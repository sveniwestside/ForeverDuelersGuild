return function(_, equal)
    -- Real discovery and identity adapters, with two independent native clients.
    local function client(options)
        options = options or {}
        local env = setmetatable({}, { __index = _G })
        env._G = env
        local state = { now = 100, mapID = 37, frames = {}, timers = {}, sent = {}, logs = {},
            units = {}, plates = {}, prefixes = {}, joins = 0, sendResult = 0 }
        state.identity = { guid = options.guid or "Player-1-AAAA", name = options.name or "Alpha",
            surname = options.surname or "One", realm = "Forever", classFile = options.classFile or "MAGE",
            level = 30, isPlayer = true }
        state.units.player = state.identity
        state.secret = setmetatable({}, { __tostring = function() error("secret formatted") end,
            __index = function() error("secret indexed") end, __concat = function() error("secret joined") end })
        local FD = { Debug = {}, Zone = {}, duel = { active = { state = "READY" } } }
        function FD.Debug:Log(...) state.logs[#state.logs + 1] = { ... } end
        function FD.Zone:RefreshIfShown() end
        function FD:Safe() error("Advisory discovery must not enter rated recovery") end
        env.GetTime = function() return state.now end
        env.issecretvalue = function(value) return rawequal(value, state.secret) end
        env.InCombatLockdown = function() return false end
        env.C_Map = { GetBestMapForUnit = function() return state.mapID end }
        env.UnitGUID = function(unit) local v = state.units[unit]; return v and v.guid end
        env.UnitFullName = function(unit)
            local v = state.units[unit]
            if v then return v.name, v.realm end
        end
        env.UnitNameUnmodified = function(unit)
            local v = state.units[unit]
            if v then return v.name, v.surname end
        end
        env.NameUtil = { GetUnmodifiedUnitFullName = function(unit)
            local v = state.units[unit]
            return v and (v.name .. " " .. v.surname)
        end }
        env.UnitClass = function(unit)
            local v = state.units[unit]
            if v then return v.classFile, v.classFile end
        end
        env.UnitLevel = function(unit) local v = state.units[unit]; return v and v.level end
        env.UnitIsPlayer = function(unit) local v = state.units[unit]; return v and v.isPlayer or false end
        env.UnitExists = function(unit) return state.units[unit] ~= nil end
        env.GetMaxPlayerLevel = function() return 60 end
        env.GetNormalizedRealmName = function() return "Forever" end
        env.RegionalUniqueNamesEnabled = function() return options.regionalNames ~= false end
        env.C_NamePlate = { GetNamePlates = function() return state.plates end }
        env.Enum = { RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
            SendAddonMessageResult = { Success = 0, InvalidPrefix = 2, AddonMessageThrottle = 3 } }
        env.C_ChatInfo = {
            RegisterAddonMessagePrefix = function(prefix)
                state.prefixes[#state.prefixes + 1] = prefix
                return 0
            end,
            SendAddonMessage = function(prefix, payload, distribution, target)
                state.sent[#state.sent + 1] = { prefix = prefix, payload = payload,
                    distribution = distribution, target = target, at = state.now,
                    accepted = not state.failSend and state.sendResult == 0 }
                if state.failSend then error("native send unavailable") end
                return state.sendResult
            end,
        }
        -- No channel API is deliberately the default. The fallback must start.
        if options.channel == "unusable" then
            env.GetChannelName = function() return 0 end
            env.JoinTemporaryChannel = function()
                state.joins = state.joins + 1
                if state.failJoin then error("channel join unavailable") end
            end
        end
        env.C_Timer = { After = function(delay, callback)
            state.timers[#state.timers + 1] = { at = state.now + delay, callback = callback }
        end }
        env.CreateFrame = function()
            local frame = { events = {}, scripts = {} }
            function frame:RegisterEvent(event) self.events[event] = true end
            function frame:SetScript(event, callback) self.scripts[event] = callback end
            state.frames[#state.frames + 1] = frame
            return frame
        end
        for _, name in ipairs({ "Constants", "Protocol", "Rating", "Database", "Wow", "Presence" }) do
            local chunk = assert(loadfile("ForeverDuel/" .. name .. ".lua"))
            setfenv(chunk, env)
            chunk("ForeverDuel", FD)
        end
        FD.Database:Initialize(nil, FD.Wow:Identity("player"))
        state.FD, state.env, state.active = FD, env, FD.duel.active
        function state:emit(event, ...)
            for _, frame in ipairs(self.frames) do
                if frame.events[event] and frame.scripts.OnEvent then frame.scripts.OnEvent(frame, event, ...) end
            end
        end
        function state:advance(seconds)
            local stop, steps = self.now + seconds, 0
            while true do
                local at, index
                for i, timer in ipairs(self.timers) do
                    if timer.at <= stop and (not at or timer.at < at) then at, index = timer.at, i end
                end
                if not index then break end
                self.now = at
                local timer = table.remove(self.timers, index)
                timer.callback()
                steps = steps + 1
                assert(steps < 2000, "whisper timer advances time")
            end
            self.now = stop
        end
        function state:name()
            return options.regionalNames == false and (self.identity.name .. "-Forever")
                or (self.identity.name .. " " .. self.identity.surname)
        end
        function state:receive(payload, sender, distribution, prefix)
            self:emit("CHAT_MSG_ADDON", prefix or "ForeverDuelZone2", payload,
                distribution or "WHISPER", sender or "Beta Two", nil, 0, 0)
        end
        function state:preserved(label)
            equal(self.FD.duel.active, self.active, label .. " preserves active duel")
            equal(self.active.state, "READY", label .. " preserves consent")
            equal(self.FD.Database.data.player.ratings.LEVELING.rating, 1500, label .. " preserves rating")
            equal(#self.FD.Database.data.matches, 0, label .. " preserves match history")
        end
        return state
    end
    local function peer(index)
        return { guid = string.format("Player-2-%X", index or 1), name = "Peer" .. (index or 1),
            surname = "Nearby", realm = "Forever", classFile = "ROGUE", level = 30, isPlayer = true }
    end
    local function sent(c, tag)
        local result = {}
        for _, packet in ipairs(c.sent) do
            if packet.distribution == "WHISPER" and (not tag or packet.payload:sub(1, 4) == tag) then
                result[#result + 1] = packet
            end
        end
        return result
    end
    local REQUEST = "FDQ2|Player-1-BBBB|1642|37|ROGUE|30|60"
    local PROFILE = "FDP2|Player-1-BBBB|1642|37|ROGUE|30|60"

    -- One side observes a nearby target; a request carries the requester's
    -- validated profile so discovery works in both directions in one exchange.
    for _, channel in ipairs({ "absent", "unusable" }) do
        local a = client({ channel = channel })
        local b = client({ channel = channel, guid = "Player-1-BBBB", name = "Beta", surname = "Two", classFile = "ROGUE" })
        a.units.target = b.identity
        equal(a.FD.Presence:Initialize(), true, channel .. " channel supports nearby discovery")
        equal(b.FD.Presence:Initialize(), true, channel .. " channel supports reciprocal discovery")
        equal(#a.FD.Presence:GetPlayers(), 0, "native unit alone is not an addon player")
        local cursorA, cursorB = 0, 0
        local function exchange()
            while cursorA < #a.sent do
                cursorA = cursorA + 1
                local packet = a.sent[cursorA]
                if packet.accepted and packet.distribution == "WHISPER" and packet.target == b:name() then
                    b:receive(packet.payload, a:name(), packet.distribution, packet.prefix)
                end
            end
            while cursorB < #b.sent do
                cursorB = cursorB + 1
                local packet = b.sent[cursorB]
                if packet.accepted and packet.distribution == "WHISPER" and packet.target == a:name() then
                    a:receive(packet.payload, b:name(), packet.distribution, packet.prefix)
                end
            end
        end
        for _ = 1, 12 do a:advance(1); b:advance(1); exchange() end
        equal(#sent(a, "FDQ2"), 1, "one nearby target sends one paced query")
        equal(sent(a, "FDQ2")[1].target, "Beta Two", "query uses native surname recipient")
        equal(sent(a, "FDQ2")[1].payload, "FDQ2|Player-1-AAAA|1500|37|MAGE|30|60", "query advertises public profile")
        equal(sent(a, "FDQ2")[1].prefix, "ForeverDuelZone2", "query uses discovery prefix")
        equal(#sent(b, "FDP2"), 1, "request produces one deferred profile reply")
        equal(#a.FD.Presence:GetPlayers(), 1, "requester discovers responding addon")
        equal(#b.FD.Presence:GetPlayers(), 1, "responder discovers requester without target")
        equal(a.FD.Presence:GetPlayers()[1].fullName, "Beta Two", "response preserves canonical surname")
        equal(b.FD.Presence:GetPlayers()[1].fullName, "Alpha One", "request preserves canonical surname")
        equal(#sent(a, "FDP2"), 0, "reply never triggers another reply")
        for _ = 1, 20 do a:advance(1); b:advance(1); exchange() end
        equal(#sent(a), 1, "stable target does not flood queries")
        equal(#sent(b), 1, "reply cannot cause ping pong")
        for _ = 1, 75 do a:advance(1); b:advance(1); exchange() end
        equal(#sent(a, "FDQ2") >= 2, true, "nearby peer is refreshed automatically")
        local queries = sent(a, "FDQ2")
        for i = 2, #queries do equal(queries[i].at - queries[i - 1].at >= 45, true, "per-peer queries wait 45 seconds") end
        equal(#a.FD.Presence:GetPlayers(), 1, "repeated discovery preserves fresh peer")
        a.units.target = nil
        a:advance(125)
        equal(a.FD.Presence:GetPlayer(b.identity.guid), nil, "silent peer expires after native unit disappears")
        a:preserved("nearby discovery and expiry")
        b:preserved("nearby reply")
    end

    -- Every automatic source is independent of the custom channel; mouseover
    -- remains passive, as inspecting a tooltip must not initiate discovery.
    for _, unit in ipairs({ "target", "focus", "party1", "raid40", "nameplate1" }) do
        local c = client()
        c.FD.Presence:Initialize()
        c:advance(6)
        c.units[unit] = peer()
        if unit == "target" then c:emit("PLAYER_TARGET_CHANGED") end
        if unit == "nameplate1" then
            c.plates = { { namePlateUnitToken = unit } }
            c:emit("NAME_PLATE_UNIT_ADDED", unit)
        end
        equal(#sent(c), 0, unit .. " event queues rather than sending synchronously")
        c:advance(12)
        equal(#sent(c, "FDQ2"), 1, unit .. " discovers native nearby player")
        equal(#c.FD.Presence:GetPlayers(), 0, unit .. " does not assume a nonresponding unit has addon")
    end
    local c = client()
    c.units.mouseover = peer()
    c.FD.Presence:Initialize()
    c:emit("UPDATE_MOUSEOVER_UNIT")
    c:advance(55)
    equal(#sent(c), 0, "mouseover and tooltip observation sends nothing")
    c.units.target = peer()
    c.units.target.isPlayer = false
    c:advance(6)
    equal(#sent(c), 0, "non-player target cannot be queried")

    c = client({ regionalNames = false })
    c.units.target = peer()
    c.FD.Presence:Initialize()
    c:advance(6)
    equal(sent(c, "FDQ2")[1].target, "Peer1-Forever", "ordinary realm clients use canonical realm name")

    -- Validate the complete profile before accepting a request or replying.
    c = client()
    c.FD.Presence:Initialize()
    local invalid = { "", "FDQ2", REQUEST .. "|extra", "FDQ2|bad-guid|1642|37|ROGUE|30|60",
        "FDQ2|Player-1-BBBB|nan|37|ROGUE|30|60", "FDQ2|Player-1-BBBB|1642|0|ROGUE|30|60",
        "FDQ2|Player-1-BBBB|1642|37|ROGUE|61|60", "FDQ2|Player-1-BBBB|1642|37|ROGUE|030|60",
        "FDQ2|Player-1-BBBB|1642|37|DEATHKNIGHT|30|60", "FDQ2|Player-1-BBBB|1642|37|MONK|30|60",
        "FDQ2|Player-1-BBBB|1642|37|DEMONHUNTER|30|60", "FDQ2|Player-1-BBBB|1642|37|EVOKER|30|60",
        string.rep("x", 256), c.secret }
    for _, payload in ipairs(invalid) do c:receive(payload) end
    for _, sender in ipairs({ "", "Bad|Name", "Bad\nName", c.secret }) do c:receive(REQUEST, sender) end
    c:receive(REQUEST, nil, "CHANNEL")
    c:receive(REQUEST, nil, "PARTY")
    c:receive(REQUEST, nil, "RAID")
    c:receive(REQUEST, nil, "WHISPER", "ForeverDuel1")
    c:advance(12)
    equal(#c.FD.Presence:GetPlayers(), 0, "invalid or misrouted requests never populate cache")
    equal(#sent(c), 0, "invalid or misrouted requests never get replies")
    c:receive(PROFILE)
    equal(c.FD.Presence:GetPlayer("Player-1-BBBB").rating, 1642, "valid whispered profile is advisory evidence")
    c:advance(12)
    equal(#sent(c), 0, "profile-only whisper does not elicit a reply")
    c:receive(REQUEST)
    equal(#sent(c), 0, "valid request queues reply outside receive callback")
    c:advance(6)
    equal(#sent(c, "FDP2"), 1, "validated request is answered")
    local firstReply = sent(c, "FDP2")[1].at
    for _ = 1, 20 do c:receive(REQUEST) end
    c:advance(12)
    local replies = sent(c, "FDP2")
    for i = 2, #replies do equal(replies[i].at - replies[i - 1].at >= 5, true, "same-peer replies are paced") end
    equal(#replies <= 3, true, "duplicate requests cannot grow unbounded reply work")
    equal(firstReply <= c.now, true, "reply uses native timer clock")
    c:preserved("malformed and repeated requests")

    -- Global whisper pacing applies across different observed units.
    c = client()
    c.units.target, c.units.focus, c.units.party1 = peer(1), peer(2), peer(3)
    c.FD.Presence:Initialize()
    c:advance(20)
    equal(#sent(c, "FDQ2"), 3, "three visible peers are all queried")
    local packets = sent(c)
    for i = 2, #packets do equal(packets[i].at - packets[i - 1].at >= 1, true, "global whisper attempts are paced") end
    c:preserved("multi-peer queue")

    c = client()
    c.FD.Presence:Initialize()
    for index = 1, 350 do
        c:receive(string.format("FDQ2|Player-2-%X|1500|37|ROGUE|30|60", index), "Peer" .. index .. " Nearby")
    end
    equal(#c.FD.Presence.whispers, 300, "request flood cannot exceed bounded reply queue")
    equal(#sent(c), 0, "request flood does not send synchronously")
    equal(#c.FD.Presence:GetPlayers(), 300, "request flood keeps profile cache bounded")
    c:advance(10)
    equal(#sent(c) <= 10, true, "request flood respects global send pacing")
    c:advance(420)
    equal(#c.FD.Presence.whispers, 0, "old queued replies eventually expire")
    equal(#sent(c) < 300, true, "expired queued replies are discarded without sending")
    equal(#c.FD.Presence:GetPlayers(), 0, "request flood profiles expire normally")
    c:preserved("request flood")

    for _, failure in ipairs({ "throttled", "exception", "join exception" }) do
        c = client({ channel = "unusable" })
        c.units.target = peer()
        c.sendResult = failure == "throttled" and 3 or 0
        c.failSend, c.failJoin = failure == "exception", failure == "join exception"
        equal(c.FD.Presence:Initialize(), true, failure .. " keeps fallback initialized")
        c:advance(6)
        c.sendResult, c.failSend, c.failJoin = 0, false, false
        c:advance(50)
        local accepted = false
        for _, packet in ipairs(sent(c, "FDQ2")) do if packet.accepted then accepted = true end end
        equal(accepted, true, failure .. " recovers automatically")
        c:preserved(failure .. " recovery")
    end

    -- A world transition must discard queued recipients and ignore packets.
    c = client()
    c.FD.Presence:Initialize()
    c:receive(REQUEST)
    c:emit("PLAYER_LEAVING_WORLD")
    c:receive(REQUEST)
    c:advance(20)
    equal(#sent(c), 0, "world transition suppresses pending replies")
    equal(#c.FD.Presence:GetPlayers(), 0, "world transition clears advisory cache")
    c:emit("PLAYER_ENTERING_WORLD")
    c:advance(12)
    equal(#sent(c), 0, "old queued reply is not resurrected after world transition")
    c:receive(REQUEST)
    c:advance(6)
    equal(#sent(c, "FDP2"), 1, "new request works after world transition")
    c:emit("PLAYER_LOGOUT")
    local count = #sent(c)
    c:receive(REQUEST)
    c:advance(55)
    equal(#sent(c), count, "logout suppresses discovery messages")
    equal(#c.timers, 0, "logout eventually retires all timers")
    c:preserved("world transition")
end
