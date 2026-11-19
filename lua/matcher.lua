-- OCR text matcher (Presence / Spatial routing).
--
-- Not part of registration: Registrator must not know expected needles.
-- Presence and Spatial call this the same way they match YOLO classes —
-- class match is exact label; text match is "expected inside a found
-- string" after `normalisator.lua`.
--
-- Requires the `normalisator` function in scope (global, or the local
-- wrapped in by the host when this file is concatenated into
-- presence_validator / validation).
--
-- Input:
--   { hay = "<found>", needle = "<expected>" }
--   { found = { "<s>", ... }, expected = "<expected>" }
--     (`needle` is accepted as an alias for `expected`)
--   { detections = { Detection }, needles = { "<expected>", ... } }
-- Output:
--   { matched = false }
--   { matched = true, index = i, from = i, to = i }
--       — `found[i]` (or `hay`) contains the expected string
--   { matched = true, from = a, to = b }
--       — concatenation of `found` (given order) contains it; claim
--         `found[a]`..`found[b]` (split letters: "A"+"B"+"C" → "ABC")
--   { detections = { Detection } }
--       — OCR can join several strings into one read ("X04 P06" over two
--         stamps). Each read holding a needle anywhere but as its whole
--         text becomes one read per needle place: `label` the needle,
--         `read` the text read, the box sliced across by the needle's place
--         in the text, which runs left to right in the frame the reads were
--         taken in. Other detections pass unchanged.
--
-- Empty expected → not matched. Matching is exact substring on the
-- already-normalised forms (all caps, no spaces/punctuation), with the
-- letters OCR mistakes for digits read as those digits on both sides:
-- O/0, I/1, S/5, B/8. Codes that differ only by one of these pairs match
-- each other. A code also matches read upside down (turned 180°, "P06" as
-- "90d") when every one of its characters has a turned form.

-- One byte for one byte, so `from` / `to` spans stay put.
local LOOKALIKES = { O = "0", I = "1", S = "5", B = "8" }

-- How a normalised character reads turned 180°.
local TURNED = {
    ["0"] = "0", ["1"] = "1", ["5"] = "5", ["8"] = "8", ["6"] = "9", ["9"] = "6",
    H = "H", N = "N", X = "X", Z = "Z", M = "W", W = "M", P = "D", D = "P",
}

-- `key` as it reads upside down, or nil when one of its characters has no
-- turned form.
local function turned(key)
    local out = {}
    for i = #key, 1, -1 do
        local c = TURNED[key:sub(i, i)]
        if not c then
            return nil
        end
        out[#out + 1] = c
    end
    return table.concat(out)
end

-- Where `key`, or the code read upside down, sits in `hay` from `init`.
local function find(hay, key, upside, init)
    local at, upto = hay:find(key, init or 1, true)
    if at or not upside then
        return at, upto, false
    end
    at, upto = hay:find(upside, init or 1, true)
    return at, upto, at ~= nil
end

local function normalize_one(s)
    if type(normalisator) ~= "function" then
        error("normalisator.lua must be loaded before matcher")
    end
    local r = normalisator({ value = s })
    if type(r) == "table" and type(r.value) == "string" then
        return (r.value:gsub("[OISB]", LOOKALIKES))
    end
    return ""
end

local function is_ocr(d)
    local k = type(d.kind) == "string" and d.kind:lower() or ""
    return k == "ocr" or k:sub(1, 4) == "ocr:"
end

-- `{ at, upto, needle, upside }` for every place a needle takes in `hay`.
local function places(hay, needles)
    local out = {}
    for _, needle in ipairs(needles) do
        local before = #out
        for _, key in ipairs({ needle.key, needle.upside }) do
            local init = 1
            while true do
                local at, upto = hay:find(key, init, true)
                if not at then
                    break
                end
                out[#out + 1] = { at, upto, needle.text, key ~= needle.key }
                init = at + 1
            end
            if #out > before then
                break
            end
        end
    end
    return out
end

local function piece(d, place, len)
    local c = {}
    for k, v in pairs(d) do
        c[k] = v
    end
    local x, w = tonumber(d.x) or 0, tonumber(d.width) or 0
    c.label, c.read, c.corners = place[3], d.label, nil
    -- Upside down, the text runs from the box's right edge.
    local from = place[4] and len - place[2] or place[1] - 1
    c.x = x + w * from / len
    c.width = w * (place[2] - place[1] + 1) / len
    return c
end

local function split(dets, given)
    local needles, seen = {}, {}
    for _, text in ipairs(given or {}) do
        local key = normalize_one(text)
        if key ~= "" and not seen[key] then
            seen[key] = true
            local upside = turned(key)
            needles[#needles + 1] = { key = key, upside = upside ~= key and upside or nil, text = text }
        end
    end
    local out = {}
    for _, d in ipairs(dets) do
        local hay = is_ocr(d) and normalize_one(d.label) or ""
        local found = hay ~= "" and places(hay, needles) or {}
        local whole = #found == 1 and found[1][1] == 1 and found[1][2] == #hay
        if #found == 0 or whole then
            out[#out + 1] = d
        else
            for _, place in ipairs(found) do
                out[#out + 1] = piece(d, place, #hay)
            end
        end
    end
    return { detections = out }
end

local function matcher(input)
    input = input or {}
    if type(input.detections) == "table" then
        return split(input.detections, input.needles)
    end
    local needle = input.needle
    if needle == nil then
        needle = input.expected
    end
    local n = normalize_one(needle)
    if n == "" then
        return { matched = false }
    end

    local found = input.found
    if type(found) ~= "table" then
        if input.hay ~= nil then
            found = { input.hay }
        else
            found = {}
        end
    end

    local upside = turned(n)
    local norms = {}
    for i, s in ipairs(found) do
        norms[i] = normalize_one(s)
        if norms[i] ~= "" and find(norms[i], n, upside) then
            return { matched = true, index = i, from = i, to = i }
        end
    end

    local concat = table.concat(norms)
    local start_i, end_i = find(concat, n, upside)
    if not start_i then
        return { matched = false }
    end
    local pos = 1
    local from, to
    for i, token in ipairs(norms) do
        local token_end = pos + #token - 1
        if token_end >= start_i and pos <= end_i then
            if not from then
                from = i
            end
            to = i
        end
        pos = token_end + 1
    end
    return { matched = true, from = from, to = to }
end

return matcher
