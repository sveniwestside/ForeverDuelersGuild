return function(FD, equal)
    local player = { guid = "Player-1-AAA", name = "Alpha", realm = "Forever", classFile = "MAGE", level = 50, maxLevel = 60 }
    local opponent = { guid = "Player-1-BBB", name = "Beta", realm = "Forever", classFile = "ROGUE", level = 50, maxLevel = 60 }
    local function commit(id, won, opponentBefore, duration)
        local bracket = FD.Rating:Bracket(player.level, player.maxLevel)
        local before = FD.Database:GetStats(bracket).rating
        opponentBefore = opponentBefore or before
        local after, delta = FD.Rating:Calculate(before, opponentBefore, won, player.level, opponent.level)
        local record = {
            schemaVersion = FD.C.SCHEMA_VERSION, protocolVersion = FD.C.PROTOCOL_VERSION, bracket = bracket,
            matchId = id, player = FD.Database:Copy(player), opponent = FD.Database:Copy(opponent),
            confirmedAt = 95, countdownAt = 97, startedAt = 100, endedAt = 100 + (duration or 30),
            startSource = "localized-countdown-plus-timer", resultSource = "KNOCKOUT",
            winnerGUID = won and player.guid or opponent.guid,
            loserGUID = won and opponent.guid or player.guid,
            result = won and "WIN" or "LOSS", ratingBefore = before, ratingAfter = after,
            opponentRatingBefore = opponentBefore, ratingDelta = delta, ratedConfirmed = true,
            evidence = { agreedBeforeStart = true, localResult = true, peerResult = true },
        }
        equal(FD.Database:Commit(record), true, "history fixture is a valid finalized match")
    end

    local function emptyOverview(label)
        local overview = FD.History:Overview()
        equal(overview.rating, 1500, label .. " initial rating")
        equal(overview.wins, 0, label .. " zero wins")
        equal(overview.losses, 0, label .. " zero losses")
        equal(overview.total, 0, label .. " zero matches")
        equal(overview.winRate, nil, label .. " no invented zero-match win rate")
        equal(overview.peakRating, 1500, label .. " initial rating establishes peak")
        equal(overview.streakResult, nil, label .. " no empty streak result")
        equal(overview.streakCount, 0, label .. " empty streak count")
    end

    emptyOverview("uninitialized database")
    equal(FD.History:Details("unknown"), nil, "details unavailable before database initialization")
    local page = FD.History:Page(5, 2)
    equal(#page.matches, 0, "uninitialized page contains no matches")
    equal(page.page, 1, "uninitialized page clamps to first")
    equal(page.pages, 1, "empty history still has one display page")
    equal(page.total, 0, "uninitialized page total")
    equal(page.pageSize, 2, "uninitialized page retains requested size")

    FD.Database:Initialize(nil, player)
    emptyOverview("initialized empty database")
    page = FD.History:Page()
    equal(#page.matches, 0, "empty initialized history")
    equal(page.page, 1, "default first page")
    equal(page.pageSize, 8, "default page size")

    commit("first-loss", false)
    local overview = FD.History:Overview()
    equal(overview.rating, 1484, "loss changes overview current rating")
    equal(overview.peakRating, 1500, "initial rating remains peak after a loss")
    equal(overview.winRate, 0, "all losses have zero win rate")
    equal(overview.streakResult, "LOSS", "first loss starts loss streak")
    equal(overview.streakCount, 1, "first loss streak count")

    commit("win-one", true)
    commit("win-two", true)
    commit("win-three", true)
    overview = FD.History:Overview()
    equal(overview.rating, 1532, "overview current rating after wins")
    equal(overview.wins, 3, "overview cumulative wins")
    equal(overview.losses, 1, "overview cumulative losses")
    equal(overview.total, 4, "overview total rated matches")
    equal(overview.winRate, 75, "overview mixed win percentage")
    equal(overview.peakRating, 1532, "latest winning rating establishes peak")
    equal(overview.streakResult, "WIN", "win streak resets prior loss")
    equal(overview.streakCount, 3, "only newest consecutive wins count")

    commit("loss-one", false)
    commit("loss-two", false)
    overview = FD.History:Overview()
    equal(overview.rating, 1500, "current rating can fall below historic peak")
    equal(overview.peakRating, 1532, "peak survives subsequent losses")
    equal(overview.wins, 3, "loss streak preserves win total")
    equal(overview.losses, 3, "loss total updates")
    equal(overview.winRate, 50, "balanced result percentage")
    equal(overview.streakResult, "LOSS", "latest result controls streak kind")
    equal(overview.streakCount, 2, "streak stops at previous win")
    overview.rating, overview.wins, overview.streakCount = 0, 900, 99
    equal(FD.Database:GetStats().rating, 1500, "mutating overview cannot change rating")
    equal(FD.History:Overview().wins, 3, "overview returns isolated values")
    equal(FD.History:Overview().streakCount, 2, "mutating overview cannot change computed streak")

    FD.Database:Reset(player)
    for index = 1, 19 do commit("match-" .. index, index % 3 ~= 0) end
    page = FD.History:Page()
    equal(page.total, 19, "pagination reports all matches")
    equal(page.pages, 3, "partial final page included")
    equal(#page.matches, 8, "default first page is full")
    equal(page.matches[1].matchId, "match-19", "first page starts at newest match")
    equal(page.matches[8].matchId, "match-12", "first page boundary")
    local ids, seen = {}, {}
    for number = 1, page.pages do
        local section = FD.History:Page(number)
        equal(section.page, number, "requested in-range page retained")
        equal(section.total, 19, "page total is stable")
        equal(section.pages, 3, "page count is stable")
        for _, match in ipairs(section.matches) do
            equal(seen[match.matchId], nil, "match never repeated across pages")
            seen[match.matchId] = true
            ids[#ids + 1] = match.matchId
        end
    end
    equal(#ids, 19, "pagination omits no matches")
    for index, id in ipairs(ids) do equal(id, "match-" .. (20 - index), "all pages retain newest-first order") end
    local last = FD.History:Page(999)
    equal(last.page, 3, "high page clamps to last page")
    equal(#last.matches, 3, "final partial page size")
    equal(last.matches[3].matchId, "match-1", "last page includes oldest match")

    page.matches[1].opponent.name = "Changed"
    page.matches[1].evidence.localResult = false
    table.remove(page.matches, 2)
    local repeated = FD.History:Page()
    equal(repeated.matches[1].opponent.name, "Beta", "page deep-copies nested participant identity")
    equal(repeated.matches[1].evidence.localResult, true, "page deep-copies nested result evidence")
    equal(#repeated.matches, 8, "editing returned array does not alter later queries")
    equal(#FD.Database.data.matches, 19, "page edits preserve stored match count")
    equal(FD.Database.data.matches[1].matchId, "match-1", "page traversal does not sort stored history")

    for _, value in ipairs({ "2", false, {}, 0 / 0, math.huge, -math.huge }) do
        local invalid = FD.History:Page(value, value)
        equal(invalid.page, 1, "invalid page uses first page")
        equal(invalid.pageSize, 8, "invalid page size uses default")
        equal(#invalid.matches, 8, "invalid args still return bounded default page")
    end
    page = FD.History:Page(-5, -2)
    equal(page.page, 1, "negative page clamps to first")
    equal(page.pageSize, 1, "negative size clamps to one")
    equal(page.pages, 19, "one-match pages count correctly")
    page = FD.History:Page(0, 0)
    equal(page.page, 1, "zero page clamps to first")
    equal(page.pageSize, 1, "zero page size clamps to one")
    page = FD.History:Page(2.9, 3.9)
    equal(page.page, 2, "fractional page floors")
    equal(page.pageSize, 3, "fractional size floors")
    equal(page.matches[1].matchId, "match-16", "floored pagination uses correct offset")
    equal(page.matches[3].matchId, "match-14", "floored pagination uses correct boundary")
    page = FD.History:Page(1e100, 1e100)
    equal(page.page, 1, "huge finite page clamps to actual last page")
    equal(page.pageSize, 50, "huge finite size caps at fifty")
    equal(#page.matches, 19, "bounded size returns only existing matches")

    FD.Database:Reset(player)
    for index = 1, 16 do commit("even-" .. index, true) end
    equal(FD.History:Page().pages, 2, "exact page multiple has no phantom page")
    equal(#FD.History:Page(2).matches, 8, "exact final page contains all rows")
    overview = FD.History:Overview()
    equal(overview.winRate, 100, "all wins have full win rate")
    equal(overview.streakResult, "WIN", "all-win history streak kind")
    equal(overview.streakCount, 16, "streak can span entire history")

    FD.Database:Reset(player)
    equal(FD.History:Details("missing"), nil, "unknown match has no fabricated details")
    equal(FD.History:Details(nil), nil, "nil match ID has no details")
    equal(FD.History:Details({}), nil, "non-string match ID has no details")
    commit("detail-win", true, 1800, 45)
    local details = FD.History:Details("detail-win")
    equal(details.match.matchId, "detail-win", "details preserve the selected match")
    equal(details.duration, 45, "duration derives from saved start and finish")
    equal(details.winner.guid, player.guid, "winning local player mapped to winner identity")
    equal(details.loser.guid, opponent.guid, "losing peer mapped to loser identity")
    equal(details.playerRatingBefore, 1500, "player before uses saved local snapshot")
    equal(details.playerRatingAfter, 1527, "player after uses stored outcome")
    equal(details.playerRatingDelta, 27, "underdog win preserves positive local delta")
    equal(details.opponentRatingBefore, 1800, "peer before uses saved opponent snapshot")
    equal(details.opponentRatingAfter, 1773, "peer loss is calculated from its own starting rating")
    equal(details.opponentRatingDelta, -27, "peer loss has complementary negative delta")
    equal(details.opponentRatingSource, "calculated", "derived peer outcome is explicitly labeled")
    equal(details.match.confirmedAt, 95, "details preserve confirmation timestamp")
    equal(details.match.countdownAt, 97, "details preserve countdown timestamp")
    equal(details.match.startedAt, 100, "details preserve start timestamp")
    equal(details.match.endedAt, 145, "details preserve finish timestamp")
    equal(details.match.startSource, "localized-countdown-plus-timer", "details preserve start evidence source")
    equal(details.match.resultSource, "KNOCKOUT", "details preserve result evidence source")
    equal(details.match.evidence.agreedBeforeStart, true, "details preserve consent evidence")
    equal(details.match.evidence.localResult, true, "details preserve native result evidence")
    equal(details.match.evidence.peerResult, true, "details preserve peer result evidence")
    equal(FD.Database.data.matches[1].opponentRatingAfter, nil, "derived rating never added to persisted record")
    equal(FD.Database.data.matches[1].duration, nil, "derived duration never added to persisted record")

    details.winner.name = "Changed winner"
    details.loser.name = "Changed loser"
    equal(details.match.player.name, "Alpha", "winner identity is independent of returned record")
    equal(details.match.opponent.name, "Beta", "loser identity is independent of returned record")
    details.match.player.name = "Changed record"
    details.match.evidence.localResult = false
    details.match.endedAt = 0
    details.opponentRatingAfter = 9999
    local unchanged = FD.History:Details("detail-win")
    equal(unchanged.match.player.name, "Alpha", "details deeply isolate saved player identity")
    equal(unchanged.winner.name, "Alpha", "fresh winner identity remains unchanged")
    equal(unchanged.loser.name, "Beta", "fresh loser identity remains unchanged")
    equal(unchanged.match.evidence.localResult, true, "details deeply isolate evidence")
    equal(unchanged.duration, 45, "details edits cannot rewrite saved duration")
    equal(unchanged.opponentRatingAfter, 1773, "derived rating edits cannot affect subsequent query")
    equal(FD.Database:GetStats().rating, 1527, "details reads and edits never alter local rating")
    equal(#FD.Database.data.matches, 1, "details never add history records")

    FD.Database:Reset(player)
    commit("detail-loss", false, 1200, 0)
    details = FD.History:Details("detail-loss")
    equal(details.duration, 0, "same-second start and finish preserves zero duration")
    equal(details.winner.guid, opponent.guid, "winning peer mapped to winner identity")
    equal(details.loser.guid, player.guid, "losing local player mapped to loser identity")
    equal(details.playerRatingBefore, 1500, "loss preserves local pre-match rating")
    equal(details.playerRatingAfter, 1473, "favorite loss preserves stored post-match rating")
    equal(details.playerRatingDelta, -27, "local loss preserves negative delta")
    equal(details.opponentRatingBefore, 1200, "winner starts from opponent snapshot")
    equal(details.opponentRatingAfter, 1227, "peer winner receives calculated transfer")
    equal(details.opponentRatingDelta, 27, "peer win has complementary positive delta")
    equal(details.playerRatingDelta + details.opponentRatingDelta, 0, "details transfers remain complementary")
    equal(details.opponentRatingSource, "calculated", "winner's projected rating remains labeled calculated")

    FD.Database:Reset(player)
    local series = FD.History:Series()
    equal(#series, 1, "empty progression contains only a starting point")
    equal(series[1].rating, 1500, "empty progression starts at initial rating")
    equal(series[1].baseline, true, "empty starting point is explicitly a baseline")
    equal(series[1].endedAt, nil, "empty progression invents no match time")
    equal(series[1].ordinal, 0, "empty baseline precedes the first match")
    equal(series.total, 0, "empty progression reports no matches")
    equal(series.shown, 0, "empty progression renders no match segments")
    equal(series.bracket, "LEVELING", "progression defaults to active rating pool")
    for index = 1, 45 do commit("chart-" .. index, index % 2 == 1) end
    series = FD.History:Series()
    equal(#series, 41, "default progression includes forty matches plus a baseline")
    equal(series.shown, 40, "progression reports the bounded count")
    equal(series.total, 45, "progression reports the complete pool count")
    equal(series[1].ordinal, 5, "truncated baseline starts after omitted matches")
    equal(series[1].rating, FD.History:Get("chart-6").ratingBefore, "truncated baseline preserves the actual earlier rating")
    equal(series[2].matchId, "chart-6", "first visible match follows its baseline")
    equal(series[41].matchId, "chart-45", "progression ends at the latest result")
    equal(series[41].rating, FD.Database:GetStats().rating, "progression reaches current pool rating")
    for index = 2, #series do
        local stored = FD.History:Get(series[index].matchId)
        equal(series[index - 1].rating, stored.ratingBefore, "equal timestamp chart points preserve rating ledger order")
        equal(series[index].rating, stored.ratingAfter, "chart point uses finalized after-rating")
    end
    series[1].rating, series[2].rating, series[2].matchId = 0, 0, "changed"
    equal(FD.History:Series()[2].matchId, "chart-6", "progression returns fresh points")
    equal(FD.History:Get("chart-6").ratingAfter ~= 0, true, "chart edits cannot change stored match")
    series = FD.History:Series("LEVELING", 1)
    equal(#series, 2, "one-match series still includes its baseline")
    equal(series[2].matchId, "chart-45", "one-match series selects newest match")
    equal(series[1].rating, FD.History:Get("chart-45").ratingBefore, "one-match baseline is the true pre-match rating")
    for _, limit in ipairs({ false, {}, "2", 0 / 0, math.huge, -math.huge }) do
        equal(#FD.History:Series("LEVELING", limit), 41, "invalid chart limits use bounded default")
    end
    equal(#FD.History:Series("LEVELING", 0), 2, "zero chart limit clamps to one match")
    equal(#FD.History:Series("LEVELING", 2.9), 3, "fractional chart limit floors")
    equal(#FD.History:Series("LEVELING", 999), 46, "large chart limit includes all available records")

    player.level, opponent.level = 60, 60
    FD.Database:SetBracket(player)
    commit("max-win", true)
    equal(FD.History:Overview().rating, 1516, "active max-level overview uses its own rating")
    equal(FD.History:Overview().total, 1, "active max-level overview excludes leveling matches")
    equal(FD.History:Overview("LEVELING").total, 45, "leveling overview remains available")
    equal(FD.History:Overview("LEVELING").streakCount, 1, "other pool results do not extend leveling streak")
    equal(FD.History:Page().total, 1, "active pool pagination counts only max-level matches")
    equal(FD.History:Page().matches[1].matchId, "max-win", "active pool pagination selects max-level match")
    equal(#FD.History:Recent(100), 1, "recent matches default to active pool")
    equal(#FD.History:Recent(100, "LEVELING"), 45, "explicit recent pool excludes max-level results")
    series = FD.History:Series()
    equal(#series, 2, "new pool does not continue leveling chart")
    equal(series[1].rating, 1500, "max-level chart starts at its independent baseline")
    equal(series[2].matchId, "max-win", "max-level chart contains only max-level results")
    equal(FD.History:Get("chart-45").bracket, "LEVELING", "direct lookup can access other pools")
    equal(FD.History:Get("max-win").bracket, "MAX_LEVEL", "direct lookup preserves max-level identity")

    player.level, opponent.level = 50, 55
    FD.Database:Reset(player)
    commit("level-underdog", true)
    details = FD.History:Details("level-underdog")
    equal(details.playerRatingDelta, 20, "lower-level win earns weighted transfer")
    equal(details.opponentRatingDelta, -20, "opponent projection reverses level weighting correctly")
    equal(details.opponentRatingAfter, 1480, "weighted opponent projection starts from its saved rating")
    equal(details.match.player.level, 50, "details retain local level snapshot")
    equal(details.match.opponent.level, 55, "details retain opponent level snapshot")
    equal(details.playerRatingDelta + details.opponentRatingDelta, 0, "weighted detail ratings remain complementary")

    opponent.level = 50
    FD.Database:Reset(player)
    commit("old-win", true)
    commit("old-loss", false)
    local legacy = FD.Database:Copy(FD.Database.data)
    legacy.schemaVersion = 1
    legacy.player = FD.Database:Copy(FD.Database:GetStats())
    legacy.player.guid = player.guid
    for _, record in ipairs(legacy.matches) do
        record.schemaVersion, record.protocolVersion, record.bracket = 1, 1, nil
        record.player.level, record.player.maxLevel = nil, nil
        record.opponent.level, record.opponent.maxLevel = nil, nil
    end
    equal(FD.Database:Initialize(legacy, player) ~= nil, true, "valid schema-one history migrates into an archive")
    equal(FD.History:Overview().total, 0, "legacy records never inflate current pool totals")
    equal(FD.History:Overview("LEGACY").total, 2, "legacy overview retains all prior results")
    equal(FD.History:Overview("LEGACY").rating, 1500, "legacy overview retains prior rating")
    equal(FD.History:Overview("LEGACY").peakRating, 1516, "legacy overview retains prior peak")
    equal(FD.History:Page(1, 8, "LEGACY").matches[1].matchId, "old-loss", "legacy pagination uses archived matches")
    equal(FD.History:Recent(1, "LEGACY")[1].bracket, "LEGACY", "legacy recent result has a display pool")
    series = FD.History:Series("LEGACY")
    equal(#series, 3, "legacy progression is separate and complete")
    equal(series[1].rating, 1500, "legacy progression retains initial baseline")
    equal(series[2].rating, 1516, "legacy progression retains past peak")
    equal(series[3].rating, 1500, "legacy progression retains last rating")
    details = FD.History:Details("old-win")
    equal(details.match.bracket, "LEGACY", "direct legacy lookup labels returned copy")
    equal(details.opponentRatingDelta, -16, "legacy projections use original unweighted Elo")
    equal(FD.Database.data.legacy.matches[1].bracket, nil, "legacy display metadata never mutates archived records")
    commit("new-win", true)
    equal(FD.History:Series()[2].matchId, "new-win", "fresh pool chart starts with a fresh result")
    equal(FD.History:Series("LEGACY").total, 2, "fresh duels leave archived progression unchanged")
    -- Details and overview read stored values, never today's rules.
    player.level, opponent.level = 50, 55
    FD.Database:Reset(player)
    commit("stored-transfer", true)
    local storedDelta = FD.History:Get("stored-transfer").ratingDelta
    FD.C.K_FACTOR, FD.C.LEVEL_RATING_WEIGHT = 10, 0
    details = FD.History:Details("stored-transfer")
    equal(details.playerRatingDelta, storedDelta, "player change is the stored change after K changed")
    equal(details.opponentRatingDelta, -storedDelta, "opponent projection reverses the stored change after K changed")
    equal(details.opponentRatingAfter, details.opponentRatingBefore - storedDelta, "opponent after-rating from the stored change")
    FD.C.K_FACTOR, FD.C.LEVEL_RATING_WEIGHT = 32, 20
    opponent.level = 50
    FD.Database:Reset(player)
    commit("only-loss", false)
    FD.C.INITIAL_RATING = 1600
    overview = FD.History:Overview()
    equal(overview.peakRating, 1500, "peak comes from the stored chain, not today's initial rating")
    -- Guards: these already read stored values and must keep doing so.
    equal(overview.rating, 1484, "overview rating stays the stored pool rating")
    equal(FD.History:Series()[1].rating, 1500, "chart baseline stays the first stored rating")
    FD.C.INITIAL_RATING = 1500
end
