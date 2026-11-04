---@param msg string
---@param level? integer
return function(msg, level)
  vim.notify("diffy: " .. msg, level or vim.log.levels.INFO)
end
