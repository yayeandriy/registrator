-- OCR text normalisator.
--
-- Frame-only: rewrites detected OCR *values*, never expected needles
-- (Registrator does not know the profile). Presence / Spatial match
-- those needles later via `matcher.lua`.
--
-- Apply when the host's profile has any component text values — then
-- every OCR detection in the frame goes through this script (YOLO
-- class labels are left alone).
--
-- **ALWAYS ENGLISH.** Output is only ASCII `A–Z` and `0–9`. Every other
-- script (Cyrillic, Greek, fullwidth, …) is folded to the English letter
-- it looks like, or dropped. Needles and hits are compared in English.
--
-- Rules (in order):
--   1. Coerce to a string (anything else → "").
--   2. Map common Unicode spaces (NBSP, thin, figure, …) to ASCII space.
--   3. Drop every remaining whitespace character (ghost spaces: "A B C"
--      and "P 06" become "ABC" / "P06").
--   4. Drop punctuation / symbols (`P-06` → `P06`, `A.B.C` → `ABC`).
--   5. Fold lookalikes onto English (`АвС` → `ABC`).
--   6. Keep English letters and digits only; uppercase.
-- Idempotent: `ABC` stays `ABC`.
--
-- Input (first matching shape wins):
--   { value = "a b c" }
--   { values = { "a b c", "p-06" } }
--   { detections = { { label, kind, ... }, ... } }
--   { frames = { { t, detections = { ... } }, ... } }
-- Output mirrors the input shape. Detections with `kind` starting
-- `ocr` (or exactly `ocr`) have `label` rewritten; other kinds
-- (yolo / extra / missing) are copied unchanged.
--
-- Standalone: `local normalisator = dofile("normalisator.lua")`.

local function is_ocr_kind(kind)
    if type(kind) ~= "string" then
        return false
    end
    kind = kind:lower()
    return kind == "ocr" or kind:sub(1, 4) == "ocr:"
end

-- UTF-8 byte sequences we treat as a space (plus ASCII 0x09–0x0d / 0x20).
local UNICODE_SPACES = {
    ["\194\160"] = true, -- U+00A0 NBSP
    ["\226\128\128"] = true, -- U+2000
    ["\226\128\129"] = true, -- U+2001
    ["\226\128\130"] = true, -- U+2002
    ["\226\128\131"] = true, -- U+2003
    ["\226\128\132"] = true, -- U+2004
    ["\226\128\133"] = true, -- U+2005
    ["\226\128\134"] = true, -- U+2006
    ["\226\128\135"] = true, -- U+2007
    ["\226\128\136"] = true, -- U+2008
    ["\226\128\137"] = true, -- U+2009
    ["\226\128\138"] = true, -- U+200A
    ["\226\128\175"] = true, -- U+202F
    ["\226\129\159"] = true, -- U+205F
    ["\227\128\128"] = true, -- U+3000
}

local function utf8_len(s, i)
    local c = s:byte(i)
    if not c then
        return 0
    end
    if c < 128 then
        return 1
    end
    if c < 224 then
        return 2
    end
    if c < 240 then
        return 3
    end
    return 4
end

local function is_ascii_space(b)
    return b == 32 or (b >= 9 and b <= 13)
end

-- Always English: any lookalike code point → ASCII A–Z / 0–9.
local HOMOGLYPHS = {}
local function fold(cp, ascii)
    HOMOGLYPHS[utf8.char(cp)] = ascii
end
-- Cyrillic
fold(0x0410, "A") fold(0x0430, "A") -- А а
fold(0x0412, "B") fold(0x0432, "B") -- В в
fold(0x0421, "C") fold(0x0441, "C") -- С с
fold(0x0415, "E") fold(0x0435, "E") fold(0x0401, "E") fold(0x0451, "E") -- Е е Ё ё
fold(0x041D, "H") fold(0x043D, "H") -- Н н
fold(0x0406, "I") fold(0x0456, "I") -- І і
fold(0x041A, "K") fold(0x043A, "K") -- К к
fold(0x041C, "M") fold(0x043C, "M") -- М м
fold(0x041E, "O") fold(0x043E, "O") -- О о
fold(0x0420, "P") fold(0x0440, "P") -- Р р
fold(0x0405, "S") fold(0x0455, "S") -- Ѕ ѕ
fold(0x0422, "T") fold(0x0442, "T") -- Т т
fold(0x0425, "X") fold(0x0445, "X") -- Х х
fold(0x0423, "Y") fold(0x0443, "Y") -- У у
-- Greek
fold(0x0391, "A") fold(0x03B1, "A")
fold(0x0392, "B") fold(0x03B2, "B")
fold(0x0395, "E") fold(0x03B5, "E")
fold(0x0397, "H") fold(0x03B7, "H")
fold(0x0399, "I") fold(0x03B9, "I")
fold(0x039A, "K") fold(0x03BA, "K")
fold(0x039C, "M") fold(0x03BC, "M")
fold(0x039D, "N") fold(0x03BD, "N")
fold(0x039F, "O") fold(0x03BF, "O")
fold(0x03A1, "P") fold(0x03C1, "P")
fold(0x03A4, "T") fold(0x03C4, "T")
fold(0x03A5, "Y") fold(0x03C5, "Y")
fold(0x03A7, "X") fold(0x03C7, "X")
fold(0x0396, "Z") fold(0x03B6, "Z")
-- Fullwidth English
for i = 0, 9 do
    fold(0xFF10 + i, string.char(48 + i))
end
for i = 0, 25 do
    fold(0xFF21 + i, string.char(65 + i))
    fold(0xFF41 + i, string.char(65 + i))
end

--- Normalize one OCR string.
local function normalize_value(s)
    if type(s) ~= "string" then
        return ""
    end
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local b = s:byte(i)
        local len = utf8_len(s, i)
        if len < 1 then
            break
        end
        local ch = s:sub(i, i + len - 1)
        local folded = HOMOGLYPHS[ch]
        if folded then
            out[#out + 1] = folded
        elseif len == 1 and is_ascii_space(b) then
            -- drop
        elseif UNICODE_SPACES[ch] then
            -- drop
        elseif len == 1 and b >= 97 and b <= 122 then
            out[#out + 1] = string.char(b - 32)
        elseif len == 1 and ((b >= 65 and b <= 90) or (b >= 48 and b <= 57)) then
            out[#out + 1] = ch
        end
        i = i + len
    end
    return table.concat(out)
end

local function copy_detection(d)
    local out = {}
    for k, v in pairs(d) do
        out[k] = v
    end
    if is_ocr_kind(d.kind) then
        out.label = normalize_value(d.label)
    end
    return out
end

local function map_detections(list)
    local out = {}
    for i, d in ipairs(list or {}) do
        out[i] = copy_detection(d)
    end
    return out
end

local function normalisator(input)
    input = input or {}
    if input.value ~= nil and input.values == nil and input.detections == nil and input.frames == nil then
        return { value = normalize_value(input.value) }
    end
    if type(input.values) == "table" then
        local values = {}
        for i, v in ipairs(input.values) do
            values[i] = normalize_value(v)
        end
        return { values = values }
    end
    if type(input.frames) == "table" then
        local frames = {}
        for i, frame in ipairs(input.frames) do
            local copy = {}
            for k, v in pairs(frame) do
                copy[k] = v
            end
            copy.detections = map_detections(frame.detections)
            frames[i] = copy
        end
        return { frames = frames }
    end
    if type(input.detections) == "table" then
        return { detections = map_detections(input.detections) }
    end
    return { value = "" }
end

return normalisator
