# 12 — Integration fixes

**Depends on:** 01–11 (all landed)

What an integration review of the eleven-task refactor turned up: places where two
tasks each solved half a problem, and leftovers a single-task review could not see.

Order: A and B first, both live bugs on the send path. Then B → G (G's last case
is B's regression test) and C → D (both touch `replHelpCmd`'s surroundings and the
same README bullet). E, F, H are independent.

Finding 9 of the review, `plans/design.md` staleness, is already corrected.

## A. A launch hint that resolves to its own name wipes the context memo

`repl.lua:99`. `remember` compares against `state.program` only:

```lua
if state.program ~= program then state.sent, state.prompt = nil, nil end
```

On the launch path `attach(win, hint)` stores the hint as `state.pending` and
leaves `state.program` nil, and `M.program` (`repl.lua:159`) falls back to
`pending` — that is the point of the hint, since `kitty @ launch` returns before
the program shows up in `foreground_processes`. So context is sent and marked in
`state.sent` under the hint's name while `state.program` is still nil. The first
`identify` that resolves the window then reaches `remember` with `nil ~= "julia"`
and clears the memo. The context line goes out a second time.

Observable with the shipped config: a freshly launched ipython is assigned
`__file__` twice (`config.variables.ipython`).

Task 04 introduced `pending`, task 09 introduced the memo, and neither knows the
other's half of "same REPL, keep what it was told".

Fix — the pending hint is a claim about identity, so compare against it too:

```lua
if (state.program or state.pending) ~= program then state.sent, state.prompt = nil, nil end
```

Safe because `pending` and `program` are mutually exclusive: `attach(win, hint)`
replaces the whole entry (`repl.lua:123`) and `remember` nils `pending` on the
first success (`repl.lua:100`). Verified against six paths — hint matches, hint is
a wrapper (`uv` → `ipython`), plain re-resolution to a different name, re-launch
over a live window, hint resolving to a shell, window gone before resolution — the
memo survives only when the hint matches.

Then re-word `M.sent`'s docstring (`repl.lua:163-167`) and `M.remember_prompt`'s
(`:188-189`): "resolves to a different name" now means different from whatever the
window was last claimed to run, hint included.

