-- Exercises `registration.lua` the same way a JSON-boundary host (e.g. a
-- future Swift/C-Lua harness) would: fixture JSON -> `json.decode` ->
-- the script -> `json.encode` -> `json.decode` again, then assert on the
-- round-tripped result. Mirrors a subset of `inventor-api`'s own
-- `registration.rs` unit tests so both hosts are checked against
-- equivalent scenarios.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
local registration = dofile(script_dir .. "../lua/registration.lua")
local t = dofile(script_dir .. "asserts.lua")

local function read_file(path)
    local f = assert(io.open(path, "r"))
    local contents = f:read("*a")
    f:close()
    return contents
end

local function run_fixture(name)
    local raw = read_file(script_dir .. "fixtures/" .. name)
    local input = json.decode(raw)
    local result = registration(input)
    -- Round-trip through JSON exactly as a real Swift-hosted call would,
    -- to prove the result itself is JSON-safe (no NaN/inf, no stray Lua
    -- values `json.encode` can't represent) — not just that the Lua
    -- function returned something.
    return json.decode(json.encode(result))
end

-- registration_single_anchor.json: a single 10x10 board-unit anchor,
-- detected as a 0.2x0.2 normalized box at (0.4, 0.4) — same scenario as
-- `registration.rs`'s own `single_anchor_maps_its_own_center_onto_the_detection`.
local result = run_fixture("registration_single_anchor.json")
t.eq(result.matched_anchors, 1, "single anchor: matched_anchors")
t.not_nil(result.transform, "single anchor: transform is present")
t.close(result.transform.a, 0.02, 1e-9, "single anchor: transform.a (x scale)")
t.close(result.transform.d, 0.02, 1e-9, "single anchor: transform.d (y scale)")
t.close(result.transform.b, 0.0, 1e-9, "single anchor: transform.b (no shear)")
t.close(result.transform.c, 0.0, 1e-9, "single anchor: transform.c (no shear)")
t.eq(#result.registered_detections, 1, "single anchor: one registered detection")
t.close(result.registered_detections[1].x, 0.0, 1e-9, "single anchor: registered x")
t.close(result.registered_detections[1].y, 0.0, 1e-9, "single anchor: registered y")
t.close(result.registered_detections[1].width, 10.0, 1e-9, "single anchor: registered width")
t.close(result.registered_detections[1].height, 10.0, 1e-9, "single anchor: registered height")
t.is_nil(result.error, "single anchor: no error")

-- No anchor in the layout is ever detected -> registration must fail
-- gracefully with a zero score, not error out.
local no_anchor_result = (function()
    local input = {
        detections = { { t = 0.0, detections = { { label = "button", confidence = 0.9, x = 0.1, y = 0.1, width = 0.2, height = 0.2 } } } },
        expected = { { id = "8e7f6b3a-0000-4000-8000-00000000000a", yolo_classes = { "connector" }, boundary = { x = 0.0, y = 0.0, width = 10.0, height = 10.0 }, rotation = 0.0, is_anchor = true, children = {} } },
    }
    return json.decode(json.encode(registration(input)))
end)()
t.eq(no_anchor_result.matched_anchors, 0, "no anchor: matched_anchors is zero")
t.eq(no_anchor_result.score, 0.0, "no anchor: score is zero")
t.eq(#no_anchor_result.registered_detections, 0, "no anchor: no registered detections")
t.not_nil(no_anchor_result.error, "no anchor: error is present")

-- Two anchors 10 board-units apart on the x-axis, detected 0.2 apart on
-- the y-axis in-frame -> a 90 degree rotation + uniform 0.02 scale (same
-- scenario as `registration.rs`'s own `two_anchors_recover_rotation_and_scale`).
local two_anchor_result = (function()
    local input = {
        detections = {
            {
                t = 0.0,
                detections = {
                    { label = "anchor_a", confidence = 0.9, x = 0.4, y = 0.4, width = 0.02, height = 0.02 },
                    { label = "anchor_b", confidence = 0.9, x = 0.4, y = 0.6, width = 0.02, height = 0.02 },
                },
            },
        },
        expected = {
            { id = "8e7f6b3a-0000-4000-8000-00000000000b", yolo_classes = { "anchor_a" }, boundary = { x = 0.0, y = 0.0, width = 1.0, height = 1.0 }, rotation = 0.0, is_anchor = true, children = {} },
            { id = "8e7f6b3a-0000-4000-8000-00000000000c", yolo_classes = { "anchor_b" }, boundary = { x = 10.0, y = 0.0, width = 1.0, height = 1.0 }, rotation = 0.0, is_anchor = true, children = {} },
        },
    }
    return json.decode(json.encode(registration(input)))
end)()
t.eq(two_anchor_result.matched_anchors, 2, "two anchors: matched_anchors")
t.close(two_anchor_result.transform.a, 0.0, 1e-6, "two anchors: transform.a (90deg rotation)")
t.close(two_anchor_result.transform.d, 0.0, 1e-6, "two anchors: transform.d (90deg rotation)")
t.close(two_anchor_result.transform.c, 0.02, 1e-6, "two anchors: transform.c")
t.close(two_anchor_result.transform.b, -0.02, 1e-6, "two anchors: transform.b")

if not t.summary("registration") then
    os.exit(1)
end
