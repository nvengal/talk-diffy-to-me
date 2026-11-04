vim.api.nvim_create_user_command("Diffy", function(o)
  require("diffy").open(o.fargs)
end, { nargs = "*", complete = "file", desc = "Review `jj diff --git` [--from <revset>] [paths...]" })

vim.api.nvim_create_user_command("DiffyComment", function(o)
  require("diffy").comment(o.line1, o.line2)
end, { range = true, desc = "Comment on the current line or range" })

vim.api.nvim_create_user_command("DiffyDelete", function()
  require("diffy").delete()
end, { desc = "Delete review comments covering the cursor line" })

vim.api.nvim_create_user_command("DiffySend", function()
  require("diffy").send()
end, { desc = "Send review comments to the Claude zellij pane" })

vim.api.nvim_create_user_command("DiffyRepick", function()
  require("diffy").reset_pane()
end, { desc = "Forget the chosen zellij pane; ask again on next send" })
