local support = require("support")

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

local function changed(...)
  local lines = {}
  for _, path in ipairs({ ... }) do
    vim.list_extend(lines, { ("diff --git a/%s b/%s"):format(path, path), "@@ -1 +1 @@", "-old", "+new" })
  end
  return lines
end

local function lines_of(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

---@return integer? win the tree window in the current tab
local function tree_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "diffytree" then
      return win
    end
  end
end

---@return integer win the diff window in the current tab
local function diff_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):match("^diffy://") then
      return win
    end
  end
  error("no diff window")
end

---@return integer[][] each closed fold of the diff window, as { first, last }
local function closed_folds()
  return vim.api.nvim_win_call(diff_win(), function()
    local folds, lnum = {}, 1
    while lnum <= vim.fn.line("$") do
      local first = vim.fn.foldclosed(lnum)
      if first == -1 then
        lnum = lnum + 1
      else
        table.insert(folds, { first, vim.fn.foldclosedend(lnum) })
        lnum = vim.fn.foldclosedend(lnum) + 1
      end
    end
    return folds
  end)
end

local function select(label)
  local win = tree_win()
  vim.api.nvim_set_current_win(win)
  for i, line in ipairs(lines_of(win)) do
    if vim.trim(line):match("^" .. vim.pesc(label)) then
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      return keys("<CR>")
    end
  end
  error("no tree line for " .. label)
end

describe("file tree", function()
  before_each(function()
    support.reset()
    vim.cmd("silent! tabonly")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):match("^diffy") then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    diff_output(sample)
    vim.cmd("Diffy")
  end)

  it("starts beside the diff, listing the changed files", function()
    assert.are.equal(diff_win(), vim.api.nvim_get_current_win())
    assert.are.same({
      "@-",
      "  greeting.go  +6 -2",
      "  math.go      +10 -0",
      "  legacy.go    +0 -4",
    }, lines_of(tree_win()))
  end)

  it("T toggles the tree, from either window", function()
    keys("T")
    assert.is_nil(tree_win())

    keys("T")
    assert.are.equal(tree_win(), vim.api.nvim_get_current_win())

    keys("T")
    assert.is_nil(tree_win())
  end)

  it("nests directories, compacting single-directory chains", function()
    diff_output(changed("lua/diffy/a.lua", "lua/diffy/b.lua", "plugin/x.lua", "README.md"))
    keys("r")

    assert.are.same({
      "@-",
      "  lua/diffy/",
      "    a.lua    +1 -1",
      "    b.lua    +1 -1",
      "  plugin/",
      "    x.lua    +1 -1",
      "  README.md  +1 -1",
    }, lines_of(tree_win()))
  end)

  it("<CR> on a file narrows the diff to it", function()
    select("math.go")

    assert.are.same({ { 1, 18 }, { 35, 44 } }, closed_folds())
    assert.are.equal(diff_win(), vim.api.nvim_get_current_win())
    assert.are.equal(19, vim.fn.line("."))
    assert.are.equal("··· 1 file hidden ···", vim.fn.foldtextresult(1))
  end)

  it("<CR> on a directory narrows the diff to every file under it", function()
    diff_output(changed("lua/diffy/a.lua", "lua/diffy/b.lua", "plugin/x.lua", "README.md"))
    keys("r")
    select("lua/diffy/")

    assert.are.same({ { 9, 16 } }, closed_folds())
    assert.are.equal("··· 2 files hidden ···", vim.fn.foldtextresult(9))
  end)

  it("<CR> on the root shows every file again", function()
    select("math.go")
    select("@-")

    assert.are.same({}, closed_folds())
    assert.are.equal(19, vim.fn.line("."))
  end)

  it("T closing the tree shows every file again", function()
    select("math.go")
    keys("T")

    assert.is_nil(tree_win())
    assert.are.same({}, closed_folds())
  end)

  it("keeps the narrowing across a refresh", function()
    select("math.go")
    diff_output(vim.list_extend(changed("z.go"), sample))
    keys("r")

    assert.are.same({ { 1, 22 }, { 39, 48 } }, closed_folds())
    assert.are.equal("  z.go         +1 -1", lines_of(tree_win())[2])
  end)

  it("shows everything when a refresh drops the narrowed file", function()
    select("math.go")
    diff_output(changed("z.go"))
    keys("r")

    assert.are.same({}, closed_folds())
  end)

  it("counts pending comments per file", function()
    vim.api.nvim_win_set_cursor(0, { 17, 0 })
    keys("cpropagate?<Esc><CR>")

    assert.are.equal("  greeting.go  +6 -2  ▸1", lines_of(tree_win())[2])
  end)

  it("widens to fit a comment count", function()
    vim.api.nvim_win_set_cursor(0, { 17, 0 })
    keys("cpropagate?<Esc><CR>")

    local widest = math.max(unpack(vim.tbl_map(vim.fn.strdisplaywidth, lines_of(tree_win()))))
    assert.is_true(vim.api.nvim_win_get_width(tree_win()) > widest)
  end)

  it("counts a comment spanning two hunks of a file once", function()
    diff_output({ "diff --git a/a.go b/a.go", "@@ -1 +1 @@", "-x", "+y", "@@ -9 +9 @@", "-p", "+q" })
    keys("r")
    keys("3GV6Gcboth<Esc><CR>")

    assert.are.equal("  a.go  +2 -2  ▸1", lines_of(tree_win())[2])
  end)

  it("stays as it was when :Diffy returns to its tab", function()
    keys("T")
    vim.cmd("tabnew")
    vim.cmd("Diffy")

    assert.is_nil(tree_win())
  end)

  it("goes away with the diff", function()
    local tree = vim.api.nvim_win_get_buf(tree_win())
    vim.api.nvim_buf_delete(vim.api.nvim_win_get_buf(diff_win()), { force = true })

    assert.is_false(vim.api.nvim_buf_is_valid(tree))
  end)
end)
