local script_dir = (arg[0]):match("(.*/)") or "./"
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(script_dir .. "../lua/json.lua")
local detect = dofile(script_dir .. "../lua/detect.lua")

local function box(x, y, w, h, confidence, kind)
    return { x = x, y = y, width = w, height = h, confidence = confidence, kind = kind }
end

local function collapse(boxes, iou)
    local wire = json.decode(json.encode({ boxes = boxes, iou = iou }))
    return detect.collapse(wire).keep
end

local same = collapse({
    box(0, 0, 10, 10, 0.6, "yolo"),
    box(1, 1, 10, 10, 0.9, "yolo"),
}, 0.45)
t.ok(not same[1] and same[2], "two models on one object keep the confident box")

local apart = collapse({
    box(0, 0, 10, 10, 0.6, "yolo"),
    box(50, 50, 10, 10, 0.9, "yolo"),
}, 0.45)
t.ok(apart[1] and apart[2], "boxes apart both stay")

local nested = collapse({
    box(0, 0, 10, 10, 0.9, "yolo"),
    box(3, 3, 6, 6, 0.8, "yolo"),
}, 0.3)
t.ok(nested[1] and nested[2], "a screw inside a plate is not swallowed by it")

local text = collapse({
    box(0, 0, 10, 10, 0.9, "yolo"),
    box(0, 0, 10, 10, 0.2, "ocr"),
    box(0, 0, 10, 10, 0.1, "ocr:gemma"),
}, 0.45)
t.ok(text[1] and text[2] and text[3], "text boxes always stay")

local quad = collapse({
    { corners = { { x = 0, y = 0 }, { x = 10, y = 0 }, { x = 10, y = 10 }, { x = 0, y = 10 } },
      x = 90, y = 90, width = 1, height = 1, confidence = 0.9 },
    box(0, 0, 10, 10, 0.5, "yolo"),
}, 0.45)
t.ok(quad[1] and not quad[2], "corners replace the box when present")

local edge = collapse({
    box(0, 0, 10, 10, 0.9),
    box(0, 0, 10, 5, 0.8),
}, 0.5)
t.ok(edge[1] and edge[2], "an IoU equal to the threshold does not drop")

t.eq(#collapse({}, 0.45), 0, "nothing to judge, nothing kept")

if not t.summary("detect") then os.exit(1) end
