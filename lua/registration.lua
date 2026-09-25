-- The Registrator's shared algorithm library.
--
-- This is the *single source of truth* for finding the transformation
-- between an ExpectedLayout's own coordinate space and a DetectionLog's
-- recorded camera-frame space — see the "Registration" TODO for why this
-- lives in Lua rather than native Rust/Swift: constructor-api (via `mlua`)
-- and, eventually, the iOS app are both meant to execute this exact file,
-- so every algorithm only ever needs to be written once and behaves
-- identically everywhere it runs.
--
-- Input (a single Lua table, passed as this chunk's first argument):
--   {
--     detections    = { { t = 0.0, detections = { { label, confidence, x, y, width, height, corners }, ... } }, ... },
--     expected      = { { yolo_classes, boundary = { x, y, width, height }, rotation, is_anchor, children = {...} }, ... },
--     frame_aspect  = height / width of the camera buffer (optional, default 1).
--                     Boxes stay `[0,1]` of the full frame; Y is scaled into
--                     width-normalized units before the fit so a portrait
--                     (or landscape) JPEG matches a square board layout.
--   }
-- `detections` is (usually) a single recorded frame — the caller is
-- expected to find the anchor(s) fresh per frame (a moving camera means a
-- fixed board anchor lands in a different spot on-screen every frame), but
-- more than one is accepted too (e.g. registering a whole log at once):
-- an anchor is matched from whichever of the given frames shows it first.
-- `expected` mirrors the API's `ReferenceObjectDto` tree — `rotation` is
-- this object's true orientation in degrees (see `expected_corners`), not
-- the axis-aligned-approximation `x`/`y`/`width`/`height` a non-rotation-
-- aware consumer would use to render it. A detection's `corners` is
-- optional — its own quad (e.g. fit to a segmentation mask), ordered
-- clockwise from top-left `{top_left, top_right, bottom_right,
-- bottom_left}`, as opposed to the plain axis-aligned `x/y/width/height`
-- box every producer reports today. Producers do not always honour that
-- start corner (or even the winding). A single rectangle is 180°-
-- ambiguous, so index pairing can invent a flip that maps the anchor
-- onto itself and throws every other part across the board. One matched
-- quad tries every cyclic shift and winding and keeps the similarity
-- that lands the rest of the scene.
--
-- Output:
--   {
--     transform = { tx, ty, a, b, c, d, px, py } | nil,
--     registered_detections = { { label, confidence, x, y, width, height, rotation }, ... },
--     score = 0.0..1.0,
--     matched_anchors = <n>,
--     error = <string> | nil,
--   }
-- A registered detection's `rotation` (degrees, same convention as
-- `ReferenceObject::local_corners` — `0°` is unrotated) is only present
-- when the *original* detection reported a real quad (`Detection.corners`)
-- — an axis-aligned box alone carries no orientation information to
-- register in the first place. `nil` otherwise.
-- `transform` maps a point in the expected layout's own space to the
-- detection frame's normalized [0,1] space (the direction the anchor match
-- naturally produces: known board-unit anchor size/position -> its
-- detected on-screen size/position) as a full projective (homography)
-- map — an 8-degree-of-freedom 3x3 matrix (`h33` fixed at `1`), not just
-- an affine one:
--   frame_x = (tx + a*x + b*y) / (px*x + py*y + 1)
--   frame_y = (ty + c*x + d*y) / (px*x + py*y + 1)
-- `px == py == 0.0` is exactly the affine case (the division is then
-- always by `1`) — how much of the full 8 degrees of freedom a given
-- result actually has determined depends on how many independent point
-- pairs the matched anchors contributed (see `collect_point_pairs`,
-- `collect_corner_pairs`, and `fit_transform` below):
--   - 1 anchor, no quad: 1 point pair -> only per-axis scale + translation
--     (`a`/`d` set, `b`/`c`/`px`/`py` left 0, no rotation — rotation
--     needs a second point).
--   - 2 anchors, no quads: 2 point pairs -> a similarity transform
--     (rotation + *uniform* scale + translation, no shear/perspective).
--   - 3+ point pairs (extra anchors' centers, and/or any matched
--     anchor's own 4 quad corners averaged in as its center): a fully
--     general *affine* least-squares fit — rotation, independent
--     per-axis scale, and shear, but still no perspective (`px`/`py`
--     stay 0).
--   - 1 matched quad (4 genuine corners): a similarity transform
--     (uniform scale + rotation + translation). Corners are *not*
--     paired by index — a rectangle cannot tell 0° from 180°, and a
--     wrong start corner invents a flip. A homography from one
--     rectangle overfits corner noise and explodes objects away from
--     the anchor — live boxes stay on the part while Spatial reports
--     hundreds of millimetres.
--   - 2+ matched quads (8+ genuine corners): a full projective
--     homography, capable of undoing real perspective/keystone.
-- `registered_detections` is the actual point of registration: every given
-- detection, run back through the *inverse* of that same transform, so its
-- position and size are expressed in the expected layout's own board-unit
-- space instead of the camera frame's. Since a general projective map
-- doesn't preserve rectangles (or even parallelograms), a detection's box
-- is re-derived as the axis-aligned bounding box of its own 4 corners run
-- through the inverse — expect a "squeezed"/"skewed" result rather than a
-- plain resize whenever the fit picked up real shear, off-axis scale, or
-- perspective; that's expected, not a bug.

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function non_empty(s)
    return type(s) == "string" and trim(s) ~= ""
end

local function yolo_classes_for(o)
    if type(o.yolo_classes) == "table" then
        local out = {}
        for _, v in ipairs(o.yolo_classes) do
            if non_empty(v) then
                table.insert(out, trim(v))
            end
        end
        if #out > 0 then
            return out
        end
    end
    if non_empty(o.yolo_class) then
        return { trim(o.yolo_class) }
    end
    return {}
end

local function label_in_classes(detection, classes)
    if type(class_match) == "table" and type(class_match.in_expected) == "function" then
        local d = detection
        if type(detection) ~= "table" then
            d = { label = detection }
        end
        return class_match.in_expected(d, classes)
    end
    local label = type(detection) == "table" and detection.label or detection
    for _, class in ipairs(classes) do
        local exp = type(class) == "table" and class.label or class
        if label == exp then
            return true
        end
    end
    return false
end

local function flatten(objects, origin_x, origin_y, out)
    origin_x = origin_x or 0.0
    origin_y = origin_y or 0.0
    for _, o in ipairs(objects) do
        local x = origin_x + o.boundary.x
        local y = origin_y + o.boundary.y
        table.insert(out, {
            id = o.id,
            yolo_classes = yolo_classes_for(o),
            yolo_class_refs = o.yolo_class_refs,
            vision_model_id = o.vision_model_id,
            x = x,
            y = y,
            width = o.boundary.width,
            height = o.boundary.height,
            -- Degrees, applied around this box's own center — see
            -- `expected_corners`. Ancestor rotations aren't composed in
            -- (only this object's own origin is translated by its
            -- parent's, above) — an accepted simplification matching
            -- `ReferenceObject`'s own doc comment, since nested children
            -- are rare/flat in practice today.
            rotation = o.rotation or 0.0,
            is_anchor = o.is_anchor,
        })
        if o.children then
            flatten(o.children, x, y, out)
        end
    end
    return out
end

-- The object's own center — invariant under rotation (rotation is always
-- applied around this same point), so this needs no `rotation` handling.
local function center(o)
    return o.x + o.width / 2.0, o.y + o.height / 2.0
end

-- A flattened expected object's own true oriented 4 corners — its
-- (unrotated) box rotated by its own `rotation` around its center —
-- ordered clockwise from top-left. A single matched quad does not pair
-- these by index (see `single_quad_similarity`). Reduces to the
-- object's plain axis-aligned corners whenever `rotation` is `0.0` (every
-- admin-drawn object today).
local function expected_corners(o)
    local cx, cy = center(o)
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
local function aspect_cost(detected, expected)
    -- Detection AABB vs the expected box's *visual* AABB (after rotation).
    -- A ~58° block's AABB is nearly square; the upright twin stays tall —
    -- enough to tell them apart when both share the same class.
    local da = (detected.width or 0.0) / math.max(detected.height or 1e-6, 1e-6)
    local ea = visual_aspect(expected)
    return math.abs(math.log(math.max(da, 1e-6)) - math.log(math.max(ea, 1e-6)))
