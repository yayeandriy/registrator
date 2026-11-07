-- Populate a view from what a model found on its still: which component
-- each found box is, which components are new, and where each box sits.
--
--   populate.place {
--     detections = { { label, confidence, x, y, width, height, rotation?, kind = "yolo"|"ocr" } },
--     components = { { id, name, class_ids, text_values } },
--     classes    = { { id, label } },     -- the view model's classes
--     placed     = { { component_id, x, y, width, height } } | nil,  -- on the view already
--     counted    = { component_id } | nil,  -- with Presence on the view
--     only       = { component_id } | nil,  -- place into these alone
--     reads      = "yolo"|"ocr"|"all" | nil, -- which boxes count; nil = all
--     kind       = "spatial"|"presence" | nil, -- what a box becomes; nil = spatial
--     iou        = 0.5 | nil,
--   } -> {
--     placements     = { { component_id? , new?, x, y, width, height, rotation } },
--     counts         = { { component_id?, new?, count } },  -- kind = "presence"
--     new_components = { { name, class_ids, text_values, width, height } },
--     skipped        = <boxes with no label>,
--     duplicates     = <boxes already placed>,
--     outside        = <boxes none of `only` is>,
--     conflicts      = <boxes of components the view holds the other way>,
--   }
--
-- Boxes are in board units. Overlapping class boxes collapse to the most
-- confident one, whatever their classes (class-agnostic NMS); text boxes
-- are kept as found. A class box takes the first text box whose middle lies
-- inside it as its text. A box is the component whose texts hold its text;
-- else, with no text, the one linked to its class; else one named like it;
-- else a new component, made once per text or class. A placement names a
-- catalog component by `component_id` or a new one by `new` (its index in
-- `new_components`). A box of a catalog component that overlaps one of that
-- component's `placed` boxes by `iou` or more is already placed and dropped.
-- With `only`, a box goes to the first of those components whose texts hold
-- its text, else the first linked to its class; nothing is made, names do
-- not count, and a box none of them is counts as `outside`.
-- `reads = "yolo"` drops the text boxes (no box takes a text); `"ocr"`
-- drops the class boxes. A component is placed by Spatial boxes or counted
-- by Presence on a view, not both: Spatial skips the boxes of `counted`
-- components, Presence those of components with `placed` boxes, each as a
-- conflict. Presence makes no placements; each component's boxes become
-- its count, in the order first found.

local populate = {}

local DEFAULT_IOU = 0.5

local function trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function key(s)
    return (trim(s):upper():gsub("%s+", ""))
end

