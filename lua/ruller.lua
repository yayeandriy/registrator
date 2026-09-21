-- Ruller: apply per-object Spatial pose thresholds after `validation.lua`.
--
-- Matching, extras, and mismatched-vs-missing stay in `validation.lua`.
-- This script only re-classifies same-class pose outcomes
-- (`matched` / `mispositioned` / `misrotated` / `mispositioned_misrotated`)
-- using each expected object's own thresholds when set, otherwise the
-- global `validation_thresholds` (absolute board-unit position + degrees).
--
-- Position is radial only: catalog `distance` (or global `position`)
-- compared to the previous step's `delta_position` (`N away`). No
-- second measurement and no axis split.
-- When the expected object has `real_size.long` (millimetres) and a
-- board-space span is known (matched object-aligned box, else the
-- expected placement), `delta_position` is converted to millimetres
-- **and written back** so HUD / verdict `N mm` is millimetres:
--   mm_per_unit = real_size.long / max(span_width, span_height)
--   delta_mm    = delta_position * mm_per_unit
-- Catalog `distance` is millimetres in that case. Without real size
-- (or without a span), distance stays in board units.
-- `rotation` is degrees and is independent, but only applied when the
-- expected object's `symmetry` is a discrete period
-- (`60` / `90` / `120` / `180`). `inf` and `0` leave the
-- validation.lua rotation classification as-is.
--
-- Input:
--   {
--     expected = { ... },                    -- same tree validation saw
--     registered_detections = { ... },       -- board-space detections
--     validation = { ... },                  -- output of validation.lua
--     thresholds = { position, rotation } | nil,  -- global fallback
--   }
--
-- Output: the same shape as `validation.lua` (objects / extras / score).

local DEFAULT_THRESHOLDS = {
    position = 8.0,
    rotation = 30.0,
}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function non_empty(s)
    return type(s) == "string" and trim(s) ~= ""
end

local function yolo_classes_for(o)
    if type(o.yolo_classes) == "table" then
        local out = {}
        for _, v in ipairs(o.yolo_classes) do
            if non_empty(v) then
                table.insert(out, trim(v))
            end
        end
        if #out > 0 then
            return out
        end
    end
    if non_empty(o.yolo_class) then
        return { trim(o.yolo_class) }
    end
    return {}
end

local function flatten(objects, origin_x, origin_y, out)
    origin_x = origin_x or 0.0
    origin_y = origin_y or 0.0
    for _, o in ipairs(objects) do
        local x = origin_x + o.boundary.x
        local y = origin_y + o.boundary.y
        table.insert(out, {
            id = o.id,
            symmetry = o.symmetry or "inf",
            thresholds = o.thresholds,
            real_size = o.real_size,
            width = o.boundary and o.boundary.width or 0.0,
            height = o.boundary and o.boundary.height or 0.0,
            yolo_classes = yolo_classes_for(o),
        })
        if o.children then
            flatten(o.children, x, y, out)
        end
    end
    return out
end

local function pose_statuses(status)
    return status == "matched"
        or status == "mispositioned"
        or status == "misrotated"
        or status == "mispositioned_misrotated"
end

local function find_expected(flat, id)
    if id == nil then
        return nil
    end
    local key = tostring(id)
    for _, o in ipairs(flat) do
        if o.id ~= nil and tostring(o.id) == key then
            return o
        end
    end
    return nil
end

local function verdict_distance(obj)
    if type(obj.delta_position) == "number" then
        return obj.delta_position
    end
    return 0.0
end

local function span_long(w, h)
    w = type(w) == "number" and w or 0.0
    h = type(h) == "number" and h or 0.0
    return math.max(w, h)
end

local function box_long(obj)
    return span_long(obj.matched_width, obj.matched_height)
end

local function real_long_mm(exp)
    local rs = type(exp) == "table" and exp.real_size or nil
    if type(rs) == "table" and type(rs.long) == "number" and rs.long > 0 then
        return rs.long
    end
    return nil
