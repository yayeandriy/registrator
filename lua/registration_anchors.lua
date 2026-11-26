-- Anchor matching for `registration.lua`: expected corners, which
-- detection each anchor binds, and the point pairs the fit uses (see
-- that file's header for the corner-order contract).
--
-- Needs `class_match`, `expected` and `pose`.

local registration_anchors = {}

-- A flattened expected object's own true oriented 4 corners — its
-- (unrotated) box rotated by its own `rotation` around its center —
-- ordered clockwise from top-left. A single matched quad does not pair
-- these by index (see `single_quad_similarity`). Reduces to the
-- object's plain axis-aligned corners whenever `rotation` is `0.0` (every
-- admin-drawn object today).
local function expected_corners(o)
    local cx, cy = pose.center(o)
    local hw, hh = o.width / 2.0, o.height / 2.0
    local theta = math.rad(o.rotation or 0.0)
    local cos_r, sin_r = math.cos(theta), math.sin(theta)
    local function rotate(dx, dy)
        return cx + cos_r * dx - sin_r * dy, cy + sin_r * dx + cos_r * dy
    end
    local x1, y1 = rotate(-hw, -hh)
    local x2, y2 = rotate(hw, -hh)
    local x3, y3 = rotate(hw, hh)
    local x4, y4 = rotate(-hw, hh)
    return { { x1, y1 }, { x2, y2 }, { x3, y3 }, { x4, y4 } }
end

-- Visual AABB aspect of an expected box after its own `rotation`. A tall
-- local box stored at ~90° (mask-fit canonicalize) must compare as wide,
-- matching the live detection AABB — not the unrotated local `w/h`.
local function visual_aspect(o)
    local corners = expected_corners(o)
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    for _, p in ipairs(corners) do
        min_x = math.min(min_x, p[1])
        min_y = math.min(min_y, p[2])
        max_x = math.max(max_x, p[1])
        max_y = math.max(max_y, p[2])
    end
    return (max_x - min_x) / math.max(max_y - min_y, 1e-6)
end

-- Matches each anchor reference object to the detection sharing its class
-- — the "for now, each anchor has a unique class for this preset" rule
-- (see the "Registration" TODO) makes this a first-match-wins lookup, not
-- a real assignment problem.
local function aspect_cost(detected, o)
    -- Detection AABB vs the expected box's *visual* AABB (after rotation).
    -- A ~58° block's AABB is nearly square; the upright twin stays tall —
    -- enough to tell them apart when both share the same class.
    local da = (detected.width or 0.0) / math.max(detected.height or 1e-6, 1e-6)
    local ea = visual_aspect(o)
    return math.abs(math.log(math.max(da, 1e-6)) - math.log(math.max(ea, 1e-6)))
end

local function pick_detection_for_expected(o, expected_flat, detections)
    -- When several detections share this object's class (two "block" parts),
    -- first-match-wins binds the wrong one and poisons the whole-frame
    -- transform. Prefer the candidate whose AABB aspect matches the expected
    -- local box; tie-break by board/frame Y-rank so the lower board anchor
    -- binds the lower-on-screen detection when the camera faces the board.
    local classes = class_match.expected_list(o)
    local candidates = {}
    for _, d in ipairs(detections) do
        if expected.in_classes(d, classes) then
            table.insert(candidates, d)
        end
    end
    if #candidates == 0 then
        return nil
    end

    local function shares_class(other)
        local other_classes = class_match.expected_list(other)
        for _, c in ipairs(other_classes) do
            if expected.in_classes(c, classes) then
                return true
            end
        end
        for _, c in ipairs(classes) do
            if expected.in_classes(c, other_classes) then
                return true
            end
        end
        return false
    end

    local peers = {}
    for _, e in ipairs(expected_flat) do
        if shares_class(e) then
            local ex, ey = pose.center(e)
            table.insert(peers, { ref = e, x = ex, y = ey })
        end
    end
    table.sort(peers, function(a, b)
        if math.abs(a.y - b.y) > 1.0 then
            return a.y < b.y
        end
        return a.x < b.x
    end)

    local rank = 1
    for i, p in ipairs(peers) do
        if p.ref == o then
            rank = i
            break
        end
    end

    table.sort(candidates, function(a, b)
        local ax = a.x + a.width / 2.0
        local ay = a.y + a.height / 2.0
        local bx = b.x + b.width / 2.0
        local by = b.y + b.height / 2.0
        if math.abs(ay - by) > 1e-4 then
            return ay < by
        end
        return ax < bx
    end)

    -- Visual aspect is the primary signal; Y-rank breaks near-ties.
    -- A sole expected of this class (the wood-block anchor) must not
    -- bind a pin that YOLO also labelled "block" — those share aspect
    -- and Y-rank then picks whichever sits higher on the JPEG. Prefer
    -- the largest AABB when there is only one expected of the class.
    local best, best_score = nil, math.huge
    for i, d in ipairs(candidates) do
        local cost = aspect_cost(d, o)
        local rank_pen = math.abs(i - rank) * 0.15
        local area = (d.width or 0.0) * (d.height or 0.0)
        local score
        if #peers <= 1 then
            score = cost - 4.0 * area
        else
            score = cost + rank_pen
        end
        if score < best_score then
            best_score = score
            best = d
        end
    end

    -- Reject a lone wrong-shape detection rather than fitting a bad transform
    -- (e.g. only the diagonal block visible while the tall anchor is expected).
    if best and aspect_cost(best, o) > 0.7 and #peers > 1 then
        return nil
    end
    return best
