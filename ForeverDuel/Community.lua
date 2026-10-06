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
-- joins, leaves or invites. Its requests are client-side: FocusMembers (the
-- call the Communities window makes to load a member list) when discovery
-- needs a list the client reports not ready, and while discovery is active
-- the single presence subscription, paired with FocusMembers like the
-- Channels window does (see Hold). Presence trusts cached members like
-- ForeverDuel channel members and whispers the online ones on demand; quiet
-- mode stops those whispers and both requests.
--
-- Joining is the player's own act. Every C_Club call that joins or invites
-- (RedeemTicket, SendCharacterInvitation, AcceptInvitation, the ClubFinder
-- requests) HasRestrictions, so the addon only prints Blizzard's own invite
-- link into the player's chat frame (see Link). The player's click runs
-- Blizzard's clubTicket handler, which opens the Communities window with
-- the invitation and its Join button.
--
-- Pinned ClubDocumentation.lua: every C_Club function used here has
-- RequiresClubsInitialized, GetSubscribedClubs, GetClubMembers and
-- GetMemberInfo are SecretInChatMessagingLockdown, and none HasRestrictions.
-- The docs do not say what a RequiresClubsInitialized function does before
-- the initial club load (no FailureMode is given). Assumed, to be confirmed
-- live: it returns nothing; a false or an error from IsEnabled before
-- INITIAL_CLUBS_LOADED is only believed when a read at least REBUILD
-- seconds after the first one repeats it.
-- Every call is feature-detected and pcall'd, every value checked for secrets.
FD.Community = { DEFAULT = "ForeverDuelersGuild", members = {}, byGuid = {}, total = 0, mismatches = 0,
    state = "loading", dirty = true }
local Community = FD.Community
local Native = FD.Native
local readable, text, integer = Native.Readable, Native.Text, Native.Integer
-- Events only mark the cache dirty. While discovery is active a rebuild runs
-- at most every REBUILD seconds after any event; while it is idle only
-- joins, leaves and list changes (structural events) do, because presence
-- and zone matter only for queries and a busy community would otherwise
-- re-read up to LIMIT members every 10 s all session. Every REFRESH seconds
-- regardless, and when discovery starts (zone window opened, queue search
-- began) unless the last one is younger than DEMAND_GAP. FocusMembers at most
-- every FOCUS_GAP seconds; at most LIMIT members are read.
local REBUILD, REFRESH, DEMAND_GAP, FOCUS_GAP, LIMIT = 10, 60, 2, 60, 1000
-- The join hint waits HINT_DELAY seconds after the first tick, so it is not
-- lost among the login messages.
local HINT_DELAY = 15
-- Invite tickets of the shipped directory community, per faction: the code
-- of a permanent, unlimited invite link (worldofwarcraft.com/invite/<code>).
-- Communities on Forever are probably limited to one faction, so each
-- faction needs its own community.
Community.TICKETS = {
    Horde = "lvEaz0fYwL",
    -- Add the Alliance community's invite code here once that community exists.
    Alliance = nil,
}
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

-- The configured community name, also while the directory is off.
function Community:Configured()
    local s = settings()
    local name = s and s.communityName
    return self:Valid(name) and name or self.DEFAULT
end

function Community:Name()
    local s = settings()
    if s and s.communityOff == true then return nil end
    return self:Configured()
end

-- The shipped invite links join the default community only.
function Community:Shipped()
    return self:Configured():lower() == self.DEFAULT:lower()
end

-- The Communities window whispers a member by the member name unchanged:
-- its menu passes memberInfo.name (UnitPopupManager splits name parts only
-- when RegionalUniqueNamesEnabled() is false), and
-- UnitPopupSharedUtil.GetFullPlayerName returns it as is when no unit or
-- surname is given. Presence keys its cache by the sender name the server
-- reports; Presence:Canonical adds the own realm on clients with realm
-- suffixes and keeps every name unchanged on surname clients (Forever).
-- So the member name is used as Blizzard uses it, a "-" included: if it is
-- an internal-server suffix of a cross-server member, skipping it would lose
-- exactly the players the directory exists for. A wrong address shows up
-- live as a mismatch (Observe) or as the server's "No player named" line,
-- which forgets the name like any offline recipient. A Kstring-encoded name
-- contains "|" escapes and is skipped (Canonical refuses it).
function Community:Resolve(raw)
    if not text(raw) or not FD.Presence then return nil end
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

