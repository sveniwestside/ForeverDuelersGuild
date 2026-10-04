return function(_, equal)
    -- Each client runs the real discovery/WoW adapters with private native APIs.
    local function client(options)
        options = options or {}
        local env = setmetatable({}, { __index = _G })
        env._G = env
        local state = { now = 100, mapID = 37, channelID = 0, timers = {}, frames = {}, sent = {},
            logs = {}, joins = {}, prefixes = {}, refreshes = 0, registerResult = 0, sendResult = 0 }
        state.secret = setmetatable({}, { __tostring = function() error("secret formatted") end,
            __index = function() error("secret indexed") end, __concat = function() error("secret joined") end })
        state.identity = { guid = options.guid or "Player-1-AAAA", name = options.name or "Alpha",
            surname = options.surname or "One", realm = "Forever", classFile = options.classFile or "MAGE", level = options.level or 30 }
        local FD = { Debug = {}, Zone = {}, duel = { active = { state = "READY", marker = "preserve" } } }
        function FD.Debug:Log(...) state.logs[#state.logs + 1] = { ... } end
        function FD.Zone:RefreshIfShown() state.refreshes = state.refreshes + 1 end
        function FD:Safe() error("Presence callbacks must not enter rated-duel recovery") end
        env.GetTime = function() return state.now end
        env.issecretvalue = function(value) return rawequal(value, state.secret) end
        env.InCombatLockdown = function() return false end
        env.C_Map = { GetBestMapForUnit = function()
            if state.failMap then error("map query failed") end
            return state.mapID
        end }
        env.UnitGUID = function(unit) return unit == "player" and state.identity.guid or nil end
        env.UnitFullName = function(unit)
            if unit == "player" then return state.identity.name, state.identity.realm end
        end
        env.UnitClass = function(unit)
            if unit == "player" then return state.identity.classFile, state.identity.classFile end
        end
        env.UnitLevel = function(unit) return unit == "player" and state.identity.level or nil end
        env.GetMaxPlayerLevel = function() return state.maxLevel or 60 end
        env.UnitIsPlayer = function(unit) return unit == "player" end
        env.GetNormalizedRealmName = function() return "Forever" end
        env.RegionalUniqueNamesEnabled = function() return options.regionalNames or false end
        env.UnitNameUnmodified = function(unit)
            if unit == "player" then return state.identity.name, state.identity.surname end
        end
        env.NameUtil = { GetUnmodifiedUnitFullName = function(unit)
            if unit == "player" then return state.identity.name .. " " .. state.identity.surname end
        end }
        env.Enum = {
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2, MaxPrefixes = 3 },
            SendAddonMessageResult = { Success = 0, InvalidPrefix = 2, AddonMessageThrottle = 3, InvalidChatType = 4 },
        }
        env.C_ChatInfo = {
            RegisterAddonMessagePrefix = function(prefix)
                state.prefixes[#state.prefixes + 1] = prefix
                if state.failRegister then error("registration failed") end
                return state.registerResult
            end,
            SendAddonMessage = function(prefix, payload, distribution, target)
                if state.failSend then error("send failed") end
                state.sent[#state.sent + 1] = { prefix = prefix, payload = payload,
                    distribution = distribution, target = target, at = state.now }
                return state.sendResult
            end,
        }
        env.GetChannelName = function(channel)
            if state.failChannel then error("channel query failed") end
            if channel == "ForeverDuel" or channel == state.channelID then
                return state.channelID, state.channelID ~= 0 and "ForeverDuel" or nil
            end
            return 0
        end
        env.JoinTemporaryChannel = function(name)
            if state.failJoin then error("channel join failed") end
            state.joins[#state.joins + 1] = { name = name, at = state.now }
            if not state.preventJoin then state.channelID = 7 end
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
        for _, module in ipairs({ "Constants", "Protocol", "Rating", "Database", "Wow", "Presence" }) do
            local chunk = assert(loadfile("ForeverDuel/" .. module .. ".lua"))
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
            local stop = self.now + seconds
            local steps = 0
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
                assert(steps < 1000, "discovery timer never spins without advancing time")
            end
            self.now = stop
        end
        function state:receive(payload, sender, overrides)
            overrides = overrides or {}
            self:emit("CHAT_MSG_ADDON", overrides.prefix or "ForeverDuelZone2", payload,
                overrides.distribution or "YELL", sender or "Beta-Forever", nil, 0,
                overrides.channelID or self.channelID)
        end
        function state:preserved(label)
            equal(self.FD.duel.active, self.active, label .. " preserves active duel")
            equal(self.active.state, "READY", label .. " preserves consent state")
            equal(self.FD.Database.data.player.ratings.LEVELING.rating, 1500, label .. " preserves rating")
            equal(#self.FD.Database.data.matches, 0, label .. " preserves match history")
        end
        return state
    end
    local function started(options)
        local c = client(options)
        c.FD.Presence:Initialize()
        c:advance(6)
        return c
    end
    local WIRE = "FDP2:Player-1-BBBB:1642:37:ROGUE:30:60"
    local c = started()
    local p = c.FD.Presence
    equal(c.prefixes[1], "ForeverDuelZone2", "discovery uses dedicated versioned addon prefix")
    equal(#c.joins, 0, "startup does not join a chat channel")
    equal(#c.sent, 1, "startup broadcasts one profile")
    equal(c.sent[1].prefix, "ForeverDuelZone2", "profile uses discovery prefix")
    equal(c.sent[1].distribution, "YELL", "profile automatically broadcasts in local area")
    equal(c.sent[1].target, nil, "area broadcast needs no channel or recipient")
    equal(c.sent[1].payload, "FDP2:Player-1-AAAA:1500:37:MAGE:30:60", "wire contains public profile fields with safe separators")
    equal(c.sent[1].payload:find("[^%w:%-]"), nil, "area wire contains no pipe escapes or non-ASCII characters")
    equal(p.lastPayload, c.sent[1].payload, "diagnostics retain last submitted area payload")
    equal(p.lastSend:find("YELL", 1, true) ~= nil, true, "send diagnostics identify area transport")
    equal(p.lastSend:find("submitted", 1, true) ~= nil, true, "send diagnostics record success enum")
    p:Initialize()
    equal(#c.prefixes, 1, "repeat initialization does not register duplicate prefix")
    equal(#c.frames, 1, "repeat initialization reuses event frame")
    equal(#c.timers, 1, "repeat initialization does not multiply polling timers")
    c:advance(9)
    equal(#c.sent, 1, "idle discovery does not broadcast every timer tick")
    c:advance(1)
    equal(#c.sent, 2, "heartbeat refreshes local presence after 15 seconds")
    equal(c.sent[2].at - c.sent[1].at, 15, "heartbeats are rate bounded")
    local sent = #c.sent
    c:receive(WIRE)
    equal(#p:GetPlayers(), 1, "valid area packet adds same-map peer without a target")
    equal(p:GetPlayer("Player-1-BBBB").fullName, "Beta-Forever", "native sender binds cached full name")
    equal(p:GetPlayer("Player-1-BBBB").rating, 1642, "received advisory rating retained")
    equal(p:GetPlayer("Player-1-BBBB").level, 30, "received level retained")
    equal(p:GetPlayer("Player-1-BBBB").maxLevel, 60, "received runtime cap retained")
    equal(p:GetPlayer("Player-1-BBBB").bracket, "LEVELING", "received mode is derived from validated levels")
    equal(#c.sent, sent, "receiving profile never echoes a response")
    c:preserved("profile reception")

    local invalid = {
        "", "FDP1:Player-1-BBBB:1642:37:ROGUE", "FDP2:Player-1-BBBB:1642:37",
        WIRE .. ":extra", WIRE .. ":", "FDP2:not-a-guid:1642:37:ROGUE:30:60",
        "FDP2:Player-1-BBBB:nan:37:ROGUE:30:60", "FDP2:Player-1-BBBB:1.2:37:ROGUE:30:60",
        "FDP2:Player-1-BBBB:100001:37:ROGUE:30:60", "FDP2:Player-1-BBBB:1642:0:ROGUE:30:60",
        "FDP2:Player-1-BBBB:1642:10000001:ROGUE:30:60", "FDP2:Player-1-BBBB:1642:37:UNKNOWN:30:60",
        "FDP2:Player-1-BBBB:1642:37:ROGUE:0:60", "FDP2:Player-1-BBBB:1642:37:ROGUE:61:60",
        "FDP2:Player-1-BBBB:1642:37:ROGUE:30:0", "FDP2:Player-1-BBBB:1642:37:ROGUE:30:256",
        "FDP2:Player-1-BBBB:1642:37:ROGUE:030:60", "FDP2:Player-1-BBBB:1642:37:ROGUE:30:60.0",
        "FDP2:Player-1-BBBB:1642:37:DEATHKNIGHT:30:60", "FDP2:Player-1-BBBB:1642:37:MONK:30:60",
        "FDP2:Player-1-BBBB:1642:37:DEMONHUNTER:30:60", "FDP2:Player-1-BBBB:1642:37:EVOKER:30:60",
        "FDP2|Player-1-BBBB|1642|37|ROGUE|30|60", "FDQ2:Player-1-BBBB:1642:37:ROGUE:30:60",
        "FDQ2|Player-1-BBBB|1642|37|ROGUE|30|60", " " .. WIRE, WIRE .. "\n",
        string.rep("x", 256), c.secret,
    }
    for _, distribution in ipairs({ "YELL", "SAY", "UNKNOWN" }) do
        for _, payload in ipairs(invalid) do
            local seen = p:GetPlayer("Player-1-BBBB").lastSeen
            c.now = c.now + 0.01
            c:receive(payload, nil, { distribution = distribution })
            equal(p:GetPlayer("Player-1-BBBB").lastSeen, seen, distribution .. " invalid packet cannot refresh cache age")
            equal(#p:GetPlayers(), 1, distribution .. " invalid packet cannot create extra peers")
        end
        c.now = c.now + 0.01
        c:receive(WIRE, nil, { distribution = distribution, channelID = 89 })
        equal(p:GetPlayer("Player-1-BBBB").lastSeen, c.now, distribution .. " accepts exact public profile without channel membership")
    end
    equal(#c.sent, sent, "malformed area requests and broadcast profiles never elicit replies")
    equal(#p.whispers, 0, "area traffic never queues whispered replies")
    for _, fields in ipairs({ { prefix = "ForeverDuel1" }, { distribution = "RAID" },
        { distribution = "PARTY" }, { distribution = "CHANNEL", channelID = 8 },
        { distribution = "CHANNEL", channelID = c.secret }, { distribution = "GUILD" },
        { distribution = "INSTANCE_CHAT" }, { distribution = "BATTLEGROUND" },
        { distribution = "WHISPER" },
        { prefix = c.secret }, { distribution = c.secret } }) do
        local before = p:GetPlayer("Player-1-BBBB").lastSeen
        c.now = c.now + 0.01
        c:receive(WIRE, "Beta-Forever", fields)
        equal(p:GetPlayer("Player-1-BBBB").lastSeen, before, "wrong transport route cannot refresh a profile")
    end
    for _, sender in ipairs({ c.secret, "", "Bad|Name", "Bad\nName" }) do
        local before = p:GetPlayer("Player-1-BBBB").lastSeen
        c.now = c.now + 0.01
        c:receive(WIRE, sender)
        equal(p:GetPlayer("Player-1-BBBB").lastSeen, before, "invalid sender cannot refresh a profile")
    end
    c:receive("FDP2:Player-1-AAAA:9000:37:ROGUE:30:60", "Spoof-Forever")
    equal(p:GetPlayer("Player-1-AAAA"), nil, "own GUID never becomes a discovered peer")
    c:receive("FDP2:Player-1-CCCC:1550:37:MAGE:30:60", "Gamma")
    equal(p:GetPlayer("Player-1-CCCC").fullName, "Gamma-Forever", "regular bare sender gets local realm")
    c:receive("FDP2:Player-1-DDDD:1550:38:MAGE:30:60", "Delta-OtherRealm")
    equal(p:GetPlayer("Player-1-DDDD").fullName, "Delta-OtherRealm", "qualified sender preserves remote realm")
    equal(#p:GetPlayers(), 2, "other-map profile is cached but omitted from zone list")
    c.mapID = 38
    equal(#p:GetPlayers(), 1, "zone list follows current map immediately")

    -- Both clients have no target, focus, group or nameplates. Their native
    -- local broadcasts may be reported with any supported area event label.
    local a = started({ regionalNames = true })
    local b = started({ regionalNames = true, guid = "Player-1-BBBB", name = "Beta", surname = "Two", classFile = "ROGUE" })
    local deliveredA, deliveredB = 0, 0
    local distributions = { "UNKNOWN", "SAY", "YELL" }
    local function exchange()
        while deliveredA < #a.sent do
            deliveredA = deliveredA + 1
            equal(a.sent[deliveredA].distribution, "YELL", "first client sends only area broadcasts without native peers")
            b:receive(a.sent[deliveredA].payload, "Alpha One", {
                distribution = distributions[(deliveredA - 1) % #distributions + 1], channelID = 17 })
        end
        while deliveredB < #b.sent do
            deliveredB = deliveredB + 1
            equal(b.sent[deliveredB].distribution, "YELL", "second client sends only area broadcasts without native peers")
            a:receive(b.sent[deliveredB].payload, "Beta Two", {
                distribution = distributions[(deliveredB - 1) % #distributions + 1], channelID = 4 })
        end
    end
    exchange()
    equal(a.FD.Presence:GetPlayers()[1].fullName, "Beta Two", "surname transport preserves exact full name")
    equal(b.FD.Presence:GetPlayers()[1].fullName, "Alpha One", "both clients discover each other")
    equal(#a.sent, 1, "first peer reception does not amplify area traffic")
    equal(#b.sent, 1, "second peer reception does not amplify area traffic")
    a:advance(90)
    b:advance(90)
    exchange()
    equal(#a.FD.Presence:GetPlayers(), 1, "heartbeat keeps peer fresh beyond first interval")
    equal(#b.FD.Presence:GetPlayers(), 1, "heartbeat preserves reciprocal discovery")
    local lastSeen = a.FD.Presence:GetPlayer("Player-1-BBBB").lastSeen
    a:advance(120)
    equal(a.FD.Presence:GetPlayer("Player-1-BBBB"), nil, "silent peer expires without goodbye message")
    equal(a.now - lastSeen >= 120, true, "expiry uses last valid profile receive time")
    equal(#a.FD.Presence:GetPlayers(), 0, "silent peer disappears from zone UI")
    a:preserved("discovery heartbeat and expiry")

    c = started()
    p = c.FD.Presence
    c.FD.Database.data.player.ratings.MAX_LEVEL.rating = 1812
    c.identity.level = 60
    c:advance(5)
    equal(c.sent[#c.sent].payload, "FDP2:Player-1-AAAA:1812:37:MAGE:60:60", "level-cap transition announces separate max-level pool")
    c:receive("FDP2:Player-1-BBBB:1777:37:ROGUE:60:60")
    equal(p:GetPlayer("Player-1-BBBB").bracket, "MAX_LEVEL", "max-level peer packet derives correct mode")
    c.identity.level = nil
    sent = #c.sent
    c:advance(50)
    equal(#c.sent, sent, "unavailable native level suppresses discovery broadcast")

    c = started()
    p = c.FD.Presence
    c:receive(WIRE, "Beta-Forever")
    c:receive("FDP2:Player-1-BBBB:9000:37:MAGE:30:60", "Imposter-Forever")
    equal(p:GetPlayer("Player-1-BBBB").fullName, "Beta-Forever", "fresh GUID cannot change transport sender")
    equal(p:GetPlayer("Player-1-BBBB").rating, 1642, "conflicting sender cannot replace cached rating")
    c:receive("FDP2:Player-1-CCCC:1550:37:MAGE:30:60", "Beta-Forever")
    equal(p:GetPlayer("Player-1-BBBB"), nil, "sender GUID change removes obsolete identity")
    equal(p:GetPlayer("Player-1-CCCC").rating, 1550, "sender GUID change installs latest identity")
    c:receive("FDP2:Player-1-DDDD:9000:37:MAGE:30:60", "Alpha-Forever")
    equal(p:GetPlayer("Player-1-DDDD"), nil, "own sender name cannot add a foreign GUID")
    for index = 1, 302 do
        c.now = c.now + 0.01
        c:receive(string.format("FDP2:Player-2-%X:1500:37:MAGE:30:60", index), "Peer" .. index .. "-Forever")
    end
    equal(#p:GetPlayers(), 300, "advisory cache remains bounded under area traffic")
    equal(p:GetPlayer("Player-2-1"), nil, "oldest profile is evicted when capacity is exhausted")
    equal(p:GetPlayer("Player-2-2"), nil, "capacity evicts enough old profiles")
    equal(p:GetPlayer("Player-2-12E").fullName, "Peer302-Forever", "newest peer survives capacity eviction")
    c:advance(125)
    local entries = 0
    for _ in pairs(p.players) do entries = entries + 1 end
    equal(entries, 0, "timer removes stale cache entries even without incoming packets")

    c = started()
    p = c.FD.Presence
    c:receive(WIRE)
    sent = #c.sent
    c:emit("PLAYER_LEAVING_WORLD")
    equal(p.suspended, true, "leaving world suspends discovery")
    equal(#p:GetPlayers(), 0, "leaving world clears discovered peers")
    c:receive(WIRE)
    equal(p:GetPlayer("Player-1-BBBB"), nil, "profiles received during transition are ignored")
    c:advance(50)
    equal(#c.sent, sent, "transition suppresses outgoing heartbeat")
    c:emit("PLAYER_ENTERING_WORLD")
    equal(p.suspended, false, "entering world resumes discovery")
    equal(#c.sent, sent + 1, "returning world announces fresh own profile")
    c:receive(WIRE)
    equal(#p:GetPlayers(), 1, "discovery accepts peers after world transition")
    c.FD.Database.data.player.ratings.LEVELING.rating = 1516
    for _ = 1, 20 do p:Changed() end
    equal(#c.sent, sent + 1, "same-instant renders do not bypass send pacing")
    c:advance(5)
    equal(#c.sent, sent + 2, "changed rating is announced after minimum interval")
    equal(c.sent[#c.sent].payload, "FDP2:Player-1-AAAA:1516:37:MAGE:30:60", "announcement uses current local rating")
    sent = #c.sent
    for _ = 1, 20 do p:Changed() end
    c:advance(5)
    equal(#c.sent, sent, "unchanged render does not create repeated announcements")
    c.mapID = 38
    c:emit("ZONE_CHANGED_NEW_AREA")
    equal(#c.sent, sent + 1, "zone event announces changed map once pacing permits")
    equal(c.sent[#c.sent].payload, "FDP2:Player-1-AAAA:1516:38:MAGE:30:60", "announcement contains new map")
    c:emit("ZONE_CHANGED")
    c:emit("ZONE_CHANGED_INDOORS")
    equal(#c.sent, sent + 1, "duplicate zone events do not flood area transport")
    c.channelID = 9
    c:advance(5)
    equal(#c.sent, sent + 1, "channel renumbering does not trigger extra broadcasts")
    equal(c.sent[#c.sent].target, nil, "area announcements remain independent of channel numbers")
    equal(#c.joins, 0, "zone events do not join custom chat channels")
    sent = #c.sent
    c:emit("PLAYER_LOGOUT")
    c:advance(60)
    equal(#c.sent, sent, "logout stops outgoing discovery")
    equal(#c.timers, 0, "logout stops rescheduling discovery timer")
    equal(#p:GetPlayers(), 0, "logout clears peer cache")

    -- Legacy channel profiles may still be received from an already joined
    -- channel, but channel membership is never required or created.
    c = started()
    p = c.FD.Presence
    local legacy = "FDP2|Player-1-BBBB|1642|37|ROGUE|30|60"
    c:receive(legacy, nil, { distribution = "CHANNEL", channelID = 7 })
    equal(#p:GetPlayers(), 0, "unjoined legacy channel cannot populate cache")
    c.channelID = 7
    c:receive(legacy, nil, { distribution = "CHANNEL", channelID = 7 })
    equal(p:GetPlayer("Player-1-BBBB").rating, 1642, "legacy profile can arrive on an already joined channel")
    local seen = p:GetPlayer("Player-1-BBBB").lastSeen
    c.now = c.now + 1
    c.channelID = 9
    c:receive(legacy, nil, { distribution = "CHANNEL", channelID = 7 })
    equal(p:GetPlayer("Player-1-BBBB").lastSeen, seen, "old legacy channel ID cannot refresh peer")
    c:receive(legacy, nil, { distribution = "CHANNEL", channelID = c.secret })
    equal(p:GetPlayer("Player-1-BBBB").lastSeen, seen, "restricted legacy channel ID cannot refresh peer")
    c:receive(legacy, nil, { distribution = "CHANNEL", channelID = 9 })
    equal(p:GetPlayer("Player-1-BBBB").lastSeen, c.now, "legacy receive follows current native channel ID")
    c:emit("CHAT_MSG_CHANNEL_NOTICE", "YOU_LEFT", 0, "ForeverDuel")
    c:advance(30)
    equal(#c.joins, 0, "legacy channel notices never cause automatic joins")
    for _, packet in ipairs(c.sent) do
        equal(packet.distribution, "YELL", "legacy compatibility never reintroduces channel sends")
    end

    for _, code in ipairs({ 2, 3 }) do
        c = client()
        c.registerResult = code
        equal(c.FD.Presence:Initialize(), false, "registration failure enum disables discovery")
        c:advance(10)
        equal(#c.sent, 0, "registration failure sends nothing")
        equal(#c.joins, 0, "registration failure does not join channel")
        c:preserved("failed registration")
    end
    c = client()
    c.registerResult = 1
    equal(c.FD.Presence:Initialize(), true, "already-registered prefix is usable")
    c:advance(6)
    equal(#c.sent, 1, "duplicate-prefix success still broadcasts")
    c = client()
    c.env.GetChannelName, c.env.JoinTemporaryChannel = nil, nil
    equal(c.FD.Presence:Initialize(), true, "missing channel APIs still enable automatic area discovery")
    c:advance(6)
    equal(#c.sent, 1, "area broadcast needs neither chat channel nor native nearby units")
    equal(c.sent[1].distribution, "YELL", "missing channel APIs use local area transport")
    equal(#c.timers, 1, "area discovery keeps polling without a channel")
    c:preserved("unsupported channel API")
    c = client()
    c.failJoin, c.failChannel = true, true
    c.FD.Presence:Initialize()
    c:advance(21)
    equal(#c.sent, 2, "broken channel APIs cannot interrupt area heartbeats")
    equal(#c.joins, 0, "automatic discovery never calls the broken channel join API")
    equal(#c.logs > 0, true, "successful area sends retain discovery diagnostics")
    c:preserved("broken unrelated channel APIs")
    c = client()
    c.sendResult = 3
    c.FD.Presence:Initialize()
    c:advance(6)
    equal(c.FD.Presence.lastSend:find("rejected", 1, true) ~= nil, true, "truthy throttle enum is treated as rejection")
    equal(c.FD.Presence.lastSend:find("YELL", 1, true) ~= nil, true, "rejected send identifies area transport")
    equal(c.FD.Presence.lastPayload, nil, "rejected broadcast is not recorded as submitted payload")
    equal(c.sent[2].at - c.sent[1].at, 5, "rejected area send retries at the five-second minimum")
    sent = #c.sent
    c.sendResult = 0
    c:advance(5)
    equal(#c.sent, sent + 1, "throttled send retries automatically")
    equal(c.FD.Presence.lastSend:find("submitted", 1, true) ~= nil, true, "recovered send restores status")
    c:preserved("throttle recovery")

    c = client()
    p = c.FD.Presence
    c.sendResult = 4
    p:Initialize()
    c:advance(6)
    equal(#c.sent, 1, "unsupported area transport is attempted only once")
    equal(c.sent[1].distribution, "YELL", "unsupported route is detected from an actual area send")
    equal(p.areaUnsupported, true, "InvalidChatType permanently disables area sending for this session")
    equal(p.available, true, "unsupported area transport preserves addon discovery registration")
    equal(p.lastPayload, nil, "unsupported area broadcast is never recorded as submitted")
    c.sendResult = 0
    c:advance(60)
    equal(#c.sent, 1, "timer ticks do not retry the unsupported area route")
    c.mapID = 38
    for _ = 1, 20 do p:Changed() end
    c:advance(5)
    equal(#c.sent, 1, "changed profile does not retry the unsupported area route")
    c.mapID = 37
    c:emit("ZONE_CHANGED_NEW_AREA")
    c:emit("ZONE_CHANGED")
    c:emit("ZONE_CHANGED_INDOORS")
    equal(#c.sent, 1, "zone events do not retry the unsupported area route")
    c:emit("PLAYER_LEAVING_WORLD")
    c:advance(10)
    c:emit("PLAYER_ENTERING_WORLD")
    c:advance(60)
    equal(p.areaUnsupported, true, "world transition preserves unsupported-route detection")
    equal(#c.sent, 1, "world transition does not retry the unsupported area route")
    c:receive("FDQ2|Player-1-BBBB|1642|37|ROGUE|30|60", "Beta-Forever", { distribution = "WHISPER" })
    equal(p:GetPlayer("Player-1-BBBB").rating, 1642, "unsupported area route still accepts whispered discovery")
    c:advance(1)
    equal(#c.sent, 2, "whisper request still receives one profile response")
    equal(c.sent[2].distribution, "WHISPER", "fallback response uses working whisper transport")
    equal(c.sent[2].target, "Beta-Forever", "fallback response addresses the requesting peer")
    equal(c.sent[2].payload, "FDP2|Player-1-AAAA|1500|37|MAGE|30|60", "fallback response retains native whisper profile")
    p:QueueWhisper("Gamma-Forever", true)
    c:advance(1)
    equal(#c.sent, 3, "unsupported area route still permits direct discovery queries")
    equal(c.sent[3].distribution, "WHISPER", "direct discovery remains on whisper transport")
    equal(c.sent[3].payload, "FDQ2|Player-1-AAAA|1500|37|MAGE|30|60", "direct discovery query remains valid")
    c:preserved("unsupported area transport and whisper fallback")

    c = started()
    local firstPayload, firstSentAt = c.sent[1].payload, c.sent[1].at
    c.failSend = true
    c:advance(firstSentAt + 15 - c.now)
    equal(#c.sent, 1, "native exception interrupts an otherwise unchanged heartbeat")
    equal(#c.logs > 0, true, "failed heartbeat is caught locally")
    c.failSend = false
    c:advance(5)
    equal(#c.sent, 2, "failed unchanged heartbeat retries after five seconds")
    equal(c.sent[2].payload, firstPayload, "heartbeat retry does not require changed profile data")
    equal(c.sent[2].at - firstSentAt, 20, "retry does not wait a second full heartbeat interval")
    c:preserved("unchanged heartbeat exception recovery")

    for _, failure in ipairs({ "failMap", "failSend" }) do
        c = client()
        c[failure] = true
        c.FD.Presence:Initialize()
        c:advance(6)
        equal(#c.timers, 1, failure .. " does not stop future polling")
        equal(#c.logs > 0, true, failure .. " is logged locally")
        c:preserved(failure)
        c[failure] = false
        c:advance(50)
        equal(#c.sent > 0, true, failure .. " can recover on a later tick")
    end
    c = started()
    c.failMap = true
    c.FD.Debug.Log = function() error("logger failed") end
    equal(pcall(function() c:advance(10) end), true, "failed logger cannot escape discovery timer recovery")
    equal(#c.timers, 1, "failed logger preserves retry timer")
    c:preserved("failed discovery logger")
end
