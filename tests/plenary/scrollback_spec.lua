---@diagnostic disable: undefined-global
local scrollback = require("kittyREPL.scrollback")
local kitty = require("kittyREPL.kitty")
local config = require("kittyREPL.config")
local parse = scrollback.parseHistoryText

local WIN = 7

describe("parseHistoryText", function()
    it("parses plain history (most recent first)", function()
        local entries = parse("ls\necho hello\npwd\n")
        assert.are.equal(3, #entries)
        assert.are.same({ "pwd" }, entries[1])
        assert.are.same({ "echo hello" }, entries[2])
        assert.are.same({ "ls" }, entries[3])
    end)

    it("parses zsh extended history", function()
        local entries = parse(table.concat({
            ": 1700000000:0;ls -la",
            ": 1700000001:0;echo hello",
            ": 1700000002:5;make test",
        }, "\n") .. "\n")
        assert.are.equal(3, #entries)
        assert.are.same({ "make test" }, entries[1])
        assert.are.same({ "echo hello" }, entries[2])
        assert.are.same({ "ls -la" }, entries[3])
    end)

    it("skips bash #timestamp lines", function()
        local entries = parse(table.concat({
            "#1700000000",
            "ls",
            "#1700000001",
            "pwd",
        }, "\n") .. "\n")
        assert.are.equal(2, #entries)
        assert.are.same({ "pwd" }, entries[1])
        assert.are.same({ "ls" }, entries[2])
    end)

    it("joins backslash-continuation lines", function()
        local entries = parse(table.concat({
            "echo hello\\",
            "world",
        }, "\n") .. "\n")
        assert.are.equal(1, #entries)
        assert.are.same({ "echo hello", "world" }, entries[1])
    end)

    it("does not join escaped backslash (even count)", function()
        local entries = parse(table.concat({
            "echo hello\\\\",
            "pwd",
        }, "\n") .. "\n")
        assert.are.equal(2, #entries)
        assert.are.same({ "pwd" }, entries[1])
        assert.are.same({ "echo hello\\\\" }, entries[2])
    end)

    it("joins triple backslash (odd = continuation)", function()
        local entries = parse(table.concat({
            "echo hello\\\\\\",
            "world",
        }, "\n") .. "\n")
        assert.are.equal(1, #entries)
        assert.are.same({ "echo hello\\\\", "world" }, entries[1])
    end)

    it("joins multi-line continuation", function()
        local entries = parse(table.concat({
            "SUBSTRATE_MAP='\\",
            "    if ($substrate == \"geranyl diphosphate\") {\\",
            "        $name = \"GPP\"\\",
            "    }\\",
            "'",
        }, "\n") .. "\n")
        assert.are.equal(1, #entries)
        assert.are.equal(5, #entries[1])
        assert.are.equal("SUBSTRATE_MAP='", entries[1][1])
        assert.are.equal("'", entries[1][5])
    end)

    it("joins continuation with zsh extended history", function()
        local entries = parse(table.concat({
            ": 1700000000:0;echo hello\\",
            "world",
        }, "\n") .. "\n")
        assert.are.equal(1, #entries)
        assert.are.same({ "echo hello", "world" }, entries[1])
    end)

    it("does not treat #comments as timestamps", function()
        local entries = parse(table.concat({
            "# this is a comment",
            "ls",
        }, "\n") .. "\n")
        assert.are.equal(2, #entries)
        assert.are.same({ "ls" }, entries[1])
        assert.are.same({ "# this is a comment" }, entries[2])
    end)

    it("returns empty table for empty input", function()
        assert.are.same({}, parse(""))
        assert.are.same({}, parse("\n"))
    end)

    it("handles mixed formats", function()
        local entries = parse(table.concat({
            ": 1700000000:0;first",
            "plain second",
            ": 1700000002:0;multi\\",
            "line",
        }, "\n") .. "\n")
        assert.are.equal(3, #entries)
        assert.are.same({ "multi", "line" }, entries[1])
        assert.are.same({ "plain second" }, entries[2])
        assert.are.same({ "first" }, entries[3])
    end)
end)

describe("scroll", function()
    local exec, notify
    before_each(function()
        exec, notify = kitty._exec, vim.notify
        vim.notify = function() end
    end)
    after_each(function()
        kitty._exec, vim.notify = exec, notify
    end)

    ---Load a REPL screen as the scrollback to be walked backwards.
    ---@param program string
    ---@param lines string[]
    local function screen(program, lines)
        local text = table.concat(lines, "\n")
        kitty._exec = function() return { code = 0, stdout = text, stderr = "" } end
        scrollback.read(WIN, program)
    end

    it("walks back over commands, skipping the empty prompt at the bottom", function()
        screen("python", {
            "Python 3.12.0",
            ">>> x = 1",
            "1",
            ">>> def f():",
            "...     return 1",
            "... ",
            ">>> ",
        })
        assert.are.same({ "def f():", "    return 1", "" }, scrollback.scroll(1, "python"))
        assert.are.same({ "x = 1" }, scrollback.scroll(1, "python"))
        assert.are.same({ "def f():", "    return 1", "" }, scrollback.scroll(-1, "python"))
    end)

    it("stops at the oldest command instead of parsing the banner", function()
        screen("python", { "Python 3.12.0", ">>> x = 1", ">>> " })
        assert.are.same({ "x = 1" }, scrollback.scroll(1, "python"))
        assert.are.same({ "x = 1" }, scrollback.scroll(1, "python"))
    end)

    it("reads a prompt only at the line start, not inside output", function()
        -- julia's prompt pattern ends in "> ", which unanchored also matches the
        -- pair syntax in "1 => 2"
        screen("julia", {
            "Documentation: https://docs.julialang.org",
            "julia> d = Dict(1 => 2)",
            "Dict{Int64, Int64} with 1 entry:",
            "  1 => 2",
            "julia> ",
        })
        assert.are.same({ "d = Dict(1 => 2)" }, scrollback.scroll(1, "julia"))
    end)

    it("anchors a prompt pattern added after setup", function()
        config.match.prompt.mine = { "mine> ", "  " }
        screen("mine", { "banner", "mine> x = 1", "mine> " })
        assert.are.same({ "x = 1" }, scrollback.scroll(1, "mine"))
        config.match.prompt.mine = nil
    end)

    it("warns and gives nothing for a program without a prompt pattern", function()
        local notified
        vim.notify = function(msg) notified = msg end
        screen("nosuchrepl", { "$ ls", "$ " })
        assert.is_nil(scrollback.scroll(1, "nosuchrepl"))
        -- the exact message, since an exhausted scrollback also gives nothing
        assert.are.equal("REPL: no prompt pattern for nosuchrepl", notified)
    end)
end)

describe("readHistory", function()
    local function write(lines)
        local path = vim.fn.tempname()
        vim.fn.writefile(lines, path)
        return path
    end

    it("reads entries most recent first", function()
        local entries = scrollback.readHistory(write({ "ls", ": 1700000000:0;pwd" }))
        assert.are.equal(2, #entries)
        assert.are.same({ "pwd" }, entries[1])
        assert.are.same({ "ls" }, entries[2])
    end)

    it("reads at most the last 500 lines", function()
        local lines = {}
        for i = 1, 600 do lines[i] = "echo " .. i end
        local entries = scrollback.readHistory(write(lines))
        assert.are.equal(500, #entries)
        assert.are.same({ "echo 600" }, entries[1])
        assert.are.same({ "echo 101" }, entries[500])
    end)

    it("notifies and returns nothing for an unreadable file", function()
        local notified
        local notify = vim.notify
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg) notified = msg end
        local entries = scrollback.readHistory("/nonexistent/history")
        vim.notify = notify
        assert.are.same({}, entries)
        assert.is_truthy(notified)
    end)
end)