-- Outcomes a live trace needs, a believed refusal (disabled, unsupported)
-- included; transient ones (loading, members), off and a client without
-- the C_Club functions (chatOnly) stay chat-debug only.
local PERSISTED = { ok = true, missing = true, type = true, disabled = true, unsupported = true, restricted = true,
    locked = true }

-- clear: the directory no longer applies (off, not joined, disabled).
function Community:Set(state, clear, chatOnly)
    if clear then self.members, self.byGuid, self.total, self.clubId, self.unresolved, self.hidden = {}, {}, 0, nil, 0, 0 end
    -- Consecutive reads without the community (the join hint trusts one
    -- only after the initial club load or a second read).
    self.absentReads = (state == "missing" or state == "type") and (self.absentReads or 0) + 1 or 0
    if state ~= self.state then
        -- The transport ring keeps the state word only, never names.
        FD.Debug:Log(PERSISTED[state] and not chatOnly and "zone receive" or "community", "community", state)
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

-- FocusMembers at most every FOCUS_GAP seconds unless forced.
function Community:Focus(at, clubId, force)
    if not force and at - (self.focusAt or -math.huge) < FOCUS_GAP then return end
    self.focusAt = at
    call("FocusMembers", clubId)
end

function Community:Rebuild(at, active)
    self.builtAt, self.dirty, self.structural, self.retry = at, false, false, false
    local name = self:Name()
    if not name then return self:Set("off", true) end
    if type(C_Club) ~= "table" or type(C_Club.IsEnabled) ~= "function" or type(C_Club.GetClubMembers) ~= "function"
        or type(C_Club.GetMemberInfo) ~= "function" then return self:Set("unsupported", true, true) end
    local ok, secret, enabled = call("IsEnabled")
    if secret then return self:Set("locked") end
    local allowed
    if ok and enabled == true then allowed = select(3, call("ShouldAllowClubType", enum("ClubType", "Character"))) end
    local refused = not ok and "unsupported" or (enabled == false or allowed == false) and "disabled" or nil
    -- Before INITIAL_CLUBS_LOADED a refusal may only mean "not initialized
    -- yet": it is reported as loading, retried after REBUILD and believed
    -- only when a read at least REBUILD seconds after the first refusal
    -- repeats it (after a /reload no load event comes). A read in between,
    -- from a command or discovery starting, still reports loading.
    if refused ~= self.refused then self.refused, self.refusedAt = refused, at end
    if refused and not self.initialLoaded and at - self.refusedAt < REBUILD then
        self.retry = true
        return self:Set("loading")
    end
    if refused then return self:Set(refused, true) end
    if enabled == nil then return self:Set("loading") end -- Assumed: not initialized yet.
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
    if ready == false and active then self:Focus(at, clubId) end
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

