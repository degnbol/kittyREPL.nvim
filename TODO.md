# TODO

## Planned work

Each file in `plans/` is one isolated task. `plans/design.md` holds the
cross-cutting decisions the tasks refer to; read the sections a task cites.

Run in this order. Numbering is the intended sequence, not a hard dependency
chain — each plan states its own dependencies.

| | Task | Depends on |
|---|---|---|
| 00 ✓ | Commit the working tree | — |
| 01 ✓ | Crash fixes and dead code | 00 |
| 02 ✓ | [One program-name namespace](plans/02-program-namespace.md) | 01 |
| 03 ✓ | [Treesitter loop-variable extraction](plans/03-iterate-treesitter.md) | 01 |
| 04 ✓ | [REPL registry](plans/04-repl-registry.md) | 02, 03 |
| 05 ✓ | [Transport seam](plans/05-transport-seam.md) | 04 |
| 06 ✓ | [Pager probe](plans/06-pager-probe.md) | 05 |
| 07 ✓ | [`setup()` hygiene](plans/07-setup-hygiene.md) | 05 |
| 08 ✓ | [README](plans/08-readme.md) | 02, 04, 05, 07 |
| 09 ✓ | [REPL context sync](plans/09-context-sync.md) | 02, 04 |
| 10 ✓ | [Launch environment](plans/10-launch-env.md) | — |
| 11 ✓ | [Runtime prompt detection](plans/11-prompt-detection.md) | 04, 05 |

02 fixes a live radian paste bug on its own — land it early even if the rest
stalls. 03 is self-contained; running it before 04 keeps `commands.lua` still
while the registry lands. 11 deletes `config.match.prompt`, which fixes `[r`/`]r`
in radian and julia.

Follow up:
`kitty._exec` is the one `vim.system` wrapper (`plans/design.md` § Transport), but
`history.lua` now uses it to run `sqlite3`, with a lazy require to dodge the
config -> kitty cycle. Moving it to `util.lua` would drop both the oddity and the
laziness, at the cost of updating the four specs that stub it and the design note
that puts it in `kitty.lua`.

## Unplanned

Paste correct indentation with awareness of radian's own indentation settings —
`radian.indent_lines`, `radian.auto_indentation`.
https://github.com/randy3k/radian
Interacts with task 02, which changes radian's paste path to bracketed.

Make operator suffixes like `<CR>ap` a no-op when there's no REPL attached. Currently `<CR>` reports "No REPL" and the `ap`
motion still fires.

`vim.cmd` has hl injection in the string but this is missing for `cmd = vim.cmd`.
We should probably use the full form `vim.cmd` so we get the syntax hl.

Maybe extend to the ghostty terminal.
