local _, FD = ...

-- All native queue actions are isolated from Core:Safe: a queue API failure
-- must never stop an unrelated rated duel or modify its evidence.
FD.QueueWow = {}
local Wow = FD.QueueWow
local L = FD.L
local Native = FD.Native
local readable, finite, integer, text, call, now = Native.Readable, Native.Finite, Native.Integer, Native.Text,
    Native.Call, Native.Now

-- The queue engine's clocks never fail: 0 stands for unavailable.
local function epoch() return Native.Epoch() or 0 end

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
        return nil, L["Waiting for native ruleset information."]
    end
    for _, rule in ipairs({ { "HardcoreRuleset", "HARDCORE" }, { "RPRuleset", "RP" }, { "PvPRuleset", "PVP" } }) do
        local id = rules[rule[1]]
        if not integer(id, 0, 1000000) then return nil, L["Native ruleset identifiers are unavailable."] end
        local active = call(C_GameRules.IsGameRuleActive, id)
        if type(active) ~= "boolean" then return nil, L["Native ruleset information is unavailable or restricted."] end
        if active then return rule[2] end
    end
    return "NORMAL"
end

local function blockedCopy(source)
    local blocked = {}
    if type(source) == "table" then
        for guid, untilAt in pairs(source) do
            if text(guid, 64) and integer(untilAt, epoch()) then blocked[guid] = untilAt end
        end
    end
    return blocked
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
    return { scope = scope, levelGap = gap, ruleset = ruleset, rulesetReason = rulesetReason,
        rulesetSource = ruleset and "C_GameRules.IsGameRuleActive" or nil,
        cooldownUntil = integer(stored.cooldownUntil, 0) and stored.cooldownUntil or 0,
        autoAcceptQueueInvite = stored.autoAcceptQueueInvite == true,
        blockedOpponents = blockedCopy(stored.blockedOpponents) }
end

function Wow:Save(settings)
    if type(settings) ~= "table" then return false end
    local stored = settingsRoot()
    if not stored then return false end
    if readable(settings.scope) and (settings.scope == "ZONE" or settings.scope == "CONTINENT" or settings.scope == "RULESET") then stored.scope = settings.scope end
    if integer(settings.levelGap, 0, 5) then stored.levelGap = settings.levelGap end
    stored.ruleset, stored.continentVerified, stored.rulesetVerified = nil, nil, nil
    if integer(settings.cooldownUntil, 0) then stored.cooldownUntil = settings.cooldownUntil end
    if type(settings.autoAcceptQueueInvite) == "boolean" then stored.autoAcceptQueueInvite = settings.autoAcceptQueueInvite end
    if type(settings.blockedOpponents) == "table" then stored.blockedOpponents = blockedCopy(settings.blockedOpponents) end
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
    if not C_Map then return nil, L["Player map APIs are unavailable."] end
    local mapID = call(C_Map.GetBestMapForUnit, "player")
    if not integer(mapID, 1, 10000000) then return nil, L["Current zone is unavailable."] end
    -- Each participant supplies their own position. Party APIs never substitute
    -- coordinates or remote observation timestamps for the peer's report.
    local mapX, mapY = vectorXY(call(C_Map.GetPlayerMapPosition, mapID, "player"))
    if not finite(mapX, 0, 1) or not finite(mapY, 0, 1) then return nil, L["Player position is unavailable."] end
    local continentID, x, y = self:World(mapID, mapX, mapY)
    if not continentID then return nil, L["World position conversion is unavailable."] end
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
    if not FD.QueueTransport or not FD.QueueTransport.available then return false, L["Queue addon transport is unavailable."] end
    local blockedUntil = FD.Wow and FD.Wow.outgoingBlockedUntil
    local nativeBlocked = finite(blockedUntil) and now() < blockedUntil
    if (FD.duel and FD.duel.active) or (FD.Wow and (FD.Wow.outgoing or FD.Wow.pendingIncoming)) or nativeBlocked then
        return false, L["Finish the current native duel request before joining the queue."]
    end
    if not self:Solo() then return false, L["Queue requires a confirmed solo character."] end
    local dead = call(UnitIsDeadOrGhost, "player")
    if type(dead) ~= "boolean" or dead then return false, L["Queue requires a living character."] end
    local instance = call(IsInInstance)
    if type(instance) ~= "boolean" or instance then return false, L["Queue requires the open world."] end
    local outdoors = call(IsOutdoors)
    if type(outdoors) ~= "boolean" or not outdoors then return false, L["Queue requires an outdoor location."] end
    if not self:Own() then return false, L["Queue requires readable identity, faction, rating and position."] end
    local settings = self:Settings()
    if not settings.ruleset then return false, settings.rulesetReason end
    return true
