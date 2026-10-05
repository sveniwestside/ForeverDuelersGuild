local _, FD = ...

-- Matchmaking never supplies native identity, consent, or rating evidence.
local Queue = {}
FD.Queue = Queue
Queue.__index = Queue
local PROFILE_FRESHNESS, PROFILE_RETENTION = 10, 120
local ACTIVE_QUERY_INTERVAL, DISCOVERY_QUERY_INTERVAL = 5, 30
local SEARCH_PRIORITY = { LEVEL_CAP = 10, BRACKET = 20, LEVEL = 30, RULESET = 40,
    FACTION = 50, RATING = 60, BLOCKED = 70, POSITION = 80, SCOPE = 90,
    STALE = 100, NO_VENUE = 110, COORDINATOR = 120 }
local ACTIVE = { RESERVING = true, GROUPING = true, PLANNING = true,
    TRAVELLING = true, READY = true, DUEL = true }
local GROUP_STATES = { EXACT = true, SOLO = true, PENDING = true, CHANGED = true }
local CANCEL_REASONS = { CANCELLED = true, GROUP_TIMEOUT = true, TRAVEL_TIMEOUT = true,
    START_TIMEOUT = true, TECHNICAL = true, DUEL = true, FINISHED = true }
local function round(n) return math.floor(n + 0.5) end
local function distance(a, b)
    return math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2)
end
local function validPosition(p)
    return p and type(p.mapID) == "number" and p.mapID > 0
        and type(p.continentID) == "number" and type(p.x) == "number" and type(p.y) == "number"
end

function Queue:New(env)
    return setmetatable({ env = env, state = "IDLE", peers = {}, queried = {},
        blocked = FD.Copy(env.settings().blockedOpponents or {}),
        reason = "Join the queue to find a rated duel.", lastQuery = -math.huge }, self)
end

function Queue:Run(callback)
    local ok, result, reason = pcall(callback)
    if ok then return result, reason end
    -- Optional matchmaking errors must not enter the rated-duel recovery handler.
    self.reason = "Queue stopped after an addon error."
    pcall(function() self:Cancel("TECHNICAL", false) end)
    pcall(function() self.env.log("queue error", result) end)
    return false, self.reason
end

function Queue:Log(topic, ...)
    if type(self.env.log) == "function" then pcall(self.env.log, topic, ...) end
end

function Queue:GroupState(peer)
    if type(self.env.groupState) == "function" then
        local ok, state = pcall(self.env.groupState, peer)
        return ok and type(state) == "string" and GROUP_STATES[state] and state or "PENDING"
    end
    -- Older adapters have only a binary proof. Preserve their existing policy.
    if self.env.party(peer) then return "EXACT" end
    return self.env.solo() and "SOLO" or "CHANGED"
end

function Queue:AdoptOwnedParty(t)
    -- Bilateral reservation must already have entered grouping. A cancellation
    -- may arrive before our first tick observes the newly accepted invitation.
    if t and t.groupAt ~= nil and self:GroupState(t.peer) == "EXACT" and self.env.party(t.peer) then
        t.ownedParty = true
        self:Log("queue group", "exact native queue group confirmed")
        return true
    end
    return false
end

function Queue:Settings()
    return self.env.settings()
end

function Queue:Configure(changes)
    if self.state ~= "IDLE" then return false, "Leave the queue before changing its settings." end
    local s = FD.Copy(self:Settings())
    for key, value in pairs(changes) do
        if key == "scope" then
            if value ~= "ZONE" and value ~= "CONTINENT" and value ~= "RULESET" then return false, "Invalid search scope." end
        elseif key == "levelGap" then
            if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 5 then return false, "Level difference must be 0 to 5." end
        else return false, "Unknown queue preference." end
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

function Queue:GetStatus()
    local t, s, count, fresh = self.ticket, self:Settings(), 0, 0
    for _, peer in pairs(self.peers) do
        local age = self.env.now() - peer.lastSeen
        if age < PROFILE_RETENTION then count = count + 1 end
        if age <= PROFILE_FRESHNESS then fresh = fresh + 1 end
    end
    local idleOwn = not self.ownProfile and self.env.own() or nil
    return { state = self.state, reason = self.reason, settings = FD.Copy(s),
        opponent = t and FD.Copy(t.peer), venue = t and FD.Copy(t.venue),
        deadline = t and t.deadline, duration = t and t.duration,
        ownArrived = t and t.ownArrived or false, peerArrived = t and t.peerArrived or false,
        inviteFallback = t and t.inviteFallback or false, inviter = t and t.coordinator or false,
        queuedAt = self.queuedAt, cooldownUntil = s.cooldownUntil or 0,
        ratingWindow = self:Window(self.queuedAt), level = self.ownProfile and self.ownProfile.level or idleOwn and idleOwn.level,
        discovered = count, freshProfiles = fresh, venueCount = #self.env.catalog(),
        searchReason = self.state == "SEARCHING" and self.searchReason or nil,
        searchDetails = self.state == "SEARCHING" and FD.Copy(self.searchDetails) or nil }
