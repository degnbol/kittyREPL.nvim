#!/usr/bin/env zsh
# USAGE: pipe STDIN into `./kittyPaste.sh KITTY_WINDOW_ID`
# or `./kittyPaste.sh KITTY_WINDOW_ID "\n"` to add a newline after the bracketed paste to make sure it gets run.
# bracketed paste escape sequences.
cat <(echo -n $'\e[200~') - <(echo -n $'\e[201~'$2) | kitty @ send-text --stdin --match id:$1
