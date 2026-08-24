#!/usr/bin/env zsh
# Screens, scrollbacks and history files as a live REPL leaves them, for the
# prompt-learning and recall specs. Needs a running kitty with remote control
# enabled and python3, ipython, radian, R, lua, julia, pymol and sqlite3 on PATH,
# plus TerminalPager installed for julia's pager modes.
# Each REPL's history is redirected into a scratch directory, so running this
# does not touch the caller's own history files.
set -euo pipefail
cd ${0:A:h}
mkdir -p repl/prompt repl/scrollback repl/history

scratch=$(mktemp -d)
trap 'rm -rf $scratch' EXIT

launch() { kitty @ launch --type=tab --cwd=$scratch --keep-focus --copy-env "$@" }
send() { kitty @ send-text --match=id:$win "$1" }
# bracketed, so a REPL that auto-indents does not re-indent what it is given
paste() { send $'\e[200~'"$1"$'\e[201~\n' }
screen() { kitty @ get-text --match=id:$win --extent=screen --add-cursor > repl/prompt/$1.txt }
scrollback() { kitty @ get-text --match=id:$win --extent=all > repl/scrollback/$1.txt }
close() { kitty @ close-window --match=id:$win }

# poll rather than sleep: REPL startup is slow and variable
waitfor() {
    for _ in {1..60}; do
        kitty @ get-text --match=id:$win --extent=screen | grep -qE "$1" && return
        sleep 1
    done
    print -ru2 "kittyREPL: window $win never matched /$1/, showing:"
    kitty @ get-text --match=id:$win --extent=screen >&2
    close
    exit 1
}


# `--extent=screen` drops each line's trailing blanks, so no pattern here may
# rely on the space a prompt ends in. `--add-cursor` is what keeps it.

win=$(launch python3)
waitfor '^>>>'
send 'x = 1
def f():
    return 1

f()
'
waitfor '^1$'
screen python
scrollback python
close

win=$(launch --env=IPYTHONDIR=$scratch/ipython ipython)
waitfor '^In \[1\]'
send 'x = 1
x
'
paste 'def f():
    return 1'
# a pasted block leaves the cell open; a blank line is what submits it
send '
f()
'
waitfor 'Out\[4\]: 1'
screen ipython
scrollback ipython
close
sqlite3 -json $scratch/ipython/profile_default/history.sqlite \
    'select source_raw from history order by rowid desc' > repl/history/ipython.json

# radian keeps history beside the session only when the file is already there
# (prompt_session.py:114); without this it appends to the caller's global file
touch $scratch/.radian_history
win=$(launch radian)
waitfor '❯'
send 'x <- 1
'
send ';ls
'
# radian stays in shell mode until a backspace at its empty prompt
waitfor '^!❯$'
send $'\x7f'
paste 'for (i in 1:2) {
    print(i)
}'
waitfor '^\[1\] 2$'
screen radian
scrollback radian
# a half-typed line: the cursor sits after it, so it reads as a prompt candidate
send 'x <- 1 + '
sleep 1
screen radian-typing
close
cp $scratch/.radian_history repl/history/radian_history

win=$(launch R --no-save)
waitfor '^>$'
send 'x <- 1
x
'
waitfor '^\[1\] 1$'
screen r
scrollback r
close

win=$(launch lua)
waitfor '^>$'
send 'x = 1
print(x)
'
waitfor '^1$'
screen lua
scrollback lua
close

win=$(launch --env=JULIA_HISTORY=$scratch/repl_history.jl julia --banner=yes)
waitfor '❯'
# the oldest line of a scrollback is out of reach, and this REPL's own config
# hides the banner that would otherwise take it, so spend a command on it
send 'y = 42
x = 1
'
send ';ls
'
# julia stays in shell mode until a backspace at its empty prompt
waitfor '^! ❯$'
send $'\x7f'
paste 'for i in 1:2
    println(i)
end'
waitfor '^2$'
screen julia
scrollback julia
# nothing renders at column 1 but the cursor while a computation runs
send 'sleep(30)
'
sleep 2
screen julia-busy
send $'\x03'
waitfor '❯'
close
cp $scratch/repl_history.jl repl/history/repl_history.jl

# julia's own mode prompts, which the help command is chosen by. Unlike the
# primary prompt above, these are drawn by julia and TerminalPager rather than
# configured, so a shipped pattern can match them. A window of its own with a
# history file of its own: loading the package is typed at the prompt, so in the
# window above it would land in the history captured from it.
win=$(launch --env=JULIA_HISTORY=$scratch/modes.jl julia --banner=no)
waitfor '❯'
send 'using TerminalPager; println("loaded")
'
waitfor '^loaded$'
send '?'
waitfor '^help\?>$'
screen julia-help
send $'\x7f'
send '|'
waitfor '^pager>$'
screen julia-pager
send '?'
waitfor '^pager\?>$'
screen julia-pager-help
close

# pymol prints no prompt, so its readiness has to be asked for.
# -c leaves out the OpenGL window that -x keeps (-x drops only the control
# panel), and -K is what keeps a GUI-less pymol alive to be read.
win=$(launch pymol -cqpK)
send 'print("ready")
'
waitfor '^ready$'
screen pymol
scrollback pymol
close
