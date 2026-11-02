--!strict
--[[
	WorldsConfig — the registry of every world (World 2 plan §3.1, spec §18 "the worlds framework").

	Purpose
		ONE place that lists the worlds (Nuke Town "main", Dino Valley "dino", Moon Base "moon") in display order
		with everything a system needs to run them: economy (EconomyIndex), rebirth track, geometry,
		currencies, unlock rule, cross-world link, Nuke-Town-only feature switches, art paths,
		ambience presets and eggs. Every list of worlds in the game iterates `WorldsConfig.Order`, so
		adding World 3 is config + art only (spec §18).

		Ids are globally unique and prefixed (pads d3_..., producers dp3_..., build keys D3_...), so a
		bare id always tells its world: `worldOfPad` / `worldOfProducer` / `worldOfBuildKey` /
		`worldOfCurrency` answer in O(1) from maps built at load.

	Pure maths (server-authoritative callers; clients only display):
		unlockPasses(def, progress)   spec §4.1 — sticky unlock rule against per-world progress
		linkCash(worldId, rebirths)   spec §6.5 — the `Modifiers.linkCash` of a world:
		  main:  1 + Σ_w link_w.toMainPerRebirth   * min(rebirths[w],   link_w.toMainMaxRebirths)
		  w:     1 +     link_w.fromMainPerRebirth * min(rebirths.main, link_w.fromMainMaxRebirths)
		  (rebirth counts are sanitised: non-numbers / NaN / negative -> 0, floored; result >= 1)

	Load-time validation (errors loudly): Order == WorldGeometry.Order; def.id / def.order match their
	slot; ids ^[a-z][a-z0-9]{0,15}$ and <= MaxWorlds (the save cap); Nuke Town first, always open,
	no link; id prefixes, pad / producer / build-key ids, currency + token keys and egg ids unique
	across worlds (currency keys never collide with other profile currencies); geometry.areaCount
	== #economy.Areas; link numbers finite and non-negative with whole caps; unlock rules reference
	a known world + an area in range; art paths non-empty.

	Connections
		* Types: `Worlds/WorldTypes` (re-exported below).
		* Worlds: `Worlds/MainWorld`, `Worlds/Dino/DinoWorld` (+ DinoRebirth, Areas/AreaNN).
		* `Shared/Tycoon/TycoonLogic.forWorld(id)` binds `def.economy` + `def.rebirth`.
		* Server: WorldService / TravelRules / TycoonService / RebirthService / OfflineService (W3/W4),
		  ProfileLogic world keys (W2); client: WorldClient / Teleport tabs / HUD currency (W5),
		  WorldLookup (W10); analytics allowlists (W12); pets / eggs (W11).

	Usage
		local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
		for _, worldId in WorldsConfig.Order do
			local def = WorldsConfig.get(worldId)
			print(def.name, def.currency.name)
		end
		local mods = { rebirths = dino.rebirths, rebirthShop = dino.rebirthShop,
			linkCash = WorldsConfig.linkCash("dino", { main = profile.rebirths, dino = dino.rebirths }) }
]]

local DinoWorld = require(script.Parent.Dino.DinoWorld)
local EconomyIndex = require(script.Parent.Parent.Parent.Tycoon.EconomyIndex)
local MainWorld = require(script.Parent.MainWorld)
local MoonWorld = require(script.Parent.Moon.MoonWorld)
local WorldGeometry = require(script.Parent.WorldGeometry)
local WorldTypes = require(script.Parent.WorldTypes)

export type CurrencyDef = WorldTypes.CurrencyDef
export type UnlockRule = WorldTypes.UnlockRule
export type LinkDef = WorldTypes.LinkDef
export type WorldFeatures = WorldTypes.WorldFeatures
export type WorldAmbience = WorldTypes.WorldAmbience
export type WorldDef = WorldTypes.WorldDef

-- Per-world progress the unlock rules read: highest unlocked area + rebirth count in that world.
export type WorldProgress = { area: number, rebirths: number }

local WorldsConfig = {}

-- Nuke Town's id: the world every player starts in and the default for every optional worldId.
WorldsConfig.MAIN = "main"

-- Most worlds a save may hold (profile.worlds cap, spec §10); the registry may never exceed it.
WorldsConfig.MaxWorlds = 8

-- World id format: the save key of profile.worlds[id] (spec §10).
WorldsConfig.IdPattern = "^[a-z][a-z0-9]*$"
WorldsConfig.MaxIdLength = 16

-- Profile currency keys that are not world currencies (a world currency must never reuse one).
WorldsConfig.ReservedCurrencyKeys = table.freeze({ gems = true, acorns = true, robux = true }) :: { [string]: boolean }

-- Every world, in display order (tabs, Welcome Back rows, admin enums, analytics families).
WorldsConfig.Order = table.freeze({ "main", "dino", "moon" }) :: { string }

