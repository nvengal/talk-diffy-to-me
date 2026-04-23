# talk-diffy-to-me — plan

A Go + Bubble Tea TUI that reads `jj diff --git` of the current revision,
lets you leave line-keyed (or range-keyed) comments, review/edit/delete
them, and ship them into a Claude Code CLI session running in another
zellij pane.

## Scope

- **In scope:** parsing `jj diff --git`, diff-review TUI with comments
  (single line *and* multi-line ranges), a review screen for queued
  comments, and a send action that paste-injects the bundled markup into
  a target zellij pane.
- **Out of scope:** chat UI, session management, persistence across runs,
  tests, config files, non-jj diff sources, non-zellij multiplexers.

Tone: personal tool, middle-ground quality — not throwaway, not polished.

## Stack

- Go 1.26+ (module `github.com/nvengal/talk-diffy-to-me`)
- Bubble Tea + Bubbles + Lipgloss (TUI)
- Shells out to `jj`, `zellij`
- No Claude Agent SDK dependency — Claude runs separately in its own pane

## Layout

```
talk-diffy-to-me/
├── go.mod                        module + deps
├── go.sum
├── README.md                     user-facing notes
├── PLAN.md                       this file
├── fixtures/                     dev fixtures (e.g. sample.diff)
├── cmd/
│   └── talk-diffy/
│       └── main.go               CLI entrypoint, stdlib flag parsing
└── internal/
    ├── diff/
    │   └── diff.go               parse `jj diff --git` → Files/Hunks/Lines
    ├── zellij/
    │   └── zellij.go             wrappers over `zellij action ...` + pane discovery
    └── tui/
        ├── app.go                top-level tea.Model, keybindings, payload bundling
        ├── diff_view.go          scrollable diff, cursor, visual-mode selection
        ├── comment_modal.go      comment editor with a preview of selected lines
        ├── review_modal.go       list of queued comments: edit / delete / send
        └── pane_modal.go         pane picker (list-panes scoped to focused tab)
```

## Behavior

### Launch

`talk-diffy`, run inside a zellij pane. Shells out to `jj diff --git` for
the current revision, parses it, renders in the main view. Empty diff
exits with a clear message.

### Diff view keybindings

- `j` / `k` — move cursor by line (skips file/hunk headers)
- `J` / `K` — jump to next / previous hunk
- `g` / `G` — top / bottom
- `v` — start / cancel a visual-mode selection anchored at the cursor;
  `j`/`k` extend; selection is clamped to the current hunk
- `c` — comment on the focused line or selection (opens comment modal)
- `d` — delete every comment whose range covers the focused line
- `s` — open the review screen (sending happens from there)
- `q` — quit

### Commenting

Pressing `c` opens a modal containing:

1. A one-line label (`Comment on path:line` or `…:start-end (N lines)`)
2. A preview box showing the selected diff line(s) with line-number
   gutter and diff coloring (`+` green, `-` red, context dim)
3. A `TextArea` for the comment body
4. A hint line

Modal keys:
- `enter` — save
- `ctrl+enter` / `ctrl+j` — insert a newline
- `ctrl+s` — save (fallback)
- `esc` — cancel

Saved comments are keyed by `(file_idx, hunk_idx, start_line, end_line)`
(single line has `start == end`). One comment per exact range; invoking
`c` on a range that already has a comment pre-fills the modal for
editing. A `▸` marker shows on any diff line whose `li` falls within
any comment's range.

### Review screen

`s` on the diff view opens `ReviewModal`: an `OptionList` of every
pending comment, each row showing `file:lines` and the first line of the
comment body. Keys:

- `j` / `k` or ↑ / ↓ — move through the list
- `enter` — send the focused comment only
- `ctrl+enter` / `shift+s` / `S` — send all (priority bindings so they
  override `OptionList`'s widget-level handling)
- `e` — edit the focused comment (re-opens `CommentModal`, pre-populated
  with the existing text and the same preview)
- `d` — delete the focused comment
- `esc` / `q` — back to the diff

After a successful send, the sent comments are removed from state. If
any comments remain, the review screen stays open; if the list empties,
it auto-dismisses.

### Target pane resolution

On the first send, talk-diffy discovers its Claude pane:

1. `zellij action list-panes --json` is parsed; plugin panes and
   non-selectable panes are skipped.
2. `$ZELLIJ_PANE_ID` (set by zellij in every pane's environment) is used
   to find talk-diffy's own pane and read its `tab_id`. Candidates are
   scoped to that tab, with talk-diffy's own pane excluded.
3. Each candidate's `title` and `pane_command` are matched
   case-insensitively against `"claude"`. If exactly one matches, it is
   auto-selected.
4. Otherwise `PaneModal` opens: an `OptionList` of candidates showing
   `id / tab_name / title / command / cwd`. The user picks with
   `enter`; `esc` cancels the send.

The resolved pane id is cached in memory for the rest of the session —
subsequent sends reuse it with no prompt.

If there are zero candidate panes in the tab, the status bar says
`no other panes in this tab`. Any `zellij` failure during discovery or
send surfaces in the status bar without crashing.

### Send

Once a pane is resolved, for the subset of comments being sent:

```
zellij action paste     --pane-id <target> -- <payload>
zellij action send-keys --pane-id <target> -- Enter
```

`paste` uses bracketed paste mode, so embedded newlines don't submit
mid-payload. `send-keys Enter` triggers the final submit.

## Message format

Every send is prefixed with a preamble that frames intent:

```
The following are review comments. Respond to questions within this
conversation (not in code comments). Make requested changes.
```

Then one `## <path>` heading per file with commented hunks. For each
comment, one bullet:

- **Single line:**
  ```
  - Line 39 (`return nil, err`): why return nil here?
  ```
  File and line number are given; the backticked source text grounds
  the comment. No surrounding hunk is included.

- **Line range:**
  ```
  - Lines 39-42: these three lines should be one call
    ```
    +return nil, err
    +log.Fatal(err)
    +return
    ```
  ```
  Range header + fenced source block indented two spaces so it reads as
  part of the list item.

Line numbers prefer the new-file side and fall back to the old-file
side. Comments sent individually produce a payload containing just that
one bullet (plus the preamble); send-all batches every pending comment
into one payload.

## Smoke test plan

Since the repo is often empty and there may be no real `jj` diff to
review:

1. Build a synthetic `jj diff --git` fixture (`fixtures/sample.diff`) —
   a small multi-file diff.
2. Run the TUI against it: `talk-diffy --fixture fixtures/sample.diff`.
3. Add a couple of comments (mix single-line and a visual-mode range),
   edit one in the review screen.
4. Press `s` with `--dry-run` to print the bundled payload to stdout
   instead of invoking zellij.
5. Eyeball the payload looks right.

`--fixture` and `--dry-run` are dev-only flags, not user-facing
features, and are hidden from `--help`.