end

local function pick_detection_for_expected(o, expected_flat, detections)
    -- When several detections share this object's class (two "block" parts),
    -- first-match-wins binds the wrong one and poisons the whole-frame
    -- transform. Prefer the candidate whose AABB aspect matches the expected
    -- local box; tie-break by board/frame Y-rank so the lower board anchor
    -- binds the lower-on-screen detection when the camera faces the board.
    local classes = (type(class_match) == "table" and class_match.expected_list(o))
        or (o.yolo_classes or {})
    local candidates = {}
    for _, d in ipairs(detections) do
        if label_in_classes(d, classes) then
            table.insert(candidates, d)
        end
    end
    if #candidates == 0 then
        return nil
    end

    local function shares_class(other)
        local other_classes = (type(class_match) == "table" and class_match.expected_list(other))
            or (other.yolo_classes or {})
        for _, c in ipairs(other_classes) do
            if label_in_classes(c, classes) then
                return true
            end
        end
        for _, c in ipairs(classes) do
            if label_in_classes(c, other_classes) then
                return true
            end
        end
        return false
    end

    local peers = {}
    for _, e in ipairs(expected_flat) do
        if shares_class(e) then
            local ex, ey = center(e)
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
        local ex, ey = center(m.expected)
        local dx, dy = center(m.detected)
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
    local ex, ey = center(m.expected)
    local dx, dy = center(m.detected)
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

