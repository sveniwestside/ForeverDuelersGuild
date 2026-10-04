return function(_, equal, newNamespace)
    local scenarioName
    local function eq(actual, expected, label)
        equal(actual, expected, scenarioName .. ": " .. label)
    end

    local function world()
        local w = { now = 0, queue = {}, timers = {}, clients = {}, sent = {} }
        local identities = {
            { guid = "Player-1-AAA", name = "Alpha", realm = "Forever", fullName = "Alpha-Forever", classFile = "MAGE", specId = 64, level = 30, maxLevel = 60 },
            { guid = "Player-1-BBB", name = "Beta", realm = "Forever", fullName = "Beta-Forever", classFile = "ROGUE", specId = 261, level = 30, maxLevel = 60 },
        }
        for index, identity in ipairs(identities) do
            local fd = newNamespace()
            local c = { fd = fd, identity = fd.Copy(identity), accepted = 0, declined = 0, restored = 0, renders = {}, logs = {}, prints = {} }
            w.clients[index] = c
            fd.Database:Initialize(nil, c.identity)
            c.db = fd.Database
            local env = {
                now = function() return w.now end,
                epoch = function() return 1700000000 + math.floor(w.now) end,
                random = function() return index * 1337 end,
                identity = function() return c.identity end,
                after = function(seconds, callback)
                    w.timers[#w.timers + 1] = { at = w.now + seconds, callback = callback }
                end,
                send = function(payload, target)
                    local packet = assert(fd.Protocol:Decode(payload))
                    if w.fail and w.fail(packet, c) then return false end
                    local message = { payload = payload, from = c.identity.fullName, to = target, kind = packet.kind }
                    w.sent[#w.sent + 1] = fd.Copy(message)
                    if not w.drop or not w.drop(packet, c) then w.queue[#w.queue + 1] = message end
                    return true
                end,
                render = function(m) c.renders[#c.renders + 1] = m.state end,
                hide = function() end,
                restore = function() c.restored = c.restored + 1 end,
                accept = function() c.accepted = c.accepted + 1; return not c.failAccept end,
                decline = function() c.declined = c.declined + 1; return not c.failDecline end,
                log = function(...) c.logs[#c.logs + 1] = { ... } end,
                print = function(text) c.prints[#c.prints + 1] = text end,
            }
            c.duel = fd.Duel:New(env, c.db)
        end
        w.a, w.b = w.clients[1], w.clients[2]
        function w:deliver(index)
            local message = table.remove(self.queue, index or 1)
            if not message then return end
            for _, c in ipairs(self.clients) do
                if c.identity.fullName == message.to then c.duel:Receive(message.payload, message.from) end
            end
            return message
        end
        function w:flush()
            local count = 0
            while #self.queue > 0 do
                count = count + 1
                assert(count < 500, "wire did not settle")
                self:deliver()
            end
        end
        function w:advance(seconds, flush)
            local target = self.now + seconds
            while true do
                local nextIndex, nextAt
                for index, timer in ipairs(self.timers) do
                    if timer.at <= target and (not nextAt or timer.at < nextAt) then
                        nextIndex, nextAt = index, timer.at
                    end
                end
                if not nextIndex then break end
                self.now = nextAt
                table.remove(self.timers, nextIndex).callback()
                if flush ~= false then self:flush() end
            end
            self.now = target
            if flush ~= false then self:flush() end
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
            local packet = from.duel:Packet(kind, kind == "RESULT" and from.identity.guid or nil)
            for key, value in pairs(changes or {}) do packet[key] = value end
            to.duel:Receive(assert(from.fd.Protocol:Encode(packet)), sender or from.identity.fullName)
        end
        return w
    end

    local function scenario(name, test)
        scenarioName = name
        test(world())
    end

    for _, proposer in ipairs({ "a", "b" }) do
        scenario("full rated match proposed by " .. proposer, function(w)
            w:running(proposer)
            local matchId = w.a.duel.active.matchId
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
            eq(w.a.db.data.matches[1].winnerGUID, w.b.db.data.matches[1].winnerGUID, "complementary winner evidence")
            eq(w.a.db.data.matches[1].result, "WIN", "winner result")
            eq(w.b.db.data.matches[1].result, "LOSS", "loser result")
            w.a.duel:Finished()
            w.b.duel:Finished()
            w.a.duel:Result(w.a.identity.guid, "duplicate")
            w.a.duel:FinalizeMatch()
            for _, message in ipairs(w.sent) do
                if message.kind == "RESULT" then
                    w.a.duel:Receive(message.payload, message.from)
                    w.b.duel:Receive(message.payload, message.from)
                end
            end
            w:advance(60)
            eq(#w.a.db.data.matches, 1, "winner duplicate ending ignored")
            eq(#w.b.db.data.matches, 1, "loser duplicate ending ignored")
            eq(w.a.db:GetStats().rating + w.b.db:GetStats().rating, 3000, "rating conserved")
        end)
    end

    scenario("no opponent addon and ordinary acceptance", function(w)
        w.b.duel:Begin("INCOMING", w.b.identity, w.a.identity)
        w:flush()
        w:advance(w.b.fd.C.PRESENCE_TIMEOUT)
        eq(w.b.duel:State(), "DISCOVERY_WAIT", "presence timeout keeps pending discovery available")
        w.b.duel:ContinueUnrated()
        eq(w.b.accepted, 1, "normal duel immediately available")
        w.b.duel:Countdown(3)
        w.b.duel:Finished()
        w:unchanged()
    end)

    scenario("unrated available before presence resolves", function(w)
        w:begin()
        w.b.duel:ContinueUnrated()
        eq(w.b.accepted, 1, "normal acceptance never waits")
        w:flush()
        w.a.duel:Countdown(3)
        w.b.duel:Countdown(3)
        w:advance(3)
        w:finish("b")
        w:unchanged()
    end)

    scenario("decline clears both negotiations", function(w)
        w:ready()
        w.b.duel:Decline()
        w:flush()
        eq(w.b.duel:State(), "IDLE", "decliner idle")
        eq(w.b.declined, 1, "native decline called")
        eq(w.a.duel:State(), "UNRATED", "peer proposal cancelled")
        w:unchanged()
    end)

    scenario("failed native decline restores ordinary request", function(w)
        w:ready()
        w.b.failDecline = true
        w.b.duel:Decline()
        w:flush()
        eq(w.b.declined, 1, "native decline attempted once")
        eq(w.b.restored, 1, "failed decline restores original request")
        eq(w.b.duel:State(), "IDLE", "failed decline clears local rated negotiation")
        eq(w.a.duel:State(), "UNRATED", "peer consent also cancelled")
        w:unchanged()
    end)

    scenario("rated refusal and timeout", function(w)
        w:ready()
        w.b.duel:AcceptRated()
        w:flush()
        w.a.duel:ContinueUnrated()
        w:flush()
        eq(w.b.duel:State(), "UNRATED", "receiver sees refusal")
        w.b.duel:ContinueUnrated()
        eq(w.b.accepted, 1, "unrated remains acceptable")
        w:advance(60)
        w:unchanged()
    end)

    scenario("negotiation expires without consent", function(w)
        w:ready()
        w.b.duel:AcceptRated()
        w:flush()
        w:advance(w.a.fd.C.NEGOTIATION_TIMEOUT)
        eq(w.a.duel:State(), "UNRATED", "nonconsenting client timed out")
        eq(w.b.duel:State(), "UNRATED", "proposer timed out")
        eq(w.b.accepted, 0, "timeout never accepts duel")
        w:unchanged()
    end)

    scenario("previous match hello cannot pin the rematch peer", function(w)
        w:ready()
        local stale
        for _, message in ipairs(w.sent) do
            if message.kind == "HELLO" and message.from == w.a.identity.fullName then
                stale = w.a.fd.Copy(message)
                break
            end
        end
        w:agree("b"); w:start(); w:finish("a")
        w:begin()
        w.b.duel:Receive(stale.payload, stale.from)
        eq(w.b.duel.active.peerNonce, nil, "unbound old hello cannot claim current peer nonce")
        eq(w.b.duel.active.peer, nil, "unbound old hello cannot freeze previous rating")
        eq(w.b.duel.active.matchId, nil, "unbound old hello cannot create rematch identity")
        w:flush()
        eq(w.a.duel:State(), "READY", "challenger discovers current request")
        eq(w.b.duel:State(), "READY", "receiver discovers current request")
        eq(w.b.duel.active.peerNonce, w.a.duel.active.nonce, "fresh echoed nonce binds peer")
        eq(w.b.duel.active.opponentRatingBefore, 1516, "rematch uses current peer rating")
        w.b.duel:Receive(stale.payload, stale.from)
        eq(w.b.duel:State(), "READY", "old hello cannot disturb proven peer")
        w:agree("a"); w:start(); w:finish("b")
        eq(#w.a.db.data.matches, 2, "challenger records both rated duels")
        eq(#w.b.db.data.matches, 2, "receiver records both rated duels")
    end)

    scenario("discovery retries recover one-way loss beyond the initial attempts", function(w)
        w.drop = function(packet, client)
            return w.now < 5 and packet.kind == "HELLO_ACK" and client == w.b
        end
        w:begin(); w:flush(); w:advance(4)
        eq(w.a.duel:State(), "DISCOVERY_WAIT", "challenger safely waits after transient loss")
        eq(w.b.duel:State(), "READY", "receiver already has nonce proof")
        eq(w.b.accepted, 0, "asymmetric readiness never accepts native duel")
        w:advance(3)
        eq(w.a.duel:State(), "READY", "challenger retries after transport recovers")
        eq(w.b.duel:State(), "READY", "receiver reacknowledges current request")
        eq(w.a.duel.active.matchId, w.b.duel.active.matchId, "recovered discovery agrees on match")
        w:agree("a"); w:start(); w:finish("b")
        eq(#w.a.db.data.matches, 1, "recovered challenger completes rated duel")
        eq(#w.b.db.data.matches, 1, "recovered receiver completes rated duel")
    end)

    for _, earlySide in ipairs({ "a", "b" }) do
        scenario("early explicit consent survives peer discovery delay from " .. earlySide, function(w)
            local early = w[earlySide]
            local waiting = earlySide == "a" and w.b or w.a
            w.drop = function(packet, client)
                return w.now < 5 and packet.kind == "HELLO_ACK" and client == early
            end
            w:begin(); w:flush()
            eq(early.duel:State(), "READY", "one client may confirm presence first")
            eq(waiting.duel:State(), "CHECKING_ADDON", "other client has no nonce proof yet")
            early.duel:AcceptRated(); w:flush()
            eq(early.duel:State(), "LOCAL_ACCEPTED", "explicit consent waits for counterpart")
            eq(waiting.duel:State(), "CHECKING_ADDON", "early consent cannot bypass discovery")
            w:advance(5)
            eq(waiting.duel:State(), "REMOTE_ACCEPTED", "recovery repeats already granted consent after nonce proof")
            eq(w.b.accepted, 0, "repeated proposal never supplies counterpart consent")
            waiting.duel:AcceptRated(); w:flush()
            eq(w.a.duel:State(), "RATED_CONFIRMED", "challenger confirms without another proposer click")
            eq(w.b.duel:State(), "RATED_CONFIRMED", "receiver confirms without another proposer click")
            eq(w.b.accepted, 1, "duplicate consent accepts native duel once")
            w:start(); w:finish("a")
            eq(#w.a.db.data.matches, 1, "challenger completes recovered proposal")
            eq(#w.b.db.data.matches, 1, "receiver completes recovered proposal")
        end)
    end

    scenario("discovery retry traffic stops at the original pending deadline", function(w)
        w.a.duel:Begin("OUTGOING", w.a.identity, w.b.identity)
        w:flush(); w:advance(49.9)
        eq(w.a.duel:State(), "DISCOVERY_WAIT", "request remains discoverable before deadline")
        eq(#w.sent > 2, true, "missing peer gets paced discovery attempts")
        eq(#w.sent <= 30, true, "retry traffic remains bounded over entire pending request")
        w:advance(0.1)
        eq(w.a.duel:State(), "IDLE", "retries cannot extend pending request lifetime")
        local before = #w.sent
        w:advance(60)
        eq(#w.sent, before, "expired request sends no more discovery")
        w:unchanged()
    end)

    scenario("late identity recovery retains the original discovery deadline", function(w)
        w.b.duel:Begin("INCOMING", w.b.identity, w.a.identity, -47)
        w:advance(3)
        eq(w.b.duel:State(), "IDLE", "late recovery expires at native request deadline")
        local before = #w.sent
        w:advance(10)
        eq(#w.sent, before, "late request cannot restart the pending window")
        eq(w.b.restored, 1, "expired incoming request restores normal native actions")
        w:unchanged()
    end)

    for _, terminal in ipairs({ "unrated", "declined", "countdown", "aborted" }) do
        scenario("discovery retries stop after " .. terminal, function(w)
            w.a.duel:Begin("OUTGOING", w.a.identity, w.b.identity)
            w:advance(4)
            if terminal == "unrated" then w.a.duel:ContinueUnrated()
            elseif terminal == "declined" then w.a.duel:Decline()
            elseif terminal == "countdown" then w.a.duel:Countdown(3)
            else w.a.duel:Abort("native cancellation", true) end
            w:flush()
            local before = #w.sent
            w:advance(20)
            eq(#w.sent, before, "terminal request sends no further discovery")
            w:unchanged()
        end)
    end

    scenario("ready discovery stops retrying without acknowledgement loops", function(w)
        w:ready()
        local before = #w.sent
        w:advance(10)
        eq(#w.sent, before, "ready pair generates no periodic handshake traffic")
        eq(w.a.duel:State(), "READY", "timer cannot grant outgoing consent")
        eq(w.b.duel:State(), "READY", "timer cannot grant incoming consent")
        w:unchanged()
    end)

    for _, legacySide in ipairs({ "a", "b" }) do
        scenario("discovery interoperates with legacy hello binding on " .. legacySide, function(w)
            local old = w[legacySide]
            local receive = old.duel.Receive
            old.duel.Receive = function(self, payload, sender)
                local p = assert(old.fd.Protocol:Decode(payload))
                -- Model the prior discovery behavior: a compatible HELLO pins
                -- peer metadata before the current request's nonce is echoed.
                if p.kind == "HELLO" and self.active and not self.active.peerNonce then
                    local m = self.active
                    m.peerNonce, m.peer = p.nonce, old.fd.Copy(p)
                    m.opponentRatingBefore = p.rating
                    m.matchId = old.fd.Protocol:MatchID(m.player.guid, m.nonce, m.opponent.guid, p.nonce)
                end
                return receive(self, payload, sender)
            end
            w:running("a"); w:finish("b")
            eq(#w.a.db.data.matches, 1, "challenger completes with existing wire protocol")
            eq(#w.b.db.data.matches, 1, "receiver completes with existing wire protocol")
        end)
    end

    scenario("presence retries after dropped initial hellos", function(w)
        w:begin()
        w.queue = {}
        w:advance(1)
        eq(w.a.duel:State(), "READY", "outgoing retry recovers")
        eq(w.b.duel:State(), "READY", "incoming retry recovers")
        w:agree("b")
        w:start()
        w:finish("b")
        eq(w.b.db:GetStats().rating, 1516, "retry match completes")
    end)

    scenario("late outgoing detection recovers after incoming hellos expired", function(w)
        w.b.duel:Begin("INCOMING", w.b.identity, w.a.identity)
        w:flush()
        w:advance(1.5)
        eq(w.a.duel:State(), "IDLE", "outgoing client has no confirmed request yet")
        eq(w.b.duel:State(), "CHECKING_ADDON", "incoming client already sent both discovery attempts")
        w.a.duel:Begin("OUTGOING", w.a.identity, w.b.identity)
        w:flush()
        eq(w.a.duel:State(), "READY", "late outgoing client learns peer presence")
        eq(w.b.duel:State(), "READY", "incoming client receives reciprocal nonce acknowledgement")
        eq(w.a.duel.active.matchId, w.b.duel.active.matchId, "late detection agrees on match identity")
        eq(w.b.accepted, 0, "discovery alone does not accept native duel")
        w:unchanged()
        w:agree("b")
        w:start()
        w:finish("a")
        eq(#w.a.db.data.matches, 1, "delayed detection supports normal rated completion")
        eq(#w.b.db.data.matches, 1, "peer completes same delayed-detection match")
    end)

    scenario("delayed discovery after soft timeout still requires explicit consent", function(w)
        w:begin()
        w:advance(w.a.fd.C.PRESENCE_TIMEOUT + 1, false)
        eq(w.a.duel:State(), "DISCOVERY_WAIT", "outgoing discovery waits for delayed traffic")
        eq(w.b.duel:State(), "DISCOVERY_WAIT", "incoming discovery waits for delayed traffic")
        for _, message in ipairs(w.sent) do
            eq(message.kind ~= "CANCEL", true, "soft timeout never sends cancellation")
        end
        w.a.duel:AcceptRated()
        w.b.duel:AcceptRated()
        eq(w.a.duel:State(), "DISCOVERY_WAIT", "cannot consent before compatible discovery")
        eq(w.b.accepted, 0, "soft timeout never accepts native duel")
        w:flush()
        eq(w.a.duel:State(), "READY", "delayed outgoing discovery completes")
        eq(w.b.duel:State(), "READY", "delayed incoming discovery completes")
        eq(w.a.duel.active.matchId, w.b.duel.active.matchId, "late discovery preserves shared identity")
        eq(w.b.accepted, 0, "late discovery does not imply consent")
        w:unchanged()
        w:agree("b")
        w:start()
        w:finish("a")
        eq(#w.a.db.data.matches, 1, "explicit consent after late discovery completes match")
        eq(#w.b.db.data.matches, 1, "late discovery completes complementary match")
    end)

    scenario("ordinary acceptance after soft timeout cannot revive discovery", function(w)
        w:begin()
        w:advance(w.b.fd.C.PRESENCE_TIMEOUT + 1, false)
        w.b.duel:ContinueUnrated()
        eq(w.b.duel:State(), "UNRATED", "normal choice permanently clears rated eligibility")
        eq(w.b.accepted, 1, "normal acceptance is immediately usable after soft timeout")
        w:flush()
        eq(w.b.duel:State(), "UNRATED", "late valid discovery cannot reverse normal choice")
        w.b.duel:AcceptRated()
        eq(w.b.accepted, 1, "rated click cannot accept native duel twice")
        w.b.duel:Countdown(3)
        w:flush()
        eq(w.b.duel:State(), "UNRATED_ACTIVE", "started ordinary duel stays unrated")
        w.b.duel:Finished()
        w:unchanged()
    end)

    for _, ending in ipairs({ "declined", "cancelled", "started" }) do
        scenario("late discovery cannot revive " .. ending .. " pending request", function(w)
            w:begin()
            w:advance(w.b.fd.C.PRESENCE_TIMEOUT + 1, false)
            if ending == "declined" then w.b.duel:Decline()
            elseif ending == "cancelled" then w.b.duel:Abort("native cancellation", true)
            else w.b.duel:Countdown(3) end
            local expected = ending == "started" and "UNRATED_ACTIVE" or "IDLE"
            w:flush()
            eq(w.b.duel:State(), expected, "late packets cannot revive terminated discovery")
            w:unchanged()
        end)
    end

    scenario("pending hard expiry discards soft-wait discovery", function(w)
        w:begin()
        w:advance(w.a.fd.C.PENDING_TIMEOUT + 1, false)
        eq(w.a.duel:State(), "IDLE", "outgoing hard expiry clears discovery")
        eq(w.b.duel:State(), "IDLE", "incoming hard expiry clears discovery")
        eq(w.b.restored, 1, "incoming hard expiry restores normal request when possible")
        w:flush()
        eq(w.a.duel:State(), "IDLE", "old discovery cannot revive expired outgoing request")
        eq(w.b.duel:State(), "IDLE", "old discovery cannot revive expired incoming request")
        w:unchanged()
    end)

    scenario("late discovery retains strict identity and nonce checks", function(w)
        w:begin()
        w:advance(w.a.fd.C.PRESENCE_TIMEOUT + 1, false)
        w.queue = {}
        w:inject(w.a, w.b, "HELLO", nil, "Stranger-Forever")
        w:inject(w.a, w.b, "HELLO", { guid = "Player-1-CCC" })
        w:inject(w.a, w.b, "HELLO", { peerGUID = "Player-1-CCC" })
        w:inject(w.a, w.b, "HELLO", { role = "INCOMING" })
        w:inject(w.a, w.b, "HELLO_ACK", { echo = "bad" })
        eq(w.b.duel:State(), "DISCOVERY_WAIT", "invalid late peers cannot finish discovery")
        eq(w.b.duel.active.peerNonce, nil, "invalid packets cannot establish a peer nonce")
        eq(w.b.accepted, 0, "invalid packets cannot accept native request")
        w:unchanged()
    end)

    scenario("late discovery cannot bypass hard deadline before timer callback", function(w)
        w:begin()
        w:advance(w.a.fd.C.PRESENCE_TIMEOUT + 1, false)
        w.now = w.a.fd.C.PENDING_TIMEOUT
        w:flush()
        eq(w.a.duel:State(), "DISCOVERY_WAIT", "expired outgoing cannot become ready")
        eq(w.b.duel:State(), "DISCOVERY_WAIT", "expired incoming cannot become ready")
        eq(w.a.duel.active.peerNonce, nil, "expired discovery preserves empty outgoing proof")
        eq(w.b.duel.active.peerNonce, nil, "expired discovery preserves empty incoming proof")
        w:unchanged()
    end)

    scenario("one delivered hello establishes presence without granting consent", function(w)
        w:begin()
        w.queue = { w.queue[1] }
        w:flush()
        eq(w.a.duel:State(), "READY", "initiator of only delivered hello receives acknowledgement")
        eq(w.b.duel:State(), "READY", "peer receives acknowledgement of its own nonce")
        eq(w.a.duel.active.matchId, w.b.duel.active.matchId, "single hello yields shared identity")
        eq(w.a.accepted, 0, "presence does not imply outgoing consent")
        eq(w.b.accepted, 0, "presence does not imply incoming consent")
        w:unchanged()
        w:agree("a")
        w:start()
        w:finish("b")
        eq(#w.a.db.data.matches, 1, "explicit later consent completes match")
        eq(#w.b.db.data.matches, 1, "both participants still agree explicitly")
    end)

    scenario("duplicate reciprocal acknowledgements settle without ping pong", function(w)
        w:ready()
        local original = w.a.fd.Copy(w.sent)
        local before = #w.sent
        eq(before <= 6, true, "initial discovery exchange has bounded message count")
        for _ = 1, 10 do
            for _, message in ipairs(original) do
                if message.kind == "HELLO_ACK" then
                    for _, c in ipairs(w.clients) do
                        if c.identity.fullName == message.to then c.duel:Receive(message.payload, message.from) end
                    end
                end
            end
        end
        w:flush()
        eq(#w.sent, before, "duplicate acknowledgements do not trigger further acknowledgements")
        eq(w.a.duel:State(), "READY", "duplicates preserve outgoing readiness")
        eq(w.b.duel:State(), "READY", "duplicates preserve incoming readiness")
        w:unchanged()
    end)

    scenario("presence retry is acknowledged after peer consent", function(w)
        local dropAcknowledgements = true
        w.drop = function(packet, client)
            return dropAcknowledgements and packet.kind == "HELLO_ACK" and client == w.b
        end
        w:begin()
        w:flush()
        eq(w.a.duel:State(), "CHECKING_ADDON", "initial acknowledgements in one direction lost")
        eq(w.b.duel:State(), "READY", "other side ready")
        w.b.duel:AcceptRated()
        dropAcknowledgements = false
        w:advance(1, false)
        eq(w.queue[1].kind, "ACCEPT", "consent packet delayed")
        eq(w.queue[2].kind, "HELLO", "presence retry queued")
        w:deliver(2)
        eq(w.queue[2].kind, "HELLO_ACK", "already-consenting peer reacknowledges")
        w:deliver(2)
        eq(w.a.duel:State(), "READY", "retry establishes presence")
        w:flush()
        eq(w.a.duel:State(), "REMOTE_ACCEPTED", "delayed consent remains usable")
        w.a.duel:AcceptRated()
        w:flush()
        w:start()
        w:finish("a")
        eq(#w.a.db.data.matches, 1, "recovered exchange completes")
        eq(#w.b.db.data.matches, 1, "recovered peer completes")
    end)

    scenario("duplicate presence and consent messages", function(w)
        w:begin()
        w.queue[#w.queue + 1] = w.a.fd.Copy(w.queue[1])
        w.queue[#w.queue + 1] = w.a.fd.Copy(w.queue[2])
        w:flush()
        w.b.duel:AcceptRated()
        w.queue[#w.queue + 1] = w.a.fd.Copy(w.queue[1])
        w:flush()
        w.a.duel:AcceptRated()
        while #w.queue > 0 do
            local duplicate = w.a.fd.Copy(w.queue[1])
            w:deliver()
            for _, c in ipairs(w.clients) do
                if c.identity.fullName == duplicate.to then c.duel:Receive(duplicate.payload, duplicate.from) end
            end
        end
        eq(w.b.accepted, 1, "duplicate START_OK accepts once")
        w:start()
        w:finish("a")
        eq(#w.a.db.data.matches, 1, "duplicate handshake commits once")
        eq(#w.b.db.data.matches, 1, "peer commits once")
    end)

    scenario("out of order commit fails safely", function(w)
        w:ready()
        w.b.duel:AcceptRated()
        w:flush()
        w.a.duel:AcceptRated()
        eq(w.queue[1].kind, "ACCEPT", "consent queued before commit")
        eq(w.queue[2].kind, "COMMIT", "commit queued second")
        w:deliver(2)
        w:flush()
        eq(w.b.accepted, 0, "early commit cannot accept native duel")
        w:advance(w.a.fd.C.NEGOTIATION_TIMEOUT)
        w:unchanged()
    end)

    for _, kind in ipairs({ "HELLO_ACK", "ACCEPT", "COMMIT", "CONFIRM", "START_OK" }) do
        scenario("lost " .. kind .. " cannot rate", function(w)
            if kind == "HELLO_ACK" then
                w.drop = function(packet) return packet.kind == kind end
                w:begin()
                w:flush()
                w:advance(w.a.fd.C.PRESENCE_TIMEOUT)
            else
                w:ready()
                w.drop = function(packet) return packet.kind == kind end
                w.b.duel:AcceptRated()
                w:flush()
                w.a.duel:AcceptRated()
                w:flush()
                eq(w.b.accepted, 0, "missing agreement step prevents native acceptance")
                w:advance(w.a.fd.C.NEGOTIATION_TIMEOUT)
            end
            w:unchanged()
        end)
    end

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
        w:inject(w.a, w.b, "ACCEPT", { specId = 62 })
        eq(w.b.duel:State(), "READY", "peer snapshot is immutable")
        w:unchanged()
    end)

    scenario("local spec changes before consent", function(w)
        w:ready()
        w.b.identity.specId = 259
        w.b.duel:AcceptRated()
        w:flush()
        eq(w.b.duel:State(), "UNRATED", "spec change cancels rating")
        w:unchanged()
    end)

    scenario("local rating changes before consent", function(w)
        w:ready()
        w.b.db:GetStats().rating = 1520
        w.b.duel:AcceptRated()
        w:flush()
        eq(w.b.duel:State(), "UNRATED", "rating change cancels negotiation")
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

    scenario("native duel accepted before bilateral agreement", function(w)
        w:ready()
        w.b.duel:AcceptRated()
        w:flush()
        w.a.duel:Countdown(3)
        w.b.duel:Countdown(3)
        w:flush()
        w:advance(3)
        w.a.duel:AcceptRated()
        w:finish("a")
        w:unchanged()
    end)

    scenario("native acceptance failure restores normal popup", function(w)
        w:ready()
        w.b.failAccept = true
        w.b.duel:AcceptRated()
        w:flush()
        w.a.duel:AcceptRated()
        w:flush()
        eq(w.b.restored, 1, "failed native acceptance restores popup")
        eq(w.a.duel:State(), "UNRATED", "peer unrate after native failure")
        w:unchanged()
    end)

    scenario("native acceptance without countdown restores normal path", function(w)
        w:ready()
        w:agree("b")
        w:advance(w.b.fd.C.START_TIMEOUT)
        eq(w.b.restored, 1, "watchdog restores popup when start was not observed")
        eq(w.b.duel:State(), "UNRATED", "receiver aborts rating")
        eq(w.a.duel:State(), "UNRATED", "challenger receives watchdog cancellation")
        w.b.duel:ContinueUnrated()
        eq(w.b.accepted, 2, "ordinary acceptance remains available after watchdog")
        w:unchanged()
    end)

    scenario("send failure degrades to ordinary duel", function(w)
        w:ready()
        w.fail = function(packet) return packet.kind == "ACCEPT" end
        w.b.duel:AcceptRated()
        eq(w.b.duel:State(), "UNRATED", "failed send cancels rating locally")
        w.b.duel:ContinueUnrated()
        eq(w.b.accepted, 1, "ordinary accept works after comms fail")
        w:flush()
        w:unchanged()
    end)

    scenario("result requires both observed start messages", function(w)
        w:ready()
        w:agree("a")
        w.drop = function(packet) return packet.kind == "START" end
        w:start()
        w:finish("a")
        w:advance(w.a.fd.C.RESULT_TIMEOUT)
        w:unchanged()
    end)

    scenario("start messages delayed behind results still finalize", function(w)
        w:ready()
        w:agree("b")
        w.a.duel:Countdown(3)
        w.b.duel:Countdown(3)
        local delayedStarts = w.queue
        w.queue = {}
        w:advance(3)
        eq(w.a.duel:State(), "IN_PROGRESS", "local start observed without peer packet")
        eq(w.b.duel:State(), "IN_PROGRESS", "peer local start observed independently")
        w:finish("a")
        eq(w.a.duel:State(), "FINISHING", "winner awaits delayed start evidence")
        eq(w.b.duel:State(), "FINISHING", "loser awaits delayed start evidence")
        w.queue = delayedStarts
        w:flush()
        eq(#w.a.db.data.matches, 1, "late peer start completes winner evidence")
        eq(#w.b.db.data.matches, 1, "late peer start completes loser evidence")
        eq(w.a.db:GetStats().rating, 1516, "late ordering retains correct winner rating")
        eq(w.b.db:GetStats().rating, 1484, "late ordering retains complementary loss")
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

    scenario("missing peer result expires safely", function(w)
        w:running("b")
        w.drop = function(packet) return packet.kind == "RESULT" end
        w:finish("a")
        eq(w.a.duel:State(), "FINISHING", "winner waits for peer")
        eq(w.b.duel:State(), "FINISHING", "loser waits for peer")
        w:advance(w.a.fd.C.RESULT_TIMEOUT)
        eq(w.a.duel:State(), "IDLE", "result timeout clears winner")
        eq(w.b.duel:State(), "IDLE", "result timeout clears loser")
        w:unchanged()
    end)

    scenario("single lost result is recovered by bounded retry", function(w)
        w:running("b")
        local dropped = false
        w.drop = function(packet, client)
            if packet.kind == "RESULT" and client == w.a and not dropped then
                dropped = true
                return true
            end
        end
        w:finish("a")
        eq(#w.a.db.data.matches, 1, "client with matching evidence commits locally")
        eq(#w.b.db.data.matches, 0, "lost report temporarily leaves peer waiting")
        w:advance(3)
        eq(#w.a.db.data.matches, 1, "finalized client retry never duplicates local commit")
        eq(#w.b.db.data.matches, 1, "retry repairs missing peer report")
        eq(w.a.db:GetStats().rating, 1516, "recovered winner rating")
        eq(w.b.db:GetStats().rating, 1484, "recovered complementary loser rating")
    end)

    scenario("persistent one-way result loss documents local asymmetry", function(w)
        w:running("b")
        w.drop = function(packet, client) return packet.kind == "RESULT" and client == w.a end
        w:finish("a")
        w:advance(w.b.fd.C.RESULT_TIMEOUT + 1)
        -- A bounded peer protocol cannot guarantee distributed atomic commits
        -- under permanent one-way loss. Each client requires its own evidence;
        -- the eventual server must reconcile independently uploaded reports.
        eq(w.a.db:GetStats().rating, 1516, "client receiving matching report finalizes")
        eq(#w.a.db.data.matches, 1, "matching independent report retained")
        eq(w.b.db:GetStats().rating, 1500, "client missing report does not infer a result")
        eq(#w.b.db.data.matches, 0, "missing report leaves no rated history")
        eq(w.b.duel:State(), "IDLE", "missing report times out after retries")
    end)

    scenario("cancelled match never retries old result", function(w)
        w:running("b")
        w.drop = function(packet) return packet.kind == "RESULT" end
        w:finish("a")
        local before = 0
        for _, message in ipairs(w.sent) do if message.kind == "RESULT" then before = before + 1 end end
        eq(before, 2, "both initial independent reports attempted")
        w.a.duel:Abort("zoning", true)
        w:flush()
        w:advance(3)
        local after = 0
        for _, message in ipairs(w.sent) do if message.kind == "RESULT" then after = after + 1 end end
        eq(after, before, "aborted or unrated match suppresses result retries")
        w:unchanged()
    end)

    scenario("finalized result retries cannot contaminate rematch", function(w)
        w:running("b")
        w:finish("a")
        local oldId = w.a.db.data.matches[1].matchId
        local before = #w.sent
        w:ready()
        local newId = w.a.duel.active.matchId
        w:advance(3)
        local retried = false
        for index = before + 1, #w.sent do
            if w.sent[index].kind == "RESULT" then retried = true end
        end
        eq(retried, true, "finished clients send bounded delivery retries")
        eq(newId ~= oldId, true, "rematch has distinct identity")
        eq(w.a.duel:State(), "READY", "old report cannot finish or consent rematch")
        eq(w.b.duel:State(), "READY", "peer rejects replayed prior report")
        eq(#w.a.db.data.matches, 1, "no duplicate or premature winner history")
        eq(#w.b.db.data.matches, 1, "no duplicate or premature loser history")
    end)

    scenario("disagreeing result reports cancel both", function(w)
        w:running("b")
        w.a.duel:Result(w.a.identity.guid, "local")
        w.a.duel:Finished()
        w.b.duel:Result(w.b.identity.guid, "local")
        w.b.duel:Finished()
        w:flush()
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

    for _, reason in ipairs({ "zoning", "reload", "disconnect", "cancelled" }) do
        scenario(reason .. " aborts active match", function(w)
            w:running("b")
            w.a.duel:Abort(reason, true)
            w:flush()
            w:finish("a")
            w:advance(w.a.fd.C.RESULT_TIMEOUT)
            w:unchanged()
        end)
    end

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

    scenario("rematch rejects replayed result and uses fresh snapshots", function(w)
        w:running("b")
        local firstId = w.a.duel.active.matchId
        w:finish("a")
        local firstWire = w.a.fd.Copy(w.sent)
        w:ready()
        local nextId = w.a.duel.active.matchId
        eq(nextId ~= firstId, true, "rematch ID is unique")
        eq(w.a.duel.active.ratingBefore, 1516, "winner rematch local snapshot")
        eq(w.b.duel.active.opponentRatingBefore, 1516, "loser rematch peer snapshot")
        for _, message in ipairs(firstWire) do
            for _, c in ipairs(w.clients) do
                if c.identity.fullName == message.to then c.duel:Receive(message.payload, message.from) end
            end
        end
        eq(w.a.duel:State(), "READY", "old messages cannot imply new consent")
        eq(w.b.duel:State(), "READY", "old messages cannot imply peer consent")
        w:agree("a")
        w:start()
        w:finish("b")
        eq(#w.a.db.data.matches, 2, "winner keeps both reports")
        eq(#w.b.db.data.matches, 2, "loser keeps both reports")
        eq(w.a.db.data.matches[2].matchId, nextId, "rematch finalized separately")
        eq(w.a.db:GetStats().rating + w.b.db:GetStats().rating, 3000, "rematch conserves Elo")
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
        w:advance(w.a.fd.C.NEGOTIATION_TIMEOUT)
        w:unchanged()
    end)

    for _, levels in ipairs({ {30, 36}, {36, 30}, {59, 60}, {60, 59}, {0, 30}, {-1, 30} }) do
        scenario("ineligible levels " .. levels[1] .. "/" .. levels[2], function(w)
            w.a.identity.level, w.b.identity.level = levels[1], levels[2]
            w:begin()
            w:flush()
            eq(w.a.duel:State(), "UNRATED", "challenger blocks rated discovery")
            eq(w.b.duel:State(), "UNRATED", "receiver blocks rated discovery")
            eq(#w.sent, 0, "ineligible duel sends no consent or discovery")
            w.a.duel:AcceptRated(); w.b.duel:AcceptRated()
            eq(w.b.accepted, 0, "rated click cannot accept ineligible match")
            w.b.duel:ContinueUnrated()
            eq(w.b.accepted, 1, "ordinary duel remains available")
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
        w.queue = {}
        w:inject(w.b, w.a, "HELLO", { level = 31 })
        eq(w.a.duel:State(), "CHECKING_ADDON", "unproven incompatible hello cannot cancel current request")
        eq(w.a.duel.active.peerNonce, nil, "wire level cannot establish native identity")
        w:inject(w.b, w.a, "HELLO_ACK", { level = 31, echo = w.a.duel.active.nonce })
        eq(w.a.duel:State(), "UNRATED", "current request proof still must match native level")
        w:unchanged()
    end)

    scenario("unproven incompatible hellos cannot poison current discovery", function(w)
        w:begin()
        local before = #w.sent
        for _, changes in ipairs({ { level = 31 }, { maxLevel = 70 }, { classFile = "WARRIOR" } }) do
            w:inject(w.a, w.b, "HELLO", changes)
            eq(w.b.duel:State(), "CHECKING_ADDON", "incompatible unproven profile leaves request pending")
            eq(w.b.duel.active.peerNonce, nil, "incompatible unproven profile does not bind peer")
        end
        eq(#w.sent, before, "incompatible unproven profile gets no acknowledgement")
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
        w:unchanged()
    end)

    scenario("level changes during countdown", function(w)
        w:ready(); w:agree("a")
        w.a.duel:Countdown(3); w.b.duel:Countdown(3); w:flush()
        w.a.identity.level = 31
        w:advance(3)
        eq(w.a.duel:State(), "UNRATED", "level change at start invalidates rating")
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
