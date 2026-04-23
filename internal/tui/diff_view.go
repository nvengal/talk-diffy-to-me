package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/nvengal/talk-diffy-to-me/internal/diff"
)

type rowKind int

const (
	rowFileHeader rowKind = iota
	rowHunkHeader
	rowLine
	rowBlank
)

type row struct {
	kind    rowKind
	fileIdx int
	hunkIdx int
	lineIdx int // within hunk, valid only when kind == rowLine
}

func buildRows(d *diff.Diff) []row {
	var rs []row
	for fi, f := range d.Files {
		if fi > 0 {
			rs = append(rs, row{kind: rowBlank})
		}
		rs = append(rs, row{kind: rowFileHeader, fileIdx: fi})
		for hi, h := range f.Hunks {
			rs = append(rs, row{kind: rowHunkHeader, fileIdx: fi, hunkIdx: hi})
			for li := range h.Lines {
				rs = append(rs, row{kind: rowLine, fileIdx: fi, hunkIdx: hi, lineIdx: li})
			}
		}
	}
	return rs
}

func firstContentRow(rs []row) int {
	for i, r := range rs {
		if r.kind == rowLine {
			return i
		}
	}
	return 0
}

func lastContentRow(rs []row) int {
	for i := len(rs) - 1; i >= 0; i-- {
		if rs[i].kind == rowLine {
			return i
		}
	}
	return 0
}

func (m *Model) nextContent(from, dir int) int {
	i := from + dir
	for i >= 0 && i < len(m.rows) {
		if m.rows[i].kind == rowLine {
			return i
		}
		i += dir
	}
	return from
}

func (m *Model) nextHunkStart(from, dir int) int {
	// find first rowLine belonging to a different hunk, iterating in dir
	curF, curH := -1, -1
	if m.rows[from].kind == rowLine {
		curF, curH = m.rows[from].fileIdx, m.rows[from].hunkIdx
	}
	i := from + dir
	for i >= 0 && i < len(m.rows) {
		r := m.rows[i]
		if r.kind == rowLine && (r.fileIdx != curF || r.hunkIdx != curH) {
			// if going backwards, keep going to the *first* line of that hunk
			if dir < 0 {
				j := i
				for j-1 >= 0 && m.rows[j-1].kind == rowLine &&
					m.rows[j-1].fileIdx == r.fileIdx && m.rows[j-1].hunkIdx == r.hunkIdx {
					j--
				}
				return j
			}
			return i
		}
		i += dir
	}
	return from
}

func (m *Model) updateDiff(msg tea.Msg) (tea.Model, tea.Cmd) {
	if m.searchPrompt {
		return m.updateSearchInput(msg)
	}
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd
	}
	switch km.String() {
	case "q", "ctrl+c":
		m.quitting = true
		return m, tea.Quit
	case "esc":
		if m.searchPattern != "" {
			m.clearSearch()
			m.renderDiffIntoViewport()
		}
		return m, nil
	case "j", "down":
		m.cursor = m.nextContent(m.cursor, +1)
		m.renderDiffIntoViewport()
	case "k", "up":
		m.cursor = m.nextContent(m.cursor, -1)
		m.renderDiffIntoViewport()
	case "J":
		m.cursor = m.nextHunkStart(m.cursor, +1)
		m.renderDiffIntoViewport()
	case "K":
		m.cursor = m.nextHunkStart(m.cursor, -1)
		m.renderDiffIntoViewport()
	case "g":
		m.cursor = firstContentRow(m.rows)
		m.renderDiffIntoViewport()
	case "G":
		m.cursor = lastContentRow(m.rows)
		m.renderDiffIntoViewport()
	case "v":
		if m.visAnchor == -1 {
			m.visAnchor = m.cursor
		} else {
			m.visAnchor = -1
		}
		m.renderDiffIntoViewport()
	case "c":
		return m, m.openCommentModal()
	case "enter":
		cur := m.rows[m.cursor]
		if cur.kind != rowLine {
			return m, nil
		}
		for i, c := range m.comments {
			if c.coversLine(cur.fileIdx, cur.hunkIdx, cur.lineIdx) {
				m.openCommentEdit(i, modeDiff)
				return m, nil
			}
		}
		return m, nil
	case "d":
		m.deleteCommentsAtCursor()
		m.renderDiffIntoViewport()
	case "s":
		if len(m.comments) == 0 {
			m.setStatus("no pending comments", false)
			return m, nil
		}
		m.mode = modeReview
		m.reviewIdx = 0
		m.reviewReturn = modeDiff
	case "o":
		m.openFileAtCursor()
	case "O":
		m.openPicker(modeDiff)
	case "/":
		m.openSearchPrompt()
		return m, nil
	case "n":
		m.jumpSearchMatch(+1)
		m.renderDiffIntoViewport()
	case "N":
		m.jumpSearchMatch(-1)
		m.renderDiffIntoViewport()
	case "r":
		m.refresh()
	default:
		// let viewport handle pgup/pgdown etc
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd
	}
	return m, nil
}

