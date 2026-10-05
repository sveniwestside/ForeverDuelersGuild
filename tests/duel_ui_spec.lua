return function(FD, equal)
    local timers, sent, nativeHides = {}, {}, 0
    local nativeAccepts, nativeDeclines, now = 0, 0, 100
    local methods = {}
    local function widget()
        return setmetatable({ scripts = {}, shown = false }, { __index = methods })
    end
    for _, name in ipairs({ "SetSize", "SetPoint", "SetFrameStrata", "SetBackdrop", "SetJustifyH" }) do
        methods[name] = function() end
    end
    function methods:SetText(value) self.text = value end
    function methods:SetEnabled(value) self.enabled = value end
    function methods:SetScript(name, callback) self.scripts[name] = callback end
    function methods:CreateFontString() return widget() end
    function methods:Show() self.shown = true end
    function methods:Hide() self.shown = false end
    function methods:IsShown() return self.shown end
    local env = setmetatable({ UIParent = widget(), CreateFrame = widget,
        C_Timer = { After = function(_, callback) timers[#timers + 1] = callback end },
        InCombatLockdown = function() return false end,
        StaticPopup_Hide = function() nativeHides = nativeHides + 1 end,
        StaticPopup_Show = function() end,
        GetTime = function() return now end,
    }, { __index = _G })
    FD.Debug = { Log = function() end, Print = function() end }
    function FD:Safe(callback, ...) return callback(...) end
    local chunk = assert(loadfile("ForeverDuel/UI.lua"))
    setfenv(chunk, env)("ForeverDuel", FD)
    local player = { guid = "Player-1-A", fullName = "Alpha-Forever", name = "Alpha", realm = "Forever",
        className = "Mage", classFile = "MAGE", level = 30, maxLevel = 60 }
    local opponent = { guid = "Player-1-B", fullName = "Beta-Forever", name = "Beta", realm = "Forever",
        className = "Rogue", classFile = "ROGUE", level = 30, maxLevel = 60 }
    assert(FD.Database:Initialize(nil, player))
    FD.duel = FD.Duel:New({ now = function() return now end, epoch = function() return 1700000000 end,
        random = function() return 123 end, after = function() end,
        identity = function() return player end, opponentIdentity = function() return opponent end,
        send = function(payload) sent[#sent + 1] = assert(FD.Protocol:Decode(payload)); return true end,
        render = function(match) FD.UI:Render(match) end, hide = function() FD.UI:Hide() end,
        accept = function() nativeAccepts = nativeAccepts + 1; return true end,
        decline = function() nativeDeclines = nativeDeclines + 1; return true end,
        restore = function(match) return FD.UI:Restore(match) end,
        print = function() end, log = function() end,
    }, FD.Database)

    assert(FD.duel:Begin("OUTGOING", player, opponent))
    local ui, match = FD.UI, FD.duel.active
    equal(ui.frame:IsShown(), true, "outgoing native request has a visible pending dialog")
    equal(ui.rated.enabled, false, "pending outgoing request does not offer rated consent")
    equal(ui.rated.text, "Propose Rated Duel", "outgoing consent remains an explicit proposal")
    equal(ui.normal.text, "Keep Unrated", "pending outgoing request retains ordinary choice")
    equal(ui.decline.text, "Cancel Duel", "pending outgoing request can be cancelled")
    equal(ui.body.text:find("Waiting for opponent addon response", 1, true) ~= nil, true, "pending dialog explains the current wait")
    equal(#timers, 0, "outgoing rendering never suppresses an incoming native popup")
    equal(#sent, 1, "begin sends discovery but presentation adds no consent")
    equal(sent[1].kind, "HELLO")
    ui.rated.scripts.OnClick()
    equal(FD.duel:State(), "CHECKING_ADDON", "rated click cannot bypass an unconfirmed request")
    equal(#sent, 1, "unconfirmed rated click sends no acceptance")
    assert(FD.duel:Transition("DISCOVERY_WAIT"))
    equal(ui.frame:IsShown(), true, "pending outgoing dialog remains visible after the discovery timeout")
    equal(ui.rated.enabled, false, "discovery timeout never enables rated consent")
    equal(nativeAccepts, 0, "presentation never accepts a native duel")
    equal(nativeDeclines, 0, "presentation never declines a native duel")

    local acknowledgement = assert(FD.Protocol:Encode({ kind = "HELLO_ACK", nonce = "b", echo = match.nonce,
        guid = opponent.guid, peerGUID = player.guid, role = "INCOMING", rating = 1500,
        specId = 0, classFile = opponent.classFile, wins = 0, losses = 0,
        level = opponent.level, maxLevel = opponent.maxLevel, verdict = "-" }))
    FD.duel:Receive(acknowledgement, opponent.fullName)
    equal(FD.duel:State(), "READY", "actual echoed handshake makes the request ready")
    equal(ui.frame:IsShown(), true, "confirmed outgoing request stays visible")
    equal(ui.rated.enabled, true, "only confirmed request enables the rated proposal")
    equal(sent[#sent].kind, "HELLO_ACK", "handshake confirmation does not grant rated consent")
    local beforeRender = #sent
    ui:Render(match)
    equal(#sent, beforeRender, "rerendering a ready dialog never grants consent")
    equal(nativeAccepts, 0, "ready rendering cannot start the native duel")
    ui.decline.scripts.OnClick()
    equal(FD.duel:State(), "IDLE", "cancel button uses the existing decline lifecycle")
    equal(ui.frame:IsShown(), false, "declining closes the outgoing pending dialog")
    equal(nativeDeclines, 1, "only explicit cancel invokes native decline")
    equal(nativeAccepts, 0)

    assert(FD.duel:Begin("OUTGOING", player, opponent))
    match = FD.duel.active
    ui.normal.scripts.OnClick()
    equal(FD.duel:State(), "UNRATED", "ordinary choice keeps the request unrated")
    equal(ui.frame:IsShown(), false, "outgoing unrated choice retains the existing hidden presentation")
    equal(nativeAccepts, 0, "outgoing ordinary choice leaves native acceptance to the recipient")
    equal(nativeDeclines, 1, "ordinary choice does not cancel the native request")
    FD.duel:Abort("new test", false)

    assert(FD.duel:Begin("INCOMING", player, opponent))
    match = FD.duel.active
    equal(ui.rated.text, "Accept Rated Duel", "incoming request retains its distinct consent label")
    equal(ui.decline.text, "Decline", "incoming request retains native decline wording")
    equal(ui.rated.enabled, false, "incoming request still requires a confirmed handshake")
    equal(nativeHides, 0, "incoming native suppression remains deferred")
    local deferred = table.remove(timers, 1)
    deferred()
    equal(nativeHides, 1, "usable incoming dialog suppresses the native presentation on the next frame")
    assert(FD.duel:Transition("DISCOVERY_WAIT"))
    equal(ui.normal.text, "Accept Normal Duel", "incoming timeout preserves ordinary acceptance")
    equal(ui.body.text:find("You can accept a normal duel now.", 1, true) ~= nil, true)
    FD.duel:Abort("new test", false)
    while #timers > 0 do table.remove(timers, 1)() end
    equal(nativeHides, 1, "stale deferred rendering cannot suppress a closed request")

    for _, state in ipairs({ "COUNTDOWN", "IN_PROGRESS", "FINISHING", "FINISHED", "UNRATED_ACTIVE" }) do
        match.state = state
        ui.frame:Show()
        ui:Render(match)
        equal(ui.frame:IsShown(), false, state .. " has no pending dialog")
    end
    match.state, match.nativeAccepted = "READY", true
    ui.frame:Show()
    ui:Render(match)
    equal(ui.frame:IsShown(), false, "native acceptance closes pending presentation")
    ui.frame:Show()
    ui:Render(nil)
    equal(ui.frame:IsShown(), false, "cleared match closes pending presentation")
    equal(nativeAccepts, 0, "presentation and stale callbacks never invoke native acceptance")
    equal(#FD.Database.data.matches, 0, "UI choices do not create rated history")
    equal(FD.Database:GetStats("LEVELING").rating, 1500, "pending UI changes do not affect ratings")
end
