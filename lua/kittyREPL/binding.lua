-- Find the loop binding or assignment at a position, with treesitter.
-- A language is supported by a queries/<lang>/repl-iterate.scm on the
-- runtimepath capturing @variable/@iterable for loop bindings and
-- @assign.variable/@assign.iterable for assignments. Only the buffer's own
-- language is queried, not code injected from another.
-- Rows and columns are (0,0)-indexed throughout, as in the treesitter API.
local M = {}

local message = require("kittyREPL.message")

--- A binding spans from the start of its variable to the end of its iterable,
--- which is the header of a loop rather than the loop with its body.
--- @class kittyREPL.Binding
--- @field variable TSNode
--- @field iterable TSNode

--- Byte ranges of comment descendants, relative to the node's start.
--- @param node TSNode
--- @return integer[][] ranges
local function commentRanges(node)
    local _, _, base = node:start()
    local ranges = {}
    local stack = { node }
    while #stack > 0 do
        for child in table.remove(stack):iter_children() do
            if child:type():match("comment") then
                local _, _, from = child:start()
                local _, _, to = child:end_()
                ranges[#ranges + 1] = { from - base, to - base }
            else
                stack[#stack + 1] = child
            end
        end
    end
    return ranges
end

--- Node text as a one-line expression: comments dropped, whitespace runs
--- spanning newlines collapsed.
--- @param node TSNode
--- @param bufnr integer
--- @return string text
local function exprText(node, bufnr)
    local text = vim.treesitter.get_node_text(node, bufnr)
    local ranges = commentRanges(node)
    -- back to front so earlier ranges keep their offsets
    table.sort(ranges, function(a, b) return a[1] > b[1] end)
    for _, range in ipairs(ranges) do
        text = text:sub(1, range[1]) .. text:sub(range[2] + 1)
    end
    return (text:gsub("%s*\n%s*", " "))
end

--- @param binding kittyREPL.Binding
--- @param row integer
--- @param col integer
--- @return boolean contains true when the binding span covers the position
local function contains(binding, row, col)
    local srow, scol = binding.variable:start()
    local erow, ecol = binding.iterable:end_()
    return (srow < row or (srow == row and scol <= col))
        and (row < erow or (row == erow and col < ecol))
end

--- @param binding kittyREPL.Binding
--- @return integer size bytes spanned
local function size(binding)
    local _, _, from = binding.variable:start()
    local _, _, to = binding.iterable:end_()
    return to - from
end

--- @param bindings kittyREPL.Binding[]
--- @return kittyREPL.Binding|nil innermost
local function innermost(bindings)
    local best
    for _, binding in ipairs(bindings) do
        if not best or size(binding) < size(best) then best = binding end
    end
    return best
end

--- The innermost binding covering a position, else the leftmost one starting
--- after it on the same row, which is what lets repeated calls walk a header
--- with several bindings left to right.
--- @param bindings kittyREPL.Binding[]
--- @param row integer
--- @param col integer
--- @return kittyREPL.Binding|nil binding
local function pick(bindings, row, col)
    local covering, ahead = {}, {}
    for _, binding in ipairs(bindings) do
        if contains(binding, row, col) then covering[#covering + 1] = binding end
        local srow, scol = binding.variable:start()
        if srow == row and scol >= col then ahead[#ahead + 1] = binding end
    end
    local inside = innermost(covering)
    if inside then return inside end
    local first, firstcol
    for _, binding in ipairs(ahead) do
        local _, scol = binding.variable:start()
        if not first or scol < firstcol then first, firstcol = binding, scol end
    end
    return first
end

--- Innermost binding starting on a row, whatever the column.
--- @param bindings kittyREPL.Binding[]
--- @param row integer
--- @return kittyREPL.Binding|nil binding
local function pickRow(bindings, row)
    local onrow = {}
    for _, binding in ipairs(bindings) do
        if binding.variable:start() == row then onrow[#onrow + 1] = binding end
    end
    return innermost(onrow)
end

--- All loop bindings and assignments in a buffer, keyed by kind.
--- Notifies and returns nil when the query or parser is unusable.
--- @param bufnr integer
--- @return table<string, kittyREPL.Binding[]>|nil bindings
local function bindings(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok then
        message.warn(tostring(parser))
        return
    end
    if not parser then return end
    local ok_query, query = pcall(vim.treesitter.query.get, parser:lang(), "repl-iterate")
    if not ok_query then
        message.warn(tostring(query))
        return
    end
    if not query then return end
    local found = { loop = {}, assign = {} }
    for _, match in query:iter_matches(parser:parse()[1]:root(), bufnr) do
        local captured = {}
        for id, nodes in pairs(match) do
            captured[query.captures[id]] = nodes[1]
        end
        local variable = captured.variable or captured["assign.variable"]
        local iterable = captured.iterable or captured["assign.iterable"]
        if variable and iterable then
            local kind = captured.variable and "loop" or "assign"
            table.insert(found[kind], { variable = variable, iterable = iterable })
        end
    end
    return found
end

--- Start of the first named node after a node, climbing out of finished levels.
--- @param node TSNode
--- @return integer[]|nil position row, col
local function nextNamedStart(node)
    --- @type TSNode|nil
    local level = node
    while level do
        local sibling = level:next_sibling()
        while sibling do
            if sibling:named() then
                local row, col = sibling:start()
                return { row, col }
            end
            sibling = sibling:next_sibling()
        end
        level = level:parent()
    end
end

--- The loop binding or assignment at a position, as text.
--- A loop binding wins over an assignment the position points at just as
--- precisely, so the body of a one-line loop does not shadow its header.
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return string|nil variable
--- @return string|nil iterable
--- @return integer[]|nil next row, col of the next named node after the iterable
function M.at(bufnr, row, col)
    local found = bindings(bufnr)
    if not found then return end
    local binding = pick(found.loop, row, col) or pick(found.assign, row, col)
        or pickRow(found.loop, row) or pickRow(found.assign, row)
    if not binding then return end
    return exprText(binding.variable, bufnr),
        exprText(binding.iterable, bufnr),
        nextNamedStart(binding.iterable)
end

return M
