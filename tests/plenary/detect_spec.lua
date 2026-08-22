---@diagnostic disable: undefined-global
-- cmdlines and titles are real `kitty @ ls` foreground_processes/title values.
local detect = require("kittyREPL.config").match.detect

describe("match.detect.r", function()
    it("detects R", function()
        assert.are.equal("r", detect.r(
            { "/Library/Frameworks/R.framework/Resources/bin/exec/R", "--no-save", "--quiet" }, "R"))
    end)

    it("detects radian under its own name, not R's", function()
        assert.are.equal("radian", detect.r(
            { "/Users/me/.local/share/uv/tools/radian/bin/python3", "/Users/me/.local/bin/radian" }, "radian id=7"))
    end)

    it("ignores other programs", function()
        assert.is_nil(detect.r({ "/opt/julia/bin/julia" }, "Julia"))
    end)
end)

describe("match.detect.sh", function()
    it("detects each shell by its own name", function()
        assert.are.equal("zsh", detect.sh({ "-zsh", "-l" }, "~"))
        assert.are.equal("bash", detect.sh({ "/bin/bash", "--posix", "-l" }, "bash"))
        assert.are.equal("sh", detect.sh({ "/bin/sh" }, "sh"))
    end)

    it("ignores other programs", function()
        assert.is_nil(detect.sh({ "/opt/julia/bin/julia" }, "Julia"))
    end)

    it("is reachable from the zsh and bash filetypes", function()
        assert.are.equal("zsh", detect.zsh({ "-zsh", "-l" }, "~"))
        assert.are.equal("bash", detect.bash({ "/bin/bash", "--posix", "-l" }, "bash"))
    end)
end)

describe("match.detect.julia", function()
    it("detects julia", function()
        assert.are.equal("julia", detect.julia(
            { "/Users/me/.julia/juliaup/julia-1.12.6+0.aarch64.apple.darwin14/Julia-1.12.app/Contents/Resources/julia/bin/julia" },
            "Julia"))
    end)

    it("ignores other programs", function()
        assert.is_nil(detect.julia({ "/bin/sh" }, "sh"))
    end)
end)

describe("match.detect.python", function()
    it("detects stock python", function()
        assert.are.equal("python", detect.python(
            { "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python" },
            "zsh"))
    end)

    it("detects ipython from the window title", function()
        assert.are.equal("ipython", detect.python(
            { "/Users/me/.local/share/uv/tools/ipython/bin/python3", "/Users/me/.local/bin/ipython" },
            "IPython: Users/me"))
    end)

    it("detects ipython from the cmdline when the title was overwritten", function()
        assert.are.equal("ipython", detect.python(
            { "/Users/me/.local/share/uv/tools/ipython/bin/python3", "/Users/me/.local/bin/ipython" },
            "ipython id=7"))
    end)

    it("detects a versioned ipython entrypoint", function()
        assert.are.equal("ipython", detect.python({ "/usr/bin/python3", "/usr/bin/ipython3" }, "ipython id=7"))
    end)

    it("detects pymol from the script path", function()
        assert.are.equal("pymol", detect.python({
            "/opt/homebrew/Caskroom/miniforge/base/envs/pymol/bin/python",
            "/opt/homebrew/Caskroom/miniforge/base/envs/pymol/lib/python3.12/site-packages/pymol/__init__.py",
            "-xpq",
        }, "zsh"))
    end)

    it("ignores other programs", function()
        assert.is_nil(detect.python({ "/opt/julia/bin/julia" }, "Julia"))
    end)
end)

describe("program names", function()
    -- match.prompt is the one program-keyed table that has to be total:
    -- scrollback.parseScrollback refuses to parse without a prompt pattern,
    -- where bracketed/linewise/help all have a meaningful missing case.
    local config = require("kittyREPL.config")
    local names = { "r", "radian", "python", "ipython", "pymol", "julia", "zsh", "bash", "sh" }

    for _, name in ipairs(names) do
        it("has a prompt pattern for " .. name, function()
            assert.is_not_nil(config.match.prompt[name])
        end)
    end
end)
