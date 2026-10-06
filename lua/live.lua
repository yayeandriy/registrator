-- Live inspect orchestrator. Concatenated last; returns the callable.

local function run_spatial_window(tree, expected, frames, opts)
    local zoned = zone.usable_zones(opts.zones)
    if #zoned >= 2 then
        return run_zoned_spatial_window(tree, expected, frames, opts, zoned)
    end
    local result, transform, seen = run_global_spatial_window(tree, expected, frames, opts, nil)
    return result, transform, {}, {}, seen
end

local function rewrite_frames(frames)
    local ok, out = pcall(normalisator, { frames = frames })
    if ok and type(out) == "table" and type(out.frames) == "table" then
        return out.frames
    end
    return frames
end

local function rewrite_dets(dets)
    local ok, out = pcall(normalisator, { detections = dets })
    if ok and type(out) == "table" and type(out.detections) == "table" then
        return out.detections
    end
    return dets
end

local function run_presence(expected, frames, opts, spatial_expected)
    local latest
    if opts.presence_overlay then
        latest = opts.presence_overlay
    else
        local last = frames[#frames]
        latest = detections_as_presence(last and last.detections)
    end
    if expected_has_ocr(expected) then
        latest = rewrite_dets(latest)
    end
    local input = { expected = expected, detections = latest }
    if opts.catalog and #opts.catalog > 0 then
        input.catalog = opts.catalog
        input.opts = { anchor_extras = true }
    end
    local ok, raw = pcall(presence_validator, input)
    if not ok or type(raw) ~= "table" then
        raw = missing_presence_placeholder(expected)
    end
    strip_ocr_presence_extras(raw)
    if opts.spatial then
        strip_spatial_class_extras(raw, spatial_expected)
    end
    strip_unlinked_presence_extras(raw, expected, opts.catalog)
    if #zone.usable_zones(opts.zones) >= 2 then
        strip_settled_anchor_presence(raw, expected)
    end
    return raw
end

local function run_live_inspect(input)
    input = input or {}
    local expected = input.expected or {}
    local frames = input.frames or {}
    local opts = {
        presence = input.presence == true,
        spatial = input.spatial == true,
        layout = input.layout ~= false,
        frame_aspect = input.frame_aspect,
        accumulator_thresholds = input.accumulator_thresholds,
        validation_thresholds = input.validation_thresholds,
        presence_overlay = input.presence_overlay,
        catalog = input.catalog or {},
        zones = input.zones or {},
        completed_zone_ids = input.completed_zone_ids or {},
    }
    if #expected == 0 or #frames == 0 or (not opts.presence and not opts.spatial) then
        return {
            presence = nil,
            spatial = nil,
            transform = nil,
            zone_transforms = {},
            visible_zones = {},
            anchor = "not_required",
        }
    end
    if expected_has_ocr(expected) then
        frames = rewrite_frames(frames)
    end
    local spatial_expected = spatial_only_tree(expected)
    local presence = nil
    if opts.presence then
        presence = run_presence(expected, frames, opts, spatial_expected)
    end
    local spatial, transform, zone_transforms, visible_zones = nil, nil, {}, {}
    local anchor = "not_required"
    if opts.spatial then
        if #spatial_expected == 0 then
            return {
                presence = presence,
                spatial = nil,
                transform = nil,
                zone_transforms = {},
                visible_zones = {},
                anchor = anchor,
            }
        end
        local result, t, zt, vz, seen = run_spatial_window(spatial_expected, expected, frames, opts)
        if #zone.usable_zones(opts.zones) >= 2 then
            strip_settled_anchor_spatial(result)
        end
        spatial, transform = result, t
        zone_transforms, visible_zones = zt or {}, vz or {}
        if anchor_expected(spatial_expected, opts.zones) then
            if seen then
                anchor = "found"
            else
                anchor = "searching"
            end
        end
    end
    if anchor == "searching" then
        return {
            presence = nil,
            spatial = nil,
            transform = nil,
            zone_transforms = {},
            visible_zones = {},
            anchor = anchor,
        }
    end
    return {
        presence = presence,
        spatial = spatial,
        transform = transform,
        zone_transforms = zone_transforms,
        visible_zones = visible_zones,
        anchor = anchor,
    }
end

local function live(input)
    input = input or {}
    local op = input.op
    if op == "transform_agrees" then
        return { agrees = transform_agrees(input.a, input.b) and true or false }
    end
    if op == "consensus_transform" then
        return { transform = consensus_transform(input.transforms) }
    end
    if op == "fill" then
        return {
            detections = registered_for_spatial_validation(input.accumulated, input.frames),
        }
    end
    return run_live_inspect(input)
end

return live
