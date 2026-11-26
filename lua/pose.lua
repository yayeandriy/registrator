-- Board-space pose: thresholds, headings, position / rotation deltas and
-- the status they give. Shared by `validation`, `layout` and `ruller`.

local pose = {}

-- Deliberately generous — a single-anchor registration (the common case:
-- most boards define just the one anchor) only pins position and
-- axis-aligned scale near *that* anchor; error grows the further an
-- object sits from it. These are only the fallback for settings.
pose.DEFAULT_THRESHOLDS = {
    position = 8.0,
    rotation = 30.0,
}

-- `{ position, rotation }` from `given`, defaults for missing fields.
function pose.thresholds(given)
    local out = {
        position = pose.DEFAULT_THRESHOLDS.position,
        rotation = pose.DEFAULT_THRESHOLDS.rotation,
    }
    if type(given) == "table" then
        if type(given.position) == "number" then
            out.position = given.position
        end
        if type(given.rotation) == "number" then
            out.rotation = given.rotation
        end
    end
    return out
end

function pose.center(o)
    return o.x + o.width / 2.0, o.y + o.height / 2.0
end

function pose.distance(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- Minimal difference within the object's symmetry period:
--   "0"   — fully symmetrical: any orientation accepted (delta 0)
--   "60" / "90" / "120" / "180" — that period
--   "inf" — no symmetry: full circle (delta in [0, 180])
-- Missing / unknown → "inf".
function pose.angle_diff(a, b, symmetry)
    local sym = tostring(symmetry or "inf")
    if sym == "0" then
        return 0.0
    end
    local period
    if sym == "inf" then
        period = 360.0
    else
        period = tonumber(sym) or 360.0
        if period <= 0 then
            return 0.0
        end
    end
    local half = period / 2.0
    local diff = (a - b) % period
    if diff < 0 then
        diff = diff + period
    end
    if diff > half then
        diff = period - diff
    end
    return diff
end

-- Heading of the long side of a *local* box + `rotation`. A tall 2×8 at
-- 0° and a wide 8×2 stored at 90° are the same rectangle.
local function long_axis_heading(rot, w, h)
    rot = type(rot) == "number" and rot or 0.0
    w = type(w) == "number" and w or 0.0
    h = type(h) == "number" and h or 0.0
    if w >= h then
        return rot
    end
    return rot + 90.0
end

-- Fold into (-90, 90].
local function wrap_signed_90(deg)
    local a = deg % 180.0
    if a > 90.0 then
        a = a - 180.0
    elseif a <= -90.0 then
        a = a + 180.0
    end
    return a
end

-- Registered detections store the AABB of unregistered corners plus the
-- top-edge angle. A wide AABB with top-edge ~87° is a horizontal pin
-- whose detector ordered a tall local box at 90° — the visual long axis
-- is 0°, not 87°.
local function registered_long_axis_heading(rot, w, h)
    rot = type(rot) == "number" and rot or 0.0
    w = type(w) == "number" and w or 0.0
    h = type(h) == "number" and h or 0.0
    local aspect = w / math.max(h, 1e-6)
    -- Near-square AABB: the top edge *is* the heading.
    if aspect < 1.2 and aspect > (1.0 / 1.2) then
        return long_axis_heading(rot, w, h)
    end
    local tilt = wrap_signed_90(rot)
    if w >= h then
        if math.abs(tilt) <= 45.0 then
            return tilt
        end
        return 0.0
    end
    if math.abs(tilt) > 45.0 then
        return rot
    end
    return 90.0 + tilt
end

local function heading_of_expected(o)
    return long_axis_heading(o.rotation or 0.0, o.width, o.height)
end

local function heading_of_detected(d)
    if type(d.rotation) == "number" then
        return registered_long_axis_heading(d.rotation, d.width, d.height)
    end
    return nil
end

-- Pose in the frame the lock's *points* already defined (registration
-- T^{-1}). Positions are lock-center-relative; the AABB heading vs the
-- image axes is not T and must not rotate those vectors. The lock vs
-- itself is the origin (delta 0) because both sides use the same lock.
local function in_lock_frame(o, detected, lock_exp, lock_det)
    local ox, oy = pose.center(o)
    local dx, dy = pose.center(detected)
    local lx, ly = pose.center(lock_exp)
    local mx, my = pose.center(lock_det)
    local delta_position = pose.distance(ox - lx, oy - ly, dx - mx, dy - my)

    local h_lock_e = heading_of_expected(lock_exp)
    local h_lock_d = heading_of_detected(lock_det) or h_lock_e
    local delta_rotation = nil
    local h_d = heading_of_detected(detected)
    if h_d ~= nil then
        delta_rotation = pose.angle_diff(h_d - h_lock_d, heading_of_expected(o) - h_lock_e, o.symmetry)
    end
    return delta_position, delta_rotation
end

local function absolute(o, detected)
    local ex, ey = pose.center(o)
    local dx, dy = pose.center(detected)
    local delta_position = pose.distance(ex, ey, dx, dy)
    local delta_rotation = nil
    local h_d = heading_of_detected(detected)
    if h_d ~= nil then
        delta_rotation = pose.angle_diff(h_d, heading_of_expected(o), o.symmetry)
    end
    return delta_position, delta_rotation
end

-- `delta_position`, `delta_rotation` (nil when the detection has no
-- orientation) of `detected` against `o`, in `lock_frame` when given.
function pose.deltas(o, detected, lock_frame)
    if lock_frame then
        return in_lock_frame(o, detected, lock_frame.expected, lock_frame.detected)
    end
    return absolute(o, detected)
end

function pose.status(position_ok, rotation_ok)
    if position_ok and rotation_ok then
        return "matched"
    elseif not position_ok and not rotation_ok then
        return "mispositioned_misrotated"
    elseif not position_ok then
        return "mispositioned"
    end
    return "misrotated"
end

function pose.outcome(delta_position, delta_rotation, thresholds)
    local rotation_ok = delta_rotation == nil or delta_rotation <= thresholds.rotation
    return pose.status(delta_position <= thresholds.position, rotation_ok)
end

return pose
