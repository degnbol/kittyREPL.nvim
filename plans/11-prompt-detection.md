# 11 — Learn the prompt at runtime; delete `config.match.prompt`

**Goal:** derive each REPL's prompt from the running window instead of a shipped
guess, and take multi-line recall from the REPL's own history file.
**Depends on:** 04 (per-window state), 05 (`_exec`, explicit `win`,
`kitty.window(win)`).
**Blocks:** nothing. 09 wants it — its settle poll (`09-context-sync.md:132`)
reads the learned prompt instead of `config.match.prompt`.
**Reads:** `design.md` § REPL identity, § Transport, § Config keying axes.

**Verdict: `config.match.prompt` can be deleted.** Every primary prompt is
observable from the running window; every continuation pattern is unneeded once
the three modal REPLs read their own history. What survives is an empty
`config.prompt` override table and a program-keyed table of history *readers* —
code whose correctness a test can check, not strings that can silently be wrong.

## The bug

`config.match.prompt` values are guesses, and both prompts the owner has
customised are wrong — silently, because `parseScrollback` returns nil rather
than throwing:

| entry | shipped | rendered | set in |
|---|---|---|---|
| `radian` | `{ "> ", "  " }` | `R❯ ` | `config/radian/profile:14` |
| `julia` | `{ "%a*%??> ", "  " }` | ` ❯ ` — U+E80D, space, U+276F, space | `config/julia/startup.jl:34` (OhMyREPL) |

Both are user-configurable strings, so no shipped default can be right. `[r`/`]r`
do nothing in the two REPLs the owner uses most.

`pymol = { "", "" }` anchors to `^()` and matches every line, so pymol recall
returns the whole scrollback one line at a time.

`zsh`/`bash`/`sh` are unreachable. `scrollback.read` (`scrollback.lua:87-96`)
fills `tScrollback` from the history file and leaves `scrollback = ""`, so
`parseScrollback`'s first `match` returns nil. Deleting them changes nothing.

That leaves `python`, `r`, `ipython` and `lua` as the only entries that are
correct — verified against captured `--extent=all` output.

`config.match.prompt` has exactly one code consumer, `parseScrollback`
(`scrollback.lua:100-128`).

## Do

### 1. Learn the primary prompt from the cursor position

One `kitty @ get-text --extent=screen --add-cursor` per window. Its output is the
full screen height, blank-padded, followed by a
`\x1b[?25h\x1b[<row>;<col>H\x1b[?12<h|l>` line — 27 lines for a 25-row window — so
`row` indexes the returned lines directly. The plain `--extent=screen` output does
not: it drops trailing blank rows.

- `col == 1` → not at a prompt. Covers a busy REPL (the cursor drops to column 1
  during `Sys.sleep`) and pymol, which renders no prompt at all while waiting for
  input.
- `in_alternate_screen` true on the `ls` record → a pager is open, refuse.
  Measured true for julia + TerminalPager.
- prompt = line `row`, right-padded with spaces to display width `col - 1`. The
  padding is load-bearing: kitty strips a trailing blank cell when the prompt's
  last cell carries an SGR colour, so radian yields `R❯` for a 3-column prompt
  while python, ipython, r, lua and julia keep their trailing space.
- pattern = that string with Lua magic characters escaped, digit runs replaced by
  `%d+`, then wrapped as `"^" .. pat .. "()"`.

Measured, one launch each:

| program | cursor | line at cursor row | learned pattern |
|---|---|---|---|
| python | (4,5) | `>>> ` | `^>>> ()` |
| ipython | (6,9) | `In [1]: ` | `^In %[%d+%]: ()` |
| radian | (4,4) | `R❯` | `^R❯ ()` |
| r | (20,3) | `> ` | `^> ()` |
| lua | (2,3) | `> ` | `^> ()` |
| julia | (1,5) | ` ❯ ` | `^ ❯ ()` |
| pymol | (14,1) | — | refuses |

The `%d+` step is what makes an observed `In [4]: ` match `In [1]: `. nvim's
`strdisplaywidth` agrees with kitty's column count for `R❯`, `In [1]:` and
julia's private-use glyph under `ambiwidth=single`; clamp the pad at zero so a
disagreement costs a trailing space, not an error.

### 2. Verify before caching

Count how many lines of `--extent=all` the pattern matches. Accept at ≥ 2,
otherwise refuse and notify. This is the guard against learning a partly-typed
command: mid-typing the cursor sits after the typed text, so the candidate is
`R❯ xyz = 1 + ` and matches one line.

