return function(FD, equal)
    local function identity(level, maxLevel)
        return { level = level, maxLevel = maxLevel or 60 }
    end
    equal(FD.Rating:Bracket(1, 60), "LEVELING", "first level is leveling")
    equal(FD.Rating:Bracket(59, 60), "LEVELING", "last leveling level")
    equal(FD.Rating:Bracket(60, 60), "MAX_LEVEL", "cap is max level")
    for _, invalid in ipairs({ 0, -1, 1.5, 256, "30", math.huge }) do
        equal(FD.Rating:Bracket(invalid, 60), nil, "invalid character level")
        equal(FD.Rating:Bracket(30, invalid), nil, "invalid level cap")
        equal(FD.Rating:Calculate(1500, 1500, true, invalid, 30), nil, "invalid weighted level")
    end
    equal(FD.Rating:Bracket(nil, 60), nil, "unknown level")
    equal(FD.Rating:Bracket(30, nil), nil, "unknown cap")
    equal(FD.Rating:Bracket(61, 60), nil, "above-cap level rejected")
    equal(FD.Rating:Eligible(identity(30), identity(35)), "LEVELING", "plus five eligible")
    equal(FD.Rating:Eligible(identity(35), identity(30)), "LEVELING", "minus five eligible")
    equal(FD.Rating:Eligible(identity(30), identity(36)), nil, "plus six rejected")
    equal(FD.Rating:Eligible(identity(36), identity(30)), nil, "minus six rejected")
    equal(FD.Rating:Eligible(identity(59), identity(60)), nil, "adjacent levels across bracket rejected")
    equal(FD.Rating:Eligible(identity(60), identity(60)), "MAX_LEVEL", "max-level peers eligible")
    equal(FD.Rating:Eligible(identity(30, 60), identity(30, 80)), nil, "different caps rejected")
    equal(FD.Rating:Eligible(identity(60, 60), identity(65, 65)), nil, "different caps both max rejected")
    equal(FD.Rating:Eligible(nil, identity(30)), nil, "missing local profile rejected")
    equal(FD.Rating:Eligible(identity(30), {}), nil, "unknown peer level rejected")
    equal(FD.Rating:Calculate(1500, 1500, true, 30), nil, "one missing weighting level rejected")
    equal(FD.Rating:Calculate(1500, 1500, true, nil, 30), nil, "other missing weighting level rejected")
    local highAfter, highDelta = FD.Rating:Calculate(1500, 1500, true, 35, 30)
    local lowAfter, lowDelta = FD.Rating:Calculate(1500, 1500, true, 30, 35)
    equal(highDelta, 12, "higher-level expected win gives less")
    equal(lowDelta, 20, "lower-level upset gives more")
    equal(highAfter, 1512, "higher-level win rating")
    equal(lowAfter, 1520, "lower-level upset rating")
    equal(select(2, FD.Rating:Calculate(1500, 1500, false, 35, 30)), -20, "higher-level upset loss costs more")
    equal(select(2, FD.Rating:Calculate(1500, 1500, false, 30, 35)), -12, "lower-level expected loss costs less")
    equal(select(2, FD.Rating:Calculate(1500, 1500, true, 60, 60)), 16, "equal max levels preserve Elo")
    equal(select(2, FD.Rating:Calculate(1500, 1600, true, 35, 30)), 16, "five levels offset 100 rating points")
    for gap = -5, 5 do
        for _, pair in ipairs({ { 1500, 1500 }, { 1450, 1710 }, { 0, -100 } }) do
            local after, delta = FD.Rating:Calculate(pair[1], pair[2], true, 30 + gap, 30)
            local peerAfter, peerDelta = FD.Rating:Calculate(pair[2], pair[1], false, 30, 30 + gap)
            equal(delta, -peerDelta, "weighted transfer complementary")
            equal(after + peerAfter, pair[1] + pair[2], "weighted rating conserved")
        end
    end
    -- Rules are what new records store and what saved records are checked with.
    local rules = FD.Rating:Rules()
    equal(rules.version, FD.Rating.RULES_VERSION, "current rules version")
    equal(rules.k, FD.C.K_FACTOR, "rules carry K")
    equal(rules.levelWeight, FD.C.LEVEL_RATING_WEIGHT, "rules carry level weight")
    equal(rules.maxLevelDifference, FD.C.MAX_LEVEL_DIFFERENCE, "rules carry maximum level difference")
    equal(rules.initialRating, FD.C.INITIAL_RATING, "rules carry initial rating")
    rules.k = 1
    equal(FD.Rating:Rules().k, 32, "each call returns a fresh rules table")
    equal(FD.Rating:ValidRules(FD.Rating:Rules()), true, "current rules valid")
    equal(FD.Rating:ValidRules(nil), false, "missing rules invalid")
    for _, change in ipairs({ { version = 2 }, { version = "1" }, { k = -1 }, { k = 0 / 0 }, { k = math.huge },
        { levelWeight = "20" }, { maxLevelDifference = 1.5 }, { maxLevelDifference = -1 },
        { initialRating = 1500.5 }, { initialRating = false } }) do
        local candidate = FD.Rating:Rules()
        for key, value in pairs(change) do candidate[key] = value end
        equal(FD.Rating:ValidRules(candidate), false, "malformed or unknown rules rejected")
    end
    local double = FD.Rating:Rules()
    double.k = 64
    equal(select(2, FD.Rating:Calculate(1500, 1500, true, 30, 30, double)), 32, "explicit rules K applies")
    local flat = FD.Rating:Rules()
    flat.levelWeight = 0
    equal(select(2, FD.Rating:Calculate(1500, 1500, true, 30, 35, flat)), 16, "explicit zero weight ignores levels")
    equal(FD.Rating:Calculate(1500, 1500, true, 30, 30, { version = 2 }), nil, "unknown rules cannot calculate")
    local narrow = FD.Rating:Rules()
    narrow.maxLevelDifference = 2
    equal(FD.Rating:Eligible(identity(30), identity(32), narrow), "LEVELING", "explicit level difference allows")
    equal(FD.Rating:Eligible(identity(30), identity(33), narrow), nil, "explicit level difference rejects")
    equal(select(2, FD.Rating:Eligible(identity(30), identity(30), { version = 2 })), "unknown_rating_rules",
        "unknown rules cannot decide eligibility")
    -- Without explicit rules today's constants apply.
    FD.C.K_FACTOR = 24
    equal(select(2, FD.Rating:Calculate(1500, 1500, true, 30, 30)), 12, "default rules follow current K")
    FD.C.K_FACTOR = 32
    FD.C.MAX_LEVEL_DIFFERENCE = 3
    equal(FD.Rating:Eligible(identity(30), identity(34)), nil, "default rules follow current level difference")
    FD.C.MAX_LEVEL_DIFFERENCE = 5
end
