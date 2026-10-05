local _, FD = ...

FD.QueueTransport = { queue = {}, lastAttempt = -math.huge, partyUnavailable = false }
local Transport = FD.QueueTransport
local PREFIX, PACE, LIMIT, TTL = "ForeverDuelQ1", 0.2, 64, 10
local ticketKinds = { OFFER = true, ACK = true, COMMIT = true, CONFIRM = true,
    GROUP = true, POSITION = true, PLAN = true, PLAN_ACK = true, GO = true,
    GO_ACK = true, ARRIVED = true, READY = true, CANCEL = true }

local function readable(...)
    return FD.Wow and FD.Wow:Readable(...)
end

local function validName(value)
    return readable(value) and type(value) == "string" and #value > 0 and #value <= 128
        and not value:find("[%c|]")
end

local function now()
    if type(GetTime) ~= "function" then return 0 end
    local value = GetTime()
    return readable(value) and type(value) == "number" and value or 0
end

local function log(...)
    if FD.Debug then pcall(FD.Debug.Log, FD.Debug, ...) end
end

function Transport:NormalizeSender(sender)
    if not validName(sender) then return nil end
    local regional = false
    if type(RegionalUniqueNamesEnabled) == "function" then
        local ok, value = pcall(RegionalUniqueNamesEnabled)
        if not ok or not readable(value) then return nil end
        regional = value
    end
    if not regional and not sender:find("-", 1, true) then
        if type(GetNormalizedRealmName) ~= "function" then return nil end
        local ok, realm = pcall(GetNormalizedRealmName)
        if not ok or not validName(realm) then return nil end
        sender = sender .. "-" .. realm
    end
    if validName(sender) then return sender end
end

function Transport:KnownPlayer(sender)
    if not FD.Presence or FD.Presence.suspended or type(FD.Presence.players) ~= "table" then return nil end
    for guid in pairs(FD.Presence.players) do
        local player = FD.Presence:GetPlayer(guid)
        if player and readable(player.fullName) and player.fullName == sender then return player end
    end
end

function Transport:TicketMatches(packet, ticket, outgoing)
    if not ticketKinds[packet.kind] or type(ticket) ~= "table"
        or not readable(ticket.id, ticket.ownSession, ticket.peerSession) then return false end
    return packet.ticket == ticket.id
        and packet.session == (outgoing and ticket.ownSession or ticket.peerSession)
        and packet.peerSession == (outgoing and ticket.peerSession or ticket.ownSession)
end

function Transport:ExactTicketParty(ticket, target)
    local ok, own, peer = pcall(function()
        local engine = FD.queue
        if type(ticket) ~= "table" or not engine or type(engine.ownProfile) ~= "table"
            or type(ticket.player) ~= "table" or type(ticket.peer) ~= "table"
            or type(IsInGroup) ~= "function" or type(IsInRaid) ~= "function"
            or type(GetNumGroupMembers) ~= "function" or not FD.Wow
            or type(FD.Wow.Identity) ~= "function" then return nil end
        if not readable(engine.ownProfile.guid, ticket.player.guid, ticket.peer.guid, ticket.peer.fullName, target)
            or not FD.QueueProtocol:ValidGUID(engine.ownProfile.guid)
            or not FD.QueueProtocol:ValidGUID(ticket.peer.guid)
            or ticket.player.guid ~= engine.ownProfile.guid
            or ticket.peer.guid == engine.ownProfile.guid
            or not validName(ticket.peer.fullName)
            or target ~= nil and target ~= ticket.peer.fullName then return nil end
        local grouped, raid, count = IsInGroup(), IsInRaid(), GetNumGroupMembers()
        if not readable(grouped, raid, count) or grouped ~= true or raid ~= false or count ~= 2 then return nil end
        local nativeOwn, nativePeer = FD.Wow:Identity("player", true), FD.Wow:Identity("party1")
        if type(nativeOwn) ~= "table" or type(nativePeer) ~= "table"
            or not readable(nativeOwn.guid, nativeOwn.fullName, nativePeer.guid, nativePeer.fullName)
            or not validName(nativeOwn.fullName) or not validName(nativePeer.fullName)
            or nativeOwn.guid ~= engine.ownProfile.guid or nativePeer.guid ~= ticket.peer.guid
            or nativePeer.fullName ~= ticket.peer.fullName then return nil end
        return nativeOwn, nativePeer
    end)
    if ok and own and peer then return own, peer end
end

