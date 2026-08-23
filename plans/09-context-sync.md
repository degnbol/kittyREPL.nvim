# 09 — REPL context sync

**Goal:** keep REPL-side state (`__file__`, `using Revise`, `setwd`) in step with
nvim-side state.
**Depends on:** 02 and 04; wants 05 and 06.
**Reads:** `design.md` § REPL identity, § Config keying axes, § Transport.

## Problem

`HERE = Path(__file__).resolve().parent` runs as a script but not at the REPL.
Generalised: a REPL holds state that should track nvim-side state, and nothing
keeps the two in sync.

| REPL | Code | Tracks |
|---|---|---|
| ipython | `__file__ = "…"` | current buffer |
| ipython | `__name__ = "__main__"` | constant |
| julia | `using Revise` | constant, once per REPL |
| r | `setwd("…")` | nvim cwd |
| pymol | `cd …` | nvim cwd |

## Mechanism

Register per-program hooks returning code. Before sending code to a REPL,
evaluate every hook for that program and send those whose output differs from
what that kitty window was last told.

```lua
config.context[repl][key] = function() return code_string_or_nil end
```

Dedup on last-sent output removes the need for an event model:

- **Constant output** (`using Revise`) differs from nothing on the first send and
  matches forever after — a startup hook with no startup event.
- **Varying output** (`__file__`, `setwd`) resends exactly when it changes — a
  change event with no change event.

So there are no `on_new`/`on_bufchange`/`on_dirchange` events and no autocmds.
One code path; a new kind of tracked state is a config entry, not a new event
type.

Return `nil` or `""` to contribute nothing — treat both as skip, or an empty
string is sent as a bare newline.

## Config surface

Variable assignment is the common case and should not require writing syntax per
hook:

```lua
config.variables[repl][name] = function() return value_or_nil end
config.assign[repl]          = function(name, value) return name .. " = " .. value end
```

Quoting belongs in a shared util function rather than a third config table —
context hooks building `setwd("…")` need the same escaper, and `assign` calls it.

**Do not use Lua's `%q` to build the literal.** It emits `\9` for tab and
backslash-plus-real-newline for newline. Both are Lua-specific and `\9` is not a
valid Python escape. Harmless for today's paths, wrong for any value with
structure. Default to a double-quote/backslash escaper shared by python, julia, r
and lua; make it overridable.

**Render `variables` in `context.pending` at call time, not in `setup()`.**
Desugaring into `config.context` during setup mixes authored and generated
entries in one user-facing table, resolves a name collision between the two
silently by overwrite, leaves stale entries when `setup()` runs twice with a
different `assign`, and forces the spec to call `setup()` — which creates an
augroup and mutates `config.match.prompt` — to test a table transform. Namespace
the cache keys (`var:<name>` vs `ctx:<key>`) so the two tables cannot collide, and
give them an explicit precedence rule.

These tables are program-keyed, joining `bracketed`, `linewise`, `custom`,
`match.prompt` and `match.help` on that axis. Context is a property of the running
program, which after task 04 is the only identity the plugin has.

There is no filetype gating. A hook under `variables.ipython` fires whenever an
ipython REPL is attached, whatever the buffer's filetype — the identity key is the
gate, and attaching is explicit.

## Where it hooks in

All code delivery funnels through `kitty.send` (`kitty.lua`) via `kitty.run`
and `kitty.paste`. Dispatch from the `run`/`paste` wrappers in `commands.lua`,
which task 04 created to resolve identity and 06 extends with the pager probe:

```lua
local function run(text, raw)
    local win, program = repl.current()
    -- pager probe here (task 06), once per user action
    context.sync(win, program)
    kitty.run(win, program, text, raw)
end
```

Dependency direction is `commands → context → kitty`.

Do not dispatch from `detect.replCheck`: it wraps every REPL keymap
(the `nmap`/`xmap` block in `init.lua`) including `focus`, `interrupt` and
scrollback, and syncing
before an interrupt is wrong. Do not dispatch inside `kitty.send`: `context` must
call `kitty` to send, so that is a cycle. Do not add a `send.lua` — see
`design.md` § Transport.

Leave `sendCustom` (`q`, CR, Ctrl-d, Ctrl-c) alone; it uses `kitty.send_raw`
directly and sends keystrokes, not code.

Sync on send, not at launch — `kitty.launch` returns before the REPL can accept
input, so a launch-time send is swallowed. This does not make the first send safe
either: `<CR><CR>` immediately after `<leader>rs` hits the same not-ready REPL. A
swallowed ordinary line is visibly lost and retried, but a swallowed *sync* line
would be silently cached as delivered forever. Record a key only after delivery is
confirmed — hence `mark` separate from `pending`.

