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
--     contain the other when the shorter token is ≥3 chars). An object passes
--     when **any** expected string matches **any** OCR detection. One OCR
--     check per object (not one per expected string).
--   - YOLO: `presence == true`, non-empty `yolo_classes`, **and** a
--     `vision_model_id` → exact `label` match on a non-OCR detection.
--     First claim wins (greedy). Slug-only legacy class with YOLO model
--     None (no vision_model_id) is not a YOLO expectation.
--   - When both OCR and a real YOLO expectation apply, **both** checks run
--     and produce two result rows (e.g. stamp A1 = class `a_1_upper` +
--     text `12`).
--
-- Extras (YOLO-only):
--   - Unclaimed YOLO boxes, only if at least one YOLO check ran.
--   - Unused OCR is never EXTRA (hosts filter to expected needles; noise
--     must not flood Matched/Mistakes).
--
-- Input (a single Lua table):
--   {
--     expected = { ReferenceObject... },
--     detections = {
--       { label, confidence, x, y, width, height, kind = "yolo"|"ocr"|... },
--       ...
--     },
--   }
-- Detection coordinates are ignored — presence only.
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
    return k:lower() == "ocr"
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

local function find_ocr(ocr_detections, needle)
    if normalize_alnum(needle) == "" then
        return nil
    end
    for _, d in ipairs(ocr_detections) do
        if ocr_text_match(d.label, needle) then
            return d
        end
    end
    return nil
end

-- Match-any: first hit across all expected strings wins.
local function find_ocr_any(ocr_detections, needles)
    for _, needle in ipairs(needles) do
        local hit = find_ocr(ocr_detections, needle)
        if hit then
            return hit
        end
    end
    return nil
end

local function find_yolo_any(detections, classes, claimed)
    for _, class in ipairs(classes) do
        local hit = find_yolo(detections, class, claimed)
        if hit then
            return hit
        end
    end
    return nil
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

local function push_result(objects, o, status, matched_label, matched_confidence, match_kind)
    -- For dual-modality rows, expose only the field that this row asserts
    -- so the UI label matches the check (YOLO class vs OCR text).
    local yolo_classes = o.yolo_classes
    local ocr_values = o.ocr_values
    if match_kind == "yolo" then
        ocr_values = nil
    elseif match_kind == "ocr" then
        yolo_classes = nil
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
    local ocr_used = {}
    local objects = {}
    local matched = 0
    local expect_yolo = false
    local expect_ocr = false

    for _, o in ipairs(expected_flat) do
        local ocr_values = o.ocr_values or {}
        local has_ocr = #ocr_values > 0
        local has_yolo = #(o.yolo_classes or {}) > 0 and has_vision_model(o)
        -- Same membership as Constructor Presence rail.
        local on_rail = o.presence or has_ocr
        if on_rail and (has_ocr or has_yolo) then
            -- YOLO: Presence On + class + bound vision model.
            if o.presence and has_yolo then
                expect_yolo = true
                local hit = find_yolo_any(detections, o.yolo_classes, claimed)
                if hit then
                    push_result(objects, o, "matched", hit.label, hit.confidence, "yolo")
                    claimed[hit._idx] = true
                    matched = matched + 1
                else
                    push_result(objects, o, "missing", nil, nil, "yolo")
                end
            end

            -- OCR: any rail item with ocr_values (Presence On or text-only).
            if has_ocr then
                expect_ocr = true
                local hit = find_ocr_any(ocr_detections, ocr_values)
                if hit then
                    push_result(objects, o, "matched", hit.label, hit.confidence, "ocr")
                    ocr_used[hit._idx] = true
                    matched = matched + 1
                else
                    push_result(objects, o, "missing", nil, nil, "ocr")
                end
            end
        end
    end

    -- EXTRA is YOLO-only. Unused OCR strings have no product value as
    -- extras (hosts filter OCR to expected needles; noise must not flood
    -- Matched/Mistakes). `expect_ocr` still gates whether OCR checks ran.
    local extra_detections = {}
    if expect_yolo then
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
