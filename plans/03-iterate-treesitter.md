# 03 — Treesitter-based loop-variable extraction

**Goal:** replace the regex `parseVariableIterable` with a treesitter query, and
fix the sequence-vs-iterator mismatch that makes the generated line fail at
runtime.
**Depends on:** 01. **Blocks:** 04 (ordering only — run this first so
`commands.lua` has stopped moving before the registry refactor).
**Reads:** `design.md` § Config keying axes, § Transport.

All open questions are resolved; this is ready to implement.

## Couplings to the other tasks

Independent in what it changes — it touches no REPL identity and no transport, so
04's removal of `vim.b.repl_cmd` does not reach it. The mechanical overlaps:

- It rewrites `runLineFor`/`runLineForI`; 04 rewrites `new`/`set`/`setI`/`setLast`
  in the same file. Different functions.
- It adds `vim.notify` error paths; 07 separately converts that file's `print`
  calls. Adjacent, not conflicting.
- Its rewritten commands call `kitty.run(torun)` — dropping the `raw` argument,
  see §6. Task 05 gives `kitty.run` an explicit `win` first parameter, so
  whichever lands second updates those two call sites.
- It adds a filetype-keyed `iterate` table. Task 02 writes the key-axis comment
  block in `config.lua` and runs first, so this task adds the `iterate` row.
- It shifts every line in `commands.lua`. Task 09 rewrites `kitty.run(` → a local
  `run(` wrapper across that file; it now re-derives its call sites by grep
  instead of from a fixed line list.

## Two separate bugs in the reported case

Repro line (python):

```python
for scene, _arrows in zip(scenes, arrows, strict=True):
```

`<leader>ri` (`commands.runLineForI`) currently produces
`_arrows = zip(scenes, arrows, strict=True)[0]`. Two independent defects:

1. **Extraction is wrong.** `parseVariableIterable`
   (`lua/kittyREPL/commands.lua`) tries `pVar = "[%w_]+"` before `"%b()"`, so
   the tuple target `scene, _arrows` is truncated to its last element. The
   correct target is the whole pattern list.
2. **The generated expression is still invalid** even with the full target:
   `zip(...)` is not subscriptable → `TypeError`. So fixing only extraction does
   not fix the repro.

Symmetric defect in the sibling command `runLineFor` (`<leader>ro`,
`commands.lua`): python `next(x)` requires an iterator, so
`next(range(10))` / `next(mylist)` raise `TypeError`. Julia's `first()` happens
to accept both, so only python is affected there.

Also: both functions crash with a Lua concat-on-nil error when nothing matches,
instead of reporting it.

## Facts established (probed against the installed parsers)

Node shapes, verified by dumping parse trees with `nvim --headless -l`, and
re-verified independently:

| ft | construct | node | variable | iterable |
|---|---|---|---|---|
| python | `for x in y:` | `for_statement` | field `left` | field `right` |
| python | comprehension | `for_in_clause` | field `left` | field `right` |
| python | `x = y` | `assignment` | field `left` | field `right` |
| julia | `for x in y` | `for_binding` | 1st named child | 3rd named child |
| julia | `x = y` | `assignment` | 1st named child | 3rd named child |
| r | `for (x in y)` | `for_statement` | field `variable` | field `sequence` |
| r | `x <- y` | `binary_operator` | field `lhs` | field `rhs` |

Julia's grammar exposes **no field names** on `for_binding`/`assignment`
(confirmed by probing candidate field names through `query.parse`), so a
field-based Lua accessor cannot be uniform across languages. R's
`binary_operator` also covers `a + b` and `1:10`, so the assignment case must
constrain the operator.

Both facts point to **treesitter queries** rather than Lua field access: queries
express positional anchors (`.`) and operator predicates (`#any-of?`) as
naturally as fields.

## Design

### 1. Queries shipped as runtime query files

Add `queries/<lang>/repl-iterate.scm` in the plugin, loaded with
`vim.treesitter.query.get(lang, "repl-iterate")`. This is the canonical
mechanism (`:h treesitter-query`): it merges across runtimepath and honours
`; extends`, so a user can support a new language, or extend an existing one, by
dropping a file in their own `queries/` dir. Verified: a plugin-shipped file is
found (the config appends `modules/*` to the rtp in its `lua/dev_plugins.lua`),
and a `; extends` file in a later rtp entry merges rather than replaces.

