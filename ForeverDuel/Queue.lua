local _, FD = ...

-- Matchmaking never supplies native identity, consent, or rating evidence.
-- Protocol 2 pairs by native invitation first: the coordinator (lower GUID)
-- sends one informational OFFER and invites at once; Blizzard's own invite
-- dialog is the consent. Everything after the group exists runs over PARTY.
local Queue = {}
FD.Queue = Queue
Queue.__index = Queue

-- Timing budgets assume whisper latency of up to ~10 s and the per-prefix
-- addon throttle (burst 10, then 1/s). Group traffic stays well below that:
-- one STATUS per 3 s per client while travelling.
local T = {
    PROFILE_FRESHNESS = 15, PROFILE_RETENTION = 120, INVITE_RECOGNITION = 60,
    ACTIVE_QUERY_INTERVAL = 5, DISCOVERY_QUERY_INTERVAL = 30, QUERY_SPACING = 2,
    INVITE = 60, GROUPING = 45, PLANNING = 45, CLEANUP = 20,
    START_WINDOW = 120, RESULT_WAIT = 15, CLOCK_SKEW = 5,
    RETRY = 3, OFFER_RETRY = 5, STATUS = 3, SILENT = 30, SOLO_GRACE = 5, LOAD_GRACE = 15, LEAVE_DELAY = 1.5,
    BLOCK = 120, COOLDOWN = 120, RETRY_DELAY = 15, RADIUS = 40, LEAVE_LIMIT = 10,
}
Queue.T = T

local SEARCH_PRIORITY = { LEVEL_CAP = 10, BRACKET = 20, LEVEL = 30, RULESET = 40,
    FACTION = 50, RATING = 60, BLOCKED = 70, POSITION = 80, SCOPE = 90,
    STALE = 100, RETRY = 105, NO_VENUE = 110, COORDINATOR = 120 }
local GROUP_STATES = { EXACT = true, SOLO = true, PENDING = true, CHANGED = true }

-- Explicit forward transitions. CLEANUP and IDLE are reached only through
-- Finish/End, which apply the outcome classes below.
local FORWARD = {
    IDLE = { SEARCHING = true },
    SEARCHING = { PAUSED = true, INVITING = true, INVITED = true },
    PAUSED = { SEARCHING = true, INVITED = true },
    INVITING = { GROUPING = true, DUEL = true },
    INVITED = { GROUPING = true, DUEL = true },
    GROUPING = { PLANNING = true, TRAVELLING = true, DUEL = true },
    PLANNING = { TRAVELLING = true, DUEL = true },
    TRAVELLING = { READY = true, DUEL = true },
    READY = { DUEL = true },
    DUEL = { INVITING = true, INVITED = true, GROUPING = true, PLANNING = true, TRAVELLING = true, READY = true },
    CLEANUP = {},
}
-- One deadline per state, measured from entering it, and the reason used when
-- it expires. TRAVELLING/READY use the shared epoch deadlines of the plan.
local LIMITS = {
    INVITING = { T.INVITE, "GROUP_TIMEOUT" }, INVITED = { T.INVITE, "GROUP_TIMEOUT" },
    GROUPING = { T.GROUPING, "PEER_SILENT" }, PLANNING = { T.PLANNING, "PEER_SILENT" },
    DUEL = { FD.C.MATCH_TIMEOUT + 60, "DUEL" },
}
-- Outcome classes: everything not listed is transient/technical.
local OUTCOME = { CANCELLED = "decision", DECLINED = "decision", GROUP_TIMEOUT = "decision",
    TRAVEL_TIMEOUT = "noshow", START_TIMEOUT = "ended", DUEL = "ended", FINISHED = "ended" }
-- Local sentence and the clause used for "Your opponent's client cancelled
-- because ...". Keys are English source strings translated through FD.L.
local CANCEL_TEXT = {
    CANCELLED = { "You left the queue.", "they left the queue" },
    DECLINED = { "The group invitation was declined.", "the group invitation was declined" },
    BUSY = { "%s is already in another queue match.", "they are already in another queue match" },
    INVITE_FAILED = { "The group invitation to %s could not be sent or did not arrive.", "the group invitation could not be sent" },
    GROUP_TIMEOUT = { "The group invitation was not accepted within one minute.", "the group invitation was not accepted within one minute" },
    PEER_SILENT = { "The client of %s stopped responding.", "your client stopped responding" },
    GROUP_CHANGED = { "The group changed; it is no longer only you and %s.", "their group changed" },
    OPPONENT_LEFT = { "%s left the queue group.", "you left the queue group" },
    NO_VENUE = { "No tested meeting place suits both players.", "no tested meeting place suits both players" },
    PLAN_INVALID = { "The meeting place could not be agreed.", "the meeting place could not be agreed" },
    TRAVEL_TIMEOUT = { "The arrival time expired.", "the arrival time expired" },
    START_TIMEOUT = { "No duel was started before the start deadline.", "no duel was started before the start deadline" },
    DUEL = { "The queue duel ended without a rated result.", "their duel ended without a rated result" },
    FINISHED = { "Queue match completed.", "the match is complete" },
    ERROR = { "The queue stopped after an addon error (/duelrating errors).", "of an addon error" },
    RELOAD = { "The queue match ended because of a reload or logout.", "they reloaded or logged out" },
}

