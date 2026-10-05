return function(_, equal)
    local function client(options)
        options = options or {}
        local state = { now = 10, timers = {}, sent = {}, received = {}, invited = {}, left = 0,
            grouped = false, raid = false, count = 0, dead = false, instance = false,
            outdoors = true, combat = false, visible = true, connected = true,
            registerResult = 0, sendResult = 0, worldCalls = 0, mapUnits = {}, territory = "friendly",
            sounds = {}, prints = {}, shown = 0, accepted = 0, popupHidden = 0, requests = {} }
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
        env.UnitGUID = function(unit)
            if unit == "party1" then
                if state.partyGUIDError then error("native GUID loading") end
                if state.grouped and state.count >= 2 then return state.partyGUID or "Player-1-00000002" end
            end
        end
        env.UnitIsDeadOrGhost = function() return state.dead end
        env.IsInInstance = function() return state.instance end
        env.IsOutdoors = function() return state.outdoors end
        env.InCombatLockdown = function() return state.combat end
        env.UnitIsVisible = function() return state.visible end
        env.UnitIsConnected = function() return state.connected end
        env.UnitPhaseReason = function() return state.phaseReason end
        env.UnitPosition = function(unit)
            if state.restrictedDistance then return state.secret end
            if unit == "player" then return 100, 100, 5, 0 end
            return state.peerX or 103, state.peerY or 104, state.peerZ or 5, state.peerInstance or 0
        end
        env.C_PartyInfo = {
            CanInvite = function() return state.canInvite ~= false end,
            InviteUnit = function(name) state.invited[#state.invited + 1] = name; if state.inviteError then error("protected") end end,
            LeaveParty = function() state.left = state.left + 1 end,
            IsGUIDInGroup = function(guid) return state.inGroup and guid == state.inGroup end,
        }
        env.AcceptGroup = function() state.accepted = state.accepted + 1 end
        state.popup = { which = "PARTY_INVITE" }
        env.StaticPopup_FindVisible = function(which) if which == "PARTY_INVITE" and state.popupShown then return state.popup end end
        env.StaticPopup_Hide = function(which)
            if which == "PARTY_INVITE" and state.popupShown then
                state.popupShown, state.popupHidden = false, state.popupHidden + 1
                if not state.popup.inviteAccepted then state.declinedByHide = true end
            end
        end
        env.ERR_DECLINE_GROUP_S = "%s declines your group invitation."
        env.ERR_ALREADY_IN_GROUP_S = "%s is already in a group."
        env.ERR_BAD_PLAYER_NAME_S = "Cannot find player '%s'."
        env.SOUNDKIT = { PVP_THROUGH_QUEUE = 8459, READY_CHECK = 8960, MAP_PING = 3175, IG_QUEST_CANCEL = 879 }
        env.PlaySound = function(id) state.sounds[#state.sounds + 1] = id end
        env.GetNormalizedRealmName = function() return "Forever" end
        env.RegionalUniqueNamesEnabled = function() return options.regionalNames or false end
        env.Enum = {
            GameRule = { HardcoreRuleset = 101, RPRuleset = 102, PvPRuleset = 103 },
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
            SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, InvalidChatType = 4, NotInGroup = 5 },
        }
        env.C_GameRules = { IsGameRuleActive = function(rule)
            if state.ruleError then error("native rules unavailable") end
            if state.activeRules and state.activeRules[rule] ~= nil then return state.activeRules[rule] end
            return false
        end }
        env.C_ChatInfo = {
            RegisterAddonMessagePrefix = function(prefix) state.prefix = prefix; return state.registerResult end,
            SendAddonMessage = function(prefix, payload, channel, target)
                local result = channel == "PARTY" and state.partyResult or state.sendResult
                state.sent[#state.sent + 1] = { prefix = prefix, payload = payload, channel = channel, target = target, result = result }
                return result
            end,
        }
        env.C_Timer = { After = function(delay, callback)
            state.timers[#state.timers + 1] = { at = state.now + delay, callback = callback }
        end }
        function state:advance(seconds)
            local finish, guard = self.now + seconds, 0
            while true do
                local index, at
                for i, timer in ipairs(self.timers) do
                    if timer.at <= finish and (not at or timer.at < at) then index, at = i, timer.at end
                end
                if not index then break end
                guard = guard + 1; assert(guard < 5000, "adapter timer runaway")
                local timer = table.remove(self.timers, index)
                self.now = math.max(self.now, at)
                timer.callback()
            end
            self.now = finish
        end
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
            RequestDuel = function(_, unit) state.requests[#state.requests + 1] = unit; return true end,
        }
        FD.Debug = { Log = function() end, Print = function(_, text) state.prints[#state.prints + 1] = text end }
        FD.Safe = function() error("queue must not route through rated error recovery") end
        FD.QueueUI = { Show = function() state.shown = state.shown + 1 end, RefreshIfShown = function() end }
        FD.Database = {
            data = { settings = { queue = { ruleset = "NORMAL" } } },
            GetStats = function() return { rating = 1500 } end,
            NextCounter = function() state.counter = (state.counter or 0) + 1; return state.counter end,
            Copy = function(_, value) return FD.Copy(value) end,
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
        FD.queue = { session = "a1", state = "SEARCHING", peers = {}, Receive = function(_, packet, sender)
            if state.receiveError then error("isolated queue failure") end
            state.received[#state.received + 1] = { packet = packet, sender = sender }
        end, Run = function(_, callback)
            local ok, result = pcall(callback)
            if ok then return result end
            state.queueErrors = (state.queueErrors or 0) + 1
            return false
        end }
        env.DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
        env.DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel"
        for _, name in ipairs({ "Constants", "Locale", "Protocol", "Rating", "Results", "Outbound",
            "QueueProtocol", "Venues", "Queue", "QueueWow", "QueueTransport" }) do load(name) end
        FD.QueueTransport:Initialize()
        state.env, state.FD, state.own, state.peer, state.vector = env, FD, own, peer, vector
        return state
    end

    local c = client()
    local wow, transport, api = c.FD.QueueWow, c.FD.QueueTransport, c.env
    local adapter = wow:Environment()
    equal(wow:Settings().scope, "ZONE", "default local discovery")
    equal(wow:Settings().levelGap, 5, "default level gap")
    equal(wow:Settings().autoAcceptQueueInvite, false, "auto-accept is opt-in")
    wow:Save({ autoAcceptQueueInvite = true })
    equal(wow:Settings().autoAcceptQueueInvite, true, "auto-accept preference saved")
    wow:Save({ autoAcceptQueueInvite = "yes" })
    equal(wow:Settings().autoAcceptQueueInvite, true, "non-boolean auto-accept ignored")
    wow:Save({ autoAcceptQueueInvite = false })
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
    equal(wow:Available(), false, "unrelated outgoing duel request pauses the queue")
    c.FD.Wow.outgoing = nil
    c.FD.Wow.outgoingBlockedUntil = c.now + 50
    equal(wow:Available(), false, "failed native request quarantine blocks queue matching")
    c.FD.Wow.outgoingBlockedUntil = nil
    c.FD.duel = { active = {} }
    equal(wow:Available(), false, "unrelated active duel pauses the queue")
    c.FD.duel = nil
    local profile = wow:Own()
    equal(profile.continentID, 0, "Eastern Kingdoms world identifier zero remains valid")
    equal(profile.x, 500, "native map conversion")
    equal(profile.rating, 1500, "profile rating from own database")
    equal(c.mapUnits[#c.mapUnits], "player", "never query peer map position")
    c.worldPosition = c.vector(500.6, -500.6)
    equal(wow:Own().x, 501, "world coordinates rounded to canonical packet integer")
    c.worldPosition = c.vector(c.secret, 500)
    equal(wow:Position(), nil, "restricted world coordinate has no position")
    equal(wow:Own().mapID, 0, "search profile uses explicit no-position sentinel")
    c.worldPosition = nil
    c.faction = c.secret
    equal(wow:Own(), nil, "restricted faction never compared or serialized")
    c.faction = nil
    c.dead = true; equal(wow:Available(), false, "dead cannot queue"); c.dead = false
    c.outdoors = false; equal(wow:Available(), false, "indoor cannot queue"); c.outdoors = true

    -- Invitation, auto-accept and decline.
    equal(wow:Invite(c.peer), true, "nil native invitation result means attempted")
    equal(c.invited[1], c.peer.fullName, "invite exact whisper name")
    equal(wow.invitedPeer.guid, c.peer.guid, "own invitation remembered for rescinding")
    c.canInvite = false
    equal(wow:Invite(c.peer), false, "explicit native invitation restriction respected")
    c.canInvite = true
    c.inviteError = true
    equal(wow:Invite(c.peer), false, "protected invitation reports failure")
    c.inviteError = false
    equal(wow:InviteRequested("Creature-1-AA"), nil, "only player GUIDs are invitation sources")
    equal(wow:InviteRequested(c.secret), nil, "restricted inviter GUID ignored")
    equal(wow:InviteRequested(c.peer.guid), c.peer.guid, "PARTY_INVITE_REQUEST inviterGUID recorded")
    c.popupShown = true
    equal(wow:AcceptInvite({ guid = "Player-1-00000003" }), true, "auto-accept is deferred to the next frame")
    c:advance(0.1)
    equal(c.accepted, 0, "a different inviter is never accepted")
    wow:AcceptInvite(c.peer)
    equal(c.accepted, 0, "acceptance waits for Blizzard's dialog")
    c:advance(0.1)
    equal(c.accepted, 1, "matched inviter accepted through AcceptGroup")
    equal(c.popup.inviteAccepted, 1, "dialog marked accepted before hiding")
    equal(c.popupShown, false, "dialog closed")
    equal(c.declinedByHide, nil, "closing the accepted dialog cannot decline")
    c:advance(0.1); wow:AcceptInvite(c.peer); c:advance(0.1)
    equal(c.accepted, 1, "one recorded invitation is accepted once")
    wow:InviteRequested(c.peer.guid)
    c.popupShown, c.popup.inviteAccepted = true, nil
    equal(wow:DeclineInvite({ guid = "Player-1-00000003" }), false, "only the matched inviter's invitation is declined")
    equal(c.popupShown, true, "other invitation dialogs untouched")
    equal(wow:DeclineInvite(c.peer), true, "void queue invitation declined")
    equal(c.declinedByHide, true, "hiding Blizzard's dialog declines through its own handler")
    equal(wow:InviteNotice("Beta declines your group invitation.", c.peer), "DECLINED", "decline system message")
    equal(wow:InviteNotice("Beta-Forever declines your group invitation.", c.peer), "DECLINED", "full-name decline")
    equal(wow:InviteNotice("Beta is already in a group.", c.peer), "INVITE_FAILED", "grouped target")
    equal(wow:InviteNotice("Cannot find player 'Beta-Forever'.", c.peer), "INVITE_FAILED", "unknown target")
    equal(wow:InviteNotice("Gamma declines your group invitation.", c.peer), nil, "other player's decline ignored")
    equal(wow:InviteNotice(c.secret, c.peer), nil, "restricted system message ignored")
    local regionalPeer = { guid = c.peer.guid, fullName = "Beta Brave" }
    equal(wow:InviteNotice("Beta declines your group invitation.", regionalPeer), "DECLINED", "surname first name matched")

    -- Native invitation liveness: a declined, rescinded or expired
    -- invitation is never announced or accepted late.
    wow:InviteRequested(c.peer.guid)
    c.popupShown, c.popup.inviteAccepted = true, nil
    equal(wow:InviteOpen(c.peer.guid), "open", "a visible dialog keeps the invitation open")
    equal(wow:InviteOpen("Player-1-00000003"), false, "another inviter has no open invitation")
    c.popupShown = false
    equal(wow:InviteOpen(c.peer.guid), false, "a closed dialog voids the invitation")
    local acceptedBefore = c.accepted
    wow:AcceptInvite(c.peer); c:advance(0.1)
    equal(c.accepted, acceptedBefore, "auto-accept never answers a closed dialog")
    equal(adapter.inviteOpen(c.peer.guid), false, "queue environment exposes invitation liveness")
    equal(wow:InviteClosed(true), c.peer.guid, "the AcceptGroup hook marks the invitation accepted")
    equal(wow:InviteOpen(c.peer.guid), "accepted", "an accepted invitation stays bindable")
    equal(wow:DeclineInvite(c.peer), false, "an accepted invitation is never declined")
    wow:InviteRequested(c.peer.guid)
    equal(wow:InviteClosed(false), c.peer.guid, "DeclineGroup and PARTY_INVITE_CANCEL name the closed inviter")
    equal(wow:InviteOpen(c.peer.guid), false, "a declined invitation is forgotten")
    equal(wow:InviteClosed(false), nil, "nothing is pending afterwards")

    -- GUID-based group classification: names never decide.
    equal(wow:GroupState(c.peer), "SOLO", "readable native solo state")
    c.grouped, c.count = true, 2
    equal(wow:GroupState(c.peer), "EXACT", "party1 GUID proves the queue pair")
    equal(adapter.groupState(c.peer), "EXACT", "queue environment exposes native classification")
    c.partyIdentity = { guid = c.peer.guid, fullName = "Unknown" }
    equal(wow:GroupState(c.peer), "EXACT", "a loading or different name for the same GUID is not a changed group")
    c.partyIdentity = nil
    c.partyGUID = "Player-1-00000003"
    equal(wow:GroupState(c.peer), "CHANGED", "readable different GUID is a changed group")
    c.partyGUID = c.secret
    equal(wow:GroupState(c.peer), "PENDING", "restricted GUID is pending")
    c.inGroup = c.peer.guid
    equal(wow:GroupState(c.peer), "EXACT", "IsGUIDInGroup proves membership when party1 is restricted")
    c.inGroup, c.partyGUID = nil, nil
    c.partyGUIDError = true
    equal(wow:GroupState(c.peer), "PENDING", "throwing GUID getter is pending")
    c.partyGUIDError = false
    for _, case in ipairs({ { 1, "PENDING" }, { 0, "PENDING" }, { 3, "CHANGED" } }) do
        c.count = case[1]
        equal(wow:GroupState(c.peer), case[2], "member count " .. case[1])
    end
    c.count = c.secret
    equal(wow:GroupState(c.peer), "PENDING", "restricted member count is pending")
    c.count, c.raid = 2, true
    equal(wow:GroupState(c.peer), "CHANGED", "raid is a changed group")
    c.raid = c.secret
    equal(wow:GroupState(c.peer), "PENDING", "restricted raid flag is pending")
    c.raid = false
    api.IsInGroup = nil
    equal(wow:GroupState(c.peer), "PENDING", "missing grouped getter is pending")
    api.IsInGroup = function() return c.grouped end
    equal(select(2, wow:GroupState(c.peer)), 2, "member count returned for rescind decisions")
    equal(wow:Invite(c.peer), false, "no invitation from an existing group")

    -- Presence, distance and the designated duel request.
    equal(wow:PeerPresent(c.peer), true, "connected party member is present")
    c.connected = false
    equal(wow:PeerPresent(c.peer), false, "disconnected party member is absent")
    c.connected = c.secret
    equal(wow:PeerPresent(c.peer), nil, "restricted connection state unknown")
    c.connected = true
    equal(wow:PeerNear(c.peer, 40), true, "native distance within the venue radius")
    c.peerX = 200
    equal(wow:PeerNear(c.peer, 40), false, "native distance beyond the radius")
    c.peerX = nil
    equal(wow:CoLocated(c.peer), true, "same native instance and nearby")
    c.peerX = 111
    local near, reason = wow:CoLocated(c.peer)
    equal(near, false, "horizontal distance beyond ten yards")
    equal(reason:find("Move within 10 yards of Beta-Forever", 1, true) ~= nil, true, "distance reason names the opponent")
    c.peerX = nil; c.peerZ = 11
    equal(wow:CoLocated(c.peer), false, "different floor excluded")
    c.peerZ = nil; c.peerInstance = 1
    equal(wow:CoLocated(c.peer), false, "different native instance excluded")
    c.peerInstance = nil; c.visible = false
    equal(wow:CoLocated(c.peer), false, "phase-invisible opponent excluded")
    c.visible = true; c.phaseReason = 1
    equal(wow:CoLocated(c.peer), false, "native phase reason rejects co-location")
    c.phaseReason = c.secret
    equal(wow:CoLocated(c.peer), false, "restricted phase reason fails closed")
    c.phaseReason = nil; c.restrictedDistance = true
    equal(wow:CoLocated(c.peer), false, "restricted distance cannot imply co-location")
    c.restrictedDistance = false
    api.UnitPhaseReason = nil
    equal(wow:CoLocated(c.peer), false, "missing phase API fails closed")
    api.UnitPhaseReason = function() return c.phaseReason end
    equal(wow:Challenge(c.peer), true, "challenge after native co-location")
    equal(c.requests[1], "party1", "duel requested through FD.Wow:RequestDuel(party1)")
    c.peerX = 111
    equal(wow:Challenge(c.peer), false, "challenge refused when apart")
    equal(#c.requests, 1, "refused challenge never requests")
    c.peerX = nil

    -- Leaving: the exact pair, or our own pending invitation.
    equal(wow:Leave(c.peer), true, "exact queue pair can leave")
    equal(c.left, 1, "one native leave")
    c.partyGUID = "Player-1-00000003"
    equal(wow:Leave(c.peer), false, "a changed group is never left automatically")
    c.partyGUID, c.count = nil, 1
    wow.invitedPeer = { guid = c.peer.guid, at = c.now }
    equal(wow:Leave(c.peer), true, "own pending invitation can be rescinded")
    wow.invitedPeer = { guid = "Player-1-00000003", at = c.now }
    equal(wow:Leave(c.peer), false, "another player's pending group is not ours to rescind")
    c.grouped, c.count = false, 0
    equal(wow:LeaveGroup(), true, "Leave group button calls LeaveParty")

    -- Notifications.
    wow:Announce("ready", "Ready!")
    equal(c.prints[#c.prints], "Ready!", "chat line printed")
    equal(c.sounds[#c.sounds], 8960, "ready sound played")
    equal(c.shown, 1, "queue window opened out of combat")
    c.combat = true
    wow:Announce("cancel", "Cancelled.")
    equal(c.sounds[#c.sounds], 879, "cancel sound played")
    equal(c.shown, 1, "window not opened in combat")
    c.combat = false
    api.SOUNDKIT = nil
    wow:Announce("travel", "Travel.")
    equal(#c.sounds, 2, "missing SOUNDKIT degrades to text only")
    wow:Announce("info", "Info.")
    equal(c.shown, 2, "travel opens the window, informational lines do not")

    -- Waypoints and nonces.
    local prior = api.UiMapPoint.CreateFromCoordinates(12, 0.2, 0.3)
    c.waypoint = prior
    c.trackingQuest = 42
    local venue = { mapID = 37, mapX = 0.6, mapY = 0.7 }
    equal(wow:Waypoint(venue), true, "set queue waypoint")
    equal(c.trackingWaypoint, true, "successful queue waypoint becomes tracked")
    wow:ClearWaypoint()
    equal(c.waypoint, prior, "restore prior waypoint after owned queue point")
    equal(c.trackingQuest, 42, "restore prior tracked quest")
    wow:Waypoint(venue)
    local changed = api.UiMapPoint.CreateFromCoordinates(38, 0.3, 0.4)
    c.waypoint = changed
    wow:ClearWaypoint()
    equal(c.waypoint, changed, "preserve user waypoint changed during queue")
    c.counter = 9007199254740000
    equal(#wow:Nonce() <= 32, true, "compact nonce remains within protocol budget")

    -- Transport through FD.Outbound.
    equal(c.prefix, "ForeverDuelQ2", "independent protocol 2 queue prefix")
    equal(transport:Send({ kind = "QUERY" }, "Unknown-Forever"), false, "cannot probe unknown players")
    equal(transport:Send({ kind = "QUERY" }, c.peer.fullName), true, "known-addon discovery query")
    equal(#c.sent, 0, "outbound queue paces before sending")
    c:advance(0.2)
    equal(#c.sent, 1, "paced whisper sent")
    equal(c.sent[1].channel, "WHISPER", "discovery uses whispers")
    local profilePacket = { kind = "PROFILE", session = "a1", guid = c.own.guid, rating = 1500,
        level = 30, maxLevel = 60, scope = "ZONE", levelGap = 5, ruleset = "NORMAL", faction = "Alliance",
        joinedAt = 1700000000, mapID = 37, continentID = 0, x = 500, y = 500, venues = "-" }
    equal(transport:Send(profilePacket, c.peer.fullName), true, "current profile queued")
    c.FD.queue.session = "a2"
    c:advance(1)
    equal(#c.sent, 1, "obsolete session dropped at drain")
    c.FD.queue.session = "a1"
    c.sendResult = 3
    equal(transport:Send(profilePacket, c.peer.fullName), true, "profile queued")
    c:advance(0.2)
    equal(c.sent[#c.sent].result, 3, "native throttle result observed")
    c.sendResult = 0
    c:advance(4)
    equal(c.sent[#c.sent].result, 0, "throttled packet retried later instead of dropped")
    equal(c.sent[#c.sent].payload, c.sent[#c.sent - 1].payload, "the same packet is retried")
    local query = assert(c.FD.QueueProtocol:Encode({ kind = "QUERY" }))
    equal(transport:Receive("ForeverDuelQ2", query, "WHISPER", "Beta"), true, "local sender normalized")
    equal(c.received[1].sender, c.peer.fullName, "sender matches known presence identity")
    equal(transport:Receive("ForeverDuelQ1", query, "WHISPER", "Beta"), false, "old protocol prefix ignored")
    equal(transport:Receive("ForeverDuelQ2", query, "WHISPER", "Unknown"), false, "unknown query rejected")
    equal(transport:Receive("ForeverDuelQ2", query, "YELL", "Beta"), false, "queue ignores public channel packet")
    equal(transport:Receive("ForeverDuelQ2", query, "WHISPER", c.secret), false, "restricted sender ignored")
    profilePacket.guid, profilePacket.session = c.own.guid, "b1"
    local spoof = assert(c.FD.QueueProtocol:Encode(profilePacket))
    equal(transport:Receive("ForeverDuelQ2", spoof, "WHISPER", "Beta"), false, "transport GUID bound to presence sender")
    c.receiveError = true
    equal(transport:Receive("ForeverDuelQ2", query, "WHISPER", "Beta"), false, "queue receive failure contained")
    equal(c.queueErrors, 1, "receive failure handled by the queue's own error path")
    c.receiveError = false

    -- Ticket packets: PARTY while the exact pair is grouped, terminal CANCEL synchronous.
    local ticket = { id = "a1.b1", ownSession = "a1", peerSession = "b1", peer = c.peer }
    c.FD.queue.ticket = ticket
    c.grouped, c.count = true, 2
    local sentBefore = #c.sent
    equal(transport:Send({ kind = "STATUS", session = "a1", peerSession = "b1", ticket = "a1.b1",
        mapID = 37, continentID = 0, x = 1, y = 2, flags = 1 }, c.peer.fullName, ticket), true, "status queued")
    c:advance(0.5)
    equal(c.sent[#c.sent].channel, "PARTY", "exact ticket pair uses PARTY")
    equal(#c.sent, sentBefore + 1, "one status submission")
    c.partyGUID = "Player-1-00000003"
    transport:Send({ kind = "STATUS", session = "a1", peerSession = "b1", ticket = "a1.b1",
        mapID = 37, continentID = 0, x = 1, y = 2, flags = 1 }, c.peer.fullName, ticket)
    c:advance(1.5)
    equal(c.sent[#c.sent].channel, "WHISPER", "changed group falls back to WHISPER at drain")
    c.partyGUID = nil
    transport:Send({ kind = "STATUS", session = "a1", peerSession = "b1", ticket = "a1.b1",
        mapID = 37, continentID = 0, x = 1, y = 2, flags = 1 }, c.peer.fullName, ticket)
    c.FD.queue.ticket = { id = "a2.b1", ownSession = "a2", peerSession = "b1", peer = c.peer }
    sentBefore = #c.sent
    c:advance(1.5)
    equal(#c.sent, sentBefore, "replaced ticket drops queued controls")
    c.FD.queue.ticket = ticket
    sentBefore = #c.sent
    local cancel = { kind = "CANCEL", session = "a1", peerSession = "b1", ticket = "a1.b1", reason = "CANCELLED" }
    equal(transport:SendNow(cancel, c.peer.fullName, ticket), true, "terminal cancel submitted synchronously")
    equal(#c.sent, sentBefore + 2, "terminal cancel uses PARTY and WHISPER before any leave")
    equal(c.sent[sentBefore + 1].channel, "PARTY", "PARTY copy first")
    equal(c.sent[sentBefore + 2].channel, "WHISPER", "WHISPER copy second")
    c.sendResult, c.partyResult = 3, 3
    sentBefore = #c.sent
    transport:SendNow(cancel, c.peer.fullName, ticket)
    c.sendResult, c.partyResult = 0, nil
    c:advance(5)
    equal(c.sent[#c.sent].result, 0, "a throttled terminal cancel is retried, never dropped")
    equal(c.FD.QueueProtocol:Decode(c.sent[#c.sent].payload).kind, "CANCEL", "retried packet is the cancel")
    local incoming = assert(c.FD.QueueProtocol:Encode({ kind = "STATUS", session = "b1", peerSession = "a1",
        ticket = "a1.b1", mapID = 37, continentID = 0, x = 1, y = 2, flags = 3 }))
    local received = #c.received
    equal(transport:Receive("ForeverDuelQ2", incoming, "PARTY", "Beta"), true, "ticket packet from the peer over PARTY")
    equal(transport.lastReceiveRoute, "PARTY", "receive route diagnosed")
    c.grouped = false
    equal(transport:Receive("ForeverDuelQ2", incoming, "PARTY", "Beta"), true,
        "a PARTY packet is bound by ticket and sender even while the local roster lags")
    c.grouped = true
    equal(transport:Receive("ForeverDuelQ2", incoming, "PARTY", "Gamma"), false, "other PARTY sender rejected")
    equal(transport:Receive("ForeverDuelQ2", incoming, "PARTY", "Alpha"), false, "own PARTY echo rejected")
    equal(transport:Receive("ForeverDuelQ2", query, "PARTY", "Beta"), false, "discovery never via PARTY")
    local wrong = assert(c.FD.QueueProtocol:Encode({ kind = "STATUS", session = "b1", peerSession = "a1",
        ticket = "a2.b1", mapID = 37, continentID = 0, x = 1, y = 2, flags = 3 }))
    equal(transport:Receive("ForeverDuelQ2", wrong, "PARTY", "Beta"), false, "wrong ticket rejected")
    equal(#c.received, received + 2, "only valid PARTY packets reach the engine")
    c.FD.queue.ticket = nil
    equal(transport:Receive("ForeverDuelQ2", incoming, "PARTY", "Beta"), false, "PARTY cannot create a ticket")
    c.grouped, c.count = false, 0

    local regional = client({ regionalNames = true })
    equal(regional.FD.QueueTransport:Receive("ForeverDuelQ2", query, "WHISPER", "Beta Brave"), true,
        "Forever surname transport name retained exactly")
    equal(regional.received[1].sender, "Beta Brave", "surname never suffixed with realm")
    local missing = client()
    missing.env.C_Map = nil
    equal(missing.FD.QueueWow:Position(), nil, "absent map APIs degrade safely")
    missing.env.IsInGroup = nil
    equal(missing.FD.QueueWow:Available(), false, "missing group API never assumes solo")
    local unregistered = client()
    unregistered.registerResult = 2
    unregistered.FD.Outbound.registered = {}
    equal(unregistered.FD.QueueTransport:Initialize(), false, "prefix registration enum failure")
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
    local function venuePacket(tested, record)
        local scale = tested.FD.QueueProtocol.MAP_SCALE
        return { kind = "VENUE", venueID = record.id, testPairGUID = tested.own.guid,
            mapID = record.mapID, continentID = record.continentID,
            mapX = math.floor(record.mapX * scale + 0.5), mapY = math.floor(record.mapY * scale + 0.5),
            minPlayerLevel = record.minPlayerLevel, zoneMinLevel = record.zoneMinLevel, zoneMaxLevel = record.zoneMaxLevel,
            faction = tested.faction or "Alliance", hubFaction = "NONE", testedAt = record.testedAt }
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
    equal(captured.hubFaction, nil, "ordinary test does not certify a capital hub")
    equal(captured.factions.Alliance, true, "capture certifies only native faction")
    local stored, kept = native:StoreVenue(captured)
    equal(stored, true, "tested place stored")
    equal(kept, captured.id, "new place keeps its own ID")
    equal(#native:Catalog(), 1, "stored verified place available to matching")
    equal(native:StoreVenue(captured), true, "same stable place can replace saved metadata")
    native:StoreVenue(captured)
    equal(#native:Catalog(), 1, "stable venue ID prevents duplicates")
    equal(#tested.FD.Database.data.settings.queue.venues, 1, "re-saving one ID replaces the stored record instead of appending")
    local larger = tested.FD.Copy(captured)
    larger.id, larger.mapX = "test-37-50000010-50000000-a", 0.5000001
    stored, kept = native:StoreVenue(larger)
    equal(kept, captured.id, "a second record of the same spot keeps the smaller existing ID")
    equal(#native:Catalog(), 1, "double-saving one spot creates no second ID")
    local smaller = tested.FD.Copy(captured)
    smaller.id = "test-37-49999999-50000000-a"
    smaller.mapX = 0.49999999
    stored, kept = native:StoreVenue(smaller)
    equal(kept, smaller.id, "the smaller ID of one spot wins on every client")
    equal(#native:Catalog(), 1, "the replaced record is removed")
    equal(native:Catalog()[1].id, smaller.id, "catalog converges on the smaller ID")
    native:StoreVenue(larger)
    equal(#tested.FD.Database.data.settings.queue.venues, 1, "a partner's merged record shared back adds no copy")
    local far = tested.FD.Copy(captured)
    far.id, far.mapX = "test-37-60000000-50000000-a", 0.6
    native:StoreVenue(far)
    equal(#native:Catalog(), 2, "a different spot is a separate place")
    tested.FD.Database.data.settings.queue.venues = { captured }
    local packet = venuePacket(tested, captured)
    local accepted, _, code, keptID = native:AcceptVenue(packet, tested.peer.fullName)
    equal(accepted, true, "same native proof accepts peer's normalized place")
    equal(keptID, captured.id, "acknowledgment names the kept ID")
    equal(code, nil, "no rejection code")
    tested.FD.ReceiveQueueSetup = function(_, venueRecord, sender) return native:AcceptVenue(venueRecord, sender) end
    local testTransport = tested.FD.QueueTransport
    local incomingVenue = assert(tested.FD.QueueProtocol:Encode(packet))
    equal(testTransport:Receive("ForeverDuelQ2", incomingVenue, "WHISPER", "Beta"), true,
        "standalone tested place routes through the setup handler")
    equal(#tested.received, 0, "venue sync never enters the queue packet handler")
    equal(testTransport.lastReceive, "VENUE from Beta-Forever", "standalone venue diagnosed separately")
    local outgoingVenue = native:VenuePacket(captured, tested.peer)
    equal(outgoingVenue.testPairGUID, tested.peer.guid, "share is bound to the test partner")
    equal(testTransport:Send(outgoingVenue, tested.peer.fullName), true, "native test peer can receive the share")
    tested:advance(0.3)
    equal(#tested.sent, 1, "standalone venue paced and submitted")
    tested.FD.Presence.players["Player-1-00000003"] = { guid = "Player-1-00000003", fullName = "Gamma-Forever" }
    equal(testTransport:Send(outgoingVenue, "Gamma-Forever"), false, "known addon player cannot receive another pair's proof")
    equal(testTransport:Send({ kind = "VENUE_ACK", venueID = captured.id, keptID = captured.id }, tested.peer.fullName), true,
        "acknowledgment can be sent to the sharer")
    tested.expired = true
    equal(testTransport:Receive("ForeverDuelQ2", incomingVenue, "WHISPER", "Beta"), true,
        "ordinary native proof can receive share without a fresh addon presence profile")
    tested.expired = false
    local setupHandler = tested.FD.ReceiveQueueSetup
    tested.FD.ReceiveQueueSetup = function() error("isolated import failure") end
    equal(testTransport:Receive("ForeverDuelQ2", incomingVenue, "WHISPER", "Beta"), false,
        "venue import error cannot call rated recovery")
    tested.FD.ReceiveQueueSetup = setupHandler
    local function rejection(changes)
        local altered = tested.FD.Copy(packet)
        for key, value in pairs(changes) do altered[key] = value end
        local ok, text, rejectCode = native:AcceptVenue(altered, changes.sender or tested.peer.fullName)
        return ok, rejectCode, text
    end
    local function rejected(changes, expectedCode, label)
        local ok, rejectCode, text = rejection(changes)
        equal(ok, false, label)
        equal(rejectCode, expectedCode, label .. " code")
        equal(type(text), "string", label .. " reason")
    end
    rejected({ minPlayerLevel = 25 }, "MISMATCH", "source-only level cannot exclude lower tested opponent")
    rejected({ hubFaction = "Alliance" }, "HUB", "peer cannot certify a capital exterior")
    rejected({ sender = "Unknown-Forever" }, "MISMATCH", "share requires exact native test sender")
    rejected({ testPairGUID = tested.peer.guid }, "MISMATCH", "share bound to recipient native GUID")
    rejected({ testedAt = packet.testedAt + 10 }, "MISMATCH", "future test timestamp rejected")
    rejected({ zoneMaxLevel = 11 }, "METADATA", "transmitted zone level range checked natively")
    rejected({ mapX = packet.mapX + 5000000 }, "MISMATCH", "peer location outside tested 40-yard radius rejected")
    tested.env.C_Map.GetMapLevels = nil
    local fallbackCapture = native:CaptureVenue()
    equal(fallbackCapture.zoneMaxLevel, 12, "frozen Classic author range used without a manual form")
    equal(fallbackCapture.metadataSource, "CLASSIC", "metadata fallback explicitly distinguished from native API")
    tested.env.C_Map.GetMapLevels = function() return 1, 10 end
    tested.mapPosition = tested.vector(0.52, 0.5)
    equal(native:CaptureVenue().mapX, 0.5, "capture keeps exact native finish spot after a small step away")
    tested.mapPosition = tested.vector(0.55, 0.5)
    equal(native:CaptureVenue(), nil, "moving beyond 40 yards invalidates button capture")
    tested.mapPosition = nil
    tested.grouped = true
    equal(native:CaptureVenue(), nil, "test party must be left before capture")
    tested.grouped = false; tested.combat = true
    equal(native:CaptureVenue(), nil, "capture waits until combat ends")
    tested.combat = false
    tested.FD.queue.state = "SEARCHING"
    equal(native:CaptureVenue(), nil, "active queue prevents capture")
    equal(native:AcceptVenue(packet, tested.peer.fullName), true, "unreserved searching client accepts its tested partner's place")
    tested.FD.queue.ticket = {}
    rejected({}, "BUSY", "reservation prevents asynchronous venue import")
    tested.FD.queue.ticket = nil
    tested.FD.queue.state = "IDLE"
    tested.territory = "hostile"
    equal(native:CaptureVenue(), nil, "changed hostile territory blocks capture after valid duel")
    rejected({}, "TERRITORY", "native hostile territory blocks peer approval")
    tested.territory = "friendly"
    equal(testTransport:Send(outgoingVenue, tested.peer.fullName), true, "share queued before world transition")
    native:ObserveDuel("world")
    equal(native.venueTest, nil, "world transition clears successful test proof")
    rejected({}, "NO_TEST", "saved peer packet cannot restore proof after world transition")
    local sentBeforeWorld = #tested.sent
    tested:advance(1)
    for index = sentBeforeWorld + 1, #tested.sent do
        equal(tested.FD.QueueProtocol:Decode(tested.sent[index].payload).kind ~= "VENUE", true,
            "world transition cancels a queued stale venue share")
    end

    local reversed = testedClient(20, 25)
    completeTest(reversed)
    equal(reversed.FD.QueueWow:CaptureVenue().minPlayerLevel, 20, "both level orderings capture the same tested minimum")
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

    local missingMetadata = testedClient(25, 20)
    missingMetadata.mapID, missingMetadata.territoryMissing = 1429, true
    missingMetadata.env.C_Map.GetMapLevels = function() return end
    completeTest(missingMetadata)
    local recovered = missingMetadata.FD.QueueWow:CaptureVenue()
    equal(type(recovered), "table", "native test proof survives missing getters in Classic Elwynn")
    equal(recovered.zoneMaxLevel, 12, "captured place uses frozen Classic author zone range")
    equal(#missingMetadata.FD.Venues.Catalog, 0, "metadata recovery does not ship a place catalog")
    local recoveredPacket = venuePacket(missingMetadata, recovered)
    equal(missingMetadata.FD.QueueWow:AcceptVenue(recoveredPacket, missingMetadata.peer.fullName), true,
        "peer import uses the same native-preferred metadata fallback")
    recoveredPacket.zoneMaxLevel = 10
    equal(missingMetadata.FD.QueueWow:AcceptVenue(recoveredPacket, missingMetadata.peer.fullName), false,
        "peer cannot replace fallback zone metadata")
    local diagnostic = missingMetadata.FD.QueueWow:MetadataDiagnostics()
    equal(diagnostic.mapID, 1429, "diagnostic includes current map")
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
    mapFallback.faction, mapFallback.mapID = "Alliance", 99999
    equal(mapNative:FriendlyTerritory(), false, "unknown zone is never neutral merely because getters return nothing")
    equal(mapNative:ZoneLevels(99999), nil, "unknown zone receives no invented range")
    mapFallback.mapID = 1429
    mapFallback.own.maxLevel = 70
    equal(mapNative:FriendlyTerritory(), false, "Classic metadata not used for another native level cap")
    mapFallback.own.maxLevel = 60
    mapFallback.mapID = 99998
    mapFallback.mapInfo = { [99998] = { mapID = 99998, mapType = 5, parentMapID = 1429 },
        [1429] = { mapID = 1429, mapType = 3, parentMapID = 1415 } }
    equal(mapNative:FriendlyTerritory(), true, "native micro-map may inherit its validated Classic parent")
    mapFallback.mapInfo[99998].mapType, mapFallback.mapInfo[99998].parentMapID = 5, 99998
    equal(mapNative:FriendlyTerritory(), false, "cyclic native parent chain ends safely")
    mapFallback.mapID, mapFallback.mapInfo = 1429, nil
    mapFallback.env.C_Map.GetMapLevels = function() return 2, 11 end
    local low, high, source = mapNative:ZoneLevels(1429)
    equal(low, 2, "complete native minimum takes precedence over fallback")
    equal(high, 11, "complete native maximum takes precedence over fallback")
    equal(source, "NATIVE", "native source accurately diagnosed")
    for _, getter in ipairs({ function() error("restricted native call") end,
        function() return mapFallback.secret, 10 end, function() return 0, 10 end }) do
        mapFallback.env.C_Map.GetMapLevels = getter
        equal(mapNative:ZoneLevels(1429), nil, "errors/restricted/partial invalid ranges never silently fall back")
    end

    local discovery = client()
    local scans = 0
    discovery.FD.Presence.Changed = function() error("directory offline") end
    discovery.FD.Presence.ScanNearby = function() scans = scans + 1 end
    equal(discovery.FD.QueueWow:Discover(), true, "optional discovery failure isolated")
    equal(scans, 1, "nearby scan still executes after directory failure")
end
