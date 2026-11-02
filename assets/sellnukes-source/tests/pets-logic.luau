--!strict
--[[
	Pets + eggs regressions (src/server/Pets/PetLogic.luau, PetState, RequestMemory, PetGrants,
	src/shared/Config/{PetConfig, EggConfig}). Run:
		lune run tests/pets-logic

	Proves on the shipped modules:
	  1. Configs validate: 76 pets (incl. the R78 Golden Nukey), 16 eggs, every egg's odds (normal AND lucky) sum to TotalBp,
	     bonuses rise with rarity inside an egg, ids are save-safe, HardCap = ProfileLogic MaxPets.
	  2. rollSlot walks the cumulative odds exactly at every boundary; a seeded 200k-roll run
	     lands within tolerance of the published odds (normal and Lucky Eggs).
	  3. Pity: the N-th hatch without the top slot is forced to it, a natural hit resets the
	     counter, triple hatches advance the counter per roll.
	  4. Hatch refusals (BadEgg, BadCount incl. NaN / strings / 2, NeedTriple, Closed, Locked,
	     NoEggs, TooFar, Restricted, NotEnough, Full) change NOTHING.
	  5. Payment: exact cash charge; held eggs pay first and need no stand; mixed held + bought;
	     acorn eggs spend event.acorns.
	  6. Grants: new uids are unique and increasing, pets.index marks new species, free slots are
	     auto-filled (never beyond the slot count), stats.hatched counts.
	  7. Equip / Equip Best / trim / delete (locked skipped, equipped removed) / lock.
	  8. Reward grants respect soft vs hard caps; held egg bounds.
	  9. Cash bonus and the replicated attribute encode / decode (hostile text).
	 10. commitHatch is all-or-nothing (a failing plan restores every field).
	 11. RequestMemory: a repeated request id returns the same payload; FIFO eviction; busy flag.
	 12. World 2 "Dino Valley" (owner R57, W11): the Dino / Volcano eggs (world "dino", Bones,
	     spec odds tiers + pity, prices from the Dino economy, stands "dino:EggStands1/2", the
	     WorldDef.eggs mirror), the 9 dino pets (spec names / rarities / bonus tiers), the unlock
	     gate (Dino locked → Locked; Dino area 2 / 5), Bones paid ONLY from worlds.dino.cash (cash
	     never pays a Bones price), refunds without income, the Bones paid-random gate, held Dino
	     eggs hatch anywhere, world refusal texts, parseStand on hostile input, PetGrants
	     fixed-pet grants (Time Ptero) and the client EggView text / balance helpers.
	 13. World 3 "Moon Base" (owner R70, W11): the Moon / Comet eggs (world "moon", Moon Rocks, the
	     Dino eggs' odds tiers + pity, prices from the Moon economy, stands "moon:EggStands1/2"),
	     the 9 space pets (names / rarities / tiers 4 / 7 / 5), the Moon unlock gate, Moon Rocks
	     paid ONLY from worlds.moon (never Bones or cash), the Moon Rocks policy gate, refusal texts,
	     the Rocket Corgi fixed grant and EggView text.
]]

local Loader = require("./fixtures/RobloxLoader")
-- Lune has no Roblox `Random`; the loader's deterministic LCG stands in.
local Random = Loader.Random

local loader = Loader.new()
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local PetLogic = loader.load("src/server/Pets/PetLogic")
local PetState = loader.load("src/server/Pets/PetState")
local PetGrants = loader.load("src/server/Pets/PetGrants")
local RequestMemory = loader.load("src/server/Pets/RequestMemory")
local PetConfig = loader.load("src/shared/Config/PetConfig")
local EggConfig = loader.load("src/shared/Config/EggConfig")
local CrateConfig = loader.load("src/shared/Config/CrateConfig")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local EggView = loader.load("src/client/Pets/EggView")
local roblox = require("@lune/roblox")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- A scripted RNG: returns the queued draws in order (clamped into [lo, hi]).
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

-- A fresh profile with `cash` and area `area`.
local function newProfile(cash: number?, area: number?): any
	local profile = ProfileLogic.defaultProfile() :: any
	profile.cash = cash or 0
	profile.tycoon.area = area or 1
	-- The pets fields requested from B1 (eggs / pity / index, crates, trails) exist after
	-- ProfileLogic.reconcile; PetState creates them the same way for a bare default profile.
	PetState.pets(profile)
	PetState.crates(profile)
	PetState.trails(profile)
	return profile
end

-- A hatch context with sensible defaults.
local function ctx(overrides: { [string]: any }?): any
	local base: { [string]: any } = {
		random = Random.new(1),
		now = 1_800_000_000,
		lucky = false,
		triple = true,
		slots = 3,
		atStand = true,
		restricted = false,
		eventOpen = nil,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return base
end

-- Deep copy for before/after comparisons.
local function snapshot(profile: any): any
	return ProfileLogic.deepCopy(profile)
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

-- 1. Configs ------------------------------------------------------------------------------------
check(#PetConfig.validate() == 0, `PetConfig problems: {table.concat(PetConfig.validate(), "; ")}`)
check(#EggConfig.validate() == 0, `EggConfig problems: {table.concat(EggConfig.validate(), "; ")}`)
check(PetConfig.Count >= 24, "at least 24 pets")
-- 75 + the R78 Golden Nukey (Nuke Pass exclusive; its Index / grant checks live in tests/pet-index).
check(PetConfig.Count == 76, `roster size {PetConfig.Count}`)
check(#EggConfig.Order == 16, "10 area eggs + harvest + lucky + 2 Dino Valley + 2 Moon Base eggs")
check(PetConfig.HardCap == ProfileLogic.Limits.MaxPets, "HardCap must equal ProfileLogic MaxPets")
check(PetConfig.Slots.Max <= ProfileLogic.Limits.MaxEquipped, "slots fit the profile bound")
do
	local rarities: { [string]: boolean } = {}
	for _, id in PetConfig.Order do
		rarities[PetConfig.Pets[id].rarity] = true
	end
	for _, def in PetConfig.Rarities do
		check(rarities[def.id] == true, `rarity {def.id} has pets`)
	end
	-- Every pet referenced by other systems exists.
	for _, id in { "group_glow_kitty", "starter_atom_pup", "secret_golden_nuke", "lucky_atom", "gobble_bomb", "time_ptero", "rocket_corgi" } do
		check(PetConfig.get(id) ~= nil, `special pet {id}`)
	end
	check(EggConfig.get("lucky_egg") ~= nil and EggConfig.get("harvest_egg") ~= nil, "special eggs")
	for _, id in EggConfig.Order do
		local egg = EggConfig.Eggs[id]
		for _, lucky in { false, true } do
			local total = 0
			for _, bp in EggConfig.oddsFor(egg, lucky) do
				check(bp > 0, `{id} slot weight positive`)
				total += bp
			end
			check(total == EggConfig.TotalBp, `{id} odds sum (lucky {lucky})`)
		end
		local normal, lucky = EggConfig.oddsFor(egg, false), EggConfig.oddsFor(egg, true)
		check(lucky[3] == normal[3] * 2 and lucky[4] == normal[4] * 2, `{id} lucky doubles rare slots`)
		check(lucky[2] == normal[2], `{id} lucky keeps slot 2`)
	end
	-- Area eggs get pricier with the area (economy tiers).
	local last = 0
	for area = 1, 10 do
		local egg = EggConfig.Eggs[EggConfig.Order[area]]
		check(egg.area == area and egg.currency == "cash", `egg {area} is the area egg`)
		check(egg.price > last, `egg {area} price rises`)
		last = egg.price
	end
	-- 40 x the Workbench's level-1 upgrade cost, pinned to $10 by owner R65 (was 40 x $14 = $560).
	check(EggConfig.Eggs.garage_egg.price == 400, `garage egg price {EggConfig.Eggs.garage_egg.price}`)
end
-- Art contract (B8f): every pet species, egg and crate mesh key exists in MeshAssets, eggs have
-- ShellTop* / ShellBottom* pieces and crates a Lid* piece (the reveal animations move them).
do
	local function hasPrefix(key: string, prefix: string): boolean
		for name in MeshAssets[key].pieces do
			if string.sub(name, 1, #prefix) == prefix then
				return true
			end
		end
		return false
	end
	for _, id in PetConfig.Order do
		check(MeshAssets[PetConfig.Pets[id].model] ~= nil, `pet {id}: mesh {PetConfig.Pets[id].model} missing`)
	end
	for _, id in EggConfig.Order do
		local key = EggConfig.Eggs[id].model
		check(MeshAssets[key] ~= nil, `egg {id}: mesh {key} missing`)
		check(hasPrefix(key, "ShellTop") and hasPrefix(key, "ShellBottom"), `egg {id}: ShellTop/ShellBottom pieces`)
	end
	for _, id in CrateConfig.Order do
		local key = CrateConfig.Crates[id].model
		check(MeshAssets[key] ~= nil, `crate {id}: mesh {key} missing`)
		check(hasPrefix(key, "Lid"), `crate {id}: Lid piece`)
	end
end
check(PetConfig.slotsFor(false, 0) == 3, "base slots")
check(PetConfig.slotsFor(true, 0) == 5, "pass slots")
check(PetConfig.slotsFor(true, 2) == 7, "max slots")
check(PetConfig.slotsFor(true, 99) == 7, "slots clamp shop level")
check(PetConfig.slotsFor(false, 0 / 0) == 3, "NaN shop level")
check(PetConfig.formatBonus(0.2) == "+20%", "format bonus")
check(PetConfig.bonusFor("Secret", 10) == 7.45, "secret tier 10 bonus")

-- 2. Rolls ---------------------------------------------------------------------------------------
local garage = EggConfig.Eggs.garage_egg
do
	local odds = EggConfig.oddsFor(garage, false) -- 65000 27000 7000 1000
	local cases = {
		{ 1, 1 },
		{ 65_000, 1 },
		{ 65_001, 2 },
		{ 92_000, 2 },
		{ 92_001, 3 },
		{ 99_000, 3 },
		{ 99_001, 4 },
		{ 100_000, 4 },
	}
	for _, case in cases do
		check(PetLogic.rollSlot(odds, scripted({ case[1] })) == case[2], `rollSlot draw {case[1]}`)
	end
	check(PetLogic.rollPitySlot(odds, 4, scripted({ 1 })) == 4, "pity slot 4 only")
	check(PetLogic.rollPitySlot(odds, 3, scripted({ 7_000 })) == 3, "pity 3..4 low")
	check(PetLogic.rollPitySlot(odds, 3, scripted({ 7_001 })) == 4, "pity 3..4 high")
	-- Distribution: 200k seeded rolls within 0.5 percentage points (normal + lucky).
	for _, lucky in { false, true } do
		local rng = Random.new(42)
		local weights = EggConfig.oddsFor(garage, lucky)
		local counts = { 0, 0, 0, 0 }
		local n = 200_000
		for _ = 1, n do
			local slot = PetLogic.rollSlot(weights, rng)
			counts[slot] += 1
		end
		for slot = 1, 4 do
			local expected = weights[slot] / EggConfig.TotalBp
			check(math.abs(counts[slot] / n - expected) < 0.005, `distribution slot {slot} lucky {lucky}`)
		end
	end
end

-- 3. Pity ----------------------------------------------------------------------------------------
do
	local profile = newProfile(1e9)
	local pets = PetState.pets(profile)
	pets.pity.garage_egg = 149 -- the 150th hatch is due
	-- Natural roll 1 (slot 1) is overridden: pity draw 1 → slot 4.
	local result, code = PetLogic.hatch(profile, "garage_egg", 1, ctx({ random = scripted({ 1, 1 }) }))
	check(code == "Ok" and result ~= nil, "pity hatch ok")
	check(result[1].slot == 4 and result[1].pityForced, "pity forced slot 4")
	check(result[1].petId == "rad_raccoon", "pity pet")
	check(pets.pity.garage_egg == nil, "pity reset after the guarantee")
	-- A natural top roll resets without forcing.
	pets.pity.garage_egg = 10
	local natural = PetLogic.hatch(profile, "garage_egg", 1, ctx({ random = scripted({ 100_000 }) }))
	check(natural[1].slot == 4 and not natural[1].pityForced, "natural top")
	check(pets.pity.garage_egg == nil, "natural top resets")
	-- Misses count up.
	PetLogic.hatch(profile, "garage_egg", 1, ctx({ random = scripted({ 1 }) }))
	check(pets.pity.garage_egg == 1, "miss counts")
	-- Triple: counter 148 → roll 1 miss (149), roll 2 due → forced (0), roll 3 miss (1).
	pets.pity.garage_egg = 148
	local triple = PetLogic.hatch(profile, "garage_egg", 3, ctx({ random = scripted({ 1, 1, 1, 1 }) }))
	check(not triple[1].pityForced and triple[2].pityForced and not triple[3].pityForced, "triple pity per roll")
	check(pets.pity.garage_egg == 1, "triple pity counter")
	-- Pity re-roll respects lucky odds proportions: lucky odds slot 3 = 14000, 4 = 2000 (minSlot 4 → 4).
	check(EggConfig.pityLeft(garage, 149) == 1 and EggConfig.pityLeft(garage, 0) == 150, "pityLeft")
end

-- 4. Refusals change nothing ----------------------------------------------------------------------
do
	local function refused(profile: any, egg: any, count: any, context: any, expected: string)
		local before = snapshot(profile)
		local result, code = PetLogic.hatch(profile, egg, count, context)
		check(result == nil and code == expected, `expected {expected}, got {code}`)
		check(deepEqual(before, profile), `{expected} changed the profile`)
	end
	local profile = newProfile(1e12, 3)
	refused(profile, "nope", 1, ctx(), "BadEgg")
	refused(profile, 7, 1, ctx(), "BadEgg")
	for _, bad in { 2, 0, -1, 1.5, 0 / 0, math.huge, "1", "3", {}, nil } do
		refused(profile, "garage_egg", bad, ctx(), "BadCount")
	end
	refused(profile, "garage_egg", 3, ctx({ triple = false }), "NeedTriple")
	refused(profile, "mine_egg", 1, ctx(), "Locked") -- area 4 egg at area 3
	refused(profile, "garage_egg", 1, ctx({ atStand = false }), "TooFar")
	refused(profile, "lucky_egg", 1, ctx(), "NoEggs")
	refused(newProfile(garage.price - 1), "garage_egg", 1, ctx(), "NotEnough")
	refused(newProfile(garage.price * 3 - 1), "garage_egg", 3, ctx(), "NotEnough")
	-- Harvest egg: closed outside the window, restricted by policy, acorns checked.
	local harvest = newProfile(0)
	harvest.event.acorns = 1_000
	refused(harvest, "harvest_egg", 1, ctx({ now = EggConfig.HarvestStarts - 1 }), "Closed")
	refused(harvest, "harvest_egg", 1, ctx({ now = EggConfig.HarvestEnds }), "Closed")
	refused(harvest, "harvest_egg", 1, ctx({ now = EggConfig.HarvestStarts, eventOpen = false }), "Closed")
	refused(harvest, "harvest_egg", 1, ctx({ now = EggConfig.HarvestStarts, restricted = true }), "Restricted")
	harvest.event.acorns = 29
	refused(harvest, "harvest_egg", 1, ctx({ now = EggConfig.HarvestStarts }), "NotEnough")
	-- Cash eggs ARE policy-gated (cash is Robux-reachable; tests/pets-policy.luau has the matrix).
	refused(newProfile(1e6), "garage_egg", 1, ctx({ restricted = true }), "Restricted")
	-- A held egg of a cash egg hatches even when restricted (nothing is bought).
	local heldOk = newProfile(0)
	PetLogic.grantEgg(heldOk, "garage_egg", 1)
	check(select(2, PetLogic.hatch(heldOk, "garage_egg", 1, ctx({ restricted = true }))) == "Ok", "held egg not gated")
	-- Full inventory.
	local full = newProfile(1e12)
	for _ = 1, PetConfig.InventoryCap do
		PetLogic.grantPet(full, "glow_slime", true)
	end
	refused(full, "garage_egg", 1, ctx(), "Full")
	check(PetLogic.grantPet(full, "glow_slime", true) == nil, "soft grant refused at the cap")
	check(PetLogic.grantPet(full, "glow_slime", false) ~= nil, "hard grant beyond the soft cap")
end

-- 5. Payment --------------------------------------------------------------------------------------
do
	local profile = newProfile(10_000)
	local pets, code, plan = PetLogic.hatch(profile, "garage_egg", 3, ctx())
	check(code == "Ok" and pets ~= nil and plan ~= nil, "triple ok")
	check(profile.cash == 10_000 - garage.price * 3, `cash charged exactly ({profile.cash})`)
	check(profile.totalEarned == 0, "a charge never touches totalEarned")
	check(plan.currency == "cash" and plan.total == garage.price * 3 and plan.bought == 3, "plan numbers")
	-- Held eggs first, no stand needed, no money.
	local held = newProfile(0)
	PetLogic.grantEgg(held, "lucky_egg", 2)
	local hatched, heldCode, heldPlan = PetLogic.hatch(held, "lucky_egg", 1, ctx({ atStand = false }))
	check(heldCode == "Ok" and hatched ~= nil and heldPlan.fromHeld == 1 and heldPlan.total == 0, "held hatch")
	check(PetState.pets(held).eggs.lucky_egg == 1, "one held egg spent")
	PetLogic.hatch(held, "lucky_egg", 1, ctx({ atStand = false }))
	check(PetState.pets(held).eggs.lucky_egg == nil, "held map stays sparse")
	-- Mixed: 1 held garage egg + 2 bought.
	local mixed = newProfile(garage.price * 2)
	PetLogic.grantEgg(mixed, "garage_egg", 1)
	local _, mixedCode, mixedPlan = PetLogic.hatch(mixed, "garage_egg", 3, ctx())
	check(mixedCode == "Ok" and mixedPlan.fromHeld == 1 and mixedPlan.bought == 2 and mixed.cash == 0, "mixed payment")
	-- Acorns.
	local acorn = newProfile(0)
	acorn.event.acorns = 100
	local _, acornCode = PetLogic.hatch(acorn, "harvest_egg", 3, ctx({ now = EggConfig.HarvestStarts + 10 }))
	check(acornCode == "Ok" and acorn.event.acorns == 10, "acorns spent")
end

-- 6. Grants ---------------------------------------------------------------------------------------
do
	local profile = newProfile(1e9)
	local seen: { [string]: boolean } = {}
	local lastUid = 0
	for _ = 1, 10 do
		local pets = PetLogic.hatch(profile, "garage_egg", 3, ctx({ slots = 3 }))
		for _, pet in pets do
			check(not seen[pet.uid], "uid unique")
			seen[pet.uid] = true
			local n = tonumber(pet.uid) :: number
			check(n > lastUid, "uids increase")
			lastUid = n
			check(PetState.pets(profile).index[pet.petId] == true, "index marks the species")
		end
	end
	check(#PetState.pets(profile).equipped == 3, "free slots auto-filled, never beyond")
	check(PetState.ownedCount(profile) == 30, "30 pets owned")
	check(profile.stats.hatched == 30, "stats.hatched")
	-- isNew only for the first of a species.
	local fresh = newProfile(1e9)
	local first = PetLogic.hatch(fresh, "garage_egg", 1, ctx({ random = scripted({ 1 }) }))
	local second = PetLogic.hatch(fresh, "garage_egg", 1, ctx({ random = scripted({ 1 }) }))
	check(first[1].isNew and not second[1].isNew, "isNew once per species")
	check(first[1].equipped and second[1].equipped, "first pets equipped")
end

-- 7. Equip / best / trim / delete / lock ----------------------------------------------------------
do
	local profile = newProfile(0)
	local slime = PetLogic.grantPet(profile, "glow_slime", true)
	local fox = PetLogic.grantPet(profile, "fission_fox", true)
	local secret = PetLogic.grantPet(profile, "quark_nukey", true)
	local pup = PetLogic.grantPet(profile, "atom_pup", true)
	check(PetLogic.setEquipped(profile, slime, true, 2) == "Ok", "equip")
	check(PetLogic.setEquipped(profile, slime, true, 2) == "Same", "equip same")
	check(PetLogic.setEquipped(profile, pup, true, 2) == "Ok", "equip 2")
	check(PetLogic.setEquipped(profile, fox, true, 2) == "NoSlot", "slot cap")
	check(PetLogic.setEquipped(profile, "999", true, 2) == "BadPet", "unknown uid")
	check(PetLogic.setEquipped(profile, 5, true, 2) == "BadPet", "non-string uid")
	check(PetLogic.setEquipped(profile, pup, false, 2) == "Ok", "unequip")
	check(PetLogic.setEquipped(profile, pup, false, 2) == "Same", "unequip same")
	check(PetLogic.equipBest(profile, 3) == true, "equip best changes")
	local equipped = PetState.pets(profile).equipped
	check(equipped[1] == secret and equipped[2] == fox and equipped[3] == pup, "best order")
	check(PetLogic.equipBest(profile, 3) == false, "equip best idempotent")
	check(math.abs(PetLogic.cashBonus(profile) - (7.45 + 0.12 + 0.07)) < 1e-9, "cash bonus sum")
	local ids = PetLogic.equippedPetIds(profile)
	check(PetConfig.encodeEquipped(ids) == "quark_nukey,fission_fox,atom_pup", "attribute encode")
	local decoded = PetConfig.decodeEquipped("quark_nukey,<script>,fission_fox,,atom_pup")
	check(#decoded == 3 and decoded[2] == "fission_fox", "attribute decode drops junk")
	check(#PetConfig.decodeEquipped(string.rep("a", 600)) == 0, "attribute decode length cap")
	check(#PetConfig.decodeEquipped(5) == 0, "attribute decode type")
	check(PetLogic.trimEquipped(profile, 2) == true and #equipped == 2, "trim to slots")
	-- Lock + delete.
	check(PetLogic.lockPets(profile, { secret, "nope" }, true) == 1, "lock one")
	check(PetLogic.lockPets(profile, { secret }, true) == 0, "lock idempotent")
	local deleted, lockedSkipped = PetLogic.deletePets(profile, { secret, fox, slime, "ghost" })
	check(#deleted == 2 and lockedSkipped == 1, "delete skips locked")
	check(PetState.pets(profile).owned[secret] ~= nil and PetState.pets(profile).owned[fox] == nil, "delete result")
	check(table.find(equipped, fox) == nil, "deleted pet unequipped")
	check(PetLogic.lockPets(profile, { secret }, false) == 1, "unlock")
	-- trimEquipped drops dangling uids.
	table.insert(equipped, "dangling")
	check(PetLogic.trimEquipped(profile, 7) == true and table.find(equipped, "dangling") == nil, "trim dangling")
end

-- 8. Reward grants ---------------------------------------------------------------------------------
do
	local profile = newProfile(0)
	check(PetGrants.pet(profile, "starter_atom_pup") == true, "PetGrants.pet")
	check(PetGrants.pet(profile, "not_a_pet") == false, "PetGrants unknown pet")
	check(PetGrants.egg(profile, "lucky_egg") == true, "PetGrants.egg")
	check(PetGrants.grantEggToProfile(profile, "nope") == false, "PetGrants unknown egg")
	check(PetLogic.grantEgg(profile, "lucky_egg", 0) == false, "egg count 0")
	check(PetLogic.grantEgg(profile, "lucky_egg", 1.5) == false, "egg count fraction")
	check(PetLogic.grantEgg(profile, "lucky_egg", 5000) == false, "egg count huge")
	check(PetState.pets(profile).eggs.lucky_egg == 1, "held eggs")
end

-- 10. commitHatch all-or-nothing ---------------------------------------------------------------------
do
	local profile = newProfile(1e6)
	PetLogic.hatch(profile, "garage_egg", 1, ctx())
	local plan = PetLogic.planHatch(profile, "garage_egg", 3, ctx())
	check(plan ~= nil, "plan")
	local before = snapshot(profile)
	-- Corrupt the last roll so commit throws midway.
	plan.rolls[3] = { slot = 1, petId = "does_not_exist", pityForced = false }
	local ok = pcall(PetLogic.commitHatch, profile, plan, 3)
	check(not ok, "bad plan throws")
	check(deepEqual(before, profile), "failed commit restored every field")
end

-- 11. RequestMemory ----------------------------------------------------------------------------------
do
	local memory = RequestMemory.new(3)
	local player = {}
	check(memory:get(player, 1) == nil, "empty memory")
	memory:remember(player, 1, "a")
	memory:remember(player, 2, "b")
	check(memory:get(player, 1) == "a", "remembered")
	memory:remember(player, 3, "c")
	memory:remember(player, 4, "d")
	check(memory:get(player, 1) == nil and memory:get(player, 4) == "d", "FIFO eviction")
	check(memory:tryBegin(player) and not memory:tryBegin(player), "busy flag")
	memory:finish(player)
	check(memory:tryBegin(player), "finish clears busy")
	memory:forget(player)
	check(memory:get(player, 4) == nil and memory:tryBegin(player), "forget")
end

-- 12. World 2 "Dino Valley" eggs + pets (R57) ------------------------------------------------------
do
	local dino = WorldsConfig.get("dino")
	check(dino ~= nil, "dino world registered")
	local dinoEgg, volcano = EggConfig.Eggs.dino_egg, EggConfig.Eggs.volcano_egg
	check(dinoEgg ~= nil and volcano ~= nil, "both Dino eggs exist")
	-- Config rows (spec §8): world, currency, area, stand, odds tier, pity, price formula.
	local expected = {
		{ egg = dinoEgg, area = 2, stand = "dino:EggStands1", odds = { 65_000, 27_000, 7_500, 500 }, pity = 300 },
		{ egg = volcano, area = 5, stand = "dino:EggStands2", odds = { 65_000, 27_000, 7_750, 250 }, pity = 600 },
	}
	for _, row in expected do
		local egg = row.egg
		check(egg.world == "dino" and egg.currency == "bones", `{egg.id}: Dino world + Bones`)
		check(egg.area == row.area and egg.stand == row.stand, `{egg.id}: area {egg.area} stand {egg.stand}`)
		for index, bp in row.odds do
			check(egg.slots[index].bp == bp, `{egg.id}: slot {index} odds {egg.slots[index].bp}`)
		end
		check(egg.pity ~= nil and egg.pity.slot == 4 and egg.pity.hatches == row.pity, `{egg.id}: pity`)
		local base = (dino :: any).economy.Areas[row.area].producer.baseCost
		check(
			egg.price == TycoonConfig.friendlyPrice(EggConfig.PriceUnits * base) and egg.price > 0,
			`{egg.id}: price {egg.price} = friendlyPrice(PriceUnits x dp{row.area} baseCost)`
		)
		check(WorldsConfig.worldOfEgg(egg.id) == "dino", `{egg.id}: WorldsConfig sells it in dino`)
		check(EggConfig.ByStand[egg.stand] == egg.id, `{egg.id}: ByStand`)
		check(EggConfig.PaidRandomCurrencies[egg.currency] == true, `{egg.id}: Bones eggs are gated`)
		check(EggConfig.currencyName(egg) == "Bones", `{egg.id}: currency name`)
	end
	check(volcano.price > dinoEgg.price, "Volcano Egg costs more than the Dino Egg")
	check(EggConfig.areaName(dinoEgg) == "Fern Market", `area name {EggConfig.areaName(dinoEgg)}`)
	check(EggConfig.worldName(volcano) == "Dino Valley", "world name")
	check(#(dino :: any).eggs == 2, "Dino Valley sells exactly the two eggs")
	-- Pets (spec §8 names + rarities; bonus tiers 4 / 7 / Time Ptero Epic 5).
	local pets = {
		{ "atom_raptor", "Atom Raptor", "Uncommon", 4, dinoEgg, 1 },
		{ "glow_stego", "Glow Stego", "Rare", 4, dinoEgg, 2 },
		{ "fission_trike", "Fission Trike", "Epic", 4, dinoEgg, 3 },
		{ "pocket_bronto", "Pocket Bronto", "Legendary", 4, dinoEgg, 4 },
		{ "ember_ankylo", "Ember Ankylo", "Rare", 7, volcano, 1 },
		{ "magma_ptero", "Magma Ptero", "Epic", 7, volcano, 2 },
		{ "lava_para", "Lava Para", "Legendary", 7, volcano, 3 },
		{ "supernova_spino", "Supernova Spino", "Mythic", 7, volcano, 4 },
	}
	for _, row in pets do
		local def = PetConfig.get(row[1])
		check(def ~= nil, `pet {row[1]}`)
		check(def.name == row[2] and def.rarity == row[3] and def.tier == row[4], `{row[1]}: name / rarity / tier`)
		check(def.cash == PetConfig.bonusFor(row[3], row[4]) and def.source == "egg", `{row[1]}: bonus + source`)
		check(row[5].slots[row[6]].pet == row[1], `{row[1]} in {row[5].id} slot {row[6]}`)
	end
	local ptero = PetConfig.get("time_ptero")
	check(ptero ~= nil and ptero.rarity == "Epic" and ptero.tier == 5 and ptero.source == "pack", "Time Ptero row")
	check(ptero.flying and ptero.hover == 1, "Time Ptero flies")
	check(PetConfig.get("magma_ptero").flying, "Magma Ptero flies")
	check(not PetConfig.get("atom_raptor").flying, "raptors walk")
	for _, id in EggConfig.Order do
		for _, slot in EggConfig.Eggs[id].slots do
			check(slot.pet ~= "time_ptero", "the Time Ptero is never in an egg (fixed pack pet)")
		end
	end

	-- parseStand (pure; hostile input).
	local w, list, index = EggConfig.parseStand("dino:EggStands2")
	check(w == "dino" and list == "EggStands" and index == 2, "parse world stand")
	w, list, index = EggConfig.parseStand("EggStands10")
	check(w == "main" and list == "EggStands" and index == 10, "parse main stand")
	w, list, index = EggConfig.parseStand("HarvestEggStand")
	check(w == "main" and list == "HarvestEggStand" and index == nil, "parse named stand")
	for _, bad in { nil, 5, "", "dino:", ":EggStands1", "Dino:EggStands1", "dino:Egg Stands", string.rep("a", 80) } do
		check(EggConfig.parseStand(bad) == nil, `parseStand rejects {tostring(bad)}`)
	end

	-- A profile with lots of cash AND Bones, Dino locked, Nuke Town maxed.
	local function dinoProfile(bones: number, unlocked: boolean, dinoArea: number): any
		local profile = newProfile(1e30, 10)
		local world = ProfileLogic.worldState(profile, "dino")
		world.cash = bones
		world.unlocked = unlocked
		world.tycoon.area = dinoArea
		return profile
	end

	-- Unlock gate: the Dino world must be unlocked AND its area reached (Nuke Town area 10 does
	-- not count); nothing changes on a refusal.
	local cases = {
		{ "dino_egg", false, 6, "Locked" },
		{ "dino_egg", true, 1, "Locked" },
		{ "dino_egg", true, 2, "Ok" },
		{ "volcano_egg", true, 4, "Locked" },
		{ "volcano_egg", true, 5, "Ok" },
	}
	for _, case in cases do
		local profile = dinoProfile(1e15, case[2], case[3])
		local before = snapshot(profile)
		local _, code = PetLogic.hatch(profile, case[1], 1, ctx())
		check(code == case[4], `{case[1]} unlocked={case[2]} area={case[3]}: {code} (want {case[4]})`)
		if code ~= "Ok" then
			check(deepEqual(before, profile), `{case[1]} refusal changed nothing`)
		end
	end
	check(EggConfig.isUnlocked(dinoProfile(0, true, 2), dinoEgg), "isUnlocked at Fern Market")
	check(not EggConfig.isUnlocked(dinoProfile(0, false, 6), dinoEgg), "isUnlocked needs the world")
	check(not EggConfig.isUnlocked({ worlds = { dino = { unlocked = "yes", tycoon = { area = 6 } } } }, dinoEgg), "unlock must be true")
	check(EggConfig.isUnlocked({ tycoon = { area = 0 / 0 } }, garage), "NaN main area reads area 1")
	check(not EggConfig.isUnlocked(nil, dinoEgg), "no profile: world egg locked")

	-- Payment: Bones from worlds.dino.cash only; cash untouched; totalEarned untouched.
	do
		local profile = dinoProfile(dinoEgg.price * 3 + 7, true, 2)
		local world = ProfileLogic.worldState(profile, "dino")
		local earned = world.totalEarned
		local results, code, plan = PetLogic.hatch(profile, "dino_egg", 3, ctx())
		check(code == "Ok" and results ~= nil and #results == 3, `triple Dino hatch {code}`)
		check(plan.currency == "bones" and plan.total == dinoEgg.price * 3, "plan charges Bones")
		check(world.cash == 7, `Bones left {world.cash}`)
		check(profile.cash == 1e30, "cash never pays a Bones price")
		check(world.totalEarned == earned, "a purchase is not income")
		for _, pet in results do
			local def = PetConfig.get(pet.petId)
			check(def ~= nil and table.find({ "atom_raptor", "glow_stego", "fission_trike", "pocket_bronto" }, def.id) ~= nil, "Dino Egg pet")
		end
		-- Refund puts the Bones straight back (no income).
		PetLogic.refund(profile, plan)
		check(world.cash == dinoEgg.price * 3 + 7 and world.totalEarned == earned, "refund restores Bones only")
	end
	do
		-- Plenty of cash, too few Bones: NotEnough, nothing changes.
		local profile = dinoProfile(dinoEgg.price - 1, true, 6)
		local before = snapshot(profile)
		local _, code = PetLogic.hatch(profile, "dino_egg", 1, ctx())
		check(code == "NotEnough", `Bones short: {code}`)
		check(deepEqual(before, profile), "Bones short changed nothing")
		check(PetLogic.balanceOf(profile, "bones") == dinoEgg.price - 1, "balanceOf Bones")
		check(PetLogic.balanceOf(profile, "amber") == 0, "tokens are not an egg balance")
	end
	do
		-- Paid random gate: buying with Bones is refused while restricted / unknown (fail closed).
		local profile = dinoProfile(1e12, true, 6)
		local before = snapshot(profile)
		local _, code = PetLogic.hatch(profile, "volcano_egg", 1, ctx({ restricted = true }))
		check(code == "Restricted", `Bones egg restricted: {code}`)
		check(deepEqual(before, profile), "restricted changed nothing")
		check(EggConfig.needsPolicy(volcano, 0, 1), "Bones egg needs the policy")
		check(not EggConfig.needsPolicy(volcano, 3, 3), "held Volcano eggs need no policy")
		-- Held Dino eggs hatch anywhere, for everybody (no stand, restricted, no Bones).
		PetLogic.grantEgg(profile, "volcano_egg", 2)
		profile.worlds.dino.cash = 0
		local results, heldCode = PetLogic.hatch(profile, "volcano_egg", 1, ctx({ restricted = true, atStand = false }))
		check(heldCode == "Ok" and results ~= nil and #results == 1, `held Volcano egg {heldCode}`)
		check(PetState.pets(profile).eggs.volcano_egg == 1, "one held egg spent")
		-- TooFar: buying needs the stand even when everything else passes.
		profile.worlds.dino.cash = 1e12
		PetState.pets(profile).eggs.volcano_egg = nil
		local _, farCode = PetLogic.hatch(profile, "volcano_egg", 1, ctx({ atStand = false }))
		check(farCode == "TooFar", `world stand range {farCode}`)
	end
	check(PetLogic.worldWallet("bones") == "dino", "bones wallet")
	check(PetLogic.worldWallet("amber") == nil and PetLogic.worldWallet("cash") == nil, "no wallet for tokens / cash")
	check(PetLogic.worldWallet("acorns") == nil and PetLogic.worldWallet("gems") == nil, "no wallet for acorns / gems")
	-- Refusal texts name the world, its area and its currency.
	local lockedText = PetLogic.refusalMessage("Locked", dinoEgg)
	check(string.find(lockedText, "Fern Market", 1, true) ~= nil and string.find(lockedText, "Dino Valley", 1, true) ~= nil, lockedText)
	check(string.find(PetLogic.refusalMessage("NotEnough", volcano), "Bones", 1, true) ~= nil, "NotEnough says Bones")
	check(PetLogic.refusalMessage("Locked", garage) == "Reach area 1 to unlock the Garage Egg!", "main text unchanged")

	-- Fixed pack pets (Time Traveler Pack): only non-egg pets, live path only, fails closed.
	check(PetGrants.isFixedPet("time_ptero"), "Time Ptero is a fixed pet")
	check(not PetGrants.isFixedPet("atom_raptor") and not PetGrants.isFixedPet("nope"), "egg / unknown pets are not")
	local player = roblox.Instance.new("Player")
	check(select(1, PetGrants.grantFixed(player, "time_ptero", "TimeTravelerPack")) == false, "no live granter → refused")
	local calls = {}
	PetGrants.useLive(function(target: any, petId: string, reason: string): (boolean, string?)
		table.insert(calls, { target, petId, reason })
		return true, "u77"
	end)
	local ok, uid = PetGrants.grantFixed(player, "time_ptero", "TimeTravelerPack")
	check(ok == true and uid == "u77" and #calls == 1 and calls[1][2] == "time_ptero", "live fixed grant")
	check(select(1, PetGrants.grantFixed(player, "atom_raptor", "x")) == false and #calls == 1, "egg pet never granted fixed")
	check(select(1, PetGrants.grantFixed(roblox.Instance.new("Folder") :: any, "time_ptero", "x")) == false, "non-player refused")
	PetGrants.useLive(function(): (boolean, string?)
		error("boom")
	end)
	check(select(1, PetGrants.grantFixed(player, "time_ptero", "x")) == false, "a throwing granter is refused, not raised")

	-- Client EggView (display helpers mirror the server rules).
	local snap = {
		cash = 5_000,
		event = { acorns = 12 },
		worlds = { dino = { unlocked = true, tycoon = { area = 2 } } },
		worldCash = { dino = { cash = 30_000, totalEarned = 99 } },
	}
	check(EggView.balance(snap, dinoEgg) == 30_000 and EggView.balance(snap, garage) == 5_000, "EggView balances")
	check(EggView.balance({ worldCash = { dino = { cash = 0 / 0 } } }, dinoEgg) == 0, "EggView NaN Bones → 0")
	check(EggView.formatAmount(dinoEgg, 24_000) == "24K Bones", EggView.formatAmount(dinoEgg, 24_000))
	check(EggView.formatAmount(garage, 560) == "$560", EggView.formatAmount(garage, 560))
	check(EggView.lockText({}, dinoEgg) == "LOCKED - unlock Dino Valley", EggView.lockText({}, dinoEgg))
	check(EggView.lockText(snap, volcano) == "LOCKED - reach Fossil Lab", EggView.lockText(snap, volcano))
	check(EggView.lockButton(snap, volcano) == "REACH FOSSIL LAB", EggView.lockButton(snap, volcano))
	check(EggView.balanceText(snap, dinoEgg) == "You have 30K Bones", EggView.balanceText(snap, dinoEgg))
	check(EggView.worldWallet("bones") == "dino" and EggView.worldWallet("amber") == nil, "EggView wallet")
end

-- 13. World 3 "Moon Base" eggs + pets (R70) ----------------------------------------------------------
do
	local moon = WorldsConfig.get("moon")
	check(moon ~= nil and (moon :: any).currency.key == "moonrocks", "moon world registered with Moon Rocks")
	local moonEgg, cometEgg = EggConfig.Eggs.moon_egg, EggConfig.Eggs.comet_egg
	check(moonEgg ~= nil and cometEgg ~= nil, "both Moon eggs exist")
	local rows = {
		{ egg = moonEgg, area = 2, stand = "moon:EggStands1", odds = { 65_000, 27_000, 7_500, 500 }, pity = 300, card = "purple" },
		{ egg = cometEgg, area = 5, stand = "moon:EggStands2", odds = { 65_000, 27_000, 7_750, 250 }, pity = 600, card = "blue" },
	}
	for _, row in rows do
		local egg = row.egg
		check(egg.world == "moon" and egg.currency == "moonrocks", `{egg.id}: Moon world + Moon Rocks`)
		check(egg.area == row.area and egg.stand == row.stand and egg.card == row.card, `{egg.id}: area / stand / card`)
		for index, bp in row.odds do
			check(egg.slots[index].bp == bp, `{egg.id}: slot {index} odds`)
		end
		check(egg.pity ~= nil and egg.pity.slot == 4 and egg.pity.hatches == row.pity, `{egg.id}: pity`)
		local base = (moon :: any).economy.Areas[row.area].producer.baseCost
		check(egg.price == TycoonConfig.friendlyPrice(EggConfig.PriceUnits * base), `{egg.id}: price {egg.price}`)
		check(WorldsConfig.worldOfEgg(egg.id) == "moon" and EggConfig.ByStand[egg.stand] == egg.id, `{egg.id}: registry`)
		check(EggConfig.PaidRandomCurrencies.moonrocks == true and EggConfig.currencyName(egg) == "Moon Rocks", `{egg.id}: gated`)
	end
	-- The Moon eggs mirror the Dino eggs' odds tiers exactly (spec §2.5 "odds like dino_egg").
	for index = 1, 4 do
		check(moonEgg.slots[index].bp == EggConfig.Eggs.dino_egg.slots[index].bp, `Moon Egg slot {index} = Dino Egg`)
		check(cometEgg.slots[index].bp == EggConfig.Eggs.volcano_egg.slots[index].bp, `Comet Egg slot {index} = Volcano Egg`)
	end
	local pets = {
		{ "astro_pup", "Astro Pup", "Uncommon", 4, moonEgg, 1 },
		{ "moon_bunny", "Moon Bunny", "Rare", 4, moonEgg, 2 },
		{ "orbit_owl", "Orbit Owl", "Epic", 4, moonEgg, 3 },
		{ "cosmo_cat", "Cosmo Cat", "Legendary", 4, moonEgg, 4 },
		{ "comet_fox", "Comet Fox", "Rare", 7, cometEgg, 1 },
		{ "saucer_octo", "Saucer Octo", "Epic", 7, cometEgg, 2 },
		{ "galaxy_whale", "Galaxy Whale", "Legendary", 7, cometEgg, 3 },
		{ "starlight_unicorn", "Starlight Unicorn", "Mythic", 7, cometEgg, 4 },
	}
	for _, row in pets do
		local def = PetConfig.get(row[1])
		check(def ~= nil and def.name == row[2] and def.rarity == row[3] and def.tier == row[4], `{row[1]} row`)
		check(def.source == "egg" and row[5].slots[row[6]].pet == row[1], `{row[1]} in {row[5].id} slot {row[6]}`)
	end
	local corgi = PetConfig.get("rocket_corgi")
	check(corgi ~= nil and corgi.rarity == "Epic" and corgi.tier == 5 and corgi.source == "pack", "Rocket Corgi row")
	check(PetGrants.isFixedPet("rocket_corgi"), "Rocket Corgi is a fixed (pack) pet")
	check(corgi.flying and PetConfig.get("orbit_owl").flying and PetConfig.get("galaxy_whale").hover == 1, "Moon flyers")
	-- Every pet display name is unique across all three worlds (PetConfig.validate checks it too).
	local seen: { [string]: boolean } = {}
	for _, id in PetConfig.Order do
		local name = PetConfig.Pets[id].name
		check(seen[name] == nil, `duplicate pet name {name}`)
		seen[name] = true
	end

	-- A player with lots of cash AND Bones AND Moon Rocks; Moon locked unless asked.
	local function moonProfile(rocks: number, unlocked: boolean, moonArea: number): any
		local profile = newProfile(1e30, 10)
		local dino = ProfileLogic.worldState(profile, "dino")
		dino.unlocked, dino.tycoon.area, dino.cash = true, 6, 1e30
		local world = ProfileLogic.worldState(profile, "moon")
		world.cash = rocks
		world.unlocked = unlocked
		world.tycoon.area = moonArea
		return profile
	end
	for _, case in {
		{ "moon_egg", false, 6, "Locked" },
		{ "moon_egg", true, 1, "Locked" },
		{ "moon_egg", true, 2, "Ok" },
		{ "comet_egg", true, 4, "Locked" },
		{ "comet_egg", true, 5, "Ok" },
	} do
		local profile = moonProfile(1e15, case[2], case[3])
		local before = snapshot(profile)
		local _, code = PetLogic.hatch(profile, case[1], 1, ctx())
		check(code == case[4], `{case[1]} unlocked={case[2]} area={case[3]}: {code} (want {case[4]})`)
		if code ~= "Ok" then
			check(deepEqual(before, profile), `{case[1]} refusal changed nothing`)
		end
	end
	do
		-- Moon Rocks only: plenty of cash + Bones never pay a Moon price.
		local profile = moonProfile(moonEgg.price - 1, true, 6)
		local before = snapshot(profile)
		local _, code = PetLogic.hatch(profile, "moon_egg", 1, ctx())
		check(code == "NotEnough" and deepEqual(before, profile), `Moon Rocks short: {code}`)
		profile.worlds.moon.cash = moonEgg.price * 2 + 5
		local results, okCode, plan = PetLogic.hatch(profile, "moon_egg", 1, ctx())
		check(okCode == "Ok" and results ~= nil and plan.currency == "moonrocks", `Moon hatch {okCode}`)
		check(profile.worlds.moon.cash == moonEgg.price + 5, `Moon Rocks left {profile.worlds.moon.cash}`)
		check(profile.cash == 1e30 and profile.worlds.dino.cash == 1e30, "cash + Bones untouched")
		PetLogic.refund(profile, plan)
		check(profile.worlds.moon.cash == moonEgg.price * 2 + 5, "refund restores Moon Rocks")
		local _, restricted = PetLogic.hatch(profile, "comet_egg", 1, ctx({ restricted = true }))
		check(restricted == "Restricted", `Moon Rocks egg restricted: {restricted}`)
	end
	check(PetLogic.worldWallet("moonrocks") == "moon" and PetLogic.worldWallet("starshards") == nil, "moon wallet")
	local lockedText = PetLogic.refusalMessage("Locked", cometEgg)
	check(string.find(lockedText, "Star Lab", 1, true) ~= nil and string.find(lockedText, "Moon Base", 1, true) ~= nil, lockedText)
	check(string.find(PetLogic.refusalMessage("NotEnough", moonEgg), "Moon Rocks", 1, true) ~= nil, "NotEnough says Moon Rocks")
	local snap = { worlds = { moon = { unlocked = true, tycoon = { area = 2 } } }, worldCash = { moon = { cash = 1_500 } } }
	check(EggView.balance(snap, moonEgg) == 1_500, "EggView Moon Rocks balance")
	check(EggView.lockText({}, moonEgg) == "LOCKED - unlock Moon Base", EggView.lockText({}, moonEgg))
	check(EggView.lockText(snap, cometEgg) == "LOCKED - reach Star Lab", EggView.lockText(snap, cometEgg))
	check(string.find(EggView.formatAmount(moonEgg, moonEgg.price), "Moon Rocks", 1, true) ~= nil, "EggView Moon price")
end

print(`[pets-logic] {checks} checks passed`)
