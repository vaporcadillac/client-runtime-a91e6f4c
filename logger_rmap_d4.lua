-- Remote Map Dump Logger d4 | Volt autoexec | Luau
-- Run: deployed per-account by the router (progression capture build).
-- Out: remote_dump_<userId>.json + remote_dump_<userId>.log in workspace.
-- Passive: hooks __namecall on Instance only. Never touches
--          other scripts' tables. No network egress.
--
-- d4 changes vs d3:
--   * 24h window (full progression run)
--   * Smart capture: high-frequency loop remotes (orbs collect, pet
--     joins, routing, position/perf telemetry) get sampled after the
--     first 50 sightings; rare/progression remotes always fully logged
--   * Rolling JSON summary keeps first-seen args for every remote

local env = getgenv()

if env.__REMOTE_DUMP_RUNNING then
    warn("[RMapD] Already running.")
    return
end

env.__REMOTE_DUMP_RUNNING = true

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local SESSION_SECONDS = 60 * 60 * 24
local FLUSH_EVERY = 5.0
local MAX_STR = 120
local MAX_DEPTH = 3
local NOISY_SAMPLE_AFTER = 50
local NOISY_LOG_EVERY = 25

-- remotes that fire continuously in the farm loop; sample them once
-- the shape is established instead of logging every single call
local NOISY_PATTERNS = {
    "orbs",          -- Orbs: Collect
    "joinpet",       -- Breakables_JoinPetBulk
    "cq_route",      -- pet movement routing
    "sendposition",  -- client position sync
    "performance",   -- fps telemetry
}

local startedAt = os.clock()
local baseName = "remote_dump_" .. tostring(LocalPlayer and LocalPlayer.UserId or 0)
local logFile = baseName .. ".log"
local jsonFile = baseName .. ".json"

local function executorFunction(name)
    local candidate = rawget(env, name) or rawget(_G, name)
    return type(candidate) == "function" and candidate or nil
end

local readFile = executorFunction("readfile")
local writeFile = executorFunction("writefile")
local appendFile = executorFunction("appendfile")
local isFile = executorFunction("isfile")

if not writeFile then
    warn("[RMapD] No filesystem API; dump disabled.")
    env.__REMOTE_DUMP_RUNNING = false
    return
end

local buffer = {}
local stats = {}   -- [callKey] = { count, firstAt, lastAt, method, path }
local argSamples = {} -- [callKey] = serialized args from first sighting
local order = {}

local function serialize(value, depth)
    depth = depth or 0

    if type(value) == "string" then
        local s = value:gsub("%c", " ")
        return #s > MAX_STR and string.format("%q", s:sub(1, MAX_STR) .. "…") or string.format("%q", s)
    elseif type(value) == "number" or type(value) == "boolean" then
        return tostring(value)
    elseif type(value) == "Instance" then
        return "Instance(" .. value:GetFullName() .. ")"
    elseif type(value) == "table" and depth < MAX_DEPTH then
        local parts = {}
        local count = 0

        for k, v in pairs(value) do
            count += 1
            if count > 24 then
                table.insert(parts, "…")
                break
            end
            table.insert(parts, tostring(k) .. "=" .. serialize(v, depth + 1))
        end

        return "{" .. table.concat(parts, ", ") .. "}"
    end

    return type(value)
end

local hook = executorFunction("hookmetamethod")
    or (type(hookmetamethod) == "function" and hookmetamethod or nil)
local getMethod = executorFunction("getnamecallmethod")
    or (type(getnamecallmethod) == "function" and getnamecallmethod or nil)

if not hook or not getMethod then
    warn("[RMapD] Executor lacks hookmetamethod; dump disabled.")
    env.__REMOTE_DUMP_RUNNING = false
    return
end

