local _, FD = ...
FD.Tooltip = {}
local Tooltip = FD.Tooltip
local tracked = setmetatable({}, { __mode = "k" })

local function readable(...)
    return FD.Wow and FD.Wow:Readable(...)
end

-- Optional presentation must never enter Core:Safe and abort an active duel.
function Tooltip:Run(callback)
    local ok, result = pcall(callback)
    if not ok and not self.errorReported then
        self.errorReported = true
        pcall(function()
            if readable(result) then FD.Debug:Log("player tooltip error", result) end
        end)
    end
    return ok, result
end

function Tooltip:Track(tooltip)
    local state = tracked[tooltip]
    if state then return state end
    if type(tooltip.HookScript) ~= "function" then return nil end
    state = {}
    -- ClearLines fires this for each new build, including native refreshes.
    -- Keep state outside the native tooltip to avoid tainting its data fields.
    tooltip:HookScript("OnTooltipCleared", function() state.added = nil end)
    tracked[tooltip] = state
    return state
end

function Tooltip:AddRating(tooltip, data)
    if not readable(tooltip, data) or not tooltip or not FD.Presence then return end
    if type(tooltip.IsForbidden) == "function" then
        local forbidden = tooltip:IsForbidden()
        if not readable(forbidden) or forbidden then return end
    end
    if type(tooltip.AddDoubleLine) ~= "function" or type(UnitIsPlayer) ~= "function"
        or type(UnitGUID) ~= "function" then return end

    local unit, expectedGUID
    if data ~= nil then
        if type(data) ~= "table" or not readable(data.type, data.guid)
            or data.type ~= Enum.TooltipDataType.Unit or type(data.guid) ~= "string" then return end
        expectedGUID = data.guid
        if type(UnitTokenFromGUID) == "function" then
            unit = UnitTokenFromGUID(expectedGUID)
            if not readable(unit) then return end
        end
        if unit == nil and type(tooltip.GetUnit) == "function" then
            local name
            name, unit = tooltip:GetUnit()
            if not readable(name, unit) then return end
        end
    elseif type(tooltip.GetUnit) == "function" then
        local name
        name, unit = tooltip:GetUnit()
        if not readable(name, unit) then return end
    end
    if not readable(unit) or type(unit) ~= "string" or unit == "" then return end
    local player = UnitIsPlayer(unit)
    if not readable(player) or not player then return end
    local guid = UnitGUID(unit)
    if not readable(guid) or type(guid) ~= "string" or not FD.Protocol:ValidGUID(guid)
        or (expectedGUID and guid ~= expectedGUID) then return end

    -- Presence is a self-report keyed by the sender name. Only an entry whose
    -- claimed GUID this visible unit corroborates is shown; an unknown player
    -- is asked for a profile on demand (rate limited inside Presence).
    local identity = FD.Wow:Identity(unit)
    if not readable(identity) or type(identity) ~= "table"
        or not readable(identity.guid, identity.fullName) or identity.guid ~= guid
        or type(identity.fullName) ~= "string" then return end
    local record = FD.Presence:GetOwnPlayer()
    if not readable(record) then return end
    if type(record) ~= "table" or not readable(record.guid) or record.guid ~= guid then
        record = FD.Presence:Observe(unit, identity)
    end
    if not readable(record) or type(record) ~= "table"
        or not readable(record.guid, record.fullName, record.rating, record.level, record.maxLevel, record.bracket)
        or record.guid ~= guid or record.fullName ~= identity.fullName then return end
    local rating = record.rating
    if type(rating) ~= "number" or rating ~= rating or rating < -100000
        or rating > 100000 or rating % 1 ~= 0 then return end
    local bracket = FD.Rating:Bracket(record.level, record.maxLevel)
    if not bracket or bracket ~= record.bracket
        or not readable(identity.level, identity.maxLevel)
        or identity.level ~= record.level or identity.maxLevel ~= record.maxLevel then return end

    local state = self:Track(tooltip)
    if not state or state.added then return end
    -- Mark first so a reentrant callback or an error after insertion cannot
    -- duplicate this line. A native rebuild permits a fresh cache read.
    state.added = true
    local mode = bracket == "MAX_LEVEL" and FD.L["Max level"] or FD.L["Leveling"]
    tooltip:AddDoubleLine(FD.Locale:Format("Duel Rating (%s, Lv %d)", mode, record.level), tostring(rating), 1, 0.82, 0, 1, 1, 1)
end

function Tooltip:Initialize()
    if self.initialized then return true end
    local ok, initialized = self:Run(function()
        if type(TooltipDataProcessor) == "table"
            and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
            and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit ~= nil then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
                self:Run(function() self:AddRating(tooltip, data) end)
            end)
            return true
        end
        -- The matching Forever build uses the processor above. Older clients
        -- are supported only when they explicitly expose the legacy script.
        if not GameTooltip or type(GameTooltip.HasScript) ~= "function"
            or type(GameTooltip.HookScript) ~= "function" then return false end
        if type(GameTooltip.IsForbidden) == "function" then
            local forbidden = GameTooltip:IsForbidden()
            if not readable(forbidden) or forbidden then return false end
        end
        local supported = GameTooltip:HasScript("OnTooltipSetUnit")
        if not readable(supported) or not supported or not self:Track(GameTooltip) then return false end
        GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
            self:Run(function() self:AddRating(tooltip) end)
        end)
        return true
    end)
    self.initialized = ok and initialized or false
    return self.initialized
end
