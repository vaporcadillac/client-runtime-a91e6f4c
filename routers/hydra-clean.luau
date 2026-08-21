--============================================================-- HYDRA ROUTER | hydra-clean
-- CONFIG-DRIVEN template. Edit ONLY the CFG block below — every
-- runtime value (items, ceilings, intervals, roles, webhooks)
-- flows from it. No hunting through the file.
--
-- ROLES per account (2tqeg can be "sniper" or "seller"; others fixed):
--   "sniper" = terminal-guided booth sniping
--   "seller" = booth seller (raffle/stones/keys)
--
-- USAGE: copy this file into autoexec as the ONLY active hydra file
-- (rename others to *.off). Volt runs every .luau in autoexec.
--============================================================

--============================================================-- HYDRA ROUTER | hydra-clean
-- CONFIG FILE: reads hydra-config.luau (the ONLY file you edit).
-- Never touch this file again.
--
-- USAGE: hydra-config.luau + this file both in autoexec; rename
-- other hydra files to *.off so only one router runs.
--============================================================

local env = getgenv()

-- load the config file (pure table, sets getgenv().HYDRA_CFG)
local loadOk, loadErr = pcall(function()
    return loadstring(readfile("hydra-config.luau"))()
end)
if not loadOk then
    warn("[Hydra] FATAL: could not load hydra-config.luau: " .. tostring(loadErr))
    return
end

local CFG = env.HYDRA_CFG
if type(CFG) ~= "table" then
    warn("[Hydra] FATAL: hydra-config.luau did not set HYDRA_CFG.")
    return
end

--============================================================ constants

local HYDRA_BUILD = "hydra-clean"

if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local player = Players.LocalPlayer

while not player do task.wait() player = Players.LocalPlayer end

local username = string.lower(player.Name)
local sessionKey = "HydraRouter_" .. HYDRA_BUILD .. "_" .. tostring(player.UserId)

if env[sessionKey] then
    warn("[Hydra] AutoExec already ran for " .. player.Name)
    return
end

env[sessionKey] = true

local ACCOUNT_1 = string.lower("scoobiesnaxx691")
local ACCOUNT_2 = string.lower("vaanila14")
local ACCOUNT_3 = string.lower("Majorette058")
local ACCOUNT_4 = string.lower("7pyze")
local ACCOUNT_5 = string.lower("2tqeg")
local ACCOUNT_6 = string.lower("amb19")

local ZAPHUB_KEY = CFG.ZapKey
local FLEET_WEBHOOK = CFG.FleetWebhook
local SNIPER_WEBHOOK = CFG.SniperWebhook

-- expose config to the session (session is loadstring'd in-process)
env.HYDRA_CFG = CFG

--============================================================ perf stack

local function setFpsCap(fps)
    if type(setfpscap) == "function" then
        local ok, e = pcall(setfpscap, fps)
        if not ok then warn("[Hydra] FPS cap failed: " .. tostring(e)) end
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
        if pcall(setfflag, name, value) then applied += 1 end
    end

    print(string.format("[Hydra] Performance FFlags applied: %d/%d", applied, 8))

    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level1 end)
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
        if not game:IsLoaded() then game.Loaded:Wait() end
        local SoundService = game:GetService("SoundService")
        local function mute(d)
            if d:IsA("Sound") then pcall(function() d.Volume = 0 end) end
        end
        for _, s in ipairs(SoundService:GetDescendants()) do mute(s) end
        SoundService.DescendantAdded:Connect(mute)
        workspace.DescendantAdded:Connect(mute)
        while true do
            task.wait(300)
            for _, svc in ipairs({ workspace, SoundService }) do
                for _, s in ipairs(svc:GetDescendants()) do mute(s) end
            end
        end
    end)
end

local function startRenderFlush()
    task.spawn(function()
        if not game:IsLoaded() then game.Loaded:Wait() end
        task.wait(120)
        while true do
            task.wait(2 * 60 * 60)
            pcall(function()
                settings().Rendering.QualityLevel = Enum.QualityLevel.Level21
                task.wait(0.5)
                settings().Rendering.QualityLevel = Enum.QualityLevel.Level1
            end)
        end
    end)
end