Two *kinds* of pattern, distinguished by capture name — this is what makes
selection well-defined (§2):

- loop bindings → `@variable`, `@iterable`
- assignments → `@assign.variable`, `@assign.iterable`

```scm
; queries/python/repl-iterate.scm
(for_statement left: (_) @variable right: (_) @iterable)
(for_in_clause left: (_) @variable right: (_) @iterable)
(assignment    left: (_) @assign.variable right: (_) @assign.iterable)
```

```scm
; queries/julia/repl-iterate.scm
(for_binding (_) @variable . (operator) . (_) @iterable)
(assignment  (_) @assign.variable . (operator) @op (_) @assign.iterable
  (#eq? @op "="))
```

```scm
; queries/r/repl-iterate.scm
(for_statement variable: (_) @variable sequence: (_) @iterable)
(binary_operator lhs: (_) @assign.variable operator: _ @op
                 rhs: (_) @assign.iterable
  (#any-of? @op "<-" "<<-" "="))
```

Verified captures: `scene, _arrows` / `zip(scenes, arrows, strict=True)`;
`(scene, arrow)` / `zip(scenes, arrows)` (julia); `k, v` / `d.items()`;
`i` / `items` for the comprehension `x = [f(i) for i in items]`.

R `->`/`->>` are deliberately unsupported: they would need lhs/rhs swapped,
which the two-capture scheme cannot express without a third pattern kind.

### 2. Match selection

Every rule below operates on a match's **binding span**: from the `@variable`
capture's start to the `@iterable` capture's end. Never the matched node's own
range — a python `for_statement` spans the header *and the whole body*, so
node-range containment makes the command reach into loop bodies (see
"Containment" below).

Within a kind, a match is selected by, in order:

1. the innermost span **containing** the cursor. This is what makes a wrapped
   header work with the cursor on a continuation line, and it keeps the cursor
   on the binding it is inside rather than skipping to the next one.
2. else the span **starting first at or after the cursor column** on the cursor
   row. This is what lets repeated presses walk a multi-binding header left to
   right (§7), and it subsumes the equal-span tiebreak that julia
   `for i in 1:3, j in 1:4` (two `for_binding`s, spans 8 and 8) would otherwise
   need. Pin it with a test.

**Kind before size**, applied to those two tiers together: a loop binding
outranks an assignment the cursor points at just as precisely. Size alone is not
enough: on a one-line loop — python `for x in y: z = w`, or the idiomatic R
`for (i in 1:10) x <- i` — with the cursor at column 0 both matches are ahead of
it on the row and the *assignment is the smaller span*, so innermost-wins would
select the body statement. Verified.

Kind must not outrank *precision*, though: with the cursor on that one-line
loop's body — which is where §7 lands it after the header was sent — the
assignment contains the cursor and the loop binding does not, so the body wins
and repeated presses keep progressing. A blanket kind precedence makes §7's
landing a dead end that re-sends the header forever.

If no span both contains the cursor and lies ahead of it, fall back to the
innermost span **starting on the cursor row**, loops before assignments, so the
commands still work with the cursor past the header (e.g. on the `:` of
`for i in items:`). Failing that, `vim.notify` a warning and do nothing
(replaces the current nil-concat crash).

**Containment is binding-span, not node-range.** Testing containment against the
matched node instead gives three inconsistent outcomes for the same user intent:

```python
# A — wrapped header, cursor on a continuation line
for a, b in zip(
    xs,            # ← nothing starts here; the iterable's span covers it → works
    ys,
):

# B — cursor on a body line with no binding
for i in items:
    print(i)       # ← node-range containment would send
                   #   i = list(iter(items))[0] from the header above, silently
```

A must work; B must not. The binding span (`a, b` → end of `zip(...)`) covers A
and excludes B, so one narrower predicate handles both. The remaining rough edge
is inherent rather than fixable here: a body line that *is* an assignment
(`total = total + i`) matches as an assignment binding and yields
`total = next(iter(total + i))`. That follows from treating `x = y` as a binding
at all, which is pre-existing behaviour these commands are built on.

