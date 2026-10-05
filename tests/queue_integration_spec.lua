return function(_, equal)
    -- The actual TOC, Core, native adapters and both lifecycle engines are
    -- loaded. Only presentation/automatic discovery are replaced: this is a
    -- deterministic integration harness, not a claim about a live WoW client.
    local function client(beta, options)
        options = options or {}
        local state = { now = 10, timers = {}, frames = {}, sent = {}, prints = {}, accepts = 0,
            declines = 0, invites = 0, leaves = 0, grouped = false, mapX = 0.50049999999,
            mapY = 0.31415926535, loaded = {} }
        local env = setmetatable({}, { __index = _G })
        env._G, env.SlashCmdList = env, {}
        local FD = {}
        local own = { guid = beta and "Player-1-00000002" or "Player-1-00000001",
            name = beta and "Beta" or "Alpha", realm = "Forever", classFile = beta and "ROGUE" or "MAGE" }
        local peer = { guid = beta and "Player-1-00000001" or "Player-1-00000002",
            name = beta and "Alpha" or "Beta", realm = "Forever", classFile = beta and "MAGE" or "ROGUE" }
        local methods = {}
        function methods:RegisterEvent(event) self.events[event] = true end
        function methods:SetScript(name, callback) self.scripts[name] = callback end
        function methods:IsShown() return false end
        env.CreateFrame = function()
            local frame = setmetatable({ events = {}, scripts = {} }, { __index = methods })
            state.frames[#state.frames + 1] = frame
            return frame
        end
        env.GetTime = function() return state.now end
        env.GetServerTime = function() return 1700000000 + math.floor(state.now) end
        env.C_Timer = { After = function(delay, callback)
            state.timers[#state.timers + 1] = { at = state.now + delay, callback = callback }
        end }
        local function unit(token)
            if token == "player" then return own end
            if token == "target" and not state.hideTarget then return peer end
            if token == "party1" and state.grouped and not state.partyIdentityUnavailable then
                return state.partyOverride or peer
            end
        end
        env.UnitGUID = function(token) local p = unit(token); return p and p.guid end
        env.UnitFullName = function(token) local p = unit(token); if p then return p.name, p.realm end end
        env.UnitClass = function(token) local p = unit(token); if p then return p.classFile, p.classFile end end
        env.UnitLevel = function(token) return unit(token) and 30 end
        env.GetMaxPlayerLevel = function() return 60 end
        env.RegionalUniqueNamesEnabled = function() return false end
        env.GetNormalizedRealmName = function() return "Forever" end
        env.UnitFactionGroup = function() return options.faction or "Alliance" end
        env.GetZonePVPInfo = function()
            if not options.emptyMetadata then return "friendly", false, options.faction or "Alliance" end
        end
        env.C_PvP = { GetZonePVPInfo = function()
            if not options.emptyMetadata then return "friendly", false, options.faction or "Alliance" end
        end }
        env.IsInGroup = function() return state.grouped end
        env.IsInRaid = function() return state.raid or false end
        env.GetNumGroupMembers = function() return state.groupCount or (state.grouped and 2 or 0) end
        env.UnitIsDeadOrGhost = function() return false end
        env.IsInInstance = function() return false end
        env.IsOutdoors = function() return true end
        env.InCombatLockdown = function() return false end
        env.UnitIsVisible = function(token) return unit(token) ~= nil end
        env.UnitInPhase = function() return true end
        env.UnitPosition = function() return 500, 314, 0, 0 end
        env.C_PartyInfo = {
            CanInvite = function() return true end,
            InviteUnit = function() state.invites = state.invites + 1 end,
            LeaveParty = function()
                state.leaves = state.leaves + 1
                if state.sharedParty then
                    for _, member in ipairs(state.sharedParty) do member.grouped = false end
                else state.grouped = false end
            end,
        }
        local function vector(x, y) return { GetXY = function() return x, y end } end
        env.CreateVector2D = vector
        env.C_Map = {
            GetBestMapForUnit = function() return options.mapID or 37 end,
            GetMapLevels = function() if not options.emptyMetadata then return 1, 10 end end,
            GetMapInfo = function(mapID) return { name = "Test outskirts", mapType = 3,
                mapID = mapID, parentMapID = options.mapID == 1420 and 1415 or 13 } end,
            GetPlayerMapPosition = function() return vector(state.mapX, state.mapY) end,
            GetWorldPosFromMapPos = function(_, pos)
                local x, y = pos:GetXY()
                return 0, vector(x * 1000, y * 1000)
            end,
        }
        env.C_SpecializationInfo = {
            GetSpecialization = function() return 1 end,
            GetSpecializationInfo = function() return beta and 259 or 62, beta and "Assassination" or "Arcane" end,
        }
        env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) state.prints[#state.prints + 1] = text end }
        env.Enum = {
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
            SendAddonMessageResult = { Success = 0 },
            GameRule = { HardcoreRuleset = 1, RPRuleset = 2, PvPRuleset = 3 },
        }
        env.C_GameRules = { IsGameRuleActive = function() return false end }
        env.C_ChatInfo = {
            RegisterAddonMessagePrefix = function(prefix)
                return options.queuePrefixFailure and prefix == "ForeverDuelQ1" and 2 or 0
            end,
            SendAddonMessage = function(prefix, payload, channel, target)
                state.sent[#state.sent + 1] = { prefix = prefix, payload = payload, channel = channel, target = target }
                return 0
            end,
        }
        env.AcceptDuel = function() state.accepts = state.accepts + 1 end
        env.CancelDuel = function() state.declines = state.declines + 1 end
        env.StartDuel = function(token) state.requestedUnit = token end
        env.hooksecurefunc = function(name, callback)
            local original = env[name]
            env[name] = function(...) original(...); callback(...) end
        end
        env.ERR_DUEL_REQUESTED = "You have requested a duel."
        env.ERR_DUEL_CANCELLED = "Duel canceled."
        env.DUEL_COUNTDOWN = "Duel starting: %d"
        env.DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
        env.DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel"
        local toc = assert(io.open("ForeverDuel/ForeverDuel.toc", "r"))
        for line in toc:lines() do
            local file = line:match("^([%w_]+%.lua)%s*$")
            if file then
                state.loaded[#state.loaded + 1] = file
                local chunk = assert(loadfile("ForeverDuel/" .. file))
                setfenv(chunk, env)("ForeverDuel", FD)
            end
        end
        toc:close()
        local function noop() end
        FD.UI = { Create = noop, Render = noop, Hide = noop, Restore = function() return true end }
        FD.Profile.RefreshIfShown, FD.Profile.Toggle = noop, noop
        FD.Minimap.Initialize, FD.Tooltip.Initialize = noop, noop
        FD.Presence.Initialize, FD.Presence.Changed = noop, noop
        FD.QueueUI.Show = function() state.queueShown = true end
        FD.QueueUI.Toggle = function() state.queueShown = not state.queueShown end
        FD.QueueUI.RefreshIfShown = noop
        FD.Presence.players[peer.guid] = { guid = peer.guid, fullName = peer.name .. "-Forever",
            level = 30, maxLevel = 60, rating = 1500, mapID = options.mapID or 37, lastSeen = state.now }
        function state:emit(event, ...)
            for _, frame in ipairs(self.frames) do
                if frame.events[event] then frame.scripts.OnEvent(frame, event, ...) end
            end
        end
        function state:advance(seconds)
            local untilAt, count = self.now + seconds, 0
            while true do
                local index, at
                for i, timer in ipairs(self.timers) do
                    if timer.at <= untilAt and (not at or timer.at < at) then index, at = i, timer.at end
                end
                if not index then break end
                count = count + 1; assert(count < 2000, "integration timer runaway")
                local timer = table.remove(self.timers, index)
                self.now = at; timer.callback()
            end
            self.now = untilAt
        end
        function state:command(text) env.SlashCmdList.FOREVERDUEL(text) end
        function state:export()
            for i = #self.prints, 1, -1 do
                local command = self.prints[i]:match("(/duelrating queue venue import .+)$")
                if command then return command end
            end
        end
        state.FD, state.env, state.own, state.peer = FD, env, own, peer
        state:emit("PLAYER_LOGIN")
        return state
    end

    local c = client()
    equal(c.loaded[#c.loaded], "Core.lua", "integration follows real TOC order")
    equal(c.FD.queue.state, "IDLE", "optional queue initializes alongside rated engine")
    equal(c.FD.duel:State(), "IDLE", "queue initialization preserves ordinary rated readiness")
    equal(c.FD.Comms.available, true, "existing rated prefix remains registered")
    equal(c.FD.QueueTransport.available, true, "queue has its own registered prefix")
    equal(c.FD.QueueWow:Settings().ruleset, "NORMAL", "ruleset comes from native game rules automatically")
    c:command("queue join")
    equal(c.FD.queue.state, "SEARCHING", "first join searches without manual ruleset or venue setup")
    equal(c.queueShown, true, "joining opens queue status UI")
    c:command("queue leave")
    equal(c.FD.queue:Configure({ ruleset = "PVP" }), false, "native ruleset cannot be overwritten through public settings")
    c:command("queue help")
    equal(c.FD.queue:Configure({ scope = "CONTINENT" }), true, "continent scope available immediately")
    equal(c.FD.queue:Configure({ scope = "RULESET" }), true, "ruleset scope available immediately")
    c.FD.queue:Configure({ scope = "ZONE" })
    c:command("queue venue add test-courtyard 1 1 10")
    local command = assert(c:export(), "venue capture must print an exact import command")
    local function place(state, id)
        for _, entry in ipairs(state.FD.QueueWow:Catalog()) do if entry.id == id then return entry end end
    end
    local first = assert(place(c, "test-courtyard"))
    equal(first.mapX, 0.5005, "captured map X normalized to exported precision")
    equal(first.mapY, 0.31415927, "captured map Y normalized to exported precision")
    equal(first.factions.Alliance, true, "captured place restricted to own faction")
    equal(first.factions.Horde, nil, "local approval never creates an enemy-faction venue")
    local other = client(true)
    other:command(command:gsub("^/duelrating ", ""))
    local imported = assert(place(other, "test-courtyard"))
    equal(imported.id, first.id, "import retains stable place ID")
    equal(imported.mapX, first.mapX, "clients retain exact same normalized X")
    equal(imported.mapY, first.mapY, "clients retain exact same normalized Y")
    local aResolved = assert(c.FD.Venues:Resolve(first.id, c.FD.queue:VenueEnvironment()))
    local bResolved = assert(other.FD.Venues:Resolve(first.id, other.FD.queue:VenueEnvironment()))
    equal(aResolved.x, bResolved.x, "native world conversion agrees on exported place")
    equal(math.floor(aResolved.x + 0.5), math.floor(bResolved.x + 0.5), "half-yard boundary agrees across import")
    c:command("queue join")
    equal(c.FD.queue.state, "SEARCHING", "configured native queue joins with approved place")
    local saved = c.FD.Database.data
    c:command("reset")
    equal(c.FD.resetUntil, nil, "reset confirmation cannot be opened while queued")
    c.FD.resetUntil = c.now + 15
    c:command("reset confirm")
    equal(c.FD.Database.data, saved, "preexisting confirmation cannot bypass queue reset guard")
    equal(c.FD.queue:Configure({ levelGap = 1 }), false, "active queue freezes settings")
    c.FD.queue:Announce(c.peer.name .. "-Forever")
    c:advance(0.25)
    local announced
    for _, sent in ipairs(c.sent) do
        if sent.prefix == "ForeverDuelQ1" then
            local packet = c.FD.QueueProtocol:Decode(sent.payload)
            if packet and packet.kind == "PROFILE" then announced = packet end
        end
    end
    equal(announced ~= nil, true, "adapter profile metadata does not block discovery transport")
    equal(announced and announced.fullName, nil, "native transport name is not a profile claim")
    equal(c.accepts, 0, "joining and announcing cannot grant native duel consent")
    equal(#c.FD.Database.data.matches, 0, "joining and announcing cannot create rating history")
    local originalQueueSession = c.FD.queue.session
    c.FD.Wow:Environment().notify("request", { opponent = { guid = c.peer.guid, fullName = c.peer.name .. "-Forever" } })
    equal(c.FD.queue.state, "IDLE", "request before both players are ready ends queue")
    equal(c.FD.queue.session, nil, "unready native request retires queue session")
    equal(originalQueueSession ~= nil, true)
    equal(c.FD.duel.active, nil, "queue request notification does not create or accept duel itself")

    -- A button installs one native-tested common spot on both clients. No
    -- manually entered coordinates, ruleset or verification flags are used.
    -- Reproduce the user's map1420 save failure: both native territory and
    -- native level getters may return nothing on this Forever client.
    local fallbackOptions = { mapID = 1420, faction = "Horde", emptyMetadata = true }
    local setupA, setupB = client(false, fallbackOptions), client(true, fallbackOptions)
    equal(setupA.FD:CaptureQueueVenue(), false, "button cannot approve an untested outdoor place")
    setupA.env.StartDuel("target")
    setupA:emit("UI_INFO_MESSAGE", 1, setupA.env.ERR_DUEL_REQUESTED)
    setupB:emit("DUEL_REQUESTED", setupA.own.name .. "-Forever")
    setupA.env.AcceptDuel(); setupB.env.AcceptDuel()
    for _, state in ipairs({ setupA, setupB }) do
        state:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
        state:advance(4)
    end
    setupA:emit("DUEL_FINISHED", true)
    setupA:emit("CHAT_MSG_SYSTEM", "Alpha-Forever has defeated Beta-Forever in a duel")
    setupB:emit("CHAT_MSG_SYSTEM", "Alpha-Forever has defeated Beta-Forever in a duel")
    setupB:emit("DUEL_FINISHED", true)
    equal(setupA.FD:CaptureQueueVenue(), true, "button records an ordinary native-tested spot automatically")
    setupB:command("queue join")
    equal(setupB.FD.queue.state, "SEARCHING", "test partner may join before the shared place arrives")
    setupA:advance(1)
    local shared
    for _, sent in ipairs(setupA.sent) do
        local packet = sent.prefix == "ForeverDuelQ1" and setupA.FD.QueueProtocol:Decode(sent.payload)
        if packet and packet.kind == "VENUE" then
            shared = packet
            setupB:emit("CHAT_MSG_ADDON", sent.prefix, sent.payload, sent.channel, setupA.own.name .. "-Forever")
        end
    end
    equal(shared ~= nil, true, "button sends a venue record to the exact native test opponent")
    local captured = setupA.FD.QueueWow:Catalog()[1]
    local synchronized = setupB.FD.QueueWow:Catalog()[1]
    equal(synchronized ~= nil, true, "second client accepts place only after its own successful test")
    equal(setupB.FD.queue.state, "SEARCHING", "place import while searching preserves the existing queue session")
    equal(synchronized.id, captured.id, "button gives both clients the same stable venue ID")
    equal(synchronized.mapX, captured.mapX, "button synchronization preserves exact map X")
    equal(synchronized.mapY, captured.mapY, "button synchronization preserves exact map Y")
    equal(captured.mapID, 1420, "tested Tirisfal position is captured on the actual native map")
    equal(captured.factions.Horde, true, "Tirisfal fallback approves the tested Horde place")
    equal(captured.factions.Alliance, nil, "Tirisfal fallback cannot approve this place for Alliance")
    equal(captured.zoneMinLevel, 1, "missing native minimum uses documented Classic starting-zone metadata")
    equal(captured.zoneMaxLevel, 12, "missing native maximum uses documented Classic starting-zone metadata")
    equal(captured.metadataSource, "CLASSIC", "fallback source is retained locally")
    equal(synchronized.zoneMaxLevel, 12, "receiving client derives and validates the same local zone metadata")
    local statusStart = #setupA.prints
    setupA:command("status")
    local sawLast = false
    for index = statusStart + 1, #setupA.prints do
        if setupA.prints[index]:find("Last:", 1, true) then sawLast = true end
    end
    equal(sawLast, true, "status remains usable after native test and metadata capture")
    setupA:command("diagnose")
    equal(#setupA.FD.Debug:RequestTrace() > 0, true, "native request diagnostics are available without enabling debug")
    equal(captured.minPlayerLevel, 30, "automatic player minimum uses actually tested character level")
    equal(#setupA.FD.Database.data.matches + #setupB.FD.Database.data.matches, 0, "native venue testing creates no rated history")
    equal(setupA.FD.Database:GetStats().rating, 1500, "saving and sharing a tested place never changes rating")
    equal(setupB.FD.Database:GetStats().rating, 1500, "receiving place never changes peer rating")
    setupA:command("queue join"); setupB:command("queue join")
    local setupCursor = { [setupA] = #setupA.sent, [setupB] = #setupB.sent }
    local setupDropGroupedWhispers, pendingPartyDeliveries = false, 0
    local function setupFlush(rounds)
        for _ = 1, rounds do
            setupA:advance(0.25); setupB:advance(0.25)
            for _, from in ipairs({ setupA, setupB }) do
                local to = from == setupA and setupB or setupA
                while setupCursor[from] < #from.sent do
                    setupCursor[from] = setupCursor[from] + 1
                    local sent = from.sent[setupCursor[from]]
                    if (sent.prefix == "ForeverDuelQ1" or sent.prefix == "ForeverDuel2")
                        and not (setupDropGroupedWhispers and setupA.grouped and setupB.grouped and sent.channel == "WHISPER") then
                        if sent.channel == "PARTY" then
                            from:emit("CHAT_MSG_ADDON", sent.prefix, sent.payload, sent.channel, from.own.name .. "-Forever")
                            if to.partyIdentityUnavailable then pendingPartyDeliveries = pendingPartyDeliveries + 1 end
                        end
                        to:emit("CHAT_MSG_ADDON", sent.prefix, sent.payload, sent.channel, from.own.name .. "-Forever")
                    end
                end
            end
        end
    end
    setupFlush(36)
    equal(setupA.FD.queue:GetStatus().discovered, 1, "nearby same-level test opponent discovered through actual queue transport")
    equal(setupA.FD.queue.state, "GROUPING", "new UI setup permits native matchmaking without slash setup")
    equal(setupB.FD.queue.state, "GROUPING", "peer receives the same automatic pairing")
    equal(setupA.invites + setupB.invites, 1, "matching generates exactly one grouping request")
    local setupTicketA, setupTicketB = setupA.FD.queue.ticket, setupB.FD.queue.ticket
    local setupAcceptedBefore = { [setupA] = setupA.accepts, [setupB] = setupB.accepts }
    setupA.grouped, setupB.grouped = true, true
    setupA.sharedParty, setupB.sharedParty = { setupA, setupB }, { setupA, setupB }
    setupB.partyIdentityUnavailable, setupDropGroupedWhispers = true, true
    equal(setupB.env.IsInGroup(), true, "native group acceptance can precede party identity")
    equal(setupB.env.GetNumGroupMembers(), 2, "loading group already has exactly two native members")
    equal(setupB.FD.Wow:Identity("party1"), nil, "peer native identity is temporarily unavailable")
    local earlyGroup = assert(setupA.FD.QueueProtocol:Encode(setupA.FD.queue:Control("GROUP")))
    equal(setupB.FD.QueueTransport:Receive("ForeverDuelQ1", earlyGroup, "PARTY", "Alpha-Forever"), false,
        "PARTY proof is rejected until receiver can identify its exact native opponent")
    setupFlush(16)
    equal(pendingPartyDeliveries > 0, true, "native PARTY controls actually arrive during identity loading")
    equal(setupA.FD.queue.state, "GROUPING", "coordinator waits while receiver cannot confirm native membership")
    equal(setupB.FD.queue.state, "GROUPING", "temporary native party identity loading cannot cancel the queue")
    equal(setupA.FD.queue.ticket, setupTicketA, "coordinator retains its original reservation during loading")
    equal(setupB.FD.queue.ticket, setupTicketB, "receiver retains its original reservation during loading")
    equal(setupTicketB.peerGrouped, nil, "unverified PARTY controls cannot establish peer grouping")
    equal(setupA.leaves + setupB.leaves, 0, "native identity loading cannot remove the accepted party")
    equal(setupA.accepts + setupB.accepts, setupAcceptedBefore[setupA] + setupAcceptedBefore[setupB],
        "queue identity recovery cannot grant native duel acceptance")
    equal(#setupA.FD.Database.data.matches + #setupB.FD.Database.data.matches, 0,
        "queue identity loading cannot create rating history")
    setupB.partyIdentityUnavailable = false
    setupFlush(44)
    equal(setupA.FD.queue.state, "READY", "colocated test players become ready with saved button spot")
    equal(setupB.FD.queue.state, "READY", "both clients confirm the same tested venue")
    equal(setupA.FD.queue.ticket.deadline, setupB.FD.queue.ticket.deadline, "button-created match retains identical shared start timer")
    equal(setupA.FD.queue.ticket.venue.mapID, 1420, "recovered planning retains the native-tested Tirisfal map")
    equal(setupA.FD.queue.ticket.venue.continentID, 0, "zero-valued native continent identity remains valid")
    equal(setupA.FD.queue.ticket.venue.mapX, captured.mapX, "recovered planning retains eight-decimal saved map X")
    equal(setupA.FD.queue.ticket.venue.mapY, synchronized.mapY, "both clients resolve the same saved map Y")
    equal(setupA.invites + setupB.invites, 1, "loading recovery does not issue duplicate native invitations")
    equal(setupA.FD.QueueTransport.lastReceiveRoute, "PARTY", "grouped recovery does not depend on delayed whispers")
    equal(setupB.FD.QueueTransport.lastReceiveRoute, "PARTY", "receiver recovers using exact native ticket PARTY proof")
    equal(setupA.FD.queue:Challenge(), true, "recovered queue starts the normal native duel request")
    equal(setupA.requestedUnit, "party1", "queue challenge targets the now-verified native party unit")
    equal(setupA.FD.duel.active, nil, "queue challenge still awaits native request acknowledgment")
    setupA:emit("UI_INFO_MESSAGE", 1, setupA.env.ERR_DUEL_REQUESTED)
    setupB:emit("DUEL_REQUESTED", "Alpha-Forever")
    setupFlush(8)
    equal(setupA.FD.queue.state, "DUEL", "recovered coordinator hands off to the rated lifecycle")
    equal(setupB.FD.queue.state, "DUEL", "recovered receiver hands off the same native duel")
    equal(setupA.FD.duel:State(), "READY", "native identity recovery still requires rated discovery")
    equal(setupB.FD.duel:State(), "READY", "recovered peer completes current-request discovery")
    equal(setupB.accepts, setupAcceptedBefore[setupB], "successful recovery and discovery still require explicit Rated choices")
    setupA.FD.duel:AcceptRated(); setupB.FD.duel:AcceptRated(); setupFlush(8)
    equal(setupA.FD.duel:State(), "RATED_CONFIRMED", "recovered queue retains explicit outgoing rated agreement")
    equal(setupB.FD.duel:State(), "RATED_CONFIRMED", "recovered queue retains explicit incoming rated agreement")
    equal(setupB.accepts, setupAcceptedBefore[setupB] + 1, "only the normal rated agreement accepts the native duel")
    setupA:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
    setupB:emit("CHAT_MSG_SYSTEM", "Duel starting: 3"); setupFlush(16)
    equal(setupA.FD.duel:State(), "IN_PROGRESS", "recovered queue requires native countdown before play")
    equal(setupB.FD.duel:State(), "IN_PROGRESS", "both recovered clients observe the native start")
    setupA:emit("CHAT_MSG_SYSTEM", "Alpha-Forever has defeated Beta-Forever in a duel")
    setupB:emit("CHAT_MSG_SYSTEM", "Alpha-Forever has defeated Beta-Forever in a duel")
    setupA:emit("DUEL_FINISHED", true); setupB:emit("DUEL_FINISHED", true); setupFlush(16)
    equal(#setupA.FD.Database.data.matches, 1, "recovered queue writes one native-evidence winning record")
    equal(#setupB.FD.Database.data.matches, 1, "recovered queue writes one native-evidence losing record")
    equal(setupA.FD.Database:GetStats().rating, 1516, "recovered queue preserves normal winning rating calculation")
    equal(setupB.FD.Database:GetStats().rating, 1484, "recovered queue preserves complementary losing rating")
    -- A terminal PARTY packet can arrive after the peer already dissolved the
    -- native party. Its proof remains rejected; the existing bounded finish
    -- wait must still retire the completed queue without another leave.
    setupFlush(64)
    equal(setupA.FD.queue.state, "IDLE", "completed recovered queue retires its session")
    equal(setupB.FD.queue.state, "IDLE", "completed recovered queue does not rejoin automatically")
    equal(setupA.leaves + setupB.leaves, 1, "completed recovered queue removes only its exact shared party once")

    local function approvedClient(beta)
        local result = client(beta)
        result:command(command:gsub("^/duelrating ", ""))
        result:command("queue join")
        return result
    end
    local a, b = approvedClient(false), approvedClient(true)
    local function ready(state, opponent)
        local q, peerProfile = state.FD.queue, state.FD.Copy(opponent.FD.queue.ownProfile)
        local id = q.ownProfile.guid < peerProfile.guid and q.session .. "." .. opponent.FD.queue.session
            or opponent.FD.queue.session .. "." .. q.session
        local venue = assert(state.FD.Venues:Resolve("test-courtyard", q:VenueEnvironment()))
        q.ticket = { id = id, venue = venue,
            ownSession = q.session, peerSession = opponent.FD.queue.session, peer = peerProfile,
            player = state.FD.Copy(q.ownProfile), ownedParty = true, ownArrived = true, peerArrived = true,
            samples = 3, deadline = state.env.GetServerTime() + 120 }
        q.state = "READY"; state.grouped = true
    end
    for _, changed in ipairs({ "wrong opponent", "third member" }) do
        local unsafe, originalPeer = approvedClient(false), approvedClient(true)
        ready(unsafe, originalPeer)
        local q, t = unsafe.FD.queue, unsafe.FD.queue.ticket
        q.state = "GROUPING"
        t.createdAt, t.groupAt, t.lastPeerAt, t.lastSend = unsafe.now, unsafe.now, unsafe.now, unsafe.now
        if changed == "wrong opponent" then
            unsafe.partyOverride = { guid = "Player-1-00000003", name = "Gamma", realm = "Forever", classFile = "WARRIOR" }
        else unsafe.groupCount = 3 end
        q:Run(function() q:Tick() end)
        equal(q.state, "CLEANUP", changed .. " is a proven changed group, not temporary identity loading")
        equal(unsafe.leaves, 0, changed .. " cannot authorize automatic leave from an unrelated group")
        equal(unsafe.grouped, true, changed .. " native group remains available for manual management")
        equal(unsafe.accepts, 0, changed .. " cancellation cannot grant native duel acceptance")
        equal(#unsafe.FD.Database.data.matches, 0, changed .. " cancellation cannot write rating history")
        equal(unsafe.FD.Database:GetStats().rating, 1500, changed .. " cancellation cannot change rating")
        equal(q:Settings().cooldownUntil or 0, 0, changed .. " is technical cancellation without a no-show pause")
    end
    ready(a, b); ready(b, a)
    a.env.StartDuel("party1")
    equal(a.FD.duel.active, nil, "native request attempt still awaits server acknowledgement")
    a:emit("UI_INFO_MESSAGE", 1, a.env.ERR_DUEL_REQUESTED)
    b:emit("DUEL_REQUESTED", a.own.name .. "-Forever")
    equal(a.FD.queue.state, "DUEL", "ready outgoing request handed to existing rated engine")
    equal(b.FD.queue.state, "DUEL", "ready incoming request handed to existing rated engine")
    equal(a.FD.queue.ticket.duelMatch, a.FD.duel.active, "handoff binds exact native duel object")
    equal(a.FD.duel:State(), "CHECKING_ADDON", "queue ready never bypasses rated discovery")
    equal(b.accepts, 0, "queue ready cannot auto-accept native duel")
    local cursor = { [a] = 0, [b] = 0 }
    local holdResultFrom, held = nil, {}
    local function flush(rounds)
        for _ = 1, rounds or 8 do
            a:advance(0.2); b:advance(0.2)
            for _, from in ipairs({ a, b }) do
                local to = from == a and b or a
                while cursor[from] < #from.sent do
                    cursor[from] = cursor[from] + 1
                    local sent = from.sent[cursor[from]]
                    local p = sent.prefix == "ForeverDuel2" and from.FD.Protocol:Decode(sent.payload)
                    if from == holdResultFrom and p and p.kind == "RESULT" then
                        held[#held + 1] = { from = from, to = to, message = sent }
                    else to:emit("CHAT_MSG_ADDON", sent.prefix, sent.payload, sent.channel, from.own.name .. "-Forever") end
                end
            end
        end
    end
    flush(6)
    equal(a.FD.duel:State(), "READY", "rated handshake remains separately required")
    equal(b.FD.duel:State(), "READY", "both native duel identities require rated handshake")
    equal(b.accepts, 0, "discovery alone still cannot grant consent")
    local packet = assert(a.FD.QueueProtocol:Encode({ kind = "READY", session = b.FD.queue.session,
        peerSession = a.FD.queue.session, ticket = a.FD.queue.ticket.id, deadline = 0 }))
    a:emit("CHAT_MSG_ADDON", "ForeverDuelQ1", packet, "WHISPER", b.own.name .. "-Forever")
    equal(a.FD.duel:State(), "READY", "queue READY packet cannot grant rated agreement")
    equal(a.FD.duel.active.nativeAccepted, nil, "queue packet cannot grant native acceptance")
    a.FD.duel:AcceptRated(); b.FD.duel:AcceptRated(); flush(8)
    equal(a.FD.duel:State(), "RATED_CONFIRMED", "existing explicit consent protocol completes")
    equal(b.FD.duel:State(), "RATED_CONFIRMED", "existing incoming rated confirmation")
    equal(b.accepts, 1, "only existing rated agreement accepts native duel")
    a:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
    b:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
    flush(18)
    equal(a.FD.duel:State(), "IN_PROGRESS", "native countdown evidence still required")
    equal(b.FD.duel:State(), "IN_PROGRESS", "native countdown starts both clients")
    a:emit("CHAT_MSG_SYSTEM", "Alpha-Forever has defeated Beta-Forever in a duel")
    b:emit("CHAT_MSG_SYSTEM", "Alpha-Forever has defeated Beta-Forever in a duel")
    a:emit("DUEL_FINISHED"); b:emit("DUEL_FINISHED"); flush(8)
    equal(#a.FD.Database.data.matches, 1, "real rated finalization stores one winning record")
    equal(#b.FD.Database.data.matches, 1, "real rated finalization stores one losing record")
    equal(a.FD.Database:GetStats().rating, 1516, "ratings remain owned by existing rated engine")
    equal(b.FD.Database:GetStats().rating, 1484, "existing rated engine applies reciprocal loss")
    equal(a.FD.queue.state, "IDLE", "finished notification completes queue cleanup")
    equal(b.FD.queue.state, "IDLE", "finished notification does not auto-join another match")
    equal(a.leaves, 1, "only owned exact queue party cleaned up")
    equal(b.leaves, 1, "both clients close owned queue party")

    for _, delayBeta in ipairs({ true, false }) do
        a, b = approvedClient(false), approvedClient(true)
        cursor, held = { [a] = 0, [b] = 0 }, {}
        a.sharedParty, b.sharedParty = { a, b }, { a, b }
        ready(a, b); ready(b, a)
        a.env.StartDuel("party1")
        a:emit("UI_INFO_MESSAGE", 1, a.env.ERR_DUEL_REQUESTED)
        b:emit("DUEL_REQUESTED", a.own.name .. "-Forever")
        flush(6)
        a.FD.duel:AcceptRated(); b.FD.duel:AcceptRated(); flush(8)
        a:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
        b:emit("CHAT_MSG_SYSTEM", "Duel starting: 3"); flush(18)
        -- There is no target, focus or nameplate after the duel begins. The
        -- shared native party is the slower client's only opponent evidence.
        a.hideTarget, b.hideTarget = true, true
        equal(a.FD.Wow:Identity("target"), nil, "shared-party regression has no target identity")
        equal(b.FD.Wow:Identity("target"), nil, "both clients rely on native party identity")
        a:emit("CHAT_MSG_SYSTEM", "Alpha-Forever has defeated Beta-Forever in a duel")
        b:emit("CHAT_MSG_SYSTEM", "Alpha-Forever has defeated Beta-Forever in a duel")
        local first, slower = delayBeta and b or a, delayBeta and a or b
        holdResultFrom = first
        -- Finish the eventual slower client first, reversing event order for
        -- the two cases. Only its peer's result is withheld from it.
        slower:emit("DUEL_FINISHED"); first:emit("DUEL_FINISHED"); flush(8)
        equal(#first.FD.Database.data.matches, 1, "first client can commit with peer result")
        equal(#slower.FD.Database.data.matches, 0, "delayed result keeps slower client uncommitted")
        equal(slower.FD.duel:State(), "FINISHING", "peer queue finish cannot unrate slower duel")
        equal(first.FD.queue.state, "CLEANUP", "first finalized queue waits for peer terminal evidence")
        equal(first.grouped and slower.grouped, true, "native party retained until slower client commits")
        equal(first.leaves + slower.leaves, 0, "queue cleanup cannot prematurely remove sole native opponent")
        equal(#held > 0, true, "test actually delays native rated result messages")
        holdResultFrom = nil
        for _, pending in ipairs(held) do
            local sent = pending.message
            pending.to:emit("CHAT_MSG_ADDON", sent.prefix, sent.payload, sent.channel, pending.from.own.name .. "-Forever")
        end
        held = {}; flush(8)
        equal(#slower.FD.Database.data.matches, 1, "slower client commits after delayed matching result")
        equal(a.FD.Database:GetStats().rating, 1516, "shared-party delayed result retains reciprocal win")
        equal(b.FD.Database:GetStats().rating, 1484, "shared-party delayed result retains reciprocal loss")
        equal(first.FD.queue.state, "IDLE", "peer completion releases first queue cleanup")
        equal(slower.FD.queue.state, "IDLE", "both matching terminal notices complete cleanup")
        equal(first.grouped or slower.grouped, false, "shared native party actually removed after both commits")
        equal(first.leaves + slower.leaves, 1, "exact party removed once for both linked clients")
    end

    local moved, waiting = approvedClient(false), approvedClient(true)
    ready(moved, waiting); ready(waiting, moved)
    -- Reposition after the most recent READY check, before the next queue Tick.
    -- Native acknowledgement must revalidate the live position itself.
    moved.mapX = 0.6
    moved.env.StartDuel("party1")
    moved:emit("UI_INFO_MESSAGE", 1, moved.env.ERR_DUEL_REQUESTED)
    equal(moved.FD.queue.state, "IDLE", "leaving venue between ticks blocks ready handoff")
    equal(moved.FD.duel:State(), "CHECKING_ADDON", "out-of-venue request retains ordinary rated discovery")
    equal(moved.accepts, 0, "out-of-venue request cannot grant native consent")
    equal(#moved.FD.Database.data.matches, 0, "failed ready handoff creates no history")
    equal(moved.FD.Database:GetStats().rating, 1500, "failed ready handoff creates no penalty")

    local expired, partner = approvedClient(false), approvedClient(true)
    ready(expired, partner); ready(partner, expired)
    expired.FD.queue.ticket.deadline = expired.env.GetServerTime()
    expired.env.StartDuel("party1")
    expired:emit("UI_INFO_MESSAGE", 1, expired.env.ERR_DUEL_REQUESTED)
    equal(expired.FD.queue.state, "IDLE", "expired ready timer cannot hand off between ticks")
    equal(expired.FD.duel:State(), "CHECKING_ADDON", "expired ready request preserves ordinary rated flow")
    equal(expired.accepts, 0, "expired readiness cannot grant native consent")

    local world = client()
    world:emit("DUEL_REQUESTED", world.peer.name .. "-Forever")
    local active = world.FD.duel.active
    world.FD.queueFrame.scripts.OnEvent(world.FD.queueFrame, "PLAYER_LEAVING_WORLD")
    equal(world.FD.duel.active, active, "queue loading event cannot abort unrelated rated duel")
    world.FD.queueFrame.scripts.OnEvent(world.FD.queueFrame, "PLAYER_ENTERING_WORLD")
    equal(world.FD.duel.active, active, "queue loading completion preserves unrelated rated duel")
    world:emit("PLAYER_LEAVING_WORLD")
    equal(world.FD.duel.active, nil, "existing Core world-transition rated abort remains explicit baseline")
    local disabled = client(false, { queuePrefixFailure = true })
    equal(disabled.FD.QueueTransport.available, false, "optional queue prefix failure reported")
    disabled:emit("DUEL_REQUESTED", disabled.peer.name .. "-Forever")
    equal(disabled.FD.duel:State(), "CHECKING_ADDON", "queue transport failure does not disable existing rated duels")
    equal(disabled.accepts, 0, "unavailable queue cannot grant native consent")
end
