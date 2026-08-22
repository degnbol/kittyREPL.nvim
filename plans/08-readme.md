# 08 — README

**Goal:** stop the README documenting a config schema that no longer exists.
**Depends on:** 02, 04, 05, 07 (documents their outcome). **Blocks:** nothing.

## The problem

The README advertises `match.cmdline = { python3 = "python", radian = "r", … }`, a
string→language map that was replaced by the `match.detect` functions. A user
copying it gets a table that is silently ignored and no detection at all.

It also states `bracketed = { python = true, r = true, julia = true }`,
contradicting `config.lua:44`, and omits `linewise`, `custom`, `command_count` and
four keymaps.

## Do

Rewrite against the config as it stands after the tasks above. Include:

- A **config key spaces** section — the filetype/program split from
  `design.md` § Config keying axes, with the reason each table sits where it does.
  This is the thing most likely to be got wrong by a future contributor.
- Every config table, including the ones currently omitted.
- The full keymap list.
- If 09 has landed: `context`/`variables`/`assign`, the `false` opt-out, and the
  multiprocessing caveat beside the `__file__` default.

## Verify

Follow your own README from a clean config: set up the plugin, attach a REPL, send
a line, in at least two languages. Anything you had to read the source for is a
README gap.

## Out of scope

`TODO.md` — it is the plan entry point and is maintained separately.
