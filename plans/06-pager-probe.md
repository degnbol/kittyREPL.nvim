# 06 — Pager probe: relocate, extract, measure

**Goal:** probe the pager once per user action instead of once per transport call,
and get the escape-sequence parsing under test.
**Depends on:** 05. **Blocks:** 09 (wanted, not required).

## The problem

`kitty.send` calls `detect_pager()` on every call — a
`get-text --add-cursor` round-trip, ~21 ms. That is per-user-action policy sitting
in per-transport-call code. Once context sync (09) lands, a synced send probes
twice, the second time reading the screen microseconds after writing to it.

The owner runs `closepager = true`, so this is live.

## Do

**Move the probe into the `run`/`paste` wrappers in `commands.lua`**, once per
user action. Task 04 created those wrappers to resolve identity; 09 adds its
context sync alongside:

```lua
local function run(text, raw)
    local win, repl = require("kittyREPL.repl").current()
    -- pager probe
    kitty.run(win, text, raw)
end
```

Do not add a `send.lua` — `design.md` § Transport says why.

**Extract the tail of `kitty.detect_pager` into a pure
`M.is_pager(text) -> boolean`.** This is
the gnarliest untested logic in the repo: it matches a cursor-position escape
sequence against the last line to decide whether a pager is showing. Give it a spec
built from captured `get-text --add-cursor` output — capture real output, do not
hand-write the escape sequences.

**Measure `in_alternate_screen`** (available on the `ls` record after 05) against
the owner's julia + TerminalPager setup. If the pager runs in altscreen, that field
replaces the heuristic outright; if it runs with `-X`, it does not. Record the
result in the commit message either way.

Keep the heuristic regardless — it also covers the `(END)` case.

## Verify

- `make test` passes, including the new `is_pager` spec
- julia `@help` on a long docstring: the pager opens, and the next send closes it
- Count the `kitty @` calls for one `<CR>` (log `util.exec` argv) — one action should
  probe once

## Out of scope

Context sync itself (09). This task only relocates the probe and creates the
wrappers it will use.