// openFileAtCursor opens the file under the diff cursor, positioning the
// file-view cursor at the line corresponding to the cursor row (new-side
// preferred). Falls back to line 1 for file/hunk-header rows.
func (m *Model) openFileAtCursor() {
	if len(m.rows) == 0 {
		return
	}
	cur := m.rows[m.cursor]
	if cur.fileIdx < 0 || cur.fileIdx >= len(m.diff.Files) {
		return
	}
	f := m.diff.Files[cur.fileIdx]
	path := f.DisplayPath()

	targetLine := 1
	switch cur.kind {
	case rowLine:
		l := f.Hunks[cur.hunkIdx].Lines[cur.lineIdx]
		if l.NewLine > 0 {
			targetLine = l.NewLine
		} else if l.OldLine > 0 {
			targetLine = l.OldLine
		}
	case rowHunkHeader:
		if h := f.Hunks[cur.hunkIdx]; h.NewStart > 0 {
			targetLine = h.NewStart
		}
	}

	if err := m.openFile(path); err != nil {
		m.setStatus(fmt.Sprintf("open %s: %v", path, err), true)
		return
	}
	if m.fileBuf != nil && len(m.fileBuf.Lines) > 0 {
		m.fileBuf.cursor = clamp(targetLine-1, 0, len(m.fileBuf.Lines)-1)
		m.renderFileIntoViewport()
		m.centerCursorInFileView()
	}
	m.mode = modeFile
}

// centerCursorInDiffView scrolls the viewport so the diff-mode cursor
// sits as close to the vertical middle as possible, clamped to valid
// offsets.
func (m *Model) centerCursorInDiffView() {
	h := m.viewport.Height
	if h <= 0 {
		return
	}
	maxOff := max(0, len(m.rows)-h)
	m.viewport.SetYOffset(clamp(m.cursor-h/2, 0, maxOff))
}

// centerCursorInFileView scrolls the viewport so the file-mode cursor
// sits as close to the vertical middle as possible, clamped to valid
// offsets.
func (m *Model) centerCursorInFileView() {
	fb := m.fileBuf
	if fb == nil {
		return
	}
	h := m.viewport.Height
	if h <= 0 {
		return
	}
	desired := fb.cursor - h/2
	maxOff := max(0, len(fb.Lines)-h)
	m.viewport.SetYOffset(clamp(desired, 0, maxOff))
}

func (m *Model) selectionHunk() (fi, hi, start, end int, ok bool) {
	cur := m.rows[m.cursor]
	if cur.kind != rowLine {
		return 0, 0, 0, 0, false
	}
	if m.visAnchor == -1 {
		return cur.fileIdx, cur.hunkIdx, cur.lineIdx, cur.lineIdx, true
	}
	anch := m.rows[m.visAnchor]
	if anch.kind != rowLine || anch.fileIdx != cur.fileIdx || anch.hunkIdx != cur.hunkIdx {
		// fallback: single line (clamp guarantees same hunk, but guard anyway)
		return cur.fileIdx, cur.hunkIdx, cur.lineIdx, cur.lineIdx, true
	}
	a, b := anch.lineIdx, cur.lineIdx
	if a > b {
		a, b = b, a
	}
	return cur.fileIdx, cur.hunkIdx, a, b, true
}

