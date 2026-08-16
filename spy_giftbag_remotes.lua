-- Remote spy: run this ONCE with GScript's auto-open ENABLED and
-- gift bags in inventory. It logs every remote call whose name mentions
-- gift/bag/open/use, plus the exact Inventory.Misc ids for the bags.
-- Send the console output back, then disable GScript auto-open.

local seen = {}

local function dump(value, depth)
    depth = depth or 0

    if depth > 3 then
        return "..."
    end

    if type(value) == "table" then
        local parts = {}

        for key, item in pairs(value) do
            if #parts >= 8 then
                table.insert(parts, "...")
                break
            end

            table.insert(parts, tostring(key) .. "=" .. dump(item, depth + 1))
        end

        return "{" .. table.concat(parts, ", ") .. "}"
    end

    if type(value) == "string" then
        return string.format("%q", value)
    end

    return tostring(value)
end

local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
    local method = getnamecallmethod()
    local lowered = string.lower(self.Name)

    if method == "InvokeServer" or method == "FireServer" then
        if string.find(lowered, "gift")
            or string.find(lowered, "bag")
            or (string.find(lowered, "open") and not string.find(lowered, "door"))
        then
            local args = table.pack(...)
            local parts = {}

            for index = 1, args.n do
                table.insert(parts, dump(args[index]))
            end

            local line = string.format(
                "[SPY] %s %s | args: %s",
                method,
                self:GetFullName(),
                table.concat(parts, ", ")
            )

            if not seen[line] then
                seen[line] = true
                print(line)

                if rconsoleinfo then
                    rconsoleinfo(line)
                end
            end
        end
    end

    return oldNamecall(self, ...)
end)

print("[SPY] Hooked. Waiting for GScript to open bags...")

-- Also dump the save's bag entries so we learn the exact ids/stack shape.
task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    task.wait(5)

    local ok, data = pcall(function()
        local Library = game:GetService("ReplicatedStorage"):WaitForChild("Library")
        local Save = require(Library.Client.Save)
        return Save.Get()
    end)

    if not ok or type(data) ~= "table" then
        warn("[SPY] Save fetch failed: " .. tostring(data))
        return
    end

    local misc = data.Inventory and data.Inventory.Misc

    if type(misc) ~= "table" then
        warn("[SPY] Inventory.Misc unavailable.")
        return
    end

    for uid, entry in pairs(misc) do
        local id = type(entry) == "table"
            and tostring(entry.id or entry._id or entry.ID or "?")
            or "?"
        local lowered = string.lower(id)

        if string.find(lowered, "gift") or string.find(lowered, "bag") or string.find(lowered, "pinata") then
            print(string.format("[SPY] Inventory.Misc %s -> %s", dump(uid), dump(entry, 2)))
        end
    end
end)
