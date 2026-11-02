--!strict
--[[
	MonetizationService — game passes, developer products (idempotent ProcessReceipt) and Robux
	purchase prompts. The receipt path is RoBeasts' (in-flight set, receipt recorded in the same
	no-yield step as the grant, commit before PurchaseGranted), trimmed to SellNukes' catalogue.

	Developer products (MarketplaceService.ProcessReceipt → processReceiptAsync):
		malformed receipt / unknown or unpublished product id   → NotProcessedYet
		kind with no grant handler registered yet               → NotProcessedYet (never take Robux
		                                                          for nothing; Roblox retries)
		buyer not in this server / profile not loaded           → NotProcessedYet
		buyer in admin New Player Mode (sandbox session)        → NotProcessedYet (re-delivered and
		                                                          granted into the REAL profile
		                                                          after EXIT / on the next join)
		session cannot save (live in-memory, read-only, lost)   → NotProcessedYet
		PurchaseId already in profile.receipts                  → PurchaseGranted once that grant
		                                                          is durable (commit retried), never
		                                                          a second grant
		otherwise, in ONE non-yielding step: grant (built-in "Gems" or the kind's handler) +
		accounting hook + ProfileLogic.recordReceipt; then markChanged + commitAsync (save) →
		PurchaseGranted, or NotProcessedYet if the save failed (the record stays, so the retry
		only re-commits). Handlers run in a coroutine that may not yield: a yielding handler is
		closed and the receipt deferred (loud warning) — a half-applied grant is never recorded.
		`processing[purchaseId]` drops a concurrent re-invoke for the same receipt.
		Studio in-memory sessions (DataStores off) acknowledge receipts without saving, so
		test purchases work in playtests.

	Game passes (PassOwnership tracker per player, from RoBeasts):
		one UserOwnsGamePassAsync lookup per published pass on join (pcall, one automatic retry
		after 15 s), live purchases via PromptGamePassPurchaseFinished (monotonic "owned").
		ownsPass(player, key): the tracker's verdict once known ("owned" / "unowned"); while it is
		still checking (or the lookup failed) the profile's `passes` cache from the last session
		answers, so perks work immediately on join and survive a Roblox web outage. The cache is
		updated whenever the verdict changes (a refund clears it). PassChanged(player, key) fires
		whenever the effective answer flips. In admin New Player Mode every pass reads as NOT
		owned (a brand-new player's view), the sandbox's cache is never written, and the passes
		that flip at each swap fire PassChanged.

	Prompts (PromptProduct / PromptPass remotes, or promptProduct / promptPass from server code):
		validated key (Validate.configKey against MonetizationConfig), shared per-player token
		bucket (PurchasePromptConfig), ONE native prompt open per player (released by the
		Finished event or after PendingSeconds), unpublished id → "Coming soon!", outside the sale
		window → refused, no handler → "Coming soon!", admin New Player Mode → refused
		(NewPlayerMode.purchaseGate: the sandbox is never saved; passes too), profile not saveable
		→ refused (never take Robux we can't save), one-time pack already bought → refused, a
		world product (`world` set, R57) while that world is LOCKED for the player → "Unlock
		<World> first!", a kind's registered prompt refusal (registerPromptRefusal) → its message,
		paid random item for a restricted player (PolicyService, fail closed) → refused, owned
		pass → refused.

	World products (owner R57 World 2; kinds "WorldCash" / "WorldStarter", handlers registered by
	TycoonService): the receipt path is exactly the one above (same idempotent ledger, same
	no-yield grant step, same rollback). Lock state comes from the seam WorldService installs with
	setWorldUnlockCheck (rule + sticky flag); until it is installed the sticky profile flag
	worlds.<world>.unlocked answers (fail closed: an unknown world is locked). Only the PROMPT is
	gated: a receipt that still arrives is always granted (the player already paid).

	Analytics hooks (build plan "Server APIs"; B13 connects them):
		PromptRequested(player, key, kind, source)  owner R137: a PromptProduct / PromptPass request
		                                            passed the rate limit + key check (fired BEFORE
		                                            any refusal; analytics' offer "click" step)
		PromptShown(player, key, kind, source)      kind = product kind, or "pass"
		PromptFinished(player, key, kind, bought)
		ProductGranted(player, key, robux, receiptInfo)   after the grant is durable
		PassPurchased(player, key, robux)                 robux = the pass's catalogue price
		setReceiptAccounting(fn | { onGrant, onDurable? })
		                                                  onGrant(player, profile, product, receipt)
		                                                  runs INSIDE the grant step (no yield),
		                                                  so whatever it writes to profile.analytics
		                                                  (outbox record, payer marks) is saved
		                                                  atomically with the grant; onDurable(...)
		                                                  runs in its own thread once the grant is
		                                                  saved (may yield: journal the record,
		                                                  clear the outbox entry). Errors in either
		                                                  never block or undo a grant.

	Remotes: PromptProduct / PromptPass (C→S), PurchaseGranted (S→C { key, kind }), Notify (S→C).

	Connects to: Shared/Config/MonetizationConfig + PublishedProductIds + PurchasePromptConfig,
	Server/Services/PlayerDataService (sessions, commit, policy, notify), Economy/ProfileLogic
	(receipts, gems), Economy/PassOwnership, every service that sells a product kind.

	Example:
		-- In a later service's Init:
		MonetizationService.registerProductHandler("Spins", function(player, profile, product, receipt)
			profile.spin.paid += product.spins :: number
			return true -- must not yield; return false WITHOUT changing anything to defer
		end)
		if MonetizationService.ownsPass(player, "DoubleCash") then multiplier *= 2 end
]]

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NewPlayerMode = require(ReplicatedStorage.Shared.Util.NewPlayerMode)
local PassOwnership = require(script.Parent.Parent.Economy.PassOwnership)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)
local ProfileStore = require(script.Parent.Parent.Economy.ProfileStore)
local PurchasePromptConfig = require(ReplicatedStorage.Shared.Config.PurchasePromptConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type Profile = ProfileLogic.Profile
type ProductDef = MonetizationConfig.ProductDef
type PassDef = MonetizationConfig.PassDef

-- The validated Roblox receipt fields a handler may read (names match Roblox's receiptInfo).
export type ReceiptInfo = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
	CurrencySpent: number, -- 0 when Roblox did not report it
}

--[[
	Grant handler of a handler-routed product kind. MUST NOT yield; return false WITHOUT changing
	anything when the grant can't be applied right now (the receipt is retried later). Apply the
	change as the LAST step so an error can never leave a half-grant.
]]
export type Handler = (player: Player, profile: Profile, product: ProductDef, receipt: ReceiptInfo) -> boolean

-- Prompt-time refusal of a kind: a player-facing reason, or nil = OK to prompt. Must not yield.
export type PromptRefusal = (player: Player, product: ProductDef) -> string?

-- R57: "is this world unlocked for this player?" (WorldService.isUnlocked). Must not yield.
export type WorldUnlockCheck = (player: Player, worldId: string) -> boolean

-- Receipt accounting step (analytics). onGrant runs inside the grant step and must not yield;
-- onDurable runs in its own thread after the grant is saved and may yield.
export type AccountingStep = (player: Player, profile: Profile, product: ProductDef, receipt: ReceiptInfo) -> ()
export type ReceiptAccounting = { onGrant: AccountingStep, onDurable: AccountingStep? }

-- Profile access for processReceiptAsync (injected so Studio tests can drive the exact logic).
export type ReceiptDeps = {
	getProduct: (productId: number) -> ProductDef?,
	getBuyer: (userId: number) -> Player?,
	getSession: (player: Player) -> ProfileStore.Session?,
	markDirty: (player: Player, session: ProfileStore.Session) -> number,
	commitAsync: (session: ProfileStore.Session, version: number) -> boolean,
	allowUnsaved: boolean, -- Studio: in-memory ("disabled") sessions acknowledge receipts
	now: () -> number,
	onGranted: ((player: Player, product: ProductDef, receipt: ReceiptInfo) -> ())?,
}

local MonetizationService = {}

MonetizationService.PassChanged = Signal.new() :: Signal.Signal<Player, string>
-- R137: (player, key, kind, source) — a client BUY intent that passed the rate limit + key check.
MonetizationService.PromptRequested = Signal.new() :: Signal.Signal<Player, string, string, string>
MonetizationService.PromptShown = Signal.new() :: Signal.Signal<Player, string, string, string>
MonetizationService.PromptFinished = Signal.new() :: Signal.Signal<Player, string, string, boolean>
MonetizationService.ProductGranted = Signal.new() :: Signal.Signal<Player, string, number, ReceiptInfo>
MonetizationService.PassPurchased = Signal.new() :: Signal.Signal<Player, string, number>

-- Kinds MonetizationService grants itself; a handler can never take one of them over.
local BUILT_IN: { [string]: boolean } = { Gems = true }

-- Every kind the catalogue knows (registration of anything else is a programming error).
local KNOWN_KINDS: { [string]: boolean } = {}
for _, product in MonetizationConfig.Products do
	KNOWN_KINDS[product.kind] = true
end

local handlers: { [string]: Handler } = {}
local promptRefusals: { [string]: PromptRefusal } = {}
local receiptAccounting: ReceiptAccounting? = nil
-- R57 world lock seam (WorldService installs it in Start); nil = the sticky profile flag answers.
local worldUnlockCheck: WorldUnlockCheck? = nil

-- PurchaseIds being processed right now (Roblox may re-invoke ProcessReceipt while we yield).
local processing: { [string]: boolean } = {}

-- Prompt requests (shared bucket for products + passes) and the one-open-prompt hold.
local promptLimiter = RateLimiter.new(PurchasePromptConfig.RequestBurst, PurchasePromptConfig.RequestRefill)
type OpenPrompt = { kind: "product" | "pass", id: number, key: string, itemKind: string, at: number }
local openPrompts: { [Player]: OpenPrompt } = {}

-- Pass ownership: one tracker + the latest status per pass key per player.
local trackers: { [Player]: PassOwnership.Tracker } = {}
local passStatuses: { [Player]: { [string]: string } } = {}
-- New Player Mode swaps: each pass's effective answer right before a swap (ProfileUnloading), so
-- the ProfileLoaded that follows fires PassChanged for exactly the passes that flipped.
local passesBeforeSwap: { [Player]: { [string]: boolean } } = {}

-- Allowed analytics sources (anything else → "other").
local SOURCES: { [string]: boolean } = {}
for _, source in PurchasePromptConfig.Sources do
	SOURCES[source] = true
end

local COMING_SOON = "Coming soon!"
local NOT_SAVEABLE = "Purchases are paused while your save is offline. Please rejoin!"
local STILL_LOADING = "Your save is still loading - try again in a moment."

--------------------------------------------------------------------------------------------------
-- Registration (other services call these in their Init)
--------------------------------------------------------------------------------------------------

--[[
	Registers the grant handler of a handler-routed product kind (see the module header). Errors
	for a built-in kind, an unknown kind or a second registration: exactly one service owns each
	kind, and the mistake shows at boot.
	Example: MonetizationService.registerProductHandler("Spins", grantSpins)
]]
function MonetizationService.registerProductHandler(kind: MonetizationConfig.ProductKind, handler: Handler)
	if BUILT_IN[kind] then
		error(`[MonetizationService] {kind} is granted by MonetizationService itself`)
	end
	if not KNOWN_KINDS[kind] then
		error(`[MonetizationService] unknown product kind {kind}`)
	end
	if handlers[kind] ~= nil then
		error(`[MonetizationService] a handler for {kind} is already registered`)
	end
	handlers[kind] = handler
end

--[[
	Registers the prompt-time refusal of a kind (e.g. SecretPack sold out, DoubleOffline with
	nothing to double, SkipPad with no next pad). Only consulted when PROMPTING; a receipt that
	still arrives is granted by the handler. Errors on a second registration.
	Example: MonetizationService.registerPromptRefusal("SkipPad", function(player, product)
		return if TycoonService.nextPad(player) == nil then "You own every pad!" else nil
	end)
]]
function MonetizationService.registerPromptRefusal(kind: MonetizationConfig.ProductKind, refusal: PromptRefusal)
	if promptRefusals[kind] ~= nil then
		error(`[MonetizationService] a prompt refusal for {kind} is already registered`)
	end
	promptRefusals[kind] = refusal
end

--[[
	R57: installs (or with nil removes) the world lock check used to refuse prompts of world
	products while that world is locked (WorldService.isUnlocked: unlock rule + sticky flag).
	Example: MonetizationService.setWorldUnlockCheck(WorldService.isUnlocked)
]]
function MonetizationService.setWorldUnlockCheck(check: WorldUnlockCheck?)
	worldUnlockCheck = check
end

--[[
	Installs (or with nil removes) the receipt accounting hooks (analytics, B13). Accepts a plain
	function (= onGrant only) or { onGrant, onDurable? } (see the module header).
	Example: MonetizationService.setReceiptAccounting({ onGrant = prepare, onDurable = journal })
]]
function MonetizationService.setReceiptAccounting(accounting: ReceiptAccounting | AccountingStep | nil)
	if type(accounting) == "function" then
		receiptAccounting = { onGrant = accounting }
	else
		receiptAccounting = accounting
	end
end

--[[ True when a product kind can be granted right now (built in, or its handler registered). ]]
function MonetizationService.canGrant(kind: string): boolean
	return BUILT_IN[kind] == true or handlers[kind] ~= nil
end

--------------------------------------------------------------------------------------------------
-- Receipts
--------------------------------------------------------------------------------------------------

--[[
	Runs `fn(...)` to completion and refuses to let it yield: a yield closes the coroutine (it
	never resumes half-way) and counts as a failure. Returns (ok, result-or-error).
]]
local function runNoYield(fn: (...any) -> any, ...: any): (boolean, any)
	local thread = coroutine.create(fn)
	local ok, result = coroutine.resume(thread, ...)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return false, "yielded (grant steps must not yield)"
	end
	return ok, result
end
-- Exposed for services with the same "must not yield" contract (and for the Core test suite).
MonetizationService.runNoYield = runNoYield

-- Applies a product's grant to `profile` (no yield). Returns true when granted. On ANY non-grant
-- (refusal, error, yield) the caller restores the profile snapshot it took first (see
-- processReceiptBody), so a handler can never leave a half-applied grant behind.
local function applyGrant(player: Player, profile: Profile, product: ProductDef, receipt: ReceiptInfo): boolean
	if product.kind == "Gems" then
		local gems = product.gems
		if type(gems) ~= "number" or gems <= 0 then
			return false
		end
		ProfileLogic.addGems(profile, gems)
		return true
	end
	local handler = handlers[product.kind]
	if handler == nil then
		return false
	end
	local ok, granted = runNoYield(handler, player, profile, product, receipt)
	if not ok then
		warn(`[MonetizationService] {product.kind} handler failed for receipt {receipt.PurchaseId}: {granted}`)
		return false
	end
	return granted == true
end

--[[
	Everything that happens once a grant is durable (saved, or Studio in-memory): the accounting
	onDurable step in its own thread (a yielding journal write never delays PurchaseGranted), then
	deps.onGranted (toast, PurchaseGranted remote, ProductGranted signal).
]]
local function afterDurable(
	player: Player,
	profile: Profile,
	product: ProductDef,
	receipt: ReceiptInfo,
	deps: ReceiptDeps
)
	local accounting = receiptAccounting
	local onDurable = if accounting ~= nil then accounting.onDurable else nil
	if onDurable ~= nil then
		task.spawn(function()
			local ok, err = pcall(onDurable, player, profile, product, receipt)
			if not ok then
				warn(`[MonetizationService] receipt accounting (durable) failed for {receipt.PurchaseId}: {err}`)
			end
		end)
	end
	local onGranted = deps.onGranted
	if onGranted ~= nil then
		-- Toast / remote / ProductGranted listeners must never turn a saved grant into
		-- NotProcessedYet (the retry would skip the grant AND these signals).
		local ok, err = pcall(onGranted, player, product, receipt)
		if not ok then
			warn(`[MonetizationService] onGranted failed for receipt {receipt.PurchaseId}: {err}`)
		end
	end
end

-- The receipt body (see processReceiptAsync); may yield in commitAsync only.
local function processReceiptBody(receipt: ReceiptInfo, deps: ReceiptDeps): Enum.ProductPurchaseDecision
	local purchaseId = receipt.PurchaseId
	local product = deps.getProduct(receipt.ProductId)
	if product == nil then
		-- Unknown / unpublished id: never grant blindly. Roblox retries once config is fixed.
		warn(`[MonetizationService] receipt {purchaseId} for unknown product {receipt.ProductId}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not MonetizationService.canGrant(product.kind) then
		warn(`[MonetizationService] receipt {purchaseId}: no handler registered for {product.kind}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local player = deps.getBuyer(receipt.PlayerId)
	if player == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local session = deps.getSession(player)
	if session == nil or session.released then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- Admin New Player Mode: the buyer's live session is a throwaway SANDBOX (never saved). Defer:
	-- Roblox re-delivers the receipt and it is granted into the REAL profile once it is back.
	if NewPlayerMode.receiptDecision(session.sandbox) == "defer" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local durable = session.status == "ok"
	if not durable and not (deps.allowUnsaved and session.status == "disabled") then
		-- The grant could not be saved (DataStores down / read-only / lost lock): retry later.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local profile = session.profile

	if ProfileLogic.hasReceipt(profile, purchaseId) then
		-- Already granted. Acknowledge once that grant is durable (never grant twice).
		local pendingVersion = session.pendingReceipts[purchaseId]
		if pendingVersion == nil or not durable then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		if not deps.commitAsync(session, pendingVersion) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		session.pendingReceipts[purchaseId] = nil
		afterDurable(player, profile, product, receipt, deps)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- ONE non-yielding step: grant + receipt record (+ accounting). A snapshot is taken first and
	-- restored on any failure, so a handler that errors / yields / refuses half-way leaves the
	-- profile exactly as it was (never a partial grant that a re-delivery would grant again).
	local before = ProfileLogic.takeSnapshot(profile :: any)
	if not applyGrant(player, profile, product, receipt) then
		ProfileLogic.restoreSnapshot(before)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not ProfileLogic.recordReceipt(profile, purchaseId, deps.now()) then
		-- Unreachable while hasReceipt is checked above; if it ever happens, undo the grant.
		ProfileLogic.restoreSnapshot(before)
		warn(`[MonetizationService] receipt {purchaseId} could not be recorded; grant undone`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local accounting = receiptAccounting
	if accounting ~= nil then
		local ok, err = runNoYield(accounting.onGrant, player, profile, product, receipt)
		if not ok then
			warn(`[MonetizationService] receipt accounting failed for {purchaseId}: {err}`)
		end
	end
	local version = deps.markDirty(player, session)

	if durable then
		session.pendingReceipts[purchaseId] = version
		if not deps.commitAsync(session, version) then
			warn(`[MonetizationService] receipt {purchaseId} granted in memory but not saved yet; will retry`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		session.pendingReceipts[purchaseId] = nil
	end
	print(`[MonetizationService] granted {product.key} to {receipt.PlayerId}, receipt {purchaseId}`)
	afterDurable(player, profile, product, receipt, deps)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

--[[
	Idempotent developer-product receipt processing (the body of MarketplaceService.ProcessReceipt).
	Never throws; anything unexpected returns NotProcessedYet so Roblox retries.
	@param receiptInfo the table Roblox passes to ProcessReceipt (validated here)
	@param deps        profile access (liveReceiptDeps() in production)
]]
function MonetizationService.processReceiptAsync(receiptInfo: unknown, deps: ReceiptDeps): Enum.ProductPurchaseDecision
	if type(receiptInfo) ~= "table" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local raw = receiptInfo :: { [string]: unknown }
	local purchaseId = Validate.string(raw.PurchaseId, 1, 64)
	local userId = Validate.userId(raw.PlayerId)
	local productId = Validate.userId(raw.ProductId)
	if purchaseId == nil or userId == nil or productId == nil then
		warn("[MonetizationService] malformed receipt")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if processing[purchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	processing[purchaseId] = true
	local receipt: ReceiptInfo = {
		PurchaseId = purchaseId,
		PlayerId = userId,
		ProductId = productId,
		CurrencySpent = Validate.integer(raw.CurrencySpent, 0, 1e9) or 0,
	}
	local ok, decision = pcall(processReceiptBody, receipt, deps)
	processing[purchaseId] = nil
	if not ok then
		warn(`[MonetizationService] receipt {purchaseId} errored: {decision}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return decision
end

-- Thank-you toast + PurchaseGranted remote + ProductGranted signal once a grant is durable.
local function onProductGranted(player: Player, product: ProductDef, receipt: ReceiptInfo)
	if player.Parent == Players then
		Remotes.fireClient("PurchaseGranted", player, { key = product.key, kind = product.kind })
		local text = if product.kind == "Gems" and product.gems ~= nil
			then `+{product.gems} gems! Thanks for your support!`
			else `{product.name} delivered! Thanks for your support!`
		PlayerDataService.notify(player, text, "reward", product.icon)
	end
	MonetizationService.ProductGranted:Fire(player, product.key, receipt.CurrencySpent, receipt)
end

--[[ The production receipt dependencies (PlayerDataService sessions + ProfileStore commits). ]]
function MonetizationService.liveReceiptDeps(): ReceiptDeps
	return {
		getProduct = MonetizationConfig.getProductById,
		getBuyer = function(userId: number): Player?
			return Players:GetPlayerByUserId(userId)
		end,
		getSession = PlayerDataService.getSession,
		markDirty = function(player: Player, session: ProfileStore.Session): number
			local version = PlayerDataService.markChanged(player, true)
			if version ~= nil then
				return version
			end
			local store = PlayerDataService.getStore()
			assert(store ~= nil, "ProfileStore exists while sessions exist")
			return store:markDirty(session)
		end,
		commitAsync = function(session: ProfileStore.Session, version: number): boolean
			local store = PlayerDataService.getStore()
			return store ~= nil and store:commitAsync(session, version)
		end,
		allowUnsaved = RunService:IsStudio(),
		now = function(): number
			return os.time()
		end,
		onGranted = onProductGranted,
	}
end

--[[
	Studio only: runs a fake receipt for `productKey` through the REAL receipt path (published or
	not), e.g. from a server test or the admin panel's "test receipts" (spec §14). Errors outside
	Studio, so no live code path can mint purchases.
	@return the ProductPurchaseDecision
	Example: MonetizationService.simulateReceiptAsync(player, "GemsSmall")
]]
function MonetizationService.simulateReceiptAsync(
	player: Player,
	productKey: string,
	purchaseId: string?
): Enum.ProductPurchaseDecision
	if not RunService:IsStudio() then
		error("[MonetizationService] simulateReceiptAsync is Studio-only")
	end
	local product = MonetizationConfig.getProduct(productKey)
	if product == nil then
		error(`[MonetizationService] unknown product {productKey}`)
	end
	local deps = MonetizationService.liveReceiptDeps()
	-- Unpublished products have id 0; route the fake id straight to the product.
	local fakeId = 1
	deps.getProduct = function(id: number): ProductDef?
		return if id == fakeId then product else nil
	end
	return MonetizationService.processReceiptAsync({
		PurchaseId = purchaseId or `studio-{HttpService:GenerateGUID(false)}`,
		PlayerId = player.UserId,
		ProductId = fakeId,
		CurrencySpent = product.price,
	}, deps)
end

--------------------------------------------------------------------------------------------------
-- Game passes
--------------------------------------------------------------------------------------------------

-- The effective ownership for a status + the profile cache (see ownsPass).
local function effectiveOwned(status: string?, profile: Profile?, passKey: string): boolean
	if status == "owned" then
		return true
	elseif status == "unowned" then
		return false
	end
	return profile ~= nil and profile.passes[passKey] == true
end

--[[
	True if the player owns a game pass: Roblox's verdict this session once known; until then (or
	if the lookup failed) the cached ownership from their last session.
	Example: if MonetizationService.ownsPass(player, "VIP") then ... end
]]
function MonetizationService.ownsPass(player: Player, passKey: string): boolean
	-- Admin New Player Mode: a brand-new player's view (no perks). The real verdicts stay in
	-- passStatuses and apply again the moment the real profile is back.
	if PlayerDataService.isNewPlayerMode(player) then
		return false
	end
	local statuses = passStatuses[player]
	return effectiveOwned(
		if statuses ~= nil then statuses[passKey] else nil,
		PlayerDataService.getProfile(player),
		passKey
	)
end

-- Keeps profile.passes in line with a definitive verdict (owned / unowned); pushes the change.
local function syncPassCache(player: Player, passKey: string, status: string)
	local profile = PlayerDataService.getProfile(player)
	-- In New Player Mode the live profile is the sandbox: never mark real passes into it (the
	-- real profile's cache is re-synced from passStatuses when it is swapped back).
	if profile == nil or (status ~= "owned" and status ~= "unowned") or PlayerDataService.isNewPlayerMode(player) then
		return
	end
	local cached = profile.passes[passKey] == true
	local owned = status == "owned"
	if cached == owned then
		return
	end
	profile.passes[passKey] = if owned then true else nil
	PlayerDataService.markChanged(player, false, { "passes" })
end

-- A tracker status update: record it, sync the cache, announce an effective flip.
local function onPassStatus(player: Player, passKey: string, status: string)
	local statuses = passStatuses[player]
	if statuses == nil then
		return
	end
	local before = MonetizationService.ownsPass(player, passKey)
	statuses[passKey] = status
	syncPassCache(player, passKey, status)
	if MonetizationService.ownsPass(player, passKey) ~= before then
		MonetizationService.PassChanged:Fire(player, passKey)
	end
end

-- Cancels a tracker task unless it is the running thread (PassOwnership cancellation contract).
local function cancelTask(worker: thread): () -> ()
	return function()
		if coroutine.status(worker) ~= "dead" and worker ~= coroutine.running() then
			task.cancel(worker)
		end
	end
end

-- Starts the per-player pass lookups (one tracker; independent bounded lookups per pass).
local function startPassChecks(player: Player)
	if player.Parent ~= Players or trackers[player] ~= nil then
		return
	end
	passStatuses[player] = {}
	local tracker = PassOwnership.new({
		lookup = function(id: number): boolean
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
		end,
		alive = function(): boolean
			return player.Parent == Players
		end,
		now = os.clock,
		spawn = function(callback: () -> ()): () -> ()
			return cancelTask(task.spawn(callback))
		end,
		delay = function(seconds: number, callback: () -> ()): () -> ()
			return cancelTask(task.delay(seconds, callback))
		end,
		changed = function(key: string, status: string)
			onPassStatus(player, key, status)
		end,
	})
	trackers[player] = tracker
	for _, key in MonetizationConfig.PassOrder do
		local pass = MonetizationConfig.Passes[key]
		tracker.request(pass.key, pass.id) -- id 0 publishes "unowned" without a lookup
	end
end

-- Live pass purchase (server-side Roblox event: trustworthy, not client input).
local function onPassPurchaseFinished(player: Player, passId: number, wasPurchased: boolean)
	local open = openPrompts[player]
	if open ~= nil and open.kind == "pass" and open.id == passId then
		openPrompts[player] = nil
	end
	local pass = MonetizationConfig.getPassById(passId)
	if pass == nil then
		return
	end
	MonetizationService.PromptFinished:Fire(player, pass.key, "pass", wasPurchased == true)
	if not wasPurchased then
		return
	end
	local tracker = trackers[player]
	if tracker ~= nil then
		tracker.grant(pass.key) -- → onPassStatus("owned"): cache + PassChanged
	end
	Remotes.fireClient("PurchaseGranted", player, { key = pass.key, kind = "pass" })
	PlayerDataService.notify(player, `{pass.name} unlocked! Thanks for your support!`, "reward", pass.icon)
	MonetizationService.PassPurchased:Fire(player, pass.key, pass.price)
end

--------------------------------------------------------------------------------------------------
-- Prompts
--------------------------------------------------------------------------------------------------

-- A normalized analytics source.
local function cleanSource(source: unknown): string
	if type(source) == "string" and SOURCES[source] then
		return source
	end
	return "other"
end

-- True while another native prompt of this player is still open (within PendingSeconds).
local function promptBusy(player: Player): boolean
	local open = openPrompts[player]
	if open == nil then
		return false
	end
	if os.clock() - open.at >= PurchasePromptConfig.PendingSeconds then
		openPrompts[player] = nil -- the Finished event was lost (e.g. disconnect mid-prompt)
		return false
	end
	return true
end

--[[
	Admin New Player Mode purchase gate (NewPlayerMode.purchaseGate): true + a refusal toast when
	this player may not open ANY Robux prompt right now (the sandbox profile is never saved).
]]
local function newPlayerModeBlocks(player: Player): boolean
	local allowed, refusal = NewPlayerMode.purchaseGate(PlayerDataService.isNewPlayerMode(player))
	if allowed then
		return false
	end
	PlayerDataService.notify(player, refusal or NewPlayerMode.Copy.PurchaseBlocked, "error")
	return true
end

--[[
	R57: true when `worldId` is unlocked for the player, as the prompt gate sees it: "main" always;
	the WorldService seam when installed (a failing / yielding seam counts as LOCKED); otherwise
	the sticky profile flag worlds.<world>.unlocked. Unknown worlds / no profile → false.
]]
local function worldUnlockedForPrompt(player: Player, profile: Profile, worldId: string): boolean
	local def = WorldsConfig.get(worldId)
	if def == nil then
		return false
	elseif def.id == WorldsConfig.MAIN then
		return true
	end
	local check = worldUnlockCheck
	if check ~= nil then
		local ok, unlocked = runNoYield(check, player, def.id)
		if not ok then
			warn(`[MonetizationService] world unlock check failed for {def.id}: {unlocked}`)
			return false
		end
		return unlocked == true
	end
	local world = ProfileLogic.peekWorld(profile, def.id)
	return world ~= nil and world.unlocked
end

-- Why a product must not be prompted right now (nil = OK). May yield (paid-random policy).
local function productRefusal(player: Player, product: ProductDef): string?
	if not MonetizationConfig.isConfigured(product.id) or not MonetizationService.canGrant(product.kind) then
		return COMING_SOON
	end
	if MonetizationConfig.saleState(product, os.time()) ~= "OnSale" then
		return "This offer isn't available right now."
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return STILL_LOADING
	end
	if not PlayerDataService.canMutate(player) then
		return NOT_SAVEABLE
	end
	-- R57 world products: never prompted while their world is locked (the UI hides them too).
	local worldId = product.world
	if worldId ~= nil and not worldUnlockedForPrompt(player, profile, worldId) then
		local def = WorldsConfig.get(worldId)
		return `Unlock {if def ~= nil then def.name else "this world"} first!`
	end
	if product.oneTime then
		local world = if worldId ~= nil then ProfileLogic.peekWorld(profile, worldId) else nil
		if
			(product.kind == "StarterPack" and profile.starter.bought)
			or (product.kind == "SecretPack" and profile.secretPack.bought)
			or (product.kind == "WorldStarter" and (world == nil or world.starter.bought))
		then
			return "You already own this!"
		end
	end
	local refusal = promptRefusals[product.kind]
	if refusal ~= nil then
		local ok, reason = runNoYield(refusal, player, product)
		if not ok then
			warn(`[MonetizationService] prompt refusal for {product.kind} failed: {reason}`)
			return "This offer isn't available right now."
		end
		if type(reason) == "string" then
			return reason
		end
	end
	if product.paidRandom and PlayerDataService.resolvePaidRandomAsync(player) then
		return "This item isn't available in your region."
	end
	return nil
end

--[[
	Opens a developer-product prompt for `productKey` after every server check (see the header).
	Server code calls this directly (e.g. an offer popup); the PromptProduct remote calls it
	after its rate limit. Refusals become a toast.
	@param source analytics attribution (PurchasePromptConfig.Sources; anything else → "other")
	@return true when the native prompt was opened
	Example: MonetizationService.promptProduct(player, "DoubleOffline", "welcomeBack")
]]
function MonetizationService.promptProduct(player: Player, productKey: string, source: string?): boolean
	local product = MonetizationConfig.getProduct(productKey)
	if product == nil or player.Parent ~= Players or promptBusy(player) or newPlayerModeBlocks(player) then
		return false
	end
	local refusal = productRefusal(player, product)
	if refusal ~= nil then
		PlayerDataService.notify(player, refusal, "info")
		return false
	end
	-- productRefusal may have yielded (policy lookup): re-check the hold, the player and the mode.
	if player.Parent ~= Players or promptBusy(player) or newPlayerModeBlocks(player) then
		return false
	end
	openPrompts[player] =
		{ kind = "product", id = product.id, key = product.key, itemKind = product.kind, at = os.clock() }
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, product.id)
	end)
	if not ok then
		openPrompts[player] = nil
		warn(`[MonetizationService] PromptProductPurchase failed: {err}`)
		return false
	end
	MonetizationService.PromptShown:Fire(player, product.key, product.kind, cleanSource(source))
	return true
end

--[[
	Opens a game-pass prompt for `passKey` (published, not already owned, one prompt at a time).
	@return true when the native prompt was opened
	Example: MonetizationService.promptPass(player, "VIP", "shop")
]]
function MonetizationService.promptPass(player: Player, passKey: string, source: string?): boolean
	local pass = MonetizationConfig.getPass(passKey)
	if pass == nil or player.Parent ~= Players or promptBusy(player) or newPlayerModeBlocks(player) then
		return false
	end
	if not MonetizationConfig.isConfigured(pass.id) then
		PlayerDataService.notify(player, COMING_SOON, "info")
		return false
	end
	if MonetizationService.ownsPass(player, pass.key) then
		PlayerDataService.notify(player, "You already own this!", "info")
		return false
	end
	openPrompts[player] = { kind = "pass", id = pass.id, key = pass.key, itemKind = "pass", at = os.clock() }
	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, pass.id)
	end)
	if not ok then
		openPrompts[player] = nil
		warn(`[MonetizationService] PromptGamePassPurchase failed: {err}`)
		return false
	end
	MonetizationService.PromptShown:Fire(player, pass.key, "pass", cleanSource(source))
	return true
end

--[[
	PromptProduct (C→S): (productKey, source?) — rate-limited + key-validated, then promptProduct.
	Owner R137: PromptRequested fires between the two (after the checks, BEFORE any prompt refusal),
	so analytics can count the BUY press itself ("click") even when the prompt is then refused. A
	request the limiter drops (a mashed button) or with an unknown key is not a press.
]]
local function onPromptProductRemote(player: Player, rawKey: unknown, rawSource: unknown)
	if not promptLimiter:Allow(player) then
		return
	end
	local key = Validate.configKey(rawKey, MonetizationConfig.Products :: any, 32)
	if key == nil then
		return
	end
	local product = MonetizationConfig.getProduct(key)
	if product == nil then
		return
	end
	local source = cleanSource(rawSource)
	MonetizationService.PromptRequested:Fire(player, product.key, product.kind, source)
	MonetizationService.promptProduct(player, product.key, source)
end

--[[
	PromptPass (C→S): (passKey, source?) — rate-limited + key-validated, then promptPass.
	PromptRequested (R137) fires between the two, exactly as for products.
]]
local function onPromptPassRemote(player: Player, rawKey: unknown, rawSource: unknown)
	if not promptLimiter:Allow(player) then
		return
	end
	local key = Validate.configKey(rawKey, MonetizationConfig.Passes :: any, 32)
	if key == nil then
		return
	end
	local source = cleanSource(rawSource)
	MonetizationService.PromptRequested:Fire(player, key, "pass", source)
	MonetizationService.promptPass(player, key, source)
end

-- Product prompt closed (bought or not): release the hold, report it.
local function onProductPromptFinished(userId: number, productId: number, isPurchased: boolean)
	local player = Players:GetPlayerByUserId(userId)
	if player == nil then
		return
	end
	local open = openPrompts[player]
	if open ~= nil and open.kind == "product" and open.id == productId then
		openPrompts[player] = nil
	end
	local product = MonetizationConfig.getProductById(productId)
	if product ~= nil then
		MonetizationService.PromptFinished:Fire(player, product.key, product.kind, isPurchased == true)
	end
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

--[[ Service contract: nothing to wire before other services register their handlers. ]]
function MonetizationService.Init() end

--[[ Service contract: ProcessReceipt, Marketplace events, prompt remotes, pass tracking. ]]
function MonetizationService.Start()
	local deps = MonetizationService.liveReceiptDeps()
	MarketplaceService.ProcessReceipt = function(receiptInfo: unknown): Enum.ProductPurchaseDecision
		return MonetizationService.processReceiptAsync(receiptInfo, deps)
	end
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPassPurchaseFinished)
	MarketplaceService.PromptProductPurchaseFinished:Connect(onProductPromptFinished)
	Remotes.onServerEvent("PromptProduct", onPromptProductRemote)
	Remotes.onServerEvent("PromptPass", onPromptPassRemote)

	-- Verdicts that arrived before the profile loaded are written into its cache now, and a pass
	-- whose effective answer changed now that the cache is readable (owned last session, lookup
	-- still running) is announced, so listeners never miss a perk that was on from the start.
	-- New Player Mode swap: remember every pass's effective answer before the profile changes.
	PlayerDataService.ProfileUnloading:Connect(function(player: Player)
		if passStatuses[player] == nil then
			return
		end
		local before: { [string]: boolean } = {}
		for _, key in MonetizationConfig.PassOrder do
			before[key] = MonetizationService.ownsPass(player, key)
		end
		passesBeforeSwap[player] = before
	end)
	PlayerDataService.ProfileLoaded:Connect(function(player: Player, _profile: Profile, _isNew: boolean)
		local swapBefore = passesBeforeSwap[player]
		passesBeforeSwap[player] = nil
		local statuses = passStatuses[player]
		if statuses == nil then
			return
		end
		for _, key in MonetizationConfig.PassOrder do
			local status = statuses[key]
			-- A swap compares with the answer right before it; a join with the pre-load answer.
			local seenBeforeLoad = if swapBefore ~= nil
				then swapBefore[key] == true
				else effectiveOwned(status, nil, key)
			if status ~= nil then
				syncPassCache(player, key, status)
			end
			if MonetizationService.ownsPass(player, key) ~= seenBeforeLoad then
				MonetizationService.PassChanged:Fire(player, key)
			end
		end
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(startPassChecks, player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(startPassChecks, player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		local tracker = trackers[player]
		if tracker ~= nil then
			tracker.destroy()
		end
		trackers[player] = nil
		passStatuses[player] = nil
		passesBeforeSwap[player] = nil
		openPrompts[player] = nil
		promptLimiter:Forget(player)
	end)
end

return MonetizationService
