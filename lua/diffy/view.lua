local comments = require("diffy.comments")
local diff = require("diffy.diff")
local notify = require("diffy.notify")

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
  comments.reanchor(buf, { kind = "diff", source = v.source }, function(span)
    return diff.find(v.rows, span)
  end)
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
  views[buf] = { opts = opts, source = source, root = vim.fs.root(vim.fn.getcwd(), ".jj"), lines = {}, rows = {} }
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
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      views[buf] = nil
    end,
  })
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, desc = desc })
  end
  map("n", "gf", function()
    M.jump(buf, vim.fn.line("."))
  end, "Open file at this line")
  map("n", "c", "<cmd>DiffyComment<cr>", "Comment on this line")
  map("x", "c", ":DiffyComment<cr>", "Comment on the selection")
  map("n", "<CR>", "<cmd>DiffyEdit<cr>", "Edit the comment under the cursor")
  map("n", "dd", "<cmd>DiffyDelete<cr>", "Delete comments on this line")
  map("n", "s", "<cmd>DiffySend<cr>", "Send comment (review if several)")
  map("n", "S", "<cmd>DiffySend!<cr>", "Send all comments")
  map("n", "r", "<cmd>edit<cr>", "Refresh the diff")
  map("n", "gr", "<cmd>DiffyReview<cr>", "Review pending comments")
  return buf
end

---@param buf integer
local function focus(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("tab sbuffer " .. buf)
  end
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
  focus(buf)
  local placed = placements(buf)
  restore(buf, show(buf, lines), placed)
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

return M
