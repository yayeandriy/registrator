-- The verdict sheet: one component row per placement (YOLO + OCR halves
-- folded together), each in one bucket, plus the expected rows a HUD
-- shows before the first scored tick. Hosts only name and paint rows.
--
-- Needs `report_rules`, `report_catalog` and `report_zones` in scope.
--
--   report.build {
--       anchor_searching, expected, profile_objects?, anchor_count,
--       presence?, spatial?, validation_objects, names = { { id, name } },
--       ocr_labels, ocr_detections, catalog, zones, zone_hits }
--     -> { entries, sections, awaiting_anchor, no_expectations, no_anchor }
--     (`verdict_rows` — the settled verdict's rows — may stand in for
--     `validation_objects`)
--     (`catalog`, `zones`, `zone_hits`: see `report_catalog` / `report_zones`)
--   report.placeholder { expected, presence, spatial }
--     -> { kind = "presence"|"spatial"|"none", presence?, spatial? }
--   report.no_anchor { objects, anchor_count } -> { no_anchor }
--
-- entry = { id, name, bucket = "ok"|"missed"|"incorrect_object"|"misplaced"|
--           "extra"|"incorrect_values", mismatches = { { expected, seen?,
--           delta_mm?, delta_deg? } }, routine? = "presence"|"spatial"|"both",
--           confidence?, matched_label?, zone_owner?, zone_hex?, is_zone_tip }

local rules = report_rules
local report = {}

local function entry(id, name, bucket, confidence, matched_label, mismatches)
    return {
        id = id,
        name = name,
        bucket = bucket,
        mismatches = mismatches or {},
        confidence = confidence,
        matched_label = matched_label,
    }
end

local function tree_has(objects, field)
    for _, o in ipairs(rules.flatten(objects)) do
        if o[field] then
            return true
        end
    end
    return false
end

-- Spatial placements with no registration tip anywhere: an authoring
-- mistake, not the runtime anchor search.
local function no_anchor(objects, anchor_count)
    return tree_has(objects, "spatial") and not tree_has(objects, "is_anchor") and (anchor_count or 0) == 0
end

function report.no_anchor(input)
    return { no_anchor = no_anchor(input.objects or {}, input.anchor_count) }
end

local function ocr_name(needle, id, ctx)
    local key = rules.alnum(needle)
    if key ~= "" then
        for _, comp in ipairs(ctx.catalog) do
            for _, v in ipairs(comp.ocr_values or {}) do
                if rules.alnum(v) == key then
                    local n = rules.trim(comp.display_name)
                    if n ~= "" then
                        return n
                    end
                end
            end
        end
    end
    return rules.display_name(id, ctx.names, needle)
end

local function best_yolo_hit(rows)
    local best
    for _, r in ipairs(rows) do
        if r.match_kind == "yolo" or r.match_kind == nil then
            if best == nil or (r.matched_confidence or -1) > (best.matched_confidence or -1) then
                best = r
            end
        end
    end
    return best and best.matched_label, best and best.matched_confidence
end

local function first(list)
    return (list or {})[1]
end

