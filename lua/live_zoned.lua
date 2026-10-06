-- Zoned spatial window: each tip owns its polygon. Concatenated after live_window.lua.

local ZONE_DISC_MARGIN = 1.15

local function member_marks(tree, keep, ox, oy)
    local out = {}
    local function walk(nodes, base_x, base_y)
        for _, object in ipairs(nodes or {}) do
            local b = object.boundary or {}
            local x = base_x + (b.x or 0)
            local y = base_y + (b.y or 0)
            local classes = {}
            for _, c in ipairs(object.yolo_classes or {}) do
                local key = tostring(c or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
                if key ~= "" then
                    classes[#classes + 1] = key
                end
            end
            local id = tostring(object.id or "")
            local in_keep = keep[id] == true
            if not in_keep then
                for _, k in ipairs(keep) do
                    if tostring(k) == id then
                        in_keep = true
                        break
                    end
                end
            end
            if in_keep and #classes > 0 then
                out[#out + 1] = {
                    x = x + (b.width or 0) * 0.5,
                    y = y + (b.height or 0) * 0.5,
                    classes = classes,
                }
            end
            walk(object.children, x, y)
        end
    end
    walk(tree, -ox, -oy)
    return out
end

local function turn_about(t, px, py, deg)
    local s, c = math.sin(math.rad(deg)), math.cos(math.rad(deg))
    local vx, vy = px - (c * px - s * py), py - (s * px + c * py)
    local k = (t.px or 0) * vx + (t.py or 0) * vy + 1.0
    if math.abs(k) < 1e-12 then
        k = 1.0
    end
    return {
        tx = (t.tx + t.a * vx + t.b * vy) / k,
        ty = (t.ty + t.c * vx + t.d * vy) / k,
        a = (t.a * c + t.b * s) / k,
        b = (-t.a * s + t.b * c) / k,
        c = (t.c * c + t.d * s) / k,
        d = (-t.c * s + t.d * c) / k,
        px = ((t.px or 0) * c + (t.py or 0) * s) / k,
        py = (-(t.px or 0) * s + (t.py or 0) * c) / k,
    }
end

local function class_in(classes, label)
    local key = tostring(label or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    for _, c in ipairs(classes) do
        if c == key then
            return true
        end
    end
    return false
end

local function settle_zone_turn(t, pivot, square_tip, marks, detections, cap)
    local turns = square_tip and { 0.0, 90.0, 180.0, 270.0 } or { 0.0, 180.0 }
    local cap2 = cap * cap
    local function cost(cand)
        local sum, n = 0.0, 0
        for _, mark in ipairs(marks) do
            local fx, fy = apply_board_to_frame(cand, mark.x, mark.y)
            if fx then
                local best = math.huge
                for _, d in ipairs(detections) do
                    if class_in(mark.classes, d.label) then
                        local dx = (d.x or 0) + (d.width or 0) * 0.5 - fx
                        local dy = (d.y or 0) + (d.height or 0) * 0.5 - fy
                        best = math.min(best, dx * dx + dy * dy)
                    end
                end
                if best < math.huge then
                    sum = sum + math.min(best, cap2)
                    n = n + 1
                end
            end
        end
        if n > 0 then
            return sum
        end
        return nil
    end
    local best_cost = cost(t)
    if not best_cost then
        return t
    end
    local best = t
    for i = 2, #turns do
        local cand = turn_about(t, pivot[1], pivot[2], turns[i])
        local c = cost(cand)
        if c and c < best_cost * 0.8 - 1e-12 then
            best_cost = c
            best = cand
        end
    end
    return best
end

local function same_heading(a, b)
    local da = math.deg(math.atan(a.c, a.a) - math.atan(b.c, b.a)) % 360.0
    return math.min(da, 360.0 - da) < 30.0
end

local function zone_candidates(tip, detections, tip_labels, keep_fn)
    local out = { tip }
    for _, det in ipairs(detections or {}) do
        local key = tostring(det.label or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if not tip_labels[key] and not is_ocr_kind(det.kind) then
            if keep_fn((det.x or 0) + (det.width or 0) * 0.5, (det.y or 0) + (det.height or 0) * 0.5) then
                out[#out + 1] = det
            end
        end
    end
    return out
end

local function take_tip_detection(detections, labels, claimed)
    for index, det in ipairs(detections or {}) do
        if not claimed[index] then
            local key = tostring(det.label or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
            if labels[key] then
                claimed[index] = true
                return det
            end
        end
    end
    return nil
end

local function as_id_set(list)
    local set = {}
    if type(list) ~= "table" then
        return set
    end
    for _, id in ipairs(list) do
        set[tostring(id)] = true
    end
    for k, v in pairs(list) do
        if v == true and type(k) == "string" then
            set[k] = true
        end
    end
    return set
end

local function merge_zone_results(parts)
    local objects, extra_detections, seen = {}, {}, {}
    for _, part in ipairs(parts) do
        for _, o in ipairs(part.objects or {}) do
            local id = tostring(o.id or "")
            if not seen[id] then
                seen[id] = true
                objects[#objects + 1] = o
            end
        end
        for _, d in ipairs(part.extra_detections or {}) do
            extra_detections[#extra_detections + 1] = d
        end
    end
    local matched = 0
    for _, o in ipairs(objects) do
        if o.status == "matched" then
            matched = matched + 1
        end
    end
    local total = #objects
    return {
        objects = objects,
        extra_detections = extra_detections,
        matched = matched,
        total = total,
        extra = #extra_detections,
        score = total == 0 and 0.0 or (matched / total),
    }
end

local function empty_spatial()
    return {
        objects = {},
        extra_detections = {},
        score = 0.0,
        matched = 0,
        total = 0,
        extra = 0,
    }
end

local function run_zoned_spatial_window(tree, expected, frames, opts, zones)
    local boxes = zone.flatten_abs(tree)
    local members = zone.zone_member_ids(boxes, zones)
    local tip_ids, all_tip_labels = {}, {}
    for _, z in ipairs(zones) do
        tip_ids[tostring(z.object_id)] = true
    end
    local parts, zone_transforms, visible_zones = {}, {}, {}
    local done = as_id_set(opts.completed_zone_ids)
    local assigned_tips = {}
    for zone_i = 1, #zones do
        assigned_tips[zone_i] = {}
    end
    for frame_i, frame in ipairs(frames or {}) do
        local claimed = {}
        for zone_i, z in ipairs(zones) do
            local tip_tree = zone.filter_keep(tree, { z.object_id })
            local labels = tree_class_labels(tip_tree)
            for k in pairs(labels) do
                all_tip_labels[k] = true
            end
            assigned_tips[zone_i][frame_i] = take_tip_detection(frame.detections, labels, claimed)
        end
    end
    local aspect = frame_aspect_of(opts)
    for zone_i, z in ipairs(zones) do
        local keep = as_id_set(members[zone_i])
        if not done[tostring(z.object_id)] then
            local tip_tree_abs = zone.filter_keep(tree, { z.object_id })
            if #tip_tree_abs > 0 then
                local ox, oy = tip_origin(boxes, z.object_id)
                local tip_tree = shift_tree(tip_tree_abs, -ox, -oy)
                local tip_labels = tree_class_labels(tip_tree)
                local score_keep, score_list = {}, {}
                for id in pairs(keep) do
                    if not tip_ids[id] then
                        score_keep[id] = true
                        score_list[#score_list + 1] = id
                    end
                end
                local val_tree = drop_anchors(shift_tree(zone.filter_keep(tree, score_list), -ox, -oy))
                local zone_tree = shift_tree(zone.filter_keep(tree, keep), -ox, -oy)
                local marks = member_marks(tree, score_keep, ox, oy)
                local pivot, square_tip = { 0.0, 0.0 }, false
                for _, b in ipairs(boxes) do
                    if tostring(b.id) == tostring(z.object_id) then
                        local ratio = (b.height or 0) > 1e-9 and ((b.width or 0) / b.height) or 0.0
                        pivot = { (b.width or 0) * 0.5, (b.height or 0) * 0.5 }
                        square_tip = ratio >= 0.8 and ratio <= 1.25
                    end
                end
                local local_zone = {}
                for _, p in ipairs(z.points or {}) do
                    local_zone[#local_zone + 1] = { x = (p.x or 0) - ox, y = (p.y or 0) - oy }
                end
                local registered_frames, frame_transforms, frame_full = {}, {}, {}
                local latest_full = false
                local last_frame = math.max(#(frames or {}) - 1, 0)
                for frame_i, frame in ipairs(frames or {}) do
                    local tip = assigned_tips[zone_i][frame_i]
                    if not tip then
                        frame_transforms[frame_i] = false
                        registered_frames[frame_i] = { detections = {} }
                        frame_full[frame_i] = false
                    else
                        local t0reg = pcall_reg({ { t = frame.t, detections = { tip } } }, tip_tree, aspect)
                        local t0 = t0reg and t0reg.transform
                        if not t0 then
                            frame_transforms[frame_i] = false
                            registered_frames[frame_i] = { detections = {} }
                            frame_full[frame_i] = false
                        else
                            local tcx = (tip.x or 0) + (tip.width or 0) * 0.5
                            local tcy = (tip.y or 0) + (tip.height or 0) * 0.5
                            local radius = 0.0
                            for _, p in ipairs(local_zone) do
                                local fx, fy = apply_board_to_frame(t0, p.x, p.y)
                                if fx then
                                    radius = math.max(radius, math.sqrt((fx - tcx) ^ 2 + (fy - tcy) ^ 2))
                                end
                            end
                            radius = radius * ZONE_DISC_MARGIN
                            local near = zone_candidates(tip, frame.detections, tip_labels, function(x, y)
                                return math.sqrt((x - tcx) ^ 2 + (y - tcy) ^ 2) <= radius
                            end)
                            local t1 = settle_zone_turn(t0, pivot, square_tip, marks, near, radius)
                            local frame_poly = {}
                            for _, p in ipairs(local_zone) do
                                local fx, fy = apply_board_to_frame(t1, p.x, p.y)
                                if fx then
                                    frame_poly[#frame_poly + 1] = { x = fx, y = fy }
                                end
                            end
                            local full = #frame_poly >= 3 and zone.polygon_in_frame(frame_poly)
                            if frame_i == last_frame + 1 then
                                latest_full = full
                            end
                            if not full then
                                frame_transforms[frame_i] = false
                                registered_frames[frame_i] = { detections = {} }
                                frame_full[frame_i] = false
                            else
                                frame_full[frame_i] = true
                                local scoped = zone_candidates(tip, frame.detections, tip_labels, function(x, y)
                                    return zone.point_in_zone(frame_poly, x, y)
                                end)
                                local refined_reg = pcall_reg({ { t = frame.t, detections = scoped } }, zone_tree, aspect)
                                local t2 = refined_reg and refined_reg.transform
                                if t2 then
                                    t2 = settle_zone_turn(t2, pivot, square_tip, marks, scoped, radius)
                                    if not (transform_agrees(t2, t1) and same_heading(t2, t1)) then
                                        t2 = nil
                                    end
                                end
                                local t = t2 or t1
                                frame_transforms[frame_i] = t
                                local members_dets = {}
                                for i = 2, #scoped do
                                    members_dets[#members_dets + 1] = scoped[i]
                                end
                                registered_frames[frame_i] = { detections = register_with(t, members_dets) }
                            end
                        end
                    end
                end
                local transform = consensus_transform(frame_transforms)
                if latest_full then
                    if transform then
                        local abs = shift_origin(transform, ox, oy)
                        zone_transforms[#zone_transforms + 1] = { tostring(z.object_id), abs }
                        for _, id in ipairs(score_list) do
                            zone_transforms[#zone_transforms + 1] = { id, abs }
                        end
                    end
                    local seen_zone = { object_id = tostring(z.object_id), member_ids = score_list }
                    if #val_tree == 0 then
                        visible_zones[#visible_zones + 1] = seen_zone
                    elseif transform then
                        local scored_frames = {}
                        for i, frame in ipairs(registered_frames) do
                            if frame_full[i] then
                                scored_frames[#scored_frames + 1] = frame
                            end
                        end
                        if #scored_frames > 0 then
                            local accumulation = pcall_acc(scored_frames, opts.accumulator_thresholds)
                            if accumulation then
                                local registered = registered_for_spatial_validation(accumulation.detections, scored_frames)
                                local result = run_spatial_validation(val_tree, registered, opts.validation_thresholds, opts.layout)
                                strip_presence_only_spatial_extras(result, expected)
                                strip_unlinked_spatial_extras(result, expected, opts.catalog)
                                strip_tip_class_extras(result, all_tip_labels)
                                parts[#parts + 1] = result
                                visible_zones[#visible_zones + 1] = seen_zone
                            end
                        end
                    end
                end
            end
        end
    end
    local anchor_seen = false
    for _, frames_tips in ipairs(assigned_tips) do
        for _, tip in ipairs(frames_tips) do
            if tip then
                anchor_seen = true
            end
        end
    end
    if #parts == 0 then
        return empty_spatial(), nil, zone_transforms, visible_zones, anchor_seen
    end
    local merged = merge_zone_results(parts)
    strip_tip_class_extras(merged, all_tip_labels)
    return merged, nil, zone_transforms, visible_zones, anchor_seen
end
