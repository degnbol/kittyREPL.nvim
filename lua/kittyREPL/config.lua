-- Default configuration for kittyREPL
--
-- The per-language tables below are keyed on one of two axes. Which one is not
-- visible at a call site, so it is recorded per table:
-- * filetype, i.e. the file being edited:
--   exclude, command, command_count, iterate, programs
-- * program, i.e. what runs in the REPL window:
--   bracketed, linewise, custom, context, variables, assign, match.prompt,
--   match.help
-- programs bridges the two: it is keyed by filetype and its values are program
-- names. A program name and a filetype coincide for some languages (julia, lua)
-- and differ for others (an r buffer drives radian).

-- kitty.lua requires this module, so the senders in `custom` resolve it at call
-- time; a top-level require here would be a cycle.
local function kitty()
    return require("kittyREPL.kitty")
end

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
    -- Program-keyed functions for how to send code to the REPL.
    -- Args: win, text, post, where post is either '' or '\n'.
    custom = {
        pymol = function(win, text, post)
            -- wrap multiline in python .. python end
            -- https://pymolwiki.org/index.php/PythonTerminal
            if text:match('\n') then
                kitty().send_raw(win, "python\n" .. text:gsub("\n*$", "") .. "\npython end" .. post)
            else
                kitty().send_raw(win, text .. post)
            end
        end,
        lua = function(win, text, post)
            -- top level locals are ignored in REPL so we strip that.
            kitty().send_raw(win, text:gsub("^local ", ""):gsub("\nlocal ", "\n") .. post)
        end,
        julia = function(win, text, post)
            -- Fixed a huge problem, super weird, julia was insanely slow typing one char at a time.
            -- I realised it was because even though we set it to use bracketed it only sends it bracketed with multiline.
            -- Solution here: always send bracketed.
            kitty().send_bracketed(win, text, post)
        end,
    },
    -- Program-keyed hooks for REPL-side state that should track nvim-side
    -- state. Each returns a line of code, or nil or "" to contribute nothing --
    -- an empty line would otherwise be sent as a bare newline. A line is sent
    -- when its text differs from what that window was last told. That
    -- covers once-per-REPL setup ("using Revise", constant forever after) and
    -- change tracking (a cwd, resent when it changes) with no event model.
    context = {},
    -- Program-keyed values to keep assigned, the common case of context. Each
    -- returns the string to assign, or nil to assign nothing.
    variables = {
        ipython = {
            __file__ = function()
                local name = vim.api.nvim_buf_get_name(0)
                -- A sentinel rather than nil, which would leave the previous
                -- buffer's path assigned. The basename is also what makes
                -- multiprocessing.spawn._fixup_main_from_path short-circuit
                -- instead of re-running the file in every spawned child, so a
                -- real path here means workers execute that file's top level,
                -- as running it as a script would.
                return name ~= "" and name or "ipython"
            end,
        },
    },
    -- Program-keyed assignment syntax for `variables`, taking a name and the
    -- raw value. Without an entry the value is quoted as a string literal:
    -- `name = "value"`, which a shell would need spelled without the spaces.
    assign = {},
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
        -- spelled out per shell rather than aliased to one table, so that a user
        -- overriding one of them does not leave the others pointing at the
        -- pre-merge set
        sh     = { sh = true, zsh = true, bash = true },
        zsh    = { sh = true, zsh = true, bash = true },
        bash   = { sh = true, zsh = true, bash = true },
    },
    -- command to execute in new kitty window. Split on whitespace into argv, not
    -- run through a shell, so ~, $VAR, globs and quoting are all literal.
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

return M
