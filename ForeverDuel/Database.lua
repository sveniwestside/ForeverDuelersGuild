local _, FD = ...

FD.Database = {}
local Database = FD.Database
local MAX_COUNTER = 9007199254740991
local MAX_DEPTH = 16 -- Nesting limit for everything kept in the saved table.
local SALVAGE_LIMIT = 100000 -- Entries kept from one archived or quarantined table.
local MAX_ARCHIVES = 3
-- Chains saved before databases stored their initial ratings start here.
local DEFAULT_INITIAL_RATING = 1500

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
-- In salvage mode unusable entries are dropped instead of failing the copy,
-- and at most salvage.left entries are kept.
local function copy(value, ancestors, depth, salvage)
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
    if kind ~= "table" or depth > MAX_DEPTH or ancestors[value] or getmetatable(value) then
        return nil, "invalid_saved_value"
    end
    ancestors[value] = true
    local result = {}
    for key, child in pairs(value) do
        if salvage and salvage.left <= 0 then salvage.dropped = true; break end
        local childCopy, err
        if type(key) ~= "string" and not integer(key) then
            err = "invalid_saved_key"
        else
            childCopy, err = copy(child, ancestors, depth + 1, salvage)
        end
        if err and not salvage then
            ancestors[value] = nil
            return nil, err
        elseif err then
            salvage.dropped = true
        else
            result[key] = childCopy
            if salvage then salvage.left = salvage.left - 1 end
        end
    end
    ancestors[value] = nil
    return result
end

function Database:Copy(value)
    return copy(value, {}, 0)
end

-- Keeps whatever is readable of damaged or foreign data. `depth` is where the
-- copy will live in the saved table, so the result always reloads. `value`
-- may be a trimmed shallow copy of `original`; a reference back to that
-- original is a cycle as well.
local function salvage(value, depth, original)
    local budget, ancestors = { left = SALVAGE_LIMIT }, {}
    if type(original) == "table" then ancestors[original] = true end
    local result, err = copy(value, ancestors, depth, budget)
    return result, (err or budget.dropped) and true or nil
end

local function now()
    if type(GetServerTime) ~= "function" then return nil end
    local ok, value = pcall(GetServerTime)
    if ok and not (type(issecretvalue) == "function" and issecretvalue(value)) and integer(value, 0) then
        return value
    end
end

-- Loading checks structure and the rating ledger, never today's tuning: each
-- stored change must add up, point in the direction of the result and chain
-- onto the previous one. Records that carry their rules are also recomputed
-- with those rules.
local function validateRecord(record, localGUID, legacy)
    if type(record) ~= "table" or record.schemaVersion ~= (legacy and 1 or FD.C.SCHEMA_VERSION)
        or not integer(record.protocolVersion, 1) then
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
    if record.ratingAfter ~= record.ratingBefore + record.ratingDelta
        or (won and record.ratingDelta < 0) or (not won and record.ratingDelta > 0) then
        return nil, "inconsistent_record_rating"
    end
    if legacy then return true end
    -- Pools are defined by the stored level snapshots, not by tunable rules.
    local player, opponent = record.player, record.opponent
    local bracket = FD.Rating:Bracket(player.level, player.maxLevel)
    if not bracket or record.bracket ~= bracket or opponent.maxLevel ~= player.maxLevel
        or FD.Rating:Bracket(opponent.level, opponent.maxLevel) ~= bracket then
        return nil, "invalid_record_bracket"
    end
    local rules = record.rules
    -- Records from before 0.6 carry no rules; rules of a newer release cannot
    -- be evaluated here. The ledger checks above still apply to both.
    if rules == nil or (type(rules) == "table" and integer(rules.version, FD.Rating.RULES_VERSION + 1)) then
        return true
    end
    if not FD.Rating:ValidRules(rules) then return nil, "invalid_record_rules" end
    local eligible, reason = FD.Rating:Eligible(player, opponent, rules)
    if eligible ~= bracket then return nil, reason or "invalid_record_bracket" end
    local after, delta = FD.Rating:Calculate(record.ratingBefore, record.opponentRatingBefore, won,
        player.level, opponent.level, rules)
    if record.ratingAfter ~= after or record.ratingDelta ~= delta then
        return nil, "inconsistent_record_rating"
    end
    return true
end

