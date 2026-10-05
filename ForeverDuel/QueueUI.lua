local _, FD = ...
FD.QueueUI = {}
local QueueUI = FD.QueueUI
local L = FD.L
local WIDTH, HEIGHT = 800, 812
local GOLD = { 0.94, 0.75, 0.38 }
local MUTED = { 0.61, 0.65, 0.70 }
local WHITE = { 0.92, 0.94, 0.97 }
local GREEN = { 0.36, 0.85, 0.61 }
local NOTICE = { 1.00, 0.55, 0.35 }
local NOTICE_SECONDS = 10
local SCOPES = { "ZONE", "CONTINENT", "RULESET" }
local SCOPE_NAMES = { ZONE = "Zone", CONTINENT = "Continent", RULESET = "Whole ruleset" }
local RULESET_NAMES = { NORMAL = "Normal", PVP = "PvP", RP = "RP", HARDCORE = "Hardcore" }
local STATE_NAMES = {
    IDLE = "Not queued", SEARCHING = "Searching for an opponent", PAUSED = "Search paused",
    INVITING = "Inviting your opponent", INVITED = "Group invitation received",
    GROUPING = "Confirming the match", PLANNING = "Choosing a duel venue", TRAVELLING = "Travel to the duel venue",
    READY = "Both players have arrived", DUEL = "Duel in progress", CLEANUP = "Finishing the queue match",
}

local function readable(value)
    return not FD.Wow or FD.Wow:Readable(value)
end

local function plain(value)
    if not readable(value) then return L["Unavailable"] end
    return (tostring(value or ""):gsub("|", "||"))
end

local function number(value)
    return readable(value) and type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function duration(value)
    value = math.max(0, math.floor(value))
    return string.format("%d:%02d", math.floor(value / 60), value % 60)
end

local function serverTime()
    if type(GetServerTime) ~= "function" then return nil end
    local ok, value = pcall(GetServerTime)
    return ok and number(value) and value or nil
end

local function surface(frame, fill, border)
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    frame:SetBackdropColor(fill[1], fill[2], fill[3], fill[4] or 1)
    border = border or { 0.20, 0.23, 0.28 }
    frame:SetBackdropBorderColor(border[1], border[2], border[3], 1)
end

local function label(parent, font, x, y, width, height, rgb)
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    text:SetPoint("TOPLEFT", x, -y)
    text:SetSize(width, height)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetWordWrap(true)
    rgb = rgb or WHITE
    text:SetTextColor(rgb[1], rgb[2], rgb[3])
    return text
end

local function panel(parent, x, y, width, height)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetPoint("TOPLEFT", x, -y)
    frame:SetSize(width, height)
    surface(frame, { 0.075, 0.09, 0.115 })
    return frame
end

-- Queue presentation and optional actions must not enter duel-aborting recovery.
function QueueUI:Run(callback)
    local ok, result, reason = pcall(callback)
    if ok then return true, result, reason end
    if self.frame then pcall(self.frame.Hide, self.frame) end
    pcall(function()
        FD.Debug:Print(L["Could not display the duel queue. Try /duelrating queue again."])
        if readable(result) then FD.Debug:Log("queue window error", result) end
    end)
    return false
end

function QueueUI:GetStatus()
    if not FD.queue or type(FD.queue.GetStatus) ~= "function" then
        return { state = "IDLE", reason = L["The duel queue is unavailable."], settings = {}, unavailable = true }
    end
    local status = FD.queue:GetStatus()
    if type(status) ~= "table" then error("Queue status is unavailable") end
    return status
end

-- Action notices are shown on their own line and expire on the next state
-- change or after a few seconds, so they never hide the live queue status.
function QueueUI:Notice(text)
    self.notice = text
    self.noticeAt = serverTime()
    self.noticeState = self:GetStatus().state
end

function QueueUI:Action(method, argument)
    if not FD.queue or type(FD.queue[method]) ~= "function" then
        self:Notice(L["The duel queue is unavailable."])
    else
        local success, reason = FD.queue[method](FD.queue, argument)
        if success == false then self:Notice(reason or L["This queue action is unavailable."]) else self.notice = nil end
    end
    self:CloseDropdown()
    self:Refresh()
end

