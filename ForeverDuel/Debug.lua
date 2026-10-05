local _, FD = ...
FD.Debug = {}
local TRACE_LIMIT = 64
local traced = { ["outgoing request"] = true, ["incoming native name"] = true,
    ["incoming identity check stopped"] = true, ["duel detected"] = true,
    ["state"] = true, ["transport send"] = true, ["transport receive"] = true,
    ["peer validation"] = true, ["transport ingress"] = true,
    ["transport sender mismatch"] = true, ["addon prefix registration"] = true,
    ["queue state"] = true, ["queue group"] = true, ["queue planning"] = true,
    ["UI_INFO_MESSAGE"] = true, ["UI_ERROR_MESSAGE"] = true }

-- Small local request summaries survive reload even when chat debug is off.
-- They contain no queue positions, tickets, consent or result evidence.
function FD.Debug:Record(topic, ...)
    local db = FD.Database and FD.Database.data
    local readable = FD.Wow and FD.Wow.Readable
    if readable and not readable(FD.Wow, topic) then return end
    if not db or not db.settings or type(topic) ~= "string" or not traced[topic] then return end
    local parts = {}
    -- Retain descriptive state/detection arguments, never negotiation IDs.
    local count = select("#", ...)
    if topic == "state" then count = math.min(count, 3)
    elseif topic == "queue state" then count = math.min(count, 4)
    elseif topic == "queue group" or topic == "queue planning" then count = math.min(count, 2)
    elseif topic == "duel detected" then count = math.min(count, 2) end
    for i = 1, count do
        local value = select(i, ...)
        if readable and not readable(FD.Wow, value) then return end
        local kind = type(value)
        if kind == "string" or kind == "number" or kind == "boolean" or kind == "nil" then
            parts[#parts + 1] = tostring(value)
        end
    end
    local entry = { event = topic, detail = table.concat(parts, " "):sub(1, 320), version = FD.C.VERSION }
    if type(GetServerTime) == "function" then
        local value = GetServerTime()
        if (not readable or readable(FD.Wow, value)) and type(value) == "number"
            and value == value and value >= 0 and value < math.huge then entry.at = math.floor(value) end
    end
    local trace = db.settings.requestDiagnostics
    if type(trace) ~= "table" then trace = {}; db.settings.requestDiagnostics = trace end
    -- Repeated waiting/idle traffic must not evict the request and its first
    -- validation. Keep the first timestamp and summarize short repetitions.
    local interval = (topic == "peer validation" or topic == "transport ingress"
        or topic == "queue group" or topic == "queue planning") and 10
        or (topic == "transport send" or topic == "transport receive") and 5 or nil
    if interval and entry.at then
        for i = #trace, 1, -1 do
            local previous = trace[i]
            if previous.event == "duel detected" or previous.event == "state" or previous.event == "queue state"
                or previous.event == "outgoing request" or previous.event == "incoming native name" then break end
            if previous.event == topic then
                if previous.version == entry.version and previous.detail == entry.detail
                    and type(previous.at) == "number" and entry.at >= previous.at
                    and entry.at - previous.at < interval then
                    previous.lastAt = entry.at
                    previous.repeats = math.min((previous.repeats or 0) + 1, 1000000)
                    return
                end
                -- Transport kinds can alternate (HELLO/ACK); collect identical
                -- short repetitions across them. A changed validation remains
                -- a new observation, preserving the guard transition.
                if topic == "peer validation" or topic == "transport ingress"
                    or topic == "queue group" or topic == "queue planning" then break end
            end
        end
    end
    trace[#trace + 1] = entry
    while #trace > TRACE_LIMIT do table.remove(trace, 1) end
end

function FD.Debug:RequestTrace(count)
    local db = FD.Database and FD.Database.data
    local trace = db and db.settings and db.settings.requestDiagnostics
    if type(trace) ~= "table" then return {} end
    local result = {}
    for index = math.max(1, #trace - (count or 12) + 1), #trace do
        local entry = trace[index]
        if type(entry) == "table" and type(entry.event) == "string" and type(entry.detail) == "string" then
            result[#result + 1] = FD.Copy(entry)
        end
    end
    return result
end

function FD.Debug:Print(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd8bb68[ForeverDuelersGuild]|r " .. tostring(text))
    end
end

function FD.Debug:Log(...)
    pcall(self.Record, self, ...)
    local db = FD.Database and FD.Database.data
    if not (db and db.settings.debug) then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    self:Print(table.concat(parts, " "))
end
