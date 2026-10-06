-- Zoned inspect: each closed zone is one view of a board that does not
-- fit the frame. A zone is scored once, while fully visible, and the
-- session verdict keeps every zone.
--
-- Ops (`{ op = "<name>", ... }`):
--
--   latch   { holds = { ZoneHold }, visible = { Visible }, verdict = Verdict }
--     -> { holds }
--   compose { zone_ids = { "<object id>" } (profile order),
--             live = Verdict, holds = { ZoneHold }, visible = { Visible } }
--     -> { verdict = Verdict, zones = { { object_id, matched, total, pending } } }
--
-- ZoneHold = { object_id, pass, rows = { Row } }
-- Visible  = { object_id, member_ids = { "<object id>" } }
-- Verdict / Row: see `verdict.lua`.

local zones = {}

local function set_of(list)
    local s = {}
    for _, v in ipairs(list or {}) do
        s[v] = true
    end
    return s
end

local function held_ids(holds)
    local s = {}
    for _, h in ipairs(holds or {}) do
        s[h.object_id] = true
    end
    return s
end

local function recount(rows)
    local matched, total, incorrect, missing, extra = 0, 0, 0, 0, 0
    for _, r in ipairs(rows) do
        if r.status == "extra" then
            extra = extra + 1
        else
            total = total + 1
            if r.status == "matched" then
                matched = matched + 1
            elseif r.status == "missing" then
                missing = missing + 1
            else
                incorrect = incorrect + 1
            end
        end
    end
    return matched, total, incorrect, missing, extra
end

local function member_rows(rows, members)
    local out = {}
    for _, r in ipairs(rows or {}) do
        if r.object_id ~= nil and members[r.object_id] then
            out[#out + 1] = r
        end
    end
    return out
end

-- Every member matched and nothing left over.
local function passed(rows)
    for _, r in ipairs(rows) do
        if r.status ~= "matched" then
            return false
        end
    end
    return true
end

function zones.latch(input)
    local holds = {}
    for _, h in ipairs(input.holds or {}) do
        holds[#holds + 1] = h
    end
    local already = held_ids(holds)
    local fresh = {}
    for _, z in ipairs(input.visible or {}) do
        if not already[z.object_id] then
            fresh[#fresh + 1] = z
        end
    end
    if #fresh == 0 then
        return { holds = holds }
    end
    local held_extras = {}
    for _, h in ipairs(holds) do
        for _, r in ipairs(h.rows or {}) do
            if r.status == "extra" then
                held_extras[r.label] = true
            end
        end
    end
    local live_rows = (input.verdict or {}).rows or {}
    for i, z in ipairs(fresh) do
        local rows = member_rows(live_rows, set_of(z.member_ids))
        -- Surplus belongs to the first zone that sees it, once.
        if i == 1 then
            for _, r in ipairs(live_rows) do
                if r.status == "extra" and not held_extras[r.label] then
                    rows[#rows + 1] = r
                end
            end
        end
        holds[#holds + 1] = { object_id = z.object_id, pass = passed(rows), rows = rows }
    end
    return { holds = holds }
end

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do
        out[k] = v
    end
    return out
end

function zones.compose(input)
    local holds, live = input.holds or {}, input.live or {}
    local held = held_ids(holds)
    local fresh, members = {}, {}
    for _, z in ipairs(input.visible or {}) do
        if not held[z.object_id] then
            fresh[#fresh + 1] = z
            for _, id in ipairs(z.member_ids or {}) do
                members[id] = true
            end
        end
    end
    local rows = {}
    for _, h in ipairs(holds) do
        for _, r in ipairs(h.rows or {}) do
            rows[#rows + 1] = r
        end
    end
    if #fresh > 0 then
        for _, r in ipairs(live.rows or {}) do
            if r.status == "extra" then
                rows[#rows + 1] = r
            end
        end
        for _, r in ipairs(live.rows or {}) do
            if r.status ~= "extra" and r.object_id ~= nil and members[r.object_id] then
                rows[#rows + 1] = r
            end
        end
    end
    local matched, total, incorrect, missing, extra = recount(rows)
    local zone_ids = input.zone_ids or {}
    local n_held = 0
    for _ in pairs(held) do
        n_held = n_held + 1
    end
    local all_held = #zone_ids > 0 and n_held >= #zone_ids
    local pass = all_held and extra == 0 and incorrect == 0 and missing == 0 and matched == total
    local out = copy(live)
    out.rows = rows
    out.matched, out.total, out.incorrect, out.missing, out.extra = matched, total, incorrect, missing, extra
    out.complete = pass
    out.no_expectations = false
    out.awaiting_anchor = false
    out.anchor_missing = false
    -- "scoring" stays publishable; "pending" is held back by the settle gate.
    if not all_held then
        out.result = "scoring"
    elseif pass then
        out.result = "pass"
    else
        out.result = "fail"
    end
    local chips = {}
    for _, id in ipairs(zone_ids) do
        local chip = { object_id = id, matched = 0, total = 0, pending = true }
        for _, h in ipairs(holds) do
            if h.object_id == id then
                chip.matched, chip.total = recount(h.rows or {})
                chip.pending = false
                break
            end
        end
        if chip.pending then
            for _, z in ipairs(input.visible or {}) do
                if z.object_id == id then
                    chip.matched, chip.total = recount(member_rows(live.rows, set_of(z.member_ids)))
                    chip.pending = false
                end
            end
        end
        chips[#chips + 1] = chip
    end
    return { verdict = out, zones = chips }
end

return zones
