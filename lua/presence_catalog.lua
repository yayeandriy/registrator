-- Presence catalog-anchored extras (`opts.anchor_extras`): unclaimed YOLO
-- boxes clustered into full class-set instances per catalog signature,
-- each named from the catalog by the OCR inside it (see the header of
-- `presence_validator.lua`).
--
--   presence_catalog.extras(unclaimed, catalog, ocr_detections) -> rows
--   presence_catalog.copy(detection) -> an extra row for one box
--
-- Needs `class_match`, `expected`, `boxes`, `catalog_instances` and
-- `presence_ocr`.

local presence_catalog = {}

function presence_catalog.copy(d)
    local kind = d.kind
    if not kind or kind == "" then
        kind = "yolo"
    end
    return {
        label = d.label,
        confidence = d.confidence,
        x = d.x,
        y = d.y,
        width = d.width,
        height = d.height,
        kind = kind,
        class_id = d.class_id,
        vision_model_id = d.vision_model_id,
    }
end

local function class_signature(classes)
    local copy = {}
    for _, c in ipairs(classes) do
        table.insert(copy, c)
    end
    table.sort(copy)
    return table.concat(copy, "\0")
end

-- A signature owned by a single catalog component is unambiguous by
-- construction and always accepted without needing OCR. Otherwise a
-- text only this component carries scores 10, a shared one 1.
local function score_instance(comp, instance, ocr_detections, group)
    if #group <= 1 then
        return 1
    end
    local region = boxes.pad(boxes.union(instance))
    if not region then
        return 0
    end
    local ax, ay = boxes.region_center(region)
    local score = 0
    local required = 0
    local found = 0
    local unique_hit = false
    for _, needle in ipairs(comp.ocr_values or {}) do
        if expected.normalize(needle) ~= "" then
            required = required + 1
            if presence_ocr.find(ocr_detections, needle, region, nil, ax, ay) then
                found = found + 1
                if presence_ocr.owners(group, needle) == 1 then
                    unique_hit = true
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
    if found < required and not unique_hit then
        return 0
    end
    return score
end

-- Biggest class sets first, so a 2-class stamp is not starved by a
-- single-class catalog row grabbing one of its two boxes first. Boxes in
-- no catalog signature pass through as plain rows — never dropped.
function presence_catalog.extras(unclaimed, catalog, ocr_detections)
    local groups = {}
    local order = {}
    for _, comp in ipairs(catalog or {}) do
        local classes = comp.yolo_classes or {}
        if #classes > 0 then
            local key = class_signature(classes)
            if not groups[key] then
                groups[key] = { classes = classes, comps = {} }
                table.insert(order, key)
            end
            table.insert(groups[key].comps, comp)
        end
    end
    table.sort(order, function(a, b)
        return #groups[a].classes > #groups[b].classes
    end)

    local remaining = unclaimed
    local results = {}
    for _, key in ipairs(order) do
        local grp = groups[key]
        local instances
        instances, remaining = catalog_instances.cluster(grp.classes, remaining, class_match.match)
        for _, instance in ipairs(instances) do
            local best_comp, best_score = nil, 0
            for _, comp in ipairs(grp.comps) do
                local score = score_instance(comp, instance, ocr_detections, grp.comps)
                if score > best_score then
                    best_score = score
                    best_comp = comp
                end
            end
            local u = boxes.union(instance)
            local top = instance[1]
            local name = best_comp and (best_comp.name or best_comp.id) or nil
            table.insert(results, {
                label = name or top.label,
                confidence = top.confidence,
                x = u.x1,
                y = u.y1,
                width = u.x2 - u.x1,
                height = u.y2 - u.y1,
                kind = "extra",
                matched_label = name,
            })
        end
    end

    for _, d in ipairs(remaining) do
        table.insert(results, presence_catalog.copy(d))
    end
    return results
end

return presence_catalog
