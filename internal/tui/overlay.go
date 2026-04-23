package tui

import (
	"strings"
	"unicode/utf8"

	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-runewidth"
)

// splitAtCol splits an ANSI-aware string so the left side has visible
// width as close to col as possible without exceeding it. Escape
// sequences are preserved; a wide rune that would straddle the boundary
// goes to the right side.
func splitAtCol(s string, col int) (string, string) {
	var lb, rb strings.Builder
	width := 0
	i := 0
	for i < len(s) {
		// CSI escape sequence: ESC '[' ... final-byte in 0x40-0x7E
		if s[i] == 0x1b && i+1 < len(s) && s[i+1] == '[' {
			end := i + 2
			for end < len(s) {
				c := s[end]
				end++
				if c >= 0x40 && c <= 0x7E {
					break
				}
			}
			seq := s[i:end]
			if width < col {
				lb.WriteString(seq)
			} else {
				rb.WriteString(seq)
			}
			i = end
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 {
			i++
			continue
		}
		w := runewidth.RuneWidth(r)
		if width+w > col {
			rb.WriteString(s[i:])
			return lb.String(), rb.String()
		}
		lb.WriteRune(r)
		width += w
		i += size
	}
	return lb.String(), rb.String()
}

// overlay splices fg onto bg at (x, y). Both strings are newline-delimited.
// Fg lines that would land outside bg's vertical range are clipped.
// Background lines shorter than x are right-padded with spaces so the
// overlay doesn't smear against the left edge.
func overlay(bg, fg string, x, y int) string {
	const reset = "\x1b[0m"
	bgLines := strings.Split(bg, "\n")
	fgLines := strings.Split(fg, "\n")
	for i, fl := range fgLines {
		row := y + i
		if row < 0 || row >= len(bgLines) {
			continue
		}
		bgLine := bgLines[row]

		left, rest := splitAtCol(bgLine, x)
		if lw := lipgloss.Width(left); lw < x {
			left += strings.Repeat(" ", x-lw)
		}
		fgW := lipgloss.Width(fl)
		_, right := splitAtCol(rest, fgW)

		bgLines[row] = left + reset + fl + reset + right
	}
	return strings.Join(bgLines, "\n")
}

// centerOverlay places fg centered over bg. If bg's dimensions are
// unknown (0), it falls back to rendering fg alone.
func centerOverlay(bg, fg string, bgWidth, bgHeight int) string {
	if bgWidth <= 0 || bgHeight <= 0 {
		return fg
	}
	fgW := lipgloss.Width(fg)
	fgH := lipgloss.Height(fg)
	x := (bgWidth - fgW) / 2
	y := (bgHeight - fgH) / 2
	if x < 0 {
		x = 0
	}
	if y < 0 {
		y = 0
	}
	return overlay(bg, fg, x, y)
}
