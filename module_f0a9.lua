local env = getgenv()
local LEDGER_BUILD = "fleet-ledger-1.1"

if env.GLEDGER_ENABLED == false then
    return
end

if env.__FLEET_PROFIT_LEDGER_RUNNING then
    warn("[Ledger] Already running.")
    return
end

env.__FLEET_PROFIT_LEDGER_RUNNING = true
env.STOP_FLEET_PROFIT_LEDGER = false
env.GLEDGER_BUILD = LEDGER_BUILD

task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    local HttpService = game:GetService("HttpService")
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local RunService = game:GetService("RunService")
    local Stats = game:GetService("Stats")
    local LocalPlayer = Players.LocalPlayer
    local startedAt = os.clock()

    local function numberSetting(name, default)
        return tonumber(env[name]) or default
    end

    local SETTINGS = {
        SAMPLE_SECONDS = math.max(
            5,
            numberSetting("GLEDGER_SAMPLE_SECONDS", 15)
        ),
        REPORT_SECONDS = math.max(
            300,
            numberSetting("GLEDGER_REPORT_SECONDS", 35 * 60)
        ),
        REPORT_STAGGER_MAX = math.max(
            0,
            math.min(
                600,
                numberSetting("GLEDGER_REPORT_STAGGER_MAX", 180)
            )
        ),
        CHECKPOINT_SECONDS = math.max(
            60,
            numberSetting("GLEDGER_CHECKPOINT_SECONDS", 300)
        ),
        STARTUP_TIMEOUT = math.max(
            30,
            numberSetting("GLEDGER_STARTUP_TIMEOUT", 180)
        ),
        WEBHOOK_ENABLED = env.GLEDGER_WEBHOOK_ENABLED ~= false,
        WEBHOOK_QUEUE_LIMIT = math.max(
            3,
            math.min(
                20,
                math.floor(numberSetting("GLEDGER_WEBHOOK_QUEUE_LIMIT", 10))
            )
        ),
        ROLE = tostring(env.GLEDGER_ROLE or "Farmer"),
        TARGET_ZONE = tonumber(env.GZONE_TO),
    }

    local DEFAULT_ITEMS = {
        "Mini Pinata",
        "Charm Stone",
        "Cocktail",
        "Seed Bag",
        "Diamond Seed Bag",
        "Hasty Flag",
        "Sprinkler",
    }
    local configuredItems = type(env.GLEDGER_ITEMS) == "table"
        and env.GLEDGER_ITEMS
        or DEFAULT_ITEMS

    local function normalize(value)
        return type(value) == "string"
            and string.lower(value):gsub("[^%w]", "")
            or ""
    end

    local trackedItems = {}
    local trackedOrder = {}

    for _, displayName in ipairs(configuredItems) do
        local key = normalize(displayName)

        if key ~= "" and trackedItems[key] == nil then
            trackedItems[key] = tostring(displayName)
            table.insert(trackedOrder, key)
        end
    end

    local function executorFunction(name)
        local candidate = rawget(env, name) or rawget(_G, name)
        return type(candidate) == "function" and candidate or nil
    end

    local readFile = executorFunction("readfile")
    local writeFile = executorFunction("writefile")
    local requestFunction = executorFunction("request")
        or executorFunction("http_request")
    local synTable = rawget(env, "syn") or rawget(_G, "syn")

    if not requestFunction and type(synTable) == "table" then
        requestFunction = type(synTable.request) == "function"
            and synTable.request
            or nil
    end

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
        local valid = string.find(
            lower,
            "https://discord.com/api/webhooks/",
            1,
            true
        ) == 1
            or string.find(
                lower,
                "https://discordapp.com/api/webhooks/",
                1,
                true
            ) == 1
            or string.find(
                lower,
                "https://canary.discord.com/api/webhooks/",
                1,
                true
            ) == 1

        return valid and url or nil
    end

    local webhookUrl = normalizeWebhookUrl(
        env.GLEDGER_WEBHOOK_URL or env.GWEBHOOK_LINK
    )
    local webhookEnabled = SETTINGS.WEBHOOK_ENABLED
        and webhookUrl ~= nil
        and requestFunction ~= nil
    local webhookQueue = {}
    local webhookWorkerRunning = false
    local webhookFailureWarned = false

    if SETTINGS.WEBHOOK_ENABLED and not webhookEnabled then
        warn("[Ledger] Webhook unavailable; continuing with local telemetry.")
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

    local function formatSignedCompact(value)
        local number = tonumber(value) or 0
        return (number >= 0 and "+" or "")
            .. formatCompact(number)
            .. " (`"
            .. formatInteger(number)
            .. "`)"
    end

    local function formatDuration(seconds)
        seconds = math.max(0, math.floor(tonumber(seconds) or 0))
        local days = math.floor(seconds / 86400)
        local hours = math.floor((seconds % 86400) / 3600)
        local minutes = math.floor((seconds % 3600) / 60)
        local remainingSeconds = seconds % 60

        if days > 0 then
            return string.format(
                "%dd %02dh %02dm %02ds",
                days,
                hours,
                minutes,
                remainingSeconds
            )
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

    local function responseStatus(response)
        return type(response) == "table" and tonumber(
            response.StatusCode
                or response.Status
                or response.status_code
                or response.status
        ) or nil
    end

    local function deliverWebhook(payload)
        local encodedOk, body = pcall(
            HttpService.JSONEncode,
            HttpService,
            payload
        )

        if not encodedOk then
            return false, "JSON encoding failed"
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
                    return false, "HTTP " .. tostring(status)
                end
            elseif attempt == 1 then
                task.wait(1)
            else
                return false, tostring(response)
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
                    warn("[Ledger] Webhook failed: " .. tostring(deliveryError))
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

    local function enqueueWebhook(title, description, fields, color)
        if not webhookEnabled then
            return
        end

        local accountName = LocalPlayer and LocalPlayer.Name or "Unknown"
        local outputFields = {
            webhookField(
                "Account",
                accountName
                    .. " (`"
                    .. tostring(LocalPlayer and LocalPlayer.UserId or 0)
                    .. "`)",
                true
            ),
            webhookField("Role", SETTINGS.ROLE, true),
            webhookField(
                "Runtime",
                formatDuration(os.clock() - startedAt),
                true
            ),
        }

        for _, field in ipairs(fields or {}) do
            if #outputFields >= 25 then
                break
            end

            table.insert(outputFields, field)
        end

        local payload = {
            username = safeText("Gem Ledger - " .. accountName, 80),
            allowed_mentions = { parse = {} },
            embeds = {
                {
                    title = safeText(title, 256),
                    description = safeText(description, 4096),
                    color = tonumber(color) or 3447003,
                    fields = outputFields,
                    footer = { text = "Ledger " .. LEDGER_BUILD },
                    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                },
            },
        }

        if #webhookQueue >= SETTINGS.WEBHOOK_QUEUE_LIMIT then
            table.remove(webhookQueue, 1)
        end

        table.insert(webhookQueue, payload)
        startWebhookWorker()
    end

    local Library = ReplicatedStorage:WaitForChild("Library")
    local Client = Library:WaitForChild("Client")
    local Save = require(Client:WaitForChild("Save"))
    local MapCmds = nil

    local function getSaveData()
        local ok, data = pcall(Save.Get)
        return ok and type(data) == "table" and data or nil
    end

    local function amountFromValue(value, depth)
        depth = depth or 0

        if depth > 2 then
            return nil
        end

        if type(value) == "number" or type(value) == "string" then
            local amount = tonumber(value)
            return amount and amount >= 0 and amount == amount and amount or nil
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
            local amount = amountFromValue(candidate, depth + 1)

            if amount ~= nil then
                return amount
            end
        end

        return nil
    end

    local function gemsInContainer(container)
        if type(container) ~= "table" then
            return nil
        end

        local best = nil

        for key, value in pairs(container) do
            local keyName = normalize(key)
            local itemName = type(value) == "table" and normalize(
                value.id
                    or value._id
                    or value.ID
                    or value.Name
                    or value.name
            ) or ""

            if keyName == "diamonds"
                or keyName == "gems"
                or itemName == "diamonds"
                or itemName == "gems"
            then
                local amount = amountFromValue(value)

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
        local containers = {
            inventory and inventory.Currency,
            inventory and inventory.Currencies,
            data.Currency,
            data.Currencies,
            data.currency,
            data.currencies,
        }

        for _, container in ipairs(containers) do
            local amount = gemsInContainer(container)

            if amount ~= nil then
                return amount
            end
        end

        for _, key in ipairs({ "Diamonds", "diamonds", "Gems", "gems" }) do
            local direct = amountFromValue(data[key])

            if direct ~= nil then
                return direct
            end
        end

        return nil
    end

    local function addTrackedAmount(totals, candidateName, value)
        local key = normalize(candidateName)

        if trackedItems[key] == nil then
            return
        end

        local amount = amountFromValue(value)

        if amount == nil and type(value) == "table" then
            amount = 1
        end

        if amount and amount >= 0 then
            totals[key] = (totals[key] or 0) + amount
        end
    end

    local function scanTrackedItems(data)
        local totals = {}

        for _, key in ipairs(trackedOrder) do
            totals[key] = 0
        end

        local inventory = type(data) == "table" and data.Inventory or nil

        if type(inventory) ~= "table" then
            return totals
        end

        for categoryName, category in pairs(inventory) do
            if type(category) == "table"
                and normalize(categoryName) ~= "currency"
                and normalize(categoryName) ~= "currencies"
            then
                for entryKey, entry in pairs(category) do
                    if type(entry) == "table" then
                        local itemName = entry.id
                            or entry._id
                            or entry.ID
                            or entry.Name
                            or entry.name
                            or entryKey
                        addTrackedAmount(totals, itemName, entry)
                    elseif type(entryKey) == "string" then
                        addTrackedAmount(totals, entryKey, entry)
                    end
                end
            end
        end

        return totals
    end

    local function readFarmState()
        if not MapCmds then
            local moduleScript = Client:FindFirstChild("MapCmds")

            if moduleScript then
                local ok, module = pcall(require, moduleScript)

                if ok and type(module) == "table" then
                    MapCmds = module
                end
            end
        end

        if type(MapCmds) ~= "table"
            or type(MapCmds.IsInDottedBox) ~= "function"
        then
            return nil
        end

        local ok, result = pcall(MapCmds.IsInDottedBox)
        return ok and result == true or false
    end

    local frameCount = 0
    local frameWindowStartedAt = os.clock()
    local measuredFps = 0
    local frameConnection = RunService.RenderStepped:Connect(function()
        frameCount += 1
        local elapsed = os.clock() - frameWindowStartedAt

        if elapsed >= 5 then
            measuredFps = frameCount / elapsed
            frameCount = 0
            frameWindowStartedAt = os.clock()
        end
    end)

    local function readPing()
        local network = Stats:FindFirstChild("Network")
        local serverStats = network and network:FindFirstChild("ServerStatsItem")
        local dataPing = serverStats and serverStats:FindFirstChild("Data Ping")

        if not dataPing or type(dataPing.GetValue) ~= "function" then
            return nil
        end

        local ok, value = pcall(dataPing.GetValue, dataPing)
        return ok and tonumber(value) or nil
    end

    local profileFileName = string.format(
        "gem_ledger_%s_%s.json",
        tostring(LocalPlayer and LocalPlayer.UserId or 0),
        tostring(game.PlaceId)
    )
    local persistenceEnabled = readFile ~= nil and writeFile ~= nil
    local today = os.date("!%Y-%m-%d")
    local profile = {
        schema = 1,
        userId = LocalPlayer and LocalPlayer.UserId or 0,
        placeId = game.PlaceId,
        day = today,
        sessions = 1,
        dayStartGems = nil,
        dayStartItems = {},
        lastGems = nil,
        lastItems = {},
        lastSeenAt = 0,
    }

    local function loadProfile()
        if not persistenceEnabled then
            return
        end

        local readOk, encoded = pcall(readFile, profileFileName)

        if not readOk or type(encoded) ~= "string" or encoded == "" then
            return
        end

        local decodeOk, decoded = pcall(
            HttpService.JSONDecode,
            HttpService,
            encoded
        )

        if not decodeOk or type(decoded) ~= "table" then
            return
        end

        local matches = tonumber(decoded.userId) == profile.userId
            and tonumber(decoded.placeId) == profile.placeId

        if not matches then
            return
        end

        profile = decoded
        profile.schema = 1
        profile.sessions = math.max(0, tonumber(profile.sessions) or 0) + 1
        profile.dayStartItems = type(profile.dayStartItems) == "table"
            and profile.dayStartItems
            or {}
        profile.lastItems = type(profile.lastItems) == "table"
            and profile.lastItems
            or {}

        if profile.day ~= today then
            profile.day = today
            profile.dayStartGems = nil
            profile.dayStartItems = {}
            profile.sessions = 1
        end
    end

    local function saveProfile()
        if not persistenceEnabled then
            return false
        end

        profile.schema = 1
        profile.lastSeenAt = os.time()
        profile.ledgerBuild = LEDGER_BUILD
        local encodeOk, encoded = pcall(
            HttpService.JSONEncode,
            HttpService,
            profile
        )

        if not encodeOk then
            return false
        end

        return pcall(writeFile, profileFileName, encoded)
    end

    loadProfile()

    local initialData = nil
    local initialGems = nil
    local startupDeadline = os.clock() + SETTINGS.STARTUP_TIMEOUT

    while not env.STOP_FLEET_PROFIT_LEDGER and os.clock() < startupDeadline do
        initialData = getSaveData()
        initialGems = findGemCount(initialData)

        if initialData and initialGems ~= nil then
            break
        end

        task.wait(2)
    end

    if not initialData or initialGems == nil then
        warn("[Ledger] Save data did not become available; stopping.")
        frameConnection:Disconnect()
        env.__FLEET_PROFIT_LEDGER_RUNNING = false
        return
    end

    local initialItems = scanTrackedItems(initialData)
    local currentGems = initialGems
    local currentItems = initialItems
    local reportStartedAt = os.clock()
    local reportStartGems = initialGems
    local reportStartItems = table.clone(initialItems)
    local reportStagger = SETTINGS.REPORT_STAGGER_MAX > 0
        and (
            (LocalPlayer and LocalPlayer.UserId or 0) % 1000
                / 1000
                * SETTINGS.REPORT_STAGGER_MAX
        )
        or 0
    local nextReportAt = reportStartedAt
        + SETTINGS.REPORT_SECONDS
        + reportStagger
    local lastCheckpointAt = reportStartedAt
    local totalSamples = 0
    local farmSamples = 0
    local unknownFarmSamples = 0
    local minimumFps = nil
    local maximumPing = nil

    if tonumber(profile.dayStartGems) == nil then
        profile.dayStartGems = initialGems
    end

    for _, key in ipairs(trackedOrder) do
        if tonumber(profile.dayStartItems[key]) == nil then
            profile.dayStartItems[key] = initialItems[key] or 0
        end
    end

    profile.lastGems = initialGems
    profile.lastItems = table.clone(initialItems)
    saveProfile()

    local function itemDeltaLines(startItems, endItems, onlyMeaningful)
        local lines = {}

        for _, key in ipairs(trackedOrder) do
            local delta = (tonumber(endItems[key]) or 0)
                - (tonumber(startItems[key]) or 0)

            if not onlyMeaningful or delta ~= 0 then
                table.insert(
                    lines,
                    string.format(
                        "%s: **%s%s**",
                        trackedItems[key],
                        delta >= 0 and "+" or "",
                        formatInteger(delta)
                    )
                )
            end
        end

        return #lines > 0 and table.concat(lines, "\n") or "No tracked changes"
    end

    local function makeReport(now)
        local elapsed = math.max(1, now - reportStartedAt)
        local gemDelta = currentGems - reportStartGems
        local gemsPerHour = gemDelta / elapsed * 3600
        local projectedDay = gemsPerHour * 24
        local dayDelta = currentGems - (tonumber(profile.dayStartGems) or currentGems)
        local knownFarmSamples = math.max(0, totalSamples - unknownFarmSamples)
        local farmUptime = knownFarmSamples > 0
            and farmSamples / knownFarmSamples * 100
            or nil
        local farmUptimeValue = farmUptime or 0
        local farmUptimeText = farmUptime
            and string.format("%.2f%%", farmUptime)
            or "Unavailable"
        local miniKey = normalize("Mini Pinata")
        local pinatasUsed = math.max(
            0,
            (reportStartItems[miniKey] or 0) - (currentItems[miniKey] or 0)
        )
        local valuePerPinata = pinatasUsed > 0 and gemDelta / pinatasUsed or nil
        local status = farmUptime == nil and "Farm detector unavailable"
            or farmUptime >= 95 and "Excellent"
            or farmUptime >= 85 and "Degraded"
            or "Needs attention"
        local reportPing = readPing()
        local description = string.format(
            "💎 **%s net gem movement** in %s\n⚡ **%s/hour** • projected balance movement **%s/day**\n🪅 **%s piñatas used** • %s\n🟢 Farming uptime: **%s** — %s",
            formatSignedCompact(gemDelta),
            formatDuration(elapsed),
            formatCompact(gemsPerHour),
            formatCompact(projectedDay),
            formatInteger(pinatasUsed),
            valuePerPinata and (
                "direct balance "
                    .. formatCompact(valuePerPinata)
                    .. " gems/piñata"
            ) or "direct balance/piñata pending",
            farmUptimeText,
            status
        )
        local fields = {
            webhookField(
                "💎 Gem Position",
                string.format(
                    "Current: **%s** (`%s`)\nWindow: **%s**\nUTC-day net: **%s**\nWindow pace: **%s/hour**",
                    formatCompact(currentGems),
                    formatInteger(currentGems),
                    formatSignedCompact(gemDelta),
                    formatSignedCompact(dayDelta),
                    formatCompact(gemsPerHour)
                ),
                false
            ),
            webhookField(
                "📦 Tracked Inventory — Window",
                itemDeltaLines(reportStartItems, currentItems, true),
                false
            ),
            webhookField(
                "🪅 Piñata Consumption",
                string.format(
                    "Consumed: **%s**\nDirect gem-balance movement per consumed piñata: **%s**\nRemaining: **%s**",
                    formatInteger(pinatasUsed),
                    valuePerPinata and formatCompact(valuePerPinata) or "N/A",
                    formatInteger(currentItems[miniKey] or 0)
                ),
                true
            ),
            webhookField(
                "🖥️ Client Health",
                string.format(
                    "FPS: **%.1f** • Window minimum: **%s**\nPing: **%s ms** • Window maximum: **%s ms**\nSamples: %s • Unknown farm samples: %s",
                    measuredFps,
                    minimumFps and string.format("%.1f", minimumFps) or "N/A",
                    reportPing and string.format("%.0f", reportPing) or "N/A",
                    maximumPing and string.format("%.0f", maximumPing) or "N/A",
                    formatInteger(totalSamples),
                    formatInteger(unknownFarmSamples)
                ),
                false
            ),
            webhookField(
                "🧭 Farming",
                string.format(
                    "Farming samples: **%s/%s**\nObserved uptime: **%s**",
                    formatInteger(farmSamples),
                    formatInteger(totalSamples),
                    farmUptimeText
                ),
                true
            ),
            webhookField(
                "💾 Continuity",
                string.format(
                    "UTC day: **%s**\nSessions today: **%s**\nPersistent checkpoint: **%s**",
                    tostring(profile.day),
                    formatInteger(profile.sessions),
                    persistenceEnabled and "available" or "session only"
                ),
                true
            ),
        }

        enqueueWebhook(
            "Fleet Profit Ledger • 35-Minute Report",
            description,
            fields,
            farmUptime == nil and 3447003
                or farmUptimeValue >= 95 and 5763719
                or farmUptimeValue >= 85 and 16753920
                or 15548997
        )

        reportStartedAt = now
        reportStartGems = currentGems
        reportStartItems = table.clone(currentItems)
        totalSamples = 0
        farmSamples = 0
        unknownFarmSamples = 0
        minimumFps = nil
        maximumPing = nil
        nextReportAt = now + SETTINGS.REPORT_SECONDS
    end

    local function rollUtcDayIfNeeded()
        local currentDay = os.date("!%Y-%m-%d")

        if profile.day == currentDay then
            return
        end

        profile.day = currentDay
        profile.sessions = 1
        profile.dayStartGems = currentGems
        profile.dayStartItems = table.clone(currentItems)
        saveProfile()
    end

    print(string.format(
        "[Ledger] %s started | role %s | report %.0fm | tracked items %d",
        LEDGER_BUILD,
        SETTINGS.ROLE,
        SETTINGS.REPORT_SECONDS / 60,
        #trackedOrder
    ))

    while not env.STOP_FLEET_PROFIT_LEDGER do
        local cycleStartedAt = os.clock()
        local data = getSaveData()

        if data then
            local gems = findGemCount(data)

            if gems ~= nil then
                currentGems = gems
            end

            currentItems = scanTrackedItems(data)
        end

        local farmState = readFarmState()
        totalSamples += 1

        if farmState == true then
            farmSamples += 1
        elseif farmState == nil then
            unknownFarmSamples += 1
        end

        if measuredFps > 0 then
            minimumFps = minimumFps and math.min(minimumFps, measuredFps)
                or measuredFps
        end

        local ping = readPing()

        if ping then
            maximumPing = maximumPing and math.max(maximumPing, ping) or ping
        end

        env.GLEDGER_LIVE_SNAPSHOT = {
            build = LEDGER_BUILD,
            account = LocalPlayer and LocalPlayer.Name or "Unknown",
            role = SETTINGS.ROLE,
            zone = SETTINGS.TARGET_ZONE,
            gems = currentGems,
            items = table.clone(currentItems),
            fps = measuredFps,
            ping = ping,
            farming = farmState,
            runtime = os.clock() - startedAt,
            updatedAt = os.time(),
        }

        local now = os.clock()
        rollUtcDayIfNeeded()

        if now - lastCheckpointAt >= SETTINGS.CHECKPOINT_SECONDS then
            profile.lastGems = currentGems
            profile.lastItems = table.clone(currentItems)
            saveProfile()
            lastCheckpointAt = now
        end

        if now >= nextReportAt then
            makeReport(now)
            profile.lastGems = currentGems
            profile.lastItems = table.clone(currentItems)
            saveProfile()
        end

        local remaining = SETTINGS.SAMPLE_SECONDS - (os.clock() - cycleStartedAt)

        if remaining > 0 then
            task.wait(remaining)
        else
            task.wait()
        end
    end

    profile.lastGems = currentGems
    profile.lastItems = table.clone(currentItems)
    saveProfile()
    frameConnection:Disconnect()
    env.GLEDGER_LIVE_SNAPSHOT = nil
    env.__FLEET_PROFIT_LEDGER_RUNNING = false
    print("[Ledger] Stopped cleanly.")
end)
