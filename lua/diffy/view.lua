local comments = require("diffy.comments")
local diff = require("diffy.diff")
local notify = require("diffy.notify")
local tree = require("diffy.tree")

local M = {}

---@class diffy.ViewOpts
---@field from? string revset to review against
---@field paths string[]

---@class diffy.View
---@field opts diffy.ViewOpts
---@field source string
---@field root string jj workspace root, which diff paths are relative to
---@field lines string[] the diff as last shown
---@field rows diffy.Row[]
---@field files diffy.File[]
---@field narrow? string what the file tree last narrowed the diff to; nil until it first does
---@field tree? integer the file tree buffer
---@field entries diffy.TreeLine[] the file tree as last rendered

---@class diffy.Placement
---@field win integer
---@field row integer cursor row
---@field height integer cursor row's height on screen, counted from the top line

---@type table<integer, diffy.View>
local views = {}

---@param opts diffy.ViewOpts
local function describe_source(opts)
  local base = opts.from or "@-"
  if #opts.paths > 0 then
    base = base .. " (filtered to: " .. table.concat(opts.paths, ", ") .. ")"
  end
  return base
end

---@param opts diffy.ViewOpts
---@return string[]? lines the diff, or nil after telling the user why there is none
local function load(opts)
  local cmd = { "jj", "diff", "--git" }
  if opts.from then
    vim.list_extend(cmd, { "--from", ("fork_point((%s) | @)"):format(opts.from) })
  end
  if #opts.paths > 0 then
    table.insert(cmd, "--")
    vim.list_extend(cmd, opts.paths)
  end
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    return notify(table.concat(cmd, " ") .. ": " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
  end
  local lines = vim.split(res.stdout, "\n", { plain = true, trimempty = true })
  if #lines == 0 then
    return notify("no changes", vim.log.levels.WARN)
  end
  return lines
end

---@param buf integer
---@return diffy.Placement[]
local function placements(buf)
  return vim.tbl_map(function(win)
    return vim.api.nvim_win_call(win, function()
      return { win = win, row = vim.fn.line("."), height = vim.fn.line(".") - vim.fn.line("w0") }
    end)
  end, vim.fn.win_findbuf(buf))
end

---@param buf integer
---@param mode string|string[]
---@param lhs string
---@param rhs string|function
---@param desc string
local function map(buf, mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, desc = desc })
end

---@param buf integer
---@return integer? win showing `buf` in the current tab
local function in_tab(buf)
  return vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(function(win)
    return vim.api.nvim_win_get_buf(win) == buf
  end)
end

---@param buf integer
local function render_tree(buf)
  local v = views[buf]
  if not (v.tree and vim.api.nvim_buf_is_valid(v.tree)) then
    return
  end
  v.entries = tree.build(v.files, v.source, comments.all())
  vim.bo[v.tree].modifiable = true
  vim.api.nvim_buf_set_lines(v.tree, 0, -1, false, vim.tbl_map(function(e)
    return e.text
  end, v.entries))
  vim.bo[v.tree].modifiable = false
  local width = 0
  for _, e in ipairs(v.entries) do
    width = math.max(width, vim.fn.strdisplaywidth(e.text))
  end
  for _, win in ipairs(vim.fn.win_findbuf(v.tree)) do
    vim.api.nvim_win_set_width(win, math.min(width + 2, math.floor(vim.o.columns / 3)))
  end
end

--- Folds away, in every window showing `buf`, the files outside what the tree last narrowed to.
---@param buf integer
local function narrow(buf)
  local v = views[buf]
  if not v.narrow then
    return
  end
  local hidden
  v.narrow, hidden = tree.narrow(v.files, v.narrow)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local wo = vim.wo[win][0]
    wo.foldmethod, wo.foldenable, wo.foldtext = "manual", true, "v:lua.require'diffy.view'.foldtext()"
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! zE")
      for _, r in ipairs(hidden) do
        vim.cmd(("%d,%dfold"):format(r.first, r.last))
      end
    end)
  end
end

---@param buf integer
---@param sel string
local function choose(buf, sel)
  local v = views[buf]
  local win = in_tab(buf) or vim.api.nvim_open_win(buf, false, { split = "right", win = 0 })
  v.narrow = sel
  narrow(buf)
  vim.api.nvim_set_current_win(win)
  if v.narrow ~= "" then
    local first = vim.iter(v.files):find(function(f)
      return tree.within(f.path, v.narrow)
    end)
    vim.api.nvim_win_set_cursor(win, { first.first, 0 })
  end
end

---@param buf integer
---@return integer
local function create_tree(buf)
  local t = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(t, "diffy-tree://" .. views[buf].source)
  vim.bo[t].filetype = "diffytree"
  vim.bo[t].modifiable = false
  map(t, "n", "<CR>", function()
    choose(buf, views[buf].entries[vim.fn.line(".")].sel)
  end, "Narrow the diff to this")
  map(t, "n", "T", function()
    M.toggle_tree(buf)
  end, "Close the file tree")
  return t
end

---@param buf integer
---@param lines string[]
---@return diffy.Row[] old the rows shown before
local function show(buf, lines)
  local v = views[buf]
  local old = v.rows
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "diff"
  v.lines, v.rows = lines, diff.parse(lines)
  v.files = diff.files(v.rows)
  comments.reanchor(buf, { kind = "diff", source = v.source }, function(span)
    return diff.find(v.rows, span)
  end)
  narrow(buf)
  render_tree(buf)
  return old
