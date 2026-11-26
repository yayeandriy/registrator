-- Composes the live-session scripts the way both hosts do (each file
-- wrapped as a local, `session_host.lua` last) and drives it over JSON.

local script_dir = (arg[0]):match("(.*/)")
local lua_dir = script_dir .. "../lua/"
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(lua_dir .. "json.lua")

local host = dofile(script_dir .. "compose.lua").load("session")

local function call(module, op, args)
    return json.decode(host(json.encode({ module = module, op = op, args = args })))
end

local merged = call("verdict", "merge", {
    presence = json.null,
    spatial = { result = "pass", matched = 1, total = 1, incorrect = 0, missing = 0, extra = 0,
        complete = true, no_expectations = false, rows = { { object_id = "a", label = "pin", status = "matched" } } },
    ocr_labels = {},
    needles = {},
    ocr = { wants_ocr = false },
})
t.eq(merged.verdict.result, "pass", "null presence is no presence")
t.eq(math.type(merged.verdict.matched), "integer", "counts stay integers")

local done = call("session", "completion", {
    verdict = merged.verdict, window_frames = 8, fail_frames = 12, tick_ms = 700,
    ticks_on_view = 0, fail_ticks = 0,
})
t.eq(done.action, "finish", "completion over JSON")

local empty = host(json.encode({ module = "zones", op = "latch", args = { holds = {}, visible = {} } }))
t.eq(empty, '{"holds":[]}', "empty arrays encode as arrays")

local placed = call("populate", "place", {
    detections = { { label = "pin", confidence = 0.9, x = 0, y = 0, width = 4, height = 4, kind = "yolo" } },
    components = {},
    classes = {},
})
t.eq(placed.placements[1].new, 1, "populate over JSON")

local ok = pcall(host, json.encode({ module = "nope", op = "x" }))
t.eq(ok, false, "unknown module raises")

-- Swift mode: `LuaVM` decodes with its own `json` instance and hands a table.
local other_json = dofile(lua_dir .. "json.lua")
local decoded = other_json.decode('{"module":"session","op":"anchor_search","args":{"ticks":null,"fail_frames":12,"tick_ms":700}}')
local search = host(decoded)
t.eq(search.ticks, 1, "table input, a foreign null reads as absent")

local settled = call("view", "settle", { objects = {}, detections = {}, completed = {} })
t.eq(settled.settled, false, "no view settles on an empty profile")
local none = call("report", "placeholder", { expected = {}, presence = true, spatial = true })
t.eq(none.kind, "none", "an empty profile has no placeholder rows")
local sticky = host(json.encode({ module = "extras", op = "sticky", args = { latched = {}, current = {} } }))
t.eq(sticky:find('"detections":[]', 1, true) ~= nil and sticky:find('"latched":[]', 1, true) ~= nil, true,
    "extras round-trip as arrays")
local fenced = call("populate", "place", {
    detections = {
        { label = "pin", confidence = 0.9, x = 0, y = 0, width = 10, height = 10, kind = "yolo" },
        { label = "pin", confidence = 0.9, x = 90, y = 90, width = 10, height = 10, kind = "yolo" },
    },
    components = {},
    classes = {},
    areas = { { { x = 0, y = 0 }, { x = 50, y = 0 }, { x = 50, y = 50 }, { x = 0, y = 50 } } },
})
t.eq(fenced.out_of_area, 1, "populate keeps to its areas through the host")

local collapsed = call("detect", "collapse", {
    boxes = {
        { x = 0, y = 0, width = 10, height = 10, confidence = 0.6 },
        { x = 1, y = 1, width = 10, height = 10, confidence = 0.9 },
    },
    iou = 0.45,
})
t.ok(collapsed.keep[1] == false and collapsed.keep[2] == true, "detect collapse over JSON")

-- A run kept in the VM: its state and window never cross.
local function kept(op, args)
    return json.decode(host(json.encode({ module = "session", op = op, args = args,
        keep = { "state", "window" } })))
end
local run = { needles = {}, zone_ids = {}, views = {}, presence = true, spatial = false, objects = {} }
local rules = { window = 3, miss_hold = 3, view_dwell = 8, next_view = 8, anchor_timeout = 3,
    finish = true, text_reads = "frame" }
local read
for i = 0, 1 do
    read = kept("reads", { run = run, rules = rules, reads = {}, text_read = false, t = i * 0.1 })
end
t.is_nil(read.state, "the state stays in the VM")
t.is_nil(read.window, "so does the window")
t.eq(#read.score.frames, 2, "the kept window carries over")
local ok = pcall(host, json.encode({ module = "session", op = "reads", args = { run = run,
    rules = rules, reads = 5, t = 0.2 }, keep = { "state", "window" } }))
t.ok(not ok, "bad reads raise")
read = kept("reads", { run = run, rules = rules, reads = {}, text_read = false, t = 0.3 })
t.eq(#read.score.frames, 3, "a failed op keeps what was kept")
local fresh = dofile(script_dir .. "compose.lua").load("session")
read = json.decode(fresh(json.encode({ module = "session", op = "reads", args = { run = run,
    rules = rules, reads = {}, t = 0.0 }, keep = { "state", "window" } })))
t.eq(#read.score.frames, 1, "another VM starts its own run")

if not t.summary("session_host") then
    os.exit(1)
end
