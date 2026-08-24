---@diagnostic disable: undefined-global
-- cmdlines and titles are real `kitty @ ls` foreground_processes/title values.
local repl = require("kittyREPL.repl")
local kitty = require("kittyREPL.kitty")

---A `kitty @ ls` window record with one foreground process.
---@param title string
---@param ... string cmdline words
---@return table
local function window(title, ...)
    return { id = 7, title = title, foreground_processes = { { cmdline = { ... } } } }
end

describe("repl.resolve", function()
    it("names R", function()
        assert.are.equal("r", repl.resolve(window("R",
            "/Library/Frameworks/R.framework/Resources/bin/exec/R", "--no-save", "--quiet")))
    end)

    it("names radian, not the python that launched it", function()
        assert.are.equal("radian", repl.resolve(window("radian id=7",
            "/Users/me/.local/share/uv/tools/radian/bin/python3", "/Users/me/.local/bin/radian")))
    end)

    it("names each shell", function()
        assert.are.equal("zsh", repl.resolve(window("~", "-zsh", "-l")))
        assert.are.equal("bash", repl.resolve(window("bash", "/bin/bash", "--posix", "-l")))
        assert.are.equal("sh", repl.resolve(window("sh", "/bin/sh")))
    end)

    it("names julia", function()
        assert.are.equal("julia", repl.resolve(window("Julia",
            "/Users/me/.julia/juliaup/julia-1.12.6+0.aarch64.apple.darwin14/Julia-1.12.app/Contents/Resources/julia/bin/julia")))
    end)

    it("names stock python", function()
        assert.are.equal("python", repl.resolve(window("zsh",
            "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python")))
    end)

    it("names ipython from the window title, which is all ssh leaves", function()
        assert.are.equal("ipython", repl.resolve(window("IPython: Users/me", "ssh", "server")))
    end)

    it("names ipython from the cmdline when the title was overwritten", function()
        assert.are.equal("ipython", repl.resolve(window("ipython id=7",
            "/Users/me/.local/share/uv/tools/ipython/bin/python3", "/Users/me/.local/bin/ipython")))
    end)

    it("drops a version suffix from the entrypoint", function()
        assert.are.equal("ipython", repl.resolve(window("ipython id=7", "/usr/bin/python3", "/usr/bin/ipython3")))
    end)

    it("names a package entrypoint by its directory", function()
        assert.are.equal("pymol", repl.resolve(window("zsh",
            "/opt/homebrew/Caskroom/miniforge/base/envs/pymol/bin/python",
            "/opt/homebrew/Caskroom/miniforge/base/envs/pymol/lib/python3.12/site-packages/pymol/__init__.py",
            "-xpq")))
    end)

    it("names the module run with -m", function()
        assert.are.equal("ipython", repl.resolve(window("zsh", "/usr/bin/python3", "-m", "IPython")))
    end)

    it("names the interpreter when a flag sits where an entrypoint would", function()
        assert.are.equal("python", repl.resolve(window("zsh", "/usr/bin/python3", "-i")))
        assert.are.equal("julia", repl.resolve(window("Julia", "/opt/julia/bin/julia", "-t", "4")))
    end)

    it("leaves a script run unnamed, whatever ran it", function()
        -- better than naming the interpreter: code sent there goes to the
        -- script's stdin, not to a prompt
        assert.is_nil(repl.resolve(window("zsh", "/usr/bin/python3", "/home/me/train.py")))
        assert.is_nil(repl.resolve(window("zsh", "/bin/bash", "/home/me/deploy.sh")))
        assert.is_nil(repl.resolve(window("zsh", "/usr/bin/lua", "run.lua")))
        assert.is_nil(repl.resolve(window("zsh", "/usr/bin/python3", "-m", "pytest")))
    end)

    it("leaves an unclaimed program unnamed", function()
        assert.is_nil(repl.resolve(window("notes.md", "/usr/bin/nvim", "notes.md")))
    end)

    it("names the last foreground process, past helpers spawned by the REPL", function()
        assert.are.equal("julia", repl.resolve {
            title = "Julia",
            foreground_processes = {
                { cmdline = { "/usr/local/bin/node", "/plotly/helper.js" } },
                { cmdline = { "/opt/julia/bin/julia" } },
            },
        })
    end)

    it("is unnamed without a foreground process", function()
        assert.is_nil(repl.resolve { title = "zsh", foreground_processes = {} })
        assert.is_nil(repl.resolve { title = "zsh" })
    end)
end)

