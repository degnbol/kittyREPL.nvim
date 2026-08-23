-- REPL detection and validation
local M = {}

local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")
local repl = require("kittyREPL.repl")

---Program names the filetype accepts as its REPL.
---@param ft string
---@return table<string, boolean>|nil
local function claimed_programs(ft)
    if config.programs[ft] then return config.programs[ft] end
    -- a compound filetype is claimed by any of its parts, e.g. "python.blender"
    for part in ft:gmatch("[^.]+") do
        if config.programs[part] then return config.programs[part] end
    end
end

---Attach the buffer to a window on the focused tab running a program the
---current filetype claims.
---@return integer|nil win
function M.detect_REPL()
    local programs = claimed_programs(vim.bo.filetype)
    if not programs then
        vim.notify("REPL: no programs configured for filetype " .. vim.bo.filetype ..
            ". Set the REPL window manually.", vim.log.levels.WARN)
        return
    end
    local tab = kitty.get_focused_tab()
    if not tab then return end
    for _, window in ipairs(tab.windows) do
        local program = repl.resolve(window)
        -- a candidate can still be refused, e.g. it closed since the tab listing
        if program and programs[program] and repl.attach(window.id) then
            return window.id
        end
    end
end

---Run function f with args if REPL is valid, otherwise print "No REPL".
---@param f function
---@return function
function M.replCheck(f)
    return function(...)
        if repl.revalidate() or M.detect_REPL() then
            return f(...)
        else
            print("No REPL")
        end
    end
end

return M
