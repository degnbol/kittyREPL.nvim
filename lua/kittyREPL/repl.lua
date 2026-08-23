-- Which program runs in which kitty window
--
-- Identity is a property of the window, not of the buffer: one REPL serves many
-- buffers, and they must agree on what runs there. The buffer -> window binding
-- is the per-buffer part and stays in vim.b.repl_win.
local M = {}

local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")
local message = require("kittyREPL.message")

-- [win] = { program = "radian"|nil, pending = "radian"|nil }
-- `pending` is the launch word, standing in until resolution succeeds:
-- `kitty @ launch` returns before the program appears in foreground_processes.
local wins = {}

---Program name a command word invokes.
---A trailing version is dropped, so a program whose own name ends in a digit
---cannot be named this way.
---@param word string
---@return string
function M.progname(word)
    -- :r drops both a script extension and a version tail ("python3.14")
    local name = vim.fn.fnamemodify(word, ":t:r"):lower()
    -- a package entrypoint is named by its directory: ".../pymol/__init__.py"
    if name == "__init__" then
        name = vim.fn.fnamemodify(word, ":h:t"):lower()
    end
    -- "-zsh" is a login shell; "python3" is python
    return (name:gsub("^%-", ""):gsub("%d+$", ""))
end

---Whether any filetype accepts a program as its REPL.
---@param name string
---@return boolean
local function claimed(name)
    for _, programs in pairs(config.programs) do
        if programs[name] then return true end
    end
    return false
end

---Argv of the last foreground process of a kitty window.
---The last one, because starting julia and then `using PlotlyJS` spawns helper
---processes that are listed earlier.
---@param window table `kitty @ ls` record
---@return string[]|nil
local function cmdline(window)
    local procs = window.foreground_processes
    if not procs or #procs == 0 then return nil end
    return procs[#procs].cmdline
end

---Program name running in a kitty window, from its `kitty @ ls` record.
---A program no filetype claims is left unnamed rather than approximated: a
---"python3 train.py" window is not a REPL anything knows how to talk to.
---@param window table
---@return string|nil
function M.resolve(window)
    -- over ssh the cmdline is ["ssh", ...], leaving only the title to go by
    if window.title and window.title:match("^IPython:") then return "ipython" end
    local argv = cmdline(window)
    if not argv or not argv[1] then return nil end
    local name = M.progname(argv[1])
    -- an interpreter names its entrypoint, not itself: radian runs as
    -- ["python3", ".../bin/radian"]. A flag where the entrypoint would be
    -- ("python3 -i") means there is none, so the interpreter is the program.
    local entry = argv[2] == "-m" and argv[3] or argv[2]
    if entry and not entry:match("^%-") then
        name = M.progname(entry)
    end
    if claimed(name) then return name end
    return nil
end

---Whether a kitty window holds an editor, which we would never send code to.
---@param window table
---@return boolean
local function is_editor(window)
    if window.is_self then return true end
    local argv = cmdline(window)
    if not argv or not argv[1] then return false end
    return M.progname(argv[1]) == "nvim"
end

---Cache a resolved program name for a window.
---A nil resolution is not cached: a REPL busy with a subprocess resolves to
---nothing, and caching that would leave the window unnamed for the session.
---@param win integer
---@param program string|nil
local function remember(win, program)
    if not program then return end
    local state = wins[win] or {}
    state.program, state.pending = program, nil
    wins[win] = state
end

---Fetch a window's record, caching what it resolves to.
---@param win integer
---@return table|nil window `kitty @ ls` record, nil once the window is gone
---@return string|nil program
local function identify(win)
    local window = kitty.window(win)
    if not window then return nil end
    local program = M.resolve(window)
    remember(win, program)
    return window, program
end

---Bind the current buffer to a REPL window and record what runs there.
---@param win integer|nil
---@param hint string|nil program name from the command a launch was asked for
---@return integer|nil win nil if the window is unusable
function M.attach(win, hint)
    if not win then return nil end
    if hint then
        wins[win] = { pending = hint }
        vim.b.repl_win = win
        return win
    end
    local window = identify(win)
    if not window then
        message.warn("no kitty window with id " .. win)
        return nil
    end
    if is_editor(window) then
        message.warn("kitty window " .. win .. " is an editor")
        return nil
    end
    vim.b.repl_win = win
    return win
end

---Re-check that the buffer's binding still points at a usable REPL.
---Refreshes identity from the record it already had to fetch, so a resolvable
---program costs one round trip here instead of one here and one in M.program.
---@return integer|nil win nil when unbound, gone, or now running an editor
function M.revalidate()
    local win = M.win()
    if not win then return nil end
    local window = identify(win)
    if not window or is_editor(window) then return nil end
    return win
end

---Program running in a window, resolved on first use and cached.
---@param win integer
---@return string|nil
function M.program(win)
    local state = wins[win]
    if state and state.program then return state.program end
    local _, program = identify(win)
    return program or (state and state.pending)
end

---The window this buffer sends to.
---@return integer|nil
function M.win()
    return vim.b.repl_win
end

---The window this buffer sends to and the program running in it.
---Costs a kitty round trip when the identity is not yet cached, so prefer
---M.win() where the program is not needed.
---@return integer|nil win
---@return string|nil program
function M.current()
    local win = M.win()
    if not win then return nil end
    return win, M.program(win)
end

return M
