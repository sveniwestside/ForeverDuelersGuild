local _, FD = ...

-- FD3|kind|nonce|echo|guid|peerGUID|role|rating|specId|classFile|wins|losses|verdict|level|maxLevel[|key=value...]
-- Fifteen strict fixed fields, then optional key=value extensions (the whole
-- payload stays printable ASCII and <= 255 bytes). Extensions only carry
-- informational data, so decoders read a known key when its value and kind
-- match and ignore every other trailing field (unknown key, malformed field,
-- value outside today's grammar, duplicate): a later version can add or
-- widen data without its packets being dropped here.
-- Known keys: v = sender addon version, r = short CANCEL reason code.
-- The lifecycle binds the envelope to the actual duel opponent and freezes
-- the reported profile; parsing alone does not establish consent.
local Protocol = {
    VERSION = FD.C.PROTOCOL_VERSION,
    WIRE_VERSION = "FD" .. FD.C.PROTOCOL_VERSION,
    LEGACY_WIRE = "FD2",
    MAX_BYTES = 255,
    FIELDS = 15,
}
FD.Protocol = Protocol

local kinds = { HELLO = true, HELLO_ACK = true, ACCEPT = true, START = true, RESULT = true, CANCEL = true }
-- Only used to recognize an outdated 0.5.x peer; FD2 is never processed.
local legacyKinds = { HELLO = true, HELLO_ACK = true, ACCEPT = true, COMMIT = true, CONFIRM = true,
    START_OK = true, START = true, RESULT = true, CANCEL = true }
local classes = {
    WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, PRIEST = true,
    DEATHKNIGHT = true, SHAMAN = true, MAGE = true, WARLOCK = true, MONK = true,
    DRUID = true, DEMONHUNTER = true, EVOKER = true,
}
local extensions = {
    v = { field = "version", pattern = "^%d[%w%.%-%+_]*$", limit = 24 },
    r = { field = "reason", pattern = "^%l[%l%d_]*$", limit = 16, kind = "CANCEL" },
}
local extensionOrder = { "v", "r" }

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

local function validExtension(key, value, kind)
    local spec = extensions[key]
    return type(value) == "string" and #value <= spec.limit and value:match(spec.pattern) ~= nil
        and (not spec.kind or spec.kind == kind)
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
    for key, spec in pairs(extensions) do
        local value = message[spec.field]
        if value ~= nil and not validExtension(key, value, message.kind) then return nil, "invalid " .. spec.field end
    end
    return true
end

local function number(value)
    return value == 0 and "0" or string.format("%.0f", value)
end

function Protocol:Encode(message)
    local valid, reason = validate(message)
    if not valid then return nil, reason end
    local fields = {
        self.WIRE_VERSION, message.kind, message.nonce, message.echo,
        message.guid, message.peerGUID, message.role, number(message.rating), number(message.specId),
        message.classFile, number(message.wins), number(message.losses), message.verdict,
        number(message.level), number(message.maxLevel),
    }
    for _, key in ipairs(extensionOrder) do
        local value = message[extensions[key].field]
        if value ~= nil then fields[#fields + 1] = key .. "=" .. value end
    end
    local payload = table.concat(fields, "|")
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

local function split(payload)
    local fields = {}
    for value in (payload .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = value end
    return fields
end

local function envelope(payload)
    if type(payload) ~= "string" or #payload == 0 or #payload > Protocol.MAX_BYTES then
        return nil, "invalid message length"
    end
    if payload:find("[^ -~]") then return nil, "message is not printable ASCII" end
    return split(payload)
end

function Protocol:Decode(payload)
    local fields, err = envelope(payload)
    if not fields then return nil, err end
    if fields[1] ~= self.WIRE_VERSION then return nil, "incompatible protocol version" end
    if #fields < self.FIELDS then return nil, "invalid field count" end
    local message = {
        protocolVersion = self.VERSION,
        kind = fields[2], nonce = fields[3], echo = fields[4],
        guid = fields[5], peerGUID = fields[6], role = fields[7],
        rating = parseInteger(fields[8]), specId = parseInteger(fields[9]),
        classFile = fields[10], wins = parseInteger(fields[11]),
        losses = parseInteger(fields[12]), verdict = fields[13],
        level = parseInteger(fields[14]), maxLevel = parseInteger(fields[15]),
    }
    for index = self.FIELDS + 1, #fields do
        local key, value = fields[index]:match("^([^=]+)=(.*)$")
        local spec = key and extensions[key]
        -- First valid occurrence wins; anything else is ignored (see header).
        if spec and message[spec.field] == nil and validExtension(key, value, message.kind) then
            message[spec.field] = value
        end
    end
    local valid, reason = validate(message)
    if not valid then return nil, reason end
    return message
end

-- A well-formed envelope of the previous wire version. Only identity fields
-- are returned: the caller may show "outdated peer" but never act on it.
function Protocol:Legacy(payload)
    local fields = envelope(payload)
    if not fields or #fields ~= self.FIELDS or fields[1] ~= self.LEGACY_WIRE or not legacyKinds[fields[2]]
        or not self:ValidNonce(fields[3]) or not self:ValidGUID(fields[5]) or not self:ValidGUID(fields[6])
        or (fields[7] ~= "INCOMING" and fields[7] ~= "OUTGOING") then return nil end
    return { kind = fields[2], guid = fields[5], peerGUID = fields[6] }
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

-- Server time embedded by Nonce, or nil for any other nonce shape.
function Protocol:NonceEpoch(nonce)
    if not self:ValidNonce(nonce) then return nil end
    local epoch = nonce:match("^(%x+)%-%x+%-%x+$")
    return epoch and #epoch <= 13 and tonumber(epoch, 16) or nil
end
