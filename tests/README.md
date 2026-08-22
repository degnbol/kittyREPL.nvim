# Tests

Unit tests using [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

## Running tests

```zsh
make test
```

This clones plenary into `rtps/` on first run, then executes all `tests/plenary/*_spec.lua` files.

Run a single test file:
```zsh
make test-deps
nvim --headless --clean -u tests/minimal_init.lua -c "PlenaryBustedFile tests/plenary/scrollback_spec.lua"
```

## Writing tests

Tests live in `tests/plenary/` and follow the `*_spec.lua` naming convention.

```lua
---@diagnostic disable: undefined-global
describe("module name", function()
    it("does something", function()
        assert.are.equal(expected, actual)
    end)
end)
```
