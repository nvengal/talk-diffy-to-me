local M = {}

---@class diffy.SnapshotLine
---@field kind string " ", "+", "-", or "" for a diff header line kept verbatim
---@field text string

---@class diffy.Span
---@field path string
---@field start integer 1-based display line, inclusive
---@field finish integer 1-based display line, inclusive

---@class diffy.Target
---@field kind "file"|"diff"
---@field spans diffy.Span[]
---@field snapshot diffy.SnapshotLine[]
---@field source? string the "from" side of the reviewed diff

---@class diffy.Comment : diffy.Target
---@field body string
---@field orphan boolean

---@class diffy.Entry : diffy.Comment
---@field buf integer
---@field mark integer
---@field first integer 1-based buffer row the comment covers, inclusive
---@field last integer

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
  e.first, e.last, e.orphan = pos[1] + 1, pos[3].end_row + 1, false
  if e.kind == "file" then
    e.spans[1].start, e.spans[1].finish = e.first, e.last
  end
end

---@param buf integer
local function render(buf)
  vim.api.nvim_buf_clear_namespace(buf, sign_ns, 0, -1)
  for _, e in ipairs(entries) do
    resolve(e)
    if e.buf == buf and not e.orphan then
      for row = e.first - 1, e.last - 1 do
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
---@return string relative to the jj workspace root, matching diff paths; else to the cwd
local function path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local root = vim.fs.root(vim.fn.getcwd(), ".jj")
  return root and vim.fs.relpath(root, name) or vim.fn.fnamemodify(name, ":.")
end

---@param buf integer
---@param first integer 1-based, inclusive
---@param last integer
---@return diffy.Target
function M.file_target(buf, first, last)
  return {
    kind = "file",
    spans = { { path = path(buf), start = first, finish = last } },
    snapshot = vim.tbl_map(function(text)
      return { kind = " ", text = text }
    end, vim.api.nvim_buf_get_lines(buf, first - 1, last, true)),
  }
end

---@param buf integer
---@param first integer 1-based buffer row, inclusive
---@param last integer
---@param body string
---@param target diffy.Target
function M.add(buf, first, last, body, target)
  local last_line = vim.api.nvim_buf_get_lines(buf, last - 1, last, true)[1]
  table.insert(
    entries,
    vim.tbl_extend("force", target, {
      body = body,
      orphan = false,
      buf = buf,
      first = first,
      last = last,
      mark = vim.api.nvim_buf_set_extmark(buf, ns, first - 1, 0, {
        end_row = last - 1,
        end_col = #last_line,
        invalidate = true,
      }),
    })
  )
  render(buf)
end

---@return diffy.Comment[]
function M.all()
  return vim.tbl_map(function(e)
    resolve(e)
    return {
      kind = e.kind,
      source = e.source,
      spans = e.spans,
      body = e.body,
      orphan = e.orphan,
      snapshot = e.snapshot,
    }
  end, entries)
end

---@param buf integer
---@param lnum integer 1-based buffer row
---@return integer removed
function M.remove_at(buf, lnum)
  local kept = {}
  for _, e in ipairs(entries) do
    resolve(e)
    if e.buf == buf and not e.orphan and e.first <= lnum and lnum <= e.last then
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