end

--- Puts each window's cursor back on the line it was on in `old`, at the same height on screen.
---@param buf integer
---@param old diffy.Row[]
---@param placed diffy.Placement[]
local function restore(buf, old, placed)
  local rows = views[buf].rows
  for _, p in ipairs(placed) do
    if vim.api.nvim_win_is_valid(p.win) and vim.api.nvim_win_get_buf(p.win) == buf then
      local row = math.min(diff.follow(old, rows, p.row) or p.row, #rows)
      vim.api.nvim_win_call(p.win, function()
        vim.fn.winrestview({ lnum = row, col = 0, topline = math.max(1, row - p.height) })
      end)
    end
  end
end

---@param opts diffy.ViewOpts
---@param source string
---@return integer buf
local function create(opts, source)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, "diffy://" .. source)
  views[buf] = { opts = opts, source = source, root = vim.fs.root(vim.fn.getcwd(), ".jj"), lines = {}, rows = {}, files = {}, entries = {} }
  local placed = {}
  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = buf,
    callback = function()
      placed = placements(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    buffer = buf,
    callback = function()
      local old = show(buf, load(opts) or views[buf].lines)
      vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = buf,
        once = true,
        callback = function()
          restore(buf, old, placed)
        end,
      })
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      narrow(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      local t = views[buf].tree
      views[buf] = nil
      if t and vim.api.nvim_buf_is_valid(t) then
        vim.api.nvim_buf_delete(t, { force = true })
      end
    end,
  })
  map(buf, "n", "gf", function()
    M.jump(buf, vim.fn.line("."))
  end, "Open file at this line")
  map(buf, "n", "c", "<cmd>DiffyComment<cr>", "Comment on this line")
  map(buf, "x", "c", ":DiffyComment<cr>", "Comment on the selection")
  map(buf, "n", "<CR>", "<cmd>DiffyEdit<cr>", "Edit the comment under the cursor")
  map(buf, "n", "dd", "<cmd>DiffyDelete<cr>", "Delete comments on this line")
  map(buf, "n", "s", "<cmd>DiffySend<cr>", "Send comment (review if several)")
  map(buf, "n", "S", "<cmd>DiffySend!<cr>", "Send all comments")
  map(buf, "n", "r", "<cmd>edit<cr>", "Refresh the diff")
  map(buf, "n", "gr", "<cmd>DiffyReview<cr>", "Review pending comments")
  map(buf, "n", "T", function()
    M.toggle_tree(buf)
  end, "Toggle the file tree")
  return buf
end

---@param buf integer
---@return boolean opened whether it opened a tab for `buf`
local function focus(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  if win then
    vim.api.nvim_set_current_win(win)
    return false
  end
  vim.cmd("tab sbuffer " .. buf)
  return true
end

---@param opts diffy.ViewOpts
function M.open(opts)
  local lines = load(opts)
  if not lines then
    return
  end
  local source = describe_source(opts)
  local buf
  for b, v in pairs(views) do
    if v.source == source then
      buf = b
    end
  end
  buf = buf or create(opts, source)
  local opened = focus(buf)
  local placed = placements(buf)
  restore(buf, show(buf, lines), placed)
  if opened then
    local win = vim.api.nvim_get_current_win()
    M.toggle_tree(buf)
    vim.api.nvim_set_current_win(win)
  end
end

---@param buf integer the diff buffer
function M.toggle_tree(buf)
  local v = views[buf]
  local open = v.tree and in_tab(v.tree)
  if open then
    vim.api.nvim_win_close(open, false)
    v.narrow = v.narrow and ""
    return narrow(buf)
  end
  if not (v.tree and vim.api.nvim_buf_is_valid(v.tree)) then
    v.tree = create_tree(buf)
  end
  local win = vim.api.nvim_open_win(v.tree, true, { split = "left", win = -1 })
  local wo = vim.wo[win][0]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, "no", "0"
  wo.wrap, wo.winfixwidth, wo.cursorline = false, true, true
  render_tree(buf)
end

---@return string
function M.foldtext()
  return tree.foldtext(views[vim.api.nvim_get_current_buf()].files, vim.v.foldstart, vim.v.foldend)
end

---@param buf integer
---@return boolean
function M.owns(buf)
  return views[buf] ~= nil
end

---@param buf integer
---@param first integer
---@param last integer
---@return diffy.Target?, string? err
function M.target(buf, first, last)
  local v = views[buf]
  return diff.target(v.rows, first, last, v.source)
end

---@param buf integer
---@param lnum integer
function M.jump(buf, lnum)
  local v = views[buf]
  local path, line = diff.jump(v.rows, lnum)
  local full = v.root .. "/" .. path
  if vim.fn.filereadable(full) == 0 then
    return notify(path .. " does not exist in the working copy", vim.log.levels.ERROR)
  end
  vim.cmd("tab drop " .. vim.fn.fnameescape(full))
  vim.api.nvim_win_set_cursor(0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
end

vim.api.nvim_create_autocmd("User", {
  pattern = "DiffyComments",
  group = vim.api.nvim_create_augroup("diffy.view", { clear = true }),
  callback = function(ev)
    if views[ev.data.buf] then
      render_tree(ev.data.buf)
    end
  end,
})

return M
