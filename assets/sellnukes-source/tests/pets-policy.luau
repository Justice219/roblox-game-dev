--!strict
--[[
	Paid random items × PolicyService regressions for eggs and crates (Roblox policy:
	ArePaidRandomItemsRestricted = "the player can NOT interact with paid random item generators,
	either via in-experience currency bought with Robux or Robux directly"). Run:
		lune run tests/pets-policy

	Proves on the shipped modules (src/server/Economy/PolicyCache, src/server/Pets/{PetLogic,
	CrateLogic, PetGrants}, src/server/Retention/RewardLogic, src/shared/Config/{EggConfig,
	CrateConfig, MonetizationConfig, LuckySpinConfig, GroupConfig}):
	  1. Robux reachability audit: every MonetizationConfig product kind is classified below, and
	     every currency a product can turn Robux into that eggs / crates accept is GATED
	     (EggConfig.PaidRandomCurrencies cash + acorns + Bones, CrateConfig.PaidRandomPay gems +
	     held). A new product kind fails this suite until someone classifies it. World 2 (R57,
	     W11): every non-main world's wallet currency that a product reaches is gated, the
	     WorldCash / WorldStarter kinds are classified, and the Time Traveler Pack's pet is a FIXED
	     pet (never in an egg), so the pack itself is not a paid random item.
	  2. The REAL PolicyCache produces the three server answers — restricted, UNKNOWN (never asked,
	     lookup failing, malformed answer, lookup still pending past the timeout) and unrestricted
	     — and fails closed: every unknown variant reads as restricted.
	  3. The matrix: for each paid way to roll (cash egg, acorn egg, triple with a partial held
	     stack, Bones egg + Bones triple (Dino Valley), Moon Rocks egg (Moon Base), gem crate, held crate) × {restricted, unknown, unrestricted} → refused / refused /
	     allowed, and a refusal changes NOTHING (no charge, no held item spent).
	  4. Robux crate receipts: unknown → deferred, restricted → the gem price, unrestricted → a
	     held crate (CrateLogic.receiptDecision + applyReceipt).
	  5. Free rewards are NOT paid random items: the wheel's Lucky Egg, the group pet, admin /
	     reward eggs are granted with no policy input, and every held egg hatches in all three
	     states.
	  6. The shared helpers the server and client both use: EggConfig.needsPolicy truth table,
	     EggConfig.policyState (snapshot reader, fail closed on anything malformed),
	     CrateConfig.needsPolicy (unknown pay kinds gated), the odds summary, refusal texts.
]]

local task = require("@lune/task")

local Loader = require("./fixtures/RobloxLoader")
local Random = Loader.Random

local loader = Loader.new()
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local PolicyCache = loader.load("src/server/Economy/PolicyCache")
local PetLogic = loader.load("src/server/Pets/PetLogic")
local CrateLogic = loader.load("src/server/Pets/CrateLogic")
local PetState = loader.load("src/server/Pets/PetState")
local PetGrants = loader.load("src/server/Pets/PetGrants")
local RewardLogic = loader.load("src/server/Retention/RewardLogic")
local EggConfig = loader.load("src/shared/Config/EggConfig")
local CrateConfig = loader.load("src/shared/Config/CrateConfig")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")
local LuckySpinConfig = loader.load("src/shared/Config/LuckySpinConfig")
local GroupConfig = loader.load("src/shared/Config/GroupConfig")
local PetConfig = loader.load("src/shared/Config/PetConfig")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

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

local NOW = 1_800_000_000

-- A fresh profile with the pets fields present (as after ProfileLogic.reconcile).
local function newProfile(): any
	local profile = ProfileLogic.defaultProfile() :: any
	PetState.pets(profile)
	PetState.crates(profile)
	PetState.trails(profile)
	return profile
end

-- 1. Robux reachability audit ---------------------------------------------------------------------
-- What each product KIND can turn Robux into (directly or through income). Spins / Barrage /
-- Shield / TurkeyLure grant no egg or crate currency (TurkeyLure's acorns are listed: lured
-- turkeys pay 3x acorns). Crate grants a HELD crate (or the gem price when restricted).
local ROBUX_REACHABLE: { [string]: { string } } = {
	Cash = { "cash" },
	Gems = { "gems" },
	Spins = {},
	StarterPack = { "cash", "gems" },
	SecretPack = { "cash", "gems" },
	DoubleOffline = { "cash" },
	ServerBoost = { "cash" },
	Boost = { "cash" },
	SkipPad = { "cash" },
	Barrage = {},
	Shield = {},
	-- R85 golden revenge nuke: a stored attack launch (no currency).
	RevengeNuke = {},
	Acorns = { "acorns" },
	TurkeyLure = { "acorns" },
	Crate = { "held", "gems" },
	-- R57 / R70 worlds: a world's currency packs (WorldCash) and one-time starter pack (WorldStarter:
	-- currency + a fixed pet + a 2x Cash boost) turn Robux into THAT world's currency (product.world →
	-- WorldsConfig currency key, added generically below: bones, moonrocks, ...). Being
	-- Robux-reachable forces EggConfig.PaidRandomCurrencies[key] = true (paid-random gating).
	WorldCash = {},
	WorldStarter = { "cash" },
	-- R78 Nuke Pass premium: tier rewards pay cash (income), gems, boosts and — only for a
	-- known-unrestricted buyer — paid spins + HELD eggs (restricted / unknown: gems instead,
	-- Server/Pass/PassLogic.premiumReward). Held eggs are never a purchase currency.
	PassPremium = { "cash", "gems", "held" },
	-- R89 Pocket Rocket: a few minutes of the buyer's income (cash only, fixed amount).
	PocketRocket = { "cash" },
}
do
	local reachable: { [string]: boolean } = {}
	for key, product in MonetizationConfig.Products do
		local currencies = ROBUX_REACHABLE[product.kind]
		check(currencies ~= nil, `product {key}: kind {product.kind} is not classified for the paid-random audit`)
		for _, currency in currencies do
			reachable[currency] = true
		end
		-- World products reach their own world's currency (Dino: bones, Moon: moonrocks).
		if product.kind == "WorldCash" or product.kind == "WorldStarter" then
			local world = WorldsConfig.get(product.world)
			if world ~= nil then
				reachable[world.currency.key] = true
			end
		end
	end
	-- The DoubleCash pass multiplies income too: cash is Robux-reachable through passes as well.
	check(MonetizationConfig.getPass("DoubleCash") ~= nil, "DoubleCash pass exists (cash via Robux)")
	reachable.cash = true
	-- Every egg currency that Robux reaches is gated; held eggs are never a purchase.
	for _, eggId in EggConfig.Order do
		local egg = EggConfig.Eggs[eggId]
		if egg.currency ~= "held" then
			check(reachable[egg.currency] == true, `egg {eggId}: {egg.currency} expected Robux-reachable`)
			check(EggConfig.PaidRandomCurrencies[egg.currency] == true, `egg {eggId}: {egg.currency} must be gated`)
		end
	end
	check(EggConfig.PaidRandomCurrencies.cash == true, "cash eggs gated")
	check(EggConfig.PaidRandomCurrencies.acorns == true, "acorn eggs gated")
	check(EggConfig.PaidRandomCurrencies.held == false, "held eggs are not a purchase")
	-- R57 World 2: Bones (Dino Valley's wallet) is Robux-reachable through WorldCash packs and the
	-- Time Traveler Pack, so Bones eggs are gated; every world wallet a product reaches is too.
	check(reachable.bones == true, "Bones are Robux-reachable (WorldCash / WorldStarter)")
	check(EggConfig.PaidRandomCurrencies.bones == true, "Bones eggs gated")
	-- R70 World 3: Moon Rocks (MoonRocks packs + the Astronaut Pack) are gated the same way.
	check(reachable.moonrocks == true, "Moon Rocks are Robux-reachable (WorldCash / WorldStarter)")
	check(EggConfig.PaidRandomCurrencies.moonrocks == true, "Moon Rocks eggs gated")
	for key, product in MonetizationConfig.Products do
		if product.kind == "WorldCash" or product.kind == "WorldStarter" then
			local world = WorldsConfig.get(product.world)
			check(world ~= nil, `product {key}: world {tostring(product.world)} exists`)
			check(
				EggConfig.PaidRandomCurrencies[world.currency.key] == true,
				`product {key}: {world.currency.key} must be gated for eggs`
			)
			check(product.paidRandom ~= true, `product {key}: a fixed pack is not a paid random item`)
			if product.pet ~= nil then
				check(PetGrants.isFixedPet(product.pet), `product {key}: pet {product.pet} is a fixed (non-egg) pet`)
				for _, eggId in EggConfig.Order do
					for _, slot in EggConfig.Eggs[eggId].slots do
						check(slot.pet ~= product.pet, `product {key}: {product.pet} never rolls from {eggId}`)
					end
				end
			end
		end
	end
	-- Crates: gems AND held crates are Robux-reachable, so both pays are gated.
	check(reachable.gems == true and CrateConfig.PaidRandomPay.gems == true, "gem crates gated")
	check(reachable.held == true and CrateConfig.PaidRandomPay.held == true, "held crates gated")
	-- The Robux crate products themselves are flagged paidRandom (MonetizationService prompt gate).
	for productKey in CrateConfig.ByProduct do
		check(MonetizationConfig.Products[productKey].paidRandom == true, `{productKey} is paidRandom`)
	end
	check(#EggConfig.validate() == 0, `EggConfig problems: {table.concat(EggConfig.validate(), "; ")}`)
	check(#CrateConfig.validate() == 0, `CrateConfig problems: {table.concat(CrateConfig.validate(), "; ")}`)
end

-- 2. The REAL PolicyCache's three answers (fail closed) -----------------------------------------
type Answer = { name: string, restricted: boolean, known: boolean }

-- Runs `fn` on its own thread (resolveAsync yields) and waits for it (bounded).
local function await<T>(fn: () -> T): T
	local done, result = false, nil :: any
	task.spawn(function()
		result = fn()
		done = true
	end)
	local waited = 0
	while not done and waited < 3 do
		waited += task.wait(0.01)
	end
	assert(done, "await timed out")
	return result
end

-- A cache whose fetch returns `info` (or errors / never returns), resolved like the services do.
local function answerFrom(name: string, fetch: (any) -> unknown): Answer
	-- One attempt per lookup: a retry's backoff would make resolveAsync task.cancel its pending
	-- timeout, and Lune 0.10 then intermittently never exits (a test-runtime quirk; Roblox is fine).
	local cache = PolicyCache.new({ fetch = fetch, attempts = 1, backoff = 0, timeout = 0.05, retryCooldown = 30 })
	local key = { name = name }
	local restricted = await(function()
		return cache:resolveAsync(key)
	end)
	-- The answer every later request reads without yielding must agree.
	check(cache:isRestricted(key) == restricted, `{name}: isRestricted agrees with resolveAsync`)
	return { name = name, restricted = restricted, known = cache:isKnown(key) }
end

local RESTRICTED = answerFrom("restricted", function()
	return { ArePaidRandomItemsRestricted = true }
end)
local UNRESTRICTED = answerFrom("unrestricted", function()
	return { ArePaidRandomItemsRestricted = false }
end)
-- The "pending" lookup below answers only once released (after its resolveAsync timed out), so
-- no thread is left suspended forever when the suite ends.
local releasePending = false

-- Unknown, five ways: the lookup throws every attempt, the answer is malformed (missing flag /
-- wrong type / not a table), and the lookup does not return within the timeout.
local UNKNOWNS: { Answer } = {
	answerFrom("failing", function()
		error("HTTP 503")
	end),
	answerFrom("missing flag", function()
		return { AreAdsAllowed = true }
	end),
	answerFrom("wrong type", function()
		return { ArePaidRandomItemsRestricted = "false" }
	end),
	answerFrom("not a table", function()
		return "false"
	end),
	answerFrom("pending", function()
		-- Still in flight when resolveAsync's timeout ends (released right after this table).
		while not releasePending do
			task.wait(0.01)
		end
		return { ArePaidRandomItemsRestricted = false }
	end),
}
releasePending = true
do
	check(RESTRICTED.restricted == true and RESTRICTED.known == true, "restricted answer")
	check(UNRESTRICTED.restricted == false and UNRESTRICTED.known == true, "unrestricted answer")
	for _, answer in UNKNOWNS do
		check(answer.restricted == true, `unknown ({answer.name}) fails closed`)
		check(answer.known == false, `unknown ({answer.name}) is not known`)
	end
	-- Never asked at all: restricted too.
	local fresh = PolicyCache.new({
		fetch = function()
			return { ArePaidRandomItemsRestricted = false }
		end,
	})
	check(fresh:isRestricted({}) == true and fresh:isKnown({}) == false, "never asked = restricted")
end

-- Every answer the matrix runs under ("unknown" covers all five unknown variants).
local ANSWERS: { Answer } = { RESTRICTED, UNRESTRICTED }
for _, answer in UNKNOWNS do
	table.insert(ANSWERS, answer)
end

-- The expected outcome: only a KNOWN unrestricted answer may roll a paid random item.
local function allowed(answer: Answer): boolean
	return answer.known and not answer.restricted
end

-- 3a. Eggs: each paid way to hatch × every answer -------------------------------------------------
local function hatchCtx(answer: Answer, overrides: { [string]: any }?): any
	local base: { [string]: any } = {
		random = Random.new(3),
		now = NOW,
		lucky = false,
		triple = true,
		slots = 3,
		atStand = true,
		restricted = answer.restricted, -- what PetService passes after resolvePaidRandomAsync
		eventOpen = nil,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return base
end

type EggCase = { name: string, egg: string, count: number, setup: (profile: any) -> (), overrides: { [string]: any }? }

local garage = EggConfig.get("garage_egg")
local harvest = EggConfig.get("harvest_egg")
local dinoEgg = EggConfig.get("dino_egg")
local moonEgg = EggConfig.get("moon_egg")

-- R57: a Dino Valley player (world unlocked, at Fern Market) with `bones` in worlds.dino.cash.
local function dinoPlayer(profile: any, bones: number)
	local world = ProfileLogic.worldState(profile, "dino")
	world.unlocked = true
	world.tycoon.area = 2
	world.cash = bones
end

-- R70: a Moon Base player (world unlocked, at the Cosmic Diner) with `rocks` in worlds.moon.cash.
local function moonPlayer(profile: any, rocks: number)
	local world = ProfileLogic.worldState(profile, "moon")
	world.unlocked = true
	world.tycoon.area = 2
	world.cash = rocks
end

local PAID_EGGS: { EggCase } = {
	{
		name = "cash egg",
		egg = "garage_egg",
		count = 1,
		setup = function(profile)
			profile.cash = garage.price * 10
		end,
	},
	{
		name = "cash egg x3",
		egg = "garage_egg",
		count = 3,
		setup = function(profile)
			profile.cash = garage.price * 10
		end,
	},
	{
		-- One held egg + two bought: still buys, so still gated.
		name = "cash egg x3 (1 held)",
		egg = "garage_egg",
		count = 3,
		setup = function(profile)
			profile.cash = garage.price * 10
			PetLogic.grantEgg(profile, "garage_egg", 1)
		end,
	},
	{
		name = "acorn egg",
		egg = "harvest_egg",
		count = 1,
		setup = function(profile)
			profile.event.acorns = harvest.price * 10
		end,
		overrides = { now = EggConfig.HarvestStarts, eventOpen = true },
	},
	{
		-- R57 World 2: Bones are Robux-reachable (Bones packs), so a Bones egg is gated like cash.
		name = "Bones egg",
		egg = "dino_egg",
		count = 1,
		setup = function(profile)
			profile.cash = 1e30 -- cash never pays a Bones price, so it must not matter
			dinoPlayer(profile, dinoEgg.price * 10)
		end,
	},
	{
		name = "Bones egg x3 (2 held)",
		egg = "dino_egg",
		count = 3,
		setup = function(profile)
			dinoPlayer(profile, dinoEgg.price * 10)
			PetLogic.grantEgg(profile, "dino_egg", 2)
		end,
	},
	{
		-- R70 World 3: Moon Rocks are Robux-reachable (Moon Rocks packs), so a Moon egg is gated too.
		name = "Moon Rocks egg",
		egg = "moon_egg",
		count = 1,
		setup = function(profile)
			profile.cash = 1e30 -- cash never pays a Moon Rocks price
			moonPlayer(profile, moonEgg.price * 10)
		end,
	},
}

for _, case in PAID_EGGS do
	for _, answer in ANSWERS do
		local profile = newProfile()
		case.setup(profile)
		local egg = EggConfig.get(case.egg)
		local held = PetState.pets(profile).eggs[case.egg] or 0
		check(EggConfig.needsPolicy(egg, held, case.count), `{case.name}: needs the policy`)
		local before = ProfileLogic.deepCopy(profile)
		local pets, code = PetLogic.hatch(profile, case.egg, case.count, hatchCtx(answer, case.overrides))
		if allowed(answer) then
			check(code == "Ok" and pets ~= nil and #pets == case.count, `{case.name} × {answer.name}: allowed`)
		else
			check(code == "Restricted" and pets == nil, `{case.name} × {answer.name}: refused ({code})`)
			check(deepEqual(before, profile), `{case.name} × {answer.name}: refusal changed nothing`)
		end
	end
end

-- 3b. Crates: gem opens and held (Robux) crates × every answer -----------------------------------
type CrateCase = { name: string, setup: (profile: any) -> () }
local supply = CrateConfig.get("supply_crate")
local PAID_CRATES: { CrateCase } = {
	{
		name = "gem crate",
		setup = function(profile)
			profile.gems = supply.gems * 3
		end,
	},
	{
		name = "held crate",
		setup = function(profile)
			profile.gems = 0
			CrateLogic.grantHeld(profile, "supply_crate", 2)
		end,
	},
}
for _, case in PAID_CRATES do
	for _, answer in ANSWERS do
		local profile = newProfile()
		case.setup(profile)
		local before = ProfileLogic.deepCopy(profile)
		local plan, applied, code = CrateLogic.open(
			profile,
			"supply_crate",
			{ random = Random.new(5), now = NOW, restricted = answer.restricted }
		)
		if allowed(answer) then
			check(code == "Ok" and plan ~= nil and applied ~= nil, `{case.name} × {answer.name}: allowed`)
		else
			check(code == "Restricted" and plan == nil, `{case.name} × {answer.name}: refused ({code})`)
			check(deepEqual(before, profile), `{case.name} × {answer.name}: refusal kept everything`)
		end
	end
end

-- 4. Robux crate receipts × every answer ----------------------------------------------------------
for _, answer in ANSWERS do
	local decision = CrateLogic.receiptDecision(answer.known, answer.restricted)
	local expected = if not answer.known then "defer" elseif answer.restricted then "gems" else "crate"
	check(decision == expected, `receipt × {answer.name}: {decision} (expected {expected})`)
	if decision ~= "defer" then
		local profile = newProfile()
		local ok, gems = CrateLogic.applyReceipt(profile, "supply_crate", 1, decision == "gems")
		check(ok, `receipt × {answer.name}: applied`)
		if decision == "gems" then
			check(gems == supply.gems and profile.gems == supply.gems, "restricted buyer gets the gem price")
			check(PetState.crates(profile).held.supply_crate == nil, "restricted buyer gets no crate")
		else
			check(gems == 0 and PetState.crates(profile).held.supply_crate == 1, "unrestricted buyer gets the crate")
		end
	end
end
check(CrateLogic.receiptDecision(false, false) == "defer", "unknown never grants a crate")

-- 5. Free rewards are not paid random items --------------------------------------------------------
do
	local granters = { pet = PetGrants.pet, egg = PetGrants.egg }
	-- The Lucky Wheel's egg slice (free spins) → a held Lucky Egg.
	local eggSlice = nil
	for _, slice in LuckySpinConfig.Slices do
		if slice.reward.egg ~= nil then
			eggSlice = slice
		end
	end
	check(eggSlice ~= nil, "the wheel has an egg slice")
	for _, answer in ANSWERS do
		local profile = newProfile()
		local summary = RewardLogic.apply(profile, eggSlice.reward, NOW, granters, 0)
		check(summary.egg == "lucky_egg" and summary.fallbackGems == 0, `wheel egg granted × {answer.name}`)
		-- The group pet (GroupConfig) lands as a pet with no policy involved.
		local group = RewardLogic.apply(profile, GroupConfig.Reward, NOW, granters, 0)
		check(group.pet == GroupConfig.Reward.pet and group.fallbackGems == 0, `group pet granted × {answer.name}`)
		-- Reward / admin eggs of a CASH egg are held too.
		check(PetGrants.egg(profile, "garage_egg"), "reward egg granted")
		check(PetLogic.grantEgg(profile, "garage_egg", 2), "admin eggs granted")
		-- Every held egg hatches in every state, away from any stand, with no money.
		profile.cash = 0
		local heldCtx = hatchCtx(answer, { atStand = false })
		check(not EggConfig.needsPolicy(EggConfig.get("lucky_egg"), 1, 1), "held lucky egg needs no policy")
		local luckyPets, luckyCode = PetLogic.hatch(profile, "lucky_egg", 1, heldCtx)
		check(luckyCode == "Ok" and #luckyPets == 1, `held Lucky Egg hatches × {answer.name}`)
		check(not EggConfig.needsPolicy(garage, 3, 3), "three held cash eggs need no policy")
		local cashPets, cashCode = PetLogic.hatch(profile, "garage_egg", 3, heldCtx)
		check(cashCode == "Ok" and #cashPets == 3 and profile.cash == 0, `held cash eggs hatch free × {answer.name}`)
		check(PetState.pets(profile).eggs.garage_egg == nil, "held stack spent")
	end
end

-- 6. Shared helpers (server + client) ------------------------------------------------------------
do
	local lucky = EggConfig.get("lucky_egg")
	-- needsPolicy: only when a gated egg must be BOUGHT.
	check(EggConfig.needsPolicy(garage, 0, 1) == true, "cash, none held")
	check(EggConfig.needsPolicy(garage, 1, 1) == false, "cash, held covers 1")
	check(EggConfig.needsPolicy(garage, 2, 3) == true, "cash, held 2 of 3")
	check(EggConfig.needsPolicy(garage, 3, 3) == false, "cash, held covers 3")
	check(EggConfig.needsPolicy(harvest, 0, 1) == true, "acorns, none held")
	check(EggConfig.needsPolicy(lucky, 0, 1) == false, "held-only egg is never bought")
	for _, bad in { 0 / 0, -5, 1.5, math.huge, EggConfig.MaxHeld + 1 } do
		check(EggConfig.needsPolicy(garage, bad, 1) == true, `unusable held {bad} = none held (fail closed)`)
	end
	check(EggConfig.needsPolicy(garage, "3" :: any, 1) == true, "non-number held = none held")
	-- policyState: the client reader of profile.policy (only an explicit known false is allowed).
	check(EggConfig.policyState({ known = true, paidRandomRestricted = false }) == "allowed", "allowed")
	check(EggConfig.policyState({ known = true, paidRandomRestricted = true }) == "restricted", "restricted")
	check(EggConfig.policyState({ known = true, paidRandomRestricted = "no" }) == "restricted", "malformed known")
	check(EggConfig.policyState({ known = true }) == "restricted", "known without a flag")
	check(EggConfig.policyState({ known = false, paidRandomRestricted = false }) == "checking", "not known yet")
	check(EggConfig.policyState({ known = "true", paidRandomRestricted = false }) == "checking", "known not a bool")
	check(EggConfig.policyState(nil) == "checking", "no policy field")
	check(EggConfig.policyState("allowed") == "checking", "policy not a table")
	-- The snapshot PlayerDataService sends for each answer maps to the right UI state.
	for _, answer in ANSWERS do
		local state = EggConfig.policyState({ paidRandomRestricted = answer.restricted, known = answer.known })
		local expected = if not answer.known then "checking" elseif answer.restricted then "restricted" else "allowed"
		check(state == expected, `snapshot × {answer.name}: {state}`)
	end
	-- Crate pays: both gated; an unknown pay kind is gated (fail closed).
	check(CrateConfig.needsPolicy("gems") and CrateConfig.needsPolicy("held"), "crate pays gated")
	check(CrateConfig.needsPolicy("robux"), "unknown pay kind gated")
	-- Refusal texts are the shared friendly ones (never echo input).
	check(
		PetLogic.refusalMessage("Restricted", garage) == EggConfig.PolicyText.RefusedRestricted,
		"egg restricted text"
	)
	check(PetLogic.refusalMessage("PolicyUnknown", garage) == EggConfig.PolicyText.RefusedUnknown, "egg unknown text")
	check(CrateLogic.refusalMessage("Restricted", supply) == CrateConfig.PolicyText.RefusedRestricted, "crate text")
	check(CrateLogic.refusalMessage("PolicyUnknown", supply) == CrateConfig.PolicyText.RefusedUnknown, "crate unknown")
	-- Odds summary (shown next to every repeat crate purchase) sums to 100 % per crate.
	for _, crateId in CrateConfig.Order do
		local crate = CrateConfig.get(crateId)
		local total = 0
		local lastRank = 0
		for _, row in CrateConfig.oddsByRarity(crate) do
			total += row.bp
			local rank = 0
			for index, rarity in PetConfig.Rarities do
				if rarity.id == row.rarity then
					rank = index
				end
			end
			check(rank > lastRank, `{crateId}: odds summary in rarity order`)
			lastRank = rank
		end
		check(total == CrateConfig.TotalBp, `{crateId}: odds summary sums to 100%`)
		check(#CrateConfig.oddsSummary(crate) > 0, `{crateId}: odds summary text`)
	end
	check(CrateConfig.formatChance(50_000) == "50%", "formatChance 50%")
	check(CrateConfig.formatChance(16_500) == "16.5%", "formatChance 16.5%")
	check(CrateConfig.formatChance(200) == "0.2%", "formatChance 0.2%")
	check(CrateConfig.formatChance(1_300) == "1.3%", "formatChance 1.3%")
end

print(`[pets-policy] {checks} checks passed`)
