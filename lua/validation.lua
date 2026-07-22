-- The Validator's shared algorithm library.
--
-- Where `registration.lua` finds *the* transformation between an
-- ExpectedLayout and a DetectionLog's frames, this script is the next
-- step: given that transformation already applied (i.e. a registration
-- run's own `registered_detections`, already expressed in the expected
-- layout's board-unit space), check every expected reference object for
-- a correspondingly-classed detection nearby, in both position *and*
-- orientation — the same "single source of truth in Lua, run identically
-- everywhere" rationale as `registration.lua` applies here too, since
-- "how close is close enough" is exactly the kind of per-deployment
-- tuning knob that shouldn't fork into separate native implementations.
--
-- Input (a single Lua table, passed as this chunk's first argument):
--   {
--     expected = { { yolo_class, boundary = { x, y, width, height }, rotation, is_anchor, children = {...} }, ... },
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
--         id, yolo_class, is_anchor,
--         status = "matched" | "missing" | "mismatched" | "mispositioned" | "misrotated" | "mispositioned_misrotated",
--         matched_label, matched_confidence,   -- nil when status == "missing"
--         delta_position,                      -- board units; nil when status == "missing"
--         delta_rotation,                       -- degrees, 0..90; nil when status == "missing", "mismatched", or neither side has an orientation to compare
--       },
--       ...
--     },
--     extra_detections = { { label, confidence, x, y, width, height, rotation }, ... },
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
-- entry already accounts for.

-- Deliberately generous — a single-anchor registration (the common case
-- today: most boards define just the one anchor) only pins position and
-- axis-aligned scale near *that* anchor; error grows the further an
-- object sits from it, and a strict threshold tuned for objects right
-- next to the anchor false-flags everything further away as
-- "mispositioned" even when registration is working fine. These are only
-- ever the *fallback* anyway — see `domain::Setting` / the "Settings"
-- TODO — an admin can (and, per a board's actual size/anchor placement,
-- usually should) tune tighter or looser from the detection-log view
-- without a redeploy.
local DEFAULT_THRESHOLDS = {
    position = 8.0,
    rotation = 30.0,
}

-- Deliberately duplicated from `registration.lua` rather than shared via
-- a `require` — each script is loaded standalone (by whatever embeds it,
-- native or Lua VM, on whatever platform) with no shared module path to
-- resolve one against, and this is small/stable enough (mirrors
-- `ReferenceObject`'s own shape 1:1) that drift risk is low. If it ever
-- needs to change, change it in both files.
local function flatten(objects, origin_x, origin_y, out)
    origin_x = origin_x or 0.0
    origin_y = origin_y or 0.0
    for _, o in ipairs(objects) do
        local x = origin_x + o.boundary.x
        local y = origin_y + o.boundary.y
        table.insert(out, {
            id = o.id,
            yolo_class = o.yolo_class,
            x = x,
            y = y,
            width = o.boundary.width,
            height = o.boundary.height,
            rotation = o.rotation or 0.0,
            is_anchor = o.is_anchor,
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

-- A rectangle looks identical rotated by 180°, so only the *minimal*
-- difference within that period is meaningful — e.g. an object expected
-- at 5° and detected at 183° is really only 2° off, not 178°.
local function angle_diff_mod_180(a, b)
    local diff = (a - b) % 180.0
    if diff > 90.0 then
        diff = 180.0 - diff
    end
    return diff
end

-- Nearest same-class detection to this expected object's center. Greedy
-- and allows the same detection to be claimed by more than one expected
-- object — acceptable for now (mirrors `match_anchors`'s own "for now"
-- simplifications) since the interesting failure modes this is meant to
-- catch (a part missing, or present but out of place) don't hinge on
-- resolving that kind of ambiguity.
local function nearest_match(o, detections)
    local ex, ey = center(o)
    local best, best_dist = nil, math.huge
    for _, d in ipairs(detections) do
        if d.label == o.yolo_class then
            local dx, dy = center(d)
            local dist = distance(ex, ey, dx, dy)
            if dist < best_dist then
                best, best_dist = d, dist
            end
        end
    end
    return best, best_dist
end

-- Nearest detection of *any* class — only consulted once `nearest_match`
-- above has already come up empty, to tell "nothing detected here at
-- all" (missing) apart from "something IS here, just the wrong class"
-- (mismatched).
local function nearest_any_match(o, detections)
    local ex, ey = center(o)
    local best, best_dist = nil, math.huge
    for _, d in ipairs(detections) do
        local dx, dy = center(d)
        local dist = distance(ex, ey, dx, dy)
        if dist < best_dist then
            best, best_dist = d, dist
        end
    end
    return best, best_dist
end

-- Returns the per-object validation result and, when a detection was
-- consulted to produce it (matched/mispositioned/misrotated/mismatched
-- — every case but "missing"), that detection's own `_idx` (tagged on
-- by `validation` below) so the caller can work out which detections
-- never explained *any* expected object at all.
local function validate_object(o, detections, thresholds)
    local detected, delta_position = nearest_match(o, detections)
    if not detected then
        local wrong_class, wrong_dist = nearest_any_match(o, detections)
        if wrong_class and wrong_dist <= thresholds.position then
            return {
                id = o.id,
                yolo_class = o.yolo_class,
                ocr_value = o.ocr_value,
                is_anchor = o.is_anchor,
                status = "mismatched",
                matched_label = wrong_class.label,
                matched_confidence = wrong_class.confidence,
                delta_position = wrong_dist,
            }, wrong_class._idx
        end
        return {
            id = o.id,
            yolo_class = o.yolo_class,
            ocr_value = o.ocr_value,
            is_anchor = o.is_anchor,
            status = "missing",
        }, nil
    end

    local position_ok = delta_position <= thresholds.position

    -- Only meaningful when *both* sides actually carry an orientation:
    -- the expected object's `rotation` is always defined (defaults to
    -- `0.0`), but a registered detection's is `nil` unless its original
    -- detection reported a real quad (see `registration.lua`'s
    -- `register_detection`) — treated as "can't judge, don't penalize"
    -- rather than as a mismatch.
    local delta_rotation = nil
    local rotation_ok = true
    if detected.rotation ~= nil and type(detected.rotation) == "number" then
        delta_rotation = angle_diff_mod_180(detected.rotation, o.rotation or 0.0)
        rotation_ok = delta_rotation <= thresholds.rotation
    end

    local status
    if position_ok and rotation_ok then
        status = "matched"
    elseif not position_ok and not rotation_ok then
        status = "mispositioned_misrotated"
    elseif not position_ok then
        status = "mispositioned"
    else
        status = "misrotated"
    end

    return {
        id = o.id,
        yolo_class = o.yolo_class,
        ocr_value = o.ocr_value,
        is_anchor = o.is_anchor,
        status = status,
        matched_label = detected.label,
        matched_confidence = detected.confidence,
        delta_position = delta_position,
        delta_rotation = delta_rotation,
    }, detected._idx
end

local function validation(input)
    local thresholds = { position = DEFAULT_THRESHOLDS.position, rotation = DEFAULT_THRESHOLDS.rotation }
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

    -- Tag each detection with a stable index so `validate_object`'s own
    -- claimed-detection index can be checked off below — a plain
    -- identity/reference check would work too, but an explicit `_idx`
    -- (stripped back out before returning, since it's an internal
    -- bookkeeping detail) is simplest given detections round-trip
    -- through a marshaled Lua table, not the original one.
    local detections = {}
    for i, d in ipairs(input.registered_detections or {}) do
        local tagged = { _idx = i }
        for k, v in pairs(d) do
            tagged[k] = v
        end
        table.insert(detections, tagged)
    end

    local claimed = {}
    local objects = {}
    local matched = 0
    for _, o in ipairs(expected_flat) do
        local result, used_idx = validate_object(o, detections, thresholds)
        table.insert(objects, result)
        if used_idx then
            claimed[used_idx] = true
        end
        if result.status == "matched" then
            matched = matched + 1
        end
    end

    local extra_detections = {}
    for _, d in ipairs(detections) do
        if not claimed[d._idx] then
            table.insert(extra_detections, {
                label = d.label,
                confidence = d.confidence,
                x = d.x,
                y = d.y,
                width = d.width,
                height = d.height,
                rotation = d.rotation,
            })
        end
    end

    local total = #expected_flat
    return {
        objects = objects,
        extra_detections = extra_detections,
        score = total > 0 and (matched / total) or 0.0,
        matched = matched,
        total = total,
        extra = #extra_detections,
    }
end

return validation
