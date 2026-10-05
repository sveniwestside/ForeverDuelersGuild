local _, FD = ...
local Duel = {}
FD.Duel = Duel
Duel.__index = Duel

-- Consent lives in the state, not in independent toggles. Evidence of game
-- events is separate and cannot be supplied by a peer's consent messages.
local transitions = {
    CHECKING_ADDON = { DISCOVERY_WAIT = true, READY = true, UNRATED = true },
    DISCOVERY_WAIT = { READY = true, UNRATED = true },
    READY = { LOCAL_ACCEPTED = true, REMOTE_ACCEPTED = true, UNRATED = true },
    LOCAL_ACCEPTED = { PREPARED = true, UNRATED = true },
    REMOTE_ACCEPTED = { PREPARED = true, UNRATED = true },
    PREPARED = { COMMIT_SENT = true, RATED_CONFIRMED = true, UNRATED = true },
    COMMIT_SENT = { RATED_CONFIRMED = true, UNRATED = true },
    RATED_CONFIRMED = { COUNTDOWN = true, UNRATED = true },
    COUNTDOWN = { IN_PROGRESS = true, UNRATED = true },
    IN_PROGRESS = { FINISHING = true, UNRATED = true },
    FINISHING = { FINISHED = true, UNRATED = true },
    UNRATED = { UNRATED_ACTIVE = true },
    UNRATED_ACTIVE = {}, FINISHED = {},
}

function Duel:New(env, database)
    return setmetatable({ env = env, db = database }, self)
end

function Duel:Notify(kind, match)
    -- The optional matchmaking layer must never interrupt duel evidence.
    if self.env.notify then pcall(self.env.notify, kind, match) end
end

function Duel:State()
    return self.active and self.active.state or "IDLE"
end

function Duel:Transition(nextState)
    local m = self.active
    if not m or not transitions[m.state] or not transitions[m.state][nextState] then
        self.env.log("rejected transition", self:State(), nextState)
        return false
    end
    self.env.log("state", m.state, "->", nextState, m.matchId or m.nonce)
    m.state = nextState
    if nextState == "RATED_CONFIRMED" then m.confirmedAt = self.env.epoch() end
    self.env.render(m)
    return true
end

function Duel:Later(seconds, match, callback)
    self.env.after(seconds, function()
        if self.active == match then callback() end
    end)
end

function Duel:RetryDiscovery(match, delay)
    self:Later(delay, match, function()
        if (match.state ~= "CHECKING_ADDON" and match.state ~= "DISCOVERY_WAIT")
            or match.nativeAccepted or match.countdownAt or match.startedAt
            or self.env.now() - match.createdAt >= FD.C.PENDING_TIMEOUT then return end
        if self:Send("HELLO") then self:RetryDiscovery(match, FD.C.HELLO_RETRY_INTERVAL) end
    end)
end

function Duel:Begin(role, player, opponent, requestedAt)
    self:Abort("new duel request", true)
    if not player or not opponent or player.guid == opponent.guid then return false end
    local counter = self.db:NextCounter()
    if not counter then return false end
    local bracket, levelReason = FD.Rating:Eligible(player, opponent)
    self.db:SetBracket(player)
    local stats = self.db:GetStats(bracket)
    local m = {
        state = "CHECKING_ADDON", role = role,
        bracket = bracket,
        player = FD.Copy(player), opponent = FD.Copy(opponent),
        ratingBefore = stats.rating, wins = stats.wins, losses = stats.losses,
        nonce = FD.Protocol:Nonce(self.env.epoch(), counter, self.env.random()),
        createdAt = requestedAt or self.env.now(),
    }
    self.active = m
    self:Notify("request", m)
    self.env.log("duel detected", role, opponent.fullName, m.nonce)
    self.env.render(m)
    if not bracket then
        local reasons = {
            invalid_level = "Rated unavailable: both player levels must be known",
            different_level_cap = "Rated unavailable: clients disagree on the maximum level",
            different_rating_bracket = "Rated unavailable: Leveling and Max level use separate ratings",
            level_difference_too_large = "Rated unavailable: players must be within 5 levels of each other",
        }
        self:Unrate(reasons[levelReason] or "Rated unavailable: level information missing", false)
        self.env.print(m.reason)
    else
        self:Send("HELLO")
    end
    self:RetryDiscovery(m, 1)
    self:Later(FD.C.PRESENCE_TIMEOUT, m, function()
        -- Discovery can arrive late while the same native request is pending.
        -- This is only a UI timeout; explicit unrated choices remain terminal.
        if m.state == "CHECKING_ADDON" then self:Transition("DISCOVERY_WAIT") end
    end)
    self:Later(math.max(0, FD.C.PENDING_TIMEOUT - (self.env.now() - m.createdAt)), m, function()
        if not m.startedAt then
            if m.role == "INCOMING" and not m.nativeAccepted then
                self:Unrate("pending request expired", true)
                -- If combat prevents restoration, retain our ordinary buttons
                -- until the request is accepted/declined or natively finishes.
                if self.env.restore(m) == false then return end
            end
            self:Abort("pending request expired", true)
        end
    end)
    return true
