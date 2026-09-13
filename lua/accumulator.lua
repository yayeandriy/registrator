-- The Accumulator's shared algorithm library.
--
-- Registration and Validation (see `registration.lua`/`validation.lua`)
-- both only ever look at a single frame at a time — but a real detector
-- occasionally blinks: a genuinely-present object drops out of one frame
-- out of many, or a spurious one-off false positive shows up in just one.
-- Neither is a legitimate signal about the board itself, and neither of
-- those two scripts has any way to tell one apart from "the object
-- really isn't there this frame". This script is the fix: given a short
-- run of frames, it clusters detections across time (same class, boxes
-- that keep overlapping frame to frame — a lightweight IoU tracker, not
-- unlike `NMS.swift`'s own within-frame IoU test, just across frames
-- instead of within one), drops any cluster too thin across the run to
-- be more than noise, and folds every surviving cluster's own frame-by-
-- frame appearances into a single smoothed detection — see the
-- "Accumulator" TODO for the two call sites this is meant to sit at:
--   - *before* Registration: run directly on raw per-frame detections
--     (straight off a DetectionLog), producing one smoothed synthetic
--     frame to register instead of any single (possibly-blinking) one.
--   - *before* Validation: run on a run of already-`registered_detections`
--     (one call to `registration.lua` per historical frame — a moving
--     camera needs the anchor matched fresh per frame anyway, see that
--     file's header comment), so the *positions* being validated are
--     smoothed too, not just presence.
-- Deliberately coordinate-space agnostic (everything here is IoU/
-- weighted-average based, nothing measured in absolute units) — this
-- file doesn't care, and doesn't need to know, whether it's handed
-- normalized `[0,1]` camera-frame boxes or board-unit ones; the same
-- script and the same defaults work unchanged either way.
--
-- Input (a single Lua table, passed as this chunk's first argument):
--   {
--     frames = { { detections = { { label, confidence, x, y, width, height, rotation, corners }, ... } }, ... },
--     thresholds = { iou = 0.0..1.0, min_presence_ratio = 0.0..1.0 } | nil,
--   }
-- A `detections` entry mirrors both `registration.lua`'s own raw
-- `Detection` (`corners`, no `rotation`) and `RegisteredDetection`
-- (`rotation`, no `corners`) — both fields are simply optional here, so
-- either shape (or, in principle, both at once) works unmodified.
-- `thresholds` is optional; see `DEFAULT_THRESHOLDS` below for what's
-- used when omitted or partial.
--
-- Output:
--   {
--     detections = {
--       { label, confidence, x, y, width, height, rotation, corners, presence, presence_ratio },
--       ...
--     },
--     accepted = <n>,
--     dropped = <n>,
--     total_frames = <n>,
--   }
-- Every accepted detection's `x`/`y`/`width`/`height` (and, when present,
-- `rotation`/`corners`) is the confidence-weighted mean across every
-- frame its own cluster was matched in, not just its most recent
-- appearance — this is the "smoother pos and dims" half of the ask, not
-- only the blink filter. `rotation` is only populated when at least one
-- of the cluster's own appearances carried one (averaged circularly —
-- see `weighted_circular_mean_degrees` — over just those, ignoring any
-- appearance that didn't); same "when present" treatment for `corners`,
-- averaged corner-index-for-corner-index. `presence` is how many of
-- `total_frames` this cluster actually matched in; `presence_ratio =
-- presence / total_frames` is exactly what `min_presence_ratio` filters
-- on — `dropped` clusters (everything below that threshold) never make
-- it into `detections` at all, the actual point of this script.

local DEFAULT_THRESHOLDS = {
    -- Deliberately lenient: a detector jittering by a few pixels frame
    -- to frame, or a moving camera nudging every box a little, should
    -- still count as "the same object" — this only needs to be high
    -- enough to stop two genuinely different same-class objects sitting
    -- near each other from merging into one.
    iou = 0.2,
    -- A cluster matched in barely any frame is far more likely a stray
    -- false positive than a real object the detector mostly saw — but
    -- this is deliberately well under 0.5 so a real object that's
    -- genuinely occluded/out of frame more than half the time (while
    -- still showing up more often than any one-off noise blob would)
    -- survives as "present, just blinking" rather than being dropped.
    -- Admin-tunable (see `AccumulatorSettingsDto` in the demo) rather
    -- than only this hardcoded fallback — a long recording with a
    -- genuinely-real but rarely-detected object needs a lower ratio than
    -- a short one does to avoid being dropped as a false positive.
    min_presence_ratio = 0.25,
}

local function box_iou(a, b)
    local ax2, ay2 = a.x + a.width, a.y + a.height
    local bx2, by2 = b.x + b.width, b.y + b.height
    local ix1, iy1 = math.max(a.x, b.x), math.max(a.y, b.y)
    local ix2, iy2 = math.min(ax2, bx2), math.min(ay2, by2)
    local iw, ih = ix2 - ix1, iy2 - iy1
    if iw <= 0.0 or ih <= 0.0 then
        return 0.0
    end
    local inter = iw * ih
    local union = a.width * a.height + b.width * b.height - inter
    if union <= 0.0 then
        return 0.0
    end
    return inter / union
end

-- Same "mlua's serde bridge represents a Rust `None` as a userdata
-- sentinel, not plain Lua `nil`" reasoning as `registration.lua`'s own
-- `quad_corners` — duplicated rather than shared, for the same "no
-- `require` between standalone-loaded chunks" reason `validation.lua`
-- already documents for its own duplicated `flatten`.
local function real_corners(d)
    local corners = d.corners
    if type(corners) == "table" and #corners == 4 then
        return corners
    end
    return nil
end

local function real_rotation(d)
    if type(d.rotation) == "number" then
        return d.rotation
    end
    return nil
end

-- A confidence of exactly `0.0` would otherwise zero out its own sample
-- entirely in a weighted mean (as if it had never been given at all) —
-- clamped so every sample still counts for at least a little.
local MIN_WEIGHT = 1e-3
local function sample_weight(d)
    return math.max(d.confidence or 0.0, MIN_WEIGHT)
end

-- A brand-new cluster, seeded from its first appearance — every running
-- accumulator below (`box`, `rot_*`, `corners`) starts as exactly this
-- one sample and is folded into by `add_sample` on every later match.
local function new_cluster(d)
    local w = sample_weight(d)
    local c = {
        label = d.label,
        kind = d.kind,
        box = { x = d.x, y = d.y, width = d.width, height = d.height },
        box_weight = w,
        confidence_sum = d.confidence,
        n = 1,
        rot_cos = 0.0,
        rot_sin = 0.0,
        rot_weight = 0.0,
        corners = nil,
        corner_weight = 0.0,
    }
    local rotation = real_rotation(d)
    if rotation then
        local theta = math.rad(rotation)
        c.rot_cos = math.cos(theta) * w
        c.rot_sin = math.sin(theta) * w
        c.rot_weight = w
    end
    local corners = real_corners(d)
    if corners then
        c.corners = {}
        for i = 1, 4 do
            c.corners[i] = { x = corners[i].x, y = corners[i].y }
        end
        c.corner_weight = w
    end
    return c
end

-- Folds one more matched appearance into `c` — a running (confidence-)
-- weighted mean, updated sample-by-sample rather than summed-then-
-- divided-once, since `c.box` is also *read* between samples (to match
-- the next frame's detections against — see `match_frame`), not only at
-- the very end.
local function add_sample(c, d)
    local w = sample_weight(d)
    local total = c.box_weight + w
    c.box.x = c.box.x + (d.x - c.box.x) * (w / total)
    c.box.y = c.box.y + (d.y - c.box.y) * (w / total)
    c.box.width = c.box.width + (d.width - c.box.width) * (w / total)
    c.box.height = c.box.height + (d.height - c.box.height) * (w / total)
    c.box_weight = total
    c.confidence_sum = c.confidence_sum + d.confidence
    c.n = c.n + 1

    local rotation = real_rotation(d)
    if rotation then
        local theta = math.rad(rotation)
        c.rot_cos = c.rot_cos + math.cos(theta) * w
        c.rot_sin = c.rot_sin + math.sin(theta) * w
        c.rot_weight = c.rot_weight + w
    end

    local corners = real_corners(d)
    if corners then
        if not c.corners then
            c.corners = {}
            for i = 1, 4 do
                c.corners[i] = { x = corners[i].x, y = corners[i].y }
            end
            c.corner_weight = w
        else
            local new_corner_weight = c.corner_weight + w
            for i = 1, 4 do
                c.corners[i].x = c.corners[i].x + (corners[i].x - c.corners[i].x) * (w / new_corner_weight)
                c.corners[i].y = c.corners[i].y + (corners[i].y - c.corners[i].y) * (w / new_corner_weight)
            end
            c.corner_weight = new_corner_weight
        end
    end
end

-- Greedy best-IoU-first assignment of this frame's detections onto the
-- clusters accumulated so far — global (sorted once across every same-
-- label (detection, cluster) pair in this frame), not per-detection-in-
-- given-order, so processing order can't accidentally starve a closer
-- match by letting a worse one claim a cluster first. Each detection and
-- each cluster is claimed at most once per frame (mirrors
-- `validation.lua`'s own greedy `nearest_match`, just extended to a
-- global assignment instead of independent per-object lookups, since two
-- detections *in the same frame* competing for the same cluster is a
-- real possibility here in a way it isn't there).
local function match_frame(clusters, detections, iou_threshold)
    local candidates = {}
    for di, d in ipairs(detections) do
        for ci, c in ipairs(clusters) do
            if c.label == d.label and (c.kind or "yolo") == (d.kind or "yolo") then
                local iou = box_iou(c.box, d)
                if iou >= iou_threshold then
                    table.insert(candidates, { di = di, ci = ci, iou = iou })
                end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.iou > b.iou end)

    local assignments = {}
    local claimed_detections, claimed_clusters = {}, {}
    for _, cand in ipairs(candidates) do
        if not claimed_detections[cand.di] and not claimed_clusters[cand.ci] then
            claimed_detections[cand.di] = true
            claimed_clusters[cand.ci] = true
            assignments[cand.di] = cand.ci
        end
    end
    return assignments
end

-- `nil` (not `0.0`) whenever nothing ever contributed a rotation — "no
-- orientation to average in the first place", the same "can't judge,
-- don't guess" treatment `validation.lua` already gives a detection with
-- no quad.
local function weighted_circular_mean_degrees(cos_sum, sin_sum, weight)
    if weight <= 0.0 then
        return nil
    end
    return math.deg(math.atan(sin_sum, cos_sum))
end

local function finalize_cluster(c, total_frames)
    local presence = c.n
    local out = {
        label = c.label,
        kind = c.kind,
        confidence = c.confidence_sum / c.n,
        x = c.box.x,
        y = c.box.y,
        width = c.box.width,
        height = c.box.height,
        rotation = weighted_circular_mean_degrees(c.rot_cos, c.rot_sin, c.rot_weight),
        presence = presence,
        presence_ratio = total_frames > 0 and (presence / total_frames) or 0.0,
    }
    if c.corners then
        local corners = {}
        for i = 1, 4 do
            corners[i] = { x = c.corners[i].x, y = c.corners[i].y }
        end
        out.corners = corners
    end
    return out
end

local function accumulator(input)
    local thresholds = { iou = DEFAULT_THRESHOLDS.iou, min_presence_ratio = DEFAULT_THRESHOLDS.min_presence_ratio }
    local given = input.thresholds
    if type(given) == "table" then
        if type(given.iou) == "number" then
            thresholds.iou = given.iou
        end
        if type(given.min_presence_ratio) == "number" then
            thresholds.min_presence_ratio = given.min_presence_ratio
        end
    end

    local frames = input.frames or {}
    local clusters = {}
    for _, frame in ipairs(frames) do
        local detections = frame.detections or {}
        -- Computed once per frame, against whatever `clusters` looked
        -- like *before* this frame's own unmatched detections start new
        -- ones below — so two simultaneous detections in the same frame
        -- can never merge into a single cluster just because they end up
        -- near each other (that's NMS's job, within a frame; this script
        -- only ever merges *across* frames).
        local assignments = match_frame(clusters, detections, thresholds.iou)
        for di, d in ipairs(detections) do
            local ci = assignments[di]
            if ci then
                add_sample(clusters[ci], d)
            else
                table.insert(clusters, new_cluster(d))
            end
        end
    end

    local total_frames = #frames
    local out_detections = {}
    local accepted, dropped = 0, 0
    for _, c in ipairs(clusters) do
        local ratio = total_frames > 0 and (c.n / total_frames) or 0.0
        if ratio >= thresholds.min_presence_ratio then
            table.insert(out_detections, finalize_cluster(c, total_frames))
            accepted = accepted + 1
        else
            dropped = dropped + 1
        end
    end

    return {
        detections = out_detections,
        accepted = accepted,
        dropped = dropped,
        total_frames = total_frames,
    }
end

return accumulator
