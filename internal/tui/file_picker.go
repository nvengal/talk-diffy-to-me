package tui

import (
	"fmt"
	"os"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// pickerMatch is a candidate path with its fuzzy score and highlight
// positions (rune indexes into Path).
type pickerMatch struct {
	Path      string
	Score     int
	Positions []int
}

// openPicker switches to the file-picker modal. returnMode is where esc
// should send the user; pass mode(-1) to quit the app on esc.
func (m *Model) openPicker(returnMode mode) {
	all, err := loadTrackedFiles()
	if err != nil {
		m.setStatus(fmt.Sprintf("jj file list: %v", err), true)
		return
	}
	m.pickerAll = all
	m.pickerInput.SetValue("")
	m.pickerInput.Focus()
	m.pickerSel = 0
	m.pickerReturn = returnMode
	m.recomputePickerMatches()
	m.mode = modeFilePicker
}

func (m *Model) updatePicker(msg tea.Msg) (tea.Model, tea.Cmd) {
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		var cmd tea.Cmd
		m.pickerInput, cmd = m.pickerInput.Update(msg)
		return m, cmd
	}
	switch km.String() {
	case "esc":
		m.pickerInput.Blur()
		if int(m.pickerReturn) < 0 {
			m.quitting = true
			return m, tea.Quit
		}
		m.mode = m.pickerReturn
		return m, nil
	case "ctrl+c":
		m.quitting = true
		return m, tea.Quit
	case "down", "ctrl+n":
		if m.pickerSel < len(m.pickerMatches)-1 {
			m.pickerSel++
		}
		return m, nil
	case "up", "ctrl+p":
		if m.pickerSel > 0 {
			m.pickerSel--
		}
		return m, nil
	case "enter":
		if len(m.pickerMatches) == 0 {
			return m, nil
		}
		path := m.pickerMatches[m.pickerSel].Path
		if err := m.openFile(path); err != nil {
			m.setStatus(fmt.Sprintf("open %s: %v", path, err), true)
			return m, nil
		}
		m.pickerInput.Blur()
		m.mode = modeFile
		return m, nil
	}
	var cmd tea.Cmd
	prev := m.pickerInput.Value()
	m.pickerInput, cmd = m.pickerInput.Update(msg)
	if m.pickerInput.Value() != prev {
		m.recomputePickerMatches()
	}
	return m, cmd
}

func (m *Model) recomputePickerMatches() {
	q := strings.TrimSpace(m.pickerInput.Value())
	matches := make([]pickerMatch, 0, len(m.pickerAll))
	if q == "" {
		for _, p := range m.pickerAll {
			matches = append(matches, pickerMatch{Path: p})
		}
	} else {
		for _, p := range m.pickerAll {
			if score, pos, ok := fuzzyScore(p, q); ok {
				matches = append(matches, pickerMatch{Path: p, Score: score, Positions: pos})
			}
		}
		sort.SliceStable(matches, func(i, j int) bool {
			if matches[i].Score != matches[j].Score {
				return matches[i].Score > matches[j].Score
			}
			return len(matches[i].Path) < len(matches[j].Path)
		})
	}
	// cap to a reasonable display size
	const cap = 200
	if len(matches) > cap {
		matches = matches[:cap]
	}
	m.pickerMatches = matches
	if m.pickerSel >= len(matches) {
		m.pickerSel = 0
	}
}

// fuzzyScore returns (score, matched-rune-positions, ok). Higher score
// is better. Matching is case-insensitive, in-order sub-sequence match;
// consecutive matches and word-boundary hits boost score.
func fuzzyScore(path, query string) (int, []int, bool) {
	if query == "" {
		return 0, nil, true
	}
	pr := []rune(strings.ToLower(path))
	qr := []rune(strings.ToLower(query))
	positions := make([]int, 0, len(qr))
	score := 0
	streak := 0
	qi := 0
	for pi, c := range pr {
		if qi >= len(qr) {
			break
		}
		if c == qr[qi] {
			positions = append(positions, pi)
			bonus := 1
			if streak > 0 {
				bonus += streak * 2
			}
			if pi == 0 || isBoundary(pr[pi-1]) {
				bonus += 3
			}
			if rune(path[pi]) != c { // original was uppercase — word-ish
				bonus++
			}
			score += bonus
			streak++
			qi++
		} else {
			streak = 0
		}
	}
	if qi < len(qr) {
		return 0, nil, false
	}
	// penalize long paths slightly
	score -= len(pr) / 50
	return score, positions, true
}

func isBoundary(r rune) bool {
	return r == '/' || r == '_' || r == '-' || r == '.' || r == ' '
}

func (m *Model) openFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	content := string(data)
	m.fileBuf = &fileBuf{
		Path:        path,
		Lines:       splitFileLines(content),
		highlighted: highlightFile(path, content),
		cursor:      0,
		visAnchor:   -1,
	}
	m.clearSearch()
	m.renderFileIntoViewport()
	return nil
}

var (
	stylePickerSel = lipgloss.NewStyle().Foreground(lipgloss.Color("137")).Bold(true)
	stylePickerDim = lipgloss.NewStyle().Faint(true)
	stylePickerHit = lipgloss.NewStyle().Foreground(lipgloss.Color("11")).Bold(true)
)

func (m *Model) viewPicker() string {
	title := lipgloss.NewStyle().Bold(true).Render("Open file")
	innerW := 80
	divider := lipgloss.NewStyle().Faint(true).Render(strings.Repeat("─", innerW))

	rows := []string{title, divider, m.pickerInput.View(), divider}

	const maxVisible = 15
	start := 0
	if m.pickerSel >= maxVisible {
		start = m.pickerSel - maxVisible + 1
	}
	end := start + maxVisible
	if end > len(m.pickerMatches) {
		end = len(m.pickerMatches)
	}

	for i := start; i < end; i++ {
		mt := m.pickerMatches[i]
		label := highlightMatch(mt.Path, mt.Positions)
		label = ansi.Truncate(label, innerW-2, "…")
		if i == m.pickerSel {
			rows = append(rows, stylePickerSel.Render("▸ ")+label)
		} else {
			rows = append(rows, "  "+label)
		}
	}
	if len(m.pickerMatches) == 0 {
		rows = append(rows, stylePickerDim.Render("  (no matches)"))
	}

	rows = append(rows,
		divider,
		stylePickerDim.Render(
			fmt.Sprintf("%d match(es) · up/down move · enter open · esc cancel", len(m.pickerMatches)),
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

func highlightMatch(path string, pos []int) string {
	if len(pos) == 0 {
		return path
	}
	var b strings.Builder
	pi := 0
	for i, r := range path {
		if pi < len(pos) && pos[pi] == i {
			b.WriteString(stylePickerHit.Render(string(r)))
			pi++
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}
