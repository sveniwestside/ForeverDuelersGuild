local _, FD = ...

-- All native queue actions are isolated from Core:Safe: a queue API failure
-- must never stop an unrelated rated duel or modify its evidence.
FD.QueueWow = {}
local Wow = FD.QueueWow

local function readable(...)
    if FD.Wow and type(FD.Wow.Readable) == "function" then return FD.Wow:Readable(...) end
    for i = 1, select("#", ...) do
        if type(issecretvalue) == "function" and issecretvalue(select(i, ...)) then return false end
    end
    return true
end

local function finite(value, low, high)
    return readable(value) and type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and (not low or value >= low) and (not high or value <= high)
end

local function integer(value, low, high)
    return finite(value, low, high) and value % 1 == 0
end

local function text(value, maximum)
    return readable(value) and type(value) == "string" and #value > 0
        and #value <= (maximum or 128) and not value:find("[%c|]")
end

local function call(callback, ...)
    if type(callback) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(callback, ...)
    if not ok or not readable(a, b, c, d) then return nil end
    return a, b, c, d
end

local function now()
    local value = call(GetTime)
    return finite(value, 0) and value or 0
end

local function epoch()
    local value = call(GetServerTime)
    return integer(value, 0) and value or 0
end

local function vectorXY(vector)
    if not readable(vector) or type(vector) ~= "table" or type(vector.GetXY) ~= "function" then return nil end
    local x, y = call(vector.GetXY, vector)
    if finite(x, -1000000, 1000000) and finite(y, -1000000, 1000000) then return x, y end
end

local function settingsRoot()
    local data = FD.Database and FD.Database.data
    if not data or type(data.settings) ~= "table" then return nil end
    if type(data.settings.queue) ~= "table" then data.settings.queue = {} end
    return data.settings.queue
end

-- Forever exposes its actual ruleset as named native game rules. Read those
-- rules rather than a saved preference, realm name, or the player's PvP flag.
function Wow:Ruleset()
    local rules = Enum and Enum.GameRule
    if not C_GameRules or type(C_GameRules.IsGameRuleActive) ~= "function" or type(rules) ~= "table" then
        return nil, "Waiting for native ruleset information."
    end
    for _, rule in ipairs({ { "HardcoreRuleset", "HARDCORE" }, { "RPRuleset", "RP" }, { "PvPRuleset", "PVP" } }) do
        local id = rules[rule[1]]
        if not integer(id, 0, 1000000) then return nil, "Native ruleset identifiers are unavailable." end
        local active = call(C_GameRules.IsGameRuleActive, id)
        if type(active) ~= "boolean" then return nil, "Native ruleset information is unavailable or restricted." end
        if active then return rule[2] end
    end
    return "NORMAL"
end

function Wow:Settings()
    local stored = settingsRoot() or {}
    local scope = stored.scope
    if not readable(scope) or (scope ~= "ZONE" and scope ~= "CONTINENT" and scope ~= "RULESET") then scope = "ZONE" end
    local gap = integer(stored.levelGap, 0, 5) and stored.levelGap or 5
    local ruleset, rulesetReason = self:Ruleset()
    -- Retire manual choices from earlier queue versions. A previously saved
    -- value cannot mask an unavailable or changed native ruleset.
    stored.ruleset, stored.continentVerified, stored.rulesetVerified = nil, nil, nil
    local blocked = {}
    if type(stored.blockedOpponents) == "table" then
        for guid, untilAt in pairs(stored.blockedOpponents) do
            if text(guid, 64) and integer(untilAt, epoch()) then blocked[guid] = untilAt end
        end
    end
    return { scope = scope, levelGap = gap, ruleset = ruleset, rulesetReason = rulesetReason,
        rulesetSource = ruleset and "C_GameRules.IsGameRuleActive" or nil,
        cooldownUntil = integer(stored.cooldownUntil, 0) and stored.cooldownUntil or 0,
        blockedOpponents = blocked }
end

function Wow:Save(settings)
    if type(settings) ~= "table" then return false end
    local stored = settingsRoot()
    if not stored then return false end
    if readable(settings.scope) and (settings.scope == "ZONE" or settings.scope == "CONTINENT" or settings.scope == "RULESET") then stored.scope = settings.scope end
    if integer(settings.levelGap, 0, 5) then stored.levelGap = settings.levelGap end
    stored.ruleset, stored.continentVerified, stored.rulesetVerified = nil, nil, nil
    if integer(settings.cooldownUntil, 0) then stored.cooldownUntil = settings.cooldownUntil end
    if type(settings.blockedOpponents) == "table" then
        stored.blockedOpponents = {}
        for guid, untilAt in pairs(settings.blockedOpponents) do
            if text(guid, 64) and integer(untilAt, epoch()) then stored.blockedOpponents[guid] = untilAt end
        end
    end
    if type(settings.venues) == "table" then
        local copied = FD.Database:Copy(settings.venues)
        if copied then stored.venues = copied end
    end
    return true
