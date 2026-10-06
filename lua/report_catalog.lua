-- Unexpected stamps on the verdict sheet: cluster unclaimed Spatial
-- boxes into full class-set instances and name each from the project
-- catalog by the OCR inside it (a code only one component carries wins).
-- Only surplus of a class the profile places is listed.
--
-- Needs `report_rules` in scope.
--
--   report_catalog.extras(boxes, ocr, catalog, profile_keys) -> { entry }
--     catalog = { { id, display_name, yolo_classes, ocr_values } }

local rules = report_rules
local report_catalog = {}

-- Two boxes join one instance when their centres sit within this many
-- of the larger box's sides.
local REACH = 5.0
local MIN_SIDE = 0.01
local PAD_RATIO = 0.2
local MIN_PAD = 0.025

local function center(d)
    return d.x + d.width * 0.5, d.y + d.height * 0.5
end

local function center_dist(a, b)
    local ax, ay = center(a)
    local bx, by = center(b)
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

local function side(d)
    return math.max(d.width, MIN_SIDE), math.max(d.height, MIN_SIDE)
end

local function box_key(d)
    return string.format("%s|%.4f|%.4f|%.4f|%.4f", d.label, d.x, d.y, d.width, d.height)
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

-- Every class-A box pairs with its nearest class-B box, globally closest first.
local function pairs_of(a_label, b_label, remaining)
    local cands = {}
    for ai, a in ipairs(remaining) do
        if a.label == a_label then
            local aw, ah = side(a)
            for bi, b in ipairs(remaining) do
                if b.label == b_label then
                    local bw, bh = side(b)
                    local dist = center_dist(a, b)
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
local function greedy(classes, remaining)
    local used, instances = {}, {}
    for si, seed in ipairs(remaining) do
        if seed.label == classes[1] and not used[si] then
            local boxes, local_used = { seed }, { [si] = true }
            local sw, sh = side(seed)
            local limit = math.max(sw, sh) * REACH
            local complete = true
            for c = 2, #classes do
                local best, best_dist
                for di, d in ipairs(remaining) do
                    if not used[di] and not local_used[di] and d.label == classes[c] then
                        local dist = center_dist(seed, d)
                        if dist <= limit and (best_dist == nil or dist < best_dist) then
                            best, best_dist = di, dist
                        end
                    end
                end
                if best == nil then
                    complete = false
                    break
                end
                boxes[#boxes + 1] = remaining[best]
                local_used[best] = true
            end
            if complete and #boxes == #classes then
                for i in pairs(local_used) do
                    used[i] = true
                end
                instances[#instances + 1] = boxes
            end
        end
    end
    return instances, without(remaining, used)
end

function report_catalog.instances(classes, remaining)
    if #classes == 0 then
        return {}, remaining
    end
    if #classes == 1 then
        local out, kept = {}, {}
        for _, d in ipairs(remaining) do
            if d.label == classes[1] then
                out[#out + 1] = { d }
            else
                kept[#kept + 1] = d
            end
        end
        return out, kept
    end
    if #classes == 2 then
        return pairs_of(classes[1], classes[2], remaining)
    end
    return greedy(classes, remaining)
end

local function padded_union(boxes)
    local f = boxes[1]
    local x1, y1, x2, y2 = f.x, f.y, f.x + f.width, f.y + f.height
    for i = 2, #boxes do
        local d = boxes[i]
        x1, y1 = math.min(x1, d.x), math.min(y1, d.y)
        x2, y2 = math.max(x2, d.x + d.width), math.max(y2, d.y + d.height)
    end
    local px = math.max((x2 - x1) * PAD_RATIO, MIN_PAD)
    local py = math.max((y2 - y1) * PAD_RATIO, MIN_PAD)
    return x1 - px, y1 - py, x2 + px, y2 + py
end

-- A code read inside the instance scores 10 when only this component
-- carries it, 1 otherwise. Class-only components accept any instance.
function report_catalog.score(comp, instance, ocr, group)
    local x1, y1, x2, y2 = padded_union(instance)
    local score, required, found, unique = 0, 0, 0, false
    for _, needle in ipairs(comp.ocr_values or {}) do
        local n = rules.alnum(needle)
        if n ~= "" then
            required = required + 1
            local hit = false
            for _, o in ipairs(ocr or {}) do
                local cx, cy = center(o)
                if cx >= x1 and cx <= x2 and cy >= y1 and cy <= y2 and rules.hits(o.label, needle) then
                    hit = true
                    break
                end
            end
            if hit then
                found = found + 1
                local owners = 0
                for _, g in ipairs(group) do
                    for _, v in ipairs(g.ocr_values or {}) do
                        if rules.alnum(v) == n then
                            owners = owners + 1
                            break
                        end
                    end
                end
                if owners == 1 then
                    unique = true
                    score = score + 10
                else
                    score = score + 1
                end
            end
        end
    end
    if required == 0 then
        return 1
    end
    if found < required and not unique then
        return 0
    end
    return score
end

local function signature(classes)
    local keys = {}
    for i, c in ipairs(classes) do
        keys[i] = c:lower()
    end
    table.sort(keys)
    return table.concat(keys, "\0")
end

local function groups(catalog)
    local order, by = {}, {}
    for _, comp in ipairs(catalog or {}) do
        if #(comp.yolo_classes or {}) > 0 then
            local sig = signature(comp.yolo_classes)
            if by[sig] == nil then
                by[sig] = {}
                order[#order + 1] = sig
            end
            local g = by[sig]
            g[#g + 1] = comp
        end
    end
    local out = {}
    for i, sig in ipairs(order) do
        out[i] = by[sig]
    end
    return out
end

local function plain_extra(d)
    return {
        id = string.format("extra-%s-%.4f-%.4f", d.label, d.x, d.y),
        name = d.label,
        bucket = "extra",
        mismatches = {},
        confidence = d.confidence,
        matched_label = d.label,
    }
end
report_catalog.plain_extra = plain_extra

function report_catalog.extras(boxes, ocr, catalog, profile_keys)
    local remaining = {}
    for _, d in ipairs(boxes or {}) do
        local kind = rules.lower(d.kind or "yolo")
        if kind:sub(1, 3) ~= "ocr" and rules.keep_surplus(d.label, d.matched_label, profile_keys) then
            remaining[#remaining + 1] = d
        end
    end
    if #remaining == 0 then
        return {}
    end
    local entries = {}
    for _, comps in ipairs(groups(catalog)) do
        local instances
        instances, remaining = report_catalog.instances(comps[1].yolo_classes, remaining)
        if #instances > 0 then
            local scored = {}
            for _, comp in ipairs(comps) do
                for _, inst in ipairs(instances) do
                    local s = report_catalog.score(comp, inst, ocr, comps)
                    if s > 0 then
                        scored[#scored + 1] = { comp = comp, inst = inst, score = s, n = #scored + 1 }
                    end
                end
            end
            table.sort(scored, function(a, b)
                if a.score ~= b.score then
                    return a.score > b.score
                end
                return a.n < b.n
            end)
            local claimed = {}
            local function taken(inst)
                for _, d in ipairs(inst) do
                    if claimed[box_key(d)] then
                        return true
                    end
                end
                return false
            end
            for _, p in ipairs(scored) do
                if not taken(p.inst) then
                    local keys, conf = {}, nil
                    for i, d in ipairs(p.inst) do
                        keys[i] = box_key(d)
                        claimed[keys[i]] = true
                        conf = (conf == nil or d.confidence > conf) and d.confidence or conf
                    end
                    entries[#entries + 1] = {
                        id = "extra-" .. tostring(p.comp.id) .. "-" .. table.concat(keys, "|"),
                        name = p.comp.display_name,
                        bucket = "extra",
                        mismatches = {},
                        confidence = conf,
                        matched_label = p.inst[1].label,
                    }
                end
            end
            for _, inst in ipairs(instances) do
                if not taken(inst) then
                    for _, d in ipairs(inst) do
                        remaining[#remaining + 1] = d
                    end
                end
            end
        end
    end
    for _, d in ipairs(remaining) do
        entries[#entries + 1] = plain_extra(d)
    end
    return entries
end

return report_catalog
