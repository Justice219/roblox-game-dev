--!strict
--[[
	PetGrants — the no-yield item granters other systems use to give pets and held eggs straight
	into a profile (B7 RewardLogic "pet" / "egg" rewards: daily, wheel, codes, group, Starter /
	Secret Pack; their signature is RewardLogic.ItemGranter = (profile, id) -> boolean).

	Rules:
		pet  PetLogic.grantPet with the HARD cap only: a reward (often paid or one-time) is never
		     refused for a full soft inventory. Unknown ids → false (the caller pays its fallback).
		egg  one held egg (PetLogic.grantEgg); hatch it anywhere from the Pets screen.
	Both only touch profile.pets; the caller marks the "pets" field changed (RewardLogic's summary
	does) — PetService.ProfileChanged handlers pick the change up on the next push.

	When a player is online, prefer PetService.grantPet / grantEgg (they also refresh the cash
	bonus, the replicated attribute and analytics). These profile granters exist for code that
	only holds a profile (receipt grant steps, RewardLogic.apply).

	Fixed pack pets (owner R57 World 2): grantFixed(player, petId, reason) gives one SPECIFIC pet
	— the Time Traveler Pack's Time Ptero (MonetizationConfig.Products.TimeTravelerPack.pet). It is
	deterministic (never rolled), so the pack is not a paid random item. It runs the live
	PetService.grantPet path (auto-equip into a free slot, the reveal popup, the cash-bonus refresh,
	analytics); PetService registers that granter at load with useLive (PetService requires this
	module, so a direct require back would be a cycle). Only non-egg pets can be fixed grants, so a
	pack can never sell an egg pet outright.

	Connects to: Server/Pets/PetLogic, B7 Server/Retention/RewardLogic (Granters),
	Server/Services/PetService (registers them with B7 when B7 exposes a registration hook).

	Example:
		local PetGrants = require(ServerScriptService.Server.Pets.PetGrants)
		RewardLogic.apply(profile, reward, now, { pet = PetGrants.pet, egg = PetGrants.egg })
		-- Time Traveler Pack receipt step (W3 world-product handler):
		local ok = PetGrants.grantFixed(player, product.pet, "TimeTravelerPack")
		if not ok then return Enum.ProductPurchaseDecision.NotProcessedYet end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetLogic = require(script.Parent.PetLogic)

-- The live granter for online players: PetService.grantPet(player, petId, reason) -> (ok, uid?).
type LiveGranter = (player: Player, petId: string, reason: string) -> (boolean, string?)

local PetGrants = {}

-- Set once by PetService at load (useLive); nil only before PetService loads (or in Lune tests).
local liveGranter: LiveGranter? = nil

--[[
	Grants one pet into `profile` (hard cap only). Never yields.
	Example: PetGrants.pet(profile, "starter_atom_pup") --> true
]]
function PetGrants.pet(profile: any, petId: string): boolean
	local uid = PetLogic.grantPet(profile, petId, false)
	return uid ~= nil
end

--[[
	Grants one held egg into `profile`. Never yields.
	Example: PetGrants.egg(profile, "lucky_egg") --> true
]]
function PetGrants.egg(profile: any, eggId: string): boolean
	return PetLogic.grantEgg(profile, eggId, 1)
end

--[[
	Registers the live granter (PetService calls this once at load). Tests pass a fake.
	Example: PetGrants.useLive(PetService.grantPet)
]]
function PetGrants.useLive(granter: LiveGranter)
	liveGranter = granter
end

--[[
	True when `petId` may be granted as a fixed pack pet: a known pet that does NOT hatch from an
	egg (source ~= "egg"). Pure; used by grantFixed and the tests / config checks.
	Example: PetGrants.isFixedPet("time_ptero") --> true ; PetGrants.isFixedPet("atom_raptor") --> false
]]
function PetGrants.isFixedPet(petId: unknown): boolean
	local def = PetConfig.get(petId)
	return def ~= nil and def.source ~= "egg"
end

--[[
	Grants one FIXED pet to an online player through the live PetService path (auto-equip, reveal,
	analytics, save soon). Never yields. Refuses (false) for an unknown / egg pet, a player that is
	not loaded or whose save cannot be written (PetService.grantPet), or before PetService loaded —
	a receipt handler then answers NotProcessedYet so Roblox retries and Robux are never lost.
	@return ok, the new pet's uid
	Example: PetGrants.grantFixed(player, "time_ptero", "TimeTravelerPack") --> true, "u42"
]]
function PetGrants.grantFixed(player: Player, petId: string, reason: string): (boolean, string?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or not PetGrants.isFixedPet(petId) then
		return false, nil
	end
	local granter = liveGranter
	if granter == nil then
		warn(`[PetGrants] grantFixed({petId}) before PetService loaded`)
		return false, nil
	end
	local ok, granted, uid = pcall(granter, player, petId, if type(reason) == "string" then reason else "pack")
	if not ok then
		warn(`[PetGrants] grantFixed({petId}) failed: {granted}`)
		return false, nil
	end
	return granted == true, if granted == true then uid else nil
end

-- Aliases matching the names announced to B7 (grantPetToProfile / grantEggToProfile).
PetGrants.grantPetToProfile = PetGrants.pet
PetGrants.grantEggToProfile = PetGrants.egg

return table.freeze(PetGrants)
