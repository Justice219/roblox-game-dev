--!strict
--[[
	MoonHubLayout — WORLD-LOCAL layout of Moon Base's Landing Plaza, the moon scenery, the reusable
	Moon PLOT FRAME (plot-local) and the locked-slot placeholder (slot-local). Same shape as
	Shared/Config/HubLayout and Worlds/Dino/ValleyLayout (W9b, owner R70; spec
	docs/superpowers/specs/2026-10-31-r69-moon-lucky-juice-design.md §2.1 / §2.3). Every model is a
	Blender mesh from tools/blender/models/{moon_base, hub_moon_rocket}.py (MeshAssets keys Moon_*,
	Hub_MoonRocket). Map + rationale: docs/areas-art.md "Moon Base Landing Plaza (W9b)".

	WORLD-LOCAL means: relative to Moon Base's world origin (WorldGeometry "moon" = (-6000, 0, 0)).
	Place anything from here with WorldLayout.toWorld("moon", cf); nothing in this file knows the
	origin, so the world can move without touching the art.

	Frames (studs, +Y up, yaw from +Z toward +X; model front = -Z) — identical to Nuke Town's and
	Dino Valley's ring, so AreaLayouts, LayoutLogic, placeholders and billboard solving reuse the
	contract unchanged:
		World     Landing Plaza centre at the origin: dust r 0-230 (top 0, chrome landing ring
		          r 25.6-88 top 0.18), ring path r 230-260 (top 0.06), far moon floor (top -0.4) to
		          r 662, boundary ridge r 644-652, invisible collision ring r 650 (WorldGeometry
		          boundaryRadius), far planets inside r 950 (sceneryRadius).
		Plot i    WorldLayout.plotOrigin(i, "moon") = origin * CFrame.Angles(0, (i-1)*45°, 0) *
		          CFrame.new(0, 0, 260); plot length 312 (3 rows = 6 slots). `plotFrame` is
		          authored in this plot-local frame (+Z away from the plaza).
		Slot k    WorldLayout.slotLocal(k, "moon"); `lockedSlot` is slot-local.

	Shape (HubLayout's shape, so HubBuilder / PlotBuilder / the pets + leaderboard services read it
	the same way):
		MoonHubLayout.worldId = "moon"
		MoonHubLayout.version, .ground = false (meshes + colliders ship the ground)
		MoonHubLayout.spawn: CFrame       -- Landing Plaza arrival (travel target "spawn"): just in
		                                  -- front of the plaza's Moon Rocket portal, facing outward
		                                  -- toward the MOON BASE sign. NOT a SpawnLocation: Roblox
		                                  -- would spawn fresh players here; travel PivotTo's to it.
		MoonHubLayout.models: { Placement }    -- plaza + moon scenery, names "<key>_<index>"
		MoonHubLayout.collision: { Collider }
		MoonHubLayout.plotFrame: PlotFrame     -- plot-local (names Ground / Road / Border /
		                                       -- EntranceArch like HubLayout; OwnerSign on the arch)
		MoonHubLayout.lockedSlot: LockedSlot   -- slot-local; `sign` = COMING SOON panel front centre
		MoonHubLayout.anchors: Anchors (below)
		MoonHubLayout.surfaces                 -- SurfaceGui faces per model key
		MoonHubLayout.plotColors[1..8]         -- = HubLayout.plotColors (tests/moon-hub-layout)
		MoonHubLayout.keys(group?)             -- "camp" | "decor" | "scenery" | "plot"; nil = all
		MoonHubLayout.deferredKeys / isDeferred(key) -- decor that loads after the first view (R55)

	Placement groups: "camp" = the Landing Plaza (floor, fountain, fixtures — the first view),
	"decor" = plaza rocks / crystals / antennas (deferred), "scenery" = wedges between plots, the
	ridge and the far planets (ground, ridge and planets stream Persistent).

	Anchors (WORLD-LOCAL CFrames; every fixture's front faces the walker):
		SpawnPoint        = MoonHubLayout.spawn
		ReturnPortal      PortalAnchor { model, cf, trigger = { cf, size }, prompt, sign, arrive }:
		                  the plaza's Moon Rocket ("BACK TO NUKE TOWN" on its Sign SurfaceGui).
		                  `trigger` = touch volume inside the launch ring, `prompt` = ProximityPrompt
		                  point in front of the step, `sign` = Sign face centre (LookVector out of the
		                  face), `arrive` = where a traveller coming FROM Nuke Town lands (= spawn).
		EggStands         [1] Moon Egg (Moon area 2), [2] Comet Egg (Moon area 5):
		                  { area, eggId, model, cf, egg, prompt, tint } — EggStandAnchor + eggId;
		                  egg = cradle pivot (stand cf * (0, 4, 0)), prompt 6 studs in front.
		Leaderboards      [1] "MOST MOON REBIRTHS" (stat MoonRebirths): LeaderboardAnchor
		TitleSign         { model, cf } — "MOON BASE", the first thing the arrival view faces
		AmbientFx         { { preset, cf } } — HubAmbientConfig presets: a Splash where each star-
		                  water jet lands, Sparkles at the fountain rocket's nose and the portal ring.
	PlotFrame anchors: OwnerSign { model = "EntranceArch", piece = "OwnerSign", faces, cf },
	YouMarker, Entrance, TurkeySpawnPoints = {} (no Harvest turkeys on the Moon).

	Budgets (tests/moon-hub-layout.luau): Landing Plaza first view (camp group) <= 700 MeshParts /
	150k triangles / 45 unique meshes; decor + scenery are deferred / far.

	Connections
		* Server: World/HubBuilder.buildWorld("moon") (models, collision, anchors.ReturnPortal,
		  AmbientFx, the Sign label sized from `surfaces.Hub_MoonRocket`),
		  World/PlotBuilder.world("moon") (plotFrame, lockedSlot), Pets/EggStands
		  (anchors.EggStands via EggConfig "moon:EggStands<n>"), the leaderboard service
		  (Leaderboards[1].screen).
		* Client: SurfaceGuis via `surfaces`; WorldFx animates Swirl (Assemblies.Hub_MoonRocket),
		  Ripple, Dish, Bulb and Crystal pieces.
		* Art: tools/blender/studio/spawn_moon_hub.luau previews the whole layout in edit mode.

	Example
		local MoonHubLayout = require(ReplicatedStorage.Shared.Config.Worlds.Moon.MoonHubLayout)
		local portal = MoonHubLayout.anchors.ReturnPortal
		trigger.CFrame = WorldLayout.toWorld("moon", portal.trigger.cf)
		trigger.Size = portal.trigger.size
]]

export type Placement = {
	key: string,
	cf: CFrame,
	name: string?,
	tint: Color3?,
	colors: { [string]: Color3 }?,
	castShadow: boolean?,
	persistent: boolean?,
	plotTint: boolean?,
	group: string?,
}
export type Collider = { size: Vector3, cf: CFrame }
export type Group = { models: { Placement }, collision: { Collider } }
export type PortalAnchor = {
	model: string,
	cf: CFrame,
	trigger: Collider,
	prompt: CFrame,
	sign: CFrame,
	arrive: CFrame,
}
export type EggStandAnchor = {
	area: number,
	eggId: string,
	model: string,
	cf: CFrame,
	egg: CFrame,
	prompt: CFrame,
	tint: Color3,
}
export type LeaderboardAnchor = {
	model: string,
	cf: CFrame,
	stat: string,
	title: string,
	tint: Color3,
	screen: CFrame,
	screenSize: Vector2,
}
export type AmbientFxAnchor = { preset: string, cf: CFrame }
export type Surface = { piece: string, faces: { string }, size: Vector2, use: string }
export type Anchors = {
	SpawnPoint: CFrame,
	ReturnPortal: PortalAnchor,
	EggStands: { EggStandAnchor },
	Leaderboards: { LeaderboardAnchor },
	TitleSign: { model: string, cf: CFrame },
	AmbientFx: { AmbientFxAnchor },
}
export type PlotFrame = {
	models: { Placement },
	collision: { Collider },
	anchors: {
		OwnerSign: { model: string, piece: string, faces: { string }, cf: CFrame },
		YouMarker: CFrame,
		Entrance: CFrame,
		TurkeySpawnPoints: { CFrame },
	},
}
export type LockedSlot = { models: { Placement }, collision: { Collider }, sign: CFrame }

-- Collider in a MODEL's own frame (transformed by each placement's cf).
type ColliderTemplate = { size: Vector3, offset: CFrame }

