# 14 — The echoed block is not output

**Goal:** stop a multi-line command's echoed continuation lines being read as
output, and recall such a command whole again. **Depends on:** nothing.
**Blocks:** 15.

## The problem

One cause, two problems. `01c126a` deleted the second element of every
`config.match.prompt` pair without replacing it, and nothing since knows what a
continuation line looks like. The two problems are worth separating because
*different information is available on each path*: one walks arbitrarily far back
through a window the plugin may never have written to, the other looks at a block
the plugin transmitted itself, seconds earlier.

### 1. `[r` recalls a fragment

`parseScrollback` (`scrollback.lua:108-117`) matches the prompt and returns
`{ lastline:sub(mPrompt) }` — the anchor line alone. The lines below it were
popped and discarded. Measured on a live `lua` and a live `R` capture, driven
through the real `scrollback.read`/`scrollback.scroll`:

```
lua: { { "print(('%s'):rep(1))" }, { "for i=1,2 do" } }
r:   { { "print(matrix(1:4,2))" }, { "for (i in 1:2) {" } }
```

`>>   print(i)` / `>> end` and `+     print(i)` / `+ }` are gone, so `[r` yields
an unbalanced fragment. Before `01c126a` the same walk absorbed them
(`git show 01c126a^:lua/kittyREPL/scrollback.lua`, `parseScrollback`: accumulate
the popped lines, then take each that matches `patCont`, stopping at the first
that does not). The specs pin the loss today — `scrollback_spec.lua:88` and `:93`
expect `{ "def f():" }` for a command that was `def f():` / `    return 1`.

