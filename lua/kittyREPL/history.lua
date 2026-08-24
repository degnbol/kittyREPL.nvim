-- REPL history files
--
-- A REPL that appends to a history file as it accepts input records what was
-- typed better than its screen does: entries are the source as written,
-- multi-line ones survive whole, and the file reaches back past what the
-- terminal still holds. Which file a program writes and how to read it is
-- config.history; the shipped entries and the reading live here.
local M = {}

local message = require("kittyREPL.message")
local util = require("kittyREPL.util")

---Whether a line ends with an odd number of backslashes, i.e. a continuation.
---Even trailing backslashes are escaped literals, not continuations.
---@param line string
---@return boolean
local function is_continuation(line)
    local n = 0
    for j = #line, 1, -1 do
        if line:sub(j, j) == "\\" then n = n + 1
        else break end
    end
    return n % 2 == 1
end

---Parse shell history text into entries (most recent first).
---Handles zsh extended history (: timestamp:duration;cmd), plain history,
---bash #timestamp lines, and backslash-newline continuations.
---@param text string
---@return string[][]
function M.parse_shell(text)
    local entries = {}
    local lines = vim.split(text, "\n", { trimempty = true })

    -- Parse from end to start, collecting entries most-recent-first
    local i = #lines
    while i >= 1 do
        local line = lines[i]
        -- zsh extended history: ": timestamp:duration;command"
        local entry = line:match("^: %d+:%d+;(.+)") or line
        -- bash HISTTIMEFORMAT: skip bare "#timestamp" lines
        if entry:match("^#%d+$") then
            i = i - 1
            goto continue
        end
        -- join backslash-continuation lines (odd trailing backslashes = continuation)
        while i > 1 and is_continuation(lines[i - 1]) do
            i = i - 1
            local prev = lines[i]
            prev = prev:match("^: %d+:%d+;(.+)") or prev
            -- strip trailing continuation backslash and join
            entry = prev:sub(1, -2) .. "\n" .. entry
        end
        table.insert(entries, vim.split(entry, "\n"))
        i = i - 1
        ::continue::
    end
    return entries
end

