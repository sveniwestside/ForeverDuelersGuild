return function(_, equal)
    local function client(options)
        options = options or {}
        local env = setmetatable({}, { __index = _G })
        env._G = env
        local state = { now = 1000, reads = 0, created = 0, captures = 0, calls = {}, prints = {}, logs = {}, secret = {},
            timers = {} }
        local active = { state = "IN_PROGRESS", matchId = "preserve-duel" }
        local FD = {
            duel = { active = active }, Debug = {}, Wow = {},
            Database = { data = { player = { rating = 1516 }, matches = { "existing-record" } } },
            Profile = {}, Zone = {},
        }
        assert(loadfile("ForeverDuel/Locale.lua"))("ForeverDuel", FD)
        function FD.Wow:Readable(value) return value ~= state.secret end
        function FD.Debug:Print(value) state.prints[#state.prints + 1] = value end
        function FD.Debug:Log(...) state.logs[#state.logs + 1] = { ... } end
        function FD.Debug:Error(context, message) state.logs[#state.logs + 1] = { context, message } end
        function FD:Safe() error("Queue UI must not invoke duel-aborting recovery") end
        function FD:CaptureQueueVenue()
            state.captures = state.captures + 1
            if state.failCapture then error("capture failed") end
            if state.rejectCapture then return false, state.rejectCapture end
            return true, state.captureReason or "Saved Test place here. Sending it to Peer; waiting for their client to confirm."
        end
        state.status = { state = "IDLE", level = 30, ratingWindow = 100, discovered = 0,
            settings = { scope = "ZONE", levelGap = 0, ruleset = "NORMAL" }, venueCount = 0, autoAccept = false }
        FD.queue = {}
        function FD.queue:GetStatus()
            state.reads = state.reads + 1
            if state.failStatus then error(state.errorValue or "status failed") end
            return state.status
        end
        for _, method in ipairs({ "Join", "Leave", "Configure", "Waypoint", "Challenge", "LeaveGroup" }) do
            local name = method
            FD.queue[name] = function(_, argument)
                state.calls[#state.calls + 1] = { method = name, argument = argument }
                if state.failAction then error("action failed") end
                if state.rejectAction then return false, state.rejectAction end
                if name == "Configure" then
                    for key, value in pairs(argument) do
                        if key == "autoAcceptQueueInvite" then state.status.autoAccept = value else state.status.settings[key] = value end
                    end
                elseif name == "Join" then
                    state.status.state, state.status.queuedAt = "SEARCHING", state.now
                elseif name == "Leave" then
                    state.status.state, state.status.queuedAt = "IDLE", nil
                end
                return true
            end
        end
        local methods, widget = {}, nil
        widget = function()
            state.created = state.created + 1
            return setmetatable({ scripts = {} }, { __index = methods })
        end
        function methods:SetSize(width, height) self.width, self.height = width, height end
        function methods:GetWidth() return self.width end
        function methods:GetHeight() return self.height end
        function methods:SetPoint(...) self.point = { ... } end
        function methods:SetText(value) self.text = value end
        function methods:GetText() return self.text end
        function methods:SetTextColor(...) self.color = { ... } end
        function methods:SetEnabled(value) self.enabled = value end
        function methods:SetChecked(value) self.checked = value end
        function methods:GetChecked() return self.checked end
        function methods:SetScript(event, callback) self.scripts[event] = callback end
        function methods:SetScale(scale) self.scale = scale end
        function methods:CreateFontString() return widget() end
        function methods:IsShown() return self.shown end
        function methods:Show() self.shown = true end
        function methods:Hide()
            self.shown = false
            if self.scripts.OnHide then self.scripts.OnHide(self) end
        end
        function methods:SetMovable(value) self.movable = value end
        function methods:SetClampedToScreen(value) self.clamped = value end
        function methods:RegisterForDrag(value) self.drag = value end
        function methods:StartMoving() self.moving = true end
        function methods:StopMovingOrSizing() self.moving = false end
        for _, name in ipairs({ "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor", "SetFrameStrata",
            "EnableMouse", "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetHighlightTexture" }) do
            methods[name] = function() end
        end
        env.CreateFrame = function(kind, name, parent, template)
            local frame = widget()
            frame.kind, frame.name, frame.parent, frame.template = kind, name, parent, template
            if name then env[name] = frame end
            return frame
        end
        env.UIParent = widget()
        env.UIParent:SetSize(options.width or 1920, options.height or 1080)
        env.GetServerTime = function() return state.now end
        env.C_Timer = { After = function(_, callback) state.timers[#state.timers + 1] = callback end }
        env.UISpecialFrames = {}
        FD.Profile.frame, FD.Zone.frame = widget(), widget()
        function FD.Profile:Toggle() self.frame:Show() end
        if options.noQueue then FD.queue = nil end
        for _, module in ipairs({ "Native", "Widgets", "QueueUI" }) do
            local chunk = assert(loadfile("ForeverDuel/" .. module .. ".lua"))
            setfenv(chunk, env)
            chunk("ForeverDuel", FD)
        end
        state.FD, state.env, state.active = FD, env, active
        function state:click(button) button.scripts.OnClick(button) end
        -- Runs the one-second timers that are pending now.
        function state:tick()
            local pending = self.timers
            self.timers = {}
            for _, callback in ipairs(pending) do callback() end
        end
        function state:select(control, index)
            self:click(control)
            equal(control.menu:IsShown(), true, "queue criteria menu opens")
            self:click(control.items[index])
            equal(control.menu:IsShown(), false, "queue criteria selection closes its menu")
            equal(FD.QueueUI.dropdownDismiss:IsShown(), false, "queue criteria selection releases dismiss layer")
        end
        function state:preserved(label)
            equal(FD.duel.active, active, label .. " preserves active duel")
            equal(active.state, "IN_PROGRESS", label .. " preserves native duel state")
            equal(FD.Database.data.player.rating, 1516, label .. " preserves rating")
            equal(FD.Database.data.matches[1], "existing-record", label .. " preserves history")
        end
        return state
    end

    local c = client()
    local ui = c.FD.QueueUI
    c.FD.Profile.frame:Show()
    c.FD.Zone.frame:Show()
    equal(ui:Show(), true, "queue opens through isolated runner")
    equal(ui.frame:IsShown(), true, "queue window visible")
    equal(c.FD.Profile.frame:IsShown(), false, "queue navigation hides overview")
    equal(c.FD.Zone.frame:IsShown(), false, "queue navigation hides zone browser")
    equal(ui.frame.movable, true, "queue panel movable")
    equal(c.env.UISpecialFrames[1], "ForeverDuelQueue", "escape can close queue panel")
    equal(ui.frame.scale, 1, "large displays retain full panel size")
    equal(ui.status.text, "Not queued", "idle status shown")
    equal(ui.ruleset.text, "Normal (automatic)", "native ruleset displayed without a manual choice")
    equal(ui.ruleset.scripts.OnClick, nil, "automatic ruleset has no manual action")
    equal(ui.scopes.ZONE.text, "> Zone", "selected zone clearly marked")
    equal(ui.scopes.CONTINENT.enabled, true, "continent search available")
    equal(ui.venue.text:find("No tested places saved yet", 1, true) ~= nil, true, "empty venue catalog explains the save button")
    equal(ui.saveVenue.enabled, true, "idle queue can save a tested native-duel place")
    equal(ui.invite, nil, "invitations are automatic; no manual invite button")
    equal(ui.autoAccept.template, "UICheckButtonTemplate", "auto-accept is a checkbox")
    equal(ui.autoAccept.checked, false, "auto-accept off by default")
    equal(ui.leaveGroup.enabled, false, "no queue group to leave")
    equal(ui.challenge.enabled, false, "no duel request while idle")
    equal(ui.help.text:find("On foot", 1, true) ~= nil, true, "lower levels display walking estimate")
    equal(#c.calls, 0, "opening queue does not join or challenge")
    local created = c.created
    ui:Show()
    equal(c.created, created, "repeat opening reuses frames")
    ui:Toggle()
    equal(ui.frame:IsShown(), false, "toggle closes queue")
    local reads = c.reads
    ui:RefreshIfShown()
    c:tick()
    equal(c.reads, reads, "hidden queue performs no status reads")
    equal(ui.frame.scripts.OnUpdate, nil, "the queue window has no per-frame refresh")
    ui:Toggle()
    equal(#c.timers, 0, "an idle window without a countdown schedules no refresh")

    c.status.settings.ruleset, c.status.settings.rulesetReason = nil, "Native ruleset information is not available yet."
    ui:RefreshIfShown()
    equal(ui.ruleset.text, "Detecting ruleset...", "missing native ruleset gives automatic detection status")
    equal(ui.reason.text, c.status.settings.rulesetReason, "missing native ruleset explains actual source failure")
    c.status.settings.ruleset, c.status.settings.rulesetReason = "RP", nil
    c:select(ui.levelGap, 6)
    equal(c.calls[#c.calls].argument.levelGap, 5, "largest gap stays within rated eligibility")
    equal(ui.levelGap.text, "Up to 5 levels", "configured level gap shown")
    c:select(ui.levelGap, 2)
    equal(ui.levelGap.text, "Up to 1 level", "singular level label")
    c:click(ui.scopes.CONTINENT)
    equal(c.calls[#c.calls].argument.scope, "CONTINENT", "scope selection sends correct engine token")
    c:click(ui.autoAccept)
    equal(c.calls[#c.calls].argument.autoAcceptQueueInvite, true, "checkbox enables auto-accept")
    equal(ui.autoAccept.checked, true, "checkbox reflects the setting")

    c.rejectCapture = "Complete a successful ordinary duel at this spot first."
    c:click(ui.saveVenue)
    equal(c.captures, 1, "save button delegates to native-tested-place integration")
    equal(ui.noticeText.text, c.rejectCapture, "capture failure explained on the notice line")
    c.rejectCapture = nil
    c:click(ui.saveVenue)
    equal(ui.noticeText.text:find("waiting for their client to confirm", 1, true) ~= nil, true,
        "capture says the partner has not confirmed yet")
    c:preserved("tested-place capture")

    c:click(ui.join)
    equal(c.calls[#c.calls].method, "Join", "join button joins engine queue")
    equal(ui.join.text, "Leave queue", "active queue offers leave")
    equal(ui.noticeText.text, "", "a state change clears the old notice")
    equal(ui.levelGap.enabled, false, "queued level criteria frozen")
    equal(ui.saveVenue.enabled, false, "queued capture action disabled")
    equal(ui.autoAccept.enabled, true, "auto-accept can change while queued")
    local calls = #c.calls
    c:click(ui.scopes.ZONE)
    equal(#c.calls, calls, "stale criteria click cannot mutate active queue")
    equal(ui.noticeText.text, "Leave the queue before changing your search criteria.", "frozen settings explain next action")
    equal(ui.reason.text ~= ui.noticeText.text, true, "a notice never replaces the live status reason")
    c.now = c.now + 11
    ui:RefreshIfShown()
    equal(ui.noticeText.text, "", "notices expire after a few seconds")
    c.status.queuedAt, c.status.ratingWindow, c.status.discovered = c.now - 63, 200, 7
    ui:RefreshIfShown()
    equal(ui.timer.text, "Waiting: 1:03  /  Rating +/-200", "queue wait and current widened window use server time")
    equal(#c.timers, 1, "a displayed countdown keeps one pending refresh")
    reads, c.now = c.reads, c.now + 1
    c:tick()
    equal(c.reads, reads + 1, "the ticker refreshes once per second")
    equal(ui.timer.text, "Waiting: 1:04  /  Rating +/-200", "the wait advances without a queue render")
    ui:RefreshIfShown()
    equal(#c.timers, 1, "queue renders never stack a second ticker")
    ui.frame:Hide()
    reads = c.reads
    c:tick()
    equal(c.reads, reads, "a hidden window ends the ticker without reading status")
    equal(#c.timers, 0, "no refresh stays scheduled for a hidden window")
    ui:Show()
    equal(ui.discovery.text, "Queue profiles found: 7", "discovery count does not claim queue position")

    c.status.state = "INVITED"
    c.status.opponent = { fullName = "Peer|cFF0000" }
    c.status.deadline = c.now + 60
    ui:RefreshIfShown()
    equal(ui.status.text, "Group invitation received", "invitation state named")
    equal(ui.matchHelp.text:find("Accept the group invitation from Peer||cFF0000", 1, true) ~= nil, true,
        "invitee told which invitation to accept, without markup")
    equal(ui.matchHelp.text:find("Automatic acceptance is on.", 1, true) ~= nil, true, "auto-accept mentioned")
    equal(ui.timer.text, "Time remaining: 1:00", "invitation deadline shown")
    c.status.state = "INVITING"
    ui:RefreshIfShown()
    equal(ui.matchHelp.text:find("Waiting for Peer||cFF0000 to accept", 1, true) ~= nil, true, "coordinator waits for acceptance")

    c.status.state = "TRAVELLING"
    c.status.venue = { id = "tested-place", name = "Place|texture", mapX = 0.42, mapY = 0.58 }
    c.status.ownArrived, c.status.peerArrived = true, false
    ui:RefreshIfShown()
    equal(ui.waypoint.enabled, true, "travel offers venue waypoint")
    equal(ui.venue.text, "Venue: Place||texture  (42.0, 58.0)", "tested venue normalized coordinates displayed")
    equal(ui.arrival.text, "You: arrived  /  Opponent: travelling", "arrival status shown for both contestants")
    equal(ui.challenge.enabled, false, "single arrival cannot request a duel")
    c:click(ui.waypoint)
    equal(c.calls[#c.calls].method, "Waypoint", "waypoint button delegates to engine")

    c.status.peerArrived, c.status.state, c.status.coordinator = true, "READY", false
    c.status.deadline = c.now + 51
    ui:RefreshIfShown()
    equal(ui.challenge.enabled, false, "only the designated requester gets the duel button")
    equal(ui.matchHelp.text:find("Waiting for Peer||cFF0000 to send the duel request", 1, true) ~= nil, true,
        "the other player sees who requests")
    c.status.coordinator = true
    c.status.colocation = "Move within 10 yards of Peer on the same level."
    ui:RefreshIfShown()
    equal(ui.challenge.enabled, true, "designated requester can request the duel")
    equal(ui.arrival.color[1], 0.36, "both arrivals use ready color")
    equal(ui.matchHelp.text:find("explicitly accept rated", 1, true) ~= nil, true, "rated consent remains explicit")
    equal(ui.matchHelp.text:find("Move within 10 yards", 1, true) ~= nil, true, "co-location hint shown")
    c.rejectAction = "Move within 10 yards of Peer on the same level."
    c:click(ui.challenge)
    equal(ui.noticeText.text, c.rejectAction, "refused challenge explains recovery")
    equal(c.status.state, "READY", "refused challenge keeps the match")
    c.rejectAction = nil
    c:click(ui.challenge)
    equal(ui.noticeText.text, "", "successful action clears old notice")
    c.now = c.now + 60
    ui:RefreshIfShown()
    equal(ui.timer.text, "Time remaining: 0:00", "expired deadline cannot render negative time")
    equal(ui.challenge.enabled, false, "expired start deadline disables the duel action")
    for _, value in ipairs({ "PLANNING", "GROUPING", "PAUSED", "DUEL", "CLEANUP" }) do
        c.status.state = value
        ui:RefreshIfShown()
        equal(ui.challenge.enabled, false, value .. " never offers a rated start")
    end

    c.status.state, c.status.cleanupStatus = "CLEANUP", "Closing the queue group."
    c.status.reason = "Your opponent's client cancelled because they left the queue."
    c.status.cancel = { reason = "CANCELLED", received = true, text = c.status.reason }
    c.status.groupAction = true
    ui:RefreshIfShown()
    equal(ui.reason.text, c.status.reason, "cancellation reason shown")
    equal(ui.cleanup.text, "Closing the queue group.", "cleanup status shown separately")
    equal(ui.join.enabled, true, "Leave is available in CLEANUP to force idle")
    equal(ui.join.text, "Leave queue", "cleanup offers leave")
    equal(ui.leaveGroup.enabled, true, "Leave group offered for the queue pair group")
    c:click(ui.leaveGroup)
    equal(c.calls[#c.calls].method, "LeaveGroup", "Leave group delegates to the engine")
    c.status.state, c.status.reason = "SEARCHING", "Searching for a suitable opponent."
    c.status.cleanupStatus, c.status.groupAction = nil, false
    ui:RefreshIfShown()
    equal(ui.lastMatch.text, "Last match: Your opponent's client cancelled because they left the queue.",
        "previous cancellation stays visible after an automatic requeue")
    equal(ui.cleanup.text, "", "cleanup line cleared")
    c.status.state, c.status.deadline, c.status.queuedAt, c.status.cooldownUntil = "IDLE", nil, nil, c.now + 60
    c.status.cancel = nil
    ui:RefreshIfShown()
    equal(ui.timer.text, "Queue cooldown: 1:00", "idle queue cooldown visible")
    equal(ui.join.enabled, false, "cooldown disables premature queue joins")
    c.status.cooldownUntil = nil
    c.status.reason, c.status.opponent = "Reason|escape", nil
    ui:RefreshIfShown()
    equal(ui.reason.text, "Reason||escape", "engine reason cannot inject markup")
    c.status.reason = c.secret
    ui:RefreshIfShown()
    equal(ui.reason.text, "Unavailable", "restricted display value is not stringified")
    c:preserved("queue display and delegation")

    c.failAction = true
    c.status.state = "SEARCHING"
    c:click(ui.join)
    equal(ui.frame:IsShown(), false, "optional action failure hides only queue presentation")
    equal(#c.prints, 1, "queue action error reports slash fallback")
    c:preserved("failed optional action")
    c.failAction, c.failStatus = nil, true
    equal(ui:Show(), false, "status errors remain isolated")
    equal(ui.frame:IsShown(), false, "failed status does not leave stale clickable panel")
    equal(c.logs[#c.logs][1], "queue window", "window failures are persisted addon errors")
    local logged = #c.logs
    c.errorValue = c.secret
    ui:Show()
    equal(#c.logs, logged + 1, "a secret failure is still recorded")
    equal(c.logs[#c.logs][2], "restricted error", "secret error detail never enters the saved errors")

    local absent = client({ noQueue = true })
    equal(absent.FD.QueueUI:Show(), true, "missing engine displays unavailable guidance")
    equal(absent.FD.QueueUI.join.enabled, false, "missing engine cannot join")
    equal(absent.FD.QueueUI.saveVenue.enabled, false, "missing engine cannot save a venue")
    equal(absent.FD.QueueUI.reason.text, "The duel queue is unavailable.", "missing engine explained")
    absent:preserved("unavailable queue")
    local captureError = client()
    captureError.FD.QueueUI:Show()
    captureError.failCapture = true
    captureError:click(captureError.FD.QueueUI.saveVenue)
    equal(captureError.FD.QueueUI.frame:IsShown(), false, "capture errors hide only queue presentation")
    captureError:preserved("failed tested-place capture")
    local small = client({ width = 700, height = 600 })
    small.FD.QueueUI:Show()
    equal(small.FD.QueueUI.frame.scale < 1, true, "queue fits small UI dimensions")
    small:click(small.FD.QueueUI.overview)
    equal(small.FD.QueueUI.frame:IsShown(), false, "record navigation closes queue")
    equal(small.FD.Profile.frame:IsShown(), true, "record navigation opens overview")

    -- The 1 Hz ticker covers every text that changes without a queue render:
    -- always while queued or matched, and when idle only time-dependent
    -- content (cleanup advisory, Leave group, an ageing profile count).
    local live = client()
    local liveUI = live.FD.QueueUI
    liveUI:Show()
    equal(#live.timers, 0, "an idle window without time-dependent content stays quiet")
    live.status.state, live.status.cleanupStatus, live.status.groupAction = "CLEANUP", "Closing the queue group.", true
    liveUI:RefreshIfShown()
    equal(liveUI.timer.text, "", "cleanup without a deadline shows no countdown")
    equal(#live.timers, 1, "a queue match keeps the ticker without a countdown")
    -- Queue:Cleanup ends a match while the pair is still grouped; the
    -- engine's own pulse changes these fields without rendering the window.
    live.status.state = "IDLE"
    live.status.cleanupStatus = "You are still in a group. Leave it manually if you no longer need it."
    live:tick()
    equal(liveUI.cleanup.text, live.status.cleanupStatus, "the end of a grouped match shows without a queue render")
    equal(liveUI.leaveGroup.enabled, true, "Leave group offered for the leftover pair")
    equal(#live.timers, 1, "an idle cleanup advisory keeps the ticker")
    live.status.cleanupStatus, live.status.groupAction = nil, false
    live:tick()
    equal(liveUI.cleanup.text, "", "a cleared advisory disappears without a queue render")
    equal(liveUI.leaveGroup.enabled, false, "Leave group follows the native group without a queue render")
    equal(#live.timers, 0, "nothing time-dependent is left: the ticker stops")
    live.status.discovered = 3
    liveUI:RefreshIfShown()
    equal(#live.timers, 1, "an idle profile count ages, so it keeps the ticker")
    live.status.discovered = 0
    live:tick()
    equal(liveUI.discovery.text, "Queue profiles found: 0", "aged-out profiles leave the count without a queue render")
    equal(#live.timers, 0, "an empty profile count ends the ticker")
    live.status.state, live.status.venue = "TRAVELLING", {}
    liveUI:RefreshIfShown()
    equal(liveUI.venue.text, "Venue: unnamed", "a venue without name or ID gets its own line")

    -- Every user-facing label goes through the locale table.
    local german = client()
    german.FD.Locale.current = "deDE"
    german.FD.Locale:Register("deDE", { ["Not queued"] = "Nicht angemeldet", ["Leave group"] = "Gruppe verlassen" })
    german.FD.QueueUI:Show()
    equal(german.FD.QueueUI.status.text, "Nicht angemeldet", "state names are localized")
    equal(german.FD.QueueUI.leaveGroup.text, "Gruppe verlassen", "button labels are localized")
end
