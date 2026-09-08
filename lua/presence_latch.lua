-- Presence latch — sticky session merge for live inspect.
--
-- `presence_validator.lua` is deliberately stateless: each call scores only
-- the detections you send. Live camera hosts (iOS / web) need session rules
-- on top:
--   1. once a presence row (id + match_kind [+ OCR needle]) has been matched,
--      keep it matched even if later frames miss it
--   2. once a YOLO extra has been seen, keep it listed even if later
--      accumulator batches drop it for a few ticks (so EXTRA cannot flicker
--      away and spuriously PASS). If this tick already lists extras of that
--      class, unmatched priors are dropped — assignment can rotate which of
--      N same-class boxes is leftover (3 detections / 2 expected must stay
--      1 extra, not latch both leftovers).
--   3. once a catalog-anchored extra (`kind == "extra"`, see
--      `presence_validator.lua`'s `anchor_extras` toggle) is named, keep
--      that name for the same physical box (IoU) even on a tick whose OCR
--      read fails and comes back ambiguous (`matched_label == nil`) — the
--      box's identity should not flicker just because one frame's OCR did
--      not resolve the printed code
--
-- This script is those rules — pure function, same pattern as accumulator:
-- the host stores `latched` / `latched_extras` between ticks and feeds them
-- back in.
--
-- Pipeline position:
--   detector → accumulator → presence_validator → presence_latch → results
--
-- Input:
--   {
--     result = { objects, extra_detections, score, matched, total, extra },
--     latched = {
--       { key = "<id>|<match_kind>[|<ocr_needle>]", object = PresenceObjectValidation },
--       ...
--     } | nil,
--     latched_extras = { PresenceDetection, ... } | nil,
--   }
-- `key` is optional on input entries — when omitted it is derived from
-- `object.id` + `object.match_kind` (+ first `ocr_values` entry for OCR rows,
-- so multi-text AND rows latch independently).
--
-- Output:
--   {
--     result = { ... sticky matched rows + sticky YOLO extras;
--                matched/total/score/extra recomputed },
--     latched = { { key, object }, ... },       -- only matched entries
--     latched_extras = { PresenceDetection, ... }  -- YOLO extras only
--   }

local function latch_key(o)
    local kind = o.match_kind
    if kind == nil then
        kind = ""
    end
    local key = tostring(o.id) .. "|" .. tostring(kind)
    -- OCR AND emits one row per needle; include the needle so latches do not
    -- collide when the same object id has multiple OCR expectations.
    if string.lower(tostring(kind)) == "ocr" then
        local needle = ""
        if type(o.ocr_values) == "table" and o.ocr_values[1] ~= nil then
            needle = tostring(o.ocr_values[1])
        end
        key = key .. "|" .. needle
    end
    return key
end

local function shallow_copy_object(o)
    -- Preserve the matched snapshot the host latched; do not share the
    -- table reference with `result.objects` (hosts may mutate).
    return {
        id = o.id,
        yolo_classes = o.yolo_classes,
        ocr_values = o.ocr_values,
        is_anchor = o.is_anchor,
        presence = o.presence,
        status = o.status,
        matched_label = o.matched_label,
        matched_confidence = o.matched_confidence,
        match_kind = o.match_kind,
    }
end

local function is_ocr_kind(kind)
    if kind == nil then
        return false
    end
    return string.lower(tostring(kind)) == "ocr"
        or string.find(string.lower(tostring(kind)), "ocr:", 1, true) == 1
end

-- Sticky extras: one row per *spatially distinct* unexpected object.
-- Match / cluster by IoU (same threshold idea as accumulator.lua) so this
-- works in camera-normalized [0,1] *and* board-unit space. Same class may
-- appear multiple times when boxes do not overlap. OCR noise is never sticky.
--
-- Soft miss TTL: an unmatched sticky row is kept for MAX_MISSES ticks, then
-- dropped. The host must round-trip `misses` on `latched_extras` (unknown
-- fields are fine for Lua; typed hosts that strip them degrade to sticky
-- forever on miss — IoU still prevents the per-tick append flood).
local IOU_THRESH = 0.2
local MAX_MISSES = 3

-- Catalog-anchored extras (`kind == "extra"`) identify by position (IoU)
-- alone — the label is a best-effort name that may legitimately flip
-- between an OCR-confirmed name and the ambiguous fallback tick to tick.
-- Plain YOLO extras still require the same class label (position alone
-- is not enough to tell two adjacent same-class boxes apart).
-- Group extras so assignment rotation of the leftover box does not
-- accumulate ghosts. Catalog-anchored rows share one group.
local function extra_group(d)
    local k = tostring(d.kind or "yolo")
    if k == "extra" then
        return "extra"
    end
    return "yolo:" .. tostring(d.label or "")
end

local function extra_kind_matches(a, b)
    local ak = tostring(a.kind or "yolo")
    local bk = tostring(b.kind or "yolo")
    if ak ~= bk then
        return false
    end
    if ak == "extra" then
        return true
    end
    return tostring(a.label or "") == tostring(b.label or "")
end

local function box_iou(a, b)
    local ax = tonumber(a.x) or 0
    local ay = tonumber(a.y) or 0
    local aw = tonumber(a.width) or 0
    local ah = tonumber(a.height) or 0
    local bx = tonumber(b.x) or 0
    local by = tonumber(b.y) or 0
    local bw = tonumber(b.width) or 0
    local bh = tonumber(b.height) or 0
    local ax2, ay2 = ax + aw, ay + ah
    local bx2, by2 = bx + bw, by + bh
    local ix1, iy1 = math.max(ax, bx), math.max(ay, by)
    local ix2, iy2 = math.min(ax2, bx2), math.min(ay2, by2)
    local iw, ih = ix2 - ix1, iy2 - iy1
    if iw <= 0.0 or ih <= 0.0 then
        return 0.0
    end
    local inter = iw * ih
    local union = aw * ah + bw * bh - inter
    if union <= 0.0 then
        return 0.0
    end
    return inter / union
end

local function shallow_copy_extra(d, misses)
    return {
        label = d.label,
        confidence = d.confidence,
        x = d.x,
        y = d.y,
        width = d.width,
        height = d.height,
        kind = d.kind,
        matched_label = d.matched_label,
        misses = misses or 0,
    }
end

local function public_extra(d)
    return {
        label = d.label,
        confidence = d.confidence,
        x = d.x,
        y = d.y,
        width = d.width,
        height = d.height,
        kind = d.kind,
        matched_label = d.matched_label,
    }
end

-- Collapse same-class detections that overlap in one batch.
local function cluster_frame(list)
    local candidates = {}
    for _, d in ipairs(list or {}) do
        if d and not is_ocr_kind(d.kind) then
            candidates[#candidates + 1] = d
        end
    end
    table.sort(candidates, function(a, b)
        return (tonumber(a.confidence) or 0) > (tonumber(b.confidence) or 0)
    end)
    local kept = {}
    for _, d in ipairs(candidates) do
        local too_close = false
        for _, k in ipairs(kept) do
            if extra_kind_matches(k, d) and box_iou(k, d) >= IOU_THRESH then
                too_close = true
                break
            end
        end
        if not too_close then
            kept[#kept + 1] = shallow_copy_extra(d, 0)
        end
    end
    return kept
end

local function merge_extras(prior, current)
    local prior_list = {}
    for _, d in ipairs(prior or {}) do
        if d and not is_ocr_kind(d.kind) then
            prior_list[#prior_list + 1] = shallow_copy_extra(d, tonumber(d.misses) or 0)
        end
    end
    local curr_list = cluster_frame(current)
    local curr_by_group = {}
    for _, c in ipairs(curr_list) do
        local g = extra_group(c)
        curr_by_group[g] = (curr_by_group[g] or 0) + 1
    end
    local used_curr = {}
    local out = {}

    for _, p in ipairs(prior_list) do
        local best_i, best_iou = nil, IOU_THRESH
        for i, c in ipairs(curr_list) do
            if not used_curr[i] and extra_kind_matches(p, c) then
                local iou = box_iou(p, c)
                if iou >= best_iou then
                    best_iou = iou
                    best_i = i
                end
            end
        end
        if best_i ~= nil then
            used_curr[best_i] = true
            local c = curr_list[best_i]
            -- Same physical box, but this tick's OCR did not resolve a
            -- name where the sticky prior one did — keep the known name.
            local keep_label = c.label
            local keep_matched = c.matched_label
            if
                (c.matched_label == nil or c.matched_label == "")
                and p.matched_label ~= nil and p.matched_label ~= ""
            then
                keep_label = p.matched_label
                keep_matched = p.matched_label
            end
            out[#out + 1] = shallow_copy_extra({
                label = keep_label,
                confidence = c.confidence,
                x = c.x,
                y = c.y,
                width = c.width,
                height = c.height,
                kind = c.kind,
                matched_label = keep_matched,
            }, 0)
        else
            -- Current tick already reports this class — prior leftover was
            -- likely claimed as a match. Holding it double-counts surplus.
            if (curr_by_group[extra_group(p)] or 0) == 0 then
                local misses = (tonumber(p.misses) or 0) + 1
                if misses <= MAX_MISSES then
                    out[#out + 1] = shallow_copy_extra(p, misses)
                end
            end
        end
    end

    for i, c in ipairs(curr_list) do
        if not used_curr[i] then
            out[#out + 1] = shallow_copy_extra(c, 0)
        end
    end
    return out
end

local function presence_latch(input)
    input = input or {}
    local result = input.result or {}
    local prior = input.latched or {}

    local map = {}
    for _, entry in ipairs(prior) do
        local obj = entry.object or entry
        local key = entry.key
        if key == nil or key == "" then
            key = latch_key(obj)
        end
        if obj and obj.status == "matched" then
            map[key] = shallow_copy_object(obj)
        end
    end

    local objects = {}
    for i, o in ipairs(result.objects or {}) do
        local key = latch_key(o)
        if o.status == "matched" then
            map[key] = shallow_copy_object(o)
            objects[i] = o
        elseif map[key] ~= nil then
            objects[i] = shallow_copy_object(map[key])
        else
            objects[i] = o
        end
    end

    local matched = 0
    for _, o in ipairs(objects) do
        if o.status == "matched" then
            matched = matched + 1
        end
    end
    local total = #objects

    local latched_out = {}
    for key, obj in pairs(map) do
        latched_out[#latched_out + 1] = {
            key = key,
            object = obj,
        }
    end
    table.sort(latched_out, function(a, b)
        return a.key < b.key
    end)

    local extras = merge_extras(input.latched_extras, result.extra_detections)
    local public_extras = {}
    for _, d in ipairs(extras) do
        public_extras[#public_extras + 1] = public_extra(d)
    end

    return {
        result = {
            objects = objects,
            extra_detections = public_extras,
            score = total > 0 and (matched / total) or 0.0,
            matched = matched,
            total = total,
            extra = #public_extras,
        },
        latched = latched_out,
        latched_extras = extras,
    }
end

return presence_latch
