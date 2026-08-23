-- Low-level kitty terminal communication
--
-- Every function that talks to a REPL takes the target window id explicitly. The
-- buffer -> window binding lives in repl.lua.
local M = {}

local config = require("kittyREPL.config")

---Run a command to completion.
---Swapped out in tests to exercise the send path without kitty.
---@param argv string[]
---@param stdin string|nil written to the child's stdin, which is then closed
---@return vim.SystemCompleted
function M._exec(argv, stdin)
    -- no text=true: get-text output is passed through byte for byte
    return vim.system(argv, { stdin = stdin }):wait()
end

---Run a `kitty @` command.
---@param argv string[] arguments following `kitty @`
---@param stdin string|nil
---@param no_match_ok boolean? treat a window that does not exist as an expected
---nil instead of an error, which is how the existence check is expressed
---@return string|nil stdout
local function kitty_cmd(argv, stdin, no_match_ok)
    -- vim.system raises rather than returns when it cannot spawn at all, which
    -- is every mapped key on a machine without the kitty CLI
    local ok, out = pcall(M._exec, vim.list_extend({ "kitty", "@" }, argv), stdin)
    if not ok then
        vim.notify_once("kittyREPL: " .. tostring(out), vim.log.levels.WARN)
        return
    end
    if out.code == 0 then return out.stdout end
    local err = vim.trim(out.stderr or "")
    if no_match_ok and err:find("No matching windows", 1, true) then return end
    -- once: an unusable remote control fails identically on every key
    vim.notify_once("kittyREPL: " .. err, vim.log.levels.WARN)
end

---Read text out of a kitty window.
---@param win integer
---@param ... string `kitty @ get-text` flags
---@return string|nil
local function get_text(win, ...)
    return kitty_cmd({ "get-text", "--match=id:" .. win, ... })
end

---Parse kitty @ ls output into table.
---@param match string? optionally filter with --match argument
---@return table?
function M.ls(match)
    local argv = { "ls" }
    if match then table.insert(argv, "--match=" .. match) end
    -- a filtered ls is the existence check, so its no-match is a value, not a fault
    local json_string = kitty_cmd(argv, nil, match ~= nil)
    if not json_string then return end
    return vim.json.decode(json_string)
end

---Get the currently focused tab.
---@return table?
function M.get_focused_tab()
    local ls = M.ls()
    if not ls then return end
    for _, os_win in ipairs(ls) do
        if os_win.is_focused then
            for _, tab in ipairs(os_win.tabs) do
                if tab.is_focused then
                    return tab
                end
            end
        end
    end
end

---Get the `kitty @ ls` record for one window.
---Nil once the window is gone: `--match` with nothing to match is an error, which
---M.ls reports as nil, and that is what makes this the existence check.
---@param win integer
---@return table|nil
function M.window(win)
    -- the --match=id: filter keeps the whole hierarchy, but "tabs" and "windows"
    -- then hold one entry each.
    local ls = M.ls("id:" .. win)
    if not ls or not ls[1] or not ls[1].tabs or not ls[1].tabs[1] then return end
    return ls[1].tabs[1].windows[1]
end

---Get window id of the ith window visible on the current tab.
---@param i integer
---@return integer?
function M.get_winid(i)
    local tab = M.get_focused_tab()
    if not tab then return end
    local win = tab.windows[i]
    if not win then return end
    return win.id
end

---Focus a kitty window.
---@param win integer
function M.focus(win)
    kitty_cmd({ "focus-window", "--match=id:" .. win })
end

---Send raw text to the REPL (no processing).
---@param win integer
---@param text string
function M.send_raw(win, text)
    kitty_cmd({ "send-text", "--stdin", "--match=id:" .. win }, text)
end

---Send text using bracketed paste mode.
---@param win integer
---@param text string
---@param post string
function M.send_bracketed(win, text, post)
    M.send_raw(win, "\x1b[200~" .. text .. "\x1b[201~" .. post)
end

---Fixes indentation by prepending Start Of Header signal.
---This can be a fallback method if a REPL doesn't support bracketed paste,
---however each line will then be sent and called separately, which may be a
---problem if there are empty lines within the sent block.
---@param text string
---@return string
function M.SOH(text)
    return (text:gsub('\n', '\n\x01'))
