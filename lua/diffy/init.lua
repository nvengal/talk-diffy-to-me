local comments = require("diffy.comments")
local payload = require("diffy.payload")
local zellij = require("diffy.zellij")

local M = {}

---@type integer?
local pane_id

local function notify(msg, level)
  vim.notify("diffy: " .. msg, level or vim.log.levels.INFO)
end

---@param p diffy.Pane
local function describe_pane(p)
  return ("%d: %s (%s)"):format(p.id, p.title or "", zellij.command(p))
end

---@param on_pane fun(id: integer)
local function with_pane(on_pane)
  if pane_id then
    return on_pane(pane_id)
  end
  local ok, panes = pcall(zellij.list_panes)
  if not ok then
    return notify(panes, vim.log.levels.ERROR)
  end
  local candidates = zellij.candidates(panes, vim.env.ZELLIJ_PANE_ID)
  if #candidates == 0 then
    return notify("no other panes in this zellij tab", vim.log.levels.ERROR)
  end
  local claude = zellij.match_claude(candidates)
  if #claude == 1 then
    pane_id = claude[1].id
    return on_pane(pane_id)
  end
  vim.ui.select(candidates, { prompt = "Send review to pane", format_item = describe_pane }, function(choice)
    if choice then
      pane_id = choice.id
      on_pane(pane_id)
    end
  end)
end

---@param line1 integer
---@param line2 integer
function M.comment(line1, line2)
  local buf = vim.api.nvim_get_current_buf()
  local label = line1 == line2 and line1 or (line1 .. "-" .. line2)
  vim.ui.input({ prompt = ("Comment on %s:%s: "):format(comments.path(buf), label) }, function(body)
    if body and body ~= "" then
      comments.add(buf, line1, line2, body)
    end
  end)
end

function M.delete()
  local removed = comments.remove_at(vim.api.nvim_get_current_buf(), vim.fn.line("."))
  notify(("deleted %d comment(s)"):format(removed))
end

function M.send()
  local all = comments.all()
  if #all == 0 then
    return notify("no comments to send", vim.log.levels.WARN)
  end
  with_pane(function(id)
    local err = zellij.send(id, payload.build(all))
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    comments.clear()
    notify(("sent %d comment(s)"):format(#all))
  end)
end

function M.reset_pane()
  pane_id = nil
end

return M
