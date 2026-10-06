-- Sticky Spatial extras. `live.lua` latches Presence extras itself; a
-- Spatial surplus part would blink out on every accumulator dropout, so
-- the host carries this list between ticks and hands it back.
--
--   extras.sticky { latched = { { detection, misses } }, current = { <registered detection> } }
--     -> { latched, detections }
--
-- Boxes are in board units. N surplus parts of one class stay N rows:
-- each prior is IoU-matched to one current box. A prior with no match
-- survives a few misses, unless this tick already lists extras of its
-- class (assignment can rotate which leftover box is the extra).

local extras = {}

local IOU_MIN = 0.2
local MAX_MISSES = 3

local function iou(a, b)
    local ix = math.min(a.x + a.width, b.x + b.width) - math.max(a.x, b.x)
    local iy = math.min(a.y + a.height, b.y + b.height) - math.max(a.y, b.y)
    if ix <= 0 or iy <= 0 then
        return 0
    end
    local inter = ix * iy
    local union = a.width * a.height + b.width * b.height - inter
    return union > 0 and inter / union or 0
end

-- One box per overlapping same-class cluster, most confident first.
local function cluster(detections)
    local order = {}
    for i, d in ipairs(detections) do
        order[i] = { d = d, i = i }
    end
    table.sort(order, function(a, b)
        local ca, cb = a.d.confidence or 0, b.d.confidence or 0
        if ca ~= cb then
            return ca > cb
        end
        return a.i < b.i
    end)
    local kept = {}
    for _, item in ipairs(order) do
        local d = item.d
        local dup = false
        for _, k in ipairs(kept) do
            if k.label == d.label and iou(k, d) >= IOU_MIN then
                dup = true
                break
            end
        end
        if not dup then
            kept[#kept + 1] = d
        end
    end
    return kept
end

function extras.sticky(input)
    local curr = cluster(input.current or {})
    local per_label = {}
    for _, c in ipairs(curr) do
        per_label[c.label] = (per_label[c.label] or 0) + 1
    end
    local used, latched = {}, {}
    for _, prior in ipairs(input.latched or {}) do
        local d = prior.detection or {}
        local misses = prior.misses or 0
        local best, best_iou = nil, IOU_MIN
        for i, c in ipairs(curr) do
            if not used[i] and c.label == d.label then
                local v = iou(d, c)
                if v >= best_iou then
                    best, best_iou = i, v
                end
            end
        end
        if best ~= nil then
            used[best] = true
            latched[#latched + 1] = { detection = curr[best], misses = 0 }
        elseif (per_label[d.label] or 0) == 0 and misses + 1 <= MAX_MISSES then
            latched[#latched + 1] = { detection = d, misses = misses + 1 }
        end
    end
    for i, c in ipairs(curr) do
        if not used[i] then
            latched[#latched + 1] = { detection = c, misses = 0 }
        end
    end
    local detections = {}
    for i, e in ipairs(latched) do
        detections[i] = e.detection
    end
    return { latched = latched, detections = detections }
end

return extras
