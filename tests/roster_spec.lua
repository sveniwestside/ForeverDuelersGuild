return function(_, equal)
    -- Model the observed Forever APIs: channel 6 is display row 9, and its
    -- members become readable only after selecting that row asynchronously.
    local function client(options)
        options = options or {}
        local env = setmetatable({}, { __index = _G })
        env._G = env
        local state = { now = 100, mapID = 1420, channelID = options.channelID or 6,
            displayIndex = options.displayIndex or 9, selected = 1, joined = not options.unjoined,
            timers = {}, frames = {}, selections = {}, reads = {}, joins = {}, sent = {}, logs = {},
            members = {}, loaded = false, shown = false }
        state.secret = setmetatable({}, { __tostring = function() error("secret formatted") end,
            __index = function() error("secret indexed") end, __eq = function() error("secret compared") end,
            __lt = function() error("secret ordered") end, __concat = function() error("secret joined") end })
        state.identity = { guid = options.guid or "Player-1-AAAA", name = options.name or "Alpha",
            surname = options.surname or "One", classFile = "MAGE", realm = "Forever", level = 30 }
        local FD = { Debug = {}, Zone = {}, duel = { active = { state = "READY", marker = "preserve" } } }
        function FD.Debug:Log(...) state.logs[#state.logs + 1] = { ... } end
        function FD.Zone:RefreshIfShown() end
        function FD:Safe() error("Roster discovery must not enter rated-duel recovery") end
        function FD.duel:Begin() error("Roster discovery must not begin a duel") end
        function FD.duel:Abort() error("Roster discovery must not abort a duel") end
        env.GetTime = function() return state.now end
        env.issecretvalue = function(value) return rawequal(value, state.secret) end
        env.InCombatLockdown = function() return false end
        env.C_Map = { GetBestMapForUnit = function() return state.mapID end }
        env.UnitGUID = function(unit) return unit == "player" and state.identity.guid or nil end
        env.UnitFullName = function(unit)
            if unit == "player" then return state.identity.name, state.identity.realm end
        end
        env.UnitClass = function(unit)
            if unit == "player" then return state.identity.classFile, state.identity.classFile end
        end
        env.UnitLevel = function(unit) return unit == "player" and state.identity.level or nil end
        env.UnitIsPlayer = function(unit) return unit == "player" end
        env.GetMaxPlayerLevel = function() return 60 end
        env.GetNormalizedRealmName = function() return "Forever" end
        env.RegionalUniqueNamesEnabled = function() return options.regionalNames ~= false end
        env.UnitNameUnmodified = function(unit)
            if unit == "player" then return state.identity.name, state.identity.surname end
        end
        env.NameUtil = { GetUnmodifiedUnitFullName = function(unit)
            if unit == "player" then return state.identity.name .. " " .. state.identity.surname end
        end }
        env.Enum = { RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
            SendAddonMessageResult = { Success = 0, InvalidChatType = 4 } }
        env.C_ChatInfo = {
            RegisterAddonMessagePrefix = function() return 0 end,
            SendAddonMessage = function(prefix, payload, distribution, target)
                state.sent[#state.sent + 1] = { prefix = prefix, payload = payload,
                    distribution = distribution, target = target, at = state.now }
                if distribution == "YELL" then return 4 end
                return 0
            end,
            GetChannelRosterInfo = function(displayIndex, memberIndex)
                state.reads[#state.reads + 1] = { displayIndex = displayIndex, memberIndex = memberIndex }
                if state.failRoster then error("roster temporarily unavailable") end
                -- A local chat-channel ID must never be used as a display row.
                if displayIndex ~= state.displayIndex or not state.joined or not state.loaded then return nil end
                local member = state.members[memberIndex]
                if member then return member.name, false, false, member.guid end
            end,
        }
        env.GetChannelName = function(name)
            if name == "ForeverDuel" and state.joined then return state.channelID, "ForeverDuel" end
            return 0
        end
        env.JoinTemporaryChannel = function(name)
            state.joins[#state.joins + 1] = { name = name, at = state.now }
            if not state.preventJoin then state.joined = true end
        end
        env.GetNumDisplayChannels = function() return state.displayIndex + 1 end
        env.GetChannelDisplayInfo = function(index)
            if state.failDisplay then error("display temporarily unavailable") end
            if state.invalidPrevious and index == 1 then return nil end
            if index == state.displayIndex and state.joined then
                return state.displayName or "ForeverDuel", false, false, state.channelID,
                    state.zeroDisplayCount and 0 or
                        (state.loaded and not state.countOnlyInEvent and #state.members or nil), true
            end
            -- Other public channels have readable members; never query them.
            return "General " .. index, false, false, index, 20, true
        end
        env.GetSelectedDisplayChannel = function()
            if state.failSelected then error("selection temporarily unavailable") end
            return state.selected
        end
        env.SetSelectedDisplayChannel = function(index)
            state.selections[#state.selections + 1] = { index = index, at = state.now }
            if state.failSelect then error("selection temporarily unavailable") end
            state.selected = index
            if index == state.displayIndex then
                env.C_Timer.After(2, function()
                    if state.neverLoads then return end
                    state.loaded = true
                    state:emit("CHANNEL_ROSTER_UPDATE", index, #state.members)
                end)
            end
        end
        env.ChannelFrame = { IsShown = function() return state.shown end }
        env.SendChatMessage = function() error("Discovery must never send ordinary public chat") end
        env.LibStub = function() error("Roster discovery must not require a library") end
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
        for _, module in ipairs({ "Constants", "Protocol", "Rating", "Database", "Wow", "Roster", "Presence" }) do
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
                assert(steps < 1000, "roster timers cannot spin without advancing time")
            end
            self.now = stop
        end
        function state:whispers()
            local result = {}
            for _, packet in ipairs(self.sent) do
                if packet.distribution == "WHISPER" then result[#result + 1] = packet end
            end
            return result
        end
        function state:preserved(label)
            equal(self.FD.duel.active, self.active, label .. " preserves active duel")
            equal(self.active.state, "READY", label .. " preserves consent state")
            equal(self.FD.Database.data.player.ratings.LEVELING.rating, 1500, label .. " preserves rating")
            equal(#self.FD.Database.data.matches, 0, label .. " preserves match history")
        end
        function state:start()
            equal(self.FD.Presence:Initialize(), true, "native discovery initializes")
            return self
        end
        return state
    end
    local function peer(name, guid) return { name = name or "Beta Two", guid = guid or "Player-1-BBBB" } end
    local function one(options)
        local c = client(options)
        c.members = { peer() }
        return c
    end

    local c = one():start()
    c:advance(1)
    equal(c.selected, 9, "unloaded roster requests display row nine rather than local channel six")
    equal(#c:whispers(), 0, "selection alone does not invent peer names")
    equal(#c.FD.Presence:GetPlayers(), 0, "roster membership alone is not addon presence")
    c:advance(5)
    equal(c.selected, 1, "asynchronously loaded roster restores previous selection")
    equal(#c:whispers(), 1, "native roster bootstraps one whisper without an observed unit")
    equal(c:whispers()[1].target, "Beta Two", "regional surname is used as the exact native whisper recipient")
    equal(c:whispers()[1].payload, "FDQ2|Player-1-AAAA|1500|1420|MAGE|30|60", "roster discovery reuses versioned advisory query")
    equal(c:whispers()[1].prefix, "ForeverDuelZone2", "roster discovery stays on dedicated presence prefix")
    equal(#c.FD.Presence:GetPlayers(), 0, "unanswered roster query never creates a profile")
    for _, read in ipairs(c.reads) do
        equal(read.displayIndex, 9, "only the addon-owned display roster is read")
    end
    c:preserved("roster bootstrap")

    c = one()
    c.countOnlyInEvent = true
    c:start():advance(10)
    equal(#c:whispers(), 1, "native roster-update member count works when display count stays nil")
    equal(c.selected, 1, "event-count roster completes selection restoration")

    c = one()
    c.zeroDisplayCount = true
    c:start():advance(10)
    equal(#c:whispers(), 1, "native roster event count overrides stale zero display count")
    equal(c.selected, 1, "stale display count does not prevent selection restoration")

    -- Two independent clients have neither targets, focus, groups nor plates.
    -- Each uses different local IDs and display rows for the same named channel.
    local a = one():start()
    local b = client({ name = "Beta", surname = "Two", guid = "Player-1-BBBB", channelID = 3, displayIndex = 7 })
    b.members = { peer("Alpha One", "Player-1-AAAA") }
    b:start()
    local deliveredA, deliveredB = 0, 0
    local function deliver(source, destination, after, sender)
        while after < #source.sent do
            after = after + 1
            local packet = source.sent[after]
            if packet.distribution == "WHISPER" then
                destination:emit("CHAT_MSG_ADDON", packet.prefix, packet.payload, "WHISPER", sender)
            end
        end
        return after
    end
    for _ = 1, 10 do
        a:advance(1); b:advance(1)
        deliveredA = deliver(a, b, deliveredA, "Alpha One")
        deliveredB = deliver(b, a, deliveredB, "Beta Two")
    end
    equal(#a.FD.Presence:GetPlayers(), 1, "first untargeted client discovers responding addon peer")
    equal(#b.FD.Presence:GetPlayers(), 1, "second untargeted client discovers responding addon peer")
    equal(a.FD.Presence:GetPlayers()[1].fullName, "Beta Two", "first profile has native transport name")
    equal(b.FD.Presence:GetPlayers()[1].fullName, "Alpha One", "second profile has native transport name")
    equal(a.selected, 1, "first client restores independent selection")
    equal(b.selected, 1, "second client restores independent selection")
    a:preserved("first client automatic handshake")
    b:preserved("second client automatic handshake")

    c = one():start()
    c:advance(160)
    local previous, queries = nil, 0
    for _, packet in ipairs(c:whispers()) do
        if packet.payload:sub(1, 5) == "FDQ2|" then
            if previous then equal(packet.at - previous >= 45, true, "same peer is queried at most once every 45 seconds") end
            previous, queries = packet.at, queries + 1
        end
    end
    equal(queries >= 3, true, "automatic refresh retries unanswered peers without a target")
    c = client()
    c.members = { peer("Beta Two", "Player-1-BBBB"), peer("Gamma Three", "Player-1-CCCC"), peer("Delta Four", "Player-1-DDDD") }
    c:start():advance(10)
    equal(#c:whispers(), 3, "all valid native roster peers are queued")
    for i = 2, #c:whispers() do
        equal(c:whispers()[i].at - c:whispers()[i - 1].at >= 1, true, "roster queries use existing one-per-second queue")
    end

    c = client()
    c.members = { peer("Alpha One", "Player-1-AAAA"), peer(), peer(),
        peer("Unknown", "Creature-1-CCCC"), peer("Malformed", "Player-1-XYZ"),
        { name = "Missing GUID" }, peer("", "Player-1-CCCC"), peer("Bad|Name", "Player-1-DDDD"),
        peer("Bad\nName", "Player-1-EEEE"), peer(string.rep("x", 129), "Player-1-FFFF"),
        peer(c.secret, "Player-1-ABCD"), peer("Restricted GUID", c.secret) }
    c:start():advance(15)
    equal(#c:whispers(), 1, "self, duplicates and malformed or restricted native rows never create queries")
    equal(c:whispers()[1].target, "Beta Two", "valid row survives malformed neighbors")
    c:preserved("malformed native roster")

    c = one()
    c.shown = true
    c:start():advance(10)
    equal(#c.selections, 0, "visible channel UI is not commandeered for discovery")
    equal(#c:whispers(), 0, "unloaded roster waits while user is viewing channels")
    c.shown = false
    c:advance(35)
    equal(#c:whispers() > 0, true, "discovery resumes when channel UI closes")

    c = one():start()
    c:advance(1)
    c.selected, c.shown = 4, true
    c:advance(7)
    equal(c.selected, 4, "user selection during async request is never overwritten")
    equal(#c.selections, 1, "user interference prevents selection restoration")

    c = one():start()
    c:advance(1)
    c:emit("PLAYER_LEAVING_WORLD")
    c:advance(8)
    equal(#c:whispers(), 0, "late native roster response cannot whisper during world transition")
    equal(#c.FD.Presence:GetPlayers(), 0, "world transition retains no stale profiles")
    c.selected = 4
    c:advance(30)
    equal(c.selected, 4, "stale request callback never restores selection after leaving world")
    c:emit("PLAYER_ENTERING_WORLD")
    c:advance(10)
    equal(#c:whispers() > 0, true, "new world begins a fresh roster discovery")

    c = one():start()
    c:advance(10)
    local before = #c:whispers()
    c.channelID, c.displayIndex, c.loaded = 3, 7, false
    c:emit("CHANNEL_UI_UPDATE")
    c:advance(65)
    equal(#c:whispers() > before, true, "channel renumbering is resolved by name on refresh")
    local found = false
    for _, selection in ipairs(c.selections) do if selection.index == 7 then found = true end end
    equal(found, true, "renumbered channel uses its new display index")
    equal(c.selected, 1, "renumbered channel restores previous user selection")

    c = client():start()
    c:advance(8)
    c:emit("CHAT_MSG_CHANNEL_JOIN", "", "Beta Two", "", "", "", "", "", 2, "General", "", "", "Player-1-BBBB")
    c:advance(2)
    equal(#c:whispers(), 0, "joins in ordinary channels never bootstrap addon queries")
    c:emit("CHAT_MSG_CHANNEL_JOIN", "", "Beta Two", "", "", "", "", "", 6, "ForeverDuel", "", "", "Player-1-BBBB")
    c:advance(2)
    equal(#c:whispers(), 1, "new member in the dedicated addon channel is queried promptly")
    equal(c:whispers()[1].target, "Beta Two", "channel join uses validated native full name")

    c = one()
    c.displayName = "General"
    c:start():advance(15)
    equal(#c.selections, 0, "matching local ID does not authorize selecting a differently named channel")
    equal(#c:whispers(), 0, "public channels are never used as discovery rosters")

    c = one({ unjoined = true })
    c.preventJoin = true
    c:start():advance(65)
    equal(#c.joins >= 2, true, "failed initial channel join is retried")
    for i, join in ipairs(c.joins) do
        equal(join.name, "ForeverDuel", "only dedicated addon channel is joined")
        if i > 1 then equal(join.at - c.joins[i - 1].at >= 30, true, "channel joins are rate bounded") end
    end
    c.preventJoin = false
    c:advance(40)
    equal(#c:whispers() > 0, true, "roster discovery recovers after channel join becomes available")

    c = one()
    c.neverLoads = true
    c:start():advance(8)
    equal(c.selected, 1, "roster load timeout restores previous channel selection")
    equal(#c:whispers(), 0, "unloaded timeout never invents peer names")
    local requests = #c.selections
    c:advance(15)
    equal(#c.selections, requests, "timed-out roster is not reselected on every five-second pulse")
    c.neverLoads = false
    c:advance(45)
    equal(#c:whispers() > 0, true, "later roster refresh recovers after a timeout")

    for _, api in ipairs({ "GetSelectedDisplayChannel", "SetSelectedDisplayChannel", "GetNumDisplayChannels", "GetChannelDisplayInfo" }) do
        c = one()
        c.env[api] = nil
        c:start():advance(15)
        equal(#c.selections, 0, api .. " missing cannot mutate channel selection")
        equal(#c:whispers(), 0, api .. " missing cannot query an unknown roster")
        c:preserved(api .. " unavailable")
    end
    c = one()
    c.env.C_ChatInfo.GetChannelRosterInfo = nil
    c:start():advance(15)
    equal(#c.selections, 0, "missing native roster API does not change selection")
    equal(#c:whispers(), 0, "missing native roster API is tolerated")
    c = one()
    c.invalidPrevious = true
    c:start():advance(10)
    equal(#c.selections, 0, "missing previous row metadata prevents an unrestorable selection change")
    equal(#c:whispers(), 0, "missing previous metadata cannot bootstrap an unknown roster")
    c = one()
    c.env.GetSelectedDisplayChannel = nil
    c.env.ChannelFrame.GetList = function()
        return { GetSelectedChannelIDAndSupportsText = function() return c.selected, true end }
    end
    c:start():advance(10)
    equal(#c:whispers(), 1, "native channel list supplies a restorable selection when the legacy getter is absent")
    equal(c.selected, 1, "native channel-list selection fallback restores the old row")
    for _, selection in ipairs({ false, "1", -1, 0.5 }) do
        c = one()
        c.selected = selection
        c:start():advance(10)
        equal(#c.selections, 0, "unrestorable selection prevents a background request")
    end
    c = one()
    c.selected = c.secret
    c:start():advance(10)
    equal(#c.selections, 0, "restricted selection is neither compared nor changed")
    for _, failure in ipairs({ "failSelected", "failDisplay", "failRoster", "failSelect" }) do
        c = one()
        c[failure] = true
        c:start():advance(10)
        equal(#c:whispers(), 0, failure .. " cannot issue a bogus discovery query")
        c:preserved(failure)
    end

    c = one():start()
    c:advance(1)
    c.failRoster = true
    c:advance(7)
    equal(c.FD.Roster.pending, nil, "throwing roster reads still release pending request at deadline")
    equal(c.selected, 1, "throwing roster reads restore former selection within bounded wait")
    equal(#c:whispers(), 0, "failed async reads never query guessed peers")
    c.failRoster = false
    c:advance(40)
    equal(#c:whispers() > 0, true, "roster read recovers after native failure clears")
    c:preserved("asynchronous roster failure")
end
