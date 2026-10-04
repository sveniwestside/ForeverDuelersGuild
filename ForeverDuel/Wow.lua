local _, FD = ...
FD.Wow = {}
local Wow = FD.Wow

function Wow:Readable(...)
    for i = 1, select("#", ...) do
        if issecretvalue and issecretvalue(select(i, ...)) then return false end
    end
    return true
end

function Wow:MaxLevel()
    if type(GetMaxPlayerLevel) ~= "function" then return nil end
    local ok, value = pcall(GetMaxPlayerLevel)
    if ok and self:Readable(value) and type(value) == "number" and value >= 1
        and value <= 255 and value % 1 == 0 then return value end
end

function Wow:Identity(unit, own)
    local guid = UnitGUID(unit)
    local name, realm = UnitFullName(unit)
    local className, classFile = UnitClass(unit)
    if not self:Readable(guid, name, realm, className, classFile) then return nil end
    if not FD.Protocol:ValidGUID(guid) or type(name) ~= "string" or name == "" or not classFile then return nil end
    local regionalNames = RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled()
    if not self:Readable(regionalNames) then return nil end
    local fullName, requestName, requestFullName, nameFormat
    if regionalNames then
        -- Forever's second name component is a surname, not a realm. Its
        -- native helper supplies the exact whisper name, including separator.
        if not UnitNameUnmodified or not NameUtil or not NameUtil.GetUnmodifiedUnitFullName then return nil end
        local first, surname = UnitNameUnmodified(unit)
        if not self:Readable(first, surname) or type(first) ~= "string" or first == "" then return nil end
        if surname ~= nil and type(surname) ~= "string" then return nil end
        fullName = NameUtil.GetUnmodifiedUnitFullName(unit)
        if not self:Readable(fullName) or type(fullName) ~= "string" or fullName == "" then return nil end
        -- Retain locally observed unit-name forms for the native duel event
        -- only. They never qualify an addon sender or a winner message.
        requestName = name
        requestFullName = type(realm) == "string" and realm ~= "" and name .. "-" .. realm or name
        name, realm, nameFormat = fullName, GetNormalizedRealmName(), "surname"
    else
        realm = realm and realm ~= "" and realm or GetNormalizedRealmName()
        if not self:Readable(realm) or type(realm) ~= "string" or realm == "" then return nil end
        fullName = name .. "-" .. realm
    end
    if not self:Readable(realm) or type(realm) ~= "string" or realm == "" then return nil end
    local identity = { guid = guid, name = name, realm = realm,
        fullName = fullName, nameFormat = nameFormat, requestName = requestName,
        requestFullName = requestFullName, className = className, classFile = classFile }
    local maxLevel = self:MaxLevel()
    local level
    if type(UnitLevel) == "function" then level = UnitLevel(unit) end
    -- Unknown/skull/restricted levels retain ordinary-duel identity but can
    -- never qualify for rated consent. Do not infer levels from peer packets.
    if self:Readable(level) and type(level) == "number" and maxLevel
        and level >= 1 and level <= maxLevel and level % 1 == 0 then
        identity.level, identity.maxLevel = level, maxLevel
    end
    if own and C_SpecializationInfo then
        local index = C_SpecializationInfo.GetSpecialization()
        if self:Readable(index) and index then
            local specId, specName = C_SpecializationInfo.GetSpecializationInfo(index)
            if self:Readable(specId, specName) then
                identity.specId, identity.specName, identity.specSource = specId, specName, "self-api"
            end
        end
    end
    return identity
end

