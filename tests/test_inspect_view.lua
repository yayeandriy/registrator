-- inspect_view.lua settle / scope / keep_detection.

local script_dir = (arg[0]):match("(.*/)") or "./"
local inspect_view = dofile(script_dir .. "../lua/inspect_view.lua")
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(script_dir .. "../lua/json.lua")

local function round(v)
    return json.decode(json.encode(v))
end

local function obj(view, class, anchor)
    return {
        id = "aaaaaaaa-0000-4000-8000-00000000000" .. class:sub(1, 1),
        profile_view_id = view,
        yolo_classes = { class },
        boundary = { x = 0, y = 0, width = 1, height = 1 },
        rotation = 0,
        is_anchor = anchor,
        children = {},
        routines = {},
    }
end

local A = "11111111-1111-4111-8111-111111111111"
local B = "22222222-2222-4222-8222-222222222222"

local objects = {
    obj(A, "front-qr", true),
    obj(A, "screw", false),
    obj(B, "back-qr", true),
    obj(B, "screw", false),
}

local map = round(inspect_view({ op = "unique_anchor_classes", objects = objects })).map
t.eq(map["front-qr"], A, "unique front-qr")
t.eq(map["back-qr"], B, "unique back-qr")
t.is_nil(map["screw"], "non-anchor screw is not unique")

local settled = round(inspect_view({
    op = "settle",
    objects = objects,
    detections = { { label = "back-qr", confidence = 0.9 } },
}))
t.eq(settled.view_id, B, "settle picks detected unique anchor")

local held = round(inspect_view({
    op = "settle",
    objects = {
        obj(A, "front-qr", true),
        obj(B, "back-qr", true),
    },
    detections = { { label = "screw", confidence = 0.9 } },
    latched = A,
}))
t.eq(held.view_id, A, "latch holds until the other unique anchor")

local single = round(inspect_view({
    op = "settle",
    objects = { obj(A, "matches", true), obj(A, "screw", false) },
    detections = {},
}))
t.eq(single.view_id, A, "single view auto-settles")

