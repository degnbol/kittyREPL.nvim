-- Minimal init for plenary tests.
-- Use --clean to avoid loading user config (plugin/, after/, etc.).
vim.opt.runtimepath:append(vim.fn.getcwd())
-- Vendored plenary — clone with: make test-deps
vim.opt.runtimepath:append("rtps/plenary.nvim")
