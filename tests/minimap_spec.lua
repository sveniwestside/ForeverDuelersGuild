return function(_, equal)
    local function client(options)
        options = options or {}
        local env = setmetatable({}, { __index = _G })
        env._G = env
        local active = { state = "IN_PROGRESS", matchId = "preserve-duel" }
        local state = { created = 0, toggles = 0, prints = {}, logs = {}, cursorX = 320, cursorY = 320 }
        local FD = {
            Database = { data = { settings = options.settings or { debug = false },
                player = { rating = 1516, wins = 1, losses = 0 }, matches = { "existing-record" } } },
            Profile = {}, Debug = {}, duel = { active = active },
            Wow = { Readable = function(_, ...) for index = 1, select("#", ...) do
                if select(index, ...) == state.secret then return false end
            end return true end },
        }
        state.secret = {}
        function FD.Profile:Toggle()
            if state.failToggle then error("toggle failed") end
            state.toggles = state.toggles + 1
        end
        function FD.Debug:Print(message) state.prints[#state.prints + 1] = message end
        function FD.Debug:Log(...) state.logs[#state.logs + 1] = { ... } end
        function FD:Safe() error("Minimap must not invoke duel-aborting recovery") end
        local methods = {}
        function methods:SetSize(width, height) self.width, self.height = width, height end
        function methods:EnableMouse(enabled) self.mouseEnabled = enabled end
        function methods:SetMovable(movable) self.movable = movable end
        function methods:SetFrameStrata(strata) self.strata = strata end
        function methods:SetNormalTexture(path) self.texture = path end
        function methods:SetHighlightTexture(path) self.highlight = path end
        function methods:RegisterForClicks(button) self.clicks = button end
        function methods:RegisterForDrag(button) self.drags = button end
        function methods:SetScript(name, callback) self.scripts[name] = callback end
        function methods:ClearAllPoints() self.point = nil end
        function methods:SetPoint(...) self.point = { ... } end
        function methods:Show() self.shown = true end
        function methods:Hide()
            self.shown = false
            if self.scripts.OnHide then self.scripts.OnHide(self) end
        end
        env.CreateFrame = function(kind, name, parent)
            state.created = state.created + 1
            return setmetatable({ kind = kind, name = name, parent = parent, scripts = {} }, { __index = methods })
        end
        env.Minimap = {
            GetWidth = function() return state.width or 140 end,
            GetHeight = function() return state.height or 140 end,
            GetCenter = function() return state.centerX or 100, state.centerY or 100 end,
            GetEffectiveScale = function() return state.scale or 2 end,
        }
        if options.noMinimap then env.Minimap = false end
        local tooltip = { lines = {} }
        function tooltip:SetOwner(owner, anchor) self.owner, self.anchor = owner, anchor end
        function tooltip:SetText(text) self.title, self.lines = text, {} end
        function tooltip:AddLine(text) self.lines[#self.lines + 1] = text end
        function tooltip:Show() self.shown = true end
        function tooltip:Hide() self.shown = false end
        env.GameTooltip = tooltip
        env.GetCursorPosition = function()
            if state.failCursor then error("cursor failed") end
            return state.cursorX, state.cursorY
        end
        local chunk = assert(loadfile("ForeverDuel/Minimap.lua"))
        setfenv(chunk, env)
        chunk("ForeverDuel", FD)
        state.FD, state.env, state.active = FD, env, active
        function state:fire(event, ...)
            local button = self.FD.Minimap.button
            local callback = button and button.scripts[event]
            if callback then callback(button, ...) end
        end
        function state:click()
            self:fire("OnMouseDown", "LeftButton")
            self:fire("OnClick", "LeftButton")
        end
        function state:preserved(label)
            equal(self.FD.duel.active, self.active, label .. " preserves active duel")
            equal(self.FD.duel.active.state, "IN_PROGRESS", label .. " preserves duel state")
            equal(self.FD.Database.data.player.rating, 1516, label .. " preserves rating")
            equal(self.FD.Database.data.matches[1], "existing-record", label .. " preserves history")
        end
        return state
    end

    local c = client()
    equal(c.FD.Minimap:Initialize(), true, "minimap launcher initializes")
    local button = c.FD.Minimap.button
    equal(button.parent, c.env.Minimap, "launcher belongs to native minimap")
    equal(button.width, 32, "launcher width")
    equal(button.height, 32, "launcher height")
    equal(button.mouseEnabled, true, "launcher receives mouse input")
    equal(button.drags, "LeftButton", "left drag is registered")
    equal(button.texture, "Interface\\AddOns\\ForeverDuel\\Media\\Icon.tga", "launcher uses packaged emblem")
    equal(button.shown, true, "launcher visible")
    equal(c.FD.Minimap.angle, 225, "missing saved angle uses safe default")
    equal(c.FD.Database.data.settings.minimapAngle, nil, "initialization does not rewrite settings")
    equal(c.FD.Minimap:Initialize(), true, "initialization is repeatable")
    equal(c.created, 1, "repeat initialization reuses button")
    c:click()
    equal(c.toggles, 1, "left click opens overview")
    c:fire("OnClick", "RightButton")
    equal(c.toggles, 1, "other clicks do not trigger actions")
    c:preserved("click")
    c:fire("OnEnter")
    equal(c.env.GameTooltip.title, "ForeverDuelersGuild", "tooltip identifies addon")
    equal(#c.env.GameTooltip.lines, 2, "tooltip describes click and drag")
    equal(c.env.GameTooltip.owner, button, "tooltip owned by launcher")
    equal(c.env.GameTooltip.shown, true, "hover shows tooltip")
    c:fire("OnLeave")
    equal(c.env.GameTooltip.shown, false, "leaving hides tooltip")

    -- At effective scale 2, screen cursor (400,200) is east of center(100,100).
    c.cursorX, c.cursorY = 400, 200
    c:fire("OnMouseDown", "LeftButton")
    c:fire("OnDragStart")
    equal(c.FD.Minimap.dragging, true, "drag begins")
    equal(c.FD.Database.data.settings.minimapAngle, 0, "cursor position respects minimap scale")
    equal(button.point[4], 76, "east position remains on minimap perimeter")
    equal(button.point[5], 0, "east position has no vertical offset")
    equal(type(button.scripts.OnUpdate), "function", "cursor tracking active only during drag")
    c.cursorX, c.cursorY = 200, 400
    c:fire("OnUpdate")
    equal(c.FD.Database.data.settings.minimapAngle, 90, "drag updates saved angle")
    c:fire("OnDragStop")
    equal(c.FD.Minimap.dragging, false, "drag ends")
    equal(button.scripts.OnUpdate, nil, "drag tracking stops after release")
    c:fire("OnClick", "LeftButton")
    equal(c.toggles, 1, "drag release does not open overview")
    c:click()
    equal(c.toggles, 2, "next intentional click works after drag")
    c:preserved("drag")
    local reloaded = client({ settings = { debug = false, minimapAngle = c.FD.Database.data.settings.minimapAngle } })
    reloaded.FD.Minimap:Initialize()
    equal(reloaded.FD.Minimap.angle, 90, "saved angle survives reload")

    local previousDB = c.FD.Database.data
    c.FD.Database.data = { settings = { debug = false, minimapAngle = 90 },
        player = previousDB.player, matches = previousDB.matches }
    c.width, c.height, c.cursorX, c.cursorY = 198, 198, 400, 200
    c:fire("OnMouseDown", "LeftButton")
    c:fire("OnDragStart")
    equal(button.point[4], 105, "perimeter follows current native minimap size")
    equal(c.FD.Database.data.settings.minimapAngle, 0, "drag updates current database after replacement")
    equal(previousDB.settings.minimapAngle, 90, "drag never writes an obsolete settings table")
    c.cursorX, c.cursorY = 200, 400
    c:fire("OnUpdate")
    c:fire("OnDragStop")
    local getCenter = c.env.Minimap.GetCenter
    c.env.Minimap.GetCenter = function() return nil end
    c:fire("OnDragStart")
    equal(c.FD.Database.data.settings.minimapAngle, 90, "missing minimap center preserves saved position")
    c:fire("OnDragStop")
    c.env.Minimap.GetCenter = getCenter

    for _, invalid in ipairs({ "north", false, {}, 0 / 0, math.huge, -math.huge }) do
        local bad = client({ settings = { debug = false, minimapAngle = invalid } })
        equal(bad.FD.Minimap:Initialize(), true, "invalid optional angle does not prevent launcher")
        equal(bad.FD.Minimap.angle, 225, "invalid optional angle uses default")
    end
    local wrapped = client({ settings = { debug = false, minimapAngle = -90 } })
    wrapped.FD.Minimap:Initialize()
    equal(wrapped.FD.Minimap.angle, 270, "negative angle normalized for display")
    equal(wrapped.FD.Database.data.settings.minimapAngle, -90, "display normalization does not rewrite saved data")
    local absent = client({ noMinimap = true })
    equal(absent.FD.Minimap:Initialize(), false, "missing native minimap is a no-op")
    equal(absent.created, 0, "missing native minimap creates no frame")
    absent:preserved("missing minimap")
    local malformed = client()
    malformed.FD.Database.data.settings = "bad"
    equal(malformed.FD.Minimap:Initialize(), false, "malformed settings table safely disables launcher")
    equal(malformed.FD.Database.data.settings, "bad", "malformed settings are preserved")

    c.cursorX, c.cursorY = 200, 200
    c:fire("OnDragStart")
    equal(c.FD.Database.data.settings.minimapAngle, 90, "center cursor preserves last valid angle")
    c.scale = 0
    c:fire("OnUpdate")
    equal(c.FD.Database.data.settings.minimapAngle, 90, "zero scale never corrupts angle")
    c.scale, c.cursorX = 2, c.secret
    c:fire("OnUpdate")
    equal(c.FD.Database.data.settings.minimapAngle, 90, "restricted cursor value is not used")
    c:fire("OnHide")
    equal(button.scripts.OnUpdate, nil, "hidden minimap stops drag work")

    c.failToggle = true
    c:click()
    equal(#c.prints, 1, "action failure reports slash-command fallback")
    equal(#c.logs, 1, "action failure remains locally logged")
    c:preserved("failed toggle")
    c:click()
    equal(#c.prints, 1, "repeated failure does not spam fallback text")
    c.failToggle, c.failCursor = false, true
    c:fire("OnDragStart")
    equal(c.FD.Minimap.dragging, false, "drag error clears active tracking")
    equal(button.scripts.OnUpdate, nil, "drag error removes frame callback")
    c:preserved("failed drag")
    c.FD.Debug.Print = function() error("logger failed") end
    c.FD.Debug.Log = function() error("logger failed") end
    c.failToggle = true
    local ok = pcall(function() c:click() end)
    equal(ok, true, "logger failure cannot escape isolated button recovery")
    c:preserved("failed logger")
end
