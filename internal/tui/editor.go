package tui

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

// editorDoneMsg is delivered when a spawned $EDITOR exits.
type editorDoneMsg struct {
	err  error
	path string
}

// launchEditor returns a bubbletea command that suspends the TUI, runs
// $EDITOR (falling back to vi) on path at the given 1-based line, and
// resumes the TUI when the editor exits.
//
// $EDITOR is split on whitespace so values like "code --wait" work. The
// "+N" line-jump argument is standard for vi/vim/nano/emacs; editors
// that don't understand it (e.g. code) will just ignore it.
func launchEditor(path string, line int) tea.Cmd {
	editor := strings.TrimSpace(os.Getenv("EDITOR"))
	parts := strings.Fields(editor)
	if len(parts) == 0 {
		parts = []string{"vi"}
	}
	args := append([]string(nil), parts[1:]...)
	if line > 0 {
		args = append(args, fmt.Sprintf("+%d", line))
	}
	args = append(args, path)
	c := exec.Command(parts[0], args...)
	return tea.ExecProcess(c, func(err error) tea.Msg {
		return editorDoneMsg{err: err, path: path}
	})
}

// handleEditorDone resyncs view state after $EDITOR exits: reload the
// open file (if any) and refresh the diff (if a loader is wired). Both
// re-anchor their respective comment sets.
func (m *Model) handleEditorDone(em editorDoneMsg) (tea.Model, tea.Cmd) {
	if em.err != nil {
		m.setStatus(fmt.Sprintf("editor: %v", em.err), true)
		return m, nil
	}
	if m.fileBuf != nil && m.fileBuf.Path == em.path {
		m.reloadFile()
	}
	if m.loader != nil {
		m.refresh()
	}
	m.rerenderForMode()
	return m, nil
}
