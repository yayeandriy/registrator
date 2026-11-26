-- Shared setup for the `test_presence_*` suites: the composed
-- `presence_validator` run across the JSON boundary.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
local presence_validator = dofile(script_dir .. "compose.lua").load("presence_validator")

local helpers = {}

helpers.VISION = "2353bf0c-1d76-4d4d-a6ee-aa7287d725c0"

function helpers.find_object(objects, id, match_kind)
    for _, o in ipairs(objects) do
        if o.id == id and (match_kind == nil or o.match_kind == match_kind) then
            return o
        end
    end
    return nil
end

function helpers.run(input)
    return json.decode(json.encode(presence_validator(input)))
end

return helpers
