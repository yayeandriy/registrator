-- Exercises `report_catalog.lua` (catalog-named extras) and the
-- `report_rules.lua` helpers it leans on.

local script_dir = (arg[0]):match("(.*/)")
local lua_dir = script_dir .. "../lua/"
local t = dofile(script_dir .. "asserts.lua")
normalisator = dofile(lua_dir .. "normalisator.lua")
ocr_window = dofile(lua_dir .. "ocr_window.lua")
report_rules = dofile(lua_dir .. "report_rules.lua")
local catalog = dofile(lua_dir .. "report_catalog.lua")
local rules = report_rules

local function box(label, x, y, conf)
    return { label = label, x = x, y = y, width = 0.1, height = 0.1, confidence = conf or 0.8, kind = "yolo" }
end

-- Rules.
t.eq(rules.alnum("р-06 ab"), "P06AB", "lookalikes fold, punctuation drops")
t.eq(rules.compact_label("0 2\n2 0\nX04"), "X04", "first letter-bearing line")
t.eq(rules.compact_label("12\n34"), "12", "digits only: first line")
t.eq(rules.class_key("  Pin Side "), "pin_side", "class key")
t.eq(rules.is_wrong_object("pin-side", { "pin-side" }, "button"), true, "other class is wrong")
t.eq(rules.is_wrong_object("pin-side", { "pin-side" }, "pin-side"), false, "own class is right")
t.eq(rules.is_wrong_object("pin-side", { "pin-side" }, nil), false, "no hit is not wrong")
t.eq(rules.is_wrong_object("Pin Side", {}, "pin_side"), false, "the name counts as a class")
t.eq(rules.pick_seen("AB123", {}, {}, { "12", "AB123", "Q7" }), "Q7", "skip blip and the text itself")
t.is_nil(rules.pick_seen("AB", {}, {}, { "7" }), "single char is a blip")
t.eq(rules.bucket_for_status("mispositioned_misrotated"), "misplaced", "both misses misplace")
t.eq(rules.canonical_id("pin#ocr#AB"), "pin", "canonical id")
t.eq(rules.same_placement("pin#zone", "pin"), true, "suffix is the same placement")
t.eq(rules.same_placement("", ""), false, "empty ids never match")
local mm = rules.spatial_mismatches("mispositioned_misrotated", 0.01, 0.2)
t.eq(#mm, 2, "both mismatches listed")
t.is_nil(mm[1].delta_mm, "noise millimetres omitted")
t.is_nil(mm[2].delta_deg, "noise degrees omitted")

-- Instances: one class is one box; two classes pair globally nearest.
local one = catalog.instances({ "stamp" }, { box("stamp", 0, 0), box("pin", 1, 1) })
t.eq(#one, 1, "one-class instance")
local inst, left = catalog.instances({ "a", "b" }, {
    box("a", 0, 0), box("b", 0.12, 0), box("a", 0.5, 0), box("b", 0.6, 0), box("b", 3, 3),
})
t.eq(#inst, 2, "two pairs")
t.eq(#left, 1, "far b stays")
t.eq(inst[1][1].x, 0.5, "closest pair first")
local tri = catalog.instances({ "a", "b", "c" }, { box("a", 0, 0), box("b", 0.1, 0), box("c", 0.2, 0), box("a", 2, 2) })
t.eq(#tri, 1, "greedy three-class instance")

-- Score: a unique code inside the instance wins over a shared one.
local group = {
    { id = "d07", display_name = "Test D07", yolo_classes = { "stamp" }, ocr_values = { "D07" } },
    { id = "d08", display_name = "Test D08", yolo_classes = { "stamp" }, ocr_values = { "D08" } },
}
local ocr = { { label = "D07", x = 0.02, y = 0.02, width = 0.05, height = 0.05, kind = "ocr" } }
t.eq(catalog.score(group[1], { box("stamp", 0, 0) }, ocr, group), 10, "unique code inside")
t.eq(catalog.score(group[2], { box("stamp", 0, 0) }, ocr, group), 0, "other code missing")
t.eq(catalog.score({ ocr_values = {} }, { box("stamp", 0, 0) }, {}, {}), 1, "class-only accepts")

-- Extras: named from the catalog, unclaimed surplus by class, non-profile ignored.
local keys = { stamp = true }
local named = catalog.extras({ box("stamp", 0, 0, 0.7), box("stamp", 0.5, 0.5, 0.9), box("chimney", 0.9, 0.9) }, ocr, group, keys)
t.eq(#named, 2, "two stamps, chimney ignored")
t.eq(named[1].name, "Test D07", "catalog name from the code")
t.eq(named[1].bucket, "extra", "extra bucket")
t.eq(named[2].name, "stamp", "unread stamp keeps its class")
t.eq(named[2].id, "extra-stamp-0.5000-0.5000", "plain extra id")
t.eq(#catalog.extras({ box("stamp", 0, 0) }, {}, {}, {}), 0, "no profile class, no extra")

if not t.summary("report_catalog") then
    os.exit(1)
end
