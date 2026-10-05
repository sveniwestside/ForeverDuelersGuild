return function(FD, equal)
    if not FD.Venues then assert(loadfile("ForeverDuel/Venues.lua"))("ForeverDuel", FD) end
    local venues = FD.Venues
    local function player(changes)
        local result = { faction = "Horde", level = 30, scope = "RULESET", mapID = 10, continentID = 0, x = 0, y = 0 }
        for key, value in pairs(changes or {}) do result[key] = value end
        return result
    end
    local function venue(changes)
        local result = { id = "test-a", name = "Verified fictional test clearing", mapID = 10,
            continentID = 0, x = 0, y = 0, factions = { Horde = true, Alliance = true },
            minPlayerLevel = 1, zoneMinLevel = 1, zoneMaxLevel = 10, verified = true, duelAllowed = true }
        for key, value in pairs(changes or {}) do result[key] = value end
        return result
    end
    local a, b = player(), player({ x = 1000 })
    equal(next(venues.Catalog), nil, "untested outdoor sites are never shipped as verified")
    local selected, duration, reason = venues:Select(a, b)
    equal(selected, nil, "empty live catalog fails closed")
    equal(reason, "NO_VENUE", "empty catalog diagnostic")

    local env = { catalog = { venue({ id = "test-b", x = 600 }), venue({ x = 400 }) } }
    selected, duration = venues:Select(a, b, env)
    equal(selected.id, "test-a", "equidistant midpoint tie uses stable venue ID")
    equal(duration, 300, "minimum travel allowance is five minutes")
    equal(selected ~= env.catalog[2], true, "selected venue is copied")
    selected.factions.Horde = false
    equal(env.catalog[2].factions.Horde, true, "nested selection metadata is copied")
    selected = venues:Select(a, b, { catalog = { venue({ x = 480 }), venue({ id = "test-b", x = 510 }) } })
    equal(selected.id, "test-b", "nearest midpoint beats catalog order")
    selected = venues:Select(a, b, { catalog = { venue({ x = 500, factions = { Alliance = true } }),
        venue({ id = "horde-safe", x = 550, factions = { Horde = true } }) } })
    equal(selected.id, "horde-safe", "Horde is never sent to an Alliance-only place")
    equal(venues:Eligible(venue(), a, player({ faction = "Alliance" })), false, "mixed factions cannot group")
    equal(venues:Eligible(venue(), a, player({ faction = "Neutral" })), false, "unknown faction rejected")
    equal(venues:Eligible(venue({ verified = false }), a, b), false, "unverified site rejected")
    equal(venues:Eligible(venue({ verified = 1 }), a, b), false, "verification is an explicit boolean")
    equal(venues:Eligible(venue({ duelAllowed = false }), a, b), false, "duel-prohibited site rejected")
    equal(venues:Eligible(venue({ minPlayerLevel = 31 }), a, b), false, "both players satisfy tested minimum level")
    equal(venues:Eligible(venue({ minPlayerLevel = 31 }), player({ level = 40 }), b), false, "weaker player's safety threshold matters")
    equal(venues:Eligible(venue({ zoneMinLevel = 1, zoneMaxLevel = 10 }), player({ level = 60 }), player({ level = 60 })),
        true, "higher-level players may use safe lower-level zones")
    equal(venues:Eligible(venue({ minPlayerLevel = 20, zoneMinLevel = 30, zoneMaxLevel = 40 }), a, b),
        true, "tested safe minimum can be below surrounding zone range")
    equal(venues:Eligible(venue({ zoneMinLevel = 30, zoneMaxLevel = 20 }), a, b), false, "malformed zone level range rejected")
    equal(venues:Eligible(venue({ factions = { Horde = 1 } }), a, b), false, "faction permission is explicit")
    equal(venues:Eligible(venue(), nil, b), false, "missing player rejected")
    equal(venues:Eligible(nil, a, b), false, "missing site rejected")

    local zoneA, zoneB = player({ scope = "ZONE" }), player({ scope = "ZONE" })
    equal(venues:Eligible(venue(), zoneA, zoneB), true, "same-zone venue accepted")
    equal(venues:Eligible(venue({ mapID = 11 }), zoneA, zoneB), false, "zone scope disallows a neighboring zone")
    equal(venues:Eligible(venue(), zoneA, player({ scope = "ZONE", mapID = 11 })), false, "both zone preferences enforced")
    equal(venues:Eligible(venue({ mapID = 11 }), player({ scope = "CONTINENT" }), player({ scope = "CONTINENT" })),
        true, "continent scope permits neighboring zone")
    equal(venues:Eligible(venue({ continentID = 1 }), player({ scope = "CONTINENT" }), b), false,
        "one continent preference restricts venue")
    equal(venues:Eligible(venue(), player({ scope = "INVALID" }), b), false, "invalid preference rejected")
    selected = venues:Select(a, b, { catalog = { venue({ id = "other-world", continentID = 1, x = 500 }) } })
    equal(selected, nil, "same-world midpoint never picks a different world")

    env = { catalog = { venue({ x = 0 }) } }
    _, duration = venues:Select(player({ x = -2100 }), player({ x = 2100 }), env)
    equal(duration, 570, "foot estimate uses seven yards per second plus buffer")
    _, duration = venues:Select(player({ level = 39, x = -2100 }), player({ level = 39, x = 2100 }), env)
    equal(duration, 570, "level 39 still uses walking speed")
    _, duration = venues:Select(player({ level = 40, x = -2100 }), player({ level = 40, x = 2100 }), env)
    equal(duration, 402, "level 40 assumes a normal mount and rounds time upward")
    _, duration = venues:Select(player({ level = 60, x = -2100 }), player({ level = 60, x = 2100 }), env)
    equal(duration, 402, "maximum level makes no faster mount assumption")
    _, duration = venues:Select(player({ level = 39, x = -2100 }), player({ level = 40, x = 3000 }), env)
    equal(duration, 570, "slower travel estimate determines shared deadline")
    _, duration = venues:Select(player({ x = -3640 }), player({ x = 3640 }), env)
    equal(duration, 900, "exact fifteen-minute travel limit is accepted")
    selected, _, reason = venues:Select(player({ x = -3641 }), player({ x = 3641 }), env)
    equal(selected, nil, "travel beyond fifteen minutes is excluded")
    equal(reason, "NO_VENUE", "all overly distant sites keep search open")
    selected = venues:Select(player({ x = 0 }), player({ level = 40, x = 8000 }), { catalog = {
        venue({ id = "near-midpoint", x = 4000 }), venue({ id = "travel-valid", x = 3600 }) } })
    equal(selected.id, "travel-valid", "duration filter precedes midpoint selection")
    selected, _, reason = venues:Select(player({ mapID = 0 }), b, env)
    equal(selected, nil, "unknown map has no travel plan")
    equal(reason, "NO_POSITION", "unknown position diagnostic")
    equal(venues:Select(player({ x = math.huge }), b, env), nil, "infinite position rejected")
    equal(venues:Select(player({ x = 0 / 0 }), b, env), nil, "NaN position rejected")

    local crossB = player({ continentID = 1 })
    env = { catalog = { venue({ id = "normal-clearing" }), venue({ id = "horde-hub", hubFaction = "Horde", x = 99999 }) } }
    selected, duration = venues:Select(a, crossB, env)
    equal(selected.id, "horde-hub", "cross-continent travel uses faction's approved capital exterior")
    equal(duration, 900, "cross-continent travel is a fixed fifteen minutes")
    selected, _, reason = venues:Select(player({ scope = "CONTINENT" }), crossB, env)
    equal(selected, nil, "cross-continent match requires both ruleset scopes")
    equal(reason, "CROSS_CONTINENT_SCOPE", "cross-continent preference diagnostic")
    equal(venues:Select(a, player({ scope = "ZONE", continentID = 1 }), env), nil, "peer also permits ruleset travel")
    equal(venues:Select(a, crossB, { catalog = { venue({ hubFaction = "Alliance" }) } }), nil,
        "cross-continent hub must belong to player's faction")
    equal(venues:Select(a, crossB, { catalog = { venue({ hubFaction = "Horde", minPlayerLevel = 40 }) } }), nil,
        "cross-continent hub still observes level safety")
    equal(venues:Select(a, crossB, { catalog = { venue({ hubFaction = "Horde", verified = false }) } }), nil,
        "unverified capital exterior remains excluded")
    selected = venues:Select(player({ faction = "Alliance" }), player({ faction = "Alliance", continentID = 1 }),
        { catalog = { venue({ id = "alliance-hub", hubFaction = "Alliance" }), venue({ id = "horde-hub", hubFaction = "Horde" }) } })
    equal(selected.id, "alliance-hub", "Allianz uses its own hub")

    local mapped = venue({ id = "mapped", mapX = 0.25, mapY = 0.75 })
    mapped.x, mapped.y = nil, nil
    local calls = 0
    env = { catalog = { mapped }, world = function(mapID, x, y)
        calls = calls + 1
        equal(mapID, 10, "world conversion uses venue map")
        equal(x, 0.25, "world conversion uses normalized X")
        equal(y, 0.75, "world conversion uses normalized Y")
        return 0, -1000.25, 2500.5
    end }
    local resolved = venues:Resolve("mapped", env)
    equal(resolved.x, -1000.25, "map coordinates converted to comparable world X")
    equal(resolved.y, 2500.5, "map coordinates converted to comparable world Y")
    equal(calls, 1, "one conversion per resolution")
    equal(mapped.x, nil, "resolution never mutates approved local catalog")
    resolved.factions.Horde = false
    equal(mapped.factions.Horde, true, "resolved faction table is copied")
    equal(venues:Resolve("missing", env), nil, "unknown venue ID rejected")
    equal(venues:Resolve(nil, env), nil, "missing venue ID rejected")
    equal(venues:Resolve("mapped", { catalog = { mapped } }), nil, "unavailable world converter fails closed")
    equal(venues:Resolve("mapped", { catalog = { mapped }, world = function() error("unavailable map") end }), nil,
        "conversion exception fails closed")
    equal(venues:Resolve("mapped", { catalog = { mapped }, world = function() return 1, 0, 0 end }), nil,
        "conversion must agree with approved world ID")
    equal(venues:Resolve("mapped", { catalog = { mapped }, world = function() return 0, math.huge, 0 end }), nil,
        "unreadable converted position rejected")
    equal(venues:Resolve("mapped", { catalog = { mapped }, world = function() return 0, 0 / 0, 0 end }), nil,
        "NaN converted position rejected")
    local badMap = venue({ id = "bad-map", mapX = 1.01, mapY = 0.75 })
    badMap.x, badMap.y = nil, nil
    equal(venues:Resolve("bad-map", { catalog = { badMap }, world = env.world }), nil, "out-of-range normalized point rejected")
    local before = calls
    equal(venues:Resolve("test-a", { catalog = { venue() }, world = env.world }).x, 0,
        "verified preconverted world coordinates supported")
    equal(calls, before, "preconverted records do not call native maps")
    equal(venues:Resolve("test-a", { catalog = { venue(), venue() } }), nil, "duplicate local venue IDs rejected")
    equal(venues:Select(a, b, { catalog = { venue(), venue() } }), nil, "duplicate local IDs cannot produce plans")
    equal(venues:Resolve("test-a", { catalog = { venue({ x = 1000001 }) } }), nil, "world coordinate bounds enforced")
    equal(venues:Resolve("bad|id", { catalog = { venue({ id = "bad|id" }) } }), nil, "wire-unsafe local venue ID rejected")
end
