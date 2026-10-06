-- Fill dropped labels, then the global spatial window.
-- Concatenated after live_spatial.lua.

local function label_counts(list)
    local counts = {}
    for _, d in ipairs(list or {}) do
        counts[d.label] = (counts[d.label] or 0) + 1
    end
    return counts
end

local function det_center_dist(a, b)
    local ax = (a.x or 0) + (a.width or 0) / 2
    local ay = (a.y or 0) + (a.height or 0) / 2
    local bx = (b.x or 0) + (b.width or 0) / 2
    local by = (b.y or 0) + (b.height or 0) / 2
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

function registered_for_spatial_validation(accumulated, registered_frames)
    local out = {}
    for _, d in ipairs(accumulated or {}) do
        out[#out + 1] = d
    end
    local fill_frame = nil
    for i = #(registered_frames or {}), 1, -1 do
        local f = registered_frames[i]
        if f and f.detections and #f.detections > 0 then
            fill_frame = f
            break
        end
    end
    if not fill_frame then
        local best_n = -1
        for _, f in ipairs(registered_frames or {}) do
            local n = f.detections and #f.detections or 0
            if n > best_n then
                best_n = n
                fill_frame = f
            end
        end
    end
    if not fill_frame or not fill_frame.detections or #fill_frame.detections == 0 then
        return out
    end
    local latest = fill_frame.detections
    local have = label_counts(out)
    local want = label_counts(latest)
    for label, need in pairs(want) do
        local gap = need - (have[label] or 0)
        if gap > 0 then
            local existing, candidates = {}, {}
            for _, d in ipairs(out) do
                if d.label == label then
                    existing[#existing + 1] = d
                end
            end
            for _, d in ipairs(latest) do
                if d.label == label then
                    candidates[#candidates + 1] = d
                end
            end
            table.sort(candidates, function(a, b)
                local function min_dist(d)
                    local best = math.huge
                    for _, e in ipairs(existing) do
                        best = math.min(best, det_center_dist(d, e))
                    end
                    return best
                end
                local da, db = min_dist(a), min_dist(b)
                if da ~= db then
                    return db < da
                end
                return (b.confidence or 0) < (a.confidence or 0)
            end)
            for i = 1, math.min(gap, #candidates) do
                have[label] = (have[label] or 0) + 1
                out[#out + 1] = candidates[i]
            end
        end
    end
    return out
end

local function frame_aspect_of(opts)
    local aspect = tonumber(opts.frame_aspect) or 0
    if aspect == aspect and aspect > 1e-6 then
        return aspect
    end
    return 1.0
end

local function pcall_reg(frames, expected, aspect)
    local ok, reg = pcall(registration, {
        detections = frames,
        expected = expected,
        frame_aspect = aspect,
    })
    if ok and type(reg) == "table" then
        return reg
    end
    return nil
end

local function register_with(t, detections)
    local ok, out = pcall(registration, {
        op = "register_with",
        transform = t,
        detections = detections,
    })
    if ok and type(out) == "table" then
        return out.registered_detections or {}
    end
    return {}
end

local function run_spatial_validation(tree, registered, thresholds, layout_on)
    local v = validation({
        expected = tree,
        registered_detections = registered,
        thresholds = thresholds,
    })
    local laid = layout({
        expected = tree,
        registered_detections = registered,
        validation = v,
        thresholds = thresholds,
        enabled = layout_on ~= false,
    })
    return ruller({
        expected = tree,
        registered_detections = registered,
        validation = laid,
        thresholds = thresholds,
    })
end

local function pcall_acc(frames, thresholds)
    local ok, acc = pcall(accumulator, { frames = frames, thresholds = thresholds })
    if ok and type(acc) == "table" then
        return acc
    end
    return nil
end

local function run_global_spatial_window(tree, expected, frames, opts, zone_pair)
    local aspect = frame_aspect_of(opts)
    local registered_frames, frame_transforms, frame_dets = {}, {}, {}
    local seen = false
    for _, frame in ipairs(frames or {}) do
        local reg = pcall_reg({ frame }, tree, aspect)
        if reg then
            seen = seen or ((reg.matched_anchors or 0) > 0)
            frame_transforms[#frame_transforms + 1] = reg.transform or false
            local dets = reg.registered_detections or {}
            if zone_pair then
                local pts = zone_pair[2]
                local kept = {}
                for _, d in ipairs(dets) do
                    if zone.point_in_zone(pts, (d.x or 0) + (d.width or 0) * 0.5, (d.y or 0) + (d.height or 0) * 0.5) then
                        kept[#kept + 1] = d
                    end
                end
                dets = kept
            end
            frame_dets[#frame_dets + 1] = dets
        else
            frame_transforms[#frame_transforms + 1] = false
            frame_dets[#frame_dets + 1] = {}
        end
    end
    local transform = consensus_transform(frame_transforms)
    for i, t in ipairs(frame_transforms) do
        local dets = frame_dets[i] or {}
        local keep = false
        if type(t) == "table" and type(transform) == "table" then
            keep = transform_agrees(t, transform)
        elseif type(t) == "table" then
            keep = true
        end
        if keep then
            registered_frames[#registered_frames + 1] = { detections = dets }
        else
            registered_frames[#registered_frames + 1] = { detections = {} }
        end
    end
    local validate_tree = zone_pair and zone_pair[1] or tree
    if transform == nil then
        return missing_spatial_placeholder(validate_tree), nil, seen
    end
    local accumulation = pcall_acc(registered_frames, opts.accumulator_thresholds)
    if not accumulation then
        return missing_spatial_placeholder(validate_tree), transform, seen
    end
    local registered = registered_for_spatial_validation(accumulation.detections, registered_frames)
    if zone_pair then
        local pts, kept = zone_pair[2], {}
        for _, d in ipairs(registered) do
            if zone.point_in_zone(pts, (d.x or 0) + (d.width or 0) * 0.5, (d.y or 0) + (d.height or 0) * 0.5) then
                kept[#kept + 1] = d
            end
        end
        registered = kept
    end
    local result = run_spatial_validation(validate_tree, registered, opts.validation_thresholds, opts.layout)
    if not zone_pair then
        strip_presence_only_spatial_extras(result, expected)
        strip_unlinked_spatial_extras(result, expected, opts.catalog)
    end
    strip_tip_class_extras(result, anchor_class_labels(tree))
    return result, transform, seen
end
