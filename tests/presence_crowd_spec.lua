return function(_, equal)
    -- Crowd: 150 bot members plus three real clients in the ForeverDuel
    -- channel, 40 friendly nameplates, 20 members that keep querying, all
    -- over a network with 0.3-0.9 s latency and 2 % loss. CHANNEL delivery is
    -- unavailable, so whisper discovery carries the whole load.
    local Harness = assert(loadfile("tests/presence_harness.lua"))()
    local net = Harness.network({ latency = 0.3, jitter = 0.6, loss = 0.02, seed = 4242, channelDelivery = false })
    local roster = {}
    local bots = {}
    for i = 1, 150 do
        local identity = Harness.identity(i)
        bots[i] = net:bot(identity, { silent = i > 130 }) -- 20 old or idle clients never answer
        roster[#roster + 1] = { name = bots[i].name, guid = identity.guid }
    end
    local reals = {}
    for index, name in ipairs({ "Alpha", "Beta", "Gamma", "Delta" }) do
        local c = Harness.client({ joined = true, name = name, surname = "Real",
            guid = string.format("Player-1-0000%04X", 0xA000 + index) })
        c.rosterDelay = 2
        reals[index] = net:add(c)
        roster[#roster + 1] = { name = name .. " Real", guid = c.player.guid }
    end
    -- A server-side throttle answers AddonMessageThrottle when a client
    -- submits more than 10 addon whispers within one second.
    local throttled = 0
    for _, c in ipairs(reals) do
        c.members = roster
        local recent = {}
        c.sendResult = function(packet)
            if packet.channel ~= "WHISPER" then return 0 end
            while recent[1] and packet.at - recent[1] >= 1 do table.remove(recent, 1) end
            if #recent >= 10 then throttled = throttled + 1; return 3 end
            recent[#recent + 1] = packet.at
            return 0
        end
        c:start()
    end
    local a = reals[1]
    for i = 1, 40 do a:addUnit("nameplate" .. i, Harness.identity(1000 + i)) end
    for _, c in ipairs(reals) do c.FD.Zone.shown = true end
    -- Twenty chatty members query Alpha every 30 seconds with spread phases.
    local maxWork = 0
    local schedule = {}
    for i = 1, 20 do schedule[i] = net.now + 3 + i * 1.4 end
    local stop = net.now + 600
    while net.now < stop do
        for i = 1, 20 do
            if net.now >= schedule[i] then
                schedule[i] = schedule[i] + 30
                net:botSend(bots[i], "Alpha Real", string.format("FDQ2|%s|1500|37|ROGUE|30|60", bots[i].identity.guid))
            end
        end
        for i = 1, 40 do
            if math.floor(net.now * 10) % 7 == 0 then a:emit("UPDATE_MOUSEOVER_UNIT"); a:emit("PLAYER_TARGET_CHANGED") end
        end
        net:step(0.1)
        maxWork = math.max(maxWork, a.P.workCount)
    end

    -- Nameplates are never fanned out to.
    local plateNames = {}
    for i = 1, 40 do plateNames[Harness.fullName(Harness.identity(1000 + i), true)] = true end
    for _, packet in ipairs(a.sent) do
        equal(plateNames[packet.target], nil, "no whisper to a nameplate stranger")
    end
    -- The send rate stays within the Outbound whisper budget.
    local whispers = {}
    for _, packet in ipairs(a.sent) do if packet.channel == "WHISPER" then whispers[#whispers + 1] = packet.at end end
    local worst = 0
    for i = 1, #whispers do
        local n = 0
        for j = i, #whispers do
            if whispers[j] - whispers[i] < 60 then n = n + 1 else break end
        end
        worst = math.max(worst, n)
    end
    equal(worst <= 68, true, "at most 68 discovery whispers in any minute (8 burst + 1/s)")
    equal(#whispers > 300, true, "the budget is used, not idle")
    equal(throttled, 0, "the server throttle is never hit")
    equal(maxWork <= 30, true, "pending discovery work never exceeds 30")
    -- Replies keep flowing: every member query is answered within seconds.
    local latencies = {}
    for _, entry in ipairs(net.log) do
        if entry.to == "Alpha Real" and entry.payload:sub(1, 5) == "FDQ2|" and entry.at < stop - 15 then
            local answered
            for _, packet in ipairs(a.sent) do
                if packet.target == entry.from and packet.payload:sub(1, 5) == "FDP2|" and packet.at >= entry.at then
                    answered = packet.at - entry.at
                    break
                end
            end
            latencies[#latencies + 1] = answered or math.huge
        end
    end
    table.sort(latencies)
    equal(#latencies > 300, true, "the chatty members sent their queries")
    equal(latencies[math.ceil(#latencies / 2)] <= 3, true, "median reply latency is at most three seconds")
    equal(latencies[#latencies] <= 10, true, "every member query is answered within ten seconds")
    -- The real clients still discover each other inside the crowd.
    for index, c in ipairs(reals) do
        local found = 0
        for other, peer in ipairs(reals) do
            if other ~= index and c.P:FindByName(peer.fullName) then found = found + 1 end
        end
        equal(found, 3, c.fullName .. " discovers the other real clients")
        -- Alpha also answers twenty chatty members, leaving less budget for
        -- its own sweep; the others list nearly all 130 answering members.
        equal(#c.P:GetPlayers() >= (index == 1 and 50 or 110), true, c.fullName .. " lists the answering crowd")
        equal(c.FD.Database.data.player.ratings.LEVELING.rating, 1500, "crowd discovery preserves rating")
    end
    -- Members are asked at most every 45 seconds each.
    local last = {}
    for _, packet in ipairs(a:whispers("FDQ2")) do
        if packet.result == 0 then
            if last[packet.target] then equal(packet.at - last[packet.target] >= 45, true, "per-member query interval holds") end
            last[packet.target] = packet.at
        end
    end
end
