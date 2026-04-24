package zellij

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

type Pane struct {
	ID              int    `json:"id"`
	Title           string `json:"title"`
	TerminalCommand string `json:"terminal_command"`
	PaneCommand     string `json:"pane_command"`
	Cwd             string `json:"pane_cwd"`
	IsPlugin        bool   `json:"is_plugin"`
	IsSelectable    bool   `json:"is_selectable"`
	TabID           int    `json:"tab_id"`
	TabName         string `json:"tab_name"`
}

func (p Pane) Command() string {
	if p.PaneCommand != "" {
		return p.PaneCommand
	}
	return p.TerminalCommand
}

func ListPanes() ([]Pane, error) {
	out, err := exec.Command("zellij", "action", "list-panes", "--json").Output()
	if err != nil {
		return nil, fmt.Errorf("zellij list-panes: %w", err)
	}
	var panes []Pane
	if err := json.Unmarshal(out, &panes); err != nil {
		return nil, fmt.Errorf("parse list-panes json: %w", err)
	}
	return panes, nil
}

func ownPaneID() (int, bool) {
	s := os.Getenv("ZELLIJ_PANE_ID")
	if s == "" {
		return 0, false
	}
	digits := strings.TrimFunc(s, func(r rune) bool { return r < '0' || r > '9' })
	if digits == "" {
		return 0, false
	}
	n, err := strconv.Atoi(digits)
	if err != nil {
		return 0, false
	}
	return n, true
}

// Candidates returns other panes in the same tab as diffy, skipping
// plugin panes and non-selectable panes.
func Candidates() ([]Pane, error) {
	panes, err := ListPanes()
	if err != nil {
		return nil, err
	}
	own, haveOwn := ownPaneID()
	ownTab := -1
	if haveOwn {
		for _, p := range panes {
			if p.ID == own {
				ownTab = p.TabID
				break
			}
		}
	}
	var candidates []Pane
	for _, p := range panes {
		if haveOwn && p.ID == own {
			continue
		}
		if ownTab != -1 && p.TabID != ownTab {
			continue
		}
		if p.IsPlugin {
			continue
		}
		if !p.IsSelectable {
			continue
		}
		candidates = append(candidates, p)
	}
	return candidates, nil
}

// MatchClaude returns panes whose title or command contains "claude"
// (case-insensitive).
func MatchClaude(panes []Pane) []Pane {
	var m []Pane
	for _, p := range panes {
		t := strings.ToLower(p.Title)
		c := strings.ToLower(p.Command())
		if strings.Contains(t, "claude") || strings.Contains(c, "claude") {
			m = append(m, p)
		}
	}
	return m
}

// Send pastes payload into the target pane, then sends Enter to submit.
func Send(paneID int, payload string) error {
	pid := strconv.Itoa(paneID)
	if err := exec.Command("zellij", "action", "paste", "--pane-id", pid, "--", payload).Run(); err != nil {
		return fmt.Errorf("zellij paste: %w", err)
	}
	if err := exec.Command("zellij", "action", "send-keys", "--pane-id", pid, "--", "Enter").Run(); err != nil {
		return fmt.Errorf("zellij send-keys Enter: %w", err)
	}
	return nil
}