-- Exactly two point pairs: a closed-form 2D similarity transform (uniform
-- scale + rotation + translation, no shear) fit by least squares — the
-- standard Umeyama/Kabsch construction specialized to 2D. Used only when
-- there aren't enough independent points (3+) for the fully general
-- affine fit below to be well-determined.
local function similarity_transform(pairs)
    local n = #pairs
    local bx_sum, by_sum, fx_sum, fy_sum = 0.0, 0.0, 0.0, 0.0
    for _, p in ipairs(pairs) do
        bx_sum = bx_sum + p.board_x
        by_sum = by_sum + p.board_y
        fx_sum = fx_sum + p.frame_x
        fy_sum = fy_sum + p.frame_y
    end
    local bx_mean, by_mean = bx_sum / n, by_sum / n
    local fx_mean, fy_mean = fx_sum / n, fy_sum / n

    local sxx, syy, sxy, syx, var_b = 0.0, 0.0, 0.0, 0.0, 0.0
    for _, p in ipairs(pairs) do
        local bx, by = p.board_x - bx_mean, p.board_y - by_mean
        local fx, fy = p.frame_x - fx_mean, p.frame_y - fy_mean
        sxx = sxx + bx * fx
        syy = syy + by * fy
        sxy = sxy + bx * fy
        syx = syx + by * fx
        var_b = var_b + bx * bx + by * by
    end

    if var_b < 1e-9 then
        return nil, "points are degenerate (coincident in the expected layout)"
    end

    local p = sxx + syy
    local q = sxy - syx
    local scale = math.sqrt(p * p + q * q) / var_b
    local rotation = math.atan(q, p)

    local cos_r, sin_r = math.cos(rotation), math.sin(rotation)
    local a, b, c, d = scale * cos_r, -scale * sin_r, scale * sin_r, scale * cos_r
    return {
        tx = fx_mean - (a * bx_mean + b * by_mean),
        ty = fy_mean - (c * bx_mean + d * by_mean),
        a = a,
        b = b,
        c = c,
        d = d,
        px = 0.0,
        py = 0.0,
    }, nil
