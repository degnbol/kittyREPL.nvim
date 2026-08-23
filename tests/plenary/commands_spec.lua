---@diagnostic disable: undefined-global
-- Needs the python and r parsers installed.
local commands = require("kittyREPL.commands")
local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")

local sent, notified

---Capture what the commands send and notify instead of doing it.
local function record()
    sent, notified = nil, nil
    kitty.run = function(text) sent = text end
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
end

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
