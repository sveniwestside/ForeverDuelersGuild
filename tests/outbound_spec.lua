return function(_, equal, newNamespace)
    local function setup(results)
        local FD = newNamespace()
        local state = { now = 100, timers = {}, sent = {}, results = results or {} }
        local env = setmetatable({}, { __index = _G })
        env.GetTime = function() return state.now end
        env.GetServerTime = function() return 1700000000 + math.floor(state.now) end
        env.C_Timer = { After = function(delay, callback)
            state.timers[#state.timers + 1] = { at = state.now + delay, callback = callback }
        end }
        env.Enum = { SendAddonMessageResult = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2,
            AddonMessageThrottle = 3, InvalidChatType = 4, NotInGroup = 5, ChannelThrottle = 8,
            GeneralError = 9, AddOnMessageLockdown = 11, TargetOffline = 12 },
            RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 } }
        env.C_ChatInfo = {
            RegisterAddonMessagePrefix = function() return 0 end,
            SendAddonMessage = function(prefix, payload, channel, target)
                local result = 0
                local queued = state.results[1]
                if queued ~= nil then table.remove(state.results, 1); result = queued end
                if type(result) == "function" then result = result(prefix, payload, channel, target) end
                state.sent[#state.sent + 1] = { prefix = prefix, payload = payload, channel = channel,
                    target = target, result = result, at = state.now }
                return result
            end,
        }
        FD.Database.data = { settings = { debug = false } }
        for _, file in ipairs({ "Debug", "Outbound" }) do
            local chunk = assert(loadfile("ForeverDuel/" .. file .. ".lua"))
            setfenv(chunk, env)("ForeverDuel", FD)
        end
        function state:advance(seconds)
            local untilTime, guard = self.now + seconds, 0
            while true do
                local selected, at
                for index, timer in ipairs(self.timers) do
                    if timer.at <= untilTime and (not at or timer.at < at) then selected, at = index, timer.at end
                end
                if not selected then break end
                guard = guard + 1
                assert(guard < 5000, "timer runaway")
                local timer = table.remove(self.timers, selected)
                self.now = at
                timer.callback()
            end
            self.now = untilTime
        end
        state.FD, state.Outbound = FD, FD.Outbound
        return state
    end

    local function item(fields)
        local value = { prefix = "ForeverDuel2", payload = "FD|x", channel = "WHISPER", target = "Beta-Forever",
            priority = 1 }
        for key, field in pairs(fields or {}) do value[key] = field end
        return value
    end

    -- Pacing and priority.
    local s = setup()
    equal(s.Outbound:Register("ForeverDuel2"), true, "prefix registration succeeds")
    equal(s.Outbound:Send(item({ payload = "bg", priority = 3 })), true)
    equal(s.Outbound:Send(item({ payload = "control", priority = 1 })), true)
    equal(#s.sent, 0, "sending is always deferred to the scheduler")
    s:advance(0.05)
    equal(#s.sent, 1)
    equal(s.sent[1].payload, "control", "control traffic is sent before background traffic")
    s:advance(0.05)
    equal(#s.sent, 1, "consecutive sends are spaced")
    s:advance(0.1)
    equal(#s.sent, 2)
    equal(s.sent[2].payload, "bg")

    -- Whisper budget: background traffic keeps a reserve for control packets.
    s = setup()
    for i = 1, 12 do s.Outbound:Send(item({ payload = "bg" .. i, priority = 3, ttl = 60 })) end
    s:advance(1.5)
    local backgroundSent = #s.sent
    equal(backgroundSent <= 6, true, "background whispers stop before exhausting the shared budget")
    s.Outbound:Send(item({ payload = "control" }))
    s:advance(0.2)
    equal(s.sent[#s.sent].payload, "control", "reserved tokens remain available for control traffic")
    s:advance(30)
    equal(#s.sent, 13, "background traffic drains at the refill rate")
    local spacing = s.sent[13].at - s.sent[8].at
    equal(spacing >= 3.9, true, "background traffic is limited to about one whisper per second")

    -- Throttle results are retried instead of dropped or treated as fatal.
    local outcome
    s = setup({ 3, 0 })
    s.Outbound:Send(item({ onResult = function(status) outcome = status end }))
    s:advance(0.2)
    equal(#s.sent, 1)
    equal(outcome, nil, "a throttled send is not reported as failed")
    s:advance(3)
    equal(#s.sent, 2, "throttled send is retried after backoff")
    equal(outcome, "sent")
    equal(s.FD.Debug.traffic["ForeverDuel2 WHISPER"].totals.throttled, 1, "throttle results are counted")

    -- PARTY route errors fall back to WHISPER once.
    s = setup({ 5, 0 })
    s.Outbound:Send(item({ channel = "PARTY", onResult = function(status) outcome = status end }))
    s:advance(0.5)
    equal(#s.sent, 2)
    equal(s.sent[1].channel, "PARTY")
    equal(s.sent[2].channel, "WHISPER", "NotInGroup falls back to the exact whisper target")
    equal(s.sent[2].target, "Beta-Forever")
    equal(outcome, "sent")
    s = setup({ 4, 0, 0 })
    s.Outbound:Send(item({ channel = "PARTY" }))
    s:advance(0.5)
    s.Outbound:Send(item({ channel = "PARTY", payload = "second" }))
    s:advance(0.5)
    equal(s.sent[3].channel, "WHISPER", "InvalidChatType disables that route for the session")

    -- Terminal results are reported, expired and obsolete items are dropped.
    s = setup({ 12 })
    s.Outbound:Send(item({ onResult = function(status) outcome = status end }))
    s:advance(0.5)
    equal(outcome, "failed", "TargetOffline is terminal")
    equal(#s.sent, 1, "terminal results are not retried")
    s = setup({ 3, 3, 3, 3, 3, 3 })
    s.Outbound:Send(item({ ttl = 5, onResult = function(status) outcome = status end }))
    s:advance(10)
    equal(outcome, "expired", "an item that cannot be sent before its deadline expires")
    s = setup()
    local current = true
    s.Outbound:Send(item({ isCurrent = function() return current end, onResult = function(status) outcome = status end }))
    current = false
    s:advance(0.5)
    equal(#s.sent, 0, "obsolete packets are never sent")
    equal(outcome, "dropped")

    -- Keyed items replace a queued predecessor instead of piling up.
    s = setup()
    s.Outbound:Send(item({ key = "status", payload = "old", priority = 2 }))
    s.Outbound:Send(item({ key = "status", payload = "new", priority = 2 }))
    s:advance(1)
    equal(#s.sent, 1, "a keyed state packet is coalesced")
    equal(s.sent[1].payload, "new")

    -- Route selection at drain time.
    s = setup()
    local grouped = true
    s.Outbound:Send(item({ route = function() if grouped then return "PARTY" end return "WHISPER", "Beta-Forever" end }))
    s:advance(0.2)
    equal(s.sent[1].channel, "PARTY", "route is chosen when the packet is drained")

    -- Synchronous terminal packets bypass the queue.
    s = setup({ 5, 0 })
    local status = s.Outbound:SendNow(item({ channel = "PARTY", payload = "cancel" }))
    equal(status, "sent", "synchronous send reports the native result")
    equal(#s.sent, 2, "synchronous send falls back to WHISPER immediately")
    equal(#s.timers, 0, "synchronous send schedules nothing")

    -- Drop removes queued items for an ended match.
    s = setup()
    local owner = {}
    s.Outbound:Send(item({ owner = owner }))
    s.Outbound:Send(item({ payload = "other" }))
    s.Outbound:Drop(function(queued) return queued.owner == owner end)
    s:advance(1)
    equal(#s.sent, 1)
    equal(s.sent[1].payload, "other")
    equal(s.Outbound:Pending(), 0)
end
