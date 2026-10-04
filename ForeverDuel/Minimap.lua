local _, FD = ...
FD.Minimap = {}
local MinimapButton = FD.Minimap
local DEFAULT_ANGLE = 225
local ICON = "Interface\\AddOns\\ForeverDuel\\Media\\Icon.tga"

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function settings()
    local db = FD.Database and FD.Database.data
    return db and type(db.settings) == "table" and db.settings or nil
end

local function readable(...)
    return not FD.Wow or FD.Wow:Readable(...)
end

-- A launcher failure must not enter Core:Safe, which aborts an active duel.
function MinimapButton:Run(callback)
    local ok, result = pcall(callback)
    if ok then return true, result end
    self.dragging = false
    if self.button then pcall(self.button.SetScript, self.button, "OnUpdate", nil) end
    pcall(function()
        if not self.errorReported then
            FD.Debug:Print("Minimap button unavailable. Use /duelrating to open your record.")
        end
        if readable(result) then FD.Debug:Log("minimap button error", result) end
    end)
    self.errorReported = true
    return false
end

function MinimapButton:Angle()
    local saved = settings()
    local angle = saved and saved.minimapAngle
    return readable(angle) and finite(angle) and angle % 360 or DEFAULT_ANGLE
end

function MinimapButton:Position(angle)
    if not self.button or not Minimap or not finite(angle) then return false end
    local width, height = Minimap:GetWidth(), Minimap:GetHeight()
    if not readable(width, height) or not finite(width) or not finite(height)
        or width <= 0 or height <= 0 then return false end
    angle = angle % 360
    local radians = angle * math.pi / 180
    self.button:ClearAllPoints()
    self.button:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(radians) * (width / 2 + 6), math.sin(radians) * (height / 2 + 6))
    self.angle = angle
    return true
end

function MinimapButton:UpdateDrag()
    if not self.dragging then return end
    local x, y = GetCursorPosition()
    local centerX, centerY = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    if not readable(x, y, centerX, centerY, scale) or not finite(x) or not finite(y)
        or not finite(centerX) or not finite(centerY) or not finite(scale) or scale <= 0 then return end
    local dx, dy = x / scale - centerX, y / scale - centerY
    if dx == 0 and dy == 0 then return end
    -- math.atan2 returns radians; WoW's global atan2 wrapper returns degrees.
    local angle = (math.atan2(dy, dx) * 180 / math.pi) % 360
    if self:Position(angle) then
        local saved = settings()
        if saved then saved.minimapAngle = angle end
    end
end

function MinimapButton:StopDrag(updatePosition)
    if updatePosition then self:UpdateDrag() end
    self.dragging = false
    if self.button then self.button:SetScript("OnUpdate", nil) end
end

function MinimapButton:Initialize()
    if not Minimap or not settings() or not FD.Profile then return false end
    local ok, initialized = self:Run(function()
        if self.button then return self:Position(self:Angle()) end
        local button = CreateFrame("Button", "ForeverDuelMinimapButton", Minimap)
        self.button = button
        button:SetSize(32, 32)
        button:EnableMouse(true)
        button:SetMovable(true)
        button:SetFrameStrata("MEDIUM")
        button:SetNormalTexture(ICON)
        button:SetHighlightTexture(ICON, "ADD")
        button:RegisterForClicks("LeftButtonUp")
        button:RegisterForDrag("LeftButton")
        button:SetScript("OnMouseDown", function(_, mouseButton)
            self:Run(function()
                if mouseButton == "LeftButton" then self.ignoreClick = false end
            end)
        end)
        button:SetScript("OnClick", function(_, mouseButton)
            self:Run(function()
                if mouseButton ~= "LeftButton" or self.dragging or self.ignoreClick then return end
                FD.Profile:Toggle()
            end)
        end)
        button:SetScript("OnDragStart", function()
            self:Run(function()
                self.dragging, self.ignoreClick = true, true
                if GameTooltip then GameTooltip:Hide() end
                self:UpdateDrag()
                button:SetScript("OnUpdate", function() self:Run(function() self:UpdateDrag() end) end)
            end)
        end)
        button:SetScript("OnDragStop", function()
            self:Run(function() self:StopDrag(true) end)
        end)
        button:SetScript("OnEnter", function()
            self:Run(function()
                if not GameTooltip or self.dragging then return end
                GameTooltip:SetOwner(button, "ANCHOR_LEFT")
                GameTooltip:SetText("ForeverDuelersGuild", 1, 0.82, 0)
                GameTooltip:AddLine("Left-click: Open your duel record.", 1, 1, 1)
                GameTooltip:AddLine("Drag: Move around the minimap.", 0.7, 0.7, 0.7)
                GameTooltip:Show()
            end)
        end)
        button:SetScript("OnLeave", function()
            self:Run(function() if GameTooltip then GameTooltip:Hide() end end)
        end)
        button:SetScript("OnHide", function()
            self:Run(function()
                self:StopDrag(false)
                if GameTooltip then GameTooltip:Hide() end
            end)
        end)
        if not self:Position(self:Angle()) then button:Hide(); return false end
        button:Show()
        return true
    end)
    return ok and initialized or false
end
