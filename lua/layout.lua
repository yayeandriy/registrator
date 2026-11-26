-- Layout: global assignment of detections to expected objects.
--
-- `validation.lua` claims same-class boxes independently, in flatten
-- order, with no look-ahead. Neighbors steal: a hole processed first
-- takes the pin sitting in the next slot, and the leftover far box
-- paints the correct pin yellow.
--
-- This script looks at the whole layout. Same I/O shape as
-- `validation.lua` / `ruller.lua` — a standalone callable, no `require`.
-- When `enabled` is false it returns `validation` unchanged so the host
-- can leave the step in the chain and flip it off.
--
-- Pose uses the same lock-point frame as `validation.lua`. Assignment
-- is global; scoring must not fall back to AABB heading vs the image
-- axes — that number is not the transform registration built from the
-- lock's points. The lock vs itself is the origin of that frame.
--
-- Input:
--   {
--     expected = { ... },
--     registered_detections = { ... },
--     validation = { ... },              -- previous step (passthrough when off)
--     thresholds = { position, rotation } | nil,
--     enabled = true | false | nil,      -- nil → on
--   }
--
-- Output: the same shape as `validation.lua`. Claimed objects also carry
-- `matched_x` / `matched_y` / `matched_width` / `matched_height` (board
-- space) so overlays bind the assigned box, not the expected slot.

--
-- Identity is `class_match` (class_id, then model + label, then label)
-- — the same rule `validation.lua` claims with.
--
-- Needs `expected`, `pose`, `spatial` and `hungarian`.

local function assign_layout(expected_flat, detections, thresholds)
    local n = #expected_flat
    local m = #detections
    local cost = {}
    for i = 1, n do
        cost[i] = {}
        local o = expected_flat[i]
        local ex, ey = pose.center(o)
        for j = 1, m do
            local d = detections[j]
            if expected.matches_object(d, o) then
                local dx, dy = pose.center(d)
                cost[i][j] = pose.distance(ex, ey, dx, dy)
            else
                cost[i][j] = hungarian.INF
            end
        end
    end
    local assignment = hungarian.assign(cost, n, m)
    local claimed = {}
    local pairs = {}
    local paired = {}
    for i, o in ipairs(expected_flat) do
        local j = assignment[i]
        if j and cost[i][j] < hungarian.INF / 2 then
            local detected = detections[j]
            claimed[detected._idx] = true
            pairs[#pairs + 1] = { object = o, detected = detected }
            paired[i] = detected
        end
    end

    local lock_for = spatial.lock_finder(pairs)
    local objects = {}
    for i, o in ipairs(expected_flat) do
        if paired[i] then
            objects[i] = spatial.scored(o, paired[i], thresholds, lock_for(o))
        end
    end
    for i, o in ipairs(expected_flat) do
        if not paired[i] then
            objects[i] = spatial.unpaired(o, detections, thresholds, claimed, expected_flat)
        end
    end
    return spatial.result(objects, detections, claimed)
end

local function layout(input)
    if input.enabled == false then
        return input.validation or {
            objects = {},
            extra_detections = {},
            score = 0.0,
            matched = 0,
            total = 0,
            extra = 0,
        }
    end
    return assign_layout(
        expected.flatten(input.expected),
        spatial.tag(input.registered_detections),
        pose.thresholds(input.thresholds)
    )
end

return layout
