-- Exercises `accumulator.lua` across the JSON boundary — see
-- `test_registration.lua`'s header comment for why. Covers the blink
-- filter (a real object dropping out of a few frames should still be
-- accepted) and the noise filter (a one-off false positive should be
-- dropped), matching the "Accumulator" behavior the Lua header comment
-- describes.

local script_dir = (arg[0]):match("(.*/)")
local json = dofile(script_dir .. "../lua/json.lua")
local accumulator = dofile(script_dir .. "../lua/accumulator.lua")
local t = dofile(script_dir .. "asserts.lua")

local function read_file(path)
    local f = assert(io.open(path, "r"))
    local contents = f:read("*a")
    f:close()
    return contents
end

-- accumulator_basic.json: 8 frames; "connector" present in 6/8 (0.75
-- ratio, blinking out twice) should be accepted and smoothed; "noise"
-- present in only 1/8 (0.125 ratio) should be dropped as a stray false
-- positive under the default 0.25 min_presence_ratio.
local raw = read_file(script_dir .. "fixtures/accumulator_basic.json")
local input = json.decode(raw)
local result = json.decode(json.encode(accumulator(input)))

t.eq(result.total_frames, 8, "basic: total_frames")
t.eq(result.accepted, 1, "basic: accepted clusters")
t.eq(result.dropped, 1, "basic: dropped clusters")
t.eq(#result.detections, 1, "basic: one surviving detection")

local connector = result.detections[1]
t.eq(connector.label, "connector", "basic: surviving detection is the connector")
t.eq(connector.presence, 6, "basic: connector presence count")
t.close(connector.presence_ratio, 0.75, 1e-9, "basic: connector presence_ratio")
-- Confidence-weighted mean of x across its 6 appearances (0.40, 0.41,
-- 0.40, 0.41, 0.40, 0.40) — all equal confidence, so a plain mean.
t.close(connector.x, (0.40 + 0.41 + 0.40 + 0.41 + 0.40 + 0.40) / 6.0, 1e-9, "basic: connector smoothed x")

-- A custom, stricter min_presence_ratio should drop even the connector
-- cluster once its ratio (0.75) is still above it — sanity-check the
-- threshold really is admin-tunable end to end, not just defaulted.
local strict_result = (function()
    local strict_input = { frames = input.frames, thresholds = { min_presence_ratio = 0.9 } }
    return json.decode(json.encode(accumulator(strict_input)))
end)()
t.eq(strict_result.accepted, 0, "strict threshold: nothing survives a 0.9 min_presence_ratio")
t.eq(strict_result.dropped, 2, "strict threshold: both clusters dropped")

if not t.summary("accumulator") then
    os.exit(1)
end