local WORLDS: { [string]: WorldDef } = {
	main = MainWorld,
	dino = DinoWorld,
	moon = MoonWorld, -- R70 World 3 (R69–R71 spec §2)
}
WorldsConfig.Worlds = WORLDS

-- Load-time lookups (built + validated below, then frozen).
local EXTRA: { WorldDef } = {}
local PAD_WORLD: { [string]: string } = {}
local PRODUCER_WORLD: { [string]: string } = {}
local BUILD_KEY_WORLD: { [string]: string } = {}
local BUILD_PREFIX_WORLD: { [string]: string } = {}
local CURRENCY_WORLD: { [string]: string } = {}
local EGG_WORLD: { [string]: string } = {}

--[[
	The definition of a world.
	@param id unknown — world id (untrusted input is fine: non-strings / unknown ids -> nil)
	@return WorldDef?
	Example: WorldsConfig.get("dino").name --> "Dino Valley"; WorldsConfig.get(5) --> nil
]]
function WorldsConfig.get(id: unknown): WorldDef?
	if type(id) ~= "string" then
		return nil
	end
	return WORLDS[id]
end

--[[
	Every non-main world, in Order (frozen list — never mutate).
	@return {WorldDef}
	Example: for _, def in WorldsConfig.extra() do print(def.id) end --> dino
]]
function WorldsConfig.extra(): { WorldDef }
	return EXTRA
end

--[[
	Which world a pad id belongs to.
	@param padId unknown
	@return string? — "main" for "a1_workbench", "dino" for "d3_wind_sock", nil for unknown ids
]]
function WorldsConfig.worldOfPad(padId: unknown): string?
	if type(padId) ~= "string" then
		return nil
	end
	return PAD_WORLD[padId]
end

--[[
	Which world a producer id belongs to.
	@param producerId unknown
	@return string? — "main" for "p1_workbench", "dino" for "dp3_ptero_express", nil otherwise
]]
function WorldsConfig.worldOfProducer(producerId: unknown): string?
	if type(producerId) ~= "string" then
		return nil
	end
	return PRODUCER_WORLD[producerId]
end

--[[
	Which world a build key belongs to: exact pad build keys first ("D3_WindSock"), then any
	well-formed key by its prefix letter ("D1_Base", a layout-only key -> "dino"; "A4_Foo" -> "main").
	@param key unknown
	@return string?
]]
function WorldsConfig.worldOfBuildKey(key: unknown): string?
	if type(key) ~= "string" then
		return nil
	end
	local exact = BUILD_KEY_WORLD[key]
	if exact ~= nil then
		return exact
	end
	local letter = string.match(key, "^(%u)%d+_%w+$")
	return if letter then BUILD_PREFIX_WORLD[letter] else nil
end

--[[
	Which world a currency (or rebirth-token) key belongs to.
	@param currencyKey unknown
	@return string? — "cash" / "tokens" -> "main", "bones" / "amber" -> "dino", "gems" -> nil
]]
function WorldsConfig.worldOfCurrency(currencyKey: unknown): string?
	if type(currencyKey) ~= "string" then
		return nil
	end
	return CURRENCY_WORLD[currencyKey]
end

--[[
	Which world sells an egg (the world whose hub has its stand).
	@param eggId unknown
	@return string? — "main" for "garage_egg", "dino" for "dino_egg", nil otherwise
]]
function WorldsConfig.worldOfEgg(eggId: unknown): string?
	if type(eggId) ~= "string" then
		return nil
	end
	return EGG_WORLD[eggId]
end

-- A sanitised whole count >= 0 (non-numbers, NaN, inf and negatives count as 0).
local function count(x: any): number
	if type(x) ~= "number" or x ~= x or x == math.huge or x <= 0 then
		return 0
	end
	return math.floor(x)
end

--[[
	Whether a world's unlock rule passes for a player's progress (spec §4.1). The server keeps the
	result sticky (profile.worlds[id].unlocked); this is the pure check.
	@param def WorldDef
	@param progress {[worldId]: { area: number, rebirths: number }} — per-world highest unlocked
	       area (tycoon.area) and rebirth count; missing / garbage entries count as nothing
	@return boolean
	Example: WorldsConfig.unlockPasses(dino, { main = { area = 3, rebirths = 0 } }) --> true
]]
function WorldsConfig.unlockPasses(def: WorldDef, progress: { [string]: WorldProgress }): boolean
	local rule = def.unlock
	if rule.kind == "always" then
		return true
	end
	if type(progress) ~= "table" then
		return false
	end
	local entry: any = progress[rule.world]
	if type(entry) ~= "table" then
		return false
	end
	if count(entry.area) >= rule.area then
		return true
	end
	local orRebirths = rule.orRebirths
	return orRebirths ~= nil and count(entry.rebirths) >= orRebirths
