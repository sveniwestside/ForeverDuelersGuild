return function(FD, equal)
    local function client(options)
        options = options or {}
        local env = setmetatable({}, { __index = _G })
        env._G = env
        local state = { registrations = 0, logs = {}, reads = 0, identityReads = 0 }
        state.secret = setmetatable({}, { __tostring = function() error("secret formatted") end,
            __index = function() error("secret indexed") end })
        local active = { state = "IN_PROGRESS" }
        local FD = { Rating = FD.Rating, L = FD.L, Locale = FD.Locale, Wow = {}, Protocol = {}, Presence = {},
            Debug = {}, duel = { active = active } }
        function FD.Wow:Readable(...)
            for i = 1, select("#", ...) do
                if rawequal(select(i, ...), state.secret) then return false end
            end
            return true
        end
        function FD.Protocol:ValidGUID(guid) return type(guid) == "string" and guid:match("^Player%-%d+%-%x+$") ~= nil end
        state.observed = { guid = "Player-1-ABCDE", fullName = "Peer Surname", rating = 1625, level = 30, maxLevel = 60, bracket = "LEVELING" }
        state.peer = { guid = "Player-1-ABCDE", fullName = "Peer Surname", rating = 1625, level = 30, maxLevel = 60, bracket = "LEVELING" }
        state.own = { guid = "Player-1-ABCDE0", fullName = "Own Surname", rating = 1516, level = 60, maxLevel = 60, bracket = "MAX_LEVEL" }
        function FD.Wow:Identity(unit)
            state.identityReads = state.identityReads + 1
            if state.failIdentity then error("identity failed") end
            if state.identity ~= nil then return state.identity end
            return unit == "player" and state.own or state.observed
        end
        -- Presence:Observe corroborates the claim with the visible unit (and
        -- may ask the player on demand); it returns only corroborated entries.
        function FD.Presence:Observe(unit)
            state.reads = state.reads + 1
            state.lastUnit = unit
            if state.failRead then error("cache failed") end
            return state.peer
        end
        function FD.Presence:GetOwnPlayer() return state.own end
        function FD.Debug:Log(...) state.logs[#state.logs + 1] = { ... } end
        function FD:Safe() error("tooltip must not invoke duel-aborting recovery") end
        env.UnitTokenFromGUID = function(guid)
            if state.noToken then return nil end
            if state.token ~= nil then return state.token end
            return guid == state.own.guid and "player" or "mouseover"
        end
        env.UnitIsPlayer = function() if state.isPlayer ~= nil then return state.isPlayer end return true end
        env.UnitGUID = function(unit)
            if state.guid ~= nil then return state.guid end
            return unit == "player" and state.own.guid or state.observed.guid
        end
        env.Enum = { TooltipDataType = { Unit = 2 } }
        env.TooltipDataProcessor = { AddTooltipPostCall = function(kind, callback)
            if state.failRegistration then error("registration failed") end
            state.registrations = state.registrations + 1
            state.callback, state.kind = callback, kind
        end }
        function state:newTooltip()
            local tooltip = { lines = {}, scripts = {}, hookCount = 0 }
            function tooltip:HookScript(name, callback)
                self.hookCount = self.hookCount + 1
                self.scripts[name] = callback
            end
            function tooltip:IsForbidden() return self.forbidden or false end
            function tooltip:HasScript(name) return options.legacy and name == "OnTooltipSetUnit" end
            function tooltip:GetUnit() return self.name or "Peer Surname", self.unit or "mouseover" end
            function tooltip:AddDoubleLine(left, right)
                self.lines[#self.lines + 1] = { left = left, right = right }
                if state.reenter then state.callback(self, state:data()) end
                if state.failAdd then error("presentation failed") end
            end
            function tooltip:ClearLines()
                self.lines = {}
                if self.scripts.OnTooltipCleared then self.scripts.OnTooltipCleared(self) end
            end
            return tooltip
        end
        function state:data() return { type = 2, guid = self.observed.guid } end
        state.tooltip = state:newTooltip()
        env.GameTooltip = state.tooltip
        if options.noModern then env.TooltipDataProcessor = false end
        for _, module in ipairs({ "Native", "Tooltip" }) do
            local chunk = assert(loadfile("ForeverDuel/" .. module .. ".lua"))
            setfenv(chunk, env)
            chunk("ForeverDuel", FD)
        end
        state.FD, state.env, state.active = FD, env, active
        function state:fire(data, tooltip)
            if self.callback then self.callback(tooltip or self.tooltip, data or self:data())
            elseif self.tooltip.scripts.OnTooltipSetUnit then self.tooltip.scripts.OnTooltipSetUnit(self.tooltip) end
        end
        return state
    end

    local c = client()
    equal(c.FD.Tooltip:Initialize(), true, "modern tooltip initializes")
    equal(c.kind, 2, "only unit tooltip callbacks registered")
    equal(c.FD.Tooltip:Initialize(), true, "tooltip initialization repeats safely")
    equal(c.registrations, 1, "only one callback registered")
    c:fire()
    equal(#c.tooltip.lines, 1, "known player receives one rating line")
    equal(c.tooltip.lines[1].left, "Duel Rating (Leveling, Lv 30)", "rating label includes mode and level")
    equal(c.tooltip.lines[1].right, "1625", "fresh cache rating displayed")
    equal(c.lastUnit, "mouseover", "the shown unit is passed to Presence for corroboration")
    c:fire()
    equal(#c.tooltip.lines, 1, "duplicate callback does not append twice")
    equal(c.tooltip.hookCount, 1, "one cleared hook per tooltip")
    c.tooltip:ClearLines()
    c.peer.rating = 1640
    c:fire()
    equal(#c.tooltip.lines, 1, "same player native refresh gets a new line")
    equal(c.tooltip.lines[1].right, "1640", "refresh reads latest rating")
    c.tooltip:ClearLines()
    c.peer.rating, c.noToken = -10, true
    c:fire()
    equal(c.tooltip.lines[1].right, "-10", "negative protocol rating and GetUnit fallback supported")
    c.noToken = nil
    c.tooltip:ClearLines()
    c.peer = nil
    c:fire()
    equal(#c.tooltip.lines, 0, "an uncorroborated, unknown or expired entry has no rating")
    c.peer = { guid = c.observed.guid, fullName = "Another Sender", rating = 1800, level = 30, maxLevel = 60, bracket = "LEVELING" }
    c:fire()
    equal(#c.tooltip.lines, 0, "reported GUID cannot impersonate another transport name")
    c.peer.fullName = c.observed.fullName
    c.peer.guid = "Player-1-BEEF"
    c:fire()
    equal(#c.tooltip.lines, 0, "mismatched cache identity is not displayed")
    c.peer.guid = c.observed.guid
    c.isPlayer = false
    c:fire()
    equal(#c.tooltip.lines, 0, "nonplayer units have no rating")
    c.isPlayer = true
    c:fire({ type = 2, guid = "Player-1-BEEF" })
    equal(#c.tooltip.lines, 0, "tooltip GUID must match resolved unit")
    c:fire({ type = 1, guid = c.observed.guid })
    equal(#c.tooltip.lines, 0, "nonunit tooltip ignored")
    local reads = c.reads
    c:fire({ type = 2, guid = c.own.guid })
    equal(c.tooltip.lines[1].right, "1516", "own current rating displayed without peer record")
    equal(c.reads, reads, "the own tooltip never asks Presence")
    equal(c.tooltip.lines[1].left, "Duel Rating (Max level, Lv 60)", "own tooltip identifies max-level pool")
    local other = c:newTooltip()
    c:fire(nil, other)
    equal(#other.lines, 1, "each tooltip keeps independent build state")

    local function restricted(change, label)
        local blocked = client()
        blocked.FD.Tooltip:Initialize()
        local data = blocked:data()
        change(blocked, data)
        local ok = pcall(function() blocked:fire(data) end)
        equal(ok, true, label .. " remains isolated")
        equal(#blocked.tooltip.lines, 0, label .. " omits rating")
        equal(#blocked.logs, 0, label .. " rejected before secret operation")
    end
    restricted(function(s, d) d.guid = s.secret end, "secret tooltip GUID")
    restricted(function(s, d) d.type = s.secret end, "secret tooltip type")
    restricted(function(s) s.token = s.secret end, "secret unit token")
    restricted(function(s) s.isPlayer = s.secret end, "secret player status")
    restricted(function(s) s.guid = s.secret end, "secret observed GUID")
    restricted(function(s) s.identity = s.secret end, "secret observed identity")
    restricted(function(s) s.observed.fullName = s.secret end, "secret observed name")
    restricted(function(s) s.peer = s.secret end, "secret record")
    restricted(function(s) s.peer.fullName = s.secret end, "secret record name")
    restricted(function(s) s.peer.rating = s.secret end, "secret rating")
    restricted(function(s) s.peer.level = s.secret end, "secret cached level")
    restricted(function(s) s.peer.maxLevel = s.secret end, "secret cached level cap")
    restricted(function(s) s.peer.bracket = s.secret end, "secret cached mode")
    restricted(function(s) s.observed.level = s.secret end, "secret native level")
    restricted(function(s) s.peer.level = 31 end, "stale level announcement")
    restricted(function(s) s.peer.maxLevel = 70 end, "different level-cap announcement")
    restricted(function(s) s.peer.bracket = "MAX_LEVEL" end, "inconsistent cached mode")
    restricted(function(s) s.peer.level = 61 end, "level above cap")
    restricted(function(s) s.tooltip.forbidden = true end, "forbidden tooltip")
    restricted(function(s) s.tooltip.forbidden = s.secret end, "secret forbidden status")
    for _, rating in ipairs({ -100001, 100001, 0 / 0, math.huge, -math.huge, 1500.5, "1500" }) do
        restricted(function(s) s.peer.rating = rating end, "invalid cached rating")
    end
    local secretData = client()
    secretData.FD.Tooltip:Initialize()
    secretData:fire(secretData.secret)
    equal(#secretData.logs, 0, "secret callback data rejected without indexing")

    local legacy = client({ noModern = true, legacy = true })
    equal(legacy.FD.Tooltip:Initialize(), true, "explicitly supported legacy script initializes")
    legacy:fire()
    legacy:fire()
    equal(#legacy.tooltip.lines, 1, "legacy callback also deduplicates")
    legacy.tooltip:ClearLines()
    legacy.tooltip.unit = legacy.secret
    legacy:fire()
    equal(#legacy.tooltip.lines, 0, "secret legacy unit omitted")
    legacy.env.UnitGUID = function() return nil end
    legacy.tooltip.unit = "mouseover"
    legacy:fire()
    equal(#legacy.tooltip.lines, 0, "missing unit identity omitted")
    local absent = client({ noModern = true })
    equal(absent.FD.Tooltip:Initialize(), false, "unsupported tooltip API safely disables presentation")

    local failed = client()
    failed.failRegistration = true
    equal(failed.FD.Tooltip:Initialize(), false, "registration errors isolated")
    equal(failed.FD.duel.active, failed.active, "registration failure preserves active duel")
    failed.failRegistration = false
    equal(failed.FD.Tooltip:Initialize(), true, "failed initialization can recover")
    failed.failRead = true
    failed:fire()
    equal(failed.FD.duel.active, failed.active, "cache read failure preserves active duel")
    equal(#failed.tooltip.lines, 0, "cache failure adds no line")
    failed.failRead, failed.failAdd, failed.reenter = false, true, true
    failed:fire()
    failed:fire()
    equal(#failed.tooltip.lines, 1, "reentrant callback and partial insertion error cannot duplicate line")
    equal(failed.FD.duel.active, failed.active, "tooltip insertion failure preserves active duel")
    local logFailure = client()
    logFailure.FD.Tooltip:Initialize()
    logFailure.failRead = true
    logFailure.FD.Debug.Log = function() error("logging failed") end
    equal(pcall(function() logFailure:fire() end), true, "logger failure is isolated")

    -- Integration with the real Presence: a player tooltip asks once (paced)
    -- and shows a rating only after the claimed GUID is corroborated.
    local Harness = assert(loadfile("tests/presence_harness.lua"))()
    local h = Harness.client({ channel = false, tooltip = true })
    h.env.Enum.TooltipDataType = { Unit = 2 }
    local post
    h.env.TooltipDataProcessor = { AddTooltipPostCall = function(_, callback) post = callback end }
    h:start()
    equal(h.FD.Tooltip:Initialize(), true, "the tooltip hook installs next to real discovery")
    local BETA = { guid = "Player-1-0000BBBB", name = "Beta", surname = "Two", realm = "Forever",
        classFile = "ROGUE", level = 30, faction = "Alliance" }
    h:addUnit("mouseover", BETA)
    local tip = { lines = {} }
    function tip:HookScript(_, callback) self.cleared = callback end
    function tip:IsForbidden() return false end
    function tip:AddDoubleLine(left, right) self.lines[#self.lines + 1] = { left = left, right = right } end
    function tip:ClearLines() self.lines = {}; if self.cleared then self.cleared(self) end end
    local data = { type = 2, guid = BETA.guid }
    post(tip, data)
    equal(#tip.lines, 0, "an unknown player shows no rating")
    h:advance(1)
    equal(#h:whispers("FDQ2"), 1, "showing the tooltip asks the player once")
    for _ = 1, 5 do tip:ClearLines(); post(tip, data) end
    h:advance(5)
    equal(#h:whispers("FDQ2"), 1, "tooltip refreshes do not ask again")
    h:receive(h:profile({ guid = BETA.guid, rating = 2400, classFile = "ROGUE", level = 30 }), "Mallory Evil")
    tip:ClearLines(); post(tip, data)
    equal(#tip.lines, 0, "another sender's claim to this GUID is never shown")
    h:receive(h:profile({ guid = BETA.guid, rating = 1642, classFile = "ROGUE", level = 30 }), "Beta Two")
    tip:ClearLines(); post(tip, data)
    equal(tip.lines[1].left, "Duel Rating (Leveling, Lv 30)", "a corroborated profile shows its mode and level")
    equal(tip.lines[1].right, "1642", "the corroborated rating is shown")
    equal(h.P:FindByName("Beta Two").verified, true, "showing the unit verifies the claim")
end
