-- Shared fake WoW client for adapter_spec and duel_latency_spec (not a suite).
-- Each client loads the real addon from the TOC into a private Lua 5.1
-- environment; fake WoW globals never enter _G. Clients created with the same
-- clock share one timeline, and a pair delivers addon messages between them
-- through scheduled per-message delivery.
local Client = {}

function Client.clock()
    return { now = 0, timers = {}, order = 0 }
end

function Client.schedule(clock, at, callback)
    clock.order = clock.order + 1
    clock.timers[#clock.timers + 1] = { at = at, order = clock.order, callback = callback }
end

function Client.run(clock, untilTime)
    local iterations = 0
    while true do
        local selected, chosen
        for index, timer in ipairs(clock.timers) do
            if timer.at <= untilTime and (not chosen or timer.at < chosen.at
                or (timer.at == chosen.at and timer.order < chosen.order)) then
                selected, chosen = index, timer
            end
        end
        if not selected then break end
        iterations = iterations + 1
        assert(iterations < 20000, "mock timer runaway")
        table.remove(clock.timers, selected)
        clock.now = math.max(clock.now, chosen.at)
        chosen.callback()
    end
    clock.now = math.max(clock.now, untilTime)
end

local TOKENS = { "target", "focus", "mouseover", "party1", "party2", "party3", "party4" }
for i = 1, 40 do TOKENS[#TOKENS + 1] = "nameplate" .. i end

function Client.new(options)
    options = options or {}
    local clock = options.clock or Client.clock()
    local state = { clock = clock, frames = {}, sent = {}, prints = {}, hides = 0, shows = 0, accepts = 0, declines = 0,
        nativeVisible = false, registerResult = options.registerResult or 0, sendResult = 0, combat = false }
    setmetatable(state, { __index = function(_, key) if key == "now" then return clock.now end end,
        __newindex = function(t, key, value) if key == "now" then clock.now = value else rawset(t, key, value) end end })
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local FD = {}
    local methods = {}
    function methods:SetSize(width, height) self.width, self.height = width, height end
    function methods:GetWidth() return self.width or 1280 end
    function methods:GetHeight() return self.height or 800 end
    function methods:SetScale(value) self.scale = value end
    function methods:SetPoint(...) self.points = self.points or {}; self.points[#self.points + 1] = { ... } end
    function methods:ClearAllPoints() self.points = {} end
    for _, name in ipairs({ "SetFrameStrata", "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor",
        "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetTextColor", "SetMovable", "EnableMouse",
        "SetClampedToScreen", "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetHighlightTexture",
        "SetAutoFocus", "SetMaxLetters", "ClearFocus", "SetTextInsets", "SetFontObject" }) do
        methods[name] = function() end
    end
    function methods:SetText(value) self.text = value end
    function methods:GetText() return self.text or "" end
    function methods:CreateLine() return self:CreateFontString() end
    function methods:SetThickness(value) self.thickness = value end
    function methods:SetStartPoint(...) self.startPoint = { ... } end
    function methods:SetEndPoint(...) self.endPoint = { ... } end
    function methods:SetColorTexture(...) self.textureColor = { ... } end
    function methods:SetEnabled(value) self.enabled = value end
    function methods:Show() self.shown = true end
    -- Like WoW, hiding a shown frame raises its OnHide script.
    function methods:Hide()
        local was = self.shown
        self.shown = false
        if was and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function methods:IsShown() return self.shown end
    function methods:SetScript(name, callback) self.scripts[name] = callback end
    function methods:RegisterEvent(event) self.events[event] = true end
    local function frame()
        local object = setmetatable({ scripts = {}, events = {}, shown = false }, { __index = methods })
        state.frames[#state.frames + 1] = object
        return object
    end
    function methods:CreateFontString() return frame() end
    env.UIParent = frame()
    env.CreateFrame = function(_, name)
        local object = frame()
        if name then env[name] = object end
        return object
    end
    env.GetTime = function() return clock.now end
    env.GetServerTime = function() return 1700000000 + math.floor(clock.now) end
    env.InCombatLockdown = function() return state.combat end
    env.IsInGroup = function() return state.grouped == true end
    env.IsInRaid = function() return state.raid == true end
    env.GetNumGroupMembers = function() return state.members or 0 end
    env.C_Timer = { After = function(delay, callback) Client.schedule(clock, clock.now + delay, callback) end }
    state.secret = {}
    env.issecretvalue = function(value) return value == state.secret end
    state.units = options.units or {
        player = { guid = "Player-1-00000001", name = "Alpha", realm = "Forever", classFile = "MAGE" },
        target = { guid = "Player-1-00000002", name = "Beta", realm = "Forever", classFile = "ROGUE" },
    }
    env.UnitLevel = function(unit)
        local identity = state.units[unit]
        if identity then return identity.level or 30 end
    end
    env.GetMaxPlayerLevel = function() return state.maxLevel or 60 end
    if options.missingCap then env.GetMaxPlayerLevel = nil end
    env.ForeverDuelDB = options.saved
    env.UnitGUID = function(unit) return state.units[unit] and state.units[unit].guid end
    env.UnitIsPlayer = function(unit) return state.units[unit] ~= nil end
    env.UnitFullName = function(unit)
        local identity = state.units[unit]
        if identity then return identity.name, options.regionalNames and identity.surname or identity.realm end
    end
    env.RegionalUniqueNamesEnabled = function() return options.regionalNames or false end
    env.UnitNameUnmodified = function(unit)
        local identity = state.units[unit]
        if identity then return identity.name, identity.surname end
    end
    env.NameUtil = { GetUnmodifiedUnitFullName = function(unit)
        state.nameHelperCalls = (state.nameHelperCalls or 0) + 1
        -- The exact Camelot 70170 helper contract, not the legacy helper.
        local name, surname = env.UnitNameUnmodified(unit)
        if surname then return name .. " " .. surname end
        return name
    end }
    env.UnitClass = function(unit)
        local identity = state.units[unit]
        if identity then return identity.classFile, identity.classFile end
    end
    if options.tokens then
        -- Pinned UnitTokenFromGUID: a token for a visible unit with that GUID.
        env.UnitTokenFromGUID = function(guid)
            for _, unit in ipairs(TOKENS) do
                local identity = state.units[unit]
                if identity and identity.guid == guid then return unit end
            end
        end
    end
    env.GetNormalizedRealmName = function() return "Forever" end
    env.C_SpecializationInfo = {
        GetSpecialization = function() return 1 end,
        GetSpecializationInfo = function() return 62, "Arcane" end,
    }
    env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) state.prints[#state.prints + 1] = text end }
    env.SlashCmdList = {}
    env.UISpecialFrames = {}
    env.date = os.date
    env.GetSpecializationNameForSpecID = function(id)
        if id == 62 then return "Arcane" end
        if id == 259 then return "Assassination" end
    end
    env.Enum = {
        RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2, MaxPrefixes = 3 },
        SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, InvalidChatType = 4,
            NotInGroup = 5, GeneralError = 9, TargetOffline = 12 },
    }
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return state.registerResult end,
        SendAddonMessage = function(prefix, payload, channel, target)
            local result = options.directory and channel == "YELL" and 4 or state.sendResult
            if state.sendFilter then result = state.sendFilter(prefix, payload, channel, target, result) end
            local sent = { prefix = prefix, payload = payload, channel = channel, target = target, result = result, at = clock.now }
            state.sent[#state.sent + 1] = sent
            if state.network then state.network:transmit(state, sent) end
            if result == "error" then error("injected native send exception") end
            return result
        end,
    }
    if options.presence then
        state.zoneMap, state.channelID = 37, 7
        env.C_Map = { GetBestMapForUnit = function() return state.zoneMap end }
        env.GetChannelName = function(name)
            return state.joinedChannel == name and state.channelID or 0
        end
        env.JoinTemporaryChannel = function(name) state.joinedChannel = name end
    end
    if options.directory then
        state.selectedChannel = 1
        env.ChannelFrame = { IsShown = function() return false end }
        env.GetNumDisplayChannels = function() return 2 end
        env.GetChannelDisplayInfo = function(index)
            if index == 1 then return "General", false, false, 1, 1, true end
            if index == 2 then return "ForeverDuel", false, false, state.channelID,
                state.directoryLoaded and #options.directory or nil, true end
        end
        env.GetSelectedDisplayChannel = function() return state.selectedChannel end
        env.SetSelectedDisplayChannel = function(index)
            state.selectedChannel = index
            if index == 2 then env.C_Timer.After(0.5, function()
                state.directoryLoaded = true
                state:emit("CHANNEL_ROSTER_UPDATE", 2, #options.directory)
            end) end
        end
        env.C_ChatInfo.GetChannelRosterInfo = function(index, row)
            local identity = state.directoryLoaded and index == 2 and options.directory[row]
            if identity then return identity.name .. " " .. identity.surname, false, false, identity.guid end
        end
    end
    env.AcceptDuel = function()
        state.accepts = state.accepts + 1
        if state.onAccept then state.onAccept(state) end
    end
    env.CancelDuel = function() state.declines = state.declines + 1 end
    state.nativeAccept, state.nativeCancel = env.AcceptDuel, env.CancelDuel
    env.StartDuel = function(unit) state.started = (state.started or 0) + 1; state.startedUnit = unit end
    env.hooksecurefunc = function(name, callback)
        local original = env[name]
        env[name] = function(...)
            original(...)
            callback(...)
        end
    end
    env.StaticPopupDialogs = { DUEL_REQUESTED = { OnAccept = env.AcceptDuel, OnCancel = env.CancelDuel } }
    state.nativeDefinition = env.StaticPopupDialogs.DUEL_REQUESTED
    state.popupFrame = frame()
    env.StaticPopup_Show = function(which, name)
        if which == "DUEL_REQUESTED" then state.nativeVisible, state.nativeName = true, name; state.shows = state.shows + 1 end
    end
    env.StaticPopup_Hide = function(which)
        if which == "DUEL_REQUESTED" then state.nativeVisible = false; state.hides = state.hides + 1 end
    end
    env.StaticPopup_Visible = function(which)
        if which == "DUEL_REQUESTED" and state.nativeVisible then return "StaticPopup1", state.popupFrame end
    end
    env.ERR_DUEL_REQUESTED = "You have requested a duel."
    env.ERR_DUEL_CANCELLED = "Duel canceled."
    env.ERR_OUT_OF_RANGE = "Out of range."
    env.SPELL_FAILED_TARGET_DUELING = "Target is currently dueling"
    env.GetGameMessageInfo = function(index)
        state.messageInfoCalls = (state.messageInfoCalls or 0) + 1
        if state.messageInfoError then error("native message mapping unavailable") end
        return state.messageInfo and state.messageInfo[index]
    end
    env.DUEL_COUNTDOWN = "Duel starting: %d"
    env.DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
    env.DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel"
    local toc = assert(io.open("ForeverDuel/ForeverDuel.toc", "r"))
    for line in toc:lines() do
        local file = line:match("^([%w_]+%.lua)%s*$")
        if file then
            local chunk = assert(loadfile("ForeverDuel/" .. file))
            setfenv(chunk, env)
            chunk("ForeverDuel", FD)
        end
    end
    toc:close()
    function state:emit(event, ...)
        for _, object in ipairs(self.frames) do
            if object.events[event] then object.scripts.OnEvent(object, event, ...) end
        end
    end
    function state:advance(seconds) Client.run(clock, clock.now + seconds) end
    function state:incoming(name)
        self:emit("DUEL_REQUESTED", name or "Beta")
        -- Blizzard shows its popup after the addon handler ran.
        env.StaticPopup_Show("DUEL_REQUESTED", name or "Beta")
    end
    -- Addon packets this client submitted for the rated prefix, decoded.
    function state:packets(kind)
        local result = {}
        for _, sent in ipairs(self.sent) do
            if sent.prefix == FD.C.PREFIX then
                local packet = FD.Protocol:Decode(sent.payload)
                if packet and (not kind or packet.kind == kind) then
                    packet.channel, packet.result, packet.at = sent.channel, sent.result, sent.at
                    result[#result + 1] = packet
                end
            end
        end
        return result
    end
    function state:printed(text)
        for _, line in ipairs(self.prints) do if line:find(text, 1, true) then return true end end
        return false
    end
    state.FD, state.env = FD, env
    state:emit("PLAYER_LOGIN")
    return state
end

-- Two clients on one timeline. delay(sent, from, to) -> seconds or false (lost).
function Client.pair(options)
    options = options or {}
    local clock = Client.clock()
    local alpha = options.alpha or { guid = "Player-1-00000001", name = "Alpha", realm = "Forever", classFile = "MAGE" }
    local beta = options.beta or { guid = "Player-1-00000002", name = "Beta", realm = "Forever", classFile = "ROGUE" }
    local function copy(t) local r = {} for k, v in pairs(t) do r[k] = v end return r end
    local shared = { clock = clock, tokens = options.tokens, regionalNames = options.regionalNames }
    local a = Client.new(setmetatable({ units = { player = copy(alpha), target = copy(beta) } }, { __index = shared }))
    local b = Client.new(setmetatable({ units = { player = copy(beta), target = copy(alpha) } }, { __index = shared }))
    local net = { a = a, b = b, clock = clock, log = {}, latency = options.latency or 0 }
    a.network, b.network, a.peer, b.peer = net, net, b, a
    a.senderName = options.alphaSender or (alpha.surname and (alpha.name .. " " .. alpha.surname) or alpha.name .. "-Forever")
    b.senderName = options.betaSender or (beta.surname and (beta.name .. " " .. beta.surname) or beta.name .. "-Forever")
    function net:transmit(from, sent)
        if sent.prefix ~= from.FD.C.PREFIX or sent.result ~= 0 then return end
        local to = from.peer
        local entry = { from = from, to = to, sent = sent, at = clock.now }
        entry.packet = from.FD.Protocol:Decode(sent.payload)
        entry.kind = entry.packet and entry.packet.kind or "?"
        self.log[#self.log + 1] = entry
        local delay = self.latency
        if self.delay then delay = self.delay(entry) end
        if not delay then entry.lost = true; return end
        local payload = self.rewrite and self.rewrite(entry) or sent.payload
        Client.schedule(clock, clock.now + delay, function()
            entry.deliveredAt = clock.now
            to:emit("CHAT_MSG_ADDON", sent.prefix, payload, sent.channel, from.senderName)
            -- Native PARTY broadcasts also echo to their sender.
            if sent.channel == "PARTY" then from:emit("CHAT_MSG_ADDON", sent.prefix, payload, "PARTY", from.senderName) end
        end)
    end
    function net:advance(seconds) Client.run(clock, clock.now + seconds) end
    function net:count(kind, from)
        local total = 0
        for _, entry in ipairs(self.log) do
            if entry.kind == kind and (not from or entry.from == from) then total = total + 1 end
        end
        return total
    end
    -- The server: an outgoing StartDuel is acknowledged to the challenger and
    -- raises DUEL_REQUESTED (and Blizzard's popup) on the receiver.
    function net:challenge(from, unit, serverDelay)
        from.env.StartDuel(unit or "target")
        Client.schedule(clock, clock.now + (serverDelay or 0.1), function()
            from:emit("CHAT_MSG_SYSTEM", from.env.ERR_DUEL_REQUESTED)
            from.peer:incoming(from.senderName)
        end)
    end
    -- AcceptDuel on the receiver starts the native countdown on both clients.
    function net:nativeCountdown(serverDelay)
        local function countdown()
            Client.schedule(clock, clock.now + (serverDelay or 0.2), function()
                a:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
                b:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
                net.countdownAt = clock.now
            end)
        end
        a.onAccept, b.onAccept = countdown, countdown
    end
    function net:finish(winner, loser)
        local text = winner.senderName .. " has defeated " .. loser.senderName .. " in a duel"
        for _, c in ipairs({ a, b }) do
            c:emit("CHAT_MSG_SYSTEM", text)
            c:emit("DUEL_FINISHED")
        end
    end
    return net
end

return Client
