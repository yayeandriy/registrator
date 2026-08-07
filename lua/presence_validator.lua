-- Presence / content validator (no spatial registration).
--
-- Where `validation.lua` checks registered board-space detections for
-- position + rotation against every expected object, this script answers a
-- simpler question for the Constructor "Validation" pipeline step (and any
-- host that only cares whether expected content showed up at all):
--
--   given a profile tree + a flat set of YOLO/OCR detections, is each
--   presence / OCR expectation accounted for?
--
-- Who participates (aligned with Constructor Presence rail):
--   - `presence == true`, or
--   - non-empty `ocr_values` (text-only parts may seed OCR with Presence Off)
--
-- Matching rules (modalities are independent — never cross-fallback):
--   - OCR: non-empty `ocr_values` → loose search inside OCR detection labels
--     (case-insensitive; whitespace + punctuation stripped; either side may
--     contain the other when the shorter token is ≥3 chars). Digit-only
--     needles (e.g. year "2020") also match when several short OCR fragments
--     inside the gate concatenate (left-to-right) to contain the needle —
--     Vision often splits arched stamp digits. **Every** expected string is
--     required (AND): one OCR result row per needle.
--   - YOLO: `presence == true`, non-empty `yolo_classes`, **and** a
--     `vision_model_id` → exact `label` match on a non-OCR detection.
--     An object needs a full **instance** (one box per listed class, clustered
--     by proximity). Objects that share the same class set compete for
--     instances; assignment prefers the instance whose interior OCR best
--     matches that object's texts (unique needles outweigh shared ones like
--     a common year). Slug-only legacy class with YOLO model None is ignored.
--   - When both OCR and a real YOLO expectation apply, **both** checks run
--     and produce YOLO + per-needle OCR rows (e.g. stamp = class + texts).
--     OCR hits must also lie **inside** the object's assigned instance union
--     (OCR detection center). No instance → YOLO + OCR missing. Text-only
--     objects (no YOLO expectation) skip the spatial gate.
--
-- Extras (YOLO-only):
--   - Unclaimed YOLO boxes, only if at least one YOLO check ran.
--   - Unused OCR is never EXTRA (hosts filter to expected needles; noise
--     must not flood Matched/Mistakes).
--
-- Toggleable module — catalog-anchored extras (`opts.anchor_extras`):
--   Off by default; zero behavior change for any existing caller. When a
--   host also passes `catalog` (every project component, not just the
--   active profile — same shape as an expected object's class/OCR fields)
--   and sets `opts.anchor_extras = true`, unclaimed YOLO boxes are
--   clustered into full-class-set instances per catalog signature (same
--   proximity clustering `build_class_instances` uses for competing
--   profile objects — "anchor a class by the other detections around it
--   in the same frame") and named from the catalog via interior OCR:
--     - A signature with exactly one catalog component is unambiguous —
--       named without needing OCR at all.
--     - A signature shared by several components (e.g. two stamps that
--       only differ by printed code) requires OCR to disambiguate, same
--       unique-vs-shared-needle rule as competing profile objects. No
--       OCR yet → still emitted (never silently dropped — see UI
--       constitution) with `matched_label = nil`; `presence_latch.lua`
--       keeps the sticky name once OCR confirms it even if a later tick's
--       OCR briefly misses again.
--   Boxes that do not belong to any catalog signature at all still come
--   back as plain unclaimed rows (unchanged from the always-on behavior).
--
-- Input (a single Lua table):
--   {
--     expected = { ReferenceObject... },
--     detections = {
--       { label, confidence, x, y, width, height, kind = "yolo"|"ocr"|... },
--       ...
--     },
--     catalog = { { id, name, yolo_classes, ocr_values }, ... },  -- optional
--     opts = { anchor_extras = true },                            -- optional
--   }
-- Detection `x/y/width/height` are used for the OCR-in-YOLO spatial gate.
--
-- Output (same envelope shape as `validation.lua` so hosts can reuse UI):
--   {
--     objects = { ... status matched|missing, match_kind yolo|ocr ... },
--     extra_detections = { ... unused YOLO and/or unused OCR ... },
--     score, matched, total, extra,
--   }

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_alnum(s)
    if type(s) ~= "string" then
        return ""
    end
    local t = trim(s):lower()
    t = t:gsub("%s+", "")
    t = t:gsub("[^%w]", "")
    return t
end

local function non_empty(s)
    return type(s) == "string" and trim(s) ~= ""
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
    -- Legacy singular field (safety during rollout).
    if non_empty(o.ocr_value) then
        return { trim(o.ocr_value) }
    end
    return {}
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
    -- Legacy singular field (safety during rollout).
    if non_empty(o.yolo_class) then
        return { trim(o.yolo_class) }
    end
    return {}
end

local function flatten(objects, out)
    for _, o in ipairs(objects or {}) do
        table.insert(out, {
            id = o.id,
            yolo_classes = yolo_classes_for(o),
            ocr_values = ocr_values_for(o),
            presence = o.presence == true,
            is_anchor = o.is_anchor == true,
            vision_model_id = o.vision_model_id,
        })
        if o.children then
            flatten(o.children, out)
        end
    end
    return out
end

-- True when the object is bound to a YOLO model (Constructor "YOLO model"
-- is not None). Uuid arrives as a string via the JSON/mlua boundary.
local function has_vision_model(o)
    local v = o.vision_model_id
    if v == nil then
        return false
    end
    if type(v) == "string" then
        return trim(v) ~= ""
    end
    return true
end

local function is_ocr_detection(d)
    local k = d.kind
    if type(k) ~= "string" then
        return false
    end
    k = k:lower()
    -- Server Gemma tags crops as `ocr:<class_group>`; treat those as OCR too.
    return k == "ocr" or k:sub(1, 4) == "ocr:"
end

-- True when `needle` is accounted for by `hay` (either direction).
-- Reverse direction requires the detection fragment to be at least 3
-- chars so a short OCR blip cannot satisfy a long expected string.
local function ocr_text_match(hay, needle)
    local h = normalize_alnum(hay)
    local n = normalize_alnum(needle)
    if h == "" or n == "" then
        return false
    end
    if h:find(n, 1, true) then
        return true
    end
    if #h >= 3 and n:find(h, 1, true) then
        return true
    end
    local hd = h:gsub("%D", "")
    local nd = n:gsub("%D", "")
    if hd ~= "" and nd ~= "" then
        if hd:find(nd, 1, true) then
            return true
        end
        if #hd >= 3 and nd:find(hd, 1, true) then
            return true
        end
    end
    return false
end

local function find_yolo(detections, class, claimed)
    for _, d in ipairs(detections) do
        if not claimed[d._idx] and not is_ocr_detection(d) and d.label == class then
            return d
        end
    end
    return nil
end

local function detection_center(d)
    local x = tonumber(d.x) or 0
    local y = tonumber(d.y) or 0
    local w = tonumber(d.width) or 0
    local h = tonumber(d.height) or 0
    return x + w * 0.5, y + h * 0.5
end

-- Axis-aligned union of detection boxes (for multi-class YOLO regions).
local function union_aabb(boxes)
    local u = nil
    for _, d in ipairs(boxes) do
        local x = tonumber(d.x) or 0
        local y = tonumber(d.y) or 0
        local w = tonumber(d.width) or 0
        local h = tonumber(d.height) or 0
        local x2, y2 = x + w, y + h
        if not u then
            u = { x1 = x, y1 = y, x2 = x2, y2 = y2 }
        else
            if x < u.x1 then u.x1 = x end
            if y < u.y1 then u.y1 = y end
            if x2 > u.x2 then u.x2 = x2 end
            if y2 > u.y2 then u.y2 = y2 end
        end
    end
    return u
end

local function center_inside_aabb(aabb, d)
    if aabb == nil then
        return true
    end
    local cx, cy = detection_center(d)
    return cx >= aabb.x1 and cx <= aabb.x2 and cy >= aabb.y1 and cy <= aabb.y2
end

local function aabb_center(aabb)
    if not aabb then
        return 0, 0
    end
    return (aabb.x1 + aabb.x2) * 0.5, (aabb.y1 + aabb.y2) * 0.5
end

-- OCR must sit inside the object's YOLO instance (center-in-AABB) with a small
-- pad so rim text still counts — not large enough to pull in frame-wide noise.
local OCR_GATE_PAD = 0.2
local OCR_GATE_PAD_MIN = 0.025

local function pad_aabb(aabb, ratio, min_pad)
    if not aabb then
        return nil
    end
    local w = aabb.x2 - aabb.x1
    local h = aabb.y2 - aabb.y1
    local floor = min_pad or OCR_GATE_PAD_MIN
    local px = math.max(w * ratio, floor)
    local py = math.max(h * ratio, floor)
    return {
        x1 = aabb.x1 - px,
        y1 = aabb.y1 - py,
        x2 = aabb.x2 + px,
        y2 = aabb.y2 + py,
    }
end

-- Claim a full class set from still-unclaimed detections (solo objects).
local function collect_yolo_boxes(detections, classes, claimed)
    -- Preview without claiming — need every class.
    local boxes = {}
    local preview_claimed = {}
    for k, v in pairs(claimed) do
        preview_claimed[k] = v
    end
    for _, class in ipairs(classes) do
        local hit = find_yolo(detections, class, preview_claimed)
        if not hit then
            return {}
        end
        table.insert(boxes, hit)
        preview_claimed[hit._idx] = true
    end
    for _, b in ipairs(boxes) do
        claimed[b._idx] = true
    end
    return boxes
end

local function class_signature(classes)
    local copy = {}
    for _, c in ipairs(classes) do
        table.insert(copy, c)
    end
    table.sort(copy)
    return table.concat(copy, "\0")
end

local function box_center_dist(a, b)
    local ax, ay = detection_center(a)
    local bx, by = detection_center(b)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- Cluster unclaimed YOLO boxes into full class-set instances (proximity).
-- Two-class stamps use global nearest-pair matching so adjacent stamps do not
-- cross-wire (lower of A + upper of B).
local function build_class_instances(detections, classes, claimed)
    if #classes == 0 then
        return {}
    end
    local by_class = {}
    for _, class in ipairs(classes) do
        by_class[class] = {}
        for _, d in ipairs(detections) do
            if not claimed[d._idx] and not is_ocr_detection(d) and d.label == class then
                table.insert(by_class[class], d)
            end
        end
    end

    local instances = {}
    local used = {}

    if #classes == 1 then
        for _, d in ipairs(by_class[classes[1]] or {}) do
            table.insert(instances, { boxes = { d } })
        end
        return instances
    end

    if #classes == 2 then
        local a_list = by_class[classes[1]] or {}
        local b_list = by_class[classes[2]] or {}
        local pairs = {}
        for _, a in ipairs(a_list) do
            local aw = math.max(tonumber(a.width) or 0.05, 0.01)
            local ah = math.max(tonumber(a.height) or 0.05, 0.01)
            for _, b in ipairs(b_list) do
                local bw = math.max(tonumber(b.width) or 0.05, 0.01)
                local bh = math.max(tonumber(b.height) or 0.05, 0.01)
                local limit = math.max(aw, ah, bw, bh) * 5.0
                local dist = box_center_dist(a, b)
                if dist <= limit then
                    table.insert(pairs, { a = a, b = b, dist = dist })
                end
            end
        end
        table.sort(pairs, function(p, q)
            return p.dist < q.dist
        end)
        for _, p in ipairs(pairs) do
            if not used[p.a._idx] and not used[p.b._idx] then
                used[p.a._idx] = true
                used[p.b._idx] = true
                table.insert(instances, { boxes = { p.a, p.b } })
            end
        end
        return instances
    end

    local seed_class = classes[1]
    for _, seed in ipairs(by_class[seed_class] or {}) do
        if not used[seed._idx] then
            local boxes = { seed }
            local sw = math.max(tonumber(seed.width) or 0.05, 0.01)
            local sh = math.max(tonumber(seed.height) or 0.05, 0.01)
            local limit = math.max(sw, sh) * 5.0
            local complete = true
            for i = 2, #classes do
                local class = classes[i]
                local best, best_d = nil, math.huge
                for _, d in ipairs(by_class[class] or {}) do
                    if not used[d._idx] then
                        local dist = box_center_dist(seed, d)
                        if dist < best_d and dist <= limit then
                            best, best_d = d, dist
                        end
                    end
                end
                if best then
                    table.insert(boxes, best)
                else
                    complete = false
                    break
                end
            end
            if complete and #boxes == #classes then
                for _, b in ipairs(boxes) do
                    used[b._idx] = true
                end
                table.insert(instances, { boxes = boxes })
            end
        end
    end
    return instances
end

local function digits_only(s)
    return (normalize_alnum(s)):gsub("%D", "")
end

-- Claim helpers: `find_ocr` returns `hit, claim_idxs` (multi when digits assembled).
local function claim_ocr_hits(claimed_ocr, hit, claim_idxs)
    if not claimed_ocr or not hit then
        return
    end
    if claim_idxs then
        for _, idx in ipairs(claim_idxs) do
            claimed_ocr[idx] = true
        end
    else
        claimed_ocr[hit._idx] = true
    end
end

-- Digit-only needle: concatenate short OCR fragments in the gate (x then y).
-- Returns hit (first fragment), claim_idxs when the concat contains the needle.
local function find_ocr_digit_assembly(ocr_detections, needle, region, claimed_ocr)
    local n = normalize_alnum(needle)
    local nd = digits_only(needle)
    if nd == "" or n ~= nd or #nd < 3 then
        return nil, nil
    end
    local parts = {}
    for _, d in ipairs(ocr_detections) do
        if not (claimed_ocr and claimed_ocr[d._idx]) and center_inside_aabb(region, d) then
            local h = normalize_alnum(d.label)
            local hd = h:gsub("%D", "")
            -- Pure digit fragments only — codes like "P06" must not interleave.
            if hd ~= "" and h == hd then
                local cx, cy = detection_center(d)
                table.insert(parts, { d = d, x = cx, y = cy, digits = hd })
            end
        end
    end
    if #parts == 0 then
        return nil, nil
    end
    table.sort(parts, function(a, b)
        if a.x ~= b.x then
            return a.x < b.x
        end
        return a.y < b.y
    end)
    local concat = ""
    for _, p in ipairs(parts) do
        concat = concat .. p.digits
    end
    local start_i, end_i = concat:find(nd, 1, true)
    if not start_i then
        return nil, nil
    end
    local pos = 1
    local claim_idxs = {}
    local hit = nil
    for _, p in ipairs(parts) do
        local plen = #p.digits
        local p_end = pos + plen - 1
        if p_end >= start_i and pos <= end_i then
            table.insert(claim_idxs, p.d._idx)
            if not hit then
                hit = p.d
            end
        end
        pos = pos + plen
    end
    if not hit then
        return nil, nil
    end
    -- Surface the expected year on the row, not a lone fragment label.
    hit = {
        _idx = hit._idx,
        label = needle,
        confidence = hit.confidence,
        x = hit.x,
        y = hit.y,
        width = hit.width,
        height = hit.height,
        kind = hit.kind,
    }
    return hit, claim_idxs
end

-- Prefer the OCR hit nearest the instance center; honor exclusive claims.
-- Returns `hit, claim_idxs` (claim_idxs nil → claim hit._idx only).
local function find_ocr(ocr_detections, needle, region, claimed_ocr, anchor_x, anchor_y)
    if normalize_alnum(needle) == "" then
        return nil, nil
    end
    local ax = anchor_x
    local ay = anchor_y
    if ax == nil or ay == nil then
        ax, ay = aabb_center(region)
    end
    local best, best_d = nil, math.huge
    for _, d in ipairs(ocr_detections) do
        if
            not (claimed_ocr and claimed_ocr[d._idx])
            and ocr_text_match(d.label, needle)
            and center_inside_aabb(region, d)
        then
            local cx, cy = detection_center(d)
            local dx, dy = cx - ax, cy - ay
            local dist = dx * dx + dy * dy
            if dist < best_d then
                best, best_d = d, dist
            end
        end
    end
    if best then
        return best, { best._idx }
    end
    return find_ocr_digit_assembly(ocr_detections, needle, region, claimed_ocr)
end

-- How many objects in `group` list this needle (shared vs unique text).
local function needle_owners(group, needle)
    local n = 0
    local key = normalize_alnum(needle)
    if key == "" then
        return 0
    end
    for _, o in ipairs(group) do
        for _, v in ipairs(o.ocr_values or {}) do
            if normalize_alnum(v) == key then
                n = n + 1
                break
            end
        end
    end
    return n
end

local function score_instance_for_object(object, instance, ocr_detections, group)
    local region = pad_aabb(union_aabb(instance.boxes), OCR_GATE_PAD)
    if not region then
        return 0
    end
    local ax, ay = aabb_center(region)
    local score = 0
    local required = 0
    local found = 0
    local unique_hit = false
    for _, needle in ipairs(object.ocr_values or {}) do
        if normalize_alnum(needle) ~= "" then
            required = required + 1
            if find_ocr(ocr_detections, needle, region, nil, ax, ay) then
                found = found + 1
                if needle_owners(group, needle) == 1 then
                    unique_hit = true
                    score = score + 10
                else
                    score = score + 1
                end
            end
        end
    end
    -- Shared text alone (e.g. year "2020") must not claim a sibling object.
    -- Assign only when every needle hits, or at least one object-unique needle.
    if required > 0 and found < required and not unique_hit then
        return 0
    end
    return score
end

-- Assign each competing object at most one instance (best OCR fit wins).
local function assign_instances(group, instances, ocr_detections)
    local pairs = {}
    for oi, object in ipairs(group) do
        for ii, instance in ipairs(instances) do
            local score = score_instance_for_object(object, instance, ocr_detections, group)
            -- Objects with OCR need a positive score; class-only objects accept 0.
            local has_ocr = #(object.ocr_values or {}) > 0
            if (not has_ocr) or score > 0 then
                table.insert(pairs, {
                    oi = oi,
                    ii = ii,
                    score = score,
                    object = object,
                    instance = instance,
                })
            end
        end
    end
    table.sort(pairs, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.oi < b.oi
    end)
    local used_obj = {}
    local used_inst = {}
    local assigned = {}
    for _, p in ipairs(pairs) do
        if not used_obj[p.oi] and not used_inst[p.ii] then
            used_obj[p.oi] = true
            used_inst[p.ii] = true
            assigned[p.object.id] = p.instance
        end
    end
    return assigned
end

local function copy_detection(d)
    return {
        label = d.label,
        confidence = d.confidence,
        x = d.x,
        y = d.y,
        width = d.width,
        height = d.height,
        kind = d.kind,
    }
end

local function push_result(objects, o, status, matched_label, matched_confidence, match_kind, ocr_needle)
    -- For dual-modality rows, expose only the field that this row asserts
    -- so the UI label matches the check (YOLO class vs OCR text). OCR AND
    -- emits one row per needle — stamp that single string on the row.
    local yolo_classes = o.yolo_classes
    local ocr_values = o.ocr_values
    if match_kind == "yolo" then
        ocr_values = nil
    elseif match_kind == "ocr" then
        yolo_classes = nil
        if ocr_needle ~= nil then
            ocr_values = { ocr_needle }
        end
    end
    table.insert(objects, {
        id = o.id,
        yolo_classes = yolo_classes,
        ocr_values = ocr_values,
        is_anchor = o.is_anchor,
        presence = o.presence,
        status = status,
        matched_label = matched_label,
        matched_confidence = matched_confidence,
        match_kind = match_kind,
    })
end

local function ocr_gate_region(yolo_boxes)
    if #yolo_boxes == 0 then
        return { x1 = 0, y1 = 0, x2 = -1, y2 = -1 }
    end
    return pad_aabb(union_aabb(yolo_boxes), OCR_GATE_PAD)
end

-- Solo / text-only emit. Optional `claimed_ocr` shares exclusivity with siblings.
local function emit_object_results(
    objects,
    matched_count,
    o,
    yolo_boxes,
    ocr_detections,
    expect_yolo_flag,
    expect_ocr_flag,
    claimed_ocr
)
    local matched = matched_count
    local expect_yolo = expect_yolo_flag
    local expect_ocr = expect_ocr_flag
    local ocr_claimed = claimed_ocr or {}
    local ocr_values = o.ocr_values or {}
    local has_ocr = #ocr_values > 0
    local has_yolo = #(o.yolo_classes or {}) > 0 and has_vision_model(o)

    if o.presence and has_yolo then
        expect_yolo = true
        if #yolo_boxes > 0 then
            local hit = yolo_boxes[1]
            push_result(objects, o, "matched", hit.label, hit.confidence, "yolo", nil)
            matched = matched + 1
        else
            push_result(objects, o, "missing", nil, nil, "yolo", nil)
        end
    end

    local ocr_region = nil
    if o.presence and has_yolo then
        ocr_region = ocr_gate_region(yolo_boxes)
    end

    if has_ocr then
        expect_ocr = true
        local ax, ay = aabb_center(ocr_region)
        for _, needle in ipairs(ocr_values) do
            if normalize_alnum(needle) ~= "" then
                local hit, claim_idxs =
                    find_ocr(ocr_detections, needle, ocr_region, ocr_claimed, ax, ay)
                if hit then
                    claim_ocr_hits(ocr_claimed, hit, claim_idxs)
                    push_result(objects, o, "matched", hit.label, hit.confidence, "ocr", needle)
                    matched = matched + 1
                else
                    push_result(objects, o, "missing", nil, nil, "ocr", needle)
                end
            end
        end
    end
    return matched, expect_yolo, expect_ocr
end

-- Competing same-class objects: unique OCR first, then shared needles by
-- nearest instance. OCR stays gated to each instance's YOLO pad (no growth).
local function emit_competing_group(
    objects,
    matched_count,
    group,
    assigned,
    ocr_detections,
    expect_yolo_flag,
    expect_ocr_flag,
    claimed_yolo
)
    local matched = matched_count
    local expect_yolo = expect_yolo_flag
    local expect_ocr = expect_ocr_flag
    local claimed_ocr = {}
    local states = {}

    for _, o in ipairs(group) do
        local instance = assigned[o.id]
        local yolo_boxes = {}
        if instance then
            yolo_boxes = instance.boxes
            for _, b in ipairs(yolo_boxes) do
                claimed_yolo[b._idx] = true
            end
        end
        local has_yolo = #(o.yolo_classes or {}) > 0 and has_vision_model(o)
        if o.presence and has_yolo then
            expect_yolo = true
            if #yolo_boxes > 0 then
                local hit = yolo_boxes[1]
                push_result(objects, o, "matched", hit.label, hit.confidence, "yolo", nil)
                matched = matched + 1
            else
                push_result(objects, o, "missing", nil, nil, "yolo", nil)
            end
        end
        local region = nil
        if o.presence and has_yolo then
            region = ocr_gate_region(yolo_boxes)
        end
        table.insert(states, {
            o = o,
            region = region,
            pending_shared = {},
        })
    end

    -- Pass 1: object-unique needles (P06 / X04) — claim + expand region.
    for _, st in ipairs(states) do
        local o = st.o
        local ax, ay = aabb_center(st.region)
        for _, needle in ipairs(o.ocr_values or {}) do
            if normalize_alnum(needle) ~= "" then
                expect_ocr = true
                if needle_owners(group, needle) == 1 then
                    local hit, claim_idxs =
                        find_ocr(ocr_detections, needle, st.region, claimed_ocr, ax, ay)
                    if hit then
                        claim_ocr_hits(claimed_ocr, hit, claim_idxs)
                        push_result(objects, o, "matched", hit.label, hit.confidence, "ocr", needle)
                        matched = matched + 1
                    else
                        push_result(objects, o, "missing", nil, nil, "ocr", needle)
                    end
                else
                    table.insert(st.pending_shared, needle)
                end
            end
        end
    end

    -- Pass 2: shared needles (incl. digit assembly for arched "2020").
    local filled = {}
    local progress = true
    while progress do
        progress = false
        local best = nil
        for si, st in ipairs(states) do
            local ax, ay = aabb_center(st.region)
            for _, needle in ipairs(st.pending_shared) do
                local key = si .. "\0" .. normalize_alnum(needle)
                if not filled[key] then
                    local hit, claim_idxs =
                        find_ocr(ocr_detections, needle, st.region, claimed_ocr, ax, ay)
                    if hit then
                        local cx, cy = detection_center(hit)
                        local dx, dy = cx - ax, cy - ay
                        local dist = dx * dx + dy * dy
                        if not best or dist < best.dist then
                            best = {
                                key = key,
                                si = si,
                                needle = needle,
                                hit = hit,
                                claim_idxs = claim_idxs,
                                dist = dist,
                            }
                        end
                    end
                end
            end
        end
        if best then
            progress = true
            filled[best.key] = true
            claim_ocr_hits(claimed_ocr, best.hit, best.claim_idxs)
            local st = states[best.si]
            push_result(
                objects, st.o, "matched", best.hit.label, best.hit.confidence, "ocr", best.needle
            )
            matched = matched + 1
        end
    end
    for si, st in ipairs(states) do
        for _, needle in ipairs(st.pending_shared) do
            local key = si .. "\0" .. normalize_alnum(needle)
            if not filled[key] then
                push_result(objects, st.o, "missing", nil, nil, "ocr", needle)
            end
        end
    end

    return matched, expect_yolo, expect_ocr
end

-- Catalog-anchored extras — see the toggleable-module header comment.
-- Unlike `score_instance_for_object` (competing profile objects), a
-- signature owned by a single catalog component is unambiguous by
-- construction and always accepted without needing OCR.
local function score_catalog_instance(comp, instance, ocr_detections, group)
    if #group <= 1 then
        return 1
    end
    local region = pad_aabb(union_aabb(instance.boxes), OCR_GATE_PAD)
    if not region then
        return 0
    end
    local ax, ay = aabb_center(region)
    local score = 0
    local required = 0
    local found = 0
    local unique_hit = false
    for _, needle in ipairs(comp.ocr_values or {}) do
        if normalize_alnum(needle) ~= "" then
            required = required + 1
            if find_ocr(ocr_detections, needle, region, nil, ax, ay) then
                found = found + 1
                if needle_owners(group, needle) == 1 then
                    unique_hit = true
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
    if found < required and not unique_hit then
        return 0
    end
    return score
end

-- Cluster unclaimed boxes into full-instance rows per catalog class
-- signature (biggest class sets first, so a 2-class stamp is not starved
-- by a single-class catalog row grabbing one of its two boxes first),
-- then name each instance from the signature's catalog candidate(s).
-- Anything left over (no catalog signature matches its class at all)
-- passes through as a plain unclaimed row — never silently dropped.
local function build_catalog_extras(unclaimed, catalog, ocr_detections)
    local groups = {}
    local order = {}
    for _, comp in ipairs(catalog or {}) do
        local classes = comp.yolo_classes or {}
        if #classes > 0 then
            local key = class_signature(classes)
            if not groups[key] then
                groups[key] = { classes = classes, comps = {} }
                table.insert(order, key)
            end
            table.insert(groups[key].comps, comp)
        end
    end
    table.sort(order, function(a, b)
        return #groups[a].classes > #groups[b].classes
    end)

    local pool_claimed = {}
    local results = {}

    for _, key in ipairs(order) do
        local grp = groups[key]
        local instances = build_class_instances(unclaimed, grp.classes, pool_claimed)
        for _, instance in ipairs(instances) do
            for _, b in ipairs(instance.boxes) do
                pool_claimed[b._idx] = true
            end
            local best_comp, best_score = nil, 0
            for _, comp in ipairs(grp.comps) do
                local score = score_catalog_instance(comp, instance, ocr_detections, grp.comps)
                if score > best_score then
                    best_score = score
                    best_comp = comp
                end
            end
            local u = union_aabb(instance.boxes)
            local top = instance.boxes[1]
            local name = best_comp and (best_comp.name or best_comp.id) or nil
            table.insert(results, {
                label = name or top.label,
                confidence = top.confidence,
                x = u.x1,
                y = u.y1,
                width = u.x2 - u.x1,
                height = u.y2 - u.y1,
                kind = "extra",
                matched_label = name,
            })
        end
    end

    for _, d in ipairs(unclaimed) do
        if not pool_claimed[d._idx] then
            local copy = copy_detection(d)
            if not copy.kind or copy.kind == "" then
                copy.kind = "yolo"
            end
            table.insert(results, copy)
        end
    end

    return results
end

local function presence_validator(input)
    local expected_flat = flatten(input.expected or {}, {})

    local detections = {}
    local ocr_detections = {}
    for i, d in ipairs(input.detections or {}) do
        local tagged = { _idx = i }
        for k, v in pairs(d) do
            tagged[k] = v
        end
        table.insert(detections, tagged)
        if is_ocr_detection(tagged) then
            table.insert(ocr_detections, tagged)
        end
    end

    local claimed = {}
    local objects = {}
    local matched = 0
    local expect_yolo = false
    local expect_ocr = false

    -- Partition: objects that share a YOLO class set compete for instances.
    local groups = {}
    local group_order = {}
    local solos = {}
    for _, o in ipairs(expected_flat) do
        local ocr_values = o.ocr_values or {}
        local has_ocr = #ocr_values > 0
        local has_yolo = #(o.yolo_classes or {}) > 0 and has_vision_model(o)
        local on_rail = o.presence or has_ocr
        if on_rail and (has_ocr or has_yolo) then
            if o.presence and has_yolo then
                local key = class_signature(o.yolo_classes)
                if not groups[key] then
                    groups[key] = {}
                    table.insert(group_order, key)
                end
                table.insert(groups[key], o)
            else
                table.insert(solos, o)
            end
        end
    end

    -- Competing / singleton YOLO groups.
    for _, key in ipairs(group_order) do
        local group = groups[key]
        local classes = group[1].yolo_classes
        if #group == 1 then
            local o = group[1]
            local yolo_boxes = collect_yolo_boxes(detections, classes, claimed)
            matched, expect_yolo, expect_ocr = emit_object_results(
                objects, matched, o, yolo_boxes, ocr_detections, expect_yolo, expect_ocr
            )
        else
            local instances = build_class_instances(detections, classes, claimed)
            local assigned = assign_instances(group, instances, ocr_detections)
            matched, expect_yolo, expect_ocr = emit_competing_group(
                objects,
                matched,
                group,
                assigned,
                ocr_detections,
                expect_yolo,
                expect_ocr,
                claimed
            )
        end
    end

    -- Text-only (no YOLO expectation).
    for _, o in ipairs(solos) do
        matched, expect_yolo, expect_ocr = emit_object_results(
            objects, matched, o, {}, ocr_detections, expect_yolo, expect_ocr
        )
    end

    -- EXTRA is YOLO-only. Unused OCR strings have no product value as
    -- extras (hosts filter OCR to expected needles; noise must not flood
    -- Matched/Mistakes). `expect_ocr` still gates whether OCR checks ran.
    local catalog = input.catalog or {}
    local opts = input.opts or {}
    local anchor_extras = opts.anchor_extras == true and #catalog > 0

    local extra_detections = {}
    if anchor_extras then
        -- Catalog-anchored path ignores `expect_yolo` — an unexpected
        -- component may not share any class with the active profile at all.
        local unclaimed = {}
        for _, d in ipairs(detections) do
            if not is_ocr_detection(d) and not claimed[d._idx] then
                table.insert(unclaimed, d)
            end
        end
        extra_detections = build_catalog_extras(unclaimed, catalog, ocr_detections)
    elseif expect_yolo then
        for _, d in ipairs(detections) do
            if not is_ocr_detection(d) and not claimed[d._idx] then
                local copy = copy_detection(d)
                if not copy.kind or copy.kind == "" then
                    copy.kind = "yolo"
                end
                table.insert(extra_detections, copy)
            end
        end
    end
    -- Note: `expect_ocr` may be true; unused OCR detections are intentionally
    -- omitted from EXTRA (YOLO-only extras).

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

return presence_validator
