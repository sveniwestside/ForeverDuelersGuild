local _, FD = ...
FD.Zone = { page = 1, pageSize = 8, search = "", classIndex = 1, windowIndex = 1, sortIndex = 1 }
local Zone = FD.Zone
local WIDTH, HEIGHT = 800, 676
local GOLD = { 0.94, 0.75, 0.38 }
local MUTED = { 0.61, 0.65, 0.70 }
local WHITE = { 0.92, 0.94, 0.97 }
local CLASS_FILTERS = { "ALL", "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
    "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local CLASS_NAMES = { ALL = "All", WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter",
    ROGUE = "Rogue", PRIEST = "Priest", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid" }
local RATING_WINDOWS = { 0, 100, 200, 400 }
local SORT_LABELS = { "Sort: Name", "Sort: Highest rating / mode", "Sort: Closest to your rating" }

local function className(class)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or CLASS_NAMES[class]
end

local function mode(bracket)
    return bracket == "MAX_LEVEL" and "Max level" or bracket == "LEVELING" and "Leveling" or "Unknown"
end

local function samePool(a, b)
    return a and b and a.bracket and a.bracket == b.bracket and a.maxLevel == b.maxLevel
end

local function byName(a, b)
    local left, right = a.fullName:lower(), b.fullName:lower()
    return left == right and a.guid < b.guid or left < right
end

local function plain(value)
    return (tostring(value or ""):gsub("|", "||"))
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
    text:SetWordWrap(false)
    rgb = rgb or WHITE
    text:SetTextColor(rgb[1], rgb[2], rgb[3])
    return text
end

-- A failed browser or challenge must never enter Core's duel-aborting recovery.
function Zone:Run(callback)
    local ok, result = pcall(callback)
    if ok then return true, result end
    if self.frame then pcall(self.frame.Hide, self.frame) end
    pcall(function()
        FD.Debug:Print("Could not display players in your zone. Try /duelrating zone again.")
        if not FD.Wow or FD.Wow:Readable(result) then FD.Debug:Log("zone browser error", result) end
    end)
    return false
end

function Zone:FilteredPlayers()
    local all, players, own = FD.Presence:GetPlayers(), {}, FD.Presence:GetOwnPlayer()
    local query, class = self.search:lower(), CLASS_FILTERS[self.classIndex]
    local window = RATING_WINDOWS[self.windowIndex]
    for _, player in ipairs(all) do
        local comparable = samePool(player, own)
        if (query == "" or player.fullName:lower():find(query, 1, true))
            and (class == "ALL" or player.classFile == class)
            and (window == 0 or (comparable and math.abs(player.rating - own.rating) <= window))
            and (not self.ratedOnly or (own and FD.Rating:Eligible(own, player))) then
            players[#players + 1] = player
        end
    end
    table.sort(players, function(a, b)
        if self.sortIndex == 1 then return byName(a, b) end
        local ownA, ownB = samePool(a, own), samePool(b, own)
        if ownA ~= ownB then return ownA and true or false end
        if self.sortIndex == 3 then
            -- Other modes have no meaningful rating distance from this player.
            if ownA then
                local da, db = math.abs(a.rating - own.rating), math.abs(b.rating - own.rating)
                if da ~= db then return da < db end
            end
        else
            -- Highest ratings are grouped by mode and level cap before sorting.
            if a.bracket ~= b.bracket then return (a.bracket or "") < (b.bracket or "") end
            if a.maxLevel ~= b.maxLevel then return (a.maxLevel or 0) < (b.maxLevel or 0) end
            if a.rating ~= b.rating then return a.rating > b.rating end
        end
        return byName(a, b)
    end)
    return players, #all
end

function Zone:FiltersChanged()
    self:CloseDropdown()
    self.page = 1
    self:Refresh()
end

function Zone:CloseDropdown()
    if self.openDropdown then self.openDropdown.menu:Hide() end
    self.openDropdown = nil
    if self.dropdownDismiss then self.dropdownDismiss:Hide() end
end

function Zone:ToggleDropdown(control)
    local wasOpen = self.openDropdown == control
    self:CloseDropdown()
    if wasOpen then return end
    self.searchBox:ClearFocus()
    local selected = control.selected()
    for index, item in ipairs(control.items) do
        local current = index == selected
        item.caption:SetText((current and "> " or "   ") .. control.options[index])
        local color = current and GOLD or WHITE
        item.caption:SetTextColor(color[1], color[2], color[3])
    end
    self.openDropdown = control
    self.dropdownDismiss:Show()
    control.menu:Show()
end

function Zone:Create()
    if self.frame then return end
    local frame = CreateFrame("Frame", "ForeverDuelZone", UIParent, "BackdropTemplate")
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
    frame:SetScript("OnHide", function() frame:StopMovingOrSizing(); self:CloseDropdown() end)
    frame:Hide()

    local function button(parent, text, width, x, y, handler)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(width, 26)
        b:SetPoint("TOPLEFT", x, -y)
        b:SetText(text)
        b:SetScript("OnClick", function()
            self:Run(function()
                if b ~= self.openDropdown then self:CloseDropdown() end
                handler()
            end)
        end)
        return b
    end
    -- Addon-owned menus use the same basic frame APIs as the browser. The
    -- dismiss layer closes a menu on an outside click without starting a duel.
    self.dropdownDismiss = CreateFrame("Button", nil, frame)
    self.dropdownDismiss:SetPoint("TOPLEFT", UIParent, "TOPLEFT")
    self.dropdownDismiss:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT")
    self.dropdownDismiss:SetFrameStrata("DIALOG")
    self.dropdownDismiss:SetScript("OnClick", function() self:Run(function() self:CloseDropdown() end) end)
    self.dropdownDismiss:Hide()
    local function dropdown(text, width, x, y, options, selected, choose)
        local control
        control = button(frame, text, width, x, y, function() self:ToggleDropdown(control) end)
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
            item:SetScript("OnClick", function()
                self:Run(function() choose(choice); self:FiltersChanged() end)
            end)
            control.items[index] = item
        end
        control.menu = menu
        menu:Hide()
        return control
    end
    label(frame, "GameFontNormalLarge", 24, 23, 420, 25, GOLD):SetText("ForeverDuelersGuild")
    label(frame, "GameFontHighlightSmall", 24, 51, 440, 18, MUTED):SetText("PLAYERS IN ZONE  /  ForeverDuelersGuild discovery")
    self.overview = button(frame, "Your record", 120, 568, 25, function()
        FD.Profile:Toggle()
    end)
    self.close = button(frame, "Close", 72, 704, 25, function() frame:Hide() end)
    self.status = label(frame, "GameFontHighlight", 24, 88, 752, 40, GOLD)
    self.status:SetWordWrap(true)
    local help = label(frame, "GameFontHighlightSmall", 24, 133, 752, 36, MUTED)
    help:SetWordWrap(true)
    help:SetText("Rated: same mode and no more than 5 levels apart. Rating distance uses your current mode. Discovery is advisory; move close to duel. Both players still choose rated separately.")
    self.searchBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    self.searchBox:SetSize(230, 26)
    self.searchBox:SetPoint("TOPLEFT", 30, -180)
    self.searchBox:SetAutoFocus(false)
    self.searchBox:SetMaxLetters(80)
    self.searchBox:SetText(self.search)
    self.searchBox:SetScript("OnTextChanged", function(box)
        self:Run(function() self.search = box:GetText() or ""; self:FiltersChanged() end)
    end)
    self.searchBox:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
    self.searchBox:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
    label(frame, "GameFontHighlightSmall", 34, 168, 230, 12, MUTED):SetText("SEARCH NAME")
    local classes = {}
    for index, class in ipairs(CLASS_FILTERS) do classes[index] = className(class) end
    self.classFilter = dropdown("Class: All", 232, 280, 180, classes,
        function() return self.classIndex end, function(index) self.classIndex = index end)
    local windows = { "All ratings" }
    for index = 2, #RATING_WINDOWS do windows[index] = "+/- " .. RATING_WINDOWS[index] .. " (your mode)" end
    self.ratingFilter = dropdown("Rating: All", 250, 526, 180, windows,
        function() return self.windowIndex end, function(index) self.windowIndex = index end)
    self.sortFilter = dropdown(SORT_LABELS[1], 240, 24, 214,
        { "Name", "Highest rating / mode", "Closest to your rating" },
        function() return self.sortIndex end, function(index) self.sortIndex = index end)
    self.eligibleFilter = dropdown("Rated eligible: All", 232, 280, 214, { "All players", "Rated eligible only" },
        function() return self.ratedOnly and 2 or 1 end, function(index) self.ratedOnly = index == 2 end)
    self.resetFilters = button(frame, "Reset filters", 250, 526, 214, function()
        self.search, self.classIndex, self.windowIndex, self.sortIndex, self.ratedOnly = "", 1, 1, 1, false
        self.searchBox:SetText("")
        self:FiltersChanged()
    end)
    label(frame, "GameFontHighlightSmall", 36, 252, 300, 18, MUTED):SetText("PLAYER")
    label(frame, "GameFontHighlightSmall", 352, 252, 160, 18, MUTED):SetText("LEVEL / MODE")
    label(frame, "GameFontHighlightSmall", 520, 252, 108, 18, MUTED):SetText("RATING")
    self.rows = {}
    for index = 1, self.pageSize do
        local row = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        row:SetPoint("TOPLEFT", 24, -(274 + (index - 1) * 40))
        row:SetSize(752, 38)
        local shade = index % 2 == 0 and 0.075 or 0.095
        surface(row, { shade, shade + 0.012, shade + 0.025 })
        row.name = label(row, "GameFontHighlight", 12, 11, 304, 20)
        row.level = label(row, "GameFontHighlightSmall", 328, 12, 158, 20, MUTED)
        row.rating = label(row, "GameFontHighlight", 496, 11, 108, 20, GOLD)
        row.duel = button(row, "Duel", 96, 640, 6, function()
            if not row.guid then return end
            local success, reason = FD.Presence:Challenge(row.guid)
            if not success then
                FD.Debug:Print(plain(reason or "Duel unavailable. Move close to the player and try again."))
            end
        end)
        self.rows[index] = row
    end
    self.empty = label(frame, "GameFontHighlight", 48, 353, 704, 100, MUTED)
    self.empty:SetWordWrap(true)
    self.empty:SetText("No ForeverDuelersGuild players discovered in this zone yet.\n\nLoading the shared player directory and checking its members. Both players need ForeverDuelersGuild 0.4.3 for this search; targeting remains a fallback.")
    self.previous = button(frame, "Previous", 100, 24, 616, function()
        self.page = self.page - 1
        self:Refresh()
    end)
    self.next = button(frame, "Next", 100, 676, 616, function()
        self.page = self.page + 1
        self:Refresh()
    end)
    self.pageLabel = label(frame, "GameFontHighlightSmall", 188, 623, 424, 20, MUTED)
    self.pageLabel:SetJustifyH("CENTER")
    self.frame = frame
    UISpecialFrames[#UISpecialFrames + 1] = "ForeverDuelZone"
end

function Zone:Refresh()
    local players, total = self:FilteredPlayers()
    local class = CLASS_FILTERS[self.classIndex]
    self.classFilter:SetText("Class: " .. className(class))
    local window = RATING_WINDOWS[self.windowIndex]
    self.ratingFilter:SetText(window == 0 and "Rating: All" or "Rating: +/- " .. window .. " (your mode)")
    self.sortFilter:SetText(SORT_LABELS[self.sortIndex])
    self.eligibleFilter:SetText(self.ratedOnly and "Rated eligible: Only" or "Rated eligible: All")
    local pages = math.max(1, math.ceil(#players / self.pageSize))
    self.page = math.max(1, math.min(pages, self.page))
    self.status:SetText(plain(FD.Presence:GetStatus()))
    for index, row in ipairs(self.rows) do
        local player = players[(self.page - 1) * self.pageSize + index]
        row.guid = player and player.guid or nil
        if player then
            row.name:SetText(plain(player.fullName))
            local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[player.classFile]
            row.name:SetTextColor(c and c.r or WHITE[1], c and c.g or WHITE[2], c and c.b or WHITE[3])
            row.rating:SetText(tostring(player.rating))
            row.level:SetText("Lv " .. tostring(player.level or "?") .. " / " .. mode(player.bracket))
            row:Show()
        else
            row:Hide()
        end
    end
    if #players > 0 then self.empty:Hide() else
        self.empty:SetText(total > 0 and "No players match these filters.\n\nTry a broader search or reset the filters."
            or "No ForeverDuelersGuild players discovered in this zone yet.\n\nLoading the shared player directory and checking its members. Both players need ForeverDuelersGuild 0.4.3 for this search; targeting remains a fallback.")
        self.empty:Show()
    end
    self.previous:SetEnabled(self.page > 1)
    self.next:SetEnabled(self.page < pages)
    self.pageLabel:SetText(string.format("Page %d / %d  /  %d of %d players", self.page, pages, #players, total))
end

function Zone:Show()
    return self:Run(function()
        self:Create()
        local scale = math.min(1, (UIParent:GetWidth() - 40) / WIDTH, (UIParent:GetHeight() - 40) / HEIGHT)
        self.frame:SetScale(math.max(0.1, scale))
        self.page = 1
        self:Refresh()
        self.frame:Show()
        if FD.Profile and FD.Profile.frame then FD.Profile.frame:Hide() end
    end)
end

function Zone:Toggle()
    if self.frame and self.frame:IsShown() then
        return self:Run(function() self.frame:Hide() end)
    end
    return self:Show()
end

function Zone:RefreshIfShown()
    if self.frame and self.frame:IsShown() then self:Run(function() self:Refresh() end) end
end
