-- Exercises `normalisator.lua` across the JSON boundary.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
local normalisator = dofile(script_dir .. "../lua/normalisator.lua")
local t = dofile(script_dir .. "asserts.lua")

local function run(input)
    return json.decode(json.encode(normalisator(input)))
end

t.eq(run({ value = "Abc" }).value, "ABC", "caps")
t.eq(run({ value = "A B C" }).value, "ABC", "ghost spaces")
t.eq(run({ value = "  a  b   c  " }).value, "ABC", "collapse + trim")
t.eq(run({ value = "P-06" }).value, "P06", "punctuation")
t.eq(run({ value = "59364-7206143-1-4363" }).value, "59364720614314363", "stamp dashes")
t.eq(run({ value = "ABC" }).value, "ABC", "idempotent")
t.eq(run({ value = "АвС" }).value, "ABC", "always english: cyrillic")
t.eq(run({ value = "ABc" }).value, "ABC", "latin needle form")
t.eq(run({ value = "ＡＢＣ" }).value, "ABC", "always english: fullwidth")
t.eq(run({ value = "" }).value, "", "empty")
t.eq(run({ value = "  -  " }).value, "", "punctuation only")

local nbsp = "A" .. string.char(194, 160) .. "B"
t.eq(run({ value = nbsp }).value, "AB", "nbsp ghost space")

local values = run({ values = { "a b c", "p-06", "blocklock" } }).values
t.eq(values[1], "ABC", "values[1]")
t.eq(values[2], "P06", "values[2]")
t.eq(values[3], "BLOCKLOCK", "values[3] letters only")

local dets = run({
    detections = {
        { label = "blocklock", kind = "yolo", x = 0.1, y = 0.1, width = 0.2, height = 0.2 },
        { label = "a b c", kind = "ocr", x = 0.4, y = 0.4, width = 0.1, height = 0.1 },
        { label = "P06", kind = "ocr:stamp", x = 0.5, y = 0.5, width = 0.1, height = 0.1 },
    },
}).detections
t.eq(dets[1].label, "blocklock", "yolo label untouched")
t.eq(dets[2].label, "ABC", "ocr label normalised")
t.eq(dets[3].label, "P06", "ocr: prefix still ocr")

local frames = run({
    frames = {
        {
            t = 0,
            detections = {
                { label = "  sn - 42  ", kind = "ocr" },
            },
        },
    },
}).frames
t.eq(frames[1].detections[1].label, "SN42", "frame ocr")

if not t.summary("normalisator") then
    os.exit(1)
end
