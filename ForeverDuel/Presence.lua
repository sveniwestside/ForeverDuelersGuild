local _, FD = ...

-- Zone discovery. Profiles are advisory self-reports: they never supply
-- rated-duel consent, snapshots or result evidence.
--
-- Traffic policy: discovery is on demand. Whisper queries go only to the
-- current target/mouseover (shown in a tooltip or while the zone window is
-- open, same faction), to ForeverDuel channel members while the zone window
-- is open or the queue is searching, and replies go only to trusted senders.
-- Nothing is queried while a duel or a queue ticket is active. Every send
-- goes through FD.Outbound; discovery hands it one whisper at a time with
-- BACKGROUND priority, so it can neither fill the shared lane nor delay duel
-- or queue control traffic.
--
-- Quiet mode A/B procedure (whisper latency, forensics-1): on both clients
-- type /duelrating quiet, /reload and wait two minutes. Measure with
-- /duelrating ping <name> a few times (a two-player group also measures
-- PARTY) and note the Traffic lines of /duelrating status. Then turn quiet
-- off on both clients, /reload and repeat. Quiet mode stops every Presence
-- and Roster send: queries, replies, broadcasts, channel joins and roster
-- requests. Only the explicit latency probe and its PONG stay available,
-- because they are the measurement.
FD.Presence = { players = {}, suspended = false, queries = {}, replies = {}, held = {}, whispered = {},
    work = {}, workCount = 0, seq = 0, pings = {}, pongs = {}, pingSeq = 0,
    -- Forever rejects addon YELL/SAY with InvalidChatType (live 0.4.2), so
    -- the area route was removed; this flag only documents that fact.
    areaUnsupported = true }
local Presence = FD.Presence
local PREFIX = "ForeverDuelZone2"
local TICK, PULSE = 2, 5            -- event-driven ticks are coalesced; housekeeping cadence
-- A whisper sweep of a large channel at the shared 1/s budget takes longer
-- than HEARTBEAT, so profiles stay valid for three minutes; the zone browser
-- marks entries older than STALE as "last seen".
local EXPIRY, FORGET, MAX_PLAYERS = 180, 600, 300
local HEARTBEAT = 45                -- per-peer query interval for known addon users
local STRANGER = 600                -- per-name interval for players that never answered
local ASK_GAP, MANUAL = 3, 10       -- tooltip query spacing; explicit refresh window
local MIN_REPLY, HOLD = 5, 20       -- per-sender replies; wait for an unverified sender
local GREET_GAP = 10                -- at most one whisper greeting per 10 s to CHANNEL newcomers
local WORK_LIMIT, WORK_TTL = 30, 30 -- pending discovery whispers and their lifetime
local QUERY_BACKLOG = 6             -- member queries waiting at once (refilled every Tick)
local ANNOUNCE_GAP, BROADCAST, CHANNEL_STALE = 30, 60, 180
local NOT_FOUND_WINDOW, PING_TIMEOUT, PONG_GAP, MAX_PINGS = 5, 90, 2, 20
Presence.STALE = 45                 -- the zone browser marks older entries as "last seen"
local classes = { WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true,
    PRIEST = true, SHAMAN = true, MAGE = true, WARLOCK = true, DRUID = true }

local function integer(value, low, high)
    return type(value) == "number" and value >= low and value <= high and value % 1 == 0
end

local function number(text, low, high)
    if not text:match("^%-?%d+$") then return nil end
    local value = tonumber(text)
    if integer(value, low, high) and string.format("%.0f", value) == text then return value end
end

local function validName(value)
    return type(value) == "string" and #value > 0 and #value <= 128
        and not value:find("[%c|]")
end

local function fresh(player, at)
    return type(player) == "table" and type(player.lastSeen) == "number" and at - player.lastSeen < EXPIRY
end

local function say(text) FD.Debug:Print(text) end

-- Discovery/UI errors must never enter Core:Safe, which cancels rated flow.
function Presence:Run(callback)
    local ok, result, reason = pcall(callback)
    if ok then return result, reason end
    self.status = FD.L["Zone discovery temporarily unavailable."]
    pcall(function()
        if FD.Wow:Readable(result) then FD.Debug:Error("zone discovery", tostring(result)) end
    end)
    return nil, self.status
end

function Presence:Live()
    return self.available == true and not self.suspended and not self.stopped
end

function Presence:Quiet()
    local db = FD.Database and FD.Database.data
    return db ~= nil and type(db.settings) == "table" and db.settings.quiet == true
end

-- Background discovery never competes with a rated request or a queue match.
function Presence:Busy()
    local queue = FD.queue
    return FD.duel ~= nil and FD.duel.active ~= nil or type(queue) == "table" and queue.ticket ~= nil
end

function Presence:ChannelMode()
    return self.lastChannelReceive ~= nil and GetTime() - self.lastChannelReceive < CHANNEL_STALE
end

function Presence:MapID()
    if not C_Map or type(C_Map.GetBestMapForUnit) ~= "function" then return nil end
    local id = C_Map.GetBestMapForUnit("player")
    if FD.Wow:Readable(id) and integer(id, 1, 10000000) then return id end
end

