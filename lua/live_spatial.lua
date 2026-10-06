-- Live spatial window (global): register → consensus → accumulate → validate.
-- Concatenated after live_strip.lua. Uses registration/accumulator/validation/
-- layout/ruller/zone as chunk locals.

local function walk_anchor_ids(object, ids)
    if object.is_anchor then
        ids[#ids + 1] = tostring(object.id or "")
    end
    for _, child in ipairs(object.children or {}) do
        walk_anchor_ids(child, ids)
    end
end

local function anchor_ids(object)
    local ids = {}
    walk_anchor_ids(object, ids)
    return ids
end

local function all_anchor_id_set(expected)
    local set = {}
    for _, o in ipairs(expected or {}) do
        for _, id in ipairs(anchor_ids(o)) do
            set[id] = true
        end
    end
    local list = {}
    for id in pairs(set) do
        list[#list + 1] = id
    end
    return list
end

local function strip_settled_anchor_presence(result, expected)
    local kept = {}
    for _, o in ipairs(result.objects or {}) do
        if not o.is_anchor then
            kept[#kept + 1] = o
        end
    end
    result.objects = kept
    local tip_labels = tree_class_labels(zone.filter_keep(expected, all_anchor_id_set(expected)))
    local extras = {}
    for _, d in ipairs(result.extra_detections or {}) do
        local key = tostring(d.label or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if not tip_labels[key] then
            extras[#extras + 1] = d
        end
    end
    result.extra_detections = extras
    local matched = 0
    for _, o in ipairs(result.objects) do
        if o.status == "matched" then
            matched = matched + 1
        end
    end
    result.matched = matched
    result.total = #result.objects
    result.extra = #extras
    if result.total == 0 then
        result.score = 0.0
    else
        result.score = matched / result.total
    end
end

local function anchor_class_labels(tree)
    local out = {}
    local function walk(nodes)
        for _, object in ipairs(nodes or {}) do
            if object.is_anchor then
                for _, c in ipairs(object.yolo_classes or {}) do
                    local key = tostring(c or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
                    if key ~= "" then
                        out[key] = true
                    end
                end
            end
            walk(object.children)
        end
    end
    walk(tree)
    return out
end

local spatial_only_tree
local function promote_spatial_children(objects, origin_x, origin_y)
    local out = {}
    for _, o in ipairs(objects or {}) do
        local b = o.boundary or {}
        local x = origin_x + (b.x or 0)
        local y = origin_y + (b.y or 0)
        if has_spatial(o) then
            local copy = copy_obj(o)
            copy.boundary = { x = x, y = y, width = b.width, height = b.height }
            copy.children = spatial_only_tree(o.children)
            out[#out + 1] = copy
        else
            for _, kid in ipairs(promote_spatial_children(o.children, x, y)) do
                out[#out + 1] = kid
            end
        end
    end
    return out
end

spatial_only_tree = function(expected)
    local out = {}
    for _, o in ipairs(expected or {}) do
        if has_spatial(o) then
            local copy = copy_obj(o)
            copy.children = spatial_only_tree(o.children)
            out[#out + 1] = copy
        else
            local b = o.boundary or {}
            for _, kid in ipairs(promote_spatial_children(o.children, b.x or 0, b.y or 0)) do
                out[#out + 1] = kid
            end
        end
    end
    return out
end

local function missing_row(o)
    return {
        id = o.id,
        yolo_classes = o.yolo_classes or {},
        ocr_values = o.ocr_values or {},
        is_anchor = o.is_anchor and true or false,
        status = "missing",
        matched_label = nil,
        matched_confidence = nil,
        delta_position = nil,
        delta_rotation = nil,
        matched_x = nil,
        matched_y = nil,
        matched_width = nil,
        matched_height = nil,
    }
end

local function missing_spatial_placeholder(tree)
    local objects = {}
    local function walk(nodes)
        for _, o in ipairs(nodes or {}) do
            if has_spatial(o) then
                objects[#objects + 1] = missing_row(o)
            end
            walk(o.children)
        end
    end
    walk(tree)
    return {
        objects = objects,
        extra_detections = {},
        score = 0.0,
        matched = 0,
        total = #objects,
        extra = 0,
    }
end

local function missing_presence_placeholder(expected)
    local objects = {}
    local function walk(nodes)
        for _, o in ipairs(nodes or {}) do
            local classes = {}
            for _, c in ipairs(o.yolo_classes or {}) do
                if type(c) == "string" and c:match("%S") then
                    classes[#classes + 1] = c
                end
            end
            local texts = {}
            for _, v in ipairs(o.ocr_values or {}) do
                if type(v) == "string" and v:match("%S") then
                    texts[#texts + 1] = v
                end
            end
            local yolo_expected = #classes > 0 and (has_presence(o) or not has_spatial(o))
            local ocr_expected = #texts > 0
            if yolo_expected then
                objects[#objects + 1] = {
                    id = o.id,
                    yolo_classes = classes,
                    ocr_values = {},
                    is_anchor = o.is_anchor and true or false,
                    presence = true,
                    status = "missing",
                    match_kind = "yolo",
                }
            end
            if ocr_expected then
                for _, text in ipairs(texts) do
                    objects[#objects + 1] = {
                        id = o.id,
                        yolo_classes = {},
                        ocr_values = { text },
                        is_anchor = o.is_anchor and true or false,
                        presence = has_presence(o),
                        status = "missing",
                        match_kind = "ocr",
                    }
                end
            end
            if has_presence(o) and not yolo_expected and not ocr_expected then
                objects[#objects + 1] = {
                    id = o.id,
                    yolo_classes = classes,
                    ocr_values = texts,
                    is_anchor = o.is_anchor and true or false,
                    presence = true,
                    status = "missing",
                }
            end
            walk(o.children)
        end
    end
    walk(expected)
    return {
        objects = objects,
        extra_detections = {},
        score = 0.0,
        matched = 0,
        total = #objects,
        extra = 0,
    }
end

local function walk_is_anchor(nodes)
    for _, o in ipairs(nodes or {}) do
        if o.is_anchor or walk_is_anchor(o.children) then
            return true
        end
    end
    return false
end

local function anchor_expected(spatial_expected, zones)
    if #zone.usable_zones(zones) >= 2 then
        return true
    end
    return walk_is_anchor(spatial_expected)
end

local function shift_tree(tree, dx, dy)
    local out = {}
    for _, object in ipairs(tree or {}) do
        local copy = copy_obj(object)
        local b = object.boundary or {}
        copy.boundary = {
            x = (b.x or 0) + dx,
            y = (b.y or 0) + dy,
            width = b.width,
            height = b.height,
        }
        copy.children = object.children
        out[#out + 1] = copy
    end
    return out
end

local function shift_origin(t, ox, oy)
    return {
        tx = t.tx - t.a * ox - t.b * oy,
        ty = t.ty - t.c * ox - t.d * oy,
        a = t.a,
        b = t.b,
        c = t.c,
        d = t.d,
        px = t.px or 0,
        py = t.py or 0,
    }
end

local function tip_origin(boxes, object_id)
    for _, b in ipairs(boxes or {}) do
        if tostring(b.id) == tostring(object_id) then
            return b.x or 0, b.y or 0
        end
    end
    return 0.0, 0.0
end

local function apply_board_to_frame(t, x, y)
    local denom = (t.px or 0) * x + (t.py or 0) * y + 1.0
    if math.abs(denom) < 1e-12 then
        return nil
    end
    return (t.tx + t.a * x + t.b * y) / denom, (t.ty + t.c * x + t.d * y) / denom
end

local function transform_scale(t)
    return math.sqrt(t.a * t.a + t.c * t.c)
end

function transform_agrees(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    local sa, sb = transform_scale(a), transform_scale(b)
    local smax = math.max(sa, sb, 1e-12)
    if math.abs(sa - sb) / smax > 0.35 then
        return false
    end
    local dt = math.sqrt((a.tx - b.tx) ^ 2 + (a.ty - b.ty) ^ 2)
    return dt < 0.12
end

function consensus_transform(ts)
    local vals = {}
    if type(ts) ~= "table" then
        return nil
    end
    local n = 0
    for i = 1, 256 do
        local t = ts[i]
        if t == nil then
            break
        end
        n = i
        if type(t) == "table" and t.tx ~= nil then
            vals[#vals + 1] = t
        end
    end
    if #vals == 0 then
        return nil
    end
    local best_i, best_n = 1, 0
    for i = 1, #vals do
        local count = 0
        for j = 1, #vals do
            if transform_agrees(vals[i], vals[j]) then
                count = count + 1
            end
        end
        if count > best_n then
            best_n = count
            best_i = i
        end
    end
    return vals[best_i]
end