-- ---- Dimensions (mirror tools/blender/models/moon_base.py; change both together) ---------------
local GROUND_TOP = -0.4 -- far moon floor (Moon_Ground)
local PLAZA_TOP = 0.18 -- chrome landing ring (the portal stands on it)
local PLOT_R = 260 -- ring path outer edge = plot entrances
local SPAWN_YAW = 22.5 -- arrival faces outward between plots 1 and 2 (same as Nuke Town)
local PORTAL_R = 50 -- the plaza's Moon Rocket pivot radius (front faces outward, toward the spawn)
local ARRIVE_AHEAD = 24 -- arrival / spawn distance in front of the portal pivot (r 74)
local TITLE_R = 130 -- MOON BASE sign
local EGG_R = 104 -- the two egg stands flank the welcome walk
local EGG_SPREAD = 13 -- degrees either side of the spawn axis
local WALL_R = 650 -- invisible boundary ring (WorldGeometry "moon" boundaryRadius)
local PLANETS_R, PLANETS_YAW = 765, 51 -- far planets (high in the sky), left of the title sign in the arrival view
local ARCH_Z = 4 -- plot entrance arch (WorldLayout.EntranceZ)

-- Rocket fountain (mirror moon_base.py ROCKET_S / ROCKET_Y0 / FIN_ANGLES / JET_LAND_R): the three
-- star-water jets land in the pool at r 17 along the fin directions (measured from the statue's
-- FRONT, -Z, toward +X); the statue's nose ball is at (0, 46.1, 0).
local FOUNTAIN_FINS = { 60, 180, 300 }
local JET_LAND_R = 17
local WATER_TOP = 1.0
local ROCKET_NOSE = Vector3.new(0, 46.1, 0)

