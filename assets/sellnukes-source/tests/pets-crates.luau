--!strict
--[[
	Supply crate regressions (src/server/Pets/CrateLogic.luau + src/shared/Config/CrateConfig.luau).
	Run:
		lune run tests/pets-crates

	Proves on the shipped modules:
	  1. CrateConfig validates: three crates, weights sum to TotalBp, every reward id resolves,
	     every pity rank is reachable, trails valid.
	  2. rollReward walks cumulative weights exactly at the boundaries; a seeded 200k-open run
	     lands within tolerance of the published odds.
	  3. Pity: the N-th open without rank >= R is forced into those rewards; hits reset; the
	     counter survives across opens; forced picks are proportional to the weights.
	  4. Payment: held crates first (no gems); gems are charged exactly; Restricted (gem AND held
	     opens: both are paid random items) / NotEnough / BadCrate change NOTHING.
	  5. Rewards: boosts stack through BoostLogic, gems are paid, eggs become held eggs, pets get a
	     uid (beyond the soft cap), trails are owned + auto-equipped once, a duplicate trail pays
	     dupGems, a pet at HardCap pays dupGems.
	  6. Receipts: held crates added; a restricted buyer gets the gem price instead; bad input
	     refused. Trail equip rules.
	  7. commitOpen is all-or-nothing.
]]

local Loader = require("./fixtures/RobloxLoader")
-- Lune has no Roblox `Random`; the loader's deterministic LCG stands in.
local Random = Loader.Random

