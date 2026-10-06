-- Compose `session_host.lua` the way both hosts do: each script wrapped
-- as a local, in dependency order, the host last. Returns the host fn.

local function read(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

local LIBS = {
    { "json", "json.lua" },
    { "normalisator", "normalisator.lua" },
    { "ocr_window", "ocr_window.lua" },
    { "inspect_view", "inspect_view.lua" },
    { "verdict", "verdict.lua" },
    { "session", "session.lua" },
    { "session_zones", "session_zones.lua" },
    { "session_extras", "session_extras.lua" },
    { "session_view", "session_view.lua" },
    { "report_rules", "report_rules.lua" },
    { "report_catalog", "report_catalog.lua" },
    { "report_zones", "report_zones.lua" },
    { "report", "report.lua" },
}

return function(lua_dir)
    local parts = {}
    for _, lib in ipairs(LIBS) do
        parts[#parts + 1] = "local " .. lib[1] .. " = (function()\n" .. read(lua_dir .. lib[2]) .. "\nend)()\n"
    end
    parts[#parts + 1] = read(lua_dir .. "session_host.lua")
    return assert(load(table.concat(parts), "session_host"))()
end
