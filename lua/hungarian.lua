-- Minimum-cost assignment (Kuhn–Munkres) on a rectangular cost matrix.
--
-- hungarian.assign(cost, n, m) → assignment[i] = j (1-based) or nil.
-- Costs ≥ `hungarian.INF / 2` mean "cannot pair"; callers check them.

local hungarian = {}

local INF = 1e9
hungarian.INF = INF

local function square(a, n)
    local u, v, p, way = {}, {}, {}, {}
    for i = 0, n do
        u[i] = 0
        v[i] = 0
        p[i] = 0
        way[i] = 0
    end
    for i = 1, n do
        p[0] = i
        local j0 = 0
        local minv, used = {}, {}
        for j = 0, n do
            minv[j] = INF
            used[j] = false
        end
        repeat
            used[j0] = true
            local i0 = p[j0]
            local delta = INF
            local j1 = 0
            for j = 1, n do
                if not used[j] then
                    local cur = a[i0][j] - u[i0] - v[j]
                    if cur < minv[j] then
                        minv[j] = cur
                        way[j] = j0
                    end
                    if minv[j] < delta then
                        delta = minv[j]
                        j1 = j
                    end
                end
            end
            for j = 0, n do
                if used[j] then
                    u[p[j]] = u[p[j]] + delta
                    v[j] = v[j] - delta
                else
                    minv[j] = minv[j] - delta
                end
            end
            j0 = j1
        until p[j0] == 0
        repeat
            local j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
        until j0 == 0
    end
    local assignment = {}
    for j = 1, n do
        if p[j] >= 1 then
            assignment[p[j]] = j
        end
    end
    return assignment
end

-- Pads to a square with cost-0 dummy cells so leftovers stay unassigned.
function hungarian.assign(cost, n, m)
    if n == 0 or m == 0 then
        return {}
    end
    local k = math.max(n, m)
    local a = {}
    for i = 1, k do
        a[i] = {}
        for j = 1, k do
            if i <= n and j <= m then
                a[i][j] = cost[i][j]
            else
                a[i][j] = 0
            end
        end
    end
    local raw = square(a, k)
    local assignment = {}
    for i = 1, n do
        local j = raw[i]
        if j and j <= m then
            assignment[i] = j
        end
    end
    return assignment
end

return hungarian
