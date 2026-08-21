--============================================================-- HYDRA ROUTER | hydra1.2.1
-- Six-account autoexec, fully GScript-free. ROLES:
--   1-4 farmers : perf stack + zonekeeper-1.4 + hyperflow-2.5.4 +
--                 ZapHub Exec + mailer (->ACCOUNT_5_NAME; snipers never mail)
--   5   ACCOUNT_5_NAME   : TERMINAL-GUIDED sniper (fps 5)
--   6   ACCOUNT_6_NAME   : TERMINAL-GUIDED sniper (fps 5; no mailer)
--
-- SNIPER FLOW (hydra1.2.1): ZapHub serverhop rotates through trading
-- plazas; every 30s our terminal layer invokes TradingTerminal_Search
-- (probe-proven, no token) for LGB + GB; a cross-server listing gets
-- OUR TeleportToPlaceInstance straight to the seller's server; ZapHub
-- buys under ceilings on arrival; rotation continues. Ping-pong guard
-- (th_state_<uid>.json) blocks re-teleporting to a job left <10min ago.
--
-- VERSIONING: file name tracks the build; each change = new versioned
-- file, old replaced + archived to temp\opencode.
--
-- CHANGELOG (condensed; full saga in temp archives):
--   1.0.x  GScript era -> key expired; zonekeeper built & graduated
--          (Teleports_RequestTeleport by zone name + BREAK_ZONE center);
--          throughput gate; ZapHub migration; ACCOUNT_5_NAME seller; ACCOUNT_6_NAME sniper
--   1.1.0  perf stack fleet-wide; dead GScript vars removed
--   1.1.1  sniper ceilings LGB 6700 / GB 1500; pinata lane dropped
--   1.1.2  zonekeeper-1.4 anti-honeypot (per-call remote re-resolution)
--          pairs with hyperflow-2.5.4 (consume tripwire, repo)
--   1.1.4/5 hop-governor attempt vs ZapHub bypass � retired; memory
--          fallbacks only (guard 11GB -> reverted 9GB after issues)
--   1.1.6/8 own-serverhop session stack; queueonteleport removed
--          (autoexec rebirth is the single runner)
--   1.1.9/1.2.0  own hopper @15s; official restore; test-era parked
--   1.2.1  TERMINAL-GUIDED SNIPING (both snipers): ZapHub serverhop ON,
--          our TradingTerminal_Search layer + direct teleport to
--          listings; blind hopper deleted; router header condensed
--============================================================
local HYDRA_BUILD = "hydra-sellmode"

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local player = Players.LocalPlayer

while not player do
    task.wait()
    player = Players.LocalPlayer
end

local env = getgenv()
local username = string.lower(player.Name)
local sessionKey = "HydraRouter_" .. HYDRA_BUILD .. "_" .. tostring(player.UserId)

if env[sessionKey] then
    warn("[Hydra] AutoExec already ran for " .. player.Name)
    return
end

env[sessionKey] = true

local ACCOUNT_1 = string.lower("ACCOUNT_1_NAME")
local ACCOUNT_2 = string.lower("ACCOUNT_2_NAME")
local ACCOUNT_3 = string.lower("ACCOUNT_3_NAME")
local ACCOUNT_4 = string.lower("ACCOUNT_4_NAME")
local ACCOUNT_5 = string.lower("ACCOUNT_5_NAME")
local ACCOUNT_6 = string.lower("ACCOUNT_6_NAME")

-- ZapHub key (shared, validated multi-seat 2026-08-19)
local ZAPHUB_KEY = "PASTE_YOUR_ZAPHUB_KEY_HERE"

local FLEET_WEBHOOK = "PASTE_YOUR_FLEET_WEBHOOK_HERE"

local PINATA_ENGINE_URL =
    "https://raw.githubusercontent.com/vaporcadillac/client-runtime-a91e6f4c/main/module_exp_5a.lua"

--============================================================ perf stack (restored 1.1.0)

local function setFpsCap(fps)
    if type(setfpscap) == "function" then
        local ok, fpsError = pcall(setfpscap, fps)
        if not ok then
            warn("[Hydra] FPS cap failed: " .. tostring(fpsError))
        end
    end
end

local function applyPerformanceFlags()
    if type(setfflag) ~= "function" then
        warn("[Hydra] setfflag unavailable; skipping FFlags.")
        return
    end

    local flags = {
        DFIntDebugFRMQualityLevelOverride = "1",
        FFlagDisablePostFx = "True",
        DFFlagDebugPauseVoxelizer = "True",
        FFlagDebugSkyGray = "True",
        DFIntTextureCompositorActiveJobs = "12",
        FFlagDebugDisableTelemetryEphemeralCounter = "True",
        FFlagDebugDisableTelemetryPoints = "True",
        FFlagDebugDisableTelemetryV2Counter = "True",
    }

    local applied = 0

    for name, value in pairs(flags) do
        if pcall(setfflag, name, value) then
            applied += 1
        end
    end

    print(string.format("[Hydra] Performance FFlags applied: %d/%d", applied, 8))

    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level1
    end)

    pcall(function()
        local Lighting = game:GetService("Lighting")
        Lighting.GlobalShadows = false
        Lighting.ShadowSoftness = 0
        Lighting.FogEnd = 1
    end)
end

