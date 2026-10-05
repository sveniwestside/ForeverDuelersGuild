local _, FD = ...

-- Queue packets go through FD.Outbound: shared pacing and budgets, retries on
-- throttle, PARTY->WHISPER fallback. Ticket packets use PARTY only while the
-- exact ticket pair is grouped and are checked again at drain (isCurrent).
FD.QueueTransport = {}
local Transport = FD.QueueTransport
local Protocol = FD.QueueProtocol
local PREFIX = Protocol.PREFIX
local TTL = { QUERY = 8, PROFILE = 8, LEAVE = 10, CANCEL = 30, VENUE = 20, VENUE_ACK = 20, VENUE_REJECT = 20 }
-- Discovery is background traffic: it never takes the whisper budget that
-- match controls and the rated duel need.
local DISCOVERY = { QUERY = true, PROFILE = true, LEAVE = true }
-- A PROFILE stays current while it can still pair or re-key a ticket.
local PROFILE_STATES = { SEARCHING = true, PAUSED = true, INVITING = true, INVITED = true, GROUPING = true }

local function readable(...)
    return not FD.Wow or FD.Wow:Readable(...)
end

local function validName(value)
    return readable(value) and type(value) == "string" and #value > 0 and #value <= 128
        and not value:find("[%c|]")
end

local function now()
    if type(GetTime) ~= "function" then return 0 end
    local ok, value = pcall(GetTime)
    return ok and readable(value) and type(value) == "number" and value or 0
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
    if not FD.Presence or type(FD.Presence.FindByName) ~= "function" then return nil end
    local ok, player = pcall(FD.Presence.FindByName, FD.Presence, sender)
    if ok and type(player) == "table" and readable(player.fullName) and player.fullName == sender then return player end
end

-- A queue peer whose PROFILE was accepted earlier (while Presence knew it).
function Transport:QueuePeer(sender)
    local engine = FD.queue
    if not engine or type(engine.peers) ~= "table" then return nil end
    for _, peer in pairs(engine.peers) do if peer.fullName == sender then return peer end end
end

function Transport:TicketMatches(packet, ticket, outgoing)
    if not Protocol.TICKET_KINDS[packet.kind] or type(ticket) ~= "table"
        or not readable(ticket.id, ticket.ownSession, ticket.peerSession) then return false end
    return packet.ticket == ticket.id
        and packet.session == (outgoing and ticket.ownSession or ticket.peerSession)
        and packet.peerSession == (outgoing and ticket.peerSession or ticket.ownSession)
end

-- The PARTY channel is server-scoped to group members and the sender name is
-- authoritative; the ticket tuple and sender bind it. The one exception is an
-- OFFER (from the ticket peer while a ticket exists): a grouped invitee binds
-- or re-keys from it, or answers one naming its earlier session with its
-- current PROFILE. PARTY never discovers peers; the engine validates OFFERs.
function Transport:PartyAccepts(packet, sender, engine)
    engine = engine or FD.queue
    if type(engine) ~= "table" or not engine.session then return false end
    local ticket = engine.ticket
    if ticket and (type(ticket.peer) ~= "table" or sender ~= ticket.peer.fullName) then return false end
    return packet.kind == "OFFER" or ticket ~= nil and self:TicketMatches(packet, ticket, false)
end

function Transport:ExactTicketParty(ticket)
    return type(ticket) == "table" and type(ticket.peer) == "table" and FD.QueueWow ~= nil
        and FD.QueueWow:GroupState(ticket.peer) == "EXACT"
end

function Transport:Initialize()
    self.available = FD.Outbound and FD.Outbound:Register(PREFIX) or false
    return self.available
end

function Transport:Recipient(target, packet)
    if not validName(target) then return false end
    local proof = FD.QueueWow and FD.QueueWow.venueTest
    if Protocol.SETUP_KINDS[packet.kind] then
        if packet.kind ~= "VENUE" then return true end
        return proof and type(proof.peer) == "table" and readable(proof.peer.fullName, proof.peer.guid)
            and proof.peer.fullName == target and proof.peer.guid == packet.testPairGUID or false
    end
    if self:KnownPlayer(target) then return true end
    if packet.kind == "QUERY" then return false end
    local ticket = FD.queue and FD.queue.ticket
    return ticket and type(ticket.peer) == "table" and readable(ticket.peer.fullName) and ticket.peer.fullName == target
        or packet.kind == "CANCEL" or packet.kind == "LEAVE" and self:QueuePeer(target) ~= nil
end

-- A queued packet still describes the current queue session and ticket.
function Transport:Current(packet, owner)
    local kind, engine = packet.kind, FD.queue
    if kind == "VENUE" then
        if not FD.QueueWow or type(FD.QueueWow.CaptureStatus) ~= "function" then return false end
        local ok, current = pcall(FD.QueueWow.CaptureStatus, FD.QueueWow, true)
        return ok and current == true
    end
    -- Terminal and reply packets stay valid after their ticket ended.
    if kind == "QUERY" or kind == "LEAVE" or kind == "CANCEL" or Protocol.SETUP_KINDS[kind] then return true end
    if not engine or engine.session ~= packet.session then return false end
    if kind == "PROFILE" then return PROFILE_STATES[engine.state] == true end
    local ticket = engine.ticket
    return owner ~= nil and owner == ticket and self:TicketMatches(packet, ticket, true)
end

function Transport:Route(packet, owner, target)
    if Protocol.TICKET_KINDS[packet.kind] and type(owner) == "table" and type(owner.peer) == "table"
        and owner.peer.fullName == target and self:ExactTicketParty(owner) then return "PARTY" end
    return "WHISPER", target
