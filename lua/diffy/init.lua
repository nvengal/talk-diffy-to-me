local comments = require("diffy.comments")
local editor = require("diffy.editor")
local notify = require("diffy.notify")
local payload = require("diffy.payload")
local review = require("diffy.review")
local sender = require("diffy.send")
local view = require("diffy.view")

local M = {}

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
      return comments.add(buf, body, target)
    end,
  })
end

function M.edit()
  local c = comments.at(vim.api.nvim_get_current_buf(), vim.fn.line("."))
  if not c then
    return notify("no comment on this line", vim.log.levels.WARN)
  end
  editor.edit(c)
end

function M.delete()
  local removed = comments.remove_at(vim.api.nvim_get_current_buf(), vim.fn.line("."))
  notify(("deleted %d comment(s)"):format(removed))
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
    return sender.send(pending)
  end
  M.review()
end

function M.review()
  review.open()
end

return M
