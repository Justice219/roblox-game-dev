--!strict
--[[
	Modifiers — turns the one `Modifiers` table (pets, passes, boosts, rebirths, server boost,
	event) into the four numbers the producer maths multiplies by.

	Purpose
		Income is boosted by many systems owned by different builders. Instead of every system
		poking the economy, the server builds ONE `TycoonTypes.Modifiers` table per player and
		hands it to TycoonLogic. This module sanitises it (hostile / corrupted values become
		neutral) and resolves it:

			production   = 1 + 0.10 * rebirthShop.clickPower             ("Power Production")
			cash         = (1 + petCash) * cashPass(2) * vip(1.5) * boostCash * serverCash * eventCash
			               * rebirthMultiplier(rebirths, rebirthShop) * production * linkCash
			               * rushCash * friendCash                       (R78)
			speed        = boostSpeed                                    (every producer)
			managerSpeed = 1 + 0.10 * rebirthShop.managerSpeed           (automated producers only)

		Power Production (save key "clickPower") multiplies EVERY cycle, clicked or automated, so
		buying a producer's Manager never lowers the cash per cycle the player sees.

		Categories multiply (a 2x boost doubles whatever pets already give). Every field is a
		bonus: values below 1 (or negative petCash) are clamped to neutral, values above
		TycoonConfig.Modifiers.MaxMultiplier are clamped down.

	Worlds (World 2 plan §3.1)
		Every world has its own rebirth track (`RebirthDef`: Nuke Town = RebirthConfig, Dino Valley
		= Worlds/Dino/DinoRebirth). `resolve`, `rebirthMultiplier`, `shopLevel` and `shopEffect` take
		an optional trailing `rebirth: RebirthDef?` — nil means Nuke Town, so every existing call is
		unchanged. The shop keys a world's def does not have resolve to neutral (a Dino Amber shop
		has no offlineHours). `linkCash` (spec §6.5, WorldsConfig.linkCash) is the cross-world link
		bonus, a plain >= 1 multiplier like the other bonuses (the `link` field shows its share).

	R78 retention boosts
		`rushCash` (Rookie / Comeback Rush) and `friendCash` (Friend Boost) are plain >= 1
		multipliers like `boostCash`, each clamped to its own sane cap from Shared/Config/
		SocialConfig (Rush.MaxMultiplier, Friends.MaxMultiplier, never above MaxMultiplier):
		NaN / inf / <= 1 -> 1. They multiply last, so a neutral rush / friend (1) leaves the product
		bit-identical to the pre-R78 maths (economy tests and the pacing simulator unchanged).

	Connections
		* Tunables: `Shared/Config/TycoonConfig.Modifiers`, `Shared/Config/RebirthConfig`,
		  `Shared/Config/SocialConfig` (R78 rush / friend caps).
		* Used by `Shared/Tycoon/TycoonLogic` (every income function takes `mods`).
		* Built by the server (B5 TycoonService) from the profile, PassOwnership, equipped pets,
		  active boosts, the server boost and EventConfig.

	Usage
		local Modifiers = require(ReplicatedStorage.Shared.Tycoon.Modifiers)
		local resolved = Modifiers.resolve({ vip = true, boostCash = 2, rebirths = 1 })
		print(resolved.cash) --> 1.5 * 2 * 1.5 = 4.5
		local dino = Modifiers.resolve({ rebirths = 2, linkCash = 1.25 }, DinoRebirth)
		print(dino.cash) --> (1 + 0.5 * 2) * 1.25 = 2.5
]]

local RebirthConfig = require(script.Parent.Parent.Config.RebirthConfig)
local SafeMath = require(script.Parent.SafeMath)
local SocialConfig = require(script.Parent.Parent.Config.SocialConfig)
local TycoonConfig = require(script.Parent.Parent.Config.TycoonConfig)
local TycoonTypes = require(script.Parent.TycoonTypes)

type Modifiers = TycoonTypes.Modifiers
type ResolvedModifiers = TycoonTypes.ResolvedModifiers
type RebirthDef = TycoonTypes.RebirthDef

-- Nuke Town's rebirth track: the default whenever a caller passes no RebirthDef.
local MAIN_REBIRTH: RebirthDef = RebirthConfig

local Modifiers = {}

-- Neutral result (no bonuses). Frozen and shared: callers must never mutate a resolved table.
Modifiers.NEUTRAL = table.freeze({
	cash = 1,
	speed = 1,
	managerSpeed = 1,
	production = 1,
	rebirth = 1,
	link = 1,
}) :: ResolvedModifiers

--[[
	The sanitised level of one Rebirth shop upgrade.
	@param shop any — that world's rebirthShop ({[key]: level}); anything else counts as empty
	@param key string — upgrade key (the def's Shop)
	@param rebirth RebirthDef? — the world's rebirth track (nil = Nuke Town's RebirthConfig)
	@return number — integer in [0, maxLevel]; 0 for unknown keys / corrupted levels
	Example: Modifiers.shopLevel({ clickPower = 3 }, "clickPower") --> 3
]]
function Modifiers.shopLevel(shop: any, key: string, rebirth: RebirthDef?): number
	local upgrade = (rebirth or MAIN_REBIRTH).Shop[key]
	if upgrade == nil or type(shop) ~= "table" then
		return 0
	end
	return SafeMath.int(shop[key], 0, upgrade.maxLevel)
