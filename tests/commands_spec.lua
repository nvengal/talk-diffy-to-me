local comments = require("diffy.comments")

local bin = vim.fn.tempname()
local log = bin .. "/calls.log"
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

local function panes(list)
  vim.fn.writefile({ vim.json.encode(list) }, bin .. "/panes.json")
end

local function pane(id, title)
  return { id = id, title = title, is_plugin = false, is_selectable = true, tab_id = 0 }
end

local function calls()
  return vim.fn.filereadable(log) == 1 and table.concat(vim.fn.readfile(log), "\n") or ""
end

local function answer_input(text)
  vim.ui.input = function(_, on_confirm)
    on_confirm(text)
  end
end

local function file_buf(lines)
  vim.cmd.enew()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/cmd" .. buf .. ".go")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

vim.cmd.runtime("plugin/diffy.lua")

describe("commands", function()
  local notes

  before_each(function()
    comments.clear()
    vim.fn.delete(log)
    require("diffy").reset_pane()
    notes = {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
  end)

  it(":DiffyComment comments on the given range", function()
    local buf = file_buf({ "a", "b", "c" })
    answer_input("needs a test")
    vim.cmd("2,3DiffyComment")

    local c = comments.all()[1]
    assert.are.same({ { path = "cmd" .. buf .. ".go", start = 2, finish = 3 } }, c.spans)
    assert.are.equal("needs a test", c.body)
  end)

  it(":DiffyComment ignores a cancelled or empty input", function()
    file_buf({ "a" })
    answer_input(nil)
    vim.cmd("DiffyComment")
    answer_input("")
    vim.cmd("DiffyComment")
    assert.are.same({}, comments.all())
  end)

  it(":DiffyDelete removes comments on the cursor line", function()
    file_buf({ "a", "b" })
    answer_input("x")
    vim.cmd("2DiffyComment")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("DiffyDelete")
    assert.are.same({}, comments.all())
  end)

  it(":DiffySend pastes the payload into the lone claude pane, submits, and clears", function()
    panes({ pane(1, "nvim"), pane(2, "zsh"), pane(3, "claude") })
    local buf = file_buf({ "a", "b" })
    answer_input("why?")
    vim.cmd("1DiffyComment")
    vim.cmd("DiffySend")

    vim.wait(2000, function()
      return #comments.all() == 0
    end)
    local out = calls()
    assert.truthy(out:find("action paste --pane-id 3 -- The following are review comments.", 1, true))
    assert.truthy(out:find("## cmd" .. buf .. ".go:1\n\nwhy?\n\n```\na\n```", 1, true))
    assert.truthy(out:find("action send-keys --pane-id 3 -- Enter", 1, true))
    assert.are.same({}, comments.all())
  end)

  it(":DiffySend asks which pane when claude is ambiguous, then remembers it", function()
    panes({ pane(1, "nvim"), pane(2, "claude a"), pane(3, "claude b") })
    local asked = 0
    vim.ui.select = function(items, _, on_choice)
      asked = asked + 1
      on_choice(items[2])
    end
    file_buf({ "a" })
    answer_input("x")

    for _ = 1, 2 do
      vim.cmd("1DiffyComment")
      vim.cmd("DiffySend")
      vim.wait(2000, function()
        return #comments.all() == 0
      end)
    end

    assert.are.equal(1, asked)
    local _, pastes = calls():gsub("paste %-%-pane%-id 3 ", "")
    assert.are.equal(2, pastes)
  end)

  it(":DiffySend keeps the comments when the paste fails", function()
    panes({ pane(1, "nvim"), pane(2, "claude") })
    file_buf({ "a" })
    answer_input("x")
    vim.cmd("1DiffyComment")

    vim.env.ZELLIJ_FAIL = "1"
    vim.cmd("DiffySend")
    vim.env.ZELLIJ_FAIL = nil

    assert.are.same({ msg = "diffy: zellij action paste: pane gone", level = vim.log.levels.ERROR }, notes[#notes])
    assert.are.equal(1, #comments.all())
  end)

  it(":DiffySend reports an error outside zellij and keeps the comments", function()
    vim.fn.delete(bin .. "/panes.json")
    file_buf({ "a" })
    answer_input("x")
    vim.cmd("1DiffyComment")
    vim.cmd("DiffySend")

    assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
    assert.truthy(notes[#notes].msg:find("list-panes", 1, true))
    assert.are.equal(1, #comments.all())
  end)

  it(":DiffySend reports an error when nvim is alone in its tab", function()
    panes({ pane(1, "nvim") })
    file_buf({ "a" })
    answer_input("x")
    vim.cmd("1DiffyComment")
    vim.cmd("DiffySend")

    assert.are.same({ msg = "diffy: no other panes in this zellij tab", level = vim.log.levels.ERROR }, notes[#notes])
    assert.are.equal(1, #comments.all())
  end)

  it(":DiffySend with nothing queued warns without touching zellij", function()
    panes({ pane(1, "nvim"), pane(2, "claude") })
    vim.cmd("DiffySend")

    assert.are.equal(vim.log.levels.WARN, notes[#notes].level)
    assert.are.equal("", calls())
  end)
end)
