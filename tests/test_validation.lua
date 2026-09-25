-- Exercises `validation.lua` across the JSON boundary — see
-- `test_registration.lua`'s header comment for why. Covers the same
-- "matched / mismatched / missing / extra" taxonomy `validation.rs`'s
-- own doc comments describe.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
normalisator = dofile(script_dir .. "../lua/normalisator.lua")
matcher = dofile(script_dir .. "../lua/matcher.lua")
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

-- Lock-relative pose: the lock vs itself is the origin, so a large
-- absolute residual is still matched. A pin that rides with the lock
-- matches; a pin rotated vs the lock is misrotated.
local lock_frame = (function()
    local input = {
        expected = {
            {
                id = "8e7f6b3a-0000-4000-8000-0000000000lk",
                yolo_classes = { "block" },
                boundary = { x = 0.0, y = 0.0, width = 10.0, height = 4.0 },
                rotation = 0.0,
                is_anchor = true,
                children = {},
            },
            {
                id = "8e7f6b3a-0000-4000-8000-0000000000pn",
                yolo_classes = { "pin" },
                boundary = { x = 0.0, y = 20.0, width = 4.0, height = 10.0 },
                rotation = 0.0,
                is_anchor = false,
                children = {},
            },
        },
        registered_detections = {
            { label = "block", confidence = 0.9, x = 20.0, y = 0.0, width = 10.0, height = 4.0, rotation = 95.0 },
            { label = "pin", confidence = 0.9, x = 20.0, y = 20.0, width = 4.0, height = 10.0, rotation = 95.0 },
        },
        thresholds = { position = 8.0, rotation = 30.0 },
    }
    return json.decode(json.encode(validation(input)))
end)()
local lock_obj = find_object(lock_frame.objects, "8e7f6b3a-0000-4000-8000-0000000000lk")
local pin_ok = find_object(lock_frame.objects, "8e7f6b3a-0000-4000-8000-0000000000pn")
t.eq(lock_obj.status, "matched", "lock-frame: lock residual is the origin")
t.close(lock_obj.delta_position, 0.0, 1e-6, "lock-frame: lock delta_position is 0")
t.close(lock_obj.delta_rotation, 0.0, 1e-6, "lock-frame: lock delta_rotation is 0")
t.eq(pin_ok.status, "matched", "lock-frame: pin that rides with the lock matches")

-- AABB top-edge vs the image (150.5°) is not the lock-point transform.
local lock_aabb = (function()
    local input = {
        expected = {
            {
                id = "8e7f6b3a-0000-4000-8000-0000000000lk",
                yolo_classes = { "block" },
                boundary = { x = 0.0, y = 0.0, width = 190.0, height = 290.0 },
                rotation = 0.0,
                is_anchor = true,
                children = {},
            },
        },
        registered_detections = {
            { label = "block", confidence = 0.91, x = 14.2, y = 74.8, width = 194.1, height = 289.9, rotation = 150.5 },
        },
        thresholds = { position = 30.0, rotation = 30.0 },
    }
    return json.decode(json.encode(validation(input)))
end)()
t.eq(lock_aabb.objects[1].status, "matched", "lock AABB heading vs frame is not a residual")
t.close(lock_aabb.objects[1].delta_rotation, 0.0, 1e-6, "lock dRot is 0 in the point frame")
t.close(lock_aabb.objects[1].delta_position, 0.0, 1e-6, "lock dPos is 0 in the point frame")

local pin_rot = (function()
    local input = {
        expected = {
            {
                id = "8e7f6b3a-0000-4000-8000-0000000000lk",
                yolo_classes = { "block" },
                boundary = { x = 0.0, y = 0.0, width = 10.0, height = 4.0 },
                rotation = 0.0,
                is_anchor = true,
                children = {},
            },
            {
                id = "8e7f6b3a-0000-4000-8000-0000000000pn",
                yolo_classes = { "pin" },
                boundary = { x = 0.0, y = 20.0, width = 4.0, height = 10.0 },
                rotation = 0.0,
                is_anchor = false,
                children = {},
            },
        },
        registered_detections = {
            { label = "block", confidence = 0.9, x = 20.0, y = 0.0, width = 10.0, height = 4.0, rotation = 95.0 },
            { label = "pin", confidence = 0.9, x = 20.0, y = 20.0, width = 4.0, height = 10.0, rotation = 135.0 },
        },
        thresholds = { position = 8.0, rotation = 30.0 },
    }
    return json.decode(json.encode(validation(input)))
end)()
t.eq(find_object(pin_rot.objects, "8e7f6b3a-0000-4000-8000-0000000000lk").status, "matched", "lock-frame: lock still origin when pin is off")
t.eq(find_object(pin_rot.objects, "8e7f6b3a-0000-4000-8000-0000000000pn").status, "misrotated", "lock-frame: pin rotated vs lock is misrotated")

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

