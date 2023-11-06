# kittyREPL
Neovim plugin for interacting with a REPL in a separate kitty window.
Mostly tested with Julia, IPython, radian, and lua but can be extended.

It can also be made to work on remotes both with the REPL running locally or on 
the remote. This can be achieved by editing files with `edit-in-kitty` which 
edits the file locally under the hood. `edit-in-kitty` can be made available on 
the remote by connected with `kitty +kitten ssh` instead of `ssh`.

No keys are bound by default. Example install and config with lazy.nvim:
```lua
{
    "degnbol/kittyREPL.nvim",
    opts={
        keymap={
            focus="<C-CR>", -- make the REPL window the active kitty window
            setlast="<leader>rr", -- set most recent window as the REPL
            new="<leader>rs", -- start a new REPL according to filetype
            run="<CR>", -- execute motion in REPL
            paste="<S-CR>", -- send motion to REPL without executing it
            help="<leader>K", -- open help in REPL for word under cursor
            runLine="<CR><CR>", -- execute current line in REPL
            pasteLine="<S-CR><S-CR>", -- send current line to REPL without execution
            runVisual="<CR>", -- execute visual selection in REPL
            pasteVisual="<S-CR>", -- copy visual selection to REPL
            q="<leader>rq", -- press q in REPL
            cr="<leader>r<S-CR>", -- press Enter in REPL
            ctrld="<leader>rd", -- press Ctrl+D in REPL
            ctrlc="<leader>rc", -- press Ctrl+C in REPL
            interrupt="<leader>rk", -- send interrupt signal to REPL
            scrollStart="[r", -- paste last command from REPL into editor
            scrollUp="[r", -- cycle back in history
            scrollDown="]r", -- cycle forward in history
            progress="<leader>rp", -- toggle progress cursor after run/paste
            editPaste="<leader>re", -- toggle focusing REPL after pasting into it
        },
        exclude = {tex=true, text=true, tsv=true, markdown=true},
        progress = true, -- cursor progresses after sending to REPL
        editpaste = true, -- focus the REPL right after pasting to it
        closepager = true, -- default=false
        -- not all REPLs support bracketed paste
        bracketed = { python=true, r=true, julia=true },
        command = { -- command to execute in new kitty window
            python="ipython",
            julia="julia",
            -- kitty command doesn't know where R is since it doesn't have all the env copied.
                r="radian --r-binary /Library/Frameworks/R.framework/Resources/R",
            lua="lua",
        },
        match = { -- language specific matching
            -- kitty @ ls foreground_processes cmdline value to recognize.
            -- Key is literal match string, value is corresponding language.
            cmdline = {
                python3="python",
                ipython="python",
                IPython="python",
                R="r",
                radian="r",
            },
            prompt = { -- patterns to match for prompt start and continuation for each supported REPL program
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
    },
},
    ```

