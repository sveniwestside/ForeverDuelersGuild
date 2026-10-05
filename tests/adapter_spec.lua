return function(_, equal)
    -- Each client loads the real addon into a private Lua 5.1 environment
    -- (tests/duel_client.lua). Fake WoW globals never enter _G.
    local Client = assert(loadfile("tests/duel_client.lua"))()
    local function client(options) return Client.new(options) end

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

    local function opponentHello(state, changes)
        local match = state.FD.duel.active
        local values = { kind = "HELLO", nonce = "abc-feed", echo = "-",
            guid = match.opponent.guid, peerGUID = match.player.guid, role = "OUTGOING", rating = 1500,
            specId = 0, classFile = match.opponent.classFile, wins = 0, losses = 0,
            level = match.opponent.level, maxLevel = match.opponent.maxLevel, verdict = "-" }
        for key, value in pairs(changes or {}) do values[key] = value end
        return assert(state.FD.Protocol:Encode(values))
    end

    local function makeParty(state)
        state.grouped, state.raid, state.members = true, false, 2
        state.units.party1 = state.FD.Copy(state.units.target)
    end

    local function lastRated(state)
        local routed
        for _, sent in ipairs(state.sent) do if sent.prefix == state.FD.C.PREFIX then routed = sent end end
        return routed
    end

    -- The logged-addon route and its ingress probe are gone entirely.
    do
        local c = client()
        equal(c.FD.eventHandlers.CHAT_MSG_ADDON_LOGGED, nil, "no logged addon receive route")
        equal(c.FD.Comms.ScheduleLoggedProbe, nil, "no logged probe")
        c:incoming(); c:advance(6)
        for _, sent in ipairs(c.sent) do equal(sent.logged, nil, "only the ordinary addon API is used") end
        local status = table.concat(c.FD:StatusLines(), "\n")
        equal(status:find("alternate transport", 1, true), nil, "no logged route status line")
        equal(status:find("Queued duel packets", 1, true) ~= nil, true, "queue depth shown instead")
    end

    -- Own PARTY echoes are ignored; everything else keeps the normal guards.
    do
        local state = client()
        state:incoming()
        makeParty(state)
        local fd, match = state.FD, state.FD.duel.active
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, opponentHello(state), "PARTY", "Other-Forever")
        local receive, receivedAt, validation, rejection, peerStatus = fd.Comms.lastReceive, fd.Comms.lastReceiveAt,
            fd.Comms.lastValidation, fd.Comms.lastRejection, match.peerStatus
        local traceSize = #fd.Debug:RequestTrace(64)
        local ownPacket = fd.duel:Packet(match, "HELLO")
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
        local ownPacket = assert(fd.Protocol:Encode(fd.duel:Packet(match, "HELLO")))
        failure[2](state)
        state:emit("CHAT_MSG_ADDON", fd.C.PREFIX, ownPacket, "PARTY", "Alpha-Forever")
        equal(fd.Comms.lastReceive:find("Alpha-Forever", 1, true) ~= nil, true,
            failure[1] .. " cannot bypass ordinary receipt diagnostics")
        equal(fd.Comms.lastRejection:find("sender mismatch", 1, true) ~= nil, true,
            failure[1] .. " is still bound to the opponent's native sender")
        equal(fd.duel.active, match, failure[1] .. " diagnostic failure cannot abort current request")
        equal(match.peerNonce, nil, failure[1] .. " echo claim cannot bind a peer")
        equal(state.accepts, 0, failure[1] .. " echo claim cannot accept native duel")
        equal(#fd.Database.data.matches, 0, failure[1] .. " echo claim cannot alter history")
    end

    -- The receiver's own roster view need not be exact: the server supplies
    -- the PARTY sender and the envelope is still GUID/nonce bound. Sending
    -- keeps the exact-party requirement and falls back to WHISPER.
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
        equal(state.FD.Comms:ExactDuelParty(state.FD.duel.active), false, invalid[1] .. " excludes PARTY sends")
        state:emit("CHAT_MSG_ADDON", state.FD.C.PREFIX, hello, "PARTY", "Beta-Forever")
        equal(state.FD.Comms.lastValidation:find("acknowledgment queued", 1, true) ~= nil, true,
            invalid[1] .. " PARTY receipt from the bound opponent is processed")
        equal(state.FD.duel.active.peerNonce, nil, invalid[1] .. " a HELLO still cannot bind a nonce")
        equal(state.accepts, 0, invalid[1] .. " PARTY receipt never accepts native duel")
        equal(#state.FD.Database.data.matches, 0, invalid[1] .. " PARTY receipt never writes history")
        state:advance(0.25)
        local routed = lastRated(state)
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
        state:emit("CHAT_MSG_ADDON", state.FD.C.PREFIX, opponentHello(state, { peerGUID = "Player-1-00000003" }), "PARTY", "Beta-Forever")
        equal(state.FD.Comms.lastRejection:find("local GUID mismatch", 1, true) ~= nil, true,
            "legitimate native party still requires packet participant GUIDs")
        equal(state.FD.duel.active.peerNonce, nil, "party membership cannot replace participant identity proof")
        state.members = 3
        state:advance(0.25)
        equal(state.sent[1].channel, "WHISPER", "membership rechecked when queued HELLO drains")
        state.members = 2
        local match = state.FD.duel.active
        state.FD.duel:Send(match, "HELLO")
        state:advance(0.25)
        equal(lastRated(state).channel, "PARTY", "later drain uses restored exact native party")
        equal(lastRated(state).target, nil, "native PARTY send does not use whisper target")
        equal(state.FD.Comms.lastSend:find("via PARTY", 1, true) ~= nil, true, "send diagnosis names actual route")
        for _, sent in ipairs(state.sent) do
            if sent.channel == "WHISPER" then equal(sent.target, "Beta-Forever", "rated packets only reach the bound opponent") end
        end
    end

    -- Native send results are classified by FD.Outbound: route errors fall back
    -- to WHISPER, throttles are retried, and a failed redundant HELLO never
    -- unrates.
    for _, outcome in ipairs({
        { name = "unsupported PARTY", result = 4, fallback = true, disabled = true },
        { name = "group lost during native send", result = 5, fallback = true },
        { name = "PARTY throttle", result = 3, retried = true },
        { name = "PARTY general error", result = 9, retried = true },
        { name = "PARTY unknown result", result = 99 },
        { name = "PARTY restricted result", restricted = true },
        { name = "PARTY native exception", throws = true },
        { name = "successful submission followed by group loss", result = 0, changed = true },
    }) do
        local state = client()
        state:incoming()
        makeParty(state)
        local partyResult = outcome.restricted and state.secret or outcome.throws and "error" or outcome.result or 0
        state.sendFilter = function(prefix, payload, channel, target, result)
            if channel ~= "PARTY" then return result end
            if outcome.changed then state.grouped, state.members = false, 0 end
            return partyResult
        end
        state:advance(0.25)
        local attempts = {}
        for _, sent in ipairs(state.sent) do if sent.prefix == state.FD.C.PREFIX then attempts[#attempts + 1] = sent end end
        equal(attempts[1].channel, "PARTY", outcome.name .. " initially verifies native two-player route")
        equal(#attempts, outcome.fallback and 2 or 1, outcome.name .. " only an explicit routing rejection falls back at once")
        if outcome.fallback then
            equal(attempts[2].channel, "WHISPER", outcome.name .. " retries as a whisper")
            equal(attempts[2].target, "Beta-Forever", outcome.name .. " fallback targets exact opponent")
        end
        equal(state.FD.Outbound.routeUnavailable.PARTY == true, outcome.disabled == true,
            outcome.name .. " only unsupported native chat type disables later PARTY sends")
        if outcome.retried then
            state:advance(3)
            local retries = 0
            for _, sent in ipairs(state.sent) do if sent.channel == "PARTY" then retries = retries + 1 end end
            equal(retries > 1, true, outcome.name .. " is retried with backoff")
        end
        equal(state.FD.duel:State(), "CHECKING_ADDON", outcome.name .. " redundant discovery failure never unrates")
        equal(state.FD.duel.active.peerNonce, nil, outcome.name .. " no result implies current request proof")
        equal(state.accepts, 0, outcome.name .. " no route result accepts native duel")
        equal(#state.FD.Database.data.matches, 0, outcome.name .. " no route result writes rated history")
        if outcome.fallback then
            makeParty(state)
            partyResult = 0
            state.FD.duel:Send(state.FD.duel.active, "HELLO")
            state:advance(0.25)
            equal(lastRated(state).channel, outcome.disabled and "WHISPER" or "PARTY",
                outcome.name .. " later route respects unsupported flag or recovered membership")
        end
    end

    -- A complete grouped rated duel with surname identities over PARTY only.
    do
        local alpha = { guid = "Player-1-00000001", name = "Alpha", surname = "Example", realm = "Forever", classFile = "MAGE" }
        local beta = { guid = "Player-1-00000002", name = "Beta", surname = "Example", realm = "Forever", classFile = "ROGUE" }
        local net = Client.pair({ regionalNames = true, alpha = alpha, beta = beta, latency = 0.2 })
        local a, b = net.a, net.b
        for _, c in ipairs({ a, b }) do c.grouped, c.members, c.units.party1 = true, 2, c.units.target end
        local whisperDrops = 0
        net.delay = function(entry)
            if entry.sent.channel == "WHISPER" then whisperDrops = whisperDrops + 1; return false end
            return 0.2
        end
        net:nativeCountdown()
        net:challenge(a)
        net:advance(2)
        equal(a.FD.duel:State(), "READY", "real PARTY sender completes strict handshake")
        equal(b.FD.duel:State(), "READY", "real PARTY receiver completes strict handshake")
        equal(a.accepts + b.accepts, 0, "native party discovery and duplicates never imply consent")
        equal(a.FD.Comms.lastRejection, nil, "native surname PARTY echo does not overwrite challenger peer status")
        equal(b.FD.Comms.lastRejection, nil, "native surname PARTY echo does not overwrite receiver peer status")
        equal(a.FD.Comms.lastReceive:find("via PARTY", 1, true) ~= nil, true, "receive diagnosis names actual route")
        a.FD.UI.rated.scripts.OnClick()
        net:advance(1)
        equal(b.FD.duel:State(), "REMOTE_ACCEPTED", "PARTY carries only explicit local rated proposal")
        equal(b.accepts, 0, "one party user's consent cannot accept native duel")
        b.FD.UI.rated.scripts.OnClick()
        equal(b.accepts, 1, "both consents accept the native duel exactly once")
        equal(b.nativeVisible, false, "after its own AcceptDuel the addon hides Blizzard's popup")
        equal(b.hides, 1, "popup hidden once")
        net:advance(1)
        equal(a.FD.duel:State(), "COUNTDOWN", "party challenger observes the native countdown")
        equal(b.FD.duel:State(), "COUNTDOWN", "party receiver observes the native countdown")
        net:advance(3.5)
        equal(a.FD.duel:State(), "IN_PROGRESS", "party match still needs native countdown")
        net:finish(a, b)
        net:advance(2)
        equal(#a.FD.Database.data.matches, 1, "native party winner commits one rated result")
        equal(#b.FD.Database.data.matches, 1, "native party loser commits one rated result")
        equal(a.FD.Database:GetStats().rating, 1516, "party native result updates winner rating")
        equal(b.FD.Database:GetStats().rating, 1484, "party native result updates loser rating")
        equal(whisperDrops, 2, "each client whispered only its first HELLO copy")
        local result
        for _, entry in ipairs(net.log) do if entry.from == a and entry.kind == "RESULT" then result = entry end end
        equal(result.sent.channel, "PARTY", "final result uses exact native party")
        local finalized = a.FD.Database.data.matches[1].matchId
        a:emit("CHAT_MSG_ADDON", a.FD.C.PREFIX, b.sent[#b.sent].payload, "PARTY", b.senderName)
        equal(a.FD.Comms.lastValidation:find("finalized match", 1, true) ~= nil, true,
            "a late party result after finishing is answered from the finalized cache")
        equal(a.FD.Database.data.matches[1].matchId, finalized, "late party result preserves finalized history")
        local original = a.FD.duel.recent[1].match
        a.FD.duel:Send(original, "RESULT", { verdict = original.localWinner })
        a:advance(0.25)
        equal(lastRated(a).channel, "PARTY", "finalized RESULT drains through still-owned exact native party")
        a.FD.duel:Send(original, "RESULT", { verdict = original.localWinner })
        a.grouped, a.members = false, 0
        a:advance(0.25)
        equal(lastRated(a).channel, "WHISPER", "finalized RESULT rechecks group loss at drain")
        equal(lastRated(a).target, "Beta Example", "finalized result fallback remains bound to original opponent")
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
        local saved
        for _, entry in ipairs(fd.Debug:RequestTrace(64, "lifecycle")) do
            if entry.event == "peer validation" then saved = entry end
        end
        equal(saved ~= nil, true, "rejection survives reload with debug disabled")
        equal(rejection:find(match.nonce, 1, true), nil, "transport diagnostic excludes local nonce")
        equal(rejection:find(values.nonce, 1, true), nil, "transport diagnostic excludes received nonce")
        state.env.CancelDuel()
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
    equal(c.FD.duel:State(), "CHECKING_ADDON", "incoming request starts discovery")
    equal(c.FD.UI.frame:IsShown(), false, "nothing is shown before the challenger is proven")
    equal(c.nativeVisible, true, "Blizzard's popup stays the ordinary choice")
    c:advance(1)
    equal(c.hides, 0, "the native popup is never hidden or replaced")
    equal(c.env.StaticPopupDialogs.DUEL_REQUESTED, c.nativeDefinition, "native definition identity preserved")
    equal(c.nativeDefinition.OnAccept, c.nativeAccept, "native accept callback preserved")
    equal(c.nativeDefinition.OnCancel, c.nativeCancel, "native cancel callback preserved")
    equal(c.accepts, 0, "discovery never accepts underlying duel")
    c.env.AcceptDuel()
    equal(c.accepts, 1, "Blizzard's Accept starts the ordinary duel at once")
    equal(c.FD.duel:State(), "UNRATED", "Blizzard's Accept is an unrated choice")
    equal(#c.prints, 0, "an unanswered challenger causes no chat output")
    equal(#c.FD.Database.data.matches, 0, "ordinary acceptance stores no rated match")
    equal(c.FD.Database:GetStats().rating, 1500, "ordinary acceptance leaves rating unchanged")

    for _, timing in ipairs({ "before", "during" }) do
        c = client()
        if timing == "before" then toggleDebugOff(c) end
        c:incoming()
        if timing == "during" then toggleDebugOff(c) end
        c:advance(0.2)
        equal(c.nativeVisible, true, "debug toggled " .. timing .. " request keeps the native popup")
        equal(c.FD.duel:State(), "CHECKING_ADDON", "debug toggle preserves discovery")
        equal(c.FD.Protocol:Decode(c.sent[1].payload).kind, "HELLO", "debug off still sends handshake")
        equal(c.accepts, 0, "debug toggle cannot accept underlying duel")
    end

    c = client()
    toggleDebugOff(c)
    local delayedOpponent = c.units.target
    c.units.target = nil
    local printsBefore = #c.prints
    c:incoming()
    equal(c.FD.duel.active, nil, "unresolved incoming request retains native flow initially")
    equal(c.nativeVisible, true, "unresolved request remains answerable")
    equal(#c.prints, printsBefore, "unknown challenger gets no targeting hint")
    c:advance(2)
    c.units.target = delayedOpponent
    c:advance(0.5)
    equal(c.FD.duel:State(), "CHECKING_ADDON", "late native identity starts discovery with debug disabled")
    equal(c.FD.duel.active.createdAt, 0, "recovered request preserves original native request time")
    equal(c.accepts, 0, "identity recovery requires explicit duel acceptance")
    c:advance(c.FD.C.PENDING_TIMEOUT - c.now)
    equal(c.FD.duel.active, nil, "identity recovery cannot extend the original pending timeout")
    equal(c.nativeVisible, true, "the native popup was never touched")

    c = client()
    c.FD.Presence.FindByName = function(_, name) if name == "Beta-Forever" then return { fullName = name } end end
    c.units.target = nil
    c:incoming()
    equal(#c.prints, 1, "a known addon user gets one targeting hint")
    equal(c.prints[1]:find("target the challenger", 1, true) ~= nil, true, "hint explains the native identity check")

    local stopPending = {
        { "native acceptance", function(state) state.env.AcceptDuel() end },
        { "native decline", function(state) state.env.CancelDuel() end },
        { "native cancellation", function(state) state:emit("CHAT_MSG_SYSTEM", state.env.ERR_DUEL_CANCELLED) end },
        { "countdown", function(state) state:emit("CHAT_MSG_SYSTEM", "Duel starting: 3") end },
        { "finished duel", function(state) state:emit("DUEL_FINISHED") end },
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
        equal(c.FD.UI.frame:IsShown(), false, scenario[1] .. " leaves no stale panel")
        equal(c.hides, 0, scenario[1] .. " does not touch the native flow")
    end

    -- Combat no longer stops native identity resolution or capture; it only
    -- disables the rated button until combat ends.
    c = client()
    delayedOpponent = c.units.target
    c.units.target = nil
    c:incoming()
    c.combat = true
    c:emit("PLAYER_REGEN_DISABLED")
    c.units.target = delayedOpponent
    c:advance(1)
    equal(c.FD.duel:State(), "CHECKING_ADDON", "a request that began in combat still discovers its peer")
    c:emit("CHAT_MSG_ADDON", c.FD.C.PREFIX, opponentHello(c), "WHISPER", "Beta-Forever")
    local ack = assert(c.FD.Protocol:Decode(opponentHello(c)))
    ack.kind, ack.echo = "HELLO_ACK", c.FD.duel.active.nonce
    c:emit("CHAT_MSG_ADDON", c.FD.C.PREFIX, assert(c.FD.Protocol:Encode(ack)), "WHISPER", "Beta-Forever")
    equal(c.FD.duel:State(), "READY", "peer proven during combat")
    equal(c.FD.UI.frame:IsShown(), true, "companion shown")
    equal(c.FD.UI.rated.enabled, false, "rated choice disabled in combat")
    equal(c.FD.UI.body.text:find("Leave combat", 1, true) ~= nil, true, "combat hint visible")
    c.combat = false
    c:emit("PLAYER_REGEN_ENABLED")
    equal(c.FD.UI.rated.enabled, true, "leaving combat re-enables the rated choice")
    equal(c.FD.UI.frame.points[1][2], c.popupFrame, "companion anchored below Blizzard's visible popup")

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
    equal(c.FD.duel.active.nativeAccepted, true, "external acceptance is final")
    equal(c.FD.UI.frame:IsShown(), false, "external acceptance leaves no panel")
    c:advance(c.FD.C.PENDING_TIMEOUT)
    equal(c.FD.Database:GetStats().rating, 1500, "external acceptance cannot retroactively rate")

    c = client()
    c:incoming()
    c:incoming("Unknown")
    c:advance(0)
    equal(c.nativeVisible, true, "a newer unknown request stays visible")
    equal(c.FD.duel.active, nil, "unknown incoming identity creates no session")
    equal(c.hides, 0, "no suppression side effect")

    c = client()
    c:incoming()
    c:advance(c.FD.C.PENDING_TIMEOUT)
    equal(c.FD.duel.active, nil, "pending timeout clears addon session")
    equal(c.nativeVisible, true, "the still-pending native popup was never touched")
    equal(c.shows, 1, "the addon never re-shows Blizzard's popup")

    c = client()
    c:incoming()
    c:advance(0)
    c.combat = true
    c:emit("PLAYER_REGEN_DISABLED")
    equal(c.FD.duel:State(), "UNRATED", "combat during negotiation fails unrated")
    equal(c.FD.duel.active.reason, "combat", "combat reason recorded")
    c.env.AcceptDuel()
    equal(c.accepts, 1, "Blizzard's accept remains available after combat")

    c = client()
    c:incoming()
    c:advance(0)
    local active = c.FD.duel.active
    c.FD.duel:Later(0.25, active, function() error("injected timer failure") end)
    c:advance(0.25)
    equal(c.FD.duel.active, nil, "timer exception clears rated session")
    equal(c.nativeVisible, true, "timer exception keeps the ordinary duel dialog")
    equal(#c.FD.Debug:Errors(), 1, "timer exception persisted")
    equal(c.FD.Database:GetStats().rating, 1500, "timer exception does not rate")

    c = client()
    c:incoming()
    local log = c.FD.Debug.Log
    c.FD.Debug.Log = function(self, topic, ...)
        if topic == "transport send" then error("injected send result failure") end
        return log(self, topic, ...)
    end
    c:advance(0.25)
    equal(c.FD.duel.active, nil, "a send-result callback exception stops the rated flow")
    equal(#c.FD.Debug:Errors() > 0, true, "send-result callback exception persisted")
    equal(c.nativeVisible, true, "send-result exception keeps the ordinary flow")
    c.FD.Debug.Log = log

    c = client()
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "server acknowledgement without captured candidate ignored")
    c.env.StartDuel("missing")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "unresolved requested unit never falls back to current target")
    equal(#c.prints, 1, "the challenger is told once that tracking could not attach")
    equal(c.prints[1]:find("could not attach", 1, true) ~= nil, true, "untracked challenge explained")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(#c.prints, 1, "the explanation is not repeated")
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

    -- An attempt without an exact identity may still produce an unqualified
    -- acknowledgment: block other captures for that attempt's own window,
    -- never longer, and tell the user only if a request actually went out.
    for _, failure in ipairs({
        { "missing identity", function() return "missing" end },
        { "restricted argument", function(state) return state.secret end },
        { "nil argument", function() return nil end },
        { "ambiguous name", function(state)
            state.units.focus = { guid = "Player-1-00000003", name = "Beta", realm = "Other", classFile = "MAGE" }
            return "Beta"
        end },
        { "restricted identity", function(state) state.units.target.guid = state.secret; return "target" end },
    }) do
        local failed = client()
        failed.env.StartDuel(failure[2](failed))
        local reason, firstDeadline = failed.FD.Wow.outgoingStatus, failed.FD.Wow.outgoingBlockedUntil
        equal(type(reason), "string", failure[1] .. " retains original capture failure diagnosis")
        equal(firstDeadline, failed.now + failed.FD.C.OUTGOING_TIMEOUT, failure[1] .. " quarantines native attempt")
        equal(failed.FD.Wow.outgoing, nil, failure[1] .. " keeps no candidate that can consume an acknowledgment")
        failed.units.target = { guid = "Player-1-00000004", name = "Gamma", realm = "Forever", classFile = "WARRIOR" }
        failed.units.focus = nil
        failed:advance(1)
        failed.env.StartDuel("target")
        equal(failed.FD.Wow.outgoing, nil, failure[1] .. " refuses to bind the second request during ambiguity window")
        equal(failed.FD.Wow.outgoingBlockedUntil, firstDeadline, failure[1] .. " a later attempt never extends the block")
        failed.messageInfo = { [701] = "ERR_DUEL_REQUESTED" }
        failed:emit("UI_INFO_MESSAGE", 701, "Delayed request acknowledgment from first attempt.")
        equal(failed.FD.duel.active, nil, failure[1] .. " late native notice cannot create a rated context for Gamma")
        equal(failed.FD.QueueWow.venueTestPending, nil, failure[1] .. " late native notice cannot create a venue test context")
        equal(failed:printed("another duel request is still pending"), true, failure[1] .. " the user learns why")
        failed:advance(failed.FD.C.OUTGOING_TIMEOUT)
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

    -- Native failure notices within two seconds of StartDuel clear the capture.
    for _, notice in ipairs({
        { "mapped out of range", 51, "Out of range.", { [51] = "ERR_OUT_OF_RANGE" } },
        { "unmapped out of range text", 52, "Out of range." },
        { "target dueling", 53, "Target is currently dueling" },
    }) do
        c = client()
        c.messageInfo = notice[4]
        c.env.StartDuel("target")
        c:emit("UI_ERROR_MESSAGE", notice[2], notice[3])
        equal(c.FD.Wow.outgoing, nil, notice[1] .. " clears the failed capture")
        equal(c.FD.Wow:RequestDuel("target"), true, notice[1] .. " does not block the next request")
        equal(c.startedUnit, "target", notice[1] .. " the addon request reaches StartDuel")
        c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
        equal(c.FD.duel:State(), "CHECKING_ADDON", notice[1] .. " retry is tracked")
    end
    c = client()
    c.env.StartDuel("target")
    c:advance(2.5)
    c:emit("UI_ERROR_MESSAGE", 51, "Out of range.")
    equal(c.FD.Wow.outgoing ~= nil, true, "a failure notice long after the attempt belongs to something else")
    c = client()
    c.env.StartDuel("target")
    c:emit("UI_ERROR_MESSAGE", 51, "Out of range.")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel:State(), "CHECKING_ADDON", "a misattributed failure without a newer attempt keeps the acknowledgment usable")
    c = client()
    c.env.StartDuel("missing")
    c:emit("UI_ERROR_MESSAGE", 51, "Out of range.")
    equal(c.FD.Wow.outgoingBlockedUntil, nil, "a failed unidentified attempt releases its own block")

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
    equal(c.FD.Wow.outgoing ~= nil, true, "native capture survives several seconds without acknowledgment")
    c.messageInfo = { [701] = "ERR_DUEL_REQUESTED", [702] = "ERR_DUEL_CANCELLED" }
    c:emit("UI_INFO_MESSAGE", 701, "Request sent to Beta Brave.")
    equal(c.FD.duel:State(), "CHECKING_ADDON", "native mapped notice identifies request despite formatted text")
    equal(c.FD.duel.active.opponent.guid, namedPeer.guid, "typed request acknowledgment retains exact captured GUID")
    equal(c.FD.duel.active.createdAt, 0, "delayed acknowledgment does not restart native request deadline")
    equal(c.FD.duel.active.localConsent, nil, "native request notice never grants rated consent")
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
    c:advance(10)
    c.env.StartDuel("mouseover")
    equal(c.FD.Wow.outgoingBlockedUntil, c.FD.C.OUTGOING_TIMEOUT, "a different target is blocked only for the original window")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "overlapping attempts make unqualified acknowledgement ambiguous")
    c = client()
    c.env.StartDuel("target")
    c:advance(10)
    c.env.StartDuel("target")
    equal(c.FD.Wow.outgoingBlockedUntil, nil, "a repeated request to the same player is never blocked")
    equal(c.FD.Wow.outgoing.at, 10, "the newer attempt replaces the capture")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel:State(), "CHECKING_ADDON", "the repeated request is tracked")
    equal(c.FD.duel.active.createdAt, 10, "native window starts at the newer attempt")

    -- A challenger still in combat (e.g. right after a duel) is tracked.
    c = client()
    c.combat = true
    c.env.StartDuel("target")
    equal(c.FD.Wow.outgoing ~= nil, true, "combat does not block outgoing capture")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel:State(), "CHECKING_ADDON", "combat request starts discovery")
    equal(c.FD.Wow:RequestDuel("party1"), false, "addon buttons refuse while a duel is active")

    -- StartDuel(unit, exactMatch, toTheDeath): a Hardcore duel to the death
    -- is never tracked, and it makes a pending acknowledgment ambiguous.
    c = client()
    c.env.StartDuel("target", true, true)
    equal(c.FD.Wow.outgoing, nil, "duel to the death is not captured")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "its acknowledgment starts no rated flow")
    equal(#c.prints, 0, "and prints nothing")
    c = client()
    c.env.StartDuel("target")
    c.env.StartDuel("target", true, true)
    equal(c.FD.Wow.outgoing, nil, "a death request discards the pending capture")
    c:emit("CHAT_MSG_SYSTEM", c.env.ERR_DUEL_REQUESTED)
    equal(c.FD.duel.active, nil, "an acknowledgment that may belong to the death request is not rated")

    -- FD.Wow:RequestDuel is the single entry for addon duel buttons.
    c = client()
    equal(c.FD.Wow:RequestDuel("party1"), true, "submitted, waiting for native acknowledgment")
    equal(c.startedUnit, "party1", "unit tokens are passed to the native API")
    local ok, reason = c.FD.Wow:RequestDuel("Beta-Forever")
    equal(ok, false, "a pending capture refuses another request")
    equal(type(reason), "string", "refusal has a visible reason")
    c = client()
    c.env.StartDuel("missing")
    ok, reason = c.FD.Wow:RequestDuel("target")
    equal(ok, false, "an ambiguity block refuses addon requests")
    equal(reason:find("still pending", 1, true) ~= nil, true, "block reason names the remaining window")
    c = client()
    c:incoming()
    c.FD.duel:Abort("cancelled", false)
    c.units.target = nil
    c:incoming()
    equal(select(2, c.FD.Wow:RequestDuel("target")) ~= nil, true, "a pending incoming request refuses addon requests")
    c = client()
    c.combat = true
    equal(c.FD.Wow:RequestDuel("target"), false, "combat refuses addon requests")
    c.combat = false
    c.env.StartDuel = nil
    equal(c.FD.Wow:RequestDuel("target"), false, "missing native API refuses addon requests")

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
        { "unavailable identity", function() return "missing" end },
        { "restricted unit", function(state) return state.secret end },
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
                c.units.mouseover = { guid = "Player-1-00000005", name = "Delta", realm = "Forever", classFile = "MAGE" }
                c.env.StartDuel("mouseover")
                equal(c.FD.Wow.outgoing, nil, ending[1] .. " setup quarantines a different target")
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
                equal(c.FD.Wow.outgoingBlockedUntil, priorDeadline, ending[1] .. " a retry never extends the ambiguity window")
                c:advance(c.FD.C.OUTGOING_TIMEOUT)
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
    c.combat = true
    c:emit("PLAYER_REGEN_DISABLED")
    equal(c.FD.Wow.outgoing ~= nil, true, "entering combat keeps the pending capture")

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
    local receive = c.FD.duel.Receive
    c.FD.duel.Receive = function(...) receiveCalls = receiveCalls + 1; return receive(...) end
    c.FD.Comms:Receive(c.env.ERR_DUEL_REQUESTED, "x", "WHISPER", "Beta")
    c.FD.Comms:Receive(c.FD.C.PREFIX, c.secret, "WHISPER", "Beta")
    c.FD.Comms:Receive(c.FD.C.PREFIX, "x", "GUILD", "Beta")
    equal(receiveCalls, 0, "wrong prefix, route and secret payload rejected before the lifecycle")
    c.FD.Comms:Receive(c.FD.C.PREFIX, "x", "PARTY", "Beta")
    equal(c.FD.Comms.lastRejection:find("invalid envelope", 1, true) ~= nil, true, "malformed PARTY payload rejected")

    for _, code in ipairs({ 2, 3 }) do
        c = client({ registerResult = code })
        equal(c.FD.Comms.available, false, "truthy registration failure enum rejected")
        equal(c.FD.Comms:Send({ match = {}, kind = "HELLO", payload = "x" }), false, "unavailable registration cannot enqueue")
    end
    c = client({ registerResult = 1 })
    equal(c.FD.Comms.available, true, "already-registered prefix remains available")

    c = client()
    c:incoming()
    c:advance(0.2)
    local sent = #c.sent
    local old = c.FD.duel.active
    old.peerNonce = "b"
    c.FD.Comms:Send({ match = old, kind = "ACCEPT", payload = packet(c.FD, "ACCEPT") })
    c.FD.duel.active = nil
    c:advance(0.2)
    equal(#c.sent, sent, "queued obsolete consent dropped after session cancellation")
    old.finalized = true
    c.FD.Comms:Send({ match = old, kind = "RESULT", payload = packet(c.FD, "RESULT") })
    c:advance(0.2)
    equal(#c.sent, sent + 1, "finalized result can drain after active session released")
    equal(c.FD.Protocol:Decode(c.sent[#c.sent].payload).kind, "RESULT", "drained payload is result")
    equal(c.sent[#c.sent].channel, "WHISPER", "transport uses targeted whisper")
    equal(c.sent[#c.sent].target, "Beta-Forever", "transport preserves explicit realm")

    -- The live failure through two real adapters: explicit /duel surname, the
    -- native acknowledgment arrives after five seconds, addon delivery is
    -- delayed by ten seconds, and the receiver identifies the challenger late.
    local alpha = { guid = "Player-1-00000001", name = "Alpha", surname = "Example", classFile = "MAGE" }
    local tray = { guid = "Player-1-00000002", name = "Tray", surname = "Taylorr", classFile = "ROGUE" }
    local net = Client.pair({ regionalNames = true, alpha = alpha, beta = tray })
    local a, b = net.a, net.b
    net.delay = function() return math.max(0, 10.5 - net.clock.now) + 0.2 end
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
    local unmodified = a.env.UnitNameUnmodified
    a.env.UnitNameUnmodified = function() return "Tray", a.secret end
    equal(a.FD.Wow:Identity("target"), nil, "restricted surname rejected before native helper")
    equal(a.nameHelperCalls, callsBefore, "restricted surname is never concatenated by helper")
    a.env.UnitNameUnmodified = unmodified
    toggleDebugOff(a)
    toggleDebugOff(b)
    a.env.StartDuel("Tray Taylorr")
    a.messageInfo = { [701] = "ERR_DUEL_REQUESTED" }
    b.units.target = nil
    b:incoming("Alpha Example")
    net:advance(5)
    a:emit("UI_INFO_MESSAGE", 701, "Request sent to Tray Taylorr.")
    equal(a.FD.duel.active.createdAt, 0, "live-order recovery keeps original captured request time")
    net:advance(5.5)
    equal(b.FD.duel.active, nil, "surname receiver initially lacks native challenger identity")
    b.units.target = alpha
    net:advance(0.5)
    equal(a.FD.duel:State(), "CHECKING_ADDON", "outgoing discovery waits for delayed delivery")
    equal(b.FD.duel:State(), "CHECKING_ADDON", "incoming discovery survives delayed identity")
    equal(a.FD.UI.frame:IsShown(), false, "nothing shown before the peer is proven")
    equal(b.nativeVisible, true, "the receiver keeps Blizzard's popup throughout")
    equal(a.sent[1].target, "Tray Taylorr", "whisper target is the canonical surname name")
    local helloB = assert(b.FD.Protocol:Encode(b.FD.duel:Packet(b.FD.duel.active, "HELLO")))
    for _, sender in ipairs({ "Tray", "Tray-Taylorr", "Tray Other", "Tray Taylorr-Forever" }) do
        a:emit("CHAT_MSG_ADDON", a.FD.C.PREFIX, helloB, "WHISPER", sender)
        equal(a.FD.Comms.lastRejection:find("sender mismatch", 1, true) ~= nil, true,
            "unqualified or altered surname sender rejected: " .. sender)
    end
    net.delay = function() return 0.3 end
    net:advance(6)
    equal(a.FD.duel:State(), "READY", "delayed surname handshake reaches outgoing ready")
    equal(b.FD.duel:State(), "READY", "delayed surname handshake reaches incoming ready")
    equal(a.FD.UI.frame:IsShown(), true, "late mapped native acknowledgment ultimately opens challenger panel")
    equal(a.FD.UI.rated.enabled, true, "verified two-client handshake enables challenger rated choice")
    equal(b.FD.UI.rated.enabled, true, "verified two-client handshake enables recipient rated choice")
    equal(a.FD.duel.active.matchId, b.FD.duel.active.matchId, "real adapters agree on the same session")
    local match = a.FD.duel.active
    local visibleOpponent = a.units.target
    a.units.target = nil
    equal(a.FD.duel:Fresh(match), true, "an opponent that no unit resolves is unknown, not changed")
    a.units.target = visibleOpponent
    local priorLevel = visibleOpponent.level
    visibleOpponent.level = 31
    local fresh, freshReason = a.FD.duel:Fresh(match)
    equal(fresh, false, "a positively observed level change is detected without a level event")
    equal(freshReason, "level", "level change has its own reason")
    visibleOpponent.level = priorLevel
    a.units.focus = { guid = "Player-1-00000003", name = "Third", surname = "Player", classFile = "MAGE", level = 31 }
    a:emit("UNIT_LEVEL", "focus")
    equal(a.FD.duel:State(), "READY", "unrelated level-up preserves rated negotiation")
    a.units.focus = nil
    equal(b.accepts, 0, "recovered discovery never accepts native duel automatically")
    a.FD.UI.rated.scripts.OnClick()
    net:advance(1)
    equal(b.accepts, 0, "one surname peer's consent does not start native duel")
    b.FD.UI.rated.scripts.OnClick()
    equal(b.accepts, 1, "both explicit clicks complete the agreement through real surname transport")
    local winner = a.FD.Results:Parse("Alpha Example has defeated Tray Taylorr in a duel",
        a.env.DUEL_WINNER_KNOCKOUT, a.env.DUEL_WINNER_RETREAT, match.player, match.opponent)
    equal(winner, alpha.guid, "full surnamed result resolves known participants")
    winner = a.FD.Results:Parse("Alpha has defeated Tray in a duel",
        a.env.DUEL_WINNER_KNOCKOUT, a.env.DUEL_WINNER_RETREAT, match.player, match.opponent)
    equal(winner, nil, "native-request aliases never qualify result evidence")

    a.env.SlashCmdList.FOREVERDUEL("ui")
    a:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
    b:emit("CHAT_MSG_SYSTEM", "Duel starting: 3")
    net:advance(3.5)
    net:finish(a, b)
    net:advance(2)
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
    local deliveredA, deliveredB = 0, 0
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
    equal(c.env.UISpecialFrames[1], "ForeverDuelDialog", "native Escape list owns the duel panel")
    equal(c.env.UISpecialFrames[2], "ForeverDuelProfile", "native Escape list owns the overview frame")
    c.env.SlashCmdList.FOREVERDUEL("")
    equal(profile.frame:IsShown(), false, "overview command toggles closed")
    for index = 1, 17 do
        local player = c.FD.Database:GetStats()
        local won = index % 2 == 1
        local after, delta = c.FD.Rating:Calculate(player.rating, 1500, won,
            c.FD.Wow:Identity("player", true).level, c.FD.Wow:Identity("target").level)
        local record = {
            schemaVersion = 2, protocolVersion = c.FD.C.PROTOCOL_VERSION, bracket = "LEVELING", matchId = "overview-" .. index,
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
    equal(#c.env.UISpecialFrames, 2, "reopening does not duplicate Escape registration")
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
    equal(c.nativeVisible, true, "overview failure preserves Blizzard's accept and decline")
    equal(#c.FD.Database.data.matches, 17, "overview failure preserves saved history")
    local printedCount = #c.prints
    c.env.SlashCmdList.FOREVERDUEL("summary")
    equal(#c.prints > printedCount, true, "chat summary remains available independently of overview")

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
    equal(c.nativeVisible, true, "presence query error preserves the native choice")
    c.env.C_Map = { GetBestMapForUnit = function() error("injected map API error") end }
    c.env.SlashCmdList.FOREVERDUEL("status")
    equal(c.FD.duel.active, pending, "optional discovery diagnostics cannot abort pending rated negotiation")

    c = client()
    c.sendResult = 3
    c:incoming()
    c:advance(5)
    equal(c.FD.duel:State(), "CHECKING_ADDON", "a throttled discovery message is retried, never fatal")
    equal(#c.sent > 1, true, "throttled message submitted again after backoff")
    equal(c.FD.Database:GetStats().rating, 1500, "transport failure never changes rating")

    c = client()
    c.units.target.level = 36
    c:incoming(); c:advance(0)
    equal(c.FD.duel:State(), "UNRATED", "native opponent six levels higher blocks rated")
    equal(c.FD.UI.frame:IsShown(), false, "ineligible request shows no panel")
    equal(#c.prints, 0, "unknown ineligible challenger causes no chat output")
    equal(#c.sent, 0, "ineligible request sends no discovery")
    c.env.AcceptDuel()
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
    equal(c.FD.duel.active.reason, "level", "level reason recorded")

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
