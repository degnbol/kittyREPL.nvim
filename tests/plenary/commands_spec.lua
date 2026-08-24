---@diagnostic disable: undefined-global
-- Needs the python and r parsers installed.
local commands = require("kittyREPL.commands")
local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")
local util = require("kittyREPL.util")

local FIXTURES = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/../fixtures/"

---One screen captured by tests/fixtures/repl.sh or pager.sh, read byte for byte:
---the cursor escape it ends in is what a prompt and a pager are measured against.
---@param name string path under tests/fixtures
---@return string
local function fixture(name)
    local file = assert(io.open(FIXTURES .. name, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

local sent, notified

---Capture what the commands send and notify instead of doing it.
---Every stub is put back by restoring(), so no test inherits one.
local function record()
    sent, notified = nil, nil
    kitty.run = function(_, _, text) sent = text end
    kitty.window = function() return { id = 7, foreground_processes = {} } end
    -- nothing here may reach the developer's terminal, whichever config defaults change
    util.exec = function() return { code = 0, stdout = "", stderr = "" } end
    vim.notify = function(msg) notified = msg end
end

---Put back whatever record() overwrites, for the tests of one describe block.
---Called per block rather than once for the file: plenary registers a
---before_each against the block being described.
local function restoring()
    local stubbed
    before_each(function()
        stubbed = {
            run = kitty.run, window = kitty.window, screen = kitty.get_screen,
            send_raw = kitty.send_raw, exec = util.exec, notify = vim.notify,
        }
    end)
    after_each(function()
        kitty.run, kitty.window, kitty.get_screen = stubbed.run, stubbed.window, stubbed.screen
        kitty.send_raw, util.exec, vim.notify = stubbed.send_raw, stubbed.exec, stubbed.notify
    end)
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

describe("commands.help", function()
    restoring()

    ---Bind the buffer to a window running one program and showing one screen.
    ---@param win integer an id of its own per case, identity being cached per window
    ---@param command string what the window's foreground process runs
    ---@param shown string|nil the screen it is sitting at
    local function at(win, command, shown)
        open("python", { "print" }, { 1, 0 })
        vim.b.repl_win = win
        kitty.window = function()
            return { id = win, foreground_processes = { { cmdline = { command } } } }
        end
        kitty.get_screen = function() return shown end
    end

    it("prefixes the query where help is one command", function()
        at(20, "/usr/bin/R")
        commands.help()
        assert.are.equal("?print", sent)
    end)

    it("wraps the query where help is a call", function()
        at(21, "/usr/bin/python3")
        commands.help()
        assert.are.equal("help(print)", sent)
    end)

    it("picks julia's help command by the mode it is prompting in", function()
        at(22, "/opt/julia/bin/julia", fixture("repl/prompt/julia-pager.txt"))
        commands.help()
        assert.are.equal("?print", sent)
    end)

    it("sends the query bare where the REPL is already in help mode", function()
        at(23, "/opt/julia/bin/julia", fixture("repl/prompt/julia-help.txt"))
        commands.help()
        assert.are.equal("print", sent)
    end)

    it("falls back to the default at a primary prompt, whatever it renders as", function()
        -- the shipped patterns describe julia's own modes; this prompt is the
        -- user's configuration of it and holds none of them
        at(24, "/opt/julia/bin/julia", fixture("repl/prompt/julia.txt"))
        commands.help()
        assert.are.equal("@help print", sent)
    end)

    it("warns and sends nothing for a program with no help command", function()
        at(25, "/bin/zsh")
        commands.help()
        assert.is_nil(sent)
        assert.are.equal("REPL: no help command for zsh", notified)
    end)

    it("takes an entry the user dropped with false as no entry", function()
        local shipped = config.help.r
        config.help.r = false
        at(27, "/usr/bin/R")
        commands.help()
        config.help.r = shipped
        assert.is_nil(sent)
        assert.are.equal("REPL: no help command for r", notified)
    end)

    it("reads one screen, for the prompt and the pager both, before sending", function()
        local closepager = config.closepager
        config.closepager = true
        at(28, "/usr/bin/python3", fixture("pager/terminalpager-mid.txt"))
        local order, reads = {}, 0
        kitty.get_screen = function()
            reads = reads + 1
            return fixture("pager/terminalpager-mid.txt")
        end
        kitty.send_raw = function(_, text) table.insert(order, "send:" .. text) end
        kitty.run = function(_, _, text) table.insert(order, "run:" .. text) end
        commands.help()
        config.closepager = closepager
        -- quitting the pager is what changes the screen the prompt was read off,
        -- so reading twice would mean reading it after the change
        assert.are.equal(1, reads)
        assert.are.same({ "send:q", "run:help(print)" }, order)
    end)

    it("does not read a pager's own footer as the prompt to match modes on", function()
        local shipped = config.help.julia
        -- a pattern the pager's footer would match, where no shipped one does
        config.help.julia = { modes = { { ":", "?" } } }
        -- less at its colon prompt, which reads as a prompt where a page part
        -- way through does not: its footer is the only thing on the last line
        at(29, "/opt/julia/bin/julia", fixture("pager/less-top.txt"))
        commands.help()
        config.help.julia = shipped
        assert.is_nil(sent)
        assert.is_truthy(notified:match("^REPL: no help command for julia"))
    end)

    it("looks up the selection rather than the word under the cursor", function()
        at(26, "/usr/bin/python3")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "os.path" })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.api.nvim_feedkeys(vim.keycode("v$h"), "mx", false)
        commands.helpVisual()
        assert.are.equal("help(os.path)", sent)
    end)
end)

describe("commands pager probe", function()
    restoring()
    local probes, raw, closepager
    before_each(function()
        probes, raw = 0, {}
        closepager, config.closepager = config.closepager, true
        -- a probe is one screen read, of a screen a pager is holding
        kitty.get_screen = function()
            probes = probes + 1
            return fixture("pager/terminalpager-mid.txt")
        end
        kitty.send_raw = function(_, text) table.insert(raw, text) end
    end)
    after_each(function() config.closepager = closepager end)

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
    restoring()
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
    restoring()
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
    restoring()
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
    restoring()
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
