local _, FD = ...
FD.QueueUI = {}
local QueueUI = FD.QueueUI
local WIDTH, HEIGHT = 800, 766
local GOLD = { 0.94, 0.75, 0.38 }
local MUTED = { 0.61, 0.65, 0.70 }
local WHITE = { 0.92, 0.94, 0.97 }
local GREEN = { 0.36, 0.85, 0.61 }
local SCOPES = { "ZONE", "CONTINENT", "RULESET" }
local SCOPE_NAMES = { ZONE = "Zone", CONTINENT = "Continent", RULESET = "Whole ruleset" }
local RULESET_NAMES = { NORMAL = "Normal", PVP = "PvP", RP = "RP", HARDCORE = "Hardcore" }
local STATE_NAMES = {
    IDLE = "Not queued", SEARCHING = "Searching for an opponent", PAUSED = "Search paused",
    RESERVING = "Confirming a match", GROUPING = "Forming your duel party",
    PLANNING = "Choosing a duel venue", TRAVELLING = "Travel to the duel venue",
    READY = "Both players have arrived", DUEL = "Duel in progress", CLEANUP = "Finishing the queue match",
}

local function readable(value)
    return not FD.Wow or FD.Wow:Readable(value)
end

local function plain(value)
    if not readable(value) then return "Unavailable" end
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
        FD.Debug:Print("Could not display the duel queue. Try /duelrating queue again.")
        if readable(result) then FD.Debug:Log("queue window error", result) end
    end)
    return false
end

function QueueUI:GetStatus()
    if not FD.queue or type(FD.queue.GetStatus) ~= "function" then
        return { state = "IDLE", reason = "The duel queue is unavailable.", settings = {}, unavailable = true }
    end
    local status = FD.queue:GetStatus()
    if type(status) ~= "table" then error("Queue status is unavailable") end
    return status
end

function QueueUI:Action(method, argument)
    if not FD.queue or type(FD.queue[method]) ~= "function" then
        self.notice = "The duel queue is unavailable."
    else
        local success, reason = FD.queue[method](FD.queue, argument)
        self.notice = success == false and (reason or "This queue action is unavailable.") or nil
    end
    self:CloseDropdown()
    self:Refresh()
end

function QueueUI:Configure(changes)
    if self:GetStatus().state ~= "IDLE" then
        self.notice = "Leave the queue before changing your search criteria."
        self:CloseDropdown()
        return self:Refresh()
    end
    self:Action("Configure", changes)
end

