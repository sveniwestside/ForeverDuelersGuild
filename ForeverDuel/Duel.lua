local _, FD = ...
local Duel = {}
FD.Duel = Duel
Duel.__index = Duel

-- Consent lives in the state, not in independent toggles. Evidence of game
-- events is separate and can never be supplied by a peer's consent messages.
--   CHECKING_ADDON   native request seen, peer not yet proven
--   READY            peer echoed this exact request's nonce
--   LOCAL_ACCEPTED   own explicit rated consent, peer consent not yet seen
--   REMOTE_ACCEPTED  peer consent seen, own consent not yet given
--   RATED_CONFIRMED  both consents bound to both nonces; INCOMING calls
--                    AcceptDuel on entry, OUTGOING waits for the countdown
--   COUNTDOWN .. FINISHED   locally observed native evidence
--   UNRATED, UNRATED_ACTIVE rated play is over for this request
local transitions = {
    CHECKING_ADDON = { READY = true, UNRATED = true },
    READY = { LOCAL_ACCEPTED = true, REMOTE_ACCEPTED = true, UNRATED = true },
    -- OUTGOING only: see Countdown for why a countdown here is tentatively rated.
    LOCAL_ACCEPTED = { RATED_CONFIRMED = true, COUNTDOWN = true, UNRATED = true },
    REMOTE_ACCEPTED = { RATED_CONFIRMED = true, UNRATED = true },
    RATED_CONFIRMED = { COUNTDOWN = true, UNRATED = true },
    COUNTDOWN = { IN_PROGRESS = true, UNRATED = true },
    IN_PROGRESS = { FINISHING = true, UNRATED = true },
    FINISHING = { FINISHED = true, UNRATED = true },
    UNRATED = { UNRATED_ACTIVE = true },
    UNRATED_ACTIVE = {}, FINISHED = {},
}

-- Reason codes. A code travels as the CANCEL `r` field; each has the local
-- wording and the wording shown to the peer that receives it.
local reasons = {
    choice = { "You kept this duel unrated", "Your opponent chose an unrated duel" },
    started = { "The duel started before both players agreed to a rated duel",
        "The duel started before both players agreed to a rated duel" },
    lost = { "The addon lost track of your opponent", "Your opponent's addon lost track of you" },
    combat = { "Combat started", "Combat started" },
    level = { "A level changed", "A level changed" },
    spec = { "Your specialization changed", "Your opponent's specialization changed" },
    rating = { "Your rating changed", "Your opponent's rating changed" },
    expired = { "The request expired", "The request expired" },
    outdated = { "Your opponent uses an older ForeverDuel version", "Your opponent uses an older ForeverDuel version" },
    error = { "Addon error", "Addon error" },
    accept = { "The duel could not be accepted automatically", "Your opponent's client could not accept the duel" },
    timeout = { "The duel did not start after your acceptance", "Your opponent's client did not observe the duel start" },
    transport = { "Addon messages could not be sent", "Your opponent's addon messages could not be sent" },
    disagree = { "The clients disagree on the winner", "The clients disagree on the winner" },
    cancelled = { "The duel request was cancelled", "The duel request was cancelled" },
    replaced = { "A new duel request replaced this one", "Your opponent started a new duel request" },
    world = { "You left the world", "Your opponent logged out or changed zones" },
    invalid_level = { "Rated unavailable: both player levels must be known" },
    different_level_cap = { "Rated unavailable: clients disagree on the maximum level" },
    different_rating_bracket = { "Rated unavailable: Leveling and Max level use separate ratings" },
    level_difference_too_large = { "Rated unavailable: players must be within 5 levels of each other" },
}
local aliases = { ["addon error"] = "error" }
local evidenceStates = { LOCAL_ACCEPTED = true, RATED_CONFIRMED = true, COUNTDOWN = true, IN_PROGRESS = true, FINISHING = true }

local function closed(m)
    return m.state == "UNRATED" or m.state == "UNRATED_ACTIVE" or m.state == "FINISHED"
end

function Duel:New(env, database)
    return setmetatable({ env = env, db = database, recent = {} }, self)
end

function Duel:Notify(kind, match)
    -- The optional matchmaking layer must never interrupt duel evidence.
    if self.env.notify then pcall(self.env.notify, kind, match) end
end

function Duel:State()
    return self.active and self.active.state or "IDLE"
end

-- A match keeps running timers while it is active or parked for results.
function Duel:Owns(m)
    return m ~= nil and (self.active == m or self.parked == m)
end

function Duel:Transition(nextState, m)
    m = m or self.active
    if not m or not transitions[m.state] or not transitions[m.state][nextState] then
        self.env.log("rejected transition", m and m.state or "IDLE", nextState)
        return false
    end
    self.env.log("state", m.state, "->", nextState)
    m.state = nextState
    if nextState == "RATED_CONFIRMED" then m.confirmedAt = self.env.epoch() end
    if m == self.active then self.env.render(m) end
    return true
