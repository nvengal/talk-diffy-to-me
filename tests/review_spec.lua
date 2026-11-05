local comments = require("diffy.comments")
local support = require("support")

local zellij = support.fake_zellij()
vim.cmd.runtime("plugin/diffy.lua")

local function comment(range, body)
  vim.cmd(range .. "DiffyComment")
  support.type_body(body)
end

local function lines(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function preview()
  local win = vim.tbl_filter(function(w)
    return not vim.api.nvim_win_get_config(w).focusable
  end, support.floats())[1]
  return lines(win)
end

local function bodies()
  return vim.tbl_map(function(c)
    return c.body
  end, comments.all())
end

describe(":DiffyReview", function()
  local buf, notes

  before_each(function()
    support.reset()
    zellij.reset()
    zellij.panes({ zellij.pane(1, "nvim"), zellij.pane(2, "claude") })
    for _, win in ipairs(support.floats()) do
      vim.api.nvim_win_close(win, true)
    end
    buf = support.file_buf("rev", { "a", "b", "c" })
    comment("1", "first\nmore detail")
    comment("2,3", "second")
    notes = support.capture_notify()
  end)

  it("lists pending comments in a float, flagging orphans, and previews the focused one", function()
    vim.api.nvim_buf_set_lines(buf, 1, 3, false, {})
    vim.cmd("DiffyReview")

    local name = "rev" .. buf .. ".go"
    assert.are.equal(2, #support.floats())
    assert.are.same({ name .. ":1  first", "[orphan] " .. name .. ":2-3  second" }, lines(0))
    assert.are.equal(" diffy: 2 pending ", vim.api.nvim_win_get_config(0).title[1][1])
    assert.is_true(vim.wo.cursorline)
    assert.are.same({ "## " .. name .. ":1", "", "first", "more detail", "", "```", "a", "```" }, preview())
  end)

  it("previews whichever comment the cursor moves to", function()
    vim.cmd("DiffyReview")
    vim.cmd("normal j")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })

    assert.are.equal("second", preview()[3])
  end)

  it("s sends only the focused comment and keeps the rest listed", function()
    vim.cmd("DiffyReview")
    vim.cmd("normal j")
    vim.cmd("normal s")

    assert.truthy(zellij.calls():find("second", 1, true))
    assert.falsy(zellij.calls():find("first", 1, true))
    assert.are.same({ "first\nmore detail" }, bodies())
    assert.are.equal(1, #lines(0))
  end)

  it("S sends everything and closes", function()
    vim.cmd("DiffyReview")
    vim.cmd("normal S")

    assert.truthy(zellij.calls():find("first", 1, true))
    assert.truthy(zellij.calls():find("second", 1, true))
    assert.are.same({}, comments.all())
    assert.are.same({}, support.floats())
  end)

  it("dd deletes the focused comment, closing once none are left", function()
    vim.cmd("DiffyReview")
    vim.cmd("normal dd")
    assert.are.same({ "second" }, bodies())
    assert.are.equal(1, #lines(0))

    vim.cmd("normal dd")
    assert.are.same({}, comments.all())
    assert.are.same({}, support.floats())
  end)

  it("<CR> edits the focused comment in the comment float, then returns to the list", function()
    vim.cmd("DiffyReview")
    local list = vim.api.nvim_get_current_win()
    vim.api.nvim_feedkeys(vim.keycode("j<CR>A, revised<Esc><CR>"), "x", false)

    assert.are.same({ "first\nmore detail", "second, revised" }, bodies())
    assert.are.equal(list, vim.api.nvim_get_current_win())
    assert.truthy(lines(0)[2]:find("second, revised", 1, true))
  end)

  it("s in the edit float saves and sends that comment, updating the list", function()
    vim.cmd("DiffyReview")
    vim.api.nvim_feedkeys(vim.keycode("j<CR>A!<Esc>s"), "x", false)

    assert.truthy(zellij.calls():find("second!", 1, true))
    assert.falsy(zellij.calls():find("first", 1, true))
    assert.are.same({ "first\nmore detail" }, bodies())
    assert.are.equal(1, #lines(0))
  end)

  it("gf closes the popover and puts the cursor on the comment", function()
    vim.cmd("DiffyReview")
    vim.cmd("normal j")
    vim.cmd("normal gf")

    assert.are.same({}, support.floats())
    assert.are.equal(1, vim.fn.tabpagenr("$"))
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
    assert.are.equal(2, vim.fn.line("."))
  end)

  it("gf on an orphan says there is nowhere to go", function()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
    vim.cmd("DiffyReview")
    vim.cmd("normal gf")

    assert.are.equal(2, #support.floats())
    assert.are.same({ msg = "diffy: orphaned comments have no location", level = vim.log.levels.WARN }, notes[#notes])
  end)

  for _, how in ipairs({ "normal q", "normal \27", "close" }) do
    it("closes the list and its preview with :" .. how:gsub("\27", "<Esc>"), function()
      vim.cmd("DiffyReview")
      vim.cmd(how)
      assert.are.same({}, support.floats())
    end)
  end

  it("warns instead of opening when nothing is pending", function()
    support.reset()
    vim.cmd("DiffyReview")

    assert.are.same({}, support.floats())
    assert.are.same({ msg = "diffy: no comments to review", level = vim.log.levels.WARN }, notes[#notes])
  end)
end)
