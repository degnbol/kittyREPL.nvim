-- Low-level kitty terminal communication
--
-- Every function that talks to a REPL takes the target window id explicitly. The
-- buffer -> window binding lives in repl.lua.
local M = {}

local config = require("kittyREPL.config")
local message = require("kittyREPL.message")

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
        message.warn_once(tostring(out))
        return
    end
    if out.code == 0 then return out.stdout end
    local err = vim.trim(out.stderr or "")
    if no_match_ok and err:find("No matching windows", 1, true) then return end
    -- once: an unusable remote control fails identically on every key
    message.warn_once(err)
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

-- What `--add-cursor` appends, straight after the text with no separator:
-- ^[ is ESC and ^[[ is CSI (Control Sequence Introducer)
-- ^[[?25h means "show the cursor"
-- ^[[n;mH places it at row n, column m, both 1-indexed
-- ^[[?12h and ^[[?12l set and reset its blink -- both appear, a pager giving h
-- and the prompt_toolkit REPLs (radian, ipython) giving l
-- https://en.wikipedia.org/wiki/ANSI_escape_code
local CURSOR = "%c%[%?25h%c%[(%d+);(%d+)H%c%[%?%d+[hl]"

---Split a screen into its text and the cursor position reported after it.
---@param screen string `kitty @ get-text --extent=screen --add-cursor` output
---@return string|nil text nil when no cursor was reported
---@return integer|nil row 1-indexed line of text the cursor sits on
---@return integer|nil col
local function cursor(screen)
    local text, row, col = screen:match("^(.*)" .. CURSOR .. "\n$")
    if not text then return end
    return text, tonumber(row), tonumber(col)
end

---Whether a screen ends in a pager's prompt with the cursor sitting in it.
---Anchoring on the cursor is what separates a pager from paged-looking text left
---behind by one that has quit.
---@param screen string `kitty @ get-text --extent=screen --add-cursor` output
---@return boolean
function M.is_pager(screen)
    local text, r, c = cursor(screen)
    if not text then return false end
    -- the row is compared against a count of newlines below, which a line long
    -- enough to wrap breaks -- kitty returns one of those as a single line. See
    -- M.prompt_at_cursor, which reads a row it cannot trust the index of.
    -- if we aren't scrolled to the bottom lastline will be nil.
    local helplines, lastline, blanklines = text:match("^(.*)\n([^\n]+)(\n*)$")
    if lastline == nil then return false end
    local pagerMatch = lastline:match("^(:)")
    if pagerMatch and #blanklines > 0 then return false end
    if not pagerMatch then pagerMatch = lastline:match("^%(END%)") end
    if not pagerMatch then return false end
    local _, nlines = helplines:gsub('\n', '')
    -- +2 since "lines" doesn't contain "lastline" and the newline right before it.
    return r == nlines + 2 and c == #pagerMatch + 1
end

---The prompt a REPL is sitting at, as it is rendered on screen.
---Taken as the last line with anything on it rather than the cursor's row: the
---cursor is reported as a screen row, while a line long enough to wrap comes
---back as one line, so the two stop lining up. A REPL waiting for input has
---drawn nothing below its prompt.
---Right-padded to the cursor's column, kitty dropping a line's trailing blanks
---so that a prompt ending in one comes back short.
---@param screen string `kitty @ get-text --extent=screen --add-cursor` output
---@return string|nil nil in column 1, where nothing was drawn for the cursor to
---sit after: a REPL busy with a computation, or one that draws no prompt at all
function M.prompt_at_cursor(screen)
    local text, _, col = cursor(screen)
    if not text or col == 1 then return end
    local prompt
    for line in vim.gsplit(text, "\n") do
        if vim.trim(line) ~= "" then prompt = line end
    end
    if not prompt then return end
    local pad = col - 1 - vim.fn.strdisplaywidth(prompt)
    -- wider than the cursor's column, so the cursor is not at the end of this
    -- line and it is not a prompt waiting to be typed after
    if pad < 0 then return end
    return prompt .. string.rep(" ", pad)
end

---Read a REPL's screen with its cursor position appended.
---@param win integer
---@return string?
function M.get_screen(win)
    return get_text(win, "--extent=screen", "--add-cursor")
end

---Whether the REPL is currently displaying a pager (e.g. help texts).
---One `kitty @ get-text` round trip, so this belongs per user action, not per send.
---@param win integer
---@return boolean
function M.detect_pager(win)
    local screen = M.get_screen(win)
    return screen ~= nil and M.is_pager(screen)
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
    -- kitty otherwise execs the child with the environment kitty itself was
    -- started with, which for a GUI-launched kitty is neither the login
    -- shell's PATH nor its XDG dirs; over remote control --copy-env sends the
    -- client's environment instead. vim.system stamps NVIM=v:servername on
    -- that client (:h vim.system), so drop it again -- a bare name removes
    -- rather than sets -- or an nvim started in the REPL window takes itself
    -- for a nested one.
    local argv = { "launch", "--cwd=current", "--keep-focus", "--copy-env", "--env=NVIM" }
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
