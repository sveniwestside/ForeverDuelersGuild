local _, FD = ...

-- FD2|kind|nonce|echo|guid|peerGUID|role|rating|specId|classFile|wins|losses|verdict|level|maxLevel
-- The lifecycle binds this fifteen-field envelope to the actual duel opponent
-- and freezes the reported profile; parsing alone does not establish consent.
local Protocol = {
    VERSION = FD.C.PROTOCOL_VERSION,
    WIRE_VERSION = "FD" .. FD.C.PROTOCOL_VERSION,
    MAX_BYTES = 255,
}
FD.Protocol = Protocol

local kinds = {
    HELLO = true, HELLO_ACK = true, ACCEPT = true, COMMIT = true,
    CONFIRM = true, START_OK = true, START = true, RESULT = true, CANCEL = true,
}
local classes = {
    WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, PRIEST = true,
    DEATHKNIGHT = true, SHAMAN = true, MAGE = true, WARLOCK = true, MONK = true,
    DRUID = true, DEMONHUNTER = true, EVOKER = true,
}

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
        and value == math.floor(value)
end

function Protocol:ValidGUID(value)
    return type(value) == "string" and #value <= 64
        and value:match("^Player%-%x+%-%x+$") ~= nil
end

function Protocol:ValidNonce(value)
    return type(value) == "string" and #value > 0 and #value <= 48
        and value:match("^[a-f0-9%.%-]+$") ~= nil and value:find("[a-f0-9]") ~= nil
end

local function validate(message)
    if type(message) ~= "table" then return nil, "message is not a table" end
    if message.protocolVersion ~= nil and message.protocolVersion ~= Protocol.VERSION then
        return nil, "incompatible protocol version"
    end
    if not kinds[message.kind] then return nil, "unknown message kind" end
    if not Protocol:ValidNonce(message.nonce) then return nil, "invalid nonce" end
    if message.kind == "HELLO" then
        if message.echo ~= "-" then return nil, "HELLO must not echo a nonce" end
    elseif not Protocol:ValidNonce(message.echo) then
        return nil, "missing or invalid echoed nonce"
    end
    if not Protocol:ValidGUID(message.guid) or not Protocol:ValidGUID(message.peerGUID)
        or message.guid == message.peerGUID then
        return nil, "invalid participant GUIDs"
    end
    if message.role ~= "INCOMING" and message.role ~= "OUTGOING" then
        return nil, "invalid duel role"
    end
    if not integer(message.rating, -100000, 100000) then return nil, "invalid rating" end
    if not integer(message.maxLevel, 1, 255) or not integer(message.level, 1, message.maxLevel) then
        return nil, "invalid level"
    end
    if not integer(message.specId, 0, 100000) then return nil, "invalid specialization" end
    if not classes[message.classFile] then return nil, "invalid class" end
    if not integer(message.wins, 0, 1000000000) or not integer(message.losses, 0, 1000000000) then
        return nil, "invalid record"
    end
    if message.kind == "RESULT" then
        if message.verdict ~= message.guid and message.verdict ~= message.peerGUID then
            return nil, "result winner is not a participant"
        end
    elseif message.verdict ~= "-" then
        return nil, "unexpected result verdict"
    end
    return true
end

function Protocol:Encode(message)
    local valid, reason = validate(message)
    if not valid then return nil, reason end
    local payload = table.concat({
        self.WIRE_VERSION, message.kind, message.nonce, message.echo,
        message.guid, message.peerGUID, message.role,
        message.rating == 0 and "0" or string.format("%.0f", message.rating),
        message.specId == 0 and "0" or string.format("%.0f", message.specId),
        message.classFile, message.wins == 0 and "0" or string.format("%.0f", message.wins),
        message.losses == 0 and "0" or string.format("%.0f", message.losses), message.verdict,
        string.format("%.0f", message.level), string.format("%.0f", message.maxLevel),
    }, "|")
    if #payload > self.MAX_BYTES then return nil, "message exceeds byte limit" end
    return payload
end

local function parseInteger(value)
    if not value:match("^%-?%d+$") then return nil end
    local number = tonumber(value)
    -- Canonical decimal syntax prevents exponents, whitespace, and alternate encodings.
    if not number or (number == 0 and value ~= "0") or number < -1000000000 or number > 1000000000
        or string.format("%.0f", number) ~= value then return nil end
    return number
end

function Protocol:Decode(payload)
    if type(payload) ~= "string" or #payload == 0 or #payload > self.MAX_BYTES then
        return nil, "invalid message length"
    end
    if payload:find("[^ -~]") then return nil, "message is not printable ASCII" end
    local fields = {}
    for value in (payload .. "|"):gmatch("([^|]*)|") do
        fields[#fields + 1] = value
    end
    if #fields ~= 15 then return nil, "invalid field count" end
    if fields[1] ~= self.WIRE_VERSION then return nil, "incompatible protocol version" end
    local message = {
        protocolVersion = self.VERSION,
        kind = fields[2], nonce = fields[3], echo = fields[4],
        guid = fields[5], peerGUID = fields[6], role = fields[7],
        rating = parseInteger(fields[8]), specId = parseInteger(fields[9]),
        classFile = fields[10], wins = parseInteger(fields[11]),
        losses = parseInteger(fields[12]), verdict = fields[13],
        level = parseInteger(fields[14]), maxLevel = parseInteger(fields[15]),
    }
    local valid, reason = validate(message)
    if not valid then return nil, reason end
    return message
end

function Protocol:MatchID(guidA, nonceA, guidB, nonceB)
    if not self:ValidGUID(guidA) or not self:ValidGUID(guidB) or guidA == guidB
        or not self:ValidNonce(nonceA) or not self:ValidNonce(nonceB) then
        return nil, "invalid match identity"
    end
    if guidB < guidA then guidA, nonceA, guidB, nonceB = guidB, nonceB, guidA, nonceA end
    return table.concat({ self.WIRE_VERSION, guidA, nonceA, guidB, nonceB }, ":")
end

local function hex(value)
    if value == 0 then return "0" end
    local digits, result = "0123456789abcdef", ""
    while value > 0 do
        local remainder = value % 16
        result = digits:sub(remainder + 1, remainder + 1) .. result
        value = math.floor(value / 16)
    end
    return result
end

function Protocol:Nonce(epoch, counter, random)
    -- No clock/random globals: the adapter supplies all entropy. Conversion avoids
    -- %x's platform-dependent integer width in Lua 5.1. This is not cryptographic.
    local maximum = 9007199254740991
    if not integer(epoch, 0, maximum) or not integer(counter, 0, maximum)
        or not integer(random, 0, maximum) then return nil, "invalid nonce inputs" end
    return hex(epoch) .. "-" .. hex(counter) .. "-" .. hex(random)
end
