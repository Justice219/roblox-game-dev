--!strict
--[[
	Pet Index rewards + Golden Nukey regressions (owner R78, spec 2026-10-31-r78 §5). Run:
		lune run tests/pet-index

	Proves on the shipped modules (src/shared/Config/{PetIndexConfig, PetConfig, PetAnimConfig,
	EggConfig, MeshAssets}, src/server/Pets/{PetIndexLogic, PetState, PetGrants, PetLogic},
	src/server/Retention/RewardLogic, src/server/Economy/ProfileLogic):
	  1. Config: validates; milestones 5 / 10 / 20 / 30 / 45 / 60 / ALL, gems 25 … 300, Index Bonus
	     +2 … +10 % (cumulative exactly +30 %); Total = the non-exclusive pet count; ALL = Total.
	  2. Golden Nukey: exclusive Nuke Pass pet (source "pass", Mythic tier 10 = the strongest Nuke
	     Town Mythic), in NO egg pool, own mesh (SparkleNukey, uploaded, Orbit joint, Hop style), a
	     "how to get" line; every pass / pack / starter / secret / event pet is exclusive.
	  3. Grants: P-pass's path PetGrants.grantFixed(player, "golden_nukey", "pass") (live granter),
	     the RewardLogic.apply { pet = "golden_nukey" } item-granter path and PetLogic.grantPet
	     accept the exclusive pet; the index marks it.
	  4. Counting: hostile index tables (non-tables, false / string values, unknown ids, number
	     keys, a 10k-entry table) count only known `true` ids; exclusive pets count when owned, so
	     Total-1 regular + 1 exclusive reaches ALL; discovered may exceed Total.
	  5. Eligibility: claimable / nextGoal at every boundary (need-1 / need), after claims.
	  6. Claim: garbage positions (0, 8, 1.5, NaN, inf, "1", nil, {}, -1) → "bad" and change
	     nothing; not enough pets → "locked", nothing changes; ok marks once; a repeat is
	     "claimed" (idempotent) and pays nothing twice (gems via RewardLogic.apply).
	  7. Bonus: sum of claimed milestones only (unknown / non-true keys ignored), +30 % when all
	     are claimed; PetIndexLogic.bonus / status; admin setClaimed grant / clear / no-op.
	  8. Profile: defaultProfile has an empty pets.indexClaimed; reconcile keeps only string keys
	     marked true (bounded by MaxIndexMilestones); the client snapshot carries a COPY; toSave
	     keeps the string-keyed map (DataStore JSON safe); the snapshot works with claimable().
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local PetIndexConfig = loader.load("src/shared/Config/PetIndexConfig")
local PetConfig = loader.load("src/shared/Config/PetConfig")
local PetAnimConfig = loader.load("src/shared/Config/PetAnimConfig")
local EggConfig = loader.load("src/shared/Config/EggConfig")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local PetIndexLogic = loader.load("src/server/Pets/PetIndexLogic")
local PetState = loader.load("src/server/Pets/PetState")
local PetGrants = loader.load("src/server/Pets/PetGrants")
local PetLogic = loader.load("src/server/Pets/PetLogic")
local RewardLogic = loader.load("src/server/Retention/RewardLogic")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local roblox = require("@lune/roblox")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local NOW = 1_800_000_000
local NAN = 0 / 0

-- A fresh default profile with the pets sub-tables created (PetState).
local function newProfile(): any
	local profile = ProfileLogic.defaultProfile() :: any
	PetState.pets(profile)
	return profile
end

-- Marks the first `regular` NON-exclusive pets (+ `exclusive` exclusive ones) discovered.
local function discover(profile: any, regular: number, exclusive: number?)
	local index = PetState.pets(profile).index
	local addedRegular, addedExclusive = 0, 0
	for _, id in PetConfig.Order do
		local def = PetConfig.Pets[id]
		if not def.exclusive and addedRegular < regular then
			index[id] = true
			addedRegular += 1
		elseif def.exclusive and addedExclusive < (exclusive or 0) then
			index[id] = true
			addedExclusive += 1
		end
	end
	assert(addedRegular == regular, `only {addedRegular} regular pets exist`)
end

-- Ids of a milestone list (for compact comparisons).
local function ids(list: { any }): string
	local out: { string } = {}
	for _, milestone in list do
		table.insert(out, milestone.id)
	end
	return table.concat(out, ",")
end

local function count(map: { [any]: any }): number
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

-- 1. Config ---------------------------------------------------------------------------------------
check(#PetIndexConfig.validate() == 0, `PetIndexConfig problems: {table.concat(PetIndexConfig.validate(), "; ")}`)
local nonExclusive = 0
for _, id in PetConfig.Order do
	if not PetConfig.Pets[id].exclusive then
		nonExclusive += 1
	end
end
check(PetIndexConfig.Total == nonExclusive, "Total = non-exclusive pets")
check(PetIndexConfig.Total < PetConfig.Count, "some pets are exclusive")
check(PetIndexConfig.Count == 7, "7 milestones")
local SPEC = {
	{ "5", 5, 25, 2 },
	{ "10", 10, 40, 2 },
	{ "20", 20, 60, 3 },
	{ "30", 30, 80, 3 },
	{ "45", 45, 120, 5 },
	{ "60", 60, 160, 5 },
	{ "all", PetIndexConfig.Total, 300, 10 },
}
for position, row in SPEC do
	local milestone = PetIndexConfig.Milestones[position]
	check(
		milestone.position == position
			and milestone.id == row[1]
			and milestone.need == row[2]
			and milestone.gems == row[3]
			and milestone.bonusPct == row[4],
		`milestone {position} = spec {row[1]}`
	)
	check(PetIndexConfig.ById[row[1]] == milestone, `ById {row[1]}`)
end
check(PetIndexConfig.Milestones[7].label == "ALL", "ALL label")
check(PetIndexConfig.MaxBonus == 0.3, "cumulative Index Bonus is exactly +30 %")
check(PetIndexConfig.formatBonus(0.3) == "+30%" and PetIndexConfig.formatBonus(NAN) == "+0%", "formatBonus")
check(PetIndexConfig.Reason == "petIndex", "reward reason id")

-- 2. Golden Nukey ---------------------------------------------------------------------------------
check(#PetConfig.validate() == 0, `PetConfig problems: {table.concat(PetConfig.validate(), "; ")}`)
local nukey = PetConfig.get("golden_nukey")
check(nukey ~= nil, "golden_nukey exists")
check(nukey.name == "Golden Nukey" and nukey.source == "pass" and nukey.exclusive == true, "Golden Nukey row")
check(nukey.rarity == "Mythic" and nukey.tier == 10, "Golden Nukey: Mythic tier 10")
-- Strength = the strongest Nuke Town (main world) Mythic egg pet.
local bestMainMythic = 0
for _, eggId in EggConfig.Order do
	local egg = EggConfig.Eggs[eggId]
	for _, slot in egg.slots do
		local def = PetConfig.get(slot.pet)
		check(slot.pet ~= "golden_nukey", `golden_nukey is in no egg pool ({eggId})`)
		if def ~= nil and def.rarity == "Mythic" and egg.world == "main" then
			bestMainMythic = math.max(bestMainMythic, def.cash)
		end
	end
end
check(bestMainMythic > 0 and nukey.cash == bestMainMythic, `Golden Nukey bonus {nukey.cash} = best Nuke Town Mythic`)
check(type(nukey.how) == "string" and string.find(nukey.how, "Nuke Pass", 1, true) ~= nil, "how-to-get line")
check(nukey.model == "SparkleNukey", "own mesh key")
local mesh = MeshAssets.SparkleNukey
check(mesh ~= nil and mesh.pieces ~= nil and mesh.pieces.Orbit ~= nil and mesh.pieces.Body ~= nil, "mesh synced")
for name, piece in mesh.pieces do
	check(type(piece.id) == "number" and piece.id > 0, `SparkleNukey.{name} uploaded`)
end
check(mesh.triangles <= 2800, "pet triangle budget")
check(string.find(mesh.pivot, "Orbit@", 1, true) ~= nil, "Orbit joint in the pivot string")
check(PetAnimConfig.Species.SparkleNukey ~= nil and PetAnimConfig.Species.SparkleNukey.style == "Hop", "hops")
for _, id in PetConfig.Order do
	local def = PetConfig.Pets[id]
	local paid = def.source == "pass"
		or def.source == "pack"
		or def.source == "starter"
		or def.source == "secret"
		or def.source == "event"
	check(not paid or def.exclusive, `{id}: a {def.source} pet is exclusive`)
end
check(PetConfig.get("rocket_corgi").how ~= nil, "Rocket Corgi names its own pack")

-- 3. Grants ---------------------------------------------------------------------------------------
do
	local profile = newProfile()
	local summary = RewardLogic.apply(
		profile,
		{ pet = "golden_nukey", fallbackGems = 99 },
		NOW,
		{ pet = PetGrants.pet }
	)
	check(summary.pet == "golden_nukey" and summary.fallbackGems == 0, "the Nuke Pass reward grants the pet")
	check(PetState.pets(profile).index.golden_nukey == true, "the grant marks the index")
	local owned = 0
	for _, entry in PetState.pets(profile).owned do
		if entry.id == "golden_nukey" then
			owned += 1
		end
	end
	check(owned == 1, "exactly one Golden Nukey owned")
	check(PetGrants.isFixedPet("golden_nukey"), "fixed-pet path accepts the exclusive pet")
	-- P-pass's actual call: PetGrants.grantFixed(player, "golden_nukey", "pass") → the live
	-- PetService.grantPet path (a fake live granter stands in for PetService here).
	local calls: { { any } } = {}
	PetGrants.useLive(function(target: any, petId: string, reason: string): (boolean, string?)
		table.insert(calls, { target, petId, reason })
		return true, "u900"
	end)
	local player = roblox.Instance.new("Player")
	local fixedOk, fixedUid = PetGrants.grantFixed(player, "golden_nukey", "pass")
	check(fixedOk == true and fixedUid == "u900", "grantFixed(golden_nukey, pass) runs the live grant")
	check(#calls == 1 and calls[1][2] == "golden_nukey" and calls[1][3] == "pass", "live granter got the pass pet")
	local uid = PetLogic.grantPet(profile, "golden_nukey", true)
	check(uid ~= nil, "a second copy (admin / reward) is allowed")
	check(PetIndexConfig.discovered(PetState.pets(profile).index) == 1, "an owned exclusive counts")
end

-- 4. Counting -------------------------------------------------------------------------------------
check(PetIndexConfig.discovered(nil) == 0 and PetIndexConfig.discovered("x") == 0, "non-table → 0")
check(PetIndexConfig.discovered({}) == 0, "empty → 0")
check(
	PetIndexConfig.discovered({ glow_slime = true, atom_pup = false, fission_fox = "yes", bogus = true, [1] = true })
		== 1,
	"only known ids marked true count"
)
do
	local huge: { [any]: any } = {}
	for i = 1, 10_000 do
		huge[`fake_{i}`] = true
	end
	huge.glow_slime = true
	check(PetIndexConfig.discovered(huge) == 1, "a huge hostile table counts known ids only")
	local all: { [string]: boolean } = {}
	for _, id in PetConfig.Order do
		all[id] = true
	end
	check(PetIndexConfig.discovered(all) == PetConfig.Count, "every pet (incl. exclusives) counts")
	check(PetIndexConfig.discovered(all) > PetIndexConfig.Total, "discovered may exceed Total")
end
do
	local profile = newProfile()
	discover(profile, PetIndexConfig.Total - 1, 0)
	check(ids(PetIndexConfig.claimable(PetState.pets(profile))) == "5,10,20,30,45,60", "Total-1: ALL not yet")
	discover(profile, PetIndexConfig.Total - 1, 1)
	check(
		ids(PetIndexConfig.claimable(PetState.pets(profile))) == "5,10,20,30,45,60,all",
		"an owned exclusive pet completes ALL"
	)
end

-- 5. Eligibility ----------------------------------------------------------------------------------
check(#PetIndexConfig.claimable(nil) == 0 and #PetIndexConfig.claimable("x") == 0, "garbage pets → none")
for _, milestone in PetIndexConfig.Milestones do
	local below = newProfile()
	discover(below, milestone.need - 1)
	local reached = newProfile()
	discover(reached, milestone.need)
	local function has(profile: any): boolean
		for _, m in PetIndexConfig.claimable(PetState.pets(profile)) do
			if m == milestone then
				return true
			end
		end
		return false
	end
	check(not has(below), `{milestone.id}: need-1 is not enough`)
	check(has(reached), `{milestone.id}: need reaches it`)
end
do
	local profile = newProfile()
	discover(profile, 12)
	local pets = PetState.pets(profile)
	check(ids(PetIndexConfig.claimable(pets)) == "5,10", "12 pets: 5 + 10 ready")
	check(PetIndexConfig.nextGoal(pets).id == "5", "next goal = first unclaimed")
	pets.indexClaimed["5"] = true
	check(ids(PetIndexConfig.claimable(pets)) == "10", "after claiming 5: 10 ready")
	pets.indexClaimed["10"] = true
	check(#PetIndexConfig.claimable(pets) == 0 and PetIndexConfig.nextGoal(pets).id == "20", "next goal 20")
	for _, milestone in PetIndexConfig.Milestones do
		pets.indexClaimed[milestone.id] = true
	end
	check(PetIndexConfig.nextGoal(pets) == nil, "no next goal when all are claimed")
end

-- 6. Claim ----------------------------------------------------------------------------------------
do
	local profile = newProfile()
	discover(profile, 7)
	local before = ProfileLogic.deepCopy(profile)
	for _, bad in { 0, 8, 1.5, NAN, math.huge, -math.huge, -1, "1", nil, {}, true } :: { any } do
		local code, milestone = PetIndexLogic.claim(profile, bad)
		check(code == "bad" and milestone == nil, `garbage position {tostring(bad)} → bad`)
	end
	check(count(PetState.pets(profile).indexClaimed) == 0, "garbage claims change nothing")
	local code = PetIndexLogic.claim(profile, 2) -- 10 pets, only 7 discovered
	check(code == "locked" and PetState.pets(profile).indexClaimed["10"] == nil, "locked changes nothing")
	check(ProfileLogic.deepCopy(profile).gems == before.gems, "no gems for refusals")

	-- The service step: claim, then pay the reward in the same step.
	local okCode, milestone = PetIndexLogic.claim(profile, 1)
	check(okCode == "ok" and milestone ~= nil and milestone.id == "5", "claim 5 pets")
	check(PetState.pets(profile).indexClaimed["5"] == true, "claim marked")
	local gems0 = profile.gems
	local summary = RewardLogic.apply(profile, PetIndexLogic.rewardOf(milestone), NOW, nil)
	check(summary.gems == 25 and profile.gems == gems0 + 25, "25 gems paid")
	-- A replayed / double-pressed claim is refused: nothing is paid twice.
	local again, none = PetIndexLogic.claim(profile, 1)
	check(again == "claimed" and none == nil, "repeat claim → claimed")
	check(profile.gems == gems0 + 25, "gems paid once")
	check(PetIndexLogic.bonus(profile) == 0.02, "Index Bonus +2 % after the first milestone")
end

-- 7. Bonus, status, admin -------------------------------------------------------------------------
check(PetIndexConfig.bonus(nil) == 0 and PetIndexConfig.bonus("x") == 0, "garbage claimed → 0")
check(
	PetIndexConfig.bonus({ ["5"] = true, bogus = true, ["10"] = "yes", [3] = true }) == 0.02,
	"only real milestones marked true add bonus"
)
check(PetIndexConfig.bonus({ ["5"] = true, ["10"] = true }) == 0.04, "5 + 10 = +4 %")
do
	local profile = newProfile()
	discover(profile, PetIndexConfig.Total)
	local paid = 0
	for position = 1, PetIndexConfig.Count do
		local code, milestone = PetIndexLogic.claim(profile, position)
		check(code == "ok", `claim {position} with every regular pet`)
		paid += RewardLogic.apply(profile, PetIndexLogic.rewardOf(milestone), NOW, nil).gems
	end
	check(paid == 25 + 40 + 60 + 80 + 120 + 160 + 300, "all milestones pay 785 gems")
	check(PetIndexLogic.bonus(profile) == 0.3, "all claimed = +30 %")
	local status = PetIndexLogic.status(profile)
	check(
		status.found == PetIndexConfig.Total
			and status.total == PetIndexConfig.Total
			and status.claimed == 7
			and status.ready == 0
			and status.bonus == 0.3,
		"status after everything"
	)
	-- Admin clear / grant.
	check(PetIndexLogic.setClaimed(profile, "all", false), "admin clears ALL")
	check(
		PetIndexLogic.bonus(profile) == 0.2 and PetIndexLogic.status(profile).ready == 1,
		"bonus drops, ALL ready again"
	)
	check(not PetIndexLogic.setClaimed(profile, "all", false), "clearing twice is a no-op")
	check(PetIndexLogic.setClaimed(profile, "all", true), "admin grants ALL")
	check(not PetIndexLogic.setClaimed(profile, "all", true), "granting twice is a no-op")
	check(not PetIndexLogic.setClaimed(profile, "bogus", true), "unknown id refused")
	check(not PetIndexLogic.setClaimed(profile, 5 :: any, true), "non-string id refused")
end
do
	-- Admin grant ignores the pets needed (a fresh profile).
	local profile = newProfile()
	check(PetIndexLogic.setClaimed(profile, "60", true) and PetIndexLogic.bonus(profile) == 0.05, "admin grant 60")
	check(PetIndexLogic.status(profile).found == 0, "nothing discovered")
end

-- 8. Profile schema -------------------------------------------------------------------------------
do
	local fresh = ProfileLogic.defaultProfile() :: any
	check(type(fresh.pets.indexClaimed) == "table" and next(fresh.pets.indexClaimed) == nil, "default: empty")
	local claimedRaw: { [any]: any } =
		{ ["5"] = true, ["10"] = "yes", all = false, [7] = true, [string.rep("x", 80)] = true }
	local repaired = ProfileLogic.reconcile({ pets = { indexClaimed = claimedRaw } }) :: any
	check(
		repaired.pets.indexClaimed["5"] == true and count(repaired.pets.indexClaimed) == 1,
		"reconcile keeps string keys marked true only"
	)
	local many: { [string]: boolean } = {}
	for i = 1, 200 do
		many[`m{i}`] = true
	end
	local bounded = ProfileLogic.reconcile({ pets = { indexClaimed = many } }) :: any
	check(count(bounded.pets.indexClaimed) == ProfileLogic.Limits.MaxIndexMilestones, "bounded")
	check(ProfileLogic.reconcile({ pets = { indexClaimed = "x" } }).pets.indexClaimed ~= nil, "non-table → empty")

	local profile = newProfile()
	discover(profile, 10)
	PetIndexLogic.claim(profile, 1)
	local context = { saveStatus = "ok", paidRandomRestricted = true, policyKnown = false }
	local snapshot = ProfileLogic.snapshot(profile, context, { "pets" })
	check(snapshot.pets.indexClaimed["5"] == true, "snapshot carries the claims")
	check(snapshot.pets.indexClaimed ~= profile.pets.indexClaimed, "snapshot is a copy")
	check(ids(PetIndexConfig.claimable(snapshot.pets)) == "10", "the client snapshot computes claimable")
	local saved = ProfileLogic.toSave(profile)
	check(saved.pets.indexClaimed["5"] == true, "toSave keeps the string-keyed map")
	local reloaded = ProfileLogic.reconcile(saved) :: any
	check(reloaded.pets.indexClaimed["5"] == true, "save → load round trip")
end

print(`[pet-index] {checks} checks passed (Total {PetIndexConfig.Total}, {PetConfig.Count} pets)`)