end

-- Native readings for FD.Queue.ClassifyGroup; nil means unreadable. The
-- membership proof is GUID based: names are only whisper addresses.
function Wow:GroupSample(peer)
    local sample = {}
    local raid, grouped, members = call(IsInRaid), call(IsInGroup), call(GetNumGroupMembers)
    if type(raid) == "boolean" then sample.raid = raid end
    if type(grouped) == "boolean" then sample.grouped = grouped end
    if integer(members, 0, 40) then sample.members = members end
    local guid = call(UnitGUID, "party1")
    if FD.QueueProtocol:ValidGUID(guid) then sample.partyGUID = guid end
    if type(peer) == "table" and text(peer.guid, 64) and C_PartyInfo and type(C_PartyInfo.IsGUIDInGroup) == "function" then
        local inGroup = call(C_PartyInfo.IsGUIDInGroup, peer.guid)
        if type(inGroup) == "boolean" then sample.peerInGroup = inGroup end
    end
    return sample
end

function Wow:GroupState(peer)
    if type(peer) ~= "table" or not text(peer.guid, 64) then return "PENDING" end
    local sample = self:GroupSample(peer)
    return FD.Queue.ClassifyGroup(sample, peer.guid), sample.members
end

function Wow:Invite(peer)
    if type(peer) ~= "table" or not text(peer.fullName) then return false, L["Opponent identity is unavailable."] end
    if not self:Solo() then return false, L["Cannot invite while grouped."] end
    local invite = C_PartyInfo and C_PartyInfo.InviteUnit or InviteUnit
    if type(invite) ~= "function" then return false, L["The native invitation API is unavailable."] end
    if C_PartyInfo and type(C_PartyInfo.CanInvite) == "function" and call(C_PartyInfo.CanInvite) ~= true then
        return false, L["Native invitation permission is unavailable."]
    end
    if not pcall(invite, peer.fullName) then return false, L["The native invitation was blocked."] end
    -- InviteUnit returns nothing: only the group roster confirms acceptance.
    self.invitedPeer = { guid = peer.guid, at = now() }
    return true
end

-- PARTY_INVITE_REQUEST bookkeeping (the 7th payload field is inviterGUID).
function Wow:InviteRequested(guid)
    if not readable(guid) or not FD.QueueProtocol:ValidGUID(guid) then return nil end
    self.pendingInviter = { guid = guid, at = now() }
    return guid
end

-- The invitation was answered in Blizzard's dialog (AcceptGroup/DeclineGroup
-- hooks) or ended natively (PARTY_INVITE_CANCEL). A declined, rescinded or
-- expired invitation is forgotten so it is never announced or accepted late.
-- Returns the inviter GUID of the closed invitation.
function Wow:InviteClosed(accepted)
    local pending = self.pendingInviter
    if not pending then return nil end
    if accepted then pending.accepted = true else self.pendingInviter = nil end
    return pending.guid
end

-- State of the native invitation from `guid`: "accepted", "open", false when
-- it is gone, nil when the dialog cannot be inspected.
function Wow:InviteOpen(guid)
    local pending = self.pendingInviter
    if not pending or pending.guid ~= guid or now() - pending.at > 60 then return false end
    if pending.accepted then return "accepted" end
    if type(StaticPopup_FindVisible) ~= "function" then return nil end
    local ok, dialog = pcall(StaticPopup_FindVisible, "PARTY_INVITE")
    if not ok or not readable(dialog) then return nil end
    return dialog ~= nil and "open" or false
