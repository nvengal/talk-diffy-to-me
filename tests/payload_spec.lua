local payload = require("diffy.payload")

local preamble =
  "The following are review comments. Respond to questions within this conversation (not in code comments). Make requested changes.\n"

local function file_comment(path, start, finish)
  return {
    kind = "file",
    spans = { { path = path, start = start, finish = finish } },
    body = "b",
    snapshot = { { kind = " ", text = "x" } },
  }
end

describe("payload.build", function()
  it("renders a diff comment with its source and a diff fence", function()
    local out = payload.build({
      {
        kind = "diff",
        source = "@-",
        spans = { { path = "greeting.go", start = 10, finish = 10 } },
        body = "why return nil here? could we propagate?",
        snapshot = { { kind = "+", text = "\treturn nil" } },
      },
    })

    assert.are.equal(
      preamble
        .. "\nDiff from: @-\n"
        .. "\n## greeting.go:10\n\n"
        .. "why return nil here? could we propagate?\n\n"
        .. "```diff\n+\treturn nil\n```\n",
      out
    )
  end)

  it("renders a file comment range with a plain fence and no source line", function()
    local out = payload.build({
      {
        kind = "file",
        spans = { { path = "internal/tui/app.go", start = 42, finish = 43 } },
        body = "this probably wants a mutex",
        snapshot = {
          { kind = " ", text = "    m.comments = append(m.comments, c)" },
          { kind = " ", text = "    return m" },
        },
      },
    })

    assert.are.equal(
      preamble
        .. "\n## internal/tui/app.go:42-43\n\n"
        .. "this probably wants a mutex\n\n"
        .. "```\n    m.comments = append(m.comments, c)\n    return m\n```\n",
      out
    )
  end)

  it("lists every span of a comment that crosses hunks and files, keeping selected headers verbatim", function()
    local out = payload.build({
      {
        kind = "diff",
        source = "main",
        spans = {
          { path = "a.go", start = 10, finish = 12 },
          { path = "a.go", start = 40, finish = 40 },
          { path = "b.go", start = 1, finish = 3 },
        },
        body = "share one error type",
        snapshot = {
          { kind = "+", text = "x" },
          { kind = "", text = "@@ -38,4 +38,5 @@" },
          { kind = "-", text = "y" },
        },
      },
    })

    assert.truthy(out:find("\n## a.go:10-12, 40; b.go:1-3\n", 1, true))
    assert.truthy(out:find("```diff\n+x\n@@ -38,4 +38,5 @@\n-y\n```\n", 1, true))
  end)

  it("names each distinct diff source once, ignoring file comments", function()
    local function diff_comment(source)
      return {
        kind = "diff",
        source = source,
        spans = { { path = "a.go", start = 1, finish = 1 } },
        body = "b",
        snapshot = { { kind = "+", text = "x" } },
      }
    end
    local out = payload.build({ diff_comment("@-"), file_comment("c.go", 1, 1), diff_comment("main"), diff_comment("@-") })
    assert.truthy(out:find("\nDiff from: @-, main\n", 1, true))
  end)

  it("emits sections in authored order", function()
    local out = payload.build({ file_comment("b.go", 1, 1), file_comment("a.go", 1, 1) })
    assert.is_true(out:find("## b.go:1", 1, true) < out:find("## a.go:1", 1, true))
  end)
end)

describe("payload.location", function()
  it("groups consecutive spans by path", function()
    assert.are.equal(
      "a.go:1, 5-6; b.go:2; a.go:9",
      payload.location({
        { path = "a.go", start = 1, finish = 1 },
        { path = "a.go", start = 5, finish = 6 },
        { path = "b.go", start = 2, finish = 2 },
        { path = "a.go", start = 9, finish = 9 },
      })
    )
  end)
end)
