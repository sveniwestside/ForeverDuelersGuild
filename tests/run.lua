-- Run from the repository root with Lua 5.1 or `python tests/run.py`.
local assertions, suites = 0, 0
local function equal(actual, expected, label)
    assertions = assertions + 1
    if actual ~= expected then
        error((label or "assertion") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local paths = TEST_LUA_FILES or {}
if not TEST_LUA_FILES then
    local windows = package.config:sub(1, 1) == "\\"
    local command = windows and "dir /b /s ForeverDuel\\*.lua tests\\*.lua"
        or "find ForeverDuel tests -type f -name '*.lua'"
    local listing = assert(io.popen(command, "r"))
    for path in listing:lines() do paths[#paths + 1] = path end
    listing:close()
end
assert(#paths > 0, "No Lua files found; run this command from the repository root.")
for _, path in ipairs(paths) do
    assert(loadfile(path)) -- Includes WoW-bound modules without executing their APIs.
end
print(string.format("%s: compiled %d files", _VERSION, #paths))

local pureModules = { "Constants", "Locale", "Protocol", "Rating", "Database", "History", "Results", "Duel", "QueueProtocol", "Venues", "Queue" }
local function newNamespace()
    local namespace = {}
    for _, name in ipairs(pureModules) do
        assert(loadfile("ForeverDuel/" .. name .. ".lua"))("ForeverDuel", namespace)
    end
    return namespace
end

local specifications = {}
for _, path in ipairs(paths) do
    if path:match("_spec%.lua$") then specifications[#specifications + 1] = path end
end
table.sort(specifications)
for _, path in ipairs(specifications) do
    local before = assertions
    local suite = assert(loadfile(path))()
    assert(type(suite) == "function", path .. " must return a test function")
    local ok, err = pcall(suite, newNamespace(), equal, newNamespace)
    if not ok then error(path .. " failed:\n" .. tostring(err), 0) end
    suites = suites + 1
    print(string.format("PASS %s (%d assertions)", path, assertions - before))
end
assert(suites > 0, "No test suites found")
print(string.format("PASS %d suites, %d assertions", suites, assertions))
