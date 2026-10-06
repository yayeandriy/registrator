-- Live OCR policy: whether this tick read the expected text, whether the
-- read is settled, and which stale reads leave the live window.
--
-- Loaded as the `ocr_window` local ahead of `verdict.lua` (the host
-- concatenates the two), or as a global by the pure-Lua tests.
--
--   ocr_window.hits(label, needle) -> bool
--   ocr_window.progress {
--       wants_ocr, engine_off, backend_ran, rows, needles,
--       read_labels = { "<geometric det label>" }, box_ticks, empty_ticks }
--     -> { ready, tick_finished, has_match, reads_expected,
--          read_hits = { <1-based index into read_labels> }, box_ticks, empty_ticks }
--   ocr_window.drop_stale {
--       frames = { { t, detections = { { label, kind, width, height, ... } } } },
--       live_labels = { "<geometric det label>" }, needles, ocr_ticked }
--     -> { frames }

local ocr_window = {}

-- Ticks with the expected text on camera before a read is settled.
local SETTLE_TICKS = 4
-- Empty ticks before a never-seen expected string is a real miss.
local ABSENT_TICKS = 4

-- Alphanumeric, upper-case. Two strings hit when either holds the other.
local function key(s)
    return (tostring(s or ""):gsub("[^%w]", ""):upper())
end

function ocr_window.hits(label, needle)
    local a, b = key(label), key(needle)
    if a == "" or b == "" then
        return false
    end
    return a == b or a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

local function hits_any(label, needles)
    for _, n in ipairs(needles or {}) do
        if ocr_window.hits(label, n) then
            return true
        end
    end
    return false
end

function ocr_window.row_hits(row, needles)
    return hits_any(row.label, needles) or (row.matched_label ~= nil and hits_any(row.matched_label, needles))
end

local function is_ocr_kind(kind)
    return type(kind) == "string" and kind:lower() == "ocr"
end

function ocr_window.progress(input)
    local needles = input.needles or {}
    local read_hits = {}
    for i, l in ipairs(input.read_labels or {}) do
        if hits_any(l, needles) then
            read_hits[#read_hits + 1] = i
        end
    end
    local reads_expected = #read_hits > 0
    local has_match = false
    for _, r in ipairs(input.rows or {}) do
        if r.status == "matched" and (is_ocr_kind(r.match_kind) or ocr_window.row_hits(r, needles)) then
            has_match = true
        end
    end
    local backend_ran = input.backend_ran or reads_expected
    local box, empty = input.box_ticks or 0, input.empty_ticks or 0
    local out = {
        has_match = has_match,
        reads_expected = reads_expected,
        read_hits = read_hits,
        tick_finished = not input.wants_ocr or input.engine_off or backend_ran,
    }
    if not input.wants_ocr or input.engine_off or has_match then
        out.ready = true
    elseif reads_expected then
        box = box + 1
        empty = 0
        out.ready = box >= SETTLE_TICKS
    else
        -- Every score counts, including "engine not flagged yet", so a
        -- read cannot hang while YOLO is already answering.
        empty = empty + 1
        local need = (not backend_ran or box == 0) and ABSENT_TICKS or SETTLE_TICKS
        out.ready = empty >= need
    end
    out.box_ticks, out.empty_ticks = box, empty
    return out
end

local function is_geom_ocr(d)
    local kind = type(d.kind) == "string" and d.kind:lower() or ""
    local ocr = kind == "ocr" or kind:sub(1, 4) == "ocr:"
    return ocr and (d.width or 0) > 1e-6 and (d.height or 0) > 1e-6
end

-- The latest real OCR tick is the truth. When it ran and the expected
-- text is gone, a removed label must not keep scoring as misplaced.
function ocr_window.drop_stale(input)
    local frames = input.frames or {}
    local needles = input.needles or {}
    if #needles == 0 or not input.ocr_ticked then
        return { frames = frames }
    end
    for _, l in ipairs(input.live_labels or {}) do
        if hits_any(l, needles) then
            return { frames = frames }
        end
    end
    for _, f in ipairs(frames) do
        local kept = {}
        for _, d in ipairs(f.detections or {}) do
            if not is_geom_ocr(d) or not hits_any(d.label, needles) then
                kept[#kept + 1] = d
            end
        end
        f.detections = kept
    end
    return { frames = frames }
end

return ocr_window