end

function Wow:World(mapID, mapX, mapY)
    if not integer(mapID, 1, 10000000) or not finite(mapX, 0, 1) or not finite(mapY, 0, 1)
        or not C_Map or type(C_Map.GetWorldPosFromMapPos) ~= "function" or type(CreateVector2D) ~= "function" then return nil end
    local vector = call(CreateVector2D, mapX, mapY)
    if not vector then return nil end
    local continentID, position = call(C_Map.GetWorldPosFromMapPos, mapID, vector)
    if not integer(continentID, 0, 10000000) then return nil end
    local x, y = vectorXY(position)
    if x and y then return continentID, x, y end
end

function Wow:Position()
    if not C_Map then return nil, "Player map APIs are unavailable." end
    local mapID = call(C_Map.GetBestMapForUnit, "player")
    if not integer(mapID, 1, 10000000) then return nil, "Current zone is unavailable." end
    -- Each participant supplies their own position. Party APIs never substitute
    -- coordinates or remote observation timestamps for the peer's report.
    local mapX, mapY = vectorXY(call(C_Map.GetPlayerMapPosition, mapID, "player"))
    if not finite(mapX, 0, 1) or not finite(mapY, 0, 1) then return nil, "Player position is unavailable." end
    local continentID, x, y = self:World(mapID, mapX, mapY)
    if not continentID then return nil, "World position conversion is unavailable." end
    return { mapID = mapID, mapX = mapX, mapY = mapY, continentID = continentID,
        x = x, y = y, positionAt = epoch() }
end

function Wow:Own()
    if not FD.Wow or type(FD.Wow.Identity) ~= "function" then return nil end
    local ok, identity = pcall(FD.Wow.Identity, FD.Wow, "player", true)
    if not ok or type(identity) ~= "table" or not readable(identity.guid, identity.fullName, identity.level, identity.maxLevel)
        or not text(identity.guid, 64) or not text(identity.fullName)
        or not integer(identity.maxLevel, 1, 255) or not integer(identity.level, 1, identity.maxLevel) then return nil end
    local faction = call(UnitFactionGroup, "player")
    if faction ~= "Alliance" and faction ~= "Horde" then return nil end
    local bracket = FD.Rating and FD.Rating:Bracket(identity.level, identity.maxLevel)
    local stats = bracket and FD.Database and FD.Database:GetStats(bracket)
    if not stats or not integer(stats.rating, -100000, 100000) then return nil end
    local position = self:Position() or { mapID = 0, continentID = 0, x = 0, y = 0, positionAt = 0 }
    position.x, position.y = math.floor(position.x + 0.5), math.floor(position.y + 0.5)
    local settings = self:Settings()
    position.guid, position.fullName, position.level, position.maxLevel = identity.guid, identity.fullName, identity.level, identity.maxLevel
    position.rating, position.bracket, position.faction = stats.rating, bracket, faction
    position.scope, position.levelGap, position.ruleset = settings.scope, settings.levelGap, settings.ruleset
    return position
end

function Wow:Solo()
    local grouped = call(IsInGroup)
    local raid = call(IsInRaid)
    -- Missing group APIs are not evidence that it is safe to invite/leave.
    return type(grouped) == "boolean" and grouped == false and type(raid) == "boolean" and raid == false
end

function Wow:Combat()
    local value = call(InCombatLockdown)
    return type(value) ~= "boolean" or value
end

function Wow:Available()
    if not FD.QueueTransport or not FD.QueueTransport.available then return false, "Queue addon transport is unavailable." end
    local blockedUntil = FD.Wow and FD.Wow.outgoingBlockedUntil
    local nativeBlocked = finite(blockedUntil) and now() < blockedUntil
    if (FD.duel and FD.duel.active) or (FD.Wow and (FD.Wow.outgoing or FD.Wow.pendingIncoming)) or nativeBlocked then
        return false, "Finish the current native duel request before joining the queue."
    end
    if not self:Solo() then return false, "Queue requires a confirmed solo character." end
    local dead = call(UnitIsDeadOrGhost, "player")
    if type(dead) ~= "boolean" or dead then return false, "Queue requires a living character." end
    local instance = call(IsInInstance)
    if type(instance) ~= "boolean" or instance then return false, "Queue requires the open world." end
    local outdoors = call(IsOutdoors)
    if type(outdoors) ~= "boolean" or not outdoors then return false, "Queue requires an outdoor location." end
    if not self:Own() then return false, "Queue requires readable identity, faction, rating and position." end
    local settings = self:Settings()
    if not settings.ruleset then return false, settings.rulesetReason end
    return true
end