function Transport:PartyTicket(packet, owner)
    local engine = FD.queue
    if not engine or type(owner) ~= "table" or not self:TicketMatches(packet, owner, true) then return nil end
    -- Only an original terminal cancellation may drain after ticket retirement.
    -- Native membership and the current character are still checked at drain.
    if owner ~= engine.ticket and packet.kind ~= "CANCEL" then return nil end
    return owner
end

function Transport:Initialize()
    self.queue, self.lastAttempt = {}, -math.huge
    if not C_ChatInfo or type(C_ChatInfo.RegisterAddonMessagePrefix) ~= "function" then self.available = false; return false end
    local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    local values = Enum and Enum.RegisterAddonMessagePrefixResult
    self.available = ok and readable(result) and values ~= nil
        and (result == values.Success or result == values.DuplicatePrefix)
    log("queue prefix registration", self.available and "available" or "unavailable")
    return self.available
end

function Transport:Recipient(target, packet)
    if not validName(target) then return false end
    if packet.kind == "VENUE" then
        local proof = FD.QueueWow and FD.QueueWow.venueTest
        return proof and type(proof.peer) == "table" and readable(proof.peer.fullName, proof.peer.guid)
            and proof.peer.fullName == target and proof.peer.guid == packet.testPairGUID or false
    end
    if self:KnownPlayer(target) then return true end
    local ticket = FD.queue and FD.queue.ticket
    return packet.kind ~= "QUERY" and ticket and type(ticket.peer) == "table"
        and readable(ticket.peer.fullName) and ticket.peer.fullName == target
end

function Transport:Send(packet, target, owner)
    if not self.available or type(packet) ~= "table" or not FD.QueueProtocol
        or #self.queue >= LIMIT then return false end
    for key, value in pairs(packet) do if not readable(key, value) then return false end end
    if not self:Recipient(target, packet) then return false end
    local ok, payload, reason = pcall(FD.QueueProtocol.Encode, FD.QueueProtocol, packet)
    if not ok or not payload then log("queue encode rejected", readable(reason) and reason or "restricted data"); return false end
    -- Store immutable wire bytes, not caller-owned profile/ticket tables.
    self.queue[#self.queue + 1] = { payload = payload, target = target, queuedAt = now(), owner = owner }
    self:Schedule()
    return true
end

function Transport:Current(packet, owner)
    if packet.kind == "VENUE" then
        if not FD.QueueWow or type(FD.QueueWow.CaptureStatus) ~= "function" then return false end
        local ok, current = pcall(FD.QueueWow.CaptureStatus, FD.QueueWow, true)
        return ok and current == true
    end
    if packet.kind == "QUERY" or packet.kind == "LEAVE" then return true end
    if packet.kind == "CANCEL" then
        return self:TicketMatches(packet, owner or FD.queue and FD.queue.ticket, true)
    end
    local engine = FD.queue
    if not engine or engine.session ~= packet.session then return false end
    if packet.kind == "PROFILE" then return engine.state == "SEARCHING" or engine.state == "PAUSED" end
    local ticket = engine.ticket
    if owner ~= nil and owner ~= ticket then return false end
    return ticket and ticket.id == packet.ticket and ticket.ownSession == packet.session
        and ticket.peerSession == packet.peerSession
end

function Transport:Schedule()
    if self.scheduled or #self.queue == 0 or not C_Timer or type(C_Timer.After) ~= "function" then return end
    self.scheduled = true
    C_Timer.After(PACE, function()
        self.scheduled = false
        local ok, err = pcall(self.Tick, self)
        if not ok then log("queue transport error", readable(err) and err or "restricted error") end
        self:Schedule()
    end)
end

function Transport:Tick()
    if not self.available or not C_ChatInfo or type(C_ChatInfo.SendAddonMessage) ~= "function" then return end
    local at = now()
    if at - self.lastAttempt < PACE then return end
    local item = table.remove(self.queue, 1)
    if not item then return end
    self.lastAttempt = at
    if at - item.queuedAt >= TTL then return end
    local packet = FD.QueueProtocol:Decode(item.payload)
    if not packet or not self:Current(packet, item.owner) then return end
    if ticketKinds[packet.kind] then
        local intended = packet.kind == "CANCEL" and item.owner or FD.queue and FD.queue.ticket
        if not intended or type(intended.peer) ~= "table" or item.target ~= intended.peer.fullName then return end
    end
    if not self:Recipient(item.target, packet) then
        -- A cancellation/leave already bound to a queued peer may drain after
        -- ticket cleanup and profile expiry; it can never reserve a new match.
        if packet.kind ~= "CANCEL" and packet.kind ~= "LEAVE" then return end
    end
    local ticket = self:PartyTicket(packet, item.owner)
    local route = not self.partyUnavailable and ticket and self:ExactTicketParty(ticket, item.target)
        and "PARTY" or "WHISPER"
    local target = route == "WHISPER" and item.target or nil
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.payload, route, target)
    local values = Enum and Enum.SendAddonMessageResult
    local function remember(fallback)
        local safe = ok and readable(result)
        local code = not ok and "Lua error" or not safe and "restricted" or tostring(result)
        local success = safe and values and result == values.Success
        self.lastSend = packet.kind .. " to " .. item.target .. " via " .. route .. " (" .. code
            .. "; " .. (success and "submitted" or "rejected") .. ")" .. (fallback or "")
        self.lastSendAt, self.lastSendRoute = at, route
        self.lastSendResultCode = safe and type(result) == "number" and result or nil
        log("queue send", self.lastSend, "at", at)
    end
    remember()
    local safe = ok and readable(result)
    local unsupported = route == "PARTY" and safe and values
        and type(values.InvalidChatType) == "number" and result == values.InvalidChatType
    local notGrouped = route == "PARTY" and safe and values
        and type(values.NotInGroup) == "number" and result == values.NotInGroup
    if unsupported or notGrouped then
        if unsupported then self.partyUnavailable = true end
        local reason = unsupported and "InvalidChatType" or "NotInGroup"
        route = "WHISPER"
        ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.payload, route, item.target)
        remember(" | PARTY rejected: " .. reason)
    end
