-- Live OCR policy: whether this tick read the expected text, whether the
-- read is settled, and which stale reads leave the live window.
--
-- Loaded as the `ocr_window` local ahead of `verdict.lua` (the host
-- concatenates the two), or as a global by the pure-Lua tests. Needs
-- `matcher` (and the `normalisator` it reads) in scope: a read hits an
-- expected text exactly when Presence would match it.
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
--   ocr_window.text_reads {
--       mode = "frame"|"window"|"view", reads = { <this tick's detection> },
--       frames = { { detections } }, pool = { <detection> }, needles }
--     -> { reads, pool }

local ocr_window = {}

-- Ticks with the expected text on camera before a read is settled.
local SETTLE_TICKS = 4
-- Empty ticks before a never-seen expected string is a real miss.
local ABSENT_TICKS = 4

function ocr_window.hits(label, needle)
    local r = matcher({ hay = tostring(label or ""), needle = tostring(needle or "") })
    return type(r) == "table" and r.matched == true
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

-- Which text reads Presence scores this tick. `frame`: this tick's own.
-- `window`: also expected text read in any frame still in the window.
-- `view`: also expected text read earlier in the view; `pool` carries those
-- reads from tick to tick, and the host empties it when the view changes.
-- Each expected text keeps its newest read: one read this tick stands for
-- every earlier read of it, and one read can hold several texts.
function ocr_window.text_reads(input)
    local mode = input.mode
    local reads = input.reads or {}
    if mode ~= "window" and mode ~= "view" then
        return { reads = reads, pool = {} }
    end
    local needles = input.needles or {}
    local out, covered = {}, {}
    -- Marks the texts `d` holds that no newer read held; true when any.
    local function cover(d)
        local any = false
        if is_ocr_kind(d.kind) then
            for i, n in ipairs(needles) do
                if not covered[i] and ocr_window.hits(d.label, n) then
                    covered[i] = true
                    any = true
                end
            end
        end
        return any
    end
    for _, d in ipairs(reads) do
        out[#out + 1] = d
        cover(d)
    end
    local function add(d)
        if cover(d) then
            out[#out + 1] = d
        end
    end
    local pool = {}
    if mode == "window" then
        local frames = input.frames or {}
        for i = #frames, 1, -1 do
            for _, d in ipairs(frames[i].detections or {}) do
                add(d)
            end
        end
    else
        for _, d in ipairs(input.pool or {}) do
            add(d)
        end
        for _, d in ipairs(out) do
            if is_ocr_kind(d.kind) and hits_any(d.label, needles) then
                pool[#pool + 1] = d
            end
        end
    end
    return { reads = out, pool = pool }
end

return ocr_window