-- Moon Rocket portal (mirror tools/blender/models/hub_moon_rocket.py; HubLayout has the same table).
local MR_RING_Y = 8.6 -- launch ring centre height above the pivot
local MR_SIGN = CFrame.new(0, 21.6, -0.6) -- Sign Front face centre (model space)
local MR_TRIGGER_SIZE = Vector3.new(9, 10, 2.5) -- touch volume inside the launch ring

-- ---- Small CFrame helpers ---------------------------------------------------------------------

--[[ Pure yaw rotation in degrees (+yaw turns +Z toward +X). ]]
local function yaw(deg: number): CFrame
	return CFrame.Angles(0, math.rad(deg), 0)
end

--[[
	Point at radius r / yaw `yawDeg` around the plaza, height y, oriented so the model's FRONT (-Z)
	faces the plaza centre (its local +Z points outward).
	Example: polar(130, SPAWN_YAW, 0) -- the title sign straight ahead of the arrival view
]]
local function polar(r: number, yawDeg: number, y: number): CFrame
	return yaw(yawDeg) * CFrame.new(0, y, r)
end

--[[
	Sector-local CFrame: wedge k (0..7) between plots k+1 and k+2 has its bisector at yaw 22.5 + 45k;
	x = lateral (+x toward larger yaw), z = distance from the centre. `turnDeg` adds a local yaw.
]]
local function sector(k: number, x: number, y: number, z: number, turnDeg: number?): CFrame
	return yaw(22.5 + 45 * k) * CFrame.new(x, y, z) * yaw(turnDeg or 0)
end

--[[
	CFrame at `position` whose front (-Z) looks at `target` horizontally (pure yaw). Built from
	CFrame.Angles, not CFrame.lookAt: Lune's lookAt (tests, z-fight audit) flips Z, so a lookAt
	layout would be audited in a different pose than Roblox builds.
]]
local function facing(position: Vector3, target: Vector3): CFrame
	local d = target - position
	return CFrame.new(position) * CFrame.Angles(0, math.atan2(-d.X, -d.Z), 0)
end

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- ---- Collider templates (model-local; mirror the Blender builders) ---------------------------

local function tbox(
	sx: number,
	sy: number,
	sz: number,
	x: number,
	y: number,
	z: number,
	turnDeg: number?
): ColliderTemplate
	return { size = Vector3.new(sx, sy, sz), offset = CFrame.new(x, y, z) * yaw(turnDeg or 0) }
end

--[[ Round base as an octagon prism (two squares at 0° / 45°) with inradius r from y0 to y1. ]]
local function toct(r: number, y0: number, y1: number, x: number?, z: number?): { ColliderTemplate }
	local h = y1 - y0
	local cx, cz = x or 0, z or 0
	return {
		tbox(r * 2, h, r * 2, cx, y0 + h / 2, cz),
		tbox(r * 2, h, r * 2, cx, y0 + h / 2, cz, 45),
	}
end

local function join(...: { ColliderTemplate }): { ColliderTemplate }
	local out: { ColliderTemplate } = {}
	for _, list in { ... } do
		for _, item in list do
			table.insert(out, item)
		end
	end
	return out
end

-- Pool rim as 16 tangential boxes (players can hop in and wade: the water floor is at 1.0).
local function poolRim(): { ColliderTemplate }
	local out: { ColliderTemplate } = {}
	for i = 0, 15 do
		table.insert(out, {
			size = Vector3.new(2 * math.pi * 24 / 16 + 0.8, 1.6, 4),
			offset = yaw(i * 22.5) * CFrame.new(0, 0.8, 24),
		})
	end
	return out
end

--[[
	The fountain rocket's three fins as boxes along each fin (r 5.7-11.4 from the axis, y 2.6-20.6).
	A fin at angle A (from the FRONT -Z toward +X) points along (sin A, -cos A) = yaw(180 - A) * +Z.
]]
local function fountainFins(): { ColliderTemplate }
	local out: { ColliderTemplate } = {}
	for _, angle in FOUNTAIN_FINS do
		local a = math.rad(angle)
		table.insert(out, tbox(1.4, 15, 5.7, math.sin(a) * 8.55, 10.1, -math.cos(a) * 8.55, 180 - angle))
	end
	return out
end

