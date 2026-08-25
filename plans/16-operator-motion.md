# 16 — Consume the motion when there is no REPL

**Goal:** make the run and paste operators do nothing, rather than edit the
buffer, when the buffer has no REPL. **Depends on:** nothing. **Blocks:** nothing.

## The problem

`init.lua:82-83` maps the two operators as `detect.replCheck(operator(...))` with
`expr = true`. `replCheck` (`detect.lua:44-52`) warns and falls off the end,
returning `nil`, when neither `repl.revalidate()` nor `detect_REPL()` finds a
window. An expr mapping that returns nothing arms no `g@`, so `operatorfunc` is
never consulted and the keys typed after the prefix are read as ordinary normal
mode commands.

So the cost is not the wasted keystroke the TODO records. Whatever the user typed
runs as itself. Measured on `alpha beta` / `gamma delta`, cursor (1,0), the expr
returning nil:

```
<CR>ap  -> "aplpha beta"      <CR>j   -> unchanged, cursor (2,0)
<CR>iw  -> "walpha beta"      <CR>gn  -> unchanged, now in visual mode
```

`<CR>ap` is the TODO's own example, so the headline case edits the buffer. Typed by
hand `<CR>aw` also leaves the user *in* insert mode, where a `feedkeys` spike ends
it the way `:normal!` does.

**No enumeration of which suffixes are dangerous belongs in the fix, or here.** The
above is evidence that the bug is real, not a taxonomy to act on: the suffix is
arbitrary, it can come from a plugin, and `:h text-objects` is not the closed set it
looks like (`gn`/`gN` take an operator without the `a`/`i` prefix). The fix consumes
whatever follows, uniformly, by arming `g@` every time.

## Do

**Move `replCheck` off the mappings and onto the operator functions**
(`init.lua:36-42`), so the expr always returns `g@` and the motion is consumed
whether or not a REPL answers:

```lua
-- The REPL check is here rather than on the mapping: an expr mapping that returns
-- nothing leaves the motion keys to normal mode.
M.operator = {
    run = detect.replCheck(function(type) commands.runOperator(type) end),
    paste = detect.replCheck(function(type) commands.pasteOperator(type) end),
}

local function operator(key)
    return function()
        vim.o.operatorfunc = "v:lua.require'kittyREPL'.operator." .. key
        return "g@"
    end
end
```

with `nmap(c.keymap.run, operator("run"), …, true)` and the same for paste.

**No global is needed.** An earlier draft asserted `v:lua` requires one and
introduced `ReplOperator`. It does not: `v:lua.require'kittyREPL'.operator.run`
arms and fires, receiving `"char"` — verified on the nvim in use (0.12.4). Hanging
the table off `M` instead *removes* the two existing globals
(`init.lua:36-42`) rather than adding a third, and keeps the operators beside every
other `replCheck`-decorated keymap in `init.lua`.

Wrapping each in a thunk rather than passing `commands.runOperator` directly
resolves the function per call, which is how the current
`function ReplRunOperator(type)` wrapper behaves. Nothing stubs
`commands.runOperator` today, but the specs stub module fields elsewhere, so a
direct reference captured at require time would make such a test silently miss.

The check has to wrap `runOperator` rather than move inside it: the first thing
`runOperator` does is yank the motion's text into register `k`
(`commands.lua:238-242`), and the last is a `progress` cursor move, neither of
which should happen without a REPL to send to.

`vim.o`, not `vim.opt` — `operatorfunc` is a plain global string, and `init.lua:30`
is the only `vim.opt` in `lua/` (`commands.lua:106` already uses `vim.o.shell`).

**The warning arrives after the motion.** Consequences:

- A motion the user aborts (`<Esc>`) or never completes warns nothing, where
  today the prefix warns on its own. The detection round trip is skipped with it.
- `detect_REPL`'s attach now happens after the motion is read, which nothing in
  the motion depends on. Writing `b:repl_win` from an operatorfunc is not
  textlocked.
- **Dot-repeat becomes guarded**, which is the change this shape buys on the
  *attached* path. `.` re-enters the operatorfunc without re-evaluating the expr
  mapping, so `replCheck` is bypassed on a repeat today: send with `<CR>ap`,
  close the REPL window, press `.`, and it sends into the dead window because
  `repl.program` serves the cached name. Under the fix the repeat warns — and, if
  another window is running a claimed program, `replCheck` falls through to
  `detect_REPL`, which attaches it. So the guarded repeat can silently retarget
  rather than merely refuse, and it now costs one `kitty @` round trip where today
  it runs off cached identity.
- **`g@` sets `'[`/`']` and consumes the redo slot** whether or not the
  operatorfunc does anything. Measured: `x`, then a no-op `g@aw`, then `.` repeats
  the no-op operator rather than the `x`. Today a pure-motion suffix (`<CR>j`)
  leaves redo intact. Accepted — the alternative is not arming `g@`, which is the
  bug.

