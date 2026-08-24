# TODO

[plans/12-integration-fixes.md](plans/12-integration-fixes.md) — what an
integration review of the finished refactor turned up. Sections A and B are live
bugs on the send path.

Paste correct indentation with awareness of radian's own indentation settings —
`radian.indent_lines`, `radian.auto_indentation`.
https://github.com/randy3k/radian
Interacts with task 02, which changes radian's paste path to bracketed.

Make operator suffixes like `<CR>ap` a no-op when there's no REPL attached. Currently `<CR>` reports "No REPL" and the `ap`
motion still fires.

`vim.cmd` has hl injection in the string but this is missing for `cmd = vim.cmd`.
We should probably use the full form `vim.cmd` so we get the syntax hl.

Maybe extend to the ghostty terminal.