-- Big crater rim as 12 tangential boxes (r 11.6-17, 2.6 tall): players can climb in and out.
local function craterRim(): { ColliderTemplate }
	local out: { ColliderTemplate } = {}
	for i = 0, 11 do
		table.insert(out, {
			size = Vector3.new(2 * math.pi * 14.3 / 12 + 0.6, 2.2, 4.6),
			offset = yaw(i * 30) * CFrame.new(0, 1.1, 14.3),
		})
	end
	return out
end

--[[
	The Moon Rocket portal's colliders (mirrors hub_moon_rocket.py; HubLayout.luau carries the same
	list and tests/moon-hub-layout.luau asserts the two match): dais + step, the launch ring's sides
	(|x| 7.4-9.6) and lower arc, its top, the rocket's fuselage (octagon round the axis z 9) and its
	three fins, the sign frame. The ring opening (|x| < 5.4 at foot level) stays open so players
	walk into the touch volume.
]]
local MOON_ROCKET: { ColliderTemplate } = join({
	tbox(30, 1.0, 26, 0, 0.5, 6),
	tbox(22, 0.5, 3.2, 0, 0.25, -8.4),
	tbox(2.2, 11, 2.4, -8.5, 8.6, 0),
	tbox(2.2, 11, 2.4, 8.5, 8.6, 0),
	tbox(3.6, 2.6, 2.4, -7.2, 2.3, 0),
	tbox(3.6, 2.6, 2.4, 7.2, 2.3, 0),
	tbox(13, 2.2, 2.4, 0, 16.9, 0),
	tbox(4.6, 10, 1.0, -7.2, 6, 9),
	tbox(4.6, 10, 1.0, 7.2, 6, 9),
	tbox(1.0, 10, 4.6, 0, 6, 16.2),
	tbox(15, 4.4, 0.8, 0, 21.6, 0),
}, toct(5, 1.0, 42.4, 0, 9))

local COLLIDERS: { [string]: { ColliderTemplate } } = {
	Hub_MoonRocket = MOON_ROCKET,
	-- Rim (hop over), wade-able pool floor (1.0), rock island, the rocket's fuselage + fins.
	Moon_RocketFountain = join(
		poolRim(),
		toct(22, -0.6, 1.0),
		toct(7.4, 1.0, 3.8),
		toct(6.3, 3.8, 45.2),
		fountainFins()
	),
	Moon_EggStand = join({
		tbox(8.4, 0.8, 8.4, 0, 0.4, 0),
		tbox(0.9, 12.2, 0.9, -4.6, 6.9, 2.9),
		tbox(0.9, 12.2, 0.9, 4.6, 6.9, 2.9),
		tbox(9.6, 3.6, 0.5, 0, 11.4, 2.9),
	}, toct(3.0, 0.8, 4.4)),
	Moon_Leaderboard = { tbox(17, 1.2, 4.2, 0, 0.6, 0.2), tbox(15.6, 20.6, 1.4, 0, 12.9, 0.45) },
	-- Antenna towers (feet + columns) and the board (above head height: walk under it).
	Moon_TitleSign = {
		tbox(5.4, 2, 5.4, -14.125, 1, 0),
		tbox(5.4, 2, 5.4, 14.125, 1, 0),
		tbox(3.8, 25, 3.8, -14.125, 14.5, 0),
		tbox(3.8, 25, 3.8, 14.125, 14.5, 0),
		tbox(26.65, 18.6, 1.7, 0, 20.8, 0),
	},
	Moon_Rock = { tbox(7, 4.5, 5.6, 0, 2.25, 0) },
	Moon_CrystalCluster = { tbox(6, 2.2, 5.4, 0, 1.1, 0), tbox(2.4, 5.5, 2.4, 0, 3.9, 0) },
	Moon_Antenna = { tbox(1.2, 15, 1.2, 0, 7.5, 0), tbox(6.6, 0.4, 6.6, 0, 0.2, 0) },
	Moon_Crater = craterRim(),
	-- Plot frame (plot-local): the ground box also spans the curved front to z = -13.
	Moon_PlotGround = { tbox(160, 4, 325, 0, -2, 149.5) },
	Moon_Path = { tbox(2, 1.4, 312, -9, -0.3, 156), tbox(2, 1.4, 312, 9, -0.3, 156) },
	Moon_CraterRim = {
		tbox(2.6, 2.7, 324, -81.4, 1.35, 151),
		tbox(2.6, 2.7, 324, 81.4, 1.35, 151),
		tbox(165.4, 2.7, 2.6, 0, 1.35, 313.4),
	},
	Moon_EntranceArch = {
		tbox(5, 16.7, 5, -13, 8.35, 0),
		tbox(5, 16.7, 5, 13, 8.35, 0),
		tbox(31.2, 4.6, 3.4, 0, 18.0, 0),
	},
	Moon_LockedSlot = {
		tbox(97, 4.2, 0.9, 0, 2.1, 2.8),
		tbox(0.7, 6.7, 0.7, -6.3, 3.35, 5.0),
		tbox(0.7, 6.7, 0.7, 6.3, 3.35, 5.0),
		tbox(14, 5, 0.6, 0, 9.2, 4.4),
		tbox(8.4, 7.8, 8.4, -20, 3.9, 28),
	},
}

