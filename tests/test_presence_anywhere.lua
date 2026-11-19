-- Presence is location-free: a part's detections count wherever they lie.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
normalisator = dofile(script_dir .. "../lua/normalisator.lua")
matcher = dofile(script_dir .. "../lua/matcher.lua")
class_match = dofile(script_dir .. "../lua/class_match.lua")
local presence_validator = dofile(script_dir .. "../lua/presence_validator.lua")
local t = dofile(script_dir .. "asserts.lua")

local VISION = "c4f1ba0c-bb60-4a9a-84dc-de17a305dff8"

local function run(input)
    return json.decode(json.encode(presence_validator(input)))
end

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

if not t.summary("presence_anywhere") then
    os.exit(1)
end
