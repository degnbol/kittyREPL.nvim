-- User-facing REPL commands
local M = {}

local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")
local repl = require("kittyREPL.repl")
local binding = require("kittyREPL.binding")
local context = require("kittyREPL.context")
local message = require("kittyREPL.message")

local cmd = vim.cmd
local fn = vim.fn

---Quit a pager holding the REPL, so what follows reaches a prompt.
---@param win integer
---@param screen string|nil the window's screen, read here when not already at hand
local function closePager(win, screen)
    if not config.closepager then return end
    screen = screen or kitty.get_screen(win)
    if screen and kitty.is_pager(screen) then
        kitty.send_raw(win, "q")
    end
end

---Bring a REPL's context up to date, so what follows runs against nvim's state.
---Belongs beside closePager, once per user action: hooks are user code, and a
---counted action has no reason to evaluate them per line.
---The code that follows needs no waiting for. Bytes queue in the tty, so it is
---read in order even while a slow context line is still running.
---A line is marked delivered on hand-off, the send path having no confirmation
---to give. With `closepager` off nothing probes for a pager, so a line sent into
---one is eaten as keystrokes and still counted as delivered.
---@param win integer
---@param program string|nil
local function sync(win, program)
    for _, entry in ipairs(context.pending(win, program)) do
        kitty.run(win, program, entry.code)
        context.mark(win, entry.key, entry.code)
    end
end

---Send text to the buffer's REPL and execute it.
---@param text string
---@param raw boolean?
local function run(text, raw)
    local win, program = repl.current()
    if not win then return end
    closePager(win)
    sync(win, program)
    kitty.run(win, program, text, raw)
end

---Send text to the buffer's REPL without executing it.
---A context line executes first, then the staged text sits at the prompt.
---@param text string
---@param raw boolean?
local function paste(text, raw)
    local win, program = repl.current()
    if not win then return end
    closePager(win)
    sync(win, program)
    kitty.paste(win, program, text, raw)
end

---Wrap a query in one help command, a prefix or a { prefix, suffix } pair.
---@param helpCmd string|string[]
---@param query string
---@return string
local function helpFor(helpCmd, query)
    if type(helpCmd) == "table" then return helpCmd[1] .. query .. (helpCmd[2] or "") end
    return helpCmd .. query
end

---Command that looks a query up in the running program's help.
---A program whose help depends on the mode it is in gets `modes` of
---{ pattern, command }, matched in order against the prompt it is sitting at,
---and `default` for a prompt none of them match. The prompt is taken as it is
---rather than searched for: help text quotes prompts of its own, so a walk
---backwards through the screen answers from whatever was last printed there.
---@param program string|nil
---@param prompt string|nil prompt the REPL is at, nil where none could be read
---@param query string
---@return string|nil
local function replHelpCmd(program, prompt, query)
    local name = program or "an unnamed REPL"
    local entry = config.help[program]
    -- false where the user dropped a shipped entry, a deep merge having no way
    -- to delete one
    if not entry then
        message.warn("no help command for " .. name)
        return
    end
    -- one command, prefix or pair, unless the entry is keyed by prompt
    if type(entry) ~= "table" or not (entry.modes or entry.default) then
        return helpFor(entry, query)
    end
    for _, mode in ipairs(entry.modes or {}) do
        if prompt and prompt:match(mode[1]) then return helpFor(mode[2], query) end
    end
    if entry.default then return helpFor(entry.default, query) end
    message.warn("no help command for " .. name .. " at " ..
        (prompt and '"' .. prompt .. '"' or "an unreadable prompt"))
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

---Send the current line to the buffer's REPL v:count times, progressing a line
---between sends. The REPL is resolved, its pager cleared and its context synced
---once for the lot.
---@param send fun(win: integer, program: string|nil, text: string)
local function sendLines(send)
    local win, program = repl.current()
    if not win then return end
    closePager(win)
    sync(win, program)
    for _ = 1, vim.v.count1 do
        send(win, program, vim.api.nvim_get_current_line())
        if config.progress then
            cmd 'silent normal! j'
        end
    end
end

---Run the current line in the REPL.
function M.runLine()
    sendLines(kitty.run)
end

---Paste the current line to the REPL.
function M.pasteLine()
    sendLines(kitty.paste)
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
        message.warn("no iterate." .. key .. " expression for " .. ft)
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
        message.warn("no loop binding found at the cursor")
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

---Ask the REPL about a query.
---The screen is read once and before anything is sent, since the prompt the
---help command is chosen by is what quitting a pager then changes. It serves
---the pager probe too, both being questions about the same screen.
---@param query string
local function runHelp(query)
    local win, program = repl.current()
    if not win then return end
    local screen = kitty.get_screen(win)
    -- a pager draws a footer where a REPL draws its prompt, and matching modes
    -- against that would read the pager's colon as the REPL's own prompt
    local prompt = screen and not kitty.is_pager(screen) and kitty.prompt_at_cursor(screen) or nil
    local helpcmd = replHelpCmd(program, prompt, query)
    if not helpcmd then return end
    closePager(win, screen)
    sync(win, program)
    kitty.run(win, program, helpcmd, true)
end

---Look up help for the word under the cursor.
function M.help()
    runHelp(fn.expand("<cword>"))
end

---Look up help for the visual selection.
function M.helpVisual()
    cmd 'silent normal! "ky'
    runHelp(fn.getreg('k'))
    if config.progress then
        cmd 'silent normal! `>'
    end
end

---Make a function to send given text when called.
---@param text string
---@return function
function M.sendCustom(text)
    return function()
        local win = repl.win()
        if win then kitty.send_raw(win, text) end
    end
end

---Focus the buffer's REPL window.
function M.focus()
    local win = repl.win()
    if win then kitty.focus(win) end
end

---Send a SIGINT to the buffer's REPL.
function M.interrupt()
    local win = repl.win()
    if win then kitty.interrupt(win) end
end

---Toggle cursor progress after commands.
function M.toggleProgress()
    config.progress = not config.progress
    message.status("progress = " .. tostring(config.progress))
end

---Toggle edit paste mode.
function M.toggleEditPaste()
    config.editpaste = not config.editpaste
    message.status("edit paste = " .. tostring(config.editpaste))
end

return M
