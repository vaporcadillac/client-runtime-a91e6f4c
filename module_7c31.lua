local env = getgenv()
local ENGINE_BUILD = "calibrated-autoremote-13"

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
    interval = tonumber(env.GPINATA_INTERVAL) or 6.2,
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

    -- Discord delivery runs in its own bounded queue. A slow or rate-limited
    -- webhook can never delay the placement loop.
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
            "https://discord.com/api/webhooks/",
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
                "%s **%s**  •  Area `%s`  •  Interval `%.2fs`",
                stateIcon,
                state,
                tostring(targetZone or env.GZONE_TO or "?"),
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

    local function sendWebhook(options)
        if not webhookEnabled then
            return
        end

        options = options or {}
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

    local function heartbeat(state)
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

    sendWebhook({
        title = "Pinata Monitor Online",
        description = "The engine loaded successfully and is waiting for GScript to settle this account inside its farming area.",
        color = 3447003,
        targetZone = tonumber(env.GZONE_TO) or 39,
        fields = {
            webhookField("Configured Baseline", string.format("%.2f seconds", numberSetting("GPINATA_INTERVAL", 6.2)), true),
            webhookField("Adaptive Controller", env.GPINATA_ADAPTIVE ~= false and "Enabled" or "Disabled", true),
            webhookField("Startup Delay", string.format("%.0f seconds", numberSetting("GPINATA_STARTUP_WAIT", 60)), true),
            webhookField("Required Stability", string.format("%.0f seconds", numberSetting("GPINATA_STABLE_WAIT", 20)), true),
            webhookField("Watchdog", string.format("%.0f seconds", watchdogTimeout), true),
            webhookField("Webhook Delivery", "Connected", true),
        },
    })

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
        heartbeat("engine initialization")

        local SETTINGS = {
            -- The short window detects pressure quickly. Recovery uses a much
            -- longer observation period plus a time hold so one lucky 20-cycle
            -- window can never make the engine speed up again.
            INTERVAL = math.max(1.5, numberSetting("GPINATA_INTERVAL", 6.2)),
            ADAPTIVE = env.GPINATA_ADAPTIVE ~= false,
            ADAPTIVE_MIN_INTERVAL = math.max(
                1.5,
                numberSetting("GPINATA_ADAPTIVE_MIN_INTERVAL", 6.2)
            ),
            ADAPTIVE_MAX_INTERVAL = math.max(
                1.5,
                numberSetting("GPINATA_ADAPTIVE_MAX_INTERVAL", 8)
            ),
            ADAPTIVE_WINDOW = math.max(
                10,
                math.floor(numberSetting("GPINATA_ADAPTIVE_WINDOW", 20))
            ),
            ADAPTIVE_LONG_WINDOW = math.max(
                50,
                math.floor(numberSetting("GPINATA_ADAPTIVE_LONG_WINDOW", 150))
            ),
            ADAPTIVE_STEP_UP = math.max(
                0.01,
                numberSetting("GPINATA_ADAPTIVE_STEP_UP", 0.15)
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
                60,
                numberSetting("GPINATA_ADAPTIVE_RECOVERY_HOLD", 1800)
            ),
            ADAPTIVE_FAILURE_HOLD = math.max(
                60,
                numberSetting("GPINATA_ADAPTIVE_FAILURE_HOLD", 1800)
            ),
            ADAPTIVE_RECOVERY_MAX_REJECT_RATE = math.max(
                0,
                numberSetting("GPINATA_ADAPTIVE_RECOVERY_MAX_REJECT_RATE", 0.03)
            ),
            ADAPTIVE_RECOVERY_MAX_SECOND_RETRIES = math.max(
                0,
                math.floor(numberSetting(
                    "GPINATA_ADAPTIVE_RECOVERY_MAX_SECOND_RETRIES",
                    0
                ))
            ),
            CONFIRM_WAIT = math.max(0.25, numberSetting("GPINATA_CONFIRM_WAIT", 1.5)),
            RETRY_DELAY = math.max(0.25, numberSetting("GPINATA_RETRY_DELAY", 1)),
            RECOVERY_RETRY_DELAY = math.max(
                0.5,
                numberSetting("GPINATA_RECOVERY_RETRY_DELAY", 2)
            ),
            -- The second retry is deliberately slower. It is only reached
            -- when both the original call and the normal retry are rejected.
            MAX_RETRIES = math.min(
                2,
                math.max(0, math.floor(numberSetting("GPINATA_MAX_RETRIES", 2)))
            ),
            STARTUP_WAIT = math.max(0, numberSetting("GPINATA_STARTUP_WAIT", 60)),
            STABLE_WAIT = math.max(0, numberSetting("GPINATA_STABLE_WAIT", 20)),
            FPS = math.max(1, numberSetting("GPINATA_FPS", 10)),
            STATUS_EVERY = math.max(1, math.floor(numberSetting("GPINATA_STATUS_EVERY", 100))),
            WEBHOOK_STATUS_EVERY = math.max(
                20,
                math.floor(numberSetting("GPINATA_WEBHOOK_STATUS_EVERY", 100))
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
            CONFIRM_POLL = 0.15,
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
            PACING_JITTER_MAX = math.max(
                0,
                math.min(1, numberSetting("GPINATA_PACING_JITTER_MAX", 0.15))
            ),
            CALIBRATION = env.GPINATA_CALIBRATION ~= false,
            CALIBRATION_PERSIST = env.GPINATA_CALIBRATION_PERSIST ~= false,
            CALIBRATION_MIN_CYCLES = math.max(
                100,
                math.floor(numberSetting("GPINATA_CALIBRATION_MIN_CYCLES", 250))
            ),
            CALIBRATION_MIN_SECONDS = math.max(
                600,
                numberSetting("GPINATA_CALIBRATION_MIN_SECONDS", 1800)
            ),
            CALIBRATION_MAX_REJECT_RATE = math.max(
                0,
                numberSetting("GPINATA_CALIBRATION_MAX_REJECT_RATE", 0.03)
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

        local function applyFpsCap()
            if type(setfpscap) ~= "function" then
                return
            end

            local ok, err = pcall(setfpscap, SETTINGS.FPS)

            if not ok then
                warn("[Runtime] FPS cap failed: " .. tostring(err))
            end
        end

        local function waitUntil(deadline)
            while not env.STOP_MINI_PINATA_FAST_PLACER do
                heartbeat("scheduled interval wait")
                local remaining = deadline - os.clock()

                if remaining <= 0 then
                    return true
                end

                task.wait(math.max(0.05, math.min(0.25, remaining)))
            end

            return false
        end

        applyFpsCap()

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
            schema = 1,
            userId = LocalPlayer and LocalPlayer.UserId or 0,
            placeId = game.PlaceId,
            placeVersion = game.PlaceVersion,
            zone = SETTINGS.TARGET_ZONE,
            recommendedInterval = currentInterval,
            qualifiedCycles = 0,
            qualifiedSeconds = 0,
            sessions = 1,
            updatedAt = 0,
        }
        local calibrationPersistent = SETTINGS.CALIBRATION
            and SETTINGS.CALIBRATION_PERSIST
            and readCalibrationFile ~= nil
            and writeCalibrationFile ~= nil

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

            if not recommended or not profileMatches then
                dashboard.calibration = "New local profile"
                return
            end

            calibrationProfile = decoded
            calibrationProfile.schema = 1
            calibrationProfile.placeVersion = game.PlaceVersion
            calibrationProfile.recommendedInterval = math.max(
                SETTINGS.ADAPTIVE_MIN_INTERVAL,
                math.min(SETTINGS.ADAPTIVE_MAX_INTERVAL, recommended)
            )
            calibrationProfile.sessions = math.max(
                0,
                tonumber(calibrationProfile.sessions) or 0
            ) + 1
            currentInterval = math.max(
                currentInterval,
                calibrationProfile.recommendedInterval
            )
            dashboard.calibration = string.format(
                calibrationProfile.provisional
                    and "Remembered protective %.2fs"
                    or "Remembered %.2fs",
                calibrationProfile.recommendedInterval
            )
        end

        local function saveCalibrationProfile()
            if not calibrationPersistent then
                return false
            end

            calibrationProfile.placeVersion = game.PlaceVersion
            calibrationProfile.updatedAt = os.time()
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

        loadCalibrationProfile()
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
            sendWebhook({
                title = "Remote Route Resolved",
                description = "The placement communication route was resolved and cached. Ordinary server rejections will not trigger rediscovery.",
                color = endpoint.strategy == "Known route" and 5763719 or 16753920,
                targetZone = SETTINGS.TARGET_ZONE,
                fields = {
                    webhookField("Resolution Strategy", endpoint.strategy, true),
                    webhookField("Endpoint", endpoint.label, false),
                    webhookField("Endpoint Type", endpoint.kind, true),
                    webhookField("Resolve Mode", SETTINGS.AUTO_REMOTE and "Automatic fallback" or "Known route only", true),
                },
            })
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
                task.wait(0.1)
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

        local function isInsideFarmArea()
            heartbeat("farm-area check")

            local module = getMapCmds()

            if type(module) ~= "table" or type(module.IsInDottedBox) ~= "function" then
                return false
            end

            local ok, result = pcall(module.IsInDottedBox)
            heartbeat("farm-area check complete")
            return ok and result == true
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

            dashboard.state = isRecovery and "Paused" or "Booting"

            print(string.format(
                "[Runtime] Waiting for GScript farming area for target zone %d.",
                SETTINGS.TARGET_ZONE
            ))

            if isRecovery then
                sendWebhook({
                    title = "Farm Area Lost",
                    description = "Placement has paused until GScript returns this account to a stable farming area.",
                    color = 16753920,
                    targetZone = SETTINGS.TARGET_ZONE,
                    fields = {
                        webhookField("Placement State", "Paused", true),
                        webhookField("Stability Required", string.format("%.0f seconds", SETTINGS.STABLE_WAIT), true),
                        webhookField("Wait Timeout", string.format("%.0f seconds", SETTINGS.FARM_WAIT_TIMEOUT), true),
                    },
                })
            end

            while not env.STOP_MINI_PINATA_FAST_PLACER do
                heartbeat("waiting for stable farm area")

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

                        if isRecovery then
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

        local function getSaveData()
            heartbeat("inventory save read")
            local ok, data = pcall(Save.Get)
            heartbeat("inventory save read complete")

            if ok and type(data) == "table" then
                return data
            end

            return nil
        end

        local function normalize(value)
            if type(value) ~= "string" then
                return ""
            end

            return string.lower(value):gsub("[^%w]", "")
        end

        local function getItemAmount(item)
            return tonumber(
                item._am
                or item.am
                or item.amount
                or item.Amount
                or item.quantity
                or item.Quantity
                or 1
            ) or 1
        end

        local function currencyAmount(value, depth)
            depth = depth or 0

            if depth > 2 then
                return nil
            end

            if type(value) == "number" or type(value) == "string" then
                local amount = tonumber(value)

                if amount and amount >= 0 and amount == amount then
                    return amount
                end

                return nil
            end

            if type(value) ~= "table" then
                return nil
            end

            for _, candidate in ipairs({
                value._am,
                value.am,
                value.amount,
                value.Amount,
                value.quantity,
                value.Quantity,
                value.value,
                value.Value,
                value.balance,
                value.Balance,
            }) do
                local amount = currencyAmount(candidate, depth + 1)

                if amount ~= nil then
                    return amount
                end
            end

            return nil
        end

        local function gemCountInContainer(container)
            if type(container) ~= "table" then
                return nil
            end

            local best = nil

            for key, value in pairs(container) do
                local keyName = normalize(key)
                local itemName = type(value) == "table"
                    and normalize(
                        value.id
                        or value._id
                        or value.ID
                        or value.Name
                        or value.name
                    )
                    or ""

                if keyName == "diamonds"
                    or keyName == "gems"
                    or itemName == "diamonds"
                    or itemName == "gems"
                then
                    local amount = currencyAmount(value)

                    if amount ~= nil and (best == nil or amount > best) then
                        best = amount
                    end
                end
            end

            return best
        end

        local function findGemCount(data)
            if type(data) ~= "table" then
                return nil
            end

            local inventory = type(data.Inventory) == "table"
                and data.Inventory
                or nil

            -- Current PS99 saves keep active balances in Inventory.Currency.
            -- Check those containers before legacy top-level fields, which may
            -- remain present as a stale numeric zero. In Lua, zero is truthy,
            -- so returning the first value previously masked the live balance.
            local containers = {
                inventory and inventory.Currency,
                inventory and inventory.Currencies,
                data.Currency,
                data.Currencies,
                data.currency,
                data.currencies,
            }

            for _, container in ipairs(containers) do
                local amount = gemCountInContainer(container)

                if amount ~= nil then
                    return amount
                end
            end

            for _, key in ipairs({ "Diamonds", "diamonds", "Gems", "gems" }) do
                local direct = currencyAmount(data[key])

                if direct ~= nil then
                    return direct
                end
            end

            return nil
        end

        local function findItemStack()
            local data = getSaveData()
            local inventory = data and data.Inventory
            local misc = inventory and inventory.Misc
            local gems = findGemCount(data)

            if gems ~= nil then
                dashboard.gems = gems
            end

            if type(misc) ~= "table" then
                dashboard.pinatas = nil
                return nil, 0, false
            end

            local selectedUid = nil
            local selectedAmount = 0
            local total = 0

            for uid, item in pairs(misc) do
                if type(uid) == "string" and type(item) == "table" then
                    local itemId = item.id
                        or item._id
                        or item.ID
                        or item.Name
                        or item.name

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

        local function waitForInventory()
            local deadline = os.clock() + SETTINGS.INVENTORY_TIMEOUT
            local sawReadyInventory = false

            repeat
                heartbeat("waiting for inventory")
                local uid, total, ready = findItemStack()

                if ready then
                    sawReadyInventory = true

                    if uid then
                        return uid, total, true
                    end
                end

                task.wait(0.5)
            until os.clock() >= deadline or env.STOP_MINI_PINATA_FAST_PLACER

            return nil, 0, sawReadyInventory
        end

        local function getReliableTotal()
            local _, total, ready = findItemStack()

            if not ready then
                return nil
            end

            return total
        end

        local function waitForConfirmation(totalBefore)
            local deadline = os.clock() + SETTINGS.CONFIRM_WAIT

            repeat
                heartbeat("inventory confirmation wait")
                local totalAfter = getReliableTotal()

                if totalAfter and totalBefore > 0 and totalAfter < totalBefore then
                    return true, totalBefore - totalAfter, totalAfter
                end

                local remaining = deadline - os.clock()

                if remaining <= 0 then
                    break
                end

                task.wait(math.max(0.05, math.min(SETTINGS.CONFIRM_POLL, remaining)))
            until env.STOP_MINI_PINATA_FAST_PLACER

            return false, 0, nil
        end

        local initialUid, initialTotal, inventoryReady = waitForInventory()

        if not initialUid then
            if inventoryReady then
                print("[Runtime] No Mini Pinatas were found; engine stopped cleanly.")
                dashboard.state = "Stopped"
                dashboard.pinatas = 0
                sendWebhook({
                    title = "No Mini Pinatas Available",
                    description = "The engine stopped cleanly because this account had no Mini Pinatas when inventory became available.",
                    color = 16753920,
                    targetZone = SETTINGS.TARGET_ZONE,
                    fields = {
                        webhookField("Inventory Remaining", "0", true),
                        webhookField("Placement State", "Stopped", true),
                    },
                })
                return "no_items"
            end

            error("[Runtime] Inventory did not become available.")
        end

        if not waitForFarmArea() then
            return "stopped"
        end

        initialUid, initialTotal, inventoryReady = waitForInventory()

        if not initialUid then
            if inventoryReady then
                print("[Runtime] No Mini Pinatas remain; engine stopped cleanly.")
                dashboard.state = "Stopped"
                dashboard.pinatas = 0
                sendWebhook({
                    title = "No Mini Pinatas Available",
                    description = "The engine stopped cleanly because the inventory contained no Mini Pinatas after farming began.",
                    color = 16753920,
                    targetZone = SETTINGS.TARGET_ZONE,
                    fields = {
                        webhookField("Inventory Remaining", "0", true),
                        webhookField("Placement State", "Stopped", true),
                    },
                })
                return "no_items"
            end

            error("[Runtime] Inventory was unavailable after farming began.")
        end

        if not getConsumeEndpoint() then
            error("[Runtime] Consume endpoint could not be resolved.")
        end

        applyFpsCap()

        if not waitForAccountPhase() then
            return "stopped"
        end

        dashboard.state = SETTINGS.CALIBRATION and "Calibrating" or "Running"
        dashboard.pinatas = initialTotal
        dashboard.interval = currentInterval
        dashboard.hourly = 3600 / currentInterval
        dashboard.daily = 86400 / currentInterval

        if SETTINGS.CALIBRATION
            and string.find(dashboard.calibration, "Remembered", 1, true) == nil
        then
            dashboard.calibration = string.format(
                "Testing %.2fs • 0/%d",
                currentInterval,
                SETTINGS.CALIBRATION_MIN_CYCLES
            )
        end

        if SETTINGS.ADAPTIVE then
            print(string.format(
                "[Runtime] Started | target %.2fs | adaptive %.2f-%.2fs "
                    .. "| retries %.2f/%.2fs | amount %d",
                currentInterval,
                SETTINGS.ADAPTIVE_MIN_INTERVAL,
                SETTINGS.ADAPTIVE_MAX_INTERVAL,
                SETTINGS.RETRY_DELAY,
                SETTINGS.RECOVERY_RETRY_DELAY,
                initialTotal
            ))
        else
            print(string.format(
                "[Runtime] Started | interval %.2fs | retries %.2f/%.2fs | amount %d",
                currentInterval,
                SETTINGS.RETRY_DELAY,
                SETTINGS.RECOVERY_RETRY_DELAY,
                initialTotal
            ))
        end

        sendWebhook({
            title = "Mini Pinata Engine Started",
            description = "The account is stable inside its farming area and automatic placement is active.",
            color = 5763719,
            targetZone = SETTINGS.TARGET_ZONE,
            fields = {
                webhookField("Inventory Remaining", formatInteger(initialTotal), true),
                webhookField("Starting Interval", string.format("%.2f seconds", currentInterval), true),
                webhookField(
                    "Adaptive Range",
                    SETTINGS.ADAPTIVE
                        and string.format(
                            "%.2f-%.2f seconds",
                            SETTINGS.ADAPTIVE_MIN_INTERVAL,
                            SETTINGS.ADAPTIVE_MAX_INTERVAL
                        )
                        or "Disabled",
                    true
                ),
                webhookField("Pressure Window", string.format("%d cycles", SETTINGS.ADAPTIVE_WINDOW), true),
                webhookField("Recovery Window", string.format("%d cycles", SETTINGS.ADAPTIVE_LONG_WINDOW), true),
                webhookField("Recovery Hold", formatDuration(SETTINGS.ADAPTIVE_RECOVERY_HOLD), true),
                webhookField(
                    "Calibration",
                    SETTINGS.CALIBRATION
                        and string.format(
                            "%d cycles + %s",
                            SETTINGS.CALIBRATION_MIN_CYCLES,
                            formatDuration(SETTINGS.CALIBRATION_MIN_SECONDS)
                        )
                        or "Disabled",
                    true
                ),
                webhookField("Calibration Storage", calibrationPersistent and "Persistent" or "Session only", true),
                webhookField("Auto-Remote", SETTINGS.AUTO_REMOTE and "Fallback enabled" or "Known route only", true),
                webhookField(
                    "Retry Policy",
                    string.format(
                        "%d max | %.2fs normal | %.2fs recovery",
                        SETTINGS.MAX_RETRIES,
                        SETTINGS.RETRY_DELAY,
                        SETTINGS.RECOVERY_RETRY_DELAY
                    ),
                    true
                ),
                webhookField("Remote Timeout", string.format("%.1f seconds", SETTINGS.REMOTE_TIMEOUT), true),
                webhookField("FPS Cap", SETTINGS.FPS, true),
                webhookField("Watchdog", string.format("%.0f seconds", watchdogTimeout), true),
                webhookField("Projected Maximum", string.format("%.1f/hour | %.0f/day", 3600 / currentInterval, 86400 / currentInterval), true),
            },
        })

        local placementRunStartedAt = os.clock()
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
        local failedCycles = 0
        local errors = 0
        local timeouts = 0
        local consecutiveRemoteErrors = 0
        local inventoryUnavailableSince = nil
        local lastResponse = nil
        local lastKnownTotal = initialTotal
        local noItemsRemain = false

        local calibrationSegmentStartedAt = os.clock()
        local calibrationSegmentInterval = currentInterval
        local calibrationSegmentCycles = 0
        local calibrationSegmentRejected = 0
        local calibrationSegmentFailed = 0
        local calibrationSegmentSecondRetries = 0
        local calibrationSegmentContaminated = false
        local calibrationSegmentQualified = false
        local calibrationBlockedUntil = 0

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

            if SETTINGS.CALIBRATION then
                dashboard.calibration = string.format(
                    "Testing %.2fs • 0/%d",
                    currentInterval,
                    SETTINGS.CALIBRATION_MIN_CYCLES
                )
            end

            if SETTINGS.VERBOSE and reason then
                print("[Runtime] Calibration reset: " .. tostring(reason))
            end
        end

        local function recordCalibrationSample(
            cycleConfirmed,
            cycleRejected,
            usedSecondRetry
        )
            if not SETTINGS.CALIBRATION then
                return
            end

            if circuitBreakerActive then
                calibrationSegmentContaminated = true
                calibrationBlockedUntil = math.max(
                    calibrationBlockedUntil,
                    os.clock() + SETTINGS.ADAPTIVE_FAILURE_HOLD
                )
                dashboard.calibration = "Excluded stuck-area episode"
                return
            end

            if calibrationSegmentContaminated
                and os.clock() >= calibrationBlockedUntil
                and cycleConfirmed
            then
                resetCalibrationSegment("contaminated evidence expired")
            end

            if math.abs(calibrationSegmentInterval - currentInterval) >= 0.001 then
                resetCalibrationSegment("interval changed")
            end

            calibrationSegmentCycles += 1

            if cycleRejected then
                calibrationSegmentRejected += 1
            end

            if not cycleConfirmed then
                calibrationSegmentFailed += 1
                calibrationSegmentContaminated = true
                calibrationBlockedUntil = math.max(
                    calibrationBlockedUntil,
                    os.clock() + SETTINGS.ADAPTIVE_FAILURE_HOLD
                )
            end

            if usedSecondRetry then
                calibrationSegmentSecondRetries += 1
                calibrationSegmentContaminated = true
                calibrationBlockedUntil = math.max(
                    calibrationBlockedUntil,
                    os.clock() + SETTINGS.ADAPTIVE_RECOVERY_HOLD
                )
            end

            local elapsed = os.clock() - calibrationSegmentStartedAt
            local rejectRate = calibrationSegmentCycles > 0
                and calibrationSegmentRejected / calibrationSegmentCycles
                or 0
            dashboard.calibration = string.format(
                "Testing %.2fs • %d/%d",
                currentInterval,
                math.min(
                    calibrationSegmentCycles,
                    SETTINGS.CALIBRATION_MIN_CYCLES
                ),
                SETTINGS.CALIBRATION_MIN_CYCLES
            )

            local qualifies = not calibrationSegmentQualified
                and not calibrationSegmentContaminated
                and calibrationSegmentCycles >= SETTINGS.CALIBRATION_MIN_CYCLES
                and elapsed >= SETTINGS.CALIBRATION_MIN_SECONDS
                and rejectRate <= SETTINGS.CALIBRATION_MAX_REJECT_RATE

            if not qualifies then
                return
            end

            calibrationSegmentQualified = true
            calibrationProfile.recommendedInterval = currentInterval
            calibrationProfile.qualifiedCycles = calibrationSegmentCycles
            calibrationProfile.qualifiedSeconds = math.floor(elapsed)
            calibrationProfile.rejectRate = rejectRate
            calibrationProfile.failedCycles = calibrationSegmentFailed
            calibrationProfile.secondRetries = calibrationSegmentSecondRetries
            calibrationProfile.provisional = false
            local saved = saveCalibrationProfile()
            dashboard.calibration = string.format(
                "%s %.2fs • %d clean",
                saved and "Remembered" or "Qualified",
                currentInterval,
                calibrationSegmentCycles
            )
            dashboard.state = "Running"

            sendWebhook({
                title = saved
                    and "Account Calibration Remembered"
                    or "Account Calibration Qualified",
                description = saved
                    and "This account and area sustained the current placement interval long enough to use it as the starting recommendation after future Volt relaunches."
                    or "The interval passed sustained calibration, but persistent executor file storage was unavailable; it can only be used during this client session.",
                color = 5763719,
                targetZone = SETTINGS.TARGET_ZONE,
                fields = {
                    webhookField("Qualified Interval", string.format("%.2f seconds", currentInterval), true),
                    webhookField("Evidence", string.format("%d cycles • %s", calibrationSegmentCycles, formatDuration(elapsed)), true),
                    webhookField("Initial Rejection Rate", string.format("%.2f%%", rejectRate * 100), true),
                    webhookField("Failed Cycles", calibrationSegmentFailed, true),
                    webhookField("Second Retries", calibrationSegmentSecondRetries, true),
                    webhookField("Profile Scope", string.format("Account %s • Area %d", tostring(LocalPlayer.UserId), SETTINGS.TARGET_ZONE), false),
                },
            })
        end

        local function recordConfirmation(amountUsed, totalAfter)
            local firstConfirmation = confirmed == 0
            confirmed += amountUsed
            lastKnownTotal = totalAfter or math.max(0, lastKnownTotal - amountUsed)
            dashboard.pinatas = lastKnownTotal
            local elapsed = math.max(1, os.clock() - placementRunStartedAt)
            dashboard.hourly = confirmed / elapsed * 3600
            dashboard.daily = dashboard.hourly * 24
            dashboard.successRate = cycles > 0 and confirmed / cycles * 100 or 100

            if firstConfirmation or SETTINGS.VERBOSE then
                print(string.format(
                    "[Runtime] Placed | remaining %d | confirmed %d",
                    totalAfter,
                    confirmed
                ))
            end
        end

        local function printStatus()
            if cycles == 0 then
                return
            end

            local shouldPrint = cycles % SETTINGS.STATUS_EVERY == 0
            local shouldWebhook = webhookEnabled
                and cycles % SETTINGS.WEBHOOK_STATUS_EVERY == 0

            if not shouldPrint and not shouldWebhook then
                return
            end

            local elapsed = math.max(1, os.clock() - placementRunStartedAt)
            local acceptedPerHour = confirmed / elapsed * 3600
            local projectedPerDay = acceptedPerHour * 24
            local successRate = confirmed / cycles * 100
            local callEfficiency = remoteCalls > 0
                and confirmed / remoteCalls * 100
                or 0
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
                print(string.format(
                    "[Runtime] Status | cycles %d | confirmed %d | calls %d "
                        .. "| retries %d | recovered %d | retry2 %d "
                        .. "| rejected %d | failed %d "
                        .. "| reject streak %d | errors %d | timeouts %d "
                        .. "| interval %.2fs "
                        .. "| %.1f/hour | %.0f/day | response %s",
                    cycles,
                    confirmed,
                    remoteCalls,
                    retries,
                    recoveredCycles,
                    secondRetryRecoveries,
                    rejected,
                    failedCycles,
                    rejectedStreak,
                    errors,
                    timeouts,
                    currentInterval,
                    acceptedPerHour,
                    projectedPerDay,
                    tostring(lastResponse)
                ))
            end

            if shouldWebhook then
                local initialAccepted = math.max(
                    0,
                    cycles - recoveredCycles - failedCycles
                )
                local initialPassRate = cycles > 0
                    and initialAccepted / cycles * 100
                    or 0
                sendWebhook({
                    title = "Placement Status - " .. formatInteger(cycles) .. " Cycles",
                    description = "A compact health report for the current placement run. The dashboard above always reflects live gems, remaining piñatas, interval and observed placement speed.",
                    color = failedCycles == 0 and recoveryRate < 5
                        and 3447003
                        or 16753920,
                    targetZone = SETTINGS.TARGET_ZONE,
                    fields = {
                        webhookField(
                            "⚡ Placement Performance",
                            string.format(
                                "**%s/%s confirmed** — %.2f%%\n**%.1f/hour** — %.0f/day\nCurrent interval: **%.2fs**",
                                formatInteger(confirmed),
                                formatInteger(cycles),
                                successRate,
                                acceptedPerHour,
                                projectedPerDay,
                                currentInterval
                            ),
                            false
                        ),
                        webhookField(
                            "🛡️ Consistency",
                            string.format(
                                "First-pass acceptance: **%.2f%%**\nCall efficiency: **%.2f%%**\nRejections: %s • Failed cycles: %s",
                                initialPassRate,
                                callEfficiency,
                                formatInteger(rejected),
                                formatInteger(failedCycles)
                            ),
                            false
                        ),
                        webhookField(
                            "🔁 Recovery",
                            string.format(
                                "Recovered: %s (%.2f%%)\nRetry 1: %s • Retry 2: %s • Late: %s",
                                formatInteger(recoveredCycles),
                                recoveryRate,
                                formatInteger(firstRetryRecoveries),
                                formatInteger(secondRetryRecoveries),
                                formatInteger(lateConfirmations)
                            ),
                            false
                        ),
                        webhookField(
                            "🧠 Account Calibration",
                            tostring(dashboard.calibration)
                                .. "\nCircuit: "
                                .. (
                                    circuitBreakerActive
                                        and string.format("ACTIVE — %.0fs probe", circuitBreakerDelay)
                                        or "inactive"
                                )
                                .. " • Trips: "
                                .. formatInteger(circuitBreakerTrips),
                            false
                        ),
                        webhookField(
                            "📡 Communication Health",
                            string.format(
                                "%s\nCalls: %s • Errors: %s • Timeouts: %s\nLast response: `%s`",
                                tostring(dashboard.remote),
                                formatInteger(remoteCalls),
                                formatInteger(errors),
                                formatInteger(timeouts),
                                tostring(lastResponse)
                            ),
                            false
                        ),
                        webhookField(
                            "🕒 Run Snapshot",
                            string.format(
                                "Run uptime: %s\nClient uptime: %s\nRemaining supply: %s",
                                formatDuration(elapsed),
                                formatDuration(os.clock() - bootStartedAt),
                                formatInteger(lastKnownTotal)
                            ),
                            false
                        ),
                    },
                })
            end
        end

        local function getRejectionBackoff(streak)
            if streak <= 0 then
                return 0
            end

            local exponent = math.min(streak - 1, 4)
            return math.min(
                SETTINGS.REJECTION_BACKOFF_MAX,
                SETTINGS.REJECTION_BACKOFF_BASE * (2 ^ exponent)
            )
        end

        local adaptiveWindowCycles = 0
        local adaptiveWindowRejected = 0
        local adaptiveWindowFailed = 0
        local adaptivePressureWindows = 0
        local adaptiveHistory = {}
        local adaptiveHistoryRejected = 0
        local adaptiveHistoryFailed = 0
        local adaptiveHistorySecondRetries = 0
        local adaptiveRecoveryNotBefore = os.clock()

        local function clearAdaptiveHistory()
            adaptiveHistory = {}
            adaptiveHistoryRejected = 0
            adaptiveHistoryFailed = 0
            adaptiveHistorySecondRetries = 0
        end

        local function pushAdaptiveHistory(cycleConfirmed, cycleRejected, usedSecondRetry)
            local sample = {
                rejected = cycleRejected == true,
                failed = cycleConfirmed ~= true,
                secondRetry = usedSecondRetry == true,
            }

            table.insert(adaptiveHistory, sample)

            if sample.rejected then
                adaptiveHistoryRejected += 1
            end

            if sample.failed then
                adaptiveHistoryFailed += 1
            end

            if sample.secondRetry then
                adaptiveHistorySecondRetries += 1
            end

            while #adaptiveHistory > SETTINGS.ADAPTIVE_LONG_WINDOW do
                local removed = table.remove(adaptiveHistory, 1)

                if removed.rejected then
                    adaptiveHistoryRejected -= 1
                end

                if removed.failed then
                    adaptiveHistoryFailed -= 1
                end

                if removed.secondRetry then
                    adaptiveHistorySecondRetries -= 1
                end
            end
        end

        local function updateAdaptiveRate(cycleConfirmed, cycleRejected, usedSecondRetry)
            if not SETTINGS.ADAPTIVE then
                return
            end

            -- Consecutive complete failures are handled by the circuit
            -- breaker. They are more consistent with an occupied/stuck area
            -- than a sustainable-rate problem, so do not let them teach the
            -- normal interval controller the wrong lesson.
            if circuitBreakerActive then
                adaptiveWindowCycles = 0
                adaptiveWindowRejected = 0
                adaptiveWindowFailed = 0
                adaptivePressureWindows = 0
                adaptiveRecoveryNotBefore = math.max(
                    adaptiveRecoveryNotBefore,
                    os.clock() + SETTINGS.ADAPTIVE_FAILURE_HOLD
                )
                clearAdaptiveHistory()
                return
            end

            pushAdaptiveHistory(cycleConfirmed, cycleRejected, usedSecondRetry)
            adaptiveWindowCycles += 1

            if cycleRejected then
                adaptiveWindowRejected += 1
            end

            if not cycleConfirmed then
                adaptiveWindowFailed += 1
            end

            if adaptiveWindowCycles < SETTINGS.ADAPTIVE_WINDOW then
                return
            end

            local previousInterval = currentInterval
            local rejectRate = adaptiveWindowRejected / adaptiveWindowCycles
            local adjustmentReason = nil
            local pressureDetected = false
            local now = os.clock()
            local historyCycles = #adaptiveHistory
            local historyRejectRate = historyCycles > 0
                and adaptiveHistoryRejected / historyCycles
                or 0

            if adaptiveWindowFailed > 0 then
                pressureDetected = true
                currentInterval = math.min(
                    SETTINGS.ADAPTIVE_MAX_INTERVAL,
                    currentInterval
                        + SETTINGS.ADAPTIVE_STEP_UP
                        * math.min(2, adaptiveWindowFailed)
                )
                adaptivePressureWindows = 0
                adaptiveRecoveryNotBefore = math.max(
                    adaptiveRecoveryNotBefore,
                    now + SETTINGS.ADAPTIVE_FAILURE_HOLD
                )
                adjustmentReason = adaptiveWindowFailed == 1
                    and "unrecovered failed cycle"
                    or "multiple unrecovered failed cycles"
            elseif rejectRate >= SETTINGS.ADAPTIVE_HIGH_REJECT_RATE then
                pressureDetected = true
                adaptivePressureWindows += 1

                if adaptivePressureWindows >= SETTINGS.ADAPTIVE_PRESSURE_WINDOWS then
                    currentInterval = math.min(
                        SETTINGS.ADAPTIVE_MAX_INTERVAL,
                        currentInterval + SETTINGS.ADAPTIVE_PRESSURE_STEP
                    )
                    adaptivePressureWindows = 0
                    adjustmentReason = "persistent recovered rejection pressure"
                end
            else
                adaptivePressureWindows = 0
            end

            local changedByPressure = currentInterval > previousInterval

            if changedByPressure then
                adaptiveRecoveryNotBefore = math.max(
                    adaptiveRecoveryNotBefore,
                    now + SETTINGS.ADAPTIVE_RECOVERY_HOLD
                )
            end

            local longWindowReady = historyCycles >= SETTINGS.ADAPTIVE_LONG_WINDOW
            local recoveryEvidenceClean = longWindowReady
                and adaptiveHistoryFailed == 0
                and adaptiveHistorySecondRetries
                    <= SETTINGS.ADAPTIVE_RECOVERY_MAX_SECOND_RETRIES
                and historyRejectRate
                    <= SETTINGS.ADAPTIVE_RECOVERY_MAX_REJECT_RATE
            local recoveryHoldComplete = now >= adaptiveRecoveryNotBefore

            -- Short windows are permitted to slow the engine only. A speed
            -- recovery requires a full long window collected at the current
            -- interval plus the time hold. History is reset after every rate
            -- change, so each faster step must prove itself independently.
            if not pressureDetected
                and math.abs(currentInterval - previousInterval) < 0.001
                and currentInterval > SETTINGS.ADAPTIVE_MIN_INTERVAL
                and recoveryEvidenceClean
                and recoveryHoldComplete
            then
                currentInterval = math.max(
                    SETTINGS.ADAPTIVE_MIN_INTERVAL,
                    currentInterval - SETTINGS.ADAPTIVE_STEP_DOWN
                )
                adjustmentReason = "long-window stable recovery"
            end

            if math.abs(currentInterval - previousInterval) >= 0.001 then
                dashboard.interval = currentInterval
                dashboard.hourly = 3600 / currentInterval
                dashboard.daily = 86400 / currentInterval
                resetCalibrationSegment("adaptive interval adjustment")
                print(string.format(
                    "[Runtime] Adaptive | %.2fs -> %.2fs | %s "
                        .. "| rejected %d/%d | failed %d",
                    previousInterval,
                    currentInterval,
                    adjustmentReason or "window update",
                    adaptiveWindowRejected,
                    adaptiveWindowCycles,
                    adaptiveWindowFailed
                ))

                local slowedDown = currentInterval > previousInterval
                local protectiveProfileSaved = false

                if slowedDown
                    and SETTINGS.CALIBRATION
                    and currentInterval > (
                        tonumber(calibrationProfile.recommendedInterval)
                            or SETTINGS.ADAPTIVE_MIN_INTERVAL
                    )
                then
                    calibrationProfile.recommendedInterval = currentInterval
                    calibrationProfile.provisional = true
                    calibrationProfile.provisionalReason = adjustmentReason
                    calibrationProfile.qualifiedCycles = 0
                    calibrationProfile.qualifiedSeconds = 0
                    protectiveProfileSaved = saveCalibrationProfile()
                    dashboard.calibration = string.format(
                        "%s protective %.2fs",
                        protectiveProfileSaved and "Remembered" or "Session",
                        currentInterval
                    )
                end

                local windowConfirmed = adaptiveWindowCycles - adaptiveWindowFailed
                local cumulativeSuccessRate = cycles > 0
                    and confirmed / cycles * 100
                    or 0
                local holdSeconds = slowedDown and (
                    adaptiveWindowFailed > 0
                        and SETTINGS.ADAPTIVE_FAILURE_HOLD
                        or SETTINGS.ADAPTIVE_RECOVERY_HOLD
                ) or SETTINGS.ADAPTIVE_RECOVERY_HOLD

                sendWebhook({
                    title = slowedDown
                        and "Adaptive Rate Slowed"
                        or "Adaptive Rate Recovered",
                    description = slowedDown
                        and "The controller detected placement pressure and increased the interval to protect long-run consistency."
                        or string.format(
                            "%d stable cycles plus the recovery hold allowed one cautious step toward the %.2f-second target.",
                            SETTINGS.ADAPTIVE_LONG_WINDOW,
                            SETTINGS.ADAPTIVE_MIN_INTERVAL
                        ),
                    color = slowedDown and 16753920 or 5763719,
                    targetZone = SETTINGS.TARGET_ZONE,
                    fields = {
                        webhookField("Adjustment Reason", adjustmentReason or "Window update", false),
                        webhookField("Previous Interval", string.format("%.2f seconds", previousInterval), true),
                        webhookField("New Interval", string.format("%.2f seconds", currentInterval), true),
                        webhookField("Change", string.format("%+.2f seconds", currentInterval - previousInterval), true),
                        webhookField("Window Result", string.format("%d/%d confirmed", windowConfirmed, adaptiveWindowCycles), true),
                        webhookField("Cycles With Rejections", string.format("%d/%d", adaptiveWindowRejected, adaptiveWindowCycles), true),
                        webhookField("Window Rejection Rate", string.format("%.2f%%", rejectRate * 100), true),
                        webhookField("Failed Cycles", adaptiveWindowFailed, true),
                        webhookField(
                            "Long Recovery Evidence",
                            string.format(
                                "%d/%d cycles | %.2f%% rejected | %d failed | %d second retries",
                                historyCycles,
                                SETTINGS.ADAPTIVE_LONG_WINDOW,
                                historyRejectRate * 100,
                                adaptiveHistoryFailed,
                                adaptiveHistorySecondRetries
                            ),
                            false
                        ),
                        webhookField("Next Recovery Hold", formatDuration(holdSeconds), true),
                        webhookField(
                            "Calibration Memory",
                            slowedDown
                                and (
                                    protectiveProfileSaved
                                        and "Protective interval saved for the next relaunch"
                                        or "Protective interval active for this session"
                                )
                                or "Faster interval must complete full calibration before being remembered",
                            false
                        ),
                        webhookField(
                            "Pressure Rule",
                            string.format(
                                "%.0f%% for %d consecutive windows",
                                SETTINGS.ADAPTIVE_HIGH_REJECT_RATE * 100,
                                SETTINGS.ADAPTIVE_PRESSURE_WINDOWS
                            ),
                            true
                        ),
                        webhookField("Cumulative Confirmed", string.format("%s/%s", formatInteger(confirmed), formatInteger(cycles)), true),
                        webhookField("Cumulative Success", string.format("%.2f%%", cumulativeSuccessRate), true),
                        webhookField("New Maximum Pace", string.format("%.1f/min | %.0f/day", 60 / currentInterval, 86400 / currentInterval), true),
                        webhookField("Allowed Range", string.format("%.2f-%.2f seconds", SETTINGS.ADAPTIVE_MIN_INTERVAL, SETTINGS.ADAPTIVE_MAX_INTERVAL), true),
                    },
                })

                adaptiveRecoveryNotBefore = math.max(
                    adaptiveRecoveryNotBefore,
                    now + holdSeconds
                )
                clearAdaptiveHistory()
            end

            adaptiveWindowCycles = 0
            adaptiveWindowRejected = 0
            adaptiveWindowFailed = 0
        end

        local function clearRejectionStreak()
            local recoveredStreak = rejectedStreak
            local recoveredFromCircuit = circuitBreakerActive
            local recoveredCircuitDelay = circuitBreakerDelay
            rejectedStreak = 0
            circuitBreakerActive = false
            circuitBreakerDelay = SETTINGS.CIRCUIT_BREAKER_INITIAL_DELAY

            if recoveredFromCircuit then
                adaptiveRecoveryNotBefore = math.max(
                    adaptiveRecoveryNotBefore,
                    os.clock() + SETTINGS.ADAPTIVE_FAILURE_HOLD
                )
                clearAdaptiveHistory()
                resetCalibrationSegment("circuit breaker recovered")
                dashboard.state = "Calibrating"
            end

            if rejectionAlertActive or recoveredFromCircuit then
                sendWebhook({
                    title = recoveredFromCircuit
                        and "Circuit Breaker Recovered"
                        or "Server Rejection Streak Recovered",
                    description = recoveredFromCircuit
                        and "A controlled diagnostic probe was accepted. Normal placement has resumed at the protected interval, while speed recovery remains locked."
                        or "The server accepted placement again. Temporary rejection backoff has been cleared.",
                    color = 5763719,
                    targetZone = SETTINGS.TARGET_ZONE,
                    fields = {
                        webhookField("Recovered Streak", formatInteger(recoveredStreak), true),
                        webhookField("Last Probe Delay", string.format("%.0f seconds", recoveredCircuitDelay), true),
                        webhookField("Current Interval", string.format("%.2f seconds", currentInterval), true),
                        webhookField(
                            "Speed Recovery Locked",
                            recoveredFromCircuit
                                and formatDuration(SETTINGS.ADAPTIVE_FAILURE_HOLD)
                                or "No",
                            true
                        ),
                        webhookField("Confirmed Placements", formatInteger(confirmed), true),
                        webhookField("Failed Cycles", formatInteger(failedCycles), true),
                        webhookField("Remote Errors", formatInteger(errors), true),
                        webhookField("Remote Timeouts", formatInteger(timeouts), true),
                    },
                })
            end

            rejectionAlertActive = false
        end

        local function alertOnRejectionStreak()
            if rejectedStreak >= SETTINGS.CIRCUIT_BREAKER_AFTER
                and not circuitBreakerActive
            then
                circuitBreakerActive = true
                circuitBreakerDelay = SETTINGS.CIRCUIT_BREAKER_INITIAL_DELAY
                circuitBreakerTrips += 1
                rejectionAlertActive = true
                calibrationSegmentContaminated = true
                dashboard.state = "Circuit"
                dashboard.calibration = "Excluded stuck-area episode"

                sendWebhook({
                    title = "Placement Circuit Breaker Engaged",
                    description = "Consecutive complete placement failures look more like an occupied/stuck area than ordinary timing pressure. Rapid placement has paused; the engine will use increasingly spaced diagnostic probes.",
                    color = 15548997,
                    targetZone = SETTINGS.TARGET_ZONE,
                    critical = true,
                    fields = {
                        webhookField("Consecutive Failed Cycles", formatInteger(rejectedStreak), true),
                        webhookField("First Probe In", string.format("%.0f seconds", circuitBreakerDelay), true),
                        webhookField("Maximum Probe Delay", string.format("%.0f seconds", SETTINGS.CIRCUIT_BREAKER_MAX_DELAY), true),
                        webhookField("Adaptive Interval", string.format("%.2f seconds", currentInterval), true),
                        webhookField("Circuit Trips", formatInteger(circuitBreakerTrips), true),
                        webhookField("Total Server Rejections", formatInteger(rejected), true),
                        webhookField("Total Failed Cycles", formatInteger(failedCycles + 1), true),
                        webhookField("Last Server Response", tostring(lastResponse), true),
                        webhookField("Suggested Check", "If probes remain rejected, inspect the configured farming area for an invisible or stuck event.", false),
                    },
                })
                return
            end

            if rejectionAlertActive
                or rejectedStreak < SETTINGS.WEBHOOK_ALERT_REJECT_STREAK
            then
                return
            end

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
                if not waitForFarmArea() then
                    break
                end

                applyFpsCap()

                if not waitForAccountPhase() then
                    break
                end
            end

            local cycleFinished = false
            local cycleCounted = false
            local cycleConfirmed = false
            local lostFarmArea = false
            local nextAttemptAt = os.clock()
            local cycleHadServerReject = false
            local cycleUsedSecondRetry = false
            local cycleRetryLimit = rejectedStreak >= SETTINGS.RETRY_DISABLE_AFTER
                and 0
                or SETTINGS.MAX_RETRIES

            for retryIndex = 0, cycleRetryLimit do
                if env.STOP_MINI_PINATA_FAST_PLACER then
                    break
                end

                if not getCharacterRoot() or not isInsideFarmArea() then
                    lostFarmArea = true
                    break
                end

                local uid, totalBefore, ready = findItemStack()

                if not ready then
                    task.wait(0.5)
                    uid, totalBefore, ready = findItemStack()
                end

                if ready then
                    inventoryUnavailableSince = nil
                elseif not inventoryUnavailableSince then
                    inventoryUnavailableSince = os.clock()
                elseif os.clock() - inventoryUnavailableSince
                    >= SETTINGS.INVENTORY_RECOVERY_TIMEOUT
                then
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

                    if retryIndex >= 2 then
                        cycleUsedSecondRetry = true
                    end
                end

                remoteCalls += 1

                local endpoint = getConsumeEndpoint()

                if not endpoint then
                    error("[Runtime] Consume endpoint became unavailable.")
                end

                local ok, response, didTimeout = invokeConsumeWithTimeout(endpoint, uid)
                heartbeat("remote invocation complete")

                lastResponse = response

                if didTimeout then
                    timeouts += 1
                end

                local didConfirm = false
                local amountUsed = 0
                local totalAfter = nil

                if ok then
                    consecutiveRemoteErrors = 0
                end

                if ok and response == true then
                    -- The server explicitly accepted the placement. Inventory
                    -- replication may arrive later, so do not retry this call.
                    local inventoryTotal = getReliableTotal()

                    didConfirm = true
                    amountUsed = 1

                    if inventoryTotal and inventoryTotal < totalBefore then
                        totalAfter = inventoryTotal
                    else
                        totalAfter = math.max(0, totalBefore - 1)
                    end
                elseif ok and response ~= false then
                    -- Use inventory confirmation only when the remote does not
                    -- return an explicit success/failure boolean.
                    didConfirm, amountUsed, totalAfter = waitForConfirmation(totalBefore)
                elseif ok and response == false then
                    rejected += 1
                    cycleHadServerReject = true
                else
                    errors += 1
                    consecutiveRemoteErrors += 1
                    local failedEndpointLabel = endpoint.label
                    ConsumeEndpoint = nil
                    lastResolvedEndpointLabel = nil
                    dashboard.remote = "Re-resolving after error"

                    if errors == 1 or errors % 10 == 0 then
                        warn("[Runtime] Remote failed: " .. tostring(response))
                    end

                    if consecutiveRemoteErrors == 1 then
                        sendWebhook({
                            title = "Remote Route Invalidated",
                            description = "A genuine communication error invalidated the cached endpoint. Automatic resolution will run before the next placement attempt. A normal server response of `false` does not trigger this process.",
                            color = 16753920,
                            targetZone = SETTINGS.TARGET_ZONE,
                            fields = {
                                webhookField("Failed Endpoint", failedEndpointLabel, false),
                                webhookField("Error", tostring(response), false),
                                webhookField("Resolver State", "Re-resolving", true),
                                webhookField("Consecutive Remote Errors", consecutiveRemoteErrors, true),
                            },
                        })
                    end

                    if consecutiveRemoteErrors >= SETTINGS.REMOTE_ERROR_RESTART_AFTER then
                        error("[Runtime] Repeated remote failures; restarting engine.")
                    end
                end

                if didConfirm then
                    recordConfirmation(amountUsed, totalAfter)
                    cycleConfirmed = true

                    if cycleHadServerReject then
                        recoveredCycles += 1

                        if retryIndex == 1 then
                            firstRetryRecoveries += 1
                        elseif retryIndex >= 2 then
                            secondRetryRecoveries += 1

                            sendWebhook({
                                title = "Recovery Retry Succeeded",
                                description = "The normal retry was still rejected, but the slower recovery retry placed the Mini Pinata successfully and prevented a failed cycle.",
                                color = 16753920,
                                targetZone = SETTINGS.TARGET_ZONE,
                                fields = {
                                    webhookField("Placement Cycle", formatInteger(cycles), true),
                                    webhookField("Recovery Delay", string.format("%.2f seconds", SETTINGS.RECOVERY_RETRY_DELAY), true),
                                    webhookField("Current Interval", string.format("%.2f seconds", currentInterval), true),
                                    webhookField("Inventory Remaining", formatInteger(lastKnownTotal), true),
                                    webhookField("Second-Retry Recoveries", formatInteger(secondRetryRecoveries), true),
                                    webhookField("Failed Cycles Avoided", formatInteger(secondRetryRecoveries), true),
                                },
                            })
                        end
                    end

                    clearRejectionStreak()
                    cycleFinished = true
                elseif retryIndex < cycleRetryLimit then
                    local retryWait = retryIndex == 0
                        and SETTINGS.RETRY_DELAY
                        or SETTINGS.RECOVERY_RETRY_DELAY

                    if not waitUntil(os.clock() + retryWait) then
                        break
                    end

                    local lateTotal = getReliableTotal()

                    if lateTotal and totalBefore > 0 and lateTotal < totalBefore then
                        recordConfirmation(totalBefore - lateTotal, lateTotal)
                        cycleConfirmed = true

                        if cycleHadServerReject then
                            recoveredCycles += 1
                            lateConfirmations += 1
                        end

                        clearRejectionStreak()
                        cycleFinished = true
                    end
                else
                    if cycleHadServerReject then
                        rejectedStreak += 1

                        if rejectedStreak == 1 then
                            sendWebhook({
                                title = "Placement Cycle Unconfirmed",
                                description = "The placement cycle remained unconfirmed after all configured attempts. The engine remains active and will continue after controlled backoff.",
                                color = 16753920,
                                targetZone = SETTINGS.TARGET_ZONE,
                                fields = {
                                    webhookField("Placement Cycle", formatInteger(cycles), true),
                                    webhookField("Attempts Used", formatInteger(cycleRetryLimit + 1), true),
                                    webhookField("Current Interval", string.format("%.2f seconds", currentInterval), true),
                                    webhookField("Next Delay", string.format("%.2f seconds", math.max(currentInterval, getRejectionBackoff(rejectedStreak))), true),
                                    webhookField("Total Failed Cycles", formatInteger(failedCycles + 1), true),
                                    webhookField("Last Server Response", tostring(lastResponse), true),
                                },
                            })
                        end

                        local circuitWasAlreadyActive = circuitBreakerActive
                        alertOnRejectionStreak()

                        if circuitWasAlreadyActive then
                            circuitBreakerDelay = math.min(
                                SETTINGS.CIRCUIT_BREAKER_MAX_DELAY,
                                circuitBreakerDelay * 2
                            )
                        end
                    end

                    cycleFinished = true
                end

                if cycleFinished then
                    break
                end
            end

            if env.STOP_MINI_PINATA_FAST_PLACER or noItemsRemain then
                break
            end

            if cycleFinished and cycleCounted then
                if not cycleConfirmed then
                    failedCycles += 1
                end

                dashboard.interval = currentInterval
                dashboard.successRate = cycles > 0
                    and confirmed / cycles * 100
                    or 100

                if circuitBreakerActive then
                    dashboard.state = "Circuit"
                end

                heartbeat("adaptive update")
                recordCalibrationSample(
                    cycleConfirmed,
                    cycleHadServerReject,
                    cycleUsedSecondRetry
                )
                updateAdaptiveRate(
                    cycleConfirmed,
                    cycleHadServerReject,
                    cycleUsedSecondRetry
                )
                heartbeat("adaptive update complete")

                -- Always anchor the next primary placement to completion of
                -- the current cycle. A successful retry therefore receives a
                -- complete interval before another primary request begins.
                local scheduleBase = os.clock()

                if cycleConfirmed then
                    local jitter = SETTINGS.PACING_JITTER_MAX > 0
                        and math.random() * SETTINGS.PACING_JITTER_MAX
                        or 0
                    nextAttemptAt = scheduleBase + currentInterval + jitter
                elseif circuitBreakerActive then
                    nextAttemptAt = scheduleBase + circuitBreakerDelay
                else
                    -- Backoff replaces the normal interval when it is larger;
                    -- stacking both delays would over-penalize a transient
                    -- failure that may recover on the next cycle.
                    nextAttemptAt = scheduleBase
                        + math.max(
                            currentInterval,
                            getRejectionBackoff(rejectedStreak)
                        )
                end

                printStatus()
            end

            if not lostFarmArea and cycleFinished then
                waitUntil(nextAttemptAt)
            end
        end

        print(string.format(
            "[Runtime] Stopped | cycles %d | confirmed %d | calls %d "
                .. "| retries %d | recovered %d | retry2 %d "
                .. "| rejected %d | failed %d | errors %d "
                .. "| timeouts %d | interval %.2fs",
            cycles,
            confirmed,
            remoteCalls,
            retries,
            recoveredCycles,
            secondRetryRecoveries,
            rejected,
            failedCycles,
            errors,
            timeouts,
            currentInterval
        ))

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

        sendWebhook({
            title = noItemsRemain and "Mini Pinata Inventory Exhausted" or "Mini Pinata Engine Stopped",
            description = noItemsRemain
                and "The engine stopped cleanly after using the final available Mini Pinata."
                or "The placement run ended because the engine received a stop signal.",
            color = noItemsRemain and 16753920 or 9807270,
            targetZone = SETTINGS.TARGET_ZONE,
            fields = {
                webhookField("Placement Cycles", formatInteger(cycles), true),
                webhookField("Confirmed Placements", formatInteger(confirmed), true),
                webhookField("Cycle Success Rate", string.format("%.2f%%", finalSuccessRate), true),
                webhookField("Remote Calls", formatInteger(remoteCalls), true),
                webhookField("Retries", formatInteger(retries), true),
                webhookField("Recovered-Cycle Rate", string.format("%.2f%%", finalRecoveryRate), true),
                webhookField(
                    "Retry Recovery Details",
                    string.format(
                        "Recovered cycles: %s | First retry: %s | Second retry: %s | Late confirmation: %s",
                        formatInteger(recoveredCycles),
                        formatInteger(firstRetryRecoveries),
                        formatInteger(secondRetryRecoveries),
                        formatInteger(lateConfirmations)
                    ),
                    false
                ),
                webhookField("Server Rejections", formatInteger(rejected), true),
                webhookField("Failed Cycles", formatInteger(failedCycles), true),
                webhookField("Remote Errors", formatInteger(errors), true),
                webhookField("Remote Timeouts", formatInteger(timeouts), true),
                webhookField("Final Interval", string.format("%.2f seconds", currentInterval), true),
                webhookField("Observed Throughput", string.format("%.1f/hour | %.0f/day", finalPerHour, finalPerDay), true),
                webhookField("Inventory Remaining", formatInteger(lastKnownTotal), true),
            },
        })

        return noItemsRemain and "no_items" or "stopped"
    end

    local function runEngineMonitored()
        heartbeat("engine thread start")

        local completed = false
        local engineSuccess = false
        local engineResult = nil

        local engineThread = task.spawn(function()
            local success, result = xpcall(runEngine, function(err)
                return tostring(err)
            end)

            engineSuccess = success
            engineResult = result
            completed = true
        end)

        while not completed and not env.STOP_MINI_PINATA_FAST_PLACER do
            local silentFor = os.clock() - heartbeatAt

            if silentFor >= watchdogTimeout then
                local stalledState = heartbeatState
                local cancelled = cancelManagedThread(engineThread)

                if not cancelled and completed then
                    return engineSuccess, engineResult
                end

                if not cancelled then
                    cancellationFailed = true
                    env.STOP_MINI_PINATA_FAST_PLACER = true
                    return false, string.format(
                        "watchdog could not cancel stalled state '%s'",
                        tostring(stalledState)
                    )
                end

                return false, string.format(
                    "watchdog detected %.0fs without progress in state '%s'",
                    silentFor,
                    tostring(stalledState)
                )
            end

            task.wait(1)
        end

        if completed then
            return engineSuccess, engineResult
        end

        local cancelled = cancelManagedThread(engineThread)

        if not cancelled and not completed then
            cancellationFailed = true
            return false, "engine thread could not be cancelled during shutdown"
        end

        return true, "stopped"
    end

    local restartDelayBase = math.max(
        5,
        numberSetting("GPINATA_RESTART_DELAY", 15)
    )
    local restartDelay = restartDelayBase
    local restartDelayMax = math.max(
        restartDelay,
        numberSetting("GPINATA_RESTART_DELAY_MAX", 300)
    )

    while not env.STOP_MINI_PINATA_FAST_PLACER do
        local runStartedAt = os.clock()
        local success, result = runEngineMonitored()

        if success then
            break
        end

        local runDuration = os.clock() - runStartedAt

        if runDuration >= 300 then
            restartDelay = restartDelayBase
        end

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

        warn(string.format(
            "[Runtime] Engine fault: %s | retrying in %.0fs",
            tostring(result),
            restartDelay
        ))

        if not supervisorWait(restartDelay) then
            break
        end

        dashboard.state = "Booting"

        if runDuration < 300 then
            restartDelay = math.min(restartDelay * 2, restartDelayMax)
        end
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
