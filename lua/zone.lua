-- Board-space zone membership for multi-anchor inspect.
--
-- Standalone: `local zone = dofile("zone.lua")`. No `require`.
--
-- Input (when called as `zone(input)`):
--   { op = "polygon_in_frame"|"point_in_zone"|"box_inside_zone"|
--          "zone_member_ids"|"filter_keep"|"with_sole_anchor"|
--          "flatten_abs"|"usable_zones"|"hits", ... }
--   hits { objects, zones } -> { hits = { { id, zones = { object_id } } } }
-- Or call the named helpers on the returned table.

local FRAME_SLACK = 0.02
local MIN_ZONE_POINTS = 3

local function hypot(dx, dy)
    return math.sqrt(dx * dx + dy * dy)
end

local function object_id(o)
    if type(o) ~= "table" then
        return tostring(o or "")
    end
    return tostring(o.id or o.object_id or "")
end

local function orient(ax, ay, bx, by, cx, cy)
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end

local function point_on_segment(ax, ay, bx, by, x, y)
    local abx, aby = bx - ax, by - ay
    local len2 = abx * abx + aby * aby
    if len2 < 1e-18 then
        return false
    end
    local dist = math.abs((x - ax) * aby - (y - ay) * abx) / math.sqrt(len2)
    if dist > 1e-6 then
        return false
    end
    local dot = (x - ax) * abx + (y - ay) * aby
    return dot >= -1e-6 and dot <= len2 + 1e-6
end

local function point_on_boundary(pts, x, y)
    local n = #pts
    for i = 1, n do
        local a, b = pts[i], pts[i % n + 1]
        local ax, ay = a.x or a[1], a.y or a[2]
        local bx, by = b.x or b[1], b.y or b[2]
        if hypot(bx - ax, by - ay) >= 1e-9 then
            if point_on_segment(ax, ay, bx, by, x, y) then
                return true
            end
        end
    end
    return false
end

local function point_in_zone(pts, x, y)
    if type(pts) ~= "table" or #pts < MIN_ZONE_POINTS then
        return false
    end
    if point_on_boundary(pts, x, y) then
        return true
    end
    local wn = 0
    local n = #pts
    local j = n
    for i = 1, n do
        local pi, pj = pts[i], pts[j]
        local xi, yi = pi.x or pi[1], pi.y or pi[2]
        local xj, yj = pj.x or pj[1], pj.y or pj[2]
        if hypot(xj - xi, yj - yi) < 1e-9 then
            j = i
        else
            if yj <= y then
                if yi > y and orient(xj, yj, xi, yi, x, y) > 0 then
                    wn = wn + 1
                end
            elseif yi <= y and orient(xj, yj, xi, yi, x, y) < 0 then
                wn = wn - 1
            end
            j = i
        end
    end
    return wn ~= 0
end

local function polygon_in_frame(pts)
    if type(pts) ~= "table" or #pts < 3 then
        return false
    end
    local function inside(x, y)
        return x >= -FRAME_SLACK and x <= 1.0 + FRAME_SLACK
            and y >= -FRAME_SLACK and y <= 1.0 + FRAME_SLACK
    end
    for _, p in ipairs(pts) do
        if not inside(p.x or p[1], p.y or p[2]) then
            return false
        end
    end
    local n = #pts
    for i = 1, n do
        local a, b = pts[i], pts[i % n + 1]
        local ax, ay = a.x or a[1], a.y or a[2]
        local bx, by = b.x or b[1], b.y or b[2]
        if not inside((ax + bx) * 0.5, (ay + by) * 0.5) then
            return false
        end
    end
    return true
end

local function polygon_area(pts)
    if type(pts) ~= "table" or #pts < 3 then
        return 0.0
    end
    local acc = 0.0
    local n = #pts
    for i = 1, n do
        local a, b = pts[i], pts[i % n + 1]
        acc = acc + (a.x or a[1]) * (b.y or b[2]) - (b.x or b[1]) * (a.y or a[2])
    end
    return math.abs(acc) * 0.5
end

local function oriented_corners(x, y, w, h, deg)
    local cx, cy = x + w * 0.5, y + h * 0.5
    local rad = math.rad(deg or 0)
    local s, c = math.sin(rad), math.cos(rad)
    local pts = { { x, y }, { x + w, y }, { x + w, y + h }, { x, y + h } }
    local out = {}
    for i, p in ipairs(pts) do
        local dx, dy = p[1] - cx, p[2] - cy
        out[i] = { x = cx + dx * c - dy * s, y = cy + dx * s + dy * c }
    end
    return out
end

local function box_inside_zone(zone_pts, b)
    if type(zone_pts) ~= "table" or #zone_pts < MIN_ZONE_POINTS then
        return false
    end
    local w, h = b.width or 0, b.height or 0
    if w <= 0 or h <= 0 then
        return false
    end
    local x, y, rot = b.x or 0, b.y or 0, b.rotation or 0
    local corners = oriented_corners(x, y, w, h, rot)
    if not point_in_zone(zone_pts, x + w * 0.5, y + h * 0.5) then
        return false
    end
    for _, p in ipairs(corners) do
        if not point_in_zone(zone_pts, p.x, p.y) then
            return false
        end
    end
    for i = 1, 4 do
        local a, bpt = corners[i], corners[i % 4 + 1]
        if not point_in_zone(zone_pts, (a.x + bpt.x) * 0.5, (a.y + bpt.y) * 0.5) then
            return false
        end
    end
    return true
end

