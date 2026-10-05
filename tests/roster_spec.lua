return function(_, equal)
    -- Observed Forever channel facts: local channel 6 is display row 9, and
    -- its members become readable only after selecting that row.
    local Harness = assert(loadfile("tests/presence_harness.lua"))()
    local function client(options)
        local c = Harness.client(options)
        c.sendResult = function(packet) return packet.channel == "CHANNEL" and 7 or 0 end
        return c
    end
    local function started(options)
        local c = client(options)
        equal(c:start(), true, "discovery initializes")
        return c
    end
    local function preserved(c, label)
        equal(c.FD.Database.data.player.ratings.LEVELING.rating, 1500, label .. " preserves rating")
        equal(#c.FD.Database.data.matches, 0, label .. " preserves match history")
    end
    local function ourSelections(c)
        local n = 0
        for _, selection in ipairs(c.selections) do if selection.index == c.displayIndex then n = n + 1 end end
        return n
    end
    local function peer(name, guid) return { name = name or "Beta Two", guid = guid or "Player-1-0000BBBB" } end

    -- Joining waits for the default channels.
    local c = started()
    c:advance(1.5)
    equal(#c.joins, 1, "a listed default channel allows the join at once")
    equal(c.joins[1].name, "ForeverDuel", "only the dedicated channel is joined")
    c = started({ defaults = false })
    c:advance(10)
    equal(#c.joins, 0, "no join before the default channels exist")
    equal(c.R.status:find("default chat channels", 1, true) ~= nil, true, "status explains the wait")
    c:emit("CHANNEL_UI_UPDATE")
    c:advance(1)
    equal(#c.joins, 0, "the channel UI is given time to settle")
    c:advance(5)
    equal(#c.joins, 1, "joined a few seconds after the channel UI update")
    c = started({ defaults = false })
    c:advance(16)
    equal(#c.joins, 1, "a fallback delay joins when no channel information exists")
    c = started({ defaults = false, general = 1 })
    c:advance(1.5)
    equal(#c.joins, 1, "the native General channel ID allows the join at once")
    c = client()
    c.env.JoinTemporaryChannel = nil
    local permanent = 0
    c.env.JoinPermanentChannel = function() permanent = permanent + 1 end
    c:start()
    c:advance(120)
    equal(permanent, 0, "the permanent-channel fallback is gone")
    equal(c.R.status:find("unavailable", 1, true) ~= nil, true, "missing temporary join is reported")

    -- Join failures are detected and reported.
    c = started()
    c.preventJoin = true
    c:advance(8)
    equal(c.R.status:find("not in the channel list", 1, true) ~= nil, true, "a join that never lands is reported")
    local status = table.concat(c.FD:StatusLines(), "\n")
    equal(status:find("not in the channel list", 1, true) ~= nil, true, "status lines show the join failure")
    c:advance(60)
    equal(#c.joins, 2, "a missing channel is retried after a minute")
    c.preventJoin = false
    c:advance(60)
    equal(c.joined, true, "a later retry recovers")
    equal(c.R.failure, nil, "a successful join clears the failure")
    for _, case in ipairs({
        { "wrong password", function(t) t:emit("CHAT_MSG_CHANNEL_NOTICE", "WRONG_PASSWORD", "", "", "ForeverDuel", "", "", 0, 0, "ForeverDuel") end, "password" },
        { "banned", function(t) t:emit("CHAT_MSG_CHANNEL_NOTICE", "BANNED", "", "", "ForeverDuel", "", "", 0, 0, "ForeverDuel") end, "banned" },
        { "password request", function(t) t:emit("CHANNEL_PASSWORD_REQUEST", "ForeverDuel") end, "password" },
    }) do
        c = started()
        c.preventJoin = true
        c:advance(1.5)
        case[2](c)
        c:advance(300)
        equal(#c.joins, 1, case[1] .. " stops automatic join attempts")
        equal(c.R.status:find(case[3], 1, true) ~= nil, true, case[1] .. " is reported in status")
    end
    c = started()
    c.preventJoin = true
    c:advance(1.5)
    c:emit("CHAT_MSG_CHANNEL_NOTICE", "WRONG_PASSWORD", "", "", "Secret", "", "", 0, 0, "Secret")
    c:emit("CHANNEL_PASSWORD_REQUEST", "Secret")
    equal(c.R.failure, nil, "another channel's failure notices are ignored")
    c = started()
    c:advance(5)
    equal(c.joined, true, "joined")
    c.R:AddMember("Beta Two", "Player-1-0000BBBB", true)
    c.joined = false
    c:emit("CHAT_MSG_CHANNEL_NOTICE", "YOU_LEFT", "", "", "6. ForeverDuel", "", "", 0, 6, "ForeverDuel")
    equal(c.R:IsMember("Beta Two"), false, "leaving the channel forgets its members")
    c:advance(300)
    equal(#c.joins, 1, "leaving the channel manually is respected")
    equal(c.R.status:find("/join ForeverDuel", 1, true) ~= nil, true, "status explains how to rejoin")
    c.joined = true
    c:advance(5)
    equal(c.R.failure, nil, "a manual rejoin resumes the directory")

    -- Quiet mode never joins.
    c = client()
    c.FD.Database.data.settings.quiet = true
    c:start()
    c:advance(120)
    equal(#c.joins, 0, "quiet mode does not join the channel")

    -- Member list: loaded only on demand, selection restored by identity.
    c = started()
    c.unloadOnDeselect = true
    c.members = { peer() }
    c:advance(30)
    equal(#c.selections, 0, "joining alone never changes the channel selection")
    c.FD.Zone.shown = true
    c:advance(3)
    equal(c.selected, 9, "an open zone window requests display row 9, not local channel 6")
    c:advance(4)
    equal(c.selected, 1, "the previous selection is restored after the roster arrives")
    equal(c.R:IsMember("Beta Two"), true, "the roster read records members")
    for _, read in ipairs(c.reads) do equal(read.index, 9, "only the addon-owned display roster is read") end
    c:advance(50)
    equal(ourSelections(c), 1, "the roster is refreshed at most once a minute")
    c:advance(15)
    equal(ourSelections(c), 2, "an open zone window refreshes the roster every minute")
    c.FD.Zone.shown = false
    c:advance(300)
    equal(ourSelections(c), 2, "a closed zone window stops roster refreshes")
    preserved(c, "roster refresh")

    -- A cached roster needs no selection change at all.
    c = started()
    c.members = { peer() }
    c:advance(5)
    c.loaded = true
    c.FD.Zone.shown = true
    c:advance(5)
    equal(#c.selections, 0, "an already loaded roster is read without touching the selection")
    equal(c.R:IsMember("Beta Two"), true, "members are read from the cached roster")

    -- The Channels window owns the selection.
    c = started()
    c.members = { peer() }
    c.shown = true
    c.FD.Zone.shown = true
    c:advance(30)
    equal(#c.selections, 0, "a visible Channels window is never commandeered")
    c.shown = false
    c:advance(5)
    equal(ourSelections(c), 1, "the request starts once the window closes")
    -- The window opening mid-request restores the selection immediately.
    c = started()
    c.members = { peer() }
    c.rosterDelay = 4
    c:advance(5)
    c.FD.Zone.shown = true
    c:advance(1.5)
    equal(c.selected, 9, "request pending")
    c.shown = true
    c.channelHooks.OnShow()
    equal(c.selected, 1, "opening the Channels window restores the user's selection at once")
    equal(c.R.pending, nil, "the pending request ends")
    -- Without a hookable frame the next Tick restores it.
    c = started()
    c.env.ChannelFrame.HookScript = nil
    c.members = { peer() }
    c.rosterDelay = 4
    c:advance(5)
    c.FD.Zone.shown = true
    c:advance(1.5)
    c.shown = true
    c:advance(5)
    equal(c.selected, 1, "a visible window found by Tick also restores the selection")
    -- A selection the user changed is never overwritten.
    c = started()
    c.members = { peer() }
    c.rosterDelay = 4
    c:advance(5)
    c.FD.Zone.shown = true
    c:advance(1.5)
    c.selected = 4
    c:advance(10)
    equal(c.selected, 4, "the user's own selection during a request is kept")
    -- A roster that never loads times out and restores the selection.
    c = started()
    c.members = { peer() }
    c.neverLoads = true
    c:advance(5)
    c.FD.Zone.shown = true
    c:advance(10)
    equal(c.selected, 1, "the roster load timeout restores the previous selection")
    equal(ourSelections(c), 1, "a timed-out roster is not reselected on every Tick")
    -- Renumbered channels are resolved by name and local ID.
    c = started()
    c.members = { peer() }
    c:advance(5)
    c.channelID, c.displayIndex = 3, 7
    c.FD.Zone.shown = true
    c:advance(8)
    equal(c.selections[1].index, 7, "a renumbered channel uses its new display row")
    equal(c.selected, 1, "the previous selection is restored after renumbering")
    -- World transitions restore a pending selection.
    c = started()
    c.members = { peer() }
    c.rosterDelay = 4
    c:advance(5)
    c.FD.Zone.shown = true
    c:advance(1.5)
    c:emit("PLAYER_LEAVING_WORLD")
    equal(c.selected, 1, "leaving the world restores the selection")

    -- Without SetSelectedDisplayChannel the roster cannot be requested.
    c = client()
    c.env.SetSelectedDisplayChannel = nil
    c.members = { peer() }
    c:start()
    c.FD.Zone.shown = true
    c:advance(30)
    equal(#c.selections, 0, "SetSelectedDisplayChannel missing cannot request the roster")
    preserved(c, "SetSelectedDisplayChannel unavailable")
    -- Without GetSelectedDisplayChannel (and no selected button in a hidden
    -- Channels window) the selection is unknown: the roster is still loaded,
    -- and nothing is restored.
    c = client()
    c.env.GetSelectedDisplayChannel = nil
    c.members = { peer() }
    c:start()
    c.FD.Zone.shown = true
    c:advance(30)
    equal(ourSelections(c), 1, "an unknown selection still loads the roster once a minute at most")
    equal(c.R:IsMember("Beta Two"), true, "and reads its members")
    equal(#c.selections, 1, "nothing is restored when the previous selection was unknown")
    preserved(c, "GetSelectedDisplayChannel unavailable")
    c = client()
    c.env.C_ChatInfo.GetChannelRosterInfo = nil
    c:start()
    c.FD.Zone.shown = true
    c:advance(30)
    equal(#c.selections, 0, "a missing roster API does not change the selection")
    c = client()
    c.env.GetSelectedDisplayChannel = nil
    c.env.ChannelFrame.GetList = function()
        return { GetSelectedChannelIDAndSupportsText = function() return c.selected, true end }
    end
    c.members = { peer() }
    c:start()
    c.FD.Zone.shown = true
    c:advance(10)
    equal(c.R:IsMember("Beta Two"), true, "the native channel list supplies a restorable selection")
    equal(c.selected, 1, "the channel-list selection is restored")
    -- An unreadable or restricted selection counts as unknown: with the
    -- Channels window hidden the roster is loaded and nothing is restored.
    for _, selection in ipairs({ false, "1", -1, 0.5, "secret" }) do
        c = started()
        c.selected = selection == "secret" and c.secret or selection
        c.FD.Zone.shown = true
        c:advance(10)
        equal(ourSelections(c), 1, "an unknown selection still loads the roster once")
        equal(#c.selections, 1, "and is never restored to an unknown value")
    end
    c = started()
    c.selected = 2
    local display = c.env.GetChannelDisplayInfo
    c.env.GetChannelDisplayInfo = function(index)
        if index == 2 then return nil end
        return display(index)
    end
    c.FD.Zone.shown = true
    c:advance(10)
    equal(#c.selections, 0, "missing previous row metadata prevents an unrestorable request")
    c = started()
    c.members = { peer() }
    c:advance(5)
    c.FD.Zone.shown = true
    c.failRoster = true
    c:advance(10)
    equal(c.selected, 1, "throwing roster reads still restore the selection")
    equal(c.R.pending, nil, "throwing roster reads release the pending request")
    preserved(c, "roster failure")

    -- Membership from roster rows and channel events.
    c = started()
    c.members = { peer("Alpha One", c.player.guid), peer(), peer(),
        peer("Unknown", "Creature-1-CCCC"), peer("Malformed", "Player-1-XYZ"),
        { name = "Missing GUID" }, peer("", "Player-1-0000CCCC"), peer("Bad|Name", "Player-1-0000DDDD"),
        peer("Bad\nName", "Player-1-0000EEEE"), peer(string.rep("x", 129), "Player-1-0000FFFF"),
        peer(c.secret, "Player-1-0000ABCD"), peer("Restricted GUID", c.secret) }
    c:advance(5)
    c.FD.Zone.shown = true
    c:advance(10)
    equal(c.R.memberCount, 1, "self, duplicates and malformed or restricted rows are skipped")
    equal(c.R:IsMember("Beta Two"), true, "the valid row survives malformed neighbors")
    c:emit("CHAT_MSG_CHANNEL_JOIN", "", "Gamma Three", "", "", "", "", 0, 2, "General", 0, 0, "Player-1-0000C0C0")
    equal(c.R:IsMember("Gamma Three"), false, "joins of ordinary channels are ignored")
    c:emit("CHAT_MSG_CHANNEL_JOIN", "", "Gamma Three", "", "", "", "", 0, 6, "ForeverDuel", 0, 0, "Player-1-0000C0C0")
    equal(c.R:IsMember("Gamma Three"), true, "a new member of our channel is recorded")
    c:emit("CHAT_MSG_CHANNEL_LEAVE", "", "Gamma Three", "", "", "", "", 0, 6, "ForeverDuel", 0, 0, "Player-1-0000C0C0")
    equal(c.R:IsMember("Gamma Three"), false, "a member who leaves is removed")
    for i = 1, 320 do c.R:AddMember("Member" .. i .. " Crowd", string.format("Player-1-%08X", 0x5000 + i)) end
    equal(c.R.memberCount, 300, "the member list is bounded")
    equal(c.R:IsMember("Member320 Crowd"), true, "at the cap a new member replaces the longest-unconfirmed one")
    c:advance(1)
    c.R:AddMember("Member5 Crowd", string.format("Player-1-%08X", 0x5005))
    c:advance(1)
    c.R:AddMember("Newest Crowd", "Player-1-0000F00F")
    equal(c.R:IsMember("Member5 Crowd") and c.R:IsMember("Newest Crowd"), true, "a reconfirmed member is not evicted")
    equal(c.R.memberCount, 300, "the bound holds")
    c = started({ regionalNames = false })
    c:advance(5)
    c:emit("CHAT_MSG_CHANNEL_JOIN", "", "Gamma", "", "", "", "", 0, 6, "ForeverDuel", 0, 0, "Player-1-0000C0C0")
    equal(c.R:IsMember("Gamma-Forever"), true, "realm-local member names are canonicalized")

    -- Churn: a fully readable roster is authoritative, so members who left
    -- without a leave event drop out and current members always fit.
    c = started()
    c:advance(5)
    c.loaded = true
    local function crowd(base)
        c.members = {}
        for i = 1, 150 do
            local identity = Harness.identity(base + i)
            c.members[i] = { name = Harness.fullName(identity, true), guid = identity.guid }
        end
        c:emit("CHANNEL_COUNT_UPDATE", 9, 150)
        c:advance(3)
    end
    crowd(0)
    equal(c.R.memberCount, 150, "a full read lists the channel")
    crowd(200)
    equal(c.R.memberCount, 150, "members who left without a leave event drop out at the next full read")
    equal(c.R:IsMember("Peer1 Crowd"), false, "a former member is no longer trusted")
    crowd(400)
    equal(c.R:IsMember("Peer550 Crowd"), true, "a current member is always known")
    c:receive("FDQ2|" .. Harness.identity(550).guid .. "|1500|37|ROGUE|30|60", "Peer550 Crowd")
    c:advance(5)
    local answered = 0
    for _, packet in ipairs(c:whispers("FDP2")) do if packet.target == "Peer550 Crowd" then answered = answered + 1 end end
    equal(answered, 1, "the current member's query is answered")
    equal(#c.selections, 0, "client roster updates need no selection change")
    -- A join the client roster does not list yet survives one read.
    c:emit("CHAT_MSG_CHANNEL_JOIN", "", "Fresh Joiner", "", "", "", "", 0, 6, "ForeverDuel", 0, 0, "Player-1-0000F00D")
    c:emit("CHANNEL_COUNT_UPDATE", 9, 150)
    c:advance(3)
    equal(c.R:IsMember("Fresh Joiner"), true, "a recent join event outlives a lagging roster read")
    c:advance(20)
    c:emit("CHANNEL_COUNT_UPDATE", 9, 150)
    c:advance(3)
    equal(c.R:IsMember("Fresh Joiner"), false, "a later read that still omits the joiner removes it")
    -- An unreadable roster proves nothing and removes nobody.
    c.loaded = false
    c:emit("CHANNEL_COUNT_UPDATE", 9, 151)
    c:advance(3)
    equal(c.R.memberCount, 150, "an unreadable roster removes nobody")
    -- Losing the channel forgets every member.
    c.joined = false
    c.preventJoin = true
    c:advance(6)
    equal(c.R.memberCount, 0, "a vanished channel forgets its members")
    equal(c.R:IsMember("Peer550 Crowd"), false, "nobody stays trusted without the channel")

    -- Live 0.6.0: a client whose Channels window was never opened reports no
    -- selection and has no ChannelFrame. Refusing then left discovery without
    -- members; the list is now loaded and nothing is restored afterwards.
    c = started()
    c.env.ChannelFrame = nil
    c.selected = nil
    c.members = { peer() }
    c:advance(30)
    c.FD.Zone.shown = true
    c:advance(8)
    equal(ourSelections(c), 1, "the member list is requested without a known previous selection")
    equal(c.R:IsMember("Beta Two"), true, "and its members are read")
    equal(#c.selections, 1, "no restore is attempted when no selection was known")
    equal(c.R.problem, nil, "no 'cannot be loaded safely' problem remains")
    -- Live 0.6.0 retest: the Channels frame was loaded but never shown, so
    -- it had no selected button either. A hidden window re-selects its own
    -- button when it updates; the list is loaded the same way.
    c = started()
    c.selected = nil
    c.members = { peer() }
    c:advance(30)
    c.FD.Zone.shown = true
    c:advance(8)
    equal(ourSelections(c), 1, "a loaded but hidden Channels frame without a selection does not block the list")
    equal(c.R:IsMember("Beta Two"), true, "its members are read")
    equal(#c.selections, 1, "and no restore is attempted")
    -- While the Channels window is shown, nothing is ever selected.
    c = started()
    c.selected = nil
    c.shown = true
    c.members = { peer() }
    c:advance(30)
    c.FD.Zone.shown = true
    c:advance(8)
    equal(#c.selections, 0, "an open Channels window keeps its own selection")

    -- A chat line in our channel proves membership without a member list;
    -- lines in other channels are ignored.
    c = started()
    c.neverLoads = true
    c:advance(30)
    c:emit("CHAT_MSG_CHANNEL", "hey", "Tester B", "", "6. ForeverDuel", "", "", 0, 6, "ForeverDuel", 0, 1, "Player-1-0000B0B0")
    equal(c.R:IsMember("Tester B"), true, "a speaker in the ForeverDuel channel is a member")
    c:emit("CHAT_MSG_CHANNEL", "wts", "Trader Joe", "", "2. Trade", "", "", 2, 2, "Trade", 0, 2, "Player-1-0000C0C0")
    equal(c.R:IsMember("Trader Joe"), false, "speakers in other channels are not")
end