end

---Send text to the REPL with appropriate method based on config.
---An unresolved program falls through to a raw send, the conservative default.
---@param win integer
---@param program string|nil program running in the REPL
---@param text string
---@param post string
---@param raw boolean? send as if the program were unknown
function M.send(win, program, text, post, raw)
    if config.closepager and M.detect_pager(win) then
        M.send_raw(win, "q")
    end
    -- an unknown program is already the raw fallthrough, so asking for a raw
    -- send is the same as forgetting which program this is
    if raw then program = nil end
    if config.custom[program] then
        config.custom[program](win, text, post)
    elseif config.bracketed[program] then
        if text:find("\n") then
            M.send_bracketed(win, text, post)
        else
            M.send_raw(win, text .. post)
        end
    elseif config.linewise[program] then
        for _, line in ipairs(vim.split(text, '\n')) do
            if line ~= "" then
                M.send_raw(win, line .. '\n')
            end
        end
        M.send_raw(win, post)
    else
        M.send_raw(win, text .. post)
    end
end

---Run text in the REPL (send with newline).
---@param win integer
---@param program string|nil
---@param text string
---@param raw boolean?
function M.run(win, program, text, raw)
    M.send(win, program, text, '\n', raw)
end

---Paste text to the REPL (send without trailing newline).
---@param win integer
---@param program string|nil
---@param text string
---@param raw boolean?
function M.paste(win, program, text, raw)
    M.send(win, program, text:gsub('\n$', ''), '', raw)
    if config.editpaste then M.focus(win) end
end

---Detect whether the REPL is currently displaying a pager (e.g. help texts).
---@param win integer
---@return boolean
function M.detect_pager(win)
    local scrollback = get_text(win, "--extent=screen", "--add-cursor")
    if not scrollback then return false end
    -- Get cursor position to check if it is placed right after a pager pattern to match.
    -- Lua pattern explanation:
    -- Matched pattern is ^[[?25h^[[n;mH^[[?12h where
    -- ^[ is ESC and ^[[ is known as CSI (Control Sequence Introducer)
    -- n is an integer indicating cursor row and m indicates cursor column. Both 1-indexed.
    -- ^[[?25h means "show the cursor". I don't know what ^[[?12h does.
    -- https://en.wikipedia.org/wiki/ANSI_escape_code
    local helplines, lastline, blanklines, r, c = scrollback:match(
        "(.*)\n([^\n]+)(\n*)%c%[%?25h%c%[(%d+);(%d+)H%c%[%?%d+h\n$")
    -- if we aren't scrolled to the bottom lastline will be nil.
    if lastline == nil then return false end
    local pagerMatch = lastline:match("^(:)")
    if pagerMatch and #blanklines > 0 then return false end
    if not pagerMatch then pagerMatch = lastline:match("^%(END%)") end
    if not pagerMatch then return false end
    local _, nlines = helplines:gsub('\n', '')
    -- +2 since "lines" doesn't contain "lastline" and the newline right before it.
    return tonumber(r) == nlines + 2 and tonumber(c) == #pagerMatch + 1
end

---Get scrollback text from the REPL.
---@param win integer
---@return string?
function M.get_scrollback(win)
    return get_text(win, "--extent=all")
end

---Get last command output from the REPL (requires kitty shell integration).
---@param win integer
---@return string?
function M.get_last_output(win)
    local text = get_text(win, "--extent=last_cmd_output")
    if text == "" then return end
    return text
end

---Send a SIGINT to the REPL.
---@param win integer
function M.interrupt(win)
    kitty_cmd({ "signal-child", "--match=id:" .. win })
end

---Launch a new kitty window.
---@param command string?
---@return integer? window_id
function M.launch(command)
    local argv = { "launch", "--cwd=current", "--keep-focus" }
    -- config.command values are user-authored strings, so they arrive as one
    -- word-splittable string; vim.split keeps them off a shell command line.
    vim.list_extend(argv, vim.split(command or "", "%s+", { trimempty = true }))
    local out = kitty_cmd(argv)
    return out and tonumber(out)
end

---Set the title of a kitty window.
---@param win integer
---@param title string
function M.set_title(win, title)
    kitty_cmd({ "set-window-title", "--match=id:" .. win, title })
end

return M
