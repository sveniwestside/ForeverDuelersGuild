local _, FD = ...

-- Queue wiring, meeting-place commands and the queue status section. Queue
-- failures stay inside the queue; ordinary rated duels never depend on them.
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

FD:RegisterCommand("queue", function(rest, rawRest)
    if FD.queue then FD.queue:Run(function() FD:QueueCommand(rest, rawRest) end)
    else FD.Debug:Print(FD.L["Queue unavailable on this installation."]) end
end, "Open the rated duel queue (queue help lists its commands).", 20)

FD:RegisterStatus(40, function()
    local lines = {}
    if FD.queue then
        local status = FD.queue:GetStatus()
        lines[#lines + 1] = "Queue: " .. status.state .. " | " .. status.reason
        lines[#lines + 1] = "Queue profiles: " .. status.discovered .. " known, " .. (status.freshProfiles or 0) .. " current"
            .. " | " .. (status.searchReason or "none")
        local details = status.searchDetails
        if details and details.ratingDifference then
            lines[#lines + 1] = "Queue rating difference: " .. details.ratingDifference .. " | both allow +/-"
                .. (details.allowedRatingDifference or 0)
        end
        if FD.QueueTransport.lastSend then lines[#lines + 1] = "Queue send: " .. FD.QueueTransport.lastSend end
        if FD.QueueTransport.lastReceive then lines[#lines + 1] = "Queue receive: " .. FD.QueueTransport.lastReceive end
    end
    if FD.QueueWow then
        local metadata = FD.QueueWow:MetadataDiagnostics()
        if metadata.mapID then
            lines[#lines + 1] = "Venue map: " .. metadata.mapID .. " | faction: " .. (metadata.faction or "unavailable")
            lines[#lines + 1] = "Venue territory: " .. (metadata.territoryResult or "not checked") .. " | "
                .. (metadata.territorySource or "not checked") .. " | " .. (metadata.territoryGetter or "not checked")
            lines[#lines + 1] = "Venue level range: " .. (metadata.zoneLevelsSource or "not checked")
        end
    end
    return lines
end)
