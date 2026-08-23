---@diagnostic disable: undefined-global
-- Needs the python, julia and r parsers installed.
local binding = require("kittyREPL.binding")

---@param ft string
---@param lines string[]
---@param cursor integer[] row, col, both 0-indexed
local function at(ft, lines, cursor)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = ft
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return binding.at(buf, cursor[1], cursor[2])
end

-- desc, ft, lines, cursor, expected variable, expected iterable
local extraction = {
    { "python tuple target", "python",
        { "for scene, _arrows in zip(scenes, arrows, strict=True):", "    pass" }, { 0, 0 },
        "scene, _arrows", "zip(scenes, arrows, strict=True)" },
    { "python single target", "python", { "for i in items:", "    pass" }, { 0, 0 },
        "i", "items" },
    { "python dict items", "python", { "for k, v in d.items():", "    pass" }, { 0, 0 },
        "k, v", "d.items()" },
    { "python comprehension binds over the assignment", "python",
        { "x = [f(i) for i in items]" }, { 0, 0 }, "i", "items" },
    { "python one-line loop binds over its body", "python",
        { "for x in y: z = w" }, { 0, 0 }, "x", "y" },
    { "python assignment", "python", { "x = f(y)" }, { 0, 0 }, "x", "f(y)" },
    { "python chained assignment takes the leftmost target", "python",
        { "x = y = z" }, { 0, 0 }, "x", "y = z" },
    { "python no binding", "python", { "import os" }, { 0, 0 }, nil, nil },
    { "julia tuple target", "julia",
        { "for (scene, arrow) in zip(scenes, arrows)", "end" }, { 0, 0 },
        "(scene, arrow)", "zip(scenes, arrows)" },
    { "julia ∈", "julia", { "for i ∈ 1:10", "end" }, { 0, 0 }, "i", "1:10" },
    { "julia call iterable", "julia", { "for i in axes(A, 1)", "end" }, { 0, 0 },
        "i", "axes(A, 1)" },
    { "julia assignment", "julia", { "x = axes(A, 1)" }, { 0, 0 }, "x", "axes(A, 1)" },
    { "r for", "r", { "for (i in seq_along(x)) {", "}" }, { 0, 0 }, "i", "seq_along(x)" },
    { "r <-", "r", { "z <- a + b" }, { 0, 0 }, "z", "a + b" },
    { "r <<-", "r", { "y <<- 3" }, { 0, 0 }, "y", "3" },
    { "r =", "r", { "x = seq_len(3)" }, { 0, 0 }, "x", "seq_len(3)" },
    { "r one-line loop binds over its body", "r",
        { "for (i in 1:10) x <- i" }, { 0, 0 }, "i", "1:10" },
    { "r non-assignment operator", "r", { "a + b" }, { 0, 0 }, nil, nil },
    { "filetype without a query", "lua", { "for i in pairs(t) do end" }, { 0, 0 }, nil, nil },
    { "cursor on a continuation line of a wrapped header", "python",
        { "for a, b in zip(", "    xs,", "    ys,", "):", "    pass" }, { 1, 4 },
        "a, b", "zip( xs, ys, )" },
    { "comment in a wrapped header", "python",
        { "for a, b in zip(", "    xs,  # first", "    ys,", "):", "    pass" }, { 0, 0 },
        "a, b", "zip( xs, ys, )" },
    { "cursor on a body line without a binding", "python",
        { "for i in items:", "    print(i)" }, { 1, 4 }, nil, nil },
    { "column walk picks the first binding of a header", "julia",
        { "for i in 1:3, j in 1:4", "end" }, { 0, 0 }, "i", "1:3" },
    { "column walk keeps the binding the cursor is inside", "julia",
        { "for i in 1:3, j in 1:4", "end" }, { 0, 9 }, "i", "1:3" },
    { "column walk picks the next binding once past the first", "julia",
        { "for i in 1:3, j in 1:4", "end" }, { 0, 14 }, "j", "1:4" },
    { "cursor past every binding on the row falls back to the row", "python",
        { "for i in items:", "    pass" }, { 0, 14 }, "i", "items" },
    { "cursor on the body of a one-line loop takes the body", "python",
        { "for x in y: z = w" }, { 0, 12 }, "z", "w" },
    { "cursor on the body of a one-line r loop takes the body", "r",
        { "for (i in 1:10) x <- i" }, { 0, 16 }, "x", "i" },
}

describe("binding.at", function()
    for _, case in ipairs(extraction) do
        local desc, ft, lines, cursor, variable, iterable = unpack(case, 1, 6)
        it(desc, function()
            local gotVariable, gotIterable = at(ft, lines, cursor)
            assert.are.equal(variable, gotVariable)
            assert.are.equal(iterable, gotIterable)
        end)
    end
end)

-- desc, ft, lines, cursor, expected next position
local progress = {
    { "python loop body", "python", { "for i in items:", "    print(i)" }, { 0, 0 }, { 1, 4 } },
    { "python body after a wrapped header", "python",
        { "for a, b in zip(", "    xs,", "    ys,", "):", "    pass" }, { 0, 0 }, { 4, 4 } },
    { "python one-line loop body", "python", { "for x in y: z = w" }, { 0, 0 }, { 0, 12 } },
    { "python statement after an assignment", "python", { "x = f(y)", "g()" }, { 0, 0 }, { 1, 0 } },
    { "julia second binding of a header", "julia",
        { "for i in 1:3, j in 1:4", "    x", "end" }, { 0, 0 }, { 0, 14 } },
    { "julia body after the last binding", "julia",
        { "for i in 1:3, j in 1:4", "    x", "end" }, { 0, 14 }, { 1, 4 } },
    { "julia tuple bindings", "julia",
        { "for (a,b) in x, (c,d) in y", "    z", "end" }, { 0, 0 }, { 0, 16 } },
    { "julia loop body", "julia", { "for i in 1:10", "    println(i)", "end" }, { 0, 0 }, { 1, 4 } },
    { "r one-line loop body", "r", { "for (i in 1:10) x <- i" }, { 0, 0 }, { 0, 16 } },
    { "r braced body", "r", { "for (i in seq_along(x)) {", "}" }, { 0, 0 }, { 0, 24 } },
}

describe("binding.at next position", function()
    for _, case in ipairs(progress) do
        local desc, ft, lines, cursor, expected = unpack(case, 1, 5)
        it(desc, function()
            local _, _, nextpos = at(ft, lines, cursor)
            assert.are.same(expected, nextpos)
        end)
    end

    it("is nil at the end of the tree", function()
        local _, _, nextpos = at("python", { "x = f(y)" }, { 0, 0 })
        assert.is_nil(nextpos)
    end)
end)
