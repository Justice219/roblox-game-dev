--!strict
--[[
	EventDecor — everything the Harvest Feast puts INTO the world (server side, docs/event.md):

		1. The Golden Turkey TEMPLATE in ReplicatedStorage.HarvestFeast.GoldenTurkey: the Blender
		   mesh (MeshLibrary, key EventConfig.Models.Turkey) or a cute primitive fallback, plus an
		   invisible "Hitbox" (PrimaryPart; click / tap / prompt target) and a golden sparkle
		   emitter. Clients clone it per turkey (no server turkey instances exist).
		2. The HUB EVENT SQUARE decor, shown by date: built while the event is active from
		   HubLayout.event.harvest (B8e: arch with a "HARVEST FEAST" sign, cornucopia, turkey statue,
		   pie stand, Harvest egg stand, string lights, hay bales, pumpkins, autumn trees + their
		   colliders; HubBuilder skips this group) or a primitive fallback square, destroyed after.
		3. PLOT DECORATIONS bought with acorns (EventConfig.Decor): built on the owner's plot at the
		   decor slots (EventConfig.DecorSlots: area 1's front lawn + over the entrance road;
		   HubLayout.plotDecor overrides), snapped to the ground, with one collision box each. A
		   fresh purchase is tagged for the LEGO build-in (owner rule 4, BuildInConfig); a rejoin /
		   plot change just shows the finished set. Decorations are permanent (kept after the event;
		   kid-friendly: never take a purchase away).

	Fallback art is primitive Parts dressed with the stud material (WorldMaterials.apply), owner
	rule 3: primitives only until the Blender meshes are uploaded. Mesh keys come from server
	config only, never from clients.

	Performance: everything is anchored, non-colliding visuals (CanQuery / CanTouch off) except the
	invisible collision boxes; models are parented once complete; Atomic streaming; no per-frame
	work. MeshLibrary.spawn may yield while templates load: callers run these in task.spawn.

	Example:
		EventDecor.ensureTurkeyTemplate()
		EventDecor.setHubActive(true)
		EventDecor.showPlotDecor(player.UserId, 3, { HayBales = true }, "HayBales")
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local BuildInConfig = require(ReplicatedStorage.Shared.Config.BuildInConfig)
local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local Lazy = require(script.Parent.Lazy)
local MeshLibrary = require(ServerScriptService.Server.World.MeshLibrary)
local MeshPlacement = require(ReplicatedStorage.Shared.World.MeshPlacement)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldMaterials = require(ServerScriptService.Server.World.WorldMaterials)

-- One primitive piece of a fallback model (model-local CFrame, pivot at the ground centre).
type Piece = {
	shape: "Block" | "Ball" | "Cylinder" | "Wedge",
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: string?, -- WorldMaterials name (default "Studs")
	name: string?,
}

-- One HubLayout placement (B8e: Placement = { key, cf, name?, tint?, colors?, castShadow? }).
export type Placement = {
	key: string,
	cf: CFrame,
	name: string?,
	tint: Color3?,
	colors: { [string]: Color3 }?,
	castShadow: boolean?,
}

-- The Harvest Feast parts of HubLayout (B8e), type-checked; every field optional (nil-safe reads).
export type HubEvent = {
	square: CFrame?, -- anchors.EventSquare.cf (box centre; its position is the square's centre)
	turkeySpawns: { Vector3 }?, -- anchors.TurkeySpawnPoints (world, ground level)
	npc: CFrame?, -- the Harvest_TurkeyStatue placement (the "Sticker Sheet" prompt spot)
	models: { Placement }?, -- event.harvest.models
	collision: { { size: Vector3, cf: CFrame } }?, -- event.harvest.collision
}

local EventDecor = {}

-- ─── Palette + fallback art ───────────────────────────────────────────────────────────────────

local C = {
	hay = Color3.fromRGB(236, 196, 96),
	twine = Color3.fromRGB(156, 102, 52),
	pumpkin = Color3.fromRGB(247, 132, 34),
	stem = Color3.fromRGB(88, 146, 54),
	wood = Color3.fromRGB(122, 80, 46),
	gold = Color3.fromRGB(255, 202, 58),
	goldDark = Color3.fromRGB(224, 158, 36),
	red = Color3.fromRGB(222, 62, 52),
	orange = Color3.fromRGB(240, 120, 40),
	purple = Color3.fromRGB(132, 72, 164),
	green = Color3.fromRGB(112, 176, 64),
	shirt = Color3.fromRGB(70, 128, 210),
	skin = Color3.fromRGB(240, 210, 150),
	white = Color3.fromRGB(250, 250, 245),
	dark = Color3.fromRGB(40, 36, 44),
}

local function piece(
	shape: "Block" | "Ball" | "Cylinder" | "Wedge",
	size: Vector3,
	cf: CFrame,
	color: Color3,
	name: string?,
	material: string?
): Piece
	return { shape = shape, size = size, cf = cf, color = color, name = name, material = material }
end

-- A cartoon turkey (feet at y = 0, faces -Z), scaled by `s`. Used by the template + the statue.
local function turkeyPieces(s: number, body: Color3, accent: Color3): { Piece }
	local pieces: { Piece } = {
		piece("Ball", Vector3.new(3.2, 3.2, 3.2) * s, CFrame.new(0, 2.2 * s, 0.2 * s), body, "Body"),
		piece("Ball", Vector3.new(1.5, 1.5, 1.5) * s, CFrame.new(0, 3.7 * s, -1.3 * s), body, "Head"),
		piece(
			"Wedge",
			Vector3.new(0.5, 0.45, 0.7) * s,
			CFrame.new(0, 3.6 * s, -2.15 * s) * CFrame.Angles(0, math.pi, 0),
			C.orange,
			"Beak"
		),
		piece("Ball", Vector3.new(0.45, 0.8, 0.45) * s, CFrame.new(0.15 * s, 3.2 * s, -1.95 * s), C.red, "Wattle"),
		piece(
			"Ball",
			Vector3.new(0.35, 0.35, 0.35) * s,
			CFrame.new(-0.4 * s, 3.95 * s, -1.95 * s),
			C.dark,
			"EyeL",
			"Smooth"
		),
		piece(
			"Ball",
			Vector3.new(0.35, 0.35, 0.35) * s,
			CFrame.new(0.4 * s, 3.95 * s, -1.95 * s),
			C.dark,
			"EyeR",
			"Smooth"
		),
		piece(
			"Cylinder",
			Vector3.new(1.2, 0.3, 0.3) * s,
			CFrame.new(-0.6 * s, 0.6 * s, 0.1 * s) * CFrame.Angles(0, 0, math.pi / 2),
			C.orange,
			"LegL"
		),
		piece(
			"Cylinder",
			Vector3.new(1.2, 0.3, 0.3) * s,
			CFrame.new(0.6 * s, 0.6 * s, 0.1 * s) * CFrame.Angles(0, 0, math.pi / 2),
			C.orange,
			"LegR"
		),
	}
	-- Tail fan: five feathers fanned behind the body, alternating colours.
	for index = -2, 2 do
		local angle = math.rad(index * 24)
		table.insert(
			pieces,
			piece(
				"Block",
				Vector3.new(0.9, 3.2, 0.25) * s,
				CFrame.new(0, 2.6 * s, 1.75 * s) * CFrame.Angles(0, 0, angle) * CFrame.new(0, 1.0 * s, 0),
				if index % 2 == 0 then accent else C.red,
				`Tail{index + 3}`
			)
		)
	end
	return pieces
end

-- Fallback pieces per model key (used when MeshAssets has no entry for the key yet).
local FALLBACK: { [string]: { Piece } } = {
	GoldenTurkey = turkeyPieces(1, C.gold, C.orange),
	Harvest_HayBale = {
		piece("Block", Vector3.new(4, 2.4, 2.4), CFrame.new(-2.1, 1.2, 0), C.hay),
		piece("Block", Vector3.new(4, 2.4, 2.4), CFrame.new(2.1, 1.2, 0), C.hay),
		piece("Block", Vector3.new(4, 2.4, 2.4), CFrame.new(0, 3.6, 0), C.hay),
		piece("Block", Vector3.new(0.3, 2.5, 2.5), CFrame.new(-2.1, 1.2, 0), C.twine),
		piece("Block", Vector3.new(0.3, 2.5, 2.5), CFrame.new(2.1, 1.2, 0), C.twine),
		piece("Block", Vector3.new(0.3, 2.5, 2.5), CFrame.new(0, 3.6, 0), C.twine),
	},
	Harvest_PumpkinPile = {
		piece("Ball", Vector3.new(3.2, 2.6, 3.2), CFrame.new(-1.6, 1.3, 0.4), C.pumpkin),
		piece("Ball", Vector3.new(2.6, 2.2, 2.6), CFrame.new(1.5, 1.1, 0.3), C.pumpkin),
		piece("Ball", Vector3.new(2.2, 1.9, 2.2), CFrame.new(0, 3.0, 0.4), C.orange),
		piece("Ball", Vector3.new(1.6, 1.4, 1.6), CFrame.new(0.4, 0.7, -1.6), C.hay),
		piece(
			"Cylinder",
			Vector3.new(0.6, 0.3, 0.3),
			CFrame.new(-1.6, 2.8, 0.4) * CFrame.Angles(0, 0, math.pi / 2),
			C.stem
		),
		piece(
			"Cylinder",
			Vector3.new(0.6, 0.3, 0.3),
			CFrame.new(1.5, 2.4, 0.3) * CFrame.Angles(0, 0, math.pi / 2),
			C.stem
		),
		piece(
			"Cylinder",
			Vector3.new(0.5, 0.25, 0.25),
			CFrame.new(0, 4.1, 0.4) * CFrame.Angles(0, 0, math.pi / 2),
			C.stem
		),
	},
	Harvest_Scarecrow = {
		piece("Block", Vector3.new(0.5, 7, 0.5), CFrame.new(0, 3.5, 0), C.wood),
		piece("Block", Vector3.new(6, 0.5, 0.5), CFrame.new(0, 5.2, 0), C.wood),
		piece("Block", Vector3.new(2.4, 2.8, 1.4), CFrame.new(0, 4.6, 0), C.shirt),
		piece("Block", Vector3.new(1.6, 0.9, 1.0), CFrame.new(-2.4, 5.2, 0), C.shirt),
		piece("Block", Vector3.new(1.6, 0.9, 1.0), CFrame.new(2.4, 5.2, 0), C.shirt),
		piece("Ball", Vector3.new(1.9, 1.9, 1.9), CFrame.new(0, 7.0, 0), C.skin),
		piece(
			"Cylinder",
			Vector3.new(0.3, 3.0, 3.0),
			CFrame.new(0, 7.8, 0) * CFrame.Angles(0, 0, math.pi / 2),
			C.twine
		),
		piece(
			"Cylinder",
			Vector3.new(1.0, 1.4, 1.4),
			CFrame.new(0, 8.4, 0) * CFrame.Angles(0, 0, math.pi / 2),
			C.twine
		),
		piece("Block", Vector3.new(0.25, 0.25, 0.1), CFrame.new(-0.4, 7.2, -0.95), C.dark, nil, "Smooth"),
		piece("Block", Vector3.new(0.25, 0.25, 0.1), CFrame.new(0.4, 7.2, -0.95), C.dark, nil, "Smooth"),
	},
	Harvest_CornucopiaSmall = {
		piece(
			"Cylinder",
			Vector3.new(1.6, 3.2, 3.2),
			CFrame.new(0, 1.6, 0.6) * CFrame.Angles(0, math.pi / 2, 0),
			C.twine
		),
		piece(
			"Cylinder",
			Vector3.new(1.4, 2.4, 2.4),
			CFrame.new(0, 1.7, 1.9) * CFrame.Angles(0, math.pi / 2, 0),
			C.wood
		),
		piece(
			"Cylinder",
			Vector3.new(1.2, 1.5, 1.5),
			CFrame.new(0, 2.0, 3.0) * CFrame.Angles(0, math.pi / 2, 0),
			C.twine
		),
		piece(
			"Cylinder",
			Vector3.new(1.0, 0.7, 0.7),
			CFrame.new(0, 2.5, 3.8) * CFrame.Angles(0, math.pi / 2, 0),
			C.wood
		),
		piece("Ball", Vector3.new(1.3, 1.3, 1.3), CFrame.new(-0.6, 1.0, -1.0), C.red),
		piece("Ball", Vector3.new(1.4, 1.2, 1.4), CFrame.new(0.7, 0.9, -1.2), C.pumpkin),
		piece("Ball", Vector3.new(1.0, 1.0, 1.0), CFrame.new(0, 2.0, -0.8), C.purple),
		piece("Ball", Vector3.new(0.9, 1.6, 0.9), CFrame.new(1.1, 1.8, -0.4), C.hay),
	},
	Harvest_Garland = (function(): { Piece }
		-- Pivot on the road centre (B8e's Harvest_Garland convention): poles on the curbs, swag ~12.5 up.
		local pieces: { Piece } = {
			piece("Block", Vector3.new(18, 0.3, 0.3), CFrame.new(0, 12.5, 0), C.stem),
			piece(
				"Cylinder",
				Vector3.new(13, 0.5, 0.5),
				CFrame.new(-9.6, 6.5, 0) * CFrame.Angles(0, 0, math.pi / 2),
				C.wood
			),
			piece(
				"Cylinder",
				Vector3.new(13, 0.5, 0.5),
				CFrame.new(9.6, 6.5, 0) * CFrame.Angles(0, 0, math.pi / 2),
				C.wood
			),
		}
		local colors = { C.orange, C.red, C.hay, C.green, C.pumpkin }
		for index = 0, 8 do
			local x = -8 + index * 2
			local sag = 0.6 * math.sin(math.pi * index / 8)
			table.insert(
				pieces,
				piece("Ball", Vector3.new(0.9, 0.9, 0.9), CFrame.new(x, 12.1 - sag, 0), colors[(index % #colors) + 1])
			)
			table.insert(
				pieces,
				piece("Ball", Vector3.new(0.45, 0.45, 0.45), CFrame.new(x + 1, 11.9 - sag, 0), C.gold, nil, "Neon")
			)
		end
		return pieces
	end)(),
	Harvest_TurkeyStatue = (function(): { Piece }
		local pieces: { Piece } = {
			piece(
				"Cylinder",
				Vector3.new(1.2, 5, 5),
				CFrame.new(0, 0.6, 0) * CFrame.Angles(0, 0, math.pi / 2),
				C.white
			),
			piece(
				"Cylinder",
				Vector3.new(0.4, 5.4, 5.4),
				CFrame.new(0, 1.3, 0) * CFrame.Angles(0, 0, math.pi / 2),
				C.goldDark
			),
		}
		for _, p in turkeyPieces(1.4, C.gold, C.goldDark) do
			p.cf = CFrame.new(0, 1.5, 0) * p.cf
			table.insert(pieces, p)
		end
		return pieces
	end)(),
}

-- Fallback hub square decor (square-local, pivot = the square centre).
local function fallbackSquarePieces(): { { key: string, cf: CFrame } }
	local list: { { key: string, cf: CFrame } } = {
		{ key = "Harvest_TurkeyStatue", cf = CFrame.new(0, 0, 0) },
	}
	for index = 0, 5 do
		local angle = math.rad(index * 60 + 30)
		local cf = CFrame.new(math.cos(angle) * 16, 0, math.sin(angle) * 16) * CFrame.Angles(0, -angle - math.pi / 2, 0)
		table.insert(list, { key = if index % 2 == 0 then "Harvest_HayBale" else "Harvest_PumpkinPile", cf = cf })
	end
	table.insert(list, { key = "Harvest_Scarecrow", cf = CFrame.new(-9, 0, 9) })
	table.insert(
		list,
		{ key = "Harvest_CornucopiaSmall", cf = CFrame.new(9, 0, 9) * CFrame.Angles(0, math.rad(-30), 0) }
	)
	return list
end

-- Builds a primitive fallback model from FALLBACK[key] (pivot = `pivot`).
local function buildFallback(key: string, pivot: CFrame): Model
	local model = Instance.new("Model")
	model.Name = key
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	local pieces = FALLBACK[key] or FALLBACK.Harvest_HayBale
	for order, spec in pieces do
		local part: BasePart
		if spec.shape == "Wedge" then
			part = Instance.new("WedgePart")
		else
			local p = Instance.new("Part")
			p.Shape = if spec.shape == "Ball"
				then Enum.PartType.Ball
				elseif spec.shape == "Cylinder" then Enum.PartType.Cylinder
				else Enum.PartType.Block
			part = p
		end
		part.Name = spec.name or `Piece{order}`
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.Size = spec.size
		part.CFrame = pivot * spec.cf
		part.Color = spec.color
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		WorldMaterials.apply(part, spec.material or "Studs")
		part:SetAttribute("BuildOrder", order)
		part.Parent = model
	end
	model.WorldPivot = pivot
	model:SetAttribute("MeshKey", key)
	model:SetAttribute("MeshSource", "Fallback")
	return model
end

--[[
	Spawns one model by key: the Blender MeshLibrary model when MeshAssets knows the key, else the
	primitive fallback. May yield (MeshLibrary template loads). Not parented.
]]
function EventDecor.buildModel(key: string, pivot: CFrame): Model
	if MeshLibrary.has(key) then
		local ok, model = pcall(MeshLibrary.spawn, key, nil, pivot, nil)
		if ok then
			return model
		end
		warn(`[EventDecor] MeshLibrary.spawn({key}) failed: {model}; using the fallback`)
	end
	return buildFallback(key, pivot)
end

-- ─── HubLayout (B8e) ──────────────────────────────────────────────────────────────────────────

--[[ The HubLayout table (Shared/Config/HubLayout, owned by B8e) or {} (Event/Lazy.hubLayout). ]]
function EventDecor.hubLayout(): { [string]: any }
	return Lazy.hubLayout()
end

-- Placements from a raw HubLayout list (type-checked; junk entries skipped).
local function placements(raw: unknown): { Placement }?
	if type(raw) ~= "table" then
		return nil
	end
	local models: { Placement } = {}
	for _, entry in raw :: { any } do
		if type(entry) == "table" and type(entry.key) == "string" and typeof(entry.cf) == "CFrame" then
			local placement: Placement = {
				key = entry.key,
				cf = entry.cf,
				name = if type(entry.name) == "string" then entry.name else nil,
				tint = if typeof(entry.tint) == "Color3" then entry.tint else nil,
				colors = if type(entry.colors) == "table" then entry.colors else nil,
				castShadow = if type(entry.castShadow) == "boolean" then entry.castShadow else nil,
			}
			table.insert(models, placement)
		end
	end
	return models
end

-- World points from a raw list of Vector3 / CFrame (type-checked).
local function points(raw: unknown): { Vector3 }?
	if type(raw) ~= "table" then
		return nil
	end
	local list: { Vector3 } = {}
	for _, point in raw :: { any } do
		if typeof(point) == "CFrame" then
			table.insert(list, point.Position)
		elseif typeof(point) == "Vector3" then
			table.insert(list, point)
		end
	end
	return list
end

--[[
	The Harvest Feast parts of HubLayout (B8e) with type-checked fields. Reads the event fields
	`event = { models, collision, square, turkeySpawns, npc }` and falls back to the equivalent
	`event.harvest` group + `anchors.EventSquare / TurkeySpawnPoints` (both shapes ship in
	HubLayout). HubBuilder never builds this group; setHubActive does, by date.
]]
function EventDecor.hubEvent(): HubEvent
	local layout = EventDecor.hubLayout()
	local result: HubEvent = {}
	local event: any = if type(layout.event) == "table" then layout.event else {}
	local harvest: any = if type(event.harvest) == "table" then event.harvest else {}
	local anchors: any = if type(layout.anchors) == "table" then layout.anchors else {}
	-- Square: event.square (ground centre) or anchors.EventSquare.cf (box centre: drop to y = 0).
	if typeof(event.square) == "CFrame" then
		result.square = event.square
	elseif type(anchors.EventSquare) == "table" and typeof(anchors.EventSquare.cf) == "CFrame" then
		local cf = anchors.EventSquare.cf :: CFrame
		result.square = CFrame.new(cf.Position.X, 0, cf.Position.Z) * cf.Rotation
	end
	result.turkeySpawns = points(event.turkeySpawns) or points(anchors.TurkeySpawnPoints)
	result.models = placements(event.models) or placements(harvest.models)
	if typeof(event.npc) == "CFrame" then
		result.npc = event.npc
	elseif result.models ~= nil then
		for _, placement in result.models do
			if placement.key == "Harvest_TurkeyStatue" then
				result.npc = placement.cf * CFrame.new(0, 3, -5) -- in front of the statue
				break
			end
		end
	end
	local rawBoxes = if type(event.collision) == "table" then event.collision else harvest.collision
	if type(rawBoxes) == "table" then
		local boxes = {}
		for _, entry in rawBoxes do
			if type(entry) == "table" and typeof(entry.size) == "Vector3" and typeof(entry.cf) == "CFrame" then
				table.insert(boxes, { size = entry.size, cf = entry.cf })
			end
		end
		result.collision = boxes
	end
	return result
end

--[[ The event square centre on the ground (world CFrame): HubLayout, else the fallback. ]]
function EventDecor.square(): CFrame
	return EventDecor.hubEvent().square or EventConfig.FallbackSquare
end

--[[
	World CFrame of a decor slot on plot `plotIndex`: HubLayout.plotDecor[slot] (plot-local) when
	the hub art defines it, else EventConfig.DecorSlots (area-1 slot-local or plot-local).
]]
function EventDecor.slotWorld(plotIndex: number, slot: string): CFrame
	local plotDecor = EventDecor.hubLayout().plotDecor
	if type(plotDecor) == "table" and typeof(plotDecor[slot]) == "CFrame" then
		return WorldLayout.plotToWorld(plotIndex, plotDecor[slot])
	end
	local spec = EventConfig.DecorSlots[slot]
	if spec == nil then
		return WorldLayout.plotToWorld(plotIndex, CFrame.new(0, 0, 14))
	end
	if spec.area >= 1 then
		return WorldLayout.slotToWorld(plotIndex, spec.area, spec.cf)
	end
	return WorldLayout.plotToWorld(plotIndex, spec.cf)
end

-- Ground probe for decor (characters excluded; meshes are CanQuery false, collision boxes count).
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true

--[[ `cf` moved down / up onto the ground below it (unchanged when no ground is found). ]]
local function onGround(cf: CFrame): CFrame
	local exclude: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character ~= nil then
			table.insert(exclude, player.Character :: Model)
		end
	end
	local decorRoot = Workspace:FindFirstChild("HarvestDecor")
	if decorRoot ~= nil then
		table.insert(exclude, decorRoot)
	end
	groundParams.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(cf.Position + Vector3.new(0, 30, 0), Vector3.new(0, -60, 0), groundParams)
	if hit == nil then
		return cf
	end
	return cf.Rotation + Vector3.new(cf.Position.X, hit.Position.Y, cf.Position.Z)
end

-- ─── Turkey template ──────────────────────────────────────────────────────────────────────────

--[[
	Creates ReplicatedStorage.HarvestFeast.GoldenTurkey once (idempotent). Yields while a Blender
	mesh template loads. The B8f mesh is scaled by EventConfig.Turkey.ModelScale (feet stay at the
	pivot). Every visual part: anchored, CanCollide / CanQuery / CanTouch false; an invisible Hitbox
	sized to the bird (CanQuery on, PrimaryPart) is the click / tap / prompt target.

	Pivot (owner R96 "the turkey i in the ground"): a Model with a PrimaryPart IGNORES WorldPivot
	and pivots on PrimaryPart.CFrame * PrimaryPart.PivotOffset, so making the Hitbox the
	PrimaryPart used to move the pivot to the hitbox CENTRE (the bird's middle) and every client
	planted that middle on the ground. The template now measures the bird's real feet
	(EventConfig.groundFrame over the visual parts), stands the Hitbox on them, and sets the
	Hitbox's PivotOffset so Model:GetPivot() IS the feet. (TurkeyRenderer re-measures the feet on
	its own too, so an older template can never sink a bird again.)
]]
function EventDecor.ensureTurkeyTemplate(): Model
	local folder = ReplicatedStorage:FindFirstChild(EventConfig.AssetFolder)
	if folder == nil then
		local created = Instance.new("Folder")
		created.Name = EventConfig.AssetFolder
		created.Parent = ReplicatedStorage
		folder = created
	end
	local existing = (folder :: Instance):FindFirstChild(EventConfig.TurkeyTemplate)
	if existing ~= nil and existing:IsA("Model") then
		return existing
	end
	local model = EventDecor.buildModel(EventConfig.Models.Turkey, CFrame.new())
	model.Name = EventConfig.TurkeyTemplate
	if model:GetAttribute("MeshSource") == "Mesh" or MeshLibrary.has(EventConfig.Models.Turkey) then
		model:ScaleTo(EventConfig.Turkey.ModelScale)
	end
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			item.Anchored = true
			item.CanCollide = false
			item.CanQuery = false
			item.CanTouch = false
			-- Many small moving shadow casters cost more than they add; only the body keeps one.
			item.CastShadow = item.Name == "Body"
		end
	end
	local boundsCf, boundsSize = model:GetBoundingBox()
	-- The bird's real feet: the lowest point of its visual parts under the (identity) pivot.
	local boxes: { EventConfig.GroundBox } = {}
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			table.insert(boxes, { cframe = item.CFrame, size = item.Size })
		end
	end
	local feet = EventConfig.groundFrame(model:GetPivot(), boxes)
	local hitbox = Instance.new("Part")
	hitbox.Name = "Hitbox"
	-- Generous: at least 4 x 4.5 x 4 studs so a tap on a phone lands easily. Its bottom stands on
	-- the feet, so the prompt / sparkles on it are always above the ground.
	hitbox.Size =
		Vector3.new(math.max(4, boundsSize.X + 1), math.max(4.5, boundsSize.Y + 0.5), math.max(4, boundsSize.Z + 1))
	hitbox.CFrame = feet.Rotation
		+ Vector3.new(boundsCf.Position.X, feet.Position.Y + hitbox.Size.Y / 2, boundsCf.Position.Z)
	hitbox.Transparency = 1
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanTouch = false
	hitbox.CanQuery = true
	hitbox.CastShadow = false
	hitbox.Parent = model
	-- Golden sparkles (one emitter per turkey; low rate so 20 turkeys stay cheap).
	local attachment = Instance.new("Attachment")
	attachment.Name = "Fx"
	attachment.Position = Vector3.new(0, 0, 0)
	attachment.Parent = hitbox
	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Name = "Sparkles"
	sparkles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkles.Color = ColorSequence.new(Color3.fromRGB(255, 226, 120), Color3.fromRGB(255, 176, 40))
	sparkles.LightEmission = 1
	sparkles.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) })
	sparkles.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	sparkles.Lifetime = NumberRange.new(0.8, 1.3)
	sparkles.Speed = NumberRange.new(1, 2.5)
	sparkles.SpreadAngle = Vector2.new(180, 180)
	sparkles.Rate = 6
	sparkles.Parent = attachment
	model.PrimaryPart = hitbox
	-- With a PrimaryPart the model pivots on hitbox.CFrame * hitbox.PivotOffset (WorldPivot is
	-- ignored): put that pivot on the feet so GetPivot() is the ground point under the bird.
	hitbox.PivotOffset = hitbox.CFrame:ToObjectSpace(feet)
	model.Parent = folder
	return model
end

-- ─── Hub decor (by date) ──────────────────────────────────────────────────────────────────────

local hubFolder: Folder? = nil
local hubToken = 0

-- Text for the hub art's sign faces (HubLayout.surfaces[key] entries with a `use` caption).
local SIGN_TEXT: { [string]: string } = {
	Harvest_Arch = "HARVEST FEAST",
	Harvest_PieStand = "PIES",
}

--[[ Puts an outlined stud-style caption on a model's sign piece (HubLayout.surfaces). ]]
local function decorateSign(model: Model, key: string)
	local text = SIGN_TEXT[key]
	local surfaces = EventDecor.hubLayout().surfaces
	local list = if type(surfaces) == "table" then surfaces[key] else nil
	if text == nil or type(list) ~= "table" then
		return
	end
	for _, surface in list do
		if type(surface) ~= "table" or type(surface.piece) ~= "string" or type(surface.faces) ~= "table" then
			continue
		end
		local part = model:FindFirstChild(surface.piece)
		if part == nil or not part:IsA("BasePart") then
			continue
		end
		for _, faceName in surface.faces do
			local ok, face = pcall(function()
				return (Enum.NormalId :: any)[faceName]
			end)
			if not ok or typeof(face) ~= "EnumItem" then
				continue
			end
			local gui = Instance.new("SurfaceGui")
			gui.Name = `Sign_{faceName}`
			-- Mesh pieces are yawed 180° on import (MeshPlacement rule 1): map the model-side face.
			gui.Face = MeshPlacement.face(part, face :: Enum.NormalId)
			gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			gui.PixelsPerStud = 40
			gui.MaxDistance = 220
			gui.LightInfluence = 0
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromScale(1, 1)
			label.Text = text
			label.TextScaled = true
			label.FontFace = Font.fromEnum(Enum.Font.LuckiestGuy)
			label.TextColor3 = Color3.fromRGB(255, 226, 120)
			label.TextStrokeColor3 = Color3.fromRGB(60, 30, 10)
			label.TextStrokeTransparency = 0
			label.Parent = gui
			gui.Parent = part
		end
	end
end

--[[
	Shows (builds) or hides (destroys) the hub event square decor (HubLayout.event.harvest, or a
	primitive fallback square). Idempotent; a quick on → off → on never leaves two copies (a build
	token cancels an outdated build). Yields while building. The models keep their HubLayout
	placement names ("<key>_<index>"), so B9 finds the Harvest egg stand
	(anchors.HarvestEggStand.model) in Workspace.HarvestFeastSquare.
]]
function EventDecor.setHubActive(active: boolean)
	hubToken += 1
	local token = hubToken
	if not active then
		if hubFolder ~= nil then
			hubFolder:Destroy()
			hubFolder = nil
		end
		return
	end
	if hubFolder ~= nil then
		return
	end
	local layout = EventDecor.hubEvent()
	local folder = Instance.new("Folder")
	folder.Name = "HarvestFeastSquare"
	local models = layout.models
	if models ~= nil and #models > 0 then
		for index, entry in models do
			local model: Model
			if MeshLibrary.has(entry.key) then
				local options: MeshLibrary.SpawnOptions = {
					tint = entry.tint,
					colors = entry.colors,
					castShadow = entry.castShadow,
					name = entry.name or `{entry.key}_{index}`,
				}
				local ok, result = pcall(MeshLibrary.spawn, entry.key, nil, entry.cf, options)
				model = if ok then result else buildFallback(entry.key, entry.cf)
			else
				model = buildFallback(entry.key, entry.cf)
			end
			model.Name = entry.name or `{entry.key}_{index}`
			decorateSign(model, entry.key)
			model.Parent = folder
			if token ~= hubToken then
				folder:Destroy() -- turned off (or rebuilt) while we were building
				return
			end
		end
	else
		local square = EventDecor.square()
		for _, entry in fallbackSquarePieces() do
			buildFallback(entry.key, square * entry.cf).Parent = folder
		end
	end
	-- Invisible collision (fallback: a box per prop so players walk around them).
	local boxes = layout.collision
	if boxes == nil and (models == nil or #models == 0) then
		local square = EventDecor.square()
		boxes = { { size = Vector3.new(5, 7, 5), cf = square * CFrame.new(0, 3.5, 0) } }
		for _, entry in fallbackSquarePieces() do
			if entry.key ~= "Harvest_TurkeyStatue" then
				table.insert(
					boxes :: any,
					{ size = Vector3.new(5, 5, 4), cf = square * entry.cf * CFrame.new(0, 2.5, 0) }
				)
			end
		end
	end
	for _, box in boxes or {} do
		local part = Instance.new("Part")
		part.Name = "Collision"
		part.Anchored = true
		part.CanCollide = true
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
		part.CastShadow = false
		part.Size = box.size
		part.CFrame = box.cf
		part.Parent = folder
	end
	if token ~= hubToken then
		folder:Destroy()
		return
	end
	folder.Parent = Workspace
	hubFolder = folder
end

-- ─── Plot decorations ─────────────────────────────────────────────────────────────────────────

type Placed = { plotIndex: number, folder: Folder, keys: { [string]: boolean } }

-- userId -> what is built on their plot.
local placed: { [number]: Placed } = {}

local function plotRoot(): Folder
	local root = Workspace:FindFirstChild("HarvestDecor")
	if root ~= nil and root:IsA("Folder") then
		return root
	end
	local created = Instance.new("Folder")
	created.Name = "HarvestDecor"
	created.Parent = Workspace
	return created
end

--[[
	Makes the player's plot show exactly their owned decorations. A plot change rebuilds the set;
	`fresh` names the one decoration just bought: it is tagged for B4's LEGO build-in
	(BuildInConfig: tag + server time + buyer, set BEFORE parenting). Each decoration snaps to the
	ground and (unless it hangs overhead) gets one invisible collision box. Yields while building.
	@param owned profile.event.decor ({ [decorKey] = true })
	@param fresh the decor key bought right now, or nil (rejoin / plot change: no fly-in)
]]
function EventDecor.showPlotDecor(userId: number, plotIndex: number, owned: { [string]: true }, fresh: string?)
	local record = placed[userId]
	if record ~= nil and record.plotIndex ~= plotIndex then
		record.folder:Destroy()
		placed[userId] = nil
		record = nil
	end
	if record == nil then
		local folder = Instance.new("Folder")
		folder.Name = `Plot_{plotIndex}`
		folder:SetAttribute("OwnerUserId", userId)
		folder.Parent = plotRoot()
		record = { plotIndex = plotIndex, folder = folder, keys = {} }
		placed[userId] = record
	end
	local current = record :: Placed
	for _, def in EventConfig.Decor do
		if not owned[def.key] or current.keys[def.key] then
			continue
		end
		current.keys[def.key] = true
		local cf = EventDecor.slotWorld(plotIndex, def.slot)
		if def.collide then
			cf = onGround(cf)
		end
		local model = EventDecor.buildModel(def.model, cf)
		model.Name = def.key
		if def.key == fresh then
			-- Owner rule 4: every purchase builds in (B4's client BuildInController).
			model:SetAttribute(BuildInConfig.TimeAttribute, Workspace:GetServerTimeNow())
			model:SetAttribute(BuildInConfig.BuyerAttribute, userId)
			CollectionService:AddTag(model, BuildInConfig.Tag)
		end
		if def.collide then
			local boundsCf, boundsSize = model:GetBoundingBox()
			local box = Instance.new("Part")
			box.Name = "Collision"
			box.Anchored = true
			box.CanCollide = true
			box.CanQuery = false
			box.CanTouch = false
			box.Transparency = 1
			box.CastShadow = false
			box.Size = boundsSize * Vector3.new(0.85, 1, 0.85)
			box.CFrame = boundsCf
			box.Parent = model
		end
		if placed[userId] ~= current then
			model:Destroy() -- the player left / changed plot while this model built
			return
		end
		model.Parent = current.folder
	end
end

--[[ Removes a player's plot decorations (they left or lost their plot). ]]
function EventDecor.clearPlotDecor(userId: number)
	local record = placed[userId]
	if record ~= nil then
		record.folder:Destroy()
		placed[userId] = nil
	end
end

--[[ The plot index a player's decorations are shown on (nil when none). ]]
function EventDecor.decorPlotOf(userId: number): number?
	local record = placed[userId]
	return if record ~= nil then record.plotIndex else nil
end

return EventDecor
