local M = {}

local preamble =
  "The following are review comments. Respond to questions within this conversation (not in code comments). Make requested changes."

---@param s diffy.Span
local function range(s)
  if s.start == s.finish then
    return tostring(s.start)
  end
  return s.start .. "-" .. s.finish
end

---@param spans diffy.Span[]
---@return string e.g. "a.go:1, 5-6; b.go:2"
function M.location(spans)
  local groups = {}
  for i, s in ipairs(spans) do
    if i > 1 and spans[i - 1].path == s.path then
      groups[#groups] = groups[#groups] .. ", " .. range(s)
    else
      table.insert(groups, s.path .. ":" .. range(s))
    end
  end
  return table.concat(groups, "; ")
end

---@param comments diffy.Comment[]
local function sources(comments)
  local seen, out = {}, {}
  for _, c in ipairs(comments) do
    if c.source and not seen[c.source] then
      seen[c.source] = true
      table.insert(out, c.source)
    end
  end
  return out
end

---@param c diffy.Comment
local function fenced(c)
  local out = { c.kind == "diff" and "```diff" or "```" }
  for _, line in ipairs(c.snapshot) do
    table.insert(out, (c.kind == "diff" and line.kind or "") .. line.text)
  end
  table.insert(out, "```")
  return table.concat(out, "\n") .. "\n"
end

---@param c diffy.Comment
---@return string the comment as it appears in the payload
function M.section(c)
  return ("## %s\n\n%s\n\n"):format(M.location(c.spans), c.body) .. fenced(c)
end

---@param comments diffy.Comment[]
---@return string
function M.build(comments)
  local out = { preamble, "\n" }
  local from = sources(comments)
  if #from > 0 then
    table.insert(out, "\nDiff from: " .. table.concat(from, ", ") .. "\n")
  end
  for _, c in ipairs(comments) do
    table.insert(out, "\n" .. M.section(c))
  end
  return table.concat(out)
end

return M
