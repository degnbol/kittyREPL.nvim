---@diagnostic disable: undefined-global
-- Finding a REPL among the windows of a kitty tab. cmdlines are real
-- `kitty @ ls` foreground_processes values.
local detect = require("kittyREPL.detect")
local kitty = require("kittyREPL.kitty")

---A `kitty @ ls` window record with one foreground process.
---@param id integer
---@param ... string cmdline words
---@return table
local function window(id, ...)
    return { id = id, foreground_processes = { { cmdline = { ... } } } }
end

describe("detect.detect_REPL", function()
    local tab, win, notify, notified
    before_each(function()
        tab, win, notify = kitty.get_focused_tab, kitty.window, vim.notify
        notified = {}
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg) table.insert(notified, msg) end
        vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
        vim.b.repl_win = nil
    end)
    after_each(function()
        kitty.get_focused_tab, kitty.window, vim.notify = tab, win, notify
    end)

    ---Answer with one tab holding the given windows, and with each of them by id.
    ---@param windows table[]
    local function tabOf(windows)
        kitty.get_focused_tab = function() return { windows = windows } end
        kitty.window = function(id)
            for _, w in ipairs(windows) do
                if w.id == id then return w end
            end
        end
    end

    it("warns for a filetype no programs are configured for", function()
        vim.bo.filetype = "tex"
        tabOf({ window(3, "/opt/julia/bin/julia") })
        assert.is_nil(detect.detect_REPL())
        assert.are.same({ "REPL: no programs configured for filetype tex. " ..
            "Set the REPL window manually." }, notified)
    end)

    it("takes a compound filetype as claimed by any of its parts", function()
        -- the claiming part second, so a first part with no entry of its own
        -- does not end the walk
        vim.bo.filetype = "quarto.python"
        tabOf({ window(4, "/usr/bin/python3", "/usr/bin/ipython") })
        assert.are.equal(4, detect.detect_REPL())
        assert.are.equal(4, vim.b.repl_win)
    end)

    it("walks past an editor to the REPL behind it", function()
        vim.bo.filetype = "julia"
        tabOf({
            window(5, "/usr/bin/nvim", "main.jl"),
            window(6, "/opt/julia/bin/julia"),
        })
        assert.are.equal(6, detect.detect_REPL())
    end)

    it("finds nothing on a tab running no REPL the filetype accepts", function()
        vim.bo.filetype = "julia"
        tabOf({ window(7, "/usr/bin/python3", "/usr/bin/ipython") })
        assert.is_nil(detect.detect_REPL())
        assert.are.same({}, notified)
    end)
end)
