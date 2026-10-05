local _, FD = ...

-- Queue discovery and reservations are intentionally separate from FD.Protocol.
-- A successfully decoded queue packet never establishes rated-duel consent.
local Protocol = { VERSION = 1, WIRE_VERSION = "FDQ1", PREFIX = "ForeverDuelQ1", MAX_BYTES = 255,
    MAP_SCALE = 100000000 }
FD.QueueProtocol = Protocol

local profileFields = {
    "session", "guid", "rating", "level", "maxLevel", "scope", "levelGap",
    "ruleset", "faction", "joinedAt", "mapID", "continentID", "x", "y",
}
local controlFields = { "session", "peerSession", "ticket" }
local schemas = { QUERY = {}, PROFILE = profileFields, LEAVE = { "session", "guid" } }
-- VENUE is a setup record, never duel evidence. The receiver must separately
-- bind the native sender to its own recent test/confirmation before importing.
schemas.VENUE = { "venueID", "testPairGUID", "mapID", "continentID", "mapX", "mapY",
    "minPlayerLevel", "zoneMinLevel", "zoneMaxLevel", "faction", "hubFaction", "testedAt" }
for _, kind in ipairs({ "OFFER", "ACK", "COMMIT", "CONFIRM", "GROUP", "GO_ACK", "ARRIVED" }) do
    schemas[kind] = controlFields
end
schemas.POSITION = { "session", "peerSession", "ticket", "mapID", "continentID", "x", "y" }
schemas.PLAN = { "session", "peerSession", "ticket", "venueID", "deadline", "duration", "mapID", "continentID", "x", "y" }
schemas.PLAN_ACK = controlFields
schemas.READY = { "session", "peerSession", "ticket", "deadline" }
schemas.GO = schemas.PLAN
schemas.CANCEL = { "session", "peerSession", "ticket", "reason" }

local numeric = {
    rating = true, level = true, maxLevel = true, levelGap = true, joinedAt = true,
    mapID = true, continentID = true, x = true, y = true, deadline = true, duration = true,
    mapX = true, mapY = true, minPlayerLevel = true, zoneMinLevel = true, zoneMaxLevel = true, testedAt = true,
}
local scopes = { ZONE = true, CONTINENT = true, RULESET = true }
local rulesets = { NORMAL = true, PVP = true, RP = true, HARDCORE = true }
local factions = { Alliance = true, Horde = true }
local reasons = {
    CANCELLED = true, GROUP_TIMEOUT = true, TRAVEL_TIMEOUT = true, START_TIMEOUT = true,
    TECHNICAL = true, DUEL = true, FINISHED = true,
}

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
        and value == math.floor(value)
end

