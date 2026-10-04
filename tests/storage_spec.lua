return function(FD, equal)
    local a = { guid = "Player-1-AAA", name = "Alpha", realm = "Forever", classFile = "MAGE", level = 30, maxLevel = 60 }
    local b = { guid = "Player-1-BBB", name = "Beta", realm = "Forever", classFile = "ROGUE", level = 30, maxLevel = 60 }
    local function record(id, before, opponentBefore, won, player, opponent)
        player, opponent = player or a, opponent or b
        local after, delta = FD.Rating:Calculate(before, opponentBefore, won, player.level, opponent.level)
        return {
            schemaVersion = FD.C.SCHEMA_VERSION,
            protocolVersion = FD.C.PROTOCOL_VERSION,
            matchId = id,
            player = FD.Database:Copy(player), opponent = FD.Database:Copy(opponent),
            bracket = FD.Rating:Bracket(player.level, player.maxLevel),
            startedAt = 100, endedAt = 130,
            winnerGUID = won and a.guid or b.guid, loserGUID = won and b.guid or a.guid,
            result = won and "WIN" or "LOSS",
            ratingBefore = before, opponentRatingBefore = opponentBefore,
            ratingAfter = after, ratingDelta = delta,
            ratedConfirmed = true,
            evidence = { agreedBeforeStart = true, localResult = true, peerResult = true },
        }
    end

    equal(FD.Rating:GetInitialRating(), 1500, "initial rating")
    local after, delta = FD.Rating:Calculate(1500, 1500, true)
    equal(after, 1516, "equal-rating win")
    equal(delta, 16, "equal-rating win delta")
    after, delta = FD.Rating:Calculate(1500, 1500, false)
    equal(after, 1484, "equal-rating loss")
    equal(delta, -16, "equal-rating loss delta")
    for _, ratings in ipairs({ { 1200, 1800 }, { 1800, 1200 }, { 0, 0 }, { -500, 2000 } }) do
        local winnerAfter, winDelta = FD.Rating:Calculate(ratings[1], ratings[2], true)
        local loserAfter, lossDelta = FD.Rating:Calculate(ratings[2], ratings[1], false)
        equal(winDelta, -lossDelta, "complementary deltas")
        equal(winnerAfter + loserAfter, ratings[1] + ratings[2], "rating conservation")
    end
    equal(FD.Rating:Calculate("1500", 1500, true), nil, "reject string rating")
    equal(FD.Rating:Calculate(1500, 1500, "WIN"), nil, "reject nonboolean result")
    equal(FD.Rating:Calculate(0 / 0, 1500, true), nil, "reject NaN")

    local db = FD.Database:Initialize(nil, a)
    local stats = db.player.ratings.LEVELING
    equal(stats.rating, 1500, "fresh database")
    equal(FD.Database:GetStats(), stats, "current leveling pool")
    equal(FD.Database:GetStats("MAX_LEVEL").rating, 1500, "fresh max-level pool")
    equal(FD.Database:GetStats("LEGACY"), nil, "fresh database has no legacy pool")
    equal(db.player.rating, nil, "no ambiguous current-rating alias")
    equal(FD.Database:NextCounter(), 1, "first nonce counter")
    equal(FD.Database:NextCounter(), 2, "second nonce counter")
    local first = record("one", 1500, 1500, true)
    equal(FD.Database:Commit(first), true, "commit win")
    equal(stats.rating, 1516, "committed rating")
    equal(stats.wins, 1, "committed win")
    equal(stats.losses, 0, "no loss added")
    first.player.name = "Changed"
    first.evidence.localResult = false
    equal(db.matches[1].player.name, "Alpha", "stored identity immutable")
    equal(db.matches[1].evidence.localResult, true, "stored evidence immutable")
    equal(FD.Database:Commit(first), false, "duplicate ignored")
    equal(#db.matches, 1, "duplicate has no new history")
    equal(stats.rating, 1516, "duplicate has no rating change")
    equal(FD.Database:Commit(record("stale", 1500, 1500, true)), nil, "stale snapshot rejected")

    local invalid = record("missing-agreement", 1516, 1500, true)
    invalid.evidence.agreedBeforeStart = false
    equal(FD.Database:Commit(invalid), nil, "pre-start agreement required")
    invalid = record("no-peer", 1516, 1500, true)
    invalid.evidence.peerResult = false
    equal(FD.Database:Commit(invalid), nil, "independent peer result required")
    invalid = record("no-local", 1516, 1500, true)
    invalid.evidence.localResult = false
    equal(FD.Database:Commit(invalid), nil, "independent local result required")
    invalid = record("unrated", 1516, 1500, true)
    invalid.ratedConfirmed = false
    equal(FD.Database:Commit(invalid), nil, "unrated cannot commit")
    invalid = record("wrong-winner", 1516, 1500, true)
    invalid.winnerGUID = b.guid
    equal(FD.Database:Commit(invalid), nil, "contradictory winner rejected")
    invalid = record("wrong-delta", 1516, 1500, true)
    invalid.ratingAfter = invalid.ratingAfter + 1
    equal(FD.Database:Commit(invalid), nil, "wrong Elo rejected")
    invalid = record("wrong-player", 1516, 1500, true)
    invalid.player.guid = "Player-1-CCC"
    equal(FD.Database:Commit(invalid), nil, "other character rejected")
    invalid = record("backward-time", 1516, 1500, true)
    invalid.endedAt = 99
    equal(FD.Database:Commit(invalid), nil, "negative duration rejected")
    invalid = record("cycle", 1516, 1500, true)
    invalid.extra = invalid
    equal(FD.Database:Commit(invalid), nil, "cyclic record rejected")
    invalid = record("wrong-bracket", 1516, 1500, true)
    invalid.bracket = "MAX_LEVEL"
    equal(FD.Database:Commit(invalid), nil, "contradictory bracket rejected")
    invalid = record("missing-level", 1516, 1500, true)
    invalid.player.level = nil
    equal(FD.Database:Commit(invalid), nil, "level evidence required")
    invalid = record("outside-level-range", 1516, 1500, true)
    invalid.opponent.level = 36
    equal(FD.Database:Commit(invalid), nil, "ineligible opponent rejected")
    invalid = record("different-cap", 1516, 1500, true)
    invalid.opponent.maxLevel = 80
    equal(FD.Database:Commit(invalid), nil, "different level cap rejected")
    equal(stats.rating, 1516, "invalid commits preserve rating")
    equal(#db.matches, 1, "invalid commits preserve history")

    equal(FD.Database:Commit(record("two", 1516, 1500, false)), true, "commit loss")
    equal(stats.wins, 1, "loss preserves wins")
    equal(stats.losses, 1, "loss counted")
    equal(#FD.History:Recent(), 2, "recent history count")
    equal(FD.History:Recent(1)[1].matchId, "two", "newest first")
    equal(#FD.History:Recent(0), 0, "zero recent count")
    equal(FD.History:Get("unknown"), nil, "unknown match")
    local queried = FD.History:Get("one")
    queried.player.name = "Mutated"
    equal(FD.History:Get("one").player.name, "Alpha", "history returns copies")

    local reloaded = FD.Database:Copy(db)
    equal(FD.Database:Initialize(reloaded, a), reloaded, "reload preserves saved database")
    equal(FD.Database:Commit(record("one", 1500, 1500, true)), false, "duplicate rejected after reload")
    equal(FD.Database:NextCounter(), 3, "nonce survives reload")
    reloaded.settings.debug = true
    local reset = FD.Database:Reset(a)
    equal(reset.player.ratings.LEVELING.rating, 1500, "reset rating")
    equal(reset.player.ratings.MAX_LEVEL.rating, 1500, "reset max-level rating")
    equal(#reset.matches, 0, "reset history")
    equal(reset.nonceCounter, 3, "reset preserves nonce counter")
    equal(reset.settings.debug, true, "reset preserves settings")

    local future = { schemaVersion = FD.C.SCHEMA_VERSION + 1, sentinel = "preserve" }
    equal(FD.Database:Initialize(future, a), nil, "future database refused")
    equal(future.sentinel, "preserve", "future database untouched")
    equal(FD.Database.data, nil, "database disabled on bad schema")
    equal(FD.Database:Commit(record("disabled", 1500, 1500, true)), nil, "disabled writes fail")
    local broken = FD.Database:Copy(reloaded)
    broken.player.ratings.LEVELING.wins = 500
    equal(FD.Database:Initialize(broken, a), nil, "inconsistent saved wins refused")
    equal(broken.player.ratings.LEVELING.wins, 500, "bad database not silently reset")
    broken = FD.Database:Copy(reloaded)
    broken.matches[2] = nil
    broken.matches[3] = record("gap", 1516, 1500, false)
    equal(FD.Database:Initialize(broken, a), nil, "sparse history refused")
    broken = FD.Database:Copy(reloaded)
    broken.finalized.missing = true
    equal(FD.Database:Initialize(broken, a), nil, "orphan finalization refused")
    equal(FD.Database:Initialize(reloaded, b), nil, "different character database refused")
    local maxA, maxB = FD.Database:Copy(a), FD.Database:Copy(b)
    maxA.level, maxB.level = 60, 60
    db = FD.Database:Initialize(nil, a)
    equal(FD.Database:Commit(record("leveling-first", 1500, 1500, true)), true, "leveling chain starts independently")
    equal(FD.Database:SetBracket(maxA), "MAX_LEVEL", "reaching cap switches current pool")
    equal(FD.Database:GetStats().rating, 1500, "new max-level pool starts fresh")
    equal(FD.Database:Commit(record("max-first", 1500, 1500, false, maxA, maxB)), true, "max-level chain starts independently")
    equal(FD.Database:Commit(record("leveling-second", 1516, 1500, true)), true, "commit uses record bracket snapshot")
    equal(FD.Database:GetStats().rating, 1484, "leveling commit cannot affect max-level pool")
    equal(FD.Database:GetStats("LEVELING").wins, 2, "leveling totals independent")
    reloaded = FD.Database:Copy(db)
    equal(FD.Database:Initialize(reloaded, maxA), reloaded, "interleaved independent chains reload")
    equal(FD.Database.bracket, "MAX_LEVEL", "reload chooses current identity bracket")
    broken = FD.Database:Copy(reloaded)
    broken.player.ratings.MAX_LEVEL.rating = 1500
    equal(FD.Database:Initialize(broken, maxA), nil, "mismatched max-level totals rejected")
    broken = FD.Database:Copy(reloaded)
    broken.matches[3].ratingBefore = 1484
    equal(FD.Database:Initialize(broken, maxA), nil, "cross-pool chain substitution rejected")
    broken = FD.Database:Copy(reloaded)
    broken.player.ratings.UNKNOWN = { rating = 1500, wins = 0, losses = 0 }
    equal(FD.Database:Initialize(broken, maxA), nil, "unknown saved pool rejected")

    local legacyRecord = record("legacy-one", 1500, 1500, true)
    legacyRecord.schemaVersion, legacyRecord.protocolVersion, legacyRecord.bracket = 1, 1, nil
    legacyRecord.player.level, legacyRecord.player.maxLevel = nil, nil
    legacyRecord.opponent.level, legacyRecord.opponent.maxLevel = nil, nil
    local old = {
        schemaVersion = 1, player = { guid = a.guid, rating = 1516, wins = 1, losses = 0 },
        matches = { legacyRecord }, finalized = { ["legacy-one"] = true },
        settings = { debug = true, minimapAngle = 70 }, nonceCounter = 8,
    }
    local migrated = FD.Database:Initialize(old, maxA)
    equal(migrated.schemaVersion, FD.C.SCHEMA_VERSION, "legacy migrated to new schema")
    equal(migrated.player.ratings.LEVELING.rating, 1500, "old rating not guessed into leveling")
    equal(migrated.player.ratings.MAX_LEVEL.rating, 1500, "old rating not guessed into max level")
    equal(#migrated.matches, 0, "new history separate")
    equal(migrated.legacy.matches[1].matchId, "legacy-one", "legacy match retained")
    equal(migrated.legacy.matches[1].player.level, nil, "historical level never invented")
    equal(FD.Database:GetStats("LEGACY").rating, 1516, "legacy stats remain accessible")
    equal(migrated.nonceCounter, 8, "legacy nonce continuity retained")
    equal(migrated.settings.minimapAngle, 70, "legacy settings carried forward")
    equal(old.schemaVersion, 1, "original legacy data untouched")
    equal(old.player.ratings, nil, "original old player untouched")
    old.matches[1].player.name = "External change"
    equal(migrated.legacy.matches[1].player.name, "Alpha", "legacy snapshot deeply copied")
    migrated.settings.debug = false
    equal(migrated.legacy.settings.debug, true, "legacy settings isolated from active settings")
    equal(FD.Database:Commit(record("legacy-one", 1500, 1500, true, maxA, maxB)), false, "legacy match cannot be rerated")
    equal(FD.Database:Commit(record("new-max", 1500, 1500, true, maxA, maxB)), true, "new pool accepts fresh match")
    reloaded = FD.Database:Copy(migrated)
    equal(FD.Database:Initialize(reloaded, maxA), reloaded, "migrated database reloads")
    broken = FD.Database:Copy(reloaded)
    broken.legacy.player.wins = 9
    equal(FD.Database:Initialize(broken, maxA), nil, "damaged embedded legacy data rejected")
    equal(broken.legacy.player.wins, 9, "damaged legacy data preserved")
    broken = FD.Database:Copy(reloaded)
    broken.nonceCounter = 7
    equal(FD.Database:Initialize(broken, maxA), nil, "nonce cannot regress past legacy archive")
    broken = FD.Database:Copy(old)
    broken.player.rating = 1700
    equal(FD.Database:Initialize(broken, maxA), nil, "invalid legacy chain cannot migrate")
    equal(broken.schemaVersion, 1, "invalid legacy schema not overwritten")
    equal(broken.player.rating, 1700, "invalid legacy totals preserved")
    FD.Database:Initialize(reloaded, maxA)
    reset = FD.Database:Reset(a)
    equal(reset.legacy, nil, "confirmed full reset also clears legacy archive")
    equal(FD.Database.bracket, "LEVELING", "reset updates current bracket")
    equal(FD.Database:GetStats().rating, 1500, "reset chooses identity pool")
    local invalidIdentity = FD.Database:Copy(a)
    invalidIdentity.level = nil
    db = FD.Database:Initialize(nil, invalidIdentity)
    equal(type(db), "table", "unknown runtime level still permits storage initialization")
    equal(FD.Database.bracket, nil, "unknown runtime level leaves current bracket unknown")
    equal(FD.Database:GetStats().rating, 1500, "unknown runtime level has safe display fallback")
    equal(FD.Rating:Eligible(invalidIdentity, b), nil, "unknown runtime level still blocks rated play")
    equal(FD.Database:Initialize(reloaded, invalidIdentity), reloaded, "unknown runtime level preserves saved history")
    equal(type(FD.Database:Reset(invalidIdentity)), "table", "reset does not require runtime level data")
    equal(FD.Database.bracket, nil, "reset retains unknown bracket until level data arrives")
    equal(FD.Database:SetBracket(maxA), "MAX_LEVEL", "late level data resolves active bracket")
    equal(FD.Database:GetStats().rating, 1500, "late level data selects matching stats")
    db = FD.Database:Initialize(nil, a)
    local higherOpponent = FD.Database:Copy(b)
    higherOpponent.level = 35
    local weighted = record("weighted", 1500, 1500, true, a, higherOpponent)
    equal(weighted.ratingDelta, 20, "record uses level-weighted result")
    local unweighted = FD.Database:Copy(weighted)
    unweighted.ratingAfter, unweighted.ratingDelta = 1516, 16
    equal(FD.Database:Commit(unweighted), nil, "old unweighted formula cannot commit new match")
    equal(FD.Database:Commit(weighted), true, "weighted match commits")
    reloaded = FD.Database:Copy(db)
    equal(FD.Database:Initialize(reloaded, a), reloaded, "weighted evidence survives reload")
    broken = FD.Database:Copy(reloaded)
    broken.matches[1].opponent.level = 30
    equal(FD.Database:Initialize(broken, a), nil, "changed historical level invalidates weighted chain")
    FD.Database:Initialize(nil, a)
end
