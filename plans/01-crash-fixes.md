# 01 — Crash fixes and dead code

**Goal:** stop the plugin erroring on reachable paths; delete what has no callers.
**Depends on:** 00. **Blocks:** 02.

No refactor. No behaviour change beyond "stops erroring".

## Do

**`commands.lua:78` — `commands.new` throws for any filetype without a
`config.command` entry.** `ftcommand` defaults to `""` (`commands.lua:67`, despite
the comment claiming zsh), so `ftcommand:match("[^ ]+")` is nil and the title
concat throws. The window is already launched by then, so the result is an orphan
kitty window plus a stack trace. Reachable for every filetype absent from
`config.command` — including the shells that `match.detect.sh` and the
history-scrollback support target.

Derive the title safely and pick a real default command. Prefer launching the
user's default shell, titled `shell id=N`, over the current claim about zsh.

**`config.lua:117-119` — delete the julia branch from `match.detect.r`.** It ends
with `if title:match("[%w.]+$") == "julia" then return "julia" end`, so an R buffer
next to a julia window — or an ssh window titled `host: julia` — auto-attaches to
julia and gets julia's paste path.

(Note for context, do not fix here: `match.detect.julia` at `config.lua:80-86`
conversely takes `title` and never uses it, despite the comment at `config.lua:69`
promising title-based detection over ssh.)

**`scrollback.lua:100` — guard a missing prompt entry.**
`unpack(config.match.prompt[vim.b.repl_cmd])` throws when identity has no
`match.prompt` entry. Reading a table with a nil key is legal, so this is
`unpack(nil)`. Reachable from `commands.set`/`setI` (which never set identity) and
from the `setLast` filetype fallback (`commands.lua:102`). Guard and `vim.notify`.

**`scrollback.lua:178` — same class.** `M.scroll` can return nil and
`vim.fn.setreg("k", nil)` throws.

**`detect.lua:56-58` — set `vim.b.repl_win`.** This branch sets identity and
returns a window id without setting `repl_win`, unlike the sibling at
`detect.lua:62-64` which sets both. Currently benign only because its one caller
(`setLast`) assigned it first.

**Delete dead code:**
- `kitty.get_repl_win` (`kitty.lua:40-54`) — reads `vim.b.repl_id`, which is
  assigned nowhere in the repo; no callers; always returns nil.
- `scrollback.get_index` (`scrollback.lua:185`) — no callers, including in specs.
- The four back-compat globals at `init.lua:37-40` (`ReplNew`, `ReplSetI`,
  `ReplToggleProgress`, `ReplToggleEditPaste`) — referenced nowhere in
  `~/dotfiles/config/nvim`.

**Keep** the two operator globals at `init.lua:27-33` — `v:lua` operatorfunc
requires them.

**`scrollback.lua:78` — drop the `tail` subprocess.** Replace
`io.popen("tail -n 500 …")` with `vim.fn.readfile(path, "", -500)`; a negative
`{max}` returns that many lines from the end. This removes the only non-kitty
subprocess in the plugin and makes `readHistory` testable with no seam.

## Verify

- `make test` passes
- `<leader>rs` in a `sh` buffer opens a working window instead of erroring, and
  leaves no orphan window
- `[r` in a buffer whose REPL was attached via `set` notifies instead of throwing
- Add a spec for `readHistory` beside the existing `parseHistoryText` one

## Out of scope

Identity normalisation (02), the registry (04), anything in
`runLineFor`/`runLineForI` (03).
