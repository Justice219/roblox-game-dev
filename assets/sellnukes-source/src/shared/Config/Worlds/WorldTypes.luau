--!strict
--[[
	WorldTypes — the type vocabulary of the worlds framework (World 2 plan §3.1). Types only.

	Purpose
		`WorldsConfig` (the registry) requires every world's definition module, and those modules
		(`MainWorld`, `Dino/DinoWorld`, ...) must produce values of the same `WorldDef` type. Keeping
		the types here (no runtime requires of the registry) avoids a require cycle. `WorldsConfig`
		re-exports every type, so consumers write `WorldsConfig.WorldDef`.

	Connections
		* `Shared/Tycoon/TycoonTypes` — EconomyIndex, RebirthDef.
		* `Shared/Config/Worlds/WorldGeometry` — Geometry.
		* Values: `Worlds/MainWorld`, `Worlds/Dino/DinoWorld`; registry: `Worlds/WorldsConfig`.

	Usage
		local WorldTypes = require(script.Parent.WorldTypes)
		type WorldDef = WorldTypes.WorldDef
]]

local TycoonTypes = require(script.Parent.Parent.Parent.Tycoon.TycoonTypes)
local WorldGeometry = require(script.Parent.WorldGeometry)

--[[
	A currency a world earns or spends. `key` is the profile / analytics / product key ("cash",
	"bones", "tokens", "amber"); `icon` an IconAssets key; `style` how NumberFormat shows it:
	"money" = "$1.2T", "count" = "4.5M Bones".
]]
export type CurrencyDef = {
	key: string,
	name: string,
	icon: string,
	color: Color3,
	style: "money" | "count",
}

--[[
	When a world opens for a player (sticky once true; server-evaluated, spec §4.1):
	* { kind = "always" } — Nuke Town.
	* { kind = "progress", world = "main", area = 3, orRebirths = 1 } — the player's highest
	  unlocked area in `world` is >= area, OR they have >= orRebirths rebirths there.
]]
export type UnlockRule =
	{ kind: "always" }
	| {
		kind: "progress",
		world: string,
		area: number,
		orRebirths: number?,
	}

--[[
	Cross-world link (spec §6.5), declared by a non-main world:
	* Nuke Town cash  x (1 + toMainPerRebirth   * min(thisWorldRebirths, toMainMaxRebirths))
	* this world's currency x (1 + fromMainPerRebirth * min(mainRebirths, fromMainMaxRebirths))
	Dino: { 0.10, 20, 0.05, 10 } -> up to x3.0 Nuke Town cash and x1.5 Bones.
]]
export type LinkDef = {
	toMainPerRebirth: number,
	toMainMaxRebirths: number,
	fromMainPerRebirth: number,
	fromMainMaxRebirths: number,
}

-- Which Nuke-Town-only systems run in a world.
export type WorldFeatures = {
	tutorial: boolean, -- the FTUE tutorial steps
	knockdown: boolean, -- attack-mode knockdown of plot builds (R50)
	standName: boolean, -- the Nuke Stand rename sign
	attack: boolean, -- launching / being targeted by attack mode
	leaderstats: boolean, -- this world's currency shows in the Roblox leaderstats
}

-- Client presentation presets (WorldClientConfig keys): lighting preset + music preset.
export type WorldAmbience = {
	lighting: string,
	music: string,
}

--[[
	One world. Everything a system needs to run a world comes from here; adding World 3 = a new
	WorldDef + art (spec §18).
]]
export type WorldDef = {
	id: string, -- SAVE KEY (profile.worlds[id]); ^[a-z][a-z0-9]{0,15}$
	order: number, -- 1-based position in WorldsConfig.Order (tabs, rows, admin enums)
	name: string, -- "Nuke Town", "Dino Valley"
	tagline: string, -- one kid-friendly line for the Teleport screen tab
	idPrefix: string, -- "" (Nuke Town legacy ids) / "d"
	currency: CurrencyDef, -- what producers pay: cash / bones
	tokens: CurrencyDef, -- what rebirth pays: Rebirth Tokens / Amber
	economy: TycoonTypes.EconomyIndex,
	rebirth: TycoonTypes.RebirthDef,
	geometry: WorldGeometry.Geometry,
	unlock: UnlockRule,
	link: LinkDef?, -- nil for Nuke Town
	features: WorldFeatures,
	-- Path under ReplicatedStorage.Shared.Config to the folder of AreaNN layouts:
	-- { "AreaLayouts" } | { "Worlds", "Dino", "Layouts" }.
	layoutFolder: { string },
	-- Path under ReplicatedStorage.Shared.Config to the hub layout module:
	-- { "HubLayout" } (world space) | { "Worlds", "Dino", "ValleyLayout" } (WORLD-LOCAL).
	hubLayout: { string },
	portalAnchor: string?, -- key in HubLayout.anchors.WorldPortals (non-main worlds)
	ambience: WorldAmbience,
	eggs: { string }, -- egg ids sold in this world's hub (EggConfig)
}

return {}
