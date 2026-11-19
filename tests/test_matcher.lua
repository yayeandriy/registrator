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
t.eq(run({ hay = "PO6", needle = "P06" }).matched, true, "letter O read for zero")
t.eq(run({ hay = "РО6", needle = "P06" }).matched, true, "cyrillic O read for zero")
t.eq(run({ hay = "X04", needle = "XO4" }).matched, true, "zero read for letter O")
t.eq(run({ hay = "AI2-S7B", needle = "A125-78" }).matched, true, "I S B read for 1 5 8")
t.eq(run({ hay = "1 PO6", needle = "P06" }).matched, true, "folded inside longer")
t.eq(run({ hay = "PQ6", needle = "P06" }).matched, false, "other letters still differ")

local split = run({ found = { "A", "B", "C" }, expected = "Abc" })
t.eq(split.matched, true, "split letters concat")
t.eq(split.from, 1, "split from")
t.eq(split.to, 3, "split to")

t.eq(run({ hay = "90d", needle = "P06" }).matched, true, "a code read upside down")
t.eq(run({ hay = "90a", needle = "P06" }).matched, false, "upside down, a wrong letter still differs")
t.eq(run({ hay = "40X", needle = "X04" }).matched, false, "a code with a character that has no turned form")
t.eq(run({ found = { "9", "0d" }, expected = "P06" }).matched, true, "upside down across split reads")

local function split(label, needles, extra)
    local dets = { { label = label, kind = "ocr", confidence = 0.9, x = 0.2, y = 0.1, width = 0.6, height = 0.05 } }
    if extra then
        dets[2] = extra
    end
    return run({ detections = dets, needles = needles }).detections
end

local joint = split("X04 P06", { "X04", "P06" })
t.eq(#joint, 2, "a joint read becomes one read per code")
t.eq(joint[1].label .. "|" .. joint[2].label, "X04|P06", "each piece reads its code")
t.eq(joint[1].read, "X04 P06", "a piece keeps the text read")
t.close(joint[1].x, 0.2, 1e-9, "the first code takes the left half")
t.close(joint[1].width, 0.3, 1e-9, "the first code's width")
t.close(joint[2].x, 0.5, 1e-9, "the second code takes the right half")
t.eq(#split("X04P06PO6", { "P06" }), 2, "a code read twice becomes two reads, lookalikes folded")
local crossed = split("1×04 P06", { "X04", "P06" })
t.eq(#crossed, 2, "a code read with a multiplication sign for X still splits out")
local turned = split("90d 1", { "P06" })
t.eq(turned[1].label, "P06", "an upside-down read splits out its code")
t.close(turned[1].x, 0.2 + 0.6 / 4, 1e-9, "upside down, the code sits from the right edge")
t.close(turned[1].width, 0.6 * 3 / 4, 1e-9, "upside down, the code's width")
local partial = split("1 P06", { "P06" })
t.eq(#partial, 1, "noise around one code leaves one read")
t.close(partial[1].x, 0.2 + 0.6 / 4, 1e-9, "the code's share of a read with noise")
local whole = split("P06", { "P06", "X04" })
t.eq(whole[1].read, nil, "a read that is exactly one code is kept as read")
t.eq(#split("99193-361819", { "P06" }), 1, "a read without a code passes")
local yolo = { label = "X04P06", kind = "yolo", x = 0, y = 0, width = 1, height = 1 }
t.eq(#split("Z", { "X04", "P06" }, yolo), 2, "class detections are not split")

local folded = run({ found = { "X", "P", "O", "6" }, expected = "P06" })
t.eq(folded.matched, true, "split letters folded")
t.eq(folded.from, 2, "folded from")
t.eq(folded.to, 4, "folded to")

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