---Parse a modal history log into the entries of one mode (most recent first).
---julia's repl_history.jl and radian's history file share this shape: a
---`# time:` line, a `# mode:` line naming which prompt took the entry, then its
---command lines under a prefix. Reading one mode is what keeps a `pkg` or
---`shell` entry from coming back as code for the language.
---@param text string
---@param mode string `# mode:` value to keep, e.g. "julia" or "r"
---@param prefix string one character every command line of an entry starts with
---@return string[][]
function M.parse_modal(text, mode, prefix)
    local entries = {}
    local lines = vim.split(text, "\n")
    local i = 1
    while i <= #lines do
        if lines[i] ~= "# mode: " .. mode then
            i = i + 1
        else
            local entry = {}
            i = i + 1
            while i <= #lines and lines[i]:sub(1, #prefix) == prefix do
                table.insert(entry, lines[i]:sub(#prefix + 1))
                i = i + 1
            end
            if #entry > 0 then table.insert(entries, entry) end
        end
    end
    return vim.iter(entries):rev():totable()
end

---Parse ipython's history table into entries.
---@param text string `sqlite3 -json` output, already ordered most recent first
---@return string[][]
function M.parse_ipython(text)
    -- sqlite3 writes nothing at all for an empty result, which is not json
    if vim.trim(text) == "" then return {} end
    local ok, rows = pcall(vim.json.decode, text)
    if not ok then
        message.warn(tostring(rows))
        return {}
    end
    return vim.iter(rows):map(function(row) return vim.split(row.source_raw or "", "\n") end):totable()
end

---Path a shell writes its history to.
---HISTFILE is a shell variable rather than an exported one, so it is usually
---unset here and the conventional path is what answers.
---@param default string basename under $HOME
---@return fun(): string
local function shell_history(default)
    return function()
        return os.getenv("HISTFILE") or vim.fn.expand("~/" .. default)
    end
end

---Path julia writes its REPL history to.
---@return string
local function julia_history()
    local histfile = os.getenv("JULIA_HISTORY")
    if histfile then return histfile end
    local depot = vim.split(os.getenv("JULIA_DEPOT_PATH") or "", ":", { trimempty = true })[1]
    return vim.fs.joinpath(depot or vim.fn.expand("~/.julia"), "logs", "repl_history.jl")
end

---Path radian writes its history to for a REPL window.
---A file beside the session wins over the global one, and only exists if the
---user asked for one: https://github.com/randy3k/radian prompt_session.py:114
---The cwd is the one the window reports now, which an R-side setwd() has moved,
---where radian chose its file at startup.
---@param win integer
---@return string
local function radian_history(win)
    -- required here rather than at the top, config requiring this module and
    -- kitty requiring config
    local window = require("kittyREPL.kitty").window(win)
    local beside = window and window.cwd and vim.fs.joinpath(window.cwd, ".radian_history")
    if beside and vim.uv.fs_stat(beside) then return beside end
    return vim.fn.expand("~/.radian_history")
end

---Path ipython writes its history database to.
---@return string
local function ipython_history()
    local dir = os.getenv("IPYTHONDIR") or vim.fn.expand("~/.ipython")
    return vim.fs.joinpath(dir, "profile_default", "history.sqlite")
end

-- how far back to read, in lines for a text file and in entries for a database
local LIMIT = 500

-- once, not per recall: a REPL whose history file is missing or unreadable is in
-- that state for the session, and recall falls back to the screen every time
---Read the tail of a text history file.
---@param path string
---@return string|nil
local function read_tail(path)
    local ok, lines = pcall(vim.fn.readfile, path, "", -LIMIT)
    if not ok then
        message.warn_once(tostring(lines))
        return
    end
    return table.concat(lines, "\n")
end

---Read ipython's history table, which is sqlite rather than text.
---@param path string
---@return string|nil nil without the sqlite3 binary, leaving recall to the screen
local function read_sqlite(path)
    local ok, out = pcall(util.exec, { "sqlite3", "-json", path,
        "select source_raw from history order by rowid desc limit " .. LIMIT })
    if not ok then
        message.warn_once(tostring(out))
        return
    end
    if out.code ~= 0 then
        local err = vim.trim(out.stderr or "")
        message.warn_once(err ~= "" and err or "sqlite3 exited " .. out.code)
        return
    end
    return out.stdout
end

---@class kittyREPL.HistoryReader
---@field path fun(win: integer): string|nil file the program's history is in,
---nil to leave recall to the screen
---@field read? fun(path: string): string|nil its text, defaulting to the file's tail
---@field parse fun(text: string): string[][] entries, most recent first

---Shipped readers, keyed by program. The REPLs missing from here either write
---their history only at exit (python, R), or never do (lua, pymol).
---@type table<string, kittyREPL.HistoryReader>
M.readers = {
    zsh     = { path = shell_history(".zsh_history"),  parse = M.parse_shell },
    bash    = { path = shell_history(".bash_history"), parse = M.parse_shell },
    sh      = { path = shell_history(".bash_history"), parse = M.parse_shell },
    julia   = { path = julia_history, parse = function(text) return M.parse_modal(text, "julia", "\t") end },
    radian  = { path = radian_history, parse = function(text) return M.parse_modal(text, "r", "+") end },
    ipython = { path = ipython_history, read = read_sqlite, parse = M.parse_ipython },
}

---Entries a REPL's history file holds, most recent first, each a list of lines.
---A reader is user config, so a fault in one reports rather than throwing out of
---whatever keymap asked to recall.
---@param reader kittyREPL.HistoryReader
---@param win integer window whose REPL wrote the file
---@return string[][]
function M.read(reader, win)
    local ok, entries = pcall(function()
        local path = reader.path(win)
        if not path then return {} end
        local text = (reader.read or read_tail)(path)
        return text and reader.parse(text) or {}
    end)
    if not ok then
        message.error("history reader: " .. tostring(entries))
        return {}
    end
    return entries
end

return M
