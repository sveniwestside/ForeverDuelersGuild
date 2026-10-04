local addonName, FD = ...

function FD:Safe(callback, ...)
    local ok, errorText = pcall(callback, ...)
    if ok then return end
    local m = self.duel and self.duel.active
    -- Error recovery must not depend on the failing render/transport callback.
    if self.duel then self.duel.active = nil end
    if self.Wow then
        local deadline = math.max(self.Wow.outgoingBlockedUntil or 0,
            self.Wow.outgoing and self.Wow.outgoing.at + self.C.PRESENCE_TIMEOUT or 0)
        if self.Wow.outgoing or self.Wow.outgoingBlockedUntil then
            self.Wow.outgoingStatus, self.Wow.outgoingAt = "addon error; rated flow stopped", GetTime()
        end
        self.Wow.outgoing = nil
        self.Wow.outgoingBlockedUntil = deadline > GetTime() and deadline or nil
        self.Wow.pendingIncoming = nil
        self.Wow.incomingStatus = "addon error; native duel retained"
    end
    pcall(function() self.UI:Restore(m) end)
    self.Debug:Print("Rated flow stopped after an addon error. Use the normal duel dialog.")
    if self.Wow:Readable(errorText) then self.Debug:Log("error", errorText) end
end

function FD:Initialize()
    local identity = self.Wow:Identity("player", true)
    local db, err = self.Database:Initialize(ForeverDuelDB, identity)
    if not db then self.Debug:Print("Saved data unavailable (" .. tostring(err) .. "). Rated duels disabled; existing data preserved."); return end
    ForeverDuelDB = db
    if db.legacy then self.Debug:Print("Previous rating preserved in Legacy. Leveling and Max level have separate ratings.") end
    self.UI:Create() -- Establish a usable fallback before ever hiding native UI.
    self.Comms:Initialize()
    self.duel = self.Duel:New(self.Wow:Environment(), self.Database)
    if type(StartDuel) == "function" and type(hooksecurefunc) == "function" then
        hooksecurefunc("StartDuel", function(unit) self:Safe(function() self.Wow:CaptureOutgoing(unit) end) end)
    end
    if type(AcceptDuel) == "function" and type(hooksecurefunc) == "function" then
        hooksecurefunc("AcceptDuel", function()
            self:Safe(function()
                self.Wow:ClearOutgoing("native duel accepted")
                self.Wow:ClearIncoming("native duel accepted")
                local m = self.duel.active
                if not m or m.countdownAt or m.startedAt then return end
                if m.role == "INCOMING" and m.state == "RATED_CONFIRMED" and m.nativeAccepted then return end
                -- A native/other-addon acceptance during negotiation is final:
                -- do not let fast later acknowledgments retroactively rate it.
                self.duel:Unrate("native acceptance outside rated agreement", true)
                m.nativeAccepted = true
                self.UI:Hide()
            end)
        end)
    end
    if type(CancelDuel) == "function" and type(hooksecurefunc) == "function" then
        hooksecurefunc("CancelDuel", function()
            self:Safe(function()
                self.Wow:ClearOutgoing("native duel declined or cancelled")
                self.Wow:ClearIncoming("native duel declined or cancelled")
            end)
        end)
    end
    self.Debug:Log("loaded", addonName, self.C.VERSION, "transport", self.Comms.available)
    if type(DUEL_COUNTDOWN) ~= "string" or type(DUEL_WINNER_KNOCKOUT) ~= "string" then
        self.Debug:Print("Duel evidence formats unavailable. This client cannot finalize rated duels.")
    end
    self.Minimap:Initialize() -- Optional presentation; handles its own errors.
    self.Presence:Initialize()
    self.Tooltip:Initialize()
end

