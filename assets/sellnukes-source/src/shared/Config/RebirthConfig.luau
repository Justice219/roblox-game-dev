--!strict
--[[
	RebirthConfig — tunables for Rebirth (spec §2.5) and the Rebirth Token shop.

	Purpose
		After the finale pad (Area 10 "Golden Atom Statue") a player may rebirth: cash, producer
		levels and pads reset; pets, gems, passes and cosmetics stay. Each rebirth adds a
		permanent cash bonus and pays Rebirth Tokens, spent in the Rebirth shop on permanent
		upgrades (click power, manager speed, offline time / rate, pet slots, starting cash,
		rebirth power).

	Formulas (implemented in Shared/Tycoon/Modifiers + Shared/Tycoon/TycoonLogic)
		rebirthMultiplier = 1 + (BonusPerRebirth + rebirthPower.perLevel * rebirthPowerLevel) * rebirths
			-> additive stacking: 1 rebirth = x1.5, 2 = x2.0, 10 = x6.0 (no rebirth power)
		tokens = floor((Tokens.Base + totalProducerLevels / Tokens.LevelsPerToken)
		               * (1 + Tokens.GrowthPerRebirth * rebirthsSoFar))
			-> rewards both finishing (Base) and over-levelling before rebirthing (levels term),
			   and later rebirths pay a little more so the shop stays reachable.
		shop cost of level L -> L+1 = ceil(baseCost * costGrowth^L) tokens

	Connections
		* Worlds framework: this module is Nuke Town's `RebirthDef`; `RebirthConfig.validate` checks
		  every world's track (Dino Valley: `Worlds/Dino/DinoRebirth`, the Amber shop).
		* `Shared/Tycoon/Modifiers` reads `BonusPerRebirth`, `Shop.clickPower`, `Shop.managerSpeed`,
		  `Shop.rebirthPower` to build the global multipliers.
		* `Shared/Tycoon/TycoonLogic` reads `Tokens`, `Shop` (costs, offline, starting cash).
		* Server (B5 RebirthService) validates `RebirthShopBuy(upgradeKey)` against `Shop`.
		* Client (Rebirth screen) lists `ShopOrder` with `name` / `blurb` / costs.
		* Pets (B9) read `Shop.petSlots` via `TycoonLogic.rebirthShopEffect("petSlots", level)`.

	Retuning: see docs/economy.md ("Rebirth").
]]

local TycoonTypes = require(script.Parent.Parent.Tycoon.TycoonTypes)

-- One Rebirth shop upgrade. `perLevel` effects are additive per level; `values` (startingCash)
-- are explicit per-level amounts (values[L] = effect at level L). Defined in TycoonTypes.
export type ShopUpgrade = TycoonTypes.ShopUpgrade

--[[
	One world's rebirth track: { BonusPerRebirth, MaxRebirths, Tokens, Shop, ShopOrder }.
	RebirthConfig itself is Nuke Town's RebirthDef; Dino Valley's is Worlds/Dino/DinoRebirth.
	`Modifiers` / `TycoonLogic.bind` take one of these per world (World 2 plan §3.1).
]]
export type RebirthDef = TycoonTypes.RebirthDef

local RebirthConfig = {}

-- Permanent cash bonus per rebirth, additive (+50 % each, spec §2.5).
RebirthConfig.BonusPerRebirth = 0.5

-- Hard ceiling on the rebirth count the maths will honour (corrupted-save guard, not a design cap).
RebirthConfig.MaxRebirths = 100000

-- Rebirth Token reward (see header formula).
RebirthConfig.Tokens = {
	Base = 20, -- paid for reaching the finale at all
	LevelsPerToken = 25, -- +1 token per this many producer levels owned at rebirth time
	GrowthPerRebirth = 0.1, -- +10 % tokens per previous rebirth
}

