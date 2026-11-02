--!strict
--[[
	LayoutLogic — the area-layout contract as types, plus pure validation and merging.

	Purpose
		Art builders write one layout per area (src/shared/Config/AreaLayouts/AreaNN.luau, build plan
		"World layout"). This module is the single definition of that shape and of the rules a layout
		must follow, used by:
		  * tests/area-layouts.luau — fails the build when a committed layout breaks the contract;
		  * Tycoon/AreaLayouts — at runtime a layout is validated, and anything missing (a build key,
		    a pad position, the producer) is filled from the generated placeholder so the area stays
		    fully playable while art is still being authored.
		Pure: no Instances, no services (CFrame / Vector3 / Color3 only), runs under Lune.

	Layout (all CFrames / points SLOT-LOCAL, see Shared/Config/WorldLayout):
		{
			area = N,
			base = { models = { ModelEntry }, collision = { CollisionEntry }? },   -- built with the area
			builds = { [buildKey] = { models = {...}, collision = {...}? } },        -- the area's own A{N}_* keys
			pads = { [padId] = Vector3 },                                            -- BuyPad ground position
			producer = { anchor = Vector3, click = { size = Vector3, cf = CFrame } }, -- billboard + click box
			spawnPoint = Vector3,                                                    -- teleport target
		}
		ModelEntry   = { key = "MeshModelKey", cf = CFrame, tint = Color3?, castShadow = boolean?,
		                 collide = boolean? }        -- collide: add an invisible box from the mesh bounds
		             | { box = Vector3, cf = CFrame, color = Color3, collide = boolean?,
		                 shape = "Block" | "Cylinder" | "Ball"?, material = string?, label = string? }
		               (primitive entries are what placeholders use; art layouts use mesh keys)
		CollisionEntry = { size = Vector3, cf = CFrame }  -- invisible, anchored, collidable

	Entry-arch convention (lead, 2026-10-30): the Unlock pad of area N has build key
	`A{N+1}_EntryArch`; it resolves to Area{N+1}.base (the next area's floor + arch, built with
	BuildIn when the Unlock pad is bought). So AreaNN.builds holds only area N's own keys
	(`LayoutLogic.ownBuildKeys`), and Area01.base is built when the plot is claimed. The finale's
	Unlock pad (Golden Atom, no `unlocks`) is an ordinary build of area 10.
	Extra top-level fields (e.g. `aaTowerMount` for attack mode) are allowed and passed through.

	Worlds (owner R57, plan §3.3): every world reuses this contract unchanged (same slot size, pad
	strip and height budget; only the finale slot's height comes from that world's geometry). Dino
	Valley's layouts live in Shared/Config/Worlds/Dino/Layouts/AreaNN with `D{N}_*` build keys; pass
	the worldId to `validate` so the finale slot (D6) gets its 140-stud budget.

	Usage
		local problems = LayoutLogic.validate(layout, TycoonConfig.Areas[3], meshKeySet)
		local full = LayoutLogic.merge(layout, PlaceholderLayouts.generate(3))
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

export type ModelEntry = {
	key: string?,
	cf: CFrame,
	tint: Color3?,
	castShadow: boolean?,
	collide: boolean?,
	box: Vector3?,
	color: Color3?,
	shape: ("Block" | "Cylinder" | "Ball")?,
	material: string?,
	label: string?,
}
export type CollisionEntry = { size: Vector3, cf: CFrame }
export type BuildEntry = { models: { ModelEntry }, collision: { CollisionEntry }? }
export type ProducerEntry = { anchor: Vector3, click: { size: Vector3, cf: CFrame } }
export type AreaLayout = {
	area: number,
	base: BuildEntry,
	builds: { [string]: BuildEntry },
	pads: { [string]: Vector3 },
	producer: ProducerEntry,
	spawnPoint: Vector3,
	-- Set by Tycoon/AreaLayouts (never by art files): true when generated, and the merged-in parts.
	placeholder: boolean?,
	filled: { string }?,
}

local LayoutLogic = {}

-- Studs of tolerance when checking that content stays inside its slot (overhangs, roofs).
LayoutLogic.BoundsMargin = 6

-- True for a real, finite number.
local function finite(x: any): boolean
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

-- True for a Vector3 with finite components.
local function isVector(v: any): boolean
	return typeof(v) == "Vector3" and finite(v.X) and finite(v.Y) and finite(v.Z)
end

-- True for a Vector3 with finite, strictly positive components.
local function isSize(v: any): boolean
	return isVector(v) and v.X > 0 and v.Y > 0 and v.Z > 0
end

-- True for a CFrame with a finite position.
local function isCFrame(v: any): boolean
	return typeof(v) == "CFrame" and isVector(v.Position)
end

--[[
	True when a pad's build key resolves to the NEXT area's base (an Unlock pad that opens an
	area), not to a build of its own area (entry-arch convention, see the header).
	@param pad PadConfig
	@return boolean
]]
function LayoutLogic.opensArea(pad: TycoonTypes.PadConfig): boolean
	return pad.kind == "Unlock" and pad.unlocks ~= nil
end

--[[
	The build keys an area's layout must provide in `builds` (in pad order): every pad build key of
	the area except the Unlock pad that opens the next area (that one is the next area's base).
	@param area AreaConfig
	@return {string}
]]
function LayoutLogic.ownBuildKeys(area: TycoonTypes.AreaConfig): { string }
	local keys: { string } = {}
	for _, pad in area.pads do
		if not LayoutLogic.opensArea(pad) then
			table.insert(keys, pad.build)
		end
	end
	return keys
end

--[[
	Validates one build entry (base or a build key); appends problems.
	@param entry any — untrusted table from a layout file
	@param where string — path for messages ("builds.A1_ToolWall")
	@param area number — slot index (bounds)
	@param meshKeys {[string]: any}? — known MeshAssets keys (nil = do not check keys)
	@param problems {string}
	@param worldId string? — the world whose slot geometry applies (finale height); nil = Nuke Town
]]
local function validateBuild(
	entry: any,
	where: string,
	area: number,
	meshKeys: { [string]: any }?,
	problems: { string },
	worldId: string?
)
	if type(entry) ~= "table" or type(entry.models) ~= "table" then
		table.insert(problems, `{where}: needs a models list`)
		return
	end
	for index, model in entry.models do
		local path = `{where}.models[{index}]`
		if type(model) ~= "table" or not isCFrame(model.cf) then
			table.insert(problems, `{path}: needs cf = CFrame`)
			continue
		end
		if model.key ~= nil then
			if type(model.key) ~= "string" or model.key == "" then
				table.insert(problems, `{path}: key must be a non-empty string`)
			elseif meshKeys ~= nil and meshKeys[model.key] == nil then
				table.insert(problems, `{path}: unknown mesh key {model.key} (not in MeshAssets)`)
			end
		elseif not isSize(model.box) then
			table.insert(problems, `{path}: needs key = "MeshKey" (or a placeholder box = Vector3)`)
		end
		if not WorldLayout.inSlot(area, model.cf.Position, LayoutLogic.BoundsMargin, worldId) then
			table.insert(problems, `{path}: {model.cf.Position} is outside slot {area}`)
		end
		if model.tint ~= nil and typeof(model.tint) ~= "Color3" then
			table.insert(problems, `{path}: tint must be a Color3`)
		end
	end
	if entry.collision ~= nil then
		if type(entry.collision) ~= "table" then
			table.insert(problems, `{where}.collision must be a list`)
			return
		end
		for index, box in entry.collision do
			local path = `{where}.collision[{index}]`
			if type(box) ~= "table" or not isSize(box.size) or not isCFrame(box.cf) then
				table.insert(problems, `{path}: needs size = Vector3 (> 0) and cf = CFrame`)
			elseif not WorldLayout.inSlot(area, box.cf.Position, LayoutLogic.BoundsMargin, worldId) then
				table.insert(problems, `{path}: {box.cf.Position} is outside slot {area}`)
			end
		end
	end
end

--[[
	Checks a layout against the contract and its area config.
	@param layout any — the table an AreaNN.luau file returned (untrusted shape)
	@param area AreaConfig — TycoonConfig.Areas[N]
	@param meshKeys {[string]: any}? — MeshAssets (to check model keys exist); nil skips that check
	@param partial boolean? — true: missing builds / pads / producer / spawnPoint are not problems
	                          (runtime merge fills them from the placeholder); shape errors still are
	@param worldId string? — R57: the world the layout belongs to (slot height: Dino's finale D6 is
	                          140 tall like Nuke Town's area 10); nil = Nuke Town (unchanged)
	@return {string} — problems (empty = valid)
	Example: assert(#LayoutLogic.validate(require(AreaLayouts.Area01), TycoonConfig.Areas[1], MeshAssets) == 0)
]]
function LayoutLogic.validate(
	layout: any,
	area: TycoonTypes.AreaConfig,
	meshKeys: { [string]: any }?,
	partial: boolean?,
	worldId: string?
): { string }
	local problems: { string } = {}
	if type(layout) ~= "table" then
		return { "layout must be a table" }
	end
	local index = area.index
	if layout.area ~= index then
		table.insert(problems, `area = {tostring(layout.area)}, expected {index}`)
	end

	if layout.base ~= nil or not partial then
		validateBuild(layout.base, "base", index, meshKeys, problems, worldId)
	end

	-- Builds: every build key of the area's pads; nothing else.
	local expected: { [string]: boolean } = {}
	for _, key in LayoutLogic.ownBuildKeys(area) do
		expected[key] = true
	end
	if type(layout.builds) ~= "table" then
		if not partial then
			table.insert(problems, "builds: needs a table keyed by build key")
		end
	else
		for key in expected do
			if layout.builds[key] == nil then
				if not partial then
					table.insert(problems, `builds.{key}: missing (every pad build key needs an entry)`)
				end
			else
				validateBuild(layout.builds[key], `builds.{key}`, index, meshKeys, problems, worldId)
			end
		end
		for key in layout.builds do
			if not expected[key] then
				table.insert(
					problems,
					`builds.{tostring(key)}: not an own build key of area {index} (EntryArch keys are the next area's base)`
				)
			end
		end
	end

	-- Pads: every pad of the area, inside the road-side strip.
	if type(layout.pads) ~= "table" then
		if not partial then
			table.insert(problems, "pads: needs a table keyed by pad id")
		end
	else
		for _, pad in area.pads do
			local point = layout.pads[pad.id]
			if point == nil then
				if not partial then
					table.insert(problems, `pads.{pad.id}: missing`)
				end
			elseif not isVector(point) then
				table.insert(problems, `pads.{pad.id}: must be a Vector3`)
			elseif
				math.abs(point.X) > WorldLayout.SlotHalfWidth
				or point.Z < WorldLayout.PadStripMin
				or point.Z > WorldLayout.PadStripMax
				or math.abs(point.Y) > 4
			then
				table.insert(problems, `pads.{pad.id}: {point} outside the pad strip (|x| <= 52, 2 <= z <= 16)`)
			end
		end
		local areaPadIds: { [string]: boolean } = {}
		for _, pad in area.pads do
			areaPadIds[pad.id] = true
		end
		for padId in layout.pads do
			if not areaPadIds[padId] then
				table.insert(problems, `pads.{tostring(padId)}: not a pad of area {index}`)
			end
		end
	end

	-- Producer anchor + click box.
	local producer = layout.producer
	if producer == nil then
		if not partial then
			table.insert(problems, "producer: needs { anchor = Vector3, click = { size, cf } }")
		end
	elseif type(producer) ~= "table" or not isVector(producer.anchor) then
		table.insert(problems, "producer.anchor: must be a Vector3")
	else
		if not WorldLayout.inSlot(index, producer.anchor, LayoutLogic.BoundsMargin, worldId) then
			table.insert(problems, `producer.anchor: {producer.anchor} is outside slot {index}`)
		end
		local click = producer.click
		if type(click) ~= "table" or not isSize(click.size) or not isCFrame(click.cf) then
			table.insert(problems, "producer.click: needs size = Vector3 (> 0) and cf = CFrame")
		elseif not WorldLayout.inSlot(index, click.cf.Position, LayoutLogic.BoundsMargin, worldId) then
			table.insert(problems, `producer.click: {click.cf.Position} is outside slot {index}`)
		end
	end

	-- Teleport target.
	if layout.spawnPoint == nil then
		if not partial then
			table.insert(problems, "spawnPoint: needs a Vector3")
		end
	elseif not isVector(layout.spawnPoint) or not WorldLayout.inSlot(index, layout.spawnPoint, 0, worldId) then
		table.insert(problems, "spawnPoint: must be a Vector3 inside the slot")
	end
	return problems
end

--[[
	Fills every missing part of an authored (possibly partial) layout from a complete fallback
	(the generated placeholder). Authored entries always win; nothing is mutated. Unknown top-level
	fields of the authored layout (e.g. attack-mode mounts) are copied through unchanged.
	@param authored any — a layout that passed validate(..., partial = true)
	@param fallback AreaLayout — complete (PlaceholderLayouts.generate)
	@return AreaLayout, {string} — the merged layout and the list of parts that came from the fallback
]]
function LayoutLogic.merge(authored: any, fallback: AreaLayout): (AreaLayout, { string })
	local filled: { string } = {}
	local builds: { [string]: BuildEntry } = {}
	for key, entry in fallback.builds do
		local own = if type(authored.builds) == "table" then authored.builds[key] else nil
		if own ~= nil then
			builds[key] = own
		else
			builds[key] = entry
			table.insert(filled, `builds.{key}`)
		end
	end
	local pads: { [string]: Vector3 } = {}
	for padId, point in fallback.pads do
		local own = if type(authored.pads) == "table" then authored.pads[padId] else nil
		if own ~= nil then
			pads[padId] = own
		else
			pads[padId] = point
			table.insert(filled, `pads.{padId}`)
		end
	end
	local function pick<T>(own: T?, default: T, name: string): T
		if own ~= nil then
			return own
		end
		table.insert(filled, name)
		return default
	end
	local merged: AreaLayout = {
		area = fallback.area,
		base = pick(authored.base, fallback.base, "base"),
		builds = builds,
		pads = pads,
		producer = pick(authored.producer, fallback.producer, "producer"),
		spawnPoint = pick(authored.spawnPoint, fallback.spawnPoint, "spawnPoint"),
		placeholder = false,
		filled = filled,
	}
	local known = { area = true, base = true, builds = true, pads = true, producer = true, spawnPoint = true }
	for key, value in authored do
		if type(key) == "string" and not known[key] and (merged :: any)[key] == nil then
			(merged :: any)[key] = value
		end
	end
	return merged, filled
end

return LayoutLogic
