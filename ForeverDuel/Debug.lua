local _, FD = ...
FD.Debug = {}

function FD.Debug:Print(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd8bb68[ForeverDuelersGuild]|r " .. tostring(text))
    end
end

function FD.Debug:Log(...)
    local db = FD.Database and FD.Database.data
    if not (db and db.settings.debug) then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    self:Print(table.concat(parts, " "))
end
