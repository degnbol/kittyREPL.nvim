#!/usr/bin/env zsh
# USAGE: pipe STDIN into `./kittyPaste.sh KITTY_WINDOW_ID`
# bracketed paste escape sequences.
# Doesn't run the paste code, end STDIN with newline to do so.
cat <(echo -n $'\e[200~') - <(echo -n $'\e[201~') | kitty @ send-text --stdin --match id:$1
