# 15 — Last command output, cut on the prompt

**Goal:** make `pasteOutput` insert the last command's output instead of the whole
session. **Depends on:** 14, for the echo predicate (11 already landed the prompt).
**Blocks:** nothing.

Ordered after 13 rather than blocked by it. The marks rule went through a draft that
borrowed 13's argv-to-name vocabulary; the `ppid` rule it settled on borrows nothing,
so the two are independent and 13 lands first only because it is smaller.

## The problem

`kitty.get_last_output` (`kitty.lua:248`) asks for `--extent=last_cmd_output`.
`kitty @ get-text --help`: that extent, and the three beside it, "require
shell_integration to be enabled". The marks are the *shell's*. In a REPL window
the only command the shell ever ran is the one that started the REPL, so "the
output of the last command" is everything the REPL has printed.

Measured on a live ipython window: `last_cmd_output` returns 1895 lines / 37100
bytes starting at `In [67]:`, byte-identical to `--extent=all`, against 158 bytes
of screen. It starts at cell 67 rather than 1 only because `scrollback_lines` is
unset and kitty's default of 2000 had already evicted the rest. `pasteOutput`
(`scrollback.lua:186`) comments every line and `nvim_put`s them, so the keymap
dumps the session into the buffer.

The extent flag is unchanged since the feature was added (`4ae72c1`, before the
refactor sequence), so nothing in 02–12 caused this. What changed is session
length: for a REPL one command old, the whole session *is* the last command's
output, which is why it looked right when it was written.

## Do

**Right-pad the candidate line, not the pattern.** kitty rstrips the final line of
a capture, so the prompt the REPL is idling at comes back a space short of its own
learned pattern and matches nothing. Fix it at the one place that cares:
`isIdlePrompt` pads the line it is handed back out to the prompt's rendered width
before matching. `promptPattern` (`scrollback.lua:27`), `promptLines`
(`scrollback.lua:35`), `promptFor`'s confirmation and `parseScrollback` all stay as
they are.

The alternative — loosening `promptPattern` to emit the prompt's own trailing
whitespace as `%s?` — is rejected. It widens every consumer, and `promptFor`'s
two-occurrence guard is the one that must not widen. Measured, on radian scrollback
holding `R❯ x <- 1` with the user having retyped `x <- 1` and not pressed Enter:

```
^R❯ x <%- %d+ ()     -> 0 occurrences  (refused, correct)
^R❯ x <%- %d+%s?()   -> 2 occurrences  (accepted)
```

That is the guard's whole purpose — a half-typed line reproducing a command already
in the scrollback — and the widened pattern is then written to the registry by
`repl.remember_prompt` (`scrollback.lua:84`) and kept for the session, since
`scrollback.lua:61` retains a cached pattern while it matches at least one line. One
mistimed keypress poisons the window.

Nothing outside `isIdlePrompt` needs the tolerance, because only the *final* line is
ever stripped — kitty rstrips the capture, not each line. Verified live on the
ipython window: interior idle prompts keep their trailing space (`In [117]: `), only
the last is bare, and the committed fixtures agree (`python.txt:1` and its `... `
line both retain theirs). Today's pattern already matches every re-rendered idle
prompt except the last one.

Pad to the rendered width, not by one space: `prompt_at_cursor` right-pads by
`col - 1 - vim.fn.strdisplaywidth(prompt)` (`kitty.lua:224`), which is unbounded —
all seven committed fixtures happen to be 1.

This drops the behaviour change the `%s?` route brought with it, where a REPL one
command old went from one occurrence to two and started passing plan 11's guard, so
`[r` began working there. That is a recall change, not a `pasteOutput` change; it
belongs in its own task if it is wanted. § Verify no longer claims it.

**Prefer kitty's own answer where the marks are the REPL's own.** Where shell
integration really is marking the program we send to, `--extent=last_cmd_output` is
the built-in and better-tested mechanism, and no prompt cut should be attempted —
a shell prompt is arbitrary and `$ `/`> ` occur freely in output. The test is not
the program's name: a `zsh` typed at another shell's prompt is a REPL we can talk
to whose marks belong to its *parent*, so kitty would return the whole nested
session, the same failure as ipython.

**Is the foreground process the one kitty spawned?** That is the question the marks
answer to, and one `ps` hop answers it:

