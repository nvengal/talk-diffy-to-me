# talk-diffy-to-me

A Neovim plugin for leaving line-keyed review comments on the current `jj`
revision — and on any file — and sending them to an LLM CLI (Claude Code,
Codex, …) running in another zellij pane.

Open the diff with `:Diffy`, comment with `:DiffyComment`, and send with
`:DiffySend`.

## Requirements

- Neovim 0.11+
- [`jj`](https://github.com/jj-vcs/jj) on `PATH`, with Neovim's working
  directory inside a `jj` workspace
- [`zellij`](https://zellij.dev) on `PATH`, with Neovim running in a zellij
  pane and the LLM CLI running in another pane of the same tab

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nvengal/talk-diffy-to-me",
  keys = {
    { "<leader>v", "", desc = "+review" },
    { "<leader>vv", "<cmd>Diffy<cr>", desc = "Review jj diff" },
    { "<leader>vc", ":DiffyComment<cr>", mode = { "n", "x" }, desc = "Comment" },
    { "<leader>vd", "<cmd>DiffyDelete<cr>", desc = "Delete comment" },
    { "<leader>vs", "<cmd>DiffySend<cr>", desc = "Send comment (review if several)" },
    { "<leader>vS", "<cmd>DiffySend!<cr>", desc = "Send all comments" },
    { "<leader>vr", "<cmd>DiffyReview<cr>", desc = "Review pending comments" },
    { "<leader>vp", "<cmd>DiffyRepick<cr>", desc = "Repick pane" },
  },
}
```

The keys are suggestions; the plugin itself only defines commands.

## Commands

| command                        | action                                                                 |
|--------------------------------|------------------------------------------------------------------------|
| `:Diffy [--from <rev>] [paths]`| open `jj diff --git` in a new tab, or return to it and refresh         |
| `:[range]DiffyComment`         | comment on the current line or range, in the diff or in any file       |
| `:DiffyDelete`                 | delete every comment covering the cursor line                          |
| `:DiffySend`                   | send the pending comment; with several, open the review popover        |
| `:DiffySend!`                  | send every pending comment                                             |
| `:DiffyReview`                 | open the review popover                                                |
| `:DiffyRepick`                 | forget the chosen zellij pane; ask again on the next send              |

A `▸` in the sign column marks every line covered by a pending comment.

### The diff (`:Diffy`)

`:Diffy` opens the working-copy change (`jj diff --git`, i.e. `@` against
`@-`) in a read-only `diffy://` buffer in its own tab. Paths narrow the
diff (`:Diffy lua/diffy plugin`).

Pass `--from <revset>` to review against another revision, PR-style:

```
:Diffy --from main         " whole branch vs main
:Diffy --from @--          " last two commits
:Diffy --from main@origin  " remote-tracking bookmark
```

This runs `jj diff --git -r '<revset>..@'` — every commit on `@`'s line
that isn't in `<revset>`, working copy included. Pick a `<revset>` in
`@`'s ancestry; truly divergent branches reach back to their common
ancestor and produce a large diff.

In the diff buffer, `gf` opens the file under the cursor at that line in
a new tab (or the tab already showing it). Removed lines jump to their
old-side line number.

### Refresh and re-anchoring

`:e` in the diff buffer — or `:Diffy` with the same arguments — re-runs
`jj diff` in place. Each diff comment is found again by the exact text
and kind of its lines, nearest to where it was, and follows the code
wherever it moved. If `jj` fails or reports no changes, the previous diff
stays.

File comments do the same whenever their file is read again: `:e!`,
`:checktime`/autoread after the file changes on disk, or reopening a
buffer you closed.

### Writing comments

`:DiffyComment` opens a small markdown float, already in insert mode.
Bodies can span lines. Commenting on exactly the lines of an existing
comment opens that comment for editing instead.

| key            | action |
|----------------|--------|
| `:w`, `<C-s>`  | save   |
| `q`            | cancel |

A blank body saves nothing.

### Review popover (`:DiffyReview`)

A float listing every pending comment, with the focused one previewed
below exactly as it will be sent.

| key            | action                                   |
|----------------|------------------------------------------|
| `j`/`k`        | move through the list                    |
| `s`            | send the focused comment                 |
| `S`            | send all                                 |
| `<CR>`         | edit the focused comment                 |
| `dd`           | delete the focused comment               |
| `gf`           | close the popover and jump to the comment|
| `q`, `<Esc>`   | close                                    |

### Choosing the pane

On the first send, diffy lists the other panes in its zellij tab and asks
which one to send to. If exactly one has `claude` in its title or command
(case-insensitive), it is picked without asking. The choice is remembered
until `:DiffyRepick`.

## Message format

Every send is prefixed with:

```
The following are review comments. Respond to questions within this conversation (not in code comments). Make requested changes.

Diff from: <ref>
```

`Diff from:` names the "from" side of each diff the comments came from —
the `--from` revset verbatim, or `@-` by default, plus any path filter.
It is omitted when every comment is on a file.

Then one `## path:lines` section per comment: the body, then a fenced
block of the selected lines. Diff comments use a ```diff block (keeping
`+`/`-` prefixes); file comments use a plain ``` block:

~~~
## greeting.go:10

why return nil here? could we propagate?

```diff
+	return nil
```

## internal/app.go:42

this probably wants a mutex

```
    m.comments = append(m.comments, c)
```
~~~

Diff line numbers prefer the new side, falling back to the old side for
`-` lines. Paths are relative to the `jj` workspace root; a file outside
it is named by its full path.

## Development

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s
busted runner. With plenary installed by lazy.nvim (or `PLENARY_DIR`
pointing at a checkout), from the repo root:

```
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua', sequential=true}"
```

`jj` and `zellij` are faked on `PATH` by the tests; neither is needed to
run them.
