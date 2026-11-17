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
--     picked     = { class_id } | nil,      -- read these classes' boxes alone; none of `classes` = all
--     none_picked = true | nil,             -- with `picked`, none of `classes` = none
--     reads      = "yolo"|"ocr"|"all" | nil, -- which boxes count; nil = all
--     kind       = "spatial"|"presence" | nil, -- what a box becomes; nil = spatial
--     areas      = { { { x, y } } } | nil,  -- polygons on the board; none = the whole board
--     iou        = 0.5 | nil,
--     separate   = true | nil,           -- each box its own component
--   } -> {
--     placements     = { { component_id? , new?, x, y, width, height, rotation } },
--     counts         = { { component_id?, new?, count } },  -- kind = "presence"
--     new_components = { { name, class_ids, text_values, width, height, geometry? } },
--     skipped        = <boxes with no label>,
--     duplicates     = <boxes already placed>,
--     outside        = <boxes none of `only` is>,
--     unpicked       = <class boxes of classes not `picked`>,
--     conflicts      = <boxes of components the view holds the other way>,
--     out_of_area    = <boxes whose middle lies in none of `areas`>,
--   }
--
-- Boxes are in board units. Overlapping class boxes collapse to the most
-- confident one, whatever their classes (class-agnostic NMS); text boxes
-- are kept as found. A class box takes the first text box whose middle lies
-- inside it as its text. A box is the component whose texts hold its text;
-- else, with no text, the one linked to its class; else one named like it,
-- though never, for a class box, one that only reads texts; else a new
-- component, made once per text or class. A placement names a
-- catalog component by `component_id` or a new one by `new` (its index in
-- `new_components`). A box of a catalog component that overlaps one of that
-- component's `placed` boxes by `iou` or more is already placed and dropped.
-- With `only`, a box goes to the first of those components whose texts hold
-- its text, else the first linked to its class; nothing is made, names do
-- not count, and a box none of them is counts as `outside`.
-- With `areas`, a box (class or text) whose middle lies in none of those
-- polygons is dropped first, as `out_of_area`.
-- `reads = "yolo"` drops the text boxes (no box takes a text); `"ocr"`
-- drops the class boxes. With `picked`, a class box whose label is none of
-- those classes is dropped before anything else, as `unpicked`; a `picked`
-- holding none of `classes` picks every class, or none with `none_picked`. A component is placed by Spatial boxes or counted
-- by Presence on a view, not both: Spatial skips the boxes of `counted`
-- components, Presence those of components with `placed` boxes, each as a
-- conflict. Presence makes no placements; each component's boxes become
-- its count, in the order first found.
--
-- With `separate`, a box goes to the first component it is that is free
-- (Spatial: holds no `placed` box; either: took no box earlier in this
-- call), else to a new one of its own, named after it and numbered past
-- the names taken ("square", "square 2"); Presence counts each so 1. A
-- Spatial box overlapping a `placed` box of any of them is a duplicate.
-- None free, a box goes to the first with `only`, and is a conflict when
-- the first is held the other way.
--
-- Needs `zone` in scope (`zone.lua`): the hosts compose it ahead of this.

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

local function in_areas(areas, d)
    if areas == nil or #areas == 0 then
        return true
    end
    local cx, cy = d.x + d.width / 2, d.y + d.height / 2
    for _, points in ipairs(areas) do
        if zone.point_in_zone(points, cx, cy) then
            return true
        end
    end
    return false
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

