-- Soak world (not a spec): several clients run the real addon in TOC order on
-- one simulated server. Unlike queue_world.lua, discovery is not stubbed:
-- Presence and Roster join the ForeverDuel channel and broadcast for real, so
-- presence, roster, queue and duel traffic run together. The server models
-- what the live traces showed (review arch-3, queuenative-8, forensics-1):
--   * per-sender FIFO delivery (per channel and recipient) with configurable
--     one-way latency, including a whisper delay line of tens of seconds,
--   * the per-prefix grouped allowance (burst 10, refill 1/s) for PARTY and
--     CHANNEL, answered with AddonMessageThrottle,
--   * the ForeverDuel channel: join, roster reads, CHANNEL addon messages,
--   * native invitations, a PARTY roster that each client sees late (party1
--     GUID before its name), asynchronous LeaveParty, offline members,
--   * native duel requests with Blizzard's popup, countdown and result,
--   * surname names (RegionalUniqueNamesEnabled) as on Forever live,
--   * simulated time; each client's timers die with its session.
-- It is a deterministic model, not a claim about a live client.
local BASE = 1700000000
local FIRST = { "Alpha", "Beta", "Gamma", "Delta", "Epsilon" }
local SURNAME = { "Stone", "Vale", "Reed", "Marsh", "Frost" }
local CLASSES = { "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID" }
-- GetGameMessageInfo ids for the native notices this world raises.
local MESSAGE_IDS = { ERR_DUEL_REQUESTED = 101, ERR_DUEL_CANCELLED = 102, ERR_OUT_OF_RANGE = 103 }
local CHANNEL = "ForeverDuel"
local PREFIXES = { ["ForeverDuel2"] = "duel", ["ForeverDuelQ2"] = "queue", ["ForeverDuelZone2"] = "zone" }

