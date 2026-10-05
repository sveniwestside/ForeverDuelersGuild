local addonName, FD = ...

function FD:Safe(callback, ...)
    local ok, errorText = pcall(callback, ...)
    if ok then return end
    local m = self.duel and self.duel.active
    -- Error recovery must not depend on the failing render/transport callback.
    if self.duel then self.duel.active = nil end
    if self.Wow then
        local deadline = math.max(self.Wow.outgoingBlockedUntil or 0,
            self.Wow.outgoing and self.Wow.outgoing.at + self.C.OUTGOING_TIMEOUT or 0)
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
    self:InitializeQueue()
end

function FD:InitializeQueue()
    if not self.Queue or not self.QueueWow or not self.QueueTransport then return end
    local ok, err = pcall(function()
        self.QueueTransport:Initialize()
        self.queue = self.Queue:New(self.QueueWow:Environment())
        local queueFrame = CreateFrame("Frame")
        for _, event in ipairs({ "CHAT_MSG_ADDON", "PLAYER_LEAVING_WORLD", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT",
            "DUEL_FINISHED", "CHAT_MSG_SYSTEM" }) do
            queueFrame:RegisterEvent(event)
        end
        queueFrame:SetScript("OnEvent", function(_, event, ...)
            local args, count = { ... }, select("#", ...)
            self.queue:Run(function()
                if event == "CHAT_MSG_ADDON" then self.QueueTransport:Receive(unpack(args, 1, count))
                elseif event == "PLAYER_LOGOUT" then self.queueStopped = true; self.queue:World(true, true)
                elseif event == "PLAYER_LEAVING_WORLD" or event == "PLAYER_ENTERING_WORLD" then
                    if event == "PLAYER_LEAVING_WORLD" and self.QueueWow.ObserveDuel then self.QueueWow:ObserveDuel("world") end
                    self.queue:World(event == "PLAYER_LEAVING_WORLD", false)
                elseif self.QueueWow.ObserveDuel then
                    if event == "DUEL_FINISHED" then self.QueueWow:ObserveDuel("finished", args[1])
                    else
                        local message = args[1]
                        if self.Wow:Readable(message) and type(message) == "string" then
                            local seconds = self.Results:Countdown(message, DUEL_COUNTDOWN)
                            if seconds then self.QueueWow:ObserveDuel("countdown", seconds)
                            else self.QueueWow:ObserveDuel("result", message) end
                        end
                    end
                end
            end)
        end)
        self.queueFrame = queueFrame
        local function pulse()
            if self.queueStopped then return end
            self.queue:Run(function() self.queue:Tick() end)
            C_Timer.After(1, pulse)
        end
        C_Timer.After(1, pulse)
    end)
    if not ok then
        self.Debug:Print("Queue unavailable; ordinary rated duels remain available.")
        if self.Wow:Readable(err) then self.Debug:Log("queue initialization", err) end
    end
end

function FD:CaptureQueueVenue()
    if not self.queue or not self.QueueWow.CaptureVenue then return false, "Meeting-place capture is unavailable." end
    if self.queue.state ~= "IDLE" then return false, "Leave the queue before saving a meeting place." end
    local venue, peer = self.QueueWow:CaptureVenue()
    if not venue then return false, peer end
    local saved, reason = self.QueueWow:StoreVenue(venue)
    if not saved then return false, reason end
    local packet = { kind = "VENUE", venueID = venue.id, testPairGUID = peer.guid,
        mapID = venue.mapID, continentID = venue.continentID,
        mapX = math.floor(venue.mapX * 100000000 + 0.5), mapY = math.floor(venue.mapY * 100000000 + 0.5),
        minPlayerLevel = venue.minPlayerLevel, zoneMinLevel = venue.zoneMinLevel, zoneMaxLevel = venue.zoneMaxLevel,
        faction = venue.factions.Alliance and "Alliance" or "Horde", hubFaction = venue.hubFaction or "NONE",
        testedAt = GetServerTime() }
    local shared = self.QueueTransport:Send(packet, peer.fullName)
    self.QueueUI:RefreshIfShown()
    local message = "Saved " .. venue.name .. ". " .. (shared and "Sending the same place to " .. peer.fullName .. "."
        or "Sharing is unavailable; your test opponent can save the same spot or import its coordinates.")
    self.Debug:Print(message)
    return true, message
end

function FD:ReceiveQueueVenue(packet, sender)
    if not self.queue or self.queue.ticket or (self.queue.state ~= "IDLE"
        and self.queue.state ~= "SEARCHING" and self.queue.state ~= "PAUSED") then
        return false, "A reserved match cannot change its meeting-place catalog."
    end
    local accepted, reason = self.QueueWow:AcceptVenue(packet, sender)
    if accepted then
        self.Debug:Print("Saved the same tested meeting place from " .. sender .. ".")
        self.QueueUI:RefreshIfShown()
    end
    return accepted, reason
