# kittyREPL
Neovim plugin for interacting with a REPL in a separate kitty window.

It can also be made to work on remotes both with the REPL running locally or on 
the remote. This can be achieved by editing files with `edit-in-kitty` which 
edits the file locally under the hood. `edit-in-kitty` can be made available on 
the remote by connected with `kitty +kitten ssh` instead of `ssh`.

