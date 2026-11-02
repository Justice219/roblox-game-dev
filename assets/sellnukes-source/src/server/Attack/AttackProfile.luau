--!strict
--[[
	AttackProfile — typed, nil-safe access to `profile.attack` for the attack services.

	Schema (build plan "Profile schema v1" + B10's addition):
		attack = {
			aa = 0,            -- stored AA level (0 = never upgraded; the pad counts as level 1)
			launcher = 0,      -- stored Launcher level (set to 1 when the Attack Console is owned;
			                   --   the HUD shows the Attack button while it is > 0)
			shieldUntil = 0,   -- server time the shield ends (whole seconds)
			cooldownUntil = 0, -- server time the next normal launch is allowed (whole seconds)
			hitsTaken = 0,     -- hits since the last free shield, capped at FreeShieldHits
			barrage = 0,       -- stored Barrage nukes (whole, 0..BarrageStorageLimit; ProfileLogic
			                   --   reconciles it to LIMITS.MaxItemCount, the same 1e6 bound).
			                   --   Prompts stop at MaxStoredBarrage; receipts are never clamped.
			golden = 0,        -- owner R85: stored golden revenge nuke charges (addGolden never clamps)
			towers = {},       -- owner R80: stored level per defence tower slot (dense list, index =
			                   --   AttackConfig.Towers slot, 0 = not bought). Gameplay only ever
			                   --   RAISES an entry (buy / upgrade); Rebirth keeps it.
		}

	Why a helper: every write must keep the numbers whole and bounded whatever a stored profile
	contains, and a paid Barrage pack must be added whole or not at all (addBarrage).

	Example:
		local stored = AttackProfile.barrage(profile)
		local added, total = AttackProfile.addBarrage(profile, 20)   -- receipt grant
		AttackProfile.setBarrage(profile, stored - 20)               -- a barrage launch
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local DefenseTowers = require(ReplicatedStorage.Shared.Attack.DefenseTowers)

local AttackProfile = {}

-- A finite number, else `fallback`.
local function num(value: unknown, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

--[[ The profile's attack table, or nil when the profile is malformed. ]]
function AttackProfile.of(profile: any): { [string]: any }?
	if type(profile) ~= "table" or type(profile.attack) ~= "table" then
		return nil
	end
	return profile.attack
end

--[[ Stored Barrage nukes (missing / invalid → 0). ]]
function AttackProfile.barrage(profile: any): number
	local attack = AttackProfile.of(profile)
	if attack == nil then
		return 0
	end
	return math.clamp(math.floor(num(attack.barrage, 0)), 0, AttackConfig.BarrageStorageLimit)
end

--[[
	Sets stored Barrage nukes (whole, clamped to [0, BarrageStorageLimit] — the storage bound, never
	the purchase threshold MaxStoredBarrage: paid nukes above it are kept).
]]
function AttackProfile.setBarrage(profile: any, value: number)
	local attack = AttackProfile.of(profile)
	if attack ~= nil then
		attack.barrage = math.clamp(math.floor(num(value, 0)), 0, AttackConfig.BarrageStorageLimit)
	end
end

--[[
	Adds a granted Barrage pack WITHOUT clamping it away (security audit, Q2 2026-10-30: a receipt
	must never silently lose paid nukes). All or nothing: when the whole pack does not fit under
	BarrageStorageLimit, nothing changes and false is returned, so the receipt handler reports
	NotProcessedYet and Roblox never completes a purchase that could not be stored.
	@param profile any
	@param nukes number — whole, >= 1
	@return (boolean, number) — added?, the stored total afterwards
	Example: AttackProfile.addBarrage(profile, 20) --> true, 2010   (from 1990: nothing lost)
]]
function AttackProfile.addBarrage(profile: any, nukes: number): (boolean, number)
	local attack = AttackProfile.of(profile)
	local count = math.floor(num(nukes, 0))
	local stored = AttackProfile.barrage(profile)
	if attack == nil or count < 1 or stored + count > AttackConfig.BarrageStorageLimit then
		return false, stored
	end
	attack.barrage = stored + count
	return true, stored + count
end

--[[ A numeric attack field (aa / launcher / shieldUntil / cooldownUntil / hitsTaken), 0 if bad. ]]
function AttackProfile.get(profile: any, field: string): number
	local attack = AttackProfile.of(profile)
	if attack == nil then
		return 0
	end
	return math.max(num(attack[field], 0), 0)
end

--[[ Sets a numeric attack field to a whole, non-negative value. ]]
function AttackProfile.set(profile: any, field: string, value: number)
	local attack = AttackProfile.of(profile)
	if attack ~= nil then
		attack[field] = math.max(math.floor(num(value, 0)), 0)
	end
end

--[[ Owner R85: stored golden revenge nuke charges (missing / invalid → 0). ]]
function AttackProfile.golden(profile: any): number
	local attack = AttackProfile.of(profile)
	if attack == nil then
		return 0
	end
	return math.clamp(math.floor(num(attack.golden, 0)), 0, AttackConfig.BarrageStorageLimit)
end

--[[
	Owner R85: adds granted golden charges WITHOUT clamping them away (a receipt must never lose a
	paid nuke). All or nothing: past the storage bound nothing changes and false is returned, so the
	receipt handler reports NotProcessedYet.
	@return (boolean, number) — added?, the stored total afterwards
	Example: AttackProfile.addGolden(profile, 1) --> true, 1
]]
function AttackProfile.addGolden(profile: any, count: number): (boolean, number)
	local attack = AttackProfile.of(profile)
	local amount = math.floor(num(count, 0))
	local stored = AttackProfile.golden(profile)
	if attack == nil or amount < 1 or stored + amount > AttackConfig.BarrageStorageLimit then
		return false, stored
	end
	attack.golden = stored + amount
	return true, stored + amount
end

--[[ Owner R85: sets stored golden charges (whole, clamped to [0, BarrageStorageLimit]). ]]
function AttackProfile.setGolden(profile: any, value: number)
	local attack = AttackProfile.of(profile)
	if attack ~= nil then
		attack.golden = math.clamp(math.floor(num(value, 0)), 0, AttackConfig.BarrageStorageLimit)
	end
end

--[[
	Owner R80: the stored defence tower levels as a sanitised dense copy (exactly
	DefenseTowers.count() entries, whole, 0..MaxLevel). Never the live table.
	Example: AttackProfile.towers(profile) --> { 2, 0, 1, 0 }
]]
function AttackProfile.towers(profile: any): { number }
	local attack = AttackProfile.of(profile)
	return DefenseTowers.normalize(if attack ~= nil then attack.towers else nil)
end

--[[
	Owner R80: writes the stored level of defence tower slot `index` (whole, clamped 0..MaxLevel),
	keeping profile.attack.towers DENSE (missing entries before it are filled with 0, so the saved
	array never has holes). Gameplay only raises levels; admin tools may set any value.
	@param profile any
	@param index number — 1..DefenseTowers.count() (anything else is ignored)
	@param level number
	@return boolean — true when written
]]
function AttackProfile.setTowerLevel(profile: any, index: number, level: number): boolean
	local attack = AttackProfile.of(profile)
	local slot = DefenseTowers.validSlot(index)
	if attack == nil or slot == nil then
		return false
	end
	local list = attack.towers
	if type(list) ~= "table" then
		list = {}
		attack.towers = list
	end
	for fill = 1, slot - 1 do
		if type(list[fill]) ~= "number" then
			list[fill] = 0
		end
	end
	list[slot] = math.clamp(math.floor(num(level, 0)), 0, AttackConfig.MaxLevel)
	return true
end

return AttackProfile