--[[
	Shop upgrades, keyed by the stable upgrade key stored in profile.rebirthShop[key] = level.
	Keys are SAVE DATA: never rename. Effects:
	* clickPower   — "Power Production": every cycle (clicked or automated) pays +perLevel (0.1 =
	                 +10 %) per level. Key kept from the original "click power" design (save data);
	                 it applies to automated cycles too so buying a Manager never lowers $/cycle.
	* managerSpeed — automated producers run +perLevel (10 %) faster per level.
	* offlineHours — offline earnings cap +perLevel hours per level (base 3 h -> 24 h at max).
	* offlineRate  — offline earnings rate +perLevel per level (base 50 % -> 100 % at max).
	* petSlots     — +1 pet equip slot per level.
	* startingCash — each run starts with values[level] cash.
	* rebirthPower — every rebirth is worth +perLevel more cash bonus (0.5 -> 0.55 per rebirth ...).
]]
local SHOP: { [string]: ShopUpgrade } = {
	clickPower = {
		key = "clickPower",
		name = "Power Production",
		blurb = "+10% cash from every producer",
		maxLevel = 10,
		baseCost = 3,
		costGrowth = 1.45,
		perLevel = 0.1,
	},
	managerSpeed = {
		key = "managerSpeed",
		name = "Speedy Managers",
		blurb = "Managers work 10% faster",
		maxLevel = 10,
		baseCost = 3,
		costGrowth = 1.5,
		perLevel = 0.1,
	},
	offlineHours = {
		key = "offlineHours",
		name = "Night Shift",
		blurb = "+1.5 h offline earnings time",
		maxLevel = 14,
		baseCost = 2,
		costGrowth = 1.35,
		perLevel = 1.5,
	},
	offlineRate = {
		key = "offlineRate",
		name = "Sleepy Reactor",
		blurb = "+5% offline earnings rate",
		maxLevel = 10,
		baseCost = 2,
		costGrowth = 1.4,
		perLevel = 0.05,
	},
	petSlots = {
		key = "petSlots",
		name = "Pet Backpack",
		blurb = "+1 pet slot",
		maxLevel = 2,
		baseCost = 15,
		costGrowth = 3,
		perLevel = 1,
	},
	startingCash = {
		key = "startingCash",
		name = "Head Start",
		blurb = "Start every run with cash",
		maxLevel = 5,
		baseCost = 4,
		costGrowth = 2.2,
		values = { 1e3, 2.5e5, 5e7, 1e10, 2.5e12 },
	},
	rebirthPower = {
		key = "rebirthPower",
		name = "Golden Atoms",
		blurb = "Every rebirth gives +5% more cash",
		maxLevel = 10,
		baseCost = 5,
		costGrowth = 1.6,
		perLevel = 0.05,
	},
}

RebirthConfig.Shop = SHOP

-- Display / iteration order for the Rebirth screen.
RebirthConfig.ShopOrder = {
	"clickPower",
	"managerSpeed",
	"startingCash",
	"offlineHours",
	"offlineRate",
	"rebirthPower",
	"petSlots",
}

--[[
	Validates and freezes a world's rebirth track (any RebirthDef: this module, DinoRebirth, ...).
	Errors loudly on a config bug: shop keys that do not match their record, non-positive costs,
	perLevel XOR values, one value per level for table upgrades (strictly rising, so a higher level
	is never worth less), ShopOrder listing exactly the shop's keys, finite token tunables.
	@param def RebirthDef — mutated only by freezing
	@param what string — name for error messages ("RebirthConfig", "DinoRebirth")
	@return RebirthDef — the same table
	Example: return RebirthConfig.validate(DinoRebirth, "DinoRebirth")
]]
function RebirthConfig.validate(def: RebirthDef, what: string): RebirthDef
	local function finite(x: any): boolean
		return type(x) == "number" and x == x and x > -math.huge and x < math.huge
	end
	assert(finite(def.BonusPerRebirth) and def.BonusPerRebirth > 0, `{what}: BonusPerRebirth must be > 0`)
	assert(finite(def.MaxRebirths) and def.MaxRebirths >= 1, `{what}: MaxRebirths must be >= 1`)
	local tokens = def.Tokens
	assert(finite(tokens.Base) and tokens.Base >= 1, `{what}: Tokens.Base must be >= 1`)
	assert(finite(tokens.LevelsPerToken) and tokens.LevelsPerToken > 0, `{what}: Tokens.LevelsPerToken must be > 0`)
	assert(finite(tokens.GrowthPerRebirth) and tokens.GrowthPerRebirth >= 0, `{what}: Tokens.GrowthPerRebirth`)
	for key, upgrade in def.Shop do
		assert(upgrade.key == key, `{what}: Shop.{key} has key {upgrade.key}`)
		assert(upgrade.maxLevel >= 1 and upgrade.baseCost > 0 and upgrade.costGrowth >= 1, `{what}: bad {key}`)
		assert((upgrade.perLevel ~= nil) ~= (upgrade.values ~= nil), `{what}: {key} needs perLevel XOR values`)
		local values = upgrade.values
		if values then
			assert(#values == upgrade.maxLevel, `{what}: {key} needs one value per level`)
			for level, value in values do
				assert(finite(value) and value > (values[level - 1] or 0), `{what}: {key} values must rise`)
			end
			if not table.isfrozen(values) then
				table.freeze(values)
			end
		else
			assert(finite(upgrade.perLevel) and (upgrade.perLevel :: number) > 0, `{what}: {key}.perLevel`)
		end
		if not table.isfrozen(upgrade) then
			table.freeze(upgrade)
		end
	end
	local shopKeys = 0
	for _ in def.Shop do
		shopKeys += 1
	end
	assert(#def.ShopOrder == shopKeys, `{what}: ShopOrder must list every shop key once`)
	local seen: { [string]: boolean } = {}
	for _, key in def.ShopOrder do
		assert(def.Shop[key] ~= nil and not seen[key], `{what}: ShopOrder key {key} unknown or repeated`)
		seen[key] = true
	end
	-- Static data: freeze so no system mutates prices at runtime.
	for _, list in { def.Shop, def.ShopOrder, def.Tokens } :: { any } do
		if not table.isfrozen(list) then
			table.freeze(list)
		end
	end
	return def
end

RebirthConfig.validate(RebirthConfig :: any, "RebirthConfig")

return RebirthConfig
