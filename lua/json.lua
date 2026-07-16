-- Minimal, dependency-free JSON encode/decode for hosting this repo's
-- scripts behind a "JSON string in, JSON string out" boundary.
--
-- Why this exists: `registration.lua`/`validation.lua`/`accumulator.lua`
-- expect a genuine Lua *table* as their argument and return one — that's
-- exactly what mlua's serde bridge gives the Rust host for free (it
-- marshals a Rust struct straight into Lua table values, no JSON text
-- involved at all). A host with no such bridge available (e.g. a plain C
-- Lua VM driven from Swift over the `lua_State*` C API) has no equally
-- direct way to hand over a Rust/Swift value as native Lua table values,
-- but *can* trivially pass a Lua string across that boundary — so that
-- host is expected to run a tiny shim wrapping each script:
--   local registration = require("registration")
--   return json.encode(registration(json.decode(...)))
-- and do its own JSON encode/decode of the Codable values on its own
-- side. The Rust host has no use for this file at all.
--
-- Decoded JSON `null` becomes `json.null` — a distinct sentinel table,
-- not plain Lua `nil` — since a Lua table can't hold a real `nil` *value*
-- under an existing key (`t.k = nil` removes `k` entirely). This mirrors
-- the exact reasoning `registration.lua`'s own header comment gives for
-- why mlua represents Rust's `None` as a sentinel userdata rather than
-- bare `nil`: every script in this repo already tests optional fields
-- with `type(x) == "table"` (real quads) or `type(x) == "number"`
-- (real rotations), and `json.null` satisfies neither — `#json.null`
-- is `0`, never `4`, so it can never be mistaken for a real corners
-- quad, and it's never a `number`, so it can never be mistaken for a
-- real rotation either. No script in this repo needs to change to
-- accommodate it.

local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end })

-- ===================== Encode =====================

local encode_value -- forward declaration (mutually recursive with encode_table)