-- ---- Group builder ----------------------------------------------------------------------------

type PlaceOptions = {
	tint: Color3?,
	colors: { [string]: Color3 }?,
	castShadow: boolean?,
	persistent: boolean?,
	plotTint: boolean?,
	group: string?,
	name: string?,
}

local function newGroup(): Group
	return { models = {}, collision = {} }
end

--[[
	Adds a model placement and its collider templates (transformed by `cf`) to a group.
	@return string — the instance name "<key>_<index>" (or opts.name for plot-frame pieces)
]]
local function place(group: Group, key: string, cf: CFrame, opts: PlaceOptions?): string
	local o: PlaceOptions = opts or {}
	local index = #group.models + 1
	local name = o.name or `{key}_{index}`
	table.insert(group.models, {
		key = key,
		cf = cf,
		name = name,
		tint = o.tint,
		colors = o.colors,
		castShadow = o.castShadow,
		persistent = o.persistent,
		plotTint = o.plotTint,
		group = o.group,
	})
	for _, template in COLLIDERS[key] or {} do
		table.insert(group.collision, { size = template.size, cf = cf * template.offset })
	end
	return name
end

--[[
	Huge flat ground collider: a 32-gon (8 squares rotated by 11.25°) with inradius `radius`, top at
	`top`, 4 studs thick. Parts max out at 2048 studs per axis, so radius <= 1024.
]]
local function groundDisc(group: Group, radius: number, top: number)
	for i = 0, 7 do
		table.insert(group.collision, {
			size = Vector3.new(radius * 2, 4, radius * 2),
			cf = CFrame.new(0, top - 2, 0) * yaw(i * 11.25),
		})
	end
end

-- ---- Palette ----------------------------------------------------------------------------------

-- Plot identity colours: the SAME eight as HubLayout.plotColors (tests/moon-hub-layout asserts it),
-- so plot N is the same colour in every world.
local PLOT_COLORS: { Color3 } = {
	rgb(232, 64, 56), -- 1 red
	rgb(255, 146, 40), -- 2 orange
	rgb(255, 214, 50), -- 3 yellow
	rgb(150, 230, 60), -- 4 lime
	rgb(110, 222, 170), -- 5 mint
	rgb(96, 168, 236), -- 6 sky blue
	rgb(150, 96, 220), -- 7 purple
	rgb(255, 120, 180), -- 8 pink
}
local MOON_EGG_TINT = rgb(196, 170, 255) -- EggConfig moon_egg shell (lilac)
local COMET_EGG_TINT = rgb(64, 110, 255) -- EggConfig comet_egg shell (comet blue)
local VIOLET_TINT = rgb(164, 120, 255) -- leaderboard frame

-- =================================================================================================
-- World: Landing Plaza + scenery
-- =================================================================================================

local world = newGroup()
local ambientFx: { AmbientFxAnchor } = {}

-- Floor: moon floor (persistent, under everything), plaza dust + chrome ring, ring path, trails.
place(world, "Moon_Ground", CFrame.new(), { persistent = true, castShadow = false, group = "camp" })
place(world, "Moon_LandingPlaza", CFrame.new(), { castShadow = false, group = "camp" })
for i = 1, 8 do
	place(world, "Moon_RingPath", yaw((i - 1) * 45), { castShadow = false, group = "camp" })
end
for i = 1, 8 do
	place(world, "Moon_Trail", yaw((i - 1) * 45), { tint = PLOT_COLORS[i], castShadow = false, group = "camp" })
end
-- Walk surfaces: plaza + ring path at y 0 (r 260), the moon floor at -0.4 out to the ridge.
groundDisc(world, PLOT_R, 0)
groundDisc(world, 662, GROUND_TOP)

-- Centrepiece: the rocket fountain faces the arrival side (yaw 22.5): its smile looks over the
-- portal at everyone arriving, and the three jets land in the pool along its fins.
local fountainCf = yaw(SPAWN_YAW + 180)
place(world, "Moon_RocketFountain", fountainCf, { persistent = true, group = "camp" })
for _, angle in FOUNTAIN_FINS do
	local a = math.rad(angle)
	local land = CFrame.new(math.sin(a) * JET_LAND_R, WATER_TOP, -math.cos(a) * JET_LAND_R)
	table.insert(ambientFx, { preset = "Splash", cf = fountainCf * land })
end
table.insert(ambientFx, { preset = "Sparkle", cf = fountainCf * CFrame.new(ROCKET_NOSE) })