Plan 11 recorded it as accepted collateral ("Multi-line recall in a stock
`python`, `R` or `lua` REPL degrades to the first line"), on the grounds that
`config.command` maps `python → ipython` and `r → radian`. The three programs it
concerns are exactly the three the fixture harness drives by hand
(`tests/fixtures/repl.sh:39`, `:95`, `:105`).

### 2. `pasteOutput` would paste the block back

Plan 13 anchors on the last prompt line with something typed after it and takes
everything below as output. The plugin's own multi-line send is a bracketed paste
(`kitty.lua:126-131`, `kitty.lua:109-111`), so what sits directly below the anchor
is the rest of the block. Measured, `--extent=all` after the send path each
program actually uses:

| program | send path | first lines below the anchor | continuation | history reader |
|---|---|---|---|---|
| julia | `custom` → bracketed (`config.lua:89-94`) | `        println(i)`, `    end` | none printed — cursor-forward, so the capture holds prompt-width blanks | yes |
| radian | bracketed (`config.lua:66`) | `       print(i)`, `   }` | prompt-width spaces | yes |
| ipython | bracketed | `   ...:     print(i)`, `   ...: ` | `   ...: ` | yes |
| python | `linewise` (`config.lua:72`) | `...     a = 1`, `...     return a`, `... ` | `... ` | no |
| r | raw multi-line (`bracketed.r == false`) | `+     print(i)`, `+ }` | `+ ` | no |
| lua | `custom` → raw (`config.lua:85-88`) | `>>   x = i`, `>>   print(x)`, `>> end` | `>> ` | no |
| pymol | `custom` → `python … python end` | the output itself | none: `PyMOL>` is re-echoed per line | no |
| zsh | raw multi-line | `for> echo $i`, `for> done` | `%_> ` → `for> ` | yes |

Send a 20-line block, get 19 lines of your own code back as comments.

pymol is the exception that needs nothing. It re-prefixes every echoed line with
its own `PyMOL>`, so plan 15's anchor already lands on the last one and the output
below it is right:

```
PyMOL>python
PyMOL>for i in range(2):
    1:for i in range(2):
PyMOL>    print(i)
    2:    print(i)
PyMOL>python end
PyMOL>python end
0
1
```

The `PyMOL>` lines are an echo *after* reading, not a prompt —
`pymol/parser.py:493-501` reads with a bare `for line in stream:` and never writes
one — and the `    N:` lines are the block echo at `pymol/parser.py:210`
(`"%5d:%s"`). Moot in practice: pymol draws nothing after output, so `promptFor`
refuses it outright, which `scrollback_spec.lua:122` pins.

### Why (a), accepting the echo, is rejected

Recorded for the file, not re-proposed. The echo is the common case, not an
occasional hand-typed multiline: every `<CR>` on a visual selection or a
treesitter-extracted block goes out as one paste. Pasting the user's own source
back as comments, one line short, is worse than pasting nothing.

### Why a whitespace continuation cannot be matched

The old table's `radian = { "> ", "  " }` and `julia = { "%a*%??> ", "  " }` are
the shape a revert would restore, and the two REPLs this config actually uses are
the two where it is unsound. Neither prints a continuation prompt at all.

- radian passes no `prompt_continuation` to prompt_toolkit
  (`radian/prompt_session.py:209`, `:245`, `:267`), which falls back to
  `continuation = " " * width` (`prompt_toolkit/shortcuts/prompt.py:1325-1328`);
  `radian/settings.py:36-64` has no continuation setting and the package has no
  `continuation` symbol.
- julia's `LineEdit.Prompt` (`REPL/src/LineEdit.jl:43-61`) has no continuation
  field. The prompt is written once for the whole buffer (`:607`) and each further
  line is placed with `cmove_col(termbuf, lindent + 1)` (`:643`) — measured on a
  pty as `\r` then `ESC[7C`, zero prompt characters.

Either way the capture is a blank prefix as wide as the prompt, because kitty
renders the cells the cursor skipped — and ordinary output is indented too.
Measured in the same sessions as the table above:

```
 ❯ Dict(:a=>1,:b=>2)          ❯ = julia, prompt width 4
Dict{Symbol, Int64} with 2 entries:
  :a => 1                     ← 2 spaces: eaten by the old "  " entry
  :b => 2

R❯ print(matrix(1:4,2))       prompt width 3
     [,1] [,2]                ← 5 spaces: eaten by "  " and by "   "
[1,]    1    3
[2,]    2    4
```

Deriving the pad from the prompt width — which `promptFor` already has, since
`prompt_at_cursor` measures it (`kitty.lua:216-228`) — does not save it either:
4 spaces is safe against julia's 2-space `Dict` output but 3 spaces eats radian's
5-space matrix header. Plan 11 § Rejected reached the same place from the other
three directions (probing kills lua and pymol; inferring from the scrollback picks
`[1` over `+ ` in R; asking radian returns `getOption("continue") == "+ "` while
it renders 3 spaces).

### The continuation strings are user-settable

Measured in a live kitty window, one program per window:

```
> _PROMPT2 = "ZZ "              >>> import sys; sys.ps2 = "ZZ "   > options(continue="ZZ ")
> for i=1,1 do                  >>> if 1:                         > for (i in 1:1) {
ZZ print(i)                     ZZ     pass                       ZZ print(i)
ZZ end                          ZZ                                ZZ }
1                               >>>                               [1] 1
>                                                                 >
```

`lua`'s `_PROMPT2` (re-read at every prompt; nil by default, the defaults being
compiled in), python's `sys.ps2` (`code.py:218-220` on 3.12,
`_pyrepl/main.py:52-53` and `_pyrepl/readline.py:390-393` on 3.13+), R's
`options(continue=)` (documented non-empty, so it cannot be blanked), ipython's
`prompts_class` (`IPython/terminal/interactiveshell.py:382`, rendered at
`IPython/terminal/prompts.py:54-82`) and the shells' `PS2` are all honoured. So a
shipped default carries the same failure mode that `01c126a` deleted
`config.match.prompt` for. Only julia, radian and pymol have no lever at all —
which is why they get no entry.

What is different is *which* prompts this user configures. The primary prompts
were wrong out of the box because they are customised — `config/radian/profile`
sets `radian.prompt`, `radian.shell_prompt` and `radian.browse_prompt`. No
continuation prompt in the tree is: `config/R/Rprofile` sets `max.print` and
`repos` and no `continue`; `$PYTHONSTARTUP`
(`colors/current/pythonstartup.py`) sets only `_colorize` theming and no `ps2`;
`config/ipython/profile_default/ipython_config.py` sets banner, shortcuts and
colours and no prompt options; `grep -rn PS2 zsh/ shell/` is empty.

## Settle first

Nothing open. The three decisions this plan needed are recorded here.

**Continuation strings are assumed, not detected.** They are customisable —
`_PROMPT2`, `sys.ps2` and `options(continue=)` all render, measured above — so a
shipped default can be wrong the way `config.match.prompt` was. Detecting one is a
`TODO.md` item, unplanned; a user override in the table is the workaround. It does
not fire in this tree, per the paragraph above.

