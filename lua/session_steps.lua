-- The steps `session_run.lua` takes on one tick's score: anchor search,
-- merge, zones, latch, settle and completion, and the resets between views.
-- Each step calls the session op hosts used to call one by one, on a copy
-- of its input as if it had crossed the host boundary.
--
-- Needs `session`, `session_zones`, `ocr_window`, `verdict` and
-- `verdict_lines` in scope.

local steps = {}

function steps.copy(v)
    if type(v) ~= "table" then
        return v
    end
    local out = {}
    for k, x in pairs(v) do
        out[k] = steps.copy(x)
    end
    return out
end

function steps.call(op, input)
    return op(steps.copy(input))
end

function steps.trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function blank()
    return {
        result = "", matched = 0, total = 0, incorrect = 0, missing = 0, extra = 0,
        complete = false, no_expectations = false, rows = {},
    }
end

-- A new view starts its own window, hold, kept text reads and matches.
function steps.restart(s)
    s.epoch = (s.epoch or 0) + 1
    s.spatial_hold = nil
    s.matched_rows = {}
end

-- Fresh window, fresh latch, nothing shown for the new view yet.
function steps.adopt(s, view_id)
    s.awaiting_next = false
    s.proposals = {}
    s.latched_view = view_id
    steps.restart(s)
    s.view_t = s.last_t
    s.view_ticks, s.fail_ticks = 0, 0
    s.published, s.candidate, s.hits = "", "", 0
    s.ocr_box_ticks, s.ocr_empty_ticks = 0, 0
    s.dirty = true
    s.verdict = nil
    s.phase = "reading"
end

-- The finished card stays up while the next tip settles.
function steps.await_next_view(s)
    s.awaiting_next = true
    s.proposals = {}
    s.latched_view = nil
    steps.restart(s)
    s.view_ticks = 0
    s.candidate, s.hits = "", 0
    s.phase = "next_view"
end

