---@diagnostic disable: undefined-global
-- setup() merges user config over the defaults. It must not clobber what the
-- user passed, and calling it again must not compound anything.
local config = require("kittyREPL.config")

describe("setup", function()
    local defaults
    before_each(function()
        defaults = vim.deepcopy(config)
    end)
    after_each(function()
        for k in pairs(config) do config[k] = nil end
        for k, v in pairs(defaults) do config[k] = v end
    end)

    it("keeps a user sender for a program that ships with one", function()
        local mine = function() end
        require("kittyREPL").setup({ custom = { pymol = mine } })
        assert.are.equal(mine, config.custom.pymol)
    end)

    it("leaves the other defaults of an overridden table in place", function()
        require("kittyREPL").setup({ custom = { pymol = function() end } })
        assert.are.equal(defaults.custom.lua, config.custom.lua)
    end)

    it("leaves prompt patterns bare, however often it runs", function()
        require("kittyREPL").setup()
        require("kittyREPL").setup()
        assert.are.same({ ">>> ", "... " }, config.match.prompt.python)
    end)
end)
