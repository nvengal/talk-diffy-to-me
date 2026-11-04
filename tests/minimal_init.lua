local plenary = vim.env.PLENARY_DIR or vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
vim.opt.rtp:prepend(plenary)
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/plenary.vim")
