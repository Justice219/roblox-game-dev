--!strict
--[[
	PlaceholderLayouts — a complete, playable layout for every area, generated from TycoonConfig.

	Purpose
		Art builders write src/shared/Config/AreaLayouts/AreaNN.luau in parallel with the server. Until
		an area's file exists (or for any part it leaves out) the plot still has to be fully playable:
		every pad needs a position, every build key something to build in, the producer an anchor and
		a click box. This module generates exactly that, deterministically:
		  * Area 1 (the tutorial garage) uses B4's real uploaded meshes (Garage_*, Workbench, ToolWall,
		    GlowLamp, MiniReactor, PaintStation, Driveway) at the positions in docs/world-art.md §5, so
		    the very first minutes already look like the game;
		  * areas 2..10 use clean themed stud primitives: a floor slab + entry arch with the area name
		    (the base, built when the previous area's Unlock pad is bought — entry-arch convention),
		    a producer "machine" in the middle, one block group per own build key around it, a small
		    person for the Manager, a tower for Feature pads, a golden atom for the finale.
		Pure: returns plain tables (LayoutLogic.AreaLayout); no Instances. Runs under Lune.

	Placement rules (slot-local, WorldLayout header):
		pads        road-side strip z_s = 9, spread over x_s ∈ [-44, 44], first pad nearest the hub
		producer    machine centred at (0, 0, 40), billboard anchor above it, click box around it
		builds      fixed spots around the producer (BUILD_SPOTS), Manager in front of the producer
		spawnPoint  (0, 0, 22): between the pads and the producer

	Worlds (owner R57, plan §3.3): `generate(area, worldId?)` works for every world. A non-main world
	(Dino Valley) gets the generic primitive layout for EVERY area (the garage meshes are Nuke Town
	art), themed from that world's palette (WORLD_THEMES, cycling when a world has more areas than
	colours), with its own prefixed pad ids / build keys from WorldsConfig. The registry is required
	lazily, only for non-main worlds, so the main path never depends on it.

	Usage
		local layout = PlaceholderLayouts.generate(3)
		print(layout.pads.a3_gps, layout.builds.A3_GPS.models[1].box)
		local dino = PlaceholderLayouts.generate(1, "dino") -- D1 Cave Workshop placeholder
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LayoutLogic = require(script.Parent.LayoutLogic)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

-- The main world's id (WorldsConfig.MAIN; a literal so the main path never requires the registry).
local MAIN = "main"

type AreaLayout = LayoutLogic.AreaLayout
type BuildEntry = LayoutLogic.BuildEntry
type ModelEntry = LayoutLogic.ModelEntry

local PlaceholderLayouts = {}

-- Theme colours per area: primary (floor/decor), secondary (machine), accent (glow / trim).
local THEMES: { { primary: Color3, secondary: Color3, accent: Color3 } } = {
	{
		primary = Color3.fromRGB(160, 160, 168),
		secondary = Color3.fromRGB(110, 120, 135),
		accent = Color3.fromRGB(110, 255, 120),
	},
	{
		primary = Color3.fromRGB(176, 120, 72),
		secondary = Color3.fromRGB(220, 70, 70),
		accent = Color3.fromRGB(255, 240, 120),
	},
	{
		primary = Color3.fromRGB(255, 150, 50),
		secondary = Color3.fromRGB(70, 70, 80),
		accent = Color3.fromRGB(255, 255, 255),
	},
	{
		primary = Color3.fromRGB(95, 92, 105),
		secondary = Color3.fromRGB(70, 66, 78),
		accent = Color3.fromRGB(90, 255, 120),
	},
	{
		primary = Color3.fromRGB(235, 240, 245),
		secondary = Color3.fromRGB(150, 210, 235),
		accent = Color3.fromRGB(80, 255, 200),
	},
	{
		primary = Color3.fromRGB(115, 140, 175),
		secondary = Color3.fromRGB(80, 90, 110),
		accent = Color3.fromRGB(255, 120, 60),
	},
	{
		primary = Color3.fromRGB(255, 210, 40),
		secondary = Color3.fromRGB(70, 70, 75),
		accent = Color3.fromRGB(255, 90, 90),
	},
	{
		primary = Color3.fromRGB(225, 110, 220),
		secondary = Color3.fromRGB(120, 70, 200),
		accent = Color3.fromRGB(255, 255, 140),
	},
	{
		primary = Color3.fromRGB(230, 235, 245),
		secondary = Color3.fromRGB(60, 75, 150),
		accent = Color3.fromRGB(120, 200, 255),
	},
	{
		primary = Color3.fromRGB(195, 195, 185),
		secondary = Color3.fromRGB(110, 120, 120),
		accent = Color3.fromRGB(90, 255, 120),
	},
}

-- R57: theme palettes of non-main worlds, one row per area (cycled when a world has more areas).
type Theme = { primary: Color3, secondary: Color3, accent: Color3 }
local WORLD_THEMES: { [string]: { Theme } } = {
	dino = {
		-- D1 Cave Workshop: mossy stone, torch orange.
		{
			primary = Color3.fromRGB(128, 140, 110),
			secondary = Color3.fromRGB(96, 90, 82),
			accent = Color3.fromRGB(255, 160, 60),
		},
		-- D2 Fern Market: leaf green, warm wood.
		{
			primary = Color3.fromRGB(110, 185, 85),
			secondary = Color3.fromRGB(150, 100, 60),
			accent = Color3.fromRGB(255, 225, 110),
		},
		-- D3 Ptero Post: treetop wood, sky blue.
		{
			primary = Color3.fromRGB(170, 120, 75),
			secondary = Color3.fromRGB(95, 150, 200),
			accent = Color3.fromRGB(255, 255, 255),
		},
		-- D4 Geyser Springs: wet stone, spring water.
		{
			primary = Color3.fromRGB(120, 150, 160),
			secondary = Color3.fromRGB(70, 160, 210),
			accent = Color3.fromRGB(200, 245, 255),
		},
		-- D5 Fossil Lab: sand, bone, amber.
		{
			primary = Color3.fromRGB(225, 200, 150),
			secondary = Color3.fromRGB(240, 235, 215),
			accent = Color3.fromRGB(255, 170, 40),
		},
		-- D6 Volcano Reactor: basalt, lava, crystal.
		{
			primary = Color3.fromRGB(70, 62, 66),
			secondary = Color3.fromRGB(230, 90, 40),
			accent = Color3.fromRGB(130, 255, 230),
		},
	},
}

-- Colours by pad kind for the build blocks (decor uses the area theme).
local GOLD = Color3.fromRGB(255, 205, 60)
local CYAN = Color3.fromRGB(90, 200, 255)
local SHIRT = Color3.fromRGB(70, 140, 255)
local SKIN = Color3.fromRGB(255, 215, 165)
local FEATURE_RED = Color3.fromRGB(235, 70, 70)

-- Where build blocks go (slot-local x, z), in pad order, skipping the producer / manager / unlock.
local BUILD_SPOTS: { Vector3 } = {
	Vector3.new(-34, 0, 26),
	Vector3.new(34, 0, 26),
	Vector3.new(-34, 0, 52),
	Vector3.new(34, 0, 52),
	Vector3.new(-16, 0, 61),
	Vector3.new(16, 0, 61),
	Vector3.new(-46, 0, 39),
	Vector3.new(46, 0, 39),
	Vector3.new(0, 0, 63),
}

-- Producer machine (areas 2..10) and its billboard anchor / click box.
local MACHINE_CENTRE = Vector3.new(0, 0, 40)
local MACHINE_SIZE = Vector3.new(12, 10, 10)
-- Floor slabs sit a hair above the plot ground (top y = 0) so the two never z-fight.
local FLOOR_TOP = 0.08

-- Ground-standing block entry: `size` box whose bottom sits on the floor at `at`.
local function block(at: Vector3, size: Vector3, color: Color3, collide: boolean?, label: string?): ModelEntry
	return {
		box = size,
		cf = CFrame.new(at.X, FLOOR_TOP + size.Y / 2 + at.Y, at.Z),
		color = color,
		collide = collide,
		label = label,
	}
end

-- A small cartoon person (Manager placeholder): legs+body, head.
local function person(at: Vector3, shirt: Color3): { ModelEntry }
	return {
		block(at, Vector3.new(3, 5, 2), shirt, true),
		block(at + Vector3.new(0, 5, 0), Vector3.new(2.2, 2.2, 2.2), SKIN, false),
	}
end

-- Pad positions: z_s = 9, spread over x_s ∈ [-44, 44], first pad nearest the hub. On the left
-- side (odd slots) the hub is at -X_s, on the right side (even slots) at +X_s.
local function padPositions(area: TycoonTypes.AreaConfig): { [string]: Vector3 }
	local areaIndex = area.index
	local count = #area.pads
	local towardHub = if areaIndex % 2 == 1 then -1 else 1
	local positions: { [string]: Vector3 } = {}
	for position, pad in area.pads do
		local t = if count > 1 then (position - 1) / (count - 1) else 0.5
		positions[pad.id] = Vector3.new(towardHub * (44 - 88 * t), 0, 9)
	end
	return positions
end

-- Entry arch at the road edge of a slot (part of an area's base): two pillars and a name beam.
-- Pillars sit at x_s = ±13, z_s = 3, clear of the pad triggers (z_s 5.5..12.5).
local function entryArch(text: string, color: Color3): { ModelEntry }
	return {
		block(Vector3.new(-13, 0, 3), Vector3.new(2, 12, 2), color, true),
		block(Vector3.new(13, 0, 3), Vector3.new(2, 12, 2), color, true),
		block(Vector3.new(0, 12, 3), Vector3.new(28, 3.5, 2), color, false, text),
	}
end

--[[
	Area 1: the garage from B4's meshes. Garage origin G = slot (0, 0, 38); door toward the road.
	Positions follow docs/world-art.md §5 (garage-local), collisions from mesh bounds (`collide`).
]]
local function garage(): AreaLayout
	local G = CFrame.new(0, 0, 38)
	local bench = G * CFrame.new(-4, 0.6, 6)
	local builds: { [string]: BuildEntry } = {
		A1_Workbench = { models = { { key = "Workbench", cf = bench, collide = true } } },
		A1_ToolWall = {
			models = {
				{ key = "Garage_WallBack", cf = G, collide = true },
				{ key = "ToolWall", cf = G * CFrame.new(7, 0.6, 11) },
			},
		},
		A1_GlowLamp = {
			models = {
				{ key = "GlowLamp", cf = G * CFrame.new(-11, 0.6, -7), collide = true },
				{ key = "GlowLamp", cf = G * CFrame.new(11, 0.6, -7), collide = true },
			},
		},
		A1_GarageDoor = {
			models = {
				{ key = "Garage_WallSide", cf = G, collide = true },
				{ key = "Garage_WallSide", cf = G * CFrame.Angles(0, math.pi, 0), collide = true },
				{ key = "Garage_WallFront", cf = G },
				{ key = "Garage_Door", cf = G },
				{ key = "Garage_Roof", cf = G },
			},
		},
		A1_MiniReactor = { models = { { key = "MiniReactor", cf = bench * CFrame.new(2.6, 3.3, 0.2) } } },
		A1_PaintStation = {
			models = {
				{
					key = "PaintStation",
					cf = G * CFrame.new(-10.4, 0.6, -0.5) * CFrame.Angles(0, -math.pi / 2, 0),
					collide = true,
				},
			},
		},
		A1_UncleAtom = { models = person(Vector3.new(3, 0.6, 36), Color3.fromRGB(80, 200, 120)) },
		A1_Driveway = { models = { { key = "Driveway", cf = G * CFrame.new(0, 0, -24), castShadow = false } } },
	}
	return {
		area = 1,
		base = {
			models = {
				{ key = "Garage_Floor", cf = G, castShadow = false },
				block(Vector3.new(0, 0, 66), Vector3.new(30, 6, 1), THEMES[1].primary, true, "GARAGE LAB"),
			},
		},
		builds = builds,
		pads = padPositions(TycoonConfig.Areas[1]),
		producer = {
			anchor = (bench * CFrame.new(0, 8.5, 0)).Position,
			click = { size = Vector3.new(8, 6, 5), cf = bench * CFrame.new(0, 3, 0) },
		},
		spawnPoint = Vector3.new(0, 0, 20),
		placeholder = true,
	}
end

--[[
	Builds the generic primitive layout of an area (Nuke Town areas 2..10, every non-main area).
	@param area AreaConfig — the area of its world's economy (pads, name, index)
	@param theme Theme — the area's colours
	@return AreaLayout
]]
local function generic(area: TycoonTypes.AreaConfig, theme: Theme): AreaLayout
	local areaIndex = area.index
	local builds: { [string]: BuildEntry } = {}
	local spot = 0
	for position, pad in area.pads do
		local key = pad.build
		if LayoutLogic.opensArea(pad) then
			continue -- `A{N+1}_EntryArch` is the next area's base (entry-arch convention)
		end
		if position == 1 then
			-- The producer "machine": body, glowing core, chimney.
			builds[key] = {
				models = {
					block(MACHINE_CENTRE, MACHINE_SIZE, theme.secondary, true),
					block(
						MACHINE_CENTRE + Vector3.new(0, MACHINE_SIZE.Y, 0),
						Vector3.new(6, 2, 6),
						theme.accent,
						false
					),
					block(
						MACHINE_CENTRE + Vector3.new(4, MACHINE_SIZE.Y, 3),
						Vector3.new(2, 6, 2),
						theme.primary,
						false
					),
				},
			}
		elseif pad.kind == "Manager" then
			builds[key] = { models = person(MACHINE_CENTRE + Vector3.new(9, 0, -10), SHIRT) }
		elseif pad.kind == "Unlock" then
			-- Finale (no `unlocks`): a golden atom on a pedestal at the back.
			builds[key] = {
				models = {
					block(Vector3.new(0, 0, 63), Vector3.new(8, 4, 8), theme.primary, true),
					{
						box = Vector3.new(7, 7, 7),
						cf = CFrame.new(0, FLOOR_TOP + 4 + 3.5, 63),
						color = GOLD,
						shape = "Ball",
						material = "Neon",
					},
				},
			}
		else
			spot += 1
			local at = BUILD_SPOTS[((spot - 1) % #BUILD_SPOTS) + 1]
			if pad.kind == "Feature" then
				builds[key] = {
					models = {
						block(at, Vector3.new(5, 14, 5), theme.secondary, true),
						block(at + Vector3.new(0, 14, 0), Vector3.new(3, 3, 3), FEATURE_RED, false),
					},
				}
			elseif pad.kind == "Multiplier" then
				local height = 4 + 2 * (pad.value or 2)
				builds[key] = { models = { block(at, Vector3.new(7, height, 7), GOLD, true, `x{pad.value}`) } }
			elseif pad.kind == "Speed" then
				builds[key] = { models = { block(at, Vector3.new(7, 6, 7), CYAN, true, "FAST") } }
			else
				builds[key] = {
					models = {
						block(at, Vector3.new(9, 3, 9), theme.primary, true),
						block(at + Vector3.new(0, 3, 0), Vector3.new(4, 3, 4), theme.accent, false),
					},
				}
			end
		end
	end
	local anchorHeight = MACHINE_SIZE.Y + 4
	local baseModels: { ModelEntry } = {
		block(Vector3.new(0, -1, 35), Vector3.new(100, 1, 66), theme.primary, false),
		block(Vector3.new(0, 0, 68), Vector3.new(40, 8, 1), theme.secondary, true, string.upper(area.name)),
	}
	for _, model in entryArch(string.upper(area.name), theme.secondary) do
		table.insert(baseModels, model)
	end
	return {
		area = areaIndex,
		base = { models = baseModels },
		builds = builds,
		pads = padPositions(area),
		producer = {
			anchor = MACHINE_CENTRE + Vector3.new(0, FLOOR_TOP + anchorHeight, 0),
			click = {
				size = MACHINE_SIZE + Vector3.new(1, 1, 1),
				cf = CFrame.new(MACHINE_CENTRE + Vector3.new(0, FLOOR_TOP + MACHINE_SIZE.Y / 2, 0)),
			},
		},
		spawnPoint = Vector3.new(0, 0, 22),
		placeholder = true,
	}
end

-- Generated layouts are pure and deterministic: build each once (per world).
local cache: { [string]: { [number]: AreaLayout } } = {}

-- The economy areas of a world: Nuke Town's TycoonConfig, or (lazily) the registry's world economy.
local function areasOf(worldId: string): { TycoonTypes.AreaConfig }
	if worldId == MAIN then
		return TycoonConfig.Areas
	end
	local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig) :: any
	local def = WorldsConfig.get(worldId)
	assert(def ~= nil, `PlaceholderLayouts: unknown world {worldId}`)
	return def.economy.Areas
end

--[[
	Theme colours of an area (the plot builder tints signs / pads with them).
	@param areaIndex number
	@param worldId string? — nil = Nuke Town
	@return Theme
]]
function PlaceholderLayouts.theme(areaIndex: number, worldId: string?): Theme
	local palette = if worldId ~= nil and worldId ~= MAIN then WORLD_THEMES[worldId] else nil
	if palette ~= nil and #palette > 0 then
		return palette[((areaIndex - 1) % #palette) + 1]
	end
	return THEMES[areaIndex] or THEMES[((areaIndex - 1) % #THEMES) + 1]
end

--[[
	The complete placeholder layout of an area (cached; treat as read-only).
	@param areaIndex number — 1..that world's area count
	@param worldId string? — R57: the world (nil = Nuke Town, unchanged)
	@return AreaLayout
	Example: PlaceholderLayouts.generate(6, "dino").builds.D6_GoldenTRex
]]
function PlaceholderLayouts.generate(areaIndex: number, worldId: string?): AreaLayout
	local world = worldId or MAIN
	local area = areasOf(world)[areaIndex]
	assert(area ~= nil, "PlaceholderLayouts.generate: bad area index")
	local perWorld = cache[world]
	if perWorld == nil then
		perWorld = {}
		cache[world] = perWorld
	end
	local cached = perWorld[areaIndex]
	if cached ~= nil then
		return cached
	end
	local layout = if world == MAIN and areaIndex == 1
		then garage()
		else generic(area, PlaceholderLayouts.theme(areaIndex, world))
	perWorld[areaIndex] = layout
	return layout
end

-- Exposed for tests: every generated spot must fit the slot.
PlaceholderLayouts.BuildSpots = BUILD_SPOTS
PlaceholderLayouts.SlotHalfWidth = WorldLayout.SlotHalfWidth

return PlaceholderLayouts
