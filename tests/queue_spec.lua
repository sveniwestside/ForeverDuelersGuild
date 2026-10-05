return function(_, equal, newNamespace)
    local scenario = "queue"
    local function eq(actual, expected, label)
        equal(actual, expected, scenario .. ": " .. label)
    end
    local function world(options)
        options = options or {}
        local w = { now = 0, clients = {}, messages = {}, sent = {}, dropped = {}, epochBase = 1700000000 }
        local names, guids = { "Alpha-Forever", "Beta-Forever", "Gamma-Forever" },
            { "Player-1-AAA", "Player-1-BBB", "Player-1-CCC" }
        for index = 1, options.count or 2 do
            local fd = newNamespace()
            for _, name in ipairs({ "QueueProtocol", "Venues", "Queue" }) do
                if not fd[name] then assert(loadfile("ForeverDuel/" .. name .. ".lua"))("ForeverDuel", fd) end
            end
            local c = { fd = fd, nonceCounter = 0, invited = 0, challenged = 0, left = 0, leaveAttempts = 0,
                waypoint = 0, cleared = 0, ratingCalls = 0, renders = 0, logs = {},
                settings = { scope = "ZONE", levelGap = 5, ruleset = "PVP", cooldownUntil = 0,
                    continentVerified = true, rulesetVerified = true },
                profile = { guid = guids[index], fullName = names[index], level = 30, maxLevel = 60,
                    rating = 1500, faction = "Horde", mapID = 10, continentID = 0, x = index == 1 and -100 or 100, y = 0 },
                catalog = { { id = "verified-test-clearing", name = "Fictional verified clearing", mapID = 10,
                    continentID = 0, x = 0, y = 0, mapX = 0.5, mapY = 0.5,
                    factions = { Horde = true, Alliance = true }, minPlayerLevel = 1,
                    zoneMinLevel = 1, zoneMaxLevel = 10, verified = true, duelAllowed = true } } }
            for key, value in pairs(options.players and options.players[index] or {}) do c.profile[key] = value end
            w.clients[index] = c
            fd.Rating.Calculate = function() c.ratingCalls = c.ratingCalls + 1; error("queue must not calculate ratings") end
            local function members()
                local count = 0
                for _ in pairs(c.group or {}) do count = count + 1 end
                return count
            end
            local env = {
                now = function() return w.now end,
                epoch = function() return w.epochBase + math.floor(w.now) end,
                nonce = function()
                    c.nonceCounter = c.nonceCounter + 1
                    return fd.Protocol:Nonce(w.epochBase + math.floor(w.now), c.nonceCounter, index * 1024)
                end,
                own = function()
                    if c.missingProfile then return nil end
                    return fd.Copy(c.profile)
                end,
                settings = function() return c.settings end,
                save = function(s) c.settings = fd.Copy(s) end,
                catalog = function() return c.catalog end,
                world = function() error("test catalog already has world coordinates") end,
                available = function()
                    if c.dead then return false, "Player is dead." end
                    if c.instanced then return false, "Player is in an instance." end
                    if members() >= 2 then return false, "Player is grouped." end
                    return true
                end,
                combat = function() return c.combat or false end,
                solo = function() return members() < 2 end,
                party = function(peer)
                    if c.groupPending or c.raid then return false end
                    return members() == 2 and c.group[c.profile.guid] and c.group[peer.guid] or false
                end,
                candidates = function()
                    local result = {}
                    for _, other in ipairs(w.clients) do
                        result[#result + 1] = { guid = other.profile.guid, fullName = other.profile.fullName }
                    end
                    return result
                end,
                send = function(packet, target)
                    local payload, reason = fd.QueueProtocol:Encode(packet)
                    assert(payload, "engine emitted invalid " .. tostring(packet.kind) .. ": " .. tostring(reason))
                    local decoded = assert(fd.QueueProtocol:Decode(payload))
                    local message = { payload = payload, from = c.profile.fullName, to = target, kind = decoded.kind, sender = c }
                    w.sent[#w.sent + 1] = message
                    if w.drop and w.drop(decoded, c, target) then
                        w.dropped[decoded.kind] = (w.dropped[decoded.kind] or 0) + 1
                    else w.messages[#w.messages + 1] = message end
                    return true
                end,
                render = function()
                    c.renders = c.renders + 1
                    local state = c.queue and c.queue.state
                    if state == "READY" and c.renderedState ~= "READY" then c.readyAt = w.now end
                    if state == "TRAVELLING" and c.renderedState ~= "TRAVELLING" then c.travelAt = w.now end
                    c.renderedState = state
                end,
                log = function(topic, ...)
                    c.logs[#c.logs + 1] = { topic = topic, detail = table.concat({ ... }, " ") }
                end,
                invite = function(peer)
                    c.invited = c.invited + 1
                    c.inviteTarget = peer.guid
                    return not c.blockInvite, c.blockInvite and "Native invitation blocked." or nil
                end,
                leave = function(peer, owned)
                    c.leaveAttempts = c.leaveAttempts + 1
                    -- Same guard as the native adapter: only the queue's exact
                    -- two-person group is eligible for automatic cleanup.
                    if owned and not c.groupPending and not c.raid and members() == 2
                        and c.group[c.profile.guid] and c.group[peer.guid] then
                        c.group[c.profile.guid] = nil
                        c.group = nil
                        c.left = c.left + 1
                        return true
                    end
                    return false
                end,
                coLocated = function(peer)
                    if c.phaseUnknown then return false end
                    for _, other in ipairs(w.clients) do
                        if other.profile.guid == peer.guid then
                            return not other.phaseUnknown and c.profile.mapID == other.profile.mapID
                                and c.profile.continentID == other.profile.continentID
                                and math.sqrt((c.profile.x - other.profile.x)^2 + (c.profile.y - other.profile.y)^2) <= 10
                        end
                    end
                    return false
                end,
                waypoint = function(v) c.waypoint = c.waypoint + 1; c.waypointVenue = v.id; return true end,
                clearWaypoint = function() c.cleared = c.cleared + 1 end,
                challenge = function(peer) c.challenged = c.challenged + 1; c.challengeTarget = peer.guid; return true end,
            }
            if options.nativeGroupStates then
                env.groupState = function(peer)
                    if c.groupStateError then error("native roster unavailable") end
                    if c.groupPending then return "PENDING" end
                    if c.raid or members() > 2 then return "CHANGED" end
                    if members() < 2 then return "SOLO" end
                    return c.group[c.profile.guid] and c.group[peer.guid] and "EXACT" or "CHANGED"
                end
            end
            c.env, c.queue = env, fd.Queue:New(env)
        end
        w.a, w.b, w.c = w.clients[1], w.clients[2], w.clients[3]
        function w:deliver(index)
            local m = table.remove(self.messages, index or 1)
            if not m then return end
            for _, recipient in ipairs(self.clients) do
                if recipient.profile.fullName == m.to then
                    recipient.queue:Receive(assert(recipient.fd.QueueProtocol:Decode(m.payload)), m.from)
                end
            end
            return m
        end
        function w:flush()
            local count = 0
            while #self.messages > 0 do
                count = count + 1
                assert(count < 1000, "queue wire did not settle")
                self:deliver()
            end
        end
        function w:inject(c, packet, sender)
            local payload = assert(c.fd.QueueProtocol:Encode(packet))
            c.queue:Receive(assert(c.fd.QueueProtocol:Decode(payload)), sender)
        end
        function w:tick(order, concurrent)
            for _, index in ipairs(order or (self.c and { 1, 2, 3 } or { 1, 2 })) do
                self.clients[index].queue:Tick()
                if not concurrent then self:flush() end
            end
            self:flush()
        end
        function w:advance(seconds, order)
            local untilTime = self.now + seconds
            while self.now < untilTime do
                self.now = math.min(untilTime, self.now + 1)
                self:tick(order)
            end
        end
        function w:join()
            for _, c in ipairs(self.clients) do eq(c.queue:Join(), true, "eligible player joined") end
        end
        function w:group(a, b)
            a, b = a or self.a, b or self.b
            local group = { [a.profile.guid] = true, [b.profile.guid] = true }
            a.group, b.group = group, group
        end
        function w:pair()
            self:join()
            self:advance(4)
            eq(self.a.queue.state, "GROUPING", "coordinator completes reservation")
            eq(self.b.queue.state, "GROUPING", "peer completes reservation")
        end
        function w:travel()
            self:pair()
            self:group()
            self:advance(5)
            eq(self.a.queue.state, "TRAVELLING", "coordinator received travel acknowledgment")
            eq(self.b.queue.state, "TRAVELLING", "peer received confirmed travel plan")
        end
        function w:move(c, x, y) c.profile.x, c.profile.y = x or 0, y or 0 end
        function w:ready()
            self:travel()
            self:move(self.a)
            self:move(self.b)
            self:advance(6)
            eq(self.a.queue.state, "READY", "coordinator's arrival and visibility confirmed")
            eq(self.b.queue.state, "READY", "peer's arrival and visibility confirmed")
        end
        function w:expiry(order)
            local deadline = self.a.queue.ticket.deadline
            self:advance(deadline - (self.epochBase + math.floor(self.now)) - 1, order)
            self.now = self.now + 1
            self:tick(order)
        end
        function w:noRatings()
            for _, c in ipairs(self.clients) do eq(c.ratingCalls, 0, "queue never calculates ratings") end
        end
        return w
    end

    scenario = "full match and duel handoff"
    local w = world()
    w:ready()
    local ta, tb = w.a.queue.ticket, w.b.queue.ticket
    eq(ta.id, tb.id, "both clients hold same ticket")
    eq(ta.venue.id, tb.venue.id, "same approved meeting place")
    eq(ta.travelDeadline, tb.travelDeadline, "same travel deadline")
    eq(ta.duration, 300, "five-minute minimum estimate")
    eq(w.a.invited, 1, "one designated coordinator invitation")
    eq(w.b.invited, 0, "peer never invites coordinator")
    eq(w.a.queue:GetStatus().ownArrived, true, "status exposes local arrival")
    eq(w.a.queue:GetStatus().peerArrived, true, "status exposes peer arrival")
    eq(w.a.queue:Waypoint(), true, "meeting place waypoint")
    eq(w.a.waypointVenue, ta.venue.id, "waypoint uses confirmed venue")
    eq(w.a.queue:Challenge(), true, "normal native duel challenge available")
    eq(w.a.challenged, 1, "queue requests native challenge once")
    local ma = { opponent = w.a.fd.Copy(w.b.profile) }
    local mb = { opponent = w.b.fd.Copy(w.a.profile) }
    w.a.queue:OnDuel("request", ma)
    w.b.queue:OnDuel("request", mb)
    eq(w.a.queue.state, "DUEL", "existing duel lifecycle takes over")
    eq(w.b.queue.state, "DUEL", "peer lifecycle takes over")
    eq(w.a.queue.ticket.deadline, nil, "queue does not time out running duel")
    w:advance(200)
    eq(w.a.queue.state, "DUEL", "long native duel remains under duel lifecycle")
    w.a.queue:OnDuel("finished", ma)
    w:flush()
    eq(w.a.queue.state, "CLEANUP", "first finished player waits for peer's result barrier")
    eq(w.a.left, 0, "first finished player retains native party identity")
    eq(w.a.env.party(w.b.profile), true, "party remains intact until peer terminal event")
    eq(w.b.queue.state, "DUEL", "peer finish notification never aborts pending local duel flow")
    w.b.queue:OnDuel("finished", mb)
    w:tick()
    eq(w.a.queue.state, "IDLE", "finished match requires explicit rejoin")
    eq(w.b.queue.state, "IDLE", "peer also requires explicit rejoin")
    w:noRatings()

    scenario = "missing peer terminal is bounded"
    w = world()
    w:ready()
    ma = { opponent = w.a.fd.Copy(w.b.profile) }
    mb = { opponent = w.b.fd.Copy(w.a.profile) }
    w.a.queue:OnDuel("request", ma)
    w.b.queue:OnDuel("request", mb)
    local lateTerminal = w.b.queue:Control("CANCEL", { reason = "FINISHED" })
    w.a.queue:OnDuel("finished", ma)
    w:flush()
    eq(w.a.queue.state, "CLEANUP", "cleanup waits for missing terminal notification")
    eq(w.b.queue.state, "DUEL", "peer retains independent local duel lifecycle")
    w:inject(w.a, lateTerminal, "Stranger-Forever")
    eq(w.a.queue.state, "CLEANUP", "foreign terminal sender cannot release pending group")
    local badTerminal = w.a.fd.Copy(lateTerminal); badTerminal.ticket = "dead-beef"
    w:inject(w.a, badTerminal, w.b.profile.fullName)
    eq(w.a.queue.state, "CLEANUP", "unbound terminal ticket cannot release pending group")
    w:advance(14)
    eq(w.a.queue.state, "CLEANUP", "result identity preserved for first fourteen seconds")
    eq(w.a.left, 0, "group cleanup waits within result grace period")
    eq(w.b.queue.state, "DUEL", "waiting peer is never force-aborted")
    w:advance(1)
    eq(w.a.queue.state, "IDLE", "missing terminal cannot hold cleanup beyond fifteen seconds")
    eq(w.a.left, 1, "expired result grace closes only queue-owned native group")
    eq(w.b.queue.state, "DUEL", "group cleanup does not manufacture local peer finish event")
    w:inject(w.a, lateTerminal, w.b.profile.fullName)
    eq(w.a.queue.state, "IDLE", "late terminal packet cannot resurrect cleared match")
    w.b.queue:OnDuel("finished", mb)
    w:flush(); w:tick()
    eq(w.b.queue.state, "IDLE", "late local terminal event ends peer participation normally")
    eq(w.a.settings.cooldownUntil, 0, "result-barrier cleanup has no absence penalty")
    eq(w.b.settings.cooldownUntil, 0, "late peer completion has no absence penalty")
    w:noRatings()

    scenario = "settings and queue admission"
    w = world()
    eq(w.a.queue:Configure({ levelGap = 0 }), true, "equal-level preference configurable")
    eq(w.a.settings.levelGap, 0, "preference saved")
    eq(w.a.queue:Configure({ levelGap = 6 }), false, "invalid gap rejected")
    w.a.settings.continentVerified, w.a.settings.rulesetVerified = false, false
    eq(w.a.queue:Configure({ scope = "CONTINENT" }), true, "continent discovery selectable without manual gate")
    eq(w.a.queue:Configure({ scope = "RULESET" }), true, "ruleset discovery selectable without manual gate")
    eq(w.a.queue:Configure({ ruleset = "PVP" }), false, "native ruleset cannot be manually overridden")
    eq(w.a.queue:Configure({ hidden = true }), false, "unsupported setting excluded")
    w.a.settings.ruleset = nil
    eq(w.a.queue:Join(), false, "unavailable automatic ruleset waits for native character data")
    w.a.settings.ruleset, w.a.dead = "PVP", true
    eq(w.a.queue:Join(), false, "dead player excluded")
    w.a.dead, w.a.instanced = false, true
    eq(w.a.queue:Join(), false, "instanced player excluded")
    w.a.instanced = false
    w.a.catalog = {}
    eq(w.a.queue:Join(), true, "empty location catalog cannot block opponent discovery")
    eq(w.a.queue.state, "SEARCHING", "missing venue leaves discovery active")
    eq(w.a.queue.session ~= nil, true, "search has a live session without a meeting place")
    eq(w.b.queue:Join(), true, "other player also joins")
    w:advance(4)
    eq(w.a.queue:GetStatus().discovered, 1, "opponent is discovered independently of meeting place availability")
    eq(w.a.queue.state, "SEARCHING", "missing venue cannot reserve unsuitable match")
    eq(w.a.queue.reason:find("Suitable opponent found", 1, true) ~= nil, true, "missing meeting place is explained separately")
    w.a.catalog = w.b.catalog
    w:advance(1)
    eq(w.a.queue.state, "GROUPING", "available meeting place resumes matching without rejoining")

    scenario = "joined profiles stay fresh while waiting for a meeting place"
    w = world()
    local approved = w.a.catalog
    w.a.catalog, w.b.catalog = {}, {}
    w:join()
    w:advance(4)
    -- A native directory entry may expire while its explicit queue session is
    -- still reachable. Refreshing received sessions must not depend on it.
    w.a.env.candidates, w.b.env.candidates = function() return {} end, function() return {} end
    for _ = 1, 40 do
        w:advance(5)
        for _, c in ipairs({ w.a, w.b }) do
            local status = c.queue:GetStatus()
            eq(status.discovered, 1, "joined opponent remains discovered during long search")
            eq(status.freshProfiles, 1, "joined opponent never ages out of matching freshness")
            eq(status.searchReason, "NO_VENUE", "missing tested venue remains a stable search explanation")
            eq(c.queue.state, "SEARCHING", "refresh cannot manufacture a meeting place")
        end
    end
    local lastQuery = {}
    for _, message in ipairs(w.sent) do
        if message.kind == "QUERY" then lastQuery[message.from] = (lastQuery[message.from] or 0) + 1 end
    end
    eq(lastQuery[w.a.profile.fullName] > 30, true, "coordinator refreshes actual joined sessions faster than old thirty-second discovery")
    w.a.catalog, w.b.catalog = approved, approved
    w:advance(3)
    eq(w.a.queue.state, "GROUPING", "fresh lower GUID coordinator matches immediately when a tested place becomes available")
    eq(w.b.queue.state, "GROUPING", "peer confirms the same fresh pairing")
    w:noRatings()

    scenario = "joined profile refresh has priority over a large passive directory"
    w = world({ count = 3 })
    w.a.catalog, w.b.catalog = {}, {}
    eq(w.a.queue:Join(), true, "coordinator joins")
    eq(w.b.queue:Join(), true, "one real opponent joins")
    w:advance(4)
    local directory = { { guid = w.b.profile.guid, fullName = w.b.profile.fullName } }
    for index = 1, 100 do
        directory[#directory + 1] = { guid = string.format("Player-2-%X", index), fullName = "Passive" .. index .. "-Forever" }
    end
    w.a.env.candidates = function() return directory end
    for _ = 1, 12 do
        w:advance(5)
        eq(w.a.queue:GetStatus().freshProfiles, 1, "passive directory scan cannot starve active queue session refresh")
    end
    eq(w.c.queue.state, "IDLE", "passive real client remains unqueued")
    eq(w.a.queue:GetStatus().discovered, 1, "only explicit opponent PROFILE is counted")
    w:noRatings()

    scenario = "presence alone never joins a passive player"
    w = world()
    eq(w.a.queue:Join(), true, "one player explicitly joins")
    w:advance(181)
    eq(w.b.queue.state, "IDLE", "discovery cannot automatically join nearby addon player")
    eq(w.a.queue:GetStatus().discovered, 0, "nonjoined addon player is not a queue profile")
    eq(w.a.queue:GetStatus().searchReason, "SEARCHING", "empty opponent queue has an explicit discovery reason")
    local queries = 0
    for _, message in ipairs(w.sent) do if message.kind == "QUERY" then queries = queries + 1 end end
    eq(queries <= 7, true, "passive discovery retains thirty-second cadence")
    w:noRatings()

    scenario = "live two hundred four rating gap then missing tested venue"
    w = world({ players = { [1] = { rating = 1398 }, [2] = { rating = 1602 } } })
    w.a.catalog, w.b.catalog = {}, {}
    eq(w.a.queue:Join(), true, "first actual rating joins")
    w:advance(10)
    eq(w.b.queue:Join(), true, "second actual rating joins later")
    w:advance(203)
    local status = w.a.queue:GetStatus()
    eq(status.searchReason, "RATING", "204 difference is excluded at screenshot's two-hundred window")
    eq(status.searchDetails.ratingDifference, 204, "diagnostics expose actual rating difference")
    eq(status.searchDetails.ownRatingWindow, 200, "first player's three-minute window")
    eq(status.searchDetails.peerRatingWindow, 200, "second player's three-minute window")
    eq(status.reason:find("Both windows must fit", 1, true) ~= nil, true, "reason states bilateral rating requirement")
    w:advance(87)
    status = w.a.queue:GetStatus()
    eq(status.searchReason, "RATING", "first player's five-minute expansion cannot override later join")
    eq(status.searchDetails.ownRatingWindow, 400, "older player's rating window expands")
    eq(status.searchDetails.peerRatingWindow, 200, "newer player's rating window still excludes 204")
    w:advance(10)
    status = w.a.queue:GetStatus()
    eq(status.searchReason, "NO_VENUE", "after both five-minute expansions the next real blocker is shown")
    eq(status.reason:find("no tested duel places saved", 1, true) ~= nil, true, "empty local catalog explained without guessed places")
    eq(w.a.queue.state, "SEARCHING", "empty catalog cannot create a pairing")
    eq(w.a.queue.ticket, nil, "no reservation occurs without a tested suitable place")
    w:noRatings()

    scenario = "specific search eligibility explanations"
    local cases = {
        { "LEVEL_CAP", function(peer) peer.maxLevel = 70 end },
        { "BRACKET", function(peer) peer.level = 60 end },
        { "LEVEL", function(peer) peer.level, peer.levelGap = 31, 0 end },
        { "RULESET", function(peer) peer.ruleset = "NORMAL" end },
        { "FACTION", function(peer) peer.faction = "Alliance" end },
        { "RATING", function(peer) peer.rating = 1700 end },
        { "POSITION", function(peer) peer.mapID, peer.continentID, peer.x, peer.y = 0, 0, 0, 0 end },
        { "SCOPE", function(peer) peer.mapID = 2 end },
        { "BLOCKED", function(peer, queue) queue.blocked[peer.guid] = w.epochBase + 120 end },
    }
    for _, case in ipairs(cases) do
        w = world()
        w:join()
        w.b.queue:Announce(w.a.profile.fullName); w:flush()
        case[2](w.a.queue.peers[w.b.profile.guid], w.a.queue)
        eq(w.a.queue:SelectPeer(), nil, case[1] .. " cannot pair")
        status = w.a.queue:GetStatus()
        eq(status.searchReason, case[1], case[1] .. " has a distinct status code")
        eq(status.reason ~= "Searching for a suitable opponent.", true, case[1] .. " has a visible explanation")
    end
    w = world()
    w:join(); w.b.queue:Announce(w.a.profile.fullName); w:flush()
    w.now = 11
    eq(w.a.queue:SelectPeer(), nil, "stale session cannot reserve")
    eq(w.a.queue:GetStatus().searchReason, "STALE", "stale retained profile is explained")
    eq(w.a.queue:GetStatus().discovered, 1, "retention still reports known explicit queue session")
    eq(w.a.queue:GetStatus().freshProfiles, 0, "fresh count separates stale discovery data")
    w.now = 120
    eq(w.a.queue:SelectPeer(), nil, "expired session cannot reserve")
    eq(w.a.queue:GetStatus().searchReason, "SEARCHING", "expired profile is purged from diagnosis")
    eq(w.a.queue:GetStatus().discovered, 0, "expired profiles no longer appear found")

    scenario = "bilateral rating and level preferences"
    w = world({ players = { [2] = { rating = 1650 } } })
    w:join()
    w:advance(119)
    eq(w.a.queue.state, "SEARCHING", "150 rating difference waits for expansion")
    eq(w.a.queue:Window(w.a.queue.queuedAt), 100, "first window is one hundred")
    w:advance(4)
    eq(w.a.queue:Window(w.a.queue.queuedAt), 200, "two-minute window is two hundred")
    eq(w.a.queue.state, "GROUPING", "both expanded windows permit pairing")
    w = world({ players = { [2] = { rating = 1800 } } })
    w:join()
    w:advance(299)
    eq(w.a.queue.state, "SEARCHING", "300 rating difference waits five minutes")
    w:advance(4)
    eq(w.a.queue:Window(w.a.queue.queuedAt), 400, "five-minute window is four hundred")
    eq(w.a.queue.state, "GROUPING", "five-minute bilateral expansion pairs")
    w = world({ players = { [2] = { rating = 1901 } } })
    w:join()
    w:advance(301)
    eq(w.a.queue.state, "SEARCHING", "rating gap greater than four hundred never expands further")
    w = world({ players = { [2] = { rating = 1750 } } })
    eq(w.a.queue:Join(), true, "first player joins early")
    w:advance(301)
    eq(w.b.queue:Join(), true, "second player joins late")
    w:advance(5)
    eq(w.a.queue.state, "SEARCHING", "older wide window cannot override new peer's narrow window")
    local peer = w.a.fd.Copy(w.b.queue.ownProfile)
    peer.joinedAt = w.a.queue.queuedAt
    eq(w.a.queue:Eligible(peer), true, "both older windows admit rating gap")
    peer.level, peer.levelGap = 31, 0
    eq(w.a.queue:Eligible(peer), false, "peer's stricter level preference enforced")
    peer.level, peer.levelGap = 36, 5
    eq(w.a.queue:Eligible(peer), false, "native rated maximum level difference enforced")
    peer.level, peer.levelGap, peer.maxLevel = 30, 5, 70
    eq(w.a.queue:Eligible(peer), false, "different level caps excluded")
    peer.level, peer.maxLevel = 60, 60
    eq(w.a.queue:Eligible(peer), false, "leveling and max level never mix")
    peer.level, peer.ruleset = 30, "NORMAL"
    eq(w.a.queue:Eligible(peer), false, "different rulesets excluded")
    peer.ruleset, peer.faction = "PVP", "Alliance"
    eq(w.a.queue:Eligible(peer), false, "cross-faction queue match excluded")
    w:noRatings()

    scenario = "preference ordering"
    w = world({ count = 3, players = { [2] = { rating = 1570 }, [3] = { rating = 1530 } } })
    w:join()
    for _, c in ipairs({ w.b, w.c }) do c.queue:Announce(w.a.profile.fullName) end
    w:flush()
    eq(w.a.queue:SelectPeer().guid, w.c.profile.guid, "nearest rating has first priority")
    w.a.queue.peers[w.c.profile.guid].rating = 1570
    w.a.queue.peers[w.c.profile.guid].joinedAt = w.a.queue.queuedAt - 1
    eq(w.a.queue:SelectPeer().guid, w.c.profile.guid, "longer wait breaks equal rating distance")
    w.a.queue.peers[w.c.profile.guid].joinedAt = w.a.queue.queuedAt
    eq(w.a.queue:SelectPeer().guid, w.b.profile.guid, "GUID breaks fully equal candidates")
    w.now = 11
    eq(w.a.queue:SelectPeer(), nil, "stale profile cannot be reserved")

    scenario = "discovery freshness and native sender binding"
    w = world({ count = 3 })
    w:join()
    local p = w.b.fd.Copy(w.b.queue.ownProfile); p.kind = "PROFILE"
    p.joinedAt = w.epochBase + 3
    w:inject(w.a, p, w.b.profile.fullName)
    eq(w.a.queue.peers[p.guid], nil, "future queue epoch rejected")
    p.joinedAt = w.epochBase - 86401
    w:inject(w.a, p, w.b.profile.fullName)
    eq(w.a.queue.peers[p.guid], nil, "old queue epoch rejected")
    p.joinedAt = w.epochBase
    w:inject(w.a, p, w.b.profile.fullName)
    eq(w.a.queue.peers[p.guid].fullName, w.b.profile.fullName, "native transport sender owns discovered identity")
    w:inject(w.a, p, w.c.profile.fullName)
    eq(w.a.queue.peers[p.guid].fullName, w.b.profile.fullName, "different sender cannot overwrite bound GUID")
    local fake = w.c.fd.Copy(w.c.queue.ownProfile); fake.kind = "PROFILE"
    w:inject(w.a, fake, w.b.profile.fullName)
    eq(w.a.queue.peers[fake.guid], nil, "one native sender cannot claim two GUIDs")
    w:inject(w.a, { kind = "LEAVE", guid = p.guid, session = "dead-beef" }, w.b.profile.fullName)
    eq(w.a.queue.peers[p.guid] ~= nil, true, "old-session leave cannot delete current profile")
    w:inject(w.a, { kind = "LEAVE", guid = p.guid, session = p.session }, w.c.profile.fullName)
    eq(w.a.queue.peers[p.guid] ~= nil, true, "wrong sender cannot delete current profile")
    w:inject(w.a, { kind = "LEAVE", guid = p.guid, session = p.session }, w.b.profile.fullName)
    eq(w.a.queue.peers[p.guid], nil, "bound current session can leave")

    for _, lost in ipairs({ "ACK", "COMMIT", "CONFIRM", "PLAN", "PLAN_ACK", "GO", "GO_ACK" }) do
        scenario = "retry dropped " .. lost
        w = world()
        local dropped = false
        w.drop = function(packet)
            if packet.kind == lost and not dropped then dropped = true; return true end
            return false
        end
        w:join()
        w:advance(10)
        eq(w.a.queue.state, "GROUPING", "reservation eventually completes")
        eq(w.b.queue.state, "GROUPING", "peer reservation eventually completes")
        w:group()
        w:advance(10)
        eq(w.a.queue.state, "TRAVELLING", "travel eventually starts")
        eq(w.b.queue.state, "TRAVELLING", "peer travel eventually starts")
        eq(w.dropped[lost], 1, "requested packet dropped exactly once")
        eq(w.a.invited, 1, "retries do not duplicate native invitations")
        eq(w.b.invited, 0, "peer never becomes inviter")
        w:noRatings()
    end

    scenario = "travel timer starts after plan acknowledgment"
    w = world()
    w:pair()
    local releaseAt = w.now + 10
    w.drop = function(packet) return packet.kind == "PLAN_ACK" and w.now < releaseAt end
    w:group()
    w:advance(15)
    eq(w.a.queue.state, "TRAVELLING", "delayed plan acknowledgment eventually starts travel")
    eq(w.b.queue.state, "TRAVELLING", "peer receives final GO")
    local finalDeadline = w.a.queue.ticket.travelDeadline
    eq(finalDeadline, w.epochBase + math.floor(w.a.travelAt) + w.a.queue.ticket.duration,
        "confirmation gives full computed travel allowance")
    eq(w.b.queue.ticket.travelDeadline, finalDeadline, "peer freezes same final GO deadline")
    eq(w.dropped.PLAN_ACK > 1, true, "plan acknowledgment was delayed through multiple retries")
    local duplicateGO = w.a.queue:Control("GO", w.a.queue:PlanFields())
    w:advance(3)
    w.b.queue:Send("PLAN_ACK")
    w:flush()
    eq(w.a.queue.ticket.travelDeadline, finalDeadline, "late duplicate acknowledgment cannot extend allowance")
    w:inject(w.b, duplicateGO, w.a.profile.fullName)
    eq(w.b.queue.ticket.travelDeadline, finalDeadline, "duplicate final GO cannot extend allowance")
    w:noRatings()

    scenario = "shared ready deadline despite delayed delivery"
    w = world()
    w:travel()
    local releaseAt = w.now + 12
    w.drop = function(packet, sender)
        return packet.kind == "READY" and packet.deadline > 0 and sender == w.a and w.now < releaseAt
    end
    w:move(w.a); w:move(w.b)
    w:advance(16)
    eq(w.a.queue.state, "READY", "coordinator becomes ready after mutual proof")
    eq(w.b.queue.state, "READY", "peer receives delayed shared start deadline")
    eq(w.a.readyAt < w.b.readyAt, true, "test actually delays ready assignment delivery")
    local readyDeadline = w.a.queue.ticket.deadline
    eq(readyDeadline, w.epochBase + math.floor(w.a.readyAt) + 120, "coordinator assigns one two-minute window")
    eq(w.b.queue.ticket.deadline, readyDeadline, "network delay never creates a second local window")
    local duplicateREADY = w.a.queue:Control("READY", { deadline = readyDeadline })
    w:advance(5)
    w:inject(w.b, duplicateREADY, w.a.profile.fullName)
    eq(w.b.queue.ticket.deadline, readyDeadline, "duplicate ready assignment never extends deadline")
    eq(w.a.queue.ticket.deadline, readyDeadline, "ready proposal retries never extend coordinator deadline")
    duplicateREADY.deadline = readyDeadline + 30
    w:inject(w.b, duplicateREADY, w.a.profile.fullName)
    eq(w.b.queue.ticket.deadline, readyDeadline, "changed late ready assignment is ignored")
    w:noRatings()

    scenario = "simultaneous three-client reservations"
    w = world({ count = 3 })
    w:join()
    for _, c in ipairs(w.clients) do
        for _, other in ipairs(w.clients) do if other ~= c then c.queue:Announce(other.profile.fullName) end end
    end
    w:flush()
    w:tick(nil, true)
    w:advance(3)
    eq(w.a.queue.ticket.peer.guid, w.b.profile.guid, "canonical lower-GUID pairing wins")
    eq(w.b.queue.ticket.peer.guid, w.a.profile.guid, "conflicting outgoing reservation released")
    eq(w.a.queue.ticket.id, w.b.queue.ticket.id, "only one ticket covers the shared player")
    eq(w.a.invited + w.b.invited + w.c.invited, 1, "concurrent offers produce one invitation")
    eq(w.c.queue.ticket, nil, "third client does not retain obsolete pairing")
    w:noRatings()

    scenario = "invalid control identity"
    w = world()
    w:travel()
    local good = w.b.queue:Control("CANCEL", { reason = "CANCELLED" })
    w:inject(w.a, good, "Stranger-Forever")
    eq(w.a.queue.state, "TRAVELLING", "foreign sender cannot cancel ticket")
    local stale = w.a.fd.Copy(good); stale.session = "dead-beef"
    w:inject(w.a, stale, w.b.profile.fullName)
    eq(w.a.queue.state, "TRAVELLING", "old peer session ignored")
    stale = w.a.fd.Copy(good); stale.peerSession = "dead-beef"
    w:inject(w.a, stale, w.b.profile.fullName)
    eq(w.a.queue.state, "TRAVELLING", "old local session ignored")
    stale = w.a.fd.Copy(good); stale.ticket = "dead-beef"
    w:inject(w.a, stale, w.b.profile.fullName)
    eq(w.a.queue.state, "TRAVELLING", "wrong ticket ignored")
    w:noRatings()

    scenario = "bounded reservation retries"
    w = world()
    w.drop = function(packet) return packet.kind == "ACK" end
    w:join()
    w:advance(25)
    eq(w.a.queue.state, "IDLE", "unconfirmed reservation expires within twenty seconds")
    eq(w.b.queue.state, "IDLE", "peer does not retain timed-out reservation")
    eq(w.a.invited, 0, "unconfirmed pairing never invites")
    eq(w.b.invited, 0, "unconfirmed peer never invites")
    eq(w.dropped.ACK < 20, true, "reservation retries are bounded")
    eq(w.a.settings.cooldownUntil, 0, "negotiation loss carries no absence pause")
    eq(w.b.settings.cooldownUntil, 0, "peer negotiation loss carries no absence pause")
    w:noRatings()

    for _, lateKind in ipairs({ "ACK", "COMMIT", "CONFIRM" }) do
        scenario = "reservation expiry before timer tick " .. lateKind
        w = world()
        w:join()
        w.a.queue:Announce(w.b.profile.fullName)
        w.b.queue:Announce(w.a.profile.fullName)
        w:flush()
        local recipient, sender = lateKind == "COMMIT" and w.b or w.a, lateKind == "COMMIT" and w.a or w.b
        local peer = recipient.queue.peers[sender.profile.guid]
        local ticketID = w.a.queue.session .. "." .. w.b.queue.session
        recipient.queue:Reserve(peer, ticketID, recipient == w.a)
        if lateKind == "CONFIRM" then recipient.queue.ticket.acknowledged = true end
        local packet = { kind = lateKind, session = sender.queue.session,
            peerSession = recipient.queue.session, ticket = ticketID }
        w.now = recipient.queue.ticket.createdAt + 20
        w:inject(recipient, packet, sender.profile.fullName)
        eq(recipient.queue.state, "IDLE", "late bound packet expires reservation before any timer tick")
        eq(recipient.queue.ticket, nil, "expired ticket cannot acquire a new grouping clock")
        eq(w.a.invited + w.b.invited, 0, "no native invitation from expired acknowledgment")
        eq(recipient.settings.cooldownUntil, 0, "reservation expiry is not a no-show")
        w:noRatings()
    end

    scenario = "locally mismatched venue coordinates"
    w = world()
    w:pair()
    w.b.catalog[1].x = 1
    w:group()
    w:advance(5)
    eq(w.a.queue.state, "IDLE", "different local venue coordinates reject travel agreement")
    eq(w.b.queue.state, "IDLE", "peer rejects same ID resolving to a different location")
    eq(w.a.settings.cooldownUntil, 0, "catalog disagreement is technical")
    eq(w.b.settings.cooldownUntil, 0, "peer catalog disagreement has no pause")
    w:noRatings()

    scenario = "arrival samples and native proximity"
    w = world()
    w:travel()
    w:move(w.a, 0)
    w:advance(2)
    eq(w.a.queue.ticket.ownArrived, false, "two arrival checks are insufficient")
    w:move(w.a, 41)
    w:advance(1)
    eq(w.a.queue.ticket.samples, 0, "stepping outside forty yards resets samples")
    w:move(w.a, 0); w:move(w.b, 20)
    w:advance(6)
    eq(w.a.queue.ticket.ownArrived, true, "three consecutive checks confirm arrival")
    eq(w.b.queue.ticket.ownArrived, true, "peer is also within venue radius")
    eq(w.a.queue.state, "TRAVELLING", "venue radius alone does not establish ten-yard proximity")
    w:move(w.b, 5)
    w:advance(4)
    eq(w.a.queue.state, "READY", "native proximity completes ready handshake")
    eq(w.b.queue.state, "READY", "peer confirms native proximity")
    w:move(w.b, 20)
    w:advance(1)
    eq(w.a.queue.state, "IDLE", "moving apart invalidates ready state")
    eq(w.b.queue.state, "IDLE", "peer's ready state also invalidated")
    eq(w.a.settings.cooldownUntil, 0, "loss of ready proximity is technical")
    w:noRatings()

    scenario = "start window timeout"
    w = world()
    w:ready()
    local startDeadline = w.a.queue.ticket.deadline
    eq(startDeadline, w.epochBase + math.floor(w.a.readyAt) + 120, "ready receives a full two-minute start window")
    w:advance(startDeadline - (w.epochBase + math.floor(w.now)))
    eq(w.a.queue.state, "IDLE", "two-minute start window ends queue match")
    eq(w.b.queue.state, "IDLE", "peer's start window also ends")
    eq(w.a.settings.cooldownUntil, 0, "no-start timeout is not absence")
    eq(w.b.settings.cooldownUntil, 0, "peer no-start timeout is not absence")
    w:noRatings()

    scenario = "late native request cannot enter queue duel"
    w = world()
    w:ready()
    w.now = w.a.queue.ticket.deadline - w.epochBase
    w.a.queue:OnDuel("request", { opponent = w.a.fd.Copy(w.b.profile) })
    w:flush(); w:tick()
    eq(w.a.queue.state, "IDLE", "request at expired start deadline rejected")
    eq(w.b.queue.state, "IDLE", "late request releases peer")
    w:noRatings()

    scenario = "blocked native invitation and group timeout"
    w = world(); w.a.blockInvite = true
    w:pair()
    eq(w.a.queue:GetStatus().inviteFallback, true, "blocked automatic invitation offers manual action")
    w.a.blockInvite = false
    eq(w.a.queue:Invite(), true, "manual invite retries native API")
    eq(w.b.queue:Invite(), false, "only designated coordinator may invite")
    w:advance(61)
    eq(w.a.queue.state, "IDLE", "group timeout releases coordinator")
    eq(w.b.queue.state, "IDLE", "group timeout releases peer")
    eq(w.a.settings.cooldownUntil, 0, "group failure has no absence penalty")
    eq(w.b.settings.cooldownUntil, 0, "peer group failure has no absence penalty")
    w:noRatings()

    scenario = "asymmetric native roster readiness"
    w = world({ nativeGroupStates = true })
    w:pair(); w:group()
    w.b.groupPending = true
    local groupingAtA, groupingAtB = w.a.queue.ticket.groupAt, w.b.queue.ticket.groupAt
    w:advance(4)
    eq(w.a.queue.state, "GROUPING", "readable client waits for bilateral native group proof")
    eq(w.b.queue.state, "GROUPING", "temporarily unreadable party identity does not cancel")
    eq(w.a.queue.ticket.ownedParty, true, "only readable exact membership proves group ownership")
    eq(w.b.queue.ticket.ownedParty, nil, "pending membership cannot establish ownership")
    eq(w.a.queue.ticket.venue, nil, "coordinator cannot plan before peer proves grouping")
    eq(w.b.queue.ticket.venue, nil, "pending client receives no assigned place")
    eq(w.a.left + w.b.left, 0, "native roster transition never leaves either group")
    eq(w.a.invited + w.b.invited, 1, "roster retries never repeat the native invitation")
    for _, message in ipairs(w.sent) do
        eq(message.kind ~= "PLAN", true, "unproven bilateral group emits no meeting-place plan")
    end
    w.b.groupPending = false
    w:advance(5); w:move(w.a); w:move(w.b); w:advance(6)
    eq(w.a.queue.state, "READY", "coordinator reaches ready after delayed proof recovers")
    eq(w.b.queue.state, "READY", "recovering native roster reaches the same ready state")
    eq(w.a.queue.ticket.groupAt, groupingAtA, "recovery never restarts coordinator grouping deadline")
    eq(w.b.queue.ticket.groupAt, groupingAtB, "recovery never restarts peer grouping deadline")
    eq(w.a.settings.cooldownUntil + w.b.settings.cooldownUntil, 0, "roster readiness has no absence penalty")
    w:noRatings()

    scenario = "cancellation before first native group tick"
    w = world({ nativeGroupStates = true })
    w:pair(); w:group()
    w.b.group = w.b.fd.Copy(w.b.group)
    eq(w.a.queue.ticket.ownedParty, nil, "no queue tick has recognized the accepted group")
    w.a.queue:Cancel("TECHNICAL", false)
    w:flush()
    eq(w.a.queue.state, "IDLE", "exact group proof at cancellation permits safe cleanup")
    eq(w.b.queue.state, "IDLE", "peer cancellation also adopts its exact queue group")
    eq(w.a.left, 1, "coordinator leaves only its proven two-person queue group")
    eq(w.b.left, 1, "peer safely cleans up before its first grouped tick")
    w:noRatings()

    scenario = "late exact proof during cancelled group cleanup"
    w = world({ nativeGroupStates = true })
    w:pair(); w:group()
    w.b.group = w.b.fd.Copy(w.b.group)
    w.a.groupPending, w.b.groupPending = true, true
    w.a.queue:Cancel("TECHNICAL", false); w:flush()
    eq(w.a.queue.state, "CLEANUP", "cancelled coordinator waits for native group proof")
    eq(w.b.queue.state, "CLEANUP", "cancelled peer waits for native group proof")
    eq(w.a.queue.reason:find("readable", 1, true) ~= nil, true, "unknown membership has a verification explanation")
    eq(w.a.queue.ticket.ownedParty, nil, "cancellation alone cannot grant group ownership")
    eq(w.b.queue.ticket.ownedParty, nil, "received cancellation cannot grant peer ownership")
    eq(w.a.left + w.b.left, 0, "unverified cancelled groups are never left automatically")
    w.a.groupPending, w.b.groupPending = false, false
    w:tick()
    eq(w.a.queue.state, "IDLE", "late coordinator native proof releases cleanup")
    eq(w.b.queue.state, "IDLE", "late peer native proof releases cleanup")
    eq(w.a.left, 1, "late proof permits exactly one coordinator leave")
    eq(w.b.left, 1, "late proof permits exactly one peer leave")
    eq(w.a.settings.cooldownUntil + w.b.settings.cooldownUntil, 0, "technical cleanup has no no-show cooldown")
    w:noRatings()

    scenario = "persistent unreadable roster retains original group deadline"
    w = world({ nativeGroupStates = true })
    w:pair(); w:group()
    w.a.groupPending, w.b.groupPending = true, true
    w.a.fd.Database.data, w.b.fd.Database.data = { matches = {} }, { matches = {} }
    local groupingDeadline = w.a.queue.ticket.groupAt + 60
    w:advance(groupingDeadline - w.now - 1)
    eq(w.a.queue.state, "GROUPING", "pending proof waits until the existing group deadline")
    eq(w.b.queue.state, "GROUPING", "peer heartbeat preserves the same pending deadline")
    w:advance(1)
    eq(w.a.queue.state, "CLEANUP", "persistent pending proof cancels at original sixty seconds")
    eq(w.b.queue.state, "CLEANUP", "peer cancellation also waits for safe cleanup proof")
    eq(w.a.left + w.b.left, 0, "persistent unknown membership never authorizes leaving")
    eq(w.a.invited + w.b.invited, 1, "persistent pending proof cannot send another invitation")
    eq(w.a.settings.cooldownUntil + w.b.settings.cooldownUntil, 0, "unknown group state never penalizes absence")
    eq(w.a.profile.rating + w.b.profile.rating, 3000, "group timeout preserves both ratings")
    eq(#w.a.fd.Database.data.matches + #w.b.fd.Database.data.matches, 0, "group timeout adds no history")
    local recordedTimeout = false
    for _, entry in ipairs(w.a.logs) do
        if entry.topic == "queue state" and entry.detail == "CLEANUP GROUP_TIMEOUT GROUPING" then recordedTimeout = true end
    end
    eq(recordedTimeout, true, "bounded state diagnostics retain actual cancellation reason")
    w.a.group, w.b.group = nil, nil
    w.a.groupPending, w.b.groupPending = false, false
    w:tick()
    eq(w.a.queue.state, "IDLE", "confirmed solo state safely ends pending cleanup")
    eq(w.b.queue.state, "IDLE", "peer confirmed solo state safely ends cleanup")
    w:noRatings()

    scenario = "pending planning proof retains confirmation deadline"
    w = world({ nativeGroupStates = true })
    w.drop = function(p) return p.kind == "PLAN_ACK" end
    w:pair(); w:group(); w:advance(5)
    eq(w.a.queue.state, "PLANNING", "coordinator has an actual plan before transient loss")
    local planningDeadline = w.a.queue.ticket.planAt + 20
    w.a.groupPending = true
    local planCount = 0
    for _, m in ipairs(w.sent) do if m.kind == "PLAN" and m.sender == w.a then planCount = planCount + 1 end end
    w:advance(planningDeadline - w.now - 1)
    eq(w.a.queue.state, "PLANNING", "pending proof does not cancel a plan prematurely")
    local afterCount = 0
    for _, m in ipairs(w.sent) do if m.kind == "PLAN" and m.sender == w.a then afterCount = afterCount + 1 end end
    eq(afterCount, planCount, "unproven current group cannot retransmit a plan")
    w:advance(1)
    eq(w.a.queue.state, "CLEANUP", "pending proof never widens the existing planning deadline")
    eq(w.a.left, 0, "planning timeout never leaves currently unverified membership")
    eq(w.a.settings.cooldownUntil, 0, "planning proof timeout is technical rather than no-show")
    w:noRatings()

    scenario = "unconfirmed reservation cannot adopt a native group"
    w = world({ nativeGroupStates = true })
    w.drop = function(p) return p.kind == "ACK" end
    w:join(); w:advance(4); w:group()
    eq(w.a.queue.state, "RESERVING", "bilateral reservation is deliberately unconfirmed")
    eq(w.a.queue.ticket.groupAt, nil, "no grouping authorization was established")
    w.a.queue:Cancel("TECHNICAL", false); w:flush()
    eq(w.a.queue.state, "CLEANUP", "exact membership cannot adopt a group formed during reservation")
    eq(w.a.queue.ticket.ownedParty, nil, "unconfirmed reservation never owns the native group")
    eq(w.a.left + w.b.left, 0, "unconfirmed clients preserve their externally formed group")
    w:noRatings()

    scenario = "positive native group changes cancel immediately"
    for _, change in ipairs({ "third member", "raid", "foreign member" }) do
        w = world({ nativeGroupStates = true })
        w:pair(); w:group()
        if change == "third member" then w.a.group["Player-1-CCC"] = true
        elseif change == "raid" then w.a.raid, w.b.raid = true, true
        else
            w.a.group = { [w.a.profile.guid] = true, ["Player-1-CCC"] = true }
            w.b.group = { [w.b.profile.guid] = true, ["Player-1-DDD"] = true }
        end
        w:advance(1)
        eq(w.a.queue.state, "CLEANUP", change .. " is cancelled without waiting sixty seconds")
        eq(w.b.queue.state, "CLEANUP", change .. " releases the peer match immediately")
        eq(w.a.left + w.b.left, 0, change .. " group is never left by queue cleanup")
        eq(w.a.queue.ticket.ownedParty, nil, change .. " cannot establish queue group ownership")
        eq(w.a.settings.cooldownUntil + w.b.settings.cooldownUntil, 0, change .. " has no no-show penalty")
        w:noRatings()
    end

    scenario = "optional group diagnostics cannot stop recovery"
    w = world({ nativeGroupStates = true })
    w:pair(); w:group()
    w.a.env.log = function() error("diagnostic unavailable") end
    w.b.groupPending = true; w:advance(2)
    eq(w.a.queue.state, "GROUPING", "failed state log cannot abort the valid pairing")
    eq(w.b.queue.state, "GROUPING", "peer still waits for pending native proof")
    w.b.groupPending = false; w:advance(5)
    eq(w.a.queue.state, "TRAVELLING", "group recovery survives optional diagnostic failure")
    eq(w.b.queue.state, "TRAVELLING", "peer receives confirmed travel plan after recovery")
    w:noRatings()

    local function planningWorld()
        local sample = world({ nativeGroupStates = true })
        sample.drop = function(p) return p.kind == "PLAN_ACK" end
        sample:pair(); sample:group(); sample:advance(5)
        eq(sample.a.queue.state, "PLANNING", "coordinator has a confirmed native group and open plan")
        eq(sample.b.queue.state, "PLANNING", "peer has received the proposed meeting place")
        sample.a.fd.Database.data, sample.b.fd.Database.data = { matches = {} }, { matches = {} }
        return sample
    end

    local function sentKind(sample, sender, kind)
        local count = 0
        for _, message in ipairs(sample.sent) do
            if message.sender == sender and message.kind == kind then count = count + 1 end
        end
        return count
    end

    scenario = "authenticated callback deadline before timer tick"
    for _, phase in ipairs({ "GROUPING", "PLANNING" }) do
        if phase == "GROUPING" then
            w = world({ nativeGroupStates = true }); w:pair(); w:group()
            w.a.fd.Database.data, w.b.fd.Database.data = { matches = {} }, { matches = {} }
        else w = planningWorld() end
        local t = w.a.queue.ticket
        local travelDeadline, peerAt, grouped = t.travelDeadline, t.lastPeerAt, t.peerGrouped
        w.now = phase == "GROUPING" and t.groupAt + 60 or t.planAt + 20
        local packet = w.b.queue:Control(phase == "GROUPING" and "GROUP" or "PLAN_ACK")
        local forged = w.b.fd.Copy(packet); forged.ticket = packet.ticket .. "-bad"
        w:inject(w.a, forged, w.b.profile.fullName)
        eq(w.a.queue.state, phase, "unbound callback cannot mutate the expired ticket")
        w:inject(w.a, packet, w.b.profile.fullName)
        eq(w.a.queue.state, "IDLE", phase .. " deadline is enforced before the next Tick")
        eq(t.lastPeerAt, peerAt, "expired callback cannot refresh peer heartbeat")
        eq(t.peerGrouped, grouped, "expired callback cannot establish group confirmation")
        eq(t.travelDeadline, travelDeadline, "expired callback cannot restart arrival time")
        eq(sentKind(w, w.a, "GO"), 0, "expired plan cannot announce travel")
        local expected = phase == "GROUPING" and "GROUP_TIMEOUT" or "TECHNICAL"
        local recorded = false
        for _, entry in ipairs(w.a.logs) do
            if entry.topic == "queue state" and entry.detail == "CLEANUP " .. expected .. " " .. phase then recorded = true end
        end
        eq(recorded, true, "callback expiry retains the same fixed cancellation reason as Tick")
        eq(w.a.settings.cooldownUntil + w.b.settings.cooldownUntil, 0, "callback expiry has no absence penalty")
        eq(#w.a.fd.Database.data.matches + #w.b.fd.Database.data.matches, 0, "callback expiry adds no rating history")
        w:noRatings()
    end

    scenario = "pending native proof defers plan acknowledgment"
    w = planningWorld()
    local t = w.a.queue.ticket
    local originalPlanAt, originalDeadline, owned = t.planAt, t.travelDeadline, t.ownedParty
    w.a.groupPending = true; w.now = w.now + 1
    w:inject(w.a, w.b.queue:Control("PLAN_ACK"), w.b.profile.fullName)
    eq(w.a.queue.state, "PLANNING", "valid WHISPER acknowledgment waits for pending native proof")
    eq(t.lastPeerAt, w.now, "authenticated pending acknowledgment can refresh peer heartbeat")
    eq(t.planAt, originalPlanAt, "pending acknowledgment cannot restart plan confirmation time")
    eq(t.travelDeadline, originalDeadline, "pending acknowledgment cannot commit an arrival deadline")
    eq(t.deadline, nil, "pending acknowledgment cannot start the travel timer")
    eq(t.ownedParty, owned, "pending acknowledgment cannot grant additional group ownership")
    eq(sentKind(w, w.a, "GO"), 0, "pending native proof emits no GO")
    eq(w.a.left + w.b.left, 0, "pending acknowledgment never tears down the valid group")
    w.a.groupPending = false; w.drop = nil
    w:inject(w.a, w.b.queue:Control("PLAN_ACK"), w.b.profile.fullName); w:flush()
    eq(w.a.queue.state, "TRAVELLING", "retried acknowledgment succeeds after exact proof recovers")
    eq(w.b.queue.state, "TRAVELLING", "peer receives the successfully committed GO")
    eq(t.planAt, originalPlanAt, "successful recovery preserves original plan confirmation start")
    eq(w.now < originalPlanAt + 20, true, "recovery occurs inside the original twenty-second plan bound")
    eq(#w.a.fd.Database.data.matches + #w.b.fd.Database.data.matches, 0, "planning recovery grants no rated result")
    w:noRatings()

    scenario = "pending native proof defers peer GO confirmation"
    w = planningWorld()
    local t = w.b.queue.ticket
    local originalPlanAt, originalDeadline, owned = t.planAt, t.travelDeadline, t.ownedParty
    w.b.groupPending = true; w.now = w.now + 1
    w:inject(w.a, w.b.queue:Control("PLAN_ACK"), w.b.profile.fullName); w:flush()
    eq(w.a.queue.state, "TRAVELLING", "readable coordinator can commit its own travel transition")
    eq(w.b.queue.state, "PLANNING", "peer GO waits rather than cancels during native proof loading")
    eq(t.lastPeerAt, w.now, "authenticated GO can refresh pending peer heartbeat")
    eq(t.planAt, originalPlanAt, "deferred GO cannot restart peer planning time")
    eq(t.travelDeadline, originalDeadline, "deferred GO cannot apply the proposed travel deadline")
    eq(t.deadline, nil, "deferred GO cannot start peer travel")
    eq(t.ownedParty, owned, "deferred GO cannot grant new group ownership")
    eq(sentKind(w, w.b, "GO_ACK"), 0, "unverified native group cannot acknowledge GO")
    w.b.groupPending = false; w.drop = nil; w:advance(5)
    eq(w.a.queue.state, "TRAVELLING", "coordinator remains on the same committed plan")
    eq(w.b.queue.state, "TRAVELLING", "coordinator retry recovers peer travel inside plan bound")
    eq(w.b.queue.ticket.travelDeadline, w.a.queue.ticket.travelDeadline, "recovered GO retains one shared arrival deadline")
    eq(t.planAt, originalPlanAt, "peer recovery retains original plan start")
    eq(w.now < originalPlanAt + 20, true, "peer GO recovery does not widen planning time")
    eq(#w.a.fd.Database.data.matches + #w.b.fd.Database.data.matches, 0, "GO recovery does not create history")
    w:noRatings()

    scenario = "native membership changes between confirmation reads"
    w = planningWorld()
    local t = w.a.queue.ticket
    local originalDeadline, originalPlanAt = t.travelDeadline, t.planAt
    local party, groupState, reads = w.a.env.party, w.a.env.groupState, 0
    w.a.env.party = function(peer)
        reads = reads + 1
        return reads == 1 and party(peer) or false
    end
    w.a.env.groupState = function(peer) return w.a.env.party(peer) and "EXACT" or "PENDING" end
    w:inject(w.a, w.b.queue:Control("PLAN_ACK"), w.b.profile.fullName)
    eq(reads >= 2, true, "travel checks exact native membership after its status snapshot")
    eq(w.a.queue.state, "PLANNING", "lost final membership proof safely defers transition")
    eq(t.travelDeadline, originalDeadline, "changing getters cannot commit a new deadline")
    eq(t.deadline, nil, "changing getters cannot start a travel timer")
    eq(t.planAt, originalPlanAt, "changing getters cannot reset planning expiry")
    eq(sentKind(w, w.a, "GO"), 0, "changing getters cannot send travel after failed transition")
    w.a.env.party, w.a.env.groupState, w.drop = party, groupState, nil
    w:inject(w.a, w.b.queue:Control("PLAN_ACK"), w.b.profile.fullName); w:flush()
    eq(w.a.queue.state, "TRAVELLING", "fresh exact proof permits the original confirmation retry")
    eq(w.b.queue.state, "TRAVELLING", "only successful transition emits the peer GO")
    eq(#w.a.fd.Database.data.matches + #w.b.fd.Database.data.matches, 0, "changing membership proof cannot create history")
    w:noRatings()

    for _, order in ipairs({ { 1, 2 }, { 2, 1 } }) do
        scenario = "arrival timeout order " .. table.concat(order, "-")
        w = world()
        w:travel()
        local oldSession, waitedAt = w.a.queue.session, w.a.queue.queuedAt
        local oldCancel = w.b.queue:Control("CANCEL", { reason = "TRAVEL_TIMEOUT" })
        w:move(w.a)
        w:advance(5)
        eq(w.a.queue.ticket.ownArrived, true, "local three-sample arrival confirmed")
        eq(w.b.queue.ticket.ownArrived, false, "peer remains away")
        w:expiry(order)
        w:tick(order)
        eq(w.a.queue.state, "SEARCHING", "present player automatically returns to queue")
        eq(w.a.queue.queuedAt, waitedAt, "present player's wait age preserved")
        eq(w.a.queue.session ~= oldSession, true, "automatic requeue creates fresh session")
        eq(w.b.queue.state, "IDLE", "absent player must manually rejoin")
        eq(w.b.settings.cooldownUntil, w.epochBase + math.floor(w.now) + 120, "absent player gets two-minute queue pause")
        eq(w.b.queue:Join(), false, "absence pause enforces explicit delayed return")
        eq(w.a.queue.blocked[w.b.profile.guid] > w.epochBase + w.now, true, "same opponent temporarily excluded")
        w:inject(w.a, oldCancel, w.b.profile.fullName)
        eq(w.a.queue.state, "SEARCHING", "old timeout packet cannot cancel fresh search")
        w:noRatings()
    end

    scenario = "both absent timeout"
    w = world()
    w:travel()
    w:expiry()
    eq(w.a.queue.state, "IDLE", "first absent player removed")
    eq(w.b.queue.state, "IDLE", "second absent player removed")
    eq(w.a.settings.cooldownUntil, w.epochBase + math.floor(w.now) + 120, "first absent player pause")
    eq(w.b.settings.cooldownUntil, w.epochBase + math.floor(w.now) + 120, "second absent player pause")
    w:noRatings()

    scenario = "phase ambiguity"
    w = world()
    w:travel()
    w:move(w.a); w:move(w.b)
    w.a.phaseUnknown, w.b.phaseUnknown = true, true
    w:advance(5)
    eq(w.a.queue.ticket.ownArrived, true, "coordinate arrival alone known")
    eq(w.a.queue.state, "TRAVELLING", "coordinates never replace native visibility")
    w:expiry()
    eq(w.a.queue.state, "IDLE", "phase ambiguity cancels technically")
    eq(w.b.queue.state, "IDLE", "peer phase ambiguity cancels technically")
    eq(w.a.settings.cooldownUntil, 0, "phase ambiguity never penalizes first player")
    eq(w.b.settings.cooldownUntil, 0, "phase ambiguity never penalizes peer")
    w:noRatings()

    scenario = "unavailable position is technical"
    w = world()
    w:travel()
    w.a.missingProfile = true
    w:advance(1)
    eq(w.a.queue.state, "IDLE", "unreadable character data cancels technically")
    eq(w.b.queue.state, "IDLE", "peer released after unreadable data")
    eq(w.a.settings.cooldownUntil, 0, "missing local data has no absence penalty")
    eq(w.b.settings.cooldownUntil, 0, "missing peer data has no absence penalty")
    w:noRatings()

    scenario = "loading grace and deadline preservation"
    w = world()
    w:travel()
    local deadline = w.a.queue.ticket.deadline
    w.a.queue:World(true)
    w:advance(44)
    eq(w.a.queue.state, "TRAVELLING", "loading below forty-five seconds tolerated")
    eq(w.a.queue.ticket.deadline, deadline, "loading never extends travel timer")
    w.a.queue:World(false)
    w:advance(2)
    eq(w.a.queue.state, "TRAVELLING", "positions recover after map load")
    eq(w.a.queue.ticket.deadline, deadline, "map load recovery retains agreed deadline")
    w.a.queue:World(true)
    w:advance(46)
    eq(w.a.queue.state, "IDLE", "loading over forty-five seconds cancels technically")
    eq(w.b.queue.state, "IDLE", "peer receives long-loading cancellation")
    eq(w.a.settings.cooldownUntil, 0, "loading failure is not a no-show")
    eq(w.b.settings.cooldownUntil, 0, "connection failure does not penalize peer")
    w:noRatings()

    scenario = "combat pauses search"
    w = world()
    w:join()
    w.a.combat = true
    w:advance(3)
    eq(w.a.queue.state, "PAUSED", "combat pauses matching")
    eq(w.a.queue.ticket, nil, "combat player has no reservation")
    w.a.combat = false
    w:advance(4)
    eq(w.a.queue.state, "GROUPING", "search resumes after combat")

    scenario = "level or rating changes release reservation"
    for _, key in ipairs({ "level", "maxLevel", "rating" }) do
        w = world()
        w:travel()
        w.a.profile[key] = w.a.profile[key] + 1
        w:advance(1)
        eq(w.a.queue.state, "IDLE", key .. " change cancels old pairing")
        eq(w.b.queue.state, "IDLE", key .. " change releases peer")
        eq(w.a.settings.cooldownUntil, 0, key .. " change never penalized")
        w:noRatings()
    end

    scenario = "changed group cleanup guard"
    w = world({ count = 3 })
    eq(w.a.queue:Join(), true, "coordinator joins")
    eq(w.b.queue:Join(), true, "peer joins")
    w:advance(4)
    w:group()
    w:advance(5)
    eq(w.a.queue.ticket.ownedParty, true, "created two-person party recognized")
    w.a.group[w.c.profile.guid] = true
    w:advance(1)
    eq(w.a.queue.state, "CLEANUP", "changed group waits for confirmed solo state")
    eq(w.a.left, 0, "queue never leaves a group containing an additional player")
    eq(w.b.left, 0, "peer also preserves changed group")
    local group = w.a.group
    for key in pairs(group) do group[key] = nil end
    w:tick()
    eq(w.a.queue.state, "IDLE", "cleanup completes after player leaves group")
    eq(w.b.queue.state, "IDLE", "peer cleanup also completes")
    w:noRatings()

    scenario = "unrelated duel and reload end participation"
    w = world()
    w:travel()
    w.a.queue:OnDuel("request", { opponent = { guid = "Player-1-DDD", fullName = "Stranger-Forever" } })
    w:flush(); w:tick()
    eq(w.a.queue.state, "IDLE", "unrelated native duel releases queue")
    eq(w.b.queue.state, "IDLE", "peer released for unrelated duel")
    w = world(); w:travel()
    w.a.queue:World(true, true)
    w:flush(); w:tick()
    eq(w.a.queue.state, "IDLE", "logout/reload ends active match")
    eq(w.b.queue.state, "IDLE", "peer notified of logout/reload")
    w:noRatings()
end
