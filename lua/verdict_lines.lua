-- Where each verdict row is listed: its outcome, and the routine it sits
-- under. Hosts group and word the lines; these decide which group.
--
--   verdict.lines { rows = { Row }, objects = { { id, routines } } }
--     -> { lines = { { outcome = "pass"|"pending"|"fail",
--                      routine = "presence"|"spatial"|"both"|"extra" } } }
--
-- `lines` is aligned with `rows`. Matched passes, pending waits, any other
-- status (extra and unknown spellings too) fails. An extra row is listed
-- as extra; another row under its object's routines, Presence when the
-- object runs neither or is not in `objects`.

local lines = {}

local PRESENCE = "presence_validate"
local SPATIAL = "spatial_validate"

local function outcome(status)
    if status == "matched" then
        return "pass"
    elseif status == "pending" or status == nil or status == "" then
        return "pending"
    end
    return "fail"
end

local function routines_by_id(objects)
    local by_id = {}
    for _, object in ipairs(objects or {}) do
        local runs = {}
        for _, routine in ipairs(object.routines or {}) do
            runs[routine] = true
        end
        by_id[object.id] = runs
    end
    return by_id
end

local function routine(row, by_id)
    if row.status == "extra" then
        return "extra"
    end
    local runs = (row.object_id and by_id[row.object_id]) or {}
    if runs[SPATIAL] and runs[PRESENCE] then
        return "both"
    elseif runs[SPATIAL] then
        return "spatial"
    end
    return "presence"
end

function lines.lines(input)
    local by_id = routines_by_id(input.objects)
    local out = {}
    for i, row in ipairs(input.rows or {}) do
        out[i] = { outcome = outcome(row.status), routine = routine(row, by_id) }
    end
    return { lines = out }
end

return lines
