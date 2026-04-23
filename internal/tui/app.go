package tui

import (
	"fmt"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/nvengal/talk-diffy-to-me/internal/diff"
	"github.com/nvengal/talk-diffy-to-me/internal/zellij"
)

type mode int

const (
	modeDiff mode = iota
	modeComment
	modeReview
	modePane
)

type CommentKey struct {
	FileIdx   int
	HunkIdx   int
	StartLine int
	EndLine   int
}

// Comment carries both its current anchor (Key, valid only when !Orphan)
// and a snapshot of the line contents it was attached to. The snapshot is
// used for (a) re-anchoring after a diff refresh and (b) rendering labels
// / payload even when the anchor has been lost.
type Comment struct {
	Key          CommentKey
	Body         string
	Orphan       bool
	Path         string      // file path as of create or last successful anchor
	DisplayStart int         // display line number at create / last anchor (new-side preferred)
	DisplayEnd   int
	Snapshot     []diff.Line // line kinds + text spanned by the comment
}

// buildComment populates a Comment's snapshot fields from the current diff.
func buildComment(d *diff.Diff, key CommentKey, body string) Comment {
	f := d.Files[key.FileIdx]
	h := f.Hunks[key.HunkIdx]
	snap := append([]diff.Line(nil), h.Lines[key.StartLine:key.EndLine+1]...)
	return Comment{
		Key:          key,
		Body:         body,
		Path:         f.DisplayPath(),
		DisplayStart: displayLineNum(h.Lines[key.StartLine]),
		DisplayEnd:   displayLineNum(h.Lines[key.EndLine]),
		Snapshot:     snap,
	}
}

// reanchor walks the new diff looking for a contiguous match of c.Snapshot
// under c.Path. On success updates Key + DisplayStart/End and clears Orphan.
// On failure sets Orphan = true; Key is left at its last-known (now stale)
// value and is not used for rendering.
func reanchor(c *Comment, d *diff.Diff) {
	want := c.Snapshot
	if len(want) == 0 {
		c.Orphan = true
		return
	}
	for fi, f := range d.Files {
		if f.DisplayPath() != c.Path {
			continue
		}
		for hi, h := range f.Hunks {
			for start := 0; start+len(want) <= len(h.Lines); start++ {
				match := true
				for k, sl := range want {
					hl := h.Lines[start+k]
					if hl.Kind != sl.Kind || hl.Text != sl.Text {
						match = false
						break
					}
				}
				if match {
					c.Key = CommentKey{FileIdx: fi, HunkIdx: hi, StartLine: start, EndLine: start + len(want) - 1}
					c.DisplayStart = displayLineNum(h.Lines[start])
					c.DisplayEnd = displayLineNum(h.Lines[start+len(want)-1])
					c.Orphan = false
					return
				}
			}
		}
	}
	c.Orphan = true
}

type Model struct {
	diff   *diff.Diff
	dryRun bool
	loader func() (*diff.Diff, error) // for 'r' refresh

	mode mode

	rows      []row
	cursor    int
	visAnchor int // -1 when not in visual mode

	comments []Comment

	paneID int

	// review modal
	reviewIdx int

	// pane modal
	candidates []zellij.Pane
	paneSelIdx int
	afterPick  func() tea.Cmd // callback to invoke after a pane is chosen

	// comment modal
	editingIdx    int // -1 for new comment, else index into m.comments
	targetKey     CommentKey
	targetLabel   string
	textarea      textarea.Model
	previewLines  string
	commentReturn mode // where to go after comment modal closes

	viewport viewport.Model
	width    int
	height   int

	status    string
	statusErr bool

	quitting bool
}

func Run(d *diff.Diff, dryRun bool, loader func() (*diff.Diff, error)) error {
	m := newModel(d, dryRun, loader)
	_, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
	return err
}

func newModel(d *diff.Diff, dryRun bool, loader func() (*diff.Diff, error)) *Model {
	m := &Model{
		diff:       d,
		dryRun:     dryRun,
		loader:     loader,
		mode:       modeDiff,
		visAnchor:  -1,
		editingIdx: -1,
	}
	m.rows = buildRows(d)
	m.cursor = firstContentRow(m.rows)

	ta := textarea.New()
	ta.Placeholder = "write your comment…"
	ta.CharLimit = 0
	ta.SetHeight(8)
	ta.KeyMap.InsertNewline = key.NewBinding(key.WithKeys("alt+enter"))
	// drop the dark "current-line" highlight — looks ugly against the modal
	emptyStyle := lipgloss.NewStyle()
	ta.FocusedStyle.CursorLine = emptyStyle
	ta.FocusedStyle.CursorLineNumber = emptyStyle
	ta.FocusedStyle.Base = emptyStyle
	ta.BlurredStyle.CursorLine = emptyStyle
	ta.BlurredStyle.CursorLineNumber = emptyStyle
	ta.BlurredStyle.Base = emptyStyle
	m.textarea = ta

	m.viewport = viewport.New(80, 20)
	return m
}

