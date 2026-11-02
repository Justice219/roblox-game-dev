--!strict
--[[
	CoreTests — B1 core smoke tests that run INSIDE the engine (Studio Run mode, no players).

	Cases:
		Remotes          every declared remote exists with the right class after the bootstrap
		Catalogue        MonetizationConfig.validate() and ChangeNotesConfig.validate() are clean in
		                 the engine (Roblox os.date / string rules, not just Lune's)
		ProfileJson      a busy profile survives toSave → HttpService JSON → migrate unchanged
		                 (the engine's own JSON, i.e. what DataStores store)
		ProfileStore     open / save / second-server lock-out / release / reopen over a JSON mock
		Receipts         the REAL receipt path over a mock session: grant once, duplicate → granted
		                 without a second grant, unhandled kind / malformed / unsaveable → deferred,
		                 failed commit → deferred then acknowledged on retry without regranting,
		                 a yielding grant step is refused
		NewPlayerMode    a New Player Mode SANDBOX session (ProfileStore.sandboxSession) defers a
		                 receipt without granting or recording it, is never written, and the same
		                 receipt is granted into the REAL session once it is back

	Run (Studio, scripts/studio_mcp.py): StudioTestService:ExecuteRunModeAsync({ suite = "Core" })
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ChangeNotesConfig = require(ReplicatedStorage.Shared.Config.ChangeNotesConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local MonetizationService = require(script.Parent.Parent.Services.MonetizationService)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)
local ProfileStore = require(script.Parent.Parent.Economy.ProfileStore)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TestContext = require(script.Parent.TestContext)

type TestCase = { name: string, run: (ctx: TestContext.TestContext) -> () }

-- Deep equality for plain data.
local function deepEqual(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- An UpdateAsync mock that stores engine JSON (like a DataStore). `failing` makes calls throw;
-- `writes` counts the writes that happened (a transform returning nil cancels, like Roblox).
local function jsonStore(): any
	local mock = { data = {} :: { [string]: string }, failing = false, writes = 0 }
	function mock.UpdateAsync(self: any, key: string, transform: (any, any) -> (any, any)): any
		if self.failing then
			error("mock DataStore failure")
		end
		local raw = self.data[key]
		local old = if raw ~= nil then HttpService:JSONDecode(raw) else nil
		local value = transform(old, nil)
		if value ~= nil then
			self.data[key] = HttpService:JSONEncode(value)
			self.writes += 1
		end
		return value
	end
	return mock
end

-- Fast timings for mock stores.
local function fastTiming(): ProfileStore.Timing
	local timing = ProfileStore.defaultTiming()
	timing.loadAttempts = 2
	timing.saveAttempts = 1
	timing.baseDelay = 0.01
	timing.maxDelay = 0.01
	timing.minWriteInterval = 0
	return timing
end

local cases: { TestCase } = {
	{
		name = "Remotes",
		run = function(ctx)
			local folder = ReplicatedStorage:FindFirstChild(Remotes.FolderName)
			ctx.check("folder exists", folder ~= nil)
			if folder == nil then
				return
			end
			local missing: { string } = {}
			local eventNames: { string } = Remotes.EventNames :: any
			local unreliableNames: { string } = Remotes.UnreliableNames :: any
			for _, name in eventNames do
				local remote = folder:FindFirstChild(name)
				if remote == nil or not remote:IsA("RemoteEvent") then
					table.insert(missing, name)
				end
			end
			for _, name in unreliableNames do
				local remote = folder:FindFirstChild(name)
				if remote == nil or not remote:IsA("UnreliableRemoteEvent") then
					table.insert(missing, name)
				end
			end
			ctx.check("every remote created", #missing == 0, table.concat(missing, ","))
			ctx.metric("remotes", #folder:GetChildren())
		end,
	},
	{
		name = "Catalogue",
		run = function(ctx)
			local problems = MonetizationConfig.validate()
			ctx.check("MonetizationConfig valid", #problems == 0, table.concat(problems, "; "))
			local notes = ChangeNotesConfig.validate()
			ctx.check("ChangeNotesConfig valid", #notes == 0, table.concat(notes, "; "))
			-- Every catalogue product has a live id now (B12 + R57 publish), so the guard is proven
			-- on synthetic UNPUBLISHED copies of a real product (0 / negative / fractional / NaN /
			-- inf ids), plus any genuinely unpublished catalogue entry, plus consistency for the rest.
			local now = os.time()
			local base = MonetizationConfig.Products.GemsSmall
			local badIds = { 0, -1, 1.5, 0 / 0, math.huge }
			local blocked = 0
			for _, badId in badIds do
				local copy = table.clone(base)
				copy.id = badId
				if
					not MonetizationConfig.isAvailable(copy, now)
					and MonetizationConfig.getProductById(badId) == nil
				then
					blocked += 1
				end
			end
			ctx.check("unpublished product unavailable", blocked == #badIds, `blocked {blocked}/{#badIds}`)
			local consistent, unpublished = true, 0
			for key, def in MonetizationConfig.Products do
				local configured = MonetizationConfig.isConfigured(def.id)
				if not configured then
					unpublished += 1
				end
				local expected = configured and MonetizationConfig.saleState(def, now) == "OnSale"
				if MonetizationConfig.isProductAvailable(key, now) ~= expected then
					consistent = false
				end
			end
			ctx.check("catalogue availability follows id + sale window", consistent)
			ctx.metric("unpublishedProducts", unpublished)
			ctx.check("unpublished id never matches a receipt", MonetizationConfig.getProductById(0) == nil)
		end,
	},
	{
		name = "ProfileJson",
		run = function(ctx)
			local profile = ProfileLogic.defaultProfile()
			ProfileLogic.addCash(profile, 123456.75)
			ProfileLogic.addGems(profile, 42)
			profile.tycoon.pads.a1_bench = true
			profile.tycoon.producers.garage = 17
			profile.timeRewards.claimed[1] = true
			profile.timeRewards.claimed[4] = true
			profile.event.stickers[9] = true
			profile.pets.owned["1"] = { id = "glow_slime", locked = true }
			profile.pets.equipped = { "1" }
			profile.pets.nextUid = 2
			ProfileLogic.recordReceipt(profile, "r-1", os.time())
			local json = HttpService:JSONEncode(ProfileLogic.toSave(profile))
			local restored, status = ProfileLogic.migrate(HttpService:JSONDecode(json))
			ctx.check("status current", status == "current", status)
			ctx.check("round trip equal", deepEqual(restored, profile))
			ctx.metric("savedBytes", #json)
		end,
	},
	{
		name = "ProfileStore",
		run = function(ctx)
			local mock = jsonStore()
			local storeA = ProfileStore.new(mock, { jobId = "test-A", placeId = 0, timing = fastTiming() })
			local storeB = ProfileStore.new(mock, { jobId = "test-B", placeId = 0, timing = fastTiming() })
			local session = storeA:openAsync(9001)
			ctx.check("opened", session ~= nil and session.status == "ok")
			if session == nil then
				return
			end
			ProfileLogic.addCash(session.profile, 99)
			local version = storeA:markDirty(session)
			ctx.check("committed", storeA:commitAsync(session, version))
			local locked, err = storeB:openAsync(9001)
			ctx.check("second server locked out", locked == nil and err == "locked", tostring(err))
			ctx.check("released", storeA:saveAsync(session, true))
			local reopened = storeB:openAsync(9001)
			ctx.check("reopened after release", reopened ~= nil and reopened.profile.cash == 99)
			if reopened ~= nil then
				storeB:saveAsync(reopened, true)
			end
		end,
	},
	{
		name = "Receipts",
		run = function(ctx)
			local mock = jsonStore()
			local store = ProfileStore.new(mock, { jobId = "test-R", placeId = 0, timing = fastTiming() })
			local session = store:openAsync(9002)
			if not ctx.check("session", session ~= nil) then
				return
			end
			local live = session :: ProfileStore.Session
			local fakePlayer = (newproxy(false) :: any) :: Player
			local gems = MonetizationConfig.Products.GemsSmall
			local unhandled = table.clone(gems) :: any
			unhandled.kind = "TestUnhandledKind"
			local granted = 0
			local deps: MonetizationService.ReceiptDeps = {
				getProduct = function(id: number): MonetizationConfig.ProductDef?
					return if id == 1 then gems elseif id == 2 then unhandled else nil
				end,
				getBuyer = function(userId: number): Player?
					return if userId == 9002 then fakePlayer else nil
				end,
				getSession = function(_player: Player): ProfileStore.Session?
					return live
				end,
				markDirty = function(_player: Player, s: ProfileStore.Session): number
					return store:markDirty(s)
				end,
				commitAsync = function(s: ProfileStore.Session, v: number): boolean
					return store:commitAsync(s, v)
				end,
				allowUnsaved = false,
				now = function(): number
					return os.time()
				end,
				onGranted = function()
					granted += 1
				end,
			}
			local Decision = Enum.ProductPurchaseDecision
			local function receipt(id: string, product: number): { [string]: any }
				return { PurchaseId = id, PlayerId = 9002, ProductId = product, CurrencySpent = 49 }
			end
			local gemsPer = gems.gems :: number
			ctx.check(
				"grant",
				MonetizationService.processReceiptAsync(receipt("p-1", 1), deps) == Decision.PurchaseGranted
			)
			ctx.check("gems once", live.profile.gems == gemsPer, `gems={live.profile.gems}`)
			ctx.check(
				"duplicate acknowledged",
				MonetizationService.processReceiptAsync(receipt("p-1", 1), deps) == Decision.PurchaseGranted
			)
			ctx.check("duplicate not regranted", live.profile.gems == gemsPer and granted == 1)
			local stored = HttpService:JSONDecode(mock.data["Profile_9002"])
			ctx.check(
				"grant saved with its receipt",
				stored.data.gems == gemsPer and stored.data.receipts["p-1"] ~= nil
			)
			ctx.check(
				"unhandled kind deferred",
				MonetizationService.processReceiptAsync(receipt("p-2", 2), deps) == Decision.NotProcessedYet
			)
			ctx.check("unhandled not recorded", not ProfileLogic.hasReceipt(live.profile, "p-2"))
			ctx.check(
				"unknown product deferred",
				MonetizationService.processReceiptAsync(receipt("p-3", 77), deps) == Decision.NotProcessedYet
			)
			ctx.check(
				"malformed deferred",
				MonetizationService.processReceiptAsync({ PurchaseId = 5 }, deps) == Decision.NotProcessedYet
			)
			-- A failed commit keeps the record (no regrant) and acknowledges once a save works.
			mock.failing = true
			ctx.check(
				"failed save deferred",
				MonetizationService.processReceiptAsync(receipt("p-4", 1), deps) == Decision.NotProcessedYet
			)
			ctx.check("granted in memory once", live.profile.gems == gemsPer * 2)
			mock.failing = false
			ctx.check(
				"retry acknowledged",
				MonetizationService.processReceiptAsync(receipt("p-4", 1), deps) == Decision.PurchaseGranted
			)
			ctx.check("retry did not regrant", live.profile.gems == gemsPer * 2 and granted == 2)
			-- An unsaveable session defers before any grant.
			live.status = "disabled"
			ctx.check(
				"unsaveable deferred",
				MonetizationService.processReceiptAsync(receipt("p-5", 1), deps) == Decision.NotProcessedYet
			)
			ctx.check("unsaveable not granted", live.profile.gems == gemsPer * 2)
			live.status = "ok"
			-- Grant steps must not yield.
			local ok = MonetizationService.runNoYield(function(): nil
				task.wait()
				return nil
			end)
			ctx.check("yielding step refused", ok == false)
			local fine, value = MonetizationService.runNoYield(function(x: number)
				return x + 1
			end, 1)
			ctx.check("plain step runs", fine == true and value == 2)
			store:saveAsync(live, true)
		end,
	},
	{
		name = "NewPlayerMode",
		run = function(ctx)
			local mock = jsonStore()
			local store = ProfileStore.new(mock, { jobId = "test-N", placeId = 0, timing = fastTiming() })
			local opened = store:openAsync(9003)
			if not ctx.check("real session", opened ~= nil) then
				return
			end
			local real = opened :: ProfileStore.Session
			local sandbox = store:sandboxSession(9003)
			ctx.check("sandbox flagged", sandbox.sandbox and not real.sandbox and sandbox.status == "ok")
			local live = sandbox -- what getSession returns while the admin is in the mode
			local fakePlayer = (newproxy(false) :: any) :: Player
			local gems = MonetizationConfig.Products.GemsSmall
			local deps: MonetizationService.ReceiptDeps = {
				getProduct = function(id: number): MonetizationConfig.ProductDef?
					return if id == 1 then gems else nil
				end,
				getBuyer = function(userId: number): Player?
					return if userId == 9003 then fakePlayer else nil
				end,
				getSession = function(_player: Player): ProfileStore.Session?
					return live
				end,
				markDirty = function(_player: Player, s: ProfileStore.Session): number
					return store:markDirty(s)
				end,
				commitAsync = function(s: ProfileStore.Session, v: number): boolean
					return store:commitAsync(s, v)
				end,
				allowUnsaved = true, -- even Studio's "acknowledge unsaved" never applies to a sandbox
				now = function(): number
					return os.time()
				end,
			}
			local Decision = Enum.ProductPurchaseDecision
			local purchase = { PurchaseId = "npm-1", PlayerId = 9003, ProductId = 1, CurrencySpent = 49 }
			local writesBefore = mock.writes
			ctx.check(
				"sandbox receipt deferred",
				MonetizationService.processReceiptAsync(purchase, deps) == Decision.NotProcessedYet
			)
			ctx.check("nothing granted into the sandbox", sandbox.profile.gems == 0)
			ctx.check("receipt not recorded in the sandbox", not ProfileLogic.hasReceipt(sandbox.profile, "npm-1"))
			ProfileLogic.addCash(sandbox.profile, 1e6)
			ctx.check("sandbox commit never durable", not store:commitAsync(sandbox, store:markDirty(sandbox)))
			store:saveAsync(sandbox, true)
			ctx.check("sandbox never written", mock.writes == writesBefore, `writes={mock.writes - writesBefore}`)
			-- EXIT: the real session is live again; the re-delivered receipt lands there, once.
			live = real
			ctx.check(
				"granted into the real profile after exit",
				MonetizationService.processReceiptAsync(purchase, deps) == Decision.PurchaseGranted
			)
			ctx.check("real gems granted once", real.profile.gems == gems.gems, `gems={real.profile.gems}`)
			local stored = HttpService:JSONDecode(mock.data["Profile_9003"])
			ctx.check("real grant saved", stored.data.gems == gems.gems and stored.data.cash == 0)
			store:saveAsync(real, true)
		end,
	},
}

return cases
