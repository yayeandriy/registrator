-- Live verdict assembly: one tick's Presence / Spatial results become
-- the verdict a host shows, settles and samples for completion.
--
-- Hosts keep only the state these ops hand back (`spatial_hold`) and
-- paint the rows; every pass / fail / complete decision is made here.
--
-- Ops (`{ op = "<name>", ... }`):
--
--   from_presence { presence = PresenceResult,
--                   lacks = { [object id] = { Lack } } }  -> { verdict = Verdict }
--   from_spatial  { spatial = ValidationResult, lacks,
--                   hold = { HoldEntry } }               -> { verdict, objects, hold }
--   merge         { presence = Verdict|nil,
--                   spatial = Verdict|nil,
--                   ocr_labels = { "<ocr det label>" },
--                   needles = { "<expected text>" },
--                   ocr = <ocr_window.progress input minus rows/needles> }
--                                                        -> { verdict = Verdict|nil, ocr }
--
--   lines { rows, objects }                              -> { lines } (`verdict_lines`)
--
-- Needs `ocr_window` and `verdict_lines` in scope.
--
-- Verdict = { result = "pass"|"fail"|"pending", matched, total,
--             incorrect, missing, extra, complete, no_expectations,
--             rows = { Row } }
-- Row     = { object_id?, label, status, confidence?, matched_label?,
--             delta_position?, delta_rotation?, match_kind?, lacks? }
-- Lack    = { label, kind = "class"|"text", why = "unseen"|"outside" }:
--           a detection of a failed part that did not count (live `lacks`,
--           or one of several checks of the part that missed)
-- HoldEntry = { id, shown = <spatial object>, fail_streak }

local verdict = {}

-- A soft fail must repeat this many ticks before a matched object shows
-- it — OBB angle jitter otherwise blinks the part every tick.
local SOFT_FAIL_HOLD = 2

local INCORRECT = {
    mispositioned = true,
    misrotated = true,
    mispositioned_misrotated = true,
    mismatched = true,
}

local SOFT_FAIL = {
    misrotated = true,
    mispositioned = true,
    mispositioned_misrotated = true,
}

