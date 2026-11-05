local comments = require("diffy.comments")
local payload = require("diffy.payload")

local M = {}

---@class diffy.EditorOpts
---@field title string
---@field body string
---@field on_save fun(body: string) called only with a non-blank body
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
    footer = " :w / <C-s> save · q cancel ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true

  local function close()
    vim.cmd.stopinsert()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function save()
    local body = body_of(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    close()
    if body ~= "" then
      opts.on_save(body)
    end
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = save })
  vim.keymap.set({ "n", "i" }, "<C-s>", save, { buffer = buf, desc = "Save comment" })
  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Cancel" })
  if opts.insert then
    vim.cmd.startinsert()
  end
end

---@param c diffy.Comment
---@param on_saved? fun()
function M.edit(c, on_saved)
  M.open({
    title = "Edit comment on " .. payload.location(c.spans),
    body = c.body,
    on_save = function(body)
      comments.set_body(c.id, body)
      if on_saved then
        on_saved()
      end
    end,
  })
end

return M
