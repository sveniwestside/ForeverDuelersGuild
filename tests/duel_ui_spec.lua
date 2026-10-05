return function(FD, equal)
    local timers, sent, now, combat = {}, {}, 100, false
    local nativeHides, nativeShows, nativeAccepts = 0, 0, 0
    local popupName, popupFrame = nil, { name = "StaticPopup1" }
    local methods = {}
    local function widget(_, name)
        local object = setmetatable({ scripts = {}, shown = false, points = {} }, { __index = methods })
        object.name = name
        return object
    end
    for _, name in ipairs({ "SetFrameStrata", "SetBackdrop", "SetJustifyH" }) do methods[name] = function() end end
    function methods:SetSize(width, height) self.width, self.height = width, height end
    function methods:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function methods:ClearAllPoints() self.points = {} end
    function methods:SetText(value) self.text = value end
    function methods:SetEnabled(value) self.enabled = value end
    function methods:SetScript(name, callback) self.scripts[name] = callback end
    function methods:CreateFontString() return widget() end
    function methods:Show() self.shown = true end
    -- Like WoW, Hide raises OnHide for a frame that was shown.
    function methods:Hide()
        local was = self.shown
        self.shown = false
        if was and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function methods:IsShown() return self.shown end
    local env = setmetatable({ UIParent = widget(nil, "UIParent"), CreateFrame = widget, UISpecialFrames = {},
        C_Timer = { After = function(delay, callback) timers[#timers + 1] = { at = now + delay, callback = callback } end },
        InCombatLockdown = function() return combat end,
        StaticPopup_Hide = function() nativeHides = nativeHides + 1 end,
        StaticPopup_Show = function() nativeShows = nativeShows + 1 end,
        StaticPopup_Visible = function(which)
            if which == "DUEL_REQUESTED" and popupName then return popupName, popupFrame end
        end,
        GetTime = function() return now end,
    }, { __index = _G })
    env._G = env
    FD.Debug = { Log = function() end, Print = function() end }
    function FD:Safe(callback, ...) return callback(...) end
    local chunk = assert(loadfile("ForeverDuel/UI.lua"))
    setfenv(chunk, env)("ForeverDuel", FD)
    local function advance(seconds)
        local target = now + seconds
        while true do
            local index
            for i, timer in ipairs(timers) do
                if timer.at <= target and (not index or timer.at < timers[index].at) then index = i end
            end
            if not index then break end
            local timer = table.remove(timers, index)
            now = timer.at
            timer.callback()
        end
        now = target
    end
    local player = { guid = "Player-1-A", fullName = "Alpha-Forever", name = "Alpha", realm = "Forever",
        className = "Mage", classFile = "MAGE", level = 30, maxLevel = 60 }
    local opponent = { guid = "Player-1-B", fullName = "Beta-Forever", name = "Beta", realm = "Forever",
        className = "Rogue", classFile = "ROGUE", level = 30, maxLevel = 60 }
    assert(FD.Database:Initialize(nil, player))
    FD.duel = FD.Duel:New({ now = function() return now end, epoch = function() return 1700000000 + math.floor(now) end,
        random = function() return 123 end, after = function(delay, callback) env.C_Timer.After(delay, callback) end,
        identity = function() return player end, combat = function() return combat end,
        send = function(item)
            sent[#sent + 1] = assert(FD.Protocol:Decode(item.payload))
            return true
        end,
        render = function(match) FD.UI:Render(match) end, hide = function() FD.UI:Hide() end,
        accept = function() nativeAccepts = nativeAccepts + 1; return true end,
        print = function() end, log = function() end,
    }, FD.Database)
    local ui = FD.UI
    local function acknowledge(match, kind)
        return FD.duel:Receive(assert(FD.Protocol:Encode({ kind = kind or "HELLO_ACK", nonce = "b0b-1-2", echo = match.nonce,
            guid = opponent.guid, peerGUID = player.guid, role = match.role == "OUTGOING" and "INCOMING" or "OUTGOING",
            rating = 1500, specId = 0, classFile = opponent.classFile, wins = 3, losses = 1,
            level = opponent.level, maxLevel = opponent.maxLevel, verdict = "-" })), opponent.fullName)
    end
    local function lastKind() return sent[#sent] and sent[#sent].kind end

    assert(FD.duel:Begin("OUTGOING", player, opponent))
    local match = FD.duel.active
    equal(ui.frame == nil or not ui.frame:IsShown(), true, "nothing is shown before the peer is proven")
    equal(lastKind(), "HELLO", "discovery starts silently")
    acknowledge(match)
    equal(FD.duel:State(), "READY", "echoed handshake proves the peer")
    equal(ui.frame:IsShown(), true, "proven peer shows the outgoing panel")
    equal(env.UISpecialFrames[1], "ForeverDuelDialog", "Esc can close the panel without clearing the target")
    equal(ui.frame.points[1][2], env.UIParent, "outgoing panel is standalone")
    equal(ui.rated.text, "Propose RATED duel", "outgoing consent is an explicit proposal")
    equal(ui.rated.enabled, true, "proven request enables the proposal")
    equal(ui.normal.text, "Keep unrated", "outgoing panel offers the ordinary choice")
    equal(ui.normal:IsShown(), true, "keep unrated visible for the challenger")
    equal(ui.body.text:find("rating 1500 (3-1)", 1, true) ~= nil, true, "peer rating and record shown")
    equal(ui.body.text:find("win +16 / loss -16", 1, true) ~= nil, true, "rated projection shown")
    equal(ui.body.text:find("Request expires in 50 s", 1, true) ~= nil, true, "native window shown")
    advance(1)
    equal(ui.body.text:find("Request expires in 49 s", 1, true) ~= nil, true, "countdown refreshes once per second")
    advance(3)
    equal(ui.body.text:find("Request expires in 46 s", 1, true) ~= nil, true, "countdown keeps refreshing")

    combat = true
    ui:Render(match)
    equal(ui.rated.enabled, false, "combat disables the rated choice")
    equal(ui.body.text:find("Leave combat to choose a rated duel.", 1, true) ~= nil, true, "combat hint visible")
    equal(FD.duel:State(), "READY", "combat that was already active does not unrate")
    combat = false
    ui:Render(match)
    equal(ui.rated.enabled, true, "the panel refresh after combat re-enables the choice")

    ui.rated.scripts.OnClick()
    equal(FD.duel:State(), "LOCAL_ACCEPTED", "click proposes rated play")
    equal(lastKind(), "ACCEPT", "proposal sent")
    equal(ui.rated.enabled, false, "proposal cannot be repeated")
    equal(ui.body.text:find("Waiting for Beta-Forever to agree to a rated duel.", 1, true) ~= nil, true, "waiting text")
    ui.close.scripts.OnClick()
    equal(FD.duel:State(), "UNRATED", "closing the panel keeps the duel unrated")
    equal(lastKind(), "CANCEL", "closing notifies the peer")
    equal(sent[#sent].reason, "choice", "closing carries the choice reason")
    equal(ui.frame:IsShown(), false, "closed panel stays hidden")

    -- Esc: UISpecialFrames hides the frame; OnHide reports an explicit close.
    assert(FD.duel:Begin("OUTGOING", player, opponent))
    match = FD.duel.active
    acknowledge(match)
    equal(ui.frame:IsShown(), true, "new request shown")
    ui.frame:Hide()
    equal(FD.duel:State(), "UNRATED", "Esc means keep unrated")
    equal(sent[#sent].kind, "CANCEL", "Esc notifies the peer")

    -- A programmatic hide (state change) is not a user choice.
    assert(FD.duel:Begin("OUTGOING", player, opponent))
    match = FD.duel.active
    acknowledge(match)
    ui:Hide()
    equal(FD.duel:State(), "READY", "internal hide does not unrate")
    ui:Render(match)
    equal(ui.frame:IsShown(), true, "panel can be shown again")
    -- A frame hidden only by its hidden parent stays IsShown and is no close.
    ui.frame.scripts.OnHide(ui.frame)
    equal(FD.duel:State(), "READY", "parent hide (Alt+Z) does not unrate")
    acknowledge(match, "ACCEPT")
    equal(FD.duel:State(), "REMOTE_ACCEPTED", "peer proposal arrives")
    equal(ui.rated.text, "Accept RATED duel", "outgoing can accept the peer's proposal")
    equal(ui.body.text:find("Beta-Forever proposes a RATED duel.", 1, true) ~= nil, true, "proposal text")
    ui.normal.scripts.OnClick()
    equal(FD.duel:State(), "UNRATED", "keep unrated button")
    equal(ui.frame:IsShown(), false, "unrated request hides the panel")

    -- INCOMING: Blizzard's popup is never touched before the addon's own accept.
    popupName = "StaticPopup1"
    assert(FD.duel:Begin("INCOMING", player, opponent))
    match = FD.duel.active
    equal(ui.frame:IsShown(), false, "unknown challenger: nothing beside the native popup")
    acknowledge(match)
    equal(ui.frame:IsShown(), true, "proven challenger: companion panel")
    equal(ui.frame.points[1][2], popupFrame, "companion anchored below the visible native popup")
    equal(ui.frame.points[1][3], "BOTTOM", "companion sits under the popup")
    equal(ui.rated.text, "Accept as RATED duel", "incoming rated choice")
    equal(ui.normal:IsShown(), false, "Blizzard's buttons remain the ordinary choice")
    equal(ui.body.text:find("Blizzard's Accept starts an UNRATED duel.", 1, true) ~= nil, true, "unrated hint")
    acknowledge(match, "ACCEPT")
    equal(FD.duel:State(), "REMOTE_ACCEPTED", "challenger proposed")
    equal(nativeAccepts, 0, "proposal alone never accepts")
    ui.rated.scripts.OnClick()
    equal(FD.duel:State(), "RATED_CONFIRMED", "both consents")
    equal(nativeAccepts, 1, "the addon accepts natively once")
    equal(ui.frame:IsShown(), false, "accepted request hides the companion")

    popupName = nil
    assert(FD.duel:Begin("INCOMING", player, opponent))
    match = FD.duel.active
    acknowledge(match)
    equal(ui.frame.points[1][2], env.UIParent, "fixed top-center fallback without a visible popup")
    advance(51)
    equal(ui.frame:IsShown(), false, "expired request removes the panel")
    equal(FD.duel.active, nil, "expired request ends")
    equal(nativeHides, 0, "the UI never hides Blizzard's popup itself")
    equal(nativeShows, 0, "the UI never re-shows Blizzard's popup")

    assert(FD.duel:Begin("OUTGOING", player, opponent))
    match = FD.duel.active
    acknowledge(match)
    for _, state in ipairs({ "COUNTDOWN", "IN_PROGRESS", "FINISHING", "FINISHED", "UNRATED", "UNRATED_ACTIVE", "CHECKING_ADDON" }) do
        match.state = state
        ui:Render(match)
        equal(ui.frame:IsShown(), false, state .. " has no pending panel")
        match.state = "READY"
        ui:Render(match)
    end
    match.nativeAccepted = true
    ui:Render(match)
    equal(ui.frame:IsShown(), false, "native acceptance closes the panel")
    match.nativeAccepted = nil
    ui:Render(nil)
    equal(ui.frame:IsShown(), false, "cleared match closes the panel")
    equal(#FD.Database.data.matches, 0, "UI choices do not create rated history")
    equal(FD.Database:GetStats("LEVELING").rating, 1500, "pending UI changes do not affect ratings")

    -- Where the client has the game-menu Esc handler API, only a real Esc
    -- closes the panel; loss of control or other panels cannot unrate it.
    local handlers = {}
    env.GameMenuEscPriority = { Dialog = 1, AddOn = 8, World = 11 }
    env.RegisterGameMenuEscHandler = function(priority, handler) handlers[#handlers + 1] = { priority, handler } end
    ui:Hide()
    ui.frame = nil
    env.UISpecialFrames = {}
    assert(FD.duel:Begin("OUTGOING", player, opponent))
    match = FD.duel.active
    acknowledge(match)
    equal(#handlers, 1, "one Esc handler registered")
    equal(handlers[1][1], 8, "AddOn priority, ahead of the World handler that clears the target")
    equal(#env.UISpecialFrames, 0, "no UISpecialFrames entry beside the handler")
    ui.frame:Hide()
    equal(FD.duel:State(), "READY", "a hide by other UI code is not a choice")
    ui:Render(match)
    equal(handlers[1][2](), true, "Esc consumed while the panel is shown")
    equal(FD.duel:State(), "UNRATED", "Esc keeps the duel unrated")
    equal(handlers[1][2](), false, "Esc passes through when the panel is hidden")

    -- Pinned Blizzard_StaticPopup_Game/GameDialog.lua registers
    -- StaticPopup_EscapePressed at Dialog priority: with DUEL_REQUESTED shown
    -- (hideOnEscape, OnCancel = CancelDuel) Esc declines the request before
    -- any AddOn handler runs. The CancelDuel hook then reaches Cancelled().
    local declines = 0
    handlers[#handlers + 1] = { env.GameMenuEscPriority.Dialog, function()
        if not popupName then return false end
        popupName, declines = nil, declines + 1
        FD.duel:Cancelled()
        return true
    end }
    local function esc()
        table.sort(handlers, function(x, y) return x[1] < y[1] end)
        for _, handler in ipairs(handlers) do if handler[2]() then return true end end
        return false
    end
    popupName = "StaticPopup1"
    assert(FD.duel:Begin("INCOMING", player, opponent))
    acknowledge(FD.duel.active)
    equal(ui.frame:IsShown(), true, "companion beside the native popup")
    equal(ui.body.text:find("Decline or Esc refuses the duel request.", 1, true) ~= nil, true,
        "the companion warns that Esc declines")
    equal(esc(), true, "Esc consumed")
    equal(declines, 1, "Blizzard's popup handler ran first and declined")
    equal(FD.duel.active, nil, "declined request ends")
    equal(sent[#sent].kind, "CANCEL", "peer notified")
    equal(sent[#sent].reason, "cancelled", "as a declined request, not as an unrated choice")
    equal(ui.frame:IsShown(), false, "companion closes with the request")
    assert(FD.duel:Begin("OUTGOING", player, opponent))
    acknowledge(FD.duel.active)
    equal(esc(), true, "without a native popup the panel's handler gets Esc")
    equal(FD.duel:State(), "UNRATED", "challenger's Esc keeps the duel unrated")
    equal(sent[#sent].reason, "choice", "as an unrated choice")
end
