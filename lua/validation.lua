-- The Validator's shared algorithm library.
--
-- Where `registration.lua` finds *the* transformation between an
-- ExpectedLayout and a DetectionLog's frames, this script is the next
-- step: given that transformation already applied (i.e. a registration
-- run's own `registered_detections`, already expressed in the expected
-- layout's board-unit space), check every expected reference object for
-- a correspondingly-classed detection nearby, in both position *and*
-- orientation. When a lock is paired, those deltas live in the lock's
-- frame (the lock vs itself is the origin). The same "single source of truth in Lua, run identically
-- everywhere" rationale as `registration.lua` applies here too, since
-- "how close is close enough" is exactly the kind of per-deployment
-- tuning knob that shouldn't fork into separate native implementations.
--
-- Input (a single Lua table, passed as this chunk's first argument):
--   {
--     expected = { { yolo_classes, boundary = { x, y, width, height }, rotation, is_anchor, children = {...} }, ... },
--     registered_detections = { { label, confidence, x, y, width, height, rotation }, ... },
--     thresholds = { position = <board units>, rotation = <degrees> } | nil,
--   }
-- `expected` and `registered_detections` mirror `registration.lua`'s own
-- `expected` input and `registered_detections` output exactly (both
-- already in the same board-unit coordinate space — that's the entire
-- point of running registration first). `thresholds` is optional; see
-- `DEFAULT_THRESHOLDS` below for what's used when omitted or partial.
--
-- Output:
--   {
--     objects = {
--       {
--         id, yolo_classes, is_anchor,
--         status = "matched" | "missing" | "mismatched" | "mispositioned" | "misrotated" | "mispositioned_misrotated",
--         matched_label, matched_confidence,   -- nil when status == "missing"
--         delta_position,                      -- board units; nil when status == "missing"
--         delta_rotation,                       -- degrees; nil when status == "missing", "mismatched", or neither side has an orientation to compare. Range depends on the object's symmetry period (≤ period/2; for "180" that is 0..90).
--       },
--       ...
--     },
--     extra_detections = { { label, confidence, x, y, width, height, rotation, kind }, ... },
--     score = 0.0..1.0,  -- fraction of `objects` with status == "matched"
--     matched = <n>,
--     total = <n>,
--     extra = <n>,  -- #extra_detections
--   }
-- `mismatched` is "missing" own close cousin: no same-class detection
-- matched at all, but *something* was detected close enough to this
-- object's expected position to be the same physical thing, just
-- classified wrong — worth surfacing separately from a plain "nothing's
-- there", since it points at a detector class-confusion problem rather
-- than a placement one. `extra_detections` is the converse: detections
-- that never explained *any* expected object (not even a `mismatched`
-- one) — a real thing on the board the layout didn't ask for, or a
-- spurious false positive; either way, not something any `objects`
-- entry already accounts for. Unused OCR (`kind` starting `ocr`) is
-- never listed as extra — same rule as `presence_validator.lua`.
-- Needs `expected`, `pose` and `spatial` (composed by `bundles.json`).

-- Two placements of the same class on the same box are one physical
-- part. A single detection used to match the first and leave the copy
-- "missing", painted on top of the part that was actually found.
local function expectation_key(o)
    local classes = {}
    for _, c in ipairs(o.yolo_classes or {}) do
        if expected.non_empty(c) then
            table.insert(classes, string.lower(expected.trim(c)))
        end
    end
    table.sort(classes)
    if #classes > 0 then
        return table.concat(classes, "\0")
    end
    local texts = {}
    for _, t in ipairs(o.ocr_values or {}) do
        if expected.non_empty(t) then
            table.insert(texts, string.lower(expected.trim(t)))
        end
    end
    table.sort(texts)
    if #texts == 0 then
        return ""
    end
    return "ocr\0" .. table.concat(texts, "\0")
end

local function same_stacked_part(a, b)
    local key = expectation_key(a)
    if key == "" or key ~= expectation_key(b) then
        return false
    end
    local max_w = math.max(a.width or 0.0, b.width or 0.0, 1e-6)
    local max_h = math.max(a.height or 0.0, b.height or 0.0, 1e-6)
    if math.abs((a.width or 0.0) - (b.width or 0.0)) / max_w > 0.25 then
        return false
    end
    if math.abs((a.height or 0.0) - (b.height or 0.0)) / max_h > 0.25 then
        return false
    end
    local ax, ay = pose.center(a)
    local bx, by = pose.center(b)
    local diag = math.sqrt(max_w * max_w + max_h * max_h)
    return pose.distance(ax, ay, bx, by) <= diag * 0.2
end

local function collapse_stacked(flat)
    local kept = {}
    for _, o in ipairs(flat) do
        local stack = nil
        for i, prev in ipairs(kept) do
            if same_stacked_part(prev, o) then
                stack = i
                break
            end
        end
        if not stack then
            table.insert(kept, o)
        elseif o.is_anchor and not kept[stack].is_anchor then
            kept[stack] = o
        end
    end
    return kept
end

-- Nearest same-class (or same-text) detection to this expected object's
-- center among detections not yet claimed by another expected object.
local function nearest_match(o, detections, claimed)
    local ex, ey = pose.center(o)
    local best, best_dist = nil, math.huge
    for _, d in ipairs(detections) do
        if not claimed[d._idx] and expected.matches_object(d, o) then
            local dx, dy = pose.center(d)
            local dist = pose.distance(ex, ey, dx, dy)
            if dist < best_dist then
                best, best_dist = d, dist
            end
        end
    end
    return best, best_dist
end

local function validation(input)
    local thresholds = pose.thresholds(input.thresholds)
    local expected_flat = collapse_stacked(expected.flatten(input.expected))
    local detections = spatial.tag(input.registered_detections)

    -- Claim same-class matches first (so neighbors don't steal each other),
    -- then score pose in the lock's frame when a lock is paired. A removed
    -- part next to a correctly matched sibling must be "missing", not
    -- "incorrect · wrong type" via the sibling's detection.
    local claimed = {}
    local pairs = {}
    local paired = {}
    for _, o in ipairs(expected_flat) do
        local det = nearest_match(o, detections, claimed)
        if det then
            claimed[det._idx] = true
            pairs[#pairs + 1] = { object = o, detected = det }
            paired[o] = det
        end
    end

    local lock_for = spatial.lock_finder(pairs)
    local objects = {}
    for i, o in ipairs(expected_flat) do
        local det = paired[o]
        if det then
            objects[i] = spatial.scored(o, det, thresholds, lock_for(o))
        end
    end
    for i, o in ipairs(expected_flat) do
        if not paired[o] then
            objects[i] = spatial.unpaired(o, detections, thresholds, claimed, expected_flat)
        end
    end
    return spatial.result(objects, detections, claimed)
end

return validation
