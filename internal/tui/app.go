package tui

import (
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/nvengal/talk-diffy-to-me/internal/diff"
	"github.com/nvengal/talk-diffy-to-me/internal/jj"
	"github.com/nvengal/talk-diffy-to-me/internal/zellij"
)

type mode int

const (
	modeDiff mode = iota
	modeComment
	modeReview
	modePane
	modeFilePicker
	modeFile
)

type CommentKind int

const (
	CommentDiff CommentKind = iota
	CommentFile
)

type CommentKey struct {
	FileIdx   int
	HunkIdx   int
	StartLine int
	EndLine   int
}

// Comment carries both its current anchor (valid only when !Orphan) and a
// snapshot of the line contents it was attached to. The snapshot is used
// for (a) re-anchoring after a refresh and (b) rendering labels / payload
// even when the anchor has been lost.
//
// For Kind == CommentDiff the anchor lives in Key (indices into the diff).
// For Kind == CommentFile the anchor is (Path, FileStart, FileEnd) in
// absolute 1-based file line numbers.
type Comment struct {
	Kind         CommentKind
	Key          CommentKey  // diff anchor
	FileStart    int         // file anchor (1-based)
	FileEnd      int
	Body         string
	Orphan       bool
	Path         string      // file path as of create or last successful anchor
	DisplayStart int         // display line number at create / last anchor
	DisplayEnd   int
	Snapshot     []diff.Line // line kinds + text spanned by the comment
}

// buildComment populates a Comment's snapshot fields from the current diff.
func buildComment(d *diff.Diff, key CommentKey, body string) Comment {
	f := d.Files[key.FileIdx]
	h := f.Hunks[key.HunkIdx]
	snap := append([]diff.Line(nil), h.Lines[key.StartLine:key.EndLine+1]...)
	return Comment{
		Kind:         CommentDiff,
		Key:          key,
		Body:         body,
		Path:         f.DisplayPath(),
		DisplayStart: displayLineNum(h.Lines[key.StartLine]),
		DisplayEnd:   displayLineNum(h.Lines[key.EndLine]),
		Snapshot:     snap,
	}
}

