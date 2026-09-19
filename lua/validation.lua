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

-- Spatial text match — same `matcher.lua` Presence uses (expected inside found).
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
    -- Text-only placement with no hydrated needles: the object name is
    -- the expected string (overlay / verdict both show it).
    if #(yolo_classes_for(o)) == 0 and non_empty(o.name) then
        return { trim(o.name) }
    end
    return {}
end

local function label_in_classes(detection, classes)
    if type(class_match) == "table" and type(class_match.in_expected) == "function" then
        local d = detection
        if type(detection) ~= "table" then
            d = { label = detection }
        end
        return class_match.in_expected(d, classes)
    end
    local label = type(detection) == "table" and detection.label or detection
    for _, class in ipairs(classes) do
        local exp = type(class) == "table" and class.label or class
        if label == exp then
            return true
        end
    end
    return false
end

local function label_matches_object(detection, o)
    local classes = (type(class_match) == "table" and class_match.expected_list(o))
        or (o.yolo_classes or {})
    if label_in_classes(detection, classes) then
        return true
    end
    local label = type(detection) == "table" and detection.label or detection
    -- Text-only Spatial placements have no YOLO class — match OCR needles
    -- the same way Presence does (overlay "TEXT" vs expected "TEXT A").
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
            yolo_class_refs = o.yolo_class_refs,
            vision_model_id = o.vision_model_id,
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

-- A rectangle looks identical rotated by 180°, so only the *minimal*
-- difference within that period is meaningful — e.g. an object expected
-- at 5° and detected at 183° is really only 2° off, not 178°.
--
-- Generalised for per-object `symmetry` (wire / DB values):
--   "0"   — fully symmetrical: any orientation accepted (delta 0)
--   "60"  — hexagonal (period 60°)
--   "90"  — square (period 90°)
--   "120" — triangular (period 120°)
--   "180" — rectangular (period 180°)
--   "inf" — no symmetry: full-circle compare (period 360° → delta in [0, 180])
-- Missing / unknown → "inf" (product default).
local function angle_diff_with_symmetry(a, b, symmetry)
    local sym = tostring(symmetry or "inf")
    if sym == "0" then
        return 0.0
    end
    local period
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

-- Nearest same-class (or same-text) detection to this expected object's
-- center among detections not yet claimed by another expected object.
local function nearest_match(o, detections, claimed)
    local ex, ey = center(o)
    local best, best_dist = nil, math.huge
    for _, d in ipairs(detections) do
        if not claimed[d._idx] and label_matches_object(d, o) then
            local dx, dy = center(d)
            local dist = distance(ex, ey, dx, dy)
            if dist < best_dist then
                best, best_dist = d, dist
            end
        end
    end
    return best, best_dist
end

-- Nearest unclaimed detection of *any* class — only after same-class
-- matching has finished, to tell "nothing here" (missing) apart from
-- "something unclaimed IS here, wrong class" (mismatched).
--
-- Must ignore detections already claimed as another object's match:
-- otherwise a neighbor capacitor that correctly matched `capacitor3`
-- also makes a removed `capacitor4` read as "incorrect · wrong type".
-- OCR leftovers on a YOLO slot are not class-confusion — they belong
-- to a text placement (or unused overlay text).
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

-- Same-class outcome (matched / mispositioned / misrotated / …).
-- Returns nil, nil when no same-class detection remains unclaimed.
local function validate_same_class(o, detections, thresholds, claimed)
    local detected, delta_position = nearest_match(o, detections, claimed)
    if not detected then
        return nil, nil
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
        delta_rotation = angle_diff_with_symmetry(
            detected.rotation,
            o.rotation or 0.0,
            o.symmetry
        )
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
        yolo_classes = o.yolo_classes,
        ocr_values = o.ocr_values,
        is_anchor = o.is_anchor,
        status = status,
        matched_label = detected.label,
        matched_confidence = detected.confidence,
        delta_position = delta_position,
        delta_rotation = delta_rotation,
        matched_x = detected.x,
        matched_y = detected.y,
        matched_width = detected.width,
        matched_height = detected.height,
    }, detected._idx
end

local function mismatched_or_missing(o, detections, thresholds, claimed, expected_flat)
    local wrong_class, wrong_dist = nearest_any_match(o, detections, claimed, expected_flat)
    if wrong_class and wrong_dist <= thresholds.position then
        return {
            id = o.id,
            yolo_classes = o.yolo_classes,
            ocr_values = o.ocr_values,
            is_anchor = o.is_anchor,
            status = "mismatched",
            matched_label = wrong_class.label,
            matched_confidence = wrong_class.confidence,
            delta_position = wrong_dist,
            matched_x = wrong_class.x,
            matched_y = wrong_class.y,
            matched_width = wrong_class.width,
            matched_height = wrong_class.height,
        }, wrong_class._idx
    end
    return {
        id = o.id,
        yolo_classes = yolo_classes_for(o),
        ocr_values = o.ocr_values,
        is_anchor = o.is_anchor,
        status = "missing",
    }, nil
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

    -- Tag each detection with a stable index so claimed-detection index
    -- can be checked off below — a plain identity/reference check would
    -- work too, but an explicit `_idx` (internal bookkeeping) is simplest
    -- given detections round-trip through a marshaled Lua table.
    local detections = {}
    for i, d in ipairs(input.registered_detections or {}) do
        local tagged = { _idx = i }
        for k, v in pairs(d) do
            tagged[k] = v
        end
        table.insert(detections, tagged)
    end

    -- Two passes:
    --   1) Claim same-class matches (so neighbors don't steal each other).
    --   2) Only then decide mismatched vs missing from *unclaimed* boxes.
    -- A removed part next to a correctly matched sibling must be "missing",
    -- not "incorrect · wrong type" via the sibling's detection.
    local claimed = {}
    local objects = {}
    local pending = {} -- indices into `objects` still needing pass 2
    local matched = 0

    for _, o in ipairs(expected_flat) do
        local result, used_idx = validate_same_class(o, detections, thresholds, claimed)
        if result then
            table.insert(objects, result)
            if used_idx then
                claimed[used_idx] = true
            end
            if result.status == "matched" then
                matched = matched + 1
            end
        else
            table.insert(objects, false) -- placeholder
            table.insert(pending, { index = #objects, object = o })
        end
    end

    for _, p in ipairs(pending) do
        local result, used_idx = mismatched_or_missing(
            p.object,
            detections,
            thresholds,
            claimed,
            expected_flat
        )
        objects[p.index] = result
        if used_idx then
            claimed[used_idx] = true
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
