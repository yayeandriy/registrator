-- Presence stamps: shared class sets told apart by text, adjacent stamps, assembled fragments.

local script_dir = (arg[0]):match("(.*/)")
local h = dofile(script_dir .. "presence_helpers.lua")
local t = dofile(script_dir .. "asserts.lua")
local run, find_object, VISION = h.run, h.find_object, h.VISION

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


-- Split handwritten letters: matcher concat "A"+"B"+"C" → expected "Abc".
local split_letters = run({
    expected = {
        {
            id = "abababab-0000-4000-8000-0000000000ab",
            ocr_values = { "Abc" },
            presence = true,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "A", confidence = 1.0, x = 0.10, y = 0.40, width = 0.04, height = 0.06, kind = "ocr" },
        { label = "B", confidence = 1.0, x = 0.16, y = 0.40, width = 0.04, height = 0.06, kind = "ocr" },
        { label = "C", confidence = 1.0, x = 0.22, y = 0.40, width = 0.04, height = 0.06, kind = "ocr" },
    },
})
t.eq(split_letters.matched, 1, "split letters: Abc assembled")
t.eq(split_letters.objects[1].status, "matched", "split letters: status")

if not t.summary("presence_stamps") then
    os.exit(1)
end