Sync before `paste` as well as `run`: a context line executes, then the staged
text sits at the prompt.

## Settle first: does a slow sync line collide with the user's code?

The two `kitty @ send-text` calls are issued back-to-back with nothing between
them, and `using Revise` takes seconds. Byte order is not execution order. The
bytes most likely queue in the tty until the line editor regains control, but this
changes the plugin's current invariant of one block sent to an idle prompt, and it
is untested.

Test it against a cold julia REPL — `using Revise` as the sync line, code sent
immediately after — before designing anything around it. If it collides, poll
`kitty @ get-text --extent=screen` against `config.match.prompt[repl][1]` after a
sync line, bounded at roughly 50 × 20 ms. That cost is paid only on the rare sync,
never on the deduped no-op path.

## State

Per-window state lives in the task 04 registry, not a second table:

```lua
wins[win].sent[key] = last_code_string   -- lua/kittyREPL/repl.lua
```

Keyed by kitty window id, not buffer — one REPL serves many buffers, and that
sharing is why `__file__` goes stale. Task 04 puts program identity in the same
per-window table, so both facts sit together and re-attaching invalidates both.
Not keyed by pid; `design.md` § REPL identity has the reasoning.

Dead windows cannot be sent to, since `replCheck` gates on existence. Entries for
dead ids leak until nvim exits — acceptable, bounded by REPLs per session.

A sync line that errors in the REPL stays cached as delivered, so `using Revise`
without Revise installed errors once rather than on every send.

Every synced line consumes a prompt number and enters history. Dedup keeps this
rare — once per REPL, plus once per buffer switch.

## Errors

Hooks are user config and can throw. `pcall` each; on failure
`vim.notify(…, vim.log.levels.ERROR)` naming the key, skip that hook, continue
with the rest.

## Defaults

```lua
variables = {
    ipython = { __file__ = function()
        local name = vim.api.nvim_buf_get_name(0)
        -- Sentinel, not nil: nil would skip the send and leave the previous
        -- buffer's path in the REPL. Matches the ipython-side exec_lines default.
        return name ~= "" and name or "ipython"
    end },
},
```

Opt out with `false`. `vim.tbl_deep_extend("keep", …)` cannot delete a shipped
default — `variables = { ipython = {} }` keeps it — but an explicit `false`
survives the merge, so treat `false` as disabled.

The ipython side already sets a fallback (`~/dotfiles` commit `130f020`):
`c.InteractiveShellApp.exec_lines = ['__file__ = "ipython"']` resolves `__file__`
to the cwd for every ipython session, including ones nvim never touches. This
plugin then overwrites it with the true buffer path.

**Document the multiprocessing trade-off next to the default.** The `"ipython"`
basename is what makes `multiprocessing.spawn._fixup_main_from_path`
short-circuit instead of re-executing the file via `runpy` in every spawned child.
Overwriting with `/path/to/mymod.py` reinstates that: workers run that file's top
level. For a module with an `if __name__ == "__main__"` guard this matches normal
script execution; for one with unguarded top-level work it does not.

## Tests

Split the module so the testable part touches no kitty, rather than injecting a
fake sender — injection leaves the default path shelling out whenever a test
forgets to inject.

```lua
context.pending(repl, win)   -- -> { {key=…, code=…}, … }  evaluates, filters, pcalls
context.mark(win, key, code) -- records delivery
```

The `run`/`paste` wrappers call `pending`, send each entry, then `mark` — which is
also what makes "record only after confirmed delivery" expressible. Drive both
directly with plain tables. `tests/minimal_init.lua` appends cwd to rtp, and
requiring the module loads `config` without touching a subprocess.

Cases (`tests/plenary/context_spec.lua`):

- constant hook is pending once, empty on the second call after `mark`
- varying hook becomes pending again only when its value changes
- two window ids track independently
- `nil` and `""` returns contribute nothing
- throwing hook notifies and does not suppress the other hooks
- `variables` renders through `config.assign` without `setup()` having run
- same name in `context` and `variables` does not collide under `var:`/`ctx:`
- quoting: embedded `"`, `\` and newline round-trip into a valid literal

## Steps

1. Settle the collision question above. The answer decides whether step 5 needs
   prompt polling.
2. `config.lua` — `context`, `variables`, `assign` tables and the `__file__`
   default; quoting helper in the shared util.
3. `lua/kittyREPL/context.lua` — `pending`, `mark`. No kitty dependency.
4. `repl.lua` — `sent` sub-table per window, dropped when the window is
   re-attached along with the rest of the entry.
5. `commands.lua` — `run`/`paste` wrappers call `pending` → send → `mark`.
6. Tests, then `make test`.
7. README — the three config tables, the `false` opt-out, and the multiprocessing
   caveat beside the `__file__` default.
