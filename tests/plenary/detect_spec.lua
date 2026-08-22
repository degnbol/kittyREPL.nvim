---@diagnostic disable: undefined-global
local detect = require("kittyREPL.config").match.detect

describe("match.detect.r", function()
    it("detects R", function()
        assert.are.equal("r", detect.r({ "/usr/local/bin/R" }))
    end)

    it("detects radian", function()
        assert.are.equal("r", detect.r({ "/usr/bin/python3", "/usr/local/bin/radian" }))
    end)

    it("does not claim a julia window", function()
        -- detect functions are called as (cmdline, title); this one ignores the title
        ---@diagnostic disable-next-line: redundant-parameter
        assert.is_nil(detect.r({ "/usr/local/bin/julia" }, "server-name: julia"))
    end)
end)

describe("match.detect.sh", function()
    it("detects each shell by its own name", function()
        assert.are.equal("zsh", detect.sh({ "/bin/zsh" }))
        assert.are.equal("bash", detect.sh({ "/usr/local/bin/bash" }))
        assert.are.equal("sh", detect.sh({ "/bin/sh" }))
    end)

    it("ignores other programs", function()
        assert.is_nil(detect.sh({ "/usr/local/bin/julia" }))
    end)
end)

describe("match.detect.python", function()
    it("detects ipython from the window title", function()
        assert.are.equal("ipython", detect.python({ "/usr/bin/python3" }, "IPython: ~/src"))
    end)

    it("detects pymol from the script path", function()
        assert.are.equal("pymol", detect.python({ "/usr/bin/python3", "/opt/lib/pymol/__init__.py" }, ""))
    end)

    it("distinguishes python from ipython", function()
        assert.are.equal("python", detect.python({ "/usr/bin/python3" }, ""))
        assert.are.equal("ipython", detect.python({ "/usr/bin/ipython3" }, ""))
    end)
end)