end

-- AcceptGroup and DeclineGroup are FrameXML-called globals (PARTY_INVITE
-- dialog in the pinned GameDialogDefs.lua), feature-detected and hooked once.
function Wow:InstallHooks()
    if self.hooksInstalled or type(hooksecurefunc) ~= "function" then return end
    self.hooksInstalled = true
    local function closed(accepted)
        return function()
            if not FD.queue then return end
            FD.queue:Run(function()
                local guid = self:InviteClosed(accepted)
                if not accepted then FD.queue:InviteClosed(guid) end
            end)
        end
    end
    if type(AcceptGroup) == "function" then pcall(hooksecurefunc, "AcceptGroup", closed(true)) end
    if type(DeclineGroup) == "function" then pcall(hooksecurefunc, "DeclineGroup", closed(false)) end
end

-- Opt-in auto-accept for exactly the matched inviter. It runs on the next
-- frame so Blizzard's dialog exists; marking it accepted first keeps its
-- OnHide handler from declining. REQUIRES LIVE VERIFICATION: AcceptGroup is
-- not in the generated API documentation and is feature-detected.
function Wow:AcceptInvite(peer)
    local function accept()
        local pending = self.pendingInviter
        if type(peer) ~= "table" or not pending or pending.accepted or pending.guid ~= peer.guid or now() - pending.at > 60
            or type(AcceptGroup) ~= "function" or not self:Solo() then return false end
        local dialog = type(StaticPopup_FindVisible) == "function" and call(StaticPopup_FindVisible, "PARTY_INVITE")
        -- Only an invitation whose dialog is still open can be accepted.
        if type(StaticPopup_FindVisible) == "function" and type(dialog) ~= "table" then return false end
        if not pcall(AcceptGroup) then return false end
        pending.accepted = true
        if type(dialog) == "table" then
            dialog.inviteAccepted = 1
            if type(StaticPopup_Hide) == "function" then pcall(StaticPopup_Hide, "PARTY_INVITE") end
        end
        return true
    end
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0, function() if FD.queue then FD.queue:Run(accept) end end)
        return true
    end
    return accept()
end

-- A void queue invitation is declined so it cannot be accepted by mistake;
-- hiding Blizzard's dialog declines through its own OnHide handler.
function Wow:DeclineInvite(peer)
    local pending = self.pendingInviter
    if type(peer) ~= "table" or not pending or pending.guid ~= peer.guid or pending.accepted then return false end
    self.pendingInviter = nil
    if self:GroupState(peer) == "EXACT" or type(StaticPopup_Hide) ~= "function" then return false end
    return pcall(StaticPopup_Hide, "PARTY_INVITE")
end

-- Leaves the exact queue pair, or rescinds our own still-pending invitation
-- (inviter grouped alone while the invitation is open).
function Wow:Leave(peer)
    local state, members = self:GroupState(peer)
    local invited = self.invitedPeer
    local rescind = state == "PENDING" and members == 1 and invited and type(peer) == "table" and invited.guid == peer.guid
    if state ~= "EXACT" and not rescind then return false end
    return self:LeaveGroup()
end

-- LeaveParty carries no HasRestrictions flag; it is also the UI button.
function Wow:LeaveGroup()
    local leave = C_PartyInfo and C_PartyInfo.LeaveParty or LeaveParty
    if type(leave) ~= "function" then return false, L["The native leave-group API is unavailable."] end
    if not pcall(leave) then return false, L["Leaving the group was blocked; use the normal group menu."] end
    return true
end

local function positions()
    local x, y, z, instance = call(UnitPosition, "player")
    local px, py, pz, pinstance = call(UnitPosition, "party1")
    if not finite(x) or not finite(y) or not finite(z) or not integer(instance, 0)
        or not finite(px) or not finite(py) or not finite(pz) or not integer(pinstance, 0) then return nil end
    return x, y, z, instance, px, py, pz, pinstance