**No `zsh`/`bash`/`sh` continuation entries.** A raw multi-line send to `zsh -f`
does echo `for> echo $i` / `for> done`, and zsh's default `PS2` of `%_> ` renders
the open construct (`%_` is "the shell constructs that have been started on the
command line", `man zshmisc`), so the old table's `%a*> ` would still work. Against
it: bash's default `PS2` is the bare `> ` (5.3 and the system 3.2 alike, and
`/bin/sh` is that bash in posix mode), common enough at the start of a line of
shell *output* — a quoted mail body, a `diff` — to eat it. Decided: no entries, an
integrated shell going through `last_cmd_output`, which needs no prompt knowledge
at all.

Their history readers are weaker than a "so `[r` never reaches `parseScrollback`"
argument would imply: `zsh/zshrc.zsh:44-46` sets `HISTSIZE`/`SAVEHIST` and
`unsetopt share_history`, with no `inc_append_history` or `append_history`, so zsh
writes `.zsh_history` on exit only. A live shell REPL's file therefore holds
nothing from the current session, and `M.read` (`scrollback.lua:96-98`) prefers a
non-empty file, so `[r` there recalls *previous* sessions and never falls back to
the scrollback. Recorded as a separate `TODO.md` item, not fixed here.

## Do

**One mechanism per problem.**

- **`[r`** gets `config.continuation`. `parseScrollback` is only ever reached when
  a program has no history reader — `M.read` (`scrollback.lua:96-98`) returns early
  once the reader produced entries — and `history.lua:191-198` lists the six that
  have one. What is left is python, r, lua and pymol: exactly the programs that
  print a marker or re-echo their prompt, so the table covers every program that
  *prints* one, and julia and radian need no entry. Not a partition by program —
  the programs that would need the unsound whitespace entry never arrive here.

  Two other routes reach `parseScrollback` and the table does not help them: an
  unnamed program, `config.continuation[nil]` being nil; and any of the six reader
  programs whose file is empty, which for zsh is the normal state (`zsh/zshrc.zsh`
  has no `inc_append_history` — a separate `TODO.md` item). § 2's "the edge this
  leaves" carries both; they degrade to today's first-line recall, not to something
  worse.
- **`pasteOutput`** gets a memo of the block the plugin transmitted. It knows the
  source exactly, so no marker, no file, no `# mode:` filter and no shared-file
  hazard, uniform across every program including the two that print no marker.

The table is reused as a second chance on the paste path, in the same walk rather
than as a fallback chain — see step 5. That is one table serving two paths, not a
per-program hybrid.

### 1. `config.continuation`

A program-keyed Lua pattern for the continuation prompt at the start of a line, in
`config.lua` beside `prompt` (`config.lua:167-171`). A sibling table rather than
restored pairs: `config.prompt` is an *override*, empty by default and learned
otherwise, while this one is shipped and is not learnable. Pairs would force a user
overriding one to supply the other.

```lua
continuation = { python = "%.%.%. ", ipython = " *%.%.%.: ", r = "%+ ", lua = ">> " },
```

`ipython`'s leading spaces are variable: `prompts.py:54-82` pads `...:` out to
`fragment_list_width(in_prompt_tokens())`, so the marker is `   ...: ` at
`In [1]: ` and `    ...: ` at `In [10]: ` — both measured.
`prompt_line_number_format` (default `""`, `interactiveshell.py:746`) would put
non-space text in that pad and break the pattern; that is what the override table
is for. No `julia`, `radian` or `pymol` entry; a nil entry means "no marker", not
"no continuation handling".

Match a line **right-padded**, for the same reason and by the same mechanism as
plan 15's `isIdlePrompt` (15 § Do, "Right-pad the candidate line, not the
pattern" — pad the candidate to the marker's rendered width at the match site, and
leave every pattern constructor alone). kitty drops the trailing blanks of a
capture's final line only, and the final line is a continuation line whenever the
block has not been submitted yet — measured in ipython, where the plugin's send
leaves the cell open and the capture ends `   ...:`.

`config.continuation` values are user-supplied Lua patterns, so the tolerance
cannot live in the shipped pattern strings; padding the candidate is what keeps an
override from having to spell it.

### 2. `parseScrollback` absorbs the run below the anchor

Restores `01c126a^`'s shape, with the pattern from `config.continuation` instead of
`config.match.prompt[program][2]`. Add `continuation` to the module state
(`scrollback.lua:15-19`) beside `prompt`, set in `M.read`
(`scrollback.lua:94-101`) from a new local

