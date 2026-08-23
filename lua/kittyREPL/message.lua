-- User-facing messages.
--
-- One prefix for every message the plugin writes, and one place deciding which
-- of them persist: a status is overwritten by the next keypress, a warning is
-- not.
local M = {}

local PREFIX = "REPL: "

---Report transient state, e.g. a scroll position or a toggled flag.
---Successive statuses replace one another instead of accumulating, and none of
---them reach the message history.
---@param msg string
function M.status(msg)
    -- one message id for all of them, so a ui-messages frontend updates the
    -- entry in place rather than listing every keypress
    vim.api.nvim_echo({ { PREFIX .. msg } }, false, { id = "kittyREPL.status" })
end

---Report a problem, which must survive whatever the next keypress writes.
---@param msg string
function M.warn(msg)
    vim.notify(PREFIX .. msg, vim.log.levels.WARN)
end

---Report a problem that recurs on every keypress, e.g. an unusable kitty.
---@param msg string
function M.warn_once(msg)
    vim.notify_once(PREFIX .. msg, vim.log.levels.WARN)
end

return M
