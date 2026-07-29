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

-- Match-any: one OCR check per object; any expected string may satisfy it.
local match_any = run({
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
t.eq(match_any.total, 1, "match_any: one OCR row")
t.eq(match_any.matched, 1, "match_any: second expected string hits")

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

if not t.summary("presence_validator") then
    os.exit(1)
end



