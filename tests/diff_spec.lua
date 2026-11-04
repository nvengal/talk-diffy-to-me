local diff = require("diffy.diff")

local sample = diff.parse(vim.fn.readfile("fixtures/sample.diff"))

local function locations(target)
  return vim.tbl_map(function(s)
    return { path = s.path, start = s.start, finish = s.finish }
  end, target.spans)
end

describe("diff.target", function()
  it("anchors a single added line at its new-side number", function()
    assert.are.same({
      kind = "diff",
      source = "@-",
      spans = {
        { path = "greeting.go", start = 10, finish = 10, first = 17, last = 17, lines = { { kind = "+", text = "\treturn nil" } } },
      },
      snapshot = { { kind = "+", text = "\treturn nil" } },
    }, diff.target(sample, 17, 17, "@-"))
  end)

  it("anchors a range inside one hunk", function()
    assert.are.same({ { path = "math.go", start = 6, finish = 8 } }, locations(diff.target(sample, 30, 32, "@-")))
  end)

  it("numbers removed lines from the old side", function()
    assert.are.same({ { path = "legacy.go", start = 1, finish = 2 } }, locations(diff.target(sample, 41, 42, "@-")))
  end)

  it("does not count added lines on the old side", function()
    local rows = diff.parse({ "diff --git a/a b/a", "@@ -5,1 +5,1 @@", "+new", "-old" })
    assert.are.same({ { path = "a", start = 5, finish = 5 } }, locations(diff.target(rows, 4, 4, "@-")))
  end)

  it("treats a blank line inside a hunk as context", function()
    assert.are.same({ kind = " ", text = "" }, diff.target(sample, 7, 7, "@-").snapshot[1])
  end)

  it("spans files, keeping the selected headers verbatim", function()
    local t = diff.target(sample, 17, 26, "main")
    assert.are.same({
      { path = "greeting.go", start = 10, finish = 11 },
      { path = "math.go", start = 1, finish = 2 },
    }, locations(t))
    assert.are.same({
      { kind = "+", text = "\treturn nil" },
      { kind = " ", text = "}" },
      { kind = "", text = "diff --git a/math.go b/math.go" },
      { kind = "", text = "new file mode 100644" },
      { kind = "", text = "index 0000000..1111111" },
      { kind = "", text = "--- /dev/null" },
      { kind = "", text = "+++ b/math.go" },
      { kind = "", text = "@@ -0,0 +1,7 @@" },
      { kind = "+", text = "package main" },
      { kind = "+", text = "" },
    }, t.snapshot)
  end)

  it("gives each hunk of one file its own span", function()
    local rows = diff.parse({
      "diff --git a/a.go b/a.go",
      "@@ -1,2 +1,2 @@",
      " one",
      "-two",
      "@@ -40,1 +40,1 @@",
      "+forty",
    })
    assert.are.same({
      { path = "a.go", start = 1, finish = 2 },
      { path = "a.go", start = 40, finish = 40 },
    }, locations(diff.target(rows, 3, 6, "@-")))
  end)

  it("keeps a no-newline marker inside its hunk's span", function()
    local rows = diff.parse({
      "diff --git a/a b/a",
      "@@ -1 +1 @@",
      "-x",
      "\\ No newline at end of file",
      "+y",
    })
    local t = diff.target(rows, 3, 5, "@-")
    assert.are.same({ { path = "a", start = 1, finish = 1 } }, locations(t))
    assert.are.same({ kind = "", text = "\\ No newline at end of file" }, t.snapshot[2])
  end)

  it("refuses a selection with no diff lines", function()
    local t, err = diff.target(sample, 19, 24, "@-")
    assert.is_nil(t)
    assert.are.equal("no diff lines selected", err)
  end)
end)

describe("diff.jump", function()
  it("goes to the new-side line of an added or context line", function()
    assert.are.same({ "greeting.go", 10 }, { diff.jump(sample, 17) })
  end)

  it("goes to the old-side line of a removed line", function()
    assert.are.same({ "greeting.go", 5 }, { diff.jump(sample, 10) })
  end)

  it("goes to a hunk's new start, or the top when the file was deleted", function()
    assert.are.same({ "math.go", 1 }, { diff.jump(sample, 24) })
    assert.are.same({ "legacy.go", 1 }, { diff.jump(sample, 40) })
  end)

  it("goes to the top of the file from its headers", function()
    assert.are.same({ "greeting.go", 1 }, { diff.jump(sample, 1) })
  end)
end)

