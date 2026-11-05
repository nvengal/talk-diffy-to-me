local comments = require("diffy.comments")
local editor = require("diffy.editor")
local notify = require("diffy.notify")
local payload = require("diffy.payload")
local review = require("diffy.review")
local view = require("diffy.view")
local zellij = require("diffy.zellij")

local M = {}

---@type integer?
local pane_id

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
  local existing = comments.find(buf, line1, line2)
  if existing then
    return editor.edit(existing)
  end
  local target, err
  if view.owns(buf) then
    target, err = view.target(buf, line1, line2)
  else
    target = comments.file_target(buf, line1, line2)
  end
  if not target then
    return notify(err, vim.log.levels.ERROR)
  end
  editor.open({
    title = "Comment on " .. payload.location(target.spans),
    body = "",
    insert = true,
    on_save = function(body)
      comments.add(buf, body, target)
    end,
  })
end

function M.delete()
  local removed = comments.remove_at(vim.api.nvim_get_current_buf(), vim.fn.line("."))
  notify(("deleted %d comment(s)"):format(removed))
end

---@param list diffy.Comment[]
---@param on_sent? fun()
function M.send(list, on_sent)
  if #list == 0 then
    return notify("no comments to send", vim.log.levels.WARN)
  end
  with_pane(function(id)
    local err = zellij.send(id, payload.build(list))
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    comments.remove(vim.tbl_map(function(c)
      return c.id
    end, list))
    notify(("sent %d comment(s)"):format(#list))
    if on_sent then
      on_sent()
    end
  end)
end

---@param args string[] `[--from <revset>] [paths...]`
function M.open(args)
  local opts = { paths = {} }
  if args[1] == "--from" then
    if not args[2] then
      return notify("--from needs a revset", vim.log.levels.ERROR)
    end
    opts.from = args[2]
    args = vim.list_slice(args, 3)
  end
  opts.paths = args
  view.open(opts)
end

--- Sends a lone pending comment; with several, opens the review popover to pick.
---@param all boolean send every pending comment instead
function M.send_pending(all)
  local pending = comments.all()
  if all or #pending <= 1 then
    return M.send(pending)
  end
  M.review()
end

function M.review()
  review.open({ send = M.send })
end

function M.reset_pane()
  pane_id = nil
end

return M
