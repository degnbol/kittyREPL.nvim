---@diagnostic disable: undefined-global
-- Screens, scrollbacks and history files as a live kitty returned them, captured
-- by tests/fixtures/repl.sh.
local scrollback = require("kittyREPL.scrollback")
local kitty = require("kittyREPL.kitty")
local config = require("kittyREPL.config")
local history = require("kittyREPL.history")

local FIXTURES = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/../fixtures/repl/"

---One captured fixture.
---Read byte for byte: the cursor escape a screen ends in is what the prompt is
---measured against.
---@param name string path under tests/fixtures/repl
---@return string
local function fixture(name)
    local file = assert(io.open(FIXTURES .. name, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

describe("prompt detection", function()
    local exec, notify, histories, notified
    before_each(function()
        exec, notify = kitty._exec, vim.notify
        -- every program reads off the screen here, history recall being below
        histories, config.history = config.history, {}
        notified = {}
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg) table.insert(notified, msg) end
    end)
    after_each(function()
        kitty._exec, vim.notify, config.history = exec, notify, histories
    end)

    -- a window id per session, so that no test reads another's learned prompt
    local win = 100

    ---Answer kitty with one captured REPL session and read it.
    ---@param program string
    ---@param opts table|nil screen = prompt fixture, else the program's own;
    ---scrollback = text to serve instead of the captured one;
    ---alternate = whether a pager holds the screen
    ---@return integer win
    local function session(program, opts)
        opts = opts or {}
        win = win + 1
        local id = win
        ---@diagnostic disable-next-line: duplicate-set-field
        kitty._exec = function(argv)
            local out
            if argv[3] == "ls" then
                out = vim.json.encode({ { tabs = { { windows = { {
                    id = id, in_alternate_screen = opts.alternate or false,
                } } } } } })
            elseif vim.tbl_contains(argv, "--extent=all") then
                out = opts.scrollback or fixture("scrollback/" .. program .. ".txt")
            else
                out = fixture("prompt/" .. (opts.screen or program) .. ".txt")
            end
            return { code = 0, stdout = out, stderr = "" }
        end
        scrollback.read(id, program)
        return id
    end

    ---The next few entries walking back from the bottom.
    ---@param n integer
    ---@return table[]
    local function entries(n)
        local walked = {}
        for _ = 1, n do table.insert(walked, scrollback.scroll(1)) end
        return walked
    end

    it("learns python's prompt and walks back over its commands", function()
        session("python")
        assert.are.same({ { "f()" }, { "def f():" }, { "x = 1" } }, entries(3))
    end)

    it("generalises ipython's counter, so a prompt read as In [5] finds In [1]", function()
        session("ipython")
        assert.are.same({ { "f()" }, { "def f():" }, { "x" }, { "x = 1" } }, entries(4))
    end)

    it("learns radian's coloured prompt, which kitty returns a cell short", function()
        session("radian")
        assert.are.same({ { "for (i in 1:2) {" }, { "x <- 1" } }, entries(2))
    end)

    it("learns julia's prompt, and reads none of its shell mode as julia", function()
        session("julia")
        assert.are.same({ { "for i in 1:2" }, { "x = 1" } }, entries(2))
    end)

    it("learns R's prompt", function()
        session("r")
        assert.are.same({ { "x" }, { "x <- 1" } }, entries(2))
    end)

    it("learns lua's prompt", function()
        session("lua")
        assert.are.same({ { "print(x)" }, { "x = 1" } }, entries(2))
    end)

    it("names the prompt it settled on, so a wrong one is visible at once", function()
        session("radian")
        session("julia")
        assert.are.same({ 'REPL: radian prompt "R❯ "', 'REPL: julia prompt "\u{E80D} ❯ "' }, notified)
    end)

    it("gives nothing for a REPL that draws no prompt to sit after", function()
        session("pymol")
        assert.is_nil(scrollback.scroll(1))
        assert.are.same({ "REPL: pymol is not at a prompt" }, notified)
    end)

    it("gives nothing while a computation runs, the cursor having left the prompt", function()
        session("julia", { screen = "julia-busy" })
        assert.is_nil(scrollback.scroll(1))
        assert.are.same({ "REPL: julia is not at a prompt" }, notified)
    end)

    it("refuses a half-typed line, which nothing else on the screen repeats", function()
        session("radian", { screen = "radian-typing" })
        assert.is_nil(scrollback.scroll(1))
        assert.are.same({ 'REPL: could not confirm radian prompt "R❯ x <- 1 + "' }, notified)
    end)

    it("refuses a prompt the screen shows once, one occurrence corroborating nothing", function()
        session("radian", { scrollback = "R version 4.5.0\nR❯ x <- 1\n" })
        assert.is_nil(scrollback.scroll(1))
        assert.are.same({ 'REPL: could not confirm radian prompt "R❯ "' }, notified)
    end)

    it("falls back to the screen where a history file has nothing in it", function()
        local path = vim.fn.tempname()
        vim.fn.writefile({}, path)
        config.history.lua = { path = function() return path end, parse = history.parse_shell }
        session("lua")
        assert.are.same({ { "print(x)" }, { "x = 1" } }, entries(2))
    end)

    it("refuses to read a prompt behind a pager", function()
        session("julia", { alternate = true })
        assert.is_nil(scrollback.scroll(1))
        assert.are.same({ "REPL: cannot read a prompt behind a pager" }, notified)
    end)

    it("takes a configured prompt over the running window", function()
        config.prompt.radian = "> "
        session("radian")
        -- the override is taken as given: this one matches nothing, where
        -- reading the window would have found "R❯ " and two commands under it
        assert.is_nil(scrollback.scroll(1))
        assert.are.same({}, notified)
        config.prompt.radian = nil
    end)

    it("re-learns a prompt that has stopped matching, which is how a mode switch recovers", function()
        local id = session("julia")
        assert.are.same({ { "for i in 1:2" } }, entries(1))
        -- the same window, now showing a REPL that prompts differently
        kitty._exec = function(argv)
            if argv[3] == "ls" then
                return { code = 0, stderr = "",
                    stdout = vim.json.encode({ { tabs = { { windows = { { id = id } } } } } }) }
            end
            local name = vim.tbl_contains(argv, "--extent=all") and "scrollback/lua" or "prompt/lua"
            return { code = 0, stdout = fixture(name .. ".txt"), stderr = "" }
        end
        scrollback.read(id, "julia")
        assert.are.same({ { "print(x)" }, { "x = 1" } }, entries(2))
    end)
end)

describe("history recall", function()
    local exec, shipped
    before_each(function() exec, shipped = kitty._exec, vim.deepcopy(config.history) end)
    after_each(function() kitty._exec, config.history = exec, shipped end)

    ---Read a program's history from a fixed file rather than wherever it lives.
    ---@param program string
    ---@param path string
    local function at(program, path)
        config.history[program] = {
            path = function() return path end,
            parse = config.history[program].parse,
        }
        ---@diagnostic disable-next-line: duplicate-set-field
        kitty._exec = function() error("the screen must not be read") end
    end

    it("reads a shell's history file rather than its screen", function()
        local path = vim.fn.tempname()
        vim.fn.writefile({ "ls -la", ": 1700000000:0;make test" }, path)
        at("zsh", path)
        scrollback.read(7, "zsh")
        assert.are.same({ "make test" }, scrollback.scroll(1))
        assert.are.same({ "ls -la" }, scrollback.scroll(1))
    end)

    it("keeps a multi-line entry whole, where the screen would give its first line", function()
        at("radian", FIXTURES .. "history/radian_history")
        scrollback.read(7, "radian")
        assert.are.same({ "for (i in 1:2) {", "    print(i)", "}" }, scrollback.scroll(1))
    end)

    it("reports a reader that throws instead of letting it out of the keymap", function()
        local notify = vim.notify
        local notified = {}
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg) table.insert(notified, msg) end
        config.history.zsh = { path = function() error("nowhere") end, parse = config.history.zsh.parse }
        -- a blank screen, so what follows the fault is the ordinary fallback
        ---@diagnostic disable-next-line: duplicate-set-field
        kitty._exec = function(argv)
            local ls = vim.json.encode({ { tabs = { { windows = { { id = 7 } } } } } })
            return { code = 0, stdout = argv[3] == "ls" and ls or "", stderr = "" }
        end
        scrollback.read(7, "zsh")
        vim.notify = notify
        assert.is_truthy(notified[1]:match("history reader: .*nowhere"))
    end)
end)