end

function Duel:Later(seconds, m, callback)
    self.env.after(seconds, function()
        if self:Owns(m) then callback() end
    end)
end

-- The human decision window is the native request; nothing else expires it.
function Duel:Pending(m)
    return not m.nativeAccepted and not m.countdownAt and not m.startedAt and self.env.now() < m.deadline
end

function Duel:Engaged(m)
    return m.peerNonce ~= nil or m.engaged == true
end

function Duel:ReasonText(m)
    local code = m and m.reason
    if type(code) ~= "string" then return FD.L["Rated unavailable"] end
    local peerCode = code:match("^peer:(.+)$")
    local entry = reasons[peerCode or code]
    if peerCode then return FD.L[entry and entry[2] or "Your opponent's addon stopped rated play"] end
    return FD.L[entry and entry[1] or code]
end

-- Drain validity for queued packets: obsolete consent or discovery must never
-- leave after cancellation, a rematch or the native start.
function Duel:Current(m, kind)
    if kind == "CANCEL" then return true end
    if kind == "RESULT" or kind == "START" then
        return m.finalized == true or (self:Owns(m) and m.countdownAt ~= nil and evidenceStates[m.state] == true)
    end
    if self.active ~= m or closed(m) then return false end
    -- INCOMING's own ACCEPT may still drain after its native accept.
    if kind == "ACCEPT" then return m.localConsent == true and not m.countdownAt and self.env.now() < m.deadline end
    if not self:Pending(m) then return false end
    if kind == "HELLO" then return m.state == "CHECKING_ADDON" end
    return true
end

function Duel:Packet(m, kind, verdict, echo)
    return {
        kind = kind, nonce = m.nonce, echo = kind == "HELLO" and "-" or echo or m.peerNonce,
        guid = m.player.guid, peerGUID = m.opponent.guid, role = m.role,
        rating = m.ratingBefore, specId = m.player.specId or 0,
        classFile = m.player.classFile, wins = m.wins, losses = m.losses,
        level = m.player.level, maxLevel = m.player.maxLevel,
        verdict = verdict or "-",
    }
end

-- options: verdict, echo, reason, mandatory, ttl, key, immediate, whisperCopy.
-- A mandatory packet unrates the match when it cannot be submitted before its
-- deadline. Redundant copies (discovery retries, duplicate ACKs, retransmits,
-- result retries and answers) never do.
function Duel:Send(m, kind, options)
    options = options or {}
    local echo = options.echo or m.peerNonce or (kind == "CANCEL" and m.heardNonce or nil)
    if kind ~= "HELLO" and not echo then return false end
    local values = self:Packet(m, kind, options.verdict, echo)
    if kind == "HELLO" or kind == "HELLO_ACK" then values.version = FD.C.VERSION end
    if kind == "CANCEL" and type(options.reason) == "string" and options.reason:match("^%l[%l_]*$")
        and #options.reason <= 16 then values.reason = options.reason end
    local payload, err = FD.Protocol:Encode(values)
    if not payload then
        self.env.log("error", "encode " .. kind, err)
        if options.mandatory then self:Unrate("error", false, "encode failed", m) end
        return false
    end
    local mandatory = options.mandatory
    local queued = self.env.send({ match = m, kind = kind, payload = payload, ttl = options.ttl,
        key = options.key, immediate = options.immediate, whisperCopy = options.whisperCopy,
        onResult = function(status)
            if status == "sent" then
                if kind == "HELLO" and not m.helloSentAt then m.helloSentAt = self.env.now() end
            elseif mandatory and (status == "failed" or status == "expired") and self:Current(m, kind) then
                self:Unrate("transport", kind ~= "RESULT", kind .. " " .. status, m)
            end
        end })
    if not queued and mandatory and self:Current(m, kind) then
        self:Unrate("transport", false, kind .. " not queued", m)
    end
    return queued == true
end

-- Answer one discovery packet per peer nonce at most every ACK_INTERVAL.
function Duel:Ack(m, nonce)
    local now = self.env.now()
    if m.acked[nonce] and now - m.acked[nonce] < FD.C.ACK_INTERVAL then return false end
    m.acked[nonce] = now
    return self:Send(m, "HELLO_ACK", { echo = nonce, key = nonce })
end

function Duel:Supersede(reason)
    local m = self.active
    if m and m.state == "FINISHING" and not m.finalized then
        -- A rematch must not discard the previous duel's result exchange.
        -- One bounded slot; its own result timeout still applies.
        if self.parked then self:Drop(self.parked, "replaced") end
        self.parked, self.active = m, nil
        self.env.log("state", "FINISHING", "-> PARKED")
        self.env.hide()
        return
    end
    self:Abort(reason, true)
