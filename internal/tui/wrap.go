package tui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// textChunk is a slice of a longer string, carrying the byte offset of
// the slice within the original. Used when wrapping content so that
// per-line annotations (search matches, syntax segments) can be
// re-mapped onto each visual chunk.
type textChunk struct {
	text      string
	byteStart int
}

// wrapByRunes splits s into chunks of at most w runes each, returning
// each chunk together with its byte offset into the original string.
// Always returns at least one chunk (empty when s is empty). For w<=0
// wrapping is disabled and the original is returned as a single chunk.
func wrapByRunes(s string, w int) []textChunk {
	if w <= 0 {
		return []textChunk{{text: s}}
	}
	if s == "" {
		return []textChunk{{text: ""}}
	}
	var out []textChunk
	chunkStart := 0
	chunkRunes := 0
	for i := range s {
		if chunkRunes == w {
			out = append(out, textChunk{text: s[chunkStart:i], byteStart: chunkStart})
			chunkStart = i
			chunkRunes = 0
		}
		chunkRunes++
	}
	out = append(out, textChunk{text: s[chunkStart:], byteStart: chunkStart})
	return out
}

// sliceSegments returns the run of segments covering byte range
// [byteStart, byteEnd) over the concatenated segment text. Segments
// that straddle the boundary are split.
func sliceSegments(segs []segment, byteStart, byteEnd int) []segment {
	if byteEnd <= byteStart {
		return nil
	}
	var out []segment
	pos := 0
	for _, sg := range segs {
		segEnd := pos + len(sg.text)
		if segEnd <= byteStart {
			pos = segEnd
			continue
		}
		if pos >= byteEnd {
			break
		}
		s := byteStart
		if s < pos {
			s = pos
		}
		e := byteEnd
		if e > segEnd {
			e = segEnd
		}
		out = append(out, segment{text: sg.text[s-pos : e-pos], style: sg.style})
		pos = segEnd
	}
	return out
}

// sliceRanges returns the search ranges that fall inside [byteStart,
// byteEnd), with offsets remapped to be relative to byteStart.
func sliceRanges(ranges []searchRange, byteStart, byteEnd int) []searchRange {
	if len(ranges) == 0 || byteEnd <= byteStart {
		return nil
	}
	var out []searchRange
	for _, r := range ranges {
		if r.end <= byteStart || r.start >= byteEnd {
			continue
		}
		s := r.start
		if s < byteStart {
			s = byteStart
		}
		e := r.end
		if e > byteEnd {
			e = byteEnd
		}
		out = append(out, searchRange{start: s - byteStart, end: e - byteStart, idx: r.idx})
	}
	return out
}

// styleFirstLine applies st to the first visual line only (padded to
// width); continuation rows pass through untouched. Keeps cursor /
// selection indicators tied to one visual bar per logical row even
// when the row wraps.
func styleFirstLine(raw string, st lipgloss.Style, width int) string {
	nl := strings.IndexByte(raw, '\n')
	if nl < 0 {
		return st.Render(padRight(raw, width))
	}
	return st.Render(padRight(raw[:nl], width)) + raw[nl:]
}

// visualLineCount returns the number of \n-separated visual lines in s
// (always >= 1 even for empty strings, matching how the viewport
// renders one line per row).
func visualLineCount(s string) int {
	return strings.Count(s, "\n") + 1
}
