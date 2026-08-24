-- Helpers with no dependencies of their own, usable from user config.
local M = {}

---Run a command to completion.
---The one place this plugin spawns a subprocess, and the swap point for tests.
---@param argv string[]
---@param stdin string|nil written to the child's stdin, which is then closed
---@return vim.SystemCompleted
function M.exec(argv, stdin)
    -- no text=true: stdout is passed through byte for byte, terminal screens
    -- included
    return vim.system(argv, { stdin = stdin }):wait()
end

---String literal holding a value, for a language reading double quotes and
---backslash escapes: python, julia, r and lua do.
---Not a shell: those leave `\n` as two characters inside double quotes, and go
---on expanding `$` and backticks there.
---@param value string
---@return string literal quotes included
function M.quote(value)
    return '"' .. value:gsub("[\\\"]", "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

return M
