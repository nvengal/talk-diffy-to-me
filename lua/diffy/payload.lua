local M = {}

local preamble =
  "The following are review comments. Respond to questions within this conversation (not in code comments). Make requested changes."

local function span(c)
  if c.start == c.finish then
    return tostring(c.start)
  end
  return c.start .. "-" .. c.finish
end

local function fenced(c)
  local out = { c.kind == "diff" and "```diff" or "```" }
  for _, line in ipairs(c.snapshot) do
    table.insert(out, (c.kind == "diff" and line.kind or "") .. line.text)
  end
  table.insert(out, "```")
  return table.concat(out, "\n") .. "\n"
end

---@param comments diffy.Comment[]
---@param source? string the "from" side of the reviewed diff
---@return string
function M.build(comments, source)
  local out = { preamble, "\n" }
  if source then
    table.insert(out, "\nDiff from: " .. source .. "\n")
  end
  for _, c in ipairs(comments) do
    table.insert(out, ("\n## %s:%s\n\n%s\n\n"):format(c.path, span(c), c.body))
    table.insert(out, fenced(c))
  end
  return table.concat(out)
end

return M
