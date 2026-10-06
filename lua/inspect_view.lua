-- Live inspect: settle which ProfileView to score, then scope placements.
--
-- Identity is class_id, else (model, label), else trimmed lowercase label.
-- Standalone: `local inspect_view = dofile("inspect_view.lua")`.
--
-- Input: { op, objects, detections, latched, completed,
--          kind, class_id, vision_model_id, view_class_ids, view_models }
-- ops: settle | scope | keep_detection | filter_detections |
--      unique_anchor_classes | collect_anchors | view_model_ids | view_class_ids

local NIL_ID = "00000000-0000-0000-0000-000000000000"

local function is_nil_id(id)
    if id == nil then
        return true
    end
    local s = tostring(id)
    return s == "" or s == NIL_ID
end

local function normalize_class(label)
    return tostring(label or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
end

local function class_identity(class_id, model_id, label)
    if not is_nil_id(class_id) then
        return "c:" .. tostring(class_id)
    end
    local lab = normalize_class(label)
    if not is_nil_id(model_id) then
        return "m:" .. tostring(model_id) .. ":" .. lab
    end
    return lab
end

local function ref_identity(r)
    return class_identity(r.class_id, r.vision_model_id, r.label)
end

local function object_class_keys(object)
    local refs = object.yolo_class_refs
    if type(refs) == "table" and #refs > 0 then
        local keys = {}
        for _, r in ipairs(refs) do
            local k = ref_identity(r)
            if k ~= "" then
                keys[#keys + 1] = k
            end
        end
        return keys
    end
    local keys = {}
    for _, c in ipairs(object.yolo_classes or {}) do
        local k = normalize_class(c)
        if k ~= "" then
            keys[#keys + 1] = k
        end
    end
    return keys
end

local function anchor_class_keys(object)
    local keys = object_class_keys(object)
    local have = {}
    for _, k in ipairs(keys) do
        have[k] = true
    end
    local function push(raw)
        local key = normalize_class(raw)
        if key ~= "" and not have[key] then
            have[key] = true
            keys[#keys + 1] = key
        end
    end
    for _, label in ipairs(object.yolo_classes or {}) do
        push(label)
    end
    for _, r in ipairs(object.yolo_class_refs or {}) do
        push(r.label)
    end
    return keys
end

local function copy_obj(o)
    local c = {}
    for k, v in pairs(o) do
        c[k] = v
    end
    return c
end

local function walk_collect_anchors(objects, completed, out)
    for _, object in ipairs(objects or {}) do
        local vid = tostring(object.profile_view_id or NIL_ID)
        if object.is_anchor and not completed[vid] then
            local row = copy_obj(object)
            row.children = {}
            out[#out + 1] = row
        end
        walk_collect_anchors(object.children, completed, out)
    end
end

local function completed_set(list)
    local set = {}
    for _, id in ipairs(list or {}) do
        set[tostring(id)] = true
    end
    return set
end

local function collect_anchors_excluding(objects, completed)
    local out = {}
    walk_collect_anchors(objects, completed_set(completed), out)
    return out
end

local function walk_view_ids(objects, ids)
    for _, object in ipairs(objects or {}) do
        if not is_nil_id(object.profile_view_id) then
            ids[tostring(object.profile_view_id)] = true
        end
        walk_view_ids(object.children, ids)
    end
end

local function id_list(set)
    local list = {}
    for id in pairs(set) do
        list[#list + 1] = id
    end
    return list
end

local function placement_view_ids(objects)
    local ids = {}
    walk_view_ids(objects, ids)
    return id_list(ids), ids
end

local function walk_completed_anchor_keys(objects, completed, keys)
    for _, object in ipairs(objects or {}) do
        if object.is_anchor and completed[tostring(object.profile_view_id or "")] then
            for _, k in ipairs(anchor_class_keys(object)) do
                keys[k] = true
            end
        end
        walk_completed_anchor_keys(object.children, completed, keys)
    end
end

local function pick_scored_view(scores, latched)
    local best_id, best_score, ties = nil, nil, 0
    for id, score in pairs(scores) do
        if best_score == nil or score > best_score + 1e-9 then
            best_id, best_score, ties = id, score, 1
        elseif math.abs(score - best_score) < 1e-9 then
            ties = ties + 1
        end
    end
    if best_id == nil then
        return nil
    end
    if ties > 1 then
        if latched and scores[latched] then
            return latched
        end
        return nil
    end
    return best_id
end

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

local function walk_anchor_view_scores(objects, hits, completed, processed, identity_scores, label_scores)
    for _, object in ipairs(objects or {}) do
        local vid = tostring(object.profile_view_id or NIL_ID)
        if object.is_anchor and not is_nil_id(object.profile_view_id) and not completed[vid] then
            local keys = {}
            for _, key in ipairs(anchor_class_keys(object)) do
                if not processed[key] then
                    keys[#keys + 1] = key
                end
            end
            for _, hit in ipairs(hits or {}) do
                local identity = class_identity(hit.class_id, hit.vision_model_id, hit.label)
                local identity_hit = identity ~= "" and contains(keys, identity)
                local label = normalize_class(hit.label)
                local label_hit = label ~= "" and contains(keys, label)
                local conf = math.max(tonumber(hit.confidence) or 0, 0.01)
                if identity_hit then
                    identity_scores[vid] = (identity_scores[vid] or 0) + conf
                elseif label_hit then
                    label_scores[vid] = (label_scores[vid] or 0) + conf
                end
            end
        end
        walk_anchor_view_scores(object.children, hits, completed, processed, identity_scores, label_scores)
    end
end

local function settle(objects, detections, latched, completed_list)
    local list, idset = placement_view_ids(objects)
    if #list <= 1 then
        local id = list[1] or latched
        return id
    end
    local completed = completed_set(completed_list)
    if latched and completed[tostring(latched)] then
        latched = nil
    end
    local processed = {}
    walk_completed_anchor_keys(objects, completed, processed)
    local identity_scores, label_scores = {}, {}
    walk_anchor_view_scores(objects, detections, completed, processed, identity_scores, label_scores)
    return pick_scored_view(identity_scores, latched)
        or pick_scored_view(label_scores, latched)
        or (latched and idset[tostring(latched)] and latched or nil)
end

local function filter_view(objects, vid)
    local out = {}
    for _, o in ipairs(objects or {}) do
        if tostring(o.profile_view_id or NIL_ID) == tostring(vid) then
            out[#out + 1] = o
        end
    end
    return out
end

local function scope(objects, detections, latched, completed_list)
    local list = select(1, placement_view_ids(objects))
    if #list == 0 then
        return { objects = objects, awaiting_view = false }
    end
    if #list == 1 then
        local id = list[1]
        return { objects = filter_view(objects, id), view_id = id, awaiting_view = false }
    end
    local completed = completed_set(completed_list)
    local id = settle(objects, detections, latched, completed_list)
    if id and not is_nil_id(id) and not completed[tostring(id)] then
        return { objects = filter_view(objects, id), view_id = id, awaiting_view = false }
    end
    return {
        objects = collect_anchors_excluding(objects, completed_list),
        awaiting_view = true,
    }
end

local function id_set(list)
    local set, any = {}, false
    for _, id in ipairs(list or {}) do
        if not is_nil_id(id) then
            set[tostring(id)], any = true, true
        end
    end
    return set, any
end

-- YOLO from another model or class is noise once the view has refs. OCR stays.
local function keeper(view_class_ids, view_models)
    local classes, has_classes = id_set(view_class_ids)
    local models, has_models = id_set(view_models)
    return function(kind, class_id, vision_model_id)
        if not has_classes and not has_models then
            return true
        end
        kind = normalize_class(kind)
        if kind == "ocr" or kind:sub(1, 4) == "ocr:" then
            return true
        end
        if not is_nil_id(class_id) and has_classes then
            return classes[tostring(class_id)] == true
        end
        return not is_nil_id(vision_model_id) and models[tostring(vision_model_id)] == true
    end
end

local function walk_anchor_class_counts(objects, counts)
    for _, object in ipairs(objects or {}) do
        if object.is_anchor then
            for _, key in ipairs(anchor_class_keys(object)) do
                counts[key] = (counts[key] or 0) + 1
            end
        end
        walk_anchor_class_counts(object.children, counts)
    end
end

local function unique_view_anchor_classes(objects)
    local counts = {}
    walk_anchor_class_counts(objects, counts)
    local map = {}
    local function walk(nodes)
        for _, object in ipairs(nodes or {}) do
            if object.is_anchor and not is_nil_id(object.profile_view_id) then
                for _, key in ipairs(anchor_class_keys(object)) do
                    if counts[key] == 1 then
                        map[key] = tostring(object.profile_view_id)
                    end
                end
            end
            walk(object.children)
        end
    end
    walk(objects)
    return map
end

local function walk_model_ids(objects, ids)
    for _, object in ipairs(objects or {}) do
        for _, r in ipairs(object.yolo_class_refs or {}) do
            if not is_nil_id(r.vision_model_id) then
                ids[tostring(r.vision_model_id)] = true
            end
        end
        if not is_nil_id(object.vision_model_id) then
            ids[tostring(object.vision_model_id)] = true
        end
        walk_model_ids(object.children, ids)
    end
end

local function walk_class_ids(objects, ids)
    for _, object in ipairs(objects or {}) do
        for _, r in ipairs(object.yolo_class_refs or {}) do
            if not is_nil_id(r.class_id) then
                ids[tostring(r.class_id)] = true
            end
        end
        walk_class_ids(object.children, ids)
    end
end

local function catalog_key(label)
    return (normalize_class(label):gsub("%s", "_"))
end

-- One verdict per detection, in order. A catalog class stays even when the
-- view does not place it, so the run can fail it as an extra.
local function filter_detections(input)
    local class_ids, model_ids = input.view_class_ids, input.view_models
    if class_ids == nil and model_ids == nil then
        local c, m = {}, {}
        walk_class_ids(input.objects, c)
        walk_model_ids(input.objects, m)
        class_ids, model_ids = id_list(c), id_list(m)
    end
    local keep_fn = keeper(class_ids, model_ids)
    local catalog = {}
    for _, label in ipairs(input.catalog_keys or {}) do
        catalog[catalog_key(label)] = true
    end
    catalog[""] = nil
    local keep = {}
    for i, d in ipairs(input.detections or {}) do
        keep[i] = keep_fn(d.kind, d.class_id, d.vision_model_id)
            or catalog[catalog_key(d.label)] == true
    end
    return { keep = keep }
end

local function inspect_view(input)
    input = input or {}
    local op = input.op or "scope"
    local objects = input.objects or {}
    if op == "settle" then
        return { view_id = settle(objects, input.detections, input.latched, input.completed) }
    elseif op == "keep_detection" then
        local keep = keeper(input.view_class_ids, input.view_models)
        return { keep = keep(input.kind, input.class_id, input.vision_model_id) }
    elseif op == "filter_detections" then
        return filter_detections(input)
    elseif op == "unique_anchor_classes" then
        return { map = unique_view_anchor_classes(objects) }
    elseif op == "collect_anchors" then
        return { objects = collect_anchors_excluding(objects, input.completed) }
    elseif op == "view_model_ids" then
        local ids = {}
        walk_model_ids(objects, ids)
        return { ids = id_list(ids) }
    elseif op == "view_class_ids" then
        local ids = {}
        walk_class_ids(objects, ids)
        return { ids = id_list(ids) }
    end
    return scope(objects, input.detections, input.latched, input.completed)
end

return inspect_view
