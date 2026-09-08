-- Exercises `presence_latch.lua` across the JSON boundary.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
local presence_latch = dofile(script_dir .. "../lua/presence_latch.lua")
local t = dofile(script_dir .. "asserts.lua")

local function run(input)
    return json.decode(json.encode(presence_latch(input)))
end

local function obj(id, kind, status, label)
    return {
        id = id,
        yolo_classes = { "connector" },
        ocr_values = {},
        is_anchor = false,
        presence = true,
        status = status,
        matched_label = label,
        matched_confidence = status == "matched" and 0.9 or nil,
        match_kind = kind,
    }
end

local ID = "aaaaaaaa-0000-4000-8000-000000000001"

-- Fresh match → latched map gains the row; result stays matched.
local first = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "connector") },
        extra_detections = {},
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 0,
    },
    latched = {},
})
t.eq(first.result.matched, 1, "first: matched")
t.eq(first.result.objects[1].status, "matched", "first: status")
t.eq(#first.latched, 1, "first: latch size")
t.eq(first.latched[1].key, ID .. "|yolo", "first: latch key")

-- Later miss with prior latch → still matched (sticky).
local second = run({
    result = {
        objects = { obj(ID, "yolo", "missing", nil) },
        extra_detections = {},
        score = 0.0,
        matched = 0,
        total = 1,
        extra = 0,
    },
    latched = first.latched,
})
t.eq(second.result.matched, 1, "second: sticky matched count")
t.eq(second.result.objects[1].status, "matched", "second: sticky status")
t.eq(second.result.objects[1].matched_label, "connector", "second: keeps label")
t.close(second.result.score, 1.0, 1e-9, "second: score")

-- Independent match_kind rows (YOLO vs OCR) latch separately.
local OCR_ID = ID
local function ocr_obj(id, status, needle, label)
    local o = obj(id, "ocr", status, label)
    o.yolo_classes = nil
    o.ocr_values = { needle }
    return o
end
local dual_miss = run({
    result = {
        objects = {
            obj(OCR_ID, "yolo", "missing", nil),
            ocr_obj(OCR_ID, "missing", "SN-42", nil),
        },
        extra_detections = {},
        score = 0.0,
        matched = 0,
        total = 2,
        extra = 0,
    },
    latched = {
        {
            key = OCR_ID .. "|ocr|SN-42",
            object = ocr_obj(OCR_ID, "matched", "SN-42", "SN-42"),
        },
    },
})
t.eq(dual_miss.result.matched, 1, "dual: only OCR latched")
t.eq(dual_miss.result.objects[1].status, "missing", "dual: YOLO still missing")
t.eq(dual_miss.result.objects[2].status, "matched", "dual: OCR sticky")
t.eq(dual_miss.result.objects[2].matched_label, "SN-42", "dual: OCR label")

-- Multi-text AND: each OCR needle latches on its own key.
local multi = run({
    result = {
        objects = {
            ocr_obj(OCR_ID, "missing", "2020", nil),
            ocr_obj(OCR_ID, "missing", "P06", nil),
        },
        extra_detections = {},
        score = 0.0,
        matched = 0,
        total = 2,
        extra = 0,
    },
    latched = {
        {
            key = OCR_ID .. "|ocr|2020",
            object = ocr_obj(OCR_ID, "matched", "2020", "2020"),
        },
    },
})
t.eq(multi.result.matched, 1, "multi: only 2020 sticky")
t.eq(multi.result.objects[1].status, "matched", "multi: 2020 latched")
t.eq(multi.result.objects[2].status, "missing", "multi: P06 still missing")
t.eq(#multi.latched, 1, "multi: one latch entry")
t.eq(multi.latched[1].key, OCR_ID .. "|ocr|2020", "multi: latch key includes needle")

-- Empty prior + all missing → unchanged.
local empty = run({
    result = {
        objects = { obj(ID, "yolo", "missing", nil) },
        extra_detections = {},
        score = 0.0,
        matched = 0,
        total = 1,
        extra = 0,
    },
})
t.eq(empty.result.matched, 0, "empty: still missing")
t.eq(#empty.latched, 0, "empty: no latch entries")

-- YOLO extras stick across a 1–2 frame dropout (cannot spuriously PASS).
local function extra(label, x, y)
    return {
        label = label,
        confidence = 0.9,
        x = x,
        y = y,
        width = 0.1,
        height = 0.1,
        kind = "yolo",
    }
end

local with_extra = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "connector") },
        extra_detections = { extra("capacitor", 0.42, 0.55) },
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 1,
    },
    latched = {},
    latched_extras = {},
})
t.eq(with_extra.result.extra, 1, "extra: first tick lists YOLO extra")
t.eq(#with_extra.latched_extras, 1, "extra: latched_extras size")

local dropout = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "connector") },
        extra_detections = {},
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 0,
    },
    latched = with_extra.latched,
    latched_extras = with_extra.latched_extras,
})
t.eq(dropout.result.matched, 1, "extra: still matched")
t.eq(dropout.result.extra, 1, "extra: sticky across dropout")
t.eq(dropout.result.extra_detections[1].label, "capacitor", "extra: keeps label")

