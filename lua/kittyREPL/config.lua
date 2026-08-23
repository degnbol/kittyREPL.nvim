-- Default configuration for kittyREPL
--
-- The per-language tables below are keyed on one of two axes. Which one is not
-- visible at a call site, so it is recorded per table:
-- * filetype, i.e. the file being edited:
--   exclude, command, command_count, iterate, programs
-- * program, i.e. what runs in the REPL window:
--   bracketed, linewise, custom, match.prompt, match.help
-- programs bridges the two: it is keyed by filetype and its values are program
-- names. A program name and a filetype coincide for some languages (julia, lua)
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
    -- Filetype-keyed sets of the program names a filetype accepts as its REPL,
    -- used to find a REPL window automatically. Union of the values is also the
    -- closed set of names identity resolution can return, so a window running
    -- something no filetype claims stays unnamed rather than being mislabelled.
    -- Resolution strips a version tail, so a name is "python", never "python3",
    -- and a program whose own name ends in a digit cannot be matched.
    programs = {
        python = { python = true, ipython = true, pymol = true },
        r      = { r = true, radian = true },
        julia  = { julia = true },
        pymol  = { pymol = true },
        lua    = { lua = true },
        sh     = { sh = true, zsh = true, bash = true },
    },
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

M.programs.zsh = M.programs.sh
M.programs.bash = M.programs.sh

return M