local scope = round(inspect_view({
    op = "scope",
    objects = objects,
    detections = { { label = "screw", confidence = 0.9 } },
}))
t.ok(scope.awaiting_view, "multi-view without unique hit awaits")
t.eq(#scope.objects, 2, "waiting set is the two anchors")

local keep = inspect_view({
    op = "keep_detection",
    kind = "ocr",
    view_class_ids = { A },
    view_models = { B },
})
t.ok(keep.keep, "OCR always kept")

local drop = inspect_view({
    op = "keep_detection",
    kind = "yolo",
    view_class_ids = { A },
    view_models = { B },
})
t.ok(not drop.keep, "unstamped YOLO dropped once the view has classes")

local C = "cccccccc-0000-4000-8000-000000000000"
local filtered = round(inspect_view({
    op = "filter_detections",
    view_class_ids = { A },
    view_models = { B },
    catalog_keys = { "Side Pin" },
    detections = {
        { kind = "yolo", label = "screw", class_id = A },
        { kind = "yolo", label = "screw", class_id = C },
        { kind = "yolo", label = "nut", vision_model_id = B },
        { kind = "yolo", label = "nut" },
        { kind = "ocr", label = "A264" },
        { kind = "yolo", label = " side pin ", class_id = C },
    },
}))
t.eq(json.encode(filtered.keep), json.encode({ true, false, true, false, true, true }),
    "batch keeps placed classes, view-model boxes, OCR and catalog extras")

local open = inspect_view({
    op = "filter_detections",
    detections = { { kind = "yolo", label = "anything" } },
})
t.ok(open.keep[1], "a view with no class or model refs keeps everything")

local derived = inspect_view({
    op = "filter_detections",
    objects = { { yolo_class_refs = { { class_id = A } }, children = {} } },
    detections = { { label = "a", class_id = A }, { label = "b", class_id = C } },
})
t.ok(derived.keep[1] and not derived.keep[2], "refs come from objects when ids are omitted")

local NIL = "00000000-0000-0000-0000-000000000000"

local function settle(objs, dets, latched, completed)
    local hits = {}
    for i, d in ipairs(dets) do
        hits[i] = type(d) == "table" and d or { label = d, confidence = 0.9 }
    end
    return round(inspect_view({
        op = "settle",
        objects = objs,
        detections = hits,
        latched = latched,
        completed = completed,
    })).view_id
end

local reuse = { obj(A, "matches", true), obj(B, "matches", false) }
t.eq(round(inspect_view({ op = "unique_anchor_classes", objects = reuse })).map.matches, A,
    "a non-anchor reuse keeps the anchor class unique")
t.eq(settle(reuse, { "matches" }), A, "non-anchor reuse does not block the anchor settle")

local twin = { obj(A, "matches", true), obj(B, "matches", true) }
t.is_nil(next(round(inspect_view({ op = "unique_anchor_classes", objects = twin })).map),
    "two anchors of one class are not unique")
t.is_nil(settle(twin, { "matches" }), "an ambiguous tip settles nothing")
t.eq(settle(twin, { "matches" }, A), A, "an ambiguous tip keeps the latch")

local pair = {
    obj(A, "square", true),
    obj(A, "block", true),
    obj(A, "pin-side", false),
    obj(B, "matches", true),
    obj(B, "pin-side", false),
}
t.eq(settle(pair, { "block" }), A, "either anchor of a view settles it")
t.eq(settle(pair, { "matches" }), B, "the other view's anchor settles it")
t.is_nil(settle(pair, { "pin-side" }), "a shared non-anchor settles nothing")

local tips = { obj(A, "front-qr", true), obj(B, "back-qr", true) }
t.eq(settle(tips, { "back-qr" }, A), B, "a visible tip steals the latched view")
t.eq(settle(tips, {
    { label = "front-qr", confidence = 0.4 },
    { label = "back-qr", confidence = 0.95 },
}), B, "the higher-confidence unique tip wins")
t.is_nil(settle(tips, { "front-qr" }, nil, { A }), "a completed view does not settle again")
t.is_nil(settle(tips, { "front-qr" }, A, { A }), "a completed latch is released")
t.eq(settle(tips, { { label = "back-qr", confidence = 0.5 } }, nil, { A }), B,
    "the remaining view still settles")

local shared = { obj(A, "shared-tip", true), obj(B, "shared-tip", true) }
t.is_nil(settle(shared, { "shared-tip" }, nil, { A }),
    "a completed view's tip class stops owning another view")

local waiting = round(inspect_view({
    op = "scope",
    objects = { obj(A, "front-qr", true), obj(A, "screw", false), obj(B, "back-qr", true) },
    detections = { { label = "screw", confidence = 0.9 } },
    completed = { A },
}))
t.ok(waiting.awaiting_view and #waiting.objects == 1, "the waiting set drops completed views")
t.eq(waiting.objects[1].profile_view_id, B, "only the open view's tip waits")

local unlabeled = round(inspect_view({
    op = "scope",
    objects = { obj(NIL, "matches", true) },
    detections = { { label = "matches", confidence = 0.9 } },
}))
t.ok(not unlabeled.awaiting_view and #unlabeled.objects == 1 and unlabeled.view_id == nil,
    "objects without a view score as one view")

local MA, MB = "aaaaaaaa-1111-4111-8111-111111111111", "bbbbbbbb-1111-4111-8111-111111111111"
local CA, CB = "aaaaaaaa-2222-4222-8222-222222222222", "bbbbbbbb-2222-4222-8222-222222222222"
local function with_ref(o, class_id, model)
    o.yolo_class_refs = { { class_id = class_id, label = "matches", vision_model_id = model } }
    return o
end
local models = { with_ref(obj(A, "matches", true), CA, MA), with_ref(obj(B, "matches", true), CB, MB) }
local unique = round(inspect_view({ op = "unique_anchor_classes", objects = models })).map
local n = 0
for _ in pairs(unique) do
    n = n + 1
end
t.eq(n, 2, "one label on two models is two classes")
t.eq(settle(models, { { label = "matches", confidence = 0.9, class_id = CB, vision_model_id = MB } }), B,
    "the stamped class settles its own view")

if not t.summary("inspect_view") then
    os.exit(1)
end
