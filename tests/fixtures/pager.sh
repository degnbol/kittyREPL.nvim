#!/usr/bin/env zsh
# Screens as `kitty @ get-text --extent=screen --add-cursor` returns them, for
# the is_pager spec. Needs a running kitty with remote control enabled, julia
# with TerminalPager, and less.
set -euo pipefail
cd ${0:A:h}
mkdir -p pager

send() { kitty @ send-text --match=id:$win "$1" }
capture() { kitty @ get-text --match=id:$win --extent=screen --add-cursor > pager/$1.txt }

# poll rather than sleep: julia startup and pager redraws are slow and variable
waitfor() {
    for _ in {1..60}; do
        kitty @ get-text --match=id:$win --extent=screen | grep -qE "$1" && return
        sleep 1
    done
    print -u2 "kittyREPL: window $win never matched /$1/"
    exit 1
}

win=$(kitty @ launch --cwd=/tmp --keep-focus julia)
waitfor '❯'
send '@help print
'
waitfor '^:.*[0-9]+%$'
capture terminalpager-mid
send G
waitfor '100%$'
capture terminalpager-end
send q
waitfor '❯ *$'
capture julia-prompt
kitty @ close-window --match=id:$win

win=$(kitty @ launch --cwd=/tmp --keep-focus)
waitfor '❯'
send 'seq 1 100 | less
'
waitfor '^:'
capture less-top
send G
waitfor '^\(END\)'
capture less-end
send q

# -X keeps less out of the alternate screen, so quitting leaves the paged text
# on screen with the shell prompt over the pager's own last line
send 'seq 1 100 | less -X
'
waitfor '^:'
send ' q'
waitfor '❯ *$'
capture less-noalt-quit
kitty @ close-window --match=id:$win
