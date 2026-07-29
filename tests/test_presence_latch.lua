-- Exercises `presence_latch.lua` across the JSON boundary.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
local presence_latch = dofile(script_dir .. "../lua/presence_latch.lua")
local t = dofile(script_dir .. "asserts.lua")

local function run(input)
    return json.decode(json.encode(presence_latch(input)))
end

local function obj(id, kind, status, label)
    return {
        id = id,
        yolo_classes = { "connector" },
        ocr_values = {},
        is_anchor = false,
        presence = true,
        status = status,
        matched_label = label,
        matched_confidence = status == "matched" and 0.9 or nil,
        match_kind = kind,
    }
end

local ID = "aaaaaaaa-0000-4000-8000-000000000001"

-- Fresh match → latched map gains the row; result stays matched.
local first = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "connector") },
        extra_detections = {},
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 0,
    },
    latched = {},
})
t.eq(first.result.matched, 1, "first: matched")
t.eq(first.result.objects[1].status, "matched", "first: status")
t.eq(#first.latched, 1, "first: latch size")
t.eq(first.latched[1].key, ID .. "|yolo", "first: latch key")

-- Later miss with prior latch → still matched (sticky).
local second = run({
    result = {
        objects = { obj(ID, "yolo", "missing", nil) },
        extra_detections = {},
        score = 0.0,
        matched = 0,
        total = 1,
        extra = 0,
    },
    latched = first.latched,
})
t.eq(second.result.matched, 1, "second: sticky matched count")
t.eq(second.result.objects[1].status, "matched", "second: sticky status")
t.eq(second.result.objects[1].matched_label, "connector", "second: keeps label")
t.close(second.result.score, 1.0, 1e-9, "second: score")

-- Independent match_kind rows (YOLO vs OCR) latch separately.
local OCR_ID = ID
local dual_miss = run({
    result = {
        objects = {
            obj(OCR_ID, "yolo", "missing", nil),
            obj(OCR_ID, "ocr", "missing", nil),
        },
        extra_detections = {},
        score = 0.0,
        matched = 0,
        total = 2,
        extra = 0,
    },
    latched = {
        {
            key = OCR_ID .. "|ocr",
            object = obj(OCR_ID, "ocr", "matched", "SN-42"),
        },
    },
})
t.eq(dual_miss.result.matched, 1, "dual: only OCR latched")
t.eq(dual_miss.result.objects[1].status, "missing", "dual: YOLO still missing")
t.eq(dual_miss.result.objects[2].status, "matched", "dual: OCR sticky")
t.eq(dual_miss.result.objects[2].matched_label, "SN-42", "dual: OCR label")

-- Empty prior + all missing → unchanged.
local empty = run({
    result = {
        objects = { obj(ID, "yolo", "missing", nil) },
        extra_detections = {},
        score = 0.0,
        matched = 0,
        total = 1,
        extra = 0,
    },
})
t.eq(empty.result.matched, 0, "empty: still missing")
t.eq(#empty.latched, 0, "empty: no latch entries")

print("test_presence_latch: ok")
