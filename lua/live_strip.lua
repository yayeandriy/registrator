-- Live extras strip + tree helpers. Concatenated into live.lua's chunk.
-- Locals from the host wrap: class_match, normalisator, zone.

local SPATIAL_ROUTINE = "spatial_validate"
local PRESENCE_ROUTINE = "presence_validate"

local function has_routine(o, name)
    for _, r in ipairs(o.routines or {}) do
        if r == name then
            return true
        end
    end
    return false
end

local function has_spatial(o)
    return has_routine(o, SPATIAL_ROUTINE)
end

local function has_presence(o)
    return has_routine(o, PRESENCE_ROUTINE)
end

local function is_ocr_kind(kind)
    if type(kind) ~= "string" then
        return false
    end
    kind = kind:lower()
    return kind == "ocr" or kind:sub(1, 4) == "ocr:"
end

local function class_key(raw)
    if type(class_match) == "table" and type(class_match.key) == "function" then
        return class_match.key(raw)
    end
    return tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower():gsub("%s+", "_")
end

local function copy_obj(o)
    local c = {}
    for k, v in pairs(o) do
        c[k] = v
    end
    return c
end

local function expected_has_ocr(nodes)
    for _, o in ipairs(nodes or {}) do
        for _, v in ipairs(o.ocr_values or {}) do
            if type(v) == "string" and v:match("%S") then
                return true
            end
        end
        if expected_has_ocr(o.children) then
            return true
        end
    end
    return false
end

local function detections_as_presence(dets)
    local out = {}
    for _, d in ipairs(dets or {}) do
        local kind = d.kind
        if type(kind) ~= "string" or kind == "" then
            kind = "yolo"
        end
        out[#out + 1] = {
            label = d.label,
            confidence = d.confidence,
            x = d.x,
            y = d.y,
            width = d.width,
            height = d.height,
            kind = kind,
            misses = 0,
            matched_label = d.matched_label,
            class_id = d.class_id,
            vision_model_id = d.vision_model_id,
        }
    end
    return out
end

local function profile_class_keys(expected)
    local keys = {}
    local function walk(nodes)
        for _, o in ipairs(nodes or {}) do
            for _, c in ipairs(o.yolo_classes or {}) do
                local k = class_key(c)
                if k ~= "" then
                    keys[k] = true
                end
            end
            walk(o.children)
        end
    end
    walk(expected)
    return keys
end

local function scored_class_keys(expected, catalog)
    local keys = profile_class_keys(expected)
    for _, component in ipairs(catalog or {}) do
        for _, label in ipairs(component.yolo_classes or {}) do
            local k = class_key(label)
            if k ~= "" then
                keys[k] = true
            end
        end
    end
    return keys
end

local function keep_profile_surplus_extra(label, matched_label, profile)
    if profile[class_key(label)] then
        return true
    end
    if type(matched_label) == "string" and profile[class_key(matched_label)] then
        return true
    end
    return false
end

