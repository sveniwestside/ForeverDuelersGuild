-- Shared simulated client for the discovery specs (not a spec itself).
-- Each client loads the real Constants, Locale, Debug, Commands, Outbound,
-- Protocol, Rating, Database, Wow, Roster and Presence modules into a
-- private environment with fake native APIs. A network object moves addon
-- messages between clients with per-message latency, loss and throttling.
local Harness = {}

local TOKENS = { "player", "target", "mouseover", "focus" }
for i = 1, 4 do TOKENS[#TOKENS + 1] = "party" .. i end
for i = 1, 40 do TOKENS[#TOKENS + 1] = "raid" .. i end
for i = 1, 40 do TOKENS[#TOKENS + 1] = "nameplate" .. i end
Harness.TOKENS = TOKENS

-- Deterministic pseudo-random numbers for latency jitter and loss.
local function rng(seed)
    local state = seed or 12345
    return function()
        state = (state * 1103515245 + 12345) % 2147483648
        return state / 2147483648
    end
end
Harness.rng = rng

function Harness.identity(index, fields)
    local value = { guid = string.format("Player-1-%08X", 0x1000 + index), name = "Peer" .. index,
        surname = "Crowd", realm = "Forever", classFile = "ROGUE", level = 30, faction = "Alliance" }
    for key, field in pairs(fields or {}) do value[key] = field end
    return value
end

function Harness.fullName(identity, regional)
    if regional == false then return identity.name .. "-" .. identity.realm end
    return identity.name .. (identity.surname and " " .. identity.surname or "")
end

function Harness.client(options)
    options = options or {}
    local regional = options.regionalNames ~= false
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local state = { now = options.now or 100, mapID = options.mapID or 37, timers = {}, sent = {}, prints = {},
        joins = {}, selections = {}, reads = {}, filters = {}, units = {}, members = {}, calls = {},
        channelID = options.channelID or 6, displayIndex = options.displayIndex or 9, selected = 1,
        joined = options.joined or false, loaded = false, shown = false, regional = regional,
        sendResult = options.sendResult }
    state.secret = setmetatable({}, { __tostring = function() error("secret formatted") end,
        __index = function() error("secret indexed") end, __concat = function() error("secret joined") end })
    state.player = { guid = options.guid or "Player-1-0000AAAA", name = options.name or "Alpha",
        surname = options.surname or "One", realm = "Forever", classFile = options.classFile or "MAGE",
        level = options.level or 30, faction = options.faction or "Alliance" }
    state.units.player = state.player
    state.fullName = Harness.fullName(state.player, regional)
    local function count(name) state.calls[name] = (state.calls[name] or 0) + 1 end
    local function unit(token)
        if token == nil then return nil end
        return state.units[token]
    end

    env.GetTime = function() return state.now end
    env.GetServerTime = function() return 1700000000 + math.floor(state.now) end
    env.issecretvalue = function(value) return rawequal(value, state.secret) end
    env.InCombatLockdown = function() return state.combat or false end
    env.C_Timer = { After = function(delay, callback)
        state.timers[#state.timers + 1] = { at = state.now + delay, callback = callback }
    end }
    env.C_Map = { GetBestMapForUnit = function(token)
        if state.failMap then error("map API failed") end
        return token == "player" and state.mapID or nil
    end }
    env.UnitGUID = function(token)
        count("UnitGUID")
        if state.failIdentity then error("unit API failed") end
        local v = unit(token)
        return v and v.guid
    end
    env.UnitFullName = function(token)
        local v = unit(token)
        if v then return v.name, regional and v.surname or v.realm end
    end
    env.UnitNameUnmodified = function(token)
        local v = unit(token)
        if v then return v.name, v.surname end
    end
    env.NameUtil = { GetUnmodifiedUnitFullName = function(token)
        local v = unit(token)
        return v and Harness.fullName(v, true)
    end }
    env.UnitClass = function(token)
        local v = unit(token)
        if v then return v.classFile, v.classFile end
    end
    env.UnitLevel = function(token) local v = unit(token); return v and v.level end
    env.UnitExists = function(token) return unit(token) ~= nil end
    env.UnitIsPlayer = function(token)
        local v = unit(token)
        if v and v.isPlayer ~= nil then return v.isPlayer end
        return v ~= nil
    end
    env.UnitFactionGroup = function(token)
        local v = unit(token)
        if v then return v.faction, v.faction end
    end
    env.UnitTokenFromGUID = function(guid)
        count("UnitTokenFromGUID")
        for _, token in ipairs(TOKENS) do
            local v = state.units[token]
            if v and rawequal(v.guid, guid) then return token end
        end
    end
    env.GetMaxPlayerLevel = function() return state.maxLevel or 60 end
    env.GetNormalizedRealmName = function() return "Forever" end
    env.RegionalUniqueNamesEnabled = function() return regional end
    env.IsInGroup = function() return state.group ~= nil end
    env.IsInRaid = function() return false end
    env.GetNumGroupMembers = function() return state.group and 2 or 0 end
    env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) state.prints[#state.prints + 1] = text end }
    env.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
    env.ChatFrameUtil = { AddMessageEventFilter = function(event, callback)
        state.filters[#state.filters + 1] = { event = event, callback = callback }
    end }
    env.Enum = {
        RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2, MaxPrefixes = 3 },
        SendAddonMessageResult = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3,
            InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8,
            GeneralError = 9, NotInGuild = 10, AddOnMessageLockdown = 11, TargetOffline = 12 },
    }
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(prefix)
            state.prefix = prefix
            if state.failRegister then error("registration failed") end
            return options.registerResult or 0
        end,
        SendAddonMessage = function(prefix, payload, channel, target)
            if state.failSend then error("native send failed") end
            local packet = { prefix = prefix, payload = payload, channel = channel, target = target, at = state.now }
            local result = 0
            -- Targeted chat types need a target (the channel number for
            -- CHANNEL); the client rejects them with TargetRequired otherwise.
            if (channel == "CHANNEL" or channel == "WHISPER") and (type(target) ~= "string" or target == "") then result = 6
            elseif type(state.sendResult) == "function" then result = state.sendResult(packet)
            elseif state.sendResult ~= nil then result = state.sendResult end
            packet.result = result
            state.sent[#state.sent + 1] = packet
            return result
        end,
        GetChannelRosterInfo = function(index, row)
            state.reads[#state.reads + 1] = { index = index, row = row }
            if state.failRoster then error("roster temporarily unavailable") end
            if index ~= state.displayIndex or not state.joined or not state.loaded then return nil end
            local member = state.members[row]
            if member then return member.name, false, false, member.guid end
        end,
    }
    if options.general then env.C_ChatInfo.GetGeneralChannelLocalID = function() return options.general end end
    if options.channel ~= false then
        env.GetChannelName = function(name)
            if state.failChannel then error("channel query failed") end
            if name == "ForeverDuel" and state.joined then return state.channelID, "ForeverDuel" end
            return 0
        end
        env.JoinTemporaryChannel = function(name)
            state.joins[#state.joins + 1] = { name = name, at = state.now }
            if state.failJoin then error("join failed") end
            if not state.preventJoin then state.joined = true end
        end
        env.GetNumDisplayChannels = function() return state.displayIndex + 1 end
        env.GetChannelDisplayInfo = function(index)
            if index == state.displayIndex and state.joined then
                return "ForeverDuel", false, false, state.channelID, state.loaded and #state.members or nil, true
            end
            if index == 1 and options.defaults ~= false then return "General", false, false, 1, nil, true end
            if index == 1 then return "Channels", true, false, nil, nil, false end
            return "Trade " .. index, false, false, options.defaults ~= false and index or nil, 20, true
        end
        env.GetSelectedDisplayChannel = function() return state.selected end
        env.SetSelectedDisplayChannel = function(index)
            state.selections[#state.selections + 1] = { index = index, at = state.now }
            if state.unloadOnDeselect and index ~= state.displayIndex then state.loaded = false end
            state.selected = index
            if index == state.displayIndex then
                env.C_Timer.After(state.rosterDelay or 2, function()
                    if state.neverLoads or state.selected ~= index then return end
                    state.loaded = true
                    state:emit("CHANNEL_ROSTER_UPDATE", index, #state.members)
                end)
            end
        end
        env.ChannelFrame = { IsShown = function() return state.shown end,
            HookScript = function(_, script, callback) state.channelHooks = state.channelHooks or {}
                state.channelHooks[script] = callback end }
    end
    env.StartDuel = function(token)
        state.duels = state.duels or {}
        state.duels[#state.duels + 1] = token
    end
    env.SendChatMessage = function() error("Discovery must never send ordinary chat") end

    local FD = { Zone = { shown = false }, duel = { active = nil } }
    function FD.Zone:IsShown() return self.shown end
    function FD.Zone:RefreshIfShown() state.refreshes = (state.refreshes or 0) + 1 end
    function FD:Safe() error("Discovery must not enter duel-aborting recovery") end
    FD.queue = options.queue
    local function load(name)
        local chunk = assert(loadfile("ForeverDuel/" .. name .. ".lua"))
        setfenv(chunk, env)
        chunk("ForeverDuel", FD)
    end
    for _, name in ipairs({ "Constants", "Locale", "Native", "Debug", "Commands", "Outbound", "Protocol", "Rating", "Database", "Wow" }) do
        load(name)
    end
    -- Only discovery handlers are dispatched by state:emit.
    FD.eventHandlers = {}
    for _, name in ipairs({ "Roster", "Presence" }) do load(name) end
    if options.tooltip then load("Tooltip") end
    FD.Database:Initialize(nil, FD.Wow:Identity("player"))
    state.FD, state.env, state.P, state.R = FD, env, FD.Presence, FD.Roster

    function state:emit(event, ...)
        for _, handler in ipairs(FD.eventHandlers[event] or {}) do handler.run(...) end
    end
    function state:command(text) FD:Command(text) end
    function state:start()
        local ok = FD.Presence:Initialize()
        return ok
    end
    -- Run due timers up to `untilTime` (absolute).
    function state:runUntil(untilTime)
        local steps = 0
        while true do
            local at, index
            for i, timer in ipairs(self.timers) do
                if timer.at <= untilTime and (not at or timer.at < at) then at, index = timer.at, i end
            end
            if not index then break end
            self.now = math.max(self.now, at)
            local timer = table.remove(self.timers, index)
            timer.callback()
            steps = steps + 1
            assert(steps < 20000, "timers must not spin without advancing time")
        end
        self.now = math.max(self.now, untilTime)
    end
    function state:advance(seconds) self:runUntil(self.now + seconds) end
    function state:addUnit(token, identity)
        local copy = {}
        for key, value in pairs(identity) do copy[key] = value end
        self.units[token] = copy
        return copy
    end
    function state:whispers(tag)
        local result = {}
        for _, packet in ipairs(self.sent) do
            if packet.channel == "WHISPER" and (not tag or packet.payload:sub(1, #tag) == tag) then result[#result + 1] = packet end
        end
        return result
    end
    function state:packets(channel)
        local result = {}
        for _, packet in ipairs(self.sent) do
            if not channel or packet.channel == channel then result[#result + 1] = packet end
        end
        return result
    end
    -- Raw delivery, as the network does it.
    function state:inject(payload, sender, distribution, localID)
        self:emit("CHAT_MSG_ADDON", "ForeverDuelZone2", payload, distribution or "WHISPER", sender, "", 0,
            localID or 0, "", 0)
    end
    -- A whispered FDP2 profile handed in by a spec models the answer to our
    -- own query: Presence keeps an unsolicited whisper of an untrusted sender
    -- out of its lookups (use inject for that case).
    function state:receive(payload, sender, distribution, localID)
        if (distribution or "WHISPER") == "WHISPER" and type(payload) == "string" and payload:sub(1, 5) == "FDP2|" then
            local name = FD.Presence:Canonical(sender)
            if name then FD.Presence.asked[name] = self.now end
        end
        self:inject(payload, sender, distribution, localID)
    end
    function state:systemMessage(text)
        for _, filter in ipairs(self.filters) do
            if filter.event == "CHAT_MSG_SYSTEM" and filter.callback(nil, "CHAT_MSG_SYSTEM", text) then return true end
        end
        return false
    end
    function state:trace(which)
        return FD.Debug:RequestTrace(64, which)
    end
    function state:profile(identity, mapID, tag)
        return string.format("%s|%s|%d|%d|%s|%d|60", tag or "FDP2", identity.guid, identity.rating or 1500,
            mapID or self.mapID, identity.classFile or "ROGUE", identity.level or 30)
    end
    return state
end

-- A network of clients and lightweight bots. Messages submitted by a client
-- (native result Success) are delivered after latency, unless lost.
function Harness.network(options)
    options = options or {}
    local net = { clients = {}, bots = {}, inflight = {}, now = options.now or 100, random = rng(options.seed),
        latency = options.latency or 0.4, jitter = options.jitter or 0.2, loss = options.loss or 0,
        routeLatency = options.routeLatency,
        channelDelivery = options.channelDelivery ~= false, delivered = 0, lost = 0, groups = {}, log = {} }
    function net:add(client)
        client.now = self.now
        client.cursor = #client.sent
        self.clients[#self.clients + 1] = client
        return client
    end
    -- A bot answers queries with a profile and can query/ping by itself.
    function net:bot(identity, fields)
        local bot = { identity = identity, name = Harness.fullName(identity, true), received = {},
            answers = not (fields and fields.silent), mapID = fields and fields.mapID or 37 }
        self.bots[bot.name] = bot
        return bot
    end
    -- Like the server, whisper delivery ignores the case of the name.
    function net:find(name)
        for _, client in ipairs(self.clients) do if client.fullName:lower() == name:lower() then return client end end
    end
    function net:findBot(name)
        for botName, bot in pairs(self.bots) do if botName:lower() == name:lower() then return bot end end
    end
    function net:deliver(packet)
        local sender = packet.from
        if packet.channel == "WHISPER" then
            local client = self:find(packet.target)
            if client then
                client:inject(packet.payload, sender.fullName, "WHISPER")
            elseif self:findBot(packet.target) then
                local bot = self:findBot(packet.target)
                bot.received[#bot.received + 1] = { payload = packet.payload, at = self.now, from = sender.fullName }
                if bot.answers and packet.payload:sub(1, 5) == "FDQ2|" then
                    self:schedule({ fromBot = bot, payload = string.format("FDP2|%s|1500|%d|ROGUE|30|60",
                        bot.identity.guid, bot.mapID), channel = "WHISPER", target = sender.fullName })
                elseif packet.payload:sub(1, 5) == "PING|" then
                    self:schedule({ fromBot = bot, payload = "PONG|" .. packet.payload:sub(6), channel = "WHISPER",
                        target = sender.fullName })
                end
            elseif self.offline and self.offline[packet.target] then
                sender:systemMessage(string.format("No player named '%s' is currently playing.", packet.target))
            end
        elseif packet.channel == "CHANNEL" and self.channelDelivery then
            for _, client in ipairs(self.clients) do
                if client.joined then client:inject(packet.payload, sender.fullName, "CHANNEL", client.channelID) end
            end
        elseif packet.channel == "PARTY" then
            for _, client in ipairs(self.clients) do
                if client ~= sender and client.group == sender.group and client.group then
                    client:inject(packet.payload, sender.fullName, "PARTY")
                end
            end
        end
    end
    function net:schedule(packet)
        if self.loss > 0 and self.random() < self.loss then self.lost = self.lost + 1; return end
        local latency = self.routeLatency and self.routeLatency[packet.channel] or self.latency
        packet.deliverAt = self.now + latency + self.jitter * self.random()
        self.inflight[#self.inflight + 1] = packet
    end
    -- Bot-originated message to a client.
    function net:botSend(bot, target, payload, channel)
        self:schedule({ fromBot = bot, payload = payload, channel = channel or "WHISPER", target = target })
    end
    function net:collect()
        for _, client in ipairs(self.clients) do
            while client.cursor < #client.sent do
                client.cursor = client.cursor + 1
                local packet = client.sent[client.cursor]
                if packet.result == 0 and packet.prefix == "ForeverDuelZone2" then
                    self:schedule({ from = client, payload = packet.payload, channel = packet.channel,
                        target = packet.target })
                end
            end
        end
    end
    function net:step(dt)
        self.now = self.now + dt
        for _, client in ipairs(self.clients) do client:runUntil(self.now) end
        self:collect()
        local remaining, due = {}, {}
        for _, packet in ipairs(self.inflight) do
            if packet.deliverAt <= self.now then due[#due + 1] = packet else remaining[#remaining + 1] = packet end
        end
        self.inflight = remaining
        table.sort(due, function(a, b) return a.deliverAt < b.deliverAt end)
        for _, packet in ipairs(due) do
            self.delivered = self.delivered + 1
            if packet.fromBot then
                local client = self:find(packet.target)
                self.log[#self.log + 1] = { from = packet.fromBot.name, to = packet.target, payload = packet.payload, at = self.now }
                if client then client:inject(packet.payload, packet.fromBot.name, packet.channel) end
            else
                self:deliver(packet)
            end
        end
        self:collect()
    end
    function net:advance(seconds, dt)
        dt = dt or 0.05
        local stop = self.now + seconds
        while self.now < stop - 1e-9 do self:step(math.min(dt, stop - self.now)) end
    end
    return net
end

return Harness