- `continuationFor(program) -> string|nil` — `"^" .. config.continuation[program] .. "()"`,
  the same anchoring and position capture `promptPattern` (`scrollback.lua:27-29`)
  applies, so `line:sub(m)` gives the source line back. Named `…For` to match the
  file's existing split: `promptPattern(rendered)` is a pure constructor,
  `promptFor(win, program, text)` is the one that consults `config`
  (`scrollback.lua:27,53`). Test the entry with `if override then`, not `~= nil` —
  `false` is this codebase's way to drop a shipped default (`config.lua:42-43`,
  `repl.lua:41-43`), and this is the first program-keyed table with shipped
  defaults that gets string-concatenated.

and in `parseScrollback`, once the prompt matches, walk the accumulated below-lines
forward, appending `line:sub(m)` while each matches, stopping at the first that does
not. Update the doc comment (`scrollback.lua:104-106`), which states the loss as a
fact.

**Drop a trailing empty line from the walk.** The submitting newline renders as one
bare continuation line — `tests/fixtures/repl/scrollback/python.txt:7` is `... `,
and `ipython.txt:13` the same — which matches the pattern and yields `""`, so
`def f():` would otherwise recall as `{"def f():", "    return 1", ""}`. That is the
submit keystroke, not content. Dropping it is the same call this plan already makes
on the paste path, where `post` stays out of the memo; making it in one place and
not the other is the inconsistency to avoid. Only a *trailing* empty is dropped — a
blank line *inside* a block is real content.

**A limitation this shares with the anchor.** An output line matching the
continuation pattern directly below the anchor is absorbed into the recalled
command: `print("... hi")` in stock python puts `... hi` immediately under it.
Narrow, and the exact counterpart of the exposure plan 15 records for the primary
prompt (`scrollback.lua:104-106`) — recorded there, not closed here.

**The edge this leaves.** `M.read` falls back to the scrollback when the history
read comes back *empty*, not only when there is no reader, so a julia or radian
window whose history file is missing or empty does reach `parseScrollback` with no
marker available — a radian window where `.radian_history` was never created, since
radian writes beside the session only if the file already exists
(`history.lua:126`, `repl.sh:72`); a julia window with `JULIA_HISTORY` pointing
nowhere; an ipython window on a machine without `sqlite3` (`history.lua:167-180`).
Those recall the first line only, which is today's behaviour and is what plan 11
accepted. Giving them a whitespace entry would not fix it — measured above, it eats
their output. Recorded, not closed.

### 3. Where the memo is written

Not `commands.run`/`commands.paste` (`commands.lua:47`, `:59`): three of the shipped
`config.custom` senders change the text before it leaves, so buffer text is not what
the REPL echoes.

- `config.lua:87` strips `local ` — required, not cosmetic: measured in lua 5.5,
  `local y = 5` at the prompt warns "locals do not survive across lines in
  interactive mode" and `print(y)` gives `nil`. A memo holding `local x = 1` would
  not match the echoed `x = 1`.
- `config.lua:80` wraps a pymol block in `python` / `python end`, both of which are
  echoed (capture above).
- `kitty.lua:132-137` sends a `linewise` program its non-empty lines only, so a
  block with a blank line inside it echoes fewer lines than the buffer holds.
- `config.lua:93` only forces bracketed; text unchanged.

Not `send_raw` (`kitty.lua:101-103`) either, though it is the true transport:
`commands.lua:18` and `M.sendCustom` (`commands.lua:299-304`) push keystrokes —
`"q"`, `\x0d`, `\x04`, `\x03` (`init.lua:92-95`) — straight through it, so a memo
written there is clobbered by a keypress; and `linewise` reaches it once per line,
so a memo would need framing from above anyway.

**`kitty.send` (`kitty.lua:120-142`) is the seam that knows what was transmitted**,
being the one place aware of both which branch ran and what that branch produced.
But it should not *write* the memo. `kitty.lua:2-4` declares itself low-level
transport with the window binding living in `repl.lua`, and `repl.lua:9` requires
`kitty` — which is why writing from there needs a deferred require to dodge a
cycle. Inverting the layering to save three call sites is the wrong trade.

Instead **`M.send` returns the lines it transmitted** — it already has them in
every branch — and `commands.run`, `commands.paste` and `sendLines` call
`repl.remember_block(win, lines)`. `sendLines(kitty.run)` (`commands.lua:147-158`)
captures the return the same way.

