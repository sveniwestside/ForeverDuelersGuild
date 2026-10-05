return function(_, equal, newNamespace)
    -- Pure lifecycle engine, two clients, scheduled delivery. Every send
    -- drains at the current time (dropping obsolete packets exactly like the
    -- real outbound queue) and arrives after the configured one-way latency.
    local scenarioName
    local function eq(actual, expected, label)
        equal(actual, expected, scenarioName .. ": " .. label)
    end

    local function world(options)
        options = options or {}
        local w = { now = 0, timers = {}, clients = {}, sent = {}, latency = options.latency or 0, order = 0 }
        local identities = {
            { guid = "Player-1-AAA", name = "Alpha", realm = "Forever", fullName = "Alpha-Forever", classFile = "MAGE", specId = 64, level = 30, maxLevel = 60 },
            { guid = "Player-1-BBB", name = "Beta", realm = "Forever", fullName = "Beta-Forever", classFile = "ROGUE", specId = 261, level = 30, maxLevel = 60 },
        }
        function w:schedule(at, callback)
            self.order = self.order + 1
            self.timers[#self.timers + 1] = { at = at, order = self.order, callback = callback }
        end
        for index, identity in ipairs(identities) do
            local fd = newNamespace()
            local c = { fd = fd, identity = fd.Copy(identity), accepted = 0, renders = {}, logs = {}, prints = {}, items = {} }
            w.clients[index] = c
            fd.Database:Initialize(nil, c.identity)
            c.db = fd.Database
            local env = {
                now = function() return w.now end,
                epoch = function() return 1700000000 + math.floor(w.now) end,
                random = function() return index * 1337 end,
                identity = function() return c.identity end,
                -- nil: no unit currently resolves to the opponent.
                opponentIdentity = function() return c.observed end,
                known = function() return c.known == true end,
                combat = function() return c.combat == true end,
                after = function(seconds, callback) w:schedule(w.now + seconds, callback) end,
                send = function(item) return w:submit(c, item) end,
                render = function(m) c.renders[#c.renders + 1] = m.state end,
                hide = function() end,
                accept = function() c.accepted = c.accepted + 1; return not c.failAccept end,
                log = function(...) c.logs[#c.logs + 1] = { ... } end,
                print = function(text) c.prints[#c.prints + 1] = text end,
            }
            c.duel = fd.Duel:New(env, c.db)
        end
        w.a, w.b = w.clients[1], w.clients[2]
        -- reject(packet, client, item) -> "queue" (not queued), "failed"/"expired" (result), nil (sent)
        -- delay(packet, client, message) -> seconds, or false to lose the packet
        function w:submit(c, item)
            local packet = assert(c.fd.Protocol:Decode(item.payload))
            c.items[#c.items + 1] = item
            if self.reject and self.reject(packet, c, item) == "queue" then return false end
            local function drain()
                if not item.immediate and not c.duel:Current(item.match, item.kind) then return item.onResult("dropped") end
                local status = self.reject and self.reject(packet, c, item)
                if status then return item.onResult(status) end
                local message = { payload = item.payload, from = c.identity.fullName, to = item.match.opponent.fullName,
                    kind = packet.kind, packet = packet, at = self.now, immediate = item.immediate }
                self.sent[#self.sent + 1] = message
                item.onResult("sent")
                local delay = self.latency
                if self.delay then delay = self.delay(packet, c, message) end
                if delay then self:schedule(self.now + delay, function() self:deliver(message) end) end
            end
            if item.immediate then drain() else self:schedule(self.now, drain) end
            return true
        end
        function w:deliver(message)
            for _, c in ipairs(self.clients) do
                if c.identity.fullName == message.to then
                    message.delivered = true
                    c.duel:Receive(message.payload, message.from)
                end
            end
        end
        function w:advance(seconds)
            local target, count = self.now + (seconds or 0), 0
            while true do
                local nextIndex, nextTimer
                for index, timer in ipairs(self.timers) do
                    if timer.at <= target and (not nextTimer or timer.at < nextTimer.at
                        or (timer.at == nextTimer.at and timer.order < nextTimer.order)) then
                        nextIndex, nextTimer = index, timer
                    end
                end
                if not nextIndex then break end
                count = count + 1
                assert(count < 5000, scenarioName .. ": wire did not settle")
                table.remove(self.timers, nextIndex)
                self.now = math.max(self.now, nextTimer.at)
                nextTimer.callback()
            end
            self.now = target
        end
        function w:flush() self:advance(0) end
        function w:count(kind, from)
            local total = 0
            for _, message in ipairs(self.sent) do
                if message.kind == kind and (not from or message.from == from.identity.fullName) then total = total + 1 end
            end
            return total
        end
        function w:begin()
            eq(self.a.duel:Begin("OUTGOING", self.a.identity, self.b.identity), true, "outgoing detected")
            eq(self.b.duel:Begin("INCOMING", self.b.identity, self.a.identity), true, "incoming detected")
        end
        function w:ready()
            self:begin()
            self:flush()
            eq(self.a.duel:State(), "READY", "outgoing presence confirmed")
            eq(self.b.duel:State(), "READY", "incoming presence confirmed")
            eq(self.a.duel.active.matchId, self.b.duel.active.matchId, "shared match ID")
        end
        function w:agree(first)
            local proposer = first == "a" and self.a or self.b
            local accepter = first == "a" and self.b or self.a
            local acceptedBefore = self.b.accepted
            proposer.duel:AcceptRated()
            self:flush()
            eq(proposer.duel:State(), "LOCAL_ACCEPTED", "proposer awaits explicit consent")
            eq(accepter.duel:State(), "REMOTE_ACCEPTED", "peer sees proposal")
            eq(self.b.accepted, acceptedBefore, "proposal does not accept native duel")
            accepter.duel:AcceptRated()
            self:flush()
            eq(self.a.duel:State(), "RATED_CONFIRMED", "outgoing rated agreement")
            eq(self.b.duel:State(), "RATED_CONFIRMED", "incoming rated agreement")
            eq(self.a.accepted, 0, "challenger does not call native accept")
            eq(self.b.accepted, acceptedBefore + 1, "receiver accepts native duel exactly once")
        end
        function w:start()
            self.a.duel:Countdown(3)
            self.b.duel:Countdown(3)
            self:flush()
            eq(self.a.duel:State(), "COUNTDOWN", "outgoing countdown")
            eq(self.b.duel:State(), "COUNTDOWN", "incoming countdown")
            self:advance(3)
            eq(self.a.duel:State(), "IN_PROGRESS", "outgoing started")
            eq(self.b.duel:State(), "IN_PROGRESS", "incoming started")
        end
        function w:running(first)
            self:ready()
            self:agree(first)
            self:start()
        end
        function w:finish(winner)
            local guid = winner == "b" and self.b.identity.guid or self.a.identity.guid
            -- Exercise both legal event orders in the same match.
            self.a.duel:Result(guid, "test-local-system")
            self.a.duel:Finished()
            self.b.duel:Finished()
            self.b.duel:Result(guid, "test-local-system")
            self:flush()
        end
        function w:unchanged()
            for _, c in ipairs(self.clients) do
                eq(c.db:GetStats().rating, 1500, "unrated preserves rating")
                eq(c.db:GetStats().wins, 0, "unrated preserves wins")
                eq(c.db:GetStats().losses, 0, "unrated preserves losses")
                eq(#c.db.data.matches, 0, "unrated never records history")
            end
        end
        function w:inject(from, to, kind, changes, sender)
            local m = from.duel.active
            local packet = from.duel:Packet(m, kind, kind == "RESULT" and from.identity.guid or nil, m.peerNonce or "fade")
            for key, value in pairs(changes or {}) do packet[key] = value end
            return to.duel:Receive(assert(from.fd.Protocol:Encode(packet)), sender or from.identity.fullName)
        end
        return w
    end

    local function printed(c, text)
        for _, line in ipairs(c.prints) do
            if line:find(text, 1, true) then return true end
        end
        return false
    end
    local function logged(c, topic, value)
        for _, entry in ipairs(c.logs) do
            if entry[1] == topic and (value == nil or entry[2] == value) then return true end
        end
        return false
    end

    local function scenario(name, test, options)
        scenarioName = name
        test(world(options))
    end

    for _, failure in ipairs({
        { label = "opponent GUID", changes = { guid = "Player-1-CCC" }, reason = "opponent GUID mismatch", value = "Player-1-CCC" },
        { label = "local GUID", changes = { peerGUID = "Player-1-CCC" }, reason = "local GUID mismatch", value = "Player-1-CCC" },
        { label = "same role", changes = { role = "OUTGOING" }, reason = "duel roles are not complementary", value = "received=OUTGOING" },
        { label = "native level", changes = { level = 31 }, reason = "native level or level cap mismatch", value = "received=31/60" },
        { label = "native cap", changes = { maxLevel = 61 }, reason = "native level or level cap mismatch", value = "received=30/61" },
        { label = "native class", changes = { classFile = "MAGE" }, reason = "native class mismatch", value = "received=MAGE" },
        { label = "native sender", sender = "Other-Forever", changes = {}, reason = "sender mismatch", value = "received=Other-Forever" },
    }) do
        scenario("diagnose rejected " .. failure.label, function(w)
            w:begin()
            local queued = #w.b.items
            local accepted, detail = w:inject(w.b, w.a, "HELLO", failure.changes, failure.sender)
            eq(accepted, false, "rejected packet reports rejection")
            eq(detail:find(failure.reason, 1, true) ~= nil, true, "specific native prerequisite explained")
            eq(detail:find(failure.value, 1, true) ~= nil, true, "received mismatch value retained")
            eq(w.a.duel.active.peerStatus, detail, "current request exposes diagnosis")
            eq(w.a.duel.active.peerNonce, nil, "diagnostics do not bind unverified peer")
            eq(#w.b.items, queued, "rejection does not acknowledge mismatched identity")
            eq(w.a.duel:State(), "CHECKING_ADDON", "unproven packet does not poison current request")
            eq(detail:find(w.a.duel.active.nonce, 1, true), nil, "local nonce excluded from diagnostics")
            w:unchanged()
        end)
    end

    scenario("diagnostic sink failure cannot prevent safe discovery", function(w)
        w:begin()
        local oldLog = w.a.duel.env.log
        w.a.duel.env.log = function(topic, ...)
            if topic == "peer validation" then error("injected diagnostic failure") end
            oldLog(topic, ...)
        end
        local accepted, status = w:inject(w.b, w.a, "HELLO")
        eq(accepted, true, "verified hello still acknowledged")
        eq(status:find("acknowledgment queued", 1, true) ~= nil, true, "queued reply distinguished from nonce proof")
        eq(w.a.duel.active.peerNonce, nil, "hello remains insufficient to bind a request")
        w:flush()
        eq(w.a.duel:State(), "READY", "logged proof failure does not interrupt discovery")
        eq(w.b.duel:State(), "READY", "peer remains ready after diagnostic exception")
        eq(w.a.duel.active.peerStatus:find("current native request acknowledged", 1, true) ~= nil, true,
            "nonce-bound proof distinguished from a queued hello reply")
        w:unchanged()
    end)

    scenario("reversed rematch rejects delayed original handshake", function(w)
        w:begin()
        local oldA = assert(w.a.fd.Protocol:Encode(w.a.duel:Packet(w.a.duel.active, "HELLO")))
        local oldB = assert(w.b.fd.Protocol:Encode(w.b.duel:Packet(w.b.duel.active, "HELLO")))
        w.delay = function() return false end
        w:advance(7)
        w.a.duel:Abort("cancelled", true)
        w.b.duel:Abort("cancelled", true)
        w:advance(4)
        w.a.duel:Begin("INCOMING", w.a.identity, w.b.identity)
        w.b.duel:Begin("OUTGOING", w.b.identity, w.a.identity)
        w:advance(24)
        local queued = #w.a.items + #w.b.items
        local acceptedA, detailA = w.a.duel:Receive(oldB, w.b.identity.fullName)
        local acceptedB, detailB = w.b.duel:Receive(oldA, w.a.identity.fullName)
        eq(acceptedA, false, "35-second old incoming hello rejected after reversed rematch")
        eq(acceptedB, false, "35-second old outgoing hello rejected after reversed rematch")
        eq(detailA:find("roles are not complementary", 1, true) ~= nil, true, "stale opposite role explained locally")
        eq(detailB:find("roles are not complementary", 1, true) ~= nil, true, "stale opposite role explained remotely")
        eq(#w.a.items + #w.b.items, queued, "stale original hellos do not receive acknowledgments")
        eq(w.a.duel.active.peerNonce, nil, "old packet does not bind rematch nonce")
        w.delay = nil
        w.a.duel:Receive(assert(w.b.fd.Protocol:Encode(w.b.duel:Packet(w.b.duel.active, "HELLO"))), w.b.identity.fullName)
        w.b.duel:Receive(assert(w.a.fd.Protocol:Encode(w.a.duel:Packet(w.a.duel.active, "HELLO"))), w.a.identity.fullName)
        w:flush()
        eq(w.a.duel:State(), "READY", "current rematch can still recover discovery")
        eq(w.b.duel:State(), "READY", "both current rematch roles acknowledged")
        w:unchanged()
    end)

    scenario("hello of an older request is stale and unanswered", function(w)
        w.a.duel:Begin("OUTGOING", w.a.identity, w.b.identity)
        local old = assert(w.a.fd.Protocol:Encode(w.a.duel:Packet(w.a.duel.active, "HELLO")))
        w.a.duel:Abort("cancelled", false)
        w.timers = {}
        w:advance(20)
        w.b.duel:Begin("INCOMING", w.b.identity, w.a.identity)
        local queued = #w.b.items
        local accepted, status = w.b.duel:Receive(old, w.a.identity.fullName)
        eq(accepted, false, "hello whose nonce predates the request by more than ten seconds rejected")
        eq(status:find("stale request", 1, true) ~= nil, true, "stale rejection explained")
        eq(#w.b.items, queued, "stale hello gets no acknowledgment")
        w:unchanged()
    end)

    for _, proposer in ipairs({ "a", "b" }) do
        scenario("full rated match proposed by " .. proposer, function(w)
            w:running(proposer)
            local matchId = w.a.duel.active.matchId
            eq(printed(w.a, "RATED duel vs Beta-Forever (win +16 / loss -16)."), true, "challenger told the duel is rated")
            eq(printed(w.b, "RATED duel vs Alpha-Forever (win +16 / loss -16)."), true, "receiver told the duel is rated")
            w:advance(15)
            w:finish("a")
            eq(w.a.duel:State(), "IDLE", "winner returns idle")
            eq(w.b.duel:State(), "IDLE", "loser returns idle")
            eq(w.a.db:GetStats().rating, 1516, "winner gains Elo")
            eq(w.b.db:GetStats().rating, 1484, "loser loses same Elo")
            eq(w.a.db:GetStats().wins, 1, "winner counts once")
            eq(w.b.db:GetStats().losses, 1, "loser counts once")
            eq(w.a.db.data.matches[1].matchId, matchId, "winner saves agreed ID")
            eq(w.b.db.data.matches[1].matchId, matchId, "loser saves same ID")
            eq(w.a.db.data.matches[1].protocolVersion, 3, "records carry the protocol version")
            eq(w.a.db.data.matches[1].result, "WIN", "winner result")
            eq(w.b.db.data.matches[1].result, "LOSS", "loser result")
            eq(printed(w.a, "Rated WIN vs Beta-Forever: +16 rating (1516)."), true, "winner sees the outcome")
            eq(printed(w.b, "Rated LOSS vs Alpha-Forever: -16 rating (1484)."), true, "loser sees the outcome")
            w.a.duel:Finished()
            w.b.duel:Finished()
            w.a.duel:Result(w.a.identity.guid, "duplicate")
            for _, message in ipairs(w.sent) do
                if message.kind == "RESULT" then w:deliver(message) end
            end
            w:advance(60)
            eq(w:count("RESULT") <= 2 + 2 * #w.a.fd.C.RESULT_SCHEDULE, true,
                "two finalized clients answer each other's late reports only a bounded number of times")
            eq(#w.a.db.data.matches, 1, "winner duplicate ending ignored")
            eq(#w.b.db.data.matches, 1, "loser duplicate ending ignored")
            eq(w.a.db:GetStats().rating + w.b.db:GetStats().rating, 3000, "rating conserved")
        end)
    end

    scenario("ordinary duel with a player without the addon stays silent", function(w)
        w.delay = function(_, c) if c == w.b then return false end end
        w.b.duel:Begin("INCOMING", w.b.identity, w.a.identity)
        w:advance(10)
        eq(w.b.duel:State(), "CHECKING_ADDON", "no answer keeps the request unproven")
        w.b.duel:ObservedAccept()
        eq(w.b.duel:State(), "UNRATED", "Blizzard's Accept keeps the duel ordinary")
        w.b.duel:Countdown(3)
        eq(w.b.duel:State(), "UNRATED_ACTIVE", "ordinary duel starts unrated")
        w.b.duel:Finished()
        eq(#w.b.prints, 0, "nothing is printed for a player who never answered")
        eq(w:count("CANCEL"), 0, "no cancel goes to a player who never answered")
        w:unchanged()
    end)

    scenario("discovery backoff bounds traffic to a missing peer", function(w)
        w.delay = function() return false end
        w.a.duel:Begin("OUTGOING", w.a.identity, w.b.identity)
        w:advance(49.9)
        eq(w.a.duel:State(), "CHECKING_ADDON", "request remains discoverable before deadline")
        eq(w:count("HELLO"), #w.a.fd.C.HELLO_SCHEDULE, "HELLO only at 0, 1, 3, 7, 15 and 31 seconds")
        w:advance(0.2)
        eq(w.a.duel:State(), "IDLE", "native request window ends the request")
        local before = #w.sent
        w:advance(60)
        eq(#w.sent, before, "expired request sends no more discovery")
        eq(#w.a.prints, 0, "unknown missing peer causes no chat output")
        w:unchanged()
    end)

    scenario("known addon user without reply gets one delay notice", function(w)
        w.delay = function() return false end
        w.a.known = true
        w.a.duel:Begin("OUTGOING", w.a.identity, w.b.identity)
        w:advance(7.9)
        eq(#w.a.prints, 0, "no notice before eight seconds")
        w:advance(0.2)
        eq(#w.a.prints, 1, "one notice after eight seconds")
        eq(w.a.prints[1]:find("delayed", 1, true) ~= nil, true, "notice explains delayed addon messages")
        w:advance(45)
        eq(#w.a.prints, 1, "notice is shown once")
    end)

    scenario("acknowledgments are limited per peer nonce", function(w)
        w.a.duel:Begin("OUTGOING", w.a.identity, w.b.identity)
        w.b.duel:Begin("INCOMING", w.b.identity, w.a.identity)
        local hello = assert(w.a.fd.Protocol:Encode(w.a.duel:Packet(w.a.duel.active, "HELLO")))
        for _ = 1, 5 do w.b.duel:Receive(hello, w.a.identity.fullName) end
        local acks = 0
        for _, item in ipairs(w.b.items) do if item.kind == "HELLO_ACK" then acks = acks + 1 end end
        eq(acks, 1, "duplicate HELLOs within three seconds get one acknowledgment")
        w.now = w.now + 3
        w.b.duel:Receive(hello, w.a.identity.fullName)
        acks = 0
        for _, item in ipairs(w.b.items) do if item.kind == "HELLO_ACK" then acks = acks + 1 end end
        eq(acks, 2, "a later retry is answered again")
    end)

    scenario("discovery round trip is recorded", function(w)
        w:begin()
        w:advance(2)
        eq(w.a.duel:State(), "READY", "latency handshake completes")
        eq(w.a.duel.active.rtt, 1, "first HELLO submission to first valid HELLO_ACK")
        eq(w.a.duel.active.peerVersion, w.a.fd.C.VERSION, "peer addon version learned from discovery")
    end, { latency = 0.5 })

    scenario("ready pair generates no periodic handshake traffic", function(w)
        w:ready()
        local before = #w.sent
        w:advance(40)
        eq(#w.sent, before, "no retries once both clients are bound")
        eq(w.a.duel:State(), "READY", "timer cannot grant outgoing consent")
        eq(w.b.duel:State(), "READY", "timer cannot grant incoming consent")
        w:unchanged()
    end)

    scenario("duplicate acknowledgments settle without ping pong", function(w)
        w:ready()
        local before = #w.sent
        eq(before <= 4, true, "initial discovery exchange has bounded message count")
        local copies = {}
        for _, message in ipairs(w.sent) do if message.kind == "HELLO_ACK" then copies[#copies + 1] = message end end
        for _ = 1, 10 do for _, message in ipairs(copies) do w:deliver(message) end end
        w:flush()
        eq(#w.sent, before, "duplicate acknowledgments do not trigger further acknowledgments")
        eq(w.a.duel:State(), "READY", "duplicates preserve outgoing readiness")
        eq(w.b.duel:State(), "READY", "duplicates preserve incoming readiness")
    end)

    scenario("consent has no negotiation timer inside the native window", function(w)
        w:ready()
        w.a.duel:AcceptRated()
        w:advance(40)
        eq(w.a.duel:State(), "LOCAL_ACCEPTED", "proposal stays open while the native request is pending")
        eq(w.b.duel:State(), "REMOTE_ACCEPTED", "peer can still decide")
        w.b.duel:AcceptRated()
        w:flush()
        eq(w.b.accepted, 1, "late second click still accepts natively")
        w:start(); w:finish("b")
        eq(#w.a.db.data.matches, 1, "slow decision still rates")
        eq(#w.b.db.data.matches, 1, "slow decision rates on both clients")
    end)

    scenario("incoming accepts natively only with both consents", function(w)
        w:ready()
        w.b.duel:AcceptRated()
        w:flush()
        eq(w.b.duel:State(), "LOCAL_ACCEPTED", "own consent alone waits")
        eq(w.b.accepted, 0, "own consent alone never accepts")
        eq(w.a.duel:State(), "REMOTE_ACCEPTED", "challenger sees the receiver's consent")
        w.a.duel:AcceptRated()
        w:flush()
        eq(w.b.accepted, 1, "challenger's ACCEPT completes the agreement and the native accept")
        eq(w:count("ACCEPT", w.a), 1, "no confirmation round trip is needed")
    end)

    scenario("lost ACCEPT is retransmitted", function(w)
        w:ready()
        local lost = 0
        w.delay = function(packet, c)
            if packet.kind == "ACCEPT" and c == w.a and lost == 0 then lost = 1; return false end
            return 0
        end
        w.a.duel:AcceptRated()
        w:flush()
        eq(w.b.duel:State(), "READY", "first ACCEPT lost")
        w:advance(2)
        eq(w.b.duel:State(), "REMOTE_ACCEPTED", "retransmit after two seconds delivers the proposal")
        w.b.duel:AcceptRated()
        w:flush()
        eq(w.b.accepted, 1, "recovered agreement accepts natively once")
        w:advance(30)
        eq(w:count("ACCEPT", w.a) <= #w.a.fd.C.ACCEPT_SCHEDULE, true, "retransmits bounded by the schedule")
    end)

    scenario("duplicate consent is idempotent", function(w)
        w:ready()
        w.a.duel:AcceptRated()
        w:advance(25)
        eq(w:count("ACCEPT", w.a), #w.a.fd.C.ACCEPT_SCHEDULE, "unanswered consent is retransmitted on schedule")
        eq(w.b.duel:State(), "REMOTE_ACCEPTED", "duplicates do not change the peer state")
        w.b.duel:AcceptRated()
        w:flush()
        for _, message in ipairs(w.sent) do if message.kind == "ACCEPT" then w:deliver(message) end end
        eq(w.b.accepted, 1, "duplicate ACCEPTs accept natively once")
        local before = w:count("ACCEPT", w.b)
        w:advance(30)
        eq(w:count("ACCEPT", w.b), before, "receiver stops retransmitting after its native accept")
    end)

    scenario("early consent binds through the echoed ACCEPT", function(w)
        w.delay = function(packet, c) if packet.kind == "HELLO_ACK" and c == w.a then return false end return 0 end
        w:begin(); w:flush()
        eq(w.a.duel:State(), "READY", "challenger bound by the receiver's ACK")
        eq(w.b.duel:State(), "CHECKING_ADDON", "receiver still lacks the challenger's ACK")
        w.a.duel:AcceptRated()
        w:flush()
        eq(w.b.duel:State(), "REMOTE_ACCEPTED", "ACCEPT echoing the receiver's nonce proves the peer")
        w.b.duel:AcceptRated(); w:flush()
        eq(w.b.accepted, 1, "agreement completes")
        w:start(); w:finish("a")
        eq(#w.a.db.data.matches, 1, "challenger completes")
        eq(#w.b.db.data.matches, 1, "receiver completes")
    end)

    scenario("late clicks near the native deadline still rate", function(w)
        w:begin()
        w:advance(45)
        w.a.duel:AcceptRated()
        w:advance(1)
        w.b.duel:AcceptRated()
        w:advance(0.7)
        eq(w.b.accepted, 1, "receiver accepted at the end of the window")
        w.a.duel:Countdown(3); w.b.duel:Countdown(3)
        w:advance(1.5)
        eq(w.a.duel:State(), "COUNTDOWN", "pending timer cannot abort a running countdown")
        w:advance(10)
        eq(w.a.duel:State(), "IN_PROGRESS", "challenger fights the rated duel")
        eq(w.b.duel:State(), "IN_PROGRESS", "receiver fights the rated duel")
        w:finish("a"); w:advance(1)
        eq(#w.a.db.data.matches, 1, "late agreement finalizes")
        eq(#w.b.db.data.matches, 1, "late agreement finalizes on the peer")
    end, { latency = 0.3 })

    scenario("challenger with consent waits for a late native accept", function(w)
        w.a.duel:Begin("OUTGOING", w.a.identity, w.b.identity, 0)
        w:advance(2)
        w.b.duel:Begin("INCOMING", w.b.identity, w.a.identity, 2)
        w:advance(2)
        w.b.duel:AcceptRated()
        w:advance(45.6)
        w.a.duel:AcceptRated()
        w:advance(0.6)
        eq(w.a.duel:State(), "RATED_CONFIRMED", "challenger keeps its agreement past its own window")
        eq(w.b.accepted, 1, "receiver accepted inside its later window")
        w.a.duel:Countdown(3); w.b.duel:Countdown(3)
        w:advance(4)
        eq(w.a.duel:State(), "IN_PROGRESS", "grace avoided a cancel after the native accept")
        eq(w:count("CANCEL"), 0, "nobody cancelled")
    end, { latency = 0.3 })

    scenario("tentatively rated countdown when the receiver's ACCEPT is lost", function(w)
        w:ready()
        w.a.duel:AcceptRated(); w:flush()
        w.delay = function(packet, c) if packet.kind == "ACCEPT" and c == w.b then return false end return 0 end
        w.b.duel:AcceptRated(); w:flush()
        eq(w.b.accepted, 1, "receiver had both consents and accepted")
        eq(w.a.duel:State(), "LOCAL_ACCEPTED", "challenger never saw the receiver's ACCEPT")
        w.a.duel:Countdown(3); w.b.duel:Countdown(3); w:flush()
        eq(w.a.duel:State(), "COUNTDOWN", "countdown after own consent is tentatively rated")
        eq(w.a.duel.active.peerStart, true, "receiver's START proves its consent")
        w:advance(3); w:finish("b")
        eq(#w.a.db.data.matches, 1, "tentative countdown finalizes with peer evidence")
        eq(#w.b.db.data.matches, 1, "receiver finalizes")
    end)

    scenario("receiver accepting through Blizzard keeps the duel unrated", function(w)
        w:ready()
        w.a.duel:AcceptRated(); w:flush()
        w.b.duel:ObservedAccept()
        eq(w.b.duel:State(), "UNRATED", "Blizzard's Accept is an unrated choice")
        w:flush()
        eq(w.a.duel:State(), "UNRATED", "challenger receives the cancel")
        eq(printed(w.a, "Your opponent chose an unrated duel"), true, "challenger told why")
        w.a.duel:Countdown(3); w.b.duel:Countdown(3)
        eq(w.a.duel:State(), "UNRATED_ACTIVE", "challenger duel unrated")
        eq(printed(w.a, "This duel is UNRATED: Your opponent chose an unrated duel."), true, "countdown outcome explained")
        eq(printed(w.b, "This duel is UNRATED: You kept this duel unrated."), true, "receiver outcome explained")
        w:advance(3); w:finish("a"); w:advance(40)
        w:unchanged()
    end)

    scenario("lost cancel after an unrated accept still cannot rate", function(w)
        w:ready()
        w.a.duel:AcceptRated(); w:flush()
        w.delay = function(packet) if packet.kind == "CANCEL" then return false end return 0 end
        w.b.duel:ObservedAccept(); w:flush()
        w.a.duel:Countdown(3); w.b.duel:Countdown(3); w:flush()
        eq(w.a.duel:State(), "COUNTDOWN", "challenger's countdown is only tentatively rated")
        eq(w.a.duel.active.peerStart, nil, "an unrated receiver never sends START")
        w:advance(3); w:finish("a")
        eq(w.a.duel:State(), "FINISHING", "challenger waits for the peer result")
        w:advance(w.a.fd.C.RESULT_TIMEOUT)
        eq(w.a.duel:State(), "IDLE", "result timeout ends the tentative match")
        eq(printed(w.a, "Match not rated: result could not be confirmed by both clients."), true, "challenger told")
        eq(w:count("RESULT", w.b), 0, "unrated receiver never reports a result")
        w:unchanged()
    end)

    scenario("keep unrated notifies the peer with a reason", function(w)
        w:ready()
        w.a.duel:KeepUnrated()
        eq(w.a.duel:State(), "UNRATED", "explicit choice")
        eq(printed(w.a, "This duel will be UNRATED: You kept this duel unrated."), true, "own choice confirmed")
        w:flush()
        eq(w.b.duel:State(), "UNRATED", "peer unrated")
        eq(printed(w.b, "This duel will be UNRATED: Your opponent chose an unrated duel."), true, "peer told why")
        eq(logged(w.b, "cancel received", "choice"), true, "received reason persisted")
        eq(logged(w.a, "unrated", "choice"), true, "own reason persisted")
        w.b.duel:AcceptRated()
        eq(w.b.accepted, 0, "rated consent closed")
        w:unchanged()
    end)

    for _, case in ipairs({
        { "combat", "Combat started" }, { "level", "A level changed" }, { "expired", "The request expired" },
        { "error", "Addon error" }, { "lost", "Your opponent's addon lost track of you" },
        { "outdated", "Your opponent uses an older ForeverDuel version" }, { "unknown_future", "stopped rated play" },
    }) do
        scenario("cancel reason " .. case[1] .. " is shown to the peer", function(w)
            w:ready()
            w.a.duel:Unrate(case[1], true)
            w:flush()
            eq(w.b.duel:State(), "UNRATED", "peer unrated")
            eq(printed(w.b, case[2]), true, "peer reason text")
        end)
    end

    scenario("native decline clears both negotiations", function(w)
        w:ready()
        w.b.duel:Cancelled()
        w:flush()
        eq(w.b.duel:State(), "IDLE", "decliner idle")
        eq(w.a.duel:State(), "UNRATED", "peer proposal cancelled")
        eq(printed(w.a, "The duel request was cancelled"), true, "peer told the request was cancelled")
        w:unchanged()
    end)

    scenario("native acceptance without countdown unrates and releases the match", function(w)
        w:ready(); w:agree("b")
        -- AcceptDuel returned without effect (e.g. a blocked call): no countdown.
        w:advance(w.b.fd.C.START_TIMEOUT - 0.1)
        eq(w.b.duel:State(), "RATED_CONFIRMED", "the countdown gets the full start window")
        w:advance(0.1)
        eq(w.b.duel:State(), "IDLE", "receiver releases the match: nothing is left to observe")
        eq(w.b.duel.last.reason, "timeout", "release reason kept")
        eq(logged(w.b, "unrated", "timeout"), true, "unrate reason persisted")
        eq(printed(w.b, "This duel will be UNRATED: The duel did not start after your acceptance."), true, "receiver told why")
        eq(printed(w.b, "If no duel started, ask Alpha-Forever to challenge you again."), true, "receiver told how to recover")
        w:flush()
        eq(w.a.duel:State(), "UNRATED", "challenger receives the timeout cancel")
        eq(w.a.duel.active.reason, "peer:timeout", "timeout reason travels")
        local cancels = w:count("CANCEL")
        w:advance(w.a.fd.C.PENDING_TIMEOUT)
        eq(w.a.duel:State(), "IDLE", "challenger released at the end of its window")
        eq(w:count("CANCEL"), cancels, "a closed match is released without another CANCEL")
        eq(w.b.duel:Begin("INCOMING", w.b.identity, w.a.identity), true, "a new request can start")
        w:unchanged()
    end)

    scenario("late native accept without countdown is released after the native window", function(w)
        w:begin()
        w:advance(44)
        w.a.duel:AcceptRated(); w:flush()
        w.b.duel:AcceptRated(); w:flush()
        eq(w.b.accepted, 1, "receiver accepted near the end of its window")
        w:advance(6.5)
        eq(w.b.duel:State(), "RATED_CONFIRMED", "the request deadline cannot abort an accepted request")
        w:advance(2)
        eq(w.b.duel:State(), "IDLE", "the start window settles it")
        w:advance(10)
        eq(w.a.duel:State(), "IDLE", "challenger released after its grace")
        w:unchanged()
    end)

    scenario("Blizzard accept without countdown is released", function(w)
        w:ready()
        w.b.duel:ObservedAccept()
        eq(w.b.duel:State(), "UNRATED", "unrated choice")
        w:advance(w.b.fd.C.START_TIMEOUT)
        eq(w.b.duel:State(), "IDLE", "no countdown: nothing left to observe")
        eq(printed(w.b, "If no duel started"), false, "no recovery hint: Blizzard's own popup handled the accept")
        w:unchanged()
    end)

    scenario("outgoing grace keeps the match, not the deadline", function(w)
        w:ready()
        w.a.duel:AcceptRated(); w:flush()
        w.delay = function() return false end
        local deadline = w.a.duel.active.deadline
        w:advance(50)
        eq(w.a.duel:State(), "LOCAL_ACCEPTED", "consenting challenger waits for a late native accept")
        eq(w.a.duel.active.deadline, deadline, "the shown request window is never extended")
        eq(w.a.duel:Pending(w.a.duel.active), false, "the native window is over")
        w:advance(w.a.fd.C.START_TIMEOUT)
        eq(w.a.duel:State(), "IDLE", "grace ends the request")
        eq(printed(w.a, "This duel will be UNRATED: The request expired."), true, "expiry explained")
        w:unchanged()
    end)

    scenario("tentative countdown announces RATED only after peer consent", function(w)
        w:ready()
        w.a.duel:AcceptRated(); w:flush()
        w.delay = function(packet, c) if c == w.b and packet.kind ~= "HELLO_ACK" then return 2 end return 0 end
        w.b.duel:AcceptRated(); w:flush()
        w.a.duel:Countdown(3); w.b.duel:Countdown(3); w:flush()
        eq(w.a.duel:State(), "COUNTDOWN", "challenger's countdown is tentatively rated")
        eq(printed(w.a, "Waiting for Beta-Forever to confirm the RATED duel."), true, "challenger told it is pending")
        eq(printed(w.a, "RATED duel vs"), false, "no RATED line before the peer's consent")
        eq(printed(w.b, "RATED duel vs Alpha-Forever (win +16 / loss -16)."), true, "receiver holds both consents")
        w:advance(2)
        eq(printed(w.a, "RATED duel vs Beta-Forever (win +16 / loss -16)."), true, "peer's ACCEPT confirms the rated line")
        local lines = #w.a.prints
        w:advance(4)
        eq(w.a.duel:State(), "IN_PROGRESS", "confirmed duel started")
        eq(#w.a.prints, lines, "the delayed STARTs do not repeat the line")
        w:finish("a"); w:advance(3)
        eq(#w.a.db.data.matches, 1, "confirmed tentative duel rates")
    end)

    scenario("tentative countdown corrected by the peer's unrated choice", function(w)
        w:ready()
        w.a.duel:AcceptRated(); w:flush()
        w.delay = function(packet) if packet.kind == "CANCEL" then return 0.3 end return 0 end
        w.b.duel:ObservedAccept()
        w.a.duel:Countdown(3); w.b.duel:Countdown(3)
        eq(printed(w.a, "Waiting for Beta-Forever to confirm the RATED duel."), true, "pending, not rated")
        eq(printed(w.a, "RATED duel vs"), false, "the challenger is never told it is rated")
        w:advance(0.3)
        eq(printed(w.a, "This duel is UNRATED: Your opponent chose an unrated duel."), true, "cancel explains it")
        eq(printed(w.a, "no longer rated"), false, "a duel never called rated is not \"no longer\" rated")
        w:advance(3); w:finish("a"); w:advance(40)
        w:unchanged()
    end)

    scenario("no cancel for timing after the native countdown", function(w)
        w:running("a")
        w.delay = function(packet) if packet.kind == "RESULT" then return false end return 0 end
        local cancels = w:count("CANCEL")
        w:finish("a")
        w:advance(w.a.fd.C.RESULT_TIMEOUT + 1)
        eq(w.a.duel:State(), "IDLE", "result timeout ends the match")
        eq(w:count("CANCEL"), cancels, "a result timeout sends no CANCEL")
        w:unchanged()
    end)

    scenario("mandatory consent that cannot be submitted unrates", function(w)
        w:ready()
        w.reject = function(packet) if packet.kind == "ACCEPT" then return "failed" end end
        w.a.duel:AcceptRated(); w:flush()
        eq(w.a.duel:State(), "UNRATED", "failed ACCEPT ends rated play")
        eq(w.a.duel.active.reason, "transport", "transport reason recorded")
        w:unchanged()
    end)

    scenario("redundant packet failures never unrate", function(w)
        w.reject = function(packet) if packet.kind == "HELLO" then return "failed" end end
        w:begin(); w:advance(5)
        eq(w.a.duel:State(), "CHECKING_ADDON", "failed discovery retries never unrate")
        w.reject = function(packet) if packet.kind == "HELLO_ACK" then return "expired" end end
        w:advance(20)
        eq(w.a.duel:State(), "CHECKING_ADDON", "expired acknowledgments never unrate")
        w.reject = nil
        w:advance(15)
        eq(w.a.duel:State(), "READY", "the next scheduled HELLO recovers discovery")
    end)

    scenario("send that cannot be queued degrades to an ordinary duel", function(w)
        w:ready()
        w.reject = function(packet) if packet.kind == "ACCEPT" then return "queue" end end
        w.b.duel:AcceptRated()
        eq(w.b.duel:State(), "UNRATED", "failed send cancels rating locally")
        w:flush()
        w:unchanged()
    end)

    scenario("missing START is proven by the peer RESULT", function(w)
        w:ready(); w:agree("a")
        w.delay = function(packet, c) if packet.kind == "START" and c == w.a then return false end return 0 end
        w:start()
        eq(w.b.duel.active.peerStart, nil, "receiver lost both START copies")
        w:finish("a")
        eq(#w.a.db.data.matches, 1, "challenger finalizes")
        eq(#w.b.db.data.matches, 1, "a bound RESULT implies the peer's start")
        eq(w:count("START", w.a), 2, "START is sent at the countdown and once more")
    end)

    scenario("late peer result is answered from the finalized cache", function(w)
        w:running("b")
        w.delay = function(packet, c)
            if packet.kind == "RESULT" and c == w.a and w.now < 12 then return false end
            return 0
        end
        w:finish("a")
        eq(#w.a.db.data.matches, 1, "challenger finalized with the receiver's result")
        eq(w.b.duel:State(), "FINISHING", "receiver still lacks the challenger's report")
        w:advance(25)
        eq(#w.b.db.data.matches, 1, "receiver's retry gets the cached answer")
        eq(w.b.db:GetStats().rating, 1484, "recovered loser rating")
        eq(#w.a.db.data.matches, 1, "cache answers never duplicate history")
    end)

    scenario("persistent one-way result loss documents local asymmetry", function(w)
        w:running("b")
        w.delay = function(packet, c) if packet.kind == "RESULT" and c == w.a then return false end return 0 end
        w:finish("a")
        w:advance(w.b.fd.C.RESULT_TIMEOUT + 1)
        -- No bounded peer protocol can guarantee an atomic two-client commit
        -- under permanent one-way loss. Each client needs its own evidence.
        eq(w.a.db:GetStats().rating, 1516, "client receiving the matching report finalizes")
        eq(w.b.db:GetStats().rating, 1500, "client missing the report does not infer a result")
        eq(#w.b.db.data.matches, 0, "missing report leaves no rated history")
        eq(w.b.duel:State(), "IDLE", "missing report times out after retries")
    end)

    scenario("cancelled match never retries old result", function(w)
        w:running("b")
        w.delay = function(packet) if packet.kind == "RESULT" then return false end return 0 end
        w:finish("a")
        eq(w:count("RESULT"), 2, "both initial independent reports attempted")
        w.a.duel:Abort("world", true)
        w.b.duel:Abort("world", true)
        w:advance(30)
        eq(w:count("RESULT"), 2, "aborted match suppresses result retries")
        w:unchanged()
    end)

    scenario("rematch during FINISHING parks the previous match", function(w)
        w:running("b")
        w.delay = function(packet, c) if packet.kind == "RESULT" and c == w.a then return 1 end return 0 end
        w:finish("a")
        eq(#w.a.db.data.matches, 1, "winner finalized")
        eq(w.b.duel:State(), "FINISHING", "loser awaits the delayed report")
        w.delay = nil
        w:begin()
        eq(w.b.duel.parked ~= nil, true, "previous match parked instead of discarded")
        eq(w.b.duel.active.held, true, "new request waits for the parked result")
        w:flush()
        eq(w.a.duel:State(), "CHECKING_ADDON", "receiver does not answer before its rating settles")
        w:advance(1)
        eq(#w.b.db.data.matches, 1, "parked match finalized from the late report")
        eq(w.b.duel.parked, nil, "reconcile slot released")
        w:advance(2)
        eq(w.b.duel:State(), "READY", "rematch discovery resumes")
        eq(w.b.duel.active.ratingBefore, 1484, "rematch announces the settled rating")
        eq(w.a.duel.active.opponentRatingBefore, 1484, "peer froze the settled rating")
        w:agree("a"); w:start(); w:finish("b")
        eq(#w.a.db.data.matches, 2, "both duels recorded by the challenger")
        eq(#w.b.db.data.matches, 2, "both duels recorded by the receiver")
        eq(w.a.db:GetStats().rating + w.b.db:GetStats().rating, 3000, "rematch conserves Elo")
    end)

    scenario("finalized result retries cannot contaminate rematch", function(w)
        w:running("b")
        w:finish("a")
        local oldWire = {}
        for _, message in ipairs(w.sent) do oldWire[#oldWire + 1] = message end
        w:ready()
        for _, message in ipairs(oldWire) do w:deliver(message) end
        w:flush()
        eq(w.a.duel:State(), "READY", "old report cannot finish or consent rematch")
        eq(w.b.duel:State(), "READY", "peer rejects replayed prior report")
        eq(#w.a.db.data.matches, 1, "no duplicate or premature winner history")
        eq(#w.b.db.data.matches, 1, "no duplicate or premature loser history")
    end)

    scenario("result reports without local finish never commit", function(w)
        w:running("b")
        w.a.duel:Result(w.a.identity.guid, "local")
        w.b.duel:Result(w.a.identity.guid, "local")
        w:inject(w.a, w.b, "RESULT")
        w:inject(w.b, w.a, "RESULT", { verdict = w.a.identity.guid })
        w:advance(w.a.fd.C.RESULT_TIMEOUT)
        w:unchanged()
    end)

    scenario("finish without independent local results never commits", function(w)
        w:running("b")
        w.a.duel:Finished()
        w.b.duel:Finished()
        w:inject(w.a, w.b, "RESULT")
        w:inject(w.b, w.a, "RESULT", { verdict = w.a.identity.guid })
        w:advance(w.a.fd.C.RESULT_TIMEOUT)
        w:unchanged()
    end)

    scenario("disagreeing result reports cancel both", function(w)
        w:running("b")
        w.a.duel:Result(w.a.identity.guid, "local")
        w.a.duel:Finished()
        w.b.duel:Result(w.b.identity.guid, "local")
        w.b.duel:Finished()
        w:flush()
        eq(printed(w.a, "This duel is no longer rated: The clients disagree on the winner."), true, "disagreement explained")
        eq(w.a.duel:State(), "IDLE", "an unrate after the native end releases the match")
        eq(w.b.duel:State(), "IDLE", "the peer is released as well")
        w:unchanged()
    end)

    scenario("conflicting peer results before local observation", function(w)
        w:running("b")
        w:inject(w.a, w.b, "RESULT")
        w:inject(w.a, w.b, "RESULT", { verdict = w.b.identity.guid })
        w:flush()
        w:finish("a")
        w:unchanged()
    end)

    scenario("conflicting independent local observations", function(w)
        w:running("b")
        w.a.duel:Result(w.a.identity.guid, "first")
        w.a.duel:Result(w.b.identity.guid, "contradiction")
        w:flush()
        w:finish("a")
        w:unchanged()
    end)

    for _, reason in ipairs({ "world", "cancelled", "replaced" }) do
        scenario(reason .. " aborts active match", function(w)
            w:running("b")
            w.a.duel:Abort(reason, true)
            w:flush()
            w:finish("a")
            w:advance(w.a.fd.C.RESULT_TIMEOUT)
            w:unchanged()
        end)
    end

    scenario("logout cancel is submitted immediately", function(w)
        w:running("b")
        w.a.duel:Abort("world", true, true)
        local cancel = w.sent[#w.sent]
        eq(cancel.kind, "CANCEL", "cancel already submitted")
        eq(cancel.immediate, true, "submitted synchronously")
        eq(cancel.packet.reason, "world", "reason travels")
        w:flush()
        eq(printed(w.b, "This duel is no longer rated: Your opponent logged out or changed zones."), true, "peer told")
    end)

    scenario("reload keeps committed history without resuming match", function(w)
        w:running("b")
        w:finish("b")
        local stored = w.a.fd.Database:Copy(w.a.db.data)
        local fd = newNamespace()
        eq(fd.Database:Initialize(stored, w.a.identity), stored, "reloaded database accepted")
        local newDuel = fd.Duel:New(w.a.duel.env, fd.Database)
        eq(newDuel:State(), "IDLE", "no transient negotiation restored")
        eq(fd.Database:GetStats().rating, 1484, "reloaded rating")
        eq(#fd.History:Recent(), 1, "reloaded match history")
    end)

    scenario("two requests discard prior timers and consent", function(w)
        w:ready()
        local nonce = w.a.duel.active.nonce
        w.b.duel:AcceptRated()
        w:begin()
        w:flush()
        eq(w.a.duel.active.nonce ~= nonce, true, "new request uses new nonce")
        eq(w.a.duel:State(), "READY", "old queued acceptance ignored")
        eq(w.b.duel:State(), "READY", "old queued cancellation ignored")
        w:agree("b")
        w:start()
        w:advance(15)
        w:finish("a")
        eq(#w.a.db.data.matches, 1, "only second request recorded")
    end)

    scenario("illegal transitions and premature endings", function(w)
        eq(w.a.duel:Transition("FINISHED"), false, "no transition without active duel")
        w:ready()
        eq(w.a.duel:Transition("IN_PROGRESS"), false, "cannot skip consent/start")
        w.a.duel:Finished()
        w:flush()
        w:unchanged()
    end)

    scenario("invalid countdown cannot start confirmed match", function(w)
        w:ready()
        w:agree("b")
        w.a.duel:Countdown(0)
        w.b.duel:Countdown("3")
        eq(w.a.duel:State(), "RATED_CONFIRMED", "zero countdown ignored")
        eq(w.b.duel:State(), "RATED_CONFIRMED", "string countdown ignored")
        w:advance(60)
        w:unchanged()
    end)

    scenario("countdown before agreement is announced only to engaged players", function(w)
        w:ready()
        w.a.duel:Countdown(3)
        eq(w.a.duel:State(), "UNRATED_ACTIVE", "no consent means unrated")
        eq(printed(w.a, "This duel is UNRATED: The duel started before both players agreed to a rated duel."), true,
            "proven peer gets an explicit outcome")
        w:unchanged()
    end)

    scenario("opponent that cannot be resolved is not a change", function(w)
        w:ready()
        w.a.observed, w.b.observed = nil, nil
        w:agree("a")
        w:start()
        eq(w.a.duel:State(), "IN_PROGRESS", "target cleared, stealth or nameplates off do not unrate")
        w:finish("a")
        eq(#w.a.db.data.matches, 1, "unresolvable opponent still rates")
    end)

    scenario("self target during the countdown is not a change", function(w)
        w:ready(); w:agree("b")
        w.a.duel:Countdown(3); w.b.duel:Countdown(3); w:flush()
        -- The opponent's GUID resolves to no unit while the player targets themselves.
        w.a.observed = nil
        w:advance(3)
        eq(w.a.duel:State(), "IN_PROGRESS", "self target keeps the rated start")
    end)

    scenario("positively observed opponent level change unrates", function(w)
        w:ready()
        w.b.observed = { guid = w.a.identity.guid, level = 31, maxLevel = 60 }
        w.b.duel:AcceptRated()
        eq(w.b.duel:State(), "UNRATED", "observed level mismatch fails")
        eq(w.b.duel.active.reason, "level", "distinct level reason")
        w:flush()
        eq(w.a.duel.active.reason, "peer:level", "peer receives the level reason")
    end)

    scenario("positively observed different player unrates", function(w)
        w:ready()
        w.b.observed = { guid = "Player-1-CCC", level = 30, maxLevel = 60 }
        w.b.duel:AcceptRated()
        eq(w.b.duel.active.reason, "lost", "same name with another GUID is an identity loss")
    end)

    scenario("combat blocks the rated click without unrating", function(w)
        w:ready()
        w.a.combat = true
        eq(w.a.duel:AcceptRated(), false, "rated consent unavailable in combat")
        eq(w.a.duel:State(), "READY", "request stays negotiable")
        w.a.combat = false
        eq(w.a.duel:AcceptRated(), true, "consent available after combat")
    end)

    scenario("outdated FD2 peer is detected once", function(w)
        w:begin()
        local fd2 = assert(w.a.fd.Protocol:Encode(w.a.duel:Packet(w.a.duel.active, "HELLO"))):gsub("^FD3", "FD2", 1)
        local accepted, status = w.b.duel:Receive(fd2, "Other-Forever")
        eq(accepted, false, "FD2 from a stranger is only an invalid envelope")
        eq(w.b.duel.active.peerOutdated, nil, "stranger cannot mark the opponent outdated")
        accepted, status = w.b.duel:Receive(fd2, w.a.identity.fullName)
        eq(status:find("protocol 2", 1, true) ~= nil, true, "outdated peer diagnosed")
        eq(w.b.duel.active.peerOutdated, true, "match marked outdated")
        eq(w.b.duel:State(), "UNRATED", "outdated peer cannot rate")
        eq(#w.b.prints, 1, "one explanation")
        eq(w.b.prints[1], "Your opponent uses an older ForeverDuel version. Rated duels need version 0.6 or newer on both sides.",
            "exact outdated text")
        eq(logged(w.b, "version mismatch"), true, "version mismatch persisted")
        w.b.duel:Receive(fd2, w.a.identity.fullName)
        eq(#w.b.prints, 1, "shown once per request")
        w.b.duel:ObservedAccept(); w.b.duel:Countdown(3)
        eq(printed(w.b, "This duel is UNRATED: Your opponent uses an older ForeverDuel version."), true, "countdown outcome")
    end)

    scenario("unrelated sender and wrong identity ignored", function(w)
        w:ready()
        w:inject(w.a, w.b, "ACCEPT", nil, "Stranger-Forever")
        w:inject(w.a, w.b, "ACCEPT", { guid = "Player-1-CCC" })
        w:inject(w.a, w.b, "ACCEPT", { peerGUID = "Player-1-CCC" })
        w:inject(w.a, w.b, "ACCEPT", { role = "INCOMING" })
        w:inject(w.a, w.b, "ACCEPT", { echo = "bad" })
        w:inject(w.a, w.b, "ACCEPT", { nonce = "bad" })
        w.b.duel:Receive("malformed", w.a.identity.fullName)
        eq(w.b.duel:State(), "READY", "invalid sender/identity cannot imply consent")
        w:unchanged()
    end)

    scenario("changed peer rating or spec cannot imply consent", function(w)
        w:ready()
        w:inject(w.a, w.b, "ACCEPT", { rating = 1600 })
        eq(w.b.duel:State(), "UNRATED", "peer snapshot is immutable")
        w:unchanged()
    end)

    scenario("local spec changes before consent", function(w)
        w:ready()
        w.b.identity.specId = 259
        w.b.duel:AcceptRated()
        w:flush()
        eq(w.b.duel:State(), "UNRATED", "spec change cancels rating")
        eq(w.b.duel.active.reason, "spec", "distinct specialization reason")
        w:unchanged()
    end)

    scenario("local rating changes before consent", function(w)
        w:ready()
        w.b.db:GetStats().rating = 1520
        w.b.duel:AcceptRated()
        w:flush()
        eq(w.b.duel:State(), "UNRATED", "rating change cancels negotiation")
        eq(w.b.duel.active.reason, "rating", "distinct rating reason")
        eq(#w.b.db.data.matches, 0, "stale snapshot does not commit")
        eq(w.b.db:GetStats().rating, 1520, "cancellation does not overwrite changed rating")
    end)

    scenario("spec changes after confirmation before countdown", function(w)
        w:ready()
        w:agree("b")
        w.b.identity.specId = 259
        w.a.duel:Countdown(3)
        w.b.duel:Countdown(3)
        w:flush()
        w:advance(3)
        w:finish("a")
        w:unchanged()
    end)

    for _, levels in ipairs({ {30, 36}, {36, 30}, {59, 60}, {60, 59}, {0, 30}, {-1, 30} }) do
        scenario("ineligible levels " .. levels[1] .. "/" .. levels[2], function(w)
            w.a.identity.level, w.b.identity.level = levels[1], levels[2]
            w.b.known = true
            w:begin()
            w:flush()
            eq(w.a.duel:State(), "UNRATED", "challenger blocks rated discovery")
            eq(w.b.duel:State(), "UNRATED", "receiver blocks rated discovery")
            eq(#w.sent, 0, "ineligible duel sends no consent or discovery")
            eq(#w.a.prints, 0, "unknown opponent gets no explanation")
            eq(#w.b.prints, 1, "known addon user learns why once")
            eq(w.b.prints[1]:find("Rated unavailable", 1, true) ~= nil, true, "reason explained")
            w.a.duel:AcceptRated(); w.b.duel:AcceptRated()
            eq(w.b.accepted, 0, "rated click cannot accept ineligible match")
            w:unchanged()
        end)
    end

    for _, winner in ipairs({ "a", "b" }) do
        scenario("five-level boundary winner " .. winner, function(w)
            w.a.identity.level, w.b.identity.level = 30, 35
            w:running("a")
            w:advance(12)
            w:finish(winner)
            local gain = winner == "a" and 20 or 12
            local record = (winner == "a" and w.a or w.b).db.data.matches[1]
            eq(record.ratingDelta, gain, "level-adjusted winner transfer")
            eq(w.a.db:GetStats().rating + w.b.db:GetStats().rating, 3000, "weighted Elo conserves points")
            eq(record.bracket, "LEVELING", "records leveling pool")
            eq(w.a.db:GetStats("MAX_LEVEL").rating, 1500, "leveling never changes max-level pool")
            eq(w.a.db.data.matches[1].opponent.level, 35, "opponent native level retained")
        end)
    end

    scenario("max-level matches use their own rating", function(w)
        w:running("a"); w:advance(12); w:finish("a")
        w.a.identity.level, w.b.identity.level = 60, 60
        w:running("b"); w:advance(12); w:finish("b")
        eq(w.a.db:GetStats("LEVELING").rating, 1516, "leveling rating preserved after cap")
        eq(w.a.db:GetStats("MAX_LEVEL").rating, 1484, "max-level starts independent")
        eq(w.b.db:GetStats("MAX_LEVEL").rating, 1516, "other client max-level transfer")
        eq(w.a.db.data.matches[2].bracket, "MAX_LEVEL", "max-level record tagged")
    end)

    scenario("peer cannot claim a different level", function(w)
        w:begin()
        w.timers = {}
        w:inject(w.b, w.a, "HELLO", { level = 31 })
        eq(w.a.duel:State(), "CHECKING_ADDON", "unproven incompatible hello cannot cancel current request")
        eq(w.a.duel.active.peerNonce, nil, "wire level cannot establish native identity")
        w:inject(w.b, w.a, "HELLO_ACK", { level = 31, echo = w.a.duel.active.nonce })
        eq(w.a.duel:State(), "UNRATED", "current request proof still must match native level")
        w:unchanged()
    end)

    scenario("unproven incompatible hellos cannot poison current discovery", function(w)
        w:begin()
        local queued = #w.b.items
        for _, changes in ipairs({ { level = 31 }, { maxLevel = 70 }, { classFile = "WARRIOR" } }) do
            w:inject(w.a, w.b, "HELLO", changes)
            eq(w.b.duel:State(), "CHECKING_ADDON", "incompatible unproven profile leaves request pending")
            eq(w.b.duel.active.peerNonce, nil, "incompatible unproven profile does not bind peer")
        end
        eq(#w.b.items, queued, "incompatible unproven profile gets no acknowledgement")
        w:flush()
        eq(w.a.duel:State(), "READY", "valid challenger proof still succeeds")
        eq(w.b.duel:State(), "READY", "valid receiver proof still succeeds")
        w:inject(w.a, w.b, "HELLO", { rating = 1501 })
        eq(w.b.duel:State(), "UNRATED", "proven nonce cannot change its frozen profile")
        w:unchanged()
    end)

    scenario("different caps block rated", function(w)
        w.b.identity.maxLevel = 70
        w:begin(); w:flush()
        eq(w.a.duel:State(), "UNRATED", "cap disagreement blocked")
        w:unchanged()
    end)

    scenario("level changes before consent", function(w)
        w:ready()
        w.a.identity.level = 31
        w.a.duel:AcceptRated(); w:flush()
        eq(w.a.duel:State(), "UNRATED", "local level change invalidates snapshot")
        eq(w.b.duel.active.reason, "peer:level", "peer told a level changed")
        w:unchanged()
    end)

    scenario("level changes during countdown", function(w)
        w:ready(); w:agree("a")
        w.a.duel:Countdown(3); w.b.duel:Countdown(3); w:flush()
        w.a.identity.level = 31
        w:advance(3)
        eq(w.a.duel:State(), "UNRATED", "level change at start invalidates rating")
        eq(printed(w.a, "This duel is no longer rated: A level changed."), true, "explained after the countdown")
        w:unchanged()
    end)

    scenario("level changes during combat", function(w)
        w:running("b")
        w.a.identity.level = 31
        w:finish("a")
        eq(#w.a.db.data.matches, 0, "changed participant cannot commit")
        eq(#w.b.db.data.matches, 0, "changed participant cannot send a rating result")
    end)
end
