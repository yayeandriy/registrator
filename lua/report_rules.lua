-- Verdict-sheet rules shared by `report.lua`, `report_catalog.lua` and
-- `report_zones.lua`: row names, class keys, which surplus box is an
-- Extra, which OCR read is a wrong value, and how a Spatial status reads.
--
-- Needs `normalisator` and `ocr_window` in scope (the host concatenates
-- them ahead), or as globals in the pure-Lua tests.

local rules = {}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
rules.trim = trim

function rules.lower(s)
    return tostring(s or ""):lower()
end

-- English A–Z / 0–9 with lookalikes folded: the key an OCR row is claimed by.
function rules.alnum(s)
    return normalisator({ value = tostring(s or "") }).value
end

function rules.hits(label, needle)
    return ocr_window.hits(label, needle)
end

function rules.class_key(s)
    return (trim(s):lower():gsub(" ", "_"))
end

function rules.flatten(nodes, out)
    out = out or {}
    for _, o in ipairs(nodes or {}) do
        out[#out + 1] = o
        rules.flatten(o.children, out)
    end
    return out
end

local function has_letter(s)
    return s:find("[%a\128-\255]") ~= nil
end

-- One line per row. A multi-line OCR dump keeps its first letter-bearing
-- line (`X04` from `0 2 / 2 0 / 1 1 / X04`).
function rules.compact_label(raw)
    local lines = {}
    for line in (tostring(raw or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        local t = trim(line)
        if t ~= "" then
            lines[#lines + 1] = t
        end
    end
    if #lines <= 1 then
        return lines[1] or ""
    end
    for _, l in ipairs(lines) do
        if has_letter(l) then
            return l
        end
    end
    return lines[1]
end

function rules.display_name(id, names, fallback)
    local n = (names or {})[id]
    if type(n) == "string" and n ~= "" then
        return n
    end
    if fallback ~= nil then
        local c = rules.compact_label(fallback)
        if c ~= "" then
            return c
        end
    end
    return id
end

-- A scored hit whose class is neither this component's class nor its name.
function rules.is_wrong_object(name, classes, hit)
    local h = trim(hit)
    if hit == nil or h == "" then
        return false
    end
    local want = {}
    for _, c in ipairs(classes or {}) do
        local k = rules.class_key(c)
        if k ~= "" then
            want[k] = true
        end
    end
    local n = rules.class_key(name)
    if n ~= "" then
        want[n] = true
    end
    return not want[rules.class_key(h)]
end

function rules.profile_class_keys(expected)
    local keys = {}
    for _, o in ipairs(rules.flatten(expected)) do
        local k = rules.class_key(o.yolo_class)
        if k ~= "" then
            keys[k] = true
        end
        for _, c in ipairs(o.yolo_classes or {}) do
            k = rules.class_key(c)
            if k ~= "" then
                keys[k] = true
            end
        end
    end
    return keys
end

-- Surplus is an Extra only for a class some profile component carries;
-- catalog-only leftovers are ignored.
function rules.keep_surplus(label, matched_label, profile_keys)
    if profile_keys[rules.class_key(label)] then
        return true
    end
    return matched_label ~= nil and profile_keys[rules.class_key(matched_label)] == true
end

local function class_set(o)
    local set = {}
    for _, c in ipairs(o.yolo_classes or {}) do
        set[rules.class_key(c)] = true
    end
    set[rules.class_key(o.yolo_class)] = true
    set[""] = nil
    return set
end

-- Same-class boxes beyond a loose-match placement that already matched
-- are that placement's, not Extras.
function rules.loose_suppressed(d, objects, loose)
    local label = rules.class_key(d.label)
    local named = rules.class_key(d.matched_label or d.label)
    for _, o in ipairs(loose) do
        local classes = class_set(o)
        local name = trim(o.name):lower()
        local hit = classes[label] or classes[named]
            or (name ~= "" and (rules.lower(d.label) == name
                or (d.matched_label ~= nil and rules.lower(d.matched_label) == name)))
        if hit then
            for _, row in ipairs(objects or {}) do
                if row.status == "matched" and row.match_kind ~= "ocr" then
                    for _, c in ipairs(row.yolo_classes or {}) do
                        if classes[rules.class_key(c)] then
                            return true
                        end
                    end
                    local m = row.matched_label
                    if m ~= nil and (classes[rules.class_key(m)] or (name ~= "" and rules.lower(m) == name)) then
                        return true
                    end
                    if row.id == o.id then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function hits_any(label, needles)
    for _, n in ipairs(needles) do
        if rules.hits(label, n) then
            return true
        end
    end
    return false
end

-- The read that stands in for `expected`: not a sibling's code, not the
-- expected text itself, and not a lone digit blip ("2", "0").
function rules.pick_seen(expected, matched_needles, foreign_needles, labels)
    local expected_len = #rules.alnum(expected)
    for _, label in ipairs(labels or {}) do
        local trimmed = trim(label)
        if trimmed ~= "" and not hits_any(label, matched_needles) and not hits_any(label, foreign_needles)
            and not rules.hits(label, expected) then
            local norm = rules.alnum(label)
            local blip = #norm < 2 or (norm:match("^%d+$") ~= nil and #norm < math.min(3, expected_len))
            if not blip then
                return trimmed
            end
        end
    end
    return nil
end

local BUCKETS = {
    matched = "ok",
    missing = "missed",
    mismatched = "incorrect_object",
    mispositioned = "misplaced",
    misrotated = "misplaced",
    mispositioned_misrotated = "misplaced",
}

function rules.bucket_for_status(status)
    return BUCKETS[status] or "missed"
end

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- `moved` carries the millimetres whenever they are measurable, even
-- inside the threshold; `rotated` only when the angle failed.
function rules.spatial_mismatches(status, delta_position, delta_rotation)
    local over_pos = status == "mispositioned" or status == "mispositioned_misrotated"
    local over_rot = status == "misrotated" or status == "mispositioned_misrotated"
    local out = {}
    local mm = finite(delta_position) and delta_position > 0.05 and math.abs(delta_position) or nil
    if over_pos or mm ~= nil then
        out[#out + 1] = { expected = "moved", delta_mm = mm }
    end
    if over_rot then
        local deg = finite(delta_rotation) and math.abs(delta_rotation) > 0.5 and math.abs(delta_rotation) or nil
        out[#out + 1] = { expected = "rotated", delta_deg = deg }
    end
    return out
end

function rules.canonical_id(id)
    return (tostring(id or ""):match("^[^#]*"))
end

function rules.same_placement(a, b)
    local x, y = rules.canonical_id(a), rules.canonical_id(b)
    return x ~= "" and x == y
end

-- Same outcome on the same scored box: one row, not two.
function rules.same_failure(e, bucket, name, matched_label, confidence)
    if e.bucket ~= bucket or rules.lower(e.name) ~= rules.lower(name) then
        return false
    end
    local a, b = trim(e.matched_label), trim(matched_label)
    if a == "" or a:lower() ~= b:lower() then
        return false
    end
    if e.confidence ~= nil and confidence ~= nil then
        return math.abs(e.confidence - confidence) < 0.005
    end
    return true
end

function rules.copy(e)
    local c = {}
    for k, v in pairs(e) do
        c[k] = v
    end
    return c
end

-- Keep `e`, but take `other`'s hit when it is the more confident one.
function rules.preferring_hit(e, other)
    local take = other.confidence ~= nil and (e.confidence == nil or other.confidence > e.confidence)
    if not take then
        return e
    end
    local c = rules.copy(e)
    c.confidence, c.matched_label = other.confidence, other.matched_label
    return c
end

-- Stable, case-insensitive by name; `rank` (optional) sorts first.
function rules.sort_entries(entries, rank)
    local order = {}
    for i, e in ipairs(entries) do
        order[i] = { e = e, i = i, n = rules.lower(e.name), r = rank and rank(e) or { 0, 0 } }
    end
    table.sort(order, function(a, b)
        if a.r[1] ~= b.r[1] then
            return a.r[1] < b.r[1]
        end
        if a.r[2] ~= b.r[2] then
            return a.r[2] < b.r[2]
        end
        if a.n ~= b.n then
            return a.n < b.n
        end
        return a.i < b.i
    end)
    local out = {}
    for i, item in ipairs(order) do
        out[i] = item.e
    end
    return out
end

return rules
