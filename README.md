# kittyREPL

Neovim plugin for sending code to a REPL running in a separate kitty window.
Defaults are shipped for python, ipython, r, radian, julia, lua, pymol and the
shells. Other programs are added through config.

Requires the `kitty` CLI on `PATH` and remote control enabled in kitty
(`allow_remote_control yes`). Pasting REPL output needs kitty's shell
integration, and the loop-iteration maps need a treesitter parser for the
buffer's language.

It also works with files edited over ssh through `edit-in-kitty`, which edits
them locally under the hood. The REPL may then run either locally or on the
remote, but a remote one is launched as `ssh …`, so only ipython is recognised
there (by its window title) and any other program stays unnamed.

## Setup

No keys are bound by default: every `keymap` entry defaults to a `<plug>` map,
so either pass your keys to `setup()` or map the `<plug>` maps yourself. Example
with lazy.nvim:

```lua
{
    "degnbol/kittyREPL.nvim",
    opts = {
        keymap = {
            new = "<leader>rs",     -- start a new REPL for this filetype
            setlast = "<leader>rr", -- send to the kitty window you came from
            focus = "<C-CR>",
            run = "<CR>",           -- run motion
            paste = "<S-CR>",       -- send motion without executing
            runLine = "<CR><CR>",
            pasteLine = "<S-CR><S-CR>",
            runVisual = "<CR>",
            pasteVisual = "<S-CR>",
            help = "<leader>K",
            interrupt = "<leader>rk",
            scrollStart = "[r",
            scrollUp = "[r",
            scrollDown = "]r",
        },
        exclude = { tex = true, text = true, tsv = true, markdown = true },
        editpaste = true,
        closepager = true,
        command = { python = "python" }, -- stock REPL instead of the default ipython
    },
}
```

Keys are buffer-local, set on `FileType`. A buffer gets none if its `'buftype'`
is non-empty or its filetype is in `exclude`.

## Config

User config is deep-merged into the defaults, so overriding one entry of a table
keeps the rest. An entry of a per-language table cannot be dropped by omission —
set it to `false`.

### Key spaces

The per-language tables are keyed on one of two axes. Which one is not visible
at a call site, so getting this wrong is the easiest way to write config that is
silently ignored.

| keyed by filetype — the file you edit | keyed by program — what runs in the REPL window |
|---|---|
| `exclude`, `command`, `command_count`, `iterate` | `bracketed`, `linewise`, `custom`, `context`, `variables`, `assign`, `match.prompt`, `match.help` |

`programs` bridges the two: it is keyed by filetype and its values are program
names. A name and a filetype coincide for some languages (`julia`, `lua`) and
differ for others — an `r` buffer usually drives `radian`.

### Options

| key | default | meaning |
|---|---|---|
| `progress` | `true` | move the cursor past what was just sent |
| `editpaste` | `false` | focus the REPL window right after pasting to it |
| `closepager` | `false` | send `q` first when the REPL is sitting in a pager |
| `exclude` | `TelescopePrompt`, `oil`, `qf` | filetypes to leave unmapped |

### Filetype-keyed

- **`programs`** — set of program names the filetype accepts as its REPL. Used to
  find a REPL among the windows of the focused kitty tab when the buffer has none
  or its window is gone.

  The name comes from the process running in the window, lowercased and stripped
  of a version tail, so it is `python`, never `python3` (and a program whose own
  name ends in a digit cannot be matched). It names the entrypoint rather than the
  interpreter, so radian, running as `python3 …/bin/radian`, resolves to `radian`.
  The union of all `programs` values is the closed set of names that resolve at
  all: a window running anything no filetype claims stays unnamed rather than
  being mislabelled, and an unnamed REPL is sent raw.
- **`command`** — command for a new REPL window, e.g. `python = "ipython"`. Split
  on whitespace into argv and not run through a shell, so `~`, `$VAR`, globs and
  quoting are all literal. A filetype with no entry gets the value of `'shell'`.
  The `r` default names an R binary under `/Library/Frameworks` explicitly,
  because a kitty-launched command does not inherit the environment that would
  otherwise find it. Change it off macOS.
- **`command_count`** — appended to `command`, with `v:count`, when the `new` map
  is given one. `3<leader>rs` in a julia buffer runs `julia -t 3`.
- **`iterate`** — `{ first, index, base }` expressions for taking one element out
  of an iterable, e.g. `python = { first = "next(iter(%s))", index =
  "list(iter(%s))[%d]", base = 0 }`. `base` is the index `index` gets without a
  count.

### Program-keyed

- **`bracketed`** — does the program handle bracketed paste? Only affects
  multi-line sends. The stock python REPL does not, and stock R echoes the
  markers as literal text.
- **`linewise`** — send multi-line text a line at a time, skipping empty lines.
  For REPLs that are slow to echo a continuation prompt.
- **`custom`** — `function(win, text, post)` replacing the send path entirely,
  where `post` is `"\n"` for run and `""` for paste. The default entries wrap
  pymol multi-line input in `python … python end`, strip top-level `local` for
  lua, and force julia bracketed even on one line.
- **`match.prompt`** — `{ prompt, continuation }` Lua patterns, anchored at the
  line start, used to cut commands out of the scrollback. The julia default does
  not understand a parenthesised environment prefix, as in `(env) pkg>`.
- **`match.help`** — the program's help command: a prefix string (`r = "?"`), a
  `{ prefix, suffix }` pair (`python = { "help(", ")" }`), or a table mapping a
  prompt pattern to either of those. A table is resolved against the scrollback,
  walking back from the last line until one of the patterns matches, which is how
  the julia default picks between `?` and TerminalPager's `@help` according to the
  prompt the REPL is sitting at. That default presumes TerminalPager is installed.

