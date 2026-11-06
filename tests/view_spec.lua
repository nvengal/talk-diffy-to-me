local comments = require("diffy.comments")
local support = require("support")

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

local type_body = support.type_body

vim.cmd.runtime("plugin/diffy.lua")

describe(":Diffy", function()
  local notes

  before_each(function()
    support.reset()
    vim.cmd("tabnew")
    vim.cmd("silent! tabonly")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):match("^diffy://") then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    diff_output(sample)
    notes = support.capture_notify()
  end)

  it("opens the working-copy diff read-only in a new tab", function()
    vim.cmd("Diffy")

    assert.are.equal(2, vim.fn.tabpagenr("$"))
    assert.are.equal("diff --git", last_jj_call())
    assert.are.same(sample, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.are.equal("diff", vim.bo.filetype)
    assert.is_false(vim.bo.modifiable)
  end)

  it("lists the diff with your buffers, so buffer navigation reaches it from a file", function()
    vim.cmd("Diffy")
    local diff_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 17, 0 })
    vim.cmd("normal gf")
    for _ = 1, #vim.fn.getbufinfo({ buflisted = 1 }) do
      if vim.api.nvim_get_current_buf() == diff_buf then
        break
      end
      vim.cmd("bnext")
    end

    assert.are.equal(diff_buf, vim.api.nvim_get_current_buf())
  end)

  it("reviews against --from and narrows to paths", function()
    vim.cmd("Diffy --from main internal cmd")
    assert.are.equal("diff --git --from fork_point((main) | @) -- internal cmd", last_jj_call())
  end)

  it("turns a comment in the diff into a diff comment carrying its source", function()
    vim.cmd("Diffy --from main internal")
    vim.cmd("17DiffyComment")
    type_body("propagate?")

    local c = comments.all()[1]
    assert.are.equal("diff", c.kind)
    assert.are.equal("main (filtered to: internal)", c.source)
    assert.are.same({ { path = "greeting.go", start = 10, finish = 10 } }, c.spans)
    assert.are.same({ { kind = "+", text = "\treturn nil" } }, c.snapshot)
  end)

  it("edits a diff comment when its rows are commented on again", function()
    vim.cmd("Diffy")
    vim.cmd("17,18DiffyComment")
    type_body("first")
    vim.cmd("17,18DiffyComment")
    type_body("revised")

    assert.are.same({ "revised" }, vim.tbl_map(function(c)
      return c.body
    end, comments.all()))
  end)

  it("defaults the source to the parent revision", function()
    vim.cmd("Diffy")
    vim.cmd("17DiffyComment")
    type_body("x")
    assert.are.equal("@-", comments.all()[1].source)
  end)

  it("refuses a comment on header lines only", function()
    vim.cmd("Diffy")
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

  describe("refresh", function()
    local function with(at, extra)
      local out = vim.list_slice(sample, 1, at - 1)
      vim.list_extend(out, extra)
      return vim.list_extend(out, vim.list_slice(sample, at))
    end

    local sign_lines = support.sign_lines

    local function commented_diff()
      vim.cmd("Diffy")
      vim.cmd("17DiffyComment")
      type_body("propagate?")
      return vim.api.nvim_get_current_buf()
    end

    it(":e re-runs jj and moves diff comments with their lines", function()
      local buf = commented_diff()
      local updated = with(17, { "+\t// one", "+\t// two" })
      diff_output(updated)
      vim.cmd("edit")

      assert.are.same(updated, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.is_false(vim.bo[buf].modifiable)
      local c = comments.all()[1]
      assert.is_false(c.orphan)
      assert.are.same({ { path = "greeting.go", start = 12, finish = 12 } }, c.spans)
      assert.are.same({ 19 }, sign_lines(buf))
    end)

    local function place(row, top)
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      vim.fn.winrestview({ topline = top })
    end

    local function placed()
      return { vim.fn.line("."), vim.fn.line("w0") }
    end

    it(":e keeps the cursor on its line, at the same height on screen", function()
      vim.cmd("Diffy")
      place(17, 10)
      diff_output(with(17, { "+\t// one", "+\t// two" }))
      vim.cmd("edit")

      assert.are.same({ 19, 12 }, placed())
    end)

    it(":Diffy again keeps the cursor on its line too", function()
      vim.cmd("Diffy")
      place(17, 10)
      diff_output(with(1, { "diff --git a/z.go b/z.go", "@@ -0,0 +1 @@", "+package z" }))
      vim.cmd("Diffy")

      assert.are.same({ 20, 13 }, placed())
    end)

    it(":e leaves the cursor where it was when its line is gone", function()
      vim.cmd("Diffy")
      place(17, 10)
      local changed = vim.deepcopy(sample)
      changed[17] = "+\treturn err"
      diff_output(changed)
      vim.cmd("edit")

      assert.are.same({ 17, 10 }, placed())
    end)

    it(":e moves the cursor to the end when the diff shrinks past it", function()
      vim.cmd("Diffy")
      place(44, 30)
      diff_output(vim.list_slice(sample, 1, 18))
      vim.cmd("edit")

      assert.are.equal(18, vim.fn.line("."))
    end)

    it(":e orphans a diff comment whose lines are gone, keeping it to send", function()
      local buf = commented_diff()
      local changed = vim.deepcopy(sample)
      changed[17] = "+\treturn err"
      diff_output(changed)
      vim.cmd("edit")

      local c = comments.all()[1]
      assert.is_true(c.orphan)
      assert.are.equal("propagate?", c.body)
      assert.are.same({}, sign_lines(buf))
    end)

    it(":e keeps the old diff when jj fails", function()
      local buf = commented_diff()
      vim.env.JJ_FAIL = "1"
      vim.cmd("edit")
      vim.env.JJ_FAIL = nil

      assert.are.same(sample, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
      assert.are.same({ 17 }, sign_lines(buf))
    end)

    it(":e keeps the old diff when there are no changes left", function()
      local buf = commented_diff()
      diff_output({})
      vim.cmd("edit")

      assert.are.same(sample, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.are.same({ msg = "diffy: no changes", level = vim.log.levels.WARN }, notes[#notes])
    end)

    it(":Diffy with the same arguments returns to its tab and refreshes it", function()
      local buf = commented_diff()
      vim.cmd("tabfirst")
      diff_output(with(17, { "+\t// one" }))
      vim.cmd("Diffy")

      assert.are.equal(2, vim.fn.tabpagenr("$"))
      assert.are.equal(buf, vim.api.nvim_get_current_buf())
      assert.are.same({ 18 }, sign_lines(buf))
    end)

    it("leaves another diff's comments alone", function()
      local parent = commented_diff()
      vim.cmd("Diffy --from main")
      vim.cmd("17DiffyComment")
      type_body("on main")
      diff_output(with(17, { "+\t// one" }))
      vim.cmd("edit")

      assert.are.same({ 17 }, sign_lines(parent))
      assert.are.same({ 18 }, sign_lines(vim.api.nvim_get_current_buf()))
    end)

    it("a closed diff opened again picks its comments back up", function()
      local buf = commented_diff()
      vim.cmd("bwipeout " .. buf)
      assert.is_true(comments.all()[1].orphan)

      vim.cmd("Diffy")
      assert.is_false(comments.all()[1].orphan)
      assert.are.same({ 17 }, sign_lines(vim.api.nvim_get_current_buf()))
    end)
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
