package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/nvengal/talk-diffy-to-me/internal/diff"
)

// openCommentModal always opens a fresh comment on the current line or
// visual-mode selection. To edit an existing comment, use openCommentEdit.
func (m *Model) openCommentModal() tea.Cmd {
	fi, hi, start, end, ok := m.selectionHunk()
	if !ok {
		return nil
	}
	key := CommentKey{FileIdx: fi, HunkIdx: hi, StartLine: start, EndLine: end}
	f := m.diff.Files[key.FileIdx]
	h := f.Hunks[key.HunkIdx]
	snap := h.Lines[key.StartLine : key.EndLine+1]

	m.targetKey = key
	m.commentIsFile = false
	m.editingIdx = -1
	m.textarea.Reset()
	m.previewLines = renderPreviewLines(snap)
	m.targetLabel = formatCommentLabel(
		f.DisplayPath(),
		displayLineNum(h.Lines[key.StartLine]),
		displayLineNum(h.Lines[key.EndLine]),
		key.EndLine-key.StartLine+1,
		false,
	)
	m.textarea.Focus()
	m.commentReturn = modeDiff
	m.mode = modeComment
	m.visAnchor = -1
	return nil
}

// openFileCommentModal starts a new comment in file mode using the open
// file's current selection (or cursor line).
func (m *Model) openFileCommentModal() tea.Cmd {
	fb := m.fileBuf
	if fb == nil || len(fb.Lines) == 0 {
		return nil
	}
	s, e, ok := m.fileSelection()
	if !ok {
		return nil
	}
	start, end := s+1, e+1 // to 1-based
	snap := make([]diff.Line, 0, end-start+1)
	for ln := start; ln <= end; ln++ {
		snap = append(snap, diff.Line{Kind: ' ', Text: fb.Lines[ln-1], NewLine: ln})
	}

	m.targetFile = fileCommentTarget{Path: fb.Path, Start: start, End: end}
	m.commentIsFile = true
	m.editingIdx = -1
	m.textarea.Reset()
	m.previewLines = renderPreviewLines(snap)
	m.targetLabel = formatCommentLabel(fb.Path, start, end, end-start+1, false)
	m.textarea.Focus()
	m.commentReturn = modeFile
	m.mode = modeComment
	fb.visAnchor = -1
	return nil
}

// openCommentEdit opens the modal pre-filled for editing the comment at
// the given index. returnMode is where to go after save/cancel.
// Works for orphans too (preview comes from the stored snapshot).
func (m *Model) openCommentEdit(idx int, returnMode mode) {
	c := m.comments[idx]
	m.targetKey = c.Key
	m.editingIdx = idx
	m.textarea.Reset()
	m.textarea.SetValue(c.Body)
	m.previewLines = renderPreviewLines(c.Snapshot)
	m.targetLabel = formatCommentLabel(c.Path, c.DisplayStart, c.DisplayEnd, len(c.Snapshot), c.Orphan)
	m.textarea.Focus()
	m.commentReturn = returnMode
	m.mode = modeComment
	m.visAnchor = -1
}

func (m *Model) updateComment(msg tea.Msg) (tea.Model, tea.Cmd) {
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		var cmd tea.Cmd
		m.textarea, cmd = m.textarea.Update(msg)
		return m, cmd
	}
	switch km.String() {
	case "esc":
		m.textarea.Blur()
		m.mode = m.commentReturn
		m.rerenderForMode()
		return m, nil
	case "enter":
		body := strings.TrimRight(m.textarea.Value(), "\n")
		if body == "" {
			m.setStatus("empty comment; press esc to cancel", true)
			return m, nil
		}
		if m.editingIdx >= 0 {
			m.comments[m.editingIdx].Body = body
		} else if m.commentIsFile {
			t := m.targetFile
			var lines []string
			if m.fileBuf != nil && m.fileBuf.Path == t.Path {
				lines = m.fileBuf.Lines
			}
			m.comments = append(m.comments, buildFileComment(t.Path, t.Start, t.End, lines, body))
		} else {
			m.comments = append(m.comments, buildComment(m.diff, m.targetKey, body))
		}
		m.textarea.Blur()
		m.mode = m.commentReturn
		m.setStatus("comment saved", false)
		m.rerenderForMode()
		return m, nil
	}
	var cmd tea.Cmd
	m.textarea, cmd = m.textarea.Update(msg)
	return m, cmd
}

func (m *Model) viewComment() string {
	innerW := m.textarea.Width()
	title := lipgloss.NewStyle().Bold(true).Render(m.targetLabel)
	divider := lipgloss.NewStyle().Faint(true).Render(strings.Repeat("─", innerW))

	hint := lipgloss.NewStyle().Faint(true).Render(
		"enter save · alt+enter newline · esc cancel",
	)

	sections := []string{
		title,
		divider,
		m.previewLines,
		divider,
		m.textarea.View(),
		hint,
	}
	if m.status != "" {
		sections = append(sections, m.statusLine())
	}

	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("137")).
		Padding(0, 1).
		Render(strings.Join(sections, "\n"))
}

func formatCommentLabel(path string, start, end, n int, orphan bool) string {
	prefix := ""
	if orphan {
		prefix = "[orphan] "
	}
	if start == end {
		return fmt.Sprintf("%sComment on %s:%d", prefix, path, start)
	}
	return fmt.Sprintf("%sComment on %s:%d-%d (%d lines)", prefix, path, start, end, n)
}

func renderPreviewLines(lines []diff.Line) string {
	var b strings.Builder
	for _, l := range lines {
		oldNum := "    "
		if l.OldLine > 0 {
			oldNum = fmt.Sprintf("%4d", l.OldLine)
		}
		newNum := "    "
		if l.NewLine > 0 {
			newNum = fmt.Sprintf("%4d", l.NewLine)
		}
		gutter := styleGutter.Render(fmt.Sprintf("%s %s │", oldNum, newNum))
		body := string(l.Kind) + l.Text
		switch l.Kind {
		case '+':
			body = styleAdd.Render(body)
		case '-':
			body = styleDel.Render(body)
		default:
			body = styleCtx.Render(body)
		}
		b.WriteString(gutter + " " + body + "\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

func displayLineNum(l diff.Line) int {
	if l.NewLine > 0 {
		return l.NewLine
	}
	return l.OldLine
}
