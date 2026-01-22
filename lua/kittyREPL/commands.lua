-- User-facing REPL commands
local M = {}

local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")
local detect = require("kittyREPL.detect")

local cmd = vim.cmd
local fn = vim.fn

---Get the help command needed to prefix a help search term for the current language.
---@param query string
---@return string?
local function replHelpCmd(query)
    local helpCmd = config.match.help[vim.bo.filetype] or "?"
    -- if the config.match.help entry for a language is a table, then it means
    -- we need to look for the current REPL prompt context to understand which
    -- prefix is appropriate.
    if type(helpCmd) ~= "table" then return helpCmd .. query end
    if vim.islist(helpCmd) and #helpCmd == 2 then
        return helpCmd[1] .. query .. helpCmd[2]
    end
    -- otherwise key-value dict
    local text = kitty.get_scrollback() or ""
    while true do
        local lastline = text:match("\n([^\n]*)$")
        if lastline == nil then return end
        text = text:sub(1, #text - #lastline - 1)
        for pat, _helpCmd in pairs(helpCmd) do
            if lastline:match(pat) then
                if type(_helpCmd) == "table" then
                    return _helpCmd[1] .. query .. _helpCmd[2]
                else
                    return _helpCmd .. query
                end
            end
        end
    end
end

-- Just Julia for now
local function parseVariableIterable(line)
    for _, pVar in ipairs({ "[%w_]+", "%b()" }) do
        -- order matters, e.g. `x in func(arg1, arg2)` would also be matched by "%w+"
        for _, pIter in ipairs({ "[%w_.]+%b()", "[%w_.]+", "%b()", "%b[]" }) do
            local variable, iterable
            variable, iterable = line:match("(" .. pVar .. ") in (" .. pIter .. ")")
            if variable ~= nil then
                return variable, iterable
            end
            variable, iterable = line:match("(" .. pVar .. ") = (" .. pIter .. ")")
            if variable ~= nil then
                return variable, iterable
            end
            variable, iterable = line:match("(" .. pVar .. ") ∈ (" .. pIter .. ")")
            if variable ~= nil then
                return variable, iterable
            end
        end
    end
end

---Launch a new REPL window.
---vim.v.count used as well, e.g. to use multiple threads.
function M.new()
    -- default to zsh
    local ftcommand = config.command[vim.bo.filetype] or ""
    if vim.v.count > 0 then
        local ftcommand_count = config.command_count[vim.bo.filetype]
        if ftcommand_count ~= nil then
            ftcommand = ftcommand .. ftcommand_count .. vim.v.count
        end
    end
    local win = kitty.launch(ftcommand)
    if not win then return end
    -- show id in the title so we can easily set it as target, but also start
    -- with the cmd like it would have been named if opened in a regular way.
    local title = ftcommand:match("[^ ]+") .. " id=" .. win
    kitty.set_title(win, title)
    vim.b.repl_win = win
    vim.b.repl_cmd = ftcommand:match("[^ ]+"):lower()
end

---Manually set REPL as ith visible window from a prompt.
function M.setI()
    vim.b.repl_win = kitty.get_winid(tonumber(fn.input("Window i: ")))
end

---Set REPL window id from user input.
function M.set()
    vim.b.repl_win = tonumber(fn.input("Window id: "))
end

---Set REPL window id to the last active window.
function M.setLast()
    local tab = kitty.get_focused_tab()
    if not tab then return end
    local history = tab.active_window_history
    vim.b.repl_win = history[#history]
    if not detect.detect_REPL { vim.b.repl_win } then
        -- fallback
        vim.b.repl_cmd = vim.bo.filetype
    end
end

---Run the current line in the REPL.
function M.runLine()
    for _ = 1, vim.v.count1 do
        kitty.run(vim.api.nvim_get_current_line(), false)
        if config.progress then
            cmd 'silent normal! j'
        end
    end
end

---Paste the current line to the REPL.
function M.pasteLine()
    for _ = 1, vim.v.count1 do
        kitty.paste(vim.api.nvim_get_current_line(), false)
        if config.progress then
            cmd 'silent normal! j'
        end
    end
end

local ft_iterate = { julia = "first", python = "next" }

---Run the current line as a for-loop iteration (using first()/next()).
function M.runLineFor()
    local variable, iterable = parseVariableIterable(vim.api.nvim_get_current_line())
    local torun = variable .. " = " .. ft_iterate[vim.bo.filetype] .. "(" .. iterable .. ")"
    kitty.run(torun, true)
    if config.progress then
        cmd 'silent normal! j'
    end
end

local ft_indexing = { julia = 1, python = 0, r = 1 }

---Same as runLineFor but instead of using next etc. assuming iterator we use indexing.
---Count is used for the index. If not given explicitly it will default to 1 or
---0 depending on if the language is 1 or 0-indexed.
function M.runLineForI()
    local count = vim.v.count > 0 and vim.v.count or ft_indexing[vim.bo.filetype]
    local variable, iterable = parseVariableIterable(vim.api.nvim_get_current_line())
    local torun = variable .. " = " .. iterable .. "[" .. count .. "]"
    kitty.run(torun, true)
    if config.progress then
        cmd 'silent normal! j'
    end
end

---Run the visual selection in the REPL.
function M.runVisual()
    cmd 'silent normal! "ky'
    kitty.run(fn.getreg('k'))
    if config.progress then
        cmd 'silent normal! `>'
    end
end

---Paste the visual selection to the REPL.
function M.pasteVisual()
    cmd 'silent normal! "ky'
    kitty.paste(fn.getreg('k'))
    if config.progress then
        cmd 'silent normal! `>'
    end
end

---Operator function for running motion selection.
---@param type string "char", "line", or "block"
function M.runOperator(type)
    if type == "char" then
        cmd 'silent normal! `[v`]"ky'
    else
        cmd 'silent normal! `[V`]"ky'
    end
    kitty.run(fn.getreg('k'))
    if config.progress then
        cmd 'silent normal! `]w'
    end
end

---Operator function for pasting motion selection.
---@param type string "char", "line", or "block"
function M.pasteOperator(type)
    if type == "char" then
        cmd 'silent normal! `[v`]"ky'
    else
        cmd 'silent normal! `[V`]"ky'
    end
    kitty.paste(fn.getreg('k'))
    if config.progress then
        cmd 'silent normal! `]w'
    end
end

---Look up help for the word under the cursor.
function M.help()
    local helpcmd = replHelpCmd(fn.expand("<cword>"))
    if helpcmd then
        kitty.run(helpcmd, true)
    end
end

---Look up help for the visual selection.
function M.helpVisual()
    cmd 'silent normal! "ky'
    local helpcmd = replHelpCmd(fn.getreg('k'))
    if helpcmd then
        kitty.run(helpcmd, true)
    end
    if config.progress then
        cmd 'silent normal! `>'
    end
end

---Make a function to send given text when called.
---@param text string
---@return function
function M.sendCustom(text)
    return function() kitty.send_raw(text) end
end

---Toggle cursor progress after commands.
function M.toggleProgress()
    config.progress = not config.progress
    print("REPL progress =", config.progress)
end

---Toggle edit paste mode.
function M.toggleEditPaste()
    config.editpaste = not config.editpaste
    print("REPL edit paste =", config.editpaste)
end

return M