end

-- Solves the NxN linear system `a * x = b` via Gaussian elimination with
-- partial pivoting, returning `nil` if `a` is (numerically) singular.
-- Mutates `a`/`b` in place — callers that still need the originals should
-- pass copies. General-purpose (used for both `fit_affine`'s 3x3 system
-- and `fit_homography`'s 8x8 one) rather than specialized per size, since
-- an explicit cofactor expansion (as `invert_3x3` below uses, where 3x3
-- is small enough for it to stay simple) gets unwieldy well before 8x8.
local function solve_linear_system(a, b, n)
    for col = 1, n do
        local pivot_row, pivot_val = col, math.abs(a[col][col])
        for row = col + 1, n do
            if math.abs(a[row][col]) > pivot_val then
                pivot_row, pivot_val = row, math.abs(a[row][col])
            end
        end
        if pivot_val < 1e-9 then
            return nil
        end
        if pivot_row ~= col then
            a[col], a[pivot_row] = a[pivot_row], a[col]
            b[col], b[pivot_row] = b[pivot_row], b[col]
        end
        for row = col + 1, n do
            local factor = a[row][col] / a[col][col]
            if factor ~= 0.0 then
                for k = col, n do
                    a[row][k] = a[row][k] - factor * a[col][k]
                end
                b[row] = b[row] - factor * b[col]
            end
        end
    end

    local x = {}
    for row = n, 1, -1 do
        local sum = b[row]
        for k = row + 1, n do
            sum = sum - a[row][k] * x[k]
        end
        x[row] = sum / a[row][row]
    end
    return x
end

-- Solves the symmetric 3x3 system `s * v = rhs` via its adjugate
-- (Cramer's rule), returning `nil` if `s` is singular. Also doubles as a
-- general 3x3 matrix inverse (see `invert_transform_matrix`) — an
-- adjugate-based inverse works the same way regardless of what the
-- matrix represents.
local function invert_3x3(s)
    local a, b, c = s[1][1], s[1][2], s[1][3]
    local d, e, f = s[2][1], s[2][2], s[2][3]
    local g, h, i = s[3][1], s[3][2], s[3][3]

    local co_a = e * i - f * h
    local co_b = -(d * i - f * g)
    local co_c = d * h - e * g
    local co_d = -(b * i - c * h)
    local co_e = a * i - c * g
    local co_f = -(a * h - b * g)
    local co_g = b * f - c * e
    local co_h = -(a * f - c * d)
    local co_i = a * e - b * d

    local det = a * co_a + b * co_b + c * co_c
    if math.abs(det) < 1e-9 then
        return nil
    end

    return {
        { co_a / det, co_d / det, co_g / det },
        { co_b / det, co_e / det, co_h / det },
        { co_c / det, co_f / det, co_i / det },
    }
end

local function apply_3x3(inv, v)
    return {
        inv[1][1] * v[1] + inv[1][2] * v[2] + inv[1][3] * v[3],
        inv[2][1] * v[1] + inv[2][2] * v[2] + inv[2][3] * v[3],
        inv[3][1] * v[1] + inv[3][2] * v[2] + inv[3][3] * v[3],
    }
end

-- 3+ point pairs: a fully general 2D affine least-squares fit (rotation,
-- independent per-axis scale, and shear, all at once — 6 degrees of
-- freedom). `frame_x = a*board_x + b*board_y + tx` and `frame_y =
-- c*board_x + d*board_y + ty` are two *independent* linear regressions
-- sharing the same predictors (`board_x`, `board_y`, `1`), so each is
-- solved as its own ordinary-least-squares normal-equations system —
-- both share the same 3x3 matrix `s`, so it's inverted only once.
local function fit_affine(pairs)
    local n = #pairs
    local sxx, sxy, sx, syy, sy = 0.0, 0.0, 0.0, 0.0, 0.0
    local rx1, rx2, rx3 = 0.0, 0.0, 0.0
    local ry1, ry2, ry3 = 0.0, 0.0, 0.0
    for _, p in ipairs(pairs) do
        local bx, by = p.board_x, p.board_y
        local fx, fy = p.frame_x, p.frame_y
        sxx = sxx + bx * bx
        sxy = sxy + bx * by
        sx = sx + bx
        syy = syy + by * by
        sy = sy + by
        rx1 = rx1 + bx * fx
        rx2 = rx2 + by * fx
        rx3 = rx3 + fx
        ry1 = ry1 + bx * fy
        ry2 = ry2 + by * fy
        ry3 = ry3 + fy
    end

    local s = {
        { sxx, sxy, sx },
        { sxy, syy, sy },
        { sx, sy, n },
    }
    local inv = invert_3x3(s)
    if not inv then
        return nil, "point correspondences are degenerate (collinear or too few)"
    end

    local x_coeffs = apply_3x3(inv, { rx1, rx2, rx3 })
    local y_coeffs = apply_3x3(inv, { ry1, ry2, ry3 })
    return {
        a = x_coeffs[1],
        b = x_coeffs[2],
        tx = x_coeffs[3],
        c = y_coeffs[1],
        d = y_coeffs[2],
        ty = y_coeffs[3],
        px = 0.0,
        py = 0.0,
    }, nil
end

-- 4+ *genuine* quad-corner pairs (see `collect_corner_pairs`): a full
-- projective homography fit — 8 degrees of freedom, capable of undoing
-- real perspective/keystone distortion that no affine map can represent.
-- Solved via the standard Direct Linear Transform, specialized to this
-- file's `(tx + a*x + b*y) / (px*x + py*y + 1)` parameterization (`h33`
-- fixed at `1`, rather than the usual homogeneous-scale-ambiguous
-- formulation solved via SVD) so it reduces to an ordinary linear
-- least-squares problem solvable with nothing fancier than
-- `solve_linear_system`: each point pair contributes 2 rows to an 8x8
-- normal-equations system over `[a, b, tx, c, d, ty, px, py]` — the same
-- construction as `fit_affine`'s 3x3 one, just bigger (and, unlike
-- `fit_affine`, correct even when the correspondences don't all lie on a
-- common affine map, since deriving `frame = tx + a*x + b*y` requires no
-- linearity assumption once the `px`/`py` denominator is included).
local function fit_homography(pairs)
    local n = 8
    local m = {}
    for i = 1, n do
        m[i] = {}
        for j = 1, n do
            m[i][j] = 0.0
        end
    end
    local rhs = { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }

    for _, p in ipairs(pairs) do
        local bx, by, fx, fy = p.board_x, p.board_y, p.frame_x, p.frame_y
        -- Cross-multiplying `fx = (a*bx + b*by + tx) / (px*bx + py*by + 1)`
        -- (and the analogous `fy` equation) turns each into a *linear*
        -- constraint on the 8 unknowns — that's the DLT trick.
        local row_x = { bx, by, 1.0, 0.0, 0.0, 0.0, -fx * bx, -fx * by }
        local row_y = { 0.0, 0.0, 0.0, bx, by, 1.0, -fy * bx, -fy * by }
        for i = 1, n do
            for j = 1, n do
                m[i][j] = m[i][j] + row_x[i] * row_x[j] + row_y[i] * row_y[j]
            end
            rhs[i] = rhs[i] + row_x[i] * fx + row_y[i] * fy
        end
    end

    local v = solve_linear_system(m, rhs, n)
    if not v then
        return nil, "quad corner correspondences are degenerate (collinear or too few)"
    end

    return {
        a = v[1], b = v[2], tx = v[3],
        c = v[4], d = v[5], ty = v[6],
        px = v[7], py = v[8],
    }, nil
