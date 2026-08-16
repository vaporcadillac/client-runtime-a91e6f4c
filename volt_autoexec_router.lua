--============================================================-- VOLT SIX-ACCOUNT AUTOEXEC ROUTER
-- (ALL PINATA ACCOUNTS ON hyperflow-5.1b EXPERIMENTAL ENGINE)
--
-- Accounts 1-4: Experimental 5.5s adaptive probe + GScript Hijack
-- Account 1 (ACCOUNT_1_NAME): ALSO runs giftbag-opener-1.1 test
-- Account 5 (ACCOUNT_5_NAME): Plaza script, no pinata engine
-- Account 6 (ACCOUNT_6_NAME): GScript progression + remote map logger d4
--============================================================

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
local sessionKey = "VoltFiveAccountRouter_" .. tostring(player.UserId)

if env[sessionKey] then
    warn("[Router] AutoExec already ran for " .. player.Name)
    return
end

env[sessionKey] = true

--============================================================
-- ACCOUNT USERNAMES
--============================================================

local ACCOUNT_1 = string.lower("ACCOUNT_1_NAME")
local ACCOUNT_2 = string.lower("ACCOUNT_2_NAME")
local ACCOUNT_3 = string.lower("ACCOUNT_3_NAME")
local ACCOUNT_4 = string.lower("ACCOUNT_4_NAME")
local ACCOUNT_5 = string.lower("ACCOUNT_5_NAME")
local ACCOUNT_6 = string.lower("ACCOUNT_6_NAME")

--============================================================
-- SHARED HELPERS
--============================================================

local PINATA_ENGINE_URL =
    "https://raw.githubusercontent.com/vaporcadillac/client-runtime-a91e6f4c/main/module_7c31.lua"

local PINATA_ENGINE_EXPERIMENTAL_URL =
    "https://raw.githubusercontent.com/vaporcadillac/client-runtime-a91e6f4c/main/module_exp_5a.lua"

local GSCRIPT_URL =
    "https://api.luarmor.net/files/v3/loaders/34915da4ad87a5028e1fd64efbe3543f.lua"

local GIFTBAG_URL =
    "https://raw.githubusercontent.com/vaporcadillac/client-runtime-a91e6f4c/main/module_giftbag.lua"

local function setLowFps()
    if type(setfpscap) == "function" then
        local ok, fpsError = pcall(setfpscap, 10)
        if not ok then
            warn("[Router] FPS cap failed: " .. tostring(fpsError))
        end
    end
end

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

--============================================================
-- GIFTBAG OPENER LOADER (account 1 test only)
--============================================================

local function startGiftbagOpener()
    task.spawn(function()
        local source, downloadError = downloadWithRetry(GIFTBAG_URL, 10, true)

        if not source then
            warn("[GiftbagLoader] Download failed: " .. tostring(downloadError))
            return
        end

        local chunk, compileError = loadstring(source)

        if not chunk then
            warn("[GiftbagLoader] Compile failed: " .. tostring(compileError))
            return
        end

        local ok, runtimeError = pcall(chunk)

        if not ok then
            warn("[GiftbagLoader] Startup failed: " .. tostring(runtimeError))
        end
    end)
end

--============================================================
-- MINI PINATA SETTINGS (LEGACY PRODUCTION 6.2s — kept for rollback)
--============================================================

