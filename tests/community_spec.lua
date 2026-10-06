return function(FD, equal)
    -- Community directory (ForeverDuel/Community.lua) against a mocked,
    -- read-only C_Club, and its use by Presence across simulated clients
    -- whose ForeverDuel channel never connects (live 0.6.0: different
    -- internal servers of the Forever mega-realm).
    local Harness = assert(loadfile("tests/presence_harness.lua"))()
    local UNKNOWN, ONLINE, MOBILE, OFFLINE, AWAY, BUSY = 0, 1, 2, 3, 4, 5
    local HORDE, ALLIANCE = 0, 1
    local function printed(c, pattern)
        for _, line in ipairs(c.prints) do if line:find(pattern, 1, true) then return true end end
        return false
    end
    local function status(c) return table.concat(c.FD.Community:Status(), "\n") end
    local function has(text, pattern) return text:find(pattern, 1, true) ~= nil end
    local function member(index, fields)
        local identity = Harness.identity(index)
        local record = { name = Harness.fullName(identity, true), guid = identity.guid, presence = ONLINE,
            zone = "Elwynn Forest", faction = ALLIANCE, level = 30, classID = 4 }
        for key, value in pairs(fields or {}) do record[key] = value end
        return record
    end
    local function own(c, fields)
        local record = { name = c.fullName, guid = c.player.guid, presence = ONLINE, zone = c.zoneText,
            faction = ALLIANCE, level = 30, classID = 8 }
        for key, value in pairs(fields or {}) do record[key] = value end
        return record
    end
    local function directory(members, fields)
        local club = { clubId = 900, name = "ForeverDuelersGuild", clubType = 1, members = members or {} }
        for key, value in pairs(fields or {}) do club[key] = value end
        return club
    end
    local function started(options)
        local c = Harness.client(options)
        equal(c:start(), true, "discovery initializes")
        c:advance(2)
        return c
    end
    local function whispersTo(c, name, tag)
        local n = 0
        for _, packet in ipairs(c.sent) do
            if packet.channel == "WHISPER" and packet.target == name and (not tag or packet.payload:sub(1, #tag) == tag) then n = n + 1 end
        end
        return n
    end
    local function names(list)
        local result = {}
        for _, entry in ipairs(list) do result[#result + 1] = entry.name or entry.fullName end
        return table.concat(result, ",")
    end

    -- The module only reads C_Club; nothing in it sends or writes.
    local source = assert(io.open("ForeverDuel/Community.lua", "r")):read("*a")
    equal(source:find("SendAddonMessage", 1, true), nil, "the directory sends no addon message")
    equal(source:find("Outbound", 1, true), nil, "the directory never queues traffic")
    equal(source:find("SendChatMessage", 1, true), nil, "the directory sends no chat")

    -- Missing APIs: no C_Club at all, or one without the member functions.
    local c = started()
    equal(c.FD.Community.state, "unsupported", "a client without C_Club has no directory")
    equal(c.FD.Community:Ready(), false, "nothing is ready without C_Club")
    equal(has(status(c), "Community: not available on this client."), true, "status explains a missing API")
    equal(has(table.concat(c.FD:StatusLines(), "\n"), "Community: not available"), true, "/duelrating status shows the directory")
    c = Harness.client({ clubs = { directory({ member(1) }) } })
    c.env.C_Club.GetClubMembers = nil
    c:start(); c:advance(2)
    equal(c.FD.Community.state, "unsupported", "a C_Club without member functions is not used")
    c = Harness.client({ clubs = { directory({ member(1), member(2) }) } })
    c.failMemberInfo = true
    c:start(); c:advance(2)
    equal(c.FD.Community.state, "ok", "a failing GetMemberInfo does not break the directory")
    equal(c.FD.Community:IsMember(member(1).name), false, "an unreadable member is not cached")
    equal(has(status(c), "2 member names could not be resolved"), true, "failed member reads are counted")
    equal(c.calls.FocusMembers, nil, "an idle client does not request the member list")

    -- Clubs initialized late: nothing is returned before the initial load;
    -- the INITIAL_CLUBS_LOADED event only marks the cache dirty.
    local club = directory({ member(1), member(2, { presence = OFFLINE }) })
    c = Harness.client({ clubs = { club }, clubsReady = false })
    c:start(); c:advance(5)
    equal(c.FD.Community.state, "loading", "uninitialized clubs report loading")
    equal(has(status(c), "waiting for the game to load your communities"), true, "status explains the wait")
    equal(c.FD.Community:IsMember(member(1).name), false, "no member before the initial load")
    c.clubsReady = true
    c:emit("INITIAL_CLUBS_LOADED")
    c:advance(10)
    equal(c.FD.Community:Ready(), true, "the directory is ready after the initial load")
    equal(c.FD.Community:IsMember(member(1).name), true, "members are cached")
    equal(c.FD.Community:IsMember(member(2).name), true, "offline members are cached too")
    equal(names(c.FD.Community:Online()), member(1).name, "only online members are listed online")
    equal(has(status(c), "Community: ForeverDuelersGuild | 2 members, 1 online, 1 in your zone"), true, "status counts members")
    equal(c.P:Trust(member(2).name), "member", "a community member is trusted like a channel member")
    -- A client whose clubs were loaded before it started (a /reload)
    -- builds at once from IsEnabled answering.
    c = started({ clubs = { directory({ member(1) }) } })
    equal(c.FD.Community:Ready(), true, "initialized clubs are read on the first tick")

    -- Several clubs and name casing: only character communities, the name
    -- ignoring case, the lowest club ID when several match.
    c = started({ clubs = {
        directory({ member(1) }, { clubId = 5, name = "Other Club" }),
        directory({ member(2) }, { clubId = 30, name = "foreverduelersguild" }),
        directory({ member(3) }, { clubId = 20, name = "FOREVERDUELERSGUILD" }),
        directory({ member(4) }, { clubId = 10, name = "ForeverDuelersGuild", clubType = 2 }),
        directory({ member(5) }, { clubId = 1, name = "ForeverDuelersGuild", clubType = 0 }),
    } })
    equal(c.FD.Community.clubId, 20, "the character community with the lowest ID is used")
    equal(names(c.FD.Community:Members()), member(3).name, "only its members are cached")
    equal(has(status(c), "2 communities are named ForeverDuelersGuild"), true, "the ambiguity is reported")
    c = started({ clubs = { directory({ member(4) }, { clubType = 2 }) } })
    equal(c.FD.Community.state, "type", "a guild with the name is never used")
    equal(has(status(c), "is not a character community"), true, "status names the wrong type")
    c = started({ clubs = { directory({ member(1) }, { name = "Somebody else" }) } })
    equal(c.FD.Community.state, "missing", "no community with the name")
    equal(has(status(c), "you are not a member of a community named ForeverDuelersGuild"), true, "status explains how to fix it")
    c.clubs[#c.clubs + 1] = directory({ member(6) }, { clubId = 901 })
    c:emit("CLUB_ADDED", 901)
    c:advance(10)
    equal(c.FD.Community:IsMember(member(6).name), true, "joining the community later is picked up")
    for _, state in ipairs({ { "clubsEnabled", false, "disabled" }, { "clubRestriction", 1, "restricted" } }) do
        c = Harness.client({ clubs = { directory({ member(1) }) } })
        c[state[1]] = state[2]
        c:start(); c:advance(2)
        if state[3] == "disabled" then
            -- Without INITIAL_CLUBS_LOADED (a /reload) one refusal could be
            -- the uninitialized answer: believed when the next read repeats it.
            equal(c.FD.Community.state, "loading", "a first refusal before the load event is not believed")
            c:advance(10)
        end
        equal(c.FD.Community.state, state[3], "status " .. state[3])
        equal(c.FD.Community:IsMember(member(1).name), false, state[3] .. " communities are not read")
    end
    c:advance(120)
    equal(c.FD.Community.state, "restricted", "a confirmed state stays")

    -- Before the initial load the client may answer IsEnabled with false or
    -- an error instead of nothing (the docs give no FailureMode): that is
    -- loading, never a persisted "disabled" or "unsupported".
    for _, answer in ipairs({ "false", "error" }) do
        c = Harness.client({ clubs = { directory({ member(1) }) }, clubsReady = false })
        c.preInit = answer
        c:start(); c:advance(3)
        equal(c.FD.Community.state, "loading", "pre-init " .. answer .. " is reported as loading")
        equal(has(status(c), "waiting for the game to load your communities"), true, "pre-init " .. answer .. " status")
        c.clubsReady = true
        c:emit("INITIAL_CLUBS_LOADED")
        c:advance(12)
        equal(c.FD.Community.state, "ok", "pre-init " .. answer .. " recovers after the load event")
        for _, entry in ipairs(c:trace("transport")) do
            equal(entry.detail:find("disabled", 1, true) or entry.detail:find("unsupported", 1, true), nil,
                "pre-init " .. answer .. " persists no refusal")
        end
    end
    -- After the load event a refusal is believed at once.
    c = Harness.client({ clubs = { directory({ member(1) }) }, clubsReady = false })
    c:start(); c:advance(3)
    c.clubsReady, c.clubsEnabled = true, false
    c:emit("INITIAL_CLUBS_LOADED")
    c:advance(10)
    equal(c.FD.Community.state, "disabled", "a refusal after the load event is believed")

    -- Presence: Online, Away and Busy are reachable; mobile, offline and
    -- unknown are not. Events only mark the cache dirty. While discovery is
    -- idle, presence and member updates wait for the minute refresh; while it
    -- is active one rebuild runs at most every 10 seconds.
    club = directory({ member(1), member(2, { presence = AWAY }), member(3, { presence = BUSY }),
        member(4, { presence = MOBILE }), member(5, { presence = OFFLINE }), member(6, { presence = UNKNOWN }) })
    c = started({ clubs = { club } })
    equal(names(c.FD.Community:Online()), table.concat({ member(1).name, member(2).name, member(3).name }, ","),
        "online, away and busy members are reachable")
    local reads = c.calls.GetSubscribedClubs
    club.members[1].presence = OFFLINE
    club.members[5].presence = ONLINE
    for _ = 1, 50 do c:emit("CLUB_MEMBER_PRESENCE_UPDATED", 900, 1, OFFLINE); c:advance(0.2) end
    c:advance(30)
    equal(c.calls.GetSubscribedClubs, reads, "an idle client does not rebuild for presence events")
    c:advance(25)
    equal(names(c.FD.Community:Online()), table.concat({ member(2).name, member(3).name, member(5).name }, ","),
        "the minute refresh applies presence changes while idle")
    c.FD.Zone.shown = true
    c.P:Changed()
    c:advance(1)
    reads = c.calls.GetSubscribedClubs
    club.members[1].presence = ONLINE
    for _ = 1, 50 do c:emit("CLUB_MEMBER_PRESENCE_UPDATED", 900, 1, ONLINE); c:advance(0.2) end
    equal(c.calls.GetSubscribedClubs - reads <= 2, true, "a burst of presence events causes at most one rebuild per 10 s")
    c:advance(10)
    equal(names(c.FD.Community:Online()), table.concat({ member(1).name, member(2).name, member(3).name, member(5).name }, ","),
        "presence changes are applied after the rebuild while discovery is active")
    c.FD.Zone.shown = false
    c:advance(20)
    reads = c.calls.GetSubscribedClubs
    c:emit("CLUB_MEMBER_PRESENCE_UPDATED", 777, 1, OFFLINE)
    equal(c.FD.Community.dirty, false, "another club's member events are ignored")
    c:advance(30)
    equal(c.calls.GetSubscribedClubs, reads, "no rebuild without an event inside the refresh interval")
    c:advance(35)
    equal(c.calls.GetSubscribedClubs, reads + 1, "the cache is refreshed every minute regardless")
    -- Members added and removed.
    club.members[#club.members + 1] = member(7)
    table.remove(club.members, 2)
    c:emit("CLUB_MEMBER_ADDED", 900, 7)
    c:emit("CLUB_MEMBER_REMOVED", 900, 2)
    c:advance(10)
    equal(c.FD.Community:IsMember(member(7).name), true, "an added member is cached")
    equal(c.FD.Community:IsMember(member(2).name), false, "a removed member is dropped")

    -- Names: the whisper address is the member name unchanged, as the
    -- Communities window whispers it, a possible server suffix included;
    -- Kstrings, invalid GUIDs, duplicates and the own entry are skipped.
    c = Harness.client({ clubs = { directory() } })
    c.clubs[1].members = { own(c), member(1), member(2, { name = "|Kq123|k" }), member(3, { name = "Peer3 Crowd-4619" }),
        member(4, { guid = "Creature-0-1" }), member(5, { name = "" }), member(6, { name = member(1).name, guid = Harness.identity(99).guid }) }
    c:start(); c:advance(2)
    equal(names(c.FD.Community:Members()), member(1).name .. ",Peer3 Crowd-4619", "resolvable members are cached")
    equal(c.FD.Community:IsMember("Peer3 Crowd-4619"), true, "a name with '-' is kept unchanged on a surname client")
    equal(c.FD.Community:IsMember(c.fullName), false, "the own character is skipped")
    equal(c.FD.Community.total, 6, "the member count excludes the own character")
    equal(has(status(c), "4 member names could not be resolved and are skipped"), true, "skipped names are counted")
    local cached = c.FD.Community:Members()[1]
    equal(cached.guid .. "|" .. cached.zone .. "|" .. cached.faction .. "|" .. cached.level .. "|" .. cached.classID,
        member(1).guid .. "|Elwynn Forest|Alliance|30|4", "the member record keeps GUID, zone, faction, level and class")
    -- A profile whose GUID belongs to a member but whose sender differs means
    -- the member name is not the whisper address: counted, never trusted.
    c:receive(c:profile(Harness.identity(1)), member(1).name)
    equal(c.FD.Community.mismatches, 0, "a member answering under its own name is no mismatch")
    c:inject(c:profile(Harness.identity(1)), "Peer1 Elsewhere")
    equal(c.FD.Community.mismatches, 1, "another sender with a member's GUID is counted")
    equal(has(status(c), "1 profiles came from a name other than the member list shows"), true, "status asks for a report")
    equal(c.P:Trust("Peer1 Elsewhere"), nil, "the GUID claim does not make the sender trusted")
    c:inject(c:profile(Harness.identity(77)), "Peer77 Crowd")
    equal(c.FD.Community.mismatches, 1, "a non-member is not counted")
    -- A client with realm suffixes completes same-realm names like Presence.
    c = Harness.client({ regionalNames = false, clubs = { directory({ member(1, { name = "Beta" }), member(2, { name = "Gamma-Other" }) }) } })
    c:start(); c:advance(2)
    equal(names(c.FD.Community:Members()), "Beta-Forever,Gamma-Other", "names use the Presence cache keys")

    -- Secret values: a hidden member or a secret name is skipped, a secret
    -- zone only loses the zone; a secret list (chat lockdown) keeps the last
    -- readable list in use.
    club = directory({ member(1), member(2, { hidden = true }), member(3, { secret = { "name" } }), member(4, { secret = { "zone", "level" } }) })
    c = started({ clubs = { club } })
    equal(names(c.FD.Community:Members()), member(1).name .. "," .. member(4).name, "secret members are skipped")
    equal(c.FD.Community:Members()[2].zone, nil, "a secret zone is dropped")
    equal(c.FD.Community:Members()[2].level, nil, "a secret level is dropped")
    equal(has(status(c), "2 member names could not be resolved"), true, "secret members are counted")
    c.clubLockdown = true
    club.members[1].presence = OFFLINE
    c:emit("CLUB_MEMBERS_UPDATED", 900)
    c:advance(10)
    equal(c.FD.Community.state, "locked", "a secret list is reported as lockdown")
    equal(c.FD.Community:IsMember(member(1).name), true, "the last readable list stays in use")
    equal(c.FD.Community:Ready(), true, "the directory stays usable")
    equal(has(status(c), "protected right now (chat lockdown); using the last readable list"), true, "status explains the lockdown")
    c.clubLockdown = false
    c:emit("CLUB_MEMBERS_UPDATED", 900)
    c:advance(10)
    equal(c.FD.Community.state, "ok", "the list is read again after the lockdown")
    equal(#c.FD.Community:Online(), 1, "and reflects changes made meanwhile")
    c = Harness.client({ clubs = { directory({ member(1) }) } })
    c.clubLockdown = true
    c:start(); c:advance(2)
    equal(c.FD.Community:Ready(), false, "a lockdown before the first read leaves the directory empty")
    equal(has(status(c), "chat lockdown); retrying"), true, "status says it retries")

    -- Bounded cache.
    local many = {}
    for i = 1, 1200 do many[i] = member(i) end
    c = started({ clubs = { directory(many) } })
    equal(#c.FD.Community:Members(), 1000, "at most 1000 members are cached")
    equal(c.calls.GetMemberInfo, 1000, "at most 1000 members are read per rebuild")
    equal(has(status(c), "only the first 1000 of 1200 members are read"), true, "status reports the bound")

    -- Filters: own faction (a member without faction counts only in a
    -- single-faction community), zone names ignoring case; copies only.
    club = directory({ member(1), member(2, { faction = HORDE }), member(3, { faction = false }),
        member(4, { zone = "Westfall" }), member(5, { zone = "ELWYNN FOREST" }) })
    c = started({ clubs = { club } })
    equal(names(c.FD.Community:Online({ sameFaction = true })),
        table.concat({ member(1).name, member(3).name, member(4).name, member(5).name }, ","), "same faction, unknown counts in a single-faction community")
    equal(names(c.FD.Community:Online({ sameFaction = true, zone = "elwynn forest" })),
        table.concat({ member(1).name, member(3).name, member(5).name }, ","), "zone filter ignores case")
    equal(names(c.FD.Community:Online({ zone = { "Duskwood", "Westfall" } })), member(4).name, "several zone names")
    club.crossFaction = true
    c:emit("CLUB_UPDATED", 900)
    c:advance(10)
    equal(has(names(c.FD.Community:Online({ sameFaction = true })), member(3).name), false,
        "a member without faction is not assumed friendly in a cross-faction community")
    c.FD.Community:Members()[1].name = "changed"
    equal(c.FD.Community:IsMember(member(1).name), true, "Members returns copies")
    c.mapNames = { [37] = "Elwynn" }
    c.zoneText = "Goldshire"
    equal(#c.FD.Community:Online({ zone = c.FD.Community:OwnZones() }), 0, "neither zone text matches")
    club.members[1].zone = "Elwynn"
    c:emit("CLUB_MEMBER_UPDATED", 900, 1)
    c:advance(60) -- Idle: member info changes wait for the minute refresh.
    equal(names(c.FD.Community:Online({ zone = c.FD.Community:OwnZones() })), member(1).name, "the map name matches too")

    -- Command: status and how to join; name validation; on/off; persisted.
    c = started({ clubs = { directory({ member(1) }, { name = "Duelists" }) } })
    c:command("community")
    equal(printed(c, "you are not a member of a community named ForeverDuelersGuild"), true, "the command shows the status")
    equal(printed(c, "Join the in-game community ForeverDuelersGuild"), true, "and how to join")
    c:command("community Duelists")
    equal(c.FD.Database.data.settings.communityName, "Duelists", "the name is saved")
    equal(c.FD.Community:IsMember(member(1).name), true, "the new name applies at once")
    equal(printed(c, "Community: Duelists | 1 members, 1 online, 1 in your zone"), true, "and its status is shown")
    local before = #c.prints
    c:command("community " .. string.rep("x", 49))
    c:command("community Bad|cffName")
    equal(c.FD.Database.data.settings.communityName, "Duelists", "invalid names are refused")
    equal(#c.prints - before, 2, "each refusal is explained")
    equal(printed(c, "A community name has 1 to 48 characters"), true, "the refusal names the rule")
    c:command("community " .. string.rep("\195\164", 48))
    equal(c.FD.Database.data.settings.communityName, string.rep("\195\164", 48), "48 characters are counted, not bytes")
    c:command("community duelists")
    c:command("community off")
    equal(c.FD.Database.data.settings.communityOff, true, "off is saved")
    equal(c.FD.Community:IsMember(member(1).name), false, "off drops the members")
    equal(has(status(c), "Community: off"), true, "status shows off")
    reads = c.calls.GetSubscribedClubs
    c:advance(120)
    equal(c.calls.GetSubscribedClubs, reads, "nothing is read while off")
    c:command("community on")
    equal(c.FD.Database.data.settings.communityOff, nil, "on is saved")
    equal(c.FD.Community:IsMember(member(1).name), true, "on uses the saved name again")
    c.FD.Database.data.settings.communityName = "bad|name"
    equal(c.FD.Community:Name(), "ForeverDuelersGuild", "an invalid saved name falls back to the default")

    -- FocusMembers: only while discovery needs an unloaded list, at most once
    -- a minute, never in quiet mode, never while idle.
    club = directory({ member(1) })
    c = Harness.client({ clubs = { club } })
    c.membersReady = false
    club.members = {}
    c:start(); c:advance(30)
    equal(c.calls.FocusMembers, nil, "an idle client does not load the member list")
    equal(has(status(c), "loading the member list"), true, "status says the list is loading")
    c:command("quiet")
    c.FD.Zone.shown = true
    c:advance(60)
    equal(c.calls.FocusMembers, nil, "quiet mode requests nothing")
    c:command("quiet")
    c:advance(5)
    equal(c.calls.FocusMembers, 1, "an open zone window requests the member list")
    c.membersReady = false
    c:emit("CLUB_MEMBERS_UPDATED", 900)
    c:advance(15)
    equal(c.calls.FocusMembers, 1, "at most one request a minute")
    club.members = { member(1) }
    c:emit("CLUB_MEMBERS_UPDATED", 900)
    c:advance(10)
    equal(c.FD.Community:IsMember(member(1).name), true, "the loaded list is read")

    -- The command is a demand: a joined player whose list is not loaded on
    -- an idle client gets one FocusMembers and is told to try again, not to
    -- join. The join hint is only for a missing community.
    club = directory({})
    c = Harness.client({ clubs = { club } })
    c.membersReady = false
    c:start(); c:advance(120)
    equal(c.calls.FocusMembers, nil, "idle: no member list request")
    c:command("community")
    equal(c.calls.FocusMembers, 1, "the command requests the member list")
    equal(printed(c, "type /duelrating community again in a few seconds"), true, "the command says to try again")
    equal(printed(c, "Join the in-game community"), false, "a joined player is not told to join")
    club.members = { member(1) }
    c:emit("CLUB_MEMBERS_UPDATED", 900)
    c:advance(1)
    c:command("community")
    equal(printed(c, "Community: ForeverDuelersGuild | 1 members, 1 online, 1 in your zone"), true, "the loaded list is shown")
    equal(c.calls.FocusMembers, 1, "a loaded list is not requested again")
    c = Harness.client({ clubs = { directory({}) } })
    c.membersReady = false
    c.FD.Database.data.settings.quiet = true
    c:start(); c:advance(2)
    c:command("community")
    equal(c.calls.FocusMembers, nil, "quiet mode: the command requests no member list")
    c = Harness.client({ clubs = { directory({ member(1) }) } })
    c.clubLockdown = true
    c:start(); c:advance(2)
    c:command("community")
    equal(printed(c, "chat lockdown); retrying"), true, "the command shows the lockdown")
    equal(printed(c, "Join the in-game community"), false, "a lockdown is not answered with the join hint")
    for _, case in ipairs({ { "clubsEnabled", false }, { "clubRestriction", 1 } }) do
        c = Harness.client({ clubs = { directory({ member(1) }) } })
        c[case[1]] = case[2]
        c:start(); c:advance(15)
        c:command("community")
        equal(printed(c, "Join the in-game community"), false, "no join hint for " .. case[1])
    end

    -- Presence subscription: the client may push presence and zone only for
    -- the one club subscribed for presence. The directory holds that slot
    -- while discovery is active and neither the Communities nor the Channels
    -- window (which own it while shown) is shown, and clears it when
    -- discovery stops. A member who logs in or moves after the first read is
    -- then still found.
    club = directory({ member(1, { presence = OFFLINE }), member(2, { zone = "Westfall" }) })
    c = started({ clubs = { club } })
    c.presenceFrozen = true
    c:advance(60)
    club.members[1].presence = ONLINE
    club.members[2].zone = "Elwynn Forest"
    c:advance(130)
    equal(c.calls.SetClubPresenceSubscription, nil, "an idle client does not subscribe")
    equal(#c.FD.Community:Online(), 1, "without the subscription presence stays as first read")
    c.FD.Zone.shown = true
    c.P:Changed()
    c:advance(3)
    equal(c.subscription, 900, "an open zone window subscribes the directory club")
    c:advance(12) -- Read again after subscribing, even without an event.
    equal(#c.FD.Community:Online({ sameFaction = true, zone = c.FD.Community:OwnZones() }), 2,
        "with it, the member who logged in and the one who arrived count in your zone")
    c.FD.Zone.shown = false
    c:advance(6)
    equal(c.subscription, nil, "closing the zone window clears the subscription")
    local subscriptions = c.calls.SetClubPresenceSubscription
    c.env.CommunitiesFrame = { IsShown = function() return c.communitiesShown end }
    c.communitiesShown = true
    c.FD.Zone.shown = true
    c.P:Changed()
    c:advance(10)
    equal(c.calls.SetClubPresenceSubscription, subscriptions, "the slot is left alone while the Communities window is shown")
    c.subscription = 77 -- The window subscribed its own club.
    c.communitiesShown = false
    c.subscription = nil -- Its OnHide cleared the slot.
    c:advance(6)
    equal(c.subscription, 900, "the slot is taken back after the Communities window closed")
    c.shown = true -- The Channels window opens.
    c.FD.Zone.shown = false
    c:advance(6)
    equal(c.subscription, 900, "nothing is cleared while the Channels window is shown")
    c.shown = false
    c:advance(6)
    equal(c.subscription, nil, "after it closed, an idle directory releases the slot")
    c.FD.Database.data.settings.quiet = true
    c.FD.Zone.shown = true
    subscriptions = c.calls.SetClubPresenceSubscription
    c:advance(30)
    equal(c.calls.SetClubPresenceSubscription, subscriptions, "quiet mode does not subscribe")
    c.FD.Database.data.settings.quiet = nil
    c:advance(6)
    equal(c.subscription, 900, "leaving quiet mode with the zone window open subscribes")
    c:command("community off")
    c:advance(6)
    equal(c.subscription, nil, "community off releases the slot")
    -- The slot is taken together with FocusMembers, like the Channels
    -- window does; after that window (which unfocuses and clears on hide)
    -- both are taken back at once.
    c = started({ clubs = { directory({ member(1) }) } })
    c.FD.Zone.shown = true
    c.P:Changed()
    c:advance(3)
    equal(tostring(c.subscription) .. "|" .. tostring(c.calls.FocusMembers), "900|1", "the slot is taken with FocusMembers")
    c.shown = true
    c:advance(6)
    c.shown, c.subscription = false, nil -- Its OnHide unfocused and cleared the slot.
    c:advance(6)
    equal(tostring(c.subscription) .. "|" .. tostring(c.calls.FocusMembers), "900|2",
        "after the Channels window closed, slot and focus are taken back at once")
    c:advance(120)
    equal(c.calls.FocusMembers, 2, "a held slot is not focused again")

    -- Two clients on different internal servers: the channel never
    -- connects them and neither sees the other, but both are in the
    -- community. With the zone window open in the same zone they find each
    -- other.
    local function pair(bZone, bMap)
        local net = Harness.network({ channelDelivery = false, seed = 31 })
        local shared = directory()
        local a = net:add(Harness.client({ joined = true, clubs = { shared }, guid = "Player-4613-0000AAAA" }))
        local b = net:add(Harness.client({ joined = true, clubs = { shared }, guid = "Player-4619-0000BBBB",
            name = "Beta", surname = "Two", classFile = "ROGUE", mapID = bMap, zoneText = bZone }))
        shared.members = { own(a), own(b) }
        a:start(); b:start()
        return net, a, b, shared
    end
    local net, a, b, shared = pair()
    net:advance(5)
    equal(#a.sent + #b.sent > 0, true, "the channel experiment runs")
    a.FD.Zone.shown = true
    a.P:Changed()
    net:advance(15)
    equal(#a.P:GetPlayers(), 1, "A lists B through the community")
    equal(a.P:GetPlayers()[1].fullName, "Beta Two", "with B's name")
    equal(b.P:FindByName("Alpha One") ~= nil, true, "B learns A from the query")
    equal(#b.P:GetPlayers(), 1, "B lists A in the same zone")
    equal(a.P.received.channel + b.P.received.channel, 0, "no channel post ever arrived")
    equal(whispersTo(a, "Beta Two", "FDQ2"), 1, "one query is enough")
    local traced = false
    for _, entry in ipairs(a:trace("transport")) do
        if entry.event == "zone send" and entry.detail == "first community query" then traced = true end
        equal(entry.detail:find("Beta", 1, true), nil, "persisted diagnostics hold no member names")
    end
    equal(traced, true, "the first community query is persisted once")
    net:advance(120)
    equal(whispersTo(a, "Beta Two", "FDQ2") <= 4, true, "a known member is re-asked at most every 45 s")
    equal(#a.P:GetPlayers(), 1, "and stays listed")
    equal(a.clubWrites or b.clubWrites, nil, "nothing is written to the community")

    -- Different zones: the zone browser does not ask B; the queue does when
    -- its scope reaches B, and B becomes a queue candidate.
    net, a, b = pair("Westfall", 40)
    a.FD.Zone.shown = true
    a.P:Changed()
    net:advance(120)
    equal(whispersTo(a, "Beta Two"), 0, "a member in another zone is not asked for the zone browser")
    equal(#a.P:GetPlayers(), 0, "and not listed")
    local scope, queries = "ZONE", {}
    local engine = FD.Queue:New({ now = function() return a.now end, epoch = function() return 1700000000 + math.floor(a.now) end,
        settings = function() return { scope = scope, levelGap = 5, blockedOpponents = {} } end,
        candidates = function() return a.P:Candidates() end, own = function() return nil end, render = function() end,
        send = function(packet, target) queries[#queries + 1] = { kind = packet.kind, target = target, at = a.now }; return true end })
    engine.state, engine.ownProfile = "SEARCHING", { guid = a.player.guid }
    a.FD.queue = engine
    a.FD.Zone.shown = false
    a.P:Changed()
    net:advance(60)
    equal(whispersTo(a, "Beta Two"), 0, "a ZONE search does not reach another zone")
    scope = "RULESET"
    local stop = net.now + 120
    while net.now < stop do
        net:advance(1)
        engine:QueryPeer()
    end
    equal(whispersTo(a, "Beta Two", "FDQ2") >= 1, true, "a RULESET search asks the member in another zone")
    equal(a.P:FindByName("Beta Two") ~= nil, true, "B is discovered")
    equal(#a.P:GetPlayers(), 0, "but not listed in A's zone browser (B disclosed no map)")
    equal(a.P:FindByName("Beta Two").mapID, 0, "B's reply carried map 0")
    local candidate = false
    for _, entry in ipairs(a.P:Candidates()) do if entry.fullName == "Beta Two" then candidate = true end end
    equal(candidate, true, "B is a queue candidate")
    local toBeta, last = 0, nil
    for index, entry in ipairs(queries) do
        if index > 1 then equal(entry.at - queries[index - 1].at >= 2, true, "queue QUERY spacing holds") end
        if entry.target == "Beta Two" then
            toBeta = toBeta + 1
            if last then equal(entry.at - last >= 30, true, "the queue asks a discovered candidate every 30 s at most") end
            last = entry.at
        end
    end
    equal(toBeta >= 2, true, "the queue queries the community-discovered candidate")
    equal(b.P:FindByName("Alpha One") ~= nil, true, "B learns A from the query")

    -- B logs in after A read the member list, on a client that pushes
    -- presence only for the subscribed club: A's open zone window takes the
    -- subscription and finds B.
    net, a, b, shared = pair()
    a.presenceFrozen = true
    shared.members[2].presence = OFFLINE
    net:advance(70)
    shared.members[2].presence = ONLINE
    net:advance(70)
    equal(a.FD.Community:Online()[1], nil, "A's unsubscribed copy still shows B offline")
    equal(whispersTo(a, "Beta Two"), 0, "and A asks nobody")
    a.FD.Zone.shown = true
    a.P:Changed()
    net:advance(20)
    equal(#a.P:GetPlayers(), 1, "with the subscription A lists B within 20 s")

    -- Offline (and mobile or unknown) members are never whispered, not by
    -- the zone browser nor by a whole-ruleset search.
    net = Harness.network({ channelDelivery = false, seed = 5 })
    local offline = { member(1, { presence = OFFLINE }), member(2, { presence = MOBILE }), member(3, { presence = UNKNOWN }),
        member(4, { presence = OFFLINE, zone = "Westfall" }), member(5) }
    for _, record in ipairs(offline) do net:bot(Harness.identity(tonumber(record.name:match("%d+")))) end
    a = net:add(Harness.client({ joined = true, clubs = { directory(offline) },
        queue = { state = "SEARCHING", Settings = function() return { scope = "RULESET" } end } }))
    a:start()
    a.FD.Zone.shown = true
    net:advance(600)
    for index = 1, 4 do equal(whispersTo(a, offline[index].name), 0, "offline member " .. index .. " is never whispered") end
    equal(whispersTo(a, offline[5].name, "FDQ2") >= 1, true, "the online member is asked")

    -- Quiet mode: nothing is sent and nothing requested.
    net = Harness.network({ channelDelivery = false, seed = 6 })
    club = directory({ member(1), member(2, { zone = "Westfall" }) })
    net:bot(Harness.identity(1)); net:bot(Harness.identity(2))
    a = net:add(Harness.client({ joined = true, clubs = { club },
        queue = { state = "SEARCHING", Settings = function() return { scope = "RULESET" } end } }))
    a.FD.Database.data.settings.quiet = true
    a.membersReady = false
    a:start()
    a.FD.Zone.shown = true
    a.P:RefreshNow()
    net:advance(300)
    equal(#a.sent, 0, "quiet mode sends nothing to community members")
    equal(a.calls.FocusMembers, nil, "quiet mode requests no member list")
    equal(a.FD.Community:IsMember(member(1).name), true, "the directory is still read")

    -- Busy: nothing is asked during a duel request or a queue ticket.
    for _, busy in ipairs({ "duel", "ticket" }) do
        net = Harness.network({ channelDelivery = false, seed = 8 })
        net:bot(Harness.identity(1))
        a = net:add(Harness.client({ joined = true, clubs = { directory({ member(1) }) },
            queue = { state = "SEARCHING", ticket = busy == "ticket" and { peer = {} } or nil,
                Settings = function() return { scope = "RULESET" } end } }))
        if busy == "duel" then a.FD.duel.active = { state = "PENDING" } end
        a:start()
        a.FD.Zone.shown = true
        net:advance(120)
        equal(whispersTo(a, member(1).name), 0, "no community query while busy: " .. busy)
    end

    -- An idle client in a busy community: presence events alone never make
    -- it re-read the list more than once a minute; a join is still read
    -- within 10 s.
    many = {}
    for i = 1, 1000 do many[i] = member(i) end
    club = directory(many)
    c = started({ clubs = { club } })
    reads = c.calls.GetSubscribedClubs
    local infos = c.calls.GetMemberInfo
    for t = 1, 600 do
        c:emit("CLUB_MEMBER_PRESENCE_UPDATED", 900, t % 1000 + 1, ONLINE)
        c:advance(1)
    end
    equal(c.calls.GetSubscribedClubs - reads <= 11, true, "idle: one rebuild a minute despite presence events")
    equal(c.calls.GetMemberInfo - infos <= 11000, true, "idle: member reads stay bounded")
    equal(#c:whispers(), 0, "idle: nobody is whispered")
    club.members[1001] = member(1001)
    table.remove(club.members, 1)
    c:emit("CLUB_MEMBER_ADDED", 900, 1001)
    c:advance(10)
    equal(c.FD.Community:IsMember(member(1001).name), true, "idle: a join is read within 10 s")

    -- Profile pushes after a map change reach a peer known only through the
    -- community only when its zone browser listing of us changes, and never
    -- one the directory reports offline. A whole-ruleset search caches
    -- members all over the realm; map-0 pushes to them told them nothing and
    -- crowded out queries.
    local function pushes(c, from)
        local list = {}
        for index = from + 1, #c.sent do
            local packet = c.sent[index]
            if packet.channel == "WHISPER" and packet.result == 0 and packet.payload:sub(1, 5) == "FDP2|" then
                list[#list + 1] = { target = packet.target, map = tonumber(packet.payload:match("^FDP2|[^|]+|[^|]+|([^|]+)|")) }
            end
        end
        return list
    end
    local function queriesSince(c, from)
        local n = 0
        for index = from + 1, #c.sent do
            local packet = c.sent[index]
            if packet.channel == "WHISPER" and packet.result == 0 and packet.payload:sub(1, 5) == "FDQ2|" then n = n + 1 end
        end
        return n
    end
    net = Harness.network({ latency = 0.3, jitter = 0.6, seed = 99, channelDelivery = false })
    local crowd = {}
    local mapOf = {}
    for i = 1, 300 do
        local west = i % 2 == 0
        crowd[i] = member(i, { zone = west and "Westfall" or "Duskwood" })
        mapOf[crowd[i].name] = west and 40 or 47
        net:bot(Harness.identity(i), { silent = i > 200, mapID = mapOf[crowd[i].name] })
    end
    local queue = { state = "SEARCHING", Settings = function() return { scope = "RULESET" } end }
    a = net:add(Harness.client({ joined = true, clubs = { directory(crowd) }, queue = queue }))
    a:start()
    net:advance(300, 0.1)
    queue.state = "IDLE"
    net:advance(5, 0.1)
    local mark = #a.sent
    a.mapID = 12
    a.P:Changed()
    net:advance(60, 0.1)
    equal(#pushes(a, mark), 0, "idle: a map change pushes nothing to members on other maps")
    queue.state = "SEARCHING"
    net:advance(120, 0.1)
    mark = #a.sent
    for _, map in ipairs({ 40, 47, 12, 40, 47, 12 }) do
        a.mapID = map
        a.P:Changed()
        net:advance(30, 0.1)
    end
    -- Replay what each member was told: every push must end a listing (the
    -- map we last disclosed equals the member's own) on a map we left.
    local told = {}
    for index, packet in ipairs(a.sent) do
        local tag, map = packet.payload:match("^(FD[PQ]2)|[^|]+|[^|]+|([^|]+)|")
        if packet.channel == "WHISPER" and packet.result == 0 and tag then
            map = tonumber(map)
            local theirs = mapOf[packet.target]
            if index > mark and tag == "FDP2" then
                local before = told[packet.target]
                equal(before ~= nil and before ~= 0 and before == theirs, true, "a push goes only to a member that lists us")
                equal(map, 0, "and unlists us")
            end
            told[packet.target] = map
        end
    end
    local sent, asked = #pushes(a, mark), queriesSince(a, mark)
    equal(sent <= 6 * 30, true, "pushes stay bounded: " .. sent)
    equal(asked >= 2 * sent, true, "queries are not crowded out: " .. asked .. " queries, " .. sent .. " pushes")
    -- Arrival is left to discovery, and a member the directory reports
    -- offline gets no push even when it listed us.
    net = Harness.network({ latency = 0.3, jitter = 0.2, seed = 7, channelDelivery = false })
    crowd = {}
    for i = 1, 5 do crowd[i] = member(i, { zone = "Westfall" }); net:bot(Harness.identity(i), { mapID = 40 }) end
    club = directory(crowd)
    queue = { state = "SEARCHING", Settings = function() return { scope = "RULESET" } end }
    a = net:add(Harness.client({ joined = true, clubs = { club }, queue = queue }))
    a:start()
    net:advance(30, 0.1)
    equal(a.P:FindByName(crowd[1].name) ~= nil, true, "member 1 is discovered")
    mark = #a.sent
    a.mapID = 40
    a.P:Changed()
    net:advance(20, 0.1)
    local targets = {}
    for _, push in ipairs(pushes(a, mark)) do targets[push.target] = true end
    equal(next(targets), nil, "arrival is left to discovery: no push to members on the entered map")
    net:advance(50, 0.1) -- The search asks again; the queries carry map 40.
    equal(a.P.disclosed[crowd[1].name], 40, "member 1 was told our map 40 and lists us")
    crowd[1].presence = OFFLINE
    a:emit("CLUB_MEMBER_PRESENCE_UPDATED", 900, 1, OFFLINE)
    net:advance(12, 0.1)
    mark = #a.sent
    a.mapID = 37
    a.P:Changed()
    net:advance(40, 0.1)
    targets = {}
    for _, push in ipairs(pushes(a, mark)) do targets[push.target] = true end
    equal(targets[crowd[1].name], nil, "the member the directory reports offline gets no push")
    equal(targets[crowd[2].name], true, "an online member that listed us learns that we left")
    -- A query that arrives while a push to the same member waits is still
    -- answered, even when the push itself is no longer due.
    c = started({ clubs = { directory({ member(1) }) } })
    local peer = member(1).name
    c:receive(c:profile(Harness.identity(1), 37), peer)
    c.P.disclosed[peer] = 37
    c.P.inflight = {} -- Holds the lane, so the push waits.
    c.mapID = 40
    c.P:Changed()
    c:advance(3)
    equal(c.P.work[peer] ~= nil and c.P.work[peer].push, true, "the map change queued a push to the member that listed us")
    c:inject(c:profile(Harness.identity(1), 40, "FDQ2"), peer)
    c.P.inflight = nil
    c.P:Pump()
    c:advance(1)
    equal(whispersTo(c, peer, "FDP2|"), 1, "the query is answered although the waiting push became stale")
    -- The map a query disclosed is remembered until its answer can arrive,
    -- so a member that lists us after answering learns when we leave.
    c = started({ clubs = { directory({ member(1) }) } })
    c.P.asked[peer], c.P.disclosed[peer] = c.now, 37
    c:advance(20)
    equal(c.P.disclosed[peer], 37, "a query's disclosed map outlives the ticks before the answer")
    c:advance(200)
    equal(c.P.disclosed[peer], nil, "and is dropped once the query expired unanswered")

    -- Refresh asks known addon users again, but not members who never
    -- answered (STRANGER) or were found offline.
    net = Harness.network({ latency = 0.3, jitter = 0.2, seed = 3, channelDelivery = false })
    crowd = {}
    for i = 1, 40 do crowd[i] = member(i); net:bot(Harness.identity(i), { silent = i > 10 }) end
    a = net:add(Harness.client({ joined = true, clubs = { directory(crowd) } }))
    a:start()
    a.FD.Zone.shown = true
    a.P:Changed()
    net:advance(240, 0.1)
    local function asks(c, silentOnly)
        local n = 0
        for _, packet in ipairs(c:whispers("FDQ2")) do
            local index = tonumber(packet.target:match("^Peer(%d+) "))
            if not silentOnly or index and index > 10 then n = n + 1 end
        end
        return n
    end
    equal(asks(a, true), 30, "every silent member is asked once")
    local gone = crowd[1].name
    a.P:Forget(gone) -- Found offline ("No player named ...").
    local silentAsks, allAsks, goneAsks = asks(a, true), asks(a), whispersTo(a, gone, "FDQ2")
    a.P:RefreshNow()
    net:advance(60, 0.1)
    equal(asks(a, true), silentAsks, "Refresh does not whisper members who never answered again")
    equal(whispersTo(a, gone, "FDQ2"), goneAsks, "nor a name found offline")
    equal(asks(a) > allAsks, true, "Refresh asks the known addon users again")

    -- A 300-member community: zone window open and a whole-ruleset search
    -- for ten minutes. 100 members never answer, half are in another zone.
    -- Traffic stays within the Outbound budget and the per-name intervals.
    net = Harness.network({ latency = 0.3, jitter = 0.6, loss = 0.02, seed = 4242, channelDelivery = false })
    local silent = {}
    crowd = {}
    for i = 1, 300 do
        local zone = i % 2 == 0 and "Westfall" or "Elwynn Forest"
        crowd[i] = member(i, { zone = zone })
        net:bot(Harness.identity(i), { silent = i > 200, mapID = zone == "Westfall" and 40 or 37 })
        if i > 200 then silent[crowd[i].name] = true end
    end
    a = net:add(Harness.client({ joined = true, clubs = { directory(crowd) },
        queue = { state = "SEARCHING", Settings = function() return { scope = "RULESET" } end } }))
    local recent, throttled = {}, 0
    a.sendResult = function(packet)
        if packet.channel ~= "WHISPER" then return 0 end
        while recent[1] and packet.at - recent[1] >= 1 do table.remove(recent, 1) end
        if #recent >= 10 then throttled = throttled + 1; return 3 end
        recent[#recent + 1] = packet.at
        return 0
    end
    a:start()
    a.FD.Zone.shown = true
    local maxWork, start = 0, net.now
    stop = net.now + 600
    while net.now < stop do
        net:step(0.1)
        maxWork = math.max(maxWork, a.P.workCount)
    end
    local times, perName, asked = {}, {}, 0
    for _, packet in ipairs(a.sent) do
        if packet.channel == "WHISPER" and packet.result == 0 then
            times[#times + 1] = packet.at
            if packet.payload:sub(1, 5) == "FDQ2|" then
                local list = perName[packet.target] or {}
                perName[packet.target] = list
                list[#list + 1] = packet.at
            end
        end
    end
    local worst = 0
    for i = 1, #times do
        local n = 0
        for j = i, #times do if times[j] - times[i] < 60 then n = n + 1 else break end end
        worst = math.max(worst, n)
    end
    equal(worst <= 68, true, "at most 68 whispers in any minute (8 burst + 1/s): " .. worst)
    equal(throttled, 0, "the server throttle is never hit")
    equal(maxWork <= 30, true, "pending discovery work never exceeds 30")
    for name, list in pairs(perName) do
        asked = asked + 1
        if silent[name] then equal(#list, 1, "a member that never answers is asked once in ten minutes: " .. name) end
        for i = 2, #list do equal(list[i] - list[i - 1] >= 45, true, "per-member query interval holds: " .. name) end
    end
    equal(asked, 300, "every online member is asked within ten minutes")
    local found, listed = 0, #a.P:GetPlayers()
    for i = 1, 200 do if a.P:FindByName(crowd[i].name) then found = found + 1 end end
    equal(found >= 150, true, "most answering members stay discovered: " .. found)
    equal(listed >= 60 and listed <= 100, true, "only same-zone members are listed in the zone browser: " .. listed)
    equal(#times > 400, true, "the budget is used, not idle")
    equal(a.calls.GetSubscribedClubs <= (600 / 60) + 3, true, "the directory is rebuilt about once a minute without events")
    equal(a.clubWrites, nil, "nothing is written to the community")
    equal(net.now - start >= 600, true, "ten minutes simulated")
end