function Wow:ResolveIncoming(requestName)
    if not self:Readable(requestName) or type(requestName) ~= "string" then return nil end
    local units = { "target", "mouseover", "focus" }
    for i = 1, 4 do units[#units + 1] = "party" .. i end
    for i = 1, 40 do
        units[#units + 1] = "raid" .. i
        units[#units + 1] = "nameplate" .. i
    end
    local found
    for _, unit in ipairs(units) do
        local candidate = self:Identity(unit)
        if candidate and (requestName == candidate.fullName or requestName == candidate.name
            or requestName == candidate.requestName or requestName == candidate.requestFullName) then
            if found and found.guid ~= candidate.guid then return nil, "ambiguous" end
            found = candidate
        end
    end
    return found
end

function Wow:OutgoingStatus(status)
    self.outgoingStatus, self.outgoingAt = status, GetTime()
    FD.Debug:Log("outgoing request", status)
end

function Wow:ClearOutgoing(reason, nativeEnded)
    local pending = self.outgoing or self.outgoingBlockedUntil
    local deadline = math.max(self.outgoingBlockedUntil or 0,
        self.outgoing and self.outgoing.at + FD.C.PRESENCE_TIMEOUT or 0)
    self.outgoing = nil
    -- A local cancel/accept call does not prove that an older unqualified
    -- request acknowledgment cannot still arrive. Keep its ambiguity window.
    self.outgoingBlockedUntil = not nativeEnded and deadline > GetTime() and deadline or nil
    if self.outgoingBlockedUntil then reason = reason .. " | waiting for prior acknowledgment window" end
    if pending then self:OutgoingStatus(reason) end
end

function Wow:CaptureOutgoing(unit)
    self:ClearIncoming("new outgoing request")
    self.incomingStatus = nil
    if not FD.duel then return end
    if not self:Readable(unit) then self:OutgoingStatus("requested unit unavailable"); return end
    if InCombatLockdown() then self:OutgoingStatus("combat; rated detection unavailable"); return end
    -- A StartDuel post-hook is only an attempt. Require the subsequent server
    -- system acknowledgement before enabling presence/consent on this side.
    -- Never substitute the current target for an unresolved requested unit.
    if self.outgoing or (self.outgoingBlockedUntil and GetTime() < self.outgoingBlockedUntil) then
        self.outgoing = nil
        self.outgoingBlockedUntil = GetTime() + FD.C.PRESENCE_TIMEOUT
        FD.duel:Abort("overlapping outgoing attempts", true)
        self:OutgoingStatus("overlapping attempts; waiting for a new unambiguous request")
        return
    end
    local candidate = self:Identity(unit)
    if not candidate then self.outgoing = nil; self:OutgoingStatus("native unit identity unavailable"); return end
    self.outgoing = { opponent = candidate, at = GetTime() }
    self:OutgoingStatus(candidate.fullName .. " | waiting for native acknowledgment")
    local captured = self.outgoing
    C_Timer.After(FD.C.PRESENCE_TIMEOUT, function()
        if self.outgoing == captured then
            self.outgoing = nil
            self:OutgoingStatus(captured.opponent.fullName .. " | expired without native acknowledgment")
        end
    end)
end

function Wow:ClearIncoming(reason)
    if not self.pendingIncoming then return end
    self.pendingIncoming = nil
    self.incomingStatus = reason
    FD.Debug:Log("incoming identity check stopped", reason)
end

function Wow:TryIncoming(pending, checkPopup)
    if self.pendingIncoming ~= pending then return end
    if InCombatLockdown() then return self:ClearIncoming("combat; native duel retained") end
    if GetTime() - pending.at >= FD.C.PENDING_TIMEOUT then
        return self:ClearIncoming("request expired; native duel retained")
    end
    if checkPopup then
        -- The initial event may run before Blizzard shows its dialog. Later
        -- attempts need positive evidence that the request is still open.
        if type(StaticPopup_Visible) ~= "function" then
            return self:ClearIncoming("popup visibility unavailable; native duel retained")
        end
        local visible = StaticPopup_Visible("DUEL_REQUESTED")
        if not self:Readable(visible) or not visible then
            return self:ClearIncoming("native request dialog closed")
        end
    end
    local opponent, reason = self:ResolveIncoming(pending.name)
    if reason == "ambiguous" then return self:ClearIncoming("ambiguous native identity; native duel retained") end
    local player = self:Identity("player", true)
    if opponent and player then
        self.pendingIncoming = nil
        self.incomingStatus = "native identity resolved"
        FD.duel:Begin("INCOMING", player, opponent, pending.at)
    end
end

function Wow:RetryIncoming(pending)
    C_Timer.After(FD.C.INCOMING_RETRY_INTERVAL, function()
        FD:Safe(function()
            if self.pendingIncoming ~= pending then return end
            self:TryIncoming(pending, true)
            if self.pendingIncoming == pending then self:RetryIncoming(pending) end
        end)
    end)
end

function Wow:Incoming(name)
    if not FD.duel then return end
    self:ClearIncoming("replaced by a new incoming request")
    self:ClearOutgoing("incoming request replaced outgoing attempt", true)
    self.outgoingStatus, self.outgoingAt = nil, nil
    FD.duel:Abort("incoming request", true)
    if InCombatLockdown() then self.incomingStatus = "combat; native duel retained"; return end
    if not self:Readable(name) or type(name) ~= "string" or name == "" then
        self.incomingStatus = "request name unavailable; native duel retained"
        return
    end
    FD.Debug:Log("incoming native name", name)
    local pending = { name = name, at = GetTime() }
    self.pendingIncoming = pending
    self.incomingStatus = "waiting for native player identity; target the challenger"
    self:TryIncoming(pending, false)
    if self.pendingIncoming == pending then
        FD.Debug:Print("Rated duel pending: target the challenger so ForeverDuelersGuild can verify their identity.")
        self:RetryIncoming(pending)
    end
end

-- Native informational notifications can be routed separately from chat. Only
-- the exact localized pending-request/cancel messages are accepted here; UI
-- notices never supply countdown or winner evidence.
function Wow:DuelNotice(message, source)
    if not self:Readable(message) or type(message) ~= "string" or not FD.duel then return false end
    if type(ERR_DUEL_REQUESTED) == "string" and message == ERR_DUEL_REQUESTED and self.outgoing then
        local pending = self.outgoing
        self.outgoing = nil
        if GetTime() - pending.at <= FD.C.PRESENCE_TIMEOUT then
            self:OutgoingStatus(pending.opponent.fullName .. " | native acknowledgment via " .. source)
            FD.duel:Begin("OUTGOING", self:Identity("player", true), pending.opponent)
        else
            self:OutgoingStatus(pending.opponent.fullName .. " | native acknowledgment arrived too late")
        end
        return true
    end
    if type(ERR_DUEL_CANCELLED) == "string" and message == ERR_DUEL_CANCELLED then
        self:ClearOutgoing("native duel cancelled", true)
        self:ClearIncoming("native duel cancelled")
        FD.duel:Abort("native duel cancelled", true)
        return true
    end
    return false
end

function Wow:InfoMessage(source, errorType, message)
    if not self:Readable(message) or type(message) ~= "string" then return end
    if self.outgoing or (FD.duel and FD.duel.active) then FD.Debug:Log(source, message) end
    self:DuelNotice(message, source)
end

function Wow:SystemMessage(message)
    if not self:Readable(message) or type(message) ~= "string" or not FD.duel then return end
    if FD.duel.active or self.outgoing then FD.Debug:Log("system", message) end
    if self:DuelNotice(message, "CHAT_MSG_SYSTEM") then return end
    local m = FD.duel.active
    if not m and not self.pendingIncoming and not self.outgoing and not self.outgoingBlockedUntil then return end
    local seconds = FD.Results:Countdown(message, DUEL_COUNTDOWN)
    if seconds then
        self:ClearOutgoing("native countdown started", true)
        self:ClearIncoming("native countdown started")
        FD.duel:Countdown(seconds)
        return
    end
    if not m then return end
    local winner, source = FD.Results:Parse(message, DUEL_WINNER_KNOCKOUT, DUEL_WINNER_RETREAT, m.player, m.opponent)
    if winner then FD.Debug:Log("local result", winner, source); FD.duel:Result(winner, source) end
end

function Wow:Environment()
    return {
        now = GetTime, epoch = GetServerTime,
        after = function(seconds, callback)
            C_Timer.After(seconds, function() FD:Safe(callback) end)
        end,
        random = function() return math.random(1, 2147483646) end,
        identity = function() return self:Identity("player", true) end,
        opponentIdentity = function(opponent) return self:ResolveIncoming(opponent.fullName) end,
        send = function(payload, target, match) return FD.Comms:Send(payload, target, match) end,
        render = function(m)
            FD.UI:Render(m)
            FD.Profile:RefreshIfShown()
            if FD.Presence then FD.Presence:Changed() end
        end,
        hide = function() FD.UI:Hide() end,
        restore = function(m) return FD.UI:Restore(m) end,
        print = function(text) FD.Debug:Print(text) end,
        log = function(...) FD.Debug:Log(...) end,
        -- REQUIRES LIVE CLIENT VERIFICATION: legacy action protection is not
        -- specified in generated docs. Failure restores the native unrated UI.
        accept = function() return pcall(AcceptDuel) end,
        decline = function() return pcall(CancelDuel) end,
    }
end
