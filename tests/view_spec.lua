local comments = require("diffy.comments")

local bin = vim.fn.tempname()
local root = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(bin, "p")
vim.fn.mkdir(root, "p")
vim.fn.writefile({
  "#!/bin/sh",
  'here="$(dirname "$0")"',
  'printf "%s\\n" "$*" >> "$here/calls.log"',
  'if [ -n "$JJ_FAIL" ]; then echo "Error: Revision \\"nope\\" doesn\'t exist" >&2; exit 1; fi',
  'cat "$here/diff.txt"',
}, bin .. "/jj")
vim.fn.setfperm(bin .. "/jj", "rwxr-xr-x")
vim.env.PATH = bin .. ":" .. vim.env.PATH
vim.fn.mkdir(root .. "/.jj", "p")
local sample = vim.fn.readfile("fixtures/sample.diff")
vim.cmd.cd(root)

local greeting = {}
for i = 1, 12 do
  greeting[i] = "line " .. i
end
vim.fn.writefile(greeting, root .. "/greeting.go")

local function diff_output(lines)
  vim.fn.writefile(lines, bin .. "/diff.txt")
end

local function last_jj_call()
  local calls = vim.fn.readfile(bin .. "/calls.log")
  return calls[#calls]
end

local function answer_input(text)
  vim.ui.input = function(_, on_confirm)
    on_confirm(text)
  end
end

vim.cmd.runtime("plugin/diffy.lua")

describe(":Diffy", function()
  local notes

  before_each(function()
    comments.clear()
    vim.cmd("silent! tabonly")
    diff_output(sample)
    notes = {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
  end)

  it("opens the working-copy diff read-only in a new tab", function()
    vim.cmd("Diffy")

    assert.are.equal(2, vim.fn.tabpagenr("$"))
    assert.are.equal("diff --git", last_jj_call())
    assert.are.same(sample, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.are.equal("diff", vim.bo.filetype)
    assert.is_false(vim.bo.modifiable)
  end)

  it("reviews against --from and narrows to paths", function()
    vim.cmd("Diffy --from main internal cmd")
    assert.are.equal("diff --git -r main..@ -- internal cmd", last_jj_call())
  end)

  it("turns a comment in the diff into a diff comment carrying its source", function()
    vim.cmd("Diffy --from main internal")
    answer_input("propagate?")
    vim.cmd("17DiffyComment")

    local c = comments.all()[1]
    assert.are.equal("diff", c.kind)
    assert.are.equal("main (filtered to: internal)", c.source)
    assert.are.same({ { path = "greeting.go", start = 10, finish = 10 } }, c.spans)
    assert.are.same({ { kind = "+", text = "\treturn nil" } }, c.snapshot)
  end)

  it("defaults the source to the parent revision", function()
    vim.cmd("Diffy")
    answer_input("x")
    vim.cmd("17DiffyComment")
    assert.are.equal("@-", comments.all()[1].source)
  end)

  it("refuses a comment on header lines only", function()
    vim.cmd("Diffy")
    answer_input("x")
    vim.cmd("19,24DiffyComment")

    assert.are.same({}, comments.all())
    assert.are.same({ msg = "diffy: no diff lines selected", level = vim.log.levels.ERROR }, notes[#notes])
  end)

  it("gf opens the file in a new tab at that line, then reuses that tab", function()
    vim.cmd("Diffy")
    local diff_tab = vim.fn.tabpagenr()
    vim.api.nvim_win_set_cursor(0, { 17, 0 })
    vim.cmd("normal gf")

    assert.are.equal(3, vim.fn.tabpagenr("$"))
    assert.are.equal(root .. "/greeting.go", vim.api.nvim_buf_get_name(0))
    assert.are.equal(10, vim.fn.line("."))

    vim.cmd("tabnext " .. diff_tab)
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    vim.cmd("normal gf")

    assert.are.equal(3, vim.fn.tabpagenr("$"))
    assert.are.equal(root .. "/greeting.go", vim.api.nvim_buf_get_name(0))
    assert.are.equal(1, vim.fn.line("."))
  end)

  it("gf resolves diff paths from the workspace root when nvim is in a subdirectory", function()
    vim.fn.mkdir(root .. "/sub", "p")
    vim.cmd.cd(root .. "/sub")
    vim.cmd("Diffy")
    vim.api.nvim_win_set_cursor(0, { 17, 0 })
    vim.cmd("normal gf")
    vim.cmd.cd(root)

    assert.are.equal(root .. "/greeting.go", vim.api.nvim_buf_get_name(0))
  end)

  it("gf lands on the last line when the file has shrunk since the diff", function()
    vim.fn.writefile({ "one", "two", "three" }, root .. "/greeting.go")
    vim.cmd("Diffy")
    vim.api.nvim_win_set_cursor(0, { 17, 0 })
    vim.cmd("normal gf")
    vim.cmd("bwipeout!")
    vim.fn.writefile(greeting, root .. "/greeting.go")

    assert.are.same({}, vim.tbl_filter(function(n)
      return n.level == vim.log.levels.ERROR
    end, notes))
  end)

  it("gf reports a file that no longer exists", function()
    vim.cmd("Diffy")
    vim.api.nvim_win_set_cursor(0, { 41, 0 })
    vim.cmd("normal gf")

    assert.are.equal(2, vim.fn.tabpagenr("$"))
    assert.are.same({ msg = "diffy: legacy.go does not exist in the working copy", level = vim.log.levels.ERROR }, notes[#notes])
  end)

  it("reopening the same diff replaces its tab", function()
    vim.cmd("Diffy")
    vim.cmd("tabfirst")
    vim.cmd("Diffy")
    assert.are.equal(2, vim.fn.tabpagenr("$"))
  end)

  it("reports jj's error and opens nothing", function()
    vim.env.JJ_FAIL = "1"
    vim.cmd("Diffy --from nope")
    vim.env.JJ_FAIL = nil

    assert.are.equal(1, vim.fn.tabpagenr("$"))
    assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
    assert.truthy(notes[#notes].msg:find('Revision "nope" doesn\'t exist', 1, true))
  end)

  it("says so when there are no changes", function()
    diff_output({})
    vim.cmd("Diffy")

    assert.are.equal(1, vim.fn.tabpagenr("$"))
    assert.are.same({ msg = "diffy: no changes", level = vim.log.levels.WARN }, notes[#notes])
  end)

  it("needs a revset after --from", function()
    vim.cmd("Diffy --from")

    assert.are.equal(1, vim.fn.tabpagenr("$"))
    assert.are.same({ msg = "diffy: --from needs a revset", level = vim.log.levels.ERROR }, notes[#notes])
  end)
end)
