-- Presence is location-free: a part's detections count wherever they lie.

local script_dir = (arg[0]):match("(.*/)")
local h = dofile(script_dir .. "presence_helpers.lua")
local t = dofile(script_dir .. "asserts.lua")
local run, find_object, VISION = h.run, h.find_object, h.VISION

local function part(id, classes, texts)
    return {
        id = id,
        presence = true,
        yolo_classes = classes,
        ocr_values = texts,
        vision_model_id = VISION,
        boundary = { x = 0, y = 0, width = 0.1, height = 0.1 },
        rotation = 0,
        children = {},
    }
end

local function box(label, x, y)
    return { label = label, confidence = 0.9, x = x, y = y, width = 0.07, height = 0.08, kind = "yolo", vision_model_id = VISION }
end

local function read(label, x, y)
    return { label = label, confidence = 1.0, x = x, y = y, width = 0.2, height = 0.1, kind = "ocr" }
end

local function statuses(result, id)
    local out = {}
    for _, o in ipairs(result.objects) do
        if o.id == id then
            out[#out + 1] = o.match_kind .. ":" .. o.status
        end
    end
    return table.concat(out, " ")
end

-- A speaker with its number printed above it, not on it.
local speaker = { box("speaker", 0.59, 0.49), read("7937", 0.45, 0.30), read("MISS", 0.63, 0.77) }

local beside = run({ expected = { part("a", { "speaker" }, { "7937" }) }, detections = speaker })
t.eq(statuses(beside, "a"), "yolo:matched ocr:matched", "beside: the text above the class box counts")

local twice = run({
    expected = { part("a", { "speaker" }, { "7937" }), part("b", { "speaker" }, { "7937" }) },
    detections = speaker,
})
t.eq(statuses(twice, "a"), "yolo:matched ocr:matched", "twice: the first placement takes the part")
t.eq(statuses(twice, "b"), "yolo:missing ocr:missing", "twice: one part does not count for two")

local two_classes = run({
    expected = { part("c", { "lid", "base" }, {}) },
    detections = { box("lid", 0.05, 0.05), box("base", 0.85, 0.85) },
})
t.eq(statuses(two_classes, "c"), "yolo:matched", "two classes: far apart still one part")

local three = run({
    expected = { part("d", { "lid", "base" }, { "SN-1" }) },
    detections = { box("base", 0.85, 0.05), read("SN-1", 0.1, 0.8), box("lid", 0.05, 0.05) },
})
t.eq(statuses(three, "d"), "yolo:matched ocr:matched", "three parts: each counts wherever it lies")
t.eq(three.extra, 0, "three parts: no box left over")

local shared = run({
    expected = { part("p06", { "stamp" }, { "P06" }), part("x04", { "stamp" }, { "X04" }) },
    detections = { box("stamp", 0.1, 0.1), read("X04", 0.6, 0.6) },
})
t.eq(statuses(shared, "x04"), "yolo:matched ocr:matched", "shared class: the part whose text is read takes the box")
t.eq(statuses(shared, "p06"), "yolo:missing ocr:missing", "shared class: the other part lacks it")
t.eq(shared.objects[1].id, "p06", "shared class: rows keep the profile's order")

local one_read = run({
    expected = { part("e", {}, { "2020" }), part("f", {}, { "2020" }) },
    detections = { read("2020", 0.1, 0.1) },
})
t.eq(statuses(one_read, "e"), "ocr:matched", "one read: counts for the first part")
t.eq(statuses(one_read, "f"), "ocr:missing", "one read: not again for the second")

-- Presence is location-free: the text counts away from the class box.
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
t.eq(spatial_out.matched, 2, "spatial_out: YOLO and OCR both count")
local spat_ocr = find_object(spatial_out.objects, "spat0000-0000-4000-8000-000000000001", "ocr")
t.eq(spat_ocr.status, "matched", "spatial_out: OCR outside the class box counts")

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

-- Text in neither half of a two-class part still counts.
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
t.eq(gap_ocr.status, "matched", "spatial_gap: OCR outside both class boxes counts")


-- A text far from the class box still counts: only a wrapper ties them.
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
t.eq(far_noise.matched, 2, "far_noise: YOLO and the far text both count")
local far_ocr = find_object(far_noise.objects, FAR_ID, "ocr")
t.eq(far_ocr.status, "matched", "far_noise: 2020 away from the class box counts")


if not t.summary("presence_anywhere") then
    os.exit(1)
end