end

function Transport:Remember(kind, target, route, status, code)
    self.lastSend = FD.Locale:Format("%s to %s via %s (%s)", kind, target, tostring(route), status)
    self.lastSendAt, self.lastSendRoute, self.lastSendStatus = now(), route, status
    log("queue send", kind, tostring(route), status, code ~= nil and tostring(code) or nil)
end

function Transport:Item(packet, target, owner, payload)
    local kind = packet.kind
    local key
    if Protocol.TICKET_KINDS[kind] and kind ~= "CANCEL" then key = kind .. ":" .. packet.ticket
    elseif kind == "QUERY" or kind == "PROFILE" or kind == "LEAVE" then key = kind .. ":" .. target
    elseif Protocol.SETUP_KINDS[kind] then key = kind .. ":" .. packet.venueID .. ":" .. target end
    local item = { prefix = PREFIX, payload = payload, channel = "WHISPER", target = target,
        priority = DISCOVERY[kind] and FD.Outbound.BACKGROUND or FD.Outbound.QUEUE,
        ttl = TTL[kind] or 10, key = key, owner = owner }
    item.isCurrent = function() return self:Current(packet, owner) end
    item.route = function()
        local channel, routeTarget = self:Route(packet, owner, target)
        item.lastRoute = channel
        return channel, routeTarget
    end
    item.onResult = function(status, code)
        self:Remember(kind, target, item.forceWhisper and "WHISPER" or item.lastRoute or "WHISPER", status, code)
    end
    return item
end

local function encode(self, packet, target)
    if not self.available or type(packet) ~= "table" or not FD.Outbound then return nil end
    for key, value in pairs(packet) do if not readable(key, value) then return nil end end
    if not self:Recipient(target, packet) then return nil end
    local ok, payload, reason = pcall(Protocol.Encode, Protocol, packet)
    if not ok or not payload then
        log("transport rejected", "queue encode", readable(reason) and reason or "restricted data")
        return nil
    end
    return payload
end

function Transport:Send(packet, target, owner)
    local payload = encode(self, packet, target)
    if not payload then return false end
    return FD.Outbound:Send(self:Item(packet, target, owner, payload))
end

-- Terminal CANCEL: submitted synchronously on PARTY (while the pair group
-- still exists) and on WHISPER; a throttled or failed copy is queued for
-- retry with control priority instead of being dropped.
function Transport:SendNow(packet, target, owner)
    local payload = encode(self, packet, target)
    if not payload then return false end
    local sent = false
    local routes = { "WHISPER" }
    if self:Route(packet, owner, target) == "PARTY" then table.insert(routes, 1, "PARTY") end
    for _, channel in ipairs(routes) do
        local item = self:Item(packet, target, owner, payload)
        item.channel, item.noWhisperFallback, item.route, item.onResult = channel, channel == "PARTY", nil, nil
        local status, code = FD.Outbound:SendNow(item)
        self:Remember(packet.kind, target, channel, status, code)
        if status == "sent" then sent = true
        elseif channel == "WHISPER" then
            item.priority, item.isCurrent = FD.Outbound.CONTROL, function() return true end
            FD.Outbound:Send(item)
        end
    end
    return sent
end

function Transport:Deliver(packet, sender, channel)
    self.lastReceive = FD.Locale:Format("%s from %s via %s", packet.kind, sender, channel)
    self.lastReceiveAt, self.lastReceiveRoute = now(), channel
    log("queue receive", packet.kind, channel)
    -- Queue errors stay within this subsystem (Queue:Run) and never reach
    -- Core:Safe's rated-duel recovery.
    return FD.queue:Run(function() FD.queue:Receive(packet, sender); return true end) == true
end

function Transport:Receive(prefix, payload, channel, sender)
    if not self.available or not readable(prefix, payload, channel, sender) or prefix ~= PREFIX
        or (channel ~= "WHISPER" and channel ~= "PARTY") then return false end
    local packet = Protocol:Decode(payload)
    sender = self:NormalizeSender(sender)
    if not packet or not sender then return false end
    if channel == "PARTY" then
        if not self:PartyAccepts(packet, sender) then return false end
        return self:Deliver(packet, sender, channel)
    end
    local known = self:KnownPlayer(sender)
    if Protocol.SETUP_KINDS[packet.kind] then
        local proof, share = FD.QueueWow and FD.QueueWow.venueTest, FD.queueVenueShare
        if not known and not (proof and proof.peer.fullName == sender) and not (share and share.target == sender) then return false end
        if type(FD.ReceiveQueueSetup) ~= "function" then return false end
        self.lastReceive = FD.Locale:Format("%s from %s", packet.kind, sender)
        self.lastReceiveAt, self.lastReceiveRoute = now(), channel
        log("queue receive", packet.kind, channel)
        local ok, result = pcall(FD.ReceiveQueueSetup, FD, packet, sender)
        if not ok then
            if FD.Debug and FD.Debug.Error then pcall(FD.Debug.Error, FD.Debug, "queue venue", readable(result) and result or "restricted error") end
            return false
        end
        return result == true
    end
    if not FD.queue then return false end
    local ticket = FD.queue.ticket
    local activePeer = ticket and type(ticket.peer) == "table" and ticket.peer.fullName == sender
    local queuePeer = self:QueuePeer(sender)
    if packet.kind == "QUERY" or packet.kind == "PROFILE" then
        if not known then return false end
    elseif not known and not activePeer and not queuePeer then return false end
    if packet.guid and (not (known or queuePeer) or packet.guid ~= (known or queuePeer).guid) then return false end
    return self:Deliver(packet, sender, channel)
end
