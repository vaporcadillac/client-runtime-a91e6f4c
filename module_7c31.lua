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

task.spawn(function()
    local success, runtimeError = xpcall(function()
        local startedAt = os.clock()

        if not game:IsLoaded() then
            game.Loaded:Wait()
        end

        task.wait(5)

        local function numberSetting(name, default)
            return tonumber(env[name]) or default
        end

        local SETTINGS = {
            INTERVAL = math.max(1.5, numberSetting("GPINATA_INTERVAL", 6)),
            CONFIRM_WAIT = math.max(0.25, numberSetting("GPINATA_CONFIRM_WAIT", 1.25)),
            RETRY_DELAY = math.max(0.25, numberSetting("GPINATA_RETRY_DELAY", 0.75)),
            -- More than one fast retry only amplified server-rejection bursts.
            MAX_RETRIES = math.min(
                1,
                math.max(0, math.floor(numberSetting("GPINATA_MAX_RETRIES", 1)))
            ),
            STARTUP_WAIT = math.max(0, numberSetting("GPINATA_STARTUP_WAIT", 90)),
            STABLE_WAIT = math.max(0, numberSetting("GPINATA_STABLE_WAIT", 15)),
            FPS = math.max(1, numberSetting("GPINATA_FPS", 10)),
            STATUS_EVERY = math.max(1, math.floor(numberSetting("GPINATA_STATUS_EVERY", 10))),
            TARGET_ZONE = tonumber(env.GZONE_TO) or 39,
            CONFIRM_POLL = 0.15,
            POSITION_RADIUS = 8,
            FARM_CHECK_INTERVAL = 2,
            INVENTORY_TIMEOUT = 30,
            RETRY_DISABLE_AFTER = 2,
            VERBOSE = env.GPINATA_VERBOSE == true,
        }

        local function applyFpsCap()
            if type(setfpscap) ~= "function" then
                return
            end

            local ok, err = pcall(setfpscap, SETTINGS.FPS)

            if not ok then
                warn("[Runtime] FPS cap failed: " .. tostring(err))
            end
        end

        applyFpsCap()

        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local Players = game:GetService("Players")
        local LocalPlayer = Players.LocalPlayer
        local Library = ReplicatedStorage:WaitForChild("Library")
        local Client = Library:WaitForChild("Client")
        local Network = ReplicatedStorage:WaitForChild("Network")
        local ConsumeRemote = Network:WaitForChild("MiniPinata" .. "_Consume", 30)

        if not ConsumeRemote then
            error("[Runtime] Consume remote was not found.")
        end

        local Save = require(Client:WaitForChild("Save"))
        local MapCmds = nil

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

            print(string.format(
                "[Runtime] Waiting for GScript farming area for target zone %d.",
                SETTINGS.TARGET_ZONE
            ))

            while not env.STOP_MINI_PINATA_FAST_PLACER do
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

                    local startupReady = os.clock() - startedAt >= SETTINGS.STARTUP_WAIT

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

            repeat
                local uid, total, ready = findItemStack()

                if ready and uid then
                    return uid, total
                end

                task.wait(0.5)
            until os.clock() >= deadline or env.STOP_MINI_PINATA_FAST_PLACER

            return nil, 0
        end

        local function getReliableTotal()
            local _, total, ready = findItemStack()

            if not ready then
                return nil
            end

            return total
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

        local initialUid, initialTotal = waitForInventory()

        if not initialUid then
            error("[Runtime] No item stack was found.")
        end

        if not waitForFarmArea() then
            return
        end

        initialUid, initialTotal = waitForInventory()

        if not initialUid then
            error("[Runtime] No items remain.")
        end

        applyFpsCap()

        print(string.format(
            "[Runtime] Started | interval %.2fs | retry %.2fs | amount %d",
            SETTINGS.INTERVAL,
            SETTINGS.RETRY_DELAY,
            initialTotal
        ))

        local cycles = 0
        local confirmed = 0
        local remoteCalls = 0
        local retries = 0
        local rejected = 0
        local rejectedStreak = 0
        local errors = 0
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
            if remoteCalls % SETTINGS.STATUS_EVERY ~= 0 then
                return
            end

            print(string.format(
                "[Runtime] Status | cycles %d | confirmed %d | calls %d "
                    .. "| retries %d | rejected %d | reject streak %d "
                    .. "| errors %d | response %s",
                cycles,
                confirmed,
                remoteCalls,
                retries,
                rejected,
                rejectedStreak,
                errors,
                tostring(lastResponse)
            ))
        end

        while not env.STOP_MINI_PINATA_FAST_PLACER do
            if not getCharacterRoot() or not isInsideFarmArea() then
                if not waitForFarmArea() then
                    break
                end

                applyFpsCap()
            end

            local cycleFinished = false
            local lostFarmArea = false
            local nextAttemptAt = os.clock()
            local cycleHadServerReject = false
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

                if ready and not uid then
                    print("[Runtime] No items remain; stopping.")
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
                else
                    retries += 1
                end

                remoteCalls += 1

                local attemptStartedAt = os.clock()
                local ok, response = pcall(function()
                    return ConsumeRemote:InvokeServer(uid)
                end)

                lastResponse = response

                local didConfirm = false
                local amountUsed = 0
                local totalAfter = nil

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
                    -- Fall back to inventory confirmation only when the remote
                    -- does not return an explicit success/failure boolean.
                    didConfirm, amountUsed, totalAfter = waitForConfirmation(totalBefore)
                elseif ok and response == false then
                    -- A false response is an explicit server rejection, not a
                    -- delayed inventory confirmation or a Lua/network error.
                    rejected += 1
                    cycleHadServerReject = true
                elseif not ok then
                    errors += 1
                    warn("[Runtime] Remote failed: " .. tostring(response))
                end

                if didConfirm then
                    recordConfirmation(amountUsed, totalAfter)
                    rejectedStreak = 0
                    nextAttemptAt = attemptStartedAt + SETTINGS.INTERVAL
                    cycleFinished = true
                elseif retryIndex < cycleRetryLimit then
                    if not waitUntil(os.clock() + SETTINGS.RETRY_DELAY) then
                        break
                    end

                    local lateTotal = getReliableTotal()

                    if lateTotal and totalBefore > 0 and lateTotal < totalBefore then
                        recordConfirmation(totalBefore - lateTotal, lateTotal)
                        rejectedStreak = 0
                        nextAttemptAt = attemptStartedAt + SETTINGS.INTERVAL
                        cycleFinished = true
                    end
                else
                    if cycleHadServerReject then
                        rejectedStreak += 1
                    end

                    nextAttemptAt = attemptStartedAt + SETTINGS.INTERVAL
                    cycleFinished = true
                end

                printStatus()

                if cycleFinished then
                    break
                end
            end

            if env.STOP_MINI_PINATA_FAST_PLACER or noItemsRemain then
                break
            end

            if not lostFarmArea and cycleFinished then
                waitUntil(nextAttemptAt)
            end
        end

        print(string.format(
            "[Runtime] Stopped | cycles %d | confirmed %d | calls %d "
                .. "| retries %d | rejected %d | errors %d",
            cycles,
            confirmed,
            remoteCalls,
            retries,
            rejected,
            errors
        ))
    end, function(err)
        return tostring(err)
    end)

    env.__MINI_PINATA_FAST_PLACER_RUNNING = false

    if not success then
        warn("[Runtime] Engine stopped with error: " .. tostring(runtimeError))
    end
end)
