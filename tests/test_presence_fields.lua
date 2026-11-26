-- Presence input fields: live stamps shape, AND over texts, legacy singular fields, `ocr:` kinds.

local script_dir = (arg[0]):match("(.*/)")
local h = dofile(script_dir .. "presence_helpers.lua")
local t = dofile(script_dir .. "asserts.lua")
local run, find_object, VISION = h.run, h.find_object, h.VISION

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

if not t.summary("presence_fields") then
    os.exit(1)
end
