package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func (m *Model) updateReview(msg tea.Msg) (tea.Model, tea.Cmd) {
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}
	switch km.String() {
	case "esc", "q":
		m.mode = modeDiff
		return m, nil
	case "j", "down":
		if m.reviewIdx < len(m.comments)-1 {
			m.reviewIdx++
		}
	case "k", "up":
		if m.reviewIdx > 0 {
			m.reviewIdx--
		}
	case "s":
		if len(m.comments) == 0 {
			return m, nil
		}
		idx := m.reviewIdx
		target := m.comments[idx]
		return m, m.resolvePane(func() tea.Cmd {
			payload := BuildPayload(m.diff, []Comment{target})
			cmd := m.sendPayload(payload)
			m.removeCommentAt(idx)
			if m.reviewIdx >= len(m.comments) && m.reviewIdx > 0 {
				m.reviewIdx = len(m.comments) - 1
			}
			if len(m.comments) == 0 {
				m.mode = modeDiff
			}
			m.renderDiffIntoViewport()
			if !m.statusErr {
				m.setStatus("sent 1 comment", false)
			}
			return cmd
		})
	case "S":
		if len(m.comments) == 0 {
			return m, nil
		}
		all := append([]Comment(nil), m.comments...)
		return m, m.resolvePane(func() tea.Cmd {
			payload := BuildPayload(m.diff, all)
			cmd := m.sendPayload(payload)
			m.comments = m.comments[:0]
			m.reviewIdx = 0
			m.mode = modeDiff
			m.renderDiffIntoViewport()
			if !m.statusErr {
				m.setStatus(fmt.Sprintf("sent %d comment(s)", len(all)), false)
			}
			return cmd
		})
	case "enter":
		if len(m.comments) == 0 {
			return m, nil
		}
		m.openCommentEdit(m.reviewIdx, modeReview)
	case "d":
		if len(m.comments) == 0 {
			return m, nil
		}
		m.comments = append(m.comments[:m.reviewIdx], m.comments[m.reviewIdx+1:]...)
		if m.reviewIdx >= len(m.comments) && m.reviewIdx > 0 {
			m.reviewIdx = len(m.comments) - 1
		}
		m.renderDiffIntoViewport()
		if len(m.comments) == 0 {
			m.mode = modeDiff
		}
	}
	return m, nil
}

func (m *Model) viewReview() string {
	title := lipgloss.NewStyle().Bold(true).Render(
		fmt.Sprintf("Pending comments (%d)", len(m.comments)),
	)

	innerW := 80
	divider := lipgloss.NewStyle().Faint(true).Render(strings.Repeat("─", innerW))

	selStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("137")).Bold(true)
	dimStyle := lipgloss.NewStyle().Faint(true)

	rows := []string{title, divider}
	for i, c := range m.comments {
		label := ansi.Truncate(commentListLabel(m, c), innerW-2, "…")
		if i == m.reviewIdx {
			rows = append(rows, selStyle.Render("▸ "+label))
		} else {
			rows = append(rows, dimStyle.Render("  "+label))
		}
	}

	rows = append(rows,
		divider,
		lipgloss.NewStyle().Faint(true).Render(
			"s send · S send all · enter edit · d delete · esc back",
		),
	)
	if m.status != "" {
		rows = append(rows, m.statusLine())
	}
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("137")).
		Padding(0, 1).
		Render(strings.Join(rows, "\n"))
}

func commentListLabel(_ *Model, c Comment) string {
	var span string
	if c.DisplayStart == c.DisplayEnd {
		span = fmt.Sprintf("%d", c.DisplayStart)
	} else {
		span = fmt.Sprintf("%d-%d", c.DisplayStart, c.DisplayEnd)
	}
	first := strings.SplitN(c.Body, "\n", 2)[0]
	prefix := ""
	if c.Orphan {
		prefix = "[orphan] "
	}
	return fmt.Sprintf("%s%s:%s  %s", prefix, c.Path, span, first)
}