-- Text-only Spatial: expected needle must appear inside the found string.
local text_result = (function()
    local input = {
        expected = {
            {
                id = "8e7f6b3a-0000-4000-8000-0000000000tx",
                yolo_classes = {},
                ocr_values = { "TEXT" },
                boundary = { x = 0.0, y = 0.0, width = 10.0, height = 4.0 },
                rotation = 0.0,
                is_anchor = false,
                children = {},
            },
        },
        registered_detections = {
            { label = "TEXT A", confidence = 0.9, x = 0.0, y = 0.0, width = 10.0, height = 4.0 },
        },
        thresholds = { position = 8.0, rotation = 30.0 },
    }
    return json.decode(json.encode(validation(input)))
end)()
t.eq(text_result.objects[1].status, "matched", "ocr: text-only object matches OCR label")
t.eq(text_result.matched, 1, "ocr: matched count")

-- Nearby OCR must not mark a YOLO slot as mismatched.
local ocr_neighbor = (function()
    local input = {
        expected = {
            {
                id = "8e7f6b3a-0000-4000-8000-0000000000ch",
                yolo_classes = { "chip" },
                boundary = { x = 0.0, y = 0.0, width = 10.0, height = 10.0 },
                rotation = 0.0,
                is_anchor = false,
                children = {},
            },
            {
                id = "8e7f6b3a-0000-4000-8000-0000000000t2",
                yolo_classes = {},
                ocr_values = { "TEXT" },
                boundary = { x = 0.0, y = 0.0, width = 10.0, height = 4.0 },
                rotation = 0.0,
                is_anchor = false,
                children = {},
            },
        },
        registered_detections = {
            { label = "TEXT", confidence = 0.9, x = 0.0, y = 0.0, width = 10.0, height = 4.0 },
        },
        thresholds = { position = 8.0, rotation = 30.0 },
    }
    return json.decode(json.encode(validation(input)))
end)()
local chip = find_object(ocr_neighbor.objects, "8e7f6b3a-0000-4000-8000-0000000000ch")
local text = find_object(ocr_neighbor.objects, "8e7f6b3a-0000-4000-8000-0000000000t2")
t.eq(chip.status, "missing", "ocr: YOLO object stays missing, not mismatched by text")
t.eq(text.status, "matched", "ocr: text object claims the OCR box")

-- Presence-only paper is not a Spatial leftover: unused OCR is never extra.
local presence_ocr = (function()
    local input = {
        expected = {
            {
                id = "8e7f6b3a-0000-4000-8000-0000000000bl",
                yolo_classes = { "blocklock" },
                boundary = { x = 0.0, y = 0.0, width = 10.0, height = 10.0 },
                rotation = 0.0,
                is_anchor = true,
                children = {},
            },
        },
        registered_detections = {
            { label = "blocklock", confidence = 0.9, x = 0.0, y = 0.0, width = 10.0, height = 10.0, kind = "yolo" },
            { label = "ABC", confidence = 1.0, x = 40.0, y = 40.0, width = 4.0, height = 2.0, kind = "ocr" },
        },
        thresholds = { position = 8.0, rotation = 30.0 },
    }
    return json.decode(json.encode(validation(input)))
end)()
t.eq(presence_ocr.objects[1].status, "matched", "presence-ocr: YOLO matched")
t.eq(presence_ocr.extra, 0, "presence-ocr: unused OCR is never Spatial extra")
t.eq(#presence_ocr.extra_detections, 0, "presence-ocr: no extra detections")

if not t.summary("validation") then
    os.exit(1)
end
