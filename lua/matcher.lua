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
-- Output:
--   { matched = false }
--   { matched = true, index = i, from = i, to = i }
--       — `found[i]` (or `hay`) contains the expected string
--   { matched = true, from = a, to = b }
--       — concatenation of `found` (given order) contains it; claim
--         `found[a]`..`found[b]` (split letters: "A"+"B"+"C" → "ABC")
--
-- Empty expected → not matched. Matching is exact substring on the
-- already-normalised forms (all caps, no spaces/punctuation).

local function normalize_one(s)
    if type(normalisator) ~= "function" then
        error("normalisator.lua must be loaded before matcher")
    end
    local r = normalisator({ value = s })
    if type(r) == "table" and type(r.value) == "string" then
        return r.value
    end
    return ""
end

local function matcher(input)
    input = input or {}
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

    local norms = {}
    for i, s in ipairs(found) do
        norms[i] = normalize_one(s)
        if norms[i] ~= "" and norms[i]:find(n, 1, true) then
            return { matched = true, index = i, from = i, to = i }
        end
    end

    local concat = table.concat(norms)
    local start_i, end_i = concat:find(n, 1, true)
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
