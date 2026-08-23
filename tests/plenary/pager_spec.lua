---@diagnostic disable: undefined-global
-- Screens as a live kitty returned them, captured by tests/fixtures/pager.sh.
local kitty = require("kittyREPL.kitty")

---One captured `kitty @ get-text --extent=screen --add-cursor` screen.
---Read byte for byte: the cursor escape at the end is what is under test.
---@param name string fixture basename
---@return string
local function screen(name)
    local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
    local file = assert(io.open(dir .. "/../fixtures/pager/" .. name .. ".txt", "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

describe("kitty.is_pager", function()
    it("sees julia's TerminalPager part way through a docstring", function()
        assert.is_true(kitty.is_pager(screen("terminalpager-mid")))
    end)

    it("sees TerminalPager at the end, where its prompt is still a colon", function()
        assert.is_true(kitty.is_pager(screen("terminalpager-end")))
    end)

    it("sees less at its colon prompt", function()
        assert.is_true(kitty.is_pager(screen("less-top")))
    end)

    it("sees less at (END), where the cursor sits five columns in", function()
        assert.is_true(kitty.is_pager(screen("less-end")))
    end)

    it("ignores a REPL sitting at its own prompt", function()
        assert.is_false(kitty.is_pager(screen("julia-prompt")))
    end)

    it("ignores paged text a quit pager left on screen", function()
        assert.is_false(kitty.is_pager(screen("less-noalt-quit")))
    end)

    it("ignores a screen with no cursor position, which is a scrolled-up window", function()
        assert.is_false(kitty.is_pager("1\n2\n(END)\n"))
    end)
end)
