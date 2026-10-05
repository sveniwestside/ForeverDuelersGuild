return function(_, equal)
    local Harness = assert(loadfile("tests/presence_harness.lua"))()
    local BETA = { guid = "Player-1-0000BBBB", name = "Beta", surname = "Two", realm = "Forever",
        classFile = "ROGUE", level = 30, faction = "Alliance" }
    local function started(options)
        local c = Harness.client(options)
        equal(c:start(), true, "discovery initializes")
        return c
    end
    local function preserved(c, label)
        equal(c.FD.Database.data.player.ratings.LEVELING.rating, 1500, label .. " preserves rating")
        equal(#c.FD.Database.data.matches, 0, label .. " preserves match history")
    end
    local function to(c, name, tag)
        local result = {}
        for _, packet in ipairs(c:whispers(tag)) do if packet.target == name then result[#result + 1] = packet end end
        return result
    end
    local function members(c, n, offset)
        for i = 1, n do
            local identity = Harness.identity((offset or 0) + i)
            c.members[#c.members + 1] = { name = Harness.fullName(identity, true), guid = identity.guid }
        end
    end

    -- (a) Target and mouseover are asked only while the zone window is open
    -- or a tooltip shows them, and only same-faction readable players.
    local c = started({ channel = false })
    c:addUnit("target", BETA)
    c:emit("PLAYER_TARGET_CHANGED")
    c:advance(60)
    equal(#c:whispers(), 0, "a target is not queried while the zone window is closed")
    c.FD.Zone.shown = true
    c:emit("PLAYER_TARGET_CHANGED")
    equal(#c:whispers(), 0, "events only schedule; nothing is sent synchronously")
    c:advance(3)
    equal(#to(c, "Beta Two", "FDQ2"), 1, "the target is queried while the zone window is open")
    equal(to(c, "Beta Two")[1].payload, "FDQ2|Player-1-0000AAAA|1500|37|MAGE|30|60", "query carries the own profile")
    c:advance(300)
    equal(#to(c, "Beta Two"), 1, "an unanswered player is not asked again for ten minutes")
    c:advance(310)
    equal(#to(c, "Beta Two"), 2, "an unanswered player may be asked again after ten minutes")
    for _, case in ipairs({
        { "hostile faction", function(t) t.units.target.faction = "Horde" end },
        { "non-player", function(t) t.units.target.isPlayer = false end },
        { "restricted GUID", function(t) t.units.target.guid = t.secret end },
        { "restricted faction", function(t) t.units.target.faction = t.secret end },
        { "missing faction API", function(t) t.env.UnitFactionGroup = nil end },
    }) do
        local t = started({ channel = false })
        t:addUnit("target", BETA)
        case[2](t)
        t.FD.Zone.shown = true
        t:advance(30)
        equal(#t:whispers(), 0, case[1] .. " target is never queried")
    end
    c = started({ channel = false })
    c.FD.Zone.shown = true
    for i = 1, 40 do c:addUnit("nameplate" .. i, Harness.identity(i)) end
    for i = 1, 40 do c:addUnit("raid" .. i, Harness.identity(100 + i)) end
    for i = 1, 4 do c:addUnit("party" .. i, Harness.identity(200 + i)) end
    c:addUnit("focus", Harness.identity(300))
    c:advance(120)
    equal(#c:whispers(), 0, "nameplate, raid, party and focus units are never fanned out to")
    c:addUnit("mouseover", Harness.identity(400))
    c:emit("UPDATE_MOUSEOVER_UNIT")
    c:advance(3)
    equal(#c:whispers("FDQ2"), 1, "the mouseover player is queried while the zone window is open")

    -- Tooltip-driven queries are paced and only corroborated entries show.
    c = started({ channel = false })
    c:addUnit("mouseover", BETA)
    equal(c.P:Observe("mouseover"), nil, "an unknown player has no corroborated entry")
    c:advance(1)
    equal(#to(c, "Beta Two", "FDQ2"), 1, "showing a player tooltip asks that player once")
    c:addUnit("mouseover", Harness.identity(1))
    c.P:Observe("mouseover")
    c:advance(1)
    equal(#c:whispers("FDQ2"), 1, "tooltip queries are spaced globally")
    c:advance(3)
    c.P:Observe("mouseover")
    c:advance(1)
    equal(#c:whispers("FDQ2"), 2, "a later tooltip may ask the next player")
    c:receive(c:profile({ guid = "Player-1-0000CCCC", classFile = "ROGUE", level = 30 }), "Beta Two")
    c:addUnit("mouseover", BETA)
    equal(c.P:Observe("mouseover"), nil, "a profile whose GUID the unit contradicts is not shown")
    c:receive(c:profile(BETA), "Beta Two")
    local shown = c.P:Observe("mouseover")
    equal(shown.fullName, "Beta Two", "a corroborated profile is returned")
    equal(shown.verified, true, "the visible unit marks the claim verified")
    c.FD.duel.active = { state = "READY" }
    c:addUnit("mouseover", Harness.identity(2))
    c:advance(5)
    c.P:Observe("mouseover")
    c:advance(2)
    equal(#c:whispers("FDQ2"), 2, "tooltips send nothing while a duel is active")
    c.FD.duel.active = nil

    -- (b) Channel members are queried only while the zone window is open or
    -- the queue is searching, never while a duel or a ticket is active.
    local function roster(options)
        local t = started({ joined = true, queue = options and options.queue })
        members(t, 5)
        t.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 0 end
        return t
    end
    c = roster()
    c:advance(300)
    equal(#c:whispers(), 0, "members are not queried while nothing needs them")
    equal(#c.selections, 0, "no roster request without a reason")
    for _, state in ipairs({ "SEARCHING", "PAUSED" }) do
        c = roster({ queue = { state = state, peers = {} } })
        c:advance(20)
        equal(#c:whispers("FDQ2"), 5, state .. " queue state asks every member")
    end
    c = roster({ queue = { state = "SEARCHING", peers = {}, ticket = { id = "t" } } })
    c:advance(30)
    equal(#c:whispers(), 0, "a queue ticket stops discovery queries")
    c = roster()
    c.FD.duel.active = { state = "READY" }
    c.FD.Zone.shown = true
    c:advance(30)
    equal(#c:whispers(), 0, "an active duel stops discovery queries")
    c.FD.duel.active = nil
    c:advance(20)
    equal(#c:whispers("FDQ2"), 5, "queries resume after the duel")
    local first = {}
    for _, packet in ipairs(c:whispers("FDQ2")) do first[packet.target] = packet.at end
    c:advance(30)
    equal(#c:whispers("FDQ2"), 5, "members are not asked again within 45 seconds")
    c:advance(60)
    for _, packet in ipairs(c:whispers("FDQ2")) do
        if packet.at > first[packet.target] then
            equal(packet.at - first[packet.target] >= 45, true, "per-member query interval is 45 seconds")
        end
    end
    -- A query that started while idle is dropped, not sent, when a duel begins.
    c = roster({ queue = { state = "SEARCHING", peers = {} } })
    members(c, 30, 10)
    c:advance(1.5)
    local before = #c:whispers()
    c.FD.duel.active = { state = "READY" }
    c:advance(30)
    equal(#c:whispers(), before, "queued queries are dropped once a duel starts")
    equal(c.P.workCount <= 30, true, "pending work stays bounded")
    preserved(c, "duel pause")

    -- Whisper queue: a short member-query backlog, at most 30 recipients in
    -- all, replies before queries, hash dedupe.
    c = roster({ queue = { state = "SEARCHING", peers = {} } })
    for i = 1, 200 do
        local identity = Harness.identity(10 + i)
        c.R:AddMember(Harness.fullName(identity, true), identity.guid)
    end
    c.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 3 end
    c:advance(1)
    equal(c.P.workCount, 6, "member queries keep a short backlog instead of flooding the queue")
    c.P:Enqueue("Peer11 Crowd", false)
    c.P:Enqueue("Peer11 Crowd", false)
    equal(c.P.workCount <= 7, true, "duplicate recipients are deduplicated")
    for i = 1, 40 do
        local name, guid = "Asker" .. i .. " One", string.format("Player-1-0000%04X", 0xC000 + i)
        c.R:AddMember(name, guid)
        c:receive(string.format("FDQ2|%s|1500|37|MAGE|30|60", guid), name)
    end
    equal(c.P.workCount, 30, "discovery work is capped at 30 recipients")
    local replies, queries = 0, 0
    for _, entry in pairs(c.P.work) do if entry.reply then replies = replies + 1 else queries = queries + 1 end end
    equal(queries, 1, "replies displaced every waiting query except the one already handed to Outbound")
    equal(replies, 29, "the remaining capacity holds replies")
    c.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 0 end
    c:advance(12)
    local order = {}
    for _, packet in ipairs(c.sent) do
        if packet.result == 0 and packet.channel == "WHISPER" then order[#order + 1] = packet.payload:sub(1, 4) end
    end
    equal(order[1], "FDQ2", "the in-flight query goes first")
    for index = 2, math.min(#order, 8) do equal(order[index], "FDP2", "replies are sent before further queries") end
    -- A reply to a recipient whose query is queued coalesces into one whisper.
    c = started({ joined = true, queue = { state = "SEARCHING", peers = {} } })
    c.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 3 end
    c.members = { { name = "Beta Two", guid = BETA.guid } }
    c:advance(4)
    equal(#to(c, "Beta Two", "FDQ2") >= 1, true, "the query was attempted and throttled")
    c:receive(c:profile(BETA, 37, "FDQ2"), "Beta Two")
    c.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 0 end
    c:advance(10)
    local accepted = 0
    for _, packet in ipairs(to(c, "Beta Two")) do if packet.result == 0 then accepted = accepted + 1 end end
    equal(accepted, 1, "a queued query and a reply to the same player coalesce")
    equal(to(c, "Beta Two")[#to(c, "Beta Two")].payload:sub(1, 4), "FDP2", "the coalesced whisper is the reply")
    -- An expired query is marked as asked, so it is not re-added at once.
    c = started({ joined = true, queue = { state = "SEARCHING", peers = {} } })
    c.R:AddMember("Beta Two", BETA.guid)
    c.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 3 end
    c:advance(2)
    equal(c.P.work["Beta Two"] ~= nil, true, "the query is pending while throttled")
    c:advance(35)
    equal(c.P.work["Beta Two"], nil, "the throttled query expired")
    local expiredAt = c.P.queries["Beta Two"]
    equal(expiredAt ~= nil and c.now - expiredAt < 8, true, "expiry records the attempt time")
    local attempts = #to(c, "Beta Two")
    c:advance(30)
    equal(#to(c, "Beta Two"), attempts, "an expired query is not re-queued immediately")
    c:advance(25)
    equal(#to(c, "Beta Two") > attempts, true, "it is asked again after the normal interval")
    equal(c.P.workCount <= 1, true, "expired queries leave the queue")

    -- TargetOffline removes the name and is never retried.
    c = started({ joined = true, queue = { state = "SEARCHING", peers = {} } })
    c.members = { { name = "Beta Two", guid = BETA.guid } }
    c:receive(c:profile(BETA), "Beta Two")
    c.P.players["Beta Two"].lastSeen = c.now - 50
    c.sendResult = function(packet)
        if packet.channel == "CHANNEL" then return 7 end
        return packet.target == "Beta Two" and 12 or 0
    end
    c:advance(5)
    equal(#to(c, "Beta Two"), 1, "the offline recipient was attempted once")
    equal(c.P.players["Beta Two"], nil, "TargetOffline removes the cached profile")
    equal(c.R:IsMember("Beta Two"), false, "TargetOffline removes the channel member")
    c.members = {} -- The server roster no longer lists the offline player.
    c:advance(120)
    equal(#to(c, "Beta Two"), 1, "TargetOffline is not retried")

    -- "No player named ..." is hidden only for names discovery whispered
    -- within the last five seconds.
    local net = Harness.network({ latency = 0.3 })
    c = net:add(started({ channel = false }))
    net.offline = { ["Beta Two"] = true }
    c.FD.Zone.shown = true
    c:addUnit("target", BETA)
    c:receive(c:profile(BETA), "Beta Two")
    c.P.players["Beta Two"].lastSeen = c.now - 50
    local hidden
    local filter = c.filters[1].callback
    c.filters[1].callback = function(...)
        local result = filter(...)
        hidden = result
        return result
    end
    net:advance(3)
    equal(#to(c, "Beta Two", "FDQ2"), 1, "the target was queried")
    equal(hidden, true, "the addon-caused not-found message is hidden")
    equal(c.P.players["Beta Two"], nil, "the unknown name is forgotten")
    equal(c:systemMessage("No player named 'Gamma Three' is currently playing."), false, "other not-found messages stay visible")
    c.P.whispered["Delta Four"] = c.now - 6
    equal(c:systemMessage("No player named 'Delta Four' is currently playing."), false, "only whispers of the last five seconds are hidden")
    equal(c:systemMessage("Something else entirely."), false, "unrelated system messages pass")
    -- Every chat frame that shows system messages (main window, whisper
    -- popouts) runs the filter for the same line: all of them hide it, and
    -- the name is forgotten only once.
    c = started({ channel = false })
    c.FD.Zone.shown = true
    c:addUnit("target", BETA)
    c:advance(3)
    equal(#to(c, "Beta Two", "FDQ2"), 1, "the target was queried")
    local forgets, forget = 0, c.P.Forget
    c.P.Forget = function(self, name) forgets = forgets + 1; return forget(self, name) end
    local line = "No player named 'Beta Two' is currently playing."
    equal(c:systemMessage(line), true, "the main chat frame hides the addon-caused line")
    equal(c:systemMessage(line), true, "a second SYSTEM chat frame hides the same line")
    equal(c:systemMessage(line), true, "and so does any further frame")
    equal(forgets, 1, "the unknown name is forgotten once")
    c:advance(6)
    equal(c:systemMessage(line), false, "after five seconds the line is shown again")

    -- Privacy: replies go only to trusted senders; the map only to those who
    -- are visible, queue partners or channel members on the same map.
    local function reply(c2, name)
        local list = to(c2, name, "FDP2")
        return list[#list]
    end
    c = started({ joined = true })
    c.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 0 end
    c.members = { { name = "Stranger Five", guid = "Player-1-0000EEEE" } }
    c:advance(5)
    c:receive("FDQ2|Player-1-0000EEEE|1500|37|MAGE|30|60", "Stranger Five")
    c:advance(10)
    equal(reply(c, "Stranger Five"), nil, "an unverified stranger gets no reply")
    equal(#c.selections, 0, "an idle client never changes the channel selection for a stranger's query")
    equal(#c.reads, 0, "nor reads the roster for it")
    c:emit("CHAT_MSG_CHANNEL_JOIN", "", "Stranger Five", "", "", "", "", 0, 6, "ForeverDuel", 0, 0, "Player-1-0000EEEE")
    c:receive("FDQ2|Player-1-0000EEEE|1500|37|MAGE|30|60", "Stranger Five")
    c:advance(4)
    equal(reply(c, "Stranger Five").payload, "FDP2|Player-1-0000AAAA|1500|37|MAGE|30|60",
        "a sender who joined the channel is answered, with the map they share")
    -- A held query is answered when a roster update the client already has
    -- lists the sender, without touching the selection.
    local held = started({ joined = true })
    held.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 0 end
    held.members = { { name = "Late Seven", guid = "Player-1-0000EFEF" } }
    held:advance(5)
    held:receive("FDQ2|Player-1-0000EFEF|1500|37|MAGE|30|60", "Late Seven")
    equal(#to(held, "Late Seven"), 0, "an unverified query waits for proof of membership")
    held.loaded = true
    held:emit("CHANNEL_COUNT_UPDATE", 9, 1)
    held:advance(6)
    equal(#to(held, "Late Seven", "FDP2"), 1, "the held query is answered once the roster lists the sender")
    equal(#held.selections, 0, "the client roster update needed no selection change")
    held:receive("FDQ2|Player-1-0000ACDC|1500|37|MAGE|30|60", "Never Listed")
    held:advance(25)
    equal(#to(held, "Never Listed"), 0, "a sender that is never proven is dropped after the hold")
    equal(held.P.held["Never Listed"], nil, "the hold expires")
    -- While discovery runs anyway (zone window open), an unverified query
    -- may load the roster once; the selection is restored.
    held = started({ joined = true })
    held.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 0 end
    held:advance(5)
    held.FD.Zone.shown = true
    held.members = { { name = "Late Seven", guid = "Player-1-0000EFEF" } }
    held:receive("FDQ2|Player-1-0000EFEF|1500|37|MAGE|30|60", "Late Seven")
    held:advance(6)
    equal(#to(held, "Late Seven", "FDP2"), 1, "the held query is answered after the roster load")
    equal(held.selected, 1, "the native selection is restored after the roster read")
    c.R:AddMember("Member Six", "Player-1-0000FFFF")
    c:receive("FDQ2|Player-1-0000FFFF|1500|99|MAGE|30|60", "Member Six")
    c:advance(4)
    equal(reply(c, "Member Six").payload, "FDP2|Player-1-0000AAAA|1500|0|MAGE|30|60",
        "a member on another map gets map 0")
    c:receive("FDQ2|Player-1-0000FFFF|1500|99|MAGE|30|60", "Member Six")
    c:advance(2)
    equal(#to(c, "Member Six", "FDP2"), 1, "replies to one sender are rate limited")
    c:addUnit("target", { guid = "Player-1-0000ABAB", name = "Near", surname = "By", realm = "Forever",
        classFile = "MAGE", level = 30, faction = "Alliance" })
    c:receive("FDQ2|Player-1-0000ABAB|1500|99|MAGE|30|60", "Near By")
    c:advance(4)
    equal(reply(c, "Near By").payload:find("|37|", 1, true) ~= nil, true, "a visible native unit gets the real map")
    c.FD.queue = { state = "SEARCHING", peers = { ["Player-1-0000ACAC"] = { fullName = "Queue Peer" } } }
    c:receive("FDQ2|Player-1-0000ACAC|1500|99|MAGE|30|60", "Queue Peer")
    c:advance(4)
    equal(reply(c, "Queue Peer").payload:find("|37|", 1, true) ~= nil, true, "a queue peer gets the real map")
    c.FD.queue = { state = "TRAVEL", peers = {}, ticket = { peer = { fullName = "Ticket Mate" } } }
    c:receive("FDQ2|Player-1-0000ADAD|1500|99|MAGE|30|60", "Ticket Mate")
    c:advance(4)
    equal(reply(c, "Ticket Mate") ~= nil, true, "the ticket partner is answered while a ticket is active")
    c:receive("FDQ2|Player-1-0000AEAE|1500|37|MAGE|30|60", "Other Eight")
    c:advance(25)
    equal(reply(c, "Other Eight"), nil, "replies never go to unverified senders, even during a ticket")
    preserved(c, "privacy rules")

    -- Freshness: a zone change pushes the new profile to trusted cached
    -- peers (rate limited) and lets them be asked again.
    c = started({ joined = true })
    c.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 0 end
    for i = 1, 3 do
        local identity = Harness.identity(i)
        c.R:AddMember(Harness.fullName(identity, true), identity.guid)
        c:receive(c:profile(identity), Harness.fullName(identity, true))
    end
    c:receive(c:profile({ guid = "Player-1-0000E0E0", classFile = "MAGE", level = 30 }), "Unknown Nine")
    c:advance(40)
    local pushes = #c:whispers("FDP2")
    c.mapID = 38
    c:emit("ZONE_CHANGED_NEW_AREA")
    c:advance(8)
    equal(#c:whispers("FDP2") - pushes, 3, "the new profile goes to every trusted cached peer once")
    equal(#to(c, "Unknown Nine", "FDP2"), 0, "untrusted cached senders get no push")
    c.mapID = 39
    c:emit("ZONE_CHANGED_NEW_AREA")
    c:advance(8)
    equal(#c:whispers("FDP2") - pushes, 3, "pushes are rate limited to one per 30 seconds")
    c:advance(30)
    equal(#c:whispers("FDP2") - pushes, 6, "the latest map is pushed after the rate limit")

    -- Most zone changes pass a loading screen (hearthstone, portal, boat,
    -- instance). The cache and the channel members survive it, so the new
    -- map still reaches the trusted peers.
    c = started({ joined = true })
    c.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 0 end
    c:advance(5)
    for i = 1, 2 do
        local identity = Harness.identity(i)
        c.R:AddMember(Harness.fullName(identity, true), identity.guid)
        c:receive(c:profile(identity), Harness.fullName(identity, true))
    end
    c:advance(40)
    pushes = #c:whispers("FDP2")
    c:emit("PLAYER_LEAVING_WORLD")
    c.mapID = 41
    c:advance(8)
    equal(#c:whispers("FDP2"), pushes, "nothing is sent during the loading screen")
    c:emit("PLAYER_ENTERING_WORLD")
    c:emit("ZONE_CHANGED_NEW_AREA")
    c:advance(8)
    equal(#c:whispers("FDP2") - pushes, 2, "a zone change through a loading screen reaches the trusted peers")
    local push = c:whispers("FDP2")[#c:whispers("FDP2")]
    equal(push.payload, "FDP2|Player-1-0000AAAA|1500|0|MAGE|30|60",
        "members still listed on the old map learn that we left it (map 0)")
    equal(c.R:IsMember("Peer1 Crowd"), true, "channel members survive the loading screen")

    -- CPU: events only schedule; one Tick at most every two seconds; one
    -- own-profile computation per Tick; no periodic roster polling.
    c = started({ joined = true })
    members(c, 300)
    c.FD.Zone.shown = true
    local ticks, owns = 0, 0
    local tick, getOwn = c.P.Tick, c.P.GetOwnPlayer
    c.P.Tick = function(self) ticks = ticks + 1; return tick(self) end
    c.P.GetOwnPlayer = function(self) owns = owns + 1; return getOwn(self) end
    c:advance(20)
    ticks, owns = 0, 0
    for _ = 1, 200 do
        c:emit("PLAYER_TARGET_CHANGED")
        c:emit("CHANNEL_COUNT_UPDATE", 3, 20)
        c:emit("UPDATE_MOUSEOVER_UNIT")
    end
    c:advance(1)
    equal(ticks <= 1, true, "a burst of 600 events runs at most one Tick")
    c:advance(9)
    equal(ticks <= 5, true, "Ticks are at least two seconds apart")
    equal(owns <= ticks + 10, true, "the own profile is computed once per Tick plus once per sent whisper")
    equal(c.FD.eventHandlers.NAME_PLATE_UNIT_ADDED, nil, "nameplate events are not handled at all")
    c = started({ joined = true })
    members(c, 50)
    c:advance(600)
    equal(#c.reads, 0, "an idle client never polls the channel roster")
    equal(#c.selections, 0, "an idle client never changes the channel selection")
    c.loaded = true
    c:emit("CHANNEL_COUNT_UPDATE", 9, 50)
    c:advance(3)
    equal(#c.reads > 0, true, "a count update for our channel reads the roster")
    equal(#c.selections, 0, "reading an available roster needs no selection change")
    equal(c.R:IsMember("Peer1 Crowd"), true, "members are learned from the read")
    local reads = #c.reads
    c:emit("CHANNEL_COUNT_UPDATE", 3, 20)
    c:advance(3)
    equal(#c.reads, reads, "another channel's count update is ignored")
end
