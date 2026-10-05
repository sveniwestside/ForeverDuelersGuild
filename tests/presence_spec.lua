return function(_, equal)
    local Harness = assert(loadfile("tests/presence_harness.lua"))()
    local function client(options)
        local c = Harness.client(options)
        equal(c:start(), true, "discovery initializes")
        return c
    end
    local function preserved(c, label)
        equal(c.FD.Database.data.player.ratings.LEVELING.rating, 1500, label .. " preserves rating")
        equal(#c.FD.Database.data.matches, 0, label .. " preserves match history")
    end
    local BETA = { guid = "Player-1-0000BBBB", name = "Beta", surname = "Two", realm = "Forever",
        classFile = "ROGUE", level = 32, faction = "Alliance" }

    -- Own profile.
    local c = client()
    local p = c.P
    equal(#p:GetPlayers(), 0, "new cache is empty")
    local own = p:GetOwnPlayer()
    equal(own.guid, c.player.guid, "own profile uses real native identity")
    equal(own.fullName, "Alpha One", "own profile uses the native surname full name")
    equal(own.rating, 1500, "own profile uses persisted rating")
    equal(own.mapID, 37, "own profile has current map")
    equal(own.level, 30, "own profile includes native level")
    equal(own.maxLevel, 60, "own profile includes runtime level cap")
    equal(own.bracket, "LEVELING", "own rating mode derives from native level")
    c.FD.Database.data.player.ratings.MAX_LEVEL.rating = 1777
    c.player.level = 60
    equal(p:GetOwnPlayer().rating, 1777, "reaching cap announces max-level rating independently")
    equal(p:GetOwnPlayer().bracket, "MAX_LEVEL", "reaching cap changes announced mode")
    c.player.level = nil
    equal(p:GetOwnPlayer(), nil, "missing native level cannot publish a profile")
    c.player.level = c.secret
    equal(p:GetOwnPlayer(), nil, "restricted native level cannot publish a profile")
    c.player.level = 30
    c.FD.Database.data.player.ratings.LEVELING.rating = c.secret
    equal(p:GetOwnPlayer(), nil, "restricted saved rating is not published")
    c.FD.Database.data.player.ratings.LEVELING.rating = 1500

    -- The cache is keyed by the authenticated sender name; the GUID is a claim.
    c:receive(c:profile(BETA), "Beta Two")
    local copy = p:GetPlayer(BETA.guid)
    equal(copy.fullName, "Beta Two", "sender name is stored with the claimed GUID")
    equal(copy.rating, 1500, "fresh cached rating available")
    equal(copy.verified, false, "an unobserved GUID claim is unverified")
    copy.rating, copy.fullName = 1, "Changed"
    equal(p:GetPlayer(BETA.guid).rating, 1500, "single lookup returns isolated copy")
    equal(p:FindByName("Beta Two").guid, BETA.guid, "name lookup finds the entry")
    equal(p:FindByName(c.secret), nil, "secret name lookup is rejected")
    equal(#p:Candidates(), 1, "candidates contain the fresh entry")
    local list = p:GetPlayers()
    equal(#list, 1, "same-map cached player is listed")
    list[1].rating = 0
    equal(p:GetPlayers()[1].rating, 1500, "returned list is independent of cache")
    -- A second sender claiming the same GUID no longer locks out the first.
    c:receive(c:profile({ guid = BETA.guid, rating = 9000, classFile = "MAGE", level = 30 }), "Mallory Evil")
    c:receive(c:profile(BETA), "Beta Two")
    equal(p:FindByName("Beta Two").rating, 1500, "the real owner's profile is still accepted")
    equal(p:FindByName("Mallory Evil").rating, 9000, "the impostor is listed under its own name only")
    equal(#p:GetPlayers(), 2, "both senders are kept as separate entries")
    c:addUnit("target", BETA)
    c:receive(c:profile(BETA), "Beta Two")
    equal(p:FindByName("Beta Two").verified, true, "a visible native unit corroborates the claimed GUID")
    equal(p:GetPlayer(BETA.guid).fullName, "Beta Two", "GUID lookup prefers the corroborated entry")
    equal(p:FindByName("Mallory Evil").verified, false, "the impostor claim stays unverified")
    c:receive(c:profile({ guid = "Player-1-0000CCCC", classFile = "MAGE", level = 30 }), "Beta Two")
    equal(p:FindByName("Beta Two").verified, false, "a changed GUID claim loses verification")
    c:receive(c:profile({ guid = c.player.guid, classFile = "MAGE", level = 30 }), "Spoof Name")
    equal(p:FindByName("Spoof Name"), nil, "own GUID never becomes a discovered peer")
    c:receive(c:profile({ guid = "Player-1-0000DDDD", classFile = "MAGE", level = 30 }), "Alpha One")
    equal(p:GetPlayer("Player-1-0000DDDD"), nil, "own sender name cannot add a foreign GUID")

    -- Map filtering, expiry and suspension.
    c = client()
    p = c.P
    c:receive(c:profile(BETA), "Beta Two")
    c.mapID = 38
    equal(#p:GetPlayers(), 0, "moving maps removes old-zone list entries")
    equal(p:GetPlayer(BETA.guid).rating, 1500, "lookup retains fresh other-map profile")
    c.mapID = 37
    c:receive(c:profile(BETA, 0), "Beta Two")
    equal(#p:GetPlayers(), 0, "an undisclosed map (0) is never listed in the zone")
    equal(p:FindByName("Beta Two").mapID, 0, "undisclosed map is cached as 0")
    c:receive(c:profile(BETA), "Beta Two")
    c.now = c.now + 179.99
    equal(#p:GetPlayers(), 1, "profile remains fresh immediately before 180 seconds")
    c.now = c.now + 0.01
    equal(p:GetPlayer(BETA.guid), nil, "profile expires at 180 seconds")
    equal(p:FindByName("Beta Two"), nil, "expired profile is not found by name")
    equal(#p:Candidates(), 0, "expired profile is no queue candidate")
    c.now = c.now - 180
    p.suspended = true
    equal(p:GetPlayer(BETA.guid), nil, "world transition suspends cached profile use")
    equal(#p:GetPlayers(), 0, "world transition hides zone list")
    equal(p:GetStatus(), "Waiting for the world to load.", "transition has useful status")
    p.suspended = false
    for _, invalid in ipairs({ c.secret, "37", 0, -1, 0.5, 10000001, math.huge, 0 / 0 }) do
        c.mapID = invalid
        equal(p:MapID(), nil, "invalid or restricted map rejected")
        equal(#p:GetPlayers(), 0, "invalid map cannot produce zone matches")
    end
    c.mapID = nil
    equal(p:GetStatus():find("waiting for map information", 1, true) ~= nil, true, "missing map explains wait")
    c.env.C_Map = nil
    equal(p:MapID(), nil, "missing map API is tolerated")
    for _, invalid in ipairs({ c.secret, "not-a-player", "Player-1-XYZ", false, {} }) do
        equal(p:GetPlayer(invalid), nil, "invalid or secret GUID cannot query cache")
    end
    -- Entries injected by value (other modules' fixtures) are found by field.
    c = client()
    c.P.players[BETA.guid] = { guid = BETA.guid, fullName = "Beta Two", rating = 1500, level = 30,
        maxLevel = 60, mapID = 37, lastSeen = c.now }
    equal(c.P:FindByName("Beta Two").guid, BETA.guid, "lookups scan values, not keys")
    equal(#c.P:Candidates(), 1, "candidates scan values")

    -- Bounded cache.
    c = client()
    for index = 1, 302 do
        c.now = c.now + 0.01
        c:receive(string.format("FDP2|Player-2-%X|1500|37|MAGE|30|60", index), "Peer" .. index .. " Crowd")
    end
    local entries = 0
    for _ in pairs(c.P.players) do entries = entries + 1 end
    equal(entries, 300, "advisory cache remains bounded")
    equal(c.P:FindByName("Peer1 Crowd"), nil, "oldest profile is evicted when capacity is exhausted")
    equal(c.P:FindByName("Peer302 Crowd").rating, 1500, "newest peer survives capacity eviction")
    c:advance(700)
    entries = 0
    for _ in pairs(c.P.players) do entries = entries + 1 end
    equal(entries, 0, "housekeeping forgets stale entries without incoming packets")

    -- Challenge resolves a visible native unit and uses the duel module's
    -- single request entry point, returning its reason.
    local function challenge(setup)
        local test = client()
        test.FD.Wow.RequestDuel = function(_, token)
            test.requested = token
            if test.blocked then return false, "Native duel request was blocked; request the duel manually." end
            return true
        end
        test:receive(test:profile(BETA), "Beta Two")
        test:addUnit("target", BETA)
        if setup then setup(test) end
        return test, test.P:Challenge("Beta Two")
    end
    local test, ok, reason = challenge()
    equal(ok, true, "visible listed player can be challenged")
    equal(test.requested, "target", "challenge passes the native unit to Wow:RequestDuel")
    equal(test.P:FindByName("Beta Two").verified, true, "challenge corroborates the claim")
    test, ok, reason = challenge(function(t) t.blocked = true end)
    equal(ok, false, "blocked request is reported")
    equal(reason, "Native duel request was blocked; request the duel manually.", "RequestDuel reason is shown")
    for _, case in ipairs({
        { "different map", function(t) t.mapID = 38 end },
        { "unobserved player", function(t) t.units.target = nil end },
        { "same name different GUID", function(t) t.units.target = Harness.identity(9, { name = "Beta", surname = "Two" }) end },
        { "same GUID different name", function(t) t.units.target = { guid = BETA.guid, name = "Gamma", surname = "Two",
            realm = "Forever", classFile = "ROGUE", level = 32, faction = "Alliance" } end },
        { "pending native request", function(t) t.FD.Wow.outgoing = {} end },
        { "expired player", function(t) t.now = t.now + 181 end },
        { "world transition", function(t) t.P.suspended = true end },
        { "restricted local GUID", function(t) t.units.target.guid = t.secret end },
    }) do
        test, ok, reason = challenge(case[2])
        equal(ok, false, case[1] .. " rejected")
        equal(type(reason), "string", case[1] .. " explains failure")
        equal(test.requested, nil, case[1] .. " never requests a native duel")
        preserved(test, case[1])
    end
    test = client()
    equal(test.P:Challenge(test.secret), false, "secret click key rejected")
    for _, token in ipairs({ "mouseover", "focus", "party1", "raid1", "nameplate40" }) do
        test = client()
        test:receive(test:profile(BETA), "Beta Two")
        test:addUnit(token, BETA)
        test.FD.duel = { active = nil }
        equal(test.P:Challenge("Beta Two"), true, token .. " exact identity can request a native duel")
        equal(test.duels[1], token, token .. " native request uses the observed token")
        equal(test.FD.duel.active, nil, token .. " request never begins rated negotiation")
        preserved(test, token)
    end
    test = client()
    test:receive(test:profile(BETA), "Beta Two")
    test:addUnit("target", BETA)
    test.FD.duel = { active = { state = "READY" } }
    ok, reason = test.P:Challenge("Beta Two")
    equal(ok, false, "an active duel blocks the request through RequestDuel")
    equal(reason, "Finish the current duel request first.", "RequestDuel's own reason is returned")
    for _, failure in ipairs({ "failMap", "failIdentity" }) do
        test = client()
        test:receive(test:profile(BETA), "Beta Two")
        test:addUnit("target", BETA)
        test[failure] = true
        ok, reason = test.P:Challenge("Beta Two")
        equal(ok, nil, failure .. " is caught locally")
        equal(reason, "Zone discovery temporarily unavailable.", failure .. " has a useful fallback")
        equal(#test.FD.Debug:Errors(), 1, failure .. " is persisted as an addon error")
        equal(test.duels, nil, failure .. " produces no native request")
        preserved(test, failure)
    end
    test.FD.Debug.Error = function() error("logger failed") end
    equal(pcall(function() test.P:Challenge("Beta Two") end), true, "logger failure stays isolated")

    -- An unsolicited whisper from a sender that is neither a channel member,
    -- a queue peer nor visible is cached but stays out of every lookup, so
    -- the queue never sends that sender its position or queries it.
    test = client()
    p = test.P
    local MAL = { guid = "Player-1-0000EEEE", name = "Mal", surname = "Evil", realm = "Forever",
        classFile = "ROGUE", level = 30, faction = "Alliance" }
    test:inject(test:profile(MAL), "Mal Evil")
    test:inject(test:profile(MAL, nil, "FDQ2"), "Mal Evil")
    equal(p.players["Mal Evil"] ~= nil, true, "the unsolicited claim is cached")
    equal(p:FindByName("Mal Evil"), nil, "hidden from name lookups (queue transport)")
    equal(p:GetPlayer(MAL.guid), nil, "hidden from GUID lookups")
    equal(#p:Candidates(), 0, "hidden from queue candidates")
    equal(#p:GetPlayers(), 0, "hidden from the zone browser")
    equal(p:PongAllowed("Mal Evil"), false, "earns no PONG")
    equal(#test:whispers(), 0, "and gets no reply")
    test.R:AddMember("Mal Evil", MAL.guid, true)
    equal(p:FindByName("Mal Evil") ~= nil, true, "a proven channel member becomes visible")
    test = client()
    p = test.P
    test:receive(test:profile(MAL), "Mal Evil")
    equal(p:FindByName("Mal Evil") ~= nil, true, "an answer to our own query is visible at once")

    -- A loading screen keeps the STRANGER interval for names that never
    -- answered, and the Forget suppression of offline names.
    test = client({ joined = false })
    test:advance(3)
    test:addUnit("mouseover", Harness.identity(42, { name = "Nonaddon", surname = "Guy" }))
    test.P:Observe("mouseover")
    test:advance(4)
    equal(#test:whispers("FDQ2|"), 1, "a tooltip asks a stranger once")
    for _ = 1, 3 do
        test:emit("PLAYER_LEAVING_WORLD"); test:advance(2); test:emit("PLAYER_ENTERING_WORLD"); test:advance(4)
        test.P:Observe("mouseover")
        test:advance(4)
    end
    equal(#test:whispers("FDQ2|"), 1, "loading screens do not reset the STRANGER interval")
    test.P:Forget("Gone Player")
    test:emit("PLAYER_LEAVING_WORLD"); test:advance(1); test:emit("PLAYER_ENTERING_WORLD")
    equal(test.P.queries["Gone Player"] ~= nil, true, "the Forget suppression survives a loading screen")

    -- "last seen" marks a missed refresh, not the wait for the next normal
    -- one: above the CHANNEL heartbeat (60 s) and the member re-query
    -- interval (45 s), below the profile expiry (180 s).
    equal(test.P.STALE > 60 and test.P.STALE < 180, true, "STALE lies between the heartbeat and the expiry")
end
