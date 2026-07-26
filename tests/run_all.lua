-- Runs every `test_*.lua` file in this directory and exits non-zero if
-- any of them failed — the one command this repo's CI (and anyone
-- checking out just this repo, with no Rust/Swift toolchain at all)
-- needs: `lua5.4 tests/run_all.lua`.

local script_dir = (arg[0]):match("(.*/)") or "./"
local suites = { "test_registration.lua", "test_validation.lua", "test_accumulator.lua", "test_presence_validator.lua" }

local any_failed = false
for _, suite in ipairs(suites) do
    print("=== " .. suite .. " ===")
    local ok, err = pcall(function()
        -- Run each suite in its own process so one suite's `os.exit`
        -- (on failure, from its own `t.summary` check) doesn't abort the
        -- rest — `dofile` alone would call it straight into this
        -- process. `popen` keeps this file dependency-free (no busted's
        -- process isolation needed) while still getting a full summary
        -- across every suite in one run.
        local handle = io.popen("lua5.4 " .. script_dir .. suite .. " 2>&1")
        local output = handle:read("*a")
        local success = handle:close()
        io.write(output)
        if not success then
            any_failed = true
        end
    end)
    if not ok then
        print("ERROR running " .. suite .. ": " .. tostring(err))
        any_failed = true
    end
end

if any_failed then
    print("\nSOME SUITES FAILED")
    os.exit(1)
else
    print("\nALL SUITES PASSED")
end
