-- German localization stays complete: every English key the addon looks up
-- has a deDE entry with the same placeholders, no deDE entry is stale, and
-- the runtime lookup formats German while falling back to English.
--
-- Keys are found by reading the sources the TOC loads: literal arguments of
-- FD.L[...] / L(...) / Locale:Format(...) / the Profile format() and stamp()
-- wrappers and RegisterCommand help texts, the named tables whose entries
-- reach FD.L indirectly, and a short list of literals passed through
-- variables. A new string that bypasses all three needs an entry below.
return function(FD, equal, newNamespace)
    local function read(path)
        local file = assert(io.open(path, "rb"))
        local text = file:read("*a")
        file:close()
        return text
    end

    -- Minimal Lua 5.1 tokenizer: names, numbers, operators and decoded
    -- strings with line numbers; comments are skipped.
    local ESCAPES = { n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v",
        ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n" }
    local function tokenize(source)
        local tokens, i, n, line = {}, 1, #source, 1
        local function push(kind, value) tokens[#tokens + 1] = { kind = kind, value = value, line = line } end
        local function advance(finish)
            local _, breaks = source:sub(i, finish):gsub("\n", "")
            line, i = line + breaks, finish + 1
        end
        while i <= n do
            local c = source:sub(i, i)
            if c:match("%s") then advance(i)
            elseif source:sub(i, i + 1) == "--" then
                local level = source:match("^%-%-%[(=*)%[", i)
                local finish
                if level then finish = select(2, source:find("]" .. level .. "]", i, true)) or n
                else finish = (source:find("\n", i, true) or n + 1) - 1 end
                advance(finish)
            elseif c == '"' or c == "'" then
                local parts, j = {}, i + 1
                while j <= n and source:sub(j, j) ~= c do
                    local d = source:sub(j, j)
                    if d == "\\" then
                        local digits = source:match("^%d%d?%d?", j + 1)
                        if digits then parts[#parts + 1], j = string.char(tonumber(digits)), j + 1 + #digits
                        else
                            local e = source:sub(j + 1, j + 1)
                            parts[#parts + 1], j = ESCAPES[e] or e, j + 2
                        end
                    else parts[#parts + 1], j = d, j + 1 end
                end
                push("string", table.concat(parts))
                advance(j)
            elseif source:match("^%[=*%[", i) then
                local level = source:match("^%[(=*)%[", i)
                local start = i + #level + 2
                local close = source:find("]" .. level .. "]", start, true) or n + 1
                push("string", (source:sub(start, close - 1):gsub("^\r?\n", "")))
                advance(close + #level + 1)
            elseif c:match("[%a_]") then
                local word = source:match("^[%w_]+", i)
                push("name", word)
                i = i + #word
            elseif c:match("%d") then
                local number = source:match("^0[xX]%x+", i) or source:match("^%d+%.?%d*", i)
                push("number", number)
                i = i + #number
            else
                local op = source:match("^%.%.%.", i) or source:match("^%.%.", i) or source:match("^[=~<>]=", i) or c
                push("op", op)
                i = i + #op
            end
        end
        return tokens
    end

    local required, order = {}, {}
    local function need(key, where)
        if not required[key] then required[key], order[#order + 1] = {}, key end
        table.insert(required[key], where)
    end

    -- (a) Literal keys: string literals at the top level of the key argument,
    -- including both branches of `cond and "A" or "B"`. Operands of == / ~=
    -- (`bracket == "MAX_LEVEL" and "Max level"`) are not keys.
    local CALLS = {
        L = { open = { ["["] = true, ["("] = true }, argument = 1 },
        Format = { open = { ["("] = true }, argument = 1 },
        format = { open = { ["("] = true }, argument = 1 }, -- Profile's wrapper, never string.format
        stamp = { open = { ["("] = true }, argument = 1 },  -- Profile's localized date patterns
        RegisterCommand = { open = { ["("] = true }, argument = 3 },
    }
    local OPENS = { ["function"] = true, ["if"] = true, ["do"] = true, ["repeat"] = true }
    local CLOSES = { ["end"] = true, ["until"] = true }
    local BRACKETS = { ["("] = 1, ["["] = 1, ["{"] = 1, [")"] = -1, ["]"] = -1, ["}"] = -1 }
    local function comparison(token) return token ~= nil and (token.value == "==" or token.value == "~=") end
    local function scanCalls(tokens, file)
        for k = 1, #tokens - 1 do
            local token, previous, opener = tokens[k], tokens[k - 1], tokens[k + 1]
            local call = token.kind == "name" and CALLS[token.value]
            if call and opener.kind == "op" and call.open[opener.value]
                and not (previous and previous.kind == "name" and (previous.value == "function" or previous.value == "local"))
                and not (token.value == "format" and previous and (previous.value == "." or previous.value == ":")) then
                local depth, argument, j = 0, 1, k + 2
                while j <= #tokens do
                    local t = tokens[j]
                    local step = t.kind == "op" and BRACKETS[t.value]
                        or t.kind == "name" and (OPENS[t.value] and 1 or CLOSES[t.value] and -1)
                    if step == -1 and depth == 0 then break end
                    if step then depth = depth + step
                    elseif t.kind == "op" and t.value == "," and depth == 0 then
                        argument = argument + 1
                        if argument > call.argument then break end
                    elseif t.kind == "string" and depth == 0 and argument == call.argument
                        and not comparison(tokens[j - 1]) and not comparison(tokens[j + 1]) then
                        need(t.value, file .. ":" .. t.line)
                    end
                    j = j + 1
                end
            end
        end
    end

    -- (b) Named tables whose string values are looked up through FD.L or
    -- used as Format patterns (all their keys are identifiers or indexes).
    local TABLES = {
        ["Duel.lua"] = { "reasons" },                         -- Duel:ReasonText, both columns
        ["Profile.lua"] = { "BRACKET_NAMES", "STREAKS", "columns" },
        ["Queue.lua"] = { "CANCEL_TEXT", "messages" },         -- CancelText, SearchDiagnostic
        ["QueueCore.lua"] = { "REJECTIONS", "HELP" },
        ["QueueUI.lua"] = { "SCOPE_NAMES", "RULESET_NAMES", "STATE_NAMES" },
        ["Zone.lua"] = { "CLASS_NAMES", "SORT_OPTIONS" },
    }
    -- Literals that reach FD.L through a variable; each must still appear
    -- in the named file, so a removed path cannot leave a stale entry.
    local INDIRECT = {
        -- Unrate's text variable; Begin's reasons, printed by Wow:ReportUntracked.
        ["Duel.lua"] = { "This duel is no longer rated: %s.", "your character could not be identified",
            "the requested player could not be identified", "the duel history is unavailable",
            "WIN", "LOSS" }, -- match.result in UI:History
        -- Untracked reasons, printed through FD.L[attempt.reason].
        ["Wow.lua"] = { "another duel request is still pending", "the requested player could not be identified",
            "the requested name matches several players", "rated tracking could not start" },
        -- Broadcast reasons and FD.Outbound delivery states in the Presence and
        -- QueueTransport status lines (both pass the state through FD.L).
        ["Presence.lua"] = { "update", "heartbeat", "retry", "experiment", "sent", "failed" },
        ["Outbound.lua"] = { "expired", "dropped" },
        -- The stat card titles iterate an inline table.
        ["Profile.lua"] = { "CURRENT RATING", "WINS / LOSSES", "WIN RATE", "BEST RATING" },
    }
    local function tableStrings(tokens, name)
        for k = 1, #tokens - 2 do
            local t = tokens[k]
            if t.kind == "name" and t.value == name and tokens[k + 1].value == "=" and tokens[k + 2].value == "{" then
                local depth, strings = 0, {}
                for j = k + 2, #tokens do
                    local entry = tokens[j]
                    if entry.kind == "op" and entry.value == "{" then depth = depth + 1
                    elseif entry.kind == "op" and entry.value == "}" then
                        depth = depth - 1
                        if depth == 0 then return strings end
                    elseif entry.kind == "string" then strings[#strings + 1] = entry.value end
                end
            end
        end
    end

    local files = {}
    for line in read("ForeverDuel/ForeverDuel.toc"):gmatch("[^\r\n]+") do
        local file = line:match("^%s*([%w_]+%.lua)%s*$")
        if file and not file:match("^Locale") then files[#files + 1] = file end
    end
    equal(#files >= 25, true, "TOC lists the addon modules")
    for _, file in ipairs(files) do
        local tokens = tokenize(read("ForeverDuel/" .. file))
        scanCalls(tokens, file)
        for _, name in ipairs(TABLES[file] or {}) do
            local strings = tableStrings(tokens, name)
            equal(strings ~= nil and #strings > 0, true, file .. " still defines table " .. name)
            for _, key in ipairs(strings or {}) do need(key, file .. ":" .. name) end
        end
        if INDIRECT[file] then
            local literals = {}
            for _, t in ipairs(tokens) do if t.kind == "string" then literals[t.value] = true end end
            for _, key in ipairs(INDIRECT[file]) do
                equal(literals[key], true, file .. " still uses the indirect key: " .. key)
                need(key, file .. ":indirect")
            end
        end
    end
    -- The scanner itself: each extraction path finds a known key, and a
    -- compared code is not mistaken for a key.
    for _, key in ipairs({ "Keep unrated", "List all commands.", "Lvl %d - %s", "%d.%m.%Y %H:%M",
        "Rated LOSS vs %s: %+d rating (%d).", "Current streak: %d wins", "they reloaded or logged out",
        "Whole ruleset", "Druid", "This duel is no longer rated: %s.", "Max level" }) do
        equal(required[key] ~= nil, true, "scanner finds " .. key)
    end
    equal(required.MAX_LEVEL, nil, "comparison operands are not keys")
    equal(#order > 450, true, "scanner finds the addon's user-facing keys")

    -- The German table as registered, and as written (duplicate keys in a
    -- table constructor would silently overwrite each other).
    assert(loadfile("ForeverDuel/Locale_deDE.lua"))("ForeverDuel", FD)
    local german = FD.Locale.translations.deDE
    equal(type(german), "table", "deDE translations registered")
    local written, duplicates, count = {}, {}, 0
    local source = tokenize(read("ForeverDuel/Locale_deDE.lua"))
    for k = 1, #source - 4 do
        if source[k].value == "[" and source[k + 1].kind == "string" and source[k + 2].value == "]"
            and source[k + 3].value == "=" and source[k + 4].kind == "string" then
            local key = source[k + 1].value
            if written[key] then duplicates[#duplicates + 1] = key end
            written[key], count = true, count + 1
        end
    end
    local registered = 0
    for _ in pairs(german) do registered = registered + 1 end
    equal(table.concat(duplicates, "\n"), "", "no duplicate deDE keys")
    equal(registered, count, "every written deDE entry is a registered non-empty string")

    -- (a)+(b) coverage: every required key has a German entry.
    local missing = {}
    for _, key in ipairs(order) do
        if german[key] == nil then missing[#missing + 1] = key .. "  <- " .. table.concat(required[key], ", ") end
    end
    equal(table.concat(missing, "\n"), "", "keys without a deDE translation")

    -- (d) No stale entries. Allowlist: key = reason, for a key the scanner
    -- cannot see; keep it short.
    local ALLOWED = {}
    local stale = {}
    for key in pairs(german) do
        if not required[key] and not ALLOWED[key] then stale[#stale + 1] = key end
    end
    table.sort(stale)
    equal(table.concat(stale, "\n"), "", "deDE entries no source string uses")

    -- (c) Placeholders keep their order and kind; slash commands, the addon
    -- and channel names, escape pipes and line breaks are unchanged.
    local function sequence(text, pattern)
        local result = {}
        for match in text:gmatch(pattern) do result[#result + 1] = match end
        return table.concat(result, " ")
    end
    local function sorted(text, pattern)
        local result = {}
        for match in text:gmatch(pattern) do result[#result + 1] = match end
        table.sort(result)
        return table.concat(result, " ")
    end
    local PLACEHOLDER = "%%[-+ #0]*%d*%.?%d*[%a%%]"
    local keys = {}
    for key in pairs(german) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local value = german[key]
        equal(sequence(value, PLACEHOLDER), sequence(key, PLACEHOLDER), "placeholders of deDE[" .. key .. "]")
        equal(sorted(value, "/%a+"), sorted(key, "/%a+"), "slash commands of deDE[" .. key .. "]")
        local _, pipes = value:gsub("|", "")
        local _, sourcePipes = key:gsub("|", "")
        local _, breaks = value:gsub("\n", "")
        local _, sourceBreaks = key:gsub("\n", "")
        local _, names = value:gsub("ForeverDuel", "")
        local _, sourceNames = key:gsub("ForeverDuel", "")
        equal(pipes .. "/" .. breaks .. "/" .. names, sourcePipes .. "/" .. sourceBreaks .. "/" .. sourceNames,
            "pipes, line breaks and addon names of deDE[" .. key .. "]")
    end

    -- Fixed-width buttons (widths from the Create() layouts) keep their
    -- German label within roughly 6 px per character of GameFontNormal.
    local BUTTONS = {
        ["Accept as RATED duel"] = 200, ["Accept RATED duel"] = 200, ["Propose RATED duel"] = 200,
        ["Keep unrated"] = 200, ["Players in zone"] = 156, ["Rated queue"] = 104, ["Close"] = 72,
        ["Leveling"] = 124, ["Max level"] = 124, ["Legacy"] = 124, ["Previous"] = 100, ["Next"] = 100,
        ["Your record"] = 120, ["Join queue"] = 170, ["Leave queue"] = 170, ["Show waypoint"] = 170,
        ["Request duel"] = 170, ["Leave group"] = 170, ["Save tested place"] = 200, ["Refresh"] = 92,
        ["Duel"] = 96, ["Reset filters"] = 250, ["Rating: All"] = 233, ["Rated eligible: All"] = 215,
        ["Rated eligible: Only"] = 215, ["Zone"] = 230, ["Continent"] = 230, ["Whole ruleset"] = 230,
    }
    local function characters(text) return select(2, text:gsub("[^\128-\191]", "")) end
    for key, width in pairs(BUTTONS) do
        local budget = math.floor((width - 12) / 6)
        equal(characters(key) <= budget and characters(german[key] or "") <= budget, true,
            "button label fits " .. width .. " px: " .. key .. " / " .. tostring(german[key]))
    end

    -- (e) Runtime: German through FD.L and Locale:Format, table-driven texts
    -- through the real modules, English for keys without a translation.
    FD.Locale.current = "deDE"
    equal(FD.L["Keep unrated"], "Ungewertet lassen", "button label in German")
    equal(FD.Locale:Format("RATED duel vs %s (win %+d / loss %+d).", "Thrall", 16, -16),
        "GEWERTETES Duell gegen Thrall (Sieg +16 / Niederlage -16).", "signed placeholders")
    equal(FD.Locale:Format("PONG from %s via %s: %.2f s round trip", "Jaina", "WHISPER", 0.25),
        "PONG von Jaina über WHISPER: 0.25 s Laufzeit", "precision placeholder")
    equal(FD.Locale:Format("%s  /  Duration: %d:%02d\n%s  /  %s", "K.o.", 1, 5, "05.10.2026 14:33", "Leveln"),
        "K.o.  /  Dauer: 1:05\n05.10.2026 14:33  /  Leveln", "padded placeholder and line break")
    equal(FD.Locale:Format("This duel is no longer rated: %s.", FD.Duel:ReasonText({ reason = "combat" })),
        "Dieses Duell ist nicht mehr gewertet: Kampf begonnen.", "own reason from the reasons table")
    equal(FD.Duel:ReasonText({ reason = "peer:spec" }), "Die Spezialisierung deines Gegners hat sich geändert",
        "peer reason uses the second column")
    equal(FD.Duel:ReasonText({ reason = "peer:future_code" }), "Das Addon deines Gegners hat das gewertete Spiel beendet",
        "unknown peer reason")
    equal(FD.Queue:CancelText("PEER_SILENT", true, {}, "Thrall"),
        "Der gegnerische Client hat abgebrochen, weil dein Client nicht mehr antwortet."
            .. " Melde dich erneut an, um ein weiteres Match zu spielen.", "peer cancellation clause and outcome")
    equal(FD.Queue:CancelText("BUSY", false, { requeue = true }, "Thrall"),
        "Thrall ist bereits in einem anderen Match. Die Suche läuft erneut; deine Wartezeit bleibt erhalten.", "local cancellation and outcome")
    equal(FD.L["An English sentence nobody translated."], "An English sentence nobody translated.", "unknown key falls back")
    equal(FD.Locale:Format("Untranslated %d of %s.", 3, "four"), "Untranslated 3 of four.", "unknown pattern formats in English")
    FD.Locale.current = "enUS"
    equal(FD.L["Keep unrated"], "Keep unrated", "English client shows the English source")

    -- A German client without the translation file still shows English.
    local bare = newNamespace()
    bare.Locale.current = "deDE"
    equal(bare.L["Keep unrated"], "Keep unrated", "missing deDE table falls back to English")
end