end

--[[
	The cross-world link multiplier of a world (spec §6.5) — the `linkCash` field of that world's
	Modifiers. Pure and monotonic: more rebirths anywhere never lowers it; always >= 1.
	@param worldId string — the world being evaluated ("main" or a world with a link)
	@param rebirthsByWorld {[worldId]: number} — rebirth counts per world (untrusted values are
	       sanitised; missing worlds count 0)
	@return number — >= 1; 1 for unknown worlds / worlds without a link
	Example: WorldsConfig.linkCash("main", { dino = 3 }) --> 1.3
	         WorldsConfig.linkCash("dino", { main = 5 }) --> 1.25
]]
function WorldsConfig.linkCash(worldId: string, rebirthsByWorld: { [string]: number }): number
	local rebirths: { [string]: any } = if type(rebirthsByWorld) == "table" then rebirthsByWorld else {}
	if worldId == WorldsConfig.MAIN then
		local bonus = 0
		for _, def in EXTRA do
			local link = def.link
			if link ~= nil then
				bonus += link.toMainPerRebirth * math.min(count(rebirths[def.id]), link.toMainMaxRebirths)
			end
		end
		return 1 + bonus
	end
	local def = WorldsConfig.get(worldId)
	local link = if def then def.link else nil
	if link == nil then
		return 1
	end
	return 1 + link.fromMainPerRebirth * math.min(count(rebirths[WorldsConfig.MAIN]), link.fromMainMaxRebirths)
end

