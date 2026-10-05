local addonName, FD = ...

-- Bootstrap, error recovery and generic commands. Subsystem wiring (duel
-- events and hooks, queue, discovery) lives in the module that owns it and is
-- registered through FD:OnEvent / FD:RegisterCommand / FD:RegisterStatus.

local function capture(err)
    local stack
    if type(debugstack) == "function" then
        local ok, value = pcall(debugstack, 2, 8, 0)
        if ok then stack = value end
    elseif type(debug) == "table" and type(debug.traceback) == "function" then
        local ok, value = pcall(debug.traceback, "", 2)
        if ok then stack = value end
    end
    return { message = err, stack = stack }
end

-- Stop the rated flow after an addon error in a way the peer and the queue
-- can see: the regular Abort sends CANCEL, records the reason and notifies the
-- queue. Only if that itself fails is the match cleared by assignment.
function FD:RecoverDuel(reason)
    local duel = self.duel
    local m = duel and duel.active
    if m then
        local ok = pcall(duel.Abort, duel, reason, true)
        if not ok then
            duel.active = nil
            duel.last = { state = "CANCELLED", reason = reason, matchId = m.matchId }
            if self.queue and self.queue.Run then
                pcall(self.queue.Run, self.queue, function() self.queue:OnDuel("abort", m) end)
            end
        end
    end
    if self.Wow then
        local now = GetTime()
        local deadline = math.max(self.Wow.outgoingBlockedUntil or 0,
            self.Wow.outgoing and self.Wow.outgoing.at + self.C.OUTGOING_TIMEOUT or 0)
        if self.Wow.outgoing or self.Wow.outgoingBlockedUntil then
            self.Wow.outgoingStatus, self.Wow.outgoingAt = "addon error; rated flow stopped", now
        end
        self.Wow.outgoing = nil
        self.Wow.outgoingBlockedUntil = deadline > now and deadline or nil
        self.Wow.pendingIncoming = nil
        self.Wow.incomingStatus = "addon error; native duel retained"
    end
    if self.UI then
        pcall(self.UI.Hide, self.UI)
        if m and self.UI.Restore then pcall(self.UI.Restore, self.UI, m) end
    end
    return m
end

function FD:Safe(callback, ...)
    local args, count = { ... }, select("#", ...)
    local ok, failure = xpcall(function() return callback(unpack(args, 1, count)) end, capture)
    if ok then return end
    local message = type(failure) == "table" and failure.message or failure
    local stack = type(failure) == "table" and failure.stack or nil
    pcall(self.Debug.Error, self.Debug, "rated duel", message, stack)
    local stopped = self:RecoverDuel("addon error")
    if stopped then
        self.Debug:Print(self.L["Rated flow stopped after an addon error. Use the normal duel dialog."])
    end
end

local INITIALIZE_RETRIES, INITIALIZE_INTERVAL = 15, 2

