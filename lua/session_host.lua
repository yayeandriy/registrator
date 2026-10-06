-- Host entry for the live-session ops, so the Rust (mlua) and Swift
-- (C Lua) hosts share one contract and never re-declare the shapes.
--
-- Needs, in scope and in this order: `json`, `normalisator`,
-- `ocr_window`, `inspect_view`, `verdict`, `session`, `session_zones`,
-- `session_extras`, `session_view`, `report_rules`, `report_catalog`,
-- `report_zones`, `report`. The host concatenates them ahead of this file.
--
-- Input:  { module = "verdict"|"session"|"zones"|"ocr"|"extras"|"view"|"report",
--           op = "<name>", args = { ... } }
--         as JSON text (Rust) or as the table `LuaVM` already decoded (Swift).
-- Output: the op's result — JSON text for text input, a table otherwise.

local modules = {
    verdict = verdict,
    session = session,
    zones = session_zones,
    ocr = ocr_window,
    extras = session_extras,
    view = session_view,
    report = report,
}

-- Any `json.lua` instance decodes `null` to its own empty sentinel whose
-- `tostring` is "null"; ops expect a plain `nil`.
local function is_null(v)
    return type(v) == "table" and next(v) == nil and getmetatable(v) ~= nil and tostring(v) == "null"
end

local function scrub(v)
    if is_null(v) then
        return nil
    end
    if type(v) == "table" then
        for k, x in pairs(v) do
            v[k] = scrub(x)
        end
    end
    return v
end

local function dispatch(input)
    input = scrub(input) or {}
    local mod = modules[input.module]
    if mod == nil then
        error("unknown session module: " .. tostring(input.module))
    end
    local fn = mod[input.op]
    if type(fn) ~= "function" then
        error("unknown session op: " .. tostring(input.module) .. "." .. tostring(input.op))
    end
    return fn(input.args or {})
end

return function(input)
    if type(input) == "string" then
        return json.encode(dispatch(json.decode(input)))
    end
    return dispatch(input)
end
