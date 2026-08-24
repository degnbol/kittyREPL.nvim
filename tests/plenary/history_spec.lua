---@diagnostic disable: undefined-global
-- History files as the REPLs themselves wrote them, captured by
-- tests/fixtures/repl.sh. The parsers are reached through the config entries
-- that wire them up, those being what a program name actually resolves to.
local history = require("kittyREPL.history")
local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")
local parse = history.parse_shell

---One captured history file.
---@param name string fixture basename
---@return string
local function fixture(name)
    local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
    local file = assert(io.open(dir .. "/../fixtures/repl/history/" .. name, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

describe("parse_shell", function()
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

describe("julia history", function()
    local entries = config.history.julia.parse(fixture("repl_history.jl"))

    it("reads entries most recent first, multi-line ones whole", function()
        assert.are.same({ "sleep(30)" }, entries[1])
        assert.are.same({ "for i in 1:2", "    println(i)", "end" }, entries[2])
        assert.are.same({ "x = 1" }, entries[3])
        assert.are.same({ "y = 42" }, entries[4])
    end)

    it("leaves out what another mode took, which is not julia to paste back", function()
        assert.are.equal(4, #entries)
    end)
end)

describe("radian history", function()
    local entries = config.history.radian.parse(fixture("radian_history"))

    it("reads entries most recent first, multi-line ones whole", function()
        assert.are.same({ "for (i in 1:2) {", "    print(i)", "}" }, entries[1])
        assert.are.same({ "x <- 1" }, entries[2])
    end)

    it("leaves out what shell mode took", function()
        assert.are.equal(2, #entries)
    end)
end)

describe("ipython history", function()
    local parse_ipython = config.history.ipython.parse

    it("reads the query result most recent first", function()
        local entries = parse_ipython(fixture("ipython.json"))
        assert.are.equal(4, #entries)
        assert.are.same({ "f()" }, entries[1])
        assert.are.same({ "def f():", "    return 1", "    " }, entries[2])
        assert.are.same({ "x" }, entries[3])
        assert.are.same({ "x = 1" }, entries[4])
    end)

    it("reads an empty result, which sqlite3 writes as no json at all", function()
        assert.are.same({}, parse_ipython(""))
    end)
end)

describe("ipython database", function()
    local exec, notify, notified
    before_each(function()
        exec, notify = kitty._exec, vim.notify
        notified = {}
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg) table.insert(notified, msg) end
    end)
    after_each(function() kitty._exec, vim.notify = exec, notify end)

    it("queries the profile's database and parses what comes back", function()
        local argv
        ---@diagnostic disable-next-line: duplicate-set-field
        kitty._exec = function(a)
            argv = a
            return { code = 0, stdout = fixture("ipython.json"), stderr = "" }
        end
        local entries = history.read(config.history.ipython, 7)
        assert.are.same({ "f()" }, entries[1])
        assert.are.same({ "sqlite3", "-json" }, { argv[1], argv[2] })
        assert.is_truthy(argv[3]:match("/profile_default/history%.sqlite$"))
    end)

    it("leaves recall to the screen when sqlite3 fails, saying why once", function()
        ---@diagnostic disable-next-line: duplicate-set-field
        kitty._exec = function() return { code = 1, stdout = "", stderr = "unable to open database" } end
        assert.are.same({}, history.read(config.history.ipython, 7))
        assert.are.same({ "REPL: unable to open database" }, notified)
    end)

    it("leaves recall to the screen when there is no sqlite3 to run", function()
        ---@diagnostic disable-next-line: duplicate-set-field
        kitty._exec = function() error("ENOENT: no such file or directory") end
        assert.are.same({}, history.read(config.history.ipython, 7))
        assert.are.equal(1, #notified)
    end)
end)

describe("radian history path", function()
    local exec
    before_each(function() exec = kitty._exec end)
    after_each(function() kitty._exec = exec end)

    ---Answer `kitty @ ls` with a window sitting in a directory.
    ---@param cwd string
    local function sitting_in(cwd)
        ---@diagnostic disable-next-line: duplicate-set-field
        kitty._exec = function()
            return { code = 0, stderr = "",
                stdout = vim.json.encode({ { tabs = { { windows = { { id = 7, cwd = cwd } } } } } }) }
        end
    end

    it("takes the file beside the session, which is radian's own precedence", function()
        local cwd = vim.fn.tempname()
        vim.fn.mkdir(cwd, "p")
        vim.fn.writefile({}, cwd .. "/.radian_history")
        sitting_in(cwd)
        assert.are.equal(cwd .. "/.radian_history", config.history.radian.path(7))
    end)

    it("falls back to the global file where the session has none", function()
        sitting_in(vim.fn.tempname())
        assert.are.equal(vim.fn.expand("~/.radian_history"), config.history.radian.path(7))
    end)
end)

describe("history.read", function()
    local function write(lines)
        local path = vim.fn.tempname()
        vim.fn.writefile(lines, path)
        return path
    end

    ---A reader for a fixed path, so that reading is what is under test.
    ---@param path string
    ---@return table
    local function at(path)
        return { path = function() return path end, parse = history.parse_shell }
    end

    it("reads entries most recent first", function()
        local entries = history.read(at(write({ "ls", ": 1700000000:0;pwd" })), 7)
        assert.are.equal(2, #entries)
        assert.are.same({ "pwd" }, entries[1])
        assert.are.same({ "ls" }, entries[2])
    end)

    it("reads at most the last 500 lines", function()
        local lines = {}
        for i = 1, 600 do lines[i] = "echo " .. i end
        local entries = history.read(at(write(lines)), 7)
        assert.are.equal(500, #entries)
        assert.are.same({ "echo 600" }, entries[1])
        assert.are.same({ "echo 101" }, entries[500])
    end)

    it("notifies and returns nothing for an unreadable file", function()
        local notified
        local notify = vim.notify
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg) notified = msg end
        local entries = history.read(at("/nonexistent/history"), 7)
        vim.notify = notify
        assert.are.same({}, entries)
        assert.is_truthy(notified)
    end)
end)
