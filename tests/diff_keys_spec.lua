local comments = require("diffy.comments")
local support = require("support")

local zellij = support.fake_zellij()
local bin = vim.fn.tempname()
local root = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(bin, "p")
vim.fn.mkdir(root .. "/.jj", "p")
vim.fn.writefile({ "#!/bin/sh", 'cat "$(dirname "$0")/diff.txt"' }, bin .. "/jj")
vim.fn.setfperm(bin .. "/jj", "rwxr-xr-x")
vim.env.PATH = bin .. ":" .. vim.env.PATH
local sample = vim.fn.readfile("fixtures/sample.diff")
vim.cmd.cd(root)
vim.cmd.runtime("plugin/diffy.lua")

local function diff_output(lines)
  vim.fn.writefile(lines, bin .. "/diff.txt")
end

local function keys(typed)
  vim.api.nvim_feedkeys(vim.keycode(typed), "x", false)
end

local function bodies()
  return vim.tbl_map(function(c)
    return c.body
  end, comments.all())
end

local function on(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
end

describe("keys in the diff buffer", function()
  local notes

  before_each(function()
    support.reset()
    zellij.reset()
    zellij.panes({ zellij.pane(1, "nvim"), zellij.pane(2, "claude") })
    vim.cmd("silent! tabonly")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):match("^diffy://") then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    diff_output(sample)
    vim.cmd("Diffy")
    notes = support.capture_notify()
  end)

  it("c comments on the cursor line", function()
    on(17)
    keys("cpropagate?<Esc><CR>")

    local c = comments.all()[1]
    assert.are.equal("propagate?", c.body)
    assert.are.same({ { path = "greeting.go", start = 10, finish = 10 } }, c.spans)
  end)

  it("c comments on a visual selection", function()
    on(30)
    keys("Vjjcsentinel?<Esc><CR>")

    assert.are.same({ { path = "math.go", start = 6, finish = 8 } }, comments.all()[1].spans)
  end)

  it("<CR> edits the comment under the cursor", function()
    on(17)
    keys("Vjcfirst<Esc><CR>")
    on(18)
    keys("<CR>A, revised<Esc><CR>")

    assert.are.same({ "first, revised" }, bodies())
  end)

  it("<CR> on a line without a comment says so", function()
    on(30)
    keys("celsewhere<Esc><CR>")
    on(17)
    keys("<CR>")

    assert.are.same({}, support.floats())
    assert.are.same({ msg = "diffy: no comment on this line", level = vim.log.levels.WARN }, notes[#notes])
  end)

  it("dd deletes the comments on the line", function()
    on(17)
    keys("cx<Esc><CR>")
    assert.are.equal(1, #comments.all())
    keys("dd")

    assert.are.same({}, comments.all())
  end)

  it("s sends the lone comment and S sends them all", function()
    on(17)
    keys("cone<Esc><CR>")
    keys("s")
    assert.truthy(zellij.calls():find("one", 1, true))
    assert.are.same({}, comments.all())

    on(17)
    keys("ctwo<Esc><CR>")
    on(30)
    keys("cthree<Esc><CR>")
    keys("S")
    assert.truthy(zellij.calls():find("three", 1, true))
    assert.are.same({}, comments.all())
  end)

  it("r refreshes the diff", function()
    local updated = vim.list_extend({ "diff --git a/z.go b/z.go", "@@ -0,0 +1 @@", "+package z" }, sample)
    diff_output(updated)
    keys("r")

    assert.are.same(updated, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  it("gr opens the review popover straight away", function()
    on(17)
    keys("cone<Esc><CR>")
    keys("gr")

    assert.are.equal(2, #support.floats())
  end)

  it("leaves those keys alone outside the diff buffer", function()
    vim.cmd.enew()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "old word" })
    keys("cwnew<Esc>")

    assert.are.same({ "new word" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.are.same({}, comments.all())
  end)
end)
