local _, FD = ...

-- Advisory profiles never supply rated-duel consent, snapshots, or evidence.
FD.Presence = { players = {}, suspended = false, dirty = true,
    whispers = {}, queries = {}, replies = {} }
local Presence = FD.Presence
local PREFIX, CHANNEL = "ForeverDuelZone2", "ForeverDuel"
local HEARTBEAT, AREA_HEARTBEAT, EXPIRY, MIN_SEND, MAX_PLAYERS = 45, 15, 120, 5, 300
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

-- Discovery/UI errors must never enter Core:Safe, which cancels rated flow.
function Presence:Run(callback)
    local ok, result, reason = pcall(callback)
    if ok then return result, reason end
    self.status = "Zone discovery temporarily unavailable."
    pcall(function()
        if FD.Wow:Readable(result) then FD.Debug:Log("zone discovery error", result) end
    end)
    return nil, self.status
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

function Presence:GetPlayer(guid)
    if not FD.Wow:Readable(guid) or not FD.Protocol:ValidGUID(guid) then return nil end
    local player = self.players[guid]
    if not player or self.suspended or GetTime() - player.lastSeen >= EXPIRY then return nil end
    return FD.Copy(player)
end

function Presence:GetPlayers()
    local list, mapID = {}, self:MapID()
    if not mapID or self.suspended then return list end
    for guid in pairs(self.players) do
        local player = self:GetPlayer(guid)
        if player and player.mapID == mapID then list[#list + 1] = player end
    end
    table.sort(list, function(a, b)
        if a.fullName == b.fullName then return a.guid < b.guid end
        return a.fullName < b.fullName
    end)
    return list
end

function Presence:GetStatus()
    if self.initialized and not self.available then
        return self.status or "Zone discovery is unavailable on this client."
    end
    if self.suspended then return "Waiting for the world to load." end
    if not self:MapID() then return "Current zone is unavailable; waiting for map information." end
    if self.available and not self:GetOwnPlayer() then return "Waiting for your character level and level cap." end
    if self.available and #self:GetPlayers() > 0 then
        return string.format("%d addon players discovered in this zone.", #self:GetPlayers())
    end
    return (FD.Roster and FD.Roster.status) or self.status or "Zone discovery is not connected."
end

function Presence:Refresh()
    if FD.Zone then FD.Zone:RefreshIfShown() end
end

function Presence:ChannelID()
    if type(GetChannelName) ~= "function" then return nil end
    local id = GetChannelName(CHANNEL)
    if FD.Wow:Readable(id) and integer(id, 1, 100) then return id end
end

-- Native addon whispers supplement automatic local-area announcements.
-- Only a received profile establishes addon presence; seeing a unit does not.
function Presence:QueueWhisper(sender, request)
    if not validName(sender) or #self.whispers >= MAX_PLAYERS then return end
    local now = GetTime()
    local last = (request and self.queries or self.replies)[sender]
    if last and now - last < (request and HEARTBEAT or MIN_SEND) then return end
    for _, item in ipairs(self.whispers) do
        if item.sender == sender then
            if not request then item.request = false end
            return
        end
    end
    self.whispers[#self.whispers + 1] = { sender = sender, request = request, queuedAt = now }
    self:ScheduleWhisper()
end

function Presence:ScheduleWhisper()
    if self.whisperTimer or #self.whispers == 0 or self.suspended or self.stopped then return end
    self.whisperTimer = true
    C_Timer.After(1, function()
        self.whisperTimer = false
        self:Run(function() self:SendWhisper() end)
        self:ScheduleWhisper()
    end)
end

function Presence:SendWhisper()
    if not self.available or self.suspended or self.stopped then return end
    local now = GetTime()
    local item = table.remove(self.whispers, 1)
    if not item then return end
    if now - item.queuedAt >= EXPIRY then return end
    if item.retryAt and now < item.retryAt then
        self.whispers[#self.whispers + 1] = item
        return
    end
    local payload = self:Encode(self:GetOwnPlayer())
    if not payload then return end
    if item.request then payload = "FDQ2" .. payload:sub(5) end
    self.lastWhisperSend = (item.request and "query to " or "profile to ") .. item.sender
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, payload, "WHISPER", item.sender)
    local values = Enum and Enum.SendAddonMessageResult
    if ok and FD.Wow:Readable(result) and values and result == values.Success then
        (item.request and self.queries or self.replies)[item.sender] = now
        self.lastWhisperSend = self.lastWhisperSend .. " (submitted)"
    else
        item.retryAt = now + MIN_SEND
        self.whispers[#self.whispers + 1] = item
        self.lastWhisperSend = self.lastWhisperSend .. " (retrying)"
    end
    FD.Debug:Log("zone whisper send", self.lastWhisperSend)
end

function Presence:ScanNearby()
    local own = self:GetOwnPlayer()
    if not own or not own.mapID or type(UnitIsPlayer) ~= "function" then return end
    local units = { "target", "focus" }
    for i = 1, 4 do units[#units + 1] = "party" .. i end
    for i = 1, 40 do
        units[#units + 1] = "raid" .. i
        units[#units + 1] = "nameplate" .. i
    end
    for _, unit in ipairs(units) do
        local isPlayer = UnitIsPlayer(unit)
        if FD.Wow:Readable(isPlayer) and isPlayer then
            local identity = FD.Wow:Identity(unit)
            if identity and identity.guid ~= own.guid then self:QueueWhisper(identity.fullName, true) end
        end
    end
end

function Presence:Encode(player)
    if not player or not FD.Protocol:ValidGUID(player.guid)
        or not integer(player.rating, -100000, 100000)
        or not integer(player.mapID, 1, 10000000) or not classes[player.classFile]
        or not FD.Rating:Bracket(player.level, player.maxLevel) then return nil end
    return table.concat({ "FDP2", player.guid, string.format("%.0f", player.rating),
        string.format("%.0f", player.mapID), player.classFile,
        string.format("%.0f", player.level), string.format("%.0f", player.maxLevel) }, "|")
end

function Presence:Decode(payload)
    if not FD.Wow:Readable(payload) or type(payload) ~= "string" or #payload > 255 then return nil end
    local guid, rating, mapID, class, level, maxLevel = payload:match("^FDP2|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if not guid or not FD.Protocol:ValidGUID(guid) or not classes[class] then return nil end
    rating, mapID = number(rating, -100000, 100000), number(mapID, 1, 10000000)
    level, maxLevel = number(level, 1, 1000), number(maxLevel, 1, 1000)
    local bracket = FD.Rating:Bracket(level, maxLevel)
    if not rating or not mapID or not bracket then return nil end
    return { guid = guid, rating = rating, mapID = mapID, classFile = class,
        level = level, maxLevel = maxLevel, bracket = bracket }
end

function Presence:Receive(prefix, payload, distribution, sender, target, zoneChannelID, localID)
    if not self.available or self.suspended or not FD.Wow:Readable(prefix, payload, distribution, sender, localID)
        or prefix ~= PREFIX then return end
    local area = distribution == "YELL" or distribution == "SAY" or distribution == "UNKNOWN"
    if area then
        -- Classic can label local addon broadcasts UNKNOWN. Require the exact
        -- ASCII beacon format before passing it to the shared profile parser.
        -- Chat-safe separators avoid treating pipe-delimited data as markup.
        if type(payload) ~= "string" or #payload > 255
            or not payload:match("^FDP2:[%w:%-]+$") then return end
        payload = payload:gsub(":", "|")
    elseif distribution == "CHANNEL" then
        -- Receive legacy profiles only if already in the matching channel.
        -- Classic does not support this route for automatic addon broadcasts.
        local channelID = self:ChannelID()
        if not channelID or localID ~= channelID then return end
    elseif distribution ~= "WHISPER" then return end
    local request = type(payload) == "string" and payload:sub(1, 5) == "FDQ2|"
    if request then
        if distribution ~= "WHISPER" then return end
        payload = "FDP2" .. payload:sub(5)
    end
    local player, own = self:Decode(payload), self:GetOwnPlayer()
    if not player or not own or player.guid == own.guid or not validName(sender) then return end
    local regional = RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled()
    if not FD.Wow:Readable(regional) then return end
    if not regional and not sender:find("-", 1, true) then
        local realm = GetNormalizedRealmName()
        if not FD.Wow:Readable(realm) or not validName(realm) then return end
        sender = sender .. "-" .. realm
    end
    if not validName(sender) or sender == own.fullName then return end
    -- The native event has no sender GUID. Keep a live GUID bound to its
    -- transport name; tooltip/challenge also require native unit agreement.
    local old = self:GetPlayer(player.guid)
    if old and old.fullName ~= sender then return end
    local count, oldestGUID, oldestTime = 0, nil, math.huge
    for guid, cached in pairs(self.players) do
        if GetTime() - cached.lastSeen >= EXPIRY or cached.fullName == sender then
            self.players[guid] = nil
        else
            count = count + 1
            if cached.lastSeen < oldestTime then oldestGUID, oldestTime = guid, cached.lastSeen end
        end
    end
    if count >= MAX_PLAYERS and oldestGUID then self.players[oldestGUID] = nil end
    player.fullName, player.lastSeen = sender, GetTime()
    self.players[player.guid] = player
    self.lastReceive = sender .. " (" .. distribution .. ", map " .. player.mapID .. ")"
    FD.Debug:Log("zone presence received", self.lastReceive)
    if request then self:QueueWhisper(sender, false) end
    self:Refresh()
end

function Presence:Tick()
    if not self.available or self.suspended then return end
    local now = GetTime()
    for guid, player in pairs(self.players) do
        if now - player.lastSeen >= EXPIRY then self.players[guid] = nil end
    end
    for _, sent in ipairs({ self.queries, self.replies }) do
        for sender, at in pairs(sent) do
            if now - at >= EXPIRY then sent[sender] = nil end
        end
    end
    -- A failed native unit scan must not suppress untargeted discovery.
    self:Run(function() self:ScanNearby() end)
    if FD.Roster then self:Run(function() FD.Roster:Tick() end) end
    local own = self:GetOwnPlayer()
    local payload = self:Encode(own)
    if payload and not self.areaUnsupported then
        payload = payload:gsub("|", ":")
        if payload ~= self.lastPayload then self.dirty = true end
        if (self.dirty or not self.lastAttempt or now - self.lastAttempt >= AREA_HEARTBEAT)
            and (not self.lastAttempt or now - self.lastAttempt >= MIN_SEND) then
            self.lastAttempt = now
            self.dirty = true -- Keep a thrown native send eligible for the next paced retry.
            -- Classic supports invisible addon broadcasts in the surrounding
            -- area via YELL; custom CHANNEL submissions need not be delivered.
            -- This is never an ordinary SendChatMessage or rated consent.
            self.lastSend = "YELL area broadcast (attempting)"
            local result = C_ChatInfo.SendAddonMessage(PREFIX, payload, "YELL")
            local values = Enum and Enum.SendAddonMessageResult
            if FD.Wow:Readable(result) and values and result == values.Success then
                self.lastPayload, self.dirty = payload, false
                self.status = "Searching the surrounding area automatically; allow up to 15 seconds."
                self.lastSend = "YELL area broadcast (submitted)"
            elseif FD.Wow:Readable(result) and values and type(values.InvalidChatType) == "number"
                and result == values.InvalidChatType then
                -- A permanent unsupported route cannot recover by retrying.
                self.areaUnsupported = true
                self.status = "Area broadcasts unsupported on this client; direct discovery remains available."
                self.lastSend = "YELL unavailable (InvalidChatType); retries stopped"
            else
                self.dirty = true
                self.status = "Area announcement delayed; retrying. Direct target discovery is available."
                local code = FD.Wow:Readable(result) and tostring(result) or "restricted"
                self.lastSend = "YELL area broadcast (rejected: " .. code .. ")"
            end
            FD.Debug:Log("zone presence send", self.lastSend)
        end
    end
    self:Refresh()
end

function Presence:Changed()
    -- Tick compares the profile, so unrelated duel renders cannot cause spam.
    return self:Run(function() self:Tick() end)
end

function Presence:Initialize()
    return self:Run(function()
        if self.initialized then return self.available end
        self.initialized = true
        if not C_ChatInfo or type(C_ChatInfo.RegisterAddonMessagePrefix) ~= "function"
            or type(C_ChatInfo.SendAddonMessage) ~= "function"
            or not C_Timer or type(C_Timer.After) ~= "function" then
            self.status = "Zone discovery is unavailable on this client."
            return false
        end
        local result = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        local values = Enum and Enum.RegisterAddonMessagePrefixResult
        self.available = FD.Wow:Readable(result) and values
            and (result == values.Success or result == values.DuplicatePrefix) or false
        if not self.available then self.status = "Zone discovery prefix could not be registered."; return false end
        self.status = "Starting zone discovery..."
        self.frame = CreateFrame("Frame")
        local events = { "CHAT_MSG_ADDON", "PLAYER_ENTERING_WORLD",
            "PLAYER_LEAVING_WORLD", "PLAYER_LOGOUT", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
            "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "NAME_PLATE_UNIT_ADDED", "GROUP_ROSTER_UPDATE",
            "CHANNEL_ROSTER_UPDATE", "CHANNEL_COUNT_UPDATE", "CHANNEL_UI_UPDATE",
            "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_NOTICE" }
        for _, event in ipairs(events) do self.frame:RegisterEvent(event) end
        self.frame:SetScript("OnEvent", function(_, event, ...)
            local args, count = { ... }, select("#", ...)
            self:Run(function()
                if event == "CHAT_MSG_ADDON" then self:Receive(unpack(args, 1, count))
                elseif event == "PLAYER_LEAVING_WORLD" or event == "PLAYER_LOGOUT" then
                    if FD.Roster then self:Run(function() FD.Roster:Reset() end) end
                    self.players, self.suspended = {}, true
                    self.whispers, self.queries, self.replies = {}, {}, {}
                    if event == "PLAYER_LOGOUT" then self.stopped = true end
                    self:Refresh()
                else
                    if FD.Roster and (event:find("CHANNEL", 1, true)) then
                        FD.Roster:OnEvent(event, unpack(args, 1, count))
                        return
                    end
                    if event == "PLAYER_ENTERING_WORLD" then
                        self.suspended, self.dirty = false, true
                    end
                    self:Tick()
                end
            end)
        end)
        local function pulse()
            if self.stopped then return end
            self:Run(function() self:Tick() end)
            C_Timer.After(MIN_SEND, pulse)
        end
        C_Timer.After(1, pulse)
        return true
    end)
end

function Presence:Challenge(guid)
    return self:Run(function()
        local player = self:GetPlayer(guid)
        if not player or player.mapID ~= self:MapID() then return false, "This player is no longer listed in your zone." end
        if InCombatLockdown() then return false, "Leave combat before requesting a duel." end
        if not FD.duel or FD.duel.active or FD.Wow.outgoing then return false, "Finish the current duel request first." end
        if type(StartDuel) ~= "function" then return false, "Duel requests are unavailable on this client." end
        local units = { "target", "mouseover", "focus" }
        for i = 1, 4 do units[#units + 1] = "party" .. i end
        for i = 1, 40 do
            units[#units + 1] = "raid" .. i
            units[#units + 1] = "nameplate" .. i
        end
        for _, unit in ipairs(units) do
            local identity = FD.Wow:Identity(unit)
            if identity and identity.guid == player.guid and identity.fullName == player.fullName then
                local isPlayer = UnitIsPlayer(unit)
                if FD.Wow:Readable(isPlayer) and isPlayer then
                    -- Existing secure hook captures this native unit. Only the
                    -- server acknowledgment may begin rated negotiation.
                    StartDuel(unit, true)
                    return true
                end
            end
        end
        return false, "Move closer and target this player, then click Duel again."
    end)
end

-- Stable lookup API for other modules (queue transport/candidates). The
-- internal storage of `players` is private to this module.
function Presence:FindByName(fullName)
    if type(fullName) ~= "string" or self.suspended then return nil end
    for guid in pairs(self.players) do
        local player = self:GetPlayer(guid)
        if player and FD.Wow:Readable(player.fullName) and player.fullName == fullName then return player end
    end
end

function Presence:Candidates()
    local result = {}
    if self.suspended then return result end
    for guid in pairs(self.players) do
        local player = self:GetPlayer(guid)
        if player then result[#result + 1] = player end
    end
    return result
end

FD:RegisterStatus(30, function()
    local lines = {}
    local zoneStatus = Presence:Run(function() return Presence:GetStatus() end)
    lines[#lines + 1] = "Zone discovery: " .. (zoneStatus or "unavailable")
    if Presence.lastSend then lines[#lines + 1] = "Zone send: " .. Presence.lastSend end
    if Presence.lastWhisperSend then lines[#lines + 1] = "Zone whisper: " .. Presence.lastWhisperSend end
    if FD.Roster and FD.Roster.status then lines[#lines + 1] = "Zone roster: " .. FD.Roster.status end
    if Presence.lastReceive then lines[#lines + 1] = "Zone receive: " .. Presence.lastReceive end
    return lines
end)
