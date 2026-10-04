local _, FD = ...

FD.Database = {}
local Database = FD.Database
local MAX_COUNTER = 9007199254740991

local function integer(value, minimum)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and value == math.floor(value) and (minimum == nil or value >= minimum)
end

local function nonempty(value)
    return type(value) == "string" and #value > 0
end

local function validIdentity(identity)
    return type(identity) == "table" and nonempty(identity.guid)
        and nonempty(identity.name) and nonempty(identity.realm)
        and nonempty(identity.classFile)
end

-- SavedVariables must contain only serializable values. Copy the finalized
-- record so later changes to negotiation/UI tables cannot rewrite history.
local function copy(value, ancestors, depth)
    local kind = type(value)
    if kind == "nil" or kind == "string" or kind == "boolean" then
        return value
    end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return nil, "nonfinite_saved_value"
        end
        return value
    end
    if kind ~= "table" or depth > 16 or ancestors[value] or getmetatable(value) then
        return nil, "invalid_saved_value"
    end
    ancestors[value] = true
    local result = {}
    for key, child in pairs(value) do
        if type(key) ~= "string" and not integer(key) then
            ancestors[value] = nil
            return nil, "invalid_saved_key"
        end
        local childCopy, err = copy(child, ancestors, depth + 1)
        if err then
            ancestors[value] = nil
            return nil, err
        end
        result[key] = childCopy
    end
    ancestors[value] = nil
    return result
end

function Database:Copy(value)
    return copy(value, {}, 0)
end

local function validateRecord(record, localGUID, legacy)
    local schemaVersion = legacy and 1 or FD.C.SCHEMA_VERSION
    local protocolVersion = legacy and 1 or FD.C.PROTOCOL_VERSION
    if type(record) ~= "table" or record.schemaVersion ~= schemaVersion
        or record.protocolVersion ~= protocolVersion then
        return nil, "invalid_record_version"
    end
    if not nonempty(record.matchId) or not validIdentity(record.player)
        or not validIdentity(record.opponent)
        or record.player.guid ~= localGUID
        or record.player.guid == record.opponent.guid then
        return nil, "invalid_record_identity"
    end
    if not integer(record.startedAt, 0) or not integer(record.endedAt, record.startedAt) then
        return nil, "invalid_record_time"
    end
    if record.result ~= "WIN" and record.result ~= "LOSS" then
        return nil, "invalid_record_result"
    end
    local won = record.result == "WIN"
    local expectedWinner = won and record.player.guid or record.opponent.guid
    local expectedLoser = won and record.opponent.guid or record.player.guid
    if record.winnerGUID ~= expectedWinner or record.loserGUID ~= expectedLoser then
        return nil, "contradictory_record_result"
    end
    local evidence = record.evidence
    if record.ratedConfirmed ~= true or type(evidence) ~= "table"
        or evidence.agreedBeforeStart ~= true or evidence.localResult ~= true
        or evidence.peerResult ~= true then
        return nil, "unconfirmed_record"
    end
    if not integer(record.ratingBefore) or not integer(record.opponentRatingBefore)
        or not integer(record.ratingAfter) or not integer(record.ratingDelta) then
        return nil, "invalid_record_rating"
    end
    local level, opponentLevel
    if not legacy then
        local bracket, reason = FD.Rating:Eligible(record.player, record.opponent)
        if not bracket then return nil, reason end
        if record.bracket ~= bracket then return nil, "invalid_record_bracket" end
        level, opponentLevel = record.player.level, record.opponent.level
    end
    local after, delta = FD.Rating:Calculate(record.ratingBefore, record.opponentRatingBefore, won, level, opponentLevel)
    if record.ratingAfter ~= after or record.ratingDelta ~= delta then
        return nil, "inconsistent_record_rating"
    end
    return true
end

local function freshStats()
    return { rating = FD.Rating:GetInitialRating(), wins = 0, losses = 0 }
end

local function fresh(identity, counter, settings)
    return {
        schemaVersion = FD.C.SCHEMA_VERSION,
        player = { guid = identity.guid, ratings = { LEVELING = freshStats(), MAX_LEVEL = freshStats() } },
        matches = {},
        finalized = {},
        settings = settings or { debug = false },
        nonceCounter = counter or 0,
    }
end

local function validStats(stats)
    return type(stats) == "table" and integer(stats.rating)
        and integer(stats.wins, 0) and integer(stats.losses, 0)
end

