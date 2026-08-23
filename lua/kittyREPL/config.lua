-- Default configuration for kittyREPL
--
-- The per-language tables below are keyed on one of two axes. Which one is not
-- visible at a call site, so it is recorded per table:
-- * filetype, i.e. the file being edited:
--   exclude, command, command_count, iterate, match.detect
-- * program, i.e. what runs in the REPL window:
--   bracketed, linewise, custom, match.prompt, match.help
-- match.detect bridges the two: it is keyed by filetype and returns a program
-- name. A program name and a filetype coincide for some languages (julia, lua)
-- and differ for others (an r buffer drives radian).
local M = {
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
        scrollOutputAbove = "<plug>kittyReplScrollOutputAbove",
        scrollOutputBelow = "<plug>kittyReplScrollOutputBelow",
    },
    -- Disable plugin for these filetypes:
    exclude = {
        TelescopePrompt = true, -- redundant since buftype is prompt.
        oil = true,
        qf = true,
    },
    progress = true,    -- should the cursor progress after a command is run?
    editpaste = false,  -- should we immediately go to REPL when pasting?
    closepager = false, -- autoclose pager if open when running/pasting
    -- Program-keyed. Not all REPLs support bracketed paste.
    -- stock python repl is particularly bad. It doesn't support bracketed, it
    -- can't handle empty line within indentation, it doesn't understand the
    -- SOH code.
    -- stock R echoes the bracketed paste markers as literal text ("00~", "01~")
    -- and then fails to parse the block; it takes multiline raw sends fine.
    bracketed = { ipython = true, python = false, radian = true, r = false, julia = true, pymol = false, pml = false },
    -- Program-keyed.
    -- Stock python REPL writes "..." too slow when running multiple lines.
    -- This "linewise" config enables splitting multiline messages by newlines
    -- and sends them one at a time. Still skipping empty newlines or adding
    -- whitespace to them.
    linewise = { python = true },
    -- custom functions for how to send code to the REPL. Args: text, post. post is either '' or '\n'.
    -- Populated in init.lua after kitty module is available.
    custom = {},
    -- command to execute in new kitty window.
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
    -- Filetype-keyed expressions taking an element out of an iterable, used to
    -- run a single iteration of a loop. "first" is used by runLineFor, "index"
    -- by runLineForI with the count as index, defaulting to "base".
    -- The iterables are wrapped rather than indexed directly, since a python
    -- zip/enumerate/generator is not subscriptable and neither is a julia zip.
    -- R needs the parentheses because [[ binds tighter than :, so 1:10[[1]] is
    -- 1:(10[[1]]), i.e. the whole vector rather than its first element.
    iterate = {
        python = { first = "next(iter(%s))", index = "list(iter(%s))[%d]", base = 0 },
        julia  = { first = "first(%s)",      index = "collect(%s)[%d]",    base = 1 },
        r      = { first = "(%s)[[1]]",      index = "(%s)[[%d]]",         base = 1 },
    },
    -- language specific matching
    match = {
        -- kitty @ ls foreground_processes cmdline value to recognize for auto finding REPL for the buffer.
        -- over SSH the foreground_processes.cmdline will simply be ["ssh", ...] so we also detect using title
        -- filetype -> function(cmdline, title) -> nil or program name
        ---@type table<string, fun(cmdline: string[]|nil, title: string): string|nil>
        detect = {
            sh = function(cmdline)
                if not cmdline or not cmdline[1] then return end
                -- matches both "/bin/zsh" and a login shell's "-zsh"
                local shell = cmdline[1]:match("%w+$")
                if shell == "zsh" then return "zsh"
                elseif shell == "bash" then return "bash"
                elseif shell == "sh" then return "sh"
                end
            end,
            julia = function(cmdline)
                if not cmdline or not cmdline[1] then return end
                -- ["/usr/local/bin/julia", "-t", "4"] -> julia
                if cmdline[1]:match("[%w.]+$") == "julia" then
                    return "julia"
                end
            end,
            python = function(cmdline, title)
                if title:match("^IPython:") then
                    return "ipython"
                end
                if not cmdline or not cmdline[1] then return end
                -- [".../python", ".../pymol/__init__.py", "-xpq"] -> pymol
                if cmdline[2] and cmdline[2]:match("/pymol/__init__.py$") then
                    return "pymol"
                end
                -- [".../ipython/bin/python3", ".../bin/ipython"] -> ipython.
                -- The title check above misses a window we retitled ourselves.
                if cmdline[2] and cmdline[2]:match("/ipython3?$") then
                    return "ipython"
                end
                -- [".../python3"] -> python
                local firstword = cmdline[1]:match("[%w.]+$")
                if not firstword then return end
                firstword = firstword:lower()
                if firstword:match("ipython3?") then
                    return "ipython"
                elseif firstword:match("python3?") then
                    return "python"
                end
            end,
            r = function(cmdline)
                if not cmdline or not cmdline[1] then return end
                -- [".../bin/exec/R", "--no-save"] -> r
                if cmdline[1]:match("[%w.]+$") == "R" then
                    return "r"
                end
                -- [".../python3", ".../radian", "--r-binary", ...] -> radian
                if cmdline[2] and cmdline[2]:match("[%w.]+$") == "radian" then
                    return "radian"
                end
            end,
        },
        -- Program-keyed patterns to match for prompt start and continuation.
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
        -- Program-keyed help command, often a "?" prefix.
        -- For each program provide either a help command prefix string, a two element array with prefix and suffix,
        -- or a key-value table where each key will be matched against the last prompt (from first to last key).
        -- E.g. julia uses ? for builtin help, but with TerminalPager @help is better for long help pages.
        help = {
            -- TODO: this shouldn't be default as it assumes TerminalPager is installed.
            julia = { ["pager??>"] = "", ["pager>"] = "?", ["help??>"] = "", [">"] = "@help " },
            radian = "?",
            r = "?",
            ipython = "?",
            python = { "help(", ")" },
            pymol = "help ", -- "?" is a syntax error in pymol
            lua = "", -- no help available
        },
    },
}

M.match.detect.zsh = M.match.detect.sh
M.match.detect.bash = M.match.detect.sh

return M