```
trust last_cmd_output  ⟺  fg.pid == window.pid  or  fg.ppid == window.pid
```

`window.pid` is what kitty forked. On macOS that is `/usr/bin/login`, and the shell
whose integration wrote the marks is its direct child, so the `ppid` arm is the one
that fires. Where kitty execs the shell directly, the shell *is* `window.pid` and
the `pid` arm fires. Anything the shell went on to start is a grandchild of
`window.pid` or deeper, so both arms miss and we cut on the prompt instead.

Measured across all nine live windows, plus the idle-shell case captured before the
window was reused:

| window | `window.pid` | last fg | `ppid` | |
|---|---|---|---|---|
| idle shell | 90702 (`login`) | 90705 `-zsh` | 90702 | **trust** — marks present, 496 B against 6410 |
| ipython behind `uv` | 62325 | 71078 `uv run` | 62328 | distrust — its two extents are byte-identical |
| seven nvim windows | … | `nvim …` | +3 | distrust |

A REPL from `kitty @ launch` *is* `window.pid`, so the `pid` arm accepts it, but it
emits no marks — the extent comes back empty and falls through.

**Why not compare names.** The cheaper rule, `progname(window.cmdline[1])` against
`progname` of the last foreground process, needs no subprocess because both fields
are already in the `ls` record. It gets all nine windows right too. But it cannot
see nesting: a `zsh` typed at a `zsh` prompt gives `zsh` vs `zsh` and is trusted,
while its marks belong to the *outer* shell — so kitty returns the whole nested
session, which is this plan's own bug one level up. The `ppid` test rejects it,
because the inner shell's parent is the outer shell, not `window.pid`.

Nesting is invisible in the `ls` record by construction: `foreground_processes` is
the tty's foreground process *group*, and job control puts a nested interactive
shell in a group of its own with the parent absent (measured — plan 13 § Settle
first 2). So no amount of reading that record distinguishes the two, and the one
`ps` call is what buys the distinction.

**Why not compare pids to `window.pid` directly.** An earlier draft trusted the
marks when the resolved program's pid *is* `window.pid`. That never accepts on
macOS, because of the `login` hop above: every one of the nine windows is
`login → zsh → program`, so the accepting branch is unreachable, `get_last_output`
becomes dead code, and shell REPLs get prompt-cut — the thing this section exists
to prevent. The `ppid` arm is exactly what repairs it.

**Cost and shape.** One `ps -o ppid= -p <pid>` through the existing `util.exec`
seam, per `pasteOutput` — beside a `kitty @ get-text` that already costs ~19 ms.
POSIX, so macOS and Linux alike. It needs no program name and no `config` entry, so
it is one rule for every window, and unlike the name comparison it borrows nothing
from plan 13.

**Cut the scrollback on the learned prompt** in every other case. Task 11 already produces the tool:
`promptFor` (`scrollback.lua:53`) returns a per-window Lua pattern with a position
capture, learned off the running REPL, confirmed against the scrollback it will be
used on, cached in the registry, and refusing to read behind a pager or an
altscreen program. `pasteOutput` is in the same module, so no new export.

Read `--extent=all` and cut it in two steps.

1. **Drop the tail the REPL is sitting in.** From the last line upwards, drop
   every line that is blank or is the prompt with nothing typed after it — which
   the right-padding above is what makes matchable. There is more
   than one line to drop: pressing Enter at a prompt re-renders it, and the live
   ipython capture ends `In [117]: `, blank, blank, `In [117]: `, blank, blank,
   `In [117]:` — with 90 of its 129 prompt lines carrying no command at all, and
   `In [98]: ` appearing 58 times before the command that finally ran under it.
2. **Anchor on the last command line** — the last remaining line the pattern
   matches with something typed after it. What lies below it is that command's
   output.

**Rejected alternative:** "the last two matching lines, take what is between". It
returns the *previous* command's output on every fixture in the repo, and on the
live window two blank lines — the "no output" warning — where the real output is
239 lines. Recorded because an earlier draft of this plan described it as the rule
being replaced, which it is not: `M.pasteOutput` (`scrollback.lua:186-200`) has only
ever called `kitty.get_last_output`, and `git log -S last_cmd_output -- lua/` gives
`4ae72c1` alone. Nothing in the codebase parses the scrollback for output today.