describe("diff paths", function()
  it("follows a rename, even from the header line above it", function()
    local rows = diff.parse({
      "diff --git a/old.go b/new.go",
      "similarity index 90%",
      "rename from old.go",
      "rename to new.go",
      "@@ -1,1 +1,1 @@",
      "-a",
      "+b",
    })
    assert.are.same({ "new.go", 1 }, { diff.jump(rows, 1) })
    assert.are.same({ { path = "new.go", start = 1, finish = 1 } }, locations(diff.target(rows, 6, 7, "@-")))
  end)

  for _, verb in ipairs({ "rename", "copy" }) do
    it("trusts '" .. verb .. " to' over an ambiguous header", function()
      local rows = diff.parse({
        "diff --git a/x b/y b/z",
        verb .. " from x",
        verb .. " to y b/z",
        "@@ -1 +1 @@",
        "+q",
      })
      assert.are.same({ "y b/z", 1 }, { diff.jump(rows, 5) })
    end)
  end

  it("reads a path that itself contains ' b/'", function()
    local rows = diff.parse({ "diff --git a/x b/y.go b/x b/y.go", "@@ -1 +1 @@", "+z" })
    assert.are.same({ "x b/y.go", 1 }, { diff.jump(rows, 3) })
  end)
end)

describe("diff.find", function()
  local lines = vim.fn.readfile("fixtures/sample.diff")

  local function with(at, extra)
    local out = vim.list_slice(lines, 1, at - 1)
    vim.list_extend(out, extra)
    return vim.list_extend(out, vim.list_slice(lines, at))
  end

  local function span_at(first, last)
    return diff.target(sample, first, last, "@-").spans[1]
  end

  it("follows a span when lines are added above it, renumbering it", function()
    local rows = diff.parse(with(17, { "+\t// one", "+\t// two" }))
    assert.are.same({ first = 19, last = 19, start = 12, finish = 12 }, diff.find(rows, span_at(17, 17)))
  end)

  it("finds a span after the files around it change", function()
    local rows = diff.parse(with(1, { "diff --git a/z.go b/z.go", "@@ -0,0 +1 @@", "+package z" }))
    assert.are.same({ first = 33, last = 35, start = 6, finish = 8 }, diff.find(rows, span_at(30, 32)))
  end)

  it("chooses the occurrence nearest to where the span was", function()
    local rows = diff.parse({
      "diff --git a/a b/a",
      "@@ -0,0 +1,5 @@",
      "+}",
      "+x",
      "+y",
      "+}",
    })
    local later = diff.target(rows, 6, 6, "@-").spans[1]
    local shifted = diff.parse({ "diff --git a/a b/a", "@@ -0,0 +1,6 @@", "+new", "+}", "+x", "+y", "+}" })
    assert.are.same({ first = 7, last = 7, start = 5, finish = 5 }, diff.find(shifted, later))
  end)

  it("finds a span with a no-newline marker inside it", function()
    local rows = diff.parse({ "diff --git a/a b/a", "@@ -1 +1 @@", "-x", "\\ No newline at end of file", "+y" })
    local span = diff.target(rows, 3, 5, "@-").spans[1]
    assert.are.same({ first = 3, last = 5, start = 1, finish = 1 }, diff.find(rows, span))
  end)

  it("gives up when the text, the kind, or the file differs", function()
    local span = span_at(17, 17)
    local function find_after(at, replacement)
      local changed = vim.deepcopy(lines)
      changed[at] = replacement
      return diff.find(diff.parse(changed), span)
    end

    assert.is_nil(find_after(17, "+\treturn err"))
    assert.is_nil(find_after(17, " \treturn nil"))
    assert.is_nil(diff.find(diff.parse({ "diff --git a/b.go b/b.go", "@@ -0,0 +1 @@", "+\treturn nil" }), span))
  end)
end)
