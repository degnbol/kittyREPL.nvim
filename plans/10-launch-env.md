# 10 — Launch environment

**Goal:** make `config.command` programs start with the user's environment.
**Depends on:** nothing. **Blocks:** nothing.
**Reads:** `design.md` § Transport.

## The bug

`kitty @ launch` execs the program with kitty's own environment. Here that is
`PATH=/Applications/kitty.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin` with
`XDG_CONFIG_HOME` unset — the launchd env, not the login shell's. Measured one
window per entry, no `--hold` (the real `kitty.launch` path):

| `config.command` entry | today |
|---|---|
| `python` → `ipython` | starts |
| `julia` | starts |
| `lua` | starts |
| `pymol -xpq` | starts |
| `r` → `radian --r-binary …` | window dies immediately |

The four that work do so because kitty resolves a bare program name server-side
against a richer PATH than the one it hands the child: `ipython` execs as
`~/.local/bin/ipython` while `os.environ["PATH"]` inside it is the bare list
above. Program *lookup* is therefore not the failure — the child's runtime env
is. radian needs `R` on `PATH` (`/usr/local/bin/R`) *and* `XDG_CONFIG_HOME` for
the radian profile; `--copy-env` with `XDG_CONFIG_HOME` removed still dies.

`radian --r-binary <path>` is separately broken, not a kitty problem: radian
0.6.16 exits `Fatal error: R home directory is not defined` for every path tried,
including from a login shell. Plain `radian` finds R itself.

## Do

**Add `--copy-env` to `kitty.launch`** (`kitty.lua:206`). Over remote control this
sends the *client's* environment — nvim's, inherited from the login shell — not
the source window's recorded env, which is what the flag means when used from a
`map launch` in kitty.conf. `kitty @ launch --copy-env`'s own help names it as the
mechanism for this problem, so there is no plugin-side env capture to build.

Drop `NVIM` alongside it with a bare `--env NVIM`. Copying nvim's env otherwise
hands the REPL the parent's server address, and an `nvim` started in the REPL
window then treats itself as nested.

**`config.command.r = "radian"`** — delete the `--r-binary` flag and the
`config.lua:70` comment that motivates it.

## Why not a shell wrapper

`kitty @ launch /bin/zsh -lc 'exec radian'` reports two foreground processes with
the wrapper last, so `repl.lua`'s `cmdline` sees
`["/bin/zsh","-lc","exec radian"]` and `repl.resolve` returns nil. `exec`
cannot help, because the surviving process is not zsh: the first word is the
user's shell, so kitty applies shell integration and runs
`/usr/bin/login -f -l -p <user> …/kitten run-shell --shell /bin/zsh -lc 'exec radian'`.
That wrapper is kitty's own, it stays in the foreground process group, and
`kitty @ ls` reports its cmdline as the shell command it was asked to run.
`/bin/sh -c 'exec radian'` escapes the wrapper — and sources nothing, so it does
not fix the env either.

`--copy-env` needs no wrapper, so detection is untouched: each entry above
launches as a single foreground process, and julia's precompile child appears
*earlier* in the list, exactly as `repl.lua`'s `cmdline` documents. Nothing here
requires changing `procs[#procs]`, and nothing here needs 04's `hint`.

## Rejected

- **An `--env` allowlist.** radian needed `PATH` *and* `XDG_CONFIG_HOME`; what a
  dotfiles-driven program reads is not enumerable from inside the plugin.
- **`setup()` capturing the env once.** Same source as `--copy-env` (nvim's
  environ), plus state that goes stale on `:let $VAR=`.
- **Absolute paths in `config.command`.** Fixes the lookup that is not broken, and
  verified insufficient: radian on a PATH holding both its own directory and R's
  still dies on the missing `XDG_CONFIG_HOME`. Machine-specific values in shipped
  defaults besides.
- **kitty.conf `env`.** A global kitty setting the plugin does not own, restating
  the login shell env by hand.
- **`clone-in-kitty`.** A shell-integration kitten, callable only from a shell
  inside kitty; kitty's docs send remote-control callers to `--copy-env`.
- **Declaring `config.command` the user's problem.** The plugin ships the defaults.

## Test

None. `kitty.launch` has no seam until 05. If 05 has landed, assert the argv
contains `--copy-env` in `send_spec.lua`.

## Verify

- `make test` passes
- `<leader>rs` in an `r`, `python`, `julia`, `lua` and pymol buffer: each REPL
  starts, and `kitty @ ls` shows one foreground process resolving to a program
  the filetype claims
- `<leader>rr` onto that radian window resolves to `radian`, not nil
- `printenv XDG_CONFIG_HOME` in a REPL launched for a filetype with no
  `config.command` entry
- launch latency unchanged — measured 42 ms mean either way over 5 launches

## Behaviour changes reaching the owner's config

Both changes are defaults and `ui.lua:8-38` overrides neither, so both land.
`<leader>rs` in an R buffer starts working. Every plugin-launched REPL now
inherits nvim's environment, including `VIM`, `VIMRUNTIME`, `MYVIMRC` and
`NVIM_LOG_FILE`.

## Out of scope

`repl.lua`'s `cmdline`. It is wrong for any wrapper that survives — a
hand-started `uv run --with ipython ipython` window reports the `uv` process last
and resolves only because its title still reads `IPython:` — but nothing this
task does creates such a window.

`README.md:46-47` repeats the `--r-binary` string; 08 rewrites the README.

Whether `--copy-env` is right when `kitty @` reaches a local kitty from an nvim
running over the ssh kitten. Untested.
