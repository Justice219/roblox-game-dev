--!strict
--[[
	PreloadList — WHICH meshes to load, in WHAT order (owner R16: "the models took forever to load").

	Shared by the server (MeshLibrary boot warm-up tiers, PlotBuilder restore order) and the client
	loading screen (ContentProvider:PreloadAsync on the content ids). Pure data over the static
	layouts — no Instances, no yields.

	Sources: HubLayout (hub models, plotFrame, lockedSlot), AreaLayouts/AreaNN (base + builds per
	build key), TycoonConfig (pads -> build keys), TycoonLogic (owned pads, unlocked areas),
	MeshAssets (piece MeshIds; id 0 = not uploaded -> skipped).

	API
		PreloadList.hubKeys()             hub models (minus deferred decor) + plot frame + locked-slot
		                                  placeholder + BuyPad
		PreloadList.deferredHubKeys()     lobby decor HubBuilder spawns after WorldReady (tier 2)
		PreloadList.areaKeys(area, owned?) area base + its builds (all, or only those `owned` allows)
		PreloadList.plotKeys(tycoon)      a player's plot in build order: area 1 base + bought builds,
		                                  then area 2, ... (only unlocked areas, only bought builds)
		PreloadList.tiers()               boot warm-up tiers (MeshLibrary):
		                                    1 hub + frame + BuyPad + Area 1 (everything a new player sees)
		                                    2 areas 2-4   3 areas 5-10   4 every other MeshAssets model
		PreloadList.contentIds(keys)      "rbxassetid://N" of every uploaded piece, deduped, in order
		PreloadList.forClient(tycoon?)    hub + (that plot's bought builds) content ids (the pre-R122
		                                  single list; kept for callers / tests)
		PreloadList.criticalKeys(tycoon?) R122: what the join loading bar WAITS for: plot frame +
		                                  locked slot + BuyPad, this plot (unlocked bases + bought
		                                  builds; nil tycoon = area 1 base), the current next pads'
		                                  builds
		PreloadList.deferredKeys(tycoon?) R122: every other hub / area mesh the player will see, for
		                                  the background continuation: the rest of the unlocked
		                                  areas (upcoming purchases; nil tycoon: all of area 1), the
		                                  shared hub, the lobby decor, the next locked area's base
		PreloadList.forClientCritical(tycoon?) / forClientDeferred(tycoon?)  their content ids;
		                                  disjoint (a piece shared by both is only critical)
		PreloadList.world(worldId, tycoon?) R57: mesh KEYS to preload when travelling to a world:
		                                  that world's hub (minus deferred decor) + plot frame +
		                                  locked slot + BuyPad, then that plot's bought builds
		                                  (contentIds(...) turns them into content ids)
		PreloadList.worldHubKeys(worldId) R57: a world's first-view hub keys (main = hubKeys())
		areaKeys / plotKeys take an optional trailing worldId (nil = Nuke Town, unchanged).

	Worlds (owner R57, plan §3.3): a non-main world reads its layouts from WorldDef.layoutFolder
	(Dino: Config/Worlds/Dino/Layouts/AreaNN) and its hub from WorldDef.hubLayout (Dino:
	ValleyLayout; deferred decor = `deferredKeys` (list or set) or `isDeferred(key)`). The registry
	is required lazily, only for non-main worlds, so the loading screen's require chain is unchanged.

	Client callers in ReplicatedFirst must wait for replication before requiring this module
	(`if not game:IsLoaded() then game.Loaded:Wait() end`), as for any Shared module.

	R122 split (owner R122, spec 2026-11-01 §2.1): field data showed phones waiting ~26 s behind the
	join loading screen (45 of 71 phone boots hit the 30 s asset budget) while a new player's
	forClient(nil) was 175 mesh ids (49 hub models, ~330k triangles). The bar now waits only for
	the CRITICAL list (a new player: frame, locked slot, BuyPad, area 1 base, the first pad's
	build); the DEFERRED list downloads after the hand-off in the Loader's background thread.

	Example (client loading screen):
		local tycoon = ClientState.profile and ClientState.profile.tycoon
		ContentProvider:PreloadAsync(holdersFor(PreloadList.forClientCritical(tycoon))) -- bar waits
		-- after the hand-off, in small paced batches:
		ContentProvider:PreloadAsync(holdersFor(PreloadList.forClientDeferred(tycoon)))
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Area layout lookup that also works on the lune test loader's path nodes
-- (tests/preload-list.luau): real Instances use FindFirstChild, path nodes just index.
local function findChild(parent: any, name: string): any
	if typeof(parent) == "Instance" then
		return (parent :: Instance):FindFirstChild(name)
	end
	return parent[name]
end

local Config = ReplicatedStorage.Shared.Config
local HubLayout = require(Config.HubLayout)
local MeshAssets = require(Config.MeshAssets)
local TycoonConfig = require(Config.TycoonConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)

local PreloadList = {}

local AREA_COUNT = #TycoonConfig.Areas
-- The main world's id (a literal: the main path never requires the worlds registry).
local MAIN = "main"
-- Per world: area -> layout table (false = missing / failed).
local layoutCache: { [string]: { [number]: any } } = {}
-- Per non-main world: its hub layout table (false = missing / failed).
local hubCache: { [string]: any } = {}

-- The worlds registry, required on first non-main use.
local function registry(): any
	return require(Config.Worlds.WorldsConfig) :: any
end

-- A non-main world's definition (errors for an unknown id: a programming bug).
local function defOf(worldId: string): any
	local def = registry().get(worldId)
	assert(def ~= nil, `PreloadList: unknown world {worldId}`)
	return def
end

-- Walks a path of child names under Config ({"Worlds", "Dino", "Layouts"}); nil when missing.
local function configChild(path: { string }): any
	local node: any = Config
	for _, name in path do
		if node == nil then
			return nil
		end
		node = findChild(node, name)
	end
	return node
end

-- Requires a layout module (Instance or test path node); nil when missing / failing / not a table.
local function requireTable(module: any): any
	if module == nil or (typeof(module) == "Instance" and not (module :: Instance):IsA("ModuleScript")) then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok and type(result) == "table" then result else nil
end

-- The art layout of an area of a world (cached), or nil when the file is missing / fails to load.
local function layoutOf(area: number, worldId: string?): any
	local world = worldId or MAIN
	local perWorld = layoutCache[world]
	if perWorld == nil then
		perWorld = {}
		layoutCache[world] = perWorld
	end
	local cached = perWorld[area]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local folder = if world == MAIN then findChild(Config, "AreaLayouts") else configChild(defOf(world).layoutFolder)
	local module = folder and findChild(folder, string.format("Area%02d", area))
	local layout: any = requireTable(module) or false
	perWorld[area] = layout
	return if layout == false then nil else layout
end

-- The economy (pads per area, area count) of a world: Nuke Town's TycoonConfig or the registry's.
local function economyOf(worldId: string?): any
	if worldId == nil or worldId == MAIN then
		return TycoonConfig
	end
	return defOf(worldId).economy
end

-- The tycoon logic of a world (Nuke Town: the module API; another world: lazily bound).
local function logicOf(worldId: string?): any
	if worldId == nil or worldId == MAIN then
		return TycoonLogic
	end
	return TycoonLogic.forWorld(worldId)
end

-- Appends the keys of a placement list (deduped through `seen`).
local function addModels(out: { string }, seen: { [string]: boolean }, models: any)
	if type(models) ~= "table" then
		return
	end
	for _, entry in models do
		local key = type(entry) == "table" and entry.key
		if type(key) == "string" and not seen[key] and MeshAssets[key] ~= nil then
			seen[key] = true
			table.insert(out, key)
		end
	end
end

-- True when HubLayout marks `key` as lobby decor that loads after WorldReady (L1, R55 perf).
local function isDeferredDecor(key: string): boolean
	local check = (HubLayout :: any).isDeferred :: ((string) -> boolean)?
	if check == nil then
		return false
	end
	local ok, deferred = pcall(check, key)
	return ok and deferred == true
end

--[[
	Hub models (minus the deferred lobby decor, HubLayout.isDeferred), the per-plot frame, the
	locked-slot placeholder and the buy pad: what the first view needs.
]]
function PreloadList.hubKeys(): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local firstWave: { any } = {}
	for _, entry in HubLayout.models do
		if type(entry) == "table" and type(entry.key) == "string" and not isDeferredDecor(entry.key) then
			table.insert(firstWave, entry)
		end
	end
	addModels(out, seen, firstWave)
	local frame = (HubLayout :: any).plotFrame
	addModels(out, seen, type(frame) == "table" and frame.models or nil)
	local locked = (HubLayout :: any).lockedSlot
	addModels(out, seen, type(locked) == "table" and locked.models or nil)
	addModels(out, seen, { { key = "BuyPad" } })
	return out
end

--[[
	The deferred lobby decor keys (HubLayout.isDeferred) that MeshAssets knows, in layout order:
	HubBuilder spawns them after WorldReady, so they load in warm-up tier 2 (Background) and stay
	out of the client's blocking preload.
]]
function PreloadList.deferredHubKeys(): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local decor: { any } = {}
	for _, entry in HubLayout.models do
		if type(entry) == "table" and type(entry.key) == "string" and isDeferredDecor(entry.key) then
			table.insert(decor, entry)
		end
	end
	addModels(out, seen, decor)
	return out
end

--[[
	An area's base + builds. `owned(buildKey)` filters builds (nil = every build of the area).
	@param area number 1..that world's area count
	@param owned ((string) -> boolean)?
	@param worldId string? — R57: nil = Nuke Town
]]
function PreloadList.areaKeys(area: number, owned: ((string) -> boolean)?, worldId: string?): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local layout = layoutOf(area, worldId)
	if layout == nil then
		return out
	end
	addModels(out, seen, type(layout.base) == "table" and layout.base.models or nil)
	-- Builds in pad order (the order players buy them), so partial loads look natural.
	for _, pad in economyOf(worldId).AreaPads[area] or {} do
		local group = type(layout.builds) == "table" and layout.builds[pad.build] or nil
		if group ~= nil and (owned == nil or owned(pad.build)) then
			addModels(out, seen, group.models)
		end
	end
	return out
end

--[[
	A player's plot in build order: for each unlocked area (1 first), its base, then the builds of
	the pads they own. Never includes unbought builds or locked areas.
	@param tycoon any  profile.tycoon (TycoonLogic state; another world: profile.worlds.<w>.tycoon)
	@param worldId string? — R57: nil = Nuke Town
]]
function PreloadList.plotKeys(tycoon: any, worldId: string?): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	addModels(out, seen, { { key = "BuyPad" } })
	if type(tycoon) ~= "table" then
		return out
	end
	local economy = economyOf(worldId)
	local logic = logicOf(worldId)
	for area = 1, #economy.Areas do
		if logic.areaUnlocked(tycoon, area) then
			local ownedBuilds: { [string]: boolean } = {}
			for _, pad in economy.AreaPads[area] or {} do
				if logic.ownsPad(tycoon, pad.id) then
					ownedBuilds[pad.build] = true
				end
			end
			local function isOwned(buildKey: string): boolean
				return ownedBuilds[buildKey] == true
			end
			for _, key in PreloadList.areaKeys(area, isOwned, worldId) do
				if not seen[key] then
					seen[key] = true
					table.insert(out, key)
				end
			end
		end
	end
	return out
end

--[[
	Boot warm-up tiers for MeshLibrary (each key appears once, in the earliest tier that needs it):
		1 hub (minus deferred decor) + plot frame + BuyPad + Area 1 (all builds)
		2 deferred lobby decor, then areas 2-4   3 areas 5-10
		4 every remaining MeshAssets model (pets, eggs, crates, attack, event, ...)
]]
function PreloadList.tiers(): { { string } }
	local seen: { [string]: boolean } = {}
	local function take(keys: { string }): { string }
		local out = {}
		for _, key in keys do
			if not seen[key] then
				seen[key] = true
				table.insert(out, key)
			end
		end
		return out
	end
	local function areas(from: number, to: number): { string }
		local out = {}
		for area = from, math.min(to, AREA_COUNT) do
			for _, key in PreloadList.areaKeys(area, nil) do
				table.insert(out, key)
			end
		end
		return out
	end
	local tier1 = take(PreloadList.hubKeys())
	for _, key in take(PreloadList.areaKeys(1, nil)) do
		table.insert(tier1, key)
	end
	-- Deferred lobby decor first in tier 2 (Background): it never gates WorldReady.
	local tier2 = take(PreloadList.deferredHubKeys())
	for _, key in take(areas(2, 4)) do
		table.insert(tier2, key)
	end
	local tier3 = take(areas(5, AREA_COUNT))
	local rest: { string } = {}
	for key in MeshAssets do
		table.insert(rest, key)
	end
	table.sort(rest)
	return { tier1, tier2, tier3, take(rest) }
end

--[[ Content ids ("rbxassetid://N") of every uploaded piece of `keys`, deduped, in key order. ]]
function PreloadList.contentIds(keys: { string }): { string }
	local out: { string } = {}
	local seen: { [number]: boolean } = {}
	for _, key in keys do
		local asset = MeshAssets[key]
		if asset ~= nil then
			for _, name in asset.order do
				local id = asset.pieces[name].id
				if id > 0 and not seen[id] then
					seen[id] = true
					table.insert(out, `rbxassetid://{id}`)
				end
			end
		end
	end
	return out
end

--[[
	What a joining client should preload behind its loading screen: the hub + frame (without the
	deferred lobby decor, which spawns after WorldReady), then its own plot's bought builds (when
	the profile is known). Content ids, deduped.
	@param tycoon any?  profile.tycoon, or nil before the profile arrives
]]
function PreloadList.forClient(tycoon: any?): { string }
	local keys = PreloadList.hubKeys()
	if tycoon ~= nil then
		local seen: { [string]: boolean } = {}
		for _, key in keys do
			seen[key] = true
		end
		for _, key in PreloadList.plotKeys(tycoon) do
			if not seen[key] then
				seen[key] = true
				table.insert(keys, key)
			end
		end
	end
	return PreloadList.contentIds(keys)
end

-- Appends every key of `keys` not in `seen` to `out` (marking it seen), keeping order.
local function appendKeys(out: { string }, seen: { [string]: boolean }, keys: { string })
	for _, key in keys do
		if not seen[key] then
			seen[key] = true
			table.insert(out, key)
		end
	end
end

-- The model keys of ONE build group of a Nuke Town area (a pad's `build`), or {} when unknown.
local function buildModelKeys(area: number, buildKey: string): { string }
	local out: { string } = {}
	local layout = layoutOf(area, nil)
	local group = if layout ~= nil and type(layout.builds) == "table" then layout.builds[buildKey] else nil
	if type(group) == "table" then
		addModels(out, {}, group.models)
	end
	return out
end

-- Every key of an area EXCEPT its builds (the area base), Nuke Town.
local function noBuilds(_buildKey: string): boolean
	return false
end

--[[
	R122: the mesh keys a joining client's loading bar WAITS for (the critical preload), in
	priority order:
		1 the plot frame, the locked-slot placeholder and the buy pad (every plot shows them);
		2 this player's plot in build order (PreloadList.plotKeys: each unlocked area's base, then
		  its bought builds) — without a tycoon (profile not arrived) area 1's base, which every
		  plot shows;
		3 the builds of the CURRENT next pads (TycoonLogic.nextPads), so the next purchase's
		  fly-in never waits for a download.
	Never the shared hub models, lobby decor or unbought later builds (deferredKeys). Nuke Town
	only (the join world; another world's travel preload is PreloadList.world).
	@param tycoon any?  profile.tycoon, or nil before the profile arrives
	@return { string } deduped MeshAssets keys
	Example: PreloadList.criticalKeys(TycoonLogic.newState()) --> { frame..., "BuyPad", area 1 base..., first pad build... }
]]
function PreloadList.criticalKeys(tycoon: any?): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local frame = (HubLayout :: any).plotFrame
	addModels(out, seen, type(frame) == "table" and frame.models or nil)
	local locked = (HubLayout :: any).lockedSlot
	addModels(out, seen, type(locked) == "table" and locked.models or nil)
	addModels(out, seen, { { key = "BuyPad" } })
	if type(tycoon) == "table" then
		appendKeys(out, seen, PreloadList.plotKeys(tycoon))
		for _, pad in TycoonLogic.nextPads(tycoon) do
			appendKeys(out, seen, buildModelKeys(pad.area, pad.build))
		end
	else
		appendKeys(out, seen, PreloadList.areaKeys(1, noBuilds))
	end
	return out
end

--[[
	R122: every other hub / area mesh a joining player will see — what the Loader's background
	thread downloads AFTER the critical list (and after the hand-off), in priority order:
		1 the upcoming purchases: the rest of every unlocked area's builds in pad order (without a
		  tycoon: all of area 1, a new player's first builds). They are never instanced before
		  they are bought, so this warm-up is the ONLY thing that makes their fly-in download-free;
		2 the shared hub models (HubLayout first wave; the per-plot frame is already critical) —
		  already replicated, so the engine fetches them on demand too: the preload only finishes
		  them sooner;
		3 the lobby decor HubBuilder spawns after WorldReady (deferredHubKeys);
		4 with a tycoon: the base of the next locked area (its unlock fly-in).
	Disjoint from criticalKeys(tycoon) (same tycoon). Never areas past the next locked one.
	@param tycoon any?  profile.tycoon, or nil when the profile did not arrive
	@return { string } deduped MeshAssets keys
]]
function PreloadList.deferredKeys(tycoon: any?): { string }
	local seen: { [string]: boolean } = {}
	for _, key in PreloadList.criticalKeys(tycoon) do
		seen[key] = true
	end
	local out: { string } = {}
	-- The first locked area (nil = every area unlocked / no tycoon): its base loads last.
	local nextLocked: number? = nil
	if type(tycoon) == "table" then
		for area = 1, AREA_COUNT do
			if not TycoonLogic.areaUnlocked(tycoon, area) then
				nextLocked = area
				break
			end
			appendKeys(out, seen, PreloadList.areaKeys(area, nil))
		end
	else
		appendKeys(out, seen, PreloadList.areaKeys(1, nil))
	end
	appendKeys(out, seen, PreloadList.hubKeys())
	appendKeys(out, seen, PreloadList.deferredHubKeys())
	if nextLocked ~= nil then
		appendKeys(out, seen, PreloadList.areaKeys(nextLocked, noBuilds))
	end
	return out
end

--[[
	R122: content ids of criticalKeys(tycoon) — the join loading bar waits for these (within
	Readiness.ASSET_BUDGET). Deduped, in priority order.
	@param tycoon any?  profile.tycoon, or nil before the profile arrives
	Example: ContentProvider:PreloadAsync(meshHolders(PreloadList.forClientCritical(tycoon)))
]]
function PreloadList.forClientCritical(tycoon: any?): { string }
	return PreloadList.contentIds(PreloadList.criticalKeys(tycoon))
end

--[[
	R122: content ids of deferredKeys(tycoon) WITHOUT any id already in forClientCritical(tycoon)
	(mesh pieces can be shared between models), in priority order — the Loader's background
	continuation after the hand-off.
	@param tycoon any?  profile.tycoon, or nil when the profile did not arrive
]]
function PreloadList.forClientDeferred(tycoon: any?): { string }
	local critical: { [string]: boolean } = {}
	for _, id in PreloadList.forClientCritical(tycoon) do
		critical[id] = true
	end
	local out: { string } = {}
	for _, id in PreloadList.contentIds(PreloadList.deferredKeys(tycoon)) do
		if not critical[id] then
			table.insert(out, id)
		end
	end
	return out
end

-- A non-main world's hub layout table (cached; nil when missing / failing).
local function worldHub(worldId: string): any
	local cached = hubCache[worldId]
	if cached == nil then
		cached = requireTable(configChild(defOf(worldId).hubLayout)) or false
		hubCache[worldId] = cached
	end
	return if cached == false then nil else cached
end

-- True when a world hub layout marks `key` as deferred decor (`deferredKeys` list / set, or
-- `isDeferred(key)`), so it stays out of the travel preload.
local function isWorldDeferred(hub: any, key: string): boolean
	local deferred = hub.deferredKeys
	if type(deferred) == "table" then
		if deferred[key] == true or table.find(deferred, key) ~= nil then
			return true
		end
	end
	local check = hub.isDeferred
	if type(check) == "function" then
		local ok, result = pcall(check, key)
		return ok and result == true
	end
	return false
end

--[[
	R57: a world's first-view hub keys — its hub models minus deferred decor, the plot frame, the
	locked slot and the buy pad. Nuke Town = hubKeys(). A world whose hub layout is not authored yet
	gets just the buy pad.
	@param worldId string
	@return {string}
]]
function PreloadList.worldHubKeys(worldId: string): { string }
	if worldId == MAIN then
		return PreloadList.hubKeys()
	end
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local hub = worldHub(worldId)
	if hub ~= nil then
		local firstWave: { any } = {}
		for _, entry in if type(hub.models) == "table" then hub.models else {} do
			if type(entry) == "table" and type(entry.key) == "string" and not isWorldDeferred(hub, entry.key) then
				table.insert(firstWave, entry)
			end
		end
		addModels(out, seen, firstWave)
		addModels(out, seen, type(hub.plotFrame) == "table" and hub.plotFrame.models or nil)
		addModels(out, seen, type(hub.lockedSlot) == "table" and hub.lockedSlot.models or nil)
	end
	addModels(out, seen, { { key = "BuyPad" } })
	return out
end

--[[
	R57: the mesh KEYS a client preloads when it travels to a world (WorldClient, on the "out"
	phase): that world's first-view hub keys, then the plot's bought builds in build order (the
	traveller's own plot state when known). Deduped; pass to contentIds for content ids.
	@param worldId string — "main", "dino", ...
	@param tycoon any? — the plot's tycoon state in that world (profile.worlds.dino.tycoon)
	@return {string}
	Example: ContentProvider:PreloadAsync(PreloadList.contentIds(PreloadList.world("dino", dinoTycoon)))
]]
function PreloadList.world(worldId: string, tycoon: any?): { string }
	local keys = PreloadList.worldHubKeys(worldId)
	if tycoon == nil then
		return keys
	end
	local seen: { [string]: boolean } = {}
	for _, key in keys do
		seen[key] = true
	end
	for _, key in PreloadList.plotKeys(tycoon, worldId) do
		if not seen[key] then
			seen[key] = true
			table.insert(keys, key)
		end
	end
	return keys
end

return PreloadList