local function record(instance, method, args)
    local ok = pcall(function()
        local className = instance.ClassName

        if className ~= "RemoteFunction" and className ~= "RemoteEvent"
            and className ~= "UnreliableRemoteEvent"
        then
            return
        end

        local path
        do
            local okPath, fullName = pcall(function() return instance:GetFullName() end)
            path = okPath and fullName or tostring(instance)
        end

        local now = os.clock()
        local key = method .. "|" .. path
        local entry = stats[key]

        if not entry then
            entry = { count = 0, firstAt = now, method = method, path = path, className = className }
            stats[key] = entry
            table.insert(order, key)
            argSamples[key] = select(1, serialize(args))
        end

        entry.count += 1
        entry.lastAt = now

        local isNoisy

        if not entry.classified then
            local normalizedPath = string.lower(path:gsub("[^%w]", ""))
            entry.classified = true
            isNoisy = false

            for _, pattern in ipairs(NOISY_PATTERNS) do
                if string.find(normalizedPath, pattern, 1, true) then
                    entry.noisy = true
                    isNoisy = true
                    break
                end
            end

            if not isNoisy then
                entry.noisy = false
            end
        else
            isNoisy = entry.noisy == true
        end

        local shouldLog = true

        if isNoisy and entry.count > NOISY_SAMPLE_AFTER then
            shouldLog = (entry.count - NOISY_SAMPLE_AFTER) % NOISY_LOG_EVERY == 0
        end

        if shouldLog and #buffer < 4000 then
            table.insert(buffer, string.format(
                "%.3f %s %s %s",
                now - startedAt,
                className,
                method,
                path
            ))
        end
    end)

    if not ok and #buffer < 4000 then
        table.insert(buffer, "serialize-error " .. tostring(method))
    end
end

-- Capture the ORIGINAL __namecall BEFORE hooking, straight from the
-- metatable. We never rely on hookmetamethod's return value (Volt's
-- returns nothing) and never call an uncaptured original — that was
-- the line-186/191 bug, twice.
local wrap = type(newcclosure) == "function" and newcclosure or function(f) return f end
local originalNamecall = nil

do
    local captured = false

    if type(getrawmetatable) == "function" then
        local ok, gameMeta = pcall(getrawmetatable, game)

        if ok and type(gameMeta) == "table" and type(gameMeta.__namecall) == "function" then
            originalNamecall = gameMeta.__namecall
            captured = true
        end
    end

    if captured then
        -- Plain Lua closure, NOT newcclosure: C closures cannot yield, and
        -- any yielding namecall (Wait/WaitForChild) crossing the hook would
        -- die at the metamethod boundary. A normal closure propagates
        -- yields correctly.
        hook(game, "__namecall", function(self, ...)
            record(self, getMethod(), { ... })
            return originalNamecall(self, ...)
        end)
        print("[RMapD] Hook installed; original __namecall captured from metatable.")
    else
        -- Refuse to hook: a logger that cannot guarantee call pass-through
        -- must never install itself. Game runs clean; dump is skipped.
        env.__REMOTE_DUMP_RUNNING = false
        warn("[RMapD] Could not capture original __namecall safely; logger disabled without hooking.")
        return
    end
end

-- FireServer goes through __namecall too, but belt-and-suspenders for
-- executors where firesignal paths differ: hook __index is intentionally
-- NOT hooked (passive-only promise).

print(string.format("[RMapD] Recording remote calls for %.0f minutes.", SESSION_SECONDS / 60))

task.spawn(function()
    if not game:IsLoaded() then game.Loaded:Wait() end

    local lastFlush = os.clock()

    while os.clock() - startedAt < SESSION_SECONDS do
        task.wait(FLUSH_EVERY)

        if #buffer > 0 then
            local chunk = table.concat(buffer, "\n") .. "\n"
            buffer = {}

            if appendFile then
                if not (isFile and isFile(logFile)) then
                    pcall(writeFile, logFile, "")
                end
                pcall(appendFile, logFile, chunk)
            else
                local existing = ""
                if isFile and isFile(logFile) then
                    local ok, data = pcall(readFile, logFile)
                    if ok then existing = data end
                end
                pcall(writeFile, logFile, existing .. chunk)
            end
        end

        -- rolling json summary so a crash never loses the map
        local summary = {}
        for i, key in ipairs(order) do
            if i > 800 then break end
            local entry = stats[key]
            summary[i] = {
                method = entry.method,
                class = entry.className,
                path = entry.path,
                count = entry.count,
                firstAt = entry.firstAt,
                lastAt = entry.lastAt,
                noisy = entry.noisy == true or nil,
                sampleArgs = argSamples[key],
            }
        end

        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, {
            userId = LocalPlayer and LocalPlayer.UserId or 0,
            placeVersion = game.PlaceVersion,
            startedAt = startedAt,
            capturedSeconds = os.clock() - startedAt,
            remotes = summary,
        })

        if ok then
            pcall(writeFile, jsonFile, encoded)
        end

        lastFlush = os.clock()
    end

    warn("[RMapD] Session window complete. Remove this file from autoexec.")
end)
