--!strict
--[[
	TycoonTypes — the shared type vocabulary of the SellNukes tycoon economy.

	Purpose
		One place that defines the shapes every tycoon module agrees on: the static config
		(areas, producers, pads), the per-player tycoon state that lives in the profile
		(`profile.tycoon`), and the derived numbers TycoonLogic hands to the server and the UI.
		Types only — this module returns an empty table and has no behaviour.

	Connections
		* `Shared/Config/TycoonConfig` + `Shared/Config/TycoonAreas/AreaNN` build values of
		  `AreaConfig` / `ProducerConfig` / `PadConfig`.
		* `Shared/Tycoon/TycoonLogic` consumes `TycoonState` + `Modifiers` and returns
		  `ProducerStats` / `MilestoneBadge`.
		* `Shared/Tycoon/Modifiers` resolves a `Modifiers` table into `ResolvedModifiers`.
		* `Shared/Tycoon/EconomyIndex` builds an `EconomyIndex` per world from an `EconomySpec`;
		  `RebirthConfig` / `Worlds/<Name>/<Name>Rebirth` are `RebirthDef`s (World 2 plan §3.1).
		This module has NO requires on purpose: config files and logic modules all depend on it,
		so it must never depend on them (that would be a require cycle).
		* Server (B5 TycoonService) stores `TycoonState` inside the profile; the client (B6)
		  renders `ProducerStats` on billboards.

	Usage
		local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)
		type PadConfig = TycoonTypes.PadConfig
]]

--[[
	What a pad does when bought (see spec §2.3):
	* "Build"      — structure / decoration. Gives `value` as a permanent +fraction to the target
	                 producer's cash (0.1 = +10 %). The first pad of every area is a Build pad that
	                 *builds the producer itself* (the producer's `builtBy`), value 0.
	* "Multiplier" — multiplies the target producer's cash by `value` (2, 3, 4, 5).
	* "Speed"      — multiplies the target producer's speed by `value` (always 2 in v1).
	* "Manager"    — automates the target producer (idle + offline income start here).
	* "Unlock"     — opens area `unlocks`; the finale Unlock pad has `feature = "Rebirth"` instead.
	* "Feature"    — unlocks the system named by `feature` ("AATower", "AttackConsole").
]]
export type PadKind = "Build" | "Multiplier" | "Speed" | "Manager" | "Unlock" | "Feature"

--[[
	A system a pad switches on. "StandRename" rides on the Nuke Stand's Neon Sign (a Multiplier
	pad), the attack features ride on their own Feature pads, "Rebirth" on the finale Unlock pad.
]]
export type FeatureKey = "StandRename" | "AATower" | "AttackConsole" | "Rebirth"

--[[
	One buy pad. `id` is SAVE DATA (profile.tycoon.pads[id] = true) — never rename or reuse one.
	`build` is the build-group key the world builders map to Blender meshes (e.g. "A1_ToolWall");
	`blurb` is the one-line billboard text ("x3 Workbench cash").
]]
export type PadConfig = {
	id: string,
	area: number,
	name: string,
	kind: PadKind,
	cost: number,
	requires: string?,
	target: string?,
	value: number?,
	unlocks: number?,
	feature: FeatureKey?,
	build: string,
	blurb: string,
}

--[[
	One producer (one per area). Level 0 = not built yet; the pad `builtBy` sets level 1.
	* `baseCost`   — price of the level 1 -> 2 upgrade; level L -> L+1 costs baseCost * costGrowth^(L-1).
	* `baseRevenue`— cash per cycle at level 1 before any multiplier (output is linear in level).
	* `baseCycle`  — seconds per cycle before speed multipliers (floored at TycoonConfig.CycleFloor).
	* `clickable`  — true: before its Manager the cycle only runs when the player clicks it.
]]
export type ProducerConfig = {
	id: string,
	name: string,
	area: number,
	builtBy: string,
	baseCost: number,
	costGrowth: number,
	baseRevenue: number,
	baseCycle: number,
	clickable: boolean,
}

-- One themed area (spec §3). `pads` are in their fixed linear buy order.
export type AreaConfig = {
	index: number,
	id: string,
	name: string,
	producer: ProducerConfig,
	pads: { PadConfig },
}

--[[
	The per-player tycoon state — exactly the `profile.tycoon` table from the profile schema.
	TycoonLogic only reads `pads` and `producers` (and writes them in `applyPad` / `applyLevels`);
	`area` is the highest unlocked area index (kept in sync by `applyPad`).
]]
export type PadSet = { [string]: true }
export type TycoonState = {
	pads: PadSet,
	producers: { [string]: number },
	area: number,
	standName: string,
	lastSaveAt: number,
	tutorialStep: number,
}

