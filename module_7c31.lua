local env = getgenv()
local ENGINE_BUILD = "consistency-webhooks-9"

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

    local function webhookField(name, value, inline)
        return {
            name = safeWebhookText(name, 256),
            value = safeWebhookText(value, 1024),
            inline = inline == true,
        }
    end

    local function webhookContextFields(targetZone)
        local accountName = WebhookPlayer and WebhookPlayer.Name or "Unknown"
        local userId = WebhookPlayer and WebhookPlayer.UserId or "Unknown"
        local jobId = game.JobId ~= "" and game.JobId or "Unknown"

        return {
            webhookField("Account", accountName, true),
            webhookField("Roblox User ID", userId, true),
            webhookField("Configured Area", targetZone or env.GZONE_TO or "Unknown", true),
            webhookField("Client Uptime", formatDuration(os.clock() - bootStartedAt), true),
            webhookField("Place ID", game.PlaceId, true),
            webhookField("Server Job ID", jobId, false),
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
                    description = safeWebhookText(options.description or "", 4096),
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
            -- Start at the consistency-first 6.2-second target. The controller may
            -- slow an individual account under server pressure, then recover
            -- toward this target after stable observation windows.
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
            ADAPTIVE_STABLE_WINDOWS = math.max(
                1,
                math.floor(numberSetting("GPINATA_ADAPTIVE_STABLE_WINDOWS", 1))
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
        local ConsumeRemote = nil

        local function getConsumeRemote()
            heartbeat("remote resolution")

            if ConsumeRemote and ConsumeRemote.Parent then
                return ConsumeRemote
            end

            local Network = ReplicatedStorage:FindFirstChild("Network")

            if not Network then
                Network = ReplicatedStorage:WaitForChild("Network", 30)
            end

            if not Network then
                return nil
            end

            ConsumeRemote = Network:FindFirstChild("MiniPinata" .. "_Consume")

            if not ConsumeRemote then
                ConsumeRemote = Network:WaitForChild("MiniPinata" .. "_Consume", 30)
            end

            return ConsumeRemote
        end

        local function invokeConsumeWithTimeout(remote, uid)
            heartbeat("remote invocation")

            local completed = false
            local callOk = false
            local callResult = nil

            local invokeThread = task.spawn(function()
                local ok, result = pcall(function()
                    return remote:InvokeServer(uid)
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

        local function findItemStack()
            local data = getSaveData()
            local inventory = data and data.Inventory
            local misc = inventory and inventory.Misc

            if type(misc) ~= "table" then
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

        if not getConsumeRemote() then
            error("[Runtime] Consume remote was not found.")
        end

        applyFpsCap()

        if not waitForAccountPhase() then
            return "stopped"
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
                webhookField("Adaptive Window", string.format("%d cycles", SETTINGS.ADAPTIVE_WINDOW), true),
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
        local failedCycles = 0
        local errors = 0
        local timeouts = 0
        local consecutiveRemoteErrors = 0
        local inventoryUnavailableSince = nil
        local lastResponse = nil
        local lastKnownTotal = initialTotal
        local noItemsRemain = false

        local function recordConfirmation(amountUsed, totalAfter)
            local firstConfirmation = confirmed == 0
            confirmed += amountUsed
            lastKnownTotal = totalAfter or math.max(0, lastKnownTotal - amountUsed)

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
                sendWebhook({
                    title = "Placement Status - " .. formatInteger(cycles) .. " Cycles",
                    description = "Scheduled operational summary for this account's current placement run.",
                    color = failedCycles == 0 and recoveryRate < 5
                        and 3447003
                        or 16753920,
                    targetZone = SETTINGS.TARGET_ZONE,
                    fields = {
                        webhookField("Run Uptime", formatDuration(elapsed), true),
                        webhookField("Placement Cycles", formatInteger(cycles), true),
                        webhookField("Confirmed Placements", formatInteger(confirmed), true),
                        webhookField("Cycle Success Rate", string.format("%.2f%%", successRate), true),
                        webhookField("Remote Calls", formatInteger(remoteCalls), true),
                        webhookField("Call Efficiency", string.format("%.2f%%", callEfficiency), true),
                        webhookField("Retries", formatInteger(retries), true),
                        webhookField("Recovered-Cycle Rate", string.format("%.2f%%", recoveryRate), true),
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
                        webhookField("Current Reject Streak", formatInteger(rejectedStreak), true),
                        webhookField("Remote Errors", formatInteger(errors), true),
                        webhookField("Remote Timeouts", formatInteger(timeouts), true),
                        webhookField("Current Interval", string.format("%.2f seconds", currentInterval), true),
                        webhookField("Actual Throughput", string.format("%.1f/hour | %.0f/day", acceptedPerHour, projectedPerDay), true),
                        webhookField("Inventory Remaining", formatInteger(lastKnownTotal), true),
                        webhookField("Last Server Response", tostring(lastResponse), false),
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
        local adaptiveStableWindows = 0
        local adaptivePressureWindows = 0

        local function updateAdaptiveRate(cycleConfirmed, cycleRejected)
            if not SETTINGS.ADAPTIVE then
                return
            end

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

            if adaptiveWindowFailed > 0 then
                currentInterval = math.min(
                    SETTINGS.ADAPTIVE_MAX_INTERVAL,
                    currentInterval
                        + SETTINGS.ADAPTIVE_STEP_UP
                        * math.min(2, adaptiveWindowFailed)
                )
                adaptiveStableWindows = 0
                adaptivePressureWindows = 0
                adjustmentReason = adaptiveWindowFailed == 1
                    and "unrecovered failed cycle"
                    or "multiple unrecovered failed cycles"
            elseif rejectRate >= SETTINGS.ADAPTIVE_HIGH_REJECT_RATE then
                adaptivePressureWindows += 1
                adaptiveStableWindows = 0

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
                adaptiveStableWindows += 1

                if adaptiveStableWindows >= SETTINGS.ADAPTIVE_STABLE_WINDOWS then
                    currentInterval = math.max(
                        SETTINGS.ADAPTIVE_MIN_INTERVAL,
                        currentInterval - SETTINGS.ADAPTIVE_STEP_DOWN
                    )
                    adaptiveStableWindows = 0
                    adjustmentReason = "stable recovery"
                end
            end

            if math.abs(currentInterval - previousInterval) >= 0.001 then
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
                local windowConfirmed = adaptiveWindowCycles - adaptiveWindowFailed
                local cumulativeSuccessRate = cycles > 0
                    and confirmed / cycles * 100
                    or 0

                sendWebhook({
                    title = slowedDown
                        and "Adaptive Rate Slowed"
                        or "Adaptive Rate Recovered",
                    description = slowedDown
                        and "The controller detected placement pressure and increased the interval to protect long-run consistency."
                        or string.format(
                            "%d stable observation window(s) allowed the controller to move closer to the %.2f-second target.",
                            SETTINGS.ADAPTIVE_STABLE_WINDOWS,
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
            end

            adaptiveWindowCycles = 0
            adaptiveWindowRejected = 0
            adaptiveWindowFailed = 0
        end

        local function clearRejectionStreak()
            local recoveredStreak = rejectedStreak
            rejectedStreak = 0

            if rejectionAlertActive then
                sendWebhook({
                    title = "Server Rejection Streak Recovered",
                    description = "The server accepted placement again. Temporary rejection backoff has been cleared.",
                    color = 5763719,
                    targetZone = SETTINGS.TARGET_ZONE,
                    fields = {
                        webhookField("Recovered Streak", formatInteger(recoveredStreak), true),
                        webhookField("Current Interval", string.format("%.2f seconds", currentInterval), true),
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
            local intervalAtCycleStart = currentInterval
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
                end

                remoteCalls += 1

                local attemptStartedAt = os.clock()
                local remote = getConsumeRemote()

                if not remote then
                    error("[Runtime] Consume remote became unavailable.")
                end

                local ok, response, didTimeout = invokeConsumeWithTimeout(remote, uid)
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
                    ConsumeRemote = nil

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
                    nextAttemptAt = attemptStartedAt + currentInterval
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
                        nextAttemptAt = attemptStartedAt + currentInterval
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

                        alertOnRejectionStreak()
                    end

                    -- Backoff replaces the normal interval when it is larger;
                    -- stacking both delays unnecessarily penalized transient
                    -- failures that recovered on the following cycle.
                    nextAttemptAt = attemptStartedAt
                        + math.max(
                            currentInterval,
                            getRejectionBackoff(rejectedStreak)
                        )
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

                heartbeat("adaptive update")
                updateAdaptiveRate(cycleConfirmed, cycleHadServerReject)
                heartbeat("adaptive update complete")

                -- Apply a controller change to the next scheduled attempt,
                -- including a slowdown selected at the end of this cycle.
                nextAttemptAt += currentInterval - intervalAtCycleStart

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

        sendWebhook({
            title = noItemsRemain and "Mini Pinata Inventory Exhausted" or "Mini Pinata Engine Stopped",
            description = noItemsRemain
                and "The engine stopped cleanly after using the final available Mini Pinata."
                or "The placement run ended because the engine received a stop signal.",
            color = noItemsRemain and 16753920 or 9807270,
            targetZone = SETTINGS.TARGET_ZONE,
            fields = {
                webhookField("Run Uptime", formatDuration(finalElapsed), true),
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

        if runDuration < 300 then
            restartDelay = math.min(restartDelay * 2, restartDelayMax)
        end
    end

    if cancellationFailed then
        warn("[Runtime] Safety guard retained until the next client relaunch.")
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
