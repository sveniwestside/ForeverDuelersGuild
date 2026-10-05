local _, FD = ...

-- Community directory (read-only). Live 0.6.0 on the Forever mega-realm: two
-- testers whose GUIDs carried different server IDs (Player-4613-...,
-- Player-4619-...) never saw each other in the ForeverDuel chat channel, yet
-- a WoW character community connected them: both saw its chat and each other
-- online with their zone. Players who join the community named in the
-- settings (default "ForeverDuelersGuild") in the game's Communities window
-- therefore form a realm-wide directory of addon users.
--
-- This module only reads that community. It never posts to it, never creates,
-- joins, leaves or invites, and never changes the presence subscription
-- (SetClubPresenceSubscription has a single slot that Blizzard's Communities
-- and Channels windows own). Its one request is FocusMembers, the call the
-- Communities window makes to load a member list, and only while discovery
-- needs the list and the client reports it not ready. Presence trusts cached
-- members like ForeverDuel channel members and whispers the online ones on
-- demand; quiet mode stops those whispers and the FocusMembers request.
--
-- Pinned ClubDocumentation.lua: every C_Club function used here has
-- RequiresClubsInitialized (FailureMode ReturnNothing: nothing is returned
-- until the initial club load), GetSubscribedClubs, GetClubMembers and
-- GetMemberInfo are SecretInChatMessagingLockdown, and none HasRestrictions.
-- Every call is feature-detected and pcall'd, every value checked for secrets.
FD.Community = { DEFAULT = "ForeverDuelersGuild", members = {}, byGuid = {}, total = 0, mismatches = 0,
    state = "loading", dirty = true }
local Community = FD.Community
local Native = FD.Native
local readable, text, integer = Native.Readable, Native.Text, Native.Integer
-- Events only mark the cache dirty: a rebuild runs at most every REBUILD
-- seconds, every REFRESH seconds regardless (presence can change without an
-- event while nothing subscribes to it), and when discovery starts (zone
-- window opened, queue search began) unless the last one is younger than
-- DEMAND_GAP. FocusMembers at most every FOCUS_GAP seconds; at most LIMIT
-- members are read.
local REBUILD, REFRESH, DEMAND_GAP, FOCUS_GAP, LIMIT = 10, 60, 2, 60, 1000
-- Documented enum values, used when the client does not expose Enum.
local DEFAULTS = {
    ClubType = { Character = 1 },
    ClubMemberPresence = { Online = 1, OnlineMobile = 2, Offline = 3, Away = 4, Busy = 5 },
    ClubRestrictionReason = { None = 0 },
    PvPFaction = { Horde = 0, Alliance = 1 },
}

local function enum(group, key)
    local values = type(Enum) == "table" and Enum[group]
    local value = type(values) == "table" and values[key]
    if integer(value, 0, 1000) then return value end
    return DEFAULTS[group][key]
end

local function results(ok, ...)
    if not ok then return false end
    if not readable(...) then return true, true end
    return true, false, ...
end

-- ok is false when the function is missing or failed; secret is true when
-- any result is secret (chat messaging lockdown).
local function call(name, ...)
    local api = C_Club
    local fn = type(api) == "table" and api[name]
    if type(fn) ~= "function" then return false end
    return results(pcall(fn, ...))
end

local function settings()
    local db = FD.Database and FD.Database.data
    return db and type(db.settings) == "table" and db.settings or nil
end

local function say(message) FD.Debug:Print(message) end

-- Directory errors are saved like other discovery errors and never reach
-- Core's duel-aborting recovery.
function Community:Run(callback)
    local ok, result = pcall(callback)
    if ok then return result end
    self.state = "error"
    pcall(function()
        if readable(result) then FD.Debug:Error("community directory", tostring(result)) end
    end)
end

-- 1 to 48 printable characters; "|" would start a UI escape sequence.
function Community:Valid(name)
    if not text(name, 192) or name:find("^%s") or name:find("%s$") then return false end
    local characters = select(2, name:gsub("[^\128-\191]", ""))
    return characters >= 1 and characters <= 48
end

function Community:Name()
    local s = settings()
    if s and s.communityOff == true then return nil end
    local name = s and s.communityName
    return self:Valid(name) and name or self.DEFAULT
end

