-- Exercises `ocr_window.text_reads`: which text reads Presence scores.

local script_dir = (arg[0]):match("(.*/)")
local ocr_window = dofile(script_dir .. "../lua/ocr_window.lua")
local t = dofile(script_dir .. "asserts.lua")

local function ocr(label)
    return { label = label, kind = "ocr", x = 0, y = 0, width = 0.1, height = 0.1 }
end

local function labels(reads)
    local out = {}
    for _, d in ipairs(reads) do
        out[#out + 1] = d.label
    end
    return table.concat(out, ",")
end

local needles = { "crab", "7937" }
local now = { ocr("7937"), { label = "crab", kind = "yolo" } }
local frames = {
    { detections = { ocr("crab 7937"), ocr("noise") } },
    { detections = { ocr("7937") } },
}

local frame = ocr_window.text_reads({ mode = "frame", reads = now, frames = frames, needles = needles })
t.eq(labels(frame.reads), "7937,crab", "frame: this tick's reads only")
t.eq(#frame.pool, 0, "frame: nothing kept")

local window = ocr_window.text_reads({ mode = "window", reads = now, frames = frames, needles = needles })
t.eq(labels(window.reads), "7937,crab,crab 7937", "window: expected text from earlier frames joins")

local first = ocr_window.text_reads({
    mode = "view",
    reads = { ocr("crab 7937") },
    pool = {},
    needles = needles,
})
t.eq(labels(first.pool), "crab 7937", "view: an expected read is kept")
local later = ocr_window.text_reads({ mode = "view", reads = now, pool = first.pool, needles = needles })
t.eq(labels(later.reads), "7937,crab,crab 7937", "view: a kept read still counts")
t.eq(labels(later.pool), "7937,crab 7937", "view: kept reads grow, no duplicates")
local again = ocr_window.text_reads({ mode = "view", reads = { ocr("CRAB 7937") }, pool = later.pool, needles = needles })
t.eq(labels(again.reads), "CRAB 7937,7937", "view: a read of the same text stands for the kept one")

if not t.summary("ocr_window") then
    os.exit(1)
end