local function applyPinataSettings()
    env.GEVENT_ITEMS_TO_USE = {}

    env.GPINATA_ENABLED = true
    env.GTELEMETRY_ENABLED = true
    env.GTELEMETRY_ENDPOINT = "https://runtime-status-a91e6f4c.swept6510.workers.dev/api/telemetry"
    env.GTELEMETRY_WRITE_KEY = "PASTE_YOUR_TELEMETRY_KEY_HERE"
    env.GTELEMETRY_INTERVAL_SECONDS = 25

    env.GPINATA_INTERVAL = 6.2
    env.GPINATA_ADAPTIVE = true
    env.GPINATA_ADAPTIVE_MIN_INTERVAL = 6.2
    env.GPINATA_ADAPTIVE_MAX_INTERVAL = 8.0
    env.GPINATA_ADAPTIVE_WINDOW = 20
    env.GPINATA_ADAPTIVE_STEP_UP = 0.15
    env.GPINATA_ADAPTIVE_STEP_DOWN = 0.05
    env.GPINATA_ADAPTIVE_HIGH_REJECT_RATE = 0.25
    env.GPINATA_ADAPTIVE_PRESSURE_WINDOWS = 2
    env.GPINATA_ADAPTIVE_PRESSURE_STEP = 0.10
    env.GPINATA_ADAPTIVE_STABLE_WINDOWS = 1

    env.GPINATA_CONFIRM_WAIT = 1.5
    env.GPINATA_RETRY_DELAY = 1.0
    env.GPINATA_RECOVERY_RETRY_DELAY = 2.0
    env.GPINATA_MAX_RETRIES = 2
    env.GPINATA_REMOTE_TIMEOUT = 8.0
    env.GPINATA_WATCHDOG_TIMEOUT = 45

    env.GPINATA_STARTUP_WAIT = 60
    env.GPINATA_STABLE_WAIT = 20
    env.GPINATA_FARM_WAIT_TIMEOUT = 600

    env.GPINATA_FPS = 10
    env.GPINATA_STAGGER = true

    env.GPINATA_STATUS_EVERY = 100
    env.GPINATA_VERBOSE = false

    env.GPINATA_WEBHOOK_ENABLED = true
    env.GPINATA_WEBHOOK_URL = env.GWEBHOOK_LINK
    env.GPINATA_WEBHOOK_STATUS_EVERY = 100
    env.GPINATA_WEBHOOK_ALERT_REJECT_STREAK = 3
    env.GPINATA_WEBHOOK_MENTION_ON_CRITICAL = false
    env.GPINATA_WEBHOOK_QUEUE_LIMIT = 30

    env.GPINATA_RESTART_DELAY = 15
    env.GPINATA_RESTART_DELAY_MAX = 300
end

--============================================================
-- MINI PINATA SETTINGS (AGGRESSIVE 5.5s PROBE — now fleet-wide)
--============================================================

local function applyExperimentalPinataSettings()
    env.GEVENT_ITEMS_TO_USE = {}

    env.GPINATA_ENABLED = true
    env.GTELEMETRY_ENABLED = true
    env.GTELEMETRY_ENDPOINT = "https://runtime-status-a91e6f4c.swept6510.workers.dev/api/telemetry"
    env.GTELEMETRY_WRITE_KEY = "PASTE_YOUR_TELEMETRY_KEY_HERE"
    env.GTELEMETRY_INTERVAL_SECONDS = 25

    -- AGGRESSIVE: 5.5s floor, 7.0s ceiling for wide exploration range
    env.GPINATA_INTERVAL = 5.5
    env.GPINATA_ADAPTIVE = true
    env.GPINATA_ADAPTIVE_MIN_INTERVAL = 5.5
    env.GPINATA_ADAPTIVE_MAX_INTERVAL = 7.0
    env.GPINATA_ADAPTIVE_WINDOW = 20
    env.GPINATA_ADAPTIVE_STEP_UP = 0.15
    env.GPINATA_ADAPTIVE_STEP_DOWN = 0.05
    env.GPINATA_ADAPTIVE_HIGH_REJECT_RATE = 0.25
    env.GPINATA_ADAPTIVE_PRESSURE_WINDOWS = 2
    env.GPINATA_ADAPTIVE_PRESSURE_STEP = 0.10
    env.GPINATA_ADAPTIVE_STABLE_WINDOWS = 1

    env.GPINATA_CONFIRM_WAIT = 1.5
    env.GPINATA_RETRY_DELAY = 1.0
    env.GPINATA_RECOVERY_RETRY_DELAY = 2.0
    env.GPINATA_MAX_RETRIES = 2
    env.GPINATA_REMOTE_TIMEOUT = 8.0
    env.GPINATA_WATCHDOG_TIMEOUT = 45

    env.GPINATA_STARTUP_WAIT = 60
    env.GPINATA_STABLE_WAIT = 20
    env.GPINATA_FARM_WAIT_TIMEOUT = 600

    env.GPINATA_FPS = 10
    env.GPINATA_STAGGER = true

    env.GPINATA_STATUS_EVERY = 100
    env.GPINATA_VERBOSE = true

    env.GPINATA_WEBHOOK_ENABLED = true
    env.GPINATA_WEBHOOK_URL = env.GWEBHOOK_LINK
    env.GPINATA_WEBHOOK_STATUS_EVERY = 100
    env.GPINATA_WEBHOOK_ALERT_REJECT_STREAK = 3
    env.GPINATA_WEBHOOK_MENTION_ON_CRITICAL = false
    env.GPINATA_WEBHOOK_QUEUE_LIMIT = 30

    env.GPINATA_RESTART_DELAY = 15
    env.GPINATA_RESTART_DELAY_MAX = 300
