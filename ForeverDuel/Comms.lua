local _, FD = ...
FD.Comms = {}
local Comms = FD.Comms

-- Rated-duel transport. Pacing, budgets, retries and the PARTY->WHISPER
-- fallback belong to FD.Outbound; this module only binds packets to their
-- match (drain validity, route) and applies the native receive gates.

function Comms:Initialize()
    self.available = FD.Outbound:Register(FD.C.PREFIX) == true
    return self.available
end

-- The exact native two-player party with the bound opponent, checked at
-- drain time: membership may change while a packet waits in the queue.
function Comms:ExactDuelParty(match)
    local ok, exact = pcall(function()
        if not match or not match.player or not match.opponent
            or type(IsInGroup) ~= "function" or type(IsInRaid) ~= "function"
            or type(GetNumGroupMembers) ~= "function" then return false end
        local grouped, raid, members = IsInGroup(), IsInRaid(), GetNumGroupMembers()
        if not FD.Wow:Readable(grouped, raid, members)
            or grouped ~= true or raid ~= false or members ~= 2 then return false end
        local own, peer = FD.Wow:Identity("player", true), FD.Wow:Identity("party1")
        if type(own) ~= "table" or type(peer) ~= "table"
            or not FD.Wow:Readable(own.guid, peer.guid, peer.fullName) then return false end
        return own.guid == match.player.guid and peer.guid == match.opponent.guid
            and peer.fullName == match.opponent.fullName
    end)
    return ok and exact == true
end

function Comms:Route(match)
    if self:ExactDuelParty(match) then return "PARTY" end
    return "WHISPER", match.opponent.fullName
end

local function current(match, kind)
    return FD.duel ~= nil and FD.duel:Current(match, kind)
end

function Comms:Submitted(item, route, status, code)
    local m = item.match
    local last = FD.Outbound.lastResult
    local channel = route or ((status == "sent" or status == "failed") and last and last.channel) or "-"
    self.lastSend = string.format("%s to %s via %s (%s%s)", item.kind, m.opponent.fullName, channel, status,
        code ~= nil and (", " .. FD.Outbound:CodeName(code)) or "")
    self.lastSendAt = GetTime()
    FD.Debug:Log("transport send", item.kind, "to", m.opponent.fullName, "via", channel, status)
    if type(item.onResult) == "function" then item.onResult(status, code) end
end

-- item = { match, kind, payload, ttl, key, immediate, whisperCopy, onResult }
function Comms:Send(item)
    local m, kind = item.match, item.kind
    if not self.available or type(m) ~= "table" or type(item.payload) ~= "string" then return false end
    local packet = {
        prefix = FD.C.PREFIX, payload = item.payload, channel = "WHISPER", target = m.opponent.fullName,
        priority = FD.Outbound.CONTROL, ttl = item.ttl, owner = m,
        key = item.key and (kind .. ":" .. item.key .. ":" .. m.nonce) or nil,
        isCurrent = function() return current(m, kind) end,
        route = function() return self:Route(m) end,
        -- Outbound swallows callback errors; FD:Safe records them and stops the rated flow.
        onResult = function(status, code) FD:Safe(self.Submitted, self, item, nil, status, code) end,
    }
    if item.immediate then
        FD.Outbound:SendNow(packet)
        return true
    end
    local queued = FD.Outbound:Send(packet)
    if queued and item.whisperCopy and self:ExactDuelParty(m) then
        -- Grouped discovery also whispers its first HELLO once: the peer's
        -- own roster view may not be exact yet. Redundant, never fatal.
        FD.Outbound:Send({ prefix = FD.C.PREFIX, payload = item.payload, channel = "WHISPER",
            target = m.opponent.fullName, priority = FD.Outbound.CONTROL, ttl = item.ttl, owner = m,
            isCurrent = function() return current(m, kind) and self:ExactDuelParty(m) end,
            onResult = function(status, code) FD:Safe(self.Submitted, self, { match = m, kind = kind }, "WHISPER", status, code) end })
    end
    return queued
end

function Comms:Pending(match)
    return FD.Outbound:Pending(function(item) return item.owner == match end)
end

