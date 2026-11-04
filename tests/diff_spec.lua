local diff = require("diffy.diff")

local sample = diff.parse(vim.fn.readfile("fixtures/sample.diff"))

describe("diff.target", function()
  it("anchors a single added line at its new-side number", function()
    assert.are.same({
      kind = "diff",
      source = "@-",
      spans = { { path = "greeting.go", start = 10, finish = 10 } },
      snapshot = { { kind = "+", text = "\treturn nil" } },
    }, diff.target(sample, 17, 17, "@-"))
  end)

  it("anchors a range inside one hunk", function()
    assert.are.same({ { path = "math.go", start = 6, finish = 8 } }, diff.target(sample, 30, 32, "@-").spans)
  end)

  it("numbers removed lines from the old side", function()
    assert.are.same({ { path = "legacy.go", start = 1, finish = 2 } }, diff.target(sample, 41, 42, "@-").spans)
  end)

  it("does not count added lines on the old side", function()
    local rows = diff.parse({ "diff --git a/a b/a", "@@ -5,1 +5,1 @@", "+new", "-old" })
    assert.are.same({ { path = "a", start = 5, finish = 5 } }, diff.target(rows, 4, 4, "@-").spans)
  end)

  it("treats a blank line inside a hunk as context", function()
    assert.are.same({ kind = " ", text = "" }, diff.target(sample, 7, 7, "@-").snapshot[1])
  end)

  it("spans files, keeping the selected headers verbatim", function()
    local t = diff.target(sample, 17, 26, "main")
    assert.are.same({
      { path = "greeting.go", start = 10, finish = 11 },
      { path = "math.go", start = 1, finish = 2 },
    }, t.spans)
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
    }, diff.target(rows, 3, 6, "@-").spans)
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
    assert.are.same({ { path = "a", start = 1, finish = 1 } }, t.spans)
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
    assert.are.same({ { path = "new.go", start = 1, finish = 1 } }, diff.target(rows, 6, 7, "@-").spans)
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
