local b = vim.b
local cmd = vim.cmd
local fn = vim.fn

---Count number of occurences of pattern in text.
---@param text string
---@param pattern string
---@return integer
local function strcount(text, pattern)
    return select(2, string.gsub(text, pattern, ""))
end

-- LATER: use function rather than string after pull request is merged:
-- https://github.com/neovim/neovim/pull/20187
local function operator(funcname)
    return function()
        vim.opt.operatorfunc = "v:lua." .. funcname
        return "g@"
    end
end

---Parse kitty @ ls output into table.
---@param match string? optionally filter with --match argument
---@return table
local function kitty_ls(match)
    if match == nil then
        match = ""
    else
        match = " --match=" .. match
    end
    local fh = io.popen('kitty @ ls' .. match .. ' 2> /dev/null')
    local json_string = fh:read("*a")
    fh:close()
    -- if we are not in fact in a kitty terminal then the command will fail
    if json_string == "" then return end
    return vim.json.decode(json_string)
end

local function get_focused_tab()
    local ls = kitty_ls()
    if ls == nil then return end
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

local function get_repl_win()
    local ls = kitty_ls()
    if ls == nil then return end
    for i_os_win, os_win in ipairs(ls) do
        for i_tab, tab in ipairs(os_win.tabs) do
            for _, win in ipairs(tab.windows) do
                if win.id == vim.b.repl_id then
                    return win
                end
            end
        end
    end
end

-- Get window id of the ith window visible on the current tab.
function get_winid(i)
    return get_focused_tab().windows[i].id
end

function kittyExists(window_id)
    -- see if kitty window exists by getting text from it and checking if the operation fails (nonzero exit code).
    return os.execute('kitty @ get-text --match id:' .. window_id .. ' > /dev/null 2> /dev/null') == 0
end

-- change kitty focus from editor to REPL
local function ReplFocus()
    os.execute('kitty @ focus-window --match id:' .. b.repl_win)
end

local function kittySendRaw(text)
    local fh = io.popen('kitty @ send-text --stdin --match id:' .. b.repl_win, 'w')
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
    local fh = io.popen(ROOT() .. '/bracketedPaste.sh ' .. b.repl_win .. ' "' .. post .. '"', 'w')
    fh:write(text)
    fh:close()
end