-- Presence of club members is pushed only for the one club subscribed for
-- presence (pinned SetClubPresenceSubscription: "You can only be subscribed
-- to 0 or 1 clubs for presence. Subscribing to a new club automatically
-- unsuscribes you to existing subscription."). In the pinned FrameXML the
-- Channels window (ChannelFrame:SetFocusedClub) calls FocusMembers and
-- SetClubPresenceSubscription while it shows a community channel and
-- UnfocusMembers and ClearClubPresenceSubscription when it hides; the
-- Communities window calls FocusMembers when a club is selected and
-- ClearClubPresenceSubscription in OnHide; each window hides the other
-- because they "share one presence subscription". Without the subscription,
-- presence and zone from GetMemberInfo may stay as first read once those
-- windows are closed (to be confirmed live), and a member who logs in or
-- moves later would never be asked. The directory therefore holds the slot
-- for its club, paired with FocusMembers like the Channels window, while
-- discovery is active and neither window is shown. It never touches the slot
-- while one of them is shown, takes it back after they closed (their OnHide
-- cleared it, the Channels window also unfocused), and clears it when
-- discovery stops. It never calls UnfocusMembers: the Communities window
-- focuses on every club selection and never unfocuses.
local WINDOWS = { "CommunitiesFrame", "ChannelFrame" }

local function blizzardShown()
    for _, name in ipairs(WINDOWS) do
        local frame = _G[name]
        if type(frame) == "table" and Native.Call(frame.IsShown, frame) == true then return true end
    end
    return false
end

-- A window opened and closed between two ticks is never seen shown, so the
-- OnHide of both windows is hooked (after Blizzard's own, which clears the
-- slot): the Communities window, loaded on demand, on its ADDON_LOADED or
-- when first seen, and both always before the directory takes the slot.
Community.hooked = {}
local function onHide()
    if Community.held ~= nil then Community.lent = true end
end

function Community:HookWindows()
    for _, name in ipairs(WINDOWS) do
        local frame = _G[name]
        if not self.hooked[name] and type(frame) == "table" and type(frame.HookScript) == "function" then
            self.hooked[name] = pcall(frame.HookScript, frame, "OnHide", onHide)
        end
    end
end

function Community:Hold(at, active)
    if type(C_Club) ~= "table" or type(C_Club.SetClubPresenceSubscription) ~= "function" then return end
    self:HookWindows()
    local want = active and self.clubId or nil
    if blizzardShown() then
        -- Their OnHide clears the slot; take it back afterwards.
        if self.held ~= nil then self.lent = true end
        return
    end
    if want == self.held and not self.lent then return end
    local lent = self.lent
    self.lent = nil
    if want ~= nil then
        -- A failed call is not repeated every tick; it is retried when the
        -- slot is needed again.
        self.held = want
        -- Presence may have changed while nobody held the slot: read again
        -- within REBUILD seconds even if no event follows.
        self.retry = call("SetClubPresenceSubscription", want)
        self:Focus(at, want, lent)
    else
        call("ClearClubPresenceSubscription")
        self.held = nil
    end
end

-- Called from every Presence tick. active: discovery needs the directory now
-- (never in quiet mode); demand: discovery just started.
function Community:Update(at, active, demand)
    return self:Run(function()
        self.startedAt = self.startedAt or at
        local age = at - (self.builtAt or -math.huge)
        if age >= REFRESH or demand and age >= DEMAND_GAP
            or age >= REBUILD and (self.retry or self.structural or self.dirty and active) then
            self:Rebuild(at, active)
        end
        self:Hold(at, active)
        self:Hint(at)
    end)
end

function Community:Ready()
    return self.clubId ~= nil and (self.state == "ok" or self.state == "locked")
end

function Community:IsMember(name)
    return type(name) == "string" and self.members[name] ~= nil
end

-- A cached member the directory reports as not reachable (offline, mobile app).
function Community:Offline(name)
    local member = type(name) == "string" and self.members[name]
    return type(member) == "table" and not member.online
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

local function Format(...) return FD.Locale:Format(...) end

local function factionLabel(faction)
    return faction == "Horde" and FD.L["Horde"] or FD.L["Alliance"]
end

-- The chat link for an invite ticket, built like Blizzard's GetClubTicketLink
-- (pinned Blizzard_UIPanels_Game/Mainline/ItemRef.lua): NORMAL_FONT_COLOR
-- (ffffd100) around LinkUtil.FormatLink(LinkTypes.ClubTicket, text, ticketId),
-- that is "|HclubTicket:<ticketId>|h<text>|h". Only the display text is the
-- addon's own (GetClubTicketLink uses CLUB_INVITE_HYPERLINK_TEXT). Clicking
-- it runs the clubTicket handler of the pinned ItemRefHandlersShared.lua,
-- which reads the ticket as the first ":"-field of the link options and,
-- when C_Club.IsEnabled(), calls CommunitiesHyperlink.OnClickLink: the game
-- requests the ticket and opens the Communities window with the invitation.
-- The link is only ever printed into the player's own chat frame; the addon
-- never sends it, clicks it or passes it to SetItemRef.
function Community:Link(ticket)
    if type(ticket) ~= "string" or not ticket:find("^%w+$") then return nil end
    return "|cffffd100|HclubTicket:" .. ticket .. "|h[" .. Format("Join %s", self.DEFAULT) .. "]|h|r"
end

-- The join link for the own faction, or nil, the faction and why not:
-- "faction" (not known yet), "custom" (another community is configured, the
-- shipped links join the default one) or "none" (no community for the
-- faction yet).
function Community:JoinLink()
    local faction = self:OwnFaction()
    if not faction then return nil, nil, "faction" end
    if not self:Shipped() then return nil, faction, "custom" end
    local link = self:Link(self.TICKETS[faction])
    if not link then return nil, faction, "none" end
    return link, faction
end

-- How to join, for a player who is not a member.
function Community:Advise()
    local link, faction, reason = self:JoinLink()
    if link then
        -- The player has the link now: no hint repeats it this session.
        local s = settings()
        if s then s.communityHintShown = true end
        return say(Format("Click the link to join %s; the game's Communities window opens and asks you to confirm. The addon cannot join for you: %s", self.DEFAULT, link))
    end
    if reason == "faction" then
        return say(FD.L["Your faction is not known yet; type /duelrating community join again in a few seconds."])
    end
    if reason == "custom" then
        say(Format("The addon ships a join link only for %s.", self.DEFAULT))
        return say(Format("Join the in-game community %s to find addon players on the whole realm: open the Communities window and accept an invitation or an invite link from a member. The addon cannot join for you and only reads the member list.", self:Configured()))
    end
    say(Format("There is no %s community for the %s yet, so the addon has no join link for you.", self.DEFAULT, factionLabel(faction)))
end

-- One gentle line per login session for a player who is not in the shipped
-- community while a link exists for the own faction: once clubs are loaded
-- and enabled (the community was missing after the initial club load or on
-- two reads), not in quiet mode, not with the directory or the hint turned
-- off, and never again once the player was seen in the community. The
-- marker is saved, so a /reload does not repeat it; only a login (the
-- isInitialLogin of PLAYER_ENTERING_WORLD) starts a new session.
function Community:Hint(at)
    local s = settings()
    if not s then return end
    if self.login then self.login, s.communityHintShown = nil, nil end
    if self.clubId ~= nil and self:Shipped() then s.communityJoined = true end
    if s.communityJoined or s.communityHintShown or s.communityHintOff or s.communityOff then return end
    -- A club event not read yet (the player may just have joined) waits for
    -- the rebuild it causes.
    if self.structural or self.state ~= "missing" and self.state ~= "type" then return end
    if not self.initialLoaded and (self.absentReads or 0) < 2 then return end
    if at - (self.startedAt or at) < HINT_DELAY or FD.Presence and FD.Presence:Quiet() then return end
    local link = self:JoinLink()
    if not link then return end
    s.communityHintShown = true
    FD.Debug:Log("community", "join hint")
    say(Format("Join the %s community to find duel partners across the whole realm: %s (hide this hint: /duelrating community hint off)", self.DEFAULT, link))
end

-- brief: the caller prints the join advice itself.
function Community:Status(brief)
    local L, name = FD.L, self:Name()
    local state = self.state
    if state == "off" then return { L["Community: off. Type /duelrating community on to use it again."] } end
    if state == "unsupported" then return { L["Community: not available on this client."] } end
    if state == "loading" then return { L["Community: waiting for the game to load your communities."] } end
    if state == "disabled" then return { L["Community: communities are disabled on this client."] } end
    if state == "restricted" then return { L["Community: communities are restricted for this account."] } end
    if state == "missing" or state == "type" then
        local lines = { state == "missing" and Format("Community: you are not a member of a community named %s.", name)
            or Format("Community: %s is not a character community; only character communities are used.", name) }
        if brief then return lines end
        local link, faction, reason = self:JoinLink()
        if link then
            lines[2] = Format("Community join link for the %s: available (/duelrating community join).", factionLabel(faction))
        elseif reason == "none" then
            lines[2] = Format("Community join link: none for the %s yet.", factionLabel(faction))
        end
        return lines
    end
    if state == "error" then return { L["Community: temporarily unavailable."] } end
    if state == "members" then return { Format("Community: %s | loading the member list...", name) } end
    local lines = {}
    if state == "locked" and not self:Ready() then
        lines[1] = L["Community: the member list is protected right now (chat lockdown); retrying."]
        return lines
    end
    local zone = #self:Online({ sameFaction = true, zone = self:OwnZones() })
    lines[1] = Format("Community: %s | other members: %d, online: %d, in your zone: %d", name, self.total, #self:Online(), zone)
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

function Community:HintCommand(s, word)
    local L = FD.L
    if word == "off" then
        s.communityHintOff = true
        return say(L["Community join hint off."])
    end
    if word == "on" then
        s.communityHintOff = nil
        return say(L["Community join hint on."])
    end
    say(Format("Community join hint: %s. Type /duelrating community hint off or on.", s.communityHintOff and L["off"] or L["on"]))
end

-- /duelrating community join: the clickable link for the own faction. The
-- command is a demand like the status form, so membership is read first.
function Community:Join(active)
    self:Rebuild(GetTime(), active)
    if self.clubId ~= nil then return say(Format("You are already a member of %s.", self:Name())) end
    local state = self.state
    if state ~= "missing" and state ~= "type" then
        -- Membership is not known (loading, chat lockdown) or communities
        -- are unusable: the status says which.
        for _, line in ipairs(self:Status(true)) do say(line) end
        -- The game would not open the invitation (the handler checks IsEnabled).
        if state == "unsupported" or state == "disabled" or state == "restricted" then return end
    end
    self:Advise()
end

-- "join", "hint", "on" and "off" are keywords: a community with one of
-- these names cannot be configured.
function Community:Command(raw)
    local L, s = FD.L, settings()
    if not s then return end
    local word = raw:lower():gsub("%s+", " ")
    -- The command is a demand: read the directory now and, unless quiet,
    -- request a member list that is not loaded yet (FOCUS_GAP still applies).
    local active = not (FD.Presence and FD.Presence:Quiet())
    if word == "off" then
        s.communityOff = true
        self:Rebuild(GetTime())
        return say(L["Community directory off. Discovery no longer reads a community."])
    end
    if word == "hint" or word == "hint on" or word == "hint off" then return self:HintCommand(s, word:match("^hint ?(.*)$")) end
    if word == "join" then return self:Join(active) end
    if word == "on" then s.communityOff = nil
    elseif raw ~= "" then
        if not self:Valid(raw) then return say(L["A community name has 1 to 48 characters and no | sign."]) end
        s.communityName, s.communityOff = raw, nil
    end
    self:Rebuild(GetTime(), active)
    for _, line in ipairs(self:Status(true)) do say(line) end
    -- Joining is the remedy only when no character community has the name.
    if self.state == "missing" or self.state == "type" then
        self:Advise()
    elseif self.state == "members" then
        say(L["The game is loading the member list; type /duelrating community again in a few seconds."])
    end
end

-- A login (not a /reload) starts a new session for the join hint.
FD:OnEvent("PLAYER_ENTERING_WORLD", function(isInitialLogin)
    if isInitialLogin == true then Community.login = true end
end, true)
-- Blizzard_Communities loads on demand; its window is hooked before it can
-- be shown.
FD:OnEvent("ADDON_LOADED", function()
    Community:Run(function() Community:HookWindows() end)
end, true, true)

-- Events only mark the cache dirty; a Presence tick rebuilds it (see Update).
-- Club events and joins, leaves and list loads of the directory club are
-- structural; presence and member info changes matter only while discovery
-- is active.
for _, event in ipairs({ "INITIAL_CLUBS_LOADED", "CLUB_ADDED", "CLUB_REMOVED", "CLUB_UPDATED" }) do
    FD:OnEvent(event, function()
        if event == "INITIAL_CLUBS_LOADED" then Community.initialLoaded = true end
        Community.dirty, Community.structural = true, true
    end, true, true)
end
local STRUCTURAL = { CLUB_MEMBER_ADDED = true, CLUB_MEMBER_REMOVED = true, CLUB_MEMBERS_UPDATED = true }
for _, event in ipairs({ "CLUB_MEMBER_ADDED", "CLUB_MEMBER_REMOVED", "CLUB_MEMBER_UPDATED",
    "CLUB_MEMBERS_UPDATED", "CLUB_MEMBER_PRESENCE_UPDATED" }) do
    FD:OnEvent(event, function(clubId) Community:Run(function()
        if readable(clubId) and clubId ~= nil and clubId ~= Community.clubId then return end
        Community.dirty = true
        if STRUCTURAL[event] then Community.structural = true end
    end) end, true, true)
end

FD:RegisterCommand("community", function(_, rawRest)
    Community:Run(function() Community:Command(rawRest or "") end)
end, "Show the community used to find players realm-wide (community join | <name> | on | off | hint on|off).", 86)
