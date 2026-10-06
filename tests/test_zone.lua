-- Zone geometry: point-in-polygon, exclusive smallest-zone assignment,
-- filter_keep, frame slack. Mirrors the former Rust `zone.rs` tests.

local script_dir = (arg[0]):match("(.*/)") or "./"
local zone = dofile(script_dir .. "../lua/zone.lua")
local t = dofile(script_dir .. "asserts.lua")

local function rect_zone(x0, y0, x1, y1)
    local min_x, max_x = math.min(x0, x1), math.max(x0, x1)
    local min_y, max_y = math.min(y0, y1), math.max(y0, y1)
    return {
        { x = min_x, y = min_y },
        { x = max_x, y = min_y },
        { x = max_x, y = max_y },
        { x = min_x, y = max_y },
    }
end

local function box_at(id, x, y, w, h)
    return { id = id, x = x, y = y, width = w, height = h, rotation = 0 }
end

local function set_has(list, id)
    for _, v in ipairs(list) do
        if v == id then
            return true
        end
    end
    return false
end

local zone_spec = { object_id = "tip", points = rect_zone(0, 0, 20, 20) }
local members = zone.zone_member_ids({
    box_at("tip", 0, 0, 8, 8),
    box_at("in", 4, 4, 4, 4),
    box_at("out", 40, 40, 4, 4),
}, { zone_spec })
t.ok(set_has(members[1], "tip"), "tip is a member of its zone")
t.ok(set_has(members[1], "in"), "inside box is a member")
t.ok(not set_has(members[1], "out"), "out-of-zone box is not a member")

local big = { object_id = "big", points = rect_zone(0, 0, 20, 20) }
local small = { object_id = "small", points = rect_zone(2, 2, 8, 8) }
local overlap = zone.zone_member_ids({ box_at("inner", 3, 3, 2, 2) }, { big, small })
t.ok(not set_has(overlap[1], "inner"), "overlapping: not assigned to the large zone")
t.ok(set_has(overlap[2], "inner"), "overlapping: assigned to the smallest zone")

local parent = {
    id = "parent",
    boundary = { x = 0, y = 0, width = 10, height = 10 },
    rotation = 0,
    is_anchor = false,
    children = {
        {
            id = "kid",
            boundary = { x = 1, y = 1, width = 2, height = 2 },
            rotation = 0,
            is_anchor = false,
            children = {},
        },
    },
}
local filtered = zone.filter_keep({ parent }, { "kid" })
t.eq(#filtered, 1, "filter_keep keeps one promoted child")
t.eq(filtered[1].id, "kid", "filter_keep id")
t.close(filtered[1].boundary.x, 1.0, 1e-9, "filter_keep promotes x")
t.close(filtered[1].boundary.y, 1.0, 1e-9, "filter_keep promotes y")

local a = {
    id = "a",
    boundary = { x = 0, y = 0, width = 4, height = 4 },
    is_anchor = true,
    children = {},
}
local b = {
    id = "b",
    boundary = { x = 10, y = 0, width = 4, height = 4 },
    is_anchor = true,
    children = {},
}
local sole = zone.with_sole_anchor({ a, b }, "a")
t.ok(sole[1].is_anchor, "sole_anchor keeps a")
t.ok(not sole[2].is_anchor, "sole_anchor clears b")

t.ok(zone.polygon_in_frame(rect_zone(0.1, 0.1, 0.4, 0.5)), "in-frame polygon")
t.ok(not zone.polygon_in_frame(rect_zone(-0.2, 0.1, 0.4, 0.5)), "left of frame")
t.ok(not zone.polygon_in_frame(rect_zone(0.8, 0.1, 1.3, 0.5)), "right of frame")

-- hits: every zone holding the whole box, nested boxes in board space.
local hit_out = zone({
    op = "hits",
    objects = {
        { id = "pcb", boundary = { x = 10, y = 0, width = 30, height = 10 }, children = {
            { id = "chip", boundary = { x = 2, y = 2, width = 2, height = 2 } },
        } },
        { id = "far", boundary = { x = 90, y = 90, width = 2, height = 2 } },
    },
    zones = {
        { object_id = "left", points = rect_zone(0, 0, 20, 20) },
        { object_id = "wide", points = rect_zone(0, 0, 50, 20) },
        { object_id = "open", points = { { x = 0, y = 0 }, { x = 1, y = 1 } } },
    },
})
t.eq(#hit_out.hits, 2, "boxes in no zone are left out")
t.eq(hit_out.hits[1].id, "pcb", "parent first")
t.eq(table.concat(hit_out.hits[1].zones, ","), "wide", "parent only fits the wide zone")
t.eq(hit_out.hits[2].id, "chip", "child box offset by its parent")
t.eq(table.concat(hit_out.hits[2].zones, ","), "left,wide", "child sits in both, the open path skipped")

if not t.summary("zone") then
    os.exit(1)
end
