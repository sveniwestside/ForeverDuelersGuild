local _, FD = ...

-- One outbound scheduler for every addon prefix. Previously the rated duel,
-- the queue and zone discovery each paced and retried their own addon
-- messages with no shared budget, and a throttled send was either dropped or
-- treated as fatal. This module owns pacing, priorities, token budgets,
-- retry of transient failures and per-prefix traffic counters.
FD.Outbound = { lanes = { {}, {}, {} }, buckets = {}, routeUnavailable = {}, registered = {}, lastSend = -math.huge,
    whispered = {}, whisperedCount = 0, unreachableHandlers = {} }
local Outbound = FD.Outbound

Outbound.CONTROL, Outbound.QUEUE, Outbound.BACKGROUND = 1, 2, 3
local SPACING = 0.1
local LANE_LIMIT = { 48, 48, 30 }
local DEFAULT_TTL = 10
-- The client documents a per-prefix allowance for grouped/channel addon
-- messages (a burst of ten, then about one per second). Whispers use a
-- self-imposed budget shared by every prefix so this addon never becomes a
-- whisper flood that could delay the player's ordinary chat.
local BUCKETS = { group = { capacity = 10, refill = 1 }, WHISPER = { capacity = 8, refill = 1 } }
-- Background traffic leaves this many tokens for duel and queue control.
local BACKGROUND_RESERVE = 3
-- Whisper recipients are remembered this long (any prefix), so the server's
-- "No player named ..." line can be traced to an addon whisper.
local WHISPER_MEMORY, WHISPER_MEMORY_LIMIT = 10, 64

-- Pinned Forever SendAddonMessageResult values; names win when present.
local DEFAULT_CODES = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3,
    InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8,
    GeneralError = 9, NotInGuild = 10, AddOnMessageLockdown = 11, TargetOffline = 12 }

local function readable(...)
    if FD.Wow and FD.Wow.Readable then return FD.Wow:Readable(...) end
    return true
end

local function now()
    if type(GetTime) ~= "function" then return 0 end
    local ok, value = pcall(GetTime)
    return ok and readable(value) and type(value) == "number" and value or 0
end

local function count(prefix, channel, outcome, target)
    if FD.Debug and FD.Debug.Count then pcall(FD.Debug.Count, FD.Debug, prefix, channel, outcome, target) end
end

local function log(...)
    if FD.Debug and FD.Debug.Log then pcall(FD.Debug.Log, FD.Debug, ...) end
end

function Outbound:Code(name)
    local values = Enum and Enum.SendAddonMessageResult
    local value = values and values[name]
    if type(value) == "number" then return value end
    return DEFAULT_CODES[name]
end

function Outbound:CodeName(code)
    if code == nil then return "none" end
    local values = Enum and Enum.SendAddonMessageResult
    if values then
        for name, value in pairs(values) do if value == code then return name end end
    end
    for name, value in pairs(DEFAULT_CODES) do if value == code then return name end end
    return tostring(code)
end

-- Result classes: success, throttle (retry later), route (try WHISPER),
-- transient (bounded retry) and terminal (give up).
function Outbound:Classify(ok, result, channel)
    if not ok then return "terminal", "Lua error" end
    if not readable(result) then return "terminal", "restricted" end
    if result == true or result == self:Code("Success") then return "success", result end
    if result == nil then return "success", nil end -- Older clients returned nothing on success.
    if result == false then return "transient", result end
    if result == self:Code("AddonMessageThrottle") or result == self:Code("ChannelThrottle") then return "throttle", result end
    if channel ~= "WHISPER" and (result == self:Code("InvalidChatType") or result == self:Code("NotInGroup")) then
        return "route", result
    end
    if result == self:Code("GeneralError") or result == self:Code("AddOnMessageLockdown") then return "transient", result end
    return "terminal", result
end

