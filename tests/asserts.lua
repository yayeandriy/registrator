-- Tiny shared assertion helpers for this repo's own test suite — kept
-- dependency-free (no busted/luaunit) so `lua5.4 tests/run_all.lua` is
-- the entire toolchain needed to verify these scripts in isolation, on
-- any machine that can run plain Lua, independent of either host
-- (Rust/mlua, or the future Swift/C-Lua harness) ever being built.

local M = {}

M.passed = 0
M.failed = 0

local function report(ok, label)
    if ok then
        M.passed = M.passed + 1
    else
        M.failed = M.failed + 1
        print("FAIL: " .. label)
    end
end

function M.ok(cond, label)
    report(cond, label)
end

function M.eq(actual, expected, label)
    report(actual == expected, label .. string.format(" (expected %s, got %s)", tostring(expected), tostring(actual)))
end

function M.close(actual, expected, tolerance, label)
    tolerance = tolerance or 1e-6
    local diff = math.abs(actual - expected)
    report(diff <= tolerance, label .. string.format(" (expected %s +/- %s, got %s, diff %s)", tostring(expected), tostring(tolerance), tostring(actual), tostring(diff)))
end

function M.is_nil(value, label)
    report(value == nil, label .. " (expected nil, got " .. tostring(value) .. ")")
end

function M.not_nil(value, label)
    report(value ~= nil, label .. " (expected non-nil)")
end

function M.summary(suite_name)
    print(string.format("[%s] %d passed, %d failed", suite_name, M.passed, M.failed))
    return M.failed == 0
end

return M