Kind-before-size also *simplifies* the comprehension case: for
`x = [f(i) for i in items]` the `for_in_clause` wins on kind alone, no size
comparison needed — and that reproduces the old regex's preference for the `in`
binding (verified: the regex does pick `i` / `items`).

Chained assignment resolves by cursor position: python `x = y = z` parses as
`assignment(x, assignment(y, z))`, and with the cursor at column 0 only the
outer span contains it, so `x` / `y = z` is selected; from `y` onwards the inner
one is. Rare either way, and neither is more correct.

### 3. Nth-element expressions, in config

Replaces `ft_iterate` / `ft_indexing` (`commands.lua`). Three fields per
filetype, not two: `ft_indexing = {julia=1, python=0, r=1}` is *not* an indexing
style but the **default index when `vim.v.count == 0`** (`commands.lua`); an
explicit count is passed through verbatim. Dropping it would change
`<leader>ri` on every language.

```lua
iterate = {
    python = { first = "next(iter(%s))",  index = "list(iter(%s))[%d]", base = 0 },
    julia  = { first = "first(%s)",       index = "collect(%s)[%d]",    base = 1 },
    r      = { first = "%s[[1]]",         index = "%s[[%d]]",           base = 1 },
}
```

This table lives in **`config.lua`**, not as a local in `commands.lua`. Two
reasons: every other per-language table in this plugin is already there and
merged by `M.setup` (`init.lua`); and §1's extensibility promise depends on
it — a user who drops in `queries/lua/repl-iterate.scm` would otherwise get
extraction and then a missing template. The two tables being locals is a
pre-existing wart, and this is the moment to fix it rather than reproduce it.

`iterate` is **filetype-keyed**, as recorded in `design.md` § Config keying axes.

Keep the table nested per filetype rather than flattening to
`iterate_first`/`iterate_index`/`iterate_base`. `setup` merges with
`vim.tbl_deep_extend("keep", …)` (`init.lua`), so nesting is what lets a user
write `iterate = { python = { base = 1 } }` and keep the default templates.

Per-language notes:

- **julia**: `first(X)` unchanged; `collect(X)[i]` because bare `X[i]` fails on
  `zip`/`enumerate`/generators.
- **r**: `(X)[[i]]`. R's `for` only iterates vectors/lists, so no iterator
  problem exists, but the parentheses are required: `[[` binds tighter than `:`,
  so `1:10[[1]]` is `1:(10[[1]])` — the whole vector, assigned silently.
  Note this makes `runLineFor` work in R for the first time — it currently
  crashes, since `ft_iterate` has no `r` entry. Intended.
- **python**: `next(iter(X))` — always valid, replacing today's `next(X)` — and
  `list(iter(X))[i]`.

The python wrap is unconditional (decided). Every filetype then has exactly one
expression template per command, so there is no node-type/callee-name heuristic
and no list of iterator-producing function names to keep in sync with the
standard library. `list(iter(X))[i]` is correct for sequences, `zip`,
`enumerate`, `map`/`filter`, generators and dict views alike. It is also correct
where wrapping *changes* meaning: `for k in d:` iterates keys, so
`list(iter(d))[0]` is the first key — the loop variable's actual value — whereas
bare `d[0]` would be a key *lookup*. No case was found where it is wrong.

Rejected alternative: wrap only when the rhs looks like an iterator producer.
Buys prettier REPL echo with a maintained name list and a silent-wrong-answer
mode for user functions returning generators.

Consequence to accept: `list(iter(X))` materialises the iterable, so it is
O(len) memory on a large sequence and hangs on an infinite iterator
(`itertools.count()`). The `for` loop being inspected has the same property.

### 4. Error paths

Three failure modes, all currently ending in a crash or a stack trace from a
keymap. All three notify instead:

- **No match** → notify (this is the nil-concat crash today).
- **No template for the filetype** → notify. Guarding only `binding.at` leaves
  `variable .. " = " .. tmpl` reachable with a nil template — the same bug class
  through a different door.
