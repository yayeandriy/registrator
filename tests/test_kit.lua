-- kit.lua: profile placements + components + classes → live scoring inputs.

local script_dir = (arg[0]):match("(.*/)") or "./"
local kit = dofile(script_dir .. "../lua/kit.lua")
local json = dofile(script_dir .. "../lua/json.lua")
local t = dofile(script_dir .. "asserts.lua")

local classes = {
    { id = "c-duck", label = "duck", vision_model_id = "m1" },
    { id = "c-bolt", label = "Bolt", vision_model_id = "m2" },
    { id = "c-free", label = "nut", vision_model_id = "" },
}

local components = {
    { id = "k-duck", inspection_profile_id = "p1", name = "Duck", class_ids = { "c-duck", "c-duck" },
      text_values = {}, symmetry = "180", thresholds = { distance = 4 } },
    { id = "k-label", inspection_profile_id = "p1", name = "Label", class_ids = {},
      text_values = { " SN-1 ", "", "=serial", "{lot}" }, symmetry = "" },
    { id = "k-other", inspection_profile_id = "p2", name = "Elsewhere", class_ids = { "c-bolt" },
      text_values = {} },
    { id = "k-shared", inspection_profile_id = "", name = "Shared", class_ids = { "c-free" },
      text_values = {} },
}

local function placement(id, fields)
    local o = { id = id, name = "", component_ids = {}, routines = { "presence_validate" },
                x = 1, y = 2, width = 3, height = 4, children = {} }
    for k, v in pairs(fields or {}) do
        o[k] = v
    end
    return o
end

local out = kit({
    objects = {
        placement("duck", { component_ids = { "k-duck" }, children = {
            placement("label", { component_ids = { "k-label" }, name = "bolt" }),
        } }),
        placement("named", { name = "bolt" }),
        placement("loose", { name = "widget" }),
    },
    components = components,
    classes = classes,
    profile_id = "p1",
})

local duck = out.expected[1]
t.eq(#duck.yolo_classes, 1, "a repeated class is listed once")
t.eq(duck.yolo_classes[1], "duck", "classes come from the linked component")
t.eq(#duck.yolo_class_refs, 1, "class refs are unique by class")
t.eq(duck.yolo_class_refs[1].vision_model_id, "m1", "class refs carry their model")
t.eq(duck.vision_model_id, "m1", "the model comes from the linked classes")
t.eq(duck.symmetry, "180", "symmetry comes from the component")
t.eq(duck.thresholds.distance, 4, "thresholds come from the component")
t.is_nil(duck.thresholds.rotation, "an unset threshold stays unset")
t.eq(duck.x, 1, "geometry is kept")

local label = duck.children[1]
t.eq(#label.yolo_classes, 0, "a text-only part does not borrow a class from its name")
t.eq(#label.ocr_values, 1, "blank text and unfilled formulas are not read")
t.eq(label.ocr_values[1], "SN-1", "OCR values are trimmed")
t.eq(label.symmetry, "inf", "a blank symmetry falls back to any rotation")
t.is_nil(label.thresholds, "no thresholds when the component has none")
t.is_nil(label.vision_model_id, "no model without a class")

t.eq(out.expected[2].yolo_classes[1], "Bolt", "a bare name matches a class label case-insensitively")
t.eq(out.expected[3].yolo_classes[1], "widget", "an unknown name is kept as the class")

local drafted = kit({
    objects = { placement("duck", { component_ids = { "k-duck" } }) },
    components = components,
    classes = classes,
    draft = { component_id = "k-duck", thresholds = { rotation = 9 } },
})
t.eq(drafted.expected[1].thresholds.rotation, 9, "unsaved thresholds win for their component")
t.is_nil(drafted.expected[1].thresholds.distance, "the draft replaces the saved thresholds")

local ids = {}
for _, c in ipairs(out.catalog) do
    ids[#ids + 1] = c.id
end
t.eq(table.concat(ids, ","), "k-duck,k-label,k-shared", "the catalog keeps this profile's and shared components")
t.eq(#out.catalog[2].ocr_values, 3, "catalog text keeps every non-blank value")

t.eq(table.concat(out.needles, ","), "SN-1", "needles list each expected text once")

local nulls = kit(json.decode([[{
    "objects": [{ "id": "a", "name": null, "component_ids": null, "routines": [],
                  "x": 0, "y": 0, "width": 1, "height": 1, "children": null }],
    "components": [], "classes": [], "profile_id": null, "draft": null
}]]))
t.eq(#nulls.expected, 1, "null fields read as empty")
t.eq(#nulls.expected[1].yolo_classes, 0, "a nameless part has no class")

t.ok(out.presence, "a presence routine anywhere in the tree turns presence on")
t.ok(not out.spatial, "spatial stays off when presence is asked for and spatial is not")

local bare = kit({ objects = { placement("p", { routines = {} }) } })
t.ok(not bare.presence and bare.spatial, "a profile with no routine is checked for placement")

local nested = kit({ objects = { placement("p", { routines = {}, children = {
    placement("c", { routines = { "spatial_validate" } }),
} }) } })
t.ok(nested.spatial and not nested.presence, "a nested spatial routine turns spatial on")

local empty = kit({ objects = {} })
t.ok(not empty.presence and not empty.spatial, "an empty profile runs nothing")

local ok = pcall(kit, { op = "other" })
t.ok(not ok, "an unknown op raises")

if not t.summary("kit") then
    os.exit(1)
end
