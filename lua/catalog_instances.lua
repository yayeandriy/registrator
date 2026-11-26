-- Cluster loose boxes into full class-set instances of one catalog
-- signature — "anchor a class by the other detections around it".
-- Shared by Presence catalog extras and the verdict sheet's extras.
--
--   catalog_instances.cluster(classes, remaining, same_class)
--     -> instances ({ { box, … }, … }), the boxes left over (order kept)
--   same_class(box, class) decides class identity for the caller.
--
-- Needs `boxes`.

local catalog_instances = {}

-- Two boxes join one instance when their centres sit within this many
-- of the larger box's sides.
local REACH = 5.0
local MIN_SIDE = 0.01
local DEFAULT_SIDE = 0.05

local function side(d)
    return math.max(tonumber(d.width) or DEFAULT_SIDE, MIN_SIDE),
        math.max(tonumber(d.height) or DEFAULT_SIDE, MIN_SIDE)
end

local function without(list, used)
    local out = {}
    for i, d in ipairs(list) do
        if not used[i] then
            out[#out + 1] = d
        end
    end
    return out
end

-- Every class-A box pairs with its nearest class-B box, globally closest
-- first, so adjacent instances do not cross-wire.
local function pairs_of(a_class, b_class, remaining, same_class)
    local cands = {}
    for ai, a in ipairs(remaining) do
        if same_class(a, a_class) then
            local aw, ah = side(a)
            for bi, b in ipairs(remaining) do
                if bi ~= ai and same_class(b, b_class) then
                    local bw, bh = side(b)
                    local dist = boxes.center_dist(a, b)
                    if dist <= math.max(aw, ah, bw, bh) * REACH then
                        cands[#cands + 1] = { ai = ai, bi = bi, dist = dist, n = #cands + 1 }
                    end
                end
            end
        end
    end
    table.sort(cands, function(x, y)
        if x.dist ~= y.dist then
            return x.dist < y.dist
        end
        return x.n < y.n
    end)
    local used, instances = {}, {}
    for _, p in ipairs(cands) do
        if not used[p.ai] and not used[p.bi] then
            used[p.ai], used[p.bi] = true, true
            instances[#instances + 1] = { remaining[p.ai], remaining[p.bi] }
        end
    end
    return instances, without(remaining, used)
end

-- Three or more classes: seed on the first, take each other class's
-- nearest box within reach of the seed.
local function greedy(classes, remaining, same_class)
    local used, instances = {}, {}
    for si, seed in ipairs(remaining) do
        if not used[si] and same_class(seed, classes[1]) then
            local found, local_used = { seed }, { [si] = true }
            local sw, sh = side(seed)
            local limit = math.max(sw, sh) * REACH
            local complete = true
            for c = 2, #classes do
                local best, best_dist
                for di, d in ipairs(remaining) do
                    if not used[di] and not local_used[di] and same_class(d, classes[c]) then
                        local dist = boxes.center_dist(seed, d)
                        if dist <= limit and (best_dist == nil or dist < best_dist) then
                            best, best_dist = di, dist
                        end
                    end
                end
                if best == nil then
                    complete = false
                    break
                end
                found[#found + 1] = remaining[best]
                local_used[best] = true
            end
            if complete then
                for i in pairs(local_used) do
                    used[i] = true
                end
                instances[#instances + 1] = found
            end
        end
    end
    return instances, without(remaining, used)
end

function catalog_instances.cluster(classes, remaining, same_class)
    if #classes == 0 then
        return {}, remaining
    end
    if #classes == 1 then
        local out, kept = {}, {}
        for _, d in ipairs(remaining) do
            if same_class(d, classes[1]) then
                out[#out + 1] = { d }
            else
                kept[#kept + 1] = d
            end
        end
        return out, kept
    end
    if #classes == 2 then
        return pairs_of(classes[1], classes[2], remaining, same_class)
    end
    return greedy(classes, remaining, same_class)
end

return catalog_instances
