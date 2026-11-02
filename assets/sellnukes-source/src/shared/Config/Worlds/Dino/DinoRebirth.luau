--!strict
--[[
	DinoRebirth — Dino Valley's own rebirth track: +50 % Bones per Dino rebirth, Amber tokens and the
	4-upgrade Amber shop (World 2 spec §6.4). A `RebirthDef` (TycoonTypes), validated and frozen by
	`RebirthConfig.validate`.

	Rules (server: RebirthService with worldId "dino")
		* Requirement: own `d6_golden_trex` (the Dino finale, feature "Rebirth"); the session saves.
		* Reward: Amber = floor((Tokens.Base 10 + totalLevels / 25) * (1 + 0.1 * dinoRebirthsSoFar)),
		  rebirths += 1, Bones multiplier = 1 + (0.5 + 0.05 * Golden Amber level) * dinoRebirths.
		* Resets worlds.dino.tycoon and worlds.dino.cash (set to the Bone Stash start); keeps Dino
		  rebirths, Amber, the Amber shop and everything outside worlds.dino. A Nuke Town rebirth never
		  touches worlds.dino and vice versa.

	Amber shop — keys are SAVE DATA (worlds.dino.rebirthShop[key] = level) and reuse the Nuke Town key
	names so `Modifiers` resolves them per track (clickPower = production, managerSpeed, startingCash,
	rebirthPower). Offline cap / rate stay player-level (Nuke Town's Night Shift / Sleepy Reactor).
		key           name            effect / level                                  max  cost (Amber)
		clickPower    Mighty Roar     +10 % Bones on every cycle (clicked + automated)  10   3 x 1.45^L
		managerSpeed  Speedy Raptors  +10 % automated speed                              10   3 x 1.5^L
		startingCash  Bone Stash      start each Dino run with Bones (4 values)           4   4 x 2.2^L
		rebirthPower  Golden Amber    +5 % per-Dino-rebirth bonus                        10   5 x 1.6^L

	Bone Stash values are sim-tuned to the Bones that open D2 / D3 / D4 / D5 (each area's Unlock
	pad price): `lune run tests/economy-sim.luau --world dino --tune --write` rewrites the
	`STASH_VALUES` line below together with the area SCALEs.

	Connections
		* `Shared/Config/Worlds/Dino/DinoWorld` puts this in the WorldDef (`def.rebirth`).
		* `Shared/Tycoon/TycoonLogic.forWorld("dino")` binds it (rebirthReward, rebirthShopCost,
		  startingCash, rebirthMultiplier); `Shared/Tycoon/Modifiers.resolve(mods, DinoRebirth)`.
		* Client: the Rebirth screen's Dino tab lists `ShopOrder` with `name` / `blurb` / costs.

	Usage
		local DinoRebirth = require(ReplicatedStorage.Shared.Config.Worlds.Dino.DinoRebirth)
		print(DinoRebirth.Shop.startingCash.values[1]) -- Bones a Bone Stash level 1 run starts with
]]

local RebirthConfig = require(script.Parent.Parent.Parent.RebirthConfig)
local TycoonTypes = require(script.Parent.Parent.Parent.Parent.Tycoon.TycoonTypes)

-- Bone Stash: Bones each Dino run starts with at levels 1..4 (≈ the Bones that open D2 / D3 / D4 / D5).
-- Written by the pacing simulator (--world dino --tune --write): keep the name and ONE line.
local STASH_VALUES = { 65000, 5.4e6, 2.1e8, 1.2e10 }

local DinoRebirth: TycoonTypes.RebirthDef = {
	-- Permanent Bones bonus per Dino rebirth, additive (+50 % each).
	BonusPerRebirth = 0.5,
	-- Corrupted-save guard on the rebirth count the maths honours (not a design cap).
	MaxRebirths = 100000,
	-- Amber reward (see header formula): finishing pays Base, over-levelling pays more.
	Tokens = {
		Base = 10,
		LevelsPerToken = 25,
		GrowthPerRebirth = 0.1,
	},
	Shop = {
		clickPower = {
			key = "clickPower",
			name = "Mighty Roar",
			blurb = "+10% Bones from every producer",
			maxLevel = 10,
			baseCost = 3,
			costGrowth = 1.45,
			perLevel = 0.1,
		},
		managerSpeed = {
			key = "managerSpeed",
			name = "Speedy Raptors",
			blurb = "Dino managers work 10% faster",
			maxLevel = 10,
			baseCost = 3,
			costGrowth = 1.5,
			perLevel = 0.1,
		},
		startingCash = {
			key = "startingCash",
			name = "Bone Stash",
			blurb = "Start every Dino run with Bones",
			maxLevel = 4,
			baseCost = 4,
			costGrowth = 2.2,
			values = STASH_VALUES,
		},
		rebirthPower = {
			key = "rebirthPower",
			name = "Golden Amber",
			blurb = "Every Dino rebirth gives +5% more Bones",
			maxLevel = 10,
			baseCost = 5,
			costGrowth = 1.6,
			perLevel = 0.05,
		},
	},
	-- Display / iteration order for the Rebirth screen's Dino tab.
	ShopOrder = { "clickPower", "managerSpeed", "startingCash", "rebirthPower" },
}

-- Validate + freeze the nested tables, then freeze the def itself. (The cast keeps the exported type
-- the plain RebirthDef: solver V2 would otherwise type the frozen table as read-only fields.)
RebirthConfig.validate(DinoRebirth, "DinoRebirth")
table.freeze(DinoRebirth :: any)

return DinoRebirth
