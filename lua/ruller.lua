-- Ruller: apply per-object Spatial pose thresholds after `validation.lua`.
--
-- Matching, extras, and mismatched-vs-missing stay in `validation.lua`.
-- This script only re-classifies same-class pose outcomes
-- (`matched` / `mispositioned` / `misrotated` / `mispositioned_misrotated`)
-- using each expected object's own thresholds when set, otherwise the
-- global `validation_thresholds` (absolute board-unit position + degrees).
--
-- Per-object position uses *one* approach at a time:
--   axis     — `x` and/or `y` set (fractions of the detected box, along
--              the expected object's aligned axes). `distance` is ignored.
--   distance — only `distance` set (fraction of the detected diagonal).
--   else     — global absolute `validation_thresholds.position`.
-- `rotation` is degrees (same as validation) and is independent, but
-- only applied when the expected object's `symmetry` is a discrete
-- period (`60` / `90` / `120` / `180`). `inf` and `0` leave the
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
            x = x,
            y = y,
            width = o.boundary.width,
            height = o.boundary.height,
            rotation = o.rotation or 0.0,
            symmetry = o.symmetry or "inf",
            thresholds = o.thresholds,
            yolo_classes = yolo_classes_for(o),
        })
        if o.children then
            flatten(o.children, x, y, out)
        end
    end
    return out
end

local function center(o)
    return o.x + o.width / 2.0, o.y + o.height / 2.0
end

local function distance(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
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

-- Box the previous step assigned (`matched_x` / `matched_y`). Independent
-- of expected-slot nearest — layout.lua names the detection; ruller only
-- measures it.
local function detection_at_matched(obj, detections)
    if type(obj.matched_x) ~= "number" or type(obj.matched_y) ~= "number" then
        return nil
    end
    local mw = type(obj.matched_width) == "number" and obj.matched_width or 0
    local mh = type(obj.matched_height) == "number" and obj.matched_height or 0
    local mx = obj.matched_x + mw / 2.0
    local my = obj.matched_y + mh / 2.0
    local best, best_dist = nil, math.huge
    for _, d in ipairs(detections) do
        local dx, dy = center(d)
        local dist = distance(mx, my, dx, dy)
        if dist < best_dist then
            best, best_dist = d, dist
        end
    end
    return best
end

-- Prefer the assigned box; otherwise nearest same-class to the slot.
local function find_detection(exp, detections, obj)
    local assigned = detection_at_matched(obj, detections)
    if assigned then
        return assigned
    end
    local matched_label = obj.matched_label
    local ex, ey = center(exp)
    local best, best_dist = nil, math.huge
    for _, d in ipairs(detections) do
        local label_ok = false
        if non_empty(matched_label) then
            label_ok = d.label == matched_label
        else
            for _, class in ipairs(exp.yolo_classes or {}) do
                if d.label == class then
                    label_ok = true
                    break
                end
            end
        end
        if label_ok then
            local dx, dy = center(d)
            local dist = distance(ex, ey, dx, dy)
            if dist < best_dist then
                best, best_dist = d, dist
            end
        end
    end
    return best
end

local function local_rel(exp, det)
    local ecx, ecy = center(exp)
    local dcx, dcy = center(det)
    local dx, dy = dcx - ecx, dcy - ecy
    local theta = math.rad(-(exp.rotation or 0.0))
    local c, s = math.cos(theta), math.sin(theta)
    local lx = dx * c - dy * s
    local ly = dx * s + dy * c
    local bw = det.width
    local bh = det.height
    if type(bw) ~= "number" or bw <= 1e-9 then
        bw = exp.width
    end
    if type(bh) ~= "number" or bh <= 1e-9 then
        bh = exp.height
    end
    if bw <= 1e-9 then
        bw = 1.0
    end
    if bh <= 1e-9 then
        bh = 1.0
    end
    local diag = math.sqrt(bw * bw + bh * bh)
    if diag <= 1e-9 then
        diag = 1.0
    end
    return {
        x_rel = math.abs(lx) / bw,
        y_rel = math.abs(ly) / bh,
        dist_rel = math.sqrt(dx * dx + dy * dy) / diag,
    }
end

local function object_thr(exp, global)
    local t = type(exp) == "table" and type(exp.thresholds) == "table" and exp.thresholds or {}
    return {
        x = type(t.x) == "number" and t.x or nil,
        y = type(t.y) == "number" and t.y or nil,
        distance = type(t.distance) == "number" and t.distance or nil,
        rotation = type(t.rotation) == "number" and t.rotation or nil,
        global_position = global.position,
        global_rotation = global.rotation,
    }
end

local function position_ok(rel, thr, delta_position)
    -- Axis wins when either local axis is set so leftover `distance`
    -- from an older write cannot AND with x/y.
    if thr.x ~= nil or thr.y ~= nil then
        local ok = true
        if thr.x ~= nil then
            ok = ok and rel.x_rel <= thr.x
        end
        if thr.y ~= nil then
            ok = ok and rel.y_rel <= thr.y
        end
        return ok
    end
    if thr.distance ~= nil then
        return rel.dist_rel <= thr.distance
    end
    return (delta_position or 0.0) <= thr.global_position
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
    local detections = input.registered_detections or {}

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
                local det = find_detection(exp, detections, copy)
                local rel
                if det then
                    rel = local_rel(exp, det)
                else
                    rel = { x_rel = 0.0, y_rel = 0.0, dist_rel = 0.0 }
                end
                local thr = object_thr(exp, thresholds)
                local ok_pos = position_ok(rel, thr, copy.delta_position)
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
