return function(_, equal)
    -- Latency probe: PING|seq|ms answered by PONG|seq|ms, measured per route
    -- on the pinger's clock, over a network with realistic one-way delays.
    local Harness = assert(loadfile("tests/presence_harness.lua"))()
    local BETA = { guid = "Player-1-0000BBBB", name = "Beta", surname = "Two", realm = "Forever",
        classFile = "ROGUE", level = 30, faction = "Alliance" }
    local function pair(options, joined)
        local net = Harness.network(options)
        local a = net:add(Harness.client({ channel = false }))
        local b = net:add(Harness.client({ channel = joined == true, joined = joined,
            guid = BETA.guid, name = "Beta", surname = "Two", classFile = "ROGUE" }))
        a:start(); b:start()
        a:addUnit("target", BETA)
        b:addUnit("target", a.player)
        return net, a, b
    end
    local function printed(c, pattern)
        for _, line in ipairs(c.prints) do
            if line:find(pattern, 1, true) then return line end
        end
    end
    local function packets(c, tag)
        local n = 0
        for _, packet in ipairs(c.sent) do if packet.payload:sub(1, #tag) == tag then n = n + 1 end end
        return n
    end
    local function traced(c, pattern)
        for _, entry in ipairs(c:trace("transport")) do
            if (entry.event .. " " .. entry.detail):find(pattern, 1, true) then return entry end
        end
    end

    -- Target ping over WHISPER with ~0.6 s one-way latency.
    local net, a, b = pair({ latency = 0.6, jitter = 0 })
    a:command("ping")
    equal(printed(a, "PING sent to Beta Two via WHISPER.") ~= nil, true, "the pinger confirms the probe")
    net:advance(3)
    local line = printed(a, "PONG from Beta Two via WHISPER: ")
    equal(line ~= nil, true, "the target answers with a PONG")
    local rtt = tonumber(line:match("WHISPER: ([%d%.]+) s round trip"))
    equal(rtt >= 1.2 and rtt <= 1.5, true, "the round trip reflects both one-way delays")
    equal(packets(b, "PONG|"), 1, "one PONG per PING")
    local probe = a:packets("WHISPER")[1]
    equal(probe.payload:match("^PING|1|%d+$") ~= nil, true, "PING carries a sequence number and the sender clock")
    equal(b:packets("WHISPER")[1].payload:sub(6), probe.payload:sub(6), "PONG echoes sequence and clock")
    equal(traced(a, "ping WHISPER 1.") ~= nil, true, "the measured round trip is recorded under ping")
    equal(traced(b, "ping answered WHISPER") ~= nil, true, "the answer is recorded")
    for _, client in ipairs({ a, b }) do
        for _, entry in ipairs(client:trace()) do
            equal(entry.detail:find("PING|", 1, true) or entry.detail:find("PONG|", 1, true), nil, "no payload in diagnostics")
            equal(entry.detail:find("Beta", 1, true) or entry.detail:find("Alpha", 1, true), nil, "no names in diagnostics")
        end
    end
    equal(#a.FD.Database.data.matches + #b.FD.Database.data.matches, 0, "a probe never creates match history")

    -- Named ping keeps the typed case; a pathological 35 s whisper delay is
    -- measured, not mistaken for a timeout.
    net, a, b = pair({ latency = 35, jitter = 0 })
    a.units.target = nil
    a:command("ping Beta Two")
    net:advance(60)
    equal(printed(a, "No PONG") , nil, "a slow answer is not reported as a timeout early")
    net:advance(15)
    line = printed(a, "PONG from Beta Two via WHISPER: ")
    rtt = tonumber(line:match("WHISPER: ([%d%.]+) s round trip"))
    equal(rtt >= 70 and rtt < 71, true, "a 35 s one-way delay shows a 70 s round trip")

    -- Whisper delivery ignores case: a name typed in lower case reaches the
    -- player, and the PONG from the server's spelling is matched to it.
    net, a, b = pair({ latency = 0.4, jitter = 0 })
    a.units.target = nil
    a:command("ping beta two")
    net:advance(3)
    equal(a:packets("WHISPER")[1].target, "beta two", "an unknown name is pinged as typed")
    line = printed(a, "PONG from Beta Two via WHISPER: ")
    equal(line ~= nil, true, "the PONG from the canonical sender is matched case-insensitively")
    net:advance(95)
    equal(printed(a, "No PONG"), nil, "no false timeout for a lower-case name")
    a:receive(a:profile(BETA), "Beta Two")
    a:command("ping BETA TWO")
    net:advance(1)
    equal(a:packets("WHISPER")[2].target, "Beta Two", "a known player is pinged with the server's spelling")
    a:command("ping alpha one")
    equal(printed(a, "not yourself") ~= nil, true, "pinging yourself is refused whatever the case")

    -- Exact two-player group: WHISPER and PARTY are probed separately.
    net, a, b = pair({ latency = 0.8, jitter = 0, routeLatency = { PARTY = 0.1 } })
    a.group, b.group = "pair", "pair"
    a:addUnit("party1", BETA)
    b:addUnit("party1", a.player)
    a:command("ping")
    net:advance(3)
    local whisper = printed(a, "via WHISPER: ")
    local party = printed(a, "via PARTY: ")
    equal(whisper ~= nil and party ~= nil, true, "both routes are answered")
    equal(tonumber(party:match("PARTY: ([%d%.]+)")) < tonumber(whisper:match("WHISPER: ([%d%.]+)")), true,
        "each route reports its own round trip")
    equal(packets(b, "PONG|"), 2, "PARTY and WHISPER each get one PONG")
    for _, packet in ipairs(b.sent) do
        if packet.channel == "PARTY" then equal(packet.payload:sub(1, 5), "PONG|", "the PARTY probe is answered on PARTY") end
    end

    -- Answers are rate limited per sender and route.
    net, a, b = pair({ latency = 0.2, jitter = 0 })
    a:command("ping"); a:command("ping"); a:command("ping")
    net:advance(1.5)
    equal(packets(b, "PONG|"), 1, "one PONG per two seconds per sender")
    net:advance(95)
    equal(printed(a, "No PONG from Beta Two via WHISPER within 90 s.") ~= nil, true, "unanswered probes time out visibly")
    a:command("ping")
    net:advance(2)
    equal(packets(b, "PONG|"), 2, "a later probe is answered again")

    -- Only channel members, known players, party members or the target are answered.
    net, a, b = pair({ latency = 0.2, jitter = 0 }, true)
    b.units.target = nil
    a:command("ping")
    net:advance(3)
    equal(packets(b, "PONG|"), 0, "an unknown sender gets no PONG")
    b.R:AddMember("Alpha One", a.player.guid, true)
    net:advance(2)
    a:command("ping")
    net:advance(2)
    equal(packets(b, "PONG|"), 1, "a channel member is answered")
    net, a, b = pair({ latency = 0.2, jitter = 0 })
    b.units.target = nil
    b:receive(b:profile({ guid = a.player.guid, classFile = "MAGE", level = 30 }), "Alpha One")
    a:command("ping")
    net:advance(2)
    equal(packets(b, "PONG|"), 1, "a known presence player is answered")
    net, a, b = pair({ latency = 0.2, jitter = 0 })
    b.units.target = nil
    b:addUnit("party3", a.player)
    a:command("ping")
    net:advance(2)
    equal(packets(b, "PONG|"), 1, "a party member is answered")
    -- PARTY probes require the exact two-player group.
    net, a, b = pair({ latency = 0.2, jitter = 0 })
    b:receive("PING|7|1000", "Alpha One", "PARTY")
    net:advance(1)
    equal(packets(b, "PONG|"), 0, "a PARTY probe without the exact group is ignored")
    for _, payload in ipairs({ "PING|abc|1", "PING|1|", "PING|1234567|1", "PING|1|1|x", "PING|-1|5", "PING 1 1" }) do
        b:receive(payload, "Alpha One")
    end
    net:advance(3)
    equal(packets(b, "PONG|"), 0, "malformed probes are ignored")
    b:receive("PONG|99|1000", "Alpha One")
    equal(printed(b, "PONG from"), nil, "an unsolicited PONG is ignored")

    -- Quiet mode keeps the probe (it is the A/B measurement) and nothing else.
    net, a, b = pair({ latency = 0.3, jitter = 0 })
    a:command("quiet"); b:command("quiet")
    a.FD.Zone.shown, b.FD.Zone.shown = true, true
    a:command("ping")
    net:advance(30)
    equal(printed(a, "PONG from Beta Two via WHISPER") ~= nil, true, "ping works in quiet mode")
    for _, client in ipairs({ a, b }) do
        for _, packet in ipairs(client.sent) do
            equal(packet.payload:sub(1, 5) == "PING|" or packet.payload:sub(1, 5) == "PONG|", true,
                "quiet mode sends nothing but the probe")
        end
    end

    -- Usage errors.
    local c = Harness.client({ channel = false })
    c:start()
    c:command("ping")
    equal(printed(c, "Target a player") ~= nil, true, "a ping without target explains usage")
    c:command("ping Alpha One")
    equal(printed(c, "not yourself") ~= nil, true, "pinging yourself is refused")
    c:command("ping Bad|Name")
    equal(printed(c, "not a valid character name") ~= nil, true, "invalid names are refused")
    equal(#c.sent, 0, "usage errors send nothing")
    c = Harness.client({ channel = false, registerResult = 2 })
    c:start()
    c:command("ping Beta Two")
    equal(printed(c, "unavailable") ~= nil, true, "an unregistered prefix disables the probe visibly")
end
