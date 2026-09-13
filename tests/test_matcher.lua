-- Exercises `matcher.lua` (needs `normalisator` in scope).

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
normalisator = dofile(script_dir .. "../lua/normalisator.lua")
local matcher = dofile(script_dir .. "../lua/matcher.lua")
local t = dofile(script_dir .. "asserts.lua")

local function run(input)
    return json.decode(json.encode(matcher(input)))
end

t.eq(run({ hay = "ABC", needle = "Abc" }).matched, true, "caps")
t.eq(run({ hay = "АвС", needle = "ABc" }).matched, true, "cyrillic hay vs latin needle")
t.eq(run({ hay = "A B C", needle = "abc" }).matched, true, "ghost spaces")
t.eq(run({ hay = "59364-7206143-1-4363", needle = "7206143" }).matched, true, "inside longer")
t.eq(run({ hay = "ABC", needle = "ABD" }).matched, false, "no match")
t.eq(run({ hay = "AB", needle = "ABC" }).matched, false, "expected not inside short hay")
t.eq(run({ hay = "HELLO", needle = "" }).matched, false, "empty needle")

local split = run({ found = { "A", "B", "C" }, expected = "Abc" })
t.eq(split.matched, true, "split letters concat")
t.eq(split.from, 1, "split from")
t.eq(split.to, 3, "split to")

local mid = run({ found = { "X", "A", "B", "C", "Y" }, expected = "ABC" })
t.eq(mid.matched, true, "span in the middle")
t.eq(mid.from, 2, "mid from")
t.eq(mid.to, 4, "mid to")

local one = run({ found = { "xxABCyy", "P06" }, expected = "abc" })
t.eq(one.matched, true, "single hay hit")
t.eq(one.index, 1, "index of containing string")

if not t.summary("matcher") then
    os.exit(1)
end