local function round(n) return math.floor(n + 0.5) end
local function distance(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function validPosition(p)
    return type(p) == "table" and type(p.mapID) == "number" and p.mapID > 0
        and type(p.continentID) == "number" and type(p.x) == "number" and type(p.y) == "number"
end

-- Pure native-group classification shared with QueueWow. Inputs are native
-- readings, nil when unavailable or restricted. Only positive evidence (raid,
-- a third member, a readable different party1 GUID) is CHANGED. Names are
-- never compared: a still-loading or partial name is not a different player.
function Queue.ClassifyGroup(sample, peerGUID)
    if type(sample) ~= "table" then return "PENDING" end
    if sample.raid == true then return "CHANGED" end
    if sample.raid ~= false or type(sample.grouped) ~= "boolean" then return "PENDING" end
    if not sample.grouped then return "SOLO" end
    local members = sample.members
    if type(members) ~= "number" then return "PENDING" end
    if members > 2 then return "CHANGED" end
    if members < 2 then return "PENDING" end
    if sample.partyGUID ~= nil then return sample.partyGUID == peerGUID and "EXACT" or "CHANGED" end
    return sample.peerInGroup == true and "EXACT" or "PENDING"
end

function Queue:New(env)
    return setmetatable({ env = env, state = "IDLE", peers = {}, queried = {}, retryAt = {}, failures = {},
        blocked = FD.Copy(env.settings().blockedOpponents or {}), enteredAt = env.now(),
        reason = FD.L["Join the queue to find a rated duel."], lastQuery = -math.huge }, self)
end

function Queue:Run(callback)
    local ok, result, reason = pcall(callback)
    if ok then return result, reason end
    -- Optional matchmaking errors never enter the rated-duel recovery path.
    local report = self.env.error or self.env.log
    if type(report) == "function" then pcall(report, "queue", result) end
    -- A repeating error ends in IDLE instead of looping through requeues.
    local repeated = self.env.now() - (self.lastErrorAt or -math.huge) < 60
    self.lastErrorAt = self.env.now()
    local recovered = self.state == "IDLE"
        or pcall(self.state == "CLEANUP" and self.End or self.Finish, self, "ERROR", { noRequeue = repeated })
    if not recovered then self.ticket, self.session, self.ownProfile, self.state = nil, nil, nil, "IDLE" end
    return false, FD.L["Queue stopped after an addon error."]
end

function Queue:Log(topic, ...)
    if type(self.env.log) == "function" then pcall(self.env.log, topic, ...) end
end

function Queue:Notify(event, text)
    if type(self.env.notify) == "function" then pcall(self.env.notify, event, text) end
end

local SEARCH_STATES = { SEARCHING = true, PAUSED = true }

function Queue:Enter(state, detail)
    local from = self.state
    self.state, self.enteredAt = state, self.env.now()
    local t = self.ticket
    -- Combat pauses toggle often; they must not evict match evidence from
    -- the bounded lifecycle ring.
    if not (SEARCH_STATES[from] and SEARCH_STATES[state]) then
        self:Log("queue state", state, from, t and (t.coordinator and "coordinator" or "invitee") or "-", detail)
    end
    self.env.render()
end

function Queue:Advance(state)
    if not FORWARD[self.state][state] then
        self:Log("queue state", "rejected", self.state, state)
        return false
    end
    self:Enter(state)
    return true
end

function Queue:GroupState(peer)
    local ok, state, members = pcall(self.env.groupState, peer)
    if ok and GROUP_STATES[state] then return state, members end
    return "PENDING"
end

function Queue:Settings()
    return self.env.settings()
end

function Queue:Configure(changes)
    local s = FD.Copy(self:Settings())
    for key, value in pairs(changes) do
        if key == "autoAcceptQueueInvite" then
            if type(value) ~= "boolean" then return false, FD.L["Unknown queue preference."] end
        elseif self.state ~= "IDLE" then return false, FD.L["Leave the queue before changing its settings."]
        elseif key == "scope" then
            if value ~= "ZONE" and value ~= "CONTINENT" and value ~= "RULESET" then return false, FD.L["Invalid search scope."] end
        elseif key == "levelGap" then
            if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 5 then return false, FD.L["Level difference must be 0 to 5."] end
        else return false, FD.L["Unknown queue preference."] end
        s[key] = value
    end
    self.env.save(s)
    self.env.render()
    return true
end

function Queue:Window(joinedAt)
    local waited = self.env.epoch() - (joinedAt or self.env.epoch())
    return waited >= 300 and 400 or waited >= 120 and 200 or 100
end

function Queue:VenueEnvironment()
    return { world = self.env.world, catalog = self.env.catalog() }
end

function Queue:RefreshOwn()
    local own = self.env.own()
    if not own then return nil end
    local s = self:Settings()
    own.scope, own.levelGap, own.ruleset = s.scope, s.levelGap, s.ruleset
    own.joinedAt, own.session = self.queuedAt, self.session
    if not validPosition(own) then own.mapID, own.continentID, own.x, own.y = 0, 0, 0, 0 end
    local digest = FD.Venues:Digest(own, self:VenueEnvironment())
    own.venues = #digest > 0 and table.concat(digest, ".") or "-"
    if not FD.QueueProtocol:ValidProfile(own) then return nil end
    self.ownProfile = own
    return own
end

-- Deadline of the current state in server time, for display.
function Queue:Deadline()
    local t, limit = self.ticket, LIMITS[self.state]
    if limit and self.state ~= "DUEL" then return self.env.epoch() + math.max(0, math.ceil(self.enteredAt + limit[1] - self.env.now())) end
    if t and t.plan and self.state == "TRAVELLING" then return t.plan.deadline end
    if t and t.plan and self.state == "READY" then return t.plan.startDeadline end
end

function Queue:GetStatus()
    local t, s, count, fresh = self.ticket, self:Settings(), 0, 0
    for _, peer in pairs(self.peers) do
        local age = self.env.now() - peer.lastSeen
        if age < T.PROFILE_RETENTION then count = count + 1 end
        if age <= T.PROFILE_FRESHNESS then fresh = fresh + 1 end
    end
    local idleOwn = not self.ownProfile and self.env.own() or nil
    local status = { state = self.state, reason = self.reason, cancel = FD.Copy(self.cancel),
        cleanupStatus = self.cleanupStatus, settings = FD.Copy(s),
        opponent = t and FD.Copy(t.peer), coordinator = t and t.coordinator or false,
        venue = t and t.plan and FD.Copy(t.plan.venue), deadline = self:Deadline(),
        ownArrived = t and t.ownArrived or false, peerArrived = t and t.peerArrived or false,
        peerReady = t and t.peerReady or false, inviteSeen = t and t.inviteSeen or false,
        queuedAt = self.queuedAt, cooldownUntil = s.cooldownUntil or 0, autoAccept = s.autoAcceptQueueInvite == true,
        ratingWindow = self:Window(self.queuedAt), level = self.ownProfile and self.ownProfile.level or idleOwn and idleOwn.level,
        discovered = count, freshProfiles = fresh, venueCount = #self.env.catalog(),
        searchReason = self.state == "SEARCHING" and self.searchReason or nil,
        searchDetails = self.state == "SEARCHING" and FD.Copy(self.searchDetails) or nil,
        groupAction = self:GroupAction() }
    if t and self.state == "READY" and type(self.env.coLocated) == "function" then
        local ok, near, reason = pcall(self.env.coLocated, t.peer)
        if ok and not near then status.colocation = reason end
    end
    return status
end

function Queue:Join(preservedWait, automatic)
    if self.state ~= "IDLE" then return false, FD.L["Already in a queue or match."] end
    local s = self:Settings()
    if (s.cooldownUntil or 0) > self.env.epoch() then
        return false, FD.L["Queue paused: wait two minutes after a missed arrival."]
    end
    if not automatic then
        local ok, reason = self.env.available()
        if not ok then return false, reason end
        self.cancel, self.lastPair, self.cleanupStatus = nil, nil, nil
    end
    self.queuedAt = preservedWait or self.env.epoch()
    self.session = self.env.nonce()
    local own = self.session and self:RefreshOwn()
    if not own then
        self.session, self.queuedAt = nil, nil
        return false, FD.L["Waiting for automatic ruleset and readable character data."]
    end
    self.queried = {}
    self:Advance("SEARCHING")
    self.reason = FD.L["Searching for a suitable opponent."]
    -- Discovery and meeting-place selection are separate. A missing suitable
    -- place must never make joining look like an empty opponent queue.
    if self.env.discover then pcall(self.env.discover) end
    self.env.render()
    return true
end

function Queue:Control(kind, extras)
    local t = self.ticket
    if not t then return nil end
    local p = { kind = kind, session = t.ownSession, peerSession = t.peerSession, ticket = t.id }
    for key, value in pairs(extras or {}) do p[key] = value end
    return p
end

function Queue:Send(kind, extras)
    local p = self:Control(kind, extras)
    return p and self.env.send(p, self.ticket.peer.fullName, self.ticket)
end

-- Terminal CANCEL leaves synchronously on PARTY and WHISPER while the group
-- still exists; the transport retries a throttled copy.
function Queue:SendTerminal(reason)
    local p = self:Control("CANCEL", { reason = reason })
    if p and type(self.env.sendNow) == "function" then return self.env.sendNow(p, self.ticket.peer.fullName, self.ticket) end
    return p and self.env.send(p, self.ticket.peer.fullName, self.ticket)
end

-- `bound` sends the PROFILE to our own ticket peer while inviting, so an
-- invitee that lost it can still recognise the invitation.
function Queue:Announce(target, bound)
    if self.state ~= "SEARCHING" and not bound then return false end
    local p = self:RefreshOwn()
    if not p then return false end
    p = FD.Copy(p); p.kind = "PROFILE"
    return self.env.send(p, target, self)
end

function Queue:Eligible(peer)
    local own = self.ownProfile
    if not own or not peer or peer.guid == own.guid then return false, "CHARACTER" end
    local bracket, ratingReason = FD.Rating:Eligible(own, peer)
    if not bracket then
        return false, ({ different_level_cap = "LEVEL_CAP", different_rating_bracket = "BRACKET",
            level_difference_too_large = "LEVEL" })[ratingReason] or "CHARACTER"
    end
    if own.ruleset ~= peer.ruleset then return false, "RULESET" end
    if own.faction ~= peer.faction then return false, "FACTION" end
    if math.abs(own.level - peer.level) > math.min(own.levelGap, peer.levelGap) then return false, "LEVEL" end
    if math.abs(own.rating - peer.rating) > math.min(self:Window(own.joinedAt), self:Window(peer.joinedAt)) then return false, "RATING" end
    if (self.blocked[peer.guid] or 0) > self.env.epoch() then return false, "BLOCKED" end
    if not validPosition(own) or not validPosition(peer) then return false, "POSITION" end
    for _, p in ipairs({ own, peer }) do
        if p.scope == "ZONE" and own.mapID ~= peer.mapID then return false, "SCOPE" end
        if p.scope == "CONTINENT" and own.continentID ~= peer.continentID then return false, "SCOPE" end
    end
    return true
end

-- Venue candidates are the places both digests contain; PLAN_REJECT removes
-- a place the peer cannot use after all.
function Queue:Intersection(peer, rejected)
    local set = {}
    if type(peer.venues) == "string" then
        for hash in peer.venues:gmatch("[^%.]+") do set[hash] = true end
    end
    return function(record)
        return set[FD.Venues:Hash(record.id)] == true and not (rejected and rejected[record.id])
    end
end

function Queue:SharedVenue(own, peer, rejected)
    return FD.Venues:Select(own, peer, self:VenueEnvironment(), self:Intersection(peer, rejected))
end

function Queue:SearchDiagnostic(code, peer)
    local own = self.ownProfile
    local details = peer and { guid = peer.guid, fullName = peer.fullName,
        age = math.max(0, math.floor(self.env.now() - peer.lastSeen)) } or {}
    local messages = {
        SEARCHING = "Searching for a suitable opponent; no joined queue profiles received yet.",
        CHARACTER = "Waiting for readable character information from the queue opponent.",
        BRACKET = "Queue opponent uses a different rating mode (Leveling or Max level).",
        RULESET = "Queue opponent belongs to a different native ruleset.",
        FACTION = "Queue opponent belongs to a different faction.",
        BLOCKED = "This pairing is paused for two minutes after its previous cancellation.",
        POSITION = "Waiting for readable map and position data from both queue players.",
        STALE = "Waiting for a fresh queue profile from the discovered opponent.",
        RETRY = "Suitable opponent found; retrying the pairing shortly.",
        COORDINATOR = "Suitable opponent found; waiting for that player's group invitation.",
        MATCH = "Suitable opponent found; sending the group invitation.",
    }
    local message = messages[code] and FD.L[messages[code]]
    if peer and own then
        details.ratingDifference = math.abs(own.rating - peer.rating)
        details.ownRatingWindow, details.peerRatingWindow = self:Window(own.joinedAt), self:Window(peer.joinedAt)
        details.allowedRatingDifference = math.min(details.ownRatingWindow, details.peerRatingWindow)
        details.levelDifference = math.abs(own.level - peer.level)
        details.allowedLevelDifference = math.min(own.levelGap, peer.levelGap, FD.C.MAX_LEVEL_DIFFERENCE)
        details.ownMaxLevel, details.peerMaxLevel = own.maxLevel, peer.maxLevel
        details.ownScope, details.peerScope = own.scope, peer.scope
        details.blockedUntil = self.blocked[peer.guid]
    end
    if code == "RATING" then
        message = FD.Locale:Format("Rating difference %d; your window is +/- %d and opponent's +/- %d. Both windows must fit.",
            details.ratingDifference, details.ownRatingWindow, details.peerRatingWindow)
    elseif code == "LEVEL" then
        message = FD.Locale:Format("Level difference %d; both players allow at most %d levels.",
            details.levelDifference, details.allowedLevelDifference)
    elseif code == "LEVEL_CAP" then
        message = FD.Locale:Format("Different level caps: yours is %d and opponent's is %d.", details.ownMaxLevel, details.peerMaxLevel)
    elseif code == "SCOPE" then
        message = own.mapID ~= peer.mapID and (own.scope == "ZONE" or peer.scope == "ZONE")
            and FD.L["Queue opponent is in another zone; at least one player searches the same zone only."]
            or FD.L["Queue opponent is on another continent; both players must allow the entire ruleset."]
    elseif code == "NO_VENUE" then
        if #self.env.catalog() == 0 then
            message = FD.L[peer and "Suitable opponent found; no tested duel places saved. Complete a normal native duel and save its tested place before matching."
                or "No tested duel places saved. Complete a normal native duel and save its tested place before matching."]
        else
            message = FD.L["Suitable opponent found; you share no tested place that fits both levels, search scopes and the travel limit."]
        end
    end
    self.searchReason, self.searchDetails = code, details
    self.reason = message or FD.L[messages.CHARACTER]
end

-- Walks the sorted candidates and returns the best one this client may
-- coordinate (lower own GUID); better candidates with a lower GUID invite us.
function Queue:SelectPeer()
    local list, blockedPeer, blockedCode = {}, nil, nil
    local now, own = self.env.now(), self.ownProfile
    for guid, peer in pairs(self.peers) do
        local age = now - peer.lastSeen
        if age >= T.PROFILE_RETENTION then self.peers[guid] = nil
        else
            local eligible, code = self:Eligible(peer)
            if eligible then
                if not self:SharedVenue(own, peer) then code = "NO_VENUE"
                elseif age > T.PROFILE_FRESHNESS then code = "STALE"
                elseif (self.retryAt[guid] or 0) > now then code = "RETRY"
                else list[#list + 1] = peer end
            end
            if code and (not blockedCode or (SEARCH_PRIORITY[code] or 0) > (SEARCH_PRIORITY[blockedCode] or 0)
                or code == blockedCode and peer.guid < blockedPeer.guid) then
                blockedPeer, blockedCode = peer, code
            end
        end
    end
    table.sort(list, function(a, b)
        local da, db = math.abs(a.rating - own.rating), math.abs(b.rating - own.rating)
        if da ~= db then return da < db end
        if a.joinedAt ~= b.joinedAt then return a.joinedAt < b.joinedAt end
        return a.guid < b.guid
    end)
    local waiting
    for _, peer in ipairs(list) do
        if own.guid < peer.guid then self:SearchDiagnostic("MATCH", peer); return peer end
        waiting = waiting or peer
    end
    if waiting then self:SearchDiagnostic("COORDINATOR", waiting)
    elseif blockedCode then self:SearchDiagnostic(blockedCode, blockedPeer)
    elseif #self.env.catalog() == 0 then self:SearchDiagnostic("NO_VENUE")
    else self:SearchDiagnostic("SEARCHING") end
end

function Queue:QueryPeer()
    local now = self.env.now()
    if now - self.lastQuery < T.QUERY_SPACING then return end
    local candidates = {}
    for _, candidate in ipairs(self.env.candidates()) do
        if candidate.guid ~= self.ownProfile.guid then candidates[candidate.fullName] = candidate end
    end
    -- Only received PROFILE packets prove a queue session. Presence candidates
    -- remain discovery targets and never become queued merely by being nearby.
    for _, peer in pairs(self.peers) do
        if now - peer.lastSeen < T.PROFILE_RETENTION then candidates[peer.fullName] = peer end
    end
    local selected, selectedAt, selectedJoined
    for name, candidate in pairs(candidates) do
        local peer = self.peers[candidate.guid]
        local joined = peer ~= nil and peer.fullName == name and now - peer.lastSeen < T.PROFILE_RETENTION
        local interval = joined and T.ACTIVE_QUERY_INTERVAL or T.DISCOVERY_QUERY_INTERVAL
        local at = self.queried[name] or -math.huge
        if now - at >= interval and (not selected or joined and not selectedJoined
            or joined == selectedJoined and (at < selectedAt or at == selectedAt and name < selected.fullName)) then
            selected, selectedAt, selectedJoined = candidate, at, joined
        end
    end
    if selected then
        self.queried[selected.fullName], self.lastQuery = now, now
        self.env.send({ kind = "QUERY" }, selected.fullName, self)
        self:Announce(selected.fullName)
    end
end

function Queue:NewTicket(peer, id, coordinator)
    local now = self.env.now()
    self.ticket = { id = id, coordinator = coordinator, peer = FD.Copy(peer), player = FD.Copy(self.ownProfile),
        ownSession = self.session, peerSession = peer.session, createdAt = now, lastPeerAt = now,
        sentAt = {}, rejected = {}, samples = 0 }
    self.pendingOffer, self.pendingInvite = nil, nil
    return self.ticket
end

-- Coordinator: one informational OFFER whisper, then the native invitation.
function Queue:Offer(peer)
    local t = self:NewTicket(peer, self.ownProfile.session .. "." .. peer.session, true)
    self:Advance("INVITING")
    self.reason = FD.Locale:Format("Inviting %s to a group for your rated queue match.", peer.fullName)
    t.sentAt.OFFER = self.env.now()
    self:Send("OFFER")
    local ok, reason = self.env.invite(peer)
    if not ok then
        self:Log("queue invite", "failed")
        return self:Finish("INVITE_FAILED", { detail = reason })
    end
    t.inviteAt = self.env.now()
    self:Log("queue invite", "sent")
    self:Notify("match", FD.Locale:Format("Queue match found: %s. Group invitation sent.", peer.fullName))
end

-- Invitee: recognised from PARTY_INVITE_REQUEST (inviterGUID) or the OFFER.
function Queue:Invited(peer, id, seen)
    local own = self:RefreshOwn()
    if not own or peer.guid >= own.guid or self.env.now() - peer.lastSeen >= T.INVITE_RECOGNITION
        or not self:Eligible(peer) or self:GroupState(peer) == "CHANGED" then return false end
    local t = self:NewTicket(peer, id, false)
    t.inviteSeen = seen == true
    self:Advance("INVITED")
    self:InvitedNotice()
    return true
end

function Queue:InvitedNotice()
    local t = self.ticket
    self.reason = FD.Locale:Format("Accept the group invitation from %s to start your rated queue match.", t.peer.fullName)
    if t.inviteSeen and not t.announced then
        t.announced = true
        self:Log("queue invite", "recognized")
        self:Notify("invited", self.reason)
        local s = self:Settings()
        if s.autoAcceptQueueInvite == true and type(self.env.acceptInvite) == "function" then
            self:Log("queue invite", "auto-accept")
            self.env.acceptInvite(t.peer)
        end
    end
    self.env.render()
end

function Queue:Busy(p, sender)
    self:Log("queue invite", "busy")
    self.env.send({ kind = "CANCEL", session = self.session, peerSession = p.session, ticket = p.ticket,
        reason = "BUSY" }, sender, nil)
end

function Queue:InviteRequest(guid)
    if type(guid) ~= "string" or not self.session then return end
    local t = self.ticket
    if t then
        if t.peer.guid == guid and self.state == "INVITED" then
            t.inviteSeen = true
            self:InvitedNotice()
        elseif t.peer.guid ~= guid and self.peers[guid] then
            self:Notify("info", FD.Locale:Format("Ignore other group invitations; your queue match is with %s.", t.peer.fullName))
        end
        return
    end
    if self.state ~= "SEARCHING" and self.state ~= "PAUSED" then return end
    local peer = self.peers[guid]
    if not peer then self.pendingInvite = { guid = guid, at = self.env.now() }; return end
    self:Invited(peer, peer.session .. "." .. self.session, true)
end

function Queue:ReceiveOffer(p, sender)
    if p.peerSession ~= self.session or p.ticket ~= p.session .. "." .. p.peerSession then return end
    local peer
    for _, entry in pairs(self.peers) do if entry.fullName == sender then peer = entry end end
    if not peer or peer.session ~= p.session then
        -- A whispered OFFER can overtake the PROFILE it depends on.
        if not peer then self.pendingOffer = { packet = p, sender = sender, at = self.env.now() } end
        return
    end
    local t = self.ticket
    if t then
        if t.peer.guid == peer.guid and not t.coordinator then
            -- Before the group exists the OFFER names the coordinator's
            -- actual session tuple; later OFFERs for another ticket are stale.
            if self.state == "INVITED" then t.id, t.peerSession = p.ticket, p.session end
            return
        end
        return self:Busy(p, sender)
    end
    local seen = self.pendingInvite and self.pendingInvite.guid == peer.guid
    if (self.state == "SEARCHING" or self.state == "PAUSED") and self:Invited(peer, p.ticket, seen) then return end
    return self:Busy(p, sender)
end

function Queue:ResolvePending(peer)
    local now = self.env.now()
    local invite, offer = self.pendingInvite, self.pendingOffer
    if invite and invite.guid == peer.guid and now - invite.at < T.INVITE_RECOGNITION then self:InviteRequest(peer.guid) end
    if offer and offer.sender == peer.fullName and now - offer.at < T.INVITE_RECOGNITION and not self.ticket then
        self.pendingOffer = nil
        self:ReceiveOffer(offer.packet, offer.sender)
    end
end

-- System notices about our own invitation (decline, unknown or grouped target).
function Queue:SystemMessage(message)
    local t = self.ticket
    if self.state ~= "INVITING" or not t or type(self.env.inviteNotice) ~= "function" then return end
    local kind = self.env.inviteNotice(message, t.peer)
    if kind == "DECLINED" or kind == "INVITE_FAILED" then
        self:Log("queue invite", kind == "DECLINED" and "declined" or "failed")
        self:Finish(kind)
    end
end

function Queue:Receive(p, sender)
    if type(p) ~= "table" or type(sender) ~= "string" then return end
    local now = self.env.now()
    if p.kind == "QUERY" then return self:Announce(sender) end
    if p.kind == "PROFILE" then
        if not FD.QueueProtocol:ValidProfile(p) or not self.session or not self.ownProfile or p.guid == self.ownProfile.guid then return end
        if p.joinedAt > self.env.epoch() + 2 or p.joinedAt < self.env.epoch() - 86400 then return end
        local old = self.peers[p.guid]
        if old and old.fullName ~= sender then return end
        local count = 0
        for guid, peer in pairs(self.peers) do
            if now - peer.lastSeen >= T.PROFILE_RETENTION then self.peers[guid] = nil else count = count + 1 end
            if peer.fullName == sender and guid ~= p.guid then return end
        end
        if not old and count >= 300 then return end
        local peer = FD.Copy(p); peer.fullName, peer.lastSeen = sender, now
        peer.kind, peer.protocolVersion = nil, nil
        self.peers[p.guid] = peer
        return self:ResolvePending(peer)
    end
    local t = self.ticket
    if p.kind == "LEAVE" then
        local peer = self.peers[p.guid]
        if peer and peer.fullName == sender and peer.session == p.session then self.peers[p.guid] = nil end
        -- A peer that left before learning of our OFFER cannot accept it.
        if t and t.peer.guid == p.guid and t.peerSession == p.session and t.peer.fullName == sender
            and (self.state == "INVITING" or self.state == "INVITED") then self:Finish("CANCELLED", { received = true }) end
        return
    end
    if p.kind == "OFFER" and not (t and t.id == p.ticket) then return self:ReceiveOffer(p, sender) end
    if not t or sender ~= t.peer.fullName or p.session ~= t.peerSession or p.peerSession ~= t.ownSession or p.ticket ~= t.id then return end
    t.lastPeerAt = now
    if p.kind == "CANCEL" then return self:PeerCancel(p.reason) end
    local handler = self["On" .. p.kind]
    if handler then return handler(self, p, t) end
end

function Queue:PeerCancel(reason)
    local t = self.ticket
    -- The local duel engine alone ends a queue duel; a finished peer must not
    -- remove the party-only identity this client still needs for its result.
    if self.state == "DUEL" or self.state == "CLEANUP" then
        self:Log("queue cancel", reason, self.state, "received", "kept")
        t.peerEnded = true
        if self.state == "CLEANUP" then self:Cleanup() end
        return
    end
    return self:Finish(reason, { received = true })
end

function Queue:OnGROUP(p, t)
    if not t.coordinator then return end
    t.peerBound = true
    if validPosition(p) then t.peerPosition = { mapID = p.mapID, continentID = p.continentID, x = p.x, y = p.y } end
    if self.state == "GROUPING" then self:BeginPlan() end
end

function Queue:OnPLAN(p, t)
    if t.coordinator then return end
    if t.plan then
        -- A repeated PLAN means our acknowledgment was lost.
        if p.venueID == t.plan.venue.id and p.deadline == t.plan.deadline then
            self:Send("PLAN_ACK", { venueID = p.venueID, deadline = p.deadline })
        end
        return
    end
    if self.state ~= "GROUPING" then return end
    local environment = self:VenueEnvironment()
    local venue = FD.Venues:Resolve(p.venueID, environment)
    local own = self:RefreshOwn() or t.player
    if not venue or not (FD.Venues:Eligible(venue, own, t.peer) or FD.Venues:Eligible(venue, t.player, t.peer))
        or venue.mapID ~= p.mapID or venue.continentID ~= p.continentID
        or round(venue.x) ~= p.x or round(venue.y) ~= p.y then
        self:Log("queue planning", "rejected", venue and "mismatch" or "unknown place")
        return self:Send("PLAN_REJECT", { venueID = p.venueID })
    end
    local epoch = self.env.epoch()
    if p.deadline <= epoch or p.deadline > epoch + p.duration + T.CLOCK_SKEW then
        self:Log("queue planning", "rejected", "deadline")
        return self:Finish("PLAN_INVALID")
    end
    t.plan = { venue = venue, duration = p.duration, deadline = p.deadline, startDeadline = p.deadline + T.START_WINDOW }
    self:Send("PLAN_ACK", { venueID = venue.id, deadline = p.deadline })
    self:StartTravel()
end

function Queue:OnPLAN_ACK(p, t)
    if self.state == "PLANNING" and t.plan and p.venueID == t.plan.venue.id and p.deadline == t.plan.deadline then
        self:StartTravel()
    end
end

function Queue:OnPLAN_REJECT(p, t)
    if self.state ~= "PLANNING" or not t.plan or p.venueID ~= t.plan.venue.id then return end
    self:Log("queue planning", "peer rejected place")
    t.rejected[p.venueID] = true
    self:BeginPlan()
end

function Queue:OnSTATUS(p, t)
    -- STATUS is only sent while travelling: it also acknowledges a plan whose
    -- PLAN_ACK was lost.
    if self.state == "PLANNING" then self:StartTravel() end
    if self.state ~= "TRAVELLING" and self.state ~= "READY" then return end
    t.peerStatus = { mapID = p.mapID, continentID = p.continentID, x = p.x, y = p.y, flags = p.flags }
    if p.flags % 2 == 1 then t.peerArrived = true end
    t.peerReady = p.flags >= FD.QueueProtocol.READY
    self:CheckReady()
end

function Queue:BeginPlan()
    local t = self.ticket
    if self.state ~= "GROUPING" and self.state ~= "PLANNING" then return end
    local own = self:RefreshOwn()
    if not validPosition(own) then own = t.player end
    local peer = FD.Copy(t.peer)
    if t.peerPosition then
        for key, value in pairs(t.peerPosition) do peer[key] = value end
    end
    local venue, duration = self:SharedVenue(own, peer, t.rejected)
    if not venue then venue, duration = self:SharedVenue(t.player, t.peer, t.rejected) end
    if not venue then
        self:Log("queue planning", "no shared place")
        return self:Finish(next(t.rejected) and "PLAN_INVALID" or "NO_VENUE")
    end
    local deadline = self.env.epoch() + duration
    t.plan = { venue = venue, duration = duration, deadline = deadline, startDeadline = deadline + T.START_WINDOW }
    if self.state ~= "PLANNING" then self:Advance("PLANNING") end
    self.reason = FD.L["Confirming the meeting place and arrival deadline."]
    t.sentAt.PLAN = -math.huge
    self:Retransmit(t, self.env.now())
end

function Queue:PlanFields()
    local plan = self.ticket.plan
    local v = plan.venue
    return { venueID = v.id, deadline = plan.deadline, duration = plan.duration,
        mapID = v.mapID, continentID = v.continentID, x = round(v.x), y = round(v.y) }
end

function Queue:StartTravel()
    local t = self.ticket
    if not self:Advance("TRAVELLING") then return end
    self.failures[t.peer.guid] = nil
    t.samples = 0
    self.reason = FD.L["Travel to the meeting place before the timer expires."]
    self.env.waypoint(t.plan.venue)
    self:Notify("travel", FD.Locale:Format("Travel to %s to duel %s; the waypoint is set.", t.plan.venue.name, t.peer.fullName))
    self:SendStatus()
end

function Queue:AtVenue(own)
    local venue = self.ticket.plan.venue
    return validPosition(own) and own.continentID == venue.continentID and distance(own, venue) <= T.RADIUS
end

function Queue:SendStatus()
    local t, own = self.ticket, self.ownProfile
    local flags = (t.ownArrived and FD.QueueProtocol.ARRIVED or 0) + (self.state == "READY" and FD.QueueProtocol.READY or 0)
    local p = validPosition(own) and own or { mapID = 0, continentID = 0, x = 0, y = 0 }
    t.sentAt.STATUS = self.env.now()
    self:Send("STATUS", { mapID = p.mapID, continentID = p.continentID, x = p.x, y = p.y, flags = flags })
end

-- READY is symmetric: each client is ready once both arrival flags are set.
function Queue:CheckReady()
    local t = self.ticket
    if self.state ~= "TRAVELLING" or not t.ownArrived or not t.peerArrived then return end
    self:Advance("READY")
    self.reason = t.coordinator and FD.L["Both players are at the meeting place. Request the duel."]
        or FD.Locale:Format("Waiting for %s to send the duel request.", t.peer.fullName)
    self:Notify("ready", FD.Locale:Format("You and %s are at the meeting place.", t.peer.fullName))
    self:SendStatus()
end

-- Own arrival is latched once reached before the deadline; peer arrival
-- comes from its STATUS flag or native party distance once we have arrived.
function Queue:Travel(t, now)
    local epoch = self.env.epoch()
    local settling = self.loadingAt or self.graceUntil and now < self.graceUntil
    local before = t.ownArrived
    if self.state == "TRAVELLING" then
        local own = not settling and self:RefreshOwn()
        if own and validPosition(own) then
            t.samples = self:AtVenue(own) and t.samples + 1 or 0
            if t.samples >= 3 and epoch < t.plan.deadline then t.ownArrived = true end
        end
        if t.ownArrived and not t.peerArrived and type(self.env.peerNear) == "function"
            and self.env.peerNear(t.peer, T.RADIUS) == true then t.peerArrived = true end
        self:CheckReady()
        if self.state == "TRAVELLING" and epoch >= t.plan.deadline then return self:Finish("TRAVEL_TIMEOUT") end
    elseif epoch >= t.plan.startDeadline then
        return self:Finish("START_TIMEOUT")
    end
    if now - t.lastPeerAt >= T.SILENT and not settling and self:PeerPresent(t) ~= true then
        self:Log("queue group", "peer silent", self.state)
        return self:Finish("PEER_SILENT")
    end
    if t.ownArrived ~= before or now - (t.sentAt.STATUS or -math.huge) >= T.STATUS then self:SendStatus() end
end

function Queue:PeerPresent(t)
    if type(self.env.peerPresent) ~= "function" then return nil end
    local ok, present = pcall(self.env.peerPresent, t.peer)
    if ok then return present end
end

-- Periodic state packets, keyed by the transport so throttled copies
-- coalesce: OFFER (with our PROFILE) until the invitee's GROUP binds the
-- ticket, the invitee's GROUP until PLAN, and PLAN until PLAN_ACK.
function Queue:Retransmit(t, now)
    local kind
    if self.state == "PLANNING" then kind = "PLAN"
    elseif self.state == "GROUPING" and not t.coordinator then kind = "GROUP"
    elseif t.coordinator and (self.state == "INVITING" or self.state == "GROUPING" and not t.peerBound) then kind = "OFFER" end
    if not kind or now - (t.sentAt[kind] or -math.huge) < (kind == "OFFER" and T.OFFER_RETRY or T.RETRY) then return end
    t.sentAt[kind] = now
    if kind == "PLAN" then return self:Send("PLAN", self:PlanFields()) end
    if kind == "OFFER" then
        self:Announce(t.peer.fullName, true)
        return self:Send("OFFER")
    end
    local own = self.ownProfile
    local p = validPosition(own) and own or { mapID = 0, continentID = 0, x = 0, y = 0 }
    self:Send("GROUP", { mapID = p.mapID, continentID = p.continentID, x = p.x, y = p.y })
end

-- Confirmed group changes end the match; an owned group that dissolves is
-- the opponent leaving, after a short grace for its late CANCEL.
function Queue:CheckGroup(t, group)
    if group == "CHANGED" then
        self:Log("queue group", "CHANGED", self.state)
        self:Finish("GROUP_CHANGED")
        return false
    end
    if group == "SOLO" then
        t.soloSince = t.soloSince or self.env.now()
        if self.env.now() - t.soloSince >= T.SOLO_GRACE then
            self:Log("queue group", "SOLO", self.state)
            self:Finish("OPPONENT_LEFT")
            return false
        end
    else t.soloSince = nil end
    return true
end

function Queue:GroupFormed(t)
    t.ownedParty, t.groupAt = true, self.env.now()
    self:Log("queue group", "EXACT", self.state)
    self:Advance("GROUPING")
    self.reason = FD.L["Group formed; confirming the match with your opponent's client."]
    if t.coordinator and t.peerBound then self:BeginPlan() end
end

function Queue:Search()
    local available, reason = self.env.available()
    local own = self:RefreshOwn()
    if not available or self.env.combat() or not own or not validPosition(own) then
        if self.state ~= "PAUSED" then self:Advance("PAUSED") end
        self.reason = self.pausedForDuel and FD.L["Search paused for an unrelated duel; it resumes afterwards."]
            or reason or FD.L["Waiting for combat to end or for readable position data."]
        return self.env.render()
    end
    self.pausedForDuel = nil
    if self.state == "PAUSED" then self:Advance("SEARCHING") end
    self:QueryPeer()
    local peer = self:SelectPeer()
    if peer then return self:Offer(peer) end
    self.env.render()
end

function Queue:Tick()
    local now = self.env.now()
    -- A cleanup advisory ends once the leftover group is gone.
    if self.lastPair and self:GroupState(self.lastPair) == "SOLO" then self.lastPair, self.cleanupStatus = nil, nil end
    if self.state == "IDLE" then return end
    if self.state == "CLEANUP" then return self:Cleanup() end
    if self.state == "SEARCHING" or self.state == "PAUSED" then return self:Search() end
    local t = self.ticket
    if not t then return self:End() end
    local limit = LIMITS[self.state]
    if limit and now - self.enteredAt >= limit[1] then
        self:Log("queue group", "deadline", self.state)
        return self:Finish(limit[2])
    end
    if self.state == "DUEL" then return end
    local group = self:GroupState(t.peer)
    if self.state == "INVITING" or self.state == "INVITED" then
        if group == "EXACT" then self:GroupFormed(t)
        elseif group == "CHANGED" then return self:Finish("GROUP_CHANGED") end
        if self.ticket ~= t then return end
    elseif not self:CheckGroup(t, group) then return end
    if self.state == "TRAVELLING" or self.state == "READY" then return self:Travel(t, now) end
    self:Retransmit(t, now)
    self.env.render()
end

-- Who decides an outcome, and what it costs (queue-3 outcome classes).
function Queue:Verdict(reason, received, noRequeue)
    local t = self.ticket
    local class, verdict = OUTCOME[reason] or "transient", {}
    if class == "transient" then
        verdict.requeue, verdict.retry = not noRequeue, t ~= nil
    elseif class == "noshow" then
        local presence = self:ArrivalVerdict()
        verdict.requeue, verdict.cooldown = presence == "arrived", presence == "absent"
    elseif reason == "CANCELLED" then
        verdict.requeue, verdict.block = received, received and t ~= nil
    elseif reason == "GROUP_TIMEOUT" and t and not t.coordinator then
        -- Only an invitee that was shown the invitation and never joined
        -- decided not to accept.
        if t.inviteSeen and not t.groupAt then verdict.block, verdict.decided = true, true
        else verdict.requeue, verdict.retry = true, true end
    elseif class == "decision" then
        verdict.requeue, verdict.block = true, t ~= nil
    end
    return verdict
end

function Queue:ArrivalVerdict()
    local t = self.ticket
    if not t or not t.plan then return "unknown" end
    if t.ownArrived then return "arrived" end
    if self.loadingAt or self.graceUntil and self.env.now() < self.graceUntil then return "unknown" end
    local own = self:RefreshOwn()
    if not own or not validPosition(own) then return "unknown" end
    return self:AtVenue(own) and "arrived" or "absent"
end

function Queue:Block(guid)
    self.blocked[guid] = self.env.epoch() + T.BLOCK
    local s = FD.Copy(self:Settings()); s.blockedOpponents = FD.Copy(self.blocked); self.env.save(s)
end

function Queue:CancelText(reason, received, verdict, name)
    local entry = CANCEL_TEXT[reason] or CANCEL_TEXT.ERROR
    local text = received and FD.Locale:Format("Your opponent's client cancelled because %s.", FD.L[entry[2]])
        or FD.Locale:Format(entry[1], name or FD.L["your opponent"])
    local outcome
    if verdict.decided then outcome = FD.L["You did not accept the group invitation in time and left the queue."]
    elseif verdict.cooldown then outcome = FD.L["Queue paused for two minutes because you did not reach the meeting place."]
    elseif verdict.requeue and verdict.block then
        outcome = FD.Locale:Format("Searching again without %s for two minutes; your waiting time is kept.", name)
    elseif verdict.requeue then outcome = FD.L["Searching again; your waiting time is kept."]
    elseif reason ~= "CANCELLED" or received then outcome = FD.L["Join again to play another match."] end
    return outcome and text .. " " .. outcome or text
end

-- The single terminal path: CANCEL first (synchronously), outcome class,
-- notification, then CLEANUP of an owned group or straight to IDLE/requeue.
function Queue:Finish(reason, options)
    options = options or {}
    if self.state == "IDLE" or self.state == "CLEANUP" then return end
    if not FD.QueueProtocol.REASONS[reason] then reason = "ERROR" end
    local t, from, received = self.ticket, self.state, options.received == true
    local verdict = self:Verdict(reason, received, options.noRequeue)
    if t and not received then self:SendTerminal(reason) end
    local guid, now = t and t.peer.guid, self.env.now()
    if guid and verdict.retry then
        self.retryAt[guid] = now + T.RETRY_DELAY
        self.failures[guid] = (self.failures[guid] or 0) + 1
        -- Repeated technical failures with one opponent stop looping invites.
        if self.failures[guid] >= 3 then verdict.block, self.failures[guid] = true, nil end
    end
    if guid and verdict.block then self:Block(guid) end
    if verdict.cooldown then
        local s = FD.Copy(self:Settings()); s.cooldownUntil = self.env.epoch() + T.COOLDOWN; self.env.save(s)
    end
    local outcome = verdict.cooldown and "cooldown" or verdict.requeue and "requeue" or "idle"
    self.cancel = { reason = reason, received = received, opponent = t and t.peer.fullName, outcome = outcome }
    self.reason = self:CancelText(reason, received, verdict, t and t.peer.fullName)
    self.cancel.text, self.cleanupStatus = self.reason, nil
    self:Log("queue cancel", reason, from, received and "received" or "local", outcome)
    self:Notify(reason == "FINISHED" and "finished" or "cancel", self.reason)
    self.env.clearWaypoint()
    self.requeueWait = verdict.requeue and self.queuedAt or nil
    if not t then return self:End() end
    if from == "INVITED" and type(self.env.declineInvite) == "function" then self.env.declineInvite(t.peer) end
    t.leaveAt = now + T.LEAVE_DELAY
    if reason == "FINISHED" and not t.peerEnded then t.finishWaitUntil = now + T.RESULT_WAIT end
    self:Enter("CLEANUP", reason)
    if type(self.env.after) == "function" then
        self.env.after(T.LEAVE_DELAY, function() if self.ticket == t then self:Cleanup() end end)
    end
    self:Cleanup()
end

-- Bounded: the owned pair group is left after the CANCEL had time to leave;
-- anything else ends with a text advisory instead of trapping the queue.
function Queue:Cleanup()
    if self.state ~= "CLEANUP" then return end
    local t, now = self.ticket, self.env.now()
    if not t then return self:End() end
    local group, members = self:GroupState(t.peer)
    if group == "SOLO" then return self:End() end
    if t.finishWaitUntil and not t.peerEnded and now < t.finishWaitUntil then
        self.cleanupStatus = FD.L["Waiting for the opponent's rated result before closing the queue group."]
        return self.env.render()
    end
    local rescind = group == "PENDING" and t.coordinator and not t.groupAt and members == 1
    if group == "CHANGED" or now - self.enteredAt >= T.CLEANUP or group == "PENDING" and not rescind and not t.ownedParty then
        if group ~= "PENDING" then
            self.cleanupStatus = FD.L["You are still in a group. Leave it manually if you no longer need it."]
            self.lastPair = FD.Copy(t.peer)
        end
        return self:End()
    end
    if now >= t.leaveAt and (group == "EXACT" and t.ownedParty or rescind)
        and now - (t.leftAt or -math.huge) >= 5 then
        t.leftAt = now
        self:Log("queue group", rescind and "rescind invitation" or "leave", "CLEANUP")
        self.env.leave(t.peer)
    end
    self.cleanupStatus = group == "PENDING" and not rescind
        and FD.L["Waiting for native group membership to become readable."]
        or FD.L["Closing the queue group."]
    self.env.render()
end

function Queue:End()
    local wait = self.requeueWait
    self.ticket, self.session, self.ownProfile, self.queuedAt, self.requeueWait = nil, nil, nil, nil, nil
    self.pendingOffer, self.pendingInvite, self.loadingAt = nil, nil, nil
    self:Enter("IDLE")
    if wait then
        local ok, reason = self:Join(wait, true)
        if not ok then self.cleanupStatus = reason end
    end
    self.env.render()
end

function Queue:Leave()
    if self.state == "IDLE" then return true end
    if self.state == "CLEANUP" then
        -- An explicit Leave never waits for group cleanup.
        self.requeueWait = nil
        if self.ticket and self:GroupState(self.ticket.peer) == "EXACT" then self.lastPair = FD.Copy(self.ticket.peer) end
        self:End()
        return true
    end
    local session, own = self.session, self.ownProfile
    self:Finish("CANCELLED")
    -- LEAVE only to the few peers that are still searching and fresh.
    if session and own then
        local list, now = {}, self.env.now()
        for _, peer in pairs(self.peers) do
            if now - peer.lastSeen <= T.PROFILE_FRESHNESS * 2 then list[#list + 1] = peer end
        end
        table.sort(list, function(a, b) return a.lastSeen > b.lastSeen end)
        for index = 1, math.min(#list, T.LEAVE_LIMIT) do
            self.env.send({ kind = "LEAVE", session = session, guid = own.guid }, list[index].fullName, self)
        end
    end
    self.peers = {}
    return true
end

-- UI "Leave group": the remaining group is the queue pair.
function Queue:GroupAction()
    if self.state ~= "IDLE" and self.state ~= "CLEANUP" and self.state ~= "SEARCHING" and self.state ~= "PAUSED" then return false end
    local peer = self.state == "CLEANUP" and self.ticket and self.ticket.peer or self.lastPair
    return peer ~= nil and self:GroupState(peer) == "EXACT"
end

function Queue:LeaveGroup()
    if not self:GroupAction() then return false, FD.L["You are not in a group with your queue opponent."] end
    return self.env.leaveGroup()
end

function Queue:Waypoint()
    local t = self.ticket
    if not t or not t.plan then return false, FD.L["No meeting place is assigned."] end
    if self.env.waypoint(t.plan.venue) then return true end
    return false, FD.L["The waypoint could not be set on this map."]
end

-- Only the coordinator requests the duel; the distance check returns a
-- visible reason and never cancels the match.
function Queue:Challenge()
    local t = self.ticket
    if self.state ~= "READY" or not t then return false, FD.L["Both players must be ready at the meeting place."] end
    if not t.coordinator then return false, FD.Locale:Format("Waiting for %s to send the duel request.", t.peer.fullName) end
    local near, reason = self.env.coLocated(t.peer)
    if not near then return false, reason or FD.L["Move within 10 yards of your opponent."] end
    return self.env.challenge(t.peer)
end

function Queue:OnDuel(kind, match)
    local t = self.ticket
    if kind == "request" then
        local opponent = type(match) == "table" and match.opponent
        if t and self.state ~= "CLEANUP" and type(opponent) == "table" and opponent.guid == t.peer.guid then
            t.duelMatch = match
            if self.state ~= "DUEL" then
                t.resume = self.state
                self:Advance("DUEL")
                self.reason = FD.L["The rated duel flow now controls this match."]
            end
        elseif self.state == "SEARCHING" or self.state == "PAUSED" then
            -- An unrelated duel pauses the search; it resumes afterwards.
            self.pausedForDuel = true
            if self.state == "SEARCHING" then self:Advance("PAUSED") end
            self.reason = FD.L["Search paused for an unrelated duel; it resumes afterwards."]
            self.env.render()
        end
        return
    end
    if not t or self.state ~= "DUEL" or t.duelMatch ~= match then return end
    if kind == "finished" then return self:Finish("FINISHED") end
    -- A request withdrawn before the countdown leaves the match intact.
    if kind == "abort" and type(match) == "table" and not match.countdownAt and not match.startedAt and t.resume then
        t.duelMatch = nil
        local deadline = t.plan and (t.resume == "READY" and t.plan.startDeadline or t.plan.deadline)
        if (not deadline or self.env.epoch() < deadline) and self:Advance(t.resume) then
            self.reason = FD.L["The duel request ended before the countdown; request it again."]
            return
        end
    end
    return self:Finish("DUEL")
end

function Queue:World(leaving)
    if leaving then self.loadingAt = self.env.now()
    else self.loadingAt, self.graceUntil = nil, self.env.now() + T.LOAD_GRACE end
end

-- Reload/logout: the client is unloading, so only the terminal CANCEL is sent.
function Queue:Logout()
    if self.ticket and self.state ~= "IDLE" and self.state ~= "CLEANUP" then
        self:Log("queue cancel", "RELOAD", self.state, "local", "idle")
        self:SendTerminal("RELOAD")
    end
end
