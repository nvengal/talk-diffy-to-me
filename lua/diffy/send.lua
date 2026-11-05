local comments = require("diffy.comments")
local notify = require("diffy.notify")
local payload = require("diffy.payload")
local zellij = require("diffy.zellij")

local M = {}

---@type integer?
local pane_id

---@param p diffy.Pane
local function describe_pane(p)
  return ("%d: %s (%s)"):format(p.id, p.title or "", zellij.command(p))
end

---@return string[] the CLI from `vim.g.diffy_launch` (a string or a list), else `claude`
local function launch_command()
  local cmd = vim.g.diffy_launch or "claude"
  return type(cmd) == "string" and { cmd } or vim.list_slice(cmd)
end

---@param list diffy.Comment[]
---@param on_sent? fun()
---@param err? string
---@param where? string
local function finish(list, on_sent, err, where)
  if err then
    return notify(err, vim.log.levels.ERROR)
  end
  comments.remove(vim.tbl_map(function(c)
    return c.id
  end, list))
  notify(("sent %d comment(s)%s"):format(#list, where or ""))
  if on_sent then
    on_sent()
  end
end

--- Pastes into the remembered pane; otherwise picks one, launching the CLI when nvim is alone in its tab.
---@param list diffy.Comment[]
---@param on_sent? fun()
function M.send(list, on_sent)
  if #list == 0 then
    return notify("no comments to send", vim.log.levels.WARN)
  end
  local text = payload.build(list)
  local function paste(id)
    pane_id = id
    finish(list, on_sent, zellij.send(id, text))
  end
  if pane_id then
    return paste(pane_id)
  end
  local ok, panes = pcall(zellij.list_panes)
  if not ok then
    return notify(panes, vim.log.levels.ERROR)
  end
  local cmd = launch_command()
  local name = vim.fs.basename(cmd[1])
  local candidates = zellij.candidates(panes, vim.env.ZELLIJ_PANE_ID)
  if #candidates == 0 then
    local root = vim.fs.root(vim.fn.getcwd(), ".jj") or vim.fn.getcwd()
    local id, err = zellij.launch(vim.list_extend(cmd, { text }), root)
    pane_id = id
    return finish(list, on_sent, err, " to a new " .. name .. " pane")
  end
  local preferred = zellij.matching(candidates, name)
  if #preferred == 1 then
    return paste(preferred[1].id)
  end
  vim.ui.select(candidates, { prompt = "Send review to pane", format_item = describe_pane }, function(choice)
    if choice then
      paste(choice.id)
    end
  end)
end

function M.reset_pane()
  pane_id = nil
end

return M