local loader = Loader.new()
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local CrateLogic = loader.load("src/server/Pets/CrateLogic")
local PetLogic = loader.load("src/server/Pets/PetLogic")
local PetState = loader.load("src/server/Pets/PetState")
local CrateConfig = loader.load("src/shared/Config/CrateConfig")
local PetConfig = loader.load("src/shared/Config/PetConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local function scripted(draws: { number }): any
	local index = 0
	return {
		NextInteger = function(_self: any, lo: number, hi: number): number
			index += 1
			local value = draws[index]
			assert(value ~= nil, `scripted RNG ran out at draw {index}`)
			return math.clamp(value, lo, hi)
		end,
	}
end

local NOW = 1_800_000_000

local function newProfile(gems: number?): any
	local profile = ProfileLogic.defaultProfile() :: any
	profile.gems = gems or 0
	PetState.pets(profile)
	PetState.crates(profile)
	PetState.trails(profile)
	return profile
end

local function ctx(random: any?, restricted: boolean?): any
	return { random = random or Random.new(7), now = NOW, restricted = restricted == true }
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

-- Draw that lands on reward `index` of `crate` (its cumulative upper bound).
local function drawFor(crate: any, index: number): number
	local cumulative = 0
	for i = 1, index do
		cumulative += crate.rewards[i].bp
	end
	return cumulative
end

-- 1. Config ----------------------------------------------------------------------------------------
check(#CrateConfig.validate() == 0, `CrateConfig problems: {table.concat(CrateConfig.validate(), "; ")}`)
check(#CrateConfig.Order == 3, "three crates")
local kinds: { [string]: boolean } = {}
for _, id in CrateConfig.Order do
	local crate = CrateConfig.Crates[id]
	local total = 0
	for _, reward in crate.rewards do
		total += reward.bp
		kinds[reward.kind] = true
	end
	check(total == CrateConfig.TotalBp, `{id} weights sum`)
	check(CrateConfig.ByProduct[crate.product] == id, `{id} product index`)
	check(crate.pity ~= nil, `{id} has pity`)
end
for _, kind in { "boost", "gems", "egg", "pet", "trail" } do
	check(kinds[kind] == true, `some crate gives {kind}`)
end

-- 2. Rolls ---------------------------------------------------------------------------------------
local supply = CrateConfig.Crates.supply_crate
do
	check(CrateLogic.rollReward(supply, scripted({ 1 })) == 1, "first reward")
	for index = 1, #supply.rewards do
		local upper = drawFor(supply, index)
		check(CrateLogic.rollReward(supply, scripted({ upper })) == index, `upper bound {index}`)
		if index < #supply.rewards then
			check(CrateLogic.rollReward(supply, scripted({ upper + 1 })) == index + 1, `next {index}`)
		end
	end
	for _, id in CrateConfig.Order do
		local crate = CrateConfig.Crates[id]
		local rng = Random.new(99)
		local counts: { number } = table.create(#crate.rewards, 0)
		local n = 200_000
		for _ = 1, n do
			local index = CrateLogic.rollReward(crate, rng)
			counts[index] += 1
		end
		for index, reward in crate.rewards do
			check(
				math.abs(counts[index] / n - reward.bp / CrateConfig.TotalBp) < 0.005,
				`{id} distribution {reward.key}`
			)
		end
	end
end

-- 3. Pity ----------------------------------------------------------------------------------------
do
	local profile = newProfile(1e6)
	local crates = PetState.crates(profile)
	-- Supply: rank 3 every 6 opens. 5 misses (cash2x_15 = Common) then the 6th is forced.
	for open = 1, 5 do
		local plan = CrateLogic.open(profile, "supply_crate", ctx(scripted({ 1 })))
		check(plan ~= nil and not plan.pityForced, `miss {open}`)
		check(crates.pity.supply_crate == open, `pity counter {open}`)
	end
	check(CrateLogic.pityLeft(supply, crates.pity.supply_crate) == 1, "pity due")
	local forced = CrateLogic.open(profile, "supply_crate", ctx(scripted({ 1, 1 })))
	check(forced.pityForced and PetConfig.rank(forced.reward.rarity) >= 3, "pity forced rank >= Rare")
	check(forced.reward.key == "trail_green_glow", `first eligible reward ({forced.reward.key})`)
	check(crates.pity.supply_crate == nil, "pity reset")
	-- A natural hit resets too.
	crates.pity.supply_crate = 3
	local natural = CrateLogic.open(profile, "supply_crate", ctx(scripted({ drawFor(supply, 6) })))
	check(not natural.pityForced and natural.reward.key == "gems_150", "natural rare")
	check(crates.pity.supply_crate == nil, "natural reset")
	-- Forced picks are proportional among eligible rewards (golden: rank >= 5).
	local golden = CrateConfig.Crates.golden_crate
	local eligible = 0
	for _, reward in golden.rewards do
		if PetConfig.rank(reward.rarity) >= 5 then
			eligible += reward.bp
		end
	end
	check(CrateLogic.rollPityReward(golden, 5, scripted({ eligible })) == #golden.rewards, "pity top reward")
	check(CrateLogic.rollPityReward(golden, 9, scripted({ 1 })) == nil, "unreachable rank")
end

-- 4. Payment + refusals --------------------------------------------------------------------------
do
	local function refused(profile: any, crate: any, context: any, expected: string)
		local before = ProfileLogic.deepCopy(profile)
		local plan, applied, code = CrateLogic.open(profile, crate, context)
		check(plan == nil and applied == nil and code == expected, `expected {expected}, got {code}`)
		check(deepEqual(before, profile), `{expected} changed the profile`)
	end
	refused(newProfile(1e6), "nope", ctx(), "BadCrate")
	refused(newProfile(1e6), 3, ctx(), "BadCrate")
	refused(newProfile(119), "supply_crate", ctx(), "NotEnough")
	refused(newProfile(1e6), "supply_crate", ctx(nil, true), "Restricted")
	-- Gems charged exactly (gem rewards are added after).
	local profile = newProfile(500)
	local plan, applied = CrateLogic.open(profile, "supply_crate", ctx(scripted({ 1 })))
	check(plan.pay == "gems" and plan.price == 120 and applied.gems == 0 and profile.gems == 380, "gem charge")
	-- Held first, free of gems — but a held crate was bought with Robux, so a restricted policy
	-- refuses it (and keeps it).
	check(CrateLogic.grantHeld(profile, "supply_crate", 2), "grant held")
	refused(profile, "supply_crate", ctx(scripted({ 1 }), true), "Restricted")
	check(PetState.crates(profile).held.supply_crate == 2, "restricted held crates kept")
	local heldPlan = CrateLogic.open(profile, "supply_crate", ctx(scripted({ 1 })))
	check(heldPlan ~= nil and heldPlan.pay == "held" and profile.gems == 380, "held open costs no gems")
	check(PetState.crates(profile).held.supply_crate == 1, "held decremented")
	CrateLogic.open(profile, "supply_crate", ctx(scripted({ 1 })))
	check(PetState.crates(profile).held.supply_crate == nil, "held map sparse")
	check(PetState.crates(profile).opened == 3, "opened counter")
	check(CrateLogic.grantHeld(profile, "supply_crate", 0) == false, "grant held 0")
	check(CrateLogic.grantHeld(profile, "nope", 1) == false, "grant held unknown")
end

-- 5. Rewards -------------------------------------------------------------------------------------
do
	local profile = newProfile(1e6)
	-- Boost (cash2x 15 min) stacks.
	CrateLogic.open(profile, "supply_crate", ctx(scripted({ 1 })))
	check(profile.boosts.cash2x == NOW + 900, "boost applied")
	CrateLogic.open(profile, "supply_crate", ctx(scripted({ 1 })))
	check(profile.boosts.cash2x == NOW + 1800, "boost stacks")
	-- Gems reward.
	local before = profile.gems
	local _, gemsApplied = CrateLogic.open(profile, "supply_crate", ctx(scripted({ drawFor(supply, 3) })))
	check(gemsApplied.gems == 40 and profile.gems == before - 120 + 40, "gems reward")
	-- Egg reward → held lucky egg.
	CrateLogic.open(profile, "supply_crate", ctx(scripted({ drawFor(supply, 4) })))
	check(PetState.pets(profile).eggs.lucky_egg == 1, "egg reward held")
	-- Trail: owned + auto-equipped; duplicate pays dupGems.
	local _, trailApplied = CrateLogic.open(profile, "supply_crate", ctx(scripted({ drawFor(supply, 5) })))
	check(trailApplied.isNew and trailApplied.trailEquipped, "trail new + equipped")
	check(PetState.trails(profile).equipped == "trail_green_glow", "trail equipped")
	local dupPlan, dupApplied = CrateLogic.open(profile, "supply_crate", ctx(scripted({ drawFor(supply, 5) })))
	check(dupPlan.dup and dupApplied.dup and dupApplied.gems == supply.dupGems, "dup trail gems")
	-- Pet reward beyond the soft cap.
	for _ = 1, PetConfig.InventoryCap do
		PetLogic.grantPet(profile, "glow_slime", true)
	end
	local _, petApplied = CrateLogic.open(profile, "supply_crate", ctx(scripted({ drawFor(supply, 8) })))
	check(petApplied.uid ~= nil and petApplied.isNew, "crate pet beyond soft cap")
	-- At HardCap the pet becomes dupGems.
	while PetState.ownedCount(profile) < PetConfig.HardCap do
		PetLogic.grantPet(profile, "glow_slime", false)
	end
	local capPlan, capApplied = CrateLogic.open(profile, "supply_crate", ctx(scripted({ drawFor(supply, 8) })))
	check(capPlan.dup and capApplied.gems == supply.dupGems and capApplied.uid == nil, "hard cap → gems")
end

-- 6. Receipts + trails ---------------------------------------------------------------------------
do
	local profile = newProfile(0)
	local ok, gems = CrateLogic.applyReceipt(profile, "golden_crate", 1, false)
	check(ok and gems == 0 and PetState.crates(profile).held.golden_crate == 1, "receipt → held")
	local restrictedOk, restrictedGems = CrateLogic.applyReceipt(profile, "golden_crate", 1, true)
	check(restrictedOk and restrictedGems == 1000 and profile.gems == 1000, "restricted receipt → gems")
	for _, bad in { 0, -1, 1.5, 0 / 0, "1", 101 } do
		check(
			CrateLogic.applyReceipt(profile, "golden_crate", bad, false) == false,
			`bad receipt count {tostring(bad)}`
		)
	end
	check(CrateLogic.applyReceipt(profile, "nope", 1, false) == false, "receipt unknown crate")
	check(CrateLogic.equipTrail(profile, "trail_rainbow") == "BadTrail", "unowned trail")
	check(
		CrateLogic.grantTrail(profile, "trail_rainbow") and not CrateLogic.grantTrail(profile, "trail_rainbow"),
		"grant trail once"
	)
	check(CrateLogic.equipTrail(profile, "trail_rainbow") == "Ok", "equip trail")
	check(CrateLogic.equipTrail(profile, "trail_rainbow") == "Same", "equip same trail")
	check(CrateLogic.equipTrail(profile, "") == "Ok" and PetState.trails(profile).equipped == "", "unequip trail")
	check(CrateLogic.equipTrail(profile, "") == "Same", "unequip twice")
	check(CrateLogic.equipTrail(profile, 5) == "BadTrail", "non-string trail")
end

-- 7. All-or-nothing -------------------------------------------------------------------------------
do
	local profile = newProfile(1e6)
	CrateLogic.grantHeld(profile, "supply_crate", 1)
	local plan = CrateLogic.planOpen(profile, "supply_crate", ctx(scripted({ 1 })))
	check(plan ~= nil, "plan")
	local before = ProfileLogic.deepCopy(profile)
	-- A boost reward whose key is unknown makes commit throw after the held crate was consumed.
	plan.reward = table.clone(plan.reward)
	plan.reward.id = "not_a_boost"
	local ok = pcall(CrateLogic.commitOpen, profile, plan, NOW)
	check(not ok, "bad reward throws")
	check(deepEqual(before, profile), "failed commit restored every field")
end

print(`[pets-crates] {checks} checks passed`)
