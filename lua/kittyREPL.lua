#!/usr/bin/env lua
local g = vim.g
local b = vim.b
local cmd = vim.cmd
local fn = vim.fn

local config = {
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
        cr            = "<plug>kittyReplCR",
        ctrld         = "<plug>kittyReplCtrld",
        ctrlc         = "<plug>kittyReplCtrlc",
        interrupt     = "<plug>kittyReplInterrupt",
        scrollStart   = "<plug>kittyReplScrollStart",
        scrollUp      = "<plug>kittyReplScrollUp",
        scrollDown    = "<plug>kittyReplScrollDown",
        progress      = "<plug>kittyReplToggleProgress",
        editPaste     = "<plug>kittyReplToggleEditPaste",
    },
    exclude = {
        TelescopePrompt=true, -- redundant since buftype is prompt.
        oil=true,
    },
    progress = true, -- should the cursor progress after a command is run?
    editpaste = false, -- should we immidiately go to REPL when pasting?
    closepager = false, -- autoclose pager if open when running/pasting
    -- not all REPLs support bracketed paste
    bracketed = { python=true, r=true, julia=true },
    -- command to execute in new kitty window
    command = {
        python="ipython",
        julia="julia",
        -- kitty command doesn't know where R is since it doesn't have all the env copied.
        r="radian --r-binary /Library/Frameworks/R.framework/Resources/R",
        lua="lua",
    },
    -- language specific matching
    match = {
        -- kitty @ ls foreground_processes cmdline value to recognize.
        -- Key is literal match string, value is corresponding language.
        cmdline = {
            python3="python",
            ipython="python",
            IPython="python",
            R="r",
            radian="r",
        },
        -- patterns to match for prompt start and continuation for each supported REPL program
        prompt = {
            -- this will not understand pkg prompts on the form (ENV) pkg>
            -- This should be fine for grabbing cmd inputs but not for grabbing 
            -- outputs, if we were to want that. A solution would be a table of patterns, with a second pkg pattern.
            julia = {"%a*%??> ", "  "},
            radian = {"> ", "  "},
            r = {"> ", "+ "},
            python = {">>> ", "... "},
            ipython = {"In %[%d+%]: ", " +...: "},
            zsh = {"❯ ", "%a*> "}, -- e.g. for>
            sh = {"❯ ", "%a*> "},
            bash = {"[%w.-]*$ ", "> "},
            lua = {"> ", ">> "},
        },
        -- help prefix by language, e.g. "?"
        -- julia uses ? for builtin help, but with TerminalPager @help is better for long help pages.
        -- If table then the key of each entry will be matched from first to last entry.
        help = {
            julia={["pager??>"]="", ["pager>"]="?", ["help??>"]="", [">"]="@help "},
            r="?",
            python="?", -- ipython
        },
    },
}


-- TODO: use function rather than string after pull request is merged:
-- https://github.com/neovim/neovim/pull/20187
local function operator(funcname)
    return function ()
        vim.opt.operatorfunc = "v:lua." .. funcname
        return "g@"
    end
end

local function get_focused_tab()
    fh = io.popen('kitty @ ls 2> /dev/null')
    json_string = fh:read("*a")
    fh:close()
    -- if we are not in fact in a kitty terminal then the command will fail
    if json_string == "" then return end
    ls = vim.json.decode(json_string)
    for i_os_win, os_win in ipairs(ls) do
        if os_win.is_focused then
            for i_tab, tab in ipairs(os_win.tabs) do
                if tab.is_focused then
                    return tab
                end
            end
        end
    end   
end

-- Get window id of the ith window visible on the current tab.
function get_winid(i)
    return get_focused_tab().windows[i].id
end

