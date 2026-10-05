local _, FD = ...

-- The ForeverDuel channel is a directory of addon users. Membership comes
-- from roster reads, join/leave events and CHANNEL addon messages, and it
-- lets Presence decide whom to answer. The channel itself is untrusted: it
-- is joined only after the client's default channels, join failures are
-- reported, and the member list is loaded only when discovery needs it.
FD.Roster = { CHANNEL = "ForeverDuel", members = {}, memberCount = 0 }
local Roster = FD.Roster
local CHANNEL, LIMIT = Roster.CHANNEL, 300
local REFRESH, MANUAL, WAIT = 60, 10, 5   -- roster requests, explicit refresh, selection hold
local JOIN_CHECK, JOIN_RETRY, JOIN_FALLBACK, UI_SETTLE = 5, 60, 15, 3

local function integer(value, low, high)
    return type(value) == "number" and value >= low and value <= high and value % 1 == 0
end

local function ours(name)
    return FD.Wow:Readable(name) and type(name) == "string" and name:lower() == CHANNEL:lower()
end

local function ownGUID()
    local guid = UnitGUID("player")
    return FD.Wow:Readable(guid) and guid or nil
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
        if FD.Wow:Readable(name, header, id, members) and not header and id == channelID and ours(name) then
            return index, members
        end
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

-- Join after the default channels so ours never takes /1 or /2: the native
-- General channel exists, another channel is listed, the channel UI settled,
-- or a fallback delay passed.
function Roster:DefaultsReady(at)
    if C_ChatInfo and type(C_ChatInfo.GetGeneralChannelLocalID) == "function" then
        local ok, id = pcall(C_ChatInfo.GetGeneralChannelLocalID)
        if ok and FD.Wow:Readable(id) and integer(id, 1, 100) then return true end
    end
    if self.uiUpdateAt and at - self.uiUpdateAt >= UI_SETTLE then return true end
    if type(GetNumDisplayChannels) == "function" and type(GetChannelDisplayInfo) == "function" then
        local count = GetNumDisplayChannels()
        if FD.Wow:Readable(count) and integer(count, 0, 512) then
            for index = 1, count do
                local name, header, _, id = GetChannelDisplayInfo(index)
                if FD.Wow:Readable(name, header, id) and not header and integer(id, 1, 100) and not ours(name) then return true end
            end
        end
    end
    return at - (FD.Presence.startedAt or at) >= JOIN_FALLBACK
end

function Roster:IsMember(name)
    return type(name) == "string" and self.members[name] ~= nil
end

function Roster:AddMember(name, guid)
    if not FD.Wow:Readable(name, guid) or type(name) ~= "string" or not FD.Protocol:ValidGUID(guid) then return end
    if self.members[name] == nil then
        if self.memberCount >= LIMIT then return end
        self.memberCount = self.memberCount + 1
    end
    self.members[name] = guid
end

function Roster:RemoveMember(name)
    if type(name) == "string" and self.members[name] ~= nil then
        self.members[name], self.memberCount = nil, self.memberCount - 1
    end
end

-- Returns true when every listed row was readable.
function Roster:Read(index, count)
    if not C_ChatInfo or type(C_ChatInfo.GetChannelRosterInfo) ~= "function"
        or not FD.Wow:Readable(count) or not integer(count, 1, 1000000) then return false end
    local own = ownGUID()
    local read, complete = 0, true
    for row = 1, math.min(count, LIMIT) do
        local name, _, _, guid = C_ChatInfo.GetChannelRosterInfo(index, row)
        if FD.Wow:Readable(name, guid) and type(name) == "string" and name ~= "" then
            read = read + 1
            if own == nil or guid ~= own then self:AddMember(FD.Presence:Canonical(name), guid) end
        else
            complete = false
        end
    end
    if complete then self.problem = nil end
    return complete
end

-- Hidden roster loading needs a temporary native selection change. It runs
-- only when discovery needs members, never while the Channels window is
-- open, and not at all when the client already has the member list.
function Roster:Request(force)
    local presence, at = FD.Presence, GetTime()
    if self.pending or presence:Quiet() or not presence:Live() or self:Visible() then return false end
    if self.lastRequest and at - self.lastRequest < (force and MANUAL or REFRESH) then return false end
    local channelID = presence:ChannelID()
    if not channelID or not C_ChatInfo or type(C_ChatInfo.GetChannelRosterInfo) ~= "function" then return false end
    local index, count = self:Directory(channelID)
    if not index then return false end
    self.lastRequest = at
    if self:Read(index, count) then return true end
    local previous = self:Selection()
    if previous == nil or type(SetSelectedDisplayChannel) ~= "function" then
        self.problem = FD.L["Channel member list cannot be loaded safely; target discovery remains available."]
        return false
    end
    local previousName, previousID
    if previous > 0 then
        local name, header, _, id = GetChannelDisplayInfo(previous)
        if not FD.Wow:Readable(name, header, id) or header or type(name) ~= "string" or name == ""
            or not integer(id, 1, 100) then
            self.problem = FD.L["Previous channel selection is unavailable; member list request deferred."]
            return false
        end
        previousName, previousID = name, id
    end
    self.pending = { index = index, channelID = channelID, previous = previous,
        previousName = previousName, previousID = previousID, deadline = at + WAIT }
    self:HookFrame()
    if not pcall(SetSelectedDisplayChannel, index) then
        self.pending = nil
        self.problem = FD.L["Channel member list request failed; target discovery remains available."]
        return false
    end
    return true
end