end

-- Wrap degrees into (-180, 180].
local function wrap_deg(deg)
    return (deg + 180.0) % 360.0 - 180.0
end

local function transform_rotation_deg(t)
    return math.deg(math.atan(t.c, t.a))
end

local function apply_transform(t, x, y)
    local w = (t.px or 0.0) * x + (t.py or 0.0) * y + 1.0
    if math.abs(w) < 1e-12 then
        return nil, nil
    end
    return (t.a * x + t.b * y + t.tx) / w, (t.c * x + t.d * y + t.ty) / w
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

local function expected_classes(o)
    return (type(class_match) == "table" and class_match.expected_list(o))
        or (o.yolo_classes or {})
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
            if d ~= skip_detected and (not classed or label_in_classes(d, classes)) then
                local dx, dy = center(d)
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
                local dx, dy = center(d)
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
            local ex, ey = center(o)
            local fx, fy = apply_transform(t, ex, ey)
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

local function transform_scale(t)
    return math.sqrt((t.a or 0.0) * (t.a or 0.0) + (t.c or 0.0) * (t.c or 0.0))
end

local function similarity_residual(t, pairs)
    local rss = 0.0
    for _, p in ipairs(pairs) do
        local fx, fy = apply_transform(t, p.board_x, p.board_y)
        if fx == nil then
            return math.huge
        end
        local dx, dy = fx - p.frame_x, fy - p.frame_y
        rss = rss + dx * dx + dy * dy
    end
    return rss
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
    local det = quad_corners(match.detected)
    if not det then
        return nil
    end
    local exp = expected_corners(match.expected)
    local cands = {}
    for reverse = 0, 1 do
        for shift = 0, 3 do
            local pairs = pair_quads(exp, det, shift, reverse == 1)
            local t = similarity_transform(pairs)
            if t and transform_scale(t) > 1e-8 then
                table.insert(cands, {
                    t = t,
                    rss = similarity_residual(t, pairs),
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
                local rot = math.abs(wrap_deg(transform_rotation_deg(c.t)))
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
        local transform = fit_homography(corner_pairs)
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
        local transform = fit_affine(pairs)
        if transform then
            return transform, nil
        end
    end
    if #matches == 1 then
        return single_anchor_transform(matches[1]), nil
    end
    return similarity_transform(pairs)
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
                local ex, ey = center(o)
                local fx, fy = apply_transform(t, ex, ey)
                if fx ~= nil then
                    local best, best_dist, best_classed = nil, math.huge, false
                    for _, frame in ipairs(frames or {}) do
                        for _, d in ipairs(frame.detections or {}) do
                            if not detection_claimed(claimed, d) then
                                local dx, dy = center(d)
                                local dist = (dx - fx) * (dx - fx) + (dy - fy) * (dy - fy)
                                local classed = label_in_classes(d, classes)
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
        local ex, ey = center(m.expected)
        local dx, dy = center(m.detected)
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
    local t1 = similarity_transform(pairs)
    if not t1 or transform_scale(t1) < 1e-8 then
        return t0
    end
    local s0, s1 = transform_scale(t0), transform_scale(t1)
    if s1 < s0 * 0.4 or s1 > s0 * 2.5 then
        return t0
    end
    -- Lock-quad (or richer) T already carries orientation from the
    -- lock's points. A two-center refine can land the scene with
    -- nearly-zero rotation and leave every AABB heading in camera
    -- space — that heading is not the transform. Keep the point-fit
    -- orientation.
    if math.abs(wrap_deg(transform_rotation_deg(t1) - transform_rotation_deg(t0))) > 15.0 then
        return t0
    end
    local r0, r1 = 0.0, 0.0
    for _, m in ipairs(extra) do
        local ex, ey = center(m.expected)
        local dx, dy = center(m.detected)
        local f0x, f0y = apply_transform(t0, ex, ey)
        local f1x, f1y = apply_transform(t1, ex, ey)
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

-- Confidence heuristic: two anchors is enough to fully constrain a
-- similarity transform, so score saturates there rather than continuing
-- to reward extra anchors that don't add real information.
local function score_for(matched_anchors)
    if matched_anchors <= 0 then
        return 0.0
    end
    return math.min(1.0, matched_anchors / 2.0)
end

-- `t`'s full projective 3x3 matrix (`[[a,b,tx],[c,d,ty],[px,py,1]]`) —
-- reduces to a plain affine matrix (bottom row `[0, 0, 1]`, so its own
-- inverse's bottom row is too, and `invert_transform`'s homogeneous
-- divide below is always by exactly `1`) whenever `px`/`py` are both
-- `0.0`, i.e. every tier except the homography one.
local function transform_matrix(t)
    return {
        { t.a, t.b, t.tx },
        { t.c, t.d, t.ty },
        { t.px or 0.0, t.py or 0.0, 1.0 },
    }
end

-- Runs `hinv` (the inverse of `t`'s matrix — see `transform_matrix`)
-- against a frame-space point, landing back in the expected layout's own
-- board-unit space, dividing through by the homogeneous coordinate `w`
-- (always exactly `1` unless the fitted transform actually has a
-- perspective component).
local function unregister_point(hinv, fx, fy)
    local bx = hinv[1][1] * fx + hinv[1][2] * fy + hinv[1][3]
    local by = hinv[2][1] * fx + hinv[2][2] * fy + hinv[2][3]
    local w = hinv[3][1] * fx + hinv[3][2] * fy + hinv[3][3]
    return bx / w, by / w
end

-- The actual point of registration: re-expresses one detection's box in
-- board-unit space as the axis-aligned bounding box of its own 4 corners,
-- each run through `unregister_point` — see this file's header comment
-- for why the result can come out "squeezed"/"skewed" rather than a
-- plain resize whenever the fitted transform has shear, off-axis scale,
-- or perspective.
local function register_detection(hinv, d)
    -- Prefer the object-aligned quad. The AABB envelope of a rotated pin
    -- is a different box than the part — using it as the registered
    -- pose both shifts the center and wrecks the millimetre ruler.
    local box_corners
    local qc = quad_corners(d)
    if qc then
        box_corners = {
            { qc[1].x, qc[1].y },
            { qc[2].x, qc[2].y },
            { qc[3].x, qc[3].y },
            { qc[4].x, qc[4].y },
        }
    else
        box_corners = {
            { d.x, d.y },
            { d.x + d.width, d.y },
            { d.x, d.y + d.height },
            { d.x + d.width, d.y + d.height },
        }
    end
    local min_x, max_x, min_y, max_y = math.huge, -math.huge, math.huge, -math.huge
    for _, corner in ipairs(box_corners) do
        local bx, by = unregister_point(hinv, corner[1], corner[2])
        min_x = math.min(min_x, bx)
        max_x = math.max(max_x, bx)
        min_y = math.min(min_y, by)
        max_y = math.max(max_y, by)
    end

    -- Only derivable when the detection reports a real quad — an
    -- axis-aligned box alone carries no orientation information at all
    -- (same reasoning as `single_anchor_transform` needing a second point
    -- before it can say anything about rotation). Angle of the registered
    -- top edge (`corners[1] -> corners[2]`, i.e. top-left -> top-right —
    -- see this file's header comment for the ordering contract), which is
    -- `0°` for an unrotated box, matching `ReferenceObject::local_corners`'s
    -- own convention exactly (so an expected object's own `rotation` and a
    -- registered detection's are directly comparable — see `validation.lua`).
    local rotation = nil
    local corners = quad_corners(d)
    if corners then
        local tl_x, tl_y = unregister_point(hinv, corners[1].x, corners[1].y)
        local tr_x, tr_y = unregister_point(hinv, corners[2].x, corners[2].y)
        rotation = math.deg(math.atan(tr_y - tl_y, tr_x - tl_x))
    end

    return {
        label = d.label,
        confidence = d.confidence,
        x = min_x,
        y = min_y,
        width = max_x - min_x,
        height = max_y - min_y,
        rotation = rotation,
        -- Presence/Spatial extras treat OCR separately from YOLO. Keep
        -- the producer kind so a Presence-only paper is not a Spatial extra.
        kind = d.kind,
    }
end

local function register_all_detections(hinv, frames)
    local out = {}
    for _, frame in ipairs(frames) do
        for _, d in ipairs(frame.detections or {}) do
            table.insert(out, register_detection(hinv, d))
        end
    end
    return out
end

-- Width-normalize a full-frame `[0,1]` box: `y' = y * (H/W)`. Square
-- frames (`aspect ≈ 1`) are unchanged. Presence stays on the raw boxes;
-- only this script sees the isotropic copy.
local function isotropize_point(p, aspect)
    if type(p) ~= "table" then
        return p
    end
    if p.x ~= nil then
        return { x = p.x, y = (p.y or 0.0) * aspect }
    end
    return { p[1], (p[2] or 0.0) * aspect }
end

local function isotropize_detection(d, aspect)
    local out = {}
    for k, v in pairs(d) do
        out[k] = v
    end
    out.y = (d.y or 0.0) * aspect
    out.height = (d.height or 0.0) * aspect
    if type(d.corners) == "table" then
        local corners = {}
        for i, p in ipairs(d.corners) do
            corners[i] = isotropize_point(p, aspect)
        end
        out.corners = corners
    end
    return out
end

local function isotropize_frames(frames, aspect)
    if math.abs((aspect or 1.0) - 1.0) < 1e-3 then
        return frames
    end
    local out = {}
    for i, frame in ipairs(frames) do
        local dets = {}
        for j, d in ipairs(frame.detections or {}) do
            dets[j] = isotropize_detection(d, aspect)
        end
        out[i] = { t = frame.t, detections = dets }
    end
    return out
end

-- Fit is in isotropic frame units. Consumers (HUD projection) expect
-- camera `[0,1]`, so divide the Y row by `aspect` after the inverse
-- has already registered detections from the isotropic copy.
local function camera_transform(t, aspect)
    if math.abs((aspect or 1.0) - 1.0) < 1e-3 then
        return t
    end
    return {
        tx = t.tx,
        ty = t.ty / aspect,
        a = t.a,
        b = t.b,
        c = t.c / aspect,
        d = t.d / aspect,
        px = t.px,
        py = t.py,
    }
end

local function registration(input)
    local expected_flat = flatten(input.expected or {}, 0.0, 0.0, {})
    local aspect = tonumber(input.frame_aspect) or 1.0
    if aspect < 1e-6 then
        aspect = 1.0
    end
    local frames = isotropize_frames(input.detections or {}, aspect)
    local matches = match_anchors(expected_flat, frames)

    if #matches == 0 then
        return {
            transform = nil,
            registered_detections = {},
            score = 0.0,
            matched_anchors = 0,
            error = "no anchor detections found",
        }
    end

    local pairs = collect_point_pairs(matches)
    local corner_pairs = collect_corner_pairs(matches)
    local transform, err = fit_transform(matches, pairs, corner_pairs, expected_flat, frames)
    if transform then
        transform = refine_with_scene(transform, matches, expected_flat, frames)
    end

    if not transform then
        return {
            transform = nil,
            registered_detections = {},
            score = 0.0,
            matched_anchors = #matches,
            error = err,
        }
    end

    local hinv = invert_3x3(transform_matrix(transform))
    if not hinv then
        return {
            transform = camera_transform(transform, aspect),
            registered_detections = {},
            score = 0.0,
            matched_anchors = #matches,
            error = "fitted transform is not invertible",
        }
    end

    return {
        transform = camera_transform(transform, aspect),
        registered_detections = register_all_detections(hinv, frames),
        score = score_for(#matches),
        matched_anchors = #matches,
        error = nil,
    }
end

return registration
