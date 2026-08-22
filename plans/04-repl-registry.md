# 04 — REPL registry; delete `vim.b.repl_cmd`

**Goal:** move REPL identity off the buffer and onto the window, behind one
choke point.
**Depends on:** 02, and 03 if it is being done (see § Ordering).
**Blocks:** 09.
**Reads:** `design.md` § REPL identity.

This is the invasive one. Let `commands.lua` stop moving before starting it.

## The problem

`vim.b.repl_cmd` names the program in a kitty window but is written from five
sites with four meanings:

| Site | Value it writes |
|---|---|
| `commands.lua:81` | launch command, lowercased |
| `commands.lua:102` | filetype, `setLast` fallback |
| `detect.lua:24` | filetype, no detect config |
| `detect.lua:56` | whole joined cmdline |
| `detect.lua:62` | `match.detect` return |

`commands.set` (`commands.lua:91`) and `setI` (`commands.lua:86`) write no
identity at all — they assign only `repl_win`. Two of three attach paths therefore
leave identity stale or nil.

Identity is also stored on the wrong object: it describes a window but lives per
buffer, so two buffers pointing at window 5 can disagree indefinitely.

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

**Also fix `setLast` binding to your own nvim window.** `commands.lua:96-104`
assigns `active_window_history[#history]` unconditionally. `detect_REPL` guards
`win.is_self` and `cmdline[1] ~= "nvim"` (`detect.lua:53`), but on failure
`setLast` keeps the bad `repl_win` and falls back to the filetype — so
`<leader>rr` pressed in the wrong order sends code into a second nvim. Refuse
self/nvim windows.

## Verify

- `make test` passes
- Launch radian with `<leader>rs`, then attach a second buffer to the same window
  with `<leader>rr` — both report the same identity and both send bracketed
- `<leader>rr` with another nvim as the last active window refuses instead of
  binding
- `set`/`setI` produce a working REPL with correct paste behaviour, where before
  they left identity nil

## Ordering

Task 03 (iterate) rewrites different functions in the same file. Run it before
this task so `commands.lua` has stopped moving. 03 does not touch identity or
transport, so nothing in it depends on the outcome here.

## Out of scope

The transport seam and explicit `win` parameters (05). The pager probe (06).
