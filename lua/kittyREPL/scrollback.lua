-- Scrollback parsing and navigation
local M = {}

local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")
local repl = require("kittyREPL.repl")
local history = require("kittyREPL.history")
local message = require("kittyREPL.message")

-- Module state: one walk backwards through what a REPL has been told, either
-- read whole out of its history file or cut off the end of `scrollback` an entry
-- at a time as `prompt` finds them.
local scrollback = ""
local prompt = nil
local tScrollback = {}
local iScrollback = 0

---Lua pattern matching a prompt at the start of a line and ending in a position
---capture, i.e. the column its command text begins at.
---Digit runs generalise, which is what makes a prompt read as "In [4]: " match
---the "In [1]: " further up the screen.
---@param rendered string prompt as it appears on screen
---@return string
local function promptPattern(rendered)
    return "^" .. (vim.pesc(rendered):gsub("%d+", "%%d+")) .. "()"
end

---How many lines of a text a prompt pattern matches.
---@param text string
---@param pattern string
---@return integer
local function promptLines(text, pattern)
    local n = 0
    for line in vim.gsplit(text, "\n") do
        if line:match(pattern) then n = n + 1 end
    end
    return n
end

---Prompt pattern to cut a window's scrollback into commands with.
---Read off the running REPL rather than shipped, every prompt here being the
---user's own configuration of it, and confirmed against the scrollback it will
---be used on: mid-typing the cursor sits after the typed text exactly as it sits
---after a prompt, and what tells the two apart is how often the rest of the
---screen repeats them.
---@param win integer
---@param program string|nil
---@param text string `--extent=all` scrollback the pattern has to cut up
---@return string|nil
local function promptFor(win, program, text)
    local override = config.prompt[program]
    if override then return "^" .. override .. "()" end
    local name = program or "REPL"
    local cached = repl.prompt(win)
    -- kept while the scrollback still shows it, so a REPL switched into another
    -- mode keeps the prompt its earlier lines carry. What re-learns is a window
    -- with no trace of the cached prompt left, i.e. one running something else.
    if cached and promptLines(text, cached) > 0 then return cached end
    local window = kitty.window(win)
    if not window then return end
    if window.in_alternate_screen then
        message.warn("cannot read a prompt behind a pager")
        return
    end
    local screen = kitty.get_screen(win)
    local rendered = screen and kitty.prompt_at_cursor(screen)
    if not rendered then
        message.warn(name .. " is not at a prompt")
        return
    end
    local pattern = promptPattern(rendered)
    -- two rather than one: a half-typed line can still reproduce a command run
    -- earlier, and asking for a second occurrence rules that out
    if promptLines(text, pattern) < 2 then
        message.warn("could not confirm " .. name .. ' prompt "' .. rendered .. '"')
        return
    end
    repl.remember_prompt(win, pattern)
    message.info(name .. ' prompt "' .. rendered .. '"')
    return pattern
end

---Read what a REPL was told, most recent first, and reset the walk over it.
---A program that keeps its own history file is read from that; the rest are read
---off the screen, which needs the prompt they draw.
---@param win integer
---@param program string|nil program running in the REPL
function M.read(win, program)
    tScrollback, iScrollback, scrollback, prompt = {}, 0, "", nil
    local reader = config.history[program]
    if reader then tScrollback = history.read(reader, win) end
    if #tScrollback > 0 then return end
    scrollback = kitty.get_scrollback(win) or ""
    prompt = promptFor(win, program, scrollback)
end

---Parse one command entry from the scrollback text and truncate the text afterwards.
---Only the line the prompt is on: a REPL's continuation prompt cannot be read
---off the screen the way its primary one can, so a multi-line command comes back
---as its first line. Recalling one whole is what the history readers are for.
---@return table? lines array of command lines
local function parseScrollback()
    if not prompt then return end
    while true do
        local lastline = scrollback:match("\n([^\n]*)$")
        if lastline == nil then return end
        scrollback = scrollback:sub(1, #scrollback - #lastline - 1)
        local mPrompt = lastline:match(prompt)
        if mPrompt ~= nil then return { lastline:sub(mPrompt) } end
    end
end

---Scroll through REPL commands, while parsing scrollback when necessary.
---@param delta integer 1 or -1
---@return table? lines array of command lines
function M.scroll(delta)
    if vim.v.count ~= 0 then
        delta = delta * vim.v.count
    end
    if delta > 0 then
        for _ = 1, delta do
            if iScrollback == #tScrollback then
                -- skip empty prompts
                local rcmd = { "" }
                while table.concat(rcmd) == "" do
                    rcmd = parseScrollback()
                    if rcmd == nil then
                        message.status("top of scrollback")
                        return tScrollback[iScrollback]
                    end
                end
                table.insert(tScrollback, rcmd)
            end
            iScrollback = iScrollback + 1
        end
        message.status("entry " .. iScrollback)
        return tScrollback[iScrollback]
    else
        iScrollback = iScrollback + delta
        if iScrollback < 1 then
            iScrollback = 1
            message.status("bottom of scrollback")
        else
            message.status("entry " .. iScrollback)
        end
        return tScrollback[iScrollback]
    end
end

---Start scrolling through scrollback, inserting first command at cursor.
function M.startScroll()
    local win, program = repl.current()
    if not win then return end
    M.read(win, program)
    local rcmd = M.scroll(1)
    if rcmd == nil then return end
    vim.api.nvim_put(rcmd, "c", true, false)
    vim.cmd.normal("v`[o")
end

---Create a function that replaces current selection with scrollback entry.
---@param delta integer
---@return function
function M.replaceScroll(delta)
    return function()
        local win, program = repl.current()
        if not win then return end
        -- edge case where replaceScroll is called before startScroll
        if iScrollback == 0 then M.read(win, program) end
        local rcmd = M.scroll(delta)
        if rcmd == nil then return end
        vim.fn.setreg("k", rcmd)
        vim.cmd.normal('"kpv`[o')
    end
end

---Paste last REPL command output as comments.
---@param after boolean insert after cursor line (true) or before (false)
function M.pasteOutput(after)
    local win = repl.win()
    if not win then return end
    local text = kitty.get_last_output(win)
    if not text then
        message.warn("no output to paste")
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
