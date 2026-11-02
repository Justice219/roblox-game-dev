--!strict
--[[
	WorldLookup — the tycoon client's one door to "which world is this id / plot in, and what are
	that world's economy, wallet, currency and layouts" (owner R57, plan §3.5).

	Purpose:
		Pad / producer / build-key ids are globally unique and prefixed (a1_workbench / p1_workbench
		/ A1_ToolWall in Nuke Town, d3_wind_sock / dp3_ptero_express / D3_WindSock in Dino Valley),
		so every Client/Tycoon module resolves an id here instead of reading TycoonConfig (which is
		Nuke Town only). Billboards and pops ask `currencyOf` / `format` so a Dino price shows the
		bone icon + "1.2K" instead of "$1.2K"; costs use the world's own TycoonLogic + wallet.

	Trust: display only. Every number shown comes from server state (ClientState snapshot,
	server-set attributes); every purchase / click / upgrade stays a server-validated intent.

	Performance: O(1) maps from WorldsConfig (built at load); per-world Logic is cached by
	TycoonLogic.forWorld; area layouts are required once per (world, area) and cached.

	Connects to: Shared/Config/Worlds/WorldsConfig (registry, id -> world maps), Shared/Tycoon/
	TycoonLogic (forWorld), ClientState (world tycoon state + wallet), Shared/Util/NumberFormat,
	Tycoon/{ProducerBillboards, PadBillboards, Interaction, IncomePops, YouMarker, TycoonWorld},
	Fx/VehicleRoutes, Npc/ManagerController.

	Example:
		local worldId, pad = WorldLookup.pad("d3_wind_sock")      --> "dino", PadConfig
		local cost = WorldLookup.logic(worldId).upgradeCost(cfg, level, 1)
		label.Text = WorldLookup.format(worldId, cost)             --> "1.2K" (bone icon beside it)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientState = require(script.Parent.Parent.ClientState)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type PadConfig = TycoonTypes.PadConfig
type ProducerConfig = TycoonTypes.ProducerConfig
type TycoonState = TycoonTypes.TycoonState
type Logic = TycoonLogic.Logic
export type CurrencyDef = WorldsConfig.CurrencyDef

local WorldLookup = {}

-- Nuke Town: the default for every optional world id.
WorldLookup.MAIN = WorldsConfig.MAIN

-- Player attribute the server (WorldService) keeps on the world the player is in.
local CURRENT_WORLD_ATTR = "CurrentWorld"

local MAIN_DEF = WorldsConfig.get(WorldsConfig.MAIN) :: WorldsConfig.WorldDef

-- (worldId -> area -> layout table | false) — false caches "no such module".
local layoutCache: { [string]: { [number]: any } } = {}

--[[
	A registered world id, or "main" for anything else (nil / unknown / non-string).
	Example: WorldLookup.normalize("dino") --> "dino"; WorldLookup.normalize(nil) --> "main"
]]
function WorldLookup.normalize(worldId: unknown): string
	return if type(worldId) == "string" and WorldsConfig.get(worldId) ~= nil then worldId else WorldsConfig.MAIN
end

--[[ The WorldDef of a world (Nuke Town for unknown ids). ]]
function WorldLookup.def(worldId: string?): WorldsConfig.WorldDef
	return WorldsConfig.get(worldId) or MAIN_DEF
end

--[[
	The world + config of a pad id (nil, nil for an unknown id).
	Example: WorldLookup.pad("a1_workbench") --> "main", PadConfig
]]
function WorldLookup.pad(padId: unknown): (string?, PadConfig?)
	local worldId = WorldsConfig.worldOfPad(padId)
	local def = if worldId ~= nil then WorldsConfig.get(worldId) else nil
	if def == nil then
		return nil, nil
	end
	return worldId, def.economy.PadsById[padId :: string]
end

--[[
	The world + config of a producer id (nil, nil for an unknown id).
	Example: WorldLookup.producer("dp3_ptero_express") --> "dino", ProducerConfig
]]
function WorldLookup.producer(producerId: unknown): (string?, ProducerConfig?)
	local worldId = WorldsConfig.worldOfProducer(producerId)
	local def = if worldId ~= nil then WorldsConfig.get(worldId) else nil
	if def == nil then
		return nil, nil
	end
	return worldId, def.economy.ProducersById[producerId :: string]
end

--[[ The world of a build key ("D3_WindSock" -> "dino"; "main" when unknown). ]]
function WorldLookup.worldOfBuildKey(key: unknown): string
	return WorldsConfig.worldOfBuildKey(key) or WorldsConfig.MAIN
end

--[[
	The bound economy Logic of a world (cached by TycoonLogic.forWorld; unknown ids -> Nuke Town).
	Example: WorldLookup.logic("dino").upgradeCost(cfg, 4, 10)
]]
function WorldLookup.logic(worldId: string?): Logic
	return TycoonLogic.forWorld(WorldLookup.normalize(worldId))
end

--[[
	The currency a world's producers pay and its pads cost (Nuke Town Cash / Dino Bones).
	@param id a world id, or a pad / producer id (resolved to its world); unknown -> Cash
	Example: WorldLookup.currencyOf("dino").icon --> "Bones"
]]
function WorldLookup.currencyOf(id: unknown): CurrencyDef
	if type(id) == "string" then
		local def = WorldsConfig.get(id)
			or WorldsConfig.get(WorldsConfig.worldOfPad(id))
			or WorldsConfig.get(WorldsConfig.worldOfProducer(id))
		if def ~= nil then
			return def.currency
		end
	end
	return MAIN_DEF.currency
end

--[[
	An amount in a world's currency style: "money" -> "$1.25K", "count" -> "1.25K" (the caller
	shows the currency icon beside it).
	Example: WorldLookup.format("dino", 1250) --> "1.25K"; WorldLookup.format("main", 1250) --> "$1.25K"
]]
function WorldLookup.format(worldId: string?, amount: number): string
	local currency = WorldLookup.currencyOf(worldId)
	return if currency.style == "money" then NumberFormat.money(amount) else NumberFormat.short(amount)
end

--[[
	True when a world's amounts need an icon beside the text (anything not "$"-styled).
	Example: WorldLookup.usesIcon("dino") --> true
]]
function WorldLookup.usesIcon(worldId: string?): boolean
	return WorldLookup.currencyOf(worldId).style ~= "money"
end

--[[
	An amount as plain text where no icon can sit beside it (input hint bar, toasts): "$1.25K" in
	Nuke Town, "1.25K Bones" in an icon world.
	Example: WorldLookup.label("dino", 1250) --> "1.25K Bones"
]]
function WorldLookup.label(worldId: string?, amount: number): string
	local currency = WorldLookup.currencyOf(worldId)
	local text = WorldLookup.format(worldId, amount)
	return if currency.style == "money" then text else `{text} {currency.name}`
end

--[[
	The local player's tycoon state for a world (READ-ONLY server snapshot), or nil before the
	first snapshot / when the world has no data yet.
	Example: local state = WorldLookup.tycoon("dino"); if state then print(state.area) end
]]
function WorldLookup.tycoon(worldId: string?): TycoonState?
	local id = WorldLookup.normalize(worldId)
	local source: any = if id == WorldsConfig.MAIN then ClientState.profile else ClientState.world(id)
	local tycoon = if type(source) == "table" then source.tycoon else nil
	return if type(tycoon) == "table" then tycoon :: any else nil
end

--[[
	The local player's balance in a world's currency (Cash / Bones; 0 before the snapshot).
	Example: if WorldLookup.wallet("dino") >= cost then ... end
]]
function WorldLookup.wallet(worldId: string?): number
	local balance = ClientState.worldCash(WorldLookup.normalize(worldId))
	return balance
end

--[[
	The world the local player is in right now (server Player attribute CurrentWorld; "main"
	before it is set or for an unknown value).
]]
function WorldLookup.current(): string
	local player = Players.LocalPlayer
	return WorldLookup.normalize(if player ~= nil then player:GetAttribute(CURRENT_WORLD_ATTR) else nil)
end

--[[
	The ModuleScript folder of a world's area layouts (WorldDef.layoutFolder under
	ReplicatedStorage.Shared.Config: Nuke Town "AreaLayouts", Dino "Worlds/Dino/Layouts"), or nil.
]]
function WorldLookup.layoutFolder(worldId: string?): Instance?
	local node: Instance? = ReplicatedStorage.Shared.Config
	for _, name in WorldLookup.def(worldId).layoutFolder do
		node = if node ~= nil then node:FindFirstChild(name) else nil
	end
	return node
end

--[[
	A world's slot-local AreaNN layout table (AreaLayouts contract; required once, cached), or
	nil when the module is missing or fails to load.
	Example: local layout = WorldLookup.layout("dino", 3); print(layout and layout.producer)
]]
function WorldLookup.layout(worldId: string?, area: number): any?
	local id = WorldLookup.normalize(worldId)
	local perWorld = layoutCache[id]
	if perWorld == nil then
		perWorld = {}
		layoutCache[id] = perWorld
	end
	local cached = perWorld[area]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local folder = WorldLookup.layoutFolder(id)
	local module = if folder ~= nil then folder:FindFirstChild(string.format("Area%02d", area)) else nil
	local layout: any = false
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then
			layout = result
		end
	end
	perWorld[area] = layout
	return if layout == false then nil else layout
end

--[[ The number of areas of a world (its economy's area list). ]]
function WorldLookup.areaCount(worldId: string?): number
	return #WorldLookup.def(worldId).economy.Areas
end

return WorldLookup
