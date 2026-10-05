return function(_, equal, newNamespace)
    -- Two real queue engines over the real QueueTransport, QueueWow group
    -- classification and FD.Outbound. The wire models WHISPER and PARTY
    -- delivery, a per-prefix PARTY throttle and invitation acceptance.
    local function world(options)
        options = options or {}
        local w = { now = 0, nextPulse = 0.5, timers = {}, wire = {}, clients = {}, sent = {} }
        for index = 1, 2 do
            local fd = newNamespace()
            local c = { fd = fd, index = index, grouped = false, raid = false, count = 0,
                received = 0, invites = 0, leaves = 0, sent = {}, tokens = 10, refillAt = 0, throttled = 0,
                settings = { scope = "ZONE", levelGap = 5, ruleset = "PVP", cooldownUntil = 0, blockedOpponents = {} },
                profile = { guid = index == 1 and "Player-1-AAA" or "Player-1-BBB",
                    fullName = index == 1 and "Alpha-Forever" or "Beta-Forever",
                    rating = 1500, level = 30, maxLevel = 60, faction = "Horde",
                    mapID = 10, continentID = 0, x = 0, y = 0 } }
            w.clients[index] = c
            local api = setmetatable({}, { __index = _G })
            api._G = api
            c.secret = setmetatable({}, { __tostring = function() error("restricted value formatted") end })
            fd.Wow = { Readable = function(_, ...)
                for i = 1, select("#", ...) do if rawequal(select(i, ...), c.secret) then return false end end
                return true
            end }
            fd.Debug = { Log = function() end, Count = function() end }
            fd.Presence = { players = {}, GetPlayer = function(_, guid)
                if c.expired then return nil end
                return fd.Presence.players[guid]
            end }
            function fd.Presence:Candidates()
                local list = {}
                for guid in pairs(self.players) do
                    local player = self:GetPlayer(guid)
                    if player then list[#list + 1] = player end
                end
                return list
            end
            function fd.Presence:FindByName(name)
                for guid in pairs(self.players) do
                    local player = self:GetPlayer(guid)
                    if player and player.fullName == name then return player end
                end
            end
            api.GetTime = function() return w.now end
            api.GetNormalizedRealmName = function() return "Forever" end
            api.RegionalUniqueNamesEnabled = function() return false end
            api.IsInGroup = function() if c.groupError then error("native group unavailable") end; return c.grouped end
            api.IsInRaid = function() return c.raid end
            api.GetNumGroupMembers = function() return c.count end
            api.UnitGUID = function(unit)
                if unit == "party1" and c.grouped and c.count == 2 then return c.partyGUID or w.clients[3 - index].profile.guid end
            end
            api.Enum = { RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
                SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, InvalidChatType = 4, NotInGroup = 5 } }
            api.C_Timer = { After = function(delay, callback)
                w.timers[#w.timers + 1] = { at = w.now + delay, callback = callback }
            end }
            api.C_ChatInfo = {
                RegisterAddonMessagePrefix = function() return 0 end,
                SendAddonMessage = function(prefix, payload, channel, target)
                    local packet = assert(fd.QueueProtocol:Decode(payload))
                    local message = { prefix = prefix, payload = payload, channel = channel, target = target,
                        from = c, kind = packet.kind, at = w.now }
                    if c.sendError then error("native transport unavailable") end
                    local result = channel == "PARTY" and c.partyResult or 0
                    -- Per-prefix allowance for grouped traffic: burst 10, 1/s.
                    if result == 0 and channel == "PARTY" and options.throttle then
                        c.tokens = math.min(10, c.tokens + (w.now - c.refillAt))
                        c.refillAt = w.now
                        if c.tokens < 1 then result = 3; c.throttled = c.throttled + 1 else c.tokens = c.tokens - 1 end
                    end
                    message.result = result
                    c.sent[#c.sent + 1] = message; w.sent[#w.sent + 1] = message
                    if result == 0 and not (w.dropWhisper and channel == "WHISPER") then w.wire[#w.wire + 1] = message end
                    return result
                end,
            }
            for _, name in ipairs({ "Native", "Outbound", "QueueWow", "QueueTransport" }) do
                local module = assert(loadfile("ForeverDuel/" .. name .. ".lua"))
                setfenv(module, api)("ForeverDuel", fd)
            end
            assert(fd.QueueTransport:Initialize())
            local env = {
                now = function() return w.now end, epoch = function() return 1700000000 + math.floor(w.now) end,
                nonce = function() c.counter = (c.counter or 0) + 1; return index .. "a" .. c.counter end,
                own = function() return fd.Copy(c.profile) end,
                settings = function() return fd.Copy(c.settings) end, save = function(s) c.settings = fd.Copy(s) end,
                available = function() return not c.grouped, "Solo only" end,
                combat = function() return false end,
                groupState = function(peer) return fd.QueueWow:GroupState(peer) end,
                candidates = function() return { w.clients[3 - index].profile } end,
                send = function(packet, target, owner) return fd.QueueTransport:Send(packet, target, owner) end,
                sendNow = function(packet, target, owner) return fd.QueueTransport:SendNow(packet, target, owner) end,
                invite = function()
                    c.invites = c.invites + 1
                    local other = w.clients[3 - index]
                    w.timers[#w.timers + 1] = { at = w.now + 0.3, callback = function()
                        other.queue:InviteRequest(c.profile.guid)
                    end }
                    w.timers[#w.timers + 1] = { at = w.now + 2, callback = function()
                        for _, member in ipairs(w.clients) do member.grouped, member.count = true, 2 end
                    end }
                    return true
                end,
                leave = function()
                    c.leaves = c.leaves + 1
                    w.timers[#w.timers + 1] = { at = w.now + 0.2, callback = function()
                        for _, member in ipairs(w.clients) do member.grouped, member.count = false, 0 end
                    end }
                    return true
                end,
                peerPresent = function() return c.grouped end,
                peerNear = function() return c.grouped end,
                coLocated = function() return c.grouped == true end,
                challenge = function() return true end,
                catalog = function() return { { id = "test-clearing", name = "Test clearing", mapID = 10, continentID = 0,
                    x = 0, y = 0, factions = { Horde = true }, minPlayerLevel = 1, zoneMinLevel = 1,
                    zoneMaxLevel = 10, verified = true, duelAllowed = true } } end,
                world = function() error("world coordinates already supplied") end,
                after = function(seconds, callback) w.timers[#w.timers + 1] = { at = w.now + seconds, callback = callback } end,
                waypoint = function() return true end, clearWaypoint = function() end,
                render = function() end, log = function() end, notify = function() end,
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
                count = count + 1; assert(count < 5000, "queue transport did not settle")
                local m = table.remove(self.wire, 1)
                local peer = self.clients[3 - m.from.index]
                if m.channel == "PARTY" then
                    -- Native PARTY echo to the sender itself.
                    m.from.fd.QueueTransport:Receive(m.prefix, m.payload, m.channel, m.from.profile.fullName)
                end
                if m.channel == "PARTY" and peer.grouped or m.channel == "WHISPER" and m.target == peer.profile.fullName then
                    if peer.fd.QueueTransport:Receive(m.prefix, m.payload, m.channel, m.from.profile.fullName) then
                        peer.received = peer.received + 1
                    end
                end
            end
        end
        function w:advance(seconds)
            local finish = self.now + seconds
            while self.now < finish do
                self.now = math.min(finish, self.now + 0.05)
                if self.now >= self.nextPulse then
                    self.nextPulse = self.nextPulse + 1
                    for _, c in ipairs(self.clients) do c.queue:Run(function() c.queue:Tick() end) end
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
        function w:reach(state, limit)
            local start = self.now
            while self.now - start < limit do
                if self.a.queue.state == state and self.b.queue.state == state then return self.now - start end
                self:advance(0.25)
            end
            error("did not reach " .. state .. ": " .. self.a.queue.state .. "/" .. self.b.queue.state
                .. " | " .. tostring(self.a.queue.reason) .. " | " .. tostring(self.b.queue.reason), 2)
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
                    coordinator = c.index == 1, player = c.fd.Copy(c.queue.ownProfile),
                    peer = c.fd.Copy(peer.queue.ownProfile), ownedParty = true, sentAt = {}, rejected = {} }
            end
        end
        return w
    end

    local w = world()
    equal(w.a.queue:Join(), true, "first solo joins")
    equal(w.b.queue:Join(), true, "second solo joins")
    w:reach("GROUPING", 15)
    equal(w.a.invites + w.b.invites, 1, "one invitation")
    for _, m in ipairs(w.sent) do
        if m.kind == "QUERY" or m.kind == "PROFILE" or m.kind == "OFFER" then equal(m.channel, "WHISPER", m.kind .. " is whispered") end
    end
    for _, c in ipairs(w.clients) do c.expired = true end
    w.dropWhisper = true
    w:reach("TRAVELLING", 20)
    for _, c in ipairs(w.clients) do c.profile.x = 0 end
    w:reach("READY", 15)
    equal(w.a.queue.ticket.plan.startDeadline, w.b.queue.ticket.plan.startDeadline, "party queue agrees one start deadline")
    equal(w.a.fd.QueueTransport.lastSendRoute, "PARTY", "actual queue send route diagnosed")
    equal(w.b.fd.QueueTransport.lastReceiveRoute, "PARTY", "actual queue receive route diagnosed")
    equal(w.a.fd.Database.data, nil, "queue transport cannot create rating data")
    local grouped = 0
    for _, m in ipairs(w.sent) do
        if (m.kind == "GROUP" or m.kind == "PLAN" or m.kind == "PLAN_ACK" or m.kind == "STATUS") and m.channel == "PARTY" then grouped = grouped + 1 end
    end
    equal(grouped > 0, true, "grouped controls use PARTY with whispers dropped")
    w.a.queue:Leave()
    local terminalParty = false
    for _, m in ipairs(w.a.sent) do if m.kind == "CANCEL" and m.channel == "PARTY" then terminalParty = true end end
    equal(terminalParty, true, "terminal CANCEL submitted over PARTY synchronously")
    equal(w.a.leaves, 0, "LeaveParty deferred behind the CANCEL")
    w:advance(3)
    equal(w.b.queue.cancel and w.b.queue.cancel.reason, "CANCELLED", "peer receives the real reason")
    equal(w.a.leaves, 1, "queue group left after the delay")
    equal(w.a.queue.state, "IDLE", "leaving client idle")

    -- Throttled PARTY: the Outbound retries instead of dropping state changes.
    w = world({ throttle = true })
    w.a.queue:Join(); w.b.queue:Join()
    w:reach("TRAVELLING", 30)
    for _, c in ipairs(w.clients) do c.profile.x = 0 end
    w:reach("READY", 30)
    w:advance(120)
    equal(w.a.queue.state, "READY", "READY survives a throttled prefix")
    local party = 0
    for _, m in ipairs(w.a.sent) do if m.channel == "PARTY" and m.at > w.now - 100 then party = party + 1 end end
    equal(party / 100 <= 0.7, true, "coordinator PARTY rate stays under the allowance")
    equal(w.a.throttled + w.b.throttled, 0, "steady STATUS never hits the per-prefix throttle")

    w = world(); w:pair()
    local c, transport = w.a, w.a.fd.QueueTransport
    c.queue.state = "SEARCHING"
    c.fd.QueueWow.venueTest = { peer = c.queue.ticket.peer }
    c.fd.QueueWow.CaptureStatus = function() return true end
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
        w:advance(0.5)
        -- The PROFILE that re-keys a grouped pair goes to the exact party1 over
        -- PARTY; every other discovery or setup packet is whispered.
        equal(c.sent[#c.sent].channel, packet.kind == "PROFILE" and "PARTY" or "WHISPER",
            packet.kind .. (packet.kind == "PROFILE" and " to the exact party1 uses party" or " never uses party"))
        local bytes = assert(c.fd.QueueProtocol:Encode(packet))
        equal(transport:Receive("ForeverDuelQ2", bytes, "PARTY", w.b.profile.fullName), false,
            packet.kind .. (packet.kind == "PROFILE" and " with a GUID that is not party1 rejected through party"
                or " never accepted through party"))
    end
    -- The exact party1's own PROFILE is accepted through party and re-keys.
    local peerProfile = c.fd.Copy(w.b.profile)
    peerProfile.kind, peerProfile.session, peerProfile.joinedAt = "PROFILE", "b2", 1700000000
    peerProfile.scope, peerProfile.levelGap, peerProfile.ruleset, peerProfile.venues = "ZONE", 5, "PVP", "-"
    local delivered = 0
    c.queue.Receive = function(_, packet) if packet.kind == "PROFILE" then delivered = delivered + 1 end end
    local bytes = assert(c.fd.QueueProtocol:Encode(peerProfile))
    equal(transport:Receive("ForeverDuelQ2", bytes, "PARTY", w.b.profile.fullName), true,
        "the exact party1's PROFILE is accepted through party")
    equal(delivered, 1, "and delivered to the engine")
    c.count = 3
    equal(transport:Receive("ForeverDuelQ2", bytes, "PARTY", w.b.profile.fullName), false,
        "a PROFILE through party is rejected once the group is not exactly the pair")

    -- Membership is checked at drain: a changed group falls back to WHISPER.
    for _, change in ipairs({
        function(cc) cc.count = 3 end, function(cc) cc.raid = true end,
        function(cc) cc.grouped = false end, function(cc) cc.groupError = true end,
        function(cc) cc.count = cc.secret end, function(cc) cc.grouped = cc.secret end,
        function(cc) cc.partyGUID = "Player-1-CCC" end, function(cc) cc.api.IsInRaid = nil end,
    }) do
        w = world(); w:pair(); c = w.a; transport = c.fd.QueueTransport
        local packet = c.queue:Control("GROUP", { mapID = 10, continentID = 0, x = 0, y = 0 })
        assert(transport:Send(packet, c.queue.ticket.peer.fullName, c.queue.ticket))
        change(c)
        w.now = 0.25
        c.fd.Outbound:Pump()
        equal(c.sent[1].channel, "WHISPER", "membership rechecked at send drain")
    end

    -- PARTY rejections: InvalidChatType/NotInGroup fall back to WHISPER once.
    for _, result in ipairs({ 4, 5 }) do
        w = world(); w:pair(); c = w.a; transport = c.fd.QueueTransport
        c.partyResult = result
        transport:Send(c.queue:Control("GROUP", { mapID = 10, continentID = 0, x = 0, y = 0 }), c.queue.ticket.peer.fullName, c.queue.ticket)
        w:advance(1)
        equal(c.sent[1].channel, "PARTY", "exact pair attempts PARTY")
        equal(c.sent[2] and c.sent[2].channel, "WHISPER", "explicit non-delivery falls back to WHISPER")
    end

    w = world(); w:pair(); c = w.a; transport = c.fd.QueueTransport
    local incoming = w.b.queue:Control("GROUP", { mapID = 10, continentID = 0, x = 0, y = 0 })
    local bytes = assert(c.fd.QueueProtocol:Encode(incoming))
    equal(transport:Receive("ForeverDuelQ2", bytes, "PARTY", c.profile.fullName), false, "own party echo ignored")
    equal(transport:Receive("ForeverDuelQ2", bytes, "PARTY", "Gamma-Forever"), false, "other sender rejected")
    equal(transport:Receive("ForeverDuelQ2", "FQ2|GROUP|bad", "PARTY", w.b.profile.fullName), false, "malformed control rejected")
    equal(transport:Receive("ForeverDuelQ2", bytes, "PARTY", c.secret), false, "restricted native sender rejected")
    incoming.peerSession = "a2"
    equal(transport:Receive("ForeverDuelQ2", assert(c.fd.QueueProtocol:Encode(incoming)), "PARTY", w.b.profile.fullName), false,
        "old peer session cannot reach engine")
    incoming.peerSession, incoming.ticket = "a1", "a2.b1"
    equal(transport:Receive("ForeverDuelQ2", assert(c.fd.QueueProtocol:Encode(incoming)), "PARTY", w.b.profile.fullName), false,
        "old ticket cannot reach engine")
    -- A PARTY OFFER naming our own session reaches the engine so a grouped
    -- invitee can bind or re-key, but PARTY never discovers its sender.
    w = world(); w:pair()
    local receiver = w.b
    local offered = w.a.queue:Control("OFFER")
    local function offer(packet, sender)
        return receiver.fd.QueueTransport:Receive("ForeverDuelQ2", assert(receiver.fd.QueueProtocol:Encode(packet)),
            "PARTY", sender or w.a.profile.fullName)
    end
    receiver.queue.state, receiver.queue.ticket = "SEARCHING", nil
    offer(offered)
    equal(receiver.queue.ticket, nil, "a PARTY OFFER from an undiscovered sender creates no ticket")
    local foreign = w.a.fd.Copy(offered); foreign.peerSession, foreign.ticket = "b9", "a1.b9"
    offer(foreign)
    equal(receiver.queue.ticket, nil, "a PARTY OFFER naming another session of ours creates no ticket")
    local known = w.a.fd.Copy(w.a.queue.ownProfile)
    known.fullName, known.lastSeen = w.a.profile.fullName, w.now
    receiver.queue.peers[known.guid] = known
    receiver.queue.pendingOffer = nil
    equal(offer(offered), true, "a PARTY OFFER from a known queue peer reaches the engine")
    equal(receiver.queue.state, "INVITED", "the grouped invitee binds from the PARTY OFFER")
    equal(receiver.queue.ticket.id, "a1.b1", "ticket named by the OFFER")
    local requeued = w.a.fd.Copy(offered); requeued.session, requeued.ticket = "a2", "a2.b1"
    equal(offer(requeued), true, "an OFFER from the ticket peer with a newer session passes the PARTY rule")
    equal(receiver.queue.ticket.id, "a2.b1", "the invitee re-keys to the coordinator's current session")
    equal(offer(requeued, "Gamma-Forever"), false, "another group member cannot re-key the ticket")

    w = world(); w:pair(); c = w.a; transport = c.fd.QueueTransport
    assert(transport:Send(c.queue:Control("GROUP", { mapID = 10, continentID = 0, x = 0, y = 0 }), c.queue.ticket.peer.fullName, c.queue.ticket))
    c.queue.ticket = c.fd.Copy(c.queue.ticket)
    w.now = 0.25; c.fd.Outbound:Pump()
    equal(#c.sent, 0, "replaced ticket object invalidates queued control even with equal fields")
    w = world(); w:pair(); c = w.a; transport = c.fd.QueueTransport
    local original = c.queue.ticket
    transport:Send(c.queue:Control("CANCEL", { reason = "FINISHED" }), original.peer.fullName, original)
    c.queue.ticket = nil
    w.now = 0.25; c.fd.Outbound:Pump()
    equal(c.sent[1] and c.fd.QueueProtocol:Decode(c.sent[1].payload).kind, "CANCEL", "terminal control drains after the ticket ended")
end