local config = {
    -- Set keymaps in setup call or map something to these <plug> maps.
    keymap = {
        new         = "<plug>kittyReplNew",
        focus       = "<plug>kittyReplFocus",
        set         = "<plug>kittyReplSet",
        setlast     = "<plug>kittyReplSetLast",
        run         = "<plug>kittyReplRun",
        paste       = "<plug>kittyReplPaste",
        help        = "<plug>kittyReplHelp",
        runLine     = "<plug>kittyReplRunLine",
        runLineFor  = "<plug>kittyReplRunLineFor",
        runLineForI = "<plug>kittyReplRunLineForI",
        pasteLine   = "<plug>kittyReplPasteLine",
        runVisual   = "<plug>kittyReplRunVisual",
        pasteVisual = "<plug>kittyReplPasteVisual",
        q           = "<plug>kittyReplQ",
        cr          = "<plug>kittyReplCR",
        ctrld       = "<plug>kittyReplCtrld",
        ctrlc       = "<plug>kittyReplCtrlc",
        interrupt   = "<plug>kittyReplInterrupt",
        scrollStart = "<plug>kittyReplScrollStart",
        scrollUp    = "<plug>kittyReplScrollUp",
        scrollDown  = "<plug>kittyReplScrollDown",
        progress    = "<plug>kittyReplToggleProgress",
        editPaste   = "<plug>kittyReplToggleEditPaste",
    },
    -- Disable plugin for these filetypes:
    exclude = {
        TelescopePrompt = true, -- redundant since buftype is prompt.
        oil = true,
        qf = true,
    },
    progress = true,    -- should the cursor progress after a command is run?
    editpaste = false,  -- should we immidiately go to REPL when pasting?
    closepager = false, -- autoclose pager if open when running/pasting
    -- not all REPLs support bracketed paste.
    -- stock python repl is particularly bad. It doesn't support bracketed, it
    -- can't handle empty line within indentation, it doesn't understand the
    -- SOH code.
    bracketed = { ipython = true, python = false, radian = true, r = false, julia = true, pymol = false, pml = false, },
    -- Stock python REPL writes "..." too slow when running multiple lines.
    -- This "linewise" config enables splitting multiline messages by newlines
    -- and sends them one at a time. Still skipping empty newlines or adding
    -- whitespace to them.
    linewise = { python = true, },
    -- custom functions for how to send code to the REPL. Args: text, post. post is either '' or '\n'.
    custom = {
        pymol = function(text, post)
            -- wrap multiline in python .. python end
            -- https://pymolwiki.org/index.php/PythonTerminal
            if text:match('\n') then
                kittySendRaw("python\n" .. text:gsub("\n*$", "") .. "\npython end" .. post)
            else
                kittySendRaw(text .. post)
            end
        end,
        lua = function(text, post)
            -- top level locals are ignored in REPL so we strip that.
            kittySendRaw(text:gsub("^local ", ""):gsub("\nlocal ", "\n") .. post)
        end,
        -- Fixed a huge problem, super weird, julia was insanely slow typing one char at a time.
        -- I realised it was because even though we set it to use bracketed it only sends it bracketed with multiline.
        -- Solution here: always send bracketed.
        julia = function(text, post)
            kittySendBracketed(text, post)
        end,
    },
    -- command to execute in new kitty window.
    -- TODO: add fallback and don't assume MacOS.
    command = {
        python = "ipython",
        julia = "julia",
        -- kitty command doesn't know where R is since it doesn't have all the env copied.
        r = "radian --r-binary /Library/Frameworks/R.framework/Resources/R",
        lua = "lua",
        pymol = "pymol -xpq",
    },
    -- Additional to command, when given a vim.v.count
    command_count = {
        julia = " -t ",
    },
    -- language specific matching
    match = {
        -- kitty @ ls foreground_processes cmdline value to recognize for auto finding REPL for the buffer.
        -- over SSH the foreground_processes.cmdline will simply be ["ssh", ...] so we also detect using title
        -- filetype -> function(cmdline, title) -> nil or REPL name
        detect = {
            julia = function(cmdline, title)
                -- ["/usr/local/bin/julia", "-t", "4"] -> julia
                if cmdline[1]:match("[%w.]+$") == "julia" then
                    return "julia"
                end
            end,
            python = function(cmdline, title)
                if title:match("^IPython:") then
                    return "ipython"
                end
                -- ["/opt/homebrew/Caskroom/miniforge/base/envs/pymol/bin/python", "/opt/homebrew/Caskroom/miniforge/base/envs/pymol/lib/python3.12/site-packages/pymol/__init__.py"] -> pymol
                if cmdline ~= nil and cmdline[2]:match("/pymol/__init__.py$") then
                    return "pymol"
                end
                -- [".../python3"] -> python
                local firstword = cmdline[1]:match("[%w.]+$"):lower()
                if firstword:match("ipython3?") then
                    return "ipython"
                elseif firstword:match("python3?") then
                    return "python"
                end
            end,
            r = function(cmdline, title)
                -- [".../R"] -> r
                if cmdline[1]:match("[%w.]+$") == "R" or
                    -- ["../Python", ".../radian"] -> r
                    cmdline[2]:match("[%w.]+$") == "radian" then
                    return "r"
                end
                -- "server-name: julia" -> julia
                if title:match("[%w.]+$") == "julia" then
                    return "julia"
                end
            end,
        },
        -- patterns to match for prompt start and continuation for each supported REPL program
        prompt = {
            -- this will not understand pkg prompts on the form (ENV) pkg>
            -- This should be fine for grabbing cmd inputs but not for grabbing
            -- outputs, if we were to want that. A solution would be a table of patterns, with a second pkg pattern.
            julia = { "%a*%??> ", "  " },
            radian = { "> ", "  " },
            r = { "> ", "+ " },
            python = { ">>> ", "... " },
            ipython = { "In %[%d+%]: ", " +...: " },
            zsh = { "❯ ", "%a*> " }, -- e.g. for>
            sh = { "❯ ", "%a*> " },
            bash = { "[%w.-]*$ ", "> " },
            lua = { "> ", ">> " },
            pymol = { "", "" },
        },
        -- Help command by REPL command and context, often a "?" prefix.
        -- For each REPL command provide either a help command prefix string, a two element array with prefix and suffix,
        -- or a key-value table where each key will be matched against the last prompt (from first to last key).
        -- E.g. julia uses ? for builtin help, but with TerminalPager @help is better for long help pages.
        help = {
            -- TODO: this shouldn't be default as it assumes TerminalPager is installed.
            julia = { ["pager??>"] = "", ["pager>"] = "?", ["help??>"] = "", [">"] = "@help " },
            radian = "?",
            r = "?",
            ipython = "?",
            python = { "help(", ")" },
            lua = "", -- no help available
        },
    },
}

