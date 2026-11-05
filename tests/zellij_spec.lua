local zellij = require("diffy.zellij")

local function pane(over)
  return vim.tbl_extend("force", {
    id = 1,
    title = "",
    terminal_command = "",
    pane_command = "",
    is_plugin = false,
    is_selectable = true,
    tab_id = 0,
  }, over)
end

local function ids(panes)
  return vim.tbl_map(function(p)
    return p.id
  end, panes)
end

describe("zellij.candidates", function()
  it("keeps selectable terminal panes in our tab other than our own", function()
    local panes = {
      pane({ id = 1, tab_id = 0 }),
      pane({ id = 2, tab_id = 0 }),
      pane({ id = 3, tab_id = 1 }),
      pane({ id = 4, tab_id = 0, is_plugin = true }),
      pane({ id = 5, tab_id = 0, is_selectable = false }),
    }
    assert.are.same({ 2 }, ids(zellij.candidates(panes, "terminal_1")))
  end)

  it("keeps every tab when our own pane is unknown", function()
    local panes = { pane({ id = 1, tab_id = 0 }), pane({ id = 3, tab_id = 1 }) }
    assert.are.same({ 1, 3 }, ids(zellij.candidates(panes, nil)))
  end)
end)

describe("zellij.matching", function()
  it("matches title or command case-insensitively, preferring pane_command", function()
    local panes = {
      pane({ id = 1, title = "Claude Code" }),
      pane({ id = 2, pane_command = "CLAUDE" }),
      pane({ id = 3, terminal_command = "claude", pane_command = "zsh" }),
      pane({ id = 4, title = "zsh" }),
    }
    assert.are.same({ 1, 2 }, ids(zellij.matching(panes, "claude")))
  end)

  it("looks for whichever name it is given", function()
    local panes = { pane({ id = 1, title = "claude" }), pane({ id = 2, pane_command = "codex" }) }
    assert.are.same({ 2 }, ids(zellij.matching(panes, "codex")))
    assert.are.same({ 2 }, ids(zellij.matching(panes, "CodeX")))
  end)
end)