-- The plaza's Moon Rocket (the way home) between trails 1 and 2, front facing outward; players
-- arrive ARRIVE_AHEAD in front of it, facing the MOON BASE sign.
local portalCf = polar(PORTAL_R, SPAWN_YAW, PLAZA_TOP) * yaw(180)
local portalName = place(world, "Hub_MoonRocket", portalCf, { group = "camp" })
local arriveCf = portalCf * CFrame.new(0, 0, -ARRIVE_AHEAD)
local spawnCf = arriveCf
table.insert(ambientFx, { preset = "Sparkle", cf = portalCf * CFrame.new(0, MR_RING_Y, -1.2) })

-- No plot teleport pads (owner R134, as in Nuke Town's lobby): players walk the trails to their
-- plot or use the Teleport menu; HubBuilder builds no plot triggers here.

-- MOON BASE title sign: the arrival view looks straight at it (front faces the plaza).
local titleCf = polar(TITLE_R, SPAWN_YAW, 0)
local titleName = place(world, "Moon_TitleSign", titleCf, { persistent = true, group = "camp" })

-- Egg stands flanking the welcome walk, turned to face the arrival point. Larger yaw = the arrival
-- view's LEFT, so the Moon Egg (area 2) sits left, the Comet Egg (area 5) right (reading order).
local EGG_STANDS = {
	{ eggId = "moon_egg", area = 2, yawDeg = SPAWN_YAW + EGG_SPREAD, tint = MOON_EGG_TINT },
	{ eggId = "comet_egg", area = 5, yawDeg = SPAWN_YAW - EGG_SPREAD, tint = COMET_EGG_TINT },
}
local eggStands: { EggStandAnchor } = {}
for i, info in EGG_STANDS do
	local cf = facing(polar(EGG_R, info.yawDeg, 0).Position, spawnCf.Position)
	local name = place(world, "Moon_EggStand", cf, { tint = info.tint, group = "camp" })
	eggStands[i] = {
		area = info.area,
		eggId = info.eggId,
		model = name,
		cf = cf,
		egg = cf * CFrame.new(0, 4.0, 0),
		prompt = cf * CFrame.new(0, 3, -6),
		tint = info.tint,
	}
end

-- Chrome monitor leaderboard in wedge 7 (left of the arrival view), facing the centre.
local leaderboardCf = sector(7, 0, 0, 112)
local leaderboardName = place(world, "Moon_Leaderboard", leaderboardCf, { tint = VIOLET_TINT, group = "camp" })
local leaderboards: { LeaderboardAnchor } = {
	{
		model = leaderboardName,
		cf = leaderboardCf,
		stat = "MoonRebirths",
		title = "MOST MOON REBIRTHS",
		tint = VIOLET_TINT,
		-- Centre of the Screen face, 0.05 in front of it; LookVector points out toward viewers.
		screen = leaderboardCf * CFrame.new(0, 12.9, -0.3),
		screenSize = Vector2.new(12.8, 17.8),
	},
}

-- ---- Plaza decor (deferred: loads after the first view) ---------------------------------------
--[[
	Wedge-local spots (x lateral, z radius) on the dust r 92-228, every one >= 4 studs off the trails
	(|x| <= z*tan(22.5°) - 9 - footprint), off the craters and the fixtures. Wedge 0 (the arrival
	wedge) frames the title sign instead. Same spots as Dino Valley's Base Camp decor.
]]
local CAMP_DECOR: { { key: string, x: number, z: number, turn: number } } = {
	{ key = "Moon_CrystalCluster", x = -28, z = 178, turn = 0 },
	{ key = "Moon_Antenna", x = 34, z = 214, turn = 120 },
	{ key = "Moon_CrystalCluster", x = 4, z = 132, turn = 240 },
	{ key = "Moon_Rock", x = -10, z = 112, turn = 30 },
	{ key = "Moon_Rock", x = 20, z = 150, turn = 80 },
	{ key = "Moon_Rock", x = -40, z = 214, turn = 60 },
	{ key = "Moon_CrystalCluster", x = 40, z = 190, turn = 140 },
}
local ARRIVAL_DECOR: { { key: string, x: number, z: number, turn: number } } = {
	{ key = "Moon_CrystalCluster", x = -32, z = 146, turn = 30 },
	{ key = "Moon_CrystalCluster", x = 32, z = 150, turn = 200 },
	{ key = "Moon_Antenna", x = -26, z = 196, turn = 100 },
	{ key = "Moon_Antenna", x = 28, z = 204, turn = 300 },
	{ key = "Moon_Rock", x = -20, z = 116, turn = 0 },
	{ key = "Moon_Rock", x = 20, z = 117, turn = 60 },
	{ key = "Moon_Rock", x = 0, z = 176, turn = 20 },
	{ key = "Moon_CrystalCluster", x = -8, z = 214, turn = 90 },
}
for k = 0, 7 do
	local spots = if k == 0 then ARRIVAL_DECOR else CAMP_DECOR
	for _, spot in spots do
		if k == 7 and spot.z < 128 then
			continue -- the leaderboard stands at z 112 in wedge 7
		end
		place(world, spot.key, sector(k, spot.x, 0, spot.z, spot.turn + 37 * k), { group = "decor" })
	end
end

-- ---- Scenery: wedges between plots, the ridge, the far planets ---------------------------------
--[[
	Sector-local (x, z) spots on the moon floor (y = -0.4). The free half-width at distance z along the
	bisector is (z*sin22.5° - 80) / cos22.5° (plot edges): 38 at z 300, 79 at 400, 121 at 500, 162 at
	600; every prop stays >= 6 studs inside it and inside r 630 (the ridge is at 644+). Same spots
	as Dino Valley's wedges (crystals / antennas where the Valley has palms, rocks for ferns and
	boulders, big craters for hills).
]]
local WEDGE: { { key: string, x: number, z: number, turn: number } } = {
	{ key = "Moon_CrystalCluster", x = -18, z = 300, turn = 0 },
	{ key = "Moon_Antenna", x = 20, z = 322, turn = 50 },
	{ key = "Moon_CrystalCluster", x = -50, z = 384, turn = 110 },
	{ key = "Moon_CrystalCluster", x = 52, z = 376, turn = 170 },
	{ key = "Moon_Antenna", x = -82, z = 456, turn = 230 },
	{ key = "Moon_CrystalCluster", x = 84, z = 448, turn = 290 },
	{ key = "Moon_CrystalCluster", x = -110, z = 524, turn = 350 },
	{ key = "Moon_Antenna", x = 112, z = 532, turn = 40 },
	{ key = "Moon_CrystalCluster", x = -138, z = 594, turn = 100 },
	{ key = "Moon_CrystalCluster", x = 140, z = 590, turn = 160 },
	{ key = "Moon_Rock", x = 0, z = 336, turn = 0 },
	{ key = "Moon_Rock", x = -30, z = 424, turn = 40 },
	{ key = "Moon_Rock", x = 30, z = 474, turn = 80 },
	{ key = "Moon_Rock", x = -60, z = 564, turn = 120 },
	{ key = "Moon_Rock", x = 64, z = 604, turn = 160 },
	{ key = "Moon_Rock", x = 24, z = 352, turn = 30 },
	{ key = "Moon_Rock", x = -40, z = 488, turn = 120 },
	{ key = "Moon_Rock", x = 92, z = 566, turn = 210 },
	{ key = "Moon_Crater", x = -66, z = 600, turn = 20 },
	{ key = "Moon_Crater", x = 50, z = 520, turn = -30 },
}
for k = 0, 7 do
	for _, spot in WEDGE do
		place(world, spot.key, sector(k, spot.x, GROUND_TOP, spot.z, spot.turn), { group = "scenery" })
	end
	-- An extra big crater in every other wedge (variety without repeating the same view 8 times).
	if k % 2 == 1 then
		place(world, "Moon_Crater", sector(k, 0, GROUND_TOP, 410, 25 * k), { group = "scenery" })
	end
