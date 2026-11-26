-- Presence loose match: surplus boxes of a met quota are not extras.

local script_dir = (arg[0]):match("(.*/)")
local h = dofile(script_dir .. "presence_helpers.lua")
local t = dofile(script_dir .. "asserts.lua")
local run, find_object, VISION = h.run, h.find_object, h.VISION

-- Loose match (component): one placed instance, three same-class hits →
-- matched, surplus screws ignored.
local loose_result = run({
    expected = {
        {
            id = "aaaaaaaa-0000-4000-8000-0000000000aa",
            yolo_classes = { "screw" },
            presence = true,
            loose_match = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "screw", confidence = 0.9, x = 0.1, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
        { label = "screw", confidence = 0.8, x = 0.3, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
        { label = "screw", confidence = 0.7, x = 0.5, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
        { label = "capacitor", confidence = 0.9, x = 0.7, y = 0.7, width = 0.1, height = 0.1, kind = "yolo" },
    },
})
t.eq(loose_result.matched, 1, "loose: screw matched")
t.eq(loose_result.extra, 1, "loose: surplus screws ignored; capacitor still extra")
t.eq(loose_result.extra_detections[1].label, "capacitor", "loose: leftover extra is the other class")

-- Strict (default): same three screws → 1 matched + 2 extras (+ capacitor).
local strict_result = run({
    expected = {
        {
            id = "aaaaaaaa-0000-4000-8000-0000000000bb",
            yolo_classes = { "screw" },
            presence = true,
            loose_match = false,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "screw", confidence = 0.9, x = 0.1, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
        { label = "screw", confidence = 0.8, x = 0.3, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
        { label = "screw", confidence = 0.7, x = 0.5, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
    },
})
t.eq(strict_result.matched, 1, "strict: screw matched")
t.eq(strict_result.extra, 2, "strict: surplus screws are extras")

-- Missing loose-match object does not suppress extras of its class.
local missing_loose = run({
    expected = {
        {
            id = "aaaaaaaa-0000-4000-8000-0000000000cc",
            yolo_classes = { "button" },
            presence = true,
            loose_match = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "screw", confidence = 0.9, x = 0.1, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
    },
})
t.eq(missing_loose.matched, 0, "missing loose: not detected")
t.eq(missing_loose.extra, 1, "missing loose: other-class leftover still extra")

-- Two placed instances of the same loose component: ≥2 detections → green,
-- surplus of that class is not extra.
local COMP = "bbbbbbbb-0000-4000-8000-0000000000aa"
local two_loose = run({
    expected = {
        {
            id = "aaaaaaaa-0000-4000-8000-0000000000d1",
            component_ids = { COMP },
            yolo_classes = { "screw" },
            presence = true,
            loose_match = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
        {
            id = "aaaaaaaa-0000-4000-8000-0000000000d2",
            component_ids = { COMP },
            yolo_classes = { "screw" },
            presence = true,
            loose_match = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "screw", confidence = 0.9, x = 0.1, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
        { label = "screw", confidence = 0.8, x = 0.3, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
        { label = "screw", confidence = 0.7, x = 0.5, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
        { label = "screw", confidence = 0.6, x = 0.7, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
        { label = "screw", confidence = 0.5, x = 0.9, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
    },
})
t.eq(two_loose.matched, 2, "two loose: both placed instances matched")
t.eq(two_loose.extra, 0, "two loose: surplus screws not extra")

-- Same two placements, not loose: surplus stays extra.
local two_strict = run({
    expected = {
        {
            id = "aaaaaaaa-0000-4000-8000-0000000000e1",
            component_ids = { COMP },
            yolo_classes = { "screw" },
            presence = true,
            loose_match = false,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
        {
            id = "aaaaaaaa-0000-4000-8000-0000000000e2",
            component_ids = { COMP },
            yolo_classes = { "screw" },
            presence = true,
            loose_match = false,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = {
        { label = "screw", confidence = 0.9, x = 0.1, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
        { label = "screw", confidence = 0.8, x = 0.3, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
        { label = "screw", confidence = 0.7, x = 0.5, y = 0.1, width = 0.05, height = 0.05, kind = "yolo" },
    },
})
t.eq(two_strict.matched, 2, "two strict: both matched")
t.eq(two_strict.extra, 1, "two strict: one surplus extra")

-- Two-class stamp: one placed instance + leftover class halves + a
-- foreign class. Loose match must swallow the halves (catalog extras too).
local stamp_dets = {
    { label = "a_1_lower", confidence = 0.9, x = 0.10, y = 0.10, width = 0.08, height = 0.08, kind = "yolo" },
    { label = "a_1_upper", confidence = 0.9, x = 0.12, y = 0.18, width = 0.08, height = 0.08, kind = "yolo" },
    { label = "a_1_lower", confidence = 0.8, x = 0.40, y = 0.10, width = 0.08, height = 0.08, kind = "yolo" },
    { label = "a_1_lower", confidence = 0.7, x = 0.55, y = 0.10, width = 0.08, height = 0.08, kind = "yolo" },
    { label = "a_1_lower", confidence = 0.6, x = 0.70, y = 0.10, width = 0.08, height = 0.08, kind = "yolo" },
    { label = "test_1_lower", confidence = 0.9, x = 0.85, y = 0.80, width = 0.08, height = 0.08, kind = "yolo" },
}
local stamp_expected = {
    {
        id = "aaaaaaaa-0000-4000-8000-0000000000s1",
        name = "a_1",
        component_ids = { "comp-a1" },
        yolo_classes = { "a_1_lower", "a_1_upper" },
        presence = true,
        loose_match = true,
        vision_model_id = VISION,
        boundary = { x = 0, y = 0, width = 1, height = 1 },
        rotation = 0,
        is_anchor = false,
        children = {},
    },
}
local stamp_loose = run({
    expected = stamp_expected,
    detections = stamp_dets,
})
t.eq(stamp_loose.matched, 1, "stamp loose: instance matched")
t.eq(stamp_loose.extra, 1, "stamp loose: leftover halves ignored; foreign class stays extra")
t.eq(stamp_loose.extra_detections[1].label, "test_1_lower", "stamp loose: leftover extra is the other class")

-- Same detections with catalog-anchored extras (iOS inspect path).
local stamp_catalog = run({
    expected = stamp_expected,
    detections = stamp_dets,
    catalog = {
        { id = "comp-a1", name = "a_1", yolo_classes = { "a_1_lower", "a_1_upper" }, ocr_values = {} },
        { id = "comp-t1", name = "test_1", yolo_classes = { "test_1_lower", "test_1_upper" }, ocr_values = {} },
    },
    opts = { anchor_extras = true },
})
t.eq(stamp_catalog.matched, 1, "stamp catalog: instance matched")
t.eq(stamp_catalog.extra, 1, "stamp catalog: leftover a_1 halves not extras")
t.eq(
    stamp_catalog.extra_detections[1].label == "test_1_lower"
        or stamp_catalog.extra_detections[1].matched_label == "test_1",
    true,
    "stamp catalog: only the foreign stamp remains extra"
)

-- Catalog labels with spaces still skip underscore detections.
local stamp_spaced = run({
    expected = {
        {
            id = "aaaaaaaa-0000-4000-8000-0000000000s2",
            name = "a_1",
            yolo_classes = { "a_1 lower", "a_1 upper" },
            presence = true,
            loose_match = true,
            vision_model_id = VISION,
            boundary = { x = 0, y = 0, width = 1, height = 1 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
    detections = stamp_dets,
})
t.eq(stamp_spaced.matched, 0, "stamp spaced: exact class mismatch so YOLO miss")
-- Quota not met → do not swallow foreign extras; leftover a_1_* stay extra
-- because the object itself did not match (classes did not line up).
t.eq(stamp_spaced.extra > 0, true, "stamp spaced: unmatched loose does not hide leftovers")

if not t.summary("presence_loose") then
    os.exit(1)
end
