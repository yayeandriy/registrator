-- `report.summary` through the composed session host, as hosts call it.

local script_dir = (arg[0]):match("(.*/)")
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(script_dir .. "../lua/json.lua")
local host = dofile(script_dir .. "compose.lua").load("session")

local function summary(results)
    return json.decode(host(json.encode({ module = "report", op = "summary", args = { results = results } })))
end

local none = summary({})
t.eq(none.result, "pending", "no inspections is not a pass")
t.eq(none.passed, 0, "no passes counted")
t.eq(none.failed, 0, "no fails counted")

local all = summary({ "pass", "pass" })
t.eq(all.result, "pass", "every inspection passed")
t.eq(all.passed, 2, "both passes counted")

local one_failed = summary({ "pass", "pass", "fail" })
t.eq(one_failed.result, "fail", "one failed inspection fails the report")
t.eq(one_failed.passed, 2, "the passes still count")
t.eq(one_failed.failed, 1, "the fail counts")

local open = summary({ "pending" })
t.eq(open.result, "pending", "an unfinished inspection leaves it open")
t.eq(summary({ "pass", "scoring" }).result, "pending", "a scoring one keeps it open")
t.eq(summary({ "fail", "pending" }).result, "fail", "a fail beats an open one")

if not t.summary("report_runs") then
    os.exit(1)
end
