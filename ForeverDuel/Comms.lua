local _, FD = ...
FD.Comms = { queue = {}, pumping = false, partyUnavailable = false }
local Comms = FD.Comms

function Comms:Initialize()
    if not C_ChatInfo or not C_ChatInfo.RegisterAddonMessagePrefix then return false end
    local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, FD.C.PREFIX)
    -- Retail returns an enum, NOT a truth value. Zero is success.
    local values = Enum and Enum.RegisterAddonMessagePrefixResult
    self.available = ok and values and (result == values.Success or result == values.DuplicatePrefix)
    FD.Debug:Log("addon prefix registration", ok and tostring(result) or "Lua error", self.available and "available" or "unavailable")
    return self.available
end

function Comms:Send(payload, target, match)
    if not self.available or #payload > FD.Protocol.MAX_BYTES or #self.queue >= FD.C.MAX_QUEUE then return false end
    pcall(self.InitializeIngressMatch, self, match)
    local reply, packet = self.loggedReply, FD.Protocol:Decode(payload)
    local loggedReply = self:LoggedAvailable() and reply and reply.match == match and packet and packet.kind == "HELLO_ACK"
        and packet.echo == reply.nonce and target == match.opponent.fullName
    self.queue[#self.queue + 1] = { payload = payload, target = target, match = match,
        logged = loggedReply == true, isolated = loggedReply == true }
    self:Pump()
    return true
end

function Comms:InitializeIngressMatch(match)
    if not match or not FD.duel or FD.duel.active ~= match then return false end
    if self.ingressStatusMatch ~= match then
        self.ingressStatusMatch = match
        self.ingressCounts = { normal = 0, logged = 0, passed = 0, rejected = 0 }
        self.ingressRecorded = {}
        self.ingressStatus = "no addon event observed for current native request"
        self.ingressStatusAt = GetTime()
    end
    return true
end

local ingressRoutes = { WHISPER = true, PARTY = true, RAID = true, GUILD = true, OFFICER = true,
    SAY = true, YELL = true, CHANNEL = true, INSTANCE_CHAT = true, WHISPER_INFORM = true }

function Comms:ObserveIngress(prefix, payload, channel, sender, loggedEvent)
    local match = FD.duel and FD.duel.active
    if not match then return end
    local logged, prefixReadable = loggedEvent == true, FD.Wow:Readable(prefix)
    -- Unrelated addons are never inspected. A restricted logged prefix permits
    -- only a generic event observation; none of its remaining fields are read.
    if (prefixReadable and prefix ~= FD.C.PREFIX) or (not prefixReadable and not logged) then return end
    if not self:InitializeIngressMatch(match) then return end
    local route, reason = "restricted", "restricted native prefix"
    if prefixReadable then
        local channelReadable = FD.Wow:Readable(channel)
        route = not channelReadable and "restricted" or type(channel) ~= "string" and "non-string"
            or ingressRoutes[channel] and channel or "other"
        if not FD.Wow:Readable(payload) then reason = "restricted native payload"
        elseif not channelReadable then reason = "restricted native channel"
        elseif not FD.Wow:Readable(sender) then reason = "restricted native sender"
        elseif channel ~= "WHISPER" and channel ~= "PARTY" then reason = "unsupported native channel"
        elseif logged and self.loggedReceiveAvailable ~= true then reason = "logged event registration unavailable"
        elseif logged and channel ~= "WHISPER" then reason = "logged event requires WHISPER"
        else reason = "entry gates passed; peer proof still required" end
    end
    local counts = self.ingressCounts
    local event = logged and "logged" or "normal"
    counts[event] = math.min(counts[event] + 1, 1000000)
    local passed = reason == "entry gates passed; peer proof still required"
    local outcome = passed and "passed" or "rejected"
    counts[outcome] = math.min(counts[outcome] + 1, 1000000)
    local status = event .. " event via " .. route .. " | " .. reason
    local now = GetTime()
    self.ingressStatus, self.ingressStatusAt = status, now
    -- The status vocabulary and route allowlist bound the keys. Identical
    -- rejects update counters while retaining only occasional trace summaries.
    local previous = self.ingressRecorded[status]
    if previous == nil or now - previous >= 10 then
        self.ingressRecorded[status] = now
        pcall(FD.Debug.Log, FD.Debug, "transport ingress", status)
    end
