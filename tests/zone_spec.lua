return function(FD, equal)
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local state = { players = {}, queries = 0, challenges = {}, prints = {}, logs = {}, now = 1000, refreshes = 0, wakes = 0 }
    local active = { state = "IN_PROGRESS", matchId = "preserve-duel" }
    FD.duel, FD.Debug = { active = active }, {}
    FD.Wow = { Readable = function() return true end }
    FD.Database:Initialize(nil, { guid = "Player-1-AAA", name = "Me", realm = "Realm", classFile = "MAGE", level = 30, maxLevel = 60 })
    FD.Presence = { STALE = 90 }
    function FD.Presence:RefreshNow() state.refreshes = state.refreshes + 1 end
    function FD.Presence:Changed() state.wakes = state.wakes + 1 end
    function FD.Presence:GetOwnPlayer()
        if state.missingOwn then return nil end
        return { guid = "Player-1-AAA", rating = 1500, level = 30, maxLevel = 60, bracket = "LEVELING" }
    end
    function FD.Presence:GetPlayers()
        state.queries = state.queries + 1
        if state.failRead then error("read failed") end
        return FD.Database:Copy(state.players)
    end
    function FD.Presence:GetStatus() return state.status or "Discovering players in this zone..." end
    function FD.Presence:Challenge(name)
        state.challenges[#state.challenges + 1] = name
        if state.failChallenge then error("challenge failed") end
        return state.challengeSuccess, "Move closer to the player and try again."
    end
    function FD.Debug:Print(message) state.prints[#state.prints + 1] = message end
    function FD.Debug:Log(...) state.logs[#state.logs + 1] = { ... } end
    -- Window failures are persisted addon errors (/duelrating errors).
    function FD.Debug:Error(context, message) state.logs[#state.logs + 1] = { context, message } end
    function FD:Safe() error("Zone UI must not enter duel-aborting recovery") end
    local methods, widget = {}, nil
    widget = function() return setmetatable({ scripts = {} }, { __index = methods }) end
    function methods:SetSize(width, height) self.width, self.height = width, height end
    function methods:GetWidth() return self.width end
    function methods:GetHeight() return self.height end
    function methods:SetPoint(...) self.point = { ... } end
    function methods:SetText(value)
        self.text = value
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self) end
    end
    function methods:GetText() return self.text end
    function methods:SetTextColor(...) self.color = { ... } end
    function methods:SetEnabled(value) self.enabled = value end
    function methods:SetScript(event, callback) self.scripts[event] = callback end
    function methods:SetScale(scale) self.scale = scale end
    function methods:CreateFontString() return widget() end
    function methods:CreateLine() return widget() end
    function methods:IsShown() return self.shown end
    function methods:Show() self.shown = true end
    function methods:Hide()
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    for _, name in ipairs({ "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor", "SetFrameStrata",
        "SetMovable", "EnableMouse", "SetClampedToScreen", "RegisterForDrag", "StartMoving",
        "StopMovingOrSizing", "SetAutoFocus", "SetMaxLetters", "ClearFocus", "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetHighlightTexture",
        "SetThickness", "SetColorTexture", "SetStartPoint", "SetEndPoint" }) do
        methods[name] = function() end
    end
    env.CreateFrame = function() return widget() end
    env.GetTime = function() return state.now end
    env.UIParent = widget()
    env.UIParent:SetSize(1920, 1080)
    env.UISpecialFrames = {}
    env.RAID_CLASS_COLORS = { MAGE = { r = 0.2, g = 0.7, b = 1 } }
    env.LOCALIZED_CLASS_NAMES_MALE = { MAGE = "Magier" }
    for _, module in ipairs({ "Native", "Widgets", "Profile", "Zone" }) do
        local chunk = assert(loadfile("ForeverDuel/" .. module .. ".lua"))
        setfenv(chunk, env)
        chunk("ForeverDuel", FD)
    end
    local function click(button) button.scripts.OnClick(button) end
    local function selectOption(control, index)
        click(control)
        equal(control.menu:IsShown(), true, "dropdown opens available choices")
        click(control.items[index])
        equal(control.menu:IsShown(), false, "selecting a choice closes its menu")
        equal(FD.Zone.dropdownDismiss:IsShown(), false, "selection releases outside-click layer")
    end
    local function preserved(label)
        equal(FD.duel.active, active, label .. " preserves active duel")
        equal(active.state, "IN_PROGRESS", label .. " preserves duel state")
        equal(FD.Database.data.player.ratings.LEVELING.rating, 1500, label .. " preserves rating")
        equal(#FD.Database.data.matches, 0, label .. " preserves history")
    end

    FD.Profile:Toggle()
    equal(FD.Profile.frame:IsShown(), true, "overview still opens")
    equal(FD.Profile.stats[1].text, "1500", "overview still renders rating")
    click(FD.Profile.zone)
    equal(FD.Zone.frame:IsShown(), true, "overview button opens zone browser")
    equal(FD.Profile.frame:IsShown(), false, "navigation hides overview")
    equal(FD.Zone.empty:IsShown(), true, "empty discovery gives guidance")
    equal(FD.Zone.status.text, "Discovering players in this zone...", "discovery status shown")
    equal(FD.Zone.previous.enabled, false, "empty page disables previous")
    equal(FD.Zone.next.enabled, false, "empty page disables next")
    equal(#state.challenges, 0, "opening browser does not initiate a duel")
    equal(FD.Zone:IsShown(), true, "Presence can see that the browser is open")
    equal(state.wakes, 1, "opening the browser starts a discovery pass")
    click(FD.Zone.refresh)
    equal(state.refreshes, 1, "the Refresh button asks Presence for an explicit refresh")
    equal(#state.challenges, 0, "refreshing never initiates a duel")
    equal(env.UISpecialFrames[2], "ForeverDuelZone", "escape can close browser")
    click(FD.Zone.overview)
    equal(FD.Profile.frame:IsShown(), true, "return button opens overview")
    equal(FD.Zone.frame:IsShown(), false, "return button hides browser")
    local queries = state.queries
    FD.Zone:RefreshIfShown()
    equal(state.queries, queries, "hidden browser does no discovery rendering work")

    for index = 10, 1, -1 do
        state.players[#state.players + 1] = { guid = "Player-1-" .. index,
            fullName = string.format("Peer%02d-Realm", index), rating = 1500 + index, classFile = "MAGE",
            level = 30, maxLevel = 60, bracket = "LEVELING", lastSeen = state.now - (index == 2 and 95 or 60) }
    end
    state.status = "10 ForeverDuel players discovered."
    FD.Zone:Toggle()
    equal(FD.Zone.rows[1].name.text, "Peer01-Realm", "browser sorts names for stable pages")
    equal(state.players[1].fullName, "Peer10-Realm", "sorting does not reorder presence data")
    equal(FD.Zone.rows[1].rating.text, "1501", "row includes peer rating")
    equal(FD.Zone.rows[1].level.text, "Lv 30 / Leveling", "row includes level and rating mode")
    equal(FD.Zone.rows[1].name.color[2], 0.7, "row uses class color")
    equal(FD.Zone.rows[1].seen.text, "", "an entry refreshed by the 60 s heartbeat has no last-seen note")
    equal(FD.Zone.rows[2].seen.text, "last seen 95 s ago", "an entry older than STALE is marked last seen")
    equal(FD.Zone.rows[8].name.text, "Peer08-Realm", "first page bounded to eight rows")
    equal(FD.Zone.pageLabel.text, "Page 1 / 2  /  10 of 10 players", "pagination includes total players")
    equal(FD.Zone.next.enabled, true, "next page available")
    equal(FD.Zone.empty:IsShown(), false, "discovered players hide empty state")
    equal(FD.Zone.status.text, state.status, "live discovery status updates")
    equal(#state.challenges, 0, "rendering players does not initiate a duel")
    click(FD.Zone.next)
    equal(FD.Zone.page, 2, "next button advances page")
    equal(FD.Zone.rows[1].key, "Peer09-Realm", "second page starts with ninth peer")
    equal(FD.Zone.rows[3]:IsShown(), false, "partial final page hides unused rows")
    equal(FD.Zone.rows[3].key, nil, "unused rows discard old challenge identity")
    equal(FD.Zone.next.enabled, false, "final page disables next")
    click(FD.Zone.rows[1].duel)
    equal(state.challenges[1], "Peer09-Realm", "explicit click challenges the row's sender name")
    equal(state.prints[1], "Move closer to the player and try again.", "failed challenge explains next action")
    state.challengeSuccess = true
    click(FD.Zone.rows[2].duel)
    equal(state.challenges[2], "Peer10-Realm", "successful click selects matching peer")
    equal(#state.prints, 1, "successful challenge avoids failure message")
    click(FD.Zone.rows[3].duel)
    equal(#state.challenges, 2, "hidden expired row cannot challenge prior peer")

    state.players = { { guid = "Player-1-3", fullName = "Pipe|cFF0000-Realm", rating = 1600, classFile = "UNKNOWN" } }
    FD.Zone:RefreshIfShown()
    equal(FD.Zone.page, 1, "peer expiry clamps an obsolete page")
    equal(FD.Zone.rows[1].name.text, "Pipe||cFF0000-Realm", "peer text cannot inject UI markup")
    equal(FD.Zone.rows[1].name.color[1], 0.92, "unknown class resets old class color")
    equal(FD.Zone.rows[2].key, nil, "live refresh clears vanished peer key")
    state.players = {}
    FD.Zone:RefreshIfShown()
    equal(FD.Zone.empty:IsShown(), true, "last peer expiry restores empty state")
    equal(FD.Zone.rows[1].key, nil, "last peer expiry clears clickable identity")
    preserved("browser navigation and clicks")

    local function peer(id, name, rating, level, class, cap)
        cap = cap or 60
        return { guid = "Player-1-" .. id, fullName = name, rating = rating, level = level,
            maxLevel = cap, bracket = level == cap and "MAX_LEVEL" or "LEVELING", classFile = class or "MAGE" }
    end
    state.players = {
        peer("A", "Zulu-Realm", 1400, 25), peer("B", "Alpha-Realm", 1500, 35, "WARRIOR"),
        peer("C", "Beta-Realm", 1510, 36, "ROGUE"), peer("D", "Max-Realm", 1499, 60),
        peer("E", "Cap-Realm", 1498, 30, "MAGE", 70), peer("F", "Literal[-Realm", 1900, 30),
    }
    FD.Zone:RefreshIfShown()
    FD.Zone.page = 2
    FD.Zone.searchBox:SetText("ALPHA")
    equal(FD.Zone.page, 1, "editing name search resets pagination")
    equal(FD.Zone.rows[1].name.text, "Alpha-Realm", "name search is case-insensitive")
    equal(FD.Zone.rows[2].key, nil, "name search excludes nonmatches")
    equal(FD.Zone.pageLabel.text, "Page 1 / 1  /  1 of 6 players", "filtered count includes discovered total")
    FD.Zone.searchBox:SetText("[")
    equal(FD.Zone.rows[1].name.text, "Literal[-Realm", "name search treats pattern punctuation literally")
    FD.Zone.searchBox:SetText("missing")
    equal(FD.Zone.empty:IsShown(), true, "empty filter results show guidance")
    equal(FD.Zone.empty.text:find("reset the filters", 1, true) ~= nil, true, "empty filters explain recovery")
    click(FD.Zone.resetFilters)
    equal(FD.Zone.searchBox.text, "", "reset clears visible name search")
    equal(FD.Zone.empty:IsShown(), false, "reset restores results")
    local classOptions = { "All", "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Shaman", "Magier", "Warlock", "Druid" }
    equal(#FD.Zone.classFilter.options, #classOptions, "class menu contains all plus nine Vanilla classes")
    for index, name in ipairs(classOptions) do
        equal(FD.Zone.classFilter.options[index], name, "class choices exclude Retail-only classes and use localized names")
    end
    FD.Zone.page = 2
    local queriesBeforeMenu = state.queries
    click(FD.Zone.classFilter)
    equal(FD.Zone.classFilter.menu:IsShown(), true, "class button opens a dropdown")
    equal(FD.Zone.classIndex, 1, "opening dropdown does not change class")
    equal(FD.Zone.page, 2, "opening dropdown does not reset pagination")
    equal(state.queries, queriesBeforeMenu, "opening dropdown does not rerun filters")
    equal(FD.Zone.classFilter.items[1].caption.text, "> All", "dropdown marks current selection")
    click(FD.Zone.dropdownDismiss)
    equal(FD.Zone.classFilter.menu:IsShown(), false, "outside click dismisses the dropdown")
    equal(FD.Zone.classIndex, 1, "dismissing dropdown preserves selection")
    equal(#state.challenges, 2, "outside menu dismissal never challenges a player")
    selectOption(FD.Zone.classFilter, 8)
    equal(FD.Zone.classFilter.text, "Class: Magier", "class menu selects a nonadjacent localized option directly")
    equal(FD.Zone.page, 1, "selecting a class resets pagination")
    equal(#FD.Zone:FilteredPlayers(), 4, "direct Mage selection applies the class filter")
    selectOption(FD.Zone.classFilter, 10)
    equal(FD.Zone.classFilter.text, "Class: Druid", "last class option is directly selectable")
    equal(#FD.Zone:FilteredPlayers(), 0, "Druid choice filters by Druid class token")
    selectOption(FD.Zone.classFilter, 2)
    equal(FD.Zone.classFilter.text, "Class: Warrior", "class dropdown selects a named class")
    equal(FD.Zone.rows[1].name.text, "Alpha-Realm", "class filter keeps matching class")
    equal(FD.Zone.rows[2].key, nil, "class filter excludes other classes")
    selectOption(FD.Zone.classFilter, 1)
    equal(FD.Zone.classFilter.text, "Class: All", "class dropdown returns directly to all classes")
    selectOption(FD.Zone.ratingFilter, 2)
    equal(#FD.Zone:FilteredPlayers(), 3, "plus-minus 100 includes boundary and same-mode ratings")
    equal(FD.Zone.rows[3].name.text, "Zulu-Realm", "rating boundary is inclusive")
    selectOption(FD.Zone.ratingFilter, 3)
    equal(#FD.Zone:FilteredPlayers(), 3, "plus-minus 200 excludes other modes and level caps")
    selectOption(FD.Zone.ratingFilter, 4)
    equal(#FD.Zone:FilteredPlayers(), 4, "plus-minus 400 includes its boundary")
    selectOption(FD.Zone.ratingFilter, 1)
    equal(#FD.Zone:FilteredPlayers(), 6, "all-rating option retains every rating mode")
    selectOption(FD.Zone.sortFilter, 2)
    equal(FD.Zone.rows[1].name.text, "Literal[-Realm", "highest rating sort starts with own-mode highest rating")
    equal(FD.Zone.rows[5].name.text, "Cap-Realm", "highest rating sort groups other caps after own mode")
    selectOption(FD.Zone.sortFilter, 3)
    equal(FD.Zone.rows[1].name.text, "Alpha-Realm", "closest sort starts with equal own rating")
    equal(FD.Zone.rows[2].name.text, "Beta-Realm", "closest sort uses rating distance")
    equal(FD.Zone.rows[4].name.text, "Literal[-Realm", "closest sort keeps all own-pool comparisons first")
    equal(FD.Zone.rows[5].name.text, "Cap-Realm", "closest sort does not compare ratings from another cap")
    equal(FD.Zone.rows[6].name.text, "Max-Realm", "closest sort does not compare max-level and leveling ratings")
    selectOption(FD.Zone.eligibleFilter, 2)
    equal(#FD.Zone:FilteredPlayers(), 3, "eligible filter requires same pool and at most five levels difference")
    equal(FD.Zone.rows[1].name.text, "Alpha-Realm", "plus-five-level opponent is eligible")
    equal(FD.Zone.rows[2].name.text, "Zulu-Realm", "minus-five-level opponent is eligible")
    equal(FD.Zone.rows[3].name.text, "Literal[-Realm", "eligible filter is independent of rating distance")
    selectOption(FD.Zone.ratingFilter, 2)
    equal(#FD.Zone:FilteredPlayers(), 2, "rating and eligibility filters compose")
    selectOption(FD.Zone.classFilter, 2)
    equal(#FD.Zone:FilteredPlayers(), 1, "class filter composes with rating and eligibility filters")
    state.missingOwn = true
    equal(#FD.Zone:FilteredPlayers(), 0, "unavailable local level cannot qualify rated or rating-distance matches")
    click(FD.Zone.resetFilters)
    equal(#FD.Zone:FilteredPlayers(), 6, "unavailable local rating still permits normal zone browsing")
    equal(FD.Zone.classFilter.text, "Class: All", "reset restores visible class selection")
    equal(FD.Zone.ratingFilter.text, "Rating: All", "reset restores visible rating selection")
    equal(FD.Zone.sortFilter.text, "Sort: Name", "reset restores visible sort selection")
    equal(FD.Zone.eligibleFilter.text, "Rated eligible: All", "reset restores visible eligibility selection")
    state.missingOwn = false
    state.players = {}
    FD.Zone:RefreshIfShown()
    preserved("search, sort, and filter changes")

    click(FD.Zone.classFilter)
    click(FD.Zone.classFilter)
    equal(FD.Zone.classFilter.menu:IsShown(), false, "clicking the same dropdown again closes it")
    click(FD.Zone.classFilter)
    click(FD.Zone.ratingFilter)
    equal(FD.Zone.classFilter.menu:IsShown(), false, "only one dropdown can be open")
    equal(FD.Zone.ratingFilter.menu:IsShown(), true, "opening another dropdown displays its choices")
    FD.Zone:Toggle()
    equal(FD.Zone.frame:IsShown(), false, "toggle closes visible browser")
    equal(FD.Zone.ratingFilter.menu:IsShown(), false, "closing browser also closes its dropdown")
    equal(FD.Zone.dropdownDismiss:IsShown(), false, "closing browser releases outside-click layer")
    env.UIParent:SetSize(640, 480)
    FD.Zone:Show()
    equal(FD.Zone.frame.scale < 1, true, "small screen scales browser into view")
    equal(FD.Zone.openDropdown, nil, "reopening browser does not reopen stale menu")
    click(FD.Zone.classFilter)
    state.failRead = true
    FD.Zone:RefreshIfShown()
    equal(FD.Zone.frame:IsShown(), false, "read failure hides broken browser")
    equal(FD.Zone.classFilter.menu:IsShown(), false, "UI failure also closes the dropdown")
    equal(#state.logs, 1, "read failure logged without core recovery")
    equal(state.logs[1][1], "zone browser", "as a persisted zone browser error")
    preserved("failed rendering")
    state.failRead = false
    state.players = { { guid = "Player-1-3", fullName = "Peer-Realm", rating = 1600 } }
    FD.Zone:Show()
    state.failChallenge = true
    click(FD.Zone.rows[1].duel)
    equal(#state.logs, 2, "challenge exception stays in isolated UI recovery")
    preserved("failed challenge")
    FD.Zone:Show()
    click(FD.Zone.ratingFilter)
    state.failRead = true
    click(FD.Zone.ratingFilter.items[4])
    equal(#state.logs, 3, "dropdown callback failure stays in isolated UI recovery")
    equal(FD.Zone.frame:IsShown(), false, "failed option selection hides broken browser")
    equal(FD.Zone.dropdownDismiss:IsShown(), false, "failed option selection releases outside-click layer")
    preserved("failed dropdown selection")
    FD.Debug.Print = function() error("logger failed") end
    FD.Debug.Log = function() error("logger failed") end
    FD.Debug.Error = function() error("logger failed") end
    state.failRead = true
    equal(pcall(function() FD.Zone:Show() end), true, "logger failure cannot escape isolated recovery")
    preserved("failed logger")
end
