-- Exercises `session.lua`, `session_zones.lua` and `ocr_window.lua`.

local script_dir = (arg[0]):match("(.*/)")
local session = dofile(script_dir .. "../lua/session.lua")
local zones = dofile(script_dir .. "../lua/session_zones.lua")
local ocr_window = dofile(script_dir .. "../lua/ocr_window.lua")
local t = dofile(script_dir .. "asserts.lua")

-- Phone frames become desktop ticks of the same length, never under two.
t.eq(session.ticks(12, 700), 2, "12 frames at 700 ms")
t.eq(session.ticks(12, 100), 10, "12 frames at 100 ms")
t.eq(session.ticks(8, 100), 7, "8 frames at 100 ms")
t.eq(session.ticks(0, 2000), 2, "floor of two")

-- A tip owns the next still only with a quorum of the window.
local window = session.ticks(8, 700)
local seen = {}
local adopt
for _ = 1, window do
    local out = session.next_view({ proposals = seen, proposal = "a", window_frames = 8, tick_ms = 700 })
    seen, adopt = out.proposals, out.adopt
end
t.eq(adopt, "a", "a held tip is adopted")
local split = session.next_view({ proposals = { "x", "a", "b", "a", "" }, proposal = "b", window_frames = 8, tick_ms = 140 })
t.eq(#split.proposals, 5, "window trimmed to its length")
t.is_nil(split.adopt, "a split window does not adopt")

local function verdict(result, complete, extra)
    return { result = result, complete = complete, extra = extra or 0, total = 1, view_id = "v1" }
end
local base = { window_frames = 8, fail_frames = 12, tick_ms = 700, ticks_on_view = 99, fail_ticks = 0 }
local function tick(over)
    local x = {}
    for k, v in pairs(base) do x[k] = v end
    for k, v in pairs(over) do x[k] = v end
    return session.completion(x)
end

local pass = tick({ verdict = verdict("pass", true) })
t.eq(pass.action, "finish", "a complete pass finishes a single still")
t.eq(pass.result, "pass", "pass")

local surplus = tick({ verdict = verdict("fail", false, 1), ticks_on_view = 0 })
t.eq(surplus.result, "fail", "surplus fails without the grace")

local miss1 = tick({ verdict = verdict("fail", false) })
t.eq(miss1.action, "none", "one miss waits")
t.eq(miss1.fail_ticks, 1, "miss counted")
local miss2 = tick({ verdict = verdict("fail", false), fail_ticks = miss1.fail_ticks })
t.eq(miss2.action, "finish", "a held miss fails")
t.eq(miss2.result, "fail", "fail")

local fresh = tick({ verdict = verdict("fail", false), multi_view = true, ticks_on_view = 1, fail_ticks = 9, views_left = 1 })
t.eq(fresh.action, "none", "a multi-view miss waits for the still to settle")

local next_still = tick({ verdict = verdict("pass", true), multi_view = true, views_left = 1 })
t.eq(next_still.action, "view", "a finished still hands over to the next")
local last = tick({ verdict = verdict("pass", true), multi_view = true, views_left = 0, done_results = { "fail" } })
t.eq(last.action, "finish", "the last still ends the run")
t.eq(last.result, "fail", "one failed still fails the session")
t.eq(last.view_result, "pass", "the still itself passed")

local zoned = session.completion({ zoned = true, zone_count = 2, zone_holds = { true } })
t.eq(zoned.action, "none", "zoned waits for every zone")
local zoned_done = session.completion({ zoned = true, zone_count = 2, zone_holds = { true, false } })
t.eq(zoned_done.result, "fail", "one failed zone fails")

-- Settle gate.
local v = { result = "pass", matched = 1, incorrect = 0, missing = 0, extra = 0, zone_chips = {} }
local read = { ocr_done = true }
local s1 = session.settle({ verdict = v, readings = read })
t.eq(s1.publish, false, "first sight is not enough")
local s2 = session.settle({ verdict = v, readings = read, candidate = s1.candidate, hits = s1.hits })
t.eq(s2.publish, true, "agreeing twice publishes")
local s3 = session.settle({ verdict = v, readings = read, published = s2.fingerprint })
t.eq(s3.publish, true, "a repeat of the published verdict shows at once")
t.eq(session.settle({ verdict = { result = "pending" }, readings = read }).publish, false, "pending never publishes")
local dirty = session.settle({ verdict = v, readings = read, published = s2.fingerprint, dirty = true })
t.eq(dirty.publish, false, "a changed scene must agree again")
t.eq(dirty.hits, 1, "a changed scene restarts the count")
local unscored = { ocr_done = true, want_spatial = true, spatial_scored = false }
t.eq(session.settle({ verdict = v, readings = unscored, published = s2.fingerprint }).publish, false,
    "a wanted engine that has not scored holds the verdict")
t.eq(session.settle({ verdict = v, readings = {}, published = s2.fingerprint }).publish, false,
    "an unfinished OCR tick holds the verdict")

-- Anchor search.
local a = { ticks = 0 }
for _ = 1, 2 do
    a = session.anchor_search({ ticks = a.ticks, fail_frames = 12, tick_ms = 700 })
end
t.eq(a.missing, true, "the search gives up after the grace")

-- router_completion
t.eq(session.router_completion({ ready = true, fail_ticks = 5 }).result, "pass", "every value in passes")
local partial = session.router_completion({ any_value = true, fail_ticks = 5, fail_frames = 12, tick_ms = 700 })
t.eq(partial.result, nil, "a partial read keeps reading")
t.eq(partial.fail_ticks, 0, "a partial read resets the grace")
local r = { fail_ticks = 0 }
r = session.router_completion({ fail_ticks = r.fail_ticks, fail_frames = 12, tick_ms = 700 })
t.eq(r.result, nil, "one empty tick is not a fail")
r = session.router_completion({ fail_ticks = r.fail_ticks, fail_frames = 12, tick_ms = 700 })
t.eq(r.result, "fail", "an empty scan fails after the grace")

-- Zones: a visible zone locks once; the other stays pending.
local live = { rows = { { object_id = "pin", label = "pin", status = "matched" } } }
local visible = { { object_id = "a", member_ids = { "pin" } } }
local h = zones.latch({ holds = {}, visible = visible, verdict = live }).holds
h = zones.latch({ holds = h, visible = visible, verdict = live }).holds
t.eq(#h, 1, "a zone locks once")
t.eq(h[1].pass, true, "zone passed")
local sheet = zones.compose({ zone_ids = { "a", "b" }, live = live, holds = h, visible = {} })
t.eq(sheet.verdict.result, "scoring", "open zones keep scoring")
t.eq(#sheet.zones, 2, "one chip per zone")
t.eq(sheet.zones[2].pending, true, "unseen zone pending")
h[#h + 1] = { object_id = "b", pass = true, rows = {} }
t.eq(zones.compose({ zone_ids = { "a", "b" }, live = {}, holds = h, visible = {} }).verdict.result, "pass", "all zones held pass")

-- OCR window.
t.eq(ocr_window.hits("ab-12", "AB12"), true, "punctuation ignored")
t.eq(ocr_window.hits("", "AB12"), false, "empty label")
local wait = ocr_window.progress({ wants_ocr = true, backend_ran = true, needles = { "AB12" }, read_labels = { "xx" }, box_ticks = 1, empty_ticks = 3 })
t.eq(wait.ready, true, "settle ticks reached after a box was seen")
local reading = ocr_window.progress({ wants_ocr = true, backend_ran = true, needles = { "AB12" }, read_labels = { "AB12" }, box_ticks = 0 })
t.eq(reading.reads_expected, true, "expected text on camera")
t.eq(reading.read_hits[1], 1, "which read hit")
local frames = ocr_window.drop_stale({
    frames = { { t = 0, detections = { { label = "AB12", kind = "ocr", width = 0.1, height = 0.1 }, { label = "pin", kind = "yolo", width = 0.1, height = 0.1 } } } },
    live_labels = {}, needles = { "AB12" }, ocr_ticked = true,
}).frames
t.eq(#frames[1].detections, 1, "a stale read leaves the window")
local function stale(live, ticked)
    return ocr_window.drop_stale({
        frames = { { t = 0, detections = { { label = "ABC", kind = "ocr", width = 0.1, height = 0.05 } } } },
        live_labels = live, needles = { "ABC" }, ocr_ticked = ticked,
    }).frames[1].detections
end
t.eq(#stale({ "ABC" }, true), 1, "text still on camera stays in the window")
t.eq(#stale({}, false), 1, "no real OCR tick, nothing dropped")

-- OCR progress: { has_match, reads_expected, backend_ran, box, empty } -> { ready, box, empty }
local function progress(match, reads, ran, box, empty)
    return ocr_window.progress({
        wants_ocr = true, backend_ran = ran, needles = { "ABC" },
        read_labels = reads and { "ABC" } or {},
        rows = match and { { label = "ABC", status = "matched", match_kind = "ocr" } } or {},
        box_ticks = box, empty_ticks = empty,
    })
end
local cases = {
    { "first box without a match stays unsettled", { false, true, true, 0, 1 }, { false, 1, 0 } },
    { "an OCR match settles at once", { true, true, true, 0, 0 }, { true, 0, 0 } },
    { "no box waits for the absent ticks", { false, false, true, 0, 2 }, { false, 0, 3 } },
    { "absent ticks reached", { false, false, true, 0, 3 }, { true, 0, 4 } },
    { "backend not flagged still counts", { false, false, false, 0, 0 }, { false, 0, 1 } },
    { "backend not flagged settles too", { false, false, false, 0, 3 }, { true, 0, 4 } },
    { "expected text holds before settling", { false, true, true, 2, 3 }, { false, 3, 0 } },
    { "expected text settles after the hold", { false, true, true, 3, 0 }, { true, 4, 0 } },
    { "a miss after boxes settles on empty ticks", { false, false, true, 2, 3 }, { true, 2, 4 } },
}
for _, c in ipairs(cases) do
    local out = progress(table.unpack(c[2]))
    t.eq(out.ready, c[3][1], c[1] .. " (ready)")
    t.eq(out.box_ticks, c[3][2], c[1] .. " (box)")
    t.eq(out.empty_ticks, c[3][3], c[1] .. " (empty)")
end
t.eq(ocr_window.progress({ wants_ocr = true, read_labels = {}, needles = { "ABC" } }).tick_finished, false,
    "no backend and no box: the OCR tick is not finished")
t.eq(ocr_window.progress({ wants_ocr = true, read_labels = { "ABC" }, needles = { "ABC" } }).tick_finished, true,
    "an expected box finishes the OCR tick")
local yolo_hit = ocr_window.progress({ wants_ocr = true, backend_ran = true, needles = { "26050D" },
    rows = { { label = "26050D", matched_label = "26050D", status = "matched", match_kind = "yolo" } } })
t.eq(yolo_hit.has_match, true, "a spatial match of the expected text counts as an OCR match")

if not t.summary("session") then
    os.exit(1)
end