-- Every component a box is, best first: those reading its text, else
-- (no text) those linked to its class; then those named like it, never,
-- for a class box, one that only reads texts.
local function matching(components, text, class, name)
    local out, seen = {}, {}
    local function add(c)
        if not seen[c] then
            seen[c] = true
            out[#out + 1] = c
        end
    end
    for _, c in ipairs(components) do
        if text ~= "" then
            for _, t in ipairs(c.text_values or {}) do
                if key(t) == key(text) then
                    add(c)
                end
            end
        elseif class ~= nil and contains(c.class_ids, class.id) then
            add(c)
        end
    end
    for _, c in ipairs(components) do
        local reads_only = #(c.class_ids or {}) == 0 and #(c.text_values or {}) > 0
        if key(c.name) == key(name) and not (class ~= nil and reads_only) then
            add(c)
        end
    end
    return out
end

-- Of `only`, those reading the box's text, then those linked to its class.
local function only_matching(components, only, text, class)
    local out = {}
    for _, c in ipairs(components) do
        if contains(only, c.id) and text ~= "" then
            for _, t in ipairs(c.text_values or {}) do
                if key(t) == key(text) then
                    out[#out + 1] = c
                    break
                end
            end
        end
    end
    for _, c in ipairs(components) do
        if contains(only, c.id) and class ~= nil and contains(c.class_ids, class.id) then
            out[#out + 1] = c
        end
    end
    return out
end

-- `base`, else `base 2`, `base 3`…: the first no component is named.
local function free_name(base, used)
    local n = 2
    if not used[key(base)] then
        return base
    end
    while used[key(base .. " " .. n)] do
        n = n + 1
    end
    return base .. " " .. n
end

function populate.place(input)
    local threshold = tonumber(input.iou) or DEFAULT_IOU
    local found, texts = {}, {}
    local skipped, duplicates, outside, unpicked, out_of_area = 0, 0, 0, 0, 0
    local only = input.only
    local picked = input.picked
    if picked ~= nil and not input.none_picked then
        local any = false
        for _, class in ipairs(input.classes or {}) do
            any = any or contains(picked, class.id)
        end
        if not any then
            picked = nil
        end
    end
    local function is_picked(label)
        local class = class_of(label, input.classes)
        return class ~= nil and contains(picked, class.id)
    end
    local reads = input.reads or "all"
    local presence = input.kind == "presence"
    for _, d in ipairs(input.detections or {}) do
        local ocr = d.kind == "ocr"
        if (ocr and reads == "yolo") or (not ocr and reads == "ocr") then
            -- not read
        elseif not in_areas(input.areas, d) then
            out_of_area = out_of_area + 1
        elseif trim(d.label) == "" then
            skipped = skipped + 1
        elseif ocr then
            texts[#texts + 1] = d
        elseif picked ~= nil and not is_picked(d.label) then
            unpicked = unpicked + 1
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
    local separate = input.separate == true
    local taken, used = {}, {}
    for _, id in ipairs(presence and {} or holders) do
        taken[id] = true
    end
    for _, c in ipairs(components) do
        used[key(c.name)] = true
    end
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
        local candidates = only ~= nil and only_matching(components, only, text, class)
            or matching(components, text, class, name)
        local existing = candidates[1]
        local duplicate = false
        if separate then
            existing = nil
            for _, c in ipairs(candidates) do
                duplicate = duplicate
                    or (not presence and already_placed(input.placed, c.id, placement, threshold))
                if existing == nil and not taken[c.id] and not contains(other, c.id) then
                    existing = c
                end
            end
            local first = candidates[1]
            if existing == nil and first ~= nil and (only ~= nil or contains(other, first.id)) then
                existing = first
            end
        end
        if duplicate then
            duplicates = duplicates + 1
            placement = nil
        elseif existing == nil and only ~= nil then
            outside = outside + 1
            placement = nil
        elseif existing ~= nil and contains(other, existing.id) then
            conflicts = conflicts + 1
            placement = nil
        elseif existing ~= nil and presence then
            tally("component_id", existing.id)
            taken[existing.id] = true
            placement = nil
        elseif existing ~= nil then
            if already_placed(input.placed, existing.id, placement, threshold) then
                duplicates = duplicates + 1
                placement = nil
            else
                placement.component_id = existing.id
                taken[existing.id] = true
            end
        else
            local k = key(name)
            local index = not separate and by_key[k] or nil
            if index == nil then
                local named = separate and free_name(name, used) or name
                used[key(named)] = true
                fresh[#fresh + 1] = {
                    name = named,
                    class_ids = class ~= nil and { class.id } or {},
                    text_values = text ~= "" and { text } or {},
                    width = d.width,
                    height = d.height,
                    geometry = class ~= nil and class.geometry or nil,
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
        unpicked = unpicked,
        conflicts = conflicts,
        out_of_area = out_of_area,
    }
end

return populate
