local payload = require("diffy.payload")

local preamble =
  "The following are review comments. Respond to questions within this conversation (not in code comments). Make requested changes.\n"

describe("payload.build", function()
  it("renders a diff comment with its source and a diff fence", function()
    local out = payload.build({
      {
        kind = "diff",
        path = "greeting.go",
        start = 10,
        finish = 10,
        body = "why return nil here? could we propagate?",
        snapshot = { { kind = "+", text = "\treturn nil" } },
      },
    }, "@-")

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
        path = "internal/tui/app.go",
        start = 42,
        finish = 43,
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

  it("emits sections in authored order", function()
    local function c(path)
      return { kind = "file", path = path, start = 1, finish = 1, body = "b", snapshot = { { kind = " ", text = "x" } } }
    end
    local out = payload.build({ c("b.go"), c("a.go") })
    assert.is_true(out:find("## b.go:1", 1, true) < out:find("## a.go:1", 1, true))
  end)
end)