describe("repl.attach", function()
    local ls
    before_each(function()
        ls = kitty.window
        vim.b.repl_win = nil
    end)
    after_each(function() kitty.window = ls end)

    it("refuses an editor, so a stale focus history cannot bind another nvim", function()
        kitty.window = function() return window("notes.md - Nvim", "/usr/bin/nvim", "notes.md") end
        assert.is_nil(repl.attach(7))
        assert.is_nil(vim.b.repl_win)
    end)

    it("refuses our own window", function()
        local self_win = window("Nvim", "/bin/zsh")
        self_win.is_self = true
        kitty.window = function() return self_win end
        assert.is_nil(repl.attach(7))
    end)

    it("refuses a window that no longer exists", function()
        kitty.window = function() return nil end
        assert.is_nil(repl.attach(7))
    end)

    it("binds and names a REPL window", function()
        kitty.window = function() return window("julia id=7", "/opt/julia/bin/julia") end
        assert.are.equal(7, repl.attach(7))
        assert.are.equal(7, vim.b.repl_win)
        assert.are.same({ 7, "julia" }, { repl.current() })
    end)

    it("keeps a launch hint until the program appears", function()
        -- `kitty @ launch` returns before the program is in foreground_processes
        kitty.window = function() return { id = 7, title = "radian id=7", foreground_processes = {} } end
        repl.attach(7, "radian")
        assert.are.equal("radian", repl.program(7))
    end)

    it("promotes what is running over the hint, which may name a wrapper", function()
        kitty.window = function()
            return window("IPython: me", "/bin/uv", "run", "--with", "ipython", "ipython")
        end
        repl.attach(7, "uv")
        assert.are.equal("ipython", repl.program(7))
    end)

    it("retries an identity it could not resolve", function()
        -- a REPL busy with a subprocess resolves to nothing; that must not stick
        kitty.window = function() return window("ipython id=8", "/usr/bin/git", "push") end
        assert.are.equal(8, repl.attach(8))
        assert.is_nil(repl.program(8))

        kitty.window = function() return window("ipython id=8", "/bin/python3", "/bin/ipython") end
        assert.are.equal("ipython", repl.program(8))
    end)
end)

describe("repl.sent", function()
    local ls
    before_each(function() ls = kitty.window end)
    after_each(function() kitty.window = ls end)

    it("keeps what a window was told while it runs the same program", function()
        kitty.window = function() return window("julia id=9", "/opt/julia/bin/julia") end
        repl.attach(9)
        repl.sent(9)["ctx:revise"] = "using Revise"
        repl.attach(9)
        assert.are.same({ ["ctx:revise"] = "using Revise" }, repl.sent(9))
    end)

    it("drops it once the window runs something else", function()
        kitty.window = function() return window("julia id=10", "/opt/julia/bin/julia") end
        repl.attach(10)
        repl.sent(10)["ctx:revise"] = "using Revise"
        kitty.window = function() return window("ipython id=10", "/bin/python3", "/bin/ipython") end
        repl.attach(10)
        assert.are.same({}, repl.sent(10))
    end)

    it("drops it when a launch takes the window over", function()
        kitty.window = function() return window("julia id=11", "/opt/julia/bin/julia") end
        repl.attach(11)
        repl.sent(11)["ctx:revise"] = "using Revise"
        repl.attach(11, "julia")
        assert.are.same({}, repl.sent(11))
    end)
end)
