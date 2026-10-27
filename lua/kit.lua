-- Profile kit: turns a profile's placements, the project's components and
-- the class catalog into what live scoring expects.
--
-- Input: {
--   objects    = { placement... },   -- id, profile_view_id, name, component_ids,
--                                     -- routines, x, y, width, height, rotation,
--                                     -- is_anchor, loose_match, children
--   components = { component... },   -- id, inspection_profile_id, name, class_ids,
--                                     -- text_values, symmetry, thresholds
--   classes    = { class... },       -- id, label, vision_model_id
--   profile_id = "uuid",
--   draft      = { component_id, thresholds } | nil  -- unsaved thresholds
-- }
-- Output: {
--   expected = { object... },  -- placement geometry plus yolo_classes,
--                               -- yolo_class_refs, ocr_values, vision_model_id,
--                               -- symmetry, thresholds; children nested
--   catalog  = { component... }, -- this profile's components that can be seen:
--                                 -- id, name, yolo_classes, ocr_values
--   needles  = { "text"... },    -- OCR values the profile expects, tree order
--   presence = bool, spatial = bool  -- which routines live scoring runs
-- }
--
-- Hosts may hand `nil` as a null sentinel; every field is read by type.

local DEFAULT_SYMMETRY = "inf"
local PRESENCE = "presence_validate"
local SPATIAL = "spatial_validate"

local function str(v)
    if type(v) == "string" then
        return v
    end
    return ""
end

local function list(v)
    if type(v) == "table" then
        return v
    end
    return {}
end

local function num(v)
    if type(v) == "number" then
        return v
    end
    return nil
end

