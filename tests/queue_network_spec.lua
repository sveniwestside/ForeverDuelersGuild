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
        local nonces = { a.FD.duel.active.nonce, b.FD.duel.active.nonce }
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
        return nonces
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
    -- The real secrets of this match, checked against every saved diagnostic.
    local secrets = { a.FD.queue.ticket.id, a.FD.queue.session, b.FD.queue.session }
    eq(#secrets, 3, "ticket and both sessions captured")
    eq(#a.sounds > 0 and #b.sounds > 0, true, "sounds played for queue milestones")
    w:advance(30)
    eq(a.FD.queue.state, "READY", "READY is stable over time")
    local party = 0
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
    for _, nonce in ipairs(rated(w, a, b)) do secrets[#secrets + 1] = nonce end
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
        end
    end
    -- No session, ticket or rated nonce in any saved entry of either client.
    eq(#secrets, 5, "both rated nonces captured")
    for _, client in ipairs({ a, b }) do
        local saved = client.FD.Debug:RequestTrace(200)
        for _, failure in ipairs(client.FD.Debug:Errors()) do
            saved[#saved + 1] = { event = "error", detail = (failure.message or "") .. " " .. (failure.stack or "") }
        end
        eq(#saved > 0, true, "diagnostics were recorded")
        for _, entry in ipairs(saved) do
            for _, secret in ipairs(secrets) do
                eq(entry.detail:find(secret, 1, true), nil, "diagnostics never contain a session, ticket or nonce ("
                    .. entry.event .. ")")
            end
        end
    end
    local chain = table.concat(states, ">")
    eq(chain:find("INVITING>GROUPING>PLANNING>TRAVELLING>READY>DUEL>CLEANUP>IDLE", 1, true) ~= nil, true,
        "persisted queue lifecycle shows the invite-first path: " .. chain)

    scenario = "throttled PARTY state changes are retried"
    w = newWorld({ throttle = true, partyLatency = 0.5 })
    a, b = w:client(), w:client()
    w:venue({ a, b })
    a:command("queue join"); b:command("queue join")
    w:reach("GROUPING", 30, { a })
    -- Other traffic exhausted the coordinator's per-prefix allowance.
    a.tokens[Q2] = { tokens = -3, at = w.now }
    w:reach("TRAVELLING", 40, { a, b })
    eq(a.throttled > 0, true, "the per-prefix throttle rejected PARTY sends (" .. a.throttled .. ")")
    local rejected, retried = {}, false
    for _, record in ipairs(w:sentKinds(a, Q2)) do
        if record.channel == "PARTY" and record.result == 3 then rejected[record.kind] = true
        elseif record.channel == "PARTY" and record.result == 0 and rejected[record.kind] then retried = true end
    end
    eq(retried, true, "a throttled PARTY packet was sent again once the allowance refilled")
    eq(a.FD.queue.ticket.plan.deadline, b.FD.queue.ticket.plan.deadline, "the plan survived the throttle")

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

    local function logged(client, event, detail)
        for _, entry in ipairs(client.FD.Debug:RequestTrace(256, "lifecycle")) do
            if entry.event == event and entry.detail:find(detail, 1, true) then return true end
        end
        return false
    end
    for _, latency in ipairs({ 3, 10 }) do
        scenario = "quick decline, then an immediate re-offer to a third client at " .. latency .. " s"
        -- Alpha invites Gamma, Gamma declines, Alpha requeues with a new
        -- session and at once invites Beta, whose copy of Alpha's PROFILE
        -- still names the old session. Beta and Gamma cannot pair.
        w = newWorld({ whisperLatency = latency, partyLatency = 0.5 })
        a = w:client({ level = 30 })
        b = w:client({ level = 26, acceptDelay = 2 })
        c = w:client({ level = 34, inviteResponse = "decline", acceptDelay = 0.5 })
        w:venue({ a, b, c })
        c:command("queue join"); w:advance(3)
        b:command("queue join"); a:command("queue join")
        w:reach("TRAVELLING", 90, { a, b })
        eq(a.FD.queue.ticket.id, b.FD.queue.ticket.id, "Alpha and Beta share one ticket")
        eq(a.FD.queue.ticket.plan.deadline, b.FD.queue.ticket.plan.deadline, "one travel deadline")
        eq(a.FD.queue.cancel and a.FD.queue.cancel.reason, "DECLINED", "the decline ended the first offer")
        eq(b.FD.queue.cancel, nil, "Beta never cancelled (no PEER_SILENT)")
        eq(a.leaves + b.leaves, 0, "the accepted group is kept")
        if latency == 10 then eq(logged(b, "queue invite", "rekeyed"), true, "Beta re-keyed from the stale session") end
        eq(c:printed("Accept the group invitation"), false, "the declined invitation is never announced late")
        eq(c.acceptGroups or 0, 0, "the declined invitation is never accepted")
        eq(c.FD.queue.state, "SEARCHING", "Gamma keeps searching")
    end

    -- Four searchers with random 0-10 s whispers, 10 % loss, the throttle,
    -- lagging rosters and some players who decline: requeues on both sides
    -- of an invitation must never strand a formed group (PEER_SILENT).
    local seed = 7
    local function random()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    for round = 1, 6 do
        scenario = "four searchers under loss and requeues, round " .. round
        w = newWorld({ whisperLatency = function() return random() * 10 end,
            partyLatency = function() return 0.2 + random() end, loss = 0.1, throttle = true,
            rosterLag = 1, guidLag = 1, nameLag = 2 })
        local list, silent = {}, {}
        for i = 1, 4 do
            local client = w:client({ level = 28 + i, acceptDelay = 0.5 + random() * 4,
                inviteResponse = (round + i) % 3 == 0 and "decline" or "accept" })
            list[i] = client
            -- Every outcome, not only the bounded diagnostic ring.
            local env = client.FD.queue.env
            local log = env.log
            env.log = function(topic, reason, ...)
                if topic == "queue cancel" and reason == "PEER_SILENT" then silent[client.name] = true end
                return log(topic, reason, ...)
            end
        end
        w:venue(list)
        for i = 1, 4 do list[i]:command("queue join"); w:advance(random() * 3) end
        w:advance(240)
        local ready = 0
        for _, client in ipairs(list) do
            eq(client.FD.queue.lastErrorAt, nil, client.name .. " had no queue error")
            eq(silent[client.name], nil, client.name .. " never stranded in a group (PEER_SILENT)")
            if client.FD.queue.state == "READY" then ready = ready + 1 end
        end
        eq(ready >= 2, true, "at least one pair reached the meeting place (" .. ready .. " ready)")
    end

    scenario = "a late PROFILE never revives a declined or rescinded invitation"
    w = newWorld({ whisperLatency = 10, partyLatency = 0.5 })
    a = w:client()
    c = w:client({ inviteResponse = "decline", acceptDelay = 0.5 })
    w:venue({ a, c })
    c:command("queue join"); w:advance(3); a:command("queue join")
    local declinedAt, invitedAt
    for _ = 1, 200 do
        w:advance(0.25)
        if not declinedAt and (c.inviteEvents or 0) > 0 and not c.popup then declinedAt = w.now end
        if not invitedAt and c.FD.queue.state == "INVITED" then invitedAt = w.now end
    end
    eq(declinedAt ~= nil, true, "the invitation was declined in Blizzard's dialog")
    eq(invitedAt, nil, "the invitee never enters INVITED for a declined invitation")
    eq(c:printed("Accept the group invitation"), false, "no stale accept prompt")
    eq(#c.sounds, 0, "no stale invitation sound")
    eq(c.queueShown, 1, "the window opened only for the join")
    eq(a.FD.queue.cancel and a.FD.queue.cancel.reason, "DECLINED", "the coordinator saw the decline")
    w = newWorld({ whisperLatency = 10, partyLatency = 0.5 })
    a = w:client()
    c = w:client({ inviteResponse = "ignore" })
    w:venue({ a, c })
    c:command("queue autoaccept on")
    c:command("queue join"); w:advance(3); a:command("queue join")
    for _ = 1, 120 do
        w:advance(0.25)
        if c.popup then break end
    end
    eq(c.popup ~= nil and c.FD.queue.state == "SEARCHING", true, "the invitation arrived before the inviter's PROFILE")
    -- The inviter rescinds: PARTY_INVITE_CANCEL hides Blizzard's dialog.
    c.pending = nil
    c.env.StaticPopup_Hide("PARTY_INVITE")
    c:emit("PARTY_INVITE_CANCEL")
    w:advance(30)
    eq(c.acceptGroups or 0, 0, "auto-accept never answers a rescinded invitation")
    eq(c:printed("Accept the group invitation"), false, "a rescinded invitation is never announced")

    scenario = "pair block after a voluntary leave is symmetric"
    w = newWorld()
    a, b = w:client(), w:client()
    w:venue({ a, b })
    a:command("queue join"); b:command("queue join")
    w:reach("TRAVELLING", 40, { a, b })
    a:command("queue leave")
    w:advance(5)
    eq(a.FD.queue.state, "IDLE", "the leaver is idle")
    eq(b.FD.queue.state, "SEARCHING", "the other player searches again")
    eq(a.FD.queue.blocked[b.guid] ~= nil, true, "the leaver pauses the pair as well")
    eq(b.FD.queue.blocked[a.guid] ~= nil, true, "the remaining player pauses the pair")
    local invites, events = a.invites, b.inviteEvents or 0
    a:command("queue join")
    w:advance(100)
    eq(a.invites, invites, "a rejoining leaver never invites the paused pair")
    eq((b.inviteEvents or 0) - events, 0, "no raw invitation without queue context")
    eq(a.FD.queue.state, "SEARCHING", "the leaver keeps searching")
    w:reach("TRAVELLING", 60, { a, b })
    eq(a.invites, invites + 1, "the pair matches again once the pause has expired")

    scenario = "a voluntary leave while searching"
    w = newWorld()
    a = w:client()
    w:venue({ a })
    a:command("queue join")
    local shown, lines = a.queueShown, #a.prints
    a:command("queue leave")
    eq(a.FD.queue.state, "IDLE", "left the queue")
    eq(#a.prints - lines, 1, "one chat line for the leave")
    eq(#a.sounds, 0, "no cancellation sound for the player's own leave")
    eq(a.queueShown, shown, "the queue window is not reopened")
end
