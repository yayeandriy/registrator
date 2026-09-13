-- Layout: global assignment of detections to expected objects.
--
-- `validation.lua` claims same-class boxes independently, in flatten
-- order, with no look-ahead. Neighbors steal: a hole processed first
-- takes the pin sitting in the next slot, and the leftover far box
-- paints the correct pin yellow.
--
-- This script looks at the whole layout. Same I/O shape as
-- `validation.lua` / `ruller.lua` — a standalone callable, no `require`.
-- When `enabled` is false it returns `validation` unchanged so the host
-- can leave the step in the chain and flip it off.
--
-- Input:
--   {
--     expected = { ... },
--     registered_detections = { ... },
--     validation = { ... },              -- previous step (passthrough when off)
--     thresholds = { position, rotation } | nil,
--     enabled = true | false | nil,      -- nil → on
--   }
--
-- Output: the same shape as `validation.lua`. Claimed objects also carry
-- `matched_x` / `matched_y` / `matched_width` / `matched_height` (board
-- space) so overlays bind the assigned box, not the expected slot.

local DEFAULT_THRESHOLDS = {
    position = 8.0,
    rotation = 30.0,
}

local INF = 1e9

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function non_empty(s)
    return type(s) == "string" and trim(s) ~= ""
end

local function normalize_alnum(s)
    if type(normalisator) == "function" then
        local r = normalisator({ value = s })
        if type(r) == "table" and type(r.value) == "string" then
            return r.value
        end
        return ""
    end
    if type(s) ~= "string" then
        return ""
    end
    local t = trim(s):upper()
    t = t:gsub("%s+", "")
    t = t:gsub("[^%w]", "")
    return t
end

local function is_ocr_kind(kind)
    if type(kind) ~= "string" then
        return false
    end
    kind = kind:lower()
    return kind == "ocr" or kind:sub(1, 4) == "ocr:"
end

local function ocr_text_match(hay, needle)
    if type(matcher) == "function" then
        local r = matcher({ hay = hay, needle = needle })
        return r and r.matched == true
    end
    local h = normalize_alnum(hay)
    local n = normalize_alnum(needle)
    return h ~= "" and n ~= "" and h:find(n, 1, true) ~= nil
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

local function ocr_values_for(o)
    if type(o.ocr_values) == "table" then
        local out = {}
        for _, v in ipairs(o.ocr_values) do
            if non_empty(v) then
                table.insert(out, trim(v))
            end
        end
        if #out > 0 then
            return out
        end
    end
    if non_empty(o.ocr_value) then
        return { trim(o.ocr_value) }
    end
    if #(yolo_classes_for(o)) == 0 and non_empty(o.name) then
        return { trim(o.name) }
    end
    return {}
end

local function label_in_classes(label, classes)
    for _, class in ipairs(classes) do
        if label == class then
            return true
        end
    end
    return false
end

local function label_matches_object(label, o)
    if label_in_classes(label, o.yolo_classes or {}) then
        return true
    end
    if #(o.yolo_classes or {}) == 0 then
        for _, needle in ipairs(o.ocr_values or {}) do
            if ocr_text_match(label, needle) then
                return true
            end
        end
    end
    return false
end

local function label_is_expected_ocr(label, expected_flat)
    for _, o in ipairs(expected_flat) do
        for _, needle in ipairs(o.ocr_values or {}) do
            if ocr_text_match(label, needle) then
                return true
            end
        end
    end
    return false
end