-- The milestone badge on a producer billboard ("x8" with the next milestone level under it).
export type MilestoneBadge = {
	milestones: number, -- milestones reached (level // MilestoneEvery)
	cash: number, -- milestone cash multiplier (power of two)
	speed: number, -- milestone speed multiplier before the cycle floor (power of two)
	nextAt: number?, -- level of the next milestone, nil at MaxLevel
	nextKind: ("Cash" | "Speed")?, -- what the next milestone gives (before floor conversion)
	text: string, -- "x8"
}

-- Everything a producer billboard / the server tick needs, from `TycoonLogic.producerStats`.
export type ProducerStats = {
	id: string,
	level: number,
	built: boolean,
	automated: boolean,
	output: number, -- cash per cycle (automated: what the tick pays; manual: see clickPayout)
	clickPayout: number, -- cash of one manually started cycle (never more than `output` once automated)
	cycle: number, -- seconds per cycle (>= CycleFloor)
	perSecond: number, -- output / cycle when automated, else 0 (manual income is not idle income)
	cashMultiplier: number, -- every cash factor except level (milestones x floor conversion x pads x mods)
	-- (the floor conversion is floor / raw cycle, so it can be fractional: x1.6 when a x16 speed hits 0.1 s)
	speedMultiplier: number, -- effective speed factor (baseCycle / cycle)
	badge: MilestoneBadge,
	nextCost: number, -- cost of the next single level (math.huge at MaxLevel / unbuilt)
}

--[[
	Every global income modifier, in ONE table the server builds per player (B5 TycoonService
	builds it from the profile, pass ownership, pets, boosts, server boost and the live event).
	All fields are optional; a missing field is neutral. Every value is sanitised by
	`Modifiers.resolve` (NaN / inf / negative -> neutral, huge -> clamped), so a corrupted profile
	field can never mint infinite cash. Categories multiply with each other:

		cash = (1 + petCash) * (cashPass and 2) * (vip and 1.5) * boostCash * serverCash
		       * eventCash * rebirthMultiplier(rebirths, rebirthShop) * linkCash * rushCash * friendCash

	`rushCash` (R78 Rookie / Comeback Rush) and `friendCash` (R78 Friend Boost) are timed / presence
	boosts from Server/Services/{RushService, FriendService}; both providers are registered with
	`offline = false`, so they never inflate offline earnings, and reward cash (RewardLogic) never
	reads them.

	`rebirths` / `rebirthShop` are the rebirth track OF THE WORLD being evaluated (Nuke Town:
	profile.rebirths / profile.rebirthShop; Dino Valley: profile.worlds.dino.rebirths / .rebirthShop),
	resolved against that world's RebirthDef (`Modifiers.resolve(mods, def.rebirth)`).
	`linkCash` is the cross-world link bonus for that world (`WorldsConfig.linkCash`, spec §6.5).

	Example (VIP, two pets worth +35 %, one 2x boost, 1 rebirth):
		{ vip = true, petCash = 0.35, boostCash = 2, rebirths = 1, rebirthShop = { clickPower = 2 } }
]]
export type Modifiers = {
	petCash: number?, -- summed equipped-pet cash bonus as a fraction (0.35 = +35 %)
	cashPass: boolean?, -- owns the "2x Cash" game pass
	vip: boolean?, -- owns the VIP game pass (+50 % cash)
	boostCash: number?, -- product of active personal timed cash boosts (2 = one 2x boost)
	boostSpeed: number?, -- product of active personal timed speed boosts (2 = one 2x speed boost)
	serverCash: number?, -- server-wide cash boost multiplier (Server 2x Cash product)
	eventCash: number?, -- live-event cash multiplier (Harvest Feast etc.), 1 when no event
	rebirths: number?, -- rebirth count (permanent +50 % cash each, RebirthConfig.BonusPerRebirth)
	rebirthShop: { [string]: number }?, -- rebirth shop levels (profile.rebirthShop)
	linkCash: number?, -- cross-world link multiplier (>= 1; WorldsConfig.linkCash), 1 / nil = none
	-- R78: Rookie / Comeback Rush multiplier (2 = a 2x rush), 1 / nil = none (RushService).
	rushCash: number?,
	-- R78: Friend Boost multiplier (1.2 = +20 % for two Roblox friends here), 1 / nil = none.
	friendCash: number?,
}

-- `Modifiers.resolve` output: the three numbers the producer maths multiplies by, plus breakdowns.
export type ResolvedModifiers = {
	cash: number, -- global cash multiplier (every producer, idle and manual; includes rebirth + production)
	speed: number, -- global speed multiplier (every producer)
	managerSpeed: number, -- extra speed multiplier for AUTOMATED producers only (rebirth shop)
	production: number, -- the "Power Production" share of `cash` (rebirth shop key clickPower; display only)
	rebirth: number, -- the rebirth share of `cash` (display only, shown on the Rebirth screen)
	link: number, -- the cross-world link share of `cash` (display only: "Dino Bonus +30%")
}

--------------------------------------------------------------------------------------------------
-- Worlds framework (World 2 plan §3.1): one economy per world, built by Shared/Tycoon/EconomyIndex.
--------------------------------------------------------------------------------------------------

-- Offline-earnings tunables (TycoonConfig.Offline). Player-level: shared by every world.
export type OfflineTunables = {
	BaseCapSeconds: number,
	BaseRate: number,
	MaxCapSeconds: number,
	MaxRate: number,
	PassCapSeconds: number,
	PassRate: number,
	MinSeconds: number,
}

-- Global modifier tunables (TycoonConfig.Modifiers). Shared by every world.
export type ModifierTunables = {
	CashPassMultiplier: number,
	VipMultiplier: number,
	MaxPetCash: number,
	MaxMultiplier: number,
}

-- The tunables every world's economy shares (the SAME table refs as TycoonConfig's).
export type EconomyTunables = {
	MilestoneEvery: number,
	MilestoneFactor: number,
	CycleFloor: number,
	MaxLevel: number,
	MaxBulkLevels: number,
	Offline: OfflineTunables,
	Modifiers: ModifierTunables,
}

