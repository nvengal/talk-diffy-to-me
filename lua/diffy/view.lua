local diff = require("diffy.diff")
local notify = require("diffy.notify")

local M = {}

---@class diffy.View
---@field rows diffy.Row[]
---@field source string
---@field root string jj workspace root, which diff paths are relative to

---@type table<integer, diffy.View>
local views = {}

---@class diffy.ViewOpts
---@field from? string revset to review against
---@field paths string[]

---@param opts diffy.ViewOpts
local function describe_source(opts)
  local base = opts.from or "@-"
  if #opts.paths > 0 then
    base = base .. " (filtered to: " .. table.concat(opts.paths, ", ") .. ")"
  end
  return base
end

---@param opts diffy.ViewOpts
---@return string[]? lines, string? err
local function load(opts)
  local cmd = { "jj", "diff", "--git" }
  if opts.from then
    vim.list_extend(cmd, { "-r", opts.from .. "..@" })
  end
  if #opts.paths > 0 then
    table.insert(cmd, "--")
    vim.list_extend(cmd, opts.paths)
  end
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    return nil, table.concat(cmd, " ") .. ": " .. vim.trim(res.stderr or "")
  end
  return vim.split(res.stdout, "\n", { plain = true, trimempty = true })
end

---@param opts diffy.ViewOpts
function M.open(opts)
  local lines, err = load(opts)
  if not lines then
    return notify(err, vim.log.levels.ERROR)
  end
  if #lines == 0 then
    return notify("no changes", vim.log.levels.WARN)
  end

  local source = describe_source(opts)
  for old, v in pairs(views) do
    if v.source == source then
      vim.api.nvim_buf_delete(old, { force = true })
    end
  end

  vim.cmd.tabnew()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, "diffy://" .. source)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].modifiable = false

  views[buf] = { rows = diff.parse(lines), source = source, root = vim.fs.root(vim.fn.getcwd(), ".jj") }
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      views[buf] = nil
    end,
  })
  vim.keymap.set("n", "gf", function()
    M.jump(buf, vim.fn.line("."))
  end, { buffer = buf, desc = "Open file at this line" })
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
