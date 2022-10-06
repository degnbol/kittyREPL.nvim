#!/usr/bin/env lua
local g = vim.g
local cmd = vim.cmd
local api = vim.api
local fn = vim.fn
local keymap = vim.keymap

function get_repl()
    return vim.b.repl_id
end
function set_repl(window_id)
    vim.b.repl_id = window_id
end

-- kitty @ ls foreground_processes cmdline value 
local cmdline2filetype = {
    python3="python",
    ipython="python",
    IPython="python",
    R="r",
    radian="r",
}

function search_repl()
    fh = io.popen('kitty @ ls 2> /dev/null')
    json_string = fh:read("*a")
    -- if we are not in fact in a kitty terminal then the command will fail
    if json_string == "" then return end
    
    ls = vim.json.decode(json_string)
    for i_os_win, os_win in ipairs(ls) do
        if os_win["is_focused"] then
            for i_tab, tab in ipairs(os_win["tabs"]) do
                if tab["is_focused"] then
                    for i_win, win in ipairs(tab["windows"]) do
                        -- use last foreground process, e.g. I observe if I start julia, then `using PlotlyJS`, 
                        -- then PlotlyJS will open other processes that are listed earlier in the list. 
                        -- If there are any problems then just loop and look in all foreground processes.
                        procs = win["foreground_processes"]
                        cmdline = procs[#procs]["cmdline"]
                        -- ["/usr/local/bin/julia", "-t", "4"] -> julia
                        -- [".../R"] -> r
                        -- ["nvim", ".../file.R"] -/-> r. Make sure we don't set the nvim editor as the REPL by accepting "." in the name match. 
                        -- ["../Python", ".../radian"] -> r
                        -- [".../python3"] -> python
                        for i_arg, arg in ipairs(cmdline) do
                            -- match letters, numbers and period until the end of string arg.
                            repl = string.match(arg, "[%w.]+$")
                            repl = cmdline2filetype[repl] or repl
                            if repl == vim.bo.filetype then
                                set_repl(win["id"])
                                return win["id"]
                            end
                        end
                        -- for proc over SSH the foreground_processes.cmdline will simply be ["ssh", ...]
                        -- so we check the title as well
                        -- "IPython: ..." -> IPython
                        -- "server-name: julia" -> julia
                        for repl in string.gmatch(win["title"], "[%w]+") do
                            repl = cmdline2filetype[repl] or repl
                            if repl == vim.bo.filetype then
                                set_repl(win["id"])
                                return win["id"]
                            end
                        end
                    end
                end
            end
        end
    end
end

-- register an autocommand to run this when entering buffers
cmd 'au BufEnter * lua search_repl()'

-- command to execute in new kitty window
local filetype2command = {
    python="~/miniconda3/bin/ipython",
    julia="julia",
    -- kitty command doesn't know where R is since it doesn't have all the env copied.
    r="radian --r-binary /Library/Frameworks/R.framework/Resources/R",
    lua="lua",
}

function kittyWindow()
    -- default to zsh
    ftcommand = filetype2command[vim.bo.filetype] or ""
    fh = io.popen('kitty @ launch --cwd=current --keep-focus ' .. ftcommand)
    window_id = fh:read("*n") -- *n means read number, which means we also strip newline
    fh:close()
    -- set title to the id so we can easily set is as target
    os.execute("kitty @ set-window-title --match id:" .. window_id .. " " .. window_id)
    set_repl(window_id)
end


function kittyExists(window_id)
    -- see if kitty window exists by getting text from it and checking if the operation fails (nonzero exit code).
    return os.execute('kitty @ get-text --match id:' .. window_id .. ' > /dev/null 2> /dev/null') == 0
end

function replCheck()
    -- return whether a valid repl is active or were found.
    return get_repl() ~= nil and kittyExists(get_repl()) or search_repl() ~= nil
end

function kittySendRaw(text)
    fh = io.popen('kitty @ send-text --stdin --match id:' .. vim.b.repl_id, 'w')
    fh:write(text .. '\n')
    fh:close()
end

function kittySendSOH(text)
    -- Fixes indentation by prepending Start Of Header signal. Still sending each line separately.
    text = text:gsub('\n', '\n\x01')
    -- might have to be done in two steps, instead of simply inserting gsub expr in kittySend.
    kittySendRaw(text)
end

function kittySendPaste(text)
    -- get diretory of current script https://stackoverflow.com/questions/6380820/get-containing-path-of-lua-file
    dir = debug.getinfo(1).source:match("@?(.*/)")
    -- kittyPaste.sh uses zsh to do bracketed paste cat from stdin to stdout.
    fh = io.popen(dir .. '/../bracketedPaste.sh ' .. vim.b.repl_id, 'w')
    fh:write(text)
    fh:close()
end

-- not all REPLs support bracketed paste
local filetype2paste = { python=true, r=true, julia=true }

function kittySend(text)
    if filetype2paste[vim.bo.filetype] then
        kittySendPaste(text)
    else
        kittySendRaw(text)
    end
end

function kittySendLine()
    if not replCheck() then
        print("No REPL")
    else
        -- easiest to use stdin rather than putting the text as an arg due to worrying about escaping characters
        kittySend(api.nvim_get_current_line())
        cmd 'silent normal! j'
    end
end

function kittySendVisual()
    if not replCheck() then
        print("No REPL")
    else
        -- gv  = reselect last select (unselected for some reason)
        -- "ky = yank to register k (k for kitty)
        -- `>  = go to mark ">" = end of last visual select
        cmd 'silent normal! gv"ky`>'
        kittySend(fn.getreg('k'))
    end
end

function ReplOperator(type, ...)
    if not replCheck() then
        print("No REPL")
    else
        -- `[ = go to start of motion
        -- v or V = select char or lines
        -- `] = go to end of motion
        -- "ky = yank selection to register k
        if type == "char" then
            cmd 'silent normal! `[v`]"ky`]w'
        else -- either type == "line" or "block", the latter I never use
            cmd 'silent normal! `[V`]"ky`]w'
        end
        kittySend(fn.getreg('k'))
    end
end

opts = {noremap=true, silent=true}
-- FIXME: slowing down quickfix jump
keymap.set("n", "<CR><CR>", ":lua kittySendLine()<CR>", opts)
keymap.set("x", "<CR>", ":lua kittySendVisual()<CR>", opts)
keymap.set('n', "<CR>", [[&buftype ==# "" ? Operator("v:lua.ReplOperator") : "\<CR>"]], {expr=true, noremap=false})
keymap.set('n', "<leader><CR>", ":lua kittyWindow()<CR>", opts)


-- TODO: add setup options
function setup()
end

return {
    setup = setup
}
