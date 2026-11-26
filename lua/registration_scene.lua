-- Scene-aware fitting for `registration.lua`: picks the richest
-- transform the anchor pairs support, disambiguates a single quad by how
-- well it lands the rest of the layout, then refines with scene pairs.
--
-- Needs `class_match`, `expected`, `pose`, `homography` and
-- `registration_anchors`.

local registration_scene = {}

local function expected_classes(o)
    return class_match.expected_list(o)
end

-- How well `t` maps the rest of the expected layout onto the scene.
-- Same-class detections win when labels line up; otherwise any other
-- detection still votes. A 180° rectangle pairing maps the anchor onto
-- itself and throws every other part to the empty side of the board.
-- `nil` when nothing besides the matched anchor is visible.
local function nearest_det_dist(fx, fy, frames, skip_detected, classes)
    local classed = type(classes) == "table" and #classes > 0
    local best = math.huge
    for _, frame in ipairs(frames or {}) do
        for _, d in ipairs(frame.detections or {}) do
            if d ~= skip_detected and (not classed or expected.in_classes(d, classes)) then
                local dx, dy = pose.center(d)
                local dist = (dx - fx) * (dx - fx) + (dy - fy) * (dy - fy)
                if dist < best then
                    best = dist
                end
            end
        end
    end
    if best < math.huge then
        return best
    end
    if not classed then
        return nil
    end
    for _, frame in ipairs(frames or {}) do
        for _, d in ipairs(frame.detections or {}) do
            if d ~= skip_detected then
                local dx, dy = pose.center(d)
                local dist = (dx - fx) * (dx - fx) + (dy - fy) * (dy - fy)
                if dist < best then
                    best = dist
                end
            end
        end
    end
    if best < math.huge then
        return best
    end
    return nil
end

local function scene_cost(t, expected_flat, frames, skip_expected, skip_detected)
    local cost, n = 0.0, 0
    for _, o in ipairs(expected_flat) do
        if o ~= skip_expected then
            local ex, ey = pose.center(o)
            local fx, fy = homography.apply(t, ex, ey)
            if fx ~= nil then
                local best = nearest_det_dist(fx, fy, frames, skip_detected, expected_classes(o))
                if best ~= nil then
                    cost = cost + best
                    n = n + 1
                end
            end
        end
    end
    if n == 0 then
        return nil
    end
    return cost / n
end

-- One rectangle cannot pin a unique similarity: index pairing of a
-- 180°-shifted (or reverse-wound) quad maps the anchor onto itself
-- and unregisters every other part to the far side of the board.
-- Try all 4 starts × 2 windings. Keep only well-scaled, low-residual
-- fits (a reflection pairing collapses scale). Among those, prefer
-- the candidate that lands the rest of the scene (class, else any
-- detection). Smallest |rotation| only when the scene is empty —
-- otherwise a ~177° stored box invents a flip while JPEG boxes stay
-- on the parts.
local function single_quad_similarity(match, expected_flat, frames)
    local det = registration_anchors.quad(match.detected)
    if not det then
        return nil
    end
    local exp = registration_anchors.corners(match.expected)
    local cands = {}
    for reverse = 0, 1 do
        for shift = 0, 3 do
            local pairs = registration_anchors.pair_quads(exp, det, shift, reverse == 1)
            local t = homography.similarity(pairs)
            if t and homography.scale(t) > 1e-8 then
                table.insert(cands, {
                    t = t,
                    rss = homography.residual(t, pairs),
                    scene = scene_cost(
                        t,
                        expected_flat,
                        frames,
                        match.expected,
                        match.detected
                    ),
                })
            end
        end
    end
    if #cands == 0 then
        return nil
    end
    local best_rss = math.huge
    for _, c in ipairs(cands) do
        if c.rss < best_rss then
            best_rss = c.rss
        end
    end
    local rss_cut = best_rss + 1e-10 + 0.05 * math.max(best_rss, 1e-12)
    local best, best_scene, best_rot = nil, math.huge, math.huge
    local have_scene = false
    for _, c in ipairs(cands) do
        if c.rss <= rss_cut then
            if c.scene ~= nil then
                if not have_scene or c.scene < best_scene - 1e-10 then
                    best, best_scene = c.t, c.scene
                end
                have_scene = true
            elseif not have_scene then
                local rot = math.abs(homography.wrap_deg(homography.rotation_deg(c.t)))
                if rot < best_rot then
                    best, best_rot = c.t, rot
                end
            end
        end
    end
    return best
end

-- Picks the richest transform the available point pairs actually support
-- — see this file's header comment for the 4 tiers. Falls back to the
-- next tier down whenever a richer fit turns out degenerate (e.g.
-- collinear points), rather than failing outright.
local function fit_transform(matches, pairs, corner_pairs, expected_flat, frames)
    -- Two or more quads (8 corners) can pin a homography. One rectangle
    -- cannot — the 8-DoF fit is ill-conditioned and throws nearby parts
    -- across the board while the JPEG overlay still looks aligned.
    if #corner_pairs >= 8 then
        local transform = homography.projective(corner_pairs)
        if transform then
            return transform, nil
        end
    end
    if #matches == 1 and #corner_pairs >= 4 then
        local transform = single_quad_similarity(matches[1], expected_flat, frames)
        if transform then
            return transform, nil
        end
    end
    if #pairs >= 3 then
        local transform = homography.affine(pairs)
        if transform then
            return transform, nil
        end
    end
    if #matches == 1 then
        return registration_anchors.single(matches[1]), nil
    end
    return homography.similarity(pairs)
