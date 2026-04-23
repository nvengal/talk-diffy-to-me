package tui

import (
	"strings"

	"github.com/alecthomas/chroma/v2"
	"github.com/alecthomas/chroma/v2/lexers"
	"github.com/alecthomas/chroma/v2/styles"
	"github.com/charmbracelet/lipgloss"
)

// segment is a contiguous run of text sharing one lipgloss style, split
// so that no segment spans a newline.
type segment struct {
	text  string
	style lipgloss.Style
}

// styleName is the chroma theme used for highlighting. Pinned here so
// it's easy to swap. Some common, TUI-friendly choices: "github-dark",
// "native", "dracula", "solarized-dark", "nord", "onedark".
const styleName = "nord"

// highlightFile tokenises content with a lexer chosen from path and
// returns one []segment per line (empty lines yield an empty slice).
// Returns nil if no lexer matches and the fallback shouldn't be used
// (e.g. binary-looking content) — caller falls back to plain rendering.
func highlightFile(path, content string) [][]segment {
	lexer := lexers.Match(path)
	if lexer == nil {
		// Analyse is expensive and rarely useful for unknown files; skip
		// and let the caller fall back to plain rendering.
		return nil
	}
	lexer = chroma.Coalesce(lexer)

	style := styles.Get(styleName)
	if style == nil {
		style = styles.Fallback
	}

	iterator, err := lexer.Tokenise(nil, content)
	if err != nil {
		return nil
	}

	var lines [][]segment
	var current []segment
	flush := func() {
		lines = append(lines, current)
		current = nil
	}

	for t := iterator(); t != chroma.EOF; t = iterator() {
		sty := tokenStyle(style, t.Type)
		// Split the token's value on newlines; each '\n' starts a new line.
		v := t.Value
		for v != "" {
			nl := strings.IndexByte(v, '\n')
			if nl < 0 {
				if v != "" {
					current = append(current, segment{text: v, style: sty})
				}
				break
			}
			if nl > 0 {
				current = append(current, segment{text: v[:nl], style: sty})
			}
			flush()
			v = v[nl+1:]
		}
	}
	// Trailing partial line (no final newline) → emit as a final line.
	if current != nil {
		flush()
	}
	return lines
}

// tokenStyle converts a chroma style entry for tokenType into a
// lipgloss style. Unset colours/flags are skipped.
func tokenStyle(style *chroma.Style, tokenType chroma.TokenType) lipgloss.Style {
	entry := style.Get(tokenType)
	s := lipgloss.NewStyle()
	if entry.Colour.IsSet() {
		s = s.Foreground(lipgloss.Color(entry.Colour.String()))
	}
	// Deliberately skip entry.Background — let the terminal's own bg
	// show through so cursor/selection/search highlights read cleanly.
	if entry.Bold == chroma.Yes {
		s = s.Bold(true)
	}
	if entry.Italic == chroma.Yes {
		s = s.Italic(true)
	}
	if entry.Underline == chroma.Yes {
		s = s.Underline(true)
	}
	return s
}

// renderSegmentsWithMatches renders a line built of pre-styled segments,
// overlaying search highlights on the given byte ranges of the original
// line text. ranges are in byte offsets of the concatenated segment
// text, matching what runSearch stored.
func renderSegmentsWithMatches(segs []segment, ranges []searchRange, currentIdx int) string {
	if len(segs) == 0 {
		return ""
	}
	if len(ranges) == 0 {
		var b strings.Builder
		for _, s := range segs {
			b.WriteString(s.style.Render(s.text))
		}
		return b.String()
	}
	var b strings.Builder
	pos := 0
	ri := 0
	for _, seg := range segs {
		segEnd := pos + len(seg.text)
		cur := pos
		for ri < len(ranges) && ranges[ri].end <= cur {
			ri++
		}
		for rj := ri; rj < len(ranges) && ranges[rj].start < segEnd; rj++ {
			r := ranges[rj]
			s := r.start
			if s < cur {
				s = cur
			}
			e := r.end
			if e > segEnd {
				e = segEnd
			}
			if s > cur {
				b.WriteString(seg.style.Render(seg.text[cur-pos : s-pos]))
			}
			hit := styleSearchHit
			if r.idx == currentIdx {
				hit = styleSearchCur
			}
			b.WriteString(hit.Render(seg.text[s-pos : e-pos]))
			cur = e
		}
		if cur < segEnd {
			b.WriteString(seg.style.Render(seg.text[cur-pos : segEnd-pos]))
		}
		pos = segEnd
	}
	return b.String()
}