function Presence:GetOwnPlayer()
    local db = FD.Database and FD.Database.data
    if not db then return nil end
    local identity = FD.Wow:Identity("player")
    if not identity or not FD.Wow:Readable(identity.level, identity.maxLevel) then return nil end
    local bracket = FD.Rating:Bracket(identity.level, identity.maxLevel)
    if not bracket then return nil end
    local stats = FD.Database:GetStats(bracket)
    if not stats or not FD.Wow:Readable(stats.rating)
        or not integer(stats.rating, -100000, 100000) then return nil end
    return { guid = identity.guid, fullName = identity.fullName, classFile = identity.classFile,
        rating = stats.rating, level = identity.level, maxLevel = identity.maxLevel,
        bracket = bracket, mapID = self:MapID(), lastSeen = GetTime() }
end

-- The cache is keyed by the server-authenticated sender name. The GUID in a
-- profile is a claim; `verified` is set only when a visible native unit with
-- exactly that name carries it. Lookups scan values, so entries are found by
-- their fields whatever key they are stored under.
function Presence:Entry(name)
    local player = self.players[name]
    if not self.suspended and fresh(player, GetTime()) then return player end
end

local function better(a, b)
    if not b then return true end
    if (a.verified == true) ~= (b.verified == true) then return a.verified == true end
    return a.lastSeen > b.lastSeen
end

function Presence:GetPlayer(guid)
    if not FD.Wow:Readable(guid) or not FD.Protocol:ValidGUID(guid) or self.suspended then return nil end
    local best, at = nil, GetTime()
    for _, player in pairs(self.players) do
        if player.guid == guid and fresh(player, at) and better(player, best) then best = player end
    end
    return best and FD.Copy(best) or nil
end