end

-- Board-space length of the physical part: live object-aligned box when
-- layout assigned one, otherwise the expected placement.
local function unit_long(copy, exp)
    local detected = box_long(copy)
    if detected > 0 then
        return detected
    end
    if type(exp) == "table" then
        return span_long(exp.width, exp.height)
    end
    return 0.0
end

-- Convert board-unit `delta_position` into millimetres when the catalog
-- part has a real size and a board-space span is known. Writes mm back
-- onto `copy.delta_position` so inspect HUD / verdict show millimetres.
local function position_delta(copy, exp)
    local delta = verdict_distance(copy)
    local long_mm = real_long_mm(exp)
    local span = unit_long(copy, exp)
    if long_mm ~= nil and span > 0 then
        local mm = delta * (long_mm / span)
        copy.delta_position = mm
        return mm
    end
    return delta
end

local function object_thr(exp, global)
    local t = type(exp) == "table" and type(exp.thresholds) == "table" and exp.thresholds or {}
    return {
        distance = type(t.distance) == "number" and t.distance or nil,
        rotation = type(t.rotation) == "number" and t.rotation or nil,
        global_position = global.position,
        global_rotation = global.rotation,
    }
end

local function position_ok(copy, exp, thr)
    if thr.distance ~= nil then
        return position_delta(copy, exp) <= thr.distance
    end
    -- Global fallback stays board units even when real_size is set.
    return verdict_distance(copy) <= thr.global_position
end

local function rotation_thresholds_apply(symmetry)
    local s = tostring(symmetry or "inf")
    return s == "60" or s == "90" or s == "120" or s == "180"
end

local function pose_status(ok_pos, ok_rot)
    if ok_pos and ok_rot then
        return "matched"
    elseif not ok_pos and not ok_rot then
        return "mispositioned_misrotated"
    elseif not ok_pos then
        return "mispositioned"
    end
    return "misrotated"
end

local function ruller(input)
    local thresholds = {
        position = DEFAULT_THRESHOLDS.position,
        rotation = DEFAULT_THRESHOLDS.rotation,
    }
    local given = input.thresholds
    if type(given) == "table" then
        if type(given.position) == "number" then
            thresholds.position = given.position
        end
        if type(given.rotation) == "number" then
            thresholds.rotation = given.rotation
        end
    end

    local validation = input.validation or {}
    local objects = validation.objects or {}
    local expected_flat = flatten(input.expected or {}, 0.0, 0.0, {})

    local matched = 0
    local out_objects = {}
    for _, obj in ipairs(objects) do
        local copy = {}
        for k, v in pairs(obj) do
            copy[k] = v
        end
        if pose_statuses(copy.status) then
            local exp = find_expected(expected_flat, copy.id)
            if exp then
                local thr = object_thr(exp, thresholds)
                local ok_pos = position_ok(copy, exp, thr)
                local ok_rot
                if rotation_thresholds_apply(exp.symmetry) then
                    ok_rot = true
                    if type(copy.delta_rotation) == "number" then
                        if thr.rotation ~= nil then
                            ok_rot = copy.delta_rotation <= thr.rotation
                        else
                            ok_rot = copy.delta_rotation <= thr.global_rotation
                        end
                    end
                else
                    -- Keep validation.lua's rotation classification.
                    ok_rot = copy.status == "matched" or copy.status == "mispositioned"
                end
                copy.status = pose_status(ok_pos, ok_rot)
            end
        end
        if copy.status == "matched" then
            matched = matched + 1
        end
        table.insert(out_objects, copy)
    end

    local total = validation.total
    if type(total) ~= "number" then
        total = #out_objects
    end
    return {
        objects = out_objects,
        extra_detections = validation.extra_detections or {},
        score = total > 0 and (matched / total) or 0.0,
        matched = matched,
        total = total,
        extra = validation.extra or #(validation.extra_detections or {}),
    }
end

return ruller
