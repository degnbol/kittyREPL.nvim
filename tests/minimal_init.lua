-- Minimal init for plenary tests.
-- Use --clean to avoid loading user config (plugin/, after/, etc.).
vim.opt.runtimepath:append(vim.fn.getcwd())
-- --clean drops the parser dir, but the binding specs need real parsers.
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/site")
-- Vendored plenary — clone with: make test-deps
vim.opt.runtimepath:append("rtps/plenary.nvim")
