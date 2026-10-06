-- Live extras / searching gate / fill / transform agreement.

local script_dir = (arg[0]):match("(.*/)") or "./"
local compose = dofile(script_dir .. "compose_live.lua")
local root = script_dir .. "../"
local live = assert(load(compose(root), "live.lua"))()
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(root .. "lua/json.lua")

local function round(v)
    return json.decode(json.encode(v))
end

local function box(id, class, x, routines, anchor)
    local presence = false
    for _, r in ipairs(routines) do
        if r == "presence_validate" then
            presence = true
        end
    end
    return {
        id = id,
        yolo_classes = { class },
        boundary = { x = x, y = 0, width = 8, height = 8 },
        rotation = 0,
        is_anchor = anchor and true or false,
        routines = routines,
        presence = presence,
        vision_model_id = "2353bf0c-1d76-4d4d-a6ee-aa7287d725c0",
        children = {},
        ocr_values = {},
    }
end

-- Presence-only miss is listed.
local presence_miss = round(live({
    expected = { box("aaaaaaaa-0000-4000-8000-000000000001", "square", 20, { "presence_validate" }, true) },
    frames = {
        {
            t = 0,
            detections = {
                { label = "blocklock", confidence = 0.9, x = 0.1, y = 0.1, width = 0.2, height = 0.05 },
            },
        },
    },
    presence = true,
    spatial = false,
    frame_aspect = 1,
}))
t.eq(presence_miss.anchor, "not_required", "presence-only: no anchor wait")
t.not_nil(presence_miss.presence, "presence-only: result")
t.eq(presence_miss.presence.objects[1].status, "missing", "presence-only miss")
t.eq(presence_miss.presence.objects[1].match_kind, "yolo", "presence-only yolo row")

-- Unseen spatial anchor → searching, no rows.
local searching = round(live({
    expected = {
        box("aaaaaaaa-0000-4000-8000-000000000002", "block", 0, { "spatial_validate" }, true),
        box("aaaaaaaa-0000-4000-8000-000000000003", "pin-side", 12, { "spatial_validate" }, false),
    },
    frames = {
        {
            t = 0,
            detections = {
                { label = "pin-side", confidence = 0.9, x = 0.22, y = 0.10, width = 0.06, height = 0.10 },
            },
        },
    },
    presence = true,
    spatial = true,
    frame_aspect = 1,
}))
t.eq(searching.anchor, "searching", "unseen anchor searches")
t.is_nil(searching.spatial, "searching: no spatial rows")
t.is_nil(searching.presence, "searching: no presence rows")

local agrees = live({
    op = "transform_agrees",
    a = { tx = 0.052, ty = 0.146, a = 0.001144, b = 0, c = 0, d = 0.000644, px = 0, py = 0 },
    b = { tx = 0.366, ty = 0.234, a = 0.000528, b = 0, c = 0, d = 0.000297, px = 0, py = 0 },
})
t.ok(not agrees.agrees, "second block transform does not agree")

local good = { tx = 0.052, ty = 0.146, a = 0.001144, b = 0, c = 0, d = 0.000644, px = 0, py = 0 }
local bad = { tx = 0.366, ty = 0.234, a = 0.000528, b = 0, c = 0, d = 0.000297, px = 0, py = 0 }
local consensus = live({
    op = "consensus_transform",
    transforms = { good, good, good, good, bad, good },
})
t.close(consensus.transform.tx, 0.052, 1e-9, "consensus picks the cluster")

local fill = live({
    op = "fill",
    accumulated = {
        { label = "pin-side", confidence = 0.9, x = 0, y = 0, width = 8, height = 8, kind = "yolo" },
    },
    frames = {
        { detections = { { label = "pin-side", confidence = 0.9, x = 0, y = 0, width = 8, height = 8, kind = "yolo" } } },
        {
            detections = {
                { label = "pin-side", confidence = 0.9, x = 0, y = 0, width = 8, height = 8, kind = "yolo" },
                { label = "blocklock", confidence = 0.9, x = 40, y = 0, width = 8, height = 8, kind = "yolo" },
            },
        },
    },
})
local restored = false
for _, d in ipairs(fill.detections) do
    if d.label == "blocklock" and math.abs(d.x - 40) < 1e-9 then
        restored = true
    end
end
t.ok(restored, "fill restores a dropped label")

if not t.summary("live") then
    os.exit(1)
end
