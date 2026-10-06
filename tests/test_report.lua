-- Exercises `report.lua` + `report_rules.lua` + `report_zones.lua`
-- through the composed session host (ported from the iOS sheet tests).

local script_dir = (arg[0]):match("(.*/)")
local lua_dir = script_dir .. "../lua/"
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(lua_dir .. "json.lua")
local host = dofile(script_dir .. "compose_session.lua")(lua_dir)

local function call(op, args)
    return json.decode(host(json.encode({ module = "report", op = op, args = args })))
end

local function ref(id, x, y, extra)
    local o = { id = id, name = id, spatial = true, boundary = { x = x, y = y, width = 2, height = 2 } }
    for k, v in pairs(extra or {}) do
        o[k] = v
    end
    return o
end

local function ids(list)
    local out = {}
    for i, e in ipairs(list) do
        out[i] = e.id
    end
    return table.concat(out, ",")
end

local function field(list, key)
    local out = {}
    for i, e in ipairs(list) do
        out[i] = tostring(e[key])
    end
    return table.concat(out, ",")
end

local function spatial(objects)
    return { objects = objects, extra_detections = {}, score = 0, matched = 0, total = #objects, extra = 0 }
end

-- The anchor search reports itself and no rows.
local searching = call("build", { anchor_searching = true, expected = { ref("block", 0, 0, { is_anchor = true }) } })
t.eq(searching.awaiting_anchor, true, "search awaits the anchor")
t.eq(#searching.entries, 0, "no row means anything without the anchor")
t.eq(searching.no_expectations, false, "the profile does expect placements")

-- No placements: an authoring gap is "no anchor", otherwise "no expectations".
local empty = call("build", { expected = {}, profile_objects = { ref("pin", 0, 0) }, anchor_count = 0 })
t.eq(empty.no_anchor, true, "spatial without a tip is no anchor")
t.eq(empty.no_expectations, false, "no anchor is not no expectations")
t.eq(call("build", { expected = {} }).no_expectations, true, "an empty profile expects nothing")
t.eq(call("no_anchor", { objects = { ref("pin", 0, 0) }, anchor_count = 1 }).no_anchor, false, "a zone tip counts")

-- Zones: tip, then members, then orphans.
local zone_input = {
    expected = { ref("tip", 0, 0, { is_anchor = true }), ref("inside", 2, 2), ref("orphan", 20, 20) },
    spatial = spatial({
        { id = "orphan", yolo_class = "Orphan", status = "matched" },
        { id = "inside", yolo_class = "Inside", status = "matched" },
        { id = "tip", yolo_class = "Tip", status = "matched" },
    }),
    names = { { id = "tip", name = "Tip" } },
    zones = { { object_id = "tip", hex = "#38bdf8" } },
    zone_hits = { { id = "tip", zones = { "tip" } }, { id = "inside", zones = { "tip" } } },
}
local zoned = call("build", zone_input)
t.eq(field(zoned.sections, "id"), "tip,other", "zone section then other")
local tip_rows = {}
for _, i in ipairs(zoned.sections[1].entries) do
    tip_rows[#tip_rows + 1] = zoned.entries[i]
end
t.eq(field(tip_rows, "name"), "Tip,Inside", "tip then members")
t.eq(tip_rows[1].is_zone_tip, true, "tip row is the tip")
t.eq(zoned.sections[1].hex, "#38bdf8", "zone carries its color")
t.eq(zoned.entries[zoned.sections[2].entries[1]].name, "Orphan", "orphan under other")

-- Two zones: an OK placement outside both stays off; failures stay.
local two = call("build", {
    expected = { ref("block", 0, 0, { is_anchor = true }), ref("pin-a", 8, 2), ref("square", 42, 0, { is_anchor = true }),
        ref("pin-b", 50, 2), ref("orphan", 80, 80), ref("stray", 90, 90) },
    spatial = spatial({
        { id = "block", yolo_class = "block", status = "matched" },
        { id = "pin-a", yolo_class = "pin-side", status = "mispositioned" },
        { id = "square", yolo_class = "square", status = "matched" },
        { id = "pin-b", yolo_class = "pin-side", status = "mispositioned" },
        { id = "orphan", yolo_class = "pin-side", status = "missing" },
        { id = "stray", yolo_class = "stray", status = "matched" },
    }),
    zones = { { object_id = "block", hex = "#fbbf24" }, { object_id = "square", hex = "#38bdf8" } },
    zone_hits = { { id = "pin-a", zones = { "block" } }, { id = "pin-b", zones = { "square" } } },
})
t.eq(field(two.sections, "id"), "block,square,other", "two zones then failures")
t.eq(#two.sections[1].entries, 2, "block zone has tip + pin")
t.eq(two.entries[two.sections[3].entries[1]].id, "orphan", "missed orphan kept")
local stray = false
for _, e in ipairs(two.entries) do
    stray = stray or e.id == "stray"
end
t.eq(stray, false, "out-of-zone OK dropped")
t.eq(two.entries[two.sections[1].entries[2]].id, "pin-a#block", "member id carries its zone")

-- A placement inside two zones is listed under each, even with a matched hit.
local shared = call("build", {
    expected = { ref("left", 0, 0, { is_anchor = true }), ref("right", 6, 6, { is_anchor = true }), ref("shared", 3, 3) },
    spatial = spatial({
        { id = "left", status = "matched" }, { id = "right", status = "matched" },
        { id = "shared", status = "matched", matched_label = "shared", matched_confidence = 0.9 },
    }),
    names = { { id = "left", name = "Left" }, { id = "right", name = "Right" }, { id = "shared", name = "Shared" } },
    zones = { { object_id = "left", hex = "#fbbf24" }, { object_id = "right", hex = "#38bdf8" } },
    zone_hits = { { id = "shared", zones = { "left", "right" } }, { id = "right", zones = { "left" } } },
})
t.eq(field(shared.sections, "id"), "left,right", "both zones")
t.eq(#shared.sections[1].entries + #shared.sections[2].entries, 4, "shared appears twice")

-- Result-pane failures: promote an OK row, add an omitted one, never duplicate.
local mismatched = { id = "pin", yolo_class = "pin-side", status = "mismatched", matched_label = "button", matched_confidence = 0.88 }
local promoted = call("build", {
    expected = { ref("pin", 0, 0) },
    presence = { objects = { { id = "pin", yolo_classes = { "pin-side" }, status = "matched", match_kind = "yolo",
        matched_label = "pin-side", matched_confidence = 0.99 } }, extra_detections = {}, score = 1, matched = 1, total = 1, extra = 0 },
    validation_objects = { mismatched },
    names = { { id = "pin", name = "pin-side" } },
})
t.eq(promoted.entries[1].bucket, "incorrect_object", "ok promoted to incorrect object")
t.eq(promoted.entries[1].matched_label, "button", "the wrong class is shown")
t.eq(#promoted.entries, 1, "promoted, not added")

local added = call("build", {
    expected = { ref("block", 0, 0), ref("pin", 4, 0) },
    spatial = spatial({ { id = "block", yolo_class = "block", status = "matched" } }),
    validation_objects = { mismatched },
    names = { { id = "pin", name = "pin-side" } },
})
t.eq(field(added.entries, "bucket"), "ok,incorrect_object", "omitted failure added")

local other = { id = "other-id", yolo_class = "pin-side", status = "mismatched", matched_label = "button", matched_confidence = 0.91 }
local once = call("build", {
    expected = { ref("pin", 0, 0) },
    spatial = spatial({ { id = "pin", yolo_class = "pin-side", status = "mismatched", matched_label = "button",
        matched_confidence = 0.91 } }),
    validation_objects = { other },
    names = { { id = "pin", name = "pin-side" } },
})
t.eq(#once.entries, 1, "same failure on the same box is one row")

-- Millimetres ride on the misplaced row; inside the threshold too.
local moved = call("build", {
    expected = { ref("pin", 0, 0) },
    spatial = spatial({ { id = "pin", yolo_class = "pin-side", status = "mispositioned", delta_position = 12.4 } }),
})
t.eq(moved.entries[1].bucket, "misplaced", "mispositioned is misplaced")
t.eq(moved.entries[1].mismatches[1].expected, "moved", "moved mismatch")
t.close(moved.entries[1].mismatches[1].delta_mm, 12.4, 1e-9, "carries the millimetres")
local inside = call("build", {
    expected = { ref("pin", 0, 0) },
    spatial = spatial({
        { id = "pin", status = "matched", delta_position = 3.2 },
        { id = "flat", status = "matched", delta_position = 0.02 },
        { id = "turn", status = "misrotated", delta_rotation = -8.4 },
    }),
})
local by_id = {}
for _, e in ipairs(inside.entries) do
    by_id[e.id] = e
end
t.eq(by_id.pin.bucket, "ok", "inside the threshold is ok")
t.close(by_id.pin.mismatches[1].delta_mm, 3.2, 1e-9, "ok still carries a measurable move")
t.eq(#by_id.flat.mismatches, 0, "noise is no move")
t.close(by_id.turn.mismatches[1].delta_deg, 8.4, 1e-9, "rotation magnitude")

-- Presence: a wrong-class hit on a missing slot is an incorrect object.
local function presence_row(status, hit)
    return { objects = { { id = "pin", yolo_classes = { "pin-side" }, status = status, match_kind = "yolo", matched_label = hit,
        matched_confidence = hit and 0.86 or nil } }, extra_detections = {}, score = 0, matched = 0, total = 1, extra = 0 }
end
local function bucket_of(p)
    return call("build", { expected = { ref("pin", 0, 0) }, presence = p, names = { { id = "pin", name = "pin-side" } } }).entries[1].bucket
end
t.eq(bucket_of(presence_row("missing", "button")), "incorrect_object", "wrong class is incorrect object")
t.eq(bucket_of(presence_row("missing", "pin-side")), "missed", "own class is a miss")
t.eq(bucket_of(presence_row("missing", nil)), "missed", "no hit is a miss")

-- OCR: a wrong read is an incorrect value; a digit blip is not.
local ocr_presence = { objects = {
    { id = "lbl", ocr_values = { "AB12" }, status = "missing", match_kind = "ocr" },
    { id = "sib", ocr_values = { "CD34" }, status = "missing", match_kind = "ocr" },
}, extra_detections = {}, score = 0, matched = 0, total = 2, extra = 0 }
local wrong = call("build", { expected = { ref("lbl", 0, 0) }, presence = ocr_presence, ocr_labels = { "2", "CD34", "XY99" } })
local rows = {}
for _, e in ipairs(wrong.entries) do
    rows[e.id] = e
end
t.eq(rows["lbl#ocr#AB12"].bucket, "incorrect_values", "a foreign-free read is the wrong value")
t.eq(rows["lbl#ocr#AB12"].mismatches[1].seen, "XY99", "sibling code and blip skipped")
t.eq(rows["sib#ocr#CD34"].bucket, "incorrect_values", "sibling sees the other code")

-- A placed text Presence did not score still gets a row.
local placed = call("build", {
    expected = { { id = "tag", name = "Tag", presence = true, ocr_values = { "Z9" }, boundary = { x = 0, y = 0, width = 1, height = 1 } } },
    presence = { objects = {}, extra_detections = {}, score = 0, matched = 0, total = 0, extra = 0 },
    ocr_labels = { "lot z9" },
    catalog = { { id = "c", display_name = "Zed", ocr_values = { "Z9" }, yolo_classes = {} } },
})
t.eq(placed.entries[1].id, "tag#ocr#Z9", "missing OCR row id")
t.eq(placed.entries[1].name, "Zed", "named from the catalog")
t.eq(placed.entries[1].bucket, "ok", "read on camera is ok")

-- Extras: only surplus of a profile class; loose-match quota absorbs it.
local function extras_for(loose)
    return call("build", {
        expected = { { id = "blk", name = "block", presence = true, yolo_classes = { "block" }, loose_match = loose,
            boundary = { x = 0, y = 0, width = 1, height = 1 } } },
        presence = { objects = { { id = "blk", yolo_classes = { "block" }, status = "matched", match_kind = "yolo" } },
            extra_detections = {
                { label = "block", confidence = 0.8, x = 0.1, y = 0.2, width = 0.1, height = 0.1, kind = "yolo" },
                { label = "chimney", confidence = 0.8, x = 0.5, y = 0.2, width = 0.1, height = 0.1, kind = "yolo" },
            }, score = 1, matched = 1, total = 1, extra = 2 },
    }).entries
end
local strict = extras_for(false)
t.eq(field(strict, "bucket"), "ok,extra", "surplus block is extra, chimney ignored")
t.eq(strict[2].id, "extra-block-0.1000-0.2000", "extra id from the box")
t.eq(#extras_for(true), 1, "loose match swallows the surplus")

-- Both routines: shared id keeps the Spatial outcome and marks both.
local both = call("build", {
    expected = { ref("pin", 0, 0, { presence = true, yolo_classes = { "pin" } }), ref("cap", 3, 0) },
    presence = { objects = { { id = "pin", yolo_classes = { "pin" }, status = "matched", match_kind = "yolo" } },
        extra_detections = {}, score = 1, matched = 1, total = 1, extra = 0 },
    spatial = spatial({ { id = "pin", yolo_class = "pin", status = "misrotated" }, { id = "cap", yolo_class = "cap", status = "matched" } }),
})
local merged = {}
for _, e in ipairs(both.entries) do
    merged[e.id] = e
end
t.eq(merged.pin.routine, "both", "shared id is both")
t.eq(merged.pin.bucket, "misplaced", "spatial outcome wins")
t.eq(merged.cap.routine, "spatial", "spatial-only row")
t.eq(ids(both.entries), "cap,pin", "sorted by name")

-- Settled verdict rows stand in for the result pane's objects.
local from_rows = call("build", {
    expected = { ref("pin", 0, 0), ref("cap", 3, 0) },
    spatial = spatial({ { id = "pin", yolo_class = "pin", status = "matched" }, { id = "cap", yolo_class = "cap", status = "matched" } }),
    names = { { id = "pin", name = "Pin" }, { id = "cap", name = "Cap" } },
    verdict_rows = {
        { object_id = "pin", label = "pin", status = "misrotated", delta_rotation = 12 },
        { object_id = "cap", label = "cap", status = "pending" },
        { label = "nut", status = "extra" },
    },
})
local by_id = {}
for _, e in ipairs(from_rows.entries) do
    by_id[e.id] = e
end
t.eq(by_id.pin.bucket, "misplaced", "a verdict failure overrides a Spatial OK")
t.eq(by_id.pin.mismatches[1].delta_deg, 12, "rotation delta carried")
t.eq(by_id.cap.bucket, "missed", "an unsettled row reads as missing")
t.eq(#from_rows.entries, 2, "verdict extras are not pane objects")

-- Placeholders: Presence rows first, Spatial when no Presence row exists.
local ph = call("placeholder", {
    expected = { { id = "a", presence = true, yolo_classes = { "pin" }, ocr_values = { "X1" }, boundary = {},
        children = { { id = "b", spatial = true, yolo_class = "cap", boundary = {} } } } },
    presence = false, spatial = true,
})
t.eq(ph.kind, "presence", "presence placement wins")
t.eq(field(ph.presence.objects, "match_kind"), "yolo,ocr", "yolo + text split; a Spatial-only child has no Presence row")
local sp = call("placeholder", {
    expected = { { id = "g", boundary = {}, children = { { id = "s1", spatial = true, yolo_classes = { "cap" }, boundary = {},
        children = { { id = "s2", spatial = true, boundary = {} } } } } } },
    presence = false, spatial = true,
})
t.eq(sp.kind, "spatial", "spatial-only board")
t.eq(ids(sp.spatial.objects), "s1,s2", "nested spatial rows in tree order")
t.eq(sp.spatial.objects[1].yolo_class, "cap", "class from the plural list")

if not t.summary("report") then
    os.exit(1)
end
