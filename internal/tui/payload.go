package tui

import (
	"fmt"
	"strings"

	"github.com/nvengal/talk-diffy-to-me/internal/diff"
)

const preamble = `The following are review comments. Respond to questions within this conversation (not in code comments). Make requested changes.`

// BuildPayload renders the bundled markdown payload: one `## file:lines`
// section per comment, followed by the comment body and a fenced diff
// block showing the selected lines. Comments are emitted in the order
// they were authored. The content comes from each comment's snapshot,
// so orphaned comments still render their original context.
func BuildPayload(_ *diff.Diff, comments []Comment) string {
	var b strings.Builder
	b.WriteString(preamble)
	b.WriteByte('\n')
	for _, c := range comments {
		writeSection(&b, c)
	}
	return b.String()
}

func writeSection(b *strings.Builder, c Comment) {
	span := fmt.Sprintf("%d", c.DisplayStart)
	if c.DisplayStart != c.DisplayEnd {
		span = fmt.Sprintf("%d-%d", c.DisplayStart, c.DisplayEnd)
	}
	fmt.Fprintf(b, "\n## %s:%s\n\n", c.Path, span)
	b.WriteString(c.Body)
	b.WriteString("\n\n")
	switch c.Kind {
	case CommentFile:
		b.WriteString("```\n")
		for _, l := range c.Snapshot {
			b.WriteString(l.Text + "\n")
		}
		b.WriteString("```\n")
	default:
		b.WriteString("```diff\n")
		for _, l := range c.Snapshot {
			b.WriteString(string(l.Kind) + l.Text + "\n")
		}
		b.WriteString("```\n")
	}
}
