local _, FD = ...

local Results = {}
FD.Results = Results

local function literal(character)
    return (character:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function compile(format, conversion, count)
    if type(format) ~= "string" or #format == 0 or #format > 1024 then return nil end
    local pattern, order, seen = { "^" }, {}, {}
    local index, sequential, mode = 1, 0, nil
    while index <= #format do
        local character = format:sub(index, index)
        if character ~= "%" then
            pattern[#pattern + 1] = literal(character)
            index = index + 1
        elseif format:sub(index + 1, index + 1) == "%" then
            pattern[#pattern + 1] = "%%"
            index = index + 2
        else
            local argument, tokenLength, tokenMode
            if format:sub(index + 1, index + 1) == conversion then
                sequential = sequential + 1
                argument, tokenLength, tokenMode = sequential, 2, "sequential"
            else
                local position = format:sub(index):match("^%%([12])%$" .. conversion)
                if not position then return nil end
                argument, tokenLength, tokenMode = tonumber(position), 4, "positional"
            end
            if argument > count or seen[argument] or (mode and mode ~= tokenMode) then return nil end
            mode, seen[argument] = tokenMode, true
            order[#order + 1] = argument
            pattern[#pattern + 1] = conversion == "d" and "(%d+)" or "(.+)"
            index = index + tokenLength
        end
    end
    if #order ~= count then return nil end
    pattern[#pattern + 1] = "$"
    return table.concat(pattern), order
end

local function identityNames(identity)
    if type(identity) ~= "table" or type(identity.guid) ~= "string"
        or type(identity.name) ~= "string" or identity.name == "" then return nil end
    local short = identity.name:match("^([^%-]+)")
    local full = identity.fullName
    if type(full) ~= "string" or full == "" then
        full = identity.name
        if not full:find("-", 1, true) and type(identity.realm) == "string" and identity.realm ~= "" then
            full = full .. "-" .. identity.realm
        end
    end
    return { short = short, full = full, guid = identity.guid }
end

local function plainIdentity(value, player, opponent)
    local first = value == player.full and (player.full ~= player.short or player.short ~= opponent.short)
    local second = value == opponent.full and (opponent.full ~= opponent.short or player.short ~= opponent.short)
    if player.short ~= opponent.short then
        first = first or value == player.short
        second = second or value == opponent.short
    end
    if first == second then return nil end
    return first and player.guid or opponent.guid
end

local function unwrapColor(value)
    return value:match("^|c%x%x%x%x%x%x%x%x(.+)|r$") or value
end

local function resolve(value, player, opponent)
    value = unwrapColor(value)
    if not value:find("|", 1, true) then return plainIdentity(value, player, opponent) end
    -- Only player hyperlinks are recognized, and both destination and displayed
    -- name must resolve to the same known participant. Never strip arbitrary tags.
    local destination, label = value:match("^|Hplayer:([^|]+)|h(.-)|h$")
    if not destination then return nil end
    local target = destination:match("^([^:]+)")
    label = unwrapColor(label)
    label = label:match("^%[(.+)%]$") or label
    local targetGUID = plainIdentity(target, player, opponent)
    local labelGUID = plainIdentity(label, player, opponent)
    if targetGUID and targetGUID == labelGUID then return targetGUID end
    return nil
end

local function matchResult(text, format, player, opponent)
    local pattern, order = compile(format, "s", 2)
    if not pattern then return nil end
    local first, second = text:match(pattern)
    if not first or not second then return nil end
    local arguments = { [order[1]] = first, [order[2]] = second }
    local winner = resolve(arguments[1], player, opponent)
    local loser = resolve(arguments[2], player, opponent)
    if not winner or not loser or winner == loser then return nil end
    return winner
end

function Results:Parse(text, knockoutFormat, retreatFormat, player, opponent)
    if type(text) ~= "string" or #text == 0 or #text > 4096 then return nil, "invalid system message" end
    local localNames, peerNames = identityNames(player), identityNames(opponent)
    if not localNames or not peerNames or localNames.guid == peerNames.guid then
        return nil, "invalid participants"
    end
    -- REQUIRES LIVE CLIENT VERIFICATION: callers pass runtime-probed localized
    -- DUEL_WINNER_KNOCKOUT / DUEL_WINNER_RETREAT strings, and only CHAT_MSG_SYSTEM.
    -- Argument 1 denotes winner and 2 loser, even when a locale reverses display
    -- order. Missing/unsupported formats or ambiguous names fail closed.
    -- DUEL_FINISHED itself has no winner payload in Retail API documentation.
    local knockout = matchResult(text, knockoutFormat, localNames, peerNames)
    local retreat = matchResult(text, retreatFormat, localNames, peerNames)
    if knockout and retreat and knockout ~= retreat then return nil, "conflicting result formats" end
    if knockout then return knockout, "KNOCKOUT" end
    if retreat then return retreat, "RETREAT" end
    return nil, "unrecognized or ambiguous duel result"
end

function Results:Countdown(text, format)
    if type(text) ~= "string" or #text > 1024 then return nil end
    local pattern = compile(format, "d", 1)
    if not pattern then return nil end
    local captured = text:match(pattern)
    local seconds = captured and tonumber(captured)
    if not seconds or seconds < 1 or seconds > 10 or tostring(seconds) ~= captured then return nil end
    -- This parses the localized DUEL_COUNTDOWN system-message format; it does
    -- not imply that a DUEL_COUNTDOWN event exists. The adapter must verify it.
    return seconds
end
