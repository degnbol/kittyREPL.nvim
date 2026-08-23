# 04 — REPL registry; delete `vim.b.repl_cmd`

**Goal:** move REPL identity off the buffer and onto the window, behind one
choke point.
**Depends on:** 02, and 03 if it is being done (see § Ordering).
**Blocks:** 09.
**Reads:** `design.md` § REPL identity.

This is the invasive one. Let `commands.lua` stop moving before starting it.

## The problem

`vim.b.repl_cmd` names the program in a kitty window but is written from four
sites with three meanings:

| Site | Value it writes |
|---|---|
| `commands.lua:82` | launch command, lowercased |
| `commands.lua:90` | nil, clearing the previous window's identity |
| `detect.lua:55` | `cmdline[1]` basename, no detect config |
| `detect.lua:62` | `match.detect` return |

Identity is stored on the wrong object: it describes a window but lives per
buffer, so two buffers pointing at window 5 can disagree indefinitely.

02 made the values agree across attach paths and routed `set`/`setI`/`setLast`
through one local `attach` (`commands.lua:87`), which is the seam `repl.attach`
replaces. What it could not fix is the split above: `commands.new` names the
program from the command string, detection names it from the cmdline, and neither
can see the other's answer.

## Do

Create `lua/kittyREPL/repl.lua` with the shape in `design.md` § REPL identity, and
route `new`, `set`, `setI`, `setLast` and `replCheck`'s auto-detect through
`repl.attach`.

`detect.detect_REPL` keeps window scanning and delegates naming. `kitty.send` and
`scrollback` take identity as an argument instead of reading `vim.b`.

Include the `pending`-hint lazy resolution — `design.md` § Launch race. This is
what makes `new` and `setLast` agree about radian.

Delete `vim.b.repl_cmd`. Nothing outside the plugin reads it: no statusline
component, no `<plug>` map, nothing in `~/dotfiles/config/nvim`. Check personal
snippets or ftplugin that a grep would not cover before removing.

**Also fix `setLast` binding to your own nvim window.** `commands.lua:108-113`
assigns `active_window_history[#history]` unconditionally. `detect_REPL` guards
`win.is_self` and `cmdline[1] ~= "nvim"` (`detect.lua:51`), but on failure
`attach` keeps the bad `repl_win` with a nil identity — so `<leader>rr` pressed in
the wrong order sends code into a second nvim. Refuse self/nvim windows.

## Resolve the program once, then ask who claims it

Split the two questions `config.match.detect.*` currently answers together:
*what program runs in this window* (one function, no filetype) and *does this
filetype claim it* (a per-filetype set of program names). The registry is where
the first belongs, since `repl.cmd(win)` already has to answer it without a
buffer in hand.

This subsumes three special cases that all encode the same shape — an interpreter
in `cmdline[1]`, the real program named by `cmdline[2]`:

| cmdline | program | handled today in |
|---|---|---|
| `[python3, .../radian]` | radian | `detect.r` |
| `[python3, .../ipython]` | ipython | `detect.python` |
| `[python, .../pymol/__init__.py, -xpq]` | pymol | `detect.python` |

Keeping them per-filetype means the same window gets two names depending on who
asks — `detect.python` on a radian window returns `python`, so a python buffer
claims it and sends stock-python linewise. That is 02's bug reached through the
other filetype, and each further python-launched REPL (jupyter console, ptpython,
bpython) adds another arm.

Four cases a basename rule gets wrong, so resolution needs its own tests:
pymol's entrypoint basename is `__init__.py`, not `pymol`; `ipython3` and
`python3` need the version suffix dropped; `-i`/`-m` sit where an entrypoint path
is expected; and `python3 train.py` resolves to `train`, which no config table
knows. Returning nil for that last one is better than today's `python` — decide
it explicitly, because it stops such a window being claimable at all.

## Test

Program resolution is pure — take the `kitty @ ls` window record, so the
"which foreground process" rule is covered too — and keeps the fixtures of
`tests/plenary/detect_spec.lua`, which are real `kitty @ ls` values. Extend them
with the four cases above rather than starting a second spec, and rename the file
after the module it now tests. Per-filetype claiming is a table lookup and needs
no test of its own; `attach`'s refusals and the `pending` promotion need only a
stubbed `kitty.window`.

## Verify

- `make test` passes
- Launch radian with `<leader>rs`, then attach a second buffer to the same window
  with `<leader>rr` — both report the same identity and both send bracketed
- `<leader>rr` from a python buffer with a radian window on the tab declines it
  instead of claiming it as stock python
- `<leader>rr` with another nvim as the last active window refuses instead of
  binding
- `set`/`setI` produce a working REPL with correct paste behaviour

## Ordering

Task 03 (iterate) rewrites different functions in the same file. Run it before
this task so `commands.lua` has stopped moving. 03 does not touch identity or
transport, so nothing in it depends on the outcome here.

## Out of scope

The transport seam and explicit `win` parameters (05). The pager probe (06).