**The cursor moves on a backward-reaching motion**, and this one is worth fixing
rather than keeping. `g@` moves the cursor to the start of the operated range
*before* calling the operatorfunc, so the guard cannot prevent it. Measured from
(2,5) on a four-line buffer with a no-op operatorfunc:

```
g@b  -> (2,0)      g@aw -> (2,5)
g@ge -> (2,3)      g@j  -> (2,5)
g@{  -> (1,0)      g@w  -> (2,5)
g@ap -> (1,0)
```

`ap` is in the moving column, and `<CR>ap` is the TODO's own example — so "does
nothing" would still jump the cursor to the paragraph start on the headline case.
Save the position in `operator()` before returning `g@` and restore it in
`replCheck`'s failure path. Restoring unconditionally would fight `progress`,
which moves the cursor deliberately on the attached path.

## Test

A new `tests/plenary/operator_spec.lua`, not a block in `commands_spec.lua`: the
cases need `setup()` to install the maps, which registers an augroup and mutates
`config.keymap`, and `PlenaryBustedDirectory` gives each file its own nvim
process to contain that.

The keymap defaults are `<plug>` maps, so pass a real lhs —
`setup({ keymap = { run = "<CR>", paste = "<C-CR>" } })` — then open a python
buffer to fire the `FileType` autocmd, and press the keys with
`nvim_feedkeys(vim.keycode("<CR>ap"), "mx", false)`. `"m"` is required: `"n"`
would skip the mapping under test.

**The buffer has to be a normal one**, `vim.cmd("enew")` or
`nvim_create_buf(false, false)`. `commands_spec`'s `open()` builds a scratch
buffer, whose `buftype=nofile` is exactly what `init.lua:65` refuses to map, so
borrowing it wholesale gives a spec with no maps in it and three no-REPL cases
that pass without testing anything. Borrow the `kitty.window` stub and
`vim.b.repl_win` from it, not the buffer.

**Stub `util.exec` here too**, as `commands_spec.lua:29` does and for its stated
reason — nothing may reach the developer's terminal whichever config defaults
change. `kitty.get_focused_tab` and `kitty.window` cover today's paths, but this
spec presses real keys and the guard now runs *after* the motion.

Cover, with `vim.b.repl_win` unset and `kitty.get_focused_tab` stubbed to find
nothing. Each case pins a different property — the guard is indifferent to which
suffix follows, so these are shapes to cover, not a list of keys to defend against:

- `<CR>aw` leaves the lines, the mode and the cursor as they were, and warns
  `REPL: none found`
- `<CR>ap`, the TODO's own keys, likewise — **with the cursor off the paragraph
  start**, since that is the case the restore exists for and a cursor already at
  (1,0) passes without testing it
- `<CR>b` from mid-line, the backward-motion case
- `<C-CR>ap` likewise — `run` and `paste` are independent assignments, so a
  transposed function in the paste one is invisible to every run case
- `<CR><Esc>` warns nothing — pinned so the trade above is not read as a
  regression later

And with a window bound, as `commands_spec`'s `attach()` does it:

- `<CR>ap` still sends the paragraph and `<C-CR>ap` still pastes it: the fix moves
  the guard past the point where the motion is resolved, so the working path needs
  cases of its own here
- `<CR>ap`, then the window gone, then `.` warns and sends nothing — the guarded
  repeat, which is a behaviour change rather than a regression and so worth
  pinning

## Verify

- `make test` passes
- with no REPL bound, `<CR>ap` in a python buffer warns and leaves the buffer
  byte-identical *and the cursor where it was*, from a line partway into a
  paragraph, and `<CR>` then `<Esc>` is silent
- with no REPL bound in this buffer but a python REPL running in another kitty
  window, `<CR>ap` then `.` — the repeat attaches that window rather than warning,
  which is `detect_REPL` behaving as designed but is worth seeing once
- with a REPL bound, `<CR>ap` and the paste operator send as before, and
  `progress` still advances the cursor past the sent range
- `<plug>` indirection is what production uses (`README:194`), so check through a
  real `nmap <CR> <plug>kittyReplRun` and not only the spec's direct lhs

## Out of scope

- The other `replCheck` mappings. None is `expr`, so none leaves a motion pending,
  and returning nil from them is already a no-op.
- `operator()` setting `operatorfunc` globally and never restoring it, and the
  `LATER` note above it (`init.lua:26-27`) about passing a function once
  neovim/neovim#20187 lands — still accurate, `vim.o.operatorfunc = <function>` is
  rejected on 0.12.4 with "expected valid option type, got Function". The fix
  widens this: `operatorfunc` is now armed on every prefix press rather than only
  on ones a REPL answered, so a later bare `g@` reaches the plugin for a user who
  never had a REPL.
- `commands.lua:241` yanking linewise for `type == "block"` (`` `[V`] ``), so a
  forced `<C-v>` motion sends whole lines. Pre-existing and untouched here; the new
  spec would be its home if it is ever fixed.
- What the warning says. "none found" reads as a fragment on its own, but it is
  the message every other keymap gives, so it changes for all of them or none.
