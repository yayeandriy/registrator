-- Exercises `presence_validator.lua` across the JSON boundary.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
local presence_validator = dofile(script_dir .. "../lua/presence_validator.lua")
local t = dofile(script_dir .. "asserts.lua")

local function find_object(objects, id, match_kind)
    for _, o in ipairs(objects) do
        if o.id == id and (match_kind == nil or o.match_kind == match_kind) then
            return o
        end
    end
    return nil
end

local function run(input)
    return json.decode(json.encode(presence_validator(input)))
end

local VISION = "2353bf0c-1d76-4d4d-a6ee-aa7287d725c0"

-- YOLO presence: connector matched, button missing; extra YOLO capacitor.
local yolo_result = run({
    expected = {
        {
            id = "aaaaaaaa-0000-4000-8000-000000000001",
            yolo_classes = { "connector" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = true,
            children = {},
        },
        {
            id = "aaaaaaaa-0000-4000-8000-000000000002",
            yolo_classes = { "button" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
        {
            -- Presence Off — ignored even though class is present in detections.
            id = "aaaaaaaa-0000-4000-8000-000000000003",
            yolo_classes = { "led" },
            presence = false,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "connector", confidence = 0.9, x = 0.1, y = 0.1, width = 0.2, height = 0.2, kind = "yolo" },
        { label = "capacitor", confidence = 0.8, x = 0.5, y = 0.5, width = 0.1, height = 0.1, kind = "yolo" },
        { label = "led", confidence = 0.7, x = 0.2, y = 0.2, width = 0.1, height = 0.1, kind = "yolo" },
    },
})

t.eq(yolo_result.total, 2, "yolo: only presence=true objects counted")
t.eq(yolo_result.matched, 1, "yolo: connector matched")
t.eq(yolo_result.extra, 2, "yolo: capacitor + led are extras (led not claimed)")
t.close(yolo_result.score, 0.5, 1e-9, "yolo: score")

local connector = find_object(yolo_result.objects, "aaaaaaaa-0000-4000-8000-000000000001")
t.eq(connector.status, "matched", "yolo: connector status")
t.eq(connector.match_kind, "yolo", "yolo: connector match_kind")

local button = find_object(yolo_result.objects, "aaaaaaaa-0000-4000-8000-000000000002")
t.eq(button.status, "missing", "yolo: button missing")
t.is_nil(button.matched_label, "yolo: missing has no label")

-- OCR loose substring: expected "7206143" found inside a longer OCR string;
-- expected "ABSENT" missing. Unused OCR is never listed as EXTRA.
local ocr_result = run({
    expected = {
        {
            id = "bbbbbbbb-0000-4000-8000-000000000001",
            ocr_values = { "7206143" },
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
        {
            id = "bbbbbbbb-0000-4000-8000-000000000002",
            ocr_values = { "SN-42" },
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
        {
            id = "bbbbbbbb-0000-4000-8000-000000000003",
            ocr_values = { "ABSENT" },
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        {
            label = "59364-7206143-1-4363",
            confidence = 1.0,
            x = 0.1,
            y = 0.4,
            width = 0.6,
            height = 0.1,
            kind = "ocr",
        },
        {
            label = "  sn - 42  ",
            confidence = 0.95,
            x = 0.1,
            y = 0.5,
            width = 0.2,
            height = 0.05,
            kind = "ocr",
        },
        {
            label = "noise-token",
            confidence = 0.5,
            x = 0.7,
            y = 0.7,
            width = 0.1,
            height = 0.05,
            kind = "ocr",
        },
        -- YOLO noise must not become EXTRA when only OCR is expected.
        { label = "a_1_lower", confidence = 0.9, x = 0, y = 0, width = 1, height = 1, kind = "yolo" },
    },
})

t.eq(ocr_result.total, 3, "ocr: three presence texts")
t.eq(ocr_result.matched, 2, "ocr: two substring hits")
t.eq(ocr_result.extra, 0, "ocr: unused OCR is never EXTRA; YOLO suppressed")
t.eq(#ocr_result.extra_detections, 0, "ocr: no extra detections")

local serial = find_object(ocr_result.objects, "bbbbbbbb-0000-4000-8000-000000000001")
t.eq(serial.status, "matched", "ocr: serial substring matched")
t.eq(serial.match_kind, "ocr", "ocr: match_kind")
t.eq(serial.matched_label, "59364-7206143-1-4363", "ocr: matched full OCR string")

local sn = find_object(ocr_result.objects, "bbbbbbbb-0000-4000-8000-000000000002")
t.eq(sn.status, "matched", "ocr: whitespace/case-insensitive SN-42")

local absent = find_object(ocr_result.objects, "bbbbbbbb-0000-4000-8000-000000000003")
t.eq(absent.status, "missing", "ocr: ABSENT missing")

-- Punctuation-stripped + bidirectional: expected full serial, OCR fragment.
local frag = run({
    expected = {
        {
            id = "ffffffff-0000-4000-8000-000000000001",
            ocr_values = { "59364-7206143-1-4363" },
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "7206143", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr" },
    },
})
t.eq(frag.matched, 1, "ocr frag: detection fragment satisfies longer expected")

-- One OCR line can satisfy two expected substrings (no exclusive claim).
local share_result = run({
    expected = {
        {
            id = "cccccccc-0000-4000-8000-000000000001",
            ocr_values = { "AAA" },
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
        {
            id = "cccccccc-0000-4000-8000-000000000002",
            ocr_values = { "BBB" },
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "xxAAAyyBBBzz", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr" },
    },
})
t.eq(share_result.matched, 2, "ocr share: both substrings from one string")
t.eq(share_result.extra, 0, "ocr share: shared string is not extra")

-- Nested children are flattened.
local nested = run({
    expected = {
        {
            id = "dddddddd-0000-4000-8000-000000000001",
            yolo_classes = { "housing" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 10, height = 10 },
            rotation = 0,
            is_anchor = true,
            children = {
                {
                    id = "dddddddd-0000-4000-8000-000000000002",
                    yolo_classes = { "pin" },
                    presence = true,
                    vision_model_id = VISION,
                    boundary = { x = 1, y = 1, width = 1, height = 1 },
                    rotation = 0,
                    is_anchor = false,
                    children = {},
                },
            },
        },
    },
    detections = {
        { label = "housing", confidence = 0.9, x = 0, y = 0, width = 1, height = 1, kind = "yolo" },
        { label = "pin", confidence = 0.9, x = 0, y = 0, width = 1, height = 1, kind = "yolo" },
    },
})
t.eq(nested.total, 2, "nested: parent + child counted")
t.eq(nested.matched, 2, "nested: both matched")

-- Dual modality on one object → two independent result rows.
local both = run({
    expected = {
        {
            id = "eeeeeeee-0000-4000-8000-000000000001",
            yolo_classes = { "text_region" },
            ocr_values = { "HELLO" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "text_region", confidence = 0.9, x = 0, y = 0, width = 1, height = 1, kind = "yolo" },
        { label = "say HELLO please", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr" },
    },
})
t.eq(both.total, 2, "both: two checks from one object")
t.eq(both.matched, 2, "both: YOLO + OCR matched")
local both_yolo = find_object(both.objects, "eeeeeeee-0000-4000-8000-000000000001", "yolo")
local both_ocr = find_object(both.objects, "eeeeeeee-0000-4000-8000-000000000001", "ocr")
t.eq(both_yolo.status, "matched", "both: YOLO row matched")
t.eq(both_ocr.status, "matched", "both: OCR row matched")
t.eq(both.extra, 0, "both: no extras")

-- Dual: YOLO can succeed while OCR misses (no cross-fallback / no OCR→YOLO).
local dual_partial = run({
    expected = {
        {
            id = "eeeeeeee-0000-4000-8000-000000000002",
            yolo_classes = { "a_1_upper" },
            ocr_values = { "12" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "a_1_upper", confidence = 0.9, x = 0, y = 0, width = 1, height = 1, kind = "yolo" },
        { label = "(020", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr" },
    },
})
t.eq(dual_partial.total, 2, "dual_partial: two rows")
t.eq(find_object(dual_partial.objects, "eeeeeeee-0000-4000-8000-000000000002", "yolo").status, "matched", "dual_partial: YOLO OK")
t.eq(find_object(dual_partial.objects, "eeeeeeee-0000-4000-8000-000000000002", "ocr").status, "missing", "dual_partial: OCR MISS")
t.eq(dual_partial.extra, 0, "dual_partial: unused OCR is never EXTRA")
t.eq(#dual_partial.extra_detections, 0, "dual_partial: no extras")

-- Slug-as-class with YOLO model None must not create a YOLO check.
local no_model = run({
    expected = {
        {
            id = "eeeeeeee-0000-4000-8000-000000000003",
            yolo_classes = { "part_number" },
            ocr_values = { "59364-7206143-1" },
            presence = true,
            -- vision_model_id omitted / nil
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "59364-7206143-1-4363", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr" },
    },
})
t.eq(no_model.total, 1, "no_model: OCR only")
t.eq(no_model.matched, 1, "no_model: serial matched")
t.eq(no_model.objects[1].match_kind, "ocr", "no_model: match_kind ocr")
t.is_nil(find_object(no_model.objects, "eeeeeeee-0000-4000-8000-000000000003", "yolo"), "no_model: no YOLO row")

-- Live Stamps demo shape: A1 has vision model + class+text; part_number is
-- OCR-only (slug may linger as yolo_classes but vision_model_id is nil).
--   YOLO a_1_upper SUCCESS; a_1_lower + line_1_full EXTRA
--   OCR 12 MISS; 59364-7206143-1 SUCCESS; (020 discarded (OCR never EXTRA)
--   no MISS part_number yolo
local stamp = run({
    expected = {
        {
            id = "stamp000-0000-4000-8000-000000000001",
            yolo_classes = { "a_1_upper" },
            ocr_values = { "12" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
        {
            id = "stamp000-0000-4000-8000-000000000003",
            yolo_classes = { "part_number" },
            ocr_values = { "59364-7206143-1" },
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "a_1_lower", confidence = 0.92, x = 0, y = 0, width = 1, height = 1, kind = "yolo" },
        { label = "line_1_full", confidence = 0.92, x = 0, y = 0, width = 1, height = 1, kind = "yolo" },
        { label = "a_1_upper", confidence = 0.89, x = 0, y = 0, width = 1, height = 1, kind = "yolo" },
        { label = "(020", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr" },
        { label = "59364-7206143-1-4363", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr" },
    },
})
t.eq(stamp.matched, 2, "stamp: a_1_upper + serial matched")
t.eq(stamp.total, 3, "stamp: YOLO + OCR12 + serial = 3 checks")
t.eq(stamp.extra, 2, "stamp: two YOLO extras only (OCR never EXTRA)")

local upper = find_object(stamp.objects, "stamp000-0000-4000-8000-000000000001", "yolo")
t.eq(upper.status, "matched", "stamp: a_1_upper SUCCESS")
t.eq(upper.yolo_classes[1], "a_1_upper", "stamp: YOLO row exposes class")
t.is_nil(upper.ocr_values, "stamp: YOLO row hides ocr_value label")

local twelve = find_object(stamp.objects, "stamp000-0000-4000-8000-000000000001", "ocr")
t.eq(twelve.status, "missing", "stamp: 12 MISS")
t.eq(twelve.ocr_values[1], "12", "stamp: OCR row exposes text")

local serial = find_object(stamp.objects, "stamp000-0000-4000-8000-000000000003", "ocr")
t.eq(serial.status, "matched", "stamp: serial substring SUCCESS")
t.eq(serial.matched_label, "59364-7206143-1-4363", "stamp: serial matched full OCR")
t.is_nil(find_object(stamp.objects, "stamp000-0000-4000-8000-000000000003", "yolo"), "stamp: no part_number YOLO")

local extra_labels = {}
for _, d in ipairs(stamp.extra_detections) do
    extra_labels[d.label] = d.kind
end
t.eq(extra_labels["a_1_lower"], "yolo", "stamp: a_1_lower EXTRA")
t.eq(extra_labels["line_1_full"], "yolo", "stamp: line_1_full EXTRA")
t.is_nil(extra_labels["(020"], "stamp: unused OCR never EXTRA")
t.is_nil(extra_labels["a_1_upper"], "stamp: claimed YOLO not EXTRA")
t.is_nil(extra_labels["59364-7206143-1-4363"], "stamp: used OCR not EXTRA")

-- Match-all (AND): one OCR row per expected string; all required.
local match_all_partial = run({
    expected = {
        {
            id = "11111111-0000-4000-8000-000000000001",
            ocr_values = { "ABSENT", "7206143" },
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "59364-7206143-1-4363", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr" },
    },
})
t.eq(match_all_partial.total, 2, "match_all: two OCR rows")
t.eq(match_all_partial.matched, 1, "match_all: only one needle present")
local absent_row = nil
local serial_row = nil
for _, o in ipairs(match_all_partial.objects) do
    if o.match_kind == "ocr" and o.ocr_values and o.ocr_values[1] == "ABSENT" then
        absent_row = o
    end
    if o.match_kind == "ocr" and o.ocr_values and o.ocr_values[1] == "7206143" then
        serial_row = o
    end
end
t.eq(absent_row.status, "missing", "match_all: ABSENT missing")
t.eq(serial_row.status, "matched", "match_all: 7206143 matched")

local match_all_full = run({
    expected = {
        {
            id = "11111111-0000-4000-8000-000000000002",
            ocr_values = { "2020", "P06" },
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "2020", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr" },
        { label = "P06", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr" },
    },
})
t.eq(match_all_full.total, 2, "match_all_full: two OCR rows")
t.eq(match_all_full.matched, 2, "match_all_full: both needles matched")
local needles = {}
for _, o in ipairs(match_all_full.objects) do
    if o.match_kind == "ocr" and o.ocr_values then
        needles[o.ocr_values[1]] = o.status
    end
end
t.eq(needles["2020"], "matched", "match_all_full: 2020 row")
t.eq(needles["P06"], "matched", "match_all_full: P06 row")

-- Legacy singular ocr_value still accepted on input.
local legacy = run({
    expected = {
        {
            id = "22222222-0000-4000-8000-000000000001",
            ocr_value = "HELLO",
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "say HELLO please", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr" },
    },
})
t.eq(legacy.matched, 1, "legacy ocr_value: still matches")

-- Legacy singular yolo_class still accepted on input.
local legacy_yolo = run({
    expected = {
        {
            id = "33333333-0000-4000-8000-000000000001",
            yolo_class = "connector",
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "connector", confidence = 0.9, x = 0, y = 0, width = 1, height = 1, kind = "yolo" },
    },
})
t.eq(legacy_yolo.matched, 1, "legacy yolo_class: still matches")
t.eq(legacy_yolo.objects[1].yolo_classes[1], "connector", "legacy yolo_class: stamped as array")

-- Server Gemma kinds `ocr:<class_group>` must still count as OCR detections.
local ocr_kind_prefix = run({
    expected = {
        {
            id = "ocrkind0-0000-4000-8000-000000000001",
            yolo_classes = {},
            ocr_values = { "X04" },
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "X04", confidence = 1.0, x = 0, y = 0, width = 1, height = 1, kind = "ocr:test_1" },
    },
})
t.eq(ocr_kind_prefix.matched, 1, "ocr_kind_prefix: matches with kind ocr:<group>")
t.eq(ocr_kind_prefix.extra, 0, "ocr_kind_prefix: OCR never EXTRA")

-- OCR must sit inside the object's YOLO box (center-in-AABB).
local spatial_out = run({
    expected = {
        {
            id = "spat0000-0000-4000-8000-000000000001",
            yolo_classes = { "test_1_lower" },
            ocr_values = { "2020" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "test_1_lower", confidence = 0.9, x = 0.0, y = 0.0, width = 0.2, height = 0.2, kind = "yolo" },
        { label = "2020", confidence = 1.0, x = 0.8, y = 0.8, width = 0.1, height = 0.1, kind = "ocr" },
    },
})
t.eq(spatial_out.matched, 1, "spatial_out: YOLO matched, OCR outside")
local spat_ocr = find_object(spatial_out.objects, "spat0000-0000-4000-8000-000000000001", "ocr")
t.eq(spat_ocr.status, "missing", "spatial_out: OCR outside YOLO is missing")

local spatial_in = run({
    expected = {
        {
            id = "spat0000-0000-4000-8000-000000000002",
            yolo_classes = { "test_1_lower" },
            ocr_values = { "2020" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "test_1_lower", confidence = 0.9, x = 0.0, y = 0.0, width = 0.4, height = 0.4, kind = "yolo" },
        { label = "2020", confidence = 1.0, x = 0.1, y = 0.1, width = 0.1, height = 0.1, kind = "ocr" },
    },
})
t.eq(spatial_in.matched, 2, "spatial_in: YOLO + OCR inside")
t.eq(spatial_in.total, 2, "spatial_in: two rows")

-- Multi-class: OCR gated by union of all claimed class boxes.
local spatial_union = run({
    expected = {
        {
            id = "spat0000-0000-4000-8000-000000000003",
            yolo_classes = { "test_1_lower", "test_1_upper" },
            ocr_values = { "2020", "P06" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "test_1_lower", confidence = 0.9, x = 0.0, y = 0.0, width = 0.3, height = 0.3, kind = "yolo" },
        { label = "test_1_upper", confidence = 0.9, x = 0.4, y = 0.0, width = 0.3, height = 0.3, kind = "yolo" },
        { label = "2020", confidence = 1.0, x = 0.05, y = 0.05, width = 0.1, height = 0.1, kind = "ocr" },
        { label = "P06", confidence = 1.0, x = 0.5, y = 0.05, width = 0.1, height = 0.1, kind = "ocr" },
    },
})
t.eq(spatial_union.total, 3, "spatial_union: 1 YOLO + 2 OCR")
t.eq(spatial_union.matched, 3, "spatial_union: both texts inside union")
t.eq(spatial_union.extra, 0, "spatial_union: both class boxes claimed (not EXTRA)")

-- Text in neither half (outside union) fails even when label matches.
local spatial_gap = run({
    expected = {
        {
            id = "spat0000-0000-4000-8000-000000000004",
            yolo_classes = { "test_1_lower", "test_1_upper" },
            ocr_values = { "P06" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "test_1_lower", confidence = 0.9, x = 0.0, y = 0.0, width = 0.2, height = 0.2, kind = "yolo" },
        { label = "test_1_upper", confidence = 0.9, x = 0.3, y = 0.0, width = 0.2, height = 0.2, kind = "yolo" },
        { label = "P06", confidence = 1.0, x = 0.9, y = 0.9, width = 0.05, height = 0.05, kind = "ocr" },
    },
})
local gap_ocr = find_object(spatial_gap.objects, "spat0000-0000-4000-8000-000000000004", "ocr")
t.eq(gap_ocr.status, "missing", "spatial_gap: OCR outside combined YOLO area")

-- Two profile objects share the same class set; only one stamp is present.
-- Unique OCR must assign the instance to X04; P06 is fully missing.
local P06_ID = "comp0000-0000-4000-8000-0000000000p6"
local X04_ID = "comp0000-0000-4000-8000-0000000000x4"
local compete = run({
    expected = {
        {
            id = P06_ID,
            yolo_classes = { "test_1_lower", "test_1_upper" },
            ocr_values = { "2020", "P06" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = true,
            children = {},
        },
        {
            id = X04_ID,
            yolo_classes = { "test_1_lower", "test_1_upper" },
            ocr_values = { "2020", "X04" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = true,
            children = {},
        },
    },
    detections = {
        { label = "test_1_lower", confidence = 0.9, x = 0.0, y = 0.0, width = 0.4, height = 0.25, kind = "yolo" },
        { label = "test_1_upper", confidence = 0.9, x = 0.0, y = 0.2, width = 0.4, height = 0.25, kind = "yolo" },
        { label = "2020", confidence = 1.0, x = 0.1, y = 0.05, width = 0.1, height = 0.08, kind = "ocr" },
        { label = "X04", confidence = 1.0, x = 0.2, y = 0.28, width = 0.1, height = 0.08, kind = "ocr" },
    },
})
t.eq(compete.total, 6, "compete: 2 YOLO + 4 OCR rows")
t.eq(compete.matched, 3, "compete: only X04's YOLO + 2020 + X04")
t.eq(compete.extra, 0, "compete: stamp classes claimed by X04")
local p06_yolo = find_object(compete.objects, P06_ID, "yolo")
local x04_yolo = find_object(compete.objects, X04_ID, "yolo")
t.eq(p06_yolo.status, "missing", "compete: P06 YOLO missing (no instance)")
t.eq(x04_yolo.status, "matched", "compete: X04 YOLO matched")
local p06_2020 = nil
local p06_p06 = nil
local x04_2020 = nil
local x04_x04 = nil
for _, o in ipairs(compete.objects) do
    if o.id == P06_ID and o.match_kind == "ocr" then
        if o.ocr_values[1] == "2020" then p06_2020 = o end
        if o.ocr_values[1] == "P06" then p06_p06 = o end
    end
    if o.id == X04_ID and o.match_kind == "ocr" then
        if o.ocr_values[1] == "2020" then x04_2020 = o end
        if o.ocr_values[1] == "X04" then x04_x04 = o end
    end
end
t.eq(p06_2020.status, "missing", "compete: P06 must not steal shared 2020")
t.eq(p06_p06.status, "missing", "compete: P06 text missing")
t.eq(x04_2020.status, "matched", "compete: X04 keeps 2020")
t.eq(x04_x04.status, "matched", "compete: X04 text matched")

-- Adjacent stamps: YOLO halves sit on the bottom; years sit on the top rim.
-- Unique text must expand the gate so each stamp keeps its own 2020.
local ADJ_P06 = "adj00000-0000-4000-8000-0000000000p6"
local ADJ_X04 = "adj00000-0000-4000-8000-0000000000x4"
local adjacent = run({
    expected = {
        {
            id = ADJ_P06,
            yolo_classes = { "test_1_lower", "test_1_upper" },
            ocr_values = { "2020", "P06" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = true,
            children = {},
        },
        {
            id = ADJ_X04,
            yolo_classes = { "test_1_lower", "test_1_upper" },
            ocr_values = { "2020", "X04" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = true,
            children = {},
        },
    },
    detections = {
        -- Stamp X04 (left): year sits on the upper half; code on the lower.
        { label = "test_1_lower", confidence = 0.9, x = 0.05, y = 0.35, width = 0.18, height = 0.14, kind = "yolo" },
        { label = "test_1_upper", confidence = 0.9, x = 0.05, y = 0.22, width = 0.18, height = 0.16, kind = "yolo" },
        { label = "2020", confidence = 1.0, x = 0.08, y = 0.24, width = 0.12, height = 0.06, kind = "ocr" },
        { label = "X04", confidence = 1.0, x = 0.09, y = 0.40, width = 0.10, height = 0.06, kind = "ocr" },
        -- Stamp P06 (right, nearly touching).
        { label = "test_1_lower", confidence = 0.9, x = 0.26, y = 0.35, width = 0.18, height = 0.14, kind = "yolo" },
        { label = "test_1_upper", confidence = 0.9, x = 0.26, y = 0.22, width = 0.18, height = 0.16, kind = "yolo" },
        { label = "2020", confidence = 1.0, x = 0.29, y = 0.24, width = 0.12, height = 0.06, kind = "ocr" },
        { label = "P06", confidence = 1.0, x = 0.30, y = 0.40, width = 0.10, height = 0.06, kind = "ocr" },
        -- Frame noise far from any stamp — must not satisfy OCR.
        { label = "9 New T 1", confidence = 0.9, x = 0.85, y = 0.85, width = 0.1, height = 0.08, kind = "ocr" },
    },
})
t.eq(adjacent.matched, 6, "adjacent: both stamps fully matched")
t.eq(adjacent.extra, 0, "adjacent: no orphan classes")
for _, o in ipairs(adjacent.objects) do
    t.eq(o.status, "matched", "adjacent: " .. tostring(o.id) .. " " .. tostring(o.match_kind))
end

-- OCR far outside the object's YOLO pad is ignored (not a wrong value).
local FAR_ID = "far00000-0000-4000-8000-000000000001"
local far_noise = run({
    expected = {
        {
            id = FAR_ID,
            yolo_classes = { "test_1_lower" },
            ocr_values = { "2020" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = true,
            children = {},
        },
    },
    detections = {
        { label = "test_1_lower", confidence = 0.9, x = 0.1, y = 0.1, width = 0.2, height = 0.2, kind = "yolo" },
        { label = "2020", confidence = 1.0, x = 0.8, y = 0.8, width = 0.1, height = 0.1, kind = "ocr" },
        { label = "9 New T 1", confidence = 0.9, x = 0.7, y = 0.7, width = 0.15, height = 0.1, kind = "ocr" },
    },
})
t.eq(far_noise.matched, 1, "far_noise: YOLO only — OCR outside gate")
local far_ocr = find_object(far_noise.objects, FAR_ID, "ocr")
t.eq(far_ocr.status, "missing", "far_noise: 2020 outside YOLO is missing")

-- Arched year split into digit fragments — assemble left-to-right inside gate.
local FRAG_ID = "frag0000-0000-4000-8000-000000000001"
local fragments = run({
    expected = {
        {
            id = FRAG_ID,
            yolo_classes = { "test_1_lower" },
            ocr_values = { "2020", "P06" },
            presence = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = true,
            children = {},
        },
    },
    detections = {
        { label = "test_1_lower", confidence = 0.9, x = 0.1, y = 0.2, width = 0.4, height = 0.4, kind = "yolo" },
        { label = "2", confidence = 1.0, x = 0.12, y = 0.22, width = 0.05, height = 0.06, kind = "ocr" },
        { label = "0", confidence = 1.0, x = 0.20, y = 0.22, width = 0.05, height = 0.06, kind = "ocr" },
        { label = "2", confidence = 1.0, x = 0.28, y = 0.22, width = 0.05, height = 0.06, kind = "ocr" },
        { label = "0", confidence = 1.0, x = 0.36, y = 0.22, width = 0.05, height = 0.06, kind = "ocr" },
        { label = "P06", confidence = 1.0, x = 0.22, y = 0.45, width = 0.12, height = 0.08, kind = "ocr" },
    },
})
t.eq(fragments.matched, 3, "fragments: YOLO + assembled 2020 + P06")
local frag_2020 = nil
for _, o in ipairs(fragments.objects) do
    if o.match_kind == "ocr" and o.ocr_values and o.ocr_values[1] == "2020" then
        frag_2020 = o
    end
end
t.eq(frag_2020.status, "matched", "fragments: 2020 assembled from digits")

-- Catalog-anchored extras — `opts.anchor_extras` toggleable module. Off by
-- default (see `anchor_off` below); on only when a host also supplies
-- `catalog` (every project component) and `opts.anchor_extras = true`.
local CAT_D07 = "catd0000-0000-4000-8000-0000000000d7"
local ANCHOR_SOLO_ID = "solo0000-0000-4000-8000-000000000001"
local catalog_all = {
    { id = P06_ID, name = "Test P06", yolo_classes = { "test_1_lower", "test_1_upper" }, ocr_values = { "2020", "P06" } },
    { id = X04_ID, name = "Test X04", yolo_classes = { "test_1_lower", "test_1_upper" }, ocr_values = { "2020", "X04" } },
    { id = CAT_D07, name = "Test D07", yolo_classes = { "test_1_lower", "test_1_upper" }, ocr_values = { "2020", "D07" } },
    { id = ANCHOR_SOLO_ID, name = "Oval Mark", yolo_classes = { "oval_mark" }, ocr_values = {} },
}

-- Same competing P06/X04 scene as `compete`, plus an unexpected third
-- stamp (D07 — same classes, not in the profile at all, own unique code)
-- sitting well clear of the other two so it can't share their OCR gate.
local function competing_scene_with_extra_stamp()
    return {
        { label = "test_1_lower", confidence = 0.9, x = 0.0, y = 0.0, width = 0.4, height = 0.25, kind = "yolo" },
        { label = "test_1_upper", confidence = 0.9, x = 0.0, y = 0.2, width = 0.4, height = 0.25, kind = "yolo" },
        { label = "2020", confidence = 1.0, x = 0.1, y = 0.05, width = 0.1, height = 0.08, kind = "ocr" },
        { label = "X04", confidence = 1.0, x = 0.2, y = 0.28, width = 0.1, height = 0.08, kind = "ocr" },
        { label = "test_1_lower", confidence = 0.9, x = 0.6, y = 0.0, width = 0.4, height = 0.25, kind = "yolo" },
        { label = "test_1_upper", confidence = 0.9, x = 0.6, y = 0.2, width = 0.4, height = 0.25, kind = "yolo" },
        { label = "D07", confidence = 1.0, x = 0.8, y = 0.28, width = 0.1, height = 0.08, kind = "ocr" },
    }
end

local competing_expected = {
    {
        id = P06_ID,
        yolo_classes = { "test_1_lower", "test_1_upper" },
        ocr_values = { "2020", "P06" },
        presence = true,
        vision_model_id = VISION,
        boundary = { x = 0, y = 0, width = 1, height = 1 },
        rotation = 0,
        is_anchor = true,
        children = {},
    },
    {
        id = X04_ID,
        yolo_classes = { "test_1_lower", "test_1_upper" },
        ocr_values = { "2020", "X04" },
        presence = true,
        vision_model_id = VISION,
        boundary = { x = 0, y = 0, width = 1, height = 1 },
        rotation = 0,
        is_anchor = true,
        children = {},
    },
}

-- Off by default: the unexpected stamp still surfaces as flat, unnamed
-- unclaimed boxes — zero behavior change from before this toggle existed.
local anchor_off = run({
    expected = competing_expected,
    detections = competing_scene_with_extra_stamp(),
})
t.eq(anchor_off.extra, 2, "anchor off: D07's two class boxes are flat extras")
for _, d in ipairs(anchor_off.extra_detections) do
    t.is_nil(d.matched_label, "anchor off: no catalog naming without the toggle")
end

-- On: the same two boxes cluster into one instance, named "Test D07" from
-- the catalog via its unique OCR code (shared "2020" alone would not do).
local anchor_on = run({
    expected = competing_expected,
    detections = competing_scene_with_extra_stamp(),
    catalog = catalog_all,
    opts = { anchor_extras = true },
})
t.eq(#anchor_on.extra_detections, 1, "anchor on: one clustered instance, not two boxes")
t.eq(anchor_on.extra_detections[1].matched_label, "Test D07", "anchor on: named via unique OCR")
t.eq(anchor_on.extra_detections[1].kind, "extra", "anchor on: instance kind")

-- On, but this tick's OCR did not catch D07's code at all — still
-- surfaced (never silently dropped), just without a confirmed name yet.
local no_ocr_dets = competing_scene_with_extra_stamp()
table.remove(no_ocr_dets, #no_ocr_dets)
local anchor_ambiguous = run({
    expected = competing_expected,
    detections = no_ocr_dets,
    catalog = catalog_all,
    opts = { anchor_extras = true },
})
t.eq(#anchor_ambiguous.extra_detections, 1, "anchor ambiguous: instance still surfaced")
t.is_nil(anchor_ambiguous.extra_detections[1].matched_label, "anchor ambiguous: no OCR yet, no guess")

-- A class signature owned by exactly one catalog component is unambiguous
-- — named without needing any OCR at all.
local solo_extra = run({
    expected = {},
    detections = {
        { label = "oval_mark", confidence = 0.9, x = 0.1, y = 0.1, width = 0.1, height = 0.1, kind = "yolo" },
    },
    catalog = catalog_all,
    opts = { anchor_extras = true },
})
t.eq(#solo_extra.extra_detections, 1, "solo: single unclaimed box")
t.eq(solo_extra.extra_detections[1].matched_label, "Oval Mark", "solo: named without OCR (only one candidate)")

-- A class with no catalog signature at all still passes through raw —
-- catalog-anchored extras never hide something the catalog does not know.
local unknown_extra = run({
    expected = {},
    detections = {
        { label = "totally_unknown_class", confidence = 0.9, x = 0.1, y = 0.1, width = 0.1, height = 0.1, kind = "yolo" },
    },
    catalog = catalog_all,
    opts = { anchor_extras = true },
})
t.eq(#unknown_extra.extra_detections, 1, "unknown: passes through")
t.is_nil(unknown_extra.extra_detections[1].matched_label, "unknown: not in any catalog signature")

if not t.summary("presence_validator") then
    os.exit(1)
end