---Detect REPL window relevant for the current filetype and detect which cmd is
---being run in the repl by scanning through windows and matching on cmdline
---and title.
---@param wins? table list of window ids to search. Default=all in the focused tab.
---@return integer?
local function detect_REPL(wins)
    local detect = config.match.detect[vim.bo.filetype]
    if wins == nil then
        if detect == nil then
            print("No detect config for " ..
                vim.bo.filetype .. ". Can't detect window and assumes REPL command is \"" .. vim.bo.filetype .. "\".")
            b.repl_cmd = vim.bo.filetype
            return
        end
        local focused_tab = get_focused_tab()
        if focused_tab == nil then return end
        wins = focused_tab.windows
    end
    for _, win in ipairs(wins) do
        if type(win) == "number" then
            -- with the --match=id:win filter we still get the same hierarchy,
            -- but "tabs" and "windows" only have 1 entry each due to the
            -- filter.
            win = kitty_ls("id:" .. win)[1].tabs[1].windows[1]
        end
        -- use last foreground process, e.g. I observe if I start julia, then `using PlotlyJS`,
        -- then PlotlyJS will open other processes that are listed earlier in the list.
        -- If there are any problems then just loop and look in all foreground processes.
        local procs = win.foreground_processes
        local cmdline = procs[#procs].cmdline
        -- we would never send to the editor.
        if not win.is_self and cmdline[1] ~= "nvim" then
            -- no detection config, but we are specifying exactly which window the REPL is in
            if detect == nil and #wins == 1 then
                b.repl_cmd = table.concat(cmdline, " ")
                print("No detect config for " .. vim.bo.filetype .. ". Assumes REPL command is \"" .. b.repl_cmd .. "\".")
                return win.id
            end
            local repl_cmd = detect(cmdline, win.title)
            if repl_cmd then
                b.repl_cmd = repl_cmd
                b.repl_win = win.id
                return win.id
            end
        end
    end
end

-- Run function f with args... if REPL is valid.
local function replCheck(f)
    return function(...)
        if b.repl_win ~= nil and kittyExists(b.repl_win) or detect_REPL() ~= nil then
            return f(...)
        else
            print("No REPL")
        end
    end
end

local function kittySend(text, post, raw)
    if config.closepager and replDetectPager() then
        kittySendRaw("q")
    end
    if raw then
        kittySendRaw(text .. post)
    else
        if config.custom[vim.b.repl_cmd] then
            config.custom[vim.b.repl_cmd](text, post)
        elseif config.bracketed[vim.b.repl_cmd] then
            if strcount(text, "\n") > 0 then
                kittySendBracketed(text, post)
            else
                kittySendRaw(text .. post)
            end
        elseif config.linewise[vim.b.repl_cmd] then
            for _, line in ipairs(vim.split(text, '\n')) do
                if line ~= "" then
                    kittySendRaw(line .. '\n')
                end
            end
            kittySendRaw(post)
        else
            -- mostly for python's sake, we could remove empty lines.
            -- It would also work to add any amount of whitespace on the empty lines.
            -- We use the linewise send above instead.
            -- kittySendRaw(text:gsub('\n+', '\n') .. post)
            -- kittySendRaw(text .. post)
            kittySendRaw(text .. post)
        end
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
    local fh = io.popen('kitty @ get-text --extent=all --match id:' .. b.repl_win)
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
        local lastline = scrollback:match("\n([^\n]*)$")
        if lastline == nil then return end
        scrollback = scrollback:sub(1, #scrollback - #lastline - 1)
        local mPrompt = lastline:match(pat)
        if mPrompt ~= nil then
            local rcmd = { lastline:sub(mPrompt) }
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
---@param delta integer 1 or -1
---@return table of strings
local function scroll(delta)
    if vim.v.count ~= 0 then
        delta = delta * vim.v.count
    end
    if delta > 0 then
        for _ = 1, delta do
            if iScrollback == #tScrollback then
                -- skip empty prompts
                local rcmd = { "" }
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
---Does the last line start with a colon and then the cursor or does the last nonempty line start with (END) and then the cursor?
---@return boolean
function replDetectPager()
    local fh = io.popen('kitty @ get-text --extent=screen --add-cursor --match id:' .. b.repl_win)
    local scrollback = fh:read("*a")
    fh:close()
    -- Get cursor position to check if it is placed right after a pager pattern to match.
    -- Lua pattern explanation:
    -- Matched pattern is ^[[?25h^[[n;mH^[[?12h where
    -- ^[ is ESC and ^[[ is known as CSI (Control Sequence Introducer)
    -- n is an integer indicating cursor row and m indicates cursor column. Both 1-indexed.
    -- ^[[?25h means "show the cursor". I don't know what ^[[?12h does.
    -- https://en.wikipedia.org/wiki/ANSI_escape_code
    local helplines, lastline, blanklines, r, c = scrollback:match(
        "(.*)\n([^\n]+)(\n*)%c%[%?25h%c%[(%d+);(%d+)H%c%[%?%d+h\n$")
    -- if we aren't scrolled to the bottom lastline will be nil.
    if lastline == nil then return false end
    local pagerMatch = lastline:match("^(:)")
    if pagerMatch and #blanklines > 0 then return false end
    if not pagerMatch then pagerMatch = lastline:match("^%(END%)") end
    if not pagerMatch then return false end
    local _, nlines = helplines:gsub('\n', '')
    -- +2 since "lines" doesn't contain "lastline" and the newline right before it.
    -- NOTE: The pattern doesn't work if that newline gets included.
    return tonumber(r) == nlines + 2 and tonumber(c) == #pagerMatch + 1
end

---Get the help command needed to prefix a help search term for the current language.
---@param query string
---@return string: string cmd to run in REPL to get help for a given query.
function replHelpCmd(query)
    local helpCmd = config.match.help[vim.bo.filetype] or "?"
    -- if the config.match.help entry for a language is a table, then it means
    -- we need to look for the current REPL prompt context to understand which
    -- prefix is appropriate.
    if type(helpCmd) ~= "table" then return helpCmd .. query end
    if vim.islist(helpCmd) and #helpCmd == 2 then
        return helpCmd[1] .. query .. helpCmd[2]
    end
    -- otherwise key-value dict
    readScrollback()
    while true do
        local lastline = scrollback:match("\n([^\n]*)$")
        if lastline == nil then return end
        scrollback = scrollback:sub(1, #scrollback - #lastline - 1)
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
    return "?"
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

-- Top level keybound commands.

--- Launch a new REPL window.
--- vim.v.count used as well, e.g. to use multiple threads.
function ReplNew()
    -- default to zsh
    local ftcommand = config.command[vim.bo.filetype] or ""
    if vim.v.count > 0 then
        local ftcommand_count = config.command_count[vim.bo.filetype]
        if ftcommand_count ~= nil then
            ftcommand = ftcommand .. ftcommand_count .. vim.v.count
        end
    end
    local fh = io.popen('kitty @ launch --cwd=current --keep-focus ' .. ftcommand)
    local win = fh:read("*n") -- *n means read number, which means we also strip newline
    fh:close()
    -- show id in the title so we can easily set is as target, but also start
    -- with the cmd like it would have been named by if opened in a regular way.
    local title = ftcommand:match("[^ ]+") .. " id=" .. win
    os.execute("kitty @ set-window-title --match id:" .. win .. " " .. title)
    b.repl_win = win
    b.repl_cmd = ftcommand:match("[^ ]+"):lower()
end

-- manually set repl as ith visible window from a prompt.
-- Useful to have keybinding to this function.
function ReplSetI()
    b.repl_win = get_winid(tonumber(fn.input("Window i: ")))
end

local function ReplSet()
    b.repl_win = tonumber(fn.input("Window id: "))
end
-- set REPL window id to the last active window
local function ReplSetLast()
    local history = get_focused_tab().active_window_history
    b.repl_win = history[#history]
    if not detect_REPL { b.repl_win } then
        -- fallback
        b.repl_cmd = vim.bo.filetype
    end
end
local function ReplRunLine()
    for _ = 1, vim.v.count1 do
        kittyRun(vim.api.nvim_get_current_line(), false)
        if config.progress then
            cmd 'silent normal! j'
        end
    end
end
local function ReplPasteLine()
    for _ = 1, vim.v.count1 do
        kittyPaste(vim.api.nvim_get_current_line(), false)
        if config.progress then
            cmd 'silent normal! j'
        end
    end
end
local ft_iterate = { julia = "first", python = "next" }
local function ReplRunLineFor()
    local variable, iterable = parseVariableIterable(vim.api.nvim_get_current_line())
    -- TODO: vim.v.count1 used for not running first but later entry of iterable.
    local torun = variable .. " = " .. ft_iterate[vim.bo.filetype] .. "(" .. iterable .. ")"
    kittyRun(torun, true)
    if config.progress then
        cmd 'silent normal! j'
    end
end
local ft_indexing = { julia = 1, python = 0, r = 1 }
---Same as ReplRunLineFor but instead of using next etc. assuming iterator we use indexing.
---Count is used for the index. If not given explicitly it will default to 1 or
---0 depending on if the language is 1 or 0-indexed.
local function ReplRunLineForI()
    local count = vim.v.count > 0 and vim.v.count or ft_indexing[vim.bo.filetype]
    local variable, iterable = parseVariableIterable(vim.api.nvim_get_current_line())
    local torun = variable .. " = " .. iterable .. "[" .. count .. "]"
    kittyRun(torun, true)
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
    kittyRun(replHelpCmd(fn.expand("<cword>")), true)
end
local function ReplHelpVisual()
    cmd 'silent normal! "ky'
    kittyRun(replHelpCmd(fn.getreg('k')), true)
    if config.progress then
        cmd 'silent normal! `>'
    end
end
--- Make a function to send given text when called.
function kittySendCustom(text)
    return function() kittySendRaw(text) end
end

--- Send a SIGINT to the REPL.
local function kittyInterrupt()
    return os.execute('kitty @ signal-child --match id:' .. b.repl_win)
end
local function startScroll()
    readScrollback()
    local rcmd = scroll(1)
    if rcmd == nil then return end           -- in case no commands can be detected
    vim.api.nvim_put(rcmd, "c", true, false) -- "follow=true" only moves the cursor 1 char.
    vim.cmd.normal("v`[o")
end
local function replaceScroll(delta)
    return function()
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


    local group = vim.api.nvim_create_augroup("kittyRepl", { clear = true })
    -- BufEnter is too early for e.g. cmdline window to assign buftype
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        callback = function()
            if vim.bo.buftype ~= "" then return end
            if c.exclude[vim.bo.filetype] then return end

            local map = vim.keymap.set
            local function nmap(lhs, rhs, desc, expr)
                local opts = { buffer = true, silent = true }
                opts["desc"] = desc
                opts["expr"] = expr
                map('n', lhs, rhs, opts)
            end
            local function xmap(lhs, rhs, desc, expr)
                local opts = { buffer = true, silent = true }
                opts["desc"] = desc
                opts["expr"] = expr
                map('x', lhs, rhs, opts)
            end

            nmap(c.keymap.new, ReplNew, "REPL new")
            nmap(c.keymap.focus, replCheck(ReplFocus), "REPL focus")
            nmap(c.keymap.set, ReplSet, "REPL set")
            nmap(c.keymap.setlast, ReplSetLast, "REPL set last")
            nmap(c.keymap.run, replCheck(operator("ReplRunOperator")), "REPL run motion", true)
            nmap(c.keymap.paste, replCheck(operator("ReplPasteOperator")), "REPL paste motion", true)
            nmap(c.keymap.help, replCheck(ReplHelp), "REPL help word under cursor")
            xmap(c.keymap.help, replCheck(ReplHelpVisual), "REPL help visual")
            nmap(c.keymap.runLine, replCheck(ReplRunLine), "REPL run line")
            nmap(c.keymap.runLineFor, replCheck(ReplRunLineFor), "REPL iterate")
            nmap(c.keymap.runLineForI, replCheck(ReplRunLineForI), "REPL index")
            nmap(c.keymap.pasteLine, replCheck(ReplPasteLine), "REPL paste line")
            xmap(c.keymap.runVisual, replCheck(ReplRunVisual), "REPL run visual")
            xmap(c.keymap.pasteVisual, replCheck(ReplPasteVisual), "REPL paste visual")
            nmap(c.keymap.q, replCheck(kittySendCustom("q")), "REPL send q")
            nmap(c.keymap.cr, replCheck(kittySendCustom("\x0d")), "REPL send CR")
            nmap(c.keymap.ctrld, replCheck(kittySendCustom("\x04")), "REPL send Ctrl+d")
            nmap(c.keymap.ctrlc, replCheck(kittySendCustom("\x03")), "REPL send Ctrl+c")
            nmap(c.keymap.interrupt, replCheck(kittyInterrupt), "REPL interrupt")
            nmap(c.keymap.scrollStart, replCheck(startScroll), "REPL paste from scrollback")
            xmap(c.keymap.scrollUp, replCheck(replaceScroll(1)), "REPL paste older scrollback")
            xmap(c.keymap.scrollDown, replCheck(replaceScroll(-1)), "REPL paste newer scrollback")
            nmap(c.keymap.progress, ReplToggleProgress, "REPL toggle progress")
            nmap(c.keymap.editPaste, ReplToggleEditPaste, "REPL toggle edit paste")
        end
    })
end

return {
    setup = setup
}
