#!/usr/bin/env zsh
# USAGE: pipe STDIN into `./kittyPaste.sh KITTY_WINDOW_ID`
# bracketed paste escape sequences.
cat <(echo -n $'\e[200~') - <(echo $'\e[201~') | kitty @ send-text --stdin --match id:$1
