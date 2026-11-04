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

describe("comments", function()
  before_each(comments.clear)

  it("records a file comment with its path, range, and snapshot", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    comments.add(buf, 2, 3, "why?")

    assert.are.same({
      {
        kind = "file",
        path = "sub/x" .. buf .. ".go",
        start = 2,
        finish = 3,
        body = "why?",
        orphan = false,
        snapshot = { { kind = " ", text = "b" }, { kind = " ", text = "c" } },
      },
    }, comments.all())
  end)

  it("follows its lines when text is inserted above", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    comments.add(buf, 2, 3, "why?")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new" })

    local c = comments.all()[1]
    assert.are.same({ 3, 4 }, { c.start, c.finish })
    assert.are.same("b", c.snapshot[1].text)
  end)

  it("marks every covered line in the sign column", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    comments.add(buf, 2, 3, "why?")
    assert.are.same({ 2, 3 }, sign_lines(buf))
  end)

  it("becomes an orphan at its last known lines when they are deleted", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    comments.add(buf, 2, 3, "why?")
    vim.api.nvim_buf_set_lines(buf, 1, 3, false, {})

    local c = comments.all()[1]
    assert.is_true(c.orphan)
    assert.are.same({ 2, 3 }, { c.start, c.finish })
    assert.are.same("c", c.snapshot[2].text)
    assert.are.same({}, sign_lines(buf))
  end)

  it("restores its lines and signs when the deletion is undone", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].undolevels = 100
    comments.add(buf, 2, 3, "why?")
    vim.cmd("normal! 2Gdj")
    vim.cmd("undo")

    local c = comments.all()[1]
    assert.is_false(c.orphan)
    assert.are.same({ 2, 3 }, { c.start, c.finish })
    assert.are.same({ 2, 3 }, sign_lines(buf))
  end)

  it("removes every comment covering a line", function()
    local buf = file_buf({ "a", "b", "c", "d" })
    comments.add(buf, 1, 2, "one")
    comments.add(buf, 2, 3, "two")
    comments.add(buf, 4, 4, "three")

    assert.are.equal(2, comments.remove_at(buf, 2))
    assert.are.same({ "three" }, vim.tbl_map(function(c)
      return c.body
    end, comments.all()))
    assert.are.same({ 4 }, sign_lines(buf))
  end)

  it("keeps each buffer's comments and signs to itself", function()
    local a = file_buf({ "a", "b" })
    local b = file_buf({ "a", "b" })
    comments.add(a, 1, 1, "in a")
    comments.add(b, 2, 2, "in b")

    assert.are.same({ 1 }, sign_lines(a))
    assert.are.same({ 2 }, sign_lines(b))
    assert.are.equal(0, comments.remove_at(a, 2))
    assert.are.equal(2, #comments.all())
  end)

  it("clears all comments and leaves no marks behind", function()
    local buf = file_buf({ "a", "b" })
    comments.add(buf, 1, 1, "one")
    comments.clear()

    assert.are.same({}, comments.all())
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}))
  end)
end)