local function contains(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then
            return true
        end
    end
    return false
end

local function iou(a, b)
    local ix = math.min(a.x + a.width, b.x + b.width) - math.max(a.x, b.x)
    local iy = math.min(a.y + a.height, b.y + b.height) - math.max(a.y, b.y)
    if ix <= 0 or iy <= 0 then
        return 0
    end
    local inter = ix * iy
    local union = a.width * a.height + b.width * b.height - inter
    return union > 0 and inter / union or 0
end

local function nms(boxes, threshold)
    local order = {}
    for i, d in ipairs(boxes) do
        order[i] = { d = d, i = i }
    end
    table.sort(order, function(a, b)
        local ca, cb = a.d.confidence or 0, b.d.confidence or 0
        if ca ~= cb then
            return ca > cb
        end
        return a.i < b.i
    end)
    local kept = {}
    for _, item in ipairs(order) do
        local dup = false
        for _, k in ipairs(kept) do
            if iou(k, item.d) >= threshold then
                dup = true
                break
            end
        end
        if not dup then
            kept[#kept + 1] = item.d
        end
    end
    return kept
end

local function already_placed(placed, component_id, box, threshold)
    for _, p in ipairs(placed or {}) do
        if p.component_id == component_id and iou(p, box) >= threshold then
            return true
        end
    end
    return false
end

local function inside(box, d)
    local cx, cy = d.x + d.width / 2, d.y + d.height / 2
    return cx >= box.x and cx <= box.x + box.width and cy >= box.y and cy <= box.y + box.height
end

local function class_of(label, classes)
    local wanted = key(label)
    for _, c in ipairs(classes or {}) do
        if key(c.label) == wanted then
            return c
        end
    end
    return nil
end

local function find_component(components, text, class, name)
    if text ~= "" then
        for _, c in ipairs(components) do
            for _, t in ipairs(c.text_values or {}) do
                if key(t) == key(text) then
                    return c
                end
            end
        end
    elseif class ~= nil then
        for _, c in ipairs(components) do
            if contains(c.class_ids, class.id) then
                return c
            end
        end
    end
    for _, c in ipairs(components) do
        if key(c.name) == key(name) then
            return c
        end
    end
    return nil
end

local function find_only(components, only, text, class)
    local chosen = {}
    for _, c in ipairs(components) do
        if contains(only, c.id) then
            chosen[#chosen + 1] = c
        end
    end
    if text ~= "" then
        for _, c in ipairs(chosen) do
            for _, t in ipairs(c.text_values or {}) do
                if key(t) == key(text) then
                    return c
                end
            end
        end
    end
    if class ~= nil then
        for _, c in ipairs(chosen) do
            if contains(c.class_ids, class.id) then
                return c
            end
        end
    end
    return nil
end

function populate.place(input)
    local threshold = tonumber(input.iou) or DEFAULT_IOU
    local found, texts = {}, {}
    local skipped, duplicates, outside = 0, 0, 0
    local only = input.only
    local reads = input.reads or "all"
    local presence = input.kind == "presence"
    for _, d in ipairs(input.detections or {}) do
        local ocr = d.kind == "ocr"
        if (ocr and reads == "yolo") or (not ocr and reads == "ocr") then
            -- not read
        elseif trim(d.label) == "" then
            skipped = skipped + 1
        elseif ocr then
            texts[#texts + 1] = d
        else
            found[#found + 1] = d
        end
    end
    local holders = {}
    for _, p in ipairs(input.placed or {}) do
        holders[#holders + 1] = p.component_id
    end
    local other = presence and holders or (input.counted or {})
    local conflicts = 0
    local counts, count_of = {}, {}
    local function tally(by, id)
        local k = by .. ":" .. tostring(id)
        local entry = count_of[k]
        if entry == nil then
            entry = { count = 0 }
            entry[by] = id
            count_of[k] = entry
            counts[#counts + 1] = entry
        end
        entry.count = entry.count + 1
    end
    local boxes = nms(found, threshold)
    for _, d in ipairs(texts) do
        boxes[#boxes + 1] = d
    end

    local components = input.components or {}
    local fresh, by_key = {}, {}
    local placements = {}
    for _, d in ipairs(boxes) do
        local text, class = "", nil
        if d.kind == "ocr" then
            text = trim(d.label)
        else
            class = class_of(d.label, input.classes)
            for _, t in ipairs(texts) do
                if inside(d, t) then
                    text = trim(t.label)
                    break
                end
            end
        end
        local name = text ~= "" and text or trim(d.label)
        local placement = {
            x = d.x,
            y = d.y,
            width = d.width,
            height = d.height,
            rotation = d.rotation or 0,
        }
        local existing
        if only ~= nil then
            existing = find_only(components, only, text, class)
        else
            existing = find_component(components, text, class, name)
        end
        if existing == nil and only ~= nil then
            outside = outside + 1
            placement = nil
        elseif existing ~= nil and contains(other, existing.id) then
            conflicts = conflicts + 1
            placement = nil
        elseif existing ~= nil and presence then
            tally("component_id", existing.id)
            placement = nil
        elseif existing ~= nil then
            if already_placed(input.placed, existing.id, placement, threshold) then
                duplicates = duplicates + 1
                placement = nil
            else
                placement.component_id = existing.id
            end
        else
            local k = key(name)
            local index = by_key[k]
            if index == nil then
                fresh[#fresh + 1] = {
                    name = name,
                    class_ids = class ~= nil and { class.id } or {},
                    text_values = text ~= "" and { text } or {},
                    width = d.width,
                    height = d.height,
                }
                index = #fresh
                by_key[k] = index
            end
            if presence then
                tally("new", index)
                placement = nil
            else
                placement.new = index
            end
        end
        if placement ~= nil then
            placements[#placements + 1] = placement
        end
    end
    return {
        placements = placements,
        counts = counts,
        new_components = fresh,
        skipped = skipped,
        duplicates = duplicates,
        outside = outside,
        conflicts = conflicts,
    }
end

-- populate.classes {
--   components = { { id, name, class_ids } },
--   classes    = { { id, label } },     -- the view model's classes
-- } -> { new_components = { { name, class_ids, text_values, width, height } },
--        existing = { component_id } }
--
-- Each class's component: the one linked to it, else named like it, as
-- `place` finds a class box's component, listed once in `existing`; else a
-- new one. Labels that read the same make one component.
function populate.classes(input)
    local components = input.components or {}
    local fresh, seen, existing, listed = {}, {}, {}, {}
    for _, class in ipairs(input.classes or {}) do
        local name = trim(class.label)
        local k = key(name)
        local found = name ~= "" and find_component(components, "", class, name) or nil
        if name == "" or seen[k] then
            -- nothing to name, or made already
        elseif found ~= nil then
            if not listed[found.id] then
                listed[found.id] = true
                existing[#existing + 1] = found.id
            end
        else
            seen[k] = true
            fresh[#fresh + 1] = {
                name = name,
                class_ids = { class.id },
                text_values = {},
                width = 0,
                height = 0,
            }
        end
    end
    return { new_components = fresh, existing = existing }
end

return populate
