--!nocheck
--[[
	gifts_server.luau — server-VM steps for the owner R89 gift ladder QA (tools/qa/gifts.py, ONE solo
	playtest, eval_server_runtime). Uses the same seams the admin panel uses.

		COMMAND  "prep"     resets today's ladder + the Pocket Rocket day + the favorite record,
		                    then sets today's playtime to ARGS[1] minutes; returns status()
		         "status"   status(): seconds, claimed, ready, rocketDay / today, favorite, cash
		         "rocket"   MonetizationService.simulateReceiptAsync(player, "PocketRocket", id ARGS[1])
		                    (Studio only: the REAL receipt path) → decision + cash before / after +
		                    the expected amount
		         "again"    MonetizationService.promptProduct(player, "PocketRocket", "hud") → false
		                    (refused: today's rocket already launched)
		         "repeat"   the same receipt id again → PurchaseGranted, cash unchanged (idempotent)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local Server = game:GetService("ServerScriptService").Server
local PlayerDataService = require(Server.Services.PlayerDataService)
local MonetizationService = require(Server.Services.MonetizationService)
local PlaytimeLogic = require(Server.Retention.PlaytimeLogic)
local RewardLogic = require(Server.Retention.RewardLogic)
local PlaytimeConfig = require(ReplicatedStorage.Shared.Config.PlaytimeConfig)
local GiftsConfig = require(ReplicatedStorage.Shared.Config.GiftsConfig)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)

local player = Players:GetPlayers()[1]
if player == nil then
	return "no player"
end
local profile = PlayerDataService.getProfile(player)
if profile == nil then
	return "no profile"
end
local today = RetentionConfig.utcDay(os.time())

local function status()
	local claimed = {}
	for index in profile.timeRewards.claimed do
		table.insert(claimed, index)
	end
	table.sort(claimed)
	return {
		seconds = profile.timeRewards.seconds,
		day = profile.timeRewards.day,
		today = today,
		ladder = profile.timeRewards.ladder,
		claimed = claimed,
		ready = PlaytimeConfig.readyIndices(profile.timeRewards, today),
		rocketDay = profile.gifts.rocketDay,
		favorite = profile.gifts.favorite,
		favoriteAsks = profile.gifts.favoriteAsks,
		cash = profile.cash,
		income = RewardLogic.incomeOf(profile),
		heldCrates = profile.crates and profile.crates.held or nil,
	}
end

if COMMAND == "prep" then
	PlaytimeLogic.reset(profile.timeRewards, today)
	PlaytimeLogic.setSeconds(profile.timeRewards, (ARGS[1] or 12) * 60, today)
	profile.gifts.rocketDay = -1
	profile.gifts.favorite = GiftsConfig.FavoriteState.None
	profile.gifts.favoriteAsks = 0
	PlayerDataService.markChanged(player, false, { "timeRewards", "gifts" })
	return HttpService:JSONEncode(status())
elseif COMMAND == "status" then
	return HttpService:JSONEncode(status())
elseif COMMAND == "rocket" or COMMAND == "repeat" then
	local before = profile.cash
	local expected = RewardLogic.cashFor(GiftsConfig.rocketReward(), RewardLogic.incomeOf(profile))
	-- ARGS[1] = the run id (one receipt id per run; "repeat" re-sends the same id).
	local purchaseId = `qa-gifts-rocket-{math.floor(ARGS[1] or 1)}`
	-- The grant itself, from the economy signal (reason "pocketRocket"), so producer income that
	-- lands while the receipt commits does not blur the check.
	local granted = 0
	local connection = PlayerDataService.CurrencyChanged:Connect(function(who, currency, amount, reason)
		if who == player and currency == "cash" and reason == "pocketRocket" then
			granted += amount
		end
	end)
	local decision = MonetizationService.simulateReceiptAsync(player, "PocketRocket", purchaseId)
	task.wait(0.5) -- RewardGrant.announce is deferred
	connection:Disconnect()
	local result = status()
	result.decision = tostring(decision)
	result.cashBefore = before
	result.granted = granted
	result.expected = expected
	-- The same income rule on both sides; doubles this large differ only in the last bits.
	result.exact = math.abs(granted - expected) <= expected * 1e-9
	return HttpService:JSONEncode(result)
elseif COMMAND == "again" then
	local opened = MonetizationService.promptProduct(player, "PocketRocket", "hud")
	return HttpService:JSONEncode({ prompted = opened, rocketDay = profile.gifts.rocketDay, today = today })
end
return "unknown command"