end

-- Returns false and an English reason when rated tracking cannot start. The
-- previous request is superseded either way: the native acknowledgment or
-- DUEL_REQUESTED that led here already replaced it in the game.
function Duel:Begin(role, player, opponent, requestedAt)
    self:Supersede("replaced")
    if not player then return false, "your character could not be identified" end
    if not opponent or player.guid == opponent.guid then return false, "the requested player could not be identified" end
    local counter = self.db:NextCounter()
    if not counter then return false, "the duel history is unavailable" end
    local bracket, levelReason = FD.Rating:Eligible(player, opponent)
    self.db:SetBracket(player)
    local stats = self.db:GetStats(bracket)
    local now = self.env.now()
    local createdAt = requestedAt or now
    local m = {
        state = "CHECKING_ADDON", role = role, bracket = bracket,
        player = FD.Copy(player), opponent = FD.Copy(opponent),
        ratingBefore = stats.rating, wins = stats.wins, losses = stats.losses,
        nonce = FD.Protocol:Nonce(self.env.epoch(), counter, self.env.random()),
        createdAt = createdAt, deadline = createdAt + FD.C.PENDING_TIMEOUT,
        -- Server time of the native request, to reject HELLOs of older requests.
        requestEpoch = self.env.epoch() - math.floor(math.max(0, now - createdAt)),
        acked = {},
    }
    self.active = m
    self:Notify("request", m)
    self.env.log("duel detected", role, opponent.fullName)
    if not bracket then
        self:Unrate(levelReason or "invalid_level", false, nil, m)
        -- Unknown players get nothing; known addon users learn why.
        if self.env.known and self.env.known(m.opponent) then self.env.print(self:ReasonText(m)) end
    elseif self.parked then
        -- The previous duel's result may still change this rating: discovery
        -- (and the snapshot it announces) waits until that match settles.
        m.held = true
    else
        self:Discover(m)
    end
    self:Later(math.max(0, m.deadline - now), m, function() self:Expire(m) end)
    return true
end

function Duel:Discover(m)
    m.held = nil
    local stats = self.db:GetStats(m.bracket)
    m.ratingBefore, m.wins, m.losses = stats.rating, stats.wins, stats.losses
    local function hello()
        if self:Current(m, "HELLO") then
            self:Send(m, "HELLO", { key = "HELLO", whisperCopy = not m.helloQueued })
            m.helloQueued = true
        end
    end
    hello()
    for index = 2, #FD.C.HELLO_SCHEDULE do self:Later(FD.C.HELLO_SCHEDULE[index], m, hello) end
    self:Later(FD.C.DELAY_NOTICE, m, function()
        if self:Current(m, "HELLO") and not m.heard and self.env.known and self.env.known(m.opponent) then
            self.env.print(FD.Locale:Format("Addon messages to %s are delayed. Rated play becomes available if they arrive before the request expires.",
                m.opponent.fullName))
        end
    end)
end

-- The parked match settled: a held request may now announce its snapshot.
function Duel:Release()
    local m = self.active
    if m and m.held and m.state == "CHECKING_ADDON" and self:Pending(m) then self:Discover(m) end
end

-- A native accept settles its own window (NativeAccept, ObservedAccept).
function Duel:Expire(m)
    if self.active ~= m or m.countdownAt or m.nativeAccepted or m.startedAt then return end
    -- The INCOMING window starts later than ours; with both consents the
    -- peer can still accept natively at the very end of its window. The grace
    -- keeps the match, never the deadline: the panel still closes on time.
    if m.role == "OUTGOING" and m.localConsent and not m.graced and not closed(m) then
        m.graced = true
        return self:Later(FD.C.START_TIMEOUT, m, function() self:Expire(m) end)
    end
    local open = not closed(m)
    if open and self:Engaged(m) then
        self.env.print(FD.Locale:Format("This duel will be UNRATED: %s.", FD.L[reasons.expired[1]]))
    end
    -- A closed match already told its peer why.
    self:Abort("expired", open)
end

-- No countdown START_TIMEOUT after a native accept: the accept had no effect
-- (or its countdown went unseen), so nothing is left to observe. Release the
-- match so a new request and the queue are not blocked. Never a CANCEL once a
-- countdown was observed.
function Duel:AcceptTimeout(m)
    self:Later(FD.C.START_TIMEOUT, m, function()
        if m.countdownAt or self.active ~= m then return end
        if not closed(m) then
            self:Unrate("timeout", true, nil, m)
            if m.acceptedBy == "addon" then
                -- The addon hid Blizzard's popup after its own AcceptDuel.
                self.env.print(FD.Locale:Format("If no duel started, ask %s to challenge you again.", m.opponent.fullName))
            end
        end
        self:Drop(m, "timeout")
    end)
