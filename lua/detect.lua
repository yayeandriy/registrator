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
        return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
    end
    return {
        x = box.x or 0,
        y = box.y or 0,
        w = math.max(box.width or 0, 0),
        h = math.max(box.height or 0, 0),
    }
end

local function iou(a, b)
    local iw = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
    local ih = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
    if iw <= 0 or ih <= 0 then
        return 0
    end
    local inter = iw * ih
    local union = a.w * a.h + b.w * b.h - inter
    if union <= 0 then
        return 0
    end
    return inter / union
end

local function nested_smaller(parent, child)
    local pa, ca = parent.w * parent.h, child.w * child.h
    if pa <= 0 or ca <= 0 or ca >= pa * 0.5 then
        return false
    end
    local cx, cy = child.x + child.w / 2, child.y + child.h / 2
    return cx >= parent.x and cx <= parent.x + parent.w
        and cy >= parent.y and cy <= parent.y + parent.h
end

function detect.collapse(input)
    local boxes = input.boxes or {}
    local threshold = tonumber(input.iou) or 0.45
    local keep, order = {}, {}
    for i, box in ipairs(boxes) do
        keep[i] = is_text(box)
        if not keep[i] then
            order[#order + 1] = i
        end
    end
    table.sort(order, function(a, b)
        local ca, cb = boxes[a].confidence or 0, boxes[b].confidence or 0
        if ca ~= cb then
            return ca > cb
        end
        return a < b
    end)
    local kept = {}
    for _, i in ipairs(order) do
        local box = bounds(boxes[i])
        local dropped = false
        for _, k in ipairs(kept) do
            if iou(k, box) > threshold and not nested_smaller(k, box) then
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

return detect
