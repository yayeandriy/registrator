-- Expected-object helpers shared by the spatial, registration and
-- presence scripts: field cleanup, class / text identity, flattening.
--
-- Needs `class_match`; the text helpers also need `normalisator` and
-- `matcher` (all composed as locals by `bundles.json`).

local expected = {}

local function trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
expected.trim = trim

local function non_empty(s)
    return type(s) == "string" and trim(s) ~= ""
end
expected.non_empty = non_empty

-- Upper-case alphanumerics — the one text identity (`normalisator.lua`).
function expected.normalize(s)
    local r = normalisator({ value = s })
    if type(r) == "table" and type(r.value) == "string" then
        return r.value
    end
    return ""
end

function expected.is_ocr_kind(kind)
    if type(kind) ~= "string" then
        return false
    end
    kind = kind:lower()
    return kind == "ocr" or kind:sub(1, 4) == "ocr:"
end

-- Expected `needle` read inside found `hay` (`matcher.lua`).
function expected.text_hits(hay, needle)
    local r = matcher({ hay = hay, needle = needle })
    return r and r.matched == true
end

local function cleaned(list, single)
    local out = {}
    if type(list) == "table" then
        for _, v in ipairs(list) do
            if non_empty(v) then
                out[#out + 1] = trim(v)
            end
        end
        if #out > 0 then
            return out
        end
    end
    if non_empty(single) then
        return { trim(single) }
    end
    return {}
end

-- `yolo_classes`, else the legacy singular `yolo_class`.
function expected.yolo_classes(o)
    return cleaned(o.yolo_classes, o.yolo_class)
end

-- `ocr_values`, else the legacy `ocr_value`. With `name_fallback`, a
-- text-only placement with no needles expects its own name.
function expected.ocr_values(o, name_fallback)
    local out = cleaned(o.ocr_values, o.ocr_value)
    if #out == 0 and name_fallback and #expected.yolo_classes(o) == 0 and non_empty(o.name) then
        return { trim(o.name) }
    end
    return out
end

-- Whether `detection` (a table or a bare label) is one of `classes`.
function expected.in_classes(detection, classes)
    local d = detection
    if type(d) ~= "table" then
        d = { label = d }
    end
    return class_match.in_expected(d, classes)
end

-- Spatial identity: a class of `o`, or for a text-only placement a read
-- holding one of its needles.
function expected.matches_object(detection, o)
    if expected.in_classes(detection, class_match.expected_list(o)) then
        return true
    end
    if #(o.yolo_classes or {}) == 0 then
        local label = type(detection) == "table" and detection.label or detection
        for _, needle in ipairs(o.ocr_values or {}) do
            if expected.text_hits(label, needle) then
                return true
            end
        end
    end
    return false
end

function expected.is_expected_text(label, expected_flat)
    for _, o in ipairs(expected_flat) do
        for _, needle in ipairs(o.ocr_values or {}) do
            if expected.text_hits(label, needle) then
                return true
            end
        end
    end
    return false
end

-- Depth-first, board-space boxes (children offset by their parent's
-- origin; ancestor rotations are not composed).
local function flatten(objects, origin_x, origin_y, out)
    for _, o in ipairs(objects) do
        local x = origin_x + o.boundary.x
        local y = origin_y + o.boundary.y
        out[#out + 1] = {
            id = o.id,
            yolo_classes = expected.yolo_classes(o),
            yolo_class_refs = o.yolo_class_refs,
            vision_model_id = o.vision_model_id,
            ocr_values = expected.ocr_values(o, true),
            x = x,
            y = y,
            width = o.boundary.width,
            height = o.boundary.height,
            rotation = o.rotation or 0.0,
            is_anchor = o.is_anchor,
            symmetry = o.symmetry or "inf",
            thresholds = o.thresholds,
            real_size = o.real_size,
        }
        if o.children then
            flatten(o.children, x, y, out)
        end
    end
    return out
end

function expected.flatten(objects)
    return flatten(objects or {}, 0.0, 0.0, {})
end

return expected
