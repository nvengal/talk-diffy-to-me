local M = {}

---@class diffy.SnapshotLine
---@field kind string one of " ", "+", "-"
---@field text string

---@class diffy.Comment
---@field kind "file"|"diff"
---@field path string
---@field start integer 1-based, inclusive
---@field finish integer 1-based, inclusive
---@field body string
---@field orphan boolean
---@field snapshot diffy.SnapshotLine[]

---@class diffy.Entry : diffy.Comment
---@field buf integer
---@field mark integer

local ns = vim.api.nvim_create_namespace("diffy")
local sign_ns = vim.api.nvim_create_namespace("diffy_signs")
vim.api.nvim_set_hl(0, "DiffySign", { link = "DiagnosticSignInfo", default = true })

---@type diffy.Entry[]
local entries = {}

---@param e diffy.Entry
local function resolve(e)
  local pos = vim.api.nvim_buf_is_valid(e.buf)
    and vim.api.nvim_buf_get_extmark_by_id(e.buf, ns, e.mark, { details = true })
  if not pos or not pos[1] or pos[3].invalid then
    e.orphan = true
    return
  end
  e.start, e.finish, e.orphan = pos[1] + 1, pos[3].end_row + 1, false
end

---@param buf integer
local function render(buf)
  vim.api.nvim_buf_clear_namespace(buf, sign_ns, 0, -1)
  for _, e in ipairs(entries) do
    resolve(e)
    if e.buf == buf and not e.orphan then
      for row = e.start - 1, e.finish - 1 do
        vim.api.nvim_buf_set_extmark(buf, sign_ns, row, 0, {
          sign_text = "▸",
          sign_hl_group = "DiffySign",
          invalidate = true,
        })
      end
    end
  end
end

---@param buf integer
---@return string
function M.path(buf)
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
end

---@param buf integer
---@param start integer 1-based, inclusive
---@param finish integer 1-based, inclusive
---@param body string
function M.add(buf, start, finish, body)
  local lines = vim.api.nvim_buf_get_lines(buf, start - 1, finish, true)
  table.insert(entries, {
    kind = "file",
    path = M.path(buf),
    start = start,
    finish = finish,
    body = body,
    orphan = false,
    snapshot = vim.tbl_map(function(text)
      return { kind = " ", text = text }
    end, lines),
    buf = buf,
    mark = vim.api.nvim_buf_set_extmark(buf, ns, start - 1, 0, {
      end_row = finish - 1,
      end_col = #lines[#lines],
      invalidate = true,
    }),
  })
  render(buf)
end

---@return diffy.Comment[]
function M.all()
  return vim.tbl_map(function(e)
    resolve(e)
    return {
      kind = e.kind,
      path = e.path,
      start = e.start,
      finish = e.finish,
      body = e.body,
      orphan = e.orphan,
      snapshot = e.snapshot,
    }
  end, entries)
end

---@param buf integer
---@param lnum integer 1-based
---@return integer removed
function M.remove_at(buf, lnum)
  local kept = {}
  for _, e in ipairs(entries) do
    resolve(e)
    if e.buf == buf and not e.orphan and e.start <= lnum and lnum <= e.finish then
      vim.api.nvim_buf_del_extmark(buf, ns, e.mark)
    else
      table.insert(kept, e)
    end
  end
  local removed = #entries - #kept
  entries = kept
  render(buf)
  return removed
end

function M.clear()
  for _, e in ipairs(entries) do
    if vim.api.nvim_buf_is_valid(e.buf) then
      vim.api.nvim_buf_clear_namespace(e.buf, ns, 0, -1)
      vim.api.nvim_buf_clear_namespace(e.buf, sign_ns, 0, -1)
    end
  end
  entries = {}
end

return M
