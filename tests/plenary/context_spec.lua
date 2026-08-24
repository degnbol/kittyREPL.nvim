---@diagnostic disable: undefined-global
-- What a REPL still needs to be told, and what it has been told already. No
-- kitty and no setup(): pending() evaluates hooks against plain config tables
-- and mark() records what a caller sent.
local context = require("kittyREPL.context")
local config = require("kittyREPL.config")
local util = require("kittyREPL.util")

local PROGRAM = "dummy"

-- Windows keep their memo for the session, so every case takes a fresh id.
local ids = 0
local function window()
    ids = ids + 1
    return ids
end

---Take everything pending and record it as delivered.
---@param win integer
---@return { key: string, code: string }[]
local function deliver(win)
    local entries = context.pending(win, PROGRAM)
    for _, entry in ipairs(entries) do
        context.mark(win, entry.key, entry.code)
    end
    return entries
end

describe("context.pending", function()
    after_each(function()
        config.context[PROGRAM] = nil
        config.variables[PROGRAM] = nil
        config.assign[PROGRAM] = nil
    end)

    it("offers constant code once, then nothing", function()
        config.context[PROGRAM] = { revise = function() return "using Revise" end }
        local win = window()
        assert.are.same({ { key = "ctx:revise", code = "using Revise" } }, deliver(win))
        assert.are.same({}, deliver(win))
    end)

    it("offers changing code again only when it changes", function()
        local cwd = "/a"
        config.context[PROGRAM] = { cwd = function() return "setwd(" .. util.quote(cwd) .. ")" end }
        local win = window()
        assert.are.same({ { key = "ctx:cwd", code = 'setwd("/a")' } }, deliver(win))
        assert.are.same({}, deliver(win))
        cwd = "/b"
        assert.are.same({ { key = "ctx:cwd", code = 'setwd("/b")' } }, deliver(win))
    end)

    it("tracks two windows independently", function()
        config.context[PROGRAM] = { revise = function() return "using Revise" end }
        local first, second = window(), window()
        assert.are.equal(1, #deliver(first))
        assert.are.equal(1, #deliver(second))
        assert.are.equal(0, #deliver(first))
    end)

    it("takes nil and an empty string as contributing nothing", function()
        config.context[PROGRAM] = {
            nothing = function() return nil end,
            empty = function() return "" end,
        }
        assert.are.same({}, context.pending(window(), PROGRAM))
    end)

    it("reports a throwing hook and still offers the others", function()
        local notified, level
        local notify = vim.notify
        vim.notify = function(msg, lvl) notified, level = msg, lvl end
        config.context[PROGRAM] = {
            a_throws = function() error("no") end,
            b_works = function() return "fine" end,
        }
        local entries = context.pending(window(), PROGRAM)
        vim.notify = notify
        assert.are.same({ { key = "ctx:b_works", code = "fine" } }, entries)
        assert.is_truthy(notified:find("ctx:a_throws", 1, true))
        assert.are.equal(vim.log.levels.ERROR, level)
    end)

    it("stays quiet for a program or a hook opted out with false", function()
        config.context[PROGRAM] = false
        config.variables[PROGRAM] = { x = false }
        assert.are.same({}, context.pending(window(), PROGRAM))
    end)

    it("reports a hook returning something other than code", function()
        local notified
        local notify = vim.notify
        vim.notify = function(msg) notified = msg end
        config.context[PROGRAM] = { truthy = function() return true end }
        local entries = context.pending(window(), PROGRAM)
        vim.notify = notify
        assert.are.same({}, entries)
        assert.is_truthy(notified:find("ctx:truthy gave a boolean", 1, true))
    end)

    it("offers nothing for an unresolved program", function()
        config.context[PROGRAM] = { revise = function() return "using Revise" end }
        assert.are.same({}, context.pending(window(), nil))
    end)
end)

describe("context variables", function()
    after_each(function()
        config.variables[PROGRAM] = nil
        config.assign[PROGRAM] = nil
    end)

    it("assigns a quoted string literal by default", function()
        config.variables[PROGRAM] = { path = function() return "/tmp/x.py" end }
        assert.are.same({ { key = "var:path", code = 'path = "/tmp/x.py"' } },
            context.pending(window(), PROGRAM))
    end)

    it("writes the assignment through config.assign, which gets the raw value", function()
        config.variables[PROGRAM] = { path = function() return "/tmp/x.py" end }
        config.assign[PROGRAM] = function(name, value) return name .. " <- " .. value end
        assert.are.same({ { key = "var:path", code = "path <- /tmp/x.py" } },
            context.pending(window(), PROGRAM))
    end)

    it("assigns an empty value, where nil assigns nothing", function()
        config.variables[PROGRAM] = {
            empty = function() return "" end,
            nothing = function() return nil end,
        }
        assert.are.same({ { key = "var:empty", code = 'empty = ""' } },
            context.pending(window(), PROGRAM))
    end)

    it("keeps a name shared with a context hook apart", function()
        config.variables[PROGRAM] = { x = function() return "1" end }
        config.context[PROGRAM] = { x = function() return "x()" end }
        local win = window()
        assert.are.same({
            { key = "var:x", code = 'x = "1"' },
            { key = "ctx:x", code = "x()" },
        }, deliver(win))
        config.context[PROGRAM] = nil
        assert.are.same({}, deliver(win))
    end)
end)

describe("the ipython __file__ default", function()
    it("assigns the buffer's path, falling back to the multiprocessing sentinel", function()
        local win = window()
        vim.cmd.enew()
        assert.are.same({ { key = "var:__file__", code = '__file__ = "ipython"' } },
            context.pending(win, "ipython"))
        -- not under /tmp, which macOS resolves to /private/tmp behind the name
        vim.api.nvim_buf_set_name(0, "/nowhere/mymod.py")
        assert.are.same({ { key = "var:__file__", code = '__file__ = "/nowhere/mymod.py"' } },
            context.pending(win, "ipython"))
    end)
end)

describe("util.quote", function()
    it("escapes what would otherwise end the literal", function()
        assert.are.equal([["a\"b"]], util.quote('a"b'))
        assert.are.equal([["a\\b"]], util.quote("a\\b"))
        assert.are.equal([["a\nb"]], util.quote("a\nb"))
        assert.are.equal([["a\rb"]], util.quote("a\rb"))
        assert.are.equal([["a\\\nb"]], util.quote("a\\\nb"))
    end)
end)
