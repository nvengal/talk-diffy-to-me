package tui

import (
	"testing"
)

func TestHighlightFileLineCount(t *testing.T) {
	content := "package main\n\nfunc f() int {\n\treturn 42\n}\n"
	segs := highlightFile("foo.go", content)
	lines := splitFileLines(content)
	if len(segs) != len(lines) {
		t.Fatalf("segments lines=%d, split lines=%d", len(segs), len(lines))
	}
	for i, sl := range segs {
		var concat string
		for _, s := range sl {
			concat += s.text
		}
		if concat != lines[i] {
			t.Errorf("line %d: concat %q != %q", i, concat, lines[i])
		}
	}
}
