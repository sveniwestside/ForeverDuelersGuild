local _, FD = ...
FD.Debug = {}
local Debug = FD.Debug

-- Persisted diagnostics are split into separate bounded rings so that noisy
-- transport traffic can never evict the lifecycle evidence of a failed match.
-- Nothing here contains packet payloads, nonces, queue tickets or positions,
-- and nothing here can supply consent, results or ratings.
local RING_LIMIT, ERROR_LIMIT = 64, 10
local rings = { lifecycle = "requestDiagnostics", transport = "transportDiagnostics" }
local routes = {
    -- Lifecycle: what the duel and queue state machines decided, and why.
    ["outgoing request"] = "lifecycle", ["incoming native name"] = "lifecycle",
    ["incoming identity check stopped"] = "lifecycle", ["duel detected"] = "lifecycle",
    ["state"] = "lifecycle", ["peer validation"] = "lifecycle", ["unrated"] = "lifecycle",
    ["cancel received"] = "lifecycle", ["session"] = "lifecycle", ["error"] = "lifecycle",
    ["queue state"] = "lifecycle", ["queue group"] = "lifecycle", ["queue planning"] = "lifecycle",
    ["queue cancel"] = "lifecycle", ["queue invite"] = "lifecycle", ["queue venue"] = "lifecycle",
    ["addon prefix registration"] = "lifecycle", ["version mismatch"] = "lifecycle",
    ["UI_INFO_MESSAGE"] = "lifecycle", ["UI_ERROR_MESSAGE"] = "lifecycle",
    -- Transport: individual submissions and receipts, plus latency probes.
    ["transport send"] = "transport", ["transport receive"] = "transport",
    ["transport ingress"] = "transport", ["transport sender mismatch"] = "transport",
    ["transport rejected"] = "transport", ["queue send"] = "transport", ["queue receive"] = "transport",
    ["zone send"] = "transport", ["zone receive"] = "transport", ["ping"] = "transport",
    ["outbound"] = "transport",
}
-- Arguments retained per topic. Later arguments may carry negotiation IDs.
local argumentLimits = { ["state"] = 3, ["queue state"] = 4, ["queue group"] = 2,
    ["queue planning"] = 2, ["duel detected"] = 2, ["queue cancel"] = 4 }
-- Repeated identical waiting/idle entries are summarized instead of appended.
local repeatIntervals = { ["peer validation"] = 10, ["transport ingress"] = 10, ["queue group"] = 10,
    ["queue planning"] = 10, ["transport send"] = 5, ["transport receive"] = 5,
    ["queue send"] = 5, ["queue receive"] = 5, ["zone send"] = 10, ["zone receive"] = 10, ["outbound"] = 10 }
-- Entries that start a new episode; compaction never reaches across them.
local boundaries = { ["duel detected"] = true, ["state"] = true, ["queue state"] = true,
    ["outgoing request"] = true, ["incoming native name"] = true, ["session"] = true }

local function readable(...)
    if FD.Wow and FD.Wow.Readable then return FD.Wow:Readable(...) end
    for i = 1, select("#", ...) do
        if type(issecretvalue) == "function" and issecretvalue(select(i, ...)) then return false end
    end
    return true
end

local function settings()
    local db = FD.Database and FD.Database.data
    return db and type(db.settings) == "table" and db.settings or nil
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function serverTime()
    if type(GetServerTime) ~= "function" then return nil end
    local ok, value = pcall(GetServerTime)
    if ok and readable(value) and finite(value) and value >= 0 then return math.floor(value) end
end

local function clientTime()
    if type(GetTime) ~= "function" then return nil end
    local ok, value = pcall(GetTime)
    if ok and readable(value) and finite(value) and value >= 0 then return math.floor(value * 1000 + 0.5) / 1000 end
end

local function ring(s, name)
    local key = rings[name]
    local trace = s[key]
    if type(trace) ~= "table" then trace = {}; s[key] = trace end
    return trace
end

local function nextSequence(s)
    local value = type(s.diagnosticsSequence) == "number" and s.diagnosticsSequence or 0
    value = value >= 2147483647 and 1 or value + 1
    s.diagnosticsSequence = value
    return value
end

-- Native UI notices are recorded only for duel-related message IDs. Spell and
-- combat errors flooded the old shared trace and evicted the match evidence.
local function relevantNotice(topic, ...)
    if topic ~= "UI_INFO_MESSAGE" and topic ~= "UI_ERROR_MESSAGE" then return true end
    local stringID = select(2, ...)
    return type(stringID) == "string" and stringID:match("^ERR_DUEL") ~= nil
end