Send-path precedence: `custom`, then `bracketed`, then `linewise`, then raw.

### Context sync

REPL-side state that should track nvim-side state, sent ahead of the next code
to reach that window.

- **`context`** — hooks returning a line of code, or `nil` or `""` to contribute
  nothing: `context.julia = { revise = function() return "using Revise" end }`.
  A line is sent only when its text differs from what that window was last told,
  so constant code runs once per REPL and code built from nvim state is resent
  exactly when that state changes — no events involved. A hook that throws is
  reported and skips only itself.
- **`variables`** — a value to assign rather than a statement to write, the
  common case. Ships `ipython.__file__`, tracking the current buffer's path so
  `Path(__file__)` idioms work at the prompt.
- **`assign`** — `function(name, value)` writing one `variables` entry,
  defaulting to `name = "value"` with the value quoted by
  `require("kittyREPL.util").quote`. Needed where that is not the syntax — a
  shell takes no spaces around `=`, and `quote` is not a shell escaper either.

`variables` are sent before `context` hooks, each in key order. The memo is per
kitty window, not per buffer — one REPL serves many buffers, which is what makes
`__file__` go stale in the first place. It is dropped when a launch re-attaches
the window or the window's program resolves to a different name. A REPL restarted
in place under the same name is indistinguishable and keeps the memo. A line that
errors in the REPL still counts as delivered, so a hook the REPL cannot run fails
once rather than on every send.

The shipped `__file__` falls back to `"ipython"` for a buffer with no name,
matching what an `InteractiveShellApp.exec_lines` entry can set for sessions nvim
never touches. Returning `nil` would instead leave the previous buffer's path
assigned. That basename is also what makes
`multiprocessing.spawn._fixup_main_from_path` short-circuit instead of re-running
the file in every spawned child, so a real path means workers execute that file's
top level — as running it as a script would, if it guards on `__name__`.

## Keymaps

| key | default | mode | action |
|---|---|---|---|
| `new` | `<plug>kittyReplNew` | n | launch a REPL window for this filetype |
| `focus` | `<plug>kittyReplFocus` | n | focus the REPL window |
| `set` | `<plug>kittyReplSet` | n | prompt for a kitty window id to send to |
| `setlast` | `<plug>kittyReplSetLast` | n | send to the kitty window that was active before the current one |
| `run` | `<plug>kittyReplRun` | n | run a motion |
| `paste` | `<plug>kittyReplPaste` | n | send a motion without executing it |
| `runLine` | `<plug>kittyReplRunLine` | n | run the current line, `v:count1` times |
| `pasteLine` | `<plug>kittyReplPasteLine` | n | send the current line, `v:count1` times |
| `runVisual` | `<plug>kittyReplRunVisual` | x | run the selection |
| `pasteVisual` | `<plug>kittyReplPasteVisual` | x | send the selection without executing it |
| `runLineFor` | `<plug>kittyReplRunLineFor` | n | assign the variable of the loop header or assignment at the cursor the first element of its iterable |
| `runLineForI` | `<plug>kittyReplRunLineForI` | n | same, for the `v:count`'th element |
| `help` | `<plug>kittyReplHelp` | n, x | help for the word under the cursor, or for the selection |
| `q` | `<plug>kittyReplQ` | n | press `q` in the REPL |
| `cr` | `<plug>kittyReplCR` | n | press Enter in the REPL |
| `ctrld` | `<plug>kittyReplCtrld` | n | send Ctrl-D |
| `ctrlc` | `<plug>kittyReplCtrlc` | n | send Ctrl-C |
| `interrupt` | `<plug>kittyReplInterrupt` | n | SIGINT the REPL |
| `scrollStart` | `<plug>kittyReplScrollStart` | n | insert the REPL's last command at the cursor and select it |
| `scrollUp` | `<plug>kittyReplScrollUp` | x | replace the selection with the command `v:count1` older |
| `scrollDown` | `<plug>kittyReplScrollDown` | x | … and newer |
| `scrollOutputAbove` | `<plug>kittyReplScrollOutputAbove` | n | paste the last command output as comments above the cursor line |
| `scrollOutputBelow` | `<plug>kittyReplScrollOutputBelow` | n | … and below |
| `progress` | `<plug>kittyReplToggleProgress` | n | toggle `progress` |
| `editPaste` | `<plug>kittyReplToggleEditPaste` | n | toggle `editpaste` |

`scrollStart` is normal mode and leaves the pasted command selected, while
`scrollUp`/`scrollDown` are visual mode, so one lhs can serve `scrollStart` and
`scrollUp` both.

When the REPL runs a shell, those three read the shell's own history file rather
than the kitty window, and so reach commands from before the window opened.

## Adding a language

1. Add the filetype to `programs`, mapping it to the program names its REPL may
   run.
2. Give it a `command` if a new REPL window should not just be a shell.
3. Add `match.prompt` and `match.help` under the program names, for the
   scrollback and help maps.
4. Set `bracketed`, `linewise` or `custom` under the program name if a plain
   multi-line send does not work.

`runLineFor`/`runLineForI` additionally need an `iterate` entry and a
`queries/<lang>/repl-iterate.scm` on the runtimepath, capturing `@variable` and
`@iterable` for loop headers and `@assign.variable`/`@assign.iterable` for
assignments. Shipped for python, julia and r.
