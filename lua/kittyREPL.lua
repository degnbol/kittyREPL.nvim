#!/usr/bin/env lua
local g = vim.g
local cmd = vim.cmd
local api = vim.api
local fn = vim.fn
local keymap = vim.keymap

-- not all REPLs support bracketed paste
local filetype2bracketed = { python=true, r=true, julia=true }

-- command to execute in new kitty window
local filetype2command = {
    python="ipython",
    julia="julia",
    -- kitty command doesn't know where R is since it doesn't have all the env copied.
    r="radian --r-binary /Library/Frameworks/R.framework/Resources/R",
    lua="lua",
}

-- kitty @ ls foreground_processes cmdline value 
local cmdline2filetype = {
    python3="python",
    ipython="python",
    IPython="python",
    R="r",
    radian="r",
}

-- help prefix by language, e.g. "?"
-- julia uses ? for builtin help, but with TerminalPager @help is better for long help pages.
local helpPrefix = { julia="@help ", r="?", python="?" }

function get_repl()
    return vim.b.repl_id
end
function set_repl(window_id)
    vim.b.repl_id = window_id
end

local function get_focused_tab()
    fh = io.popen('kitty @ ls 2> /dev/null')
    json_string = fh:read("*a")
    fh:close()
    -- if we are not in fact in a kitty terminal then the command will fail
    if json_string == "" then return end
    
    ls = vim.json.decode(json_string)
    for i_os_win, os_win in ipairs(ls) do
        if os_win["is_focused"] then
            for i_tab, tab in ipairs(os_win["tabs"]) do
                if tab["is_focused"] then
                    return tab
                end
            end
        end
    end   
end
local function get_focused_windows()
    return get_focused_tab()["windows"]
end

-- Get window id of the ith window visible on the current tab.
function get_winid(i)
    return get_focused_windows()[i]["id"]
end

-- manually set repl as ith visible window from a prompt.
-- Useful to have keybinding to this function.
function ReplSetI()
    i = tonumber(vim.fn.input("Window i: "))
    set_repl(get_winid(i))
end
function ReplSet()
    winid = tonumber(vim.fn.input("Window id: "))
    set_repl(winid)
end

