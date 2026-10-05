return function(FD, equal)
    local chat, now, clock, secret = {}, 1700000000, 100.25, {}
    local env = setmetatable({ GetServerTime = function() return now end, GetTime = function() return clock end,
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) chat[#chat + 1] = message end } }, { __index = _G })
    FD.Wow = { Readable = function(_, value) return value ~= secret end }
    FD.Database.data = { settings = { debug = false }, matches = {}, ratings = { LEVELING = 1500 } }
    local chunk = assert(loadfile("ForeverDuel/Debug.lua"))
    setfenv(chunk, env)("ForeverDuel", FD)

    -- Lifecycle evidence is recorded with debug chat off, with both clocks.
    FD.Debug:Log("outgoing request", "native unit identity unavailable")
    equal(#chat, 0, "failure diagnostics do not enable chat debug")
    local trace = FD.Debug:RequestTrace()
    equal(#trace, 1, "native failure can be inspected with debug off")
    equal(trace[1].event, "outgoing request")
    equal(trace[1].at, now, "diagnostics retain server timestamp")
    equal(trace[1].t, 100.25, "diagnostics retain client time with millisecond precision")
    equal(trace[1].version, FD.C.VERSION)
    trace[1].detail = "changed"
    equal(FD.Debug:RequestTrace()[1].detail, "native unit identity unavailable", "caller cannot mutate saved diagnostics")

    -- Privacy and relevance filters.
    FD.Debug:Log("queue position", 1420, 0.5, 0.5)
    FD.Debug:Log("RESULT", "untrusted result")
    FD.Debug:Log("UI_INFO_MESSAGE", 7, secret, "restricted")
    FD.Debug:Log(secret, "restricted topic")
    equal(#FD.Debug:RequestTrace(), 1, "positions, result evidence and restricted values are excluded")
    FD.Debug:Log("UI_ERROR_MESSAGE", 51, "ERR_SPELL_COOLDOWN", "Spell is not ready yet.")
    FD.Debug:Log("UI_ERROR_MESSAGE", 52, nil, "Not enough rage")
    equal(#FD.Debug:RequestTrace(), 1, "combat and spell notices never enter the persisted trace")
    FD.Debug:Log("UI_INFO_MESSAGE", 300, "ERR_DUEL_REQUESTED", "You have requested a duel.")
    equal(FD.Debug:RequestTrace()[2].detail, "300 ERR_DUEL_REQUESTED You have requested a duel.",
        "duel-related native notices are recorded")
    FD.Debug:Log("state", "CHECKING_ADDON", "->", "READY", "request-nonce")
    equal(FD.Debug:RequestTrace()[3].detail, "CHECKING_ADDON -> READY", "state trace excludes negotiation identity")
    FD.Debug:Log("duel detected", "OUTGOING", "Native Name", "request-nonce")
    equal(FD.Debug:RequestTrace()[4].detail, "OUTGOING Native Name", "detection trace excludes negotiation identity")
    FD.Debug:Log("unrated", "rated confirmation timed out")
    equal(FD.Debug:RequestTrace()[5].event, "unrated", "unrate reasons are persisted")
    now = math.huge
    FD.Debug:Log("unrated", "native error")
    equal(FD.Debug:RequestTrace()[6].at, nil, "nonfinite timestamps cannot enter SavedVariables")
    now = 1700000001
    FD.Debug:Log("unrated", string.rep("x", 2000))
    equal(#FD.Debug:RequestTrace()[7].detail, 320, "individual diagnostics are bounded")

    -- Separate rings: transport floods cannot evict lifecycle evidence.
    for i = 1, 70 do FD.Debug:Log("transport receive", "HELLO", "Player " .. i) end
    local transport = FD.Debug:RequestTrace(100, "transport")
    equal(#transport, 64, "transport ring has a hard entry limit")
    equal(transport[1].detail, "HELLO Player 7", "oldest transport summaries are evicted")
    equal(transport[64].detail, "HELLO Player 70")
    local lifecycle = FD.Debug:RequestTrace(100, "lifecycle")
    equal(#lifecycle, 7, "lifecycle evidence survives a transport flood")
    equal(lifecycle[1].event, "outgoing request", "first request evidence is still present")
    local merged = FD.Debug:RequestTrace(100)
    equal(#merged, 71, "merged view contains both rings")
    equal(merged[7].event, "unrated", "merged view keeps chronological order")
    equal(merged[8].detail, "HELLO Player 7", "transport entries follow in sequence")
    equal(#FD.Debug:RequestTrace(), 12, "chat inspection defaults to a short tail")
    equal(#FD.Database.data.matches, 0, "diagnostics cannot create history")
    equal(FD.Database.data.ratings.LEVELING, 1500, "diagnostics cannot change ratings")

    -- Survives reload through SavedVariables.
    local snapshot = assert(FD.Database:Copy(FD.Database.data))
    chunk = assert(loadfile("ForeverDuel/Debug.lua"))
    setfenv(chunk, env)("ForeverDuel", FD)
    FD.Database.data = snapshot
    equal(FD.Debug:RequestTrace(1, "transport")[1].detail, "HELLO Player 70", "diagnostics survive reload")
    snapshot.settings.debug = true
    FD.Debug:Log("unlisted topic", "debug chat")
    equal(#chat, 1, "explicit chat debug continues to work")
    equal(#FD.Debug:RequestTrace(200), 71, "unlisted chat logs do not expand persisted diagnostics")

    -- Coalescing of repeated waiting traffic; boundaries across rings.
    snapshot.settings.requestDiagnostics, snapshot.settings.transportDiagnostics = {}, {}
    snapshot.settings.debug = false
    FD.Debug:Log("outgoing request", "Native Name | acknowledged")
    FD.Debug:Log("state", "CHECKING_ADDON", "->", "DISCOVERY_WAIT", "nonce")
    FD.Debug:Log("transport receive", "HELLO from Native Name", "state", "DISCOVERY_WAIT")
    FD.Debug:Log("peer validation", "HELLO | native peer verified; acknowledgment queued")
    now = now + 2
    FD.Debug:Log("transport receive", "HELLO from Native Name", "state", "DISCOVERY_WAIT")
    FD.Debug:Log("peer validation", "HELLO | native peer verified; acknowledgment queued")
    trace = FD.Debug:RequestTrace()
    equal(#trace, 4, "repeated waiting traffic does not displace native request evidence")
    equal(trace[3].repeats, 1, "duplicate receipt count remains observable")
    equal(trace[3].lastAt, now, "coalesced receipts retain last timestamp")
    equal(trace[3].at, now - 2, "coalesced receipts retain first timestamp")
    FD.Debug:Log("peer validation", "HELLO | native class mismatch")
    equal(#FD.Debug:RequestTrace(), 5, "a changed guard diagnosis is recorded immediately")
    now = now + 5
    FD.Debug:Log("transport receive", "HELLO from Native Name", "state", "DISCOVERY_WAIT")
    equal(#FD.Debug:RequestTrace(), 6, "receipt beyond short coalescing interval receives a new timestamp")
    FD.Debug:Log("transport receive", "HELLO_ACK from Native Name", "state", "DISCOVERY_WAIT")
    now = now + 1
    FD.Debug:Log("transport receive", "HELLO from Native Name", "state", "DISCOVERY_WAIT")
    trace = FD.Debug:RequestTrace()
    equal(#trace, 7, "alternating HELLO and ACK do not defeat short duplicate coalescing")
    equal(trace[6].repeats, 1, "coalesced alternating receipt keeps its own count")
    FD.Debug:Log("state", "DISCOVERY_WAIT", "->", "READY")
    FD.Debug:Log("transport receive", "HELLO from Native Name", "state", "DISCOVERY_WAIT")
    equal(#FD.Debug:RequestTrace(), 9, "a state transition in the lifecycle ring separates transport observations")

    -- Queue lifecycle summaries.
    snapshot.settings.requestDiagnostics, snapshot.settings.transportDiagnostics = {}, {}
    local before = FD.Database:Copy(snapshot.ratings)
    FD.Debug:Log("queue state", "RESERVING", "->", "GROUPING", "native invitation pending", "ticket-nonce")
    equal(FD.Debug:RequestTrace()[1].detail, "RESERVING -> GROUPING native invitation pending",
        "queue transition includes bounded descriptive reason but excludes extra ticket data")
    FD.Debug:Log("queue group", "PENDING", "GROUPING", "ticket-nonce")
    now = now + 2
    FD.Debug:Log("queue group", "PENDING", "GROUPING")
    equal(#FD.Debug:RequestTrace(), 2, "native group waiting summaries are deduplicated")
    equal(FD.Debug:RequestTrace()[2].repeats, 1, "group waiting keeps repeat count")
    equal(FD.Debug:RequestTrace()[2].detail, "PENDING GROUPING", "group trace excludes extra native or ticket fields")
    FD.Debug:Log("queue group", "EXACT", "GROUPING")
    equal(#FD.Debug:RequestTrace(), 3, "changed group classification is preserved immediately")
    FD.Debug:Log("queue planning", "NO_VENUE", "catalog mismatch", "map coordinates")
    equal(FD.Debug:RequestTrace()[4].detail, "NO_VENUE catalog mismatch", "planning reason excludes extra coordinates")
    FD.Debug:Log("queue state", "GROUPING", "->", "CLEANUP", "TECHNICAL")
    FD.Debug:Log("queue group", "EXACT", "GROUPING")
    equal(#FD.Debug:RequestTrace(), 6, "queue transitions separate group observations")
    equal(#chat, 1, "queue diagnostic collection leaves chat debug off")
    equal(#snapshot.matches, 0, "queue diagnostics cannot create rated history")
    equal(snapshot.ratings.LEVELING, before.LEVELING, "queue diagnostics cannot change rating")

    -- Addon errors are always persisted, bounded and summarized.
    FD.Debug:Error("rated duel", "Duel.lua:10: attempt to index nil", "stack line 1\nstack line 2|x")
    local errors = FD.Debug:Errors()
    equal(#errors, 1, "an addon error is persisted with debug off")
    equal(errors[1].context, "rated duel")
    equal(errors[1].message, "Duel.lua:10: attempt to index nil")
    equal(errors[1].stack:find("|", 1, true), nil, "stacks cannot carry chat escape sequences")
    equal(#chat, 2, "the first error prints one pointer to /duelrating errors")
    FD.Debug:Error("rated duel", "Duel.lua:10: attempt to index nil")
    equal(#FD.Debug:Errors(), 1, "identical consecutive errors are counted, not duplicated")
    equal(FD.Debug:Errors()[1].repeats, 1)
    equal(#chat, 2, "the error pointer is printed only once per session")
    for i = 1, 15 do FD.Debug:Error("queue", "error " .. i) end
    equal(#FD.Debug:Errors(100), 10, "the error ring is bounded")
    equal(FD.Debug:Errors(100)[10].message, "error 15")
    FD.Debug:Error("queue", secret)
    equal(FD.Debug:Errors(1)[1].message, "restricted error", "restricted error values are never stored")
    FD.Debug:ClearErrors()
    equal(#FD.Debug:Errors(), 0, "errors can be cleared")

    -- Traffic counters: totals, rolling minute and unique recipients.
    FD.Debug:Count("ForeverDuel2", "WHISPER", "submitted", "Beta-Forever")
    FD.Debug:Count("ForeverDuel2", "WHISPER", "success", "Beta-Forever")
    FD.Debug:Count("ForeverDuel2", "WHISPER", "submitted", "Gamma-Forever")
    FD.Debug:Count("ForeverDuel2", "WHISPER", "throttled", "Gamma-Forever")
    local lines = FD.Debug:TrafficLines()
    equal(#lines, 1, "one traffic line per prefix and channel")
    equal(lines[1]:find("submitted 2", 1, true) ~= nil, true, "submissions are counted")
    equal(lines[1]:find("(2 recipients)", 1, true) ~= nil, true, "unique recipients are counted")
    equal(snapshot.settings.trafficCounters["ForeverDuel2 WHISPER"].totals.throttled, 1, "totals are persisted")
    clock = clock + 120
    FD.Debug:Count("ForeverDuel2", "WHISPER", "submitted", "Beta-Forever")
    equal(snapshot.settings.trafficCounters["ForeverDuel2 WHISPER"].lastMinute.recipients, 2,
        "the previous full minute is persisted when a new minute starts")
    FD.Debug:Session(false, true)
    equal(FD.Debug:RequestTrace(1, "lifecycle")[1].detail, "reload", "reload and login are distinguished")
end
