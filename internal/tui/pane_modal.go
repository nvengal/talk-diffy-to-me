package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

func (m *Model) updatePane(msg tea.Msg) (tea.Model, tea.Cmd) {
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}
	switch km.String() {
	case "esc", "q":
		m.afterPick = nil
		m.mode = modeReview
		m.setStatus("send cancelled", false)
		return m, nil
	case "j", "down":
		if m.paneSelIdx < len(m.candidates)-1 {
			m.paneSelIdx++
		}
	case "k", "up":
		if m.paneSelIdx > 0 {
			m.paneSelIdx--
		}
	case "enter":
		if len(m.candidates) == 0 {
			return m, nil
		}
		picked := m.candidates[m.paneSelIdx]
		m.paneID = picked.ID
		cb := m.afterPick
		m.afterPick = nil
		m.mode = modeReview
		if cb != nil {
			return m, cb()
		}
	}
	return m, nil
}

func (m *Model) viewPane() string {
	title := lipgloss.NewStyle().Bold(true).Render("Pick target pane")

	innerW := 100
	divider := lipgloss.NewStyle().Faint(true).Render(strings.Repeat("─", innerW))

	selStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("137")).Bold(true)
	dimStyle := lipgloss.NewStyle().Faint(true)

	rows := []string{title, divider}
	for i, p := range m.candidates {
		cmd := p.Command()
		if cmd == "" {
			cmd = "-"
		}
		label := fmt.Sprintf("#%d  [%s]  %s  cmd=%s  cwd=%s",
			p.ID, p.TabName, p.Title, cmd, p.Cwd)
		if i == m.paneSelIdx {
			rows = append(rows, selStyle.Render("▸ "+label))
		} else {
			rows = append(rows, dimStyle.Render("  "+label))
		}
	}
	rows = append(rows, divider, lipgloss.NewStyle().Faint(true).Render(
		"j/k move · enter pick · esc cancel",
	))
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("137")).
		Padding(0, 1).
		Render(strings.Join(rows, "\n"))
}
