--!strict
--[[
	World currency isolation (owner R60: "make sure the money in each area doesn't transfer").
	Run: lune run tests/world-currency-isolation

	Boots the REAL server services under Lune — PlayerDataService (in-memory session, the real
	currency routes), TycoonService (runtimes per world, the real pad / click / upgrade handlers,
	the real payout loop on Heartbeat, the real product handlers), RebirthService (the real Rebirth
	remote handler), OfflineService (the real join payout + DoubleOffline handler) and
	ModifierSources (the real cross-world link) — and stubs only what needs a live place: the plot
	builders / PlotService / Knockdown (Instances), Remotes (captured handlers), MonetizationService
	(captured product handlers, no passes) and the pet granter (the real PetLogic on the live
	profile). Every money path is then driven exactly as a player would drive it.

	Proves, for Nuke Town (cash / Rebirth Tokens) and Dino Valley (Bones / Amber):
	  1. Wallet routes: every currency key changes exactly ONE wallet (balance + its totalEarned);
	     PlayerDataService.balance / PetLogic.balanceOf read the same wallet; a world's price can
	     never be paid from another world's wallet.
	  2. Pad buy, producer click (the manual cycle's payout, proven before any manager so nothing
	     else can pay), upgrades, manager (automated) income (each wallet grows by ITS world's
	     rate; a world whose runtime is not running stays put while the other earns),
	     the offline payout on join and its DoubleOffline, Cash packs vs Bones packs vs the Time
	     Traveler Pack, egg hatches priced in a world currency, and rebirth in either world NEVER
	     change the other world's balance, totalEarned or rebirth tokens.
	  3. The cross-world link (linkCash) only changes INCOME MULTIPLIERS: building modifiers and
	     reading income never mutate a wallet; a Dino rebirth raises Nuke Town's income per second
	     and leaves its cash alone (and the other way round).
	  4. Gems stay account-wide by design: gem grants / spends touch only `gems`, and no world
	     action touches gems.
]]

local task = require("@lune/task")
local roblox = require("@lune/roblox")

local Loader = require("./analytics-fixtures/Loader")
-- Lune has no Roblox `Random`; the shared fixture's deterministic LCG stands in (egg rolls).
local RobloxRandom = require("./fixtures/RobloxLoader").Random
local check, done = Loader.checker()

local process = require("@lune/process")

-- The booted services keep loops alive (autosave, payout): the suite ends the process itself, and a
-- watchdog fails it instead of hanging if a wait never resolves.
task.delay(90, function()
	print("[world-currency-isolation] TIMEOUT")
	process.exit(1)
end)

