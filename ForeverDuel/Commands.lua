local _, FD = ...

-- Registration helpers live in Constants.lua so every module can register
-- at file scope; this file holds the dispatcher and generic commands.

local function say(text) FD.Debug:Print(text) end

function FD:StatusLines()
    local providers = {}
    for _, provider in ipairs(self.statusProviders) do providers[#providers + 1] = provider end
    table.sort(providers, function(a, b) return a.order < b.order end)
    local all = {}
    for _, provider in ipairs(providers) do
        local ok, lines = pcall(provider.lines)
        if ok and type(lines) == "table" then
            for _, line in ipairs(lines) do all[#all + 1] = tostring(line) end
        elseif not ok then
            all[#all + 1] = "status section failed: " .. tostring(lines)
        end
    end
    return all
end

function FD:Command(text)
    text = (text or ""):match("^%s*(.-)%s*$")
    local lowered = text:lower()
    local name, rest = lowered:match("^(%S+)%s*(.-)$")
    name = name or ""
    -- Preserve the original case of arguments (character names, venue IDs).
    local rawRest = text:match("^%S+%s+(.*)$") or ""
    if name == "" then name = "ui" end
    local command = self.commands[name]
    if not command then
        local names = {}
        for key in pairs(self.commands) do names[#names + 1] = key end
        table.sort(names, function(a, b)
            local oa, ob = self.commands[a].order, self.commands[b].order
            if oa ~= ob then return oa < ob end
            return a < b
        end)
        say("/duelrating [" .. table.concat(names, " | ") .. "]")
        return
    end
    if not command.anyState and not (self.Database and self.Database.data) then
        say(FD.L["Saved data unavailable; rating is disabled. Type /duelrating repair to start a fresh rating while keeping a copy of the old data."])
        return
    end
    if self.Database and self.Database.data and self.Wow then
        pcall(self.Database.SetBracket, self.Database, self.Wow:Identity("player", true))
    end
    command.run(rest or "", rawRest)
end

FD:RegisterCommand("help", function()
    local names = {}
    for key, command in pairs(FD.commands) do names[#names + 1] = { key = key, command = command } end
    table.sort(names, function(a, b)
        if a.command.order ~= b.command.order then return a.command.order < b.command.order end
        return a.key < b.key
    end)
    for _, entry in ipairs(names) do
        say("/duelrating " .. entry.key .. (entry.command.help and (" - " .. FD.L[entry.command.help]) or ""))
    end
end, "List all commands.", 99, true)

FD:RegisterCommand("debug", function()
    local settings = FD.Database.data.settings
    settings.debug = not settings.debug
    say(settings.debug and FD.L["Debug chat output enabled."] or FD.L["Debug chat output disabled."])
end, "Toggle debug chat output.", 90)

FD:RegisterCommand("status", function()
    for _, line in ipairs(FD:StatusLines()) do say(line) end
end, "Show the current duel, queue and transport state.", 80, true)

local function printEntry(entry)
    local repeated = entry.repeats and string.format(" | repeated %d, last %s", entry.repeats, tostring(entry.lastAt)) or ""
    local clock = entry.t and string.format(" (%.3f)", entry.t) or ""
    say((entry.version or "?") .. " | " .. tostring(entry.at or 0) .. clock .. " | " .. entry.event .. " | " .. entry.detail .. repeated)
end

FD:RegisterCommand("diagnose", function(rest)
    local which = (rest == "transport" or rest == "lifecycle") and rest or nil
    local trace = FD.Debug:RequestTrace(which and 30 or 20, which)
    say(string.format(FD.L["Recent diagnostics (%s): %d entries. Recorded even with debug disabled."],
        which or "lifecycle + transport", #trace))
    for _, entry in ipairs(trace) do printEntry(entry) end
    for _, line in ipairs(FD.Debug:TrafficLines()) do say(FD.L["Traffic: "] .. line) end
    local errors = FD.Debug:Errors(3)
    if #errors > 0 then say(string.format(FD.L["%d recent addon errors; type /duelrating errors."], #errors)) end
end, "Print saved diagnostics (optional: lifecycle or transport).", 81, true)

FD:RegisterCommand("errors", function(rest)
    if rest == "clear" then FD.Debug:ClearErrors(); say(FD.L["Saved addon errors cleared."]); return end
    local errors = FD.Debug:Errors()
    if #errors == 0 then say(FD.L["No addon errors recorded."]); return end
    for index, entry in ipairs(errors) do
        say(string.format("#%d %s | %s | %s | %s%s", index, entry.version or "?", tostring(entry.at or 0),
            entry.context or "?", entry.message or "?", entry.repeats and (" | x" .. (entry.repeats + 1)) or ""))
        if entry.stack then
            for line in entry.stack:gmatch("[^\n]+") do say("    " .. line) end
        end
    end
end, "Show saved addon errors (errors clear removes them).", 82, true)