function Wow:PartyUnit(peer)
    if type(peer) ~= "table" or not text(peer.guid, 64) or not text(peer.fullName) then return nil end
    if call(IsInRaid) ~= false or call(IsInGroup) ~= true or call(GetNumGroupMembers) ~= 2 then return nil end
    if not FD.Wow or type(FD.Wow.Identity) ~= "function" then return nil end
    local ok, identity = pcall(FD.Wow.Identity, FD.Wow, "party1")
    if ok and type(identity) == "table" and readable(identity.guid, identity.fullName)
        and identity.guid == peer.guid and identity.fullName == peer.fullName then return "party1" end
end

function Wow:Party(peer)
    if self:PartyUnit(peer) then return true end
    return false, "Waiting for the exact two-player queue group."
end

-- Group membership and party unit data need not become readable together.
-- Missing data is a pending verification, never proof of a different group.
-- Only PartyUnit's exact identity check authorizes planning or group cleanup.
function Wow:GroupState(peer)
    if type(peer) ~= "table" or not text(peer.guid, 64) or not text(peer.fullName) then return "PENDING" end
    local raid, grouped = call(IsInRaid), call(IsInGroup)
    if raid == true then return "CHANGED" end
    if raid ~= false or type(grouped) ~= "boolean" then return "PENDING" end
    if grouped == false then return "SOLO" end
    local members = call(GetNumGroupMembers)
    if not integer(members, 0, 40) then return "PENDING" end
    if members > 2 then return "CHANGED" end
    if members ~= 2 then return "PENDING" end
    if self:PartyUnit(peer) then return "EXACT" end
    -- A readable native GUID can establish a wrong opponent even while its
    -- name/class are loading. Restricted/absent GUIDs cannot establish that.
    local guid = call(UnitGUID, "party1")
    if FD.QueueProtocol:ValidGUID(guid) and guid ~= peer.guid then return "CHANGED" end
    if FD.Wow and type(FD.Wow.Identity) == "function" then
        local ok, identity = pcall(FD.Wow.Identity, FD.Wow, "party1")
        if ok and type(identity) == "table" and readable(identity.guid, identity.fullName)
            and FD.QueueProtocol:ValidGUID(identity.guid) then
            if identity.guid ~= peer.guid or text(identity.fullName) and identity.fullName ~= peer.fullName then
                return "CHANGED"
            end
        end
    end
    return "PENDING"
end

function Wow:Invite(peer)
    if type(peer) ~= "table" or not text(peer.fullName) then return false, "Opponent identity is unavailable." end
    if not self:Solo() then return false, "Cannot invite while grouped." end
    if self:Combat() then return false, "Use Invite opponent after leaving combat." end
    local invite = C_PartyInfo and C_PartyInfo.InviteUnit or InviteUnit
    if type(invite) ~= "function" then return false, "Native invitation API is unavailable; invite the opponent manually." end
    if C_PartyInfo and type(C_PartyInfo.CanInvite) == "function" and call(C_PartyInfo.CanInvite) ~= true then
        return false, "Native invitation permission is unavailable; invite the opponent manually."
    end
    local ok, result = pcall(invite, peer.fullName)
    if not ok or not readable(result) or result == false then return false, "Automatic invitation was blocked; use Invite opponent." end
    -- A nil return indicates an attempt, not confirmation. Only Party(peer)
    -- confirms acceptance; the recipient always uses Blizzard's native dialog.
    return true
end

function Wow:Leave(peer, owned)
    if owned ~= true or not self:PartyUnit(peer) then return false end
    local leave = C_PartyInfo and C_PartyInfo.LeaveParty or LeaveParty
    if type(leave) ~= "function" or self:Combat() then return false end
    local ok, result = pcall(leave)
    return ok and readable(result) and result ~= false
end

function Wow:CoLocated(peer)
    local unit = self:PartyUnit(peer)
    if not unit then return false, "Opponent group identity is unavailable." end
    if call(UnitIsVisible, unit) ~= true then return false, "Opponent is not visible in this phase." end
    if type(UnitPhaseReason) == "function" then
        local ok, phaseReason = pcall(UnitPhaseReason, unit)
        if not ok or not readable(phaseReason) or phaseReason ~= nil then return false, "Opponent phase is incompatible or unavailable." end
    elseif type(UnitInPhase) == "function" then
        if call(UnitInPhase, unit) ~= true then return false, "Opponent is in another phase." end
    else return false, "Native phase verification is unavailable." end
    local x, y, z, instanceID = call(UnitPosition, "player")
    local peerX, peerY, peerZ, peerInstanceID = call(UnitPosition, unit)
    if not finite(x) or not finite(y) or not finite(z) or not integer(instanceID, 0)
        or not finite(peerX) or not finite(peerY) or not finite(peerZ) or not integer(peerInstanceID, 0) then
        return false, "Native distance data is unavailable."
    end
    if instanceID ~= peerInstanceID then return false, "Opponent is in another world instance." end
    if (x - peerX) ^ 2 + (y - peerY) ^ 2 > 100 or math.abs(z - peerZ) > 5 then
        return false, "Move within 10 yards of the opponent on the same level."
    end
    return true
