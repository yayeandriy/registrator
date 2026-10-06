-- Compose live.lua the same way the Rust host does: wrap library
-- scripts as locals (no `require`).

local function read(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

local function wrap(name, path)
    return "local " .. name .. " = (function()\n" .. read(path) .. "\nend)()\n"
end

return function(root)
    return table.concat({
        wrap("class_match", root .. "lua/class_match.lua"),
        wrap("normalisator", root .. "lua/normalisator.lua"),
        wrap("matcher", root .. "lua/matcher.lua"),
        wrap("registration", root .. "lua/registration.lua"),
        wrap("validation", root .. "lua/validation.lua"),
        wrap("layout", root .. "lua/layout.lua"),
        wrap("ruller", root .. "lua/ruller.lua"),
        wrap("presence_validator", root .. "lua/presence_validator.lua"),
        wrap("accumulator", root .. "lua/accumulator.lua"),
        wrap("zone", root .. "lua/zone.lua"),
        read(root .. "lua/live_strip.lua"),
        read(root .. "lua/live_spatial.lua"),
        read(root .. "lua/live_window.lua"),
        read(root .. "lua/live_zoned.lua"),
        read(root .. "lua/live.lua"),
    })
end
