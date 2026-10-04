local _, FD = ...

-- The channel is a directory only. Profiles travel over addon WHISPER.
FD.Roster = {}
local Roster = FD.Roster
local CHANNEL, REFRESH, WAIT, LIMIT = "ForeverDuel", 30, 5, 300

local function integer(value, low, high)
    return type(value) == "number" and value >= low and value <= high and value % 1 == 0
end

function Roster:Visible()
    return ChannelFrame and type(ChannelFrame.IsShown) == "function" and ChannelFrame:IsShown()
end

function Roster:Selection()
    if type(GetSelectedDisplayChannel) == "function" then
        local selected = GetSelectedDisplayChannel()
        if FD.Wow:Readable(selected) and integer(selected, 0, 512) then return selected end
    end
    if ChannelFrame and type(ChannelFrame.GetList) == "function" then
        local list = ChannelFrame:GetList()
        if list and type(list.GetSelectedChannelIDAndSupportsText) == "function" then
            local selected, text = list:GetSelectedChannelIDAndSupportsText()
            if FD.Wow:Readable(selected, text) and text and integer(selected, 1, 512) then return selected end
        end
    end
end

function Roster:Directory(channelID)
    if type(GetNumDisplayChannels) ~= "function" or type(GetChannelDisplayInfo) ~= "function" then return end
    local count = GetNumDisplayChannels()
    if not FD.Wow:Readable(count) or not integer(count, 0, 512) then return end
    for index = 1, count do
        local name, header, _, id, members = GetChannelDisplayInfo(index)
        if FD.Wow:Readable(name, header, id, members) and not header and id == channelID
            and type(name) == "string" and name:lower() == CHANNEL:lower() then
            return index, members
        end
    end
end

function Roster:Candidate(name, guid)
    if not FD.Wow:Readable(name, guid) or type(name) ~= "string" or #name == 0
        or #name > 128 or name:find("[%c|]") or not FD.Protocol:ValidGUID(guid) then return end
    local own = FD.Presence:GetOwnPlayer()
    if own and guid ~= own.guid and name ~= own.fullName then FD.Presence:QueueWhisper(name, true) end
end

function Roster:Read(index, count)
    if not FD.Wow:Readable(count) or not integer(count, 1, 1000000) then return false end
    local read, complete = 0, true
    for row = 1, math.min(count, LIMIT) do
        local name, _, _, guid = C_ChatInfo.GetChannelRosterInfo(index, row)
        if FD.Wow:Readable(name, guid) then
            if type(name) == "string" and name ~= "" then
                read = read + 1
                self:Candidate(name, guid)
            else
                complete = false
            end
        end
    end
    self.status = string.format("Channel directory: %d/%d members loaded; querying by whisper.", read, count)
    return complete
end

function Roster:Finish()
    local pending = self.pending
    self.pending = nil -- Restoration can synchronously dispatch channel events.
    if not pending or self:Visible() or self:Selection() ~= pending.index then return end
    local restore = pending.previous
    if restore > 0 then
        -- Resolve the former channel again; display indices can change on join.
        restore = pending.previousID and self:DirectoryByID(pending.previousID, pending.previousName) or nil
    end
    if restore ~= nil and restore ~= pending.index then
        pcall(SetSelectedDisplayChannel, restore)
    end
end

function Roster:DirectoryByID(channelID, channelName)
    local count = GetNumDisplayChannels()
    if not FD.Wow:Readable(count) or not integer(count, 0, 512) then return end
    for index = 1, count do
        local name, header, _, id = GetChannelDisplayInfo(index)
        if FD.Wow:Readable(name, header, id) and not header and id == channelID and name == channelName then
            return index
        end
    end
end

function Roster:Poll(pending)
    if self.pending ~= pending then return end
    C_Timer.After(1, function()
        if self.pending ~= pending then return end
        FD.Presence:Run(function() self:Tick() end)
        if self.pending == pending then self:Poll(pending) end
    end)
end

function Roster:Tick()
    local presence = FD.Presence
    if not presence.available or presence.suspended or presence.stopped then return end
    if self:Visible() then
        self.pending = nil -- The user's open channel UI owns native selection.
        self.status = "Channel directory paused while the channel window is open."
        return
    end
    local now = GetTime()
    -- Check the deadline before any native roster API that could keep failing.
    if self.pending and now >= self.pending.deadline then
        self:Finish()
        self.status = "Channel roster not received yet; retrying automatically."
        return
    end
    local channelID = presence:ChannelID()
    if not channelID then
        self:Finish()
        local join = type(JoinTemporaryChannel) == "function" and JoinTemporaryChannel
            or type(JoinPermanentChannel) == "function" and JoinPermanentChannel
        if not join then self.status = "Channel directory unavailable; target discovery is active."; return end
        self.status = "Joining the ForeverDuelersGuild player directory..."
        if not self.lastJoin or now - self.lastJoin >= REFRESH then
            self.lastJoin = now
            join(CHANNEL)
        end
        return
    end
    if not C_ChatInfo or type(C_ChatInfo.GetChannelRosterInfo) ~= "function" then
        self.status = "Channel roster API unavailable; target discovery is active."
        return
    end
    local index, count = self:Directory(channelID)
    if not index then self:Finish(); self.status = "Waiting for the channel directory to appear."; return end
    local pending = self.pending
    if pending then
        if index ~= pending.index or channelID ~= pending.channelID or self:Selection() ~= index then
            self:Finish()
            return
        end
        if self:Read(index, pending.count or count) then self:Finish(); return end
        return
    end
    self:Read(index, count) -- A readable directory may already be cached.
    if self.lastRequest and now - self.lastRequest < REFRESH then return end
    local previous = self:Selection()
    if previous == nil or type(SetSelectedDisplayChannel) ~= "function" then
        self.status = "Channel roster cannot be requested safely; target discovery is active."
        return
    end
    local previousName, previousID
    if previous > 0 then
        local name, header, _, id = GetChannelDisplayInfo(previous)
        if not FD.Wow:Readable(name, header, id) or header or type(name) ~= "string" or name == ""
            or not integer(id, 1, 100) then
            self.status = "Previous channel selection is unavailable; directory request deferred."
            return
        end
        previousName, previousID = name, id
    end
    self.lastRequest = now
    pending = { index = index, channelID = channelID, previous = previous,
        previousName = previousName, previousID = previousID, deadline = now + WAIT }
    self.pending = pending
    self.status = "Loading the ForeverDuelersGuild player directory..."
    local ok = pcall(SetSelectedDisplayChannel, index)
    if not ok then self:Finish(); self.status = "Channel roster request failed; target discovery is active."; return end
    self:Poll(pending)
end

function Roster:OnEvent(event, ...)
    if not FD.Presence.available or FD.Presence.suspended or FD.Presence.stopped then return end
    if event == "CHAT_MSG_CHANNEL_JOIN" then
        local _, name, _, _, _, _, _, channelID, channelName, _, _, guid = ...
        if FD.Wow:Readable(channelID, channelName) and channelID == FD.Presence:ChannelID()
            and type(channelName) == "string" and channelName:lower() == CHANNEL:lower() then
            self:Candidate(name, guid)
        end
    elseif event == "CHANNEL_ROSTER_UPDATE" or event == "CHANNEL_COUNT_UPDATE" then
        local index, count = ...
        if self.pending and FD.Wow:Readable(index, count) and index == self.pending.index
            and integer(count, 0, 1000000) then self.pending.count = count end
    end
    self:Tick()
end

function Roster:Reset()
    self:Finish()
    self.lastRequest, self.lastJoin = nil, nil
end
