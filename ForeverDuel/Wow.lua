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
    if not self:Readable(guid, name, realm, className, classFile) then return nil, "restricted native identity" end
    if not FD.Protocol:ValidGUID(guid) then return nil, "native player GUID unavailable" end
    if type(name) ~= "string" or name == "" then return nil, "native player name unavailable" end
    if not classFile then return nil, "native class unavailable" end
    local regionalNames = RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled()
    if not self:Readable(regionalNames) then return nil, "restricted native name mode" end
    local fullName, requestName, requestFullName, nameFormat
    if regionalNames then
        -- Forever's second name component is a surname, not a realm. Its
        -- native helper supplies the exact whisper name, including separator.
        if not UnitNameUnmodified or not NameUtil or not NameUtil.GetUnmodifiedUnitFullName then return nil, "native surname helper unavailable" end
        local first, surname = UnitNameUnmodified(unit)
        if not self:Readable(first, surname) or type(first) ~= "string" or first == "" then return nil, "native unmodified name unavailable" end
        if surname ~= nil and type(surname) ~= "string" then return nil, "native surname unavailable" end
        fullName = NameUtil.GetUnmodifiedUnitFullName(unit)
        if not self:Readable(fullName) or type(fullName) ~= "string" or fullName == "" then return nil, "native full surname name unavailable" end
        -- Retain locally observed unit-name forms for the native duel event
        -- only. They never qualify an addon sender or a winner message.
        requestName = name
        requestFullName = type(realm) == "string" and realm ~= "" and name .. "-" .. realm or name
        name, realm, nameFormat = fullName, GetNormalizedRealmName(), "surname"
    else
        realm = realm and realm ~= "" and realm or GetNormalizedRealmName()
        if not self:Readable(realm) or type(realm) ~= "string" or realm == "" then return nil, "native realm metadata unavailable" end
        fullName = name .. "-" .. realm
    end
    if not self:Readable(realm) or type(realm) ~= "string" or realm == "" then return nil, "native realm metadata unavailable" end
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
    if self.outgoingArgument then status = status .. " | unitargument=" .. self.outgoingArgument end
    self.outgoingStatus, self.outgoingAt = status, GetTime()
    FD.Debug:Log("outgoing request", status)
end

function Wow:ClearOutgoing(reason, nativeEnded)
    local pending = self.outgoing or self.outgoingBlockedUntil
    local deadline = math.max(self.outgoingBlockedUntil or 0,
        self.outgoing and self.outgoing.at + FD.C.OUTGOING_TIMEOUT or 0)
    self.outgoing = nil
    -- A local cancel/accept call does not prove that an older unqualified
    -- request acknowledgment cannot still arrive. Keep its ambiguity window.
    self.outgoingBlockedUntil = not nativeEnded and deadline > GetTime() and deadline or nil
    if self.outgoingBlockedUntil then reason = reason .. " | waiting for prior acknowledgment window" end
    if pending then self:OutgoingStatus(reason) end
end

function Wow:BlockOutgoing(reason)
    -- The post-hook runs after native StartDuel already made its attempt. An
    -- unreadable or unresolved identity does not prove that no request went
    -- out; quarantine its possible unqualified acknowledgment as well.
    self.outgoing = nil
    self.outgoingBlockedUntil = math.max(self.outgoingBlockedUntil or 0, GetTime() + FD.C.OUTGOING_TIMEOUT)
    self:OutgoingStatus(reason .. " | waiting for prior acknowledgment window")
end

