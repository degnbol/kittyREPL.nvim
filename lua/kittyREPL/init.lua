-- kittyREPL - Send code to a REPL running in a kitty terminal window
local M = {}

local config = require("kittyREPL.config")
local kitty = require("kittyREPL.kitty")
local detect = require("kittyREPL.detect")
local scrollback = require("kittyREPL.scrollback")
local commands = require("kittyREPL.commands")

-- Re-export submodules for advanced usage
M.kitty = kitty
M.detect = detect
M.scrollback = scrollback
M.commands = commands
M.config = config

-- LATER: use function rather than string after pull request is merged:
-- https://github.com/neovim/neovim/pull/20187
local function operator(funcname)
    return function()
        vim.opt.operatorfunc = "v:lua." .. funcname
        return "g@"
    end
end

-- Global functions required for operatorfunc (v:lua.funcname needs globals)
function ReplRunOperator(type)
    commands.runOperator(type)
end

function ReplPasteOperator(type)
    commands.pasteOperator(type)
end

-- Expose some functions globally for backwards compatibility
-- These can be called from user configs
ReplNew = commands.new
ReplSetI = commands.setI
ReplToggleProgress = commands.toggleProgress
ReplToggleEditPaste = commands.toggleEditPaste

---Setup kittyREPL with optional user configuration.
---@param userconfig table?
function M.setup(userconfig)
    if userconfig ~= nil then
        -- Merge user config into default config
        for k, v in pairs(userconfig) do
            if type(v) == "table" and type(config[k]) == "table" then
                config[k] = vim.tbl_deep_extend("keep", v, config[k])
            else
                config[k] = v
            end
        end
    end

    -- Set up custom send functions that need access to kitty module
    config.custom.pymol = function(text, post)
        -- wrap multiline in python .. python end
        -- https://pymolwiki.org/index.php/PythonTerminal
        if text:match('\n') then
            kitty.send_raw("python\n" .. text:gsub("\n*$", "") .. "\npython end" .. post)
        else
            kitty.send_raw(text .. post)
        end
    end
    config.custom.lua = function(text, post)
        -- top level locals are ignored in REPL so we strip that.
        kitty.send_raw(text:gsub("^local ", ""):gsub("\nlocal ", "\n") .. post)
    end
    config.custom.julia = function(text, post)
        -- Fixed a huge problem, super weird, julia was insanely slow typing one char at a time.
        -- I realised it was because even though we set it to use bracketed it only sends it bracketed with multiline.
        -- Solution here: always send bracketed.
        kitty.send_bracketed(text, post)
    end

    -- Transform prompt patterns to match from start of line (only once)
    for k, v in pairs(config.match.prompt) do
        if not v[1]:match("^%^") then
            config.match.prompt[k][1] = "^" .. v[1] .. "()"
            config.match.prompt[k][2] = "^" .. v[2] .. "()"
        end
    end

    local group = vim.api.nvim_create_augroup("kittyRepl", { clear = true })
    -- BufEnter is too early for e.g. cmdline window to assign buftype
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        callback = function()
            if vim.bo.buftype ~= "" then return end
            if config.exclude[vim.bo.filetype] then return end

            local map = vim.keymap.set
            local c = config

            local function nmap(lhs, rhs, desc, expr)
                map('n', lhs, rhs, { buffer = true, silent = true, desc = desc, expr = expr })
            end
            local function xmap(lhs, rhs, desc, expr)
                map('x', lhs, rhs, { buffer = true, silent = true, desc = desc, expr = expr })
            end

            nmap(c.keymap.new, commands.new, "REPL new")
            nmap(c.keymap.focus, detect.replCheck(kitty.focus), "REPL focus")
            nmap(c.keymap.set, commands.set, "REPL set")
            nmap(c.keymap.setlast, commands.setLast, "REPL set last")
            nmap(c.keymap.run, detect.replCheck(operator("ReplRunOperator")), "REPL run motion", true)
            nmap(c.keymap.paste, detect.replCheck(operator("ReplPasteOperator")), "REPL paste motion", true)
            nmap(c.keymap.help, detect.replCheck(commands.help), "REPL help word under cursor")
            xmap(c.keymap.help, detect.replCheck(commands.helpVisual), "REPL help visual")
            nmap(c.keymap.runLine, detect.replCheck(commands.runLine), "REPL run line")
            nmap(c.keymap.runLineFor, detect.replCheck(commands.runLineFor), "REPL iterate")
            nmap(c.keymap.runLineForI, detect.replCheck(commands.runLineForI), "REPL index")
            nmap(c.keymap.pasteLine, detect.replCheck(commands.pasteLine), "REPL paste line")
            xmap(c.keymap.runVisual, detect.replCheck(commands.runVisual), "REPL run visual")
            xmap(c.keymap.pasteVisual, detect.replCheck(commands.pasteVisual), "REPL paste visual")
            nmap(c.keymap.q, detect.replCheck(commands.sendCustom("q")), "REPL send q")
            nmap(c.keymap.cr, detect.replCheck(commands.sendCustom("\x0d")), "REPL send CR")
            nmap(c.keymap.ctrld, detect.replCheck(commands.sendCustom("\x04")), "REPL send Ctrl+d")
            nmap(c.keymap.ctrlc, detect.replCheck(commands.sendCustom("\x03")), "REPL send Ctrl+c")
            nmap(c.keymap.interrupt, detect.replCheck(kitty.interrupt), "REPL interrupt")
            nmap(c.keymap.scrollStart, detect.replCheck(scrollback.startScroll), "REPL paste from scrollback")
            xmap(c.keymap.scrollUp, detect.replCheck(scrollback.replaceScroll(1)), "REPL paste older scrollback")
            xmap(c.keymap.scrollDown, detect.replCheck(scrollback.replaceScroll(-1)), "REPL paste newer scrollback")
            nmap(c.keymap.scrollOutputAbove, detect.replCheck(function() scrollback.pasteOutput(false) end), "REPL paste output above")
            nmap(c.keymap.scrollOutputBelow, detect.replCheck(function() scrollback.pasteOutput(true) end), "REPL paste output below")
            nmap(c.keymap.progress, commands.toggleProgress, "REPL toggle progress")
            nmap(c.keymap.editPaste, commands.toggleEditPaste, "REPL toggle edit paste")
        end
    })
end

return M
