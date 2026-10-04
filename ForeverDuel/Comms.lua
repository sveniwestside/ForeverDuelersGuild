local _, FD = ...
FD.Comms = { queue = {}, pumping = false }
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
    self.queue[#self.queue + 1] = { payload = payload, target = target, match = match }
    self:Pump()
    return true
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
        if valid then
            local ok, result = pcall(C_ChatInfo.SendAddonMessage, FD.C.PREFIX, item.payload, "WHISPER", item.target)
            local values = Enum and Enum.SendAddonMessageResult
            self.lastSend = packet.kind .. " to " .. item.target .. " (" .. (ok and tostring(result) or "Lua error") .. ")"
            FD.Debug:Log("transport send", self.lastSend)
            if not ok or not values or result ~= values.Success then
                FD.Debug:Log("transport rejected", ok and result or "Lua error")
                if FD.duel and FD.duel.active == item.match then FD.duel:Unrate("addon message could not be sent", false) end
            end
        end
        self:Pump()
        end)
    end)
end

function Comms:Receive(prefix, payload, channel, sender)
    if not FD.Wow:Readable(prefix, payload, channel, sender) then return end
    if prefix ~= FD.C.PREFIX or channel ~= "WHISPER" or not FD.duel then return end
    local decoded = FD.Protocol:Decode(payload)
    self.lastReceive = (decoded and decoded.kind or "invalid packet") .. " from " .. tostring(sender)
    FD.Debug:Log("transport receive", self.lastReceive, "state", FD.duel:State())
    local m = FD.duel.active
    if not m or type(sender) ~= "string" then return end
    if m.opponent.nameFormat ~= "surname" and not sender:find("-", 1, true) then
        -- A bare transport name is accepted only on the local realm.
        if m.opponent.realm ~= m.player.realm then return end
        sender = sender .. "-" .. m.player.realm
    end
    if sender ~= m.opponent.fullName then
        FD.Debug:Log("transport sender mismatch", sender, "expected", m.opponent.fullName)
        return
    end
    FD.duel:Receive(payload, sender)
end