end

function Duel:Packet(kind, verdict)
    local m = self.active
    return {
        kind = kind, nonce = m.nonce, echo = kind == "HELLO" and "-" or m.peerNonce,
        guid = m.player.guid, peerGUID = m.opponent.guid, role = m.role,
        rating = m.ratingBefore, specId = m.player.specId or 0,
        classFile = m.player.classFile, wins = m.wins, losses = m.losses,
        level = m.player.level, maxLevel = m.player.maxLevel,
        verdict = verdict or "-",
    }
end

function Duel:Send(kind, verdict, helloEcho)
    local m = self.active
    local replyNonce = kind == "HELLO_ACK" and helloEcho or nil
    if not m or (kind ~= "HELLO" and not m.peerNonce and not replyNonce) then return false end
    local values = self:Packet(kind, verdict)
    if replyNonce then values.echo = replyNonce end
    local packet, err = FD.Protocol:Encode(values)
    if not packet then
        self.env.log("encode failed", err)
        if kind ~= "CANCEL" then self:Unrate("protocol unavailable", false) end
        return false
    end
    self.env.log("send", kind, m.matchId or m.nonce)
    if not self.env.send(packet, m.opponent.fullName, m) then
        if kind ~= "CANCEL" then self:Unrate("communication unavailable", false) end
        return false
    end
    return true
end

function Duel:Fresh()
    local m = self.active
    local current = self.env.identity()
    if not m or not current then return false end
    local stats = self.db:GetStats(m.bracket)
    local opponent = self.env.opponentIdentity and self.env.opponentIdentity(m.opponent)
    if self.env.opponentIdentity and not opponent and not m.startedAt then return false end
    if opponent and (opponent.guid ~= m.opponent.guid or opponent.level ~= m.opponent.level
        or opponent.maxLevel ~= m.opponent.maxLevel) then return false end
    return current.guid == m.player.guid
        and (current.specId or 0) == (m.player.specId or 0)
        and current.level == m.player.level and current.maxLevel == m.player.maxLevel
        and FD.Rating:Eligible(current, m.opponent) == m.bracket
        and stats and stats.rating == m.ratingBefore
end

function Duel:ArmNegotiation()
    local m = self.active
    if m.negotiationDeadline then return end
    m.negotiationDeadline = self.env.now() + FD.C.NEGOTIATION_TIMEOUT
    self:Later(FD.C.NEGOTIATION_TIMEOUT, m, function()
        if not m.countdownAt then self:Unrate("rated confirmation timed out", true) end
    end)
end

function Duel:AcceptRated()
    local m = self.active
    if not m or (m.state ~= "READY" and m.state ~= "REMOTE_ACCEPTED") then return end
    if not self:Fresh() then return self:Unrate("player snapshot changed", true) end
    self:ArmNegotiation()
    self:Transition(m.state == "READY" and "LOCAL_ACCEPTED" or "PREPARED")
    if self:Send("ACCEPT") then self:Prepare() end
end

function Duel:Prepare()
    local m = self.active
    if m.state == "PREPARED" and m.role == "OUTGOING" then
        self:Transition("COMMIT_SENT")
        self:Send("COMMIT")
    end
end

function Duel:RepeatDiscoveryConsent()
    local m = self.active
    if m.state == "LOCAL_ACCEPTED" or m.state == "PREPARED" then
        -- The peer may have ignored our explicit ACCEPT before discovery
        -- completed there. Repeat only consent already granted by this user.
        self:Send("ACCEPT")
    end
end

-- Explain rejected discovery without weakening native identity or consent.
-- Diagnostics never include packet bodies or request nonces, and logging must
-- not interrupt the duel if an optional diagnostic sink fails.
function Duel:PeerValidation(accepted, reason, packet, detail, unrateReason)
    local status = (packet and packet.kind or "packet") .. " | " .. reason
    if detail then status = status .. " | " .. detail end
    status = status:sub(1, 320)
    local m = self.active
    if m then m.peerStatus = status end
    if self.env.log then pcall(self.env.log, "peer validation", status) end
    if unrateReason then self:Unrate(unrateReason, true) end
    return accepted, status
