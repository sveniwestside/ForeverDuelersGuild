local _, FD = ...

FD.C = {
    VERSION = "0.4.5", PROTOCOL_VERSION = 2, SCHEMA_VERSION = 2,
    PREFIX = "ForeverDuel2", INITIAL_RATING = 1500, K_FACTOR = 32,
    MAX_LEVEL_DIFFERENCE = 5, LEVEL_RATING_WEIGHT = 20,
    PRESENCE_TIMEOUT = 4, NEGOTIATION_TIMEOUT = 12, PENDING_TIMEOUT = 50,
    INCOMING_RETRY_INTERVAL = 0.5,
    HELLO_RETRY_INTERVAL = 2,
    START_TIMEOUT = 8, RESULT_TIMEOUT = 8, MATCH_TIMEOUT = 1200,
    RESULT_RETRIES = 2, RESULT_RETRY_INTERVAL = 1,
    SEND_INTERVAL = 0.15, MAX_QUEUE = 24, RECENT_COUNT = 5,
}

function FD.Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = FD.Copy(child) end
    return result
end