-- set REPL window id to the last active window
local function ReplSetLast()
    hist = get_focused_tab()["active_window_history"]
    set_repl(hist[#hist])
end

-- change kitty focus from editor to REPL
local function ReplFocus()
    if vim.b.repl_id == nil then
        print("No REPL")
    else
        fh = io.popen('kitty @ focus-window --match id:' .. vim.b.repl_id)
        fh:close()
    end
end

function search_repl()
    fh = io.popen('kitty @ ls 2> /dev/null')
    json_string = fh:read("*a")
    fh:close()
    -- if we are not in fact in a kitty terminal then the command will fail
    if json_string == "" then return end
    
    ls = vim.json.decode(json_string)
    for i_win, win in ipairs(get_focused_windows()) do
        -- we would never send to the editor.
        if not win["is_self"] then
            -- use last foreground process, e.g. I observe if I start julia, then `using PlotlyJS`, 
            -- then PlotlyJS will open other processes that are listed earlier in the list. 
            -- If there are any problems then just loop and look in all foreground processes.
            procs = win["foreground_processes"]
            cmdline = procs[#procs]["cmdline"]
            -- ["/usr/local/bin/julia", "-t", "4"] -> julia
            -- [".../R"] -> r
            -- ["nvim", ".../file.R"] -/-> r. Make sure we don't set the nvim editor as the REPL by accepting "." in the name match. 
            -- ["../Python", ".../radian"] -> r
            -- [".../python3"] -> python
            for i_arg, arg in ipairs(cmdline) do
                -- match letters, numbers and period until the end of string arg.
                repl = string.match(arg, "[%w.]+$")
                repl = cmdline2filetype[repl] or repl
                if repl == vim.bo.filetype then
                    set_repl(win["id"])
                    return win["id"]
                end
            end
            -- for proc over SSH the foreground_processes.cmdline will simply be ["ssh", ...]
            -- so we check the title as well
            -- "IPython: ..." -> IPython
            -- "server-name: julia" -> julia
            for repl in string.gmatch(win["title"], "[%w]+") do
                repl = cmdline2filetype[repl] or repl
                if repl == vim.bo.filetype then
                    set_repl(win["id"])
                    return win["id"]
                end
            end
        end
    end
end

--- Launch a new REPL window
function ReplNew()
    -- default to zsh
    local ftcommand = filetype2command[vim.bo.filetype] or ""
    local fh = io.popen('kitty @ launch --cwd=current --keep-focus ' .. ftcommand)
    local window_id = fh:read("*n") -- *n means read number, which means we also strip newline
    fh:close()
    -- show id in the title so we can easily set is as target, but also start 
    -- with the cmd like it would have been named by if opened in a regular way.
    local title = ftcommand:match("[^ ]+") .. " id=" .. window_id
    os.execute("kitty @ set-window-title --match id:" .. window_id .. " " .. title)
    set_repl(window_id)
end


function kittyExists(window_id)
    -- see if kitty window exists by getting text from it and checking if the operation fails (nonzero exit code).
    return os.execute('kitty @ get-text --match id:' .. window_id .. ' > /dev/null 2> /dev/null') == 0
end

function replCheck()
    -- return whether a valid repl is active or were found.
    return get_repl() ~= nil and kittyExists(get_repl()) or search_repl() ~= nil
end

local function kittySendRaw(text)
    fh = io.popen('kitty @ send-text --stdin --match id:' .. vim.b.repl_id, 'w')
    fh:write(text)
    fh:close()
end
--- Make a function to send given text when called.
function kittySendCustom(text)
    return function ()
        if not replCheck() then print("No REPL") else
            kittySendRaw(text)
        end
    end
end

--- Send a SIGINT to the REPL.
local function kittyInterrupt()
    if not replCheck() then print("No REPL") else
        return os.execute('kitty @ signal-child --match id:' .. vim.b.repl_id)
    end
end

--- Fixes indentation by prepending Start Of Header signal.
--- This can be a fallback method if a REPL doesn't support bracketed paste, 
--- however each line will then be sent and called separately, which may be a 
--- problem if there are empty lines within the sent block.
local function SOH(text)
    return text:gsub('\n', '\n\x01')
end

--- Get repo root.
local function ROOT()
    -- get diretory of current script 
    -- https://stackoverflow.com/questions/6380820/get-containing-path-of-lua-file
    return debug.getinfo(1).source:match("@?(.*/)") .. '/..'
end

function kittySendBracketed(text, post)
    -- bracketedPaste.sh uses zsh to do bracketed paste cat from stdin to stdout.
    -- easiest to use stdin rather than putting the text as an arg due to worrying about escaping characters
    fh = io.popen(ROOT() .. '/bracketedPaste.sh ' .. vim.b.repl_id .. ' "' .. post ..'"', 'w')
    fh:write(text)
    fh:close()
end

function kittySend(text, post)
    if filetype2bracketed[vim.bo.filetype] then
        kittySendBracketed(text, post)
    else
        kittySendRaw(text .. post)
    end
end

local function kittyRun(text)
    kittySend(text, '\n')
end
local function kittyPaste(text)
    kittySend(text:gsub('\n$', ''), "")
end

local function ReplHelp()
    if not replCheck() then print("No REPL") else
        prefix = helpPrefix[vim.bo.filetype] or "?"
        kittySendRaw(prefix .. vim.fn.expand("<cword>") .. "\n")
    end
end
local function ReplHelpVisual()
    if not replCheck() then print("No REPL") else
        prefix = helpPrefix[vim.bo.filetype] or "?"
        cmd 'silent normal! "ky`>'
        kittySendRaw(prefix .. fn.getreg('k') .. "\n")
    end
end

local function ReplRunLine()
    if not replCheck() then print("No REPL") else
        kittyRun(api.nvim_get_current_line())
        cmd 'silent normal! j'
    end
end
local function ReplPasteLine()
    if not replCheck() then print("No REPL") else
        kittyPaste(api.nvim_get_current_line())
    end
end

local function ReplRunVisual()
    if not replCheck() then print("No REPL") else
        -- NOTE: old nvim versions needed gv to first reselect last select.
        -- "ky = yank to register k (k for kitty)
        -- `>  = go to mark ">" = end of last visual select
        cmd 'silent normal! "ky`>'
        kittyRun(fn.getreg('k'))
    end
end
local function ReplPasteVisual()
    if not replCheck() then print("No REPL") else
        -- NOTE: old nvim versions needed gv to first reselect last select.
        -- "ky = yank to register k (k for kitty)
        -- `>  = go to mark ">" = end of last visual select
        cmd 'silent normal! "ky`>'
        kittyPaste(fn.getreg('k'))
    end
end

function ReplRunOperator(type, ...)
    if not replCheck() then print("No REPL") else
        -- `[ = go to start of motion
        -- v or V = select char or lines
        -- `] = go to end of motion
        -- "ky = yank selection to register k
        if type == "char" then
            cmd 'silent normal! `[v`]"ky`]w'
        else -- either type == "line" or "block", the latter I never use
            cmd 'silent normal! `[V`]"ky`]w'
        end
        kittyRun(fn.getreg('k'))
    end
end
function ReplPasteOperator(type, ...)
    if not replCheck() then print("No REPL") else
        -- `[ = go to start of motion
        -- v or V = select char or lines
        -- `] = go to end of motion
        -- "ky = yank selection to register k
        if type == "char" then
            cmd 'silent normal! `[v`]"ky`]w'
        else -- either type == "line" or "block", the latter I never use
            cmd 'silent normal! `[V`]"ky`]w'
        end
        kittyPaste(fn.getreg('k'))
    end
end

local defaults = {
    keymap = {
        new           = "<plug>kittyReplNew",
        focus         = "<plug>kittyReplFocus",
        set           = "<plug>kittyReplSet",
        setlast       = "<plug>kittyReplSetLast",
        run           = "<plug>kittyReplRun",
        paste         = "<plug>kittyReplPaste",
        help          = "<plug>kittyReplHelp",
        runLine       = "<plug>kittyReplRunLine",
        pasteLine     = "<plug>kittyReplPasteLine",
        runVisual     = "<plug>kittyReplRunVisual",
        pasteVisual   = "<plug>kittyReplPasteVisual",
        q             = "<plug>kittyReplQ",
        ctrld         = "<plug>kittyReplCtrld",
        ctrlc         = "<plug>kittyReplCtrlc",
        interrupt     = "<plug>kittyReplInterrupt",
    },
    exclude = {
        TelescopePrompt=true, -- redundant since buftype is prompt.
        oil=true,
    },
}

function setup(conf)
    if conf == nil then conf = defaults else
        conf = vim.tbl_deep_extend("keep", conf, defaults)
    end
    
    local group = vim.api.nvim_create_augroup("kittyRepl", {clear=true})
    -- BufEnter is too early for e.g. cmdline window to assign buftype
    vim.api.nvim_create_autocmd("Filetype", {
        group = group,
        callback = function ()
            if vim.bo.buftype ~= "" then return end 
            if conf.exclude[vim.bo.filetype] then return end

            function opts(desc)
                return {buffer=true, silent=true, desc=desc}
            end
            
            keymap.set('n', conf.keymap.new, ReplNew, opts("REPL new"))
            keymap.set('n', conf.keymap.focus, ReplFocus, opts("REPL focus"))
            keymap.set('n', conf.keymap.set, ReplSet, opts("REPL set"))
            keymap.set('n', conf.keymap.setlast, ReplSetLast, opts("REPL set last"))
            keymap.set('n', conf.keymap.run, "Operator('v:lua.ReplRunOperator')", {buffer=true, silent=true, expr=true, desc="REPL run motion"})
            keymap.set('n', conf.keymap.paste, "Operator('v:lua.ReplPasteOperator')", {buffer=true, silent=true, expr=true, desc="REPL paste motion"})
            keymap.set('n', conf.keymap.help, ReplHelp, opts("REPL help word under cursor"))
            keymap.set('x', conf.keymap.help, ReplHelpVisual, opts("REPL help visual"))
            keymap.set('n', conf.keymap.runLine, ReplRunLine, opts("REPL run line"))
            keymap.set('n', conf.keymap.pasteLine, ReplPasteLine, opts("REPL paste line"))
            keymap.set('x', conf.keymap.runVisual, ReplRunVisual, opts("REPL run visual"))
            keymap.set('x', conf.keymap.pasteVisual, ReplPasteVisual, opts("REPL paste visual"))
            keymap.set('n', conf.keymap.q, kittySendCustom("q"), opts("REPL send q"))
            keymap.set('n', conf.keymap.ctrld, kittySendCustom("\x04"), opts("REPL send Ctrl+d"))
            keymap.set('n', conf.keymap.ctrlc, kittySendCustom("\x03"), opts("REPL send Ctrl+c"))
            keymap.set('n', conf.keymap.interrupt, kittyInterrupt, opts("REPL interrupt"))
        end
    })
end

return {
    setup = setup
}