// buildFileComment builds a Comment anchored at absolute line range
// [start, end] of the open file, with a snapshot captured from lines.
func buildFileComment(path string, start, end int, lines []string, body string) Comment {
	snap := make([]diff.Line, 0, end-start+1)
	for ln := start; ln <= end; ln++ {
		var text string
		if ln-1 >= 0 && ln-1 < len(lines) {
			text = lines[ln-1]
		}
		snap = append(snap, diff.Line{Kind: ' ', Text: text, NewLine: ln})
	}
	return Comment{
		Kind:         CommentFile,
		FileStart:    start,
		FileEnd:      end,
		Body:         body,
		Path:         path,
		DisplayStart: start,
		DisplayEnd:   end,
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

// reanchorFile searches the given file line slice (0-indexed, 1-based for
// display) for a contiguous match of c.Snapshot text. On success updates
// FileStart/FileEnd + Display* and clears Orphan.
func reanchorFile(c *Comment, lines []string) {
	want := c.Snapshot
	if len(want) == 0 {
		c.Orphan = true
		return
	}
	for start := 0; start+len(want) <= len(lines); start++ {
		match := true
		for k, sl := range want {
			if lines[start+k] != sl.Text {
				match = false
				break
			}
		}
		if match {
			c.FileStart = start + 1
			c.FileEnd = start + len(want)
			c.DisplayStart = c.FileStart
			c.DisplayEnd = c.FileEnd
			// refresh snapshot line numbers so payload/preview stay consistent
			for i := range c.Snapshot {
				c.Snapshot[i].NewLine = c.FileStart + i
			}
			c.Orphan = false
			return
		}
	}
	c.Orphan = true
}

// fileBuf is the open-file workspace: file contents plus cursor/selection
// state. rows is always one row per file line (cursor indexes directly).
type fileBuf struct {
	Path      string
	Lines     []string
	cursor    int // 0-based row index (== line-1)
	visAnchor int

	// highlighted[i] is the chroma-tokenised, pre-styled segments for
	// Lines[i]. nil when no lexer matched; len may be 0 for blank lines.
	highlighted [][]segment
}

// fileCommentTarget carries the selection saved when 'c' is pressed in
// file mode; used by the comment modal to build the new Comment.
type fileCommentTarget struct {
	Path  string
	Start int // 1-based
	End   int
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
	reviewIdx    int
	reviewReturn mode // where esc from review should send us

	// pane modal
	candidates []zellij.Pane
	paneSelIdx int
	afterPick  func() tea.Cmd // callback to invoke after a pane is chosen

	// comment modal
	editingIdx      int // -1 for new comment, else index into m.comments
	targetKey       CommentKey
	targetFile      fileCommentTarget // used when editingIdx<0 and returning to modeFile
	targetLabel     string
	textarea        textarea.Model
	previewLines    string
	commentReturn   mode // where to go after comment modal closes
	commentIsFile   bool // true when saving should create a file comment

	// file picker
	pickerInput   textinput.Model
	pickerAll     []string
	pickerMatches []pickerMatch
	pickerSel     int
	pickerReturn  mode // where to go after esc (modeDiff, or -1 to quit)

	// open file
	fileBuf *fileBuf

	// search (file mode)
	searchInput     textinput.Model
	searchPrompt    bool // input open
	searchPattern   string
	searchMatches   []searchMatch
	searchByLine    map[int][]searchRange
	searchIdx       int // index into searchMatches; -1 when none

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
	startMode := modeDiff
	if d == nil || len(d.Files) == 0 {
		startMode = modeFilePicker
	}
	m := &Model{
		diff:       d,
		dryRun:     dryRun,
		loader:     loader,
		mode:       startMode,
		visAnchor:  -1,
		editingIdx: -1,
	}
	if d != nil {
		m.rows = buildRows(d)
	}
	if len(m.rows) > 0 {
		m.cursor = firstContentRow(m.rows)
	}

	pi := textinput.New()
	pi.Placeholder = "fuzzy find file…"
	pi.CharLimit = 0
	pi.Prompt = "› "
	m.pickerInput = pi

	si := textinput.New()
	si.Prompt = "/"
	si.CharLimit = 0
	m.searchInput = si
	m.searchIdx = -1

	if startMode == modeFilePicker {
		m.openPicker(-1) // -1 = quit on esc (no diff to return to)
	}

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
	case modeFilePicker:
		return m.updatePicker(msg)
	case modeFile:
		return m.updateFile(msg)
	}
	return m, nil
}

func (m *Model) View() string {
	if m.quitting {
		return ""
	}
	// backdrop for overlays: file view if a file is open, diff view otherwise,
	// or a plain empty-state when neither exists
	backdrop := m.backdropView()
	switch m.mode {
	case modeDiff:
		return m.viewDiff()
	case modeFile:
		return m.viewFile()
	case modeComment:
		return centerOverlay(backdrop, m.viewComment(), m.width, m.height)
	case modeReview:
		return centerOverlay(backdrop, m.viewReview(), m.width, m.height)
	case modePane:
		return centerOverlay(backdrop, m.viewPane(), m.width, m.height)
	case modeFilePicker:
		return centerOverlay(backdrop, m.viewPicker(), m.width, m.height)
	}
	return ""
}

func (m *Model) backdropView() string {
	if m.fileBuf != nil && m.mode == modeFile {
		return m.viewFile()
	}
	if m.diff != nil && len(m.diff.Files) > 0 {
		return m.viewDiff()
	}
	// empty backdrop for no-diff launch
	return strings.Repeat("\n", max(0, m.height-1))
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

// coversLine returns true if a non-orphan diff comment covers the given
// (fileIdx, hunkIdx, lineIdx). Orphans and file comments return false.
func (c Comment) coversLine(fi, hi, li int) bool {
	if c.Orphan || c.Kind != CommentDiff {
		return false
	}
	k := c.Key
	return k.FileIdx == fi && k.HunkIdx == hi && k.StartLine <= li && li <= k.EndLine
}

// coversFileLine returns true if a non-orphan file comment at the given
// path covers absolute line `ln`. Diff comments and orphans return false.
func (c Comment) coversFileLine(path string, ln int) bool {
	if c.Orphan || c.Kind != CommentFile {
		return false
	}
	return c.Path == path && c.FileStart <= ln && ln <= c.FileEnd
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
	fileCache := map[string][]string{}
	anchored, orphans := 0, 0
	for i := range m.comments {
		c := &m.comments[i]
		switch c.Kind {
		case CommentDiff:
			reanchor(c, nd)
		case CommentFile:
			lines, ok := fileCache[c.Path]
			if !ok {
				if data, err := os.ReadFile(c.Path); err == nil {
					lines = splitFileLines(string(data))
					fileCache[c.Path] = lines
				} else {
					lines = nil
					fileCache[c.Path] = nil
				}
			}
			if lines == nil {
				c.Orphan = true
			} else {
				reanchorFile(c, lines)
			}
		}
		if c.Orphan {
			orphans++
		} else {
			anchored++
		}
	}
	m.diff = nd
	m.rows = buildRows(nd)
	if len(m.rows) > 0 {
		m.cursor = firstContentRow(m.rows)
	} else {
		m.cursor = 0
	}
	m.visAnchor = -1
	m.clearSearch()
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

// rerenderForMode redraws the viewport content appropriate for the
// current mode. Safe to call from modal transitions.
func (m *Model) rerenderForMode() {
	switch m.mode {
	case modeDiff:
		m.renderDiffIntoViewport()
	case modeFile:
		m.renderFileIntoViewport()
	}
}

// splitFileLines splits raw file bytes into lines without preserving
// trailing newlines. A final empty "line" from a trailing \n is dropped.
func splitFileLines(s string) []string {
	if s == "" {
		return nil
	}
	s = strings.ReplaceAll(s, "\r\n", "\n")
	lines := strings.Split(s, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// loadTrackedFiles returns the list via jj.
func loadTrackedFiles() ([]string, error) {
	return jj.ListTrackedFiles()
}

