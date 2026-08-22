# 00 — Commit the existing working tree

**Goal:** get to a clean tree so every later task's diff is reviewable.
**Depends on:** nothing. **Blocks:** everything.

## State

8 modified files, `Makefile` and `tests/` untracked, `bracketedPaste.sh` deleted.
The uncommitted work is substantial and wanted — do not discard any of it.

## Do

Split into three commits, each self-contained:

1. **kitty-native bracketed paste** — the `kitty.lua` send path plus
   `get_last_output`, and the deletion of `bracketedPaste.sh` that it replaces.
2. **Shell-history scrollback** — `scrollback.lua` history parsing, plus
   `tests/`, `tests/plenary/scrollback_spec.lua`, `tests/minimal_init.lua`,
   `tests/README.md` and `Makefile`, and the `rtps/` entry in `.gitignore`.
3. **Shell detection** — `sh`/`zsh`/`bash` entries in `config.match.detect` and
   the dotted-filetype fallback in `detect.lua`.

Read the actual diff before assigning files to commits; the grouping above is a
starting hypothesis, not a manifest.

## Verify

- `git status` clean afterwards
- `make test` passes
- Open a python and an R buffer, send a line to each — the plugin still works

## Out of scope

Any behaviour change. This task only commits what is already written.