local function startVoidCamera()
    task.spawn(function()
        if not game:IsLoaded() then game.Loaded:Wait() end
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
            if string.find(message, pattern) then return end
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

--============================================================ zonekeeper-1.4 (farmers only)

local function startZoneKeeper()
    if env.GZONEKEEPER_ENABLED == false then return end

    task.spawn(function()
        if not game:IsLoaded() then game.Loaded:Wait() end

        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local HttpService = game:GetService("HttpService")
        local LocalPlayer = Players.LocalPlayer
        while not LocalPlayer do task.wait() LocalPlayer = Players.LocalPlayer end

        local targetZone = tonumber(env.GZONEKEEPER_ZONE)
        if not targetZone then return end

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
        local requestFn = resolveExecutorFunction("request") or resolveExecutorFunction("http_request")

        local logName = string.format("zk_log_%s.txt", tostring(LocalPlayer.UserId))

        local function log(message)
            local line = string.format("[%s] %s\n", os.date("%H:%M:%S"), message)
            print("[ZoneKeeper] " .. message)
            if writeFileFn then
                pcall(function()
                    if appendLog then appendLog(logName, line)
                    else
                        local ok, existing = pcall(readfile, logName)
                        writeFileFn(logName, (ok and existing or "") .. line)
                    end
                end)
            end
        end

        local function notify(title, description, color)
            if not requestFn then return end
            local payload = {
                username = "ZoneKeeper - " .. LocalPlayer.Name,
                embeds = {{ title = title, description = description, color = color or 2326507 }},
            }
            task.spawn(function()
                pcall(requestFn, {
                    Url = FLEET_WEBHOOK, Method = "POST",
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
        if not Client then log("FATAL: Library.Client unavailable.") return end

        local MapCmds
        do
            local ok, mod = pcall(require, Client:WaitForChild("MapCmds", 10))
            if ok then MapCmds = mod end
        end
        if not MapCmds or type(MapCmds.IsInDottedBox) ~= "function" then
            log("FATAL: MapCmds unavailable.") return
        end

        local Network = ReplicatedStorage:WaitForChild("Network", 30)

        local function isInFarmArea()
            local ok, result = pcall(MapCmds.IsInDottedBox)
            return ok and result == true
        end

        local function getRoot()
            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if not humanoid or humanoid.Health <= 0 or not root then return nil end
            return root
        end

        local function fmtPos(v) return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z) end

        local function resolveZoneName()
            local mapFolder = workspace:FindFirstChild("Map")
            if not mapFolder then return nil end
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
            if not mapFolder then return nil end
            local prefix = tostring(targetZone) .. " | "
            for _, zoneFolder in ipairs(mapFolder:GetChildren()) do
                if string.sub(zoneFolder.Name, 1, #prefix) == prefix then
                    local interact = zoneFolder:FindFirstChild("INTERACT")
                    if not interact then return nil end
                    local breakZones = interact:FindFirstChild("BREAK_ZONES")
                    if not breakZones then return nil end
                    local bestPart, bestVolume = nil, -1
                    for _, part in ipairs(breakZones:GetChildren()) do
                        if part:IsA("BasePart") then
                            local size = part.Size
                            local volume = size.X * size.Y * size.Z
                            if volume > bestVolume then bestVolume = volume bestPart = part end
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

                local travelRemote = Network:FindFirstChild("Teleports_RequestTeleport")
                    or Network:WaitForChild("Teleports_RequestTeleport", 10)

                if not travelRemote or not travelRemote:IsA("RemoteFunction") then
                    log(reason .. ": travel remote missing/renamed; failing.")
                    return false
                end

                local ok, res = pcall(function()
                    return travelRemote:InvokeServer(zoneName)
                end)
                log(string.format("%s: travel returned ok=%s res=%s.", reason, tostring(ok), tostring(res)))

                local deadline = os.clock() + 20
                while os.clock() < deadline do
                    task.wait(1)
                    local root = getRoot()
                    if root then
                        local mapFolder = workspace:FindFirstChild("Map")
                        local prefix = tostring(targetZone) .. " | "
                        if mapFolder and mapFolder:FindFirstChild(prefix .. zoneName) then break end
                    end
                end
            else
                log(reason .. ": could not resolve zone name; CFrame-only attempt.")
            end

            log(string.format("%s: waiting for BREAK_ZONE geometry (up to %ds)...", reason, streamTimeout))
            local deadline = os.clock() + streamTimeout
            local center = nil
            while os.clock() < deadline do
                center = resolveBreakZoneCenter()
                if center then break end
                task.wait(3)
            end

            if not center then log(reason .. ": BREAK_ZONE never streamed in; failing.") return false end
            log(string.format("%s: BREAK_ZONE center %s.", reason, fmtPos(center)))

            local root = getRoot()
            if not root then log(reason .. ": no character root; failing.") return false end

            root.CFrame = CFrame.new(center + Vector3.new(0, yOffset, 0))
            task.wait(2)
            local inside = isInFarmArea()
            log(string.format("%s: after center teleport inside=%s.", reason, tostring(inside)))
            return inside
        end

        log(string.format("zonekeeper-1.4 start | zone %d", targetZone))
        task.wait(settleSeconds)

        local positioned = positionIntoZone("Boot")
        local anchor = resolveBreakZoneCenter()
        if not anchor then
            local root = getRoot()
            if root and isInFarmArea() then anchor = root.Position end
        end

        if writeFileFn and anchor then
            pcall(writeFileFn, string.format(
                "zonekeeper_%s_%s_%s.json",
                tostring(LocalPlayer.UserId), tostring(game.PlaceId), tostring(targetZone)
            ), HttpService:JSONEncode({
                schema = 4, engine = "zonekeeper-1.4",
                userId = LocalPlayer.UserId, placeId = game.PlaceId,
                placeVersion = game.PlaceVersion, zone = targetZone,
                zoneName = resolveZoneName(),
                position = { x = anchor.X, y = anchor.Y, z = anchor.Z },
                positioned = positioned, at = os.time(),
            }))
        end

        notify(
            positioned and "ZoneKeeper Positioned" or "ZoneKeeper Position Issues",
            string.format("**%s** — zone %d | inside: %s | anchor %s",
                LocalPlayer.Name, targetZone, tostring(positioned),
                anchor and fmtPos(anchor) or "none"),
            positioned and 2326507 or 16753920
        )

        LocalPlayer.CharacterAdded:Connect(function(character)
            task.delay(settleSeconds, function()
                local root = character:FindFirstChild("HumanoidRootPart")
                    or character:WaitForChild("HumanoidRootPart", 10)
                if root and not isInFarmArea() then positionIntoZone("Spawn") end
            end)
        end)

        log("Keep-mode " .. (keepMode and "active." or "DISABLED (boot/respawn positioning only)."))
        if not keepMode then return end

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
                        if not done then positionIntoZone("KeepFallback") end
                        if teleportsThisSession == 5 or teleportsThisSession % 25 == 0 then
                            notify("ZoneKeeper Return Teleports",
                                string.format("**%s** — %d return teleports this session (zone %d).",
                                    LocalPlayer.Name, teleportsThisSession, targetZone),
                                16753920)
                        end
                    end
                end
            else
                outsidePolls = 0
            end
        end
    end)
end

--============================================================ hyperflow engine (farmers only)

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
        local function downloadWithRetry(baseUrl, attempts, cacheBust)
            local lastError = "unknown download error"
            local sessionId = tostring(os.time())
            for attempt = 1, attempts do
                local requestUrl = baseUrl
                if cacheBust then
                    local sep = string.find(baseUrl, "?", 1, true) and "&" or "?"
                    requestUrl = baseUrl .. sep .. "session=" .. sessionId .. "&attempt=" .. tostring(attempt)
                end
                local ok, result = pcall(function() return game:HttpGet(requestUrl) end)
                if ok and type(result) == "string" and #result > 0 then return result end
                lastError = tostring(result)
                if attempt < attempts then task.wait(math.min(30, attempt * 5)) end
            end
            return nil, lastError
        end

        local source, err = downloadWithRetry(
            "https://raw.githubusercontent.com/vaporcadillac/client-runtime-a91e6f4c/main/module_exp_5a.lua",
            10, true)
        if not source then warn("[PinataLoader] Download failed: " .. tostring(err)) return end

        local chunk, compileError = loadstring(source)
        if not chunk then warn("[PinataLoader] Compile failed: " .. tostring(compileError)) return end

        local ok, runtimeError = pcall(chunk)
        if not ok then warn("[PinataLoader] Startup failed: " .. tostring(runtimeError)) end
    end)
end

--============================================================ ZapHub mailer (farmers only)

local function startZapHubMailer()
    if env.GZAPMAILER_ENABLED == false then return end

    local mail = { Receiver = "2tqeg", GemsTrigger = CFG.MailTriggerGems or 500000000, GemsKeep = CFG.MailKeepGems or 5000000, CharmStoneTrigger = 10000, CrystalKeyTrigger = 10000 }
    _G.ZapHubMailerSettings = {
        Users = { mail.Receiver },
        Items = {
            { Class = "Currency", Item = "Diamonds",
              MinimumAmount = mail.GemsTrigger, AmountToKeep = mail.GemsKeep },
            { Class = "Misc", Item = "Charm Stone",
              MinimumAmount = mail.CharmStoneTrigger, AmountToKeep = 0 },
            { Class = "Misc", Item = "Crystal Key",
              MinimumAmount = mail.CrystalKeyTrigger, AmountToKeep = 0 },
        },
        Extras = {},
        CustomExtras = {},
        OnlyOnline = false,
        Webhook = { Enabled = true, WebhookURL = FLEET_WEBHOOK },
    }

    task.spawn(function()
        if not game:IsLoaded() then game.Loaded:Wait() end
        task.wait(tonumber(env.GZAPMAILER_DELAY) or 60)
        script_key = ZAPHUB_KEY
        loadstring(game:HttpGet("https://zaphub.xyz/ExecMailer"))()
        print("[Hydra] ZapHub mailer loaded (receiver: " .. mail.Receiver .. ").")
    end)
end

--============================================================ ZapHub Exec (farmers)

local function startZapHub()
    task.spawn(function()
        if not game:IsLoaded() then game.Loaded:Wait() end
        task.wait(tonumber(env.GZAPHUB_DELAY) or 30)
        script_key = ZAPHUB_KEY
        loadstring(game:HttpGet("https://zaphub.xyz/Exec"))()
        print("[Hydra] ZapHub loaded (Exec).")
    end)
end
--============================================================ ZapHub auto-minimize

local function startZapHubAutoMinimize()
    if env.GZAPHUB_AUTOMIN == false then return end

    task.spawn(function()
        local hui = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
        local deadline = os.clock() + 300
        while os.clock() < deadline do
            local zapLib = hui:FindFirstChild("ZapLib", true)
            if zapLib and zapLib:IsA("ScreenGui") then
                local bg = zapLib:FindFirstChild("BackgroundGUI")
                if bg and bg:IsA("GuiObject") then
                    task.wait(5)
                    if bg.Visible then bg.Visible = false end
                    return
                end
            end
            task.wait(2)
        end
    end)
end

--============================================================ sniper session (config-driven)

local SNIPER_SESSION_FILE = "hydra_sniper_session.luau"

local function sniperSessionSource()
    -- config is a dict {["Item"] = maxprice}; convert to arrays
    local sniperLanes = {}
    for itemName, price in pairs(CFG.SniperItems or {}) do
        table.insert(sniperLanes, { Item = itemName, MaxPrice = tonumber(price) or 0 })
    end

    local zapItems = {}
    for _, item in ipairs(sniperLanes) do
        table.insert(zapItems, string.format(
            "{Class = \"Misc\", Item = \"%s\", MaxPrice = %d, MaxInInventory = 999999},",
            item.Item, item.MaxPrice))
    end
    local zapItemsText = table.concat(zapItems, "\n        ")

    -- search order = insertion order of the config dict (Luau preserves
    -- string-key insertion order), so the first line is the priority lane
    local searchNames = {}
    for _, item in ipairs(sniperLanes) do
        table.insert(searchNames, string.format(
            "{ name = \"%s\", class = \"Misc\", id = \"%s\" },", item.Item, item.Item))
    end
    local searchNamesText = table.concat(searchNames, "\n        ")

    return [==[
-- hydra sniper session (config-driven from hydra-clean)
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CFG = getgenv().HYDRA_CFG
if type(CFG) ~= "table" then CFG = {} end

local SEARCH_INTERVAL = tonumber(CFG.SearchInterval) or 180
local WEBHOOK = CFG.SniperWebhook or ""

if not game:IsLoaded() then game.Loaded:Wait() end

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do task.wait() LocalPlayer = Players.LocalPlayer end

local logFile = string.format("th_log_%s.txt", tostring(LocalPlayer.UserId))

local function log(msg)
    print("[HydraSession] " .. msg)
    pcall(function()
        if isfile and isfile(logFile) then appendfile(logFile, msg .. "\n")
        else writefile(logFile, msg .. "\n") end
    end)
end

pcall(function()
    LocalPlayer.Idled:Connect(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

-- ZapHub sniper: serverhop OFF — our terminal layer owns movement
_G.ZapHubBoothsSniperSettings = {
    MinimumGems = 0,
    Items = {
        ]==] .. zapItemsText .. [==[
    },
    Extras = {},
    CustomExtras = {},
    ServerHop = { Enabled = false, Type = "Both" },
    Webhook = { Enabled = true, WebhookURL = WEBHOOK },
}

task.delay(15, function()
    script_key = CFG.ZapKey or ""
    loadstring(game:HttpGet("https://zaphub.xyz/ExecBoothSniper"))()
    log("sniper loaded (ZapHub serverhop off).")
end)

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

task.spawn(function()
    local Network = ReplicatedStorage:WaitForChild("Network", 30)
    local SearchRemote = Network and Network:WaitForChild("TradingTerminal_Search", 10)
    if not SearchRemote then
        log("TradingTerminal_Search missing; terminal layer idle this server.")
        return
    end

    local stateFile = string.format("th_state_%s.json", tostring(LocalPlayer.UserId))

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

    task.wait(SEARCH_INTERVAL) -- dwell FULL interval before first search (1.2.11 fix)

    local ITEMS = {
        ]==] .. searchNamesText .. [==[
    }

    while true do
        for _, item in ipairs(ITEMS) do
            local ok, result = pcall(function()
                return SearchRemote:InvokeServer(item.class, string.format('{"id":"%s"}', item.id), nil, true)
            end)

            if ok and type(result) == "table" and result.job_id and result.job_id ~= "" then
                if result.job_id == game.JobId then
                    local sellerName = tostring(result.user_id)
                    pcall(function()
                        sellerName = Players:GetNameFromUserIdAsync(result.user_id)
                            .. " (" .. tostring(result.user_id) .. ")"
                    end)
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
    if env.__HYDRA_SNIPER_STACK_RUNNING then
        print("[Hydra] Sniper stack already running in this process; skipping.")
        return true
    end

    if type(writefile) ~= "function" or type(readfile) ~= "function" then
        warn("[Hydra] Sniper session needs readfile/writefile; falling back to ZapHub serverhop.")
        return false
    end

    env.__HYDRA_SNIPER_STACK_RUNNING = true

    pcall(writefile, SNIPER_SESSION_FILE, sniperSessionSource())

    local ok, err = pcall(function()
        loadstring(readfile(SNIPER_SESSION_FILE))()
    end)

    if not ok then
        warn("[Hydra] Sniper session start failed: " .. tostring(err))
        return false
    end

    print("[Hydra] Sniper stack running (terminal-guided).")
    return true
end

local function configToZapItems(dict)
    local out = {}
    for itemName, price in pairs(dict or {}) do
        table.insert(out, { Class = "Misc", Item = itemName, MaxPrice = tonumber(price) or 0 })
    end
    return out
end

local function configToSellerItems(dict)
    local out = {}
    for itemName, price in pairs(dict or {}) do
        table.insert(out, { Class = "Misc", Item = itemName, Price = tonumber(price) or 0 })
    end
    return out
end--============================================================ seller empty-hop (player-count driven)
-- Replaces ZapHub's timed serverhop: if the server sits at 0 players
-- for SellerHopEmptyMinutes (config), teleport to a random public
-- server. Autoexec re-arms the seller on arrival.

local function startSellerEmptyHop()
    local emptyMinutes = tonumber(CFG.SellerHopEmptyMinutes)
    if not emptyMinutes or emptyMinutes <= 0 then
        print("[Hydra] Seller empty-hop disabled (SellerHopEmptyMinutes=0).")
        return
    end

    task.spawn(function()
        if not game:IsLoaded() then game.Loaded:Wait() end

        local TeleportService = game:GetService("TeleportService")
        local HttpService = game:GetService("HttpService")

        task.wait(120) -- settle after boot before judging emptiness

        local emptySince = nil

        while true do
            local playerCount = #Players:GetPlayers()

            if playerCount == 0 then
                emptySince = emptySince or os.clock()
            else
                emptySince = nil
            end

            if emptySince and (os.clock() - emptySince) >= emptyMinutes * 60 then
                print(string.format(
                    "[Hydra] Server empty for %.0f+ min; hopping.",
                    (os.clock() - emptySince) / 60))

                local placeId = game.PlaceId
                local currentJob = game.JobId
                local target = nil

                local ok, res = pcall(function()
                    return request({
                        Url = "https://games.roblox.com/v1/games/"
                            .. tostring(placeId)
                            .. "/servers/Public?sortOrder=2&limit=100",
                        Method = "GET",
                    })
                end)

                if ok and res and res.Body then
                    local dOk, data = pcall(HttpService.JSONDecode, HttpService, res.Body)

                    if dOk and type(data) == "table" and type(data.data) == "table" then
                        local candidates = {}
                        for _, server in ipairs(data.data) do
                            if server.id ~= currentJob
                                and (server.playing or 0) < (server.maxPlayers or 200)
                            then
                                table.insert(candidates, server.id)
                            end
                        end
                        if #candidates > 0 then
                            target = candidates[math.random(#candidates)]
                        end
                    end
                end

                if target then
                    pcall(function()
                        TeleportService:TeleportToPlaceInstance(placeId, target)
                    end)
                    return
                end

                print("[Hydra] Empty-hop: no joinable server found; will retry.")
                emptySince = os.clock()
            end

            task.wait(30)
        end
    end)
end
--============================================================ roles

local function runSniper(accountName, fps)
    applyFullPerfStack(fps)

    if not startSniperStack() then
        _G.ZapHubBoothsSniperSettings = {
            MinimumGems = 0,
            Items = configToZapItems(CFG.SniperItems),
            Extras = {},
            CustomExtras = {},
            ServerHop = { Enabled = true, Type = "Both" },
            Webhook = { Enabled = true, WebhookURL = SNIPER_WEBHOOK },
        }
        script_key = ZAPHUB_KEY
        loadstring(game:HttpGet("https://zaphub.xyz/ExecBoothSniper"))()
        startZapHubAutoMinimize()
    end

    print(string.format("[Hydra] %s: sniper (config lanes).", accountName))
end

local function runSeller(accountName)
    applyFullPerfStack(15)

    pcall(function()
        local VirtualUser = game:GetService("VirtualUser")
        player.Idled:Connect(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end)

    _G.ZapHubBoothSellerSettings = {
        Items = configToSellerItems(CFG.SellerItems),
        Extras = {},
        CustomExtras = {},
        ServerHop = { Enabled = false, Type = "Both", Time = 5 },
        Webhook = { Enabled = true, WebhookURL = FLEET_WEBHOOK },
    }

    script_key = ZAPHUB_KEY
    loadstring(game:HttpGet("https://zaphub.xyz/ExecBoothSeller"))()

    startZapHubAutoMinimize()
    startSellerEmptyHop()

    print(string.format("[Hydra] %s: booth seller (config items).", accountName))
end

local function runFarmer(zoneTo)
    applyFullPerfStack(10)

    env.GZONEKEEPER_ENABLED = true
    env.GZONEKEEPER_ZONE = zoneTo
    env.GZONE_TO = zoneTo -- engine calibration zone (was missing: all farmers defaulted to 39)
    env.GWEBHOOK_USERID = "PASTE_YOUR_DISCORD_USER_ID_HERE"
    env.GWEBHOOK_LINK = FLEET_WEBHOOK

    applyPinataEngineSettings()
    startZoneKeeper()
    startPinataEngine()
    startZapHub()
    startZapHubAutoMinimize()
    startZapHubMailer()
end

--============================================================ dispatch

print("[Hydra] " .. HYDRA_BUILD .. " booting for " .. player.Name .. " | config loaded OK")

local handlers = {
    [ACCOUNT_1] = function() runFarmer(CFG.FarmerZones["scoobiesnaxx691"] or 44) end,
    [ACCOUNT_2] = function() runFarmer(CFG.FarmerZones["vaanila14"] or 39) end,
    [ACCOUNT_3] = function() runFarmer(CFG.FarmerZones["Majorette058"] or 32) end,
    [ACCOUNT_4] = function()
        env.GPINATA_TARGET_INTERVAL = 5.5
        runFarmer(CFG.FarmerZones["7pyze"] or 26)
    end,
    [ACCOUNT_5] = function()
        local role = CFG["2tqeg_role"] or "sniper"
        if role == "seller" then runSeller("2tqeg")
        else runSniper("2tqeg", 5) end
    end,
    [ACCOUNT_6] = function() runSniper("amb19", 5) end,
}

local selected = handlers[username]

if not selected then
    env[sessionKey] = nil
    warn("[Hydra] No script assigned to " .. player.Name)
    return
end

local success, runtimeError = pcall(selected)

if not success then
    env[sessionKey] = nil
    warn("[Hydra] AutoExec failed for " .. player.Name .. ": " .. tostring(runtimeError))
end
