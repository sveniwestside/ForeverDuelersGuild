return function(FD, equal)
    if not FD.QueueProtocol then assert(loadfile("ForeverDuel/QueueProtocol.lua"))("ForeverDuel", FD) end
    local protocol = FD.QueueProtocol
    local base = {
        kind = "PROFILE", session = "abcd-1234", guid = "Player-1234-0000ABCD",
        rating = 1500, level = 30, maxLevel = 60, scope = "ZONE", levelGap = 5,
        ruleset = "PVP", faction = "Alliance", joinedAt = 1791100000,
        mapID = 1429, continentID = 0, x = -1000, y = 2000, venues = "0a1b2.ffff0",
    }
    local function profile(changes)
        local result = {}
        for key, value in pairs(base) do result[key] = value end
        for key, value in pairs(changes or {}) do result[key] = value end
        return result
    end
    local function control(kind, changes)
        local result = { kind = kind, session = "abcd-1234", peerSession = "abcd-5678", ticket = "ab.cd-1234-5678" }
        for key, value in pairs(changes or {}) do result[key] = value end
        return result
    end
    local function roundTrip(packet)
        local payload = protocol:Encode(packet)
        equal(type(payload), "string", packet.kind .. " encoded")
        equal(#payload <= protocol.MAX_BYTES, true, packet.kind .. " bounded")
        local decoded = protocol:Decode(payload)
        for key, value in pairs(packet) do
            if key ~= "fullName" and key ~= "lastSeen" then
                equal(decoded[key], value, packet.kind .. " round trip " .. key)
            end
        end
        equal(decoded.protocolVersion, 2, packet.kind .. " version")
        equal(protocol:Encode(decoded), payload, packet.kind .. " canonical re-encoding")
        return payload, decoded
    end
    equal(protocol.PREFIX, "ForeverDuelQ2", "queue protocol 2 uses its own prefix")
    equal(protocol.WIRE_VERSION, "FQ2", "queue protocol 2 wire tag")
    equal(protocol.MAX_BYTES, 255, "addon wire byte limit")
    equal(protocol.MAP_SCALE, 100000000, "venue fractions retain eight decimal places")
    local encoded = roundTrip(base)
    roundTrip({ kind = "QUERY" })
    roundTrip({ kind = "LEAVE", session = base.session, guid = base.guid })
    roundTrip(control("OFFER"))
    roundTrip(control("GROUP", { mapID = 1429, continentID = 0, x = 12, y = -40 }))
    roundTrip(control("GROUP", { mapID = 0, continentID = 0, x = 0, y = 0 }))
    roundTrip(control("PLAN", { venueID = "test-venue.1", deadline = 1791100900, duration = 900,
        mapID = 1429, continentID = 0, x = -1000, y = 2000 }))
    roundTrip(control("PLAN_ACK", { venueID = "test-venue.1", deadline = 1791100900 }))
    roundTrip(control("PLAN_REJECT", { venueID = "test-venue.1" }))
    for flags = 0, 3 do roundTrip(control("STATUS", { mapID = 1429, continentID = 0, x = 1, y = 2, flags = flags })) end
    local reasons = { "CANCELLED", "DECLINED", "BUSY", "INVITE_FAILED", "GROUP_TIMEOUT", "PEER_SILENT",
        "GROUP_CHANGED", "OPPONENT_LEFT", "NO_VENUE", "PLAN_INVALID", "TRAVEL_TIMEOUT", "START_TIMEOUT",
        "DUEL", "FINISHED", "ERROR", "RELOAD" }
    for _, reason in ipairs(reasons) do roundTrip(control("CANCEL", { reason = reason })) end
    local count = 0
    for _ in pairs(protocol.REASONS) do count = count + 1 end
    equal(count, #reasons, "every wire reason has a protocol code")
    for _, removed in ipairs({ "ACK", "COMMIT", "CONFIRM", "GO", "GO_ACK", "ARRIVED", "READY", "POSITION" }) do
        equal(protocol:Encode(control(removed)), nil, "protocol 1 handshake kind removed: " .. removed)
    end
    equal(protocol:Encode(control("CANCEL", { reason = "TECHNICAL" })), nil, "generic technical reason replaced by specific codes")

    -- Venue digest: up to eight five-hex-digit hashes or "-".
    roundTrip(profile({ venues = "-" }))
    roundTrip(profile({ venues = "00000.11111.22222.33333.44444.55555.66666.77777" }))
    for _, digest in ipairs({ "", "0a1b", "0a1b23", "0A1B2", "0a1b2.", ".0a1b2", "0a1b2..ffff0", "zzzzz",
        "00000.11111.22222.33333.44444.55555.66666.77777.88888", "0a1b2,ffff0", 5 }) do
        equal(protocol:Encode(profile({ venues = digest })), nil, "invalid venue digest " .. tostring(digest))
    end
    local largestProfile = protocol:Encode(profile({ session = string.rep("a", 32),
        guid = "Player-" .. string.rep("a", 28) .. "-" .. string.rep("b", 28), rating = -100000, level = 255,
        maxLevel = 255, scope = "CONTINENT", ruleset = "HARDCORE", joinedAt = 4102444800, mapID = 100000,
        continentID = 100000, x = -1000000, y = -1000000,
        venues = "00000.11111.22222.33333.44444.55555.66666.77777" }))
    equal(type(largestProfile), "string", "largest profile with a full digest fits the native wire")
    equal(#largestProfile <= 255, true, "largest profile under byte limit")

    local metadata = profile({ fullName = "Native-Name", lastSeen = 25 })
    equal(protocol:Encode(metadata), encoded, "native transport metadata is never serialized")
    equal(protocol:ValidProfile(metadata), true, "local profile metadata is permitted")
    local profileWithoutKind = profile()
    profileWithoutKind.kind = nil
    equal(protocol:ValidProfile(profileWithoutKind), true, "adapter profiles need no packet kind")
    roundTrip(profile({ mapID = 0, continentID = 0, x = 0, y = 0 }))
    roundTrip(profile({ scope = "CONTINENT", faction = "Horde", ruleset = "NORMAL", levelGap = 0,
        rating = -100000, x = -1000000, y = 1000000, joinedAt = 0 }))
    roundTrip(profile({ scope = "RULESET", ruleset = "RP", level = 255, maxLevel = 255,
        rating = 100000, mapID = 100000, continentID = 100000, joinedAt = 4102444800 }))
    roundTrip(profile({ ruleset = "HARDCORE", rating = -1 / math.huge }))

    for key, values in pairs({
        kind = { "UNKNOWN", "profile", "" },
        session = { "", "...", "ABCD", "a|b", string.rep("a", 33) },
        guid = { "Creature-1-A", "Player--A", "Player-1-Z", string.rep("a", 65) },
        rating = { -100001, 100001, 0.1, "1500", math.huge, 0 / 0 },
        level = { 0, 61, 0.1, "30" }, maxLevel = { 0, 29, 256, 60.1 },
        scope = { "ALL", "zone", "" }, levelGap = { -1, 6, 0.5, "5" },
        ruleset = { "PVE", "pvp", "", "PVP|NORMAL" }, faction = { "Neutral", "horde", "" },
        joinedAt = { -1, 4102444801, 0.1, "1791100000" },
        mapID = { -1, 100001, 0.5, "1429" }, continentID = { -1, 100001, 0.5, "0" },
        x = { -1000001, 1000001, 0.5, "0", math.huge },
        y = { -1000001, 1000001, 0.5, "0", 0 / 0 },
        protocolVersion = { 0, 1, 3, "2" },
    }) do
        for _, value in ipairs(values) do equal(protocol:Encode(profile({ [key] = value })), nil, "invalid profile " .. key) end
    end
    equal(protocol:ValidProfile(nil), nil, "nil adapter profile")
    equal(protocol:Encode(profile({ mapID = 0 })), nil, "partial unknown position")
    equal(protocol:Encode(profile({ mapID = 0, x = 0, y = 0, continentID = 1 })), nil, "unknown position has no continent")
    equal(protocol:Encode(nil), nil, "nil packet")
    equal(protocol:Encode({}), nil, "missing packet kind")
    equal(protocol:Encode({ kind = "QUERY", protocolVersion = 1 }), nil, "query version mismatch")

    for key, values in pairs({
        session = { "", "a|b", string.rep("b", 33) },
        peerSession = { "", "a|b", base.session, string.rep("b", 33) },
        ticket = { "", "...", "a:b", string.rep("b", 81) },
    }) do
        for _, value in ipairs(values) do equal(protocol:Encode(control("OFFER", { [key] = value })), nil, "invalid control " .. key) end
    end
    local plan = { venueID = "test-venue", deadline = 1791100300, duration = 300,
        mapID = 1429, continentID = 0, x = -1000, y = 2000 }
    local function changedPlan(changes)
        local result = {}
        for key, value in pairs(plan) do result[key] = value end
        for key, value in pairs(changes) do result[key] = value end
        return control("PLAN", result)
    end
    for key, values in pairs({
        venueID = { "", "Test", "test|venue", string.rep("a", 49) },
        deadline = { -1, 4102444801, 0.1, "1791100300" },
        duration = { 299, 901, 300.1, "300" },
        mapID = { 0, -1, 100001 }, continentID = { -1, 100001 }, x = { 0.5, 1000001 }, y = { 0.5, -1000001 },
    }) do
        for _, value in ipairs(values) do equal(protocol:Encode(changedPlan({ [key] = value })), nil, "invalid plan " .. key) end
    end
    equal(protocol:Encode(control("PLAN_ACK", { venueID = "test-venue" })), nil, "plan acknowledgment names the deadline")
    equal(protocol:Encode(control("PLAN_ACK", { venueID = "Bad|ID", deadline = 1 })), nil, "plan acknowledgment venue validated")
    equal(protocol:Encode(control("PLAN_REJECT", {})), nil, "plan rejection names its venue")
    for _, flags in ipairs({ -1, 4, 0.5, "1" }) do
        equal(protocol:Encode(control("STATUS", { mapID = 1, continentID = 0, x = 0, y = 0, flags = flags })), nil,
            "invalid status flags " .. tostring(flags))
    end
    equal(protocol:Encode(control("STATUS", { mapID = 0, continentID = 1, x = 0, y = 0, flags = 0 })), nil,
        "status unknown position cannot carry a continent")
    equal(protocol:Encode(control("CANCEL", { reason = "NO_SHOW" })), nil, "unknown cancellation reason")
    local largestPlan = protocol:Encode(changedPlan({ session = string.rep("a", 32), peerSession = string.rep("b", 32),
        ticket = string.rep("c", 80), venueID = string.rep("d", 48),
        deadline = 4102444800, mapID = 100000, continentID = 100000, x = -1000000, y = -1000000 }))
    equal(#largestPlan <= 255, true, "largest control schema remains under native byte limit")
    equal(type(protocol:Decode(largestPlan)), "table", "largest valid control packet round-trips")

    for _, payload in ipairs({
        "", string.rep("a", 256), "FDQ1|QUERY", "FQ1|QUERY", "FQ3|QUERY", "FQ2|UNKNOWN", "FQ2|QUERY|",
        "FQ2|QUERY|unexpected", encoded .. "|unexpected", "|" .. encoded,
        encoded:sub(1, #encoded - 5), encoded:gsub("1500", "01500", 1),
        encoded:gsub("1500", "1e3", 1), encoded:gsub("1500", "+1500", 1),
        encoded:gsub("1500", "1500.0", 1), encoded:gsub("1500", "-0", 1),
        encoded:gsub("1500", " 1500", 1), encoded:gsub("1500", "100001", 1),
        encoded:gsub("1500", "", 1), encoded:gsub("PVP", "PV\nP", 1),
        encoded:gsub("PVP", "PV\195\164P", 1), encoded:gsub("PVP", "PV\0P", 1),
        encoded:gsub("1791100000", "4102444801", 1), encoded:gsub("%-1000", "-01000", 1),
    }) do equal(protocol:Decode(payload), nil, "reject malformed queue wire payload") end
    equal(protocol:Decode("FDQ1|ACK|abcd-1234|abcd-5678|ab.cd-1234-5678"), nil, "old protocol 1 control packets are ignored")
    equal(protocol:Decode(nil), nil, "nil wire payload")
    equal(protocol:Decode({}), nil, "table wire payload")
    local planWire = protocol:Encode(control("PLAN", plan))
    equal(protocol:Decode(planWire .. "|0"), nil, "frozen venue wire rejects extra coordinate")
    local fd2 = FD.Protocol:Encode({ kind = "HELLO", nonce = "ab", echo = "-", guid = base.guid,
        peerGUID = "Player-1234-0000DCBA", role = "INCOMING", rating = 1500, specId = 0,
        classFile = "MAGE", wins = 0, losses = 0, verdict = "-", level = 30, maxLevel = 60 })
    equal(protocol:Decode(fd2), nil, "duel packets cannot become queue packets")
    equal(FD.Protocol:Decode(encoded), nil, "queue packets cannot become consent packets")

    local recordedVenue = {
        kind = "VENUE", venueID = "tested-spot.1", testPairGUID = base.guid,
        mapID = 1429, continentID = 0, mapX = 12345678, mapY = 98765432,
        minPlayerLevel = 1, zoneMinLevel = 1, zoneMaxLevel = 10,
        faction = "Alliance", hubFaction = "NONE", testedAt = 1791100000,
    }
    local function venue(changes)
        local result = {}
        for key, value in pairs(recordedVenue) do result[key] = value end
        for key, value in pairs(changes or {}) do result[key] = value end
        return result
    end
    local venueWire = roundTrip(recordedVenue)
    roundTrip(venue({ mapX = 0, mapY = protocol.MAP_SCALE, hubFaction = "Alliance" }))
    roundTrip(venue({ faction = "Horde", hubFaction = "Horde", mapID = 1411, continentID = 1,
        minPlayerLevel = 255, zoneMinLevel = 255, zoneMaxLevel = 255, testedAt = 4102444800 }))
    local largestVenue = protocol:Encode(venue({ venueID = string.rep("a", 48),
        testPairGUID = "Player-" .. string.rep("a", 28) .. "-" .. string.rep("b", 28),
        mapID = 100000, continentID = 100000, mapX = protocol.MAP_SCALE, mapY = protocol.MAP_SCALE,
        minPlayerLevel = 255, zoneMinLevel = 255, zoneMaxLevel = 255, testedAt = 4102444800,
        faction = "Alliance", hubFaction = "Alliance" }))
    equal(#largestVenue <= 255, true, "largest venue setup record fits native addon wire")
    equal(type(protocol:Decode(largestVenue)), "table", "largest setup record round-trips")
    equal(protocol:Encode(venue({ fullName = "Native-Forever", verified = true, name = "Local map label", rated = true })),
        venueWire, "setup transport never serializes trust flags or rated evidence")
    equal(FD.Protocol:Decode(venueWire), nil, "venue setup cannot become rated duel consent")
    for key, values in pairs({
        venueID = { "", "Uppercase", "a|b", string.rep("a", 49) },
        testPairGUID = { "", "Creature-1-AB", "Player--AB", "Player-1-GHI", string.rep("a", 65) },
        mapID = { 0, -1, 100001, 1.1, "1429" },
        continentID = { -1, 100001, 0.1, "0" },
        mapX = { -1, 100000001, 0.1, "12345678", math.huge, 0 / 0 },
        mapY = { -1, 100000001, 0.1, "98765432", math.huge, 0 / 0 },
        minPlayerLevel = { 0, 256, 1.1, "1" },
        zoneMinLevel = { 0, 11, 256, 1.1, "1" },
        zoneMaxLevel = { 0, 256, 10.1, "10" },
        faction = { "", "Neutral", "alliance", "Alliance|Horde" },
        hubFaction = { "", "none", "Horde", "UNKNOWN" },
        testedAt = { -1, 4102444801, 0.1, "1791100000", math.huge },
    }) do
        for _, value in ipairs(values) do equal(protocol:Encode(venue({ [key] = value })), nil, "invalid setup " .. key) end
    end
    for key in pairs(recordedVenue) do
        local missing = venue(); missing[key] = nil
        equal(protocol:Encode(missing), nil, "venue setup requires " .. key)
    end
    for _, payload in ipairs({
        venueWire .. "|rated", venueWire .. "|", venueWire:gsub("12345678", "012345678", 1),
        venueWire:gsub("12345678", "0.12345678", 1), venueWire:gsub("12345678", "1e7", 1),
        venueWire:gsub("12345678", "-0", 1), venueWire:gsub("NONE", "NO\nNE", 1),
        venueWire:gsub("NONE", "NO\195\164NE", 1), venueWire:gsub("98765432", "100000001", 1),
    }) do equal(protocol:Decode(payload), nil, "setup wire is strict canonical ASCII") end

    -- Acknowledged venue sharing.
    roundTrip({ kind = "VENUE_ACK", venueID = "test-1-2-3-a", keptID = "test-1-2-3-a" })
    roundTrip({ kind = "VENUE_ACK", venueID = "test-1-2-3-a", keptID = "test-1-2-2-a" })
    for code in pairs(protocol.VENUE_REJECTIONS) do
        roundTrip({ kind = "VENUE_REJECT", venueID = "test-1-2-3-a", reason = code })
    end
    equal(protocol:Encode({ kind = "VENUE_REJECT", venueID = "test-1-2-3-a", reason = "SECRET" }), nil, "unknown venue rejection")
    equal(protocol:Encode({ kind = "VENUE_ACK", venueID = "test-1-2-3-a" }), nil, "venue acknowledgment names the kept ID")
    equal(protocol:Encode({ kind = "VENUE_ACK", venueID = "Bad", keptID = "ok" }), nil, "venue acknowledgment IDs validated")
end
