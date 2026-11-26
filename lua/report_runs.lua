-- How a report's inspections went together.
--
--   report.summary { results = { "pass"|"fail"|"pending"|"scoring" } }
--     -> { result = "pass"|"fail"|"pending", passed, failed }
--
-- Failed once any inspection failed; passed when there is one and every
-- one passed; pending otherwise. `passed` / `failed` count the results so.

local runs = {}

function runs.summary(input)
    local results = input.results or {}
    local passed, failed = 0, 0
    for _, result in ipairs(results) do
        if result == "pass" then
            passed = passed + 1
        elseif result == "fail" then
            failed = failed + 1
        end
    end
    local result = "pending"
    if failed > 0 then
        result = "fail"
    elseif #results > 0 and passed == #results then
        result = "pass"
    end
    return { result = result, passed = passed, failed = failed }
end

return runs