end

--[[
	The effect of a Rebirth shop upgrade at a level: `perLevel * level` for additive upgrades,
	`values[level]` for table upgrades (startingCash), 0 at level 0 / unknown keys.
	@param key string — upgrade key
	@param level number — (untrusted) level, clamped to [0, maxLevel]
	@param rebirth RebirthDef? — the world's rebirth track (nil = Nuke Town's RebirthConfig)
	@return number — e.g. 0.2 for clickPower level 2 (= +20 %), 1e3 for startingCash level 1
	Example: Modifiers.shopEffect("offlineHours", 2) --> 3 (extra hours)
]]
function Modifiers.shopEffect(key: string, level: number, rebirth: RebirthDef?): number
	local upgrade = (rebirth or MAIN_REBIRTH).Shop[key]
	if upgrade == nil then
		return 0
	end
	local safeLevel = SafeMath.int(level, 0, upgrade.maxLevel)
	if safeLevel == 0 then
		return 0
	end
	local values = upgrade.values
	if values ~= nil then
		return values[safeLevel] or 0
	end
	return (upgrade.perLevel or 0) * safeLevel
end

--[[
	Permanent cash multiplier from rebirths (spec §2.5: +50 % per rebirth, stacking additively).
	Formula: 1 + (BonusPerRebirth + rebirthPower effect) * rebirths
	@param rebirths any — rebirth count (untrusted; clamped to [0, def.MaxRebirths])
	@param shop any — that world's rebirthShop (reads the rebirthPower level)
	@param rebirth RebirthDef? — the world's rebirth track (nil = Nuke Town's RebirthConfig)
	@return number — >= 1
	Example: Modifiers.rebirthMultiplier(2, nil) --> 2.0; (1, { rebirthPower = 2 }) --> 1.6
]]
function Modifiers.rebirthMultiplier(rebirths: any, shop: any, rebirth: RebirthDef?): number
	local def = rebirth or MAIN_REBIRTH
	local count = SafeMath.int(rebirths, 0, def.MaxRebirths)
	local perRebirth = def.BonusPerRebirth
		+ Modifiers.shopEffect("rebirthPower", Modifiers.shopLevel(shop, "rebirthPower", def), def)
	return 1 + perRebirth * count
end

--[[
	Resolves (and sanitises) a Modifiers table into the multipliers TycoonLogic applies.
	@param mods any — a TycoonTypes.Modifiers table, or nil for "no bonuses"
	@param rebirth RebirthDef? — the rebirth track `mods.rebirths` / `mods.rebirthShop` belong to
	       (nil = Nuke Town's RebirthConfig; TycoonLogic.forWorld(id) passes the world's own)
	@return ResolvedModifiers — every field finite and >= 1
	Example: Modifiers.resolve({ cashPass = true, petCash = 0.5 }).cash --> 3
]]
function Modifiers.resolve(mods: any, rebirth: RebirthDef?): ResolvedModifiers
	if type(mods) ~= "table" then
		return Modifiers.NEUTRAL
	end
	local def = rebirth or MAIN_REBIRTH
	local tunables = TycoonConfig.Modifiers
	local cap = tunables.MaxMultiplier

	local pets = 1 + SafeMath.clamp(mods.petCash, 0, tunables.MaxPetCash, 0)
	local pass = if mods.cashPass == true then tunables.CashPassMultiplier else 1
	local vip = if mods.vip == true then tunables.VipMultiplier else 1
	local boost = SafeMath.bonus(mods.boostCash, cap)
	local server = SafeMath.bonus(mods.serverCash, cap)
	local event = SafeMath.bonus(mods.eventCash, cap)
	local rebirthCash = Modifiers.rebirthMultiplier(mods.rebirths, mods.rebirthShop, def)
	local shop = mods.rebirthShop
	-- "Power Production" (save key clickPower) boosts clicked AND automated cycles alike.
	local production = 1 + Modifiers.shopEffect("clickPower", Modifiers.shopLevel(shop, "clickPower", def), def)
	-- Cross-world link (spec §6.5): >= 1, NaN / inf / below 1 -> 1, above MaxMultiplier -> clamped.
	-- Multiplied last so a neutral link (1) leaves the product bit-identical to the pre-link maths.
	local link = SafeMath.bonus(mods.linkCash, cap)
	-- R78 Rush / Friend Boost: >= 1, each clamped to its own sane cap (a corrupted provider can
	-- never mint more than a 10x rush / +100 % friend bonus). Multiplied last (neutral = identical).
	local rush = SafeMath.bonus(mods.rushCash, math.min(cap, SocialConfig.Rush.MaxMultiplier))
	local friend = SafeMath.bonus(mods.friendCash, math.min(cap, SocialConfig.Friends.MaxMultiplier))

	return {
		cash = pets * pass * vip * boost * server * event * rebirthCash * production * link * rush * friend,
		speed = SafeMath.bonus(mods.boostSpeed, cap),
		managerSpeed = 1 + Modifiers.shopEffect("managerSpeed", Modifiers.shopLevel(shop, "managerSpeed", def), def),
		production = production,
		rebirth = rebirthCash,
		link = link,
	}
end

return Modifiers