**Where each step stops.** Step 2 slices from the anchor to the end of the text step
1 returned, not to the end of the raw capture — otherwise the idle prompts step 1
just dropped come straight back. The cost is that genuine trailing blank output is
lost: `print("a\n\n")` pastes `a` alone. Accepted, being indistinguishable from the
blanks the REPL itself draws. The no-anchor fallback pastes the *truncated* text for
the same reason, so a fresh REPL showing only a banner does not paste the banner
plus its prompt.

**Three outcomes, three messages.** Output below the anchor: paste it. Nothing
below the anchor: warn "no output" — an assignment prints nothing, and a silent
no-op reads as a broken keymap. **No anchor anywhere in the capture**, with a
pattern in hand: the capture *is* one command's output, truncated at
`scrollback_lines` by an output longer than the buffer holds. Paste it and say so.
That last case is the only fallback to the whole capture, and it is reachable only
with a confirmed pattern — with no pattern at all, `promptFor` has already warned
and nothing is pasted.

**Name the units.** All `local`, all in `scrollback.lua` — this is scrollback
parsing keyed on a prompt:

- `isIdlePrompt(line, pattern)` — is this a prompt line with nothing typed after
  it? A predicate, named as one; the repo's existing one is `kitty.is_pager`
  (`kitty.lua:188`). This is also where the final line's missing pad is absorbed.
- `lastOutput(text, pattern, echo) -> string[]` — the lines the last command
  printed, possibly empty. `echo` is plan 14's
  `fun(anchorText: string, below: string[]) -> integer`, how many lines below the
  anchor are the command echoed back; nil when 14 can build no rule for the
  program, in which case nothing is skipped. Written with the third parameter from
  the start. Takes its text as an argument rather than reading the module global,
  so it is testable in the way `design.md` § Testing says `parseScrollback` is not.
- `readWithPrompt(win, program) -> text, pattern` — `get_scrollback` then
  `promptFor`, which `M.read` (`scrollback.lua:99-100`) and `pasteOutput` both
  want. `M.read` keeps its own walk-state reset. It does *not* also build the echo
  predicate: `pasteOutput` calls plan 14's `echoFor(window, program)` itself, so
  this unit keeps the one job its name promises and stays a letter's difference
  from `M.read` in name only.

`pasteOutput` therefore holds the `kitty @ ls` record, not just a window id — the
marks rule needs `window.pid`, and `echoFor` needs `window.columns` for plan 14's
wrap gate. One fetch, passed down; neither module should call `kitty.window` again.

**`pasteOutput` must not call `M.read`**: `scrollback.lua:95` resets
`tScrollback`/`iScrollback`/`walkWin` and would silently drop a `[r` walk in
progress. `promptFor` is safe to share — its only writes are `repl.remember_prompt`
and its two messages, none of the five walk locals.

**Use `repl.current()`, not `repl.win()`** (`scrollback.lua:187`). `promptFor`
takes `program` for the `config.prompt` override and for its message text; with
`nil` a configured override silently stops applying and every message says "REPL".

**Guard the empty commentstring.** `scrollback.lua:197` does `cs:format(line)`;
`cs == ""` turns every line into `""`. Pre-existing, but this is the first time
the right output reaches it.

**Rewrite the shell-integration sentence at `README.md:8`**: it is what kitty
answers with for a shell REPL, and the readable prompt `README.md:231-237` already
documents is what covers the rest.

## Known limitation

The exposure `parseScrollback` (`scrollback.lua:114-115`) already carries, now on a
second path: **an output line matching the prompt pattern becomes the anchor**,
truncating the paste to what follows it. `>>> ` in `help()` output or a doctest is
the concrete case; `> ` (r, lua) is broader. No false match occurs in the 1895-line
live capture, so this is a hazard, not an observed failure.

The echoed block below the anchor is plan 14's, not a limitation here.

## Test

Fixtures already exist: `tests/fixtures/repl/scrollback/{python,ipython,radian,julia,r,lua,pymol}.txt`
cover the with-output cases, and `session(program, { scrollback = … })` takes
literal text where the screen is not under test (`scrollback_spec.lua:141`).

Capture new fixtures for the two cases nothing covers — an ipython prompt with a
couple of bare `send $'\n'` before the capture in `tests/fixtures/repl.sh`, which is
the failure that motivates the plan, and a command with no output.

