package diff

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

type FileStatus int

const (
	StatusModified FileStatus = iota
	StatusAdded
	StatusDeleted
	StatusRenamed
	StatusCopied
)

func (s FileStatus) String() string {
	switch s {
	case StatusAdded:
		return "added"
	case StatusDeleted:
		return "deleted"
	case StatusRenamed:
		return "renamed"
	case StatusCopied:
		return "copied"
	default:
		return "modified"
	}
}

type Line struct {
	Kind    byte
	Text    string
	OldLine int
	NewLine int
}

type Hunk struct {
	OldStart, OldCount int
	NewStart, NewCount int
	Section            string
	Lines              []Line
}

type File struct {
	OldPath string
	NewPath string
	Status  FileStatus
	Hunks   []Hunk
}

func (f File) DisplayPath() string {
	if f.NewPath != "" && f.NewPath != "/dev/null" {
		return f.NewPath
	}
	return f.OldPath
}

type Diff struct {
	Files []File
}

func Parse(r io.Reader) (*Diff, error) {
	s := bufio.NewScanner(r)
	s.Buffer(make([]byte, 64*1024), 4*1024*1024)

	d := &Diff{}
	var cur *File
	var hunk *Hunk
	var oldLine, newLine int

	finishHunk := func() {
		if hunk != nil && cur != nil {
			cur.Hunks = append(cur.Hunks, *hunk)
			hunk = nil
		}
	}
	finishFile := func() {
		finishHunk()
		if cur != nil {
			d.Files = append(d.Files, *cur)
			cur = nil
		}
	}

	for s.Scan() {
		line := s.Text()

		if strings.HasPrefix(line, "diff --git ") {
			finishFile()
			cur = &File{Status: StatusModified}
			rest := strings.TrimPrefix(line, "diff --git ")
			old, new, ok := splitDiffPaths(rest)
			if !ok {
				return nil, fmt.Errorf("bad diff header: %q", line)
			}
			cur.OldPath, cur.NewPath = old, new
			continue
		}

		if cur == nil {
			if strings.TrimSpace(line) == "" {
				continue
			}
			return nil, fmt.Errorf("unexpected line before diff header: %q", line)
		}

		// file-level metadata
		switch {
		case strings.HasPrefix(line, "new file mode"):
			cur.Status = StatusAdded
			continue
		case strings.HasPrefix(line, "deleted file mode"):
			cur.Status = StatusDeleted
			continue
		case strings.HasPrefix(line, "rename from "):
			cur.Status = StatusRenamed
			cur.OldPath = strings.TrimPrefix(line, "rename from ")
			continue
		case strings.HasPrefix(line, "rename to "):
			cur.NewPath = strings.TrimPrefix(line, "rename to ")
			continue
		case strings.HasPrefix(line, "copy from "):
			cur.Status = StatusCopied
			cur.OldPath = strings.TrimPrefix(line, "copy from ")
			continue
		case strings.HasPrefix(line, "copy to "):
			cur.NewPath = strings.TrimPrefix(line, "copy to ")
			continue
		case strings.HasPrefix(line, "index "),
			strings.HasPrefix(line, "old mode "),
			strings.HasPrefix(line, "new mode "),
			strings.HasPrefix(line, "similarity index "),
			strings.HasPrefix(line, "dissimilarity index "):
			continue
		case strings.HasPrefix(line, "--- "), strings.HasPrefix(line, "+++ "):
			continue
		case strings.HasPrefix(line, "Binary files "):
			continue
		case strings.HasPrefix(line, "@@"):
			finishHunk()
			h, err := parseHunkHeader(line)
			if err != nil {
				return nil, err
			}
			hunk = h
			oldLine = h.OldStart
			newLine = h.NewStart
			continue
		}

		if hunk == nil {
			return nil, fmt.Errorf("unexpected line outside hunk: %q", line)
		}

		if len(line) == 0 {
			hunk.Lines = append(hunk.Lines, Line{Kind: ' ', Text: "", OldLine: oldLine, NewLine: newLine})
			oldLine++
			newLine++
			continue
		}

		kind := line[0]
		text := line[1:]
		switch kind {
		case ' ':
			hunk.Lines = append(hunk.Lines, Line{Kind: ' ', Text: text, OldLine: oldLine, NewLine: newLine})
			oldLine++
			newLine++
		case '+':
			hunk.Lines = append(hunk.Lines, Line{Kind: '+', Text: text, NewLine: newLine})
			newLine++
		case '-':
			hunk.Lines = append(hunk.Lines, Line{Kind: '-', Text: text, OldLine: oldLine})
			oldLine++
		case '\\':
			continue
		default:
			return nil, fmt.Errorf("unexpected line in hunk: %q", line)
		}
	}
	if err := s.Err(); err != nil {
		return nil, err
	}
	finishFile()
	return d, nil
}

func splitDiffPaths(rest string) (string, string, bool) {
	idx := strings.LastIndex(rest, " b/")
	if idx < 0 {
		return "", "", false
	}
	left := rest[:idx]
	right := rest[idx+1:]
	if !strings.HasPrefix(left, "a/") || !strings.HasPrefix(right, "b/") {
		return "", "", false
	}
	return left[2:], right[2:], true
}

func parseHunkHeader(line string) (*Hunk, error) {
	rest := strings.TrimPrefix(line, "@@")
	endIdx := strings.Index(rest, "@@")
	if endIdx < 0 {
		return nil, fmt.Errorf("bad hunk header: %q", line)
	}
	ranges := strings.TrimSpace(rest[:endIdx])
	section := strings.TrimSpace(rest[endIdx+2:])
	parts := strings.Fields(ranges)
	if len(parts) != 2 || !strings.HasPrefix(parts[0], "-") || !strings.HasPrefix(parts[1], "+") {
		return nil, fmt.Errorf("bad hunk header: %q", line)
	}
	oldStart, oldCount, err := parseRange(parts[0][1:])
	if err != nil {
		return nil, fmt.Errorf("bad hunk header %q: %w", line, err)
	}
	newStart, newCount, err := parseRange(parts[1][1:])
	if err != nil {
		return nil, fmt.Errorf("bad hunk header %q: %w", line, err)
	}
	return &Hunk{
		OldStart: oldStart, OldCount: oldCount,
		NewStart: newStart, NewCount: newCount,
		Section: section,
	}, nil
}

func parseRange(s string) (int, int, error) {
	if i := strings.Index(s, ","); i >= 0 {
		start, err := strconv.Atoi(s[:i])
		if err != nil {
			return 0, 0, err
		}
		count, err := strconv.Atoi(s[i+1:])
		if err != nil {
			return 0, 0, err
		}
		return start, count, nil
	}
	start, err := strconv.Atoi(s)
	if err != nil {
		return 0, 0, err
	}
	return start, 1, nil
}