end

-- Matches each anchor reference object to a detection of its class.
-- Same-class duplicates are disambiguated by aspect + Y-rank (see
-- `pick_detection_for_expected`) — not first-match-wins.
local function match_anchors(expected_flat, frames)
    local matches = {}
    for _, o in ipairs(expected_flat) do
        if o.is_anchor then
            for _, frame in ipairs(frames) do
                local found = pick_detection_for_expected(
                    o,
                    expected_flat,
                    frame.detections or {}
                )
                if found then
                    table.insert(matches, { expected = o, detected = found })
                    break
                end
            end
        end
    end
    return matches
end

local function quad_corners(detected)
    local corners = detected.corners
    if type(corners) == "table" and #corners == 4 then
        return corners
    end
    return nil
end

-- Every point correspondence the matched anchors give us: each match
-- always contributes its own center pair, plus its 4 quad-corner pairs
-- whenever the detection reports a real `corners` quad — see this file's
-- header comment for the ordering contract between the two sides' quads.
-- Used for the affine/similarity/single-anchor tiers, where mixing
-- centers and corners together is harmless (an affine map preserves
-- centroids, so a center pair is just as valid a constraint as a corner
-- one) — *not* for the homography tier; see `collect_corner_pairs`.
local function collect_point_pairs(matches)
    local pairs = {}
    for _, m in ipairs(matches) do
        local ex, ey = pose.center(m.expected)
        local dx, dy = pose.center(m.detected)
        table.insert(pairs, { board_x = ex, board_y = ey, frame_x = dx, frame_y = dy })

        local corners = quad_corners(m.detected)
        if corners then
            local exp_corners = expected_corners(m.expected)
            for i = 1, 4 do
                table.insert(pairs, {
                    board_x = exp_corners[i][1],
                    board_y = exp_corners[i][2],
                    frame_x = corners[i].x,
                    frame_y = corners[i].y,
                })
            end
        end
    end
    return pairs
end

-- Only genuine corner correspondences — no synthesized center pairs.
-- This matters specifically for the homography tier: under a true
-- projective map, the image of a rectangle's centroid is *not* the
-- centroid of the mapped quad (unlike under an affine map, where
-- centroids are always preserved) — mixing in a "center" pair here would
-- feed the homography fit a point that doesn't actually satisfy the same
-- transform as the 4 real corners do, corrupting it whenever there's
-- genuine perspective distortion to recover in the first place.
local function collect_corner_pairs(matches)
    local pairs = {}
    for _, m in ipairs(matches) do
        local corners = quad_corners(m.detected)
        if corners then
            local exp_corners = expected_corners(m.expected)
            for i = 1, 4 do
                table.insert(pairs, {
                    board_x = exp_corners[i][1],
                    board_y = exp_corners[i][2],
                    frame_x = corners[i].x,
                    frame_y = corners[i].y,
                })
            end
        end
    end
    return pairs
end

-- One matched anchor pins position, but a single point pair can't fix
-- rotation — only scale (from the matched boxes' own width/height ratio)
-- and translation (from aligning both boxes' centers). Rotation is left
-- at 0 until a second point (a second anchor, or this anchor's own quad
-- corners) is available.
local function single_anchor_transform(m)
    local sx = m.detected.width / m.expected.width
    local sy = m.detected.height / m.expected.height
    local ex, ey = pose.center(m.expected)
    local dx, dy = pose.center(m.detected)
    return {
        tx = dx - sx * ex,
        ty = dy - sy * ey,
        a = sx,
        b = 0.0,
        c = 0.0,
        d = sy,
        px = 0.0,
        py = 0.0,
    }
end


-- Detected-quad index for expected corner `i` (1-based) after a cyclic
-- shift and optional reverse winding.
local function corner_index(i, shift, reverse)
    local k = (i - 1 + shift) % 4
    if reverse then
        k = (4 - k) % 4
    end
    return k + 1
end

local function pair_quads(exp_corners, det_corners, shift, reverse)
    local pairs = {}
    for i = 1, 4 do
        local j = corner_index(i, shift, reverse)
        local p = det_corners[j]
        table.insert(pairs, {
            board_x = exp_corners[i][1],
            board_y = exp_corners[i][2],
            frame_x = p.x,
            frame_y = p.y,
        })
    end
    return pairs
end

registration_anchors.corners = expected_corners
registration_anchors.quad = quad_corners
registration_anchors.match = match_anchors
registration_anchors.point_pairs = collect_point_pairs
registration_anchors.corner_pairs = collect_corner_pairs
registration_anchors.single = single_anchor_transform
registration_anchors.pair_quads = pair_quads

return registration_anchors