Notify the accepted value once per window — `kittyREPL: radian prompt "R❯ "`.
That single line is what would have surfaced the radian bug immediately, and it
is the difference between a detection that can be audited and one that fails
silently.

Re-learn when the cached pattern matches zero lines, which is how a mode switch
(`pkg> `, `Browse[1]❯ `, `!❯ `) recovers.

### 3. Cache in the task-04 registry

`wins[win].prompt`, dropped when the window is re-attached. Learn lazily on the first
`scrollback.read`, not at attach: `kitty @ launch` returns before the prompt is
drawn. A refusal must not be cached as a failure.

### 4. Delete `config.match.prompt` and the `init.lua:71-76` rewrite

The learned pattern already carries `^` and the `()` position capture, so
`parseScrollback`'s `lastline:sub(mPrompt)` is unchanged, and plan 07's "move the
prompt anchoring out of `setup()`" is satisfied by deletion. Drop the totality
assertion in `tests/plenary/repl_spec.lua` with it.

Add `config.prompt = {}` — a program-keyed override, empty by default, for a REPL
the observation cannot handle. What was wrong was the shipped values, not the
existence of an escape hatch.

### 5. Drop the continuation pattern

`parseScrollback` segments on prompt lines only; a multi-line entry recalls as its
first line. The continuation is not learnable — § Rejected has the measurements.

### 6. Take multi-line recall from the REPL's own history file

Extend the shell special-case in `scrollback.read` into a program-keyed table of
readers. All three are written on every accepted input, mid-session, with the
source intact, and record commands typed directly into the REPL:

| program | file | format |
|---|---|---|
| julia | `$JULIA_HISTORY`, else `<depot>/logs/repl_history.jl` | `# time:` / `# mode: julia` / tab-indented lines |
| radian | `radian.local_history_file` in the window's cwd when it exists, else `radian.global_history_file` (`~/.radian_history`) | `# time:` / `# mode: r` / `+`-prefixed lines |
| ipython | `$IPYTHONDIR/profile_default/history.sqlite` | `select source_raw from history order by rowid desc` |

`# mode:` separates `r`/`shell`/`browse` and `julia`/`shell`/`pkg`/`help` — the
distinction `config.match.prompt`'s own comment says the patterns could not make.
radian's
precedence is `prompt_session.py:114`: a cwd-local file wins, and only exists if
the user opted in, so check the window's cwd first.

ipython needs the `sqlite3` binary (`-json`); without it fall back to scrollback.

The other four get no reader. Stock python (`~/.python_history`) and R
(`.Rhistory`) write only at exit. lua never writes one at all — `lua_saveline` is
`add_history(line)` and nothing in `lua.c` calls `write_history`. pymol has no
history mechanism.

The readers are program-keyed (`design.md` § Config keying axes), so
`config.history[program] = { path = fn(win), parse = fn(text) }` puts the three
shells' existing `histfile`/`parseHistoryText` pair on the same footing and lets a
user point at a non-default file. An entry is wrong in a way a test can catch:
either the file parses into entries or it does not.

Two windows running the same program share one history file, so recall shows the
other window's commands. That is already true for the shells; note it in the
README rather than working around it.

Guard `parseScrollback` so a program with a reader never falls through to it. A
shell scrolled past the end of its history reaches it today and would start
warning once the table is gone.

## Test

No kitty needed for any of this — `design.md` § Testing.

- `learn_prompt(text) -> pattern|nil` taking `--add-cursor` output, spec'd from
  the seven captures above. Capture real output; do not hand-write the escape
  sequences, for the reason 06 gives for `is_pager`.
- digit generalisation, magic-character escaping, the ≥2-occurrence verification,
  the `col == 1` refusal, and a partly-typed line being refused.
- `parseScrollback` against captured `--extent=all` samples for python, r, lua,
  ipython and radian, asserting the entry lists.
- julia and radian history parsers from text fixtures; ipython from a fixture
  database or a stubbed `_exec`.

## Verify

- `make test` passes
- `[r` in an R buffer attached to radian lists entries — today it does nothing
- `[r` in a julia buffer, same
- a command typed by hand straight into radian is recalled
- `[r` mid-computation notifies instead of returning a wrong entry
- `[r` with julia's pager open refuses
- one `kitty @` round-trip is added per window, not per keypress (`get-text` is
  ~21 ms)

## Behaviour changes reaching the owner's live config

`~/dotfiles/config/nvim/lua/plugins/ui.lua:8-38` overrides no `match` key, so all
of it lands.