-- The Communities window whispers a member by the member name unchanged:
-- its menu passes memberInfo.name, and UnitPopupSharedUtil.GetFullPlayerName
-- returns it as is when no unit or surname is given. Presence keys its cache
-- by the sender name the server reports; Presence:Canonical adds the own
-- realm on clients with realm suffixes. On Forever (RegionalUniqueNamesEnabled)
-- whisper names are "Name Surname" and the first name never contains "-"
-- (NameUtil.SplitPlayerNameIntoParts); a "-" may be a server suffix whose
-- whisper form is unknown, so such a name is skipped and counted instead of
-- guessed. A Kstring-encoded name contains "|" escapes and is skipped too.
function Community:Resolve(raw)
    if not text(raw) or not FD.Presence then return nil end
    local regional = type(RegionalUniqueNamesEnabled) == "function" and RegionalUniqueNamesEnabled()
    if not readable(regional) or regional and raw:find("-", 1, true) then return nil end
    return FD.Presence:Canonical(raw)
end

local function factionName(value)
    if not integer(value, 0, 1000) then return nil end
    if value == enum("PvPFaction", "Horde") then return "Horde" end
    if value == enum("PvPFaction", "Alliance") then return "Alliance" end
end

-- In the game, like the Communities window's online count: Online, Away and
-- Busy. OnlineMobile is the mobile chat app, which addon whispers cannot reach.
local function reachable(presence)
    return presence == enum("ClubMemberPresence", "Online") or presence == enum("ClubMemberPresence", "Away")
        or presence == enum("ClubMemberPresence", "Busy")
end

-- A member record, or nil and why it was skipped.
function Community:Record(info)
    local isSelf, raw, guid, presence = info.isSelf, info.name, info.guid, info.presence
    if not readable(isSelf, raw, guid, presence) then return nil, "hidden" end
    if isSelf == true then return nil, "self" end
    local name = self:Resolve(raw)
    if not name or not FD.Protocol:ValidGUID(guid) then return nil, "unresolved" end
    local zone = info.zone
    return { name = name, guid = guid, presence = integer(presence, 0, 1000) and presence or nil,
        online = reachable(presence), level = integer(info.level, 1, 255) and info.level or nil,
        classID = integer(info.classID, 1, 1000) and info.classID or nil,
        zone = text(zone) and zone or nil, faction = factionName(info.faction) }
end

-- Outcomes a live trace needs; transient ones (loading) and a client
-- without C_Club stay chat-debug only.
local PERSISTED = { ok = true, missing = true, type = true, disabled = true, restricted = true, locked = true }

-- clear: the directory no longer applies (off, not joined, disabled).
function Community:Set(state, clear)
    if clear then self.members, self.byGuid, self.total, self.clubId, self.unresolved, self.hidden = {}, {}, 0, nil, 0, 0 end
    if state ~= self.state then
        -- The transport ring keeps the state word only, never names.
        FD.Debug:Log(PERSISTED[state] and "zone receive" or "community", "community", state)
    end
    self.state = state
end

local function lower(a, b)
    if type(a) == "number" and type(b) == "number" then return a < b end
    return tostring(a) < tostring(b)
end