end

function Duel:Receive(packet, sender)
    local m = self.active
    if not m then return self:PeerValidation(false, "no pending native request") end
    if sender ~= m.opponent.fullName then
        return self:PeerValidation(false, "sender mismatch", nil,
            "expected=" .. tostring(m.opponent.fullName) .. "; received=" .. tostring(sender))
    end
    local p, err = FD.Protocol:Decode(packet)
    if not p then return self:PeerValidation(false, "invalid envelope", nil, err) end
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
    if m.state == "UNRATED" or m.state == "UNRATED_ACTIVE" then
        return self:PeerValidation(false, "rated discovery is closed", p, "state=" .. m.state)
    end
    if p.level ~= m.opponent.level or p.maxLevel ~= m.opponent.maxLevel
        or FD.Rating:Eligible(m.player, p) ~= m.bracket then
        return self:PeerValidation(false, "native level or level cap mismatch", p,
            "expected=" .. tostring(m.opponent.level) .. "/" .. tostring(m.opponent.maxLevel)
                .. "; received=" .. p.level .. "/" .. p.maxLevel,
            not (p.kind == "HELLO" and not m.peerNonce)
                and "Rated unavailable: opponent level or rating group changed" or nil)
    end
    if p.kind == "HELLO" or p.kind == "HELLO_ACK" then
        -- Re-acknowledge a matching discovery retry even after local consent.
        if m.nativeAccepted or m.countdownAt or m.startedAt
            or self.env.now() - m.createdAt >= FD.C.PENDING_TIMEOUT then
            return self:PeerValidation(false, "native request no longer accepts discovery", p)
        end
        if p.classFile ~= m.opponent.classFile then
            return self:PeerValidation(false, "native class mismatch", p,
                "expected=" .. tostring(m.opponent.classFile) .. "; received=" .. p.classFile,
                not (p.kind == "HELLO" and not m.peerNonce) and "opponent identity mismatch" or nil)
        end
        if m.peer and not self:SameProfile(p) then
            return self:PeerValidation(false, "confirmed peer profile changed", p, nil, "opponent snapshot changed")
        end
        if p.kind == "HELLO" then
            -- HELLO has no echoed nonce and may belong to an earlier duel.
            -- Reply without freezing its nonce/profile into the new request.
            local queued = self:Send("HELLO_ACK", nil, p.nonce)
            self:RepeatDiscoveryConsent()
            return self:PeerValidation(queued, queued and "native peer verified; acknowledgment queued"
                or "acknowledgment could not be queued", p)
        end
        m.peerNonce, m.peer = p.nonce, FD.Copy(p)
        m.opponentRatingBefore = p.rating
        m.opponent.specId = p.specId ~= 0 and p.specId or nil
        m.opponent.specSource = p.specId ~= 0 and "peer-self-report" or nil
        m.matchId = FD.Protocol:MatchID(m.player.guid, m.nonce, m.opponent.guid, m.peerNonce)
        -- An echoed nonce establishes that the peer has this particular request.
        if p.kind == "HELLO_ACK" and (m.state == "CHECKING_ADDON" or m.state == "DISCOVERY_WAIT") then
            self:Transition("READY")
            -- Echo the peer's nonce once as well. Its earlier HELLOs may have
            -- arrived before our native outgoing request was acknowledged.
            -- Sending only on this transition makes duplicates settle.
            self:Send("HELLO_ACK")
        end
        self:RepeatDiscoveryConsent()
        return self:PeerValidation(true, "current native request acknowledged", p)
    end
    if not m.peer then return self:PeerValidation(false, "current request not acknowledged", p) end
    if not self:SameProfile(p) then return self:PeerValidation(false, "confirmed peer profile mismatch", p) end
    self:PeerValidation(true, "bound peer profile accepted", p)
    self.env.log("receive", p.kind, m.matchId)
    if p.kind == "CANCEL" then return self:Unrate("opponent kept duel unrated", false) end
    if p.kind == "ACCEPT" then
        if m.state == "READY" or m.state == "LOCAL_ACCEPTED" then
            self:ArmNegotiation()
            self:Transition(m.state == "READY" and "REMOTE_ACCEPTED" or "PREPARED")
            self:Prepare()
        end
    elseif p.kind == "COMMIT" and m.role == "INCOMING" and m.state == "PREPARED" then
        if not self:Fresh() then return self:Unrate("player snapshot changed", true) end
        self:Transition("RATED_CONFIRMED")
        self:Send("CONFIRM")
    elseif p.kind == "CONFIRM" and m.role == "OUTGOING" and m.state == "COMMIT_SENT" then
        if not self:Fresh() then return self:Unrate("player snapshot changed", true) end
        self:Transition("RATED_CONFIRMED")
        self:Send("START_OK")
    elseif p.kind == "START_OK" and m.role == "INCOMING" and m.state == "RATED_CONFIRMED" then
        if m.nativeAccepted then return end
        if not self:Fresh() then return self:Unrate("player snapshot changed", true) end
        m.nativeAccepted = true
        self.env.hide()
        if not self.env.accept() then
            m.nativeAccepted = nil
            self:Unrate("native acceptance failed", true)
            self.env.restore(m)
        end
        self:Later(FD.C.START_TIMEOUT, m, function()
            if not m.countdownAt then
                m.nativeAccepted = nil
                self:Unrate("native duel start was not observed", true)
                self.env.restore(m)
            end
        end)
    elseif p.kind == "START" then
        if m.state == "RATED_CONFIRMED" or m.state == "COUNTDOWN" or m.state == "IN_PROGRESS" or m.state == "FINISHING" then
            m.peerStart = true
            self:FinalizeMatch()
        end
    elseif p.kind == "RESULT" and (m.state == "IN_PROGRESS" or m.state == "FINISHING") then
        if m.peerWinner and m.peerWinner ~= p.verdict then return self:Unrate("contradictory peer result", true) end
        m.peerWinner = p.verdict
        self:StartFinishing()
        self:FinalizeMatch()
    end
