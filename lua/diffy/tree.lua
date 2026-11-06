local M = {}

---@class diffy.TreeLine
---@field text string
---@field sel string what choosing the line narrows to: "" for everything, a directory ending in "/", or a file path

---@class diffy.TreeNode
---@field name string
---@field sel string
---@field file? diffy.File
---@field children diffy.TreeNode[]
---@field by table<string, diffy.TreeNode>

---@param path string
---@param sel string
---@return boolean
function M.within(path, sel)
  return sel == "" or path == sel or (sel:sub(-1) == "/" and vim.startswith(path, sel))
end

---@param name string
---@param sel string
---@return diffy.TreeNode
local function node(name, sel)
  return { name = name, sel = sel, children = {}, by = {} }
end

---@param root diffy.TreeNode
---@param file diffy.File
local function insert(root, file)
  local parent, parts = root, vim.split(file.path, "/", { plain = true })
  for i = 1, #parts - 1 do
    local dir = parts[i] .. "/"
    if not parent.by[dir] then
      parent.by[dir] = node(dir, parent.sel .. dir)
      table.insert(parent.children, parent.by[dir])
    end
    parent = parent.by[dir]
  end
  local leaf = node(parts[#parts], file.path)
  leaf.file = file
  table.insert(parent.children, leaf)
end

---@class diffy.TreeEntry
---@field depth integer
---@field name string
---@field sel string
---@field file? diffy.File

---@param parent diffy.TreeNode
---@param depth integer
---@param out diffy.TreeEntry[]
local function flatten(parent, depth, out)
  for _, child in ipairs(parent.children) do
    local name = child.name
    while not child.file and #child.children == 1 and not child.children[1].file do
      child = child.children[1]
      name = name .. child.name
    end
    table.insert(out, { depth = depth, name = name, sel = child.sel, file = child.file })
    flatten(child, depth + 1, out)
  end
end

---@param comments diffy.Comment[]
---@param source string
---@return table<string, integer> pending comments on each path of the diff from `source`
local function counts(comments, source)
  local n = {}
  for _, c in ipairs(comments) do
    if c.kind == "diff" and c.source == source then
      local paths = {}
      for _, s in ipairs(c.spans) do
        paths[s.path] = true
      end
      for path in pairs(paths) do
        n[path] = (n[path] or 0) + 1
      end
    end
  end
  return n
end

---@param files diffy.File[]
---@param source string
---@param comments diffy.Comment[]
---@return diffy.TreeLine[]
function M.build(files, source, comments)
  local root = node("", "")
  for _, f in ipairs(files) do
    insert(root, f)
  end
  local entries = {}
  flatten(root, 1, entries)
  local width = 0
  for _, e in ipairs(entries) do
    e.name = ("  "):rep(e.depth) .. e.name
    if e.file then
      width = math.max(width, vim.fn.strdisplaywidth(e.name))
    end
  end
  local commented = counts(comments, source)
  local lines = { { text = source, sel = "" } }
  for _, e in ipairs(entries) do
    local text = e.name
    if e.file then
      text = ("%s%s  +%d -%d"):format(text, (" "):rep(width - vim.fn.strdisplaywidth(text)), e.file.added, e.file.removed)
      if commented[e.sel] then
        text = text .. "  ▸" .. commented[e.sel]
      end
    end
    table.insert(lines, { text = text, sel = e.sel })
  end
  return lines
end

---@class diffy.Range
---@field first integer
---@field last integer

---@param files diffy.File[]
---@param sel string
---@return string sel `sel`, or "" when no file is within it
---@return diffy.Range[] hidden the rows of the files outside `sel`, merged where adjacent
function M.narrow(files, sel)
  local hidden, shown = {}, false
  for _, f in ipairs(files) do
    local last = hidden[#hidden]
    if M.within(f.path, sel) then
      shown = true
    elseif last and last.last + 1 == f.first then
      last.last = f.last
    else
      table.insert(hidden, { first = f.first, last = f.last })
    end
  end
  if not shown then
    return "", {}
  end
  return sel, hidden
end

---@param files diffy.File[]
---@param first integer
---@param last integer
---@return string
function M.foldtext(files, first, last)
  local n = 0
  for _, f in ipairs(files) do
    if first <= f.first and f.first <= last then
      n = n + 1
    end
  end
  return ("··· %d %s hidden ···"):format(n, n == 1 and "file" or "files")
end

return M
