-- wrapper.lua: a wrapper detection stands for its part only while the part's
-- other detections lie inside its box.

local script_dir = (arg[0]):match("(.*/)") or "./"
local root = script_dir .. "../"
class_match = dofile(root .. "lua/class_match.lua")
normalisator = dofile(root .. "lua/normalisator.lua")
matcher = dofile(root .. "lua/matcher.lua")
local wrapper = dofile(root .. "lua/wrapper.lua")
local compose = dofile(script_dir .. "compose_live.lua")
local live = assert(load(compose(root), "live.lua"))()
local json = dofile(root .. "lua/json.lua")
local t = dofile(script_dir .. "asserts.lua")

local MODEL = "2353bf0c-1d76-4d4d-a6ee-aa7287d725c0"
local ID = "aaaaaaaa-0000-4000-8000-000000000001"

local function part(wrap, routines)
    return {
        id = ID,
        yolo_classes = { "test_1_lower" },
        yolo_class_refs = { { class_id = "c-lower", label = "test_1_lower", vision_model_id = MODEL } },
        ocr_values = { "P06" },
        vision_model_id = MODEL,
        boundary = { x = 0, y = 0, width = 8, height = 8 },
        rotation = 0,
        routines = routines or { "presence_validate" },
        presence = true,
        children = {},
        wrapper = wrap,
    }
end

local CLASS = { class_id = "c-lower", label = "test_1_lower", vision_model_id = MODEL }

local function yolo(x)
    return { label = "test_1_lower", class_id = "c-lower", vision_model_id = MODEL, kind = "yolo",
             confidence = 0.9, x = x, y = 0.1, width = 0.2, height = 0.2 }
end

local function ocr(text, x)
    return { label = text, kind = "ocr", confidence = 0.9, x = x, y = 0.15, width = 0.08, height = 0.05 }
end

local function labels(dets)
    local out = {}
    for _, d in ipairs(dets) do
        out[#out + 1] = d.label .. "@" .. d.x
    end
    return table.concat(out, ",")
end

local scene = { yolo(0.1), ocr("X04", 0.15), yolo(0.5), ocr("P06", 0.55) }
local kept = wrapper.detections({ part(CLASS) }, scene)
t.eq(labels(kept), "X04@0.15,test_1_lower@0.5,P06@0.55",
    "only the class box holding the text stays")
t.eq(labels(wrapper.detections({ part(nil) }, scene)), labels(scene), "no wrapper keeps every box")

local outside = { yolo(0.1), ocr("P06", 0.28) }
t.eq(labels(wrapper.detections({ part(CLASS) }, outside)), "P06@0.28",
    "a text mostly outside the box does not count")

local label = { label = "P06", kind = "ocr", confidence = 0.9, x = 0.45, y = 0.05, width = 0.3, height = 0.3 }
local text_kept = wrapper.detections({ part({ text = "P06" }) }, { yolo(0.5), label, ocr("P06", 0.9) })
t.eq(labels(text_kept), "P06@0.45", "a text wrapper consumes the class box it holds and drops the lone read")

local reduced = wrapper.expected({ part(CLASS) })[1]
t.eq(#reduced.ocr_values, 0, "a class-wrapped part reads no text itself")
t.eq(reduced.yolo_class_refs[1].class_id, "c-lower", "a class-wrapped part expects its wrapper")
local reduced_text = wrapper.expected({ part({ text = "P06" }) })[1]
t.eq(#reduced_text.yolo_classes, 0, "a text-wrapped part expects no class")
t.eq(reduced_text.ocr_values[1], "P06", "a text-wrapped part expects its wrapper text")
local lone = part(CLASS)
lone.ocr_values = {}
t.eq(#wrapper.expected({ lone })[1].yolo_classes, 1, "a wrapper with nothing to hold changes nothing")

local function why(dets)
    local found = wrapper.lacks({ part(CLASS) }, dets)[ID] or {}
    local out = {}
    for _, l in ipairs(found) do
        out[#out + 1] = l.kind .. ":" .. l.label .. ":" .. l.why
    end
    return table.concat(out, ",")
end
t.eq(why(scene), "", "a held wrapper lacks nothing")
t.eq(why({ yolo(0.1), ocr("X04", 0.15) }), "text:P06:unseen", "an unread text is unseen")
t.eq(why({ yolo(0.1), ocr("P06", 0.8) }), "text:P06:outside", "a text read away from the box is outside")
t.eq(why({ ocr("P06", 0.8) }), "class:test_1_lower:unseen", "no wrapper box says the wrapper is unseen")

local function inspect(dets, routines)
    return json.decode(json.encode(live({
        expected = { part(CLASS, routines) },
        frames = { { t = 0, detections = dets } },
        presence = true,
        spatial = false,
        frame_aspect = 1,
    })))
end

local pass = inspect(scene).presence
t.eq(#pass.objects, 1, "a wrapped part is one row")
t.eq(pass.objects[1].status, "matched", "the part counts when its text is inside a class box")
t.eq(#(pass.extras or {}), 0, "the class box that misses the text is not an extra")

local missed = inspect({ yolo(0.1), ocr("X04", 0.15), ocr("P06", 0.8) })
t.eq(missed.presence.objects[1].status, "missing", "the part is missing when no class box holds its text")
t.eq(missed.lacks[ID][1].why, "outside", "live says why the part is missing")

if not t.summary("wrapper") then
    os.exit(1)
end