Two new cases in `repl_spec.lua`, beside `:180` ("drops it when a launch takes the
window over", which covers attach-resolved-then-re-attached, a different path):

1. attach with hint `julia`, record a `sent` entry, window resolves to `julia` →
   entry survives.
2. same, window resolves to `python` → entry cleared. The fix must not turn the
   clear off altogether.

## B. `programs = { <ft> = false }` throws out of every keymap

`repl.lua:40-41`. `claimed` indexes every value of `config.programs`:

```lua
for _, programs in pairs(config.programs) do
    if programs[name] then return true end
```

`README.md:57` documents `false` as the way to drop a per-language entry ("An
entry of a per-language table cannot be dropped by omission — set it to `false`"),
and the deep merge in `init.lua:50` preserves it. A user who follows that gets

```
repl.lua:41: attempt to index local 'programs' (a boolean value)
```

out of `resolve`, which every send goes through. `detect.lua:13-17` and
`context.lua:27` both tolerate the shape; `repl.lua` is the only place that does
not.

Fix:

```lua
for _, programs in pairs(config.programs) do
    if type(programs) == "table" and programs[name] then return true end
end
```

`type(…) == "table"` rather than `programs and programs[name]`, so a stray number
is tolerated too.

**The test must use a program no filetype claims.** `claimed` returns on the first
match, so whether it ever reaches the `false` entry depends on `pairs` order —
resolving `julia` under `programs = { python = false }` returns normally about as
often as it throws. Only an unclaimed name (`nvim`, which `detect_REPL` walks past
on every auto-detect) forces the full iteration.

Put it in `repl_spec.lua` beside `:79` ("leaves an unclaimed program unnamed"), not
in the new `detect_spec.lua`: `repl.resolve` is the unit, and it needs no seam —
the throw reproduces from a bare `repl.resolve(window)` call.

## C. Flatten `config.match`

`config.lua:175-191`. Task 02 removed `match.detect` and task 11 removed
`match.prompt`, leaving `match` as a namespace around a single key while its former
sibling `prompt` now sits at the top level. Two spellings for one key space.

Move `match.help` to `config.help`, drop `match`. Call sites: `commands.lua:68` and
the comment at `:69`; the axis header comment at `config.lua:9`; `README.md:68`,
`:127`, `:229`; the program-keyed axis list in `plans/design.md` § Config keying
axes.

This is a published plugin, so a downstream `setup{ match = { help = … } }` would
be deep-merged into a `config.match` nothing reads and ignored silently. Warn in
`setup`:

```lua
if userconfig.match then message.warn("config.match.help is now config.help") end
```

`design.md` § Owner's live config records that the owner's own config overrides no
`match` key.

## D. `replHelpCmd` reads its own screen, at the wrong moment, and fails silently

`commands.lua:67-92`, `M.help` at `:255-263`, `M.helpVisual` at `:266-277`.

**The ordering half of the finding is real** — settled by driving a live julia +
TerminalPager window. With `@help print` paged:

- `kitty @ ls` reports `in_alternate_screen`, and the page footer is `:  … 100%`,
  so `kitty.is_pager` is true (the `terminalpager-mid` fixture already shows this)
  and `closePager` fires.
- `kitty @ get-text --extent=all` while the alt screen is up returns **only the
  page** — none of the session's scrollback. So `replHelpCmd`'s walk cannot see a
  REPL prompt at all; in the capture it matched `julia> eval(:x)`, a doctest line
  *inside the help text*, against the `>` key.

So the walk reads a screen `run` then changes, and derives its answer from page
content. The wrong-answer case is a pager entered from `pager>` mode (which needs
`?` after `q`, but gets `@help `); the common case is a page with no `>` in it and
a silent nil.

**Do not hoist `closePager` and re-read.** It sends `q` via `kitty @ send-text` and
returns immediately — reading straight after races the pager's redraw. `sync`'s
docstring is explicit that the send path has no confirmation to give, which is fine
when the next thing you do is send, not read.

Fix by matching against the prompt the REPL is *currently* sitting at, rather than
walking backwards through text:

```lua
local function replHelpCmd(program, prompt, query)
```

`M.help`/`M.helpVisual` read one screen, use it for both the pager probe and
`kitty.prompt_at_cursor`, and pass the rendered prompt in. That drops the
`--extent=all` fetch and the backwards walk entirely, which is what made help-text
content matchable in the first place, and satisfies `design.md` § Testing's
"replHelpCmd fetches its own input" note — the function becomes testable with no
seam.

Warn **inside** `replHelpCmd`, not at the two call sites — only it can tell "no
entry for this program" from "no key matched", and warning at both callers
duplicates the message and throws that distinction away.

Add a `replHelpCmd` spec: prefix string, `{ prefix, suffix }` pair, mode match
against an injected prompt, fallthrough to the default, no entry at all. It is the
last unit `design.md` names as testable-without-a-seam that has no coverage.

**Reshape the entry: mode prompts are literals, the primary prompt is not.** The
shipped `[">"] = "@help "` assumes a stock `julia> `. This machine's julia prompts ` ❯ `, and
`tests/fixtures/repl/scrollback/julia.txt` — captured from it — contains zero `>`,
so the key never fires and `M.help` returning nil is the *normal* case, not an edge
one. Task 11 removed exactly this class of shipped-prompt assumption from
`config.match.prompt`: the primary prompt is the user's own configuration and no
shipped value can be right. The mode prompts are different — julia and
TerminalPager draw those, not the user.

So list only the mode prompts, ordered, and fall through to a default:

```lua
julia = {
    default = "@help ",
    { "pager%?>", "" },
    { "pager>", "?" },
    { "help%?>", "" },
}
```

The array part is matched in order against the current prompt, first match wins;
`default` covers the primary prompt whatever it renders as. That fixes both
existing defects at once:

- **`pairs` has no order.** `config.lua:180` and `README.md:129-131` promise the
  dict is matched "from first to last key" while `commands.lua:82` iterates
  unordered, which under LuaJIT's actual order leaves `pager??>` unreachable behind
  `>`. An array part is ordered by construction.
- **`?` is a Lua pattern quantifier.** `help??>` parses as `hel` + optional `p` +
  `?>`, matching `help?>` by luck and `hel?>` besides. Escape as `%?`, and document
  in `README.md:129` that these are Lua patterns.

**Capture the mode prompts before writing the keys.** Their literal spellings have
never been checked against a live REPL — no fixture holds one, and the existing
`pager??>`/`help??>` keys only ever worked through the quantifier accident, so it
is not clear whether the author meant `pager?>` or something else. Julia's modes
are settable in principle (`Base.active_repl.interface.modes[i].prompt`) but stock
in practice, and the prompt-restyling that produces this machine's primary prompt
leaves them alone. Extend `tests/fixtures/repl.sh` to capture julia in help, pager
and pager-help mode, and write the keys from what it captures. A user who does
reassign them still has `config.help.julia` to override.

## E. The recall walk is per-window state living outside the registry

`scrollback.lua:10-16`. Task 04 moved identity, the context memo and the prompt
pattern into `wins[win]`; `scrollback`, `prompt`, `tScrollback` and `iScrollback`
stayed module-global and record nothing about which window they were read from.
`replaceScroll` (`:169`) re-reads only when `iScrollback == 0`, so with
`scrollStart` and `scrollUp` sharing one key, as `README.md` documents: walk in a
buffer bound to REPL 1, switch to a buffer bound to REPL 2, select, press the key
— REPL 1's history comes back.

Fix — record the source window and re-read when it changes:

```lua
local walkWin  -- window the walk was read from

function M.read(win, program)
    walkWin = win
    ...
end

-- replaceScroll:
if iScrollback == 0 or walkWin ~= win then M.read(win, program) end
```

One variable rather than a move into `wins[win]`: the walk is a transient cursor
into one REPL's history, not state the registry should outlive a buffer switch
with. `M.read` already resets everything else it owns, and it is the only way into
the walk state — `startScroll` re-reads unconditionally, `pasteOutput` does not
touch it, so `replaceScroll` is the only gap.

Add a spec: read against one window's fixture, then call the `replaceScroll`
closure with the buffer bound to another, and assert the second window's scrollback
is what gets fetched.

## F. `promptFor`'s pager test misses `less -X`

`scrollback.lua:59-64`. It reads `in_alternate_screen` off a `kitty @ ls` record,
which misses the non-alt case task 06's `kitty.is_pager` was written for.
`plans/11-prompt-detection.md:57` prescribed the flag, but 06 landed after it.

Add `is_pager` rather than swapping for it:

```lua
local window = kitty.window(win)
if not window then return end
local screen = kitty.get_screen(win)
if window.in_alternate_screen or (screen and kitty.is_pager(screen)) then
    message.warn("cannot read a prompt behind a pager")
    return
end
```

The review proposed dropping the `kitty @ ls` call to save a round trip. Keeping it
is the better trade: `in_alternate_screen` is the only thing that refuses a
*non-pager* full-screen program (a nested editor, htop, any TUI), and `promptFor`
runs once per `[r` that starts a walk, not per send — task 06's round-trip budget
was about the send path. Keeping it also leaves `scrollback_spec.lua:145` ("refuses
to read a prompt behind a pager", which serves `alternate = true`) green and the
`session` helper's `alternate` option live.

`pager_spec.lua` already covers `is_pager` against TerminalPager, `less` without
alt-screen, and `(END)`, so no new fixture is needed.

## G. `detect.lua` has no spec

`plans/design.md` § Testing names `replCheck` as one of the three units needing the
subprocess seam, and it is the only one that never got a file.
`claimed_programs`'s compound-filetype fallback (`detect.lua:12-18`) is pure;
`detect_REPL` needs `kitty.get_focused_tab` and `kitty.window` stubbed, which the
other specs already do.

Cover: a filetype with no entry warns and returns nil; a compound filetype
(`python.blender`) falls back to its first claiming part; a tab whose windows
include an editor and a REPL picks the REPL. B's regression test lives in
`repl_spec.lua`, not here.

## H. Delete `kitty.SOH`

`kitty.lua:113-121`. No caller since the dispatch reduced to
custom/bracketed/linewise/raw. `config.lua:63` mentions the technique in prose
only. Delete it; a user writing a `custom` sender that needs it can prepend `\x01`
themselves, and the README's `custom` section is where that would be documented if
it ever comes up.

## Housekeeping

- No `.luarc.json`, so lua_ls reports `undefined-global vim` on every line of every
  file and real diagnostics are invisible. Three lines — `runtime.version =
  "LuaJIT"`, `workspace.library = { vim.env.VIMRUNTIME }` — pays for itself at this
  suite size.
- `commands_spec.lua:10-17` — `record()` overwrites `kitty.run`, `kitty.window`,
  `util.exec` and `vim.notify` with no `after_each` restore, so later `describe`
  blocks depend on which test ran last. Harmless today; a `before_each`/`after_each`
  pair removes the coupling.

## Not in scope

`history.lua:134` still does `require("kittyREPL.kitty").window(win)` inline for
the config→history→kitty cycle, so moving the subprocess seam to `util.lua` did not
remove the module's laziness the way the old `TODO.md` note predicted. Removing it
means passing the window's cwd into `path` instead of letting the reader fetch it,
which changes the `HistoryReader` interface for one program — a separate decision,
not a fix.
