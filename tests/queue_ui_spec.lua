return function(_, equal)
    local function client(options)
        options = options or {}
        local env = setmetatable({}, { __index = _G })
        env._G = env
        local state = { now = 1000, reads = 0, created = 0, captures = 0, calls = {}, prints = {}, logs = {}, secret = {} }
        local active = { state = "IN_PROGRESS", matchId = "preserve-duel" }
        local FD = {
            duel = { active = active }, Debug = {}, Wow = {},
            Database = { data = { player = { rating = 1516 }, matches = { "existing-record" } } },
            Profile = {}, Zone = {},
        }
        function FD.Wow:Readable(value) return value ~= state.secret end
        function FD.Debug:Print(value) state.prints[#state.prints + 1] = value end
        function FD.Debug:Log(...) state.logs[#state.logs + 1] = { ... } end
        function FD:Safe() error("Queue UI must not invoke duel-aborting recovery") end
        function FD:CaptureQueueVenue()
            state.captures = state.captures + 1
            if state.failCapture then error("capture failed") end
            if state.rejectCapture then return false, state.rejectCapture end
            return true, state.captureReason or "Saved Test place. Sending the same place to Peer."
        end
        state.status = { state = "IDLE", level = 30, ratingWindow = 100, discovered = 0,
            settings = { scope = "ZONE", levelGap = 0, ruleset = "NORMAL" }, venueCount = 0 }
        FD.queue = {}
        function FD.queue:GetStatus()
            state.reads = state.reads + 1
            if state.failStatus then error(state.errorValue or "status failed") end
            return state.status
        end
        for _, method in ipairs({ "Join", "Leave", "Configure", "Invite", "Waypoint", "Challenge" }) do
            local name = method
            FD.queue[name] = function(_, argument)
                state.calls[#state.calls + 1] = { method = name, argument = argument }
                if state.failAction then error("action failed") end
                if state.rejectAction then return false, state.rejectAction end
                if name == "Configure" then
                    for key, value in pairs(argument) do state.status.settings[key] = value end
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
        env.CreateFrame = function(kind, name, parent)
            local frame = widget()
            frame.kind, frame.name, frame.parent = kind, name, parent
            if name then env[name] = frame end
            return frame
        end
        env.UIParent = widget()
        env.UIParent:SetSize(options.width or 1920, options.height or 1080)
        env.GetServerTime = function() return state.now end
        env.UISpecialFrames = {}
        FD.Profile.frame, FD.Zone.frame = widget(), widget()
        function FD.Profile:Toggle() self.frame:Show() end
        if options.noQueue then FD.queue = nil end
        local chunk = assert(loadfile("ForeverDuel/QueueUI.lua"))
        setfenv(chunk, env)
        chunk("ForeverDuel", FD)
        state.FD, state.env, state.active = FD, env, active
        function state:click(button) button.scripts.OnClick(button) end
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
    equal(ui.frame.clamped, true, "queue panel remains on screen")
    equal(ui.frame.drag, "LeftButton", "queue panel registers dragging")
    equal(c.env.UISpecialFrames[1], "ForeverDuelQueue", "escape can close queue panel")
    equal(c.env.ForeverDuelQueue, ui.frame, "escape entry resolves global frame")
    equal(ui.frame.scale, 1, "large displays retain full panel size")
    equal(ui.status.text, "Not queued", "idle status shown")
    equal(ui.ruleset.text, "Normal (automatic)", "native ruleset displayed without a manual choice")
    equal(ui.ruleset.kind, nil, "ruleset presentation is a read-only font string")
    equal(ui.ruleset.scripts.OnClick, nil, "automatic ruleset has no manual action")
    equal(ui.scopes.ZONE.enabled, true, "selected zone remains clickable rather than greyed out")
    equal(ui.scopes.ZONE.text, "> Zone", "selected zone clearly marked")
    equal(ui.scopes.CONTINENT.enabled, true, "continent search available without manual verification")
    equal(ui.scopes.RULESET.enabled, true, "whole-ruleset search available without manual verification")
    equal(ui.scopeHint.text:find("reachable addon users", 1, true) ~= nil, true, "scope reach remains best effort")
    equal(ui.venue.text:find("No tested places saved yet", 1, true) ~= nil, true, "empty venue catalog explains the save button")
    equal(ui.saveVenue.enabled, true, "idle queue can save a tested native-duel place")
    equal(ui.saveVenue.text, "Save tested place", "tested-place capture has a direct UI action")
    equal(ui.setup.text:find("filled automatically", 1, true) ~= nil, true, "venue capture needs no manual values")
    equal(c.captures, 0, "opening queue does not save or share a place")
    equal(ui.help.text:find("On foot", 1, true) ~= nil, true, "lower levels display walking estimate")
    equal(ui.help.text:find("15 minutes", 1, true) ~= nil, true, "travel limit shown")
    equal(ui.help.text:find("terrain or routes", 1, true) ~= nil, true, "travel approximation explained")
    equal(#c.calls, 0, "opening queue does not join or challenge")
    local created = c.created
    ui:Show()
    equal(c.created, created, "repeat opening reuses frames")
    equal(#c.env.UISpecialFrames, 1, "escape entry registered once")
    ui:Toggle()
    equal(ui.frame:IsShown(), false, "toggle closes queue")
    local reads = c.reads
    ui:RefreshIfShown()
    ui.frame.scripts.OnUpdate(ui.frame, 2)
    equal(c.reads, reads, "hidden queue performs no status reads")
    ui:Toggle()
    ui.frame.scripts.OnDragStart(ui.frame)
    equal(ui.frame.moving, true, "drag starts movement")
    ui.frame.scripts.OnDragStop(ui.frame)
    equal(ui.frame.moving, false, "drag stops movement")

    c.status.settings.ruleset = "RP"
    ui:RefreshIfShown()
    equal(ui.ruleset.text, "RP (automatic)", "updated native ruleset appears without configuration")
    equal(#c.calls, 0, "native ruleset rendering does not mutate queue preferences")
    c.status.settings.ruleset, c.status.settings.rulesetReason = nil, "Native ruleset information is not available yet."
    ui:RefreshIfShown()
    equal(ui.ruleset.text, "Detecting ruleset...", "missing native ruleset gives automatic detection status")
    equal(ui.reason.text, c.status.settings.rulesetReason, "missing native ruleset explains actual source failure")
    equal(ui.reason.text:find("Choose", 1, true), nil, "missing native ruleset never requests a manual choice")
    c.status.settings.ruleset, c.status.settings.rulesetReason = "RP", nil
    c:click(ui.scopes.ZONE)
    equal(c.calls[#c.calls].argument.scope, "ZONE", "selected zone button remains a working search criterion")
    c:select(ui.levelGap, 6)
    equal(c.calls[#c.calls].argument.levelGap, 5, "largest gap stays within rated eligibility")
    equal(ui.levelGap.text, "Up to 5 levels", "configured level gap shown")
    c:select(ui.levelGap, 1)
    equal(c.calls[#c.calls].argument.levelGap, 0, "same-level search supported")
    equal(ui.levelGap.text, "Same level", "same-level label shown")
    ui:RefreshIfShown()
    equal(ui.scopes.CONTINENT.enabled, true, "continent scope stays available without verification flags")
    c:click(ui.scopes.CONTINENT)
    equal(c.calls[#c.calls].argument.scope, "CONTINENT", "scope selection sends correct engine token")
    equal(ui.scopes.CONTINENT.text, "> Continent", "selected scope marked")
    equal(ui.scopes.ZONE.enabled, true, "zone can be selected again")
    ui:RefreshIfShown()
    equal(ui.scopes.RULESET.enabled, true, "whole-ruleset scope stays available without verification flags")
    c:click(ui.scopes.RULESET)
    equal(c.calls[#c.calls].argument.scope, "RULESET", "ruleset reach independent of own ruleset")
    equal(c.status.settings.ruleset, "RP", "scope selection does not overwrite detected ruleset")
    c.status.level = 40
    ui:RefreshIfShown()
    equal(ui.help.text:find("Normal mount (+60%)", 1, true) ~= nil, true, "level forty displays normal mount estimate")

    local captureQueueCalls = #c.calls
    c.rejectCapture = "Complete a successful ordinary duel at this spot first."
    c:click(ui.saveVenue)
    equal(c.captures, 1, "save button delegates to native-tested-place integration")
    equal(ui.reason.text, c.rejectCapture, "capture failure explains its actual prerequisite inline")
    equal(c.status.state, "IDLE", "rejected place capture does not enroll")
    c.rejectCapture = nil
    c:click(ui.saveVenue)
    equal(ui.reason.text, "Saved Test place. Sending the same place to Peer.", "successful capture distinguishes sending from received proof")
    equal(#c.calls, captureQueueCalls, "place capture does not join or configure matchmaking")
    c:preserved("tested-place capture")
    ui.notice = nil

    c:click(ui.join)
    equal(c.calls[#c.calls].method, "Join", "join button joins engine queue")
    equal(ui.join.text, "Leave queue", "active queue offers leave")
    equal(ui.ruleset.scripts.OnClick, nil, "queued ruleset remains read-only")
    equal(ui.levelGap.enabled, false, "queued level criteria frozen")
    equal(ui.scopes.ZONE.enabled, false, "queued reach criteria frozen")
    equal(ui.saveVenue.enabled, false, "queued capture action disabled")
    local calls = #c.calls
    -- A criteria click that was already queued before the state refresh cannot reconfigure.
    c:click(ui.scopes.ZONE)
    equal(#c.calls, calls, "stale criteria click cannot mutate active queue")
    equal(ui.reason.text, "Leave the queue before changing your search criteria.", "frozen settings explain next action")
    local captures = c.captures
    c:click(ui.saveVenue)
    equal(c.captures, captures, "stale save click cannot mutate an active queue")
    equal(ui.reason.text, "Leave the queue before saving a tested place.", "queued place capture explains how to proceed")
    ui.notice = nil
    c.status.queuedAt, c.status.ratingWindow, c.status.discovered = 937, 200, 7
    ui:RefreshIfShown()
    equal(ui.timer.text, "Waiting: 1:03  /  Rating +/-200", "queue wait and current widened window use server time")
    equal(ui.discovery.text, "Queue profiles found: 7", "discovery count does not claim queue position")
    reads = c.reads
    ui.frame.scripts.OnUpdate(ui.frame, 0.4)
    equal(c.reads, reads, "short UI update avoids repeated status work")
    c.now = 1001
    ui.frame.scripts.OnUpdate(ui.frame, 0.7)
    equal(ui.timer.text, "Waiting: 1:04  /  Rating +/-200", "visible countdown refreshes each second")
    c:click(ui.join)
    equal(c.calls[#c.calls].method, "Leave", "leave button leaves search")
    equal(ui.join.text, "Join queue", "leaving restores join action")

    c.status.state, c.status.inviter, c.status.inviteFallback = "GROUPING", true, true
    c.status.opponent = { fullName = "Peer|cFF0000", level = 40, rating = 1500 }
    c.status.deadline = 1121
    ui:RefreshIfShown()
    equal(ui.invite.enabled, true, "native invitation fallback offered to inviter")
    equal(ui.challenge.enabled, false, "grouping does not allow premature duel")
    equal(ui.timer.text, "Time remaining: 2:00", "group deadline uses epoch server time")
    equal(ui.opponent.text, "Opponent: Peer||cFF0000", "peer display cannot inject markup")
    c:click(ui.invite)
    equal(c.calls[#c.calls].method, "Invite", "explicit invite fallback delegates to engine")
    c.status.inviter = false
    ui:RefreshIfShown()
    equal(ui.invite.enabled, false, "recipient cannot send mirrored native invitations")
    equal(ui.matchHelp.text:find("Accept your matched opponent", 1, true) ~= nil, true, "recipient instructed to accept native invite")

    c.status.state = "TRAVELLING"
    c.status.venue = { id = "tested-place", name = "Place|texture", mapX = 0.42, mapY = 0.58,
        x = 6400, y = 4200 }
    c.status.ownArrived, c.status.peerArrived = true, false
    ui:RefreshIfShown()
    equal(ui.waypoint.enabled, true, "travel offers venue waypoint")
    equal(ui.venue.text, "Venue: Place||texture  (42.0, 58.0)", "tested venue normalized coordinates displayed")
    equal(ui.arrival.text, "You: arrived  /  Opponent: travelling", "arrival status shown for both contestants")
    equal(ui.challenge.enabled, false, "single contestant arrival cannot offer duel")
    c:click(ui.waypoint)
    equal(c.calls[#c.calls].method, "Waypoint", "waypoint button delegates to engine")
    c.status.peerArrived, c.status.state = true, "READY"
    c.status.deadline = 1051
    ui:RefreshIfShown()
    equal(ui.challenge.enabled, true, "ready pair offers normal native duel request")
    equal(ui.arrival.color[1], 0.36, "both arrivals use ready color")
    equal(ui.matchHelp.text:find("explicitly accept rated", 1, true) ~= nil, true, "ready instructions preserve explicit rated consent")
    c:click(ui.challenge)
    equal(c.calls[#c.calls].method, "Challenge", "duel action delegates to existing native challenge adapter")
    c.now = 1052
    ui:RefreshIfShown()
    equal(ui.timer.text, "Time remaining: 0:00", "expired deadline cannot render negative time")
    equal(ui.challenge.enabled, false, "expired ready deadline disables optional duel action")
    for _, value in ipairs({ "RESERVING", "PLANNING", "PAUSED", "DUEL", "CLEANUP" }) do
        c.status.state = value
        ui:RefreshIfShown()
        equal(ui.challenge.enabled, false, value .. " never offers a rated start")
    end
    equal(ui.join.enabled, false, "cleanup cannot create competing queue session")
    c.status.state, c.status.deadline, c.status.queuedAt, c.status.cooldownUntil = "IDLE", nil, nil, 1112
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

    c.rejectAction = "Move closer to your matched opponent."
    c.status.state = "READY"
    c:click(ui.challenge)
    equal(ui.reason.text, c.rejectAction, "rejected native action explains recovery")
    c.rejectAction = nil
    c:click(ui.challenge)
    equal(ui.notice, nil, "successful action clears old notice")
    c.failAction = true
    c:click(ui.challenge)
    equal(ui.frame:IsShown(), false, "optional action failure hides only queue presentation")
    equal(#c.prints, 1, "queue action error reports slash fallback")
    equal(#c.logs, 1, "readable queue action error locally logged")
    c:preserved("failed optional action")
    c.failAction, c.failStatus = nil, true
    equal(ui:Show(), false, "status errors remain isolated")
    equal(ui.frame:IsShown(), false, "failed status does not leave stale clickable panel")
    c:preserved("failed status")
    local logged = #c.logs
    c.errorValue = c.secret
    ui:Show()
    equal(#c.logs, logged, "secret error detail never enters debug log")

    local absent = client({ noQueue = true })
    equal(absent.FD.QueueUI:Show(), true, "missing engine displays unavailable guidance")
    equal(absent.FD.QueueUI.join.enabled, false, "missing engine cannot join")
    equal(absent.FD.QueueUI.saveVenue.enabled, false, "missing engine cannot save a venue")
    equal(absent.FD.QueueUI.ruleset.scripts.OnClick, nil, "missing engine cannot configure ruleset manually")
    equal(absent.FD.QueueUI.reason.text, "The duel queue is unavailable.", "missing engine explained")
    absent:preserved("unavailable queue")
    local captureError = client()
    captureError.FD.QueueUI:Show()
    captureError.failCapture = true
    captureError:click(captureError.FD.QueueUI.saveVenue)
    equal(captureError.FD.QueueUI.frame:IsShown(), false, "capture errors hide only queue presentation")
    equal(#captureError.logs, 1, "capture exception is isolated and logged")
    captureError:preserved("failed tested-place capture")
    local small = client({ width = 700, height = 600 })
    small.FD.QueueUI:Show()
    equal(small.FD.QueueUI.frame.scale < 1, true, "queue fits small UI dimensions")
    small:click(small.FD.QueueUI.overview)
    equal(small.FD.QueueUI.frame:IsShown(), false, "record navigation closes queue")
    equal(small.FD.Profile.frame:IsShown(), true, "record navigation opens overview")
end