end
-- Boundary ridge (8 x 45° arcs) + the invisible ring at r 650 (keeps players on the plateau).
for i = 1, 8 do
	place(world, "Moon_BoundaryRidge", yaw((i - 1) * 45), { persistent = true, group = "scenery" })
end
for i = 0, 31 do
	table.insert(world.collision, {
		size = Vector3.new(2 * WALL_R * math.tan(math.pi / 32) + 4, 60, 4),
		cf = yaw(i * 11.25) * CFrame.new(0, 28, WALL_R + 2),
	})
end
place(
	world,
	"Moon_PlanetBackdrop",
	polar(PLANETS_R, PLANETS_YAW, GROUND_TOP),
	{ persistent = true, castShadow = false, group = "scenery" }
)

-- =================================================================================================
-- Plot frame (plot-local) + locked slot placeholder (slot-local)
-- =================================================================================================

local frame = newGroup()
place(frame, "Moon_PlotGround", CFrame.new(), { castShadow = false, name = "Ground" })
place(frame, "Moon_Path", CFrame.new(), { castShadow = false, name = "Road" })
place(frame, "Moon_CraterRim", CFrame.new(), { plotTint = true, name = "Border" })
place(frame, "Moon_EntranceArch", CFrame.new(0, 0, ARCH_Z), { plotTint = true, name = "EntranceArch" })
-- Backdrop behind the back rim (moon floor, inside the ridge).
for _, spot in
	{
		{ "Moon_CrystalCluster", -62, 326, 20 },
		{ "Moon_Rock", -34, 322, 0 },
		{ "Moon_Antenna", -8, 330, 160 },
		{ "Moon_CrystalCluster", 30, 324, 250 },
		{ "Moon_Rock", 58, 322, 90 },
	}
do
	place(
		frame,
		spot[1] :: string,
		CFrame.new(spot[2] :: number, GROUND_TOP, spot[3] :: number) * yaw(spot[4] :: number)
	)
end

local locked = newGroup()
place(locked, "Moon_LockedSlot", CFrame.new(), { name = "LockedSlot" })

-- =================================================================================================
-- Module table
-- =================================================================================================