func (m *Model) deleteCommentsAtCursor() {
	cur := m.rows[m.cursor]
	if cur.kind != rowLine {
		return
	}
	var kept []Comment
	removed := 0
	for _, c := range m.comments {
		if c.coversLine(cur.fileIdx, cur.hunkIdx, cur.lineIdx) {
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

// renderDiffIntoViewport rebuilds the viewport content with current cursor
// and visual selection highlighted, then adjusts scroll to keep cursor on
// screen.
func (m *Model) renderDiffIntoViewport() {
	if m.width == 0 || m.height == 0 {
		return
	}
	var b strings.Builder
	for i, r := range m.rows {
		line := m.renderRow(i, r)
		b.WriteString(line)
		b.WriteByte('\n')
	}
	m.viewport.SetContent(b.String())

	// keep cursor visible
	h := m.viewport.Height
	if m.cursor < m.viewport.YOffset {
		m.viewport.SetYOffset(m.cursor)
	} else if m.cursor >= m.viewport.YOffset+h {
		m.viewport.SetYOffset(m.cursor - h + 1)
	}
}

var (
	styleFileHeader = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("14"))
	styleHunkHeader = lipgloss.NewStyle().Foreground(lipgloss.Color("13"))
	styleAdd        = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	styleDel        = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	styleCtx        = lipgloss.NewStyle().Faint(true)
	styleGutter     = lipgloss.NewStyle().Faint(true)
	styleCursor     = lipgloss.NewStyle().Reverse(true)
	styleSelected   = lipgloss.NewStyle().Background(lipgloss.Color("237"))
	styleMarker     = lipgloss.NewStyle().Foreground(lipgloss.Color("11")).Bold(true)
	styleStickyBar  = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("14")).
			Background(lipgloss.Color("237"))
)

func (m *Model) renderRow(i int, r row) string {
	isCursor := i == m.cursor
	isSelected := false
	if m.visAnchor != -1 && m.mode == modeDiff {
		fi, hi, start, end, ok := m.selectionHunk()
		if ok && r.kind == rowLine && r.fileIdx == fi && r.hunkIdx == hi && r.lineIdx >= start && r.lineIdx <= end {
			isSelected = true
		}
	}

	var raw string
	switch r.kind {
	case rowBlank:
		raw = ""
	case rowFileHeader:
		f := m.diff.Files[r.fileIdx]
		raw = styleFileHeader.Render(fmt.Sprintf("── %s (%s)", f.DisplayPath(), f.Status))
	case rowHunkHeader:
		h := m.diff.Files[r.fileIdx].Hunks[r.hunkIdx]
		hdr := fmt.Sprintf("@@ -%d,%d +%d,%d @@", h.OldStart, h.OldCount, h.NewStart, h.NewCount)
		if h.Section != "" {
			hdr += " " + h.Section
		}
		raw = styleHunkHeader.Render(hdr)
	case rowLine:
		raw = m.renderContentLine(i, r)
	}

	if isCursor {
		raw = styleCursor.Render(padRight(raw, m.width))
	} else if isSelected {
		raw = styleSelected.Render(padRight(raw, m.width))
	}
	return raw
}

func (m *Model) renderContentLine(rowIdx int, r row) string {
	l := m.diff.Files[r.fileIdx].Hunks[r.hunkIdx].Lines[r.lineIdx]

	// comment marker
	marker := "  "
	for _, c := range m.comments {
		if c.coversLine(r.fileIdx, r.hunkIdx, r.lineIdx) {
			marker = styleMarker.Render("▸ ")
			break
		}
	}

	oldNum := "    "
	if l.OldLine > 0 {
		oldNum = fmt.Sprintf("%4d", l.OldLine)
	}
	newNum := "    "
	if l.NewLine > 0 {
		newNum = fmt.Sprintf("%4d", l.NewLine)
	}
	gutter := styleGutter.Render(fmt.Sprintf("%s %s │", oldNum, newNum))

	var baseStyle lipgloss.Style
	switch l.Kind {
	case '+':
		baseStyle = styleAdd
	case '-':
		baseStyle = styleDel
	default:
		baseStyle = styleCtx
	}
	prefix := string(l.Kind)
	// search matches are on l.Text only — render prefix separately so the
	// match offsets still line up.
	var textPart string
	if ranges := m.searchByLine[rowIdx]; len(ranges) > 0 {
		textPart = renderBodyWithMatches(l.Text, ranges, m.searchIdx, baseStyle)
	} else {
		textPart = baseStyle.Render(l.Text)
	}
	body := baseStyle.Render(prefix) + textPart

	return marker + gutter + " " + body
}

func padRight(s string, w int) string {
	visLen := lipgloss.Width(s)
	if visLen >= w {
		return s
	}
	return s + strings.Repeat(" ", w-visLen)
}

// stickyHeader returns an overlay filename line to render on the first
// visible viewport row, or "" if the real file header is already on-screen
// (or there are no files).
func (m *Model) stickyHeader() string {
	if len(m.rows) == 0 || m.viewport.Height <= 0 {
		return ""
	}
	yOff := m.viewport.YOffset
	if yOff < 0 || yOff >= len(m.rows) {
		return ""
	}
	// find the file the top visible row belongs to
	fi := -1
	for i := yOff; i >= 0; i-- {
		r := m.rows[i]
		if r.kind == rowBlank {
			continue
		}
		fi = r.fileIdx
		break
	}
	if fi < 0 {
		return ""
	}
	// locate the file header row for that file
	headerIdx := -1
	for i, r := range m.rows {
		if r.kind == rowFileHeader && r.fileIdx == fi {
			headerIdx = i
			break
		}
	}
	if headerIdx < 0 || headerIdx >= yOff {
		// real header is still visible (or at the very top)
		return ""
	}
	f := m.diff.Files[fi]
	text := fmt.Sprintf("── %s (%s)", f.DisplayPath(), f.Status)
	return styleStickyBar.Render(padRight(text, m.width))
}

func (m *Model) viewDiff() string {
	title := lipgloss.NewStyle().Bold(true).Render("talk-diffy")
	help := lipgloss.NewStyle().Faint(true).Render(
		"j/k · J/K hunk · v · c · d · s · / search · n/N · o file · O pick · r · q",
	)
	top := m.viewport.View()
	if sticky := m.stickyHeader(); sticky != "" {
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
	_ = title
	return top + "\n" + footer
}
