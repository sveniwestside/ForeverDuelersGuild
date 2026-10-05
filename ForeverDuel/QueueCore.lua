local _, FD = ...
local L = FD.L

-- Queue wiring, tested-place sharing, commands and the queue status section.
-- Queue failures stay inside the queue; ordinary rated duels never depend on
-- them, so every handler runs through FD.queue:Run rather than Core:Safe.
local function say(message) FD.Debug:Print(message) end

function FD:InitializeQueue()
    if self.queue or not self.Queue or not self.QueueWow or not self.QueueTransport then return end
    self.QueueTransport:Initialize()
    self.queue = self.Queue:New(self.QueueWow:Environment())
    self.QueueWow:InstallHooks()
    local function pulse()
        if self.queueStopped then return end
        self.queue:Run(function() self.queue:Tick() end)
        C_Timer.After(1, pulse)
    end
    C_Timer.After(1, pulse)
end

local function run(callback)
    if FD.queue then FD.queue:Run(callback) end
end

FD:OnEvent("CHAT_MSG_ADDON", function(prefix, payload, channel, sender)
    run(function() FD.QueueTransport:Receive(prefix, payload, channel, sender) end)
end)
-- A queue peer the server reports offline is no longer queried.
FD.Outbound:OnUnreachable(function(name) run(function() FD.queue:Unreachable(name) end) end)
FD:OnEvent("PLAYER_LEAVING_WORLD", function()
    run(function()
        FD.QueueWow:ObserveDuel("world")
        FD.queue:World(true)
    end)
end)
FD:OnEvent("PLAYER_ENTERING_WORLD", function() run(function() FD.queue:World(false) end) end)
-- PLAYER_LOGOUT also fires on /reload: the terminal CANCEL leaves now.
FD:OnEvent("PLAYER_LOGOUT", function()
    run(function() FD.queue:Logout() end)
    FD.queueStopped = true
end)
FD:OnEvent("DUEL_FINISHED", function() run(function() FD.QueueWow:ObserveDuel("finished") end) end)
FD:OnEvent("CHAT_MSG_SYSTEM", function(message)
    run(function()
        if not FD.Wow:Readable(message) or type(message) ~= "string" then return end
        FD.queue:SystemMessage(message)
        local seconds = FD.Results:Countdown(message, DUEL_COUNTDOWN)
        if seconds then FD.QueueWow:ObserveDuel("countdown", seconds)
        else FD.QueueWow:ObserveDuel("result", message) end
    end)
end)
-- Payload: name, isTank, isHealer, isDamage, isNativeRealm, allowMultipleRoles,
-- inviterGUID, questSessionActive (pinned PartyInfoDocumentation).
FD:OnEvent("PARTY_INVITE_REQUEST", function(...)
    local guid = select(7, ...)
    run(function()
        if FD.QueueWow:InviteRequested(guid) then FD.queue:InviteRequest(guid) end
    end)
end, false, true)
-- The inviter rescinded the invitation or it expired (pinned PartyInfo
-- documentation; FrameXML hides the dialog). A late PROFILE must not revive it.
FD:OnEvent("PARTY_INVITE_CANCEL", function()
    run(function() FD.queue:InviteClosed(FD.QueueWow:InviteClosed(false), true) end)
end, false, true)
-- Group formation and cleanup react to the roster at once; travel checks
-- keep their one-second sampling pulse.
local ROSTER_STATES = { INVITING = true, INVITED = true, CLEANUP = true }
FD:OnEvent("GROUP_ROSTER_UPDATE", function()
    run(function()
        if ROSTER_STATES[FD.queue.state] then FD.queue:Tick() end
        -- A leftover queue pair group can become exactly the pair again (the
        -- Leave group button) or dissolve (the advisory) in any state.
        if FD.queue.lastPair then FD.QueueUI:RefreshIfShown() end
    end)
end, false, true)

local REJECTIONS = {
    NO_TEST = "they have no matching recent test duel here",
    MISMATCH = "the place does not match their own test duel",
    METADATA = "their zone information differs",
    TERRITORY = "the territory is not approved for their faction",
    BUSY = "their queue is in a match",
    HUB = "hubs cannot be shared automatically",
    FULL = "their tested-place list is full",
    INVALID = "the shared record was invalid",
}