-- Detect REPL window and cmdname and set them based on parsing kitty @ ls.
function search_repl()
    local focused_tab = get_focused_tab()
    if focused_tab == nil then return end
    for _, win in ipairs(focused_tab.windows) do
        -- we would never send to the editor.
        if win.is_self then goto continue end
        -- use last foreground process, e.g. I observe if I start julia, then `using PlotlyJS`, 
        -- then PlotlyJS will open other processes that are listed earlier in the list. 
        -- If there are any problems then just loop and look in all foreground processes.
        procs = win.foreground_processes
        cmdline = procs[#procs].cmdline
        -- example cmdline patterns:
        -- ["/usr/local/bin/julia", "-t", "4"] -> julia
        -- [".../R"] -> r
        -- ["nvim", ".../file.R"] -/-> r. Make sure we don't set the nvim editor as the REPL by accepting "." in the name match. 
        -- ["../Python", ".../radian"] -> r
        -- [".../python3"] -> python
        if cmdline[1] == "nvim" then goto continue end
        for _, arg in ipairs(cmdline) do
            -- match letters, numbers and period until the end of string arg.
            cmdname = string.match(arg, "[%w.]+$")
            repl = config.match.cmdline[cmdname] or cmdname
            if repl == vim.bo.filetype then
                b.repl_cmd = cmdname:lower()
                b.repl_id = win.id
                return win.id
            end
        end
        -- for proc over SSH the foreground_processes.cmdline will simply be ["ssh", ...]
        -- so we check the title as well
        -- "IPython: ..." -> IPython
        -- "server-name: julia" -> julia
        for cmdname in string.gmatch(win.title, "[%w]+") do
            repl = config.match.cmdline[cmdname] or cmdname
            if repl == vim.bo.filetype then
                b.repl_cmd = cmdname:lower()
                b.repl_id = win.id
                return win.id
            end
        end
        ::continue::
    end
end

function kittyExists(window_id)
    -- see if kitty window exists by getting text from it and checking if the operation fails (nonzero exit code).
    return os.execute('kitty @ get-text --match id:' .. window_id .. ' > /dev/null 2> /dev/null') == 0
end

-- Run function f with args... if REPL is valid.
function replCheck(f)
    return function (...)
        if b.repl_id ~= nil and kittyExists(b.repl_id) or search_repl() ~= nil then
            return f(...)
        else
            print("No REPL")
        end
    end
end

local function kittySendRaw(text)
    fh = io.popen('kitty @ send-text --stdin --match id:' .. b.repl_id, 'w')
    fh:write(text)
    fh:close()
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
    fh = io.popen(ROOT() .. '/bracketedPaste.sh ' .. b.repl_id .. ' "' .. post ..'"', 'w')
    fh:write(text)
    fh:close()
end

function kittySend(text, post, raw)
    if config.closepager and replDetectPager() then
        kittySendRaw("q")
    end
    if not raw and filetype2bracketed[vim.bo.filetype] then
        kittySendBracketed(text, post)
    else
        kittySendRaw(text .. post)
    end
end

local function kittyRun(text, raw)
    kittySend(text, '\n', raw)
end
local function kittyPaste(text, raw)
    kittySend(text:gsub('\n$', ''), '', raw)
    if config.editpaste then ReplFocus() end
end

local scrollback = ""
local tScrollback = {}
local iScrollback = 0

-- read the raw scrollback text and reset parsing.
local function readScrollback()
    fh = io.popen('kitty @ get-text --extent=all --match id:' .. b.repl_id)
    scrollback = fh:read("*a")
    fh:close()
    -- reset
    tScrollback = {}
    iScrollback = 0
end

---Parse one command entry from the scrollback text and truncate the text afterwards.
---@return string: the matched prompt string
---@return table: the new parsed command, as array of lines
local function parseScrollback()
    local pat, patCont = unpack(config.match.prompt[b.repl_cmd])
    local lines = {}
    while true do
        lastline = scrollback:match("\n([^\n]*)$")
        if lastline == nil then return end
        scrollback = scrollback:sub(1, #scrollback - #lastline - 1)
        local mPrompt = lastline:match(pat)
        if mPrompt ~= nil then
            rcmd = {lastline:sub(mPrompt)}
            for i, line in ipairs(lines) do
                local mPromptCont = line:match(patCont)
                if mPromptCont ~= nil then
                    table.insert(rcmd, line:sub(mPromptCont))
                else
                    return rcmd
                end
            end
            return rcmd
        else
            table.insert(lines, 1, lastline)
        end
    end
end

---Scroll through REPL commands, while parsing scrollback when necessary.
---@param delta integer. 1 or -1
---@return table of strings
local function scroll(delta)
    if vim.v.count ~= 0 then
        delta = delta * vim.v.count
    end
    if delta > 0 then
        for i = 1, delta do
            if iScrollback == #tScrollback then
                -- skip empty prompts
                rcmd = {""}
                while table.concat(rcmd) == "" do
                    rcmd = parseScrollback()
                    if rcmd == nil then
                        print("REPL top")
                        return tScrollback[iScrollback]
                    end
                end
                table.insert(tScrollback, rcmd)
            end
            iScrollback = iScrollback + 1
        end
        print(iScrollback)
        return tScrollback[iScrollback]
    else
        iScrollback = iScrollback + delta
        if iScrollback < 1 then
            iScrollback = 1
            print("REPL bottom")
        else
            print(iScrollback)
        end
        return tScrollback[iScrollback]
    end
end

---Detect whether the REPL is currently displaying a pager, e.g. help texts.
---@return boolean
function replDetectPager()
    fh = io.popen('kitty @ get-text --extent=screen --add-cursor --match id:' .. b.repl_id)
    local scrollback = vim.split(fh:read("*a"), '\n')
    -- remove empty string at the end due to final newline char
    table.remove(scrollback, #scrollback)
    fh:close()
    lastline = scrollback[#scrollback]
    -- does the last line start with a colon and some whitespace?
    local colon = lastline:match("^:%s+")
    if colon == nil then return false end
    -- as a second measure we also check that the cursor is placed right after the colon.
    -- Lua pattern explanation:
    -- Matched pattern is ^[[n;mH
    -- where ^[ is ESC, n is an integer indicating cursor row and m indicates cursor column. Both 1-indexed.
    -- https://en.wikipedia.org/wiki/ANSI_escape_code
    local r, c = lastline:match("%c%[(%d+);(%d+)H")
    return tonumber(r) == #scrollback and tonumber(c) == 2
end

---Get the help command needed to prefix a help search term for the current language.
---@return string: Prefix string for command to run in REPL to get help for a given query.
function replHelpPrefix()
    local prefix = config.match.help[vim.bo.filetype] or "?"
    -- if the config.match.help entry for a language is a table, then it means 
    -- we need to look for the current REPL prompt context to understand which 
    -- prefix is appropriate.
    if type(prefix) ~= "table" then return prefix end
    readScrollback()
    while true do
        lastline = scrollback:match("\n([^\n]*)$")
        if lastline == nil then return end
        scrollback = scrollback:sub(1, #scrollback - #lastline - 1)
        for pat, pre in pairs(prefix) do
            if lastline:match(pat) then
                return pre
            end
        end
    end
    return "?"
end

-- Top level keybound commands.

--- Launch a new REPL window
function ReplNew()
    -- default to zsh
    local ftcommand = config.command[vim.bo.filetype] or ""
    local fh = io.popen('kitty @ launch --cwd=current --keep-focus ' .. ftcommand)
    local window_id = fh:read("*n") -- *n means read number, which means we also strip newline
    fh:close()
    -- show id in the title so we can easily set is as target, but also start 
    -- with the cmd like it would have been named by if opened in a regular way.
    local title = ftcommand:match("[^ ]+") .. " id=" .. window_id
    os.execute("kitty @ set-window-title --match id:" .. window_id .. " " .. title)
    b.repl_id = window_id
    b.repl_cmd = ftcommand:match("[^ ]+"):lower()
end
-- change kitty focus from editor to REPL
local function ReplFocus()
    os.execute('kitty @ focus-window --match id:' .. b.repl_id)
end
-- manually set repl as ith visible window from a prompt.
-- Useful to have keybinding to this function.
function ReplSetI()
    b.repl_id = get_winid(tonumber(fn.input("Window i: ")))
end
local function ReplSet()
    b.repl_id = tonumber(fn.input("Window id: "))
end
-- set REPL window id to the last active window
local function ReplSetLast()
    hist = get_focused_tab().active_window_history
    b.repl_id = hist[#hist]
    -- TODO: detect from kitty @ ls instead
    b.repl_cmd = vim.bo.filetype
end
local function ReplRunLine()
    kittyRun(vim.api.nvim_get_current_line(), true)
    if config.progress then
        cmd 'silent normal! j'
    end
end
local function ReplPasteLine()
    kittyPaste(vim.api.nvim_get_current_line(), true)
    if config.progress then
        cmd 'silent normal! j'
    end
end
local function ReplRunVisual()
    -- "ky = yank to register k (k for kitty)
    cmd 'silent normal! "ky'
    kittyRun(fn.getreg('k'))
    if config.progress then
        -- `>  = go to mark ">" = end of last visual select
        cmd 'silent normal! `>'
    end
end
local function ReplPasteVisual()
    cmd 'silent normal! "ky'
    kittyPaste(fn.getreg('k'))
    if config.progress then
        cmd 'silent normal! `>'
    end
end
function ReplRunOperator(type, ...)
    -- `[ = go to start of motion
    -- v or V = select char or lines
    -- `] = go to end of motion
    -- "ky = yank selection to register k
    if type == "char" then
        cmd 'silent normal! `[v`]"ky'
    else -- either type == "line" or "block", the latter I never use
        cmd 'silent normal! `[V`]"ky'
    end
    kittyRun(fn.getreg('k'))
    if config.progress then
        cmd 'silent normal! `]w'
    end
end
function ReplPasteOperator(type, ...)
    if type == "char" then
        cmd 'silent normal! `[v`]"ky'
    else
        cmd 'silent normal! `[V`]"ky'
    end
    kittyPaste(fn.getreg('k'))
    if config.progress then
        cmd 'silent normal! `]w'
    end
end
local function ReplHelp()
    kittyRun(replHelpPrefix() .. fn.expand("<cword>"), true)
end
local function ReplHelpVisual()
    cmd 'silent normal! "ky'
    kittyRun(replHelpPrefix() .. fn.getreg('k'), true)
    if config.progress then
        cmd 'silent normal! `>'
    end
end
--- Make a function to send given text when called.
function kittySendCustom(text)
    return function () kittySendRaw(text) end
end
--- Send a SIGINT to the REPL.
local function kittyInterrupt()
    return os.execute('kitty @ signal-child --match id:' .. b.repl_id)
end
local function startScroll()
    readScrollback()
    local rcmd = scroll(1)
    if rcmd == nil then return end -- in case no commands can be detected
    vim.api.nvim_put(rcmd, "c", true, false) -- "follow=true" only moves the cursor 1 char.
    vim.cmd.normal("v`[o")
end
local function replaceScroll(delta)
    return function ()
        -- edge case where replaceScroll is called before startScroll
        if iScrollback == 0 then readScrollback() end
        local rcmd = scroll(delta)
        fn.setreg("k", rcmd)
        cmd.normal '"kpv`[o'
    end
end
function ReplToggleProgress()
    config.progress = not config.progress
    print("REPL progress =", config.progress)
end
function ReplToggleEditPaste()
    config.editpaste = not config.editpaste
    print("REPL edit paste =", config.editpaste)
end


function setup(userconfig)
    -- TODO: check if term is kitty

    if userconfig ~= nil then
        config = vim.tbl_deep_extend("keep", userconfig, config)
    end

    local c = config
    
    -- match against start of line, get the location of the end
    for k, v in pairs(c.match.prompt) do
        c.match.prompt[k][1] = "^" .. v[1] .. "()"
        c.match.prompt[k][2] = "^" .. v[2] .. "()"
    end


    local group = vim.api.nvim_create_augroup("kittyRepl", {clear=true})
    -- BufEnter is too early for e.g. cmdline window to assign buftype
    vim.api.nvim_create_autocmd("Filetype", {
        group = group,
        callback = function ()
            if vim.bo.buftype ~= "" then return end 
            if c.exclude[vim.bo.filetype] then return end

            function opts(desc)
                return {buffer=true, silent=true, desc=desc}
            end

            local map = vim.keymap.set
            map('n', c.keymap.new,         ReplNew,                                  opts("REPL new"))
            map('n', c.keymap.focus,       replCheck(ReplFocus),                     opts("REPL focus"))
            map('n', c.keymap.set,         ReplSet,                                  opts("REPL set"))
            map('n', c.keymap.setlast,     ReplSetLast,                              opts("REPL set last"))
            map('n', c.keymap.run,         replCheck(operator("ReplRunOperator")),   {buffer=true, silent=true, expr=true, desc="REPL run motion"})
            map('n', c.keymap.paste,       replCheck(operator("ReplPasteOperator")), {buffer=true, silent=true, expr=true, desc="REPL paste motion"})
            map('n', c.keymap.help,        replCheck(ReplHelp),                      opts("REPL help word under cursor"))
            map('x', c.keymap.help,        replCheck(ReplHelpVisual),                opts("REPL help visual"))
            map('n', c.keymap.runLine,     replCheck(ReplRunLine),                   opts("REPL run line"))
            map('n', c.keymap.pasteLine,   replCheck(ReplPasteLine),                 opts("REPL paste line"))
            map('x', c.keymap.runVisual,   replCheck(ReplRunVisual),                 opts("REPL run visual"))
            map('x', c.keymap.pasteVisual, replCheck(ReplPasteVisual),               opts("REPL paste visual"))
            map('n', c.keymap.q,           replCheck(kittySendCustom("q")),          opts("REPL send q"))
            map('n', c.keymap.cr,          replCheck(kittySendCustom("\x0d")),       opts("REPL send CR"))
            map('n', c.keymap.ctrld,       replCheck(kittySendCustom("\x04")),       opts("REPL send Ctrl+d"))
            map('n', c.keymap.ctrlc,       replCheck(kittySendCustom("\x03")),       opts("REPL send Ctrl+c"))
            map('n', c.keymap.interrupt,   replCheck(kittyInterrupt),                opts("REPL interrupt"))
            map('n', c.keymap.scrollStart, replCheck(startScroll),                   opts("REPL paste from scrollback"))
            map('x', c.keymap.scrollUp,    replCheck(replaceScroll(1)),              opts("REPL paste older scrollback"))
            map('x', c.keymap.scrollDown,  replCheck(replaceScroll(-1)),             opts("REPL paste newer scrollback"))
            map('n', c.keymap.progress,    ReplToggleProgress,                       opts("REPL toggle progress"))
            map('n', c.keymap.editPaste,   ReplToggleEditPaste,                      opts("REPL toggle edit paste"))
        end
    })
end

return {
    setup = setup
}