end

function Comms:LoggedAvailable()
    return self.loggedReceiveAvailable == true and C_ChatInfo
        and type(C_ChatInfo.SendAddonMessageLogged) == "function"
end

function Comms:LoggedStatus(match, status)
    self.loggedStatusMatch, self.loggedStatus, self.loggedStatusAt = match, status, GetTime()
    pcall(FD.Debug.Log, FD.Debug, "peer validation", status)
end

function Comms:PendingLoggedRequest(match)
    return self:LoggedAvailable() and FD.duel and FD.duel.active == match
        and not match.nativeAccepted and not match.countdownAt and not match.startedAt
        and GetTime() - match.createdAt < FD.C.PENDING_TIMEOUT
end

function Comms:CanProbe(match)
    return self:PendingLoggedRequest(match)
        and (match.state == "CHECKING_ADDON" or match.state == "DISCOVERY_WAIT") and not match.peerNonce
        and not self:ExactDuelParty(match, match.opponent.fullName)
end

function Comms:ScheduleLoggedProbe(match, payload, target)
    if match.loggedProbeScheduled or not self:LoggedAvailable() then return end
    match.loggedProbeScheduled = true
    C_Timer.After(4, function()
        -- A probe belongs only to this still-open native request. It cannot
        -- survive cancellation, a role reversal, native acceptance or rematch.
        local ok = pcall(function()
            if not self:CanProbe(match) then return end
            match.loggedProbeAttempted = true
            if #self.queue >= FD.C.MAX_QUEUE then
                self:LoggedStatus(match, "logged probe not queued: transport queue full")
                return
            end
            self.queue[#self.queue + 1] = { payload = payload, target = target, match = match,
                logged = true, isolated = true, probe = true }
            self:LoggedStatus(match, "logged probe queued; waiting for current request acknowledgment")
            self:Pump()
        end)
        if not ok then pcall(self.LoggedStatus, self, match, "logged probe unavailable; ordinary whisper remains active") end
    end)
end

function Comms:HelloSubmitted(match, route)
    local now = GetTime()
    match.firstHelloAt = match.firstHelloAt or now
    match.helloPaths = match.helloPaths or {}
    local path = match.helloPaths[route] or { first = now, count = 0 }
    path.last, path.count = now, path.count + 1
    match.helloPaths[route] = path
end

function Comms:RememberAcknowledgment(match, route)
    match.acknowledgmentRoutes = match.acknowledgmentRoutes or {}
    if match.acknowledgmentRoutes[route] then return end
    match.acknowledgmentRoutes[route] = true
    match.acknowledgmentObserved = true
    local now, path = GetTime(), match.helloPaths and match.helloPaths[route]
    local status = "current native request acknowledged via " .. route
    if match.firstHelloAt then
        status = status .. string.format("; %.1fs after first HELLO submission", now - match.firstHelloAt)
    end
    if path then
        status = status .. string.format("; latest %s HELLO %.1fs ago; %d submissions", route, now - path.last, path.count)
    end
    -- Retries reuse the current nonce: this is request age, not packet RTT.
    self:LoggedStatus(match, status)
end

