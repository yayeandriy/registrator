-- Spatial tree prepare: drop presence-only nodes, ensure a tip.
--
-- Input: { op = "spatial_branch"|"ensure_spatial_anchor"|"prepare", objects = { ... } }
-- Output: { objects = { ... } }

local SPATIAL = "spatial_validate"

local function has_spatial(o)
    for _, r in ipairs(o.routines or {}) do
        if r == SPATIAL then
            return true
        end
    end
    return false
end

local function copy_obj(o)
    local c = {}
    for k, v in pairs(o) do
        c[k] = v
    end
    return c
end

local function spatial_branch(objects)
    local out = {}
    for _, object in ipairs(objects or {}) do
        local kids = spatial_branch(object.children)
        if has_spatial(object) then
            local copy = copy_obj(object)
            copy.children = kids
            out[#out + 1] = copy
        else
            for _, kid in ipairs(kids) do
                out[#out + 1] = kid
            end
        end
    end
    return out
end

local function has_any_anchor(objects)
    for _, o in ipairs(objects or {}) do
        if o.is_anchor or has_any_anchor(o.children) then
            return true
        end
    end
    return false
end

local function walk_pick(objects, best)
    for _, object in ipairs(objects or {}) do
        local spatial = has_spatial(object)
        local b = object.boundary or {}
        local area = math.abs(b.width or 0) * math.abs(b.height or 0)
        local take = best.id == nil
        if not take then
            if spatial ~= best.spatial then
                take = spatial
            else
                take = area > best.area
            end
        end
        if take then
            best.id = object.id
            best.area = area
            best.spatial = spatial
        end
        walk_pick(object.children, best)
    end
end

local function set_anchor(objects, id)
    for _, object in ipairs(objects or {}) do
        if tostring(object.id) == tostring(id) then
            object.is_anchor = true
            return true
        end
        if set_anchor(object.children, id) then
            return true
        end
    end
    return false
end

local function ensure_spatial_anchor(objects)
    if has_any_anchor(objects) then
        return objects
    end
    local best = {}
    walk_pick(objects, best)
    if best.id ~= nil then
        set_anchor(objects, best.id)
    end
    return objects
end

local function deep_copy_tree(objects)
    local out = {}
    for _, o in ipairs(objects or {}) do
        local copy = copy_obj(o)
        copy.children = deep_copy_tree(o.children)
        if o.boundary then
            local b = {}
            for k, v in pairs(o.boundary) do
                b[k] = v
            end
            copy.boundary = b
        end
        out[#out + 1] = copy
    end
    return out
end

local function prepare(objects)
    local spatial = spatial_branch(objects)
    if #spatial == 0 then
        spatial = deep_copy_tree(objects)
    end
    return ensure_spatial_anchor(spatial)
end

local function run(input)
    input = input or {}
    local objects = deep_copy_tree(input.objects or {})
    local op = input.op or "prepare"
    if op == "spatial_branch" then
        return { objects = spatial_branch(objects) }
    elseif op == "ensure_spatial_anchor" then
        return { objects = ensure_spatial_anchor(objects) }
    end
    return { objects = prepare(objects) }
end

return run
