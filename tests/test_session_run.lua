-- `session.reads` / `session.tick` / `session.finish` / `session.stop_run` /
-- `session.rescan_run` through the composed session host, over JSON as
-- hosts call them, with the scorer's answer made up per tick.

local script_dir = (arg[0]):match("(.*/)")
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(script_dir .. "../lua/json.lua")
local host = dofile(script_dir .. "compose.lua").load("session")

local function call(op, args)
    return json.decode(host(json.encode({ module = "session", op = op, args = args })))
end

local FRONT, BACK = "front", "back"
local OBJECTS = { { id = "o1", routines = { "presence_validate" } } }

local function rules(finish)
    return {
        window = 3, miss_hold = 3, view_dwell = 8, next_view = 8, anchor_timeout = 3,
        finish = finish, text_reads = "frame",
    }
end

local function run_of(views, zone_ids)
    return { needles = {}, zone_ids = zone_ids or {}, views = views or {}, presence = true,
        spatial = false, objects = OBJECTS }
end

local function views(await_id)
    return { { id = FRONT, await = await_id == FRONT }, { id = BACK, await = await_id == BACK } }
end

local function verdict(result)
    local status = result == "pass" and "matched" or "missing"
    return {
        result = result, matched = result == "pass" and 1 or 0, total = 1, incorrect = 0,
        missing = result == "pass" and 0 or 1, extra = 0, complete = result == "pass",
        no_expectations = false, rows = { { object_id = "o1", label = "Label", status = status } },
    }
end

local function scored(result, view_id)
    return {
        presence = result ~= nil, spatial = false, presence_verdict = result and verdict(result),
        view_id = view_id, awaiting_view = false, awaiting_anchor = false, visible_zones = {},
    }
end

-- One tick at `t`: the reads, then what the scorer said.
local function step(s, run, r, t, facts)
    local read = call("reads", { state = s, run = run, rules = r, reads = {}, text_read = false, t = t })
    if read.done then
        return read.state, nil, nil
    end
    local out = call("tick", { state = read.state, run = run, rules = r, scored = facts })
    return out.state, out.snapshot, read.score
end

local function ticks(s, run, r, from, count, facts)
    local snap
    for i = from, from + count - 1 do
        local next_state, next_snap = step(s, run, r, i * 0.1, facts)
        s, snap = next_state, next_snap or snap
    end
    return s, snap
end

