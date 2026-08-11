local env = getgenv()

if env.GPINATA_ENABLED == false then
    return
end

if env.__MINI_PINATA_FAST_PLACER_RUNNING then
    warn("[Runtime] Engine is already running.")
    return
end

env.__MINI_PINATA_FAST_PLACER_RUNNING = true
env.STOP_MINI_PINATA_FAST_PLACER = false

local bootStartedAt = os.clock()

task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    task.wait(5)

    local function numberSetting(name, default)
        return tonumber(env[name]) or default
    end

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
                numberSetting("GPINATA_ADAPTIVE_HIGH_REJECT_RATE", 0.08)
            ),
            ADAPTIVE_LOW_REJECT_RATE = math.max(
                0,
                numberSetting("GPINATA_ADAPTIVE_LOW_REJECT_RATE", 0.05)
            ),
            ADAPTIVE_STABLE_WINDOWS = math.max(
                1,
                math.floor(numberSetting("GPINATA_ADAPTIVE_STABLE_WINDOWS", 2))
            ),
            CONFIRM_WAIT = math.max(0.25, numberSetting("GPINATA_CONFIRM_WAIT", 1.5)),
            RETRY_DELAY = math.max(0.25, numberSetting("GPINATA_RETRY_DELAY", 1)),
            -- More than one fast retry amplified rejection bursts in testing.
            MAX_RETRIES = math.min(
                1,
                math.max(0, math.floor(numberSetting("GPINATA_MAX_RETRIES", 1)))
            ),
            STARTUP_WAIT = math.max(0, numberSetting("GPINATA_STARTUP_WAIT", 60)),
            STABLE_WAIT = math.max(0, numberSetting("GPINATA_STABLE_WAIT", 20)),
            FPS = math.max(1, numberSetting("GPINATA_FPS", 10)),
            STATUS_EVERY = math.max(1, math.floor(numberSetting("GPINATA_STATUS_EVERY", 100))),
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
                task.wait(0.1)
            end

            if completed then
                return callOk, callResult, false
            end

            local cancelled = false

            if type(task.cancel) == "function" then
                cancelled = pcall(task.cancel, invokeThread)
            end

            if not cancelled and type(coroutine.close) == "function" then
                cancelled = pcall(coroutine.close, invokeThread)
            end

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
            local module = getMapCmds()

            if type(module) ~= "table" or type(module.IsInDottedBox) ~= "function" then
                return false
            end

            local ok, result = pcall(module.IsInDottedBox)
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

        local function waitForFarmArea()
            local stableSince = nil
            local stablePosition = nil
            local waitStartedAt = os.clock()

            print(string.format(
                "[Runtime] Waiting for GScript farming area for target zone %d.",
                SETTINGS.TARGET_ZONE
            ))

            while not env.STOP_MINI_PINATA_FAST_PLACER do
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
            local ok, data = pcall(Save.Get)

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
                    .. "| retry %.2fs | amount %d",
                currentInterval,
                SETTINGS.ADAPTIVE_MIN_INTERVAL,
                SETTINGS.ADAPTIVE_MAX_INTERVAL,
                SETTINGS.RETRY_DELAY,
                initialTotal
            ))
        else
            print(string.format(
                "[Runtime] Started | interval %.2fs | retry %.2fs | amount %d",
                currentInterval,
                SETTINGS.RETRY_DELAY,
                initialTotal
            ))
        end

        local placementRunStartedAt = os.clock()
        local cycles = 0
        local confirmed = 0
        local remoteCalls = 0
        local retries = 0
        local rejected = 0
        local rejectedStreak = 0
        local failedCycles = 0
        local errors = 0
        local timeouts = 0
        local consecutiveRemoteErrors = 0
        local inventoryUnavailableSince = nil
        local lastResponse = nil
        local noItemsRemain = false

        local function recordConfirmation(amountUsed, totalAfter)
            local firstConfirmation = confirmed == 0
            confirmed += amountUsed

            if firstConfirmation or SETTINGS.VERBOSE then
                print(string.format(
                    "[Runtime] Placed | remaining %d | confirmed %d",
                    totalAfter,
                    confirmed
                ))
            end
        end

        local function printStatus()
            if cycles == 0 or cycles % SETTINGS.STATUS_EVERY ~= 0 then
                return
            end

            local elapsed = math.max(1, os.clock() - placementRunStartedAt)
            local acceptedPerHour = confirmed / elapsed * 3600
            local projectedPerDay = acceptedPerHour * 24

            print(string.format(
                "[Runtime] Status | cycles %d | confirmed %d | calls %d "
                    .. "| retries %d | rejected %d | failed %d "
                    .. "| reject streak %d | errors %d | timeouts %d "
                    .. "| interval %.2fs "
                    .. "| %.1f/hour | %.0f/day | response %s",
                cycles,
                confirmed,
                remoteCalls,
                retries,
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
                    currentInterval + SETTINGS.ADAPTIVE_STEP_UP * 2
                )
                adaptiveStableWindows = 0
                adjustmentReason = "failed cycle"
            elseif rejectRate >= SETTINGS.ADAPTIVE_HIGH_REJECT_RATE then
                currentInterval = math.min(
                    SETTINGS.ADAPTIVE_MAX_INTERVAL,
                    currentInterval + SETTINGS.ADAPTIVE_STEP_UP
                )
                adaptiveStableWindows = 0
                adjustmentReason = "high rejection pressure"
            elseif rejectRate > SETTINGS.ADAPTIVE_LOW_REJECT_RATE then
                currentInterval = math.min(
                    SETTINGS.ADAPTIVE_MAX_INTERVAL,
                    currentInterval + SETTINGS.ADAPTIVE_STEP_UP / 2
                )
                adaptiveStableWindows = 0
                adjustmentReason = "light rejection pressure"
            elseif adaptiveWindowRejected == 0 then
                adaptiveStableWindows += 1

                if adaptiveStableWindows >= SETTINGS.ADAPTIVE_STABLE_WINDOWS then
                    currentInterval = math.max(
                        SETTINGS.ADAPTIVE_MIN_INTERVAL,
                        currentInterval - SETTINGS.ADAPTIVE_STEP_DOWN
                    )
                    adaptiveStableWindows = 0
                    adjustmentReason = "stable recovery"
                end
            else
                -- One recovered rejection in a 20-cycle window is normal
                -- jitter. Hold the current rate instead of chasing noise.
                adaptiveStableWindows = 0
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
            end

            adaptiveWindowCycles = 0
            adaptiveWindowRejected = 0
            adaptiveWindowFailed = 0
        end

        while not env.STOP_MINI_PINATA_FAST_PLACER do
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
                    rejectedStreak = 0
                    nextAttemptAt = attemptStartedAt + currentInterval
                    cycleFinished = true
                elseif retryIndex < cycleRetryLimit then
                    if not waitUntil(os.clock() + SETTINGS.RETRY_DELAY) then
                        break
                    end

                    local lateTotal = getReliableTotal()

                    if lateTotal and totalBefore > 0 and lateTotal < totalBefore then
                        recordConfirmation(totalBefore - lateTotal, lateTotal)
                        cycleConfirmed = true
                        rejectedStreak = 0
                        nextAttemptAt = attemptStartedAt + currentInterval
                        cycleFinished = true
                    end
                else
                    if cycleHadServerReject then
                        rejectedStreak += 1
                    end

                    nextAttemptAt = attemptStartedAt
                        + currentInterval
                        + getRejectionBackoff(rejectedStreak)
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

                updateAdaptiveRate(cycleConfirmed, cycleHadServerReject)

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
                .. "| retries %d | rejected %d | failed %d | errors %d "
                .. "| timeouts %d | interval %.2fs",
            cycles,
            confirmed,
            remoteCalls,
            retries,
            rejected,
            failedCycles,
            errors,
            timeouts,
            currentInterval
        ))

        return noItemsRemain and "no_items" or "stopped"
    end

    local restartDelay = math.max(5, numberSetting("GPINATA_RESTART_DELAY", 15))
    local restartDelayMax = math.max(
        restartDelay,
        numberSetting("GPINATA_RESTART_DELAY_MAX", 300)
    )

    while not env.STOP_MINI_PINATA_FAST_PLACER do
        local success, result = xpcall(runEngine, function(err)
            return tostring(err)
        end)

        if success then
            break
        end

        warn(string.format(
            "[Runtime] Engine fault: %s | retrying in %.0fs",
            tostring(result),
            restartDelay
        ))

        if not supervisorWait(restartDelay) then
            break
        end

        restartDelay = math.min(restartDelay * 2, restartDelayMax)
    end

    env.__MINI_PINATA_FAST_PLACER_RUNNING = false
end)
