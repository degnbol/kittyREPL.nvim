---@diagnostic disable: undefined-global
-- The send path with kitty's subprocess replaced, so the bytes a REPL receives
-- are asserted rather than eyeballed in a terminal.
local kitty = require("kittyREPL.kitty")
local config = require("kittyREPL.config")
local util = require("kittyREPL.util")

local WIN = 7

local calls

---Capture every subprocess instead of running it.
local function record()
    calls = {}
    util.exec = function(argv, stdin)
        table.insert(calls, { argv = argv, stdin = stdin })
        return { code = 0, stdout = "", stderr = "" }
    end
end

---What each recorded send wrote to the REPL.
---@return string[]
local function sent()
    return vim.tbl_map(function(call) return call.stdin end, calls)
end

describe("kitty.send_raw", function()
    before_each(record)

    it("passes text over stdin, targeting the window by id", function()
        kitty.send_raw(WIN, "print(1)\n")
        assert.are.same({ "kitty", "@", "send-text", "--stdin", "--match=id:7" }, calls[1].argv)
        assert.are.equal("print(1)\n", calls[1].stdin)
    end)
end)

describe("kitty.send_bracketed", function()
    before_each(record)

    it("wraps the text in paste markers, leaving post outside them", function()
        kitty.send_bracketed(WIN, "a\nb", "\n")
        assert.are.same({ "\x1b[200~a\nb\x1b[201~\n" }, sent())
    end)
end)

describe("kitty.send dispatch", function()
    before_each(function()
        record()
        config.bracketed.dummy = true
        config.linewise.dummy = true
    end)
    after_each(function()
        config.custom.dummy = nil
        config.bracketed.dummy = nil
        config.linewise.dummy = nil
    end)

    it("prefers a custom sender over bracketed and linewise", function()
        local got
        config.custom.dummy = function(win, text, post) got = { win, text, post } end
        kitty.send(WIN, "dummy", "a\nb", "\n")
        assert.are.same({ WIN, "a\nb", "\n" }, got)
        assert.are.same({}, sent())
    end)

    it("prefers bracketed over linewise", function()
        kitty.send(WIN, "dummy", "a\nb", "\n")
        assert.are.same({ "\x1b[200~a\nb\x1b[201~\n" }, sent())
    end)

    it("sends a single line raw, bracketing nothing", function()
        kitty.send(WIN, "dummy", "a", "\n")
        assert.are.same({ "a\n" }, sent())
    end)

    it("splits linewise on newlines, skipping empty lines but still sending post", function()
        config.bracketed.dummy = nil
        kitty.send(WIN, "dummy", "a\n\nb", "\n")
        assert.are.same({ "a\n", "b\n", "\n" }, sent())
    end)

    it("raw-sends an unresolved program, the conservative default", function()
        kitty.send(WIN, nil, "a\nb", "\n")
        assert.are.same({ "a\nb\n" }, sent())
    end)

    it("raw-sends when asked, bypassing the program's method", function()
        kitty.send(WIN, "dummy", "a\nb", "\n", true)
        assert.are.same({ "a\nb\n" }, sent())
    end)
end)

describe("kitty.send per program", function()
    before_each(record)

    it("brackets ipython only when there is more than one line", function()
        kitty.send(WIN, "ipython", "a\nb", "\n")
        kitty.send(WIN, "ipython", "a", "\n")
        assert.are.same({ "\x1b[200~a\nb\x1b[201~\n", "a\n" }, sent())
    end)

    it("brackets julia even for a single line", function()
        kitty.send(WIN, "julia", "1+1", "\n")
        assert.are.same({ "\x1b[200~1+1\x1b[201~\n" }, sent())
    end)

    it("splits stock python line by line", function()
        kitty.send(WIN, "python", "def f():\n\n    return 1", "\n")
        assert.are.same({ "def f():\n", "    return 1\n", "\n" }, sent())
    end)

    it("wraps multiline pymol in a python block", function()
        kitty.send(WIN, "pymol", "x = 1\ny = 2", "\n")
        assert.are.same({ "python\nx = 1\ny = 2\npython end\n" }, sent())
    end)

    it("strips top-level locals for the lua repl, which ignores them", function()
        kitty.send(WIN, "lua", "local x = 1\nlocal y = 2", "\n")
        assert.are.same({ "x = 1\ny = 2\n" }, sent())
    end)
end)

describe("kitty.paste", function()
    before_each(record)

    it("drops the trailing newline so the REPL does not execute the text", function()
        kitty.paste(WIN, nil, "a\nb\n")
        assert.are.same({ "a\nb" }, sent())
    end)

    it("closes the bracketed paste without a newline after it", function()
        kitty.paste(WIN, "ipython", "a\nb\n")
        assert.are.same({ "\x1b[200~a\nb\x1b[201~" }, sent())
    end)
end)

describe("kitty.launch", function()
    before_each(record)

    it("word-splits a user-authored command into argv, no shell involved", function()
        util.exec = function(argv)
            table.insert(calls, { argv = argv })
            return { code = 0, stdout = "9\n", stderr = "" }
        end
        assert.are.equal(9, kitty.launch("pymol -xpq"))
        assert.are.same({
            "kitty", "@", "launch", "--cwd=current", "--keep-focus",
            "--copy-env", "--env=NVIM",
            "pymol", "-xpq",
        }, calls[1].argv)
    end)
end)

describe("kitty command failure", function()
    local notified, notify, exec
    before_each(function()
        notified, notify, exec = nil, vim.notify, util.exec
        -- notify_once routes through notify, so this catches the first of each message
        vim.notify = function(msg) notified = msg end
    end)
    after_each(function()
        vim.notify, util.exec = notify, exec
    end)

    it("reports an unusable remote control rather than hiding stderr", function()
        util.exec = function()
            return { code = 1, stdout = "", stderr = "Error: No listening socket\n" }
        end
        assert.is_nil(kitty.get_scrollback(WIN))
        assert.are.equal("REPL: Error: No listening socket", notified)
    end)

    it("reports a kitty binary it cannot spawn, where vim.system raises", function()
        util.exec = function() error("ENOENT: no such file or directory (cmd): 'kitty'") end
        assert.is_nil(kitty.get_scrollback(WIN))
        assert.is_truthy(notified:find("ENOENT", 1, true))
    end)

    it("stays quiet for a window that is gone, since that is the existence check", function()
        util.exec = function()
            return { code = 1, stdout = "", stderr = "Error: No matching windows for expression: id:7\n" }
        end
        assert.is_nil(kitty.window(WIN))
        assert.is_nil(notified)
    end)
end)