end

-- Native liveness of the matched peer: true/false when readable, else nil.
function Wow:PeerPresent(peer)
    if self:GroupState(peer) ~= "EXACT" then return nil end
    local connected = call(UnitIsConnected, "party1")
    if type(connected) == "boolean" then return connected end
end

function Wow:PeerNear(peer, yards)
    if self:GroupState(peer) ~= "EXACT" then return nil end
    local x, y, _, instance, px, py, _, pinstance = positions()
    if not x then return nil end
    return instance == pinstance and (x - px) ^ 2 + (y - py) ^ 2 <= yards ^ 2
end

function Wow:CoLocated(peer)
    if self:GroupState(peer) ~= "EXACT" then return false, L["Your opponent is not in your queue group yet."] end
    if call(UnitIsVisible, "party1") ~= true then return false, L["Your opponent is not visible in this phase."] end
    if type(UnitPhaseReason) ~= "function" then return false, L["Native phase verification is unavailable."] end
    local ok, phaseReason = pcall(UnitPhaseReason, "party1")
    if not ok or not readable(phaseReason) or phaseReason ~= nil then return false, L["Your opponent is in another phase."] end
    local x, y, z, instance, px, py, pz, pinstance = positions()
    if not x then return false, L["Native distance data is unavailable."] end
    if instance ~= pinstance then return false, L["Your opponent is in another world instance."] end
    if (x - px) ^ 2 + (y - py) ^ 2 > 100 or math.abs(z - pz) > 5 then
        return false, FD.Locale:Format("Move within 10 yards of %s on the same level.", peer.fullName)
    end
    return true
end

-- The designated requester's button; FD.Wow:RequestDuel is the single entry
-- for addon-initiated native requests and reports a visible reason.
function Wow:Challenge(peer)
    local located, reason = self:CoLocated(peer)
    if not located then return false, reason end
    if not FD.Wow or type(FD.Wow.RequestDuel) ~= "function" then return false, L["Request the duel manually."] end
    return FD.Wow:RequestDuel("party1")
end

-- System messages about our own invitation. The global format strings are
-- client-supplied (not in the generated docs) and feature-detected.
-- An already grouped target is almost always a queued player who accepted
-- another coordinator's invitation, so it is reported as BUSY.
local NOTICES = { ERR_DECLINE_GROUP_S = "DECLINED", ERR_ALREADY_IN_GROUP_S = "BUSY",
    ERR_BAD_PLAYER_NAME_S = "INVITE_FAILED" }

function Wow:InviteNotice(message, peer)
    if not readable(message) or type(message) ~= "string" or type(peer) ~= "table" or not text(peer.fullName) then return nil end
    local names = { peer.fullName, peer.fullName:match("^([^%-]+)%-"), peer.fullName:match("^(%S+)%s") }
    for global, kind in pairs(NOTICES) do
        local pattern = _G[global]
        if type(pattern) == "string" then
            for _, name in pairs(names) do
                local ok, expected = pcall(string.format, pattern, name)
                if ok and expected == message then return kind end
            end
        end
    end
end

-- Chat line, sound and the queue window for each queue milestone. Sound kit
-- IDs are feature-detected because Forever's SOUNDKIT table may differ.
local SOUNDS = { match = "PVP_THROUGH_QUEUE", invited = "PVP_THROUGH_QUEUE", travel = "MAP_PING",
    ready = "READY_CHECK", cancel = "IG_QUEST_CANCEL" }

function Wow:Announce(event, message)
    if FD.Debug and type(message) == "string" then FD.Debug:Print(message) end
    local id = SOUNDS[event] and type(SOUNDKIT) == "table" and SOUNDKIT[SOUNDS[event]]
    if integer(id, 1) and type(PlaySound) == "function" then pcall(PlaySound, id) end
    if SOUNDS[event] and FD.QueueUI and not self:Combat() then FD.QueueUI:Show() end
end