local function done_ids(snap)
    local out = {}
    for _, done in ipairs(snap.views_done or {}) do
        out[#out + 1] = done.view_id .. ":" .. done.result
    end
    return table.concat(out, ",")
end

-- A settled pass ends a one-view run; its rows are listed for the card.
local s, snap = ticks(nil, run_of(), rules(true), 0, 6, scored("pass"))
t.eq(snap.result, "pass", "a settled pass ends the run")
t.eq(snap.verdict.matched, 1, "the verdict is shown")
t.eq(snap.verdict.rows[1].outcome, "pass", "rows carry their outcome")
t.eq(snap.verdict.rows[1].routine, "presence", "rows carry their routine")
t.ok(snap.took ~= nil and snap.took >= 0, "a finished run says how long it took")
local again = step(s, run_of(), rules(true), 9.0, scored("pass"))
t.eq(again.last_t, s.last_t, "a finished run takes no more ticks")

-- The window keeps only the latest frames.
local w, win, score = nil, nil, nil
for i = 0, 4 do
    local read = call("reads", { state = w, window = win, run = run_of(), rules = rules(false),
        reads = {}, t = i * 0.1 })
    w, win, score = read.state, read.window, read.score
end
local times = {}
for i, frame in ipairs(score.frames) do
    times[i] = string.format("%.17g", frame.t)
end
t.eq(table.concat(times, ","), "0.20000000000000001,0.30000000000000004,0.40000000000000002",
    "three frames, the latest")

-- Stopping an incomplete run fails it; stopping a finished one does not.
local idle = ticks(nil, run_of(), rules(false), 0, 4, scored(nil))
t.eq(call("tick", { state = idle, run = run_of(), rules = rules(false), scored = scored(nil) })
    .snapshot.phase, "reading", "nothing scored keeps reading")
t.eq(call("stop_run", { state = idle, run = run_of() }).snapshot.result, "fail", "an early stop fails")
t.eq(call("stop_run", { state = s, run = run_of() }).snapshot.result, "pass", "a passed run stays passed")

-- A settled view of a multi-view run finishes the view, not the run.
local multi = run_of(views())
local m, msnap = ticks(nil, multi, rules(true), 0, 6, scored("pass", FRONT))
t.eq(done_ids(msnap), "front:pass", "the front view is done")
t.is_nil(msnap.result, "the run goes on")
t.eq(msnap.phase, "next_view", "the next view is awaited")
t.eq(msnap.views_done[1].verdict.matched, 1, "a finished view keeps the verdict it ended on")
t.eq(msnap.views_done[1].verdict.rows[1].outcome, "pass", "listed too")
t.eq(msnap.rescannable, false, "nothing failed")

-- The next view is adopted once the tips agree, with nothing shown yet.
local adopted = ticks(m, multi, rules(true), 6, 12, scored(nil, BACK))
local asnap = call("tick", { state = adopted, run = multi, rules = rules(true), scored = scored(nil, BACK) }).snapshot
t.eq(asnap.view_id, BACK, "the back view is adopted")
t.is_nil(asnap.verdict, "nothing shown for the new view")
t.eq(done_ids(asnap), "front:pass", "the finished view stays done")

-- The last view of a multi-view run ends it with every view's result.
local _, last = ticks(adopted, multi, rules(true), 18, 6, scored("fail", BACK))
t.eq(done_ids(last), "front:pass,back:fail", "both views held")
t.eq(last.result, "fail", "one failed view fails the run")

-- Each view takes from its start to its finish.
local timed = run_of(views())
local ts = step(nil, timed, rules(true), 2.0, scored("pass", FRONT))
local tsnap
ts, tsnap = step(ts, timed, rules(true), 5.0, scored("pass", FRONT))
t.eq(tsnap.views_done[1].took, 3.0, "front from its first picture to its finish")
for _, at in ipairs({ 5.5, 6.0 }) do
    ts = step(ts, timed, rules(true), at, scored(nil, BACK))
end
for _, at in ipairs({ 7.0, 7.5 }) do
    ts, tsnap = step(ts, timed, rules(true), at, scored("pass", BACK))
end
t.eq(tsnap.views_done[2].took, 1.5, "back from its adoption to its finish")

-- An await view holds until the operator finishes it.
local held_run = run_of(views(FRONT))
local h, hsnap = ticks(nil, held_run, rules(true), 0, 10, scored("pass", FRONT))
t.eq(#hsnap.views_done, 0, "an await still never ends by itself")
t.eq(hsnap.finishable, true, "Finish is offered")
local finished = call("finish", { state = h, run = held_run, rules = rules(true) }).snapshot
t.eq(done_ids(finished), "front:pass", "Finish ends the still")
t.eq(finished.phase, "next_view", "and waits for the next")
t.eq(finished.finishable, false, "no Finish between views")

-- Finishing a lone await view ends the run, even without auto-finish.
local lone = run_of({ { id = FRONT, await = true } })
local l, lsnap = ticks(nil, lone, rules(false), 0, 10, scored("pass"))
t.is_nil(lsnap.result, "the lone still holds")
t.eq(lsnap.finishable, true, "a lone view stills whatever the latch says")
t.eq(call("finish", { state = l, run = lone, rules = rules(false) }).snapshot.result, "pass",
    "Finish passes it")

-- Finish does nothing before the still settles.
local early = call("finish", { run = held_run, rules = rules(true) }).snapshot
t.eq(early.phase, "reading", "nothing to finish")
t.is_nil(early.verdict, "nothing shown")
t.eq(#early.views_done, 0, "nothing done")

-- Another view on camera starts the window over.
local v1, v1_window
for i = 0, 2 do
    local read = call("reads", { state = v1, window = v1_window, run = multi, rules = rules(false),
        reads = {}, t = i * 0.1 })
    v1_window = read.window
    v1 = call("tick", { state = read.state, run = multi, rules = rules(false),
        scored = scored(nil, FRONT) }).state
end
t.eq(#v1_window.frames, 2, "the front view keeps its frames since it latched")
local switched = call("tick", { state = v1, run = multi, rules = rules(false), scored = scored(nil, BACK) }).state
local fresh_score = call("reads", { state = switched, window = v1_window, run = multi,
    rules = rules(false), reads = {}, t = 0.5 }).score
t.eq(#fresh_score.frames, 1, "the new view keeps only its own frame")
t.eq(fresh_score.latched_view_id, BACK, "and latches")

-- Waiting for a view says so.
local waiting = scored(nil)
waiting.awaiting_view = true
local _, wsnap = step(nil, multi, rules(false), 0.0, waiting)
t.eq(wsnap.phase, "awaiting_view", "no view on camera yet")

-- No anchor: the search fails the run once it outlasts the grace; zones
-- keep what they latched instead.
local lost = scored(nil)
lost.awaiting_anchor = true
local _, gone = ticks(nil, run_of(), rules(false), 0, 2, lost)
t.eq(gone.phase, "searching_anchor", "the search goes on within the grace")
local _, missing = ticks(nil, run_of(), rules(false), 0, 6, lost)
t.eq(missing.phase, "anchor_missing", "the anchor is missing")
t.eq(missing.result, "fail", "and the run fails")
local _, zoned_lost = ticks(nil, run_of({}, { "z1" }), rules(false), 0, 6, lost)
t.eq(zoned_lost.phase, "scored", "zones show what they kept")
t.is_nil(zoned_lost.result, "a zoned board never times out")

-- A zoned run of several views ends without holding a view.
local zoned = run_of(views(), { "z1" })
zoned.presence, zoned.spatial = false, true
local zfacts = scored(nil, FRONT)
zfacts.spatial, zfacts.spatial_verdict = true, verdict("pass")
zfacts.visible_zones = { { object_id = "z1", member_ids = { "o1" } } }
local _, zsnap = ticks(nil, zoned, rules(true), 0, 6, zfacts)
t.eq(zsnap.result, "pass", "every zone held passed")
t.eq(#zsnap.views_done, 0, "no view is held on a zoned run")

-- Rescan forgets the failed views and waits for a view again.
local function state_with(fields)
    local base = call("reads", { run = multi, rules = rules(false), reads = {}, t = 0.0 }).state
    for k, v in pairs(fields) do
        base[k] = v
    end
    return base
end
local function done(id, result)
    return { view_id = id, result = result }
end
local nothing = call("rescan_run", { state = state_with({ views_done = { done(FRONT, "pass") } }), run = multi })
t.is_nil(nothing.forget, "nothing failed, nothing forgotten")
local failed_views = state_with({
    views_done = { done(FRONT, "pass"), done(BACK, "fail"), done("side", "fail") }, result = "fail",
})
t.eq(call("tick", { state = failed_views, run = multi, rules = rules(false), scored = scored(nil) })
    .snapshot.rescannable, true, "a failed view can be rescanned")
local rescanned = call("rescan_run", { state = failed_views, run = multi })
t.eq(table.concat(rescanned.forget, ","), "back,side", "the failed views are forgotten")
t.is_nil(rescanned.snapshot.result, "the failed end clears")
t.eq(rescanned.snapshot.phase, "next_view", "the run waits for a view")
t.is_nil(rescanned.snapshot.verdict, "nothing shown")
t.eq(done_ids(rescanned.snapshot), "front:pass", "passed views stay")
local on_camera = state_with({
    views_done = { done(FRONT, "pass") }, phase = "scored", latched_view = BACK, verdict = verdict("fail"),
})
t.eq(table.concat(call("rescan_run", { state = on_camera, run = multi }).forget, ","), "back",
    "the view on camera reading failed is rescanned")
local ended = call("rescan_run", { state = state_with({ result = "fail" }), run = multi })
t.eq(#ended.forget, 0, "a failed end with no view done is rescanned")
t.is_nil(ended.snapshot.result, "and clears")
t.eq(call("tick", { state = state_with({ result = "fail" }), run = run_of(), rules = rules(false),
    scored = scored(nil) }).snapshot.rescannable, false, "a one-view run is never rescanned")

if not t.summary("session_run") then
    os.exit(1)
end
