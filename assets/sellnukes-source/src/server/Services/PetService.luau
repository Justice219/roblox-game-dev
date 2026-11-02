--!strict
--[[
	PetService — the server half of PETS and EGGS (design spec §8; rules in Server/Pets/PetLogic,
	numbers in Shared/Config/{PetConfig, EggConfig}; docs/pets.md).

	Remotes (every argument untrusted; Shared/Net/Remotes):
		HatchEgg(eggId, count, requestId, auto?)  → HatchResult(requestId, payload)
		    request id 1..2^31 (malformed → dropped, nothing to reply to); token bucket per player;
		    a repeated id gets the SAME reply back (RequestMemory, never a second charge); one
		    hatch in flight per player; refused while the profile cannot save (canMutate).
		    PAID RANDOM ITEMS: whenever the request must BUY at least one egg with a Robux-reachable
		    currency (EggConfig.needsPolicy: cash, acorns AND Bones), the player's PolicyService answer is
		    awaited on EVERY request (PlayerDataService.resolvePaidRandomAsync — cached after the
		    first lookup, FAILS CLOSED: unknown / failed / malformed = restricted) and the session
		    is re-checked after that yield; a restricted answer refuses "Restricted" (or
		    "PolicyUnknown" while PolicyService has not answered, so the client can say "try
		    again"). Held eggs never need it. Then, with NO yield: PetLogic.planHatch (validation +
		    rolls) → charge (PlayerDataService.trySpendCash so analytics see the sink, the event
		    acorns, or a world wallet through PlayerDataService.trySpendCurrency — Dino Valley's
		    Bones, R57) → PetLogic.commitHatch (grants, pity, index, auto-equip; all or nothing,
		    refunded on error) → markChanged(saveSoon). `count` is 1 or 3 (TripleHatch pass);
		    `auto` only tags analytics (AutoHatch is a client loop of ordinary requests).
		    Buying needs the character at the stand (EggStands.isNear, EggConfig.StandRange, measured
		    in WORLD space: Dino stands sit at Base Camp, ValleyLayout → WorldLayout.toWorld); a world
		    egg also needs that world unlocked + its area reached (EggConfig.isUnlocked); held eggs
		    hatch anywhere.
		EquipPet(uid, on) / EquipBest() / DeletePets({uid}) / LockPets({uid}, locked)
		    action token bucket, canMutate, bounded lists (PetConfig.Server.MaxBatch), then the
		    PetLogic rule; equip changes refresh the cash bonus + the replicated attribute.
		HatchResult(0, payload) is also sent for server grants (granted = true): the client plays
		the pet reveal for a group / event / pack pet too. Request id 0 is never a client id.
		PetIndexClaim(milestone)  (owner R78 Pet Index rewards, Shared/Config/PetIndexConfig)
		    whole number 1..PetIndexConfig.Count; token bucket per player; canMutate; then, with NO
		    yield, PetIndexLogic.claim (idempotent: claimed / locked change nothing) + the gems via
		    RewardGrant.grant (PetSeams.rewardGrant) + invalidate the modifiers. No reply remote:
		    the client re-renders from the profile push (pets.indexClaimed, gems) + a reward toast.

	Replication: Player attribute PetConfig.Attribute ("SNPets") = the equipped pets' ids
	("glow_slime,atom_pup"). Every client renders everyone's pets from it (Client/Pets) — the
	server builds no pet models and sends no per-frame data.

	Income: registers the modifier source "pets" (Tycoon/ModifierSources, B5):
	{ petCash = PetLogic.cashBonus(profile) + PetIndexLogic.bonus(profile) } (equipped pets + the
	R78 permanent Pet Index Bonus), invalidated after every equip change and Index claim.

	Grants for other systems (never yield; save soon; play the reveal):
		PetService.grantPet(player, petId, reason) -> (ok, uid?)   group pet, Gobble Bomb (B11), admin
		PetService.grantEgg(player, eggId, count, reason) -> ok      held eggs
		PetGrants.grantFixed(player, petId, reason) -> (ok, uid?)   fixed pack pets (Time Ptero, R57)
		B7 RewardLogic items: PetGrants.pet / PetGrants.egg registered as RewardGrant item granters.

	Analytics (guarded lazy, PetSeams): eggHatched (hatch / hatchN / hatchAuto / rarity /
	eggRarity / pet), pets "equip" / "equipBest" / "delete" / "refused:<reason>", R78
	"index:claim:<milestone>" / "index:gems" / "index:refused:<reason>".
	Admin (B14 registerCommand): GivePet, GiveEgg, ClearPets, R78 PetIndexView / PetIndexGrant /
	PetIndexClear (audited; docs/admin.md).

	Connects to: Server/Pets/{PetLogic, PetState, PetGrants, RequestMemory, EggStands, PetSeams,
	PetIndexLogic}, Shared/Config/PetIndexConfig,
	Services/{PlayerDataService, MonetizationService}, Client/Pets/*, UI/Screens/{Pets, EggHatch}.

	Example (tests / admin):
		local payload = PetService.handleHatch(player, "garage_egg", 1, 7)
		local ok, uid = PetService.grantPet(player, "group_glow_kitty", "group")
		PetService.handleIndexClaim(player, 1) -- R78: claim the "5 pets" Index milestone
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local EggStands = require(script.Parent.Parent.Pets.EggStands)
local MonetizationService = require(script.Parent.MonetizationService)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetGrants = require(script.Parent.Parent.Pets.PetGrants)
local PetIndexConfig = require(ReplicatedStorage.Shared.Config.PetIndexConfig)
local PetIndexLogic = require(script.Parent.Parent.Pets.PetIndexLogic)
local PetLogic = require(script.Parent.Parent.Pets.PetLogic)
local PetSeams = require(script.Parent.Parent.Pets.PetSeams)
local ProgressEvents = require(script.Parent.Parent.Progression.ProgressEvents)
local PetState = require(script.Parent.Parent.Pets.PetState)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local RequestMemory = require(script.Parent.Parent.Pets.RequestMemory)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

-- One pet row of a HatchResult (PetLogic.HatchedPet).
export type PetRow = PetLogic.HatchedPet

-- The HatchResult payload.
export type HatchPayload = {
	ok: boolean,
	code: string,
	egg: string, -- egg id ("" for grants / unknown eggs)
	count: number,
	pets: { PetRow },
	price: number, -- currency charged (0: held eggs / grants / refusals)
	currency: string, -- "cash" | "acorns" | "held"
	fromHeld: number,
	pityLeft: number?, -- hatches until the egg's guarantee after this hatch
	auto: boolean,
	granted: boolean, -- a server grant (group / event / admin), not a hatch
	message: string?, -- refusal text
}

local PetService = {}

--[[
	Fires (player, eggId, petId) for every pet a committed hatch produced (after the reply), the
	server's own fact: B11 awards the First Hatch badge from it. Not fired for grants.
]]
PetService.Hatched = Signal.new() :: Signal.Signal<Player, string, string>

local Tunables = PetConfig.Server
local hatchLimiter = RateLimiter.new(Tunables.HatchBurst, Tunables.HatchPerSecond)
local actionLimiter = RateLimiter.new(Tunables.ActionBurst, Tunables.ActionPerSecond)
-- R78 Pet Index claims (PetIndexClaim): a few presses, then one per second.
local indexLimiter = RateLimiter.new(PetIndexConfig.Server.ClaimBurst, PetIndexConfig.Server.ClaimPerSecond)
-- (Generic instantiation by cast: the new solver does not infer T from the annotation.)
local memory: RequestMemory.RequestMemory<HatchPayload> = RequestMemory.new(Tunables.RecentRequests) :: any

-- The server RNG (swappable in Studio tests only, see useRandomForTests).
local rng: PetLogic.RandomLike = Random.new()

-- Server-side refusal texts (codes that never reach PetLogic).
local MESSAGES: { [string]: string } = {
	RateLimited = "Slow down - one egg at a time!",
	Busy = "Your last egg is still cracking!",
	NotLoaded = "Your pets are still loading. Try again in a moment.",
	SaveOffline = "Hatching is paused while your save is offline. Please rejoin!",
	Error = "Something went wrong - nothing was charged.",
}

-- Hatch refusal code → analytics reason (pets "refused:<reason>"; AnalyticsConfig documents
-- the allowed reasons — an undocumented one would be dropped as a bad key).
local REFUSAL_REASON: { [string]: string } = {
	NotEnough = "cash",
	Full = "slots",
	RateLimited = "rate",
	Locked = "locked",
	Restricted = "policy", -- paid random items restricted in the player's region
	PolicyUnknown = "policy", -- PolicyService not answered yet (fail closed)
}

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

--[[ Equip slots of `player` right now (base + PetSlots pass + Rebirth shop "petSlots"). ]]
function PetService.slotsFor(player: Player, profile: any): number
	local shop = if type(profile.rebirthShop) == "table" then profile.rebirthShop[PetConfig.Slots.ShopKey] else 0
	return PetConfig.slotsFor(MonetizationService.ownsPass(player, PetConfig.Slots.PassKey), shop)
end

--[[
	Writes the replicated equipped-pets attribute and tells the tycoon the cash bonus may have
	changed. Called after every equip change and on load. Never yields.
]]
function PetService.refresh(player: Player)
	local profile = PlayerDataService.getProfile(player)
	local value = if profile ~= nil then PetConfig.encodeEquipped(PetLogic.equippedPetIds(profile)) else ""
	if player:GetAttribute(PetConfig.Attribute) ~= value then
		player:SetAttribute(PetConfig.Attribute, value)
	end
	PetSeams.invalidateModifiers(player)
end

-- A refusal payload (nothing charged).
local function failure(code: string, egg: EggConfig.EggDef?, message: string?): HatchPayload
	return {
		ok = false,
		code = code,
		egg = if egg ~= nil then egg.id else "",
		count = 0,
		pets = {},
		price = 0,
		currency = if egg ~= nil then egg.currency else "cash",
		fromHeld = 0,
		pityLeft = nil,
		auto = false,
		granted = false,
		message = message or MESSAGES[code] or PetLogic.refusalMessage(code, egg),
	}
end

-- Sends a HatchResult to a player still in the server.
local function send(player: Player, requestId: number, payload: HatchPayload)
	if player.Parent == Players then
		Remotes.fireClient("HatchResult", player, requestId, payload)
	end
end

-- Analytics for a refused hatch (counted only for refusals that passed the rate limit).
local function trackRefusal(player: Player, code: string)
	PetSeams.analytics("pets", player, `refused:{REFUSAL_REASON[code] or "other"}`)
end

-- This season's acorns: EventService.getAcorns, else the profile's balance only if it is this
-- season's (a stale previous-season balance never buys an egg).
local function acornBalance(player: Player, profile: any): number
	local fromService = PetSeams.acornsOf(player)
	if fromService ~= nil then
		return fromService
	end
	local event = profile.event
	if type(event) == "table" and event.season == EventConfig.Season.id and type(event.acorns) == "number" then
		return event.acorns
	end
	return 0
end

-- Event authority for windowed eggs: EventService.isActive (admin force + dates), else nil.
local function eventOpen(egg: EggConfig.EggDef): boolean?
	if egg.window == nil then
		return nil
	end
	return PetSeams.eventActive()
end

--------------------------------------------------------------------------------------------------
-- Hatching
--------------------------------------------------------------------------------------------------

--[[
	The HatchEgg handler (also the Studio test entry point). See the header for every check.
	@return the payload sent (nil when the request id itself was malformed)
]]
function PetService.handleHatch(
	player: Player,
	rawEgg: unknown,
	rawCount: unknown,
	rawRequestId: unknown,
	rawAuto: unknown?
): HatchPayload?
	local requestId = Validate.integer(rawRequestId, 1, Tunables.MaxRequestId)
	if requestId == nil then
		return nil
	end
	if not hatchLimiter:Allow(player.UserId) then
		-- Replied (an honest client clears its pending state) but not remembered or counted.
		local payload = failure("RateLimited", nil)
		send(player, requestId, payload)
		return payload
	end
	local previous = memory:get(player, requestId)
	if previous ~= nil then
		send(player, requestId, previous) -- idempotent: the same reply, never a second hatch
		return previous
	end
	local egg = EggConfig.get(Validate.key(rawEgg, 32))
	if not memory:tryBegin(player) then
		local payload = failure("Busy", egg)
		send(player, requestId, payload)
		return payload
	end

	local ok, outcome = pcall(function(): HatchPayload
		local session = PlayerDataService.getSession(player)
		if session == nil then
			return failure("NotLoaded", egg)
		end
		if not PlayerDataService.canMutate(player) then
			return failure("SaveOffline", egg)
		end
		local profile = session.profile
		-- Policy first (may yield) — whenever eggs must be BOUGHT with a gated currency (a paid
		-- random item). Re-checked on every request: never trusted from an earlier one.
		-- Fail closed: only a resolved PolicyService answer can lower it (a hatch fully paid by
		-- held eggs never reads it).
		local restricted = true
		if egg ~= nil then
			local held = PetState.pets(profile).eggs[egg.id] or 0
			local count = if rawCount == EggConfig.TripleCount then EggConfig.TripleCount else 1
			if EggConfig.needsPolicy(egg, held, count) then
				restricted = PlayerDataService.resolvePaidRandomAsync(player)
				-- Re-check after the yield: the player may have left / reloaded / lost the lock.
				local current = PlayerDataService.getSession(player)
				if current ~= session or player.Parent ~= Players then
					return failure("NotLoaded", egg)
				end
				if not PlayerDataService.canMutate(player) then
					return failure("SaveOffline", egg)
				end
			end
		end

		-- From here: NO yields (plan → charge → commit).
		local slots = PetService.slotsFor(player, profile)
		local ctx: PetLogic.HatchContext = {
			random = rng,
			now = os.time(),
			lucky = MonetizationService.ownsPass(player, EggConfig.LuckPass),
			triple = MonetizationService.ownsPass(player, EggConfig.TriplePass),
			slots = slots,
			atStand = egg ~= nil and EggStands.isNear(player, egg.id, EggConfig.StandRange),
			restricted = restricted,
			eventOpen = if egg ~= nil then eventOpen(egg) else nil,
			acorns = if egg ~= nil and egg.currency == "acorns" then acornBalance(player, profile) else nil,
		}
		local plan, code = PetLogic.planHatch(profile, if egg ~= nil then egg.id else nil, rawCount, ctx)
		if plan == nil then
			-- A refusal only because PolicyService has not answered yet: say so (a retry may work).
			if code == "Restricted" and not PlayerDataService.isPolicyKnown(player) then
				return failure("PolicyUnknown", egg)
			end
			return failure(code, egg)
		end
		local fields = { "pets", "stats" }
		if plan.total > 0 then
			if plan.currency == "cash" then
				if not PlayerDataService.trySpendCash(player, plan.total, "egg_hatch") then
					return failure("NotEnough", plan.egg)
				end
			elseif plan.currency == "acorns" then
				-- EventService owns acorns (season rollover, analytics); direct spend only if it is
				-- unavailable, and then only from this season's balance.
				local spent = PetSeams.spendAcorns(player, plan.total, "harvest_egg")
				if spent == nil then
					spent = type(profile.event) == "table"
						and profile.event.season == EventConfig.Season.id
						and profile.event.acorns >= plan.total
					if spent then
						profile.event.acorns -= plan.total
					end
				end
				if not spent then
					return failure("NotEnough", plan.egg)
				end
				table.insert(fields, "event")
			else
				-- A world's wallet (Dino Valley: Bones; R57). PlayerDataService spends from that
				-- world only (currencies never mix), marks "worldCash" and reports the sink.
				if PetLogic.worldWallet(plan.currency) == nil then
					return failure("Error", plan.egg)
				end
				if not PlayerDataService.trySpendCurrency(player, plan.currency, plan.total, "egg_hatch") then
					return failure("NotEnough", plan.egg)
				end
			end
		end
		local committed, result = pcall(PetLogic.commitHatch, profile, plan, slots)
		if not committed then
			PetLogic.refund(profile, plan)
			table.insert(fields, if PetLogic.worldWallet(plan.currency) ~= nil then "worldCash" else "cash")
			PlayerDataService.markChanged(player, true, fields)
			error(result, 0)
		end
		PlayerDataService.markChanged(player, true, fields)
		local auto = rawAuto == true and MonetizationService.ownsPass(player, EggConfig.AutoPass)
		return {
			ok = true,
			code = "Ok",
			egg = plan.egg.id,
			count = plan.count,
			pets = result,
			price = plan.total,
			currency = plan.currency,
			fromHeld = plan.fromHeld,
			pityLeft = EggConfig.pityLeft(plan.egg, plan.pityAfter),
			auto = auto,
			granted = false,
			message = nil,
		}
	end)
	memory:finish(player)

	local payload: HatchPayload
	if ok then
		payload = outcome
	else
		warn(`[PetService] hatch errored: {outcome}`)
		payload = failure("Error", egg)
	end
	if player.Parent == Players then
		memory:remember(player, requestId, payload)
	end
	send(player, requestId, payload)

	-- Side effects outside the pcall: they can never turn a charged hatch into "Error".
	if payload.ok then
		local anyEquipped = false
		local rows: { { petId: string, rarity: string } } = {}
		for _, pet in payload.pets do
			anyEquipped = anyEquipped or pet.equipped
			table.insert(rows, { petId = pet.petId, rarity = pet.rarity })
		end
		if anyEquipped then
			PetService.refresh(player)
		end
		PetSeams.eggHatched(player, payload.egg, rows, payload.auto)
		ProgressEvents.progress(player, "hatch", #payload.pets) -- R78 Quests / Pass: eggs hatched
		for _, pet in payload.pets do
			PetService.Hatched:Fire(player, payload.egg, pet.petId)
		end
	else
		trackRefusal(player, payload.code)
	end
	return payload
end

--------------------------------------------------------------------------------------------------
-- Equip / Equip Best / delete / lock
--------------------------------------------------------------------------------------------------

-- Common gate of the inventory actions: rate limit + a saveable, loaded profile.
local function actionProfile(player: Player): any
	if not actionLimiter:Allow(player.UserId) then
		return nil
	end
	if not PlayerDataService.canMutate(player) then
		return nil
	end
	return PlayerDataService.getProfile(player)
end

--[[ EquipPet(uid, on). @return the PetLogic code ("Ok" | "BadPet" | "NoSlot" | "Same") or nil ]]
function PetService.handleEquip(player: Player, rawUid: unknown, rawOn: unknown): string?
	local uid = Validate.key(rawUid, 16)
	local on = Validate.boolean(rawOn)
	if uid == nil or on == nil then
		return nil
	end
	local profile = actionProfile(player)
	if profile == nil then
		return nil
	end
	local code = PetLogic.setEquipped(profile, uid, on, PetService.slotsFor(player, profile))
	if code == "Ok" then
		PlayerDataService.markChanged(player, false, { "pets" })
		PetService.refresh(player)
		if on then
			PetSeams.analytics("pets", player, "equip")
		end
	elseif code == "NoSlot" then
		PlayerDataService.notify(player, "All pet slots are full! Unequip one first.", "error")
	end
	return code
end

--[[ EquipBest(). @return true when the equipped set changed ]]
function PetService.handleEquipBest(player: Player): boolean
	local profile = actionProfile(player)
	if profile == nil then
		return false
	end
	local changed = PetLogic.equipBest(profile, PetService.slotsFor(player, profile))
	if changed then
		PlayerDataService.markChanged(player, false, { "pets" })
		PetService.refresh(player)
	end
	PetSeams.analytics("pets", player, "equipBest")
	return changed
end

--[[ DeletePets({uid}). @return how many were deleted ]]
function PetService.handleDelete(player: Player, rawUids: unknown): number
	local uids = Validate.stringArray(rawUids, Tunables.MaxBatch, 16)
	if uids == nil or #uids == 0 then
		return 0
	end
	local profile = actionProfile(player)
	if profile == nil then
		return 0
	end
	local equippedBefore = #PetState.pets(profile).equipped
	local deleted, lockedSkipped = PetLogic.deletePets(profile, uids)
	if #deleted > 0 then
		-- Deleting is irreversible: save soon.
		PlayerDataService.markChanged(player, true, { "pets" })
		if #PetState.pets(profile).equipped ~= equippedBefore then
			PetService.refresh(player)
		end
		PetSeams.analytics("pets", player, "delete", #deleted)
	end
	if lockedSkipped > 0 then
		PlayerDataService.notify(
			player,
			`{lockedSkipped} locked pet{if lockedSkipped == 1 then " was" else "s were"} kept.`,
			"info"
		)
	end
	return #deleted
end

--[[ LockPets({uid}, locked). @return how many changed ]]
function PetService.handleLock(player: Player, rawUids: unknown, rawLocked: unknown): number
	local uids = Validate.stringArray(rawUids, Tunables.MaxBatch, 16)
	local locked = Validate.boolean(rawLocked)
	if uids == nil or locked == nil or #uids == 0 then
		return 0
	end
	local profile = actionProfile(player)
	if profile == nil then
		return 0
	end
	local changed = PetLogic.lockPets(profile, uids, locked)
	if changed > 0 then
		PlayerDataService.markChanged(player, false, { "pets" })
	end
	return changed
end

--------------------------------------------------------------------------------------------------
-- Pet Index milestone rewards (owner R78, spec 2026-10-31-r78 §5; Shared/Config/PetIndexConfig)
--------------------------------------------------------------------------------------------------

-- Counts a refused Index claim (pets "index:refused:<reason>", AnalyticsConfig allowlist).
local function indexRefused(player: Player, reason: string)
	PetSeams.analytics("pets", player, `index:refused:{reason}`)
end

--[[
	PetIndexClaim(milestone) handler: claims Pet Index milestone `rawPosition` (untrusted: a whole
	number 1..PetIndexConfig.Count) and pays its gems + permanent Index Bonus.
	Order (no yield anywhere, so the claim mark and the payment are ONE step):
		rate limit (token bucket per UserId) → typed position → profile loaded + writable →
		reward granter present → PetIndexLogic.claim (idempotent: "claimed" / "locked" change
		nothing) → RewardGrant.grant({ gems }) with pets marked changed + save soon → the "pets"
		modifier provider re-reads the bonus (invalidate) → analytics + a reward toast.
	The client re-renders from the profile push (pets.indexClaimed + gems); there is no reply remote.
	@return true when the milestone was claimed and paid
	Example: PetService.handleIndexClaim(player, 1) --> true (25 gems, +2 % cash)
]]
function PetService.handleIndexClaim(player: Player, rawPosition: unknown): boolean
	if not indexLimiter:Allow(player.UserId) then
		indexRefused(player, "rate")
		return false
	end
	local position = Validate.integer(rawPosition, 1, PetIndexConfig.Count)
	if position == nil then
		indexRefused(player, "bad")
		return false
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) then
		indexRefused(player, "save")
		PlayerDataService.notify(player, "Your save is still loading - try again in a moment.", "info", "Pets")
		return false
	end
	local grant = PetSeams.rewardGrant()
	if grant == nil then
		indexRefused(player, "other")
		PlayerDataService.notify(player, "Index rewards are not ready yet - try again soon!", "info", "Pets")
		return false
	end
	local code, milestone = PetIndexLogic.claim(profile, position)
	if code == "claimed" then
		indexRefused(player, "claimed")
		PlayerDataService.notify(player, "You already claimed this Index reward!", "info", "Pets")
		return false
	elseif code ~= "ok" or milestone == nil then
		indexRefused(player, if code == "locked" then "locked" else "bad")
		local target = PetIndexConfig.get(position)
		local missing = if target ~= nil
			then math.max(0, target.need - PetIndexConfig.discovered(PetState.pets(profile).index))
			else 0
		PlayerDataService.notify(player, `Discover {missing} more pets to unlock this reward!`, "info", "Pets")
		return false
	end
	-- Same step: pay the gems (RewardGrant marks gems + pets changed, saves soon, reports the
	-- gems to the economy analytics as reason "petIndex").
	grant(
		player,
		PetIndexLogic.rewardOf(milestone),
		PetIndexConfig.Reason,
		{ saveSoon = true, extraFields = { "pets" } }
	)
	PetSeams.invalidateModifiers(player) -- the Index Bonus (petCash) just grew
	PetSeams.analytics("pets", player, `index:claim:{milestone.id}`)
	PetSeams.analytics("pets", player, "index:gems", milestone.gems)
	PlayerDataService.notify(
		player,
		`Pet Index reward! +{milestone.gems} Gems and +{milestone.bonusPct}% cash forever!`,
		"reward",
		"Gems"
	)
	print(`[PetService] {player.UserId} claimed Pet Index milestone {milestone.id}`)
	return true
end

--------------------------------------------------------------------------------------------------
-- Grants (other systems, admin)
--------------------------------------------------------------------------------------------------

--[[
	Grants one pet to an online player (group reward, Gobble Bomb, admin). Ignores the soft
	inventory cap (a reward is never lost; the hard cap still applies), auto-equips into a free
	slot, saves soon, refreshes the bonus and plays the reveal (HatchResult id 0). Never yields.
	@param reason analytics-safe label (unused for counting today; kept for logs)
	@return (true, uid) or (false, nil) — unknown pet, profile not saveable, hard cap
	Example: PetService.grantPet(player, "gobble_bomb", "event_sheet") --> true, "41"
]]
function PetService.grantPet(player: Player, petId: string, reason: string): (boolean, string?)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) then
		return false, nil
	end
	local uid, isNew = PetLogic.grantPet(profile, petId, false)
	if uid == nil then
		return false, nil
	end
	local def = PetConfig.get(petId) :: PetConfig.PetDef
	local equipped = PetLogic.setEquipped(profile, uid, true, PetService.slotsFor(player, profile)) == "Ok"
	PlayerDataService.markChanged(player, true, { "pets" })
	if equipped then
		PetService.refresh(player)
	end
	send(player, 0, {
		ok = true,
		code = "Granted",
		egg = "",
		count = 1,
		pets = {
			{
				uid = uid,
				petId = def.id,
				rarity = def.rarity,
				slot = 0,
				pityForced = false,
				isNew = isNew,
				equipped = equipped,
			},
		},
		price = 0,
		currency = "held",
		fromHeld = 0,
		pityLeft = nil,
		auto = false,
		granted = true,
		message = nil,
	})
	print(`[PetService] {player.UserId} granted {def.id} ({reason})`)
	return true, uid
end

--[[
	Grants `count` held eggs to an online player (admin / rewards). Saves soon.
	@return true when granted
	Example: PetService.grantEgg(player, "lucky_egg", 3, "admin")
]]
function PetService.grantEgg(player: Player, eggId: string, count: number, reason: string): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil or not PlayerDataService.canMutate(player) then
		return false
	end
	if not PetLogic.grantEgg(profile, eggId, count) then
		return false
	end
	PlayerDataService.markChanged(player, true, { "pets" })
	local egg = EggConfig.get(eggId)
	PlayerDataService.notify(
		player,
		`+{count} {if egg ~= nil then egg.name else eggId}! Hatch it from your Pets menu.`,
		"reward",
		"Pets"
	)
	print(`[PetService] {player.UserId} +{count} {eggId} ({reason})`)
	return true
end

--[[ Studio tests: swap the server RNG (returns a restore function). ]]
function PetService.useRandomForTests(random: PetLogic.RandomLike?): () -> ()
	local previous = rng
	rng = random or Random.new()
	return function()
		rng = previous
	end
end

--------------------------------------------------------------------------------------------------
-- Admin (B14)
--------------------------------------------------------------------------------------------------

-- Display names of a config id list (enum labels).
local function labelsOf(ids: { string }, nameOf: (string) -> string): { string }
	local labels: { string } = {}
	for _, id in ids do
		table.insert(labels, nameOf(id))
	end
	return labels
end

-- The admin commands, registered together (PetSeams retries while AdminService is not up yet).
local function registerAdmin()
	local entries: { PetSeams.AdminEntry } = {}
	local function adminCommand(def: { [string]: any }, handler: (ctx: any) -> (boolean, string))
		table.insert(entries, { def = def, handler = handler })
	end
	local petLabels = labelsOf(PetConfig.Order, function(id: string): string
		local def = PetConfig.Pets[id]
		return `{def.name} ({def.rarity})`
	end)
	adminCommand({
		name = "GivePet",
		tab = "Players",
		label = "Give Pet",
		description = "Adds pets to the player's inventory (ignores the backpack limit).",
		target = "Player",
		args = {
			pet = { kind = "enum", values = PetConfig.Order, labels = petLabels, label = "Pet" },
			count = {
				kind = "integer",
				min = 1,
				max = 20,
				label = "Count",
				presets = { 1, 5, 10 },
				format = "count",
				default = 1,
			},
		},
		argOrder = { "pet", "count" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "purple",
		order = 60,
	}, function(ctx: any): (boolean, string)
		local target = ctx.target.player
		if target == nil then
			return false, "Player not in this server"
		end
		local given = 0
		for _ = 1, ctx.args.count do
			if PetService.grantPet(target, ctx.args.pet, "admin") then
				given += 1
			end
		end
		return given > 0, `Gave {given}x {ctx.args.pet}`
	end)
	adminCommand({
		name = "GiveEgg",
		tab = "Players",
		label = "Give Egg",
		description = "Adds held eggs (hatch for free from the Pets menu).",
		target = "Player",
		args = {
			egg = {
				kind = "enum",
				values = EggConfig.Order,
				labels = labelsOf(EggConfig.Order, function(id: string): string
					return EggConfig.Eggs[id].name
				end),
				label = "Egg",
			},
			count = {
				kind = "integer",
				min = 1,
				max = 100,
				label = "Count",
				presets = { 1, 10, 50 },
				format = "count",
				default = 1,
			},
		},
		argOrder = { "egg", "count" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "purple",
		order = 61,
	}, function(ctx: any): (boolean, string)
		local target = ctx.target.player
		if target == nil then
			return false, "Player not in this server"
		end
		local ok = PetService.grantEgg(target, ctx.args.egg, ctx.args.count, "admin")
		return ok, if ok then `Gave {ctx.args.count}x {ctx.args.egg}` else "Could not give eggs"
	end)
	adminCommand({
		name = "ClearPets",
		tab = "Players",
		label = "Clear Pets",
		description = "Deletes EVERY pet of the player (locked ones too) and their held eggs.",
		target = "Player",
		args = {},
		cooldown = 3,
		audited = true,
		confirm = true,
		color = "red",
		order = 62,
	}, function(ctx: any): (boolean, string)
		local target = ctx.target.player
		local profile = if target ~= nil then PlayerDataService.getProfile(target) else nil
		if target == nil or profile == nil or not PlayerDataService.canMutate(target) then
			return false, "Player not loaded"
		end
		local pets = PetState.pets(profile)
		local removed = PetState.ownedCount(profile)
		table.clear(pets.owned)
		table.clear(pets.equipped)
		table.clear(pets.eggs)
		PlayerDataService.markChanged(target, true, { "pets" })
		PetService.refresh(target)
		return true, `Removed {removed} pets`
	end)

	-- R78 Pet Index rewards: view a player's standing, grant / clear one milestone (audited).
	local milestoneIds: { string } = {}
	local milestoneLabels: { string } = {}
	for _, milestone in PetIndexConfig.Milestones do
		table.insert(milestoneIds, milestone.id)
		table.insert(milestoneLabels, `{milestone.label} pets ({milestone.gems} gems, +{milestone.bonusPct}%)`)
	end
	-- An online, writable target's profile (nil + message otherwise).
	local function indexTarget(ctx: any): (Player?, any, string?)
		local target = ctx.target.player
		local profile = if target ~= nil then PlayerDataService.getProfile(target) else nil
		if target == nil or profile == nil or not PlayerDataService.canMutate(target) then
			return nil, nil, "Player not loaded"
		end
		return target, profile, nil
	end
	adminCommand({
		name = "PetIndexView",
		tab = "Players",
		label = "Pet Index",
		description = "Shows the player's Pet Index: pets discovered, milestones claimed / ready, Index Bonus.",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = false,
		confirm = false,
		color = "purple",
		order = 63,
	}, function(ctx: any): (boolean, string)
		local _target, profile, problem = indexTarget(ctx)
		if profile == nil then
			return false, problem or "Player not loaded"
		end
		local status = PetIndexLogic.status(profile)
		local claimed: { string } = {}
		for _, milestone in PetIndexConfig.Milestones do
			if PetIndexConfig.isClaimed(PetState.pets(profile).indexClaimed, milestone) then
				table.insert(claimed, milestone.label)
			end
		end
		return true,
			`Discovered {status.found} / {status.total}; claimed {if #claimed > 0
				then table.concat(claimed, ", ")
				else "none"}; ready {status.ready}; Index Bonus {PetIndexConfig.formatBonus(status.bonus)}`
	end)
	adminCommand({
		name = "PetIndexGrant",
		tab = "Players",
		label = "Grant Index Reward",
		description = "Marks one Pet Index milestone claimed and pays its gems + Index Bonus (ignores the pets needed).",
		target = "Player",
		args = {
			milestone = { kind = "enum", values = milestoneIds, labels = milestoneLabels, label = "Milestone" },
		},
		argOrder = { "milestone" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "purple",
		order = 64,
	}, function(ctx: any): (boolean, string)
		local target, profile, problem = indexTarget(ctx)
		local milestone = PetIndexConfig.ById[ctx.args.milestone]
		if target == nil or profile == nil or milestone == nil then
			return false, problem or "Unknown milestone"
		end
		local grant = PetSeams.rewardGrant()
		if grant == nil then
			return false, "RewardGrant missing"
		end
		if not PetIndexLogic.setClaimed(profile, milestone.id, true) then
			return false, `Milestone {milestone.label} is already claimed`
		end
		-- Same no-yield step as a player claim: mark + pay, then refresh the bonus.
		grant(
			target,
			PetIndexLogic.rewardOf(milestone),
			PetIndexConfig.Reason,
			{ saveSoon = true, extraFields = { "pets" } }
		)
		PetSeams.invalidateModifiers(target)
		return true, `Granted Index milestone {milestone.label} (+{milestone.gems} gems, +{milestone.bonusPct}%)`
	end)
	adminCommand({
		name = "PetIndexClear",
		tab = "Players",
		label = "Clear Index Reward",
		description = "Un-claims one Pet Index milestone (its Index Bonus goes away; gems already paid stay).",
		target = "Player",
		args = {
			milestone = { kind = "enum", values = milestoneIds, labels = milestoneLabels, label = "Milestone" },
		},
		argOrder = { "milestone" },
		cooldown = 1,
		audited = true,
		confirm = true,
		color = "red",
		order = 65,
	}, function(ctx: any): (boolean, string)
		local target, profile, problem = indexTarget(ctx)
		local milestone = PetIndexConfig.ById[ctx.args.milestone]
		if target == nil or profile == nil or milestone == nil then
			return false, problem or "Unknown milestone"
		end
		if not PetIndexLogic.setClaimed(profile, milestone.id, false) then
			return false, `Milestone {milestone.label} was not claimed`
		end
		PlayerDataService.markChanged(target, true, { "pets" })
		PetSeams.invalidateModifiers(target)
		return true, `Cleared Index milestone {milestone.label}`
	end)
	PetSeams.registerAdminCommands(entries, 6, 5)
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

-- Profile ready: repair the equipped list against the current slots, then replicate.
local function onLoaded(player: Player, profile: any)
	if PetLogic.trimEquipped(profile, PetService.slotsFor(player, profile)) and PlayerDataService.canMutate(player) then
		PlayerDataService.markChanged(player, false, { "pets" })
	end
	PetService.refresh(player)
end

function PetService.Init()
	Remotes.onServerEvent(
		"HatchEgg",
		function(player: Player, rawEgg: unknown, rawCount: unknown, rawRequestId: unknown, rawAuto: unknown)
			PetService.handleHatch(player, rawEgg, rawCount, rawRequestId, rawAuto)
		end
	)
	Remotes.onServerEvent("EquipPet", function(player: Player, rawUid: unknown, rawOn: unknown)
		PetService.handleEquip(player, rawUid, rawOn)
	end)
	Remotes.onServerEvent("EquipBest", function(player: Player)
		PetService.handleEquipBest(player)
	end)
	Remotes.onServerEvent("DeletePets", function(player: Player, rawUids: unknown)
		PetService.handleDelete(player, rawUids)
	end)
	Remotes.onServerEvent("LockPets", function(player: Player, rawUids: unknown, rawLocked: unknown)
		PetService.handleLock(player, rawUids, rawLocked)
	end)
	Remotes.onServerEvent("PetIndexClaim", function(player: Player, rawPosition: unknown)
		PetService.handleIndexClaim(player, rawPosition)
	end)
	-- B7 reward items (daily / wheel / codes / group / packs) go through the pets rules.
	PetSeams.registerItemGranter("pet", PetGrants.pet)
	PetSeams.registerItemGranter("egg", PetGrants.egg)
end

function PetService.Start()
	-- Exact analytics key checks for pets ids.
	PetSeams.registerIds("eggId", function(id: string): boolean
		return EggConfig.get(id) ~= nil
	end)
	PetSeams.registerIds("petId", function(id: string): boolean
		return PetConfig.get(id) ~= nil
	end)
	-- petCash = the equipped pets' bonuses + the permanent Pet Index Bonus (R78: claimed
	-- milestones, +30 % max; PetIndexLogic.bonus). Invalidated after equips and Index claims.
	PetSeams.registerModifier("pets", function(_player: Player, profile: any): any
		return { petCash = PetLogic.cashBonus(profile) + PetIndexLogic.bonus(profile) }
	end)

	PlayerDataService.ProfileLoaded:Connect(function(player: Player, profile: any)
		onLoaded(player, profile)
	end)
	MonetizationService.PassChanged:Connect(function(player: Player, passKey: string)
		if passKey == PetConfig.Slots.PassKey then
			local profile = PlayerDataService.getProfile(player)
			if profile ~= nil then
				onLoaded(player, profile)
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		memory:forget(player)
		hatchLimiter:Forget(player.UserId)
		actionLimiter:Forget(player.UserId)
		indexLimiter:Forget(player.UserId)
	end)
	for _, player in Players:GetPlayers() do
		local profile = PlayerDataService.getProfile(player)
		if profile ~= nil then
			onLoaded(player, profile)
		end
	end

	task.spawn(EggStands.build)
	task.defer(registerAdmin)
end

-- Fixed pack pets (Time Traveler Pack, R57) run the live grant path above (PetGrants.grantFixed).
-- Registered at load, so a receipt that arrives before Start still grants.
PetGrants.useLive(PetService.grantPet)

return PetService
