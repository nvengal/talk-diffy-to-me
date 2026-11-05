local match = require("diffy.match")

local M = {}

---@class diffy.SnapshotLine
---@field kind string " ", "+", "-", or "" for a diff header line kept verbatim
---@field text string

---@class diffy.Location
---@field path string
---@field start integer 1-based display line, inclusive
---@field finish integer 1-based display line, inclusive

---@class diffy.Span : diffy.Location
---@field first integer 1-based buffer row the span covers, inclusive
---@field last integer
---@field lines diffy.SnapshotLine[] the span's content, which re-anchoring searches for
---@field mark? integer

---@class diffy.Target
---@field kind "file"|"diff"
---@field spans diffy.Span[]
---@field snapshot diffy.SnapshotLine[] the selection as shown in the payload
---@field source? string the "from" side of the reviewed diff

---@class diffy.Comment
---@field id integer
---@field kind "file"|"diff"
---@field spans diffy.Location[]
---@field snapshot diffy.SnapshotLine[]
---@field source? string
---@field body string
---@field orphan boolean

---@class diffy.Entry : diffy.Target
---@field id integer
---@field buf integer
---@field body string
---@field orphan boolean

local ns = vim.api.nvim_create_namespace("diffy")
local sign_ns = vim.api.nvim_create_namespace("diffy_signs")
vim.api.nvim_set_hl(0, "DiffySign", { link = "DiagnosticSignInfo", default = true })

---@type diffy.Entry[]
local entries = {}
local next_id = 1

---@param e diffy.Entry
local function resolve(e)
  for _, s in ipairs(e.spans) do
    local pos = s.mark
      and vim.api.nvim_buf_is_valid(e.buf)
      and vim.api.nvim_buf_get_extmark_by_id(e.buf, ns, s.mark, { details = true })
    if not pos or not pos[1] or pos[3].invalid then
      e.orphan = true
      return
    end
    s.first, s.last = pos[1] + 1, pos[3].end_row + 1
    if e.kind == "file" then
      s.start, s.finish = s.first, s.last
    end
  end
  e.orphan = false
end

---@param buf integer
---@param s diffy.Span
local function place(buf, s)
  local last_line = vim.api.nvim_buf_get_lines(buf, s.last - 1, s.last, true)[1]
  s.mark = vim.api.nvim_buf_set_extmark(buf, ns, s.first - 1, 0, {
    end_row = s.last - 1,
    end_col = #last_line,
    invalidate = true,
  })
end

---@param e diffy.Entry
local function unplace(e)
  for _, s in ipairs(e.spans) do
    if s.mark and vim.api.nvim_buf_is_valid(e.buf) then
      vim.api.nvim_buf_del_extmark(e.buf, ns, s.mark)
    end
    s.mark = nil
  end
end

---@param buf integer
local function render(buf)
  vim.api.nvim_buf_clear_namespace(buf, sign_ns, 0, -1)
  for _, e in ipairs(entries) do
    resolve(e)
    if e.buf == buf and not e.orphan then
      for _, s in ipairs(e.spans) do
        for row = s.first - 1, s.last - 1 do
          vim.api.nvim_buf_set_extmark(buf, sign_ns, row, 0, {
            sign_text = "▸",
            sign_hl_group = "DiffySign",
            invalidate = true,
          })
        end
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
  local snapshot = vim.tbl_map(function(text)
    return { kind = " ", text = text }
  end, vim.api.nvim_buf_get_lines(buf, first - 1, last, true))
  return {
    kind = "file",
    spans = { { path = path(buf), start = first, finish = last, first = first, last = last, lines = snapshot } },
    snapshot = snapshot,
  }
end

---@param buf integer
---@param body string
---@param target diffy.Target
function M.add(buf, body, target)
  local e = vim.tbl_extend("force", target, { id = next_id, buf = buf, body = body, orphan = false })
  next_id = next_id + 1
  for _, s in ipairs(e.spans) do
    place(buf, s)
  end
  table.insert(entries, e)
  render(buf)
