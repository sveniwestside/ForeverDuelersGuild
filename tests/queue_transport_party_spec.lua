return function(_, equal, newNamespace)
    local function world()
        local w = { now = 0, nextPulse = 0, timers = {}, wire = {}, clients = {}, sent = {} }
        for index = 1, 2 do
            local fd = newNamespace()
            local c = { fd = fd, index = index, grouped = false, raid = false, count = 0,
                received = 0, invites = 0, leaves = 0, sent = {}, settings = { scope = "ZONE", levelGap = 5, ruleset = "PVP" },
                profile = { guid = index == 1 and "Player-1-AAA" or "Player-1-BBB",
                    fullName = index == 1 and "Alpha-Forever" or "Beta-Forever",
                    rating = 1500, level = 30, maxLevel = 60, faction = "Horde",
                    mapID = 10, continentID = 0, x = 0, y = 0 } }
            w.clients[index] = c
            local api = setmetatable({}, { __index = _G })
            api._G = api
            c.secret = setmetatable({}, { __tostring = function() error("restricted value formatted") end })
            fd.Wow = {
                Readable = function(_, ...)
                    for i = 1, select("#", ...) do if rawequal(select(i, ...), c.secret) then return false end end
                    return true
                end,
                Identity = function(_, unit)
                    if c.identityError then error("native identity unavailable") end
                    if unit == "player" then return c.nativeOwn or c.profile end
                    if unit == "party1" then return c.nativePeer or w.clients[3 - index].profile end
                end,
            }
            fd.Debug = { Log = function() end }
            fd.Presence = { players = {}, GetPlayer = function(_, guid)
                if c.expired or fd.Presence.suspended then return nil end
                return fd.Presence.players[guid]
            end }
            api.GetTime = function() return w.now end
            api.GetNormalizedRealmName = function() return "Forever" end
            api.RegionalUniqueNamesEnabled = function() return false end
            api.IsInGroup = function() if c.groupError then error("native group unavailable") end; return c.grouped end
            api.IsInRaid = function() return c.raid end
            api.GetNumGroupMembers = function() return c.count end
            api.Enum = { RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
                SendAddonMessageResult = { Success = 0, Throttle = 3, InvalidChatType = 4, NotInGroup = 5 } }
            api.C_Timer = { After = function(delay, callback)
                w.timers[#w.timers + 1] = { at = w.now + delay, callback = callback }
            end }
            api.C_ChatInfo = {
                RegisterAddonMessagePrefix = function() return 0 end,
                SendAddonMessage = function(prefix, payload, channel, target)
                    local packet = assert(fd.QueueProtocol:Decode(payload))
                    local message = { prefix = prefix, payload = payload, channel = channel, target = target,
                        from = c, kind = packet.kind }
                    c.sent[#c.sent + 1] = message; w.sent[#w.sent + 1] = message
                    if c.sendError then error("native transport unavailable") end
                    local result = channel == "PARTY" and c.partyResult or c.whisperResult
                    if result == nil then result = 0 end
                    if result == 0 and not (w.dropWhisper and channel == "WHISPER") then
                        w.wire[#w.wire + 1] = message
                    end
                    return result
                end,
            }
            local module = assert(loadfile("ForeverDuel/QueueTransport.lua"))
            setfenv(module, api)("ForeverDuel", fd)
            assert(fd.QueueTransport:Initialize())
            local env = {
                now = function() return w.now end, epoch = function() return 1700000000 + math.floor(w.now) end,
                nonce = function() c.counter = (c.counter or 0) + 1; return index .. "a" .. c.counter end,
                own = function() return fd.Copy(c.profile) end,
                settings = function() return c.settings end, save = function(s) c.settings = fd.Copy(s) end,
                available = function() return not c.grouped, "Solo only" end,
                solo = function() return not c.grouped end, combat = function() return false end,
                party = function(peer) return c.grouped == true and c.raid == false and c.count == 2
                    and peer.guid == w.clients[3 - index].profile.guid end,
                candidates = function() return { w.clients[3 - index].profile } end,
                send = function(packet, target, owner) return fd.QueueTransport:Send(packet, target, owner) end,
                invite = function() c.invites = c.invites + 1; return true end,
                leave = function(_, owned)
                    if owned and c.grouped then
                        c.leaves = c.leaves + 1
                        for _, other in ipairs(w.clients) do other.grouped, other.count = false, 0 end
                        return true
                    end
                    return false
                end,
                coLocated = function() return c.grouped == true end,
                catalog = function() return { { id = "test-clearing", name = "Test clearing", mapID = 10, continentID = 0,
                    x = 0, y = 0, factions = { Horde = true }, minPlayerLevel = 1, zoneMinLevel = 1,
                    zoneMaxLevel = 10, verified = true, duelAllowed = true } } end,
                world = function() error("world coordinates already supplied") end,
                waypoint = function() return true end, clearWaypoint = function() end,
                render = function() end, log = function() end, print = function() end,
            }
            c.api, c.env = api, env
            c.queue = fd.Queue:New(env); fd.queue = c.queue
        end
        w.a, w.b = w.clients[1], w.clients[2]
        for _, c in ipairs(w.clients) do
            local peer = w.clients[3 - c.index]
            c.fd.Presence.players[peer.profile.guid] = peer.profile
        end
        function w:flush()
            local count = 0
            while #self.wire > 0 do
                count = count + 1; assert(count < 1000, "queue transport did not settle")
                local m = table.remove(self.wire, 1)
                local peer = self.clients[3 - m.from.index]
                if m.channel == "PARTY" then
                    m.from.fd.QueueTransport:Receive(m.prefix, m.payload, m.channel, m.from.profile.fullName)
                end
                if m.channel == "PARTY" or m.target == peer.profile.fullName then
                    if peer.fd.QueueTransport:Receive(m.prefix, m.payload, m.channel, m.from.profile.fullName) then
                        peer.received = peer.received + 1
                    end
                end
            end
        end
        function w:advance(seconds)
            local finish = self.now + seconds
            while self.now < finish do
                self.now = math.min(finish, self.now + 0.25)
                if self.now >= self.nextPulse then
                    self.nextPulse = self.now + 1
                    for _, c in ipairs(self.clients) do c.queue:Tick() end
                end
                local changed = true
                while changed do
                    changed = false
                    for i, timer in ipairs(self.timers) do
                        if timer.at <= self.now then table.remove(self.timers, i); timer.callback(); changed = true; break end
                    end
                end
                self:flush()
            end
        end
        function w:pair()
            for _, c in ipairs(self.clients) do
                c.queue.session = c.index == 1 and "a1" or "b1"
                c.queue.state = "GROUPING"
                c.queue.queuedAt = 1700000000
                c.queue:RefreshOwn()
                c.grouped, c.count = true, 2
            end
            for _, c in ipairs(self.clients) do
                local peer = self.clients[3 - c.index]
                c.queue.ticket = { id = "a1.b1", ownSession = c.queue.session, peerSession = peer.queue.session,
                    player = c.fd.Copy(c.queue.ownProfile), peer = c.fd.Copy(peer.queue.ownProfile), ownedParty = true }
            end
        end
        function w:send(c, kind, extras, owner)
            local packet = c.queue:Control(kind, extras)
            assert(c.fd.QueueTransport:Send(packet, c.queue.ticket.peer.fullName, owner or c.queue.ticket))
            self.now = self.now + 0.25
            c.fd.QueueTransport:Tick()
            return c.sent[#c.sent], packet
        end
        return w
    end

    local w = world()
    equal(w.a.queue:Join(), true, "first solo joins unchanged queue")
    equal(w.b.queue:Join(), true, "second solo joins unchanged queue")
    w:advance(5)
    equal(w.a.queue.state, "GROUPING", "whisper reservation completes before invitation")
    equal(w.b.queue.state, "GROUPING", "both whisper confirmations precede group")
    equal(w.a.invites + w.b.invites, 1, "one automatic invite after reservation")
    for _, m in ipairs(w.sent) do equal(m.channel, "WHISPER", "all pre-group queue sends stay whispered") end
    for _, c in ipairs(w.clients) do c.grouped, c.count, c.expired = true, 2, true; c.fd.Presence.suspended = true end
    w.dropWhisper = true
    w:advance(15)
    equal(w.a.queue.state, "READY", "queue reaches ready with all grouped whispers dropped")
    equal(w.b.queue.state, "READY", "peer uses native ticket identity while presence suspended")
    equal(w.a.queue.ticket.deadline, w.b.queue.ticket.deadline, "party queue agrees one ready deadline")
    equal(w.a.fd.QueueTransport.lastSendRoute, "PARTY", "actual queue send route diagnosed")
    equal(w.a.fd.QueueTransport.lastSendResultCode, 0, "native result enum diagnosed")
    equal(type(w.a.fd.QueueTransport.lastSendAt), "number", "queue send time recorded")
    equal(w.b.fd.QueueTransport.lastReceiveRoute, "PARTY", "actual queue receive route diagnosed")
    equal(w.a.fd.Database.data, nil, "queue transport cannot create rating data")
    w.a.queue:Cancel("FINISHED", false); w.b.queue:Cancel("FINISHED", false)
    w:advance(16)
    equal(w.a.queue.state, "IDLE", "first terminal cleanup finishes safely")
    equal(w.b.queue.state, "IDLE", "peer terminal cleanup finishes safely")
    equal(w.a.leaves + w.b.leaves, 1, "exact native party removed once")
    local terminalParty = false
    for _, m in ipairs(w.sent) do if m.kind == "CANCEL" and m.channel == "PARTY" then terminalParty = true end end
    equal(terminalParty, true, "terminal notification uses retained queue party")

    w = world(); w:pair()
    local c, transport = w.a, w.a.fd.QueueTransport
    c.queue.state = "SEARCHING"
    c.fd.QueueWow = { venueTest = { peer = c.queue.ticket.peer }, CaptureStatus = function() return true end }
    local discovery = {
        { kind = "QUERY" },
        c.fd.Copy(c.queue.ownProfile),
        { kind = "LEAVE", session = "a1", guid = c.profile.guid },
        { kind = "VENUE", venueID = "test-clearing", testPairGUID = c.queue.ticket.peer.guid,
            mapID = 10, continentID = 0, mapX = 50000000, mapY = 50000000,
            minPlayerLevel = 30, zoneMinLevel = 1, zoneMaxLevel = 10, faction = "Horde", hubFaction = "NONE", testedAt = 1700000000 },
    }
    discovery[2].kind = "PROFILE"
    for _, packet in ipairs(discovery) do
        assert(transport:Send(packet, c.queue.ticket.peer.fullName, c.queue))
        w.now = w.now + 0.25; transport:Tick()
        equal(c.sent[#c.sent].channel, "WHISPER", packet.kind .. " never uses party")
        local bytes = assert(c.fd.QueueProtocol:Encode(packet))
        equal(transport:Receive("ForeverDuelQ1", bytes, "PARTY", w.b.profile.fullName), false,
            packet.kind .. " never accepted through party")
    end

    for _, change in ipairs({
        function(c) c.count = 3 end, function(c) c.raid = true end,
        function(c) c.grouped = false end, function(c) c.groupError = true end,
        function(c) c.identityError = true end, function(c) c.count = c.secret end,
        function(c) c.grouped = c.secret end,
        function(c) c.nativeOwn = { guid = "Player-1-CCC", fullName = c.profile.fullName } end,
        function(c) c.nativeOwn = { guid = c.secret, fullName = c.profile.fullName } end,
        function(c) c.nativePeer = { guid = "Player-1-CCC", fullName = "Gamma-Forever" } end,
        function(c) c.nativePeer = { guid = "Player-1-BBB", fullName = "Other-Forever" } end,
        function(c) c.nativePeer = { guid = c.secret, fullName = "Beta-Forever" } end,
        function(c) c.api.IsInRaid = nil end,
    }) do
        w = world(); w:pair(); c = w.a; transport = c.fd.QueueTransport
        local packet = c.queue:Control("GROUP")
        assert(transport:Send(packet, c.queue.ticket.peer.fullName, c.queue.ticket))
        change(c)
        w.now = 0.25; transport:Tick()
        equal(c.sent[1].channel, "WHISPER", "membership rechecked at send drain")
        local incoming = w.b.queue:Control("GROUP")
        equal(transport:Receive("ForeverDuelQ1", assert(c.fd.QueueProtocol:Encode(incoming)), "PARTY", w.b.profile.fullName),
            false, "unreadable or changed native pair rejects party receipt")
    end

    for _, result in ipairs({ 4, 5, 3, 99, "restricted", "error" }) do
        w = world(); w:pair(); c = w.a; transport = c.fd.QueueTransport
        if result == "restricted" then c.partyResult = c.secret
        elseif result == "error" then c.sendError = true
        else c.partyResult = result end
        w:send(c, "GROUP")
        equal(#c.sent, (result == 4 or result == 5) and 2 or 1, "only explicit non-delivery rejection falls back")
        equal(c.sent[1].channel, "PARTY", "exact-pair attempt selects party")
        if #c.sent == 2 then equal(c.sent[2].channel, "WHISPER", "one legacy fallback") end
        equal(transport.partyUnavailable, result == 4, "unsupported party disabled for runtime")
        if result == 4 then
            c.partyResult = 0; w:send(c, "GROUP")
            equal(c.sent[3].channel, "WHISPER", "unsupported route is not retried")
        elseif result == 5 then
            c.partyResult = 0; w:send(c, "GROUP")
            equal(c.sent[3].channel, "PARTY", "temporary not-in-group rejection keeps later exact route available")
        end
    end

    w = world(); w:pair(); c = w.a; transport = c.fd.QueueTransport
    local ownPacket = c.queue:Control("GROUP")
    local bytes = assert(c.fd.QueueProtocol:Encode(ownPacket))
    equal(transport:Receive("ForeverDuelQ1", bytes, "PARTY", c.profile.fullName), false, "own party echo ignored")
    local incoming = w.b.queue:Control("GROUP")
    bytes = assert(c.fd.QueueProtocol:Encode(incoming))
    equal(transport:Receive("ForeverDuelQ1", bytes, "PARTY", "Gamma-Forever"), false, "other sender rejected")
    equal(transport:Receive("ForeverDuelQ1", "FDQ1|GROUP|bad", "PARTY", w.b.profile.fullName), false, "malformed control rejected")
    equal(transport:Receive("ForeverDuelQ1", bytes, "PARTY", c.secret), false, "restricted native sender rejected")
    incoming.peerSession = "a2"
    equal(transport:Receive("ForeverDuelQ1", assert(c.fd.QueueProtocol:Encode(incoming)), "PARTY", w.b.profile.fullName), false,
        "old peer session cannot reach engine")
    incoming.peerSession, incoming.ticket = "a1", "a2.b1"
    equal(transport:Receive("ForeverDuelQ1", assert(c.fd.QueueProtocol:Encode(incoming)), "PARTY", w.b.profile.fullName), false,
        "old ticket cannot reach engine")
    w = world(); w:pair()
    local receiver = w.b
    local offered = w.a.queue:Control("OFFER")
    local originalTicket = receiver.queue.ticket
    offered.peerSession = "b2"
    equal(receiver.fd.QueueTransport:Receive("ForeverDuelQ1", assert(receiver.fd.QueueProtocol:Encode(offered)),
        "PARTY", w.a.profile.fullName), false, "party offer with a mismatched tuple is rejected")
    equal(receiver.queue.ticket, originalTicket, "party offer cannot replace current ticket")
    receiver.queue.state, receiver.queue.ticket = "SEARCHING", nil
    offered.peerSession = "b1"
    equal(receiver.fd.QueueTransport:Receive("ForeverDuelQ1", assert(receiver.fd.QueueProtocol:Encode(offered)),
        "PARTY", w.a.profile.fullName), false, "party offer cannot create a reservation without an existing ticket")
    equal(receiver.queue.ticket, nil, "exact native party does not create a queue ticket")
    equal(receiver.invites, 0, "party offer cannot trigger another native invite")
    w = world(); w:pair(); c = w.a; transport = c.fd.QueueTransport
    ownPacket = c.queue:Control("GROUP")
    assert(transport:Send(ownPacket, c.queue.ticket.peer.fullName, c.queue.ticket))
    c.queue.ticket = c.fd.Copy(c.queue.ticket)
    w.now = 0.25; transport:Tick()
    equal(#c.sent, 0, "replaced ticket object invalidates queued control even with equal fields")

    w = world(); w:pair(); c = w.a; transport = c.fd.QueueTransport
    local original = c.queue.ticket
    assert(transport:Send(c.queue:Control("CANCEL", { reason = "FINISHED" }), original.peer.fullName, original))
    c.queue.ticket = nil
    w.now = 0.25; transport:Tick()
    equal(c.sent[1].channel, "PARTY", "original terminal control can drain with current native character and pair")
    w = world(); w:pair(); c = w.a; transport = c.fd.QueueTransport
    assert(transport:Send(c.queue:Control("GROUP"), c.queue.ticket.peer.fullName, c.queue.ticket))
    c.queue.ticket.id = "a2.b1"
    w.now = 0.25; transport:Tick()
    equal(#c.sent, 0, "changed ticket tuple cannot drain")
end