--------------------------------------------------------------------------------------------------
-- Load-time validation + lookup maps
--------------------------------------------------------------------------------------------------
do
	local function finite(x: any): boolean
		return type(x) == "number" and x == x and x > -math.huge and x < math.huge
	end
	local function nonEmptyPath(path: any): boolean
		if type(path) ~= "table" or #path == 0 then
			return false
		end
		for _, part in path do
			if type(part) ~= "string" or string.match(part, "^%u%w*$") == nil then
				return false
			end
		end
		return true
	end

	local order = WorldsConfig.Order
	assert(#order >= 1 and #order <= WorldsConfig.MaxWorlds, "WorldsConfig: 1..MaxWorlds worlds")
	assert(order[1] == WorldsConfig.MAIN, "WorldsConfig: Nuke Town (main) must be first")
	assert(#order == #WorldGeometry.Order, "WorldsConfig: Order must match WorldGeometry.Order")
	local prefixes: { [string]: string } = {}
	local seen: { [string]: boolean } = {}
	for position, id in order do
		local def = WORLDS[id]
		local tag = `WorldsConfig({id})`
		assert(def ~= nil and def.id == id and not seen[id], `{tag}: missing or duplicate world`)
		seen[id] = true
		assert(
			string.match(id, WorldsConfig.IdPattern) ~= nil and #id <= WorldsConfig.MaxIdLength,
			`{tag}: id must be a lowercase letter + up to 15 lowercase letters / digits`
		)
		assert(WorldGeometry.Order[position] == id, `{tag}: WorldGeometry.Order[{position}] must be {id}`)
		assert(def.order == position, `{tag}: order {def.order} ~= its Order position {position}`)
		assert(type(def.name) == "string" and #def.name > 0 and #def.name <= 24, `{tag}: name 1..24 chars`)
		assert(type(def.tagline) == "string" and #def.tagline > 0, `{tag}: needs a tagline`)

		-- Economy + geometry + rebirth agree with each other.
		local economy = def.economy
		assert(economy.WorldId == id, `{tag}: economy.WorldId {economy.WorldId}`)
		assert(economy.IdPrefix == def.idPrefix, `{tag}: economy idPrefix mismatch`)
		assert(def.geometry == WorldGeometry.get(id), `{tag}: geometry must be WorldGeometry.get({id})`)
		assert(def.geometry.areaCount == #economy.Areas, `{tag}: geometry.areaCount ~= #economy.Areas`)
		assert(def.rebirth.Shop ~= nil and #def.rebirth.ShopOrder >= 1, `{tag}: needs a rebirth shop`)
		local _, _, buildPrefix = EconomyIndex.prefixes(def.idPrefix)
		assert(prefixes[buildPrefix] == nil, `{tag}: id prefix {buildPrefix} already used by {prefixes[buildPrefix]}`)
		prefixes[buildPrefix] = id
		BUILD_PREFIX_WORLD[buildPrefix] = id

		-- Ids unique across worlds (prefixes make this true by construction; checked anyway).
		for padId, pad in economy.PadsById do
			assert(PAD_WORLD[padId] == nil, `{tag}: pad id {padId} also in {PAD_WORLD[padId]}`)
			PAD_WORLD[padId] = id
			assert(BUILD_KEY_WORLD[pad.build] == nil, `{tag}: build key {pad.build} also in another world`)
			BUILD_KEY_WORLD[pad.build] = id
		end
		for producerId in economy.ProducersById do
			assert(PRODUCER_WORLD[producerId] == nil, `{tag}: producer id {producerId} also in another world`)
			PRODUCER_WORLD[producerId] = id
		end

		-- Currencies: unique keys across worlds, never a non-world profile currency.
		for _, currency in { def.currency, def.tokens } do
			local key = currency.key
			assert(string.match(key, "^[a-z][a-zA-Z0-9]*$") ~= nil, `{tag}: bad currency key {key}`)
			assert(not WorldsConfig.ReservedCurrencyKeys[key], `{tag}: currency key {key} is reserved`)
			assert(CURRENCY_WORLD[key] == nil, `{tag}: currency key {key} also used by {CURRENCY_WORLD[key]}`)
			CURRENCY_WORLD[key] = id
			assert(#currency.name > 0 and #currency.icon > 0, `{tag}: currency {key} needs a name + icon`)
			assert(currency.style == "money" or currency.style == "count", `{tag}: currency {key} style`)
		end

		-- Unlock rule.
		local rule = def.unlock
		if id == WorldsConfig.MAIN then
			assert(rule.kind == "always", `{tag}: Nuke Town is always open`)
			assert(def.link == nil, `{tag}: Nuke Town has no link (other worlds link to it)`)
			assert(def.portalAnchor == nil, `{tag}: Nuke Town has no portal anchor`)
		else
			assert(rule.kind == "progress", `{tag}: non-main worlds unlock by progress`)
			assert(type(def.portalAnchor) == "string" and #def.portalAnchor > 0, `{tag}: needs a portalAnchor`)
		end
		if rule.kind == "progress" then
			local target = WORLDS[rule.world]
			assert(target ~= nil and rule.world ~= id, `{tag}: unlock references unknown world {rule.world}`)
			assert(
				finite(rule.area) and rule.area % 1 == 0 and rule.area >= 1 and rule.area <= #target.economy.Areas,
				`{tag}: unlock area {rule.area} outside 1..{#target.economy.Areas}`
			)
			local orRebirths = rule.orRebirths
			assert(
				orRebirths == nil or (finite(orRebirths) and orRebirths % 1 == 0 and orRebirths >= 1),
				`{tag}: unlock orRebirths must be a whole number >= 1`
			)
		end

		-- Link (finite, non-negative, whole caps).
		local link = def.link
		if link ~= nil then
			for _, key in { "toMainPerRebirth", "fromMainPerRebirth" } do
				local value = (link :: any)[key]
				assert(finite(value) and value >= 0 and value <= 10, `{tag}: link.{key} must be in [0, 10]`)
			end
			for _, key in { "toMainMaxRebirths", "fromMainMaxRebirths" } do
				local value = (link :: any)[key]
				assert(finite(value) and value % 1 == 0 and value >= 0 and value <= 1000, `{tag}: link.{key}`)
			end
		end

		-- Art + presentation.
		assert(nonEmptyPath(def.layoutFolder), `{tag}: layoutFolder must be a path of module names`)
		assert(nonEmptyPath(def.hubLayout), `{tag}: hubLayout must be a path of module names`)
		assert(#def.ambience.lighting > 0 and #def.ambience.music > 0, `{tag}: needs ambience presets`)
		assert(#def.eggs >= 1, `{tag}: needs at least one egg`)
		for _, eggId in def.eggs do
			assert(string.match(eggId, "^[a-z][a-z0-9_]*$") ~= nil, `{tag}: bad egg id {eggId}`)
			assert(EGG_WORLD[eggId] == nil, `{tag}: egg {eggId} also sold in {EGG_WORLD[eggId]}`)
			EGG_WORLD[eggId] = id
		end

		if id ~= WorldsConfig.MAIN then
			table.insert(EXTRA, def)
		end

		-- Static data: freeze the definition (economy / rebirth / geometry are already frozen).
		table.freeze(def.currency)
		table.freeze(def.tokens)
		table.freeze(def.unlock)
		if link ~= nil then
			table.freeze(link)
		end
		table.freeze(def.features)
		table.freeze(def.layoutFolder)
		table.freeze(def.hubLayout)
		table.freeze(def.ambience)
		table.freeze(def.eggs)
		table.freeze(def)
	end
	for id in WORLDS do
		assert(seen[id], `WorldsConfig: world {id} missing from Order`)
	end
	table.freeze(WORLDS)
	table.freeze(EXTRA)
	table.freeze(PAD_WORLD)
	table.freeze(PRODUCER_WORLD)
	table.freeze(BUILD_KEY_WORLD)
	table.freeze(BUILD_PREFIX_WORLD)
	table.freeze(CURRENCY_WORLD)
	table.freeze(EGG_WORLD)
end

return table.freeze(WorldsConfig)
