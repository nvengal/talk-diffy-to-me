package tui

import (
	"os"
	"strings"
	"testing"

	"github.com/nvengal/talk-diffy-to-me/internal/diff"
)

func TestFixtureRoundTrip(t *testing.T) {
	data, err := os.ReadFile("../../fixtures/sample.diff")
	if err != nil {
		t.Fatal(err)
	}
	d, err := diff.Parse(strings.NewReader(string(data)))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got, want := len(d.Files), 3; got != want {
		t.Fatalf("files: got %d want %d", got, want)
	}
	// Expect: greeting.go modified, math.go added, legacy.go deleted.
	statuses := []diff.FileStatus{
		diff.StatusModified, diff.StatusAdded, diff.StatusDeleted,
	}
	for i, f := range d.Files {
		if f.Status != statuses[i] {
			t.Errorf("file %d status: got %v want %v", i, f.Status, statuses[i])
		}
	}

	// Fabricate two comments:
	//   1) single-line on greeting.go, on the "+return nil" line
	//   2) multi-line range on math.go, covering the early-return branch
	greetingHunk := d.Files[0].Hunks[0]
	var singleLineIdx = -1
	for i, l := range greetingHunk.Lines {
		if l.Kind == '+' && strings.Contains(l.Text, "return nil") {
			singleLineIdx = i
			break
		}
	}
	if singleLineIdx == -1 {
		t.Fatal("couldn't find single-line target in greeting.go hunk")
	}

	mathHunk := d.Files[1].Hunks[0]
	var mathStart, mathEnd = -1, -1
	for i, l := range mathHunk.Lines {
		if strings.Contains(l.Text, "if b == 0") {
			mathStart = i
		}
		if strings.Contains(l.Text, `errors.New("div by zero")`) {
			mathEnd = i + 1 // include trailing '}' line
		}
	}
	if mathStart == -1 || mathEnd == -1 {
		t.Fatal("couldn't find range targets in math.go hunk")
	}

	comments := []Comment{
		buildComment(d, CommentKey{
			FileIdx: 0, HunkIdx: 0,
			StartLine: singleLineIdx, EndLine: singleLineIdx,
		}, "why return nil here? could we propagate?"),
		buildComment(d, CommentKey{
			FileIdx: 1, HunkIdx: 0,
			StartLine: mathStart, EndLine: mathEnd,
		}, "guard could be a sentinel error var"),
	}

	payload := BuildPayload(d, comments, "@-")
	t.Logf("\n--- payload ---\n%s--- end ---", payload)

	// Sanity checks
	mustContain := []string{
		"The following are review comments.",
		"Diff from: @-",
		"## greeting.go:10",    // single-line header
		"## math.go:6-8",       // range header
		"why return nil here?",
		"guard could be a sentinel error var",
		"```diff",
	}
	for _, s := range mustContain {
		if !strings.Contains(payload, s) {
			t.Errorf("payload missing %q", s)
		}
	}
}
