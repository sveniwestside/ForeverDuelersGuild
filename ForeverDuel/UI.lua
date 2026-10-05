local _, FD = ...
FD.UI = {}
local UI = FD.UI

-- The addon never hides or replaces Blizzard's DUEL_REQUESTED popup before
-- its own AcceptDuel. The panel appears only once the peer is proven: for
-- INCOMING a compact companion under the native popup, for OUTGOING a
-- standalone proposal panel. Closing it (button or Esc) keeps the duel unrated.
local VISIBLE = { READY = true, LOCAL_ACCEPTED = true, REMOTE_ACCEPTED = true, RATED_CONFIRMED = true }

local function readable(...)
    if FD.Wow and FD.Wow.Readable then return FD.Wow:Readable(...) end
    return true
end

local function inCombat()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, value = pcall(InCombatLockdown)
    return not ok or not readable(value) or value == true
end

function UI:Create()
    if self.frame then return end
    local frame = CreateFrame("Frame", "ForeverDuelDialog", UIParent, "BackdropTemplate")
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:Hide()
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -16)
    title:SetText("ForeverDuelersGuild")
    local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetPoint("TOPLEFT", 20, -36)
    body:SetPoint("TOPRIGHT", -20, -36)
    body:SetJustifyH("CENTER")
    self.body = body
    local function button(handler)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(200, 24)
        b:SetScript("OnClick", function() FD:Safe(handler) end)
        return b
    end
    self.rated = button(function() FD.duel:AcceptRated() end)
    self.normal = button(function() self:Closed() end)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() FD:Safe(function() self:Closed() end) end)
    self.close = close
    self.frame = frame
    -- Esc must close the panel before the World handler that would
    -- ClearTarget (pinned Blizzard_GameMenuEsc and Game.lua). An AddOn-priority
    -- handler runs only for a real Esc; UISpecialFrames, the fallback where
    -- that API is missing, is also closed by loss of control or panel changes.
    local function escape()
        if not frame:IsShown() then return false end
        FD:Safe(function() self:Closed() end)
        return true
    end
    local priority = type(GameMenuEscPriority) == "table" and GameMenuEscPriority.AddOn
    if type(RegisterGameMenuEscHandler) == "function" and priority
        and pcall(RegisterGameMenuEscHandler, priority, escape) then return end
    -- A frame hidden by its hidden parent stays IsShown(); only an explicit
    -- close reaches Closed().
    frame:SetScript("OnHide", function()
        if not self.hiding and not frame:IsShown() then FD:Safe(function() self:Closed() end) end
    end)
    if type(UISpecialFrames) == "table" then UISpecialFrames[#UISpecialFrames + 1] = "ForeverDuelDialog" end
end

-- Closing the panel means "keep this duel unrated" and notifies the peer.
function UI:Closed()
    local m = self.shown
    self:Hide()
    if m and FD.duel and FD.duel.active == m then FD.duel:KeepUnrated() end
end

function UI:Hide()
    self.shown, self.ticking = nil, nil
    if self.frame and self.frame:IsShown() then
        self.hiding = true
        self.frame:Hide()
        self.hiding = nil
    end
end

local function nativePopup()
    if type(StaticPopup_Visible) ~= "function" then return nil end
    -- Pinned StaticPopup.lua: returns the dialog name and the dialog frame.
    local ok, name, dialog = pcall(StaticPopup_Visible, "DUEL_REQUESTED")
    if not ok or not readable(name, dialog) then return nil end
    if type(dialog) == "table" then return dialog end
    if type(name) == "string" and type(_G[name]) == "table" then return _G[name] end
end

function UI:Visible(m)
    return m ~= nil and FD.duel ~= nil and FD.duel.active == m and m.peerNonce ~= nil and VISIBLE[m.state] == true
        and not m.nativeAccepted and not m.countdownAt and GetTime() < m.deadline
end

function UI:Text(m)
    local L, name = FD.L, m.opponent.fullName
    local lines = {}
    local peer = m.peer
    if peer then
        lines[#lines + 1] = FD.Locale:Format("%s - level %d %s | rating %d (%d-%d)", name, m.opponent.level or 0,
            m.opponent.className or m.opponent.classFile, peer.rating, peer.wins, peer.losses)
        local _, gain = FD.Rating:Calculate(m.ratingBefore, peer.rating, true, m.player.level, m.opponent.level)
        local _, loss = FD.Rating:Calculate(m.ratingBefore, peer.rating, false, m.player.level, m.opponent.level)
        if gain and loss then
            lines[#lines + 1] = FD.Locale:Format("Rated: win %+d / loss %+d (your rating %d)", gain, loss, m.ratingBefore)
        end
    end
    local state = m.state
    if state == "LOCAL_ACCEPTED" then lines[#lines + 1] = FD.Locale:Format("Waiting for %s to agree to a rated duel.", name)
    elseif state == "REMOTE_ACCEPTED" then lines[#lines + 1] = FD.Locale:Format("%s proposes a RATED duel.", name)
    elseif state == "RATED_CONFIRMED" then lines[#lines + 1] = FD.Locale:Format("Rated duel agreed. Waiting for %s to accept the duel.", name)
    elseif m.role == "OUTGOING" then lines[#lines + 1] = L["Your opponent also uses ForeverDuelersGuild."] end
    if m.role == "INCOMING" then lines[#lines + 1] = L["Blizzard's Accept starts an UNRATED duel."] end
    if (state == "READY" or state == "REMOTE_ACCEPTED") and inCombat() then
        lines[#lines + 1] = L["Leave combat to choose a rated duel."]
    end
    lines[#lines + 1] = FD.Locale:Format("Request expires in %d s", math.max(0, math.ceil(m.deadline - GetTime())))
    return table.concat(lines, "\n")
end

function UI:Layout(m)
    local frame = self.frame
    frame:ClearAllPoints()
    self.rated:ClearAllPoints()
    self.normal:ClearAllPoints()
    if m.role == "INCOMING" then
        frame:SetSize(340, 150)
        local popup = nativePopup()
        if popup then frame:SetPoint("TOP", popup, "BOTTOM", 0, -4)
        else frame:SetPoint("TOP", UIParent, "TOP", 0, -260) end
        self.rated:SetPoint("BOTTOM", 0, 16)
        self.normal:Hide()
    else
        frame:SetSize(360, 180)
        frame:SetPoint("TOP", UIParent, "TOP", 0, -170)
        self.rated:SetPoint("BOTTOM", 0, 46)
        self.normal:SetPoint("BOTTOM", 0, 18)
        self.normal:Show()
    end
end

function UI:Render(m)
    if not self:Visible(m) then
        -- Never let another match's update close the panel of the active one.
        if not (self.shown and self.shown ~= m and self:Visible(self.shown)) then self:Hide() end
        return
    end
    self:Create()
    if self.shown ~= m then self:Layout(m) end
    self.shown = m
    self.body:SetText(self:Text(m))
    local open = m.state == "READY" or m.state == "REMOTE_ACCEPTED"
    if m.role == "INCOMING" then self.rated:SetText(FD.L["Accept as RATED duel"])
    else self.rated:SetText(m.state == "REMOTE_ACCEPTED" and FD.L["Accept RATED duel"] or FD.L["Propose RATED duel"]) end
    self.rated:SetEnabled(open and not inCombat())
    self.normal:SetText(FD.L["Keep unrated"])
    self.frame:Show()
    self:Tick(m)
end

-- Refresh the expiry countdown once per second while the panel is shown.
function UI:Tick(m)
    if self.ticking == m then return end
    self.ticking = m
    local function step()
        if self.ticking ~= m or self.shown ~= m then return end
        self.ticking = nil
        self:Render(m)
    end
    C_Timer.After(1, function() FD:Safe(step) end)
end

function UI:History(count)
    local matches = FD.History:Recent(count)
    if #matches == 0 then FD.Debug:Print(FD.L["No rated matches yet."]); return end
    for _, match in ipairs(matches) do
        FD.Debug:Print(FD.Locale:Format("%s %+d vs %s (%s) | %s", FD.L[match.result], match.ratingDelta,
            match.opponent.fullName or match.opponent.name, match.opponent.className or match.opponent.classFile,
            match.matchId))
    end
end

function UI:Summary()
    for _, bracket in ipairs({ "LEVELING", "MAX_LEVEL", "LEGACY" }) do
        local player = FD.Database:GetStats(bracket)
        if player then
            local name = bracket == "MAX_LEVEL" and FD.L["Max level"] or bracket == "LEGACY" and FD.L["Legacy"] or FD.L["Leveling"]
            FD.Debug:Print(FD.Locale:Format("%s rating: %d | Wins: %d | Losses: %d | Rated matches: %d",
                name, player.rating, player.wins, player.losses, player.wins + player.losses))
        end
    end
    self:History(FD.C.RECENT_COUNT)
end