local function trim(s)
    return (str(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function contains(items, value)
    for _, item in ipairs(items) do
        if item == value then
            return true
        end
    end
    return false
end

local function push_unique(items, value)
    if not contains(items, value) then
        items[#items + 1] = value
    end
end

local function by_id(items, id)
    for _, item in ipairs(items) do
        if str(item.id) == id then
            return item
        end
    end
    return nil
end

-- The placement's components that exist, in placement order.
local function linked(o, components)
    local out = {}
    for _, cid in ipairs(list(o.component_ids)) do
        local comp = by_id(components, str(cid))
        if comp then
            out[#out + 1] = comp
        end
    end
    return out
end

-- Each linked component's classes that exist, in order.
local function linked_classes(comps, classes)
    local out = {}
    for _, comp in ipairs(comps) do
        for _, class_id in ipairs(list(comp.class_ids)) do
            local cl = by_id(classes, str(class_id))
            if cl then
                out[#out + 1] = cl
            end
        end
    end
    return out
end

local function has_text(comps)
    for _, comp in ipairs(comps) do
        for _, text in ipairs(list(comp.text_values)) do
            if trim(text) ~= "" then
                return true
            end
        end
    end
    return false
end

-- A text-only part never borrows a YOLO class from its name: that would be
-- a nameless presence miss and would leave the real OCR as an extra.
local function yolo_classes(o, comps, linked_cls, classes)
    local out = {}
    for _, cl in ipairs(linked_cls) do
        push_unique(out, str(cl.label))
    end
    if #out == 0 and not has_text(comps) then
        local name = trim(o.name)
        if name ~= "" then
            local lower = name:lower()
            for _, cl in ipairs(classes) do
                if str(cl.label):lower() == lower then
                    out[1] = str(cl.label)
                    return out
                end
            end
            out[1] = name
        end
    end
    return out
end

local function class_refs(linked_cls)
    local out, seen = {}, {}
    for _, cl in ipairs(linked_cls) do
        local id = str(cl.id)
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = {
                class_id = id,
                label = str(cl.label),
                vision_model_id = str(cl.vision_model_id),
            }
        end
    end
    return out
end

-- Presence YOLO needs a model; it comes only from the linked classes.
local function vision_model(linked_cls)
    for _, cl in ipairs(linked_cls) do
        if trim(cl.vision_model_id) ~= "" then
            return str(cl.vision_model_id)
        end
    end
    return nil
end

-- An unfilled router formula is not something to read.
local function ocr_values(comps)
    local out = {}
    for _, comp in ipairs(comps) do
        for _, text in ipairs(list(comp.text_values)) do
            local value = trim(text)
            if value ~= "" and value:sub(1, 1) ~= "=" and not value:find("{", 1, true) then
                push_unique(out, value)
            end
        end
    end
    return out
end

local function thresholds_of(o, comps, draft)
    local source
    if draft and contains(list(o.component_ids), str(draft.component_id)) then
        source = draft.thresholds
    elseif comps[1] then
        source = comps[1].thresholds
    end
    if type(source) ~= "table" then
        return nil
    end
    local distance, rotation = num(source.distance), num(source.rotation)
    if distance == nil and rotation == nil then
        return nil
    end
    return { distance = distance, rotation = rotation }
end

local function symmetry_of(comps)
    if comps[1] and trim(comps[1].symmetry) ~= "" then
        return str(comps[1].symmetry)
    end
    return DEFAULT_SYMMETRY
end

local function expected(objects, components, classes, draft)
    local out = {}
    for _, o in ipairs(list(objects)) do
        local comps = linked(o, components)
        local cls = linked_classes(comps, classes)
        out[#out + 1] = {
            id = str(o.id),
            profile_view_id = str(o.profile_view_id),
            name = str(o.name),
            routines = list(o.routines),
            x = num(o.x) or 0,
            y = num(o.y) or 0,
            width = num(o.width) or 0,
            height = num(o.height) or 0,
            rotation = num(o.rotation) or 0,
            is_anchor = o.is_anchor == true,
            symmetry = symmetry_of(comps),
            loose_match = o.loose_match == true,
            thresholds = thresholds_of(o, comps, draft),
            yolo_classes = yolo_classes(o, comps, cls, classes),
            yolo_class_refs = class_refs(cls),
            ocr_values = ocr_values(comps),
            vision_model_id = vision_model(cls),
            children = expected(o.children, components, classes, draft),
        }
    end
    return out
end

-- Components from another profile of the project are not extras here.
local function catalog(components, classes, profile_id)
    local out = {}
    local wanted = trim(profile_id)
    for _, comp in ipairs(components) do
        local owner = trim(comp.inspection_profile_id)
        if wanted == "" or owner == "" or owner == wanted then
            local yolo = {}
            for _, class_id in ipairs(list(comp.class_ids)) do
                local cl = by_id(classes, str(class_id))
                local label = cl and trim(cl.label) or ""
                if label ~= "" then
                    push_unique(yolo, label)
                end
            end
            local ocr = {}
            for _, text in ipairs(list(comp.text_values)) do
                local value = trim(text)
                if value ~= "" then
                    ocr[#ocr + 1] = value
                end
            end
            if #yolo > 0 or #ocr > 0 then
                out[#out + 1] = {
                    id = str(comp.id),
                    name = str(comp.name),
                    yolo_classes = yolo,
                    ocr_values = ocr,
                }
            end
        end
    end
    return out
end

local function needles(objects, out)
    for _, o in ipairs(objects) do
        for _, value in ipairs(o.ocr_values) do
            push_unique(out, value)
        end
        needles(o.children, out)
    end
    return out
end

local function uses(objects, routine)
    for _, o in ipairs(objects) do
        if contains(o.routines, routine) or uses(o.children, routine) then
            return true
        end
    end
    return false
end

local function run(input)
    input = list(input)
    local op = str(input.op)
    if op ~= "" and op ~= "prepare" then
        error("kit: unknown op " .. op)
    end
    local components, classes = list(input.components), list(input.classes)
    local draft = type(input.draft) == "table" and input.draft or nil
    local objects = expected(input.objects, components, classes, draft)
    -- A profile that names no routine is still checked for placement.
    local presence = uses(objects, PRESENCE)
    return {
        expected = objects,
        catalog = catalog(components, classes, input.profile_id),
        needles = needles(objects, {}),
        presence = presence,
        spatial = uses(objects, SPATIAL) or (not presence and #objects > 0),
    }
end

return run
