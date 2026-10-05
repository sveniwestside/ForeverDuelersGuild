return function(_, equal)
    -- Cross-module soak (review arch-3, queuenative-8, forensics-1). The real
    -- TOC runs on 2-4 clients over tests/soak_world.lua: presence, roster,
    -- queue and duel traffic together, per-sender FIFO delivery with a
    -- configurable delay line, the per-prefix grouped allowance, the
    -- ForeverDuel channel, a lagging party roster, asynchronous LeaveParty
    -- and surname names. Every scenario ends with the same health checks.
    local newWorld = assert(loadfile("tests/soak_world.lua"))()
    local scenario = "soak"
    local function eq(actual, expected, label) equal(actual, expected, scenario .. ": " .. label) end
    local function ok(value, label) equal(value and true or false, true, scenario .. ": " .. label) end
    local Q2, ZONE = "ForeverDuelQ2", "ForeverDuelZone2"

    local function printed(c, text, since) return c:printed(text, since) end
    local function lifecycle(c, event, detail)
        for _, entry in ipairs(c.FD.Debug:RequestTrace(256, "lifecycle")) do
            if entry.event == event and (not detail or entry.detail:find(detail, 1, true)) then return true end
        end
        return false
    end
    local function chain(c)
        local states = {}
        for _, entry in ipairs(c.FD.Debug:RequestTrace(256, "lifecycle")) do
            if entry.event == "queue state" then states[#states + 1] = entry.detail:match("^(%S+)") end
        end
        return table.concat(states, ">")
    end
    local function channels(list)
        local seen = {}
        for _, packet in ipairs(list) do seen[packet.channel] = true end
        return seen
    end
    -- Persisted errors, traffic counters against native submissions, and the
    -- Outbound whisper budget (8, then 1/s; synchronous terminal packets may
    -- add a couple). errors: client -> expected number of persisted errors.
    local function healthy(w, list, errors)
        for _, c in ipairs(list) do
            eq(#c.FD.Debug:Errors(), errors and errors[c] or 0, c.name .. " persisted Lua errors")
            local native = {}
            for _, record in ipairs(c.sent) do
                local key = record.prefix .. " " .. record.channel
                native[key] = (native[key] or 0) + 1
            end
            for key, count in pairs(native) do
                local entry = c.FD.Debug.traffic[key]
                eq(entry and entry.totals.submitted, count, c.name .. " traffic counter covers every native " .. key)
            end
            for _, span in ipairs({ 10, 60 }) do
                ok(w:whisperBurst(c, span) <= 8 + span + 2, c.name .. " whispers within the Outbound budget per " .. span .. " s ("
                    .. w:whisperBurst(c, span) .. ")")
            end
            eq(c.throttled, 0, c.name .. " never runs into the server's grouped allowance")
            for _, line in ipairs(c.system) do
                ok(not line:find("is currently playing", 1, true), c.name .. " shows no addon-caused not-found line: " .. line)
            end
        end
    end
    local function settle(w, list, limit)
        return w:wait(limit, function()
            for _, c in ipairs(list) do if c.walking then return false end end
            return true
        end)
    end
    -- Both rated buttons, the native countdown and a knockout of `loser`.
    local function ratedDuel(w, winner, loser)
        ok(w:wait(30, function() return winner:duelState() == "READY" and loser:duelState() == "READY" end),
            "rated discovery completes on both clients")
        eq(winner.accepts + loser.accepts, 0, "the queue never accepts the native duel")
        winner:clickRated(); loser:clickRated()
        ok(w:wait(30, function() return winner:duelState() == "IN_PROGRESS" and loser:duelState() == "IN_PROGRESS" end),
            "both rated buttons and the native countdown start the duel")
        w:advance(6)
        w:finishDuel(winner, loser)
        ok(w:wait(40, function() return #winner.FD.Database.data.matches == 1 and #loser.FD.Database.data.matches == 1 end),
            "both clients commit the result")
        local rw, rl = winner.FD.Database:GetStats().rating, loser.FD.Database:GetStats().rating
        eq(rw - 1500, 1500 - rl, "complementary rating changes")
        ok(rw > 1500, "the winner gains rating")
        eq(winner.FD.Database.data.matches[1].matchId, loser.FD.Database.data.matches[1].matchId, "one match ID on both clients")
    end

    -- The server model itself ---------------------------------------------------
    scenario = "soak world"
    local w = newWorld({ whisperLatency = function(record) return tonumber(record.payload) end, nameLag = 2 })
    local a, b = w:client(), w:client({ inviteResponse = "accept", acceptDelay = 1 })
    eq(a.fullName, "Alpha Stone", "surname names as on Forever")
    local send = a.env.C_ChatInfo.SendAddonMessage
    for _, delay in ipairs({ 9, 3, 1 }) do eq(send("SoakProbe", tostring(delay), "WHISPER", b.fullName), 0, "whisper submitted") end
    w:advance(10)
    local order = {}
    for _, entry in ipairs(b.received) do if entry.prefix == "SoakProbe" then order[#order + 1] = entry.payload .. "@" .. entry.at end end
    eq(table.concat(order, " "), "9@9 3@9 1@9", "one sender's whispers stay in order behind the slowest")
    eq(send("SoakProbe", "x", "PARTY"), 5, "PARTY without a group is NotInGroup")
    a.env.C_PartyInfo.InviteUnit(b.fullName)
    w:advance(2)
    eq(b.FD.queue.state, "IDLE", "a plain invitation does not touch the queue")
    eq(b.group ~= nil, true, "the invitation was accepted")
    eq(a.env.UnitGUID("party1"), b.guid, "party1 GUID is visible first")
    eq(a.env.UnitFullName("party1"), "Unknown", "while its name is still loading")
    w:advance(2)
    eq(a.env.NameUtil.GetUnmodifiedUnitFullName("party1"), b.fullName, "then the name follows")
    local results = {}
    for i = 1, 12 do results[i] = send("SoakProbe", "p" .. i, "PARTY") end
    eq(results[10], 0, "ten grouped messages pass")
    eq(results[11], 3, "the eleventh is AddonMessageThrottle")
    w:advance(1)
    eq(send("SoakProbe", "again", "PARTY"), 0, "the allowance refills at one per second")
    a.env.C_PartyInfo.LeaveParty()
    eq(a.group ~= nil, true, "LeaveParty is asynchronous")
    w:advance(1)
    eq(a.group, nil, "the group is left a moment later")

    -- S1 ---------------------------------------------------------------------
    scenario = "S1 ten idle minutes, zone window closed"
    w = newWorld()
    a, b = w:client(), w:client({ mapX = 0.51 })
    local c = w:client({ mapX = 0.49 })
    local passer = w:stranger({ mapX = 0.505 })              -- visible and targeted, no addon
    local lurker = w:stranger({ channel = true, mapX = 0.6 }) -- in the channel, no addon
    a.target, b.target = passer, lurker
    w:advance(600)
    for _, client in ipairs({ a, b, c }) do
        local t = w:traffic(client)
        eq(client.joined, true, client.name .. " joined the ForeverDuel channel")
        eq(#client.FD.Presence:GetPlayers(), 2, client.name .. " discovered both addon players")
        eq(client.FD.Presence:ChannelMode(), true, client.name .. " uses CHANNEL broadcasts")
        eq(client.rosterRequests, nil, client.name .. " never loads the member list while idle")
        ok(t.whispers <= 3, client.name .. " sends at most a greeting per newcomer (" .. t.whispers .. " whispers)")
        ok((t.byKey[ZONE .. " CHANNEL"] or 0) <= 12, client.name .. " broadcasts at most once a minute")
        eq((t.byKey[Q2 .. " WHISPER"] or 0) + (t.byKey[client.FD.C.PREFIX .. " WHISPER"] or 0), 0, client.name .. " idle: no queue or duel traffic")
        eq(t.recipients[passer.fullName], nil, client.name .. " never whispers a visible stranger")
        eq(t.recipients[lurker.fullName], nil, client.name .. " never whispers a channel member without the addon")
        eq(#client.FD.Database.data.matches, 0, client.name .. " has no history change")
        eq(client.FD.Database:GetStats().rating, 1500, client.name .. " has no rating change")
    end
    eq(#passer.received, 0, "a stranger outside the channel receives nothing")
    for _, entry in ipairs(lurker.received) do eq(entry.channel, "CHANNEL", "the channel lurker only sees channel broadcasts") end
    healthy(w, { a, b, c })

    -- S2 ---------------------------------------------------------------------
    -- Surname names as on Forever live, then the realm-qualified form.
    for _, regional in ipairs({ true, false }) do
        scenario = "S2 queue to rated duel at 0.5 s" .. (regional and "" or ", realm names")
        w = newWorld({ whisperLatency = 0.5, partyLatency = 0.5, channelLatency = 0.5, regional = regional })
        a, b = w:client({ mapX = 0.44 }), w:client({ mapX = 0.56 })
        w:venue({ a, b })
        w:advance(10)
        a:command("queue join"); b:command("queue join")
        ok(w:wait(30, function() return a:state() == "TRAVELLING" and b:state() == "TRAVELLING" end), "pairing reaches travel")
        eq(a.invites, 1, "the lower GUID sends one native invitation")
        eq(b.invites, 0, "the invitee never invites")
        eq(b.inviteEvents, 1, "one Blizzard invitation dialog")
        eq(a.FD.queue.ticket.id, b.FD.queue.ticket.id, "one shared ticket")
        eq(a.FD.queue.ticket.plan.deadline, b.FD.queue.ticket.plan.deadline, "one shared travel deadline")
        eq(channels(w:packets(a, Q2, "PLAN")).WHISPER, nil, "PLAN only over PARTY")
        eq(channels(w:packets(b, Q2, "GROUP")).WHISPER, nil, "GROUP only over PARTY")
        eq(channels(w:packets(b, Q2, "PLAN_ACK")).PARTY, true, "PLAN_ACK over PARTY")
        ok(a.waypoint and b.waypoint, "waypoints set on both clients")
        a:walkTo(0.5, 0.3); b:walkTo(0.502, 0.3)
        ok(w:wait(60, function() return a:state() == "READY" and b:state() == "READY" end), "both arrive: READY")
        settle(w, { a, b }, 30)
        eq(b.FD.queue:Challenge(), false, "only the coordinator requests the duel")
        local requests, request = 0, a.FD.Wow.RequestDuel
        a.FD.Wow.RequestDuel = function(...) requests = requests + 1; return request(...) end
        eq(a:requestDuel(), true, "Request duel succeeds")
        eq(requests, 1, "the request goes through FD.Wow:RequestDuel")
        eq(a.requestedUnit, "party1", "native request targets the verified party unit")
        ok(w:wait(5, function() return a:state() == "DUEL" and b:state() == "DUEL" end), "both queues hand over to the duel engine")
        ratedDuel(w, a, b)
        eq(channels(w:packets(a, a.FD.C.PREFIX, "HELLO")).PARTY, true, "duel discovery over PARTY")
        ok(w:wait(30, function() return a:state() == "IDLE" and b:state() == "IDLE" and not a.group and not b.group end),
            "queue match closes and the group is left")
        eq(a.FD.queue.cancel.reason, "FINISHED", "coordinator: queue FINISHED")
        eq(b.FD.queue.cancel.reason, "FINISHED", "invitee: queue FINISHED")
        ok(a.leaves + b.leaves >= 1, "LeaveParty called")
        ok(chain(a):find("SEARCHING>INVITING>GROUPING>PLANNING>TRAVELLING>READY>DUEL>CLEANUP>IDLE", 1, true), "coordinator lifecycle " .. chain(a))
        ok(chain(b):find("SEARCHING>INVITED>GROUPING>TRAVELLING>READY>DUEL>CLEANUP>IDLE", 1, true), "invitee lifecycle " .. chain(b))
        ok(w:traffic(a).whispers <= 20 and w:traffic(b).whispers <= 20, "a whole queue match needs few whispers")
        healthy(w, { a, b })
    end

    -- S3 ---------------------------------------------------------------------
    scenario = "S3 whispers delayed 30 s"
    w = newWorld({ whisperLatency = 30, partyLatency = 0.5, channelLatency = 1 })
    a, b = w:client({ mapX = 0.44 }), w:client({ mapX = 0.56 })
    w:venue({ a, b })
    w:advance(10)
    a:command("queue join"); b:command("queue join")
    local formed = w:wait(120, function() return a:state() == "TRAVELLING" and b:state() == "TRAVELLING" end)
    ok(formed, "the queue still forms through the native invitation and PARTY")
    ok(formed and formed < 75, "within two whisper delays (" .. tostring(formed) .. " s)")
    eq(a.invites, 1, "one native invitation")
    eq(channels(w:packets(a, Q2, "PLAN")).WHISPER, nil, "planning never waits for a whisper")
    a:walkTo(0.5, 0.3); b:walkTo(0.502, 0.3)
    ok(w:wait(60, function() return a:state() == "READY" and b:state() == "READY" end), "READY despite the delay line")
    settle(w, { a, b }, 30)
    eq(a:requestDuel(), true, "the coordinator requests the duel")
    ok(w:wait(5, function() return a:duelState() == "READY" and b:duelState() == "READY" end), "rated discovery over PARTY in seconds")
    ratedDuel(w, a, b)
    ok(w:wait(30, function() return a:state() == "IDLE" and b:state() == "IDLE" and not a.group and not b.group end),
        "the queue match ends")
    -- The solo rated path during the episode: an ordinary /duel on the target.
    local soloAt = w.now
    a.target, b.target = b, a
    a.env.StartDuel("target")
    w:advance(1)
    eq(a:duelState(), "CHECKING_ADDON", "the requester tracks its native request")
    eq(b:duelState(), "CHECKING_ADDON", "the receiver tracks the native request")
    w:advance(9)
    ok(printed(a, "Addon messages to " .. b.fullName .. " are delayed", soloAt), "requester is told messages are delayed")
    ok(printed(b, "Addon messages to " .. a.fullName .. " are delayed", soloAt), "receiver is told messages are delayed")
    w:advance(20)
    eq(a:duelState(), "CHECKING_ADDON", "no rated dialog without the peer's echo")
    ok(w:wait(65, function() return a:duelState() == "IDLE" and b:duelState() == "IDLE" end), "the request ends with its native window")
    w:advance(100) -- every delayed whisper arrives into IDLE
    for _, client in ipairs({ a, b }) do
        eq(client:state(), "IDLE", client.name .. " queue returned to IDLE")
        eq(client:duelState(), "IDLE", client.name .. " duel returned to IDLE")
        eq(#client.FD.Database.data.matches, 1, client.name .. " the solo episode wrote no history")
        ok(lifecycle(client, "peer validation", "stale request") or lifecycle(client, "peer validation", "no pending native request"),
            client.name .. " rejected HELLOs that arrived too late")
    end
    healthy(w, { a, b })

    -- S4 ---------------------------------------------------------------------
    scenario = "S4 three searchers compete for one receiver"
    w = newWorld({ whisperLatency = 2, partyLatency = 0.5, channelLatency = 0.5 })
    -- Level gaps let Alpha, Beta and Gamma pair only with Delta (highest GUID).
    a = w:client({ level = 30, mapX = 0.49 })
    b = w:client({ level = 35, mapX = 0.495 })
    c = w:client({ level = 40, mapX = 0.505 })
    local r = w:client({ level = 35, mapX = 0.51 })
    local all = { a, b, c, r }
    w:venue(all)
    a.FD.queue:Configure({ levelGap = 5 }); b.FD.queue:Configure({ levelGap = 0 })
    c.FD.queue:Configure({ levelGap = 5 }); r.FD.queue:Configure({ levelGap = 5 })
    w:advance(10)
    local joined = {}
    for _, client in ipairs(all) do client:command("queue join"); joined[client] = client.FD.queue.queuedAt end
    local start = w.now
    ok(w:wait(60, function() return r.FD.queue.ticket ~= nil and r.FD.queue.ticket.plan ~= nil end), "the receiver is matched")
    w:advance(120)
    local winner = r.FD.queue.ticket and w:byGUID(r.FD.queue.ticket.peer.guid)
    ok(winner, "one coordinator holds the receiver")
    eq(r.FD.queue.cancel, nil, "the receiver's match is never cancelled")
    local losers = 0
    for _, client in ipairs({ a, b, c }) do
        if client ~= winner then
            local q = client.FD.queue
            eq(q.state, "SEARCHING", client.name .. " searches again")
            eq(q.queuedAt, joined[client], client.name .. " keeps its waiting time")
            eq(q.blocked[r.guid], nil, client.name .. " does not block the receiver")
            eq(q.failures[r.guid], nil, client.name .. " counts no pair failure")
            ok(client.invites <= 1, client.name .. " never re-invites a receiver already taken (" .. client.invites .. ")")
            if q.cancel then
                losers = losers + 1
                ok(q.cancel.reason == "BUSY" or q.cancel.reason == "INVITE_FAILED", client.name .. " lost to an immediate busy notice: "
                    .. q.cancel.reason)
                eq(q.cancel.outcome, "requeue", client.name .. " requeued at once")
            end
            ok(not printed(client, "stopped responding") and not printed(client, "addon error"), client.name .. " sees no technical text")
            local whispers = w:traffic(client).whispers
            ok(whispers <= 0.5 * (w.now - start + 10), client.name .. " searching stays far below the whisper budget (" .. whispers .. ")")
        end
    end
    ok(losers >= 1, "a competing invitation actually lost (" .. losers .. ")")
    eq(#r.FD.Debug:Errors(), 0, "receiver without errors")
    healthy(w, all)

    -- S5 ---------------------------------------------------------------------
    for _, leaver in ipairs({ "invitee", "coordinator" }) do
        scenario = "S5 " .. leaver .. " logs out mid-TRAVELLING"
        w = newWorld({ whisperLatency = 2, partyLatency = 0.5, channelLatency = 0.5 })
        a, b = w:client({ mapX = 0.40 }), w:client({ mapX = 0.60 })
        w:venue({ a, b })
        w:advance(10)
        a:command("queue join"); b:command("queue join")
        ok(w:wait(40, function() return a:state() == "TRAVELLING" and b:state() == "TRAVELLING" end), "both travel")
        a:walkTo(0.5, 0.3, 3); b:walkTo(0.502, 0.3, 3)
        w:advance(5)
        local gone = leaver == "invitee" and b or a
        local stay = gone == a and b or a
        local queuedAt, logoutAt = stay.FD.queue.queuedAt, w.now
        local sentBefore = #stay.sent
        gone:logout()
        local heard = w:wait(5, function() return stay.FD.queue.cancel ~= nil end, 0.1)
        ok(heard and heard <= 1.5, "CANCEL arrives promptly (" .. tostring(heard) .. " s)")
        eq(stay.FD.queue.cancel.reason, "RELOAD", "the reason is the reload/logout")
        eq(stay.FD.queue.cancel.received, true, "shown as the opponent client's reason")
        ok(w:wait(5, function() return stay:state() == "SEARCHING" end, 0.1), "requeued within seconds")
        eq(stay.FD.queue.queuedAt, queuedAt, "the waiting time is preserved")
        eq(stay.FD.queue.blocked[gone.guid], nil, "a logout never blocks the pair")
        w:advance(120)
        eq(stay:state(), "SEARCHING", "still searching")
        eq(stay.group, nil, "the remaining player left the queue group")
        local toGone = 0
        for index = sentBefore + 1, #stay.sent do
            if stay.sent[index].target == gone.fullName then toGone = toGone + 1 end
        end
        ok(toGone <= 2, "the offline player is not whispered again and again (" .. toGone .. ")")
        local late = 0
        for _, record in ipairs(gone.sent) do if record.at > logoutAt then late = late + 1 end end
        eq(late, 0, "nothing is sent after the logout")
        healthy(w, { a, b })
    end

    -- S6 ---------------------------------------------------------------------
    for _, side in ipairs({ "coordinator", "invitee" }) do
        scenario = "S6 Lua error in a duel callback on the " .. side
        w = newWorld({ whisperLatency = 2, partyLatency = 0.5, channelLatency = 0.5 })
        a, b = w:client({ mapX = 0.49 }), w:client({ mapX = 0.51 })
        w:venue({ a, b })
        w:advance(10)
        a:command("queue join"); b:command("queue join")
        ok(w:wait(60, function() return a:state() == "READY" and b:state() == "READY" end), "READY")
        a:walkTo(0.5, 0.3); b:walkTo(0.502, 0.3)
        settle(w, { a, b }, 30)
        local victim = side == "coordinator" and a or b
        local peer = victim == a and b or a
        local injected = false
        -- The duel engine's render callback fails once the peer is proven.
        victim.onRender = function(m)
            if not injected and m and m.state == "READY" then injected = true; error("injected duel callback failure") end
        end
        eq(a:requestDuel(), true, "the coordinator requests the duel")
        ok(w:wait(5, function() return a:state() == "DUEL" and b:state() == "DUEL" end), "both queues in DUEL")
        ok(w:wait(10, function() return injected end), "the failure fired")
        local errors = victim.FD.Debug:Errors()
        eq(#errors, 1, "the error is persisted")
        eq(errors[1] and errors[1].context, "rated duel", "under the rated duel context")
        ok(errors[1] and errors[1].message:find("injected duel callback failure", 1, true), "with its message")
        ok(printed(victim, "Rated flow stopped after an addon error"), "the player is told")
        eq(victim.FD.duel.active, nil, "the victim's rated flow stopped")
        ok(w:wait(3, function() return lifecycle(peer, "cancel received", "error") end), "the peer receives CANCEL(error)")
        ok(printed(peer, "This duel will be UNRATED: Addon error."), "the peer is told why")
        ok(w:wait(10, function() return a:state() ~= "DUEL" and b:state() ~= "DUEL" end), "both queues leave DUEL")
        ok(w:wait(30, function()
            return (a:state() == "IDLE" or a:state() == "SEARCHING" or a:state() == "READY")
                and (b:state() == "IDLE" or b:state() == "SEARCHING" or b:state() == "READY")
        end), "no queue is stuck")
        w:advance(70)
        eq(a:duelState(), "IDLE", "coordinator duel released")
        eq(b:duelState(), "IDLE", "invitee duel released")
        eq(#a.FD.Database.data.matches + #b.FD.Database.data.matches, 0, "an aborted request writes no history")
        healthy(w, { a, b }, { [victim] = 1 })
    end

    -- Regression: a void queue invitation accepted after the match ended. The
    -- invitee leaves the queue while the coordinator's invitation is on its
    -- way; its player still presses Accept in Blizzard's dialog.
    scenario = "void invitation accepted late"
    w = newWorld({ whisperLatency = 2, partyLatency = 0.5, channelLatency = 0.5 })
    a = w:client({ mapX = 0.49 })
    local d = w:client({ mapX = 0.51, acceptDelay = 4 })
    w:venue({ a, d })
    w:advance(10)
    d:command("queue join"); a:command("queue join")
    ok(w:wait(30, function() return a:state() == "INVITING" end, 0.05), "the coordinator invites")
    d:command("queue leave")
    ok(w:wait(10, function() return d.group ~= nil end), "the void invitation was accepted in Blizzard's dialog")
    ok(w:wait(10, function() return a.group == nil and d.group == nil end), "the coordinator leaves the group nobody's match owns")
    w:advance(10)
    eq(a:state(), "SEARCHING", "the coordinator keeps searching instead of pausing for a solo character")
    ok(lifecycle(a, "queue group", "void invitation"), "the leave is recorded")
    healthy(w, { a, d })
end
