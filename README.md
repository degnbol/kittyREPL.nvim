# kittyREPL
Neovim plugin for interacting with a REPL in a separate kitty window.

It can also be made to work on remotes both with the REPL running locally or on 
the remote. This can be achieved by editing files with `edit-in-kitty` which 
edits the file locally under the hood. `edit-in-kitty` can be made available on 
the remote by connected with `kitty +kitten ssh` instead of `ssh`.

Not keys are bound by default. Example install and config with lazy.nvim:
```lua
{
    "degnbol/kittyREPL.nvim",
    opts={
        keymap={
            focus="<C-CR>",
            setlast="<leader>rr",
            new="<leader>rs",
            run="<CR>",
            paste="<S-CR>",
            help="<leader>K",
            runLine="<CR><CR>",
            pasteLine="<S-CR><S-CR>",
            runVisual="<CR>",
            pasteVisual="<S-CR>",
            q="<leader>rq",
            cr="<leader>r<S-CR>",
            ctrld="<leader>rd",
            ctrlc="<leader>rc",
            interrupt="<leader>rk",
            scrollStart="[r",
            scrollUp="[r",
            scrollDown="]r",
            progress="<leader>rp",
            editPaste="<leader>re",
        },
        exclude = {tex=true, text=true, tsv=true, markdown=true},
        progress = true,
        editpaste = true,
    },
},
```
```
```
