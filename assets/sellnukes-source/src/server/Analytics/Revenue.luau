--!strict
--[[
	Revenue — Robux revenue, the purchase funnel and offer impressions (ported from RoBeasts'
	AnalyticsService revenue half: promptShown → promptFinished → robuxPurchase / passPurchase,
	PromptAttribution, durable receipt accounting).

	Funnel per product / pass key (revenue family; "funnel:<key>:<step>"):
		shown    an offer card for the key was rendered (OffersSeen) or announced by the server
		click    the player pressed BUY on an offer surface (owner R137): promptRequested, fed by
		         MonetizationService.PromptRequested — every PromptProduct / PromptPass request that
		         passed the prompt rate limit + key check, BEFORE any prompt refusal — counted for
		         the offer sources only (AnalyticsConfig.OfferClicks: shop / offer / welcomeBack),
		         capped per session, a double tap on the same offer within RepeatSeconds = one
		         press. Server code can also call offerClicked(player, id) directly (trusted).
		prompt   MonetizationService opened Roblox's purchase prompt (PromptShown)
		bought   the purchase completed (receipt accounting / PassPurchased)
	Every completed purchase is credited to the source of its latest prompt (PromptAttribution:
	"purchase:<key>:<source>", "robuxBySource:<source>"), and split by device, tycoon area and
	rebirth tier. Abandoned prompts count "promptClosed*" plus their dwell bucket.

	Durable developer-product accounting (MonetizationService.setReceiptAccounting):
		onGrant   (no yield, same profile commit as the grant) capture the facts (product, Robux,
		          day, prompt source, device, area, rebirths, staff), mark the payer-day bitmap
		          (ReceiptAccounting.finalize) and park the record in profile.analytics.outbox.
		onDurable (own thread, may yield) ReceiptJournal.complete: one UpdateAsync inserts the
		          PurchaseId and adds the receipt's counters (idempotent; a replay never counts
		          twice), then the outbox entry is removed. Failed attempts stay in the outbox and
		          are retried at every flush (drainOutboxes) and on the next profile load.
		Studio / no DataStore: the record's counters go straight into this server's Recorder so
		playtests still see revenue (never written; Studio never writes).

	Connects to: MonetizationService signals (AnalyticsService.Start wires them), Runtime,
	Recorder, Sessions.markPayer (passes), PromptAttribution, ReceiptAccounting, Flusher.store,
	AnalyticsLogic (offersSeen, offerClick), MonetizationConfig (offer ids, product kinds).

	Example:
		Revenue.promptRequested(player, "StarterPack", "StarterPack", "shop") -- BUY pressed: click
		Revenue.promptShown(player, "StarterPack", "StarterPack", "shop")
		Revenue.promptFinished(player, "StarterPack", "StarterPack", false)  -- closed: promptClosed:*
		MonetizationService.setReceiptAccounting(Revenue.accountingHooks())
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local AnalyticsLogic = require(script.Parent.AnalyticsLogic)
local Flusher = require(script.Parent.Flusher)
local PromptAttribution = require(script.Parent.PromptAttribution)
local ReceiptAccounting = require(script.Parent.ReceiptAccounting)
local Recorder = require(script.Parent.Recorder)
local Runtime = require(script.Parent.Runtime)
local Sessions = require(script.Parent.Sessions)

type Profile = Runtime.Profile

local Revenue = {}

local count = Recorder.count
local key = AnalyticsLogic.key

-- Per-player prompt memory (strong keys; dropped by `forget` at leave).
local promptMemory: { [Player]: PromptAttribution.Memory } = {}
-- Per-player Roblox funnel attempt ids (key → guid), bounded like the prompt memory.
local funnelIds: { [Player]: { [string]: string } } = {}
-- Game pass list prices fetched from the web (passId → { price, at }).
local passPrices: { [number]: { price: number, at: number } } = {}
local PASS_PRICE_TTL = 600
-- OffersSeen token bucket (1–2 honest reports per offer surface visit).
local offersLimiter = RateLimiter.new(AnalyticsConfig.OffersSeen.Burst, AnalyticsConfig.OffersSeen.PerSecond)
-- R137 offer BUY press bucket (defence in depth behind MonetizationService's prompt limiter).
local clickLimiter = RateLimiter.new(AnalyticsConfig.OfferClicks.Burst, AnalyticsConfig.OfferClicks.PerSecond)
-- Core keys of a refused offer BUY press (+ ":<reason>", AnalyticsConfig.ClientRefusalReasons).
local CLICK_REFUSED = "ops:clientRefused:OfferClick"
-- True once MonetizationService runs our durable accounting (ProductGranted then counts nothing).
local accountingInstalled = false

--[[ A prompt source folded into MonetizationService's allowlist (nil → "none"). ]]
local function sourceOf(raw: unknown): string
	if raw == nil then
		return AnalyticsConfig.Sales.NoSource
	end
	return AnalyticsLogic.pick(AnalyticsConfig.PromptSources, raw, "other")
end

--[[ True when `id` is a product or pass key of the catalogue (offer ids are catalogue keys). ]]
function Revenue.isOfferId(id: string): boolean
	return MonetizationConfig.getProduct(id) ~= nil or MonetizationConfig.getPass(id) ~= nil
end

-- The buyer's rebirth bucket label.
local function rebirthBucket(player: Player?): string
	return AnalyticsLogic.countBucket(Runtime.rebirthsOf(player), AnalyticsConfig.Tycoon.RebirthBuckets)
end

--[[
	The server opened a purchase prompt (MonetizationService.PromptShown). Counts the prompt by
	key, source and device, the funnel's prompt step, and remembers the source for the purchase.
]]
Revenue.promptShown = Runtime.economyGuard(
	"promptShown",
	function(player: Player, itemKey: string, _kind: string, source: string?)
		if type(itemKey) ~= "string" then
			return
		end
		local cleanSource = sourceOf(source)
		local device = Runtime.deviceOf(player) or "unknown"
		count("revenue", key("prompt", itemKey))
		count("revenue", key("prompt", itemKey, cleanSource))
		count("revenue", key("promptDevice", itemKey, device))
		count("revenue", key("funnel", itemKey, "prompt"))
		local memory = promptMemory[player]
		if memory == nil then
			if Runtime.sessions[player] == nil then
				return
			end
			memory = PromptAttribution.new()
			promptMemory[player] = memory
		end
		PromptAttribution.remember(memory, AnalyticsLogic.part(itemKey), cleanSource, os.clock(), nil)
		-- Roblox purchase funnel: step 1 "Prompted" (a fresh attempt id per prompt).
		local ids = funnelIds[player]
		if ids == nil then
			ids = {}
			funnelIds[player] = ids
		end
		local attempt = Sessions.funnelSessionId()
		if ids[itemKey] == nil then
			local n = 0
			for _ in ids do
				n += 1
			end
			if n >= AnalyticsConfig.Sales.MaxPromptsPerPlayer then
				table.clear(ids)
			end
		end
		ids[itemKey] = attempt
		local live = Runtime.livePlayer(player)
		if live ~= nil then
			Runtime.forwarder.funnel(live, "Purchase", attempt, 1, "Prompted")
		end
	end
)

--[[
	Roblox closed a purchase prompt (MonetizationService.PromptFinished). A close WITHOUT a purchase
	of a prompt THIS server opened counts promptClosed:<key>[:<source>], by device and dwell.
]]
Revenue.promptFinished = Runtime.economyGuard(
	"promptFinished",
	function(player: Player, itemKey: string, _kind: string, bought: boolean)
		local memory = promptMemory[player]
		if memory == nil or type(itemKey) ~= "string" then
			return
		end
		local source, dwell = PromptAttribution.finish(memory, AnalyticsLogic.part(itemKey), bought == true, os.clock())
		if source == nil then
			return
		end
		local device = Runtime.deviceOf(player) or "unknown"
		count("revenue", key("promptClosed", itemKey))
		count("revenue", key("promptClosed", itemKey, source))
		count("revenue", key("promptClosedDevice", itemKey, device))
		if dwell ~= nil then
			count("revenue", key("promptDwell", source, device, AnalyticsLogic.dwellBucket(dwell)))
		end
	end
)

--[[ The source to credit a completed purchase with (consumes the remembered prompt). ]]
local function takeSource(player: Player?, itemKey: string): string
	local memory = if player ~= nil then promptMemory[player] else nil
	if memory == nil then
		return AnalyticsConfig.Sales.Unknown
	end
	return PromptAttribution.take(memory, AnalyticsLogic.part(itemKey), os.clock())
end

-- Roblox purchase funnel step 2 for the key's latest prompt (once).
local function forwardBought(player: Player?, itemKey: string)
	local ids = if player ~= nil then funnelIds[player] else nil
	local attempt = if ids ~= nil then ids[itemKey] else nil
	local live = Runtime.livePlayer(player)
	if attempt ~= nil and live ~= nil and ids ~= nil then
		ids[itemKey] = nil
		Runtime.forwarder.funnel(live, "Purchase", attempt, 2, "Purchased")
	end
end

--[[
	Captures the facts of a developer-product receipt (no yield). Consumes the prompt attribution.
	@return a ReceiptAccounting.Record (ready = false until finalize)
]]
function Revenue.prepareRecord(player: Player?, profile: Profile?, product: any, receipt: any): ReceiptAccounting.Record
	local itemKey = if type(product) == "table" and type(product.key) == "string" then product.key else "unknown"
	local kind = if type(product) == "table" and type(product.kind) == "string" then product.kind else "unknown"
	local robux = if type(receipt) == "table" then tonumber(receipt.CurrencySpent) or 0 else 0
	if robux <= 0 and type(product) == "table" then
		robux = tonumber(product.price) or 0 -- Roblox did not report it: the catalogue price
	end
	local productId = if type(receipt) == "table" then tonumber(receipt.ProductId) or 0 else 0
	local gems = if type(product) == "table" and kind == "Gems" then tonumber(product.gems) or 0 else 0
	return {
		day = Recorder.today(),
		userId = if player ~= nil then player.UserId else 0,
		productId = math.max(1, math.floor(productId)),
		product = AnalyticsLogic.part(itemKey),
		kind = AnalyticsLogic.part(kind),
		robux = math.clamp(math.floor(robux), 0, 1e9),
		source = AnalyticsLogic.part(takeSource(player, itemKey)),
		device = Runtime.deviceOf(player) or "unknown",
		area = Runtime.areaOf(player),
		rebirths = Runtime.rebirthsOf(player),
		staff = Runtime.isStaff(player),
		payEligible = player ~= nil and profile ~= nil and Runtime.canMark(player, profile),
		ready = false,
		gems = math.clamp(math.floor(gems), 0, 1e9),
	}
end

-- Counts a finalized record straight into this server's Recorder (Studio / memory mode).
local function countRecordLocally(record: ReceiptAccounting.Record)
	for family, counters in ReceiptAccounting.counters(record) do
		for metric, amount in counters do
			Recorder.countOn(record.day, family, metric, amount)
		end
	end
end

-- The live-only side effects of a completed product purchase (never replayed on recovery).
local function liveSuccess(player: Player?, record: ReceiptAccounting.Record)
	if player == nil or record.staff then
		return
	end
	Runtime.markFirstDay(player, "pay")
	forwardBought(player, record.product)
	local live = Runtime.livePlayer(player)
	if live ~= nil and record.gems > 0 then
		local profile = Runtime.profileOf(live)
		local balance = if profile ~= nil then tonumber(profile.gems) or 0 else 0
		Runtime.forwarder.economy(live, "Source", "Gems", record.gems, balance, "IAP", record.product)
	end
end

--[[
	Journals one finalized outbox record (yields). Removes it from the outbox on success, or in
	Studio / memory mode after counting it locally. Returns true when the entry is settled.
]]
local function journal(player: Player?, profile: Profile, purchaseId: string): boolean
	local data = profile.analytics
	local outbox = if type(data) == "table" then data.outbox else nil
	if type(outbox) ~= "table" then
		return true
	end
	local record = ReceiptAccounting.read(outbox[purchaseId])
	if record == nil or not record.ready then
		-- Malformed or never finalized: nothing trustworthy to count; drop it.
		outbox[purchaseId] = nil
		return true
	end
	local store = Flusher.store()
	local settled = false
	if RunService:IsStudio() or store == nil or not Flusher.writesEnabled() then
		countRecordLocally(record)
		settled = true
	else
		settled = (store :: any).recordReceipt(purchaseId, record) == true
	end
	if settled then
		-- Re-check: the profile may have been released while the journal yielded.
		if (profile.analytics :: any).outbox == outbox then
			outbox[purchaseId] = nil
			if player ~= nil and Runtime.canMark(player, profile) then
				Runtime.saveMarks(player)
			end
		end
	end
	return settled
end

--[[
	The accounting hooks for MonetizationService.setReceiptAccounting:
		onGrant(player, profile, product, receipt)    no yield; same commit as the grant
		onDurable(player, profile, product, receipt)  own thread; journals the record
]]
function Revenue.accountingHooks(): { onGrant: (any, any, any, any) -> (), onDurable: (any, any, any, any) -> () }
	return {
		onGrant = function(player: any, profile: any, product: any, receipt: any)
			if type(profile) ~= "table" or type(receipt) ~= "table" or type(receipt.PurchaseId) ~= "string" then
				return
			end
			local buyer = Runtime.asPlayer(player)
			local data = Runtime.dataOf(buyer)
			if data == nil or Runtime.profileOf(buyer) ~= profile then
				return
			end
			local purchaseId = receipt.PurchaseId :: string
			if #purchaseId < 1 or #purchaseId > 64 or data.outbox[purchaseId] ~= nil then
				return
			end
			local record = Revenue.prepareRecord(buyer, profile, product, receipt)
			ReceiptAccounting.finalize(record, data :: any, record.gems)
			if record.payer then
				data.payLast = math.max(data.payLast, record.day)
			end
			data.robux = math.min(1e9, data.robux + record.robux)
			-- A flat record of primitives (MonetizationService's outbox reconcile keeps exactly that).
			local flat: { [string]: string | number | boolean } = {}
			for field, value in record :: any do
				if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
					flat[field] = value
				end
			end
			data.outbox[purchaseId] = flat
		end,
		onDurable = function(player: any, profile: any, _product: any, receipt: any)
			if type(profile) ~= "table" or type(receipt) ~= "table" or type(receipt.PurchaseId) ~= "string" then
				return
			end
			local buyer = Runtime.asPlayer(player)
			local data = profile.analytics
			local raw = if type(data) == "table" and type(data.outbox) == "table"
				then data.outbox[receipt.PurchaseId]
				else nil
			local record = ReceiptAccounting.read(raw)
			if record ~= nil and record.ready then
				liveSuccess(buyer, record)
			end
			journal(buyer, profile, receipt.PurchaseId)
		end,
	}
end

--[[
	Marks the durable accounting as installed in MonetizationService (ProductGranted then counts
	nothing itself: the journal does). Called by AnalyticsService.Start after setReceiptAccounting.
]]
function Revenue.setAccountingInstalled(installed: boolean)
	accountingInstalled = installed
end

--[[
	Retries the outbox of every online player (each flush) and of a freshly loaded profile:
	finalized records whose journal write failed earlier. Yields (journal writes); bounded by the
	outbox size (MonetizationService keeps it bounded).
]]
function Revenue.drainOutbox(player: Player, profile: Profile)
	local data = profile.analytics
	if type(data) ~= "table" or type(data.outbox) ~= "table" then
		return
	end
	local ids: { string } = {}
	for purchaseId in data.outbox do
		if type(purchaseId) == "string" then
			table.insert(ids, purchaseId)
		end
	end
	for _, purchaseId in ids do
		if not journal(player, profile, purchaseId) then
			break -- storage trouble: try again next flush
		end
	end
end

--[[ Flush hook: drains every online player's outbox (only when there is something to drain). ]]
function Revenue.drainOutboxes()
	for player in Runtime.sessions do
		local profile = Runtime.profileOf(player)
		local data = if profile ~= nil then profile.analytics else nil
		if profile ~= nil and type(data) == "table" and type(data.outbox) == "table" and next(data.outbox) ~= nil then
			Revenue.drainOutbox(player, profile)
		end
	end
end

--[[
	A developer product was granted (MonetizationService.ProductGranted, after the grant is
	durable). With durable accounting installed the counters come from the journal, so this only
	runs the live extras; without it (accounting off) it counts the sale itself.
]]
Revenue.productGranted = Runtime.economyGuard(
	"productGranted",
	function(player: Player, itemKey: string, robux: number, receipt: any)
		if accountingInstalled then
			return
		end
		local product = MonetizationConfig.getProduct(itemKey)
		local profile = Runtime.profileOf(player)
		local record = Revenue.prepareRecord(player, profile, product or { key = itemKey, kind = "unknown" }, {
			CurrencySpent = robux,
			ProductId = if type(receipt) == "table" then receipt.ProductId else 0,
		})
		local payer, first = Sessions.markPayer(player, profile, record.robux)
		record.payer, record.newPayer, record.ready = payer, first, true
		countRecordLocally(record)
		liveSuccess(player, record)
	end
)

-- A game pass list price (cached; yields on a miss). 0 when unknown.
local function passPriceAsync(passId: number): number
	local cached = passPrices[passId]
	if cached ~= nil and os.clock() - cached.at < PASS_PRICE_TTL then
		return cached.price
	end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfoAsync(passId, Enum.InfoType.GamePass)
	end)
	local price = 0
	if ok and type(info) == "table" then
		local raw = (info :: { [string]: unknown }).PriceInRobux
		if type(raw) == "number" and raw == raw and raw > 0 and raw < 1e9 then
			price = math.floor(raw)
		end
	end
	passPrices[passId] = { price = price, at = os.clock() }
	return price
end

--[[
	A game pass bought in this server (MonetizationService.PassPurchased, once per new ownership).
	`robux` = the catalogue price MonetizationService knows; 0 → looked up off-thread.
]]
Revenue.passPurchased = Runtime.economyGuard("passPurchased", function(player: Player, passKey: string, robux: number)
	if type(passKey) ~= "string" then
		return
	end
	local day = Recorder.today()
	local source = takeSource(player, passKey)
	local device = Runtime.deviceOf(player) or "unknown"
	local area = tostring(Runtime.areaOf(player))
	local tier = rebirthBucket(player)
	local profile = Runtime.profileOf(player)
	local function countPrice(price: number)
		local cleanPrice = math.clamp(math.floor(price), 0, 1e9)
		local _, first = Sessions.markPayer(player, profile, cleanPrice)
		Recorder.countOn(day, "revenue", "purchases", 1)
		Recorder.countOn(day, "revenue", key("pass", passKey, "count"), 1)
		Recorder.countOn(day, "revenue", key("purchase", passKey, source), 1)
		Recorder.countOn(day, "revenue", key("purchaseDevice", passKey, device), 1)
		Recorder.countOn(day, "revenue", key("buyArea", area), 1)
		Recorder.countOn(day, "revenue", key("funnel", passKey, "bought"), 1)
		if first then
			Recorder.countOn(day, "revenue", key("firstBuy", passKey), 1)
		end
		if cleanPrice > 0 then
			Recorder.countOn(day, "revenue", "robux", cleanPrice)
			Recorder.countOn(day, "revenue", key("pass", passKey, "robux"), cleanPrice)
			Recorder.countOn(day, "revenue", "kind:GamePass:robux", cleanPrice)
			Recorder.countOn(day, "revenue", key("robuxBySource", source), cleanPrice)
			Recorder.countOn(day, "revenue", key("robuxByDevice", device), cleanPrice)
			Recorder.countOn(day, "revenue", key("robuxByArea", area), cleanPrice)
			Recorder.countOn(day, "revenue", key("robuxByRebirth", tier), cleanPrice)
		end
	end
	Runtime.markFirstDay(player, "pay")
	forwardBought(player, passKey)
	local price = if type(robux) == "number" and robux == robux and robux > 0 then robux else 0
	if price > 0 then
		countPrice(price)
		return
	end
	local pass = MonetizationConfig.getPass(passKey)
	local passId = if pass ~= nil then pass.id else 0
	if passId <= 0 then
		countPrice(0)
		return
	end
	-- Web lookup off the gameplay thread; the purchase day was captured above.
	task.spawn(function()
		countPrice(passPriceAsync(passId))
	end)
end)

--[[ A server-side offer impression (e.g. a starburst popup announced by the server). ]]
Revenue.offerShown = Runtime.economyGuard("offerShown", function(_player: Player, offerId: string)
	if type(offerId) == "string" and Revenue.isOfferId(offerId) then
		count("revenue", key("offer", offerId, "shown"))
		count("revenue", key("funnel", offerId, "shown"))
	end
end)

--[[
	Counts one BUY press on offer `offerId` (an id Revenue.isOfferId accepted): the "Offer
	impressions and clicks" CTR numerator and the purchase funnel's click step.
]]
local function countClick(offerId: string)
	count("revenue", key("offer", offerId, "click"))
	count("revenue", key("funnel", offerId, "click"))
end

-- Counts one refused offer BUY press: the base key + its reason (ClientRefusalReasons).
local function refuseClick(reason: string)
	count("core", CLICK_REFUSED)
	count("core", `{CLICK_REFUSED}:{reason}`)
end

--[[
	The player pressed BUY on an offer (server-side observation of the intent, before the prompt).
	For TRUSTED server callers (a server-driven offer); client-originated presses arrive through
	promptRequested, which adds the per-session cap, double-tap merge and token bucket.
	Example: AnalyticsService.offerClicked(player, "VIP")
]]
Revenue.offerClicked = Runtime.economyGuard("offerClicked", function(_player: Player, offerId: string)
	if type(offerId) == "string" and Revenue.isOfferId(offerId) then
		countClick(offerId)
	end
end)

--[[
	Owner R137: a purchase prompt was REQUESTED (MonetizationService.PromptRequested — the client's
	PromptProduct / PromptPass intent after the prompt rate limit and the catalogue-key check,
	BEFORE any prompt refusal). When the request came from an offer surface
	(AnalyticsConfig.OfferClicks.Sources) it is the funnel's "click": the player pressed BUY,
	whether or not Roblox's prompt then opens. Other sources (pads, wheel, attack, lucky, ...) are
	not offer cards and count nothing here (their prompt step still counts in promptShown).
	Untrusted inputs (they came from a remote): own token bucket, AnalyticsLogic.offerClick
	(typeof / length / allowlisted offer id / per-session cap / double-tap merge). Refusals count
	core ops:clientRefused:OfferClick + ops:clientRefused:OfferClick:<reason>. Counts only: nothing
	is granted, prompted or shown because of this. Staff / New Player Mode are diverted
	(economyGuard).
	@param itemKey product / pass key (MonetizationService validated it against the catalogue)
	@param _kind   product kind, or "pass" (unused; kept for the signal's shape)
	@param source  PurchasePromptConfig source (MonetizationService folded it; unknown → "other")
	Example: Revenue.promptRequested(player, "StarterPack", "StarterPack", "offer") -- funnel click
]]
Revenue.promptRequested = Runtime.economyGuard(
	"promptRequested",
	function(player: Player, itemKey: string, _kind: string, source: string?)
		local info = Runtime.sessions[player]
		if info == nil or not AnalyticsLogic.isOfferClickSource(source) then
			return
		end
		if not clickLimiter:Allow(player.UserId) then
			refuseClick("rate")
			return
		end
		local offerId, refusal =
			AnalyticsLogic.offerClick(info.offersSeen, itemKey, source, os.clock(), Revenue.isOfferId)
		if offerId ~= nil then
			countClick(offerId)
		elseif refusal ~= nil then
			refuseClick(refusal)
		end
	end
)

--[[
	OffersSeen (C→S): offers a surface actually rendered. Untrusted: token bucket →
	AnalyticsLogic.offersSeen (allowlists, per-session caps). Counts only.
	@return number of keys counted (tests)
]]
function Revenue.onOffersSeen(player: Player, rawSource: unknown, rawCards: unknown, rawNew: unknown): number
	local info = Runtime.sessions[player]
	if info == nil then
		return 0
	end
	if not offersLimiter:Allow(player.UserId) then
		count("core", "ops:clientRefused:OffersSeen")
		return 0
	end
	if Runtime.isExcluded(player) then
		return 0
	end
	local keys = AnalyticsLogic.offersSeen(info.offersSeen, rawSource, rawCards, rawNew, Revenue.isOfferId)
	for _, metric in keys do
		count("revenue", metric)
		local card = string.match(metric, "^offers:card:(.+)$")
		if card ~= nil then
			count("revenue", key("funnel", card, "shown"))
		end
	end
	if rawNew == true and #keys > 0 then
		Runtime.markUnique(player, "offers")
	end
	return #keys
end

--[[ Drops the player's prompt memory and limiter states (PlayerRemoving). ]]
function Revenue.forget(player: Player)
	promptMemory[player] = nil
	funnelIds[player] = nil
	offersLimiter:Forget(player.UserId)
	clickLimiter:Forget(player.UserId)
end

return table.freeze(Revenue)
