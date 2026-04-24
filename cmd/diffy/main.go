package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/nvengal/talk-diffy-to-me/internal/diff"
	"github.com/nvengal/talk-diffy-to-me/internal/tui"
)

func main() {
	fs := flag.NewFlagSet("diffy", flag.ContinueOnError)
	fs.SetOutput(io.Discard) // we print usage ourselves

	var fixturePath string
	var dryRun bool
	fs.StringVar(&fixturePath, "fixture", "", "")
	fs.BoolVar(&dryRun, "dry-run", false, "")

	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: diffy [paths...]")
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "Run inside a zellij pane. Reads `jj diff --git` for the current")
		fmt.Fprintln(os.Stderr, "revision, opens a TUI to leave comments, and ships them into a")
		fmt.Fprintln(os.Stderr, "Claude Code CLI session running in another zellij pane.")
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "Positional paths filter the diff (like `git diff path/...`):")
		fmt.Fprintln(os.Stderr, "exact file match or directory prefix.")
	}

	if err := fs.Parse(os.Args[1:]); err != nil {
		// flag.Parse already called fs.Usage for --help / unknown flags.
		if err == flag.ErrHelp {
			os.Exit(0)
		}
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	paths := fs.Args()

	if fixturePath == "" {
		// Resolve any path filters against the user's original CWD before
		// chdir, so jj still sees the files they meant.
		for i, p := range paths {
			abs, err := filepath.Abs(p)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			paths[i] = abs
		}
		if err := chdirToWorkspaceRoot(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}

	loader := func() (*diff.Diff, error) {
		src, err := loadSource(fixturePath, paths)
		if err != nil {
			return nil, err
		}
		d, err := diff.Parse(bytes.NewReader(src))
		if err != nil {
			return nil, fmt.Errorf("parse diff: %w", err)
		}
		if fixturePath != "" && len(paths) > 0 {
			d = filterDiff(d, paths)
		}
		return d, nil
	}

	d, err := loader()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	if err := tui.Run(d, dryRun, loader); err != nil {
		fmt.Fprintf(os.Stderr, "tui: %v\n", err)
		os.Exit(1)
	}
}

// chdirToWorkspaceRoot moves into the jj workspace root so that paths
// from `jj diff --git` (which are workspace-root-relative) resolve
// correctly when diffy is invoked from a subdirectory.
func chdirToWorkspaceRoot() error {
	out, err := exec.Command("jj", "workspace", "root").Output()
	if err != nil {
		return fmt.Errorf("jj workspace root: %w", err)
	}
	root := strings.TrimSpace(string(out))
	if root == "" {
		return nil
	}
	if err := os.Chdir(root); err != nil {
		return fmt.Errorf("chdir %s: %w", root, err)
	}
	return nil
}

func loadSource(fixturePath string, paths []string) ([]byte, error) {
	if fixturePath != "" {
		data, err := os.ReadFile(fixturePath)
		if err != nil {
			return nil, fmt.Errorf("read fixture: %w", err)
		}
		return data, nil
	}
	args := []string{"diff", "--git"}
	if len(paths) > 0 {
		args = append(args, "--")
		args = append(args, paths...)
	}
	out, err := exec.Command("jj", args...).Output()
	if err != nil {
		return nil, fmt.Errorf("jj diff --git: %w", err)
	}
	return out, nil
}

func filterDiff(d *diff.Diff, paths []string) *diff.Diff {
	keep := make([]diff.File, 0, len(d.Files))
	for _, f := range d.Files {
		p := f.DisplayPath()
		for _, filter := range paths {
			if p == filter || strings.HasPrefix(p, strings.TrimSuffix(filter, "/")+"/") {
				keep = append(keep, f)
				break
			}
		}
	}
	return &diff.Diff{Files: keep}
}
