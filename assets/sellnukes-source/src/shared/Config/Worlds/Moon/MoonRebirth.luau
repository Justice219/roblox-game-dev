--!strict
--[[
	MoonRebirth — Moon Base's own rebirth track: +50 % Moon Rocks per Moon rebirth, Star Shards and
	the 4-upgrade Star Shard shop (R69–R71 spec §2.1). A `RebirthDef` (TycoonTypes), validated and
	frozen by `RebirthConfig.validate`. Same curves as Dino Valley's Amber track (DinoRebirth).

	Rules (server: RebirthService with worldId "moon")
		* Requirement: own `m6_golden_astronaut` (the Moon finale, feature "Rebirth"); the session saves.
		* Reward: Star Shards = floor((Tokens.Base 10 + totalLevels / 25) * (1 + 0.1 * moonRebirthsSoFar)),
		  rebirths += 1, Moon Rocks multiplier = 1 + (0.5 + 0.05 * Supernova level) * moonRebirths.
		* Resets worlds.moon.tycoon and worlds.moon.cash (set to the Rock Stash start); keeps Moon
		  rebirths, Star Shards, the shop and everything outside worlds.moon. No other world's rebirth
		  ever touches worlds.moon and vice versa.

	Star Shard shop — keys are SAVE DATA (worlds.moon.rebirthShop[key] = level) and reuse the Nuke Town
	key names so `Modifiers` resolves them per track. Offline cap / rate stay player-level.
		key           name         effect / level                                      max  cost (Star Shards)
		clickPower    Rocket Fuel  +10 % Moon Rocks on every cycle (clicked + automated)  10   3 x 1.45^L
		managerSpeed  Turbo Bots   +10 % automated speed                                  10   3 x 1.5^L
		startingCash  Rock Stash   start each Moon run with Moon Rocks (4 values)          4   4 x 2.2^L
		rebirthPower  Supernova    +5 % per-Moon-rebirth bonus                            10   5 x 1.6^L

	Rock Stash values are sim-tuned to the Moon Rocks that open M2 / M3 / M4 / M5 (each area's Unlock
	pad price): `lune run tests/economy-sim.luau --world moon --tune --write` rewrites the
	`STASH_VALUES` line below together with the area SCALEs.

	Connections
		* `Shared/Config/Worlds/Moon/MoonWorld` puts this in the WorldDef (`def.rebirth`).
		* `Shared/Tycoon/TycoonLogic.forWorld("moon")` binds it; `Modifiers.resolve(mods, MoonRebirth)`.
		* Client: the Rebirth screen's Moon tab lists `ShopOrder` with `name` / `blurb` / costs.

	Usage
		local MoonRebirth = require(ReplicatedStorage.Shared.Config.Worlds.Moon.MoonRebirth)
		print(MoonRebirth.Shop.startingCash.values[1]) -- Moon Rocks a Rock Stash level 1 run starts with
]]

local RebirthConfig = require(script.Parent.Parent.Parent.RebirthConfig)
local TycoonTypes = require(script.Parent.Parent.Parent.Parent.Tycoon.TycoonTypes)

-- Rock Stash: Moon Rocks each Moon run starts with at levels 1..4 (≈ the Moon Rocks that open M2..M5).
-- Written by the pacing simulator (--world moon --tune --write): keep the name and ONE line.
local STASH_VALUES = { 65000, 5.4e6, 2.1e8, 1.2e10 }

local MoonRebirth: TycoonTypes.RebirthDef = {
	-- Permanent Moon Rocks bonus per Moon rebirth, additive (+50 % each).
	BonusPerRebirth = 0.5,
	-- Corrupted-save guard on the rebirth count the maths honours (not a design cap).
	MaxRebirths = 100000,
	-- Star Shard reward (see header formula): finishing pays Base, over-levelling pays more.
	Tokens = {
		Base = 10,
		LevelsPerToken = 25,
		GrowthPerRebirth = 0.1,
	},
	Shop = {
		clickPower = {
			key = "clickPower",
			name = "Rocket Fuel",
			blurb = "+10% Moon Rocks from every producer",
			maxLevel = 10,
			baseCost = 3,
			costGrowth = 1.45,
			perLevel = 0.1,
		},
		managerSpeed = {
			key = "managerSpeed",
			name = "Turbo Bots",
			blurb = "Moon managers work 10% faster",
			maxLevel = 10,
			baseCost = 3,
			costGrowth = 1.5,
			perLevel = 0.1,
		},
		startingCash = {
			key = "startingCash",
			name = "Rock Stash",
			blurb = "Start every Moon run with Moon Rocks",
			maxLevel = 4,
			baseCost = 4,
			costGrowth = 2.2,
			values = STASH_VALUES,
		},
		rebirthPower = {
			key = "rebirthPower",
			name = "Supernova",
			blurb = "Each Moon rebirth: +5% more Moon Rocks",
			maxLevel = 10,
			baseCost = 5,
			costGrowth = 1.6,
			perLevel = 0.05,
		},
	},
	-- Display / iteration order for the Rebirth screen's Moon tab.
	ShopOrder = { "clickPower", "managerSpeed", "startingCash", "rebirthPower" },
}

-- Validate + freeze the nested tables, then freeze the def itself. (The cast keeps the exported type
-- the plain RebirthDef: solver V2 would otherwise type the frozen table as read-only fields.)
RebirthConfig.validate(MoonRebirth, "MoonRebirth")
table.freeze(MoonRebirth :: any)

return MoonRebirth