local function token(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum
        and value:match("^[a-f0-9%.%-]+$") ~= nil and value:find("[a-f0-9]") ~= nil
end

function Protocol:ValidGUID(value)
    return type(value) == "string" and #value <= 64
        and value:match("^Player%-%x+%-%x+$") ~= nil
end

local function location(value)
    if not integer(value.mapID, 0, 100000) or not integer(value.continentID, 0, 100000)
        or not integer(value.x, -1000000, 1000000) or not integer(value.y, -1000000, 1000000) then
        return nil, "invalid position"
    end
    if value.mapID == 0 then
        if value.mapID ~= 0 or value.continentID ~= 0 or value.x ~= 0 or value.y ~= 0 then
            return nil, "incomplete position"
        end
    end
    return true
end

-- Profile validation also works on adapter profiles carrying local metadata;
-- Encode projects those profiles onto the selected wire schema, so metadata
-- such as native transport names and receipt times never reaches the wire.
function Protocol:ValidProfile(value)
    if type(value) ~= "table" then return nil, "profile is not a table" end
    if not token(value.session, 32) then return nil, "invalid queue session" end
    if not self:ValidGUID(value.guid) then return nil, "invalid player GUID" end
    if not integer(value.rating, -100000, 100000) then return nil, "invalid rating" end
    if not integer(value.maxLevel, 1, 255) or not integer(value.level, 1, value.maxLevel) then
        return nil, "invalid level"
    end
    if not scopes[value.scope] then return nil, "invalid search scope" end
    if not integer(value.levelGap, 0, 5) then return nil, "invalid level gap" end
    if not rulesets[value.ruleset] then return nil, "invalid ruleset" end
    if not factions[value.faction] then return nil, "invalid faction" end
    if not integer(value.joinedAt, 0, 4102444800) then return nil, "invalid queue time" end
    return location(value)
end

local function validate(value)
    if type(value) ~= "table" then return nil, "packet is not a table" end
    if value.protocolVersion ~= nil and value.protocolVersion ~= Protocol.VERSION then
        return nil, "incompatible queue protocol version"
    end
    local fields = schemas[value.kind]
    if not fields then return nil, "unknown queue packet kind" end
    if value.kind == "QUERY" then return true end
    if value.kind == "PROFILE" then return Protocol:ValidProfile(value) end
    if value.kind == "VENUE" then
        if type(value.venueID) ~= "string" or #value.venueID == 0 or #value.venueID > 48
            or not value.venueID:match("^[a-z0-9_.%-]+$") then return nil, "invalid venue ID" end
        if not Protocol:ValidGUID(value.testPairGUID) then return nil, "invalid venue test partner" end
        if not integer(value.mapID, 1, 100000) or not integer(value.continentID, 0, 100000)
            or not integer(value.mapX, 0, Protocol.MAP_SCALE) or not integer(value.mapY, 0, Protocol.MAP_SCALE) then
            return nil, "invalid venue map position"
        end
        if not integer(value.minPlayerLevel, 1, 255) or not integer(value.zoneMinLevel, 1, 255)
            or not integer(value.zoneMaxLevel, value.zoneMinLevel, 255) then return nil, "invalid venue level range" end
        if not factions[value.faction] then return nil, "invalid venue faction" end
        if value.hubFaction ~= "NONE" and value.hubFaction ~= value.faction then return nil, "invalid venue hub faction" end
        if not integer(value.testedAt, 0, 4102444800) then return nil, "invalid venue test time" end
        return true
    end
    if not token(value.session, 32) then return nil, "invalid queue session" end
    if value.kind == "LEAVE" then
        if not Protocol:ValidGUID(value.guid) then return nil, "invalid player GUID" end
        return true
    end
    if not token(value.peerSession, 32) or value.session == value.peerSession then
        return nil, "invalid peer queue session"
    end
    if not token(value.ticket, 80) then return nil, "invalid match ticket" end
    if value.kind == "POSITION" then return location(value) end
    if value.kind == "READY" and not integer(value.deadline, 0, 4102444800) then
        return nil, "invalid duel start deadline"
    end
    if value.kind == "PLAN" or value.kind == "GO" then
        if type(value.venueID) ~= "string" or #value.venueID == 0 or #value.venueID > 48
            or not value.venueID:match("^[a-z0-9_.%-]+$") then return nil, "invalid venue ID" end
        if not integer(value.deadline, 0, 4102444800) then return nil, "invalid travel deadline" end
        if not integer(value.duration, 300, 900) then return nil, "invalid travel duration" end
        local ok, reason = location(value)
        if not ok or value.mapID == 0 then return nil, reason or "missing venue position" end
    elseif value.kind == "CANCEL" and not reasons[value.reason] then
        return nil, "invalid cancellation reason"
    end
    return true
end

function Protocol:Encode(value)
    local ok, reason = validate(value)
    if not ok then return nil, reason end
    local fields = { self.WIRE_VERSION, value.kind }
    for _, key in ipairs(schemas[value.kind]) do
        local field = value[key]
        fields[#fields + 1] = numeric[key] and (field == 0 and "0" or string.format("%.0f", field)) or field
    end
    local payload = table.concat(fields, "|")
    if #payload > self.MAX_BYTES then return nil, "queue packet exceeds byte limit" end
    return payload
end

local function parseInteger(value)
    if not value:match("^%-?%d+$") then return nil end
    local number = tonumber(value)
    if not number or number < -4102444800 or number > 4102444800
        or (number == 0 and value ~= "0") or string.format("%.0f", number) ~= value then return nil end
    return number
end

function Protocol:Decode(payload)
    if type(payload) ~= "string" or #payload == 0 or #payload > self.MAX_BYTES then
        return nil, "invalid queue packet length"
    end
    if payload:find("[^ -~]") then return nil, "queue packet is not printable ASCII" end
    local fields = {}
    for value in (payload .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = value end
    if fields[1] ~= self.WIRE_VERSION then return nil, "incompatible queue protocol version" end
    local schema = schemas[fields[2]]
    if not schema then return nil, "unknown queue packet kind" end
    if #fields ~= #schema + 2 then return nil, "invalid queue packet field count" end
    local packet = { kind = fields[2], protocolVersion = self.VERSION }
    for index, key in ipairs(schema) do
        local value = fields[index + 2]
        if numeric[key] then packet[key] = parseInteger(value) else packet[key] = value end
    end
    local ok, reason = validate(packet)
    if not ok then return nil, reason end
    return packet
end
