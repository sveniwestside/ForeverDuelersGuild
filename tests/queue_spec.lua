return function(_, equal, newNamespace)
    local scenario = "queue"
    local function eq(actual, expected, label)
        equal(actual, expected, scenario .. ": " .. label)
    end
    local BASE = 1700000000
    local NAMES = { "Alpha-Forever", "Beta-Forever", "Gamma-Forever" }
    local GUIDS = { "Player-1-AAA", "Player-1-BBB", "Player-1-CCC" }
    local function clearing(changes)
        local venue = { id = "verified-test-clearing", name = "Fictional verified clearing", mapID = 10,
            continentID = 0, x = 0, y = 0, mapX = 0.5, mapY = 0.5, factions = { Horde = true, Alliance = true },
            minPlayerLevel = 1, zoneMinLevel = 1, zoneMaxLevel = 10, verified = true, duelAllowed = true }
        for key, value in pairs(changes or {}) do venue[key] = value end
        return venue
    end
    local TICKET_KINDS = { OFFER = true, GROUP = true, PLAN = true, PLAN_ACK = true, PLAN_REJECT = true,
        STATUS = true, CANCEL = true }

    -- Deterministic time-based world: per-message latency and loss, a native
    -- roster that every client sees with its own lag (party1 GUID can lag the
    -- member count), invitations a human accepts/declines/ignores, deferred
    -- LeaveParty, and 1-second queue pulses at different phases per client.
    local function world(options)
        options = options or {}
        local w = { now = 0, clients = {}, events = {}, sent = {}, dropped = {}, sequence = 0 }
        local function option(c, key, default)
            if c.options[key] ~= nil then return c.options[key] end
            if options[key] ~= nil then return options[key] end
            return default
        end
        local function byGUID(guid) for _, c in ipairs(w.clients) do if c.profile.guid == guid then return c end end end
        local function byName(name) for _, c in ipairs(w.clients) do if c.profile.fullName == name then return c end end end
        function w:at(delay, callback)
            self.sequence = self.sequence + 1
            self.events[#self.events + 1] = { at = self.now + delay, seq = self.sequence, run = callback }
        end
        local function snapshot(c)
            local group = c.group
            if group then
                local other
                for _, member in ipairs(group.members) do if member ~= c and not other then other = member end end
                return { raid = group.raid or false, grouped = true, members = #group.members,
                    partyGUID = other and other.profile.guid }
            end
            if c.inviting and option(c, "pendingInviterGroup", false) then return { raid = false, grouped = true, members = 1 } end
            return { raid = false, grouped = false, members = 0 }
        end
        function w:roster(c)
            local view = snapshot(c)
            local lag, guidLag = option(c, "rosterLag", 0.3), option(c, "guidLag", 0)
            if view.partyGUID and guidLag > 0 then
                local partial = { raid = view.raid, grouped = view.grouped, members = view.members }
                self:at(lag, function() c.view = partial end)
                self:at(lag + guidLag, function() if c.view == partial then c.view = view end end)
            else self:at(lag, function() c.view = view end) end
        end
        function w:form(inviter, invitee)
            local group = { members = { inviter, invitee } }
            inviter.group, invitee.group, inviter.inviting, invitee.pending = group, group, nil, nil
            self:roster(inviter); self:roster(invitee)
        end
        function w:remove(c)
            local group = c.group
            if group then
                for index, member in ipairs(group.members) do if member == c then table.remove(group.members, index); break end end
                c.group = nil
                if #group.members == 1 then group.members[1].group = nil end
                for _, member in ipairs(group.members) do self:roster(member) end
                self:roster(c)
            elseif c.inviting then
                local target = c.inviting
                if target.pending and target.pending.from == c then target.pending = nil end
                c.inviting = nil
                c.rescinded = (c.rescinded or 0) + 1
                self:roster(c)
            end
        end
        function w:accept(invitee, inviter)
            if invitee.pending and invitee.pending.from == inviter and not invitee.group and not inviter.group then
                self:form(inviter, invitee)
            end
        end
        function w:decline(invitee, inviter)
            if not invitee.pending or invitee.pending.from ~= inviter then return end
            invitee.pending, inviter.inviting = nil, nil
            self:roster(inviter)
            self:at(0.3, function()
                inviter.queue:Run(function() inviter.queue:SystemMessage("DECLINED:" .. invitee.profile.fullName) end)
            end)
        end
        local function exact(c, peer)
            return c.view.raid == false and c.view.grouped == true and c.view.members == 2 and c.view.partyGUID == peer.guid
        end
        local function distance(a, b)
            if a.profile.mapID ~= b.profile.mapID then return math.huge end
            return math.sqrt((a.profile.x - b.profile.x) ^ 2 + (a.profile.y - b.profile.y) ^ 2)
        end
        function w:duelRequest(from, to)
            from.match, to.match = { opponent = from.fd.Copy(to.profile) }, { opponent = to.fd.Copy(from.profile) }
            from.queue:OnDuel("request", from.match)
            to.queue:OnDuel("request", to.match)
        end
        for index = 1, options.count or 2 do
            local fd = newNamespace()
            local c = { fd = fd, index = index, options = options.players and options.players[index] or {},
                nonceCounter = 0, invited = 0, challenged = 0, leaves = 0, autoAccepted = 0, declined = 0,
                waypoints = 0, cleared = 0, ratingCalls = 0, logs = {}, notices = {}, errors = 0,
                view = { raid = false, grouped = false, members = 0 }, nextTick = 1 + (index - 1) * 0.37,
                settings = { scope = "ZONE", levelGap = 5, ruleset = "PVP", cooldownUntil = 0, blockedOpponents = {} },
                profile = { guid = GUIDS[index], fullName = NAMES[index], level = 30, maxLevel = 60,
                    rating = 1500, faction = "Horde", mapID = 10, continentID = 0, x = index == 1 and -100 or 100, y = 0 },
                catalog = { clearing() } }
            for key, value in pairs(c.options.profile or {}) do c.profile[key] = value end
            if c.options.catalog then c.catalog = c.options.catalog end
            w.clients[index] = c
            fd.Rating.Calculate = function() c.ratingCalls = c.ratingCalls + 1; error("queue must not calculate ratings") end
            local function transmit(packet, targetName, channel)
                local payload, reason = fd.QueueProtocol:Encode(packet)
                assert(payload, "engine emitted invalid " .. tostring(packet.kind) .. ": " .. tostring(reason))
                local decoded = assert(fd.QueueProtocol:Decode(payload))
                local target = byName(targetName)
                local message = { kind = decoded.kind, from = c, to = target, channel = channel, at = w.now,
                    reason = decoded.reason, packet = decoded }
                w.sent[#w.sent + 1] = message
                if not target then return true end
                if w.drop and w.drop(decoded, c, target, channel) then
                    w.dropped[decoded.kind] = (w.dropped[decoded.kind] or 0) + 1
                    return true
                end
                local latency = channel == "PARTY" and option(c, "partyLatency", 0.2) or option(c, "whisperLatency", 0.5)
                if type(latency) == "function" then latency = latency(decoded, c, target) end
                w:at(latency, function()
                    -- PARTY reaches only current members of the same group.
                    if channel == "PARTY" and not (c.group and c.group == target.group) then
                        w.dropped.party = (w.dropped.party or 0) + 1
                        return
                    end
                    message.delivered = true
                    target.queue:Run(function()
                        target.queue:Receive(assert(target.fd.QueueProtocol:Decode(payload)), c.profile.fullName)
                    end)
                end)
                return true
            end
            local function route(packet, targetName)
                local target = byName(targetName)
                return TICKET_KINDS[packet.kind] and target and exact(c, target.profile) and "PARTY" or "WHISPER"
            end
            local env = {
                now = function() return w.now end,
                epoch = function() return BASE + math.floor(w.now + (c.options.clockSkew or 0)) end,
                nonce = function()
                    c.nonceCounter = c.nonceCounter + 1
                    return fd.Protocol:Nonce(BASE + math.floor(w.now), c.nonceCounter, index * 1024)
                end,
                own = function()
                    if c.missingProfile then return nil end
                    local own = fd.Copy(c.profile)
                    if c.unreadablePosition then own.mapID, own.continentID, own.x, own.y = 0, 0, 0, 0 end
                    return own
                end,
                settings = function() return fd.Copy(c.settings) end,
                save = function(s) c.settings = fd.Copy(s) end,
                catalog = function() return c.catalog end,
                world = function() error("test catalog already has world coordinates") end,
                available = function()
                    if c.dead then return false, "Player is dead." end
                    if c.unrelatedDuel then return false, "Finish the current native duel request before joining the queue." end
                    if c.view.grouped ~= false then return false, "Queue requires a confirmed solo character." end
                    return true
                end,
                combat = function() return c.combat or false end,
                groupState = function(peer)
                    if c.groupStateError then error("native roster unavailable") end
                    if c.groupUnreadable then return "PENDING" end
                    return fd.Queue.ClassifyGroup(c.view, peer.guid), c.view.members
                end,
                candidates = function()
                    local result = {}
                    for _, other in ipairs(w.clients) do
                        if other ~= c and not other.offline then
                            result[#result + 1] = { guid = other.profile.guid, fullName = other.profile.fullName }
                        end
                    end
                    return result
                end,
                send = function(packet, target) return transmit(packet, target, route(packet, target)) end,
                sendNow = function(packet, target)
                    if route(packet, target) == "PARTY" then transmit(packet, target, "PARTY") end
                    return transmit(packet, target, "WHISPER")
                end,
                after = function(seconds, callback) w:at(seconds, function() c.queue:Run(callback) end) end,
                render = function()
                    local state = c.queue and c.queue.state
                    if state and c.renderedState ~= state then
                        c.enteredAt = c.enteredAt or {}
                        c.enteredAt[state] = w.now
                    end
                    c.renderedState = state
                end,
                notify = function(event, text) c.notices[#c.notices + 1] = { event = event, text = text, at = w.now } end,
                log = function(topic, ...)
                    if c.logError then error("diagnostic unavailable") end
                    local parts = {}
                    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
                    c.logs[#c.logs + 1] = { topic = topic, detail = table.concat(parts, " ") }
                end,
                error = function() c.errors = c.errors + 1 end,
                invite = function(peer)
                    c.invited = c.invited + 1
                    if c.blockInvite then return false, "Native invitation blocked." end
                    if c.view.grouped ~= false then return false, "Cannot invite while grouped." end
                    local target = byGUID(peer.guid)
                    if target.group or target.pending then
                        if not option(c, "silentCollision", false) then
                            w:at(0.3, function() c.queue:Run(function() c.queue:SystemMessage("FAILED:" .. target.profile.fullName) end) end)
                        end
                        return true
                    end
                    target.pending, c.inviting = { from = c, at = w.now }, target
                    w:roster(c)
                    w:at(option(target, "inviteLatency", 0.3), function()
                        if not target.pending or target.pending.from ~= c then return end
                        target.inviteEvents = (target.inviteEvents or 0) + 1
                        target.pending.seen = true
                        target.queue:Run(function() target.queue:InviteRequest(c.profile.guid) end)
                        local response, delay = option(target, "inviteResponse", "accept"), option(target, "acceptDelay", 2)
                        if response == "accept" then w:at(delay, function() w:accept(target, c) end)
                        elseif response == "decline" then w:at(delay, function() w:decline(target, c) end) end
                    end)
                    w:at(90, function()
                        if target.pending and target.pending.from == c then target.pending, c.inviting = nil, nil; w:roster(c) end
                    end)
                    return true
                end,
                acceptInvite = function(peer)
                    c.autoAccepted = c.autoAccepted + 1
                    w:at(0.1, function() w:accept(c, byGUID(peer.guid)) end)
                end,
                declineInvite = function(peer)
                    local inviter = byGUID(peer.guid)
                    if c.pending and c.pending.from == inviter and c.pending.seen then
                        c.declined = c.declined + 1
                        w:decline(c, inviter)
                    end
                end,
                inviteNotice = function(message, peer)
                    if message == "DECLINED:" .. peer.fullName then return "DECLINED" end
                    if message == "FAILED:" .. peer.fullName then return "INVITE_FAILED" end
                end,
                leave = function()
                    c.leaves = c.leaves + 1
                    w:at(option(c, "leaveLag", 0.2), function() w:remove(c) end)
                    return true
                end,
                leaveGroup = function()
                    c.leaves = c.leaves + 1
                    w:at(option(c, "leaveLag", 0.2), function() w:remove(c) end)
                    return true
                end,
                peerPresent = function(peer)
                    if not exact(c, peer) then return nil end
                    return not byGUID(peer.guid).disconnected
                end,
                peerNear = function(peer, yards)
                    if not exact(c, peer) then return nil end
                    return distance(c, byGUID(peer.guid)) <= yards
                end,
                coLocated = function(peer)
                    if not exact(c, peer) then return false, "Your opponent is not in your queue group yet." end
                    local other = byGUID(peer.guid)
                    if c.phaseUnknown or other.phaseUnknown then return false, "Your opponent is in another phase." end
                    if distance(c, other) > 10 then return false, "Move within 10 yards of " .. peer.fullName .. " on the same level." end
                    return true
                end,
                challenge = function(peer)
                    c.challenged = c.challenged + 1
                    local other = byGUID(peer.guid)
                    w:at(0.3, function() w:duelRequest(c, other) end)
                    return true
                end,
                waypoint = function(v) c.waypoints = c.waypoints + 1; c.waypointVenue = v.id; return true end,
                clearWaypoint = function() c.cleared = c.cleared + 1 end,
                discover = function() end,
            }
            c.env, c.queue = env, fd.Queue:New(env)
        end
        w.a, w.b, w.c = w.clients[1], w.clients[2], w.clients[3]
        function w:advance(seconds)
            local finish = self.now + seconds
            local guard = 0
            while true do
                guard = guard + 1
                assert(guard < 200000, "queue world runaway")
                local eventIndex, eventAt, eventSeq
                for index, event in ipairs(self.events) do
                    if event.at <= finish and (not eventAt or event.at < eventAt or event.at == eventAt and event.seq < eventSeq) then
                        eventIndex, eventAt, eventSeq = index, event.at, event.seq
                    end
                end
                local tickClient
                for _, c in ipairs(self.clients) do
                    if c.nextTick <= finish and (not tickClient or c.nextTick < tickClient.nextTick) then tickClient = c end
                end
                if eventIndex and (not tickClient or eventAt <= tickClient.nextTick) then
                    local event = table.remove(self.events, eventIndex)
                    self.now = math.max(self.now, event.at)
                    event.run()
                elseif tickClient then
                    self.now = math.max(self.now, tickClient.nextTick)
                    tickClient.nextTick = tickClient.nextTick + 1
                    if not tickClient.offline then tickClient.queue:Run(function() tickClient.queue:Tick() end) end
                else break end
            end
            self.now = finish
        end
        -- Advances until every listed client is in `state`; returns the time.
        function w:reach(state, limit, list)
            list = list or { self.a, self.b }
            local start = self.now
            while self.now - start < limit do
                local all = true
                for _, c in ipairs(list) do if c.queue.state ~= state then all = false end end
                if all then return self.now - start end
                self:advance(0.25)
            end
            local states = {}
            for _, c in ipairs(list) do states[#states + 1] = c.profile.fullName .. "=" .. c.queue.state .. " (" .. tostring(c.queue.reason) .. ")" end
            error(scenario .. ": did not reach " .. state .. " within " .. limit .. " s: " .. table.concat(states, ", "), 2)
        end
        function w:join(list)
            for _, c in ipairs(list or self.clients) do eq(c.queue:Join(), true, c.profile.fullName .. " joined") end
        end
        function w:travel()
            self:join({ self.a, self.b })
            self:reach("TRAVELLING", 60)
        end
        function w:move(c, x, y) c.profile.x, c.profile.y = x or 0, y or 0 end
        function w:ready()
            self:travel()
            self:move(self.a, -3); self:move(self.b, 3)
            self:reach("READY", 30)
        end
        function w:count(kind, from, channel)
            local total = 0
            for _, m in ipairs(self.sent) do
                if m.kind == kind and (not from or m.from == from) and (not channel or m.channel == channel) then total = total + 1 end
            end
            return total
        end
        function w:noRatings()
            for _, c in ipairs(self.clients) do eq(c.ratingCalls, 0, "queue never calculates ratings") end
        end
        function w:logged(c, topic, pattern)
            for _, entry in ipairs(c.logs) do
                if entry.topic == topic and entry.detail:find(pattern, 1, true) then return true end
            end
            return false
        end
        w.option = option
        return w
    end

    scenario = "invite-first full match and duel handoff"
    local w = world()
    w:join()
    w:reach("INVITED", 15, { w.b })
    eq(w.a.queue.state, "INVITING", "lower GUID coordinator invites immediately with its OFFER")
    eq(w.a.invited, 1, "one native invitation")
    eq(w.b.invited, 0, "the invitee never invites")
    eq(w.b.queue.ticket.inviteSeen, true, "native invitation recognised from the inviter GUID")
    eq(w.a.queue.ticket.id, w.b.queue.ticket.id, "invitee derives the same ticket")
    eq(w.b.queue:GetStatus().reason:find("Accept the group invitation from Alpha-Forever", 1, true) ~= nil, true,
        "invitee is told which invitation to accept")
    local invitedNotice
    for _, notice in ipairs(w.b.notices) do if notice.event == "invited" then invitedNotice = notice end end
    eq(invitedNotice ~= nil, true, "invitee gets a chat/sound notification")
    w:reach("TRAVELLING", 20)
    local ta, tb = w.a.queue.ticket, w.b.queue.ticket
    eq(ta.plan.venue.id, tb.plan.venue.id, "same meeting place")
    eq(ta.plan.deadline, tb.plan.deadline, "same travel deadline from the plan")
    eq(ta.plan.startDeadline, ta.plan.deadline + 120, "start deadline derived from the plan")
    eq(tb.plan.startDeadline, ta.plan.startDeadline, "shared start deadline")
    eq(ta.plan.duration, 300, "five-minute minimum estimate")
    eq(w.a.waypoints, 1, "coordinator waypoint set automatically at travel start")
    eq(w.b.waypoints, 1, "invitee waypoint set automatically at travel start")
    eq(w:count("OFFER", w.a), 1, "exactly one informational OFFER")
    for _, m in ipairs(w.sent) do
        if m.kind == "PLAN" or m.kind == "PLAN_ACK" or m.kind == "GROUP" or m.kind == "STATUS" then
            eq(m.channel, "PARTY", m.kind .. " runs over the exact group")
        end
    end
    w:move(w.a, -3); w:move(w.b, 3)
    w:reach("READY", 20)
    eq(w.a.queue:GetStatus().ownArrived and w.a.queue:GetStatus().peerArrived, true, "status exposes both arrivals")
    local ok, reason = w.b.queue:Challenge()
    eq(ok, false, "only the coordinator requests the duel")
    eq(reason:find("Waiting for Alpha-Forever", 1, true) ~= nil, true, "invitee is told who requests")
    eq(w.b.challenged, 0, "invitee did not call the native request")
    eq(w.a.queue:Challenge(), true, "coordinator requests the native duel")
    w:advance(1)
    eq(w.a.queue.state, "DUEL", "outgoing request hands off to the duel engine")
    eq(w.b.queue.state, "DUEL", "incoming request hands off to the duel engine")
    w:advance(600)
    eq(w.a.queue.state, "DUEL", "a long duel stays under the duel lifecycle")
    w.a.queue:OnDuel("finished", w.a.match)
    w:advance(2)
    eq(w.a.queue.state, "CLEANUP", "first finished client waits for the peer's result")
    eq(w.a.leaves, 0, "group retained for the peer's result barrier")
    eq(w.b.queue.state, "DUEL", "peer FINISHED notice never ends the peer's local duel")
    w.b.queue:OnDuel("finished", w.b.match)
    w:advance(4)
    eq(w.a.queue.state, "IDLE", "finished match ends normally")
    eq(w.b.queue.state, "IDLE", "peer ends normally")
    eq(w.a.leaves + w.b.leaves, 1, "exact queue group left once")
    eq(w.a.group or w.b.group, nil, "queue group dissolved")
    eq(w.a.queue.cancel.reason, "FINISHED", "completion recorded")
    eq(w.a.settings.cooldownUntil, 0, "no cooldown after a completed match")
    w:noRatings()

    scenario = "missing peer terminal is bounded"
    w = world()
    w:ready()
    w.a.queue:Challenge(); w:advance(1)
    w.drop = function(packet) return packet.kind == "CANCEL" end
    w.a.queue:OnDuel("finished", w.a.match)
    w:advance(14)
    eq(w.a.queue.state, "CLEANUP", "result identity kept within the fifteen-second result wait")
    eq(w.a.leaves, 0, "no leave during the result wait")
    w:advance(2)
    eq(w.a.queue.state, "IDLE", "missing peer terminal cannot hold cleanup beyond the wait")
    eq(w.a.leaves, 1, "expired result wait closes the queue-owned group")
    eq(w.b.queue.state, "DUEL", "the peer's duel is never force-aborted by the queue")
    w.b.queue:OnDuel("finished", w.b.match); w:advance(3)
    eq(w.b.queue.state, "IDLE", "late local terminal event ends the peer normally")
    w:noRatings()

    for _, latency in ipairs({ 5, 10 }) do
        scenario = "invite-first pairing at " .. latency .. " s whisper latency"
        w = world({ whisperLatency = latency })
        w:join()
        local elapsed = w:reach("TRAVELLING", 90)
        eq(elapsed < 60, true, "pairing completes despite slow whispers (" .. elapsed .. " s)")
        eq(w.a.invited + w.b.invited, 1, "exactly one native invitation")
        eq(w.a.queue.ticket.id, w.b.queue.ticket.id, "one shared ticket")
        eq(w.a.queue.ticket.plan.deadline, w.b.queue.ticket.plan.deadline, "one travel deadline")
        for _, c in ipairs({ w.a, w.b }) do eq(c.queue.cancel, nil, c.profile.fullName .. " never cancelled") end
        w:noRatings()
    end

    scenario = "invitation arrives before the inviter's PROFILE"
    w = world({ whisperLatency = function(_, from) return from.index == 1 and 12 or 0.5 end })
    w:join()
    w:advance(4)
    eq(w.a.queue.state, "INVITING", "coordinator invites after the fast PROFILE")
    eq(w.b.queue.state ~= "INVITED", true, "invitee cannot yet identify the inviter")
    eq(w.b.queue.pendingInvite ~= nil or w.b.view.grouped == true, true, "native invitation remembered or already accepted")
    w:reach("TRAVELLING", 40)
    eq(w.a.queue.ticket.id, w.b.queue.ticket.id, "late PROFILE resolves the pending invitation")
    eq(w.a.invited, 1, "no second invitation")
    w:noRatings()

    scenario = "coordinator repeats PROFILE and OFFER until the invitee binds"
    w = world({ players = { [2] = { acceptDelay = 1 } } })
    w.drop = function(packet, from)
        return from == w.a and (packet.kind == "PROFILE" or packet.kind == "OFFER") and w.now < 8
    end
    w:join()
    w:reach("INVITING", 10, { w.a })
    w:advance(3)
    eq(w.b.group ~= nil, true, "the invitee accepted the native invitation before recognising it")
    eq(w.b.queue.ticket, nil, "the invitation could not be bound yet")
    eq(w.b.queue.state, "PAUSED", "the grouped invitee pauses its search meanwhile")
    w:reach("TRAVELLING", 20)
    eq(w:count("OFFER", w.a) >= 2, true, "OFFER repeated until the invitee's GROUP arrived")
    eq(w.a.queue.cancel, nil, "no cancellation")
    w:noRatings()

    scenario = "group roster lag: party1 GUID after member count"
    w = world({ guidLag = 6, rosterLag = 1.5 })
    w:join()
    w:reach("TRAVELLING", 60)
    eq(w.a.queue.cancel, nil, "pending native identity never cancels the coordinator")
    eq(w.b.queue.cancel, nil, "pending native identity never cancels the invitee")
    eq(w.a.leaves + w.b.leaves, 0, "pending identity never leaves the group")
    w:noRatings()

    scenario = "inviter with a pending invitation group"
    w = world({ pendingInviterGroup = true, players = { [2] = { inviteLatency = 200 } } })
    w:join()
    w:advance(10)
    eq(w.a.view.grouped and w.a.view.members, 1, "inviter is grouped alone while the invitation is open")
    eq(w.a.queue.state, "INVITING", "pending invitation group is not a changed group")
    eq(w.b.queue.state, "INVITED", "the OFFER alone announces the invitation")
    eq(w.b.queue.ticket.inviteSeen, false, "the native invitation never arrived")
    w:reach("SEARCHING", 70, { w.a })
    eq(w.a.queue.cancel.reason, "GROUP_TIMEOUT", "unanswered invitation times out")
    eq(w.a.rescinded, 1, "the inviter rescinds its own pending invitation")
    eq(w.a.view.grouped, false, "inviter returns to solo")
    w:advance(2)
    eq(w.b.queue.state, "SEARCHING", "an invitee that never saw the invitation is requeued")
    eq(w.b.queue.blocked[w.a.profile.guid], nil, "a missing invitation never blocks the invitee")
    w:noRatings()

    scenario = "ignored invitation"
    w = world({ players = { [2] = { inviteResponse = "ignore" } } })
    w:join()
    w:reach("INVITING", 10, { w.a })
    w:reach("SEARCHING", 70, { w.a })
    eq(w.a.queue.cancel.reason, "GROUP_TIMEOUT", "unanswered invitation times out")
    eq(w.a.queue.blocked[w.b.profile.guid] ~= nil, true, "ignoring the invitation blocks only this pair")
    w:advance(2)
    eq(w.b.queue.state, "IDLE", "the invitee who saw and ignored the invitation leaves the queue")
    eq(w.b.queue.reason:find("did not accept the group invitation", 1, true) ~= nil, true, "invitee told why")
    eq(w.b.declined, 1, "the void native invitation is declined on the invitee")
    eq(w.b.pending, nil, "no stale invitation can be accepted later")
    eq(w.a.settings.cooldownUntil + w.b.settings.cooldownUntil, 0, "no absence cooldown for an invitation")
    w:noRatings()

    scenario = "declined invitation"
    w = world({ players = { [2] = { inviteResponse = "decline" } } })
    w:join()
    w:advance(8)
    eq(w.a.queue.state, "SEARCHING", "coordinator requeues after the decline")
    eq(w.a.queue.cancel.reason, "DECLINED", "decline recognised from the system message")
    eq(w.a.queue.blocked[w.b.profile.guid] ~= nil, true, "decline blocks this pair briefly")
    w:advance(2)
    eq(w.b.queue.state, "SEARCHING", "decliner stays in the queue for other opponents")
    eq(w.b.queue.cancel.reason, "DECLINED", "decliner receives the reason")
    eq(w.b.queue.cancel.received, true, "decliner sees it as the opponent client's message")
    w:advance(60)
    eq(w.a.invited, 1, "blocked pair is not invited again within two minutes")
    eq(w.a.queue.queuedAt, BASE + 0, "original wait preserved on requeue")
    w:noRatings()

    scenario = "auto-accept setting"
    w = world({ players = { [2] = { inviteResponse = "ignore" } } })
    eq(w.b.queue:Configure({ autoAcceptQueueInvite = true }), true, "auto-accept is a preference")
    w:join()
    w:reach("TRAVELLING", 30)
    eq(w.b.autoAccepted, 1, "matched inviter's invitation accepted automatically once")
    eq(w.b.queue:Configure({ autoAcceptQueueInvite = false }), true, "auto-accept can change during a match")
    eq(w.b.queue:Configure({ autoAcceptQueueInvite = "yes" }), false, "auto-accept is a boolean")
    w:noRatings()

    scenario = "settings and queue admission"
    w = world()
    eq(w.a.queue:Configure({ levelGap = 0 }), true, "equal-level preference configurable")
    eq(w.a.settings.levelGap, 0, "preference saved")
    eq(w.a.queue:Configure({ levelGap = 6 }), false, "invalid gap rejected")
    eq(w.a.queue:Configure({ scope = "CONTINENT" }), true, "continent discovery selectable")
    eq(w.a.queue:Configure({ scope = "RULESET" }), true, "ruleset discovery selectable")
    eq(w.a.queue:Configure({ ruleset = "PVP" }), false, "native ruleset cannot be manually overridden")
    eq(w.a.queue:Configure({ hidden = true }), false, "unsupported setting excluded")
    w.a.settings.scope = "ZONE"
    w.a.settings.ruleset = nil
    eq(w.a.queue:Join(), false, "unavailable automatic ruleset waits for native character data")
    w.a.settings.ruleset, w.a.dead = "PVP", true
    eq(w.a.queue:Join(), false, "dead player excluded")
    w.a.dead = false
    w.a.catalog = {}
    eq(w.a.queue:Join(), true, "empty location catalog cannot block discovery")
    eq(w.a.queue:Configure({ scope = "ZONE" }), false, "active queue freezes criteria")
    eq(w.b.queue:Join(), true, "other player joins")
    w:advance(6)
    eq(w.a.queue:GetStatus().discovered, 1, "opponent discovered independently of meeting places")
    eq(w.a.queue.state, "SEARCHING", "missing venue cannot pair")
    eq(w.a.queue:GetStatus().searchReason, "NO_VENUE", "missing place explained separately")
    eq(w.a.invited, 0, "no invitation without a shared tested place")
    w.a.catalog = { clearing() }
    w:reach("INVITED", 10, { w.b })
    eq(w.a.queue.state, "INVITING", "an available place resumes matching without rejoining")

    scenario = "venue intersection from the PROFILE digest"
    local nearMid, side = clearing({ id = "mid-a" }), clearing({ id = "shared-b", x = 60 })
    w = world({ players = { [1] = { catalog = { nearMid, side } }, [2] = { catalog = { side } } } })
    w:join()
    w:reach("TRAVELLING", 30)
    eq(w.a.queue.ticket.plan.venue.id, "shared-b", "only a place in both digests is planned")
    eq(w:count("PLAN_REJECT"), 0, "intersection avoids a rejected plan")
    w = world({ players = { [1] = { catalog = { nearMid } }, [2] = { catalog = { side } } } })
    w:join()
    w:advance(20)
    eq(w.a.queue.state, "SEARCHING", "an empty intersection never invites")
    eq(w.a.invited, 0, "no invitation for a pair without a common place")
    eq(w.a.queue:GetStatus().searchReason, "NO_VENUE", "empty intersection explained")
    eq(w.a.queue.reason:find("share no tested place", 1, true) ~= nil, true, "explanation names the missing common place")

    scenario = "PLAN_REJECT re-plans without the rejected place"
    local mismatched = clearing({ id = "mid-a", x = 1 })
    w = world({ players = { [1] = { catalog = { nearMid, side } }, [2] = { catalog = { mismatched, side } } } })
    w:join()
    w:reach("TRAVELLING", 40)
    eq(w:count("PLAN_REJECT", w.b), 1, "invitee rejects the place it resolves differently")
    eq(w.a.queue.ticket.plan.venue.id, "shared-b", "coordinator re-plans with the remaining place")
    eq(w.b.queue.ticket.plan.venue.id, "shared-b", "both travel to the agreed place")
    eq(w.a.queue.cancel, nil, "a rejected place is not a cancellation")
    w = world({ players = { [1] = { catalog = { nearMid } }, [2] = { catalog = { mismatched } } } })
    w:join()
    w:advance(15)
    eq(w.a.queue.cancel and w.a.queue.cancel.reason, "PLAN_INVALID", "no remaining place is PLAN_INVALID")
    eq(w.a.queue.blocked[w.b.profile.guid], nil, "technical outcome does not block the pair")
    eq(w.a.queue.state == "SEARCHING" or w.a.queue.state == "INVITING", true, "coordinator requeued automatically")
    w:noRatings()

    scenario = "BUSY with three simultaneous searchers"
    -- A and B are 200 apart, so both can only pair with C and both invite it.
    w = world({ count = 3, players = { [1] = { profile = { rating = 1400 } }, [2] = { profile = { rating = 1600 } },
        [3] = { profile = { rating = 1500 } } } })
    w:join()
    -- C's profile reaches both before either coordinator's first pulse.
    w.c.queue:Announce(w.a.profile.fullName); w.c.queue:Announce(w.b.profile.fullName)
    w:advance(30)
    eq(w.a.invited + w.b.invited, 2, "both coordinators invited the same player")
    local matched = 0
    for _, c in ipairs(w.clients) do if c.queue.ticket then matched = matched + 1 end end
    eq(matched, 2, "exactly one pair holds a ticket")
    eq(w.c.queue.ticket ~= nil, true, "the highest GUID is matched by one coordinator")
    local loser = w.a.queue.ticket and w.b or w.a
    eq(loser.queue.state, "SEARCHING", "the other coordinator returns to searching")
    eq(loser.queue.cancel.reason == "BUSY" or loser.queue.cancel.reason == "INVITE_FAILED", true,
        "the competing offer ends as a transient BUSY/invite failure")
    eq(loser.queue.blocked[w.c.profile.guid], nil, "BUSY never blocks the pair")
    eq(loser.queue.retryAt[w.c.profile.guid] ~= nil, true, "BUSY delays the next offer to that player")
    eq(loser.queue.queuedAt, BASE, "BUSY preserves the original wait")
    w:noRatings()
    -- Without a native failure notice the busy invitee's addon answers BUSY.
    w = world({ count = 3, silentCollision = true, players = { [1] = { profile = { rating = 1400 } },
        [2] = { profile = { rating = 1600 } }, [3] = { profile = { rating = 1500 } } } })
    w:join()
    w.c.queue:Announce(w.a.profile.fullName); w.c.queue:Announce(w.b.profile.fullName)
    w:advance(10)
    loser = w.a.queue.ticket and w.b or w.a
    eq(loser.queue.cancel and loser.queue.cancel.reason, "BUSY", "the busy invitee answers the second OFFER with BUSY")
    eq(loser.queue.cancel.received, true, "BUSY comes from the invitee's client")
    eq(loser.queue.state, "SEARCHING", "the coordinator searches again at once")
    eq(loser.queue.blocked[w.c.profile.guid], nil, "BUSY never blocks the pair")
    eq(w.c.queue.ticket.peer.guid ~= loser.profile.guid, true, "the invitee keeps its first match")
    w:noRatings()

    scenario = "best coordinatable candidate is offered"
    w = world({ count = 3, players = { [2] = { profile = { rating = 1500 } }, [1] = { profile = { rating = 1500 } },
        [3] = { profile = { rating = 1590 } } } })
    w.a.offline = true
    w:join({ w.b, w.c })
    w:reach("INVITED", 15, { w.c })
    eq(w.b.queue.state, "INVITING", "middle GUID offers its best higher-GUID candidate")
    eq(w.b.queue.ticket.peer.guid, w.c.profile.guid, "selection skips past candidates it cannot coordinate")
    w:noRatings()

    scenario = "READY hysteresis"
    w = world()
    w:ready()
    w:move(w.b, 14)
    w:advance(30)
    eq(w.a.queue.state, "READY", "stepping 11 yd away never cancels READY")
    eq(w.b.queue.state, "READY", "peer remains READY")
    local status = w.a.queue:GetStatus()
    eq(status.colocation and status.colocation:find("Move within 10 yards", 1, true) ~= nil, true, "co-location hint shown")
    ok, reason = w.a.queue:Challenge()
    eq(ok, false, "challenge refused while apart")
    eq(reason:find("Move within 10 yards", 1, true) ~= nil, true, "refusal has a visible reason")
    eq(w.a.queue.state, "READY", "a refused challenge never cancels")
    w:move(w.b, 3)
    eq(w.a.queue:Challenge(), true, "challenge succeeds once close again")
    w:noRatings()

    scenario = "start deadline"
    w = world()
    w:ready()
    local startDeadline = w.a.queue.ticket.plan.startDeadline
    w:advance(startDeadline - (BASE + math.floor(w.now)) - 2)
    eq(w.a.queue.state, "READY", "READY lasts until the shared start deadline")
    w:advance(6)
    eq(w.a.queue.cancel.reason, "START_TIMEOUT", "start deadline ends the match")
    eq(w.a.queue.state, "IDLE", "start timeout returns to idle")
    eq(w.b.queue.state, "IDLE", "peer start timeout returns to idle")
    eq(w.a.settings.cooldownUntil + w.b.settings.cooldownUntil, 0, "no-start timeout is not absence")
    w:noRatings()

    for _, order in ipairs({ "arrived first", "absent first" }) do
        scenario = "travel timeout decided locally: " .. order
        w = world({ players = order == "absent first" and { [2] = { clockSkew = 1 } } or { [1] = { clockSkew = 1 } } })
        w:travel()
        local waitedAt = w.a.queue.queuedAt
        w:move(w.a, 0)
        w:advance(5)
        eq(w.a.queue.ticket.ownArrived, true, "three samples latch arrival")
        w:move(w.a, 30)
        w:advance(2)
        eq(w.a.queue.ticket.ownArrived, true, "arrival stays latched within the venue walk-around")
        w:advance(w.a.queue.ticket.plan.deadline - (BASE + math.floor(w.now)) + 3)
        eq(w.a.queue.state, "SEARCHING", "present player requeued")
        eq(w.a.queue.queuedAt, waitedAt, "present player's wait preserved")
        eq(w.a.settings.cooldownUntil, 0, "present player never gets the cooldown")
        eq(w.b.queue.state, "IDLE", "absent player leaves the queue")
        eq(w.b.settings.cooldownUntil > BASE, true, "absent player's own position gives the cooldown")
        eq(w.b.queue:Join(), false, "cooldown enforced")
        w:noRatings()
    end

    scenario = "both absent and unknown position at the travel deadline"
    w = world()
    w:travel()
    w.b.unreadablePosition = true
    w:advance(w.a.queue.ticket.plan.deadline - (BASE + math.floor(w.now)) + 3)
    eq(w.a.settings.cooldownUntil > BASE, true, "readable absence gives a cooldown")
    eq(w.b.settings.cooldownUntil, 0, "unreadable position never gives a cooldown")
    eq(w.a.queue.state, "IDLE", "absent player idle")
    eq(w.b.queue.state, "IDLE", "unknown position idle without penalty")
    w:noRatings()

    scenario = "peer arrival from native distance when STATUS is lost"
    w = world()
    w:travel()
    w.drop = function(packet, from) return packet.kind == "STATUS" and from == w.b end
    w:move(w.a, -3); w:move(w.b, 3)
    w:reach("READY", 20)
    eq(w.a.queue.ticket.peerArrived, true, "native party distance confirms the peer")
    w:noRatings()

    scenario = "lost PLAN_ACK is acknowledged by STATUS"
    w = world()
    w.drop = function(packet) return packet.kind == "PLAN_ACK" end
    w:join()
    w:reach("TRAVELLING", 40)
    eq(w.dropped.PLAN_ACK >= 1, true, "plan acknowledgments were lost")
    eq(w.a.queue.ticket.plan.deadline, w.b.queue.ticket.plan.deadline, "travel deadline still shared")
    w:noRatings()

    scenario = "peer silence"
    w = world()
    w:travel()
    w.drop = function(_, from) return from == w.b end
    w:advance(45)
    eq(w.a.queue.state, "TRAVELLING", "native party presence keeps a quiet peer in the match")
    w.b.disconnected = true
    w:advance(35)
    eq(w.a.queue.cancel and w.a.queue.cancel.reason, "PEER_SILENT", "silent and disconnected peer ends the match")
    eq(w.a.queue.blocked[w.b.profile.guid], nil, "technical silence does not block the pair")
    eq(w.a.queue.queuedAt ~= nil, true, "coordinator requeued")
    w:noRatings()

    scenario = "terminal CANCEL precedes the deferred LeaveParty"
    w = world({ whisperLatency = 10 })
    w:travel()
    w.a.queue:Leave()
    eq(w.a.queue.state, "CLEANUP", "leaving client cleans up its group")
    eq(w.a.leaves, 0, "LeaveParty deferred so the CANCEL can leave first")
    w:advance(0.5)
    eq(w.b.queue.cancel and w.b.queue.cancel.reason, "CANCELLED", "peer receives the real reason over PARTY")
    eq(w.b.queue.cancel.received, true, "peer shows it as the opponent client's reason")
    eq(w.b.queue.state == "SEARCHING" or w.b.queue.state == "CLEANUP", true, "peer requeues after the opponent left")
    w:advance(3)
    eq(w.a.leaves >= 1, true, "group left after the delay")
    eq(w.a.queue.state, "IDLE", "the user who left is idle")
    eq(w.b.queue.blocked[w.a.profile.guid] ~= nil, true, "an explicit leave blocks the pair briefly")
    eq(w:count("LEAVE", w.a) <= 10, true, "LEAVE only to a bounded number of fresh peers")
    w:noRatings()

    scenario = "opponent left the group without a CANCEL"
    w = world()
    w:travel()
    w.drop = function(packet, from) return packet.kind == "CANCEL" and from == w.b end
    w.b.queue.ticket = nil; w.b.queue.state = "IDLE"
    w:remove(w.b)
    w:advance(3)
    eq(w.a.queue.state, "TRAVELLING", "dissolved group waits for a late CANCEL")
    w:advance(5)
    eq(w.a.queue.cancel and w.a.queue.cancel.reason, "OPPONENT_LEFT", "owned group gone means the opponent left")
    eq(w.a.queue.state, "SEARCHING", "transient outcome requeues")
    w:noRatings()

    scenario = "reload or logout sends CANCEL synchronously"
    w = world()
    w:travel()
    w.a.queue:Logout()
    w.a.offline = true
    w:advance(1)
    eq(w.b.queue.cancel and w.b.queue.cancel.reason, "RELOAD", "peer learns about the reload")
    eq(w.b.queue.blocked[w.a.profile.guid], nil, "reload is technical")
    w:advance(10)
    eq(w.b.queue.state, "SEARCHING", "peer requeued with its wait")
    w:noRatings()

    scenario = "positive group changes"
    for _, change in ipairs({ "third member", "raid" }) do
        w = world()
        w:travel()
        if change == "raid" then w.a.group.raid = true else
            local stranger = { profile = { guid = "Player-1-DDD" } }
            w.a.group.members[3] = stranger
        end
        w:roster(w.a); w:roster(w.b)
        w:advance(3)
        eq(w.a.queue.cancel and w.a.queue.cancel.reason, "GROUP_CHANGED", change .. " is a confirmed group change")
        eq(w.a.leaves + w.b.leaves, 0, change .. " group is never left by the queue")
        eq(w.a.queue.state ~= "CLEANUP", true, change .. " cleanup does not trap the queue")
        eq(w.a.queue:GetStatus().cleanupStatus ~= nil, true, change .. " advises leaving manually")
        w:noRatings()
    end

    scenario = "CLEANUP is bounded"
    w = world()
    w:travel()
    w.a.groupUnreadable = true
    w.drop = function(packet) return packet.kind == "CANCEL" end
    w.a.queue:Finish("PEER_SILENT")
    eq(w.a.queue.state, "CLEANUP", "unreadable owned group waits")
    w:advance(18)
    eq(w.a.queue.state, "CLEANUP", "cleanup waits within its bound")
    w:advance(3)
    eq(w.a.queue.state ~= "CLEANUP", true, "cleanup ends after twenty seconds")
    eq(w.a.queue.cancel.reason, "PEER_SILENT", "cancel reason kept separately from cleanup status")
    w = world()
    w:travel()
    w.a.groupUnreadable = true
    w.a.queue:Finish("PEER_SILENT")
    eq(w.a.queue:Leave(), true, "Leave from CLEANUP is accepted")
    eq(w.a.queue.state, "IDLE", "Leave from CLEANUP forces IDLE")

    scenario = "Leave group after a bounded cleanup"
    w = world()
    w:travel()
    w.a.env.leave = function() w.a.leaves = w.a.leaves + 1; return false end
    w.drop = function(packet) return packet.kind == "CANCEL" end
    w.a.queue:Finish("PEER_SILENT")
    w:advance(22)
    eq(w.a.queue.state ~= "CLEANUP", true, "cleanup ended at its bound although LeaveParty did nothing")
    eq(w.a.queue:GetStatus().cleanupStatus ~= nil, true, "advisory to leave the group")
    eq(w.a.queue:GetStatus().groupAction, true, "Leave group offered for the leftover queue pair")
    eq(w.a.queue:LeaveGroup(), true, "Leave group calls the native leave")
    w:advance(2)
    eq(w.a.group, nil, "the leftover group is gone")
    eq(w.a.queue:GetStatus().groupAction, false, "no Leave group action once solo")
    eq(w.a.queue:GetStatus().cleanupStatus, nil, "advisory cleared once solo")

    scenario = "duel fallback deadline"
    w = world()
    w:ready()
    w.a.queue:Challenge(); w:advance(1)
    eq(w.a.queue.state, "DUEL", "duel hand-off")
    w:advance(w.a.fd.C.MATCH_TIMEOUT + 61)
    eq(w.a.queue.cancel and w.a.queue.cancel.reason, "DUEL", "a duel without any engine notice ends at MATCH_TIMEOUT + 60 s")
    eq(w.a.queue.state ~= "DUEL", true, "the queue never stays in DUEL forever")

    scenario = "ticket-less leave in an unrelated group"
    w = world()
    eq(w.a.queue:Join(), true, "joined while solo")
    w:form(w.a, w.b)
    w:advance(3)
    eq(w.a.queue.state, "PAUSED", "unrelated group pauses the search")
    w.a.queue:Leave()
    eq(w.a.queue.state, "IDLE", "ticket-less cancel goes straight to IDLE")
    eq(w.a.leaves, 0, "a group the queue did not create is never left")

    scenario = "unrelated duel while searching and during a match"
    w = world()
    eq(w.a.queue:Join(), true, "joined")
    local session = w.a.queue.session
    w.a.unrelatedDuel = true
    w.a.queue:OnDuel("request", { opponent = { guid = "Player-1-DDD", fullName = "Stranger-Forever" } })
    w:advance(5)
    eq(w.a.queue.state, "PAUSED", "unrelated duel pauses the search")
    eq(w.a.queue.reason:find("unrelated duel", 1, true) ~= nil, true, "pause explained")
    w.a.unrelatedDuel = false
    w:advance(2)
    eq(w.a.queue.state, "SEARCHING", "search resumes after the unrelated duel")
    eq(w.a.queue.session, session, "same queue session and wait")
    w = world()
    w:travel()
    w.a.queue:OnDuel("request", { opponent = { guid = "Player-1-DDD", fullName = "Stranger-Forever" } })
    w:advance(2)
    eq(w.a.queue.state, "TRAVELLING", "unrelated request ignored during an active match")
    eq(w.b.queue.cancel, nil, "peer unaffected")

    scenario = "peer CANCEL(DUEL) never ends a local duel"
    w = world()
    w:ready()
    w.a.queue:Challenge(); w:advance(1)
    w.b.queue:OnDuel("unrated", w.b.match)
    w:advance(2)
    eq(w.b.queue.cancel.reason, "DUEL", "unrated duel ends the peer's queue match")
    eq(w.a.queue.state, "DUEL", "local duel engine still controls this client")
    w.a.queue:OnDuel("unrated", w.a.match)
    w:advance(3)
    eq(w.a.queue.state, "IDLE", "local unrated notice ends the queue match")
    w:noRatings()

    scenario = "withdrawn duel request returns to READY"
    w = world()
    w:ready()
    w.a.queue:Challenge(); w:advance(1)
    w.a.queue:OnDuel("abort", w.a.match)
    w.b.queue:OnDuel("abort", w.b.match)
    eq(w.a.queue.state, "READY", "a request declined before the countdown keeps the match")
    eq(w.b.queue.state, "READY", "peer keeps the match")
    eq(w.a.queue:Challenge(), true, "the duel can be requested again")
    w:noRatings()

    scenario = "eligibility is decided once"
    w = world()
    w:travel()
    w.a.profile.level, w.a.profile.rating, w.a.profile.mapID = 31, 1600, 11
    w:advance(10)
    eq(w.a.queue.state, "TRAVELLING", "level, rating or map changes do not cancel the travel")
    eq(w.a.queue.cancel, nil, "no cancellation")

    scenario = "loading grace"
    w = world()
    w:travel()
    w.a.queue:World(true)
    w.a.unreadablePosition = true
    w:advance(40)
    w.a.queue:World(false)
    w:advance(10)
    eq(w.a.queue.state, "TRAVELLING", "loading screen and grace keep the match")
    w.a.unreadablePosition = false
    w:advance(10)
    eq(w.a.queue.state, "TRAVELLING", "positions recover after loading")

    scenario = "PARTY traffic budget while travelling"
    w = world()
    w:ready()
    local first = #w.sent
    w:advance(60)
    local party = { [w.a] = 0, [w.b] = 0 }
    for index = first + 1, #w.sent do
        local m = w.sent[index]
        if m.channel == "PARTY" then party[m.from] = party[m.from] + 1 end
    end
    eq(party[w.a] / 60 <= 0.7, true, "coordinator stays under 0.7 PARTY messages per second")
    eq(party[w.b] / 60 <= 0.7, true, "invitee stays under 0.7 PARTY messages per second")
    eq(party[w.a] >= 15, true, "periodic STATUS continues")

    scenario = "invalid control identity"
    w = world()
    w:travel()
    local good = w.b.queue:Control("CANCEL", { reason = "CANCELLED" })
    local function inject(c, packet, sender)
        local payload = assert(c.fd.QueueProtocol:Encode(packet))
        c.queue:Receive(assert(c.fd.QueueProtocol:Decode(payload)), sender)
    end
    inject(w.a, good, "Stranger-Forever")
    eq(w.a.queue.state, "TRAVELLING", "foreign sender cannot cancel")
    for _, field in ipairs({ "session", "peerSession", "ticket" }) do
        local stale = w.a.fd.Copy(good); stale[field] = "dead-beef"
        inject(w.a, stale, w.b.profile.fullName)
        eq(w.a.queue.state, "TRAVELLING", "wrong " .. field .. " ignored")
    end

    scenario = "diagnostics without tickets or positions"
    w = world()
    w:travel()
    w.a.queue:Leave(); w:advance(3)
    eq(w:logged(w.a, "queue cancel", "CANCELLED TRAVELLING local idle"), true, "local cancellation logged with its outcome")
    eq(w:logged(w.b, "queue cancel", "CANCELLED"), true, "received cancellation logged")
    for _, c in ipairs({ w.a, w.b }) do
        for _, entry in ipairs(c.logs) do
            eq(entry.detail:find(c.fd.Copy(w.a.queue.session or "zzzz"), 1, true), nil, "no session in diagnostics")
            eq(entry.detail:find("-100", 1, true), nil, "no positions in diagnostics")
        end
    end

    scenario = "optional diagnostics and errors stay isolated"
    w = world()
    w.a.logError = true
    w:join()
    w:reach("TRAVELLING", 30)
    eq(w.a.queue.cancel, nil, "a failing logger cannot stop pairing")
    w.a.groupStateError = true
    w:advance(2)
    eq(w.a.queue.state, "TRAVELLING", "a failing roster getter is pending, not changed")
    w.a.groupStateError = false
    local before = w.a.errors
    w.a.queue:Run(function() error("synthetic queue failure") end)
    eq(w.a.errors, before + 1, "queue error persisted")
    eq(w.a.queue.cancel.reason, "ERROR", "queue error ends the match with a specific reason")
    w:advance(2)
    eq(w.b.queue.cancel and w.b.queue.cancel.reason, "ERROR", "peer told about the addon error")
    w:noRatings()

    scenario = "notifications"
    w = world()
    w:ready()
    local events = {}
    for _, notice in ipairs(w.a.notices) do events[notice.event] = true end
    for _, event in ipairs({ "match", "travel", "ready" }) do eq(events[event], true, "coordinator notified: " .. event) end
    events = {}
    for _, notice in ipairs(w.b.notices) do events[notice.event] = true end
    for _, event in ipairs({ "invited", "travel", "ready" }) do eq(events[event], true, "invitee notified: " .. event) end
    w.a.queue:Leave(); w:advance(1)
    local cancelled = false
    for _, notice in ipairs(w.b.notices) do
        if notice.event == "cancel" and notice.text:find("Your opponent's client cancelled because they left the queue", 1, true) then cancelled = true end
    end
    eq(cancelled, true, "received cancellation names the opponent client's reason")

    scenario = "rating windows and preferences"
    w = world({ players = { [2] = { profile = { rating = 1650 } } } })
    w:join()
    w:advance(110)
    eq(w.a.queue.state, "SEARCHING", "150 rating difference waits for expansion")
    eq(w.a.queue:Window(w.a.queue.queuedAt), 100, "first window is one hundred")
    w:reach("INVITING", 20, { w.a })
    eq(w.a.queue:Window(w.a.queue.queuedAt), 200, "two-minute window is two hundred")
    w = world({ players = { [2] = { profile = { level = 31 } } } })
    w.b.settings.levelGap = 0
    w:join()
    w:advance(10)
    eq(w.a.queue:GetStatus().searchReason, "LEVEL", "peer's stricter level preference enforced")
    w = world({ players = { [2] = { profile = { faction = "Alliance" } } } })
    w:join()
    w:advance(10)
    eq(w.a.queue:GetStatus().searchReason, "FACTION", "cross-faction excluded")

    scenario = "discovery freshness and native sender binding"
    w = world({ count = 3 })
    w:join()
    local p = w.b.fd.Copy(w.b.queue.ownProfile); p.kind = "PROFILE"
    local function injectProfile(sender, changes)
        local packet = w.b.fd.Copy(p)
        for key, value in pairs(changes or {}) do packet[key] = value end
        local payload = assert(w.a.fd.QueueProtocol:Encode(packet))
        w.a.queue:Receive(assert(w.a.fd.QueueProtocol:Decode(payload)), sender)
    end
    w.a.queue.peers = {}
    injectProfile(w.b.profile.fullName, { joinedAt = BASE + 3 })
    eq(w.a.queue.peers[p.guid], nil, "future queue epoch rejected")
    injectProfile(w.b.profile.fullName)
    eq(w.a.queue.peers[p.guid].fullName, w.b.profile.fullName, "native transport sender owns discovered identity")
    injectProfile(w.c.profile.fullName)
    eq(w.a.queue.peers[p.guid].fullName, w.b.profile.fullName, "different sender cannot overwrite bound GUID")
    w.a.queue:Receive({ kind = "LEAVE", guid = p.guid, session = "dead-beef" }, w.b.profile.fullName)
    eq(w.a.queue.peers[p.guid] ~= nil, true, "old-session leave cannot delete current profile")
    w.a.queue:Receive({ kind = "LEAVE", guid = p.guid, session = p.session }, w.b.profile.fullName)
    eq(w.a.queue.peers[p.guid], nil, "bound current session can leave")

    scenario = "presence alone never joins a passive player"
    w = world()
    eq(w.a.queue:Join(), true, "one player explicitly joins")
    w:advance(181)
    eq(w.b.queue.state, "IDLE", "discovery cannot automatically join a nearby addon player")
    eq(w.a.queue:GetStatus().discovered, 0, "a non-joined addon player is not a queue profile")
    eq(w:count("QUERY", w.a) <= 7, true, "passive discovery keeps the thirty-second cadence")
end