function Comms:RememberValidation(accepted, status, match)
    if match and self.validationMatch ~= match then
        self.validationMatch, self.lastRejection = match, nil
    end
    self.lastValidation = status
    self.lastValidationAt = GetTime()
    -- A peer's retry after a manual Decline must not erase the rejection that
    -- prevented discovery while that native request was still open.
    if accepted == false and match then
        self.lastRejection, self.lastRejectionAt = status, GetTime()
    end
end

function Comms:Own()
    local own = FD.Wow:Identity("player", true)
    if type(own) == "table" and FD.Wow:Readable(own.guid, own.fullName, own.realm, own.nameFormat) then return own end
end

-- Native PARTY broadcasts echo to their sender. Require both the own GUID in
-- the payload and the own native sender spelling before ignoring one.
function Comms:IsOwnPartyEcho(packet, sender, own)
    if type(packet) ~= "table" or not own or packet.guid ~= own.guid then return false end
    if own.nameFormat ~= "surname" and not sender:find("-", 1, true) then
        if type(own.realm) ~= "string" or own.realm == "" then return false end
        sender = sender .. "-" .. own.realm
    end
    return sender == own.fullName
end

-- A bare sender is the local realm; surname senders keep their exact spelling.
local function qualified(sender, own)
    if not own or own.nameFormat == "surname" or sender:find("-", 1, true)
        or type(own.realm) ~= "string" or own.realm == "" then return sender end
    return sender .. "-" .. own.realm
end

function Comms:Receive(prefix, payload, channel, sender)
    if not FD.Wow:Readable(prefix, payload, channel, sender) then return end
    if prefix ~= FD.C.PREFIX or (channel ~= "WHISPER" and channel ~= "PARTY") or not FD.duel then return end
    if type(payload) ~= "string" or type(sender) ~= "string" or sender == "" then return end
    local decoded = FD.Protocol:Decode(payload)
    local ok, own = pcall(self.Own, self)
    own = ok and own or nil
    if channel == "PARTY" and self:IsOwnPartyEcho(decoded, sender, own) then return end
    -- PARTY needs no own-roster check: the server supplies the sender, and the
    -- envelope is still bound to both GUIDs and nonces.
    sender = qualified(sender, own)
    local kind = decoded and decoded.kind or (FD.Protocol:Legacy(payload) and "FD2 packet") or "invalid packet"
    local m = FD.duel.active
    local hadRTT = m and m.rtt
    local accepted, status = FD.duel:Receive(payload, sender)
    self.lastReceive = kind .. " from " .. sender .. " via " .. channel
    self.lastReceiveAt = GetTime()
    if m and m.rtt and not hadRTT then
        FD.Debug:Log("transport receive", kind, "from", sender, "via", channel, "state", FD.duel:State(),
            "rtt", string.format("%.1f", m.rtt))
    else
        FD.Debug:Log("transport receive", kind, "from", sender, "via", channel, "state", FD.duel:State())
    end
    pcall(self.RememberValidation, self, accepted, status, m)
end

FD:RegisterStatus(25, function()
    local lines, m = {}, FD.duel and FD.duel.active
    if m then lines[#lines + 1] = string.format("Queued duel packets: %d", Comms:Pending(m)) end
    if Comms.lastSend then
        lines[#lines + 1] = "Last send: " .. Comms.lastSend
            .. string.format(" | %.1fs ago", GetTime() - (Comms.lastSendAt or GetTime()))
    end
    if Comms.lastReceive then
        lines[#lines + 1] = "Last receive: " .. Comms.lastReceive
            .. string.format(" | %.1fs ago", GetTime() - (Comms.lastReceiveAt or GetTime()))
    end
    if m and Comms.validationMatch ~= m then
        lines[#lines + 1] = "Peer validation: no packet received for the current request"
    elseif Comms.lastValidation then
        lines[#lines + 1] = "Peer validation: " .. Comms.lastValidation
            .. string.format(" | %.1fs ago", GetTime() - (Comms.lastValidationAt or GetTime()))
    end
    if Comms.lastRejection and Comms.lastRejection ~= Comms.lastValidation then
        lines[#lines + 1] = "Last pending rejection: " .. Comms.lastRejection
            .. string.format(" | %.1fs ago", GetTime() - (Comms.lastRejectionAt or GetTime()))
    end
    return lines
end)
