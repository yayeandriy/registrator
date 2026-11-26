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

--
-- Needs `expected`, `homography`, `registration_anchors` and
-- `registration_scene` (composed by `bundles.json`).


-- Confidence heuristic: two anchors is enough to fully constrain a
-- similarity transform, so score saturates there rather than continuing
-- to reward extra anchors that don't add real information.
local function score_for(matched_anchors)
    if matched_anchors <= 0 then
        return 0.0
    end
    return math.min(1.0, matched_anchors / 2.0)
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
    local qc = registration_anchors.quad(d)
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
        local bx, by = homography.unapply(hinv, corner[1], corner[2])
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
    local corners = registration_anchors.quad(d)
    if corners then
        local tl_x, tl_y = homography.unapply(hinv, corners[1].x, corners[1].y)
        local tr_x, tr_y = homography.unapply(hinv, corners[2].x, corners[2].y)
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
        class_id = d.class_id,
        vision_model_id = d.vision_model_id,
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

-- Apply a host-settled transform (live zone turn) using this file's
-- register_detection — never a second copy of the inverse map.
local function register_with_transform(input)
    local t = input.transform
    if type(t) ~= "table" then
        return { registered_detections = {} }
    end
    local hinv = homography.inverse(t)
    if not hinv then
        return { registered_detections = {} }
    end
    local frames = input.detections
    if type(frames) ~= "table" then
        frames = {}
    elseif frames[1] and frames[1].label ~= nil and frames[1].detections == nil then
        frames = { { detections = frames } }
    end
    return { registered_detections = register_all_detections(hinv, frames) }
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
    input = input or {}
    if input.op == "register_with" then
        return register_with_transform(input)
    end
    local expected_flat = expected.flatten(input.expected)
    local aspect = tonumber(input.frame_aspect) or 1.0
    if aspect < 1e-6 then
        aspect = 1.0
    end
    local frames = isotropize_frames(input.detections or {}, aspect)
    local matches = registration_anchors.match(expected_flat, frames)

    if #matches == 0 then
        return {
            transform = nil,
            registered_detections = {},
            score = 0.0,
            matched_anchors = 0,
            error = "no anchor detections found",
        }
    end

    local pairs = registration_anchors.point_pairs(matches)
    local corner_pairs = registration_anchors.corner_pairs(matches)
    local transform, err = registration_scene.fit(matches, pairs, corner_pairs, expected_flat, frames)
    if transform then
        transform = registration_scene.refine(transform, matches, expected_flat, frames)
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

    local hinv = homography.inverse(transform)
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
