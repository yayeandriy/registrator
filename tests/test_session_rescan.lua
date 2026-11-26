-- `session.rescan` through the composed session host, as hosts call it.

local script_dir = (arg[0]):match("(.*/)")
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(script_dir .. "../lua/json.lua")
local host = dofile(script_dir .. "compose.lua").load("session")

local function rescan(args)
    return json.decode(host(json.encode({ module = "session", op = "rescan", args = args })))
end

local function done(view_id, result)
    return { view_id = view_id, result = result }
end

local passed = rescan({ views_done = { done("front", "pass") }, phase = "next_view" })
t.eq(passed.failed, false, "nothing failed")
t.is_nil(passed.forget, "nothing to forget")

local kept = rescan({ views_done = {}, phase = "scored", result = "pass" })
t.eq(kept.result, "pass", "a passed end stays")

local two = rescan({
    views_done = { done("front", "pass"), done("back", "fail"), done("side", "fail") },
    phase = "next_view",
    result = "fail",
})
t.eq(two.failed, true, "two views failed")
t.eq(table.concat(two.forget, ","), "back,side", "the failed views, in order")
t.is_nil(two.result, "the failed end clears")

local live = rescan({
    views_done = { done("front", "pass") },
    phase = "scored",
    view_id = "back",
    verdict = { result = "fail" },
})
t.eq(live.failed, true, "the view on camera reads failed")
t.eq(table.concat(live.forget, ","), "back", "the view on camera is forgotten")

local unscored = rescan({ views_done = {}, phase = "reading", view_id = "back", verdict = { result = "fail" } })
t.eq(unscored.failed, false, "a failing read not yet scored is no fail")

local listed = rescan({
    views_done = { done("back", "fail") },
    phase = "scored",
    view_id = "back",
    verdict = { result = "fail" },
})
t.eq(table.concat(listed.forget, ","), "back", "a view forgotten once")

local ended = rescan({ views_done = {}, phase = "anchor_missing", result = "fail" })
t.eq(ended.failed, true, "a failed end with no view done")
t.eq(#ended.forget, 0, "no view to forget")

if not t.summary("session_rescan") then
    os.exit(1)
end
