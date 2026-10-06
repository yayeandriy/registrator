-- prepare.lua spatial_branch / ensure_spatial_anchor.

local script_dir = (arg[0]):match("(.*/)") or "./"
local prepare = dofile(script_dir .. "../lua/prepare.lua")
local t = dofile(script_dir .. "asserts.lua")

local function box_at(id, x, w, h, routines, anchor)
    return {
        id = id,
        boundary = { x = x, y = 0, width = w, height = h },
        rotation = 0,
        is_anchor = anchor and true or false,
        routines = routines,
        children = {},
        yolo_classes = {},
    }
end

local presence = box_at("p", 0, 1, 1, { "presence_validate" }, false)
local spatial = box_at("s", 2, 3, 3, { "spatial_validate" }, false)
local branch = prepare({ op = "spatial_branch", objects = { presence, spatial } })
t.eq(#branch.objects, 1, "spatial_branch drops presence-only")
t.eq(branch.objects[1].id, "s", "spatial_branch keeps spatial")

local small = box_at("small", 0, 1, 1, { "spatial_validate" }, false)
local large = box_at("large", 2, 4, 4, { "spatial_validate" }, false)
local anchored = prepare({ op = "ensure_spatial_anchor", objects = { small, large } })
t.ok(not anchored.objects[1].is_anchor, "small is not the implicit tip")
t.ok(anchored.objects[2].is_anchor, "largest spatial becomes the tip")

local marked = box_at("marked", 0, 1, 1, { "spatial_validate" }, true)
local other = box_at("other", 2, 9, 9, { "spatial_validate" }, false)
local kept = prepare({ op = "ensure_spatial_anchor", objects = { marked, other } })
t.ok(kept.objects[1].is_anchor, "existing tip is kept")
t.ok(not kept.objects[2].is_anchor, "larger object is not stolen")

if not t.summary("prepare") then
    os.exit(1)
end
