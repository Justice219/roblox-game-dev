--!strict
--[[
	ValleyLayout — WORLD-LOCAL layout of Dino Valley's Base Camp, the valley scenery, the reusable
	Dino PLOT FRAME (plot-local) and the locked-slot placeholder (slot-local). Same shape as
	Shared/Config/HubLayout (W9 valley-hub-art, owner R57; spec
	docs/superpowers/specs/2026-10-31-world2-design.md §4.4 / §5 / §15 / §16). Every model is a Blender
	mesh from tools/blender/models/{dino_valley, hub_time_machine}.py (MeshAssets keys Valley_*,
	Hub_TimeMachine). Map + rationale: docs/areas-art.md "Dino Valley Base Camp (W9)".

	WORLD-LOCAL means: relative to the Valley's world origin (WorldGeometry "dino" = (6000, 0, 0)).
	Place anything from here with WorldLayout.toWorld("dino", cf); nothing in this file knows the
	origin, so the Valley can move without touching the art.

	Frames (studs, +Y up, yaw from +Z toward +X; model front = -Z) — identical to Nuke Town's ring so
	AreaLayouts, LayoutLogic, placeholders and billboard solving reuse the contract unchanged:
		World     Base Camp centre at the origin: plaza r 0-230 (meadow top 0, flagstone ring
		          r 25.6-88 top 0.18), ring path r 230-260 (top 0.06), valley floor (top -0.4) to
		          r 662, boundary cliffs r 644-652, invisible collision ring r 650 (WorldGeometry
		          boundaryRadius), far scenery to r 950 (sceneryRadius).
		Plot i    WorldLayout.plotOrigin(i, "dino") = origin * CFrame.Angles(0, (i-1)*45°, 0) *
		          CFrame.new(0, 0, 260); plot length 312 (3 rows = 6 slots). `plotFrame` is
		          authored in this plot-local frame (+Z away from Base Camp).
		Slot k    WorldLayout.slotLocal(k, "dino"); `lockedSlot` is slot-local.

	Shape (HubLayout's shape, so HubBuilder / PlotBuilder / the pets + leaderboard services read it
	the same way):
		ValleyLayout.worldId = "dino"
		ValleyLayout.version, .ground = false (meshes + colliders ship the ground)
		ValleyLayout.spawn: CFrame       -- Base Camp arrival (travel target "spawn"): just in front
		                                 -- of the Base Camp Time Machine, facing outward toward the
		                                 -- DINO VALLEY sign. NOT a SpawnLocation: Roblox would spawn
		                                 -- fresh players here; travel PivotTo's to it instead.
		ValleyLayout.models: { Placement }    -- Base Camp + valley scenery, names "<key>_<index>"
		ValleyLayout.collision: { Collider }
		ValleyLayout.plotFrame: PlotFrame     -- plot-local (names Ground / Road / Border /
		                                      -- EntranceArch like HubLayout; OwnerSign on the arch)
		ValleyLayout.lockedSlot: LockedSlot   -- slot-local; `sign` = COMING SOON panel front centre
		ValleyLayout.anchors: Anchors (below)
		ValleyLayout.surfaces                 -- SurfaceGui faces per model key
		ValleyLayout.plotColors[1..8]         -- = HubLayout.plotColors (tests/valley-layout checks)
		ValleyLayout.keys(group?)             -- "camp" | "scenery" | "plot"; nil = everything
		ValleyLayout.deferredKeys / isDeferred(key) -- decor that loads after the first view (R55)

	Placement groups: "camp" = Base Camp (floor, fountain, fixtures — the first view), "decor" =
	Base Camp palms / ferns / boulders (deferred), "scenery" = wedges between plots, cliffs, the
	waterfall and the volcano (far; cliffs, ground and volcano stream Persistent).

	Anchors (WORLD-LOCAL CFrames; every fixture's front faces the walker):
		SpawnPoint        = ValleyLayout.spawn
		ReturnPortal      PortalAnchor { model, cf, trigger = { cf, size }, prompt, sign, arrive }:
		                  the Base Camp Time Machine ("BACK TO NUKE TOWN" on its Sign SurfaceGui).
		                  `trigger` = touch volume inside the swirl, `prompt` = ProximityPrompt
		                  point in front of the step, `sign` = Sign face centre (LookVector out of the
		                  face), `arrive` = where a traveller coming FROM Nuke Town lands (= spawn).
		EggStands         [1] Dino Egg (Dino area 2), [2] Volcano Egg (Dino area 5):
		                  { area, eggId, model, cf, egg, prompt, tint } — EggStandAnchor + eggId;
		                  egg = cradle pivot (stand cf * (0, 4, 0)), prompt 6 studs in front.
		Leaderboards      [1] "MOST DINO REBIRTHS" (stat DinoRebirths): LeaderboardAnchor
		TitleSign         { model, cf } — "DINO VALLEY", the first thing the arrival view faces
		AmbientFx         { { preset, cf } } — HubAmbientConfig presets: the Bronto's Spray /
		                  Splash, a soft Sparkle at the Time Machine swirl.
	PlotFrame anchors: OwnerSign { model = "EntranceArch", piece = "OwnerSign", faces, cf },
	YouMarker, Entrance, TurkeySpawnPoints = {} (no Harvest turkeys in the Valley, spec §1).

	Budgets (spec §15, tests/valley-layout.luau): Base Camp first view (camp group) <= 700 MeshParts /
	150k triangles / 45 unique meshes; decor + scenery are deferred / far.

	Connections
		* Server: World/HubBuilder.buildWorld("dino") (W4: models, collision, anchors.ReturnPortal,
		  AmbientFx), World/PlotBuilder.world("dino") (W3: plotFrame, lockedSlot),
		  Pets/EggStands (W11: anchors.EggStands), the leaderboard service (W12: Leaderboards).
		* Client: SurfaceGuis via `surfaces`; WorldFx animates Swirl / Ripple pieces.
		* Art: tools/blender/studio/spawn_valley.luau previews the whole layout in edit mode.

	Example
		local ValleyLayout = require(ReplicatedStorage.Shared.Config.Worlds.Dino.ValleyLayout)
		local portal = ValleyLayout.anchors.ReturnPortal
		trigger.CFrame = WorldLayout.toWorld("dino", portal.trigger.cf)
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

-- ---- Dimensions (mirror tools/blender/models/dino_valley.py; change both together) -------------
local GROUND_TOP = -0.4 -- valley floor (Valley_Ground)
local PLAZA_TOP = 0.18 -- flagstone plaza ring (the Time Machine stands on it)
local PLOT_R = 260 -- ring path outer edge = plot entrances
local SPAWN_YAW = 22.5 -- arrival faces outward between plots 1 and 2 (same as Nuke Town)
local PORTAL_R = 50 -- Base Camp Time Machine pivot radius (front faces outward, toward the spawn)
local ARRIVE_AHEAD = 24 -- arrival / spawn distance in front of the Time Machine pivot (r 74)
local TITLE_R = 130 -- DINO VALLEY sign
local EGG_R = 104 -- the two nest stands flank the welcome walk
local EGG_SPREAD = 13 -- degrees either side of the spawn axis
local WALL_R = 650 -- invisible boundary ring (WorldGeometry "dino" boundaryRadius)
local VOLCANO_R, VOLCANO_YAW = 815, 55 -- far backdrop, left of the title sign in the arrival view
local WATERFALL_R, WATERFALL_YAW = 640, 352 -- against the cliffs, right of the title sign
local ARCH_Z = 4 -- plot entrance arch (WorldLayout.EntranceZ)

-- Bronto fountain (mirror dino_valley.py BRONTO_*): the spout nozzle and where the arc lands.
local BRONTO_MOUTH = Vector3.new(0, 2.4 + (26.1 - 2.4) * 1.55, -12.3 * 1.55)
local BRONTO_CTRL = Vector3.new(0, BRONTO_MOUTH.Y + 7, -22.5)
local BRONTO_LAND = Vector3.new(0, 1.0, -18.5)

-- Time Machine (mirror tools/blender/models/hub_time_machine.py; HubLayout has the same table).
local TM_RING_Y = 10 -- ring centre height above the pivot
local TM_SIGN = CFrame.new(0, 24.8, -0.6) -- Sign Front face centre (model space)
local TM_TRIGGER_SIZE = Vector3.new(10, 12, 2.5) -- touch volume inside the swirl

-- ---- Small CFrame helpers ---------------------------------------------------------------------

--[[ Pure yaw rotation in degrees (+yaw turns +Z toward +X). ]]
local function yaw(deg: number): CFrame
	return CFrame.Angles(0, math.rad(deg), 0)
end

--[[
	Point at radius r / yaw `yawDeg` around Base Camp, height y, oriented so the model's FRONT (-Z)
	faces Base Camp's centre (its local +Z points outward).
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

-- Pond rim as 16 tangential boxes (players can hop in and wade: the water floor is at 1.0).
local function pondRim(): { ColliderTemplate }
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
	The Time Machine's colliders (mirrors hub_time_machine.py; HubLayout.luau carries the same list
	and tests/valley-layout.luau asserts the two match): dais + step, the ring's sides (|x| 8.8-11.2)
	and lower arc, the top, the console, the lever pedestal, the sign frame. The swirl opening
	(|x| < 5.5 at foot level) stays open so players walk into the touch volume.
]]
local TIME_MACHINE: { ColliderTemplate } = {
	tbox(32, 1.0, 14, 0, 0.5, 0),
	tbox(24, 0.5, 3.2, 0, 0.25, -8.4),
	tbox(2.6, 12, 3.0, -10, 10, 0),
	tbox(2.6, 12, 3.0, 10, 10, 0),
	tbox(4.0, 3.0, 3.0, -7.5, 2.5, 0),
	tbox(4.0, 3.0, 3.0, 7.5, 2.5, 0),
	tbox(16, 2.4, 3.0, 0, 20.0, 0),
	tbox(4.4, 6.3, 4.8, -13.6, 4.15, 0),
	tbox(3.2, 3.6, 3.2, 13.6, 2.8, 0),
	tbox(15, 4.4, 0.8, 0, 24.8, 0),
}

local COLLIDERS: { [string]: { ColliderTemplate } } = {
	Hub_TimeMachine = TIME_MACHINE,
	-- Rim (hop over), wade-able pond floor (1.0), rock island, the dino's legs + body.
	Valley_BrontoFountain = join(pondRim(), toct(22, -0.6, 1.0), toct(7, 1.0, 3.6, 0, 2), {
		tbox(11, 8, 13, 0, 6.5, 3.9),
		tbox(13, 10, 19, 0, 10.5, 3.9),
	}),
	Valley_EggStand = join({
		tbox(8.4, 0.8, 8.4, 0, 0.4, 0),
		tbox(0.9, 12.2, 0.9, -4.6, 6.9, 2.9),
		tbox(0.9, 12.2, 0.9, 4.6, 6.9, 2.9),
		tbox(9.6, 3.6, 0.5, 0, 11.4, 2.9),
	}, toct(2.8, 0.8, 4.0)),
	Valley_Leaderboard = { tbox(17, 1.2, 4.2, 0, 0.6, 0.2), tbox(15.6, 20.6, 1.4, 0, 12.9, 0.45) },
	Valley_TitleSign = {
		tbox(5, 21, 5, -19.82, 10.5, 0),
		tbox(5, 21, 5, 19.82, 10.5, 0),
		tbox(36, 17.2, 1.2, 0, 20.8, 0),
	},
	Valley_Palm = { tbox(1.4, 12, 1.4, 0, 6, 0) },
	Valley_Boulder = { tbox(7, 4.5, 5.6, 0, 2.25, 0) },
	Valley_Hill = { tbox(38, 4, 28, 0, 2, 0), tbox(28, 4, 20, 0, 6, 0), tbox(16, 3.5, 12, 0, 9.5, 0) },
	Valley_FossilDecor = { tbox(16, 1.6, 11, 0, 0.8, 0) },
	Valley_Waterfall = {
		tbox(14, 44, 12, -11, 22, 6),
		tbox(14, 44, 12, 11, 22, 6),
		tbox(26, 1.2, 4, 0, 0.6, -18),
	},
	-- Plot frame (plot-local): the ground box also spans the curved front to z = -13.
	Valley_PlotGround = { tbox(160, 4, 325, 0, -2, 149.5) },
	Valley_Path = { tbox(2, 1.4, 312, -9, -0.3, 156), tbox(2, 1.4, 312, 9, -0.3, 156) },
	Valley_FernHedge = {
		tbox(2.6, 2.7, 324, -81.4, 1.35, 151),
		tbox(2.6, 2.7, 324, 81.4, 1.35, 151),
		tbox(165.4, 2.7, 2.6, 0, 1.35, 313.4),
	},
	Valley_EntranceArch = {
		tbox(5, 16.7, 5, -13, 8.35, 0),
		tbox(5, 16.7, 5, 13, 8.35, 0),
		tbox(31.2, 4.6, 3.4, 0, 18.0, 0),
	},
	Valley_LockedSlot = {
		tbox(97, 4.2, 0.9, 0, 2.1, 2.8),
		tbox(0.7, 6.7, 0.7, -6.3, 3.35, 5.0),
		tbox(0.7, 6.7, 0.7, 6.3, 3.35, 5.0),
		tbox(14, 5, 0.6, 0, 9.2, 4.4),
		tbox(10, 4.4, 10, -20, 2.2, 28.5),
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

-- Plot identity colours: the SAME eight as HubLayout.plotColors (tests/valley-layout asserts it),
-- so plot N is the same colour in both worlds.
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
local DINO_EGG_TINT = rgb(146, 218, 104) -- EggConfig dino_egg shell (fern green)
local VOLCANO_EGG_TINT = rgb(244, 122, 44) -- EggConfig volcano_egg shell (lava orange)
local AMBER_TINT = rgb(255, 168, 40)

-- =================================================================================================
-- World: Base Camp + scenery
-- =================================================================================================

local world = newGroup()
local ambientFx: { AmbientFxAnchor } = {}

-- Floor: valley floor (persistent, under everything), Base Camp meadow + plaza, ring path, trails.
place(world, "Valley_Ground", CFrame.new(), { persistent = true, castShadow = false, group = "camp" })
place(world, "Valley_BaseCamp", CFrame.new(), { castShadow = false, group = "camp" })
for i = 1, 8 do
	place(world, "Valley_RingPath", yaw((i - 1) * 45), { castShadow = false, group = "camp" })
end
for i = 1, 8 do
	place(world, "Valley_Trail", yaw((i - 1) * 45), { tint = PLOT_COLORS[i], castShadow = false, group = "camp" })
end
-- Walk surfaces: Base Camp + ring path at y 0 (r 260), the valley floor at -0.4 out to the cliffs.
groundDisc(world, PLOT_R, 0)
groundDisc(world, 662, GROUND_TOP)

-- Centrepiece: the Bronto fountain faces the arrival side (yaw 22.5), so its smile and spout look
-- over the Time Machine at everyone stepping out of it.
local fountainCf = yaw(SPAWN_YAW + 180)
place(world, "Valley_BrontoFountain", fountainCf, { persistent = true, group = "camp" })
do
	-- Nozzle: the arc leaves the mouth rising toward the Bezier control point (pitch about X).
	local d = BRONTO_CTRL - BRONTO_MOUTH
	local nozzle = fountainCf * CFrame.new(BRONTO_MOUTH) * CFrame.Angles(math.atan2(d.Y, -d.Z), 0, 0)
	table.insert(ambientFx, { preset = "Spray", cf = nozzle })
	table.insert(ambientFx, { preset = "Splash", cf = fountainCf * CFrame.new(BRONTO_LAND) })
end

-- Base Camp Time Machine (the way home) on the plaza between trails 1 and 2, front facing outward;
-- players arrive ARRIVE_AHEAD in front of it, facing the DINO VALLEY sign.
local portalCf = polar(PORTAL_R, SPAWN_YAW, PLAZA_TOP) * yaw(180)
local portalName = place(world, "Hub_TimeMachine", portalCf, { group = "camp" })
local arriveCf = portalCf * CFrame.new(0, 0, -ARRIVE_AHEAD)
local spawnCf = arriveCf
table.insert(ambientFx, { preset = "Sparkle", cf = portalCf * CFrame.new(0, TM_RING_Y, -1.2) })

-- No plot teleport pads (owner R134, as in Nuke Town's lobby): players walk the trails to their
-- plot or use the Teleport menu; HubBuilder builds no plot triggers here.

-- DINO VALLEY title sign: the arrival view looks straight at it (front faces Base Camp).
local titleCf = polar(TITLE_R, SPAWN_YAW, 0)
local titleName = place(world, "Valley_TitleSign", titleCf, { persistent = true, group = "camp" })

-- Nest stands flanking the welcome walk, turned to face the arrival point. Larger yaw = the arrival
-- view's LEFT (+X is the viewer's left when facing +Z), so Dino Egg sits left, Volcano Egg right
-- (reading order).
local EGG_STANDS = {
	{ eggId = "dino_egg", area = 2, yawDeg = SPAWN_YAW + EGG_SPREAD, tint = DINO_EGG_TINT },
	{ eggId = "volcano_egg", area = 5, yawDeg = SPAWN_YAW - EGG_SPREAD, tint = VOLCANO_EGG_TINT },
}
local eggStands: { EggStandAnchor } = {}
for i, info in EGG_STANDS do
	local cf = facing(polar(EGG_R, info.yawDeg, 0).Position, spawnCf.Position)
	local name = place(world, "Valley_EggStand", cf, { tint = info.tint, group = "camp" })
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

-- Stone-tablet leaderboard in wedge 7 (left of the arrival view), facing the centre.
local leaderboardCf = sector(7, 0, 0, 112)
local leaderboardName = place(world, "Valley_Leaderboard", leaderboardCf, { tint = AMBER_TINT, group = "camp" })
local leaderboards: { LeaderboardAnchor } = {
	{
		model = leaderboardName,
		cf = leaderboardCf,
		stat = "DinoRebirths",
		title = "MOST DINO REBIRTHS",
		tint = AMBER_TINT,
		-- Centre of the Screen face, 0.05 in front of it; LookVector points out toward viewers.
		screen = leaderboardCf * CFrame.new(0, 12.9, -0.3),
		screenSize = Vector2.new(12.8, 17.8),
	},
}

-- ---- Base Camp decor (deferred: loads after the first view) -----------------------------------
--[[
	Wedge-local spots (x lateral, z radius) on the meadow r 92-228, every one >= 4 studs off the
	trails (|x| <= z*tan(22.5°) - 9 - footprint) and off the moss / fixtures. Wedge 0 (the arrival
	wedge) frames the title sign instead.
]]
local CAMP_DECOR: { { key: string, x: number, z: number, turn: number } } = {
	{ key = "Valley_Palm", x = -28, z = 178, turn = 0 },
	{ key = "Valley_Palm", x = 34, z = 214, turn = 120 },
	{ key = "Valley_Palm", x = 4, z = 132, turn = 240 },
	{ key = "Valley_Fern", x = -10, z = 112, turn = 30 },
	{ key = "Valley_Fern", x = 20, z = 150, turn = 80 },
	{ key = "Valley_Boulder", x = -40, z = 214, turn = 60 },
	{ key = "Valley_Fern", x = 40, z = 190, turn = 140 },
}
local ARRIVAL_DECOR: { { key: string, x: number, z: number, turn: number } } = {
	{ key = "Valley_Palm", x = -32, z = 146, turn = 30 },
	{ key = "Valley_Palm", x = 32, z = 150, turn = 200 },
	{ key = "Valley_Palm", x = -26, z = 196, turn = 100 },
	{ key = "Valley_Palm", x = 28, z = 204, turn = 300 },
	{ key = "Valley_Fern", x = -20, z = 116, turn = 0 },
	{ key = "Valley_Fern", x = 20, z = 117, turn = 60 },
	{ key = "Valley_Boulder", x = 0, z = 176, turn = 20 },
	{ key = "Valley_Fern", x = -8, z = 214, turn = 90 },
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

-- ---- Scenery: wedges between plots, cliffs, waterfall, volcano --------------------------------
--[[
	Sector-local (x, z) spots on the valley floor (y = -0.4). The free half-width at distance z
	along the bisector is (z*sin22.5° - 80) / cos22.5° (plot edges): 38 at z 300, 79 at 400, 121 at
	500, 162 at 600; every prop stays >= 6 studs inside it and inside r 630 (cliffs at 644+).
]]
local WEDGE: { { key: string, x: number, z: number, turn: number } } = {
	{ key = "Valley_Palm", x = -18, z = 300, turn = 0 },
	{ key = "Valley_Palm", x = 20, z = 322, turn = 50 },
	{ key = "Valley_Palm", x = -50, z = 384, turn = 110 },
	{ key = "Valley_Palm", x = 52, z = 376, turn = 170 },
	{ key = "Valley_Palm", x = -82, z = 456, turn = 230 },
	{ key = "Valley_Palm", x = 84, z = 448, turn = 290 },
	{ key = "Valley_Palm", x = -110, z = 524, turn = 350 },
	{ key = "Valley_Palm", x = 112, z = 532, turn = 40 },
	{ key = "Valley_Palm", x = -138, z = 594, turn = 100 },
	{ key = "Valley_Palm", x = 140, z = 590, turn = 160 },
	{ key = "Valley_Fern", x = 0, z = 336, turn = 0 },
	{ key = "Valley_Fern", x = -30, z = 424, turn = 40 },
	{ key = "Valley_Fern", x = 30, z = 474, turn = 80 },
	{ key = "Valley_Fern", x = -60, z = 564, turn = 120 },
	{ key = "Valley_Fern", x = 64, z = 604, turn = 160 },
	{ key = "Valley_Boulder", x = 24, z = 352, turn = 30 },
	{ key = "Valley_Boulder", x = -40, z = 488, turn = 120 },
	{ key = "Valley_Boulder", x = 92, z = 566, turn = 210 },
	{ key = "Valley_Hill", x = -66, z = 600, turn = 20 },
	{ key = "Valley_Hill", x = 50, z = 520, turn = -30 },
}
for k = 0, 7 do
	for _, spot in WEDGE do
		place(world, spot.key, sector(k, spot.x, GROUND_TOP, spot.z, spot.turn), { group = "scenery" })
	end
	-- Fossil dig sites in every other wedge (variety without repeating the same view 8 times).
	if k % 2 == 1 then
		place(world, "Valley_FossilDecor", sector(k, 0, GROUND_TOP, 410, 25 * k), { group = "scenery" })
	end
end
-- Boundary cliffs (8 x 45° arcs) + the invisible ring at r 650 (keeps players in the valley).
for i = 1, 8 do
	place(world, "Valley_BoundaryCliffs", yaw((i - 1) * 45), { persistent = true, group = "scenery" })
end
for i = 0, 31 do
	table.insert(world.collision, {
		size = Vector3.new(2 * WALL_R * math.tan(math.pi / 32) + 4, 60, 4),
		cf = yaw(i * 11.25) * CFrame.new(0, 28, WALL_R + 2),
	})
end
place(
	world,
	"Valley_Waterfall",
	polar(WATERFALL_R, WATERFALL_YAW, GROUND_TOP),
	{ persistent = true, group = "scenery" }
)
place(
	world,
	"Valley_VolcanoBackdrop",
	polar(VOLCANO_R, VOLCANO_YAW, GROUND_TOP),
	{ persistent = true, castShadow = false, group = "scenery" }
)

-- =================================================================================================
-- Plot frame (plot-local) + locked slot placeholder (slot-local)
-- =================================================================================================

local frame = newGroup()
place(frame, "Valley_PlotGround", CFrame.new(), { castShadow = false, name = "Ground" })
place(frame, "Valley_Path", CFrame.new(), { castShadow = false, name = "Road" })
place(frame, "Valley_FernHedge", CFrame.new(), { plotTint = true, name = "Border" })
place(frame, "Valley_EntranceArch", CFrame.new(0, 0, ARCH_Z), { plotTint = true, name = "EntranceArch" })
-- Backdrop behind the back hedge (valley floor, inside the cliffs).
for _, spot in
	{
		{ "Valley_Palm", -62, 326, 20 },
		{ "Valley_Fern", -34, 322, 0 },
		{ "Valley_Palm", -8, 330, 160 },
		{ "Valley_Palm", 30, 324, 250 },
		{ "Valley_Fern", 58, 322, 90 },
	}
do
	place(
		frame,
		spot[1] :: string,
		CFrame.new(spot[2] :: number, GROUND_TOP, spot[3] :: number) * yaw(spot[4] :: number)
	)
end

local locked = newGroup()
place(locked, "Valley_LockedSlot", CFrame.new(), { name = "LockedSlot" })

-- =================================================================================================
-- Module table
-- =================================================================================================

local ValleyLayout = {}

ValleyLayout.worldId = "dino"
ValleyLayout.version = 1
-- We ship the walkable ground (meshes + 32-gon colliders): no placeholder discs.
ValleyLayout.ground = false
ValleyLayout.spawn = spawnCf
ValleyLayout.models = world.models
ValleyLayout.collision = world.collision

ValleyLayout.plotFrame = {
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

ValleyLayout.lockedSlot = {
	models = locked.models,
	collision = locked.collision,
	sign = CFrame.new(0, 9.2, 4.4 - 0.21),
} :: LockedSlot

ValleyLayout.anchors = {
	SpawnPoint = spawnCf,
	ReturnPortal = {
		model = portalName,
		cf = portalCf,
		trigger = { size = TM_TRIGGER_SIZE, cf = portalCf * CFrame.new(0, TM_RING_Y - 0.2, 0) },
		prompt = portalCf * CFrame.new(0, 4, -11),
		sign = portalCf * TM_SIGN,
		arrive = arriveCf,
	},
	EggStands = eggStands,
	Leaderboards = leaderboards,
	TitleSign = { model = titleName, cf = titleCf },
	AmbientFx = ambientFx,
} :: Anchors

-- SurfaceGui-ready faces (piece + Enum.NormalId names; size = the face in studs).
ValleyLayout.surfaces = {
	Hub_TimeMachine = {
		{ piece = "Sign", faces = { "Front" }, size = Vector2.new(13.6, 3.0), use = "BACK TO NUKE TOWN" },
	},
	Valley_EggStand = {
		{ piece = "Sign", faces = { "Front" }, size = Vector2.new(9.2, 3.2), use = "egg name + price" },
	},
	Valley_Leaderboard = {
		{ piece = "Screen", faces = { "Front" }, size = Vector2.new(12.8, 17.8), use = "top-10 list" },
	},
	Valley_EntranceArch = {
		{
			piece = "OwnerSign",
			faces = { "Front", "Back" },
			size = Vector2.new(22, 3.6),
			use = "<DisplayName>'s Dino Nukes",
		},
	},
	Valley_LockedSlot = {
		{ piece = "Sign", faces = { "Front" }, size = Vector2.new(13.5, 4.5), use = "COMING SOON + x / y purchases" },
	},
} :: { [string]: { Surface } }

ValleyLayout.plotColors = PLOT_COLORS

--[[
	Unique mesh keys of a group, for MeshLibrary.preload.
	@param group string? — "camp" (Base Camp first view), "decor" (Base Camp decor), "scenery"
	                       (wedges, cliffs, waterfall, volcano), "plot" (plot frame + locked slot);
	                       nil = everything
	@return { string }
	Example: MeshLibrary.preload(ValleyLayout.keys("camp"))
]]
function ValleyLayout.keys(group: string?): { string }
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
	Base Camp decor that is NOT needed to play or to read the arrival view, so it loads in a second
	wave after the first view (the R55 lobby pattern; HubBuilder spawns it `deferred` at Background
	priority). Everything an anchor points at (Time Machine, stands, board, title sign), the
	floor and the fountain stay in the first wave; colliders are never deferred.
]]
local DEFERRED_KEYS: { string } = { "Valley_Palm", "Valley_Fern", "Valley_Boulder" }
local DEFERRED_SET: { [string]: boolean } = {}
for _, key in DEFERRED_KEYS do
	DEFERRED_SET[key] = true
end
ValleyLayout.deferredKeys = table.freeze(DEFERRED_KEYS)

--[[
	True when `key` is Base Camp decor that loads after the first view (see deferredKeys).
	@param key string  a MeshAssets model key
	@return boolean
	Example: if ValleyLayout.isDeferred(entry.key) then table.insert(later, entry) end
]]
function ValleyLayout.isDeferred(key: string): boolean
	return DEFERRED_SET[key] == true
end

return table.freeze(ValleyLayout)
