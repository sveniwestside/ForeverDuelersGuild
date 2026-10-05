-- Saved history must survive later tuning of the rating rules: loading checks
-- structure and the rating ledger, and recomputes a record only with the
-- rules stored in that record, never with today's constants.
return function(FD, equal)
    local a = { guid = "Player-1-AAA", name = "Alpha", realm = "Forever", classFile = "MAGE", level = 30, maxLevel = 60 }
    local b = { guid = "Player-1-BBB", name = "Beta", realm = "Forever", classFile = "ROGUE", level = 30, maxLevel = 60 }
    local function at(identity, level)
        local result = FD.Database:Copy(identity)
        result.level = level
        return result
    end
    local maxA, maxB = at(a, 60), at(b, 60)
    local original = FD.Database:Copy(FD.C)
    local function restore()
        for key, value in pairs(original) do FD.C[key] = value end
    end
    local function tune(changes)
        restore()
        for key, value in pairs(changes) do FD.C[key] = value end
    end

    -- A record shaped like the one Duel.lua finalizes, chained onto the
    -- current pool rating unless `before` overrides it.
    local function record(id, won, opponentBefore, player, opponent, protocol, rules, before)
        player, opponent = player or a, opponent or b
        local bracket = FD.Rating:Bracket(player.level, player.maxLevel)
        before = before or FD.Database:GetStats(bracket).rating
        local after, delta = FD.Rating:Calculate(before, opponentBefore, won, player.level, opponent.level, rules)
        return {
            schemaVersion = FD.C.SCHEMA_VERSION, protocolVersion = protocol or FD.C.PROTOCOL_VERSION,
            addonVersion = FD.C.VERSION, bracket = bracket, matchId = id,
            player = FD.Database:Copy(player), opponent = FD.Database:Copy(opponent),
            startedAt = 100, endedAt = 130,
            winnerGUID = won and player.guid or opponent.guid, loserGUID = won and opponent.guid or player.guid,
            result = won and "WIN" or "LOSS", ratingBefore = before, opponentRatingBefore = opponentBefore,
            ratingAfter = after, ratingDelta = delta, ratedConfirmed = true,
            evidence = { agreedBeforeStart = true, localResult = true, peerResult = true },
        }
    end
    local function loads(saved, identity, label)
        local loaded, reason = FD.Database:Initialize(FD.Database:Copy(saved), identity or a)
        equal(type(loaded), "table", label .. (reason and (" (" .. reason .. ")") or ""))
        return loaded
    end
    local function refused(saved, expected, label, identity)
        local copy = FD.Database:Copy(saved)
        local loaded, reason = FD.Database:Initialize(copy, identity or a)
        equal(loaded, nil, label)
        if expected then equal(reason, expected, label .. " reason") end
        equal(FD.Database.data, nil, label .. " leaves rating disabled")
    end

    -- New databases store their initial ratings; new records store their rules.
    local db = FD.Database:Initialize(nil, a)
    equal(db.player.initialRatings.LEVELING, 1500, "new database stores leveling initial rating")
    equal(db.player.initialRatings.MAX_LEVEL, 1500, "new database stores max-level initial rating")
    local first = record("first", true, 1500)
    equal(first.rules, nil, "duel records may omit rules")
    local committed, returned = FD.Database:Commit(first)
    equal(committed, true, "record without rules commits")
    equal(first.rules, nil, "commit never mutates the caller's record")
    local stored = db.matches[1].rules
    equal(stored.version, 1, "stored rules version")
    equal(stored.k, 32, "stored K factor")
    equal(stored.levelWeight, 20, "stored level weight")
    equal(stored.maxLevelDifference, 5, "stored maximum level difference")
    equal(stored.initialRating, 1500, "stored initial rating")
    equal(returned.rules.k, 32, "returned snapshot carries rules")
    returned.rules.k = 1
    equal(db.matches[1].rules.k, 32, "returned snapshot is isolated")
    local explicit = record("explicit-rules", false, 1600, a, at(b, 35))
    explicit.rules = FD.Rating:Rules()
    equal(FD.Database:Commit(explicit), true, "record with today's rules commits")
    local foreign = record("foreign-rules", true, 1500)
    foreign.rules = FD.Rating:Rules()
    foreign.rules.k = 24
    equal(select(2, FD.Database:Commit(foreign)), "invalid_record_rules", "new result cannot claim other rules")
    foreign.rules = "v1"
    equal(select(2, FD.Database:Commit(foreign)), "invalid_record_rules", "malformed rules rejected")

    -- The protocol version is recorded, not a load or commit gate.
    equal(FD.Database:Commit(record("protocol-two", true, 1450, a, at(b, 27), 2)), true, "protocol 2 result commits")
    equal(FD.Database:Commit(record("protocol-three", false, 1520, a, at(b, 33), 3)), true, "protocol 3 result commits")
    for _, invalid in ipairs({ "3", 0, 2.5, -1 }) do
        equal(FD.Database:Commit(record("bad-protocol", true, 1500, a, b, invalid)), nil, "invalid protocol version rejected")
    end
    equal(FD.Database:Commit(record("max-one", true, 1500, maxA, maxB, 3)), true, "max-level result commits")
    equal(#db.matches, 5, "fixture history")
    local saved = FD.Database:Copy(db)
    loads(saved, a, "protocol 2 and 3 records load together")
    local mixed = FD.Database:Copy(saved)
    mixed.matches[1].protocolVersion = 2
    mixed.matches[2].protocolVersion = 4
    loads(mixed, a, "later protocol versions do not block loading")

    -- Each rule constant can change after records exist.
    for _, changes in ipairs({ { K_FACTOR = 24 }, { LEVEL_RATING_WEIGHT = 10 }, { MAX_LEVEL_DIFFERENCE = 2 },
        { INITIAL_RATING = 1000 }, { K_FACTOR = 40, LEVEL_RATING_WEIGHT = 0, MAX_LEVEL_DIFFERENCE = 1, INITIAL_RATING = 1200 } }) do
        tune(changes)
        local names = {}
        for key in pairs(changes) do names[#names + 1] = key end
        local loaded = loads(saved, a, "history loads after changing " .. table.concat(names, "+"))
        equal(loaded.player.ratings.LEVELING.rating, saved.player.ratings.LEVELING.rating, "rule change keeps rating")
        equal(loaded.player.initialRatings.LEVELING, 1500, "rule change keeps stored initial rating")
        loads(saved, maxA, "history loads in max-level pool after rule change")
    end
    restore()

    -- After a K change, new results use the new rules and old ones keep theirs.
    tune({ K_FACTOR = 24 })
    db = loads(saved, a, "history loads with new K")
    local oldRules = FD.Rating:Rules()
    oldRules.k = 32
    equal(FD.Database:Commit(record("old-k", true, 1500, a, b, nil, oldRules)), nil, "result computed with old K cannot commit")
    local newK = record("new-k", true, 1500)
    equal(newK.ratingDelta, 12, "new K applies to new results")
    equal(FD.Database:Commit(newK), true, "result with new K commits")
    equal(db.matches[#db.matches].rules.k, 24, "new record keeps new K")
    equal(db.matches[1].rules.k, 32, "old record keeps old K")
    local twoRules = FD.Database:Copy(db)
    restore()
    loads(twoRules, a, "one chain mixing two rule sets loads after reverting the constant")
    tune({ K_FACTOR = 16 })
    loads(twoRules, a, "one chain mixing two rule sets loads under a third rule set")
    restore()

    -- A changed initial rating applies to new databases and resets only.
    tune({ INITIAL_RATING = 1000 })
    db = loads(saved, a, "history loads with new initial rating")
    equal(FD.Database:GetStats("MAX_LEVEL").rating, saved.player.ratings.MAX_LEVEL.rating, "existing pools keep their chain")
    local reset = FD.Database:Reset(a)
    equal(reset.player.initialRatings.LEVELING, 1000, "reset uses the new initial rating")
    equal(reset.player.ratings.LEVELING.rating, 1000, "reset pool starts at the new initial rating")
    equal(FD.Database:Commit(record("after-reset", true, 1000)), true, "new chain starts at the new initial rating")
    local newInitial = FD.Database:Copy(reset)
    restore()
    loads(newInitial, a, "chain from a stored 1000 start loads after INITIAL_RATING returns to 1500")
    FD.Database:Initialize(nil, a)
    equal(select(2, FD.Database:Commit(record("wrong-start", true, 1500, a, b, nil, nil, 1000))), "stale_rating_snapshot",
        "result not chained onto the pool's stored initial rating is refused as stale")

    -- Databases from before 0.6 have no initial ratings and no rules.
    local old = FD.Database:Copy(saved)
    old.player.initialRatings = nil
    for _, match in ipairs(old.matches) do match.rules = nil end
    loads(old, a, "pre-0.6 database loads")
    tune({ K_FACTOR = 10, LEVEL_RATING_WEIGHT = 50, MAX_LEVEL_DIFFERENCE = 0, INITIAL_RATING = 900 })
    db = loads(old, a, "pre-0.6 database loads after every constant changed")
    equal(db.player.initialRatings, nil, "loading never invents an initial-rating record")
    equal(FD.Database:GetStats("LEVELING").rating, saved.player.ratings.LEVELING.rating, "pre-0.6 rating preserved")
    restore()
    local emptyOld = FD.Database:Copy(FD.Database:Initialize(nil, a))
    emptyOld.player.initialRatings = nil
    tune({ INITIAL_RATING = 1000 })
    loads(emptyOld, a, "empty pre-0.6 pools at 1500 load after INITIAL_RATING changed")
    restore()

    -- Tampered ledgers are still rejected, with and without stored rules.
    for _, base in ipairs({ saved, old }) do
        local kind = base == saved and " (with rules)" or " (pre-0.6)"
        -- With stored rules, the recomputation may notice an edited
        -- starting rating before the chain check does.
        local chainReason = base == old and "inconsistent_history" or nil
        local broken = FD.Database:Copy(base)
        broken.matches[2].ratingBefore = broken.matches[2].ratingBefore + 1
        broken.matches[2].ratingAfter = broken.matches[2].ratingAfter + 1
        refused(broken, chainReason, "broken chain link rejected" .. kind)
        broken = FD.Database:Copy(base)
        broken.matches[1].ratingAfter = broken.matches[1].ratingAfter + 1
        refused(broken, "inconsistent_record_rating", "after not equal to before plus delta rejected" .. kind)
        broken = FD.Database:Copy(base)
        broken.matches[1].ratingDelta = -broken.matches[1].ratingDelta
        broken.matches[1].ratingAfter = broken.matches[1].ratingBefore + broken.matches[1].ratingDelta
        refused(broken, "inconsistent_record_rating", "win with a negative change rejected" .. kind)
        broken = FD.Database:Copy(base)
        broken.matches[1].ratingBefore, broken.matches[1].ratingAfter = 1400, 1400 + broken.matches[1].ratingDelta
        refused(broken, chainReason, "chain not starting at its initial rating rejected" .. kind)
        broken = FD.Database:Copy(base)
        broken.matches[3].matchId = broken.matches[2].matchId
        broken.finalized["protocol-two"] = nil
        refused(broken, "inconsistent_history", "duplicate match ID rejected" .. kind)
        broken = FD.Database:Copy(base)
        broken.matches[1].winnerGUID, broken.matches[1].loserGUID = b.guid, a.guid
        refused(broken, "contradictory_record_result", "swapped winner rejected" .. kind)
        broken = FD.Database:Copy(base)
        broken.finalized.first = nil
        refused(broken, "inconsistent_history", "missing finalization entry rejected" .. kind)
        broken = FD.Database:Copy(base)
        broken.finalized.invented = true
        refused(broken, "inconsistent_finalization_index", "orphan finalization entry rejected" .. kind)
        broken = FD.Database:Copy(base)
        broken.player.ratings.LEVELING.losses = broken.player.ratings.LEVELING.losses + 1
        refused(broken, "inconsistent_player_totals", "inflated totals rejected" .. kind)
        broken = FD.Database:Copy(base)
        broken.matches[5].bracket = "LEVELING"
        refused(broken, "invalid_record_bracket", "record moved to another pool rejected" .. kind)
        broken = FD.Database:Copy(base)
        broken.matches[2].opponent.maxLevel = 70
        refused(broken, "invalid_record_bracket", "opponent with another level cap rejected" .. kind)
    end
    local broken = FD.Database:Copy(saved)
    broken.player.initialRatings.LEVELING = 1400
    refused(broken, "inconsistent_history", "edited initial rating breaks the chain")
    for _, initial in ipairs({ "1500", { LEVELING = 1500 }, { LEVELING = 1500, MAX_LEVEL = 1500, LEGACY = 1500 },
        { LEVELING = 1500.5, MAX_LEVEL = 1500 } }) do
        broken = FD.Database:Copy(saved)
        broken.player.initialRatings = initial
        refused(broken, "invalid_initial_ratings", "malformed initial ratings rejected")
    end

    -- Records with rules are recomputed with exactly those rules.
    broken = FD.Database:Copy(saved)
    broken.matches[1].rules.k = 16
    refused(broken, "inconsistent_record_rating", "edited stored K invalidates its record")
    broken = FD.Database:Copy(saved)
    broken.matches[2].rules.maxLevelDifference = 2
    refused(broken, "level_difference_too_large", "record must be eligible under its own rules")
    broken = FD.Database:Copy(saved)
    broken.matches[2].opponent.level = 30
    refused(broken, "inconsistent_record_rating", "edited level snapshot invalidates its weighted record")
    broken = FD.Database:Copy(saved)
    broken.matches[1].ratingAfter, broken.matches[1].ratingDelta = 1532, 32
    broken.matches[2].ratingBefore = 1532
    refused(broken, "inconsistent_record_rating", "consistent but recomputable forgery rejected when rules are stored")
    for _, rules in ipairs({ "v1", { version = 0 }, { version = 1.5 }, { version = 1, k = "32", levelWeight = 20,
        maxLevelDifference = 5, initialRating = 1500 }, { version = 1, k = 32, levelWeight = 20,
        maxLevelDifference = -1, initialRating = 1500 } }) do
        broken = FD.Database:Copy(saved)
        broken.matches[1].rules = rules
        refused(broken, "invalid_record_rules", "malformed stored rules rejected")
    end
    local future = FD.Database:Copy(saved)
    future.matches[1].rules = { version = 2, formula = "glicko", tau = 0.5 }
    loads(future, a, "rules of a newer release load with ledger checks only")
    future.matches[1].ratingAfter = future.matches[1].ratingAfter + 1
    refused(future, "inconsistent_record_rating", "newer rules still need a consistent ledger")

    -- Legacy schema-1 migration still works, also after INITIAL_RATING changed.
    local legacyRecord = record("legacy-one", true, 1500, a, b, nil, nil, 1500)
    legacyRecord.schemaVersion, legacyRecord.protocolVersion, legacyRecord.bracket = 1, 1, nil
    legacyRecord.player.level, legacyRecord.player.maxLevel = nil, nil
    legacyRecord.opponent.level, legacyRecord.opponent.maxLevel = nil, nil
    local legacy = {
        schemaVersion = 1, player = { guid = a.guid, rating = 1516, wins = 1, losses = 0 },
        matches = { legacyRecord }, finalized = { ["legacy-one"] = true },
        settings = { debug = false }, nonceCounter = 3,
    }
    tune({ INITIAL_RATING = 1000, K_FACTOR = 10 })
    local migrated = loads(legacy, a, "schema-1 history migrates after rules changed")
    equal(migrated.legacy.player.rating, 1516, "legacy pool keeps its 1500-based chain")
    equal(migrated.player.initialRatings.LEVELING, 1000, "migrated pools record today's initial rating")
    equal(migrated.player.ratings.LEVELING.rating, 1000, "migrated pools start at today's initial rating")
    loads(migrated, a, "migrated database reloads")
    local tampered = FD.Database:Copy(legacy)
    tampered.matches[1].ratingAfter = 1517
    refused(tampered, "inconsistent_record_rating", "tampered legacy record still rejected")
    tampered = FD.Database:Copy(legacy)
    tampered.matches[1].ratingBefore, tampered.matches[1].ratingAfter = 1600, 1616
    tampered.player.rating = 1616
    refused(tampered, "inconsistent_history", "legacy chain must start at 1500")
    restore()
    FD.Database:Initialize(nil, a)
end