-- Native identity can be briefly unavailable at login. Initialization is
-- idempotent and retried instead of leaving a silently half-loaded addon.
function FD:Initialize()
    if self.initialized then return true end
    local identity = self.Wow:Identity("player", true)
    if not identity then
        self.initializeAttempts = (self.initializeAttempts or 0) + 1
        if self.initializeAttempts <= INITIALIZE_RETRIES then
            if not self.initializeRetryPending then
                self.initializeRetryPending = true
                C_Timer.After(INITIALIZE_INTERVAL, function()
                    self.initializeRetryPending = nil
                    self:Safe(function() self:Initialize() end)
                end)
            end
        elseif not self.initializeReported then
            self.initializeReported = true
            self.Debug:Print(self.L["Character identity is unavailable; rated duels are disabled until /reload."])
        end
        return false
    end
    local db, err = self.Database:Initialize(ForeverDuelDB, identity)
    if not db then
        self.databaseError = err
        if not self.databaseReported then
            self.databaseReported = true
            self.Debug:Print(self.Locale:Format("Saved data could not be loaded (%s). Rated duels are disabled; the data is untouched. Type /duelrating repair to start fresh while keeping a copy.", tostring(err)))
        end
        return false
    end
    ForeverDuelDB = db
    self.databaseError = nil
    self.initialized = true
    if db.legacy then self.Debug:Print(self.L["Previous rating preserved in Legacy. Leveling and Max level have separate ratings."]) end
    -- Each optional step is isolated so one failure cannot block the others.
    local failed = {}
    local function step(name, run)
        local ok, stepError = pcall(run)
        if not ok then
            failed[#failed + 1] = name
            pcall(self.Debug.Error, self.Debug, "initialize " .. name, stepError)
        end
    end
    step("dialog", function() self.UI:Create() end) -- A usable fallback before any native UI change.
    step("transport", function() self.Comms:Initialize() end)
    step("duel", function() self.duel = self.Duel:New(self.Wow:Environment(), self.Database) end)
    step("hooks", function() self.Wow:InstallHooks() end)
    step("minimap", function() self.Minimap:Initialize() end)
    step("discovery", function() self.Presence:Initialize() end)
    step("tooltip", function() self.Tooltip:Initialize() end)
    step("queue", function() self:InitializeQueue() end)
    self.Debug:Log("loaded", addonName, self.C.VERSION, "transport", self.Comms.available)
    if type(DUEL_COUNTDOWN) ~= "string" or type(DUEL_WINNER_KNOCKOUT) ~= "string" then
        self.Debug:Print(self.L["Duel evidence formats unavailable. This client cannot finalize rated duels."])
    end
    if #failed > 0 then
        self.Debug:Print(self.Locale:Format("Some features failed to start: %s. Type /duelrating errors for details.",
            table.concat(failed, ", ")))
    end
    return true
end

local function say(text) FD.Debug:Print(text) end

FD:RegisterCommand("ui", function() FD.Profile:Toggle() end, "Open the rating overview.", 1)
FD:RegisterCommand("summary", function() FD.UI:Summary() end, "Print ratings and recent results.", 3)
FD:RegisterCommand("history", function() FD.UI:History(20) end, "Print up to 20 recent rated duels.", 4)

FD:RegisterCommand("reset", function(rest)
    if FD.queue and FD.queue.state ~= "IDLE" then say(FD.L["Leave the queue before resetting."]); return end
    if FD.duel and FD.duel.active then say(FD.L["Finish or cancel the pending duel before resetting."]); return end
    if rest ~= "confirm" then
        FD.resetUntil = GetTime() + 15
        say(FD.L["This deletes this character's rating and history. Type /duelrating reset confirm within 15 seconds."])
        return
    end
    if not FD.resetUntil or GetTime() > FD.resetUntil then say(FD.L["Type /duelrating reset first."]); return end
    FD.resetUntil = nil
    local db, err = FD.Database:Reset(FD.Wow:Identity("player", true))
    if db then
        ForeverDuelDB = db
        FD.Profile:RefreshIfShown()
        FD.Presence:Changed()
        say(FD.L["This character's rating and history reset."])
    else say(FD.Locale:Format("Reset refused: %s", tostring(err))) end
end, "Delete this character's rating and history (asks for confirmation).", 70)

FD:RegisterCommand("repair", function(rest)
    if FD.Database.data then say(FD.L["Saved data is valid; nothing to repair."]); return end
    if type(FD.Database.Repair) ~= "function" then say(FD.L["Repair is unavailable in this version."]); return end
    if rest ~= "confirm" then
        say(FD.L["Repair starts a fresh rating for this character. The unreadable data stays in the saved file under 'quarantine'. Type /duelrating repair confirm."])
        return
    end
    local db, err = FD.Database:Repair(ForeverDuelDB, FD.Wow:Identity("player", true))
    if not db then say(FD.Locale:Format("Repair failed: %s", tostring(err))); return end
    ForeverDuelDB = db
    FD.databaseReported = nil
    if FD:Initialize() then say(FD.L["Saved data repaired. The previous data is kept under 'quarantine'."]) end
end, "Start fresh when saved data cannot be loaded (keeps a copy).", 71, true)

FD:RegisterStatus(10, function()
    local lines = {}
    lines[#lines + 1] = "Version: " .. FD.C.VERSION .. " | Addon transport: "
        .. (FD.Comms and FD.Comms.available and "registered" or "unavailable")
    if FD.databaseError then lines[#lines + 1] = "Saved data: unavailable (" .. tostring(FD.databaseError) .. ")" end
    lines[#lines + 1] = "State: " .. (FD.duel and FD.duel:State() or "DISABLED")
        .. " | Debug: " .. (FD.Database.data and FD.Database.data.settings.debug and "enabled" or "disabled")
    local errors = FD.Debug:Errors(1)
    if #errors > 0 then
        lines[#lines + 1] = "Last addon error: " .. (errors[1].context or "?") .. " | " .. (errors[1].message or "?")
    end
    for _, line in ipairs(FD.Debug:TrafficLines()) do lines[#lines + 1] = "Traffic: " .. line end
    return lines
end)

-- Every module has registered its handlers by now: Core.lua loads last.
local frame = CreateFrame("Frame")
FD.eventRegistered = {}
FD:OnEvent("PLAYER_LOGIN", function() FD:Initialize() end, true)
FD:OnEvent("PLAYER_ENTERING_WORLD", function(isInitialLogin, isReloadingUi)
    pcall(FD.Debug.Session, FD.Debug, isInitialLogin, isReloadingUi)
    if not FD.initialized then FD:Initialize() end
end, true)
for event, handlers in pairs(FD.eventHandlers) do
    local optional = true
    for _, handler in ipairs(handlers) do optional = optional and handler.optional end
    if optional then
        local ok, result = pcall(frame.RegisterEvent, frame, event)
        FD.eventRegistered[event] = ok and result ~= false
    else
        frame:RegisterEvent(event)
        FD.eventRegistered[event] = true
    end
end
-- Older clients can reject unknown events. Keep ordinary transport usable when
-- the optional logged-addon receive route is absent.
if FD.Comms then FD.Comms.loggedReceiveAvailable = FD.eventRegistered.CHAT_MSG_ADDON_LOGGED == true end
frame:SetScript("OnEvent", function(_, event, ...)
    local handlers = FD.eventHandlers[event]
    if not handlers then return end
    for _, handler in ipairs(handlers) do
        if handler.always or FD.duel then FD:Safe(handler.run, ...) end
    end
end)
FD.eventFrame = frame

SLASH_FOREVERDUEL1 = "/duelrating"
SlashCmdList.FOREVERDUEL = function(text) FD:Safe(function() FD:Command(text) end) end
