-- Spatial rows shared by `validation` (greedy claim) and `layout`
-- (global assignment): tagging, lock frames, scored / mismatched /
-- missing rows, extras and the result envelope.
--
-- Needs `expected` and `pose`.

local spatial = {}

-- Copies with a stable `_idx` so claims survive marshaled tables.
function spatial.tag(detections)
    local out = {}
    for i, d in ipairs(detections or {}) do
        local tagged = { _idx = i }
        for k, v in pairs(d) do
            tagged[k] = v
        end
        out[#out + 1] = tagged
    end
    return out
end

-- Nearest unclaimed detection of *any* class, to tell "nothing here"
-- (missing) from "something unclaimed is here, wrong class"
-- (mismatched). OCR is never class confusion, and a YOLO slot ignores
-- reads that belong to some text placement.
local function nearest_any(o, detections, claimed, expected_flat)
    local ex, ey = pose.center(o)
    local skip_text = #(o.yolo_classes or {}) > 0
    local best, best_dist = nil, math.huge
    for _, d in ipairs(detections) do
        if not claimed[d._idx]
            and not expected.is_ocr_kind(d.kind)
            and not (skip_text and expected.is_expected_text(d.label, expected_flat))
        then
            local dx, dy = pose.center(d)
            local dist = pose.distance(ex, ey, dx, dy)
            if dist < best_dist then
                best, best_dist = d, dist
            end
        end
    end
    return best, best_dist
end

-- `lock_for(o)`: an anchor uses its own pair; any other object the
-- nearest paired anchor; nil when no anchor was paired.
function spatial.lock_finder(pairs)
    local frames = {}
    for _, p in ipairs(pairs) do
        if p.object.is_anchor then
            frames[#frames + 1] = { expected = p.object, detected = p.detected }
        end
    end
    return function(o)
        if o.is_anchor then
            for _, f in ipairs(frames) do
                if f.expected.id == o.id then
                    return f
                end
            end
            return nil
        end
        local ox, oy = pose.center(o)
        local best, best_d = nil, math.huge
        for _, f in ipairs(frames) do
            local lx, ly = pose.center(f.expected)
            local d = pose.distance(ox, oy, lx, ly)
            if d < best_d then
                best, best_d = f, d
            end
        end
        return best
    end
end

local function row(o, status)
    return {
        id = o.id,
        yolo_classes = o.yolo_classes,
        ocr_values = o.ocr_values,
        is_anchor = o.is_anchor,
        status = status,
    }
end

local function bind(r, d)
    r.matched_label = d.label
    r.matched_confidence = d.confidence
    r.matched_x = d.x
    r.matched_y = d.y
    r.matched_width = d.width
    r.matched_height = d.height
    return r
end

-- Same-class pair; pose in the lock's frame when one is paired.
function spatial.scored(o, detected, thresholds, lock_frame)
    local delta_position, delta_rotation = pose.deltas(o, detected, lock_frame)
    local r = bind(row(o, pose.outcome(delta_position, delta_rotation, thresholds)), detected)
    r.delta_position = delta_position
    r.delta_rotation = delta_rotation
    return r
end

-- Unpaired object: `mismatched` on the nearest unclaimed box within the
-- position threshold (claimed here), else `missing`.
function spatial.unpaired(o, detections, thresholds, claimed, expected_flat)
    local wrong, dist = nearest_any(o, detections, claimed, expected_flat)
    if wrong and dist <= thresholds.position then
        claimed[wrong._idx] = true
        local r = bind(row(o, "mismatched"), wrong)
        r.delta_position = dist
        return r
    end
    return row(o, "missing")
end

-- Envelope over `objects`; unclaimed non-OCR detections are extras.
function spatial.result(objects, detections, claimed)
    local extra_detections = {}
    for _, d in ipairs(detections) do
        if not claimed[d._idx] and not expected.is_ocr_kind(d.kind) then
            extra_detections[#extra_detections + 1] = {
                label = d.label,
                confidence = d.confidence,
                x = d.x,
                y = d.y,
                width = d.width,
                height = d.height,
                rotation = d.rotation,
                kind = d.kind,
            }
        end
    end
    local matched = 0
    for _, obj in ipairs(objects) do
        if obj.status == "matched" then
            matched = matched + 1
        end
    end
    local total = #objects
    return {
        objects = objects,
        extra_detections = extra_detections,
        score = total > 0 and (matched / total) or 0.0,
        matched = matched,
        total = total,
        extra = #extra_detections,
    }
end

return spatial
