--!strict
--[[
	DinoWorld — Dino Valley (world "dino") as a WorldDef (World 2 spec §0 / §2 / §6, plan §3.1).

	A sunny prehistoric jungle valley reached by a cartoon Time Machine: 6 areas, 59 pads,
	~2.5 h first run, its own currency (Bones, never converted to or from Cash), its own rebirth
	track (Amber, DinoRebirth) and a two-way link with Nuke Town (+10 % Nuke Town cash per Dino
	rebirth up to 20, +5 % Bones per Nuke Town rebirth up to 10).

	Economy: the six `Areas/AreaNN` modules built by EconomyIndex with idPrefix "d" (pads d<N>_name,
	producers dp<N>_name, build keys D<N>_Name). Only the "Rebirth" feature is allowed (AA / attack /
	Stand rename stay in Nuke Town). Pacing targets (minutes per area on a first run, spec §6.3):
	10 / 18 / 24 / 28 / 32 / 38 = 150 min, tuned by `lune run tests/economy-sim.luau --world dino`.

	Unlock (sticky, server-evaluated): Nuke Town area 3 (BoomDash Delivery) reached OR >= 1 Nuke
	Town rebirth.

	Connections
		* Registry: `Shared/Config/Worlds/WorldsConfig` (Worlds.dino).
		* Rebirth: `Worlds/Dino/DinoRebirth`; geometry: WorldGeometry "dino" (origin (6000, 0, 0)).
		* Art: `Worlds/Dino/Layouts/AreaNN` (W6–W8), `Worlds/Dino/ValleyLayout` (W9, world-local),
		  portal anchor `HubLayout.anchors.WorldPortals.dino`.
		* Eggs: `dino_egg`, `volcano_egg` (EggConfig, priced in Bones).

	Usage
		local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
		local dino = WorldsConfig.get("dino")
		print(dino.economy.PadsById.d3_wind_sock.cost)
]]

local AREAS = script.Parent.Areas
local DinoRebirth = require(script.Parent.DinoRebirth)
local EconomyIndex = require(script.Parent.Parent.Parent.Parent.Tycoon.EconomyIndex)
local TycoonConfig = require(script.Parent.Parent.Parent.TycoonConfig)
local TycoonTypes = require(script.Parent.Parent.Parent.Parent.Tycoon.TycoonTypes)
local WorldGeometry = require(script.Parent.Parent.WorldGeometry)
local WorldTypes = require(script.Parent.Parent.WorldTypes)

-- Pacing targets (spec §6.3 table): minutes a greedy no-Robux player spends in each Dino area on
-- the first run. tests/economy-sim.luau --world dino fails if any area drifts more than Tolerance.
local PACING: TycoonTypes.PacingTargets = {
	TargetMinutes = { 10, 18, 24, 28, 32, 38 },
	Tolerance = 0.2,
}

local ECONOMY = EconomyIndex.build({
	worldId = "dino",
	idPrefix = "d",
	areas = {
		require(AREAS.Area01),
		require(AREAS.Area02),
		require(AREAS.Area03),
		require(AREAS.Area04),
		require(AREAS.Area05),
		require(AREAS.Area06),
	} :: { TycoonTypes.AreaConfig },
	pacing = PACING,
	-- Only the finale's Rebirth: no Stand rename, no attack mode pads in the Valley.
	allowedFeatures = { Rebirth = true },
	tunables = TycoonConfig.Tunables,
})

local DinoWorld: WorldTypes.WorldDef = {
	id = "dino",
	order = 2,
	name = "Dino Valley",
	tagline = "Hop in the Time Machine and build a dino nuke empire!",
	idPrefix = "d",
	currency = {
		key = "bones",
		name = "Bones",
		icon = "Bones",
		color = Color3.fromRGB(245, 234, 205),
		style = "count",
	},
	tokens = {
		key = "amber",
		name = "Amber",
		icon = "Amber",
		color = Color3.fromRGB(255, 168, 40),
		style = "count",
	},
	economy = ECONOMY,
	rebirth = DinoRebirth,
	geometry = WorldGeometry.get("dino") :: WorldGeometry.Geometry,
	unlock = { kind = "progress", world = "main", area = 3, orRebirths = 1 },
	link = {
		toMainPerRebirth = 0.10,
		toMainMaxRebirths = 20,
		fromMainPerRebirth = 0.05,
		fromMainMaxRebirths = 10,
	},
	features = {
		tutorial = false,
		knockdown = false,
		standName = false,
		attack = false,
		leaderstats = false,
	},
	layoutFolder = { "Worlds", "Dino", "Layouts" },
	hubLayout = { "Worlds", "Dino", "ValleyLayout" },
	portalAnchor = "dino",
	ambience = { lighting = "dino", music = "music_dino_valley" },
	eggs = { "dino_egg", "volcano_egg" },
}

return DinoWorld
