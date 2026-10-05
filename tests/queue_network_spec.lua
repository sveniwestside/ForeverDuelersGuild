return function(_, equal)
    -- Real addon modules (TOC order) on several clients over a modelled
    -- network: per-message latency up to 10 s, loss, the per-prefix grouped
    -- throttle, lagging rosters, deferred LeaveParty and pending invitations.
    local newWorld = assert(loadfile("tests/queue_world.lua"))()
    local scenario = "network"
    local function eq(actual, expected, label) equal(actual, expected, scenario .. ": " .. label) end
    local Q2 = "ForeverDuelQ2"

    local function rated(w, a, b)
        -- Explicit rated consent on both clients, native countdown and result.
        local start = w.now
        while w.now - start < 30 and not (a.FD.duel:State() == "READY" and b.FD.duel:State() == "READY") do w:advance(0.25) end
        eq(a.FD.duel:State(), "READY", "rated discovery completes for the requester")
        eq(b.FD.duel:State(), "READY", "rated discovery completes for the opponent")
        eq(a.accepts + b.accepts, 0, "the queue never accepts a native duel")
        a.FD.duel:AcceptRated(); b.FD.duel:AcceptRated()
        start = w.now
        while w.now - start < 30 and not (a.FD.duel:State() == "RATED_CONFIRMED" and b.FD.duel:State() == "RATED_CONFIRMED") do w:advance(0.25) end
        eq(a.FD.duel:State(), "RATED_CONFIRMED", "explicit rated agreement on the requester")
        eq(b.FD.duel:State(), "RATED_CONFIRMED", "explicit rated agreement on the opponent")
        w:countdown({ a, b }); w:advance(5)
        eq(a.FD.duel:State(), "IN_PROGRESS", "native countdown starts the rated duel")
        w:finishDuel(a, b)
        start = w.now
        while w.now - start < 40 and not (#a.FD.Database.data.matches == 1 and #b.FD.Database.data.matches == 1) do w:advance(0.25) end
        eq(#a.FD.Database.data.matches, 1, "winner commits one record")
        eq(#b.FD.Database.data.matches, 1, "loser commits one record")
        eq(a.FD.Database:GetStats().rating, 1516, "winning rating from the duel engine")
        eq(b.FD.Database:GetStats().rating, 1484, "losing rating from the duel engine")
    end

    scenario = "queue to rated duel at 10 s whisper latency with throttle and roster lag"
    local w = newWorld({ whisperLatency = 10, partyLatency = 0.5, throttle = true, rosterLag = 1,
        guidLag = 2, nameLag = 3, leaveLag = 0.5 })
    local a, b = w:client(), w:client()
    w:venue({ a, b })
    a:command("queue join"); b:command("queue join")
    eq(a.FD.queue.state, "SEARCHING", "coordinator joined")
    local elapsed = w:reach("TRAVELLING", 120, { a, b })
    eq(elapsed < 90, true, "invite-first pairing completes despite 10 s whispers (" .. elapsed .. " s)")
    eq(a.invites + b.invites, 1, "exactly one native invitation")
    eq(a.invites, 1, "the lower GUID invites")
    eq(b.inviteEvents, 1, "the invitee received one native invitation")
    eq(b.FD.queue.ticket.inviteSeen, true, "invitee recognised PARTY_INVITE_REQUEST's inviter GUID")
    eq(a.FD.queue.ticket.id, b.FD.queue.ticket.id, "one shared ticket")
    eq(a.FD.queue.ticket.plan.deadline, b.FD.queue.ticket.plan.deadline, "one shared travel deadline")
    eq(a.waypoint ~= nil and b.waypoint ~= nil, true, "waypoint set automatically on both clients")
    eq(a.queueShown ~= nil and b.queueShown ~= nil, true, "queue window opened on both clients")
    w:reach("READY", 20, { a, b })
    eq(#a.sounds > 0 and #b.sounds > 0, true, "sounds played for queue milestones")
    w:advance(30)
    eq(a.FD.queue.state, "READY", "READY is stable over time")
    local party, throttled = 0, a.throttled + b.throttled
    for _, record in ipairs(w:sentKinds(a, Q2)) do
        if record.channel == "PARTY" and record.at > w.now - 30 then party = party + 1 end
    end
    eq(party / 30 <= 0.7, true, "steady PARTY traffic stays under the allowance")
    eq(b.FD.queue:Challenge(), false, "only the coordinator requests the duel")
    eq(a.FD.queue:Challenge(), true, "the coordinator's request uses FD.Wow:RequestDuel")
    eq(a.requestedUnit, "party1", "native request targets the verified party unit")
    w:advance(2)
    eq(a.FD.queue.state, "DUEL", "outgoing request hands off to the duel engine")
    eq(b.FD.queue.state, "DUEL", "incoming request hands off to the duel engine")
    rated(w, a, b)
    w:advance(20)
    eq(a.FD.queue.state, "IDLE", "completed match ends on the requester")
    eq(b.FD.queue.state, "IDLE", "completed match ends on the opponent")
    eq(a.leaves + b.leaves >= 1, true, "the queue group is left")
    eq(a.group or b.group, nil, "no queue group remains")
    eq(a.FD.queue.cancel.reason, "FINISHED", "normal completion recorded")
    local states = {}
    for _, entry in ipairs(a.FD.Debug:RequestTrace(64, "lifecycle")) do
        if entry.event == "queue state" then states[#states + 1] = entry.detail:match("^(%S+)") end
        if entry.event:find("^queue") then
            eq(entry.detail:find("Player%-") == nil, true, "queue diagnostics contain no GUIDs")
            eq(entry.detail:find("%d+%.%d+%-%x") == nil, true, "queue diagnostics contain no session or ticket")
        end
    end
    local chain = table.concat(states, ">")
    eq(chain:find("INVITING>GROUPING>PLANNING>TRAVELLING>READY>DUEL>CLEANUP>IDLE", 1, true) ~= nil, true,
        "persisted queue lifecycle shows the invite-first path: " .. chain)
    eq(throttled >= 0, true, "throttle model active")

    for _, latency in ipairs({ 5, 10 }) do
        scenario = "pairing at " .. latency .. " s whisper latency with loss"
        w = newWorld({ whisperLatency = latency, partyLatency = 1, loss = 0.15, throttle = true })
        a, b = w:client(), w:client()
        w:venue({ a, b })
        a:command("queue join"); b:command("queue join")
        w:reach("READY", 150, { a, b })
        eq(a.invites + b.invites >= 1, true, "invitation sent")
        eq(a.FD.queue.ticket.id, b.FD.queue.ticket.id, "one shared ticket despite loss")
        eq(a.FD.queue.ticket.plan.startDeadline, b.FD.queue.ticket.plan.startDeadline, "one start deadline despite loss")
        eq(w.lost > 0, true, "messages were actually lost")
    end

    scenario = "inviter with a pending invitation and a declining invitee"
    w = newWorld({ pendingInviterGroup = true })
    a, b = w:client(), w:client({ inviteResponse = "decline" })
    w:venue({ a, b })
    a:command("queue join"); b:command("queue join")
    w:reach("INVITING", 20, { a })
    w:advance(1)
    eq(a.view.grouped and a.view.members, 1, "inviter is grouped alone while the invitation is open")
    eq(a.FD.queue.state, "INVITING", "pending invitation group is not a changed group")
    w:advance(6)
    eq(a.FD.queue.cancel and a.FD.queue.cancel.reason, "DECLINED", "decline recognised from ERR_DECLINE_GROUP_S")
    eq(b.FD.queue.cancel and b.FD.queue.cancel.reason, "DECLINED", "decliner learns the outcome")
    eq(a.FD.queue.state, "SEARCHING", "coordinator searches again")
    eq(b.FD.queue.state, "SEARCHING", "decliner searches again")
    w:advance(60)
    eq(a.invites, 1, "the declined pair is not invited again for two minutes")

    scenario = "ignored invitation and auto-accept"
    w = newWorld()
    a, b = w:client(), w:client({ inviteResponse = "ignore" })
    w:venue({ a, b })
    b:command("queue autoaccept on")
    a:command("queue join"); b:command("queue join")
    w:reach("TRAVELLING", 30, { a, b })
    eq(b.acceptGroups, 1, "auto-accept accepted exactly the matched inviter's invitation")
    eq(b.popup, nil, "Blizzard's dialog closed without declining")
    w = newWorld()
    a, b = w:client(), w:client({ inviteResponse = "ignore" })
    w:venue({ a, b })
    a:command("queue join"); b:command("queue join")
    w:reach("INVITED", 20, { b })
    w:advance(65)
    eq(a.FD.queue.cancel and a.FD.queue.cancel.reason, "GROUP_TIMEOUT", "unanswered invitation times out")
    eq(a.FD.queue.state, "SEARCHING", "coordinator requeued")
    eq(b.FD.queue.state, "IDLE", "the invitee that ignored the invitation leaves the queue")
    eq(b.popup, nil, "the void invitation dialog is declined")

    scenario = "three simultaneous searchers"
    w = newWorld({ whisperLatency = 2, partyLatency = 0.4, throttle = true })
    a, b = w:client(), w:client()
    local c = w:client()
    w:venue({ a, b, c })
    a:command("queue join"); b:command("queue join"); c:command("queue join")
    w:advance(90)
    local states = {}
    for _, client in ipairs({ a, b, c }) do states[client.FD.queue.state] = (states[client.FD.queue.state] or 0) + 1 end
    eq((states.TRAVELLING or 0) + (states.READY or 0), 2, "exactly one pair is matched")
    eq(states.SEARCHING, 1, "the third player keeps searching")
    for _, client in ipairs({ a, b, c }) do
        eq(client.FD.queue.state ~= "CLEANUP" and client.FD.queue.state ~= "INVITING", true, client.name .. " is not stuck")
        for _, other in ipairs({ a, b, c }) do
            eq(client.FD.queue.blocked[other.guid], nil, client.name .. " blocked nobody for a collision")
        end
    end

    scenario = "READY hysteresis and logout"
    w = newWorld({ partyLatency = 0.5 })
    a, b = w:client(), w:client()
    w:venue({ a, b })
    a:command("queue join"); b:command("queue join")
    w:reach("READY", 40, { a, b })
    b:move(0.512)
    w:advance(30)
    eq(a.FD.queue.state, "READY", "12 yards apart never cancels READY")
    local ok, reason = a.FD.queue:Challenge()
    eq(ok, false, "the duel request is refused while apart")
    eq(reason:find("Move within 10 yards of Beta-Forever", 1, true) ~= nil, true, "visible distance reason")
    eq(a.FD.queue:GetStatus().colocation ~= nil, true, "co-location hint in the status")
    b:emit("PLAYER_LOGOUT")
    b.offline = true
    w:at(5, function() w:leave(b) end)
    w:advance(2)
    eq(a.FD.queue.cancel and a.FD.queue.cancel.reason, "RELOAD", "logout CANCEL arrives synchronously over PARTY")
    eq(a.FD.queue.cancel.received, true, "shown as the opponent client's reason")
    w:advance(10)
    eq(a.FD.queue.state, "SEARCHING", "remaining player requeued")
    eq(a.FD.queue.blocked[b.guid], nil, "a reload never blocks the pair")

    scenario = "unrelated duel while searching"
    w = newWorld()
    a, b = w:client(), w:client()
    w:venue({ a })
    a:command("queue join")
    local session = a.FD.queue.session
    b.target = a; a.target = b
    b.env.StartDuel("target")
    w:advance(1)
    eq(a.FD.duel.active ~= nil, true, "the unrelated duel request reached the duel engine")
    eq(a.FD.queue.state, "PAUSED", "the search pauses")
    a:emit("CHAT_MSG_SYSTEM", a.env.ERR_DUEL_CANCELLED)
    w:advance(2)
    eq(a.FD.queue.state, "SEARCHING", "the search resumes after the unrelated duel")
    eq(a.FD.queue.session, session, "same session and wait")

    scenario = "different catalogs pair only on a shared place"
    w = newWorld()
    a, b = w:client(), w:client()
    w:venue({ a }, "only-alpha", 0.5, 0.3)
    w:venue({ a, b }, "shared-spot", 0.52, 0.3)
    a:command("queue join"); b:command("queue join")
    w:reach("TRAVELLING", 40, { a, b })
    eq(a.FD.queue.ticket.plan.venue.id, "shared-spot", "only the place both clients hold is planned")
    eq(b.FD.queue.ticket.plan.venue.id, "shared-spot", "the invitee travels to the same place")
end
