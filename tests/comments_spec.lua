local comments = require("diffy.comments")

local function file_buf(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/sub/x" .. buf .. ".go")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function sign_lines(buf)
  local placed = vim.fn.sign_getplaced(buf, { group = "*" })[1].signs
  return vim.tbl_map(function(s)
    return s.lnum
  end, placed)
end

local function add(buf, first, last, body)
  comments.add(buf, body, comments.file_target(buf, first, last))
end

local function lines_of(c)
  return { c.spans[1].start, c.spans[1].finish }
end

describe("comments", function()
  before_each(comments.clear)

  it("records a file comment with its path, range, and snapshot", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    add(buf, 2, 3, "why?")

    assert.are.same({
      {
        kind = "file",
        spans = { { path = "sub/x" .. buf .. ".go", start = 2, finish = 3 } },
        body = "why?",
        orphan = false,
        snapshot = { { kind = " ", text = "b" }, { kind = " ", text = "c" } },
      },
    }, comments.all())
  end)

  describe("path", function()
    local cwd = vim.fn.getcwd()
    after_each(function()
      vim.cmd.cd(cwd)
    end)

    local function path_in(dir, name)
      vim.fn.mkdir(dir, "p")
      vim.cmd.cd(dir)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, dir .. "/" .. name)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a" })
      return comments.file_target(buf, 1, 1).spans[1].path
    end

    it("is relative to the jj workspace root, even from a subdirectory", function()
      local root = vim.fn.resolve(vim.fn.tempname())
      vim.fn.mkdir(root .. "/.jj", "p")
      assert.are.equal("sub/a.go", path_in(root .. "/sub", "a.go"))
    end)

    it("names a file from another jj workspace by its full path", function()
      local other = vim.fn.resolve(vim.fn.tempname())
      vim.fn.mkdir(other .. "/.jj", "p")
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, other .. "/b.go")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b" })
      assert.are.equal(other .. "/b.go", comments.file_target(buf, 1, 1).spans[1].path)
    end)

    it("is relative to the working directory outside a jj workspace", function()
      assert.are.equal("a.go", path_in(vim.fn.resolve(vim.fn.tempname()), "a.go"))
    end)
  end)

  it("follows its lines when text is inserted above", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    add(buf, 2, 3, "why?")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new" })

    local c = comments.all()[1]
    assert.are.same({ 3, 4 }, lines_of(c))
    assert.are.same("b", c.snapshot[1].text)
  end)

  it("marks every covered line in the sign column", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    add(buf, 2, 3, "why?")
    assert.are.same({ 2, 3 }, sign_lines(buf))
  end)

  it("becomes an orphan at its last known lines when they are deleted", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    add(buf, 2, 3, "why?")
    vim.api.nvim_buf_set_lines(buf, 1, 3, false, {})

    local c = comments.all()[1]
    assert.is_true(c.orphan)
    assert.are.same({ 2, 3 }, lines_of(c))
    assert.are.same("c", c.snapshot[2].text)
    assert.are.same({}, sign_lines(buf))
  end)

  it("restores its lines and signs when the deletion is undone", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].undolevels = 100
    add(buf, 2, 3, "why?")
    vim.cmd("normal! 2Gdj")
    vim.cmd("undo")

    local c = comments.all()[1]
    assert.is_false(c.orphan)
    assert.are.same({ 2, 3 }, lines_of(c))
    assert.are.same({ 2, 3 }, sign_lines(buf))
  end)

  it("removes every comment covering a line", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    add(buf, 1, 2, "one")
    add(buf, 2, 3, "two")
    add(buf, 4, 4, "three")

    assert.are.equal(2, comments.remove_at(buf, 2))
    assert.are.same({ "three" }, vim.tbl_map(function(c)
      return c.body
    end, comments.all()))
    assert.are.same({ 4 }, sign_lines(buf))

    comments.remove_at(buf, 4)
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}))
  end)

  it("keeps a diff comment's spans and source while marking the rows it was made on", function()
    local buf = file_buf({ "@@ -38,2 +38,2 @@", "-a", "+b" })
    local snapshot = { { kind = "-", text = "a" }, { kind = "+", text = "b" } }
    comments.add(buf, "why?", {
      kind = "diff",
      source = "@-",
      spans = { { path = "a.go", start = 38, finish = 38, first = 2, last = 3, lines = snapshot } },
      snapshot = snapshot,
    })

    assert.are.same({
      {
        kind = "diff",
        source = "@-",
        spans = { { path = "a.go", start = 38, finish = 38 } },
        body = "why?",
        orphan = false,
        snapshot = snapshot,
      },
    }, comments.all())
    assert.are.same({ 2, 3 }, sign_lines(buf))
    assert.are.equal(1, comments.remove_at(buf, 3))
  end)

  it("marks only the rows of each span of a comment that crosses hunks", function()
    local buf = file_buf({ "@@ -1 +1 @@", "+x", "@@ -9 +9 @@", "+y" })
    comments.add(buf, "both", {
      kind = "diff",
      source = "@-",
      spans = {
        { path = "a.go", start = 1, finish = 1, first = 2, last = 2, lines = { { kind = "+", text = "x" } } },
        { path = "a.go", start = 9, finish = 9, first = 4, last = 4, lines = { { kind = "+", text = "y" } } },
      },
      snapshot = {},
    })

    assert.are.same({ 2, 4 }, sign_lines(buf))
    assert.are.equal(0, comments.remove_at(buf, 3))
    assert.are.equal(1, comments.remove_at(buf, 4))
  end)

  describe("when its file is reloaded", function()
    local function disk_buf(lines)
      local file = vim.fn.resolve(vim.fn.tempname()) .. ".go"
      vim.fn.writefile(lines, file)
      vim.cmd.edit(file)
      return vim.api.nvim_get_current_buf(), file
    end

    local function reload(file, lines)
      vim.fn.writefile(lines, file)
      vim.cmd("edit!")
    end

    it("follows its text to where it now is", function()
      local buf, file = disk_buf({ "a", "b", "c", "d" })
      add(buf, 3, 3, "why?")
      reload(file, { "new", "a", "b", "c", "d" })

      local c = comments.all()[1]
      assert.is_false(c.orphan)
      assert.are.same({ 4, 4 }, lines_of(c))
      assert.are.same({ 4 }, sign_lines(buf))
    end)

    it("picks the copy of repeated lines nearest to where it was", function()
      local buf, file = disk_buf({ "}", "a", "b", "}" })
      add(buf, 4, 4, "why?")
      reload(file, { "new", "}", "a", "b", "}" })

      assert.are.same({ 5, 5 }, lines_of(comments.all()[1]))
    end)

    it("becomes an orphan when its text is gone", function()
      local buf, file = disk_buf({ "a", "b", "c" })
      add(buf, 2, 2, "why?")
      reload(file, { "a", "c" })

      assert.is_true(comments.all()[1].orphan)
      assert.are.same({}, sign_lines(buf))
    end)

    it("leaves other files' comments where they are", function()
      local a, file_a = disk_buf({ "a", "b" })
      add(a, 2, 2, "in a")
      local b = disk_buf({ "x", "b" })
      add(b, 2, 2, "in b")
      vim.cmd.buffer(a)
      reload(file_a, { "b", "a" })

      assert.are.same({ 1 }, sign_lines(a))
      assert.are.same({ 2 }, sign_lines(b))
    end)

    it("reattaches when its file is closed and opened again", function()
      local buf, file = disk_buf({ "a", "b", "c" })
      add(buf, 2, 2, "why?")
      vim.cmd("bwipeout! " .. buf)
      assert.is_true(comments.all()[1].orphan)

      vim.cmd.edit(file)
      assert.is_false(comments.all()[1].orphan)
      assert.are.same({ 2 }, sign_lines(vim.api.nvim_get_current_buf()))
    end)
  end)

  it("keeps each buffer's comments and signs to itself", function()
    local a = file_buf({ "a", "b" })
    local b = file_buf({ "a", "b" })
    add(a, 1, 1, "in a")
    add(b, 2, 2, "in b")

    assert.are.same({ 1 }, sign_lines(a))
    assert.are.same({ 2 }, sign_lines(b))
    assert.are.equal(0, comments.remove_at(a, 2))
    assert.are.equal(2, #comments.all())
  end)

  it("clears all comments and leaves no marks behind", function()
    local buf = file_buf({ "a", "b" })
    add(buf, 1, 1, "one")
    comments.clear()

    assert.are.same({}, comments.all())
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}))
  end)
end)
