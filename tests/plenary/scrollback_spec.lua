---@diagnostic disable: undefined-global
local scrollback = require("kittyREPL.scrollback")
local parse = scrollback.parseHistoryText

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