local function applyStreamingCap()
    pcall(function()
        local radius = tonumber(env.GSTREAMING_RADIUS) or 64
        workspace.StreamingTargetRadius = radius
        workspace.StreamingMinRadius = math.min(16, radius)
        workspace.StreamingRequestQueueSize = 8
    end)
end

local function startAudioKill()
    task.spawn(function()
        if not game:IsLoaded() then
            game.Loaded:Wait()
        end

        local SoundService = game:GetService("SoundService")

        local function mute(descendant)
            if descendant:IsA("Sound") then
                pcall(function()
                    descendant.Volume = 0
                end)
            end
        end

        for _, sound in ipairs(SoundService:GetDescendants()) do
            mute(sound)
        end

        SoundService.DescendantAdded:Connect(mute)
        workspace.DescendantAdded:Connect(mute)

        while true do
            task.wait(300)

            for _, service in ipairs({ workspace, SoundService }) do
                for _, sound in ipairs(service:GetDescendants()) do
                    mute(sound)
                end
            end
        end
    end)
end

local function startRenderFlush()
    task.spawn(function()
        if not game:IsLoaded() then
            game.Loaded:Wait()
        end

        task.wait(120)

        while true do
            task.wait(2 * 60 * 60)

            pcall(function()
                settings().Rendering.QualityLevel = Enum.QualityLevel.Level21
                task.wait(0.5)
                settings().Rendering.QualityLevel = Enum.QualityLevel.Level1
            end)

            print("[Hydra] Render flush complete.")
        end
    end)
end

local function startVoidCamera()
    task.spawn(function()
        if not game:IsLoaded() then
            game.Loaded:Wait()
        end

        local voidCFrame = CFrame.new(0, 5000, 0)

        while true do
            pcall(function()
                local camera = workspace.CurrentCamera

                if camera then
                    camera.CFrame = voidCFrame
                    camera.FieldOfView = 1
                end
            end)

            task.wait(5)
        end
    end)
end

local function startConsoleSpamFilter()
    local dropPatterns = {
        "^%s*priority on",
        "^%s*Pinata%s*$",
        "%[LAZY%]",
        "^%s*true%s*$",
    }

    local rawPrint = print

    getgenv().print = function(...)
        local first = select(1, ...)
        local message = type(first) == "string" and first or ""

        for _, pattern in ipairs(dropPatterns) do
            if string.find(message, pattern) then
                return
            end
        end

        return rawPrint(...)
    end

    print("[Hydra] Console spam filter active.")
end

