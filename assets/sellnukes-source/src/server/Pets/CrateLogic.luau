--!strict
--[[
	CrateLogic — pure server rules for Supply Crates: plan + commit an open (held crate or gems,
	paid-random policy, the reward roll with pity, duplicate trails, full inventories), Robux
	receipts (held crates), and trail equipping. No Players, no remotes, no yields; tested in Lune
	(tests/pets-crates.luau) with a seeded RNG.

	An open is PLAN → CHARGE → COMMIT with no yield in between (CrateService):
		planOpen    validates and draws the roll against a scratch pity counter; mutates nothing.
		(charge)    pay "gems": the caller takes crate.gems (PlayerDataService.trySpendGems, so
		            analytics see the sink). pay "held": commitOpen consumes the held crate.
		commitOpen  consumes a held crate, applies the reward (boost / egg / pet / trail), bumps
		            crates.opened + the pity counter. Gem rewards and duplicate refunds are NOT added
		            here: they are returned as `gems` so the caller grants them through
		            PlayerDataService.grantGems (analytics source). All or nothing on errors.

	Roll (published odds = rolled odds):
		1. index = NextInteger(1, TotalBp) over the cumulative reward weights
		2. PITY: when this is the `pity.opens`-th open in a row without a reward of rarity rank >=
		   pity.rank and step 1 missed it, re-roll among those rewards proportional to their
		   weights (NextInteger(1, their total)). Counter resets on a hit, else +1.

	Payment order: a HELD crate (Robux receipt / admin) is opened first (no gems). Otherwise gems.
	BOTH are PAID RANDOM ITEMS (CrateConfig.PaidRandomPay): gems are sold for Robux, and held
	crates are only sold for Robux, so opening either is refused "Restricted" while the player's
	policy is restricted or unknown (ctx.restricted, fail closed). A restricted player's held
	crates stay in the profile untouched (kept safe until the region allows them).

	Duplicates / caps (a paid roll is never wasted):
		trail already owned  → crate.dupGems instead
		pet at PetConfig.HardCap → crate.dupGems instead (crate pets ignore the soft cap)
		egg kinds full        → crate.dupGems instead

	Refusal codes: BadCrate (unknown id), Restricted (paid random item + restricted / unknown
	policy), NotEnough (gems). CrateService reports Restricted as "PolicyUnknown" while
	PolicyService has not answered.

	Robux receipts: receiptDecision(policyKnown, restricted) → "defer" (policy unknown: Roblox
	re-delivers the receipt later) | "gems" (known restricted: the gem price instead, never a
	crate) | "crate" (a held crate); applyReceipt applies "gems" / "crate".

	Connects to: Shared/Config/{CrateConfig, PetConfig}, Server/Pets/{PetLogic, PetState},
	Server/Retention/BoostLogic (B7, boost stacking), Server/Economy/ProfileLogic (gems in `open`),
	Server/Services/CrateService, tests/pets-crates.luau.

	Example:
		local plan, code = CrateLogic.planOpen(profile, "supply_crate", ctx)
		if plan and (plan.pay == "held" or PlayerDataService.trySpendGems(player, plan.price, "crate")) then
			local applied = CrateLogic.commitOpen(profile, plan, os.time())
			PlayerDataService.grantGems(player, applied.gems, "crate")
		end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoostLogic = require(script.Parent.Parent.Retention.BoostLogic)
local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetLogic = require(script.Parent.PetLogic)
local PetState = require(script.Parent.PetState)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)

type CrateDef = CrateConfig.CrateDef
type Reward = CrateConfig.Reward

export type OpenContext = {
	random: PetLogic.RandomLike,
	now: number,
	restricted: boolean, -- paid random items restricted, or policy unknown (fail closed)
}

export type OpenCode = "Ok" | "BadCrate" | "Restricted" | "NotEnough"

export type OpenPlan = {
	crate: CrateDef,
	pay: "held" | "gems",
	price: number, -- gems to charge (0 for a held crate)
	index: number, -- the reward's index in crate.rewards
	reward: Reward,
	pityForced: boolean,
	pityAfter: number,
	dup: boolean, -- converted to crate.dupGems (owned trail / full inventory)
}

export type OpenApplied = {
	gems: number, -- gems the caller must grant (gem rewards + duplicate refunds)
	uid: string?, -- pet reward uid
	isNew: boolean, -- pet reward first of its kind / trail newly owned
	boostEndsAt: number?, -- boost reward new expiry
	trailEquipped: boolean, -- the new trail was auto-equipped (none was equipped)
	dup: boolean, -- converted to gems at commit (a cap was hit between plan and commit)
}

local CrateLogic = {}

local COUNTER_MAX = 1_000_000

--[[ Step 1: a reward index from the cumulative weights. ]]
function CrateLogic.rollReward(crate: CrateDef, random: PetLogic.RandomLike): number
	local draw = random:NextInteger(1, CrateConfig.TotalBp)
	local cumulative = 0
	for index, reward in crate.rewards do
		cumulative += reward.bp
		if draw <= cumulative then
			return index
		end
	end
	return #crate.rewards
end

--[[ Step 2: the pity re-roll among rewards of rarity rank >= `rank` (nil when none exist). ]]
function CrateLogic.rollPityReward(crate: CrateDef, rank: number, random: PetLogic.RandomLike): number?
	local total = 0
	for _, reward in crate.rewards do
		if PetConfig.rank(reward.rarity) >= rank then
			total += reward.bp
		end
	end
	if total <= 0 then
		return nil
	end
	local draw = random:NextInteger(1, total)
	local cumulative = 0
	for index, reward in crate.rewards do
		if PetConfig.rank(reward.rarity) >= rank then
			cumulative += reward.bp
			if draw <= cumulative then
				return index
			end
		end
	end
	return nil
end

--[[
	Opens left until the pity guarantee after `counter` opens without it (nil = no rule).
	Example: supply crate (6 opens) with counter 5 --> 1
]]
function CrateLogic.pityLeft(crate: CrateDef, counter: number): number?
	local rule = crate.pity
	if rule == nil then
		return nil
	end
	return math.max(1, rule.opens - math.max(0, counter))
end

-- True when granting `reward` now would be a duplicate / blocked (paid as dupGems instead).
local function wouldDup(profile: any, reward: Reward): boolean
	if reward.kind == "trail" then
		return PetState.trails(profile).owned[reward.id or ""] == true
	elseif reward.kind == "pet" then
		return PetState.ownedCount(profile) >= PetConfig.HardCap
	end
	return false
end

--[[
	Validates an open and draws the reward (mutates nothing).
	@return (plan, "Ok") or (nil, code)
]]
function CrateLogic.planOpen(profile: any, rawCrate: unknown, ctx: OpenContext): (OpenPlan?, OpenCode)
	local crate = CrateConfig.get(rawCrate)
	if crate == nil then
		return nil, "BadCrate"
	end
	local crates = PetState.crates(profile)
	local held = crates.held[crate.id] or 0
	local pay: "held" | "gems" = if type(held) == "number" and held >= 1 then "held" else "gems"
	-- Paid random item (held crates were bought with Robux; gems are Robux-reachable).
	if ctx.restricted and CrateConfig.needsPolicy(pay) then
		return nil, "Restricted"
	end
	if pay == "gems" then
		local gems = if type(profile.gems) == "number" then profile.gems else 0
		if gems < crate.gems then
			return nil, "NotEnough"
		end
	end

	local counter = crates.pity[crate.id] or 0
	if type(counter) ~= "number" or counter ~= counter or counter < 0 then
		counter = 0
	end
	local index = CrateLogic.rollReward(crate, ctx.random)
	local forced = false
	local rule = crate.pity
	if rule ~= nil and counter + 1 >= rule.opens and PetConfig.rank(crate.rewards[index].rarity) < rule.rank then
		local pityIndex = CrateLogic.rollPityReward(crate, rule.rank, ctx.random)
		if pityIndex ~= nil then
			index = pityIndex
			forced = true
		end
	end
	local reward = crate.rewards[index]
	if rule ~= nil then
		counter = if PetConfig.rank(reward.rarity) >= rule.rank then 0 else math.min(counter + 1, COUNTER_MAX)
	end
	return {
		crate = crate,
		pay = pay,
		price = if pay == "gems" then crate.gems else 0,
		index = index,
		reward = reward,
		pityForced = forced,
		pityAfter = counter,
		dup = wouldDup(profile, reward),
	},
		"Ok"
end

--[[
	Applies a plan (see the header). For pay "gems" the gems must already be charged. All or
	nothing: every touched field is restored if anything throws.
	@param now server unix time (boost stacking)
	@return OpenApplied (the caller grants `gems`)
]]
function CrateLogic.commitOpen(profile: any, plan: OpenPlan, now: number): OpenApplied
	local crates = PetState.crates(profile)
	local pets = PetState.pets(profile)
	local trails = PetState.trails(profile)
	local reward = plan.reward
	local crateId = plan.crate.id
	local boosts = if type(profile.boosts) == "table" then profile.boosts else nil
	local undo = {
		held = crates.held[crateId],
		pity = crates.pity[crateId],
		opened = crates.opened,
		owned = table.clone(pets.owned),
		nextUid = pets.nextUid,
		index = table.clone(pets.index),
		eggs = table.clone(pets.eggs),
		trailsOwned = table.clone(trails.owned),
		trail = trails.equipped,
		boosts = if boosts ~= nil then table.clone(boosts) else nil,
	}
	local applied: OpenApplied =
		{ gems = 0, uid = nil, isNew = false, boostEndsAt = nil, trailEquipped = false, dup = false }
	local ok, err = pcall(function()
		if plan.pay == "held" then
			local left = (crates.held[crateId] or 0) - 1
			crates.held[crateId] = if left > 0 then left else nil
		end
		if plan.dup or wouldDup(profile, reward) then
			applied.gems = plan.crate.dupGems
			applied.dup = true
		elseif reward.kind == "gems" then
			applied.gems = reward.amount
		elseif reward.kind == "boost" then
			assert(boosts ~= nil, "profile.boosts missing")
			applied.boostEndsAt = BoostLogic.extend(boosts, reward.id :: string, reward.seconds, now)
			assert(applied.boostEndsAt ~= nil, `boost {reward.id} not applied`)
		elseif reward.kind == "egg" then
			if not PetLogic.grantEgg(profile, reward.id, reward.amount) then
				applied.gems = plan.crate.dupGems
				applied.dup = true
			end
		elseif reward.kind == "pet" then
			local uid, isNew = PetLogic.grantPet(profile, reward.id, false)
			if uid == nil then
				applied.gems = plan.crate.dupGems
				applied.dup = true
			else
				applied.uid = uid
				applied.isNew = isNew
			end
		elseif reward.kind == "trail" then
			trails.owned[reward.id :: string] = true
			applied.isNew = true
			if trails.equipped == "" then
				trails.equipped = reward.id :: string
				applied.trailEquipped = true
			end
		else
			error(`unknown reward kind {reward.kind}`)
		end
		crates.opened = math.min(crates.opened + 1, 1e15)
		if plan.crate.pity ~= nil then
			crates.pity[crateId] = if plan.pityAfter > 0 then plan.pityAfter else nil
		end
	end)
	if not ok then
		crates.held[crateId] = undo.held
		crates.pity[crateId] = undo.pity
		crates.opened = undo.opened
		table.clear(pets.owned)
		for uid, entry in undo.owned do
			pets.owned[uid] = entry
		end
		pets.nextUid = undo.nextUid
		table.clear(pets.index)
		for id, value in undo.index do
			pets.index[id] = value
		end
		table.clear(pets.eggs)
		for id, value in undo.eggs do
			pets.eggs[id] = value
		end
		table.clear(trails.owned)
		for id, value in undo.trailsOwned do
			trails.owned[id] = value
		end
		trails.equipped = undo.trail
		if boosts ~= nil and undo.boosts ~= nil then
			table.clear(boosts)
			for key, value in undo.boosts do
				boosts[key] = value
			end
		end
		error(err, 0)
	end
	return applied
end

--[[
	Plan + charge + commit + gem grant through ProfileLogic in one call (Lune tests / admin).
	@return (plan, applied, "Ok") or (nil, nil, code)
]]
function CrateLogic.open(profile: any, rawCrate: unknown, ctx: OpenContext): (OpenPlan?, OpenApplied?, OpenCode)
	local plan, code = CrateLogic.planOpen(profile, rawCrate, ctx)
	if plan == nil then
		return nil, nil, code
	end
	if plan.pay == "gems" then
		assert(ProfileLogic.spendGems(profile, plan.price), "CrateLogic: gem charge failed after the check")
	end
	local ok, applied = pcall(CrateLogic.commitOpen, profile, plan, ctx.now)
	if not ok then
		if plan.pay == "gems" then
			ProfileLogic.addGems(profile, plan.price)
		end
		error(applied, 0)
	end
	if applied.gems > 0 then
		ProfileLogic.addGems(profile, applied.gems)
	end
	return plan, applied, "Ok"
end

export type ReceiptDecision = "defer" | "gems" | "crate"

--[[
	What a Robux crate receipt does for the buyer's policy (pure; CrateService.handleReceipt):
		policy unknown      → "defer"  (NotProcessedYet: Roblox re-delivers once it is known —
		                               never a crate on an unknown answer, fail closed)
		known restricted    → "gems"   (the crate's gem price per crate instead of a crate)
		known unrestricted  → "crate"  (held crates)
	Example: CrateLogic.receiptDecision(true, false) --> "crate"
]]
function CrateLogic.receiptDecision(policyKnown: boolean, restricted: boolean): ReceiptDecision
	if policyKnown ~= true then
		return "defer"
	end
	return if restricted == false then "crate" else "gems"
end

--[[
	A Robux receipt (MonetizationConfig kind "Crate"): adds `count` HELD crates of `rawCrate`.
	A player whose paid-random policy is KNOWN restricted (bought before it was known) gets the
	crate's gem price per crate instead — never a roll. Pure; the caller checks the receipt ledger.
	@return (ok, gemsInstead) — ok false: unknown crate / bad count (nothing changed)
	Example: CrateLogic.applyReceipt(profile, "golden_crate", 1, false) --> true, 0
]]
function CrateLogic.applyReceipt(
	profile: any,
	rawCrate: unknown,
	count: unknown,
	restricted: boolean
): (boolean, number)
	local crate = CrateConfig.get(rawCrate)
	if crate == nil or type(count) ~= "number" or count ~= count or count % 1 ~= 0 or count < 1 or count > 100 then
		return false, 0
	end
	if restricted then
		local gems = crate.gems * count
		ProfileLogic.addGems(profile, gems)
		return true, gems
	end
	local crates = PetState.crates(profile)
	local current = crates.held[crate.id] or 0
	crates.held[crate.id] = math.min(current + count, CrateConfig.Server.MaxHeld)
	return true, 0
end

--[[
	Adds `count` held crates (admin / rewards; no gems fallback). @return true when granted
]]
function CrateLogic.grantHeld(profile: any, rawCrate: unknown, count: number): boolean
	local crate = CrateConfig.get(rawCrate)
	if crate == nil or type(count) ~= "number" or count ~= count or count % 1 ~= 0 or count < 1 or count > 100 then
		return false
	end
	local crates = PetState.crates(profile)
	crates.held[crate.id] = math.min((crates.held[crate.id] or 0) + count, CrateConfig.Server.MaxHeld)
	return true
end

--[[
	Grants a trail directly (admin / rewards). @return true when it was not owned before
]]
function CrateLogic.grantTrail(profile: any, rawTrail: unknown): boolean
	local def = CrateConfig.getTrail(rawTrail)
	if def == nil then
		return false
	end
	local trails = PetState.trails(profile)
	if trails.owned[def.id] == true then
		return false
	end
	trails.owned[def.id] = true
	return true
end

--[[
	Equips an owned trail ("" unequips). @return "Ok" | "BadTrail" | "Same"
	Example: CrateLogic.equipTrail(profile, "trail_rainbow") --> "Ok"
]]
function CrateLogic.equipTrail(profile: any, rawTrail: unknown): "Ok" | "BadTrail" | "Same"
	local trails = PetState.trails(profile)
	if rawTrail == "" then
		if trails.equipped == "" then
			return "Same"
		end
		trails.equipped = ""
		return "Ok"
	end
	local def = CrateConfig.getTrail(rawTrail)
	if def == nil or trails.owned[def.id] ~= true then
		return "BadTrail"
	end
	if trails.equipped == def.id then
		return "Same"
	end
	trails.equipped = def.id
	return "Ok"
end

--[[ Player-facing text for an open refusal. ]]
function CrateLogic.refusalMessage(code: string, crate: CrateDef?): string
	if code == "Restricted" then
		return CrateConfig.PolicyText.RefusedRestricted
	elseif code == "PolicyUnknown" then
		return CrateConfig.PolicyText.RefusedUnknown
	elseif code == "NotEnough" and crate ~= nil then
		return `You need {crate.gems} gems for the {crate.name}.`
	end
	return "That crate can't be opened right now."
end

return table.freeze(CrateLogic)
