return function(_, equal)
    -- Each client loads the real addon into a private Lua 5.1 environment.
    -- Fake WoW globals never enter _G, so other suites need no cleanup.
    local function client(options)
        options = options or {}
        local state = { now = 0, timers = {}, frames = {}, sent = {}, prints = {},
            nativeVisible = false, hides = 0, accepts = 0, declines = 0,
            registerResult = options.registerResult or 0, sendResult = 0, combat = false }
        local env = setmetatable({}, { __index = _G })
        env._G = env
        local FD = {}
        local methods = {}
        function methods:SetSize(width, height) self.width, self.height = width, height end
        function methods:GetWidth() return self.width or 1280 end
        function methods:GetHeight() return self.height or 800 end
        function methods:SetScale(value) self.scale = value end
        function methods:SetPoint() end
        function methods:SetFrameStrata() end
        function methods:SetBackdrop() end
        function methods:SetBackdropColor() end
        function methods:SetBackdropBorderColor() end
        function methods:SetJustifyH() end
        function methods:SetJustifyV() end
        function methods:SetWordWrap() end
        function methods:SetTextColor() end
        function methods:SetMovable() end
        function methods:EnableMouse() end
        function methods:SetClampedToScreen() end
        function methods:RegisterForDrag() end
        function methods:StartMoving() end
        function methods:StopMovingOrSizing() end
        function methods:SetHighlightTexture() end
        function methods:SetText(value) self.text = value end
        function methods:GetText() return self.text or "" end
        function methods:SetAutoFocus() end
        function methods:SetMaxLetters() end
        function methods:ClearFocus() end
        function methods:SetTextInsets() end
        function methods:SetFontObject() end
        function methods:CreateLine() return self:CreateFontString() end
        function methods:SetThickness(value) self.thickness = value end
        function methods:SetStartPoint(...) self.startPoint = { ... } end
        function methods:SetEndPoint(...) self.endPoint = { ... } end
        function methods:SetColorTexture(...) self.textureColor = { ... } end
        function methods:SetEnabled(value) self.enabled = value end
        function methods:Show() self.shown = true end
        function methods:Hide() self.shown = false end
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
        env.GetTime = function() return state.now end
        env.GetServerTime = function() return 1700000000 + math.floor(state.now) end
        env.InCombatLockdown = function() return state.combat end
        env.C_Timer = { After = function(delay, callback)
            state.timers[#state.timers + 1] = { at = state.now + delay, callback = callback }
        end }
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
            SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, InvalidChatType = 4 },
        }
        env.C_ChatInfo = {
            RegisterAddonMessagePrefix = function() return state.registerResult end,
            SendAddonMessage = function(prefix, payload, channel, target)
                local result = options.directory and channel == "YELL" and 4 or state.sendResult
                state.sent[#state.sent + 1] = { prefix = prefix, payload = payload, channel = channel,
                    target = target, result = result }
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
        env.AcceptDuel = function() state.accepts = state.accepts + 1 end
        env.CancelDuel = function() state.declines = state.declines + 1 end
        state.nativeAccept, state.nativeCancel = env.AcceptDuel, env.CancelDuel
        env.StartDuel = function() end
        env.hooksecurefunc = function(name, callback)
            local original = env[name]
            env[name] = function(...)
                original(...)
                callback(...)
            end
        end
        env.StaticPopupDialogs = { DUEL_REQUESTED = { OnAccept = env.AcceptDuel, OnCancel = env.CancelDuel } }
        state.nativeDefinition = env.StaticPopupDialogs.DUEL_REQUESTED
        env.StaticPopup_Show = function(which, name)
            if which == "DUEL_REQUESTED" then state.nativeVisible, state.nativeName = true, name end
        end
        env.StaticPopup_Hide = function(which)
            if which == "DUEL_REQUESTED" then state.nativeVisible = false; state.hides = state.hides + 1 end
        end
        env.StaticPopup_Visible = function(which)
            if which == "DUEL_REQUESTED" and state.nativeVisible then return "StaticPopup1" end
        end
        env.ERR_DUEL_REQUESTED = "You have requested a duel."
        env.ERR_DUEL_CANCELLED = "Duel canceled."
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
        function state:advance(seconds)
            local untilTime, iterations = self.now + seconds, 0
            while true do
                local selected, at
                for index, timer in ipairs(self.timers) do
                    if timer.at <= untilTime and (not at or timer.at < at) then selected, at = index, timer.at end
                end
                if not selected then break end
                iterations = iterations + 1
                assert(iterations < 2000, "mock timer runaway")
                local timer = table.remove(self.timers, selected)
                self.now = at
                timer.callback()
            end
            self.now = untilTime
        end
        function state:incoming(name)
            self:emit("DUEL_REQUESTED", name or "Beta")
            -- Intentionally model Blizzard running AFTER the addon handler.
            env.StaticPopup_Show("DUEL_REQUESTED", name or "Beta")
        end
        state.FD, state.env = FD, env
        state:emit("PLAYER_LOGIN")
        return state
    end

    local function packet(FD, kind)
        return assert(FD.Protocol:Encode({ kind = kind, nonce = "a", echo = kind == "HELLO" and "-" or "b",
            guid = "Player-1-00000001", peerGUID = "Player-1-00000002", role = "INCOMING",
            rating = 1500, specId = 62, classFile = "MAGE", wins = 0, losses = 0, level = 30, maxLevel = 60,
            verdict = kind == "RESULT" and "Player-1-00000001" or "-" }))
    end

    local function toggleDebugOff(state)
        local active = state.FD.duel.active
        equal(state.FD.Database.data.settings.debug, false, "debug starts disabled")
        state.env.SlashCmdList.FOREVERDUEL("debug")
        equal(state.FD.Database.data.settings.debug, true, "real slash command enables debug")
        state.env.SlashCmdList.FOREVERDUEL("debug")
        equal(state.FD.Database.data.settings.debug, false, "real slash command disables debug")
        equal(state.FD.duel.active, active, "debug toggle preserves the active duel")
    end

    local c = client()
    equal(c.FD.Database:GetStats().rating, 1500, "real adapter initializes SavedVariables")
    equal(c.env.ForeverDuelDB, c.FD.Database.data, "SavedVariables references initialized database")
    equal(c.FD.Comms.available, true, "register enum zero means success")
    c:incoming()
    equal(c.FD.UI.frame:IsShown(), true, "replacement exists before native suppression")
    equal(c.nativeVisible, true, "native shown after addon event handler")
    equal(c.hides, 0, "native is not hidden synchronously")
    c:advance(0)
    equal(c.nativeVisible, false, "deferred replacement wins event ordering")
    equal(c.env.StaticPopupDialogs.DUEL_REQUESTED, c.nativeDefinition, "native definition identity preserved")
    equal(c.nativeDefinition.OnAccept, c.nativeAccept, "native accept callback preserved")
    equal(c.nativeDefinition.OnCancel, c.nativeCancel, "native cancel callback preserved")
    equal(c.accepts, 0, "discovery never accepts underlying duel")
    c.FD.UI.normal.scripts.OnClick()
    equal(c.accepts, 1, "ordinary button accepts immediately without handshake")
    equal(#c.FD.Database.data.matches, 0, "ordinary acceptance stores no rated match")
    equal(c.FD.Database:GetStats().rating, 1500, "ordinary acceptance leaves rating unchanged")

    for _, timing in ipairs({ "before", "during" }) do
        c = client()
        if timing == "before" then toggleDebugOff(c) end
        c:incoming()
        if timing == "during" then toggleDebugOff(c) end
        equal(c.FD.UI.frame:IsShown(), true, "debug toggled " .. timing .. " request preserves replacement")
        c:advance(c.FD.C.SEND_INTERVAL)
        equal(c.nativeVisible, false, "debug toggled " .. timing .. " request preserves native suppression")
        equal(c.FD.duel:State(), "CHECKING_ADDON", "debug toggle preserves discovery")
        equal(c.FD.Protocol:Decode(c.sent[1].payload).kind, "HELLO", "debug off still sends handshake")
        equal(c.accepts, 0, "debug toggle cannot accept underlying duel")
    end

    c = client()
    toggleDebugOff(c)
    local delayedOpponent = c.units.target
    c.units.target = nil
    c:incoming()
    equal(c.FD.duel.active, nil, "unresolved incoming request retains native flow initially")
    equal(c.nativeVisible, true, "unresolved request remains answerable")
    c:advance(2)
    c.units.target = delayedOpponent
    c:advance(0.5)
    equal(c.FD.UI.frame:IsShown(), true, "late native identity recovers replacement with debug disabled")
    equal(c.nativeVisible, false, "recovered replacement suppresses pending native popup")
    equal(c.FD.duel.active.createdAt, 0, "recovered request preserves original native request time")
    equal(c.accepts, 0, "identity recovery requires explicit duel acceptance")
    c:advance(c.FD.C.PENDING_TIMEOUT - c.now)
    equal(c.FD.duel.active, nil, "identity recovery cannot extend the original pending timeout")
    equal(c.FD.UI.frame:IsShown(), false, "original deadline removes recovered replacement")
    equal(c.nativeVisible, true, "original deadline restores ordinary native choice")

    local stopPending = {
        { "native acceptance", function(state) state.env.AcceptDuel() end },
        { "native decline", function(state) state.env.CancelDuel() end },
        { "native cancellation", function(state) state:emit("CHAT_MSG_SYSTEM", state.env.ERR_DUEL_CANCELLED) end },
        { "countdown", function(state) state:emit("CHAT_MSG_SYSTEM", "Duel starting: 3") end },
        { "finished duel", function(state) state:emit("DUEL_FINISHED") end },
        { "combat", function(state)
            state.combat = true
            state:emit("PLAYER_REGEN_DISABLED")
            state.combat = false
        end },
        { "world transition", function(state) state:emit("PLAYER_LEAVING_WORLD") end },
        { "logout", function(state) state:emit("PLAYER_LOGOUT") end },
        { "addon error", function(state) state.FD:Safe(function() error("injected pending failure") end) end },
        { "new outgoing attempt", function(state) state.env.StartDuel("missing") end },
        { "restricted popup visibility", function(state)
            state.env.StaticPopup_Visible = function() return state.secret end
        end },
        { "popup visibility error", function(state)
            state.env.StaticPopup_Visible = function() error("injected popup visibility failure") end
        end },
        { "closed native popup", function(state)
            state.nativeVisible = false
            state:advance(0.5)
        end },
        { "expired request", function(state) state:advance(state.FD.C.PENDING_TIMEOUT) end },
    }
    for _, scenario in ipairs(stopPending) do
        c = client()
        local opponent = c.units.target
        c.units.target = nil
        c:incoming()
        scenario[2](c)
        c.units.target = opponent
        c:advance(1)
        equal(c.FD.duel.active, nil, scenario[1] .. " prevents late identity from reviving negotiation")
        equal(c.FD.UI.frame:IsShown(), false, scenario[1] .. " leaves no stale replacement")
        equal(c.hides, 0, scenario[1] .. " does not suppress the native flow")
    end

    c = client()
    c.env.StaticPopup_Visible = nil
    delayedOpponent = c.units.target
    c.units.target = nil
    c:incoming()
    c.units.target = delayedOpponent
    c:advance(1)
    equal(c.FD.duel.active, nil, "missing popup visibility API prevents unsafe deferred recovery")
    equal(c.nativeVisible, true, "missing popup visibility API keeps native choice")

    c = client()
    delayedOpponent = c.units.target
    c.units.target = nil
    c:incoming()
    c:advance(0.25)
    c:incoming("Gamma")
    c.units.target = delayedOpponent
    c:advance(0.5)
    equal(c.FD.duel.active, nil, "old retry cannot resolve a newer request from another challenger")
    equal(c.nativeVisible, true, "new unresolved challenger keeps native popup")
    c.units.target = { guid = "Player-1-00000003", name = "Gamma", realm = "Forever", classFile = "WARRIOR" }
    c:advance(0.5)
    equal(c.FD.duel.active.opponent.guid, "Player-1-00000003", "replacement request resolves only its own challenger")
    equal(c.FD.duel.active.createdAt, 0.25, "replacement request owns its own native timestamp")
    local recovered = c.FD.duel.active
    c:advance(1)
    equal(c.FD.duel.active, recovered, "obsolete retry callbacks cannot replace the recovered session")

    for _, timing in ipairs({ "initial", "late" }) do
        c = client()
        delayedOpponent = c.units.target
        local ambiguousPeer = { guid = "Player-1-00000003", name = "Beta", realm = "Other", classFile = "WARRIOR" }
        if timing == "initial" then c.units.focus = ambiguousPeer else c.units.target = nil end
        c:incoming()
        c.units.target, c.units.focus = delayedOpponent, ambiguousPeer
        c:advance(0.5)
        equal(c.FD.duel.active, nil, timing .. " ambiguous challenger cannot establish rated identity")
        equal(c.nativeVisible, true, "ambiguous identity preserves native choice")
        c.units.focus = nil
        c:advance(0.5)
        equal(c.FD.duel.active, nil, "losing an ambiguous candidate cannot revive this request")
        c:incoming("Beta-Forever")
        equal(c.FD.duel.active.opponent.guid, delayedOpponent.guid, "new exact-name request can establish native identity")
    end

    c = client()
    c:incoming()
    c.env.AcceptDuel()
    equal(c.FD.duel:State(), "UNRATED", "external native acceptance immediately invalidates negotiation")
    equal(c.FD.duel.active.nativeAccepted, true, "external acceptance cannot later restore a pending popup")
    equal(c.FD.UI.frame:IsShown(), false, "external acceptance removes owned negotiation UI")
    c:advance(c.FD.C.PENDING_TIMEOUT)
    equal(c.FD.Database:GetStats().rating, 1500, "external acceptance cannot retroactively rate")

    c = client()
    c:incoming()
    c:incoming("Unknown")
    c:advance(0)
    equal(c.nativeVisible, true, "stale deferred hide leaves a newer unknown request visible")
    equal(c.FD.duel.active, nil, "unknown incoming identity creates no session")
    equal(c.FD.UI.frame:IsShown(), false, "unknown incoming identity retains native-only flow")
    equal(c.hides, 0, "stale suppression callback has no side effect")

    c = client()
    c:incoming()
    c:advance(c.FD.C.PENDING_TIMEOUT)
    equal(c.FD.duel.active, nil, "pending timeout clears addon session")
    equal(c.nativeVisible, true, "pending timeout restores still-pending native dialog")
    equal(c.FD.UI.frame:IsShown(), false, "timeout removes owned dialog")

    c = client()
    c:incoming()
    c:advance(0)
    c.combat = true
    c:emit("PLAYER_REGEN_DISABLED")
    equal(c.FD.duel:State(), "UNRATED", "combat during negotiation fails unrated")
    equal(c.FD.UI.frame:IsShown(), true, "combat cancellation preserves ordinary buttons")
    c:advance(c.FD.C.PENDING_TIMEOUT)
    equal(c.FD.duel:State(), "UNRATED", "combat expiry retains only an unrated pending request")
    equal(c.FD.UI.frame:IsShown(), true, "combat expiry cannot remove both duel dialogs")
    c.FD.UI.normal.scripts.OnClick()
    equal(c.accepts, 1, "normal acceptance remains available after combat expiry")

    c = client()
    c:incoming()
    c:advance(0)
    local active = c.FD.duel.active
    c.FD.duel:Later(0.25, active, function() error("injected timer failure") end)
    c:advance(0.25)
    equal(c.FD.duel.active, nil, "timer exception clears rated session")
    equal(c.nativeVisible, true, "timer exception restores ordinary duel dialog")
    equal(c.FD.Database:GetStats().rating, 1500, "timer exception does not rate")

    c = client()
    c:incoming()
    c:advance(0)
    c.FD.Protocol.Decode = function() error("injected transport timer failure") end
    c:advance(c.FD.C.SEND_INTERVAL)
    equal(c.FD.duel.active, nil, "transport timer exception clears session")
    equal(c.nativeVisible, true, "transport timer exception restores ordinary flow")

    c = client()
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "server acknowledgement without captured candidate ignored")
    c.env.StartDuel("missing")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "unresolved requested unit never falls back to current target")
    c.env.StartDuel("target")
    equal(c.FD.duel.active, nil, "StartDuel attempt alone does not open rated session")
    c.units.target = { guid = "Player-1-00000003", name = "Gamma", realm = "Forever", classFile = "WARRIOR" }
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active.opponent.guid, "Player-1-00000002", "ack binds captured identity despite target change")
    equal(c.FD.duel.active.role, "OUTGOING", "ack creates correct duel role")

    for _, noticeEvent in ipairs({ "UI_INFO_MESSAGE", "UI_ERROR_MESSAGE" }) do
        c = client()
        c:emit(noticeEvent, 123, c.env.ERR_DUEL_REQUESTED)
        equal(c.FD.duel.active, nil, noticeEvent .. " requires a locally captured attempt")
        c.env.StartDuel("target")
        c:emit(noticeEvent, 123, "Unrelated game notification")
        equal(c.FD.duel.active, nil, noticeEvent .. " ignores unrelated notices")
        c:emit(noticeEvent, 123, c.secret)
        equal(c.FD.duel.active, nil, noticeEvent .. " ignores restricted notices")
        c:emit(noticeEvent, 123, c.env.ERR_DUEL_REQUESTED)
        equal(c.FD.duel:State(), "CHECKING_ADDON", noticeEvent .. " acknowledges native outgoing request")
        equal(c.FD.duel.active.opponent.guid, "Player-1-00000002", noticeEvent .. " preserves captured GUID")
        local parserCalls = 0
        c.FD.Results.Countdown = function() parserCalls = parserCalls + 1 end
        c.FD.Results.Parse = function() parserCalls = parserCalls + 1 end
        c:emit(noticeEvent, 123, "Duel starting: 3")
        c:emit(noticeEvent, 123, "Alpha has defeated Beta in a duel")
        equal(parserCalls, 0, noticeEvent .. " never supplies start or result evidence")
        c:emit(noticeEvent, 123, c.env.ERR_DUEL_CANCELLED)
        equal(c.FD.duel.active, nil, noticeEvent .. " cancels native request")
        c = client()
        c.env.StartDuel("target")
        c:advance(c.FD.C.PRESENCE_TIMEOUT + 0.01)
        c:emit(noticeEvent, 123, c.env.ERR_DUEL_REQUESTED)
        equal(c.FD.duel.active, nil, noticeEvent .. " cannot revive expired attempt")
    end

    c = client()
    c.env.StartDuel("target")
    c:advance(c.FD.C.PRESENCE_TIMEOUT + 0.01)
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "expired outgoing candidate cannot be revived")
    c = client()
    c.env.StartDuel("target")
    c.units.mouseover = { guid = "Player-1-00000003", name = "Gamma", realm = "Forever", classFile = "WARRIOR" }
    c.env.StartDuel("mouseover")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "overlapping attempts make unqualified acknowledgement ambiguous")

    -- Retain useful request diagnostics when debug is disabled. A missing
    -- challenger dialog must remain diagnosable after the four-second capture
    -- expires, without allowing that old capture to start a later rated duel.
    local function outgoingStatusPrinted(state)
        local before = #state.prints
        state.env.SlashCmdList.FOREVERDUEL("status")
        for index = before + 1, #state.prints do
            local message = state.prints[index]
            if message:find("Outgoing request: ", 1, true) then return message end
        end
    end
    c = client()
    equal(c.FD.Database.data.settings.debug, false, "outgoing diagnostics run with debug disabled")
    c.env.StartDuel("target")
    local capturedStatus = c.FD.Wow.outgoingStatus
    equal(type(capturedStatus), "string", "native capture records a diagnostic status")
    c:advance(c.FD.C.PRESENCE_TIMEOUT + 0.01)
    equal(c.FD.Wow.outgoing, nil, "expired capture no longer authorizes native acknowledgment")
    local expiredStatus, expiredAt = c.FD.Wow.outgoingStatus, c.FD.Wow.outgoingAt
    equal(type(expiredStatus), "string", "capture expiry remains diagnosable without debug")
    equal(expiredStatus ~= capturedStatus, true, "expiry status distinguishes capture from failure")
    equal(expiredAt, c.FD.C.PRESENCE_TIMEOUT, "expiry diagnostic records its transition time")
    c:advance(2)
    local printed = outgoingStatusPrinted(c)
    equal(type(printed), "string", "status command includes an expired outgoing attempt")
    equal(printed and printed:find(expiredStatus, 1, true) ~= nil, true, "status prints the retained expiry reason")
    equal(printed and printed:find("ago", 1, true) ~= nil, true, "status exposes the age of retained outgoing evidence")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "diagnostic retention cannot revive the expired native capture")
    equal(c.FD.Wow.outgoingStatus, expiredStatus, "unassociated acknowledgment does not rewrite the failed attempt")
    c.FD.Wow.incomingStatus = "previous incoming request"
    c.env.StartDuel("target")
    equal(c.FD.Wow.incomingStatus, nil, "new outgoing request removes stale incoming diagnostics")
    equal(c.FD.Wow.outgoingAt, c.now, "new outgoing request supersedes the previous diagnostic time")
    c:emit("UI_INFO_MESSAGE", 123, c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel:State(), "CHECKING_ADDON", "fresh captured attempt still requires native acknowledgment")
    local acknowledgedStatus, acknowledgedAt = c.FD.Wow.outgoingStatus, c.FD.Wow.outgoingAt
    equal(type(acknowledgedStatus), "string", "acknowledgment is retained after capture removal")
    equal(acknowledgedStatus ~= expiredStatus, true, "successful fresh attempt supersedes the old expiry reason")
    c:advance(c.FD.C.PRESENCE_TIMEOUT + 0.01)
    equal(c.FD.Wow.outgoingStatus, acknowledgedStatus, "old capture timer cannot replace acknowledged status")
    equal(c.FD.Wow.outgoingAt, acknowledgedAt, "old capture timer cannot refresh the acknowledged status age")
    equal(outgoingStatusPrinted(c):find(acknowledgedStatus, 1, true) ~= nil, true, "status describes the latest attempt after capture is gone")

    for _, setup in ipairs({
        { "unavailable identity", function(state) return "missing" end },
        { "restricted unit", function(state) return state.secret end },
        { "combat", function(state) state.combat = true; return "target" end },
    }) do
        c = client()
        c.FD.Wow.incomingStatus = "previous incoming request"
        c:advance(0.25)
        c.env.StartDuel(setup[2](c))
        equal(c.FD.Wow.outgoing, nil, setup[1] .. " cannot create an outgoing capture")
        equal(type(c.FD.Wow.outgoingStatus), "string", setup[1] .. " has a retained diagnostic without debug")
        equal(c.FD.Wow.outgoingAt, c.now, setup[1] .. " diagnostic belongs to this attempt")
        equal(c.FD.Wow.incomingStatus, nil, setup[1] .. " replaces stale incoming diagnostics")
        equal(type(outgoingStatusPrinted(c)), "string", setup[1] .. " remains visible through the status command")
    end

    -- Native termination releases a capture and its overlap quarantine. Local
    -- cancel/accept calls and error recovery only discard the candidate: they
    -- must preserve the window in which an old unqualified ack may still arrive.
    local outgoingEndings = {
        { "local cancel", function(state) state.env.CancelDuel() end },
        { "native finish", function(state) state:emit("DUEL_FINISHED") end, true },
        { "native countdown", function(state) state:emit("CHAT_MSG_SYSTEM", "Duel starting: 3") end, true },
        { "combat entry", function(state)
            state.combat = true
            state:emit("PLAYER_REGEN_DISABLED")
            state.combat = false
        end },
        { "local acceptance", function(state) state.env.AcceptDuel() end },
        { "cancel notice", function(state) state:emit("CHAT_MSG_SYSTEM", state.env.ERR_DUEL_CANCELLED) end, true },
        { "world transition", function(state) state:emit("PLAYER_LEAVING_WORLD") end, true },
        { "logout", function(state) state:emit("PLAYER_LOGOUT") end, true },
        { "addon error", function(state) state.FD:Safe(function() error("injected outgoing failure") end) end },
    }
    for _, ending in ipairs(outgoingEndings) do
        for _, overlap in ipairs({ false, true }) do
            c = client()
            c.env.StartDuel("target")
            if overlap then
                c:advance(0.5)
                c.env.StartDuel("target")
                equal(c.FD.Wow.outgoing, nil, ending[1] .. " setup quarantines overlapping attempts")
                equal(c.FD.Wow.outgoingBlockedUntil > c.now, true, ending[1] .. " setup has an active quarantine")
            end
            local priorDeadline = c.FD.Wow.outgoingBlockedUntil
                or c.FD.Wow.outgoing.at + c.FD.C.PRESENCE_TIMEOUT
            c:advance(0.25)
            ending[2](c)
            equal(c.FD.Wow.outgoing, nil, ending[1] .. " clears an unacknowledged outgoing capture")
            equal(type(c.FD.Wow.outgoingStatus), "string", ending[1] .. " retains the outgoing termination reason")
            equal(c.FD.Wow.outgoingAt, c.now, ending[1] .. " records when outgoing tracking ended")
            if ending[3] then
                equal(c.FD.Wow.outgoingBlockedUntil, nil, ending[1] .. " clears the terminated request's overlap quarantine")
                c:emit("UI_INFO_MESSAGE", 123, c.env.ERR_DUEL_REQUESTED)
                equal(c.FD.duel.active, nil, ending[1] .. " prevents late acknowledgment of the old request")
            else
                equal(c.FD.Wow.outgoingBlockedUntil, priorDeadline, ending[1] .. " preserves the old acknowledgment deadline")
                -- Reproduced regression: Beta attempt, local CancelDuel, Gamma
                -- attempt, then only Beta's delayed native request ack. Gamma
                -- must not acquire a rated session from that old notice.
                c.units.mouseover = { guid = "Player-1-00000003", name = "Gamma", realm = "Forever", classFile = "WARRIOR" }
                c.env.StartDuel("mouseover")
                equal(c.FD.Wow.outgoing, nil, ending[1] .. " rejects a different target inside the old acknowledgment window")
                c:emit("UI_INFO_MESSAGE", 123, c.env.ERR_DUEL_REQUESTED)
                equal(c.FD.duel.active, nil, ending[1] .. " cannot bind a delayed old acknowledgment to the different target")
                equal(c.FD.Wow.outgoingBlockedUntil, c.now + c.FD.C.PRESENCE_TIMEOUT,
                    ending[1] .. " overlapping retry extends the ambiguity window")
                c:advance(c.FD.C.PRESENCE_TIMEOUT + 0.01)
            end
            c.env.StartDuel("target")
            equal(c.FD.Wow.outgoing ~= nil, true, ending[1] .. " allows a fresh attempt after the ambiguity guard permits it")
            equal(c.FD.duel.active, nil, ending[1] .. " does not bypass native acknowledgment for the rematch")
            c:emit("UI_INFO_MESSAGE", 123, c.env.ERR_DUEL_REQUESTED)
            equal(c.FD.duel:State(), "CHECKING_ADDON", ending[1] .. " allows the freshly acknowledged rematch")
        end
    end

    c = client()
    c.env.StartDuel("target")
    c.env.StartDuel("target")
    c:incoming()
    equal(c.FD.Wow.outgoing, nil, "incoming request replaces an outgoing capture")
    equal(c.FD.Wow.outgoingBlockedUntil, nil, "incoming request clears stale outgoing quarantine")
    equal(c.FD.Wow.outgoingStatus, nil, "incoming request does not show an unrelated outgoing diagnostic")
    equal(c.FD.Wow.outgoingAt, nil, "incoming request removes unrelated outgoing diagnostic age")
    equal(c.FD.duel.active.role, "INCOMING", "incoming request keeps its own native role")

    c = client()
    c:incoming()
    local calls = 0
    c.FD.Results.Countdown = function() calls = calls + 1; error("secret parsed") end
    c.FD.Results.Parse = function() calls = calls + 1; error("secret parsed") end
    c:emit("CHAT_MSG_SYSTEM", c.secret)
    equal(calls, 0, "secret system text is ignored before parser access")
    equal(c.FD.duel:State(), "CHECKING_ADDON", "secret unrelated evidence does not change session")
    local guid = c.units.target.guid
    c.units.target.guid = c.secret
    equal(c.FD.Wow:Identity("target"), nil, "secret unit GUID is rejected before protocol validation")
    c.units.target.guid = guid
    local receiveCalls = 0
    c.FD.duel.Receive = function() receiveCalls = receiveCalls + 1 end
    c.FD.Comms:Receive(c.env.ERR_DUEL_REQUESTED, "x", "WHISPER", "Beta")
    c.FD.Comms:Receive(c.FD.C.PREFIX, c.secret, "WHISPER", "Beta")
    c.FD.Comms:Receive(c.FD.C.PREFIX, "x", "PARTY", "Beta")
    equal(receiveCalls, 0, "wrong prefix/channel and secret payload rejected")

    for _, code in ipairs({ 2, 3 }) do
        c = client({ registerResult = code })
        equal(c.FD.Comms.available, false, "truthy registration failure enum rejected")
        equal(c.FD.Comms:Send("x", "Beta-Forever", {}), false, "unavailable registration cannot enqueue")
    end
    c = client({ registerResult = 1 })
    equal(c.FD.Comms.available, true, "already-registered prefix remains available")

    c = client()
    c:incoming()
    c:advance(c.FD.C.SEND_INTERVAL)
    local sent = #c.sent
    local old = c.FD.duel.active
    c.FD.Comms:Send(packet(c.FD, "ACCEPT"), "Beta-Forever", old)
    c.FD.duel.active = nil
    c:advance(c.FD.C.SEND_INTERVAL)
    equal(#c.sent, sent, "queued obsolete consent dropped after session cancellation")
    old.finalized = true
    c.FD.Comms:Send(packet(c.FD, "RESULT"), "Beta-Forever", old)
    c:advance(c.FD.C.SEND_INTERVAL)
    equal(#c.sent, sent + 1, "finalized result can drain after active session released")
    equal(c.FD.Protocol:Decode(c.sent[#c.sent].payload).kind, "RESULT", "drained payload is result")
    equal(c.sent[#c.sent].channel, "WHISPER", "transport uses targeted whisper")
    equal(c.sent[#c.sent].target, "Beta-Forever", "transport preserves explicit realm")

    -- Reproduce the live failure through two real native/transport adapters:
    -- surname-based whisper addresses and packets delayed past four seconds.
    local alpha = { guid = "Player-1-00000001", name = "Alpha", surname = "Example", classFile = "MAGE" }
    local tray = { guid = "Player-1-00000002", name = "Tray", surname = "Taylorr", classFile = "ROGUE" }
    local a = client({ regionalNames = true, units = { player = alpha, target = tray } })
    local b = client({ regionalNames = true, units = { player = tray, target = alpha } })
    local target = a.FD.Wow:Identity("target")
    equal(target.fullName, "Tray Taylorr", "Forever uses exact native surname format")
    equal(target.name, "Tray Taylorr", "result names retain the complete character name")
    equal(target.realm, "Forever", "surname does not replace realm metadata")
    equal(target.nameFormat, "surname", "name mode is captured in identity snapshot")
    equal(a.FD.Wow:ResolveIncoming("Tray Taylorr").guid, tray.guid, "full surname resolves native request")
    equal(a.FD.Wow:ResolveIncoming("Tray-Taylorr").guid, tray.guid, "observed legacy unit form remains native-event-only alias")
    a.units.focus = { guid = "Player-1-00000003", name = "Tray", surname = "Other", classFile = "MAGE" }
    equal(a.FD.Wow:ResolveIncoming("Tray"), nil, "ambiguous native first names do not select a GUID")
    equal(a.FD.Wow:ResolveIncoming("Tray Taylorr").guid, tray.guid, "full surname distinguishes same first name")
    a.units.focus = nil
    local callsBefore = a.nameHelperCalls
    a.env.UnitNameUnmodified = function() return "Tray", a.secret end
    equal(a.FD.Wow:Identity("target"), nil, "restricted surname rejected before native helper")
    equal(a.nameHelperCalls, callsBefore, "restricted surname is never concatenated by helper")
    a.env.UnitNameUnmodified = function(unit)
        local identity = a.units[unit]
        if identity then return identity.name, identity.surname end
    end
    toggleDebugOff(a)
    toggleDebugOff(b)
    a.env.StartDuel("target")
    a:emit("UI_INFO_MESSAGE", 123, a.env.ERR_DUEL_REQUESTED)
    b.units.target = nil
    b:incoming("Alpha Example")
    a:advance(5)
    b:advance(0.5)
    equal(b.FD.duel.active, nil, "surname receiver initially lacks native challenger identity")
    b.units.target = alpha
    b:advance(4.5)
    equal(b.nativeVisible, false, "surname receiver recovers the pending request with debug off")
    equal(a.FD.duel:State(), "DISCOVERY_WAIT", "outgoing discovery survives delayed delivery")
    equal(b.FD.duel:State(), "DISCOVERY_WAIT", "incoming discovery survives delayed delivery")
    equal(a.FD.UI.frame:IsShown(), false, "outgoing soft timeout does not show a consent dialog")
    equal(b.FD.UI.frame:IsShown(), true, "incoming soft timeout preserves ordinary choice")
    equal(b.FD.UI.rated.enabled, false, "timeout alone never grants consent")
    equal(b.FD.UI.normal.text, "Accept Normal Duel", "ordinary action is clear after soft timeout")
    equal(a.sent[1].target, "Tray Taylorr", "whisper target is the canonical surname name")
    for _, sender in ipairs({ "Tray", "Tray-Taylorr", "Tray Other", "Tray Taylorr-Forever" }) do
        a:emit("CHAT_MSG_ADDON", a.FD.C.PREFIX, b.sent[1].payload, "WHISPER", sender)
        equal(a.FD.duel.active.peerNonce, nil, "unqualified or altered surname sender rejected: " .. sender)
    end
    local deliveredA, deliveredB = 0, 0
    local function exchange()
        for _ = 1, 8 do
            while deliveredA < #a.sent do
                deliveredA = deliveredA + 1
                local p = a.sent[deliveredA]
                b:emit("CHAT_MSG_ADDON", p.prefix, p.payload, p.channel, "Alpha Example")
            end
            while deliveredB < #b.sent do
                deliveredB = deliveredB + 1
                local p = b.sent[deliveredB]
                a:emit("CHAT_MSG_ADDON", p.prefix, p.payload, p.channel, "Tray Taylorr")
            end
            a:advance(0.15)
            b:advance(0.15)
        end
    end
    exchange()
    equal(a.FD.duel:State(), "READY", "delayed surname handshake reaches outgoing ready")
    equal(b.FD.duel:State(), "READY", "delayed surname handshake reaches incoming ready")
    toggleDebugOff(b)
    equal(a.FD.duel.active.matchId, b.FD.duel.active.matchId, "real adapters agree on the same session")
    local visibleOpponent = a.units.target
    a.units.target = nil
    equal(a.FD.duel:Fresh(), false, "lost native peer identity prevents rated consent")
    a.units.target = visibleOpponent
    local priorLevel = visibleOpponent.level
    visibleOpponent.level = 31
    equal(a.FD.duel:Fresh(), false, "changed native level is detected without a level event")
    visibleOpponent.level = priorLevel
    a.units.focus = { guid = "Player-1-00000003", name = "Third", surname = "Player", classFile = "MAGE", level = 31 }
    a:emit("UNIT_LEVEL", "focus")
    equal(a.FD.duel:State(), "READY", "unrelated level-up preserves rated negotiation")
    a.units.focus = nil
    equal(b.accepts, 0, "recovered discovery never accepts native duel automatically")
    a.FD.UI.rated.scripts.OnClick()
    exchange()
    equal(b.accepts, 0, "one surname peer's consent does not start native duel")
    b.FD.UI.rated.scripts.OnClick()
    exchange()
    equal(b.accepts, 1, "both explicit clicks complete handshake through real surname transport")
    local winner = a.FD.Results:Parse("Alpha Example has defeated Tray Taylorr in a duel",
        a.env.DUEL_WINNER_KNOCKOUT, a.env.DUEL_WINNER_RETREAT, a.FD.duel.active.player, a.FD.duel.active.opponent)
    equal(winner, alpha.guid, "full surnamed result resolves known participants")
    winner = a.FD.Results:Parse("Alpha has defeated Tray in a duel",
        a.env.DUEL_WINNER_KNOCKOUT, a.env.DUEL_WINNER_RETREAT, a.FD.duel.active.player, a.FD.duel.active.opponent)
    equal(winner, nil, "native-request aliases never qualify result evidence")

    a.env.SlashCmdList.FOREVERDUEL("ui")
    a:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
    b:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
    a:advance(3)
    b:advance(3)
    exchange()
    a:emit("DUEL_FINISHED")
    b:emit("DUEL_FINISHED")
    a:emit("CHAT_MSG_SYSTEM", "Alpha Example has defeated Tray Taylorr in a duel")
    b:emit("CHAT_MSG_SYSTEM", "Alpha Example has defeated Tray Taylorr in a duel")
    exchange()
    equal(a.FD.Database:GetStats().rating, 1516, "completed native-adapter match updates winner rating")
    equal(b.FD.Database:GetStats().rating, 1484, "completed native-adapter match updates loser rating")
    equal(a.FD.Profile.stats[1].text, "1516", "open overview refreshes after real finalization")
    equal(a.FD.Profile.rows[1].match.matchId, a.FD.Database.data.matches[1].matchId, "newly committed duel appears without reopening")
    equal(a.FD.Profile.rows[1].cells[4].text, "+16", "overview shows actual finalized rating change")
    a.env.SlashCmdList.FOREVERDUEL("reset")
    a.env.SlashCmdList.FOREVERDUEL("reset confirm")
    equal(a.FD.Profile.stats[1].text, "1500", "open overview refreshes after confirmed reset")
    equal(a.FD.Profile.empty:IsShown(), true, "reset clears visible history rows")
    equal(a.FD.Profile.selectedId, nil, "reset clears stale match selection")

    -- Full loaded-addon integration: untargeted roster discovery -> row click -> the
    -- existing explicit consent/native evidence flow -> advertised new rating.
    a = client({ presence = true, directory = { alpha, tray }, regionalNames = true, units = { player = alpha } })
    b = client({ presence = true, directory = { alpha, tray }, regionalNames = true, units = { player = tray } })
    deliveredA, deliveredB = 0, 0
    local function exchangeWithPresence()
        for _ = 1, 8 do
            while deliveredA < #a.sent do
                deliveredA = deliveredA + 1
                local p = a.sent[deliveredA]
                if p.result == 0 then
                    b:emit("CHAT_MSG_ADDON", p.prefix, p.payload, p.channel, "Alpha Example", nil, 0,
                        p.channel == "CHANNEL" and b.channelID or nil)
                end
            end
            while deliveredB < #b.sent do
                deliveredB = deliveredB + 1
                local p = b.sent[deliveredB]
                if p.result == 0 then
                    a:emit("CHAT_MSG_ADDON", p.prefix, p.payload, p.channel, "Tray Taylorr", nil, 0,
                        p.channel == "CHANNEL" and a.channelID or nil)
                end
            end
            a:advance(0.15)
            b:advance(0.15)
        end
    end
    a:advance(10)
    b:advance(10)
    exchangeWithPresence()
    equal(a.FD.Presence.available, true, "loaded addon initializes automatic roster presence")
    equal(a.joinedChannel, "ForeverDuel", "loaded addon joins the dedicated directory")
    equal(a.FD.Presence.areaUnsupported, true, "native YELL rejection does not prevent directory discovery")
    equal(a.FD.Presence.lastReceive:find("WHISPER", 1, true) ~= nil, true, "directory discovery receives actual whispered profiles")
    equal(a.selectedChannel, 1, "loaded integration restores the native channel selection")
    equal(#a.FD.Presence:GetPlayers(), 1, "first adapter discovers the other surname player")
    equal(#b.FD.Presence:GetPlayers(), 1, "second adapter discovers first player")
    equal(a.FD.duel.active, nil, "area presence cannot establish a rated session")
    equal(b.accepts, 0, "area presence cannot accept a native request")
    a.env.SlashCmdList.FOREVERDUEL("zone")
    equal(a.FD.Zone.rows[1].name.text, "Tray Taylorr", "discovery populates visible browser")
    -- Native duel initiation still resolves a visible unit, after discovery.
    a.units.target, b.units.target = tray, alpha
    a.FD.Zone.rows[1].duel.scripts.OnClick()
    equal(a.FD.Wow.outgoing.opponent.guid, tray.guid, "row click reaches existing native identity hook")
    equal(a.FD.duel.active, nil, "row click still awaits native acknowledgment")
    a:emit("UI_INFO_MESSAGE", 123, a.env.ERR_DUEL_REQUESTED)
    b:incoming("Alpha Example")
    exchangeWithPresence()
    equal(a.FD.duel:State(), "READY", "normal handshake works alongside area presence")
    equal(b.accepts, 0, "handshake discovery still requires explicit consent")
    a.FD.UI.rated.scripts.OnClick()
    exchangeWithPresence()
    equal(b.accepts, 0, "one player's rated consent remains insufficient")
    b.FD.UI.rated.scripts.OnClick()
    exchangeWithPresence()
    equal(b.accepts, 1, "both consent clicks complete native acceptance with discovery enabled")
    a:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
    b:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
    a:advance(3)
    b:advance(3)
    exchangeWithPresence()
    a:emit("DUEL_FINISHED")
    b:emit("DUEL_FINISHED")
    a:emit("CHAT_MSG_SYSTEM", "Alpha Example has defeated Tray Taylorr in a duel")
    b:emit("CHAT_MSG_SYSTEM", "Alpha Example has defeated Tray Taylorr in a duel")
    exchangeWithPresence()
    a:advance(50)
    b:advance(50)
    exchangeWithPresence()
    equal(a.FD.Database:GetStats().rating, 1516, "presence-enabled duel commits winner rating")
    equal(b.FD.Database:GetStats().rating, 1484, "presence-enabled duel commits loser rating")
    equal(b.FD.Presence:GetPlayer(alpha.guid).rating, 1516, "commit advertises new winner rating to peer")
    equal(a.FD.Presence:GetPlayer(tray.guid).rating, 1484, "commit advertises new loser rating to peer")
    equal(a.FD.Zone.rows[1].rating.text, "1484", "received rating refreshes browser without reopening")
    a.env.SlashCmdList.FOREVERDUEL("reset")
    a.env.SlashCmdList.FOREVERDUEL("reset confirm")
    a:advance(50)
    b:advance(50)
    exchangeWithPresence()
    equal(b.FD.Presence:GetPlayer(alpha.guid).rating, 1500, "confirmed reset advertises new rating")
    equal(#b.FD.Database.data.matches, 1, "peer presence/reset cannot rewrite saved rated history")

    -- Opening and browsing the read-only overview cannot grant consent or
    -- disturb an unrelated pending duel, even when rendering fails.
    c = client()
    c.env.SlashCmdList.FOREVERDUEL("")
    local profile = c.FD.Profile
    equal(profile.frame:IsShown(), true, "default command opens overview")
    equal(profile.empty:IsShown(), true, "fresh character sees empty-history guidance")
    equal(profile.stats[1].text, "1500", "fresh overview shows initial rating")
    equal(profile.stats[3].text, "--", "empty win rate is not fabricated")
    equal(profile.previous.enabled, false, "empty history has no previous page")
    equal(profile.next.enabled, false, "empty history has no next page")
    equal(c.env.UISpecialFrames[1], "ForeverDuelProfile", "native Escape list owns only overview frame")
    c.env.SlashCmdList.FOREVERDUEL("")
    equal(profile.frame:IsShown(), false, "overview command toggles closed")
    for index = 1, 17 do
        local player = c.FD.Database:GetStats()
        local won = index % 2 == 1
        local after, delta = c.FD.Rating:Calculate(player.rating, 1500, won)
        local record = {
            schemaVersion = 2, protocolVersion = 2, bracket = "LEVELING", matchId = "overview-" .. index,
            player = c.FD.Wow:Identity("player", true), opponent = c.FD.Wow:Identity("target"),
            startedAt = 1700000000 + index * 100, endedAt = 1700000037 + index * 100,
            winnerGUID = won and c.units.player.guid or c.units.target.guid,
            loserGUID = won and c.units.target.guid or c.units.player.guid,
            result = won and "WIN" or "LOSS", ratingBefore = player.rating,
            ratingAfter = after, ratingDelta = delta, opponentRatingBefore = 1500,
            ratedConfirmed = true, evidence = { agreedBeforeStart = true, localResult = true, peerResult = true },
        }
        equal(c.FD.Database:Commit(record), true, "overview fixture commits a valid completed record")
    end
    c.env.SlashCmdList.FOREVERDUEL("ui")
    equal(profile.rows[1].match.matchId, "overview-17", "overview starts with latest completed duel")
    equal(profile.rows[8].match.matchId, "overview-10", "overview first page contains eight records")
    equal(profile.pageLabel.text, "Page 1 / 3", "overview pagination uses complete history")
    equal(profile.stats[2].text, "9 / 8", "overview displays wins and losses")
    profile.rows[2].scripts.OnClick()
    equal(profile.selectedId, "overview-16", "row click selects match details")
    equal(profile.detailResult.text, "DEFEAT", "detail panel reflects selected result")
    equal(profile.opponentCard.name.text, "Beta-Forever", "detail panel shows the selected opponent")
    equal(profile.rows[2].arrow.text, ">", "selected row points to detail panel")
    equal(profile.rows[1].arrow.text, "", "previous row loses selection marker")
    equal(profile.details.text:find("Duration: 0:37", 1, true) ~= nil, true, "detail panel shows persisted match duration")
    profile.next.scripts.OnClick()
    equal(profile.rows[1].match.matchId, "overview-9", "next page continues without repeated records")
    profile.next.scripts.OnClick()
    equal(profile.rows[1].match.matchId, "overview-1", "last page reaches oldest match")
    equal(profile.rows[2]:IsShown(), false, "unused rows are cleared on short last page")
    equal(profile.next.enabled, false, "last page disables next")
    equal(profile.selectedDetails.match.matchId, "overview-1", "detail panel follows page selection")
    profile.previous.scripts.OnClick()
    equal(profile.page, 2, "previous button returns one page")
    profile.close.scripts.OnClick()
    c.env.SlashCmdList.FOREVERDUEL("ui")
    equal(profile.page, 1, "reopening starts at latest history")
    equal(#c.env.UISpecialFrames, 1, "reopening does not duplicate Escape registration")
    local detail = c.FD.History:Details("overview-17")
    detail.match.opponent.specId = 259
    profile:RenderDetails(detail)
    equal(profile.opponentCard.description.text, "Lvl 30 - Assassination - ROGUE", "saved level and spec ID get a native display name")
    equal(profile.selectedDetails.opponentRatingSource, "calculated", "peer after-rating remains a derived display value")
    equal(profile.opponentCard.rating.text:find(string.format("%d  ->  %d", detail.opponentRatingBefore, detail.opponentRatingAfter), 1, true) ~= nil,
        true, "opponent panel uses independently calculated rating direction")
    detail.match.opponent.specName = "Stored specialization"
    profile:RenderDetails(detail)
    equal(profile.opponentCard.description.text, "Lvl 30 - Stored specialization - ROGUE", "stored specialization snapshot takes precedence")
    detail.match.opponent.specName = nil
    c.env.GetSpecializationNameForSpecID = function() return c.secret end
    profile:RenderDetails(detail)
    equal(profile.opponentCard.description.text, "Lvl 30 - ROGUE", "restricted specialization name is ignored before formatting")
    c.env.GetSpecializationNameForSpecID = nil
    profile:RenderDetails(detail)
    equal(profile.opponentCard.description.text, "Lvl 30 - ROGUE", "missing specialization API preserves useful details")
    local lookups = 0
    c.env.GetSpecializationNameForSpecID = function() lookups = lookups + 1; return "Wrong" end
    detail.match.opponent.specId = math.huge
    profile:RenderDetails(detail)
    equal(lookups, 0, "invalid historical spec ID never reaches native lookup")
    detail.match.opponent.name = "A|cffff0000Name"
    detail.match.opponent.fullName = nil
    profile:RenderDetails(detail)
    equal(profile.opponentCard.name.text, "A||cffff0000Name", "saved text cannot inject UI color markup")
    profile:RenderDetails(nil)
    equal(profile.playerCard:IsShown(), false, "empty selection hides player data")
    equal(profile.opponentCard:IsShown(), false, "empty selection hides opponent data")
    equal(profile.selectedDetails, nil, "empty selection clears stale match details")
    profile.close.scripts.OnClick()
    c.env.UIParent:SetSize(720, 540)
    c.env.SlashCmdList.FOREVERDUEL("ui")
    equal(profile.frame.width * profile.frame.scale <= 680, true, "overview fits narrow viewport with margins")
    equal(profile.frame.height * profile.frame.scale <= 500, true, "overview fits short viewport with margins")
    equal(c.env.UIParent.scale, nil, "fit affects only overview, not global UI scale")
    c:incoming()
    local pending = c.FD.duel.active
    profile.rows[1].scripts.OnClick()
    equal(c.FD.duel.active, pending, "history browsing preserves native pending request")
    equal(c.accepts, 0, "overview never accepts a native duel")
    c.FD.History.Overview = function() error("injected overview presentation failure") end
    profile:RefreshIfShown()
    equal(profile.frame:IsShown(), false, "failed overview closes only itself")
    equal(c.FD.duel.active, pending, "overview failure does not cancel pending rated negotiation")
    equal(c.FD.UI.frame:IsShown(), true, "overview failure preserves duel accept and decline")
    equal(#c.FD.Database.data.matches, 17, "overview failure preserves saved history")
    local printed = #c.prints
    c.env.SlashCmdList.FOREVERDUEL("summary")
    equal(#c.prints > printed, true, "chat summary remains available independently of overview")

    c = client()
    c.env.SlashCmdList.FOREVERDUEL("ui")
    c.FD.Profile.zone.scripts.OnClick()
    equal(c.FD.Zone.frame:IsShown(), true, "profile navigation opens loaded zone browser")
    equal(c.FD.Profile.frame:IsShown(), false, "zone navigation hides overview")
    equal(c.FD.Zone.empty:IsShown(), true, "unavailable discovery retains a useful empty browser")
    c.FD.Zone.overview.scripts.OnClick()
    equal(c.FD.Profile.frame:IsShown(), true, "zone navigation returns to the existing overview")
    equal(c.FD.Zone.frame:IsShown(), false, "return navigation hides zone browser")
    c:incoming()
    pending = c.FD.duel.active
    c.env.SlashCmdList.FOREVERDUEL("zone")
    equal(c.FD.Zone.frame:IsShown(), true, "zone command opens browser during a pending duel")
    equal(c.FD.duel.active, pending, "zone navigation preserves pending rated negotiation")
    equal(c.accepts, 0, "zone navigation never accepts a native request")
    c.FD.Presence.GetPlayers = function() error("injected presence read failure") end
    c.FD.Zone:RefreshIfShown()
    equal(c.FD.Zone.frame:IsShown(), false, "presence query error closes browser")
    equal(c.FD.duel.active, pending, "presence query error does not enter duel-aborting recovery")
    equal(c.FD.UI.frame:IsShown(), true, "presence query error preserves consent actions")
    c.env.C_Map = { GetBestMapForUnit = function() error("injected map API error") end }
    c.env.SlashCmdList.FOREVERDUEL("status")
    equal(c.FD.duel.active, pending, "optional discovery diagnostics cannot abort pending rated negotiation")

    c = client()
    c.sendResult = 3
    c:incoming()
    c:advance(c.FD.C.SEND_INTERVAL)
    equal(c.FD.duel:State(), "UNRATED", "truthy throttle enum fails unrated")
    equal(c.FD.UI.frame:IsShown(), true, "transport failure preserves normal choice")
    equal(c.FD.Database:GetStats().rating, 1500, "transport failure never changes rating")

    c = client()
    c.units.target.level = 36
    c:incoming(); c:advance(0)
    equal(c.FD.duel:State(), "UNRATED", "native opponent six levels higher blocks rated")
    equal(c.FD.UI.rated.enabled, false, "level guard disables rated action")
    equal(c.FD.UI.body.text:find("within 5 levels", 1, true) ~= nil, true, "clear level-gap explanation")
    c.FD.UI.normal.scripts.OnClick()
    equal(c.accepts, 1, "ineligible level keeps native ordinary acceptance")

    c = client()
    c.env.UnitLevel = function() return c.secret end
    local unknown = c.FD.Wow:Identity("player", true)
    equal(unknown.level, nil, "restricted native level is never compared or stored")
    c:incoming(); c:advance(0)
    equal(c.FD.duel:State(), "UNRATED", "unknown levels never qualify")

    c = client()
    c.env.GetMaxPlayerLevel = nil
    c:incoming(); c:advance(0)
    equal(c.FD.duel:State(), "UNRATED", "missing max-level API does not guess cap")

    c = client()
    c:incoming()
    c.units.target.level = 31
    c:emit("UNIT_LEVEL", "target")
    equal(c.FD.duel:State(), "UNRATED", "native peer level-up invalidates pending rating")

    c = client()
    c:incoming()
    c:emit("PLAYER_LEVEL_UP", 31)
    equal(c.FD.duel:State(), "UNRATED", "level-up event invalidates before UnitLevel refresh")
    c.units.player.level = 60
    c:advance(0)
    equal(c.FD.Database.bracket, "MAX_LEVEL", "deferred native refresh selects max-level pool")
    equal(c.FD.Database:GetStats("LEVELING").rating, 1500, "max-level transition leaves leveling intact")

    c = client()
    c.FD.Profile:Toggle()
    equal(c.FD.Profile.brackets.LEGACY:IsShown(), false, "fresh character has no legacy tab")
    c.FD.Profile.brackets.MAX_LEVEL.scripts.OnClick()
    equal(c.FD.Profile.bracket, "MAX_LEVEL", "overview can inspect inactive rating pool")
    equal(c.FD.Profile.chartSeries.bracket, "MAX_LEVEL", "chart follows selected pool")
    equal(c.FD.Profile.chartEmpty:IsShown(), true, "empty pool has chart guidance")
    equal(c.FD.Database.bracket, "LEVELING", "viewing max-level pool does not change active rating")

    local saved = { schemaVersion = 1,
        player = { guid = "Player-1-00000001", rating = 1500, wins = 0, losses = 0 },
        matches = {}, finalized = {}, settings = { debug = false }, nonceCounter = 7 }
    c = client({ missingCap = true, saved = saved })
    equal(c.FD.Database.data.legacy.schemaVersion, 1, "unknown login cap still loads legacy data")
    equal(saved.schemaVersion, 1, "migration never mutates original saved input")
    equal(c.FD.Database.bracket, nil, "unknown login cap has no active group")
    c:incoming()
    equal(c.FD.duel:State(), "UNRATED", "unknown login cap keeps native fallback")
    c.FD.duel:Abort("test cancellation", false)
    c.env.GetMaxPlayerLevel = function() return 60 end
    c:emit("PLAYER_ENTERING_WORLD")
    c:incoming()
    equal(c.FD.Database.bracket, "LEVELING", "available cap recovers without reload")
    equal(c.FD.duel:State(), "CHECKING_ADDON", "new request recovers rated discovery")
end