local function startAntiAfk()
    pcall(function()
        local VirtualUser = game:GetService("VirtualUser")
        player.Idled:Connect(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end)
end

local function applyFullPerfStack(fps)
    setFpsCap(fps)
    applyPerformanceFlags()
    startVoidCamera()
    startRenderFlush()
    startAudioKill()
    applyStreamingCap()
    startConsoleSpamFilter()
    startAntiAfk()
end

--============================================================ shared loaders

local function downloadWithRetry(baseUrl, attempts, cacheBust)
    local lastError = "unknown download error"
    local sessionId = tostring(os.time())

    for attempt = 1, attempts do
        local requestUrl = baseUrl

        if cacheBust then
            local separator = string.find(baseUrl, "?", 1, true) and "&" or "?"
            requestUrl = baseUrl
                .. separator
                .. "session="
                .. sessionId
                .. "&attempt="
                .. tostring(attempt)
        end

        local ok, result = pcall(function()
            return game:HttpGet(requestUrl)
        end)

        if ok and type(result) == "string" and #result > 0 then
            return result
        end

        lastError = tostring(result)

        if attempt < attempts then
            task.wait(math.min(30, attempt * 5))
        end
    end

    return nil, lastError
end

--============================================================ zonekeeper-1.3
-- GScript GZONE_TO replacement. Generic per zone:
--   1. zone name resolved live from workspace.Map
--   2. Teleports_RequestTeleport:InvokeServer(zoneName) — real game
--      traffic (zonespy-5.0 ground truth, 2026-08-19)
--   3. BREAK_ZONE center CFrame = farming middle
-- Keep-mode (displacement-only) + respawn chain + anti-AFK + logging.

local function startZoneKeeper()
    if env.GZONEKEEPER_ENABLED == false then
        return
    end

    task.spawn(function()
        if not game:IsLoaded() then
            game.Loaded:Wait()
        end

        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local HttpService = game:GetService("HttpService")

        local LocalPlayer = Players.LocalPlayer

        while not LocalPlayer do
            task.wait()
            LocalPlayer = Players.LocalPlayer
        end

        local targetZone = tonumber(env.GZONEKEEPER_ZONE)

        if not targetZone then
            warn("[ZoneKeeper] GZONEKEEPER_ZONE not set; zonekeeper idle.")
            return
        end

        local pollSeconds = tonumber(env.GZONEKEEPER_POLL) or 2
        local gracePolls = tonumber(env.GZONEKEEPER_GRACE) or 3
        local settleSeconds = tonumber(env.GZONEKEEPER_SETTLE) or 3
        local yOffset = tonumber(env.GZONEKEEPER_Y_OFFSET) or 5
        local streamTimeout = tonumber(env.GZONEKEEPER_STREAM_TIMEOUT) or 90
        local keepMode = env.GZONEKEEPER_KEEP_MODE ~= false

        local function resolveExecutorFunction(name)
            local candidate = rawget(env, name) or rawget(_G, name)
            return type(candidate) == "function" and candidate or nil
        end

        local writeFileFn = resolveExecutorFunction("writefile")
        local appendLog = resolveExecutorFunction("appendfile")
        local requestFn = resolveExecutorFunction("request")
            or resolveExecutorFunction("http_request")

        local logName = string.format("zk_log_%s.txt", tostring(LocalPlayer.UserId))

        local function log(message)
            local line = string.format("[%s] %s\n", os.date("%H:%M:%S"), message)
            print("[ZoneKeeper] " .. message)

            if writeFileFn then
                pcall(function()
                    if appendLog then
                        appendLog(logName, line)
                    else
                        local ok, existing = pcall(readfile, logName)
                        writeFileFn(logName, (ok and existing or "") .. line)
                    end
                end)
            end
        end

        local function notify(title, description, color)
            if not FLEET_WEBHOOK or not requestFn then
                return
            end

            local payload = {
                username = "ZoneKeeper - " .. LocalPlayer.Name,
                embeds = {{
                    title = title,
                    description = description,
                    color = color or 2326507,
                }},
            }

            task.spawn(function()
                pcall(requestFn, {
                    Url = FLEET_WEBHOOK,
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode(payload),
                })
            end)
        end

        pcall(function()
            local VirtualUser = game:GetService("VirtualUser")
            LocalPlayer.Idled:Connect(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
        end)

        local Library = ReplicatedStorage:WaitForChild("Library", 30)
        local Client = Library and Library:WaitForChild("Client", 30)

        if not Client then
            log("FATAL: Library.Client unavailable.")
            notify("ZoneKeeper Fatal", "Library.Client not found.", 16711680)
            return
        end

        local MapCmds
        do
            local ok, mod = pcall(require, Client:WaitForChild("MapCmds", 10))
            if ok then MapCmds = mod end
        end

        if not MapCmds or type(MapCmds.IsInDottedBox) ~= "function" then
            log("FATAL: MapCmds unavailable.")
            notify("ZoneKeeper Fatal", "MapCmds unavailable.", 16711680)
            return
        end

        local Network = ReplicatedStorage:WaitForChild("Network", 30)
        local RequestTeleport = Network and Network:WaitForChild("Teleports_RequestTeleport", 10)

        if not RequestTeleport then
            log("FATAL: Teleports_RequestTeleport remote not found.")
            notify("ZoneKeeper Fatal", "Teleports_RequestTeleport missing.", 16711680)
            return
        end

        local function isInFarmArea()
            local ok, result = pcall(MapCmds.IsInDottedBox)
            return ok and result == true
        end

        local function getRoot()
            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local root = character and character:FindFirstChild("HumanoidRootPart")

            if not humanoid or humanoid.Health <= 0 or not root then
                return nil
            end

            return root
        end

        local function fmtPos(v)
            return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
        end

        local function resolveZoneName()
            local mapFolder = workspace:FindFirstChild("Map")

            if not mapFolder then
                return nil
            end

            local prefix = tostring(targetZone) .. " | "

            for _, child in ipairs(mapFolder:GetChildren()) do
                if string.sub(child.Name, 1, #prefix) == prefix then
                    return string.sub(child.Name, #prefix + 1)
                end
            end

            return nil
        end

        local function resolveBreakZoneCenter()
            local mapFolder = workspace:FindFirstChild("Map")

            if not mapFolder then
                return nil
            end

            local prefix = tostring(targetZone) .. " | "

            for _, zoneFolder in ipairs(mapFolder:GetChildren()) do
                if string.sub(zoneFolder.Name, 1, #prefix) == prefix then
                    local interact = zoneFolder:FindFirstChild("INTERACT")

                    if not interact then
                        return nil
                    end

                    local breakZones = interact:FindFirstChild("BREAK_ZONES")

                    if not breakZones then
                        return nil
                    end

                    local bestPart, bestVolume = nil, -1

                    for _, part in ipairs(breakZones:GetChildren()) do
                        if part:IsA("BasePart") then
                            local size = part.Size
                            local volume = size.X * size.Y * size.Z

                            if volume > bestVolume then
                                bestVolume = volume
                                bestPart = part
                            end
                        end
                    end

                    return bestPart and bestPart.Position or nil
                end
            end

            return nil
        end

        local function positionIntoZone(reason)
            log(reason .. ": positioning chain start.")

            if isInFarmArea() then
                log(reason .. ": already inside farm area; no travel needed.")
                return true
            end

            local zoneName = resolveZoneName()

            if zoneName then
                log(string.format("%s: travel remote -> %q.", reason, zoneName))

                -- zonekeeper-1.4: re-resolve by name at every call; never
                -- invoke a cached instance (anti-honeypot, see hyperflow
                -- -2.5.4). Rotation to a renamed remote is picked up here.
                local travelRemote = Network:FindFirstChild("Teleports_RequestTeleport")
                    or Network:WaitForChild("Teleports_RequestTeleport", 10)

                if not travelRemote or not travelRemote:IsA("RemoteFunction") then
                    log(reason .. ": travel remote missing/renamed; failing.")
                    notify(
                        "ZoneKeeper Travel Remote Missing",
                        string.format(
                            "**%s** — Teleports_RequestTeleport not found or wrong class at call time (possible rotation/honeypot). Positioning aborted this cycle.",
                            LocalPlayer.Name
                        ),
                        16753920
                    )
                    return false
                end

                if travelRemote ~= RequestTeleport then
                    log(reason .. ": travel remote instance CHANGED since boot — rotation suspected, using fresh instance.")
                end

                local ok, res = pcall(function()
                    return travelRemote:InvokeServer(zoneName)
                end)

                log(string.format("%s: travel returned ok=%s res=%s.",
                    reason, tostring(ok), tostring(res)))

                local deadline = os.clock() + 20

                while os.clock() < deadline do
                    task.wait(1)
                    local root = getRoot()

                    if root then
                        local mapFolder = workspace:FindFirstChild("Map")
                        local prefix = tostring(targetZone) .. " | "

                        if mapFolder and mapFolder:FindFirstChild(prefix .. zoneName) then
                            break
                        end
                    end
                end
            else
                log(reason .. ": could not resolve zone name; CFrame-only attempt.")
            end

            log(string.format("%s: waiting for BREAK_ZONE geometry (up to %ds)...",
                reason, streamTimeout))

            local deadline = os.clock() + streamTimeout
            local center = nil

            while os.clock() < deadline do
                center = resolveBreakZoneCenter()

                if center then
                    break
                end

                task.wait(3)
            end

            if not center then
                log(reason .. ": BREAK_ZONE never streamed in; failing.")
                return false
            end

            log(string.format("%s: BREAK_ZONE center %s.", reason, fmtPos(center)))

            local root = getRoot()

            if not root then
                log(reason .. ": no character root; failing.")
                return false
            end

            root.CFrame = CFrame.new(center + Vector3.new(0, yOffset, 0))
            task.wait(2)

            local inside = isInFarmArea()
            log(string.format("%s: after center teleport inside=%s.", reason, tostring(inside)))

            return inside
        end

        log(string.format("zonekeeper-1.3 start | zone %d | remote travel + BREAK_ZONE center",
            targetZone))

        task.wait(settleSeconds)

        local positioned = positionIntoZone("Boot")

        local anchor = resolveBreakZoneCenter()

        if not anchor then
            local root = getRoot()

            if root and isInFarmArea() then
                anchor = root.Position
            end
        end

        if writeFileFn and anchor then
            pcall(writeFileFn, string.format(
                "zonekeeper_%s_%s_%s.json",
                tostring(LocalPlayer.UserId),
                tostring(game.PlaceId),
                tostring(targetZone)
            ), HttpService:JSONEncode({
                schema = 4,
                engine = "zonekeeper-1.3",
                userId = LocalPlayer.UserId,
                placeId = game.PlaceId,
                placeVersion = game.PlaceVersion,
                zone = targetZone,
                zoneName = resolveZoneName(),
                position = { x = anchor.X, y = anchor.Y, z = anchor.Z },
                positioned = positioned,
                at = os.time(),
            }))
        end

        notify(
            positioned and "ZoneKeeper Positioned" or "ZoneKeeper Position Issues",
            string.format(
                "**%s** — zone %d | inside: %s | anchor %s",
                LocalPlayer.Name,
                targetZone,
                tostring(positioned),
                anchor and fmtPos(anchor) or "none"
            ),
            positioned and 2326507 or 16753920
        )

        LocalPlayer.CharacterAdded:Connect(function(character)
            task.delay(settleSeconds, function()
                local root = character:FindFirstChild("HumanoidRootPart")
                    or character:WaitForChild("HumanoidRootPart", 10)

                if root and not isInFarmArea() then
                    positionIntoZone("Spawn")
                end
            end)
        end)

        log("Keep-mode " .. (keepMode and "active." or "DISABLED (boot/respawn positioning only)."))

        if not keepMode then
            return
        end

        local outsidePolls = 0
        local teleportsThisSession = 0

        while true do
            task.wait(pollSeconds)

            local root = getRoot()

            if root then
                if isInFarmArea() then
                    outsidePolls = 0
                else
                    outsidePolls += 1

                    if outsidePolls >= gracePolls then
                        outsidePolls = 0
                        teleportsThisSession += 1

                        local done = false
                        local keepCenter = resolveBreakZoneCenter()

                        if keepCenter then
                            root.CFrame = CFrame.new(keepCenter + Vector3.new(0, yOffset, 0))
                            done = true
                            log(string.format("Return #%d: CFrame to center %s.",
                                teleportsThisSession, fmtPos(keepCenter)))
                        end

                        if not done then
                            positionIntoZone("KeepFallback")
                        end

                        if teleportsThisSession == 5
                            or teleportsThisSession % 25 == 0
                        then
                            notify(
                                "ZoneKeeper Return Teleports",
                                string.format(
                                    "**%s** — %d return teleports this session (zone %d).",
                                    LocalPlayer.Name,
                                    teleportsThisSession,
                                    targetZone
                                ),
                                16753920
                            )
                        end
                    end
                end
            else
                outsidePolls = 0
            end
        end
    end)
end

--============================================================ hyperflow engine settings

local function applyPinataEngineSettings()
    env.GEVENT_ITEMS_TO_USE = {}

    env.GPINATA_ENABLED = true
    env.GTELEMETRY_ENABLED = true
    env.GTELEMETRY_ENDPOINT = "https://runtime-status-a91e6f4c.swept6510.workers.dev/api/telemetry"
    env.GTELEMETRY_WRITE_KEY = "PASTE_YOUR_TELEMETRY_KEY_HERE"
    env.GTELEMETRY_INTERVAL_SECONDS = 25

    env.GPINATA_INTERVAL = 5.5
    env.GPINATA_ADAPTIVE = true
    env.GPINATA_ADAPTIVE_MIN_INTERVAL = 5.5
    env.GPINATA_ADAPTIVE_MAX_INTERVAL = 7.0
    env.GPINATA_ADAPTIVE_WINDOW = 20
    env.GPINATA_ADAPTIVE_STEP_DOWN = 0.05
    env.GPINATA_ADAPTIVE_HIGH_REJECT_RATE = 0.25
    env.GPINATA_ADAPTIVE_PRESSURE_WINDOWS = 2
    env.GPINATA_ADAPTIVE_PRESSURE_STEP = 0.10

    -- THROUGHPUT GATE (engine-dive 2026-08-19): 2-4% reject rate with
    -- retry costs less time than the margin above floor. ~+6% expected.
    env.GPINATA_CALIBRATION_MAX_REJECT_RATE = 0.05
    env.GPINATA_ADAPTIVE_PROBE_RETREAT_RATE = 0.06

    env.GPINATA_CONFIRM_WAIT = 1.5
    env.GPINATA_MAX_RETRIES = 2
    env.GPINATA_REMOTE_TIMEOUT = 8.0
    env.GPINATA_WATCHDOG_TIMEOUT = 45

    env.GPINATA_STARTUP_WAIT = 60
    env.GPINATA_STABLE_WAIT = 20
    env.GPINATA_FARM_WAIT_TIMEOUT = 600

    env.GPINATA_FPS = 5
    env.GPINATA_STAGGER = true

    env.GPINATA_STATUS_EVERY = 100
    env.GPINATA_VERBOSE = false

    env.GPINATA_WEBHOOK_ENABLED = true
    env.GPINATA_WEBHOOK_URL = FLEET_WEBHOOK
    env.GPINATA_WEBHOOK_ALERT_REJECT_STREAK = 3
    env.GPINATA_WEBHOOK_MENTION_ON_CRITICAL = false
    env.GPINATA_WEBHOOK_QUEUE_LIMIT = 30

    env.GPINATA_RESTART_DELAY = 15
    env.GPINATA_RESTART_DELAY_MAX = 300
end

local function startPinataEngine()
    task.spawn(function()
        local source, downloadError = downloadWithRetry(PINATA_ENGINE_URL, 10, true)

        if not source then
            warn("[PinataLoader] Download failed: " .. tostring(downloadError))
            return
        end

        local chunk, compileError = loadstring(source)

        if not chunk then
            warn("[PinataLoader] Compile failed: " .. tostring(compileError))
            return
        end

        local ok, runtimeError = pcall(chunk)

        if not ok then
            warn("[PinataLoader] Startup failed: " .. tostring(runtimeError))
        end
    end)
end

--============================================================ ZapHub: mailer + automin

local function startZapHubMailer()
    if env.GZAPMAILER_ENABLED == false then
        return
    end

    _G.ZapHubMailerSettings = {
        Users = { "ACCOUNT_5_NAME" },
        Items = {
            -- gems: mail over 500m, keep 5m on the account
            {
                Class = "Currency",
                Item = "Diamonds",
                MinimumAmount = 1000000000,
                AmountToKeep = 5000000,
            },
            -- charm stones: mail at 10k+, keep none
            {
                Class = "Misc",
                Item = "Charm Stone",
                MinimumAmount = 10000,
                AmountToKeep = 0,
            },
            -- crystal keys: mail at 10k+, keep none
            {
                Class = "Misc",
                Item = "Crystal Key",
                MinimumAmount = 10000,
                AmountToKeep = 0,
            },
        },
        Extras = {},
        CustomExtras = {},
        OnlyOnline = false,
        Webhook = {
            Enabled = true,
            WebhookURL = FLEET_WEBHOOK,
        },
    }

    task.spawn(function()
        if not game:IsLoaded() then
            game.Loaded:Wait()
        end

        task.wait(tonumber(env.GZAPMAILER_DELAY) or 60)

        script_key = ZAPHUB_KEY
        loadstring(game:HttpGet("https://zaphub.xyz/ExecMailer"))()

        print("[Hydra] ZapHub mailer loaded (receiver: ACCOUNT_5_NAME).")
    end)
end

-- one-shot per boot: flip ZapLib.BackgroundGUI 5s after it appears,
-- then never touch the gui again (manual opens are never re-minimized)
local function startZapHubAutoMinimize()
    if env.GZAPHUB_AUTOMIN == false then
        return
    end

    task.spawn(function()
        local hui = (typeof(gethui) == "function" and gethui())
            or game:GetService("CoreGui")

        local deadline = os.clock() + 300

        while os.clock() < deadline do
            local zapLib = hui:FindFirstChild("ZapLib", true)

            if zapLib and zapLib:IsA("ScreenGui") then
                local bg = zapLib:FindFirstChild("BackgroundGUI")

                if bg and bg:IsA("GuiObject") then
                    task.wait(5)

                    if bg.Visible then
                        bg.Visible = false
                        print("[Hydra] ZapHub gui auto-minimized.")
                    end

                    return
                end
            end

            task.wait(2)
        end

        warn("[Hydra] ZapLib never appeared; auto-minimize skipped.")
    end)
end

local function startZapHub()
    task.spawn(function()
        if not game:IsLoaded() then
            game.Loaded:Wait()
        end

        task.wait(tonumber(env.GZAPHUB_DELAY) or 30)

        script_key = ZAPHUB_KEY
        loadstring(game:HttpGet("https://zaphub.xyz/Exec"))()

        print("[Hydra] ZapHub loaded.")
    end)
end

--============================================================ farmer template (1-4)

local function applyFarmerConfig(zoneTo)
    applyFullPerfStack(10)

    env.GZONEKEEPER_ENABLED = true
    env.GZONEKEEPER_ZONE = zoneTo

    env.GWEBHOOK_USERID = "PASTE_YOUR_DISCORD_USER_ID_HERE"
    env.GWEBHOOK_LINK = FLEET_WEBHOOK

    applyPinataEngineSettings()
    startZoneKeeper()
    startPinataEngine()
    startZapHub()
    startZapHubAutoMinimize()
    startZapHubMailer()
end

--============================================================ ACCOUNT 1 (zone 44)

local function runAccount1()
    applyFarmerConfig(44)
end

--============================================================ ACCOUNT 2 (zone 39)

local function runAccount2()
    applyFarmerConfig(39)
end

--============================================================ ACCOUNT 3 (zone 32)

local function runAccount3()
    applyFarmerConfig(32)
end

--============================================================ ACCOUNT 4 (ACCOUNT_4_NAME: zone 26, floor probe)

local function runAccount4()
    env.GPINATA_TARGET_INTERVAL = 5.5
    applyFarmerConfig(26)
end

--============================================================ sniper session (hydra1.2.1, terminal-guided)
-- Hydra writes the session file once per boot and runs it; the Volt
-- autoexec re-births it on every server join (single runner, no
-- queueonteleport — 1.1.8 lesson). Session = ZapHub sniper (its
-- serverhop owns plaza rotation) + our terminal layer (search every
-- 30s, teleport to cross-server listings, ping-pong guarded).

local SNIPER_SESSION_FILE = "hydra_sniper_session.luau"
local SNIPER_WEBHOOK = "PASTE_YOUR_SNIPER_WEBHOOK_HERE"

local function sniperSessionSource()
    return [==[
-- hydra sniper session (generated by hydra1.2.1) � terminal-guided
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SEARCH_INTERVAL = 180 -- terminal dwell: seconds per server visit
local PINATA_MAX_PRICE = 35000 -- <<< SNIPER TUNE: pinata buy ceiling (edit here)
local ZAP_KEY = "PASTE_YOUR_ZAPHUB_KEY_HERE"
local WEBHOOK = "PASTE_YOUR_SNIPER_WEBHOOK_HERE"

if not game:IsLoaded() then game.Loaded:Wait() end

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do task.wait() LocalPlayer = Players.LocalPlayer end

local logFile = string.format("th_log_%s.txt", tostring(LocalPlayer.UserId))
local stateFile = string.format("th_state_%s.json", tostring(LocalPlayer.UserId))

local function log(msg)
    print("[HydraSession] " .. msg)
    pcall(function()
        if isfile and isfile(logFile) then appendfile(logFile, msg .. "\n")
        else writefile(logFile, msg .. "\n") end
    end)
end

-- anti-AFK
pcall(function()
    LocalPlayer.Idled:Connect(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

-- ZapHub sniper: serverhop OFF (hydra1.2.4) - OUR terminal layer owns ALL movement; ZapHub only scans the current server + buys. Idle: parked between strikes (search is global; first listing anywhere triggers the next hop).
_G.ZapHubBoothsSniperSettings = {
    MinimumGems = 0,
    Items = {
        {Class = "Misc", Item = "Exclusive Raffle Ticket", MaxPrice = 15000000, MaxInInventory = 999999},
        {Class = "Misc", Item = "Large Gift Bag", MaxPrice = 6700, MaxInInventory = 999999},
        {Class = "Misc", Item = "Gift Bag", MaxPrice = 1500, MaxInInventory = 999999},
        {Class = "Misc", Item = "Pinata", MaxPrice = PINATA_MAX_PRICE, MaxInInventory = 999999},
    },
    Extras = {},
    CustomExtras = {},
    ServerHop = { Enabled = false, Type = "Both" },
    Webhook = { Enabled = true, WebhookURL = WEBHOOK },
}

local lastSellerInfo = nil -- hydra1.2.6: seller context for purchase attribution
local rawRequest = nil     -- hydra1.2.8: unwrapped request for attribution posts

-- hydra1.2.5: REQUEST TAP � wrap the executor's request function
-- BEFORE ZapHub loads. Every webhook payload ZapHub posts (their buy
-- alerts) passes through here and is logged verbatim for purchase
-- attribution. Pass-through wrapper: nothing is modified or blocked.
do
    local originalRequest = (typeof(request) == "function" and request)
        or (typeof(getgenv().request) == "function" and getgenv().request)

    if originalRequest then
        rawRequest = originalRequest

        local function tappedRequest(options)
            pcall(function()
                if type(options) == "table"
                    and type(options.Url) == "string"
                    and string.find(options.Url, "discord.com/api/webhooks", 1, true)
                then
                    local body = tostring(options.Body or "")
                    log("[ZAP-WEBHOOK] " .. body)

                    -- hydra1.2.6: ZapHub buy alert detected -> post our
                    -- seller attribution follow-up (skip our own posts)
                    if not string.find(body, "Purchase Attribution", 1, true) then
                        task.spawn(function()
                            pcall(function()
                                originalRequest({
                                    Url = WEBHOOK,
                                    Method = "POST",
                                    Headers = { ["Content-Type"] = "application/json" },
                                    Body = HttpService:JSONEncode({
                                        username = "Purchase Attribution - " .. LocalPlayer.Name,
                                        embeds = {{
                                            title = "Bought from: " .. (lastSellerInfo or "unknown seller"),
                                            color = 2326507,
                                        }},
                                    }),
                                })
                            end)
                        end)
                    end
                end
            end)

            return originalRequest(options)
        end

        -- hydra1.2.7: wrap EVERY request alias � ZapHub posted through
        -- one we missed (zero captures on 1.2.6), same bypass pattern
        -- as their teleports. Cover the full sUNC surface.
        pcall(function() getgenv().request = tappedRequest end)
        pcall(function() _G.request = tappedRequest end)
        pcall(function() getgenv().http_request = tappedRequest end)
        pcall(function()
            if type(getgenv().syn) == "table" and type(getgenv().syn.request) == "function" then
                getgenv().syn.request = tappedRequest
            elseif type(syn) == "table" and type(syn.request) == "function" then
                syn.request = tappedRequest
            end
        end)
        pcall(function()
            if type(http) == "table" and type(http.request) == "function" then
                http.request = tappedRequest
            end
        end)
        log("request tap armed on all aliases (request/syn.request/http_request/http.request).")
    else
        log("request unavailable; webhook tap disabled.")
    end
end

task.delay(15, function()
    script_key = ZAP_KEY
    loadstring(game:HttpGet("https://zaphub.xyz/ExecBoothSniper"))()
    log("sniper loaded (ZapHub serverhop on).")
end)

-- auto-minimize (one-shot)
task.spawn(function()
    local hui = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    local deadline = os.clock() + 300
    while os.clock() < deadline do
        local zapLib = hui:FindFirstChild("ZapLib", true)
        if zapLib and zapLib:IsA("ScreenGui") then
            local bg = zapLib:FindFirstChild("BackgroundGUI")
            if bg then
                task.wait(5)
                if bg.Visible then bg.Visible = false end
                return
            end
        end
        task.wait(2)
    end
end)

-- TERMINAL-HOP LAYER (hydra1.2.1): search both items from ANY server
-- (remote probe-proven 2026-08-20); cross-server listing -> OUR
-- teleport straight to it; ZapHub buys on arrival; ZapHub's serverhop
-- keeps rotating. Ping-pong guard: never teleport back to a job we
-- just left within 10 min (overpriced-listing loop protection).
task.spawn(function()
    local Network = ReplicatedStorage:WaitForChild("Network", 30)
    local SearchRemote = Network and Network:WaitForChild("TradingTerminal_Search", 10)

    if not SearchRemote then
        log("TradingTerminal_Search missing; terminal layer idle this server.")
        return
    end

    local function readSkip()
        local ok, raw = pcall(function() return readfile(stateFile) end)
        if not ok or type(raw) ~= "string" or raw == "" then return nil end
        local dOk, data = pcall(HttpService.JSONDecode, HttpService, raw)
        if not dOk or type(data) ~= "table" then return nil end
        return data
    end

    local function writeSkip(job)
        pcall(function()
            writefile(stateFile, HttpService:JSONEncode({ skipJob = job, at = os.time() }))
        end)
    end

    -- hydra1.2.11: dwell the FULL interval before the first search on
    -- every server. The old 35s settle was the real teleport clock �
    -- search fires, finds a cross-server listing, teleports, rebirths,
    -- 35s again. SEARCH_INTERVAL now truly governs teleport cadence.
    task.wait(SEARCH_INTERVAL)

    -- hydra1.2.16: Large Gift Bag is the focus lane (searched first).
    -- Raffle ticket removed from search priority; its ZapHub buy lane
    -- stays as passive insurance if one appears on a server we're on.
    -- PINATA LANE: edit PINATA_MAX_PRICE at the top of this session
    -- file to change the buy ceiling (default 35000).
    local ITEMS = {
        { name = "Large Gift Bag", class = "Misc", id = "Large Gift Bag" },
        { name = "Gift Bag", class = "Misc", id = "Gift Bag" },
        { name = "Pinata", class = "Misc", id = "Pinata" },
    }

    while true do
        for _, item in ipairs(ITEMS) do
            local ok, result = pcall(function()
                return SearchRemote:InvokeServer(
                    item.class,
                    string.format('{"id":"%s"}', item.id),
                    nil,
                    true
                )
            end)

            if ok and type(result) == "table" and result.job_id and result.job_id ~= "" then
                if result.job_id == game.JobId then
                    local sellerName = tostring(result.user_id)
                    pcall(function()
                        sellerName = Players:GetNameFromUserIdAsync(result.user_id)
                            .. " (" .. tostring(result.user_id) .. ")"
                    end)

                    lastSellerInfo = sellerName .. " | " .. item.name
                        .. " | booth " .. tostring(result.booth)

                    log(item.name .. ": listing is on THIS server (booth "
                        .. tostring(result.booth) .. ", SELLER: " .. sellerName
                        .. "); parking for ZapHub.")
                else
                    local state = readSkip()
                    local skip = state and state.skipJob or ""
                    local stale = not state or (os.time() - (state.at or 0) > 600)

                    if result.job_id == skip and not stale then
                        log(item.name .. ": resolved to recently-left job; skipping (ping-pong guard).")
                    else
                        -- hydra1.2.2: seller attribution � resolve the
                        -- seller's username so purchases are traceable
                        local sellerName = tostring(result.user_id)
                        pcall(function()
                            sellerName = Players:GetNameFromUserIdAsync(result.user_id)
                                .. " (" .. tostring(result.user_id) .. ")"
                        end)

                        log(item.name .. " -> job " .. result.job_id
                            .. " booth " .. tostring(result.booth)
                            .. " | SELLER: " .. sellerName
                            .. " | teleporting (came from " .. game.JobId .. ").")

                        writeSkip(result.job_id)

                        -- hydra1.2.6: seller context for purchase attribution
                        -- (teleport webhook REMOVED per user; ZapHub's buy
                        -- alert now triggers our attribution follow-up)
                        lastSellerInfo = sellerName .. " | " .. item.name
                            .. " | booth " .. tostring(result.booth)

                        local tpOk = pcall(function()
                            TeleportService:TeleportToPlaceInstance(
                                result.place_id, result.job_id, LocalPlayer)
                        end)

                        if tpOk then return end
                    end
                end
            end
        end

        task.wait(SEARCH_INTERVAL)
    end
end)

]==]
end

local function startSniperStack()

    if type(writefile) ~= "function" or type(readfile) ~= "function" then
        warn("[Hydra] Sniper session needs readfile/writefile; falling back to ZapHub serverhop.")
        return false
    end

    pcall(writefile, SNIPER_SESSION_FILE, sniperSessionSource())


    local ok, err = pcall(function()
        loadstring(readfile(SNIPER_SESSION_FILE))()
    end)

    if not ok then
        warn("[Hydra] Sniper session start failed: " .. tostring(err))
        return false
    end

    print("[Hydra] Sniper stack running: ZapHub serverhop off, our dwell hopper armed (90s).")
    return true
end

--============================================================ ACCOUNT 5 (ACCOUNT_5_NAME): booth sniper (hydra1.1.1)
-- Was: ZapHub booth seller (stones 9800 / keys 8900). Now snipes
-- alongside ACCOUNT_6_NAME — same targets, same ceilings.

-- SELLMODE (hydra-sellmode): ACCOUNT_5_NAME sells stones/keys; ACCOUNT_6_NAME snipes.
local function runAccount5()
    applyFullPerfStack(15)

    -- anti-AFK: sellers sit still at the booth
    pcall(function()
        local VirtualUser = game:GetService("VirtualUser")
        player.Idled:Connect(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end)

    _G.ZapHubBoothSellerSettings = {
        Items = {
            {Class = "Misc", Item = "Exclusive Raffle Ticket", Price = 20600000},
            {Class = "Misc", Item = "Charm Stone", Price = 9800},
            {Class = "Misc", Item = "Crystal Key", Price = 8900},
        },
        Extras = {},
        CustomExtras = {},
        ServerHop = {
            Enabled = true,
            Type = "Both",
            Time = 5,
        },
        Webhook = {
            Enabled = true,
            WebhookURL = FLEET_WEBHOOK,
        },
    }

    script_key = ZAPHUB_KEY
    loadstring(game:HttpGet("https://zaphub.xyz/ExecBoothSeller"))()

    startZapHubAutoMinimize()

    print("[Hydra] ACCOUNT_5_NAME: booth seller | stones 9800 | keys 8900 | serverhop on")
end
--============================================================ ACCOUNT 6 (ACCOUNT_6_NAME): booth sniper

local function runAccount6()
    -- fps 5 (hydra1.1.6): cut render cost during hop churn
    applyFullPerfStack(5)

    if not startSniperStack() then
        -- fallback: legacy inline config with ZapHub serverhop
        _G.ZapHubBoothsSniperSettings = {
            MinimumGems = 0,
            Items = {
                {Class = "Misc", Item = "Large Gift Bag", MaxPrice = 6700, MaxInInventory = 999999},
                {Class = "Misc", Item = "Gift Bag", MaxPrice = 1500, MaxInInventory = 999999},
            },
            Extras = {},
            CustomExtras = {},
            ServerHop = { Enabled = true, Type = "Both" },
            Webhook = {
                Enabled = true,
                WebhookURL = "PASTE_YOUR_SNIPER_WEBHOOK_HERE",
            },
        }

        script_key = ZAPHUB_KEY
        loadstring(game:HttpGet("https://zaphub.xyz/ExecBoothSniper"))()
        startZapHubAutoMinimize()
    end


    print("[Hydra] ACCOUNT_6_NAME: booth sniper | LGB<=6700 | GB<=1500 | our hopper 90s")
end
--============================================================ dispatch

print("[Hydra] " .. HYDRA_BUILD .. " booting for " .. player.Name)

local accountHandlers = {
    [ACCOUNT_1] = runAccount1,
    [ACCOUNT_2] = runAccount2,
    [ACCOUNT_3] = runAccount3,
    [ACCOUNT_4] = runAccount4,
    [ACCOUNT_5] = runAccount5,
    [ACCOUNT_6] = runAccount6,
}

local selectedHandler = accountHandlers[username]

if not selectedHandler then
    env[sessionKey] = nil
    warn("[Hydra] No script assigned to " .. player.Name)
    return
end

print("[Hydra] Loading configured script for " .. player.Name)

local success, runtimeError = pcall(selectedHandler)

if not success then
    env[sessionKey] = nil
    warn("[Hydra] AutoExec failed for " .. player.Name .. ": " .. tostring(runtimeError))
end