end

function Wow:Challenge(peer)
    local located, reason = self:CoLocated(peer)
    if not located then return false, reason end
    if self:Combat() then return false, "Leave combat before requesting the duel." end
    if type(StartDuel) ~= "function" then return false, "Native duel API is unavailable; request the duel manually." end
    local ok, result = pcall(StartDuel, "party1")
    if not ok or not readable(result) or result == false then return false, "Native duel request was blocked; request the duel manually." end
    return true
end

function Wow:Candidates()
    local candidates = {}
    if not FD.Presence or FD.Presence.suspended or type(FD.Presence.players) ~= "table" then return candidates end
    for guid in pairs(FD.Presence.players) do
        local player = FD.Presence:GetPlayer(guid)
        if player and text(player.fullName) then candidates[#candidates + 1] = player end
    end
    table.sort(candidates, function(a, b) return a.guid < b.guid end)
    return candidates
end

function Wow:Catalog()
    local catalog = {}
    local stored = settingsRoot()
    local compiled = FD.Venues and FD.Venues.Catalog
    local byID = {}
    for _, source in ipairs({ compiled or {}, stored and stored.venues or {} }) do
        if type(source) == "table" then
            for _, venue in ipairs(source) do
                if type(venue) == "table" and readable(venue.verified, venue.duelAllowed)
                    and venue.verified == true and venue.duelAllowed == true and text(venue.id, 48) then
                    if byID[venue.id] then catalog[byID[venue.id]] = venue
                    else catalog[#catalog + 1] = venue; byID[venue.id] = #catalog end
                end
            end
        end
    end
    return catalog
end

function Wow:Discover()
    local presence = FD.Presence
    if not presence then return false end
    -- Immediate discovery is optional. Each route is isolated so a failed
    -- native scan/directory request cannot fail the queue admission itself.
    if type(presence.Changed) == "function" then pcall(presence.Changed, presence) end
    if type(presence.ScanNearby) == "function" then pcall(presence.ScanNearby, presence) end
    return true
end

local function samePlace(a, b, radius)
    return a and b and a.mapID == b.mapID and a.continentID == b.continentID
        and finite(a.x) and finite(a.y) and finite(b.x) and finite(b.y)
        and (a.x - b.x)^2 + (a.y - b.y)^2 <= radius^2
end

-- Zone metadata only: these records contain no duel locations or coordinates.
-- Classic ownership/1-12 ranges: LibTouristClassicEra WoW-1.15.8-release1,
-- commit 46c51b793a7e0f426f37c431fc10994af81e8973 (MIT), author release:
-- https://www.wowace.com/projects/libtourist-classic-era/files/7182873
-- Retail map aliases are accepted only with a native level cap of 60 and the
-- exact native zone/map-parent identity; they do not import Retail scaling.
local CLASSIC_ZONES = {
    [1429] = { faction = "Alliance", parent = 1415 }, -- Elwynn Forest
    [1426] = { faction = "Alliance", parent = 1415 }, -- Dun Morogh
    [1438] = { faction = "Alliance", parent = 1414 }, -- Teldrassil
    [1411] = { faction = "Horde", parent = 1414 },    -- Durotar
    [1412] = { faction = "Horde", parent = 1414 },    -- Mulgore
    [1420] = { faction = "Horde", parent = 1415 },    -- Tirisfal Glades
    [37] = { faction = "Alliance", parent = 13 }, [27] = { faction = "Alliance", parent = 13 },
    [57] = { faction = "Alliance", parent = 12 }, [1] = { faction = "Horde", parent = 12 },
    [7] = { faction = "Horde", parent = 12 }, [18] = { faction = "Horde", parent = 13 },
}

function Wow:ClassicZoneMetadata(mapID)
    if not integer(mapID, 1, 10000000) or not C_Map or not FD.Wow
        or type(FD.Wow.Identity) ~= "function" or call(C_Map.GetBestMapForUnit, "player") ~= mapID then return nil end
    local ok, identity = pcall(FD.Wow.Identity, FD.Wow, "player", true)
    if not ok or type(identity) ~= "table" or not readable(identity.maxLevel) or identity.maxLevel ~= 60 then return nil end
    local current, visited = mapID, {}
    for _ = 1, 6 do
        if visited[current] then return nil end
        visited[current] = true
        local info = call(C_Map.GetMapInfo, current)
        if type(info) ~= "table" or not readable(info.mapID, info.mapType, info.parentMapID)
            or info.mapID ~= current or not integer(info.parentMapID, 0, 10000000) then return nil end
        local record = CLASSIC_ZONES[current]
        if record then
            if info.mapType ~= 3 or info.parentMapID ~= record.parent then return nil end
            return { mapID = current, faction = record.faction, low = 1, high = 12, source = "CLASSIC" }
        end
        -- Only an explicitly identified outdoor micro-map may inherit its
        -- native parent zone. Unknown zones, cities and continents stop here.
        if info.mapType ~= 5 or info.parentMapID == 0 then return nil end
        current = info.parentMapID
    end
end

function Wow:MetadataDiagnostics()
    return FD.Copy(self.metadataDiagnostics or {})
end

local function territoryResult(getter)
    if type(getter) ~= "function" then return "missing" end
    local ok, territory, subzone, faction = pcall(getter)
    if not ok then return "error" end
    if not readable(territory, subzone, faction) then return "restricted" end
    if territory == nil and subzone == nil and faction == nil then return "missing" end
    if territory == nil and type(subzone) == "boolean" then return "available", nil end
    if type(territory) ~= "string" then return "invalid" end
    return "available", territory
end

function Wow:FriendlyTerritory()
    local mapID, faction = C_Map and call(C_Map.GetBestMapForUnit, "player"), call(UnitFactionGroup, "player")
    local diagnostics = self.metadataDiagnostics or {}
    self.metadataDiagnostics = diagnostics
    diagnostics.mapID, diagnostics.faction = mapID, faction
    local state, territory = territoryResult(C_PvP and C_PvP.GetZonePVPInfo)
    diagnostics.territoryGetter = "C_PvP.GetZonePVPInfo"
    if state == "missing" then
        state, territory = territoryResult(GetZonePVPInfo)
        diagnostics.territoryGetter = "C_PvP.GetZonePVPInfo (missing) -> GetZonePVPInfo"
    end
    diagnostics.territoryResult, diagnostics.territorySource = territory or (state == "available" and "neutral" or state), "NATIVE"
    if state ~= "available" and state ~= "missing" then
        return false, "Native territory information is " .. state .. "; this place cannot be saved."
    end
    local metadata = self:ClassicZoneMetadata(mapID)
    if metadata and metadata.faction ~= faction then
        diagnostics.territorySource = "CLASSIC"
        return false, "This territory is hostile to your faction; choose a friendly or contested outdoor place."
    end
    if state == "available" and (territory == "friendly" or territory == "contested" or territory == nil) then return true end
    if territory == "hostile" then return false, "This territory is hostile to your faction; choose a friendly or contested outdoor place." end
    if territory == "sanctuary" or territory == "arena" or territory == "combat" then
        return false, "This territory cannot be approved as an outdoor duel place."
    end
    if state == "missing" and metadata and metadata.faction == faction then
        diagnostics.territorySource = "CLASSIC"
        return true
    end
    return false, "Territory information is unavailable for this map; only known Classic starting zones have a metadata fallback."
end

local function nativeLevels(mapID)
    if not C_Map or type(C_Map.GetMapLevels) ~= "function" then return "missing" end
    local ok, low, high = pcall(C_Map.GetMapLevels, mapID)
    if not ok then return "error" end
    if not readable(low, high) then return "restricted" end
    if low == nil and high == nil or low == 0 and high == 0 then return "missing" end
    if integer(low, 1, 255) and integer(high, low, 255) then return "available", low, high end
    return "invalid"
end

function Wow:ZoneLevels(mapID)
    local diagnostics = self.metadataDiagnostics or {}
    self.metadataDiagnostics = diagnostics
    diagnostics.mapID = mapID
    local state, low, high = nativeLevels(mapID)
    if state == "available" then
        diagnostics.zoneLevelsSource = "NATIVE"
        return low, high, "NATIVE"
    end
    if state ~= "missing" then
        diagnostics.zoneLevelsSource = state
        return nil, nil, "Native zone level range is " .. state .. "; this place cannot be saved."
    end
    local metadata = self:ClassicZoneMetadata(mapID)
    if metadata then
        if metadata.mapID ~= mapID then
            state, low, high = nativeLevels(metadata.mapID)
            if state == "available" then
                diagnostics.zoneLevelsSource = "NATIVE_PARENT"
                return low, high, "NATIVE_PARENT"
            elseif state ~= "missing" then
                diagnostics.zoneLevelsSource = state
                return nil, nil, "Native parent zone level range is " .. state .. "; this place cannot be saved."
            end
        end
        diagnostics.zoneLevelsSource = "CLASSIC"
        return metadata.low, metadata.high, "CLASSIC"
    end
    diagnostics.zoneLevelsSource = "unavailable"
    return nil, nil, "Zone level range is unavailable for this map; only known Classic starting zones have a metadata fallback."
end

function Wow:FinishVenueTest()
    local pending = self.venueTestPending
    if not pending or not pending.finishedAt or not pending.winnerGUID or not pending.countdownAt then return end
    local position = self:Position()
    if now() - pending.requestedAt > 1200 or now() < pending.startedAt
        or not samePlace(position, pending.position, 40)
        or call(IsInInstance) ~= false or call(IsOutdoors) ~= true or not self:FriendlyTerritory() then self.venueTestPending = nil; return end
    local own = self:Own()
    if not own or own.guid ~= pending.player.guid or own.level ~= pending.player.level
        or own.faction ~= pending.faction then self.venueTestPending = nil; return end
    self.venueTest = { position = position, player = pending.player, peer = pending.peer,
        faction = own.faction, provedAt = epoch(), provedTick = now() }
    self.venueTestPending = nil
end

function Wow:ObserveDuel(kind, value)
    if kind == "request" then
        self.venueTest, self.venueTestPending = nil, nil
        local friendly, reason = self:FriendlyTerritory()
        self.venueTestReason = not friendly and reason or nil
        if not friendly then return end
        if type(value) ~= "table" or type(value.opponent) ~= "table" or not FD.Wow then return end
        local opponent = value.opponent
        if not readable(opponent.guid, opponent.fullName) or not text(opponent.fullName) then return end
        local player = FD.Wow:Identity("player", true)
        local peer = FD.Wow:ResolveIncoming(opponent.fullName)
        local position, own = self:Position(), self:Own()
        if not player or not peer or not own or not position or not readable(peer.guid, peer.fullName, peer.level)
            or peer.guid ~= opponent.guid or peer.fullName ~= opponent.fullName or player.guid ~= own.guid
            or not integer(peer.level, 1, 255) then return end
        self.venueTestPending = { player = FD.Copy(player), peer = FD.Copy(peer), position = position,
            faction = own.faction, requestedAt = now() }
        return
    end
    if kind == "world" or kind == "abort" then
        if kind == "world" then self.venueTestPending, self.venueTest, self.venueTestReason = nil, nil, nil
        elseif self.venueTestPending and not self.venueTestPending.countdownAt then self.venueTestPending = nil end
        return
    end
    local pending = self.venueTestPending
    if not pending or now() - pending.requestedAt > 1200 then self.venueTestPending = nil; return end
    if kind == "countdown" and integer(value, 1, 10) then
        if not pending.countdownAt then pending.countdownAt, pending.startedAt = now(), now() + value end
    elseif kind == "result" and readable(value) and type(value) == "string" and FD.Results then
        local winner, source = FD.Results:Parse(value, DUEL_WINNER_KNOCKOUT, DUEL_WINNER_RETREAT, pending.player, pending.peer)
        -- A retreat only proves a duel was abandoned, not a successfully
        -- completed ordinary test at this exact outdoor location.
        if winner and source == "KNOCKOUT" then pending.winnerGUID = winner end
    elseif kind == "finished" then pending.finishedAt = now() end
    self:FinishVenueTest()
end

function Wow:CaptureStatus(allowSearching)
    if FD.queue and FD.queue.state ~= "IDLE" then
        local searching = allowSearching == true and not FD.queue.ticket
            and (FD.queue.state == "SEARCHING" or FD.queue.state == "PAUSED")
        if not searching then return false, "Leave the queue before saving a tested place." end
    end
    local friendly, territoryReason = self:FriendlyTerritory()
    if not friendly then return false, territoryReason end
    local proof = self.venueTest
    if not proof or now() - proof.provedTick > 300 then
        return false, self.venueTestReason or "Complete an ordinary test duel here first (within five minutes)."
    end
    if not self:Solo() then return false, "Leave the test party before saving this place." end
    if self:Combat() or call(IsInInstance) ~= false or call(IsOutdoors) ~= true then
        return false, "Save the tested place outdoors, outside instances and combat."
    end
    local position, own = self:Position(), self:Own()
    if not samePlace(position, proof.position, 40) or not own or own.guid ~= proof.player.guid
        or own.level ~= proof.player.level or own.faction ~= proof.faction then
        return false, "Return within 40 yards of the place where your test duel finished."
    end
    return true, "Recent ordinary duel test confirmed; this place can be saved."
end

function Wow:CaptureVenue()
    local allowed, reason = self:CaptureStatus()
    if not allowed then return nil, reason end
    local proof = self.venueTest
    local position = proof.position
    local zoneMin, zoneMax, levelSource = self:ZoneLevels(position.mapID)
    if not zoneMin then return nil, levelSource end
    local scale = FD.QueueProtocol and FD.QueueProtocol.MAP_SCALE or 100000000
    local mapX, mapY = math.floor(position.mapX * scale + 0.5), math.floor(position.mapY * scale + 0.5)
    local continentID, x, y = self:World(position.mapID, mapX / scale, mapY / scale)
    if continentID ~= position.continentID or not x then return nil, "Tested-place coordinates are unavailable." end
    local info = C_Map and call(C_Map.GetMapInfo, position.mapID)
    local name = type(info) == "table" and text(info.name, 128) and info.name or "Tested duel place"
    local factionCode = proof.faction == "Alliance" and "a" or "h"
    return { id = string.format("test-%d-%d-%d-%s", position.mapID, mapX, mapY, factionCode),
        name = name, mapID = position.mapID, continentID = continentID,
        mapX = mapX / scale, mapY = mapY / scale, factions = { [proof.faction] = true },
        minPlayerLevel = math.min(proof.player.level, proof.peer.level), zoneMinLevel = zoneMin, zoneMaxLevel = zoneMax,
        verified = true, duelAllowed = true, testedAt = proof.provedAt, metadataSource = levelSource }, FD.Copy(proof.peer)
end

function Wow:StoreVenue(venue)
    if type(venue) ~= "table" or not FD.Venues then return false, "Invalid tested place." end
    local valid = FD.Venues:Resolve(venue.id, { catalog = { venue }, world = function(...) return self:World(...) end })
    if not valid or venue.verified ~= true or venue.duelAllowed ~= true then return false, "Invalid tested-place record." end
    local stored = settingsRoot()
    if not stored then return false, "Saved data is unavailable." end
    local venues = FD.Copy(type(stored.venues) == "table" and stored.venues or {})
    for index = #venues, 1, -1 do if venues[index].id == venue.id then table.remove(venues, index) end end
    if #venues >= 100 then return false, "Local tested-place catalog is full." end
    venues[#venues + 1] = FD.Copy(venue)
    return self:Save({ venues = venues })
end

function Wow:AcceptVenue(packet, sender)
    local allowed, reason = self:CaptureStatus(true)
    if not allowed then return false, reason end
    if type(packet) ~= "table" or not readable(sender) or not FD.QueueProtocol then return false, "Invalid tested-place message." end
    for key, value in pairs(packet) do if not readable(key, value) then return false, "Restricted tested-place message." end end
    local wire = FD.QueueProtocol:Encode(packet)
    if not wire or packet.kind ~= "VENUE" then return false, "Invalid tested-place message." end
    local proof = self.venueTest
    if sender ~= proof.peer.fullName or packet.testPairGUID ~= proof.player.guid
        or packet.testedAt < epoch() - 300 or packet.testedAt > epoch() + 2
        or packet.faction ~= proof.faction or packet.minPlayerLevel ~= math.min(proof.player.level, proof.peer.level) then
        return false, "Tested place does not match your recent native duel partner."
    end
    if packet.hubFaction ~= "NONE" then return false, "Automatic sharing cannot certify a capital exterior hub." end
    local scale = FD.QueueProtocol.MAP_SCALE
    local mapX, mapY = packet.mapX / scale, packet.mapY / scale
    local continentID, x, y = self:World(packet.mapID, mapX, mapY)
    local position = { mapID = packet.mapID, continentID = continentID, x = x, y = y }
    if continentID ~= packet.continentID or not samePlace(position, proof.position, 40) then
        return false, "The peer's place is outside your locally tested spot."
    end
    local zoneMin, zoneMax, levelSource = self:ZoneLevels(packet.mapID)
    if not zoneMin then return false, levelSource end
    if zoneMin ~= packet.zoneMinLevel or zoneMax ~= packet.zoneMaxLevel then
        return false, "Zone level metadata does not match the peer's place."
    end
    local factionCode = proof.faction == "Alliance" and "a" or "h"
    local expectedID = string.format("test-%d-%d-%d-%s", packet.mapID, packet.mapX, packet.mapY, factionCode)
    if packet.venueID ~= expectedID then return false, "The peer's place identifier does not match its coordinates." end
    local info = C_Map and call(C_Map.GetMapInfo, packet.mapID)
    local name = type(info) == "table" and text(info.name, 128) and info.name or "Tested duel place"
    local venue = { id = packet.venueID, name = name, mapID = packet.mapID, continentID = continentID,
        mapX = mapX, mapY = mapY, factions = { [proof.faction] = true }, minPlayerLevel = packet.minPlayerLevel,
        zoneMinLevel = packet.zoneMinLevel, zoneMaxLevel = packet.zoneMaxLevel,
        hubFaction = packet.hubFaction ~= "NONE" and packet.hubFaction or nil,
        verified = true, duelAllowed = true, testedAt = packet.testedAt, metadataSource = levelSource }
    return self:StoreVenue(venue)
end

local function pointCoordinates(point)
    if type(point) ~= "table" or not readable(point.uiMapID, point.position) then return nil end
    local x, y = vectorXY(point.position)
    if integer(point.uiMapID, 1, 10000000) and finite(x, 0, 1) and finite(y, 0, 1) then return point.uiMapID, x, y end
end

function Wow:Waypoint(venue)
    if type(venue) ~= "table" or not integer(venue.mapID, 1, 10000000)
        or not finite(venue.mapX, 0, 1) or not finite(venue.mapY, 0, 1)
        or not C_Map or type(C_Map.GetUserWaypoint) ~= "function" or type(C_Map.SetUserWaypoint) ~= "function"
        or not UiMapPoint or type(UiMapPoint.CreateFromCoordinates) ~= "function" then return false end
    if type(C_Map.CanSetUserWaypointOnMap) == "function" and call(C_Map.CanSetUserWaypointOnMap, venue.mapID) ~= true then return false end
    local current = call(C_Map.GetUserWaypoint)
    local mapID, x, y = pointCoordinates(current)
    if current and not mapID then return false end
    -- Preserve the user's existing point once. A second queue click must not
    -- replace that saved point with the queue's own point.
    local owned = self.ownedWaypoint
    if not owned or mapID ~= owned.mapID or x ~= owned.x or y ~= owned.y then
        self.previousWaypoint = current
        self.previousWaypointTracking = C_SuperTrack and call(C_SuperTrack.IsSuperTrackingUserWaypoint) or false
        self.previousQuestTracking = C_SuperTrack and call(C_SuperTrack.GetSuperTrackedQuestID) or nil
    end
    local point = call(UiMapPoint.CreateFromCoordinates, venue.mapID, venue.mapX, venue.mapY)
    if not point then return false end
    if call(C_Map.SetUserWaypoint, point) ~= true then return false end
    self.ownedWaypoint = { mapID = venue.mapID, x = venue.mapX, y = venue.mapY }
    if C_SuperTrack and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" then
        call(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    return true
end

function Wow:ClearWaypoint()
    local owned = self.ownedWaypoint
    if not owned then return end
    self.ownedWaypoint = nil
    local previous = self.previousWaypoint
    local previousTracking, previousQuest = self.previousWaypointTracking, self.previousQuestTracking
    self.previousWaypoint = nil
    self.previousWaypointTracking, self.previousQuestTracking = nil, nil
    if not C_Map then return end
    local mapID, x, y = pointCoordinates(call(C_Map.GetUserWaypoint))
    -- A user change during the match takes precedence over automatic cleanup.
    if mapID ~= owned.mapID or x ~= owned.x or y ~= owned.y then return end
    if previous and type(C_Map.SetUserWaypoint) == "function" then call(C_Map.SetUserWaypoint, previous)
    elseif type(C_Map.ClearUserWaypoint) == "function" then call(C_Map.ClearUserWaypoint) end
    if C_SuperTrack and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" and type(previousTracking) == "boolean" then
        call(C_SuperTrack.SetSuperTrackedUserWaypoint, previousTracking)
    end
    if previousTracking ~= true and integer(previousQuest, 1) and C_SuperTrack
        and type(C_SuperTrack.SetSuperTrackedQuestID) == "function" then call(C_SuperTrack.SetSuperTrackedQuestID, previousQuest) end
end

function Wow:Nonce()
    local counter = FD.Database and FD.Database:NextCounter()
    if not integer(counter, 0) or not FD.Protocol then return nil end
    local nonce = FD.Protocol:Nonce(epoch(), counter, math.random(1, 2147483646))
    -- Counter is retained in full; trim only high epoch digits if a very large
    -- saved counter would exceed the compact queue protocol's nonce budget.
    if nonce and #nonce > 32 then nonce = nonce:sub(#nonce - 31) end
    return nonce
end

function Wow:Environment()
    return {
        now = now, epoch = epoch,
        nonce = function() return self:Nonce() end,
        own = function() return self:Own() end,
        available = function() return self:Available() end,
        combat = function() return self:Combat() end,
        solo = function() return self:Solo() end,
        party = function(peer) return self:Party(peer) end,
        groupState = function(peer) return self:GroupState(peer) end,
        invite = function(peer) return self:Invite(peer) end,
        leave = function(peer, owned) return self:Leave(peer, owned) end,
        coLocated = function(peer) return self:CoLocated(peer) end,
        challenge = function(peer) return self:Challenge(peer) end,
        world = function(mapID, x, y) return self:World(mapID, x, y) end,
        send = function(packet, target, owner) return FD.QueueTransport:Send(packet, target, owner) end,
        render = function() if FD.QueueUI then FD.QueueUI:RefreshIfShown() end end,
        save = function(settings) return self:Save(settings) end,
        settings = function() return self:Settings() end,
        candidates = function() return self:Candidates() end,
        discover = function() return self:Discover() end,
        catalog = function() return self:Catalog() end,
        waypoint = function(venue) return self:Waypoint(venue) end,
        clearWaypoint = function() return self:ClearWaypoint() end,
        print = function(message) if FD.Debug then FD.Debug:Print(message) end end,
        log = function(...) if FD.Debug then FD.Debug:Log(...) end end,
    }
end
