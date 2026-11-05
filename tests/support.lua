local comments = require("diffy.comments")

local M = {}

function M.reset()
  vim.cmd.stopinsert()
  for _, win in ipairs(M.floats()) do
    vim.api.nvim_win_close(win, true)
  end
  comments.remove(vim.tbl_map(function(c)
    return c.id
  end, comments.all()))
end

---@param prefix string
---@param lines string[]
---@return integer buf the current buffer, named <cwd>/<prefix><buf>.go
function M.file_buf(prefix, lines)
  vim.cmd.enew()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/" .. prefix .. buf .. ".go")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

---@return { msg: string, level: integer }[] filled by every later vim.notify
function M.capture_notify()
  local notes = {}
  vim.notify = function(msg, level)
    table.insert(notes, { msg = msg, level = level })
  end
  return notes
end

---@param text string
function M.type_body(text)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, "\n"))
  vim.cmd("write")
end

---@param buf integer
---@return integer[]
function M.sign_lines(buf)
  return vim.tbl_map(function(s)
    return s.lnum
  end, vim.fn.sign_getplaced(buf, { group = "*" })[1].signs)
end

---@return integer[]
function M.floats()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_list_wins())
end

--- Puts a `zellij` on PATH that serves `list-panes` from `panes(...)` and logs every other call.
--- With $ZELLIJ_FAIL set, everything but `list-panes` fails.
function M.fake_zellij()
  local bin = vim.fn.tempname()
  vim.fn.mkdir(bin, "p")
  vim.fn.writefile({
    "#!/bin/sh",
    'if [ "$2" = list-panes ]; then exec cat "$(dirname "$0")/panes.json"; fi',
    'if [ -n "$ZELLIJ_FAIL" ]; then echo "pane gone" >&2; exit 1; fi',
    'printf "%s\\n" "$*" >> "$(dirname "$0")/calls.log"',
  }, bin .. "/zellij")
  vim.fn.setfperm(bin .. "/zellij", "rwxr-xr-x")
  vim.env.PATH = bin .. ":" .. vim.env.PATH
  vim.env.ZELLIJ_PANE_ID = "1"

  local fake = { bin = bin }
  function fake.panes(list)
    vim.fn.writefile({ vim.json.encode(list) }, bin .. "/panes.json")
  end
  function fake.pane(id, title)
    return { id = id, title = title, is_plugin = false, is_selectable = true, tab_id = 0 }
  end
  function fake.calls()
    local log = bin .. "/calls.log"
    return vim.fn.filereadable(log) == 1 and table.concat(vim.fn.readfile(log), "\n") or ""
  end
  function fake.reset()
    vim.fn.delete(bin .. "/calls.log")
    vim.fn.delete(bin .. "/panes.json")
    require("diffy").reset_pane()
  end
  return fake
end

return M