Assert `lastOutput` directly rather than through `nvim_put`, which drags in
`commentstring` and buffer state; one integration case through `pasteOutput` in a
scratch buffer with a known `commentstring` covers the rest.

Cases: output present; no output (warns); prompt re-rendered by Enter; no anchor
with a pattern (pastes the capture, says so); no pattern (inherits `promptFor`'s
warning); `echo` nil (nothing skipped). Assert `promptFor`'s two-occurrence guard
is *unchanged* — a half-typed candidate reproducing a scrollback command still
counts zero — since that is what the rejected `%s?` route broke.

The marks rule is a separate unit and needs the `ps` hop stubbed, the way
`commands_spec.lua:29` stubs `util.exec`. Four cases, one per row of the truth
table: `fg.pid == window.pid` (launched REPL), `fg.ppid == window.pid` (the shell
kitty spawned, through `login` or not), neither (a REPL under that shell), and
`ps` failing or returning nothing — which must distrust, not crash, since a wrong
*accept* pastes the whole session.

## Verify

- `make test` passes
- In an ipython session tens of cells deep, the keymap inserts the last cell's
  output, not the session
- Press Enter at the prompt a few times first, then the keymap — the live failure
- Same in radian and julia, whose prompts are the user's own configuration
- `[r` behaves exactly as it does today, on a REPL mid-typing and otherwise — this
  plan changes no recall behaviour
- Assignment cell → "no output" warning, nothing inserted
- **An idle shell REPL takes kitty's extent, not a prompt cut** — the `ppid` arm,
  already confirmed on window 604 (`login` 90702 → `-zsh` 90705, marks present, 496
  bytes against 6410). Run a command in that shell and confirm the keymap pastes its
  output. Check the record with `kitty @ ls --match=id:N` issued from *another*
  window, since running it in the window under test makes it non-idle.
- **A REPL nested in that shell is cut on its prompt, not handed kitty's extent** —
  type `zsh` at the shell prompt, run a command, then the keymap. This is the case
  the name comparison could not see, and the reason for the `ps` hop; getting the
  whole nested session back means the rule regressed to it.
- A command mid-run, and a command half-typed in the REPL: with a *cached* pattern
  `promptFor` returns at `scrollback.lua:61` without reading the screen, so neither
  is refused. Confirm both degrade the way § Do predicts rather than adding a guard:
  mid-run anchors on the running command and pastes the output *so far*, which is
  honest and repeatable; half-typed anchors on the half-typed line, finds nothing
  below and warns "no output". Neither is wrong enough to spend a `get_screen`
  (~19 ms) refusing. If either pastes something else, that is the finding.

## Out of scope

- **Capping the paste.** Segmenting bounds it to one command, which is what was
  asked for; a command that printed 50k lines pastes 50k lines.
- **`--extent=screen`.** Not an option: the live last output was 239 lines against
  an 18-row screen. `--extent=all` costs ~19 ms on a 37100-byte window,
  indistinguishable from `screen` over 5 calls (0.09 s vs 0.10 s). Line wrapping
  is a non-issue here — the algorithm uses no row indices, unlike `is_pager` and
  `prompt_at_cursor`.
- **`promptFor`'s cache-before-pager-guard hole.** `scrollback.lua:61` returns a
  cached pattern before the altscreen/`is_pager` check at `:68`, so a pager whose
  content matches the prompt reads as REPL output. Usually self-correcting — the
  cached pattern matches zero lines of an alt screen, so the code falls through to
  the guard — and it affects `[r` today, not just this. Pre-existing; a separate
  one-line change.
- **OSC 133.** Plan 11 measured the whole route: `--extent` needs `A` *and* `C`
  (`B` is ignored — no `case 'B'` in kitty's `screen.c`), `C` must fire between
  Enter and evaluation, and only julia (`mode.on_done`) and ipython
  (`pre_run_cell`) expose a hook to emit it. Nothing reports where the marks are
  either: `kitty @ ls` does not carry them and `scroll_to_prompt` is not reachable
  over remote control. If revisited, the escape must be wrapped in `\001`/`\002`
  (readline's `RL_PROMPT_START_IGNORE`) or prompt_toolkit prints `133;A` as text —
  measured in radian, prompt clean, cursor in column 4. All of it is the user's
  REPL config, not the plugin's.
