local M = {}

---@class diffy.Row
---@field kind string " ", "+", "-", or "" for a header or marker line
---@field text string the line without its diff prefix ("" rows keep the whole line)
---@field path? string display path of the file the row belongs to
---@field hunk? integer identifies the hunk the row belongs to
---@field old? integer old-side line number
---@field new? integer new-side line number
---@field new_start? integer new-side start of the hunk a "@@" row opens

---@param rest string "a/<path> b/<path>"; renames and copies name their path on a later line
---@return string?
local function unchanged_path(rest)
  local half = (#rest - 1) / 2
  if rest:sub(3, half) == rest:sub(half + 4) then
    return rest:sub(half + 4)
  end
end

---@param lines string[] output of `jj diff --git`
---@return diffy.Row[] one row per line
function M.parse(lines)
  local rows, files = {}, {}
  local file, hunk, hunks, old, new = nil, nil, 0, 0, 0
  for _, line in ipairs(lines) do
    local row = { kind = "", text = line }
    local prefix = line:sub(1, 1)
    if line:sub(1, 11) == "diff --git " then
      file, hunk = { path = unchanged_path(line:sub(12)) }, nil
    elseif line:sub(1, 2) == "@@" then
      local o, n = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
      hunks, hunk, old, new = hunks + 1, hunks + 1, tonumber(o) or 0, tonumber(n) or 0
      row.new_start = new
    elseif hunk and (line == "" or prefix == " " or prefix == "+" or prefix == "-") then
      row.kind, row.text = line == "" and " " or prefix, line:sub(2)
      if row.kind ~= "+" then
        row.old, old = old, old + 1
      end
      if row.kind ~= "-" then
        row.new, new = new, new + 1
      end
    elseif file then
      file.path = line:match("^rename to (.*)") or line:match("^copy to (.*)") or file.path
    end
    row.hunk = hunk
    table.insert(rows, row)
    files[#rows] = file
  end
  for i, row in ipairs(rows) do
    row.path = files[i] and files[i].path
  end
  return rows
end

---@param rows diffy.Row[]
---@param first integer 1-based row, inclusive
---@param last integer
---@param source string the "from" side of the diff
---@return diffy.Target?, string? err
function M.target(rows, first, last, source)
  local spans, snapshot, span_hunk = {}, {}, nil
  for i = first, last do
    local r = rows[i]
    table.insert(snapshot, { kind = r.kind, text = r.text })
    if r.kind ~= "" then
      local n = r.new or r.old
      if #spans > 0 and span_hunk == r.hunk then
        spans[#spans].finish = n
      else
        table.insert(spans, { path = r.path, start = n, finish = n })
        span_hunk = r.hunk
      end
    end
  end
  if #spans == 0 then
    return nil, "no diff lines selected"
  end
  return { kind = "diff", source = source, spans = spans, snapshot = snapshot }
end

---@param rows diffy.Row[]
---@param lnum integer 1-based row
---@return string path, integer line
function M.jump(rows, lnum)
  local r = rows[lnum]
  if r.kind ~= "" then
    return r.path, r.new or r.old
  end
  if r.new_start and r.new_start > 0 then
    return r.path, r.new_start
  end
  return r.path, 1
end

return M
