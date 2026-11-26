-- Presence catalog-anchored extras (`opts.anchor_extras`).

local script_dir = (arg[0]):match("(.*/)")
local h = dofile(script_dir .. "presence_helpers.lua")
local t = dofile(script_dir .. "asserts.lua")
local run, find_object, VISION = h.run, h.find_object, h.VISION

local P06_ID = "comp0000-0000-4000-8000-0000000000p6"
local X04_ID = "comp0000-0000-4000-8000-0000000000x4"

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

-- The X04 stamp the profile expects, plus an unexpected second stamp (D07 —
-- same classes, not in the profile at all, own unique code).
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
    expected = { competing_expected[2] },
    detections = competing_scene_with_extra_stamp(),
})
t.eq(anchor_off.extra, 2, "anchor off: D07's two class boxes are flat extras")
for _, d in ipairs(anchor_off.extra_detections) do
    t.is_nil(d.matched_label, "anchor off: no catalog naming without the toggle")
end

-- On: the same two boxes cluster into one instance, named "Test D07" from
-- the catalog via its unique OCR code (shared "2020" alone would not do).
local anchor_on = run({
    expected = { competing_expected[2] },
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
    expected = { competing_expected[2] },
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

if not t.summary("presence_catalog") then
    os.exit(1)
end
