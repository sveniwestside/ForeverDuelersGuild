local _, FD = ...

-- Queue discovery, invitation binding and travel status are intentionally
-- separate from FD.Protocol. A decoded queue packet never establishes
-- rated-duel consent, native identity or result evidence. Protocol 2 replaces
-- the whispered four-step reservation with invite-first pairing; FDQ1 packets
-- are rejected as an incompatible version.
local Protocol = { VERSION = 2, WIRE_VERSION = "FQ2", PREFIX = "ForeverDuelQ2", MAX_BYTES = 255,
    MAP_SCALE = 100000000, DIGEST_SIZE = 8 }
FD.QueueProtocol = Protocol

local ticketFields = { "session", "peerSession", "ticket" }
local position = { "mapID", "continentID", "x", "y" }
local function with(base, ...)
    local result = {}
    for _, key in ipairs(base) do result[#result + 1] = key end
    for i = 1, select("#", ...) do
        local extra = select(i, ...)
        if type(extra) == "table" then
            for _, key in ipairs(extra) do result[#result + 1] = key end
        else result[#result + 1] = extra end
    end
    return result
end

local schemas = {
    QUERY = {},
    PROFILE = { "session", "guid", "rating", "level", "maxLevel", "scope", "levelGap",
        "ruleset", "faction", "joinedAt", "mapID", "continentID", "x", "y", "venues" },
    LEAVE = { "session", "guid" },
    -- Ticket-bound controls. OFFER is informational: the native invitation and
    -- Blizzard's own accept dialog are the pairing step.
    OFFER = ticketFields,
    GROUP = with(ticketFields, position),
    PLAN = with(ticketFields, "venueID", "deadline", "duration", position),
    PLAN_ACK = with(ticketFields, "venueID", "deadline"),
    PLAN_REJECT = with(ticketFields, "venueID"),
    STATUS = with(ticketFields, position, "flags"),
    CANCEL = with(ticketFields, "reason"),
    -- VENUE is a setup record, never duel evidence. The receiver must bind the
    -- native sender to its own recent test before importing and answers with
    -- VENUE_ACK (the ID it now holds) or VENUE_REJECT.
    VENUE = { "venueID", "testPairGUID", "mapID", "continentID", "mapX", "mapY",
        "minPlayerLevel", "zoneMinLevel", "zoneMaxLevel", "faction", "hubFaction", "testedAt" },
    VENUE_ACK = { "venueID", "keptID" },
    VENUE_REJECT = { "venueID", "reason" },
}
Protocol.TICKET_KINDS = { OFFER = true, GROUP = true, PLAN = true, PLAN_ACK = true,
    PLAN_REJECT = true, STATUS = true, CANCEL = true }
Protocol.SETUP_KINDS = { VENUE = true, VENUE_ACK = true, VENUE_REJECT = true }

local numeric = {
    rating = true, level = true, maxLevel = true, levelGap = true, joinedAt = true,
    mapID = true, continentID = true, x = true, y = true, deadline = true, duration = true,
    mapX = true, mapY = true, minPlayerLevel = true, zoneMinLevel = true, zoneMaxLevel = true,
    testedAt = true, flags = true,
}
local scopes = { ZONE = true, CONTINENT = true, RULESET = true }
local rulesets = { NORMAL = true, PVP = true, RP = true, HARDCORE = true }
local factions = { Alliance = true, Horde = true }
-- Every cancellation names its cause; the receiving UI explains it as the
-- opponent's client's reason.
Protocol.REASONS = {
    CANCELLED = true, DECLINED = true, BUSY = true, INVITE_FAILED = true, GROUP_TIMEOUT = true,
    PEER_SILENT = true, GROUP_CHANGED = true, OPPONENT_LEFT = true, NO_VENUE = true,
    PLAN_INVALID = true, TRAVEL_TIMEOUT = true, START_TIMEOUT = true, DUEL = true,
    FINISHED = true, ERROR = true, RELOAD = true,
}
Protocol.VENUE_REJECTIONS = { NO_TEST = true, MISMATCH = true, METADATA = true, TERRITORY = true,
    BUSY = true, HUB = true, FULL = true, INVALID = true }
Protocol.ARRIVED, Protocol.READY = 1, 2

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
        and value == math.floor(value)
end

local function token(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum
        and value:match("^[a-f0-9%.%-]+$") ~= nil and value:find("[a-f0-9]") ~= nil
end

local function venueID(value)
    return type(value) == "string" and #value > 0 and #value <= 48 and value:match("^[a-z0-9_.%-]+$") ~= nil
end

function Protocol:ValidGUID(value)
    return type(value) == "string" and #value <= 64
        and value:match("^Player%-%x+%-%x+$") ~= nil
end

-- Up to DIGEST_SIZE five-hex-digit venue hashes joined by ".", or "-" when the
-- sender has no eligible tested place.
function Protocol:ValidDigest(value)
    if value == "-" then return true end
    if type(value) ~= "string" or #value > self.DIGEST_SIZE * 6 - 1 then return false end
    for part in (value .. "."):gmatch("([^%.]*)%.") do
        if not part:match("^%x%x%x%x%x$") or part:find("%u") then return false end
    end
    return true
end

local function location(value)
    if not integer(value.mapID, 0, 100000) or not integer(value.continentID, 0, 100000)
        or not integer(value.x, -1000000, 1000000) or not integer(value.y, -1000000, 1000000) then
        return nil, "invalid position"
    end
    if value.mapID == 0 and (value.continentID ~= 0 or value.x ~= 0 or value.y ~= 0) then
        return nil, "incomplete position"
    end
    return true
end

-- Profile validation also works on adapter profiles carrying local metadata;
-- Encode projects those profiles onto the wire schema, so metadata such as
-- native transport names and receipt times never reaches the wire.
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
    if not self:ValidDigest(value.venues) then return nil, "invalid venue digest" end
    return location(value)
end

local function validVenue(value)
    if not venueID(value.venueID) then return nil, "invalid venue ID" end
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

local function validate(value)
    if type(value) ~= "table" then return nil, "packet is not a table" end
    if value.protocolVersion ~= nil and value.protocolVersion ~= Protocol.VERSION then
        return nil, "incompatible queue protocol version"
    end
    local kind = value.kind
    if not schemas[kind] then return nil, "unknown queue packet kind" end
    if kind == "QUERY" then return true end
    if kind == "PROFILE" then return Protocol:ValidProfile(value) end
    if kind == "VENUE" then return validVenue(value) end
    if kind == "VENUE_ACK" then
        if not venueID(value.venueID) or not venueID(value.keptID) then return nil, "invalid venue ID" end
        return true
    end
    if kind == "VENUE_REJECT" then
        if not venueID(value.venueID) then return nil, "invalid venue ID" end
        if not Protocol.VENUE_REJECTIONS[value.reason] then return nil, "invalid venue rejection" end
        return true
    end
    if not token(value.session, 32) then return nil, "invalid queue session" end
    if kind == "LEAVE" then
        if not Protocol:ValidGUID(value.guid) then return nil, "invalid player GUID" end
        return true
    end
    if not token(value.peerSession, 32) or value.session == value.peerSession then
        return nil, "invalid peer queue session"
    end
    if not token(value.ticket, 80) then return nil, "invalid match ticket" end
    if kind == "GROUP" then return location(value) end
    if kind == "STATUS" then
        if not integer(value.flags, 0, 3) then return nil, "invalid status flags" end
        return location(value)
    end
    if kind == "CANCEL" then
        if not Protocol.REASONS[value.reason] then return nil, "invalid cancellation reason" end
        return true
    end
    if kind == "PLAN" or kind == "PLAN_ACK" or kind == "PLAN_REJECT" then
        if not venueID(value.venueID) then return nil, "invalid venue ID" end
        if kind == "PLAN_REJECT" then return true end
        if not integer(value.deadline, 0, 4102444800) then return nil, "invalid travel deadline" end
        if kind == "PLAN_ACK" then return true end
        if not integer(value.duration, 300, 900) then return nil, "invalid travel duration" end
        local ok, reason = location(value)
        if not ok or value.mapID == 0 then return nil, reason or "missing venue position" end
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
