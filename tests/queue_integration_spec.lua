return function(_, equal)
    -- The actual TOC, Core, native adapters and both lifecycle engines are
    -- loaded per client (tests/queue_world.lua). Only presentation and
    -- automatic discovery are replaced: a deterministic integration harness,
    -- not a claim about a live WoW client.
    local newWorld = assert(loadfile("tests/queue_world.lua"))()

    local w = newWorld()
    local c = w:client()
    equal(c.loaded[#c.loaded], "Core.lua", "integration follows real TOC order")
    equal(c.FD.queue.state, "IDLE", "optional queue initializes alongside rated engine")
    equal(c.FD.duel:State(), "IDLE", "queue initialization preserves ordinary rated readiness")
    equal(c.FD.Comms.available, true, "existing rated prefix remains registered")
    equal(c.FD.QueueTransport.available, true, "queue has its own registered prefix")
    equal(c.FD.QueueWow:Settings().ruleset, "NORMAL", "ruleset comes from native game rules automatically")
    c:command("queue join")
    equal(c.FD.queue.state, "SEARCHING", "first join searches without manual ruleset or venue setup")
    equal(c.queueShown ~= nil, true, "joining opens queue status UI")
    c:command("queue status")
    equal(c:printed("Queue: SEARCHING"), true, "queue status command prints the state")
    c:command("status")
    equal(c:printed("Queue profiles:"), true, "global status includes the queue section")
    c:command("queue leave")
    equal(c.FD.queue.state, "IDLE", "leave from searching goes straight to idle")
    equal(c.FD.queue:Configure({ ruleset = "PVP" }), false, "native ruleset cannot be overwritten through public settings")
    c:command("queue help")
    equal(c:printed("queue join | leave | status | autoaccept"), true, "help lists the queue commands")
    c:command("queue autoaccept on")
    equal(c.FD.QueueWow:Settings().autoAcceptQueueInvite, true, "auto-accept toggled by command")
    c:command("queue autoaccept off")
    equal(c.FD.QueueWow:Settings().autoAcceptQueueInvite, false, "auto-accept off by command")
    equal(c.FD.queue:Configure({ scope = "CONTINENT" }), true, "continent scope available immediately")
    c.FD.queue:Configure({ scope = "ZONE" })
    c:command("queue venue add test-courtyard 1 1 10")
    local command
    for i = #c.prints, 1, -1 do
        command = command or c.prints[i]:match("(/duelrating queue venue import .+)$")
    end
    command = assert(command, "venue capture must print an exact import command")
    local first = c.FD.QueueWow:FindVenue("test-courtyard")
    equal(first.factions.Alliance, true, "captured place restricted to own faction")
    local other = w:client()
    other:command((command:gsub("^/duelrating ", "")))
    local imported = assert(other.FD.QueueWow:FindVenue("test-courtyard"))
    equal(imported.mapX, first.mapX, "clients retain exact same normalized X")
    equal(imported.mapY, first.mapY, "clients retain exact same normalized Y")
    c:command("queue join")
    local saved = c.FD.Database.data
    c:command("reset")
    equal(c.FD.resetUntil, nil, "reset confirmation cannot be opened while queued")
    c.FD.resetUntil = w.now + 15
    c:command("reset confirm")
    equal(c.FD.Database.data, saved, "preexisting confirmation cannot bypass queue reset guard")
    equal(c.FD.queue:Configure({ levelGap = 1 }), false, "active queue freezes settings")
    w:presence()
    c.FD.queue:Announce(other.fullName)
    w:advance(1)
    local announced
    for _, record in ipairs(w:sentKinds(c, "ForeverDuelQ2")) do
        if record.kind == "PROFILE" then announced = record end
    end
    equal(announced ~= nil, true, "adapter profile metadata does not block discovery transport")
    equal(c.accepts, 0, "joining and announcing cannot grant native duel consent")
    equal(#c.FD.Database.data.matches, 0, "joining and announcing cannot create rating history")

    -- Save tested place: an ordinary native duel, then the button. The
    -- partner's client confirms with VENUE_ACK before "saved on both".
    w = newWorld()
    local spec = { mapID = 1420, faction = "Horde", emptyMetadata = true }
    local setupA = w:client(spec)
    local setupB = w:client({ mapID = 1420, faction = "Horde", emptyMetadata = true, mapX = 0.505 })
    equal(setupA.FD:CaptureQueueVenue(), false, "button cannot approve an untested outdoor place")
    setupA.target, setupB.target = setupB, setupA
    setupA.env.StartDuel("target")
    w:advance(0.5)
    setupA.env.AcceptDuel(); setupB.env.AcceptDuel()
    w:countdown({ setupA, setupB }); w:advance(4)
    w:finishDuel(setupA, setupB)
    w:advance(1)
    setupA.target, setupB.target = nil, nil
    equal(setupA.FD:CaptureQueueVenue(), true, "button records an ordinary native-tested spot automatically")
    equal(setupA:printed("waiting for their client to confirm"), true, "sender is not told 'saved' before the ACK")
    setupB:command("queue join")
    w:advance(2)
    local captured = setupA.FD.QueueWow:Catalog()[1]
    local synchronized = setupB.FD.QueueWow:Catalog()[1]
    equal(synchronized ~= nil, true, "second client accepts the place after its own successful test")
    equal(synchronized.id, captured.id, "both clients hold the same venue ID")
    equal(setupA:printed("it is now on both clients"), true, "VENUE_ACK confirms the share on the sender")
    equal(setupB.FD.queue.state, "SEARCHING", "place import while searching preserves the queue session")
    equal(captured.metadataSource, "CLASSIC", "fallback source is retained locally")
    setupB:command("queue leave")
    equal(setupB.FD:CaptureQueueVenue(), true, "the partner can also press Save at the same spot")
    w:advance(2)
    equal(#setupB.FD.QueueWow:Catalog(), 1, "double-saving one spot creates no second ID")
    equal(#setupA.FD.QueueWow:Catalog(), 1, "the partner's catalog stays at one record")
    equal(setupB.FD.QueueWow:Catalog()[1].id, captured.id, "both catalogs converge on one ID")
    equal(setupB:printed("it is now on both clients"), true, "the second share is acknowledged too")
    equal(#setupA.FD.Database.data.matches + #setupB.FD.Database.data.matches, 0, "native venue testing creates no rated history")
    equal(setupA.FD.Database:GetStats().rating, 1500, "saving and sharing a tested place never changes rating")

    -- A rejected share is reported on both clients.
    local loneA = w:client({ mapID = 1420, faction = "Horde", emptyMetadata = true, mapX = 0.7 })
    loneA.FD.QueueWow.venueTest = setupA.FD.Copy(setupA.FD.QueueWow.venueTest)
    loneA.FD.QueueWow.venueTest.peer = { guid = setupB.guid, fullName = setupB.fullName, level = 30 }
    loneA.FD.QueueWow.venueTest.player = { guid = loneA.guid, fullName = loneA.fullName, level = 30 }
    loneA.FD.QueueWow.venueTest.position = loneA.FD.QueueWow:Position()
    equal(loneA.FD:CaptureQueueVenue(), true, "a third client saves its own tested place")
    w:advance(2)
    equal(loneA:printed("could not save the place because"), true, "VENUE_REJECT explained to the sender")
    equal(setupB:printed("Could not save the place shared by"), true, "rejection explained to the receiver")
    local rejectedTrace = false
    for _, entry in ipairs(setupB.FD.Debug:RequestTrace(64, "lifecycle")) do
        if entry.event == "queue venue" and entry.detail:find("rejected", 1, true) then rejectedTrace = true end
    end
    equal(rejectedTrace, true, "rejected import persisted in the lifecycle diagnostics")

    -- Queue match through the rated engine; the first finished client keeps
    -- the queue group until the slower client has its peer result.
    for _, delayBeta in ipairs({ true, false }) do
        w = newWorld({ partyLatency = 0.3 })
        local a, b = w:client(), w:client()
        w:venue({ a, b })
        a:command("queue join"); b:command("queue join")
        w:reach("READY", 40, { a, b })
        equal(a.FD.queue:Challenge(), true, "coordinator requests the duel")
        w:advance(2)
        equal(a.FD.queue.state, "DUEL", "outgoing request handed to the rated engine")
        equal(b.FD.queue.state, "DUEL", "incoming request handed to the rated engine")
        equal(a.FD.queue.ticket.duelMatch, a.FD.duel.active, "hand-off binds the exact native duel object")
        w:advance(3)
        equal(b.accepts, 0, "queue READY cannot auto-accept the native duel")
        a.FD.duel:AcceptRated(); b.FD.duel:AcceptRated(); w:advance(3)
        equal(a.FD.duel:State(), "RATED_CONFIRMED", "explicit outgoing rated agreement")
        equal(b.accepts, 1, "only the rated agreement accepts the native duel")
        w:countdown({ a, b }); w:advance(5)
        local first, slower = delayBeta and b or a, delayBeta and a or b
        first.options.partyLatency = function(record)
            local packet = record.prefix == first.FD.C.PREFIX and first.FD.Protocol:Decode(record.payload)
            if packet and packet.kind == "RESULT" then return 5 end
            return 0.3
        end
        first.options.whisperLatency = first.options.partyLatency
        w:finishDuel(a, b)
        w:advance(3)
        equal(#first.FD.Database.data.matches, 1, "first client commits with the peer's result")
        equal(#slower.FD.Database.data.matches, 0, "delayed result keeps the slower client uncommitted")
        equal(slower.FD.duel:State(), "FINISHING", "a queue finish notice cannot unrate the slower duel")
        equal(first.FD.queue.state, "CLEANUP", "first finished queue waits for the peer's terminal")
        equal(first.group ~= nil and slower.group ~= nil, true, "native party retained for the slower client's result")
        equal(first.leaves + slower.leaves, 0, "cleanup cannot remove the slower client's party opponent")
        w:advance(5)
        equal(#slower.FD.Database.data.matches, 1, "slower client commits after the delayed result")
        equal(a.FD.Database:GetStats().rating, 1516, "reciprocal win")
        equal(b.FD.Database:GetStats().rating, 1484, "reciprocal loss")
        w:advance(10)
        equal(first.FD.queue.state, "IDLE", "peer completion releases the first client's cleanup")
        equal(slower.FD.queue.state, "IDLE", "both clients end the queue match")
        equal(first.group or slower.group, nil, "the shared queue group is gone")
    end

    -- Positive group changes during a match are never left automatically.
    for _, change in ipairs({ "third member", "raid" }) do
        w = newWorld()
        local a, b = w:client(), w:client()
        local stranger = w:client({ guid = "Player-1-0000000F" })
        w:venue({ a, b })
        a:command("queue join"); b:command("queue join")
        w:reach("TRAVELLING", 40, { a, b })
        if change == "raid" then a.group.raid = true
        else
            a.group.members[3] = stranger
            stranger.group = a.group
        end
        w:roster(a); w:roster(b)
        w:advance(4)
        equal(a.FD.queue.cancel and a.FD.queue.cancel.reason, "GROUP_CHANGED", change .. " is a confirmed group change")
        equal(a.leaves, 0, change .. " group is never left automatically")
        equal(a.FD.queue.state ~= "CLEANUP", true, change .. " never traps the queue in cleanup")
        equal(a.accepts, 0, change .. " cancellation cannot grant native duel acceptance")
        equal(#a.FD.Database.data.matches, 0, change .. " cancellation cannot write rating history")
        equal(a.FD.QueueWow:Settings().cooldownUntil, 0, change .. " is technical, without a no-show pause")
        if change == "third member" then
            local status = a.FD.queue:GetStatus()
            equal(status.cleanupStatus ~= nil, true, "the leftover group is advised")
            equal(status.groupAction, false, "no Leave group while a third player is in the group")
            a:command("queue leave")
            equal(a.FD.queue.state, "IDLE", "leaving the paused search")
            equal(a.FD.queue:GetStatus().cleanupStatus ~= nil, true, "leaving the search keeps the leftover-group advisory")
            local refreshes = 0
            a.FD.QueueUI.RefreshIfShown = function() refreshes = refreshes + 1 end
            table.remove(a.group.members, 3)
            stranger.group = nil
            w:roster(a)
            w:advance(0.5)
            equal(refreshes > 0, true, "the roster change refreshes the queue window at once")
            equal(a.FD.queue:GetStatus().groupAction, true, "Leave group is offered once only the queue pair remains")
        end
    end

    w = newWorld()
    local world = w:client()
    local peer = w:client()
    world.target = peer
    world:emit("DUEL_REQUESTED", peer.fullName)
    local active = world.FD.duel.active
    equal(active ~= nil, true, "an unrelated rated request exists")
    world:emit("PLAYER_ENTERING_WORLD")
    equal(world.FD.duel.active, active, "queue loading completion preserves unrelated rated duel")
    world:emit("PLAYER_LEAVING_WORLD")
    equal(world.FD.duel.active, nil, "existing Core world-transition rated abort remains explicit baseline")
    local disabled = w:client({ prefixFailure = "ForeverDuelQ2" })
    equal(disabled.FD.QueueTransport.available, false, "optional queue prefix failure reported")
    disabled.target = peer
    disabled:emit("DUEL_REQUESTED", peer.fullName)
    equal(disabled.FD.duel:State(), "CHECKING_ADDON", "queue transport failure does not disable existing rated duels")
    equal(disabled.accepts, 0, "unavailable queue cannot grant native consent")
end