end

--============================================================
-- DIAMOND MAILING FOR ACCOUNTS 1-4 ONLY
--============================================================

local function applyDiamondMailSettings()
    _G.GDRY_RUN = false

    _G.GMAIL_ITEMS = {
        ["Diamonds"] = {
            Class = "Currency",
            Id = "Diamonds",
            KeepAmount = "5m",
            MinAmount = "2b",
        },
    }

    _G.GMAIL_RECEIVERS = {
        "ACCOUNT_5_NAME",
    }

    _G.GMAIL_DELAY = 7.1
end

local function startPinataEngine(experimental)
    task.spawn(function()
        local url = experimental and PINATA_ENGINE_EXPERIMENTAL_URL or PINATA_ENGINE_URL
        local source, downloadError = downloadWithRetry(url, 10, true)

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

local function startGotjeeGScript()
    local source, downloadError = downloadWithRetry(GSCRIPT_URL, 10, false)

    if not source then
        error("[GScriptLoader] Download failed: " .. tostring(downloadError))
    end

    local chunk, compileError = loadstring(source)

    if not chunk then
        error("[GScriptLoader] Compile failed: " .. tostring(compileError))
    end

    local ok, runtimeError = pcall(chunk)

    if not ok then
        warn("[GScriptLoader] Startup failed: " .. tostring(runtimeError))
    end
end

local function startPinataAccount()
    applyPinataSettings()
    applyDiamondMailSettings()
    startPinataEngine(false)
    startGotjeeGScript()
end

local function startExperimentalPinataAccount()
    applyExperimentalPinataSettings()
    applyDiamondMailSettings()
    startPinataEngine(true)
    startGotjeeGScript()
end

--============================================================
-- ACCOUNT 1: EXPERIMENTAL GSCRIPT + MINI PINATA 5.5s + GIFTBAG TEST
-- ACCOUNT_1_NAME is the giftbag opener test subject.
-- GHOLD_GIFTS = true hands bags to our opener instead of GScript.
--============================================================

local function runAccount1()
    setLowFps()

    script_key = "PASTE_YOUR_GSCRIPT_KEY_HERE"
    getgenv().GPROGRESS_MODE = "Hybrid"
    getgenv().GKICK_ON_STAFF = true
    getgenv().GHOP_ON_STAFF = true
    getgenv().GGFX_MODE = 1
    getgenv().GZONE_TO = 44
    _G.GOPEN_ITEMS_IN_BULK = true
    getgenv().GHOLD_GIFTS = true
    getgenv().GHOLD_BUNDLES = true
    getgenv().GLOOTBOXES = nil
    getgenv().GUSE_SPRINKLERS = true
    getgenv().GUSE_FLAGS = {"Hasty Flag"}
    getgenv().GUSE_ULTIMATES = {"Chest Spell"}
    getgenv().GIGNORE_SLEDRACE = true
    getgenv().GIGNORE_ALL_INSTANCES = true
    getgenv().GENCHANTS = {}
    getgenv().GCOLLECT_VENDING_MACHINES = false
    getgenv().GCOLLECT_FREE_ITEMS = false
    getgenv().GHUGE_COUNT = 200
    getgenv().GMAX_ZONE_UPGRADE_COST = 20000000000
    getgenv().GFRUITS = {"Watermelon","Candycane","Apple","Rainbow","Pineapple","Orange","Banana"}
    getgenv().GPOTIONS = {"Coins","Lucky","Treasure Hunter","Walkspeed","Diamonds","Damage","The Cocktail"}
    getgenv().GPOTIONS_MAX_TIER = 10
    getgenv().GENCHANTS = {}
    env.GWEBHOOK_USERID = "PASTE_YOUR_DISCORD_USER_ID_HERE"
    env.GWEBHOOK_LINK = "PASTE_YOUR_FLEET_WEBHOOK_HERE"

    -- Giftbag opener (test)
    env.GGIFTBAG_ENABLED = true
    env.GGIFTBAG_WEBHOOK_ENABLED = true
    env.GGIFTBAG_WEBHOOK_MENTION_ON_CRITICAL = true

    startExperimentalPinataAccount()
    startGiftbagOpener()
end

--============================================================
-- ACCOUNT 2: GSCRIPT + MINI PINATA (hyperflow-5.1b)
--============================================================

local function runAccount2()
    setLowFps()

    script_key = "PASTE_YOUR_GSCRIPT_KEY_HERE"
    getgenv().GPROGRESS_MODE = "Hybrid"
    getgenv().GKICK_ON_STAFF = true
    getgenv().GHOP_ON_STAFF = true
    getgenv().GGFX_MODE = 1
    getgenv().GZONE_TO = 39
    _G.GOPEN_ITEMS_IN_BULK = true
    getgenv().GHOLD_GIFTS = false
    getgenv().GHOLD_BUNDLES = true
    getgenv().GLOOTBOXES = nil
    getgenv().GUSE_SPRINKLERS = true
    getgenv().GUSE_FLAGS = {"Hasty Flag"}
    getgenv().GUSE_ULTIMATES = {"Chest Spell"}
    getgenv().GIGNORE_SLEDRACE = true
    getgenv().GIGNORE_ALL_INSTANCES = true
    getgenv().GENCHANTS = {}
    getgenv().GCOLLECT_VENDING_MACHINES = false
    getgenv().GCOLLECT_FREE_ITEMS = false
    getgenv().GHUGE_COUNT = 200
    getgenv().GMAX_ZONE_UPGRADE_COST = 20000000000
    getgenv().GFRUITS = {"Watermelon","Candycane","Apple","Rainbow","Pineapple","Orange","Banana"}
    getgenv().GPOTIONS = {"Coins","Lucky","Treasure Hunter","Walkspeed","Diamonds","Damage","The Cocktail"}
    getgenv().GPOTIONS_MAX_TIER = 10
    getgenv().GENCHANTS = {}
    env.GWEBHOOK_USERID = "PASTE_YOUR_DISCORD_USER_ID_HERE"
    env.GWEBHOOK_LINK = "PASTE_YOUR_FLEET_WEBHOOK_HERE"

    startExperimentalPinataAccount()
end

--============================================================
-- ACCOUNT 3: GSCRIPT + MINI PINATA (hyperflow-5.1b)
--============================================================

local function runAccount3()
    setLowFps()

    script_key = "PASTE_YOUR_GSCRIPT_KEY_HERE"
    getgenv().GPROGRESS_MODE = "Hybrid"
    getgenv().GKICK_ON_STAFF = true
    getgenv().GHOP_ON_STAFF = true
    getgenv().GGFX_MODE = 1
    getgenv().GZONE_TO = 32
    _G.GOPEN_ITEMS_IN_BULK = true
    getgenv().GHOLD_GIFTS = false
    getgenv().GHOLD_BUNDLES = true
    getgenv().GLOOTBOXES = nil
    getgenv().GUSE_SPRINKLERS = true
    getgenv().GUSE_FLAGS = {"Hasty Flag"}
    getgenv().GUSE_ULTIMATES = {"Chest Spell"}
    getgenv().GIGNORE_SLEDRACE = true
    getgenv().GIGNORE_ALL_INSTANCES = true
    getgenv().GENCHANTS = {}
    getgenv().GCOLLECT_VENDING_MACHINES = false
    getgenv().GCOLLECT_FREE_ITEMS = false
    getgenv().GHUGE_COUNT = 200
    getgenv().GMAX_ZONE_UPGRADE_COST = 20000000000
    getgenv().GFRUITS = {"Watermelon","Candycane","Apple","Rainbow","Pineapple","Orange","Banana"}
    getgenv().GPOTIONS = {"Coins","Lucky","Treasure Hunter","Walkspeed","Diamonds","Damage","The Cocktail"}
    getgenv().GPOTIONS_MAX_TIER = 10
    getgenv().GENCHANTS = {}
    env.GWEBHOOK_USERID = "PASTE_YOUR_DISCORD_USER_ID_HERE"
    env.GWEBHOOK_LINK = "PASTE_YOUR_FLEET_WEBHOOK_HERE"

    startExperimentalPinataAccount()
end

--============================================================
-- ACCOUNT 4: GSCRIPT + MINI PINATA (hyperflow-5.1b)
--============================================================

local function runAccount4()
    setLowFps()

    script_key = "PASTE_YOUR_GSCRIPT_KEY_HERE"
    getgenv().GPROGRESS_MODE = "Hybrid"
    getgenv().GKICK_ON_STAFF = true
    getgenv().GHOP_ON_STAFF = true
    getgenv().GGFX_MODE = 1
    getgenv().GZONE_TO = 26
    _G.GOPEN_ITEMS_IN_BULK = true
    getgenv().GHOLD_GIFTS = false
    getgenv().GHOLD_BUNDLES = true
    getgenv().GLOOTBOXES = nil
    getgenv().GUSE_SPRINKLERS = true
    getgenv().GUSE_FLAGS = {"Hasty Flag"}
    getgenv().GUSE_ULTIMATES = {"Chest Spell"}
    getgenv().GIGNORE_SLEDRACE = true
    getgenv().GIGNORE_ALL_INSTANCES = true
    getgenv().GENCHANTS = {}
    getgenv().GCOLLECT_VENDING_MACHINES = false
    getgenv().GCOLLECT_FREE_ITEMS = false
    getgenv().GHUGE_COUNT = 200
    getgenv().GMAX_ZONE_UPGRADE_COST = 20000000000
    getgenv().GFRUITS = {"Watermelon","Candycane","Apple","Rainbow","Pineapple","Orange","Banana"}
    getgenv().GPOTIONS = {"Coins","Lucky","Treasure Hunter","Walkspeed","Diamonds","Damage","The Cocktail"}
    getgenv().GPOTIONS_MAX_TIER = 10
    getgenv().GENCHANTS = {}
    env.GWEBHOOK_USERID = "PASTE_YOUR_DISCORD_USER_ID_HERE"
    env.GWEBHOOK_LINK = "PASTE_YOUR_FLEET_WEBHOOK_HERE"

    startExperimentalPinataAccount()
end

--============================================================
-- ACCOUNT 5: PLAZA SCRIPT, NO MINI PINATA ENGINE
--============================================================

local function runAccount5()
    setfpscap(10)

    script_key = "PASTE_YOUR_GSCRIPT_KEY_HERE"
    getgenv().GPROGRESS_MODE = "Hybrid"
    getgenv().GGFX_MODE = 1
    getgenv().GRANK_TO = 40
    getgenv().GZONE_TO = 279
    getgenv().GMAX_EGG_SLOTS = 99
    getgenv().GMAX_EQUIP_SLOTS = 99
    getgenv().GHATCH_BETTER_PETS = false
    getgenv().GHOLD_GIFTS = false
    getgenv().GHOLD_BUNDLES = false
    getgenv().GLOOTBOXES = nil
    getgenv().GUSE_ULTIMATES = {"Tsunami"}
    _G.GMASTERY_TO_MAX = "Pets"
    _G.GOPEN_ITEMS_IN_BULK = true
    getgenv().GIGNORE_SLEDRACE = true
    getgenv().GIGNORE_ALL_INSTANCES = true
    getgenv().GUSE_SPRINKLERS = true
    getgenv().GENCHANTS = {}
    getgenv().GCOLLECT_VENDING_MACHINES = true
    getgenv().GCOLLECT_FREE_ITEMS = true
    getgenv().GUSE_FLAGS = {"Hasty Flag"}
    getgenv().GHUGE_COUNT = 200
    getgenv().GMAX_ZONE_UPGRADE_COST = 20000000000
    getgenv().GFRUITS = {"Watermelon","Candycane","Apple","Rainbow","Pineapple","Orange","Banana"}
    getgenv().GPOTIONS = {"Coins","Lucky","Treasure Hunter","Walkspeed","Diamonds","Damage"}
    getgenv().GPOTIONS_MAX_TIER = 8
    getgenv().GENCHANTS = {}
    getgenv().GWEBHOOK_USERID = "PASTE_YOUR_DISCORD_USER_ID_HERE"
    getgenv().GWEBHOOK_LINK = "PASTE_YOUR_FLEET_WEBHOOK_HERE"

    getgenv().GMAIL_RECEIVERS = {""}

    loadstring(game:HttpGet(
        "https://api.luarmor.net/files/v3/loaders/34915da4ad87a5028e1fd64efbe3543f.lua"
    ))()
end

--============================================================
-- ACCOUNT 6 (ACCOUNT_6_NAME): GSCRIPT PROGRESSION
-- Fresh boosted account climbing rank 20 -> max zone.
--============================================================

local function runAccount6()
    setfpscap(10)

    script_key = "PASTE_YOUR_GSCRIPT_KEY_HERE"
    getgenv().GPROGRESS_MODE = "Hybrid"
    --getgenv().GKICK_ON_STAFF = true
    --getgenv().GHOP_ON_STAFF = true
    getgenv().GGFX_MODE = 1
    getgenv().GRANK_TO = 40
    getgenv().GFOCUS_RANK_TO = 20
    getgenv().GZONE_TO = 999
    getgenv().GMAX_EGG_SLOTS = 99
    getgenv().GMAX_EQUIP_SLOTS = 99
    getgenv().GHATCH_BETTER_PETS = false
    getgenv().GHOLD_GIFTS = false
    getgenv().GHOLD_BUNDLES = false
    getgenv().GLOOTBOXES = nil
    getgenv().GUSE_SPRINKLERS = true
    getgenv().GUSE_FLAGS = {"Hasty Flag"}
    getgenv().GUSE_ULTIMATES = {"Pet Surge"}
    _G.GMASTERY_TO_MAX = "Pets"
    getgenv().GIGNORE_SLEDRACE = true
    getgenv().GIGNORE_ALL_INSTANCES = true
    getgenv().GENCHANTS = {}
    getgenv().GCOLLECT_VENDING_MACHINES = true
    getgenv().GCOLLECT_FREE_ITEMS = true
    getgenv().GHUGE_COUNT = 200
    getgenv().GMAX_ZONE_UPGRADE_COST = 20000000000
    getgenv().GFRUITS = {"Watermelon","Candycane","Apple","Rainbow","Pineapple","Orange","Banana"}
    getgenv().GPOTIONS = {"Coins","Lucky","Treasure Hunter","Walkspeed","Diamonds","Damage","The Cocktail"}
    getgenv().GPOTIONS_MAX_TIER = 7
    getgenv().GENCHANTS = {}
    getgenv().GWEBHOOK_USERID = "PASTE_YOUR_DISCORD_USER_ID_HERE"
    getgenv().GWEBHOOK_LINK = "PASTE_YOUR_FLEET_WEBHOOK_HERE"
    getgenv().GMAIL_RECEIVERS = {""}

    loadstring(game:HttpGet(
        "https://api.luarmor.net/files/v3/loaders/34915da4ad87a5028e1fd64efbe3543f.lua"
    ))()
end

--============================================================
-- SELECT AND RUN ONE ACCOUNT
--============================================================

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
    warn("[Router] No script assigned to " .. player.Name)
    return
end

print("[Router] Loading configured script for " .. player.Name)

local success, runtimeError = pcall(selectedHandler)

if not success then
    env[sessionKey] = nil
    warn(
        "[Router] AutoExec failed for "
            .. player.Name
            .. ": "
            .. tostring(runtimeError)
    )
end