function QueueUI:Configure(changes)
    if self:GetStatus().state ~= "IDLE" and changes.autoAcceptQueueInvite == nil then
        self:Notice(L["Leave the queue before changing your search criteria."])
        self:CloseDropdown()
        return self:Refresh()
    end
    self:Action("Configure", changes)
end

function QueueUI:CaptureVenue()
    if self:GetStatus().state ~= "IDLE" then
        self:Notice(L["Leave the queue before saving a tested place."])
    elseif type(FD.CaptureQueueVenue) ~= "function" then
        self:Notice(L["Saving a tested place is unavailable."])
    else
        local success, reason = FD:CaptureQueueVenue()
        self:Notice(reason or (success == false and L["This place could not be saved."] or L["Tested place saved."]))
    end
    self:Refresh()
end

function QueueUI:CloseDropdown()
    if self.openDropdown then self.openDropdown.menu:Hide() end
    self.openDropdown = nil
    if self.dropdownDismiss then self.dropdownDismiss:Hide() end
end

function QueueUI:ToggleDropdown(control)
    local wasOpen = self.openDropdown == control
    self:CloseDropdown()
    if wasOpen or self:GetStatus().state ~= "IDLE" then return end
    local selected = control.selected()
    for index, item in ipairs(control.items) do
        local chosen = index == selected
        item.caption:SetText((chosen and "> " or "   ") .. control.options[index])
        local rgb = chosen and GOLD or WHITE
        item.caption:SetTextColor(rgb[1], rgb[2], rgb[3])
    end
    self.openDropdown = control
    self.dropdownDismiss:Show()
    control.menu:Show()
end