function Outbound:Register(prefix)
    if type(prefix) ~= "string" or #prefix == 0 or #prefix > 16 then return false, "invalid prefix" end
    if self.registered[prefix] ~= nil then return self.registered[prefix] end
    if not C_ChatInfo or type(C_ChatInfo.RegisterAddonMessagePrefix) ~= "function" then
        return false, "addon messages unavailable"
    end
    local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, prefix)
    local values = Enum and Enum.RegisterAddonMessagePrefixResult
    local available = ok and readable(result) and values ~= nil
        and (result == values.Success or result == values.DuplicatePrefix) or false
    self.registered[prefix] = available
    log("addon prefix registration", prefix, ok and readable(result) and tostring(result) or "error",
        available and "available" or "unavailable")
    return available, ok and tostring(result) or "Lua error"
end

local function bucketKey(prefix, channel)
    return channel == "WHISPER" and "WHISPER" or prefix .. " " .. channel
end

function Outbound:Bucket(prefix, channel)
    local key = bucketKey(prefix, channel)
    local bucket = self.buckets[key]
    local spec = channel == "WHISPER" and BUCKETS.WHISPER or BUCKETS.group
    local at = now()
    if not bucket then
        bucket = { tokens = spec.capacity, at = at }
        self.buckets[key] = bucket
    end
    bucket.tokens = math.min(spec.capacity, bucket.tokens + math.max(0, at - bucket.at) * spec.refill)
    bucket.at = at
    return bucket, spec
end

local function required(item)
    return item.priority == Outbound.BACKGROUND and 1 + BACKGROUND_RESERVE or 1
end