end

function Duel:SameProfile(p)
    local peer = self.active.peer
    return peer and p.rating == peer.rating and p.specId == peer.specId
        and p.classFile == peer.classFile and p.wins == peer.wins and p.losses == peer.losses
        and p.level == peer.level and p.maxLevel == peer.maxLevel
end

-- Called ONLY for a locally observed, localized duel countdown system message.
-- This adapter is deliberately conservative; see docs/API_VERIFICATION.md.
function Duel:Countdown(seconds)
    local m = self.active
    if not m or m.countdownAt then return end
    if m.state ~= "RATED_CONFIRMED" or not self:Fresh() then
        self:Unrate("duel accepted before rated agreement", true)
        m.nativeAccepted = true
        if m.state == "UNRATED" then self:Transition("UNRATED_ACTIVE") end
        self.env.hide()
        return
    end
    if type(seconds) ~= "number" or seconds < 1 or seconds > 10 then return end
    m.countdownAt = self.env.epoch()
    self:Transition("COUNTDOWN")
    self.env.hide()
    self:Send("START")
    self:Later(seconds, m, function()
        if m.state == "COUNTDOWN" then
            if not self:Fresh() then return self:Unrate("player or opponent level changed", true) end
            m.startedAt = self.env.epoch()
            self:Transition("IN_PROGRESS")
            self.env.hide()
        end
    end)
    self:Later(FD.C.MATCH_TIMEOUT, m, function() self:Abort("match expired", true) end)
end

function Duel:StartFinishing()
    local m = self.active
    if m.state ~= "IN_PROGRESS" then return end
    self:Transition("FINISHING")
    self:Later(FD.C.RESULT_TIMEOUT, m, function()
        self.env.print("Match not rated: result could not be confirmed by both clients.")
        self:Abort("missing result evidence", true)
    end)
end

function Duel:Finished()
    local m = self.active
    if not m then return end
    if m.state ~= "IN_PROGRESS" and m.state ~= "FINISHING" then
        return self:Abort("duel ended without rated start", true)
    end
    if not m.finishedAt then m.finishedAt = self.env.epoch() end
    self:StartFinishing()
    self:ReportResult()
end

function Duel:Result(winnerGUID, source)
    local m = self.active
    if not m or (m.state ~= "IN_PROGRESS" and m.state ~= "FINISHING") then return end
    if winnerGUID ~= m.player.guid and winnerGUID ~= m.opponent.guid then return end
    if m.localWinner and m.localWinner ~= winnerGUID then return self:Unrate("contradictory local result", true) end
    m.localWinner, m.resultSource = winnerGUID, source
    self:StartFinishing()
    self:ReportResult()
end

