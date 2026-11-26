-- Host entry for the live-session ops, so the Rust (mlua) and Swift
-- (C Lua) hosts share one contract and never re-declare the shapes.
--
-- Needs, in scope and in order, every `wrap` module of the `session`
-- bundle in `bundles.json`; the host concatenates them ahead of this file.
--
-- Input:  { module = "verdict"|"session"|"zones"|"ocr"|"extras"|"view"|"report"|"populate"|"detect",
--           op = "<name>", args = { ... } }
--         as JSON text (Rust) or as the table `LuaVM` already decoded (Swift).
-- Output: the op's result — JSON text for text input, a table otherwise.
--
-- `keep = { "<arg>", … }` beside `module`: those args are not sent; the
-- op gets what it returned under those names last time in this VM (absent
-- the first time), and they are kept here instead of returned. A failed op
-- keeps what was kept before. Hosts that call one VM for a whole run use
-- it for the run's opaque `state` and `window`.

session.reads, session.tick, session.finish = session_run.reads, session_run.tick, session_run.finish
session.stop_run, session.rescan_run = session_run.stop_run, session_run.rescan_run

local modules = {
    verdict = verdict,
    session = session,
    zones = session_zones,
    ocr = ocr_window,
    extras = session_extras,
    view = session_view,
    report = report,
    populate = populate,
    detect = detect,
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

local function copy(v)
    if type(v) ~= "table" then
        return v
    end
    local out = {}
    for k, x in pairs(v) do
        out[k] = copy(x)
    end
    return setmetatable(out, getmetatable(v))
end

local kept = {}

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
    local args = input.args or {}
    local keep = input.keep or {}
    for _, name in ipairs(keep) do
        args[name] = copy(kept[name])
    end
    local out = fn(args)
    for _, name in ipairs(keep) do
        kept[name] = out[name]
        out[name] = nil
    end
    return out
end

return function(input)
    if type(input) == "string" then
        return json.encode(dispatch(json.decode(input)))
    end
    return dispatch(input)
end
