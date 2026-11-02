--!strict
--[[
	MoonWorld — Moon Base (world "moon") as a WorldDef (R69–R71 spec §2.1, owner R70 "a space world").

	A cartoon moon colony of cute aliens + robots, reached by the lobby's Moon Rocket: 6 areas, 59
	pads, ~2.5 h first run, its own currency (Moon Rocks, never converted to or from Cash or Bones),
	its own rebirth track (Star Shards, MoonRebirth) and the same two-way link with Nuke Town as Dino
	Valley (+10 % Nuke Town cash per Moon rebirth up to 20, +5 % Moon Rocks per Nuke Town rebirth up
	to 10). Added the spec §18 way: config + art, no framework special cases.

	Economy: the six `Areas/AreaNN` modules built by EconomyIndex with idPrefix "m" (pads m<N>_name,
	producers mp<N>_name, build keys M<N>_Name). Pad kinds mirror Dino Valley pad-for-pad, so the
	pricing structure is identical. Only the "Rebirth" feature is allowed. Pacing targets (minutes
	per area on a first run): 10 / 18 / 24 / 28 / 32 / 38 = 150 min, tuned by
	`lune run tests/economy-sim.luau --world moon`.

	Unlock (sticky, server-evaluated): Nuke Town area 5 (Enrichment Lab) reached OR >= 1 Nuke Town
	rebirth — Dino opens at area 3, Moon at area 5, a fresh goal for session 2.

	Connections
		* Registry: `Shared/Config/Worlds/WorldsConfig` (Worlds.moon).
		* Rebirth: `Worlds/Moon/MoonRebirth`; geometry: WorldGeometry "moon" (origin (-6000, 0, 0)).
		* Art: `Worlds/Moon/Layouts/AreaNN` (W6–W8), `Worlds/Moon/MoonHubLayout` (W9b, world-local),
		  portal anchor `HubLayout.anchors.WorldPortals.moon`. Every consumer finds these with
		  FindFirstChild / fs.isFile and falls back to placeholders while the art is missing.
		* Client: lighting preset "moon" + music "music_moon_base" (WorldClientConfig, low gravity).
		* Eggs: `moon_egg`, `comet_egg` (EggConfig, priced in Moon Rocks).

	Usage
		local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
		local moon = WorldsConfig.get("moon")
		print(moon.economy.PadsById.m3_radar_dish.cost)
]]

local AREAS = script.Parent.Areas
local EconomyIndex = require(script.Parent.Parent.Parent.Parent.Tycoon.EconomyIndex)
local MoonRebirth = require(script.Parent.MoonRebirth)
local TycoonConfig = require(script.Parent.Parent.Parent.TycoonConfig)
local TycoonTypes = require(script.Parent.Parent.Parent.Parent.Tycoon.TycoonTypes)
local WorldGeometry = require(script.Parent.Parent.WorldGeometry)
local WorldTypes = require(script.Parent.Parent.WorldTypes)

-- Pacing targets (spec §2.1): minutes a greedy no-Robux player spends in each Moon area on the
-- first run. tests/economy-sim.luau --world moon fails if any area drifts more than Tolerance.
local PACING: TycoonTypes.PacingTargets = {
	TargetMinutes = { 10, 18, 24, 28, 32, 38 },
	Tolerance = 0.2,
}

local ECONOMY = EconomyIndex.build({
	worldId = "moon",
	idPrefix = "m",
	areas = {
		require(AREAS.Area01),
		require(AREAS.Area02),
		require(AREAS.Area03),
		require(AREAS.Area04),
		require(AREAS.Area05),
		require(AREAS.Area06),
	} :: { TycoonTypes.AreaConfig },
	pacing = PACING,
	-- Only the finale's Rebirth: no Stand rename, no attack mode pads on the Moon.
	allowedFeatures = { Rebirth = true },
	tunables = TycoonConfig.Tunables,
})

local MoonWorld: WorldTypes.WorldDef = {
	id = "moon",
	order = 3,
	name = "Moon Base",
	tagline = "Blast off and build a nuke empire on the Moon!",
	idPrefix = "m",
	currency = {
		key = "moonrocks",
		name = "Moon Rocks",
		icon = "MoonRocks",
		color = Color3.fromRGB(196, 180, 255),
		style = "count",
	},
	tokens = {
		key = "starshards",
		name = "Star Shards",
		icon = "StarShards",
		color = Color3.fromRGB(120, 230, 255),
		style = "count",
	},
	economy = ECONOMY,
	rebirth = MoonRebirth,
	geometry = WorldGeometry.get("moon") :: WorldGeometry.Geometry,
	unlock = { kind = "progress", world = "main", area = 5, orRebirths = 1 },
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
	layoutFolder = { "Worlds", "Moon", "Layouts" },
	hubLayout = { "Worlds", "Moon", "MoonHubLayout" },
	portalAnchor = "moon",
	ambience = { lighting = "moon", music = "music_moon_base" },
	eggs = { "moon_egg", "comet_egg" },
}

return MoonWorld
