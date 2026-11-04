local script_dir = (arg[0]):match("(.*/)") or "./"
local t = dofile(script_dir .. "asserts.lua")
local populate = dofile(script_dir .. "../lua/populate.lua")

local function box(label, x, y, w, h, extra)
    local d = { label = label, confidence = 0.9, x = x, y = y, width = w, height = h, kind = "yolo" }
    for k, v in pairs(extra or {}) do
        d[k] = v
    end
    return d
end

local classes = { { id = "c-pin", label = "pin" }, { id = "c-cap", label = "cap" } }

-- A linked class is reused; an unknown one becomes one new component.
local out = populate.place({
    detections = { box("pin", 0, 0, 10, 10), box("cap", 50, 0, 10, 10), box("cap", 80, 0, 10, 10) },
    components = { { id = "k1", name = "Pin", class_ids = { "c-pin" }, text_values = {} } },
    classes = classes,
})
t.eq(#out.placements, 3, "every box is placed")
t.eq(out.placements[1].component_id, "k1", "a class box is the component linked to its class")
t.eq(#out.new_components, 1, "one new component per unknown class")
t.eq(out.new_components[1].name, "cap", "a new component is named after its class")
t.eq(out.new_components[1].class_ids[1], "c-cap", "and linked to it")
t.eq(out.placements[2].new, 1, "placements name the new component by index")
t.eq(out.placements[3].new, 1, "the second cap reuses it")

-- Overlapping boxes collapse whatever their class; the confident one stays.
local overlap = populate.place({
    detections = {
        box("pin", 0, 0, 10, 10, { confidence = 0.5 }),
        box("cap", 1, 1, 10, 10, { confidence = 0.8 }),
    },
    components = {},
    classes = classes,
})
t.eq(#overlap.placements, 1, "overlapping boxes collapse class-agnostically")
t.eq(overlap.new_components[1].name, "cap", "the most confident box stays")

-- A class box holding text is the component with that text.
local texted = populate.place({
    detections = {
        box("pin", 0, 0, 40, 20),
        box("D268", 10, 5, 10, 5, { kind = "ocr" }),
    },
    components = {
        { id = "k1", name = "Pin", class_ids = { "c-pin" }, text_values = {} },
        { id = "k2", name = "Label", class_ids = {}, text_values = { "d268" } },
    },
    classes = classes,
})
t.eq(texted.placements[1].component_id, "k2", "text wins over the class")
t.eq(texted.placements[2].component_id, "k2", "the text box is that component too")

-- New text components keep the text; unlabeled boxes are skipped.
local fresh = populate.place({
    detections = { box("0900", 0, 0, 10, 5, { kind = "ocr" }), box("  ", 30, 30, 5, 5) },
    components = {},
    classes = classes,
})
t.eq(fresh.skipped, 1, "a box with no label is skipped")
t.eq(fresh.new_components[1].text_values[1], "0900", "a new text component keeps its text")
t.eq(#fresh.new_components[1].class_ids, 0, "with no class")

-- A name match catches a component not linked yet.
local named = populate.place({
    detections = { box("cap", 0, 0, 10, 10) },
    components = { { id = "k9", name = "CAP", class_ids = {}, text_values = {} } },
    classes = classes,
})
t.eq(named.placements[1].component_id, "k9", "a component named like the class is reused")

-- A box its component already has on the view is not placed again.
local again = populate.place({
    detections = { box("pin", 1, 1, 10, 10), box("pin", 60, 0, 10, 10) },
    components = { { id = "k1", name = "Pin", class_ids = { "c-pin" }, text_values = {} } },
    classes = classes,
    placed = {
        { component_id = "k1", x = 0, y = 0, width = 10, height = 10 },
        { component_id = "k7", x = 60, y = 0, width = 10, height = 10 },
    },
})
t.eq(again.duplicates, 1, "a box over its component's placement is a duplicate")
t.eq(#again.placements, 1, "only the new box is placed")
t.eq(again.placements[1].x, 60, "another component's box at the spot does not count")

-- With `only`, boxes go to those components alone, by class or text.
local chosen = populate.place({
    detections = {
        box("pin", 0, 0, 10, 10),
        box("cap", 50, 0, 10, 10),
        box("cap", 80, 0, 10, 10, { label = "0900", kind = "ocr" }),
    },
    components = {
        { id = "k1", name = "Pin", class_ids = { "c-pin" }, text_values = {} },
        { id = "k2", name = "cap", class_ids = { "c-cap" }, text_values = {} },
        { id = "k3", name = "Serial", class_ids = {}, text_values = { "0900" } },
    },
    classes = classes,
    only = { "k1", "k3" },
})
t.eq(#chosen.placements, 2, "only the chosen components are placed")
t.eq(chosen.placements[1].component_id, "k1", "a chosen component takes its class")
t.eq(chosen.placements[2].component_id, "k3", "and a chosen one its text")
t.eq(#chosen.new_components, 0, "nothing new is made")
t.eq(chosen.outside, 1, "a box of another component is outside")

local unnamed = populate.place({
    detections = { box("cap", 0, 0, 10, 10) },
    components = { { id = "k9", name = "CAP", class_ids = {}, text_values = {} } },
    classes = classes,
    only = { "k9" },
})
t.eq(#unnamed.placements, 0, "a name alone does not count with only")
t.eq(unnamed.outside, 1, "the box is outside")

if not t.summary("populate") then os.exit(1) end