end

-- Own-player checks are strict. The opponent was bound at Begin: a unit that
-- cannot be resolved right now (target cleared, stealth, nameplates off) is
-- unknown, not changed. Only a positively observed different GUID or level
-- fails. Returns ok, reason code, diagnostic detail.
function Duel:Fresh(m)
    local current = self.env.identity()
    if not current then return false, "lost", "own identity unavailable" end
    if current.guid ~= m.player.guid then return false, "lost", "own character changed" end
    if (current.specId or 0) ~= (m.player.specId or 0) then return false, "spec", "own specialization changed" end
    if current.level ~= m.player.level or current.maxLevel ~= m.player.maxLevel then
        return false, "level", "own level changed"
    end
    if FD.Rating:Eligible(current, m.opponent) ~= m.bracket then return false, "level", "rating group changed" end
    local stats = self.db:GetStats(m.bracket)
    if not stats or stats.rating ~= m.ratingBefore then return false, "rating", "own rating changed" end
    local seen = self.env.opponentIdentity and self.env.opponentIdentity(m.opponent)
    if seen then
        if seen.guid ~= m.opponent.guid then return false, "lost", "opponent unit has another GUID" end
        if seen.level and (seen.level ~= m.opponent.level or seen.maxLevel ~= m.opponent.maxLevel) then
            return false, "level", "opponent level changed"
        end
    end
    return true
end

function Duel:AcceptRated()
    local m = self.active
    if not m or (m.state ~= "READY" and m.state ~= "REMOTE_ACCEPTED") or not self:Pending(m) then return false end
    if self.env.combat and self.env.combat() then return false end
    local fresh, code, detail = self:Fresh(m)
    if not fresh then self:Unrate(code, true, detail); return false end
    m.localConsent = true
    self:Transition(m.state == "READY" and "LOCAL_ACCEPTED" or "RATED_CONFIRMED", m)
    local function accept(first)
        if (first or not m.nativeAccepted) and self:Current(m, "ACCEPT")
            and (m.state == "LOCAL_ACCEPTED" or m.state == "RATED_CONFIRMED") then
            self:Send(m, "ACCEPT", { mandatory = first, ttl = first and math.max(1, m.deadline - self.env.now()) or nil })
        end
    end
    accept(true)
    -- Idempotent retransmits until the next state; duplicates are ignored.
    for index = 2, #FD.C.ACCEPT_SCHEDULE do
        self:Later(FD.C.ACCEPT_SCHEDULE[index], m, function() accept(false) end)
    end
    self:NativeAccept(m)
    return true
end

-- INCOMING accepts natively only here: own consent plus the peer's ACCEPT.
function Duel:NativeAccept(m)
    if m.role ~= "INCOMING" or m.state ~= "RATED_CONFIRMED" or m.nativeAccepted or not self:Pending(m) then return end
    local fresh, code, detail = self:Fresh(m)
    if not fresh then return self:Unrate(code, true, detail, m) end
    -- Set first: the AcceptDuel hook must recognize the addon's own accept.
    m.nativeAccepted, m.acceptedBy = true, "addon"
    if not self.env.accept() then
        m.nativeAccepted, m.acceptedBy = nil, nil
        return self:Unrate("accept", true, nil, m)
    end
    self.env.render(m)
    self:AcceptTimeout(m)
end

function Duel:KeepUnrated()
    local m = self.active
    if not m or m.countdownAt or m.nativeAccepted or closed(m) then return false end
    self:Unrate("choice", true)
    return true
end

-- Explain rejected packets without weakening native identity or consent.
-- Diagnostics never include packet bodies or nonces, and a failing
-- diagnostic sink must not interrupt the duel.
function Duel:PeerValidation(accepted, reason, packet, detail, unrateCode)
    local status = (packet and packet.kind or "packet") .. " | " .. reason
    if detail then status = status .. " | " .. detail end
    status = status:sub(1, 320)
    local m = self.active
    if m then m.peerStatus = status end
    if self.env.log then pcall(self.env.log, "peer validation", status) end
    if unrateCode then self:Unrate(unrateCode, true, reason) end
    return accepted, status
end

function Duel:Outdated(payload, sender)
    local m, legacy = self.active, FD.Protocol:Legacy(payload)
    if not m or not legacy or sender ~= m.opponent.fullName or legacy.guid ~= m.opponent.guid then return false end
    if not m.peerOutdated then
        m.peerOutdated, m.engaged = true, true
        self.env.log("version mismatch", "FD2", m.opponent.fullName)
        self.env.print(FD.L["Your opponent uses an older ForeverDuel version. Rated duels need version 0.6 or newer on both sides."])
        self:Unrate("outdated", false, nil, m, true)
    end
    return true
