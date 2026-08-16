local env = getgenv()
local ENGINE_BUILD = "hyperflow-2.2"

local function startFleetLedger()
    if env.GLEDGER_ENABLED == false
        or env.__FLEET_PROFIT_LEDGER_RUNNING
        or env.__FLEET_PROFIT_LEDGER_LOADING
    then
        return
    end

    env.__FLEET_PROFIT_LEDGER_LOADING = true

    if env.GLEDGER_ROLE == nil then
        env.GLEDGER_ROLE = env.GPINATA_ENABLED == false
            and "GScript Account"
            or "Pinata Farmer"
    end

    task.spawn(function()
        local ledgerUrl = "https://raw.githubusercontent.com/"
            .. "vaporcadillac/client-runtime-a91e6f4c/main/module_f0a9.lua"
        local lastError = "download unavailable"

        for attempt = 1, 5 do
            if env.STOP_FLEET_PROFIT_LEDGER then
                break
            end

            local requestUrl = ledgerUrl
                .. "?session="
                .. tostring(os.time())
                .. "&attempt="
                .. tostring(attempt)
            local downloadOk, source = pcall(function()
                return game:HttpGet(requestUrl)
            end)

            if downloadOk and type(source) == "string" and #source > 0 then
                -- Build pin: refuse to execute a ledger that does not
                -- declare the expected LEDGER_BUILD. A bad deploy on the
                -- repo can no longer push arbitrary code into clients.
                local expectedBuild = tostring(
                    env.GLEDGER_REQUIRED_BUILD or "fleet-ledger-1.4"
                )

                if string.find(
                    source,
                    'LEDGER_BUILD = "' .. expectedBuild,
                    1,
                    true
                ) == nil then
                    lastError = "build marker mismatch (expected " .. expectedBuild .. ")"
                else
                    local chunk, compileError = loadstring(source)

                    if chunk then
                        local runtimeOk, runtimeError = pcall(chunk)
                        env.__FLEET_PROFIT_LEDGER_LOADING = false

                        if not runtimeOk then
                            warn(
                                "[LedgerBootstrap] Startup failed: "
                                    .. tostring(runtimeError)
                            )
                        end

                        return
                    end

                    lastError = tostring(compileError)
                end
            else
                lastError = tostring(source)
            end

            if attempt < 5 then
                task.wait(math.min(20, attempt * 3))
            end
        end

        env.__FLEET_PROFIT_LEDGER_LOADING = false
        warn("[LedgerBootstrap] Could not start ledger: " .. lastError)
    end)
end

startFleetLedger()

if env.GPINATA_ENABLED == false then
    return
end

if env.__MINI_PINATA_FAST_PLACER_RUNNING then
    warn("[Runtime] Engine is already running.")
    return
end

env.__MINI_PINATA_FAST_PLACER_RUNNING = true
env.STOP_MINI_PINATA_FAST_PLACER = false
env.GPINATA_ENGINE_BUILD = ENGINE_BUILD

local bootStartedAt = os.clock()
local dashboard = {
    state = "Booting",
    gems = nil,
    pinatas = nil,
    interval = 5.0,
    hourly = 0,
    daily = 0,
    successRate = 100,
    calibration = "Loading profile",
    remote = "Resolving",
}
dashboard.hourly = 3600 / dashboard.interval
dashboard.daily = 86400 / dashboard.interval