local function main(): any
	local serverNow = 1000
	local env = Loader.new({
		-- In-memory profiles (the Studio "API access off" path of PlayerDataService).
		DataStoreService = {
			GetDataStore = function()
				return {
					GetAsync = function()
						error("API access off (test)")
					end,
				}
			end,
			GetRequestBudgetForRequestType = function()
				return 100
			end,
		},
		PolicyService = {
			GetPolicyInfoForPlayerAsync = function()
				return { ArePaidRandomItemsRestricted = false }
			end,
		},
		Workspace = {
			GetServerTimeNow = function(): number
				return serverNow
			end,
		},
	}, { lenientServices = true })
	env.setTime(1_800_000_000)
	env.setClock(5000)

	--------------------------------------------------------------------------------------------------
	-- Stubs (only what needs a live place)
	--------------------------------------------------------------------------------------------------

	-- Remotes: captured server handlers; client sends are ignored.
	local handlers: { [string]: (...any) -> ...any } = {}
	env.stub(
		"src/shared/Net/Remotes",
		setmetatable({
			onServerEvent = function(name: string, fn: (...any) -> ...any)
				handlers[name] = fn
			end,
			onServerInvoke = function(name: string, fn: (...any) -> ...any)
				handlers[name] = fn
			end,
		}, {
			__index = function(): any
				return function() end
			end,
		})
	)

	-- A fake part (producer anchor / character root) at the origin.
	local function fakePart(): any
		local attributes: { [string]: any } = {}
		return {
			Position = roblox.Vector3.new(0, 0, 0),
			IsA = function(_self: any, className: string): boolean
				return className == "BasePart"
			end,
			SetAttribute = function(_self: any, key: string, value: any)
				attributes[key] = value
			end,
			GetAttribute = function(_self: any, key: string): any
				return attributes[key]
			end,
		}
	end
	local anchor = fakePart()

	-- Any function call answers nil unless listed in `answers` (name → value or function).
	local function proxy(answers: { [string]: any }): any
		return setmetatable({}, {
			__index = function(_self: any, key: string): any
				local answer = answers[key]
				-- Functions and signals (fields with :Connect) are returned as they are.
				if type(answer) == "function" or (type(answer) == "table" and answer.Connect ~= nil) then
					return answer
				end
				return function()
					return answer
				end
			end,
		})
	end
	local builder = proxy({ restore = true, getProducerAnchor = anchor, hasPlots = true })
	env.stub(
		"src/server/World/PlotBuilder",
		proxy({
			restore = true,
			world = function()
				return builder
			end,
		})
	)
	env.stub(
		"src/server/Tycoon/PlotService",
		proxy({
			PlotAssigned = Loader.signal(),
			PlotReleased = Loader.signal(),
			getPlotIndex = 1,
			routeTravel = false,
		})
	)
	env.stub("src/server/Tycoon/Knockdown", proxy({}))
	env.stub("src/server/World/MeshLibrary", proxy({}))

	-- MonetizationService: no passes; product handlers captured (the real TycoonService /
	-- OfflineService handlers run when the test "delivers a receipt").
	local productHandlers: { [string]: (Player, any, any, any) -> boolean } = {}
	env.stub(
		"src/server/Services/MonetizationService",
		proxy({
			PassChanged = Loader.signal(),
			ownsPass = false,
			registerProductHandler = function(kind: string, fn: (Player, any, any, any) -> boolean)
				productHandlers[kind] = fn
			end,
		})
	)

	--------------------------------------------------------------------------------------------------
	-- Boot the real services
	--------------------------------------------------------------------------------------------------

	local player = env.player(4242)
	player.children.leaderstats = {
		FindFirstChild = function()
			return nil
		end,
	}
	local root = fakePart()
	player.Character = {
		FindFirstChild = function(_self: any, name: string): any
			return if name == "HumanoidRootPart" then root else nil
		end,
	}

	local WorldsConfig = env.load("src/shared/Config/Worlds/WorldsConfig")
	local TycoonConfig = env.load("src/shared/Config/TycoonConfig")
	local TycoonLogic = env.load("src/shared/Tycoon/TycoonLogic")
	local MonetizationConfig = env.load("src/shared/Config/MonetizationConfig")
	local EggConfig = env.load("src/shared/Config/EggConfig")
	local ProfileLogic = env.load("src/server/Economy/ProfileLogic")
	local PlayerDataService = env.load("src/server/Services/PlayerDataService")
	local ModifierSources = env.load("src/server/Tycoon/ModifierSources")
	local PetLogic = env.load("src/server/Pets/PetLogic")
	local PetState = env.load("src/server/Pets/PetState")
	local PetGrants = env.load("src/server/Pets/PetGrants")
	local TycoonService = env.load("src/server/Tycoon/TycoonService")
	local RebirthService = env.load("src/server/Tycoon/RebirthService")
	local OfflineService = env.load("src/server/Tycoon/OfflineService")

	local DINO = WorldsConfig.get("dino")
	local MAIN = WorldsConfig.get("main")
	check(DINO ~= nil and MAIN ~= nil, "both worlds registered")

	-- Polls `condition` (yielding) up to `seconds`.
	local function waitFor(condition: () -> boolean, seconds: number): boolean
		local deadline = os.clock() + seconds
		while os.clock() < deadline do
			if condition() then
				return true
			end
			task.wait(0.01)
		end
		return condition()
	end

	PlayerDataService.Start()
	check(
		waitFor(function()
			return PlayerDataService.getProfile(player) ~= nil
		end, 5),
		"in-memory profile loaded"
	)
	local profile = PlayerDataService.getProfile(player)
	check(PlayerDataService.canMutate(player), "Studio in-memory session can play")
	PetState.pets(profile)

	-- Fixed-pet grants (Time Traveler Pack) through the real PetLogic on the live profile.
	PetGrants.useLive(function(target: any, petId: string, _reason: string): (boolean, string?)
		if target ~= player then
			return false, nil
		end
		local uid = PetLogic.grantPet(profile, petId, true)
		return uid ~= nil, uid
	end)

	TycoonService.Init()
	RebirthService.Init()
	OfflineService.Init()
	TycoonService.Start()
	RebirthService.Start()

	-- Nuke Town runtime on plot 1 (PlotService assigns it), then Dino Valley (unlocked, plot built).
	local PlotService = env.load("src/server/Tycoon/PlotService")
	PlotService.PlotAssigned:Fire(player, 1)
	check(
		waitFor(function()
			return TycoonService.isReady(player)
		end, 5),
		"Nuke Town runtime ready"
	)
	local dinoState = ProfileLogic.worldState(profile, "dino")
	dinoState.unlocked = true
	check(TycoonService.ensureWorld(player, "dino", true), "Dino Valley runtime + plot ready")

	--------------------------------------------------------------------------------------------------
	-- The wallets and the isolation assertion
	--------------------------------------------------------------------------------------------------

	type Wallets = { [string]: number }

	-- Every balance / lifetime counter that must never move across worlds (+ gems, account-wide).
	local function wallets(): Wallets
		return {
			cash = profile.cash,
			totalEarned = profile.totalEarned,
			tokens = profile.rebirthTokens,
			bones = dinoState.cash,
			bonesEarned = dinoState.totalEarned,
			amber = dinoState.rebirthTokens,
			gems = profile.gems,
		}
	end

	-- Which wallet fields belong to which world (gems: account-wide, never moved by a world action).
	local WORLD_FIELDS: { [string]: { string } } = {
		main = { "cash", "totalEarned", "tokens" },
		dino = { "bones", "bonesEarned", "amber" },
	}

	--[[
		Asserts that only `world`'s fields may have changed between `before` and now (gems never), and
		returns the deltas. `label` names the action.
	]]
	local function onlyWorld(world: string, before: Wallets, label: string): Wallets
		local after = wallets()
		local delta: Wallets = {}
		for key, value in after do
			delta[key] = value - before[key]
		end
		for otherWorld, fields in WORLD_FIELDS do
			if otherWorld ~= world then
				for _, field in fields do
					check(
						after[field] == before[field],
						`{label}: {field} of {otherWorld} moved ({before[field]} -> {after[field]})`
					)
				end
			end
		end
		check(after.gems == before.gems, `{label}: gems moved`)
		return delta
	end

	-- Seed both wallets (real routes).
	check(PlayerDataService.grantCurrency(player, "cash", 1e9, "test") == 1e9, "seed cash")
	check(PlayerDataService.grantCurrency(player, "bones", 1e9, "test") == 1e9, "seed Bones")

	--------------------------------------------------------------------------------------------------
	-- 1. Wallet routes
	--------------------------------------------------------------------------------------------------
	do
		local routes = {
			{ key = "cash", world = "main", field = "cash", earned = "totalEarned" },
			{ key = MAIN.tokens.key, world = "main", field = "tokens" },
			{ key = DINO.currency.key, world = "dino", field = "bones", earned = "bonesEarned" },
			{ key = DINO.tokens.key, world = "dino", field = "amber" },
		}
		for _, route in routes do
			local before = wallets()
			local added = PlayerDataService.grantCurrency(player, route.key, 7, "test")
			local delta = onlyWorld(route.world, before, `grant {route.key}`)
			check(added == 7 and delta[route.field] == 7, `grant {route.key} lands in {route.field}`)
			if route.earned ~= nil then
				check(delta[route.earned] == 7, `grant {route.key} counts as {route.world} income`)
			end
			for _, other in routes do
				if other.field ~= route.field then
					check(
						delta[other.field] == 0 or other.world == route.world and other.field == route.earned,
						`grant {route.key} left {other.field}`
					)
				end
			end
			check(
				PlayerDataService.balance(profile, route.key) == wallets()[route.field],
				`balance({route.key}) reads {route.field}`
			)
			before = wallets()
			check(PlayerDataService.trySpendCurrency(player, route.key, 7, "test"), `spend {route.key}`)
			delta = onlyWorld(route.world, before, `spend {route.key}`)
			check(delta[route.field] == -7, `spend {route.key} leaves {route.field}`)
			if route.earned ~= nil then
				check(delta[route.earned] == 0, `spending {route.key} is not negative income`)
			end
		end
		check(WorldsConfig.worldOfCurrency(DINO.currency.key) == "dino", "bones belongs to Dino Valley")
		check(WorldsConfig.worldOfCurrency("cash") == "main", "cash belongs to Nuke Town")
		check(DINO.currency.key ~= "cash" and DINO.tokens.key ~= MAIN.tokens.key, "distinct keys")
		check(PetLogic.balanceOf(profile, DINO.currency.key) == dinoState.cash, "PetLogic reads the Bones wallet")
		check(PetLogic.worldWallet(DINO.tokens.key) == nil, "Amber is never an egg wallet")

		-- A Dino price can never be paid with cash (and the other way round).
		local savedBones, savedCash = dinoState.cash, profile.cash
		dinoState.cash = 0
		local before = wallets()
		check(not PlayerDataService.trySpendCurrency(player, DINO.currency.key, 1, "test"), "no Bones, no spend")
		onlyWorld("none", before, "refused Bones spend")
		dinoState.cash = savedBones
		profile.cash = 0
		before = wallets()
		check(not PlayerDataService.trySpendCurrency(player, "cash", 1, "test"), "no cash, no spend")
		onlyWorld("none", before, "refused cash spend")
		profile.cash = savedCash
	end

	--------------------------------------------------------------------------------------------------
	-- 2. Pads, clicks, upgrades, manager income
	--------------------------------------------------------------------------------------------------

	-- Buys pads `from`..`to` of a world's linear order through the real purchasePad.
	local function buyPads(world: any, from: number, to: number)
		local order = if world.id == "main" then TycoonConfig.PadOrder else world.economy.PadOrder
		for index = from, to do
			local pad = order[index]
			local before = wallets()
			local ok, why = TycoonService.purchasePad(player, pad.id)
			check(ok, `{world.id} pad {pad.id}: {tostring(why)}`)
			local delta = onlyWorld(world.id, before, `{world.id} pad {pad.id}`)
			local field = if world.id == "main" then "cash" else "bones"
			check(delta[field] == -pad.cost, `{pad.id} cost {pad.cost} paid from {field} ({delta[field]})`)
		end
	end

	-- Runs the real payout loop for `seconds` of server time (Heartbeat, one tick at a time).
	local function tick(seconds: number)
		local steps = math.ceil(seconds / TycoonService.TickSeconds)
		for _ = 1, steps do
			serverNow += TycoonService.TickSeconds
			env.services.RunService.Heartbeat:Fire(TycoonService.TickSeconds)
		end
	end

	-- Clicks first, while NO producer is automated, so a payout can only come from the click.
	buyPads(MAIN, 1, 1)
	buyPads(DINO, 1, 1)
	check(
		TycoonService.incomePerSecond(player) == 0 and TycoonService.incomePerSecond(player, "dino") == 0,
		"no automated income before the managers"
	)
	do
		local mainProducer = TycoonConfig.PadOrder[1].target
		local dinoProducer = DINO.economy.PadOrder[1].target
		local before = wallets()
		tick(30)
		onlyWorld("none", before, "idle producers pay nothing")
		handlers.ProducerClick(player, mainProducer)
		tick(30) -- longer than one manual cycle
		local delta = onlyWorld("main", before, `Nuke Town click {mainProducer}`)
		check(delta.cash > 0 and delta.totalEarned == delta.cash, "the Nuke Town click paid cash (income)")
		env.advance(1) -- the click limiter refills
		before = wallets()
		handlers.ProducerClick(player, dinoProducer)
		tick(30)
		delta = onlyWorld("dino", before, `Dino click {dinoProducer}`)
		check(delta.bones > 0 and delta.bonesEarned == delta.bones, "the Dino click paid Bones (income)")
	end

	-- The rest of area 1 (incl. each world's Manager pad).
	buyPads(MAIN, 2, #TycoonConfig.AreaPads[1])
	buyPads(DINO, 2, #DINO.economy.AreaPads[1])

	-- A Dino pad with plenty of cash but no Bones is refused and changes nothing.
	do
		local nextDino: string? = nil
		for _, pad in DINO.economy.PadOrder do
			if dinoState.tycoon.pads[pad.id] == nil then
				nextDino = pad.id
				break
			end
		end
		assert(nextDino ~= nil, "a Dino pad is left")
		local savedBones = dinoState.cash
		dinoState.cash = 0
		local before = wallets()
		local ok, why = TycoonService.purchasePad(player, nextDino)
		check(not ok and why == "cash", `Bones-less Dino pad refused ({tostring(why)})`)
		onlyWorld("none", before, "refused Dino pad")
		dinoState.cash = savedBones
	end

	-- Upgrades: the real ProducerUpgrade handler, per world.
	for _, world in { MAIN, DINO } do
		local producers = if world.id == "main" then TycoonConfig.Producers else world.economy.Producers
		local producer = producers[1]
		local before = wallets()
		handlers.ProducerUpgrade(player, producer.id, "10")
		local delta = onlyWorld(world.id, before, `{world.id} upgrade`)
		local field = if world.id == "main" then "cash" else "bones"
		check(delta[field] < 0, `{producer.id} upgrade paid from {field}`)
		env.advance(1) -- the upgrade limiter refills
	end

	-- Automated (manager) income: each world pays ITS rate into ITS wallet.
	do
		tick(TycoonService.TickSeconds) -- runtimes recompute after the pads / upgrades
		local mainRate = TycoonService.incomePerSecond(player)
		local dinoRate = TycoonService.incomePerSecond(player, "dino")
		check(mainRate > 0 and dinoRate > 0, `both worlds earn ({mainRate} / {dinoRate} per s)`)
		local before = wallets()
		tick(10)
		local after = wallets()
		local cashGain, bonesGain = after.cash - before.cash, after.bones - before.bones
		check(math.abs(cashGain - mainRate * 10) <= mainRate * 2, `cash gain {cashGain} ~ {mainRate} x 10`)
		check(math.abs(bonesGain - dinoRate * 10) <= dinoRate * 2, `Bones gain {bonesGain} ~ {dinoRate} x 10`)
		check(after.totalEarned - before.totalEarned == cashGain, "Nuke Town totalEarned = cash income only")
		check(after.bonesEarned - before.bonesEarned == bonesGain, "Dino totalEarned = Bones income only")
		check(
			after.gems == before.gems and after.tokens == before.tokens and after.amber == before.amber,
			"income moves no tokens / gems"
		)
		-- Pause one world's producers (its runtime dropped): the other keeps earning, the paused
		-- wallet stays put.
		TycoonService.releaseWorld(player, "dino")
		before = wallets()
		tick(10)
		local delta = onlyWorld("main", before, "Nuke Town income while Dino Valley is not running")
		check(delta.cash > 0, "Nuke Town still earns")
		check(TycoonService.ensureWorld(player, "dino", true), "Dino Valley runtime back")
	end

	--------------------------------------------------------------------------------------------------
	-- 3. Products: Cash pack vs Bones pack vs Time Traveler Pack
	--------------------------------------------------------------------------------------------------
	do
		local cashPack: any, bonesPack: any, starter: any = nil, nil, nil
		for _, key in MonetizationConfig.ProductOrder do
			local product = MonetizationConfig.getProduct(key)
			if product ~= nil then
				if product.kind == "Cash" and cashPack == nil then
					cashPack = product
				elseif product.kind == "WorldCash" and product.world == "dino" and bonesPack == nil then
					bonesPack = product
				elseif product.kind == "WorldStarter" and product.world == "dino" then
					starter = product
				end
				-- Config guard: a world product names a real world; a Cash pack never does.
				if product.kind == "WorldCash" or product.kind == "WorldStarter" then
					check(
						WorldsConfig.get(product.world) ~= nil and product.world ~= "main",
						`{key}: world product names an extra world`
					)
				elseif product.kind == "Cash" then
					check(product.world == nil, `{key}: a Cash pack is Nuke Town only`)
				end
			end
		end
		check(
			cashPack ~= nil and bonesPack ~= nil and starter ~= nil,
			"Cash pack, Bones pack and Time Traveler Pack exist"
		)

		local before = wallets()
		check(productHandlers.Cash(player, profile, cashPack, {}), "Cash pack receipt")
		local delta = onlyWorld("main", before, `Cash pack {cashPack.key}`)
		check(delta.cash > 0, "Cash pack paid cash")

		before = wallets()
		check(productHandlers.WorldCash(player, profile, bonesPack, {}), "Bones pack receipt")
		delta = onlyWorld("dino", before, `Bones pack {bonesPack.key}`)
		check(delta.bones > 0, "Bones pack paid Bones")

		before = wallets()
		local petsBefore = 0
		for _ in PetState.pets(profile).owned do
			petsBefore += 1
		end
		check(productHandlers.WorldStarter(player, profile, starter, {}), "Time Traveler Pack receipt")
		delta = onlyWorld("dino", before, `Time Traveler Pack {starter.key}`)
		check(delta.bones > 0 and dinoState.starter.bought == true, "Time Traveler Pack paid Bones once")
		local petsAfter = 0
		for _ in PetState.pets(profile).owned do
			petsAfter += 1
		end
		check(petsAfter == petsBefore + 1, "Time Traveler Pack granted its fixed pet")
		before = wallets()
		check(
			productHandlers.WorldStarter(player, profile, starter, {}),
			"a repeat receipt still pays the currency part"
		)
		onlyWorld("dino", before, "Time Traveler Pack repeat")
	end

	--------------------------------------------------------------------------------------------------
	-- 4. Eggs priced in a world currency
	--------------------------------------------------------------------------------------------------
	do
		local ctx = {
			random = RobloxRandom.new(3),
			now = 1_800_000_000,
			lucky = false,
			triple = false,
			slots = 3,
			atStand = true,
			restricted = false,
		}
		-- Nuke Town's first area egg (cash) and Dino Valley's first egg (Bones).
		local mainEgg = "garage_egg"
		check(EggConfig.get(mainEgg).currency == "cash", "the garage egg costs cash")
		check(EggConfig.get("dino_egg").currency == DINO.currency.key, "the Dino Egg costs Bones")
		dinoState.tycoon.area = math.max(dinoState.tycoon.area, 2)
		local before = wallets()
		local _, code = PetLogic.hatch(profile, "dino_egg", 1, ctx)
		check(code == "Ok", `Dino egg hatch ({code})`)
		local delta = onlyWorld("dino", before, "Dino egg (Bones)")
		check(
			delta.bones == -EggConfig.get("dino_egg").price and delta.bonesEarned == 0,
			"Dino egg paid Bones, no income"
		)
		before = wallets()
		local _, mainCode = PetLogic.hatch(profile, mainEgg, 1, ctx)
		check(mainCode == "Ok", `Nuke Town egg hatch ({mainCode})`)
		delta = onlyWorld("main", before, `Nuke Town egg {mainEgg}`)
		check(delta.cash < 0 and delta.totalEarned == 0, "Nuke Town egg paid cash, no income")
	end

	--------------------------------------------------------------------------------------------------
	-- 5. Cross-world link (linkCash): multipliers only
	--------------------------------------------------------------------------------------------------
	do
		local before = wallets()
		local snapshot = ProfileLogic.deepCopy(profile)
		local mainMods = ModifierSources.build(player, profile)
		local dinoMods = ModifierSources.build(player, profile, nil, "dino")
		local _ = TycoonService.incomePerSecond(player) + TycoonService.incomePerSecond(player, "dino")
		onlyWorld("none", before, "building modifiers / reading income")
		check(ProfileLogic.deepCopy(profile).cash == snapshot.cash, "no wallet touched by the link")
		check(mainMods.linkCash == 1 and dinoMods.linkCash == 1, "no rebirths yet: link x1")

		-- Pretend Dino rebirths exist: Nuke Town's MULTIPLIER rises, its cash does not.
		local mainRate = TycoonService.incomePerSecond(player)
		dinoState.rebirths = 2
		ModifierSources.invalidate(player)
		before = wallets()
		local linked = ModifierSources.build(player, profile)
		check(linked.linkCash > 1, `Dino rebirths raise Nuke Town's linkCash ({linked.linkCash})`)
		TycoonService.markDirty(player, nil)
		tick(TycoonService.TickSeconds) -- the runtime recomputes on its next tick
		local afterRate = TycoonService.incomePerSecond(player)
		check(afterRate > mainRate, `Nuke Town income rises with the link ({mainRate} -> {afterRate})`)
		dinoState.rebirths = 0
		ModifierSources.invalidate(player)
		TycoonService.markDirty(player, nil)
		tick(TycoonService.TickSeconds)
	end

	--------------------------------------------------------------------------------------------------
	-- 6. Offline payout on join (+ DoubleOffline)
	--------------------------------------------------------------------------------------------------
	do
		-- The services read the fake clock: away exactly one hour by THEIR os.time.
		env.setTime(1_800_100_000)
		profile.offline.lastSeenAt = 1_800_100_000 - 3600
		local preview = OfflineService.preview(player, 3600)
		local expected: { [string]: number } = {}
		for _, row in preview do
			expected[row.id] = row.amount
		end
		check((expected.main or 0) > 0 and (expected.dino or 0) > 0, "both worlds earn offline")
		local before = wallets()
		OfflineService.payOnJoin(player, profile)
		local after = wallets()
		check(
			math.abs((after.cash - before.cash) - expected.main) <= expected.main * 1e-9 + 1e-6,
			"cash = Nuke Town's offline row"
		)
		check(
			math.abs((after.bones - before.bones) - expected.dino) <= expected.dino * 1e-9 + 1e-6,
			"Bones = Dino's offline row"
		)
		check(
			after.tokens == before.tokens and after.amber == before.amber and after.gems == before.gems,
			"offline moves no tokens / gems"
		)
		before = wallets()
		check(productHandlers.DoubleOffline(player, profile, {}, {}), "DoubleOffline receipt")
		after = wallets()
		check(
			math.abs((after.cash - before.cash) - expected.main) <= expected.main * 1e-9 + 1e-6,
			"double: cash row again"
		)
		check(
			math.abs((after.bones - before.bones) - expected.dino) <= expected.dino * 1e-9 + 1e-6,
			"double: Bones row again"
		)
	end

	--------------------------------------------------------------------------------------------------
	-- 7. Rebirth in either world
	--------------------------------------------------------------------------------------------------
	do
		-- Dino rebirth through the real Rebirth("dino") handler: own every Dino pad (the finale).
		for _, pad in DINO.economy.PadOrder do
			dinoState.tycoon.pads[pad.id] = true
		end
		local logic = TycoonLogic.forWorld("dino")
		check(logic.canRebirth(dinoState.tycoon), "Dino finale owned")
		local before = wallets()
		handlers.Rebirth(player, "dino")
		check(
			waitFor(function()
				return dinoState.rebirths == 1
			end, 2),
			"Dino rebirth applied"
		)
		local delta = onlyWorld("dino", before, "Dino rebirth")
		check(delta.amber > 0, "Dino rebirth paid Amber")
		check(dinoState.cash == logic.startingCash(dinoState.rebirthShop), "Bones reset to the Bone Stash")

		-- Nuke Town rebirth through the real Rebirth() handler.
		env.advance(10)
		for _, pad in TycoonConfig.PadOrder do
			profile.tycoon.pads[pad.id] = true
		end
		check(TycoonLogic.canRebirth(profile.tycoon), "Nuke Town finale owned")
		before = wallets()
		handlers.Rebirth(player)
		check(
			waitFor(function()
				return profile.rebirths == 1
			end, 2),
			"Nuke Town rebirth applied"
		)
		delta = onlyWorld("main", before, "Nuke Town rebirth")
		check(delta.tokens > 0, "Nuke Town rebirth paid Rebirth Tokens")
	end

	--------------------------------------------------------------------------------------------------
	-- 8. Gems are account-wide (by design) and only move on gem actions
	--------------------------------------------------------------------------------------------------
	do
		local before = wallets()
		check(PlayerDataService.grantGems(player, 25, "test") == 25, "gem grant")
		local after = wallets()
		for key, value in after do
			if key ~= "gems" then
				check(value == before[key], `a gem grant left {key}`)
			end
		end
		check(after.gems == before.gems + 25, "gems added once, account-wide")
	end

	return env
end

local ok, result = xpcall(main, debug.traceback)
if not ok then
	print(`[world-currency-isolation] FAILED: {result}`)
	process.exit(1)
end
result.close()
done("world-currency-isolation")
process.exit(0)