end

function Transport:Receive(prefix, payload, channel, sender)
    if not self.available or not FD.QueueProtocol
        or not readable(prefix, payload, channel, sender) or prefix ~= PREFIX
        or (channel ~= "WHISPER" and channel ~= "PARTY") then return false end
    local packet = FD.QueueProtocol:Decode(payload)
    sender = self:NormalizeSender(sender)
    if not packet or not sender then return false end
    if channel == "PARTY" then
        local ticket = FD.queue and FD.queue.ticket
        if not self:TicketMatches(packet, ticket, false) then return false end
        local own, peer = self:ExactTicketParty(ticket)
        if not own or sender ~= peer.fullName then return false end
        -- Exact native ticket context supplies the transport identity even
        -- while zone presence is unavailable after a loading transition.
        self.lastReceive = packet.kind .. " from " .. sender .. " via PARTY"
        self.lastReceiveAt, self.lastReceiveRoute = now(), channel
        log("queue receive", self.lastReceive, "at", self.lastReceiveAt)
        local ok, result = pcall(FD.queue.Receive, FD.queue, packet, sender)
        if not ok then log("queue receive error", readable(result) and result or "restricted error"); return false end
        return true
    end
    local known = self:KnownPlayer(sender)
    if packet.kind == "VENUE" then
        local proof = FD.QueueWow and FD.QueueWow.venueTest
        if not known and not (proof and proof.peer.fullName == sender) then return false end
        if type(FD.ReceiveQueueVenue) ~= "function" then return false end
        self.lastReceive = packet.kind .. " from " .. sender
        self.lastReceiveAt, self.lastReceiveRoute = now(), channel
        log("queue receive", self.lastReceive, "at", self.lastReceiveAt)
        local ok, result, reason = pcall(FD.ReceiveQueueVenue, FD, packet, sender)
        if not ok then log("queue venue receive error", readable(result) and result or "restricted error"); return false end
        if result ~= true then log("queue venue receive rejected", readable(reason) and reason or "proof unavailable"); return false end
        return true
    end
    if not FD.queue then return false end
    local ticket = FD.queue.ticket
    local activePeer = ticket and type(ticket.peer) == "table" and ticket.peer.fullName == sender
    if packet.kind == "QUERY" and not known or not known and not activePeer then return false end
    if packet.guid and (not known or packet.guid ~= known.guid) then return false end
    self.lastReceive = packet.kind .. " from " .. sender .. " via WHISPER"
    self.lastReceiveAt, self.lastReceiveRoute = now(), channel
    log("queue receive", self.lastReceive, "at", self.lastReceiveAt)
    -- Queue errors stay within this subsystem and never call Core:Safe.
    local ok, result = pcall(FD.queue.Receive, FD.queue, packet, sender)
    if not ok then log("queue receive error", readable(result) and result or "restricted error"); return false end
    return true
end