task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    task.wait(5)

    local function numberSetting(name, default)
        return tonumber(env[name]) or default
    end

    local HttpService = game:GetService("HttpService")
    local Players = game:GetService("Players")
    local WebhookPlayer = Players.LocalPlayer

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

        local lowerUrl = string.lower(url)
        local isDiscord = string.find(
            lowerUrl,
            "PASTE_YOUR_DISCORD_WEBHOOK_HERE",
            1,
            true
        ) == 1
            or string.find(
                lowerUrl,
                "https://discordapp.com/api/webhooks/",
                1,
                true
            ) == 1
            or string.find(
                lowerUrl,
                "https://canary.discord.com/api/webhooks/",
                1,
                true
            ) == 1

        return isDiscord and url or nil
    end

    local function resolveRequestFunction()
        local candidates = {}

        local function addCandidate(candidate)
            if type(candidate) == "function" then
                table.insert(candidates, candidate)
            end
        end

        addCandidate(rawget(env, "request"))
        addCandidate(rawget(env, "http_request"))
        addCandidate(rawget(_G, "request"))
        addCandidate(rawget(_G, "http_request"))

        local synTable = rawget(env, "syn") or rawget(_G, "syn")

        if type(synTable) == "table" then
            addCandidate(synTable.request)
        end

        local httpTable = rawget(env, "http") or rawget(_G, "http")

        if type(httpTable) == "table" then
            addCandidate(httpTable.request)
        end

        for _, candidate in ipairs(candidates) do
            if type(candidate) == "function" then
                return candidate
            end
        end

        return nil
    end

    local webhookEnabled = env.GPINATA_WEBHOOK_ENABLED == true
    local webhookUrl = normalizeWebhookUrl(
        env.GPINATA_WEBHOOK_URL or env.GWEBHOOK_LINK
    )
    local webhookRequest = resolveRequestFunction()
    local webhookQueueLimit = math.max(
        5,
        math.min(100, math.floor(numberSetting("GPINATA_WEBHOOK_QUEUE_LIMIT", 30)))
    )
    local webhookQueue = {}
    local webhookWorkerRunning = false
    local webhookFailureWarned = false

    if webhookEnabled and not webhookUrl then
        webhookEnabled = false
        warn("[Runtime] Pinata webhook disabled: Discord URL is missing or invalid.")
    elseif webhookEnabled and not webhookRequest then
        webhookEnabled = false
        warn("[Runtime] Pinata webhook disabled: executor request API is unavailable.")
    end

    local function safeWebhookText(value, limit)
        local text = tostring(value == nil and "N/A" or value)

        if #text > limit then
            return string.sub(text, 1, math.max(1, limit - 3)) .. "..."
        end

        return text
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
            return "Loading…"
        end

        local absolute = math.abs(number)
        local suffixes = {
            { 1e15, "Q" },
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

    local function dashboardDescription(detail, targetZone)
        local stateIcons = {
            Running = "🟢",
            Calibrating = "🟡",
            Paused = "🟠",
            Circuit = "🔴",
            Fault = "🔴",
            Stopped = "⚫",
            Booting = "🔵",
        }
        local state = dashboard.state or "Booting"
        local stateIcon = stateIcons[state] or "🔵"
        local pinataText = dashboard.pinatas == nil
            and "Loading…"
            or formatInteger(dashboard.pinatas)
        local gemText = dashboard.gems == nil
            and "Loading…"
            or string.format(
                "%s (`%s`)",
                formatCompact(dashboard.gems),
                formatInteger(dashboard.gems)
            )
        local hourly = tonumber(dashboard.hourly) or 0
        local daily = tonumber(dashboard.daily) or 0
        local lines = {
            string.format(
                "%s **%s**  •  Interval `%.2fs`",
                stateIcon,
                state,
                tonumber(dashboard.interval) or 0
            ),
            string.format(
                "💎 **%s gems**  •  🪅 **%s piñatas**",
                gemText,
                pinataText
            ),
            string.format(
                "⚡ **%.1f/hour**  •  **%.0f/day**  •  ✅ **%.2f%% success**",
                hourly,
                daily,
                tonumber(dashboard.successRate) or 0
            ),
            string.format(
                "🧠 **%s**  •  🔗 **%s**",
                tostring(dashboard.calibration or "Not available"),
                tostring(dashboard.remote or "Resolving")
            ),
        }

        if type(detail) == "string" and detail ~= "" then
            table.insert(lines, "\n" .. detail)
        end

        return table.concat(lines, "\n")
    end

    local function webhookField(name, value, inline)
        return {
            name = safeWebhookText(name, 256),
            value = safeWebhookText(value, 1024),
            inline = inline == true,
        }
    end

    local function webhookContextFields()
        local accountName = WebhookPlayer and WebhookPlayer.Name or "Unknown"
        local userId = WebhookPlayer and WebhookPlayer.UserId or "Unknown"

        return {
            webhookField("Account", accountName .. " (`" .. tostring(userId) .. "`)", true),
            webhookField("Runtime", formatDuration(os.clock() - bootStartedAt), true),
        }
    end

    local function appendWebhookFields(destination, source)
        for _, field in ipairs(source or {}) do
            if #destination >= 25 then
                break
            end

            table.insert(destination, field)
        end
    end

    local function readResponseStatus(response)
        if type(response) ~= "table" then
            return nil
        end

        return tonumber(
            response.StatusCode
                or response.Status
                or response.status_code
                or response.status
        )
    end

    local function readRetryAfter(response)
        if type(response) ~= "table" or type(response.Body) ~= "string" then
            return 1
        end

        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body)
        local retryAfter = ok and type(decoded) == "table"
            and tonumber(decoded.retry_after)
            or nil

        return math.max(0.5, math.min(10, retryAfter or 1))
    end

    local function deliverWebhook(payload)
        local encodedOk, body = pcall(HttpService.JSONEncode, HttpService, payload)

        if not encodedOk then
            return false, "JSON encoding failed"
        end

        for attempt = 1, 2 do
            local requestOk, response = pcall(webhookRequest, {
                Url = webhookUrl,
                Method = "POST",
                Headers = {
                    ["Content-Type"] = "application/json",
                },
                Body = body,
            })

            if requestOk then
                local status = readResponseStatus(response)

                if status == 429 and attempt == 1 then
                    task.wait(readRetryAfter(response))
                elseif status == nil or (status >= 200 and status < 300) then
                    return true
                else
                    return false, "HTTP " .. tostring(status)
                end
            elseif attempt == 2 then
                return false, tostring(response)
            else
                task.wait(1)
            end
        end

        return false, "delivery failed"
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
                local delivered, deliveryError = deliverWebhook(payload)

                if not delivered and not webhookFailureWarned then
                    webhookFailureWarned = true
                    warn(
                        "[Runtime] Pinata webhook delivery failed: "
                            .. tostring(deliveryError)
                    )
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

    local alertLastSentAt = {}
    local alertMinGapSeconds = math.max(
        0,
        numberSetting("GPINATA_WEBHOOK_ALERT_MIN_GAP", 60)
    )

    local function sendWebhook(options)
        if not webhookEnabled then
            return
        end

        options = options or {}

        if options.periodic ~= true then
            -- Non-periodic alerts are rate-limited per title instead of
            -- dropped, so a flapping circuit breaker cannot flood the
            -- webhook while genuine alerts still get through.
            local title = tostring(options.title or "")
            local now = os.clock()
            local lastSentAt = tonumber(alertLastSentAt[title]) or 0

            if alertMinGapSeconds > 0 and now - lastSentAt < alertMinGapSeconds then
                return
            end

            alertLastSentAt[title] = now
        end

        local fields = {}
        appendWebhookFields(fields, webhookContextFields(options.targetZone))
        appendWebhookFields(fields, options.fields)

        local accountName = WebhookPlayer and WebhookPlayer.Name or "Unknown"
        local mentionUserId = tostring(env.GWEBHOOK_USERID or ""):match("^%d+$")
        local shouldMention = options.critical == true
            and env.GPINATA_WEBHOOK_MENTION_ON_CRITICAL == true
            and mentionUserId ~= nil

        local payload = {
            username = safeWebhookText("Mini Pinata Monitor - " .. accountName, 80),
            content = shouldMention and ("<@" .. mentionUserId .. ">") or nil,
            allowed_mentions = shouldMention
                and { users = { mentionUserId } }
                or { parse = {} },
            embeds = {
                {
                    title = safeWebhookText(options.title or "Mini Pinata Update", 256),
                    description = safeWebhookText(
                        dashboardDescription(
                            options.description,
                            options.targetZone
                        ),
                        4096
                    ),
                    color = tonumber(options.color) or 3447003,
                    fields = fields,
                    footer = {
                        text = "Engine " .. ENGINE_BUILD,
                    },
                    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                },
            },
        }

        if #webhookQueue >= webhookQueueLimit then
            table.remove(webhookQueue, 1)
        end

        table.insert(webhookQueue, payload)
        startWebhookWorker()
    end

    local watchdogTimeout = math.max(
        20,
        numberSetting("GPINATA_WATCHDOG_TIMEOUT", 45)
    )
    local heartbeatAt = os.clock()
    local heartbeatState = "boot"
    local cancellationFailed = false
    local engineThreadId = nil

    local function heartbeat(state)
        -- Only the engine thread feeds the watchdog. Background loops
        -- (hijack, cache monitor, telemetry) must not mask a stall.
        if engineThreadId ~= nil and coroutine.running() ~= engineThreadId then
            return
        end

        heartbeatAt = os.clock()

        if state then
            heartbeatState = state
        end
    end

    local function cancelManagedThread(thread)
        local cancelled = false

        if type(task.cancel) == "function" then
            cancelled = pcall(task.cancel, thread)
        end

        if not cancelled and type(coroutine.close) == "function" then
            cancelled = pcall(coroutine.close, thread)
        end

        return cancelled
    end

    print(string.format(
        "[Runtime] Engine build %s | watchdog %.0fs",
        ENGINE_BUILD,
        watchdogTimeout
    ))

    local function supervisorWait(seconds)
        local deadline = os.clock() + seconds

        while not env.STOP_MINI_PINATA_FAST_PLACER do
            local remaining = deadline - os.clock()

            if remaining <= 0 then
                return true
            end

            task.wait(math.max(0.1, math.min(1, remaining)))
        end

        return false
    end

    local function runEngine()
        engineThreadId = coroutine.running()

        -- Generation token: background loops from a previous engine
        -- incarnation exit when this changes, preventing accumulation
        -- across supervisor fault restarts.
        local engineGeneration = (env.__GPINATA_ENGINE_GENERATION or 0) + 1
        env.__GPINATA_ENGINE_GENERATION = engineGeneration

        heartbeat("engine initialization")

        local SETTINGS = {
            -- Placement interval; adaptive controller tunes within MIN/MAX bounds.
            INTERVAL = math.max(1.5, numberSetting("GPINATA_INTERVAL", 5.0)),
            ADAPTIVE = env.GPINATA_ADAPTIVE ~= false,
            ADAPTIVE_MIN_INTERVAL = math.max(
                1.5,
                numberSetting("GPINATA_ADAPTIVE_MIN_INTERVAL", 5.0)
            ),
            ADAPTIVE_MAX_INTERVAL = math.max(
                1.5,
                numberSetting("GPINATA_ADAPTIVE_MAX_INTERVAL", 7.0)
            ),
            ADAPTIVE_WINDOW = math.max(
                10,
                math.floor(numberSetting("GPINATA_ADAPTIVE_WINDOW", 20))
            ),
            ADAPTIVE_LONG_WINDOW = math.max(
                150,
                math.floor(numberSetting("GPINATA_ADAPTIVE_LONG_WINDOW", 150))
            ),
            ADAPTIVE_STEP_DOWN = math.max(
                0.01,
                numberSetting("GPINATA_ADAPTIVE_STEP_DOWN", 0.05)
            ),
            ADAPTIVE_HIGH_REJECT_RATE = math.max(
                0,
                numberSetting("GPINATA_ADAPTIVE_HIGH_REJECT_RATE", 0.25)
            ),
            ADAPTIVE_PRESSURE_WINDOWS = math.max(
                1,
                math.floor(numberSetting("GPINATA_ADAPTIVE_PRESSURE_WINDOWS", 2))
            ),
            ADAPTIVE_PRESSURE_STEP = math.max(
                0.01,
                numberSetting("GPINATA_ADAPTIVE_PRESSURE_STEP", 0.10)
            ),
            ADAPTIVE_RECOVERY_HOLD = math.max(
                1200,
                numberSetting("GPINATA_ADAPTIVE_RECOVERY_HOLD", 1200)
            ),
            ADAPTIVE_FAILURE_HOLD = math.max(
                3600,
                numberSetting("GPINATA_ADAPTIVE_FAILURE_HOLD", 3600)
            ),
            ADAPTIVE_RECOVERY_MAX_REJECT_RATE = math.min(
                0.015,
                math.max(
                    0,
                    numberSetting("GPINATA_ADAPTIVE_RECOVERY_MAX_REJECT_RATE", 0.015)
                )
            ),
            ADAPTIVE_RECOVERY_MAX_SECOND_RETRIES = math.max(
                0,
                math.floor(numberSetting(
                    "GPINATA_ADAPTIVE_RECOVERY_MAX_SECOND_RETRIES",
                    0
                ))
            ),
            ISOLATED_FAILURE_WINDOW = math.max(
                50,
                math.floor(numberSetting(
                    "GPINATA_ISOLATED_FAILURE_WINDOW",
                    100
                ))
            ),
            ISOLATED_FAILURES_TO_SLOW = math.max(
                2,
                math.floor(numberSetting(
                    "GPINATA_ISOLATED_FAILURES_TO_SLOW",
                    2
                ))
            ),
            ISOLATED_FAILURE_STEP = math.max(
                0.05,
                numberSetting("GPINATA_ISOLATED_FAILURE_STEP", 0.10)
            ),
            CONFIRM_WAIT = math.max(0.25, numberSetting("GPINATA_CONFIRM_WAIT", 1.5)),
            MAX_RETRIES = math.min(
                2,
                math.max(0, math.floor(numberSetting("GPINATA_MAX_RETRIES", 2)))
            ),
            STARTUP_WAIT = math.max(0, numberSetting("GPINATA_STARTUP_WAIT", 60)),
            STABLE_WAIT = math.max(0, numberSetting("GPINATA_STABLE_WAIT", 20)),
            FPS = math.max(1, numberSetting("GPINATA_FPS", 10)),
            STATUS_EVERY = math.max(1, math.floor(numberSetting("GPINATA_STATUS_EVERY", 100))),
            WEBHOOK_STATUS_SECONDS = math.max(
                3 * 60 * 60,
                numberSetting("GPINATA_WEBHOOK_STATUS_SECONDS", 3 * 60 * 60)
            ),
            WEBHOOK_FARM_LOSS_DELAY = math.max(
                30,
                numberSetting("GPINATA_WEBHOOK_FARM_LOSS_DELAY", 60)
            ),
            WEBHOOK_ALERT_REJECT_STREAK = math.max(
                2,
                math.floor(numberSetting("GPINATA_WEBHOOK_ALERT_REJECT_STREAK", 3))
            ),
            TARGET_ZONE = tonumber(env.GZONE_TO) or 39,
            FARM_WAIT_TIMEOUT = math.max(
                60,
                numberSetting("GPINATA_FARM_WAIT_TIMEOUT", 600)
            ),
            STAGGER = env.GPINATA_STAGGER ~= false,
            POSITION_RADIUS = 8,
            FARM_CHECK_INTERVAL = 2,
            INVENTORY_TIMEOUT = 30,
            INVENTORY_RECOVERY_TIMEOUT = 60,
            RETRY_DISABLE_AFTER = 1,
            REJECTION_BACKOFF_BASE = 2,
            REJECTION_BACKOFF_MAX = 30,
            CIRCUIT_BREAKER_AFTER = math.max(
                2,
                math.floor(numberSetting("GPINATA_CIRCUIT_BREAKER_AFTER", 3))
            ),
            CIRCUIT_BREAKER_INITIAL_DELAY = math.max(
                10,
                numberSetting("GPINATA_CIRCUIT_BREAKER_INITIAL_DELAY", 30)
            ),
            CIRCUIT_BREAKER_MAX_DELAY = math.max(
                30,
                numberSetting("GPINATA_CIRCUIT_BREAKER_MAX_DELAY", 300)
            ),
            ZONE_CIRCUIT_WINDOW_SECONDS = math.max(
                1800,
                numberSetting("GPINATA_ZONE_CIRCUIT_WINDOW_SECONDS", 7200)
            ),
            ZONE_CIRCUITS_TO_UNHEALTHY = math.max(
                2,
                math.floor(numberSetting(
                    "GPINATA_ZONE_CIRCUITS_TO_UNHEALTHY",
                    2
                ))
            ),
            ZONE_UNHEALTHY_HOLD = math.max(
                1800,
                numberSetting("GPINATA_ZONE_UNHEALTHY_HOLD", 3600)
            ),
            PACING_JITTER_MAX = math.max(
                0,
                math.min(1, numberSetting("GPINATA_PACING_JITTER_MAX", 0.15))
            ),
            -- 2.2 hold-at-target: once the engine confirms at this
            -- interval it stops probing downward and holds, instead of
            -- chasing the floor. 24/7 fleets trade the last ~5% pace for
            -- far less limit-riding and rate-heuristic exposure.
            TARGET_INTERVAL = math.max(
                1.5,
                numberSetting("GPINATA_TARGET_INTERVAL", 5.8)
            ),
            CALIBRATION = env.GPINATA_CALIBRATION ~= false,
            CALIBRATION_PERSIST = env.GPINATA_CALIBRATION_PERSIST ~= false,
            CALIBRATION_MIN_CYCLES = math.max(
                180,
                math.floor(numberSetting("GPINATA_CALIBRATION_MIN_CYCLES", 180))
            ),
            CALIBRATION_MIN_SECONDS = math.max(
                1500,
                numberSetting("GPINATA_CALIBRATION_MIN_SECONDS", 1500)
            ),
            CALIBRATION_MAX_REJECT_RATE = math.min(
                0.015,
                math.max(
                    0,
                    numberSetting("GPINATA_CALIBRATION_MAX_REJECT_RATE", 0.015)
                )
            ),
            AUTO_REMOTE = env.GPINATA_AUTO_REMOTE ~= false,
            AUTO_REMOTE_RESOLVE_TIMEOUT = math.max(
                5,
                numberSetting("GPINATA_AUTO_REMOTE_RESOLVE_TIMEOUT", 30)
            ),
            REMOTE_TIMEOUT = math.max(
                3,
                numberSetting("GPINATA_REMOTE_TIMEOUT", 8)
            ),
            REMOTE_ERROR_RESTART_AFTER = 5,
            VERBOSE = env.GPINATA_VERBOSE == true,
        }

        SETTINGS.ADAPTIVE_MAX_INTERVAL = math.max(
            SETTINGS.ADAPTIVE_MIN_INTERVAL,
            SETTINGS.ADAPTIVE_MAX_INTERVAL
        )
        SETTINGS.CIRCUIT_BREAKER_MAX_DELAY = math.max(
            SETTINGS.CIRCUIT_BREAKER_INITIAL_DELAY,
            SETTINGS.CIRCUIT_BREAKER_MAX_DELAY
        )

        local currentInterval = math.max(
            SETTINGS.ADAPTIVE_MIN_INTERVAL,
            math.min(SETTINGS.ADAPTIVE_MAX_INTERVAL, SETTINGS.INTERVAL)
        )

        local initialFpsCap = nil

        if type(getfpscap) == "function" then
            local ok, value = pcall(getfpscap)
            if ok and type(value) == "number" and value > 0 then
                initialFpsCap = value
            end
        end

        local fpsCapApplied = false

        local function applyFpsCap(fps)
            if type(setfpscap) ~= "function" then
                return
            end

            local ok, err = pcall(setfpscap, fps or SETTINGS.FPS)

            if ok then
                fpsCapApplied = true
            else
                warn("[Runtime] FPS cap failed: " .. tostring(err))
            end
        end

        local function restoreFpsCap()
            if not fpsCapApplied or type(setfpscap) ~= "function" then
                return
            end

            pcall(setfpscap, initialFpsCap or 60)
            fpsCapApplied = false
        end

        env.__GPINATA_RESTORE_FPSCAP = restoreFpsCap

        local function waitUntil(deadline)
            -- At a 10 FPS cap each task.wait rounds up to a ~100ms frame,
            -- so the final approach ramps FPS for ~16ms scheduling
            -- granularity instead of overshooting the deadline.
            local fpsRamped = false

            while not env.STOP_MINI_PINATA_FAST_PLACER do
                heartbeat("scheduled interval wait")
                local remaining = deadline - os.clock()

                if remaining <= 0 then
                    if fpsRamped then
                        applyFpsCap()
                    end

                    return true
                end

                if remaining <= 0.75 and not fpsRamped then
                    fpsRamped = true
                    applyFpsCap(60)
                end

                task.wait(math.max(0.03, math.min(0.25, remaining)))
            end

            if fpsRamped then
                applyFpsCap()
            end

            return false
        end

        applyFpsCap()

        local RunService = game:GetService("RunService")
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local Players = game:GetService("Players")
        local LocalPlayer = Players.LocalPlayer
        local Library = ReplicatedStorage:WaitForChild("Library")
        local Client = Library:WaitForChild("Client")
        local Save = require(Client:WaitForChild("Save"))
        local MapCmds = nil
        local ConsumeEndpoint = nil
        local lastResolvedEndpointLabel = nil

        local function executorFunction(name)
            local candidate = rawget(env, name) or rawget(_G, name)
            return type(candidate) == "function" and candidate or nil
        end

        local readCalibrationFile = executorFunction("readfile")
        local writeCalibrationFile = executorFunction("writefile")
        local calibrationFileName = string.format(
            "mini_pinata_calibration_%s_%s_%s.json",
            tostring(LocalPlayer and LocalPlayer.UserId or 0),
            tostring(game.PlaceId),
            tostring(SETTINGS.TARGET_ZONE)
        )
        local calibrationProfile = {
            schema = 2,
            userId = LocalPlayer and LocalPlayer.UserId or 0,
            placeId = game.PlaceId,
            placeVersion = game.PlaceVersion,
            zone = SETTINGS.TARGET_ZONE,
            recommendedInterval = currentInterval,
            qualifiedCycles = 0,
            qualifiedSeconds = 0,
            sessions = 1,
            updatedAt = 0,
            nextRecoveryAllowedAt = 0,
            recentCircuitCount = 0,
            lastCircuitAt = 0,
            zoneUnhealthyUntil = 0,
            engineBuild = ENGINE_BUILD,
        }
        local calibrationPersistent = SETTINGS.CALIBRATION
            and SETTINGS.CALIBRATION_PERSIST
            and readCalibrationFile ~= nil
            and writeCalibrationFile ~= nil
        local calibrationLoadedRemembered = false

        local function loadCalibrationProfile()
            if not calibrationPersistent then
                dashboard.calibration = SETTINGS.CALIBRATION
                    and "Session calibration"
                    or "Calibration disabled"
                return
            end

            local readOk, encoded = pcall(readCalibrationFile, calibrationFileName)

            if not readOk or type(encoded) ~= "string" or encoded == "" then
                dashboard.calibration = "New local profile"
                return
            end

            local decodeOk, decoded = pcall(
                HttpService.JSONDecode,
                HttpService,
                encoded
            )

            if not decodeOk or type(decoded) ~= "table" then
                dashboard.calibration = "Profile reset"
                return
            end

            local recommended = tonumber(decoded.recommendedInterval)
            local profileMatches = tonumber(decoded.userId) == calibrationProfile.userId
                and tonumber(decoded.placeId) == calibrationProfile.placeId
                and tonumber(decoded.zone) == calibrationProfile.zone
            local versionMatches = tonumber(decoded.placeVersion) == game.PlaceVersion

            if not recommended or not profileMatches then
                dashboard.calibration = "New local profile"
                return
            end

            calibrationProfile = decoded
            calibrationProfile.schema = 2
            calibrationProfile.recommendedInterval = math.max(
                SETTINGS.ADAPTIVE_MIN_INTERVAL,
                math.min(SETTINGS.ADAPTIVE_MAX_INTERVAL, recommended)
            )
            calibrationProfile.sessions = math.max(
                0,
                tonumber(calibrationProfile.sessions) or 0
            ) + 1
            calibrationProfile.nextRecoveryAllowedAt = math.max(
                0,
                tonumber(calibrationProfile.nextRecoveryAllowedAt) or 0
            )
            calibrationProfile.recentCircuitCount = math.max(
                0,
                math.floor(tonumber(calibrationProfile.recentCircuitCount) or 0)
            )
            calibrationProfile.lastCircuitAt = math.max(
                0,
                tonumber(calibrationProfile.lastCircuitAt) or 0
            )
            calibrationProfile.zoneUnhealthyUntil = math.max(
                0,
                tonumber(calibrationProfile.zoneUnhealthyUntil) or 0
            )

            if not versionMatches then
                calibrationProfile.provisional = true
                calibrationProfile.provisionalReason = "game build changed"
                calibrationProfile.qualifiedCycles = 0
                calibrationProfile.qualifiedSeconds = 0
                calibrationProfile.rejectRate = nil
            end

            currentInterval = math.max(
                currentInterval,
                calibrationProfile.recommendedInterval
            )
            -- v2.0 anti-drift: flag that this run started from a
            -- remembered interval, so early rejections on a stricter
            -- server can demote it (see updateAdaptiveRate).
            calibrationLoadedRemembered = true
            dashboard.calibration = string.format(
                not versionMatches
                    and "Game update • validating %.2fs"
                    or calibrationProfile.provisional
                        and "Remembered protective %.2fs"
                        or "Remembered %.2fs",
                calibrationProfile.recommendedInterval
            )
        end

        -- v2.0 zone memory: a per-zone interval map persisted inside the
        -- calibration profile. Different zones can sit on servers with
        -- different cooldown floors; when GScript moves this account's
        -- zone, the engine pre-loads the remembered zone floor instead
        -- of probing cold. Only qualified (non-provisional) intervals
        -- are recorded.
        local function rememberZoneInterval(zone, interval)
            if type(zone) ~= "number" or type(interval) ~= "number" then
                return
            end

            if calibrationProfile.zoneIntervals == nil
                or type(calibrationProfile.zoneIntervals) ~= "table"
            then
                calibrationProfile.zoneIntervals = {}
            end

            calibrationProfile.zoneIntervals[tostring(zone)] = interval
        end

        local function recallZoneInterval(zone)
            if type(zone) ~= "number"
                or type(calibrationProfile.zoneIntervals) ~= "table"
            then
                return nil
            end

            return tonumber(calibrationProfile.zoneIntervals[tostring(zone)])
        end

        local function saveCalibrationProfile()
            if not calibrationPersistent then
                return false
            end

            calibrationProfile.schema = 2
            calibrationProfile.placeVersion = game.PlaceVersion
            calibrationProfile.updatedAt = os.time()
            calibrationProfile.engineBuild = ENGINE_BUILD
            local encodeOk, encoded = pcall(
                HttpService.JSONEncode,
                HttpService,
                calibrationProfile
            )

            if not encodeOk then
                return false
            end

            local writeOk = pcall(
                writeCalibrationFile,
                calibrationFileName,
                encoded
            )
            return writeOk
        end

        local function persistRecoveryLock(seconds, reason)
            local lockUntil = os.time() + math.ceil(math.max(0, seconds or 0))
            calibrationProfile.nextRecoveryAllowedAt = math.max(
                tonumber(calibrationProfile.nextRecoveryAllowedAt) or 0,
                lockUntil
            )
            calibrationProfile.lastPressureReason = tostring(reason or "pressure")
            return saveCalibrationProfile()
        end

        local function recordZoneCircuit()
            local nowEpoch = os.time()
            local previousCircuitAt = tonumber(calibrationProfile.lastCircuitAt) or 0

            if previousCircuitAt <= 0
                or nowEpoch - previousCircuitAt
                    > SETTINGS.ZONE_CIRCUIT_WINDOW_SECONDS
            then
                calibrationProfile.recentCircuitCount = 1
            else
                calibrationProfile.recentCircuitCount = math.max(
                    0,
                    math.floor(
                        tonumber(calibrationProfile.recentCircuitCount) or 0
                    )
                ) + 1
            end

            calibrationProfile.lastCircuitAt = nowEpoch
            local markedUnhealthy = calibrationProfile.recentCircuitCount
                >= SETTINGS.ZONE_CIRCUITS_TO_UNHEALTHY

            if markedUnhealthy then
                calibrationProfile.zoneUnhealthyUntil = math.max(
                    tonumber(calibrationProfile.zoneUnhealthyUntil) or 0,
                    nowEpoch + SETTINGS.ZONE_UNHEALTHY_HOLD
                )
                calibrationProfile.nextRecoveryAllowedAt = math.max(
                    tonumber(calibrationProfile.nextRecoveryAllowedAt) or 0,
                    calibrationProfile.zoneUnhealthyUntil
                )
                calibrationProfile.lastPressureReason = "repeated zone circuits"
            end

            saveCalibrationProfile()
            return markedUnhealthy, calibrationProfile.recentCircuitCount
        end

        local function zoneHealthRemaining()
            return math.max(
                0,
                (tonumber(calibrationProfile.zoneUnhealthyUntil) or 0) - os.time()
            )
        end

        loadCalibrationProfile()

        if os.time() - (tonumber(calibrationProfile.lastCircuitAt) or 0)
            > SETTINGS.ZONE_CIRCUIT_WINDOW_SECONDS
        then
            calibrationProfile.recentCircuitCount = 0
        end

        if (tonumber(calibrationProfile.zoneUnhealthyUntil) or 0) <= os.time() then
            calibrationProfile.zoneUnhealthyUntil = 0
        end

        -- v2.0 zone memory: if this zone has its own remembered floor,
        -- honor it. Take the max of the account-wide interval and the
        -- zone-specific one so a stricter zone floor is never started
        -- below.
        do
            local zoneFloor = tonumber(recallZoneInterval(tonumber(SETTINGS.TARGET_ZONE)))
            local maxInterval = tonumber(SETTINGS.ADAPTIVE_MAX_INTERVAL)

            if zoneFloor and maxInterval and zoneFloor > currentInterval then
                currentInterval = math.min(zoneFloor, maxInterval)
                dashboard.calibration = string.format(
                    "Zone floor %.2fs pre-loaded",
                    currentInterval
                )
            end
        end

        dashboard.interval = currentInterval
        dashboard.hourly = 3600 / currentInterval
        dashboard.daily = 86400 / currentInterval

        local function normalizeRemoteName(value)
            return type(value) == "string"
                and string.lower(value):gsub("[^%w]", "")
                or ""
        end

        local function remoteAliases()
            local aliases = {
                tostring(env.GPINATA_REMOTE_NAME or "MiniPinata_Consume"),
                "MiniPinata_Consume",
                "MiniPinataConsume",
                "Mini Pinata Consume",
            }
            local configured = env.GPINATA_REMOTE_ALIASES

            if type(configured) == "table" then
                for _, alias in ipairs(configured) do
                    if type(alias) == "string" and alias ~= "" then
                        table.insert(aliases, alias)
                    end
                end
            end

            local unique = {}
            local result = {}

            for _, alias in ipairs(aliases) do
                local normalized = normalizeRemoteName(alias)

                if normalized ~= "" and not unique[normalized] then
                    unique[normalized] = true
                    table.insert(result, alias)
                end
            end

            return result
        end

        local function endpointValid(endpoint)
            if type(endpoint) ~= "table" then
                return false
            end

            if endpoint.kind == "instance" then
                return endpoint.remote
                    and endpoint.remote.Parent
                    and endpoint.remote:IsA("RemoteFunction")
            end

            return endpoint.kind == "network-wrapper"
                and type(endpoint.invoke) == "function"
        end

        local function announceResolvedEndpoint(endpoint)
            if not endpointValid(endpoint) then
                return
            end

            dashboard.remote = endpoint.display

            if endpoint.label == lastResolvedEndpointLabel then
                return
            end

            lastResolvedEndpointLabel = endpoint.label
        end

        local function findDirectEndpoint(network, aliases)
            if not network then
                return nil
            end

            for index, alias in ipairs(aliases) do
                local candidate = network:FindFirstChild(alias, true)

                if candidate and candidate:IsA("RemoteFunction") then
                    return {
                        kind = "instance",
                        remote = candidate,
                        label = candidate:GetFullName(),
                        display = index == 1 and "Known remote" or "Alias remote",
                        strategy = index == 1 and "Known route" or "Configured alias",
                    }
                end
            end

            if not SETTINGS.AUTO_REMOTE then
                return nil
            end

            for _, candidate in ipairs(network:GetDescendants()) do
                if candidate:IsA("RemoteFunction") then
                    local normalized = normalizeRemoteName(candidate.Name)
                    local mentionsMiniPinata = string.find(
                        normalized,
                        "minipinata",
                        1,
                        true
                    ) ~= nil
                    local looksConsumptive = string.find(
                        normalized,
                        "consume",
                        1,
                        true
                    ) ~= nil
                        or string.find(normalized, "activate", 1, true) ~= nil
                        or string.find(normalized, "use", 1, true) ~= nil

                    if mentionsMiniPinata and looksConsumptive then
                        return {
                            kind = "instance",
                            remote = candidate,
                            label = candidate:GetFullName(),
                            display = "Discovered remote",
                            strategy = "Signature scan",
                        }
                    end
                end
            end

            return nil
        end

        local function findNetworkWrapperEndpoint(aliases)
            if not SETTINGS.AUTO_REMOTE then
                return nil
            end

            local moduleScript = Client:FindFirstChild("Network")

            if not moduleScript then
                return nil
            end

            local requireOk, module = pcall(require, moduleScript)

            if not requireOk or type(module) ~= "table" then
                return nil
            end

            local invoke = module.Invoke or module.invoke

            if type(invoke) ~= "function" then
                return nil
            end

            return {
                kind = "network-wrapper",
                invoke = invoke,
                action = aliases[1],
                label = moduleScript:GetFullName() .. " → " .. aliases[1],
                display = "Client network wrapper",
                strategy = "PS99 client network",
            }
        end

        local function getConsumeEndpoint()
            heartbeat("remote resolution")

            if endpointValid(ConsumeEndpoint) then
                return ConsumeEndpoint
            end

            ConsumeEndpoint = nil
            dashboard.remote = "Resolving"
            local aliases = remoteAliases()
            local deadline = os.clock() + SETTINGS.AUTO_REMOTE_RESOLVE_TIMEOUT

            repeat
                heartbeat("remote resolution")
                local network = ReplicatedStorage:FindFirstChild("Network")
                local endpoint = findDirectEndpoint(network, aliases)

                if not endpoint then
                    endpoint = findNetworkWrapperEndpoint(aliases)
                end

                if endpoint then
                    ConsumeEndpoint = endpoint
                    announceResolvedEndpoint(endpoint)
                    return endpoint
                end

                task.wait(0.5)
            until os.clock() >= deadline
                or env.STOP_MINI_PINATA_FAST_PLACER

            dashboard.remote = "Unresolved"
            return nil
        end

        local function invokeConsumeWithTimeout(endpoint, uid)
            heartbeat("remote invocation")

            local completed = false
            local callOk = false
            local callResult = nil

            local invokeThread = task.spawn(function()
                local ok, result = pcall(function()
                    if endpoint.kind == "instance" then
                        return endpoint.remote:InvokeServer(uid)
                    end

                    return endpoint.invoke(endpoint.action, uid)
                end)

                callOk = ok
                callResult = result
                completed = true
            end)

            local deadline = os.clock() + SETTINGS.REMOTE_TIMEOUT

            while not completed
                and not env.STOP_MINI_PINATA_FAST_PLACER
                and os.clock() < deadline
            do
                heartbeat("remote response wait")
                task.wait(0.03)
            end

            if completed then
                return callOk, callResult, false
            end

            local cancelled = cancelManagedThread(invokeThread)

            if not cancelled and completed then
                return callOk, callResult, false
            end

            if not cancelled then
                error("[Runtime] Timed-out remote thread could not be cancelled.")
            end

            if env.STOP_MINI_PINATA_FAST_PLACER then
                return false, "engine stopped during remote call", false
            end

            return false, string.format(
                "remote timed out after %.1fs",
                SETTINGS.REMOTE_TIMEOUT
            ), true
        end

        local function getMapCmds()
            if MapCmds then
                return MapCmds
            end

            heartbeat("map module resolution")

            local moduleScript = Client:FindFirstChild("MapCmds")

            if not moduleScript then
                return nil
            end

            local ok, module = pcall(require, moduleScript)

            if ok and type(module) == "table" then
                MapCmds = module
            end

            return MapCmds
        end

        -- v2.0: TTL cache for the farm-area check. The hijack loop calls
        -- this at 10Hz and every placement cycle calls it too, but farm
        -- state never flips inside 0.5s — IsInDottedBox (a pcalled game
        -- module) runs at most twice a second regardless of caller.
        local farmCheckCache = { value = false, at = 0 }
        local FARM_CHECK_TTL = 0.5

        local function isInsideFarmArea()
            heartbeat("farm-area check")

            if os.clock() - farmCheckCache.at < FARM_CHECK_TTL then
                return farmCheckCache.value
            end

            local module = getMapCmds()

            if type(module) ~= "table" or type(module.IsInDottedBox) ~= "function" then
                return false
            end

            local ok, result = pcall(module.IsInDottedBox)
            heartbeat("farm-area check complete")
            farmCheckCache.value = ok and result == true
            farmCheckCache.at = os.clock()
            return farmCheckCache.value
        end

        local function getCharacterRoot()
            local character = LocalPlayer and LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local root = character and character:FindFirstChild("HumanoidRootPart")

            if not humanoid or humanoid.Health <= 0 then
                return nil
            end

            return root
        end

        local farmReadyCount = 0

        local function waitForFarmArea()
            local stableSince = nil
            local stablePosition = nil
            local waitStartedAt = os.clock()
            local isRecovery = farmReadyCount > 0
            local lossAlerted = false

            dashboard.state = isRecovery and "Paused" or "Booting"

            print(string.format(
                "[Runtime] Waiting for GScript farming area for target zone %d.",
                SETTINGS.TARGET_ZONE
            ))

            while not env.STOP_MINI_PINATA_FAST_PLACER do
                heartbeat("waiting for stable farm area")

                if isRecovery
                    and not lossAlerted
                    and os.clock() - waitStartedAt
                        >= SETTINGS.WEBHOOK_FARM_LOSS_DELAY
                then
                    lossAlerted = true
                    sendWebhook({
                        title = "Farm Area Lost",
                        description = "Placement has remained paused long enough to require attention. The engine is waiting for GScript to restore a stable farming position.",
                        color = 16753920,
                        targetZone = SETTINGS.TARGET_ZONE,
                        fields = {
                            webhookField("Placement State", "Paused", true),
                            webhookField("Paused For", formatDuration(os.clock() - waitStartedAt), true),
                            webhookField("Wait Timeout", string.format("%.0f seconds", SETTINGS.FARM_WAIT_TIMEOUT), true),
                        },
                    })
                end

                if os.clock() - waitStartedAt >= SETTINGS.FARM_WAIT_TIMEOUT then
                    error(string.format(
                        "[Runtime] Farming area was not ready after %.0f seconds.",
                        SETTINGS.FARM_WAIT_TIMEOUT
                    ))
                end

                local root = getCharacterRoot()

                if root and isInsideFarmArea() then
                    local position = root.Position

                    if not stablePosition
                        or (position - stablePosition).Magnitude > SETTINGS.POSITION_RADIUS
                    then
                        stablePosition = position
                        stableSince = os.clock()
                    end

                    local positionReady = stableSince
                        and os.clock() - stableSince >= SETTINGS.STABLE_WAIT

                    local startupReady = os.clock() - bootStartedAt >= SETTINGS.STARTUP_WAIT

                    if positionReady and startupReady then
                        print("[Runtime] Farming area stable; placement enabled.")

                        dashboard.state = SETTINGS.CALIBRATION
                            and "Calibrating"
                            or "Running"

                        farmReadyCount += 1

                        if lossAlerted then
                            sendWebhook({
                                title = "Farm Area Recovered",
                                description = "GScript returned the account to a stable farming area. Placement has resumed.",
                                color = 5763719,
                                targetZone = SETTINGS.TARGET_ZONE,
                                fields = {
                                    webhookField("Placement State", "Running", true),
                                    webhookField("Paused For", formatDuration(os.clock() - waitStartedAt), true),
                                    webhookField("Current Interval", string.format("%.2f seconds", currentInterval), true),
                                },
                            })
                        end

                        return true
                    end
                else
                    stableSince = nil
                    stablePosition = nil
                end

                task.wait(SETTINGS.FARM_CHECK_INTERVAL)
            end

            return false
        end

        local function waitForAccountPhase()
            if not SETTINGS.STAGGER then
                return true
            end

            local ok, serverNow = pcall(function()
                return workspace:GetServerTimeNow()
            end)

            if not ok or type(serverNow) ~= "number" then
                if SETTINGS.VERBOSE then
                    warn("[Runtime] Server time unavailable; skipping account stagger.")
                end
                return true
            end

            local userId = LocalPlayer and tonumber(LocalPlayer.UserId) or 0
            local phase = ((userId or 0) % 1009) / 1009 * currentInterval
            local currentPhase = serverNow % currentInterval
            local delay = (phase - currentPhase + currentInterval) % currentInterval

            if delay < 0.05 then
                return true
            end

            if SETTINGS.VERBOSE then
                print(string.format("[Runtime] Account stagger %.2fs.", delay))
            end

            return waitUntil(os.clock() + delay)
        end

        -- ==========================================
        -- GSCRIPT TARGET PRIORITY OVERRIDE (HIJACK)
        -- Incremental target set: one initial
        -- GetDescendants pass, then DescendantAdded/
        -- DescendantRemoving keep the set current.
        -- O(changes) instead of a full tree walk at 10Hz.
        -- ==========================================
        task.spawn(function()
            local PetCmds = nil
            local pinataTargets = {}
            local connections = {}

            local function isPinataModel(obj)
                return obj:IsA("Model")
                    and string.find(string.lower(obj.Name), "pinata", 1, true) ~= nil
            end

            for _, obj in ipairs(workspace:GetDescendants()) do
                if isPinataModel(obj) then
                    pinataTargets[obj] = true
                end
            end

            table.insert(connections, workspace.DescendantAdded:Connect(function(obj)
                if isPinataModel(obj) then
                    pinataTargets[obj] = true
                end
            end))

            table.insert(connections, workspace.DescendantRemoving:Connect(function(obj)
                pinataTargets[obj] = nil
            end))

            while not env.STOP_MINI_PINATA_FAST_PLACER
                and env.__GPINATA_ENGINE_GENERATION == engineGeneration
            do
                if isInsideFarmArea() and getCharacterRoot() then
                    if not PetCmds then
                        local moduleScript = Client:FindFirstChild("PetCmds")

                        if moduleScript then
                            local ok, module = pcall(require, moduleScript)

                            if ok
                                and type(module) == "table"
                                and type(module.SetTarget) == "function"
                            then
                                PetCmds = module
                            end
                        end
                    end

                    local char = LocalPlayer.Character
                    local targetPinata = nil

                    for obj in pairs(pinataTargets) do
                        if obj.Parent
                            and obj:FindFirstChildWhichIsA("TouchTransmitter", true)
                        then
                            targetPinata = obj
                            break
                        end
                    end

                    if targetPinata and char then
                        if PetCmds then
                            pcall(PetCmds.SetTarget, targetPinata)
                        end

                        local pets = char:FindFirstChild("Pets")
                        local pinataRoot = targetPinata:FindFirstChild("HumanoidRootPart")
                            or targetPinata:FindFirstChild("Base")
                            or targetPinata.PrimaryPart

                        if pets and pinataRoot then
                            for _, pet in ipairs(pets:GetChildren()) do
                                if pet:IsA("Model") then
                                    local petHumanoid = pet:FindFirstChildOfClass("Humanoid")
                                    local petRoot = pet:FindFirstChild("HumanoidRootPart")

                                    if petHumanoid and petRoot then
                                        petRoot.CFrame = CFrame.new(
                                            pinataRoot.Position
                                                + Vector3.new(
                                                    math.random(-2, 2),
                                                    math.random(0, 2),
                                                    math.random(-2, 2)
                                                )
                                        )
                                        petHumanoid:MoveTo(pinataRoot.Position)
                                    end
                                end
                            end
                        end

                        local touchPart = targetPinata:FindFirstChildWhichIsA("BasePart", true)
                        local characterRoot = getCharacterRoot()

                        if touchPart
                            and characterRoot
                            and touchPart:FindFirstChildWhichIsA("TouchTransmitter", true)
                        then
                            if type(firetouchinterest) == "function" then
                                pcall(firetouchinterest, characterRoot, touchPart, 0)
                                pcall(firetouchinterest, characterRoot, touchPart, 1)
                            end
                        end
                    end
                end

                task.wait(0.1)
            end

            for _, connection in ipairs(connections) do
                pcall(connection.Disconnect, connection)
            end
        end)

        -- ==========================================
        -- O(1) INVENTORY CACHE LAYER (GSCRIPT-PROOF)
        -- ==========================================
        local saveCache = { data = nil, total = 0, uid = nil, version = 0 }
        local saveCacheAt = 0
        local SAVE_CACHE_TTL = 2.0 -- Increased from 1.5s to 2.0s to ignore GScript rapid mutations

        local function normalize(value)
            if type(value) ~= "string" then return "" end
            return string.lower(value):gsub("[^%w]", "")
        end

        local function getItemAmount(item)
            return tonumber(item._am or item.am or item.amount or item.Amount or item.quantity or item.Quantity or 1) or 1
        end

        local function currencyAmount(value, depth)
            depth = depth or 0
            if depth > 2 then return nil end
            if type(value) == "number" or type(value) == "string" then
                local amount = tonumber(value)
                if amount and amount >= 0 and amount == amount then return amount end
                return nil
            end
            if type(value) ~= "table" then return nil end
            for _, candidate in ipairs({ value._am, value.am, value.amount, value.Amount, value.quantity, value.Quantity, value.value, value.Value, value.balance, value.Balance }) do
                local amount = currencyAmount(candidate, depth + 1)
                if amount ~= nil then return amount end
            end
            return nil
        end

        local function gemCountInContainer(container)
            if type(container) ~= "table" then return nil end
            local best = nil
            for key, value in pairs(container) do
                local keyName = normalize(key)
                local itemName = type(value) == "table" and normalize(value.id or value._id or value.ID or value.Name or value.name) or ""
                if keyName == "diamonds" or keyName == "gems" or itemName == "diamonds" or itemName == "gems" then
                    local amount = currencyAmount(value)
                    if amount ~= nil and (best == nil or amount > best) then best = amount end
                end
            end
            return best
        end

        local function findGemCount(data)
            if type(data) ~= "table" then return nil end
            local inventory = type(data.Inventory) == "table" and data.Inventory or nil
            local containers = {
                inventory and inventory.Currency, inventory and inventory.Currencies,
                data.Currency, data.Currencies, data.currency, data.currencies,
            }
            for _, container in ipairs(containers) do
                local amount = gemCountInContainer(container)
                if amount ~= nil then return amount end
            end
            for _, key in ipairs({ "Diamonds", "diamonds", "Gems", "gems" }) do
                local direct = currencyAmount(data[key])
                if direct ~= nil then return direct end
            end
            return nil
        end

        local function rawFindItemStack(data)
            if type(data) ~= "table" then return nil, 0, false end
            local inventory = data.Inventory
            local misc = inventory and inventory.Misc
            local gems = findGemCount(data)
            if gems ~= nil then dashboard.gems = gems end
            if type(misc) ~= "table" then return nil, 0, true end
            local selectedUid = nil
            local selectedAmount = 0
            local total = 0
            
            -- STRICT MATCHING: Only pay attention to Mini Pinatas. Ignore GScript's gift/egg noise.
            for uid, item in pairs(misc) do
                if type(uid) == "string" and type(item) == "table" then
                    local itemId = item.id or item._id or item.ID or item.Name or item.name
                    if normalize(itemId) == ("mini" .. "pinata") then
                        local amount = getItemAmount(item)
                        if amount > 0 then
                            total += amount
                            if amount > selectedAmount then
                                selectedUid = uid
                                selectedAmount = amount
                            end
                        end
                    end
                end
            end
            
            dashboard.pinatas = total
            return selectedUid, total, true
        end

        local function refreshSaveCache()
            heartbeat("inventory save read")
            local ok, data = pcall(Save.Get)
            heartbeat("inventory save read complete")
            if ok and type(data) == "table" then
                local uid, total, ready = rawFindItemStack(data)
                saveCache.data = data
                env.GPINATA_SAVE_CACHE_DATA = data
                saveCache.uid = uid
                saveCache.total = total
                saveCache.version += 1
                saveCacheAt = os.clock()
                return uid, total, ready
            end
            return nil, 0, false
        end

        local function getCachedUid()
            if saveCache.uid and os.clock() - saveCacheAt < SAVE_CACHE_TTL then
                return saveCache.uid, saveCache.total, true
            end
            return refreshSaveCache()
        end

        local function getReliableTotal()
            if os.clock() - saveCacheAt < 0.05 then
                return saveCache.total
            end
            refreshSaveCache()
            return saveCache.total
        end

        local function waitForInventory()
            local deadline = os.clock() + SETTINGS.INVENTORY_TIMEOUT
            local sawReadyInventory = false
            repeat
                heartbeat("waiting for inventory")
                local uid, total, ready = getCachedUid()
                if ready then
                    sawReadyInventory = true
                    if uid then return uid, total, true end
                end
                task.wait(0.5)
            until os.clock() >= deadline or env.STOP_MINI_PINATA_FAST_PLACER
            return nil, 0, sawReadyInventory
        end

        local function waitForConfirmation(totalBefore)
            local deadline = os.clock() + SETTINGS.CONFIRM_WAIT
            local pollDelays = { 0.05, 0.05, 0.1, 0.2, 0.4, 0.4, 0.25 }
            local pollIndex = 1
            repeat
                heartbeat("inventory confirmation wait")
                local totalAfter = getReliableTotal()
                if totalAfter and totalBefore > 0 and totalAfter < totalBefore then
                    return true, totalBefore - totalAfter, totalAfter
                end
                local remaining = deadline - os.clock()
                if remaining <= 0 then break end
                local waitTime = pollDelays[pollIndex] or 0.25
                pollIndex += 1
                task.wait(math.max(0.05, math.min(waitTime, remaining)))
            until env.STOP_MINI_PINATA_FAST_PLACER
            return false, 0, nil
        end

        -- Background cache monitor
        task.spawn(function()
            while not env.STOP_MINI_PINATA_FAST_PLACER
                and env.__GPINATA_ENGINE_GENERATION == engineGeneration
            do
                if os.clock() - saveCacheAt >= SAVE_CACHE_TTL - 0.1 then
                    refreshSaveCache()
                end
                task.wait(0.5)
            end
        end)

        local function announceNoItems(consoleLine, webhookDescription)
            print(consoleLine)
            dashboard.state = "Stopped"
            dashboard.pinatas = 0
            sendWebhook({
                title = "No Mini Pinatas Available",
                description = webhookDescription,
                color = 16753920,
                targetZone = SETTINGS.TARGET_ZONE,
                fields = {
                    webhookField("Inventory Remaining", "0", true),
                    webhookField("Placement State", "Stopped", true),
                },
            })
            return "no_items"
        end

        local initialUid, initialTotal, inventoryReady = waitForInventory()
        if not initialUid then
            if inventoryReady then
                return announceNoItems(
                    "[Runtime] No Mini Pinatas were found; engine stopped cleanly.",
                    "The engine stopped cleanly because this account had no Mini Pinatas when inventory became available."
                )
            end
            error("[Runtime] Inventory did not become available.")
        end

        if not waitForFarmArea() then return "stopped" end

        initialUid, initialTotal, inventoryReady = waitForInventory()
        if not initialUid then
            if inventoryReady then
                return announceNoItems(
                    "[Runtime] No Mini Pinatas remain; engine stopped cleanly.",
                    "The engine stopped cleanly because the inventory contained no Mini Pinatas after farming began."
                )
            end
            error("[Runtime] Inventory was unavailable after farming began.")
        end

        if not getConsumeEndpoint() then
            error("[Runtime] Consume endpoint could not be resolved.")
        end

        applyFpsCap()
        if not waitForAccountPhase() then return "stopped" end

        dashboard.state = SETTINGS.CALIBRATION and "Calibrating" or "Running"
        dashboard.pinatas = initialTotal
        dashboard.interval = currentInterval
        dashboard.hourly = 3600 / currentInterval
        dashboard.daily = 86400 / currentInterval

        if SETTINGS.CALIBRATION and string.find(dashboard.calibration, "Remembered", 1, true) == nil then
            dashboard.calibration = string.format("Testing %.2fs • 0/%d", currentInterval, SETTINGS.CALIBRATION_MIN_CYCLES)
        end

        if SETTINGS.ADAPTIVE then
            print(string.format("[Runtime] Started | target %.2fs | adaptive %.2f-%.2fs | amount %d", currentInterval, SETTINGS.ADAPTIVE_MIN_INTERVAL, SETTINGS.ADAPTIVE_MAX_INTERVAL, initialTotal))
        else
            print(string.format("[Runtime] Started | interval %.2fs | amount %d", currentInterval, initialTotal))
        end

        local placementRunStartedAt = os.clock()
        local lastWebhookStatusAt = placementRunStartedAt
        local lastReportAt = placementRunStartedAt

        -- v2.0 observability: rejoin counter (persists across supervisor
        -- restarts via calibration file) and server age. Server-side
        -- cooldown floors vary per server instance; a rejoin landing on
        -- a stricter server is the #1 cause of one-account divergence,
        -- and these two fields make that diagnosis instant from the
        -- webhook instead of requiring console archaeology.
        env.__GPINATA_REJOINS_THIS_SESSION = (env.__GPINATA_REJOINS_THIS_SESSION or 0) + 1
        local rejoinsThisSession = env.__GPINATA_REJOINS_THIS_SESSION

        local function serverAgeSeconds()
            local ok, started = pcall(function()
                return workspace:GetServerTimeNow() - game.PrivateServerIdSeqId
            end)

            return ok and started or nil
        end
        local cycles = 0
        local confirmed = 0
        local remoteCalls = 0
        local retries = 0
        local recoveredCycles = 0
        local firstRetryRecoveries = 0
        local secondRetryRecoveries = 0
        local lateConfirmations = 0
        local rejected = 0
        local rejectedStreak = 0
        local rejectionAlertActive = false
        local circuitBreakerActive = false
        local circuitBreakerDelay = SETTINGS.CIRCUIT_BREAKER_INITIAL_DELAY
        local circuitBreakerTrips = 0
        local circuitStartedAt = nil
        local circuitDowntimeTotal = 0
        local failedCycles = 0
        local errors = 0
        local timeouts = 0
        local consecutiveRemoteErrors = 0
        local inventoryUnavailableSince = nil
        local lastResponse = nil
        local lastKnownTotal = initialTotal
        local noItemsRemain = false
        local lastSuccessAt = os.clock()

        -- Phase timing (EMA, milliseconds): where the per-cycle time
        -- beyond the interval actually goes.
        --   gateOvershoot: how late the invoke landed past the pacing gate
        --   invokeLatency: gate-cross to server response (incl. FPS spike)
        --   postConfirm:   response arrival to cycle bookkeeping complete
        local phaseStats = {
            gateOvershootMs = 0,
            invokeLatencyMs = 0,
            postConfirmMs = 0,
        }

        local function samplePhaseStat(key, milliseconds)
            phaseStats[key] = phaseStats[key] * 0.9 + math.max(0, milliseconds) * 0.1
        end

        local telemetryRequest = resolveRequestFunction()
        local telemetryEndpoint = type(env.GTELEMETRY_ENDPOINT) == "string" and env.GTELEMETRY_ENDPOINT:match("^https://[^%s]+$") or nil
        local telemetryWriteKey = type(env.GTELEMETRY_WRITE_KEY) == "string" and env.GTELEMETRY_WRITE_KEY or nil
        local telemetryInterval = math.max(20, math.min(30, numberSetting("GTELEMETRY_INTERVAL_SECONDS", 25)))
        local telemetryLastConfirmationAt = 0
        local telemetryPublisherRunning = false
        local telemetryPinataCostPerUnit = math.max(0, numberSetting("GPINATA_COST_PER_UNIT", 50000))

        local reportSnapshot = {
            cycles = 0, confirmed = 0, calls = 0, recovered = 0, rejected = 0, failed = 0, errors = 0, timeouts = 0,
            gems = tonumber(dashboard.gems), pinatas = initialTotal, circuitDowntime = 0,
        }

        local calibrationSegmentStartedAt = os.clock()
        local calibrationSegmentInterval = currentInterval
        local calibrationSegmentCycles = 0
        local calibrationSegmentRejected = 0
        local calibrationSegmentFailed = 0
        local calibrationSegmentSecondRetries = 0
        local calibrationSegmentContaminated = false
        local calibrationSegmentQualified = false
        local calibrationBlockedUntil = 0
        local calibrationQualifiedLabel = nil

        local function resetCalibrationSegment(reason)
            calibrationSegmentStartedAt = os.clock()
            calibrationSegmentInterval = currentInterval
            calibrationSegmentCycles = 0
            calibrationSegmentRejected = 0
            calibrationSegmentFailed = 0
            calibrationSegmentSecondRetries = 0
            calibrationSegmentContaminated = false
            calibrationSegmentQualified = false
            calibrationBlockedUntil = 0
            calibrationQualifiedLabel = nil
            if SETTINGS.CALIBRATION then
                dashboard.calibration = string.format("Testing %.2fs • 0/%d", currentInterval, SETTINGS.CALIBRATION_MIN_CYCLES)
            end
            if SETTINGS.VERBOSE and reason then
                print("[Runtime] Calibration reset: " .. tostring(reason))
            end
        end

        local function recordCalibrationSample(cycleConfirmed, cycleRejected, usedSecondRetry)
            if not SETTINGS.CALIBRATION then return end
            if circuitBreakerActive then
                calibrationSegmentContaminated = true
                calibrationBlockedUntil = math.max(calibrationBlockedUntil, os.clock() + SETTINGS.ADAPTIVE_FAILURE_HOLD)
                dashboard.calibration = "Excluded stuck-area episode"
                return
            end
            local unhealthyRemaining = zoneHealthRemaining()
            if unhealthyRemaining > 0 then
                calibrationSegmentContaminated = true
                calibrationBlockedUntil = math.max(calibrationBlockedUntil, os.clock() + unhealthyRemaining)
                dashboard.calibration = "Zone recovery lock • " .. formatDuration(unhealthyRemaining)
                return
            end
            local recoveryLockRemaining = math.max(0, (tonumber(calibrationProfile.nextRecoveryAllowedAt) or 0) - os.time())
            if recoveryLockRemaining > 0 then
                calibrationSegmentContaminated = true
                calibrationBlockedUntil = math.max(calibrationBlockedUntil, os.clock() + recoveryLockRemaining)
                dashboard.calibration = "Recovery evidence lock • " .. formatDuration(recoveryLockRemaining)
                return
            end
            if calibrationSegmentContaminated and os.clock() >= calibrationBlockedUntil and cycleConfirmed then
                resetCalibrationSegment("contaminated evidence expired")
            end
            if math.abs(calibrationSegmentInterval - currentInterval) >= 0.001 then
                resetCalibrationSegment("interval changed")
            end
            if calibrationSegmentQualified then
                dashboard.calibration = calibrationQualifiedLabel or string.format("Qualified %.2fs • %d clean", currentInterval, calibrationSegmentCycles)
                return
            end
            calibrationSegmentCycles += 1
            if cycleRejected then calibrationSegmentRejected += 1 end
            if not cycleConfirmed then
                calibrationSegmentFailed += 1
                calibrationSegmentContaminated = true
                calibrationBlockedUntil = math.max(calibrationBlockedUntil, os.clock() + SETTINGS.ADAPTIVE_FAILURE_HOLD)
            end
            if usedSecondRetry then
                calibrationSegmentSecondRetries += 1
                calibrationSegmentContaminated = true
                calibrationBlockedUntil = math.max(calibrationBlockedUntil, os.clock() + SETTINGS.ADAPTIVE_RECOVERY_HOLD)
            end
            local elapsed = os.clock() - calibrationSegmentStartedAt
            local rejectRate = calibrationSegmentCycles > 0 and calibrationSegmentRejected / calibrationSegmentCycles or 0
            dashboard.calibration = string.format("Testing %.2fs • %d/%d", currentInterval, math.min(calibrationSegmentCycles, SETTINGS.CALIBRATION_MIN_CYCLES), SETTINGS.CALIBRATION_MIN_CYCLES)
            local qualifies = not calibrationSegmentQualified
                and not calibrationSegmentContaminated
                and calibrationSegmentCycles >= SETTINGS.CALIBRATION_MIN_CYCLES
                and elapsed >= SETTINGS.CALIBRATION_MIN_SECONDS
                and rejectRate <= SETTINGS.CALIBRATION_MAX_REJECT_RATE
            if not qualifies then return end
            calibrationSegmentQualified = true
            calibrationProfile.recommendedInterval = currentInterval
            rememberZoneInterval(SETTINGS.TARGET_ZONE, currentInterval)
            calibrationProfile.qualifiedCycles = calibrationSegmentCycles
            calibrationProfile.qualifiedSeconds = math.floor(elapsed)
            calibrationProfile.rejectRate = rejectRate
            calibrationProfile.failedCycles = calibrationSegmentFailed
            calibrationProfile.secondRetries = calibrationSegmentSecondRetries
            calibrationProfile.provisional = false
            calibrationProfile.provisionalReason = nil
            if (tonumber(calibrationProfile.nextRecoveryAllowedAt) or 0) <= os.time() then
                calibrationProfile.nextRecoveryAllowedAt = 0
            end
            local saved = saveCalibrationProfile()
            calibrationQualifiedLabel = string.format("%s %.2fs • %d clean", saved and "Remembered" or "Qualified", currentInterval, calibrationSegmentCycles)
            dashboard.calibration = calibrationQualifiedLabel
            dashboard.state = "Running"
        end

        local function telemetryStatus()
            if dashboard.state == "Circuit" then return "blocked" end
            if dashboard.state == "Fault" or dashboard.state == "Stopped" then return "offline" end
            if dashboard.state == "Paused" or dashboard.state == "Booting" then return "degraded" end
            return "healthy"
        end

        local function publishTelemetry()
            if not telemetryRequest or not telemetryEndpoint or not telemetryWriteKey then return end
            local currentTotal = getReliableTotal()
            if currentTotal ~= nil then
                lastKnownTotal = currentTotal
                dashboard.pinatas = currentTotal
            end
            local elapsed = math.max(1, os.clock() - placementRunStartedAt)
            local observedPerMinute = confirmed / elapsed * 60
            local currentCircuitDowntime = circuitDowntimeTotal
            if circuitBreakerActive and circuitStartedAt then
                currentCircuitDowntime += math.max(0, os.clock() - circuitStartedAt)
            end
            local uptimePercent = math.max(0, math.min(100, (elapsed - currentCircuitDowntime) / elapsed * 100))
            local supplyMinutes = observedPerMinute > 0 and lastKnownTotal / observedPerMinute or 0
            local ledgerSnapshot = type(env.GLEDGER_LIVE_SNAPSHOT) == "table" and env.GLEDGER_LIVE_SNAPSHOT or {}
            local directWindowNetGain = tonumber(ledgerSnapshot.windowNetGain) or 0
            local directHourlyNetGain = tonumber(ledgerSnapshot.hourlyNetGain) or 0
            local directDailyNetGain = tonumber(ledgerSnapshot.dailyNetGain) or 0
            local ledgerWindowSeconds = math.max(1, tonumber(ledgerSnapshot.windowSeconds) or elapsed)
            local windowPinatasConsumed = math.max(0, math.floor(tonumber(ledgerSnapshot.windowPinatasConsumed) or 0))
            local dailyPinatasConsumed = math.max(0, math.floor(tonumber(ledgerSnapshot.dailyPinatasConsumed) or 0))
            local windowPinataCost = windowPinatasConsumed * telemetryPinataCostPerUnit
            local dailyPinataCost = dailyPinatasConsumed * telemetryPinataCostPerUnit
            local windowNetGain = directWindowNetGain - windowPinataCost
            local hourlyNetGain = directHourlyNetGain - windowPinataCost / ledgerWindowSeconds * 3600
            local dailyNetGain = directDailyNetGain - dailyPinataCost
            local payload = {
                accountName = LocalPlayer and LocalPlayer.Name or "unknown",
                robloxUserId = tostring(LocalPlayer and LocalPlayer.UserId or 0),
                ledgerDay = ledgerSnapshot.ledgerDay,
                ledgerSessionId = ledgerSnapshot.ledgerSessionId,
                ledgerSessionStartedAt = ledgerSnapshot.ledgerSessionStartedAt,
                status = telemetryStatus(),
                placementRatePerMinute = observedPerMinute,
                confirmed = confirmed,
                attempted = cycles,
                adaptiveIntervalSeconds = currentInterval,
                phaseGateOvershootMs = math.floor(phaseStats.gateOvershootMs + 0.5),
                phaseInvokeLatencyMs = math.floor(phaseStats.invokeLatencyMs + 0.5),
                phasePostConfirmMs = math.floor(phaseStats.postConfirmMs + 0.5),
                pinatasRemaining = lastKnownTotal,
                supplyDurationMinutes = supplyMinutes,
                pinatasConsumed = math.max(0, initialTotal - lastKnownTotal),
                dailyPinatasConsumed = dailyPinatasConsumed,
                runtimeSeconds = elapsed,
                engineRejoinsThisSession = rejoinsThisSession,
                serverAgeSeconds = serverAgeSeconds(),
                lastConfirmationAt = telemetryLastConfirmationAt,
                uptimePercent = uptimePercent,
                windowNetGain = windowNetGain,
                hourlyNetGain = hourlyNetGain,
                dailyNetGain = dailyNetGain,
                windowDiamondNetGain = windowNetGain,
                hourlyDiamondNetGain = hourlyNetGain,
                dailyDiamondNetGain = dailyNetGain,
                ledgerWindowSeconds = ledgerWindowSeconds,
                windowLootGained = ledgerSnapshot.windowLootGained or {},
                dailyLootGained = ledgerSnapshot.dailyLootGained or {},
            }
            local encodedOk, body = pcall(HttpService.JSONEncode, HttpService, payload)
            if not encodedOk then return end
            pcall(telemetryRequest, {
                Url = telemetryEndpoint,
                Method = "POST",
                Headers = {
                    ["Authorization"] = "Bearer " .. telemetryWriteKey,
                    ["Content-Type"] = "application/json",
                },
                Body = body,
            })
        end

        local function startTelemetryPublisher()
            if telemetryPublisherRunning or not telemetryRequest or not telemetryEndpoint or not telemetryWriteKey then return end
            telemetryPublisherRunning = true
            task.spawn(function()
                while not env.STOP_MINI_PINATA_FAST_PLACER
                    and env.__GPINATA_ENGINE_GENERATION == engineGeneration
                do
                    publishTelemetry()
                    local deadline = os.clock() + telemetryInterval
                    while not env.STOP_MINI_PINATA_FAST_PLACER and os.clock() < deadline do
                        task.wait(math.min(1, deadline - os.clock()))
                    end
                end
                telemetryPublisherRunning = false
            end)
        end

        startTelemetryPublisher()

        local function recordConfirmation(amountUsed, totalAfter)
            local firstConfirmation = confirmed == 0
            confirmed += amountUsed
            telemetryLastConfirmationAt = math.floor(os.time() * 1000)
            lastKnownTotal = totalAfter or math.max(0, lastKnownTotal - amountUsed)
            saveCache.total = lastKnownTotal
            dashboard.pinatas = lastKnownTotal
            local elapsed = math.max(1, os.clock() - placementRunStartedAt)
            dashboard.hourly = confirmed / elapsed * 3600
            dashboard.daily = dashboard.hourly * 24
            dashboard.successRate = cycles > 0 and confirmed / cycles * 100 or 100
            if firstConfirmation or SETTINGS.VERBOSE then
                print(string.format("[Runtime] Placed | remaining %d | confirmed %d", totalAfter, confirmed))
            end
        end

        local function printStatus()
            if cycles == 0 then return end
            local now = os.clock()
            local shouldPrint = cycles % SETTINGS.STATUS_EVERY == 0
            local shouldWebhook = webhookEnabled and now - lastWebhookStatusAt >= SETTINGS.WEBHOOK_STATUS_SECONDS
            if not shouldPrint and not shouldWebhook then return end
            local elapsed = math.max(1, os.clock() - placementRunStartedAt)
            local acceptedPerHour = confirmed / elapsed * 3600
            local projectedPerDay = acceptedPerHour * 24
            local successRate = confirmed / cycles * 100
            local callEfficiency = remoteCalls > 0 and confirmed / remoteCalls * 100 or 0
            local recoveryRate = recoveredCycles / cycles * 100
            dashboard.interval = currentInterval
            dashboard.hourly = acceptedPerHour
            dashboard.daily = projectedPerDay
            dashboard.successRate = successRate
            if circuitBreakerActive then
                dashboard.state = "Circuit"
            elseif SETTINGS.CALIBRATION and not calibrationSegmentQualified then
                dashboard.state = "Calibrating"
            else
                dashboard.state = "Running"
            end
            if shouldPrint then
                print(string.format("[Runtime] Status | cycles %d | confirmed %d | calls %d | retries %d | recovered %d | retry2 %d | rejected %d | failed %d | reject streak %d | errors %d | timeouts %d | interval %.2fs | %.1f/hour | %.0f/day | response %s | overhead gate %.0fms invoke %.0fms post %.0fms", cycles, confirmed, remoteCalls, retries, recoveredCycles, secondRetryRecoveries, rejected, failedCycles, rejectedStreak, errors, timeouts, currentInterval, acceptedPerHour, projectedPerDay, tostring(lastResponse), phaseStats.gateOvershootMs, phaseStats.invokeLatencyMs, phaseStats.postConfirmMs))
            end
            if shouldWebhook then
                lastWebhookStatusAt = now
                local currentCircuitDowntime = circuitDowntimeTotal
                if circuitBreakerActive and circuitStartedAt then
                    currentCircuitDowntime += now - circuitStartedAt
                end
                local windowElapsed = math.max(1, now - lastReportAt)
                local windowCycles = math.max(0, cycles - reportSnapshot.cycles)
                local windowConfirmed = math.max(0, confirmed - reportSnapshot.confirmed)
                local windowCalls = math.max(0, remoteCalls - reportSnapshot.calls)
                local windowRecovered = math.max(0, recoveredCycles - reportSnapshot.recovered)
                local windowRejected = math.max(0, rejected - reportSnapshot.rejected)
                local windowFailed = math.max(0, failedCycles - reportSnapshot.failed)
                local windowErrors = math.max(0, errors - reportSnapshot.errors)
                local windowTimeouts = math.max(0, timeouts - reportSnapshot.timeouts)
                local windowCircuitDowntime = math.max(0, currentCircuitDowntime - reportSnapshot.circuitDowntime)
                local windowSuccessRate = windowCycles > 0 and windowConfirmed / windowCycles * 100 or 0
                local windowCallEfficiency = windowCalls > 0 and windowConfirmed / windowCalls * 100 or 0
                local windowPerHour = windowConfirmed / windowElapsed * 3600
                local windowGemDelta = dashboard.gems ~= nil and reportSnapshot.gems ~= nil and dashboard.gems - reportSnapshot.gems or nil
                local windowGemText = windowGemDelta == nil and "Updating…" or string.format("%s%s (`%s`)", windowGemDelta >= 0 and "+" or "", formatCompact(windowGemDelta), formatInteger(windowGemDelta))
                local windowPinatasUsed = math.max(0, (reportSnapshot.pinatas or lastKnownTotal) - lastKnownTotal)
                local initialAccepted = math.max(0, cycles - recoveredCycles - failedCycles)
                local initialPassRate = cycles > 0 and initialAccepted / cycles * 100 or 0
                local reportCadenceMinutes = SETTINGS.WEBHOOK_STATUS_SECONDS / 60
                sendWebhook({
                    periodic = true,
                    title = "3-Hour Placement Update",
                    description = "Scheduled three-hour report. The dashboard reflects live gems, remaining piñatas, interval and observed placement speed.",
                    color = windowFailed == 0 and (windowCycles == 0 or windowRecovered / windowCycles * 100 < 5) and 3447003 or 16753920,
                    targetZone = SETTINGS.TARGET_ZONE,
                    fields = {
                        webhookField(string.format("📊 Last %g Minutes", reportCadenceMinutes), string.format("**%s/%s confirmed** — %.2f%%\n**%.1f/hour observed** • Calls: %s • Efficiency: %.2f%%\nGems: **%s** • Piñatas used: **%s**\nRecovered: %s • Rejections: %s • Failed: %s\nWindow: %s • Circuit downtime: %s", formatInteger(windowConfirmed), formatInteger(windowCycles), windowSuccessRate, windowPerHour, formatInteger(windowCalls), windowCallEfficiency, windowGemText, formatInteger(windowPinatasUsed), formatInteger(windowRecovered), formatInteger(windowRejected), formatInteger(windowFailed), formatDuration(windowElapsed), formatDuration(windowCircuitDowntime)), false),
                        webhookField("⚡ Placement Performance", string.format("**%s/%s confirmed** — %.2f%%\n**%.1f/hour** — %.0f/day\nCurrent interval: **%.2fs**\nCycle overhead: gate **%.0fms** • invoke **%.0fms** • post **%.0fms**", formatInteger(confirmed), formatInteger(cycles), successRate, acceptedPerHour, projectedPerDay, currentInterval, phaseStats.gateOvershootMs, phaseStats.invokeLatencyMs, phaseStats.postConfirmMs), false),
                        webhookField("🛡️ Consistency", string.format("First-pass acceptance: **%.2f%%**\nCall efficiency: **%.2f%%**\nRejections: %s • Failed cycles: %s", initialPassRate, callEfficiency, formatInteger(rejected), formatInteger(failedCycles)), false),
                        webhookField("🔁 Recovery", string.format("Recovered: %s (%.2f%%)\nRetry 1: %s • Retry 2: %s • Late: %s", formatInteger(recoveredCycles), recoveryRate, formatInteger(firstRetryRecoveries), formatInteger(secondRetryRecoveries), formatInteger(lateConfirmations)), false),
                        webhookField("🧠 Account Calibration", tostring(dashboard.calibration) .. "\nCircuit: " .. (circuitBreakerActive and string.format("ACTIVE — %.0fs probe", circuitBreakerDelay) or "inactive") .. " • Trips: " .. formatInteger(circuitBreakerTrips), false),
                        webhookField("📡 Communication Health", string.format("%s\nCalls: %s • Errors: %s • Timeouts: %s\nWindow errors: %s • Window timeouts: %s\nLast response: `%s`", tostring(dashboard.remote), formatInteger(remoteCalls), formatInteger(errors), formatInteger(timeouts), formatInteger(windowErrors), formatInteger(windowTimeouts), tostring(lastResponse)), false),
                        webhookField("🕒 Run Snapshot", string.format("Remaining supply: %s\nCompleted cycles: %s\nEngine restarts this session: %s\nNext scheduled update: %g minutes", formatInteger(lastKnownTotal), formatInteger(cycles), tostring(rejoinsThisSession), reportCadenceMinutes), false),
                    },
                })
                lastReportAt = now
                reportSnapshot.cycles = cycles
                reportSnapshot.confirmed = confirmed
                reportSnapshot.calls = remoteCalls
                reportSnapshot.recovered = recoveredCycles
                reportSnapshot.rejected = rejected
                reportSnapshot.failed = failedCycles
                reportSnapshot.errors = errors
                reportSnapshot.timeouts = timeouts
                reportSnapshot.gems = tonumber(dashboard.gems)
                reportSnapshot.pinatas = lastKnownTotal
                reportSnapshot.circuitDowntime = currentCircuitDowntime
            end
        end

        local function getRejectionBackoff(streak)
            if streak <= 0 then return 0 end
            local exponent = math.min(streak - 1, 4)
            return math.min(SETTINGS.REJECTION_BACKOFF_MAX, SETTINGS.REJECTION_BACKOFF_BASE * (2 ^ exponent))
        end

        local adaptiveWindowCycles = 0
        local adaptiveWindowRejected = 0
        local adaptivePressureWindows = 0
        local adaptiveHistory = table.create(SETTINGS.ADAPTIVE_LONG_WINDOW)
        local adaptiveHistoryCount = 0
        local adaptiveHistoryNext = 1
        local adaptiveHistoryRejected = 0
        local adaptiveHistoryFailed = 0
        local adaptiveHistorySecondRetries = 0
        local adaptiveValidCycleIndex = 0
        local isolatedFailureMarks = {}
        local persistedRecoveryRemaining = math.max(0, (tonumber(calibrationProfile.nextRecoveryAllowedAt) or 0) - os.time())
        local adaptiveRecoveryNotBefore = os.clock() + math.max(persistedRecoveryRemaining, zoneHealthRemaining())

        if zoneHealthRemaining() > 0 then
            dashboard.calibration = "Zone recovery lock • " .. formatDuration(zoneHealthRemaining())
        end

        local function resetAdaptiveWindow()
            adaptiveWindowCycles = 0
            adaptiveWindowRejected = 0
        end

        local function clearAdaptiveHistory()
            table.clear(adaptiveHistory)
            adaptiveHistoryCount = 0
            adaptiveHistoryNext = 1
            adaptiveHistoryRejected = 0
            adaptiveHistoryFailed = 0
            adaptiveHistorySecondRetries = 0
        end

        local function pushAdaptiveHistory(cycleConfirmed, cycleRejected, usedSecondRetry)
            local sample = (cycleRejected == true and 1 or 0) + (cycleConfirmed ~= true and 2 or 0) + (usedSecondRetry == true and 4 or 0)
            if adaptiveHistoryCount >= SETTINGS.ADAPTIVE_LONG_WINDOW then
                local removed = adaptiveHistory[adaptiveHistoryNext]
                if removed then
                    if removed % 2 == 1 then adaptiveHistoryRejected -= 1 end
                    if math.floor(removed / 2) % 2 == 1 then adaptiveHistoryFailed -= 1 end
                    if removed >= 4 then adaptiveHistorySecondRetries -= 1 end
                end
            else
                adaptiveHistoryCount += 1
            end
            adaptiveHistory[adaptiveHistoryNext] = sample
            adaptiveHistoryNext = adaptiveHistoryNext % SETTINGS.ADAPTIVE_LONG_WINDOW + 1
            if cycleRejected then adaptiveHistoryRejected += 1 end
            if not cycleConfirmed then adaptiveHistoryFailed += 1 end
            if usedSecondRetry then adaptiveHistorySecondRetries += 1 end
        end

        local function pruneIsolatedFailures()
            local oldestAllowed = adaptiveValidCycleIndex - SETTINGS.ISOLATED_FAILURE_WINDOW
            while #isolatedFailureMarks > 0 and isolatedFailureMarks[1] <= oldestAllowed do
                table.remove(isolatedFailureMarks, 1)
            end
        end

        local function applyAdaptiveIntervalChange(requestedInterval, adjustmentReason, evidence, holdSeconds)
            local previousInterval = currentInterval
            currentInterval = math.max(SETTINGS.ADAPTIVE_MIN_INTERVAL, math.min(SETTINGS.ADAPTIVE_MAX_INTERVAL, math.floor(requestedInterval * 100 + 0.5) / 100))
            if math.abs(currentInterval - previousInterval) < 0.001 then return false end
            evidence = evidence or {}
            holdSeconds = math.max(tonumber(holdSeconds) or SETTINGS.ADAPTIVE_RECOVERY_HOLD, SETTINGS.ADAPTIVE_RECOVERY_HOLD)
            local now = os.clock()
            local slowedDown = currentInterval > previousInterval
            dashboard.interval = currentInterval
            resetCalibrationSegment("adaptive interval adjustment")
            print(string.format("[Runtime] Adaptive | %.2fs -> %.2fs | %s | rejected %d/%d | failed %d", previousInterval, currentInterval, adjustmentReason or "evidence update", tonumber(evidence.windowRejected) or 0, tonumber(evidence.windowCycles) or 0, tonumber(evidence.windowFailed) or 0))
            local protectiveProfileSaved = false
            if slowedDown and SETTINGS.CALIBRATION and currentInterval > (tonumber(calibrationProfile.recommendedInterval) or SETTINGS.ADAPTIVE_MIN_INTERVAL) then
                calibrationProfile.recommendedInterval = currentInterval
                calibrationProfile.provisional = true
                calibrationProfile.provisionalReason = adjustmentReason
                calibrationProfile.qualifiedCycles = 0
                calibrationProfile.qualifiedSeconds = 0
                protectiveProfileSaved = saveCalibrationProfile()
                dashboard.calibration = string.format("%s protective %.2fs", protectiveProfileSaved and "Remembered" or "Session", currentInterval)
            end
            adaptiveRecoveryNotBefore = math.max(adaptiveRecoveryNotBefore, now + holdSeconds)
            persistRecoveryLock(holdSeconds, adjustmentReason)
            local historyCycles = tonumber(evidence.historyCycles) or adaptiveHistoryCount
            local historyRejectRate = tonumber(evidence.historyRejectRate) or (historyCycles > 0 and adaptiveHistoryRejected / historyCycles or 0)
            local cumulativeSuccessRate = cycles > 0 and confirmed / cycles * 100 or 0
            sendWebhook({
                title = slowedDown and "Adaptive Rate Slowed" or "Adaptive Rate Recovered",
                description = slowedDown and "The consistency controller found repeated pacing evidence and made one protective interval change. Quarantined zone failures cannot directly force a speed change." or string.format("%d clean evidence cycles plus the recovery lock allowed one cautious step toward the %.2f-second target.", SETTINGS.ADAPTIVE_LONG_WINDOW, SETTINGS.TARGET_INTERVAL),
                color = slowedDown and 16753920 or 5763719,
                targetZone = SETTINGS.TARGET_ZONE,
                fields = {
                    webhookField("Adjustment Reason", adjustmentReason or "Evidence update", false),
                    webhookField("Previous Interval", string.format("%.2f seconds", previousInterval), true),
                    webhookField("New Interval", string.format("%.2f seconds", currentInterval), true),
                    webhookField("Change", string.format("%+.2f seconds", currentInterval - previousInterval), true),
                    webhookField("Short Evidence", string.format("%d cycles • %d rejected • %d quarantined failures", tonumber(evidence.windowCycles) or 0, tonumber(evidence.windowRejected) or 0, tonumber(evidence.isolatedFailures) or 0), false),
                    webhookField("Long Recovery Evidence", string.format("%d/%d cycles • %.2f%% rejected • %d second retries", historyCycles, SETTINGS.ADAPTIVE_LONG_WINDOW, historyRejectRate * 100, adaptiveHistorySecondRetries), false),
                    webhookField("Next Recovery Lock", formatDuration(holdSeconds), true),
                    webhookField("Zone Health", zoneHealthRemaining() > 0 and ("Recovery locked for " .. formatDuration(zoneHealthRemaining())) or "Healthy", true),
                    webhookField("Calibration Memory", slowedDown and (protectiveProfileSaved and "Protective interval saved for the next relaunch" or "Protective interval and recovery lock active") or "Faster interval must complete full calibration before being remembered", false),
                    webhookField("Cumulative Confirmed", string.format("%s/%s", formatInteger(confirmed), formatInteger(cycles)), true),
                    webhookField("Cumulative Success", string.format("%.2f%%", cumulativeSuccessRate), true),
                    webhookField("Observed Pace", string.format("%.1f/hour | %.0f/day", dashboard.hourly or 0, dashboard.daily or 0), true),
                    webhookField("Clean-Path Ceiling", string.format("%.1f/min | %.0f/day", 60 / currentInterval, 86400 / currentInterval), true),
                    webhookField("Allowed Range", string.format("%.2f-%.2f seconds", SETTINGS.ADAPTIVE_MIN_INTERVAL, SETTINGS.ADAPTIVE_MAX_INTERVAL), true),
                },
            })
            resetAdaptiveWindow()
            isolatedFailureMarks = {}

            -- 2.2: evidence accumulates across speed-up steps. Wiping
            -- history on every -0.05s step reset the qualification race
            -- and made recovery take (steps x long-window) instead of
            -- one long-window. Pressure (slow-down) events still wipe.
            if slowedDown then
                clearAdaptiveHistory()
            end

            return true
        end

        local function updateAdaptiveRate(cycleConfirmed, cycleRejected, usedSecondRetry, recoveredFailureStreak, recoveredFromCircuit)
            if not SETTINGS.ADAPTIVE then return end
            local now = os.clock()
            if not cycleConfirmed then
                adaptivePressureWindows = 0
                adaptiveRecoveryNotBefore = math.max(adaptiveRecoveryNotBefore, now + SETTINGS.ADAPTIVE_FAILURE_HOLD)
                persistRecoveryLock(SETTINGS.ADAPTIVE_FAILURE_HOLD, "quarantined failed placement")
                resetAdaptiveWindow()
                clearAdaptiveHistory()
                return
            end
            recoveredFailureStreak = math.max(0, math.floor(tonumber(recoveredFailureStreak) or 0))
            if circuitBreakerActive or recoveredFromCircuit then
                adaptivePressureWindows = 0
                adaptiveRecoveryNotBefore = math.max(adaptiveRecoveryNotBefore, now + SETTINGS.ADAPTIVE_FAILURE_HOLD)
                resetAdaptiveWindow()
                clearAdaptiveHistory()
                return
            end
            adaptiveValidCycleIndex += 1
            pruneIsolatedFailures()
            if recoveredFailureStreak > 0 then
                table.insert(isolatedFailureMarks, adaptiveValidCycleIndex)
                adaptiveRecoveryNotBefore = math.max(adaptiveRecoveryNotBefore, now + SETTINGS.ADAPTIVE_FAILURE_HOLD)
                persistRecoveryLock(SETTINGS.ADAPTIVE_FAILURE_HOLD, "isolated failure quarantine")
                resetAdaptiveWindow()
                clearAdaptiveHistory()
                if #isolatedFailureMarks >= SETTINGS.ISOLATED_FAILURES_TO_SLOW then
                    applyAdaptiveIntervalChange(currentInterval + SETTINGS.ISOLATED_FAILURE_STEP, "repeated isolated failures", { isolatedFailures = #isolatedFailureMarks, windowCycles = SETTINGS.ISOLATED_FAILURE_WINDOW }, SETTINGS.ADAPTIVE_FAILURE_HOLD)
                end
                return
            end
            pushAdaptiveHistory(cycleConfirmed, cycleRejected, usedSecondRetry)
            adaptiveWindowCycles += 1
            if cycleRejected then adaptiveWindowRejected += 1 end

            -- v2.0 anti-drift: if we booted from a remembered interval
            -- but the first cycles on THIS server reject well above the
            -- calibration bar, the new server's floor is stricter than
            -- the remembered one. Demote the profile to provisional and
            -- let the adaptive controller re-qualify from current
            -- evidence instead of bleeding rejections for a full
            -- calibration segment.
            if calibrationLoadedRemembered
                and not calibrationProfile.provisional
                and adaptiveWindowCycles + adaptiveHistoryCount <= 20
                and adaptiveWindowRejected >= 2
            then
                calibrationProfile.provisional = true
                calibrationProfile.provisionalReason = "early rejections exceed calibration on this server"
                resetCalibrationSegment("server drift detected")
                dashboard.calibration = string.format(
                    "Validating %.2fs • server drift",
                    currentInterval
                )
                print("[Runtime] Calibration | remembered interval marked provisional: new server rejecting above calibration rate")
            end

            if adaptiveWindowCycles < SETTINGS.ADAPTIVE_WINDOW then return end
            local rejectRate = adaptiveWindowRejected / adaptiveWindowCycles
            local historyCycles = adaptiveHistoryCount
            local historyRejectRate = historyCycles > 0 and adaptiveHistoryRejected / historyCycles or 0
            local evidence = {
                windowCycles = adaptiveWindowCycles,
                windowRejected = adaptiveWindowRejected,
                windowFailed = 0,
                historyCycles = historyCycles,
                historyRejectRate = historyRejectRate,
            }
            if rejectRate >= SETTINGS.ADAPTIVE_HIGH_REJECT_RATE then
                adaptivePressureWindows += 1
                if adaptivePressureWindows >= SETTINGS.ADAPTIVE_PRESSURE_WINDOWS then
                    adaptivePressureWindows = 0
                    if applyAdaptiveIntervalChange(currentInterval + SETTINGS.ADAPTIVE_PRESSURE_STEP, "persistent recovered rejection pressure", evidence, SETTINGS.ADAPTIVE_RECOVERY_HOLD) then return end
                end
            else
                adaptivePressureWindows = 0
            end
            local longWindowReady = historyCycles >= SETTINGS.ADAPTIVE_LONG_WINDOW
            local recoveryEvidenceClean = longWindowReady
                and adaptiveHistoryFailed == 0
                and adaptiveHistorySecondRetries <= SETTINGS.ADAPTIVE_RECOVERY_MAX_SECOND_RETRIES
                and historyRejectRate <= SETTINGS.ADAPTIVE_RECOVERY_MAX_REJECT_RATE
            local recoveryHoldComplete = now >= adaptiveRecoveryNotBefore
            local zoneHealthy = zoneHealthRemaining() <= 0
            -- 2.2 hold-at-target: stop probing downward once the engine
            -- confirms at TARGET_INTERVAL. The floor exists for
            -- slow-down recovery overflow, not for pace-chasing.
            local aboveTarget = currentInterval - SETTINGS.TARGET_INTERVAL > 0.001
            if rejectRate < SETTINGS.ADAPTIVE_HIGH_REJECT_RATE
                and currentInterval > SETTINGS.ADAPTIVE_MIN_INTERVAL
                and aboveTarget
                and recoveryEvidenceClean
                and recoveryHoldComplete
                and zoneHealthy
            then
                if applyAdaptiveIntervalChange(math.max(SETTINGS.TARGET_INTERVAL, currentInterval - SETTINGS.ADAPTIVE_STEP_DOWN), "long-window stable recovery", evidence, SETTINGS.ADAPTIVE_RECOVERY_HOLD) then return end
            end
            resetAdaptiveWindow()
        end

        local function clearRejectionStreak()
            local recoveredStreak = rejectedStreak
            local recoveredFromCircuit = circuitBreakerActive
            local recoveredCircuitDelay = circuitBreakerDelay
            rejectedStreak = 0
            circuitBreakerActive = false
            circuitBreakerDelay = SETTINGS.CIRCUIT_BREAKER_INITIAL_DELAY
            if recoveredFromCircuit then
                if circuitStartedAt then
                    circuitDowntimeTotal += math.max(0, os.clock() - circuitStartedAt)
                    circuitStartedAt = nil
                end
                adaptiveRecoveryNotBefore = math.max(adaptiveRecoveryNotBefore, os.clock() + SETTINGS.ADAPTIVE_FAILURE_HOLD)
                persistRecoveryLock(SETTINGS.ADAPTIVE_FAILURE_HOLD, "circuit breaker recovery")
                clearAdaptiveHistory()
                resetCalibrationSegment("circuit breaker recovered")
                dashboard.state = "Calibrating"
                dashboard.calibration = zoneHealthRemaining() > 0 and ("Zone recovery lock • " .. formatDuration(zoneHealthRemaining())) or ("Recovery evidence lock • " .. formatDuration(SETTINGS.ADAPTIVE_FAILURE_HOLD))
            end
            if rejectionAlertActive or recoveredFromCircuit then
                sendWebhook({
                    title = recoveredFromCircuit and "Circuit Breaker Recovered" or "Server Rejection Streak Recovered",
                    description = recoveredFromCircuit and "A controlled diagnostic probe was accepted. Normal placement has resumed at the protected interval, while speed recovery remains locked." or "The server accepted placement again. Temporary rejection backoff has been cleared.",
                    color = 5763719,
                    targetZone = SETTINGS.TARGET_ZONE,
                    fields = {
                        webhookField("Recovered Streak", formatInteger(recoveredStreak), true),
                        webhookField("Last Probe Delay", string.format("%.0f seconds", recoveredCircuitDelay), true),
                        webhookField("Current Interval", string.format("%.2f seconds", currentInterval), true),
                        webhookField("Speed Recovery Locked", recoveredFromCircuit and formatDuration(SETTINGS.ADAPTIVE_FAILURE_HOLD) or "No", true),
                        webhookField("Confirmed Placements", formatInteger(confirmed), true),
                        webhookField("Failed Cycles", formatInteger(failedCycles), true),
                        webhookField("Remote Errors", formatInteger(errors), true),
                        webhookField("Remote Timeouts", formatInteger(timeouts), true),
                    },
                })
            end
            rejectionAlertActive = false
            return recoveredStreak, recoveredFromCircuit
        end

        local function alertOnRejectionStreak()
            if rejectedStreak >= SETTINGS.CIRCUIT_BREAKER_AFTER and not circuitBreakerActive then
                circuitBreakerActive = true
                circuitBreakerDelay = SETTINGS.CIRCUIT_BREAKER_INITIAL_DELAY
                circuitBreakerTrips += 1
                circuitStartedAt = circuitStartedAt or os.clock()
                rejectionAlertActive = true
                calibrationSegmentContaminated = true
                dashboard.state = "Circuit"
                dashboard.calibration = "Excluded stuck-area episode"
                local zoneUnhealthy, recentZoneCircuits = recordZoneCircuit()
                if zoneUnhealthy then dashboard.calibration = "Zone unhealthy • recovery locked" end
                sendWebhook({
                    title = zoneUnhealthy and "Zone Marked Unhealthy" or "Placement Circuit Breaker Engaged",
                    description = zoneUnhealthy and "This farming zone produced repeated circuit episodes inside the health window. Placement probes continue safely, but calibration and all speed recovery are locked so the account cannot learn a bad rate from a stuck event." or "Consecutive complete placement failures look more like an occupied/stuck area than ordinary timing pressure. Rapid placement has paused; the engine will use increasingly spaced diagnostic probes.",
                    color = 15548997,
                    targetZone = SETTINGS.TARGET_ZONE,
                    critical = true,
                    fields = {
                        webhookField("Consecutive Failed Cycles", formatInteger(rejectedStreak), true),
                        webhookField("First Probe In", string.format("%.0f seconds", circuitBreakerDelay), true),
                        webhookField("Maximum Probe Delay", string.format("%.0f seconds", SETTINGS.CIRCUIT_BREAKER_MAX_DELAY), true),
                        webhookField("Adaptive Interval", string.format("%.2f seconds", currentInterval), true),
                        webhookField("Circuit Trips", formatInteger(circuitBreakerTrips), true),
                        webhookField("Recent Zone Circuits", formatInteger(recentZoneCircuits), true),
                        webhookField("Zone Recovery Lock", zoneUnhealthy and formatDuration(zoneHealthRemaining()) or "Monitoring", true),
                        webhookField("Total Server Rejections", formatInteger(rejected), true),
                        webhookField("Total Failed Cycles", formatInteger(failedCycles + 1), true),
                        webhookField("Last Server Response", tostring(lastResponse), true),
                        webhookField("Suggested Check", "If probes remain rejected, inspect the configured farming area for an invisible or stuck event.", false),
                    },
                })
                return
            end
            if rejectionAlertActive or rejectedStreak < SETTINGS.WEBHOOK_ALERT_REJECT_STREAK then return end
            rejectionAlertActive = true
            local backoff = getRejectionBackoff(rejectedStreak)
            sendWebhook({
                title = "Sustained Server Rejection",
                description = "Multiple consecutive placement cycles were rejected. The engine is still running and has applied temporary backoff. This can indicate cooldown pressure or an occupied/stuck farming area.",
                color = 15548997,
                targetZone = SETTINGS.TARGET_ZONE,
                critical = true,
                fields = {
                    webhookField("Consecutive Rejected Cycles", formatInteger(rejectedStreak), true),
                    webhookField("Temporary Extra Backoff", string.format("%.2f seconds", backoff), true),
                    webhookField("Adaptive Interval", string.format("%.2f seconds", currentInterval), true),
                    webhookField("Total Server Rejections", formatInteger(rejected), true),
                    webhookField("Total Failed Cycles", formatInteger(failedCycles + 1), true),
                    webhookField("Last Server Response", tostring(lastResponse), true),
                    webhookField("Suggested Check", "Confirm that no invisible or stuck event occupies this account's farming area.", false),
                },
            })
        end

        while not env.STOP_MINI_PINATA_FAST_PLACER do
            heartbeat("placement cycle start")

            if not getCharacterRoot() or not isInsideFarmArea() then
                if not waitForFarmArea() then break end
                applyFpsCap()
                if not waitForAccountPhase() then break end
            end

            local cycleFinished = false
            local cycleCounted = false
            local cycleConfirmed = false
            local lostFarmArea = false
            local nextAttemptAt = os.clock()
            local cycleHadServerReject = false
            local cycleUsedSecondRetry = false
            local cycleRecoveredFailureStreak = 0
            local cycleRecoveredFromCircuit = false
            local cycleResponseAt = nil
            local cycleRetryLimit = rejectedStreak >= SETTINGS.RETRY_DISABLE_AFTER and 0 or SETTINGS.MAX_RETRIES

            for retryIndex = 0, cycleRetryLimit do
                if env.STOP_MINI_PINATA_FAST_PLACER then break end

                if not getCharacterRoot() or not isInsideFarmArea() then
                    lostFarmArea = true
                    break
                end

                local uid, totalBefore, ready = getCachedUid()
                if not ready then
                    task.wait(0.5)
                    uid, totalBefore, ready = getCachedUid()
                end

                if ready then
                    inventoryUnavailableSince = nil
                elseif not inventoryUnavailableSince then
                    inventoryUnavailableSince = os.clock()
                elseif os.clock() - inventoryUnavailableSince >= SETTINGS.INVENTORY_RECOVERY_TIMEOUT then
                    error("[Runtime] Inventory stayed unavailable; restarting engine.")
                end

                if ready and not uid then
                    print("[Runtime] No Mini Pinatas remain; stopping.")
                    lastKnownTotal = 0
                    noItemsRemain = true
                    break
                end

                if not uid then
                    nextAttemptAt = os.clock() + 1
                    cycleFinished = true
                    break
                end

                if retryIndex == 0 then
                    cycles += 1
                    cycleCounted = true
                else
                    retries += 1
                    if retryIndex >= 2 then cycleUsedSecondRetry = true end
                end

                remoteCalls += 1

                local endpoint = getConsumeEndpoint()
                if not endpoint then error("[Runtime] Consume endpoint became unavailable.") end

                -- Cooldown-anchored pacing gate: the invoke lands exactly
                -- one interval after the last confirmed consume, plus
                -- jitter. This removes cycle-start scheduling overhead
                -- (farm check, cache read, task.wait frame rounding) from
                -- the effective inter-invoke interval.
                local pacingJitter = SETTINGS.PACING_JITTER_MAX > 0
                    and math.random() * SETTINGS.PACING_JITTER_MAX
                    or 0
                local invokeGate = lastSuccessAt + currentInterval + pacingJitter

                if os.clock() < invokeGate and not waitUntil(invokeGate) then break end

                local invokeStartedAt = os.clock()

                if retryIndex == 0 then
                    samplePhaseStat("gateOvershootMs", (invokeStartedAt - invokeGate) * 1000)
                end

                -- FPS boost during remote invocation; yield one frame so
                -- the raised cap is live before the remote fires.
                applyFpsCap(60)
                RunService.Heartbeat:Wait()

                local ok, response, didTimeout = invokeConsumeWithTimeout(endpoint, uid)
                cycleResponseAt = os.clock()
                heartbeat("remote invocation complete")

                -- Drop FPS back down for idle wait
                applyFpsCap(SETTINGS.FPS)

                if retryIndex == 0 then
                    samplePhaseStat("invokeLatencyMs", (cycleResponseAt - invokeStartedAt) * 1000)
                end

                lastResponse = response
                if didTimeout then timeouts += 1 end

                local didConfirm = false
                local amountUsed = 0
                local totalAfter = nil

                if ok then
                    consecutiveRemoteErrors = 0
                end

                if ok and response == true then
                    -- Optimistic confirmation skip. Bounded drift guard:
                    -- every 25th optimistic confirmation re-reads the real
                    -- inventory total, so a server that consumes a
                    -- different amount cannot silently desync the cache.
                    didConfirm = true
                    amountUsed = 1
                    totalAfter = math.max(0, totalBefore - 1)
                    saveCache.optimisticStreak = (saveCache.optimisticStreak or 0) + 1

                    if saveCache.optimisticStreak >= 25 then
                        saveCache.optimisticStreak = 0
                        local verifiedTotal = getReliableTotal()

                        if type(verifiedTotal) == "number" and verifiedTotal >= 0 then
                            totalAfter = verifiedTotal
                        end
                    end

                    saveCache.total = totalAfter
                elseif ok and response ~= false then
                    didConfirm, amountUsed, totalAfter = waitForConfirmation(totalBefore)
                elseif ok and response == false then
                    rejected += 1
                    cycleHadServerReject = true
                else
                    errors += 1
                    consecutiveRemoteErrors += 1
                    ConsumeEndpoint = nil
                    lastResolvedEndpointLabel = nil
                    dashboard.remote = "Re-resolving after error"
                    if errors == 1 or errors % 10 == 0 then
                        warn("[Runtime] Remote failed: " .. tostring(response))
                    end
                    if consecutiveRemoteErrors >= SETTINGS.REMOTE_ERROR_RESTART_AFTER then
                        error("[Runtime] Repeated remote failures; restarting engine.")
                    end
                end

                if didConfirm then
                    recordConfirmation(amountUsed, totalAfter)
                    cycleConfirmed = true
                    lastSuccessAt = os.clock()

                    if cycleHadServerReject then
                        recoveredCycles += 1
                        if retryIndex == 1 then firstRetryRecoveries += 1
                        elseif retryIndex >= 2 then secondRetryRecoveries += 1 end
                    end

                    local recoveredStreak, recoveredFromCircuit = clearRejectionStreak()
                    cycleRecoveredFailureStreak = math.max(cycleRecoveredFailureStreak, recoveredStreak or 0)
                    cycleRecoveredFromCircuit = cycleRecoveredFromCircuit or recoveredFromCircuit == true
                    cycleFinished = true
                elseif retryIndex < cycleRetryLimit then
                    -- Cooldown-anchored retry: land the retry exactly on
                    -- the pacing gate instead of a fixed delay.
                    local retryGate = math.max(
                        lastSuccessAt + currentInterval,
                        os.clock() + 0.1
                    )

                    if not waitUntil(retryGate) then break end

                    local lateTotal = getReliableTotal()
                    if lateTotal and totalBefore > 0 and lateTotal < totalBefore then
                        recordConfirmation(totalBefore - lateTotal, lateTotal)
                        cycleConfirmed = true
                        lastSuccessAt = os.clock()

                        if cycleHadServerReject then
                            recoveredCycles += 1
                            lateConfirmations += 1
                        end
                        local recoveredStreak, recoveredFromCircuit = clearRejectionStreak()
                        cycleRecoveredFailureStreak = math.max(cycleRecoveredFailureStreak, recoveredStreak or 0)
                        cycleRecoveredFromCircuit = cycleRecoveredFromCircuit or recoveredFromCircuit == true
                        cycleFinished = true
                    end
                else
                    if cycleHadServerReject then
                        rejectedStreak += 1
                        local circuitWasAlreadyActive = circuitBreakerActive
                        alertOnRejectionStreak()
                        if circuitWasAlreadyActive then
                            circuitBreakerDelay = math.min(SETTINGS.CIRCUIT_BREAKER_MAX_DELAY, circuitBreakerDelay * 2)
                        end
                    end
                    cycleFinished = true
                end

                if cycleFinished then break end
            end

            if env.STOP_MINI_PINATA_FAST_PLACER or noItemsRemain then break end

            if cycleFinished and cycleCounted then
                if not cycleConfirmed then failedCycles += 1 end
                dashboard.interval = currentInterval
                dashboard.successRate = cycles > 0 and confirmed / cycles * 100 or 100
                if circuitBreakerActive then dashboard.state = "Circuit" end

                heartbeat("adaptive update")
                recordCalibrationSample(cycleConfirmed, cycleHadServerReject, cycleUsedSecondRetry)
                updateAdaptiveRate(cycleConfirmed, cycleHadServerReject, cycleUsedSecondRetry, cycleRecoveredFailureStreak, cycleRecoveredFromCircuit)
                heartbeat("adaptive update complete")

                if cycleConfirmed
                    and not cycleHadServerReject
                    and cycleResponseAt ~= nil
                then
                    samplePhaseStat("postConfirmMs", (os.clock() - cycleResponseAt) * 1000)
                end

                local scheduleBase = os.clock()
                if cycleConfirmed then
                    -- Pacing is enforced at the invoke gate; re-loop
                    -- immediately so pre-invoke work overlaps the wait.
                    nextAttemptAt = scheduleBase
                elseif circuitBreakerActive then
                    nextAttemptAt = scheduleBase + circuitBreakerDelay
                else
                    nextAttemptAt = scheduleBase + math.max(currentInterval, getRejectionBackoff(rejectedStreak))
                end

                printStatus()
            end

            if not lostFarmArea and cycleFinished then
                waitUntil(nextAttemptAt)
            end
        end

        print(string.format("[Runtime] Stopped | cycles %d | confirmed %d | calls %d | retries %d | recovered %d | retry2 %d | rejected %d | failed %d | errors %d | timeouts %d | interval %.2fs", cycles, confirmed, remoteCalls, retries, recoveredCycles, secondRetryRecoveries, rejected, failedCycles, errors, timeouts, currentInterval))

        local finalElapsed = math.max(1, os.clock() - placementRunStartedAt)
        local finalPerHour = confirmed / finalElapsed * 3600
        local finalPerDay = finalPerHour * 24
        local finalSuccessRate = cycles > 0 and confirmed / cycles * 100 or 0
        local finalRecoveryRate = cycles > 0 and recoveredCycles / cycles * 100 or 0
        dashboard.state = "Stopped"
        dashboard.interval = currentInterval
        dashboard.hourly = finalPerHour
        dashboard.daily = finalPerDay
        dashboard.successRate = finalSuccessRate
        dashboard.pinatas = lastKnownTotal

        if noItemsRemain then
            sendWebhook({
                title = "Mini Pinata Inventory Exhausted",
                description = "The engine stopped cleanly after using the final available Mini Pinata.",
                color = 16753920,
                targetZone = SETTINGS.TARGET_ZONE,
                fields = {
                    webhookField("Placement Cycles", formatInteger(cycles), true),
                    webhookField("Confirmed Placements", formatInteger(confirmed), true),
                    webhookField("Cycle Success Rate", string.format("%.2f%%", finalSuccessRate), true),
                    webhookField("Remote Calls", formatInteger(remoteCalls), true),
                    webhookField("Retries", formatInteger(retries), true),
                    webhookField("Recovered-Cycle Rate", string.format("%.2f%%", finalRecoveryRate), true),
                    webhookField("Retry Recovery Details", string.format("Recovered cycles: %s | First retry: %s | Second retry: %s | Late confirmation: %s", formatInteger(recoveredCycles), formatInteger(firstRetryRecoveries), formatInteger(secondRetryRecoveries), formatInteger(lateConfirmations)), false),
                    webhookField("Server Rejections", formatInteger(rejected), true),
                    webhookField("Failed Cycles", formatInteger(failedCycles), true),
                    webhookField("Remote Errors", formatInteger(errors), true),
                    webhookField("Remote Timeouts", formatInteger(timeouts), true),
                    webhookField("Final Interval", string.format("%.2f seconds", currentInterval), true),
                    webhookField("Observed Throughput", string.format("%.1f/hour | %.0f/day", finalPerHour, finalPerDay), true),
                    webhookField("Inventory Remaining", formatInteger(lastKnownTotal), true),
                },
            })
        end

        return noItemsRemain and "no_items" or "stopped"
    end

    local function runEngineMonitored()
        heartbeat("engine thread start")
        local completed = false
        local engineSuccess = false
        local engineResult = nil
        local engineThread = task.spawn(function()
            local success, result = xpcall(runEngine, function(err) return tostring(err) end)
            engineSuccess = success
            engineResult = result
            completed = true
        end)
        while not completed and not env.STOP_MINI_PINATA_FAST_PLACER do
            local silentFor = os.clock() - heartbeatAt
            if silentFor >= watchdogTimeout then
                local stalledState = heartbeatState
                local cancelled = cancelManagedThread(engineThread)
                if not cancelled and completed then return engineSuccess, engineResult end
                if not cancelled then
                    cancellationFailed = true
                    env.STOP_MINI_PINATA_FAST_PLACER = true
                    return false, string.format("watchdog could not cancel stalled state '%s'", tostring(stalledState))
                end
                return false, string.format("watchdog detected %.0fs without progress in state '%s'", silentFor, tostring(stalledState))
            end
            task.wait(1)
        end
        if completed then return engineSuccess, engineResult end
        local cancelled = cancelManagedThread(engineThread)
        if not cancelled and not completed then
            cancellationFailed = true
            return false, "engine thread could not be cancelled during shutdown"
        end
        return true, "stopped"
    end

    local restartDelayBase = math.max(5, numberSetting("GPINATA_RESTART_DELAY", 15))
    local restartDelay = restartDelayBase
    local restartDelayMax = math.max(restartDelay, numberSetting("GPINATA_RESTART_DELAY_MAX", 300))

    while not env.STOP_MINI_PINATA_FAST_PLACER do
        local runStartedAt = os.clock()
        local success, result = runEngineMonitored()
        if success then break end
        local runDuration = os.clock() - runStartedAt
        if runDuration >= 300 then restartDelay = restartDelayBase end
        dashboard.state = "Fault"
        sendWebhook({
            title = "Engine Fault - Restart Scheduled",
            description = "The supervisor detected a runtime fault. The failed engine thread was isolated and a clean restart has been scheduled.",
            color = 15548997,
            targetZone = tonumber(env.GZONE_TO) or 39,
            critical = true,
            fields = {
                webhookField("Fault", tostring(result), false),
                webhookField("Last Heartbeat State", tostring(heartbeatState), true),
                webhookField("Run Duration", formatDuration(runDuration), true),
                webhookField("Restart In", string.format("%.0f seconds", restartDelay), true),
                webhookField("Next Failure Delay", string.format("up to %.0f seconds", math.min(restartDelay * 2, restartDelayMax)), true),
                webhookField("Watchdog Threshold", string.format("%.0f seconds", watchdogTimeout), true),
            },
        })
        warn(string.format("[Runtime] Engine fault: %s | retrying in %.0fs", tostring(result), restartDelay))
        if not supervisorWait(restartDelay) then break end
        dashboard.state = "Booting"
        if runDuration < 300 then restartDelay = math.min(restartDelay * 2, restartDelayMax) end
    end

    if type(env.__GPINATA_RESTORE_FPSCAP) == "function" then
        pcall(env.__GPINATA_RESTORE_FPSCAP)
        env.__GPINATA_RESTORE_FPSCAP = nil
    end

    if cancellationFailed then
        warn("[Runtime] Safety guard retained until the next client relaunch.")
        dashboard.state = "Stopped"
        sendWebhook({
            title = "Engine Safety Stop",
            description = "A stalled thread could not be cancelled safely. Automatic placement is disabled until Volt relaunches this Roblox client.",
            color = 15548997,
            targetZone = tonumber(env.GZONE_TO) or 39,
            critical = true,
            fields = {
                webhookField("Placement State", "Disabled until client relaunch", false),
                webhookField("Last Heartbeat State", tostring(heartbeatState), true),
                webhookField("Watchdog Threshold", string.format("%.0f seconds", watchdogTimeout), true),
            },
        })
    else
        env.__MINI_PINATA_FAST_PLACER_RUNNING = false
    end
end)
