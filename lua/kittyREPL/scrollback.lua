-- Scrollback parsing and navigation
local M = {}

local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")
local repl = require("kittyREPL.repl")

-- Module state
local scrollback = ""
local tScrollback = {}
local iScrollback = 0

local shells = { zsh = true, bash = true, sh = true }

---Check if line ends with an odd number of backslashes (i.e. a continuation).
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
---Each entry is a table of lines, matching parseScrollback() format.
---Handles zsh extended history (: timestamp:duration;cmd), plain history,
---bash #timestamp lines, and backslash-newline continuations.
---@param text string raw history file content
---@return table[]
function M.parseHistoryText(text)
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
        local entryLines = vim.split(entry, "\n")
        table.insert(entries, entryLines)
        i = i - 1
        ::continue::
    end
    return entries
end

---Path of the history file for a shell.
---@param shell string
---@return string
local function histfile(shell)
    -- HISTFILE is a shell variable (not exported), so os.getenv usually returns nil.
    -- Fall back to conventional paths.
    return os.getenv("HISTFILE")
        or os.getenv("HOME") .. (shell == "zsh" and "/.zsh_history" or "/.bash_history")
end

---Read the tail of a shell history file as entries (most recent first).
---@param path string
---@return table[]
function M.readHistory(path)
    local ok, result = pcall(vim.fn.readfile, path, "", -500)
    if not ok then
        vim.notify("kittyREPL: " .. result, vim.log.levels.WARN)
        return {}
    end
    return M.parseHistoryText(table.concat(result, "\n"))
end

---Read the raw scrollback text and reset parsing state.
---@param program string|nil program running in the REPL
function M.read(program)
    tScrollback = {}
    iScrollback = 0
    if shells[program] then
        tScrollback = M.readHistory(histfile(program))
        scrollback = ""
    else
        scrollback = kitty.get_scrollback() or ""
    end
end

---Parse one command entry from the scrollback text and truncate the text afterwards.
---@param program string|nil
---@return table? lines array of command lines
local function parseScrollback(program)
    local prompt = config.match.prompt[program]
    if not prompt then
        vim.notify("kittyREPL: no prompt pattern for REPL " .. tostring(program), vim.log.levels.WARN)
        return
    end
    local pat, patCont = unpack(prompt)
    local lines = {}
    while true do
        local lastline = scrollback:match("\n([^\n]*)$")
        if lastline == nil then return end
        scrollback = scrollback:sub(1, #scrollback - #lastline - 1)
        local mPrompt = lastline:match(pat)
        if mPrompt ~= nil then
            local rcmd = { lastline:sub(mPrompt) }
            for _, line in ipairs(lines) do
                local mPromptCont = line:match(patCont)
                if mPromptCont ~= nil then
                    table.insert(rcmd, line:sub(mPromptCont))
                else
                    return rcmd
                end
            end
            return rcmd
        else
            table.insert(lines, 1, lastline)
        end
    end
end

---Scroll through REPL commands, while parsing scrollback when necessary.
---@param delta integer 1 or -1
---@param program string|nil
---@return table? lines array of command lines
function M.scroll(delta, program)
    if vim.v.count ~= 0 then
        delta = delta * vim.v.count
    end
    if delta > 0 then
        for _ = 1, delta do
            if iScrollback == #tScrollback then
                -- skip empty prompts
                local rcmd = { "" }
                while table.concat(rcmd) == "" do
                    rcmd = parseScrollback(program)
                    if rcmd == nil then
                        print("REPL top")
                        return tScrollback[iScrollback]
                    end
                end
                table.insert(tScrollback, rcmd)
            end
            iScrollback = iScrollback + 1
        end
        print(iScrollback)
        return tScrollback[iScrollback]
    else
        iScrollback = iScrollback + delta
        if iScrollback < 1 then
            iScrollback = 1
            print("REPL bottom")
        else
            print(iScrollback)
        end
        return tScrollback[iScrollback]
    end
end

---Start scrolling through scrollback, inserting first command at cursor.
function M.startScroll()
    local _, program = repl.current()
    M.read(program)
    local rcmd = M.scroll(1, program)
    if rcmd == nil then return end
    vim.api.nvim_put(rcmd, "c", true, false)
    vim.cmd.normal("v`[o")
end

---Create a function that replaces current selection with scrollback entry.
---@param delta integer
---@return function
function M.replaceScroll(delta)
    return function()
        local _, program = repl.current()
        -- edge case where replaceScroll is called before startScroll
        if iScrollback == 0 then M.read(program) end
        local rcmd = M.scroll(delta, program)
        if rcmd == nil then return end
        vim.fn.setreg("k", rcmd)
        vim.cmd.normal('"kpv`[o')
    end
end

---Paste last REPL command output as comments.
---@param after boolean insert after cursor line (true) or before (false)
function M.pasteOutput(after)
    local text = kitty.get_last_output()
    if not text then
        print("No output")
        return
    end
    local cs = vim.bo.commentstring
    local outLines = vim.split(text:gsub("\n$", ""), "\n")
    for i, line in ipairs(outLines) do
        outLines[i] = cs:format(line)
    end
    vim.api.nvim_put(outLines, "l", after, false)
end

return M
