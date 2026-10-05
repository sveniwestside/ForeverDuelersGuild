local _, FD = ...

FD.C = {
    VERSION = "0.6.0", PROTOCOL_VERSION = 2, SCHEMA_VERSION = 2,
    PREFIX = "ForeverDuel2", INITIAL_RATING = 1500, K_FACTOR = 32,
    MAX_LEVEL_DIFFERENCE = 5, LEVEL_RATING_WEIGHT = 20,
    PRESENCE_TIMEOUT = 4, NEGOTIATION_TIMEOUT = 12, PENDING_TIMEOUT = 50,
    INCOMING_RETRY_INTERVAL = 0.5,
    HELLO_RETRY_INTERVAL = 2,
    START_TIMEOUT = 8, RESULT_TIMEOUT = 8, MATCH_TIMEOUT = 1200,
    RESULT_RETRIES = 2, RESULT_RETRY_INTERVAL = 1,
    SEND_INTERVAL = 0.15, MAX_QUEUE = 24, RECENT_COUNT = 5,
}
-- The four-second presence indicator is not the native request lifetime.
FD.C.OUTGOING_TIMEOUT = FD.C.PENDING_TIMEOUT

function FD.Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = FD.Copy(child) end
    return result
end

-- Slash subcommands and status sections are registered by the module that
-- owns them, so no single file has to know every subsystem's details.
--   FD.commands[name] = { run = function(rest) end, help = "...", order = n, anyState = bool }
--   FD.statusProviders[#+1] = { order = n, lines = function() return { "line", ... } end }
FD.commands = FD.commands or {}
FD.statusProviders = FD.statusProviders or {}
-- Game events are registered the same way. Core's frame registers every
-- collected event after all modules have loaded and dispatches each handler
-- through FD:Safe. Handlers run only after initialization unless `always`.
--   FD.eventHandlers[event] = { { run = fn(...), always = bool, optional = bool }, ... }
FD.eventHandlers = FD.eventHandlers or {}

function FD:OnEvent(event, run, always, optional)
    if type(event) ~= "string" or type(run) ~= "function" then return end
    local list = self.eventHandlers[event] or {}
    self.eventHandlers[event] = list
    list[#list + 1] = { run = run, always = always == true, optional = optional == true }
end

function FD:RegisterCommand(name, run, help, order, anyState)
    if type(name) ~= "string" or type(run) ~= "function" then return end
    self.commands[name] = { run = run, help = help, order = order or 50, anyState = anyState == true }
end

function FD:RegisterStatus(order, lines)
    if type(lines) ~= "function" then return end
    self.statusProviders[#self.statusProviders + 1] = { order = order or 50, lines = lines }
end