return function(options)
    options = options or {}
    local w = { now = 0, units = {}, clients = {}, events = {}, seq = 0, base = BASE, options = options,
        channel = {}, streams = {}, log = {}, duels = {}, lost = 0, regional = options.regional ~= false }
    w.PREFIXES = PREFIXES

    local function opt(u, key, default)
        if u and u.options and u.options[key] ~= nil then return u.options[key] end
        if options[key] ~= nil then return options[key] end
        return default
    end
    w.opt = opt

    -- Binary min-heap of timers ordered by (at, seq).
    local function less(a, b) return a.at < b.at or a.at == b.at and a.seq < b.seq end
    local function push(event)
        local heap = w.events
        heap[#heap + 1] = event
        local i = #heap
        while i > 1 do
            local parent = math.floor(i / 2)
            if not less(heap[i], heap[parent]) then break end
            heap[i], heap[parent] = heap[parent], heap[i]
            i = parent
        end
    end
    local function pop()
        local heap = w.events
        local top, last = heap[1], table.remove(heap)
        if #heap > 0 then
            heap[1] = last
            local i = 1
            while true do
                local l, r, s = 2 * i, 2 * i + 1, i
                if heap[l] and less(heap[l], heap[s]) then s = l end
                if heap[r] and less(heap[r], heap[s]) then s = r end
                if s == i then break end
                heap[i], heap[s] = heap[s], heap[i]
                i = s
            end
        end
        return top
    end

    -- owner: a client whose timer dies when it logs out (its Lua state ends).
    function w:at(delay, run, owner)
        self.seq = self.seq + 1
        push({ at = self.now + math.max(0, delay or 0), seq = self.seq, run = run, owner = owner,
            generation = owner and owner.generation })
    end
    function w:advance(seconds)
        local finish = self.now + seconds
        local guard, sameAt, lastAt = 0, 0, nil
        while self.events[1] and self.events[1].at <= finish do
            local event = pop()
            self.now = math.max(self.now, event.at)
            guard = guard + 1
            assert(guard < 3000000, "soak world: timer runaway")
            if event.at == lastAt then sameAt = sameAt + 1 else sameAt, lastAt = 0, event.at end
            assert(sameAt < 20000, "soak world: timers spin without advancing time")
            local owner = event.owner
            if not owner or (not owner.offline and owner.generation == event.generation) then event.run() end
        end
        self.now = finish
    end
    -- Advance in steps until predicate() holds; returns the elapsed time or
    -- nil after `limit` seconds.
    function w:wait(limit, predicate, step)
        local start = self.now
        while self.now - start <= limit do
            if predicate() then return self.now - start end
            self:advance(step or 0.25)
        end
        return nil
    end

    local function lower(value) return type(value) == "string" and value:lower() or nil end
    function w:byGUID(guid) for _, u in ipairs(self.units) do if u.guid == guid then return u end end end
    function w:byName(name)
        name = lower(name)
        if not name then return nil end
        for _, u in ipairs(self.units) do if lower(u.fullName) == name then return u end end
        for _, u in ipairs(self.units) do if lower(u.name) == name then return u end end
    end
    function w:distance(a, b)
        return math.sqrt(((a.mapX - b.mapX) * 1000) ^ 2 + ((a.mapY - b.mapY) * 1000) ^ 2)
    end
    local function online(u) return u ~= nil and not u.offline end
    local function fullName(u) return w.regional and (u.name .. " " .. u.surname) or (u.name .. "-" .. u.realm) end
    -- The name the server prints in duel results (Results.lua compares it
    -- with the identity's name: the full surname name, or the bare name).
    local function shownName(u) return w.regional and u.fullName or u.name end

    -- index: position in w.units (delivery streams); ordinal: default name,
    -- class and GUID (clients sort by GUID: the first client coordinates).
    local function newUnit(spec, index, ordinal)
        local u = { index = index, options = spec, guid = spec.guid or string.format("Player-1-%08X", ordinal),
            name = spec.name or FIRST[ordinal] or ("Player" .. ordinal), surname = spec.surname or SURNAME[ordinal] or "Doe",
            realm = "Forever", classFile = spec.classFile or CLASSES[ordinal] or "HUNTER", level = spec.level or 30,
            faction = spec.faction or "Alliance", mapID = spec.mapID or 37, mapX = spec.mapX or 0.5,
            mapY = spec.mapY or 0.3, received = {} }
        u.fullName = fullName(u)
        return u
    end

    -- A player without the addon: visible, invitable, whisperable.
    function w:stranger(spec)
        spec = spec or {}
        local u = newUnit(spec, #self.units + 1, 0x100 + #self.units)
        if not spec.name then u.name, u.surname = "Stranger" .. u.index, "Nobody"; u.fullName = fullName(u) end
        u.stranger = true
        self.units[#self.units + 1] = u
        if spec.channel then self:joinChannel(u) end
        return u
    end

    -- Native notices and chat filters ---------------------------------------
    function w:emit(c, event, ...)
        if not c.frames or c.offline then return end
        for _, frame in ipairs(c.frames) do
            if frame.events[event] and frame.scripts.OnEvent then frame.scripts.OnEvent(frame, event, ...) end
        end
    end
    -- CHAT_MSG_SYSTEM: the event, then the chat frame filters decide whether
    -- the line is shown.
    function w:system(c, message, delay)
        self:at(delay or 0.2, function()
            if not c.frames or c.offline then return end
            self:emit(c, "CHAT_MSG_SYSTEM", message)
            for _, filter in ipairs(c.filters) do
                local ok, hide = pcall(filter, nil, "CHAT_MSG_SYSTEM", message)
                if ok and hide then return end
            end
            c.system[#c.system + 1] = message
        end)
    end

    -- ForeverDuel channel --------------------------------------------------
    function w:channelIndex(u)
        for index, member in ipairs(self.channel) do if member == u then return index end end
    end
    local function channelChanged(except)
        for _, member in ipairs(w.channel) do
            if member.frames and member ~= except and member.rosterLoaded then
                w:emit(member, "CHANNEL_ROSTER_UPDATE", member.fdDisplay, #w.channel)
            end
        end
    end
    function w:joinChannel(u)
        if self:channelIndex(u) then return end
        self.channel[#self.channel + 1] = u
        u.joined = true
        for _, member in ipairs(self.channel) do
            if member ~= u and member.frames then
                self:emit(member, "CHAT_MSG_CHANNEL_JOIN", "", u.fullName, "", member.channelID .. ". " .. CHANNEL, "", "",
                    0, member.channelID, CHANNEL, 0, 0, u.guid)
            end
        end
        if u.frames then
            self:emit(u, "CHAT_MSG_CHANNEL_NOTICE", "YOU_CHANGED", "", "", u.channelID .. ". " .. CHANNEL, "", "", 0,
                u.channelID, CHANNEL)
            self:emit(u, "CHANNEL_UI_UPDATE")
        end
        channelChanged(u)
    end
    function w:leaveChannel(u)
        local index = self:channelIndex(u)
        if not index then return end
        table.remove(self.channel, index)
        u.joined, u.rosterLoaded = false, false
        for _, member in ipairs(self.channel) do
            if member.frames then
                self:emit(member, "CHAT_MSG_CHANNEL_LEAVE", "", u.fullName, "", member.channelID .. ". " .. CHANNEL, "", "",
                    0, member.channelID, CHANNEL, 0, 0, u.guid)
            end
        end
        channelChanged()
    end

    -- Party roster -----------------------------------------------------------
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
    -- Each client sees server membership after its own lag; the party1 GUID
    -- may lag the member count and the name lags the GUID (default 1 s).
    function w:roster(c)
        if not c.frames then return end
        local view = snapshot(c)
        local lag, guidLag, nameLag = opt(c, "rosterLag", 0.3), opt(c, "guidLag", 0), opt(c, "nameLag", 1)
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
            self:roster(c)
        end
    end
    function w:invite(inviter, name)
        local target = self:byName(name)
        if not target or target.offline then
            self:system(inviter, string.format(inviter.env.ERR_BAD_PLAYER_NAME_S, name)); return
        end
        -- A pending invitation counts as membership for the server.
        if target.group or target.pending or inviter.group then
            self:system(inviter, string.format(inviter.env.ERR_ALREADY_IN_GROUP_S, target.fullName)); return
        end
        target.pending, inviter.inviting = { from = inviter, at = self.now }, target
        self:roster(inviter)
        if target.stranger then return end
        self:at(opt(target, "inviteLatency", 0.3), function()
            if not target.pending or target.pending.from ~= inviter or target.offline then return end
            target.popup = { which = "PARTY_INVITE", from = inviter }
            target.inviteEvents = (target.inviteEvents or 0) + 1
            self:emit(target, "PARTY_INVITE_REQUEST", inviter.fullName, false, false, false, true, false, inviter.guid, false)
            local response, delay = opt(target, "inviteResponse", "accept"), opt(target, "acceptDelay", 2)
            if response == "accept" then self:at(delay, function() self:click(target, true) end, target)
            elseif response == "decline" then self:at(delay, function() self:click(target, false) end, target) end
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
        if pending and not c.group and not pending.from.group and online(pending.from) then self:form(pending.from, c) end
    end
    function w:decline(c)
        local pending = c.pending
        if not pending then return end
        c.pending, c.popup = nil, nil
        pending.from.inviting = nil
        self:roster(pending.from)
        self:system(pending.from, string.format(pending.from.env.ERR_DECLINE_GROUP_S, c.fullName), 0.3)
    end

    -- Addon messages ---------------------------------------------------------
    local function latency(record, recipient)
        local key = record.channel == "WHISPER" and "whisperLatency" or record.channel == "PARTY" and "partyLatency"
            or "channelLatency"
        local value = opt(record.from, key, record.channel == "WHISPER" and 0.5 or 0.3)
        if type(value) == "function" then value = value(record, recipient) end
        return value
    end
    -- The server keeps each sender's stream to each recipient in order.
    local function schedule(record, recipient, run)
        local delay = latency(record, recipient)
        if delay == false then w.lost = w.lost + 1; return end
        local key = record.from.index .. " " .. record.channel .. " " .. recipient.index
        local at = math.max(w.now + delay, w.streams[key] or -math.huge)
        w.streams[key] = at
        w:at(at - w.now, run)
    end
    local function receive(recipient, record, ...)
        if recipient.offline then return end
        local entry = { from = record.from, to = recipient, prefix = record.prefix, payload = record.payload,
            channel = record.channel, sentAt = record.at, at = w.now }
        w.log[#w.log + 1] = entry
        recipient.received[#recipient.received + 1] = entry
        if recipient.frames then w:emit(recipient, "CHAT_MSG_ADDON", record.prefix, record.payload, record.channel, ...) end
    end
    function w:chat(c, prefix, payload, channel, target)
        local record = { from = c, prefix = prefix, payload = payload, channel = channel, target = target, at = self.now }
        c.sent[#c.sent + 1] = record
        local function result(code) record.result = code; return code end
        if type(payload) ~= "string" or #payload == 0 or #payload > 255 then return result(2) end
        if channel == "WHISPER" then
            if type(target) ~= "string" or target == "" then return result(6) end
        elseif channel == "PARTY" then
            if not c.group then return result(5) end
        elseif channel == "CHANNEL" then
            if not c.joined or target ~= tostring(c.channelID) then return result(7) end
        else return result(4) end
        if channel ~= "WHISPER" and opt(c, "throttle", true) then
            local bucket = c.tokens[prefix] or { tokens = 10, at = self.now }
            c.tokens[prefix] = bucket
            bucket.tokens, bucket.at = math.min(10, bucket.tokens + (self.now - bucket.at)), self.now
            if bucket.tokens < 1 then c.throttled = c.throttled + 1; return result(3) end
            bucket.tokens = bucket.tokens - 1
        end
        result(0)
        if channel == "WHISPER" then
            local recipient = self:byName(target)
            if not online(recipient) then
                -- The server answers an unreachable whisper with a system line.
                self:system(c, string.format(c.env.ERR_CHAT_PLAYER_NOT_FOUND_S, target), latency(record, c) or 0.3)
                return 0
            end
            record.recipients = { recipient }
            schedule(record, recipient, function() receive(recipient, record, c.fullName, recipient.fullName, 0, 0, "", 0) end)
        elseif channel == "PARTY" then
            -- Members at submission; native PARTY broadcasts echo to the sender.
            record.recipients = {}
            for _, member in ipairs(c.group.members) do
                record.recipients[#record.recipients + 1] = member
                schedule(record, member, function() receive(member, record, c.fullName, "", 0, 0, "", 0) end)
            end
        else
            record.recipients = {}
            for _, member in ipairs(self.channel) do
                record.recipients[#record.recipients + 1] = member
                schedule(record, member, function()
                    if member.joined then receive(member, record, c.fullName, "", 0, member.channelID or 0, CHANNEL, 0) end
                end)
            end
        end
        return 0
    end

    -- Native duels -----------------------------------------------------------
    function w:duelOf(u)
        local duel = self.duels[u]
        if duel and duel.state ~= "over" then return duel end
    end
    local function endDuel(duel)
        duel.state = "over"
        w.duels[duel.from], w.duels[duel.to] = nil, nil
        if duel.to.duelPopup == duel then duel.to.duelPopup = nil end
    end
    function w:startDuel(c, unit)
        local target = c.unit(unit)
        if not online(target) or target == c or target.stranger then
            self:at(0.1, function() self:emit(c, "UI_ERROR_MESSAGE", MESSAGE_IDS.ERR_OUT_OF_RANGE, c.env.ERR_OUT_OF_RANGE) end, c)
            return
        end
        if self:distance(c, target) > opt(c, "duelRange", 10) or self:duelOf(c) or self:duelOf(target) then
            self:at(0.1, function() self:emit(c, "UI_ERROR_MESSAGE", MESSAGE_IDS.ERR_OUT_OF_RANGE, c.env.ERR_OUT_OF_RANGE) end, c)
            return
        end
        local duel = { from = c, to = target, state = "requested", at = self.now }
        self.duels[c], self.duels[target] = duel, duel
        c.duelRequests = (c.duelRequests or 0) + 1
        self:at(opt(c, "duelLatency", 0.2), function()
            if duel.state ~= "requested" then return end
            self:emit(c, "UI_INFO_MESSAGE", MESSAGE_IDS.ERR_DUEL_REQUESTED, c.env.ERR_DUEL_REQUESTED)
            self:emit(target, "DUEL_REQUESTED", c.fullName)
            -- Blizzard shows its dialog after the addon handlers ran; its
            -- timeout calls OnCancel = CancelDuel.
            target.duelPopup = duel
            self:at(60, function()
                if target.duelPopup == duel and duel.state == "requested" then
                    target.duelPopup = nil
                    target.env.CancelDuel()
                end
            end, target)
        end)
    end
    function w:acceptDuel(c)
        local duel = self:duelOf(c)
        if not duel or duel.to ~= c or duel.state ~= "requested" then return end
        duel.state, c.duelPopup = "countdown", nil
        for step = 0, 2 do
            self:at(0.2 + step, function()
                if duel.state ~= "countdown" then return end
                for _, u in ipairs({ duel.from, duel.to }) do
                    self:system(u, string.format(u.env.DUEL_COUNTDOWN, 3 - step), 0)
                end
            end)
        end
        self:at(3.2, function() if duel.state == "countdown" then duel.state = "fighting" end end)
    end
    function w:cancelDuel(c)
        local duel = self:duelOf(c)
        if not duel or duel.state == "fighting" then return end
        endDuel(duel)
        for _, u in ipairs({ duel.from, duel.to }) do self:system(u, u.env.ERR_DUEL_CANCELLED) end
    end
    -- The native result: the system line on both clients, then DUEL_FINISHED.
    function w:finishDuel(winner, loser)
        local duel = self:duelOf(winner)
        if duel then endDuel(duel) end
        for _, u in ipairs({ winner, loser }) do
            self:system(u, string.format("%s has defeated %s in a duel", shownName(winner), shownName(loser)), 0)
            self:at(0.05, function() self:emit(u, "DUEL_FINISHED") end)
        end
    end

    -- Movement: clients walk toward a destination at `speed` yards/s.
    local function walk()
        for _, u in ipairs(w.units) do
            local goal = u.walking
            if goal and not u.offline then
                local dx, dy = (goal.mapX - u.mapX) * 1000, (goal.mapY - u.mapY) * 1000
                local d, step = math.sqrt(dx * dx + dy * dy), goal.speed * 0.25
                if d <= step then u.mapX, u.mapY, u.walking = goal.mapX, goal.mapY, nil
                else u.mapX, u.mapY = u.mapX + dx / d * step / 1000, u.mapY + dy / d * step / 1000 end
            end
        end
        w:at(0.25, walk)
    end
    w:at(0.25, walk)

    -- Clients ----------------------------------------------------------------
    function w:client(spec)
        spec = spec or {}
        local c = newUnit(spec, #self.units + 1, #self.clients + 1)
        self.units[#self.units + 1] = c
        self.clients[#self.clients + 1] = c
        c.client = true
        c.frames, c.prints, c.system, c.sent, c.sounds, c.tokens, c.filters = {}, {}, {}, {}, {}, {}, {}
        c.throttled, c.accepts, c.declines, c.invites, c.leaves, c.renders, c.generation = 0, 0, 0, 0, 0, 0, 1
        c.channelID, c.selected, c.fdDisplay = spec.channelID or 5, 1, 3
        c.view = { grouped = false, raid = false, members = 0 }
        local env = setmetatable({}, { __index = _G })
        env._G, env.SlashCmdList, env.UISpecialFrames = env, {}, {}
        c.env = env
        local FD = {}
        c.FD = FD

        local methods = {}
        function methods:RegisterEvent(event) self.events[event] = true; return true end
        function methods:UnregisterEvent(event) self.events[event] = nil end
        function methods:SetScript(name, callback) self.scripts[name] = callback end
        function methods:HookScript() end
        function methods:IsShown() return false end
        function methods:Show() end
        function methods:Hide() end
        env.CreateFrame = function(_, name)
            local frame = setmetatable({ events = {}, scripts = {} }, { __index = methods })
            c.frames[#c.frames + 1] = frame
            if name then env[name] = frame end
            return frame
        end
        env.GetTime = function() return w.now end
        env.GetServerTime = function() return BASE + math.floor(w.now) end
        env.C_Timer = { After = function(delay, callback) w:at(delay, callback, c) end }

        -- Units: player, target, party1 (lagging), nameplates within 41 yd.
        local function visible(u)
            return online(u) and u.mapID == c.mapID
        end
        local function nameplates()
            local list = {}
            if opt(c, "nameplates", true) then
                for _, u in ipairs(w.units) do
                    if u ~= c and visible(u) and w:distance(c, u) <= 41 then list[#list + 1] = u end
                end
            end
            return list
        end
        local function unit(token)
            if type(token) ~= "string" then return nil end
            if token == "player" then return c, true end
            if token == "target" then if visible(c.target) then return c.target, true end return nil end
            if token == "party1" then
                local view = c.view
                if view.grouped and view.members == 2 and view.partyGUID then return w:byGUID(view.partyGUID), view.nameReady end
                return nil
            end
            local n = token:match("^nameplate(%d+)$")
            if n then
                local u = nameplates()[tonumber(n)]
                if u then return u, true end
            end
            -- /duel <name> passes a name; the native call resolves it.
            for _, u in ipairs(w.units) do
                if u ~= c and visible(u) and (u.fullName == token or u.name == token) and w:distance(c, u) <= 41 then return u, true end
            end
        end
        c.unit = unit
        local TOKENS = { "target", "party1" }
        for i = 1, 40 do TOKENS[#TOKENS + 1] = "nameplate" .. i end
        env.UnitGUID = function(token) local u = unit(token); return u and u.guid end
        env.UnitFullName = function(token)
            local u, ready = unit(token)
            if not u then return nil end
            if not ready then return "Unknown", nil end
            if w.regional then return u.name, u.surname end
            return u.name, u == c and u.realm or nil
        end
        env.UnitNameUnmodified = function(token)
            local u, ready = unit(token)
            if not u then return nil end
            if not ready then return "Unknown", nil end
            return u.name, u.surname
        end
        env.NameUtil = { GetUnmodifiedUnitFullName = function(token)
            local u, ready = unit(token)
            if not u then return nil end
            if not ready then return "Unknown" end
            return u.name .. " " .. u.surname
        end }
        env.UnitName = function(token)
            local u, ready = unit(token)
            if u then return ready and u.name or "Unknown" end
        end
        env.UnitClass = function(token) local u = unit(token); if u then return u.classFile, u.classFile end end
        env.UnitLevel = function(token) local u = unit(token); return u and u.level end
        env.UnitIsPlayer = function(token) return unit(token) ~= nil end
        env.UnitIsConnected = function(token) local u = unit(token); return u ~= nil and not u.offline end
        env.UnitIsVisible = function(token) local u = unit(token); return u ~= nil and visible(u) end
        env.UnitPhaseReason = function() return nil end
        env.UnitIsDeadOrGhost = function() return false end
        env.UnitFactionGroup = function(token) local u = unit(token); if u then return u.faction, u.faction end end
        env.UnitPosition = function(token)
            local u = unit(token)
            if u and visible(u) then return u.mapY * 1000, u.mapX * 1000, 0, 0 end
        end
        env.UnitTokenFromGUID = function(guid)
            for _, token in ipairs(TOKENS) do
                local u = unit(token)
                if u and u.guid == guid then return token end
            end
        end
        env.GetMaxPlayerLevel = function() return 60 end
        env.RegionalUniqueNamesEnabled = function() return w.regional end
        env.GetNormalizedRealmName = function() return "Forever" end
        env.GetZonePVPInfo = function() return "friendly", false, c.faction end
        env.C_PvP = { GetZonePVPInfo = function() return "friendly", false, c.faction end }
        env.IsInGroup = function() return c.view.grouped end
        env.IsInRaid = function() return c.view.raid end
        env.GetNumGroupMembers = function() return c.view.members end
        env.IsInInstance = function() return false end
        env.IsOutdoors = function() return true end
        env.InCombatLockdown = function() return c.combat or false end
        env.C_PartyInfo = {
            CanInvite = function() return true end,
            InviteUnit = function(name) c.invites = c.invites + 1; w:invite(c, name) end,
            LeaveParty = function()
                c.leaves = c.leaves + 1
                w:at(opt(c, "leaveLag", 0.4), function() w:leave(c) end)
            end,
            IsGUIDInGroup = function(guid) return c.view.grouped and c.view.partyGUID == guid or false end,
        }
        env.AcceptGroup = function() c.acceptGroups = (c.acceptGroups or 0) + 1; w:accept(c) end
        env.DeclineGroup = function() c.declineGroups = (c.declineGroups or 0) + 1; w:decline(c) end
        env.StaticPopup_FindVisible = function(which) if which == "PARTY_INVITE" then return c.popup end end
        env.StaticPopup_Visible = function(which)
            if which == "DUEL_REQUESTED" and c.duelPopup then return "StaticPopup1", c.duelPopup end
        end
        env.StaticPopup_Hide = function(which)
            if which == "DUEL_REQUESTED" then c.duelPopup = nil; return end
            if which ~= "PARTY_INVITE" or not c.popup then return end
            local popup = c.popup
            c.popup = nil
            -- FrameXML's OnHide declines an invitation that was not accepted.
            if not popup.inviteAccepted then env.DeclineGroup() end
        end
        local function vector(x, y) return { GetXY = function() return x, y end } end
        env.CreateVector2D = vector
        env.C_Map = {
            GetBestMapForUnit = function(token) if token == "player" then return c.mapID end end,
            GetMapLevels = function() return 1, 10 end,
            GetMapInfo = function(mapID) return { name = "Test outskirts", mapType = 3, mapID = mapID, parentMapID = 13 } end,
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
            GetSpecializationInfo = function() return 62 + c.index, "Spec" .. c.index end,
        }
        env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) c.prints[#c.prints + 1] = { text = text, at = w.now } end }
        env.ChatFrameUtil = { AddMessageEventFilter = function(event, callback)
            if event == "CHAT_MSG_SYSTEM" then c.filters[#c.filters + 1] = callback end
        end }
        env.SendChatMessage = function() error("the addon must never send ordinary chat") end
        env.Enum = {
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2, MaxPrefixes = 3 },
            SendAddonMessageResult = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3,
                InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8,
                GeneralError = 9, NotInGuild = 10, AddOnMessageLockdown = 11, TargetOffline = 12 },
            GameRule = { HardcoreRuleset = 1, RPRuleset = 2, PvPRuleset = 3 },
        }
        env.C_GameRules = { IsGameRuleActive = function() return false end }
        -- Channel directory: General, Trade, then ForeverDuel once joined.
        local function display(index)
            if index == 1 then return "General", false, false, 1, nil, true end
            if index == 2 then return "Trade", false, false, 2, nil, true end
            if index == c.fdDisplay and c.joined then
                return CHANNEL, false, false, c.channelID, c.rosterLoaded and #w.channel or nil, true
            end
        end
        env.GetNumDisplayChannels = function() return c.joined and 3 or 2 end
        env.GetChannelDisplayInfo = display
        env.GetSelectedDisplayChannel = function() return c.selected end
        env.SetSelectedDisplayChannel = function(index)
            c.selected = index
            c.rosterRequests = (c.rosterRequests or 0) + (index == c.fdDisplay and 1 or 0)
            if index == c.fdDisplay and c.joined then
                w:at(0.5, function()
                    if c.selected ~= index or not c.joined then return end
                    c.rosterLoaded = true
                    w:emit(c, "CHANNEL_ROSTER_UPDATE", index, #w.channel)
                end, c)
            end
        end
        env.GetChannelName = function(name)
            if c.joined and type(name) == "string" and name:lower() == CHANNEL:lower() then return c.channelID, CHANNEL end
            return 0
        end
        env.JoinTemporaryChannel = function(name)
            c.channelJoins = (c.channelJoins or 0) + 1
            if type(name) == "string" and name:lower() == CHANNEL:lower() and not opt(c, "noChannel", false) then
                w:at(opt(c, "joinLag", 0.5), function() w:joinChannel(c) end, c)
            end
        end
        env.ChannelFrame = { IsShown = function() return false end, HookScript = function() end }
        env.C_ChatInfo = {
            RegisterAddonMessagePrefix = function(prefix) return spec.prefixFailure == prefix and 2 or 0 end,
            SendAddonMessage = function(prefix, payload, channel, target) return w:chat(c, prefix, payload, channel, target) end,
            GetChannelRosterInfo = function(index, row)
                if index ~= c.fdDisplay or not c.joined or not c.rosterLoaded then return nil end
                local member = w.channel[row]
                if member then return member.fullName, false, false, member.guid end
            end,
            GetGeneralChannelLocalID = function() return 1 end,
        }
        env.SOUNDKIT = { PVP_THROUGH_QUEUE = 8459, READY_CHECK = 8960, MAP_PING = 3175, IG_QUEST_CANCEL = 879 }
        env.PlaySound = function(id) c.sounds[#c.sounds + 1] = id end
        env.AcceptDuel = function() c.accepts = c.accepts + 1; w:acceptDuel(c) end
        env.CancelDuel = function() c.declines = c.declines + 1; w:cancelDuel(c) end
        env.StartDuel = function(token) c.requestedUnit = token; w:startDuel(c, token) end
        env.hooksecurefunc = function(name, callback)
            local original = env[name]
            env[name] = function(...) original(...); callback(...) end
        end
        env.GetGameMessageInfo = function(id)
            for key, value in pairs(MESSAGE_IDS) do if value == id then return key end end
        end
        env.ERR_DUEL_REQUESTED = "You have requested a duel."
        env.ERR_DUEL_CANCELLED = "Duel canceled."
        env.ERR_OUT_OF_RANGE = "Out of range."
        env.ERR_DECLINE_GROUP_S = "%s declines your group invitation."
        env.ERR_ALREADY_IN_GROUP_S = "%s is already in a group."
        env.ERR_BAD_PLAYER_NAME_S = "Cannot find player '%s'."
        env.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
        env.DUEL_COUNTDOWN = "Duel starting: %d"
        env.DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
        env.DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel"

        local toc = assert(io.open("ForeverDuel/ForeverDuel.toc", "r"))
        for line in toc:lines() do
            local file = line:match("^([%w_]+%.lua)%s*$")
            if file then
                local chunk = assert(loadfile("ForeverDuel/" .. file))
                setfenv(chunk, env)("ForeverDuel", FD)
            end
        end
        toc:close()
        -- Presentation is replaced; every engine, adapter and discovery
        -- module runs for real. Render keeps a hook for fault injection.
        local function noop() end
        FD.UI = { Create = noop, Restore = function() return true end, History = noop, Summary = noop,
            Hide = function() c.dialog = nil end,
            Render = function(_, m)
                c.renders = c.renders + 1
                if c.onRender then c.onRender(m) end
            end }
        FD.Profile.RefreshIfShown, FD.Profile.Toggle = noop, noop
        FD.Minimap.Initialize, FD.Tooltip.Initialize = noop, noop
        FD.QueueUI.Show = function() c.queueShown = (c.queueShown or 0) + 1 end
        FD.QueueUI.Toggle, FD.QueueUI.RefreshIfShown = noop, noop

        function c:command(text) env.SlashCmdList.FOREVERDUEL(text) end
        function c:emit(event, ...) w:emit(self, event, ...) end
        function c:queue() return self.FD.queue end
        function c:state() return self.FD.queue.state end
        function c:duelState() return self.FD.duel and self.FD.duel:State() or "DISABLED" end
        -- The duel dialog's rated button, through the same FD:Safe wrapper.
        function c:clickRated() return self.FD:Safe(function() self.FD.duel:AcceptRated() end) end
        -- The queue window's Request duel button.
        function c:requestDuel() return self.FD.queue:Run(function() return self.FD.queue:Challenge() end) end
        function c:walkTo(mapX, mapY, speed) self.walking = { mapX = mapX, mapY = mapY, speed = speed or 7 } end
        function c:printed(text, since)
            for _, line in ipairs(self.prints) do
                if line.at >= (since or -math.huge) and line.text:find(text, 1, true) then return true end
            end
            return false
        end
        function c:logout()
            self:emit("PLAYER_LEAVING_WORLD")
            self:emit("PLAYER_LOGOUT")
            self.offline, self.generation = true, self.generation + 1
            w:leaveChannel(self)
            local duel = w:duelOf(self)
            if duel then w:cancelDuel(self) end
            if self.inviting then w:leave(self) end
            -- An offline member stays in the group; the others see it change.
            if self.group then for _, member in ipairs(self.group.members) do if member ~= self then w:roster(member) end end end
        end
        c:emit("PLAYER_LOGIN")
        c:emit("PLAYER_ENTERING_WORLD", true, false)
        return c
    end

    -- Saves the same operator-approved place on every listed client.
    function w:venue(list, id, mapX, mapY)
        for _, c in ipairs(list) do
            c:command(string.format("queue venue import %s %d %.8f %.8f 1 1 10", id or "test-courtyard", c.mapID,
                mapX or 0.5, mapY or 0.3))
        end
    end

    -- Traffic of one client from its native submissions: totals per
    -- "<prefix> <channel>" plus whispers to `to` (a unit) when given.
    function w:traffic(c)
        local summary = { total = 0, whispers = 0, byKey = {}, whisperTimes = {}, recipients = {} }
        for _, record in ipairs(c.sent) do
            local key = record.prefix .. " " .. record.channel
            summary.byKey[key] = (summary.byKey[key] or 0) + 1
            summary.total = summary.total + 1
            if record.channel == "WHISPER" then
                summary.whispers = summary.whispers + 1
                summary.whisperTimes[#summary.whisperTimes + 1] = record.at
                summary.recipients[record.target] = (summary.recipients[record.target] or 0) + 1
            end
        end
        return summary
    end
    -- Largest number of whispers this client submitted in any `span` seconds.
    function w:whisperBurst(c, span)
        local times, best, first = w:traffic(c).whisperTimes, 0, 1
        for last = 1, #times do
            while times[last] - times[first] >= span do first = first + 1 end
            best = math.max(best, last - first + 1)
        end
        return best
    end
    -- Decoded duel and queue packets a client submitted.
    function w:packets(c, prefix, kind)
        local list = {}
        for _, record in ipairs(c.sent) do
            if record.prefix == prefix then
                local packet = prefix == c.FD.C.PREFIX and c.FD.Protocol:Decode(record.payload)
                    or prefix == "ForeverDuelQ2" and c.FD.QueueProtocol:Decode(record.payload) or nil
                if packet and (not kind or packet.kind == kind) then
                    packet.channel, packet.result, packet.at, packet.target = record.channel, record.result, record.at, record.target
                    list[#list + 1] = packet
                end
            end
        end
        return list
    end
    return w
end