-- OCR extras are never sticky.
local ocr_noise = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "connector") },
        extra_detections = {
            {
                label = "SN-9",
                confidence = 0.8,
                x = 0.2,
                y = 0.2,
                width = 0.1,
                height = 0.05,
                kind = "ocr",
            },
        },
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 1,
    },
})
t.eq(ocr_noise.result.extra, 0, "ocr: not sticky / not listed as EXTRA")
t.eq(#ocr_noise.latched_extras, 0, "ocr: no latched extras")

-- Overlapping same-class boxes (IoU ≥ 0.2) collapse to one sticky row.
local near = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "connector") },
        extra_detections = {
            extra("capacitor", 0.42, 0.55),
            extra("capacitor", 0.44, 0.56),
        },
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 2,
    },
    latched = with_extra.latched,
    latched_extras = with_extra.latched_extras,
})
t.eq(near.result.extra, 1, "near: IoU-cluster same-class overlap to one row")

-- Non-overlapping same-class extras are distinct objects.
local two = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "connector") },
        extra_detections = {
            extra("connector", 0.10, 0.10),
            extra("connector", 0.40, 0.50),
        },
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 2,
    },
    latched = near.latched,
    latched_extras = near.latched_extras,
})
t.eq(two.result.extra, 3, "two: sticky capacitor + two far connectors")

local two_jitter = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "connector") },
        extra_detections = {
            -- IoU-overlap with the two prior connectors + one brand-new far box.
            extra("connector", 0.11, 0.11),
            extra("connector", 0.41, 0.51),
            extra("connector", 0.70, 0.20),
        },
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 3,
    },
    latched = two.latched,
    latched_extras = two.latched_extras,
})
t.eq(two_jitter.result.extra, 4, "two_jitter: prior three + new far connector")

-- Soft miss TTL (MAX_MISSES=3). Capacitor was absent from `two` and
-- `two_jitter`, so it enters empty ticks already at misses=2; connectors
-- were refreshed in two_jitter (misses=0).
local function empty_tick(prior)
    return run({
        result = {
            objects = { obj(ID, "yolo", "matched", "connector") },
            extra_detections = {},
            score = 1.0,
            matched = 1,
            total = 1,
            extra = 0,
        },
        latched = prior.latched,
        latched_extras = prior.latched_extras,
    })
end
local held = empty_tick(two_jitter)
t.eq(held.result.extra, 4, "ttl t1: all four held")
held = empty_tick(held)
t.eq(held.result.extra, 3, "ttl t2: capacitor expires")
held = empty_tick(held)
t.eq(held.result.extra, 3, "ttl t3: connectors still held")
held = empty_tick(held)
t.eq(held.result.extra, 0, "ttl t4: connectors expire")

-- Catalog-anchored extras (`kind == "extra"`, see `presence_validator.lua`'s
-- `anchor_extras` toggle) identify by position (IoU) alone, and keep the
-- last confirmed name even on a tick whose OCR briefly fails to resolve it.
local function catalog_extra(x, y, matched_label)
    return {
        label = matched_label or "test_1_lower",
        confidence = 0.9,
        x = x,
        y = y,
        width = 0.4,
        height = 0.45,
        kind = "extra",
        matched_label = matched_label,
    }
end

local named_first = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "connector") },
        extra_detections = { catalog_extra(0.6, 0.0, "Test D07") },
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 1,
    },
    latched = {},
    latched_extras = {},
})
t.eq(named_first.result.extra_detections[1].matched_label, "Test D07", "catalog: first tick keeps confirmed name")

-- Same physical box (overlapping position), but this tick's OCR came back
-- ambiguous — sticky merge must not drop the previously-confirmed name.
local named_ambiguous_tick = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "connector") },
        extra_detections = { catalog_extra(0.61, 0.01, nil) },
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 1,
    },
    latched = named_first.latched,
    latched_extras = named_first.latched_extras,
})
t.eq(named_ambiguous_tick.result.extra, 1, "catalog: still one sticky row")
t.eq(
    named_ambiguous_tick.result.extra_detections[1].matched_label,
    "Test D07",
    "catalog: name survives an ambiguous OCR tick"
)

-- Same-class leftover can rotate which box is extra (3 detections / 2
-- expected). Do not latch both leftovers.
local leftover_a = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "block") },
        extra_detections = { extra("block", 0.70, 0.20) },
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 1,
    },
    latched = {},
    latched_extras = {},
})
t.eq(leftover_a.result.extra, 1, "rotate: first leftover")
local leftover_b = run({
    result = {
        objects = { obj(ID, "yolo", "matched", "block") },
        extra_detections = { extra("block", 0.10, 0.10) },
        score = 1.0,
        matched = 1,
        total = 1,
        extra = 1,
    },
    latched = leftover_a.latched,
    latched_extras = leftover_a.latched_extras,
})
t.eq(leftover_b.result.extra, 1, "rotate: still one extra, not both leftovers")
t.close(leftover_b.result.extra_detections[1].x, 0.10, 1e-9, "rotate: current leftover wins")

if not t.summary("presence_latch") then
    os.exit(1)
end