end

-- Late START/RESULT for a parked or recently finalized match, by nonce.
function Duel:Settle(p, sender)
    local m = self.parked
    local function owns(match)
        return match and p.nonce == match.peerNonce and p.echo == match.nonce
            and sender == match.opponent.fullName and p.guid == match.opponent.guid
    end
    if owns(m) then self:Evidence(m, p); return true, "parked match evidence accepted" end
    local now, kept = self.env.now(), {}
    for _, entry in ipairs(self.recent) do
        if now - entry.at < FD.C.RECENT_TTL then kept[#kept + 1] = entry end
    end
    self.recent = kept
    for _, entry in ipairs(kept) do
        if owns(entry.match) then
            -- The peer missed our report: answer from the immutable record.
            -- Two finalized clients would answer each other's answers, so
            -- answers are spaced and bounded by the peer's retry count.
            local answers = entry.answers or 0
            if answers < #FD.C.RESULT_SCHEDULE and now - (entry.answeredAt or -math.huge) >= 1 then
                entry.answers, entry.answeredAt = answers + 1, now
                self:Send(entry.match, "RESULT", { verdict = entry.match.localWinner, key = "ANSWER" })
                return true, "finalized match answered"
            end
            return true, "finalized match recently answered"
        end
    end
    return false
end

function Duel:Receive(payload, sender)
    local p, err = FD.Protocol:Decode(payload)
    if not p then
        if self:Outdated(payload, sender) then return self:PeerValidation(false, "opponent uses protocol 2") end
        return self:PeerValidation(false, "invalid envelope", nil, err)
    end
    if p.kind == "RESULT" or p.kind == "START" then
        local settled, status = self:Settle(p, sender)
        if settled then
            if self.env.log then pcall(self.env.log, "peer validation", p.kind .. " | " .. status) end
            return true, status
        end
    end
    local m = self.active
    if not m then return self:PeerValidation(false, "no pending native request", p) end
    if sender ~= m.opponent.fullName then
        return self:PeerValidation(false, "sender mismatch", p,
            "expected=" .. tostring(m.opponent.fullName) .. "; received=" .. tostring(sender))
    end
    if p.guid ~= m.opponent.guid then
        return self:PeerValidation(false, "opponent GUID mismatch", p,
            "expected=" .. m.opponent.guid .. "; received=" .. p.guid)
    end
    if p.peerGUID ~= m.player.guid then
        return self:PeerValidation(false, "local GUID mismatch", p,
            "expected=" .. m.player.guid .. "; received=" .. p.peerGUID)
    end
    if p.role == m.role then
        return self:PeerValidation(false, "duel roles are not complementary", p,
            "local=" .. m.role .. "; received=" .. p.role)
    end
    if p.kind ~= "HELLO" and p.echo ~= m.nonce then
        return self:PeerValidation(false, "acknowledgment belongs to another request", p)
    end
    if m.peerNonce and p.nonce ~= m.peerNonce then
        return self:PeerValidation(false, "peer belongs to another request", p)
    end
    if closed(m) then return self:PeerValidation(false, "rated discovery is closed", p, "state=" .. m.state) end
    if m.held then return self:PeerValidation(false, "waiting for the previous duel result", p) end
    -- Echoed packets prove the peer holds this request; a bare HELLO does not.
    local proven = p.kind ~= "HELLO" or m.peerNonce ~= nil
    if p.level ~= m.opponent.level or p.maxLevel ~= m.opponent.maxLevel
        or FD.Rating:Eligible(m.player, p) ~= m.bracket then
        return self:PeerValidation(false, "native level or level cap mismatch", p,
            "expected=" .. tostring(m.opponent.level) .. "/" .. tostring(m.opponent.maxLevel)
                .. "; received=" .. p.level .. "/" .. p.maxLevel, proven and "level" or nil)
    end
    if p.classFile ~= m.opponent.classFile then
        return self:PeerValidation(false, "native class mismatch", p,
            "expected=" .. tostring(m.opponent.classFile) .. "; received=" .. p.classFile, proven and "lost" or nil)
    end
    if m.peer and not self:SameProfile(m, p) then
        return self:PeerValidation(false, "confirmed peer profile changed", p, nil, "lost")
    end
    if p.kind == "CANCEL" then
        m.engaged = true
        local code = p.reason or "unknown"
        self.env.log("cancel received", code)
        self:Unrate("peer:" .. code, false, nil, m)
        return self:PeerValidation(true, "peer cancelled rated play", p, code)
    end
    if p.kind == "HELLO" then
        if not self:Pending(m) then return self:PeerValidation(false, "native request no longer accepts discovery", p) end
        local epoch = FD.Protocol:NonceEpoch(p.nonce)
        if epoch and epoch < m.requestEpoch - FD.C.STALE_HELLO then
            return self:PeerValidation(false, "stale request", p)
        end
        -- HELLO may belong to an earlier duel: reply without freezing its
        -- nonce or profile. Only an echo of our nonce binds the peer.
        m.heard, m.heardNonce = true, p.nonce
        local queued = self:Ack(m, p.nonce)
        return self:PeerValidation(true, queued and "native peer verified; acknowledgment queued"
            or "native peer verified; acknowledgment recently sent", p)
    end
    if not m.peerNonce then
        if not self:Pending(m) then return self:PeerValidation(false, "native request no longer accepts discovery", p) end
        self:Bind(m, p)
    end
    if p.kind == "ACCEPT" then
        m.peerConsent = true
        if m.state == "READY" then self:Transition("REMOTE_ACCEPTED", m)
        elseif m.state == "LOCAL_ACCEPTED" and self:Pending(m) then
            self:Transition("RATED_CONFIRMED", m)
            self:NativeAccept(m)
        elseif m.countdownAt then
            self:Announce(m)
        end
    elseif p.kind == "START" or p.kind == "RESULT" then
        self:Evidence(m, p)
    end
    return self:PeerValidation(true, "current native request acknowledged", p)
end

function Duel:Bind(m, p)
    m.peerNonce, m.peer, m.heard = p.nonce, FD.Copy(p), true
    m.peerVersion = p.version
    m.opponentRatingBefore = p.rating
    m.opponent.specId = p.specId ~= 0 and p.specId or nil
    m.opponent.specSource = p.specId ~= 0 and "peer-self-report" or nil
    m.matchId = FD.Protocol:MatchID(m.player.guid, m.nonce, m.opponent.guid, m.peerNonce)
    self:Transition("READY", m)
    if p.kind == "HELLO_ACK" then
        if m.helloSentAt then m.rtt = self.env.now() - m.helloSentAt end
        -- The peer may still need our echo of its nonce (its HELLOs can
        -- predate our request); once, subject to the per-nonce ACK interval.
        self:Ack(m, p.nonce)
    end
end

-- START and RESULT, for the active or a parked match. A valid bound RESULT
-- is produced only after the peer's own native start, so it also proves START.
function Duel:Evidence(m, p)
    if not evidenceStates[m.state] then return end
    if p.kind == "START" then
        m.peerStart, m.peerConsent = true, true
    elseif m.countdownAt then
        if m.peerWinner and m.peerWinner ~= p.verdict then
            return self:Unrate("disagree", true, "contradictory peer result", m)
        end
        m.peerWinner, m.peerStart, m.peerConsent = p.verdict, true, true
        self:StartFinishing(m)
    end
    -- A tentative countdown is now confirmed (in FINISHING the result line follows).
    if m.countdownAt and self.active == m then self:Announce(m) end
    self:FinalizeMatch(m)
end

function Duel:SameProfile(m, p)
    local peer = m.peer
    return peer and p.rating == peer.rating and p.specId == peer.specId
        and p.classFile == peer.classFile and p.wins == peer.wins and p.losses == peer.losses
        and p.level == peer.level and p.maxLevel == peer.maxLevel
end

-- Outcome line at the native countdown. The RATED line needs the peer's
-- consent: OUTGOING's countdown can precede INCOMING's ACCEPT (see Countdown)
-- and a receiver who pressed Blizzard's Accept makes it unrated, so until the
-- peer's ACCEPT, START or RESULT arrives the line only says it is pending.
function Duel:Announce(m)
    if m.state == "COUNTDOWN" or m.state == "IN_PROGRESS" then
        if m.announced then return end
        if not m.peerConsent then
            if not m.tentative then
                m.tentative = true
                self.env.print(FD.Locale:Format("Waiting for %s to confirm the RATED duel.", m.opponent.fullName))
            end
            return
        end
        m.announced = true
        local _, gain = FD.Rating:Calculate(m.ratingBefore, m.opponentRatingBefore, true, m.player.level, m.opponent.level)
        local _, loss = FD.Rating:Calculate(m.ratingBefore, m.opponentRatingBefore, false, m.player.level, m.opponent.level)
        self.env.print(FD.Locale:Format("RATED duel vs %s (win %+d / loss %+d).", m.opponent.fullName, gain or 0, loss or 0))
    elseif m.state == "UNRATED_ACTIVE" and self:Engaged(m) then
        self.env.print(FD.Locale:Format("This duel is UNRATED: %s.", self:ReasonText(m)))
    end
end

-- Called ONLY for a locally observed, localized duel countdown system message.
--
-- Why a countdown is rated without a further confirmation round trip:
-- INCOMING calls AcceptDuel only from RATED_CONFIRMED, i.e. holding its own
-- consent and the peer's ACCEPT, both bound to both nonces. Its START (or a
-- RESULT, which it sends only after its own rated start) therefore proves its
-- consent. OUTGOING may still be in LOCAL_ACCEPTED while INCOMING's ACCEPT is
-- in flight; its countdown is tentatively rated and finalization still needs
-- the peer's START or RESULT plus agreeing results. Every unrated path on
-- either side (Blizzard's Accept, Keep unrated, combat, level change, ...)
-- sends CANCEL and suppresses START and RESULT, so a tentative countdown can
-- never finalize without both consents.
function Duel:Countdown(seconds)
    local m = self.active
    if not m or m.countdownAt then return end
    if type(seconds) ~= "number" or seconds < 1 or seconds > 10 then return end
    local rated = (m.role == "INCOMING" and m.state == "RATED_CONFIRMED" and m.nativeAccepted)
        or (m.role == "OUTGOING" and (m.state == "LOCAL_ACCEPTED" or m.state == "RATED_CONFIRMED"))
    local fresh, code, detail = true, nil, nil
    if rated then fresh, code, detail = self:Fresh(m) end
    m.countdownAt = self.env.epoch()
    if not rated or not fresh then
        m.nativeAccepted = true
        if not closed(m) then self:Unrate(rated and code or "started", m.peerNonce ~= nil, detail, m, true) end
        if m.state == "UNRATED" then self:Transition("UNRATED_ACTIVE", m) end
        self:Announce(m)
        self.env.hide()
        -- DUEL_FINISHED normally ends it; never keep a missed one forever.
        self:Later(FD.C.MATCH_TIMEOUT, m, function() self:Drop(m, "expired") end)
        return
    end
    self:Transition("COUNTDOWN", m)
    self:Announce(m)
    self.env.hide()
    local function start()
        if self:Current(m, "START") then self:Send(m, "START") end
    end
    start()
    self:Later(FD.C.START_REPEAT, m, start)
    self:Later(seconds, m, function()
        if m.state ~= "COUNTDOWN" then return end
        local ok, reason, why = self:Fresh(m)
        if not ok then return self:Unrate(reason, true, why, m) end
        m.startedAt = self.env.epoch()
        self:Transition("IN_PROGRESS", m)
    end)
    self:Later(FD.C.MATCH_TIMEOUT, m, function() self:Drop(m, "expired") end)
end

function Duel:StartFinishing(m)
    if m.state ~= "IN_PROGRESS" then return end
    self:Transition("FINISHING", m)
    self:Later(FD.C.RESULT_TIMEOUT, m, function()
        if m.state ~= "FINISHING" then return end
        self.env.print(FD.L["Match not rated: result could not be confirmed by both clients."])
        self.env.log("unrated", "result timeout")
        -- No CANCEL after the native countdown for a timing reason.
        self:Drop(m, "result")
    end)
end

function Duel:Finished()
    local m = self.active
    if not m then return end
    if m.state ~= "IN_PROGRESS" and m.state ~= "FINISHING" then return self:Abort("ended", false) end
    if not m.finishedAt then m.finishedAt = self.env.epoch() end
    self:StartFinishing(m)
    self:ReportResult(m)
end

function Duel:Result(winnerGUID, source, m)
    m = m or self.active
    if not m or not self:Owns(m) or (m.state ~= "IN_PROGRESS" and m.state ~= "FINISHING") then return end
    if winnerGUID ~= m.player.guid and winnerGUID ~= m.opponent.guid then return end
    if m.localWinner and m.localWinner ~= winnerGUID then return self:Unrate("disagree", true, "contradictory local result", m) end
    m.localWinner, m.resultSource = winnerGUID, source
    self:StartFinishing(m)
    self:ReportResult(m)
end

function Duel:ReportResult(m)
    local fresh, code, detail = self:Fresh(m)
    if not fresh then return self:Unrate(code, true, detail, m) end
    if m.finishedAt and m.localWinner and not m.resultSent then
        m.resultSent = true
        self:Send(m, "RESULT", { verdict = m.localWinner, mandatory = true, ttl = FD.C.RESULT_TIMEOUT })
        -- Retries only until this client finalizes; afterwards the recent-match
        -- cache answers each late peer RESULT with this same report.
        for _, offset in ipairs(FD.C.RESULT_SCHEDULE) do
            self:Later(offset, m, function()
                if m.state == "FINISHING" then self:Send(m, "RESULT", { verdict = m.localWinner }) end
            end)
        end
    end
    self:FinalizeMatch(m)
end

function Duel:FinalizeMatch(m)
    if not m or m.state ~= "FINISHING" or m.finalized then return false end
    if not (m.countdownAt and m.startedAt and m.finishedAt and m.peerStart and m.localWinner and m.peerWinner) then return false end
    if m.localWinner ~= m.peerWinner then self:Unrate("disagree", true, nil, m); return false end
    local fresh, code, detail = self:Fresh(m)
    if not fresh then self:Unrate(code, true, detail, m); return false end
    local won = m.localWinner == m.player.guid
    local after, delta = FD.Rating:Calculate(m.ratingBefore, m.opponentRatingBefore, won, m.player.level, m.opponent.level)
    local record = {
        schemaVersion = FD.C.SCHEMA_VERSION, protocolVersion = FD.C.PROTOCOL_VERSION,
        addonVersion = FD.C.VERSION,
        bracket = m.bracket,
        matchId = m.matchId, player = FD.Copy(m.player), opponent = FD.Copy(m.opponent),
        startedAt = m.startedAt, endedAt = m.finishedAt, countdownAt = m.countdownAt,
        confirmedAt = m.confirmedAt or m.countdownAt, startSource = "localized-countdown-plus-timer",
        winnerGUID = m.localWinner, loserGUID = won and m.opponent.guid or m.player.guid,
        result = won and "WIN" or "LOSS", ratingBefore = m.ratingBefore,
        ratingAfter = after, ratingDelta = delta, opponentRatingBefore = m.opponentRatingBefore,
        ratedConfirmed = true, resultSource = m.resultSource,
        evidence = { agreedBeforeStart = true, localResult = true, peerResult = true },
    }
    local ok, err = self.db:Commit(record)
    if not ok then
        self.env.log("error", "commit rejected", err)
        self:Unrate("error", true, "commit rejected", m)
        return false
    end
    m.finalized = true
    self:Transition("FINISHED", m)
    self.env.log("finalized", m.ratingBefore, after, delta)
    self.env.print(FD.Locale:Format(won and "Rated WIN vs %s: %+d rating (%d)." or "Rated LOSS vs %s: %+d rating (%d).",
        m.opponent.fullName, delta, after))
    self.recent[#self.recent + 1] = { match = m, at = self.env.now() }
    while #self.recent > FD.C.RECENT_MATCHES do table.remove(self.recent, 1) end
    self.last = { state = "FINISHED", matchId = m.matchId, reason = record.result }
    if self.active == m then
        self.active = nil
        self.env.hide()
    elseif self.parked == m then
        self.parked = nil
        self:Release()
    end
    self:Notify("finished", m)
    return true
end

-- quiet: the caller prints its own outcome line.
function Duel:Unrate(code, notify, detail, m, quiet)
    m = m or self.active
    if not m or closed(m) then return end
    code = aliases[code] or code
    if notify then self:Send(m, "CANCEL", { reason = code }) end
    m.reason = code
    self:Transition("UNRATED", m)
    self.env.log("unrated", code, detail)
    if not quiet and self:Engaged(m) then
        -- "No longer" only after the RATED line; a tentative countdown was never called rated.
        local text = m.announced and "This duel is no longer rated: %s."
            or m.countdownAt and "This duel is UNRATED: %s." or "This duel will be UNRATED: %s."
        self.env.print(FD.Locale:Format(text, self:ReasonText(m)))
    end
    self:Notify("unrated", m)
    -- After the native duel ended (or for a parked match) nothing is left to observe.
    if m.finishedAt or self.parked == m then self:Drop(m, code) end
end

-- The AcceptDuel hook: an acceptance outside the rated path is final. The
-- countdown that follows announces the outcome, so this stays quiet.
function Duel:ObservedAccept()
    local m = self.active
    if not m or m.countdownAt then return end
    if m.role == "INCOMING" and m.nativeAccepted then return end
    self:Unrate("choice", true, "native accept", nil, true)
    m.nativeAccepted, m.acceptedBy = true, "native"
    self.env.hide()
    self:AcceptTimeout(m)
end

function Duel:Cancelled()
    local m = self.active
    if m and not m.countdownAt then self:Abort("cancelled", true) end
end

-- Remove the active or parked match without further evidence.
function Duel:Drop(m, reason)
    if self.active == m then return self:Abort(reason, false) end
    if self.parked == m then
        self.parked = nil
        self.env.log("state", m.state, "-> CANCELLED", reason)
        self:Notify("abort", m)
        self:Release()
    end
end

-- immediate: submit the CANCEL synchronously (logout, reload, party leave).
function Duel:Abort(reason, notify, immediate)
    reason = aliases[reason] or reason
    local m = self.active
    if m then
        if notify then self:Send(m, "CANCEL", { reason = reason, immediate = immediate }) end
        self.last = { state = "CANCELLED", reason = reason, matchId = m.matchId }
        self.env.log("state", m.state, "-> CANCELLED", reason)
    end
    self.active = nil
    self.env.hide()
    if m then self:Notify("abort", m) end
end
