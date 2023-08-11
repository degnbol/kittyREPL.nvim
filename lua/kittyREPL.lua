#!/usr/bin/env lua
local g = vim.g
local cmd = vim.cmd
local api = vim.api
local fn = vim.fn
local keymap = vim.keymap

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
function ReplSetLast()
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

-- kitty @ ls foreground_processes cmdline value 
local cmdline2filetype = {
    python3="python",
    ipython="python",
    IPython="python",
    R="r",
    radian="r",
}

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

-- command to execute in new kitty window
local filetype2command = {
    python="ipython",
    julia="julia",
    -- kitty command doesn't know where R is since it doesn't have all the env copied.
    r="radian --r-binary /Library/Frameworks/R.framework/Resources/R",
    lua="lua",
}

function ReplWindow()
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

function kittySendRaw(text)
    fh = io.popen('kitty @ send-text --stdin --match id:' .. vim.b.repl_id, 'w')
    fh:write(text .. '\n')
    fh:close()
end

function kittySendSOH(text)
    -- Fixes indentation by prepending Start Of Header signal. Still sending each line separately.
    text = text:gsub('\n', '\n\x01')
    -- might have to be done in two steps, instead of simply inserting gsub expr in kittySend.
    kittySendRaw(text)
end

function kittySendPaste(text)
    -- get diretory of current script https://stackoverflow.com/questions/6380820/get-containing-path-of-lua-file
    dir = debug.getinfo(1).source:match("@?(.*/)")
    -- kittyPaste.sh uses zsh to do bracketed paste cat from stdin to stdout.
    fh = io.popen(dir .. '/../bracketedPaste.sh ' .. vim.b.repl_id, 'w')
    fh:write(text)
    fh:close()
end

-- not all REPLs support bracketed paste
local filetype2paste = { python=true, r=true, julia=true }

function kittySend(text)
    if filetype2paste[vim.bo.filetype] then
        kittySendPaste(text)
    else
        kittySendRaw(text)
    end
end

function ReplSendLine()
    if not replCheck() then
        print("No REPL")
    else
        -- easiest to use stdin rather than putting the text as an arg due to worrying about escaping characters
        kittySend(api.nvim_get_current_line())
        cmd 'silent normal! j'
    end
end

function ReplSendVisual()
    if not replCheck() then
        print("No REPL")
    else
        -- NOTE: old nvim versions needed gv to first reselect last select.
        -- "ky = yank to register k (k for kitty)
        -- `>  = go to mark ">" = end of last visual select
        cmd 'silent normal! "ky`>'
        kittySend(fn.getreg('k'))
    end
end

function ReplOperator(type, ...)
    if not replCheck() then
        print("No REPL")
    else
        -- `[ = go to start of motion
        -- v or V = select char or lines
        -- `] = go to end of motion
        -- "ky = yank selection to register k
        if type == "char" then
            cmd 'silent normal! `[v`]"ky`]w'
        else -- either type == "line" or "block", the latter I never use
            cmd 'silent normal! `[V`]"ky`]w'
        end
        kittySend(fn.getreg('k'))
    end
end

local defaults = {
    keymap = {
        line     = "<plug>kittyReplLine",
        visual   = "<plug>kittyReplVisual",
        operator = "<plug>kittyRepl",
        win      = "<plug>kittyReplWin",
        focus    = "<plug>kittyReplFocus",
        set      = "<plug>kittyReplSet",
        setlast  = "<plug>kittyReplSetLast",
    },
    exclude = {
        TelescopePrompt=true, -- redundant since buftype is prompt.
        oil=true,
    },
}

function setup(conf)
    -- set defaults
    conf = conf or defaults
    conf.keymap = conf.keymap or defaults.keymap
    for key, default in pairs(defaults.keymap) do
        conf.keymap[key] = conf.keymap[key] or default
    end
    conf.exclude = conf.exclude or defaults.exclude
    for key, default in pairs(defaults.exclude) do
        conf.exclude[key] = conf.exclude[key] or default
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
            
            keymap.set('n', conf.keymap.line, ReplSendLine, opts("REPL send line"))
            keymap.set('x', conf.keymap.visual, ReplSendVisual, opts("REPL send visual"))
            keymap.set('n', conf.keymap.operator, "Operator('v:lua.ReplOperator')", {buffer=true, silent=true, expr=true, desc="REPL send"})
            keymap.set('n', conf.keymap.win, ReplWindow, opts("REPL new"))
            keymap.set('n', conf.keymap.focus, ReplFocus, opts("REPL focus"))
            keymap.set('n', conf.keymap.set, ReplSet, opts("REPL set"))
            keymap.set('n', conf.keymap.setlast, ReplSetLast, opts("REPL set last"))
        end
    })
end

return {
    setup = setup
}
