local _, FD = ...

-- Native-value checks shared by the WoW-bound modules. A secret value
-- (issecretvalue) is never compared, formatted or stored: each helper checks
-- readability first and treats an unreadable value like a missing one.
local Native = {}
FD.Native = Native

-- FD.Wow:Readable is the addon's secret check (specs replace it); without it
-- issecretvalue is asked directly. Every caller runs from an event, timer,
-- click or slash command, which start only after all TOC files (Wow.lua
-- included) have loaded, so the old copies' differing answers without FD.Wow
-- (true in UI/QueueUI/Zone/Minimap/QueueTransport, false in Tooltip) were
-- never observable.
function Native.Readable(...)
    local wow = FD.Wow
    if wow and type(wow.Readable) == "function" then return wow:Readable(...) end
    if type(issecretvalue) ~= "function" then return true end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return false end
    end
    return true
end

-- A readable number other than NaN and +/-infinity, within optional bounds.
function Native.Finite(value, low, high)
    return Native.Readable(value) and type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and (not low or value >= low) and (not high or value <= high)
end

function Native.Integer(value, low, high)
    return Native.Finite(value, low, high) and value % 1 == 0
end

-- A readable, non-empty string without control characters or UI escapes,
-- such as a GUID or a whisper address.
function Native.Text(value, maximum)
    return Native.Readable(value) and type(value) == "string" and #value > 0
        and #value <= (maximum or 128) and not value:find("[%c|]")
end

-- Display form of any value: UI escapes are neutralised and a secret value
-- is never stringified.
function Native.Plain(value)
    if not Native.Readable(value) then return FD.L["Unavailable"] end
    return (tostring(value or ""):gsub("|", "||"))
end

local function results(ok, ...)
    if ok and Native.Readable(...) then return ... end
    return nil
end

-- pcall for a native API: nil when the function is missing, fails or
-- returns any secret value, otherwise its results.
function Native.Call(callback, ...)
    if type(callback) ~= "function" then return nil end
    return results(pcall(callback, ...))
end

-- GetTime in seconds; 0 when unavailable, so timing arithmetic never fails.
function Native.Now()
    local value = Native.Call(GetTime)
    return Native.Finite(value, 0) and value or 0
end

-- GetServerTime in whole seconds; nil when unavailable.
function Native.Epoch()
    local value = Native.Call(GetServerTime)
    if Native.Integer(value, 0) then return value end
end
