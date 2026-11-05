local M = {}

---@class diffy.Pane
---@field id integer
---@field title string
---@field terminal_command string
---@field pane_command string
---@field is_plugin boolean
---@field is_selectable boolean
---@field tab_id integer

---@param p diffy.Pane
---@return string
function M.command(p)
  if p.pane_command ~= nil and p.pane_command ~= "" then
    return p.pane_command
  end
  return p.terminal_command or ""
end

---@param panes diffy.Pane[]
---@param own_env? string value of $ZELLIJ_PANE_ID
---@return diffy.Pane[]
function M.candidates(panes, own_env)
  local own = tonumber((own_env or ""):match("%d+"))
  local own_tab
  for _, p in ipairs(panes) do
    if p.id == own then
      own_tab = p.tab_id
    end
  end
  return vim.tbl_filter(function(p)
    return p.id ~= own
      and (own_tab == nil or p.tab_id == own_tab)
      and not p.is_plugin
      and p.is_selectable
  end, panes)
end

---@param panes diffy.Pane[]
---@param name string
---@return diffy.Pane[] the panes whose title or command contains `name`, ignoring case
function M.matching(panes, name)
  name = name:lower()
  return vim.tbl_filter(function(p)
    return (p.title or ""):lower():find(name, 1, true) ~= nil or M.command(p):lower():find(name, 1, true) ~= nil
  end, panes)
end

---@return diffy.Pane[]
function M.list_panes()
  local res = vim.system({ "zellij", "action", "list-panes", "--json" }, { text = true }):wait()
  if res.code ~= 0 then
    error("zellij list-panes: " .. vim.trim(res.stderr or ""))
  end
  return vim.json.decode(res.stdout)
end

--- Runs `argv` in a new pane to the right, leaving focus where it is.
---@param argv string[]
---@param cwd string
---@return integer? pane_id the new pane, when zellij names it, string? err
function M.launch(argv, cwd)
  local cmd = { "zellij", "action", "new-pane", "--direction", "right", "--no-focus", "--cwd", cwd, "--" }
  local res = vim.system(vim.list_extend(cmd, argv), { text = true }):wait()
  if res.code ~= 0 then
    return nil, "zellij action new-pane: " .. vim.trim(res.stderr or "")
  end
  return tonumber((res.stdout or ""):match("terminal_(%d+)"))
end

---@param pane_id integer
---@param text string
---@return string? err
function M.send(pane_id, text)
  local id = tostring(pane_id)
  for _, cmd in ipairs({
    { "zellij", "action", "paste", "--pane-id", id, "--", text },
    { "zellij", "action", "send-keys", "--pane-id", id, "--", "Enter" },
  }) do
    local res = vim.system(cmd, { text = true }):wait()
    if res.code ~= 0 then
      return table.concat(cmd, " ", 1, 3) .. ": " .. vim.trim(res.stderr or "")
    end
  end
end

return M
