return function(_, equal)
    local function client(options)
        options = options or {}
        local env = setmetatable({}, { __index = _G })
        env._G = env
        local state = { now = 100, mapID = 37, units = {}, logs = {}, native = {}, timers = {}, refreshes = 0 }
        state.secret = setmetatable({}, { __tostring = function() error("secret formatted") end,
            __index = function() error("secret indexed") end, __le = function() error("secret compared") end })
        env.issecretvalue = function(value) return rawequal(value, state.secret) end
        env.GetTime = function() return state.now end
        env.InCombatLockdown = function() return state.combat or false end
        env.C_Map = { GetBestMapForUnit = function(unit)
            equal(unit, "player", "map query refers to own player")
            if state.failMap then error("map API failed") end
            return state.mapID
        end }
        env.UnitGUID = function(unit)
            if state.failIdentity then error("unit API failed") end
            return state.units[unit] and state.units[unit].guid
        end
        env.UnitFullName = function(unit)
            local identity = state.units[unit]
            if identity then return identity.name, identity.realm end
        end
        env.UnitClass = function(unit)
            local identity = state.units[unit]
            if identity then return identity.classFile, identity.classFile end
        end
        env.UnitLevel = function(unit) return state.units[unit] and state.units[unit].level end
        env.GetMaxPlayerLevel = function() return state.maxLevel or 60 end
        env.UnitIsPlayer = function(unit)
            local identity = state.units[unit]
            if identity and identity.isPlayer ~= nil then return identity.isPlayer end
            return identity ~= nil
        end
        env.GetNormalizedRealmName = function() return "Forever" end
        env.RegionalUniqueNamesEnabled = function() return options.surname or false end
        env.UnitNameUnmodified = function(unit)
            local identity = state.units[unit]
            if identity then return identity.name, identity.surname end
        end
        env.NameUtil = { GetUnmodifiedUnitFullName = function(unit)
            local identity = state.units[unit]
            return identity.name .. (identity.surname and " " .. identity.surname or "")
        end }
        env.C_Timer = { After = function(delay, callback)
            state.timers[#state.timers + 1] = { delay = delay, callback = callback }
        end }
        local FD = { Debug = {}, Zone = {}, duel = {} }
        function FD.Debug:Log(...) state.logs[#state.logs + 1] = { ... } end
        function FD.Zone:RefreshIfShown() state.refreshes = state.refreshes + 1 end
        function FD:Safe() error("Discovery must not enter duel-aborting recovery") end
        function FD.duel:Begin() error("Presence must not begin rated negotiation") end
        function FD.duel:Abort() error("Presence must not abort rated negotiation") end
        env.StartDuel = function(unit, exact)
            if state.failNative then error("native duel unavailable") end
            state.native[#state.native + 1] = { unit = unit, exact = exact }
            if state.nativeHook then FD.Wow:CaptureOutgoing(unit) end
        end
        for _, module in ipairs({ "Constants", "Protocol", "Rating", "Database", "Wow", "Presence" }) do
            local chunk = assert(loadfile("ForeverDuel/" .. module .. ".lua"))
            setfenv(chunk, env)
            chunk("ForeverDuel", FD)
        end
        state.units.player = { guid = "Player-1-AAAA", name = "Alpha", surname = "Own",
            realm = "Forever", classFile = "MAGE", level = 30 }
        FD.Database:Initialize(nil, FD.Wow:Identity("player"))
        state.FD, state.env = FD, env
        function state:peer(unit)
            local identity = { guid = "Player-1-BBBB", name = "Beta", surname = "Peer",
                realm = "Forever", classFile = "ROGUE", level = 32 }
            if unit then self.units[unit] = identity end
            local profile = { guid = identity.guid, fullName = options.surname and "Beta Peer" or "Beta-Forever",
                classFile = identity.classFile, rating = 1642, level = identity.level, maxLevel = 60,
                bracket = "LEVELING", mapID = self.mapID, lastSeen = self.now }
            self.FD.Presence.players[profile.guid] = profile
            return profile, identity
        end
        return state
    end

    local c = client()
    local p = c.FD.Presence
    equal(#p:GetPlayers(), 0, "new cache is empty")
    local own = p:GetOwnPlayer()
    equal(own.guid, c.units.player.guid, "own profile uses real native identity")
    equal(own.fullName, "Alpha-Forever", "own profile uses canonical full name")
    equal(own.rating, 1500, "own tooltip profile uses persisted rating")
    equal(own.mapID, 37, "own profile has current map")
    equal(own.level, 30, "own profile includes native level")
    equal(own.maxLevel, 60, "own profile includes runtime level cap")
    equal(own.bracket, "LEVELING", "own rating mode derives from native level")
    c.FD.Database.data.player.ratings.MAX_LEVEL.rating = 1777
    c.units.player.level = 60
    equal(p:GetOwnPlayer().rating, 1777, "reaching cap announces max-level rating independently")
    equal(p:GetOwnPlayer().bracket, "MAX_LEVEL", "reaching cap changes announced mode")
    c.units.player.level = nil
    equal(p:GetOwnPlayer(), nil, "missing native level cannot publish a profile")
    c.units.player.level = c.secret
    equal(p:GetOwnPlayer(), nil, "restricted native level cannot publish a profile")
    c.units.player.level = 30
    own.rating = 9999
    equal(p:GetOwnPlayer().rating, 1500, "own profile is independent of database")
    local peer = c:peer()
    local copy = p:GetPlayer(peer.guid)
    equal(copy.fullName, "Beta-Forever", "fresh cached identity available")
    equal(copy.rating, 1642, "fresh cached rating available")
    copy.rating, copy.fullName = 1, "Changed"
    equal(p:GetPlayer(peer.guid).rating, 1642, "single lookup returns isolated copy")
    local list = p:GetPlayers()
    equal(#list, 1, "same-map cached player is listed")
    list[1].rating, list[1].mapID = 0, 99
    list[2] = { guid = "injected" }
    equal(#p:GetPlayers(), 1, "returned list is independent of cache")
    equal(p:GetPlayer(peer.guid).mapID, 37, "returned player cannot rewrite map")
    c.mapID = 38
    equal(#p:GetPlayers(), 0, "moving maps removes old-zone list entries")
    equal(p:GetPlayer(peer.guid).rating, 1642, "tooltip lookup retains fresh other-map profile")
    c.mapID = 37
    c.now = 219.99
    equal(#p:GetPlayers(), 1, "profile remains fresh immediately before 120 seconds")
    c.now = 220
    equal(p:GetPlayer(peer.guid), nil, "profile expires at 120 seconds")
    equal(#p:GetPlayers(), 0, "expired profile leaves zone list")
    c.now = 100
    p.suspended = true
    equal(p:GetPlayer(peer.guid), nil, "world transition suspends cached profile use")
    equal(#p:GetPlayers(), 0, "world transition hides zone list")
    equal(p:GetStatus(), "Waiting for the world to load.", "transition has useful status")
    p.suspended = false
    c.mapID = nil
    equal(p:MapID(), nil, "missing map returns no fabricated zone")
    equal(#p:GetPlayers(), 0, "missing map prevents zone list")
    equal(p:GetStatus():find("waiting for map information", 1, true) ~= nil, true, "missing map explains wait")
    for _, invalid in ipairs({ c.secret, "37", 0, -1, 0.5, 10000001, math.huge, 0 / 0 }) do
        c.mapID = invalid
        equal(p:MapID(), nil, "invalid or restricted map rejected")
        equal(#p:GetPlayers(), 0, "invalid map cannot produce zone matches")
    end
    c.env.C_Map = nil
    equal(p:MapID(), nil, "missing map API is tolerated")
    c.env.C_Map = {}
    equal(p:MapID(), nil, "missing map function is tolerated")
    for _, invalid in ipairs({ c.secret, "not-a-player", "Player-1-XYZ", false, {} }) do
        equal(p:GetPlayer(invalid), nil, "invalid or secret GUID cannot query cache")
    end
    equal(p:GetPlayer(nil), nil, "nil GUID cannot query cache")
    c.FD.Database.data.player.ratings.LEVELING.rating = c.secret
    equal(p:GetOwnPlayer(), nil, "restricted saved rating is not published")
    c.FD.Database.data.player.ratings.LEVELING.rating = 1500
    c.units.player.guid = c.secret
    equal(p:GetOwnPlayer(), nil, "restricted own identity is not published")
    p:Refresh()
    equal(c.refreshes, 1, "presence refresh notifies zone view")

    local function rejected(setup, label)
        local test = client()
        local profile = test:peer("target")
        setup(test, profile)
        local accepted, reason = test.FD.Presence:Challenge(profile.guid)
        equal(accepted, false, label .. " rejected")
        equal(type(reason), "string", label .. " explains failure")
        equal(#test.native, 0, label .. " never starts native duel")
        return test
    end
    rejected(function(test) test.combat = true end, "combat challenge")
    local pending = { state = "READY", matchId = "unchanged" }
    c = rejected(function(test) test.FD.duel.active = pending end, "pending rated duel")
    equal(c.FD.duel.active, pending, "rejected click preserves existing rated flow")
    rejected(function(test) test.FD.Wow.outgoing = {} end, "pending native request")
    rejected(function(test) test.FD.duel = nil end, "uninitialized duel")
    rejected(function(test) test.env.StartDuel = nil end, "missing native duel API")
    rejected(function(test) test.mapID = 38 end, "different current map")
    rejected(function(test) test.mapID = nil end, "unavailable current map")
    rejected(function(test) test.now = 220 end, "expired player")
    rejected(function(test) test.FD.Presence.suspended = true end, "world transition")
    rejected(function(test) test.units.target = nil end, "unobserved player")
    rejected(function(test) test.units.target.guid = "Player-1-CCCC" end, "same name different GUID")
    rejected(function(test) test.units.target.name = "Gamma" end, "same GUID different name")
    rejected(function(test) test.units.target.realm = "OtherRealm" end, "same short name different realm")
    rejected(function(test) test.units.target.isPlayer = false end, "non-player unit")
    rejected(function(test) test.units.target.isPlayer = test.secret end, "restricted player flag")
    rejected(function(test) test.units.target.guid = test.secret end, "restricted local GUID")
    rejected(function(test) test.units.target.name = test.secret end, "restricted local name")
    c = client()
    equal(c.FD.Presence:Challenge(c.secret), false, "secret click GUID rejected")
    equal(#c.native, 0, "secret click GUID cannot start native duel")

    for _, unit in ipairs({ "target", "mouseover", "focus", "party1", "party4", "raid1", "raid40", "nameplate1", "nameplate40" }) do
        c = client()
        peer = c:peer(unit)
        equal(c.FD.Presence:Challenge(peer.guid), true, unit .. " exact identity can request native duel")
        equal(#c.native, 1, unit .. " produces one native request")
        equal(c.native[1].unit, unit, unit .. " native request uses observable token")
        equal(c.native[1].exact, true, unit .. " native request uses exact matching")
        equal(c.FD.duel.active, nil, unit .. " request itself never begins rated negotiation")
        equal(c.FD.Database.data.player.ratings.LEVELING.rating, 1500, unit .. " request never changes rating")
        equal(#c.FD.Database.data.matches, 0, unit .. " request never invents match history")
    end
    c = client({ surname = true })
    peer = c:peer("focus")
    equal(c.FD.Presence:Challenge(peer.guid), true, "Forever exact surname identity can duel")
    c.units.focus.surname = "Other"
    equal(c.FD.Presence:Challenge(peer.guid), false, "same first name cannot replace exact surname identity")
    equal(#c.native, 1, "altered surname creates no second native request")
    c = client()
    peer = c:peer("target")
    peer.level, c.units.target.level = 50, 50
    equal(c.FD.Presence:Challenge(peer.guid), true, "normal duel button remains available outside rated level range")
    c = client()
    peer = c:peer("target")
    c.nativeHook = true
    equal(c.FD.Presence:Challenge(peer.guid), true, "native request works with real capture post-hook")
    equal(c.FD.Wow.outgoing.opponent.guid, peer.guid, "capture hook binds clicked identity")
    equal(c.FD.duel.active, nil, "captured request still awaits native server acknowledgement")
    equal(c.FD.Presence:Challenge(peer.guid), false, "second click cannot overlap captured request")
    equal(#c.native, 1, "second click sends no native request")

    for _, failure in ipairs({ "failMap", "failIdentity", "failNative" }) do
        c = client()
        peer = c:peer("target")
        c[failure] = true
        local accepted, reason = c.FD.Presence:Challenge(peer.guid)
        equal(accepted, nil, failure .. " is caught locally")
        equal(reason, "Zone discovery temporarily unavailable.", failure .. " has a useful fallback")
        equal(#c.logs, 1, failure .. " is logged locally")
        equal(#c.native, 0, failure .. " produces no native request")
        equal(c.FD.Database.data.player.ratings.LEVELING.rating, 1500, failure .. " preserves rating")
        equal(#c.FD.Database.data.matches, 0, failure .. " preserves match history")
    end
    c.FD.Debug.Log = function() error("logger failed") end
    equal(pcall(function() c.FD.Presence:Challenge(peer.guid) end), true, "logger failure stays isolated")
end
