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
--   - Location-free: a part counts once each of its classes has a box and
--     each of its texts a read, wherever they lie in the frame, for any mix
--     (class + text, class + class, more than two). Where its parts sit
--     against each other matters only through a wrapper (`wrapper.lua`,
--     run before this script).
--   - OCR: non-empty `ocr_values` → `matcher.lua` (expected text inside
--     any found string after `normalisator.lua`). Digit-only needles
--     (e.g. year "2020") also match when several short OCR fragments
--     concatenate (left-to-right) to contain the needle — Vision often
--     splits arched stamp digits. **Every** expected string is required
--     (AND): one OCR result row per needle.
--   - YOLO: `presence == true`, non-empty `yolo_classes`, **and** a
--     `vision_model_id` → exact `label` match on a non-OCR detection, one
--     box per listed class. Slug-only legacy class with YOLO model None is
--     ignored.
--   - When both apply, both checks run: a YOLO row plus one OCR row per
--     needle (e.g. stamp = class + texts).
--   - Each box and each read counts for one part. Parts that lack the
--     fewest of their detections claim first, so a part whose text is in
--     the frame takes the shared-class box before one whose text is not.

-- Extras (YOLO-only):
--   - Unclaimed YOLO boxes, only if at least one YOLO check ran.
--   - Unused OCR is never EXTRA (hosts filter to expected needles; noise
--     must not flood Matched/Mistakes).
--   - `loose_match == true` (on the **profile object**):
--     leftover YOLO boxes of that object's classes are not extras
--     once at least as many presence instances are matched as are
--     placed. Surplus occurrences do not fail the object.
--     The same catalog component may be loose in one profile and
--     strict in another. Spatial validation ignores this flag.
--
-- Toggleable module — catalog-anchored extras (`opts.anchor_extras`):
--   Off by default; zero behavior change for any existing caller. When a
--   host also passes `catalog` (every project component, not just the
--   active profile — same shape as an expected object's class/OCR fields)
--   and sets `opts.anchor_extras = true`, unclaimed YOLO boxes are
--   clustered by proximity into full-class-set instances per catalog
--   signature (`catalog_instances.lua`) and named from the catalog via
--   interior OCR (`presence_catalog.lua`):
--     - A signature with exactly one catalog component is unambiguous —
--       named without needing OCR at all.
--     - A signature shared by several components (e.g. two stamps that
--       only differ by printed code) requires OCR to disambiguate, same
--       unique-vs-shared-needle rule (unique needles outweigh shared ones). No
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
--
-- Needs `class_match`, `expected`, `matcher`, `presence_ocr` and
-- `presence_catalog` (composed by `bundles.json`).

local function first_component_id(o)
    if type(o.component_ids) == "table" and o.component_ids[1] then
        return o.component_ids[1]
    end
    return o.id
end

local function flatten(objects, out)
    for _, o in ipairs(objects or {}) do
        table.insert(out, {
            id = o.id,
            name = o.name,
            component_id = first_component_id(o),
            yolo_classes = expected.yolo_classes(o),
            yolo_class_refs = o.yolo_class_refs,
            ocr_values = expected.ocr_values(o, false),
            presence = o.presence == true,
            is_anchor = o.is_anchor == true,
            loose_match = o.loose_match == true,
            vision_model_id = o.vision_model_id,
        })
        if o.children then
            flatten(o.children, out)
        end
    end
    return out
end

-- Bound to a YOLO model (Constructor "YOLO model" is not None).
local function has_vision_model(o)
    local v = o.vision_model_id
    if type(v) == "string" then
        return expected.trim(v) ~= ""
    end
    return v ~= nil
end

local function find_yolo(detections, class, claimed)
    for _, d in ipairs(detections) do
        if not claimed[d._idx] and not expected.is_ocr_kind(d.kind) and class_match.match(d, class) then
            return d
        end
    end
    return nil
end

-- Claim a full class set from still-unclaimed detections, or nothing.
local function collect_yolo_boxes(detections, classes, claimed)
    local found = {}
    local preview_claimed = {}
    for k, v in pairs(claimed) do
        preview_claimed[k] = v
    end
    for _, class in ipairs(classes) do
        local hit = find_yolo(detections, class, preview_claimed)
        if not hit then
            return {}
        end
        table.insert(found, hit)
        preview_claimed[hit._idx] = true
    end
    for _, b in ipairs(found) do
        claimed[b._idx] = true
    end
    return found
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

local function has_yolo(o)
    return #(o.yolo_classes or {}) > 0 and has_vision_model(o)
end

-- How many of `o`'s classes have no box and texts no read, with every
-- detection free. Parts closest to whole claim first.
local function lacking(o, detections, ocr_detections)
    local n = 0
    if o.presence and has_yolo(o) then
        for _, class in ipairs(class_match.expected_list(o)) do
            if not find_yolo(detections, class, {}) then
                n = n + 1
            end
        end
    end
    for _, needle in ipairs(o.ocr_values or {}) do
        if expected.normalize(needle) ~= "" and not presence_ocr.find(ocr_detections, needle, nil, nil) then
            n = n + 1
        end
    end
    return n
end

-- One part's rows: a box for every class and a read for every text, anywhere
-- in the frame and none a part before it claimed.
local function part_results(o, detections, ocr_detections, claimed, claimed_ocr)
    local rows, matched, expect_yolo, expect_ocr = {}, 0, false, false
    if o.presence and has_yolo(o) then
        expect_yolo = true
        local found = collect_yolo_boxes(detections, class_match.expected_list(o), claimed)
        if #found > 0 then
            push_result(rows, o, "matched", found[1].label, found[1].confidence, "yolo", nil)
            matched = matched + 1
        else
            push_result(rows, o, "missing", nil, nil, "yolo", nil)
        end
    end
    for _, needle in ipairs(o.ocr_values or {}) do
        if expected.normalize(needle) ~= "" then
            expect_ocr = true
            local hit, claim_idxs = presence_ocr.find(ocr_detections, needle, nil, claimed_ocr)
            if hit then
                presence_ocr.claim(claimed_ocr, hit, claim_idxs)
                push_result(rows, o, "matched", hit.read or hit.label, hit.confidence, "ocr", needle)
                matched = matched + 1
            else
                push_result(rows, o, "missing", nil, nil, "ocr", needle)
            end
        end
    end
    return rows, matched, expect_yolo, expect_ocr
end

-- One read per expected text it holds (`matcher.lua`, `detections`).
local function split_reads(dets, expected_flat)
    if type(dets) ~= "table" then
        return {}
    end
    local needles = {}
    for _, o in ipairs(expected_flat) do
        for _, v in ipairs(o.ocr_values or {}) do
            needles[#needles + 1] = v
        end
    end
    return matcher({ detections = dets, needles = needles }).detections
end

-- Loose-match is a component flag: once its matched YOLO instances reach
-- the placed count, leftover boxes of its classes (and catalog rows named
-- after it) are not extras. Returns `is_loose(detection)`.
local function loose_filter(expected_flat, objects)
    local yolo_matched = {}
    for _, row in ipairs(objects) do
        if row.status == "matched" and row.match_kind == "yolo" then
            yolo_matched[row.id] = true
        end
    end
    local expected_n, matched_n, loose_comp, classes_of, names_of = {}, {}, {}, {}, {}
    for _, o in ipairs(expected_flat) do
        if o.presence and #(o.yolo_classes or {}) > 0 then
            local cid = o.component_id or o.id
            expected_n[cid] = (expected_n[cid] or 0) + 1
            if yolo_matched[o.id] then
                matched_n[cid] = (matched_n[cid] or 0) + 1
            end
            if o.loose_match then
                loose_comp[cid] = true
            end
            classes_of[cid] = classes_of[cid] or {}
            for _, class in ipairs(class_match.expected_list(o)) do
                table.insert(classes_of[cid], class)
            end
            if expected.non_empty(o.name) then
                names_of[cid] = names_of[cid] or {}
                names_of[cid][expected.trim(o.name):lower()] = true
            end
        end
    end
    local loose_classes, loose_names = {}, {}
    for cid, _ in pairs(loose_comp) do
        if (matched_n[cid] or 0) >= (expected_n[cid] or 0) then
            for _, class in ipairs(classes_of[cid] or {}) do
                loose_classes[#loose_classes + 1] = class
            end
            for name, _ in pairs(names_of[cid] or {}) do
                loose_names[name] = true
            end
        end
    end
    return function(d)
        for _, class in ipairs(loose_classes) do
            if class_match.similar(d, class) then
                return true
            end
        end
        local named = d.matched_label or d.label
        return expected.non_empty(named) and loose_names[expected.trim(named):lower()] == true
    end
end

local function presence_validator(input)
    local expected_flat = flatten(input.expected or {}, {})

    local detections = {}
    local ocr_detections = {}
    for i, d in ipairs(split_reads(input.detections, expected_flat)) do
        local tagged = { _idx = i }
        for k, v in pairs(d) do
            tagged[k] = v
        end
        table.insert(detections, tagged)
        if expected.is_ocr_kind(tagged.kind) then
            table.insert(ocr_detections, tagged)
        end
    end

    local claimed = {}
    local objects = {}
    local matched = 0
    local expect_yolo = false

    local parts = {}
    for at, o in ipairs(expected_flat) do
        local has_ocr = #(o.ocr_values or {}) > 0
        if (o.presence or has_ocr) and (has_ocr or has_yolo(o)) then
            parts[#parts + 1] = { o = o, at = at, lacking = lacking(o, detections, ocr_detections) }
        end
    end
    table.sort(parts, function(a, b)
        if a.lacking ~= b.lacking then
            return a.lacking < b.lacking
        end
        return a.at < b.at
    end)
    local claimed_ocr, rows_at = {}, {}
    for _, part in ipairs(parts) do
        local rows, n, yolo = part_results(part.o, detections, ocr_detections, claimed, claimed_ocr)
        rows_at[part.at] = rows
        matched = matched + n
        expect_yolo = expect_yolo or yolo
    end
    for at = 1, #expected_flat do
        for _, row in ipairs(rows_at[at] or {}) do
            objects[#objects + 1] = row
        end
    end

    -- EXTRA is YOLO-only: unused OCR has no product value as an extra
    -- (hosts filter OCR to expected needles; noise must not flood
    -- Matched/Mistakes).
    local is_loose = loose_filter(expected_flat, objects)
    local unclaimed = {}
    for _, d in ipairs(detections) do
        if not expected.is_ocr_kind(d.kind) and not claimed[d._idx] and not is_loose(d) then
            table.insert(unclaimed, d)
        end
    end

    local catalog = input.catalog or {}
    local opts = input.opts or {}
    local extra_detections = {}
    if opts.anchor_extras == true and #catalog > 0 then
        -- Catalog-anchored path ignores `expect_yolo` — an unexpected
        -- component may not share any class with the active profile at all.
        -- Its rows carry the component name; drop those whose loose quota
        -- is already met.
        for _, d in ipairs(presence_catalog.extras(unclaimed, catalog, ocr_detections)) do
            if not is_loose(d) then
                table.insert(extra_detections, d)
            end
        end
    elseif expect_yolo then
        for _, d in ipairs(unclaimed) do
            table.insert(extra_detections, presence_catalog.copy(d))
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

return presence_validator
