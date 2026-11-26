-- Board → frame transforms `{ tx, ty, a, b, c, d, px, py }`:
--   frame_x = (tx + a*x + b*y) / (px*x + py*y + 1)
--   frame_y = (ty + c*x + d*y) / (px*x + py*y + 1)
-- Fits from point pairs `{ board_x, board_y, frame_x, frame_y }`, apply,
-- invert. `px == py == 0` is the affine case. Pure math.

local homography = {}

-- 2+ pairs: closed-form least-squares 2D similarity (uniform scale +
-- rotation + translation, no shear) — Umeyama/Kabsch in 2D.
function homography.similarity(pairs)
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

-- `a * x = b` by Gaussian elimination with partial pivoting; nil when
-- singular. Mutates `a` and `b`.
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

-- Adjugate inverse of a 3x3 matrix; nil when singular.
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

-- 3+ pairs: general affine least squares (rotation, per-axis scale,
-- shear). The x and y rows are independent regressions on the same
-- predictors, so they share one inverted 3x3 normal matrix.
function homography.affine(pairs)
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

    local inv = invert_3x3({
        { sxx, sxy, sx },
        { sxy, syy, sy },
        { sx, sy, n },
    })
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

-- 4+ genuine corner pairs: full projective fit (8 DoF) by the Direct
-- Linear Transform with `h33 = 1`, so it is an 8x8 linear least-squares
-- system over `[a, b, tx, c, d, ty, px, py]`.
function homography.projective(pairs)
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
        -- Cross-multiplying by the denominator makes each equation linear.
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
function homography.wrap_deg(deg)
    return (deg + 180.0) % 360.0 - 180.0
end

function homography.rotation_deg(t)
    return math.deg(math.atan(t.c, t.a))
end

function homography.scale(t)
    return math.sqrt((t.a or 0.0) * (t.a or 0.0) + (t.c or 0.0) * (t.c or 0.0))
end

-- Board point → frame point; nil, nil at the horizon.
function homography.apply(t, x, y)
    local w = (t.px or 0.0) * x + (t.py or 0.0) * y + 1.0
    if math.abs(w) < 1e-12 then
        return nil, nil
    end
    return (t.a * x + t.b * y + t.tx) / w, (t.c * x + t.d * y + t.ty) / w
end

-- Sum of squared frame residuals of `t` over `pairs`.
function homography.residual(t, pairs)
    local rss = 0.0
    for _, p in ipairs(pairs) do
        local fx, fy = homography.apply(t, p.board_x, p.board_y)
        if fx == nil then
            return math.huge
        end
        local dx, dy = fx - p.frame_x, fy - p.frame_y
        rss = rss + dx * dx + dy * dy
    end
    return rss
end

-- Inverse 3x3 of `[[a,b,tx],[c,d,ty],[px,py,1]]`; nil when singular.
function homography.inverse(t)
    return invert_3x3({
        { t.a, t.b, t.tx },
        { t.c, t.d, t.ty },
        { t.px or 0.0, t.py or 0.0, 1.0 },
    })
end

-- Frame point → board point through `hinv` (from `homography.inverse`).
function homography.unapply(hinv, fx, fy)
    local bx = hinv[1][1] * fx + hinv[1][2] * fy + hinv[1][3]
    local by = hinv[2][1] * fx + hinv[2][2] * fy + hinv[2][3]
    local w = hinv[3][1] * fx + hinv[3][2] * fy + hinv[3][3]
    return bx / w, by / w
end

return homography
