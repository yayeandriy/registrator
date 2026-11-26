-- `verdict.lines` through the composed session host, as hosts call it.

local script_dir = (arg[0]):match("(.*/)")
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(script_dir .. "../lua/json.lua")
local host = dofile(script_dir .. "compose.lua").load("session")

local objects = {
    { id = "p", routines = { "presence_validate" } },
    { id = "s", routines = { "spatial_validate" } },
    { id = "b", routines = { "presence_validate", "spatial_validate" } },
    { id = "n", routines = {} },
}

local function lines(rows)
    local out = json.decode(host(json.encode({
        module = "verdict", op = "lines", args = { rows = rows, objects = objects },
    })))
    return out.lines
end

local got = lines({
    { object_id = "p", status = "matched" },
    { object_id = "s", status = "pending" },
    { object_id = "b", status = "missing" },
    { object_id = "n", status = "misrotated" },
    { status = "extra" },
    { object_id = "gone", status = "brand_new" },
    { label = "d" },
})
local function field(name)
    local out = {}
    for i, line in ipairs(got) do
        out[i] = line[name]
    end
    return table.concat(out, ",")
end
t.eq(field("outcome"), "pass,pending,fail,fail,fail,fail,pending",
    "matched passes, pending or no status waits, the rest fails")
t.eq(field("routine"), "presence,spatial,both,presence,extra,presence,presence",
    "listed under the object's routines; neither, unknown or none is Presence; extras apart")
t.eq(#lines({}), 0, "no rows, no lines")

if not t.summary("verdict_lines") then
    os.exit(1)
end