local function walk_abs(objects, ox, oy, out)
    for _, o in ipairs(objects or {}) do
        local b = o.boundary or {}
        local x = ox + (b.x or 0)
        local y = oy + (b.y or 0)
        out[#out + 1] = {
            id = object_id(o),
            x = x,
            y = y,
            width = b.width or 0,
            height = b.height or 0,
            rotation = o.rotation or 0,
        }
        walk_abs(o.children, x, y, out)
    end
end

local function flatten_abs(objects)
    local out = {}
    walk_abs(objects, 0.0, 0.0, out)
    return out
end

local function usable_zones(zones)
    local out = {}
    for _, z in ipairs(zones or {}) do
        local pts = z.points or {}
        local id = tostring(z.object_id or "")
        if #pts >= MIN_ZONE_POINTS and id:match("%S") then
            out[#out + 1] = z
        end
    end
    return out
end

local function zone_member_ids(boxes, zones)
    local members = {}
    for i, z in ipairs(zones or {}) do
        members[i] = { [tostring(z.object_id or "")] = true }
    end
    for _, b in ipairs(boxes or {}) do
        local skip = false
        for _, z in ipairs(zones or {}) do
            if tostring(z.object_id or "") == tostring(b.id or "") then
                skip = true
                break
            end
        end
        if not skip then
            local best_i, best_a = nil, nil
            for i, z in ipairs(zones or {}) do
                if box_inside_zone(z.points, b) then
                    local area = polygon_area(z.points)
                    if best_i == nil or area < best_a then
                        best_i, best_a = i, area
                    end
                end
            end
            if best_i then
                members[best_i][tostring(b.id or "")] = true
            end
        end
    end
    local lists = {}
    for i, set in ipairs(members) do
        local ids = {}
        for id in pairs(set) do
            ids[#ids + 1] = id
        end
        lists[i] = ids
    end
    return lists
end

-- Per placement, every usable zone whose polygon holds its whole box (a
-- box may sit in several). Placements in no zone are left out.
local function zone_hits(objects, zones)
    local usable = usable_zones(zones)
    local out = {}
    for _, b in ipairs(flatten_abs(objects)) do
        local ids = {}
        for _, z in ipairs(usable) do
            if box_inside_zone(z.points, b) then
                ids[#ids + 1] = tostring(z.object_id)
            end
        end
        if #ids > 0 then
            out[#out + 1] = { id = b.id, zones = ids }
        end
    end
    return out
end

local function copy_object(o)
    local c = {}
    for k, v in pairs(o) do
        c[k] = v
    end
    return c
end

local function with_sole_anchor(tree, oid)
    local out = {}
    for _, o in ipairs(tree or {}) do
        local copy = copy_object(o)
        copy.is_anchor = object_id(o) == tostring(oid)
        copy.children = with_sole_anchor(o.children, oid)
        out[#out + 1] = copy
    end
    return out
end

local function keep_has(keep, id)
    if type(keep) ~= "table" then
        return false
    end
    if keep[id] == true then
        return true
    end
    for _, v in ipairs(keep) do
        if tostring(v) == id then
            return true
        end
    end
    return false
end

local function filter_keep(tree, keep)
    local out = {}
    for _, o in ipairs(tree or {}) do
        local kids = filter_keep(o.children, keep)
        if keep_has(keep, object_id(o)) then
            local copy = copy_object(o)
            copy.children = kids
            out[#out + 1] = copy
        else
            local b = o.boundary or {}
            for _, kid in ipairs(kids) do
                local k = copy_object(kid)
                local kb = {}
                for kk, vv in pairs(kid.boundary or {}) do
                    kb[kk] = vv
                end
                kb.x = (kb.x or 0) + (b.x or 0)
                kb.y = (kb.y or 0) + (b.y or 0)
                k.boundary = kb
                out[#out + 1] = k
            end
        end
    end
    return out
end

local zone = {
    FRAME_SLACK = FRAME_SLACK,
    point_in_zone = point_in_zone,
    point_in_polygon = point_in_zone,
    polygon_in_frame = polygon_in_frame,
    polygon_area = polygon_area,
    box_inside_zone = box_inside_zone,
    flatten_abs = flatten_abs,
    usable_zones = usable_zones,
    zone_member_ids = zone_member_ids,
    zone_hits = zone_hits,
    with_sole_anchor = with_sole_anchor,
    filter_keep = filter_keep,
}

function zone.dispatch(input)
    input = input or {}
    local op = input.op
    if op == "polygon_in_frame" then
        return { ok = polygon_in_frame(input.points) }
    elseif op == "point_in_zone" then
        return { ok = point_in_zone(input.points, input.x, input.y) }
    elseif op == "box_inside_zone" then
        return { ok = box_inside_zone(input.points, input.box) }
    elseif op == "flatten_abs" then
        return { boxes = flatten_abs(input.objects) }
    elseif op == "usable_zones" then
        return { zones = usable_zones(input.zones) }
    elseif op == "zone_member_ids" then
        return { members = zone_member_ids(input.boxes, input.zones) }
    elseif op == "hits" then
        return { hits = zone_hits(input.objects, input.zones) }
    elseif op == "filter_keep" then
        return { objects = filter_keep(input.objects, input.keep) }
    elseif op == "with_sole_anchor" then
        return { objects = with_sole_anchor(input.objects, input.object_id) }
    end
    return { error = "unknown zone op" }
end

return setmetatable(zone, {
    __call = function(_, input)
        return zone.dispatch(input)
    end,
})