function Presence:GetPlayers()
    local list, mapID = {}, self:MapID()
    if not mapID or self.suspended then return list end
    local at = GetTime()
    for _, player in pairs(self.players) do
        if fresh(player, at) and player.mapID == mapID then list[#list + 1] = FD.Copy(player) end
    end
    table.sort(list, function(a, b)
        if a.fullName == b.fullName then return a.guid < b.guid end
        return a.fullName < b.fullName
    end)
    return list
end

-- Stable lookup API for other modules (queue transport/candidates).
function Presence:FindByName(fullName)
    if not FD.Wow:Readable(fullName) or type(fullName) ~= "string" or self.suspended then return nil end
    local at = GetTime()
    for _, player in pairs(self.players) do
        if player.fullName == fullName and fresh(player, at) then return FD.Copy(player) end
    end
end

function Presence:Candidates()
    local result = {}
    if self.suspended then return result end
    local at = GetTime()
    for _, player in pairs(self.players) do
        if fresh(player, at) then result[#result + 1] = FD.Copy(player) end
    end
    return result
end

function Presence:GetStatus()
    local L = FD.L
    if self.initialized and not self.available then
        return self.status or L["Zone discovery is unavailable on this client."]
    end
    if self.suspended then return L["Waiting for the world to load."] end
    if self:Quiet() then return L["Quiet mode: zone discovery sends nothing. Type /duelrating quiet to resume."] end
    if not self:MapID() then return L["Current zone is unavailable; waiting for map information."] end
    if self.available and not self:GetOwnPlayer() then return L["Waiting for your character level and level cap."] end
    local count = #self:GetPlayers()
    if self.available and count > 0 then
        return FD.Locale:Format("%d addon players discovered in this zone.", count)
    end
    return (FD.Roster and FD.Roster.status) or self.status or L["Zone discovery is not connected."]
end

function Presence:Refresh()
    if FD.Zone and FD.Zone.RefreshIfShown then FD.Zone:RefreshIfShown() end
end

function Presence:ChannelID()
    if type(GetChannelName) ~= "function" then return nil end
    local id = GetChannelName(FD.Roster and FD.Roster.CHANNEL or "ForeverDuel")
    if FD.Wow:Readable(id) and integer(id, 1, 100) then return id end
end

-- Native senders on the own realm arrive without a realm suffix.
function Presence:Canonical(sender)
    if not FD.Wow:Readable(sender) or not validName(sender) then return nil end
    local regional = type(RegionalUniqueNamesEnabled) == "function" and RegionalUniqueNamesEnabled()
    if not FD.Wow:Readable(regional) then return nil end
    if regional or sender:find("-", 1, true) then return sender end
    local realm = GetNormalizedRealmName()
    if not FD.Wow:Readable(realm) or not validName(realm) then return nil end
    return sender .. "-" .. realm
end

-- A visible native unit whose exact name (and, when given, GUID) matches.
function Presence:NativeUnit(name, guid)
    local units = { "target", "mouseover", "focus", "party1", "party2", "party3", "party4" }
    if guid and type(UnitTokenFromGUID) == "function" then
        local unit = UnitTokenFromGUID(guid)
        if FD.Wow:Readable(unit) and type(unit) == "string" and unit ~= "" then table.insert(units, 1, unit) end
    end
    for _, unit in ipairs(units) do
        local unitGUID = UnitGUID(unit)
        if FD.Wow:Readable(unitGUID) and FD.Protocol:ValidGUID(unitGUID) and (guid == nil or unitGUID == guid) then
            local identity = FD.Wow:Identity(unit)
            if identity and identity.fullName == name then return unit, identity end
        end
    end
end

-- Who may receive our profile: a current queue peer or ticket partner, a
-- ForeverDuel channel member, or a visible native unit with this name.
-- Cheap table checks run before native unit lookups.
function Presence:Trust(name, guid)
    local queue = FD.queue
    if type(queue) == "table" then
        local ticket = queue.ticket
        if type(ticket) == "table" and type(ticket.peer) == "table" and ticket.peer.fullName == name then return "queue" end
        if type(queue.peers) == "table" then
            for _, peer in pairs(queue.peers) do
                if type(peer) == "table" and peer.fullName == name then return "queue" end
            end
        end
    end
    if FD.Roster and FD.Roster:IsMember(name) then return "member" end
    if self:NativeUnit(name, guid) then return "native" end
end

-- Map disclosure in replies: queue partners and visible units get the real
-- map; channel members only when they already reported this map; everyone
-- else gets map 0, which never lists us in their zone browser.
function Presence:MapFor(own, name)
    local player = self.players[name]
    local trust = self:Trust(name, player and player.guid)
    if trust == "native" or trust == "queue" then return own.mapID or 0 end
    if trust == "member" and player and own.mapID and player.mapID == own.mapID then return own.mapID end
    return 0
end

function Presence:SameFaction(unit)
    if type(UnitFactionGroup) ~= "function" then return false end
    local mine, theirs = UnitFactionGroup("player"), UnitFactionGroup(unit)
    return FD.Wow:Readable(mine, theirs) and type(mine) == "string" and mine ~= "" and mine == theirs
end

function Presence:Encode(player, mapID, tag)
    if not player or not FD.Protocol:ValidGUID(player.guid)
        or not integer(player.rating, -100000, 100000)
        or not integer(mapID, 0, 10000000) or not classes[player.classFile]
        or not FD.Rating:Bracket(player.level, player.maxLevel) then return nil end
    return table.concat({ tag or "FDP2", player.guid, string.format("%.0f", player.rating),
        string.format("%.0f", mapID), player.classFile,
        string.format("%.0f", player.level), string.format("%.0f", player.maxLevel) }, "|")
end

function Presence:Decode(payload)
    if not FD.Wow:Readable(payload) or type(payload) ~= "string" or #payload > 255 then return nil end
    local guid, rating, mapID, class, level, maxLevel = payload:match("^FDP2|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if not guid or not FD.Protocol:ValidGUID(guid) or not classes[class] then return nil end
    -- Map 0 means "not disclosed to you".
    rating, mapID = number(rating, -100000, 100000), number(mapID, 0, 10000000)
    level, maxLevel = number(level, 1, 1000), number(maxLevel, 1, 1000)
    local bracket = FD.Rating:Bracket(level, maxLevel)
    if not rating or not mapID or not bracket then return nil end
    return { guid = guid, rating = rating, mapID = mapID, classFile = class,
        level = level, maxLevel = maxLevel, bracket = bracket }
end

-- Discovery whisper work: name -> { reply, at, seq, item }. One entry at a
-- time is handed to FD.Outbound; replies are chosen before queries and a
-- reply coalesces with a queued query to the same recipient (Outbound key).
function Presence:Enqueue(name, reply)
    if not self:Live() or self:Quiet() or not validName(name) then return false end
    local entry = self.work[name]
    if entry then
        if reply and not entry.reply then
            entry.reply = true
            if entry.item then self:Submit(name, entry) end
        end
        return true
    end
    if self.workCount >= WORK_LIMIT then
        if not reply then return false end
        -- A reply displaces the newest waiting query.
        local victim, newest
        for key, other in pairs(self.work) do
            if not other.reply and not other.item and (not newest or other.seq > newest) then victim, newest = key, other.seq end
        end
        if not victim then return false end
        self:Discard(victim)
    end
    self.seq = self.seq + 1
    self.work[name] = { reply = reply == true, at = GetTime(), seq = self.seq }
    self.workCount = self.workCount + 1
    if not reply then self.queries[name] = GetTime() end
    self:Pump()
    return true
end

function Presence:Discard(name)
    local entry = self.work[name]
    if not entry then return end
    self.work[name], self.workCount = nil, self.workCount - 1
    if not entry.reply then self.queries[name] = GetTime() end
end

function Presence:Pump()
    if self.inflight or not self:Live() or self:Quiet() then return end
    local at, busy, pickName, pick = GetTime(), self:Busy(), nil, nil
    for name, entry in pairs(self.work) do
        if at - entry.at >= WORK_TTL then self:Discard(name)
        elseif (entry.reply or not busy) and (not pick or entry.reply and not pick.reply
            or entry.reply == pick.reply and entry.seq < pick.seq) then pickName, pick = name, entry end
    end
    if pick then self:Submit(pickName, pick) end
end

function Presence:Submit(name, entry)
    local own = self:GetOwnPlayer()
    local payload = own and (entry.reply and self:Encode(own, self:MapFor(own, name), "FDP2")
        or self:Encode(own, own.mapID or 0, "FDQ2"))
    if not payload then
        if self.inflight == entry.item then self.inflight = nil end
        entry.item = nil
        return self:Discard(name)
    end
    local item
    item = { prefix = PREFIX, payload = payload, channel = "WHISPER", target = name,
        priority = FD.Outbound.BACKGROUND, ttl = WORK_TTL, key = "zone " .. name, owner = self,
        isCurrent = function() return self:Live() and not self:Quiet() and (entry.reply or not self:Busy()) end,
        onResult = function(status, code) self:Done(name, entry, item, status, code) end }
    entry.item, self.inflight = item, item
    if not FD.Outbound:Send(item) then
        self.inflight, entry.item = nil, nil
        self:Discard(name)
    end
end

function Presence:Done(name, entry, item, status, code)
    if self.inflight ~= item then return end
    self.inflight = nil
    if self.work[name] == entry then self.work[name], self.workCount = nil, self.workCount - 1 end
    local at, kind = GetTime(), entry.reply and "profile" or "query"
    if status == "sent" then
        self.whispered[name] = at
        if entry.reply then self.replies[name] = at else self.queries[name] = at end
    elseif status == "failed" and code == FD.Outbound:Code("TargetOffline") then
        self:Forget(name) -- Offline recipients are never retried.
    elseif not entry.reply then
        self.queries[name] = at -- An expired or dropped query is not re-added at once.
    end
    self.lastWhisper = FD.Locale:Format(entry.reply and "Profile to %s: %s" or "Query to %s: %s", name, FD.L[status])
    if status == "sent" then FD.Debug:Log("zone send", kind, "WHISPER", status)
    else FD.Debug:Log("zone send", kind, "WHISPER", status, FD.Outbound:CodeName(code)) end
    self:Pump()
end

-- Remove a name that is offline or unknown to the server.
function Presence:Forget(name)
    self.players[name], self.held[name] = nil, nil
    self.queries[name] = GetTime()
    local entry = self.work[name]
    if entry and not entry.item then self.work[name], self.workCount = nil, self.workCount - 1 end
    if FD.Roster then FD.Roster:RemoveMember(name) end
end

function Presence:DropWork()
    self.work, self.workCount, self.inflight, self.held = {}, 0, nil, {}
    if FD.Outbound then FD.Outbound:Drop(function(item) return item.owner == self end) end
end

-- On-demand query for a visible player the user is looking at. Unknown
-- names are asked at most once per STRANGER interval.
function Presence:Ask(unit, identity, paced)
    if not self:Live() or self:Quiet() or self:Busy() then return false end
    local at = GetTime()
    if paced and self.lastAsk and at - self.lastAsk < ASK_GAP then return false end
    local isPlayer = UnitIsPlayer(unit)
    if not FD.Wow:Readable(isPlayer) or not isPlayer or not self:SameFaction(unit) then return false end
    identity = identity or FD.Wow:Identity(unit)
    local ownGUID = UnitGUID("player")
    if not identity or not FD.Wow:Readable(ownGUID) or identity.guid == ownGUID then return false end
    local name, player = identity.fullName, self.players[identity.fullName]
    if player and at - player.lastSeen < HEARTBEAT then return false end
    local last = self.queries[name]
    local interval = (player or FD.Roster and FD.Roster:IsMember(name)) and HEARTBEAT or STRANGER
    if last and at - last < interval then return false end
    if paced then self.lastAsk = at end
    return self:Enqueue(name, false)
end

-- Tooltip hook: corroborate the cached claim with the visible unit, or ask
-- the player for a profile. Returns only a corroborated entry.
function Presence:Observe(unit, identity)
    local result = self:Run(function()
        identity = identity or FD.Wow:Identity(unit)
        if type(identity) ~= "table" then return nil end
        local player = self:Entry(identity.fullName)
        if player and player.guid == identity.guid then
            player.verified = true
            return FD.Copy(player)
        end
        self:Ask(unit, identity, true)
    end)
    return result
end

-- Kept for QueueWow:Discover: run a discovery pass soon.
function Presence:ScanNearby()
    return self:Run(function() self:Wake(0) end)
end

function Presence:Store(name, player)
    local at, old = GetTime(), self.players[name]
    if not old then
        local count, oldestKey, oldestAt = 0, nil, math.huge
        for key, cached in pairs(self.players) do
            if type(cached) ~= "table" or type(cached.lastSeen) ~= "number" or at - cached.lastSeen >= FORGET then
                self.players[key] = nil
            else
                count = count + 1
                if cached.lastSeen < oldestAt then oldestKey, oldestAt = key, cached.lastSeen end
            end
        end
        if count >= MAX_PLAYERS and oldestKey then self.players[oldestKey] = nil end
    end
    player.fullName, player.lastSeen = name, at
    player.verified = old ~= nil and old.guid == player.guid and old.verified == true
        or self:NativeUnit(name, player.guid) ~= nil
    self.players[name] = player
    return fresh(old, at) and old or nil
end

function Presence:Receive(prefix, payload, distribution, sender, _, _, localID)
    if not self:Live() or not FD.Wow:Readable(prefix, payload, distribution, sender, localID)
        or prefix ~= PREFIX or type(payload) ~= "string" or #payload > 255 then return end
    local name = self:Canonical(sender)
    if not name then return end
    local tag = payload:sub(1, 5)
    if tag == "PING|" or tag == "PONG|" then return self:ReceivePing(payload, distribution, name) end
    local channel = distribution == "CHANNEL"
    if channel then
        local id = self:ChannelID()
        if not id or localID ~= id then return end
    elseif distribution ~= "WHISPER" then return end
    local query = tag == "FDQ2|"
    if query and channel then return end
    local player = self:Decode(query and "FDP2" .. payload:sub(5) or payload)
    local ownGUID = UnitGUID("player")
    if not player or not FD.Wow:Readable(ownGUID) then return end
    local own = FD.Wow:Identity("player")
    if player.guid == ownGUID or own and own.fullName == name then
        -- The own echo shows the server distributed our broadcast; it is no
        -- proof that anyone else receives CHANNEL messages.
        if channel and own and own.fullName == name then
            if not self.ownEcho then FD.Debug:Log("zone receive", "own echo via CHANNEL") end
            self.ownEcho = GetTime()
        end
        return
    end
    local at = GetTime()
    if channel then
        -- Only another player's CHANNEL message proves channel delivery.
        if not self.lastChannelReceive then FD.Debug:Log("zone receive", "first profile via CHANNEL") end
        self.lastChannelReceive = at
        if FD.Roster then FD.Roster:AddMember(name, player.guid) end
    end
    local known = self:Store(name, player)
    self.lastReceive = FD.Locale:Format(query and "Query from %s via %s" or "Profile from %s via %s", name, distribution)
    FD.Debug:Log("zone receive", query and "query" or "profile", "via " .. distribution)
    if query then self:Answer(name, player.guid)
    elseif channel and not known and at - (self.lastGreet or -math.huge) >= GREET_GAP then
        -- A newcomer's broadcast is answered directly, so it learns existing
        -- members without every member rebroadcasting to the whole channel.
        self.lastGreet = at
        self:Enqueue(name, true)
    end
    self:Refresh()
end

function Presence:Answer(name, guid)
    local last = self.replies[name]
    if last and GetTime() - last < MIN_REPLY then return end
    if self:Trust(name, guid) then return self:Enqueue(name, true) end
    -- Unverified sender: wait briefly for a roster read to prove membership.
    local count = 0
    for _ in pairs(self.held) do count = count + 1 end
    if count >= WORK_LIMIT or self:Quiet() then return end
    self.held[name] = self.held[name] or GetTime()
    if FD.Roster then FD.Roster:Request(false) end
end

function Presence:ResolveHeld(at)
    for name, since in pairs(self.held) do
        local player = self:Entry(name)
        if not player or at - since >= HOLD then self.held[name] = nil
        elseif self:Trust(name, player.guid) then
            self.held[name] = nil
            self:Enqueue(name, true)
        end
    end
end

function Presence:Broadcast(own, reason)
    local id, payload = self:ChannelID(), self:Encode(own, own.mapID or 0, "FDP2")
    if not id or not payload then return false end
    self.lastBroadcast, self.announced = GetTime(), payload
    -- noWhisperFallback: a rejected CHANNEL route must never become a whisper
    -- to a player named like the channel number.
    return FD.Outbound:Send({ prefix = PREFIX, payload = payload, channel = "CHANNEL", target = tostring(id),
        priority = FD.Outbound.BACKGROUND, ttl = 20, key = "zone channel", owner = self, noWhisperFallback = true,
        isCurrent = function() return self:Live() and not self:Quiet() and not self:Busy() and self:ChannelID() == id end,
        onResult = function(status, code)
            local codeName = FD.Outbound:CodeName(code)
            self.lastChannelSend = FD.Locale:Format("%s: %s (%s)", FD.L[reason], FD.L[status], codeName)
            FD.Debug:Log("zone send", "CHANNEL", reason, status, codeName)
        end })
end

-- Profile changes (map, rating, level) are pushed at most every 30 s: over
-- CHANNEL while that route works, otherwise to trusted cached peers.
function Presence:Announce(own, at)
    local payload = self:Encode(own, own.mapID or 0, "FDP2")
    local channel = self:ChannelMode()
    if not self.announced then self.announced = payload end -- The first profile is a baseline, not a change.
    if payload and payload ~= self.announced and at - (self.lastAnnounce or -math.huge) >= ANNOUNCE_GAP then
        self.lastAnnounce = at
        if channel then return self:Broadcast(own, "update") end
        self.announced = payload
        for name, player in pairs(self.players) do
            if fresh(player, at) and self:Trust(name, player.guid) then
                self.queries[name] = nil
                if not self:Enqueue(name, true) then break end
            end
        end
    elseif channel and at - (self.lastBroadcast or -math.huge) >= BROADCAST then
        self:Broadcast(own, "heartbeat")
    end
end

function Presence:Discover(own, at)
    local zone = FD.Zone and FD.Zone.IsShown and FD.Zone:IsShown()
    local queue = FD.queue
    local searching = type(queue) == "table" and (queue.state == "SEARCHING" or queue.state == "PAUSED")
    local manual = self.manualUntil ~= nil and at < self.manualUntil
    if zone or manual then
        self:Ask("target")
        self:Ask("mouseover")
    end
    -- A working CHANNEL route replaces per-member query whispers.
    if not (zone or searching or manual) or self:ChannelMode() and not manual or not FD.Roster then return end
    FD.Roster:Request(manual)
    -- Keep only a short query backlog and refill it with the members asked
    -- longest ago, so a large channel is swept fairly instead of starving.
    local room = QUERY_BACKLOG
    for _, entry in pairs(self.work) do if not entry.reply then room = room - 1 end end
    if room <= 0 then return end
    local due = {}
    for name, guid in pairs(FD.Roster.members) do
        if name ~= own.fullName and guid ~= own.guid and not self.work[name] then
            local player, last = self.players[name], self.queries[name]
            if (not player or at - player.lastSeen >= HEARTBEAT) and (not last or at - last >= HEARTBEAT) then
                due[#due + 1] = name
            end
        end
    end
    table.sort(due, function(x, y)
        local qx, qy = self.queries[x] or -math.huge, self.queries[y] or -math.huge
        if qx ~= qy then return qx < qy end
        return x < y
    end)
    for index = 1, math.min(room, #due) do
        if not self:Enqueue(due[index], false) then break end
    end
end

function Presence:Tick()
    local at = GetTime()
    self.lastTick = at
    if not self:Live() then return end
    for name, player in pairs(self.players) do
        if type(player) ~= "table" or type(player.lastSeen) ~= "number" or at - player.lastSeen >= FORGET then self.players[name] = nil end
    end
    for name, last in pairs(self.queries) do if at - last >= FORGET then self.queries[name] = nil end end
    for name, last in pairs(self.replies) do if at - last >= MIN_REPLY then self.replies[name] = nil end end
    for name, last in pairs(self.whispered) do if at - last >= NOT_FOUND_WINDOW then self.whispered[name] = nil end end
    for seq, probe in pairs(self.pings) do
        if at - probe.queuedAt >= PING_TIMEOUT then
            self.pings[seq] = nil
            say(FD.Locale:Format("No PONG from %s via %s within %d s.", probe.target, probe.route, PING_TIMEOUT))
            FD.Debug:Log("ping", "timeout", probe.route)
        end
    end
    local quiet, own = self:Quiet(), self:GetOwnPlayer()
    if FD.Roster then FD.Roster:Tick(quiet) end
    if quiet or not own then return end
    self:ResolveHeld(at)
    if not self:Busy() then
        if not self.experimented and self:ChannelID() then
            -- One CHANNEL attempt per session. Success only means submitted;
            -- the route counts as working once another player's arrives.
            self.experimented = true
            self:Broadcast(own, "experiment")
        end
        self:Announce(own, at)
        self:Discover(own, at)
    end
    self:Pump()
end

-- Event handlers only schedule; one Tick runs at most every TICK seconds.
function Presence:Wake(delay)
    if self.stopped or not self.available or not C_Timer then return end
    local at = math.max(GetTime() + (delay or 0), (self.lastTick or -math.huge) + TICK)
    if self.wakeAt and self.wakeAt <= at + 0.001 then return end
    self.wakeAt = at
    C_Timer.After(math.max(0.01, at - GetTime()), function()
        if self.wakeAt ~= at then return end
        self.wakeAt = nil
        self:Run(function() self:Tick() end)
        self:Wake(PULSE)
    end)
end

function Presence:Changed()
    return self:Run(function() self:Wake(0) end)
end

-- Explicit refresh from the zone window: ask members and the target again.
function Presence:RefreshNow()
    return self:Run(function()
        local at = GetTime()
        self.manualUntil = at + MANUAL
        for name, last in pairs(self.queries) do
            if at - last >= MANUAL then self.queries[name] = nil end
        end
        self:Wake(0)
    end)
end

function Presence:QuietChanged()
    if self:Quiet() then
        self:DropWork()
        if FD.Roster then FD.Roster:Finish() end
    end
    self:Wake(0)
end

function Presence:Enter()
    if not self.available then return end
    self.suspended = false
    self:Wake(0)
end

function Presence:Leave(logout)
    if FD.Roster then FD.Roster:Reset() end
    self.players, self.suspended = {}, true
    self.queries, self.replies = {}, {}
    self:DropWork()
    if logout then self.stopped = true end
    self:Refresh()
end

-- "No player named '%s' is currently playing." is hidden only for names
-- this module whispered within the last five seconds; the name is dropped.
function Presence:NotFound(message)
    if not FD.Wow:Readable(message) or type(message) ~= "string" or type(ERR_CHAT_PLAYER_NOT_FOUND_S) ~= "string" then return false end
    if not self.notFoundPattern then
        local escaped = ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
        local pattern, count = escaped:gsub("%%%%s", "(.+)")
        self.notFoundPattern = count == 1 and "^" .. pattern .. "$" or false
    end
    local name = self.notFoundPattern and message:match(self.notFoundPattern)
    if not name then return false end
    local at = GetTime()
    for whispered, sent in pairs(self.whispered) do
        if at - sent < NOT_FOUND_WINDOW and (whispered == name or whispered:match("^[^%-]+") == name) then
            self.whispered[whispered] = nil
            self:Forget(whispered)
            return true
        end
    end
    return false
end

function Presence:InstallFilter()
    local add = ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter or ChatFrame_AddMessageEventFilter
    if type(add) ~= "function" or type(ERR_CHAT_PLAYER_NOT_FOUND_S) ~= "string" then return end
    pcall(add, "CHAT_MSG_SYSTEM", function(_, _, message)
        local hide = self:Run(function() return self:NotFound(message) end)
        return hide == true
    end)
end

function Presence:Initialize()
    return self:Run(function()
        if self.initialized then return self.available end
        self.initialized = true
        if not FD.Outbound or not C_ChatInfo or type(C_ChatInfo.SendAddonMessage) ~= "function"
            or not C_Timer or type(C_Timer.After) ~= "function" then
            self.status = FD.L["Zone discovery is unavailable on this client."]
            return false
        end
        self.available = FD.Outbound:Register(PREFIX) == true
        if not self.available then
            self.status = FD.L["Zone discovery prefix could not be registered."]
            return false
        end
        self.startedAt = GetTime()
        self.status = FD.L["Starting zone discovery..."]
        self:InstallFilter()
        self:Wake(1)
        return true
    end)
end

function Presence:Challenge(name)
    return self:Run(function()
        local L = FD.L
        local player = FD.Wow:Readable(name) and type(name) == "string" and self:Entry(name)
        if not player or player.mapID ~= self:MapID() then return false, L["This player is no longer listed in your zone."] end
        if FD.Wow.outgoing then return false, L["Finish the current duel request first."] end
        local unit = self:NativeUnit(player.fullName, player.guid)
        if not unit then return false, L["Move closer and target this player, then click Duel again."] end
        player.verified = true
        -- The duel module owns addon-initiated requests; its post-hook still
        -- captures the native unit, and only the server acknowledgment begins
        -- rated negotiation.
        return FD.Wow:RequestDuel(unit)
    end)
end

-- Latency probe: PING|seq|ms is answered at once with PONG|seq|ms. The
-- pinger measures the round trip on its own clock, per route.
function Presence:GroupedWith(name)
    if type(IsInGroup) ~= "function" or type(IsInRaid) ~= "function" or type(GetNumGroupMembers) ~= "function" then return false end
    local grouped, raid, members = IsInGroup(), IsInRaid(), GetNumGroupMembers()
    if not FD.Wow:Readable(grouped, raid, members) or not grouped or raid or members ~= 2 then return false end
    local identity = FD.Wow:Identity("party1")
    return identity ~= nil and identity.fullName == name
end

function Presence:PongAllowed(name)
    if self.players[name] or FD.Roster and FD.Roster:IsMember(name) then return true end
    for _, unit in ipairs({ "target", "party1", "party2", "party3", "party4" }) do
        local identity = FD.Wow:Identity(unit)
        if identity and identity.fullName == name then return true end
    end
    return false
end

function Presence:SendPing(name, route)
    local count = 0
    for _ in pairs(self.pings) do count = count + 1 end
    if count >= MAX_PINGS then return say(FD.L["Too many pings are still waiting for an answer."]) end
    self.pingSeq = self.pingSeq % 999999 + 1
    local seq, at = self.pingSeq, GetTime()
    local probe = { target = name, route = route, queuedAt = at }
    self.pings[seq] = probe
    local sent = FD.Outbound:Send({ prefix = PREFIX, payload = string.format("PING|%d|%.0f", seq, at * 1000),
        channel = route, target = name, priority = FD.Outbound.QUEUE, ttl = 10, owner = "ping", noWhisperFallback = true,
        onResult = function(status, code)
            if status == "sent" then probe.sentAt = GetTime(); return end
            self.pings[seq] = nil
            say(FD.Locale:Format("PING to %s via %s was not sent (%s).", name, route, FD.Outbound:CodeName(code)))
            FD.Debug:Log("ping", "not sent", route, status)
        end })
    if not sent then
        self.pings[seq] = nil
        return say(FD.Locale:Format("PING to %s via %s was not sent (%s).", name, route, FD.L["outbound queue full"]))
    end
    say(FD.Locale:Format("PING sent to %s via %s.", name, route))
    FD.Debug:Log("ping", "sent", route)
end

function Presence:Ping(text)
    local L = FD.L
    if not self.available then return say(L["Addon messages are unavailable; the latency probe cannot run."]) end
    local name
    if not text or text == "" then
        local isPlayer = UnitIsPlayer("target")
        local identity = FD.Wow:Readable(isPlayer) and isPlayer and FD.Wow:Identity("target")
        if not identity then return say(L["Target a player or type /duelrating ping <name>."]) end
        name = identity.fullName
    else
        name = self:Canonical(text)
        if not name then return say(L["That is not a valid character name."]) end
    end
    local own = FD.Wow:Identity("player")
    if own and own.fullName == name then return say(L["Ping another player, not yourself."]) end
    self:SendPing(name, "WHISPER")
    if self:GroupedWith(name) then self:SendPing(name, "PARTY") end
end

function Presence:ReceivePing(payload, distribution, name)
    local kind, seq, clock = payload:match("^(P[IO]NG)|(%d%d?%d?%d?%d?%d?)|(%d%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?)$")
    seq, clock = tonumber(seq), tonumber(clock)
    if not kind or not seq or not clock or distribution ~= "WHISPER" and distribution ~= "PARTY"
        or distribution == "PARTY" and not self:GroupedWith(name) then return end
    local at = GetTime()
    if kind == "PING" then
        local key = name .. " " .. distribution
        if self.pongs[key] and at - self.pongs[key] < PONG_GAP or not self:PongAllowed(name) then return end
        self.pongs[key] = at
        for other, last in pairs(self.pongs) do if at - last >= PONG_GAP then self.pongs[other] = nil end end
        FD.Outbound:Send({ prefix = PREFIX, payload = string.format("PONG|%d|%.0f", seq, clock), channel = distribution,
            target = name, priority = FD.Outbound.QUEUE, ttl = 10, owner = "ping", noWhisperFallback = true })
        FD.Debug:Log("ping", "answered", distribution)
        return
    end
    local probe = self.pings[seq]
    if not probe or probe.target ~= name or probe.route ~= distribution then return end
    self.pings[seq] = nil
    local rtt = at - (probe.sentAt or probe.queuedAt)
    say(FD.Locale:Format("PONG from %s via %s: %.2f s round trip", name, distribution, rtt))
    FD.Debug:Log("ping", distribution, string.format("%.3f", rtt))
end

-- Events only record facts and schedule a Tick. Handlers run through
-- Presence:Run, so discovery failures never reach Core's duel recovery.
local function on(event, handler, optional)
    FD:OnEvent(event, function(...)
        local args, count = { ... }, select("#", ...)
        Presence:Run(function() handler(unpack(args, 1, count)) end)
    end, true, optional)
end
local function zoneShown() return FD.Zone and FD.Zone.IsShown and FD.Zone:IsShown() end
on("CHAT_MSG_ADDON", function(...) Presence:Receive(...) end)
on("PLAYER_ENTERING_WORLD", function() Presence:Enter() end)
on("PLAYER_LEAVING_WORLD", function() Presence:Leave(false) end)
on("PLAYER_LOGOUT", function() Presence:Leave(true) end)
-- A new map changes the own profile; Announce pushes it (rate limited).
on("ZONE_CHANGED_NEW_AREA", function() Presence:Wake(0) end)
on("PLAYER_TARGET_CHANGED", function() if zoneShown() then Presence:Wake(0) end end)
on("UPDATE_MOUSEOVER_UNIT", function() if zoneShown() then Presence:Wake(0) end end, true)
for _, event in ipairs({ "CHANNEL_UI_UPDATE", "CHANNEL_ROSTER_UPDATE", "CHANNEL_COUNT_UPDATE",
    "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_NOTICE" }) do
    on(event, function(...) if FD.Roster then FD.Roster:OnEvent(event, ...) end; Presence:Wake(0) end)
end
for _, event in ipairs({ "CHAT_MSG_CHANNEL_LEAVE", "CHANNEL_PASSWORD_REQUEST" }) do
    on(event, function(...) if FD.Roster then FD.Roster:OnEvent(event, ...) end; Presence:Wake(0) end, true)
end

FD:RegisterCommand("quiet", function()
    local settings = FD.Database.data.settings
    settings.quiet = not settings.quiet
    Presence:Run(function() Presence:QuietChanged() end)
    say(settings.quiet and FD.L["Quiet mode on: zone discovery and the channel directory send nothing. /duelrating ping still works."]
        or FD.L["Quiet mode off: on-demand zone discovery resumed."])
end, "Toggle quiet mode: discovery sends nothing (for latency A/B tests).", 85)

FD:RegisterCommand("ping", function(_, rawRest)
    Presence:Run(function() Presence:Ping(rawRest) end)
end, "Measure the addon message round trip to your target or a named player.", 84)

FD:RegisterStatus(30, function()
    local L, Format = FD.L, function(...) return FD.Locale:Format(...) end
    local lines = {}
    local zoneStatus = Presence:Run(function() return Presence:GetStatus() end)
    lines[#lines + 1] = Format("Zone discovery: %s", zoneStatus or L["unavailable"])
    lines[#lines + 1] = Format("Discovery route: %s | Quiet mode: %s | Pending whispers: %d",
        Presence:ChannelMode() and L["CHANNEL broadcasts"] or L["on-demand whispers"],
        Presence:Quiet() and L["on"] or L["off"], Presence.workCount)
    if Presence.lastChannelSend then lines[#lines + 1] = Format("Zone channel send: %s", Presence.lastChannelSend) end
    if Presence.lastWhisper then lines[#lines + 1] = Format("Zone whisper: %s", Presence.lastWhisper) end
    if FD.Roster and FD.Roster.status then lines[#lines + 1] = Format("Zone roster: %s", FD.Roster.status) end
    if Presence.lastReceive then lines[#lines + 1] = Format("Zone receive: %s", Presence.lastReceive) end
    return lines
end)