- **`query.get` / `get_parser` raise** → `pcall` + notify with the error text.
  Verified: `query.get` returns nil for a *missing* file but **throws** for a
  file whose node types don't match the parser (`Query error at 1:2. Invalid
  node type`), and for a missing parser. A user's typo'd `; extends` file would
  otherwise produce a stack trace on keypress. Per the project's Lua rules, the
  pcall surfaces the error rather than swallowing it.

Note for the dev loop: `query.get` memoises per lang+name, so editing a `.scm`
needs a restart. The spec must not create query files at runtime after a failed
lookup.

### 5. Structure and naming

Extract to `lua/kittyREPL/binding.lua`, named for what it finds rather than for
the command that consumes it (`runLineFor` is described as "REPL iterate" in
`init.lua`, but the unit itself has nothing to do with REPLs).

- `binding.at(bufnr, row, col)` → `variable, iterable` strings, or `nil`. Pure
  query + selection, no REPL knowledge, directly unit-testable.
- `commands.lua` keeps one local `iterateExpr(ft, key, iterable, count)` for
  expression assembly, shared by both commands so the nil-template guard exists
  once.

Delete the regex — no fallback. Keeping a regex path would mean two code paths
disagreeing silently on exactly the cases the queries were added to fix.

### 6. Multi-line captures must be normalised to one line

Verified: `for a, b in zip(\n    xs,\n    ys,\n):` captures the
iterable as `"zip(\n    xs,\n    ys,\n)"`. Both commands call
`kitty.run(torun, true)`, and `raw = true` short-circuits to
`send_raw(text .. post)` (`kitty.lua`), bypassing the `bracketed`/`linewise`
handling — so the stock python REPL (`bracketed.python = false`,
`linewise.python = true`) receives embedded newlines with indentation.

These commands construct a *single expression*; it should always be one line.
Collapse whitespace runs spanning newlines (`:gsub("%s*\n%s*", " ")`), and strip
`comment` child nodes inside the captured range first, since a comment inside a
multi-line header would otherwise swallow the rest of the expression. Treesitter
makes the comment case a child-node walk rather than a regex.

**Then drop the `raw` argument: `kitty.run(torun)`.** With a guaranteed
single-line expression, `raw = true` no longer protects against anything, and it
costs the `custom` dispatch. `config.custom.julia` (`init.lua`) exists
specifically to send *every* julia payload bracketed — its comment records that
julia types unbracketed input one character at a time — so `raw = true` means
`<leader>ri`/`<leader>ro` in julia currently take exactly the slow path that
workaround was written to avoid. Non-raw is otherwise identical for a single
line: `bracketed` only wraps text containing newlines, and `linewise` on one
line sends that line plus `post` (`kitty.lua`).

### 7. Cursor progress: advance to the next thing you would send

`config.progress` currently does `normal! j` in both commands
(`commands.lua`). Replace that, for these two commands only, with a
single unconditional walk:

> From the `@iterable` node, step forward over siblings, skipping anonymous
> tokens; take the first **named** node. If the level runs out, climb to the
> parent and continue. Put the cursor at that node's start.

No branch on "is there another binding" — the trailing `:` / `,` / `)` is an
anonymous token belonging to the construct being exited, so skipping it is the
same operation whether what follows is the next binding or the loop body.
Verified landings:

| source | lands on |
|---|---|
| python `for i in items:` | `block` — body's first line, today's behaviour |
| python wrapped `for a, b in zip(\n…\n):` | `block` after the header |
| python `for x in y: z = w` | `z = w`, same line |
| python `x = f(y)` | the next `expression_statement` |
| julia `for i in 1:3, j in 1:4` | the second `for_binding`, `j in 1:4` |
| julia `for (a,b) in x, (c,d) in y` | `(c,d) in y` |
| julia `for i in 1:10` | `block` |
| r `for (i in 1:10) x <- i` | `x <- i` |
| r `for (i in seq_along(x)) {` | `braced_expression`, i.e. the `{` |

The julia tuple case is why this must be structural rather than a text scan for
trailing punctuation: skipping a punctuation *run* after `x` would consume the
`(` of `(c,d)` and land inside the next binding. Landing on R's `{` is the one
inelegant outcome, and not worth a special case.

Because the landing is always a node *start*, and a multi-binding header lands
on the next binding's `@variable` start, §2's containment rule consumes it
exactly — the two rules compose without a tolerance.

## Tests

`tests/plenary/binding_spec.lua`, table-driven over `{ft, source, cursor,
expected_variable, expected_iterable}`:

- python: tuple target (`scene, _arrows` — the repro), single target,
  `d.items()`, comprehension (binding beats assignment), **one-line
  `for x in y: z = w`** (binding, not the body), plain assignment, `x = y = z`,
  no-match line → `nil`.
- julia: `(scene, arrow) in zip(...)`, `∈`, `1:10`, `axes(A, 1)`, assignment.
- r: `for (i in seq_along(x))`, `<-` and `<<-`, `z <- a + b`, one-line
  `for (i in 1:10) x <- i` (binding, not the body), bare `a + b` → `nil`.
- **binding-span containment**: cursor on a wrapped header's continuation line →
  the header's binding; cursor on a `print(i)` body line → `nil`, *not* the
  enclosing loop's binding.
- **column walk**: julia `for i in 1:3, j in 1:4` with the cursor at column 0
  → `i`; inside `1:3` → still `i`; at `j`'s column → `j`.
- **progress does not stall**: with the cursor where §7 lands it on a one-line
  loop (python `for x in y: z = w`, R `for (i in 1:10) x <- i`) → the body
  assignment, not the header again.
- multi-line header text: whitespace collapsed to one line, and a header
  containing a comment.
- filetype with a parser but no query file (lua) → `nil`, no throw.

Plus `tests/plenary/commands_spec.lua`, with `kitty.run` and `vim.notify`
captured: the repro's full sent string for both commands, the cursor landing,
`progress = false` leaving the cursor put, the no-binding notify, and
`iterateExpr` (ft, key, iterable, count → string) pinning the python
`list(iter(...))` form, the `base` default when count is 0, and the
missing-template and missing-`base` notifies.

Cursor progress (§7) needs a buffer-level spec rather than a pure one. Assert
the landing row/col for each row of §7's table — in particular the julia comma
loop landing on `j`'s column, since that is what §2's column rule then consumes
on the next press.

`tests/minimal_init.lua` runs `--clean`, so the parser dir is not on the
runtimepath. Add `vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/site")`.
This makes the specs depend on locally installed python/julia/r parsers (all
three present); vendoring parsers is not worth it here.

## Order of work

1. `tests/minimal_init.lua`: add the parser rtp entry.
2. `queries/{python,julia,r}/repl-iterate.scm`.
3. `config.lua`: add the `iterate` table and its key-axis row; drop
   `ft_iterate`/`ft_indexing`.
4. `binding_spec.lua` (failing).
5. `lua/kittyREPL/binding.lua`; delete `parseVariableIterable`.
6. Rewrite `runLineFor` / `runLineForI` around `iterateExpr` + the error paths,
   sending non-raw (§6).
7. Replace the `normal! j` progress in those two commands with §7's rule.
8. `make test`, then check the repro line interactively — including that
   `<leader>ri` in a julia buffer is no longer slow (§6).

## Out of scope

- Extending to more languages — the query-file mechanism makes that additive.
- R `->`/`->>` assignment (see §1).
- Harmless nonsense the regex also produced: julia `f(x) = x^2` →
  `f(x) = next(iter(x^2))`, python `x: int = 5`. Not worth constraining.
- `config.progress` in the *other* commands (`runLine`, `pasteLine`, the
  operators) keeps its current `normal! j` / `` `] `` behaviour; §7 changes only
  `runLineFor`/`runLineForI`, where "the next thing you would send" is
  well-defined.
- The `<enter>ap` no-op item in `TODO.md`.
- `commands.help`'s `kitty.run(helpcmd, true)` is the remaining `raw = true`
  caller after §6, and bypasses `custom` for the same reason. It belongs with 02,
  which already reworks `match.help`.

