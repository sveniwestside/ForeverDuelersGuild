return function(FD, equal)
    local protocol = FD.Protocol
    local base = {
        kind = "HELLO", nonce = "66ec1-1-abcd", echo = "-",
        guid = "Player-1234-0000ABCD", peerGUID = "Player-4321-0000DCBA",
        role = "INCOMING", rating = 1500, specId = 62, classFile = "MAGE",
        wins = 12, losses = 8, verdict = "-", level = 30, maxLevel = 60,
    }
    local function message(changes)
        local result = {}
        for key, value in pairs(base) do result[key] = value end
        for key, value in pairs(changes or {}) do result[key] = value end
        return result
    end
    local encoded = protocol:Encode(base)
    equal(type(encoded), "string", "HELLO encoded")
    equal(#encoded <= 255, true, "wire limit")
    local _, separatorCount = encoded:gsub("|", "")
    equal(separatorCount, 14, "exactly fifteen fields")
    local decoded = protocol:Decode(encoded)
    for key, value in pairs(base) do equal(decoded[key], value, "round trip " .. key) end
    equal(decoded.protocolVersion, 2, "decoded protocol version")
    equal(protocol:Encode(decoded), encoded, "canonical re-encoding")

    for _, kind in ipairs({ "HELLO_ACK", "ACCEPT", "COMMIT", "CONFIRM", "START_OK", "START", "RESULT", "CANCEL" }) do
        local value = message({ kind = kind, echo = "66ec1-2-1234", verdict = kind == "RESULT" and base.peerGUID or "-" })
        local payload = protocol:Encode(value)
        equal(type(payload), "string", kind .. " encoded")
        local received = protocol:Decode(payload)
        equal(received.kind, kind, kind .. " decoded")
        equal(received.verdict, value.verdict, kind .. " verdict")
    end

    local limits = message({ rating = -100000, specId = 0, wins = 1000000000, losses = 0 })
    equal(protocol:Decode(protocol:Encode(limits)).rating, -100000, "negative rating is supported")
    limits.rating, limits.specId = 100000, 100000
    equal(protocol:Decode(protocol:Encode(limits)).rating, 100000, "upper rating bound")
    limits.rating = -1 / math.huge
    equal(protocol:Decode(protocol:Encode(limits)).rating, 0, "negative-zero number encodes canonically")
    for key, values in pairs({
        kind = { "RATED_ACCEPT", "", "hello" },
        nonce = { "-", "", "abcdef|1", "ABCD", string.rep("a", 49) },
        echo = { "abcdef", "", "?|" },
        guid = { "Creature-1234-ABCD", "Player--ABCD", "Player-12-GHI", base.peerGUID, string.rep("a", 65) },
        peerGUID = { "Player-1-2|3", "", base.guid },
        role = { "WATCHER", "incoming", "" },
        rating = { -100001, 100001, 1.5, "1500", math.huge, 0 / 0 },
        specId = { -1, 100001, 1.5, "62" },
        classFile = { "Mage", "UNKNOWN", "MAGE|ROGUE" },
        wins = { -1, 1000000001, 0.5, "12" },
        losses = { -1, 1000000001, 0.5, "8" },
        verdict = { base.guid, "", "OTHER" },
        protocolVersion = { 1, 3, "2" },
        level = { 0, -1, 61, 30.5, "30", math.huge },
        maxLevel = { 0, 29, 256, "60", 60.5 },
    }) do
        for _, value in ipairs(values) do
            equal(protocol:Encode(message({ [key] = value })), nil, "reject invalid " .. key)
        end
    end
    equal(protocol:Encode(nil), nil, "nil message")
    equal(protocol:Encode(message({ kind = "RESULT", echo = "ab", verdict = "Player-1-FFFF" })), nil, "unrelated result")
    equal(protocol:Encode(message({ kind = "ACCEPT" })), nil, "non-HELLO requires nonce echo")
    equal(protocol:Encode(message({ nonce = string.rep("a", 48), guid = "Player-" .. string.rep("1", 28) .. "-" .. string.rep("a", 28),
        peerGUID = "Player-" .. string.rep("2", 28) .. "-" .. string.rep("b", 28),
        kind = "RESULT", echo = string.rep("f", 48), verdict = "Player-" .. string.rep("2", 28) .. "-" .. string.rep("b", 28) })), nil,
        "reject oversized otherwise-valid message")

    for _, payload in ipairs({
        "", string.rep("a", 256), encoded .. "|extra", "|" .. encoded, encoded .. "|",
        encoded:sub(1, #encoded - 3), encoded:gsub("FD2", "FD1", 1),
        encoded:gsub("HELLO", "UNKNOWN", 1), encoded:gsub("1500", "1e3", 1),
        encoded:gsub("1500", "01500", 1), encoded:gsub("1500", "1500.0", 1),
        encoded:gsub("1500", "+1500", 1), encoded:gsub("1500", "-0", 1),
        encoded:gsub("1500", " 1500", 1), encoded:gsub("1500", "nan", 1),
        encoded:gsub("1500", "", 1), encoded:gsub("1500", "100001", 1),
        encoded:gsub("MAGE", "MA\nGE", 1), encoded:gsub("MAGE", "M\195\164GE", 1),
    }) do equal(protocol:Decode(payload), nil, "reject malformed wire payload: " .. tostring(payload)) end
    equal(protocol:Decode(nil), nil, "nil payload")
    equal(protocol:Decode({}), nil, "table payload")

    local nonce = protocol:Nonce(255, 1, 4096)
    equal(nonce, "ff-1-1000", "deterministic nonce")
    equal(protocol:Nonce(0, 0, 0), "0-0-0", "zero nonce inputs")
    equal(protocol:ValidNonce(protocol:Nonce(9007199254740991, 9007199254740991, 9007199254740991)), true,
        "largest exact nonce inputs fit")
    equal(protocol:Nonce(-1, 1, 1), nil, "negative nonce input")
    equal(protocol:Nonce(1, 0.5, 1), nil, "fractional nonce input")
    equal(protocol:Nonce(1, 1, math.huge), nil, "infinite nonce input")
    equal(protocol:Nonce(1, 1, "5"), nil, "string nonce input")
    local id = protocol:MatchID(base.guid, nonce, base.peerGUID, "ff-2-1000")
    equal(id, "FD2:" .. base.guid .. ":ff-1-1000:" .. base.peerGUID .. ":ff-2-1000", "canonical match ID")
    equal(protocol:MatchID(base.peerGUID, "ff-2-1000", base.guid, nonce), id, "GUID sorting preserves nonce association")
    equal(protocol:MatchID(base.guid, "ff-3-1000", base.peerGUID, "ff-4-1000") ~= id, true, "rematch identity differs")
    equal(protocol:MatchID(base.guid, nonce, base.guid, nonce), nil, "same participant cannot match")
    equal(protocol:MatchID(base.guid, "bad:nonce", base.peerGUID, nonce), nil, "match ID rejects separators")

    local player = { guid = base.guid, name = "Alpha", realm = "Forever", fullName = "Alpha-Forever" }
    local opponent = { guid = base.peerGUID, name = "Beta", realm = "Elsewhere", fullName = "Beta-Elsewhere" }
    local knockout = "%s has defeated %s in a duel."
    local retreat = "%2$s has fled from %1$s in a duel."
    local winner, reason = FD.Results:Parse("Alpha has defeated Beta in a duel.", knockout, retreat, player, opponent)
    equal(winner, player.guid, "short names matched")
    equal(reason, "KNOCKOUT", "knockout reason")
    equal(FD.Results:Parse("Beta-Elsewhere has defeated Alpha-Forever in a duel.", knockout, retreat, player, opponent),
        opponent.guid, "full names matched")
    winner, reason = FD.Results:Parse("Alpha has fled from Beta in a duel.", knockout, retreat, player, opponent)
    equal(winner, opponent.guid, "positional retreat winner")
    equal(reason, "RETREAT", "retreat reason")
    equal(FD.Results:Parse("[Alpha] (1+0=1) defeated [Beta]? 100%.", "[%1$s] (1+0=1) defeated [%2$s]? 100%%.", nil, player, opponent),
        player.guid, "localized punctuation and percent escaping")
    equal(FD.Results:Parse("Beta a perdu contre Alpha.", "%2$s a perdu contre %1$s.", nil, player, opponent),
        player.guid, "winner follows loser in localized output")
    equal(FD.Results:Parse("Beta被Alpha击败。", "%2$s被%1$s击败。", nil, player, opponent),
        player.guid, "UTF-8 localized format")
    equal(FD.Results:Parse("|cff00ff00Alpha|r has defeated |Hplayer:Beta-Elsewhere:42:WHISPER|h[Beta]|h in a duel.",
        knockout, retreat, player, opponent), player.guid, "known color and player hyperlink")
    equal(FD.Results:Parse("|cff00ff00|Hplayer:Alpha-Forever:42|h[Alpha]|h|r has defeated Beta in a duel.",
        knockout, retreat, player, opponent), player.guid, "colored known hyperlink")
    for _, text in ipairs({
        "Stranger has defeated Beta in a duel.", "Alpha has defeated Stranger in a duel.",
        "Alpha has defeated Alpha in a duel.", "Alpha has defeated Beta in a duel!",
        "Prefix Alpha has defeated Beta in a duel.", "Alpha has defeated Beta in a duel. suffix",
        "|Hitem:Alpha|h[Alpha]|h has defeated Beta in a duel.",
        "|Hplayer:Stranger|h[Alpha]|h has defeated Beta in a duel.",
        "|Hplayer:Alpha|h[Beta]|h has defeated Beta in a duel.",
        "|cffxxxxxxAlpha|r has defeated Beta in a duel.",
    }) do equal(FD.Results:Parse(text, knockout, retreat, player, opponent), nil, "ignore unrelated or malformed result") end
    equal(FD.Results:Parse("Alpha defeats Beta", nil, nil, player, opponent), nil, "missing globals fail closed")
    equal(FD.Results:Parse("Alpha defeats Beta", "%s defeats %d", nil, player, opponent), nil, "unsupported format fails closed")
    equal(FD.Results:Parse("Alpha defeats Beta", "%s defeats %2$s", nil, player, opponent), nil, "mixed format fails closed")
    equal(FD.Results:Parse("Alpha defeats Beta", "%1$s defeats %1$s", nil, player, opponent), nil, "duplicate argument fails closed")
    equal(FD.Results:Parse("Alpha defeats Beta", "%1$s defeats %2$s", "%2$s defeats %1$s", player, opponent), nil,
        "conflicting localized templates fail closed")
    equal(FD.Results:Parse(nil, knockout, retreat, player, opponent), nil, "invalid result text")
    equal(FD.Results:Parse("Alpha has defeated Beta in a duel.", knockout, retreat, nil, opponent), nil, "invalid result identity")
    opponent.name, opponent.fullName = "Alpha", "Alpha-Elsewhere"
    equal(FD.Results:Parse("Alpha has defeated Alpha in a duel.", knockout, retreat, player, opponent), nil,
        "identical short names across realms are ambiguous")
    equal(FD.Results:Parse("Alpha-Forever has defeated Alpha-Elsewhere in a duel.", knockout, retreat, player, opponent),
        player.guid, "full names disambiguate same short names")
    equal(FD.Results:Parse("Alpha-Forever has defeated Alpha in a duel.", knockout, retreat, player, opponent), nil,
        "mixed full and ambiguous short names fail closed")

    equal(FD.Results:Countdown("Duel starting: 3", "Duel starting: %d"), 3, "countdown format")
    equal(FD.Results:Countdown("[3] secondes (duel).", "[%1$d] secondes (duel)."), 3, "localized positional countdown")
    for _, text in ipairs({ "Duel starting: 0", "Duel starting: 11", "Duel starting: 03", "Duel starting: -1",
        "Duel starting: 3!", "prefix Duel starting: 3", "Duel starting: 1.5" }) do
        equal(FD.Results:Countdown(text, "Duel starting: %d"), nil, "invalid countdown")
    end
    equal(FD.Results:Countdown("Duel starting: 3", nil), nil, "missing countdown global")
    equal(FD.Results:Countdown("Duel starting: 3", "Duel starting: %s"), nil, "unsupported countdown format")
end