-- The Channels window opening mid-request restores the user's selection
-- before they can see ours.
function Roster:HookFrame()
    if self.hooked or not ChannelFrame or type(ChannelFrame.HookScript) ~= "function" then return end
    self.hooked = true
    ChannelFrame:HookScript("OnShow", function() FD.Presence:Run(function() Roster:Finish() end) end)
end

-- Restore the previous selection unless the user changed it meanwhile. This
-- deliberately also runs while the Channels window is visible.
function Roster:Finish()
    local pending = self.pending
    self.pending = nil -- Restoration can synchronously dispatch channel events.
    if not pending or self:Selection() ~= pending.index then return end
    local restore = pending.previous
    if restore > 0 then
        -- Resolve the former channel again; display indices can change on join.
        restore = pending.previousID and self:DirectoryByID(pending.previousID, pending.previousName) or nil
    end
    if restore ~= nil and restore ~= pending.index then pcall(SetSelectedDisplayChannel, restore) end
end

function Roster:Continue(at, channelID)
    local pending = self.pending
    if self:Visible() or channelID ~= pending.channelID or self:Directory(channelID) ~= pending.index then return self:Finish() end
    if self:Selection() ~= pending.index then self.pending = nil; return end
    -- A throwing native read must still end the request and restore.
    local ok, complete = pcall(self.Read, self, pending.index, pending.count)
    if not ok or complete or at >= pending.deadline then self:Finish() end
end

function Roster:Tick(quiet)
    local L, at = FD.L, GetTime()
    local channelID = FD.Presence:ChannelID()
    if self.pending then self:Continue(at, channelID) end
    if channelID then
        if not self.joinedAt then self.joinedAt, self.failure, self.joinAttempt = at, nil, nil end
        local dirty = self.dirty
        self.dirty = nil
        if dirty and not self.pending then
            -- A roster or count update for our display row: read what the
            -- client already has, without touching the selection.
            local index, count = self:Directory(channelID)
            if index and dirty[index] then self:Read(index, dirty[index] or count) end
        end
        self.status = self.pending and L["Loading the ForeverDuel member list..."] or self.problem
            or FD.Locale:Format("ForeverDuel channel joined; %d members known.", self.memberCount)
        return
    end
    self.joinedAt = nil
    if quiet then self.status = L["Quiet mode: the ForeverDuel channel is not joined."]; return end
    if self.failure == "password" then
        self.status = L["The ForeverDuel channel asks for a password; the directory is unavailable. Target discovery remains available."]
        return
    elseif self.failure == "banned" then
        self.status = L["You are banned from the ForeverDuel channel; the directory is unavailable. Target discovery remains available."]
        return
    elseif self.failure == "left" then
        self.status = L["You left the ForeverDuel channel; type /join ForeverDuel to use the directory again."]
        return
    end
    if type(JoinTemporaryChannel) ~= "function" then
        self.status = L["Channel directory unavailable on this client; target discovery remains available."]
        return
    end
    if self.joinAttempt and at - self.joinAttempt < JOIN_CHECK then return end
    if self.joinAttempt then
        self.failure = "missing"
        self.status = L["Could not join the ForeverDuel channel (not in the channel list after joining); retrying every minute."]
        if at - self.joinAttempt < JOIN_RETRY then return end
    end
    if not self:DefaultsReady(at) then self.status = L["Waiting for the default chat channels before joining ForeverDuel."]; return end
    self.joinAttempt = at
    if not self.failure then self.status = L["Joining the ForeverDuel player directory..."] end
    pcall(JoinTemporaryChannel, CHANNEL)
end

-- Events only record facts; Presence schedules the Tick that acts on them.
function Roster:OnEvent(event, ...)
    if event == "CHANNEL_UI_UPDATE" then
        self.uiUpdateAt = self.uiUpdateAt or GetTime()
    elseif event == "CHAT_MSG_CHANNEL_JOIN" or event == "CHAT_MSG_CHANNEL_LEAVE" then
        local _, name, _, _, _, _, _, channelID, channelName, _, _, guid = ...
        local current = FD.Presence:ChannelID()
        if not current or not FD.Wow:Readable(channelID) or channelID ~= current or not ours(channelName) then return end
        name = FD.Presence:Canonical(name)
        if not name then return end
        if event == "CHAT_MSG_CHANNEL_JOIN" then
            if FD.Wow:Readable(guid) and guid ~= ownGUID() then self:AddMember(name, guid) end
        elseif event == "CHAT_MSG_CHANNEL_LEAVE" then self:RemoveMember(name) end
    elseif event == "CHANNEL_ROSTER_UPDATE" or event == "CHANNEL_COUNT_UPDATE" then
        local index, count = ...
        if not FD.Wow:Readable(index, count) or not integer(count, 0, 1000000) then return end
        if self.pending and index == self.pending.index then self.pending.count = count end
        self.dirty = self.dirty or {}
        self.dirty[index] = count
    elseif event == "CHAT_MSG_CHANNEL_NOTICE" then
        local notice, _, _, _, _, _, _, _, channelName = ...
        if not FD.Wow:Readable(notice) or not ours(channelName) then return end
        if notice == "WRONG_PASSWORD" then self.failure = "password"
        elseif notice == "BANNED" then self.failure = "banned"
        elseif notice == "YOU_LEFT" then self.failure = "left" end -- Respect a manual /leave.
    elseif event == "CHANNEL_PASSWORD_REQUEST" then
        if ours((...)) then self.failure = "password" end
    end
end

function Roster:Reset()
    self:Finish()
    self.lastRequest, self.joinAttempt, self.dirty = nil, nil, nil
end