local function share(record, peer)
    local packet = FD.QueueWow:VenuePacket(record, peer)
    if packet and FD.QueueTransport:Send(packet, peer.fullName) then
        FD.queueVenueShare = { venueID = record.id, target = peer.fullName }
        return true
    end
end

function FD:CaptureQueueVenue()
    if not self.queue or not self.QueueWow.CaptureVenue then return false, L["Meeting-place capture is unavailable."] end
    if self.queue.state ~= "IDLE" then return false, L["Leave the queue before saving a meeting place."] end
    local venue, peer = self.QueueWow:CaptureVenue()
    if not venue then return false, peer end
    local saved, kept = self.QueueWow:StoreVenue(venue)
    if not saved then return false, kept end
    local record = self.QueueWow:FindVenue(kept) or venue
    local shared = share(record, peer)
    self.Debug:Log("queue venue", "saved", shared and "sharing" or "local only")
    self.QueueUI:RefreshIfShown()
    -- "Saved on both clients" is reported only after the partner's ACK.
    local message = shared
        and self.Locale:Format("Saved %s here. Sending it to %s; waiting for their client to confirm.", record.name, peer.fullName)
        or self.Locale:Format("Saved %s here. Sharing is unavailable; %s can save the same spot.", record.name, peer.fullName)
    say(message)
    return true, message
end

function FD:ReceiveQueueVenue(packet, sender)
    local accepted, reason, code, kept
    local state = self.queue and self.queue.state
    if not self.queue or self.queue.ticket or state ~= "IDLE" and state ~= "SEARCHING" and state ~= "PAUSED" then
        accepted, reason, code = false, L["A reserved match cannot change its meeting-place catalog."], "BUSY"
    else
        accepted, reason, code, kept = self.QueueWow:AcceptVenue(packet, sender)
    end
    if not accepted then
        code = FD.QueueProtocol.VENUE_REJECTIONS[code] and code or "INVALID"
        self.QueueTransport:Send({ kind = "VENUE_REJECT", venueID = packet.venueID, reason = code }, sender)
        self.Debug:Log("queue venue", "rejected", code)
        say(self.Locale:Format("Could not save the place shared by %s: %s", sender, tostring(reason)))
        return false
    end
    self.QueueTransport:Send({ kind = "VENUE_ACK", venueID = packet.venueID, keptID = kept }, sender)
    if kept ~= packet.venueID then
        -- Our own record of this spot has the smaller ID: send it back so both
        -- catalogs converge on one ID.
        local record, proof = self.QueueWow:FindVenue(kept), self.QueueWow.venueTest
        if record and proof then share(record, proof.peer) end
    end
    self.Debug:Log("queue venue", "accepted")
    say(self.Locale:Format("Saved the tested meeting place shared by %s.", sender))
    self.QueueUI:RefreshIfShown()
    return true
end

-- VENUE, VENUE_ACK and VENUE_REJECT: setup packets outside the match flow.
function FD:ReceiveQueueSetup(packet, sender)
    if packet.kind == "VENUE" then return self:ReceiveQueueVenue(packet, sender) end
    local pending = self.queueVenueShare
    if not pending or pending.target ~= sender or pending.venueID ~= packet.venueID then return false end
    self.queueVenueShare = nil
    if packet.kind == "VENUE_ACK" then
        self.Debug:Log("queue venue", "acknowledged")
        say(packet.keptID == packet.venueID
            and self.Locale:Format("%s saved the same place; it is now on both clients.", sender)
            or self.Locale:Format("%s already had this place saved; both clients now use one shared record.", sender))
    else
        self.Debug:Log("queue venue", "rejected by partner", packet.reason)
        say(self.Locale:Format("%s could not save the place because %s.", sender, L[REJECTIONS[packet.reason]]))
    end
    self.QueueUI:RefreshIfShown()
    return true
end

