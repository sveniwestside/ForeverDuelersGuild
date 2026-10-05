local _, FD = ...

-- User-facing text is written in English and used as the lookup key.
-- A missing translation always falls back to that English text, so a new
-- string can never produce an empty label or a nil concatenation error.
local translations = {}
FD.Locale = { translations = translations }

local function detect()
    if type(GetLocale) ~= "function" then return "enUS" end
    local ok, value = pcall(GetLocale)
    if ok and type(value) == "string" and value:match("^%a%a%u%u$") then return value end
    return "enUS"
end

FD.Locale.current = detect()

function FD.Locale:Register(locale, entries)
    if type(locale) ~= "string" or type(entries) ~= "table" then return end
    local target = translations[locale] or {}
    translations[locale] = target
    for key, value in pairs(entries) do
        if type(key) == "string" and type(value) == "string" and value ~= "" then target[key] = value end
    end
end

function FD.Locale:Get(key)
    if type(key) ~= "string" then return tostring(key) end
    local active = translations[self.current]
    return active and active[key] or key
end

-- Format through the translated pattern. A translation whose placeholders do
-- not fit the arguments falls back to the English pattern instead of failing.
function FD.Locale:Format(key, ...)
    local pattern = self:Get(key)
    local ok, text = pcall(string.format, pattern, ...)
    if ok then return text end
    ok, text = pcall(string.format, key, ...)
    return ok and text or key
end

FD.L = setmetatable({}, { __index = function(_, key) return FD.Locale:Get(key) end })
