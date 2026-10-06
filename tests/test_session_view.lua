-- Exercises `session_view.lua`, `session_extras.lua` and
-- `session.stop` / `session.overall` through the composed session host.

local script_dir = (arg[0]):match("(.*/)")
local lua_dir = script_dir .. "../lua/"
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(lua_dir .. "json.lua")
local host = dofile(script_dir .. "compose_session.lua")(lua_dir)

local function call(module, op, args)
    return json.decode(host(json.encode({ module = module, op = op, args = args })))
end

local function flags(list)
    local out = {}
    for i, v in ipairs(list) do
        out[i] = tostring(v)
    end
    return table.concat(out, ",")
end

local A, B = "view-a", "view-b"
local M = "model-1"
local objects = {
    { id = "tipA", profile_view_id = A, is_anchor = true, yolo_classes = { "block" },
        yolo_class_refs = { { class_id = "c-block", label = "block", vision_model_id = M } },
        children = { { id = "pinA", profile_view_id = A, yolo_classes = { "pin" },
            yolo_class_refs = { { class_id = "c-pin", label = "pin", vision_model_id = M } } } } },
    { id = "tipB", profile_view_id = B, is_anchor = true, yolo_classes = { "square" },
        yolo_class_refs = { { class_id = "c-square", label = "square", vision_model_id = M } } },
    { id = "capB", profile_view_id = B, yolo_classes = { "cap" },
        yolo_class_refs = { { class_id = "c-cap", label = "cap", vision_model_id = "model-2" } } },
}

-- Settle: the seen tip owns its view; an empty frame keeps the latch.
local seen = call("view", "settle", { objects = objects, completed = {},
    detections = { { label = "square", confidence = 0.9, class_id = "c-square" } } })
t.eq(seen.view_id, B, "seen tip settles its view")
local kept = call("view", "settle", { objects = objects, completed = {}, detections = {}, latched = A })
t.eq(kept.view_id, A, "dropout keeps the latch")
local done = call("view", "settle", { objects = objects, completed = { A }, detections = {}, latched = A })
t.eq(done.settled, false, "a completed view never settles again")

-- Scope: settled view's roots; otherwise the open tips only.
local scoped = call("view", "scope", { objects = objects, view_id = B, completed = {} })
t.eq(table.concat(scoped.ids, ","), "tipB,capB", "settled view placements")
local waiting = call("view", "scope", { objects = objects, completed = { A } })
t.eq(table.concat(waiting.ids, ","), "tipB", "open tips while waiting")
t.eq(waiting.anchors_only, true, "anchors only while waiting")
local single = call("view", "scope", { objects = { objects[1] }, completed = {} })
t.eq(single.anchors_only, false, "one view keeps the whole tree")

-- Frame: stamp class ids by (label, model) on the view; keep the view's classes.
local dets = {
    { kind = "yolo", label = "pin", vision_model_id = M },
    { kind = "yolo", label = "square", vision_model_id = M },
    { kind = "yolo", label = "pin", vision_model_id = nil },
    { kind = "ocr", label = "AB12" },
    { kind = "yolo", label = "chimney", vision_model_id = "model-9" },
}
local on_a = call("view", "frame", { objects = objects, view_id = A, completed = {}, catalog_keys = { "chimney" }, detections = dets })
t.eq(table.concat(on_a.class_ids, ","), "c-pin,,,,", "only this view's refs stamp, and only with a model")
t.eq(flags(on_a.keep), "true,true,false,true,true", "view classes and models, OCR and catalog classes stay")
local wait = call("view", "frame", { objects = objects, completed = { A }, catalog_keys = { "chimney" }, detections = dets })
t.eq(flags(wait.keep), "false,true,false,true,false", "waiting keeps the open tips only")
t.eq(wait.class_ids[2], "c-square", "waiting stamps across views")
local flat = call("view", "frame", { objects = { objects[1] }, completed = {}, catalog_keys = {}, detections = dets })
t.eq(flags(flat.keep), "true,true,true,true,true", "one unsettled view keeps everything")

-- Sticky Spatial extras.
local function reg(label, x, conf)
    return { label = label, x = x, y = 0, width = 10, height = 10, confidence = conf or 0.8 }
end
local first = call("extras", "sticky", { latched = {}, current = { reg("pin", 0, 0.7), reg("pin", 2, 0.9), reg("pin", 50) } })
t.eq(#first.detections, 2, "overlapping same-class boxes cluster")
t.eq(first.detections[1].x, 2, "most confident box of a cluster wins")
local drop = call("extras", "sticky", { latched = first.latched, current = {} })
t.eq(#drop.detections, 2, "a dropout keeps the extras")
t.eq(drop.latched[1].misses, 1, "a miss is counted")
local held = drop
for _ = 1, 3 do
    held = call("extras", "sticky", { latched = held.latched, current = {} })
end
t.eq(#held.detections, 0, "ghosts expire after the miss budget")
local rotate = call("extras", "sticky", { latched = first.latched, current = { reg("pin", 100) } })
t.eq(#rotate.detections, 1, "a class listed this tick drops its unmatched priors")
local moved = call("extras", "sticky", { latched = first.latched, current = { reg("pin", 3), reg("cap", 50) } })
t.eq(moved.detections[1].x, 3, "a matched prior follows the current box")
t.eq(#moved.detections, 2, "pin matched, new cap added, unmatched pin dropped")

-- Manual stop and the multi-view overall.
t.eq(call("session", "stop", { verdict = { result = "pass", complete = true } }).result, "pass", "complete pass passes")
t.eq(call("session", "stop", { verdict = { result = "pass", complete = false } }).result, "fail", "incomplete fails")
t.eq(call("session", "stop", {}).result, "fail", "no verdict fails")
t.eq(call("session", "overall", { run = "pass", view_results = { "fail" } }).result, "pass", "completion's run wins")
t.eq(call("session", "overall", { view_results = { "pass", "fail" } }).result, "fail", "one failed still fails")
t.eq(call("session", "overall", { view_results = {} }).result, "pass", "no failed still passes")

if not t.summary("session_view") then
    os.exit(1)
end
