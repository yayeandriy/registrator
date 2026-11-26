-- One inspection run, tick by tick: the host gathers the reads, hands back
-- the state it was given last time, and scores the frames in between.
--
--   session.reads { state?, window?, run, rules, reads = { Det }, text_read, t }
--     -> { state, window, done, score? }
--   session.tick  { state, run, rules, scored } -> { state, snapshot }
--   session.finish    { state, run, rules } -> { state, snapshot }  (operator Finish)
--   session.stop_run  { state, run }        -> { state, snapshot }  (operator Stop)
--   session.rescan_run { state, run }       -> { state, snapshot, forget? }
--
-- `reads` drops text that left the table, picks the reads Presence scores
-- and returns `score = { frames, presence_detections, latched_view_id,
-- completed_view_ids, completed_zone_ids, spatial_hold }` for the scorer
-- (`done` once the run is over: nothing to score). `tick` takes what it
-- scored, `scored = { presence, spatial (bools: the engine ran),
-- presence_verdict?, spatial_verdict?, spatial_hold?, view_id?,
-- awaiting_view, awaiting_anchor, visible_zones }`, and runs every session
-- step on it: next view, view change, anchor search, merge, zones, latch,
-- settle, completion. `t` is seconds since the run began.
--
-- run   = { needles, zone_ids, views = { { id, await } }, presence, spatial,
--           objects = { { id, routines } } }
-- rules = { window, miss_hold, view_dwell, next_view, anchor_timeout,
--           finish, text_reads = "frame"|"window"|"view" }
-- snapshot = { phase, verdict?, view_id?, views_done = { { view_id, result,
--              verdict?, took? } }, result?, took?, finishable, rescannable }
-- phase = "reading"|"awaiting_view"|"next_view"|"searching_anchor"|
--         "anchor_missing"|"scored"
--
-- `state` and `window` are opaque to hosts. The window holds the frames and
-- kept text reads, which only `reads` needs: hosts hand it back to `reads`
-- alone, so the other ops never carry the frames.
--
-- Needs `session`, `session_zones`, `ocr_window`, `verdict` and
-- `session_steps` in scope.

local run_ops = {}

local FIRST_TICK_MS = 250
local MAX_TICK_MS = 10000

local function fresh()
    return {
        published = "", candidate = "", hits = 0, dirty = true,
        ocr_box_ticks = 0, ocr_empty_ticks = 0,
        view_ticks = 0, fail_ticks = 0, anchor_ticks = 0,
        views_done = {}, zone_holds = {}, awaiting_next = false, proposals = {},
        tick_ms = FIRST_TICK_MS, phase = "reading", matched_rows = {}, epoch = 0,
    }
end

-- A view restarted since the window was kept bumps the epoch: its frames
-- and text reads are dropped.
local function window_of(s, w)
    if w == nil or w.epoch ~= s.epoch then
        return { epoch = s.epoch, frames = {}, text_pool = {} }
    end
    return w
end

local function rounded(x)
    local r = math.floor(x)
    if x - r >= 0.5 then
        r = r + 1
    end
    return r
end

-- Ticks are timed from the reads; until two have landed the engine gets
-- `FIRST_TICK_MS`.
local function time(s, t)
    if s.last_t ~= nil then
        local ms = rounded((t - s.last_t) * 1000.0)
        if ms == ms and ms >= 1 and ms ~= math.huge then
            s.tick_ms = math.tointeger(math.min(ms, MAX_TICK_MS))
        end
    end
    s.first_t = s.first_t or t
    s.view_t = s.view_t or t
    s.last_t = t
end

