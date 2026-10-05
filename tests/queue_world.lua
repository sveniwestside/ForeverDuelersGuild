-- Full-TOC multi-client world shared by the queue integration and network
-- specs. Every client loads the real addon in TOC order; the world models the
-- server: addon messages with per-message latency and loss, the per-prefix
-- grouped allowance (burst 10, then 1/s), invitations with human responses,
-- a roster that each client sees late (party1 GUID before its name),
-- deferred LeaveParty and native duel requests. It is a deterministic test
-- model, not a claim about a live client.
local BASE = 1700000000

return function(options)
    options = options or {}
    local w = { now = 10, clients = {}, events = {}, sequence = 0, lost = 0, base = BASE }

    local function opt(c, key, default)
        if c.options[key] ~= nil then return c.options[key] end
        if options[key] ~= nil then return options[key] end
        return default
    end
    w.opt = opt

    function w:at(delay, callback, owner)
        self.sequence = self.sequence + 1
        self.events[#self.events + 1] = { at = self.now + math.max(0, delay), seq = self.sequence, run = callback, owner = owner }
    end
    function w:byGUID(guid) for _, c in ipairs(self.clients) do if c.guid == guid then return c end end end
    function w:byName(name)
        for _, c in ipairs(self.clients) do if c.fullName == name or c.name == name then return c end end
    end
    function w:emit(c, event, ...)
        if c.offline then return end
        for _, frame in ipairs(c.frames) do
            if frame.events[event] and frame.scripts.OnEvent then frame.scripts.OnEvent(frame, event, ...) end
        end
    end
    function w:system(c, message, delay)
        self:at(delay or 0.2, function() self:emit(c, "CHAT_MSG_SYSTEM", message) end)
    end

    -- Roster: each client sees server membership after its own lag; the
    -- party1 GUID may lag the member count and the name may lag the GUID.
    local function snapshot(c)
        local group = c.group
        if group then
            local other
            for _, member in ipairs(group.members) do if member ~= c and not other then other = member end end
            return { grouped = true, raid = group.raid or false, members = #group.members, partyGUID = other and other.guid }
        end
        if c.inviting and opt(c, "pendingInviterGroup", false) then return { grouped = true, raid = false, members = 1 } end
        return { grouped = false, raid = false, members = 0 }
    end
    function w:roster(c)
        local view = snapshot(c)
        local lag, guidLag, nameLag = opt(c, "rosterLag", 0.3), opt(c, "guidLag", 0), opt(c, "nameLag", 0)
        local guid = view.partyGUID
        if guid and guidLag > 0 then view.partyGUID = nil end
        view.nameReady = guid ~= nil and guidLag == 0 and nameLag == 0
        self:at(lag, function()
            c.view = view
            self:emit(c, "GROUP_ROSTER_UPDATE")
        end)
        if guid and guidLag > 0 then
            self:at(lag + guidLag, function()
                if c.view ~= view then return end
                view.partyGUID, view.nameReady = guid, nameLag == 0
                self:emit(c, "GROUP_ROSTER_UPDATE")
            end)
        end
        if guid and nameLag > 0 then
            self:at(lag + guidLag + nameLag, function()
                if c.view ~= view then return end
                view.nameReady = true
                self:emit(c, "GROUP_ROSTER_UPDATE")
            end)
        end
    end
    function w:form(inviter, invitee)
        local group = { members = { inviter, invitee } }
        inviter.group, invitee.group, inviter.inviting, invitee.pending = group, group, nil, nil
        self:roster(inviter); self:roster(invitee)
    end
    function w:leave(c)
        local group = c.group
        if group then
            for index, member in ipairs(group.members) do if member == c then table.remove(group.members, index); break end end
            c.group = nil
            if #group.members == 1 then group.members[1].group = nil end
            for _, member in ipairs(group.members) do self:roster(member) end
            self:roster(c)
        elseif c.inviting then
            local target = c.inviting
            if target.pending and target.pending.from == c then
                target.pending, target.popup = nil, nil
                self:at(0.2, function() self:emit(target, "PARTY_INVITE_CANCEL") end)
            end
            c.inviting = nil
            c.rescinded = (c.rescinded or 0) + 1
            self:roster(c)
        end
    end
    function w:invite(inviter, name)
        local target = self:byName(name)
        if not target or target.offline then
            self:system(inviter, string.format(inviter.env.ERR_BAD_PLAYER_NAME_S, name)); return
        end
        if target.group or target.pending or inviter.group then
            self:system(inviter, string.format(inviter.env.ERR_ALREADY_IN_GROUP_S, target.name)); return
        end
        target.pending, inviter.inviting = { from = inviter, at = self.now }, target
        self:roster(inviter)
        self:at(opt(target, "inviteLatency", 0.3), function()
            if not target.pending or target.pending.from ~= inviter then return end
            target.popup = { which = "PARTY_INVITE", from = inviter }
            target.inviteEvents = (target.inviteEvents or 0) + 1
            self:emit(target, "PARTY_INVITE_REQUEST", inviter.name, false, false, false, true, false, inviter.guid, false)
            local response, delay = opt(target, "inviteResponse", "accept"), opt(target, "acceptDelay", 2)
            if response == "accept" then self:at(delay, function() self:click(target, true) end)
            elseif response == "decline" then self:at(delay, function() self:click(target, false) end) end
        end)
        self:at(120, function()
            if target.pending and target.pending.from == inviter then self:decline(target) end
        end)
    end
    -- Blizzard's PARTY_INVITE dialog buttons.
    function w:click(c, accept)
        local popup = c.popup
        if not popup then return end
        if accept then popup.inviteAccepted = 1; c.env.AcceptGroup() end
        c.env.StaticPopup_Hide("PARTY_INVITE")
    end
    function w:accept(c)
        local pending = c.pending
        if pending and not c.group and not pending.from.group then self:form(pending.from, c) end
    end
    function w:decline(c)
        local pending = c.pending
        if not pending then return end
        c.pending, c.popup = nil, nil
        pending.from.inviting = nil
        self:roster(pending.from)
        self:system(pending.from, string.format(pending.from.env.ERR_DECLINE_GROUP_S, c.name), 0.3)
    end

    -- Addon messages. PARTY obeys the per-prefix allowance when `throttle`
    -- is set and reaches only players still grouped with the sender.
    local function lost(record, recipient)
        local loss = opt(record.from, "loss", 0)
        if type(loss) == "function" then return loss(record, recipient) end
        if loss <= 0 then return false end
        w.lossSeed = ((w.lossSeed or 12345) * 1103515245 + 12345) % 2147483648
        return w.lossSeed / 2147483648 < loss
    end
    local function latency(record, recipient)
        local value = record.channel == "WHISPER" and opt(record.from, "whisperLatency", 0.3) or opt(record.from, "partyLatency", 0.2)
        if type(value) == "function" then return value(record, recipient) end
        return value
    end
    function w:chat(c, prefix, payload, channel, target)
        local record = { from = c, prefix = prefix, payload = payload, channel = channel, target = target, at = self.now }
        c.sent[#c.sent + 1] = record
        if channel ~= "WHISPER" and channel ~= "PARTY" then record.result = 0; return 0 end
        if channel == "PARTY" then
            if not c.group then record.result = 5; return 5 end
            if options.throttle then
                local bucket = c.tokens[prefix] or { tokens = 10, at = self.now }
                c.tokens[prefix] = bucket
                bucket.tokens, bucket.at = math.min(10, bucket.tokens + (self.now - bucket.at)), self.now
                if bucket.tokens < 1 then record.result, c.throttled = 3, c.throttled + 1; return 3 end
                bucket.tokens = bucket.tokens - 1
            end
        end
        record.result = 0
        local recipients = {}
        if channel == "WHISPER" then recipients[1] = self:byName(target)
        else for _, member in ipairs(c.group.members) do recipients[#recipients + 1] = member end end
        for _, recipient in ipairs(recipients) do
            if lost(record, recipient) then self.lost = self.lost + 1
            else
                self:at(latency(record, recipient), function()
                    if channel == "PARTY" and not (recipient.group and c.group == recipient.group) then return end
                    self:emit(recipient, "CHAT_MSG_ADDON", prefix, payload, channel, c.fullName)
                end)
            end
        end
        return 0
    end

    -- Native duel requests: the requester gets the acknowledgement, the
    -- target the DUEL_REQUESTED event with the requester's name.
    function w:startDuel(c, unit)
        local target = unit == "party1" and c.view.partyGUID and self:byGUID(c.view.partyGUID)
            or unit == "target" and c.target
        if not target then return end
        self:at(0.2, function()
            self:emit(c, "UI_INFO_MESSAGE", 1, c.env.ERR_DUEL_REQUESTED)
            self:emit(target, "DUEL_REQUESTED", c.fullName)
        end)
    end
    function w:countdown(list)
        for _, c in ipairs(list) do self:emit(c, "CHAT_MSG_SYSTEM", "Duel starting: 3") end
    end
    function w:finishDuel(winner, loser)
        local text = winner.fullName .. " has defeated " .. loser.fullName .. " in a duel"
        for _, c in ipairs({ winner, loser }) do self:emit(c, "CHAT_MSG_SYSTEM", text) end
        for _, c in ipairs({ winner, loser }) do self:emit(c, "DUEL_FINISHED", true) end
    end

    function w:client(spec)
        spec = spec or {}
        local index = #self.clients + 1
        local c = { index = index, options = spec, name = spec.name or ({ "Alpha", "Beta", "Gamma", "Delta" })[index],
            realm = "Forever", classFile = spec.classFile or ({ "MAGE", "ROGUE", "WARRIOR", "PRIEST" })[index],
            level = spec.level or 30, mapID = spec.mapID or 37, mapX = spec.mapX or 0.5, mapY = spec.mapY or 0.3,
            faction = spec.faction or "Alliance", frames = {}, prints = {}, sent = {}, sounds = {}, tokens = {},
            throttled = 0, accepts = 0, invites = 0, leaves = 0, loaded = {},
            view = { grouped = false, raid = false, members = 0 } }
        c.guid = spec.guid or string.format("Player-1-%08X", index)
        c.fullName = c.name .. "-" .. c.realm
        self.clients[index] = c
        local env = setmetatable({}, { __index = _G })
        env._G, env.SlashCmdList = env, {}
        c.env = env
        local FD = {}
        c.FD = FD
        local methods = {}
        function methods:RegisterEvent(event) self.events[event] = true; return true end
        function methods:SetScript(name, callback) self.scripts[name] = callback end
        function methods:IsShown() return false end
        env.CreateFrame = function()
            local frame = setmetatable({ events = {}, scripts = {} }, { __index = methods })
            c.frames[#c.frames + 1] = frame
            return frame
        end
        env.GetTime = function() return w.now end
        env.GetServerTime = function() return BASE + math.floor(w.now) end
        env.C_Timer = { After = function(delay, callback) w:at(delay, callback, c) end }
        local function unit(token)
            if token == "player" then return c, true end
            if token == "party1" and c.view.grouped and c.view.members == 2 and c.view.partyGUID then
                return w:byGUID(c.view.partyGUID), c.view.nameReady
            end
            if token == "target" and c.target then return c.target, true end
        end
        env.UnitGUID = function(token) local u = unit(token); return u and u.guid end
        env.UnitFullName = function(token)
            local u, ready = unit(token)
            if not u then return end
            if not ready then return "Unknown", nil end
            return u.name, u.realm
        end
        env.UnitClass = function(token) local u = unit(token); if u then return u.classFile, u.classFile end end
        env.UnitLevel = function(token) local u = unit(token); return u and u.level end
        env.UnitIsConnected = function(token) local u = unit(token); return u ~= nil and not u.offline end
        env.UnitIsVisible = function(token) return unit(token) ~= nil end
        env.UnitPhaseReason = function() return nil end
        env.UnitIsPlayer = function(token) return unit(token) ~= nil end
        env.UnitPosition = function(token)
            local u = unit(token)
            if u then return u.mapY * 1000, u.mapX * 1000, 0, 0 end
        end
        env.GetMaxPlayerLevel = function() return 60 end
        env.RegionalUniqueNamesEnabled = function() return false end
        env.GetNormalizedRealmName = function() return "Forever" end
        env.UnitFactionGroup = function() return c.faction end
        env.GetZonePVPInfo = function() if not spec.emptyMetadata then return "friendly", false, c.faction end end
        env.C_PvP = { GetZonePVPInfo = function() if not spec.emptyMetadata then return "friendly", false, c.faction end end }
        env.IsInGroup = function() return c.view.grouped end
        env.IsInRaid = function() return c.view.raid end
        env.GetNumGroupMembers = function() return c.view.members end
        env.UnitIsDeadOrGhost = function() return false end
        env.IsInInstance = function() return false end
        env.IsOutdoors = function() return true end
        env.InCombatLockdown = function() return c.combat or false end
        env.C_PartyInfo = {
            CanInvite = function() return true end,
            InviteUnit = function(name) c.invites = c.invites + 1; w:invite(c, name) end,
            LeaveParty = function()
                c.leaves = c.leaves + 1
                w:at(opt(c, "leaveLag", 0.3), function() w:leave(c) end)
            end,
            IsGUIDInGroup = function(guid) return c.view.grouped and c.view.partyGUID == guid or false end,
        }
        env.AcceptGroup = function() c.acceptGroups = (c.acceptGroups or 0) + 1; w:accept(c) end
        env.DeclineGroup = function() c.declineGroups = (c.declineGroups or 0) + 1; w:decline(c) end
        env.StaticPopup_FindVisible = function(which) if which == "PARTY_INVITE" then return c.popup end end
        env.StaticPopup_Hide = function(which)
            if which ~= "PARTY_INVITE" or not c.popup then return end
            local popup = c.popup
            c.popup = nil
            -- FrameXML's OnHide declines an invitation that was not accepted.
            if not popup.inviteAccepted then env.DeclineGroup() end
        end
        local function vector(x, y) return { GetXY = function() return x, y end } end
        env.CreateVector2D = vector
        env.C_Map = {
            GetBestMapForUnit = function() return c.mapID end,
            GetMapLevels = function() if not spec.emptyMetadata then return 1, 10 end end,
            GetMapInfo = function(mapID) return { name = "Test outskirts", mapType = 3,
                mapID = mapID, parentMapID = mapID == 1420 and 1415 or 13 } end,
            GetPlayerMapPosition = function() return vector(c.mapX, c.mapY) end,
            GetWorldPosFromMapPos = function(_, position)
                local x, y = position:GetXY()
                return 0, vector(x * 1000, y * 1000)
            end,
            CanSetUserWaypointOnMap = function() return true end,
            GetUserWaypoint = function() return c.waypoint end,
            SetUserWaypoint = function(point) c.waypoint = point; return true end,
            ClearUserWaypoint = function() c.waypoint = nil end,
        }
        env.UiMapPoint = { CreateFromCoordinates = function(mapID, x, y) return { uiMapID = mapID, position = vector(x, y) } end }
        env.C_SpecializationInfo = {
            GetSpecialization = function() return 1 end,
            GetSpecializationInfo = function() return 62 + index, "Spec" .. index end,
        }
        env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) c.prints[#c.prints + 1] = text end }
        env.Enum = {
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 },
            SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, InvalidChatType = 4, NotInGroup = 5 },
            GameRule = { HardcoreRuleset = 1, RPRuleset = 2, PvPRuleset = 3 },
        }
        env.C_GameRules = { IsGameRuleActive = function() return false end }
        env.C_ChatInfo = {
            RegisterAddonMessagePrefix = function(prefix) return spec.prefixFailure == prefix and 2 or 0 end,
            SendAddonMessage = function(prefix, payload, channel, target) return w:chat(c, prefix, payload, channel, target) end,
        }
        env.SOUNDKIT = { PVP_THROUGH_QUEUE = 8459, READY_CHECK = 8960, MAP_PING = 3175, IG_QUEST_CANCEL = 879 }
        env.PlaySound = function(id) c.sounds[#c.sounds + 1] = id end
        env.AcceptDuel = function() c.accepts = c.accepts + 1 end
        env.CancelDuel = function() c.declines = (c.declines or 0) + 1 end
        env.StartDuel = function(token) c.requestedUnit = token; w:startDuel(c, token) end
        env.hooksecurefunc = function(name, callback)
            local original = env[name]
            env[name] = function(...) original(...); callback(...) end
        end
        env.ERR_DUEL_REQUESTED = "You have requested a duel."
        env.ERR_DUEL_CANCELLED = "Duel canceled."
        env.ERR_DECLINE_GROUP_S = "%s declines your group invitation."
        env.ERR_ALREADY_IN_GROUP_S = "%s is already in a group."
        env.ERR_BAD_PLAYER_NAME_S = "Cannot find player '%s'."
        env.DUEL_COUNTDOWN = "Duel starting: %d"
        env.DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
        env.DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel"
        local toc = assert(io.open("ForeverDuel/ForeverDuel.toc", "r"))
        for line in toc:lines() do
            local file = line:match("^([%w_]+%.lua)%s*$")
            if file then
                c.loaded[#c.loaded + 1] = file
                local chunk = assert(loadfile("ForeverDuel/" .. file))
                setfenv(chunk, env)("ForeverDuel", FD)
            end
        end
        toc:close()
        local function noop() end
        FD.UI = { Create = noop, Render = noop, Hide = noop, Restore = function() return true end }
        FD.Profile.RefreshIfShown, FD.Profile.Toggle = noop, noop
        FD.Minimap.Initialize, FD.Tooltip.Initialize = noop, noop
        FD.Presence.Initialize, FD.Presence.Changed, FD.Presence.ScanNearby = noop, noop, noop
        FD.QueueUI.Show = function() c.queueShown = (c.queueShown or 0) + 1 end
        FD.QueueUI.Toggle = noop
        FD.QueueUI.RefreshIfShown = noop
        function c:command(text) env.SlashCmdList.FOREVERDUEL(text) end
        function c:emit(event, ...) w:emit(self, event, ...) end
        function c:queue() return self.FD.queue end
        function c:move(mapX, mapY) self.mapX, self.mapY = mapX, mapY or self.mapY end
        function c:printed(pattern)
            for _, text in ipairs(self.prints) do if text:find(pattern, 1, true) then return true end end
            return false
        end
        c:emit("PLAYER_LOGIN")
        return c
    end

    -- Every online client is discoverable through Presence.
    function w:presence()
        for _, c in ipairs(self.clients) do
            if c.FD.Presence then
                for _, other in ipairs(self.clients) do
                    if other ~= c then
                        if other.offline or other.hidden then c.FD.Presence.players[other.guid] = nil
                        else
                            c.FD.Presence.players[other.guid] = { guid = other.guid, fullName = other.fullName, level = other.level,
                                maxLevel = 60, rating = 1500, mapID = other.mapID, lastSeen = self.now }
                        end
                    end
                end
            end
        end
    end
    function w:advance(seconds)
        local finish = self.now + seconds
        local guard = 0
        self:presence()
        while true do
            local index, at, seq
            for i, event in ipairs(self.events) do
                if event.at <= finish and (not at or event.at < at or event.at == at and event.seq < seq) then
                    index, at, seq = i, event.at, event.seq
                end
            end
            if not index then break end
            guard = guard + 1
            assert(guard < 500000, "queue world timer runaway")
            local event = table.remove(self.events, index)
            if event.at > self.now + 1 then self.now = event.at; self:presence() end
            self.now = math.max(self.now, event.at)
            if not (event.owner and event.owner.offline) then event.run() end
        end
        self.now = finish
        self:presence()
    end
    function w:reach(state, limit, list)
        local start = self.now
        list = list or self.clients
        while self.now - start <= limit do
            local all = true
            for _, c in ipairs(list) do if c.FD.queue.state ~= state then all = false end end
            if all then return self.now - start end
            self:advance(0.25)
        end
        local parts = {}
        for _, c in ipairs(list) do parts[#parts + 1] = c.name .. "=" .. c.FD.queue.state .. " (" .. tostring(c.FD.queue.reason) .. ")" end
        error("queue world: did not reach " .. state .. " within " .. limit .. " s: " .. table.concat(parts, "; "), 2)
    end
    -- Saves the same operator-approved place on every listed client.
    function w:venue(list, id, mapX, mapY)
        for _, c in ipairs(list) do
            c:command(string.format("queue venue import %s %d %.8f %.8f 1 1 10", id or "test-courtyard", c.mapID,
                mapX or 0.5, mapY or 0.3))
        end
    end
    function w:sentKinds(c, prefix)
        local kinds = {}
        for _, record in ipairs(c.sent) do
            if record.prefix == prefix then
                local packet = c.FD.QueueProtocol:Decode(record.payload)
                if packet then kinds[#kinds + 1] = { kind = packet.kind, channel = record.channel, result = record.result, at = record.at } end
            end
        end
        return kinds
    end
    return w
end