local function strip_unlinked_presence_extras(result, expected, catalog)
    local profile = scored_class_keys(expected, catalog)
    local kept = {}
    for _, d in ipairs(result.extra_detections or {}) do
        if keep_profile_surplus_extra(d.label, d.matched_label, profile) then
            kept[#kept + 1] = d
        end
    end
    result.extra_detections = kept
    result.extra = #kept
end

local function strip_unlinked_spatial_extras(result, expected, catalog)
    local profile = scored_class_keys(expected, catalog)
    local kept = {}
    for _, d in ipairs(result.extra_detections or {}) do
        if keep_profile_surplus_extra(d.label, nil, profile) then
            kept[#kept + 1] = d
        end
    end
    result.extra_detections = kept
    result.extra = #kept
end

local function yolo_labels_in(nodes, keep_fn)
    local labels = {}
    local function walk(list)
        for _, o in ipairs(list or {}) do
            if keep_fn(o) then
                for _, c in ipairs(o.yolo_classes or {}) do
                    if type(c) == "string" and c:match("%S") then
                        labels[c] = true
                    end
                end
            end
            walk(o.children)
        end
    end
    walk(nodes)
    return labels
end

local function strip_spatial_class_extras(result, spatial_tree)
    local labels = yolo_labels_in(spatial_tree, has_spatial)
    local empty = true
    for _ in pairs(labels) do
        empty = false
        break
    end
    if empty then
        return
    end
    local kept = {}
    for _, d in ipairs(result.extra_detections or {}) do
        if not labels[d.label] then
            kept[#kept + 1] = d
        end
    end
    result.extra_detections = kept
    result.extra = #kept
end

local function strip_ocr_presence_extras(result)
    local kept = {}
    for _, d in ipairs(result.extra_detections or {}) do
        if not is_ocr_kind(d.kind) then
            kept[#kept + 1] = d
        end
    end
    result.extra_detections = kept
    result.extra = #kept
end

local function fold_value(s)
    if type(normalisator) == "function" then
        local r = normalisator({ value = s })
        if type(r) == "table" and type(r.value) == "string" then
            return r.value
        end
    end
    return s
end

local function presence_only_labels(expected)
    local labels = {}
    local function insert(raw)
        if type(raw) ~= "string" then
            return
        end
        local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed == "" then
            return
        end
        labels[trimmed] = true
        local folded = fold_value(trimmed)
        if type(folded) == "string" and folded ~= "" then
            labels[folded] = true
        end
    end
    local function walk(nodes)
        for _, o in ipairs(nodes or {}) do
            if has_presence(o) and not has_spatial(o) then
                for _, c in ipairs(o.yolo_classes or {}) do
                    insert(c)
                end
                for _, v in ipairs(o.ocr_values or {}) do
                    insert(v)
                end
            end
            walk(o.children)
        end
    end
    walk(expected)
    return labels
end

local function is_presence_only_extra(d, presence_labels)
    if is_ocr_kind(d.kind) then
        return true
    end
    if presence_labels[d.label] then
        return true
    end
    local folded = fold_value(d.label)
    return type(folded) == "string" and folded ~= "" and presence_labels[folded] == true
end

local function strip_presence_only_spatial_extras(result, expected)
    local labels = presence_only_labels(expected)
    local kept = {}
    for _, d in ipairs(result.extra_detections or {}) do
        if not is_presence_only_extra(d, labels) then
            kept[#kept + 1] = d
        end
    end
    result.extra_detections = kept
    result.extra = #kept
end

local function tree_class_labels(tree)
    local labels = {}
    local function walk(nodes)
        for _, o in ipairs(nodes or {}) do
            for _, c in ipairs(o.yolo_classes or {}) do
                local key = tostring(c or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
                if key ~= "" then
                    labels[key] = true
                end
            end
            walk(o.children)
        end
    end
    walk(tree)
    return labels
end

local function drop_anchors(tree)
    local out = {}
    for _, object in ipairs(tree or {}) do
        local kids = drop_anchors(object.children)
        if object.is_anchor then
            local b = object.boundary or {}
            for _, kid in ipairs(kids) do
                local copy = copy_obj(kid)
                local kb = {}
                for k, v in pairs(kid.boundary or {}) do
                    kb[k] = v
                end
                kb.x = (kb.x or 0) + (b.x or 0)
                kb.y = (kb.y or 0) + (b.y or 0)
                copy.boundary = kb
                out[#out + 1] = copy
            end
        else
            local copy = copy_obj(object)
            copy.children = kids
            out[#out + 1] = copy
        end
    end
    return out
end

local function strip_tip_class_extras(result, tip_labels)
    local kept = {}
    for _, d in ipairs(result.extra_detections or {}) do
        local key = tostring(d.label or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if not tip_labels[key] then
            kept[#kept + 1] = d
        end
    end
    result.extra_detections = kept
    result.extra = #kept
end

local function recount_spatial(result)
    local matched = 0
    for _, o in ipairs(result.objects or {}) do
        if o.status == "matched" then
            matched = matched + 1
        end
    end
    result.matched = matched
    result.total = #(result.objects or {})
    result.extra = #(result.extra_detections or {})
    if result.total == 0 then
        result.score = 0.0
    else
        result.score = matched / result.total
    end
end

local function strip_settled_anchor_spatial(result)
    local kept = {}
    for _, o in ipairs(result.objects or {}) do
        if not o.is_anchor then
            kept[#kept + 1] = o
        end
    end
    result.objects = kept
    recount_spatial(result)
end
