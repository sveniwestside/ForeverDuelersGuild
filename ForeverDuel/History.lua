local _, FD = ...

FD.History = {}
local History = FD.History

local function currentBracket(bracket)
    return bracket or FD.Database.bracket or "LEVELING"
end

local function matchesFor(bracket)
    local db = FD.Database.data
    local matches = {}
    if not db then return matches end
    if bracket == "LEGACY" then return db.legacy and db.legacy.matches or matches end
    for _, match in ipairs(db.matches) do
        if match.bracket == bracket then matches[#matches + 1] = match end
    end
    return matches
end

local function copyMatch(match, bracket)
    local result = FD.Database:Copy(match)
    if bracket == "LEGACY" then result.bracket = "LEGACY" end
    return result
end

local function boundedInteger(value, default, maximum)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        return default
    end
    return math.min(maximum, math.max(1, math.floor(value)))
end

function History:Recent(count, bracket)
    bracket = currentBracket(bracket)
    local matches, result = matchesFor(bracket), {}
    count = count or 5
    if type(count) ~= "number" or count ~= count or count < 0 then return result end
    count = math.min(math.floor(count), #matches)
    for index = #matches, #matches - count + 1, -1 do
        result[#result + 1] = copyMatch(matches[index], bracket)
    end
    return result
end

function History:Get(matchId)
    local db = FD.Database.data
    if not db or type(matchId) ~= "string" then return nil end
    for index = #db.matches, 1, -1 do
        if db.matches[index].matchId == matchId then return copyMatch(db.matches[index]) end
    end
    local legacy = db.legacy
    if legacy then
        for index = #legacy.matches, 1, -1 do
            if legacy.matches[index].matchId == matchId then
                return copyMatch(legacy.matches[index], "LEGACY")
            end
        end
    end
end

function History:Details(matchId)
    local match = self:Get(matchId)
    if not match then return nil end
    local won = match.result == "WIN"
    -- Legacy results predate level weighting. The peer's rating is always a
    -- projection from saved snapshots, never a verified peer account balance.
    local opponentLevel, playerLevel
    if match.bracket ~= "LEGACY" then
        opponentLevel, playerLevel = match.opponent.level, match.player.level
    end
    local opponentAfter, opponentDelta = FD.Rating:Calculate(
        match.opponentRatingBefore, match.ratingBefore, not won, opponentLevel, playerLevel)
    return {
        match = match,
        duration = match.endedAt - match.startedAt,
        winner = FD.Database:Copy(won and match.player or match.opponent),
        loser = FD.Database:Copy(won and match.opponent or match.player),
        playerRatingBefore = match.ratingBefore,
        playerRatingAfter = match.ratingAfter,
        playerRatingDelta = match.ratingDelta,
        opponentRatingBefore = match.opponentRatingBefore,
        opponentRatingAfter = opponentAfter,
        opponentRatingDelta = opponentDelta,
        opponentRatingSource = "calculated",
    }
end

function History:Overview(bracket)
    bracket = currentBracket(bracket)
    local initialRating = FD.Rating:GetInitialRating()
    local result = {
        bracket = bracket, rating = initialRating, wins = 0, losses = 0, total = 0,
        peakRating = initialRating, streakCount = 0,
    }
    local stats = FD.Database:GetStats(bracket)
    if not stats then return result end
    local matches = matchesFor(bracket)
    result.rating, result.wins, result.losses = stats.rating, stats.wins, stats.losses
    result.total = result.wins + result.losses
    if result.total > 0 then result.winRate = result.wins / result.total * 100 end
    for _, match in ipairs(matches) do
        result.peakRating = math.max(result.peakRating, match.ratingBefore, match.ratingAfter)
    end
    local latest = matches[#matches]
    if latest then
        result.streakResult = latest.result
        for index = #matches, 1, -1 do
            if matches[index].result ~= result.streakResult then break end
            result.streakCount = result.streakCount + 1
        end
    end
    return result
end

function History:Page(page, pageSize, bracket)
    bracket = currentBracket(bracket)
    local matches = matchesFor(bracket)
    local total = #matches
    pageSize = boundedInteger(pageSize, 8, 50)
    local pages = math.max(1, math.ceil(total / pageSize))
    page = boundedInteger(page, 1, pages)
    local result = { matches = {}, page = page, pages = pages, total = total, pageSize = pageSize, bracket = bracket }
    local newest = total - (page - 1) * pageSize
    local oldest = math.max(1, newest - pageSize + 1)
    for index = newest, oldest, -1 do
        result.matches[#result.matches + 1] = copyMatch(matches[index], bracket)
    end
    return result
end

function History:Series(bracket, limit)
    bracket = currentBracket(bracket)
    local matches = matchesFor(bracket)
    local count = math.min(#matches, boundedInteger(limit, 40, 100))
    local first = #matches - count + 1
    local stats = FD.Database:GetStats(bracket)
    local result = { bracket = bracket, total = #matches, shown = count }
    local opening = matches[first]
    result[1] = {
        baseline = true, ordinal = first - 1,
        rating = opening and opening.ratingBefore or (stats and stats.rating or FD.Rating:GetInitialRating()),
        endedAt = opening and opening.startedAt or nil,
    }
    -- Finalization order is the rating ledger's chronology. Keep it even when
    -- timestamps tie or the client clock moves; sorting would break the chain.
    for index = first, #matches do
        local match = matches[index]
        result[#result + 1] = {
            ordinal = index, matchId = match.matchId, rating = match.ratingAfter,
            endedAt = match.endedAt, result = match.result, ratingDelta = match.ratingDelta,
        }
    end
    return result
end