function FD:Command(text)
    text = (text or ""):lower():match("^%s*(.-)%s*$")
    if not self.Database.data then self.Debug:Print("Saved data unavailable; rating is disabled."); return end
    self.Database:SetBracket(self.Wow:Identity("player", true))
    if text == "debug" then
        local settings = self.Database.data.settings
        settings.debug = not settings.debug
        self.Debug:Print("Debug " .. (settings.debug and "enabled." or "disabled."))
    elseif text == "history" then self.UI:History(20)
    elseif text == "status" then
        local m = self.duel and self.duel.active
        local last = self.duel and self.duel.last
        self.Debug:Print("Version: " .. self.C.VERSION .. " | Addon transport: " .. (self.Comms.available and "registered" or "unavailable"))
        self.Debug:Print("State: " .. (self.duel and self.duel:State() or "DISABLED"))
        self.Debug:Print("Debug: " .. (self.Database.data.settings.debug and "enabled" or "disabled"))
        if self.Wow.incomingStatus then self.Debug:Print("Incoming request: " .. self.Wow.incomingStatus) end
        if self.Wow.outgoingStatus then
            self.Debug:Print("Outgoing request: " .. self.Wow.outgoingStatus
                .. string.format(" | %.1fs ago", GetTime() - self.Wow.outgoingAt))
        end
        local zoneStatus = self.Presence:Run(function() return self.Presence:GetStatus() end)
        self.Debug:Print("Zone discovery: " .. (zoneStatus or "unavailable"))
        if self.Presence.lastSend then self.Debug:Print("Zone send: " .. self.Presence.lastSend) end
        if self.Presence.lastWhisperSend then self.Debug:Print("Zone whisper: " .. self.Presence.lastWhisperSend) end
        if self.Roster and self.Roster.status then self.Debug:Print("Zone roster: " .. self.Roster.status) end
        if self.Presence.lastReceive then self.Debug:Print("Zone receive: " .. self.Presence.lastReceive) end
        if self.Wow.outgoing then self.Debug:Print("Outgoing: " .. self.Wow.outgoing.opponent.fullName .. " | waiting for native acknowledgment") end
        if self.Comms.lastSend then self.Debug:Print("Last send: " .. self.Comms.lastSend) end
        if self.Comms.lastReceive then self.Debug:Print("Last receive: " .. self.Comms.lastReceive) end
        if m then
            self.Debug:Print(m.role .. " | " .. m.opponent.fullName .. " | " .. (m.matchId or "checking addon") .. " | " .. (m.reason or m.state))
            self.Debug:Print("Peer confirmation: " .. (m.peerNonce and "bound to current request" or "waiting for current request acknowledgment"))
        end
        if last then self.Debug:Print("Last: " .. last.state .. " | " .. (last.reason or "") .. " | " .. (last.matchId or "")) end
    elseif text == "reset" then
        if self.duel and self.duel.active then self.Debug:Print("Finish or cancel the pending duel before resetting."); return end
        self.resetUntil = GetTime() + 15
        self.Debug:Print("This deletes this character's rating and history. Type /duelrating reset confirm within 15 seconds.")
    elseif text == "reset confirm" then
        if self.duel and self.duel.active then self.Debug:Print("Reset refused while a duel is pending."); return end
        if not self.resetUntil or GetTime() > self.resetUntil then self.Debug:Print("Type /duelrating reset first."); return end
        self.resetUntil = nil
        local db, err = self.Database:Reset(self.Wow:Identity("player", true))
        if db then
            ForeverDuelDB = db
            self.Profile:RefreshIfShown()
            self.Presence:Changed()
            self.Debug:Print("This character's rating and history reset.")
        else self.Debug:Print("Reset refused: " .. tostring(err)) end
    elseif text == "" or text == "ui" then self.Profile:Toggle()
    elseif text == "zone" then self.Zone:Toggle()
    elseif text == "summary" then self.UI:Summary()
    else self.Debug:Print("/duelrating [ui | zone | summary | history | status | debug | reset]") end
end