That also fixes what writing inside `send` would get wrong: context sync goes
through this seam. `sync` (`commands.lua:32`) calls
`kitty.run(win, program, entry.code)` at `:34`, and `kitty.run` is
`M.send(win, program, text, '\n', raw)` (`kitty.lua:149-151`) — so sync lines would
write the memo. Today that is harmless only because `sync` precedes the user's send
in all four of its callers (`commands.lua:46`, `:58`, `:151`, `:278`), an invariant
nothing states or enforces. `runHelp` (`commands.lua:279`) has the same shape, its
memo being the help command. With the write at the call sites, neither touches the
memo and the invariant stops mattering.

**`config.custom` gains a return value:** `fun(win, text, post): string|nil`, the
text it transmitted, `post` excluded. The three shipped senders return one line
each; a user sender that returns nothing leaves the memo nil, and that program's
paste path falls back to step 5's marker predicate. Update `README.md:114-117`,
which documents the signature.

The custom sender returns a *string* while `repl.remember_block` takes lines, so
say who splits: `M.send` does, on `\n`, so every branch hands `remember_block` the
same shape and a custom sender is not asked to know about the memo's units.

`post` stays out of the memo. A submitting newline renders as one bare
continuation line — `... ` for python, `   ...: ` for ipython, both measured — and
step 5's marker predicate is what absorbs it. Folding it in as a trailing empty
memo line does not work: an empty line right-trim-suffix-matches anything, so R's
first output line `[1] 1` would be eaten.

### 4. The memo in the registry

A `block` field beside `sent` and `prompt` (`repl.lua:12-16`), with
`repl.remember_block(win, lines)` and `repl.block(win)`.

**It belongs in `remember`'s clear** (`repl.lua:103`), which already nils `sent`
and `prompt` when a window's program changes: a different program echoes
differently, and a block transmitted to the old one describes nothing.

It is in-memory only, so after an nvim restart the memo is nil and step 5 runs on
the marker alone.

A `paste` the user then edits at the prompt before running is handled by step 5's
first-line check, not by invalidation: edit the first line and nothing is dropped;
edit a later line and the walk stops there, leaking one echo line rather than eating
output.

### 5. One walk, three predicates

This step ships the predicate; plan 15 ships its only caller. `lastOutput` is born
in 13 as `lastOutput(text, pattern, echo)`, where
`echo: fun(anchorText: string, below: string[]) -> integer` is how many lines
directly below the anchor are the echo of the anchored command, and 13 skips that
many. Nothing here waits on 13: both units below are pure functions of their
arguments and are tested directly.

- `echoedLines(block, pattern, width) -> fun` — walk `below` from the anchor down,
  taking a line if **any** predicate holds, stopping at the first line where none
  does. `i` indexes the memo and starts at **2**, `block[1]` being the anchor line
  itself, which is not in `below`. `block` may be nil, `echoFor` being buildable
  from a pattern alone.
  - **(a) the memo.** `block[i]` right-trimmed is a suffix of the accumulation
    right-trimmed, `i` advancing and the accumulation resetting only on a match.
    Suffix because what the REPL adds is a *prefix* — the pad or the marker. An
    empty `block[i]` matches only an empty accumulation, never anything else.
  - **(b) the marker.** The padded line matches `pattern`.
  - **(c) the wrap fragment.** The preceding line's display width equals `width`;
    strip the pad and append to the accumulation, leaving `i` where it is.
  - Discard the memo up front unless `block[1]` right-trimmed equals `anchorText`
    right-trimmed. That one check is what makes a stale memo harmless.
- `echoFor(window, program) -> fun|nil` —
  `echoedLines(repl.block(window.id), continuationFor(program), window.columns)`,
  nil only when both `block` and `pattern` are absent. Plan 15's `pasteOutput` calls
  it directly: it holds the record and `program` already, and `lastOutput` stays a
  pure function of its arguments. It is deliberately *not* folded into
  `readWithPrompt`, whose name promises reading and prompt-learning only.

**Contiguous and from the anchor down**, never "drop every matching line": an output
line that happens to match must not punch a hole in the middle of the output.

Measured, per program, for the block-just-sent state with every line fitting the
window — memo lines are what the branch transmitted, `post` excluded. Predicate (c)
fires on no row here; the over-wide rows are below:

