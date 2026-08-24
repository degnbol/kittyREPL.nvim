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

---Report something worth auditing later that is not a problem, e.g. a value the
---plugin worked out for itself. Reaches the message history, where a status does
---not survive the next keypress.
---@param msg string
function M.info(msg)
    vim.notify(PREFIX .. msg, vim.log.levels.INFO)
end

---Report a problem, which must survive whatever the next keypress writes.
---@param msg string
function M.warn(msg)
    vim.notify(PREFIX .. msg, vim.log.levels.WARN)
end

---Report a fault in user config, e.g. a hook that threw.
---Once per message, since config is consulted on every send and so a fault in it
---recurs on every keypress. A second broken entry still reports, wording being
---what these are keyed on.
---@param msg string
function M.error(msg)
    vim.notify_once(PREFIX .. msg, vim.log.levels.ERROR)
end

---Report a problem that recurs on every keypress, e.g. an unusable kitty.
---@param msg string
function M.warn_once(msg)
    vim.notify_once(PREFIX .. msg, vim.log.levels.WARN)
end

return M