local MoonHubLayout = {}

MoonHubLayout.worldId = "moon"
MoonHubLayout.version = 1
-- We ship the walkable ground (meshes + 32-gon colliders): no placeholder discs.
MoonHubLayout.ground = false
MoonHubLayout.spawn = spawnCf
MoonHubLayout.models = world.models
MoonHubLayout.collision = world.collision

MoonHubLayout.plotFrame = {
	models = frame.models,
	collision = frame.collision,
	anchors = {
		OwnerSign = {
			model = "EntranceArch",
			piece = "OwnerSign",
			faces = { "Front", "Back" },
			cf = CFrame.new(0, 17.3, ARCH_Z - 2.0),
		},
		YouMarker = CFrame.new(0, 31, ARCH_Z),
		Entrance = CFrame.new(0, 0, ARCH_Z + 10) * yaw(180),
		TurkeySpawnPoints = {},
	},
} :: PlotFrame

MoonHubLayout.lockedSlot = {
	models = locked.models,
	collision = locked.collision,
	sign = CFrame.new(0, 9.2, 4.4 - 0.21),
} :: LockedSlot

MoonHubLayout.anchors = {
	SpawnPoint = spawnCf,
	ReturnPortal = {
		model = portalName,
		cf = portalCf,
		trigger = { size = MR_TRIGGER_SIZE, cf = portalCf * CFrame.new(0, MR_RING_Y - 0.2, 0) },
		prompt = portalCf * CFrame.new(0, 4, -11),
		sign = portalCf * MR_SIGN,
		arrive = arriveCf,
	},
	EggStands = eggStands,
	Leaderboards = leaderboards,
	TitleSign = { model = titleName, cf = titleCf },
	AmbientFx = ambientFx,
} :: Anchors

-- SurfaceGui-ready faces (piece + Enum.NormalId names; size = the face in studs).
MoonHubLayout.surfaces = {
	Hub_MoonRocket = {
		{ piece = "Sign", faces = { "Front" }, size = Vector2.new(13.6, 3.0), use = "BACK TO NUKE TOWN" },
	},
	Moon_EggStand = {
		{ piece = "Sign", faces = { "Front" }, size = Vector2.new(9.2, 3.2), use = "egg name + price" },
	},
	Moon_Leaderboard = {
		{ piece = "Screen", faces = { "Front" }, size = Vector2.new(12.8, 17.8), use = "top-10 list" },
	},
	Moon_EntranceArch = {
		{
			piece = "OwnerSign",
			faces = { "Front", "Back" },
			size = Vector2.new(22, 3.6),
			use = "<DisplayName>'s Moon Nukes",
		},
	},
	Moon_LockedSlot = {
		{ piece = "Sign", faces = { "Front" }, size = Vector2.new(13.5, 4.5), use = "COMING SOON + x / y purchases" },
	},
} :: { [string]: { Surface } }

MoonHubLayout.plotColors = PLOT_COLORS

--[[
	Unique mesh keys of a group, for MeshLibrary.preload.
	@param group string? — "camp" (Landing Plaza first view), "decor" (plaza decor), "scenery"
	                       (wedges, ridge, planets), "plot" (plot frame + locked slot); nil = all
	@return { string }
	Example: MeshLibrary.preload(MoonHubLayout.keys("camp"))
]]
function MoonHubLayout.keys(group: string?): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	local function add(list: { Placement }, filter: string?)
		for _, entry in list do
			if (filter == nil or entry.group == filter) and not seen[entry.key] then
				seen[entry.key] = true
				table.insert(out, entry.key)
			end
		end
	end
	if group == nil or group == "camp" or group == "decor" or group == "scenery" then
		add(world.models, group)
	end
	if group == nil or group == "plot" then
		add(frame.models, nil)
		add(locked.models, nil)
	end
	table.sort(out)
	return out
end

--[[
	Plaza decor that is NOT needed to play or to read the arrival view, so it loads in a second wave
	after the first view (the R55 lobby pattern; HubBuilder spawns it `deferred` at Background
	priority). Everything an anchor points at (portal, stands, board, title sign), the floor and
	the fountain stay in the first wave; colliders are never deferred.
]]
local DEFERRED_KEYS: { string } = { "Moon_Rock", "Moon_CrystalCluster", "Moon_Antenna" }
local DEFERRED_SET: { [string]: boolean } = {}
for _, key in DEFERRED_KEYS do
	DEFERRED_SET[key] = true
end
MoonHubLayout.deferredKeys = table.freeze(DEFERRED_KEYS)

--[[
	True when `key` is plaza decor that loads after the first view (see deferredKeys).
	@param key string  a MeshAssets model key
	@return boolean
	Example: if MoonHubLayout.isDeferred(entry.key) then table.insert(later, entry) end
]]
function MoonHubLayout.isDeferred(key: string): boolean
	return DEFERRED_SET[key] == true
end

return table.freeze(MoonHubLayout)