local function read_facts(reads, text_read)
    local facts = { ocr_ticked = text_read == true, read_labels = {}, ocr_labels = {} }
    for _, read in ipairs(reads) do
        if read.kind == "ocr" then
            facts.ocr_ticked = true
            facts.ocr_labels[#facts.ocr_labels + 1] = read.label
        end
        if (read.width or 0) > 1e-6 and (read.height or 0) > 1e-6 then
            facts.read_labels[#facts.read_labels + 1] = read.label
        end
    end
    return facts
end

local function ids(list, field)
    local out = {}
    for i, item in ipairs(list) do
        out[i] = item[field]
    end
    return out
end

function run_ops.reads(input)
    local s = input.state or fresh()
    local run, rules = input.run or {}, input.rules or {}
    local w = window_of(s, input.window)
    if s.result ~= nil then
        return { state = s, window = w, done = true }
    end
    local t = input.t or 0.0
    time(s, t)
    local reads = input.reads or {}
    local facts = read_facts(reads, input.text_read)
    s.facts = facts
    w.frames[#w.frames + 1] = { t = t, detections = session_steps.copy(reads) }
    while #w.frames > (rules.window or 1) do
        table.remove(w.frames, 1)
    end
    local needles = run.needles or {}
    if #needles > 0 then
        w.frames = session_steps.call(ocr_window.drop_stale, {
            frames = w.frames, live_labels = facts.read_labels, needles = needles,
            ocr_ticked = facts.ocr_ticked,
        }).frames or {}
    end
    local mode = rules.text_reads or "frame"
    if mode ~= "frame" and #needles > 0 then
        local out = session_steps.call(ocr_window.text_reads, {
            mode = mode, reads = reads, frames = w.frames, pool = w.text_pool, needles = needles,
        })
        w.text_pool = out.pool or {}
        reads = out.reads or {}
    end
    return {
        state = s,
        window = w,
        done = false,
        score = {
            frames = w.frames,
            presence_detections = reads,
            latched_view_id = s.latched_view,
            completed_view_ids = ids(s.views_done, "view_id"),
            completed_zone_ids = ids(s.zone_holds, "object_id"),
            spatial_hold = s.spatial_hold,
        },
    }
end

local function answer(s, run, extra)
    local out = extra or {}
    out.state = s
    out.snapshot = session_steps.snapshot(s, run)
    return out
end

-- While a finished view stays up, the views scored vote on the next.
local function propose_next(s, rules, scored)
    local next = session_steps.call(session.next_view, {
        proposals = s.proposals, proposal = scored.view_id or "",
        window_frames = rules.next_view, tick_ms = s.tick_ms,
    })
    s.proposals = next.proposals or {}
    if next.adopt ~= nil then
        session_steps.adopt(s, next.adopt)
    end
end

-- Another view on camera starts its counters over.
local function track_view(s, scored)
    if s.latched_view ~= scored.view_id then
        session_steps.restart(s)
        s.view_ticks = 0
        s.fail_ticks = 0
    elseif not scored.awaiting_view then
        s.view_ticks = s.view_ticks + 1
    end
    local id = scored.view_id and session_steps.trim(scored.view_id) or ""
    if id ~= "" then
        s.latched_view = id
    elseif scored.awaiting_view then
        s.latched_view = nil
    end
end

function run_ops.tick(input)
    local s, run, rules = input.state or fresh(), input.run or {}, input.rules or {}
    local scored = input.scored or {}
    if s.result ~= nil then
        return answer(s, run)
    end
    if s.awaiting_next then
        propose_next(s, rules, scored)
        return answer(s, run)
    end
    track_view(s, scored)
    if scored.awaiting_view then
        s.phase = "awaiting_view"
        return answer(s, run)
    end
    if scored.awaiting_anchor then
        session_steps.seek_anchor(s, run, rules)
        return answer(s, run)
    end
    s.anchor_ticks = 0
    session_steps.judge(s, run, rules, scored)
    return answer(s, run)
end

-- The operator's Finish: one completion that ends the await still on
-- screen now, as an automatic completion would.
function run_ops.finish(input)
    local s, run, rules = input.state or fresh(), input.run or {}, input.rules or {}
    if session_steps.snapshot(s, run).finishable and s.verdict ~= nil then
        session_steps.complete(s, run, rules, session_steps.copy(s.verdict), s.latched_view, true)
    end
    return answer(s, run)
end

-- The operator's Stop: the run ends now, passing only on a complete pass.
function run_ops.stop_run(input)
    local s, run = input.state or fresh(), input.run or {}
    if s.result == nil then
        s.result = session.stop({ verdict = session_steps.copy(s.verdict) }).result
    end
    return answer(s, run)
end

-- Forgets every failed view, the view on camera when it reads failed, and
-- a failed end, so the run waits for a view again; passed views stay.
function run_ops.rescan_run(input)
    local s, run = input.state or fresh(), input.run or {}
    local out = session.rescan(session_steps.rescan_input(s))
    if not out.failed then
        return answer(s, run)
    end
    local kept = {}
    for _, done in ipairs(s.views_done) do
        if done.result ~= "fail" then
            kept[#kept + 1] = done
        end
    end
    s.views_done = kept
    s.result = nil
    session_steps.await_next_view(s)
    s.verdict = nil
    return answer(s, run, { forget = out.forget })
end

return run_ops
