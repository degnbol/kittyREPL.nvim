-- User-facing REPL commands
local M = {}

local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")
local repl = require("kittyREPL.repl")
local binding = require("kittyREPL.binding")

local cmd = vim.cmd
local fn = vim.fn

---Send text to the buffer's REPL and execute it.
---@param text string
---@param raw boolean?
local function run(text, raw)
    local _, program = repl.current()
    kitty.run(program, text, raw)
end

---Send text to the buffer's REPL without executing it.
---@param text string
---@param raw boolean?
local function paste(text, raw)
    local _, program = repl.current()
    kitty.paste(program, text, raw)
end

---Get the help command needed to prefix a help search term for the running REPL program.
---@param program string|nil
---@param query string
---@return string?
local function replHelpCmd(program, query)
    local helpCmd = config.match.help[program] or "?"
    -- if the config.match.help entry for a program is a table, then it means
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

---Launch a new REPL window.
---vim.v.count used as well, e.g. to use multiple threads.
function M.new()
    -- filetypes without a command entry fall back to the shell
    local ftcommand = config.command[vim.bo.filetype] or vim.o.shell
    if vim.v.count > 0 then
        local ftcommand_count = config.command_count[vim.bo.filetype]
        if ftcommand_count ~= nil then
            ftcommand = ftcommand .. ftcommand_count .. vim.v.count
        end
    end
    -- derived before launching so a bad command cannot leave an untitled window behind
    local program = repl.progname(ftcommand:match("[^ ]+"))
    local win = kitty.launch(ftcommand)
    if not win then return end
    -- show id in the title so we can easily set it as target, but also start
    -- with the cmd like it would have been named if opened in a regular way.
    kitty.set_title(win, program .. " id=" .. win)
    repl.attach(win, program)
end

---Manually set REPL as ith visible window from a prompt.
function M.setI()
    local i = tonumber(fn.input("Window i: "))
    if not i then return end
    repl.attach(kitty.get_winid(i))
end

---Set REPL window id from user input.
function M.set()
    repl.attach(tonumber(fn.input("Window id: ")))
end

---Set REPL window id to the last active window.
function M.setLast()
    local tab = kitty.get_focused_tab()
    if not tab then return end
    local history = tab.active_window_history
    repl.attach(history[#history])
end

---Run the current line in the REPL.
function M.runLine()
    for _ = 1, vim.v.count1 do
        run(vim.api.nvim_get_current_line(), false)
        if config.progress then
            cmd 'silent normal! j'
        end
    end
end

---Paste the current line to the REPL.
function M.pasteLine()
    for _ = 1, vim.v.count1 do
        paste(vim.api.nvim_get_current_line(), false)
        if config.progress then
            cmd 'silent normal! j'
        end
    end
end

---Expression taking an element out of an iterable in the given language.
---@param ft string
---@param key "first"|"index"
---@param iterable string
---@param count integer|nil index for "index", defaulting to the filetype's base index
---@return string|nil expr
function M.iterateExpr(ft, key, iterable, count)
    local spec = config.iterate[ft]
    local index = count or (spec or {}).base
    if not spec or not spec[key] or (key == "index" and not index) then
        vim.notify("REPL: no iterate." .. key .. " expression for " .. ft, vim.log.levels.WARN)
        return
    end
    return spec[key]:format(iterable, index)
end

---Assign the variable of the binding at the cursor one element of its iterable.
---@param key "first"|"index"
---@param count integer|nil
local function runBinding(key, count)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local variable, iterable, nextpos = binding.at(0, cursor[1] - 1, cursor[2])
    if not variable or not iterable then
        vim.notify("REPL: no loop binding found at the cursor", vim.log.levels.WARN)
        return
    end
    local expr = M.iterateExpr(vim.bo.filetype, key, iterable, count)
    if not expr then return end
    run(variable .. " = " .. expr)
    -- progress to the next thing that would be sent, which is the next binding
    -- of a multi-binding header, else the loop body.
    if config.progress and nextpos then
        vim.api.nvim_win_set_cursor(0, { nextpos[1] + 1, nextpos[2] })
    end
end

---Run the first iteration of the loop at the cursor.
function M.runLineFor()
    runBinding("first")
end

---Run the vim.v.count'th iteration of the loop at the cursor.
---Without a count the language's first index is used.
function M.runLineForI()
    runBinding("index", vim.v.count > 0 and vim.v.count or nil)
end

---Run the visual selection in the REPL.
function M.runVisual()
    cmd 'silent normal! "ky'
    run(fn.getreg('k'))
    if config.progress then
        cmd 'silent normal! `>'
    end
end

---Paste the visual selection to the REPL.
function M.pasteVisual()
    cmd 'silent normal! "ky'
    paste(fn.getreg('k'))
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
    run(fn.getreg('k'))
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
    paste(fn.getreg('k'))
    if config.progress then
        cmd 'silent normal! `]w'
    end
end

---Look up help for the word under the cursor.
function M.help()
    local _, program = repl.current()
    local helpcmd = replHelpCmd(program, fn.expand("<cword>"))
    if helpcmd then
        run(helpcmd, true)
    end
end

---Look up help for the visual selection.
function M.helpVisual()
    cmd 'silent normal! "ky'
    local _, program = repl.current()
    local helpcmd = replHelpCmd(program, fn.getreg('k'))
    if helpcmd then
        run(helpcmd, true)
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
