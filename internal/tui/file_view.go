package tui

import (
	"fmt"
	"os"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

func (m *Model) updateFile(msg tea.Msg) (tea.Model, tea.Cmd) {
	if m.searchPrompt {
		return m.updateSearchInput(msg)
	}
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd
	}
	fb := m.fileBuf
	if fb == nil || len(fb.Lines) == 0 {
		switch km.String() {
		case "esc", "q":
			return m.leaveFileMode(false)
		case "ctrl+c":
			m.quitting = true
			return m, tea.Quit
		case "O":
			m.openPicker(modeFile)
			return m, nil
		}
		return m, nil
	}
	last := len(fb.Lines) - 1
	switch km.String() {
	case "ctrl+c":
		m.quitting = true
		return m, tea.Quit
	case "esc":
		if m.searchPattern != "" {
			m.clearSearch()
			m.renderFileIntoViewport()
			return m, nil
		}
		return m.leaveFileMode(false)
	case "q":
		return m.leaveFileMode(false)
	case "j", "down":
		if fb.cursor < last {
			fb.cursor++
		}
		m.renderFileIntoViewport()
	case "k", "up":
		if fb.cursor > 0 {
			fb.cursor--
		}
		m.renderFileIntoViewport()
	case "g":
		fb.cursor = 0
		m.renderFileIntoViewport()
	case "G":
		fb.cursor = last
		m.renderFileIntoViewport()
	case "ctrl+d":
		fb.cursor = min(last, fb.cursor+max(1, m.viewport.Height/2))
		m.renderFileIntoViewport()
	case "ctrl+u":
		fb.cursor = max(0, fb.cursor-max(1, m.viewport.Height/2))
		m.renderFileIntoViewport()
	case "v":
		if fb.visAnchor == -1 {
			fb.visAnchor = fb.cursor
		} else {
			fb.visAnchor = -1
		}
		m.renderFileIntoViewport()
	case "c":
		return m, m.openFileCommentModal()
	case "enter":
		ln := fb.cursor + 1
		for i, c := range m.comments {
			if c.coversFileLine(fb.Path, ln) {
				m.openCommentEdit(i, modeFile)
				return m, nil
			}
		}
		return m, nil
	case "d":
		m.deleteFileCommentsAtCursor()
		m.renderFileIntoViewport()
	case "s":
		if len(m.comments) == 0 {
			m.setStatus("no pending comments", false)
			return m, nil
		}
		m.mode = modeReview
		m.reviewIdx = 0
		m.reviewReturn = modeFile
	case "O":
		m.openPicker(modeFile)
	case "/":
		m.openSearchPrompt()
		return m, nil
	case "n":
		m.jumpSearchMatch(+1)
		m.renderFileIntoViewport()
	case "N":
		m.jumpSearchMatch(-1)
		m.renderFileIntoViewport()
	case "r":
		m.reloadFile()
	default:
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd
	}
	return m, nil
}

// leaveFileMode drops the open file and returns to the diff view if one
// exists, otherwise re-opens the picker.
func (m *Model) leaveFileMode(keepFile bool) (tea.Model, tea.Cmd) {
	if !keepFile {
		m.fileBuf = nil
	}
	// search matches were keyed by file-line; clear to avoid stale hits
	// in the diff view
	m.clearSearch()
	if m.diff != nil && len(m.diff.Files) > 0 {
		m.mode = modeDiff
		m.renderDiffIntoViewport()
		return m, nil
	}
	// no diff: re-open picker so esc doesn't strand the user
	m.openPicker(-1)
	return m, nil
}

// reloadFile re-reads the open file from disk and re-anchors any file
// comments for that path.
func (m *Model) reloadFile() {
	fb := m.fileBuf
	if fb == nil {
		return
	}
	data, err := os.ReadFile(fb.Path)
	if err != nil {
		m.setStatus(fmt.Sprintf("reload: %v", err), true)
		return
	}
	content := string(data)
	lines := splitFileLines(content)
	fb.Lines = lines
	fb.highlighted = highlightFile(fb.Path, content)
	if fb.cursor >= len(lines) {
		fb.cursor = max(0, len(lines)-1)
	}
	fb.visAnchor = -1
	// re-run any active search against the new contents
	if m.searchPattern != "" {
		_ = m.runSearch(m.searchPattern)
	}
	anchored, orphans := 0, 0
	for i := range m.comments {
		c := &m.comments[i]
		if c.Kind != CommentFile || c.Path != fb.Path {
			continue
		}
		reanchorFile(c, lines)
		if c.Orphan {
			orphans++
		} else {
			anchored++
		}
	}
	m.renderFileIntoViewport()
	switch {
	case anchored+orphans == 0:
		m.setStatus("file reloaded", false)
	case orphans == 0:
		m.setStatus(fmt.Sprintf("file reloaded; %d comment(s) re-anchored", anchored), false)
	default:
		m.setStatus(fmt.Sprintf("file reloaded; %d anchored, %d orphan(s)", anchored, orphans), false)
	}
}

