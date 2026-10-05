local _, FD = ...
FD.Zone = { page = 1, pageSize = 8, search = "", classIndex = 1, windowIndex = 1, sortIndex = 1 }
local Zone = FD.Zone
local Widgets = FD.Widgets
local label, plain = Widgets.Label, FD.Native.Plain
local WIDTH, HEIGHT = 800, 676
local GOLD, MUTED, WHITE = Widgets.GOLD, Widgets.MUTED, Widgets.WHITE
local CLASS_FILTERS = { "ALL", "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
    "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local CLASS_NAMES = { ALL = "All", WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter",
    ROGUE = "Rogue", PRIEST = "Priest", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid" }
local RATING_WINDOWS = { 0, 100, 200, 400 }
local SORT_OPTIONS = { "Name", "Highest rating / mode", "Closest to your rating" }

local function L(key) return FD.L[key] end
local function Format(...) return FD.Locale:Format(...) end

local function className(class)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or L(CLASS_NAMES[class])
end

local function mode(bracket)
    return L(bracket == "MAX_LEVEL" and "Max level" or bracket == "LEVELING" and "Leveling" or "Unknown")
end

local function samePool(a, b)
    return a and b and a.bracket and a.bracket == b.bracket and a.maxLevel == b.maxLevel
end

local function byName(a, b)
    local left, right = a.fullName:lower(), b.fullName:lower()
    return left == right and a.guid < b.guid or left < right
end

local function emptyText()
    return L("No ForeverDuelersGuild players discovered in this zone yet.\n\nWhile this window is open, ForeverDuel channel members and your target are asked for their profiles. Click Refresh to ask again; targeting a player also works.")
end

-- A failed browser or challenge must never enter Core's duel-aborting recovery.
function Zone:Run(callback)
    return Widgets.Run(self, callback, L("Could not display players in your zone. Try /duelrating zone again."), "zone browser error")
end

function Zone:IsShown()
    return self.frame ~= nil and self.frame:IsShown() == true
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

Zone.CloseDropdown = Widgets.CloseDropdown

function Zone:ToggleDropdown(control)
    local wasOpen = self.openDropdown == control
    self:CloseDropdown()
    if wasOpen then return end
    self.searchBox:ClearFocus()
    Widgets.OpenDropdown(self, control)
end

function Zone:Create()
    if self.frame then return end
    local frame = Widgets.Window("ForeverDuelZone", WIDTH, HEIGHT, function() self:CloseDropdown() end)
    -- Every click closes an open menu first (ToggleDropdown does so itself).
    local function button(parent, text, width, x, y, handler)
        return Widgets.Button(parent, text, width, x, y, function()
            self:Run(function() self:CloseDropdown(); handler() end)
        end)
    end
    Widgets.DismissLayer(self, frame)
    local function dropdown(text, width, x, y, options, selected, choose)
        return Widgets.Dropdown(self, frame, text, width, x, y, options, selected,
            function(index) choose(index); self:FiltersChanged() end)
    end
    label(frame, "GameFontNormalLarge", 24, 23, 420, 25, GOLD):SetText("ForeverDuelersGuild")
    label(frame, "GameFontHighlightSmall", 24, 51, 420, 18, MUTED):SetText(L("PLAYERS IN ZONE  /  ForeverDuelersGuild discovery"))
    -- Explicit refresh: asks channel members and the target again now.
    self.refresh = button(frame, L("Refresh"), 92, 466, 25, function()
        FD.Presence:RefreshNow()
        self:Refresh()
    end)
    self.overview = button(frame, L("Your record"), 120, 568, 25, function()
        FD.Profile:Toggle()
    end)
    self.close = button(frame, L("Close"), 72, 704, 25, function() frame:Hide() end)
    self.status = label(frame, "GameFontHighlight", 24, 88, 752, 40, GOLD)
    self.status:SetWordWrap(true)
    local help = label(frame, "GameFontHighlightSmall", 24, 133, 752, 36, MUTED)
    help:SetWordWrap(true)
    help:SetText(L("Rated: same mode and no more than 5 levels apart. Rating distance uses your current mode. Discovery is advisory; move close to duel. Both players still choose rated separately."))
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
    label(frame, "GameFontHighlightSmall", 34, 168, 230, 12, MUTED):SetText(L("SEARCH NAME"))
    local classes = {}
    for index, class in ipairs(CLASS_FILTERS) do classes[index] = className(class) end
    self.classFilter = dropdown(Format("Class: %s", className("ALL")), 232, 280, 180, classes,
        function() return self.classIndex end, function(index) self.classIndex = index end)
    local windows = { L("All ratings") }
    for index = 2, #RATING_WINDOWS do windows[index] = Format("+/- %d (your mode)", RATING_WINDOWS[index]) end
    self.ratingFilter = dropdown(L("Rating: All"), 250, 526, 180, windows,
        function() return self.windowIndex end, function(index) self.windowIndex = index end)
    local sorts = {}
    for index, option in ipairs(SORT_OPTIONS) do sorts[index] = L(option) end
    self.sortFilter = dropdown(Format("Sort: %s", sorts[1]), 240, 24, 214, sorts,
        function() return self.sortIndex end, function(index) self.sortIndex = index end)
    self.eligibleFilter = dropdown(L("Rated eligible: All"), 232, 280, 214, { L("All players"), L("Rated eligible only") },
        function() return self.ratedOnly and 2 or 1 end, function(index) self.ratedOnly = index == 2 end)
    self.resetFilters = button(frame, L("Reset filters"), 250, 526, 214, function()
        self.search, self.classIndex, self.windowIndex, self.sortIndex, self.ratedOnly = "", 1, 1, 1, false
        self.searchBox:SetText("")
        self:FiltersChanged()
    end)
    label(frame, "GameFontHighlightSmall", 36, 252, 300, 18, MUTED):SetText(L("PLAYER"))
    label(frame, "GameFontHighlightSmall", 352, 252, 160, 18, MUTED):SetText(L("LEVEL / MODE"))
    label(frame, "GameFontHighlightSmall", 520, 252, 108, 18, MUTED):SetText(L("RATING"))
    self.rows = {}
    for index = 1, self.pageSize do
        local row = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        row:SetPoint("TOPLEFT", 24, -(274 + (index - 1) * 40))
        row:SetSize(752, 38)
        local shade = index % 2 == 0 and 0.075 or 0.095
        Widgets.Surface(row, { shade, shade + 0.012, shade + 0.025 })
        row.name = label(row, "GameFontHighlight", 12, 4, 304, 18)
        row.seen = label(row, "GameFontHighlightSmall", 12, 22, 304, 14, MUTED)
        row.level = label(row, "GameFontHighlightSmall", 328, 12, 158, 20, MUTED)
        row.rating = label(row, "GameFontHighlight", 496, 11, 108, 20, GOLD)
        row.duel = button(row, L("Duel"), 96, 640, 6, function()
            if not row.key then return end
            local success, reason = FD.Presence:Challenge(row.key)
            if not success then
                FD.Debug:Print(plain(reason or L("Duel unavailable. Move close to the player and try again.")))
            end
        end)
        self.rows[index] = row
    end
    self.empty = label(frame, "GameFontHighlight", 48, 353, 704, 100, MUTED)
    self.empty:SetWordWrap(true)
    self.empty:SetText(emptyText())
    self.previous = button(frame, L("Previous"), 100, 24, 616, function()
        self.page = self.page - 1
        self:Refresh()
    end)
    self.next = button(frame, L("Next"), 100, 676, 616, function()
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
    self.classFilter:SetText(Format("Class: %s", className(class)))
    local window = RATING_WINDOWS[self.windowIndex]
    self.ratingFilter:SetText(window == 0 and L("Rating: All") or Format("Rating: +/- %d (your mode)", window))
    self.sortFilter:SetText(Format("Sort: %s", L(SORT_OPTIONS[self.sortIndex])))
    self.eligibleFilter:SetText(self.ratedOnly and L("Rated eligible: Only") or L("Rated eligible: All"))
    local pages = math.max(1, math.ceil(#players / self.pageSize))
    self.page = math.max(1, math.min(pages, self.page))
    self.status:SetText(plain(FD.Presence:GetStatus()))
    local now = GetTime()
    for index, row in ipairs(self.rows) do
        local player = players[(self.page - 1) * self.pageSize + index]
        -- Rows are keyed by the authenticated sender name, not a GUID claim.
        row.key = player and player.fullName or nil
        if player then
            row.name:SetText(plain(player.fullName))
            local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[player.classFile]
            row.name:SetTextColor(c and c.r or WHITE[1], c and c.g or WHITE[2], c and c.b or WHITE[3])
            row.rating:SetText(tostring(player.rating))
            row.level:SetText(Format("Lv %s / %s", tostring(player.level or "?"), mode(player.bracket)))
            local age = type(player.lastSeen) == "number" and now - player.lastSeen or 0
            row.seen:SetText(age >= FD.Presence.STALE and Format("last seen %d s ago", math.floor(age)) or "")
            row:Show()
        else
            row:Hide()
        end
    end
    if #players > 0 then self.empty:Hide() else
        self.empty:SetText(total > 0 and L("No players match these filters.\n\nTry a broader search or reset the filters.")
            or emptyText())
        self.empty:Show()
    end
    self.previous:SetEnabled(self.page > 1)
    self.next:SetEnabled(self.page < pages)
    self.pageLabel:SetText(Format("Page %d / %d  /  %d of %d players", self.page, pages, #players, total))
end

function Zone:Show()
    return self:Run(function()
        self:Create()
        Widgets.Fit(self.frame, WIDTH, HEIGHT)
        self.page = 1
        self:Refresh()
        self.frame:Show()
        if FD.Profile and FD.Profile.frame then FD.Profile.frame:Hide() end
        -- An open browser is a reason to discover: run a pass now.
        if FD.Presence.Changed then FD.Presence:Changed() end
    end)
end

Zone.Toggle, Zone.RefreshIfShown = Widgets.Toggle, Widgets.RefreshIfShown

FD:RegisterCommand("zone", function() FD.Zone:Toggle() end, "Open the same-map player browser.", 2)
