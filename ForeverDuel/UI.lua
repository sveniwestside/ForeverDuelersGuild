local _, FD = ...
FD.UI = {}
local UI = FD.UI

function UI:Create()
    if self.frame then return end
    local frame = CreateFrame("Frame", "ForeverDuelDialog", UIParent, "BackdropTemplate")
    frame:SetSize(430, 340)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -170)
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:Hide()
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -22)
    title:SetText("ForeverDuelersGuild")
    local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", 22, -55)
    body:SetPoint("TOPRIGHT", -22, -55)
    body:SetJustifyH("CENTER")
    self.body = body
    local function button(y, handler)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(300, 27)
        b:SetPoint("BOTTOM", 0, y)
        b:SetScript("OnClick", function() FD:Safe(handler) end)
        return b
    end
    self.rated = button(87, function() FD.duel:AcceptRated() end)
    self.normal = button(55, function() FD.duel:ContinueUnrated() end)
    self.decline = button(23, function() FD.duel:Decline() end)
    self.frame = frame
end

function UI:Hide()
    if self.frame then self.frame:Hide() end
end

function UI:Render(m)
    if not m then return self:Hide() end
    if m.state == "COUNTDOWN" or m.state == "IN_PROGRESS" or m.state == "FINISHING"
        or m.state == "FINISHED" or m.state == "UNRATED_ACTIVE" or m.nativeAccepted then return self:Hide() end
    if m.role == "OUTGOING" and m.state == "UNRATED" then return self:Hide() end
    self:Create()
    local details = m.opponent.fullName .. " - " .. (m.opponent.className or m.opponent.classFile)
    if m.player.level and m.opponent.level then
        details = details .. string.format("\nLevel %d vs %d  |  %s", m.player.level, m.opponent.level,
            m.bracket == "MAX_LEVEL" and "Max level" or m.bracket == "LEVELING" and "Leveling" or "Unrated")
    end
    if m.peer then
        details = details .. string.format("\nRating: %d  |  Record: %d-%d", m.peer.rating, m.peer.wins, m.peer.losses)
        details = details .. string.format("\nYour rating: %d", m.ratingBefore)
        local _, gain = FD.Rating:Calculate(m.ratingBefore, m.peer.rating, true, m.player.level, m.opponent.level)
        local _, loss = FD.Rating:Calculate(m.ratingBefore, m.peer.rating, false, m.player.level, m.opponent.level)
        if gain and loss then details = details .. string.format("  |  Win %+d / Loss %+d", gain, loss) end
    end
    local state = m.state
    local status = ""
    if state == "CHECKING_ADDON" or state == "DISCOVERY_WAIT" then
        status = "Waiting for opponent addon response. Rated becomes available after both addons confirm this request."
        if m.role == "INCOMING" and state == "DISCOVERY_WAIT" then status = status .. " You can accept a normal duel now." end
    elseif state == "UNRATED" then status = (m.reason or "Rated unavailable") .. "."
    elseif state == "REMOTE_ACCEPTED" then status = "Your opponent wants this duel to count as RATED."
    elseif state == "READY" then status = "Both players must explicitly agree to a rated duel."
    elseif state == "RATED_CONFIRMED" then status = "Rated confirmed. Preparing the duel..."
    else status = "Waiting for rated confirmation..." end
    self.body:SetText(details .. "\n\n" .. status)
    self.rated:SetText(m.role == "OUTGOING" and (state == "REMOTE_ACCEPTED" and "Accept Rated" or "Propose Rated Duel") or "Accept Rated Duel")
    self.rated:SetEnabled(state == "READY" or state == "REMOTE_ACCEPTED")
    self.normal:SetText(m.role == "OUTGOING" and "Keep Unrated"
        or ((state == "UNRATED" or state == "DISCOVERY_WAIT") and "Accept Normal Duel" or "Continue Unrated"))
    self.decline:SetText(m.role == "OUTGOING" and "Cancel Duel" or "Decline")
    self.frame:Show()
    if m.role == "INCOMING" then
        -- A same-event hide races Blizzard's handler. Replace on the next frame,
        -- only after our usable frame is visible and this request is still current.
        C_Timer.After(0, function()
            FD:Safe(function()
                if FD.duel and FD.duel.active == m and self.frame:IsShown()
                    and not m.nativeAccepted and not InCombatLockdown() then
                    StaticPopup_Hide("DUEL_REQUESTED")
                    FD.Debug:Log("native popup hidden for", m.nonce)
                end
            end)
        end)
    end
end

function UI:Restore(m)
    if InCombatLockdown() then return false end
    self:Hide()
    -- No Blizzard-owned definitions are changed. Never restore an expired or
    -- already accepted request, or resurrect a popup during a different duel.
    if m and m.role == "INCOMING" and not m.nativeAccepted and not m.countdownAt
        and GetTime() - m.createdAt <= FD.C.PENDING_TIMEOUT + 5 and not InCombatLockdown() then
        StaticPopup_Show("DUEL_REQUESTED", m.opponent.fullName)
        FD.Debug:Log("native popup restored")
    end
    return true
end

function UI:History(count)
    local matches = FD.History:Recent(count)
    if #matches == 0 then FD.Debug:Print("No rated matches yet."); return end
    for _, match in ipairs(matches) do
        FD.Debug:Print(string.format("%s %+.0f vs %s (%s) | %s", match.result, match.ratingDelta,
            match.opponent.fullName or match.opponent.name, match.opponent.className or match.opponent.classFile, match.matchId))
    end
end

function UI:Summary()
    for _, bracket in ipairs({ "LEVELING", "MAX_LEVEL", "LEGACY" }) do
        local player = FD.Database:GetStats(bracket)
        if player then
            local name = bracket == "MAX_LEVEL" and "Max level" or bracket == "LEGACY" and "Legacy" or "Leveling"
            FD.Debug:Print(string.format("%s rating: %d | Wins: %d | Losses: %d | Rated matches: %d",
                name, player.rating, player.wins, player.losses, player.wins + player.losses))
        end
    end
    self:History(FD.C.RECENT_COUNT)
end
