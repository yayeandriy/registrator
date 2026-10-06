-- Live session policy: when a still is finished, which still is next,
-- when a verdict is stable enough to show, and when the board is lost.
--
-- Hosts own the clock and the camera; they call these ops once per
-- scored tick with the counters they were handed back last time.
--
-- Ops (`{ op = "<name>", ... }`):
--
--   completion  { verdict, zoned, zone_holds = { bool }, zone_count,
--                 multi_view, view_done, views_left, done_results = { "pass"|"fail" },
--                 ticks_on_view, fail_ticks, window_frames, fail_frames, tick_ms }
--     -> { action = "none"|"view"|"finish", result?, fail_ticks }
--   next_view   { proposals = { "<id>"|"" }, proposal, window_frames, tick_ms }
--     -> { proposals, adopt? }
--   settle      { verdict, published, candidate, hits, dirty,
--                 readings = { ocr_done, want_spatial, spatial_scored,
--                              want_presence, presence_scored } }
--     -> { publish, candidate, hits, fingerprint }
--   anchor_search { ticks, fail_frames, tick_ms } -> { ticks, missing }
--   router_completion { ready, any_value, fail_ticks, fail_frames, tick_ms }
--     -> { result? = "pass"|"fail", fail_ticks }
--   ticks_for_frames { frames, tick_ms } -> { ticks }
--   stop        { verdict? } -> { result }  (operator stop: the still's result)
--   overall     { run?, view_results = { "pass"|"fail" } } -> { result }
--
-- Zone latch / compose live in `session_zones.lua`.

local session = {}

-- The phone samples this many frames a second. A desktop tick is longer,
-- so a phone frame gate becomes ticks of the same wall-clock length.
local PHONE_FPS = 12.0
-- Consecutive equal verdicts before PASS / FAIL may show.
local SETTLE_AGREE = 2
-- A still must hold at least this many frames before a miss may end it.
local MIN_WINDOW_FRAMES = 8

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function same_view(a, b)
    return trim(a):lower() == trim(b):lower()
end

function session.ticks(frames, tick_ms)
    local secs = math.max(1, frames or 1) / PHONE_FPS
    local tick = math.max(1, tick_ms or 1) / 1000.0
    local n = math.floor(secs / tick + 0.5)
    return math.max(2, n)
end

function session.ticks_for_frames(input)
    return { ticks = session.ticks(input.frames, input.tick_ms) }
end

-- About 60% of the window must agree before a tip owns the next still.
local function quorum(window)
    window = math.max(1, window)
    return math.max((window * 3 + 4) // 5, window // 2 + 1)
end

local function stable_view(proposals, window)
    if #proposals < window then
        return nil
    end
    local order, count = {}, {}
    for _, id in ipairs(proposals) do
        if trim(id) ~= "" then
            local key
            for _, k in ipairs(order) do
                if same_view(k, id) then
                    key = k
                    break
                end
            end
            if key == nil then
                key = id
                order[#order + 1] = id
                count[id] = 0
            end
            count[key] = count[key] + 1
        end
    end
    local best, best_n = nil, -1
    for _, k in ipairs(order) do
        if count[k] >= best_n then
            best, best_n = k, count[k]
        end
    end
    if best ~= nil and best_n >= quorum(window) then
        return best
    end
    return nil
end

function session.next_view(input)
    local window = session.ticks(math.max(input.window_frames or 0, MIN_WINDOW_FRAMES), input.tick_ms)
    local seen = {}
    for _, id in ipairs(input.proposals or {}) do
        seen[#seen + 1] = id
    end
    seen[#seen + 1] = trim(input.proposal)
    while #seen > window do
        table.remove(seen, 1)
    end
    return { proposals = seen, adopt = stable_view(seen, window) }
end

-- One failed still fails the session.
local function union_result(results)
    for _, r in ipairs(results or {}) do
        if r == "fail" then
            return "fail"
        end
    end
    return "pass"
end

-- Only a complete PASS passes when the operator stops a still early.
function session.stop(input)
    local v = input.verdict or {}
    return { result = (v.result == "pass" and v.complete == true) and "pass" or "fail" }
end

-- `completion`'s run result when it decided the run, else the union of
-- every scored still (a manual stop decides no run).
function session.overall(input)
    if input.run == "pass" or input.run == "fail" then
        return { result = input.run }
    end
    return { result = union_result(input.view_results) }
end

-- A complete PASS finishes the still at once and surplus fails it at once.
-- A miss waits for a multi-view still to settle and then for the grace,
-- so a dropout of one or two ticks never decides the run.
local function sample(tick)
    if tick.complete_pass then
        return "pass"
    end
    if tick.has_extras then
        return "fail"
    end
    if tick.multi_view and tick.ticks_on_view < tick.settle_ticks then
        return nil
    end
    if tick.fail_ticks >= math.max(1, tick.fail_grace) then
        return "fail"
    end
    return nil
end

function session.completion(input)
    local v = input.verdict or {}
    local fail_ticks = input.fail_ticks or 0
    if input.zoned then
        local holds = input.zone_holds or {}
        if #holds < (input.zone_count or 0) then
            return { action = "none", fail_ticks = fail_ticks }
        end
        local all = true
        for _, pass in ipairs(holds) do
            all = all and pass
        end
        return { action = "finish", result = all and "pass" or "fail", fail_ticks = fail_ticks }
    end
    if v.awaiting_view or v.no_expectations or (v.total or 0) == 0 then
        return { action = "none", fail_ticks = fail_ticks }
    end
    if input.multi_view and (trim(v.view_id) == "" or input.view_done) then
        return { action = "none", fail_ticks = fail_ticks }
    end
    local complete_pass = v.result == "pass" and v.complete == true
    fail_ticks = complete_pass and 0 or fail_ticks + 1
    local result = sample({
        complete_pass = complete_pass,
        has_extras = (v.extra or 0) > 0,
        multi_view = input.multi_view,
        ticks_on_view = input.ticks_on_view or 0,
        settle_ticks = session.ticks(math.max(input.window_frames or 0, MIN_WINDOW_FRAMES), input.tick_ms),
        fail_ticks = fail_ticks,
        fail_grace = session.ticks(math.max(1, input.fail_frames or 1), input.tick_ms),
    })
    if result == nil then
        return { action = "none", fail_ticks = fail_ticks }
    end
    if not input.multi_view then
        return { action = "finish", result = result, fail_ticks = fail_ticks }
    end
    if (input.views_left or 0) > 0 then
        return { action = "view", result = result, fail_ticks = 0 }
    end
    local all = {}
    for _, r in ipairs(input.done_results or {}) do
        all[#all + 1] = r
    end
    all[#all + 1] = result
    return { action = "finish", view_result = result, result = union_result(all), fail_ticks = 0 }
end

local function fingerprint(v)
    local zones = {}
    for _, z in ipairs(v.zone_chips or {}) do
        if z.pending then
            zones[#zones + 1] = z.hex .. ":open"
        else
            zones[#zones + 1] = string.format("%s:%d/%d", z.hex, z.matched, z.total)
        end
    end
    return string.format("%s:%d:%d:%d:%d:%s", v.result, v.matched or 0, v.incorrect or 0,
        v.missing or 0, v.extra or 0, table.concat(zones, ","))
end

-- One finished tick from each requested engine — not a full live window
-- and not the OCR settle ticks, which left Reading up while the overlay
-- already had every box.
local function readings_complete(r)
    return r.ocr_done == true
        and (not r.want_spatial or r.spatial_scored == true)
        and (not r.want_presence or r.presence_scored == true)
end

-- Show a verdict only when it repeats the last published one, or the
-- same verdict has come back SETTLE_AGREE times in a row.
function session.settle(input)
    local fp = fingerprint(input.verdict or {})
    local candidate, hits = input.candidate or "", input.hits or 0
    local out = { publish = false, candidate = candidate, hits = hits, fingerprint = fp }
    if not readings_complete(input.readings or {}) or fp:sub(1, 8) == "pending:" then
        return out
    end
    local published = input.published or ""
    if published ~= "" and published == fp and not input.dirty then
        out.candidate, out.hits, out.publish = fp, SETTLE_AGREE, true
        return out
    end
    if candidate == fp then
        hits = hits + 1
    else
        candidate, hits = fp, 1
    end
    out.candidate, out.hits, out.publish = candidate, hits, hits >= SETTLE_AGREE
    return out
end

-- The anchor places every row. Once the search outlasts the grace a
-- miss gets, the board is not on the table.
function session.anchor_search(input)
    local ticks = (input.ticks or 0) + 1
    local grace = session.ticks(math.max(1, input.fail_frames or 1), input.tick_ms)
    return { ticks = ticks, missing = ticks >= grace }
end

-- Router scan: PASS once every value is in; FAIL only after the scan has
-- come up empty for the grace. Any value read resets the grace — date /
-- time often land before the barcode does.
function session.router_completion(input)
    if input.ready then
        return { result = "pass", fail_ticks = 0 }
    end
    if input.any_value then
        return { fail_ticks = 0 }
    end
    local ticks = (input.fail_ticks or 0) + 1
    local grace = session.ticks(math.max(1, input.fail_frames or 1), input.tick_ms)
    return { result = ticks >= grace and "fail" or nil, fail_ticks = ticks }
end

return session