local function validateDatabase(saved, localGUID, legacy)
    if type(saved) ~= "table" or saved.schemaVersion ~= (legacy and 1 or FD.C.SCHEMA_VERSION) then
        return nil, "unsupported_database_version"
    end
    local player = saved.player
    if type(player) ~= "table" or player.guid ~= localGUID or type(saved.matches) ~= "table"
        or type(saved.finalized) ~= "table" or type(saved.settings) ~= "table"
        or type(saved.settings.debug) ~= "boolean" or not integer(saved.nonceCounter, 0)
        or saved.nonceCounter > MAX_COUNTER then
        return nil, "invalid_database"
    end
    local pools
    if legacy then
        if not validStats(player) then return nil, "invalid_database" end
        pools = { LEGACY = player }
    else
        if type(player.ratings) ~= "table" or not validStats(player.ratings.LEVELING)
            or not validStats(player.ratings.MAX_LEVEL) then return nil, "invalid_database" end
        for bracket in pairs(player.ratings) do
            if bracket ~= "LEVELING" and bracket ~= "MAX_LEVEL" then return nil, "invalid_rating_bracket" end
        end
        pools = player.ratings
    end
    local totals = {}
    for bracket in pairs(pools) do totals[bracket] = freshStats() end
    local seen, count = {}, 0
    for key in pairs(saved.matches) do
        if not integer(key, 1) then
            return nil, "invalid_history_index"
        end
        count = count + 1
    end
    for index = 1, count do
        local record = saved.matches[index]
        local valid, err = validateRecord(record, player.guid, legacy)
        if not valid then
            return nil, err
        end
        local stats = totals[legacy and "LEGACY" or record.bracket]
        if seen[record.matchId] or saved.finalized[record.matchId] ~= true
            or record.ratingBefore ~= stats.rating then
            return nil, "inconsistent_history"
        end
        seen[record.matchId] = true
        stats.rating = record.ratingAfter
        stats.wins = stats.wins + (record.result == "WIN" and 1 or 0)
        stats.losses = stats.losses + (record.result == "LOSS" and 1 or 0)
    end
    for matchId, finalized in pairs(saved.finalized) do
        if finalized ~= true or not seen[matchId] then
            return nil, "inconsistent_finalization_index"
        end
    end
    for bracket, stats in pairs(pools) do
        local total = totals[bracket]
        if total.wins ~= stats.wins or total.losses ~= stats.losses or total.rating ~= stats.rating then
            return nil, "inconsistent_player_totals"
        end
    end
    if not legacy and saved.legacy ~= nil then
        local valid, err = validateDatabase(saved.legacy, localGUID, true)
        if not valid then return nil, err end
        if saved.nonceCounter < saved.legacy.nonceCounter then return nil, "inconsistent_nonce_counter" end
        for matchId in pairs(saved.legacy.finalized) do
            if seen[matchId] then return nil, "duplicate_legacy_match" end
        end
    end
    local _, copyError = Database:Copy(saved)
    if copyError then
        return nil, copyError
    end
    return true
end

function Database:SetBracket(identity)
    local bracket = type(identity) == "table" and FD.Rating:Bracket(identity.level, identity.maxLevel)
    if not bracket then
        self.bracket = nil
        return nil, "invalid_local_level"
    end
    self.bracket = bracket
    return bracket
end

function Database:GetStats(bracket)
    if not self.data then return nil end
    bracket = bracket or self.bracket or "LEVELING"
    if bracket == "LEGACY" then return self.data.legacy and self.data.legacy.player end
    return self.data.player.ratings[bracket]
end

function Database:Initialize(saved, localIdentity)
    self.data, self.bracket = nil, nil
    if not validIdentity(localIdentity) then return nil, "invalid_local_identity" end
    -- Level APIs may not be ready at login. Preserve/read saved history while
    -- rated eligibility separately requires a complete, current level profile.
    self:SetBracket(localIdentity)
    if saved == nil then
        self.data = fresh(localIdentity)
        return self.data
    end
    -- Validate the entire original data before migration. Never overwrite a
    -- future/damaged SavedVariable or infer historical levels from today's level.
    local legacy = type(saved) == "table" and saved.schemaVersion == 1
    local valid, err = validateDatabase(saved, localIdentity.guid, legacy)
    if not valid then return nil, err end
    if legacy then
        local preserved, copyError = self:Copy(saved)
        if copyError then return nil, copyError end
        local migrated = fresh(localIdentity, saved.nonceCounter, self:Copy(saved.settings))
        migrated.legacy = preserved
        local _, migrationError = self:Copy(migrated)
        if migrationError then return nil, migrationError end
        self.data = migrated
    else
        self.data = saved
    end
    return self.data
end

function Database:NextCounter()
    if not self.data then
        return nil, "database_unavailable"
    end
    if self.data.nonceCounter >= MAX_COUNTER then
        return nil, "nonce_counter_exhausted"
    end
    self.data.nonceCounter = self.data.nonceCounter + 1
    return self.data.nonceCounter
end

function Database:Reset(localIdentity)
    if not self.data then
        return nil, "database_unavailable"
    end
    if not validIdentity(localIdentity) or localIdentity.guid ~= self.data.player.guid then
        return nil, "invalid_local_identity"
    end
    local bracket = FD.Rating:Bracket(localIdentity.level, localIdentity.maxLevel)
    local settings, err = self:Copy(self.data.settings)
    if err then
        return nil, err
    end
    self.data = fresh(localIdentity, self.data.nonceCounter, settings)
    self.bracket = bracket
    return self.data
end

function Database:Commit(record)
    local db = self.data
    if not db then
        return nil, "database_unavailable"
    end
    if type(record) == "table" and nonempty(record.matchId)
        and (db.finalized[record.matchId] or (db.legacy and db.legacy.finalized[record.matchId])) then
        return false, "already_finalized"
    end
    local valid, err = validateRecord(record, db.player.guid)
    if not valid then
        return nil, err
    end
    local stats = self:GetStats(record.bracket)
    if record.ratingBefore ~= stats.rating then
        return nil, "stale_rating_snapshot"
    end
    local stored, copyError = self:Copy(record)
    if copyError then
        return nil, copyError
    end

    -- All checks and snapshot copying precede mutation; there are no callbacks or
    -- yields between the following writes. Each match ID can commit only once.
    local nextWins = stats.wins + (stored.result == "WIN" and 1 or 0)
    local nextLosses = stats.losses + (stored.result == "LOSS" and 1 or 0)
    db.matches[#db.matches + 1] = stored
    db.finalized[stored.matchId] = true
    stats.rating = stored.ratingAfter
    stats.wins = nextWins
    stats.losses = nextLosses
    return true, self:Copy(stored)
end
