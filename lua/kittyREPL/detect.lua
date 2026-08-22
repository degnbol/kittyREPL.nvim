-- REPL detection and validation
local M = {}

local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")

---Detect REPL window relevant for the current filetype and detect which cmd is
---being run in the repl by scanning through windows and matching on cmdline
---and title.
---@param wins? table list of window ids to search. Default=all in the focused tab.
---@return integer?
function M.detect_REPL(wins)
    local detect = config.match.detect[vim.bo.filetype]
    if not detect then
        for ft in vim.bo.filetype:gmatch("[^.]+") do
            detect = config.match.detect[ft]
            if detect then break end
        end
    end
    if wins == nil then
        if detect == nil then
            print("No detect config for " .. vim.bo.filetype .. ". Set the REPL window manually.")
            return
        end
        local focused_tab = kitty.get_focused_tab()
        if focused_tab == nil then return end
        wins = focused_tab.windows
    end
    for _, win in ipairs(wins) do
        if type(win) == "number" then
            -- with the --match=id:win filter we still get the same hierarchy,
            -- but "tabs" and "windows" only have 1 entry each due to the filter.
            local ls = kitty.ls("id:" .. win)
            if not ls or not ls[1] or not ls[1].tabs or not ls[1].tabs[1] then
                goto continue
            end
            win = ls[1].tabs[1].windows[1]
        end
        -- use last foreground process, e.g. I observe if I start julia, then `using PlotlyJS`,
        -- then PlotlyJS will open other processes that are listed earlier in the list.
        -- If there are any problems then just loop and look in all foreground processes.
        local procs = win.foreground_processes
        if not procs or #procs == 0 then
            goto continue
        end
        local cmdline = procs[#procs].cmdline
        if not cmdline then
            goto continue
        end
        -- we would never send to the editor.
        if not win.is_self and cmdline[1] ~= "nvim" then
            -- no detection config, but we are specifying exactly which window the REPL is in
            if detect == nil and #wins == 1 then
                -- the basename is a guess at the program name; the full cmdline never is
                vim.b.repl_cmd = vim.fn.fnamemodify(cmdline[1], ":t"):lower()
                vim.b.repl_win = win.id
                print("No detect config for " .. vim.bo.filetype .. ". Assumes REPL program is \"" .. vim.b.repl_cmd .. "\".")
                return win.id
            end
            local repl_cmd = detect(cmdline, win.title)
            if repl_cmd then
                vim.b.repl_cmd = repl_cmd
                vim.b.repl_win = win.id
                return win.id
            end
        end
        ::continue::
    end
end

---Run function f with args if REPL is valid, otherwise print "No REPL".
---@param f function
---@return function
function M.replCheck(f)
    return function(...)
        if vim.b.repl_win ~= nil and kitty.exists(vim.b.repl_win) or M.detect_REPL() ~= nil then
            return f(...)
        else
            print("No REPL")
        end
    end
end

return M