function Duel:ReportResult()
    local m = self.active
    if not self:Fresh() then return self:Unrate("player or opponent snapshot changed", true) end
    if m.finishedAt and m.localWinner and not m.resultSent then
        m.resultSent = true
        self:Send("RESULT", m.localWinner)
        local packet = FD.Protocol:Encode(self:Packet("RESULT", m.localWinner))
        -- Cache the immutable report so a client which finalized first can
        -- still help its peer recover from a lost message. Finite retries are
        -- not an atomic two-client commit or a delivery guarantee.
        if packet then
            for attempt = 1, FD.C.RESULT_RETRIES do
                self.env.after(attempt * FD.C.RESULT_RETRY_INTERVAL, function()
                    if m.finalized or (self.active == m and m.state == "FINISHING") then
                        self.env.send(packet, m.opponent.fullName, m)
                    end
                end)
            end
        end
    end
    self:FinalizeMatch()
end

function Duel:FinalizeMatch()
    local m = self.active
    if not m or m.state ~= "FINISHING" or m.finalized then return false end
    if not (m.countdownAt and m.startedAt and m.finishedAt and m.peerStart and m.localWinner and m.peerWinner) then return false end
    if m.localWinner ~= m.peerWinner then self:Unrate("clients disagree on winner", true); return false end
    if not self:Fresh() then self:Unrate("player or opponent snapshot changed", true); return false end
    local won = m.localWinner == m.player.guid
    local after, delta = FD.Rating:Calculate(m.ratingBefore, m.opponentRatingBefore, won, m.player.level, m.opponent.level)
    local record = {
        schemaVersion = FD.C.SCHEMA_VERSION, protocolVersion = FD.C.PROTOCOL_VERSION,
        addonVersion = FD.C.VERSION,
        bracket = m.bracket,
        matchId = m.matchId, player = FD.Copy(m.player), opponent = FD.Copy(m.opponent),
        startedAt = m.startedAt, endedAt = m.finishedAt, countdownAt = m.countdownAt,
        confirmedAt = m.confirmedAt, startSource = "localized-countdown-plus-timer",
        winnerGUID = m.localWinner, loserGUID = won and m.opponent.guid or m.player.guid,
        result = won and "WIN" or "LOSS", ratingBefore = m.ratingBefore,
        ratingAfter = after, ratingDelta = delta, opponentRatingBefore = m.opponentRatingBefore,
        ratedConfirmed = true, resultSource = m.resultSource,
        evidence = { agreedBeforeStart = true, localResult = true, peerResult = true },
    }
    local ok, err = self.db:Commit(record)
    if not ok then self.env.log("commit rejected", err); self:Abort("commit rejected", true); return false end
    m.finalized = true
    self:Transition("FINISHED")
    self.env.log("finalized", m.matchId, m.ratingBefore, after, delta)
    self.env.print(string.format("%s vs %s: %+.0f rating (%d).", record.result, m.opponent.fullName, delta, after))
    self.last = { state = "FINISHED", matchId = m.matchId, reason = record.result }
    self.active = nil
    self.env.hide()
    self:Notify("finished", m)
    return true
end

function Duel:Unrate(reason, notify)
    local m = self.active
    if not m or m.state == "UNRATED" or m.state == "UNRATED_ACTIVE" or m.state == "FINISHED" then return end
    if notify then self:Send("CANCEL") end
    m.reason = reason
    self:Transition("UNRATED")
    self:Notify("unrated", m)
    if m.countdownAt or m.startedAt or m.nativeAccepted then self.env.hide() end
    self.env.log("unrated", reason)
end

function Duel:ContinueUnrated()
    local m = self.active
    if not m or m.countdownAt or m.startedAt or m.nativeAccepted then return end
    self:Unrate("explicitly unrated", true)
    self.env.hide()
    if m.role == "INCOMING" then
        m.nativeAccepted = true
        if not self.env.accept() then m.nativeAccepted = nil; self.env.restore(m) end
    end
end

function Duel:Decline()
    local m = self.active
    if not m or m.countdownAt or m.startedAt then return end
    self:Abort("declined", true)
    if not self.env.decline() then self.env.restore(m) end
end

function Duel:Abort(reason, notify)
    local m = self.active
    if m then
        if notify then self:Send("CANCEL") end
        self.last = { state = "CANCELLED", reason = reason, matchId = m.matchId }
        self.env.log("state", m.state, "-> CANCELLED -> IDLE", reason)
    end
    self.active = nil
    self.env.hide()
    if m then self:Notify("abort", m) end
end
