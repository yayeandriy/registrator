-- Detection vs expected YOLO class.
--
-- Identity is class_id, then (vision_model_id, label), then label.
-- Overlapping labels on different models must not match.
--
-- match(detection, expected)
--   detection: { label, class_id, vision_model_id }
--   expected:  string label  OR  { label, class_id, vision_model_id }
-- similar(detection, expected) — `match` with case / `_`-tolerant labels
-- in_expected(detection, expected_list)
-- key(detection_or_ref) — extras grouping
-- expected_list(object) — `yolo_class_refs`, else labels on its model

local function trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function nonempty(s)
    return trim(tostring(s or "")) ~= ""
end

local function as_str(v)
    if v == nil then
        return ""
    end
    return trim(tostring(v))
end

local function label_key(s)
    return (trim(tostring(s or "")):lower():gsub("%s+", "_"))
end

local function same_text(a, b)
    return as_str(a) == as_str(b)
end

local function same_key(a, b)
    return label_key(a) == label_key(b)
end

local function identity(detection, expected, same_label)
    local d = detection or {}
    local exp_label, exp_class_id, exp_model
    if type(expected) == "table" then
        exp_label = expected.label
        exp_class_id = expected.class_id
        exp_model = expected.vision_model_id
    else
        exp_label = expected
    end
    local d_class = as_str(d.class_id)
    local e_class = as_str(exp_class_id)
    if d_class ~= "" and e_class ~= "" then
        return d_class == e_class
    end
    local d_model = as_str(d.vision_model_id)
    local e_model = as_str(exp_model)
    if d_model ~= "" and e_model ~= "" and d_model ~= e_model then
        return false
    end
    return same_label(d.label, exp_label)
end

local function class_match(detection, expected)
    return identity(detection, expected, same_text)
end

-- Same identity, labels compared ignoring case and space-vs-underscore
-- (catalog `a_1 lower` vs detector `a_1_lower`).
local function class_similar(detection, expected)
    return identity(detection, expected, same_key)
end

local function class_in_expected(detection, expected_list)
    for _, exp in ipairs(expected_list or {}) do
        if class_match(detection, exp) then
            return true
        end
    end
    return false
end

local function class_key_of(d)
    if type(d) ~= "table" then
        return label_key(d)
    end
    local id = as_str(d.class_id)
    if id ~= "" then
        return "c:" .. id
    end
    local model = as_str(d.vision_model_id)
    local lab = label_key(d.label)
    if model ~= "" then
        return "m:" .. model .. ":" .. lab
    end
    return lab
end

local function expected_class_list(o)
    o = o or {}
    if type(o.yolo_class_refs) == "table" and #o.yolo_class_refs > 0 then
        return o.yolo_class_refs
    end
    local out = {}
    local labels = o.yolo_classes
    if type(labels) ~= "table" then
        labels = {}
        if nonempty(o.yolo_class) then
            labels = { o.yolo_class }
        end
    end
    for _, v in ipairs(labels) do
        if nonempty(v) then
            table.insert(out, {
                label = trim(v),
                vision_model_id = o.vision_model_id,
            })
        end
    end
    return out
end

return {
    match = class_match,
    similar = class_similar,
    in_expected = class_in_expected,
    key = class_key_of,
    expected_list = expected_class_list,
}
