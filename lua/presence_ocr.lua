-- Presence OCR: find the read (or assembled fragments) holding an
-- expected text, inside an optional region, honouring exclusive claims.
--
--   presence_ocr.find(ocr_detections, needle, region, claimed_ocr, ax, ay)
--     -> hit, claim_idxs (nil when not found)
--   presence_ocr.claim(claimed_ocr, hit, claim_idxs)
--   presence_ocr.owners(group, needle) -> how many objects list `needle`
--
-- Needs `expected`, `boxes` and `matcher`.

local presence_ocr = {}

local function digits_only(s)
    return (expected.normalize(s)):gsub("%D", "")
end

-- Claim helpers: `find_ocr` returns `hit, claim_idxs` (multi when digits assembled).
local function claim_ocr_hits(claimed_ocr, hit, claim_idxs)
    if not claimed_ocr or not hit then
        return
    end
    if claim_idxs then
        for _, idx in ipairs(claim_idxs) do
            claimed_ocr[idx] = true
        end
    else
        claimed_ocr[hit._idx] = true
    end
end

-- Digit-only needle: concatenate short OCR fragments in the gate (x then y).
-- Returns hit (first fragment), claim_idxs when the concat contains the needle.
local function find_ocr_digit_assembly(ocr_detections, needle, region, claimed_ocr)
    local n = expected.normalize(needle)
    local nd = digits_only(needle)
    if nd == "" or n ~= nd or #nd < 3 then
        return nil, nil
    end
    local parts = {}
    for _, d in ipairs(ocr_detections) do
        if not (claimed_ocr and claimed_ocr[d._idx]) and boxes.inside(region, d) then
            local h = expected.normalize(d.label)
            local hd = h:gsub("%D", "")
            -- Pure digit fragments only — codes like "P06" must not interleave.
            if hd ~= "" and h == hd then
                local cx, cy = boxes.center(d)
                table.insert(parts, { d = d, x = cx, y = cy, digits = hd })
            end
        end
    end
    if #parts == 0 then
        return nil, nil
    end
    table.sort(parts, function(a, b)
        if a.x ~= b.x then
            return a.x < b.x
        end
        return a.y < b.y
    end)
    local concat = ""
    for _, p in ipairs(parts) do
        concat = concat .. p.digits
    end
    local start_i, end_i = concat:find(nd, 1, true)
    if not start_i then
        return nil, nil
    end
    local pos = 1
    local claim_idxs = {}
    local hit = nil
    for _, p in ipairs(parts) do
        local plen = #p.digits
        local p_end = pos + plen - 1
        if p_end >= start_i and pos <= end_i then
            table.insert(claim_idxs, p.d._idx)
            if not hit then
                hit = p.d
            end
        end
        pos = pos + plen
    end
    if not hit then
        return nil, nil
    end
    -- Surface the expected year on the row, not a lone fragment label.
    hit = {
        _idx = hit._idx,
        label = needle,
        confidence = hit.confidence,
        x = hit.x,
        y = hit.y,
        width = hit.width,
        height = hit.height,
        kind = hit.kind,
    }
    return hit, claim_idxs
end

-- Letter (or mixed) fragments: `matcher.lua` concat of in-gate OCR
-- left-to-right — "A"+"B"+"C" → expected "Abc".
local function find_ocr_text_assembly(ocr_detections, needle, region, claimed_ocr)
    if expected.normalize(needle) == "" then
        return nil, nil
    end
    local parts = {}
    for _, d in ipairs(ocr_detections) do
        if not (claimed_ocr and claimed_ocr[d._idx]) and boxes.inside(region, d) then
            local cx, cy = boxes.center(d)
            table.insert(parts, { d = d, x = cx, y = cy })
        end
    end
    if #parts == 0 then
        return nil, nil
    end
    table.sort(parts, function(a, b)
        if a.x ~= b.x then
            return a.x < b.x
        end
        return a.y < b.y
    end)
    local labels = {}
    for i, p in ipairs(parts) do
        labels[i] = p.d.label
    end
    local r = matcher({ found = labels, expected = needle })
    if not (r and r.matched) then
        return nil, nil
    end
    local from = r.from or r.index or 1
    local to = r.to or r.index or from
    local claim_idxs = {}
    local hit = nil
    for i = from, to do
        local p = parts[i]
        if p then
            table.insert(claim_idxs, p.d._idx)
            if not hit then
                hit = p.d
            end
        end
    end
    if not hit then
        return nil, nil
    end
    hit = {
        _idx = hit._idx,
        label = needle,
        confidence = hit.confidence,
        x = hit.x,
        y = hit.y,
        width = hit.width,
        height = hit.height,
        kind = hit.kind,
    }
    return hit, claim_idxs
end

-- Prefer the OCR hit nearest the instance center; honor exclusive claims.
-- Returns `hit, claim_idxs` (claim_idxs nil → claim hit._idx only).
local function find_ocr(ocr_detections, needle, region, claimed_ocr, anchor_x, anchor_y)
    if expected.normalize(needle) == "" then
        return nil, nil
    end
    local ax = anchor_x
    local ay = anchor_y
    if ax == nil or ay == nil then
        ax, ay = boxes.region_center(region)
    end
    local best, best_d = nil, math.huge
    for _, d in ipairs(ocr_detections) do
        if
            not (claimed_ocr and claimed_ocr[d._idx])
            and expected.text_hits(d.label, needle)
            and boxes.inside(region, d)
        then
            local cx, cy = boxes.center(d)
            local dx, dy = cx - ax, cy - ay
            local dist = dx * dx + dy * dy
            if dist < best_d then
                best, best_d = d, dist
            end
        end
    end
    if best then
        return best, { best._idx }
    end
    local digits, digit_idxs = find_ocr_digit_assembly(ocr_detections, needle, region, claimed_ocr)
    if digits then
        return digits, digit_idxs
    end
    return find_ocr_text_assembly(ocr_detections, needle, region, claimed_ocr)
end

-- How many objects in `group` list this needle (shared vs unique text).
local function needle_owners(group, needle)
    local n = 0
    local key = expected.normalize(needle)
    if key == "" then
        return 0
    end
    for _, o in ipairs(group) do
        for _, v in ipairs(o.ocr_values or {}) do
            if expected.normalize(v) == key then
                n = n + 1
                break
            end
        end
    end
    return n
end

presence_ocr.find = find_ocr
presence_ocr.claim = claim_ocr_hits
presence_ocr.owners = needle_owners

return presence_ocr