func (m *Model) fileSelection() (start, end int, ok bool) {
	fb := m.fileBuf
	if fb == nil || len(fb.Lines) == 0 {
		return 0, 0, false
	}
	if fb.visAnchor == -1 {
		return fb.cursor, fb.cursor, true
	}
	a, b := fb.visAnchor, fb.cursor
	if a > b {
		a, b = b, a
	}
	return a, b, true
}

func (m *Model) deleteFileCommentsAtCursor() {
	fb := m.fileBuf
	if fb == nil {
		return
	}
	ln := fb.cursor + 1
	var kept []Comment
	removed := 0
	for _, c := range m.comments {
		if c.coversFileLine(fb.Path, ln) {
			removed++
			continue
		}
		kept = append(kept, c)
	}
	m.comments = kept
	if removed > 0 {
		m.setStatus(fmt.Sprintf("deleted %d comment(s)", removed), false)
	}
}

// renderFileIntoViewport draws the open file into the shared viewport.
func (m *Model) renderFileIntoViewport() {
	fb := m.fileBuf
	if fb == nil || m.width == 0 || m.height == 0 {
		return
	}
	var b strings.Builder
	for i := range fb.Lines {
		line := m.renderFileLine(i)
		b.WriteString(line)
		b.WriteByte('\n')
	}
	m.viewport.SetContent(b.String())

	h := m.viewport.Height
	if fb.cursor < m.viewport.YOffset {
		m.viewport.SetYOffset(fb.cursor)
	} else if fb.cursor >= m.viewport.YOffset+h {
		m.viewport.SetYOffset(fb.cursor - h + 1)
	}
}

func (m *Model) renderFileLine(i int) string {
	fb := m.fileBuf
	text := fb.Lines[i]
	ln := i + 1

	isCursor := i == fb.cursor
	isSelected := false
	if fb.visAnchor != -1 {
		s, e, ok := m.fileSelection()
		if ok && i >= s && i <= e {
			isSelected = true
		}
	}

	marker := "  "
	for _, c := range m.comments {
		if c.coversFileLine(fb.Path, ln) {
			marker = styleMarker.Render("▸ ")
			break
		}
	}

	gutter := styleGutter.Render(fmt.Sprintf("%5d │", ln))
	ranges := m.searchByLine[i]
	var body string
	switch {
	case fb.highlighted != nil && i < len(fb.highlighted):
		body = renderSegmentsWithMatches(fb.highlighted[i], ranges, m.searchIdx)
	case len(ranges) > 0:
		body = renderBodyWithMatches(text, ranges, m.searchIdx, styleCtx)
	default:
		body = styleCtx.Render(text)
	}
	raw := marker + gutter + " " + body

	if isCursor {
		raw = styleCursor.Render(padRight(raw, m.width))
	} else if isSelected {
		raw = styleSelected.Render(padRight(raw, m.width))
	}
	return raw
}

// fileStickyHeader returns the always-on header for file view (path pinned
// at the top of the viewport area).
func (m *Model) fileStickyHeader() string {
	if m.fileBuf == nil {
		return ""
	}
	label := fmt.Sprintf("── %s", m.fileBuf.Path)
	return styleStickyBar.Render(padRight(label, m.width))
}

func (m *Model) viewFile() string {
	help := lipgloss.NewStyle().Faint(true).Render(
		"j/k move · g/G top/bot · v select · c comment · d delete · s review · / search · n/N next/prev · O open · q back",
	)
	top := m.viewport.View()
	if sticky := m.fileStickyHeader(); sticky != "" {
		lines := strings.SplitN(top, "\n", 2)
		if len(lines) == 2 {
			top = sticky + "\n" + lines[1]
		} else {
			top = sticky
		}
	}
	var footer string
	switch {
	case m.searchPrompt:
		footer = m.searchInput.View()
	case m.status != "":
		footer = m.statusLine() + "  " + help
	default:
		footer = help
	}
	return top + "\n" + footer
}