-- The subscribed character community with the configured name, ignoring
-- case. Guild and Battle.net communities are never used. Several matches
-- (possible, names are not unique) use the lowest club ID and are reported.
function Community:Find(name)
    local ok, secret, clubs = call("GetSubscribedClubs")
    if secret then return nil, "locked" end
    if not ok or type(clubs) ~= "table" then return nil, "loading" end
    local wanted, matches, otherType, hidden = name:lower(), {}, false, false
    for _, info in ipairs(clubs) do
        if not readable(info) or type(info) ~= "table" or not readable(info.clubId, info.name, info.clubType) then
            hidden = true
        elseif type(info.name) == "string" and info.name:lower() == wanted and info.clubId ~= nil then
            if info.clubType == enum("ClubType", "Character") then matches[#matches + 1] = info.clubId
            else otherType = true end
        end
    end
    table.sort(matches, lower)
    self.ambiguous = #matches > 1 and #matches or nil
    if matches[1] ~= nil then return matches[1] end
    return nil, hidden and "locked" or otherType and "type" or "missing"
end

function Community:Rebuild(at, active)
    self.builtAt, self.dirty = at, false
    local name = self:Name()
    if not name then return self:Set("off", true) end
    if type(C_Club) ~= "table" or type(C_Club.GetClubMembers) ~= "function"
        or type(C_Club.GetMemberInfo) ~= "function" then return self:Set("unsupported", true) end
    local ok, secret, enabled = call("IsEnabled")
    if secret then return self:Set("locked") end
    if not ok then return self:Set("unsupported", true) end
    if enabled == nil then return self:Set("loading") end -- Not initialized yet (ReturnNothing).
    local _, _, allowed = call("ShouldAllowClubType", enum("ClubType", "Character"))
    if enabled ~= true or allowed == false then return self:Set("disabled", true) end
    local _, _, restriction = call("IsRestricted")
    if integer(restriction, 0, 1000) and restriction ~= enum("ClubRestrictionReason", "None") then
        return self:Set("restricted", true)
    end
    local clubId, reason = self:Find(name)
    if clubId == nil then return self:Set(reason, reason ~= "locked" and reason ~= "loading") end
    if clubId ~= self.clubId then self.members, self.byGuid, self.total, self.unresolved, self.hidden = {}, {}, 0, 0, 0 end
    self.clubId = clubId
    local _, _, opposite = call("DoesCommunityHaveMembersOfTheOppositeFaction", clubId)
    self.singleFaction = opposite == false
    local listed, hiddenList, ids = call("GetClubMembers", clubId)
    if hiddenList then return self:Set("locked") end -- The last readable list stays in use.
    local _, _, ready = call("AreMembersReady", clubId)
    if ready == false and active and at - (self.focusAt or -math.huge) >= FOCUS_GAP then
        self.focusAt = at
        call("FocusMembers", clubId)
    end
    if not listed or type(ids) ~= "table" or #ids == 0 and ready == false then return self:Set("members") end
    local members, byGuid, total, unresolved, hidden = {}, {}, 0, 0, 0
    for index = 1, math.min(#ids, LIMIT) do
        local memberId = ids[index]
        local found, hiddenInfo, info
        if readable(memberId) and memberId ~= nil then found, hiddenInfo, info = call("GetMemberInfo", clubId, memberId) end
        local record, skipped
        if not found or hiddenInfo or not readable(info) or type(info) ~= "table" then skipped = "hidden"
        else record, skipped = self:Record(info) end
        if skipped ~= "self" then total = total + 1 end
        if record and members[record.name] == nil then members[record.name], byGuid[record.guid] = record, record.name
        elseif record or skipped == "unresolved" then unresolved = unresolved + 1
        elseif skipped == "hidden" then hidden = hidden + 1 end
    end
    self.members, self.byGuid, self.total, self.unresolved, self.hidden = members, byGuid, total, unresolved, hidden
    self.truncated = #ids > LIMIT and #ids or nil
    self:Set("ok")
end

-- Called from every Presence tick. active: discovery needs the directory now
-- (never in quiet mode); demand: discovery just started.
function Community:Update(at, active, demand)
    return self:Run(function()
        local age = at - (self.builtAt or -math.huge)
        if age >= REFRESH or self.dirty and age >= REBUILD or demand and age >= DEMAND_GAP then
            self:Rebuild(at, active)
        end
    end)
end

function Community:Ready()
    return self.clubId ~= nil and (self.state == "ok" or self.state == "locked")
end

function Community:IsMember(name)
    return type(name) == "string" and self.members[name] ~= nil
end

-- A profile whose GUID claim belongs to a cached member while the server
-- reports another sender name: the member name is then not the whisper
-- address on this client (the live unknown of Resolve). Only counted for
-- status; a GUID claim never renames or trusts anyone.
function Community:Observe(sender, guid)
    local member = type(guid) == "string" and self.byGuid[guid]
    if not member or member == sender then return end
    self.mismatches = self.mismatches + 1
    if self.mismatches == 1 then FD.Debug:Log("zone receive", "community member name differs from sender") end
end

local function sorted(map)
    local list = {}
    for _, member in pairs(map) do list[#list + 1] = FD.Copy(member) end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function Community:Members()
    return sorted(self.members)
end

function Community:OwnFaction()
    local faction = Native.Call(UnitFactionGroup, "player")
    if faction == "Alliance" or faction == "Horde" then return faction end
end

-- The member zone is the area name the Communities roster shows, localized by
-- this client. It is compared, ignoring case, with GetRealZoneText() (the
-- zone, not the subzone; pinned ZoneScriptDocumentation) and with the name of
-- the current best map (C_Map.GetMapInfo); either may match. A false match
-- only costs a query: the zone browser lists players by the map ID they reply.
function Community:OwnZones()
    local zones = {}
    local zone = Native.Call(GetRealZoneText)
    if text(zone) then zones[#zones + 1] = zone end
    local mapID = FD.Presence and FD.Presence:MapID()
    if mapID and type(C_Map) == "table" then
        local info = Native.Call(C_Map.GetMapInfo, mapID)
        if type(info) == "table" and text(info.name) then zones[#zones + 1] = info.name end
    end
    return zones
end

-- Online members. filter.sameFaction keeps the own faction (a member without
-- faction counts when the community has no opposite-faction members);
-- filter.zone (a name or a list of names) keeps members in that zone.
function Community:Online(filter)
    filter = filter or {}
    local faction = filter.sameFaction and self:OwnFaction()
    if filter.sameFaction and not faction then return {} end
    local zones
    if filter.zone then
        zones = {}
        for _, zone in ipairs(type(filter.zone) == "table" and filter.zone or { filter.zone }) do
            if text(zone) then zones[zone:lower()] = true end
        end
    end
    local online = {}
    for name, member in pairs(self.members) do
        if member.online and (not faction or member.faction == faction or member.faction == nil and self.singleFaction)
            and (not zones or member.zone and zones[member.zone:lower()]) then online[name] = member end
    end
    return sorted(online)
end

function Community:Status()
    local L, name = FD.L, self:Name()
    local function Format(...) return FD.Locale:Format(...) end
    local state = self.state
    if state == "off" then return { L["Community: off. Type /duelrating community on to use it again."] } end
    if state == "unsupported" then return { L["Community: not available on this client."] } end
    if state == "loading" then return { L["Community: waiting for the game to load your communities."] } end
    if state == "disabled" then return { L["Community: communities are disabled on this client."] } end
    if state == "restricted" then return { L["Community: communities are restricted for this account."] } end
    if state == "missing" then return { Format("Community: you are not a member of a community named %s.", name) } end
    if state == "type" then return { Format("Community: %s is not a character community; only character communities are used.", name) } end
    if state == "error" then return { L["Community: temporarily unavailable."] } end
    if state == "members" then return { Format("Community: %s | loading the member list...", name) } end
    local lines = {}
    if state == "locked" and not self:Ready() then
        lines[1] = L["Community: the member list is protected right now (chat lockdown); retrying."]
        return lines
    end
    local zone = #self:Online({ sameFaction = true, zone = self:OwnZones() })
    lines[1] = Format("Community: %s | %d members, %d online, %d in your zone", name, self.total, #self:Online(), zone)
    if state == "locked" then lines[#lines + 1] = L["Community: the member list is protected right now (chat lockdown); using the last readable list."] end
    if self.ambiguous then lines[#lines + 1] = Format("Community: %d communities are named %s; the one with the lowest ID is used.", self.ambiguous, name) end
    if (self.unresolved or 0) + (self.hidden or 0) > 0 then
        lines[#lines + 1] = Format("Community: %d member names could not be resolved and are skipped.", self.unresolved + self.hidden)
    end
    if self.truncated then lines[#lines + 1] = Format("Community: only the first %d of %d members are read.", LIMIT, self.truncated) end
    if self.mismatches > 0 then
        lines[#lines + 1] = Format("Community: %d profiles came from a name other than the member list shows; please report this.", self.mismatches)
    end
    return lines
end

function Community:Command(raw)
    local L, s = FD.L, settings()
    if not s then return end
    local word = raw:lower()
    if word == "off" then
        s.communityOff = true
        self:Rebuild(GetTime())
        return say(L["Community directory off. Discovery no longer reads a community."])
    end
    if word == "on" then s.communityOff = nil
    elseif raw ~= "" then
        if not self:Valid(raw) then return say(L["A community name has 1 to 48 characters and no | sign."]) end
        s.communityName, s.communityOff = raw, nil
    end
    if raw ~= "" then self:Rebuild(GetTime()) end
    for _, line in ipairs(self:Status()) do say(line) end
    if not self:Ready() then
        say(FD.Locale:Format("Join the in-game community %s to find addon players on the whole realm: open the Communities window and accept an invitation or an invite link from a member. The addon cannot join for you and only reads the member list.", self:Name() or self.DEFAULT))
    end
end

-- Events only mark the cache dirty; the next Presence tick rebuilds it.
local function dirty(clubId)
    if clubId == nil or not readable(clubId) or clubId == Community.clubId then Community.dirty = true end
end
for _, event in ipairs({ "INITIAL_CLUBS_LOADED", "CLUB_ADDED", "CLUB_REMOVED", "CLUB_UPDATED" }) do
    FD:OnEvent(event, function() Community.dirty = true end, true, true)
end
for _, event in ipairs({ "CLUB_MEMBER_ADDED", "CLUB_MEMBER_REMOVED", "CLUB_MEMBER_UPDATED",
    "CLUB_MEMBERS_UPDATED", "CLUB_MEMBER_PRESENCE_UPDATED" }) do
    FD:OnEvent(event, function(clubId) Community:Run(function() dirty(clubId) end) end, true, true)
end

FD:RegisterCommand("community", function(_, rawRest)
    Community:Run(function() Community:Command(rawRest or "") end)
end, "Show the community used to find players realm-wide (community <name> | on | off).", 86)
