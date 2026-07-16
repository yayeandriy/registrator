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
--     detections = { { t = 0.0, detections = { { label, confidence, x, y, width, height, corners }, ... } }, ... },
--     expected   = { { yolo_class, boundary = { x, y, width, height }, rotation, is_anchor, children = {...} }, ... },
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
-- box every producer reports today. When present, it's paired index-for-
-- index against the matched anchor's own `expected_corners`, in the same
-- order.
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
--   - 4+ *genuine* quad-corner pairs (i.e. real corners reported on at
--     least one matched detection, not synthesized centers — see
--     `collect_corner_pairs` for why centers are excluded here
--     specifically): a full projective homography fit, capable of
--     undoing real perspective/keystone distortion (the camera looking
--     at the board's plane from an angle) that no affine map can
--     represent. This is the richest tier and is preferred whenever
--     enough genuine corners are available.
-- `registered_detections` is the actual point of registration: every given
-- detection, run back through the *inverse* of that same transform, so its
-- position and size are expressed in the expected layout's own board-unit
-- space instead of the camera frame's. Since a general projective map
-- doesn't preserve rectangles (or even parallelograms), a detection's box
-- is re-derived as the axis-aligned bounding box of its own 4 corners run
-- through the inverse — expect a "squeezed"/"skewed" result rather than a
-- plain resize whenever the fit picked up real shear, off-axis scale, or
-- perspective; that's expected, not a bug.

local function flatten(objects, origin_x, origin_y, out)
    origin_x = origin_x or 0.0
    origin_y = origin_y or 0.0
    for _, o in ipairs(objects) do
        local x = origin_x + o.boundary.x
        local y = origin_y + o.boundary.y
        table.insert(out, {
            id = o.id,
            yolo_class = o.yolo_class,
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
-- ordered to match `Detection.corners`'s clockwise-from-top-left
-- convention so the two can be paired up index-for-index. Reduces to the
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

-- Matches each anchor reference object to the detection sharing its class
-- — the "for now, each anchor has a unique class for this preset" rule
-- (see the "Registration" TODO) makes this a first-match-wins lookup, not
-- a real assignment problem.
local function match_anchors(expected_flat, frames)
    local matches = {}
    for _, o in ipairs(expected_flat) do
        if o.is_anchor then
            for _, frame in ipairs(frames) do
                local found = nil
                for _, d in ipairs(frame.detections or {}) do
                    if d.label == o.yolo_class then
                        found = d
                        break
                    end
                end
                if found then
                    table.insert(matches, { expected = o, detected = found })
                    break
                end
            end
        end
    end
    return matches
end

-- `mlua`'s serde bridge represents a Rust `None` as a special sentinel
-- (userdata), not plain Lua `nil` — `type(...) == "table"` is the
-- reliable way to tell "a real quad was given" from either that sentinel
-- or actual `nil`.
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

-- Picks the richest transform the available point pairs actually support
-- — see this file's header comment for the 4 tiers. Falls back to the
-- next tier down whenever a richer fit turns out degenerate (e.g.
-- collinear points), rather than failing outright.
local function fit_transform(matches, pairs, corner_pairs)
    if #corner_pairs >= 4 then
        local transform = fit_homography(corner_pairs)
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
    local box_corners = {
        { d.x, d.y },
        { d.x + d.width, d.y },
        { d.x, d.y + d.height },
        { d.x + d.width, d.y + d.height },
    }
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

local function registration(input)
    local expected_flat = flatten(input.expected or {}, 0.0, 0.0, {})
    local frames = input.detections or {}
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
    local transform, err = fit_transform(matches, pairs, corner_pairs)

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
            transform = transform,
            registered_detections = {},
            score = 0.0,
            matched_anchors = #matches,
            error = "fitted transform is not invertible",
        }
    end

    return {
        transform = transform,
        registered_detections = register_all_detections(hinv, frames),
        score = score_for(#matches),
        matched_anchors = #matches,
        error = nil,
    }
end

return registration
