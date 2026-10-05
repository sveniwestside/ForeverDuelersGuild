return function(_, equal)
    local function client(options)
        options = options or {}
        local state = { now = 10, timers = {}, sent = {}, received = {}, invited = {}, left = 0,
            grouped = false, raid = false, count = 0, dead = false, instance = false,
            outdoors = true, combat = false, visible = true, phase = true,
            registerResult = 0, sendResult = 0, worldCalls = 0, mapUnits = {}, territory = "friendly" }
        local env = setmetatable({}, { __index = _G })
        env._G = env
        local FD = {}
        local function load(name)
            local module = assert(loadfile("ForeverDuel/" .. name .. ".lua"))
            setfenv(module, env)("ForeverDuel", FD)
        end
        state.secret = {}
        env.issecretvalue = function(value) return value == state.secret end
        env.GetTime = function() return state.now end
        env.GetServerTime = function() return 1700000000 + math.floor(state.now) end
        local function vector(x, y) return { GetXY = function() return x, y end } end
        env.CreateVector2D = vector
        env.C_Map = {
            GetBestMapForUnit = function() return state.mapID or 37 end,
            GetPlayerMapPosition = function(mapID, unit)
                state.mapUnits[#state.mapUnits + 1] = unit
                return state.mapPosition or vector(0.5, 0.5)
            end,
            GetWorldPosFromMapPos = function(mapID, point)
                state.worldCalls = state.worldCalls + 1
                local x, y = point:GetXY()
                return state.continentID or 0, state.worldPosition or vector(x * 1000, y * 1000)
            end,
            GetMapLevels = function() return state.zoneMin or 1, state.zoneMax or 10 end,
            GetMapInfo = function(mapID)
                local parents = { [37] = 13, [1429] = 1415, [27] = 13, [1426] = 1415,
                    [57] = 12, [1438] = 1414, [1] = 12, [1411] = 1414,
                    [7] = 12, [1412] = 1414, [18] = 13, [1420] = 1415 }
                return state.mapInfo and state.mapInfo[mapID]
                    or { name = "Elwynn Forest", mapID = mapID, parentMapID = parents[mapID] or 1415, mapType = 3 }
            end,
            CanSetUserWaypointOnMap = function() return state.waypointAllowed ~= false end,
            GetUserWaypoint = function() return state.waypoint end,
            SetUserWaypoint = function(point) state.waypoint = point; return true end,
            ClearUserWaypoint = function() state.waypoint = nil end,
        }
        env.UiMapPoint = { CreateFromCoordinates = function(mapID, x, y) return { uiMapID = mapID, position = vector(x, y) } end }
        env.C_SuperTrack = {
            IsSuperTrackingUserWaypoint = function() return state.trackingWaypoint == true end,
            SetSuperTrackedUserWaypoint = function(value) state.trackingWaypoint = value end,
            GetSuperTrackedQuestID = function() return state.trackingQuest or 0 end,
            SetSuperTrackedQuestID = function(id) state.trackingQuest = id end,
        }
        env.UnitFactionGroup = function() return state.faction or "Alliance" end
        env.C_PvP = { GetZonePVPInfo = function()
            if state.territoryError then error("native territory unavailable") end
            if state.territoryMissing then return end
            return state.territory, false
        end }
        env.IsInGroup = function() return state.grouped end
        env.IsInRaid = function() return state.raid end
        env.GetNumGroupMembers = function() return state.count end
        env.UnitIsDeadOrGhost = function() return state.dead end
        env.IsInInstance = function() return state.instance end
        env.IsOutdoors = function() return state.outdoors end
        env.InCombatLockdown = function() return state.combat end
        env.UnitIsVisible = function() return state.visible end
        env.UnitInPhase = function() return state.phase end
        env.UnitPosition = function(unit)
            if state.restrictedDistance then return state.secret end
            if unit == "player" then return 100, 100, 5, 0 end
            return state.peerX or 103, state.peerY or 104, state.peerZ or 5, state.peerInstance or 0
        end
        env.C_PartyInfo = {
            CanInvite = function() return state.canInvite ~= false end,
            InviteUnit = function(name) state.invited[#state.invited + 1] = name; if state.inviteError then error("protected") end end,
            LeaveParty = function() state.left = state.left + 1 end,
        }
        env.GetNormalizedRealmName = function() return "Forever" end
        env.RegionalUniqueNamesEnabled = function() return options.regionalNames or false end
        env.Enum = {
            GameRule = { HardcoreRuleset = 101, RPRuleset = 102, PvPRuleset = 103 },
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
            SendAddonMessageResult = { Success = 0, Throttle = 3 },
        }
        env.C_GameRules = { IsGameRuleActive = function(rule)
            if state.ruleError then error("native rules unavailable") end
            if state.activeRules and state.activeRules[rule] ~= nil then return state.activeRules[rule] end
            return false
        end }
        env.C_ChatInfo = {
            RegisterAddonMessagePrefix = function(prefix) state.prefix = prefix; return state.registerResult end,
            SendAddonMessage = function(prefix, payload, channel, target)
                state.sent[#state.sent + 1] = { prefix = prefix, payload = payload, channel = channel, target = target }
                return state.sendResult
            end,
        }
        env.C_Timer = { After = function(delay, callback) state.timers[#state.timers + 1] = { delay = delay, callback = callback } end }
        local own = { guid = "Player-1-00000001", name = "Alpha", realm = "Forever", fullName = "Alpha-Forever", level = 30, maxLevel = 60 }
        local peer = { guid = "Player-1-00000002", name = "Beta", realm = "Forever", level = 30, maxLevel = 60,
            fullName = options.regionalNames and "Beta Brave" or "Beta-Forever", session = "b1" }
        FD.Wow = {
            Readable = function(_, ...)
                for i = 1, select("#", ...) do if select(i, ...) == state.secret then return false end end
                return true
            end,
            Identity = function(_, unit)
                if unit == "player" then return own end
                if state.partyIdentityError then error("native party identity unavailable") end
                if state.partyIdentityMissing then return nil end
                return state.partyIdentity or peer
            end,
            ResolveIncoming = function(_, name) if name == peer.fullName then return state.partyIdentity or peer end end,
        }
        FD.Debug = { Log = function() end, Print = function() end }
        FD.Safe = function() error("queue must not route through rated error recovery") end
        FD.Database = {
            data = { settings = { queue = { ruleset = "NORMAL" } } },
            GetStats = function() return { rating = 1500 } end,
            NextCounter = function() state.counter = (state.counter or 0) + 1; return state.counter end,
            Copy = function(_, value) return value end,
        }
        FD.Presence = { players = { [peer.guid] = peer }, GetPlayer = function(_, guid)
            if state.expired then return nil end
            return FD.Presence.players[guid]
        end }
        function FD.Presence:Candidates()
            local list = {}
            for guid in pairs(self.players) do
                local player = self:GetPlayer(guid)
                if player then list[#list + 1] = player end
            end
            return list
        end
        function FD.Presence:FindByName(name)
            for guid in pairs(self.players) do
                local player = self:GetPlayer(guid)
                if player and player.fullName == name then return player end
            end
        end
        FD.queue = { session = "a1", state = "SEARCHING", Receive = function(_, packet, sender)
            if state.receiveError then error("isolated queue failure") end
            state.received[#state.received + 1] = { packet = packet, sender = sender }
        end }
        env.DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
        env.DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel"
        load("Constants"); load("Protocol"); load("Rating"); load("Results"); load("QueueProtocol"); load("Venues")
        load("QueueWow"); load("QueueTransport")
        FD.QueueTransport:Initialize()
        state.env, state.FD, state.own, state.peer, state.vector = env, FD, own, peer, vector
        return state
    end

    local c = client()
    local wow, transport, api = c.FD.QueueWow, c.FD.QueueTransport, c.env
    local adapter = wow:Environment()
    equal(wow:Settings().scope, "ZONE", "default local discovery")
    equal(wow:Settings().levelGap, 5, "default level gap")
    equal(wow:Settings().ruleset, "NORMAL", "all native rules false identifies Normal automatically")
    equal(wow:Settings().continentVerified, nil, "manual verification no longer required")
    c.activeRules = { [103] = true }
    equal(wow:Settings().ruleset, "PVP", "native PvP ruleset automatically detected")
    c.activeRules[102] = true
    equal(wow:Settings().ruleset, "RP", "native RP precedes PvP")
    c.activeRules[101] = true
    equal(wow:Settings().ruleset, "HARDCORE", "native Hardcore precedes RP and PvP")
    c.activeRules = { [101] = c.secret }
    equal(wow:Settings().ruleset, nil, "restricted native rules never infer Normal")
    equal(type(wow:Settings().rulesetReason), "string", "automatic detection explains unavailable data")
    c.activeRules = nil; c.ruleError = true
    equal(wow:Settings().ruleset, nil, "native rules errors do not reuse manual saved preference")
    c.ruleError = false
    wow:Save({ ruleset = "HARDCORE" })
    equal(wow:Settings().ruleset, "NORMAL", "manual preference cannot override native rules")
    equal(wow:Available(), true, "living solo outdoor character can search")
    transport.available = false
    equal(wow:Available(), false, "queue prefix required before joining")
    transport.available = true
    c.FD.Wow.outgoing = {}
    equal(wow:Available(), false, "unrelated outgoing duel request blocks queue join")
    c.FD.Wow.outgoing = nil
    c.FD.Wow.outgoingBlockedUntil = c.now + 50
    equal(wow:Available(), false, "failed native request quarantine blocks queue matching")
    c.FD.Wow.outgoingBlockedUntil = c.now
    equal(wow:Available(), true, "expired native quarantine allows a fresh queue search")
    c.FD.Wow.outgoingBlockedUntil = nil
    c.FD.Wow.pendingIncoming = {}
    equal(wow:Available(), false, "unrelated incoming native duel request blocks queue join")
    c.FD.Wow.pendingIncoming = nil
    c.FD.duel = { active = {} }
    equal(wow:Available(), false, "unrelated active duel blocks queue join")
    c.FD.duel = nil
    local profile = wow:Own()
    equal(profile.continentID, 0, "Eastern Kingdoms world identifier zero remains valid")
    equal(profile.x, 500, "native map conversion")
    equal(profile.rating, 1500, "profile rating from own database")
    equal(profile.positionAt, 1700000010, "position time always local server time")
    equal(c.mapUnits[#c.mapUnits], "player", "never query peer map position")
    c.worldPosition = c.vector(500.6, -500.6)
    equal(wow:Own().x, 501, "world coordinates rounded to canonical packet integer")
    equal(wow:Own().y, -501, "negative world coordinates rounded")
    c.worldPosition = nil
    equal(wow:World(37, -0.1, 0.5), nil, "reject out of range map coordinate")
    c.worldPosition = c.vector(c.secret, 500)
    equal(wow:Position(), nil, "restricted world coordinate has no position")
    equal(wow:Own().mapID, 0, "search profile uses explicit no-position sentinel")
    c.worldPosition = nil
    c.faction = c.secret
    equal(wow:Own(), nil, "restricted faction never compared or serialized")
    c.faction = nil
    c.dead = true; equal(wow:Available(), false, "dead cannot queue"); c.dead = false
    c.outdoors = false; equal(wow:Available(), false, "indoor cannot queue"); c.outdoors = true
    c.instance = true; equal(wow:Available(), false, "instance cannot queue"); c.instance = false
    wow:Save({ scope = "CONTINENT" })
    equal(wow:Available(), true, "continent scope usable without operator verification")
    wow:Save({ scope = "RULESET" })
    equal(wow:Available(), true, "ruleset scope usable without operator verification")
    wow:Save({ scope = "ZONE", ruleset = "invented", levelGap = 99 })
    equal(wow:Settings().ruleset, "NORMAL", "unknown ruleset not saved")
    equal(wow:Settings().levelGap, 5, "invalid gap not saved")
    equal(wow:Invite(c.peer), true, "nil native invitation result means attempted")
    equal(c.invited[1], c.peer.fullName, "invite exact full name")
    c.canInvite = false
    equal(wow:Invite(c.peer), false, "explicit native invitation restriction respected")
    equal(#c.invited, 1, "permission denial does not call native invitation")
    c.canInvite = true
    c.inviteError = true
    equal(wow:Invite(c.peer), false, "protected invitation supplies manual fallback")
    c.inviteError = false
    c.combat = true
    equal(wow:Invite(c.peer), false, "no invitation in combat")
    c.combat = false
    equal(wow:GroupState(c.peer), "SOLO", "readable native solo state is distinct from pending group data")
    c.grouped, c.count = true, 2
    equal(wow:Party(c.peer), true, "exact native group identity")
    equal(wow:GroupState(c.peer), "EXACT", "fully verified native queue pair is exact")
    equal(adapter.groupState(c.peer), "EXACT", "queue environment exposes native group classification")
    equal(wow:Invite(c.peer), false, "no automatic invitation from existing group")
    equal(wow:Leave(c.peer), false, "group ownership required")
    equal(c.left, 0, "unowned group never changed")
    equal(wow:CoLocated(c.peer), true, "same native instance and nearby")
    c.peerX = 111
    equal(wow:CoLocated(c.peer), false, "horizontal distance beyond ten yards")
    c.peerX = nil; c.peerZ = 11
    equal(wow:CoLocated(c.peer), false, "different floor excluded")
    c.peerZ = nil; c.peerInstance = 1
    equal(wow:CoLocated(c.peer), false, "different native instance excluded")
    c.peerInstance = nil; c.visible = false
    equal(wow:CoLocated(c.peer), false, "phase-invisible opponent excluded")
    c.visible = true; c.phase = false
    equal(wow:CoLocated(c.peer), false, "explicit different phase excluded")
    c.phase = true; c.restrictedDistance = true
    equal(wow:CoLocated(c.peer), false, "restricted distance cannot imply ready")
    c.restrictedDistance = false; c.count = 3
    equal(wow:Leave(c.peer, true), false, "third member prevents automated leave")
    c.count = 2; c.partyIdentity = { guid = "Player-1-00000003", fullName = c.peer.fullName }
    equal(wow:Party(c.peer), false, "matching name cannot override mismatched GUID")
    c.partyIdentity = nil
    api.UnitInPhase = nil
    equal(wow:CoLocated(c.peer), false, "missing phase APIs fail closed")
    api.UnitPhaseReason = function() return nil end

    -- Native grouped flags may precede party1 GUID/name/class population.
    -- This must remain distinguishable from a positively changed group.
    local pending = client()
    local native, groupAPI = pending.FD.QueueWow, pending.env
    pending.grouped, pending.count, pending.partyIdentityMissing = true, 2, true
    equal(native:Party(pending.peer), false, "pending party identity cannot supply exact pair proof")
    equal(native:GroupState(pending.peer), "PENDING", "grouped flag without readable party1 is pending")
    groupAPI.UnitGUID = function() return pending.peer.guid end
    equal(native:GroupState(pending.peer), "PENDING", "correct GUID alone cannot authorize full native pair")
    groupAPI.UnitGUID = function() return pending.secret end
    equal(native:GroupState(pending.peer), "PENDING", "restricted GUID cannot identify a changed opponent")
    groupAPI.UnitGUID = function() error("native GUID loading") end
    equal(native:GroupState(pending.peer), "PENDING", "throwing GUID getter is pending verification")
    groupAPI.UnitGUID = function() return "Player-1-00000003" end
    equal(native:GroupState(pending.peer), "CHANGED", "readable wrong GUID identifies a different group")
    groupAPI.UnitGUID = nil
    pending.partyIdentityMissing, pending.partyIdentityError = false, true
    equal(native:GroupState(pending.peer), "PENDING", "throwing full native identity is pending")
    pending.partyIdentityError = false
    pending.partyIdentity = { guid = pending.secret, fullName = pending.peer.fullName }
    equal(native:GroupState(pending.peer), "PENDING", "restricted identity cannot establish a mismatch")
    pending.partyIdentity = { guid = pending.peer.guid, fullName = "Other-Forever" }
    equal(native:GroupState(pending.peer), "CHANGED", "readable native name mismatch identifies a different pair")
    pending.partyIdentity = { guid = "Player-1-00000003", fullName = pending.peer.fullName }
    equal(native:GroupState(pending.peer), "CHANGED", "matching name never overrides wrong GUID")
    pending.partyIdentity = nil
    equal(native:GroupState(pending.peer), "EXACT", "native metadata arriving later verifies original pair")
    pending.count = 1
    equal(native:GroupState(pending.peer), "PENDING", "group count still populating is pending")
    pending.count = 0
    equal(native:GroupState(pending.peer), "PENDING", "grouped flag and zero members are not confirmed solo")
    pending.count = pending.secret
    equal(native:GroupState(pending.peer), "PENDING", "restricted member count cannot identify a changed group")
    pending.count = 3
    equal(native:GroupState(pending.peer), "CHANGED", "readable third member is a changed group")
    pending.count, pending.raid = 2, true
    equal(native:GroupState(pending.peer), "CHANGED", "native raid membership is a changed group")
    pending.raid = pending.secret
    equal(native:GroupState(pending.peer), "PENDING", "restricted raid status cannot authorize group handling")
    pending.raid = false
    groupAPI.GetNumGroupMembers = function() error("native roster loading") end
    equal(native:GroupState(pending.peer), "PENDING", "throwing roster getter remains pending")
    groupAPI.IsInGroup = function() return pending.secret end
    equal(native:GroupState(pending.peer), "PENDING", "restricted grouped status remains pending")
    groupAPI.IsInGroup = nil
    equal(native:GroupState(pending.peer), "PENDING", "missing native grouped getter remains pending")
    equal(pending.left, 0, "group classification never leaves any group")
    equal(#pending.invited, 0, "group classification never sends an invitation")
    equal(wow:CoLocated(c.peer), true, "readable native no-phase-reason confirms compatibility")
    api.UnitPhaseReason = function() return c.secret end
    equal(wow:CoLocated(c.peer), false, "restricted phase reason fails closed")
    api.UnitPhaseReason = function() return 1 end
    equal(wow:CoLocated(c.peer), false, "native phase reason rejects readiness")
    api.UnitPhaseReason = function() return nil end
    api.StartDuel = function(unit) c.duelUnit = unit end
    equal(wow:Challenge(c.peer), true, "manual challenge calls native duel only after identity and phase proof")
    equal(c.duelUnit, "party1", "native duel targets verified group unit")
    c.combat = true
    equal(wow:Challenge(c.peer), false, "manual challenge blocked during combat")
    c.combat = false
    equal(wow:Leave(c.peer, true), true, "owned exact pair can leave")
    equal(c.left, 1, "one native leave attempt")
    c.FD.Presence.players[c.peer.guid].mapID = 999
    equal(#wow:Candidates(), 1, "queue discovery retains fresh peers from other zones")
    c.expired = true
    equal(#wow:Candidates(), 0, "stale presence ignored")
    c.expired = false
    local prior = api.UiMapPoint.CreateFromCoordinates(12, 0.2, 0.3)
    c.waypoint = prior
    c.trackingQuest = 42
    local venue = { mapID = 37, mapX = 0.6, mapY = 0.7 }
    equal(wow:Waypoint(venue), true, "set queue waypoint")
    equal(c.trackingWaypoint, true, "successful queue waypoint becomes tracked")
    wow:ClearWaypoint()
    equal(c.waypoint, prior, "restore prior waypoint after owned queue point")
    equal(c.trackingWaypoint, false, "restore prior waypoint tracking state")
    equal(c.trackingQuest, 42, "restore prior tracked quest")
    wow:Waypoint(venue)
    local changed = api.UiMapPoint.CreateFromCoordinates(38, 0.3, 0.4)
    c.waypoint = changed
    wow:ClearWaypoint()
    equal(c.waypoint, changed, "preserve user waypoint changed during queue")
    wow:Waypoint(venue)
    wow:ClearWaypoint()
    equal(c.waypoint, changed, "explicit new queue waypoint preserves user's most recent point")
    c.counter = 9007199254740000
    local nonce = wow:Nonce()
    equal(#nonce <= 32, true, "compact nonce remains within protocol budget")

    equal(c.prefix, "ForeverDuelQ1", "independent queue prefix")
    equal(transport:Send({ kind = "QUERY" }, "Unknown-Forever"), false, "cannot probe unknown players")
    equal(transport:Send({ kind = "QUERY" }, c.peer.fullName), true, "known-addon discovery query")
    equal(#c.sent, 0, "transport paced before sending")
    c.now = 10.2; transport:Tick()
    equal(#c.sent, 1, "paced whisper sent")
    equal(c.sent[1].channel, "WHISPER", "dedicated native whisper transport")
    local profilePacket = { kind = "PROFILE", session = "a1", guid = c.own.guid, rating = 1500,
        level = 30, maxLevel = 60, scope = "ZONE", levelGap = 5, ruleset = "NORMAL", faction = "Alliance",
        joinedAt = 1700000000, mapID = 37, continentID = 0, x = 500, y = 500 }
    equal(transport:Send(profilePacket, c.peer.fullName), true, "current profile queued")
    c.FD.queue.session = "a2"
    c.now = 10.5; transport:Tick()
    equal(#c.sent, 1, "obsolete session dropped before transmission")
    c.FD.queue.session = "a1"
    equal(transport:Send({ kind = "QUERY" }, c.peer.fullName), true)
    c.now = 21; transport:Tick()
    equal(#c.sent, 1, "expired packet dropped")
    local query = assert(c.FD.QueueProtocol:Encode({ kind = "QUERY" }))
    equal(transport:Receive("ForeverDuelQ1", query, "WHISPER", "Beta"), true, "local sender normalized")
    equal(c.received[1].sender, c.peer.fullName, "sender matches known presence identity")
    equal(transport:Receive("ForeverDuelQ1", query, "WHISPER", "Unknown"), false, "unknown query rejected")
    equal(transport:Receive("ForeverDuelQ1", query, "YELL", "Beta"), false, "queue ignores public channel packet")
    equal(transport:Receive("ForeverDuelQ1", query, "WHISPER", c.secret), false, "restricted sender ignored")
    profilePacket.guid, profilePacket.session = c.own.guid, "b1"
    local spoof = assert(c.FD.QueueProtocol:Encode(profilePacket))
    equal(transport:Receive("ForeverDuelQ1", spoof, "WHISPER", "Beta"), false, "transport GUID bound to presence sender")
    c.receiveError = true
    equal(transport:Receive("ForeverDuelQ1", query, "WHISPER", "Beta"), false, "queue receive failure contained")
    c.receiveError = false
    c.FD.queue.ticket = { id = "a1.b1", ownSession = "a1", peerSession = "b1", peer = c.peer }
    local control = { kind = "ACK", session = "a1", peerSession = "b1", ticket = "a1.b1" }
    equal(transport:Send(control, c.peer.fullName), true, "reserved-ticket packet queued")
    c.FD.queue.ticket.id = "a2.b1"
    c.now = 21.3; transport:Tick()
    equal(#c.sent, 1, "stale ticket dropped")
    c.FD.queue.ticket.id = "a1.b1"
    c.expired = true
    equal(transport:Send({ kind = "QUERY" }, c.peer.fullName), false, "query excludes expired presence even with ticket")
    equal(transport:Send(control, c.peer.fullName), true, "active ticket can keep using confirmed peer")
    c.now = 21.6; transport:Tick()
    equal(#c.sent, 2, "active ticket control survives presence expiry")
    c.expired = false
    for i = 1, 64 do equal(transport:Send({ kind = "QUERY" }, c.peer.fullName), true, "bounded queue item " .. i) end
    equal(transport:Send({ kind = "QUERY" }, c.peer.fullName), false, "transport queue bounded at64")
    local regional = client({ regionalNames = true })
    equal(regional.FD.QueueTransport:Receive("ForeverDuelQ1", query, "WHISPER", "Beta Brave"), true,
        "Forever surname helper transport name retained exactly")
    equal(regional.received[1].sender, "Beta Brave", "surname never suffixed with realm")
    local missing = client()
    missing.env.C_Map = nil
    equal(missing.FD.QueueWow:Position(), nil, "absent map APIs degrade safely")
    missing.env.IsInGroup = nil
    equal(missing.FD.QueueWow:Available(), false, "missing group API never assumes solo")
    missing.registerResult = 2
    equal(missing.FD.QueueTransport:Initialize(), false, "prefix registration enum failure")
    missing.registerResult = 1
    equal(missing.FD.QueueTransport:Initialize(), true, "duplicate queue prefix accepted")
    equal(type(adapter.catalog), "function", "catalog supplied dynamically after operator approval")

    -- Ordinary native duels certify a local venue independently of rated
    -- consent, rating records or an active queue. A whisper alone is no proof.
    local function testedClient(ownLevel, peerLevel)
        local tested = client()
        tested.FD.queue.state = "IDLE"
        tested.own.level, tested.peer.level = ownLevel or 30, peerLevel or 30
        return tested
    end
    local function requestTest(tested)
        tested.FD.QueueWow:ObserveDuel("request", { player = tested.own, opponent = tested.peer })
    end
    local function completeTest(tested, options)
        options = options or {}
        local native = tested.FD.QueueWow
        requestTest(tested)
        if not options.noCountdown then native:ObserveDuel("countdown", 3) end
        tested.now = tested.now + 4
        if options.abort then native:ObserveDuel("abort", "duel ended without rated start") end
        local outcome = options.retreat and "Beta has fled from Alpha in a duel" or "Alpha has defeated Beta in a duel"
        if not options.noResult then native:ObserveDuel("result", outcome) end
        if not options.noFinish then native:ObserveDuel("finished") end
    end
    local function venuePacket(tested, venue)
        local scale = tested.FD.QueueProtocol.MAP_SCALE
        return { kind = "VENUE", venueID = venue.id, testPairGUID = tested.own.guid,
            mapID = venue.mapID, continentID = venue.continentID,
            mapX = math.floor(venue.mapX * scale + 0.5), mapY = math.floor(venue.mapY * scale + 0.5),
            minPlayerLevel = venue.minPlayerLevel, zoneMinLevel = venue.zoneMinLevel, zoneMaxLevel = venue.zoneMaxLevel,
            faction = tested.faction or "Alliance", hubFaction = "NONE", testedAt = venue.testedAt }
    end

    local tested = testedClient(25, 20)
    local native = tested.FD.QueueWow
    equal(#native:Catalog(), 0, "automatic venue catalog starts empty")
    equal(native:CaptureVenue(), nil, "button cannot approve an untested place")
    completeTest(tested, { abort = true })
    equal(native:CaptureStatus(), true, "ordinary Core abort after native countdown preserves success evidence")
    local captured, opponent = native:CaptureVenue()
    equal(type(captured), "table", "successful native ordinary duel enables automatic capture")
    equal(opponent.guid, tested.peer.guid, "capture targets the natively observed opponent")
    equal(captured.name, "Elwynn Forest", "native map name fills venue label")
    equal(captured.minPlayerLevel, 20, "minimum level is lower of both native test levels")
    equal(captured.zoneMinLevel, 1, "native zone minimum captured")
    equal(captured.zoneMaxLevel, 10, "native zone maximum captured")
    equal(captured.hubFaction, nil, "ordinary test does not certify a capital hub")
    equal(captured.factions.Alliance, true, "capture certifies only native faction")
    equal(captured.factions.Horde, nil, "capture never approves opposite faction")
    equal(native:StoreVenue(captured), true, "tested place stored")
    equal(#native:Catalog(), 1, "stored verified place available to matching")
    equal(native:StoreVenue(captured), true, "same stable place can replace saved metadata")
    equal(#native:Catalog(), 1, "stable venue ID prevents duplicates")
    local packet = venuePacket(tested, captured)
    equal(native:AcceptVenue(packet, tested.peer.fullName), true, "same native proof accepts peer's normalized place")
    tested.FD.ReceiveQueueVenue = function(_, venue, sender) return native:AcceptVenue(venue, sender) end
    local testTransport = tested.FD.QueueTransport
    local incomingVenue = assert(tested.FD.QueueProtocol:Encode(packet))
    equal(testTransport:Receive("ForeverDuelQ1", incomingVenue, "WHISPER", "Beta"), true,
        "standalone tested place routes through native proof importer")
    equal(#tested.received, 0, "venue sync never enters queue or rated packet handler")
    equal(testTransport.lastReceive, "VENUE from Beta-Forever", "standalone venue diagnosed separately")
    local outgoingVenue = tested.FD.Copy(packet)
    outgoingVenue.testPairGUID = tested.peer.guid
    equal(testTransport:Send(outgoingVenue, tested.peer.fullName), true, "native test peer can receive standalone share")
    tested.now = tested.now + 0.3; testTransport:Tick()
    equal(#tested.sent, 1, "standalone venue paced and submitted")
    tested.FD.Presence.players["Player-1-00000003"] = { guid = "Player-1-00000003", fullName = "Gamma-Forever" }
    equal(testTransport:Send(outgoingVenue, "Gamma-Forever"), false, "known addon player cannot receive another pair's proof")
    tested.expired = true
    equal(testTransport:Receive("ForeverDuelQ1", incomingVenue, "WHISPER", "Beta"), true,
        "ordinary native proof can receive share without a fresh addon presence profile")
    tested.expired = false
    local venueHandler = tested.FD.ReceiveQueueVenue
    tested.FD.ReceiveQueueVenue = function() error("isolated import failure") end
    equal(testTransport:Receive("ForeverDuelQ1", incomingVenue, "WHISPER", "Beta"), false,
        "venue import error cannot call rated recovery")
    tested.FD.ReceiveQueueVenue = venueHandler
    packet.minPlayerLevel = 25
    equal(native:AcceptVenue(packet, tested.peer.fullName), false, "source-only level cannot exclude lower tested opponent")
    packet.minPlayerLevel = 20
    packet.hubFaction = "Alliance"
    equal(native:AcceptVenue(packet, tested.peer.fullName), false, "peer cannot certify a capital exterior")
    packet.hubFaction = "NONE"
    equal(native:AcceptVenue(packet, "Unknown-Forever"), false, "share requires exact native test sender")
    packet.testPairGUID = tested.peer.guid
    equal(native:AcceptVenue(packet, tested.peer.fullName), false, "share bound to recipient native GUID")
    packet.testPairGUID = tested.own.guid
    packet.testedAt = packet.testedAt + 10
    equal(native:AcceptVenue(packet, tested.peer.fullName), false, "future test timestamp rejected")
    packet.testedAt = captured.testedAt
    packet.zoneMaxLevel = 11
    equal(native:AcceptVenue(packet, tested.peer.fullName), false, "transmitted zone level range checked natively")
    packet.zoneMaxLevel = 10
    packet.mapX = packet.mapX + 5000000
    equal(native:AcceptVenue(packet, tested.peer.fullName), false, "peer location outside tested40yard radius rejected")
    packet = venuePacket(tested, captured)
    tested.env.C_Map.GetMapLevels = nil
    local fallbackCapture = native:CaptureVenue()
    equal(fallbackCapture.zoneMinLevel, 1, "known Classic zone minimum available without native map levels")
    equal(fallbackCapture.zoneMaxLevel, 12, "frozen Classic author range used without a manual form")
    equal(fallbackCapture.metadataSource, "CLASSIC", "metadata fallback explicitly distinguished from native API")
    tested.env.C_Map.GetMapLevels = function() return 1, 10 end
    tested.mapPosition = tested.vector(0.52, 0.5)
    local unchanged = native:CaptureVenue()
    equal(unchanged.mapX, 0.5, "capture keeps exact native finish spot after a small step away")
    tested.mapPosition = tested.vector(0.55, 0.5)
    equal(native:CaptureVenue(), nil, "moving beyond40yards invalidates button capture")
    tested.mapPosition = nil
    tested.grouped = true
    equal(native:CaptureVenue(), nil, "test party must be left before capture")
    tested.grouped = false; tested.combat = true
    equal(native:CaptureVenue(), nil, "capture waits until combat ends")
    tested.combat = false
    tested.FD.queue.state = "SEARCHING"
    equal(native:CaptureVenue(), nil, "active queue prevents capture")
    equal(native:AcceptVenue(packet, tested.peer.fullName), true, "unreserved searching client accepts its tested partner's place")
    tested.FD.queue.state = "PAUSED"
    equal(native:AcceptVenue(packet, tested.peer.fullName), true, "unreserved paused search accepts its tested partner's place")
    tested.FD.queue.ticket = {}
    equal(native:AcceptVenue(packet, tested.peer.fullName), false, "reservation prevents asynchronous venue import")
    tested.FD.queue.ticket = nil
    tested.FD.queue.state = "IDLE"
    tested.territory = "hostile"
    equal(native:CaptureVenue(), nil, "changed hostile territory blocks capture after valid duel")
    equal(native:AcceptVenue(packet, tested.peer.fullName), false, "native hostile territory blocks peer approval")
    tested.territory = "friendly"
    equal(testTransport:Send(outgoingVenue, tested.peer.fullName), true, "share queued before world transition")
    native:ObserveDuel("world")
    equal(native.venueTest, nil, "world transition clears successful test proof")
    equal(native:AcceptVenue(packet, tested.peer.fullName), false, "saved peer packet cannot restore proof after world transition")
    tested.now = tested.now + 0.3; testTransport:Tick()
    equal(#tested.sent, 1, "world transition cancels a queued stale venue share")

    local reversed = testedClient(20, 25)
    completeTest(reversed)
    local lowerCapture = reversed.FD.QueueWow:CaptureVenue()
    equal(lowerCapture.minPlayerLevel, 20, "both client level orderings capture identical tested minimum")
    reversed.now = reversed.now + 301
    equal(reversed.FD.QueueWow:CaptureVenue(), nil, "five minute proof expires")
    for _, option in ipairs({ { noCountdown = true }, { noResult = true }, { noFinish = true }, { retreat = true } }) do
        local unproved = testedClient()
        completeTest(unproved, option)
        equal(unproved.FD.QueueWow:CaptureVenue(), nil, "countdown knockout and native finish all required")
    end
    local canceled = testedClient()
    requestTest(canceled)
    canceled.FD.QueueWow:ObserveDuel("abort")
    equal(canceled.FD.QueueWow.venueTestPending, nil, "native request canceled before countdown cannot certify a place")
    local mismatched = testedClient()
    mismatched.partyIdentity = { guid = "Player-1-00000003", fullName = mismatched.peer.fullName, level = 30 }
    requestTest(mismatched)
    equal(mismatched.FD.QueueWow.venueTestPending, nil, "same name with wrong native GUID cannot become test proof")

    local territory = testedClient()
    for _, bad in ipairs({ "hostile", "sanctuary", "arena", "combat", "unknown" }) do
        territory.territory = bad
        equal(territory.FD.QueueWow:FriendlyTerritory(), false, "territory exclusion " .. bad)
        completeTest(territory)
        equal(territory.FD.QueueWow.venueTest, nil, "unapproved native territory cannot produce successful proof")
    end
    territory.faction, territory.territory = "Horde", "hostile"
    completeTest(territory)
    equal(territory.FD.QueueWow:CaptureVenue(), nil, "two Horde in native-hostile Elwynn cannot approve Horde venue")
    territory.territory = "contested"
    territory.mapID = 999999
    equal(territory.FD.QueueWow:FriendlyTerritory(), true, "contested territory usable with successful test")
    territory.territory = nil
    equal(territory.FD.QueueWow:FriendlyTerritory(), true, "native neutral territory nil with readable boolean usable")
    territory.territoryMissing = true
    equal(territory.FD.QueueWow:FriendlyTerritory(), false, "native MayReturnNothing is unavailable")
    territory.territoryMissing = false; territory.territory = territory.secret
    equal(territory.FD.QueueWow:FriendlyTerritory(), false, "restricted territory cannot authorize capture")
    territory.territoryError = true
    equal(territory.FD.QueueWow:FriendlyTerritory(), false, "native territory errors stay isolated")
    territory.territoryError = false; territory.territory = "friendly"
    territory.env.GetZonePVPInfo = territory.env.C_PvP.GetZonePVPInfo
    territory.env.C_PvP = nil
    equal(territory.FD.QueueWow:FriendlyTerritory(), true, "legacy native territory getter supported")

    -- Forever may expose the documented getters but supply no territory or
    -- map-level data. Only a proven Classic native map identity can recover.
    local missingMetadata = testedClient(25, 20)
    missingMetadata.mapID, missingMetadata.territoryMissing = 1429, true
    missingMetadata.env.C_Map.GetMapLevels = function() return end
    completeTest(missingMetadata)
    local recovered = missingMetadata.FD.QueueWow:CaptureVenue()
    equal(type(recovered), "table", "native test proof survives missing territory/map-level getters in Classic Elwynn")
    equal(recovered.mapID, 1429, "fallback does not invent or translate the recorded native map")
    equal(recovered.zoneMaxLevel, 12, "captured place uses frozen Classic author zone range")
    equal(recovered.metadataSource, "CLASSIC", "capture records local metadata provenance")
    equal(recovered.minPlayerLevel, 20, "fallback cannot replace the natively observed tested player minimum")
    equal(#missingMetadata.FD.Venues.Catalog, 0, "metadata recovery does not ship a place catalog")
    local recoveredPacket = venuePacket(missingMetadata, recovered)
    equal(missingMetadata.FD.QueueWow:AcceptVenue(recoveredPacket, missingMetadata.peer.fullName), true,
        "peer import uses the same native-preferred metadata fallback")
    equal(missingMetadata.FD.QueueWow:Catalog()[1].metadataSource, "CLASSIC", "receiver derives provenance locally")
    recoveredPacket.zoneMaxLevel = 10
    equal(missingMetadata.FD.QueueWow:AcceptVenue(recoveredPacket, missingMetadata.peer.fullName), false,
        "peer cannot replace fallback zone metadata")
    local diagnostic = missingMetadata.FD.QueueWow:MetadataDiagnostics()
    equal(diagnostic.mapID, 1429, "diagnostic includes current map")
    equal(diagnostic.faction, "Alliance", "diagnostic includes native faction")
    equal(diagnostic.territorySource, "CLASSIC", "territory fallback diagnosed separately")
    equal(diagnostic.zoneLevelsSource, "CLASSIC", "level-range fallback diagnosed separately")

    local mapFallback = client()
    local mapNative = mapFallback.FD.QueueWow
    mapFallback.territoryMissing = true
    mapFallback.env.C_Map.GetMapLevels = nil
    for _, zone in ipairs({ { 1429, "Alliance" }, { 37, "Alliance" }, { 1426, "Alliance" }, { 27, "Alliance" },
        { 1438, "Alliance" }, { 57, "Alliance" }, { 1411, "Horde" }, { 1, "Horde" },
        { 1412, "Horde" }, { 7, "Horde" }, { 1420, "Horde" }, { 18, "Horde" } }) do
        mapFallback.mapID, mapFallback.faction = zone[1], zone[2]
        equal(mapNative:FriendlyTerritory(), true, "native zone identity permits own Classic starting territory " .. zone[1])
        local low, high, source = mapNative:ZoneLevels(zone[1])
        equal(low, 1, "bounded metadata low " .. zone[1])
        equal(high, 12, "bounded metadata high " .. zone[1])
        equal(source, "CLASSIC", "bounded metadata source " .. zone[1])
        mapFallback.faction = zone[2] == "Alliance" and "Horde" or "Alliance"
        equal(mapNative:FriendlyTerritory(), false, "opposite faction cannot approve starting territory " .. zone[1])
    end
    mapFallback.mapID, mapFallback.faction = 1429, "Horde"
    mapFallback.territoryMissing, mapFallback.territory = false, "friendly"
    equal(mapNative:FriendlyTerritory(), false, "known Elwynn ownership prevents opposite-faction approval even with inconsistent getter")
    mapFallback.faction, mapFallback.territoryMissing = "Alliance", true
    mapFallback.mapID = 99999
    equal(mapNative:FriendlyTerritory(), false, "unknown zone is never neutral merely because getters return nothing")
    equal(mapNative:ZoneLevels(99999), nil, "unknown zone receives no invented range")
    mapFallback.mapID = 1429
    mapFallback.own.maxLevel = 70
    equal(mapNative:FriendlyTerritory(), false, "Classic metadata not used for another native level cap")
    mapFallback.own.maxLevel = mapFallback.secret
    equal(mapNative:FriendlyTerritory(), false, "secret level cap cannot establish Classic world")
    mapFallback.own.maxLevel = 60
    for _, info in ipairs({ { mapID = 37, mapType = 3, parentMapID = 1415 },
        { mapID = 1429, mapType = 3, parentMapID = 13 }, { mapID = 1429, mapType = 2, parentMapID = 1415 },
        { mapID = 1429, mapType = 3, parentMapID = mapFallback.secret } }) do
        mapFallback.mapInfo = { [1429] = info }
        equal(mapNative:FriendlyTerritory(), false, "mismatched/restricted native map details cannot select fallback")
        equal(mapNative:ZoneLevels(1429), nil, "mismatched native map cannot borrow range")
    end
    mapFallback.mapID = 99998
    mapFallback.mapInfo = { [99998] = { mapID = 99998, mapType = 5, parentMapID = 1429 },
        [1429] = { mapID = 1429, mapType = 3, parentMapID = 1415 } }
    equal(mapNative:FriendlyTerritory(), true, "native micro-map may inherit its validated Classic parent")
    equal(select(2, mapNative:ZoneLevels(99998)), 12, "validated micro-map inherits parent range")
    mapFallback.mapInfo[99998].mapType = 3
    equal(mapNative:FriendlyTerritory(), false, "unknown native zone cannot escape into a friendly parent zone")
    mapFallback.mapInfo[99998].mapType, mapFallback.mapInfo[99998].parentMapID = 5, 99998
    equal(mapNative:FriendlyTerritory(), false, "cyclic native parent chain ends safely")
    mapFallback.mapID, mapFallback.mapInfo = 1429, nil
    mapFallback.env.C_Map.GetMapLevels = function() return 2, 11 end
    local low, high, source = mapNative:ZoneLevels(1429)
    equal(low, 2, "complete native minimum takes precedence over fallback")
    equal(high, 11, "complete native maximum takes precedence over fallback")
    equal(source, "NATIVE", "native source accurately diagnosed")
    mapFallback.env.C_Map.GetMapLevels = function() return 0, 0 end
    equal(select(2, mapNative:ZoneLevels(1429)), 12, "empty zero native range can use known Classic metadata")
    for _, getter in ipairs({ function() error("restricted native call") end,
        function() return mapFallback.secret, 10 end, function() return 0, 10 end }) do
        mapFallback.env.C_Map.GetMapLevels = getter
        equal(mapNative:ZoneLevels(1429), nil, "errors/restricted/partial invalid ranges never silently fall back")
    end
    mapFallback.territoryMissing, mapFallback.territory = false, mapFallback.secret
    equal(mapNative:FriendlyTerritory(), false, "secret native territory never authorizes known-map fallback")
    mapFallback.territoryError = true
    mapFallback.env.GetZonePVPInfo = function() return "friendly", false end
    equal(mapNative:FriendlyTerritory(), false, "native territory exception cannot be bypassed by alternate getter")
    mapFallback.territoryError, mapFallback.territoryMissing, mapFallback.mapID = false, true, 99999
    equal(mapNative:FriendlyTerritory(), true, "readable legacy native territory recovers unavailable modern getter")

    local discovery = client()
    local scans = 0
    discovery.FD.Presence.Changed = function() error("directory offline") end
    discovery.FD.Presence.ScanNearby = function() scans = scans + 1 end
    equal(discovery.FD.QueueWow:Discover(), true, "optional discovery failure isolated")
    equal(scans, 1, "nearby scan still executes after directory failure")
end
