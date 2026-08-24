-- Helpers with no dependencies of their own, usable from user config.
local M = {}

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
