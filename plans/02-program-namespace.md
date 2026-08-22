# 02 — One program-name namespace

**Goal:** make a REPL's name mean the same thing however it was attached.
**Depends on:** 01. **Blocks:** 04, 09.
**Reads:** `design.md` § REPL identity, § Config keying axes.

This task fixes a live, user-visible bug. Land it before the registry refactor so
the fix is in even if the refactor stalls.

## The bug

radian gets opposite paste behaviour depending on attach path:

- Launched via `commands.new` → `vim.b.repl_cmd = "radian"` (`commands.lua:81`) →
  `config.bracketed.radian == true` → `send_bracketed`.
- Detected via `config.match.detect.r` (`config.lua:113-115`) → `"r"` →
  `bracketed.r == false`, `linewise.r` nil → `send_raw`.

So multiline R code reaches radian unbracketed and radian re-indents it. Single
-line sends are identical on both paths, which is why it survives unnoticed.

The same split breaks scrollback recall: `config.match.prompt`
(`config.lua:127-137`) holds both `radian = { "> ", "  " }` and
`r = { "> ", "+ " }`, so a detect-attached radian parses its scrollback with R's
`+ ` continuation pattern and `[r` truncates multi-line entries.

## Do

**`config.match.detect.r` returns `"radian"` for radian**, and `"r"` only for a
real `R` binary. `config.bracketed.radian`/`.r` and `match.prompt.radian`/`.r`
then mean what they say.

**Re-verify `config.bracketed.r = false`** against a real stock `R` session. It
has only ever been exercised via radian, so its value is unevidenced.

**Key `match.help` by program, not filetype.** `commands.lua:16` reads
`config.match.help[vim.bo.filetype]`, but `config.lua:142-150` holds `radian` and
`ipython` entries and its comment says "Help command by REPL command". No buffer
has filetype `radian` or `ipython`, so those entries are unreachable and a python
buffer driving ipython gets `help(x)` instead of `x?`.

**Add the key-axis comment block** to `config.lua` — see `design.md` § Config
keying axes. If task 03 has already landed, include its `iterate` table on the
filetype axis.

## Test

Add `tests/plenary/detect_spec.lua` covering every `config.match.detect.*`
function against real `kitty @ ls` cmdline and title shapes. They are already pure
`(cmdline, title) -> name|nil` functions and need no kitty. Capture real shapes
with `kitty @ ls` rather than inventing them.

## Verify

- `make test` passes
- Send a multi-line block to a radian REPL attached via `<leader>rr` — it arrives
  bracketed and correctly indented
- `[r` in that session recalls multi-line entries without truncating
- `<leader>K` in a python buffer driving ipython produces `x?`, not `help(x)`

## Behaviour changes reaching the owner's config

All three verification points above are changes to live behaviour. The radian one
interacts with the `TODO.md` note on `radian.indent_lines`/`auto_indentation` —
read it, it is the same failure from the other side. The help change is a
muscle-memory change. Julia is unaffected: identity and filetype coincide.

## Out of scope

Deleting `vim.b.repl_cmd` or introducing the registry — that is 04. This task only
makes the *values* consistent.
