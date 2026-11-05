local plenary = vim.env.PLENARY_DIR or vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
vim.opt.rtp:prepend(plenary)
vim.opt.rtp:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/tests/?.lua;" .. package.path
vim.cmd("runtime plugin/plenary.vim")
vim.o.swapfile = false
