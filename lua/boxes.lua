-- Frame-space box geometry: `{ x, y, width, height }` boxes and
-- `{ x1, y1, x2, y2 }` regions. Missing numbers read as 0. Pure math.

local boxes = {}

-- A read belongs to an instance when its center sits inside the union
-- padded by this share of each side (at least `MIN_PAD`), so rim text
-- counts without pulling in frame-wide noise.
boxes.PAD_RATIO = 0.2
boxes.MIN_PAD = 0.025

local function num(v)
    return tonumber(v) or 0
end

function boxes.center(d)
    return num(d.x) + num(d.width) * 0.5, num(d.y) + num(d.height) * 0.5
end

function boxes.center_dist(a, b)
    local ax, ay = boxes.center(a)
    local bx, by = boxes.center(b)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- Axis-aligned union of `list`; nil when empty.
function boxes.union(list)
    local u = nil
    for _, d in ipairs(list) do
        local x, y = num(d.x), num(d.y)
        local x2, y2 = x + num(d.width), y + num(d.height)
        if not u then
            u = { x1 = x, y1 = y, x2 = x2, y2 = y2 }
        else
            u.x1 = math.min(u.x1, x)
            u.y1 = math.min(u.y1, y)
            u.x2 = math.max(u.x2, x2)
            u.y2 = math.max(u.y2, y2)
        end
    end
    return u
end

-- `region` grown by `boxes.PAD_RATIO` of each side, at least `MIN_PAD`.
function boxes.pad(region)
    if not region then
        return nil
    end
    local px = math.max((region.x2 - region.x1) * boxes.PAD_RATIO, boxes.MIN_PAD)
    local py = math.max((region.y2 - region.y1) * boxes.PAD_RATIO, boxes.MIN_PAD)
    return {
        x1 = region.x1 - px,
        y1 = region.y1 - py,
        x2 = region.x2 + px,
        y2 = region.y2 + py,
    }
end

-- Center of `d` inside `region`; a nil region holds everything.
function boxes.inside(region, d)
    if region == nil then
        return true
    end
    local cx, cy = boxes.center(d)
    return cx >= region.x1 and cx <= region.x2 and cy >= region.y1 and cy <= region.y2
end

function boxes.region_center(region)
    if not region then
        return 0, 0
    end
    return (region.x1 + region.x2) * 0.5, (region.y1 + region.y2) * 0.5
end

function boxes.iou(a, b)
    local ix = math.min(a.x + a.width, b.x + b.width) - math.max(a.x, b.x)
    local iy = math.min(a.y + a.height, b.y + b.height) - math.max(a.y, b.y)
    if ix <= 0 or iy <= 0 then
        return 0
    end
    local inter = ix * iy
    local union = a.width * a.height + b.width * b.height - inter
    return union > 0 and inter / union or 0
end

return boxes
