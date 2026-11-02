--!strict
--[[
	PocketRocket — the owner R89 daily impulse developer product (spec §3), live side. The rules
	live in Server/Retention/GiftsLogic, the numbers in Shared/Config/{GiftsConfig,
	MonetizationConfig} (product "PocketRocket", kind "PocketRocket").

	What it does:
		Init   registers with MonetizationService:
		       - the "PocketRocket" product handler (runs inside the receipt's ONE non-yielding grant
		         step, after the per-profile receipt ledger check — so a re-delivered receipt is never
		         granted twice): pays `incomeSeconds` of the buyer's automated income, at least
		         `cashFloor`, through RewardGrant.applyInReceipt (the shared cashSeconds + cashFloor
		         path, the same number the HUD previewed) and stamps profile.gifts.rocketDay = today.
		         A receipt for a player who already got today's rocket (bought just before UTC
		         midnight, a slow retry, two devices) is STILL granted: Robux are never taken for
		         nothing (counted as "rocket:late").
		       - the prompt refusal: once rocketDay == today the prompt is refused with a friendly
		         toast (the HUD offer is already hidden by then).
		Start  listens to MonetizationService.ProductGranted (after the grant is durable) for the
		       retention analytics "rocket:grant" (count), "rocket:cash" (cash paid) and
		       "rocket:late"; refused prompts count "rocket:refused".

	Security: the client only sends PromptProduct("PocketRocket", source); every amount is computed
	here from the server profile. Nothing yields inside the handler or the refusal (analytics is
	deferred out of the grant step).

	Connects to: Services/{MonetizationService, PlayerDataService}, Retention/{GiftsLogic,
	RewardGrant}, Shared/Config/{GiftsConfig, RetentionConfig}; lifecycle owned by
	Services/PlaytimeService (Init / Start call this module's Init / Start).

	Example (Studio QA):
		MonetizationService.simulateReceiptAsync(player, "PocketRocket") --> PurchaseGranted
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GiftsConfig = require(ReplicatedStorage.Shared.Config.GiftsConfig)
local GiftsLogic = require(script.Parent.GiftsLogic)
local MonetizationService = require(ServerScriptService.Server.Services.MonetizationService)
local PlayerDataService = require(ServerScriptService.Server.Services.PlayerDataService)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local RewardGrant = require(script.Parent.RewardGrant)

local PocketRocket = {}

-- Economy reason of the cash grant (analytics "earn:cash:pocketRocket").
local REASON = "pocketRocket"

-- Per receipt: what the handler paid (read once by the durable-grant listener, then dropped).
local pending: { [string]: { cash: number, late: boolean } } = {}

-- Today's UTC day number (server clock).
local function today(): number
	return RetentionConfig.utcDay(os.time())
end

--[[
	The "PocketRocket" receipt handler (MonetizationService contract: no yield, true = granted).
	@return true when the cash was paid (false → the snapshot is restored and Roblox retries)
]]
function PocketRocket.grant(player: Player, profile: any, product: any, receipt: any): boolean
	local reward: RetentionConfig.Reward = { cashSeconds = product.incomeSeconds, cashFloor = product.cashFloor }
	local day = today()
	local late = profile.gifts.rocketDay == day
	local summary = RewardGrant.applyInReceipt(player, profile, reward, REASON)
	if summary.cash <= 0 then
		return false -- nothing paid (junk config / cash cap): never ack a receipt for nothing
	end
	GiftsLogic.markRocket(profile.gifts, day)
	if type(receipt) == "table" and type(receipt.PurchaseId) == "string" then
		pending[receipt.PurchaseId] = { cash = summary.cash, late = late }
	end
	return true
end

--[[
	Prompt-time refusal (no yield): today's rocket already launched. nil = prompt allowed.
	Example: PocketRocket.refusal(player, product) --> "Your Pocket Rocket already launched today ..."
]]
function PocketRocket.refusal(player: Player, _product: any): string?
	if not GiftsConfig.RocketEnabled then
		return "This offer isn't available right now." -- kill switch (GiftsConfig.RocketEnabled)
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil -- MonetizationService already refuses unloaded profiles
	end
	local reason = GiftsLogic.promptRefusal(profile.gifts, today())
	if reason ~= nil then
		task.defer(function()
			RewardGrant.track(player, "rocket:refused")
		end)
	end
	return reason
end

function PocketRocket.Init()
	MonetizationService.registerProductHandler("PocketRocket", PocketRocket.grant)
	MonetizationService.registerPromptRefusal("PocketRocket", PocketRocket.refusal)
end

function PocketRocket.Start()
	MonetizationService.ProductGranted:Connect(function(player: Player, key: string, _robux: number, receipt: any)
		if key ~= GiftsConfig.Rocket.Product then
			return
		end
		local purchaseId = if type(receipt) == "table" then receipt.PurchaseId else nil
		local paid = if type(purchaseId) == "string" then pending[purchaseId] else nil
		if type(purchaseId) == "string" then
			pending[purchaseId] = nil
		end
		-- Counts add their amount: one key for the purchase count, one for the cash it paid.
		RewardGrant.track(player, "rocket:grant")
		if paid ~= nil then
			RewardGrant.track(player, "rocket:cash", paid.cash)
			if paid.late then
				RewardGrant.track(player, "rocket:late")
			end
		end
	end)
end

return PocketRocket
