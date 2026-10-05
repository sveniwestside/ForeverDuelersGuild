return function(FD, equal)
    local chat, now, secret = {}, 1700000000, {}
    local env = setmetatable({ GetServerTime = function() return now end,
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) chat[#chat + 1] = message end } }, { __index = _G })
    FD.Wow = { Readable = function(_, value) return value ~= secret end }
    FD.Database.data = { settings = { debug = false }, matches = {}, ratings = { LEVELING = 1500 } }
    local chunk = assert(loadfile("ForeverDuel/Debug.lua"))
    setfenv(chunk, env)("ForeverDuel", FD)
    FD.Debug:Log("outgoing request", "native unit identity unavailable")
    equal(#chat, 0, "failure diagnostics do not enable chat debug")
    local trace = FD.Debug:RequestTrace()
    equal(#trace, 1, "native failure can be inspected with debug off")
    equal(trace[1].event, "outgoing request")
    equal(trace[1].at, now, "diagnostics retain server timestamp")
    equal(trace[1].version, FD.C.VERSION)
    trace[1].detail = "changed"
    equal(FD.Debug:RequestTrace()[1].detail, "native unit identity unavailable", "caller cannot mutate saved diagnostics")
    FD.Debug:Log("queue position", 1420, 0.5, 0.5)
    FD.Debug:Log("RESULT", "untrusted result")
    FD.Debug:Log("UI_INFO_MESSAGE", secret, "restricted")
    FD.Debug:Log(secret, "restricted topic")
    equal(#FD.Debug:RequestTrace(), 1, "positions, result evidence and restricted values are excluded")
    FD.Debug:Log("state", "CHECKING_ADDON", "->", "READY", "request-nonce")
    equal(FD.Debug:RequestTrace()[2].detail, "CHECKING_ADDON -> READY", "state trace excludes negotiation identity")
    FD.Debug:Log("duel detected", "OUTGOING", "Native Name", "request-nonce")
    equal(FD.Debug:RequestTrace()[3].detail, "OUTGOING Native Name", "detection trace excludes negotiation identity")
    now = math.huge
    FD.Debug:Log("UI_ERROR_MESSAGE", "native error")
    equal(FD.Debug:RequestTrace()[4].at, nil, "nonfinite timestamps cannot enter SavedVariables")
    now = 1700000001
    FD.Debug:Log("UI_INFO_MESSAGE", string.rep("x", 2000))
    equal(#FD.Debug:RequestTrace()[5].detail, 320, "individual diagnostics are bounded")
    for i = 1, 70 do FD.Debug:Log("transport receive", "HELLO", "Player " .. i) end
    trace = FD.Debug:RequestTrace(100)
    equal(#trace, 64, "saved diagnostics have a hard entry limit")
    equal(trace[1].detail, "HELLO Player 7", "oldest summaries are evicted")
    equal(trace[64].detail, "HELLO Player 70")
    equal(#FD.Debug:RequestTrace(), 12, "chat inspection defaults to a short tail")
    equal(#FD.Database.data.matches, 0, "diagnostics cannot create history")
    equal(FD.Database.data.ratings.LEVELING, 1500, "diagnostics cannot change ratings")
    local snapshot = assert(FD.Database:Copy(FD.Database.data))
    chunk = assert(loadfile("ForeverDuel/Debug.lua"))
    setfenv(chunk, env)("ForeverDuel", FD)
    FD.Database.data = snapshot
    equal(FD.Debug:RequestTrace()[12].detail, "HELLO Player 70", "diagnostics survive reload through SavedVariables")
    snapshot.settings.debug = true
    FD.Debug:Log("unlisted topic", "debug chat")
    equal(#chat, 1, "explicit chat debug continues to work")
    equal(#FD.Debug:RequestTrace(100), 64, "unlisted chat logs do not expand persisted diagnostics")
    snapshot.settings.requestDiagnostics = {}
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
    equal(#FD.Debug:RequestTrace(), 9, "native state transition separates transport observations")
    snapshot.settings.requestDiagnostics = {}
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
end
