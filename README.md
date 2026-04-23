# talk-diffy-to-me

Textual TUI for reviewing a `jj diff` and piping line-keyed comments into a
Claude Code CLI running in another zellij pane.

## Install

```
uv sync
```

## Use

Run inside a zellij session that also has a Claude Code pane open:

```
talk-diffy
```

### Keys

| key | action |
|-----|--------|
| `j` / `k` | move cursor by line |
| `J` / `K` | jump to next / previous hunk |
| `g` / `G` | top / bottom |
| `v` | start / cancel a visual-mode selection (extend with `j`/`k`; confined to the current hunk) |
| `c` | comment on the focused line or selection (`enter` to save, `ctrl+enter` / `ctrl+j` for a newline, `esc` to cancel) |
| `d` | delete any comment whose range covers the focused line |
| `s` | open the review screen (send from there) |
| `q` | quit |

### Review screen

`s` opens a list of every pending comment. From there:

| key | action |
|-----|--------|
| `j` / `k` or ↑ / ↓ | move through the list |
| `enter` | send the focused comment |
| `ctrl+enter` (fallback: `shift+s`) | send them all |
| `e` | edit the focused comment's text |
| `d` | delete the focused comment |
| `esc` / `q` | back to the diff |

Sent comments are removed from the list. The screen stays open until every
comment has been sent or deleted, then closes automatically.

### Pane picker

The first time you press `s`, talk-diffy looks at the panes in the
currently focused zellij tab (via `zellij action list-panes --json`):

- exactly one pane whose title or running command contains `claude` →
  auto-selected
- otherwise → picker listing the tab's panes

The pick is remembered for the rest of the session — subsequent sends go
straight there. If talk-diffy can't figure out its own pane (no
`$ZELLIJ_PANE_ID`), the picker falls back to listing every pane.

### Dev flags

- `--fixture <path>` — read diff from file instead of `jj diff --git`
- `--dry-run` — on send, print the bundled payload to stdout instead of
  invoking `zellij`
