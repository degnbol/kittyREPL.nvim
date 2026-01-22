-- Default configuration for kittyREPL
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
    -- not all REPLs support bracketed paste.
    -- stock python repl is particularly bad. It doesn't support bracketed, it
    -- can't handle empty line within indentation, it doesn't understand the
    -- SOH code.
    bracketed = { ipython = true, python = false, radian = true, r = false, julia = true, pymol = false, pml = false },
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
    -- language specific matching
    match = {
        -- kitty @ ls foreground_processes cmdline value to recognize for auto finding REPL for the buffer.
        -- over SSH the foreground_processes.cmdline will simply be ["ssh", ...] so we also detect using title
        -- filetype -> function(cmdline, title) -> nil or REPL name
        detect = {
            julia = function(cmdline, title)
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
                -- ["/opt/homebrew/.../pymol/__init__.py"] -> pymol
                if cmdline[2] and cmdline[2]:match("/pymol/__init__.py$") then
                    return "pymol"
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
            r = function(cmdline, title)
                if not cmdline or not cmdline[1] then return end
                -- [".../R"] -> r
                if cmdline[1]:match("[%w.]+$") == "R" then
                    return "r"
                end
                -- ["../Python", ".../radian"] -> r
                if cmdline[2] and cmdline[2]:match("[%w.]+$") == "radian" then
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

return M
