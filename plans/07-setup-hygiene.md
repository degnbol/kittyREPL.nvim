# 07 — `setup()` hygiene

**Goal:** stop `setup()` clobbering user config and mutating shared tables.
**Depends on:** 05 (for the `custom` signature change). **Blocks:** nothing.

## Do

**Move `config.custom.pymol/lua/julia` into `config.lua` as ordinary defaults.**
`init.lua:57-75` assigns them unconditionally *after* merging user config, so a
user-supplied `custom.pymol` is silently overwritten.

They live in `setup()` only because they close over `kitty`. After 05 they take
`(win, text, post)` and must `require("kittyREPL.kitty")` **inside the function
body** — `kitty` requires `config`, so a top-level require in `config.lua` is a
cycle.

**Move the prompt `^`-anchoring out of `setup()`.** `init.lua:78-83` rewrites every
`config.match.prompt` pattern in place to add a `()` position capture that
`scrollback.lua:107-108` depends on. Consequences: the config module misrepresents
its own contents; a `match.prompt` entry added after `setup()` crashes rather than
mismatches; and the `^%^` guard at `init.lua:79` exists only to stop a second
`setup()` double-anchoring.

Anchor at the use site in `parseScrollback` with a memo table. That removes the
mutation, the re-entrancy guard and the setup-ordering dependency together.

**Convert the remaining `print` diagnostics to `vim.notify`** with appropriate
levels — re-derive them with `grep -n 'print(' lua/kittyREPL/*.lua`; tasks 03 and
04 converted some of them already.
`print` from a keymap callback is clobbered by the next message, and 09 adds
`vim.notify` error paths that would otherwise sit inconsistently beside these.

If task 03 has landed it will have added its own `vim.notify` calls — leave those
alone, they are already correct.

## Verify

- `make test` passes
- Call `setup()` twice in a scratch config; prompt patterns behave identically and
  no pattern is double-anchored
- Pass `custom = { pymol = <your own fn> }` to `setup()` and confirm it survives
- `[r` scrollback recall still works for julia, ipython and radian

## Out of scope

Anything about identity or transport.