function QueueUI:Create()
    if self.frame then return end
    local frame = CreateFrame("Frame", "ForeverDuelQueue", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    surface(frame, { 0.055, 0.065, 0.085, 0.98 }, { 0.46, 0.36, 0.19 })
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() frame:StartMoving() end)
    frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    frame:SetScript("OnHide", function()
        frame:StopMovingOrSizing()
        self:CloseDropdown()
        self.elapsed, self.notice = 0, nil
    end)
    frame:SetScript("OnUpdate", function(_, elapsed)
        if not frame:IsShown() then return end
        self.elapsed = (self.elapsed or 0) + elapsed
        if self.elapsed >= 1 then
            self.elapsed = 0
            self:RefreshIfShown()
        end
    end)
    frame:Hide()
    self.frame = frame

    local function button(parent, text, width, x, y, handler)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(width, 26)
        b:SetPoint("TOPLEFT", x, -y)
        b:SetText(text)
        b:SetScript("OnClick", function()
            self:Run(function() handler(); self:CloseDropdown() end)
        end)
        return b
    end
    self.dropdownDismiss = CreateFrame("Button", nil, frame)
    self.dropdownDismiss:SetPoint("TOPLEFT", UIParent, "TOPLEFT")
    self.dropdownDismiss:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT")
    self.dropdownDismiss:SetFrameStrata("DIALOG")
    self.dropdownDismiss:SetScript("OnClick", function() self:Run(function() self:CloseDropdown() end) end)
    self.dropdownDismiss:Hide()
    local function dropdown(parent, width, x, y, options, selected, choose)
        local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        control:SetSize(width, 26)
        control:SetPoint("TOPLEFT", x, -y)
        control:SetScript("OnClick", function() self:Run(function() self:ToggleDropdown(control) end) end)
        label(control, "GameFontHighlightSmall", width - 17, 7, 12, 16, MUTED):SetText("v")
        control.options, control.selected, control.items = options, selected, {}
        local menu = CreateFrame("Frame", nil, self.dropdownDismiss, "BackdropTemplate")
        menu:SetPoint("TOPLEFT", control, "BOTTOMLEFT", 0, -2)
        menu:SetSize(width, #options * 26 + 8)
        menu:EnableMouse(true)
        menu:SetClampedToScreen(true)
        surface(menu, { 0.065, 0.075, 0.095, 1 }, { 0.46, 0.36, 0.19 })
        for index, text in ipairs(options) do
            local choice = index
            local item = CreateFrame("Button", nil, menu)
            item:SetSize(width - 8, 26)
            item:SetPoint("TOPLEFT", 4, -(4 + (index - 1) * 26))
            item:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            item.caption = label(item, "GameFontHighlightSmall", 6, 7, width - 20, 18)
            item.caption:SetText(text)
            item:SetScript("OnClick", function() self:Run(function() choose(choice) end) end)
            control.items[index] = item
        end
        control.menu = menu
        menu:Hide()
        return control
    end
    label(frame, "GameFontNormalLarge", 24, 23, 470, 25, GOLD):SetText("ForeverDuelersGuild")
    label(frame, "GameFontHighlightSmall", 24, 51, 460, 18, MUTED):SetText(L["RATED DUEL QUEUE"])
    self.overview = button(frame, L["Your record"], 120, 568, 25, function()
        if FD.Profile then FD.Profile:Toggle() end
        frame:Hide()
    end)
    self.close = button(frame, L["Close"], 72, 704, 25, function() frame:Hide() end)

    local criteria = panel(frame, 24, 85, 752, 212)
    label(criteria, "GameFontHighlightSmall", 16, 13, 710, 18, GOLD):SetText(L["SEARCH CRITERIA  /  Change before joining"])
    self.scopes = {}
    for index, scope in ipairs(SCOPES) do
        local selectedScope = scope
        self.scopes[scope] = button(criteria, L[SCOPE_NAMES[scope]], 232, 16 + (index - 1) * 244, 38,
            function() self:Configure({ scope = selectedScope }) end)
    end
    self.scopeHint = label(criteria, "GameFontHighlightSmall", 16, 73, 720, 38, MUTED)
    label(criteria, "GameFontHighlightSmall", 16, 121, 345, 16, MUTED):SetText(L["RULESET  /  AUTOMATIC"])
    label(criteria, "GameFontHighlightSmall", 382, 121, 345, 16, MUTED):SetText(L["MAXIMUM LEVEL DIFFERENCE"])
    self.ruleset = label(criteria, "GameFontHighlight", 16, 147, 354, 22, GOLD)
    local levels = { L["Same level"] }
    for gap = 1, 5 do levels[#levels + 1] = FD.Locale:Format(gap == 1 and "Up to %d level" or "Up to %d levels", gap) end
    self.levelGap = dropdown(criteria, 354, 382, 142, levels,
        function() return ((self:GetStatus().settings or {}).levelGap or 0) + 1 end,
        function(index) self:Configure({ levelGap = index - 1 }) end)
    self.autoAccept = CreateFrame("CheckButton", nil, criteria, "UICheckButtonTemplate")
    self.autoAccept:SetSize(24, 24)
    self.autoAccept:SetPoint("TOPLEFT", 12, -178)
    self.autoAccept:SetScript("OnClick", function()
        self:Run(function() self:Configure({ autoAcceptQueueInvite = not self:GetStatus().autoAccept }) end)
    end)
    label(criteria, "GameFontHighlightSmall", 42, 183, 690, 18, WHITE)
        :SetText(L["Accept the group invitation of a matched queue opponent automatically"])

    self.help = label(frame, "GameFontHighlightSmall", 24, 308, 752, 52, MUTED)
    local statusPanel = panel(frame, 24, 366, 752, 168)
    self.status = label(statusPanel, "GameFontHighlightLarge", 16, 13, 720, 27, GOLD)
    self.reason = label(statusPanel, "GameFontHighlightSmall", 16, 45, 720, 34, WHITE)
    self.lastMatch = label(statusPanel, "GameFontHighlightSmall", 16, 81, 720, 30, MUTED)
    self.cleanup = label(statusPanel, "GameFontHighlightSmall", 16, 113, 720, 18, MUTED)
    self.noticeText = label(statusPanel, "GameFontHighlightSmall", 16, 133, 720, 16, NOTICE)
    self.timer = label(statusPanel, "GameFontHighlightSmall", 16, 150, 470, 16, MUTED)
    self.discovery = label(statusPanel, "GameFontHighlightSmall", 498, 150, 238, 16, MUTED)
    self.discovery:SetJustifyH("RIGHT")

    local matchPanel = panel(frame, 24, 546, 752, 156)
    self.opponent = label(matchPanel, "GameFontHighlight", 16, 13, 720, 28)
    self.venue = label(matchPanel, "GameFontHighlightSmall", 16, 48, 720, 32, GOLD)
    self.arrival = label(matchPanel, "GameFontHighlightSmall", 16, 91, 720, 20, MUTED)
    self.matchHelp = label(matchPanel, "GameFontHighlightSmall", 16, 115, 720, 34, MUTED)
    self.join = button(frame, L["Join queue"], 170, 24, 714, function()
        self:Action(self:GetStatus().state == "IDLE" and "Join" or "Leave")
    end)
    self.waypoint = button(frame, L["Show waypoint"], 170, 218, 714, function() self:Action("Waypoint") end)
    self.challenge = button(frame, L["Request duel"], 170, 412, 714, function() self:Action("Challenge") end)
    self.leaveGroup = button(frame, L["Leave group"], 170, 606, 714, function() self:Action("LeaveGroup") end)
    self.saveVenue = button(frame, L["Save tested place"], 200, 24, 758, function() self:CaptureVenue() end)
    self.setup = label(frame, "GameFontHighlightSmall", 240, 754, 536, 42, MUTED)
    self.setup:SetText(L["After a successful ordinary duel, leave the party and save this spot within five minutes. Place details are filled automatically and sent to your test partner."])
    UISpecialFrames[#UISpecialFrames + 1] = "ForeverDuelQueue"
end

local function matchHelp(state, status, name)
    if state == "INVITING" then return FD.Locale:Format("Waiting for %s to accept your group invitation.", name) end
    if state == "INVITED" then
        return FD.Locale:Format("Accept the group invitation from %s to start your rated queue match.", name)
            .. (status.autoAccept and " " .. L["Automatic acceptance is on."] or "")
    end
    if state == "GROUPING" or state == "PLANNING" then
        return FD.Locale:Format("Confirming the match and the meeting place with the client of %s.", name)
    end
    if state == "READY" then
        local text = status.coordinator and L["Request a normal duel. Both players still explicitly accept rated in the duel dialog."]
            or FD.Locale:Format("Waiting for %s to send the duel request. Both players still explicitly accept rated in the duel dialog.", name)
        return status.colocation and text .. " " .. plain(status.colocation) or text
    end
    if state == "TRAVELLING" then return L["Both players must arrive before the timer expires. A cancelled queue match changes no rating."] end
    if state == "DUEL" then return L["The rated duel flow now controls this match."] end
    return L["The queue chooses a tested meeting place that both players have saved."]
end

function QueueUI:Refresh()
    local status = self:GetStatus()
    local state, settings = status.state or "IDLE", status.settings or {}
    local idle = state == "IDLE" and not status.unavailable
    local now = serverTime()
    if state ~= "IDLE" then self:CloseDropdown() end
    if self.notice and (state ~= self.noticeState or not now or not self.noticeAt or now - self.noticeAt >= NOTICE_SECONDS) then
        self.notice = nil
    end
    for _, scope in ipairs(SCOPES) do
        self.scopes[scope]:SetEnabled(idle)
        self.scopes[scope]:SetText((scope == (settings.scope or "ZONE") and "> " or "") .. L[SCOPE_NAMES[scope]])
    end
    self.scopeHint:SetText(L["Choose how far your search should reach. Discovery includes reachable addon users within your selected scope."])
    local rulesetName = readable(settings.ruleset) and RULESET_NAMES[settings.ruleset]
    self.ruleset:SetText(rulesetName and FD.Locale:Format("%s (automatic)", L[rulesetName]) or L["Detecting ruleset..."])
    local gap = number(settings.levelGap) and settings.levelGap or 0
    self.levelGap:SetEnabled(idle)
    self.levelGap:SetText(gap == 0 and L["Same level"] or FD.Locale:Format(gap == 1 and "Up to %d level" or "Up to %d levels", gap))
    self.autoAccept:SetChecked(status.autoAccept == true)
    self.autoAccept:SetEnabled(not status.unavailable)
    local movement = number(status.level) and status.level >= 40 and L["Normal mount (+60%)"] or L["On foot"]
    self.help:SetText(L["Rating range widens from +/-100 to +/-200 to +/-400 while you wait. Max-level and leveling pools stay separate."] .. "\n"
        .. FD.Locale:Format("Travel estimate: %s. Travel is limited to 15 minutes; straight-line estimates do not account for terrain or routes.", movement))
    self.status:SetText(STATE_NAMES[state] and L[STATE_NAMES[state]] or plain(state))
    local reason = status.reason
    if idle and not settings.ruleset then reason = settings.rulesetReason or L["Waiting for automatic ruleset detection."] end
    self.reason:SetText(plain(reason or ""))
    local cancel = type(status.cancel) == "table" and status.cancel or nil
    self.lastMatch:SetText(cancel and cancel.text and state ~= "IDLE" and state ~= "CLEANUP"
        and FD.Locale:Format("Last match: %s", plain(cancel.text)) or "")
    self.cleanup:SetText(status.cleanupStatus and plain(status.cleanupStatus) or "")
    self.noticeText:SetText(self.notice and plain(self.notice) or "")
    local timer = ""
    if now and number(status.deadline) then
        timer = FD.Locale:Format("Time remaining: %s", duration(status.deadline - now))
    elseif now and number(status.cooldownUntil) and status.cooldownUntil > now then
        timer = FD.Locale:Format("Queue cooldown: %s", duration(status.cooldownUntil - now))
    elseif now and number(status.queuedAt) and state ~= "IDLE" then
        timer = FD.Locale:Format("Waiting: %s", duration(now - status.queuedAt))
    end
    if number(status.ratingWindow) and state == "SEARCHING" then
        timer = timer .. (timer ~= "" and "  /  " or "") .. FD.Locale:Format("Rating +/-%d", status.ratingWindow)
    end
    self.timer:SetText(timer)
    self.discovery:SetText(number(status.discovered) and FD.Locale:Format("Queue profiles found: %d", status.discovered) or "")
    local opponent = type(status.opponent) == "table" and status.opponent or nil
    local name = opponent and plain(opponent.fullName or opponent.name or L["Unknown"]) or nil
    self.opponent:SetText(name and FD.Locale:Format("Opponent: %s", name) or L["Opponent: waiting for a match"])
    local venue = type(status.venue) == "table" and status.venue or nil
    local venueText = venue and FD.Locale:Format("Venue: %s", plain(venue.name or venue.id or L["Duel venue"])) or L["Venue: chosen after matching"]
    if venue and number(venue.mapX) and number(venue.mapY) then
        venueText = venueText .. string.format("  (%.1f, %.1f)", venue.mapX * 100, venue.mapY * 100)
    end
    if not venue and status.venueCount == 0 then
        venueText = L["No tested places saved yet. Complete an ordinary duel here, then use Save tested place."]
    end
    self.venue:SetText(venueText)
    local arrival = ""
    if venue then
        arrival = FD.Locale:Format("You: %s  /  Opponent: %s", status.ownArrived and L["arrived"] or L["travelling"],
            status.peerArrived and L["arrived"] or L["travelling"])
    end
    self.arrival:SetText(arrival)
    self.arrival:SetTextColor(unpack(status.ownArrived and status.peerArrived and GREEN or MUTED))
    self.matchHelp:SetText(matchHelp(state, status, name))
    self.join:SetText(state == "IDLE" and L["Join queue"] or L["Leave queue"])
    local coolingDown = state == "IDLE" and now and number(status.cooldownUntil) and status.cooldownUntil > now
    self.join:SetEnabled(not status.unavailable and not coolingDown and state ~= "DUEL")
    self.waypoint:SetEnabled(not status.unavailable and venue ~= nil and (state == "TRAVELLING" or state == "READY"))
    self.challenge:SetEnabled(not status.unavailable and state == "READY" and status.coordinator == true
        and now ~= nil and number(status.deadline) and now < status.deadline)
    self.leaveGroup:SetEnabled(not status.unavailable and status.groupAction == true)
    self.saveVenue:SetEnabled(idle)
end

function QueueUI:Show()
    return self:Run(function()
        self:Create()
        local scale = math.min(1, (UIParent:GetWidth() - 40) / WIDTH, (UIParent:GetHeight() - 40) / HEIGHT)
        self.frame:SetScale(math.max(0.1, scale))
        self:Refresh()
        self.frame:Show()
        if FD.Profile and FD.Profile.frame then FD.Profile.frame:Hide() end
        if FD.Zone and FD.Zone.frame then FD.Zone.frame:Hide() end
    end)
end

function QueueUI:Toggle()
    if self.frame and self.frame:IsShown() then return self:Run(function() self.frame:Hide() end) end
    return self:Show()
end

function QueueUI:RefreshIfShown()
    if self.frame and self.frame:IsShown() then return self:Run(function() self:Refresh() end) end
end
