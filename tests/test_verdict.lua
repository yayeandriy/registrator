-- Exercises `verdict.lua` (needs `ocr_window` in scope).

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
ocr_window = dofile(script_dir .. "../lua/ocr_window.lua")
local verdict = dofile(script_dir .. "../lua/verdict.lua")
local t = dofile(script_dir .. "asserts.lua")

local function rt(v)
    return json.decode(json.encode(v))
end

-- Presence: counts decide, an incorrect object blocks pass.
local p = rt(verdict.from_presence({
    presence = {
        matched = 2, total = 2, extra = 0,
        objects = {
            { id = "a", status = "matched", yolo_classes = { "pin" } },
            { id = "b", status = "matched", ocr_values = { "AB12" }, match_kind = "ocr" },
        },
    },
})).verdict
t.eq(p.result, "pass", "presence all matched passes")
t.eq(p.complete, true, "presence complete")
t.eq(p.rows[2].label, "AB12", "ocr row labelled by its text")

local empty = rt(verdict.from_presence({ presence = { matched = 0, total = 0, extra = 0, objects = {} } })).verdict
t.eq(empty.result, "pending", "no expectations stays pending")
t.eq(#empty.rows, 0, "empty rows encode as an array")

local pose = rt(verdict.from_presence({
    presence = {
        matched = 1, total = 1, extra = 0,
        objects = { { id = "a", status = "mispositioned", yolo_classes = { "pin" } } },
    },
})).verdict
t.eq(pose.result, "fail", "incorrect object fails even with matched == total")
t.eq(pose.complete, true, "complete is counts only")

-- Spatial: soft fail is held one tick after a match.
local matched = { id = "a", status = "matched", yolo_classes = { "pin" } }
local first = verdict.from_spatial({ spatial = { matched = 1, total = 1, extra = 0, objects = { matched } } })
local wobble = verdict.from_spatial({
    hold = first.hold,
    spatial = { matched = 0, total = 1, extra = 0, objects = { { id = "a", status = "misrotated", yolo_classes = { "pin" } } } },
})
t.eq(wobble.objects[1].status, "matched", "one soft fail stays matched")
t.eq(wobble.hold[1].fail_streak, 1, "streak counted")
local again = verdict.from_spatial({
    hold = wobble.hold,
    spatial = { matched = 0, total = 1, extra = 0, objects = { { id = "a", status = "misrotated", yolo_classes = { "pin" } } } },
})
t.eq(again.objects[1].status, "misrotated", "a repeated soft fail shows")

local extras = verdict.from_spatial({
    spatial = {
        matched = 1, total = 1, extra = 1,
        objects = { matched },
        extra_detections = { { label = "screw", confidence = 0.9 } },
    },
}).verdict
t.eq(extras.result, "fail", "surplus fails spatial")
t.eq(extras.rows[2].status, "extra", "extra row appended")

-- Merge: pose failure beats a presence match; OCR extras drop.
local merged = rt(verdict.merge({
    presence = { result = "pass", matched = 1, total = 1, incorrect = 0, missing = 0, extra = 0,
        complete = true, no_expectations = false,
        rows = { { object_id = "a", label = "pin", status = "matched" } } },
    spatial = { result = "fail", matched = 0, total = 1, incorrect = 1, missing = 0, extra = 1,
        complete = false, no_expectations = false,
        rows = { { object_id = "a", label = "pin", status = "mispositioned" },
                 { label = "AB12", status = "extra" } } },
    ocr_labels = { "AB12" },
    needles = {},
    ocr = { wants_ocr = false },
}))
t.eq(merged.verdict.rows[1].status, "mispositioned", "pose failure wins the union")
t.eq(merged.verdict.result, "fail", "merged fails")
t.eq(merged.verdict.extra, 0, "OCR surplus is not a part")

local only = rt(verdict.merge({
    spatial = { result = "pass", matched = 1, total = 1, incorrect = 0, missing = 0, extra = 0,
        complete = true, no_expectations = false, rows = { { object_id = "a", label = "pin", status = "matched" } } },
    ocr = { wants_ocr = false },
}))
t.eq(only.verdict.result, "pass", "one side passes through")

t.eq(next(verdict.merge({})), nil, "nothing scored")

-- Unsettled OCR: a text miss waits while OCR has not run.
local held = rt(verdict.merge({
    presence = { result = "fail", matched = 0, total = 1, incorrect = 0, missing = 1, extra = 0,
        complete = false, no_expectations = false,
        rows = { { object_id = "t", label = "AB12", status = "missing", match_kind = "ocr" } } },
    needles = { "AB12" },
    ocr = { wants_ocr = true, engine_off = false, backend_ran = false, read_labels = {} },
}))
t.eq(held.verdict.rows[1].status, "pending", "text miss held")
t.eq(held.verdict.result, "pending", "verdict pending while OCR has not run")
t.eq(held.ocr.tick_finished, false, "tick not finished")

local mixed = rt(verdict.merge({
    presence = { result = "fail", matched = 0, total = 2, incorrect = 0, missing = 2, extra = 0,
        complete = false, no_expectations = false,
        rows = { { object_id = "t", label = "AB12", status = "missing", match_kind = "ocr" },
                 { object_id = "s", label = "square", status = "missing", match_kind = "yolo" } } },
    needles = { "AB12" },
    ocr = { wants_ocr = true, backend_ran = false, read_labels = {} },
}))
t.eq(mixed.verdict.rows[2].status, "missing", "a held text miss does not hide a part miss")
t.eq(mixed.verdict.missing, 1, "only the text miss is held")
t.eq(mixed.verdict.result, "fail", "the part miss still fails")

-- Merge keeps the presence-only text row and one row per shared part.
local union = rt(verdict.merge({
    presence = { result = "pass", matched = 2, total = 2, incorrect = 0, missing = 0, extra = 0,
        complete = true, no_expectations = false,
        rows = { { object_id = "text", label = "26050D", status = "matched", match_kind = "ocr" },
                 { object_id = "sq", label = "square", status = "matched", match_kind = "yolo" } } },
    spatial = { result = "pass", matched = 1, total = 1, incorrect = 0, missing = 0, extra = 0,
        complete = true, no_expectations = false,
        rows = { { object_id = "sq", label = "square", status = "matched", match_kind = "yolo" } } },
    ocr = { wants_ocr = false },
}))
t.eq(union.verdict.total, 2, "union total")
t.eq(union.verdict.matched, 2, "union matched")
t.eq(#union.verdict.rows, 2, "one row per object")

-- Presence labels: text rows by their expected text, parts by class.
local labels = rt(verdict.from_presence({ presence = { matched = 0, total = 3, extra = 0, objects = {
    { id = "a", yolo_classes = {}, ocr_values = { "26050D" }, status = "missing", match_kind = "ocr" },
    { id = "b", yolo_classes = {}, ocr_values = { "26050D" }, status = "matched", match_kind = "ocr", matched_label = "2605OD" },
    { id = "c", yolo_classes = { " ", "square" }, ocr_values = {}, status = "missing", match_kind = "yolo" },
} } })).verdict.rows
t.eq(labels[1].label, "26050D", "a missing text row shows the expected text")
t.eq(labels[2].label, "26050D", "a matched text row prefers the expected text")
t.eq(labels[3].label, "square", "a part row skips blank classes")

if not t.summary("verdict") then
    os.exit(1)
end
