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
	fs.StringVar(&fixturePath, "fixture", "", "")
	fs.BoolVar(&dryRun, "dry-run", false, "")
	fs.StringVar(&fromRef, "from", "", "")

	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: diffy [--from <ref>] [paths...]")
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "Run inside a zellij pane. Reads `jj diff --git` for the current")
		fmt.Fprintln(os.Stderr, "revision, opens a TUI to leave comments, and ships them into a")
		fmt.Fprintln(os.Stderr, "Claude Code CLI session running in another zellij pane.")
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "With --from <ref>, runs `git diff <ref>...HEAD` (PR-review style;")
		fmt.Fprintln(os.Stderr, "e.g. `diffy --from main` or `diffy --from HEAD^`). Plain git refs")
		fmt.Fprintln(os.Stderr, "go straight to git; jj revsets containing `@` (like `main@origin`")
		fmt.Fprintln(os.Stderr, "or `@-`) are resolved via jj first.")
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

	if fromRef != "" && fixturePath != "" {
		fmt.Fprintln(os.Stderr, "--from cannot be combined with --fixture")
		os.Exit(2)
	}

	if fixturePath == "" {
		// Path filters: in jj mode they're forwarded to `jj diff` (so they
		// stay relative to the user's CWD); in --from / fixture modes
		// they're applied as post-parse filters and need to be relative to
		// the workspace root we'll be sitting in.
		if fromRef == "" {
			for i, p := range paths {
				abs, err := filepath.Abs(p)
				if err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(1)
				}
				paths[i] = abs
			}
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
		if (fixturePath != "" || fromRef != "") && len(paths) > 0 {
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
// preamble — the ref the user supplied (unmanipulated, jj or git
// either) for --from mode, "@-" for the default jj-current-revision
// mode, and a fixture-file label for fixture mode.
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
	if fromRef != "" {
		return gitDiff(fromRef)
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

// gitDiff runs `git diff --no-color <ref>...HEAD` — the 3-dot form, so
// git itself computes the merge-base of <ref> and HEAD. Committed
// changes only. If <ref> looks like a jj revset (contains `@`), it's
// resolved to a commit ID via jj first.
func gitDiff(ref string) ([]byte, error) {
	resolved, err := resolveRef(ref)
	if err != nil {
		return nil, err
	}
	spec := resolved + "...HEAD"
	cmd := exec.Command("git", "diff", "--no-color", spec)
	out, err := cmd.Output()
	if err != nil {
		var stderr string
		if ee, ok := err.(*exec.ExitError); ok {
			stderr = strings.TrimSpace(string(ee.Stderr))
		}
		if stderr != "" {
			return nil, fmt.Errorf("git diff %s: %s", spec, stderr)
		}
		return nil, fmt.Errorf("git diff %s: %w", spec, err)
	}
	return out, nil
}

// resolveRef passes plain git refs through as-is, but routes jj-style
// revsets (anything containing `@` — `main@origin`, `@-`, etc.) through
// `jj log` to get a single commit ID that git understands.
func resolveRef(ref string) (string, error) {
	if !strings.Contains(ref, "@") {
		return ref, nil
	}
	cmd := exec.Command("jj", "log", "--no-graph", "-r", ref, "-T", `commit_id ++ "\n"`)
	out, err := cmd.Output()
	if err != nil {
		var stderr string
		if ee, ok := err.(*exec.ExitError); ok {
			stderr = strings.TrimSpace(string(ee.Stderr))
		}
		if stderr != "" {
			return "", fmt.Errorf("resolve %q via jj: %s", ref, stderr)
		}
		return "", fmt.Errorf("resolve %q via jj: %w", ref, err)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	var ids []string
	for _, l := range lines {
		if l = strings.TrimSpace(l); l != "" {
			ids = append(ids, l)
		}
	}
	if len(ids) == 0 {
		return "", fmt.Errorf("revset %q resolved to no commits", ref)
	}
	if len(ids) > 1 {
		return "", fmt.Errorf("revset %q resolved to %d commits; --from needs exactly one", ref, len(ids))
	}
	return ids[0], nil
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