local function flatten(objects, origin_x, origin_y, out)
    origin_x = origin_x or 0.0
    origin_y = origin_y or 0.0
    for _, o in ipairs(objects) do
        local x = origin_x + o.boundary.x
        local y = origin_y + o.boundary.y
        table.insert(out, {
            id = o.id,
            yolo_classes = yolo_classes_for(o),
            ocr_values = ocr_values_for(o),
            x = x,
            y = y,
            width = o.boundary.width,
            height = o.boundary.height,
            rotation = o.rotation or 0.0,
            is_anchor = o.is_anchor,
            symmetry = o.symmetry or "inf",
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

local function angle_diff_with_symmetry(a, b, symmetry)
    local period
    local sym = tostring(symmetry or "inf")
    if sym == "inf" then
        period = 360.0
    else
        period = tonumber(sym) or 360.0
        if period <= 0 then
            return 0.0
        end
    end
    local half = period / 2.0
    local diff = (a - b) % period
    if diff < 0 then
        diff = diff + period
    end
    if diff > half then
        diff = period - diff
    end
    return diff
end

-- Kuhn–Munkres on a square cost matrix (1-based). Returns
-- assignment[row] = col.
local function hungarian_square(a, n)
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

-- Rectangular: assignment[i] = j (1-based into the original columns)
-- or nil. Dummy pad cells use cost 0 so leftovers stay unassigned.
local function hungarian(cost, n, m)
    if n == 0 or m == 0 then
        return {}
    end
    local k = n
    if m > k then
        k = m
    end
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
    local raw = hungarian_square(a, k)
    local assignment = {}
    for i = 1, n do
        local j = raw[i]
        if j and j <= m then
            assignment[i] = j
        end
    end
    return assignment
end

local function pose_status(position_ok, rotation_ok)
    if position_ok and rotation_ok then
        return "matched"
    elseif not position_ok and not rotation_ok then
        return "mispositioned_misrotated"
    elseif not position_ok then
        return "mispositioned"
    end
    return "misrotated"
end

local function outcome_from_pair(o, detected, delta_position, thresholds)
    local position_ok = delta_position <= thresholds.position
    local delta_rotation = nil
    local rotation_ok = true
    if detected.rotation ~= nil and type(detected.rotation) == "number" then
        delta_rotation = angle_diff_with_symmetry(
            detected.rotation,
            o.rotation or 0.0,
            o.symmetry
        )
        rotation_ok = delta_rotation <= thresholds.rotation
    end
    return {
        id = o.id,
        yolo_classes = o.yolo_classes,
        ocr_values = o.ocr_values,
        is_anchor = o.is_anchor,
        status = pose_status(position_ok, rotation_ok),
        matched_label = detected.label,
        matched_confidence = detected.confidence,
        delta_position = delta_position,
        delta_rotation = delta_rotation,
        matched_x = detected.x,
        matched_y = detected.y,
        matched_width = detected.width,
        matched_height = detected.height,
    }
end

local function nearest_any_match(o, detections, claimed, expected_flat)
    local ex, ey = center(o)
    local skip_ocr = #(o.yolo_classes or {}) > 0
    local best, best_dist = nil, math.huge
    for _, d in ipairs(detections) do
        if not claimed[d._idx]
            and not is_ocr_kind(d.kind)
            and not (skip_ocr and label_is_expected_ocr(d.label, expected_flat))
        then
            local dx, dy = center(d)
            local dist = distance(ex, ey, dx, dy)
            if dist < best_dist then
                best, best_dist = d, dist
            end
        end
    end
    return best, best_dist
end

local function assign_layout(expected_flat, detections, thresholds)
    local n = #expected_flat
    local m = #detections
    local cost = {}
    for i = 1, n do
        cost[i] = {}
        local o = expected_flat[i]
        local ex, ey = center(o)
        for j = 1, m do
            local d = detections[j]
            if label_matches_object(d.label, o) then
                local dx, dy = center(d)
                cost[i][j] = distance(ex, ey, dx, dy)
            else
                cost[i][j] = INF
            end
        end
    end
    local assignment = hungarian(cost, n, m)
    local claimed = {}
    local objects = {}
    local pending = {}
    for i, o in ipairs(expected_flat) do
        local j = assignment[i]
        if j and cost[i][j] < INF / 2 then
            local detected = detections[j]
            claimed[detected._idx] = true
            table.insert(objects, outcome_from_pair(o, detected, cost[i][j], thresholds))
        else
            table.insert(objects, false)
            table.insert(pending, { index = #objects, object = o })
        end
    end
    for _, p in ipairs(pending) do
        local wrong, dist = nearest_any_match(p.object, detections, claimed, expected_flat)
        if wrong and dist <= thresholds.position then
            claimed[wrong._idx] = true
            objects[p.index] = {
                id = p.object.id,
                yolo_classes = p.object.yolo_classes,
                ocr_values = p.object.ocr_values,
                is_anchor = p.object.is_anchor,
                status = "mismatched",
                matched_label = wrong.label,
                matched_confidence = wrong.confidence,
                delta_position = dist,
                matched_x = wrong.x,
                matched_y = wrong.y,
                matched_width = wrong.width,
                matched_height = wrong.height,
            }
        else
            objects[p.index] = {
                id = p.object.id,
                yolo_classes = p.object.yolo_classes,
                ocr_values = p.object.ocr_values,
                is_anchor = p.object.is_anchor,
                status = "missing",
            }
        end
    end
    local extra_detections = {}
    for _, d in ipairs(detections) do
        if not claimed[d._idx] and not is_ocr_kind(d.kind) then
            table.insert(extra_detections, {
                label = d.label,
                confidence = d.confidence,
                x = d.x,
                y = d.y,
                width = d.width,
                height = d.height,
                rotation = d.rotation,
                kind = d.kind,
            })
        end
    end
    local matched = 0
    for _, obj in ipairs(objects) do
        if obj.status == "matched" then
            matched = matched + 1
        end
    end
    local total = n
    return {
        objects = objects,
        extra_detections = extra_detections,
        score = total > 0 and (matched / total) or 0.0,
        matched = matched,
        total = total,
        extra = #extra_detections,
    }
end

local function layout(input)
    local enabled = input.enabled
    if enabled == false then
        return input.validation or {
            objects = {},
            extra_detections = {},
            score = 0.0,
            matched = 0,
            total = 0,
            extra = 0,
        }
    end
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
    local expected_flat = flatten(input.expected or {}, 0.0, 0.0, {})
    local detections = {}
    for i, d in ipairs(input.registered_detections or {}) do
        local tagged = { _idx = i }
        for k, v in pairs(d) do
            tagged[k] = v
        end
        table.insert(detections, tagged)
    end
    return assign_layout(expected_flat, detections, thresholds)
end

return layout