end

function FD:QueueCommand(text)
    if not self.queue then self.Debug:Print("Queue unavailable on this installation."); return end
    local function say(message) self.Debug:Print(message) end
    if text == "" then self.QueueUI:Toggle(); return end
    if text == "help" then
        say("queue join | leave | status; choose search scope and level difference in the queue window. Ruleset is detected automatically.")
        say("Discovery uses reachable addon players; wider scopes are available immediately. Both players must join the queue.")
        say("After completing a normal native duel at a safe outdoor spot, leave your group and click Save tested place there.")
        say("The button reads map coordinates, faction and level information automatically and shares the place with your test opponent.")
        say("Advanced manual capture after testing a safe ordinary duel:")
        say("queue venue add <id> <minimum player level> <zone minimum level> <zone maximum level> [hub]")
        say("This approves the current outdoor spot for your faction. Use hub only outside Stormwind (Alliance) or Orgrimmar (Horde).")
        say("Copy the printed venue import command to the other client to install exactly the same coordinates.")
        return
    end
    if text == "join" then
        local ok, reason = self.queue:Join()
        if not ok then say(reason) else say("Joined the rated duel queue.") end
        self.QueueUI:Show(); return
    elseif text == "leave" then self.queue:Leave(); say("Left the queue."); return
    elseif text == "status" then
        local s = self.queue:GetStatus()
        say("Queue: " .. s.state .. " | " .. s.reason)
        say("Ruleset: " .. (s.settings.ruleset or "waiting for native detection") .. " | Scope: " .. s.settings.scope
            .. " | Level gap: " .. s.settings.levelGap .. " | Rating window: +/-" .. s.ratingWindow)
        say("Queue profiles: " .. s.discovered .. " | Meeting places: " .. s.venueCount)
        if self.Presence then say("Discovery: " .. self.Presence:GetStatus()) end
        if s.opponent then say("Opponent: " .. s.opponent.fullName) end
        if s.venue then say("Place: " .. s.venue.name .. " | Map: " .. s.venue.mapID .. " | Deadline: " .. (s.deadline or 0)) end
        if self.QueueTransport.lastSend then say("Queue send: " .. self.QueueTransport.lastSend) end
        if self.QueueTransport.lastReceive then say("Queue receive: " .. self.QueueTransport.lastReceive) end
        return
    end
    if self.queue.state ~= "IDLE" then say("Leave the queue before changing meeting places."); return end
    local tokens = {}
    for token in text:gmatch("%S+") do tokens[#tokens + 1] = token end
    if tokens[1] ~= "venue" then say("Use /duelrating queue help."); return end
    local stored = self.Database.data.settings.queue
    local venues = FD.Copy(stored and stored.venues or {})
    if tokens[2] == "remove" and #tokens == 3 then
        for index = #venues, 1, -1 do if venues[index].id == tokens[3] then table.remove(venues, index) end end
        local s = self.QueueWow:Settings(); s.venues = venues; self.QueueWow:Save(s)
        say("Removed local duel place " .. tokens[3] .. "."); return
    end
    local id, position, minimum, zoneMin, zoneMax, hub
    if tokens[2] == "add" and (#tokens == 6 or #tokens == 7) then
        id, minimum, zoneMin, zoneMax, hub = tokens[3], tonumber(tokens[4]), tonumber(tokens[5]), tonumber(tokens[6]), tokens[7]
        position = self.QueueWow:Position()
        local available, unavailableReason = self.QueueWow:Available()
        if not available or self.QueueWow:Combat() then
            say(unavailableReason or "Capture duel places while outside combat."); return
        end
        local friendly, territoryReason = self.QueueWow:FriendlyTerritory()
        if not friendly then say(territoryReason); return end
    elseif tokens[2] == "import" and (#tokens == 9 or #tokens == 10) then
        id, minimum, zoneMin, zoneMax, hub = tokens[3], tonumber(tokens[7]), tonumber(tokens[8]), tonumber(tokens[9]), tokens[10]
        local mapID, mapX, mapY = tonumber(tokens[4]), tonumber(tokens[5]), tonumber(tokens[6])
        local continentID, x, y = self.QueueWow:World(mapID, mapX, mapY)
        if continentID then position = { mapID = mapID, mapX = mapX, mapY = mapY, continentID = continentID, x = x, y = y } end
    else say("Use /duelrating queue help for venue setup."); return end
    local function level(n) return type(n) == "number" and n % 1 == 0 and n >= 1 and n <= 255 end
    if not position or not id or #id > 48 or not id:match("^[a-z0-9_.%-]+$")
        or not level(minimum) or not level(zoneMin) or not level(zoneMax) or zoneMin > zoneMax
        or hub and hub ~= "hub" then say("Invalid duel place coordinates or level metadata."); return end
    local identity = self.QueueWow:Own()
    if not identity then say("Readable character faction is required."); return end
    position.mapX, position.mapY = tonumber(string.format("%.8f", position.mapX)), tonumber(string.format("%.8f", position.mapY))
    local normalizedContinent = self.QueueWow:World(position.mapID, position.mapX, position.mapY)
    if normalizedContinent == nil then say("Normalized place coordinates could not be converted."); return end
    position.continentID = normalizedContinent
    local venue = { id = id, name = id, mapID = position.mapID, mapX = position.mapX, mapY = position.mapY,
        continentID = position.continentID, factions = { [identity.faction] = true }, minPlayerLevel = minimum,
        zoneMinLevel = zoneMin, zoneMaxLevel = zoneMax, verified = true, duelAllowed = true,
        hubFaction = hub and identity.faction or nil }
    for index = #venues, 1, -1 do if venues[index].id == id then table.remove(venues, index) end end
    venues[#venues + 1] = venue
    local s = self.QueueWow:Settings(); s.venues = venues; self.QueueWow:Save(s)
    say("Recorded your tested duel place " .. id .. ". Both clients need this same record:")
    say(string.format("/duelrating queue venue import %s %d %.8f %.8f %d %d %d%s", id, venue.mapID,
        venue.mapX, venue.mapY, minimum, zoneMin, zoneMax, hub and " hub" or ""))
end

function FD:Command(text)
    text = (text or ""):lower():match("^%s*(.-)%s*$")
    if not self.Database.data then self.Debug:Print("Saved data unavailable; rating is disabled."); return end
    self.Database:SetBracket(self.Wow:Identity("player", true))
    if text == "queue" or text:sub(1, 6) == "queue " then
        if self.queue then self.queue:Run(function() self:QueueCommand(text == "queue" and "" or text:sub(7)) end)
        else self.Debug:Print("Queue unavailable on this installation.") end
    elseif text == "debug" then
        local settings = self.Database.data.settings
        settings.debug = not settings.debug
        self.Debug:Print("Debug " .. (settings.debug and "enabled." or "disabled."))
    elseif text == "diagnose" then
        local trace = self.Debug:RequestTrace()
        self.Debug:Print("Recent native request diagnostics: " .. #trace .. " entries (also recorded with debug disabled).")
        for _, entry in ipairs(trace) do
            local repeated = entry.repeats and string.format(" | repeated %d, last %d", entry.repeats, entry.lastAt) or ""
            self.Debug:Print((entry.version or "?") .. " | " .. (entry.at or 0) .. " | " .. entry.event .. " | " .. entry.detail .. repeated)
        end
    elseif text == "history" then self.UI:History(20)
    elseif text == "status" then
        local m = self.duel and self.duel.active
        local last = self.duel and self.duel.last
        if self.queue then
            local status = self.queue:GetStatus()
            self.Debug:Print("Queue: " .. status.state .. " | " .. status.reason)
            self.Debug:Print("Queue profiles: " .. status.discovered .. " known, " .. (status.freshProfiles or 0) .. " current"
                .. " | " .. (status.searchReason or "none"))
            local details = status.searchDetails
            if details and details.ratingDifference then
                self.Debug:Print("Queue rating difference: " .. details.ratingDifference .. " | both allow +/-"
                    .. (details.allowedRatingDifference or 0))
            end
        end
        self.Debug:Print("Version: " .. self.C.VERSION .. " | Addon transport: " .. (self.Comms.available and "registered" or "unavailable"))
        local loggedAvailable = self.Comms.loggedReceiveAvailable == true
            and C_ChatInfo and type(C_ChatInfo.SendAddonMessageLogged) == "function"
        self.Debug:Print("Solo alternate transport: " .. (loggedAvailable and "available" or "unavailable"))
        if self.Comms.loggedStatus and (not m or self.Comms.loggedStatusMatch == m) then
            self.Debug:Print((m and "Solo transport: " or "Last solo transport: ") .. self.Comms.loggedStatus)
        end
        if self.Comms.ingressStatus and (not m or self.Comms.ingressStatusMatch == m) then
            self.Debug:Print((m and "Native receive gates: " or "Last native receive gates: ") .. self.Comms.ingressStatus)
            local counts = self.Comms.ingressCounts
            if counts then self.Debug:Print(string.format("Native receive events: regular %d, logged %d, entry accepted %d, entry rejected %d",
                counts.normal, counts.logged, counts.passed, counts.rejected)) end
        end
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
        if self.QueueWow then
            local metadata = self.QueueWow:MetadataDiagnostics()
            if metadata.mapID then
                self.Debug:Print("Venue map: " .. metadata.mapID .. " | faction: " .. (metadata.faction or "unavailable"))
                self.Debug:Print("Venue territory: " .. (metadata.territoryResult or "not checked") .. " | "
                    .. (metadata.territorySource or "not checked") .. " | " .. (metadata.territoryGetter or "not checked"))
                self.Debug:Print("Venue level range: " .. (metadata.zoneLevelsSource or "not checked"))
            end
        end
        if self.Comms.lastSend then self.Debug:Print("Last send: " .. self.Comms.lastSend) end
        if self.Comms.lastReceive then self.Debug:Print("Last receive: " .. self.Comms.lastReceive) end
        if m and self.Comms.validationMatch ~= m then
            self.Debug:Print("Peer validation: no packet received for the current request")
        elseif self.Comms.lastValidation then
            self.Debug:Print("Peer validation: " .. self.Comms.lastValidation
                .. string.format(" | %.1fs ago", GetTime() - (self.Comms.lastValidationAt or GetTime())))
        end
        if self.Comms.lastRejection and self.Comms.lastRejection ~= self.Comms.lastValidation then
            self.Debug:Print("Last pending rejection: " .. self.Comms.lastRejection
                .. string.format(" | %.1fs ago", GetTime() - (self.Comms.lastRejectionAt or GetTime())))
        end
        if m then
            self.Debug:Print(string.format("Native request: %s | age %.1fs", m.role, GetTime() - m.createdAt))
            self.Debug:Print("Native self: " .. m.player.guid .. " | " .. m.player.classFile .. " | level "
                .. (m.player.level or "unknown") .. "/" .. (m.player.maxLevel or "unknown"))
            self.Debug:Print("Native opponent: " .. m.opponent.guid .. " | " .. m.opponent.classFile .. " | level "
                .. (m.opponent.level or "unknown") .. "/" .. (m.opponent.maxLevel or "unknown"))
            self.Debug:Print(m.role .. " | " .. m.opponent.fullName .. " | " .. (m.matchId or "checking addon") .. " | " .. (m.reason or m.state))
            self.Debug:Print("Peer confirmation: " .. (m.peerNonce and "bound to current request" or "waiting for current request acknowledgment"))
        end
        if last then self.Debug:Print("Last: " .. last.state .. " | " .. (last.reason or "") .. " | " .. (last.matchId or "")) end
    elseif text == "reset" then
        if self.queue and self.queue.state ~= "IDLE" then self.Debug:Print("Leave the queue before resetting."); return end
        if self.duel and self.duel.active then self.Debug:Print("Finish or cancel the pending duel before resetting."); return end
        self.resetUntil = GetTime() + 15
        self.Debug:Print("This deletes this character's rating and history. Type /duelrating reset confirm within 15 seconds.")
    elseif text == "reset confirm" then
        if self.queue and self.queue.state ~= "IDLE" then self.Debug:Print("Leave the queue before resetting."); return end
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
    else self.Debug:Print("/duelrating [ui | zone | queue | summary | history | status | diagnose | debug | reset]") end
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
-- Older clients can reject unknown events. Keep ordinary transport usable when
-- the optional logged-addon receive route is absent.
local loggedRegistered, loggedRegistrationResult = pcall(frame.RegisterEvent, frame, "CHAT_MSG_ADDON_LOGGED")
FD.Comms.loggedReceiveAvailable = loggedRegistered and loggedRegistrationResult ~= false
frame:SetScript("OnEvent", function(_, event, ...)
    FD:Safe(function(...)
        if event == "PLAYER_LOGIN" then FD:Initialize(); return end
        if not FD.duel then return end
        if event ~= "CHAT_MSG_ADDON" and event ~= "CHAT_MSG_ADDON_LOGGED" and event ~= "CHAT_MSG_SYSTEM" and event ~= "UI_INFO_MESSAGE" and event ~= "UI_ERROR_MESSAGE" then FD.Debug:Log("event", event) end
        if event == "DUEL_REQUESTED" then FD.Wow:Incoming(...)
        elseif event == "DUEL_FINISHED" then
            FD.Wow:ClearOutgoing("native duel finished", true)
            FD.Wow:ClearIncoming("native duel finished")
            FD.duel:Finished()
        elseif event == "CHAT_MSG_ADDON" or event == "CHAT_MSG_ADDON_LOGGED" then
            -- The native fifth field is the target, not a route flag.
            local prefix, payload, channel, sender = ...
            FD.Comms:Receive(prefix, payload, channel, sender, event == "CHAT_MSG_ADDON_LOGGED")
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
