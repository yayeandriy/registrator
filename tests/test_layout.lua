-- Exercises `layout.lua` against the flatten-order steal that
-- `validation.lua` still does.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
local compose = dofile(script_dir .. "compose.lua")
local validation = compose.load("validation")
local layout = compose.load("layout")
local t = dofile(script_dir .. "asserts.lua")

local function expected_obj(id, class, x, y, w, h)
    return {
        id = id,
        yolo_classes = { class },
        boundary = { x = x, y = y, width = w, height = h },
        rotation = 0.0,
        is_anchor = false,
        children = {},
    }
end

local function det(label, x, y, w, h)
    return {
        label = label,
        confidence = 0.9,
        x = x,
        y = y,
        width = w,
        height = h,
        rotation = nil,
        kind = "yolo",
    }
end

-- Three 10×10 pins in a row. Detections sit on A and B; C's pin is
-- far to the right. Flatten order C, A, B so greedy validation steals.
local expected = {
    expected_obj("c", "pin-side", 40.0, 0.0, 10.0, 10.0),
    expected_obj("a", "pin-side", 0.0, 0.0, 10.0, 10.0),
    expected_obj("b", "pin-side", 20.0, 0.0, 10.0, 10.0),
}
local detections = {
    det("pin-side", 0.0, 0.0, 10.0, 10.0),
    det("pin-side", 20.0, 0.0, 10.0, 10.0),
    det("pin-side", 70.0, 0.0, 10.0, 10.0),
}

local raw = validation({
    expected = expected,
    registered_detections = detections,
    thresholds = { position = 8.0, rotation = 30.0 },
})

local function by_id(result, id)
    for _, o in ipairs(result.objects) do
        if o.id == id then
            return o
        end
    end
end

-- Greedy: C (first) claims B's pin at x=20 (dist 20) over the far box.
t.eq(by_id(raw, "c").status, "mispositioned", "greedy: C steals B")
t.eq(by_id(raw, "b").status, "mispositioned", "greedy: B gets the far leftover")

local laid = layout({
    expected = expected,
    registered_detections = detections,
    validation = raw,
    thresholds = { position = 8.0, rotation = 30.0 },
    enabled = true,
})

t.eq(by_id(laid, "a").status, "matched", "layout: A stays on its pin")
t.eq(by_id(laid, "b").status, "matched", "layout: B stays on its pin")
t.eq(by_id(laid, "c").status, "mispositioned", "layout: C owns the far miss")
t.eq(by_id(laid, "a").matched_x, 0.0, "layout: A matched box x")
t.eq(by_id(laid, "b").matched_x, 20.0, "layout: B matched box x")
t.eq(by_id(laid, "c").matched_x, 70.0, "layout: C matched box x")
t.eq(laid.matched, 2, "layout: two matched")
t.eq(laid.extra, 0, "layout: far box is assigned, not extra")

local off = layout({
    expected = expected,
    registered_detections = detections,
    validation = raw,
    enabled = false,
})
t.eq(by_id(off, "c").status, raw.objects[1].status, "off: passthrough")
t.eq(off.matched, raw.matched, "off: same matched count")

local missing = layout({
    expected = { expected_obj("a", "pin-side", 0.0, 0.0, 10.0, 10.0) },
    registered_detections = { det("widget", 50.0, 50.0, 5.0, 5.0) },
    validation = { objects = {}, extra_detections = {}, score = 0, matched = 0, total = 0, extra = 0 },
    enabled = true,
})
t.eq(missing.objects[1].status, "missing", "no same-class: missing")
t.eq(missing.extra, 1, "wrong-class leftover is extra when far")

-- Layout used to compare AABB top-edge vs the image axes (dRot=150.5)
-- and overwrite the lock-point frame. The lock vs itself is the origin.
local lock_expected = {
    {
        id = "lock",
        yolo_classes = { "block" },
        boundary = { x = 0.0, y = 0.0, width = 190.0, height = 290.0 },
        rotation = 0.0,
        is_anchor = true,
        children = {},
    },
}
local lock_det = {
    {
        label = "block",
        confidence = 0.91,
        x = 14.2,
        y = 74.8,
        width = 194.1,
        height = 289.9,
        rotation = 150.5,
        kind = "yolo",
    },
}
local lock_raw = validation({
    expected = lock_expected,
    registered_detections = lock_det,
    thresholds = { position = 30.0, rotation = 30.0 },
})
local lock_laid = layout({
    expected = lock_expected,
    registered_detections = lock_det,
    validation = lock_raw,
    thresholds = { position = 30.0, rotation = 30.0 },
    enabled = true,
})
t.eq(lock_laid.objects[1].status, "matched", "lock AABB heading is not a residual")
t.close(lock_laid.objects[1].delta_rotation, 0.0, 1e-6, "layout lock dRot is 0")
t.close(lock_laid.objects[1].delta_position, 0.0, 1e-6, "layout lock dPos is 0")

-- Identity is class_id first, then model + label, then label — the
-- `class_match` rule `validation.lua` claims with.
local function lay(objects, dets)
    return layout({
        expected = objects,
        registered_detections = dets,
        thresholds = { position = 8.0, rotation = 30.0 },
        enabled = true,
    })
end

local function with_ref(id, class_id, label)
    local o = expected_obj(id, label, 0.0, 0.0, 10.0, 10.0)
    o.yolo_class_refs = { { class_id = class_id, label = label } }
    return o
end

local renamed = det("pin_v2", 0.0, 0.0, 10.0, 10.0)
renamed.class_id = "c1"
t.eq(lay({ with_ref("a", "c1", "pin") }, { renamed }).objects[1].status, "matched", "layout: same class_id, renamed label matches")

local other_class = det("pin", 0.0, 0.0, 10.0, 10.0)
other_class.class_id = "c9"
local by_other = lay({ with_ref("a", "c1", "pin") }, { other_class }).objects[1]
t.eq(by_other.status, "mismatched", "layout: same label, other class_id is not a match")

local other_model = det("pin", 0.0, 0.0, 10.0, 10.0)
other_model.vision_model_id = "m2"
local scoped = expected_obj("a", "pin", 0.0, 0.0, 10.0, 10.0)
scoped.vision_model_id = "m1"
t.eq(lay({ scoped }, { other_model }).objects[1].status, "mismatched", "layout: same label on another model is not a match")

-- Two refs share a label; each pairs with its own class_id even when the
-- other box sits closer.
local swapped_a = det("pin", 20.0, 0.0, 10.0, 10.0)
swapped_a.class_id = "c1"
local swapped_b = det("pin", 0.0, 0.0, 10.0, 10.0)
swapped_b.class_id = "c2"
local ref_b = with_ref("b", "c2", "pin")
ref_b.boundary.x = 20.0
local by_class = lay({ with_ref("a", "c1", "pin"), ref_b }, { swapped_a, swapped_b })
t.eq(by_id(by_class, "a").matched_x, 20.0, "layout: a takes its class_id box, not the nearer one")
t.eq(by_id(by_class, "b").matched_x, 0.0, "layout: b takes its class_id box")

if not t.summary("layout") then
    os.exit(1)
end
