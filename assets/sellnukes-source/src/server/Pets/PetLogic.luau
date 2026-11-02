--!strict
--[[
	PetLogic — pure server rules for EGGS and PETS: plan + commit a hatch (single / triple, luck,
	pity, held eggs, stand range, area gate, inventory cap, paid-random policy), equip / unequip,
	Equip Best, delete, lock, reward grants, and the equipped cash bonus. No Players, no remotes,
	no DataStores, no yields: every rule runs identically in Lune (tests/pets-logic.luau, seeded
	RNG) and in Studio.

	A hatch is PLAN → CHARGE → COMMIT with no yield in between (PetService runs all three in one
	synchronous block):
		planHatch    validates everything and draws every roll against a scratch pity counter;
		             mutates NOTHING. Refusal codes below.
		(charge)     the caller takes `plan.total` of `plan.currency` (PetService uses
		             PlayerDataService.trySpendCash so analytics see the sink; `hatch` below uses
		             ProfileLogic directly for tests / admin)
		commitHatch  spends the held eggs, grants the pets (new uids), writes pets.index, the pity
		             counter and stats.hatched, auto-equips into free slots. Captures every field it
		             touches first and restores them if anything throws, so a profile is never
		             half-updated (the caller then refunds the charge).

	Roll order per egg (pinned by tests so the published odds are exactly what runs):
		1. odds = EggConfig.oddsFor(egg, lucky)            (LuckyEggs pass doubles the rare slots)
		2. slot = NextInteger(1, TotalBp) over cumulative odds
		3. PITY: when this is the `pity.hatches`-th hatch in a row without slot >= pity.slot and
		   step 2 missed it: slot = NextInteger(1, sum of odds[slot >= pity.slot]) re-roll among
		   those slots, proportional to their odds ("natural first": a due guarantee only changes
		   a roll that missed). Counter resets on any slot >= pity.slot, else +1.
		4. pet = egg.slots[slot].pet (one pet per slot)
	A triple hatch is three independent rolls in order (roll 2 sees roll 1's pity counter).

	Payment: held eggs (profile.pets.eggs[egg]) pay first, one per egg; the rest is BOUGHT at the
	egg's price in its currency (cash / acorns / a world's currency such as Dino Valley's Bones,
	paid ONLY from profile.worlds[world].cash — currencies never mix) and needs the stand
	(ctx.atStand). A held-only egg
	(Lucky Egg) can never be bought. Buying with a Robux-reachable currency (cash AND acorns —
	EggConfig.PaidRandomCurrencies / needsPolicy) is a PAID RANDOM ITEM: refused "Restricted"
	unless the caller resolved the player's PolicyService answer to unrestricted
	(ctx.restricted = false; PetService fails closed, so unknown = restricted). Hatches fully paid
	by held eggs never need the policy (they were granted, nothing is bought).

	Refusal codes (nothing changes on any refusal):
		BadEgg      unknown egg id
		BadCount    count not 1 or 3
		NeedTriple  count 3 without the TripleHatch pass
		Closed      the egg's window is shut (Harvest Egg outside the event)
		Locked      the egg's world is still locked, or its area is above the player's tycoon area
		            in that world (EggConfig.isUnlocked: Nuke Town eggs read profile.tycoon, world
		            eggs profile.worlds[world])
		NoEggs      held-only egg and not enough held eggs
		TooFar      eggs must be bought but the character is not at the stand
		Restricted  eggs must be bought with a gated currency (EggConfig.needsPolicy) and the policy
		            is restricted or unknown (ctx.restricted, fail closed). PetService reports it
		            as "PolicyUnknown" when PolicyService has not answered (a retry may succeed).
		NotEnough   balance below the price of the bought eggs
		Full        the pets would exceed PetConfig.InventoryCap

	Connects to: Shared/Config/{PetConfig, EggConfig}, Server/Pets/PetState (schema access),
	Server/Economy/ProfileLogic (currency math in `hatch`), Server/Services/PetService (remotes),
	Server/Pets/{PetGrants, CrateLogic} (grants), tests/pets-logic.luau.

	Example:
		local plan, code = PetLogic.planHatch(profile, "garage_egg", 3, ctx)
		if plan then
			-- charge plan.total of plan.currency here (no yield), then:
			local pets = PetLogic.commitHatch(profile, plan, ctx.slots)
		end
		PetLogic.equipBest(profile, 5) --> true (equipped changed)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetState = require(script.Parent.PetState)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type EggDef = EggConfig.EggDef
type PetDef = PetConfig.PetDef

-- The RNG surface PetLogic needs (Random, or a scripted / seeded table in Lune tests).
export type RandomLike = { NextInteger: (self: any, low: number, high: number) -> number }

export type HatchContext = {
	random: RandomLike,
	now: number, -- server unix time (egg windows)
	lucky: boolean, -- owns the LuckyEggs pass
	triple: boolean, -- owns the TripleHatch pass
	slots: number, -- equip slots right now (new pets fill free slots)
	atStand: boolean, -- server range check passed (only needed to BUY eggs)
	restricted: boolean, -- paid random items restricted, or policy unknown (fail closed)
	eventOpen: boolean?, -- event authority for windowed eggs (nil = the egg's own window)
	acorns: number?, -- this season's acorn balance (EventService.getAcorns); nil = read the profile
}

export type HatchCode =
	"Ok"
	| "BadEgg"
	| "BadCount"
	| "NeedTriple"
	| "Closed"
	| "Locked"
	| "NoEggs"
	| "TooFar"
	| "Restricted"
	| "NotEnough"
	| "Full"

export type Roll = { slot: number, petId: string, pityForced: boolean }

export type HatchPlan = {
	egg: EggDef,
	count: number,
	fromHeld: number, -- eggs paid with held eggs
	bought: number, -- eggs paid with currency
	currency: EggConfig.Currency,
	total: number, -- currency to charge (bought × price)
	rolls: { Roll },
	pityAfter: number, -- the egg's pity counter after every roll
}

-- One pet a committed hatch produced (HatchResult payload rows).
export type HatchedPet = {
	uid: string,
	petId: string,
	rarity: string,
	slot: number,
	pityForced: boolean,
	isNew: boolean, -- first of its kind for this player (pets.index)
	equipped: boolean, -- auto-equipped into a free slot
}

export type EquipCode = "Ok" | "BadPet" | "NoSlot" | "Same"

local PetLogic = {}

-- Pity counters saturate here (keeps saves bounded).
local COUNTER_MAX = 1_000_000
-- Held eggs of one id saturate here.
local HELD_MAX = EggConfig.MaxHeld
-- Distinct held egg ids (bounded save map).
local HELD_KINDS_MAX = 32

-- True for a finite whole number in [lo, hi].
local function wholeIn(value: unknown, lo: number, hi: number): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= lo and value <= hi
end

--------------------------------------------------------------------------------------------------
-- Rolls
--------------------------------------------------------------------------------------------------

--[[
	Step 2: a slot index from cumulative `odds` (NextInteger(1, TotalBp)).
	Example: PetLogic.rollSlot({ 65000, 27000, 7000, 1000 }, rng) --> 1..4
]]
function PetLogic.rollSlot(odds: { number }, random: RandomLike): number
	local draw = random:NextInteger(1, EggConfig.TotalBp)
	local cumulative = 0
	for index, bp in odds do
		cumulative += bp
		if draw <= cumulative then
			return index
		end
	end
	-- Unreachable with a valid config (validate: odds sum to TotalBp); rarest slot is safe.
	return #odds
end

--[[
	Step 3: the pity re-roll among slots >= `minSlot`, proportional to their odds.
	@return the slot, or nil when those slots have no weight (validate forbids it)
]]
function PetLogic.rollPitySlot(odds: { number }, minSlot: number, random: RandomLike): number?
	local total = 0
	for index = minSlot, #odds do
		total += odds[index]
	end
	if total <= 0 then
		return nil
	end
	local draw = random:NextInteger(1, total)
	local cumulative = 0
	for index = minSlot, #odds do
		cumulative += odds[index]
		if draw <= cumulative then
			return index
		end
	end
	return nil
end

--------------------------------------------------------------------------------------------------
-- Hatching
--------------------------------------------------------------------------------------------------

--[[
	The non-main world whose WALLET currency `currency` is ("bones" -> "dino"); nil for cash,
	acorns, held, rebirth tokens ("amber") or unknown keys. Eggs are only ever priced in a world's
	wallet currency, never in its tokens.
	Example: PetLogic.worldWallet("bones") --> "dino"; PetLogic.worldWallet("amber") --> nil
]]
function PetLogic.worldWallet(currency: EggConfig.Currency): string?
	local worldId = WorldsConfig.worldOfCurrency(currency)
	if worldId == nil or worldId == WorldsConfig.MAIN then
		return nil
	end
	local world = WorldsConfig.get(worldId)
	return if world ~= nil and world.currency.key == currency then worldId else nil
end

--[[
	The player's balance of an egg currency: cash, this profile's acorns, or a world's wallet
	(profile.worlds[world].cash, read-only: a missing world reads 0). Held eggs have no balance.
	Example: PetLogic.balanceOf(profile, "bones") --> profile.worlds.dino.cash
]]
function PetLogic.balanceOf(profile: any, currency: EggConfig.Currency): number
	if currency == "cash" then
		return if type(profile.cash) == "number" then profile.cash else 0
	elseif currency == "acorns" then
		local event = profile.event
		return if type(event) == "table" and type(event.acorns) == "number" then event.acorns else 0
	end
	local worldId = PetLogic.worldWallet(currency)
	if worldId ~= nil then
		local world = ProfileLogic.peekWorld(profile, worldId)
		local cash = if world ~= nil then world.cash else nil
		return if type(cash) == "number" and cash == cash and cash >= 0 then cash else 0
	end
	return 0
end

--[[ True when hatching `egg` is open at ctx.now (the event authority wins for windowed eggs). ]]
function PetLogic.isOpen(egg: EggDef, ctx: HatchContext): boolean
	if egg.window ~= nil and ctx.eventOpen ~= nil then
		return ctx.eventOpen
	end
	return EggConfig.isOpen(egg, ctx.now)
end

--[[
	Validates a hatch and draws every roll (mutates nothing). See the header for the codes.
	@param profile  the live profile (read only here)
	@param rawEgg   untrusted egg id
	@param rawCount untrusted count (1 or 3)
	@param ctx      server-built context (never from the client)
	@return (plan, "Ok") or (nil, code)
]]
function PetLogic.planHatch(
	profile: any,
	rawEgg: unknown,
	rawCount: unknown,
	ctx: HatchContext
): (HatchPlan?, HatchCode)
	local egg = EggConfig.get(rawEgg)
	if egg == nil then
		return nil, "BadEgg"
	end
	if rawCount ~= 1 and rawCount ~= EggConfig.TripleCount then
		return nil, "BadCount"
	end
	local count = rawCount :: number
	if count > 1 and not ctx.triple then
		return nil, "NeedTriple"
	end
	if not PetLogic.isOpen(egg, ctx) then
		return nil, "Closed"
	end
	-- World + area progress of the egg's own world (Nuke Town: profile.tycoon; Dino Valley:
	-- profile.worlds.dino, which must also be unlocked).
	if not EggConfig.isUnlocked(profile, egg) then
		return nil, "Locked"
	end
	local pets = PetState.pets(profile)
	local held = pets.eggs[egg.id] or 0
	local fromHeld = math.min(if wholeIn(held, 0, HELD_MAX) then held else 0, count)
	local bought = count - fromHeld
	if bought > 0 then
		if egg.currency == "held" then
			return nil, "NoEggs"
		end
		if not ctx.atStand then
			return nil, "TooFar"
		end
		-- Paid random item (cash / acorns are Robux-reachable): the policy must be known-allowed.
		if ctx.restricted and EggConfig.needsPolicy(egg, fromHeld, count) then
			return nil, "Restricted"
		end
		local balance = if egg.currency == "acorns" and ctx.acorns ~= nil
			then ctx.acorns
			else PetLogic.balanceOf(profile, egg.currency)
		if balance < egg.price * bought then
			return nil, "NotEnough"
		end
	end
	if PetState.ownedCount(profile) + count > PetConfig.InventoryCap then
		return nil, "Full"
	end

	-- Draw every roll against a scratch pity counter (nothing written yet).
	local odds = EggConfig.oddsFor(egg, ctx.lucky)
	local rule = egg.pity
	local counter = pets.pity[egg.id] or 0
	if not wholeIn(counter, 0, COUNTER_MAX) then
		counter = 0
	end
	local rolls: { Roll } = {}
	for _ = 1, count do
		local slot = PetLogic.rollSlot(odds, ctx.random)
		local forced = false
		if rule ~= nil and counter + 1 >= rule.hatches and slot < rule.slot then
			local pitySlot = PetLogic.rollPitySlot(odds, rule.slot, ctx.random)
			if pitySlot ~= nil then
				slot = pitySlot
				forced = true
			end
		end
		if rule ~= nil then
			counter = if slot >= rule.slot then 0 else math.min(counter + 1, COUNTER_MAX)
		end
		table.insert(rolls, { slot = slot, petId = egg.slots[slot].pet, pityForced = forced })
	end

	return {
		egg = egg,
		count = count,
		fromHeld = fromHeld,
		bought = bought,
		currency = if bought > 0 then egg.currency else "held",
		total = if bought > 0 then egg.price * bought else 0,
		rolls = rolls,
		pityAfter = counter,
	},
		"Ok"
end

-- Assigns the next uid and stores the pet (no checks; callers checked the caps).
local function addPet(pets: PetState.Pets, petId: string): string
	local uid = tostring(pets.nextUid)
	-- A corrupt save could hold this uid already (reconcile prevents it); never overwrite.
	while pets.owned[uid] ~= nil do
		pets.nextUid += 1
		uid = tostring(pets.nextUid)
	end
	pets.nextUid += 1
	pets.owned[uid] = { id = petId }
	return uid
end

--[[
	Applies a plan (see the header). The CHARGE must already have happened. All or nothing: on an
	error every touched field is restored before the error propagates.
	@param slots equip slots right now (free slots are filled by the new pets, best first)
	@return the pets granted, in roll order
]]
function PetLogic.commitHatch(profile: any, plan: HatchPlan, slots: number): { HatchedPet }
	local pets = PetState.pets(profile)
	local eggId = plan.egg.id
	local undo = {
		owned = table.clone(pets.owned),
		equipped = table.clone(pets.equipped),
		nextUid = pets.nextUid,
		held = pets.eggs[eggId],
		pity = pets.pity[eggId],
		index = table.clone(pets.index),
		hatched = if type(profile.stats) == "table" then profile.stats.hatched else nil,
	}
	local out: { HatchedPet } = {}
	local ok, err = pcall(function()
		if plan.fromHeld > 0 then
			local left = (pets.eggs[eggId] or 0) - plan.fromHeld
			pets.eggs[eggId] = if left > 0 then left else nil
		end
		for _, roll in plan.rolls do
			local def = PetConfig.get(roll.petId)
			assert(def ~= nil, `unknown pet {roll.petId}`)
			local uid = addPet(pets, roll.petId)
			local isNew = pets.index[roll.petId] ~= true
			pets.index[roll.petId] = true
			local equipped = false
			if #pets.equipped < slots then
				table.insert(pets.equipped, uid)
				equipped = true
			end
			table.insert(out, {
				uid = uid,
				petId = roll.petId,
				rarity = def.rarity,
				slot = roll.slot,
				pityForced = roll.pityForced,
				isNew = isNew,
				equipped = equipped,
			})
		end
		if plan.egg.pity ~= nil then
			pets.pity[eggId] = if plan.pityAfter > 0 then plan.pityAfter else nil
		end
		if type(profile.stats) == "table" and type(profile.stats.hatched) == "number" then
			profile.stats.hatched = math.min(profile.stats.hatched + plan.count, 1e15)
		end
	end)
	if not ok then
		table.clear(pets.owned)
		for uid, entry in undo.owned do
			pets.owned[uid] = entry
		end
		table.clear(pets.equipped)
		for _, uid in undo.equipped do
			table.insert(pets.equipped, uid)
		end
		pets.nextUid = undo.nextUid
		pets.eggs[eggId] = undo.held
		pets.pity[eggId] = undo.pity
		table.clear(pets.index)
		for id, value in undo.index do
			pets.index[id] = value
		end
		if undo.hatched ~= nil then
			profile.stats.hatched = undo.hatched
		end
		error(err, 0)
	end
	return out
end

--[[
	Plan + charge (ProfileLogic / event acorns, no analytics) + commit in one call — the Lune
	tests' and admin's path. PetService uses planHatch / its own charge / commitHatch instead.
	@return (pets, "Ok", plan) or (nil, code, nil)
	Example: PetLogic.hatch(profile, "garage_egg", 1, ctx) --> { { uid = "1", petId = "glow_slime", ... } }, "Ok", plan
]]
function PetLogic.hatch(
	profile: any,
	rawEgg: unknown,
	rawCount: unknown,
	ctx: HatchContext
): ({ HatchedPet }?, HatchCode, HatchPlan?)
	local plan, code = PetLogic.planHatch(profile, rawEgg, rawCount, ctx)
	if plan == nil then
		return nil, code, nil
	end
	if plan.total > 0 then
		if plan.currency == "cash" then
			assert(ProfileLogic.spendCash(profile, plan.total), "PetLogic: cash charge failed after the check")
		elseif plan.currency == "acorns" then
			profile.event.acorns -= plan.total
		else
			local worldId = PetLogic.worldWallet(plan.currency)
			assert(worldId ~= nil, `PetLogic: no wallet for {plan.currency}`)
			assert(
				ProfileLogic.spendWorldCash(profile, worldId, plan.total),
				"PetLogic: world currency charge failed after the check"
			)
		end
	end
	local ok, result = pcall(PetLogic.commitHatch, profile, plan, ctx.slots)
	if not ok then
		PetLogic.refund(profile, plan)
		error(result, 0)
	end
	return result, "Ok", plan
end

--[[
	Gives back a plan's charge (only after a failed commit). Cash goes straight back to the balance
	(NOT through ProfileLogic.addCash: a refund is not income, so totalEarned must not grow).
]]
function PetLogic.refund(profile: any, plan: HatchPlan)
	if plan.total <= 0 then
		return
	end
	if plan.currency == "cash" then
		profile.cash += plan.total
	elseif plan.currency == "acorns" then
		profile.event.acorns += plan.total
	else
		-- A world wallet: straight back into the balance (not totalEarned — a refund is not income),
		-- clamped like every wallet.
		local worldId = PetLogic.worldWallet(plan.currency)
		if worldId ~= nil then
			local world = ProfileLogic.worldState(profile, worldId)
			world.cash = math.min(world.cash + plan.total, ProfileLogic.Limits.MaxCash)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Equip / Equip Best / delete / lock
--------------------------------------------------------------------------------------------------

--[[
	Drops equipped uids that are not owned (or duplicated) and trims to `slots` (e.g. the PetSlots
	pass was refunded). @return true when anything changed
]]
function PetLogic.trimEquipped(profile: any, slots: number): boolean
	local pets = PetState.pets(profile)
	local kept: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, uid in pets.equipped do
		if type(uid) == "string" and pets.owned[uid] ~= nil and not seen[uid] and #kept < slots then
			seen[uid] = true
			table.insert(kept, uid)
		end
	end
	if #kept == #pets.equipped then
		return false
	end
	table.clear(pets.equipped)
	for _, uid in kept do
		table.insert(pets.equipped, uid)
	end
	return true
end

--[[
	Equips (on) or unequips (not on) the pet `rawUid`.
	@return "Ok" | "BadPet" (not owned) | "NoSlot" (every slot full) | "Same" (already so)
]]
function PetLogic.setEquipped(profile: any, rawUid: unknown, on: boolean, slots: number): EquipCode
	local pets = PetState.pets(profile)
	if type(rawUid) ~= "string" or pets.owned[rawUid] == nil then
		return "BadPet"
	end
	local uid = rawUid :: string
	local index = table.find(pets.equipped, uid)
	if on then
		if index ~= nil then
			return "Same"
		end
		if #pets.equipped >= slots then
			return "NoSlot"
		end
		table.insert(pets.equipped, uid)
		return "Ok"
	end
	if index == nil then
		return "Same"
	end
	table.remove(pets.equipped, index)
	return "Ok"
end

-- Numeric order of uids (older first) as the last tie-breaker; non-numeric uids sort by text.
local function uidBefore(a: string, b: string): boolean
	local na, nb = tonumber(a), tonumber(b)
	if na ~= nil and nb ~= nil and na ~= nb then
		return na < nb
	end
	return a < b
end

--[[
	The owned uids sorted best first (PetConfig.better, then older first). Unknown pet ids (a
	removed config entry) sort last.
]]
function PetLogic.rankedUids(profile: any): { string }
	local pets = PetState.pets(profile)
	local uids: { string } = {}
	for uid in pets.owned do
		table.insert(uids, uid)
	end
	table.sort(uids, function(a: string, b: string): boolean
		local da, db = PetConfig.get(pets.owned[a].id), PetConfig.get(pets.owned[b].id)
		if da ~= nil and db ~= nil then
			-- Different species: PetConfig.better is a strict order (roster order breaks ties).
			if da.id ~= db.id then
				return PetConfig.better(da, db)
			end
		elseif da ~= nil then
			return true
		elseif db ~= nil then
			return false
		end
		-- Same pet (or both unknown): older first, a stable total order.
		return uidBefore(a, b)
	end)
	return uids
end

--[[
	Equips the `slots` best pets (Equip Best). @return true when the equipped set changed
	Example: PetLogic.equipBest(profile, 3) --> true
]]
function PetLogic.equipBest(profile: any, slots: number): boolean
	local pets = PetState.pets(profile)
	local ranked = PetLogic.rankedUids(profile)
	local best: { string } = {}
	for index = 1, math.min(slots, #ranked) do
		best[index] = ranked[index]
	end
	local changed = #best ~= #pets.equipped
	if not changed then
		for index, uid in best do
			if pets.equipped[index] ~= uid then
				changed = true
				break
			end
		end
	end
	if changed then
		table.clear(pets.equipped)
		for _, uid in best do
			table.insert(pets.equipped, uid)
		end
	end
	return changed
end

--[[
	Deletes owned, UNLOCKED pets (equipped ones are unequipped first).
	@param uids validated list of uids (Validate.stringArray)
	@return (deleted uids, how many were skipped because locked)
]]
function PetLogic.deletePets(profile: any, uids: { string }): ({ string }, number)
	local pets = PetState.pets(profile)
	local deleted: { string } = {}
	local locked = 0
	for _, uid in uids do
		local entry = pets.owned[uid]
		if entry ~= nil then
			if entry.locked == true then
				locked += 1
			else
				pets.owned[uid] = nil
				local index = table.find(pets.equipped, uid)
				if index ~= nil then
					table.remove(pets.equipped, index)
				end
				table.insert(deleted, uid)
			end
		end
	end
	return deleted, locked
end

--[[ Locks / unlocks owned pets. @return how many changed ]]
function PetLogic.lockPets(profile: any, uids: { string }, locked: boolean): number
	local pets = PetState.pets(profile)
	local changed = 0
	for _, uid in uids do
		local entry = pets.owned[uid]
		if entry ~= nil and (entry.locked == true) ~= locked then
			entry.locked = if locked then true else nil
			changed += 1
		end
	end
	return changed
end

--------------------------------------------------------------------------------------------------
-- Grants (rewards, crates, admin) and the cash bonus
--------------------------------------------------------------------------------------------------

--[[
	Grants one pet. `soft` respects InventoryCap (crates / hatches); otherwise only HardCap (paid
	or one-time rewards must never be lost). Writes pets.index.
	@return (uid, isNew) or (nil, false) for an unknown pet / full inventory
	Example: PetLogic.grantPet(profile, "group_glow_kitty", false) --> "12", true
]]
function PetLogic.grantPet(profile: any, rawPetId: unknown, soft: boolean): (string?, boolean)
	local def = PetConfig.get(rawPetId)
	if def == nil then
		return nil, false
	end
	local cap = if soft then PetConfig.InventoryCap else PetConfig.HardCap
	if PetState.ownedCount(profile) >= cap then
		return nil, false
	end
	local pets = PetState.pets(profile)
	local uid = addPet(pets, def.id)
	local isNew = pets.index[def.id] ~= true
	pets.index[def.id] = true
	return uid, isNew
end

--[[
	Adds `count` held eggs of `rawEggId` (crates, Lucky Wheel, admin). Bounded: ≤ HELD_MAX per id,
	≤ HELD_KINDS_MAX ids. @return true when granted
	Example: PetLogic.grantEgg(profile, "lucky_egg", 2) --> true
]]
function PetLogic.grantEgg(profile: any, rawEggId: unknown, count: number): boolean
	local egg = EggConfig.get(rawEggId)
	if egg == nil or not wholeIn(count, 1, 1_000) then
		return false
	end
	local eggs = PetState.pets(profile).eggs
	if eggs[egg.id] == nil then
		local kinds = 0
		for _ in eggs do
			kinds += 1
		end
		if kinds >= HELD_KINDS_MAX then
			return false
		end
	end
	local current = eggs[egg.id] or 0
	if not wholeIn(current, 0, HELD_MAX) then
		current = 0
	end
	eggs[egg.id] = math.min(current + count, HELD_MAX)
	return true
end

--[[
	The summed cash bonus of the equipped pets (TycoonTypes.Modifiers.petCash; fraction).
	Example: three Glow Slimes equipped --> 0.12
]]
function PetLogic.cashBonus(profile: any): number
	local pets = PetState.pets(profile)
	local total = 0
	local seen: { [string]: boolean } = {}
	for _, uid in pets.equipped do
		local entry = pets.owned[uid]
		if entry ~= nil and not seen[uid] then
			seen[uid] = true
			local def = PetConfig.get(entry.id)
			if def ~= nil then
				total += def.cash
			end
		end
	end
	return total
end

--[[ The equipped pets' ids in slot order (the replicated attribute). ]]
function PetLogic.equippedPetIds(profile: any): { string }
	local pets = PetState.pets(profile)
	local out: { string } = {}
	for _, uid in pets.equipped do
		local entry = pets.owned[uid]
		if entry ~= nil and PetConfig.get(entry.id) ~= nil then
			table.insert(out, entry.id)
		end
	end
	return out
end

--[[
	Player-facing text for a hatch refusal (never echoes client input).
	Example: PetLogic.refusalMessage("NeedTriple", egg) --> "Get the Triple Hatch pass to hatch 3 at once!"
]]
function PetLogic.refusalMessage(code: string, egg: EggDef?): string
	local name = if egg ~= nil then egg.name else "egg"
	if code == "NeedTriple" then
		return "Get the Triple Hatch pass to hatch 3 at once!"
	elseif code == "Closed" then
		return `The {name} is only around during the Harvest Feast!`
	elseif code == "Locked" and egg ~= nil and egg.world ~= WorldsConfig.MAIN then
		return `Reach {EggConfig.areaName(egg)} in {EggConfig.worldName(egg)} to unlock the {name}!`
	elseif code == "Locked" and egg ~= nil then
		return `Reach area {egg.area} to unlock the {name}!`
	elseif code == "NoEggs" then
		return `You don't have any {name}s left.`
	elseif code == "TooFar" then
		return `Walk up to the {name} stand to buy one!`
	elseif code == "Restricted" then
		return EggConfig.PolicyText.RefusedRestricted
	elseif code == "PolicyUnknown" then
		return EggConfig.PolicyText.RefusedUnknown
	elseif code == "NotEnough" then
		if egg ~= nil and egg.currency == "acorns" then
			return `You need more acorns for the {name}. Catch Golden Turkeys!`
		elseif egg ~= nil and PetLogic.worldWallet(egg.currency) ~= nil then
			return `You need more {EggConfig.currencyName(egg)} for the {name}. Keep building in {EggConfig.worldName(
				egg
			)}!`
		end
		return `You need more cash for the {name}. Keep building!`
	elseif code == "Full" then
		return `Your pet backpack is full ({PetConfig.InventoryCap}). Delete some pets first!`
	end
	return "That egg can't be hatched right now."
end

return table.freeze(PetLogic)