function QueueUI:CaptureVenue()
    if self:GetStatus().state ~= "IDLE" then
        self.notice = "Leave the queue before saving a tested place."
    elseif type(FD.CaptureQueueVenue) ~= "function" then
        self.notice = "Saving a tested place is unavailable."
    else
        local success, reason = FD:CaptureQueueVenue()
        self.notice = reason or (success == false and "This place could not be saved." or "Tested place saved.")
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
        self.elapsed = 0
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
    label(frame, "GameFontHighlightSmall", 24, 51, 460, 18, MUTED):SetText("RATED DUEL QUEUE")
    self.overview = button(frame, "Your record", 120, 568, 25, function()
        if FD.Profile then FD.Profile:Toggle() end
        frame:Hide()
    end)
    self.close = button(frame, "Close", 72, 704, 25, function() frame:Hide() end)

    local criteria = panel(frame, 24, 85, 752, 182)
    label(criteria, "GameFontHighlightSmall", 16, 13, 710, 18, GOLD):SetText("SEARCH CRITERIA  /  Change before joining")
    self.scopes = {}
    for index, scope in ipairs(SCOPES) do
        local selectedScope = scope
        self.scopes[scope] = button(criteria, SCOPE_NAMES[scope], 232, 16 + (index - 1) * 244, 38,
            function() self:Configure({ scope = selectedScope }) end)
    end
    self.scopeHint = label(criteria, "GameFontHighlightSmall", 16, 73, 720, 38, MUTED)
    label(criteria, "GameFontHighlightSmall", 16, 121, 345, 16, MUTED):SetText("RULESET  /  AUTOMATIC")
    label(criteria, "GameFontHighlightSmall", 382, 121, 345, 16, MUTED):SetText("MAXIMUM LEVEL DIFFERENCE")
    self.ruleset = label(criteria, "GameFontHighlight", 16, 147, 354, 22, GOLD)
    local levels = { "Same level", "Up to 1 level", "Up to 2 levels", "Up to 3 levels", "Up to 4 levels", "Up to 5 levels" }
    self.levelGap = dropdown(criteria, 354, 382, 142, levels,
        function() return ((self:GetStatus().settings or {}).levelGap or 0) + 1 end,
        function(index) self:Configure({ levelGap = index - 1 }) end)

    self.help = label(frame, "GameFontHighlightSmall", 24, 280, 752, 65, MUTED)
    local statusPanel = panel(frame, 24, 354, 752, 125)
    self.status = label(statusPanel, "GameFontHighlightLarge", 16, 13, 720, 27, GOLD)
    self.reason = label(statusPanel, "GameFontHighlightSmall", 16, 49, 720, 36, WHITE)
    self.timer = label(statusPanel, "GameFontHighlightSmall", 16, 97, 470, 18, MUTED)
    self.discovery = label(statusPanel, "GameFontHighlightSmall", 498, 97, 238, 18, MUTED)
    self.discovery:SetJustifyH("RIGHT")

    local matchPanel = panel(frame, 24, 491, 752, 156)
    self.opponent = label(matchPanel, "GameFontHighlight", 16, 13, 720, 28)
    self.venue = label(matchPanel, "GameFontHighlightSmall", 16, 48, 720, 32, GOLD)
    self.arrival = label(matchPanel, "GameFontHighlightSmall", 16, 91, 720, 20, MUTED)
    self.matchHelp = label(matchPanel, "GameFontHighlightSmall", 16, 119, 720, 28, MUTED)
    self.join = button(frame, "Join queue", 170, 24, 662, function()
        self:Action(self:GetStatus().state == "IDLE" and "Join" or "Leave")
    end)
    self.invite = button(frame, "Invite opponent", 170, 218, 662, function() self:Action("Invite") end)
    self.waypoint = button(frame, "Show waypoint", 170, 412, 662, function() self:Action("Waypoint") end)
    self.challenge = button(frame, "Request duel", 170, 606, 662, function() self:Action("Challenge") end)
    self.saveVenue = button(frame, "Save tested place", 200, 24, 709, function() self:CaptureVenue() end)
    self.setup = label(frame, "GameFontHighlightSmall", 240, 705, 536, 42, MUTED)
    self.setup:SetText("After a successful ordinary duel, leave the party and save this spot within five minutes. Place details are filled automatically and sent to your test partner.")
    UISpecialFrames[#UISpecialFrames + 1] = "ForeverDuelQueue"
end

function QueueUI:Refresh()
    local status = self:GetStatus()
    local state, settings = status.state or "IDLE", status.settings or {}
    local idle = state == "IDLE" and not status.unavailable
    if state ~= "IDLE" then self:CloseDropdown() end
    for _, scope in ipairs(SCOPES) do
        self.scopes[scope]:SetEnabled(idle)
        self.scopes[scope]:SetText((scope == (settings.scope or "ZONE") and "> " or "") .. SCOPE_NAMES[scope])
    end
    self.scopeHint:SetText("Choose how far your search should reach. Discovery includes reachable addon users within your selected scope.")
    local rulesetName = readable(settings.ruleset) and RULESET_NAMES[settings.ruleset]
    self.ruleset:SetText(rulesetName and rulesetName .. " (automatic)" or "Detecting ruleset...")
    local gap = number(settings.levelGap) and settings.levelGap or 0
    self.levelGap:SetEnabled(idle)
    self.levelGap:SetText(gap == 0 and "Same level" or "Up to " .. gap .. " levels")
    local movement = number(status.level) and status.level >= 40 and "Normal mount (+60%)" or "On foot"
    self.help:SetText("Rating range widens from +/-100 to +/-200 to +/-400 while you wait. Max-level and leveling pools stay separate.\nTravel estimate: "
        .. movement .. ". Travel is limited to 15 minutes; straight-line estimates do not account for terrain or routes.")
    self.status:SetText(STATE_NAMES[state] or plain(state))
    self.reason:SetText(plain(self.notice or (state == "IDLE" and not settings.ruleset and settings.rulesetReason)
        or status.reason or (state == "IDLE" and not settings.ruleset
        and "Waiting for automatic ruleset detection." or "")))
    local now = type(GetServerTime) == "function" and GetServerTime() or nil
    local timer = ""
    if number(now) and number(status.deadline) then
        timer = "Time remaining: " .. duration(status.deadline - now)
    elseif number(now) and number(status.cooldownUntil) and status.cooldownUntil > now then
        timer = "Queue cooldown: " .. duration(status.cooldownUntil - now)
    elseif number(now) and number(status.queuedAt) and state ~= "IDLE" then
        timer = "Waiting: " .. duration(now - status.queuedAt)
    end
    if number(status.ratingWindow) and state == "SEARCHING" then
        timer = timer .. (timer ~= "" and "  /  " or "") .. "Rating +/-" .. status.ratingWindow
    end
    self.timer:SetText(timer)
    self.discovery:SetText(number(status.discovered) and "Queue profiles found: " .. status.discovered or "")
    local opponent = type(status.opponent) == "table" and status.opponent or nil
    self.opponent:SetText(opponent and "Opponent: " .. plain(opponent.fullName or opponent.name or "Unknown")
        or "Opponent: waiting for a match")
    local venue = type(status.venue) == "table" and status.venue or nil
    local venueText = venue and "Venue: " .. plain(venue.name or venue.id or "Duel venue") or "Venue: chosen after matching"
    if venue and number(venue.mapX) and number(venue.mapY) then
        venueText = venueText .. string.format("  (%.1f, %.1f)", venue.mapX * 100, venue.mapY * 100)
    elseif venue and number(venue.mapID) then
        venueText = venueText .. "  /  Map " .. venue.mapID
    end
    if not venue and status.venueCount == 0 then
        venueText = "No tested places saved yet. Complete an ordinary duel here, then use Save tested place."
    end
    self.venue:SetText(venueText)
    local arrival = ""
    if venue then
        arrival = "You: " .. (status.ownArrived and "arrived" or "travelling")
            .. "  /  Opponent: " .. (status.peerArrived and "arrived" or "travelling")
    end
    self.arrival:SetText(arrival)
    self.arrival:SetTextColor(unpack(status.ownArrived and status.peerArrived and GREEN or MUTED))
    self.matchHelp:SetText(state == "READY" and "Request a normal duel. Both players still explicitly accept rated in the duel dialog."
        or state == "GROUPING" and (status.inviter and "Your opponent must accept the native party invitation."
            or "Accept your matched opponent's native party invitation.")
        or venue and "Both players must arrive before the timer expires. A cancelled queue match changes no rating."
        or "The queue chooses a suitable meeting place from both players' positions.")
    self.join:SetText(state == "IDLE" and "Join queue" or "Leave queue")
    local coolingDown = state == "IDLE" and number(now) and number(status.cooldownUntil) and status.cooldownUntil > now
    self.join:SetEnabled(not status.unavailable and not coolingDown and state ~= "DUEL" and state ~= "CLEANUP")
    self.invite:SetEnabled(not status.unavailable and state == "GROUPING" and status.inviter == true and status.inviteFallback == true)
    self.waypoint:SetEnabled(not status.unavailable and venue ~= nil and (state == "TRAVELLING" or state == "READY"))
    self.challenge:SetEnabled(not status.unavailable and state == "READY" and number(now)
        and number(status.deadline) and now < status.deadline)
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