local escape_map = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function encode_string(s)
    local out = { '"' }
    for i = 1, #s do
        local c = s:sub(i, i)
        local escaped = escape_map[c]
        if escaped then
            out[#out + 1] = escaped
        elseif c:byte() < 0x20 then
            out[#out + 1] = string.format("\\u%04x", c:byte())
        else
            out[#out + 1] = c
        end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

local function encode_number(n)
    if n ~= n then
        error("json.encode: cannot encode NaN")
    end
    if n == math.huge or n == -math.huge then
        error("json.encode: cannot encode infinity")
    end
    if math.type(n) == "integer" then
        return tostring(n)
    end
    -- %.17g round-trips any double exactly (the classic "shortest
    -- round-trippable decimal" guarantee needs more care than this, but
    -- 17 significant digits is always *sufficient*, just occasionally
    -- longer than strictly necessary — fine for a data interchange
    -- format nobody hand-reads).
    local formatted = string.format("%.17g", n)
    -- Every number in this repo's schemas is logically a float (board
    -- units, confidences, normalized coordinates) — always emit a
    -- decimal point/exponent so Swift's `Double`-typed Codable fields
    -- never choke on e.g. `"width": 10` being read where `10.0` was
    -- expected under a strict decoder.
    if not formatted:find("[%.eEnN]") then
        formatted = formatted .. ".0"
    end
    return formatted
end

-- Heuristic used both here and in `decode`'s array/object choice: a Lua
-- table is treated as a JSON array iff it's empty, or every key is a
-- positive integer forming a contiguous `1..n` run. Every array-shaped
-- field in this repo's own schemas (`detections`, `expected`, `objects`,
-- `extra_detections`, `children`, ...) is always built by the producing
-- script via `table.insert`, so this always holds for real output; an
-- empty table defaulting to `[]` rather than `{}` matches every genuinely
-- empty *array* field these scripts ever produce (e.g.
-- `registered_detections = {}` when registration fails) — no field in
-- any of the three scripts' schemas is ever an intentionally-empty JSON
-- *object*.
local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
            return false
        end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then
            return false
        end
    end
    return true
end

local function encode_table(t)
    if t == json.null then
        return "null"
    end
    if is_array(t) then
        local out = {}
        for i = 1, #t do
            out[i] = encode_value(t[i])
        end
        return "[" .. table.concat(out, ",") .. "]"
    end

    local out = {}
    for k, v in pairs(t) do
        if type(k) ~= "string" then
            error("json.encode: object keys must be strings, got " .. type(k))
        end
        out[#out + 1] = encode_string(k) .. ":" .. encode_value(v)
    end
    return "{" .. table.concat(out, ",") .. "}"
end

function encode_value(v)
    local t = type(v)
    if v == json.null then
        return "null"
    elseif t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        return encode_number(v)
    elseif t == "string" then
        return encode_string(v)
    elseif t == "table" then
        return encode_table(v)
    else
        error("json.encode: cannot encode a " .. t)
    end
end

function json.encode(value)
    return encode_value(value)
end

-- ===================== Decode =====================

local decode_value -- forward declaration

local function decode_error(s, pos, message)
    local line = 1
    for i = 1, pos - 1 do
        if s:sub(i, i) == "\n" then
            line = line + 1
        end
    end
    error(string.format("json.decode: %s (line %d, pos %d)", message, line, pos))
end

local function skip_whitespace(s, pos)
    local _, e = s:find("^[ \t\r\n]*", pos)
    return e + 1
end

local decode_escape_map = {
    ['"'] = '"',
    ["\\"] = "\\",
    ["/"] = "/",
    b = "\b",
    f = "\f",
    n = "\n",
    r = "\r",
    t = "\t",
}

local function decode_string(s, pos)
    -- `pos` points just past the opening quote.
    local out = {}
    local i = pos
    while true do
        local c = s:sub(i, i)
        if c == "" then
            decode_error(s, i, "unterminated string")
        elseif c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local next_c = s:sub(i + 1, i + 1)
            if next_c == "u" then
                local hex = s:sub(i + 2, i + 5)
                local code = tonumber(hex, 16)
                if not code then
                    decode_error(s, i, "invalid \\u escape")
                end
                -- Only the Basic Multilingual Plane is supported (no
                -- surrogate-pair handling) — every string value in this
                -- repo's schemas (labels, uuids, class names) is plain
                -- ASCII, so this is never exercised in practice.
                if code < 0x80 then
                    out[#out + 1] = string.char(code)
                elseif code < 0x800 then
                    out[#out + 1] = string.char(
                        0xC0 | (code >> 6),
                        0x80 | (code & 0x3F)
                    )
                else
                    out[#out + 1] = string.char(
                        0xE0 | (code >> 12),
                        0x80 | ((code >> 6) & 0x3F),
                        0x80 | (code & 0x3F)
                    )
                end
                i = i + 6
            else
                local mapped = decode_escape_map[next_c]
                if not mapped then
                    decode_error(s, i, "invalid escape '\\" .. next_c .. "'")
                end
                out[#out + 1] = mapped
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

local function decode_number(s, pos)
    local match, e = s:match("^(-?%d+%.?%d*[eE]?[+-]?%d*)()", pos)
    if not match then
        decode_error(s, pos, "invalid number")
    end
    local n = tonumber(match)
    if not n then
        decode_error(s, pos, "invalid number literal '" .. match .. "'")
    end
    return n, e
end

local function decode_array(s, pos)
    -- `pos` points just past the opening `[`.
    local out = {}
    pos = skip_whitespace(s, pos)
    if s:sub(pos, pos) == "]" then
        return out, pos + 1
    end
    local i = 1
    while true do
        local value, next_pos = decode_value(s, pos)
        out[i] = value
        i = i + 1
        pos = skip_whitespace(s, next_pos)
        local c = s:sub(pos, pos)
        if c == "]" then
            return out, pos + 1
        elseif c ~= "," then
            decode_error(s, pos, "expected ',' or ']' in array")
        end
        pos = skip_whitespace(s, pos + 1)
    end
end

local function decode_object(s, pos)
    -- `pos` points just past the opening `{`.
    local out = {}
    pos = skip_whitespace(s, pos)
    if s:sub(pos, pos) == "}" then
        return out, pos + 1
    end
    while true do
        if s:sub(pos, pos) ~= '"' then
            decode_error(s, pos, "expected string key in object")
        end
        local key, after_key = decode_string(s, pos + 1)
        pos = skip_whitespace(s, after_key)
        if s:sub(pos, pos) ~= ":" then
            decode_error(s, pos, "expected ':' after object key")
        end
        pos = skip_whitespace(s, pos + 1)
        local value, next_pos = decode_value(s, pos)
        out[key] = value
        pos = skip_whitespace(s, next_pos)
        local c = s:sub(pos, pos)
        if c == "}" then
            return out, pos + 1
        elseif c ~= "," then
            decode_error(s, pos, "expected ',' or '}' in object")
        end
        pos = skip_whitespace(s, pos + 1)
    end
end

function decode_value(s, pos)
    pos = skip_whitespace(s, pos)
    local c = s:sub(pos, pos)
    if c == '"' then
        return decode_string(s, pos + 1)
    elseif c == "{" then
        return decode_object(s, pos + 1)
    elseif c == "[" then
        return decode_array(s, pos + 1)
    elseif c == "t" and s:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif c == "f" and s:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif c == "n" and s:sub(pos, pos + 3) == "null" then
        return json.null, pos + 4
    elseif c == "-" or c:match("%d") then
        return decode_number(s, pos)
    else
        decode_error(s, pos, "unexpected character '" .. c .. "'")
    end
end

function json.decode(s)
    local value, pos = decode_value(s, 1)
    pos = skip_whitespace(s, pos)
    if pos <= #s then
        decode_error(s, pos, "trailing data after top-level value")
    end
    return value
end

return json