-- Version plus the installed commit when tools/install-addon.ps1 stamped it.
function Debug:Version()
    return FD.C.BUILD and (FD.C.VERSION .. "+" .. FD.C.BUILD) or FD.C.VERSION
end

function Debug:Record(topic, ...)
    if not readable(topic) or type(topic) ~= "string" then return end
    local route = routes[topic]
    local s = settings()
    if not route or not s or not relevantNotice(topic, ...) then return end
    local parts = {}
    local count = select("#", ...)
    if argumentLimits[topic] then count = math.min(count, argumentLimits[topic]) end
    for i = 1, count do
        local value = select(i, ...)
        if not readable(value) then return end
        local kind = type(value)
        if kind == "string" or kind == "boolean" or kind == "nil" then parts[#parts + 1] = tostring(value)
        elseif kind == "number" then parts[#parts + 1] = finite(value) and tostring(value) or "nonfinite" end
    end
    local entry = { event = topic, detail = table.concat(parts, " "):sub(1, 320), version = Debug:Version(),
        at = serverTime(), t = clientTime() }
    local trace = ring(s, route)
    local interval = repeatIntervals[topic]
    if interval and entry.at then
        for i = #trace, 1, -1 do
            local previous = trace[i]
            -- An episode boundary recorded in any ring ends compaction, so a
            -- receipt after a state change remains a separate observation.
            if boundaries[previous.event] or (previous.seq or 0) < (s.diagnosticsBoundary or 0) then break end
            if previous.event == topic then
                if previous.version == entry.version and previous.detail == entry.detail
                    and type(previous.at) == "number" and entry.at >= previous.at
                    and entry.at - previous.at < interval then
                    previous.lastAt, previous.lastT = entry.at, entry.t
                    previous.repeats = math.min((previous.repeats or 0) + 1, 1000000)
                    return
                end
                -- A changed validation is a new observation and stays visible.
                if route == "lifecycle" then break end
            end
        end
    end
    entry.seq = nextSequence(s)
    if boundaries[topic] then s.diagnosticsBoundary = entry.seq end
    trace[#trace + 1] = entry
    while #trace > RING_LIMIT do table.remove(trace, 1) end
end

local function collect(s, names)
    local merged = {}
    for _, name in ipairs(names) do
        local trace = s[rings[name]]
        if type(trace) == "table" then
            for _, entry in ipairs(trace) do
                if type(entry) == "table" and type(entry.event) == "string" and type(entry.detail) == "string" then
                    merged[#merged + 1] = entry
                end
            end
        end
    end
    -- Entries written before sequence numbers existed keep their saved order.
    for index, entry in ipairs(merged) do entry._order = index end
    table.sort(merged, function(a, b)
        local sa, sb = a.seq or 0, b.seq or 0
        if sa ~= sb then return sa < sb end
        return a._order < b._order
    end)
    return merged
end

-- Recent persisted entries in chronological order. `which` is "lifecycle",
-- "transport" or nil for both rings merged.
function Debug:RequestTrace(count, which)
    local s = settings()
    if not s then return {} end
    local names = which and rings[which] and { which } or { "lifecycle", "transport" }
    local merged = collect(s, names)
    local result = {}
    for index = math.max(1, #merged - (count or 12) + 1), #merged do
        local copy = FD.Copy and FD.Copy(merged[index]) or merged[index]
        if type(copy) == "table" then copy._order = nil; result[#result + 1] = copy end
    end
    for _, entry in ipairs(merged) do entry._order = nil end
    return result
end

local function stackText()
    if type(debugstack) == "function" then
        local ok, value = pcall(debugstack, 3, 6, 0)
        if ok and type(value) == "string" then return value end
    end
    if type(debug) == "table" and type(debug.traceback) == "function" then
        local ok, value = pcall(debug.traceback, "", 3)
        if ok and type(value) == "string" then return value end
    end
end

-- Lua errors are always persisted, independently of chat debug. Players can
-- report `/duelrating errors` instead of a generic "technical" cancellation.
function Debug:Error(context, message, stack)
    local s = settings()
    local text = readable(message) and tostring(message) or "restricted error"
    context = readable(context) and type(context) == "string" and context or "unknown"
    stack = readable(stack) and type(stack) == "string" and stack or stackText()
    if s then
        local errors = s.errorDiagnostics
        if type(errors) ~= "table" then errors = {}; s.errorDiagnostics = errors end
        local last = errors[#errors]
        if last and last.context == context and last.message == text:sub(1, 400) and last.version == self:Version() then
            last.repeats = math.min((last.repeats or 0) + 1, 1000000)
            last.lastAt = serverTime()
        else
            errors[#errors + 1] = { context = context:sub(1, 64), message = text:sub(1, 400),
                stack = stack and stack:gsub("[|]", "/"):sub(1, 900) or nil,
                version = self:Version(), at = serverTime(), t = clientTime() }
            while #errors > ERROR_LIMIT do table.remove(errors, 1) end
        end
    end
    pcall(self.Record, self, "error", context, text:sub(1, 200))
    self.errorCount = (self.errorCount or 0) + 1
    if not self.errorNoticeShown then
        self.errorNoticeShown = true
        pcall(self.Print, self, FD.L and FD.L["An addon error was recorded. Type /duelrating errors for details."]
            or "An addon error was recorded. Type /duelrating errors for details.")
    end
end

function Debug:Errors(count)
    local s = settings()
    local errors = s and s.errorDiagnostics
    if type(errors) ~= "table" then return {} end
    local result = {}
    for index = math.max(1, #errors - (count or ERROR_LIMIT) + 1), #errors do
        local copy = FD.Copy and FD.Copy(errors[index]) or errors[index]
        if type(copy) == "table" then result[#result + 1] = copy end
    end
    return result
end

function Debug:ClearErrors()
    local s = settings()
    if s then s.errorDiagnostics = {} end
    self.errorNoticeShown = nil
end

-- Traffic counters: per prefix and channel, totals plus a rolling 60-second
-- window with unique recipients. They make "was this client flooding addon
-- whispers?" answerable from the next live trace. Outcomes: submitted,
-- success, throttled, failed, dropped, expired.
Debug.traffic = Debug.traffic or {}

local function window(now)
    return math.floor((now or 0) / 60)
end

function Debug:Count(prefix, channel, outcome, target)
    if type(prefix) ~= "string" or type(channel) ~= "string" or type(outcome) ~= "string" then return end
    local now = clientTime() or 0
    local key = prefix .. " " .. channel
    local entry = self.traffic[key]
    if not entry then
        entry = { prefix = prefix, channel = channel, totals = {}, minute = window(now), current = {}, recipients = {}, previous = nil }
        self.traffic[key] = entry
    end
    if entry.minute ~= window(now) then
        local uniques = 0
        for _ in pairs(entry.recipients) do uniques = uniques + 1 end
        entry.previous = { minute = entry.minute, counts = entry.current, recipients = uniques }
        entry.minute, entry.current, entry.recipients = window(now), {}, {}
    end
    entry.totals[outcome] = (entry.totals[outcome] or 0) + 1
    entry.current[outcome] = (entry.current[outcome] or 0) + 1
    if outcome == "submitted" and type(target) == "string" and readable(target) then entry.recipients[target] = true end
    local s = settings()
    if s then
        local saved = s.trafficCounters
        if type(saved) ~= "table" then saved = {}; s.trafficCounters = saved end
        local persisted = saved[key] or { totals = {} }
        saved[key] = persisted
        persisted.totals[outcome] = (persisted.totals[outcome] or 0) + 1
        persisted.version, persisted.lastAt = self:Version(), serverTime()
        if entry.previous then
            persisted.lastMinute = { counts = FD.Copy and FD.Copy(entry.previous.counts) or entry.previous.counts,
                recipients = entry.previous.recipients }
        end
    end
end

local outcomeOrder = { "submitted", "success", "throttled", "failed", "dropped", "expired" }

local function describe(counts)
    local parts = {}
    for _, outcome in ipairs(outcomeOrder) do
        if counts and counts[outcome] then parts[#parts + 1] = outcome .. " " .. counts[outcome] end
    end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

-- Human-readable traffic lines for status/diagnose output.
function Debug:TrafficLines()
    local lines, keys = {}, {}
    for key in pairs(self.traffic) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local entry = self.traffic[key]
        local uniques = 0
        for _ in pairs(entry.recipients) do uniques = uniques + 1 end
        lines[#lines + 1] = string.format("%s | this minute: %s (%d recipients) | session: %s",
            key, describe(entry.current), uniques, describe(entry.totals))
    end
    return lines
end

function Debug:Session(isInitialLogin, isReloadingUi)
    local kind = isInitialLogin == true and "login" or isReloadingUi == true and "reload" or "world transition"
    self:Record("session", kind)
end

function Debug:Print(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd8bb68[ForeverDuelersGuild]|r " .. tostring(text))
    end
end

function Debug:Log(...)
    pcall(self.Record, self, ...)
    local s = settings()
    if not (s and s.debug) then return end
    local parts = {}
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        parts[i] = readable(value) and tostring(value) or "restricted"
    end
    self:Print(table.concat(parts, " "))
end
