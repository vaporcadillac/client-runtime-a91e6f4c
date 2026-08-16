local env = getgenv()
local MODULE_BUILD = "giftbag-opener-1.4"

if env.GGIFTBAG_ENABLED == false then
    return
end

if env.__GIFTBAG_OPENER_RUNNING then
    warn("[Giftbag] Opener is already running.")
    return
end

env.__GIFTBAG_OPENER_RUNNING = true
env.STOP_GIFTBAG_OPENER = false
env.GGIFTBAG_BUILD = MODULE_BUILD

task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    task.wait(3)

    local HttpService = game:GetService("HttpService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Players = game:GetService("Players")
    local LocalPlayer = Players.LocalPlayer
    local startedAt = os.clock()

    local Library = ReplicatedStorage:WaitForChild("Library")
    local Client = Library:WaitForChild("Client")
    local Save = require(Client:WaitForChild("Save"))

    local function numberSetting(name, default)
        return tonumber(env[name]) or default
    end

    local SETTINGS = {
        INTERVAL = math.max(0.5, numberSetting("GGIFTBAG_INTERVAL", 1.2)),
        MIN_INTERVAL = math.max(0.5, numberSetting("GGIFTBAG_MIN_INTERVAL", 0.8)),
        MAX_INTERVAL = math.max(0.5, numberSetting("GGIFTBAG_MAX_INTERVAL", 3.0)),
        REMOTE_NAME = tostring(env.GGIFTBAG_REMOTE_NAME or "GiftBag_Open"),
        ARG_MODE = string.lower(tostring(env.GGIFTBAG_ARG_MODE or "id")),
        MAX_BATCH = math.max(1, math.floor(numberSetting("GGIFTBAG_MAX_BATCH", 50))),
        BATCH_GROW_AFTER = math.max(5, math.floor(numberSetting("GGIFTBAG_BATCH_GROW_AFTER", 10))),
        DRAIN_THRESHOLD = math.max(25, math.floor(numberSetting("GGIFTBAG_DRAIN_THRESHOLD", 60))),
        REMOTE_TIMEOUT = math.max(3, numberSetting("GGIFTBAG_REMOTE_TIMEOUT", 8)),
        RESOLVE_TIMEOUT = math.max(5, numberSetting("GGIFTBAG_RESOLVE_TIMEOUT", 60)),
        VERIFY_EVERY = math.max(5, math.floor(numberSetting("GGIFTBAG_VERIFY_EVERY", 20))),
        BACKOFF_BASE = math.max(1, numberSetting("GGIFTBAG_BACKOFF_BASE", 2)),
        BACKOFF_MAX = math.max(5, numberSetting("GGIFTBAG_BACKOFF_MAX", 30)),
        CIRCUIT_AFTER = math.max(2, math.floor(numberSetting("GGIFTBAG_CIRCUIT_AFTER", 5))),
        CIRCUIT_INITIAL_DELAY = math.max(10, numberSetting("GGIFTBAG_CIRCUIT_INITIAL_DELAY", 30)),
        CIRCUIT_MAX_DELAY = math.max(30, numberSetting("GGIFTBAG_CIRCUIT_MAX_DELAY", 300)),
        STOP_AFTER_FAILS = math.max(5, math.floor(numberSetting("GGIFTBAG_STOP_AFTER_FAILS", 12))),
        JITTER_MAX = math.max(0, math.min(1, numberSetting("GGIFTBAG_JITTER_MAX", 0.2))),
        SPEEDUP_AFTER = math.max(20, math.floor(numberSetting("GGIFTBAG_SPEEDUP_AFTER", 50))),
        SPEEDUP_STEP = math.max(0.01, numberSetting("GGIFTBAG_SPEEDUP_STEP", 0.05)),
        SLOW_STEP = math.max(0.01, numberSetting("GGIFTBAG_SLOW_STEP", 0.2)),
        BACKLOG_ALERT = math.max(50, math.floor(numberSetting("GGIFTBAG_BACKLOG_ALERT", 200))),
        BACKLOG_ALERT_MINUTES = math.max(5, numberSetting("GGIFTBAG_BACKLOG_ALERT_MINUTES", 30)),
        EXTERNAL_TOLERANCE = math.max(1, math.floor(numberSetting("GGIFTBAG_EXTERNAL_TOLERANCE", 5))),
        WEBHOOK_STATUS_SECONDS = math.max(
            3 * 60 * 60,
            numberSetting("GGIFTBAG_WEBHOOK_STATUS_SECONDS", 3 * 60 * 60)
        ),
        VERBOSE = env.GGIFTBAG_VERBOSE == true,
        AUTO_REMOTE = env.GGIFTBAG_AUTO_REMOTE ~= false,
    }

    SETTINGS.MAX_INTERVAL = math.max(SETTINGS.MIN_INTERVAL, SETTINGS.MAX_INTERVAL)
    SETTINGS.CIRCUIT_MAX_DELAY = math.max(
        SETTINGS.CIRCUIT_INITIAL_DELAY,
        SETTINGS.CIRCUIT_MAX_DELAY
    )

    local currentInterval = math.max(
        SETTINGS.MIN_INTERVAL,
        math.min(SETTINGS.MAX_INTERVAL, SETTINGS.INTERVAL)
    )

    local dashboard = {
        state = "Booting",
        backlog = 0,
        backlogLarge = 0,
        interval = currentInterval,
        opened = 0,
        openedLarge = 0,
        rejected = 0,
        errors = 0,
        external = "No",
    }

    local function executorFunction(name)
        local candidate = rawget(env, name) or rawget(_G, name)
        return type(candidate) == "function" and candidate or nil
    end

    local readFile = executorFunction("readfile")
    local writeFile = executorFunction("writefile")

    local function normalize(value)
        return type(value) == "string"
            and string.lower(value):gsub("[^%w]", "")
            or ""
    end

    -- ==========================================
    -- WEBHOOK LAYER (rate-limited alerts, 2.1 pattern)
    -- ==========================================

    local function normalizeWebhookUrl(value)
        if type(value) ~= "string" then
            return nil
        end

        local url = value:match("%((https?://[^%)]+)%)")
            or value:match("(https?://%S+)")

        if not url then
            return nil
        end

        url = url:gsub("[>%)]+$", "")
        local lower = string.lower(url)
        local valid = string.find(lower, "PASTE_YOUR_DISCORD_WEBHOOK_HERE", 1, true) == 1
            or string.find(lower, "https://discordapp.com/api/webhooks/", 1, true) == 1
            or string.find(lower, "https://canary.discord.com/api/webhooks/", 1, true) == 1

        return valid and url or nil
    end

    local requestFunction = executorFunction("request")
        or executorFunction("http_request")

    if not requestFunction then
        local synTable = rawget(env, "syn") or rawget(_G, "syn")
        if type(synTable) == "table" and type(synTable.request) == "function" then
            requestFunction = synTable.request
        end
    end

    local webhookEnabled = env.GGIFTBAG_WEBHOOK_ENABLED == true
    local webhookUrl = normalizeWebhookUrl(
        env.GGIFTBAG_WEBHOOK_URL or env.GWEBHOOK_LINK
    )

    if webhookEnabled and not webhookUrl then
        webhookEnabled = false
        warn("[Giftbag] Webhook disabled: Discord URL missing or invalid.")
    elseif webhookEnabled and not requestFunction then
        webhookEnabled = false
        warn("[Giftbag] Webhook disabled: executor request API unavailable.")
    end

    local function formatInteger(value)
        local number = math.floor(tonumber(value) or 0)
        local sign = number < 0 and "-" or ""
        local digits = tostring(math.abs(number))
        local formatted = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()

        if string.sub(formatted, 1, 1) == "," then
            formatted = string.sub(formatted, 2)
        end

        return sign .. formatted
    end

    local function formatCompact(value)
        local number = tonumber(value)

        if not number then
            return "N/A"
        end

        local absolute = math.abs(number)
        local suffixes = {
            { 1e12, "T" },
            { 1e9, "B" },
            { 1e6, "M" },
            { 1e3, "K" },
        }

        for _, entry in ipairs(suffixes) do
            if absolute >= entry[1] then
                local compact = number / entry[1]
                local decimals = math.abs(compact) >= 100 and 0
                    or math.abs(compact) >= 10 and 1
                    or 2
                return string.format("%." .. decimals .. "f%s", compact, entry[2])
            end
        end

        return formatInteger(number)
    end

    local function formatDuration(seconds)
        seconds = math.max(0, math.floor(tonumber(seconds) or 0))
        local days = math.floor(seconds / 86400)
        local hours = math.floor((seconds % 86400) / 3600)
        local minutes = math.floor((seconds % 3600) / 60)
        local remainingSeconds = seconds % 60

        if days > 0 then
            return string.format("%dd %02dh %02dm %02ds", days, hours, minutes, remainingSeconds)
        end

        return string.format("%02dh %02dm %02ds", hours, minutes, remainingSeconds)
    end

    local function safeText(value, limit)
        local text = tostring(value == nil and "N/A" or value)

        if #text > limit then
            return string.sub(text, 1, math.max(1, limit - 3)) .. "..."
        end

        return text
    end

    local function webhookField(name, value, inline)
        return {
            name = safeText(name, 256),
            value = safeText(value, 1024),
            inline = inline == true,
        }
    end

    local webhookQueue = {}
    local webhookWorkerRunning = false
    local webhookFailureWarned = false
    local alertLastSentAt = {}
    local alertMinGapSeconds = math.max(0, numberSetting("GGIFTBAG_WEBHOOK_ALERT_MIN_GAP", 60))

    local function responseStatus(response)
        return type(response) == "table"
            and tonumber(
                response.StatusCode
                    or response.Status
                    or response.status_code
                    or response.status
            )
            or nil
    end

    local function deliverWebhook(payload)
        local encodedOk, body = pcall(HttpService.JSONEncode, HttpService, payload)

        if not encodedOk then
            return false
        end

        for attempt = 1, 2 do
            local ok, response = pcall(requestFunction, {
                Url = webhookUrl,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = body,
            })

            if ok then
                local status = responseStatus(response)

                if status == nil or (status >= 200 and status < 300) then
                    return true
                end

                if status == 429 and attempt == 1 then
                    task.wait(2)
                else
                    return false
                end
            elseif attempt == 1 then
                task.wait(1)
            else
                return false
            end
        end

        return false
    end

    local startWebhookWorker

    startWebhookWorker = function()
        if not webhookEnabled or webhookWorkerRunning then
            return
        end

        webhookWorkerRunning = true

        task.spawn(function()
            while #webhookQueue > 0 do
                local payload = table.remove(webhookQueue, 1)
                local delivered = deliverWebhook(payload)

                if not delivered and not webhookFailureWarned then
                    webhookFailureWarned = true
                    warn("[Giftbag] Webhook delivery failed.")
                elseif delivered then
                    webhookFailureWarned = false
                end

                if #webhookQueue > 0 then
                    task.wait(0.5)
                end
            end

            webhookWorkerRunning = false

            if #webhookQueue > 0 then
                startWebhookWorker()
            end
        end)
    end

    local function sendWebhook(options)
        if not webhookEnabled then
            return
        end

        options = options or {}

        if options.periodic ~= true then
            local title = tostring(options.title or "")
            local now = os.clock()
            local lastSentAt = tonumber(alertLastSentAt[title]) or 0

            if alertMinGapSeconds > 0 and now - lastSentAt < alertMinGapSeconds then
                return
            end

            alertLastSentAt[title] = now
        end

        local accountName = LocalPlayer and LocalPlayer.Name or "Unknown"
        local mentionUserId = tostring(env.GWEBHOOK_USERID or ""):match("^%d+$")
        local shouldMention = options.critical == true
            and env.GGIFTBAG_WEBHOOK_MENTION_ON_CRITICAL == true
            and mentionUserId ~= nil
        local fields = {
            webhookField(
                "Account",
                accountName .. " (`" .. tostring(LocalPlayer and LocalPlayer.UserId or 0) .. "`)",
                true
            ),
            webhookField("Runtime", formatDuration(os.clock() - startedAt), true),
        }

        for _, field in ipairs(options.fields or {}) do
            if #fields >= 25 then
                break
            end

            table.insert(fields, field)
        end

        local payload = {
            username = safeText("Giftbag Opener - " .. accountName, 80),
            content = shouldMention and ("<@" .. mentionUserId .. ">") or nil,
            allowed_mentions = shouldMention
                and { users = { mentionUserId } }
                or { parse = {} },
            embeds = {
                {
                    title = safeText(options.title or "Giftbag Update", 256),
                    description = safeText(options.description or "", 4096),
                    color = tonumber(options.color) or 3447003,
                    fields = fields,
                    footer = { text = "Opener " .. MODULE_BUILD },
                    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                },
            },
        }

        if #webhookQueue >= 20 then
            table.remove(webhookQueue, 1)
        end

        table.insert(webhookQueue, payload)
        startWebhookWorker()
    end

    -- ==========================================
    -- SAVE ACCESS (piggyback the pinata engine's cache)
    -- ==========================================

    local lastStandaloneFetchAt = 0

    local function getSaveData()
        local engineCache = env.GPINATA_SAVE_CACHE_DATA

        if type(engineCache) == "table" and type(engineCache.data) == "table" then
            return engineCache.data
        end

        if os.clock() - lastStandaloneFetchAt >= 2 then
            lastStandaloneFetchAt = os.clock()
            local ok, data = pcall(Save.Get)
            return ok and type(data) == "table" and data or nil
        end

        return nil
    end

    -- ==========================================
    -- BAG SCANNING
    -- ==========================================

    -- BAG_IDS pinned from remote-spy capture: the server identifies bags
    -- by exact display string ("Gift Bag" / "Large Gift Bag") passed as
    -- the first argument to GiftBag_Open.
    local BAG_IDS = {
        [normalize("Gift Bag")] = false,
        [normalize("Large Gift Bag")] = true,
    }

    -- UI-sanctioned open denominations, identical for both bag types
    -- (in-game UI confirmed: 1, 5, 25, 50, lock — lock is an inventory
    -- toggle, not a count). The opener's batch ladder steps through
    -- these values only, never synthesized counts like 3 or 10.
    local NORMAL_BATCHES = { 1, 5, 25, 50 }
    local LARGE_BATCHES = { 1, 5, 25, 50 }

    local function entryAmount(entry)
        if type(entry) ~= "table" then
            return 1
        end

        for _, key in ipairs({ "_am", "am", "amount", "Amount", "quantity", "Quantity", "_v", "value" }) do
            local amount = tonumber(entry[key])
            if amount and amount >= 1 then
                return math.floor(amount)
            end
        end

        return 1
    end

    -- Returns bags sorted large-first. Each entry is
    -- { uid, id, isLarge, stack } with stack = openable units left in
    -- our local view of that stack.
    local function scanBags(data)
        local bags = {}
        local inventory = type(data) == "table" and data.Inventory or nil
        local misc = type(inventory) == "table" and inventory.Misc or nil

        if type(misc) ~= "table" then
            return bags, 0, 0
        end

        local total, totalLarge, totalNormal = 0, 0, 0

        for uid, entry in pairs(misc) do
            local idString = type(entry) == "table"
                and (entry.id or entry._id or entry.ID or entry.Name or entry.name)
                or nil
            local key = normalize(idString)

            if BAG_IDS[key] ~= nil then
                local isLarge = BAG_IDS[key]
                local stack = entryAmount(entry)

                table.insert(bags, {
                    uid = tostring(uid),
                    id = tostring(idString),
                    isLarge = isLarge,
                    stack = stack,
                })

                total += stack

                if isLarge then
                    totalLarge += stack
                else
                    totalNormal += stack
                end
            end
        end

        table.sort(bags, function(a, b)
            if a.isLarge ~= b.isLarge then
                return a.isLarge
            end

            return a.uid < b.uid
        end)

        return bags, total, totalLarge, totalNormal
    end

    -- ==========================================
    -- REMOTE RESOLUTION
    -- ==========================================

    local OpenEndpoint = nil

    local function remoteAliases()
        local aliases = {}

        if SETTINGS.REMOTE_NAME ~= "" then
            table.insert(aliases, SETTINGS.REMOTE_NAME)
        end

        for _, alias in ipairs({
            "GiftBag_Open",
            "Gift Bag Open",
            "Open Gift Bag",
        }) do
            table.insert(aliases, alias)
        end

        local configured = env.GGIFTBAG_REMOTE_ALIASES

        if type(configured) == "table" then
            for _, alias in ipairs(configured) do
                if type(alias) == "string" and alias ~= "" then
                    table.insert(aliases, alias)
                end
            end
        end

        local unique, result = {}, {}

        for _, alias in ipairs(aliases) do
            local normalized = normalize(alias)

            if normalized ~= "" and not unique[normalized] then
                unique[normalized] = true
                table.insert(result, alias)
            end
        end

        return result
    end

    local function resolveOpenEndpoint()
        local network = ReplicatedStorage:FindFirstChild("Network")

        if not network then
            return nil
        end

        local aliases = remoteAliases()

        for index, alias in ipairs(aliases) do
            local candidate = network:FindFirstChild(alias, true)

            if candidate and (candidate:IsA("RemoteFunction") or candidate:IsA("RemoteEvent")) then
                return {
                    kind = candidate:IsA("RemoteFunction") and "function" or "event",
                    remote = candidate,
                    label = candidate:GetFullName(),
                    display = index == 1 and "Configured remote" or "Alias remote",
                }
            end
        end

        if not SETTINGS.AUTO_REMOTE then
            return nil
        end

        for _, candidate in ipairs(network:GetDescendants()) do
            if candidate:IsA("RemoteFunction") or candidate:IsA("RemoteEvent") then
                local normalized = normalize(candidate.Name)
                local mentionsBag = string.find(normalized, "giftbag", 1, true) ~= nil
                    or string.find(normalized, "gift", 1, true) ~= nil
                local looksConsumptive = string.find(normalized, "use", 1, true) ~= nil
                    or string.find(normalized, "open", 1, true) ~= nil
                    or string.find(normalized, "consume", 1, true) ~= nil

                if mentionsBag and looksConsumptive then
                    return {
                        kind = candidate:IsA("RemoteFunction") and "function" or "event",
                        remote = candidate,
                        label = candidate:GetFullName(),
                        display = "Discovered remote",
                    }
                end
            end
        end

        return nil
    end

    -- ==========================================
    -- WATCHDOG
    -- ==========================================

    local heartbeatAt = os.clock()
    local heartbeatState = "boot"

    local function heartbeat(state)
        heartbeatAt = os.clock()

        if state then
            heartbeatState = state
        end
    end

    -- ==========================================
    -- OPEN LOOP
    -- ==========================================

    local openedTotal = 0
    local openedLargeTotal = 0
    local rejectedTotal = 0
    local errorTotal = 0
    local optimisticStreak = 0
    local rejectionStreak = 0
    local consecutiveFails = 0
    local circuitBreakerDelay = 0
    local circuitTrips = 0
    local cleanStreak = 0
    local externalWarned = false

    -- Independent denomination ladders per bag type. Each index points
    -- into that type's sanctioned batch table; success climbs, refusal
    -- drops one step. Never exceeds the smaller of the ladder cap
    -- (MAX_BATCH) and the account's current total for that type.
    local batchIndex = { normal = 1, large = 1 }
    local cleanSinceGrow = { normal = 0, large = 0 }

    local function ladderFor(isLarge)
        return isLarge and LARGE_BATCHES or NORMAL_BATCHES
    end

    local function batchKey(isLarge)
        return isLarge and "large" or "normal"
    end

    local function selectBatch(isLarge, typeTotal)
        local ladder = ladderFor(isLarge)
        local key = batchKey(isLarge)
        local index = batchIndex[key]

        while index > 1 and ladder[index] > typeTotal do
            index -= 1
        end

        batchIndex[key] = index
        return ladder[index]
    end

    local function growBatch(isLarge)
        local ladder = ladderFor(isLarge)
        local key = batchKey(isLarge)

        if batchIndex[key] < #ladder
            and ladder[batchIndex[key] + 1] <= SETTINGS.MAX_BATCH
        then
            batchIndex[key] += 1
            cleanSinceGrow[key] = 0

            if SETTINGS.VERBOSE then
                print(string.format(
                    "[Giftbag] %s batch -> %d",
                    isLarge and "Large" or "Normal",
                    ladder[batchIndex[key]]
                ))
            end
        end
    end

    local function shrinkBatch(isLarge)
        local key = batchKey(isLarge)

        if batchIndex[key] > 1 then
            batchIndex[key] -= 1
        end

        cleanSinceGrow[key] = 0
    end
    local windowOpened = 0
    local windowStartedAt = os.clock()
    local lastStatusAt = os.clock()
    local backlogHighSince = nil

    local function applyIntervalChange(newInterval, reason)
        newInterval = math.max(
            SETTINGS.MIN_INTERVAL,
            math.min(SETTINGS.MAX_INTERVAL, newInterval)
        )

        if math.abs(newInterval - currentInterval) < 0.01 then
            return
        end

        currentInterval = newInterval
        dashboard.interval = currentInterval
        cleanStreak = 0

        if SETTINGS.VERBOSE then
            print(string.format("[Giftbag] Interval %.2fs (%s)", currentInterval, reason))
        end
    end

    local function gateWait()
        -- Plain interval + per-account jitter. (An earlier version ADDED
        -- a phase offset on top of the interval here, doubling the
        -- average gate; phase decorrelation is not worth that cost.)
        local jitter = currentInterval * SETTINGS.JITTER_MAX
            * ((LocalPlayer and LocalPlayer.UserId or 0) % 7 / 7)
        local deadline = os.clock() + currentInterval + jitter

        while not env.STOP_GIFTBAG_OPENER do
            heartbeat("gate wait")
            local remaining = deadline - os.clock()

            if remaining <= 0 then
                return true
            end

            task.wait(math.max(0.05, math.min(0.25, remaining)))
        end

        return false
    end

    local function invokeOpen(endpoint, bag, count)
        heartbeat("remote invocation")
        -- Server contract (remote-spy confirmed): GiftBag_Open(id, count).
        local args = SETTINGS.ARG_MODE == "uid" and { bag.uid, count } or { bag.id, count }

        if endpoint.kind == "event" then
            local ok = pcall(endpoint.remote.FireServer, endpoint.remote, table.unpack(args))
            return ok, ok and nil or "fire failed", false
        end

        local completed, callOk, callResult = false, false, nil
        local thread = task.spawn(function()
            local ok, result = pcall(function()
                return endpoint.remote:InvokeServer(table.unpack(args))
            end)
            callOk, callResult = ok, result
            completed = true
        end)

        local deadline = os.clock() + SETTINGS.REMOTE_TIMEOUT

        while not completed and not env.STOP_GIFTBAG_OPENER and os.clock() < deadline do
            heartbeat("remote response wait")
            task.wait(0.03)
        end

        if completed then
            return callOk, callResult, false
        end

        local cancelled = false

        if type(task.cancel) == "function" then
            cancelled = pcall(task.cancel, thread)
        end

        if not cancelled and type(coroutine.close) == "function" then
            cancelled = pcall(coroutine.close, thread)
        end

        if not cancelled and not completed then
            return false, "uncancellable timeout thread", true
        end

        return false, string.format("timeout after %.1fs", SETTINGS.REMOTE_TIMEOUT), false
    end

    local function confirmByCount(beforeTotal, beforeBags)
        local deadline = os.clock() + 3

        while os.clock() < deadline and not env.STOP_GIFTBAG_OPENER do
            heartbeat("confirmation poll")
            task.wait(0.25)
            local data = getSaveData()

            if data then
                local bags, total = scanBags(data)

                if total < beforeTotal then
                    return true, total, bags
                end

                if total > beforeTotal then
                    return false, total, bags
                end
            end
        end

        return false, beforeTotal, beforeBags
    end

    print(string.format(
        "[Giftbag] %s started | interval %.2fs | ladder 1/5/25/%d | drain at %d+ | remote %s",
        MODULE_BUILD,
        currentInterval,
        math.min(50, SETTINGS.MAX_BATCH),
        SETTINGS.DRAIN_THRESHOLD,
        SETTINGS.REMOTE_NAME ~= "" and SETTINGS.REMOTE_NAME or "auto"
    ))

    sendWebhook({
        title = "Giftbag Opener Started",
        description = "The gift bag opener is online and will begin draining the backlog once the open remote resolves.",
        fields = {
            webhookField("Interval", string.format("%.2fs", currentInterval), true),
            webhookField("Backlog", formatInteger(dashboard.backlog), true),
        },
    })

    -- External-consumer detector baseline
    local checkpointBags, checkpointTotal = scanBags(getSaveData())
    local checkpointOpened = 0

    dashboard.state = "Resolving"

    while not env.STOP_GIFTBAG_OPENER do
        heartbeat("remote resolution loop")

        if not OpenEndpoint then
            OpenEndpoint = resolveOpenEndpoint()

            if OpenEndpoint then
                print("[Giftbag] Open remote: " .. OpenEndpoint.label)
                dashboard.state = "Running"
            end
        end

        if OpenEndpoint then
            break
        end

        if os.clock() - startedAt > SETTINGS.RESOLVE_TIMEOUT then
            dashboard.state = "Unresolved"
            sendWebhook({
                title = "Giftbag Remote Unresolved",
                description = "The open remote could not be resolved. Set GGIFTBAG_REMOTE_NAME from a remote-spy capture, or verify the signature scan covers the current game build.",
                color = 15548997,
                critical = true,
                fields = {
                    webhookField("Resolved State", "Unresolved", true),
                    webhookField("Backlog", formatInteger(dashboard.backlog), true),
                },
            })
            warn("[Giftbag] Open remote unresolved after "
                .. tostring(SETTINGS.RESOLVE_TIMEOUT) .. "s; retrying every 15s.")
            task.wait(15)
        else
            task.wait(1)
        end
    end

    local lastVerificationAt = os.clock()

    -- Pending-opens ledger: the engine's save cache refreshes ~every 2s,
    -- so bags we just opened still appear present. Subtract optimistic
    -- opens until the cache version advances, preventing over-opens
    -- against phantom inventory (the old rejection-cascade source).
    local pendingNormal, pendingLarge = 0, 0
    local lastCacheVersion = nil

    while not env.STOP_GIFTBAG_OPENER do
        heartbeat("main loop")
        local data = getSaveData()

        if data then
            local bags, total, totalLarge, totalNormal = scanBags(data)
            dashboard.backlog = total
            dashboard.backlogLarge = totalLarge

            local cacheEntry = env.GPINATA_SAVE_CACHE_DATA
            local cacheVersion = type(cacheEntry) == "table"
                and tonumber(cacheEntry.version)
                or nil

            if cacheVersion == nil or cacheVersion ~= lastCacheVersion then
                -- Fresh data (standalone fetch, or engine cache advanced):
                -- our optimistic decrements are now reflected in the scan.
                pendingNormal, pendingLarge = 0, 0
                lastCacheVersion = cacheVersion
            end

            local effectiveNormal = math.max(0, totalNormal - pendingNormal)
            local effectiveLarge = math.max(0, totalLarge - pendingLarge)

            -- External consumer detection: bags vanished that we did not
            -- open. Tolerance absorbs loot/edge timing noise.
            local observedDrop = checkpointTotal - total

            if observedDrop > checkpointOpened + SETTINGS.EXTERNAL_TOLERANCE then
                dashboard.external = "Detected"

                if not externalWarned then
                    externalWarned = true
                    sendWebhook({
                        title = "External Bag Consumer Detected",
                        description = "Gift bag counts are dropping faster than this opener is opening. Disable GScript's auto-open for gift bags so only one consumer fires remotes.",
                        color = 16753920,
                        critical = true,
                        fields = {
                            webhookField("Our Opens Since Checkpoint", formatInteger(checkpointOpened), true),
                            webhookField("Observed Drop", formatInteger(observedDrop), true),
                        },
                    })
                end
            end

            checkpointTotal = total
            checkpointOpened = 0

            if total >= SETTINGS.BACKLOG_ALERT then
                if backlogHighSince == nil then
                    backlogHighSince = os.clock()
                elseif os.clock() - backlogHighSince
                    >= SETTINGS.BACKLOG_ALERT_MINUTES * 60
                then
                    backlogHighSince = os.clock()
                    sendWebhook({
                        title = "Giftbag Backlog Growing",
                        description = "The backlog has stayed above the alert threshold. The opener may be paced too slowly or opens are being rejected.",
                        color = 16753920,
                        fields = {
                            webhookField("Backlog", formatInteger(total), true),
                            webhookField("Interval", string.format("%.2fs", currentInterval), true),
                            webhookField("Opened This Session", formatInteger(openedTotal), true),
                        },
                    })
                end
            else
                backlogHighSince = nil
            end

            if total == 0 then
                dashboard.state = "Idle"
                task.wait(2)
            elseif effectiveNormal + effectiveLarge == 0 then
                -- Raw stock exists but every bag is one we already opened
                -- (cache not refreshed yet). Short wait, do not invoke.
                dashboard.state = "Syncing"
                task.wait(0.5)
            else
                dashboard.state = circuitBreakerDelay > 0 and "Circuit" or "Running"

                if circuitBreakerDelay > 0 then
                    circuitBreakerDelay = math.max(0, circuitBreakerDelay - 1)
                    task.wait(1)
                else
                    -- First type with un-opened stock (large-first order).
                    local bag

                    for _, candidate in ipairs(bags) do
                        if (candidate.isLarge and effectiveLarge or effectiveNormal) > 0 then
                            bag = candidate
                            break
                        end
                    end

                    if not bag then
                        task.wait(0.5)
                    else
                    if not gateWait() then
                        break
                    end

                    -- The remote takes (id, count) and pulls from the
                    -- account-wide total for that id. Cap at the EFFECTIVE
                    -- per-type aggregate (raw minus our pending opens).
                    local effectiveForType = bag.isLarge and effectiveLarge or effectiveNormal

                    -- Drain mode: a real backlog (drops accumulated) jumps
                    -- the ladder straight to the largest sanctioned rung
                    -- that fits — matching GScript's bulk-open burst —
                    -- instead of earning it 10 clean calls at a time.
                    if effectiveNormal + effectiveLarge >= SETTINGS.DRAIN_THRESHOLD then
                        local ladder = ladderFor(bag.isLarge)
                        local bestIndex = 1

                        for index, rung in ipairs(ladder) do
                            if rung <= effectiveForType and rung <= SETTINGS.MAX_BATCH then
                                bestIndex = index
                            end
                        end

                        batchIndex[batchKey(bag.isLarge)] = bestIndex
                    end

                    local batch = selectBatch(bag.isLarge, effectiveForType)

                    local ok, response, fatal = invokeOpen(OpenEndpoint, bag, batch)

                    if fatal then
                        sendWebhook({
                            title = "Giftbag Opener Safety Stop",
                            description = "A timed-out remote thread could not be cancelled. The opener has stopped itself to avoid stacking threads.",
                            color = 15548997,
                            critical = true,
                            fields = {
                                webhookField("Last State", tostring(response), true),
                                webhookField("Backlog", formatInteger(total), true),
                            },
                        })
                        env.STOP_GIFTBAG_OPENER = true
                        break
                    end

                    if ok and (response == nil or response == true or response == 1) then
                        -- Optimistic path
                        openedTotal += batch
                        windowOpened += batch
                        checkpointOpened += batch

                        if bag.isLarge then
                            pendingLarge += batch
                        else
                            pendingNormal += batch
                        end

                        rejectionStreak = 0
                        consecutiveFails = 0
                        cleanStreak += 1
                        optimisticStreak += batch

                        if bag.isLarge then
                            openedLargeTotal += batch
                            cleanSinceGrow.large += 1

                            if cleanSinceGrow.large >= SETTINGS.BATCH_GROW_AFTER then
                                growBatch(true)
                            end
                        else
                            cleanSinceGrow.normal += 1

                            if cleanSinceGrow.normal >= SETTINGS.BATCH_GROW_AFTER then
                                growBatch(false)
                            end
                        end

                        dashboard.opened = openedTotal
                        dashboard.openedLarge = openedLargeTotal

                        if cleanStreak >= SETTINGS.SPEEDUP_AFTER then
                            cleanStreak = 0
                            applyIntervalChange(currentInterval - SETTINGS.SPEEDUP_STEP, "speedup")
                        end

                        -- Bounded drift guard: periodically re-verify the
                        -- real backlog instead of trusting local decrements.
                        if optimisticStreak >= SETTINGS.VERIFY_EVERY then
                            optimisticStreak = 0
                            lastVerificationAt = os.clock()
                        end
                    elseif ok then
                        -- Remote answered but refused.
                        rejectedTotal += 1
                        dashboard.rejected = rejectedTotal
                        rejectionStreak += 1
                        cleanStreak = 0

                        -- Refusal drops one sanctioned denomination step.
                        shrinkBatch(bag.isLarge)

                        if rejectionStreak >= SETTINGS.CIRCUIT_AFTER then
                            circuitTrips += 1
                            circuitBreakerDelay = math.min(
                                SETTINGS.CIRCUIT_INITIAL_DELAY * (2 ^ math.min(circuitTrips, 5)),
                                SETTINGS.CIRCUIT_MAX_DELAY
                            )
                            applyIntervalChange(currentInterval + SETTINGS.SLOW_STEP, "rejection pressure")
                            sendWebhook({
                                title = "Giftbag Circuit Breaker Engaged",
                                description = "The open remote rejected several consecutive requests. The opener is backing off and slowing its pace.",
                                color = 15548997,
                                fields = {
                                    webhookField("Rejections", formatInteger(rejectedTotal), true),
                                    webhookField("Backoff", string.format("%.0fs", circuitBreakerDelay), true),
                                    webhookField("New Interval", string.format("%.2fs", currentInterval), true),
                                },
                            })
                        end
                    else
                        errorTotal += 1
                        dashboard.errors = errorTotal
                        consecutiveFails += 1
                        cleanStreak = 0

                        if SETTINGS.VERBOSE then
                            warn("[Giftbag] Open failed: " .. tostring(response))
                        end

                        if consecutiveFails >= SETTINGS.STOP_AFTER_FAILS then
                            sendWebhook({
                                title = "Giftbag Opener Fault Stop",
                                description = "Open calls are failing persistently. The opener has stopped to avoid hammering a broken endpoint.",
                                color = 15548997,
                                critical = true,
                                fields = {
                                    webhookField("Consecutive Failures", formatInteger(consecutiveFails), true),
                                    webhookField("Last Error", tostring(response), false),
                                    webhookField("Backlog", formatInteger(total), true),
                                },
                            })
                            env.STOP_GIFTBAG_OPENER = true
                            break
                        end

                        local backoff = math.min(
                            SETTINGS.BACKOFF_BASE ^ math.min(consecutiveFails, 5),
                            SETTINGS.BACKOFF_MAX
                        )
                        task.wait(backoff)
                        OpenEndpoint = nil
                    end
                    end
                end
            end
        else
            task.wait(2)
        end

        -- Periodic status webhook + live snapshot for telemetry.
        local now = os.clock()

        if now - windowStartedAt >= SETTINGS.WEBHOOK_STATUS_SECONDS then
            local elapsed = now - windowStartedAt
            sendWebhook({
                periodic = true,
                title = "Giftbag 3-Hour Update",
                description = string.format(
                    "🪅 **%s bags opened** (%s large) in %s\n📦 Backlog: **%s** (%s large)\n⚡ **%.0f/hour** • Interval `%.2fs`",
                    formatInteger(windowOpened),
                    formatInteger(dashboard.openedLarge),
                    formatDuration(elapsed),
                    formatInteger(dashboard.backlog),
                    formatInteger(dashboard.backlogLarge),
                    windowOpened / elapsed * 3600,
                    currentInterval
                ),
                fields = {
                    webhookField("Session Totals", string.format(
                        "Opened: **%s** (%s large)\nRejected: %s • Errors: %s\nCircuit trips: %s",
                        formatInteger(openedTotal),
                        formatInteger(openedLargeTotal),
                        formatInteger(rejectedTotal),
                        formatInteger(errorTotal),
                        formatInteger(circuitTrips)
                    ), false),
                    webhookField("Health", string.format(
                        "State: **%s**\nRemote: `%s`\nExternal consumer: **%s**",
                        tostring(dashboard.state),
                        tostring(OpenEndpoint and OpenEndpoint.display or "re-resolving"),
                        tostring(dashboard.external)
                    ), false),
                },
            })
            windowOpened = 0
            windowStartedAt = now
            lastStatusAt = now
        end

        env.GGIFTBAG_LIVE_SNAPSHOT = {
            build = MODULE_BUILD,
            state = dashboard.state,
            backlog = dashboard.backlog,
            backlogLarge = dashboard.backlogLarge,
            interval = currentInterval,
            batchNormal = NORMAL_BATCHES[batchIndex.normal],
            batchLarge = LARGE_BATCHES[batchIndex.large],
            openedSession = openedTotal,
            openedLargeSession = openedLargeTotal,
            rejectedSession = rejectedTotal,
            errorsSession = errorTotal,
            externalConsumer = dashboard.external,
            remote = OpenEndpoint and OpenEndpoint.display or "unresolved",
            runtime = os.clock() - startedAt,
            updatedAt = os.time(),
        }
    end

    sendWebhook({
        title = "Giftbag Opener Stopped",
        description = "The opener has shut down.",
        fields = {
            webhookField("Opened This Session", formatInteger(openedTotal), true),
            webhookField("Backlog Remaining", formatInteger(dashboard.backlog), true),
            webhookField("Runtime", formatDuration(os.clock() - startedAt), true),
        },
    })

    print(string.format(
        "[Giftbag] Stopped | opened %d (%d large) | backlog %d | rejected %d | errors %d",
        openedTotal,
        openedLargeTotal,
        dashboard.backlog,
        rejectedTotal,
        errorTotal
    ))

    env.GGIFTBAG_LIVE_SNAPSHOT = nil
    env.__GIFTBAG_OPENER_RUNNING = false
end)
