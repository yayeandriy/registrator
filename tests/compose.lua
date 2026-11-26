-- Composes a bundle from `lua/bundles.json` exactly as the hosts do:
-- each `wrap` module as a local, then the `inline` files (no `require`).

local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local lua_dir = here .. "../lua/"

local function read(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

local json = dofile(lua_dir .. "json.lua")
local bundles = json.decode(read(lua_dir .. "bundles.json"))

local compose = {}

function compose.source(name)
    local bundle = bundles[name]
    if bundle == nil then
        error("compose: unknown bundle " .. tostring(name))
    end
    local parts = {}
    for _, module in ipairs(bundle.wrap) do
        parts[#parts + 1] = "local " .. module .. " = (function()\n" .. read(lua_dir .. module .. ".lua") .. "\nend)()\n"
    end
    for _, module in ipairs(bundle.inline) do
        parts[#parts + 1] = read(lua_dir .. module .. ".lua") .. "\n"
    end
    return table.concat(parts)
end

function compose.load(name)
    return assert(load(compose.source(name), name))()
end

return compose
