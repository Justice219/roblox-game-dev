--!strict
--[[
	ShopService — grants for the shop's packs and cash products (design spec §11; layout and pack
	contents in Shared/Config/ShopConfig, prices / ids in MonetizationConfig).

	Product handlers (registered in Init; each runs inside MonetizationService's no-yield grant
	step, applies everything or nothing, and is saved with the receipt record):
		"StarterPack"  ShopConfig.StarterPack.reward + profile.starter.bought = true
		"SecretPack"   ShopConfig.SecretPack.reward  + profile.secretPack.bought = true
	A one-time pack bought a second time (a prompt race) is still granted: the player paid.
	PAID RANDOM ITEMS: the packs are on sale for everyone, but their Lucky Spins are paid random
	items. RewardLogic.robuxReward decides per buyer at the receipt (no yield): policy KNOWN and
	unrestricted → the spins go to the gated PAID bank; restricted OR unknown (fail closed) → each
	spin is paid as LuckySpinConfig.GemsPerSpin gems instead (the pack card shows this).
	Analytics: retention "pack:spins:<spins|gems>".
	("Gems" are built into MonetizationService; "Cash" packs belong to B5's TycoonService, which
	knows the player's live income; this screen only displays them.)

	Secret Pack global stock (ShopConfig.Stock):
		- after a SecretPack grant is durable (MonetizationService.ProductGranted) the PurchaseId is
		  counted ONCE in the cross-server DataStore record (StockLogic.count inside UpdateAsync,
		  retried; "<StoreName>_Studio" in Studio);
		- a loop re-reads the count every RefreshSeconds (1 GetAsync / min / server) and publishes
		  ReplicatedStorage attributes SecretPackSold / SecretPackLimit / SecretPackAt;
		- prompt refusal: sold out → "Sold out!", count never read (no DataStore) → "Stock is
		  updating - try again soon!" (never sell blind).

	Public API: stock() → { sold, limit, known }, refreshStockAsync(), useStoreForTests(store).
	Example: ShopService.stock() --> { sold = 12, limit = 500, known = true }
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AdminHooks = require(ServerScriptService.Server.Retention.AdminHooks)
local LuckySpinConfig = require(ReplicatedStorage.Shared.Config.LuckySpinConfig)
local MonetizationService = require(script.Parent.MonetizationService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RewardGrant = require(ServerScriptService.Server.Retention.RewardGrant)
local RewardLogic = require(ServerScriptService.Server.Retention.RewardLogic)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local StockLogic = require(ServerScriptService.Server.Retention.StockLogic)

local ShopService = {}

-- Retry policy for the post-grant stock count (a missed count is retried in the background).
local COUNT_ATTEMPTS = 5
local COUNT_RETRY_SECONDS = 5

local stock = { sold = 0, known = false, at = 0 }
local storeOverride: any = nil
local storeCache: any = nil

-- The stock DataStore (nil when DataStores are unavailable).
local function stockStore(): any
	if storeOverride ~= nil then
		return storeOverride
	end
	if storeCache ~= nil then
		return storeCache
	end
	local name = if RunService:IsStudio() then ShopConfig.Stock.StoreName .. "_Studio" else ShopConfig.Stock.StoreName
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(name)
	end)
	if ok then
		storeCache = store
		return store
	end
	return nil
end

-- Publishes the stock as ReplicatedStorage attributes (the Shop card reads them).
local function publish()
	ReplicatedStorage:SetAttribute(ShopConfig.Stock.SoldAttribute, stock.sold)
	ReplicatedStorage:SetAttribute(ShopConfig.Stock.LimitAttribute, ShopConfig.Stock.Limit)
	ReplicatedStorage:SetAttribute(ShopConfig.Stock.AtAttribute, if stock.known then stock.at else 0)
end

--[[ The Secret Pack stock as last read. ]]
function ShopService.stock(): { sold: number, limit: number, known: boolean }
	return { sold = stock.sold, limit = ShopConfig.Stock.Limit, known = stock.known }
end

--[[ Re-reads the stock count (yields). @return true when the read succeeded ]]
function ShopService.refreshStockAsync(): boolean
	local store = stockStore()
	if store == nil then
		return false
	end
	local ok, value = pcall(function()
		return store:GetAsync(ShopConfig.Stock.Key)
	end)
	if not ok then
		return false
	end
	stock.sold = StockLogic.read(value)
	stock.known = true
	stock.at = os.time()
	publish()
	return true
end

-- Counts one durable Secret Pack purchase in the global record (idempotent; yields; retried).
local function countSale(purchaseId: string)
	for attempt = 1, COUNT_ATTEMPTS do
		local store = stockStore()
		if store ~= nil then
			local ok, err = pcall(function()
				store:UpdateAsync(ShopConfig.Stock.Key, function(old: unknown): any
					local record = StockLogic.count(old, purchaseId)
					return record
				end)
			end)
			if ok then
				ShopService.refreshStockAsync()
				return
			end
			warn(`[ShopService] stock count for {purchaseId} failed (attempt {attempt}): {err}`)
		end
		task.wait(COUNT_RETRY_SECONDS)
	end
end

--[[ Studio tests: route the stock to a mock store (nil restores the real one). ]]
function ShopService.useStoreForTests(store: any)
	if RunService:IsStudio() then
		storeOverride = store
		stock.known = false
	end
end

-- A one-time pack handler: reward + flag, in the receipt's grant step. The spins follow the
-- buyer's paid-random policy (see the header; never decided on an unknown answer).
local function packHandler(flagField: "starter" | "secretPack", reward: any, reason: string)
	return function(player: Player, profile, _product, _receipt): boolean
		local allowPaidRandom = PlayerDataService.isPolicyKnown(player)
			and not PlayerDataService.isPaidRandomRestricted(player)
		local granted, options = RewardLogic.robuxReward(reward, allowPaidRandom, LuckySpinConfig.GemsPerSpin)
		RewardGrant.applyInReceipt(player, profile, granted, reason, options)
		if reward.spins ~= nil then
			RewardGrant.track(player, if allowPaidRandom then "pack:spins:spins" else "pack:spins:gems")
		end
		if flagField == "starter" then
			profile.starter.bought = true
		else
			profile.secretPack.bought = true
		end
		return true
	end
end

function ShopService.Init()
	-- B7's owner-admin commands (B14 AdminService, guarded; ShopService is the last B7 service).
	AdminHooks.install()
	MonetizationService.registerProductHandler(
		"StarterPack",
		packHandler("starter", ShopConfig.StarterPack.reward, "starterPack")
	)
	MonetizationService.registerProductHandler(
		"SecretPack",
		packHandler("secretPack", ShopConfig.SecretPack.reward, "secretPack")
	)
	MonetizationService.registerPromptRefusal("SecretPack", function(_player, _product): string?
		if not stock.known then
			return "Stock is updating - try again soon!"
		end
		if stock.sold >= ShopConfig.Stock.Limit then
			return "Sold out! Every Secret Pack has been claimed."
		end
		return nil
	end)
end

function ShopService.Start()
	publish()
	MonetizationService.ProductGranted:Connect(function(_player: Player, key: string, _robux: number, receipt)
		if key == "SecretPack" then
			task.spawn(countSale, receipt.PurchaseId)
		end
	end)
	task.spawn(function()
		while true do
			ShopService.refreshStockAsync()
			task.wait(ShopConfig.Stock.RefreshSeconds)
		end
	end)
end

return ShopService
