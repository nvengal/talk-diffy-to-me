local comments = require("diffy.comments")
local support = require("support")

local zellij = support.fake_zellij()
local type_body = support.type_body

local function keys(typed)
  vim.api.nvim_feedkeys(vim.keycode(typed), "x", false)
end

local function file_buf(lines)
  return support.file_buf("cmd", lines)
end

vim.cmd.runtime("plugin/diffy.lua")

describe("commands", function()
  local notes

  before_each(function()
    support.reset()
    zellij.reset()
    notes = support.capture_notify()
  end)

  it(":DiffyComment comments on the given range", function()
    local buf = file_buf({ "a", "b", "c" })
    vim.cmd("2,3DiffyComment")
    type_body("needs a test")

    local c = comments.all()[1]
    assert.are.same({ { path = "cmd" .. buf .. ".go", start = 2, finish = 3 } }, c.spans)
    assert.are.equal("needs a test", c.body)
  end)

  it(":DiffyComment opens a markdown float titled with what is being commented on", function()
    local buf = file_buf({ "a", "b", "c" })
    keys(":2,3DiffyComment<CR>")

    local config = vim.api.nvim_win_get_config(0)
    assert.are.equal("editor", config.relative)
    assert.are.equal(" Comment on cmd" .. buf .. ".go:2-3 ", config.title[1][1])
    assert.are.equal("markdown", vim.bo.filetype)
    keys("<Esc>q")
  end)

  it(":DiffyComment's float tells completion plugins to stay quiet", function()
    file_buf({ "a" })
    keys(":DiffyComment<CR>")

    assert.is_false(vim.b.completion)
    keys("<Esc>q")
  end)

  it(":DiffyComment saves a multi-line body without trailing blank lines and closes the float", function()
    file_buf({ "a" })
    vim.cmd("DiffyComment")
    type_body("first line\n\nsecond paragraph\n\n")

    assert.are.equal("first line\n\nsecond paragraph", comments.all()[1].body)
    assert.are.equal("", vim.api.nvim_win_get_config(0).relative)
  end)

  it(":DiffyComment starts typing straight away and saves with <CR> from normal mode", function()
    local buf = file_buf({ "a" })
    keys(":DiffyComment<CR>hello<Esc><CR>")

    assert.are.equal(buf, vim.api.nvim_get_current_buf())

    assert.are.equal("hello", comments.all()[1].body)
  end)

  it(":DiffyComment's s saves and sends just that comment", function()
    zellij.panes({ zellij.pane(1, "nvim"), zellij.pane(2, "claude") })
    file_buf({ "a", "b" })
    vim.cmd("1DiffyComment")
    type_body("older")
    keys(":2DiffyComment<CR>urgent<Esc>s")

    assert.truthy(zellij.calls():find("urgent", 1, true))
    assert.falsy(zellij.calls():find("older", 1, true))
    assert.are.same({ "older" }, vim.tbl_map(function(c)
      return c.body
    end, comments.all()))
  end)

  it(":DiffyComment adds nothing when cancelled with q or saved empty", function()
    file_buf({ "a" })
    keys(":DiffyComment<CR><Esc>q")
    keys(":DiffyComment<CR><CR>  <Esc><CR>")

    assert.are.same({}, comments.all())
    assert.are.equal("", vim.api.nvim_win_get_config(0).relative)
  end)

  it(":DiffyComment on exactly the range of a comment edits that comment", function()
    file_buf({ "a", "b", "c" })
    vim.cmd("2,3DiffyComment")
    type_body("first")
    keys(":2,3DiffyComment<CR>")

    assert.are.same({ "first" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    keys("A, again<Esc><CR>")
    assert.are.same({ "first, again" }, vim.tbl_map(function(c)
      return c.body
    end, comments.all()))
  end)

  it(":DiffyComment on a range overlapping a comment adds another", function()
    file_buf({ "a", "b", "c" })
    vim.cmd("2,3DiffyComment")
    type_body("first")
    vim.cmd("2DiffyComment")
    type_body("second")
    vim.cmd("1,3DiffyComment")
    type_body("third")

    assert.are.equal(3, #comments.all())
  end)

  it(":DiffyComment where an orphaned comment last was adds a new comment", function()
    local buf = file_buf({ "a", "b", "c" })
    vim.cmd("2DiffyComment")
    type_body("on b")
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    vim.cmd("2DiffyComment")
    type_body("on c")

    assert.are.same({ "on b", "on c" }, vim.tbl_map(function(c)
      return c.body
    end, comments.all()))
  end)

  it(":DiffyDelete removes comments on the cursor line", function()
    file_buf({ "a", "b" })
    vim.cmd("2DiffyComment")
    type_body("x")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("DiffyDelete")
    assert.are.same({}, comments.all())
  end)

  it(":DiffySend pastes the payload into the lone claude pane, submits, and clears", function()
    zellij.panes({ zellij.pane(1, "nvim"), zellij.pane(2, "zsh"), zellij.pane(3, "claude") })
    local buf = file_buf({ "a", "b" })
    vim.cmd("1DiffyComment")
    type_body("why?")
    vim.cmd("DiffySend")

    vim.wait(2000, function()
      return #comments.all() == 0
    end)
    local out = zellij.calls()
    assert.truthy(out:find("action paste --pane-id 3 -- The following are review comments.", 1, true))
    assert.truthy(out:find("## cmd" .. buf .. ".go:1\n\nwhy?\n\n```\na\n```", 1, true))
    assert.truthy(out:find("action send-keys --pane-id 3 -- Enter", 1, true))
    assert.are.same({}, comments.all())
  end)

  it(":DiffySend keeps a comment added while it was choosing the pane", function()
    zellij.panes({ zellij.pane(1, "nvim"), zellij.pane(2, "claude a"), zellij.pane(3, "claude b") })
    file_buf({ "a", "b" })
    vim.cmd("1DiffyComment")
    type_body("sent")
    vim.ui.select = function(items, _, on_choice)
      vim.cmd("2DiffyComment")
      type_body("added meanwhile")
      on_choice(items[2])
    end
    vim.cmd("DiffySend")

    assert.are.same({ "added meanwhile" }, vim.tbl_map(function(c)
      return c.body
    end, comments.all()))
  end)

  it(":DiffySend asks which pane when claude is ambiguous, then remembers it", function()
    zellij.panes({ zellij.pane(1, "nvim"), zellij.pane(2, "claude a"), zellij.pane(3, "claude b") })
    local asked = 0
    vim.ui.select = function(items, _, on_choice)
      asked = asked + 1
      on_choice(items[2])
    end
    file_buf({ "a" })

    for _ = 1, 2 do
      vim.cmd("1DiffyComment")
      type_body("x")
      vim.cmd("DiffySend")
      vim.wait(2000, function()
        return #comments.all() == 0
      end)
    end

    assert.are.equal(1, asked)
    local _, pastes = zellij.calls():gsub("paste %-%-pane%-id 3 ", "")
    assert.are.equal(2, pastes)
  end)

  it(":DiffySend keeps the comments when the paste fails", function()
    zellij.panes({ zellij.pane(1, "nvim"), zellij.pane(2, "claude") })
    file_buf({ "a" })
    vim.cmd("1DiffyComment")
    type_body("x")

    vim.env.ZELLIJ_FAIL = "1"
    vim.cmd("DiffySend")
    vim.env.ZELLIJ_FAIL = nil

    assert.are.same({ msg = "diffy: zellij action paste: pane gone", level = vim.log.levels.ERROR }, notes[#notes])
    assert.are.equal(1, #comments.all())
  end)

  it(":DiffySend reports an error outside zellij and keeps the comments", function()
    vim.fn.delete(zellij.bin .. "/panes.json")
    file_buf({ "a" })
    vim.cmd("1DiffyComment")
    type_body("x")
    vim.cmd("DiffySend")

    assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
    assert.truthy(notes[#notes].msg:find("list-panes", 1, true))
    assert.are.equal(1, #comments.all())
  end)

  it(":DiffySend reports an error when nvim is alone in its tab", function()
    zellij.panes({ zellij.pane(1, "nvim") })
    file_buf({ "a" })
    vim.cmd("1DiffyComment")
    type_body("x")
    vim.cmd("DiffySend")

    assert.are.same({ msg = "diffy: no other panes in this zellij tab", level = vim.log.levels.ERROR }, notes[#notes])
    assert.are.equal(1, #comments.all())
  end)

  it(":DiffySend with several pending opens the review popover instead of sending", function()
    zellij.panes({ zellij.pane(1, "nvim"), zellij.pane(2, "claude") })
    file_buf({ "a", "b" })
    vim.cmd("1DiffyComment")
    type_body("one")
    vim.cmd("2DiffyComment")
    type_body("two")
    vim.cmd("DiffySend")

    assert.are.equal(2, #support.floats())
    assert.are.equal("", zellij.calls())
    assert.are.equal(2, #comments.all())
    vim.cmd("normal q")
  end)

  it(":DiffySend! sends every pending comment", function()
    zellij.panes({ zellij.pane(1, "nvim"), zellij.pane(2, "claude") })
    file_buf({ "a", "b" })
    vim.cmd("1DiffyComment")
    type_body("one")
    vim.cmd("2DiffyComment")
    type_body("two")
    vim.cmd("DiffySend!")

    assert.truthy(zellij.calls():find("one", 1, true))
    assert.truthy(zellij.calls():find("two", 1, true))
    assert.are.same({}, comments.all())
  end)

  it(":DiffySend with nothing queued warns without touching zellij", function()
    zellij.panes({ zellij.pane(1, "nvim"), zellij.pane(2, "claude") })
    vim.cmd("DiffySend")

    assert.are.equal(vim.log.levels.WARN, notes[#notes].level)
    assert.are.equal("", zellij.calls())
  end)
end)