local function validItem(item)
    return type(item) == "table" and type(item.prefix) == "string" and type(item.payload) == "string"
        and #item.payload > 0 and #item.payload <= 255 and type(item.channel) == "string"
        and ((item.channel ~= "WHISPER" and item.channel ~= "CHANNEL")
            or (type(item.target) == "string" and #item.target > 0))
end

-- item = { prefix, payload, channel = "WHISPER"|"PARTY", target, priority,
--   ttl, key, isCurrent = fn() -> bool, route = fn() -> channel, target,
--   onResult = fn(status, code) with status "sent"|"failed"|"expired"|"dropped",
--   noWhisperFallback = true }
function Outbound:Send(item)
    if not validItem(item) or not readable(item.payload, item.target, item.channel) then return false end
    if self.registered[item.prefix] == false then return false end
    local priority = item.priority == 1 and 1 or item.priority == 2 and 2 or 3
    item.priority = priority
    item.ttl = type(item.ttl) == "number" and item.ttl > 0 and item.ttl or DEFAULT_TTL
    item.queuedAt, item.attempts = now(), 0
    local lane = self.lanes[priority]
    if item.key then
        for index, queued in ipairs(lane) do
            if queued.key == item.key and queued.prefix == item.prefix then
                lane[index] = item
                self:Schedule(0)
                return true
            end
        end
    end
    if #lane >= LANE_LIMIT[priority] then
        count(item.prefix, item.channel, "dropped", item.target)
        return false
    end
    lane[#lane + 1] = item
    self:Schedule(math.max(0, SPACING - (now() - self.lastSend)))
    return true
end

-- A failing callback of a sending module is persisted, never silently lost.
local function report(context, err)
    if FD.Debug and FD.Debug.Error then pcall(FD.Debug.Error, FD.Debug, context, err) end
end

local function notify(item, status, code)
    if type(item.onResult) ~= "function" then return end
    local ok, err = pcall(item.onResult, status, code)
    if not ok then report("outbound callback", err) end
end

function Outbound:Resolve(item)
    local channel, target = item.channel, item.target
    if type(item.route) == "function" then
        local ok, routeChannel, routeTarget = pcall(item.route)
        if ok and type(routeChannel) == "string" then channel, target = routeChannel, routeTarget
        elseif not ok then report("outbound route", routeChannel) end
    end
    if item.forceWhisper or channel ~= "WHISPER" and self.routeUnavailable[channel] then
        if type(item.target) ~= "string" or item.noWhisperFallback then return nil end
        channel, target = "WHISPER", item.target
    end
    if (channel == "WHISPER" or channel == "CHANNEL") and (type(target) ~= "string" or target == "") then return nil end
    -- WHISPER needs the player name, CHANNEL the channel number as a string.
    return channel, (channel == "WHISPER" or channel == "CHANNEL") and target or nil
end

function Outbound:RememberWhisper(target)
    if self.whispered[target] == nil then
        if self.whisperedCount >= WHISPER_MEMORY_LIMIT then
            local at = now()
            for name, sent in pairs(self.whispered) do
                if at - sent >= WHISPER_MEMORY then self.whispered[name], self.whisperedCount = nil, self.whisperedCount - 1 end
            end
            if self.whisperedCount >= WHISPER_MEMORY_LIMIT then return end
        end
        self.whisperedCount = self.whisperedCount + 1
    end
    self.whispered[target] = now()
end

-- When this client last whispered `name` (any prefix), within `window` s.
function Outbound:Whispered(name, window)
    local at = self.whispered[name]
    if at and now() - at < (window or WHISPER_MEMORY) then return at end
end

-- handler(name) runs when the server reports a whispered player offline.
function Outbound:OnUnreachable(handler)
    if type(handler) == "function" then self.unreachableHandlers[#self.unreachableHandlers + 1] = handler end
end

-- The server reported `name` offline (TargetOffline, or its "No player named"
-- line for one of our whispers). Every module forgets the player, so neither
-- discovery nor the queue keeps whispering it; each such whisper would show
-- the player another system line.
function Outbound:Unreachable(name)
    if type(name) ~= "string" or not readable(name) then return end
    log("outbound", "unreachable whisper target")
    self:Drop(function(item) return item.channel == "WHISPER" and item.target == name end)
    for _, handler in ipairs(self.unreachableHandlers) do pcall(handler, name) end
end

-- Submit one item to the native API now. Returns class, code.
function Outbound:Submit(item, channel, target, ignoreBudget)
    local bucket = self:Bucket(item.prefix, channel)
    if not C_ChatInfo or type(C_ChatInfo.SendAddonMessage) ~= "function" then return "terminal", "unavailable" end
    count(item.prefix, channel, "submitted", target or channel)
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, item.prefix, item.payload, channel, target)
    local class, code = self:Classify(ok, result, channel)
    self.lastSend = now()
    self.lastResult = { prefix = item.prefix, channel = channel, class = class, code = self:CodeName(code), at = self.lastSend }
    if class == "success" then
        bucket.tokens = math.max(0, bucket.tokens - 1)
        count(item.prefix, channel, "success", target)
        if channel == "WHISPER" then self:RememberWhisper(target) end
    elseif class == "throttle" then
        bucket.tokens = 0
        count(item.prefix, channel, "throttled", target)
    else
        count(item.prefix, channel, "failed", target)
        if class == "route" and code == self:Code("InvalidChatType") then self.routeUnavailable[channel] = true end
        -- After the caller has settled this item: Unreachable drops queued items.
        if channel == "WHISPER" and code == self:Code("TargetOffline") and C_Timer and type(C_Timer.After) == "function" then
            C_Timer.After(0, function() self:Unreachable(target) end)
        end
    end
    if not ignoreBudget and class ~= "success" then
        log("outbound", item.prefix, channel, class, self:CodeName(code))
    end
    return class, code
end

-- Synchronous submission for terminal packets during logout, reload or a
-- party leave. It bypasses pacing and the queue but still records traffic.
function Outbound:SendNow(item)
    if not validItem(item) or not readable(item.payload, item.target, item.channel) then return "invalid" end
    local channel, target = self:Resolve(item)
    if not channel then return "dropped" end
    local class, code = self:Submit(item, channel, target, true)
    if class == "route" and type(item.target) == "string" and not item.noWhisperFallback then
        class, code = self:Submit(item, "WHISPER", item.target, true)
    end
    local status = class == "success" and "sent" or "failed"
    notify(item, status, code)
    return status, code
end

function Outbound:Pending(predicate)
    local total = 0
    for _, lane in ipairs(self.lanes) do
        for _, item in ipairs(lane) do
            if not predicate or predicate(item) then total = total + 1 end
        end
    end
    return total
end

-- Remove queued items, e.g. everything for a finished match.
function Outbound:Drop(predicate)
    for _, lane in ipairs(self.lanes) do
        for index = #lane, 1, -1 do
            local item = lane[index]
            if predicate(item) then
                table.remove(lane, index)
                count(item.prefix, item.channel, "dropped", item.target)
                notify(item, "dropped")
            end
        end
    end
end

function Outbound:Schedule(delay)
    if not C_Timer or type(C_Timer.After) ~= "function" then return end
    delay = math.max(0.01, delay or SPACING)
    local target = now() + delay
    if self.wakeAt and self.wakeAt <= target + 0.0001 then return end
    self.wakeAt = target
    C_Timer.After(delay, function()
        if self.wakeAt ~= target then return end
        self.wakeAt = nil
        local ok, err = pcall(self.Pump, self)
        if not ok then
            if FD.Debug and FD.Debug.Error then pcall(FD.Debug.Error, FD.Debug, "outbound", err) end
            self:Schedule(1)
        end
    end)
end

-- Choose and submit at most one item, then reschedule.
function Outbound:Pump()
    local at = now()
    -- Small tolerance: timer and clock arithmetic is not exact.
    if at - self.lastSend < SPACING - 0.001 then return self:Schedule(SPACING - (at - self.lastSend)) end
    local soonest
    for _, lane in ipairs(self.lanes) do
        local index = 1
        while index <= #lane do
            local item = lane[index]
            local current = true
            if type(item.isCurrent) == "function" then
                local ok, value = pcall(item.isCurrent)
                current = ok and value == true
                if not ok then report("outbound isCurrent", value) end
            end
            if not current then
                table.remove(lane, index)
                count(item.prefix, item.channel, "dropped", item.target)
                notify(item, "dropped")
            elseif at - item.queuedAt >= item.ttl then
                table.remove(lane, index)
                count(item.prefix, item.channel, "expired", item.target)
                log("outbound", item.prefix, item.channel, "expired")
                notify(item, "expired")
            elseif item.retryAt and at < item.retryAt then
                soonest = math.min(soonest or math.huge, item.retryAt - at)
                index = index + 1
            else
                local channel, target = self:Resolve(item)
                if not channel then
                    table.remove(lane, index)
                    count(item.prefix, item.channel, "dropped", item.target)
                    notify(item, "dropped")
                else
                    local bucket, spec = self:Bucket(item.prefix, channel)
                    local need = required(item)
                    if bucket.tokens + 0.0001 < need then
                        soonest = math.min(soonest or math.huge, (need - bucket.tokens) / spec.refill)
                        index = index + 1
                    else
                        local class, code = self:Submit(item, channel, target)
                        item.attempts = item.attempts + 1
                        if class == "success" then
                            table.remove(lane, index)
                            notify(item, "sent", code)
                        elseif class == "throttle" or class == "transient" and item.attempts < 3 then
                            item.retryAt = at + math.min(8, 2 ^ item.attempts)
                        elseif class == "route" and not item.forceWhisper and type(item.target) == "string"
                            and not item.noWhisperFallback then
                            item.forceWhisper = true
                        else
                            table.remove(lane, index)
                            notify(item, "failed", code)
                        end
                        if self:Pending() > 0 then self:Schedule(SPACING) end
                        return
                    end
                end
            end
        end
    end
    if soonest then self:Schedule(math.max(SPACING, soonest)) end
end
