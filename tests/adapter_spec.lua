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
        function methods:RegisterEvent(event)
            if event == "CHAT_MSG_ADDON_LOGGED" and options.loggedRegistration == "error" then error("logged event unavailable") end
            if event == "CHAT_MSG_ADDON_LOGGED" and options.loggedRegistration == false then return false end
            self.events[event] = true
        end
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
        env.IsInGroup = function() return state.grouped == true end
        env.IsInRaid = function() return state.raid == true end
        env.GetNumGroupMembers = function() return state.members or 0 end
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
            SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, InvalidChatType = 4,
                NotInGroup = 5, GeneralError = 9 },
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
        if options.logged then
            state.loggedResult = 0
            env.C_ChatInfo.SendAddonMessageLogged = function(prefix, payload, channel, target)
                state.loggedCalls = (state.loggedCalls or 0) + 1
                if state.loggedError then error("logged native send unavailable") end
                state.sent[#state.sent + 1] = { prefix = prefix, payload = payload, channel = channel,
                    target = target, result = state.loggedResult, logged = true }
                return state.loggedResult
            end
        end
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

    local function opponentHello(state)
        local match = state.FD.duel.active
        return assert(state.FD.Protocol:Encode({ kind = "HELLO", nonce = "abc-feed", echo = "-",
            guid = match.opponent.guid, peerGUID = match.player.guid, role = "OUTGOING", rating = 1500,
            specId = 0, classFile = match.opponent.classFile, wins = 0, losses = 0,
            level = match.opponent.level, maxLevel = match.opponent.maxLevel, verdict = "-" }))
    end

    local function makeParty(state)
        state.grouped, state.raid, state.members = true, false, 2
        state.units.party1 = state.FD.Copy(state.units.target)
    end

    for _, case in ipairs({
        { name = "restricted normal payload", logged = false, field = "payload", reason = "restricted native payload" },
        { name = "restricted logged payload", logged = true, field = "payload", reason = "restricted native payload" },
        { name = "restricted normal channel", logged = false, field = "channel", reason = "restricted native channel" },
        { name = "restricted logged sender", logged = true, field = "sender", reason = "restricted native sender" },
        { name = "unsupported normal CHANNEL", logged = false, channel = "CHANNEL", reason = "unsupported native channel" },
        { name = "unsupported logged WHISPER_INFORM", logged = true, channel = "WHISPER_INFORM", reason = "unsupported native channel" },
        { name = "logged PARTY", logged = true, channel = "PARTY", reason = "logged event requires WHISPER" },
        { name = "unavailable logged registration", logged = true, unavailable = true, reason = "logged event registration unavailable" },
        { name = "restricted logged prefix", logged = true, field = "prefix", reason = "restricted native prefix" },
    }) do
        local state = client({ logged = true })
        state:incoming()
        local fd, match = state.FD, state.FD.duel.active
        equal(fd.Comms.ingressStatusMatch, match, case.name .. " starts counts for this native request")
        equal(fd.Comms.ingressCounts.logged + fd.Comms.ingressCounts.normal, 0,
            case.name .. " initially distinguishes no native event")
        local fields = { prefix = fd.C.PREFIX, payload = opponentHello(state), channel = case.channel or "WHISPER", sender = "Beta" }
        if case.field then fields[case.field] = state.secret end
        if case.unavailable then fd.Comms.loggedReceiveAvailable = false end
        fd.Comms:Receive(fields.prefix, fields.payload, fields.channel, fields.sender, case.logged)
        equal(fd.Comms.ingressCounts[case.logged and "logged" or "normal"], 1,
            case.name .. " native event is counted before its early gate")
        equal(fd.Comms.ingressCounts.rejected, 1, case.name .. " entry gate rejection is counted")
        equal(fd.Comms.ingressCounts.passed, 0, case.name .. " rejected gate cannot count as passed")
        equal(fd.Comms.ingressStatus:find(case.reason, 1, true) ~= nil, true, case.name .. " has a descriptive gate reason")
        equal(fd.Comms.ingressStatus:find("Beta", 1, true), nil, case.name .. " stores no native sender alias")
        equal(fd.Comms.lastReceive, nil, case.name .. " preserves original pre-receive rejection")
        equal(fd.duel.active, match, case.name .. " diagnostics cannot abort native request")
        equal(match.peerNonce, nil, case.name .. " diagnostics cannot prove a peer nonce")
        equal(state.accepts, 0, case.name .. " diagnostics cannot grant consent")
        equal(#fd.Database.data.matches, 0, case.name .. " diagnostics cannot mutate history")
    end

    do
        local state = client({ logged = true })
        state:incoming()
        local fd = state.FD
        fd.Comms:Receive("UnrelatedAddon", state.secret, state.secret, state.secret, true)
        fd.Comms:Receive(state.secret, state.secret, state.secret, state.secret, false)
        equal(fd.Comms.ingressCounts.normal + fd.Comms.ingressCounts.logged, 0,
            "unrelated readable prefixes and restricted normal prefixes are never observed")
        local initial = fd.Comms.ingressStatus
        local untrusted = "Beta payload abc-feed"
        fd.Comms:Receive(fd.C.PREFIX, opponentHello(state), untrusted, "Beta", true)
        equal(fd.Comms.ingressStatus:find(untrusted, 1, true), nil, "unexpected channel text cannot enter diagnostics verbatim")
        equal(fd.Comms.ingressStatus:find("via other", 1, true) ~= nil, true, "unknown native channel uses a bounded generic label")
        equal(fd.Comms.ingressStatus ~= initial, true, "unexpected native channel distinguishes rejected event from no event")
        fd.Comms:Receive(fd.C.PREFIX, opponentHello(state), "WHISPER", "Beta", false)
        equal(fd.Comms.ingressCounts.normal, 1, "actual ordinary native event is separately counted")
        equal(fd.Comms.ingressCounts.passed, 1, "readable own-prefix normal event passes only entry gates")
        equal(fd.duel.active.peerNonce, nil, "passed ingress gate never replaces current-request acknowledgment")
        local old = fd.Comms.ingressStatusMatch
        fd.duel:Decline(); state:incoming()
        equal(fd.Comms.ingressStatusMatch ~= old, true, "new native request resets ingress context")
        equal(fd.Comms.ingressCounts.normal + fd.Comms.ingressCounts.logged, 0, "new request cannot inherit old event counts")
        equal(fd.Comms.ingressStatus, "no addon event observed for current native request", "fresh status reports absence of current events")
        fd.duel:Decline()
        local counts, status = fd.Comms.ingressCounts, fd.Comms.ingressStatus
        fd.Comms:Receive(fd.C.PREFIX, state.secret, "CHANNEL", "Beta", true)
        equal(fd.Comms.ingressCounts, counts, "no active native context produces no ingress count snapshot")
        equal(fd.Comms.ingressStatus, status, "late event cannot produce broad idle ingress diagnostics")
    end

    do
        local state = client({ logged = true })
        state:incoming()
        local fd, recorded = state.FD, 0
        local original = fd.Debug.Log
        fd.Debug.Log = function(self, topic, ...)
            if topic == "transport ingress" then recorded = recorded + 1 end
            return original(self, topic, ...)
        end
        local prints = #state.prints
        for _ = 1, 30 do fd.Comms:Receive(fd.C.PREFIX, "not inspected", "CHANNEL", "Beta", true) end
        equal(recorded, 1, "identical gate rejections are locally deduplicated before debug logging")
        equal(fd.Comms.ingressCounts.logged, 30, "deduplicated gate traces retain actual native event count")
        equal(fd.Comms.ingressCounts.rejected, 30, "deduplicated traces retain rejection count")
        equal(#state.prints, prints, "ingress diagnostics cannot spam chat with debug disabled")
        state:advance(10)
        fd.Comms:Receive(fd.C.PREFIX, "not inspected", "CHANNEL", "Beta", true)
        equal(recorded, 2, "ongoing identical rejects retain an occasional bounded trace summary")
        fd.Comms.ingressCounts.logged, fd.Comms.ingressCounts.rejected = 1000000, 1000000
        fd.Comms:Receive(fd.C.PREFIX, "not inspected", "CHANNEL", "Beta", true)
        equal(fd.Comms.ingressCounts.logged, 1000000, "native ingress counters have a fixed upper bound")
        equal(fd.Comms.ingressCounts.rejected, 1000000, "native rejection counters have a fixed upper bound")
    end

    do
        local state = client({ logged = true })
        state:incoming()
        local fd, match = state.FD, state.FD.duel.active
        local original = fd.Debug.Log
        fd.Debug.Log = function(self, topic, ...)
            if topic == "transport ingress" then error("injected ingress log failure") end
            return original(self, topic, ...)
        end
        state:emit("CHAT_MSG_ADDON_LOGGED", fd.C.PREFIX, state.secret, "WHISPER", "Beta")
        equal(fd.duel.active, match, "ingress debug log exception cannot abort native request")
        equal(fd.Comms.ingressCounts.rejected, 1, "failed ingress log still preserves its bounded count")
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, opponentHello(state), "WHISPER", "Beta")
        equal(fd.Comms.ingressCounts.passed, 1, "failed ingress log cannot block original guarded receive")
        equal(fd.duel.active, match, "guarded receive retains native request after ingress log failure")
    end

    do
        local state = client({ logged = true })
        local fd = state.FD
        fd.Comms.InitializeIngressMatch = function() error("injected diagnostic initialization failure") end
        state:incoming(); state:advance(0.2)
        equal(fd.duel:State(), "CHECKING_ADDON", "diagnostic initialization exception cannot interrupt primary request")
        equal(state.sent[1].channel, "WHISPER", "diagnostic initialization exception cannot change primary route")
        fd.Comms.ObserveIngress = function() error("injected ingress observer failure") end
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, opponentHello(state), "WHISPER", "Beta")
        equal(fd.duel:State(), "CHECKING_ADDON", "ingress observer exception cannot interrupt original guarded receive")
        equal(fd.duel.active.peerNonce, nil, "diagnostic exceptions cannot grant session proof")
        equal(state.accepts, 0, "diagnostic exceptions cannot grant native consent")
        equal(#fd.Database.data.matches, 0, "diagnostic exceptions cannot alter history")
    end

    -- The optional native logged event carries the identical strict FD2 wire.
    -- These real adapters deliberately lose ordinary whispers, so a simulated
    -- native receipt is the only evidence that the alternate route works.
    local function loggedPair(options)
        options = options or {}
        local alpha = { guid = "Player-4613-00000001", name = "Alpha", surname = "Example", realm = "Forever", classFile = "MAGE" }
        local beta = { guid = "Player-4619-00000002", name = "Beta", surname = "Example", realm = "Forever", classFile = "ROGUE" }
        local a = client({ logged = true, regionalNames = true, units = { player = alpha, target = beta } })
        local b = client({ logged = options.peerAPI ~= false, regionalNames = true, units = { player = beta, target = alpha } })
        if options.nilResult then a.loggedResult, b.loggedResult = nil, nil end
        a.env.StartDuel("target")
        a:emit("CHAT_MSG_SYSTEM", a.env.ERR_DUEL_REQUESTED)
        b:incoming("Alpha Example")
        local counts = { normalDropped = 0, loggedHello = 0, loggedACK = 0 }
        local delivered = { [a] = 0, [b] = 0 }
        local function exchange(seconds)
            for _ = 1, math.ceil((seconds or 2) / 0.2) do
                a:advance(0.2); b:advance(0.2)
                for _, transfer in ipairs({ { from = a, to = b, name = "Alpha Example" },
                    { from = b, to = a, name = "Beta Example" } }) do
                    for index = delivered[transfer.from] + 1, #transfer.from.sent do
                        local sent = transfer.from.sent[index]
                        if sent.prefix == a.FD.C.PREFIX then
                            local decoded = a.FD.Protocol:Decode(sent.payload)
                            if sent.logged and decoded.kind == "HELLO" then counts.loggedHello = counts.loggedHello + 1 end
                            if sent.logged and decoded.kind == "HELLO_ACK" then counts.loggedACK = counts.loggedACK + 1 end
                            local permit = sent.logged and not options.dropLogged
                                or (not sent.logged and (options.allowNormal or options.normalACK and decoded.kind == "HELLO_ACK"))
                            if not sent.logged and not permit then counts.normalDropped = counts.normalDropped + 1 end
                            if permit and (sent.result == 0 or sent.logged and sent.result == nil) then
                                local event = sent.logged and "CHAT_MSG_ADDON_LOGGED" or "CHAT_MSG_ADDON"
                                transfer.to:emit(event, sent.prefix, sent.payload, sent.channel, transfer.name, transfer.to == a and "Alpha Example" or "Beta Example")
                                transfer.to:emit(event, sent.prefix, sent.payload, sent.channel, transfer.name)
                            end
                        end
                    end
                    delivered[transfer.from] = #transfer.from.sent
                end
            end
        end
        return a, b, exchange, counts
    end

    for _, nilResult in ipairs({ false, true }) do
        local a, b, exchange, counts = loggedPair({ nilResult = nilResult })
        local originalA, originalB = a.FD.duel.active, b.FD.duel.active
        exchange(3.8)
        equal(counts.loggedHello, 0, "logged probe waits four seconds after primary submission")
        equal(a.FD.duel.active.peerNonce, nil, "primary submission success cannot prove received peer")
        exchange(2)
        equal(a.FD.duel:State(), "READY", "logged solo challenger completes current-request handshake")
        equal(b.FD.duel:State(), "READY", "logged solo recipient completes current-request handshake")
        equal(a.FD.duel.active.loggedRoute, true, "accepted echoed logged ACK learns challenger route")
        equal(b.FD.duel.active.loggedRoute, true, "accepted echoed logged ACK learns recipient route")
        equal(counts.loggedHello, 2, "each solo request sends exactly one logged HELLO probe")
        equal(counts.normalDropped > 0, true, "solo integration actually loses ordinary whispers")
        equal(a.accepts + b.accepts, 0, "logged proof never grants either user's consent")
        equal(a.grouped == true or b.grouped == true, false, "logged solo route does not create a party")
        equal(a.FD.Comms.loggedStatusMatch, originalA, "acknowledgment age remains bound to current request")
        equal(a.FD.Comms.loggedStatus:find("after first HELLO submission", 1, true) ~= nil, true,
            "diagnostic describes current request age instead of packet RTT")
        equal(a.FD.Comms.loggedStatus:find(originalA.nonce, 1, true), nil, "acknowledgment summary does not persist a nonce")
        equal(type(originalA.firstHelloAt), "number", "first HELLO submission timing stays in memory")
        equal(originalA.helloPaths.LOGGED.count, 1, "logged submission timing counts only one probe")
        a.FD.UI.rated.scripts.OnClick()
        exchange()
        equal(b.FD.duel:State(), "REMOTE_ACCEPTED", "logged route carries explicit proposal only")
        equal(b.accepts, 0, "one solo proposal cannot accept native duel")
        b.FD.UI.rated.scripts.OnClick()
        exchange()
        equal(a.FD.duel:State(), "RATED_CONFIRMED", "logged solo challenger requires mutual explicit consent")
        equal(b.FD.duel:State(), "RATED_CONFIRMED", "logged solo recipient requires mutual explicit consent")
        equal(b.accepts, 1, "duplicate logged consent accepts native duel exactly once")
        a:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
        b:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
        exchange()
        a:advance(1.1); b:advance(1.1)
        equal(a.FD.duel:State(), "IN_PROGRESS", "logged route still requires native countdown evidence")
        equal(b.FD.duel:State(), "IN_PROGRESS", "logged peer still requires native countdown evidence")
        a:emit("CHAT_MSG_SYSTEM", "Alpha Example has defeated Beta Example in a duel")
        a:emit("DUEL_FINISHED")
        b:emit("DUEL_FINISHED")
        b:emit("CHAT_MSG_SYSTEM", "Alpha Example has defeated Beta Example in a duel")
        exchange()
        equal(#a.FD.Database.data.matches, 1, "logged solo winner commits one native-verified rated result")
        equal(#b.FD.Database.data.matches, 1, "logged solo loser commits one native-verified rated result")
        equal(a.FD.Database:GetStats().rating, 1516, "logged result updates solo winner rating")
        equal(b.FD.Database:GetStats().rating, 1484, "logged result updates solo loser rating")
        local result
        for _, sent in ipairs(a.sent) do
            if sent.prefix == a.FD.C.PREFIX and a.FD.Protocol:Decode(sent.payload).kind == "RESULT" then result = sent end
        end
        equal(result.logged, true, "finalized result drains through request's proven logged route")
        a.FD.Comms:Send(result.payload, "Beta Example", originalA)
        a:advance(0.2)
        equal(a.sent[#a.sent].logged, true, "finalized result retains own match's proven route")
        equal(#a.FD.Database.data.matches, 1, "logged duplicate result cannot duplicate history")
        a:incoming("Beta Example")
        b.env.StartDuel("target"); b:emit("CHAT_MSG_SYSTEM", b.env.ERR_DUEL_REQUESTED)
        equal(a.FD.duel.active ~= originalA, true, "new native request gets a distinct match object")
        equal(a.FD.duel.active.loggedRoute, nil, "new native request cannot inherit previous proven logged route")
        equal(b.FD.duel.active ~= originalB, true, "opposite client also receives a fresh request object")
    end

    do
        local a, b, exchange, counts = loggedPair({ allowNormal = true })
        exchange(7)
        equal(a.FD.duel:State(), "READY", "prompt ordinary whisper remains primary")
        equal(b.FD.duel:State(), "READY", "prompt primary route confirms both clients")
        equal(counts.loggedHello, 0, "primary early confirmation prevents optional probe")
        equal(a.FD.duel.active.loggedRoute, nil, "ordinary proof does not claim logged proof")
    end

    do
        local a, b, exchange, counts = loggedPair({ dropLogged = true })
        exchange(9)
        equal(counts.loggedHello, 2, "lost optional probes are bounded to one per client")
        equal(a.FD.duel:State(), "DISCOVERY_WAIT", "lost logged probe leaves ordinary challenger negotiation active")
        equal(b.FD.duel:State(), "DISCOVERY_WAIT", "lost logged probe leaves ordinary recipient negotiation active")
        equal(a.FD.duel.active.peerNonce, nil, "lost logged submission cannot prove peer session")
        equal(a.accepts + b.accepts, 0, "lost probe never implies native acceptance")
        exchange(42)
        equal(a.FD.duel:State(), "IDLE", "lost alternate route cannot extend native pending deadline")
        equal(b.FD.duel:State(), "IDLE", "recipient keeps existing native pending deadline")
        equal(#a.FD.Database.data.matches + #b.FD.Database.data.matches, 0, "lost alternate route creates no history")
    end

    for _, failure in ipairs({ "rejected", "error", "restricted", "nil" }) do
        local state = client({ logged = true })
        if failure == "rejected" then state.loggedResult = 4
        elseif failure == "error" then state.loggedError = true
        elseif failure == "restricted" then state.loggedResult = state.secret
        else state.loggedResult = nil end
        state:incoming(); state:advance(6)
        equal(state.loggedCalls, 1, failure .. " optional probe is attempted only once")
        equal(state.FD.duel:State(), "DISCOVERY_WAIT", failure .. " optional probe does not unrate ordinary request")
        equal(state.FD.duel.active.peerNonce, nil, failure .. " optional probe never infers receipt")
        equal(state.FD.duel.active.loggedRoute, nil, failure .. " optional probe never learns a route")
        equal(state.accepts, 0, failure .. " optional probe cannot grant native consent")
        equal(#state.FD.Database.data.matches, 0, failure .. " optional probe cannot create history")
        equal(state.FD.Comms.loggedStatusMatch, state.FD.duel.active, failure .. " probe diagnosis is request-bound")
    end

    for _, registration in ipairs({ false, "error" }) do
        local state = client({ logged = true, loggedRegistration = registration })
        state:incoming(); state:advance(6)
        equal(state.FD.Comms.loggedReceiveAvailable, false, "unavailable logged event registration disables optional route")
        equal(state.loggedCalls, nil, "unregistered logged event never sends a probe")
        equal(state.FD.duel:State(), "DISCOVERY_WAIT", "unsupported optional event preserves ordinary negotiation")
        state.FD.Comms:Receive(state.FD.C.PREFIX, opponentHello(state), "WHISPER", "Beta", true)
        equal(state.FD.duel.active.peerNonce, nil, "unregistered optional event cannot prove peer")
    end

    do
        local a, b, exchange, counts = loggedPair({ peerAPI = false, normalACK = true })
        exchange(7)
        equal(a.FD.duel:State(), "READY", "mixed API peers can confirm using ordinary ACK")
        equal(b.FD.duel:State(), "READY", "peer lacking optional send API retains ordinary reply")
        equal(counts.loggedHello, 1, "only capable client sends a probe")
        equal(a.FD.duel.active.loggedRoute, nil, "ordinary reply to logged probe does not prove logged ACK receipt")
        equal(b.FD.duel.active.loggedRoute, nil, "peer lacking logged API cannot claim a proven logged route")
    end

    do
        local state = client({ logged = true })
        state:incoming()
        state:emit("CHAT_MSG_ADDON", state.FD.C.PREFIX, opponentHello(state), "WHISPER", "Beta", true)
        state:advance(0.2)
        equal(state.sent[#state.sent].logged, nil, "ordinary event's fifth native field is never interpreted as logged event")
        equal(state.FD.duel.active.loggedRoute, nil, "ordinary fifth event argument cannot promote logged route")
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, opponentHello(state), "PARTY", "Beta")
        equal(state.FD.Comms.lastReceive:find("LOGGED", 1, true), nil, "optional event never borrows PARTY route")
    end

    do
        local state = client({ logged = true })
        state:incoming()
        local match = state.FD.duel.active
        local hello = opponentHello(state)
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, hello, "WHISPER", "Beta")
        equal(match.peerNonce, nil, "unbound logged HELLO cannot freeze opponent session")
        equal(match.loggedRoute, nil, "unbound logged HELLO cannot promote transport route")
        equal(state.FD.UI.rated.enabled, false, "unbound logged HELLO cannot enable rated consent")
        state:advance(0.4)
        local reply = state.sent[#state.sent]
        equal(reply.logged, true, "verified logged HELLO receives exactly scoped logged ACK")
        equal(state.FD.Protocol:Decode(reply.payload).echo, "abc-feed", "scoped logged ACK echoes received probe nonce")
        equal(state.FD.Comms.loggedReply, nil, "temporary reply context is cleared after receive")
        local values = assert(state.FD.Protocol:Decode(hello))
        values.kind, values.echo = "HELLO_ACK", match.nonce
        values.guid = "Player-1-00000003"
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, assert(state.FD.Protocol:Encode(values)), "WHISPER", "Beta")
        equal(match.loggedRoute, nil, "wrong native participant cannot promote logged route")
        equal(match.peerNonce, nil, "wrong native participant cannot bind a nonce via logged route")
        values.guid, values.role = match.opponent.guid, match.role
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, assert(state.FD.Protocol:Encode(values)), "WHISPER", "Beta")
        equal(match.loggedRoute, nil, "same-role logged ACK cannot promote route")
        values.role, values.echo = "OUTGOING", "abc-dead"
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, assert(state.FD.Protocol:Encode(values)), "WHISPER", "Beta")
        equal(match.loggedRoute, nil, "logged ACK for another request cannot promote route")
        equal(state.accepts, 0, "unbound and rejected logged traffic never grants native consent")
        equal(#state.FD.Database.data.matches, 0, "unbound and rejected logged traffic never writes history")
        values.echo = match.nonce
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, assert(state.FD.Protocol:Encode(values)), "WHISPER", "Beta")
        equal(match.loggedRoute, true, "valid echoed logged ACK alone can prove alternate route")
        local confirmed = state.FD.Comms.loggedStatus
        state:advance(0.4)
        equal(state.FD.Comms.loggedStatus, confirmed, "reciprocal ACK drain preserves confirmed request-age diagnosis")
        state.FD.duel:Send("HELLO_ACK")
        makeParty(state)
        state:advance(0.2)
        equal(state.sent[#state.sent].channel, "PARTY", "exact native party takes priority over proven logged route")
        equal(state.sent[#state.sent].logged, nil, "preferred PARTY uses normal native addon API")
    end

    do
        local state = client({ logged = true })
        state:incoming(); makeParty(state); state:advance(6)
        equal(state.loggedCalls, nil, "existing exact native party never probes logged whispers")
        equal(state.sent[#state.sent].channel, "PARTY", "pending exact-party discovery retains proven party route")
    end

    do
        local state = client({ logged = true })
        state:incoming(); state:advance(0.2)
        local match = state.FD.duel.active
        local values = assert(state.FD.Protocol:Decode(opponentHello(state)))
        values.kind, values.echo = "HELLO_ACK", match.nonce
        local ack = assert(state.FD.Protocol:Encode(values))
        state:emit("CHAT_MSG_ADDON", state.FD.C.PREFIX, ack, "WHISPER", "Beta")
        equal(match.loggedRoute, nil, "first ordinary ACK learns only ordinary request proof")
        local first = match.firstHelloAt
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, ack, "WHISPER", "Beta")
        equal(match.loggedRoute, true, "later valid logged ACK can prove a second route for same request")
        equal(match.firstHelloAt, first, "later alternate proof retains original first submission time")
        equal(state.FD.Comms.loggedStatus:find("acknowledged via LOGGED", 1, true) ~= nil, true,
            "later logged proof updates request-bound route summary")
        local confirmed = state.FD.Comms.loggedStatus
        state:emit("CHAT_MSG_ADDON", state.FD.C.PREFIX, ack, "WHISPER", "Beta")
        equal(match.loggedRoute, true, "late duplicate ordinary ACK cannot revoke proven logged route")
        equal(state.FD.Comms.loggedStatus, confirmed, "late duplicate ordinary ACK preserves learned-route summary")
        values.guid, values.peerGUID, values.role = match.player.guid, match.opponent.guid, match.role
        values.nonce = match.nonce
        local receive, validation, rejection = state.FD.Comms.lastReceive, state.FD.Comms.lastValidation, state.FD.Comms.lastRejection
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, assert(state.FD.Protocol:Encode(values)), "WHISPER", "Alpha")
        equal(state.FD.Comms.lastReceive, receive, "native own logged echo cannot overwrite peer receipt")
        equal(state.FD.Comms.lastValidation, validation, "native own logged echo cannot overwrite peer proof")
        equal(state.FD.Comms.lastRejection, rejection, "native own logged echo preserves prior rejection status")
        equal(state.accepts, 0, "native own logged echo cannot grant consent")
        equal(#state.FD.Database.data.matches, 0, "native own logged echo cannot create history")
    end

    do
        local state = client({ logged = true })
        state:incoming(); state:advance(4.2)
        local old = state.FD.duel.active
        equal(old.loggedProbeAttempted, true, "probe is queued before cancellation race")
        state.FD.duel:Decline()
        state:incoming()
        local current = state.FD.duel.active
        equal(current ~= old, true, "cancellation creates fresh incoming native context")
        state:advance(0.4)
        equal(state.loggedCalls, nil, "queued probe for cancelled request is never transmitted")
        local staleACK = assert(state.FD.Protocol:Decode(opponentHello(state)))
        staleACK.kind, staleACK.echo = "HELLO_ACK", old.nonce
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, assert(state.FD.Protocol:Encode(staleACK)), "WHISPER", "Beta")
        equal(current.peerNonce, nil, "cancelled request's logged ACK cannot bind fresh same-role request")
        equal(current.loggedRoute, nil, "cancelled request's logged ACK cannot teach fresh route")
        state.FD.duel:Decline(); state:advance(0.6)
        state.env.StartDuel("target"); state:emit("CHAT_MSG_SYSTEM", state.env.ERR_DUEL_REQUESTED)
        current = state.FD.duel.active
        equal(current.role, "OUTGOING", "native request is explicitly reversed for stale-role replay")
        staleACK.echo = current.nonce
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, assert(state.FD.Protocol:Encode(staleACK)), "WHISPER", "Beta")
        equal(current.peerNonce, nil, "opposite old native role cannot bind reversed request even with matching echo")
        equal(current.loggedRoute, nil, "opposite old native role cannot promote reversed request route")
        equal(state.accepts, 0, "cancelled and reversed probes do not infer rated consent")
        equal(#state.FD.Database.data.matches, 0, "cancelled and reversed probes preserve rated history")
    end

    do
        local state = client({ logged = true })
        state:incoming()
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, opponentHello(state), "WHISPER", "Beta")
        state.env.AcceptDuel()
        state:advance(5)
        equal(state.loggedCalls, nil, "queued optional ACK and future probe stop after native acceptance")
        equal(state.FD.duel.active.loggedRoute, nil, "native acceptance cannot retroactively prove logged rated request")
        equal(#state.FD.Database.data.matches, 0, "native ordinary acceptance after probe remains unrated")
    end

    do
        local state = client({ logged = true })
        state:incoming(); state:advance(49.95)
        local hello = opponentHello(state)
        local calls = state.loggedCalls
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, hello, "WHISPER", "Beta")
        state:advance(0.4)
        equal(state.FD.duel:State(), "IDLE", "native pending deadline closes request during queued optional ACK")
        equal(state.loggedCalls, calls, "optional ACK does not drain after native pending deadline")
        state:emit("CHAT_MSG_ADDON_LOGGED", state.FD.C.PREFIX, hello, "WHISPER", "Beta")
        state:advance(0.4)
        equal(state.FD.duel:State(), "IDLE", "late logged probe cannot recreate expired native request")
        equal(state.loggedCalls, calls, "late logged probe outside native request cannot send ACK")
        equal(#state.FD.Database.data.matches, 0, "expired logged traffic cannot write history")
    end

    do
        local state = client()
        state:incoming()
        makeParty(state)
        local fd, match = state.FD, state.FD.duel.active
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, opponentHello(state), "PARTY", "Other-Forever")
        local receive, receivedAt, validation, rejection, peerStatus = fd.Comms.lastReceive, fd.Comms.lastReceiveAt,
            fd.Comms.lastValidation, fd.Comms.lastRejection, match.peerStatus
        local traceSize = #fd.Debug:RequestTrace(64)
        local ownPacket = fd.duel:Packet("HELLO")
        for _, sender in ipairs({ "Alpha-Forever", "Alpha" }) do
            state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, assert(fd.Protocol:Encode(ownPacket)), "PARTY", sender)
        end
        ownPacket.kind, ownPacket.echo = "HELLO_ACK", "cafe"
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, assert(fd.Protocol:Encode(ownPacket)), "PARTY", "Alpha")
        equal(fd.Comms.lastReceive, receive, "verified own party echo preserves last actual peer receive")
        equal(fd.Comms.lastReceiveAt, receivedAt, "verified own party echo preserves peer receive age")
        equal(fd.Comms.lastValidation, validation, "verified own party echo preserves peer validation")
        equal(fd.Comms.lastRejection, rejection, "verified own party echo preserves previous rejection")
        equal(match.peerStatus, peerStatus, "verified own party echo preserves active peer status")
        equal(#fd.Debug:RequestTrace(64), traceSize, "verified own party echo does not add misleading saved diagnostics")
        equal(match.peerNonce, nil, "own hello and acknowledgment cannot prove a peer session")
        equal(state.accepts, 0, "own party echo never grants native consent")
        equal(#fd.Database.data.matches, 0, "own party echo never creates rated history")

        ownPacket.kind, ownPacket.echo = "HELLO", "-"
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, assert(fd.Protocol:Encode(ownPacket)), "PARTY", "Beta-Forever")
        equal(fd.Comms.lastRejection:find("opponent GUID mismatch", 1, true) ~= nil, true,
            "peer sender with own payload GUID is checked rather than silently ignored")
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, opponentHello(state), "PARTY", "Alpha-Forever")
        equal(fd.Comms.lastRejection:find("sender mismatch", 1, true) ~= nil, true,
            "own sender with peer payload GUID is checked rather than silently ignored")
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, assert(fd.Protocol:Encode(ownPacket)), "PARTY", "Alpha-OtherRealm")
        equal(fd.Comms.lastReceive:find("Alpha-OtherRealm", 1, true) ~= nil, true,
            "same own first name on a different realm never qualifies as an echo")
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, assert(fd.Protocol:Encode(ownPacket)), "WHISPER", "Alpha-Forever")
        equal(fd.Comms.lastReceive:find("via WHISPER", 1, true) ~= nil, true,
            "own whisper remains subject to the unchanged sender guards")
    end

    for _, failure in ipairs({
        { "unknown own identity", function(s) s.units.player = nil end },
        { "restricted own GUID", function(s) s.units.player.guid = s.secret end },
        { "restricted own name", function(s) s.units.player.name = s.secret end },
        { "throwing own native identity", function(s)
            local original = s.env.UnitGUID
            s.env.UnitGUID = function(unit)
                if unit == "player" then error("injected own native identity failure") end
                return original(unit)
            end
        end },
    }) do
        local state = client()
        state:incoming()
        makeParty(state)
        local fd, match = state.FD, state.FD.duel.active
        local ownPacket = assert(fd.Protocol:Encode(fd.duel:Packet("HELLO")))
        failure[2](state)
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, ownPacket, "PARTY", "Alpha-Forever")
        equal(fd.Comms.lastReceive:find("Alpha-Forever", 1, true) ~= nil, true,
            failure[1] .. " cannot bypass ordinary receipt diagnostics")
        equal(fd.Comms.lastRejection:find("exact native two-player", 1, true) ~= nil, true,
            failure[1] .. " retains fail-closed native party requirement")
        equal(fd.duel.active, match, failure[1] .. " diagnostic failure cannot abort current request")
        equal(match.peerNonce, nil, failure[1] .. " echo claim cannot bind a peer")
        equal(state.accepts, 0, failure[1] .. " echo claim cannot accept native duel")
        equal(#fd.Database.data.matches, 0, failure[1] .. " echo claim cannot alter history")
    end

    for _, invalid in ipairs({
        { "solo", function(s) s.grouped = false end },
        { "raid", function(s) s.raid = true end },
        { "third member", function(s) s.members = 3 end },
        { "missing group API", function(s) s.env.IsInGroup = nil end },
        { "restricted group", function(s) s.env.IsInGroup = function() return s.secret end end },
        { "restricted size", function(s) s.env.GetNumGroupMembers = function() return s.secret end end },
        { "group API error", function(s) s.env.IsInRaid = function() error("injected native group error") end end },
        { "unknown party unit", function(s) s.units.party1 = nil end },
        { "wrong party GUID", function(s) s.units.party1.guid = "Player-1-00000003" end },
        { "wrong party name", function(s) s.units.party1.name = "Other" end },
        { "changed own GUID", function(s) s.units.player.guid = "Player-1-00000003" end },
        { "restricted party GUID", function(s) s.units.party1.guid = s.secret end },
        { "party identity error", function(s)
            local original = s.env.UnitGUID
            s.env.UnitGUID = function(unit)
                if unit == "party1" then error("injected native party identity error") end
                return original(unit)
            end
        end },
    }) do
        local state = client()
        state:incoming()
        local hello = opponentHello(state)
        makeParty(state)
        invalid[2](state)
        equal(state.FD.Comms:ExactDuelParty(state.FD.duel.active), false, invalid[1] .. " excludes PARTY route")
        state:emit("CHAT_MSG_ADDON", state.FD.C.PREFIX, hello, "PARTY", "Beta-Forever")
        equal(state.FD.duel.active.peerNonce, nil, invalid[1] .. " PARTY receipt cannot bind nonce")
        equal(state.FD.Comms.lastRejection:find("exact native two-player", 1, true) ~= nil, true,
            invalid[1] .. " PARTY receipt explains native group requirement")
        equal(state.accepts, 0, invalid[1] .. " PARTY receipt never accepts native duel")
        equal(#state.FD.Database.data.matches, 0, invalid[1] .. " PARTY receipt never writes history")
        state:advance(0.25)
        local routed
        for _, sent in ipairs(state.sent) do if sent.prefix == state.FD.C.PREFIX then routed = sent end end
        equal(routed.channel, "WHISPER", invalid[1] .. " send falls back to ordinary whisper")
        equal(routed.target, "Beta-Forever", invalid[1] .. " whisper fallback retains exact opponent")
    end

    do
        local state = client()
        state:incoming()
        makeParty(state)
        equal(state.FD.Comms:ExactDuelParty(state.FD.duel.active), true, "native exact two-player party qualifies")
        state:emit("CHAT_MSG_ADDON", state.FD.C.PREFIX, opponentHello(state), "PARTY", "Other-Forever")
        equal(state.FD.Comms.lastRejection:find("sender mismatch", 1, true) ~= nil, true,
            "third-party sender cannot borrow the legitimate duel party")
        equal(state.FD.duel.active.peerNonce, nil, "outside sender cannot confirm native request")
        local mismatched = assert(state.FD.Protocol:Decode(opponentHello(state)))
        mismatched.peerGUID = "Player-1-00000003"
        state:emit("CHAT_MSG_ADDON", state.FD.C.PREFIX, assert(state.FD.Protocol:Encode(mismatched)), "PARTY", "Beta-Forever")
        equal(state.FD.Comms.lastRejection:find("local GUID mismatch", 1, true) ~= nil, true,
            "legitimate native party still requires packet participant GUIDs")
        equal(state.FD.duel.active.peerNonce, nil, "party membership cannot replace participant identity proof")
        state.members = 3
        state:advance(0.25)
        equal(state.sent[#state.sent].channel, "WHISPER", "membership rechecked when queued HELLO drains")
        state.members = 2
        state.FD.duel:Send("HELLO")
        state:advance(0.25)
        equal(state.sent[#state.sent].channel, "PARTY", "later drain uses restored exact native party")
        equal(state.sent[#state.sent].target, nil, "native PARTY send does not use whisper target")
        equal(state.FD.Comms.lastSend:find("via PARTY", 1, true) ~= nil, true, "send diagnosis names actual route")
        local match = state.FD.duel.active
        state.FD.Comms:Send(assert(state.FD.Protocol:Encode(state.FD.duel:Packet("HELLO"))), "Other-Forever", match)
        state:advance(0.25)
        equal(state.sent[#state.sent].channel, "WHISPER", "unrelated queued target cannot inherit duel party")
        equal(state.sent[#state.sent].target, "Other-Forever", "explicit unrelated target remains an isolated whisper")
    end

    for _, outcome in ipairs({
        { name = "unsupported PARTY", result = 4, fallback = true, disabled = true },
        { name = "group lost during native send", result = 5, fallback = true, changed = true },
        { name = "PARTY throttle", result = 3 },
        { name = "PARTY general error", result = 9 },
        { name = "PARTY unknown result", result = 99 },
        { name = "PARTY restricted result", restricted = true },
        { name = "PARTY native exception", throws = true },
        { name = "successful submission followed by group loss", result = 0, changed = true, success = true },
    }) do
        local state = client()
        state:incoming()
        makeParty(state)
        local original = state.env.C_ChatInfo.SendAddonMessage
        local partyResult = outcome.restricted and state.secret or outcome.result or 0
        state.env.C_ChatInfo.SendAddonMessage = function(prefix, payload, channel, target)
            local before = state.sendResult
            state.sendResult = channel == "PARTY" and partyResult or 0
            local result = original(prefix, payload, channel, target)
            state.sendResult = before
            if channel == "PARTY" and outcome.changed then state.grouped, state.members = false, 0 end
            if channel == "PARTY" and outcome.throws then error("injected native send exception") end
            return result
        end
        state:advance(0.25)
        local attempts = {}
        for _, sent in ipairs(state.sent) do if sent.prefix == state.FD.C.PREFIX then attempts[#attempts + 1] = sent end end
        equal(attempts[1].channel, "PARTY", outcome.name .. " initially verifies native two-player route")
        equal(#attempts, outcome.fallback and 2 or 1, outcome.name .. " only explicit routing rejection allows one fallback")
        if outcome.fallback then
            equal(attempts[2].channel, "WHISPER", outcome.name .. " attempts legacy route once")
            equal(attempts[2].target, "Beta-Forever", outcome.name .. " fallback targets exact opponent")
            equal(state.FD.Comms.lastSend:find("PARTY rejected", 1, true) ~= nil, true,
                outcome.name .. " fallback diagnosis retains original routing rejection")
        end
        equal(state.FD.Comms.partyUnavailable, outcome.disabled == true,
            outcome.name .. " only unsupported native chat type disables later PARTY sends")
        equal(state.FD.duel:State(), (outcome.fallback or outcome.success) and "CHECKING_ADDON" or "UNRATED",
            outcome.name .. " submission failure never supplies a peer acknowledgment")
        equal(state.FD.duel.active.peerNonce, nil, outcome.name .. " no result implies current request proof")
        equal(state.accepts, 0, outcome.name .. " no route result accepts native duel")
        equal(#state.FD.Database.data.matches, 0, outcome.name .. " no route result writes rated history")
        if outcome.fallback then
            makeParty(state)
            partyResult = 0
            state.FD.duel:Send("HELLO")
            state:advance(0.25)
            equal(state.sent[#state.sent].channel, outcome.disabled and "WHISPER" or "PARTY",
                outcome.name .. " later route respects unsupported flag or recovered membership")
        end
    end

    do
        local alpha = { guid = "Player-1-00000001", name = "Alpha", surname = "Example", realm = "Forever", classFile = "MAGE" }
        local beta = { guid = "Player-1-00000002", name = "Beta", surname = "Example", realm = "Forever", classFile = "ROGUE" }
        local a = client({ regionalNames = true, units = { player = alpha, target = beta, party1 = beta } })
        local b = client({ regionalNames = true, units = { player = beta, target = alpha, party1 = alpha } })
        a.grouped, a.members, b.grouped, b.members = true, 2, true, 2
        a.env.StartDuel("target")
        a:emit("CHAT_MSG_SYSTEM", a.env.ERR_DUEL_REQUESTED)
        b:incoming("Alpha Example")
        local originalA = a.FD.duel.active
        local deliveredA, deliveredB, whisperDrops = 0, 0, 0
        local function exchange()
            for _ = 1, 10 do
                a:advance(0.2); b:advance(0.2)
                for _, transfer in ipairs({ { from = a, to = b, name = "Alpha Example" },
                    { from = b, to = a, name = "Beta Example" } }) do
                    local previous = transfer.from == a and deliveredA or deliveredB
                    for index = previous + 1, #transfer.from.sent do
                        local sent = transfer.from.sent[index]
                        if sent.prefix == a.FD.C.PREFIX then
                            if sent.channel == "PARTY" then
                                transfer.to:emit("CHAT_MSG_ADDON", sent.prefix, sent.payload, "PARTY", transfer.name)
                                transfer.to:emit("CHAT_MSG_ADDON", sent.prefix, sent.payload, "PARTY", transfer.name)
                                transfer.from:emit("CHAT_MSG_ADDON", sent.prefix, sent.payload, "PARTY", transfer.name)
                            elseif sent.channel == "WHISPER" then whisperDrops = whisperDrops + 1 end
                        end
                    end
                    if transfer.from == a then deliveredA = #a.sent else deliveredB = #b.sent end
                end
            end
        end
        exchange()
        equal(a.FD.duel:State(), "READY", "real PARTY sender completes strict handshake")
        equal(b.FD.duel:State(), "READY", "real PARTY receiver completes strict handshake")
        equal(a.accepts + b.accepts, 0, "native party discovery and duplicates never imply consent")
        equal(a.FD.Comms.lastRejection, nil, "native surname PARTY echo does not overwrite challenger peer status")
        equal(b.FD.Comms.lastRejection, nil, "native surname PARTY echo does not overwrite receiver peer status")
        equal(a.FD.Comms.lastReceive:find("via PARTY", 1, true) ~= nil, true, "receive diagnosis names actual route")
        a.FD.UI.rated.scripts.OnClick()
        exchange()
        equal(b.FD.duel:State(), "REMOTE_ACCEPTED", "PARTY carries only explicit local rated proposal")
        equal(b.accepts, 0, "one party user's consent cannot accept native duel")
        b.FD.UI.rated.scripts.OnClick()
        exchange()
        equal(a.FD.duel:State(), "RATED_CONFIRMED", "party challenger reaches mutual rated agreement")
        equal(b.FD.duel:State(), "RATED_CONFIRMED", "party receiver reaches mutual rated agreement")
        equal(b.accepts, 1, "duplicate party consent packets accept native duel only once")
        a:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
        b:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
        exchange()
        a:advance(1.1); b:advance(1.1)
        equal(a.FD.duel:State(), "IN_PROGRESS", "party match still needs native countdown")
        equal(b.FD.duel:State(), "IN_PROGRESS", "party peer still needs native countdown")
        a:emit("CHAT_MSG_SYSTEM", "Alpha Example has defeated Beta Example in a duel")
        a:emit("DUEL_FINISHED")
        b:emit("DUEL_FINISHED")
        b:emit("CHAT_MSG_SYSTEM", "Alpha Example has defeated Beta Example in a duel")
        exchange()
        equal(#a.FD.Database.data.matches, 1, "native party winner commits one rated result")
        equal(#b.FD.Database.data.matches, 1, "native party loser commits one rated result")
        equal(a.FD.Database:GetStats().rating, 1516, "party native result updates winner rating")
        equal(b.FD.Database:GetStats().rating, 1484, "party native result updates loser rating")
        equal(whisperDrops, 0, "complete exact-party duel does not depend on whisper delivery")
        local finalized = a.FD.Copy(a.FD.Database.data.matches[1])
        local lastResult
        for _, sent in ipairs(a.sent) do
            if sent.prefix == a.FD.C.PREFIX and a.FD.Protocol:Decode(sent.payload).kind == "RESULT" then lastResult = sent end
        end
        equal(lastResult.channel, "PARTY", "final result uses exact native party")
        equal(a.FD.Comms.lastValidation:find("no pending native request", 1, true) ~= nil, true,
            "duplicate party result after finish cannot resurrect the duel")
        equal(a.FD.Database.data.matches[1].matchId, finalized.matchId, "duplicate party result preserves finalized history")
        a.FD.Comms:Send(lastResult.payload, "Beta Example", originalA)
        a:advance(0.25)
        equal(a.sent[#a.sent].channel, "PARTY", "finalized RESULT drains through still-owned exact native party")
        a.FD.Comms:Send(lastResult.payload, "Beta Example", originalA)
        a.grouped, a.members = false, 0
        a:advance(0.25)
        equal(a.sent[#a.sent].channel, "WHISPER", "finalized RESULT rechecks group loss at drain")
        equal(a.sent[#a.sent].target, "Beta Example", "finalized result fallback remains bound to original opponent")
        equal(#a.FD.Database.data.matches, 1, "finalized result route changes never duplicate rated history")
    end

    do
        local state = client()
        state:incoming()
        local fd, match = state.FD, state.FD.duel.active
        local values = { kind = "HELLO", nonce = "feed-abc", echo = "-", guid = match.opponent.guid,
            peerGUID = match.player.guid, role = "INCOMING", rating = 1500, specId = 0,
            classFile = match.opponent.classFile, wins = 0, losses = 0, level = match.opponent.level,
            maxLevel = match.opponent.maxLevel, verdict = "-" }
        local function deliver(sender)
            state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, assert(fd.Protocol:Encode(values)), "WHISPER", sender or "Beta")
        end
        local prints = #state.prints
        deliver()
        equal(fd.Comms.lastValidation:find("roles are not complementary", 1, true) ~= nil, true,
            "actual transport explains same-role peer rejection")
        local rejection = fd.Comms.lastRejection
        equal(fd.duel.active.peerStatus, rejection, "transport and active request show the same cause")
        equal(#state.prints, prints, "debug-off rejection does not add chat spam")
        equal(fd.Debug:RequestTrace(1)[1].event, "peer validation", "rejection survives reload with debug disabled")
        equal(rejection:find(match.nonce, 1, true), nil, "transport diagnostic excludes local nonce")
        equal(rejection:find(values.nonce, 1, true), nil, "transport diagnostic excludes received nonce")
        fd.duel:Decline()
        deliver()
        equal(fd.Comms.lastValidation:find("no pending native request", 1, true) ~= nil, true,
            "retry after decline classified as no pending native request")
        equal(fd.Comms.lastRejection, rejection, "manual decline and subsequent retry preserve original rejection")
        state:incoming()
        values.role = "OUTGOING"
        deliver()
        equal(fd.Comms.lastRejection, nil, "a new valid request clears prior request rejection")
        equal(fd.Comms.lastValidation:find("acknowledgment queued", 1, true) ~= nil, true,
            "transport reports verified native peer reply was queued")
        equal(fd.duel.active.peerNonce, nil, "transport diagnostics never confer nonce proof")
        equal(state.accepts, 0, "transport diagnostics never accept the native duel")
        equal(#fd.Database.data.matches, 0, "transport diagnostics leave rated history unchanged")

        values.role = "OUTGOING"
        deliver("Other")
        equal(fd.Comms.lastRejection:find("sender mismatch", 1, true) ~= nil, true,
            "normalized sender mismatch retains a specific rejection")
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, "malformed", "WHISPER", "Beta")
        equal(fd.Comms.lastRejection:find("invalid envelope", 1, true) ~= nil, true,
            "invalid envelope is distinguishable from identity mismatch")
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
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_CANCELLED)
    c.env.StartDuel("target")
    equal(c.FD.duel.active, nil, "StartDuel attempt alone does not open rated session")
    c.units.target = { guid = "Player-1-00000003", name = "Gamma", realm = "Forever", classFile = "WARRIOR" }
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active.opponent.guid, "Player-1-00000002", "ack binds captured identity despite target change")
    equal(c.FD.duel.active.role, "OUTGOING", "ack creates correct duel role")

    c = client()
    c.env.StartDuel("")
    equal(c.FD.Wow.outgoing.opponent.guid, "Player-1-00000002", "empty native slash duel captures its default target")
    equal(c.FD.Wow.outgoingArgument, "string:", "diagnostic preserves actual empty argument rather than inferred token")
    equal(c.FD.duel.active, nil, "empty slash default remains only an unconfirmed attempt")
    c.units.target = { guid = "Player-1-00000003", name = "Gamma", realm = "Forever", classFile = "WARRIOR" }
    c:emit("UI_INFO_MESSAGE", 123, c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active.opponent.guid, "Player-1-00000002", "default-target capture frozen before later target changes")
    c = client()
    c.units.target = nil
    c.env.StartDuel("")
    equal(c.FD.Wow.outgoing, nil, "empty slash without a native target cannot create a request capture")
    c:emit("UI_INFO_MESSAGE", 123, c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "empty slash without identity remains ordinary despite unqualified native ack")
    c = client()
    c.env.StartDuel(nil)
    equal(c.FD.Wow.outgoing, nil, "unverified nil argument is not equated with an empty native slash command")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_CANCELLED)
    c.env.StartDuel("missing")
    equal(c.FD.Wow.outgoing, nil, "unresolved nonempty input never gets default-target semantics")
    equal(c.FD.Wow.outgoingStatus:find("unitargument=string:missing", 1, true) ~= nil, true,
        "capture failure diagnosis retains bounded readable native argument")
    equal(c.FD.Wow.outgoingStatus:find("native player GUID unavailable", 1, true) ~= nil, true,
        "capture failure diagnosis identifies its native API prerequisite")
    c.messageInfo = { [701] = "ERR_DUEL_REQUESTED" }
    c:emit("UI_INFO_MESSAGE", 701, "Request sent, but capture failed.")
    equal(c.FD.duel.active, nil, "diagnosed native ack still cannot authorize missing candidate")
    local diagnostic = c.FD.Debug:RequestTrace(1)[1]
    equal(diagnostic.event, "UI_INFO_MESSAGE", "native notice retained with debug off after failed capture")
    equal(diagnostic.detail:find("ERR_DUEL_REQUESTED", 1, true) ~= nil, true,
        "native notice diagnosis contains reliable mapped error name")

    -- Every native attempt that cannot be associated with an exact identity
    -- can still have an outstanding server acknowledgment. A later readable
    -- target must not acquire rated or venue state from the first notice.
    for _, failure in ipairs({
        { "missing identity", function(state) return "missing" end },
        { "restricted argument", function(state) return state.secret end },
        { "nil argument", function() return nil end },
        { "ambiguous name", function(state)
            state.units.focus = { guid = "Player-1-00000003", name = "Beta", realm = "Other", classFile = "MAGE" }
            return "Beta"
        end },
        { "restricted identity", function(state) state.units.target.guid = state.secret; return "target" end },
        { "native combat", function(state) state.combat = true; return "target" end },
    }) do
        local failed = client()
        failed.env.StartDuel(failure[2](failed))
        local reason, firstDeadline = failed.FD.Wow.outgoingStatus, failed.FD.Wow.outgoingBlockedUntil
        equal(type(reason), "string", failure[1] .. " retains original capture failure diagnosis")
        equal(firstDeadline, failed.now + failed.FD.C.OUTGOING_TIMEOUT, failure[1] .. " quarantines native attempt")
        equal(failed.FD.Wow.outgoing, nil, failure[1] .. " keeps no candidate that can consume an acknowledgment")
        failed.units.target = { guid = "Player-1-00000004", name = "Gamma", realm = "Forever", classFile = "WARRIOR" }
        failed.combat = false
        failed:advance(1)
        failed.env.StartDuel("target")
        equal(failed.FD.Wow.outgoing, nil, failure[1] .. " refuses to bind the second request during ambiguity window")
        failed.messageInfo = { [701] = "ERR_DUEL_REQUESTED" }
        failed:emit("UI_INFO_MESSAGE", 701, "Delayed request acknowledgment from first attempt.")
        equal(failed.FD.duel.active, nil, failure[1] .. " late native notice cannot create a rated context for Gamma")
        equal(failed.FD.QueueWow.venueTestPending, nil, failure[1] .. " late native notice cannot create a venue test context")
        equal(failed.FD.Wow.outgoingBlockedUntil, failed.now + failed.FD.C.OUTGOING_TIMEOUT,
            failure[1] .. " second native attempt receives its own ambiguity window")
        failed:advance(failed.FD.C.OUTGOING_TIMEOUT + 0.01)
        failed.env.StartDuel("target")
        equal(failed.FD.Wow.outgoing.opponent.guid, "Player-1-00000004", failure[1] .. " fresh retry after expiry captures exact Gamma")
        equal(failed.FD.duel.active, nil, failure[1] .. " retry still requires its own native notice")
        failed:emit("UI_INFO_MESSAGE", 701, "Fresh native request acknowledgment.")
        equal(failed.FD.duel.active.opponent.guid, "Player-1-00000004", failure[1] .. " freshly acknowledged retry starts correct context")
    end

    for _, ending in ipairs({
        { "native cancelled", function(state) state:emit("CHAT_MSG_SYSTEM", state.env.ERR_DUEL_CANCELLED) end },
        { "native countdown", function(state) state:emit("CHAT_MSG_SYSTEM", "Duel starting: 3") end },
        { "native finished", function(state) state:emit("DUEL_FINISHED") end },
    }) do
        local failed = client()
        failed.env.StartDuel("missing")
        failed:advance(1)
        ending[2](failed)
        equal(failed.FD.Wow.outgoingBlockedUntil, nil, ending[1] .. " authoritatively releases failed-attempt quarantine")
        failed.env.StartDuel("target")
        equal(failed.FD.Wow.outgoing ~= nil, true, ending[1] .. " allows new exact native request immediately")
    end

    -- Blizzard's secure /duel handler passes its explicit name, rather than a
    -- unit token. Native UnitGUID(name) can be unavailable while party1 is an
    -- exact readable source for that same full surname identity.
    local namedOwn = { guid = "Player-1-00000001", name = "Alpha", surname = "Example", classFile = "MAGE" }
    local namedPeer = { guid = "Player-1-00000002", name = "Beta", surname = "Brave", classFile = "ROGUE" }
    c = client({ regionalNames = true, units = { player = namedOwn, party1 = namedPeer } })
    c.env.StartDuel("Beta Brave")
    equal(c.FD.Wow.outgoing.opponent.guid, namedPeer.guid, "explicit full surname capture resolved from native party unit")
    equal(c.FD.duel.active, nil, "resolved name still requires a native request acknowledgment")
    c:advance(5)
    equal(c.FD.Wow.outgoing ~= nil, true, "native capture survives the four second addon discovery UI timeout")
    c.messageInfo = { [701] = "ERR_DUEL_REQUESTED", [702] = "ERR_DUEL_CANCELLED" }
    c:emit("UI_INFO_MESSAGE", 701, "Request sent to Beta Brave.")
    equal(c.FD.duel:State(), "CHECKING_ADDON", "native mapped notice identifies request despite formatted text")
    equal(c.FD.duel.active.opponent.guid, namedPeer.guid, "typed request acknowledgment retains exact captured GUID")
    equal(c.FD.duel.active.createdAt, 0, "delayed acknowledgment does not restart native request deadline")
    equal(c.FD.duel.active.localAccepted, nil, "native request notice never grants rated consent")
    equal(c.accepts, 0, "mapped notice does not accept the native duel")
    c:emit("UI_ERROR_MESSAGE", 702, "Formatted cancel notice.")
    equal(c.FD.duel.active, nil, "native mapped cancel ends the same request without text matching")
    equal(c.FD.Wow.outgoingBlockedUntil, nil, "native mapped cancellation releases ambiguity quarantine")

    c = client({ regionalNames = true, units = { player = namedOwn, party1 = namedPeer,
        focus = { guid = "Player-1-00000003", name = "Beta", surname = "Other", classFile = "MAGE" } } })
    c.env.StartDuel("Beta")
    equal(c.FD.Wow.outgoing, nil, "ambiguous explicit first name cannot select a nearby GUID")
    c:emit("UI_INFO_MESSAGE", 701, c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "acknowledgment cannot recover an ambiguous named capture")

    for _, noticeEvent in ipairs({ "UI_INFO_MESSAGE", "UI_ERROR_MESSAGE" }) do
        c = client()
        c.messageInfo = { [701] = "ERR_DUEL_REQUESTED", [703] = "ERR_PLAYER_BUSY" }
        c:emit(noticeEvent, 701, "Native formatted request")
        equal(c.FD.duel.active, nil, "mapped native ID without capture cannot infer an opponent")
        c.env.StartDuel("target")
        c:emit(noticeEvent, 703, "Native formatted request")
        equal(c.FD.duel.active, nil, "unrelated native message ID cannot acknowledge a duel")
        local infoCalls = c.messageInfoCalls
        c:emit(noticeEvent, c.secret, "Native formatted request")
        equal(c.messageInfoCalls, infoCalls, "restricted native message ID never reaches mapping API")
        equal(c.FD.duel.active, nil, "restricted mapped message cannot grant request evidence")
        c.messageInfo = { [701] = c.secret }
        c:emit(noticeEvent, 701, "Native formatted request")
        equal(c.FD.duel.active, nil, "restricted native message name ignored")
        c.messageInfoError = true
        c:emit(noticeEvent, 701, "Native formatted request")
        equal(c.FD.duel.active, nil, "native mapping exception leaves ordinary request intact")
        equal(c.FD.Wow.outgoing ~= nil, true, "mapping exception does not discard safe pending capture")
        c.messageInfoError = false; c.messageInfo = { [701] = "ERR_DUEL_REQUESTED" }
        c:emit(noticeEvent, 701, "Native formatted request")
        equal(c.FD.duel:State(), "CHECKING_ADDON", "verified native mapped ID eventually acknowledges exact capture")
        local parserCalls = 0
        c.FD.Results.Countdown = function() parserCalls = parserCalls + 1 end
        c.FD.Results.Parse = function() parserCalls = parserCalls + 1 end
        c:emit(noticeEvent, 701, "Duel starting: 3")
        equal(parserCalls, 0, "mapped info notification cannot supply countdown or result evidence")
    end

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
        c:advance(c.FD.C.OUTGOING_TIMEOUT + 0.01)
        c:emit(noticeEvent, 123, c.env.ERR_DUEL_REQUESTED)
        equal(c.FD.duel.active, nil, noticeEvent .. " cannot revive expired attempt")
    end

    c = client()
    c.env.StartDuel("target")
    c:advance(c.FD.C.OUTGOING_TIMEOUT + 0.01)
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "expired outgoing candidate cannot be revived")
    c = client()
    c.env.StartDuel("target")
    c.units.mouseover = { guid = "Player-1-00000003", name = "Gamma", realm = "Forever", classFile = "WARRIOR" }
    c.env.StartDuel("mouseover")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "overlapping attempts make unqualified acknowledgement ambiguous")

    -- Retain useful request diagnostics when debug is disabled. A missing
    -- challenger dialog must remain diagnosable after its native request window
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
    c:advance(c.FD.C.OUTGOING_TIMEOUT + 0.01)
    equal(c.FD.Wow.outgoing, nil, "expired capture no longer authorizes native acknowledgment")
    local expiredStatus, expiredAt = c.FD.Wow.outgoingStatus, c.FD.Wow.outgoingAt
    equal(type(expiredStatus), "string", "capture expiry remains diagnosable without debug")
    equal(expiredStatus ~= capturedStatus, true, "expiry status distinguishes capture from failure")
    equal(expiredAt, c.FD.C.OUTGOING_TIMEOUT, "expiry diagnostic records its transition time")
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
    c:advance(c.FD.C.OUTGOING_TIMEOUT + 0.01)
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
                or c.FD.Wow.outgoing.at + c.FD.C.OUTGOING_TIMEOUT
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
                equal(c.FD.Wow.outgoingBlockedUntil, c.now + c.FD.C.OUTGOING_TIMEOUT,
                    ending[1] .. " overlapping retry extends the ambiguity window")
                c:advance(c.FD.C.OUTGOING_TIMEOUT + 0.01)
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
    -- explicit /duel surname, formatted native acknowledgment delayed past
    -- four seconds, and delayed addon delivery must still show both dialogs.
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
    a.env.StartDuel("Tray Taylorr")
    a.messageInfo = { [701] = "ERR_DUEL_REQUESTED" }
    b.units.target = nil
    b:incoming("Alpha Example")
    a:advance(5)
    a:emit("UI_INFO_MESSAGE", 701, "Request sent to Tray Taylorr.")
    equal(a.FD.duel.active.createdAt, 0, "live-order recovery keeps original captured request time")
    a:advance(5)
    b:advance(0.5)
    equal(b.FD.duel.active, nil, "surname receiver initially lacks native challenger identity")
    b.units.target = alpha
    b:advance(9.5)
    equal(b.nativeVisible, false, "surname receiver recovers the pending request with debug off")
    equal(a.FD.duel:State(), "DISCOVERY_WAIT", "outgoing discovery survives delayed delivery")
    equal(b.FD.duel:State(), "DISCOVERY_WAIT", "incoming discovery survives delayed delivery")
    equal(a.FD.UI.frame:IsShown(), true, "outgoing soft timeout keeps the waiting dialog visible")
    equal(a.FD.UI.rated.enabled, false, "visible outgoing waiting dialog cannot grant rated consent")
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
    equal(a.FD.UI.frame:IsShown(), true, "late mapped native acknowledgment ultimately opens challenger addon dialog")
    equal(a.FD.UI.rated.enabled, true, "verified two-client handshake enables challenger rated choice")
    equal(b.FD.UI.rated.enabled, true, "verified two-client handshake enables recipient rated choice")
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