function Comms:ExactDuelParty(match, requestedTarget)
    local ok, exact = pcall(function()
        if not match or not match.player or not match.opponent
            or type(IsInGroup) ~= "function" or type(IsInRaid) ~= "function"
            or type(GetNumGroupMembers) ~= "function" then return false end
        if not FD.Wow:Readable(requestedTarget) then return false end
        if requestedTarget ~= nil and (type(requestedTarget) ~= "string"
            or requestedTarget ~= match.opponent.fullName) then return false end
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

function Comms:Pump()
    if self.pumping or #self.queue == 0 then return end
    self.pumping = true
    C_Timer.After(FD.C.SEND_INTERVAL, function()
        self.pumping = false
        FD:Safe(function()
        local item = table.remove(self.queue, 1)
        local packet = FD.Protocol:Decode(item.payload)
        -- Do not send obsolete consent or results after cancellation/rematch.
        -- A result already locally finalized, and a cancellation, may drain.
        local valid = packet and (packet.kind == "CANCEL"
            or (packet.kind == "RESULT" and item.match.finalized)
            or (FD.duel and FD.duel.active == item.match
                and item.match.state ~= "UNRATED" and item.match.state ~= "UNRATED_ACTIVE"))
        if valid and (not item.probe or self:CanProbe(item.match))
            and (not item.isolated or item.probe or self:PendingLoggedRequest(item.match)) then
            -- Membership may have changed while this packet was queued. Never
            -- broadcast a duel packet to a third player or another opponent.
            local route = not self.partyUnavailable and type(item.target) == "string" and self:ExactDuelParty(item.match, item.target)
                and "PARTY" or "WHISPER"
            local target = route == "WHISPER" and item.target or nil
            local logged = route == "WHISPER" and item.target == item.match.opponent.fullName
                and self:LoggedAvailable() and (item.logged or item.match.loggedRoute == true)
            local nativeSend = logged and C_ChatInfo.SendAddonMessageLogged or C_ChatInfo.SendAddonMessage
            local path = logged and "LOGGED" or route
            local ok, result = pcall(nativeSend, FD.C.PREFIX, item.payload, route, target)
            local values = Enum and Enum.SendAddonMessageResult
            local readable = ok and FD.Wow:Readable(result)
            local resultText = not ok and "Lua error" or not readable and "restricted" or tostring(result)
            if logged and ok and readable and result == nil then resultText = "unknown submission" end
            self.lastSend = packet.kind .. " to " .. item.target .. " via " .. (logged and "LOGGED WHISPER" or route)
                .. " (" .. resultText .. ")"
            self.lastSendAt = GetTime()
            FD.Debug:Log("transport send", self.lastSend)
            -- Only explicit, non-delivery routing rejections permit one legacy
            -- whisper attempt. A throttle, unknown result or exception does not.
            local unsupported = route == "PARTY" and readable and values
                and type(values.InvalidChatType) == "number" and result == values.InvalidChatType
            local notGrouped = route == "PARTY" and readable and values
                and type(values.NotInGroup) == "number" and result == values.NotInGroup
            if unsupported or notGrouped then
                if unsupported then self.partyUnavailable = true end
                local reason = unsupported and "InvalidChatType" or "NotInGroup"
                ok, result = pcall(C_ChatInfo.SendAddonMessage, FD.C.PREFIX, item.payload, "WHISPER", item.target)
                readable = ok and FD.Wow:Readable(result)
                resultText = not ok and "Lua error" or not readable and "restricted" or tostring(result)
                self.lastSend = packet.kind .. " to " .. item.target .. " via WHISPER (" .. resultText
                    .. ") | PARTY rejected: " .. reason
                self.lastSendAt = GetTime()
                FD.Debug:Log("transport send", self.lastSend)
                path = "WHISPER"
            end
            local submitted = ok and readable and ((values and result == values.Success) or (logged and result == nil))
            if submitted and packet.kind == "HELLO" then
                pcall(self.HelloSubmitted, self, item.match, path)
                if not logged and path == "WHISPER" and not item.match.loggedRoute then
                    pcall(self.ScheduleLoggedProbe, self, item.match, item.payload, item.target)
                end
            end
            if item.isolated then
                if not item.match.peerNonce then
                    local status = submitted and (result == nil and path .. " submission unknown; waiting for current request acknowledgment"
                        or path .. " submission accepted by native API; waiting for current request acknowledgment")
                        or path .. " attempt unavailable (" .. resultText .. "); ordinary whisper remains active"
                    pcall(self.LoggedStatus, self, item.match, status)
                end
            elseif not submitted then
                FD.Debug:Log("transport rejected", resultText)
                if FD.duel and FD.duel.active == item.match then FD.duel:Unrate("addon message could not be sent", false) end
            end
        end
        self:Pump()
        end)
    end)
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

function Comms:IsOwnPartyEcho(packet, sender)
    local ok, ownEcho = pcall(function()
        if type(packet) ~= "table" or type(sender) ~= "string"
            or not FD.Wow:Readable(packet.guid, sender) then return false end
        local own = FD.Wow:Identity("player", true)
        if type(own) ~= "table" or not FD.Wow:Readable(own.guid, own.fullName, own.realm, own.nameFormat)
            or not FD.Protocol:ValidGUID(own.guid) or type(own.fullName) ~= "string"
            or own.fullName == "" or packet.guid ~= own.guid then return false end
        -- Surname senders must keep their exact native spelling. A standard
        -- bare sender may refer only to the own character's native local realm.
        if own.nameFormat ~= "surname" and not sender:find("-", 1, true) then
            if type(own.realm) ~= "string" or own.realm == "" then return false end
            sender = sender .. "-" .. own.realm
        end
        return sender == own.fullName
    end)
    return ok and ownEcho == true
end

function Comms:Receive(prefix, payload, channel, sender, loggedEvent)
    -- Observe our native event before early gates hide why it was discarded.
    -- Diagnostics cannot change the existing transport or rated lifecycle.
    pcall(self.ObserveIngress, self, prefix, payload, channel, sender, loggedEvent)
    if not FD.Wow:Readable(prefix, payload, channel, sender) then return end
    if prefix ~= FD.C.PREFIX or (channel ~= "WHISPER" and channel ~= "PARTY") or not FD.duel then return end
    local logged = loggedEvent == true
    if logged and (self.loggedReceiveAvailable ~= true or channel ~= "WHISPER") then return end
    local decoded = FD.Protocol:Decode(payload)
    -- Native PARTY broadcasts echo to their sender. Require both native own
    -- identity and sender spelling before ignoring one, preserving peer status.
    if (channel == "PARTY" or logged) and self:IsOwnPartyEcho(decoded, sender) then return end
    self.lastReceive = (decoded and decoded.kind or "invalid packet") .. " from " .. tostring(sender)
        .. " via " .. (logged and "LOGGED " or "") .. channel
    self.lastReceiveAt = GetTime()
    FD.Debug:Log("transport receive", self.lastReceive, "state", FD.duel:State())
    local m = FD.duel.active
    if not m then
        local accepted, status = FD.duel:Receive(payload, sender)
        pcall(self.RememberValidation, self, accepted, status)
        return
    end
    if channel == "PARTY" and not self:ExactDuelParty(m) then
        local accepted, status = FD.duel:PeerValidation(false, "PARTY requires the exact native two-player duel group")
        pcall(self.RememberValidation, self, accepted, status, m)
        return
    end
    if type(sender) ~= "string" then
        local accepted, status = FD.duel:PeerValidation(false, "native sender unavailable")
        pcall(self.RememberValidation, self, accepted, status, m)
        return
    end
    if m.opponent.nameFormat ~= "surname" and not sender:find("-", 1, true) then
        -- A bare transport name is accepted only on the local realm.
        if m.opponent.realm ~= m.player.realm then
            local accepted, status = FD.duel:PeerValidation(false, "bare sender belongs to another realm", nil,
                "local=" .. m.player.realm .. "; opponent=" .. m.opponent.realm)
            pcall(self.RememberValidation, self, accepted, status, m)
            return
        end
        sender = sender .. "-" .. m.player.realm
    end
    if sender ~= m.opponent.fullName then
        FD.Debug:Log("transport sender mismatch", sender, "expected", m.opponent.fullName)
        local accepted, status = FD.duel:PeerValidation(false, "sender mismatch", nil,
            "expected=" .. m.opponent.fullName .. "; received=" .. sender)
        pcall(self.RememberValidation, self, accepted, status, m)
        return
    end
    -- Only an ACK generated in direct response to this guarded packet may use
    -- its logged route. An unbound HELLO cannot route consent or prove a peer.
    local previousReply = self.loggedReply
    if logged and decoded and (decoded.kind == "HELLO" or decoded.kind == "HELLO_ACK") then
        self.loggedReply = { match = m, nonce = decoded.nonce }
    end
    local ok, accepted, status = pcall(FD.duel.Receive, FD.duel, payload, sender)
    self.loggedReply = previousReply
    if not ok then error(accepted, 0) end
    if accepted == true and decoded and decoded.kind == "HELLO_ACK" and decoded.echo == m.nonce
        and m.peerNonce == decoded.nonce and FD.duel.active == m
        and m.state ~= "UNRATED" and m.state ~= "UNRATED_ACTIVE" then
        if logged then m.loggedRoute = true end
        pcall(self.RememberAcknowledgment, self, m, logged and "LOGGED" or channel)
    end
    pcall(self.RememberValidation, self, accepted, status or m.peerStatus, m)
end
