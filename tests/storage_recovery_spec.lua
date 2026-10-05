-- Saved data that cannot be this character's history is kept, never silently
-- deleted, and never disables the addon for good: another character's table
-- is archived, unreadable data is quarantined by /duelrating repair, and a
-- reset keeps both.
return function(FD, equal)
    local clock
    local originalClock = GetServerTime
    GetServerTime = function() return clock end
    local function character(guid)
        return { guid = guid, name = "Alpha", realm = "Forever", classFile = "MAGE", level = 30, maxLevel = 60 }
    end
    local a = character("Player-1-AAA")
    local opponent = { guid = "Player-1-BBB", name = "Beta", realm = "Forever", classFile = "ROGUE", level = 30, maxLevel = 60 }
    local function commit(id, won, player)
        player = player or a
        local before = FD.Database:GetStats("LEVELING").rating
        local after, delta = FD.Rating:Calculate(before, 1500, won, player.level, opponent.level)
        return FD.Database:Commit({
            schemaVersion = FD.C.SCHEMA_VERSION, protocolVersion = 3, bracket = "LEVELING", matchId = id,
            player = FD.Database:Copy(player), opponent = FD.Database:Copy(opponent), startedAt = 100, endedAt = 130,
            winnerGUID = won and player.guid or opponent.guid, loserGUID = won and opponent.guid or player.guid,
            result = won and "WIN" or "LOSS", ratingBefore = before, opponentRatingBefore = 1500,
            ratingAfter = after, ratingDelta = delta, ratedConfirmed = true,
            evidence = { agreedBeforeStart = true, localResult = true, peerResult = true },
        })
    end
    local function reloads(db, identity, label)
        local copy, err = FD.Database:Copy(db)
        equal(err, nil, label .. " stays serializable")
        equal(FD.Database:Initialize(copy, identity), copy, label .. " reloads")
        return copy
    end
    local function count(map)
        local total = 0
        for _ in pairs(map) do total = total + 1 end
        return total
    end
    local function entries(value)
        local total = 0
        for _, child in pairs(value) do
            total = total + 1 + (type(child) == "table" and entries(child) or 0)
        end
        return total
    end

    -- A re-rolled character with the same name inherits the old file.
    clock = 1000
    local db = FD.Database:Initialize(nil, a)
    equal(commit("old-1", true), true, "old character history")
    equal(commit("old-2", false), true, "old character second result")
    db.settings.debug, db.settings.minimapAngle, db.nonceCounter = true, 70, 5
    local saved = FD.Database:Copy(db)
    local oldRating = saved.player.ratings.LEVELING.rating
    local reroll = character("Player-1-CCC")
    local fresh, reason = FD.Database:Initialize(saved, reroll)
    equal(type(fresh), "table", "re-rolled character loads instead of disabling the addon")
    equal(reason, nil, "archiving is not an error")
    equal(fresh ~= saved, true, "re-rolled character gets a new table")
    equal(fresh.player.guid, reroll.guid, "new table belongs to the new character")
    equal(#fresh.matches, 0, "new character inherits no rated history")
    equal(next(fresh.finalized), nil, "new character inherits no finalized matches")
    equal(FD.Database:GetStats().rating, 1500, "new character starts at the initial rating")
    equal(FD.Database.bracket, "LEVELING", "new character's pool is selected")
    local entry = fresh.archived[a.guid]
    equal(entry.archivedAt, 1000, "archive records the server time")
    equal(entry.truncated, nil, "readable data is archived completely")
    equal(entry.data.player.ratings.LEVELING.rating, oldRating, "archived rating kept")
    equal(entry.data.matches[2].matchId, "old-2", "archived history kept")
    equal(fresh.archivedNotice.guid, a.guid, "archive notice names the archived character")
    equal(fresh.archivedNotice.archivedAt, 1000, "archive notice carries the time")
    equal(fresh.settings.minimapAngle, 70, "settings follow the character name")
    equal(fresh.settings.debug, true, "debug setting carried over")
    equal(fresh.nonceCounter, 5, "nonce counter carried over")
    fresh.settings.minimapAngle = 10
    equal(entry.data.settings.minimapAngle, 70, "archive is a separate copy")
    equal(saved.player.guid, a.guid, "saved input untouched")
    equal(saved.archived, nil, "saved input gains no archive")
    equal(#saved.matches, 2, "saved input history untouched")
    equal(FD.Database:Kept().archives, 1, "one archive kept")
    equal(FD.Database:Kept().archivedNow, true, "archive is reported for this session")
    equal(commit("new-1", true, reroll), true, "re-rolled character can play rated")
    local reloaded = reloads(fresh, reroll, "database with an archive")
    equal(reloaded.archivedNotice, nil, "archive notice lasts one session")
    equal(reloaded.archived[a.guid].data.matches[1].matchId, "old-1", "archive survives reload")
    equal(FD.Database:Kept().archivedNow, false, "reloaded archive is no longer new")
    equal(FD.Database:Kept().archives, 1, "reloaded archive still counted")

    -- A long history is archived completely, however large it is.
    local long = FD.Database:Copy(saved)
    for index = 1, 3000 do
        local match = FD.Database:Copy(saved.matches[1])
        match.matchId = "long-" .. index
        long.matches[index], long.finalized[match.matchId] = match, true
    end
    equal(entries(long) > 100000, true, "fixture holds more than 100000 entries")
    local fromLong = FD.Database:Initialize(FD.Database:Copy(long), reroll)
    equal(fromLong.archived[a.guid].truncated, nil, "long history archived without cuts")
    equal(#fromLong.archived[a.guid].data.matches, 3000, "every archived match kept")
    equal(count(fromLong.archived[a.guid].data.finalized), count(long.finalized), "every finalization entry kept")
    reloads(fromLong, reroll, "database with a long archive")

    -- At most three archives; the oldest is dropped and archives never nest.
    local current, previous = reloaded, reroll
    for index, guid in ipairs({ "Player-1-DDD", "Player-1-EEE", "Player-1-FFF" }) do
        clock = 1000 + index * 100
        local nextCharacter = character(guid)
        current = FD.Database:Initialize(FD.Database:Copy(current), nextCharacter)
        equal(current.archived[previous.guid].archivedAt, clock, "each re-roll archives the previous character")
        previous = nextCharacter
    end
    equal(count(current.archived), 3, "at most three archives kept")
    equal(current.archived[a.guid], nil, "oldest archive dropped")
    for _, kept in pairs(current.archived) do equal(kept.data.archived, nil, "archives never nest") end
    equal(current.archived[reroll.guid].data.matches[1].matchId, "new-1", "kept archive retains its history")
    reloads(current, previous, "database with three archives")
    clock = nil
    local unclocked = character("Player-1-GGG")
    current = FD.Database:Initialize(FD.Database:Copy(current), unclocked)
    equal(type(current.archived[previous.guid]), "table", "archive without a server time is still kept")
    equal(current.archived[previous.guid].archivedAt, nil, "missing server time is not invented")
    equal(current.archived[reroll.guid], nil, "oldest dated archive makes room")
    equal(count(current.archived), 3, "limit holds without a server time")

    -- Old schema, damaged and future tables of another character.
    clock = 3000
    local legacyForeign = { schemaVersion = 1, player = { guid = "Player-1-OLD", rating = 1500, wins = 0, losses = 0 },
        matches = {}, finalized = {}, settings = { debug = false }, nonceCounter = 2 }
    local fromLegacy = FD.Database:Initialize(legacyForeign, a)
    equal(fromLegacy.archived["Player-1-OLD"].data.schemaVersion, 1, "foreign schema-1 table archived")
    equal(fromLegacy.legacy, nil, "foreign legacy pool is not migrated into this character")
    local damaged = FD.Database:Copy(saved)
    local node = damaged
    for _ = 1, 30 do node.next = {}; node = node.next end
    damaged.settings.bad = 0 / 0
    damaged.cycle = damaged
    damaged[1.5] = "fractional key"
    local rescued = FD.Database:Initialize(damaged, reroll)
    equal(type(rescued), "table", "damaged foreign data still lets the new character load")
    local salvaged = rescued.archived[a.guid]
    equal(salvaged.truncated, true, "dropped parts of foreign data are reported")
    equal(salvaged.data.matches[2].matchId, "old-2", "readable foreign history kept")
    equal(salvaged.data[1.5], nil, "invalid key dropped")
    equal(salvaged.data.cycle, nil, "cycle back to the original dropped")
    equal(salvaged.data.settings.bad, nil, "nonfinite value dropped")
    equal(rescued.settings.minimapAngle, nil, "unreadable settings are not carried over")
    equal(rescued.settings.debug, false, "unreadable settings replaced by defaults")
    reloads(rescued, reroll, "salvaged archive")
    -- An archive edited beyond the depth limit is cut when lifted on the next
    -- re-roll, and the cut is flagged; intact archives stay unflagged.
    local edited = FD.Database:Copy(fromLegacy)
    node = edited.archived["Player-1-OLD"].data
    for _ = 1, 20 do node.deep = {}; node = node.deep end
    local relifted = FD.Database:Initialize(edited, reroll)
    equal(relifted.archived["Player-1-OLD"].truncated, true, "cut archive flagged when lifted")
    equal(relifted.archived["Player-1-OLD"].data.schemaVersion, 1, "rest of the cut archive kept")
    equal(relifted.archived[a.guid].truncated, nil, "newly archived data is not flagged")
    local intact = FD.Database:Initialize(FD.Database:Copy(fromLong), character("Player-1-HHH"))
    equal(intact.archived[a.guid].truncated, nil, "lifting an intact archive cuts nothing")
    equal(#intact.archived[a.guid].data.matches, 3000, "lifted long archive keeps every match")
    local futureForeign = { schemaVersion = FD.C.SCHEMA_VERSION + 1, player = { guid = "Player-1-NEW" }, sentinel = true }
    local refused, refusal = FD.Database:Initialize(futureForeign, a)
    equal(refused, nil, "future data of another character is left alone")
    equal(refusal, "unsupported_database_version", "future data reason")
    equal(futureForeign.sentinel, true, "future data untouched")

    -- /duelrating repair quarantines unreadable data of this character.
    clock = 5000
    FD.Database:Initialize(nil, a)
    equal(commit("keep-1", true), true, "history before damage")
    FD.Database.data.settings.minimapAngle, FD.Database.data.nonceCounter = 33, 12
    local broken = FD.Database:Copy(FD.Database.data)
    broken.player.ratings.LEVELING.wins = 99
    local loaded, loadError = FD.Database:Initialize(broken, a)
    equal(loaded, nil, "damaged data disables rating until repaired")
    equal(loadError, "inconsistent_player_totals", "damage reason reported")
    local repaired, repairError = FD.Database:Repair(broken, a)
    equal(type(repaired), "table", "repair returns a fresh database")
    equal(repairError, nil, "repair succeeds")
    equal(FD.Database.data, nil, "repair alone does not activate the database")
    local quarantine = repaired.quarantine
    equal(quarantine.quarantineReason, "inconsistent_player_totals", "quarantine records why")
    equal(quarantine.quarantinedAt, 5000, "quarantine records when")
    equal(quarantine.truncated, nil, "readable damaged data is quarantined completely")
    equal(quarantine.data.player.ratings.LEVELING.wins, 99, "quarantine keeps the damaged values")
    equal(quarantine.data.matches[1].matchId, "keep-1", "quarantine keeps the history")
    equal(quarantine.data ~= broken, true, "quarantine is a copy")
    equal(#repaired.matches, 0, "repaired database starts without history")
    equal(repaired.player.ratings.LEVELING.rating, 1500, "repaired database starts at the initial rating")
    equal(repaired.settings.minimapAngle, 33, "readable settings survive repair")
    equal(repaired.nonceCounter, 12, "nonce counter survives repair")
    equal(broken.player.ratings.LEVELING.wins, 99, "repair leaves the saved input untouched")
    equal(broken.quarantine, nil, "saved input gains no quarantine")
    equal(FD.Database:Initialize(repaired, a), repaired, "repaired database loads")
    equal(FD.Database:Kept().quarantine.quarantineReason, "inconsistent_player_totals", "quarantine reported")
    equal(commit("after-repair", true), true, "rated play resumes after repair")
    repaired = reloads(repaired, a, "repaired database")
    equal(select(2, FD.Database:Repair(FD.Database:Copy(repaired), a)), "nothing_to_repair", "valid data is never quarantined")
    equal(select(2, FD.Database:Repair(nil, a)), "nothing_to_repair", "missing data needs no repair")
    equal(select(2, FD.Database:Repair(broken, nil)), "invalid_local_identity", "repair needs the character identity")

    local fromString = FD.Database:Repair("corrupt", a)
    equal(fromString.quarantine.data, "corrupt", "non-table saved value quarantined")
    equal(fromString.quarantine.quarantineReason, "unsupported_database_version", "non-table reason")
    equal(fromString.settings.debug, false, "default settings without readable ones")
    equal(fromString.nonceCounter, 0, "default counter without a readable one")
    local messy = FD.Database:Copy(broken)
    messy.settings = { debug = "yes", minimapAngle = 5 }
    messy.nonceCounter = -1
    local fromMessy = FD.Database:Repair(messy, a)
    equal(fromMessy.quarantine.quarantineReason, "invalid_database", "invalid settings reason")
    equal(fromMessy.settings.debug, false, "unreadable settings replaced")
    equal(fromMessy.settings.minimapAngle, nil, "unreadable settings not partly carried")
    equal(fromMessy.nonceCounter, 0, "invalid counter replaced")
    equal(fromMessy.quarantine.data.settings.debug, "yes", "quarantine keeps unreadable settings")
    local futureOwn = { schemaVersion = FD.C.SCHEMA_VERSION + 1, player = { guid = a.guid }, payload = "x" }
    equal(FD.Database:Initialize(futureOwn, a), nil, "own future data is not loaded")
    local fromFuture = FD.Database:Repair(futureOwn, a)
    equal(fromFuture.quarantine.quarantineReason, "unsupported_database_version", "explicit repair keeps future data aside")
    equal(fromFuture.quarantine.data.payload, "x", "future data copied into quarantine")

    -- The quarantine copy is bounded in depth and size.
    local hostile = { schemaVersion = 2, player = { guid = a.guid } }
    node = hostile
    for _ = 1, 40 do node.child = {}; node = node.child end
    hostile.cycle = hostile
    hostile.nan, hostile.inf = 0 / 0, math.huge
    hostile[true] = "boolean key"
    hostile[2.5] = "fractional key"
    hostile.fn = function() end
    hostile.meta = setmetatable({}, {})
    local fromHostile = FD.Database:Repair(hostile, a)
    local kept = fromHostile.quarantine.data
    equal(fromHostile.quarantine.truncated, true, "dropped parts reported")
    equal(kept.player.guid, a.guid, "readable parts kept")
    for _, key in ipairs({ "cycle", "nan", "inf", "fn", "meta", true, 2.5 }) do
        equal(kept[key], nil, "unserializable entry dropped")
    end
    local depth = 0
    node = kept
    while node.child do depth, node = depth + 1, node.child end
    equal(depth, 14, "nesting cut at the saved-data depth limit")
    equal(FD.Database:Initialize(fromHostile, a), fromHostile, "bounded quarantine reloads")
    local huge = { schemaVersion = 2, list = {} }
    for index = 1, 1000050 do huge.list[index] = index end
    local fromHuge = FD.Database:Repair(huge, a)
    local kept = count(fromHuge.quarantine.data.list)
    equal(fromHuge.quarantine.truncated, true, "oversized data reported as cut")
    equal(kept <= 1000000 and kept > 990000, true, "oversized data bounded")
    huge = nil
    local fromLong = FD.Database:Repair(long, a)
    equal(fromLong.quarantine.quarantineReason, "inconsistent_history", "long damaged history needs repair")
    equal(fromLong.quarantine.truncated, nil, "long damaged history quarantined completely")
    equal(#fromLong.quarantine.data.matches, 3000, "every quarantined match kept")

    -- Repair keeps archives found in the damaged table, outside the quarantine.
    local archivesBroken = FD.Database:Copy(current)
    archivesBroken.player.ratings.LEVELING.rating = 1
    equal(FD.Database:Initialize(archivesBroken, unclocked), nil, "damaged table with archives refused")
    local fromArchives = FD.Database:Repair(archivesBroken, unclocked)
    equal(count(fromArchives.archived), 3, "archives lifted out of the damaged table")
    equal(fromArchives.quarantine.data.archived, nil, "quarantine does not duplicate archives")
    reloads(fromArchives, unclocked, "repaired database with archives")

    -- Repeated repairs keep earlier quarantines side by side, never nested,
    -- and only the newest three.
    local again = FD.Database:Copy(repaired)
    for round = 1, 5 do
        clock = 7000 + round
        again.player.ratings.LEVELING.wins = 50 + round
        again = FD.Database:Repair(again, a)
        equal(again.quarantine.data.quarantine, nil, "previous quarantine lifted out of the new one")
        equal(again.quarantine.truncated, nil, "repeated repair keeps the damaged data completely")
        if round == 1 then
            equal(again.quarantine.earlier[1].quarantinedAt, 5000, "first quarantine moved to the earlier list")
            equal(again.quarantine.earlier[1].data.matches[1].matchId, "keep-1", "moved quarantine keeps its data")
            equal(again.quarantine.earlier[1].truncated, nil, "moving a quarantine cuts nothing")
        end
    end
    local earlier = again.quarantine.earlier
    equal(#earlier, 2, "two earlier quarantines kept beside the newest")
    equal(again.quarantine.quarantinedAt, 7005, "newest quarantine on top")
    equal(earlier[1].quarantinedAt, 7003, "older quarantines dropped first")
    equal(earlier[2].quarantinedAt, 7004, "earlier quarantines oldest first")
    equal(earlier[1].data.player.ratings.LEVELING.wins, 53, "each earlier quarantine keeps its own data")
    equal(earlier[1].earlier, nil, "earlier quarantines never nest")
    equal(earlier[2].data.quarantine, nil, "earlier quarantine data holds no quarantine")
    reloads(again, a, "database after repeated repairs")

    -- Reset clears this character's history only.
    clock = 6000
    local both = FD.Database:Initialize(FD.Database:Copy(repaired), a)
    both.archived = FD.Database:Copy(current.archived)
    both.settings.minimapAngle = 44
    local reset = FD.Database:Reset(a)
    equal(#reset.matches, 0, "reset clears history")
    equal(reset.player.ratings.LEVELING.rating, 1500, "reset clears rating")
    equal(reset.quarantine, both.quarantine, "reset keeps quarantined data")
    equal(reset.archived, both.archived, "reset keeps other characters' archives")
    equal(reset.settings.minimapAngle, 44, "reset keeps settings")
    equal(reset.player.initialRatings.LEVELING, 1500, "reset stores initial ratings")
    reloads(reset, a, "reset database with archives and quarantine")

    -- /duelrating status names what the file keeps.
    local function status()
        local lines = {}
        for _, provider in ipairs(FD.statusProviders) do
            for _, line in ipairs(provider.lines()) do lines[#lines + 1] = line end
        end
        return table.concat(lines, "\n")
    end
    local text = status()
    equal(text:find("3 archived earlier character(s)", 1, true) ~= nil, true, "status counts archives")
    equal(text:find("(inconsistent_player_totals)", 1, true) ~= nil, true, "status names the quarantine reason")
    FD.Database:Initialize(nil, a)
    equal(status(), "", "clean database adds no storage status")
    FD.Database.data = nil
    equal(status(), "", "unavailable database adds no storage status")

    GetServerTime = originalClock
    FD.Database:Initialize(nil, a)
end