local function group_by_id(objects)
    local order, by = {}, {}
    for _, o in ipairs(objects or {}) do
        if by[o.id] == nil then
            by[o.id] = {}
            order[#order + 1] = o.id
        end
        local g = by[o.id]
        g[#g + 1] = o
    end
    return order, by
end

local function presence_rows(id, rows, all, ctx, out)
    local yolo, ocr = {}, {}
    for _, r in ipairs(rows) do
        if r.match_kind == "yolo" then
            yolo[#yolo + 1] = r
        elseif r.match_kind == "ocr" then
            ocr[#ocr + 1] = r
        end
    end
    local fallback = (yolo[1] and first(yolo[1].yolo_classes)) or (ocr[1] and first(ocr[1].ocr_values))
    local name = rules.display_name(id, ctx.names, fallback)
    local hit_label, hit_conf = best_yolo_hit(rows)
    if #yolo > 0 then
        local missing, classes = false, {}
        for _, r in ipairs(yolo) do
            missing = missing or r.status == "missing"
            for _, c in ipairs(r.yolo_classes or {}) do
                classes[#classes + 1] = c
            end
        end
        local bucket = "ok"
        if missing then
            bucket = rules.is_wrong_object(name, classes, hit_label) and "incorrect_object" or "missed"
        end
        out[#out + 1] = entry(id, name, bucket, hit_conf, hit_label)
    end
    local foreign, matched = {}, {}
    for _, o in ipairs(all) do
        if o.id ~= id and o.match_kind == "ocr" and first(o.ocr_values) ~= nil then
            foreign[#foreign + 1] = first(o.ocr_values)
        end
    end
    for _, r in ipairs(ocr) do
        if r.status == "matched" and first(r.ocr_values) ~= nil then
            matched[#matched + 1] = first(r.ocr_values)
        end
    end
    for _, r in ipairs(ocr) do
        local needle = first(r.ocr_values) or ""
        local key = rules.alnum(needle)
        if key ~= "" then
            ctx.claimed[key] = true
        end
        local row_name = ocr_name(needle, id, ctx)
        local row_id = id .. "#ocr#" .. (key ~= "" and key or row_name)
        if r.status == "matched" then
            out[#out + 1] = entry(row_id, row_name, "ok", r.matched_confidence, r.matched_label or needle)
        else
            local seen = rules.pick_seen(needle, matched, foreign, ctx.ocr_labels)
            if seen ~= nil then
                out[#out + 1] = entry(row_id, row_name, "incorrect_values", r.matched_confidence, seen,
                    { { expected = needle, seen = seen } })
            else
                out[#out + 1] = entry(row_id, row_name, "missed", r.matched_confidence, r.matched_label)
            end
        end
    end
end

-- Texts placed on a component that Presence did not score still get a
-- row. Router inputs and unplaced catalog texts are not needles here.
local function missing_ocr_rows(ctx, out)
    for _, o in ipairs(rules.flatten(ctx.expected)) do
        for _, needle in ipairs(o.ocr_values or {}) do
            local key = rules.alnum(needle)
            if key ~= "" and not ctx.claimed[key] then
                ctx.claimed[key] = true
                local name = ocr_name(needle, o.id, ctx)
                local seen
                for _, l in ipairs(ctx.ocr_labels) do
                    if rules.hits(l, needle) then
                        seen = l
                        break
                    end
                end
                out[#out + 1] = entry(o.id .. "#ocr#" .. key, name, seen and "ok" or "missed", nil, seen)
            end
        end
    end
end

local function presence(p, ctx)
    local out = {}
    local order, by = group_by_id(p.objects)
    for _, id in ipairs(order) do
        presence_rows(id, by[id], p.objects or {}, ctx, out)
    end
    missing_ocr_rows(ctx, out)
    for _, d in ipairs(p.extra_detections or {}) do
        local kind = rules.lower(d.kind or "yolo")
        if kind ~= "ocr" and not rules.loose_suppressed(d, p.objects, ctx.loose)
            and rules.keep_surplus(d.label, d.matched_label, ctx.profile_keys) then
            local e = report_catalog.plain_extra(d)
            if kind == "extra" then
                e.name = d.matched_label or ("Unidentified (" .. d.label .. ")")
            end
            out[#out + 1] = e
        end
    end
    return rules.sort_entries(out)
end

local function spatial(s, ctx)
    local out = {}
    for _, o in ipairs(s.objects or {}) do
        out[#out + 1] = entry(
            o.id,
            rules.display_name(o.id, ctx.names, o.yolo_class or o.ocr_value),
            rules.bucket_for_status(o.status),
            o.matched_confidence,
            o.matched_label,
            rules.spatial_mismatches(o.status, o.delta_position, o.delta_rotation)
        )
    end
    for _, e in ipairs(report_catalog.extras(s.extra_detections, ctx.ocr_detections, ctx.catalog, ctx.profile_keys)) do
        out[#out + 1] = e
    end
    return rules.sort_entries(out)
end

local function tagged(e, routine)
    local c = rules.copy(e)
    c.routine = routine
    return c
end

-- Both routines ran: union by id, a shared id keeps the Spatial outcome.
local function merge(p, s)
    local order, by = {}, {}
    for _, e in ipairs(p) do
        if e.bucket ~= "extra" then
            by[e.id] = tagged(e, "presence")
            order[#order + 1] = e.id
        end
    end
    for _, e in ipairs(s) do
        if e.bucket ~= "extra" then
            if by[e.id] ~= nil then
                by[e.id] = tagged(e, "both")
            else
                by[e.id] = tagged(e, "spatial")
                order[#order + 1] = e.id
            end
        end
    end
    local out, seen = {}, {}
    for _, id in ipairs(order) do
        out[#out + 1] = by[id]
    end
    for _, pass in ipairs({ { s, "spatial" }, { p, "presence" } }) do
        for _, e in ipairs(pass[1]) do
            if e.bucket == "extra" and not seen[e.id] then
                seen[e.id] = true
                out[#out + 1] = tagged(e, pass[2])
            end
        end
    end
    return rules.sort_entries(out)
end

function report.build(input)
    if input.anchor_searching then
        return { entries = {}, sections = {}, awaiting_anchor = true, no_expectations = false, no_anchor = false }
    end
    local expected = input.expected or {}
    if #expected == 0 then
        local missing = no_anchor(input.profile_objects or {}, input.anchor_count)
        return { entries = {}, sections = {}, awaiting_anchor = false, no_expectations = not missing, no_anchor = missing }
    end
    local loose = {}
    for _, o in ipairs(rules.flatten(expected)) do
        if o.loose_match then
            loose[#loose + 1] = o
        end
    end
    local names = {}
    for _, n in ipairs(input.names or {}) do
        names[n.id] = n.name
    end
    local ctx = {
        names = names,
        ocr_labels = input.ocr_labels or {},
        ocr_detections = input.ocr_detections or {},
        catalog = input.catalog or {},
        expected = expected,
        profile_keys = rules.profile_class_keys(expected),
        loose = loose,
        claimed = {},
    }
    local base = {}
    if input.presence ~= nil and input.spatial ~= nil then
        base = merge(presence(input.presence, ctx), spatial(input.spatial, ctx))
    elseif input.presence ~= nil then
        base = presence(input.presence, ctx)
    elseif input.spatial ~= nil then
        base = spatial(input.spatial, ctx)
    end
    local zones = input.zones or {}
    local entries = report_zones.apply(base, zones, input.zone_hits)
    local pane = input.validation_objects or report_zones.from_verdict_rows(input.verdict_rows)
    entries = report_zones.overlay(entries, pane, ctx.names)
    return {
        entries = entries,
        sections = #zones > 0 and report_zones.sections(entries, zones) or {},
        awaiting_anchor = false,
        no_expectations = false,
        no_anchor = no_anchor(input.profile_objects or expected, input.anchor_count),
    }
end

local function classes_of(o)
    if #(o.yolo_classes or {}) > 0 then
        return o.yolo_classes
    end
    return o.yolo_class and { o.yolo_class } or {}
end

local function texts_of(o)
    if #(o.ocr_values or {}) > 0 then
        return o.ocr_values
    end
    return o.ocr_value and { o.ocr_value } or {}
end

-- Presence / OCR expectations as missing, split into rows the way
-- `presence_validator.lua` splits them.
local function missing_presence(expected)
    local objects = {}
    for _, o in ipairs(rules.flatten(expected)) do
        local classes, texts = classes_of(o), texts_of(o)
        local yolo = #classes > 0 and (o.presence or not o.spatial)
        local base = { id = o.id, is_anchor = o.is_anchor == true, status = "missing" }
        if yolo then
            local r = rules.copy(base)
            r.yolo_classes, r.ocr_values, r.presence, r.match_kind = classes, {}, true, "yolo"
            objects[#objects + 1] = r
        end
        for _, t in ipairs(texts) do
            local r = rules.copy(base)
            r.yolo_classes, r.ocr_values, r.presence, r.match_kind = {}, { t }, o.presence == true, "ocr"
            objects[#objects + 1] = r
        end
        if o.presence and not yolo and #texts == 0 then
            local r = rules.copy(base)
            r.yolo_classes, r.ocr_values, r.presence = classes, texts, true
            objects[#objects + 1] = r
        end
    end
    return { objects = objects, extra_detections = {}, score = 0, matched = 0, total = #objects, extra = 0 }
end

-- Spatial placements in tree order, nested ones included.
local function missing_spatial(expected)
    local objects = {}
    for _, o in ipairs(rules.flatten(expected)) do
        if o.spatial then
            objects[#objects + 1] = {
                id = o.id,
                yolo_class = o.yolo_class or first(o.yolo_classes),
                ocr_value = o.ocr_value or first(o.ocr_values),
                is_anchor = o.is_anchor == true,
                status = "missing",
            }
        end
    end
    return { objects = objects, extra_detections = {}, score = 0, matched = 0, total = #objects, extra = 0 }
end

-- Before the first scored tick the HUD lists what it expects. A
-- Presence-only board has no anchor; a Spatial board still gets its rows.
function report.placeholder(input)
    local expected = input.expected or {}
    local run_presence = input.presence == true
    for _, o in ipairs(expected) do
        run_presence = run_presence or o.presence == true
    end
    local p = missing_presence(expected)
    if run_presence and p.total > 0 then
        return { kind = "presence", presence = p }
    end
    if input.spatial then
        local s = missing_spatial(expected)
        if s.total > 0 then
            return { kind = "spatial", spatial = s }
        end
    end
    if p.total > 0 then
        return { kind = "presence", presence = p }
    end
    return { kind = "none" }
end

return report
