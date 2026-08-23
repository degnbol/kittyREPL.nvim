# 05 — Transport seam

**Goal:** make `kitty.lua` explicit about its window and testable without kitty.
**Depends on:** 04. **Blocks:** 06, and wanted by 09.
**Reads:** `design.md` § Transport, § Testing.

## Do

**Explicit window id on every `kitty.lua` function** — `kitty.send_raw(win, text)`,
`kitty.get_scrollback(win)`, and so on — replacing the seven sites in `kitty.lua`
that read `vim.b.repl_win`. Callers hold the id already: task 04 put the
`repl.current()` lookup in the `run`/`paste` wrappers in `commands.lua` and in
`scrollback`'s two entry points.

**One subprocess helper** on `vim.system`:

```lua
M._exec = function(argv, stdin)  -- returns { code, stdout, stderr }
```

Route all 11 `io.popen`/`os.execute` calls through it. argv tables, no shell, no
string concatenation into a command line, real exit codes, and stderr no longer
discarded by `2>/dev/null` (`kitty.lua:14`).

Watch the exit-code semantics change — `design.md` § Transport, `os.execute`
semantics. The `== 0` checks in `kitty.exists` and `kitty.interrupt` must become
`:wait().code`; keeping `== 0` against a `vim.SystemCompleted` makes
`kitty.exists` always false.

`kitty.launch` still needs word splitting for user-authored `config.command`
strings — `vim.split` on whitespace, not `sh`.

**Delete `kitty.exists(win)` in favour of `kitty.window(win)`**, which task 04
added: the `ls --match id:` record it returns is empty for a dead window, so it is
a drop-in existence check, and the same record supplies `foreground_processes` for
identity resolution and `in_alternate_screen` for 06.

This takes one `<CR>` from three kitty round-trips to two: `replCheck`'s existence
check currently throws away everything it fetched, and `repl.attach` then fetches
the same record again. Round-trips cost ~21 ms each and `ls --match` is no cheaper
than `get-text --match`, so justify this by the identity it returns in the same
trip, not by speed.

## Test

Add `tests/plenary/send_spec.lua` with a fake `_exec`, asserting:

- dispatch precedence: `custom` > `bracketed` > `linewise` > raw
- the exact bracketed byte sequence, including the `\x1b[200~` / `\x1b[201~`
  wrapping and the `post` handling
- linewise splitting skips empty lines and still sends `post`

## Verify

- `make test` passes
- Send single-line and multi-line blocks to ipython, julia, radian and pymol —
  each still arrives correctly
- Kill a REPL window, then send: "No REPL" instead of a hang or a stack trace

## Out of scope

The pager probe stays where it is; 06 moves it.
