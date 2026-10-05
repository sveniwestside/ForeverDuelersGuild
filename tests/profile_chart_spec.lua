return function(FD, equal, newNamespace)
    assert(loadfile("ForeverDuel/Profile.lua"))("ForeverDuel", FD)
    local profile = FD.Profile
    local function textRegion()
        return {
            SetText = function(self, value) self.text = value end,
            Show = function(self) self.shown = true end,
            Hide = function(self) self.shown = false end,
        }
    end
    profile.chart = {}
    for _, field in ipairs({ "chartSummary", "chartHigh", "chartLow", "chartFirst", "chartLast", "chartEmpty" }) do
        profile[field] = textRegion()
    end
    profile.chartLines = {}
    for index = 1, 40 do
        local line = textRegion()
        function line:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
        function line:SetStartPoint(point, relativeTo, x, y)
            self.start = { point = point, relativeTo = relativeTo, x = x, y = y }
        end
        function line:SetEndPoint(point, relativeTo, x, y)
            self.finish = { point = point, relativeTo = relativeTo, x = x, y = y }
        end
        profile.chartLines[index] = line
    end
    local function series(ratings)
        local result = { bracket = "LEVELING", total = #ratings - 1, shown = #ratings - 1 }
        for index, rating in ipairs(ratings) do
            result[index] = { rating = rating, ordinal = index - 1, baseline = index == 1 }
        end
        return result
    end
    local function verifyBounds(count)
        for index = 1, count do
            local line = profile.chartLines[index]
            equal(line.shown, true, "each visible match has a rendered chart segment")
            for _, anchor in ipairs({ line.start, line.finish }) do
                equal(anchor.point, "TOPLEFT", "chart uses a consistent coordinate origin")
                equal(anchor.relativeTo, profile.chart, "native line signature includes its explicit chart parent")
                equal(type(anchor.x) == "number" and anchor.x >= 68 and anchor.x <= 896, true,
                    "chart endpoint stays inside horizontal plotting bounds")
                equal(type(anchor.y) == "number" and anchor.y >= -98 and anchor.y <= -36, true,
                    "chart endpoint stays inside vertical plotting bounds without nonfinite coordinates")
            end
            if index > 1 then
                equal(line.start.x, profile.chartLines[index - 1].finish.x, "adjacent rendered matches meet horizontally")
                equal(line.start.y, profile.chartLines[index - 1].finish.y, "adjacent rendered matches meet vertically")
            end
        end
        for index = count + 1, #profile.chartLines do
            equal(profile.chartLines[index].shown, false, "unused chart segments are hidden")
        end
    end

    profile:RenderChart(series({ 1500, 1516, 1496, 1496, 1800 }))
    verifyBounds(4)
    equal(profile.chartLines[1].start.x, 68, "baseline begins at the left plot edge")
    equal(profile.chartLines[4].finish.x, 896, "latest match reaches the right plot edge")
    equal(profile.chartLines[1].finish.y > profile.chartLines[1].start.y, true, "rating gains rise on the chart")
    equal(profile.chartLines[2].finish.y < profile.chartLines[2].start.y, true, "rating losses fall on the chart")
    equal(profile.chartLines[3].finish.y, profile.chartLines[3].start.y, "zero transfer produces a flat segment")
    equal(profile.chartLines[1].color[2], 0.85, "gain segment uses the victory color")
    equal(profile.chartLines[2].color[1], 0.96, "loss segment uses the defeat color")
    equal(profile.chartLines[3].color[1], 0.94, "flat segment uses the neutral gold color")
    equal(profile.chartEmpty.shown, false, "real history clears the empty-state overlay")

    -- Switching from a busy pool to a shorter pool cannot leave stale lines.
    local shorter = series({ 1500, 1484 })
    shorter.bracket = "MAX_LEVEL"
    profile:RenderChart(shorter)
    verifyBounds(1)
    equal(profile.chartSeries.bracket, "MAX_LEVEL", "rendered data follows the newly selected pool")
    equal(profile.chartSummary.text:find("1500 -> 1484 (-16)", 1, true) ~= nil, true,
        "summary describes the visible pool's actual rating movement")

    profile:RenderChart(series({ 1500, 1500 }))
    verifyBounds(1)
    equal(profile.chartLines[1].finish.y, profile.chartLines[1].start.y,
        "entirely flat history stays finite and visible")
    profile:RenderChart(series({ 1500 }))
    verifyBounds(0)
    equal(profile.chartEmpty.shown, true, "empty pool shows its own empty-state message")
    equal(profile.chartFirst.text, "", "empty pool clears the previous first-match label")
    equal(profile.chartLast.text, "", "empty pool clears the previous last-match label")
    equal(profile.chartSummary.text, "Starting rating: 1500", "empty pool does not retain a previous gain or loss")
    -- The whole window in a private environment: localized text, storage
    -- notices and contained presentation errors.
    local ns = newNamespace()
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local methods = {}
    local function widget() return setmetatable({ scripts = {}, shown = false }, { __index = methods }) end
    for _, name in ipairs({ "SetPoint", "SetFrameStrata", "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor",
        "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetMovable", "EnableMouse", "SetClampedToScreen",
        "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetHighlightTexture", "SetThickness",
        "SetColorTexture", "SetStartPoint", "SetEndPoint", "SetScale" }) do
        methods[name] = function() end
    end
    function methods:SetSize(width, height) self.width, self.height = width, height end
    function methods:GetWidth() return self.width end
    function methods:GetHeight() return self.height end
    function methods:SetText(value) self.text = value end
    function methods:SetTextColor(r, g, b) self.color = { r, g, b } end
    function methods:SetEnabled(value) self.enabled = value end
    function methods:SetScript(name, callback) self.scripts[name] = callback end
    function methods:Show() self.shown = true end
    function methods:Hide() self.shown = false end
    function methods:IsShown() return self.shown end
    function methods:CreateFontString() return widget() end
    function methods:CreateLine() return widget() end
    env.CreateFrame = function() return widget() end
    env.UIParent = widget()
    env.UIParent:SetSize(1920, 1080)
    env.UISpecialFrames = {}
    env.date = os.date
    local chunk = assert(loadfile("ForeverDuel/Profile.lua"))
    setfenv(chunk, env)
    chunk("ForeverDuel", ns)
    local printed, errors = {}, {}
    ns.Wow = { Readable = function() return true end }
    ns.Zone = {}
    ns.Debug = {
        Print = function(_, text) printed[#printed + 1] = text end,
        Error = function(_, context, message) errors[#errors + 1] = { context = context, message = message } end,
    }
    local a = { guid = "Player-1-AAA", name = "Alpha", realm = "Forever", classFile = "MAGE", level = 30, maxLevel = 60 }
    local b = { guid = "Player-1-BBB", name = "Beta", realm = "Forever", classFile = "ROGUE", level = 30, maxLevel = 60 }
    local function commit(id, won)
        local before = ns.Database:GetStats("LEVELING").rating
        local after, delta = ns.Rating:Calculate(before, 1500, won, 30, 30)
        equal(ns.Database:Commit({
            schemaVersion = 2, protocolVersion = 3, bracket = "LEVELING", matchId = id,
            player = ns.Database:Copy(a), opponent = ns.Database:Copy(b), startedAt = 1700000000, endedAt = 1700000045,
            winnerGUID = won and a.guid or b.guid, loserGUID = won and b.guid or a.guid, result = won and "WIN" or "LOSS",
            ratingBefore = before, opponentRatingBefore = 1500, ratingAfter = after, ratingDelta = delta,
            ratedConfirmed = true, evidence = { agreedBeforeStart = true, localResult = true, peerResult = true },
        }), true, "window fixture commits")
    end
    equal(ns.Profile:Notice(), nil, "no notice without a database")
    ns.Database:Initialize(nil, a)
    commit("first", false)
    commit("second", true)
    commit("third", true)
    local window = ns.Profile
    window:Toggle()
    equal(window.frame:IsShown(), true, "window opens")
    equal(window.notice.text, "", "clean database shows no storage notice")
    equal(window.record.text, "Leveling  /  3 rated matches  /  Current streak: 2 wins", "record line")
    equal(window.rows[1].cells[3].text, "WIN", "row result label")
    equal(window.rows[3].cells[3].text, "LOSS", "row loss label")
    equal(window.pageLabel.text, "Page 1 / 1", "page label")
    equal(window.detailResult.text, "VICTORY", "detail result")
    equal(window.details.text:find("Rated duel  /  Duration: 0:45", 1, true) ~= nil, true, "detail summary")
    equal(window.opponentCard.rating.text:find("1500  ->  ", 1, true) ~= nil, true, "opponent projection shown")

    -- Storage notices: what happened this session is highlighted.
    local data = ns.Database.data
    data.archived = { ["Player-1-OLD"] = { archivedAt = 1, data = {} } }
    data.archivedNotice = { guid = "Player-1-OLD", archivedAt = 1 }
    window:Refresh()
    equal(window.notice.text, "Saved data of another character with this name was archived. This character starts with a fresh rating.",
        "fresh archive explained")
    equal(window.notice.color[1], 0.94, "fresh archive highlighted")
    data.archivedNotice = nil
    window:Refresh()
    equal(window.notice.text, "Data of 1 earlier character with this name is archived in the saved file.", "kept archive noted")
    equal(window.notice.color[1], 0.61, "kept archive muted")
    data.archived["Player-1-OLDER"] = { archivedAt = 0, data = {} }
    data.quarantine = { data = {}, quarantinedAt = 1, quarantineReason = "inconsistent_history" }
    window:Refresh()
    equal(window.notice.text, "Data of 2 earlier characters with this name is archived in the saved file."
        .. "  /  Saved data that could not be loaded is kept under 'quarantine' in the saved file.", "archives and quarantine noted")
    equal(window.stats[1].text, tostring(ns.Database:GetStats().rating), "notices leave the rating display intact")

    -- Every refreshed string goes through the locale; a broken translation
    -- falls back to English instead of failing the window.
    ns.Locale:Register("xxXX", {
        ["Leveling"] = "Stufen", ["%s  /  %d rated matches"] = "%s  /  %d gewertet",
        ["Current streak: %d wins"] = "Serie: %d Siege", ["WIN"] = "SIEG", ["LOSS"] = "NIEDERLAGE",
        ["Page %d / %d"] = "Seite %d / %d", ["VICTORY"] = "SIEG!",
        ["Data of %d earlier characters with this name is archived in the saved file."] = "%d Archive.",
        ["Saved data that could not be loaded is kept under 'quarantine' in the saved file."] = "Quarantaene.",
        ["Last %d / %d duels  /  %d -> %d (%+d)"] = "Letzte %d / %d  /  %d -> %d (%+d)",
        ["Before duel %d: %d"] = "Vor Duell %s %s %s",
    })
    ns.Locale.current = "xxXX"
    window:Refresh()
    equal(window.record.text, "Stufen  /  3 gewertet  /  Serie: 2 Siege", "record line localized")
    equal(window.rows[1].cells[3].text, "SIEG", "row result localized")
    equal(window.rows[3].cells[3].text, "NIEDERLAGE", "row loss localized")
    equal(window.pageLabel.text, "Seite 1 / 1", "page label localized")
    equal(window.detailResult.text, "SIEG!", "detail result localized")
    equal(window.notice.text, "2 Archive.  /  Quarantaene.", "notices localized")
    equal(window.chartSummary.text:find("Letzte 3 / 3", 1, true) ~= nil, true, "chart summary localized")
    equal(window.chartFirst.text, "Before duel 1: 1500", "broken translation falls back to English")
    ns.Locale.current = "enUS"

    -- A presentation failure closes only the window and is persisted.
    local overview = ns.History.Overview
    ns.History.Overview = function() error("injected overview failure") end
    window:RefreshIfShown()
    ns.History.Overview = overview
    equal(window.frame:IsShown(), false, "failed window closes")
    equal(#printed, 1, "player told once")
    equal(errors[1].context, "overview", "failure persisted as an addon error")
    equal(tostring(errors[1].message):find("injected overview failure", 1, true) ~= nil, true, "failure message persisted")
    equal(#ns.Database.data.matches, 3, "failure leaves history untouched")
    window:Toggle()
    equal(window.frame:IsShown(), true, "window opens again after a failure")
end
