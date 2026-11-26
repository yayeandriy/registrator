-- `zones.latch_rows`: a part matched on the still on camera stays matched.

local script_dir = (arg[0]):match("(.*/)")
local lua_dir = script_dir .. "../lua/"
local t = dofile(script_dir .. "asserts.lua")
local json = dofile(lua_dir .. "json.lua")

local host = dofile(script_dir .. "compose.lua").load("session")

local function latch(v, latched)
    return json.decode(host(json.encode({
        module = "zones",
        op = "latch_rows",
        args = { verdict = v, latched = latched or {} },
    })))
end

local function row(id, status, extra)
    local r = { object_id = id, label = id, status = status }
    for k, v in pairs(extra or {}) do
        r[k] = v
    end
    return r
end

local function verdict(rows, extra)
    local matched, missing, incorrect = 0, 0, 0
    local total = 0
    for _, r in ipairs(rows) do
        if r.status ~= "extra" then
            total = total + 1
            if r.status == "matched" then
                matched = matched + 1
            elseif r.status == "missing" then
                missing = missing + 1
            elseif r.status ~= "pending" then
                incorrect = incorrect + 1
            end
        end
    end
    local complete = matched == total and (extra or 0) == 0
    return {
        result = complete and "pass" or "fail",
        matched = matched, total = total, incorrect = incorrect, missing = missing,
        extra = extra or 0, complete = complete, no_expectations = false, rows = rows,
    }
end

local green = latch(verdict({
    row("x04", "matched", { matched_label = "X04" }),
    row("p06", "matched", { matched_label = "P06" }),
    row("serial", "matched"),
}))
t.eq(green.verdict.result, "pass", "an all-green tick passes")
t.eq(#green.latched, 3, "every matched part is latched")

local moved = latch(verdict({
    row("x04", "missing", { lacks = { { label = "X04", kind = "text", why = "unseen" } } }),
    row("p06", "missing"),
    row("serial", "missing"),
}), green.latched)
t.eq(moved.verdict.result, "pass", "a picture that lost every part keeps the pass")
t.eq(moved.verdict.complete, true, "the kept pass is complete")
t.eq(moved.verdict.matched, 3, "every kept part counts as matched")
t.eq(moved.verdict.missing, 0, "no kept part counts as missing")
t.eq(moved.verdict.rows[1].matched_label, "X04", "the kept row shows what matched it")
t.eq(moved.verdict.rows[1].lacks, nil, "a kept row lists nothing it lacks")

local partial = latch(verdict({
    row("x04", "missing"),
    row("p06", "matched"),
    row("serial", "missing"),
}))
local later = latch(verdict({
    row("x04", "matched"),
    row("p06", "misrotated"),
    row("serial", "pending"),
}), partial.latched)
t.eq(later.verdict.rows[2].status, "matched", "a pose fail after a match keeps the match")
t.eq(later.verdict.result, "pending", "unsettled text with no miss stays pending")
t.eq(#later.latched, 2, "parts matched on different pictures add up")

local last = latch(verdict({
    row("x04", "missing"),
    row("p06", "missing"),
    row("serial", "matched"),
}), later.latched)
t.eq(last.verdict.result, "pass", "parts matched on different pictures pass together")

local surplus = latch(verdict({
    row("x04", "missing"),
    row("p06", "missing"),
    row("serial", "missing"),
    { label = "bolt", status = "extra" },
}, 1), last.latched)
t.eq(surplus.verdict.result, "fail", "surplus still fails a kept pass")
t.eq(surplus.verdict.rows[4].status, "extra", "surplus is never latched")

local none = latch(nil, last.latched)
t.eq(none.verdict, nil, "no verdict passes through")
t.eq(#none.latched, 3, "the latch survives a tick with nothing scored")

if not t.summary("row_latch") then
    os.exit(1)
end
