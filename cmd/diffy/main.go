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
	var fromRef string
	var openPath string
	fs.StringVar(&fixturePath, "fixture", "", "")
	fs.BoolVar(&dryRun, "dry-run", false, "")
	fs.StringVar(&fromRef, "from", "", "")
	fs.StringVar(&openPath, "open", "", "")

	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: diffy [--from <revset>] [paths...]")
		fmt.Fprintln(os.Stderr, "       diffy --open <file>")
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "Run inside a zellij pane. Reads `jj diff --git` for the current")
		fmt.Fprintln(os.Stderr, "revision, opens a TUI to leave comments, and ships them into a")
		fmt.Fprintln(os.Stderr, "Claude Code CLI session running in another zellij pane.")
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "With --from <revset>, runs `jj diff --git -r '<revset>..@'`")
		fmt.Fprintln(os.Stderr, "(PR-review style; e.g. `diffy --from main` or `diffy --from main@origin`).")
		fmt.Fprintln(os.Stderr, "Any jj revset works.")
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "With --open <file>, skips diff loading and opens the file directly")
		fmt.Fprintln(os.Stderr, "for commenting. Works on any file, even outside a jj repo.")
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "Positional paths filter the diff: exact file match or directory prefix.")
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

	if fromRef != "" && fixturePath != "" {
		fmt.Fprintln(os.Stderr, "--from cannot be combined with --fixture")
		os.Exit(2)
	}
	if openPath != "" && (fromRef != "" || fixturePath != "" || len(paths) > 0) {
		fmt.Fprintln(os.Stderr, "--open cannot be combined with --from, --fixture, or path arguments")
		os.Exit(2)
	}

	if openPath != "" {
		abs, err := filepath.Abs(openPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if err := tui.RunOpen(abs, dryRun); err != nil {
			fmt.Fprintf(os.Stderr, "tui: %v\n", err)
			os.Exit(1)
		}
		return
	}

	if fixturePath == "" {
		// Paths are forwarded to `jj diff`; absolutize before chdir so they
		// stay relative to the user's CWD, not the workspace root.
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
		src, err := loadSource(fixturePath, fromRef, paths)
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

	source := describeSource(fixturePath, fromRef, paths)

	if err := tui.Run(d, dryRun, loader, source); err != nil {
		fmt.Fprintf(os.Stderr, "tui: %v\n", err)
		os.Exit(1)
	}
}

// describeSource builds the "from" side of the diff for the payload
// preamble — the revset the user supplied (verbatim) for --from mode,
// "@-" for the default jj-current-revision mode, and a fixture-file
// label for fixture mode.
func describeSource(fixturePath, fromRef string, paths []string) string {
	var base string
	switch {
	case fromRef != "":
		base = fromRef
	case fixturePath != "":
		base = fmt.Sprintf("fixture file %q", fixturePath)
	default:
		base = "@-"
	}
	if len(paths) > 0 {
		base += fmt.Sprintf(" (filtered to: %s)", strings.Join(paths, ", "))
	}
	return base
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

func loadSource(fixturePath, fromRef string, paths []string) ([]byte, error) {
	if fixturePath != "" {
		data, err := os.ReadFile(fixturePath)
		if err != nil {
			return nil, fmt.Errorf("read fixture: %w", err)
		}
		return data, nil
	}
	args := []string{"diff", "--git"}
	if fromRef != "" {
		args = append(args, "-r", fmt.Sprintf("%s..@", fromRef))
	}
	if len(paths) > 0 {
		args = append(args, "--")
		args = append(args, paths...)
	}
	out, err := exec.Command("jj", args...).Output()
	if err != nil {
		var stderr string
		if ee, ok := err.(*exec.ExitError); ok {
			stderr = strings.TrimSpace(string(ee.Stderr))
		}
		if stderr != "" {
			return nil, fmt.Errorf("jj %s: %s", strings.Join(args, " "), stderr)
		}
		return nil, fmt.Errorf("jj %s: %w", strings.Join(args, " "), err)
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
