-- Unexpected stamps on the verdict sheet: cluster unclaimed Spatial
-- boxes into full class-set instances and name each from the project
-- catalog by the OCR inside it (a code only one component carries wins).
-- Only surplus of a class the profile places is listed.
--
-- Needs `report_rules`, `boxes` and `catalog_instances` in scope.
--
--   report_catalog.extras(found, ocr, catalog, profile_keys) -> { entry }
--     catalog = { { id, display_name, yolo_classes, ocr_values } }

local rules = report_rules
local report_catalog = {}

local function box_key(d)
    return string.format("%s|%.4f|%.4f|%.4f|%.4f", d.label, d.x, d.y, d.width, d.height)
end

local function same_label(d, class)
    return d.label == class
end

function report_catalog.instances(classes, remaining)
    return catalog_instances.cluster(classes, remaining, same_label)
end

-- A code read inside the instance scores 10 when only this component
-- carries it, 1 otherwise. Class-only components accept any instance.
function report_catalog.score(comp, instance, ocr, group)
    local region = boxes.pad(boxes.union(instance))
    local score, required, found, unique = 0, 0, 0, false
    for _, needle in ipairs(comp.ocr_values or {}) do
        local n = rules.alnum(needle)
        if n ~= "" then
            required = required + 1
            local hit = false
            for _, o in ipairs(ocr or {}) do
                if boxes.inside(region, o) and rules.hits(o.label, needle) then
                    hit = true
                    break
                end
            end
            if hit then
                found = found + 1
                local owners = 0
                for _, g in ipairs(group) do
                    for _, v in ipairs(g.ocr_values or {}) do
                        if rules.alnum(v) == n then
                            owners = owners + 1
                            break
                        end
                    end
                end
                if owners == 1 then
                    unique = true
                    score = score + 10
                else
                    score = score + 1
                end
            end
        end
    end
    if required == 0 then
        return 1
    end
    if found < required and not unique then
        return 0
    end
    return score
end

local function signature(classes)
    local keys = {}
    for i, c in ipairs(classes) do
        keys[i] = c:lower()
    end
    table.sort(keys)
    return table.concat(keys, "\0")
end

local function groups(catalog)
    local order, by = {}, {}
    for _, comp in ipairs(catalog or {}) do
        if #(comp.yolo_classes or {}) > 0 then
            local sig = signature(comp.yolo_classes)
            if by[sig] == nil then
                by[sig] = {}
                order[#order + 1] = sig
            end
            local g = by[sig]
            g[#g + 1] = comp
        end
    end
    local out = {}
    for i, sig in ipairs(order) do
        out[i] = by[sig]
    end
    return out
end

local function plain_extra(d)
    return {
        id = string.format("extra-%s-%.4f-%.4f", d.label, d.x, d.y),
        name = d.label,
        bucket = "extra",
        mismatches = {},
        confidence = d.confidence,
        matched_label = d.label,
    }
end
report_catalog.plain_extra = plain_extra

function report_catalog.extras(found, ocr, catalog, profile_keys)
    local remaining = {}
    for _, d in ipairs(found or {}) do
        local kind = rules.lower(d.kind or "yolo")
        if kind:sub(1, 3) ~= "ocr" and rules.keep_surplus(d.label, d.matched_label, profile_keys) then
            remaining[#remaining + 1] = d
        end
    end
    if #remaining == 0 then
        return {}
    end
    local entries = {}
    for _, comps in ipairs(groups(catalog)) do
        local instances
        instances, remaining = report_catalog.instances(comps[1].yolo_classes, remaining)
        if #instances > 0 then
            local scored = {}
            for _, comp in ipairs(comps) do
                for _, inst in ipairs(instances) do
                    local s = report_catalog.score(comp, inst, ocr, comps)
                    if s > 0 then
                        scored[#scored + 1] = { comp = comp, inst = inst, score = s, n = #scored + 1 }
                    end
                end
            end
            table.sort(scored, function(a, b)
                if a.score ~= b.score then
                    return a.score > b.score
                end
                return a.n < b.n
            end)
            local claimed = {}
            local function taken(inst)
                for _, d in ipairs(inst) do
                    if claimed[box_key(d)] then
                        return true
                    end
                end
                return false
            end
            for _, p in ipairs(scored) do
                if not taken(p.inst) then
                    local keys, conf = {}, nil
                    for i, d in ipairs(p.inst) do
                        keys[i] = box_key(d)
                        claimed[keys[i]] = true
                        conf = (conf == nil or d.confidence > conf) and d.confidence or conf
                    end
                    entries[#entries + 1] = {
                        id = "extra-" .. tostring(p.comp.id) .. "-" .. table.concat(keys, "|"),
                        name = p.comp.display_name,
                        bucket = "extra",
                        mismatches = {},
                        confidence = conf,
                        matched_label = p.inst[1].label,
                    }
                end
            end
            for _, inst in ipairs(instances) do
                if not taken(inst) then
                    for _, d in ipairs(inst) do
                        remaining[#remaining + 1] = d
                    end
                end
            end
        end
    end
    for _, d in ipairs(remaining) do
        entries[#entries + 1] = plain_extra(d)
    end
    return entries
end

return report_catalog
