---@diagnostic disable: undefined-global
-- Needs the python and r parsers installed.
local commands = require("kittyREPL.commands")
local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")

local sent, notified

---Capture what the commands send and notify instead of doing it.
local function record()
    sent, notified = nil, nil
    kitty.run = function(_, _, text) sent = text end
    kitty.window = function() return { id = 7, foreground_processes = {} } end
    -- nothing here may reach the developer's terminal, whichever config defaults change
    kitty._exec = function() return { code = 0, stdout = "", stderr = "" } end
    vim.notify = function(msg) notified = msg end
end

---@param ft string
---@param lines string[]
---@param cursor integer[] row (1-indexed), col
local function open(ft, lines, cursor)
    record()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.bo[buf].filetype = ft
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, cursor)
    vim.b.repl_win = 7
end

describe("commands pager probe", function()
    local probes, raw, detect_pager, send_raw, closepager
    before_each(function()
        probes, raw = 0, {}
        detect_pager, send_raw, closepager = kitty.detect_pager, kitty.send_raw, config.closepager
        config.closepager = true
        kitty.detect_pager = function() probes = probes + 1; return true end
        kitty.send_raw = function(_, text) table.insert(raw, text) end
    end)
    after_each(function()
        kitty.detect_pager, kitty.send_raw, config.closepager = detect_pager, send_raw, closepager
    end)

    it("probes once per action, where sending probed once per send", function()
        open("python", { "1 + 1" }, { 1, 0 })
        commands.runLine()
        assert.are.equal(1, probes)
    end)

    it("probes once for a counted action, not once per line it sends", function()
        open("python", { "1 + 1", "2 + 2", "3 + 3" }, { 1, 0 })
        local sends = 0
        kitty.run = function() sends = sends + 1 end
        -- v:count1 is only set inside a mapping, so this one is pressed, not called
        vim.keymap.set("n", "R", commands.runLine, { buffer = 0 })
        vim.api.nvim_feedkeys("3R", "mx", false)
        assert.are.equal(3, sends)
        assert.are.equal(1, probes)
    end)

    it("quits the pager before sending", function()
        open("python", { "1 + 1" }, { 1, 0 })
        commands.pasteLine()
        assert.are.same({ "q", "1 + 1" }, raw)
    end)

    it("does not probe with closepager off", function()
        config.closepager = false
        open("python", { "1 + 1" }, { 1, 0 })
        commands.runLine()
        assert.are.equal(0, probes)
    end)
end)

describe("commands context sync", function()
    local hooks, paste
    before_each(function()
        hooks, paste = config.context.python, kitty.paste
        config.context.python = { one = function() return "1" end }
    end)
    after_each(function()
        config.context.python, kitty.paste = hooks, paste
    end)

    ---Bind to a window a program resolves for, so context hooks apply.
    ---Every case passes an id of its own: the memo of what a window has been
    ---told outlives the test that filled it.
    ---@param win integer
    local function attach(win)
        kitty.window = function()
            return { id = win, foreground_processes = { { cmdline = { "python" } } } }
        end
        vim.b.repl_win = win
    end

    it("sends the context line before the code, once per counted action", function()
        open("python", { "a", "b" }, { 1, 0 })
        attach(78)
        local sends = {}
        kitty.run = function(_, _, text) table.insert(sends, text) end
        -- v:count1 is only set inside a mapping, so this one is pressed, not called
        vim.keymap.set("n", "R", commands.runLine, { buffer = 0 })
        vim.api.nvim_feedkeys("2R", "mx", false)
        assert.are.same({ "1", "a", "b" }, sends)
    end)

    it("does not send it again for the next action", function()
        open("python", { "a" }, { 1, 0 })
        attach(79)
        local sends = {}
        kitty.run = function(_, _, text) table.insert(sends, text) end
        commands.runLine()
        commands.runLine()
        assert.are.same({ "1", "a", "a" }, sends)
    end)

    it("syncs before a paste too", function()
        open("python", { "a" }, { 1, 0 })
        attach(80)
        local sends = {}
        kitty.run = function(_, _, text) table.insert(sends, text) end
        kitty.paste = function(_, _, text) table.insert(sends, "paste:" .. text) end
        commands.pasteLine()
        assert.are.same({ "1", "paste:a" }, sends)
    end)
end)

describe("commands.runLineFor", function()
    it("sends the first element of the iterable, iterator or not", function()
        open("python", { "for scene, _arrows in zip(scenes, arrows, strict=True):", "    pass" }, { 1, 0 })
        commands.runLineFor()
        assert.are.equal("scene, _arrows = next(iter(zip(scenes, arrows, strict=True)))", sent)
    end)

    it("progresses to the loop body", function()
        open("python", { "for i in items:", "    pass" }, { 1, 0 })
        commands.runLineFor()
        assert.are.same({ 2, 4 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("leaves the cursor alone with progress off", function()
        config.progress = false
        open("python", { "for i in items:", "    pass" }, { 1, 0 })
        commands.runLineFor()
        config.progress = true
        assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("notifies and sends nothing without a binding", function()
        open("python", { "import os" }, { 1, 0 })
        commands.runLineFor()
        assert.is_nil(sent)
        assert.are.equal("REPL: no loop binding found at the cursor", notified)
    end)
end)

describe("commands.runLineForI", function()
    it("indexes the iterable at the language's first index", function()
        open("python", { "for i in items:", "    pass" }, { 1, 0 })
        commands.runLineForI()
        assert.are.equal("i = list(iter(items))[0]", sent)

        -- parenthesised because R's [[ binds tighter than :
        open("r", { "for (i in 1:10) {", "}" }, { 1, 0 })
        commands.runLineForI()
        assert.are.equal("i = (1:10)[[1]]", sent)
    end)
end)

describe("commands.iterateExpr", function()
    it("wraps python iterables so iterators work too", function()
        record()
        assert.are.equal("next(iter(zip(a, b)))",
            commands.iterateExpr("python", "first", "zip(a, b)"))
        assert.are.equal("list(iter(zip(a, b)))[2]",
            commands.iterateExpr("python", "index", "zip(a, b)", 2))
    end)

    it("defaults the index to the language's first", function()
        record()
        assert.are.equal("list(iter(xs))[0]", commands.iterateExpr("python", "index", "xs"))
        assert.are.equal("collect(xs)[1]", commands.iterateExpr("julia", "index", "xs"))
        assert.are.equal("(xs)[[1]]", commands.iterateExpr("r", "index", "xs"))
    end)

    it("notifies for a filetype without expressions", function()
        record()
        assert.is_nil(commands.iterateExpr("lua", "first", "xs"))
        assert.are.equal("REPL: no iterate.first expression for lua", notified)
    end)

    it("notifies for expressions without a base index", function()
        record()
        config.iterate.lua = { first = "%s[1]", index = "%s[%d]" }
        assert.is_nil(commands.iterateExpr("lua", "index", "xs"))
        config.iterate.lua = nil
        assert.are.equal("REPL: no iterate.index expression for lua", notified)
    end)
end)
