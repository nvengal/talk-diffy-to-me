local comments = require("diffy.comments")
local editor = require("diffy.editor")
local notify = require("diffy.notify")
local payload = require("diffy.payload")
local sender = require("diffy.send")

local M = {}

---@param c diffy.Comment
local function label(c)
  return ("%s%s  %s"):format(c.orphan and "[orphan] " or "", payload.location(c.spans), c.body:match("[^\n]*"))
end

---@param buf integer
---@param lines string[]
local function fill(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---@param ft? string
local function scratch(ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = ft or ""
  return buf
end

function M.open()
  if #comments.all() == 0 then
    return notify("no comments to review", vim.log.levels.WARN)
  end

  local width = math.min(100, vim.o.columns - 4)
  local col = math.floor((vim.o.columns - width) / 2)
  local list_height = math.max(3, math.floor(vim.o.lines / 3))
  local list_buf, preview_buf = scratch(), scratch("markdown")
  local list_win = vim.api.nvim_open_win(list_buf, true, {
    relative = "editor",
    width = width,
    height = list_height,
    row = 2,
    col = col,
    border = "rounded",
    style = "minimal",
    title_pos = "center",
    title = " diffy ",
    footer = " s send · S send all · ⏎ edit · dd delete · gf jump · q close ",
    footer_pos = "center",
  })
  vim.wo[list_win].cursorline = true
  local preview_win = vim.api.nvim_open_win(preview_buf, false, {
    relative = "editor",
    width = width,
    height = math.max(3, vim.o.lines - list_height - 10),
    row = list_height + 4,
    col = col,
    border = "rounded",
    style = "minimal",
    focusable = false,
  })
  vim.wo[preview_win].wrap = true

  local shown = {} ---@type diffy.Comment[]

  local function close()
    for _, win in ipairs({ preview_win, list_win }) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
  end

  local function focused()
    return shown[vim.api.nvim_win_get_cursor(list_win)[1]]
  end

  local function preview()
    fill(preview_buf, vim.split(payload.section(focused()), "\n", { trimempty = true }))
  end

  local function render()
    shown = comments.all()
    if #shown == 0 then
      return close()
    end
    fill(list_buf, vim.tbl_map(label, shown))
    vim.api.nvim_win_set_config(list_win, { title = (" diffy: %d pending "):format(#shown), title_pos = "center" })
    preview()
  end

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = list_buf, nowait = true, desc = desc })
  end

  map("s", function()
    sender.send({ focused() }, render)
  end, "Send this comment")
  map("S", function()
    sender.send(shown, render)
  end, "Send all comments")
  map("dd", function()
    comments.remove({ focused().id })
    render()
  end, "Delete this comment")
  map("<CR>", function()
    editor.edit(focused(), render)
  end, "Edit this comment")
  map("gf", function()
    local buf, row = comments.location(focused().id)
    if not buf then
      return notify("orphaned comments have no location", vim.log.levels.WARN)
    end
    close()
    local win = vim.fn.win_findbuf(buf)[1]
    if win then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("tab sbuffer " .. buf)
    end
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end, "Jump to this comment")
  map("q", close, "Close")
  map("<Esc>", close, "Close")

  vim.api.nvim_create_autocmd("CursorMoved", { buffer = list_buf, callback = preview })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(list_win),
    once = true,
    callback = close,
  })
  render()
end

return M
