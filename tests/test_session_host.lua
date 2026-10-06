-- Composes the live-session scripts the way both hosts do (each file
-- wrapped as a local, `session_host.lua` last) and drives it over JSON.

local script_dir = (arg[0]):match("(.*/)")
local lua_dir = script_dir .. "../lua/"
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(lua_dir .. "json.lua")

local host = dofile(script_dir .. "compose_session.lua")(lua_dir)

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

if not t.summary("session_host") then
    os.exit(1)
end
