local _, FD = ...
FD.Profile = { page = 1, pageSize = 8 }
local Profile = FD.Profile
local WIDTH, HEIGHT = 960, 812
local GOLD = { 0.94, 0.75, 0.38 }
local MUTED = { 0.61, 0.65, 0.70 }
local WIN = { 0.36, 0.85, 0.61 }
local LOSS = { 0.96, 0.43, 0.43 }
local WHITE = { 0.92, 0.94, 0.97 }
-- English source strings; every display goes through FD.L.
local BRACKET_NAMES = { LEVELING = "Leveling", MAX_LEVEL = "Max level", LEGACY = "Legacy" }
local STREAKS = { WIN = { "Current streak: %d win", "Current streak: %d wins" },
    LOSS = { "Current streak: %d loss", "Current streak: %d losses" } }

local function format(key, ...)
    return FD.Locale:Format(key, ...)
end

-- Date patterns are locale keys as well, so a translation can reorder them;
-- one that date() rejects falls back to the English pattern.
local function stamp(pattern, time)
    local ok, text = pcall(date, FD.L[pattern], time)
    if ok and type(text) == "string" then return text end
    return date(pattern, time)
end

local function bracketName(bracket)
    return FD.L[BRACKET_NAMES[bracket] or BRACKET_NAMES.LEGACY]
end

local function plain(value)
    return (tostring(value or ""):gsub("|", "||"))
end

local function color(text, rgb)
    text:SetTextColor(rgb[1], rgb[2], rgb[3])
end

local function classColor(identity)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[identity.classFile]
    return c and { c.r, c.g, c.b } or WHITE
end

local function specialization(identity)
    if type(identity.specName) == "string" and identity.specName ~= "" then return identity.specName end
    local id = identity.specId
    if type(id) ~= "number" or id ~= id or id < 1 or id > 100000 or id % 1 ~= 0
        or type(GetSpecializationNameForSpecID) ~= "function" then return nil end
    local ok, name = pcall(GetSpecializationNameForSpecID, id)
    if ok and FD.Wow:Readable(name) and type(name) == "string" and name ~= "" then return name end
end

local function description(identity)
    local class = plain(identity.className or identity.classFile)
    local spec = specialization(identity)
    local text = spec and plain(spec) .. " - " .. class or class
    return identity.level and format("Lvl %d - %s", identity.level, text) or text
end

local function surface(frame, fill, border)
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    frame:SetBackdropColor(fill[1], fill[2], fill[3], fill[4] or 1)
    border = border or { 0.20, 0.23, 0.28 }
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

local function label(parent, font, x, y, width, height, rgb)
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    text:SetPoint("TOPLEFT", x, -y)
    text:SetSize(width, height)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetWordWrap(false)
    color(text, rgb or WHITE)
    return text
end

local function panel(parent, x, y, width, height, fill, border)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetPoint("TOPLEFT", x, -y)
    frame:SetSize(width, height)
    surface(frame, fill, border)
    return frame
end

-- Keep read-only presentation failures separate from duel error recovery,
-- but persist them like every other addon error.
function Profile:Run(callback)
    local stack
    local ok, err = xpcall(callback, function(message)
        if type(debugstack) == "function" then stack = debugstack(2, 8, 0) end
        return message
    end)
    if ok then return end
    if self.frame then self.frame:Hide() end
    FD.Debug:Print(FD.L["Could not display the overview. /duelrating summary still shows your rating."])
    FD.Debug:Error("overview", err, stack)
end