local function fresh(identity, counter, settings)
    local initial = FD.Rating:GetInitialRating()
    local function stats() return { rating = initial, wins = 0, losses = 0 } end
    return {
        schemaVersion = FD.C.SCHEMA_VERSION,
        -- Chains start at the stored initial rating, so a later change of
        -- INITIAL_RATING only affects databases created afterwards.
        player = { guid = identity.guid, initialRatings = { LEVELING = initial, MAX_LEVEL = initial },
            ratings = { LEVELING = stats(), MAX_LEVEL = stats() } },
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

local function validSettings(settings)
    return type(settings) == "table" and type(settings.debug) == "boolean"
end

local function initialRatings(player, legacy)
    local stored = not legacy and player.initialRatings
    if not stored then
        return { LEGACY = DEFAULT_INITIAL_RATING, LEVELING = DEFAULT_INITIAL_RATING, MAX_LEVEL = DEFAULT_INITIAL_RATING }
    end
    if type(stored) ~= "table" or not integer(stored.LEVELING) or not integer(stored.MAX_LEVEL) then return nil end
    for bracket in pairs(stored) do
        if bracket ~= "LEVELING" and bracket ~= "MAX_LEVEL" then return nil end
    end
    return stored
end

local function validateDatabase(saved, localGUID, legacy)
    if type(saved) ~= "table" or saved.schemaVersion ~= (legacy and 1 or FD.C.SCHEMA_VERSION) then
        return nil, "unsupported_database_version"
    end
    local player = saved.player
    if type(player) ~= "table" or player.guid ~= localGUID or type(saved.matches) ~= "table"
        or type(saved.finalized) ~= "table" or not validSettings(saved.settings)
        or not integer(saved.nonceCounter, 0) or saved.nonceCounter > MAX_COUNTER
        or (saved.archived ~= nil and type(saved.archived) ~= "table")
        or (saved.quarantine ~= nil and type(saved.quarantine) ~= "table") then
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
    local initial = initialRatings(player, legacy)
    if not initial then return nil, "invalid_initial_ratings" end
    local totals = {}
    for bracket in pairs(pools) do totals[bracket] = { rating = initial[bracket], wins = 0, losses = 0 } end
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

-- Settings and the nonce counter survive a fresh start when readable.
local function restart(identity, saved)
    local counter = type(saved) == "table" and saved.nonceCounter
    local settings = type(saved) == "table" and validSettings(saved.settings) and copy(saved.settings, {}, 1) or nil
    return fresh(identity, integer(counter, 0) and counter <= MAX_COUNTER and counter or 0, settings)
end

-- Moves the archives of `saved` into `archived` and returns the rest of it,
-- so archives never nest inside each other.
local function liftArchives(saved, archived)
    local rest = {}
    for key, value in pairs(saved) do rest[key] = value end
    rest.archivedNotice = nil
    if type(saved.archived) == "table" then
        rest.archived = nil
        for guid, entry in pairs(saved.archived) do
            local kept = nonempty(guid) and type(entry) == "table" and salvage(entry, 2)
            if kept then archived[guid] = kept end
        end
    end
    return rest
end

local function trimArchives(archived, keep)
    local count = 0
    for _ in pairs(archived) do count = count + 1 end
    while count > keep do
        local oldest, oldestAt
        for guid, entry in pairs(archived) do
            local at = integer(entry.archivedAt) and entry.archivedAt or 0
            if not oldest or at < oldestAt or (at == oldestAt and guid < oldest) then oldest, oldestAt = guid, at end
        end
        archived[oldest] = nil
        count = count - 1
    end
end

-- Per-character SavedVariables follow the character name, so a re-rolled
-- character (e.g. after a Hardcore death) inherits the old table. Keep it
-- under archived[oldGUID] and start fresh instead of refusing to load.
local function archive(saved, identity)
    local db, archived, guid = restart(identity, saved), {}, saved.player.guid
    local data, dropped = salvage(liftArchives(saved, archived), 3, saved)
    archived[guid] = nil
    trimArchives(archived, MAX_ARCHIVES - 1)
    local at = now()
    archived[guid] = { archivedAt = at, data = data, truncated = dropped }
    db.archived, db.archivedNotice = archived, { guid = guid, archivedAt = at }
    return db
end

local function open(saved, identity)
    if saved == nil then return fresh(identity) end
    local known = type(saved) == "table" and (saved.schemaVersion == 1 or saved.schemaVersion == FD.C.SCHEMA_VERSION)
    local owner = known and type(saved.player) == "table" and saved.player.guid
    if nonempty(owner) and owner ~= identity.guid then return archive(saved, identity) end
    -- Validate the entire original data before migration. Never overwrite a
    -- future/damaged SavedVariable or infer historical levels from today's level.
    local legacy = known and saved.schemaVersion == 1
    local valid, err = validateDatabase(saved, identity.guid, legacy)
    if not valid then return nil, err end
    if not legacy then
        saved.archivedNotice = nil -- Shown for the session that archived only.
        return saved
    end
    local preserved, copyError = Database:Copy(saved)
    if copyError then return nil, copyError end
    local migrated = fresh(identity, saved.nonceCounter, Database:Copy(saved.settings))
    migrated.legacy = preserved
    local _, migrationError = Database:Copy(migrated)
    if migrationError then return nil, migrationError end
    return migrated
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

-- Returns the database; db.archivedNotice is set when another character's
-- data was just archived.
function Database:Initialize(saved, localIdentity)
    self.data, self.bracket = nil, nil
    if not validIdentity(localIdentity) then return nil, "invalid_local_identity" end
    local db, err = open(saved, localIdentity)
    if not db then return nil, err end
    self.data = db
    -- Level APIs may not be ready at login. Preserve/read saved history while
    -- rated eligibility separately requires a complete, current level profile.
    self:SetBracket(localIdentity)
    return db
end

-- /duelrating repair after Initialize failed: a fresh database that keeps a
-- bounded copy of the unreadable data under `quarantine`.
function Database:Repair(saved, localIdentity)
    if not validIdentity(localIdentity) then return nil, "invalid_local_identity" end
    local _, reason = open(saved, localIdentity)
    if not reason then return nil, "nothing_to_repair" end
    local db, archived = restart(localIdentity, saved), {}
    local data, dropped = salvage(type(saved) == "table" and liftArchives(saved, archived) or saved, 2, saved)
    trimArchives(archived, MAX_ARCHIVES)
    db.archived = next(archived) and archived or nil
    db.quarantine = { data = data, quarantinedAt = now(), quarantineReason = reason, truncated = dropped }
    return db
end

-- What the saved file keeps besides this character's active ratings.
function Database:Kept()
    local db, kept = self.data, { archives = 0 }
    if not db then return kept end
    if type(db.archived) == "table" then
        for _ in pairs(db.archived) do kept.archives = kept.archives + 1 end
    end
    kept.archivedNow = type(db.archivedNotice) == "table"
    kept.quarantine = type(db.quarantine) == "table" and db.quarantine or nil
    return kept
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

-- Clears this character's ratings, history and legacy pool. Settings, other
-- characters' archives and quarantined data are not its history and stay.
function Database:Reset(localIdentity)
    local db = self.data
    if not db then
        return nil, "database_unavailable"
    end
    if not validIdentity(localIdentity) or localIdentity.guid ~= db.player.guid then
        return nil, "invalid_local_identity"
    end
    local reset = fresh(localIdentity, db.nonceCounter, db.settings)
    reset.archived, reset.quarantine = db.archived, db.quarantine
    self.data = reset
    self.bracket = FD.Rating:Bracket(localIdentity.level, localIdentity.maxLevel)
    return reset
end

local function currentRules(rules)
    if type(rules) ~= "table" then return false end
    for key, value in pairs(FD.Rating:Rules()) do
        if rules[key] ~= value then return false end
    end
    return true
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
    local stored, copyError = self:Copy(record)
    if copyError then
        return nil, copyError
    end
    if type(stored) ~= "table" then return nil, "invalid_record_version" end
    -- A new rating change always uses today's rules, and the record keeps
    -- them so a later rule change cannot invalidate it.
    stored.rules = stored.rules or FD.Rating:Rules()
    if not currentRules(stored.rules) then return nil, "invalid_record_rules" end
    local valid, err = validateRecord(stored, db.player.guid)
    if not valid then
        return nil, err
    end
    local stats = self:GetStats(stored.bracket)
    if stored.ratingBefore ~= stats.rating then
        return nil, "stale_rating_snapshot"
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

FD:RegisterStatus(12, function()
    local kept, lines = Database:Kept(), {}
    if kept.archives > 0 then
        lines[#lines + 1] = FD.Locale:Format("Saved data: %d archived earlier character(s) with this name.", kept.archives)
    end
    if kept.quarantine then
        lines[#lines + 1] = FD.Locale:Format("Saved data: unreadable data kept under 'quarantine' (%s).",
            tostring(kept.quarantine.quarantineReason or "?"))
    end
    return lines
end)
