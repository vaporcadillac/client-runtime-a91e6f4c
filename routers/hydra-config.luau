--============================================================
-- HYDRA CONFIG — edit THIS file. That's the whole job.
-- The router reads this file; you never touch the router.
-- Change a number below, relaunch, done.
--============================================================

getgenv().HYDRA_CFG = {

    --========================================================
    -- WHAT ACCOUNT_5 DOES: "sniper" (hunts booths) or "seller" (sells)
    --========================================================
    ["ACCOUNT_5_NAME_role"] = "seller",

    --========================================================
    -- SNIPERS: items to hunt and the max price to pay.
    -- format: ["Item Name"] = max price
    --========================================================
    SniperItems = {
        ["Exclusive Raffle Ticket"] = 15000000,  -- 15m
        ["Large Gift Bag"]          = 6700,
        ["Gift Bag"]                = 1500,
        ["Pinata"]                  = 35000,
    },

    --========================================================
    -- SNIPERS: seconds parked per server before searching.
    -- this IS the teleport rhythm. 180 = calm, 20 = aggressive.
    --========================================================
    SearchInterval = 180,

    --========================================================
    -- SELLER (ACCOUNT_5_NAME when role is "seller"): items + fixed price
    --========================================================
    SellerItems = {
        ["Exclusive Raffle Ticket"] = 20600000,  -- 20.6m
        ["Charm Stone"]             = 9800,
        ["Crystal Key"]             = 8900,
    },

    --========================================================
    -- SELLER: hop to a fresh server if THIS server has 0 players
    -- for this many minutes. 0 = disabled.
    --========================================================
    SellerHopEmptyMinutes = 5,

    --========================================================
    -- FARMERS: sweep gems to ACCOUNT_5_NAME once they pass the trigger,
    -- leaving the keep-amount behind.
    --========================================================
    MailTriggerGems = 500000000,   -- 500m
    MailKeepGems    = 5000000,     -- 5m

    --========================================================
    -- FARMERS: which zone each account farms
    --========================================================
    FarmerZones = {
        ["ACCOUNT_1_NAME"] = 44,
        ["ACCOUNT_2_NAME"]       = 39,
        ["ACCOUNT_3_NAME"]    = 32,
        ["ACCOUNT_4_NAME"]           = 26,
    },

    --========================================================
    -- SECRETS — these must match your live keys (see local copy)
    --========================================================
    ZapKey      = "PASTE_YOUR_ZAPHUB_KEY_HERE",
    FleetWebhook = "PASTE_YOUR_FLEET_WEBHOOK_HERE",
    SniperWebhook = "PASTE_YOUR_SNIPER_WEBHOOK_HERE",
}
