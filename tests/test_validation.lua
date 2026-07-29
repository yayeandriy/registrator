-- Exercises `validation.lua` across the JSON boundary — see
-- `test_registration.lua`'s header comment for why. Covers the same
-- "matched / mismatched / missing / extra" taxonomy `validation.rs`'s
-- own doc comments describe.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
local validation = dofile(script_dir .. "../lua/validation.lua")
local t = dofile(script_dir .. "asserts.lua")

local function read_file(path)
    local f = assert(io.open(path, "r"))
    local contents = f:read("*a")
    f:close()
    return contents
end

local function find_object(objects, id)
    for _, o in ipairs(objects) do
        if o.id == id then
            return o
        end
    end
    return nil
end

-- validation_basic.json: "connector" (anchor) matched close by; "button"
-- has a nearby wrong-class detection ("switch") -> mismatched; "led" has
-- nothing nearby -> missing; a "capacitor" detection far from everything
-- explains no expected object -> extra_detections.
local raw = read_file(script_dir .. "fixtures/validation_basic.json")
local input = json.decode(raw)
local result = json.decode(json.encode(validation(input)))

t.eq(result.total, 3, "basic: total expected objects")
t.eq(result.matched, 1, "basic: matched count")
t.eq(result.extra, 1, "basic: extra detections count")
t.close(result.score, 1.0 / 3.0, 1e-9, "basic: score is matched/total")

local connector = find_object(result.objects, "8e7f6b3a-0000-4000-8000-000000000001")
t.not_nil(connector, "basic: connector object present")
t.eq(connector.status, "matched", "basic: connector status")

local button = find_object(result.objects, "8e7f6b3a-0000-4000-8000-000000000002")
t.not_nil(button, "basic: button object present")
t.eq(button.status, "mismatched", "basic: button status")
t.eq(button.matched_label, "switch", "basic: button matched_label")

local led = find_object(result.objects, "8e7f6b3a-0000-4000-8000-000000000003")
t.not_nil(led, "basic: led object present")
t.eq(led.status, "missing", "basic: led status")
t.is_nil(led.matched_label, "basic: missing object has no matched_label")

t.eq(#result.extra_detections, 1, "basic: one extra detection")
t.eq(result.extra_detections[1].label, "capacitor", "basic: extra detection label")

-- Rotation comparison: an expected object at 10 degrees, a registered
-- detection reporting 100 degrees -> 90 degree raw difference, but
-- `angle_diff_mod_180` folds it to 90 exactly at the boundary; nudge to
-- 95 degrees so it's unambiguously over a tight 30-degree threshold ->
-- "misrotated", not "matched", even though position lines up exactly.
local rotation_result = (function()
    local rot_input = {
        expected = {
            { id = "8e7f6b3a-0000-4000-8000-0000000000rr", yolo_classes = { "widget" }, boundary = { x = 0.0, y = 0.0, width = 4.0, height = 4.0 }, rotation = 10.0, is_anchor = false, children = {} },
        },
        registered_detections = {
            { label = "widget", confidence = 0.9, x = 0.0, y = 0.0, width = 4.0, height = 4.0, rotation = 95.0 },
        },
        thresholds = { position = 8.0, rotation = 30.0 },
    }
    return json.decode(json.encode(validation(rot_input)))
end)()
t.eq(rotation_result.objects[1].status, "misrotated", "rotation: misrotated despite exact position match")
t.close(rotation_result.objects[1].delta_rotation, 85.0, 1e-6, "rotation: delta_rotation folded correctly")

-- Two expected capacitors; only one detection. The matched sibling must not
-- make the empty slot read as mismatched ("wrong type").
local neighbor_result = (function()
    local n_input = {
        expected = {
            {
                id = "8e7f6b3a-0000-4000-8000-0000000000c3",
                yolo_classes = { "capacitor" },
                boundary = { x = 0.0, y = 0.0, width = 4.0, height = 4.0 },
                rotation = 0.0,
                is_anchor = false,
                children = {},
            },
            {
                id = "8e7f6b3a-0000-4000-8000-0000000000c4",
                yolo_classes = { "capacitor" },
                boundary = { x = 3.0, y = 0.0, width = 4.0, height = 4.0 },
                rotation = 0.0,
                is_anchor = false,
                children = {},
            },
        },
        registered_detections = {
            -- Center ~ (2, 2) — close to both slots; only one physical part.
            { label = "capacitor", confidence = 0.9, x = 0.0, y = 0.0, width = 4.0, height = 4.0 },
        },
        thresholds = { position = 8.0, rotation = 30.0 },
    }
    return json.decode(json.encode(validation(n_input)))
end)()
local c3 = find_object(neighbor_result.objects, "8e7f6b3a-0000-4000-8000-0000000000c3")
local c4 = find_object(neighbor_result.objects, "8e7f6b3a-0000-4000-8000-0000000000c4")
t.eq(c3.status, "matched", "neighbor: first capacitor matched")
t.eq(c4.status, "missing", "neighbor: empty slot is missing, not mismatched")
t.eq(neighbor_result.extra, 0, "neighbor: sole detection claimed by match")

if not t.summary("validation") then
    os.exit(1)
end
