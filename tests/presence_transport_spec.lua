return function(_, equal)
    local Harness = assert(loadfile("tests/presence_harness.lua"))()
    local BETA = { guid = "Player-1-0000BBBB", name = "Beta", surname = "Two", realm = "Forever",
        classFile = "ROGUE", level = 30, faction = "Alliance" }
    local function started(options)
        local c = Harness.client(options)
        equal(c:start(), true, "discovery initializes")
        return c
    end
    local function preserved(c, label)
        equal(c.FD.Database.data.player.ratings.LEVELING.rating, 1500, label .. " preserves rating")
        equal(#c.FD.Database.data.matches, 0, label .. " preserves match history")
    end
    local function count(c, channel, tag)
        local n = 0
        for _, packet in ipairs(c.sent) do
            if packet.channel == channel and (not tag or packet.payload:sub(1, #tag) == tag) then n = n + 1 end
        end
        return n
    end
    local function traced(c, pattern)
        for _, entry in ipairs(c:trace("transport")) do
            if (entry.event .. " " .. entry.detail):find(pattern, 1, true) then return true end
        end
        return false
    end

    -- Every send goes through FD.Outbound; dead routes are gone.
    for _, file in ipairs({ "ForeverDuel/Presence.lua", "ForeverDuel/Roster.lua" }) do
        local source = assert(io.open(file, "r")):read("*a")
        equal(source:find("SendAddonMessage(", 1, true), nil, file .. " sends only through FD.Outbound")
        equal(source:find("\"YELL\"", 1, true), nil, file .. " has no YELL route")
        equal(source:find("\"SAY\"", 1, true), nil, file .. " has no SAY route")
        equal(source:find("JoinPermanentChannel", 1, true), nil, file .. " never joins a permanent channel")
        equal(source:find("NAME_PLATE_UNIT_ADDED", 1, true), nil, file .. " does not react to nameplates")
    end

    -- Registration through Outbound.
    local c = started()
    equal(c.prefix, "ForeverDuelZone2", "discovery uses the dedicated versioned prefix")
    equal(c.FD.Outbound.registered.ForeverDuelZone2, true, "Outbound owns the prefix registration")
    equal(c.P:Initialize(), true, "repeat initialization is harmless")
    for _, code in ipairs({ 2, 3 }) do
        c = Harness.client({ registerResult = code })
        equal(c:start(), false, "registration failure enum disables discovery")
        c:advance(600)
        equal(#c.sent, 0, "registration failure sends nothing")
        equal(#c.joins, 0, "registration failure does not join the channel")
        equal(#c.timers, 0, "registration failure leaves no discovery timer")
    end
    c = Harness.client({ registerResult = 1 })
    equal(c:start(), true, "an already-registered prefix is usable")

    -- An idle client without a zone window, queue or channel sends nothing.
    c = started({ channel = false })
    c:addUnit("target", BETA)
    for i = 1, 40 do c:addUnit("nameplate" .. i, Harness.identity(i)) end
    c:advance(600)
    equal(#c.sent, 0, "idle discovery never whispers visible players")
    preserved(c, "idle discovery")

    -- Strict profile parser on the remaining routes.
    c = started({ channel = false })
    local p = c.P
    local WIRE = "FDP2|Player-1-0000BBBB|1642|37|ROGUE|30|60"
    local invalid = {
        "", "FDP1|Player-1-0000BBBB|1642|37|ROGUE", "FDP2|Player-1-0000BBBB|1642|37",
        WIRE .. "|extra", WIRE .. "|", "FDP2|not-a-guid|1642|37|ROGUE|30|60",
        "FDP2|Player-1-0000BBBB|nan|37|ROGUE|30|60", "FDP2|Player-1-0000BBBB|1.2|37|ROGUE|30|60",
        "FDP2|Player-1-0000BBBB|100001|37|ROGUE|30|60", "FDP2|Player-1-0000BBBB|1642|-1|ROGUE|30|60",
        "FDP2|Player-1-0000BBBB|1642|10000001|ROGUE|30|60", "FDP2|Player-1-0000BBBB|1642|37|UNKNOWN|30|60",
        "FDP2|Player-1-0000BBBB|1642|37|ROGUE|0|60", "FDP2|Player-1-0000BBBB|1642|37|ROGUE|61|60",
        "FDP2|Player-1-0000BBBB|1642|37|ROGUE|30|0", "FDP2|Player-1-0000BBBB|1642|37|ROGUE|030|60",
        "FDP2|Player-1-0000BBBB|1642|37|DEATHKNIGHT|30|60", "FDP2|Player-1-0000BBBB|1642|37|MONK|30|60",
        "FDP2:Player-1-0000BBBB:1642:37:ROGUE:30:60", "FDQ2:Player-1-0000BBBB:1642:37:ROGUE:30:60",
        " " .. WIRE, WIRE .. "\n", string.rep("x", 256), c.secret,
    }
    for _, payload in ipairs(invalid) do c:receive(payload, "Beta Two") end
    equal(p:FindByName("Beta Two"), nil, "malformed profiles never populate the cache")
    -- The removed area beacon (YELL/SAY/UNKNOWN, colon encoding) is ignored.
    for _, distribution in ipairs({ "YELL", "SAY", "UNKNOWN", "PARTY", "RAID", "GUILD", "INSTANCE_CHAT", "BATTLEGROUND" }) do
        c:receive(WIRE, "Beta Two", distribution)
        c:receive("FDP2:Player-1-0000BBBB:1642:37:ROGUE:30:60", "Beta Two", distribution)
    end
    equal(p:FindByName("Beta Two"), nil, "area and group routes cannot deliver profiles")
    c:emit("CHAT_MSG_ADDON", "ForeverDuel1", WIRE, "WHISPER", "Beta Two", "", 0, 0)
    c:emit("CHAT_MSG_ADDON", c.secret, WIRE, "WHISPER", "Beta Two", "", 0, 0)
    c:emit("CHAT_MSG_ADDON", "ForeverDuelZone2", WIRE, c.secret, "Beta Two", "", 0, 0)
    for _, sender in ipairs({ c.secret, "", "Bad|Name", "Bad\nName", string.rep("x", 129) }) do c:receive(WIRE, sender) end
    equal(p:FindByName("Beta Two"), nil, "wrong prefix, restricted fields or invalid senders are rejected")
    c:receive(WIRE, "Beta Two")
    equal(p:FindByName("Beta Two").rating, 1642, "valid whispered profile is accepted")
    c:receive("FDP2|Player-1-0000BBBB|1700|0|ROGUE|30|60", "Beta Two")
    equal(p:FindByName("Beta Two").mapID, 0, "map 0 (undisclosed) is a valid profile")
    c = started({ regionalNames = false, channel = false })
    c:receive(WIRE, "Beta")
    equal(c.P:FindByName("Beta-Forever").rating, 1642, "a bare realm-local sender is canonicalized")
    c:receive("FDP2|Player-1-0000DDDD|1550|38|MAGE|30|60", "Delta-OtherRealm")
    equal(c.P:FindByName("Delta-OtherRealm").mapID, 38, "a qualified sender keeps the remote realm")

    -- A CHANNEL addon message must address the channel number as target.
    c = started({ joined = true })
    c:advance(30)
    equal(count(c, "CHANNEL"), 1, "one experimental CHANNEL broadcast after joining")
    local experiment = c:packets("CHANNEL")[1]
    equal(experiment.target, "6", "the experiment addresses the channel number, never a player")
    equal(experiment.prefix, "ForeverDuelZone2", "experiment uses the discovery prefix")
    equal(experiment.payload, "FDP2|Player-1-0000AAAA|1500|37|MAGE|30|60", "experiment carries the public profile")
    equal(experiment.result, 0, "a CHANNEL send with its channel number is accepted")
    equal(traced(c, "zone send CHANNEL experiment sent Success"), true, "the experiment result code is recorded")
    equal(count(c, "WHISPER"), 0, "the experiment never addresses a player")

    local function routed(options)
        local client = Harness.client(options)
        equal(client:start(), true, "discovery initializes")
        return client
    end

    -- CHANNEL profiles count only from our own joined channel.
    c = routed({ joined = true })
    c:advance(30)
    c:receive(WIRE, "Beta Two", "CHANNEL", 8)
    equal(c.P:FindByName("Beta Two"), nil, "another channel number cannot deliver profiles")
    c:receive(WIRE, "Beta Two", "CHANNEL", c.secret)
    equal(c.P:FindByName("Beta Two"), nil, "a restricted channel number is rejected")
    c:receive("FDQ2" .. WIRE:sub(5), "Beta Two", "CHANNEL", 6)
    equal(c.P:FindByName("Beta Two"), nil, "queries are never accepted over CHANNEL")
    c:receive(WIRE, "Beta Two", "CHANNEL", 6)
    equal(c.P:FindByName("Beta Two").rating, 1642, "the joined channel delivers a profile")
    equal(c.R:IsMember("Beta Two"), true, "a CHANNEL sender is a proven channel member")
    equal(c.P:ChannelMode(), true, "another player's CHANNEL message proves the route")
    equal(traced(c, "zone receive first profile via CHANNEL"), true, "the first CHANNEL receipt is recorded")

    -- CHANNEL experiment: exactly one broadcast per session after joining.
    c = routed({ joined = true })
    c:advance(30)
    equal(count(c, "CHANNEL"), 1, "one experimental CHANNEL broadcast after joining")
    experiment = c:packets("CHANNEL")[1]
    equal(experiment.target, "6", "the experiment addresses the channel number, never a player")
    equal(traced(c, "zone send CHANNEL experiment sent Success"), true, "the experiment result code is recorded")
    c:receive(experiment.payload, "Alpha One", "CHANNEL", 6)
    equal(c.P:ChannelMode(), false, "the own echo does not prove delivery to others")
    equal(c.P.ownEcho ~= nil, true, "the own echo is noted")
    equal(traced(c, "zone receive own echo via CHANNEL"), true, "the own echo is recorded as a diagnostic")
    c:advance(600)
    equal(count(c, "CHANNEL"), 1, "a Success result alone never starts CHANNEL broadcasts")
    c:emit("PLAYER_LEAVING_WORLD")
    c:emit("PLAYER_ENTERING_WORLD")
    c:advance(60)
    equal(count(c, "CHANNEL"), 1, "the experiment runs once per session, not per loading screen")

    -- Rejected experiment: the result is recorded and never becomes a whisper.
    c = routed({ joined = true, sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 0 end })
    c:advance(30)
    equal(count(c, "CHANNEL"), 1, "rejected experiment is attempted once")
    equal(count(c, "WHISPER"), 0, "a rejected CHANNEL route never falls back to a whisper")
    equal(traced(c, "zone send CHANNEL experiment failed InvalidChannel"), true, "the rejection code is recorded")
    equal(c.P:ChannelMode(), false, "a rejected route keeps whisper discovery")
    -- Others' broadcasts arrive, ours are rejected: whispers continue and
    -- CHANNEL is retried only every ten minutes.
    c.members = { { name = "Beta Two", guid = BETA.guid } }
    c.FD.Zone.shown = true
    for _ = 1, 12 do
        c:receive(WIRE, "Beta Two", "CHANNEL", 6)
        c:advance(55)
    end
    equal(c.P:ChannelMode(), false, "hearing CHANNEL never switches a client whose broadcasts fail")
    equal(count(c, "WHISPER", "FDQ2") >= 1, true, "the member is still queried by whisper")
    equal(count(c, "CHANNEL"), 2, "one rare CHANNEL retry within ten minutes")
    preserved(c, "rejected experiment")

    -- Working route between two real clients: broadcasts replace member
    -- query whispers; a newcomer is greeted once by whisper.
    local net = Harness.network({ latency = 0.4, jitter = 0.3, seed = 7 })
    local a = net:add(routed({ joined = true }))
    local b = net:add(routed({ joined = true, guid = BETA.guid, name = "Beta", surname = "Two", classFile = "ROGUE" }))
    a.members = { { name = "Beta Two", guid = BETA.guid } }
    b.members = { { name = "Alpha One", guid = a.player.guid } }
    net:advance(10)
    equal(a.P:ChannelMode() and b.P:ChannelMode(), true, "both clients observed the other's CHANNEL message")
    equal(a.P:FindByName("Beta Two").rating, 1500, "first client discovered the second over CHANNEL")
    equal(b.P:FindByName("Alpha One").rating, 1500, "second client discovered the first")
    equal(count(a, "WHISPER", "FDP2") + count(b, "WHISPER", "FDP2") <= 2, true, "newcomers are greeted at most once each")
    local whispers = count(a, "WHISPER") + count(b, "WHISPER")
    a.FD.Zone.shown = true
    net:advance(240)
    equal(count(a, "WHISPER", "FDQ2"), 0, "an open zone window sends no member queries while CHANNEL works")
    equal(#a.selections, 0, "CHANNEL mode never changes the native channel selection")
    equal(count(a, "WHISPER") + count(b, "WHISPER"), whispers, "known members are not whispered again")
    local broadcasts = count(a, "CHANNEL")
    equal(broadcasts >= 4 and broadcasts <= 6, true, "heartbeat broadcasts run about every 60 seconds")
    equal(#a.P:GetPlayers(), 1, "heartbeats keep the peer fresh")
    local zoneEntries = 0
    for _, entry in ipairs(a:trace("transport")) do
        if entry.event == "zone send" or entry.event == "zone receive" then zoneEntries = zoneEntries + 1 end
    end
    equal(zoneEntries <= 3, true, "routine heartbeats and receipts are not persisted")
    a.mapID = 38
    a:emit("ZONE_CHANGED_NEW_AREA")
    net:advance(3)
    equal(count(a, "CHANNEL"), broadcasts + 1, "a zone change is broadcast promptly")
    equal(b.P:FindByName("Alpha One").mapID, 38, "the peer learns the new map")
    a.mapID = 37
    a:emit("ZONE_CHANGED_NEW_AREA")
    net:advance(3)
    equal(count(a, "CHANNEL"), broadcasts + 1, "zone-change broadcasts are rate limited")
    net:advance(30)
    equal(count(a, "CHANNEL"), broadcasts + 2, "the rate-limited change is sent within 30 seconds")
    equal(b.P:FindByName("Alpha One").mapID, 37, "the peer sees the latest map")
    a.FD.Database.data.player.ratings.LEVELING.rating = 1516
    a.P:Changed()
    net:advance(35)
    equal(b.P:FindByName("Alpha One").rating, 1516, "a rating change is advertised without whispers")
    preserved(b, "CHANNEL discovery")

    -- The route stops working: after three missed heartbeats the client
    -- returns to whisper discovery for an open zone window.
    net.channelDelivery = false
    net:advance(200)
    equal(a.P:ChannelMode(), false, "a silent CHANNEL route expires")
    net:advance(10)
    equal(count(a, "WHISPER", "FDQ2") > 0, true, "whisper discovery resumes for members")

    -- Submitted but never delivered: whisper discovery stays in place.
    net = Harness.network({ channelDelivery = false })
    a = net:add(routed({ joined = true }))
    b = net:add(routed({ joined = true, guid = BETA.guid, name = "Beta", surname = "Two", classFile = "ROGUE" }))
    a.members = { { name = "Beta Two", guid = BETA.guid } }
    net:advance(60)
    equal(a.P:ChannelMode() or b.P:ChannelMode(), false, "undelivered CHANNEL messages never switch the route")
    equal(count(a, "CHANNEL"), 1, "only the single experiment was broadcast")

    -- World transitions and logout.
    c = started({ channel = false })
    c:receive(WIRE, "Beta Two")
    c:emit("PLAYER_LEAVING_WORLD")
    equal(c.P.suspended, true, "leaving world suspends discovery")
    equal(c.P:FindByName("Beta Two"), nil, "leaving world hides discovered peers")
    equal(#c.P:Candidates(), 0, "no queue candidates while suspended")
    c:receive("FDP2|Player-1-0000BBBB|1700|37|ROGUE|30|60", "Beta Two")
    equal(c.P:FindByName("Beta Two"), nil, "profiles received during transition are ignored")
    c:emit("PLAYER_ENTERING_WORLD")
    equal(c.P.suspended, false, "entering world resumes discovery")
    equal(c.P:FindByName("Beta Two").rating, 1642, "the cache survives a loading screen without the ignored profile")
    c:receive(WIRE, "Beta Two")
    equal(#c.P:GetPlayers(), 1, "discovery accepts peers after world transition")
    c:emit("PLAYER_LOGOUT")
    equal(next(c.P.players), nil, "logout clears the cache")
    c:advance(60)
    equal(#c.timers, 0, "logout retires all discovery timers")
    equal(#c.sent, 0, "logout sends nothing")

    -- Diagnostics never contain payloads, GUIDs or names.
    for _, client in ipairs({ a, b }) do
        for _, entry in ipairs(client:trace()) do
            equal(entry.detail:find("FDP2", 1, true), nil, "trace holds no profile payload")
            equal(entry.detail:find("FDQ2", 1, true), nil, "trace holds no query payload")
            equal(entry.detail:find("Player-", 1, true), nil, "trace holds no GUID")
            equal(entry.detail:find("Two", 1, true) or entry.detail:find("One", 1, true), nil, "trace holds no names")
        end
    end

    -- Native failures stay inside discovery.
    for _, failure in ipairs({ "failMap", "failSend", "failChannel", "failJoin" }) do
        c = started()
        c.FD.Zone.shown = true
        c[failure] = true
        equal(pcall(function() c:advance(30) end), true, failure .. " is contained")
        c[failure] = false
        c:advance(30)
        equal(#c.timers > 0, true, failure .. " keeps the discovery pulse alive")
        preserved(c, failure)
    end
end
