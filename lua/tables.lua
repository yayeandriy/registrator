-- Table helpers shared by the tree ops.
--
-- copy(t) — shallow copy; nested tables stay shared.

local function copy(t)
    local c = {}
    for k, v in pairs(t) do
        c[k] = v
    end
    return c
end

return {
    copy = copy,
}