function FD:LevelChanged(unit)
    local identity = self.Wow:Identity("player", true)
    self.Database:SetBracket(identity)
    local m = self.duel and self.duel.active
    if m and m.state ~= "UNRATED" and m.state ~= "UNRATED_ACTIVE" then
        local changed = not identity or identity.level ~= m.player.level or identity.maxLevel ~= m.player.maxLevel
        if unit and self.Wow:Readable(unit) then
            local peer = self.Wow:Identity(unit)
            if peer and peer.guid == m.opponent.guid and (peer.level ~= m.opponent.level
                or peer.maxLevel ~= m.opponent.maxLevel) then changed = true end
        end
        if changed then self.duel:Unrate("Rated unavailable: participant level changed", true) end
    end
    self.Profile:RefreshIfShown()
    self.Presence:Changed()
end

local frame = CreateFrame("Frame")
local events = { "PLAYER_LOGIN", "DUEL_REQUESTED", "DUEL_FINISHED", "DUEL_INBOUNDS", "DUEL_OUTOFBOUNDS",
    "CHAT_MSG_ADDON", "CHAT_MSG_SYSTEM", "UI_INFO_MESSAGE", "UI_ERROR_MESSAGE", "PLAYER_LEAVING_WORLD", "PLAYER_LOGOUT", "PLAYER_SPECIALIZATION_CHANGED", "PLAYER_REGEN_DISABLED",
    "UNIT_LEVEL", "PLAYER_LEVEL_UP", "PLAYER_ENTERING_WORLD" }
for _, event in ipairs(events) do frame:RegisterEvent(event) end
frame:SetScript("OnEvent", function(_, event, ...)
    FD:Safe(function(...)
        if event == "PLAYER_LOGIN" then FD:Initialize(); return end
        if not FD.duel then return end
        if event ~= "CHAT_MSG_ADDON" and event ~= "CHAT_MSG_SYSTEM" and event ~= "UI_INFO_MESSAGE" and event ~= "UI_ERROR_MESSAGE" then FD.Debug:Log("event", event) end
        if event == "DUEL_REQUESTED" then FD.Wow:Incoming(...)
        elseif event == "DUEL_FINISHED" then
            FD.Wow:ClearOutgoing("native duel finished", true)
            FD.Wow:ClearIncoming("native duel finished")
            FD.duel:Finished()
        elseif event == "CHAT_MSG_ADDON" then FD.Comms:Receive(...)
        elseif event == "CHAT_MSG_SYSTEM" then FD.Wow:SystemMessage(...)
        elseif event == "UI_INFO_MESSAGE" or event == "UI_ERROR_MESSAGE" then FD.Wow:InfoMessage(event, ...)
        elseif event == "PLAYER_LEAVING_WORLD" or event == "PLAYER_LOGOUT" then
            FD.Wow:ClearOutgoing("world transition or logout", true)
            FD.Wow:ClearIncoming("world transition or logout")
            FD.duel:Abort("world transition or logout", true)
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            local unit = ...
            if FD.Wow:Readable(unit) and unit == "player" then FD.duel:Unrate("specialization changed", true) end
        elseif event == "UNIT_LEVEL" then FD:LevelChanged(...)
        elseif event == "PLAYER_LEVEL_UP" then
            -- The event payload can precede UnitLevel's update. Invalidate
            -- immediately, then query native state on the next frame.
            FD.duel:Unrate("Rated unavailable: player level changed", true)
            C_Timer.After(0, function() FD:Safe(function() FD:LevelChanged("player") end) end)
        elseif event == "PLAYER_ENTERING_WORLD" then FD:LevelChanged("player")
        elseif event == "PLAYER_REGEN_DISABLED" then
            FD.Wow:ClearOutgoing("combat; rated detection unavailable")
            FD.Wow:ClearIncoming("combat; native duel retained")
            local m = FD.duel.active
            if m and not m.countdownAt then
                FD.duel:Unrate("combat began during negotiation", true)
                -- Keep our ordinary accept/decline buttons usable if we hid
                -- the native popup earlier. No deferred popup hide in combat.
            end
        end
    end, ...)
end)

SLASH_FOREVERDUEL1 = "/duelrating"
SlashCmdList.FOREVERDUEL = function(text) FD:Safe(function() FD:Command(text) end) end
