--!strict
--[[
	MainWorld — Nuke Town (world "main") as a WorldDef (World 2 plan §3.1).

	Purpose
		Wraps the existing Nuke Town modules — TycoonConfig (economy), RebirthConfig (rebirth track),
		the WorldGeometry "main" row, AreaLayouts and HubLayout — into the same shape every other
		world uses, so systems iterate `WorldsConfig.Order` instead of special-casing Nuke Town.
		Nothing here changes Nuke Town: the economy is `TycoonConfig.Index` (the very tables the
		module-level TycoonLogic uses) and the rebirth track is `RebirthConfig` itself.

	Connections
		* Registry: `Shared/Config/Worlds/WorldsConfig` (Worlds.main).
		* Currency icons: IconAssets "Cash" / "RebirthToken"; analytics keys "cash" / "tokens".
		* Eggs: the ten Nuke Town area eggs of EggConfig (sold in the main hub).

	Usage
		local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
		local main = WorldsConfig.get(WorldsConfig.MAIN)
]]

local RebirthConfig = require(script.Parent.Parent.RebirthConfig)
local TycoonConfig = require(script.Parent.Parent.TycoonConfig)
local WorldGeometry = require(script.Parent.WorldGeometry)
local WorldTypes = require(script.Parent.WorldTypes)

local MainWorld: WorldTypes.WorldDef = {
	id = "main",
	order = 1,
	name = "Nuke Town",
	tagline = "Where it all began: build your toy-nuke empire!",
	idPrefix = "",
	currency = {
		key = "cash",
		name = "Cash",
		icon = "Cash",
		color = Color3.fromRGB(120, 240, 70), -- UIStyleConfig CashGreen
		style = "money",
	},
	tokens = {
		key = "tokens",
		name = "Rebirth Tokens",
		icon = "RebirthToken",
		color = Color3.fromRGB(190, 130, 255),
		style = "count",
	},
	economy = TycoonConfig.Index,
	rebirth = RebirthConfig,
	geometry = WorldGeometry.get("main") :: WorldGeometry.Geometry,
	unlock = { kind = "always" },
	link = nil,
	features = {
		tutorial = true,
		knockdown = true,
		standName = true,
		attack = true,
		leaderstats = true,
	},
	layoutFolder = { "AreaLayouts" },
	hubLayout = { "HubLayout" },
	portalAnchor = nil,
	ambience = { lighting = "main", music = "music_nuke_town" },
	eggs = {
		"garage_egg",
		"stand_egg",
		"dash_egg",
		"mine_egg",
		"lab_egg",
		"factory_egg",
		"silo_egg",
		"mart_egg",
		"space_egg",
		"reactor_egg",
	},
}

return MainWorld
