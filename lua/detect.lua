-- Detector boxes from several models on one frame: one physical object
-- keeps one box.
--
-- op "collapse":
--   in:  { boxes = [{ x, y, width, height, confidence, kind?, corners? }],
--          iou = 0.45 }
--        One coordinate space for every box; `x`, `y` is the top-left
--        corner. `corners` (four `{ x, y }`) replaces the box by its
--        axis-aligned bounds.
--   out: { keep = [bool] }, aligned with `boxes`.
--
-- Highest confidence first. A box is dropped when its IoU with a box
-- already kept exceeds `iou`, whatever the two classes, unless it is the
-- smaller nested one: under half the kept box's area with its centre
-- inside it (a screw on a plate). Text boxes (`kind` "ocr" or "ocr:…")
-- are always kept and never drop another box.
--
-- op "class_ids":
--   in:  { catalog = [{ label, vision_model_id }],
--          detections = [{ label, vision_model_id }] }
--   out: { index = [n] }, aligned with `detections`: the 1-based position
--        of the first catalog class on the same model with the same
--        label key (`class_match.key`: case, outer space and
--        space-vs-underscore ignored), 0 when none.

-- Needs `boxes`, `class_match`.

local detect = {}

local function is_text(box)
    local kind = string.lower(tostring(box.kind or ""))
    return kind == "ocr" or kind:sub(1, 4) == "ocr:"
end

local function bounds(box)
    local corners = box.corners
    if type(corners) == "table" and #corners >= 4 then
        local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
        for i = 1, 4 do
            local p = corners[i]
            x1, y1 = math.min(x1, p.x), math.min(y1, p.y)
            x2, y2 = math.max(x2, p.x), math.max(y2, p.y)
        end
        return { x = x1, y = y1, width = x2 - x1, height = y2 - y1 }
    end
    return {
        x = box.x or 0,
        y = box.y or 0,
        width = math.max(box.width or 0, 0),
        height = math.max(box.height or 0, 0),
    }
end

local function nested_smaller(parent, child)
    local pa, ca = parent.width * parent.height, child.width * child.height
    if pa <= 0 or ca <= 0 or ca >= pa * 0.5 then
        return false
    end
    local cx, cy = child.x + child.width / 2, child.y + child.height / 2
    return cx >= parent.x and cx <= parent.x + parent.width
        and cy >= parent.y and cy <= parent.y + parent.height
end

function detect.collapse(input)
    local found = input.boxes or {}
    local threshold = tonumber(input.iou) or 0.45
    local keep, order = {}, {}
    for i, box in ipairs(found) do
        keep[i] = is_text(box)
        if not keep[i] then
            order[#order + 1] = i
        end
    end
    table.sort(order, function(a, b)
        local ca, cb = found[a].confidence or 0, found[b].confidence or 0
        if ca ~= cb then
            return ca > cb
        end
        return a < b
    end)
    local kept = {}
    for _, i in ipairs(order) do
        local box = bounds(found[i])
        local dropped = false
        for _, k in ipairs(kept) do
            if boxes.iou(k, box) > threshold and not nested_smaller(k, box) then
                dropped = true
                break
            end
        end
        if not dropped then
            keep[i] = true
            kept[#kept + 1] = box
        end
    end
    return { keep = keep }
end

local function catalog_ref(c)
    return { label = c.label, vision_model_id = c.vision_model_id }
end

function detect.class_ids(input)
    local by_key = {}
    for j, c in ipairs(input.catalog or {}) do
        local key = class_match.key(catalog_ref(c))
        if by_key[key] == nil then
            by_key[key] = j
        end
    end
    local index = {}
    for i, d in ipairs(input.detections or {}) do
        index[i] = by_key[class_match.key(catalog_ref(d))] or 0
    end
    return { index = index }
end

return detect