| program | memo | below the anchor | by (a) | by (b) | left as output |
|---|---|---|---|---|---|
| julia | 3 | `        println(i)`, `    end`, `1`, `2` | 2 | 0 | `1`, `2` |
| radian | 3 | `       print(i)`, `   }`, `[1] 1`, `[1] 2` | 2 | 0 | `[1] 1`, `[1] 2` |
| ipython | 2 | `   ...:     print(i)`, `   ...: `, `0`, `1` | 1 | 1 | `0`, `1` |
| python | 3 | `...     a = 1`, `...     return a`, `... ` | 2 | 1 | none → "no output" |
| r | 3 | `+     print(i)`, `+ }`, `[1] 1`, `[1] 2` | 2 | 0 | `[1] 1`, `[1] 2` |
| lua | 4 | `>>   x = i`, `>>   print(x)`, `>> end`, `1`, `2` | 3 | 0 | `1`, `2` |

julia and radian are carried entirely by (a), which is the point: they have no
marker. python and ipython need both, (b) taking the bare submit line that no memo
line corresponds to. lua needs (a) because its memo is post-transform. Every row is
from a capture in this plan's harness, not derived.

**Warn once when a rule was available, the block was multi-line, and nothing was
dropped.** Silently pasting your own code back as comments is the failure this plan
exists to stop, and it should be visible rather than reading as a mangled REPL.

All three conditions are load-bearing. Without `#block > 1` the warning fires on
every single-line command — `block = {text}`, `block[1] == anchorText`, nothing
below to drop — and so on every `r`, `lua` or `python` command, and on `runHelp`
(`commands.lua:279`), whose memo is the help command. The pattern branch alone can
never justify a warning either: a block typed by hand at the prompt leaves no memo
to compare against.

**An over-wide input line is re-rendered as several hard lines, and (c) is what
takes them.** The earlier draft claimed line counts were wrap-independent, on the
strength of a julia measurement — a 308-column continuation line inside a bracketed
block came back as one line of the capture. That holds for julia, which soft-wraps,
and does not generalise: prompt_toolkit re-renders a too-long input line as its own
*hard* lines, so no terminal rejoins them. Measured in a 40-column pane, `tmux
capture-pane` with and without `-J` (which joins soft wraps, as `--extent=all`
does):

```
ipython   len=40  '   ...:         x = 'aaaaaaaaaaaaaaaaaaa      <- full width
          len=34  '      ⋮ aaaaaaaaaaaaaaaaaaaaaaaaa''          <- fragment, not joined
radian    len=40  '     print('aaaaaaaaaaaaaaaaaaaaaaaaaaaa      <- full width
          len=21  '   aaaaaaaaaaaaaaaa')'                       <- fragment, not joined
```

`-J` joins radian's *banner* in the same capture, so those two really are hard
lines and not a capture artefact. Without a third predicate the fragment matches
neither (a) — it is a middle, not a suffix, of the memo line — nor (b), and the
walk stops there, pasting the rest of the echo back as comments. That is this
plan's own failure mode, on the two REPLs `config.command` makes primary.

- **(c) the wrap fragment.** Strip the pad and append to an accumulation, which (a)
  then tests as a suffix instead of a single line. Gated on the preceding line
  having display width equal to the window's `columns`: **a line shorter than the
  width cannot be followed by its own wrap fragment.**

The pad is one number, the prompt's rendered width, which the anchor match already
yields as `mPrompt - 1` — measured equal for the prompt, the marker and the wrap
pad in every case (ipython 8: `In [1]: `, `   ...: `, `      ⋮ ` — the last by
construction, `" "*(width-2) + "⋮ "` at `IPython/terminal/prompts.py:77-83`; radian
3; julia 4). So ipython's `⋮` needs no `continuation` entry: stripping 8 columns
removes `      ⋮ ` outright.

Keep (a) a *suffix* test against the accumulation, not an equality test: ipython
auto-indents, so `    x = …` sent comes back echoed as `        x = …`, and equality
would fail on exactly the lines (c) exists for.

`columns` is already in the `ls` record (`kitty @ ls` window keys include `columns`
and `lines`), so the gate costs no extra call — but `echoFor` now needs it, so it
takes `window` rather than `win`. Use `vim.fn.strdisplaywidth`, not `#line`: `⋮` is
multibyte, and `kitty.lua:224` already sets that precedent.

