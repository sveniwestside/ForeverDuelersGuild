return function(_, equal)
    -- Two real addon clients (full TOC, Outbound pacing, UI, native hooks) on
    -- one timeline. Every addon message is delivered by schedule with a
    -- per-message latency, loss or rewrite; the server is modelled only by the
    -- request acknowledgment, DUEL_REQUESTED, the countdown after AcceptDuel
    -- and the winner message.
    local Client = assert(loadfile("tests/duel_client.lua"))()
    local label
    local function eq(actual, expected, text) equal(actual, expected, label .. ": " .. text) end

    local function records(net) return #net.a.FD.Database.data.matches, #net.b.FD.Database.data.matches end

    -- A human clicks the rated button `delay` seconds after it became usable.
    local function human(net, c, delay)
        local seen
        local function poll()
            local ui = c.FD.UI
            if ui.frame and ui.frame:IsShown() and ui.rated.enabled then
                seen = seen or net.clock.now
                if net.clock.now >= seen + delay then
                    c.clickedAt = net.clock.now
                    ui.rated.scripts.OnClick()
                    return
                end
            end
            if net.clock.now < 60 then Client.schedule(net.clock, net.clock.now + 0.25, poll) end
        end
        poll()
    end

    -- Countdown after the native accept; the duel ends `length` seconds later.
    local function fight(net, length, winner)
        net:nativeCountdown()
        local accepted = net.b.onAccept
        net.b.onAccept = function(state)
            accepted(state)
            Client.schedule(net.clock, net.clock.now + 0.2 + 3 + (length or 10), function()
                if winner == "b" then net:finish(net.b, net.a) else net:finish(net.a, net.b) end
            end)
        end
    end

    local function ratedPair(net)
        local a, b = records(net)
        eq(a, 1, "challenger records the rated duel")
        eq(b, 1, "receiver records the rated duel")
        eq(net.a.FD.Database:GetStats().rating + net.b.FD.Database:GetStats().rating, 3000, "Elo conserved")
    end

    -- Rated play must succeed whenever both players click within the native
    -- window, for any one-way latency the window can carry.
    for _, latency in ipairs({ 0.5, 2, 5, 10 }) do
        for _, delays in ipairs({ { 0, 0 }, { 0, 15 }, { 15, 0 }, { 5, 5 }, { 15, 15 }, { 3, 12 } }) do
            label = string.format("latency %.1fs, clicks after %ds/%ds", latency, delays[1], delays[2])
            local net = Client.pair({ latency = latency, tokens = true })
            fight(net, 10, "a")
            net:challenge(net.a)
            human(net, net.a, delays[1])
            human(net, net.b, delays[2])
            net:advance(120)
            eq(net.b.accepts, 1, "receiver's addon accepted natively once")
            eq(net.countdownAt < 50, true, "native countdown inside the request window")
            ratedPair(net)
            eq(net.a.FD.Database:GetStats().rating, 1516, "winner rating")
            eq(net:count("HELLO", net.a) <= #net.a.FD.C.HELLO_SCHEDULE, true, "discovery traffic bounded")
            eq(net.a:printed("RATED duel vs Beta-Forever"), true, "challenger told the duel is rated")
            eq(net.b:printed("RATED duel vs Alpha-Forever"), true, "receiver told the duel is rated")
            eq(net.a.FD.Comms.lastSend ~= nil, true, "transport diagnostics recorded")
        end
    end

    label = "discovery round trip"
    local net = Client.pair({ latency = 2, tokens = true })
    net:challenge(net.a)
    net:advance(6)
    local match = net.a.FD.duel.active
    eq(match.state, "READY", "handshake completes over two-second latency")
    eq(match.rtt >= 4 and match.rtt < 4.5, true, "round trip measured from first HELLO to first ACK")
    local traced
    for _, entry in ipairs(net.a.FD.Debug:RequestTrace(64, "transport")) do
        if entry.event == "transport receive" and entry.detail:find("rtt", 1, true) then traced = entry.detail end
    end
    eq(traced ~= nil, true, "round trip in transport diagnostics")
    eq(traced:find(match.nonce, 1, true), nil, "diagnostics never contain nonces")
    local status = table.concat(net.a.FD:StatusLines(), "\n")
    eq(status:find("Discovery round trip", 1, true) ~= nil, true, "round trip in status lines")
    eq(net.a.FD.UI.frame:IsShown(), true, "proven peer shows the challenger panel")
    eq(net.b.FD.UI.frame:IsShown(), true, "proven peer shows the receiver companion")
    eq(net.b.hides, 0, "Blizzard's popup is untouched before the addon's own accept")

    label = "one lost ACCEPT"
    net = Client.pair({ latency = 1, tokens = true })
    local dropped = false
    net.delay = function(entry)
        if entry.kind == "ACCEPT" and entry.from == net.a and not dropped then dropped = true; return false end
        return 1
    end
    fight(net, 8, "b")
    net:challenge(net.a)
    human(net, net.a, 0); human(net, net.b, 6)
    net:advance(100)
    eq(dropped, true, "the first ACCEPT was lost")
    ratedPair(net)
    eq(net.b.FD.Database:GetStats().rating, 1516, "receiver won")

    label = "opponent not targeted and nameplates off"
    net = Client.pair({ latency = 1, tokens = true })
    local alpha = net.b.units.target
    net.b.units.target = nil
    fight(net, 8, "a")
    net:challenge(net.a)
    net:advance(4)
    eq(net.b.FD.duel.active, nil, "receiver without any unit cannot bind the challenger yet")
    eq(#net.b.prints, 0, "unknown challenger: no hint printed")
    net.b.units.target = alpha
    net:advance(1)
    eq(net.b.FD.duel.active ~= nil, true, "targeting the challenger binds the native identity")
    net.b.units.target, net.a.units.target = nil, nil
    human(net, net.a, 1); human(net, net.b, 2)
    net:advance(100)
    ratedPair(net)

    label = "self target during the countdown"
    for _, tokens in ipairs({ false, true }) do
        net = Client.pair({ latency = 0.5, tokens = tokens })
        fight(net, 8, "a")
        local accepted = net.b.onAccept
        net.b.onAccept = function(state)
            accepted(state)
            -- Both players target themselves while "Duel starting: 3" runs.
            Client.schedule(net.clock, net.clock.now + 0.5, function()
                net.a.units.target = net.a.units.player
                net.b.units.target = net.b.units.player
                eq(net.a.FD.Wow:Observe(net.a.FD.duel.active.opponent), nil, "opponent no longer resolvable")
                eq(net.a.FD.duel:State(), "COUNTDOWN", "self target happens during the countdown")
            end)
        end
        net:challenge(net.a)
        human(net, net.a, 0); human(net, net.b, 1)
        net:advance(100)
        ratedPair(net)
    end

    label = "double click StartDuel"
    net = Client.pair({ latency = 0.5, tokens = true })
    fight(net, 5, "a")
    net.a.env.StartDuel("target")
    net:challenge(net.a)
    eq(net.a.FD.Wow.outgoingBlockedUntil, nil, "a repeated request to the same player is not ambiguous")
    human(net, net.a, 0); human(net, net.b, 0)
    net:advance(100)
    ratedPair(net)

    label = "out of range failure then retry"
    net = Client.pair({ latency = 0.5, tokens = true })
    net.a.messageInfo = { [51] = "ERR_OUT_OF_RANGE" }
    net.a.env.StartDuel("target")
    net.a:emit("UI_ERROR_MESSAGE", 51, "Out of range.")
    eq(net.a.FD.Wow.outgoing, nil, "failure notice clears the pending capture")
    eq(net.a.FD.Wow.outgoingBlockedUntil, nil, "a failed request does not block the next one")
    net:advance(3)
    local ok = net.a.FD.Wow:RequestDuel("target")
    eq(ok, true, "addon request allowed right after the native failure")
    Client.schedule(net.clock, net.clock.now + 0.1, function()
        net.a:emit("CHAT_MSG_SYSTEM", net.a.env.ERR_DUEL_REQUESTED)
        net.b:incoming(net.a.senderName)
    end)
    fight(net, 5, "b")
    human(net, net.a, 0); human(net, net.b, 0)
    net:advance(100)
    ratedPair(net)

    label = "duel to the death"
    net = Client.pair({ latency = 0.5, tokens = true })
    net.a.env.StartDuel("target", true, true)
    eq(net.a.FD.Wow.outgoing, nil, "a duel to the death is not captured")
    net.a:emit("CHAT_MSG_SYSTEM", net.a.env.ERR_DUEL_REQUESTED)
    net.b:emit("DUEL_TO_THE_DEATH_REQUESTED", net.a.senderName)
    net.b:emit("DUEL_REQUESTED", net.a.senderName)
    eq(net.b.FD.duel.active, nil, "a DUEL_REQUESTED raised for the same death request is ignored")
    net:advance(30)
    eq(net.a.FD.duel.active, nil, "challenger starts no rated flow")
    eq(net.b.FD.duel.active, nil, "receiver starts no rated flow")
    eq(#net.log, 0, "no addon message is sent")
    eq(#net.a.prints + #net.b.prints, 0, "nothing printed")
    net.b:incoming(net.a.senderName)
    net.b:emit("DUEL_TO_THE_DEATH_REQUESTED", net.a.senderName)
    eq(net.b.FD.duel.active, nil, "a death request right after DUEL_REQUESTED drops that fresh request")

    label = "outdated FD2 peer"
    net = Client.pair({ latency = 0.5, tokens = true })
    net.rewrite = function(entry)
        -- A 0.5.x client sends the fifteen FD2 fields without extensions.
        if entry.from == net.a then return (entry.sent.payload:gsub("^FD3", "FD2", 1):gsub("|v=[^|]*$", "")) end
    end
    net:challenge(net.a)
    net:advance(40)
    local outdated = 0
    for _, line in ipairs(net.b.prints) do
        if line:find("older ForeverDuel version", 1, true) then outdated = outdated + 1 end
    end
    eq(outdated, 1, "receiver explains the outdated peer once")
    eq(net.b.FD.duel.active.peerOutdated, true, "match marked")
    local mismatch
    for _, entry in ipairs(net.b.FD.Debug:RequestTrace(64, "lifecycle")) do
        if entry.event == "version mismatch" then mismatch = entry end
    end
    eq(mismatch ~= nil, true, "version mismatch persisted")
    eq(net.b.FD.UI.frame:IsShown(), false, "no rated panel for an outdated peer")

    label = "logout sends an immediate CANCEL"
    net = Client.pair({ latency = 1, tokens = true })
    net:challenge(net.a)
    net:advance(4)
    eq(net.b.FD.duel:State(), "READY", "negotiation ready")
    local before = #net.a.sent
    net.a:emit("PLAYER_LOGOUT")
    local cancel = net.a.sent[before + 1]
    eq(cancel ~= nil and net.a.FD.Protocol:Decode(cancel.payload).kind, "CANCEL", "CANCEL submitted synchronously")
    eq(net.a.FD.Protocol:Decode(cancel.payload).reason, "world", "CANCEL carries the reason code")
    net:advance(2)
    eq(net.b.FD.duel:State(), "UNRATED", "receiver stops rated play")
    eq(net.b:printed("Your opponent logged out or changed zones"), true, "receiver told why")

    label = "late RESULT after the peer finalized"
    net = Client.pair({ latency = 0.5, tokens = true })
    net.delay = function(entry)
        if entry.kind == "RESULT" and entry.from == net.a and net.clock.now < net.lossUntil then return false end
        return 0.5
    end
    net.lossUntil = math.huge
    fight(net, 5, "a")
    net:challenge(net.a)
    human(net, net.a, 0); human(net, net.b, 0)
    net:advance(15)
    net.lossUntil = net.clock.now + 12
    net:advance(30)
    local recordsA, recordsB = records(net)
    eq(recordsA, 1, "challenger finalized from the receiver's report")
    eq(recordsB, 1, "receiver finalized from the cached answer")
    eq(net.b.FD.Database:GetStats().rating, 1484, "receiver's loss recorded")

    label = "rematch during FINISHING"
    net = Client.pair({ latency = 0.5, tokens = true })
    net.delay = function(entry)
        if entry.kind == "RESULT" and entry.from == net.a then return 2 end
        return 0.5
    end
    fight(net, 5, "a")
    net:challenge(net.a)
    human(net, net.a, 0); human(net, net.b, 0)
    -- The duel ends at about 10 s; the winner's report needs 2 s to arrive.
    net:advance(11)
    eq(#net.a.FD.Database.data.matches, 1, "winner finalized")
    eq(net.b.FD.duel:State(), "FINISHING", "loser still waits for the delayed report")
    net.delay = nil
    net.a.onAccept, net.b.onAccept = nil, nil
    fight(net, 5, "b")
    net:challenge(net.a)
    net:advance(0.2)
    eq(net.b.FD.duel.parked ~= nil, true, "previous match parked")
    net:advance(3)
    eq(#net.b.FD.Database.data.matches, 1, "parked match finalized from the late report")
    human(net, net.a, 0); human(net, net.b, 0)
    net:advance(100)
    eq(#net.a.FD.Database.data.matches, 2, "challenger records both duels")
    eq(#net.b.FD.Database.data.matches, 2, "receiver records both duels")
    eq(net.a.FD.Database:GetStats().rating + net.b.FD.Database:GetStats().rating, 3000, "rematch conserves Elo")

    label = "exact party route while the receiver's roster is still loading"
    net = Client.pair({ latency = 0.5, tokens = true })
    for _, c in ipairs({ net.a, net.b }) do c.grouped, c.members, c.units.party1 = true, 2, c.units.target end
    net.b.units.party1 = nil
    fight(net, 5, "a")
    net:challenge(net.a)
    human(net, net.a, 0); human(net, net.b, 0)
    net:advance(100)
    ratedPair(net)
    local channels = {}
    for _, entry in ipairs(net.log) do
        if entry.from == net.a then
            local key = entry.kind .. " " .. entry.sent.channel
            channels[key] = (channels[key] or 0) + 1
        end
    end
    eq(channels["HELLO WHISPER"], 1, "grouped discovery also whispers the first HELLO once")
    eq((channels["HELLO PARTY"] or 0) >= 1, true, "grouped discovery uses PARTY")
    eq(channels["ACCEPT PARTY"] ~= nil and channels["ACCEPT WHISPER"] == nil, true, "consent travels by PARTY only")
    eq((channels["RESULT PARTY"] or 0) >= 1, true, "results travel by PARTY")
    eq(net.b.FD.Comms.lastRejection, nil, "PARTY from the bound opponent is accepted without an exact own roster")
    eq(net.a.FD.Comms.lastRejection, nil, "own PARTY echoes are ignored, not rejected")

    label = "throttled sends are paced, not fatal"
    net = Client.pair({ latency = 0.5, tokens = true })
    local throttled = 0
    net.a.sendFilter = function(prefix, payload, channel, target, result)
        if throttled < 3 then throttled = throttled + 1; return 3 end
        return result
    end
    fight(net, 5, "a")
    net:challenge(net.a)
    human(net, net.a, 0); human(net, net.b, 0)
    net:advance(100)
    eq(throttled, 3, "the first submissions were throttled")
    ratedPair(net)
end