end

local function match_is_expected(matches, o)
    for _, m in ipairs(matches) do
        if m.expected == o then
            return true
        end
    end
    return false
end

local function detection_claimed(matches, d)
    for _, m in ipairs(matches) do
        if m.detected == d then
            return true
        end
    end
    return false
end

-- After the anchor-only similarity, pair every other expected object
-- with the nearest unused detection (same class, else any) that the
-- coarse T already lands nearby. Those centers pull scale/rotation so
-- pins 30–60 board units off the single-rect map snap onto their slots.
-- Corner index-pairing is *not* reused here — a pin quad has the same
-- 180° ambiguity as the anchor, and a bad shift would undo the scene
-- vote `single_quad_similarity` already made.
local function collect_scene_matches(t, expected_flat, frames, anchor_matches)
    local extra = {}
    local claimed = {}
    for _, m in ipairs(anchor_matches) do
        table.insert(claimed, m)
    end
    for _, o in ipairs(expected_flat) do
        if not match_is_expected(anchor_matches, o) then
            local classes = expected_classes(o)
            if type(classes) == "table" and #classes > 0 then
                local ex, ey = pose.center(o)
                local fx, fy = homography.apply(t, ex, ey)
                if fx ~= nil then
                    local best, best_dist, best_classed = nil, math.huge, false
                    for _, frame in ipairs(frames or {}) do
                        for _, d in ipairs(frame.detections or {}) do
                            if not detection_claimed(claimed, d) then
                                local dx, dy = pose.center(d)
                                local dist = (dx - fx) * (dx - fx) + (dy - fy) * (dy - fy)
                                local classed = expected.in_classes(d, classes)
                                local take = false
                                if classed and (not best_classed or dist < best_dist) then
                                    take = true
                                elseif not best_classed and not classed and dist < best_dist then
                                    take = true
                                end
                                if take then
                                    best, best_dist, best_classed = d, dist, classed
                                end
                            end
                        end
                    end
                    -- ~0.18 of the frame — 36–59 board units at the
                    -- live 0.001 scale is 0.04–0.07; keep a gate wide
                    -- enough for the coarse residual, tight enough to
                    -- ignore a second-block ghost on the far side.
                    if best and best_dist < 0.18 * 0.18 then
                        local pair = { expected = o, detected = best }
                        table.insert(extra, pair)
                        table.insert(claimed, pair)
                    end
                end
            end
        end
    end
    return extra
end

local function refine_with_scene(t0, anchor_matches, expected_flat, frames)
    local extra = collect_scene_matches(t0, expected_flat, frames, anchor_matches)
    if #extra == 0 then
        return t0
    end
    local pairs = {}
    local function add_center(m)
        local ex, ey = pose.center(m.expected)
        local dx, dy = pose.center(m.detected)
        table.insert(pairs, {
            board_x = ex,
            board_y = ey,
            frame_x = dx,
            frame_y = dy,
        })
    end
    for _, m in ipairs(anchor_matches) do
        add_center(m)
    end
    for _, m in ipairs(extra) do
        add_center(m)
    end
    if #pairs < 2 then
        return t0
    end
    local t1 = homography.similarity(pairs)
    if not t1 or homography.scale(t1) < 1e-8 then
        return t0
    end
    local s0, s1 = homography.scale(t0), homography.scale(t1)
    if s1 < s0 * 0.4 or s1 > s0 * 2.5 then
        return t0
    end
    -- Lock-quad (or richer) T already carries orientation from the
    -- lock's points. A two-center refine can land the scene with
    -- nearly-zero rotation and leave every AABB heading in camera
    -- space — that heading is not the transform. Keep the point-fit
    -- orientation.
    if math.abs(homography.wrap_deg(homography.rotation_deg(t1) - homography.rotation_deg(t0))) > 15.0 then
        return t0
    end
    local r0, r1 = 0.0, 0.0
    for _, m in ipairs(extra) do
        local ex, ey = pose.center(m.expected)
        local dx, dy = pose.center(m.detected)
        local f0x, f0y = homography.apply(t0, ex, ey)
        local f1x, f1y = homography.apply(t1, ex, ey)
        if f0x ~= nil and f1x ~= nil then
            r0 = r0 + (f0x - dx) * (f0x - dx) + (f0y - dy) * (f0y - dy)
            r1 = r1 + (f1x - dx) * (f1x - dx) + (f1y - dy) * (f1y - dy)
        end
    end
    if r1 <= r0 * 1.05 then
        return t1
    end
    return t0
end

registration_scene.fit = fit_transform
registration_scene.refine = refine_with_scene

return registration_scene