local HELP = {
    "queue join | leave | status | autoaccept on|off; choose search scope and level difference in the queue window. Ruleset is detected automatically.",
    "Discovery uses reachable addon players. Both players must join the queue; the matched player with the lower character ID sends the group invitation.",
    "After completing a normal native duel at a safe outdoor spot, leave your group and click Save tested place there.",
    "The button reads map coordinates, faction and level information automatically and shares the place with your test opponent.",
    "Advanced manual capture after testing a safe ordinary duel:",
    "queue venue add <id> <minimum player level> <zone minimum level> <zone maximum level> [hub]",
    "This approves the current outdoor spot for your faction. Use hub only outside Stormwind (Alliance) or Orgrimmar (Horde).",
    "Copy the printed venue import command to the other client to install exactly the same coordinates.",
}

function FD:QueueVenueCommand(text)
    if self.queue.state ~= "IDLE" then say(L["Leave the queue before changing meeting places."]); return end
    local tokens = {}
    for token in text:gmatch("%S+") do tokens[#tokens + 1] = token end
    if tokens[1] ~= "venue" then say(L["Use /duelrating queue help."]); return end
    local stored = self.Database.data.settings.queue
    local venues = FD.Copy(stored and stored.venues or {})
    if tokens[2] == "remove" and #tokens == 3 then
        for index = #venues, 1, -1 do if venues[index].id == tokens[3] then table.remove(venues, index) end end
        local s = self.QueueWow:Settings(); s.venues = venues; self.QueueWow:Save(s)
        say(self.Locale:Format("Removed local duel place %s.", tokens[3])); return
    end
    local id, position, minimum, zoneMin, zoneMax, hub
    if tokens[2] == "add" and (#tokens == 6 or #tokens == 7) then
        id, minimum, zoneMin, zoneMax, hub = tokens[3], tonumber(tokens[4]), tonumber(tokens[5]), tonumber(tokens[6]), tokens[7]
        position = self.QueueWow:Position()
        local available, unavailableReason = self.QueueWow:Available()
        if not available or self.QueueWow:Combat() then
            say(unavailableReason or L["Capture duel places while outside combat."]); return
        end
        local friendly, territoryReason = self.QueueWow:FriendlyTerritory()
        if not friendly then say(territoryReason); return end
    elseif tokens[2] == "import" and (#tokens == 9 or #tokens == 10) then
        id, minimum, zoneMin, zoneMax, hub = tokens[3], tonumber(tokens[7]), tonumber(tokens[8]), tonumber(tokens[9]), tokens[10]
        local mapID, mapX, mapY = tonumber(tokens[4]), tonumber(tokens[5]), tonumber(tokens[6])
        local continentID, x, y = self.QueueWow:World(mapID, mapX, mapY)
        if continentID then position = { mapID = mapID, mapX = mapX, mapY = mapY, continentID = continentID, x = x, y = y } end
    else say(L["Use /duelrating queue help for venue setup."]); return end
    local function level(n) return type(n) == "number" and n % 1 == 0 and n >= 1 and n <= 255 end
    if not position or not id or #id > 48 or not id:match("^[a-z0-9_.%-]+$")
        or not level(minimum) or not level(zoneMin) or not level(zoneMax) or zoneMin > zoneMax
        or hub and hub ~= "hub" then say(L["Invalid duel place coordinates or level metadata."]); return end
    local identity = self.QueueWow:Own()
    if not identity then say(L["Readable character faction is required."]); return end
    position.mapX, position.mapY = tonumber(string.format("%.8f", position.mapX)), tonumber(string.format("%.8f", position.mapY))
    local normalizedContinent = self.QueueWow:World(position.mapID, position.mapX, position.mapY)
    if normalizedContinent == nil then say(L["Normalized place coordinates could not be converted."]); return end
    position.continentID = normalizedContinent
    local venue = { id = id, name = id, mapID = position.mapID, mapX = position.mapX, mapY = position.mapY,
        continentID = position.continentID, factions = { [identity.faction] = true }, minPlayerLevel = minimum,
        zoneMinLevel = zoneMin, zoneMaxLevel = zoneMax, verified = true, duelAllowed = true,
        hubFaction = hub and identity.faction or nil }
    for index = #venues, 1, -1 do if venues[index].id == id then table.remove(venues, index) end end
    venues[#venues + 1] = venue
    local s = self.QueueWow:Settings(); s.venues = venues; self.QueueWow:Save(s)
    say(self.Locale:Format("Recorded your tested duel place %s. Both clients need this same record:", id))
    say(string.format("/duelrating queue venue import %s %d %.8f %.8f %d %d %d%s", id, venue.mapID,
        venue.mapX, venue.mapY, minimum, zoneMin, zoneMax, hub and " hub" or ""))
end

function FD:QueueCommand(text)
    if text == "" then self.QueueUI:Toggle(); return end
    if text == "help" then
        for _, line in ipairs(HELP) do say(L[line]) end
        return
    end
    if text == "join" then
        local ok, reason = self.queue:Join()
        say(ok and L["Joined the rated duel queue."] or reason)
        self.QueueUI:Show(); return
    elseif text == "leave" then self.queue:Leave(); say(L["Left the queue."]); return
    elseif text == "autoaccept on" or text == "autoaccept off" then
        self.queue:Configure({ autoAcceptQueueInvite = text == "autoaccept on" })
        say(text == "autoaccept on" and L["Queue group invitations from your matched opponent are accepted automatically."]
            or L["Queue group invitations must be accepted in Blizzard's dialog."])
        return
    elseif text == "status" then
        for _, line in ipairs(FD:QueueStatusLines()) do say(line) end
        return
    end
    self:QueueVenueCommand(text)
end

function FD:QueueStatusLines()
    local lines = {}
    local function Format(...) return self.Locale:Format(...) end
    if self.queue then
        local s = self.queue:GetStatus()
        lines[#lines + 1] = Format("Queue: %s | %s", s.state, tostring(s.reason))
        if s.cancel then
            lines[#lines + 1] = Format("Last queue cancellation: %s (%s) | %s", s.cancel.reason,
                s.cancel.received and L["opponent's client"] or L["this client"], s.cancel.outcome)
        end
        if s.cleanupStatus then lines[#lines + 1] = Format("Queue cleanup: %s", s.cleanupStatus) end
        lines[#lines + 1] = Format("Ruleset: %s | Scope: %s | Level gap: %d | Rating window: +/-%d",
            s.settings.ruleset or L["waiting for native detection"], s.settings.scope, s.settings.levelGap, s.ratingWindow)
        lines[#lines + 1] = Format("Queue profiles: %d known, %d current | Meeting places: %d | %s",
            s.discovered, s.freshProfiles or 0, s.venueCount, s.searchReason or "-")
        local details = s.searchDetails
        if details and details.ratingDifference then
            lines[#lines + 1] = Format("Queue rating difference: %d | both allow +/-%d", details.ratingDifference, details.allowedRatingDifference or 0)
        end
        if s.opponent then lines[#lines + 1] = Format("Opponent: %s | %s", s.opponent.fullName, s.coordinator and L["you request the duel"] or L["they request the duel"]) end
        if s.venue then lines[#lines + 1] = Format("Place: %s | Map: %d", s.venue.name, s.venue.mapID) end
        if self.Presence then lines[#lines + 1] = Format("Discovery: %s", tostring(self.Presence:GetStatus())) end
        if self.QueueTransport.lastSend then lines[#lines + 1] = Format("Queue send: %s", self.QueueTransport.lastSend) end
        if self.QueueTransport.lastReceive then lines[#lines + 1] = Format("Queue receive: %s", self.QueueTransport.lastReceive) end
    end
    if self.QueueWow then
        local metadata = self.QueueWow:MetadataDiagnostics()
        if metadata.mapID then
            lines[#lines + 1] = Format("Venue map: %s | faction: %s", tostring(metadata.mapID), tostring(metadata.faction or L["unavailable"]))
            lines[#lines + 1] = Format("Venue territory: %s | %s | %s", tostring(metadata.territoryResult or "-"),
                tostring(metadata.territorySource or "-"), tostring(metadata.territoryGetter or "-"))
            lines[#lines + 1] = Format("Venue level range: %s", tostring(metadata.zoneLevelsSource or "-"))
        end
    end
    return lines
end

FD:RegisterCommand("queue", function(rest)
    if FD.queue then FD.queue:Run(function() FD:QueueCommand(rest) end)
    else say(L["Queue unavailable on this installation."]) end
end, "Open the rated duel queue (queue help lists its commands).", 20)

FD:RegisterStatus(40, function() return FD:QueueStatusLines() end)