-- Where data went that is no longer this character's active history. The
-- second value marks something that happened in this session.
function Profile:Notice()
    local kept = FD.Database:Kept()
    local parts = {}
    if kept.archivedNow then
        parts[1] = FD.L["Saved data of another character with this name was archived. This character starts with a fresh rating."]
    elseif kept.archives > 0 then
        parts[1] = format(kept.archives == 1 and "Data of %d earlier character with this name is archived in the saved file."
            or "Data of %d earlier characters with this name is archived in the saved file.", kept.archives)
    end
    if kept.quarantine then
        parts[#parts + 1] = FD.L["Saved data that could not be loaded is kept under 'quarantine' in the saved file."]
    end
    if #parts > 0 then return table.concat(parts, "  /  "), kept.archivedNow end
end

function Profile:Create()
    if self.frame then return end
    local frame = CreateFrame("Frame", "ForeverDuelProfile", UIParent, "BackdropTemplate")
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
    frame:SetScript("OnHide", function() frame:StopMovingOrSizing() end)
    frame:Hide()

    local function button(text, width, x, y, handler)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(width, 26)
        b:SetPoint("TOPLEFT", x, -y)
        b:SetText(text)
        b:SetScript("OnClick", function() self:Run(handler) end)
        return b
    end
    label(frame, "GameFontNormalLarge", 24, 23, 600, 25, GOLD):SetText("ForeverDuelersGuild")
    label(frame, "GameFontHighlightSmall", 24, 51, 540, 18, MUTED):SetText(FD.L["YOUR DUEL RECORD  /  Local rated matches"])
    self.zone = button(FD.L["Players in zone"], 156, 692, 25, function() FD.Zone:Show() end)
    self.queue = button(FD.L["Rated queue"], 104, 580, 25, function() FD.QueueUI:Show() end)
    self.close = button(FD.L["Close"], 72, 864, 25, function() frame:Hide() end)
    self.brackets = {}
    for index, bracket in ipairs({ "LEVELING", "MAX_LEVEL", "LEGACY" }) do
        local selectedBracket = bracket
        self.brackets[bracket] = button(bracketName(bracket), 124, 24 + (index - 1) * 132, 78, function()
            self.bracket, self.page, self.selectedId = selectedBracket, 1, nil
            self:Refresh()
        end)
    end
    self.poolLabel = label(frame, "GameFontHighlightSmall", 436, 86, 500, 18, MUTED)
    self.poolLabel:SetJustifyH("RIGHT")
    self.stats = {}
    for index, title in ipairs({ "CURRENT RATING", "WINS / LOSSES", "WIN RATE", "BEST RATING" }) do
        local card = panel(frame, 24 + (index - 1) * 232, 118, 216, 82,
            index == 1 and { 0.16, 0.13, 0.08 } or { 0.085, 0.10, 0.13 },
            index == 1 and { 0.46, 0.36, 0.19 } or nil)
        label(card, "GameFontHighlightSmall", 16, 14, 184, 17, MUTED):SetText(FD.L[title])
        self.stats[index] = label(card, "GameFontHighlightLarge", 16, 41, 184, 28, index == 1 and GOLD or WHITE)
    end
    self.record = label(frame, "GameFontHighlightSmall", 24, 215, 912, 18, MUTED)
    self.chart = panel(frame, 24, 239, 912, 121, { 0.075, 0.09, 0.115 })
    label(self.chart, "GameFontHighlightSmall", 14, 10, 270, 16, GOLD):SetText(FD.L["RATING PROGRESSION"])
    self.chartSummary = label(self.chart, "GameFontHighlightSmall", 310, 10, 586, 16, MUTED)
    self.chartSummary:SetJustifyH("RIGHT")
    self.chartHigh = label(self.chart, "GameFontHighlightSmall", 10, 31, 48, 16, MUTED)
    self.chartLow = label(self.chart, "GameFontHighlightSmall", 10, 83, 48, 16, MUTED)
    self.chartFirst = label(self.chart, "GameFontHighlightSmall", 68, 103, 370, 14, MUTED)
    self.chartLast = label(self.chart, "GameFontHighlightSmall", 516, 103, 380, 14, MUTED)
    self.chartLast:SetJustifyH("RIGHT")
    self.chartEmpty = label(self.chart, "GameFontHighlightSmall", 200, 59, 540, 18, MUTED)
    self.chartEmpty:SetJustifyH("CENTER")
    self.chartEmpty:SetText(FD.L["Play a rated duel to start this rating history."])
    for _, y in ipairs({ 36, 98 }) do
        local line = self.chart:CreateLine(nil, "BACKGROUND")
        line:SetThickness(1)
        line:SetColorTexture(0.20, 0.23, 0.28, 1)
        line:SetStartPoint("TOPLEFT", self.chart, 68, -y)
        line:SetEndPoint("TOPLEFT", self.chart, 896, -y)
    end
    self.chartLines = {}
    for index = 1, 40 do
        local line = self.chart:CreateLine(nil, "ARTWORK")
        line:SetThickness(2)
        self.chartLines[index] = line
    end
    label(frame, "GameFontNormal", 24, 371, 260, 20, GOLD):SetText(FD.L["Match history"])
    label(frame, "GameFontHighlightSmall", 260, 373, 316, 18, MUTED):SetText(FD.L["Click a duel to view its details  >"])
    local columns = { { "DATE", 12, 85 }, { "OPPONENT", 108, 219 },
        { "RESULT", 343, 75 }, { "CHANGE", 441, 68 } }
    for _, column in ipairs(columns) do
        label(frame, "GameFontHighlightSmall", 24 + column[2], 402, column[3], 16, MUTED):SetText(FD.L[column[1]])
    end
    self.rows = {}
    for index = 1, self.pageSize do
        local row = CreateFrame("Button", nil, frame, "BackdropTemplate")
        row:SetSize(552, 36)
        row:SetPoint("TOPLEFT", 24, -(422 + (index - 1) * 38))
        surface(row, { 0.08, 0.095, 0.12 }, { 0.08, 0.095, 0.12 })
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.cells = {}
        for col, column in ipairs(columns) do
            row.cells[col] = label(row, col == 2 and "GameFontHighlight" or "GameFontHighlightSmall",
                column[2], col == 1 and 4 or (col == 2 and 3 or 12), column[3], col == 1 and 30 or 18)
        end
        color(row.cells[1], MUTED)
        row.class = label(row, "GameFontHighlightSmall", 108, 21, 219, 14, MUTED)
        row.arrow = label(row, "GameFontHighlight", 526, 10, 18, 20, GOLD)
        row.cells[4]:SetJustifyH("RIGHT")
        row:SetScript("OnClick", function()
            self:Run(function()
                if row.match then self.selectedId = row.match.matchId; self:Refresh() end
            end)
        end)
        self.rows[index] = row
    end
    self.empty = label(frame, "GameFontHighlight", 48, 487, 504, 110, MUTED)
    self.empty:SetWordWrap(true)
    self.empty:SetText(FD.L["No rated duels yet.\n\nChallenge another ForeverDuelersGuild player through the normal Duel action, then both accept rated."])

    self.detailPanel = panel(frame, 592, 368, 344, 408, { 0.075, 0.09, 0.115 })
    label(self.detailPanel, "GameFontHighlightSmall", 16, 16, 312, 17, GOLD):SetText(FD.L["MATCH DETAILS"])
    self.detailResult = label(self.detailPanel, "GameFontHighlightLarge", 16, 44, 312, 27)
    self.details = label(self.detailPanel, "GameFontHighlightSmall", 16, 78, 312, 43, MUTED)
    self.details:SetWordWrap(true)
    local function participant(y, title, calculated)
        local card = panel(self.detailPanel, 12, y, 320, calculated and 122 or 112, { 0.10, 0.12, 0.15 })
        card.title = label(card, "GameFontHighlightSmall", 12, 9, 296, 16, MUTED)
        card.title:SetText(title)
        card.name = label(card, "GameFontHighlight", 12, 27, 296, 32)
        card.name:SetWordWrap(true)
        card.description = label(card, "GameFontHighlightSmall", 12, 61, 296, 16, MUTED)
        card.rating = label(card, "GameFontHighlight", 12, 83, 296, 22)
        if calculated then
            label(card, "GameFontHighlightSmall", 12, 105, 296, 14, MUTED):SetText(FD.L["Rating after match: calculated"])
        end
        return card
    end
    self.playerCard = participant(131, FD.L["YOU"], false)
    self.opponentCard = participant(254, FD.L["OPPONENT"], true)
    label(self.detailPanel, "GameFontHighlightSmall", 16, 386, 312, 16, MUTED):SetText(FD.L["Rated result  /  Recorded on this character"])
    self.previous = button(FD.L["Previous"], 100, 24, 750, function()
        self.page = self.page - 1; self.selectedId = nil; self:Refresh()
    end)
    self.next = button(FD.L["Next"], 100, 476, 750, function()
        self.page = self.page + 1; self.selectedId = nil; self:Refresh()
    end)
    self.pageLabel = label(frame, "GameFontHighlightSmall", 188, 757, 224, 20, MUTED)
    self.pageLabel:SetJustifyH("CENTER")
    self.notice = label(frame, "GameFontHighlightSmall", 24, 786, 912, 16, MUTED)
    self.frame = frame
    UISpecialFrames[#UISpecialFrames + 1] = "ForeverDuelProfile"
end

function Profile:RenderDetails(detail)
    self.selectedDetails = detail
    if not detail then
        self.detailResult:SetText(FD.L["No match selected"])
        color(self.detailResult, MUTED)
        self.details:SetText(FD.L["Completed rated duels appear in your history. Select one to see both players and the result."])
        self.playerCard:Hide()
        self.opponentCard:Hide()
        return
    end
    local match = detail.match
    local won = match.result == "WIN"
    self.detailResult:SetText(won and FD.L["VICTORY"] or FD.L["DEFEAT"])
    color(self.detailResult, won and WIN or LOSS)
    local outcome = match.resultSource == "KNOCKOUT" and FD.L["Knockout"]
        or (match.resultSource == "RETREAT" and FD.L["Retreat"] or FD.L["Rated duel"])
    self.details:SetText(format("%s  /  Duration: %d:%02d\n%s  /  %s", outcome,
        math.floor(detail.duration / 60), detail.duration % 60, stamp("%d.%m.%Y %H:%M", match.endedAt),
        bracketName(match.bracket)))
    local function participant(card, identity, before, after, delta, winner)
        card.name:SetText(plain(identity.fullName or identity.name))
        color(card.name, classColor(identity))
        card.description:SetText(description(identity))
        card.rating:SetText(format("Rating: %d  ->  %d    (%+d)", before, after, delta))
        color(card.rating, winner and WIN or LOSS)
        card:Show()
    end
    participant(self.playerCard, match.player, detail.playerRatingBefore, detail.playerRatingAfter, detail.playerRatingDelta, won)
    participant(self.opponentCard, match.opponent, detail.opponentRatingBefore, detail.opponentRatingAfter, detail.opponentRatingDelta, not won)
end

function Profile:RenderChart(series)
    self.chartSeries = series
    local minimum, maximum = series[1].rating, series[1].rating
    for _, point in ipairs(series) do
        minimum, maximum = math.min(minimum, point.rating), math.max(maximum, point.rating)
    end
    -- A bounded nonzero range keeps ties and a single starting rating readable.
    local padding = math.max(5, math.ceil((maximum - minimum) * 0.12))
    minimum, maximum = minimum - padding, maximum + padding
    self.chartHigh:SetText(tostring(maximum))
    self.chartLow:SetText(tostring(minimum))
    local function position(index)
        local x = 68 + (index - 1) / math.max(1, #series - 1) * 828
        local y = -98 + (series[index].rating - minimum) / (maximum - minimum) * 62
        return x, y
    end
    for index, line in ipairs(self.chartLines) do
        if index < #series then
            local x1, y1 = position(index)
            local x2, y2 = position(index + 1)
            local rgb = series[index + 1].rating > series[index].rating and WIN
                or (series[index + 1].rating < series[index].rating and LOSS or GOLD)
            line:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)
            line:SetStartPoint("TOPLEFT", self.chart, x1, y1)
            line:SetEndPoint("TOPLEFT", self.chart, x2, y2)
            line:Show()
        else line:Hide() end
    end
    local first, latest = series[1], series[#series]
    if series.shown == 0 then
        self.chartSummary:SetText(format("Starting rating: %d", first.rating))
        self.chartFirst:SetText("")
        self.chartLast:SetText("")
        self.chartEmpty:Show()
    else
        self.chartSummary:SetText(format("Last %d / %d duels  /  %d -> %d (%+d)",
            series.shown, series.total, first.rating, latest.rating, latest.rating - first.rating))
        self.chartFirst:SetText(format("Before duel %d: %d", first.ordinal + 1, first.rating))
        self.chartLast:SetText(format("Duel %d: %d", latest.ordinal, latest.rating))
        self.chartEmpty:Hide()
    end
end

function Profile:Refresh()
    self.bracket = self.bracket or FD.Database.bracket or "LEVELING"
    local hasLegacy = FD.Database.data and FD.Database.data.legacy
    if self.bracket == "LEGACY" and not hasLegacy then self.bracket = FD.Database.bracket or "LEVELING" end
    for bracket, button in pairs(self.brackets) do
        button:SetEnabled(bracket ~= self.bracket)
        if bracket ~= "LEGACY" or hasLegacy then button:Show() else button:Hide() end
    end
    self.poolLabel:SetText(self.bracket == "LEGACY" and FD.L["Archive from before separate ratings"]
        or FD.L["Separate ratings for leveling and max level"])
    local notice, current = self:Notice()
    self.notice:SetText(notice or "")
    color(self.notice, current and GOLD or MUTED)
    local overview = FD.History:Overview(self.bracket)
    local page = FD.History:Page(self.page, self.pageSize, self.bracket)
    self:RenderChart(FD.History:Series(self.bracket, 40))
    self.page = page.page
    self.stats[1]:SetText(tostring(overview.rating))
    self.stats[2]:SetText(string.format("%d / %d", overview.wins, overview.losses))
    self.stats[3]:SetText(overview.winRate and string.format("%.1f%%", overview.winRate) or "--")
    self.stats[4]:SetText(tostring(overview.peakRating))
    local record = format("%s  /  %d rated matches", bracketName(self.bracket), overview.total)
    local streak = STREAKS[overview.streakResult]
    if streak and overview.streakCount > 0 then
        record = record .. "  /  " .. format(overview.streakCount == 1 and streak[1] or streak[2], overview.streakCount)
    end
    self.record:SetText(record)
    local selected
    for _, match in ipairs(page.matches) do
        if match.matchId == self.selectedId then selected = match end
    end
    selected = selected or page.matches[1]
    self.selectedId = selected and selected.matchId or nil
    for index, row in ipairs(self.rows) do
        local match = page.matches[index]
        row.match = match
        if match then
            local won, chosen = match.result == "WIN", match.matchId == self.selectedId
            row.cells[1]:SetText(stamp("%d.%m.%y\n%H:%M", match.endedAt))
            row.cells[2]:SetText(plain(match.opponent.fullName or match.opponent.name))
            color(row.cells[2], classColor(match.opponent))
            row.class:SetText(plain(match.opponent.className or match.opponent.classFile))
            row.cells[3]:SetText(won and FD.L["WIN"] or FD.L["LOSS"])
            row.cells[4]:SetText(string.format("%+d", match.ratingDelta))
            color(row.cells[3], won and WIN or LOSS)
            color(row.cells[4], won and WIN or LOSS)
            local shade = index % 2 == 0 and 0.075 or 0.095
            row:SetBackdropColor(chosen and 0.19 or shade, chosen and 0.16 or shade + 0.012,
                chosen and 0.10 or shade + 0.025, 1)
            row:SetBackdropBorderColor(chosen and 0.59 or shade, chosen and 0.45 or shade + 0.012,
                chosen and 0.22 or shade + 0.025, 1)
            row.arrow:SetText(chosen and ">" or "")
            row:Show()
        else row:Hide() end
    end
    if selected then self.empty:Hide() else self.empty:Show() end
    self:RenderDetails(selected and FD.History:Details(selected.matchId) or nil)
    self.previous:SetEnabled(page.page > 1)
    self.next:SetEnabled(page.page < page.pages)
    self.pageLabel:SetText(format("Page %d / %d", page.page, page.pages))
end

function Profile:Toggle()
    self:Run(function()
        self:Create()
        if self.frame:IsShown() then self.frame:Hide(); return end
        -- UIParent dimensions are already in UI units; shrink the whole window
        -- on smaller displays while leaving the player's UI scale untouched.
        local scale = math.min(1, (UIParent:GetWidth() - 40) / WIDTH, (UIParent:GetHeight() - 40) / HEIGHT)
        self.frame:SetScale(math.max(0.1, scale))
        self.page, self.selectedId = 1, nil
        self:Refresh()
        self.frame:Show()
        if FD.Zone.frame then FD.Zone.frame:Hide() end
    end)
end

function Profile:RefreshIfShown()
    if self.frame and self.frame:IsShown() then self:Run(function() self:Refresh() end) end
end