-- Pacing targets of one world (minutes per area on a first run, and the simulator tolerance).
export type PacingTargets = {
	TargetMinutes: { number },
	Tolerance: number,
}

--[[
	Input of `EconomyIndex.build`: one world's raw areas plus its id rules.
	* `idPrefix` — "" for Nuke Town (legacy ids a<N>_ / p<N>_ / A<N>_), else ONE lowercase letter
	  ("d"): pads d<N>_name, producers dp<N>_name, build keys D<N>_Name.
	* `allowedFeatures` — the FeatureKeys this world's pads may carry (Dino: { Rebirth = true }).
]]
export type EconomySpec = {
	worldId: string,
	idPrefix: string,
	areas: { AreaConfig },
	pacing: PacingTargets,
	allowedFeatures: { [string]: boolean },
	tunables: EconomyTunables,
}

--[[
	One world's validated, frozen economy: exactly the lookup fields TycoonConfig has always had,
	plus the world identity and the shared tunables. TycoonConfig.Index is Nuke Town's;
	WorldsConfig.Worlds[id].economy is every world's.
]]
export type EconomyIndex = {
	WorldId: string,
	IdPrefix: string,
	PadPrefix: string, -- "a" (main) / "d": pad ids start with this + the area number
	ProducerPrefix: string, -- "p" (main) / "dp"
	BuildPrefix: string, -- "A" (main) / "D": build keys start with this + an area number
	Areas: { AreaConfig },
	PadOrder: { PadConfig },
	PadsById: { [string]: PadConfig },
	PadIndex: { [string]: number },
	Producers: { ProducerConfig },
	ProducersById: { [string]: ProducerConfig },
	PadsByTarget: { [string]: { PadConfig } },
	ManagerPadOf: { [string]: string },
	ProducerBuiltBy: { [string]: string },
	AreaPads: { [number]: { PadConfig } },
	FeaturePadOf: { [string]: string },
	FinalePadId: string,
	Pacing: PacingTargets,
	AllowedFeatures: { [string]: boolean },
	BuildKeys: { [string]: string }, -- pad build key -> pad id
	MilestoneEvery: number,
	MilestoneFactor: number,
	CycleFloor: number,
	MaxLevel: number,
	MaxBulkLevels: number,
	Offline: OfflineTunables,
	Modifiers: ModifierTunables,
}

-- One rebirth-shop upgrade. `perLevel` effects are additive per level; `values` are explicit
-- per-level amounts (values[L] = effect at level L, e.g. starting cash).
export type ShopUpgrade = {
	key: string,
	name: string,
	blurb: string,
	maxLevel: number,
	baseCost: number,
	costGrowth: number,
	perLevel: number?,
	values: { number }?,
}

-- Token reward tunables: tokens = floor((Base + levels / LevelsPerToken) * (1 + GrowthPerRebirth * done)).
export type RebirthTokens = {
	Base: number,
	LevelsPerToken: number,
	GrowthPerRebirth: number,
}

--[[
	One world's rebirth track (Shared/Config/RebirthConfig is Nuke Town's; Worlds/Dino/DinoRebirth
	is Dino Valley's Amber track). Shop keys are SAVE DATA in that world's rebirthShop table.
]]
export type RebirthDef = {
	BonusPerRebirth: number,
	MaxRebirths: number,
	Tokens: RebirthTokens,
	Shop: { [string]: ShopUpgrade },
	ShopOrder: { string },
}

return {}