func (m *Model) Init() tea.Cmd {
	return nil
}

func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.viewport.Width = msg.Width
		m.viewport.Height = max(1, msg.Height-2) // leave room for status
		m.textarea.SetWidth(clamp(msg.Width-12, 40, 80))
		m.renderDiffIntoViewport()
		return m, nil
	}

	switch m.mode {
	case modeDiff:
		return m.updateDiff(msg)
	case modeComment:
		return m.updateComment(msg)
	case modeReview:
		return m.updateReview(msg)
	case modePane:
		return m.updatePane(msg)
	}
	return m, nil
}

func (m *Model) View() string {
	if m.quitting {
		return ""
	}
	switch m.mode {
	case modeDiff:
		return m.viewDiff()
	case modeComment:
		return centerOverlay(m.viewDiff(), m.viewComment(), m.width, m.height)
	case modeReview:
		return centerOverlay(m.viewDiff(), m.viewReview(), m.width, m.height)
	case modePane:
		return centerOverlay(m.viewDiff(), m.viewPane(), m.width, m.height)
	}
	return ""
}

func (m *Model) setStatus(s string, isErr bool) {
	m.status = s
	m.statusErr = isErr
}

func (m *Model) statusLine() string {
	if m.status == "" {
		return ""
	}
	style := lipgloss.NewStyle().Faint(true)
	if m.statusErr {
		style = lipgloss.NewStyle().Foreground(lipgloss.Color("9"))
	}
	return style.Render(m.status)
}

// coversLine returns true if a non-orphan comment covers the given
// (fileIdx, hunkIdx, lineIdx). Orphans have no valid anchor.
func (c Comment) coversLine(fi, hi, li int) bool {
	if c.Orphan {
		return false
	}
	k := c.Key
	return k.FileIdx == fi && k.HunkIdx == hi && k.StartLine <= li && li <= k.EndLine
}

// resolvePane discovers the Claude pane. If auto-picked, returns the id;
// otherwise opens the pane modal and returns 0. The `after` callback runs
// once a pane is selected (either now or from the modal).
func (m *Model) resolvePane(after func() tea.Cmd) tea.Cmd {
	if m.paneID != 0 {
		return after()
	}
	cands, err := zellij.Candidates()
	if err != nil {
		m.setStatus(fmt.Sprintf("zellij: %v", err), true)
		return nil
	}
	if len(cands) == 0 {
		m.setStatus("no other panes in this tab", true)
		return nil
	}
	if matches := zellij.MatchClaude(cands); len(matches) == 1 {
		m.paneID = matches[0].ID
		return after()
	}
	m.candidates = cands
	m.paneSelIdx = 0
	m.mode = modePane
	m.afterPick = after
	return nil
}

// sendPayload actually ships the payload to the resolved pane.
func (m *Model) sendPayload(payload string) tea.Cmd {
	if m.dryRun {
		fmt.Print("--- dry-run payload ---\n" + payload + "\n--- end ---\n")
		m.setStatus("dry-run: payload printed to stdout", false)
		return nil
	}
	if err := zellij.Send(m.paneID, payload); err != nil {
		m.setStatus(fmt.Sprintf("send failed: %v", err), true)
		return nil
	}
	return nil
}

// refresh reloads the diff via the stored loader and re-anchors every
// pending comment against the new diff. Comments whose snapshot can't
// be found become orphans.
func (m *Model) refresh() {
	if m.loader == nil {
		m.setStatus("refresh unavailable", true)
		return
	}
	nd, err := m.loader()
	if err != nil {
		m.setStatus(fmt.Sprintf("refresh failed: %v", err), true)
		return
	}
	if len(nd.Files) == 0 {
		m.setStatus("refresh: empty diff", true)
		return
	}
	anchored, orphans := 0, 0
	for i := range m.comments {
		reanchor(&m.comments[i], nd)
		if m.comments[i].Orphan {
			orphans++
		} else {
			anchored++
		}
	}
	m.diff = nd
	m.rows = buildRows(nd)
	m.cursor = firstContentRow(m.rows)
	m.visAnchor = -1
	m.renderDiffIntoViewport()
	switch {
	case len(m.comments) == 0:
		m.setStatus("diff refreshed", false)
	case orphans == 0:
		m.setStatus(fmt.Sprintf("diff refreshed; %d comment(s) re-anchored", anchored), false)
	default:
		m.setStatus(fmt.Sprintf("diff refreshed; %d anchored, %d orphan(s)", anchored, orphans), false)
	}
}

// removeCommentAt drops the comment at the given index.
func (m *Model) removeCommentAt(idx int) {
	if idx < 0 || idx >= len(m.comments) {
		return
	}
	m.comments = append(m.comments[:idx], m.comments[idx+1:]...)
}

// helpers
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

