-- Presence latch — sticky "once matched, stay matched" for live inspect.
--
-- `presence_validator.lua` is deliberately stateless: each call scores only
-- the detections you send. Live camera hosts (iOS / web) need a session
-- rule on top: once a presence row (id + match_kind) has been matched, keep
-- it matched even if later frames miss it.
--
-- This script is that rule — pure function, same pattern as accumulator:
-- the host stores `latched` between ticks and feeds it back in.
--
-- Pipeline position:
--   detector → accumulator → presence_validator → presence_latch → results
--
-- Input:
--   {
--     result = { objects, extra_detections, score, matched, total, extra },
--     latched = {
--       { key = "<id>|<match_kind>", object = PresenceObjectValidation },
--       ...
--     } | nil,
--   }
-- `key` is optional on input entries — when omitted it is derived from
-- `object.id` + `object.match_kind` (same formula as the hosts used).
--
-- Output:
--   {
--     result = { ... same shape, with sticky matched rows + recomputed
--                matched/total/score },
--     latched = { { key, object }, ... }  -- only matched entries, sorted
--   }

local function latch_key(o)
    local kind = o.match_kind
    if kind == nil then
        kind = ""
    end
    return tostring(o.id) .. "|" .. tostring(kind)
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

    return {
        result = {
            objects = objects,
            extra_detections = result.extra_detections or {},
            score = total > 0 and (matched / total) or 0.0,
            matched = matched,
            total = total,
            extra = result.extra or 0,
        },
        latched = latched_out,
    }
end

return presence_latch
