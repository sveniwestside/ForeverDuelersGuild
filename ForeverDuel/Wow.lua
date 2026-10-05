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

local scanUnits = { "target", "mouseover", "focus" }
for i = 1, 4 do scanUnits[#scanUnits + 1] = "party" .. i end
for i = 1, 40 do
    scanUnits[#scanUnits + 1] = "raid" .. i
    scanUnits[#scanUnits + 1] = "nameplate" .. i
end

function Wow:ResolveIncoming(requestName)
    if not self:Readable(requestName) or type(requestName) ~= "string" then return nil end
    local found
    for _, unit in ipairs(scanUnits) do
        local candidate = self:Identity(unit)
        if candidate and (requestName == candidate.fullName or requestName == candidate.name
            or requestName == candidate.requestName or requestName == candidate.requestFullName) then
            if found and found.guid ~= candidate.guid then return nil, "ambiguous" end
            found = candidate
        end
    end
    return found
end

-- A positive native observation of the bound opponent, or nil when no unit
-- currently resolves to them (which the duel treats as unchanged).
-- UnitTokenFromGUID is in the pinned UnitDocumentation (secret when unit
-- identity is restricted); older clients fall back to the name scan.
function Wow:Observe(opponent)
    if type(UnitTokenFromGUID) == "function" then
        local ok, unit = pcall(UnitTokenFromGUID, opponent.guid)
        if not ok or not self:Readable(unit) or type(unit) ~= "string" or unit == "" then return nil end
        return (self:Identity(unit))
    end
    return (self:ResolveIncoming(opponent.fullName))
end

-- A player the discovery cache knows as an addon user.
function Wow:Known(fullName)
    if not FD.Presence or type(FD.Presence.FindByName) ~= "function" or type(fullName) ~= "string" then return false end
    local ok, player = pcall(FD.Presence.FindByName, FD.Presence, fullName)
    return ok and player ~= nil
end

function Wow:OutgoingStatus(status)
    if self.outgoingArgument then status = status .. " | unitargument=" .. self.outgoingArgument end
    self.outgoingStatus, self.outgoingAt = status, GetTime()
    FD.Debug:Log("outgoing request", status)
end

function Wow:PendingOutgoing()
    local pending = self.outgoing
    if pending and GetTime() - pending.at <= FD.C.OUTGOING_TIMEOUT then return pending end
end

function Wow:Blocked()
    return self.outgoingBlockedUntil ~= nil and GetTime() < self.outgoingBlockedUntil
end

function Wow:ClearOutgoing(reason, nativeEnded)
    local pending = self.outgoing or self.outgoingBlockedUntil
    local deadline = math.max(self.outgoingBlockedUntil or 0,
        self.outgoing and self.outgoing.at + FD.C.OUTGOING_TIMEOUT or 0)
    self.outgoing, self.failedOutgoing = nil, nil
    -- A local cancel/accept call does not prove that an older unqualified
    -- request acknowledgment cannot still arrive. Keep its ambiguity window.
    self.outgoingBlockedUntil = not nativeEnded and deadline > GetTime() and deadline or nil
    if not self.outgoingBlockedUntil then self.blockAttemptAt = nil end
    if self.outgoingBlockedUntil then reason = reason .. " | waiting for prior acknowledgment window" end
    if pending then self:OutgoingStatus(reason) end
end

-- Remember why rated tracking could not attach to the user's attempt; the
-- reason is printed only if the native request actually goes out.
function Wow:Untracked(reason, detail)
    if self.attempt then self.attempt.reason = reason end
    self:OutgoingStatus(reason .. (detail and (" (" .. detail .. ")") or ""))
end

function Wow:Requested(unit)
    if not self:Readable(unit) or type(unit) ~= "string" then return nil, "the requested player could not be identified", "requested unit unavailable" end
    -- Blizzard's secure /duel handler forwards the empty slash argument to
    -- StartDuel, which requests the current target. An unresolved explicit
    -- name/token never falls back to whichever unit happens to be targeted.
    if unit == "" then unit = "target" end
    local candidate, identityReason = self:Identity(unit)
    if candidate then return candidate end
    -- /duel passes its explicit name, the unit menu a token. A native name
    -- need not be accepted by UnitGUID; resolve it among observed units.
    local found, ambiguity = self:ResolveIncoming(unit)
    if ambiguity == "ambiguous" then return nil, "the requested name matches several players", "requested native name is ambiguous" end
    if found then return found end
    return nil, "the requested player could not be identified", "native unit identity unavailable ("
        .. (identityReason or "no exact observed identity") .. ")"
end

function Wow:Capture(candidate, now)
    local captured = { opponent = candidate, at = now }
    self.outgoing = captured
    C_Timer.After(FD.C.OUTGOING_TIMEOUT, function()
        if self.outgoing == captured then
            self.outgoing = nil
            self:OutgoingStatus(captured.opponent.fullName .. " | expired without native acknowledgment")
        end
    end)
end

-- StartDuel post-hook. Only an attempt: the server acknowledgment that
-- follows decides whether a rated negotiation begins. Combat does not block
-- capture; the rated button stays disabled until combat ends instead.
function Wow:CaptureOutgoing(unit, exactMatch, toTheDeath)
    if toTheDeath == true then
        -- A Hardcore duel to the death is never rated or tracked. Its
        -- acknowledgment could not be told apart from a pending capture's.
        self.attempt = nil
        local pending = self:PendingOutgoing()
        if pending then
            self.outgoing, self.failedOutgoing, self.blockAttemptAt = nil, nil, nil
            self.outgoingBlockedUntil = math.max(self.outgoingBlockedUntil or 0, pending.at + FD.C.OUTGOING_TIMEOUT)
        end
        return self:OutgoingStatus("duel to the death; not tracked")
    end
    if not self:Readable(unit) then self.outgoingArgument = "restricted"
    elseif type(unit) == "string" then self.outgoingArgument = "string:" .. unit:gsub("[%c|]", "?"):sub(1, 128)
    else self.outgoingArgument = type(unit) end
    self:ClearIncoming("new outgoing request")
    self.incomingStatus = nil
    if not FD.duel then return end
    local now = GetTime()
    self.attempt = { at = now }
    local candidate, reason, detail = self:Requested(unit)
    local pending = self:PendingOutgoing()
    if pending then
        if candidate and candidate.guid == pending.opponent.guid then
            -- The same player again (double click, retry after a failure):
            -- any acknowledgment is unambiguous, so the newer attempt wins.
            self:Capture(candidate, now)
            return self:OutgoingStatus(candidate.fullName .. " | repeated request replaces the pending capture")
        end
        -- Another target: an unqualified acknowledgment could belong to either
        -- attempt. Block only for the original attempt's remaining window.
        self.outgoing, self.failedOutgoing, self.blockAttemptAt = nil, nil, nil
        self.outgoingBlockedUntil = math.max(self.outgoingBlockedUntil or 0, pending.at + FD.C.OUTGOING_TIMEOUT)
        return self:Untracked("another duel request is still pending", "different target inside the acknowledgment window")
    end
    self.failedOutgoing = nil
    if self:Blocked() then return self:Untracked("another duel request is still pending", "earlier acknowledgment window") end
    if not candidate then
        -- The native attempt may still have gone out; quarantine its
        -- possible acknowledgment for this attempt's own window.
        self.blockAttemptAt = now
        self.outgoingBlockedUntil = now + FD.C.OUTGOING_TIMEOUT
        return self:Untracked(reason, detail)
    end
    self:Capture(candidate, now)
    self:OutgoingStatus(candidate.fullName .. " | waiting for native acknowledgment")
end

function Wow:ClearIncoming(reason)
    if not self.pendingIncoming then return end
    self.pendingIncoming = nil
    self.incomingStatus = reason
    FD.Debug:Log("incoming identity check stopped", reason)
end

function Wow:TryIncoming(pending, checkPopup)
    if self.pendingIncoming ~= pending then return end
    if GetTime() - pending.at >= FD.C.PENDING_TIMEOUT then
        return self:ClearIncoming("request expired; native duel retained")
    end
    if checkPopup then
        -- The initial event may run before Blizzard shows its dialog. Later
        -- attempts need positive evidence that the request is still open.
        if type(StaticPopup_Visible) ~= "function" then
            return self:ClearIncoming("popup visibility unavailable; native duel retained")
        end
        local ok, visible = pcall(StaticPopup_Visible, "DUEL_REQUESTED")
        if not ok or not self:Readable(visible) or not visible then
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

function Wow:KnownRequestName(name)
    if self:Known(name) then return true end
    local realm = type(GetNormalizedRealmName) == "function" and GetNormalizedRealmName()
    return self:Readable(realm) and type(realm) == "string" and not name:find("-", 1, true)
        and self:Known(name .. "-" .. realm) or false
end

function Wow:Incoming(name)
    if not FD.duel then return end
    local death = self.death
    if death and death.name == name and GetTime() - death.at <= 1 then return end
    self:ClearIncoming("replaced by a new incoming request")
    self:ClearOutgoing("incoming request replaced outgoing attempt", true)
    self.outgoingStatus, self.outgoingAt, self.outgoingArgument = nil, nil, nil
    FD.duel:Supersede("replaced")
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
        -- Only known addon users get the hint; ordinary duels stay silent.
        if self:KnownRequestName(name) then
            FD.Debug:Print(FD.L["Rated duel pending: target the challenger so ForeverDuelersGuild can verify their identity."])
        end
        self:RetryIncoming(pending)
    end
end

-- DUEL_TO_THE_DEATH_REQUESTED (pinned DuelInfo documentation). Never rated;
-- if the client also raised DUEL_REQUESTED for it, drop that fresh request.
function Wow:DeathRequest(name)
    self.death = { name = name, at = GetTime() }
    if self.pendingIncoming and self.pendingIncoming.name == name then self:ClearIncoming("duel to the death; not tracked") end
    local m = FD.duel and FD.duel.active
    if m and m.role == "INCOMING" and not m.peerNonce and GetTime() - m.createdAt <= 1 then
        FD.duel:Abort("cancelled", false)
    end
end

-- Native failures of the Duel request (the request is a spell cast).
-- ERR_OUT_OF_RANGE, ERR_SPELL_OUT_OF_RANGE and ERR_GENERIC_NO_VALID_TARGETS
-- are LE_GAME_ERR_* names in the pinned UIErrorsFrame; ERR_GENERIC_NO_TARGET
-- and the SPELL_FAILED_* texts (target busy/dueling) are NOT verified there.
-- All are plain comparisons that only match when the client reports them;
-- the real UI_ERROR_MESSAGE of a failed StartDuel needs a live check.
local failureIds = { ERR_OUT_OF_RANGE = true, ERR_SPELL_OUT_OF_RANGE = true,
    ERR_GENERIC_NO_TARGET = true, ERR_GENERIC_NO_VALID_TARGETS = true }
local failureTexts = { "ERR_OUT_OF_RANGE", "ERR_SPELL_OUT_OF_RANGE", "ERR_GENERIC_NO_TARGET",
    "SPELL_FAILED_OUT_OF_RANGE", "SPELL_FAILED_BAD_TARGETS", "SPELL_FAILED_BAD_IMPLICIT_TARGETS",
    "SPELL_FAILED_TARGET_DUELING", "SPELL_FAILED_NO_DUELING" }

function Wow:Failure(stringID, message)
    if stringID and failureIds[stringID] then return true end
    for _, name in ipairs(failureTexts) do
        local text = _G[name]
        if type(text) == "string" and text ~= "" and message == text then return true end
    end
    return false
end

function Wow:ReportUntracked()
    local attempt = self.attempt
    if not attempt or attempt.printed or not attempt.reason or GetTime() - attempt.at > FD.C.OUTGOING_TIMEOUT then return end
    attempt.printed = true
    FD.Debug:Print(FD.Locale:Format("Rated tracking could not attach to your duel request: %s. It continues as an ordinary duel.",
        FD.L[attempt.reason]))
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
    local now = GetTime()
    if stringID == "ERR_DUEL_REQUESTED" or type(ERR_DUEL_REQUESTED) == "string" and message == ERR_DUEL_REQUESTED then
        local pending = self:PendingOutgoing()
        -- A failure notice may have belonged to another spell: with no newer
        -- attempt, the only possible owner of this acknowledgment is that capture.
        local failed = self.failedOutgoing
        if not pending and failed and self.attempt and self.attempt.at <= failed.at
            and now - failed.at <= FD.C.OUTGOING_TIMEOUT then pending = failed end
        self.outgoing, self.failedOutgoing = nil, nil
        if pending then
            self:OutgoingStatus(pending.opponent.fullName .. " | native acknowledgment via " .. source)
            local begun, reason = FD.duel:Begin("OUTGOING", self:Identity("player", true), pending.opponent, pending.at)
            if not begun then
                self:Untracked(reason or "rated tracking could not start")
                self:ReportUntracked()
            end
        else
            self:ReportUntracked()
        end
        return true, stringID
    end
    if stringID == "ERR_DUEL_CANCELLED" or type(ERR_DUEL_CANCELLED) == "string" and message == ERR_DUEL_CANCELLED then
        self:ClearOutgoing("native duel cancelled", true)
        self:ClearIncoming("native duel cancelled")
        FD.duel:Cancelled()
        return true, stringID
    end
    if self:Failure(stringID, message) then
        local pending = self.outgoing
        if pending and now - pending.at <= FD.C.FAILURE_WINDOW then
            self.outgoing, self.failedOutgoing = nil, pending
            self:OutgoingStatus(pending.opponent.fullName .. " | native request failed (" .. (stringID or "notice") .. ")")
        elseif self.blockAttemptAt and now - self.blockAttemptAt <= FD.C.FAILURE_WINDOW then
            -- The unidentified attempt failed natively; no acknowledgment can follow.
            self.outgoingBlockedUntil, self.blockAttemptAt = nil, nil
            self:OutgoingStatus("unidentified request failed natively (" .. (stringID or "notice") .. ")")
        end
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
    if self:DuelNotice(message, "CHAT_MSG_SYSTEM") then return end
    local m, parked = FD.duel.active, FD.duel.parked
    if not m and not parked and not self.pendingIncoming and not self.outgoing and not self.outgoingBlockedUntil then return end
    local seconds = FD.Results:Countdown(message, DUEL_COUNTDOWN)
    if seconds then
        self:ClearOutgoing("native countdown started", true)
        self:ClearIncoming("native countdown started")
        FD.duel:Countdown(seconds)
        return
    end
    for _, match in ipairs({ m or false, parked or false }) do
        if match then
            local winner, source = FD.Results:Parse(message, DUEL_WINNER_KNOCKOUT, DUEL_WINNER_RETREAT, match.player, match.opponent)
            if winner then FD.duel:Result(winner, source, match); return end
        end
    end
end

-- After the addon's own AcceptDuel the still-open native popup would cancel
-- the duel: its Decline, and its own timeout (pinned StaticPopup.lua
-- CancelAndHideDialog), call OnCancel = CancelDuel. Hide it out of combat;
-- StaticPopup_Hide never calls OnCancel. pcall cannot tell whether the accept
-- took effect, so Duel:AcceptTimeout releases the match if no countdown follows.
function Wow:Accept()
    if type(AcceptDuel) ~= "function" then return false end
    local ok = pcall(AcceptDuel)
    if ok and not InCombatLockdown() and type(StaticPopup_Hide) == "function" then
        pcall(StaticPopup_Hide, "DUEL_REQUESTED")
    end
    return ok
end

function Wow:Environment()
    return {
        now = GetTime, epoch = GetServerTime,
        after = function(seconds, callback)
            C_Timer.After(seconds, function() FD:Safe(callback) end)
        end,
        random = function() return math.random(1, 2147483646) end,
        identity = function() return self:Identity("player", true) end,
        opponentIdentity = function(opponent) return self:Observe(opponent) end,
        known = function(opponent) return self:Known(opponent.fullName) end,
        combat = function() return InCombatLockdown() == true end,
        send = function(item) return FD.Comms:Send(item) end,
        render = function(m)
            FD.UI:Render(m)
            FD.Profile:RefreshIfShown()
        end,
        hide = function() FD.UI:Hide() end,
        print = function(text) FD.Debug:Print(text) end,
        log = function(...) FD.Debug:Log(...) end,
        notify = function(kind, match)
            if FD.QueueWow and FD.QueueWow.ObserveDuel then pcall(FD.QueueWow.ObserveDuel, FD.QueueWow, kind, match) end
            if FD.queue then FD.queue:Run(function() FD.queue:OnDuel(kind, match) end) end
        end,
        -- REQUIRES LIVE CLIENT VERIFICATION: legacy action protection is not
        -- specified in generated docs. A failure leaves Blizzard's popup as is.
        accept = function() return self:Accept() end,
    }
end

-- The single entry point for duel requests started by addon buttons (queue,
-- zone browser). Unit tokens ("party1") and names are accepted. Success means
-- "submitted, waiting for the native acknowledgment", never "requested".
function Wow:RequestDuel(unit)
    if type(StartDuel) ~= "function" then return false, FD.L["Native duel API is unavailable; request the duel manually."] end
    if type(unit) ~= "string" or unit == "" then return false, FD.L["Select a player to challenge."] end
    local m = FD.duel and FD.duel.active
    if m and m.state ~= "FINISHING" then return false, FD.L["Finish the current duel request first."] end
    if self.pendingIncoming then return false, FD.L["Answer the incoming duel request first."] end
    if self:PendingOutgoing() then return false, FD.L["Wait for your previous duel request to be answered."] end
    if self:Blocked() then
        return false, FD.Locale:Format("A previous duel request is still pending (%d s).",
            math.ceil(self.outgoingBlockedUntil - GetTime()))
    end
    if InCombatLockdown() then return false, FD.L["Leave combat before requesting a duel."] end
    local ok, result = pcall(StartDuel, unit, true)
    if not ok or not self:Readable(result) or result == false then
        return false, FD.L["Native duel request was blocked; request the duel manually."]
    end
    return true
end

function Wow:InstallHooks()
    if type(hooksecurefunc) ~= "function" then return end
    if type(StartDuel) == "function" then
        hooksecurefunc("StartDuel", function(unit, exactMatch, toTheDeath)
            FD:Safe(function() self:CaptureOutgoing(unit, exactMatch, toTheDeath) end)
        end)
    end
    if type(AcceptDuel) == "function" then
        hooksecurefunc("AcceptDuel", function()
            FD:Safe(function()
                self:ClearOutgoing("native duel accepted")
                self:ClearIncoming("native duel accepted")
                if FD.duel then FD.duel:ObservedAccept() end
            end)
        end)
    end
    if type(CancelDuel) == "function" then
        hooksecurefunc("CancelDuel", function()
            FD:Safe(function()
                self:ClearOutgoing("native duel declined or cancelled")
                self:ClearIncoming("native duel declined or cancelled")
                if FD.duel then FD.duel:Cancelled() end
            end)
        end)
    end
end

-- Level changes invalidate a pending rated agreement. Only the player and the
-- active opponent matter; an unreadable identity is not treated as a change.
function Wow:LevelChanged(unit)
    local m = FD.duel and FD.duel.active
    local pending = m and m.state ~= "UNRATED" and m.state ~= "UNRATED_ACTIVE"
    if unit ~= nil and unit ~= "player" then
        if not pending or not self:Readable(unit) or type(unit) ~= "string" then return end
        local peer = self:Identity(unit)
        if peer and peer.guid == m.opponent.guid and (peer.level ~= m.opponent.level
            or peer.maxLevel ~= m.opponent.maxLevel) then
            FD.duel:Unrate("level", true, "opponent level event")
        end
        return
    end
    local identity = self:Identity("player", true)
    if identity then FD.Database:SetBracket(identity) end
    if pending and identity and (identity.level ~= m.player.level or identity.maxLevel ~= m.player.maxLevel) then
        FD.duel:Unrate("level", true, "own level event")
    end
    FD.Profile:RefreshIfShown()
    FD.Presence:Changed()
end

FD:OnEvent("DUEL_REQUESTED", function(...) Wow:Incoming(...) end)
FD:OnEvent("DUEL_TO_THE_DEATH_REQUESTED", function(...) Wow:DeathRequest(...) end, false, true)
FD:OnEvent("DUEL_FINISHED", function()
    Wow:ClearOutgoing("native duel finished", true)
    Wow:ClearIncoming("native duel finished")
    FD.duel:Finished()
end)
FD:OnEvent("CHAT_MSG_ADDON", function(prefix, payload, channel, sender)
    FD.Comms:Receive(prefix, payload, channel, sender)
end)
FD:OnEvent("CHAT_MSG_SYSTEM", function(...) Wow:SystemMessage(...) end)
FD:OnEvent("UI_INFO_MESSAGE", function(...) Wow:InfoMessage("UI_INFO_MESSAGE", ...) end)
FD:OnEvent("UI_ERROR_MESSAGE", function(...) Wow:InfoMessage("UI_ERROR_MESSAGE", ...) end)
local function leaveWorld()
    Wow:ClearOutgoing("world transition or logout", true)
    Wow:ClearIncoming("world transition or logout")
    -- Third argument: submit the CANCEL synchronously while still connected.
    FD.duel:Abort("world", true, true)
end
FD:OnEvent("PLAYER_LEAVING_WORLD", leaveWorld)
FD:OnEvent("PLAYER_LOGOUT", leaveWorld)
FD:OnEvent("PLAYER_SPECIALIZATION_CHANGED", function(unit)
    if Wow:Readable(unit) and unit == "player" then FD.duel:Unrate("spec", true) end
end)
FD:OnEvent("UNIT_LEVEL", function(unit) Wow:LevelChanged(unit) end)
FD:OnEvent("PLAYER_LEVEL_UP", function()
    -- The event payload can precede UnitLevel's update. Invalidate
    -- immediately, then query native state on the next frame.
    FD.duel:Unrate("level", true, "level up")
    C_Timer.After(0, function() FD:Safe(function() Wow:LevelChanged("player") end) end)
end)
FD:OnEvent("PLAYER_ENTERING_WORLD", function() Wow:LevelChanged("player") end)
FD:OnEvent("PLAYER_REGEN_DISABLED", function()
    local m = FD.duel.active
    if m and not m.countdownAt then FD.duel:Unrate("combat", true) end
    FD.UI:Render(FD.duel.active)
end)
-- Combat only disables the rated button; re-enable it when combat ends.
FD:OnEvent("PLAYER_REGEN_ENABLED", function() FD.UI:Render(FD.duel.active) end)

FD:RegisterStatus(20, function()
    local lines, m, last = {}, FD.duel and FD.duel.active, FD.duel and FD.duel.last
    if Wow.incomingStatus then lines[#lines + 1] = "Incoming request: " .. Wow.incomingStatus end
    if Wow.outgoingStatus then
        lines[#lines + 1] = "Outgoing request: " .. Wow.outgoingStatus
            .. string.format(" | %.1fs ago", GetTime() - (Wow.outgoingAt or GetTime()))
    end
    if Wow.outgoing then lines[#lines + 1] = "Outgoing: " .. Wow.outgoing.opponent.fullName .. " | waiting for native acknowledgment" end
    if Wow:Blocked() then
        lines[#lines + 1] = string.format("Outgoing tracking blocked for %.0fs", Wow.outgoingBlockedUntil - GetTime())
    end
    if m then
        lines[#lines + 1] = string.format("Native request: %s | age %.1fs | %.0fs left", m.role,
            GetTime() - m.createdAt, math.max(0, m.deadline - GetTime()))
        lines[#lines + 1] = "Native self: " .. m.player.guid .. " | " .. m.player.classFile .. " | level "
            .. (m.player.level or "unknown") .. "/" .. (m.player.maxLevel or "unknown")
        lines[#lines + 1] = "Native opponent: " .. m.opponent.guid .. " | " .. m.opponent.classFile .. " | level "
            .. (m.opponent.level or "unknown") .. "/" .. (m.opponent.maxLevel or "unknown")
        lines[#lines + 1] = m.role .. " | " .. m.opponent.fullName .. " | " .. (m.matchId and "match bound" or "checking addon")
            .. " | " .. (m.reason and ("UNRATED: " .. m.reason) or m.state)
        lines[#lines + 1] = "Peer confirmation: " .. (m.peerNonce and "bound to current request" or "waiting for current request acknowledgment")
            .. (m.peerVersion and (" | peer addon " .. m.peerVersion) or "")
        if m.rtt then lines[#lines + 1] = string.format("Discovery round trip: %.1fs (first HELLO to first ACK)", m.rtt) end
        if m.peerOutdated then lines[#lines + 1] = "Peer addon: outdated (protocol 2); rated duels need 0.6 on both sides" end
    end
    local parked = FD.duel and FD.duel.parked
    if parked then lines[#lines + 1] = "Previous duel: awaiting result from " .. parked.opponent.fullName end
    if last then lines[#lines + 1] = "Last: " .. last.state .. " | " .. (last.reason or "") end
    return lines
end)
