local _, FD = ...

-- RULES_VERSION 1 is the level-weighted Elo below. A later formula gets a new
-- version; records keep the version and parameters they were calculated with.
FD.Rating = { RULES_VERSION = 1 }
local Rating = FD.Rating

local function isRating(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and value == math.floor(value)
end

local function isWeight(value)
    return type(value) == "number" and value == value and value >= 0 and value ~= math.huge
end

function Rating:GetInitialRating()
    return FD.C.INITIAL_RATING
end

-- The rules new records are calculated with. Each record stores a copy, so a
-- later change of these constants never invalidates saved history.
function Rating:Rules()
    return { version = self.RULES_VERSION, k = FD.C.K_FACTOR, levelWeight = FD.C.LEVEL_RATING_WEIGHT,
        maxLevelDifference = FD.C.MAX_LEVEL_DIFFERENCE, initialRating = FD.C.INITIAL_RATING }
end

-- Only rules of this client's version can be evaluated.
function Rating:ValidRules(rules)
    return type(rules) == "table" and rules.version == self.RULES_VERSION
        and isWeight(rules.k) and isWeight(rules.levelWeight)
        and isRating(rules.maxLevelDifference) and rules.maxLevelDifference >= 0
        and isRating(rules.initialRating)
end

local function isLevel(value)
    return isRating(value) and value >= 1 and value <= 255
end

function Rating:Bracket(level, maxLevel)
    if not isLevel(level) or not isLevel(maxLevel) or level > maxLevel then return nil end
    return level == maxLevel and "MAX_LEVEL" or "LEVELING"
end

-- `rules` defaults to the current rules; saved records pass their own.
function Rating:Eligible(player, opponent, rules)
    rules = rules or self:Rules()
    if not self:ValidRules(rules) then return nil, "unknown_rating_rules" end
    if type(player) ~= "table" or type(opponent) ~= "table" then
        return nil, "invalid_level"
    end
    local bracket = self:Bracket(player.level, player.maxLevel)
    local otherBracket = self:Bracket(opponent.level, opponent.maxLevel)
    if not bracket or not otherBracket then return nil, "invalid_level" end
    if player.maxLevel ~= opponent.maxLevel then return nil, "different_level_cap" end
    if bracket ~= otherBracket then return nil, "different_rating_bracket" end
    if math.abs(player.level - opponent.level) > rules.maxLevelDifference then
        return nil, "level_difference_too_large"
    end
    return bracket
end

function Rating:Calculate(localRating, opponentRating, didLocalPlayerWin, localLevel, opponentLevel, rules)
    rules = rules or self:Rules()
    if not self:ValidRules(rules) then return nil, "unknown_rating_rules" end
    if not isRating(localRating) or not isRating(opponentRating)
        or type(didLocalPlayerWin) ~= "boolean" then
        return nil, "invalid_rating_input"
    end
    -- Omitting both levels gives the unweighted formula (same as equal levels).
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
        winnerRating = winnerRating + winnerLevel * rules.levelWeight
        loserRating = loserRating + loserLevel * rules.levelWeight
    end
    local expectedWinner = 1 / (1 + 10 ^ ((loserRating - winnerRating) / 400))
    local transfer = math.floor(rules.k * (1 - expectedWinner) + 0.5)
    local delta = didLocalPlayerWin and transfer or -transfer
    -- A zero floor would destroy complementary rating transfers.
    return localRating + delta, delta
end