end

---@return diffy.Comment[]
function M.all()
  return vim.tbl_map(function(e)
    resolve(e)
    return {
      id = e.id,
      kind = e.kind,
      source = e.source,
      spans = vim.tbl_map(function(s)
        return { path = s.path, start = s.start, finish = s.finish }
      end, e.spans),
      body = e.body,
      orphan = e.orphan,
      snapshot = e.snapshot,
    }
  end, entries)
end

---@param e diffy.Entry
---@param lnum integer
local function covers(e, lnum)
  for _, s in ipairs(e.spans) do
    if s.first <= lnum and lnum <= s.last then
      return true
    end
  end
  return false
end

---@param doomed fun(e: diffy.Entry): boolean
---@return integer removed
local function drop(doomed)
  local kept, touched = {}, {}
  for _, e in ipairs(entries) do
    resolve(e)
    if doomed(e) then
      unplace(e)
      touched[e.buf] = true
    else
      table.insert(kept, e)
    end
  end
  local removed = #entries - #kept
  entries = kept
  for buf in pairs(touched) do
    if vim.api.nvim_buf_is_valid(buf) then
      render(buf)
    end
  end
  return removed
end

---@param buf integer
---@param lnum integer 1-based buffer row
---@return integer removed
function M.remove_at(buf, lnum)
  return drop(function(e)
    return e.buf == buf and not e.orphan and covers(e, lnum)
  end)
end

---@param ids integer[]
function M.remove(ids)
  local named = {}
  for _, id in ipairs(ids) do
    named[id] = true
  end
  drop(function(e)
    return named[e.id] == true
  end)
end

---@param id integer
---@return diffy.Entry?
local function entry(id)
  for _, e in ipairs(entries) do
    if e.id == id then
      return e
    end
  end
end

---@param id integer
---@param body string
function M.set_body(id, body)
  entry(id).body = body
end

---@param id integer
---@return integer? buf, integer? row 1-based first row, or nothing for an orphan
function M.location(id)
  local e = entry(id)
  resolve(e)
  if not e.orphan then
    return e.buf, e.spans[1].first
  end
end

---@class diffy.Key
---@field kind "file"|"diff"
---@field path? string identifies file comments
---@field source? string identifies diff comments

---@param e diffy.Entry
---@param key diffy.Key
local function keyed(e, key)
  if key.kind == "file" then
    return e.kind == "file" and e.spans[1].path == key.path
  end
  return e.kind == "diff" and e.source == key.source
end

--- Attaches every comment with `key` to `buf`, wherever `find` now locates each of its spans.
--- A comment with any span not found becomes an orphan.
---@param buf integer
---@param key diffy.Key
---@param find fun(span: diffy.Span): diffy.Anchor?
function M.reanchor(buf, key, find)
  for _, e in ipairs(entries) do
    if keyed(e, key) then
      unplace(e)
      e.buf = buf
      local anchors = vim.tbl_map(find, e.spans)
      if #anchors == #e.spans then
        for i, s in ipairs(e.spans) do
          s.first, s.last, s.start, s.finish = anchors[i].first, anchors[i].last, anchors[i].start, anchors[i].finish
          place(buf, s)
        end
      end
    end
  end
  render(buf)
end

---@param buf integer
local function reanchor_file(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  M.reanchor(buf, { kind = "file", path = path(buf) }, function(span)
    local first = match.nearest(#lines, #span.lines, span.first, function(first)
      for k, w in ipairs(span.lines) do
        if lines[first + k - 1] ~= w.text then
          return false
        end
      end
      return true
    end)
    return first and { first = first, last = first + #span.lines - 1, start = first, finish = first + #span.lines - 1 }
  end)
end

vim.api.nvim_create_autocmd("BufReadPost", {
  group = vim.api.nvim_create_augroup("diffy", { clear = true }),
  callback = function(ev)
    reanchor_file(ev.buf)
  end,
})

return M