end

function Queue:RefreshOwn()
    local own = self.env.own()
    if not own then return nil end
    local s = self:Settings()
    own.scope, own.levelGap, own.ruleset = s.scope, s.levelGap, s.ruleset
    own.joinedAt, own.session = self.queuedAt, self.session
    if not validPosition(own) then own.mapID, own.continentID, own.x, own.y = 0, 0, 0, 0 end
    if not FD.QueueProtocol:ValidProfile(own) then return nil end
    self.ownProfile = own
    return own
end

function Queue:VenueEnvironment()
    return { world = self.env.world, catalog = self.env.catalog() }
end

function Queue:Join(preservedWait)
    if self.state ~= "IDLE" then return false, "Already in a queue or match." end
    local s = self:Settings()
    if (s.cooldownUntil or 0) > self.env.epoch() then return false, "Queue pause: wait two minutes after a missed arrival." end
    local ok, reason = self.env.available()
    if not ok then return false, reason end
    self.queuedAt = preservedWait or self.env.epoch()
    self.session = self.env.nonce()
    local own = self:RefreshOwn()
    if not own then self.session, self.queuedAt = nil, nil; return false, "Waiting for automatic ruleset and readable character data." end
    self.state, self.reason, self.queried = "SEARCHING", "Searching for a suitable opponent.", {}
    self:Log("queue state", "SEARCHING")
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

function Queue:Announce(target)
    if self.state ~= "SEARCHING" then return false end
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

function Queue:SearchDiagnostic(code, peer)
    local own = self.ownProfile
    local details = peer and { guid = peer.guid, fullName = peer.fullName,
        age = math.max(0, math.floor(self.env.now() - peer.lastSeen)) } or {}
    local messages = {
        SEARCHING = "Searching for a suitable opponent; no joined queue profiles received yet.",
        CHARACTER = "Waiting for readable character information from the queue opponent.",
        LEVEL_CAP = "Queue opponent has a different level cap.",
        BRACKET = "Queue opponent uses a different rating mode (Leveling or Max level).",
        LEVEL = "Queue opponent is outside the level difference allowed by both players.",
        RULESET = "Queue opponent belongs to a different native ruleset.",
        FACTION = "Queue opponent belongs to a different faction.",
        BLOCKED = "This pairing is paused for two minutes after its previous cancellation.",
        POSITION = "Waiting for readable map and position data from both queue players.",
        SCOPE = "Queue opponent is outside the zone or continent search allowed by both players.",
        STALE = "Waiting for a fresh queue profile from the discovered opponent.",
        COORDINATOR = "Suitable opponent found; waiting for that player's pairing reservation.",
    }
    if peer and own then
        details.ratingDifference = math.abs(own.rating - peer.rating)
        details.ownRatingWindow, details.peerRatingWindow = self:Window(own.joinedAt), self:Window(peer.joinedAt)
        details.allowedRatingDifference = math.min(details.ownRatingWindow, details.peerRatingWindow)
        details.levelDifference = math.abs(own.level - peer.level)
        details.allowedLevelDifference = math.min(own.levelGap, peer.levelGap, FD.C.MAX_LEVEL_DIFFERENCE)
        details.ownLevel, details.peerLevel = own.level, peer.level
        details.ownMaxLevel, details.peerMaxLevel = own.maxLevel, peer.maxLevel
        details.ownScope, details.peerScope = own.scope, peer.scope
        details.ownMapID, details.peerMapID = own.mapID, peer.mapID
        details.ownContinentID, details.peerContinentID = own.continentID, peer.continentID
        details.blockedUntil = self.blocked[peer.guid]
    end
    local message = messages[code]
    if code == "RATING" then
        message = string.format("Rating difference %d; your window is +/- %d and opponent's +/- %d. Both windows must fit.",
            details.ratingDifference, details.ownRatingWindow, details.peerRatingWindow)
    elseif code == "LEVEL" then
        message = string.format("Level difference %d; both players allow at most %d levels.",
            details.levelDifference, details.allowedLevelDifference)
    elseif code == "LEVEL_CAP" then
        message = string.format("Different level caps: yours is %d and opponent's is %d.", details.ownMaxLevel, details.peerMaxLevel)
    elseif code == "SCOPE" then
        message = own.mapID ~= peer.mapID and (own.scope == "ZONE" or peer.scope == "ZONE")
            and "Queue opponent is in another zone; at least one player searches the same zone only."
            or "Queue opponent is on another continent; both players must allow the entire ruleset."
    elseif code == "NO_VENUE" then
        if #self.env.catalog() == 0 then
            message = (peer and "Suitable opponent found; no tested duel places saved." or "No tested duel places saved.")
                .. " Complete a normal native duel and save its tested place before matching."
        else
            message = "Suitable opponent found; no common tested faction-friendly place fits both levels, search scopes and the travel limit."
        end
    end
    self.searchReason, self.searchDetails, self.reason = code, details, message or messages.CHARACTER