local function hold_view(s, view_id, result)
    local kept = {}
    for _, done in ipairs(s.views_done) do
        if done.view_id ~= view_id then
            kept[#kept + 1] = done
        end
    end
    local took
    if s.view_t ~= nil and s.last_t ~= nil then
        took = math.max(0.0, s.last_t - s.view_t)
    end
    kept[#kept + 1] = { view_id = view_id, result = result, verdict = steps.copy(s.verdict), took = took }
    s.views_done = kept
    s.fail_ticks = 0
end

-- The verdict shown, each row listed by `verdict.lines`.
local function show(s, run, v)
    if type(v) == "table" and type(v.rows) == "table" then
        local listed = verdict.lines({ rows = v.rows, objects = run.objects or {} }).lines
        for i, row in ipairs(v.rows) do
            row.outcome, row.routine = listed[i].outcome, listed[i].routine
        end
    end
    s.verdict = v
    s.phase = "scored"
end

local function compose(s, run, live, visible)
    return steps.call(session_zones.compose, {
        zone_ids = run.zone_ids or {}, live = live, holds = s.zone_holds, visible = visible or {},
    }).verdict
end

-- Whether the still of `view_id` is in await mode. A single-view profile
-- stills its only view whatever the latch says.
function steps.awaits(run, view_id)
    local views = run.views or {}
    if #views == 1 then
        return views[1].await == true
    end
    if view_id == nil then
        return false
    end
    local id = steps.trim(view_id)
    for _, view in ipairs(views) do
        if view.id == id and view.await == true then
            return true
        end
    end
    return false
end

local function is_done(s, id)
    for _, done in ipairs(s.views_done) do
        if done.view_id == id then
            return true
        end
    end
    return false
end

-- `session.completion` on a settled verdict: this view, or the run, may be
-- done. `finish` is the operator's Finish on an await still.
function steps.complete(s, run, rules, v, view_id, finish)
    local zone_ids = run.zone_ids or {}
    local zoned = #zone_ids > 0
    local views = run.views or {}
    local multi_view = #views > 1
    local id = view_id and steps.trim(view_id) or ""
    view_id = id ~= "" and id or nil
    if view_id ~= nil and type(v) == "table" then
        v.view_id = view_id
    end
    local views_left, holds, results = 0, {}, {}
    for _, view in ipairs(views) do
        if not is_done(s, view.id) and view.id ~= view_id then
            views_left = views_left + 1
        end
    end
    for i, hold in ipairs(s.zone_holds) do
        holds[i] = hold.pass
    end
    for i, done in ipairs(s.views_done) do
        results[i] = done.result
    end
    local out = steps.call(session.completion, {
        verdict = v, zoned = zoned, zone_holds = holds, zone_count = #zone_ids,
        multi_view = multi_view, view_done = view_id ~= nil and is_done(s, view_id),
        views_left = views_left, done_results = results, ticks_on_view = s.view_ticks,
        fail_ticks = s.fail_ticks, window_frames = rules.view_dwell, fail_frames = rules.miss_hold,
        tick_ms = s.tick_ms, await = steps.awaits(run, view_id), finish = finish,
    })
    s.fail_ticks = out.fail_ticks or 0
    show(s, run, v)
    local view_result = out.view_result or out.result
    if view_result == nil then
        return
    end
    if out.action == "view" then
        if view_id ~= nil and multi_view then
            hold_view(s, view_id, view_result)
            steps.await_next_view(s)
        end
    elseif out.action == "finish" and (rules.finish or finish) then
        if view_id ~= nil and multi_view and not zoned then
            hold_view(s, view_id, view_result)
        end
        s.result = out.result or view_result
    end
end

-- No anchor in the picture: zones keep what they latched; otherwise the
-- search runs until it times out and fails the run.
function steps.seek_anchor(s, run, rules)
    if #(run.zone_ids or {}) > 0 then
        s.anchor_ticks = 0
        show(s, run, compose(s, run, blank()))
        return
    end
    s.spatial_hold = nil
    s.dirty = true
    local search = session.anchor_search({
        ticks = s.anchor_ticks, fail_frames = rules.anchor_timeout, tick_ms = s.tick_ms,
    })
    s.anchor_ticks = search.ticks
    if search.missing then
        s.result = "fail"
        s.phase = "anchor_missing"
    else
        s.phase = "searching_anchor"
    end
end

-- Publishes the verdict once it has held, then lets completion move the
-- run on.
local function settle(s, run, rules, scored, v, readings, hold)
    local zoned = #(run.zone_ids or {}) > 0
    local settled = steps.call(session.settle, {
        verdict = v, published = s.published, candidate = s.candidate, hits = s.hits,
        dirty = s.dirty, readings = readings,
    })
    s.candidate, s.hits = settled.candidate, settled.hits
    if not settled.publish then
        if zoned then
            show(s, run, v)
        elseif s.verdict == nil then
            s.phase = "reading"
        end
        return
    end
    s.spatial_hold = hold
    s.dirty = false
    s.published = settled.fingerprint
    if zoned then
        s.zone_holds = steps.call(session_zones.latch, {
            holds = s.zone_holds, visible = scored.visible_zones or {}, verdict = v,
        }).holds or {}
        v = compose(s, run, v)
    end
    steps.complete(s, run, rules, v, scored.view_id, false)
end

-- Merges what scored into one verdict, then settles it.
function steps.judge(s, run, rules, scored)
    local zoned = #(run.zone_ids or {}) > 0
    local presence = scored.presence and not zoned and scored.presence_verdict or nil
    local spatial = scored.spatial and scored.spatial_verdict or nil
    if presence == nil and spatial == nil then
        if zoned then
            show(s, run, compose(s, run, blank()))
            return
        end
        s.dirty = true
        s.phase = "reading"
        return
    end
    local facts, needles = s.facts or {}, run.needles or {}
    local merged = steps.call(verdict.merge, {
        presence = presence, spatial = spatial, ocr_labels = facts.ocr_labels or {}, needles = needles,
        ocr = {
            wants_ocr = #needles > 0, engine_off = false, backend_ran = facts.ocr_ticked == true,
            read_labels = facts.read_labels or {}, box_ticks = s.ocr_box_ticks,
            empty_ticks = s.ocr_empty_ticks,
        },
    })
    local ocr = merged.ocr or {}
    s.ocr_box_ticks, s.ocr_empty_ticks = ocr.box_ticks or 0, ocr.empty_ticks or 0
    local v
    if zoned then
        v = compose(s, run, merged.verdict, scored.visible_zones)
    else
        local latched = steps.call(session_zones.latch_rows, { verdict = merged.verdict, latched = s.matched_rows })
        s.matched_rows = latched.latched or {}
        v = latched.verdict
    end
    local readings = {
        ocr_done = ocr.tick_finished == true, want_spatial = run.spatial == true,
        spatial_scored = spatial ~= nil, want_presence = run.presence == true,
        presence_scored = presence ~= nil,
    }
    local hold = spatial ~= nil and scored.spatial_hold or nil
    settle(s, run, rules, scored, v, readings, hold)
end

function steps.rescan_input(s)
    return {
        views_done = s.views_done, phase = s.phase, view_id = s.latched_view,
        verdict = s.verdict, result = s.result,
    }
end

function steps.snapshot(s, run)
    local took
    if s.result ~= nil and s.first_t ~= nil and s.last_t ~= nil then
        took = math.max(0.0, s.last_t - s.first_t)
    end
    return {
        phase = s.phase,
        verdict = s.verdict,
        view_id = s.latched_view,
        views_done = s.views_done,
        result = s.result,
        took = took,
        finishable = s.result == nil and s.phase == "scored" and steps.awaits(run, s.latched_view),
        rescannable = #(run.views or {}) > 1 and session.rescan(steps.rescan_input(s)).failed,
    }
end

return steps
