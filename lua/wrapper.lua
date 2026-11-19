-- Component wrapper: one detection of a part stands for the whole part, and
-- counts only while the part's other detections lie inside its box.
--
-- Reads frame-local boxes only, so it holds for Presence and Spatial
-- placements alike, with or without an anchor. Live runs it before both.
--
-- An expected object may carry
--   wrapper = { class_id, label, vision_model_id } | { text = "..." }
-- (from `kit.lua`). It applies when the part has another detection besides.
--
-- wrapper.detections(expected, dets) -> dets
--   Drops every wrapper box that misses one of its part's other detections,
--   and the YOLO boxes a held wrapper contains for its part. A held class
--   box is tagged `class_id = wrapper.part_class(id)` for the part it holds
--   (one copy per part), so parts that share a wrapper class never take
--   each other's box.
-- wrapper.expected(expected) -> expected
--   A copy of the tree where a wrapped part expects only its wrapper: its
--   own tagged box for a class wrapper, the wrapper text for a text one.
-- wrapper.lacks(expected, dets) -> { [object id] = { Lack } }
--   Why each wrapped part does not count: its wrapper unseen, or what the
--   best wrapper box fails to hold. Lack = { label, kind = "class"|"text",
--   why = "unseen"|"outside" }; `outside` is seen, but not in a wrapper.

-- Share of an inner box's area that must lie within the wrapper box.
local INSIDE = 0.6

local function is_ocr(d)
    local k = d.kind
    if type(k) ~= "string" then
        return false
    end
    k = k:lower()
    return k == "ocr" or k:sub(1, 4) == "ocr:"
end

local function num(v)
    if type(v) == "number" then
        return v
    end
    return 0
end

local function inside_share(inner, outer)
    local w, h = num(inner.width), num(inner.height)
    if w <= 0 or h <= 0 then
        return 0
    end
    local x0 = math.max(num(inner.x), num(outer.x))
    local y0 = math.max(num(inner.y), num(outer.y))
    local x1 = math.min(num(inner.x) + w, num(outer.x) + num(outer.width))
    local y1 = math.min(num(inner.y) + h, num(outer.y) + num(outer.height))
    if x1 <= x0 or y1 <= y0 then
        return 0
    end
    return (x1 - x0) * (y1 - y0) / (w * h)
end

local function text_hit(d, needle)
    if not is_ocr(d) then
        return false
    end
    local ok, r = pcall(matcher, { hay = tostring(d.label or ""), needle = needle })
    return ok and type(r) == "table" and r.matched == true
end

local function class_hit(d, ref)
    return not is_ocr(d) and class_match.match(d, ref)
end

local function hits(d, need)
    if need.text then
        return text_hit(d, need.text)
    end
    return class_hit(d, need.class)
end

-- What a wrapped part must find inside its wrapper box.
local function inners(o)
    local w, out = o.wrapper, {}
    for _, ref in ipairs(class_match.expected_list(o)) do
        if w.text or not class_match.match(ref, w) then
            out[#out + 1] = { class = ref }
        end
    end
    for _, v in ipairs(o.ocr_values or {}) do
        if v ~= w.text then
            out[#out + 1] = { text = v }
        end
    end
    return out
end

local function wrapped(o)
    return type(o.wrapper) == "table" and #inners(o) > 0
end

local function wrapped_objects(objects, out)
    for _, o in ipairs(objects or {}) do
        if wrapped(o) then
            out[#out + 1] = o
        end
        wrapped_objects(o.children, out)
    end
    return out
end

-- Indices of the inner boxes the wrapper at `wi` holds, or nil when one is missing.
local function held(dets, wi, needs)
    local taken = {}
    for _, need in ipairs(needs) do
        local found
        for i, d in ipairs(dets) do
            if i ~= wi and not taken[i] and hits(d, need) and inside_share(d, dets[wi]) >= INSIDE then
                found = i
                break
            end
        end
        if found == nil then
            return nil
        end
        taken[found] = true
    end
    return taken
end

local function part_class(id)
    return "wrapper:" .. tostring(id)
end

local function tagged(d, id)
    local c = {}
    for k, v in pairs(d) do
        c[k] = v
    end
    c.class_id = part_class(id)
    return c
end

local function detections(expected, dets)
    local objects = wrapped_objects(expected, {})
    if #objects == 0 or type(dets) ~= "table" then
        return dets
    end
    local keep, drop, holds = {}, {}, {}
    for _, o in ipairs(objects) do
        local needs = inners(o)
        for i, d in ipairs(dets) do
            if hits(d, o.wrapper.text and { text = o.wrapper.text } or { class = o.wrapper }) then
                local taken = held(dets, i, needs)
                if taken then
                    keep[i] = true
                    if not o.wrapper.text then
                        holds[i] = holds[i] or {}
                        holds[i][#holds[i] + 1] = o.id
                    end
                    for j in pairs(taken) do
                        drop[j] = drop[j] or not is_ocr(dets[j])
                    end
                else
                    drop[i] = true
                end
            end
        end
    end
    local out = {}
    for i, d in ipairs(dets) do
        if holds[i] then
            for _, id in ipairs(holds[i]) do
                out[#out + 1] = tagged(d, id)
            end
        elseif keep[i] or not drop[i] then
            out[#out + 1] = d
        end
    end
    return out
end

local function lack(need, why)
    if need.text then
        return { label = need.text, kind = "text", why = why }
    end
    return { label = tostring(need.class.label or ""), kind = "class", why = why }
end

-- What the box at `wi` misses of `needs`: `outside` when seen elsewhere.
local function missed_by(dets, wi, needs)
    local out = {}
    for _, need in ipairs(needs) do
        local seen, inside = false, false
        for j, d in ipairs(dets) do
            if j ~= wi and hits(d, need) then
                seen = true
                if inside_share(d, dets[wi]) >= INSIDE then
                    inside = true
                    break
                end
            end
        end
        if not inside then
            out[#out + 1] = lack(need, seen and "outside" or "unseen")
        end
    end
    return out
end

local function lacks(expected, dets)
    local out = {}
    for _, o in ipairs(wrapped_objects(expected, {})) do
        local own = o.wrapper.text and { text = o.wrapper.text } or { class = o.wrapper }
        local needs, best = inners(o), nil
        for i, d in ipairs(dets or {}) do
            if hits(d, own) then
                local missed = missed_by(dets, i, needs)
                if best == nil or #missed < #best then
                    best = missed
                end
            end
        end
        best = best or { lack(own, "unseen") }
        if #best > 0 then
            out[o.id] = best
        end
    end
    return out
end

local function expected(objects)
    local out = {}
    for i, o in ipairs(objects or {}) do
        local c = {}
        for k, v in pairs(o) do
            c[k] = v
        end
        if wrapped(o) then
            local w = o.wrapper
            if w.text then
                c.yolo_classes, c.yolo_class_refs, c.ocr_values = {}, {}, { w.text }
            else
                c.yolo_classes = { w.label }
                c.yolo_class_refs = {
                    { class_id = part_class(o.id), label = w.label, vision_model_id = w.vision_model_id },
                }
                c.ocr_values = {}
            end
        end
        if type(o.children) == "table" then
            c.children = expected(o.children)
        end
        out[i] = c
    end
    return out
end

return {
    INSIDE = INSIDE,
    part_class = part_class,
    detections = detections,
    expected = expected,
    lacks = lacks,
}
