local _, FD = ...

FD.Rating = {}
local Rating = FD.Rating

local function isRating(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and value == math.floor(value)
end

function Rating:GetInitialRating()
    return FD.C.INITIAL_RATING
end

local function isLevel(value)
    return isRating(value) and value >= 1 and value <= 255
end

function Rating:Bracket(level, maxLevel)
    if not isLevel(level) or not isLevel(maxLevel) or level > maxLevel then return nil end
    return level == maxLevel and "MAX_LEVEL" or "LEVELING"
end

function Rating:Eligible(player, opponent)
    if type(player) ~= "table" or type(opponent) ~= "table" then
        return nil, "invalid_level"
    end
    local bracket = self:Bracket(player.level, player.maxLevel)
    local otherBracket = self:Bracket(opponent.level, opponent.maxLevel)
    if not bracket or not otherBracket then return nil, "invalid_level" end
    if player.maxLevel ~= opponent.maxLevel then return nil, "different_level_cap" end
    if bracket ~= otherBracket then return nil, "different_rating_bracket" end
    if math.abs(player.level - opponent.level) > FD.C.MAX_LEVEL_DIFFERENCE then
        return nil, "level_difference_too_large"
    end
    return bracket
end

function Rating:Calculate(localRating, opponentRating, didLocalPlayerWin, localLevel, opponentLevel)
    if not isRating(localRating) or not isRating(opponentRating)
        or type(didLocalPlayerWin) ~= "boolean" then
        return nil, "invalid_rating_input"
    end
    -- Omitting both levels is retained only for validating legacy schema-1 data.
    if (localLevel ~= nil or opponentLevel ~= nil)
        and (not isLevel(localLevel) or not isLevel(opponentLevel)) then
        return nil, "invalid_level"
    end

    -- Always calculate the winner's transfer. Rounding the two signed deltas
    -- separately can give the two clients different answers at a half point.
    local winnerRating = didLocalPlayerWin and localRating or opponentRating
    local loserRating = didLocalPlayerWin and opponentRating or localRating
    if localLevel then
        local winnerLevel = didLocalPlayerWin and localLevel or opponentLevel
        local loserLevel = didLocalPlayerWin and opponentLevel or localLevel
        winnerRating = winnerRating + winnerLevel * FD.C.LEVEL_RATING_WEIGHT
        loserRating = loserRating + loserLevel * FD.C.LEVEL_RATING_WEIGHT
    end
    local expectedWinner = 1 / (1 + 10 ^ ((loserRating - winnerRating) / 400))
    local transfer = math.floor(FD.C.K_FACTOR * (1 - expectedWinner) + 0.5)
    local delta = didLocalPlayerWin and transfer or -transfer
    -- A zero floor would destroy complementary rating transfers.
    return localRating + delta, delta
end
