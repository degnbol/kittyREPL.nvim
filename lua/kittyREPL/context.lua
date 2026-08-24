-- REPL-side state kept in step with nvim
--
-- A hook returns the code that would bring its REPL up to date. Sending only
-- what differs from what that window was last told needs no events: constant
-- code differs once and matches forever after, and code built from nvim state
-- differs exactly when that state changes.
--
-- Nothing here talks to kitty. A caller sends what `pending` returns and marks
-- each line once it has, so the memo records what went out rather than what was
-- planned, and the module is testable without a subprocess.
local M = {}

local config = require("kittyREPL.config")
local repl = require("kittyREPL.repl")
local util = require("kittyREPL.util")
local message = require("kittyREPL.message")

---A program's enabled hooks, in the order they reach the REPL.
---Sorted by name, since hooks are sent in the order returned. A program or a
---single hook set to `false` opts out: a deep merge cannot delete a shipped
---default, but it does carry a `false` through.
---@param hooks table program-keyed table of hook tables
---@param program string|nil
---@return { name: string, hook: function }[]
local function enabled(hooks, program)
    local entries = hooks[program]
    if type(entries) ~= "table" then return {} end
    local named = {}
    for name, hook in pairs(entries) do
        if hook then table.insert(named, { name = name, hook = hook }) end
    end
    table.sort(named, function(a, b) return a.name < b.name end)
    return named
end

---Assignment statement for one `config.variables` entry.
---@param program string|nil
---@param name string
---@param value string
---@return string
local function assignment(program, name, value)
    local assign = config.assign[program]
    if assign then return assign(name, value) end
    return name .. " = " .. util.quote(value)
end

---Context lines a window still needs, in the order to send them.
---Variables come before `config.context` hooks, each in key order. Cache keys
---are namespaced `var:`/`ctx:`, so the same name in both tables is two entries.
---@param win integer
---@param program string|nil
---@return { key: string, code: string }[]
function M.pending(win, program)
    local sent = repl.sent(win)
    local entries = {}

    ---@param key string namespaced cache key, also what an error is reported under
    ---@param produce fun(): string|nil
    local function add(key, produce)
        local ok, code = pcall(produce)
        if not ok then
            message.error("context " .. key .. ": " .. tostring(code))
        elseif code == nil or code == "" then
            return
        elseif type(code) ~= "string" then
            message.error("context " .. key .. " gave a " .. type(code) .. ", not code")
        elseif sent[key] ~= code then
            table.insert(entries, { key = key, code = code })
        end
    end

    for _, entry in ipairs(enabled(config.variables, program)) do
        add("var:" .. entry.name, function()
            local value = entry.hook()
            -- an empty string is a value to assign, where nil assigns nothing
            if value == nil then return nil end
            return assignment(program, entry.name, value)
        end)
    end

    for _, entry in ipairs(enabled(config.context, program)) do
        add("ctx:" .. entry.name, entry.hook)
    end

    return entries
end

---Record code as delivered, so it is not sent again until it changes.
---A line that errored in the REPL still counts as delivered, so a hook the REPL
---cannot run fails once instead of on every send.
---@param win integer
---@param key string
---@param code string
function M.mark(win, key, code)
    repl.sent(win)[key] = code
end

return M