-- Pose failures beat missing, missing beats matched, when several checks
-- (Presence, Spatial, a part's class and its text) report one object.
local STATUS_RANK = {
    matched = 0,
    missing = 1,
    mismatched = 2,
    misrotated = 3,
    mispositioned = 4,
    mispositioned_misrotated = 5,
}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function first_nonempty(list)
    for _, s in ipairs(list or {}) do
        local t = trim(s)
        if t ~= "" then
            return t
        end
    end
    return nil
end

local function counts(rows)
    local incorrect, missing = 0, 0
    for _, r in ipairs(rows) do
        if r.status == "missing" then
            missing = missing + 1
        elseif INCORRECT[r.status] then
            incorrect = incorrect + 1
        end
    end
    return incorrect, missing
end

local function decide(no_expectations, complete)
    if no_expectations then
        return "pending"
    elseif complete then
        return "pass"
    end
    return "fail"
end

local function scored(rows, matched, total, extra)
    local no_expectations = total == 0
    local incorrect, missing = counts(rows)
    local complete = not no_expectations and matched == total and extra == 0
    return {
        result = decide(no_expectations, complete and incorrect == 0),
        matched = matched,
        total = total,
        incorrect = incorrect,
        missing = missing,
        extra = extra,
        complete = complete,
        no_expectations = no_expectations,
        rows = rows,
    }
end

local function is_ocr_kind(kind)
    return type(kind) == "string" and kind:lower() == "ocr"
end

local function presence_label(o)
    if is_ocr_kind(o.match_kind) then
        return first_nonempty(o.ocr_values) or o.matched_label or ""
    end
    return first_nonempty(o.yolo_classes) or o.matched_label or first_nonempty(o.ocr_values) or ""
end

local function lacks_for(lacks, o)
    if o.status == "matched" or type(lacks) ~= "table" then
        return nil
    end
    local found = lacks[o.id]
    if type(found) == "table" and #found > 0 then
        return found
    end
    return nil
end

function verdict.from_presence(input)
    local p = input.presence or {}
    local rows = {}
    for _, o in ipairs(p.objects or {}) do
        rows[#rows + 1] = {
            object_id = o.id,
            label = presence_label(o),
            status = o.status,
            confidence = o.matched_confidence,
            matched_label = o.matched_label,
            match_kind = o.match_kind,
            lacks = lacks_for(input.lacks, o),
        }
    end
    return { verdict = scored(rows, p.matched or 0, p.total or 0, p.extra or 0) }
end

local function spatial_label(o)
    return first_nonempty(o.yolo_classes) or o.matched_label or first_nonempty(o.ocr_values) or ""
end

local function spatial_kind(o)
    if first_nonempty(o.ocr_values) and not first_nonempty(o.yolo_classes) then
        return "ocr"
    end
    return "spatial"
end

-- Keep `matched` until a soft fail repeats.
local function stabilize(prev, objects)
    local by_id = {}
    for _, h in ipairs(prev or {}) do
        by_id[h.id] = h
    end
    local shown, hold = {}, {}
    for _, o in ipairs(objects or {}) do
        local prior = by_id[o.id]
        local was_ok = prior ~= nil and prior.shown ~= nil and prior.shown.status == "matched"
        local kept = false
        if was_ok and SOFT_FAIL[o.status] then
            local streak = (prior.fail_streak or 0) + 1
            if streak < SOFT_FAIL_HOLD then
                shown[#shown + 1] = prior.shown
                hold[#hold + 1] = { id = o.id, shown = prior.shown, fail_streak = streak }
                kept = true
            end
        end
        if not kept then
            shown[#shown + 1] = o
            hold[#hold + 1] = { id = o.id, shown = o, fail_streak = 0 }
        end
    end
    return shown, hold
end

function verdict.from_spatial(input)
    local v = input.spatial or {}
    local objects, hold = stabilize(input.hold, v.objects)
    local rows = {}
    for _, o in ipairs(objects) do
        rows[#rows + 1] = {
            object_id = o.id,
            label = spatial_label(o),
            status = o.status,
            confidence = o.matched_confidence,
            matched_label = o.matched_label,
            delta_position = o.delta_position,
            delta_rotation = o.delta_rotation,
            match_kind = spatial_kind(o),
            lacks = lacks_for(input.lacks, o),
        }
    end
    for _, d in ipairs(v.extra_detections or {}) do
        rows[#rows + 1] = { label = d.label, status = "extra", confidence = d.confidence }
    end
    return {
        verdict = scored(rows, v.matched or 0, v.total or 0, v.extra or 0),
        objects = objects,
        hold = hold,
    }
end

-- A part several checks report names the detections that did not count:
-- those its rows carry, else the missed checks while they differ.
local function merged_lacks(rows)
    local out, known, labels, distinct = {}, {}, {}, 0
    local function add(l)
        local key = tostring(l.kind) .. ":" .. tostring(l.label)
        if not known[key] then
            known[key] = true
            out[#out + 1] = l
        end
    end
    for _, r in ipairs(rows) do
        local label = trim(r.label)
        if label ~= "" and not labels[label] then
            labels[label] = true
            distinct = distinct + 1
        end
    end
    for _, r in ipairs(rows) do
        if type(r.lacks) == "table" and #r.lacks > 0 then
            for _, l in ipairs(r.lacks) do
                add(l)
            end
        elseif r.status == "missing" and distinct > 1 and trim(r.label) ~= "" then
            add({ label = trim(r.label), kind = is_ocr_kind(r.match_kind) and "text" or "class", why = "unseen" })
        end
    end
    return out
end

local function with_lacks(row, rows)
    if row.status == "matched" then
        return row
    end
    local lacks = merged_lacks(rows)
    if #lacks == 0 then
        return row
    end
    local out = {}
    for k, v in pairs(row) do
        out[k] = v
    end
    out.lacks = lacks
    return out
end

local function union(presence, spatial)
    local no_expectations = presence.no_expectations and spatial.no_expectations
    local extra = (presence.extra or 0) + (spatial.extra or 0)
    local by_key, order, extras, unnamed, reported = {}, {}, {}, 0, {}
    local function take(row)
        if row.status == "extra" then
            extras[#extras + 1] = row
            return
        end
        local key = row.object_id
        if key == nil or key == "" then
            unnamed = unnamed + 1
            key = "anon:" .. unnamed
        end
        reported[key] = reported[key] or {}
        table.insert(reported[key], row)
        local existing = by_key[key]
        local rank, known = STATUS_RANK[row.status] or 0, existing and (STATUS_RANK[existing.status] or 0)
        if existing == nil then
            order[#order + 1] = key
            by_key[key] = row
        elseif rank > known or (rank == known and not (is_ocr_kind(row.match_kind) and not is_ocr_kind(existing.match_kind))) then
            -- On a tie the part's row stays, so a held text miss never hides a part miss.
            by_key[key] = row
        end
    end
    for _, r in ipairs(presence.rows or {}) do take(r) end
    for _, r in ipairs(spatial.rows or {}) do take(r) end
    local rows, matched = {}, 0
    for _, k in ipairs(order) do
        rows[#rows + 1] = with_lacks(by_key[k], reported[k])
        if by_key[k].status == "matched" then
            matched = matched + 1
        end
    end
    local total = #rows
    for _, r in ipairs(extras) do rows[#rows + 1] = r end
    local incorrect, missing = counts(rows)
    local complete = not no_expectations and matched == total and extra == 0 and incorrect == 0
    return {
        result = decide(no_expectations, complete),
        matched = matched,
        total = total,
        incorrect = incorrect,
        missing = missing,
        extra = extra,
        complete = complete,
        no_expectations = no_expectations,
        rows = rows,
    }
end

-- OCR boxes are read text, never a surplus part.
local function strip_ocr_extras(v, ocr_labels)
    local ocr = {}
    local any = false
    for _, l in ipairs(ocr_labels or {}) do
        ocr[l] = true
        any = true
    end
    if not any then
        return v
    end
    local rows, extra = {}, 0
    for _, r in ipairs(v.rows) do
        if r.status ~= "extra" or not ocr[r.label] then
            rows[#rows + 1] = r
            if r.status == "extra" then
                extra = extra + 1
            end
        end
    end
    v.rows = rows
    v.extra = extra
    v.complete = not v.no_expectations and v.matched == v.total and extra == 0
    v.result = decide(v.no_expectations, v.complete)
    return v
end

-- Until OCR has run, a text miss is not yet a miss.
local function hold_unsettled_ocr(v, needles)
    local held = 0
    for _, r in ipairs(v.rows) do
        if r.status == "missing" and (is_ocr_kind(r.match_kind) or ocr_window.row_hits(r, needles)) then
            r.status = "pending"
            held = held + 1
        end
    end
    if held == 0 then
        return v
    end
    v.missing = math.max(0, v.missing - held)
    v.complete = false
    if v.incorrect == 0 and v.missing == 0 and v.extra == 0 then
        v.result = "pending"
    end
    return v
end

-- One row per object, however many checks report it.
function verdict.merge(input)
    local p, s = input.presence, input.spatial
    if p == nil and s == nil then
        return {}
    end
    local none = { no_expectations = true, extra = 0, rows = {} }
    local v = union(p or none, s or none)
    v.rows = v.rows or {}
    v = strip_ocr_extras(v, input.ocr_labels)
    local ocr_in = input.ocr or {}
    ocr_in.rows = v.rows
    ocr_in.needles = input.needles
    local ocr = ocr_window.progress(ocr_in)
    if not ocr.tick_finished then
        v = hold_unsettled_ocr(v, input.needles)
    end
    return { verdict = v, ocr = ocr }
end

verdict.lines = verdict_lines.lines

return verdict
