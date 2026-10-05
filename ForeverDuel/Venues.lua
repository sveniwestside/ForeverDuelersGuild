local _, FD = ...

local Venues = { Catalog = {} }
FD.Venues = Venues

-- No outdoor place has been live-tested for this release. Candidates must not
-- be promoted to verified by guessing coordinates or trusting a peer packet.
-- The adapter supplies an explicitly approved local catalog through env.catalog.

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function finite(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
end

local function integer(value, minimum, maximum)
    return finite(value, minimum, maximum) and value == math.floor(value)
end

local function validRecord(value)
    return type(value) == "table" and type(value.id) == "string" and #value.id > 0 and #value.id <= 48
        and value.id:match("^[a-z0-9_.%-]+$") ~= nil and type(value.name) == "string" and #value.name > 0
        and integer(value.mapID, 1, 100000) and integer(value.continentID, 0, 100000)
        and type(value.factions) == "table" and integer(value.minPlayerLevel, 1, 255)
        and integer(value.zoneMinLevel, 1, 255) and integer(value.zoneMaxLevel, value.zoneMinLevel, 255)
end

local function records(self, env)
    return type(env) == "table" and type(env.catalog) == "table" and env.catalog or self.Catalog
end

local function resolveRecord(value, env)
    if not validRecord(value) then return nil, "INVALID_VENUE" end
    local result = copy(value)
    if result.x == nil and result.y == nil then
        if not finite(result.mapX, 0, 1) or not finite(result.mapY, 0, 1)
            or type(env) ~= "table" or type(env.world) ~= "function" then return nil, "NO_POSITION" end
        local ok, continentID, x, y = pcall(env.world, result.mapID, result.mapX, result.mapY)
        if not ok or continentID ~= result.continentID then return nil, "NO_POSITION" end
        result.x, result.y = x, y
    end
    if not finite(result.x, -1000000, 1000000) or not finite(result.y, -1000000, 1000000) then
        return nil, "NO_POSITION"
    end
    return result
end

function Venues:Resolve(id, env)
    if type(id) ~= "string" then return nil, "INVALID_VENUE" end
    local found
    for _, venue in pairs(records(self, env)) do
        if type(venue) == "table" and venue.id == id then
            -- Ambiguous local IDs cannot be used in a negotiated travel plan.
            if found then return nil, "INVALID_VENUE" end
            found = venue
        end
    end
    if not found then return nil, "NO_VENUE" end
    return resolveRecord(found, env)
end

local function scopeAllows(venue, player)
    if player.scope == "ZONE" then return venue.mapID == player.mapID end
    if player.scope == "CONTINENT" then return venue.continentID == player.continentID end
    return player.scope == "RULESET"
end

function Venues:Eligible(venue, a, b)
    if not validRecord(venue) or venue.verified ~= true or venue.duelAllowed ~= true
        or type(a) ~= "table" or type(b) ~= "table" or a.faction ~= b.faction
        or (a.faction ~= "Alliance" and a.faction ~= "Horde")
        or venue.factions[a.faction] ~= true or venue.factions[b.faction] ~= true
        or not integer(a.level, venue.minPlayerLevel, 255) or not integer(b.level, venue.minPlayerLevel, 255) then
        return false
    end
    return scopeAllows(venue, a) and scopeAllows(venue, b)
end

local function position(player)
    return type(player) == "table" and integer(player.mapID, 1, 100000)
        and integer(player.continentID, 0, 100000) and finite(player.x, -1000000, 1000000)
        and finite(player.y, -1000000, 1000000)
end

local function distanceSquared(a, b)
    return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2
end

function Venues:Select(a, b, env)
    if not position(a) or not position(b) then return nil, nil, "NO_POSITION" end
    local crossContinent = a.continentID ~= b.continentID
    if crossContinent and (a.scope ~= "RULESET" or b.scope ~= "RULESET") then
        return nil, nil, "CROSS_CONTINENT_SCOPE"
    end
    local midpoint = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2 }
    local best, bestDistance, bestDuration
    local duplicates, counts = {}, {}
    for _, venue in pairs(records(self, env)) do
        if type(venue) == "table" and type(venue.id) == "string" then
            counts[venue.id] = (counts[venue.id] or 0) + 1
            if counts[venue.id] > 1 then duplicates[venue.id] = true end
        end
    end
    for _, record in pairs(records(self, env)) do
        if type(record) == "table" and not duplicates[record.id] and self:Eligible(record, a, b)
            and (crossContinent and record.hubFaction == a.faction
                or not crossContinent and record.continentID == a.continentID) then
            local venue = resolveRecord(record, env)
            if venue then
                local duration = 900
                local score = 0
                if not crossContinent then
                    local speedA, speedB = a.level < 40 and 7 or 11.2, b.level < 40 and 7 or 11.2
                    local travel = math.max(math.sqrt(distanceSquared(venue, a)) / speedA,
                        math.sqrt(distanceSquared(venue, b)) / speedB)
                    duration = math.max(300, math.ceil(travel * 1.5 + 120))
                    score = distanceSquared(venue, midpoint)
                end
                if duration <= 900 and (not best or score < bestDistance
                    or score == bestDistance and venue.id < best.id) then
                    best, bestDistance, bestDuration = venue, score, duration
                end
            end
        end
    end
    if not best then return nil, nil, "NO_VENUE" end
    return best, bestDuration
end
