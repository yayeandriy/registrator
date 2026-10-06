-- Verdict-sheet layout over colored anchor zones, and the result-pane
-- failures the sheet must never hide.
--
-- Needs `report_rules` in scope. Zone geometry is the host's: it hands
-- over the zones in paint order and, per placement, the zones whose
-- polygon holds its whole box.
--
--   report_zones.apply(entries, zones, zone_hits) -> entries
--     zones = { { object_id, hex } }, zone_hits = { { id, zones = { object_id } } }
--   report_zones.sections(entries, zones) -> { { id, zone, hex?, entries = { index } } }
--   report_zones.overlay(entries, validation_objects, names) -> entries
--   report_zones.from_verdict_rows(rows) -> validation_objects

local rules = report_rules
local report_zones = {}

local function with_zone(e, owner, hex, tip, suffix)
    local c = rules.copy(e)
    if suffix ~= nil then
        c.id = e.id .. "#" .. suffix
    end
    c.zone_owner, c.zone_hex, c.is_zone_tip = owner, hex, tip
    return c
end

local function zone_index(zones, id)
    for i, z in ipairs(zones) do
        if z.object_id == id then
            return i
        end
    end
    return nil
end

-- Tip first, then its members, zone by zone; a placement whose whole box
-- sits in several zones is listed under each. With two or more zones an
-- OK placement outside every zone stays off the sheet.
function report_zones.apply(entries, zones, zone_hits)
    zones = zones or {}
    if #zones == 0 then
        return entries
    end
    local hex, hits = {}, {}
    for _, z in ipairs(zones) do
        hex[z.object_id] = z.hex
    end
    for _, h in ipairs(zone_hits or {}) do
        hits[h.id] = h.zones
    end
    local out = {}
    for _, e in ipairs(entries) do
        local tip = zone_index(zones, e.id)
        local in_zones = hits[e.id] or {}
        if e.bucket == "extra" then
            out[#out + 1] = e
        elseif tip ~= nil then
            out[#out + 1] = with_zone(e, zones[tip].object_id, zones[tip].hex, true)
        elseif #in_zones > 0 then
            for _, z in ipairs(in_zones) do
                out[#out + 1] = with_zone(e, z, hex[z], false, z)
            end
        elseif not (#zones >= 2 and e.bucket == "ok") then
            out[#out + 1] = e
        end
    end
    return rules.sort_entries(out, function(e)
        for i, z in ipairs(zones) do
            if z.object_id == e.id or (e.is_zone_tip and z.object_id == e.zone_owner) then
                return { i, 0 }
            end
        end
        local owner = e.zone_owner ~= nil and zone_index(zones, e.zone_owner) or nil
        if owner ~= nil then
            return { owner, 1 }
        end
        return { #zones + 1, 2 }
    end)
end

function report_zones.sections(entries, zones)
    local out = {}
    local function push(id, zone, hex, keep)
        local members = {}
        for i, e in ipairs(entries) do
            if keep(e) then
                members[#members + 1] = i
            end
        end
        if #members > 0 then
            out[#out + 1] = { id = id, zone = zone, hex = hex, entries = members }
        end
    end
    for _, z in ipairs(zones) do
        push(z.object_id, true, z.hex, function(e)
            return e.zone_owner == z.object_id
        end)
    end
    if #zones < 2 then
        push("other", false, nil, function(e)
            return e.zone_owner == nil
        end)
    else
        push("other", false, nil, function(e)
            return e.zone_owner == nil and e.bucket ~= "extra" and e.bucket ~= "ok"
        end)
        push("extra", false, nil, function(e)
            return e.zone_owner == nil and e.bucket == "extra"
        end)
    end
    return out
end

local function dedupe(entries)
    local out = {}
    for _, e in ipairs(entries) do
        local at
        for i, o in ipairs(out) do
            -- A placement listed under several zones keeps one row per zone.
            if o.zone_owner == e.zone_owner
                and ((e.bucket ~= "ok" and o.bucket == e.bucket and rules.same_placement(o.id, e.id))
                    or rules.same_failure(o, e.bucket, e.name, e.matched_label, e.confidence)) then
                at = i
                break
            end
        end
        if at == nil then
            out[#out + 1] = e
        elseif out[at].routine == nil and e.routine ~= nil then
            out[at] = rules.preferring_hit(e, out[at])
        else
            out[at] = rules.preferring_hit(out[at], e)
        end
    end
    return out
end

local SETTLED = {
    matched = true,
    mismatched = true,
    mispositioned = true,
    misrotated = true,
    mispositioned_misrotated = true,
}

-- The settled verdict's rows as the result pane's objects: one per
-- placement, extras out, anything unsettled reads as missing.
function report_zones.from_verdict_rows(rows)
    local out, seen = {}, {}
    for _, r in ipairs(rows or {}) do
        local id = r.object_id
        if type(id) == "string" and id ~= "" and r.status ~= "extra" and not seen[id] then
            seen[id] = true
            out[#out + 1] = {
                id = id,
                yolo_class = r.label,
                status = SETTLED[r.status] and r.status or "missing",
                matched_label = r.matched_label,
                matched_confidence = r.confidence,
                delta_position = r.delta_position,
                delta_rotation = r.delta_rotation,
            }
        end
    end
    return out
end

-- The result pane is the truth for failures: zone stacking must not drop
-- a wrong-class hit, and a Presence OK must not hide a Spatial mismatch.
function report_zones.overlay(entries, validation_objects, names)
    local out = {}
    for i, e in ipairs(entries) do
        out[i] = e
    end
    for _, o in ipairs(validation_objects or {}) do
        local want = rules.bucket_for_status(o.status)
        if want ~= "ok" then
            local name = rules.display_name(o.id, names, o.yolo_class or o.ocr_value)
            local mm = rules.spatial_mismatches(o.status, o.delta_position, o.delta_rotation)
            local matches = {}
            for i, e in ipairs(out) do
                if rules.same_placement(e.id, o.id) then
                    matches[#matches + 1] = i
                end
            end
            if #matches == 0 then
                local known = false
                for _, e in ipairs(out) do
                    if rules.same_failure(e, want, name, o.matched_label, o.matched_confidence) then
                        known = true
                        break
                    end
                end
                if not known then
                    out[#out + 1] = {
                        id = o.id,
                        name = name,
                        bucket = want,
                        mismatches = mm,
                        confidence = o.matched_confidence,
                        matched_label = o.matched_label,
                    }
                end
            end
            for _, i in ipairs(matches) do
                local e = rules.copy(out[i])
                if e.bucket == "ok" or e.bucket == "missed" then
                    e.bucket = want
                end
                if #(e.mismatches or {}) == 0 then
                    e.mismatches = mm
                end
                if e.name == nil or e.name == "" then
                    e.name = name
                end
                e.confidence = o.matched_confidence or e.confidence
                e.matched_label = o.matched_label or e.matched_label
                out[i] = e
            end
        end
    end
    return dedupe(out)
end

return report_zones
