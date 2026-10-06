-- Which ProfileView a live tick scores and which detections it keeps.
-- The settle and keep rules are `inspect_view.lua`; these ops are the
-- batches a phone tick needs, one call each.
--
-- Needs `inspect_view` in scope (the host concatenates it ahead).
--
-- `objects` is the profile tree: { id, profile_view_id, is_anchor,
--   yolo_classes, yolo_class_refs = { { class_id, label, vision_model_id } },
--   vision_model_id, children }.
--
--   view.settle { objects, detections = { { label, confidence, class_id?, vision_model_id? } },
--                 latched?, completed = { view_id } } -> { settled, view_id? }
--   view.scope  { objects, view_id?, completed } -> { ids, anchors_only }
--   view.frame  { objects, view_id?, completed, catalog_keys,
--                 detections = { { kind, label, vision_model_id? } } }
--     -> { class_ids = { "<class id>"|"" }, keep = { bool } }

local view = {}

local function key(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower())
end

local function same_view(a, b)
    return key(a) == key(b)
end

local function is_ocr(kind)
    kind = key(kind)
    return kind == "ocr" or kind:sub(1, 4) == "ocr:"
end

local function view_count(objects)
    local ids, n = {}, 0
    local function walk(nodes)
        for _, o in ipairs(nodes or {}) do
            local id = key(o.profile_view_id)
            if id ~= "" and not ids[id] then
                ids[id] = true
                n = n + 1
            end
            walk(o.children)
        end
    end
    walk(objects)
    return n
end

local function on_view(objects, view_id)
    local out = {}
    for _, o in ipairs(objects or {}) do
        if same_view(o.profile_view_id, view_id) then
            out[#out + 1] = o
        end
    end
    return out
end

local function anchors(objects, completed)
    return inspect_view({ op = "collect_anchors", objects = objects, completed = completed or {} }).objects
end

function view.settle(input)
    local id = inspect_view({
        op = "settle",
        objects = input.objects or {},
        detections = input.detections or {},
        latched = input.latched,
        completed = input.completed or {},
    }).view_id
    return { settled = id ~= nil, view_id = id }
end

-- The settled view's placements; one view (or none) keeps the whole tree;
-- otherwise only the open views' tips, until one settles.
function view.scope(input)
    local objects = input.objects or {}
    local ids = {}
    if key(input.view_id) ~= "" then
        for _, o in ipairs(on_view(objects, input.view_id)) do
            ids[#ids + 1] = o.id
        end
        return { ids = ids, anchors_only = false }
    end
    if view_count(objects) <= 1 then
        for _, o in ipairs(objects) do
            ids[#ids + 1] = o.id
        end
        return { ids = ids, anchors_only = false }
    end
    for _, o in ipairs(anchors(objects, input.completed)) do
        ids[#ids + 1] = o.id
    end
    return { ids = ids, anchors_only = true }
end

-- A detection names a class only when its engine model is known: the
-- first same-label class of another model is never a guess.
local function class_ref(objects, view_id, label, model)
    local lab, mid = key(label), key(model)
    if lab == "" or mid == "" then
        return ""
    end
    local function walk(nodes)
        for _, o in ipairs(nodes or {}) do
            if view_id == nil or same_view(o.profile_view_id, view_id) then
                for _, r in ipairs(o.yolo_class_refs or {}) do
                    if key(r.label) == lab and key(r.vision_model_id) == mid then
                        return tostring(r.class_id or "")
                    end
                end
            end
            local hit = walk(o.children)
            if hit ~= nil then
                return hit
            end
        end
        return nil
    end
    return walk(objects) or ""
end

function view.frame(input)
    local objects = input.objects or {}
    local view_id = key(input.view_id) ~= "" and input.view_id or nil
    local detections = input.detections or {}
    local class_ids, stamped = {}, {}
    for i, d in ipairs(detections) do
        local cid = is_ocr(d.kind) and "" or class_ref(objects, view_id, d.label, d.vision_model_id)
        class_ids[i] = cid
        stamped[i] = {
            kind = d.kind,
            label = d.label,
            class_id = cid ~= "" and cid or nil,
            vision_model_id = d.vision_model_id,
        }
    end
    local scoped, catalog
    if view_id ~= nil then
        scoped, catalog = on_view(objects, view_id), input.catalog_keys or {}
    elseif view_count(objects) > 1 then
        -- Waiting for a view: only the open views' tips may settle one.
        scoped, catalog = anchors(objects, input.completed), {}
    end
    if scoped == nil then
        local keep = {}
        for i = 1, #detections do
            keep[i] = true
        end
        return { class_ids = class_ids, keep = keep }
    end
    local out = inspect_view({
        op = "filter_detections",
        objects = scoped,
        catalog_keys = catalog,
        detections = stamped,
    })
    return { class_ids = class_ids, keep = out.keep }
end

return view