function Wow:CaptureOutgoing(unit)
    if not self:Readable(unit) then self.outgoingArgument = "restricted"
    elseif type(unit) == "string" then self.outgoingArgument = "string:" .. unit:gsub("[%c|]", "?"):sub(1, 128)
    else self.outgoingArgument = type(unit) end
    self:ClearIncoming("new outgoing request")
    self.incomingStatus = nil
    if not FD.duel then return end
    if not self:Readable(unit) or type(unit) ~= "string" then return self:BlockOutgoing("requested unit unavailable") end
    -- Blizzard's secure /duel handler forwards the empty slash argument to
    -- StartDuel. That command requests the current target. This is only the
    -- empty-command default; an unresolved explicit name/token never falls
    -- back to whichever unit happens to be targeted.
    if unit == "" then unit = "target" end
    if InCombatLockdown() then return self:BlockOutgoing("combat; rated detection unavailable") end
    -- A StartDuel post-hook is only an attempt. Require the subsequent server
    -- system acknowledgement before enabling presence/consent on this side.
    -- Never substitute the current target for an unresolved requested unit.
    if self.outgoing or (self.outgoingBlockedUntil and GetTime() < self.outgoingBlockedUntil) then
        self.outgoing = nil
        self.outgoingBlockedUntil = GetTime() + FD.C.OUTGOING_TIMEOUT
        FD.duel:Abort("overlapping outgoing attempts", true)
        self:OutgoingStatus("overlapping attempts; waiting for a new unambiguous request")
        return
    end
    local candidate, identityReason = self:Identity(unit)
    local reason
    -- /duel passes its explicit character-name argument to StartDuel, whereas
    -- the unit menu passes a unit token. A native name need not be accepted by
    -- UnitGUID; resolve only that exact requested name among observed units.
    if not candidate then candidate, reason = self:ResolveIncoming(unit) end
    if reason == "ambiguous" then return self:BlockOutgoing("requested native name is ambiguous") end
    if not candidate then return self:BlockOutgoing("native unit identity unavailable (" .. (identityReason or "no exact observed identity") .. ")") end
    self.outgoing = { opponent = candidate, at = GetTime() }
    self:OutgoingStatus(candidate.fullName .. " | waiting for native acknowledgment")
    local captured = self.outgoing
    C_Timer.After(FD.C.OUTGOING_TIMEOUT, function()
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
    self.outgoingStatus, self.outgoingAt, self.outgoingArgument = nil, nil, nil
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
-- exact native pending-request/cancel IDs or localized messages are accepted; UI
-- notices never supply countdown or winner evidence.
function Wow:DuelNotice(message, source, errorType)
    if not self:Readable(message) or type(message) ~= "string" or not FD.duel then return false end
    local stringID
    if self:Readable(errorType) and type(errorType) == "number" and errorType >= 0
        and errorType % 1 == 0 and type(GetGameMessageInfo) == "function" then
        local ok, value = pcall(GetGameMessageInfo, errorType)
        if ok and self:Readable(value) and type(value) == "string" then stringID = value end
    end
    local requested = stringID == "ERR_DUEL_REQUESTED"
        or type(ERR_DUEL_REQUESTED) == "string" and message == ERR_DUEL_REQUESTED
    if requested and self.outgoing then
        local pending = self.outgoing
        self.outgoing = nil
        if GetTime() - pending.at <= FD.C.OUTGOING_TIMEOUT then
            self:OutgoingStatus(pending.opponent.fullName .. " | native acknowledgment via " .. source)
            FD.duel:Begin("OUTGOING", self:Identity("player", true), pending.opponent, pending.at)
        else
            self:OutgoingStatus(pending.opponent.fullName .. " | native acknowledgment arrived too late")
        end
        return true, stringID
    end
    if stringID == "ERR_DUEL_CANCELLED" or type(ERR_DUEL_CANCELLED) == "string" and message == ERR_DUEL_CANCELLED then
        self:ClearOutgoing("native duel cancelled", true)
        self:ClearIncoming("native duel cancelled")
        FD.duel:Abort("native duel cancelled", true)
        return true, stringID
    end
    return false, stringID
end

function Wow:InfoMessage(source, errorType, message)
    if not self:Readable(message) or type(message) ~= "string" then return end
    local tracking = self.outgoing or (FD.duel and FD.duel.active)
        or self.outgoingAt and GetTime() - self.outgoingAt <= FD.C.OUTGOING_TIMEOUT
    local _, stringID = self:DuelNotice(message, source, errorType)
    if tracking then FD.Debug:Log(source, self:Readable(errorType) and errorType or "restricted", stringID, message) end
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
        notify = function(kind, match)
            if FD.QueueWow and FD.QueueWow.ObserveDuel then pcall(FD.QueueWow.ObserveDuel, FD.QueueWow, kind, match) end
            if FD.queue then FD.queue:Run(function() FD.queue:OnDuel(kind, match) end) end
        end,
        -- REQUIRES LIVE CLIENT VERIFICATION: legacy action protection is not
        -- specified in generated docs. Failure restores the native unrated UI.
        accept = function() return pcall(AcceptDuel) end,
        decline = function() return pcall(CancelDuel) end,
    }
end
