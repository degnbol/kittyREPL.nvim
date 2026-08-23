-- Low-level kitty terminal communication
local M = {}

local config = require("kittyREPL.config")

---Parse kitty @ ls output into table.
---@param match string? optionally filter with --match argument
---@return table?
function M.ls(match)
    local cmd = "kitty @ ls"
    if match then
        cmd = cmd .. " --match=" .. match
    end
    cmd = cmd .. " 2> /dev/null"
    local fh = io.popen(cmd)
    if not fh then return end
    local json_string = fh:read("*a")
    fh:close()
    -- if we are not in fact in a kitty terminal then the command will fail
    if json_string == "" then return end
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

---Check if a kitty window exists.
---@param window_id integer
---@return boolean
function M.exists(window_id)
    return os.execute("kitty @ get-text --match id:" .. window_id .. " > /dev/null 2> /dev/null") == 0
end

---Focus the REPL window.
function M.focus()
    os.execute("kitty @ focus-window --match id:" .. vim.b.repl_win)
end

---Send raw text to the REPL (no processing).
---@param text string
function M.send_raw(text)
    local fh = io.popen("kitty @ send-text --stdin --match id:" .. vim.b.repl_win, "w")
    if not fh then return end
    fh:write(text)
    fh:close()
end

---Send text using bracketed paste mode.
---@param text string
---@param post string
function M.send_bracketed(text, post)
    local fh = io.popen("kitty @ send-text --stdin --match id:" .. vim.b.repl_win, "w")
    if not fh then return end
    fh:write("\x1b[200~" .. text .. "\x1b[201~" .. post)
    fh:close()
end

---Fixes indentation by prepending Start Of Header signal.
---This can be a fallback method if a REPL doesn't support bracketed paste,
---however each line will then be sent and called separately, which may be a
---problem if there are empty lines within the sent block.
---@param text string
---@return string
function M.SOH(text)
    return text:gsub('\n', '\n\x01')
end

---Count number of occurrences of pattern in text.
---@param text string
---@param pattern string
---@return integer
local function strcount(text, pattern)
    return select(2, string.gsub(text, pattern, ""))
end

---Send text to the REPL with appropriate method based on config.
---An unresolved program falls through to a raw send, the conservative default.
---@param program string|nil program running in the REPL
---@param text string
---@param post string
---@param raw boolean?
function M.send(program, text, post, raw)
    if config.closepager and M.detect_pager() then
        M.send_raw("q")
    end
    if raw then
        M.send_raw(text .. post)
    else
        if config.custom[program] then
            config.custom[program](text, post)
        elseif config.bracketed[program] then
            if strcount(text, "\n") > 0 then
                M.send_bracketed(text, post)
            else
                M.send_raw(text .. post)
            end
        elseif config.linewise[program] then
            for _, line in ipairs(vim.split(text, '\n')) do
                if line ~= "" then
                    M.send_raw(line .. '\n')
                end
            end
            M.send_raw(post)
        else
            M.send_raw(text .. post)
        end
    end
end

---Run text in the REPL (send with newline).
---@param program string|nil
---@param text string
---@param raw boolean?
function M.run(program, text, raw)
    M.send(program, text, '\n', raw)
end

---Paste text to the REPL (send without trailing newline).
---@param program string|nil
---@param text string
---@param raw boolean?
function M.paste(program, text, raw)
    M.send(program, text:gsub('\n$', ''), '', raw)
    if config.editpaste then M.focus() end
end

---Detect whether the REPL is currently displaying a pager (e.g. help texts).
---@return boolean
function M.detect_pager()
    local fh = io.popen("kitty @ get-text --extent=screen --add-cursor --match id:" .. vim.b.repl_win)
    if not fh then return false end
    local scrollback = fh:read("*a")
    fh:close()
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
---@return string?
function M.get_scrollback()
    local fh = io.popen("kitty @ get-text --extent=all --match id:" .. vim.b.repl_win)
    if not fh then return end
    local text = fh:read("*a")
    fh:close()
    return text
end

---Get last command output from the REPL (requires kitty shell integration).
---@return string?
function M.get_last_output()
    local fh = io.popen("kitty @ get-text --extent=last_cmd_output --match id:" .. vim.b.repl_win)
    if not fh then return end
    local text = fh:read("*a")
    fh:close()
    if text == "" then return end
    return text
end

---Send a SIGINT to the REPL.
---@return boolean
function M.interrupt()
    return os.execute("kitty @ signal-child --match id:" .. vim.b.repl_win) == 0
end

---Launch a new kitty window.
---@param command string?
---@return integer? window_id
function M.launch(command)
    command = command or ""
    local fh = io.popen("kitty @ launch --cwd=current --keep-focus " .. command)
    if not fh then return end
    local win = fh:read("*n") -- *n means read number, which also strips newline
    fh:close()
    return win
end

---Set the title of a kitty window.
---@param window_id integer
---@param title string
function M.set_title(window_id, title)
    os.execute("kitty @ set-window-title --match id:" .. window_id .. " " .. title)
end

return M