- `[r`/`]r` start working in radian and julia REPLs.
- One notify per REPL window naming the learned prompt.
- Multi-line recall becomes exact for julia, radian and ipython, and reaches
  further back: `scrollback_lines` is unset, so kitty keeps 2000 lines, while
  `~/.radian_history` is already 218 KB and `~/.julia/logs/repl_history.jl`
  651 KB.
- Multi-line recall in a stock `python`, `R` or `lua` REPL degrades to the first
  line. `config.command` maps `python → ipython` and `r → radian`, so reaching it
  means attaching to a hand-started window.
- pymol recall refuses with a message instead of returning every scrollback line.

## Rejected

- **Deriving the continuation from the primary prompt.** It is width-aligned in
  python (`... `), ipython (`   ...: `), r (`+ `), radian (3 spaces) and julia
  (4 spaces), but *whitespace* only in radian and julia. lua breaks even the
  width rule: `> ` primary, `>> ` continuation.
- **Probing for it.** `(` + Enter does render the continuation at the same cursor
  column in all six REPLs that have one. There is no safe abort. Ctrl-C recovers
  python, ipython, radian, r and julia, and **kills lua and pymol** — both
  windows measured dead. Completing the expression instead (`1)`) recovers python
  and r but leaves lua at `>> `. A probe also writes junk into the REPL and into
  the history files step 6 reads.
- **Inferring it from the scrollback.** The best candidate rule — most frequent
  `col-1`-wide prefix on the line following a prompt line — picks `[1` over `+ `
  in R, where `[1] ` output dominates. Silent wrong answers, the failure mode
  this task exists to remove.
- **Asking the REPL.** Measured: `sys.ps1`/`sys.ps2` exact for stock python;
  `getOption("prompt")`/`("continue")` exact for stock R; radian *does* sync its
  rendered prompt into `getOption("prompt")` (returns `R❯ `), but reports
  `getOption("continue") == "+ "` while rendering 3 spaces; ipython's `sys.ps1`
  is `'In : '` with the number stripped and is not what prompt_toolkit draws;
  lua leaves `_PROMPT`/`_PROMPT2` nil and uses compiled-in defaults. Wrong for
  both programs that motivated the task, and it executes code in the user's REPL.
- **A send log.** Recall must find commands the user typed into the REPL directly.
- **Making the REPLs emit OSC 133 prompt marks.** No REPL here emits them today,
  and the prompt-start mark is genuinely emittable — the reason to reject this is
  the *other* mark, not the escape.

  Wrap the escape in `\001`/`\002` and it works: readline's
  `RL_PROMPT_START_IGNORE` pair, which prompt_toolkit's `ANSI` parser turns into a
  `[ZeroWidthEscape]` fragment and CPython's PyREPL strips in `process_prompt`.
  Measured in radian with `options(radian.prompt = "\001\033]133;A\007\002…")`:
  the prompt renders clean and the cursor lands in column 4, display width 3.
  Unwrapped is what fails, everywhere — prompt_toolkit drops the `\x1b]`
  introducer and prints `133;A` as text, and stock python miscounts the escape as
  visible columns on both readline and PyREPL.

  It still does not help, for two reasons:
  - **`A` alone buys nothing kitty can use here.** `--extent=last_cmd_output`
    needs `A` *and* `C` (`B` is ignored — there is no `case 'B'` in `screen.c`),
    and `C` has to fire between Enter and evaluation. radian, R, lua and stock
    python expose no such hook; only julia (`mode.on_done`) and ipython
    (`pre_run_cell`, via the private `_extra_prompt_options`) can emit it.
  - **Nothing reports where the marks are.** `kitty @ ls` does not carry them, the
    `*_cmd_output` extents need `C`, and `scroll_to_prompt` is not reachable over
    remote control (`Error: Unknown action`). Segmentation would still need the
    prompt text, which step 1 already has.

  pymol cannot participate at all: its prompt is a hardcoded C string
  (`layer1/Ortho.cpp:2738`), not an option. And all of it is the user's REPL
  config, not the plugin's.

## Out of scope

- `config.match.help.julia` (`config.lua:161`). `replHelpCmd`
  (`commands.lua:24-38`) matches its keys against scrollback lines, and `[">"]`
  does not match ` ❯ ` either — the same root cause, one table over. The
  learned prompt makes it fixable; fixing it is a separate task.
- `pasteOutput` returning the whole session (`kitty.get_last_output`). That needs
  OSC 133 marks, which nothing here emits.
- `in_alternate_screen` is true for julia + TerminalPager. That answers 06's
  measurement, but 06 owns the change.
