-- Scrollback parsing and navigation
local M = {}

local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")

-- Module state
local scrollback = ""
local tScrollback = {}
local iScrollback = 0

---Read the raw scrollback text and reset parsing state.
function M.read()
    scrollback = kitty.get_scrollback() or ""
    tScrollback = {}
    iScrollback = 0
end

---Parse one command entry from the scrollback text and truncate the text afterwards.
---@return table? lines array of command lines
local function parseScrollback()
    local pat, patCont = unpack(config.match.prompt[vim.b.repl_cmd])
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
    M.read()
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
        -- edge case where replaceScroll is called before startScroll
        if iScrollback == 0 then M.read() end
        local rcmd = M.scroll(delta)
        vim.fn.setreg("k", rcmd)
        vim.cmd.normal('"kpv`[o')
    end
end

---Get the current scrollback index.
---@return integer
function M.get_index()
    return iScrollback
end

return M
