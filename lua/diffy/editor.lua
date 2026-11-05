local comments = require("diffy.comments")
local payload = require("diffy.payload")
local sender = require("diffy.send")

local M = {}

---@class diffy.EditorOpts
---@field title string
---@field body string
---@field on_save fun(body: string): integer called only with a non-blank body; returns the comment's id
---@field after? fun() called once the comment is saved, and again once it is sent
---@field insert? boolean start in insert mode

---@param lines string[]
---@return string
local function body_of(lines)
  return (table.concat(lines, "\n"):gsub("%s+$", ""))
end

---@param opts diffy.EditorOpts
function M.open(opts)
  local lines = vim.split(opts.body, "\n")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "diffy://comment/" .. buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].completion = false

  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(math.max(6, #lines + 2), vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
    title = " " .. opts.title .. " ",
    title_pos = "center",
    footer = " ⏎ save · s send · q cancel ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true

  local function close()
    vim.cmd.stopinsert()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  ---@param send_now boolean
  local function save(send_now)
    local body = body_of(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    close()
    if body == "" then
      return
    end
    local id = opts.on_save(body)
    if opts.after then
      opts.after()
    end
    if send_now then
      sender.send({ comments.get(id) }, opts.after)
    end
  end

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc })
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      save(false)
    end,
  })
  map("<CR>", function()
    save(false)
  end, "Save comment")
  map("s", function()
    save(true)
  end, "Save and send this comment")
  map("q", close, "Cancel")
  if opts.insert then
    vim.cmd.startinsert()
  end
end

---@param c diffy.Comment
---@param after? fun() called once the comment is saved, and again once it is sent
function M.edit(c, after)
  M.open({
    title = "Edit comment on " .. payload.location(c.spans),
    body = c.body,
    after = after,
    on_save = function(body)
      comments.set_body(c.id, body)
      return c.id
    end,
  })
end

return M
