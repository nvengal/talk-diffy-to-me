# talk-diffy-to-me

A TUI for leaving line-keyed review comments on the current `jj` revision
— and on any tracked file — and shipping them into a Claude Code CLI
session running in another zellij pane.

You review `jj diff --git`, press `c` on a line (or over a visual-mode
range), type a comment, queue up a few more, then press `s` to bundle
and paste them into the Claude pane. You can also open any tracked file
(`o` on a diff row to jump to that file; `O` for a fuzzy picker),
comment on arbitrary lines, search (`/`), and edit in `$EDITOR` (`e`).

## Requirements

- Go 1.26+ (to build)
- [`jj`](https://github.com/jj-vcs/jj) on `PATH`
- [`zellij`](https://zellij.dev) on `PATH`
- Run from inside a zellij pane, in a `jj` working copy

An empty diff is fine — talk-diffy opens the file picker on launch so you
can still leave comments on arbitrary files.

## Install

```
go install github.com/nvengal/talk-diffy-to-me/cmd/talk-diffy@latest
```

Or build from a checkout:

```
git clone https://github.com/nvengal/talk-diffy-to-me
cd talk-diffy-to-me
go build -o talk-diffy ./cmd/talk-diffy
```

## Usage

Open a zellij tab with (at least) two panes: one running `claude` and one
where you'll run `talk-diffy`. From the talk-diffy pane:

```
talk-diffy
```

Pass paths to narrow the diff (like `git diff path/...`):

```
talk-diffy internal/tui
talk-diffy internal/tui/app.go cmd/talk-diffy/main.go
```

Paths are forwarded to `jj diff --git -- <paths>`; an exact file match
or a directory prefix will do.

### Diff view

| key      | action                                                    |
|----------|-----------------------------------------------------------|
| `j`/`k`  | move cursor by line (skips headers)                       |
| `J`/`K`  | jump to next / previous hunk                              |
| `g`/`G`  | top / bottom                                              |
| `v`      | toggle visual-mode selection (clamped to hunk)            |
| `c`      | new comment on the current line or selection              |
| `enter`  | edit an existing comment covering the cursor              |
| `d`      | delete every comment covering the focused line            |
| `s`      | open the review screen                                    |
| `/`      | search; `n`/`N` jump next/prev; `esc` clears highlights   |
| `o`      | open file under cursor in file view (jumps to that line)  |
| `O`      | fuzzy file picker                                         |
| `e`      | open file under cursor in `$EDITOR` (at the cursor line)  |
| `r`      | refresh: re-run `jj diff --git`, re-anchor comments       |
| `q`      | quit                                                      |

A `▸` in the gutter marks any line covered by a pending comment.

### File view

Opened via `o`/`O` from the diff view (or auto-opened on launch when the
diff is empty). Syntax-highlighted via
[chroma](https://github.com/alecthomas/chroma) (nord theme).

| key      | action                                                     |
|----------|------------------------------------------------------------|
| `j`/`k`  | move cursor by line                                        |
| `g`/`G`  | top / bottom                                               |
| `v`      | toggle visual-mode selection                               |
| `c`      | new comment on the current line or selection               |
| `enter`  | edit an existing comment covering the cursor               |
| `d`      | delete every comment covering the focused line             |
| `s`      | open the review screen                                     |
| `/`      | search (Go regex, smart-case); `n`/`N` next/prev           |
| `esc`    | clear active search; if none, leave file view              |
| `O`      | fuzzy file picker (switches to another file)               |
| `e`      | open current file in `$EDITOR` (at the cursor line)        |
| `r`      | reload file from disk, re-anchor file comments             |
| `q`      | back to diff view (or picker if launched with no diff)     |

### Refresh

Press `r` in the diff view to re-run `jj diff --git` (or re-read the
fixture) and swap in the new diff. Each pending comment is re-anchored
to the new diff by matching its snapshot of line content against hunks
in the same file; successful matches follow the code wherever it moved.
Comments whose anchor can't be found are flagged as `[orphan]` in the
review list — the body and original context are preserved and still
sendable; only the `▸` marker in the diff view is dropped.

### Comment modal

| key         | action         |
|-------------|----------------|
| `enter`     | save           |
| `alt+enter` | insert newline |
| `esc`       | cancel         |

Opening `c` on a range that already has an exact-match comment pre-fills
the modal so you can edit it.

### Review screen

| key             | action                         |
|-----------------|--------------------------------|
| `j`/`k`, arrows | move through the list          |
| `s`             | send the focused comment only  |
| `S`             | send all                       |
| `enter`         | edit the focused comment       |
| `d`             | delete the focused comment     |
| `esc`, `q`      | back to the diff               |

On the first send, talk-diffy scans `zellij action list-panes` for
candidates in the current tab, auto-picks the one whose title or command
contains `claude` (case-insensitive) if there's exactly one, and
otherwise opens a picker. The resolved pane id is cached for the rest of
the session.

## Message format

Every send is prefixed with:

```
The following are review comments. Respond to questions within this conversation (not in code comments). Make requested changes.
```

Followed by one `## path:lines` section per comment, with the comment
body, then a fenced block showing the selected lines. Diff-anchored
comments use a ```diff block (preserving `+`/`-` prefixes); file-anchored
comments use a plain ``` block (verbatim file lines):

~~~
## greeting.go:10

why return nil here? could we propagate?

```diff
+	return nil
```

## math.go:6-8

guard could be a sentinel error var

```diff
+	if b == 0 {
+		return 0, errors.New("div by zero")
+	}
```

## internal/tui/app.go:42

this probably wants a mutex

```
    m.comments = append(m.comments, c)
```
~~~

For diff comments, line numbers prefer the new-file side, falling back to
the old-file side for `-` lines. File comments use absolute line numbers.

## Dev flags

Hidden from `--help`:

- `--fixture <path>` — read the diff from a file instead of invoking `jj`
- `--dry-run` — print the bundled payload to stdout instead of invoking
  `zellij`

Example:

```
talk-diffy --fixture fixtures/sample.diff --dry-run
```

## Scope

- In: parsing `jj diff --git`, diff-review TUI with single-line and
  multi-line comments, opening arbitrary `jj`-tracked files for
  commenting (with fuzzy picker, search, syntax highlighting, and
  `$EDITOR` integration), review screen, paste-injection into a zellij
  pane.
- Out: chat UI, session state, persistence across runs, non-jj diff
  sources, non-zellij multiplexers.
