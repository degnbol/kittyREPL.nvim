# TODO

Maybe extend to the ghostty terminal.

`pasteOutput` inserts the whole session: `--extent=last_cmd_output` marks the
shell command that started the REPL. Cut the scrollback on the learned prompt
instead — `plans/15-last-output.md`.

Resolve a REPL running behind a wrapper: `uv run ipython` reports `uv` as its
last foreground process — `plans/13-wrapper-identity.md`.

`<CR>ap` with no REPL attached warns, then lets `ap` run as normal-mode keys and
edit the buffer — `plans/16-operator-motion.md`.

`--copy-env` (`kitty.lua:271`) is untested when `kitty @` reaches a local kitty
from an nvim running over the ssh kitten. Not a direction we use, left untested.

Detect a REPL's continuation prompt instead of assuming the default.
`_PROMPT2`, `sys.ps2` and `options(continue=)` are all customisable, so the
`config.continuation` defaults `plans/14-continuation-echo.md` ships can be wrong.

`[r` in a shell REPL recalls previous sessions, not the current one: zsh writes
`.zsh_history` on exit only (`zsh/zshrc.zsh:44-46` — no `inc_append_history`), and
`scrollback.lua:96-98` prefers a non-empty history file over the scrollback.
