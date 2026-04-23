package tui

import (
	"fmt"
	"regexp"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// searchMatch is a single hit in the open file, as a line index plus a
// byte range within that line.
type searchMatch struct {
	line  int
	start int
	end   int
}

// searchRange is a per-line view of a match with its global index, used
// during rendering so we can distinguish the current hit.
type searchRange struct {
	start, end int
	idx        int // index into Model.searchMatches
}

var (
	styleSearchHit = lipgloss.NewStyle().
			Foreground(lipgloss.Color("0")).
			Background(lipgloss.Color("220"))
	styleSearchCur = lipgloss.NewStyle().
			Foreground(lipgloss.Color("0")).
			Background(lipgloss.Color("208")).
			Bold(true)
)

// updateSearchInput handles keystrokes while the search prompt is open
// in file or diff mode.
func (m *Model) updateSearchInput(msg tea.Msg) (tea.Model, tea.Cmd) {
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		var cmd tea.Cmd
		m.searchInput, cmd = m.searchInput.Update(msg)
		return m, cmd
	}
	switch km.String() {
	case "esc", "ctrl+c":
		m.searchInput.Blur()
		m.searchPrompt = false
		return m, nil
	case "enter":
		q := m.searchInput.Value()
		m.searchInput.Blur()
		m.searchPrompt = false
		if q == "" {
			m.clearSearch()
			m.rerenderForMode()
			return m, nil
		}
		if err := m.runSearch(q); err != nil {
			m.setStatus(fmt.Sprintf("search: %v", err), true)
			m.rerenderForMode()
			return m, nil
		}
		m.jumpSearchMatch(0)
		m.rerenderForMode()
		return m, nil
	}
	var cmd tea.Cmd
	m.searchInput, cmd = m.searchInput.Update(msg)
	return m, cmd
}

// openSearchPrompt enters search-prompt mode, starting from the currently
// active pattern (if any) for easy refinement.
func (m *Model) openSearchPrompt() {
	m.searchInput.SetValue(m.searchPattern)
	m.searchInput.CursorEnd()
	m.searchInput.Focus()
	m.searchPrompt = true
}

// clearSearch drops the current pattern and all match state.
func (m *Model) clearSearch() {
	m.searchPattern = ""
	m.searchMatches = nil
	m.searchByLine = nil
	m.searchIdx = -1
}

// runSearch compiles q as a regex (smart-case: insensitive when q is all
// lowercase) and populates searchMatches against the active view. In
// file mode it scans file lines; in diff mode it scans the text of each
// rowLine row and keys matches by row index.
func (m *Model) runSearch(q string) error {
	pattern := q
	if strings.ToLower(q) == q {
		pattern = "(?i)" + pattern
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		m.clearSearch()
		return err
	}
	m.searchPattern = q
	m.searchMatches = m.searchMatches[:0]
	m.searchByLine = map[int][]searchRange{}

	addMatches := func(key int, text string) {
		for _, loc := range re.FindAllStringIndex(text, -1) {
			if loc[0] == loc[1] {
				continue // skip zero-width matches to avoid infinite styling
			}
			idx := len(m.searchMatches)
			m.searchMatches = append(m.searchMatches, searchMatch{
				line: key, start: loc[0], end: loc[1],
			})
			m.searchByLine[key] = append(m.searchByLine[key], searchRange{
				start: loc[0], end: loc[1], idx: idx,
			})
		}
	}

	switch m.mode {
	case modeFile:
		if m.fileBuf == nil {
			return nil
		}
		for li, line := range m.fileBuf.Lines {
			addMatches(li, line)
		}
	case modeDiff:
		if m.diff == nil {
			return nil
		}
		for ri, r := range m.rows {
			if r.kind != rowLine {
				continue
			}
			text := m.diff.Files[r.fileIdx].Hunks[r.hunkIdx].Lines[r.lineIdx].Text
			addMatches(ri, text)
		}
	}

	for k := range m.searchByLine {
		sort.Slice(m.searchByLine[k], func(i, j int) bool {
			return m.searchByLine[k][i].start < m.searchByLine[k][j].start
		})
	}
	return nil
}

// jumpSearchMatch moves the cursor to a search match.
//   dir == 0: nearest match at or after the current cursor (wraps)
//   dir > 0: next match
//   dir < 0: previous match
func (m *Model) jumpSearchMatch(dir int) {
	if len(m.searchMatches) == 0 {
		if m.searchPattern != "" {
			m.setStatus("pattern not found", true)
		}
		return
	}
	var cur int
	switch m.mode {
	case modeFile:
		if m.fileBuf == nil {
			return
		}
		cur = m.fileBuf.cursor
	case modeDiff:
		cur = m.cursor
	default:
		return
	}
	switch {
	case dir == 0:
		idx := sort.Search(len(m.searchMatches), func(i int) bool {
			return m.searchMatches[i].line >= cur
		})
		if idx >= len(m.searchMatches) {
			idx = 0
		}
		m.searchIdx = idx
	case dir > 0:
		m.searchIdx = (m.searchIdx + 1) % len(m.searchMatches)
	default:
		m.searchIdx = (m.searchIdx - 1 + len(m.searchMatches)) % len(m.searchMatches)
	}
	target := m.searchMatches[m.searchIdx]
	switch m.mode {
	case modeFile:
		m.fileBuf.cursor = target.line
		m.centerCursorInFileView()
	case modeDiff:
		m.cursor = target.line
		m.centerCursorInDiffView()
	}
	m.setStatus(fmt.Sprintf("[%d/%d] /%s", m.searchIdx+1, len(m.searchMatches), m.searchPattern), false)
}

// renderBodyWithMatches splices match highlights into text, leaving
// non-match segments rendered by baseStyle.
func renderBodyWithMatches(text string, ranges []searchRange, currentIdx int, baseStyle lipgloss.Style) string {
	if len(ranges) == 0 {
		return baseStyle.Render(text)
	}
	var b strings.Builder
	pos := 0
	for _, r := range ranges {
		s, e := r.start, r.end
		if s < pos {
			s = pos // overlap guard
		}
		if s > len(text) {
			break
		}
		if e > len(text) {
			e = len(text)
		}
		if s > pos {
			b.WriteString(baseStyle.Render(text[pos:s]))
		}
		style := styleSearchHit
		if r.idx == currentIdx {
			style = styleSearchCur
		}
		b.WriteString(style.Render(text[s:e]))
		pos = e
	}
	if pos < len(text) {
		b.WriteString(baseStyle.Render(text[pos:]))
	}
	return b.String()
}
