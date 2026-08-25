# 13 — Resolve a REPL behind a wrapper

**Goal:** name the REPL in a window started as `uv run ipython`, from its
processes rather than its title. **Depends on:** nothing. **Blocks:** nothing.

Lands first of the three because it is the smallest and its § Settle first 2 result
— that job control already hides a nested shell — is what lets 15 stop worrying
about nesting in the `ls` record and reach for `ppid` instead.

## The problem

`cmdline` (`repl.lua:56`) returns `procs[#procs]`, the *last* foreground process,
because starting julia and then `using PlotlyJS` spawns helpers that are listed
earlier. That premise holds: measured with PlotlyJS installed, julia plus a
`plot(…)` call has `kaleido` (PlotlyJS's image-export engine) as a child in its own
process group, so kitty lists both. A wrapper that stays alive inverts the order. A live window started as
`uv run --with ipython --with numpy ipython` reports:

```
[1] <venv>/bin/python3 <venv>/bin/ipython
[2] uv run --with ipython --with numpy ipython
```

so `resolve` sees `{uv, run, …}`: `progname` gives `uv`, the entrypoint rule gives
`run`, neither is claimed, and it returns nil. The window resolves at all only
because `resolve`'s first line matches an `^IPython:` title, which exists for
REPLs reached over ssh. `uv run radian`, `uv run python`, `uvx`, `pixi run`,
`hatch run`, or any window whose title has been overridden get no name — and so no
bracketed paste, no history reader, no help command.

## Settle first

**1. Ordering is undocumented, and keying on pid instead does not rescue it.**
`foreground_processes` appears nowhere in kitty 0.48.2's shipped docs (275 files)
nor in `kitty @ ls --help`, so the order is whatever the platform's process
enumeration yields. Both live multi-process windows here are descending pid.

The draft's escape — "the claimed process with the lowest pid", said to express the
same intent order-free — is not the same rule. kitty returns
`processes_in_group(pgrp)` unsorted, so pid order is not process age: measured over
this machine's 934 process groups, 3 of the 35 multi-member ones have
`list[-1] ~= min(pids)` (pid wraparound puts a member below its own leader), and 19
groups contain no group leader at all. The two rules disagree on ~9% of real
multi-process groups and neither is a proxy for "the outermost process".

So take position, drop the pid option, and say in the docstring that the list order
is what it is. But do not explain *why* it works in terms of where kitty puts the
wrapper — see item 3.

**2. A wrapper that is itself claimed — settled: accept, and say why it is nearly
unreachable.** Shells are claimed (`config.programs.sh/zsh/bash`), so the worry was
that a shell wrapper would shadow the REPL behind it. It does not, because
`foreground_processes` is exactly the tty's foreground *process group*, and a shell
leaves that group in one of two ways before the REPL is running. Measured under a
pty:

```
idle interactive zsh         fg pgrp 28394 -> [28394 zsh -f -i]
  nested interactive zsh     fg pgrp 28396 -> [28396 zsh -f -i]      outer invisible
zsh -f -c 'sleep 4'          fg pgrp 28702 -> [28702 sleep 4]        shell exec'd away
zsh -f -c 'exec sleep 4'     fg pgrp 28742 -> [28742 sleep 4]
sh  -c 'sleep 4'             fg pgrp 28788 -> [28788 sleep 4]
```

Job control puts each interactive job in a *new* group, so a REPL nested in a shell
lists only the REPL — the true REPL is what the scan sees, with no work on our part.
A non-interactive `-c` shell exec's itself into its last command, so it is gone
too. What stays visible in the group is a wrapper that does no job control and does
not exec (`uv run`), or a helper the REPL spawned (`kaleido`,
`sh -c 'cloudflared …'`) — and of those only the shell helper is claimed, which is
the `ProxyCommand` window § Do already handles by keeping the title guard first.

So a claimed shell appearing beside another claimed program requires a wrapper that
is a shell, stays alive, and does not exec. Nothing the plugin launches does that,
and no shape measured here does either. Accept the current answer; record the
process-group reason so the question is not reopened.

**3. The direction may be platform-specific — resolve by measuring on Linux.**
kitty has two `process_group_map` implementations: the macOS one wraps a C call,
the Linux one iterates `/proc`, which procfs emits in ascending pid order. So the
wrapper is plausibly *first* on Linux where it is last here. Not measurable from
this machine — the macOS build carries no `/proc` branch to read.

It does not affect the goal. `uv run ipython` and julia+kaleido resolve correctly
from either end, because the wrapper and the helper are both unclaimed. It affects
only the two-claimed case, which is what § Test's discriminating fixture pins. §
Verify carries the Linux measurement; until it is done, that fixture asserts
macOS-observed behaviour and says so in a comment.

## Do

**Take the last foreground process that names a claimed program**, rather than the
last foreground process. `uv` is last and unclaimed, so the scan continues to the
ipython process behind it, while a REPL that shelled out to a claimed program keeps
its own name. The direction decides only when two processes are *both* claimed — say
that, rather than implying the rule is order-free, and do not justify it by
asserting where kitty puts a wrapper (§ Settle first 3).

**Test nvim before the claim, within each entry.** The two tests must not be
independent scans and must not be one merged test. Verified against the real module:
`repl.resolve(window("r.R", "/usr/bin/nvim", "r.R"))` returns `"r"` today —
`progname("r.R")` is `"r"`, and r is claimed. It is refused only because `is_editor`
tests `progname(argv[1])` separately. Fold both into one scan and let the claim test
win inside an entry, and an nvim editing `r.R` resolves to `"r"`, `is_editor` is
false, and `attach` binds a REPL to an editor — what `repl_spec.lua:117-121` and
`detect_spec.lua:57-64` exist to prevent. Per entry: `progname(argv[1]) == "nvim"`
first, short-circuiting; only then the claim test.

`cmdline` goes: "argv of the last foreground process" stops being what anything
wants. Replace it with

- `M.argv_program(argv) -> string|nil` — `progname` plus the `-m`/entrypoint rule
  currently inline in `resolve` (`repl.lua:70-75`), no claim test. Named for
  symmetry with the word-level `M.progname(word)` (`repl.lua:25`): two functions
  answering the same question at different granularities should not be named on
  different patterns.
- `recognised(window) -> string|nil` — the scan. Not `running`, which would lie
  about a window plainly running `pytest`. Its contract, and the docstring: *the
  last foreground process, scanning back, whose command line names a program some
  filetype claims — or `"nvim"`, which `is_editor` acts on. Nil for anything else.*
  Both the closed vocabulary and the scan direction are load-bearing for both
  callers, so both belong in the docstring.

`resolve` becomes the title guard, then `local name = recognised(window)` gated on
`claimed`. `is_editor` becomes `window.is_self or recognised(window) == "nvim"`.

The nvim test is on `progname(argv[1])`, never on `argv_program(argv)`:
`argv_program({"nvim", "notes.md"})` is `"notes"`, so folding the editor test into
the entrypoint rule silently breaks the guard `repl_spec.lua:117-121` pins.

Both units live in `repl.lua`, beside the `cmdline` local they replace
(`repl.lua:53`) — the only reader of `foreground_processes` today. No new file.

**Scan `is_editor` too.** `uv run nvim` is not refused today — the last process is
`uv`, so `<leader>rr` binds to that window and `<CR>` types code into a running
nvim. The same scan fixes it, and keeps an editor a REPL *spawned* (`%edit`,
`git commit` under a shell REPL) from being mistaken for the window's program.

**Skip a process whose cmdline kitty could not read.** kitty sets `cmdline: null`
for a process that has just exited, and `kitty.ls` decodes with plain
`vim.json.decode` (`kitty.lua:49`), so it arrives as `vim.NIL` — truthy userdata
that raises `attempt to index field 'cmdline' (a userdata value)`. Only the last
entry is ever touched today; a scan visits every entry. Fix at the source with
`vim.json.decode(json_string, { luanil = { object = true } })`, which fixes every
consumer of the record.

Doing it at the decode rather than in the scan is what also protects
`history.lua:135` (`window.cwd`) and `scrollback.lua:68`
(`window.in_alternate_screen`), where a `vim.NIL` would be *truthy* and pass a
guard it should fail. `process_desc` seeds `{pid, cmdline: None, cwd: None}` and
fills each under `suppress(Exception)`, so both fields can arrive null.

**The decode change is untestable through the specs**, and the plan should say so
rather than let the next reader assume coverage: every spec stubs `kitty.window`
and never reaches `kitty.ls`. The `cmdline = vim.NIL` fixture below therefore
exercises only the belt-and-braces guard, not the decode. Keep that guard, and
widen it — test `type(argv) ~= "table" or argv[1] == nil`, since `cmdline_of_pid`
can plausibly yield `[]` as well as null, and `progname("")` would otherwise ride
on `claimed("")` being false.

No null appears in the live `kitty @ ls` output today, so the blast radius is
currently zero; this is hardening a scan that newly visits every entry.

**Keep the `^IPython:` title check first** (`repl.lua:66`). The reorder the first
draft proposed is a separate behaviour change with a measured cost and nothing in
the goal needing it: order matters only when both the scan and the title answer,
which for an `^IPython:` window means the scan found a *different* claimed name.
Measured — `ssh` behind a `ProxyCommand` reports
`[{sh -c "cloudflared access ssh"}, {ssh server}]`, and shells being claimed, the
scan names that window `sh`, so a title-last rule breaks the remote REPL
`README.md:12-15` exists for. (The guard came in with `96ea272` for *any* remote
REPL, not ipython specifically; narrowing it to `^IPython:` already dropped the
remote julia case.)

**Re-word `remember`'s reason for not caching a nil** (`repl.lua:92-93`). Its
example — "a REPL busy with a subprocess resolves to nothing" — stops being true
once the scan names the REPL behind the subprocess. The policy still holds; what
keeps it is the launch race, where `foreground_processes` is empty
(`repl_spec.lua:142-147`).

**Update `README.md:89-95`**, which documents the current rule:

> The name comes from the window's foreground processes, scanned from the last one
> kitty lists back to the first, taking the first that names a program some
> filetype claims. A wrapper is not a name: `uv run ipython` is ipython, and
> `uv run pytest` is unnamed. Nor is a helper the REPL spawned — julia with
> `using PlotlyJS` loaded is still julia.

It states the rule's outcomes, not kitty's process ordering. An earlier draft
explained *why* each case works — "helper processes a REPL spawns are listed before
it… a wrapper that stays alive is listed after" — which asserts kitty internals
that hold on macOS and may invert on Linux (§ Settle first 3). The outcomes hold on
both.

## Test

`repl_spec.lua`'s `window(title, ...)` (`:11`) takes cmdline *words*, so it cannot
take several processes without an ambiguous signature. It has **32** call sites, not
the dozen an earlier draft assumed, and `detect_spec.lua:11` defines its own
single-process `window(id, ...)` with 5 more (`:42`, `:52`, `:60`, `:61`, `:68`) —
which this plan also needs, since the `uv run nvim` refusal runs
`detect_REPL` → `attach` → `is_editor`.

So do not rewrite the existing helper. Add a sibling `windows(title, ...)` taking
each vararg as one `string[]` in kitty's order, and leave `window` alone. That
absorbs the hand-built records at `repl_spec.lua:93-101` and `:103-106` and every
new multi-process fixture without touching 32 working call sites, lets
`windows(title)` express the empty list, and gives `detect_spec` something to import
rather than growing a third copy of the same helper.

The julia shape is now capturable: PlotlyJS is installed, and `plot(…)` puts
`~/.julia/artifacts/…/bin/kaleido` in julia's process group. Capture it from a real
window rather than inventing it — but note it does not pin the scan *direction*,
because `kaleido` is claimed by no filetype, so the scan reaches julia from either
end. The same goes for the other three obvious cases (`uv run` two-process, ssh via
title, `uv run pytest` → nil). Add the ones that discriminate:

- two claimed processes with different names —
  `[{python3, -c, "import x"}, {venv/python3, venv/ipython}]` → `ipython`. This is
  the test that pins "from the end".
- `uv run nvim` → refused as an editor; an nvim *child* of a REPL (`%edit`) → still
  the REPL.
- an entry with `cmdline = vim.NIL` beside a good one → the good one, and one with
  `cmdline = {}` likewise. Both test the scan's guard, not the decode — see § Do.
- a REPL nested in an interactive shell — one entry, the inner REPL, the outer shell
  absent. Pins the § Settle first 2 finding: job control is what makes nesting a
  non-problem, and a fixture is what stops a future change from assuming otherwise.

Fix `repl_spec.lua:149-155` ("promotes what is running over the hint, which may
name a wrapper") while there: it passes today only via the `IPython:` title, so it
does not test wrapper promotion at all. Give it the real two-process shape — **and
change its title too**, since a title still starting `IPython:` keeps it passing
trivially and the fix would go unnoticed.

## Verify

- `make test` passes
- `<leader>rr` (`setlast`, not `<leader>rs` — that is `new`) onto a hand-started
  `uv run ipython` window with its title overridden by
  `kitty @ set-window-title`, names it ipython: a multiline send arrives bracketed
  and `[r` recalls entries
- `<CR>` in a python buffer with no binding auto-detects that same window
  (`detect.lua:33-35` is a second consumer of `resolve`, gating on
  `programs[program]`)
- A remote ipython over a plain ssh window is still named
- A window running `uv run nvim` is refused
- A `radian` started from inside a nested interactive `zsh` is named `radian`, not
  `zsh` — the nesting case, which § Settle first 2 says the OS already handles

**On Linux** (§ Settle first 3 — the one thing this machine cannot answer). In a
kitty window there, run `uv run --with ipython ipython`, then from another window:

```sh
kitty @ ls | jq '.. | .foreground_processes? // empty | map(.pid, .cmdline[0])'
```

If `uv` comes back *before* the venv python, the list is ascending-pid on Linux and
the two-claimed fixture is macOS-specific. Record the answer in § Settle first 3
either way, and if it does invert, decide there between branching on platform and
dropping that fixture. Everything else in § Verify should behave identically — the
wrapper and helper cases do not depend on direction, so a divergence anywhere else
means the rule, not the ordering, is wrong.

## Out of scope

- **Launching a wrapped REPL.** `config.command` values are split on whitespace
  (`kitty.lua:271-274`), so `command = { python = "uv run ipython" }` already
  launches. Its launch hint is the *first* word (`commands.lua:114`), so the window
  is `pending = "uv"` and titled `uv id=N` (`commands.lua:119`) — which also
  destroys the `^IPython:` fallback — sending raw, with no history reader and no
  help, permanently, since a nil resolution never displaces a hint. The scan is
  what ends that, on the first `repl.program` call after the process appears.
  Naming the hint better, and the title with it, is a separate change.
- Walking the process tree by ppid, to *name* a REPL. The foreground list carries
  the wrapped process in every shape measured, and where it does not — a nested
  interactive shell — the OS has already narrowed the list to the true REPL
  (§ Settle first 2). Plan 15 does take one `ppid` hop, for a different question
  (whose shell integration wrote the marks), which the `ls` record cannot answer at
  all. One hop for a yes/no test is not a tree walk for a name.
- `progname`'s version-tail stripping, which is why a program whose own name ends
  in a digit cannot be matched.