end

function Queue:SelectPeer()
    local list, blockedPeer, blockedCode = {}, nil, nil
    self.venueBlocked = false
    for guid, peer in pairs(self.peers) do
        local age = self.env.now() - peer.lastSeen
        if age >= PROFILE_RETENTION then self.peers[guid] = nil
        else
            local eligible, code = self:Eligible(peer)
            if eligible then
                local venue = FD.Venues:Select(self.ownProfile, peer, self:VenueEnvironment())
                if not venue then self.venueBlocked, code = true, "NO_VENUE"
                elseif age > PROFILE_FRESHNESS then code = "STALE"
                else list[#list + 1] = peer end
            end
            if code and (not blockedCode or (SEARCH_PRIORITY[code] or 0) > (SEARCH_PRIORITY[blockedCode] or 0)
                or code == blockedCode and peer.guid < blockedPeer.guid) then
                blockedPeer, blockedCode = peer, code
            end
        end
    end
    table.sort(list, function(a, b)
        local da, db = math.abs(a.rating - self.ownProfile.rating), math.abs(b.rating - self.ownProfile.rating)
        if da ~= db then return da < db end
        if a.joinedAt ~= b.joinedAt then return a.joinedAt < b.joinedAt end
        return a.guid < b.guid
    end)
    local best = list[1]
    if best then self:SearchDiagnostic("COORDINATOR", best)
    elseif blockedCode then self:SearchDiagnostic(blockedCode, blockedPeer)
    elseif #self.env.catalog() == 0 then self:SearchDiagnostic("NO_VENUE")
    else self:SearchDiagnostic("SEARCHING") end
    return best
end

function Queue:QueryPeer()
    local now = self.env.now()
    if now - self.lastQuery < 1 then return end
    local candidates = {}
    for _, candidate in ipairs(self.env.candidates()) do
        if candidate.guid ~= self.ownProfile.guid then candidates[candidate.fullName] = candidate end
    end
    -- Only received PROFILE packets prove a queue session. Presence candidates
    -- remain discovery targets and never become queued merely by being nearby.
    for _, peer in pairs(self.peers) do
        if now - peer.lastSeen < PROFILE_RETENTION then candidates[peer.fullName] = peer end
    end
    local selected, selectedAt, selectedJoined
    for name, candidate in pairs(candidates) do
        local peer = self.peers[candidate.guid]
        local joined = peer ~= nil and peer.fullName == name and now - peer.lastSeen < PROFILE_RETENTION
        local interval = joined and ACTIVE_QUERY_INTERVAL or DISCOVERY_QUERY_INTERVAL
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

function Queue:Reserve(peer, id, coordinator)
    self.ticket = { id = id, peer = FD.Copy(peer), player = FD.Copy(self.ownProfile), ownSession = self.session,
        peerSession = peer.session, coordinator = coordinator, createdAt = self.env.now(),
        lastPeerAt = self.env.now(), lastSend = -math.huge, samples = 0 }
    self.state, self.reason = "RESERVING", "Reserving this pairing."
    self:Log("queue state", "RESERVING", coordinator and "coordinator" or "peer")
    self.env.render()
end

function Queue:StartGrouping()
    local t = self.ticket
    if self.state ~= "RESERVING" then return end
    self.state, self.reason, t.groupAt = "GROUPING", "Waiting for the native group invitation to be accepted.", self.env.now()
    self:Log("queue state", "GROUPING")
    if t.coordinator then
        local ok = self.env.invite(t.peer)
        t.inviteFallback = not ok
    end
    self.env.render()
end

function Queue:GroupingHeartbeat(now, exact)
    local t = self.ticket
    if now - t.lastSend < 2 then return end
    if exact and self.env.party(t.peer) then self:Send("GROUP") end
    local p = self:PositionPacket(); if p then self:Send("POSITION", p) end
    if exact and self.state == "PLANNING" and self.env.party(t.peer) then
        self:Send(t.coordinator and "PLAN" or "PLAN_ACK", t.coordinator and self:PlanFields() or nil)
    else
        self:Send(t.coordinator and "COMMIT" or "CONFIRM")
    end
    t.lastSend = now
end

function Queue:Invite()
    local t = self.ticket
    if not t or not t.coordinator or self.state ~= "GROUPING" then return false, "No invitation is pending." end
    local ok, reason = self.env.invite(t.peer)
    t.inviteFallback = not ok
    self.env.render()
    return ok, reason
end

function Queue:Waypoint()
    if not self.ticket or not self.ticket.venue then return false, "No meeting place is assigned." end
    return self.env.waypoint(self.ticket.venue)
end

function Queue:Challenge()
    if self.state ~= "READY" then return false, "Both players must be ready at the meeting place." end
    if self.env.epoch() >= self.ticket.deadline then
        self:Cancel("START_TIMEOUT", false); return false, "The duel start deadline expired."
    end
    local own, t = self:RefreshOwn(), self.ticket
    if not validPosition(own) or own.mapID ~= t.venue.mapID or own.continentID ~= t.venue.continentID
        or distance(own, t.venue) > 40 or not self.env.coLocated(t.peer) then
        self:Cancel("TECHNICAL", false); return false, "The meeting place or opponent could no longer be verified."
    end
    return self.env.challenge(self.ticket.peer)
end

function Queue:PlanFields()
    local t, v = self.ticket, self.ticket.venue
    return { venueID = v.id, deadline = t.travelDeadline, duration = t.duration,
        mapID = v.mapID, continentID = v.continentID, x = round(v.x), y = round(v.y) }
end

function Queue:BeginPlan()
    local t = self.ticket
    if not t or not t.coordinator or not t.peerGrouped or not self.env.party(t.peer) then return end
    t.ownedParty = true
    local own = self:RefreshOwn()
    if not own or not t.peerPosition or self.env.now() - t.peerPositionAt > 5 then
        self:Log("queue planning", "waiting for fresh participant positions")
        return
    end
    local peer = FD.Copy(t.peer)
    for _, key in ipairs({ "mapID", "continentID", "x", "y" }) do peer[key] = t.peerPosition[key] end
    local venue, duration = FD.Venues:Select(own, peer, self:VenueEnvironment())
    if not venue then
        self:Log("queue planning", "no eligible tested meeting place")
        return self:Cancel("TECHNICAL", false)
    end
    t.venue, t.duration, t.travelDeadline = venue, duration, self.env.epoch() + duration
    t.planDeadline = t.travelDeadline
    t.planAt, t.lastSend = self.env.now(), -math.huge
    self.state, self.reason = "PLANNING", "Confirming the meeting place and arrival deadline."
    self:Log("queue state", "PLANNING")
    self:Send("PLAN", self:PlanFields())
    self.env.render()
end

function Queue:AcceptPlan(p)
    local t = self.ticket
    if t.coordinator or not self.env.party(t.peer) or not t.peerGrouped then return end
    t.ownedParty = true
    local venue = FD.Venues:Resolve(p.venueID, self:VenueEnvironment())
    local own = self:RefreshOwn()
    if not venue or not own or not FD.Venues:Eligible(venue, own, t.peer)
        or venue.mapID ~= p.mapID or venue.continentID ~= p.continentID
        or round(venue.x) ~= p.x or round(venue.y) ~= p.y
        or p.deadline <= self.env.epoch() or p.deadline > self.env.epoch() + p.duration + 2 then
        self:Log("queue planning", "meeting place or deadline validation failed")
        return self:Cancel("TECHNICAL", false)
    end
    if t.venue and (t.venue.id ~= p.venueID or t.travelDeadline ~= p.deadline or t.duration ~= p.duration) then return end
    if not t.venue then
        t.venue, t.duration, t.travelDeadline = venue, p.duration, p.deadline
        t.planDeadline = p.deadline
        t.planAt = self.env.now()
    end
    local previousState = self.state
    self.state, self.reason = "PLANNING", "Confirming the meeting place and arrival deadline."
    if previousState ~= "PLANNING" then self:Log("queue state", "PLANNING") end
    self:Send("PLAN_ACK")
    self.env.render()
end

function Queue:StartTravel(deadline)
    local t = self.ticket
    if not t or not t.venue then return false end
    local groupState = self:GroupState(t.peer)
    local exact = groupState == "EXACT" and self.env.party(t.peer)
    if not exact then
        -- Native getters can change between the status and final exact check.
        -- Never commit a travel deadline or acknowledge GO without that proof.
        if groupState == "EXACT" then groupState = self:GroupState(t.peer) end
        if self.state == "PLANNING" and (groupState == "PENDING" or groupState == "EXACT") then
            self.reason = "Waiting for native group membership to become readable."
            self:Log("queue group", "travel confirmation waiting for native group proof")
            return false
        end
        self:Cancel("TECHNICAL", false)
        return false
    end
    if deadline ~= nil then t.travelDeadline = deadline end
    t.ownedParty = true
    local previousState = self.state
    self.state, self.reason, t.deadline = "TRAVELLING", "Travel to the meeting place before the timer expires.", t.travelDeadline
    if previousState ~= "TRAVELLING" then self:Log("queue state", "TRAVELLING") end
    self.env.render()
    return true
end

function Queue:PositionPacket()
    local p = self:RefreshOwn()
    return p and { mapID = p.mapID, continentID = p.continentID, x = p.x, y = p.y }
end

function Queue:Receive(p, sender)
    if type(p) ~= "table" or type(sender) ~= "string" then return end
    if p.kind == "QUERY" then return self:Announce(sender) end
    if p.kind == "PROFILE" then
        if not FD.QueueProtocol:ValidProfile(p) or not self.session or p.guid == self.ownProfile.guid then return end
        if p.joinedAt > self.env.epoch() + 2 or p.joinedAt < self.env.epoch() - 86400 then return end
        local old = self.peers[p.guid]
        if old and old.fullName ~= sender then return end
        local count = 0
        for guid, peer in pairs(self.peers) do
            if self.env.now() - peer.lastSeen >= PROFILE_RETENTION then self.peers[guid] = nil else count = count + 1 end
            if peer.fullName == sender and guid ~= p.guid then return end
        end
        if not old and count >= 300 then return end
        local peer = FD.Copy(p); peer.fullName, peer.lastSeen = sender, self.env.now()
        self.peers[p.guid] = peer
        return
    end
    if p.kind == "LEAVE" then
        local peer = self.peers[p.guid]
        if peer and peer.fullName == sender and peer.session == p.session then self.peers[p.guid] = nil end
        return
    end
    if p.kind == "OFFER" and (self.state == "SEARCHING" or self.state == "RESERVING") then
        local peer
        for _, entry in pairs(self.peers) do
            if entry.fullName == sender and entry.session == p.session then peer = entry; break end
        end
        if not peer or p.peerSession ~= self.session or not self:RefreshOwn() or not self:Eligible(peer)
            or peer.guid >= self.ownProfile.guid or self.env.combat() or not self.env.solo()
            or self.env.now() - peer.lastSeen > PROFILE_FRESHNESS then return end
        local expected = peer.session .. "." .. self.session
        if p.ticket ~= expected then return end
        if self.ticket and self.ticket.id ~= p.ticket then
            if not self.ticket.coordinator or peer.guid >= self.ownProfile.guid then return end
            self:Send("CANCEL", { reason = "CANCELLED" })
        end
        if not self.ticket or self.ticket.id ~= p.ticket then self:Reserve(peer, p.ticket, false) end
        self:Send("ACK")
        return
    end
    local t = self.ticket
    if not t or sender ~= t.peer.fullName or p.session ~= t.peerSession or p.peerSession ~= t.ownSession or p.ticket ~= t.id then return end
    -- Receive callbacks can run before the next timer tick. A late control
    -- packet must not turn an already expired reservation into a fresh group.
    if self.state == "RESERVING" and self.env.now() - t.createdAt >= 20 then
        self:Cancel("TECHNICAL", false)
        return
    end
    -- Native callbacks can arrive at a deadline before its next timer tick.
    -- An authenticated late control must not advance an expired group or plan.
    if self.state == "GROUPING" or self.state == "PLANNING" then
        if self.env.now() - t.groupAt >= 60 then
            self:Cancel("GROUP_TIMEOUT", false)
            return
        end
        if self.state == "PLANNING" and self.env.now() - t.planAt >= 20 then
            self:Log("queue planning", "planning confirmation deadline expired")
            self:Cancel("TECHNICAL", false)
            return
        end
    end
    -- A finished client must retain party-only native identity for its peer's
    -- result barrier. Terminal notification is not permission to abort a duel.
    if p.kind == "CANCEL" and (p.reason == "FINISHED" or p.reason == "DUEL") then
        t.peerEnded = true
        if self.state == "CLEANUP" then self:Cleanup(); return end
        if p.reason == "FINISHED" and self.state == "DUEL" then return end
    end
    if not ACTIVE[self.state] then return end
    t.lastPeerAt = self.env.now()
    if p.kind == "CANCEL" then
        if p.reason == "TRAVEL_TIMEOUT" and self.state == "TRAVELLING"
            and self.env.epoch() >= t.travelDeadline then return self:ExpireTravel(true) end
        return self:Cancel(p.reason, false, true)
    end
    if p.kind == "ACK" and t.coordinator and self.state == "RESERVING" then
        t.acknowledged = true; self:Send("COMMIT")
    elseif p.kind == "COMMIT" and not t.coordinator and (self.state == "RESERVING" or self.state == "GROUPING") then
        self:StartGrouping(); self:Send("CONFIRM")
    elseif p.kind == "CONFIRM" and t.coordinator and (self.state == "RESERVING" or self.state == "GROUPING") then
        t.confirmed = true; self:StartGrouping()
    elseif p.kind == "GROUP" and self.state ~= "RESERVING" then
        t.peerGrouped = true
    elseif p.kind == "POSITION" and self.state ~= "RESERVING" then
        t.peerPosition, t.peerPositionAt = FD.Copy(p), self.env.now()
    elseif p.kind == "GO_ACK" and t.coordinator and self.state == "TRAVELLING" then
        t.travelConfirmed = true
    elseif p.kind == "PLAN" and (self.state == "GROUPING" or self.state == "PLANNING") then
        self:AcceptPlan(p)
    elseif p.kind == "PLAN_ACK" and t.coordinator and (self.state == "PLANNING" or self.state == "TRAVELLING") then
        local deadline = self.state == "PLANNING" and self.env.epoch() + t.duration or t.travelDeadline
        if self:StartTravel(deadline) then self:Send("GO", self:PlanFields()) end
    elseif p.kind == "GO" and not t.coordinator and (self.state == "PLANNING" or self.state == "TRAVELLING") then
        local validDeadline = self.state == "PLANNING" and p.deadline >= t.planDeadline
            and p.deadline <= self.env.epoch() + t.duration + 2 and p.deadline > self.env.epoch()
            or self.state == "TRAVELLING" and p.deadline == t.travelDeadline
        if t.venue and validDeadline and p.venueID == t.venue.id and p.duration == t.duration
            and p.mapID == t.venue.mapID and p.continentID == t.venue.continentID
            and p.x == round(t.venue.x) and p.y == round(t.venue.y) then
            if self:StartTravel(p.deadline) then
                self:Send("GO_ACK"); self:Send("POSITION", self:PositionPacket())
            end
        end
    elseif p.kind == "ARRIVED" and (self.state == "TRAVELLING" or self.state == "READY") then
        t.peerArrivalAt = self.env.now()
        t.travelConfirmed = true
    elseif p.kind == "READY" and (self.state == "TRAVELLING" or self.state == "READY") then
        t.peerReadyAt = self.env.now()
        t.travelConfirmed = true
        if not t.coordinator and p.deadline > self.env.epoch() and p.deadline <= self.env.epoch() + 122 then
            if not t.readyProposal then t.readyProposal = p.deadline end
        end
    end
end

function Queue:Cancel(reason, requeue, received)
    local t = self.ticket
    self:AdoptOwnedParty(t)
    self:Log("queue state", "CLEANUP", CANCEL_REASONS[reason] and reason or "CANCELLED", self.state)
    if t and not received then self:Send("CANCEL", { reason = reason or "CANCELLED" }) end
    if t then
        self.blocked[t.peer.guid] = self.env.epoch() + 120
        local s = FD.Copy(self:Settings()); s.blockedOpponents = FD.Copy(self.blocked); self.env.save(s)
    end
    self.reason = ({ TRAVEL_TIMEOUT = "Arrival time expired.", GROUP_TIMEOUT = "Group invitation timed out.",
        START_TIMEOUT = "No duel request was started.", FINISHED = "Match completed. Join again to play another.",
        TECHNICAL = "Match cancelled: position, connection, or phase could not be confirmed." })[reason] or "Queue cancelled."
    self.requeueWait = requeue and self.queuedAt or nil
    if t and reason == "FINISHED" and not t.peerEnded then t.finishWaitUntil = self.env.now() + 15 end
    self.state = "CLEANUP"
    self.env.clearWaypoint()
    self:Cleanup()
    self.env.render()
end

function Queue:Cleanup()
    if self.state ~= "CLEANUP" then return end
    local finishing = self.ticket
    if finishing and finishing.finishWaitUntil and not finishing.peerEnded
        and self.env.now() < finishing.finishWaitUntil then
        self.reason = "Waiting for the opponent's rated result before closing the queue group."
        return
    end
    if not self.env.solo() then
        local t = self.ticket
        local groupState = t and self:GroupState(t.peer) or "CHANGED"
        if groupState == "PENDING" then
            self.reason = "Waiting for native group membership to become readable before cleanup."
            self:Log("queue group", "cleanup waiting for native group proof")
        elseif groupState == "EXACT" and t and (t.ownedParty or self:AdoptOwnedParty(t)) and self.env.party(t.peer) then
            if self.env.now() - (t.cleanupAt or -math.huge) >= 5 then
                t.cleanupAt = self.env.now(); self.env.leave(t.peer, true)
            end
            self.reason = "Waiting for the queue group to close."
        else self.reason = "Leave the changed group before joining the queue again." end
        if not self.env.solo() then return end
    end
    local wait = self.requeueWait
    self.ticket, self.session, self.ownProfile, self.queuedAt, self.requeueWait = nil, nil, nil, nil, nil
    self.state = "IDLE"
    self:Log("queue state", "IDLE")
    if wait then
        local ok, reason = self:Join(wait)
        if not ok then self.reason = reason end
    end
end

function Queue:Leave()
    if self.session and self.ownProfile then
        for _, peer in pairs(self.peers) do
            self.env.send({ kind = "LEAVE", session = self.session, guid = self.ownProfile.guid }, peer.fullName, self)
        end
    end
    if self.state ~= "IDLE" then self:Cancel("CANCELLED", false) end
    return true
end

function Queue:OnDuel(kind, match)
    if self.state == "IDLE" or self.state == "CLEANUP" then return end
    local t = self.ticket
    if kind == "request" then
        local own = self:RefreshOwn()
        local atVenue = t and validPosition(own) and t.venue and own.mapID == t.venue.mapID
            and own.continentID == t.venue.continentID and distance(own, t.venue) <= 40
        if t and self.state == "READY" and self.env.epoch() < t.deadline and match and match.opponent.guid == t.peer.guid
            and match.opponent.fullName == t.peer.fullName and atVenue and self.env.coLocated(t.peer) then
            self.state, self.reason, t.duelMatch, t.deadline = "DUEL", "The existing rated duel flow now controls this match.", match, nil
            self:Log("queue state", "DUEL")
            self.env.render()
        else self:Cancel("DUEL", false) end
    elseif t and self.state == "DUEL" and t.duelMatch == match then
        if kind == "finished" then self:Cancel("FINISHED", false)
        elseif kind == "abort" or kind == "unrated" then self:Cancel("DUEL", false) end
    end
end

function Queue:World(leaving, logout)
    if logout then self:Leave(); return end
    self.loadingAt = leaving and self.env.now() or nil
end

function Queue:ExpireTravel(received)
    local t = self.ticket
    local own = self:RefreshOwn()
    local known = not self.loadingAt and validPosition(own)
    local atVenue = known and own.mapID == t.venue.mapID and own.continentID == t.venue.continentID
        and distance(own, t.venue) <= 40 and t.ownArrived
    if atVenue and not t.peerArrived then return self:Cancel("TRAVEL_TIMEOUT", true, received) end
    if known and not atVenue and not (own.mapID == t.venue.mapID
        and own.continentID == t.venue.continentID and distance(own, t.venue) <= 40) then
        local s = FD.Copy(self:Settings()); s.cooldownUntil = self.env.epoch() + 120; self.env.save(s)
        return self:Cancel("TRAVEL_TIMEOUT", false, received)
    end
    return self:Cancel("TECHNICAL", false, received)
end

function Queue:Arrival()
    local t, own = self.ticket, self:RefreshOwn()
    local known = validPosition(own) and own.continentID == t.venue.continentID
    local atVenue = known and own.mapID == t.venue.mapID and distance(own, t.venue) <= 40
    t.samples = atVenue and t.samples + 1 or 0
    if t.samples >= 3 and self.env.epoch() < t.travelDeadline then t.arrivedBeforeDeadline = true end
    t.ownArrived, t.ownArrivalKnown = t.samples >= 3 and t.arrivedBeforeDeadline or false, validPosition(own) and not self.loadingAt
    local peerFresh = t.peerPositionAt and self.env.now() - t.peerPositionAt <= 5
    local pp = t.peerPosition
    t.peerArrived = peerFresh and validPosition(pp) and pp.mapID == t.venue.mapID
        and pp.continentID == t.venue.continentID and distance(pp, t.venue) <= 40
        and t.peerArrivalAt and self.env.now() - t.peerArrivalAt <= 5 or false
    if t.ownArrived then self:Send("ARRIVED") end
    local colocated = t.ownArrived and t.peerArrived and self.env.coLocated(t.peer)
    if colocated and (self.state == "READY" or self.env.epoch() < t.travelDeadline) then
        self:Send("READY", { deadline = self.state == "READY" and t.deadline or 0 })
        if t.peerReadyAt and self.env.now() - t.peerReadyAt <= 5 and self.state == "TRAVELLING"
            and (t.coordinator or t.readyProposal and t.readyProposal > self.env.epoch()) then
            self.state, self.reason, t.deadline = "READY", "Both players are ready. Start the normal duel request.",
                t.coordinator and self.env.epoch() + 120 or t.readyProposal
            self:Log("queue state", "READY")
            self:Send("READY", { deadline = t.deadline })
            self.env.render()
        end
    elseif self.state == "READY" then
        self:Cancel("TECHNICAL", false)
        return
    end
    if self.env.epoch() >= t.deadline then
        if self.state == "READY" then return self:Cancel("START_TIMEOUT", false) end
        self:ExpireTravel(false)
    end
end

function Queue:Tick()
    local now = self.env.now()
    if self.state == "CLEANUP" then self:Cleanup(); return end
    if self.state == "IDLE" then return end
    if self.loadingAt then
        if now - self.loadingAt > 45 then self:Cancel("TECHNICAL", false)
        elseif self.ticket and self.ticket.deadline and self.env.epoch() >= self.ticket.deadline then self:Cancel("TECHNICAL", false) end
        return
    end
    if self.state == "SEARCHING" or self.state == "PAUSED" then
        local available, reason = self.env.available()
        local own = self:RefreshOwn()
        if not available or self.env.combat() or not own or not validPosition(own) then
            self.state, self.reason = "PAUSED", reason or "Waiting for combat or readable position data."
            self.env.render(); return
        end
        self.state = "SEARCHING"
        self:QueryPeer()
        local peer = self:SelectPeer()
        if peer and own.guid < peer.guid then
            self:Reserve(peer, own.session .. "." .. peer.session, true)
            self:Send("OFFER")
        end
        self.env.render(); return
    end
    local t = self.ticket
    if not t then return end
    if self.state == "DUEL" then return end
    if now - t.lastPeerAt > 45 then return self:Cancel("TECHNICAL", false) end
    local groupState
    if self.state == "GROUPING" or self.state == "PLANNING" then
        if now - t.groupAt >= 60 then return self:Cancel("GROUP_TIMEOUT", false) end
        groupState = self:GroupState(t.peer)
        if groupState == "CHANGED" then
            self:Log("queue group", "native group changed")
            return self:Cancel("TECHNICAL", false)
        end
        if groupState == "EXACT" and not self:AdoptOwnedParty(t) then groupState = "PENDING" end
        if groupState == "PENDING" then
            if self.state == "PLANNING" and now - t.planAt >= 20 then
                self:Log("queue planning", "planning confirmation deadline expired")
                return self:Cancel("TECHNICAL", false)
            end
            self.reason = "Waiting for native group membership to become readable."
            self:Log("queue group", "native group proof pending")
            self:GroupingHeartbeat(now, false)
            self.env.render()
            return
        end
    end
    local previous = t.player
    local current = self:RefreshOwn()
    if not current or current.level ~= previous.level or current.maxLevel ~= previous.maxLevel
        or current.rating ~= previous.rating or not self:Eligible(t.peer) then return self:Cancel("TECHNICAL", false) end
    if self.state == "RESERVING" then
        if now - t.createdAt >= 20 then return self:Cancel("TECHNICAL", false) end
        if now - t.lastSend >= 2 then
            self:Send(t.coordinator and (t.acknowledged and "COMMIT" or "OFFER") or "ACK")
            t.lastSend = now
        end
        return
    end
    if self.state == "GROUPING" or self.state == "PLANNING" then
        self:GroupingHeartbeat(now, groupState == "EXACT")
        if self.state == "GROUPING" then self:BeginPlan() end
        if self.state == "PLANNING" and now - t.planAt >= 20 then self:Cancel("TECHNICAL", false) end
        return
    end
    if not self.env.party(t.peer) then return self:Cancel("TECHNICAL", false) end
    if now - t.lastSend >= 2 then
        local p = self:PositionPacket(); if p then self:Send("POSITION", p) end
        if t.coordinator and self.state == "TRAVELLING" and not t.travelConfirmed then self:Send("GO", self:PlanFields()) end
        t.lastSend = now
    end
    self:Arrival()
    self.env.render()
end
