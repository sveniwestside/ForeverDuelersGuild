local _, FD = ...

-- Frame helpers shared by the addon windows (overview, zone browser, queue).
-- Positions are TOPLEFT offsets with y growing downwards.
local Widgets = { GOLD = { 0.94, 0.75, 0.38 }, MUTED = { 0.61, 0.65, 0.70 },
    WHITE = { 0.92, 0.94, 0.97 }, GREEN = { 0.36, 0.85, 0.61 } }
FD.Widgets = Widgets
local ACCENT, BORDER, PANEL = { 0.46, 0.36, 0.19 }, { 0.20, 0.23, 0.28 }, { 0.075, 0.09, 0.115 }
local FLAT = { bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 }

function Widgets.Surface(frame, fill, border)
    frame:SetBackdrop(FLAT)
    frame:SetBackdropColor(fill[1], fill[2], fill[3], fill[4] or 1)
    border = border or BORDER
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

-- Fixed-size text; only a `wrap` label breaks onto further lines.
function Widgets.Label(parent, font, x, y, width, height, rgb, wrap)
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    text:SetPoint("TOPLEFT", x, -y)
    text:SetSize(width, height)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetWordWrap(wrap == true)
    rgb = rgb or Widgets.WHITE
    text:SetTextColor(rgb[1], rgb[2], rgb[3])
    return text
end

function Widgets.Panel(parent, x, y, width, height, fill, border)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetPoint("TOPLEFT", x, -y)
    frame:SetSize(width, height)
    Widgets.Surface(frame, fill or PANEL, border)
    return frame
end

-- click(button) runs inside the owner's own error policy (see Run).
function Widgets.Button(parent, text, width, x, y, click)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 26)
    button:SetPoint("TOPLEFT", x, -y)
    if text then button:SetText(text) end
    button:SetScript("OnClick", function() click(button) end)
    return button
end

-- A movable, screen-clamped window, created hidden; onHide runs after any
-- drag has stopped.
function Widgets.Window(name, width, height, onHide)
    local frame = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    frame:SetSize(width, height)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    Widgets.Surface(frame, { 0.055, 0.065, 0.085, 0.98 }, ACCENT)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() frame:StartMoving() end)
    frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    frame:SetScript("OnHide", function()
        frame:StopMovingOrSizing()
        if onHide then onHide() end
    end)
    frame:Hide()
    return frame
end

-- UIParent dimensions are already in UI units; shrink the whole window on
-- smaller displays while leaving the player's UI scale untouched.
function Widgets.Fit(frame, width, height)
    local scale = math.min(1, (UIParent:GetWidth() - 40) / width, (UIParent:GetHeight() - 40) / height)
    frame:SetScale(math.max(0.1, scale))
end

-- Optional presentation must never enter Core:Safe, whose recovery aborts an
-- active duel: a failure hides only the owner's window, tells the player
-- `message` and persists the error with its stack under `context`
-- (/duelrating errors), like every other addon error.
function Widgets.Run(owner, callback, message, context)
    local stack
    local ok, result, reason = xpcall(callback, function(err)
        if type(debugstack) == "function" then
            local captured, value = pcall(debugstack, 2, 8, 0)
            if captured then stack = value end
        end
        return err
    end)
    if ok then return true, result, reason end
    if owner.frame then pcall(owner.frame.Hide, owner.frame) end
    pcall(function() FD.Debug:Print(message) end)
    pcall(FD.Debug.Error, FD.Debug, context, FD.Native.Readable(result) and result or "restricted error", stack)
    return false
end

-- Window plumbing for owners with frame, Run, Show and Refresh.
function Widgets.Toggle(owner)
    if owner.frame and owner.frame:IsShown() then return owner:Run(function() owner.frame:Hide() end) end
    return owner:Show()
end

function Widgets.RefreshIfShown(owner)
    if owner.frame and owner.frame:IsShown() then return owner:Run(function() owner:Refresh() end) end
end

-- Addon-owned menus use the same basic frame APIs as the windows. The
-- dismiss layer closes an open menu on an outside click and does nothing else.
-- The owner provides Run, CloseDropdown and ToggleDropdown.
function Widgets.DismissLayer(owner, frame)
    local layer = CreateFrame("Button", nil, frame)
    layer:SetPoint("TOPLEFT", UIParent, "TOPLEFT")
    layer:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT")
    layer:SetFrameStrata("DIALOG")
    layer:SetScript("OnClick", function() owner:Run(function() owner:CloseDropdown() end) end)
    layer:Hide()
    owner.dropdownDismiss = layer
end

-- selected() returns the current option index; choose(index) applies a pick.
function Widgets.Dropdown(owner, parent, text, width, x, y, options, selected, choose, wrap)
    local control
    control = Widgets.Button(parent, text, width, x, y, function()
        owner:Run(function() owner:ToggleDropdown(control) end)
    end)
    Widgets.Label(control, "GameFontHighlightSmall", width - 17, 7, 12, 16, Widgets.MUTED, wrap):SetText("v")
    control.options, control.selected, control.items = options, selected, {}
    local menu = CreateFrame("Frame", nil, owner.dropdownDismiss, "BackdropTemplate")
    menu:SetPoint("TOPLEFT", control, "BOTTOMLEFT", 0, -2)
    menu:SetSize(width, #options * 26 + 8)
    menu:EnableMouse(true)
    menu:SetClampedToScreen(true)
    Widgets.Surface(menu, { 0.065, 0.075, 0.095, 1 }, ACCENT)
    for index, option in ipairs(options) do
        local item = CreateFrame("Button", nil, menu)
        item:SetSize(width - 8, 26)
        item:SetPoint("TOPLEFT", 4, -(4 + (index - 1) * 26))
        item:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        item.caption = Widgets.Label(item, "GameFontHighlightSmall", 6, 7, width - 20, 18, nil, wrap)
        item.caption:SetText(option)
        item:SetScript("OnClick", function() owner:Run(function() choose(index) end) end)
        control.items[index] = item
    end
    control.menu = menu
    menu:Hide()
    return control
end

-- Marks the current choice and shows the menu above the dismiss layer.
function Widgets.OpenDropdown(owner, control)
    local selected = control.selected()
    for index, item in ipairs(control.items) do
        local chosen = index == selected
        item.caption:SetText((chosen and "> " or "   ") .. control.options[index])
        local rgb = chosen and Widgets.GOLD or Widgets.WHITE
        item.caption:SetTextColor(rgb[1], rgb[2], rgb[3])
    end
    owner.openDropdown = control
    owner.dropdownDismiss:Show()
    control.menu:Show()
end

function Widgets.CloseDropdown(owner)
    if owner.openDropdown then owner.openDropdown.menu:Hide() end
    owner.openDropdown = nil
    if owner.dropdownDismiss then owner.dropdownDismiss:Hide() end
end