**What (c) trades.** Two independent conditions must hold for an output line to be
absorbed: it directly follows a line that filled the width exactly, *and* stripping
the pad makes it complete a line actually sent. A false positive on the width gate
alone is harmless — (a) still gates, and the walk stops. `cat("   hi\n")` in R needs
both at once. This is not airtight and is not meant to be; it is the same class of
hazard plan 15 already accepts for the anchor, narrowed. ipython, python, r and lua
carry a marker as independent confirmation; **radian and julia rest on the width
gate alone**, having no marker at all.

Resizing the window between the send and the capture invalidates the gate. It fails
toward leaking echo, not toward eating output, which is the right direction — the
warning below fires and nothing the REPL printed is lost.

**The residual gap: a multi-line command typed by hand at the REPL.** No memo, and
julia and radian have no marker, so none of the three predicates fires — (c) needs
the memo too, having nothing to accumulate towards — and the echo is included in the
paste, with the warning. Narrow — the plugin exists so that blocks are not
typed at the prompt, and `radian.auto_indentation=FALSE` in this config makes doing
so awkward — and everywhere a marker exists (python, r, lua, ipython) predicate (b)
covers it unaided. The history entry would close it; § Out of scope says why it is
not worth the cost here.

### 6. Documentation

- `README.md:236-237` ("Off the screen a multi-line command recalls as its first
  line, the continuation prompt not being measurable this way") is what step 2
  falsifies. Rewrite: recall off the screen keeps a multi-line command whole for a
  program with a `continuation` entry, and gives its first line for one without.
- Add `continuation` to the program-keyed list at `README.md:68` and to the
  `### Program-keyed` reference beside `prompt` (`README.md:118-121`), saying what a
  nil entry means and why julia and radian have none.
- Update the `custom` entry (`README.md:114-117`) for the return value.
- `README.md:243-244` ("Recall needs nothing, unless the REPL keeps a history file
  worth a `history` entry") is the adding-a-program checklist, and stops being true
  for a marker-printing REPL that now wants a `continuation` entry. Add that
  condition beside the history one.
- `config.lua:6-9` enumerates the program-keyed tables in the file header and must
  gain `continuation` — a code comment, but it is the same index the README list
  mirrors, so it belongs in this step rather than being found later.

## Test

**Fixtures.** `tests/fixtures/repl.sh` drives R (`:95-103`) and lua (`:105-113`)
with single-line commands only, so no committed fixture carries a `+ ` or `>> `
line. Add a multi-line block to each with `send`, not the `paste` helper
(`repl.sh:18`): R is `bracketed = false` and lua goes out raw through its `custom`
sender, so an unbracketed send is the path under test.

Add to the julia and radian sessions the command whose output the whitespace
decision rests on — `Dict(:a=>1,:b=>2)` and `print(matrix(1:4,2))` — so the
fixtures themselves carry the evidence that a blank-prefix pattern would eat real
output. That shifts what `entries(2)` returns at `scrollback_spec.lua:98` and `:103`
by one command; update them.

Capture the ipython cell-still-open shape too: a bracketed block with no submitting
newline after it, whose capture ends `   ...:`. It is the case where the echo is the
capture's *tail* rather than sitting above output.

**Capture an over-wide block for radian and ipython**, the two shapes predicate (c)
exists for and the two REPLs `config.command` makes primary. radian is the one that
matters: it has no marker, so it rests on the width gate alone, while ipython's `⋮`
confirms independently. Drive them in a *narrow* pane so the fixture stays legible —
40 columns reproduces both, and the fixture must record the pane width beside the
text, since the gate compares against `window.columns` and a fixture without it
cannot be replayed. julia needs no such fixture: it soft-wraps, so `--extent=all`
rejoins it and (c) never fires.

**`parseScrollback`.** The existing per-program walks are the tests; the assertions
change to whole commands for python (`scrollback_spec.lua:88`), ipython (`:93`), r
and lua, and stay first-line-only for radian (`:98`) and julia (`:103`) with a
comment naming why — no marker exists, and their real path is the history reader.

**The memo.** Assert `repl.block(win)` after a `kitty.send` per branch, `util.exec`
stubbed: bracketed, linewise (a block with a blank line inside → the non-empty lines
only), each shipped `custom` sender (lua's `local` stripped, pymol's wrapper lines
present, julia's text unchanged), a `custom` returning nil → nil memo, and
`remember` clearing it on a program change.

**`echoedLines`.** A pure function of `(block, pattern, width)`; assert it directly
rather than through `lastOutput`. One case per row of the table above, plus:

- memo only, no pattern (julia, radian) → the memo's run
- pattern only, no memo (a hand-typed block in r) → the marker's run
- neither → 0
- a stale memo whose first line differs from the anchor → 0, warns
- a memo whose third line was reformatted → stops at 2, leaks one line rather than
  eating output
- an output line matching the pattern *below* real output → not dropped, the run
  being contiguous from the anchor
- an empty memo line against a non-blank line → no match, the hole that would let a
  blank memo line eat `[1] 1`
- a single-line block → 0 dropped and **no** warning, the condition that keeps the
  warning off every ordinary command

and for predicate (c):

- radian's over-wide fixture → the fragment is absorbed and the memo line matched
  across two capture lines
- ipython's, where the same fragment is *also* reachable by its `⋮`, confirming the
  pad strip and the marker agree
- the width gate refusing: the same fragment line preceded by a line one column
  short of `width` → not absorbed, walk stops
- the adversarial-ish real case: an output line with leading whitespace directly
  below a full-width line, which does not complete a memo line → not absorbed
- an input line exactly `width` columns that did *not* wrap → the next line is
  tested and rejected by (a), no output eaten

## Verify

- `make test` passes
- `[r` in a hand-started stock `R`, `python` and `lua` window recalls a multi-line
  command whole and runnable, not its first line
- `[r` in radian and julia is unchanged (still the history file, still whole)
- `<CR>` on a 20-line block in radian, then the `pasteOutput` keymap: the output
  only, no commented copy of the block
- Same in julia, whose continuation is a 4-column blank and whose `Dict` output is
  indented 2 — the block dropped *and* the indented output kept
- Same in ipython at a two-digit cell number, where the marker widens
- Same in a stock `python` window, where the block is sent line at a time and the
  bare `... ` needs predicate (b)
- `<leader>rp` a block, edit a middle line at the prompt, run it, then the keymap —
  one leaked line, not eaten output
- A multi-line block typed by hand into radian, then the keymap — the residual gap:
  the echo is included and one warning is issued
- The same block typed by hand into stock `R` — covered by (b), no leak
- **A block with a line wider than the window**, in radian and in ipython, narrowing
  the window first so it is easy to hit — predicate (c). radian is the real test,
  having no marker to fall back on
- **The same block after resizing the window between the send and the keymap** —
  the gate's stated failure: echo leaks, warning fires, no output lost
- pymol: the keymap is refused by `promptFor` as it is today

## Out of scope

- **The history entry as a third route.** It would close the residual gap — a
  hand-typed block in julia or radian — and nothing else, at the cost of a file read
  on every miss plus a `kitty @ ls` for radian, whose file is resolved from the
  window's cwd (`history.lua:131-138`); it is also the only route with a `# mode:`
  filter (`history.lua:195-196`) and a shared-file hazard (`README.md:225-229`), both
  of which would need the same first-line check the memo already carries. Revisit if
  the gap is felt.
- **Detecting the continuation string** rather than assuming it. `TODO.md` item;
  plan 11 § Rejected closed all four routes and nothing measured here reopens one.
- **ipython's cell staying open after a multi-line send.** Measured: the plugin's
  `send_bracketed(win, text, "\n")` leaves `In [1]:` open at `   ...:`, and a further
  newline is what submits it — already noted at `tests/fixtures/repl.sh:59`. A live
  send-path bug, not this one; step 5 handles the capture shape it produces.
- **zsh writing its history only at exit**, so `[r` in a shell REPL recalls previous
  sessions. Separate `TODO.md` item.
- **Plan 13's known limitation that an output line can match the *primary* prompt**
  and become the anchor. A different pattern against a different line; the
  continuation run is only ever read relative to whatever anchor it picked.

## Relationship to plan 15

**This lands whole, before 15, and nothing in it waits on 15.** The earlier draft
had step 5 building `echoFor` inside plan 15's read-and-learn unit (then called
`readScrollback`, now `readWithPrompt`), which made the two
plans mutually blocking. They are not: this plan owns everything that knows what a
continuation prompt is, including both units of step 5, and both are pure functions
tested directly. Plan 15 owns the cut, and calls `echoFor` from `pasteOutput`.

The one thing 15 must do for this plan is be written with `lastOutput`'s third
parameter from the start — it is (15 § Do, "Name the units") — rather than gaining
it afterwards.

`repl.lua` is touched by both this plan and 13, textually but not semantically: 13
rewords `remember`'s docstring at `:92-93`, this adds `block` to the clear at
`:103`. Whichever lands second rebases trivially.
