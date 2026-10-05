return function(_, equal)
    -- Quiet mode for whisper-latency A/B tests: Presence and Roster send
    -- nothing at all while it is on.
    local Harness = assert(loadfile("tests/presence_harness.lua"))()
    local BETA = { guid = "Player-1-0000BBBB", name = "Beta", surname = "Two", realm = "Forever",
        classFile = "ROGUE", level = 30, faction = "Alliance" }
    local function printed(c, pattern)
        for _, line in ipairs(c.prints) do if line:find(pattern, 1, true) then return true end end
        return false
    end

    -- Everything that would normally cause traffic happens while quiet.
    local c = Harness.client({ queue = { state = "SEARCHING", peers = {} } })
    c:command("quiet")
    equal(c.FD.Database.data.settings.quiet, true, "the command stores quiet mode in saved settings")
    equal(printed(c, "Quiet mode on"), true, "the command confirms quiet mode")
    c:start()
    c.FD.Zone.shown = true
    c:addUnit("target", BETA)
    c:addUnit("mouseover", Harness.identity(1))
    c.members = { { name = "Beta Two", guid = BETA.guid } }
    c:emit("PLAYER_TARGET_CHANGED")
    c:advance(30)
    c.joined = true -- e.g. joined by hand
    c:receive(c:profile(BETA, 37, "FDQ2"), "Beta Two")
    c:receive(c:profile(Harness.identity(2)), "Peer2 Crowd", "CHANNEL", 6)
    c.R:AddMember("Beta Two", BETA.guid)
    c:receive(c:profile(BETA, 37, "FDQ2"), "Beta Two")
    equal(c.P:FindByName("Beta Two") ~= nil, true, "received profiles are still cached passively")
    c.mapID = 38
    c:emit("ZONE_CHANGED_NEW_AREA")
    c.FD.Database.data.player.ratings.LEVELING.rating = 1530
    c.P:Changed()
    c.P:RefreshNow()
    c.P:Observe("mouseover")
    c:advance(600)
    equal(#c.sent, 0, "quiet mode sends no queries, replies or broadcasts")
    equal(#c.joins, 0, "quiet mode does not join the channel")
    equal(#c.selections, 0, "quiet mode requests no channel roster")
    local status = table.concat(c.FD:StatusLines(), "\n")
    equal(status:find("Quiet mode: on", 1, true) ~= nil, true, "status shows quiet mode")
    equal(c.P:GetStatus():find("Quiet mode", 1, true) ~= nil, true, "the zone browser status explains quiet mode")

    -- Turning quiet on drops pending discovery work and restores a pending
    -- channel selection; turning it off resumes on-demand discovery.
    c = Harness.client({ joined = true, queue = { state = "SEARCHING", peers = {} } })
    c.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 3 end
    c:start()
    for i = 1, 10 do c.R:AddMember("Peer" .. i .. " Crowd", Harness.identity(i).guid) end
    c.members = { { name = "Beta Two", guid = BETA.guid } }
    c.rosterDelay = 10
    c:advance(3)
    equal(c.P.workCount > 0, true, "discovery work is pending")
    equal(c.selected, 9, "a roster request is pending")
    c:command("quiet")
    equal(c.P.workCount, 0, "quiet mode drops pending discovery work")
    equal(c.FD.Outbound:Pending(function(item) return item.owner == c.P end), 0, "queued Outbound items are dropped")
    equal(c.selected, 1, "the pending channel selection is restored")
    local sent = #c.sent
    c:advance(120)
    equal(#c.sent, sent, "nothing is sent while quiet")
    c.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 0 end
    c:command("quiet")
    equal(c.FD.Database.data.settings.quiet, false, "the command toggles quiet mode off")
    equal(printed(c, "Quiet mode off"), true, "the command confirms resumed discovery")
    c:advance(10)
    equal(#c.sent > sent, true, "discovery resumes after quiet mode")
    local status2 = table.concat(c.FD:StatusLines(), "\n")
    equal(status2:find("Quiet mode: off", 1, true) ~= nil, true, "status shows quiet mode off")

    -- Quiet mode survives a reload (saved setting) and skips the join.
    c = Harness.client()
    c.FD.Database.data.settings.quiet = true
    c:start()
    c:advance(120)
    equal(#c.joins + #c.sent, 0, "a saved quiet setting is honoured from login")
    c:command("quiet")
    c:advance(5)
    equal(#c.joins, 1, "leaving quiet mode joins the directory")
end
