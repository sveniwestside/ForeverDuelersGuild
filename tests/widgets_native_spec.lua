return function(_, equal)
    -- Native: secret values, non-finite numbers, bounds and failing APIs.
    local secret = setmetatable({}, { __tostring = function() error("secret formatted") end })
    local clock = { now = 12.5, server = 1700000000 }
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.issecretvalue = function(value) return rawequal(value, secret) end
    env.GetTime = function() return clock.now end
    env.GetServerTime = function() return clock.server end
    local FD = {}
    local function load(name, namespace, environment)
        local chunk = assert(loadfile("ForeverDuel/" .. name .. ".lua"))
        setfenv(chunk, environment or env)("ForeverDuel", namespace or FD)
    end
    load("Locale")
    load("Native")
    local N = FD.Native

    equal(N.Readable(1, "a", nil, false), true, "plain values are readable")
    equal(N.Readable(1, secret), false, "issecretvalue rejects a secret among several values")
    equal(N.Readable(nil, secret, nil), false, "a secret after nils is still found")
    local asked = 0
    FD.Wow = { Readable = function(_, ...) asked = asked + 1; return select("#", ...) ~= 2 end }
    equal(N.Readable(1, 2), false, "FD.Wow:Readable decides once loaded")
    equal(N.Readable(1), true, "FD.Wow:Readable receives every value")
    equal(asked, 2, "FD.Wow:Readable is asked for each check")
    FD.Wow = nil
    env.issecretvalue = nil
    equal(N.Readable(secret), true, "without any secret API values are readable")
    env.issecretvalue = function(value) return rawequal(value, secret) end

    equal(N.Finite(0) and true, true, "zero is finite")
    equal(N.Finite(-12.5) and true, true, "negative fractions are finite")
    equal(N.Finite(0 / 0) and true or false, false, "NaN is rejected")
    equal(N.Finite(math.huge) and true or false, false, "infinity is rejected")
    equal(N.Finite(-math.huge) and true or false, false, "negative infinity is rejected")
    equal(N.Finite("5") and true or false, false, "numeric strings are not numbers")
    equal(N.Finite(secret) and true or false, false, "a secret number is never compared")
    equal(N.Finite(5, 5, 5) and true, true, "bounds are inclusive")
    equal(N.Finite(4.99, 5) and true or false, false, "lower bound enforced")
    equal(N.Finite(5.01, nil, 5) and true or false, false, "upper bound enforced")
    equal(N.Integer(7, 1, 10) and true, true, "integers within bounds pass")
    equal(N.Integer(7.5, 1, 10) and true or false, false, "fractions are not integers")
    equal(N.Integer(math.huge) and true or false, false, "infinity is not an integer")
    equal(N.Integer(0 / 0, 0) and true or false, false, "NaN is not an integer")

    equal(N.Text("Peer-Realm") and true, true, "a whisper address is text")
    equal(N.Text("") and true or false, false, "empty text rejected")
    equal(N.Text("a|cFF0000") and true or false, false, "UI escapes rejected")
    equal(N.Text("a\nb") and true or false, false, "control characters rejected")
    equal(N.Text(string.rep("a", 128)) and true, true, "128 characters by default")
    equal(N.Text(string.rep("a", 129)) and true or false, false, "longer text rejected by default")
    equal(N.Text(string.rep("a", 64), 63) and true or false, false, "explicit maximum enforced")
    equal(N.Text(secret) and true or false, false, "secret text rejected")
    equal(N.Text(42) and true or false, false, "numbers are not text")

    equal(N.Plain("a|cFF0000b"), "a||cFF0000b", "plain text escapes UI markup")
    equal(N.Plain(nil), "", "nil displays as empty text")
    equal(N.Plain(12), "12", "numbers display as text")
    equal(N.Plain(secret), "Unavailable", "a secret value is never stringified")
    FD.Locale:Register("xxXX", { Unavailable = "Nicht lesbar" })
    FD.Locale.current = "xxXX"
    equal(N.Plain(secret), "Nicht lesbar", "the unavailable marker is localized")
    FD.Locale.current = "enUS"

    equal(N.Call(nil), nil, "a missing API returns nil")
    equal(N.Call("GetTime"), nil, "a non-function returns nil")
    equal(N.Call(function() error("native failure") end), nil, "a failing API returns nil")
    equal(select("#", N.Call(function() error("native failure") end)), 1, "a failure is exactly one nil")
    local a, b, c = N.Call(function(x, y) return x + y, "two", nil end, 2, 3)
    equal(a, 5, "arguments are passed through")
    equal(b, "two", "every result is returned")
    equal(c, nil, "trailing nils survive")
    equal(N.Call(function() return 1, secret end), nil, "any secret result discards all results")
    local x, y = N.Call(function() return 1, 2, 3, 4, secret end)
    equal(x == nil and y == nil, true, "a secret beyond the fourth result is found too")

    equal(N.Now(), 12.5, "GetTime is read")
    clock.now = 0 / 0
    equal(N.Now(), 0, "a NaN clock falls back to 0")
    clock.now = -1
    equal(N.Now(), 0, "a negative clock falls back to 0")
    clock.now = secret
    equal(N.Now(), 0, "a secret clock falls back to 0")
    env.GetTime = function() error("clock failed") end
    equal(N.Now(), 0, "a failing clock falls back to 0")
    env.GetTime = nil
    equal(N.Now(), 0, "a missing clock falls back to 0")
    equal(N.Epoch(), 1700000000, "GetServerTime is read")
    clock.server = 1700000000.5
    equal(N.Epoch(), nil, "server time must be whole seconds")
    clock.server = secret
    equal(N.Epoch(), nil, "a secret server time is unavailable")
    env.GetServerTime = function() error("server time failed") end
    equal(N.Epoch(), nil, "a failing server time is unavailable")
    env.GetServerTime = nil
    equal(N.Epoch(), nil, "a missing server time is unavailable")

    -- Widgets: layout values, the dropdown cycle and the error policy.
    local methods, created = {}, {}
    local function widget(kind, name, parent, template)
        local object = setmetatable({ kind = kind, name = name, parent = parent, template = template,
            scripts = {}, points = {}, shown = true }, { __index = methods })
        created[#created + 1] = object
        return object
    end
    function methods:SetSize(width, height) self.width, self.height = width, height end
    function methods:GetWidth() return self.width end
    function methods:GetHeight() return self.height end
    function methods:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function methods:SetText(value) self.text = value end
    function methods:SetTextColor(r, g, b) self.color = { r, g, b } end
    function methods:SetWordWrap(value) self.wrap = value end
    function methods:SetJustifyH(value) self.justifyH = value end
    function methods:SetJustifyV(value) self.justifyV = value end
    function methods:SetBackdrop(value) self.backdrop = value end
    function methods:SetBackdropColor(...) self.fill = { ... } end
    function methods:SetBackdropBorderColor(...) self.border = { ... } end
    function methods:SetFrameStrata(value) self.strata = value end
    function methods:SetScale(value) self.scale = value end
    function methods:SetScript(name, callback) self.scripts[name] = callback end
    function methods:CreateFontString(_, layer, font)
        local text = widget("FontString", nil, self)
        text.layer, text.font = layer, font
        return text
    end
    function methods:IsShown() return self.shown end
    function methods:Show() self.shown = true end
    function methods:Hide()
        local was = self.shown
        self.shown = false
        if was and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    for _, name in ipairs({ "SetMovable", "EnableMouse", "SetClampedToScreen", "RegisterForDrag", "StartMoving",
        "StopMovingOrSizing", "SetHighlightTexture" }) do
        methods[name] = function(self) self[name .. "Calls"] = (self[name .. "Calls"] or 0) + 1 end
    end
    local ui = setmetatable({ CreateFrame = widget }, { __index = env })
    ui._G = ui
    ui.UIParent = widget("Frame", "UIParent")
    ui.UIParent:SetSize(1920, 1080)
    load("Widgets", FD, ui)
    local W = FD.Widgets

    local label = W.Label(ui.UIParent, "GameFontHighlightSmall", 16, 13, 720, 18)
    equal(label.points[1][1], "TOPLEFT", "labels anchor top left")
    equal(label.points[1][2] == 16 and label.points[1][3] == -13, true, "label y grows downwards")
    equal(label.width == 720 and label.height == 18, true, "label keeps its fixed size")
    equal(label.wrap, false, "labels are single-line by default")
    equal(label.color[1], W.WHITE[1], "labels default to white")
    equal(label.justifyH == "LEFT" and label.justifyV == "TOP", true, "labels justify top left")
    equal(W.Label(ui.UIParent, "GameFontHighlight", 0, 0, 10, 10, W.GOLD, true).wrap, true, "wrapping is opt-in")

    local panel = W.Panel(ui.UIParent, 24, 85, 752, 212)
    equal(panel.template, "BackdropTemplate", "panels carry a backdrop")
    equal(panel.backdrop.edgeSize, 1, "panels use a one-pixel edge")
    equal(panel.fill[1] == 0.075 and panel.fill[4] == 1, true, "default panel fill")
    equal(panel.border[1] == 0.20 and panel.border[4] == 1, true, "default panel border")
    W.Surface(panel, { 0.1, 0.2, 0.3, 0.5 }, { 0.4, 0.5, 0.6, 0.7 })
    equal(panel.fill[4] == 0.5 and panel.border[4] == 0.7, true, "explicit alpha values are kept")

    local clicks = {}
    local button = W.Button(ui.UIParent, "Join", 170, 24, 714, function(self) clicks[#clicks + 1] = self end)
    equal(button.template == "UIPanelButtonTemplate" and button.height == 26, true, "buttons are 26 high")
    equal(button.text, "Join", "button caption")
    button.scripts.OnClick()
    equal(clicks[1], button, "the click handler receives its button")
    equal(W.Button(ui.UIParent, nil, 10, 0, 0, function() end).text, nil, "a captionless button stays empty")

    local hidden = 0
    local window = W.Window("ForeverDuelTest", 800, 600, function() hidden = hidden + 1 end)
    equal(window.name == "ForeverDuelTest" and window.parent == ui.UIParent, true, "windows are named UIParent children")
    equal(window.shown, false, "windows are created hidden")
    equal(hidden, 1, "creating the window runs its hide handler once")
    equal(window.StopMovingOrSizingCalls, 1, "hiding a window ends any drag first")
    equal(window.strata, "HIGH", "windows use the HIGH strata")
    equal(window.border[1], 0.46, "windows use the accent border")
    W.Fit(window, 800, 600)
    equal(window.scale, 1, "large screens keep full size")
    ui.UIParent:SetSize(840, 340)
    W.Fit(window, 800, 600)
    equal(window.scale, 0.5, "small screens shrink the window")
    ui.UIParent:SetSize(10, 10)
    W.Fit(window, 800, 600)
    equal(window.scale, 0.1, "the scale never drops below 0.1")

    local prints, errors = {}, {}
    FD.Debug = { Print = function(_, text) prints[#prints + 1] = text end,
        Error = function(_, context, message, stack)
            errors[#errors + 1] = { context = context, message = message, stack = stack }
        end }
    local owner = { frame = window }
    window:Show()
    local ok, first, second = W.Run(owner, function() return "value", "reason" end, "failed", "context")
    equal(ok and first == "value" and second == "reason", true, "Run passes results through")
    equal(W.Run(owner, function() error("broken") end, "failed", "context"), false, "Run contains errors")
    equal(window.shown, false, "a failure hides the owner's window")
    equal(prints[1], "failed", "the player is told")
    equal(errors[1].context, "context", "the error is persisted under its context (/duelrating errors)")
    equal(tostring(errors[1].message):find("broken", 1, true) ~= nil, true, "with its message")
    W.Run(owner, function() error(secret) end, "failed", "context")
    equal(errors[2].message, "restricted error", "a secret error never reaches the saved errors")
    FD.Debug.Print = function() error("print failed") end
    equal(W.Run({}, function() error("again") end, "failed", "context"), false, "a failing report stays contained")

    -- A dropdown opens above its dismiss layer, marks the selection and closes
    -- on a pick or an outside click.
    local picked
    local menuOwner = { frame = window }
    function menuOwner:Run(callback) return W.Run(self, callback, "failed", "menu") end
    menuOwner.CloseDropdown = W.CloseDropdown
    function menuOwner:ToggleDropdown(control)
        local wasOpen = self.openDropdown == control
        self:CloseDropdown()
        if not wasOpen then W.OpenDropdown(self, control) end
    end
    W.DismissLayer(menuOwner, window)
    equal(menuOwner.dropdownDismiss.shown, false, "the dismiss layer starts hidden")
    equal(menuOwner.dropdownDismiss.strata, "DIALOG", "the dismiss layer covers the windows")
    local current = 2
    local control = W.Dropdown(menuOwner, window, "Sort", 240, 24, 214, { "Name", "Rating" },
        function() return current end, function(index) picked = index end)
    equal(control.text, "Sort", "the dropdown shows its caption")
    equal(control.items[2].caption.wrap, false, "menu captions follow the wrap choice")
    equal(control.menu.parent, menuOwner.dropdownDismiss, "menus live on the dismiss layer")
    equal(control.menu.height, 2 * 26 + 8, "menu height follows the options")
    equal(control.menu.shown, false, "menus start closed")
    control.scripts.OnClick()
    equal(control.menu.shown and menuOwner.dropdownDismiss.shown, true, "a click opens the menu and dismiss layer")
    equal(control.items[2].caption.text, "> Rating", "the current choice is marked")
    equal(control.items[1].caption.text, "   Name", "other choices are indented")
    equal(control.items[2].caption.color[1], W.GOLD[1], "the current choice is gold")
    control.items[1].scripts.OnClick()
    equal(picked, 1, "a pick reports its index")
    menuOwner:CloseDropdown()
    equal(control.menu.shown or menuOwner.dropdownDismiss.shown, false, "closing hides menu and layer")
    control.scripts.OnClick()
    menuOwner.dropdownDismiss.scripts.OnClick()
    equal(control.menu.shown, false, "an outside click closes the menu")
    equal(menuOwner.openDropdown, nil, "no menu stays registered as open")
    control.scripts.OnClick()
    control.scripts.OnClick()
    equal(control.menu.shown, false, "a second click on the control closes its menu")

    -- Toggle and RefreshIfShown do no work for a hidden window.
    local refreshed, opened = 0, 0
    local toggler = { frame = W.Window("ForeverDuelToggle", 100, 100) }
    function toggler:Run(callback) return W.Run(self, callback, "failed", "toggle") end
    function toggler:Refresh() refreshed = refreshed + 1 end
    function toggler:Show() opened = opened + 1; self.frame:Show(); return true end
    W.RefreshIfShown(toggler)
    equal(refreshed, 0, "a hidden window is not refreshed")
    equal(W.Toggle(toggler), true, "toggling a hidden window shows it")
    W.RefreshIfShown(toggler)
    equal(refreshed, 1, "a shown window is refreshed")
    equal(W.Toggle(toggler), true, "toggling a shown window hides it")
    equal(toggler.frame.shown == false and opened == 1, true, "the second toggle only hides")
end
