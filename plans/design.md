# Cross-cutting design

Shared decisions the numbered task plans refer to. Read the parts your task
cites; you do not need the whole file.

## REPL identity

A REPL's identity is the **program name** running in a kitty window, from a
closed set: `ipython, python, julia, radian, r, pymol, pml, lua, zsh, bash, sh`.

Identity is a property of the **window**, not of the buffer. One REPL serves many
buffers; two buffers targeting window 5 must agree on what runs there.

The buffer→window binding *is* per-buffer — two files may target two REPLs — so
`vim.b.repl_win` stays. `vim.b.repl_cmd` goes away.

### Registry: `lua/kittyREPL/repl.lua`

```lua
local wins = {}   -- [win] = { program = "radian", pending = "radian"|nil, sent = {} }

M.attach(win, hint)  -- bind buffer -> win, cache identity, returns win|nil
M.resolve(window)    -- `kitty @ ls` record -> program name|nil. Pure; the tested unit
M.revalidate()       -- binding still usable? refreshes identity from the same record
M.program(win)       -- cached program name, resolving lazily on first use
M.win()              -- -> win|nil
M.current()          -- -> win|nil, program|nil
```

`attach` returns the window rather than the program name, since a bound window
with an unresolved program is a success and nil identity is a legitimate value.

**Cache only successful resolutions.** A REPL busy with a subprocess resolves to
its subprocess or to nothing, so caching a nil would leave the window unnamed —
and silently raw-sending — for the rest of the session. An entry is therefore
replaced when identity is learned, and there is no `forget` until there is state
worth clearing on its own.

Every attach path routes through `repl.attach`: `new`, `set`, `setI`, `setLast`,
and auto-detect from `replCheck`.

Prefer this over funnelling writes through a single setter for `vim.b.repl_cmd`.
A setter fixes the multiple-writers problem but leaves identity buffer-scoped, and
leaves per-window state (the context-sync memo) with nowhere to live but a second
module-level table keyed the same way.

**Launch race.** `kitty @ launch` returns before the program appears in
`foreground_processes`, so identity cannot be resolved at launch. Pass the launch
word as `hint`, store as `pending`, and let `repl.cmd(win)` re-resolve from
`kitty @ ls --match id:` on first use and promote the result — keeping the hint
only if detection returns nil.

**Key per-window state on window id, not pid.** Pid-keying would additionally
catch "REPL exited and restarted inside one window", but `foreground_processes[]`
is a list whose last element shifts for benign reasons — `repl.lua`'s `cmdline`
documents PlotlyJS spawning helpers mid-session — so it fires spurious
invalidations. The stable window-level `pid` tracks the shell kitty spawned, not
the program. Re-attaching is the invalidation.

**A nil identity is safe to send with, not to read scrollback with.** Unresolved
identity makes `custom`/`bracketed`/`linewise` miss and `kitty.send` fall through
to `send_raw`, the conservative default. Scrollback throws instead until task 01
guards it.

## Config keying axes

Two axes, both legitimate, indistinguishable at a call site. Record which is which
in a `config.lua` header comment.

- **filetype-keyed** — chosen from the file being edited: `exclude`, `command`,
  `command_count`, `programs`, `iterate`
- **program-keyed** — chosen from what is running: `bracketed`, `linewise`,
  `custom`, `match.prompt`, `match.help`, `context`, `variables`, `assign`

## Transport

Every `kitty.lua` function takes an explicit window id (`kitty.send_raw(win, text)`,
`kitty.get_scrollback(win)`, …) rather than reading `vim.b.repl_win` at 11 sites.
This is the precondition for testing the send path and for context sync targeting a
specific window.

All subprocess use funnels through one private helper on `vim.system`:

```lua
M._exec = function(argv, stdin)  -- returns { code, stdout, stderr }
```

argv tables, no shell, no string concatenation into a command line, real exit
codes, and stderr no longer discarded by `2>/dev/null` (`kitty.lua:14`). `M._exec`
is the swap point for tests.

`kitty.launch` still needs word splitting, because `config.command` values are
user-authored strings — use `vim.split` on whitespace rather than handing them to
`sh`.

**`os.execute` semantics.** Under nvim 0.12.4's LuaJIT these are Lua 5.1:
`os.execute("true")` is `0`, `os.execute("false")` is `256`. The `== 0` checks in
`kitty.exists` and `kitty.interrupt` are correct today and must become
`:wait().code` in the port — keeping `== 0` against a `vim.SystemCompleted` makes
`kitty.exists` always false.

**Do not add a `send.lua`.** `kitty.send`'s dispatch across
`custom`/`bracketed`/`linewise` is knowledge about how each program consumes text
and belongs with the transport. Relocating the pager probe needs no module to live
in — the `run`/`paste` wrappers in `commands.lua` are its home.

## Testing

**No kitty and no seam needed:** `repl.resolve`;
`parseHistoryText`; `parseScrollback` once it takes text as a parameter instead of
reading a module global; `readHistory` after task 01; `is_pager` after task 06;
`replHelpCmd`'s dispatch given injected scrollback text.

**Seam needed:** `kitty.send` dispatch, `repl.attach`, `replCheck`.

Introduce the `_exec` seam (task 05); do not build a fake kitty. A fixture-driven
fake `kitty @` that models window lifecycle and focus history is more code than
the module it tests, encodes JSON assumptions only a live kitty can validate, and
loses most of its value once identity resolution moves into `repl.lua`. Test the
pure resolution function against captured JSON fixtures; verify window-walking by
hand.

## Owner's live config

`~/dotfiles/config/nvim/lua/plugins/ui.lua:8-38` — `keymap`,
`exclude = { tex, tsv, markdown }`, `progress = true`, `editpaste = true`,
`closepager = true`. No `bracketed`/`command`/`match` overrides, so no config-key
change can break it. Behaviour changes that reach this config are called out in
the task plans that cause them.