function Wow:Candidates()
    local candidates = {}
    if not FD.Presence or type(FD.Presence.Candidates) ~= "function" then return candidates end
    local ok, players = pcall(FD.Presence.Candidates, FD.Presence)
    if not ok or type(players) ~= "table" then return candidates end
    for _, player in ipairs(players) do
        if type(player) == "table" and text(player.fullName) then candidates[#candidates + 1] = player end
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
        return false, FD.Locale:Format("Native territory information is %s; this place cannot be saved.", state)
    end
    local metadata = self:ClassicZoneMetadata(mapID)
    if metadata and metadata.faction ~= faction then
        diagnostics.territorySource = "CLASSIC"
        return false, L["This territory is hostile to your faction; choose a friendly or contested outdoor place."]
    end
    if state == "available" and (territory == "friendly" or territory == "contested" or territory == nil) then return true end
    if territory == "hostile" then return false, L["This territory is hostile to your faction; choose a friendly or contested outdoor place."] end
    if territory == "sanctuary" or territory == "arena" or territory == "combat" then
        return false, L["This territory cannot be approved as an outdoor duel place."]
    end
    if state == "missing" and metadata and metadata.faction == faction then
        diagnostics.territorySource = "CLASSIC"
        return true
    end
    return false, L["Territory information is unavailable for this map; only known Classic starting zones have a metadata fallback."]
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
        return nil, nil, FD.Locale:Format("Native zone level range is %s; this place cannot be saved.", state)
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
                return nil, nil, FD.Locale:Format("Native parent zone level range is %s; this place cannot be saved.", state)
            end
        end
        diagnostics.zoneLevelsSource = "CLASSIC"
        return metadata.low, metadata.high, "CLASSIC"
    end
    diagnostics.zoneLevelsSource = "unavailable"
    return nil, nil, L["Zone level range is unavailable for this map; only known Classic starting zones have a metadata fallback."]
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

-- Returns allowed, reason and a VENUE_REJECT code.
function Wow:CaptureStatus(allowSearching)
    if FD.queue and FD.queue.state ~= "IDLE" then
        local searching = allowSearching == true and not FD.queue.ticket
            and (FD.queue.state == "SEARCHING" or FD.queue.state == "PAUSED")
        if not searching then return false, L["Leave the queue before saving a tested place."], "BUSY" end
    end
    local friendly, territoryReason = self:FriendlyTerritory()
    if not friendly then return false, territoryReason, "TERRITORY" end
    local proof = self.venueTest
    if not proof or now() - proof.provedTick > 300 then
        return false, self.venueTestReason or L["Complete an ordinary test duel here first (within five minutes)."], "NO_TEST"
    end
    if not self:Solo() then return false, L["Leave the test party before saving this place."], "NO_TEST" end
    if self:Combat() or call(IsInInstance) ~= false or call(IsOutdoors) ~= true then
        return false, L["Save the tested place outdoors, outside instances and combat."], "NO_TEST"
    end
    local position, own = self:Position(), self:Own()
    if not samePlace(position, proof.position, 40) or not own or own.guid ~= proof.player.guid
        or own.level ~= proof.player.level or own.faction ~= proof.faction then
        return false, L["Return within 40 yards of the place where your test duel finished."], "NO_TEST"
    end
    return true, L["Recent ordinary duel test confirmed; this place can be saved."]
end

local function placeName(mapID)
    local info = C_Map and call(C_Map.GetMapInfo, mapID)
    return type(info) == "table" and text(info.name, 128) and info.name or L["Tested duel place"]
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
    local continentID, x = self:World(position.mapID, mapX / scale, mapY / scale)
    if continentID ~= position.continentID or not x then return nil, L["Tested-place coordinates are unavailable."] end
    local factionCode = proof.faction == "Alliance" and "a" or "h"
    return { id = string.format("test-%d-%d-%d-%s", position.mapID, mapX, mapY, factionCode),
        name = placeName(position.mapID), mapID = position.mapID, continentID = continentID,
        mapX = mapX / scale, mapY = mapY / scale, factions = { [proof.faction] = true },
        minPlayerLevel = math.min(proof.player.level, proof.peer.level), zoneMinLevel = zoneMin, zoneMaxLevel = zoneMax,
        verified = true, duelAllowed = true, testedAt = proof.provedAt, metadataSource = levelSource }, FD.Copy(proof.peer)
end

function Wow:VenueEnvironment(catalog)
    return { catalog = catalog, world = function(...) return self:World(...) end }
end

-- Stores a tested place. Two records of one spot (both partners saved) are
-- merged to the lexically smaller ID on every client so catalogs converge.
-- Returns ok, the kept ID (or a reason) and a VENUE_REJECT code.
function Wow:StoreVenue(venue)
    if type(venue) ~= "table" or not FD.Venues then return false, L["Invalid tested place."], "INVALID" end
    local valid = FD.Venues:Resolve(venue.id, self:VenueEnvironment({ venue }))
    if not valid or venue.verified ~= true or venue.duelAllowed ~= true then return false, L["Invalid tested-place record."], "INVALID" end
    local stored = settingsRoot()
    if not stored then return false, L["Saved data is unavailable."], "INVALID" end
    local venues = FD.Copy(type(stored.venues) == "table" and stored.venues or {})
    local environment = self:VenueEnvironment(venues)
    local keep = venue
    for _, existing in ipairs(venues) do
        if existing.id < keep.id and FD.Venues:SameSpot(existing, venue, environment) then keep = existing end
    end
    -- Every other record of this ID or spot goes, so a re-save replaces the
    -- record (and its metadata) instead of appending a copy.
    for index = #venues, 1, -1 do
        local existing = venues[index]
        if existing ~= keep and (existing.id == venue.id or FD.Venues:SameSpot(existing, venue, environment)) then
            table.remove(venues, index)
        end
    end
    if keep == venue then
        if #venues >= 100 then return false, L["Local tested-place catalog is full."], "FULL" end
        venues[#venues + 1] = FD.Copy(venue)
    end
    if not self:Save({ venues = venues }) then return false, L["Saved data is unavailable."], "INVALID" end
    return true, keep.id
end

function Wow:FindVenue(id)
    for _, venue in ipairs(self:Catalog()) do if venue.id == id then return venue end end
end

-- The wire record for a stored place, sent to the native test partner.
function Wow:VenuePacket(venue, peer)
    local proof = self.venueTest
    if type(venue) ~= "table" or type(peer) ~= "table" or not proof then return nil end
    local scale = FD.QueueProtocol.MAP_SCALE
    return { kind = "VENUE", venueID = venue.id, testPairGUID = peer.guid,
        mapID = venue.mapID, continentID = venue.continentID,
        mapX = math.floor(venue.mapX * scale + 0.5), mapY = math.floor(venue.mapY * scale + 0.5),
        minPlayerLevel = venue.minPlayerLevel, zoneMinLevel = venue.zoneMinLevel, zoneMaxLevel = venue.zoneMaxLevel,
        faction = venue.factions.Alliance and "Alliance" or "Horde", hubFaction = venue.hubFaction or "NONE",
        testedAt = proof.provedAt }
end

-- Returns accepted, reason, VENUE_REJECT code, kept ID.
function Wow:AcceptVenue(packet, sender)
    local allowed, reason, code = self:CaptureStatus(true)
    if not allowed then return false, reason, code end
    if type(packet) ~= "table" or not readable(sender) or not FD.QueueProtocol then return false, L["Invalid tested-place message."], "INVALID" end
    for key, value in pairs(packet) do if not readable(key, value) then return false, L["Restricted tested-place message."], "INVALID" end end
    local wire = FD.QueueProtocol:Encode(packet)
    if not wire or packet.kind ~= "VENUE" then return false, L["Invalid tested-place message."], "INVALID" end
    local proof = self.venueTest
    if sender ~= proof.peer.fullName or packet.testPairGUID ~= proof.player.guid
        or packet.testedAt < epoch() - 300 or packet.testedAt > epoch() + 2
        or packet.faction ~= proof.faction or packet.minPlayerLevel ~= math.min(proof.player.level, proof.peer.level) then
        return false, L["Tested place does not match your recent native duel partner."], "MISMATCH"
    end
    if packet.hubFaction ~= "NONE" then return false, L["Automatic sharing cannot certify a capital exterior hub."], "HUB" end
    local scale = FD.QueueProtocol.MAP_SCALE
    local mapX, mapY = packet.mapX / scale, packet.mapY / scale
    local continentID, x, y = self:World(packet.mapID, mapX, mapY)
    local position = { mapID = packet.mapID, continentID = continentID, x = x, y = y }
    if continentID ~= packet.continentID or not samePlace(position, proof.position, 40) then
        return false, L["The partner's place is outside your locally tested spot."], "MISMATCH"
    end
    local zoneMin, zoneMax, levelSource = self:ZoneLevels(packet.mapID)
    if not zoneMin then return false, levelSource, "METADATA" end
    if zoneMin ~= packet.zoneMinLevel or zoneMax ~= packet.zoneMaxLevel then
        return false, L["Zone level metadata does not match the partner's place."], "METADATA"
    end
    local factionCode = proof.faction == "Alliance" and "a" or "h"
    local expectedID = string.format("test-%d-%d-%d-%s", packet.mapID, packet.mapX, packet.mapY, factionCode)
    if packet.venueID ~= expectedID then return false, L["The partner's place identifier does not match its coordinates."], "MISMATCH" end
    local venue = { id = packet.venueID, name = placeName(packet.mapID), mapID = packet.mapID, continentID = continentID,
        mapX = mapX, mapY = mapY, factions = { [proof.faction] = true }, minPlayerLevel = packet.minPlayerLevel,
        zoneMinLevel = packet.zoneMinLevel, zoneMaxLevel = packet.zoneMaxLevel,
        verified = true, duelAllowed = true, testedAt = packet.testedAt, metadataSource = levelSource }
    local stored, kept, storeCode = self:StoreVenue(venue)
    if not stored then return false, kept, storeCode end
    return true, nil, nil, kept
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
        groupState = function(peer) return self:GroupState(peer) end,
        invite = function(peer) return self:Invite(peer) end,
        acceptInvite = function(peer) return self:AcceptInvite(peer) end,
        declineInvite = function(peer) return self:DeclineInvite(peer) end,
        inviteOpen = function(guid) return self:InviteOpen(guid) end,
        inviteNotice = function(message, peer) return self:InviteNotice(message, peer) end,
        leave = function(peer) return self:Leave(peer) end,
        leaveGroup = function() return self:LeaveGroup() end,
        peerPresent = function(peer) return self:PeerPresent(peer) end,
        peerNear = function(peer, yards) return self:PeerNear(peer, yards) end,
        coLocated = function(peer) return self:CoLocated(peer) end,
        challenge = function(peer) return self:Challenge(peer) end,
        world = function(mapID, x, y) return self:World(mapID, x, y) end,
        send = function(packet, target, owner) return FD.QueueTransport:Send(packet, target, owner) end,
        sendNow = function(packet, target, owner) return FD.QueueTransport:SendNow(packet, target, owner) end,
        after = function(seconds, callback)
            if C_Timer and type(C_Timer.After) == "function" then
                C_Timer.After(seconds, function() if FD.queue then FD.queue:Run(callback) end end)
            end
        end,
        render = function() if FD.QueueUI then FD.QueueUI:RefreshIfShown() end end,
        notify = function(event, message) self:Announce(event, message) end,
        save = function(settings) return self:Save(settings) end,
        settings = function() return self:Settings() end,
        candidates = function() return self:Candidates() end,
        discover = function() return self:Discover() end,
        catalog = function() return self:Catalog() end,
        waypoint = function(venue) return self:Waypoint(venue) end,
        clearWaypoint = function() return self:ClearWaypoint() end,
        log = function(...) if FD.Debug then FD.Debug:Log(...) end end,
        error = function(context, message) if FD.Debug and FD.Debug.Error then FD.Debug:Error(context, message) end end,
    }
end
