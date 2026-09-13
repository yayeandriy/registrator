-- Exercises `ruller.lua` against a `validation.lua` result.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
normalisator = dofile(script_dir .. "../lua/normalisator.lua")
matcher = dofile(script_dir .. "../lua/matcher.lua")
local validation = dofile(script_dir .. "../lua/validation.lua")
local ruller = dofile(script_dir .. "../lua/ruller.lua")
local t = dofile(script_dir .. "asserts.lua")

local function expected_obj(id, class, x, y, w, h, thresholds, symmetry)
    return {
        id = id,
        yolo_classes = { class },
        boundary = { x = x, y = y, width = w, height = h },
        rotation = 0.0,
        is_anchor = true,
        children = {},
        thresholds = thresholds,
        symmetry = symmetry,
    }
end

local function det(label, x, y, w, h, rotation)
    return {
        label = label,
        confidence = 0.9,
        x = x,
        y = y,
        width = w,
        height = h,
        rotation = rotation,
        kind = "yolo",
    }
end

local function run(expected, detections, thresholds)
    local v = validation({
        expected = expected,
        registered_detections = detections,
        thresholds = thresholds,
    })
    return ruller({
        expected = expected,
        registered_detections = detections,
        validation = v,
        thresholds = thresholds,
    }), v
end

local ruled, raw = run(
    { expected_obj("a", "connector", 0.0, 0.0, 10.0, 10.0, nil) },
    { det("connector", 0.3, 0.3, 10.0, 10.0, nil) },
    nil
)
t.eq(ruled.objects[1].status, raw.objects[1].status, "unset: same as validation")
t.eq(ruled.matched, raw.matched, "unset: matched count")

ruled, raw = run(
    { expected_obj("a", "connector", 0.0, 0.0, 10.0, 10.0, { distance = 0.05 }) },
    { det("connector", 2.0, 0.0, 10.0, 10.0, nil) },
    nil
)
t.eq(raw.objects[1].status, "matched", "strict distance: validation still global-pass")
t.eq(ruled.objects[1].status, "mispositioned", "strict distance: ruller rejects")

ruled, raw = run(
    { expected_obj("a", "connector", 0.0, 0.0, 10.0, 10.0, { rotation = 5.0 }, "90") },
    { det("connector", 0.0, 0.0, 10.0, 10.0, 20.0) },
    { position = 8.0, rotation = 30.0 }
)
t.eq(raw.objects[1].status, "matched", "strict rotation: validation uses global 30")
t.eq(ruled.objects[1].status, "misrotated", "square symmetry: ruller uses 5")

ruled, raw = run(
    { expected_obj("a", "connector", 0.0, 0.0, 10.0, 10.0, { rotation = 5.0 }, "inf") },
    { det("connector", 0.0, 0.0, 10.0, 10.0, 20.0) },
    { position = 8.0, rotation = 30.0 }
)
t.eq(ruled.objects[1].status, raw.objects[1].status, "inf symmetry: ruller leaves rotation")

ruled, raw = run(
    { expected_obj("a", "connector", 0.0, 0.0, 10.0, 10.0, { rotation = 5.0 }, "0") },
    { det("connector", 0.0, 0.0, 10.0, 10.0, 20.0) },
    { position = 8.0, rotation = 30.0 }
)
t.eq(ruled.objects[1].status, raw.objects[1].status, "full symmetry: ruller leaves rotation")

ruled, raw = run(
    { expected_obj("a", "connector", 0.0, 0.0, 10.0, 10.0, {
        x = 1.0,
        y = 1.0,
        distance = 0.01,
    }) },
    { det("connector", 2.0, 0.0, 10.0, 10.0, nil) },
    nil
)
t.eq(ruled.objects[1].status, "matched", "axis set: leftover distance ignored")

ruled, raw = run(
    { expected_obj("a", "connector", 0.0, 0.0, 10.0, 10.0, nil) },
    { det("widget", 50.0, 50.0, 5.0, 5.0, nil) },
    nil
)
t.eq(ruled.objects[1].status, "missing", "missing left alone")
t.eq(ruled.extra, raw.extra, "extras unchanged")

-- Previous step assigned the far box. A neighbor sits closer to the
-- expected slot and would pass the relative distance — ruller must
-- still measure the assigned box.
local assigned = {
    objects = {
        {
            id = "c",
            yolo_classes = { "pin-side" },
            status = "mispositioned",
            matched_label = "pin-side",
            matched_confidence = 0.9,
            delta_position = 30.0,
            matched_x = 70.0,
            matched_y = 0.0,
            matched_width = 10.0,
            matched_height = 10.0,
        },
    },
    extra_detections = {},
    score = 0.0,
    matched = 0,
    total = 1,
    extra = 0,
}
ruled = ruller({
    expected = {
        expected_obj("c", "pin-side", 40.0, 0.0, 10.0, 10.0, { distance = 0.21 }),
    },
    registered_detections = {
        det("pin-side", 41.0, 0.0, 10.0, 10.0, nil),
        det("pin-side", 70.0, 0.0, 10.0, 10.0, nil),
    },
    validation = assigned,
})
t.eq(ruled.objects[1].status, "mispositioned", "ruller uses assigned far box")
t.eq(ruled.objects[1].matched_x, 70.0, "ruller keeps assigned coords")

if not t.summary("ruller") then
    os.exit(1)
end
