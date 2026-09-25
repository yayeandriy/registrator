-- Exercises `layout.lua` against the flatten-order steal that
-- `validation.lua` still does.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
normalisator = dofile(script_dir .. "../lua/normalisator.lua")
matcher = dofile(script_dir .. "../lua/matcher.lua")
local validation = dofile(script_dir .. "../lua/validation.lua")
local layout = dofile(script_dir .. "../lua/layout.lua")
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

if not t.summary("layout") then
    os.exit(1)
end
