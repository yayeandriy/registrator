-- presence_validator.lua: one read that holds the codes of two parts.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
normalisator = dofile(script_dir .. "../lua/normalisator.lua")
matcher = dofile(script_dir .. "../lua/matcher.lua")
class_match = dofile(script_dir .. "../lua/class_match.lua")
local presence_validator = dofile(script_dir .. "../lua/presence_validator.lua")
local t = dofile(script_dir .. "asserts.lua")

local MODEL = "2353bf0c-1d76-4d4d-a6ee-aa7287d725c0"
local CLASS = { class_id = "c-lower", label = "test_1_lower", vision_model_id = MODEL }

local function stamp(id, code)
    return {
        id = id,
        yolo_classes = { "test_1_lower" },
        yolo_class_refs = { CLASS },
        ocr_values = { code },
        vision_model_id = MODEL,
        presence = true,
        boundary = { x = 0, y = 0, width = 1, height = 1 },
        rotation = 0,
        children = {},
    }
end

local function lower(x)
    return { label = "test_1_lower", class_id = "c-lower", vision_model_id = MODEL, kind = "yolo",
             confidence = 0.9, x = x, y = 0.4, width = 0.14, height = 0.1 }
end

local function run(read)
    return json.decode(json.encode(presence_validator({
        expected = { stamp("a1", "X04"), stamp("a2", "P06") },
        detections = { lower(0.17), lower(0.32), read },
    })))
end

local function statuses(r)
    local out = {}
    for _, o in ipairs(r.objects) do
        out[#out + 1] = o.id .. ":" .. tostring(o.match_kind) .. ":" .. o.status
    end
    table.sort(out)
    return table.concat(out, ",")
end

-- "X04 P06" over both stamps; its centre lies in the first stamp's box.
local joint = { label = "X04 P06", kind = "ocr", confidence = 0.9, x = 0.19, y = 0.45, width = 0.25, height = 0.03 }
local both = statuses(run(joint))
t.eq(both:find("a1:ocr:matched", 1, true) ~= nil, true, "the first code of a joint read counts: " .. both)
t.eq(both:find("a2:ocr:matched", 1, true) ~= nil, true, "the second code of a joint read counts: " .. both)
t.eq(both:find("missing", 1, true), nil, "nothing is missing: " .. both)

if not t.summary("presence_joint_read") then
    os.exit(1)
end
