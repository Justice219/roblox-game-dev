--!strict
--[[
	HubLayout — WORLD-SPACE layout of the Hub, the island scenery, the Harvest Feast event decor and
	the reusable PLOT FRAME (plot-local) + locked-slot placeholder (slot-local). Written by the hub art
	builder (B8e); every model is a Blender mesh from tools/blender/models/{hub,plotframe,scenery,
	event_harvest}.py (MeshAssets keys Hub_*, Plot_*, Scenery_*, Harvest_*). Human-readable map and
	rationale: docs/areas-art.md → "Hub, plot frame, scenery and Harvest Feast (B8e)".

	Frames (studs, +Y up, yaw measured from +Z toward +X, i.e. CFrame.Angles(0, yaw, 0) * (0, 0, 1)
	= (sin yaw, 0, cos yaw); model front = -Z):
		World     hub centre at the origin; plaza r 0-230 (top y = 0), ring road r 230-260 (top 0),
		          island ground r <= 836 (top -0.4), stepped beach to r 874, sea (top -2.4) to r 2000.
		Plot i    WorldLayout.plotOrigin(i) = CFrame.Angles(0, (i-1)*45°, 0) * CFrame.new(0, 0, 260);
		          plot-local +Z away from the hub. `plotFrame` is authored in this frame.
		Slot k    WorldLayout.slotLocal(k) (plot-local); `lockedSlot` is authored in slot-local space.

	Shape (B5's HubBuilder contract in WorldLayout.luau is a SUBSET of this, so it works unchanged):
		HubLayout.ground = false          -- we ship the ground meshes + colliders: skip placeholder discs
		HubLayout.spawn: CFrame           -- hub spawn (ground level, facing outward); the Hub_SpawnPad
		                                  -- mesh encloses HubBuilder's 12 x 1 x 12 SpawnLocation
		HubLayout.models: { Placement }   -- ALWAYS-BUILT world models: hub + island scenery, in order
		HubLayout.collision: { Collider } -- invisible Block parts for those models (ground discs are
		                                  -- 32-gons of 8 rotated squares; everything is a plain box)
		HubLayout.event.harvest: Group    -- Harvest Feast decor (world). The event service spawns it
		                                  -- while EventConfig's window is open and destroys it after.
		HubLayout.event.{models, collision, square, squareSize, turkeySpawns, npc}
		                                  -- the same group as flat fields (B11's names): square = square
		                                  -- centre on the ground; turkeySpawns = { Vector3 }; npc = prompt
		                                  -- spot in front of the Turkey statue
		HubLayout.leaderboards[1..3]      -- { cf, size }: Screen face centre (LookVector = out of the
		                                  -- face), 12.8 x 17.8; [1] cash earned, [2] rebirths, [3] playtime
		HubLayout.plotDecor[slot]         -- PLOT-LOCAL CFrames for bought Harvest decorations: Arch
		                                  -- (Harvest_Garland pivot: road centre past the arch) and GroundL1,
		                                  -- GroundL2, GroundL3, GroundR1, GroundR2 (island, outside the
		                                  -- plot's front corners)
		HubLayout.plotFrame: PlotFrame    -- per plot, plot-local (see type below)
		HubLayout.lockedSlot: LockedSlot  -- per LOCKED area slot, slot-local
		HubLayout.anchors: Anchors        -- named world anchors for systems (see type below)
		HubLayout.surfaces                -- SurfaceGui-ready faces per model key (piece + NormalId names)
		HubLayout.plotColors[1..8]        -- each plot's identity colour (avenue chevrons, gates, caps)
		HubLayout.areaTints[1..10]        -- egg stand accent per area theme
		HubLayout.keys(group?)            -- unique mesh keys for MeshLibrary.preload

	Placement = { key, cf, name?, tint?, colors?, castShadow?, persistent?, plotTint? }
		name        instance name. For `models` it is ALWAYS "<key>_<index in HubLayout.models>", which
		            is exactly what HubBuilder already names them, so anchors can reference instances.
		            Event placements use "<key>_<index in event.harvest.models>" the same way.
		castShadow  false on flat floors (shadow cost wasted).
		persistent  true = landmark/ground visible from anywhere (monument, island, beach, sea):
		            spawn with streamingMode = Enum.ModelStreamingMode.Persistent.
		plotTint    plotFrame only: tint = HubLayout.plotColors[plotIndex].
	Collider = { size, cf } — an anchored, invisible, CanQuery/CanTouch = false Block Part.

	Anchors (world CFrames; every fixture's front faces the hub centre):
		SpawnPoint                       = HubLayout.spawn
		EggStands[1..10]                 { area, model, cf, egg, prompt, tint } — `egg` = egg model
		                                   pivot (bottom centre) on the cradle; `prompt` = interaction
		                                   point 6 studs in front; Sign SurfaceGui = name + price
		HarvestEggStand                  same shape (area = 0), in the EVENT group (model name is
		                                   relative to event.harvest.models)
		CrateStall                       { model, cf, display, prompt } — display = showcase crate pivot
		LuckyWheelStage                  { model, wheelModel, cf, wheel, prompt } — spin `wheelModel`
		                                   about wheel's local Z (client-side, cosmetic)
		GroupChest                       { model, lidModel, cf, lidHinge, prompt } — open = rotate the
		                                   lid about lidHinge's local X by -105°
		CodesBoard                       { model, cf, prompt } — Screen SurfaceGui
		Leaderboards[1..3]               { model, cf, stat, title, tint } — Screen SurfaceGui
		PlotGates[1..8]                  { plot, model, cf, tint } — numbered gate over avenue i's outer
		                                   end (r 222), white Hub_Digit<i> on both faces (owner R13).
		                                   The lobby's ONLY plot numbers since owner R134 (below).
		TitleSign                        { model, cf } — "SELL NUKES" lobby sign in front of the spawn
		EventSquare                      { cf, size } — event-square region (box, oriented on its axis)
		TurkeySpawnPoints                { CFrame } — event square + hub beds (ground level)
		FountainJets                     { CFrame } — the 8 toy-nuke spout nozzles; LookVector = the
		                                   direction the water arc leaves the nose (owner R55)
		AmbientFx                        { { preset, cf } } — lobby particles HubBuilder builds once:
		                                   "Spray" / "Splash" (fountain), "Sparkle" (coins), presets in
		                                   Shared/Config/HubAmbientConfig
		LampLights                       { CFrame } — globe centres. The globes are Neon; add PointLights
		                                   only on high graphics quality (mobile / console first, R11)
		WorldPortals[worldId]            PortalAnchor { model, cf, trigger = { cf, size }, prompt, sign,
		                                   arrive } — the lobby Time Machine to another world (owner R57,
		                                   W9): `trigger` = touch volume inside the swirl, `prompt` =
		                                   ProximityPrompt point in front of the step, `sign` = the Sign
		                                   face centre (SurfaceGui "DINO VALLEY", LookVector out of the
		                                   face), `arrive` = where a traveller coming BACK from that world
		                                   lands (in front of the machine, facing away from it). Twin:
		                                   Worlds/<Name>/ValleyLayout anchors.ReturnPortal. `moon` (owner
		                                   R70, W9b) is the Moon Rocket (Hub_MoonRocket, sign "MOON BASE",
		                                   trigger inside its launch ring), twin MoonHubLayout.ReturnPortal.
		                                   The portal model is whatever placement `model` names, so any
		                                   world can bring its own portal mesh (HubBuilder is generic).
	PlotFrame = { models, collision, anchors = { OwnerSign, YouMarker, Entrance, TurkeySpawnPoints } }
		OwnerSign = { model = "EntranceArch", piece = "OwnerSign", faces = {"Front", "Back"}, cf }
		YouMarker = plot-local CFrame for the "YOU" BillboardGui (above the arch)
	LockedSlot = { models, collision, sign } — build at plotOrigin * WorldLayout.slotLocal(k) * cf for
		every slot k whose area is still locked; `sign` = Sign panel front centre ("COMING SOON",
		"x / y purchases").

	Lobby centre (owner R55 "the center lobby looks like shit", L1-lobby; art in
	tools/blender/models/hub_plaza.py, map in docs/areas-art.md "Lobby centre (R55)"):
		r 0-26.6   Hub_Monument (toy-nuke fountain incl. 8 spouts), Hub_NukeyStatue on the plinth
		           facing the spawn, Hub_CoinHalo spinning over his head
		r 27-38.4  fountain walk (Hub_CenterPlaza tiles + lime borders)
		r 38-80.5  Hub_PlazaSpoke x8 (plot-coloured path, walked straight out to the avenue),
		           Hub_PlazaGarden x7 between the spokes (bench, banner pole, floating coin each),
		           the spawn wedge's welcome carpet lined with banners + planters, coins rising to
		           the SELL NUKES sign
		r 77.6     every spoke mouth: Hub_Bunting (two lamp posts + a pennant string: the path's gateway)
		r 80-86.5  lime rim with yellow inlays (Hub_CenterPlaza)

	No plot teleport pads (owner R134, 2026-11-01: "can we remove these little teleports")
		The R55 ring of 8 plot teleport pads (Hub_TeleportPad + a plot-coloured Hub_Digit<i> on its
		signpost at r 62, touch trigger → walk to plot i) is gone, and so is the `PlotTeleportPads`
		anchor list: HubBuilder builds no plot triggers and no generated portal fallback. Players
		reach plots by walking the plot paths + avenues (the numbered PlotGates still read from the
		lobby) or through the Teleport menu (own plot areas free, other plots with the Teleporter
		pass). The Hub_TeleportPad mesh stays in MeshAssets, unused. Every extra world's hub layout
		follows the same rule (tests/hub-no-teleport-pads.luau).

	Connections
		* Server: World/HubBuilder (models, collision, ground, spawn, anchors.WorldPortals,
		  anchors.AmbientFx),
		  World/PlotBuilder (plotFrame, lockedSlot), the event service (event.harvest, EventSquare,
		  TurkeySpawnPoints), eggs / crates / wheel / chest / codes / leaderboard services (anchors).
		* Client: wheel spin, chest lid, YOU marker, SurfaceGuis via `surfaces`.
		* Art: tools/blender/studio/spawn_hub.luau spawns this whole layout in edit mode.

	Example
		local HubLayout = require(ReplicatedStorage.Shared.Config.HubLayout)
		MeshLibrary.preload(HubLayout.keys("hub"))
		local stand = HubLayout.anchors.EggStands[3]
		local model = hubArt:FindFirstChild(stand.model) -- "Hub_EggStand_<n>"
		eggModel:PivotTo(stand.egg)
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
export type EggStandAnchor = { area: number, model: string, cf: CFrame, egg: CFrame, prompt: CFrame, tint: Color3 }
export type CrateAnchor = { model: string, cf: CFrame, display: CFrame, prompt: CFrame }
export type WheelAnchor = { model: string, wheelModel: string, cf: CFrame, wheel: CFrame, prompt: CFrame }
export type ChestAnchor = { model: string, lidModel: string, cf: CFrame, lidHinge: CFrame, prompt: CFrame }
export type BoardAnchor = { model: string, cf: CFrame, prompt: CFrame }
export type LeaderboardAnchor = {
	model: string,
	cf: CFrame,
	stat: string,
	title: string,
	tint: Color3,
	screen: CFrame,
	screenSize: Vector2,
}
export type GateAnchor = { plot: number, model: string, cf: CFrame, tint: Color3 }
export type Surface = { piece: string, faces: { string }, size: Vector2, use: string }
-- One lobby particle emitter: `preset` names a HubAmbientConfig.Presets row, `cf` is world space.
export type AmbientFxAnchor = { preset: string, cf: CFrame }
-- A world portal (owner R57): the Time Machine in the lobby (here) or its twin in another world's hub.
export type PortalAnchor = {
	model: string,
	cf: CFrame,
	trigger: Collider,
	prompt: CFrame,
	sign: CFrame,
	arrive: CFrame,
}
export type Anchors = {
	SpawnPoint: CFrame,
	EggStands: { EggStandAnchor },
	HarvestEggStand: EggStandAnchor,
	CrateStall: CrateAnchor,
	LuckyWheelStage: WheelAnchor,
	GroupChest: ChestAnchor,
	CodesBoard: BoardAnchor,
	Leaderboards: { LeaderboardAnchor },
	PlotGates: { GateAnchor },
	TitleSign: { model: string, cf: CFrame },
	EventSquare: { cf: CFrame, size: Vector3 },
	TurkeySpawnPoints: { CFrame },
	FountainJets: { CFrame },
	LampLights: { CFrame },
	AmbientFx: { AmbientFxAnchor },
	WorldPortals: { [string]: PortalAnchor },
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

-- ---- Dimensions (mirror tools/blender/models/*.py; change both together) ----------------------
local BED_TOP = 0.1 -- hub grass beds (features stand on them)
local ISLAND_TOP = -0.4 -- island ground under the wedges / behind the plots
-- Visitors' lane nodes on each plot path (lobbyWalk). r 62 is where the R55 teleport pads stood
-- until owner R134 removed them; the lanes keep their proven spot beside the path axis.
local LANE_R = 62
local SPAWN_R = 44 -- spawn pad radius from the centre
local SPAWN_YAW = 22.5 -- spawn between plot paths 1 and 2, facing outward toward egg district 0
-- Radius of the main feature arc in each district: 132 since the R55 lobby pass (was 150) so the
-- egg stands, stalls, wheel and boards frame the lobby centre more tightly (still on the beds,
-- clear of the avenues; tests/hub-layout checks both).
local FEATURE_R = 132
local WALL_R = 880 -- invisible boundary wall ring (beach ends at the foam line, r 874)

-- Lobby centre (owner R55; mirror tools/blender/models/hub_plaza.py — change both together).
local DAIS_TOP = 0.06 -- plaza dais top (benches, lamps, planters, banner poles stand on it)
local POOL_TOP = 1.7 -- fountain pool water (players wade at this height)
local CAP_TOP = 2.9 -- fountain cap top (the toy-nuke spouts stand on it)
local SPOUT_R = 24.4 -- spout ring radius
local SPOUT_LEN = 5.6 -- spout height (nose tip)
local LAND_R = 16 -- the spout arcs land in the pool at this radius
local SPRAY_PITCH = 36.9 -- the arc leaves the nose rising at atan(0.75) toward the centre
local PLINTH_TOP = 12.2 -- fountain plinth top = Hub_NukeyStatue pivot height
local NUKEY_TOP = 31.5 -- statue height (fin bottoms to nose tip)
local GARDEN_R0 = 48 -- garden beds between the spokes: r 48-77, edges 12.5 from the spoke axes
local GARDEN_R1 = 77
local GARDEN_OFFSET = 12.5
local GARDEN_TOP = 1.3 -- garden grass top
local COPING_TOP = 1.55 -- garden kerb top (the bed's walk-on collision height)
local MOUTH_Z = 77.6 -- spoke-mouth gateway (Hub_Bunting: 2 lamp posts + pennants), spoke-local z
local MOUTH_X = 10.6 -- its lamp posts' offset from the spoke axis (walkway between path edge 9 and garden 12.5)

-- Lobby Time Machine to Dino Valley (owner R57, W9; model tools/blender/models/hub_time_machine.py).
-- Placement (spec §4.4 asks for "within ~30° of the fresh-spawn view"): from the spawn camera the
-- SELL NUKES sign fills +-21°, the welcome banners 20-30° and (until owner R134 removed them) the
-- pad 1 / pad 2 signposts 34-46° on either side, and every open sightline inside +-30° runs down an
-- avenue or onto a plot (Studio
-- capture docs/verification/world2/lobby-spawn-view.jpg). The nearest legal spot is district 1's
-- paving forecourt beside avenue 2 (yaw 54, r 207, ~39° LEFT of the spawn axis, 176 studs, so it
-- is first-wave): clear of the bed (r 194), the avenue, plot gate 2 and the ring road (r 230), it
-- shows as soon as a player turns a little left (lobby-spawn-turn-left.jpg) and greets everyone
-- walking to plot 2. tests/hub-layout checks every clearance.
local PORTAL_R = 207
local PORTAL_YAW = 54
local PORTAL_ARRIVE = 18 -- returning travellers land this far in front of the machine
local TM_RING_Y = 10 -- ring centre height (mirror hub_time_machine.py RING_Y)
local TM_SIGN = CFrame.new(0, 24.8, -0.6) -- Sign Front face centre (model space)
local TM_TRIGGER_SIZE = Vector3.new(10, 12, 2.5) -- touch volume inside the swirl

-- Lobby Moon Rocket to Moon Base (owner R70, W9b; model tools/blender/models/hub_moon_rocket.py).
-- Placement: the Time Machine's mirror on the other side of the spawn view — district 7's paving
-- forecourt beside avenue 1 (yaw 346.5, r 208, ~44.5° RIGHT of the spawn axis; the TM is ~39°
-- LEFT, 228 studs away, so the two portals frame the SELL NUKES sign without crowding each other
-- or the R55 plaza). The sightline from the spawn passes between the park trees, it is first-wave
-- (174 studs from the spawn < MeshLibrary's 200 near-hub radius) and tests/hub-layout checks every
-- clearance (bed r 194, avenue 1, plot gate 1, the ring road r 230, the park's trees and lamps).
local MOON_PORTAL_R = 208
local MOON_PORTAL_YAW = 346.5
local MR_RING_Y = 8.6 -- launch ring centre height (mirror hub_moon_rocket.py RING_Y)
local MR_SIGN = CFrame.new(0, 21.6, -0.6) -- Sign Front face centre (model space)
local MR_TRIGGER_SIZE = Vector3.new(9, 10, 2.5) -- touch volume inside the launch ring

-- ---- Small CFrame helpers ---------------------------------------------------------------------

--[[ Pure yaw rotation in degrees (Roblox convention: +yaw turns +Z toward +X). ]]
local function yaw(deg: number): CFrame
	return CFrame.Angles(0, math.rad(deg), 0)
end

--[[
	Point at radius r / yaw `yawDeg` around the hub centre, height y, oriented so the model's FRONT
	(-Z) faces the hub centre (its local +Z points outward).
	Example: polar(150, 22.5, 0.1) -- centre of egg district 0, facing the fountain
]]
local function polar(r: number, yawDeg: number, y: number): CFrame
	return yaw(yawDeg) * CFrame.new(0, y, r)
end

--[[
	Sector-local CFrame: district / wedge k (0..7) has its bisector at yaw 22.5 + 45k; x = lateral
	(+x toward larger yaw), z = distance from the centre along the bisector. Front (-Z) faces the
	hub along the bisector; `turnDeg` adds a local yaw.
]]
local function sector(k: number, x: number, y: number, z: number, turnDeg: number?): CFrame
	return yaw(22.5 + 45 * k) * CFrame.new(x, y, z) * yaw(turnDeg or 0)
end

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- ---- Collider templates (model-local; mirrors the Blender builders) --------------------------

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

--[[
	Round base approximated by an octagon prism = two squares (0° and 45°) with inradius r, from
	y0 to y1, centred at (x, z). Cheap and close enough for pads, podiums and drums.
]]
local function toct(r: number, y0: number, y1: number, x: number?, z: number?): { ColliderTemplate }
	local h = y1 - y0
	local cx, cz = x or 0, z or 0
	return {
		tbox(r * 2, h, r * 2, cx, y0 + h / 2, cz),
		tbox(r * 2, h, r * 2, cx, y0 + h / 2, cz, 45),
	}
end

-- Concatenate template lists.
local function join(...: { ColliderTemplate }): { ColliderTemplate }
	local out: { ColliderTemplate } = {}
	for _, list in { ... } do
		for _, item in list do
			table.insert(out, item)
		end
	end
	return out
end

-- Fountain basin wall as 16 tangential boxes (players can wade into the fountain, water floor 1.8).
local function basinWall(): { ColliderTemplate }
	local out: { ColliderTemplate } = {}
	for i = 0, 15 do
		table.insert(out, {
			size = Vector3.new(2 * math.pi * 24.3 / 16 + 0.8, 3.0, 4.6),
			offset = yaw(i * 22.5) * CFrame.new(0, 1.5, 24.3),
		})
	end
	return out
end

-- Market-stall shell shared by Hub_CrateStall and Harvest_PieStand (counter, back, posts, awning).
local STALL = {
	tbox(13, 3.4, 2.6, 0, 1.7, -2.8),
	tbox(13.6, 7, 0.5, 0, 3.5, 4.1),
	tbox(0.8, 9.6, 0.8, -6.4, 4.8, -3.9),
	tbox(0.8, 9.6, 0.8, 6.4, 4.8, -3.9),
	tbox(0.8, 10.8, 0.8, -6.4, 5.4, 3.9),
	tbox(0.8, 10.8, 0.8, 6.4, 5.4, 3.9),
	tbox(14.4, 0.6, 9.8, 0, 10.2, -0.3),
}

local function cloudStick(s: number): { ColliderTemplate }
	return { tbox(2.6 * s, 1 * s, 2.6 * s, 0, 0.5 * s, 0), tbox(0.7 * s, 20 * s, 0.7 * s, 0, 10 * s, 0) }
end

local TRUNK = { tbox(1.5, 8, 1.5, 0, 4, 0) }

-- The fountain's eight toy-nuke spouts on the cap (r SPOUT_R, yaw 22.5 + 45k), one box each.
local function spoutColliders(): { ColliderTemplate }
	local out: { ColliderTemplate } = {}
	for k = 0, 7 do
		local p = yaw(22.5 + 45 * k) * Vector3.new(0, 0, SPOUT_R)
		table.insert(out, tbox(2.6, SPOUT_LEN, 2.6, p.X, CAP_TOP + SPOUT_LEN / 2, p.Z, 22.5 + 45 * k))
	end
	return out
end

--[[
	Garden bed collision (sector-local, bisector +Z), all INSIDE the bed outline so nobody bumps an
	invisible wall on the 3.5-stud walkway beside it: two boxes hugging the straight side edges
	(turned +-22.5°, 3.4 deep) + two centre boxes, top = kerb top; plus the topiary trunk. The side
	edge on side s is the line at GARDEN_OFFSET from the spoke axis at yaw s*22.5 (tools/blender
	hub.py wedge_corner), running from the inner circle to where its inner face meets the outer one.
]]
local function gardenColliders(): { ColliderTemplate }
	local out: { ColliderTemplate } = {}
	local depth = 3.4
	local c = GARDEN_OFFSET
	local t0 = math.sqrt(GARDEN_R0 * GARDEN_R0 - c * c)
	local t1 = math.sqrt(GARDEN_R1 * GARDEN_R1 - (c + depth) * (c + depth))
	local s225, c225 = math.sin(math.rad(22.5)), math.cos(math.rad(22.5))
	for _, side in { -1, 1 } do
		local u = Vector3.new(side * s225, 0, c225) -- along the edge, outward
		local n = Vector3.new(-side * c225, 0, s225) -- toward the bisector
		local centre = n * (c + depth / 2) + u * ((t0 + t1) / 2)
		table.insert(out, tbox(depth, COPING_TOP, t1 - t0, centre.X, COPING_TOP / 2, centre.Z, side * 22.5))
	end
	table.insert(out, tbox(13, COPING_TOP, 13, 0, COPING_TOP / 2, 55.5))
	table.insert(out, tbox(24, COPING_TOP, 13.5, 0, COPING_TOP / 2, 68.75))
	table.insert(out, tbox(1.5, 8, 1.5, 0, GARDEN_TOP + 4, 65.5))
	return out
end

--[[
	The Time Machine's colliders (mirrors hub_time_machine.py; Worlds/Dino/ValleyLayout carries the
	same list and tests/valley-layout.luau asserts the two match): dais + step, the ring's sides and
	lower arc, its top, the console, the lever pedestal, the sign frame. The swirl opening stays open
	so players walk into the touch volume.
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

--[[
	The Moon Rocket's colliders (mirrors hub_moon_rocket.py; Worlds/Moon/MoonHubLayout carries the
	same list and tests/moon-hub-layout.luau asserts the two match): dais + step, the launch ring's
	sides and lower arc, its top, the rocket's three fins and fuselage (octagon round the axis z 9),
	the sign frame. The ring opening stays open so players walk into the touch volume.
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
	Hub_TimeMachine = TIME_MACHINE,
	Hub_MoonRocket = MOON_ROCKET,
	-- Pool wall, wade-able water (1.7), bowl (rim 7.6), square plinth up to the statue.
	Hub_Monument = join(basinWall(), toct(22, 0, POOL_TOP), toct(12.9, POOL_TOP, 7.6), {
		tbox(12.8, PLINTH_TOP - 7.6, 12.8, 0, (7.6 + PLINTH_TOP) / 2, 0),
	}, spoutColliders()),
	-- Gateway lamp posts (the pennant string overhead needs none).
	Hub_Bunting = {
		tbox(1.6, 0.8, 1.6, -MOUTH_X, 0.4, 0),
		tbox(0.7, 12.6, 0.7, -MOUTH_X, 6.7, 0),
		tbox(1.6, 0.8, 1.6, MOUTH_X, 0.4, 0),
		tbox(0.7, 12.6, 0.7, MOUTH_X, 6.7, 0),
	},
	Hub_NukeyStatue = join(toct(5.6, 0, 24), toct(3.4, 24, NUKEY_TOP)),
	Hub_PlazaGarden = gardenColliders(),
	Hub_BannerPole = { tbox(1.6, 0.6, 1.6, 0, 0.3, 0.45), tbox(0.7, 17, 0.7, 0, 8.5, 0.45) },
	Hub_SpawnPad = toct(9.5, 0, 1.0),
	Hub_EggStand = join({
		tbox(8.4, 0.8, 8.4, 0, 0.4, 0),
		tbox(0.8, 12, 0.8, -4.6, 6.8, 2.9),
		tbox(0.8, 12, 0.8, 4.6, 6.8, 2.9),
		tbox(9.6, 3.6, 0.5, 0, 11.4, 2.9),
	}, toct(2.8, 0.8, 4.0)),
	Hub_CrateStall = join(STALL, { tbox(10.4, 5.2, 2.8, -0.3, 2.6, 1.95) }),
	Hub_LuckyWheelStage = join(toct(10, 0, 1.8), {
		tbox(7, 0.6, 1.8, 0, 0.3, -11.3),
		tbox(7, 1.2, 1.6, 0, 0.6, -9.9),
		tbox(1.2, 12.2, 1.2, -9, 7.9, 1.2),
		tbox(1.2, 12.2, 1.2, 9, 7.9, 1.2),
		tbox(18.4, 18.4, 1.6, 0, 13, 0.2),
	}),
	Hub_GroupChest = join(toct(5.6, 0, 1.35), {
		tbox(7, 5.9, 4.6, 0, 4.15, 0),
		tbox(0.45, 8, 0.45, -3.4, 5.2, 3.6),
		tbox(0.45, 8, 0.45, 3.4, 5.2, 3.6),
		tbox(7.6, 2.4, 0.45, 0, 9.3, 3.6),
	}),
	Hub_CodesBoard = {
		tbox(0.9, 6, 0.9, -5.8, 3, 0.35),
		tbox(0.9, 6, 0.9, 5.8, 3, 0.35),
		tbox(14.4, 9.6, 0.8, 0, 9.6, 0),
	},
	Hub_Leaderboard = {
		tbox(16, 1, 3.6, 0, 0.5, 0.2),
		tbox(1, 3, 1, -6.3, 2.3, 0.4),
		tbox(1, 3, 1, 6.3, 2.3, 0.4),
		tbox(14.4, 19.4, 0.8, 0, 12.9, 0),
	},
	Hub_Bench = { tbox(6, 1.8, 1.9, 0, 0.9, 0), tbox(6, 3.8, 0.45, 0, 1.9, 1.0) },
	Hub_Lamp = { tbox(1.7, 0.8, 1.7, 0, 0.4, 0), tbox(0.7, 12.6, 0.7, 0, 6.7, 0) },
	Hub_Tree = TRUNK,
	Hub_Planter = { tbox(5.4, 1.4, 5.4, 0, 0.7, 0) },
	Hub_TitleSign = {
		tbox(3.4, 33.2, 3.4, -20.2, 16.6, 0),
		tbox(3.4, 33.2, 3.4, 20.2, 16.6, 0),
		tbox(39, 20, 1.6, 0, 22.5, 0),
	},
	Hub_PlotGate = {
		tbox(4, 16.9, 4, -14.5, 8.45, 0),
		tbox(4, 16.9, 4, 14.5, 8.45, 0),
		tbox(32, 2.8, 2.2, 0, 15.6, 0),
	},
	-- Plot frame (plot-local; the plot ground box also spans the curved front to z = -13).
	Plot_Ground = { tbox(160, 4, 533, 0, -2, 253.5) },
	Plot_Road = { tbox(2, 1.4, 520, -9, -0.3, 260), tbox(2, 1.4, 520, 9, -0.3, 260) },
	-- Just outside the footprint (x = +-[80, 81.6], z = [520, 521.6]); see plotframe.py build_border.
	Plot_Border = {
		tbox(1.6, 1.5, 533, -80.8, 0.75, 255.1),
		tbox(1.6, 1.5, 533, 80.8, 0.75, 255.1),
		tbox(163.2, 1.5, 1.6, 0, 0.75, 520.8),
	},
	Plot_EntranceArch = {
		tbox(5, 20.8, 5, -13, 10.4, 0),
		tbox(5, 20.8, 5, 13, 10.4, 0),
		tbox(30, 4.6, 3.4, 0, 17.3, 0),
	},
	Plot_LockedSlot = {
		tbox(97, 3.8, 0.8, 0, 1.9, 2.8),
		tbox(0.7, 6.7, 0.7, -6.3, 3.35, 5.0),
		tbox(0.7, 6.7, 0.7, 6.3, 3.35, 5.0),
		tbox(14, 5, 0.6, 0, 9.2, 4.4),
		tbox(8, 2.85, 4, -22, 1.42, 26),
		tbox(4, 2.85, 4, -20, 3.82, 26.5),
		tbox(6, 2.85, 4, 26, 1.42, 34),
	},
	-- Scenery (ground-pivot props stand on the island at y = -0.4).
	Scenery_Hill = {
		tbox(37, 4.0, 29, 0, 1.6, 0),
		tbox(27, 3.4, 20, 1.5, 5.3, -1),
		tbox(17, 3.2, 12, 2.5, 8.6, 0.5),
		tbox(8, 2.8, 5, 2, 11.6, 1),
	},
	Scenery_HillSmall = { tbox(19, 3.8, 14, 0, 1.5, 0), tbox(9, 3.0, 6, -1.2, 4.9, 0.8) },
	Scenery_TreePine = TRUNK,
	Scenery_Cloud = cloudStick(1),
	Scenery_CloudBig = cloudStick(2),
	Scenery_Rock = { tbox(5.2, 3, 4.2, 0.3, 1.5, 0.4) },
	-- Harvest Feast.
	Harvest_HayBale = { tbox(4.6, 2.6, 2.8, 0, 1.3, 0) },
	Harvest_Pumpkin = { tbox(3.2, 2.5, 3.2, 0, 1.25, 0) },
	Harvest_Cornucopia = { tbox(10, 10, 18, 0, 5, 1) },
	Harvest_StringLights = { tbox(0.8, 13, 0.8, -20, 6.5, 0), tbox(0.8, 13, 0.8, 20, 6.5, 0) },
	Harvest_AutumnTree = TRUNK,
	Harvest_TurkeyStatue = join(toct(4.45, 0, 1.9), { tbox(5.4, 10, 6.5, 0, 6.9, 0.3) }),
	Harvest_PieStand = STALL,
	Harvest_CornucopiaSmall = { tbox(3.4, 3.4, 6, 0, 1.7, 0.3) },
	Harvest_PumpkinPile = { tbox(7, 2.8, 4.4, 0.4, 1.4, -0.2) },
	Harvest_Scarecrow = { tbox(1.8, 9.4, 1.8, 0, 4.7, 0) },
	Harvest_Arch = {
		tbox(4.4, 9.6, 4.4, -9, 4.8, 0),
		tbox(4.4, 9.6, 4.4, 9, 4.8, 0),
		tbox(17, 3.6, 0.6, 0, 11, 0),
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
	@return string — the instance name "<key>_<index>" (or opts.name for plot-frame anchors)
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
	Huge flat ground collider: a 32-gon (8 squares rotated by 11.25°) with inradius `radius` and its
	top at `top`, 4 studs thick. Parts max out at 2048 studs per axis, so radius <= 1024.
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

-- Plot identity colours (avenue chevrons, plot gates, border caps, arch accents).
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

-- Egg stand accent per area theme (spec §3).
local AREA_TINTS: { Color3 } = {
	rgb(96, 168, 236), -- 1 Garage Lab (suburban blue garage)
	rgb(255, 146, 40), -- 2 Nuke Stand (orange awning)
	rgb(232, 64, 56), -- 3 BoomDash Delivery (red scooters)
	rgb(110, 230, 90), -- 4 Glow Rock Mine (glowing green crystals)
	rgb(110, 222, 170), -- 5 Enrichment Lab (mint clean room)
	rgb(214, 128, 70), -- 6 Rocket Factory (copper)
	rgb(255, 206, 36), -- 7 Launch Silos (hazard yellow)
	rgb(255, 120, 180), -- 8 Nuke Megastore (pink mall)
	rgb(150, 96, 220), -- 9 Space Port (purple space)
	rgb(60, 220, 240), -- 10 Mega Nuclear Facility (fusion cyan)
}

local PUMPKIN_TINTS: { Color3 } = { rgb(255, 146, 40), rgb(250, 232, 190), rgb(255, 196, 60) }
local AUTUMN_TINTS: { Color3 } = { rgb(240, 130, 40), rgb(214, 70, 46), rgb(250, 190, 50) }
local FLOWER_TINTS: { Color3 } = { rgb(255, 120, 180), rgb(255, 214, 50), rgb(170, 120, 240) }

-- =================================================================================================
-- World: hub + scenery (always built)
-- =================================================================================================

local world = newGroup()

-- Lobby floor (dais, fountain walk, welcome carpet, rim), one plot-coloured path per plot, avenues
-- (tinted per plot), districts, ring road.
place(world, "Hub_CenterPlaza", CFrame.new(), { castShadow = false, group = "hub" })
for i = 1, 8 do
	place(world, "Hub_PlazaSpoke", yaw((i - 1) * 45), { tint = PLOT_COLORS[i], castShadow = false, group = "hub" })
end
for i = 1, 8 do
	place(world, "Hub_Avenue", yaw((i - 1) * 45), { tint = PLOT_COLORS[i], castShadow = false, group = "hub" })
end
for k = 0, 7 do
	place(world, "Hub_DistrictWedge", yaw(22.5 + 45 * k), { castShadow = false, group = "hub" })
end
for i = 1, 8 do
	place(world, "Hub_RingRoadArc", yaw((i - 1) * 45), { castShadow = false, group = "hub" })
end
-- The plaza + ring road walk surface (top y = 0) as one 32-gon collider of radius 260.
groundDisc(world, 260, 0)

-- Centrepiece (owner R55): toy-nuke fountain whose eight spouts spray water arcs at the statue, the
-- giant waving Nukey facing the spawn (players turning round from the spawn see him wave) and a
-- slowly orbiting coin halo over his head.
place(world, "Hub_Monument", CFrame.new(), { persistent = true, group = "hub" })
local fountainJets: { CFrame } = {}
local ambientFx: { AmbientFxAnchor } = {}
for k = 0, 7 do
	-- Spout k (built into Hub_Monument) at r SPOUT_R on the cap, front (-Z) toward the statue.
	local cf = polar(SPOUT_R, 22.5 + 45 * k, CAP_TOP)
	-- Nozzle: the arc leaves the nose (0, len - 0.1, -0.2) rising SPRAY_PITCH toward the centre (-Z).
	local nozzle = cf * CFrame.new(0, SPOUT_LEN - 0.1, -0.2) * CFrame.Angles(math.rad(SPRAY_PITCH), 0, 0)
	table.insert(fountainJets, nozzle)
	table.insert(ambientFx, { preset = "Spray", cf = nozzle })
	table.insert(
		ambientFx,
		{ preset = "Splash", cf = cf * CFrame.new(0, POOL_TOP + 0.1 - CAP_TOP, -(SPOUT_R - LAND_R)) }
	)
end
local statueCf = CFrame.new(0, PLINTH_TOP, 0) * yaw(SPAWN_YAW + 180)
place(world, "Hub_NukeyStatue", statueCf, { persistent = true, group = "hub" })
local haloCf = CFrame.new(0, PLINTH_TOP + NUKEY_TOP + 3.5, 0)
place(world, "Hub_CoinHalo", haloCf, { group = "hub" })
for k = 0, 3 do
	table.insert(ambientFx, { preset = "Sparkle", cf = haloCf * yaw(45 + 90 * k) * CFrame.new(0, 0, 7) })
end

-- Spawn pad (encloses HubBuilder's SpawnLocation), facing outward toward egg district 0.
local spawnCf = polar(SPAWN_R, SPAWN_YAW, 0) * yaw(180)
place(world, "Hub_SpawnPad", spawnCf, { group = "hub" })

-- No plot teleport pads (owner R134): the R55 pad ring at r 62 is gone; the plot paths stay clear
-- and players walk to their plot or use the Teleport menu (see the header).

-- Numbered plot gates over every avenue's outer end (r = 222), digits on both faces (owner R13:
-- the 8 plot directions must read from the lobby; since R134 the lobby's only plot numbers).
-- Same colour as avenue i (HubLayout.plotColors[i]).
local plotGates: { GateAnchor } = {}
for i = 1, 8 do
	local cf = polar(222, (i - 1) * 45, 0)
	local name = place(world, "Hub_PlotGate", cf, { tint = PLOT_COLORS[i], group = "hub" })
	place(world, `Hub_Digit{i}`, cf * CFrame.new(0, 17.25, -1.05), { group = "hub" })
	place(world, `Hub_Digit{i}`, cf * CFrame.new(0, 17.25, 1.05) * yaw(180), { group = "hub" })
	plotGates[i] = { plot = i, model = name, cf = cf, tint = PLOT_COLORS[i] }
end

-- "SELL NUKES" lobby sign: the first thing a spawning player sees (spawn faces this way), framing
-- the egg district behind it; letters on both faces.
local titleCf = polar(96, SPAWN_YAW, BED_TOP)
local titleName = place(world, "Hub_TitleSign", titleCf, { persistent = true, group = "hub" })

-- Egg stands: areas 1-5 in district 0 (yaw 0-45), areas 6-10 in district 1 (yaw 45-90).
local eggStands: { EggStandAnchor } = {}
for area = 1, 10 do
	local district = if area <= 5 then 0 else 1
	local slot = (area - 1) % 5
	local cf = polar(FEATURE_R, 45 * district + 8.5 + 7 * slot, BED_TOP)
	local name = place(world, "Hub_EggStand", cf, { tint = AREA_TINTS[area], group = "hub" })
	eggStands[area] = {
		area = area,
		model = name,
		cf = cf,
		egg = cf * CFrame.new(0, 4.0, 0),
		prompt = cf * CFrame.new(0, 3, -6),
		tint = AREA_TINTS[area],
	}
end

-- District 2: crate stall + group chest (lid is its own model so it can swing open).
local crateCf = polar(FEATURE_R, 102.5, BED_TOP)
local crateName = place(world, "Hub_CrateStall", crateCf, { group = "hub" })
local chestCf = polar(FEATURE_R, 124, BED_TOP)
local chestName = place(world, "Hub_GroupChest", chestCf, { group = "hub" })
local lidHinge = chestCf * CFrame.new(0, 4.8, 2.3)
local lidName = place(world, "Hub_GroupChestLid", lidHinge, { group = "hub" })

-- District 3: lucky wheel stage + the spinnable wheel.
local wheelStageCf = polar(FEATURE_R + 2, 157.5, BED_TOP)
local wheelStageName = place(world, "Hub_LuckyWheelStage", wheelStageCf, { group = "hub" })
local wheelCf = wheelStageCf * CFrame.new(0, 13, 0)
local wheelName = place(world, "Hub_LuckyWheel", wheelCf, { group = "hub" })

-- District 4: three leaderboards.
local LEADERBOARDS = {
	{ stat = "CashEarned", title = "TOP CASH EARNED", tint = rgb(150, 230, 60), yawDeg = 191 },
	{ stat = "Rebirths", title = "TOP REBIRTHS", tint = rgb(150, 96, 220), yawDeg = 202.5 },
	{ stat = "Playtime", title = "TOP PLAYTIME", tint = rgb(96, 168, 236), yawDeg = 214 },
}
local leaderboards: { LeaderboardAnchor } = {}
for i, info in LEADERBOARDS do
	local cf = polar(FEATURE_R + 8, info.yawDeg, BED_TOP)
	local name = place(world, "Hub_Leaderboard", cf, { tint = info.tint, group = "hub" })
	leaderboards[i] = {
		model = name,
		cf = cf,
		stat = info.stat,
		title = info.title,
		tint = info.tint,
		-- Centre of the Screen face, 0.05 in front of it; LookVector points out toward viewers.
		screen = cf * CFrame.new(0, 12.9, -0.3),
		screenSize = Vector2.new(12.8, 17.8),
	}
end

-- District 5: codes board.
local codesCf = polar(FEATURE_R, 247.5, BED_TOP)
local codesName = place(world, "Hub_CodesBoard", codesCf, { group = "hub" })

-- Street lamps on both sides of every avenue at r 165, 13.5 off the axis (16 total: kept lean for
-- mobile / console, owner R11; the globes are Neon, so no PointLights are needed).
local lampLights: { CFrame } = {}
for i = 1, 8 do
	for _, d in { 165 } do
		for _, side in { -1, 1 } do
			local cf = yaw((i - 1) * 45) * CFrame.new(side * 13.5, 0, d)
			place(world, "Hub_Lamp", cf, { group = "hub" })
			table.insert(lampLights, cf * CFrame.new(0, 12.2, 0))
		end
	end
end

-- District dressing: a planter at the front of every bed, benches facing the features, trees
-- behind them, flower patches by the curbs. District 7 is a little park instead of a feature.
-- District 1's first tree sits at -6 (not -12): at yaw 55.5 it stood 20 studs in front of the R57
-- lobby Time Machine (yaw 54, r 207) and hid the left half of its clock face from the spawn and
-- from the walk-up; at 61.5 it is 27 studs to the machine's side and 49° off the spawn view.
local TREE_YAWS: { [number]: { number } } = {
	[0] = { -12, 0, 12 },
	[1] = { -6, 0, 12 },
	[2] = { -15, 0, 15 },
	[3] = { -12, 12 },
	[4] = { -15, -5.5, 5.5, 15 },
	[5] = { -12, 12 },
	[6] = { -15, 15 },
	[7] = {},
}
for k = 0, 7 do
	local beta = 22.5 + 45 * k
	if k == 6 then
		-- Event district: two planters flank the (event-only) entrance arch instead of one centred.
		for _, side in { -1, 1 } do
			place(world, "Hub_Planter", polar(100, beta + side * 10, BED_TOP), { group = "hub" })
		end
	else
		place(world, "Hub_Planter", polar(100, beta, BED_TOP), { group = "hub" })
	end
	if k ~= 6 then
		for _, side in { -1, 1 } do
			place(world, "Hub_Bench", polar(112, beta + side * 9, BED_TOP) * yaw(180), { group = "hub" })
		end
	end
	for _, offset in TREE_YAWS[k] do
		place(world, "Hub_Tree", polar(186, beta + offset, BED_TOP) * yaw(offset * 7), { group = "hub" })
	end
	place(world, "Scenery_Flowers", polar(125, beta + (if k % 2 == 0 then -13 else 13), BED_TOP), {
		tint = FLOWER_TINTS[k % 3 + 1],
		castShadow = false,
		group = "hub",
	})
end
-- District 7 park: tree clusters and benches facing the fountain.
for _, spot in { { 132, -11 }, { 140, 9 }, { 168, -14 }, { 172, 3 }, { 186, 15 }, { 160, -2 } } do
	place(world, "Hub_Tree", polar(spot[1], 337.5 + spot[2], BED_TOP) * yaw(spot[2] * 9), { group = "hub" })
end
for _, spot in { { 150, -14 }, { 150, 14 } } do
	place(world, "Hub_Bench", polar(spot[1], 337.5 + spot[2], BED_TOP), { group = "hub" })
end

-- ---- Lobby centre dressing (owner R55) --------------------------------------------------------

-- A floating gold coin (spins via WorldFx `Whirl`) with a soft sparkle emitter.
local function floatingCoin(cf: CFrame)
	place(world, "Hub_Coin", cf, { castShadow = false, group = "hub" })
	table.insert(ambientFx, { preset = "Sparkle", cf = cf })
end

-- Gardens in wedges 1-7 (wedge 0 is the spawn's welcome carpet): a bench facing the fountain at
-- each garden's inner tip, a banner pole on the bed and a coin spinning over the topiary ("money
-- tree", top y 16.8).
for k = 1, 7 do
	local beta = 22.5 + 45 * k
	place(world, "Hub_PlazaGarden", yaw(beta), { group = "hub" })
	place(world, "Hub_Bench", polar(44.2, beta, DAIS_TOP), { group = "hub" })
	place(world, "Hub_BannerPole", sector(k, 0, GARDEN_TOP, 52.5), { group = "hub" })
	floatingCoin(sector(k, 0, 19.6, 65.5))
end
-- Spawn wedge: two banners flank the welcome carpet wide of the spawn camera's view of the SELL
-- NUKES sign (r 96), two flower planters sit beside it further out; three coins float low over the
-- carpet, under the sign.
for _, side in { -1, 1 } do
	place(world, "Hub_BannerPole", sector(0, side * 13.5, DAIS_TOP, 61), { group = "hub" })
	place(world, "Hub_Planter", sector(0, side * 9.6, DAIS_TOP, 70), { group = "hub" })
end
for i, z in { 60, 68, 76 } do
	floatingCoin(sector(0, 0, 4.5 + i, z))
end
-- Every spoke mouth: a lamp-post gateway with a pennant string across the plot path.
for i = 1, 8 do
	place(world, "Hub_Bunting", yaw((i - 1) * 45) * CFrame.new(0, DAIS_TOP, MOUTH_Z), { group = "hub" })
end

-- ---- Scenery: island, beach, sea (persistent: seen from everywhere) ----------------------------

place(world, "Scenery_IslandGround", CFrame.new(), { persistent = true, castShadow = false, group = "scenery" })
for i = 1, 8 do
	place(world, "Scenery_BeachArc", yaw((i - 1) * 45), { persistent = true, castShadow = false, group = "scenery" })
	place(world, "Scenery_Water", yaw((i - 1) * 45), { persistent = true, castShadow = false, group = "scenery" })
end
groundDisc(world, 836, ISLAND_TOP)
groundDisc(world, 850, -0.7) -- dry sand band (Scenery_BeachArc r 828-850)
groundDisc(world, 868, -1.6) -- wet sand band (r 850-868); foam 868-874, sea beyond
-- Invisible boundary ring at the foam line (keeps players on the island).
for i = 0, 31 do
	table.insert(world.collision, {
		size = Vector3.new(2 * WALL_R * math.tan(math.pi / 32) + 4, 60, 4),
		cf = yaw(i * 11.25) * CFrame.new(0, 28, WALL_R + 2),
	})
end

-- ---- Scenery: wedge between plots (same template in all 8 sectors) ---------------------------
--[[
	Sector-local (x, z) spots, y = island top. The free half-width at distance z along the bisector
	is (z*sin22.5° - 80) / cos22.5° (plot edges), e.g. 38 at z = 300, 100 at z = 450, 178 at
	z = 640; every spot keeps its prop >= 6 studs inside it and inside the island (r <= 820).
]]
local WEDGE: { { key: string, x: number, z: number, turn: number, tint: Color3? } } = {
	{ key = "Scenery_TreePine", x = -26, z = 300, turn = 0 },
	{ key = "Hub_Tree", x = 26, z = 300, turn = 30 },
	{ key = "Hub_Tree", x = -52, z = 372, turn = 70 },
	{ key = "Scenery_TreePine", x = 54, z = 368, turn = 0 },
	{ key = "Scenery_TreePine", x = -84, z = 450, turn = 0 },
	{ key = "Hub_Tree", x = 86, z = 446, turn = 140 },
	{ key = "Hub_Tree", x = -120, z = 540, turn = 200 },
	{ key = "Scenery_TreePine", x = 124, z = 536, turn = 0 },
	{ key = "Scenery_TreePine", x = -160, z = 640, turn = 0 },
	{ key = "Hub_Tree", x = 162, z = 636, turn = 260 },
	{ key = "Hub_Tree", x = -196, z = 736, turn = 320 },
	{ key = "Scenery_TreePine", x = 200, z = 730, turn = 0 },
	{ key = "Scenery_Pond", x = 0, z = 410, turn = 0 },
	{ key = "Scenery_Hill", x = -60, z = 610, turn = 20 },
	{ key = "Scenery_Hill", x = 70, z = 700, turn = -35 },
	{ key = "Scenery_HillSmall", x = 40, z = 520, turn = 60 },
	{ key = "Scenery_HillSmall", x = -90, z = 720, turn = -20 },
	{ key = "Scenery_Cloud", x = -20, z = 560, turn = 15 },
	{ key = "Scenery_Cloud", x = 110, z = 600, turn = -25 },
	{ key = "Scenery_CloudBig", x = 0, z = 800, turn = 0 },
	{ key = "Scenery_Rock", x = 30, z = 330, turn = 40 },
	{ key = "Scenery_Rock", x = -40, z = 470, turn = 110 },
	{ key = "Scenery_Rock", x = 95, z = 590, turn = 200 },
	{ key = "Scenery_Flowers", x = -20, z = 340, turn = 0, tint = FLOWER_TINTS[1] },
	{ key = "Scenery_Flowers", x = 45, z = 460, turn = 30, tint = FLOWER_TINTS[2] },
	{ key = "Scenery_Flowers", x = -70, z = 540, turn = 60, tint = FLOWER_TINTS[3] },
	{ key = "Scenery_Flowers", x = 10, z = 650, turn = 90, tint = FLOWER_TINTS[1] },
}
for k = 0, 7 do
	for _, spot in WEDGE do
		place(world, spot.key, sector(k, spot.x, ISLAND_TOP, spot.z, spot.turn), {
			tint = spot.tint,
			castShadow = if spot.key == "Scenery_Flowers" or spot.key == "Scenery_Pond" then false else nil,
			group = "scenery",
		})
	end
end

-- ---- World portals (owner R57) ----------------------------------------------------------------
-- Appended LAST so every earlier placement keeps its "<key>_<index>" name. District 1 forecourt:
-- the Time Machine to Dino Valley, turned to face the spawn so its clock face + "DINO VALLEY" sign
-- read from the spawn area (a ~39° turn left, see PORTAL_R above); first-wave (within MeshLibrary's
-- 200-stud near-hub radius of the spawn).
-- Pure yaw toward the spawn (CFrame.Angles, not CFrame.lookAt: Lune's lookAt flips Z, so the tests
-- and the z-fight audit would check a different pose than Roblox builds).
local portalPos = (yaw(PORTAL_YAW) * CFrame.new(0, 0, PORTAL_R)).Position
local toSpawn = spawnCf.Position - portalPos
local portalCf = CFrame.new(portalPos) * CFrame.Angles(0, math.atan2(-toSpawn.X, -toSpawn.Z), 0)
local portalName = place(world, "Hub_TimeMachine", portalCf, { group = "hub" })
-- The Moon Rocket to Moon Base (owner R70), appended after the Time Machine for the same reason
-- (no older name moves); also turned to face the spawn (~44.5° right, see MOON_PORTAL_R above).
local moonPortalPos = (yaw(MOON_PORTAL_YAW) * CFrame.new(0, 0, MOON_PORTAL_R)).Position
local moonToSpawn = spawnCf.Position - moonPortalPos
local moonPortalCf = CFrame.new(moonPortalPos) * CFrame.Angles(0, math.atan2(-moonToSpawn.X, -moonToSpawn.Z), 0)
local moonPortalName = place(world, "Hub_MoonRocket", moonPortalCf, { group = "hub" })

-- =================================================================================================
-- Harvest Feast event group (district 6, bisector yaw 292.5°)
-- =================================================================================================

local EVENT_K = 6
local harvest = newGroup()

local function ev(key: string, x: number, z: number, turn: number?, opts: PlaceOptions?): string
	return place(harvest, key, sector(EVENT_K, x, BED_TOP, z, turn), opts)
end

--[[
	Event square plan (sector-local x = lateral, z = distance from the centre; bed: z 92-194,
	|x| <= (z*sin22.5° - 16)/cos22.5°). Permanent district-6 items it works around: planters at
	(+-17.4, 98.5), flowers at (+-28.1, 121.8), trees at (+-48.1, 179.7).
		front  z 104-140  hay-bale arch, bales + pumpkins, front string lights, turkey statue (right),
		                  pie stand (left)
		middle z 140-176  giant cornucopia (centre) with bales and pumpkins, side string lights x = +-40
		back   z 170-190  Harvest egg stand (right), autumn trees, back string lights, pumpkins
]]
ev("Harvest_Arch", 0, 104)
ev("Harvest_Cornucopia", 0, 158)
ev("Harvest_TurkeyStatue", 20, 134, -20) -- keep in sync with turkeyStatueCf below
ev("Harvest_PieStand", -26, 140, 20)
local harvestStandCf = sector(EVENT_K, 28, BED_TOP, 176, -12)
local harvestStandName = place(harvest, "Hub_EggStand", harvestStandCf, { tint = rgb(255, 146, 40) })
ev("Harvest_StringLights", 0, 116)
ev("Harvest_StringLights", 0, 188)
ev("Harvest_StringLights", -40, 165, 90)
ev("Harvest_StringLights", 40, 165, 90)
for _, spot in
	{
		{ -15, 108, 0 },
		{ 15, 108, 0 },
		{ -8, 150, 30 },
		{ 8, 150, -30 },
		{ -38, 172, 90 },
		{ 36, 146, 90 },
		{ 30, 186, 20 },
		{ 16, 176, 70 },
	}
do
	ev("Harvest_HayBale", spot[1], spot[2], spot[3])
end
-- A second bale stacked on the first (top of a bale is y = 2.6).
place(harvest, "Harvest_HayBale", sector(EVENT_K, -15, BED_TOP + 2.6, 108, 90))
for i, spot in
	{
		{ -6, 110 },
		{ 6, 111 },
		{ -12, 145 },
		{ 12, 144 },
		{ -36, 156 },
		{ 34, 139 },
		{ 12, 186 },
		{ -12, 188 },
		{ -34, 186 },
		{ 46, 166 },
		{ 22, 170 },
		{ -26, 116 },
	}
do
	ev("Harvest_Pumpkin", spot[1], spot[2], i * 37, { tint = PUMPKIN_TINTS[i % 3 + 1] })
end
for i, spot in { { -24, 174 }, { 0, 184 } } do
	ev("Harvest_AutumnTree", spot[1], spot[2], i * 50, { tint = AUTUMN_TINTS[i % 3 + 1] })
end
-- Autumn touches by the spawn and the fountain (also event-only). The bales flank the welcome
-- carpet just past the spawn pad (off the plot paths, R55 lobby).
for _, side in { -1, 1 } do
	place(harvest, "Harvest_HayBale", sector(0, side * 8.6, 0, 53.5, 90))
end
for i, yawDeg in { 52.5, 112.5, 172.5, 232.5, 292.5, 352.5 } do
	place(harvest, "Harvest_Pumpkin", polar(31.5, yawDeg, 0.1) * yaw(i * 60), { tint = PUMPKIN_TINTS[i % 3 + 1] })
end

local turkeyPoints: { CFrame } = {}
for _, spot in { { -10, 125 }, { 10, 124 }, { -30, 162 }, { 30, 166 }, { 0, 136 }, { -12, 182 }, { 14, 182 } } do
	table.insert(turkeyPoints, sector(EVENT_K, spot[1], BED_TOP, spot[2]))
end
for k = 0, 7 do
	if k ~= EVENT_K then
		table.insert(turkeyPoints, polar(125, 22.5 + 45 * k, BED_TOP))
	end
end

-- =================================================================================================
-- Plot frame (plot-local) + locked slot placeholder (slot-local)
-- =================================================================================================

local frame = newGroup()
place(frame, "Plot_Ground", CFrame.new(), { castShadow = false, name = "Ground" })
place(frame, "Plot_Road", CFrame.new(), { castShadow = false, name = "Road" })
place(frame, "Plot_Border", CFrame.new(), { plotTint = true, name = "Border" })
local ARCH_Z = 4
place(frame, "Plot_EntranceArch", CFrame.new(0, 0, ARCH_Z), { plotTint = true, name = "EntranceArch" })
-- Backdrop behind the plot's back wall (on the island ground) + one big shoreline cloud.
for _, spot in
	{
		{ "Hub_Tree", -64, 532, 20 },
		{ "Scenery_TreePine", -24, 536, 0 },
		{ "Hub_Tree", 20, 531, 160 },
		{ "Scenery_TreePine", 62, 535, 0 },
	}
do
	place(
		frame,
		spot[1] :: string,
		CFrame.new(spot[2] :: number, ISLAND_TOP, spot[3] :: number) * yaw(spot[4] :: number)
	)
end
place(frame, "Scenery_CloudBig", CFrame.new(44, ISLAND_TOP, 552) * yaw(180))

local plotTurkeys: { CFrame } = {}
for i, z in { 70, 170, 270, 370, 470 } do
	table.insert(plotTurkeys, CFrame.new(if i % 2 == 0 then 9 else -9, 0.4, z))
end

local locked = newGroup()
place(locked, "Plot_LockedSlot", CFrame.new(), { name = "LockedSlot" })

-- =================================================================================================
-- Module table
-- =================================================================================================

local HubLayout = {}

HubLayout.version = 1
-- We ship the walkable ground (meshes + 32-gon colliders): HubBuilder skips its placeholder discs.
HubLayout.ground = false
HubLayout.spawn = spawnCf
HubLayout.models = world.models
HubLayout.collision = world.collision

local turkeySpawns: { Vector3 } = {}
for _, point in turkeyPoints do
	table.insert(turkeySpawns, point.Position)
end
local turkeyStatueCf = sector(EVENT_K, 20, BED_TOP, 134, -20)
-- `harvest` is the canonical group; models / collision / square / turkeySpawns / npc are the flat
-- names the event service (B11) reads.
HubLayout.event = {
	harvest = harvest,
	models = harvest.models,
	collision = harvest.collision,
	square = sector(EVENT_K, 0, BED_TOP, 148),
	squareSize = Vector3.new(96, 20, 100),
	turkeySpawns = turkeySpawns,
	npc = turkeyStatueCf * CFrame.new(0, 3, -6.5),
}

HubLayout.plotFrame = {
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
		TurkeySpawnPoints = plotTurkeys,
	},
} :: PlotFrame

--[[
	Plot decoration slots (PLOT-LOCAL) for Harvest Feast items bought with Acorns (B11). `Arch` =
	ground at the road centre 8 studs past the entrance arch (Harvest_Garland's pivot: its poles
	stand on the curbs, the swag hangs at y ~ 12.5 over the road). Ground* slots are free spots on
	the island just outside the plot's front corners (|x| > 80, off the ring road, clear of the
	wedge props). B11's own lawn slots (LawnA..LawnE) live in its event config.
]]
HubLayout.plotDecor = {
	GroundL1 = CFrame.new(-88, ISLAND_TOP, 4),
	GroundL2 = CFrame.new(-100, ISLAND_TOP, 12),
	GroundL3 = CFrame.new(-112, ISLAND_TOP, 22), -- room for the ~9-wide Turkey statue (B11)
	GroundR1 = CFrame.new(88, ISLAND_TOP, 4),
	GroundR2 = CFrame.new(100, ISLAND_TOP, 12),
	Arch = CFrame.new(0, 0, ARCH_Z + 8),
} :: { [string]: CFrame }

HubLayout.lockedSlot = {
	models = locked.models,
	collision = locked.collision,
	sign = CFrame.new(0, 9.2, 4.4 - 0.21),
} :: LockedSlot

HubLayout.anchors = {
	SpawnPoint = spawnCf,
	EggStands = eggStands,
	HarvestEggStand = {
		area = 0,
		model = harvestStandName,
		cf = harvestStandCf,
		egg = harvestStandCf * CFrame.new(0, 4.0, 0),
		prompt = harvestStandCf * CFrame.new(0, 3, -6),
		tint = rgb(255, 146, 40),
	},
	CrateStall = {
		model = crateName,
		cf = crateCf,
		display = crateCf * CFrame.new(0, 3.7, -2.9),
		prompt = crateCf * CFrame.new(0, 3, -7.5),
	},
	LuckyWheelStage = {
		model = wheelStageName,
		wheelModel = wheelName,
		cf = wheelStageCf,
		wheel = wheelCf,
		prompt = wheelStageCf * CFrame.new(0, 4.5, -8),
	},
	GroupChest = {
		model = chestName,
		lidModel = lidName,
		cf = chestCf,
		lidHinge = lidHinge,
		prompt = chestCf * CFrame.new(0, 3, -6.5),
	},
	CodesBoard = { model = codesName, cf = codesCf, prompt = codesCf * CFrame.new(0, 3, -5) },
	Leaderboards = leaderboards,
	PlotGates = plotGates,
	TitleSign = { model = titleName, cf = titleCf },
	EventSquare = { cf = sector(EVENT_K, 0, BED_TOP + 10, 148), size = Vector3.new(96, 20, 100) },
	TurkeySpawnPoints = turkeyPoints,
	FountainJets = fountainJets,
	LampLights = lampLights,
	AmbientFx = ambientFx,
	WorldPortals = {
		dino = {
			model = portalName,
			cf = portalCf,
			trigger = { size = TM_TRIGGER_SIZE, cf = portalCf * CFrame.new(0, TM_RING_Y - 0.2, 0) },
			prompt = portalCf * CFrame.new(0, 4, -11),
			sign = portalCf * TM_SIGN,
			arrive = portalCf * CFrame.new(0, 0, -PORTAL_ARRIVE),
		},
		moon = {
			model = moonPortalName,
			cf = moonPortalCf,
			trigger = { size = MR_TRIGGER_SIZE, cf = moonPortalCf * CFrame.new(0, MR_RING_Y - 0.2, 0) },
			prompt = moonPortalCf * CFrame.new(0, 4, -11),
			sign = moonPortalCf * MR_SIGN,
			arrive = moonPortalCf * CFrame.new(0, 0, -PORTAL_ARRIVE),
		},
	},
} :: Anchors

-- SurfaceGui-ready faces. `size` is the panel's face size in studs (SurfaceGui.CanvasSize = size *
-- PixelsPerStud); faces are Enum.NormalId names on the named piece (MeshPart bounding box face).
HubLayout.surfaces = {
	Hub_Monument = {
		{ piece = "Plaque", faces = { "Front", "Back" }, size = Vector2.new(11, 2.6), use = "SELL NUKES title" },
	},
	Hub_EggStand = { { piece = "Sign", faces = { "Front" }, size = Vector2.new(9.2, 3.2), use = "egg name + price" } },
	Hub_CrateStall = { { piece = "Sign", faces = { "Front" }, size = Vector2.new(9.65, 2.45), use = "SUPPLY CRATES" } },
	Hub_LuckyWheelStage = {
		{ piece = "Sign", faces = { "Front" }, size = Vector2.new(11.6, 3.2), use = "LUCKY WHEEL + free spin timer" },
	},
	Hub_GroupChest = { { piece = "Sign", faces = { "Front" }, size = Vector2.new(7.25, 2.05), use = "GROUP REWARD" } },
	Hub_CodesBoard = { { piece = "Screen", faces = { "Front" }, size = Vector2.new(13, 8.2), use = "CODES" } },
	Hub_Leaderboard = { { piece = "Screen", faces = { "Front" }, size = Vector2.new(12.8, 17.8), use = "top-10 list" } },
	Plot_EntranceArch = {
		{
			piece = "OwnerSign",
			faces = { "Front", "Back" },
			size = Vector2.new(22, 3.6),
			use = "<DisplayName>'s Nukes",
		},
	},
	Plot_LockedSlot = {
		{ piece = "Sign", faces = { "Front" }, size = Vector2.new(13.5, 4.5), use = "COMING SOON + x / y purchases" },
	},
	Hub_TimeMachine = { { piece = "Sign", faces = { "Front" }, size = Vector2.new(13.6, 3.0), use = "DINO VALLEY" } },
	Hub_MoonRocket = { { piece = "Sign", faces = { "Front" }, size = Vector2.new(13.6, 3.0), use = "MOON BASE" } },
	Harvest_Arch = { { piece = "Sign", faces = { "Front" }, size = Vector2.new(16.55, 3.15), use = "HARVEST FEAST" } },
	Harvest_PieStand = { { piece = "Sign", faces = { "Front" }, size = Vector2.new(9.65, 2.45), use = "PIES" } },
} :: { [string]: { Surface } }

-- Flat leaderboard screen list (B11): [1] lifetime cash, [2] rebirths, [3] playtime.
local leaderboardScreens: { { cf: CFrame, size: Vector2 } } = {}
for i, board in leaderboards do
	leaderboardScreens[i] = { cf = board.screen, size = board.screenSize }
end
HubLayout.leaderboards = leaderboardScreens

HubLayout.plotColors = PLOT_COLORS
HubLayout.areaTints = AREA_TINTS

--[[
	Unique mesh keys of a group, for MeshLibrary.preload.
	@param group string? — "hub" | "scenery" (world models), "event", "plot" (plot frame + locked
	                       slot); nil = everything
	@return { string }
	Example: MeshLibrary.preload(HubLayout.keys("hub"))
]]
function HubLayout.keys(group: string?): { string }
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
	if group == nil or group == "hub" or group == "scenery" then
		add(world.models, group)
	end
	if group == nil or group == "event" then
		add(harvest.models, nil)
	end
	if group == nil or group == "plot" then
		add(frame.models, nil)
		add(locked.models, nil)
	end
	table.sort(out)
	return out
end

--[[
	Purely decorative lobby keys (owner R55 dressing, perf follow-up 2026-10-30): the lobby grew from
	514 to 660 MeshParts and WorldReady regressed 7.1 s -> 9.6 s. These keys are NOT needed to play
	or to read the lobby, so they load in a second wave:
		* Server/World/HubBuilder spawns them in its second pass (after its first-view pass has
		  released MeshLibrary.holdWorldReady): `deferred` spawns at Background priority that never
		  hold WorldReady; the ambient particles are built with them;
		* MeshLibrary's boot split (W1b) treats them as far hub decoration (not first view), so the
		  tier-1 preload the loading screen waits on never includes them.
	Everything else stays in the first wave: plaza floor, plot paths, fountain + statue, spawn pad,
	title sign, plot gates + digits, avenues / districts / ring road and every fixture an
	anchor points at (egg stands, stalls, wheel, chest, boards). Colliders are never deferred (the
	garden beds are walkable boxes from the first frame).
]]
local DEFERRED_KEYS: { string } =
	{ "Hub_PlazaGarden", "Hub_Bunting", "Hub_BannerPole", "Hub_Coin", "Hub_CoinHalo", "Hub_Bench" }
local DEFERRED_SET: { [string]: boolean } = {}
for _, key in DEFERRED_KEYS do
	DEFERRED_SET[key] = true
end
HubLayout.deferredKeys = table.freeze(DEFERRED_KEYS)

--[[
	True when `key` is lobby decor that loads after WorldReady (see deferredKeys).
	@param key string  a MeshAssets model key
	@return boolean
	Example: if HubLayout.isDeferred(entry.key) then table.insert(later, entry) end
]]
function HubLayout.isDeferred(key: string): boolean
	return DEFERRED_SET[key] == true
end

-- =================================================================================================
-- Lobby visitors' walk graph (owner R100, L-lobby; Client/Lobby/LobbyNpcLogic walks it)
-- =================================================================================================
--[[
	HubLayout.lobbyWalk = { nodes, links, seats } — where the client-side R15 visitors may stroll.
	World space, y = the walk surface (plaza / beds ~0.1; visitors' feet go here).

		nodes[i] = { pos, jitter, idle, look?, kind }
			jitter  each visit aims at pos + a random offset within this radius (crowds spread out)
			idle    chance (0..1) a visitor stops here (faces `look` when set)
			kind    "ring" | "lane" | "mouth" | "avenue" | "end" | "feature" (debug + tests)
		links[i] = { j, ... } — undirected walkable segments (both directions listed)
		seats[s] = { cf, approach, node } — one sitting spot: the root faces cf.LookVector at cf
			(seat top level); a visitor walks node → approach → sits, and back the same way.

	The graph (everything stays on paving, clear of every HubLayout.collision box; tests/lobby.luau
	checks each segment keeps >= 1.25 studs + jitter from every box a body would touch):
		ring     15 nodes on the fountain walk (r 37, every 22.5°), linked in a C that skips the
		         spawn wedge (yaw 22.5: the spawn pad, where fresh players appear)
		lane     on each plot path at r 62 (spoke-local x = +-10, where the R55 pads stood beside
		         until owner R134; sides alternate per spoke, paths 1 + 2 pass away from the spawn pad)
		mouth    each path's mouth at the lime rim (r 88), then the avenue axis at r 121 / 165 and
		end      r 205 (short of the plot gate at r 222): a visitor "checks out" plot i
		feature  in front of each district's feature (eggs, crate stall + chest, Lucky Wheel,
		         leaderboards, codes board, the park), linked to both neighbouring avenues at r 121;
		         district 6 (the Harvest Feast square) is skipped so event decor never meets a walker
		seats    2 per bench: the 7 garden benches (r 44.2, facing the fountain), the district benches
		         (r 112, facing the features) and the 2 park benches (r 150)
]]
export type WalkNode = { pos: Vector3, jitter: number, idle: number, look: Vector3?, kind: string }
export type WalkSeat = { cf: CFrame, approach: Vector3, node: number }
export type LobbyWalk = { nodes: { WalkNode }, links: { { number } }, seats: { WalkSeat } }

local WALK_Y = BED_TOP
local walkNodes: { WalkNode } = {}
local walkLinks: { { number } } = {}
local walkSeats: { WalkSeat } = {}

-- Adds a node; returns its index.
local function walkNode(pos: Vector3, jitter: number, idle: number, kind: string, look: Vector3?): number
	table.insert(
		walkNodes,
		{ pos = Vector3.new(pos.X, WALK_Y, pos.Z), jitter = jitter, idle = idle, look = look, kind = kind }
	)
	local links: { number } = {}
	table.insert(walkLinks, links)
	return #walkNodes
end

-- Links two nodes both ways.
local function walkLink(a: number, b: number)
	table.insert(walkLinks[a], b)
	table.insert(walkLinks[b], a)
end

-- Two seats on one bench (x = +-1.4 along the seat), sitting toward the bench front (-Z).
local SEAT_X = 1.4
local SEAT_TOP = 1.8 -- Hub_Bench seat box top (collider tbox(6, 1.8, 1.9, ...))
local function benchSeats(benchCf: CFrame, node: number)
	for _, x in { -SEAT_X, SEAT_X } do
		table.insert(walkSeats, {
			cf = benchCf * CFrame.new(x, SEAT_TOP, -0.25),
			approach = (benchCf * CFrame.new(x, 0, -3)).Position,
			node = node,
		})
	end
end

local FOUNTAIN_LOOK = Vector3.new(0, PLINTH_TOP + 10, 0) -- Nukey's chest
-- r 37 on the fountain walk (27.6-38.4): clear of the basin collider's star tips (two 44-stud
-- squares reach r 31.1 at every 45°) and of the Harvest pumpkins at r 31.5. The spawn wedge
-- (k = 1, yaw 22.5) is skipped: the spawn pad's collider reaches r 30.6 there and fresh players
-- appear on it, so the ring is a C from yaw 45 round to yaw 0.
local RING_R = 37
local SPAWN_RING_K = 1
local ring: { [number]: number } = {}
for k = 0, 15 do
	if k ~= SPAWN_RING_K then
		ring[k] = walkNode(polar(RING_R, 22.5 * k, 0).Position, 1.2, 0.2, "ring", FOUNTAIN_LOOK)
	end
end
for k = 0, 15 do
	local nextK = (k + 1) % 16
	if k ~= SPAWN_RING_K and nextK ~= SPAWN_RING_K then
		walkLink(ring[k], ring[nextK])
	end
end

-- Plot paths → avenues. avenueNear[i] = the r 121 node of avenue i (features link to it).
local avenueNear: { number } = {}
for i = 1, 8 do
	local a = (i - 1) * 45
	-- Lane at x = +-10 (it cleared the R55 pad collider's star tip at x 7.6 until owner R134 removed
	-- the pads; the garden bed starts at 12.5). Odd spokes take -x, even +x, so paths 1 and 2 pass
	-- AWAY from the spawn pad.
	local side = if i % 2 == 1 then -1 else 1
	local lane = walkNode((yaw(a) * CFrame.new(side * 10, 0, LANE_R)).Position, 0.8, 0.05, "lane")
	local mouth = walkNode((yaw(a) * CFrame.new(0, 0, 88)).Position, 1.5, 0.05, "mouth")
	local near = walkNode((yaw(a) * CFrame.new(0, 0, 121)).Position, 2.2, 0.1, "avenue")
	local mid = walkNode((yaw(a) * CFrame.new(0, 0, 165)).Position, 3, 0.1, "avenue")
	-- Looks down the road at plot i (the arch behind the plot gate).
	local far = walkNode((yaw(a) * CFrame.new(0, 0, 205)).Position, 3, 0.5, "end", (yaw(a) * Vector3.new(0, 8, 280)))
	walkLink(ring[2 * (i - 1)], lane)
	walkLink(lane, mouth)
	walkLink(mouth, near)
	walkLink(near, mid)
	walkLink(mid, far)
	avenueNear[i] = near
end

-- Feature fronts: district k's node, what visitors look at there, its radius.
-- jitter: smaller where the front is tight (the wheel stage's collider star tip reaches r 119.9;
-- the park bench path passes a tree).
local FEATURE_FRONTS: { [number]: { r: number, look: Vector3, jitter: number? } } = {
	[0] = { r = 121, look = polar(FEATURE_R, 22.5, 6).Position }, -- egg stands, areas 1-5
	[1] = { r = 121, look = polar(FEATURE_R, 67.5, 6).Position }, -- egg stands, areas 6-10
	[2] = { r = 121, look = polar(FEATURE_R, 112.5, 6).Position }, -- crate stall + group chest
	[3] = { r = 116.8, jitter = 1.5, look = (wheelCf * CFrame.new(0, -2, 0)).Position }, -- the Lucky Wheel
	[4] = { r = 120, look = polar(FEATURE_R + 8, 202.5, 12).Position }, -- leaderboards
	[5] = { r = 121, look = polar(FEATURE_R, 247.5, 9).Position }, -- codes board
	[7] = { r = 121, jitter = 1.2, look = polar(160, 337.5, 6).Position }, -- the park
}
local featureNode: { [number]: number } = {}
for k = 0, 7 do
	local front = FEATURE_FRONTS[k]
	if front == nil then
		continue -- district 6: the Harvest Feast square
	end
	local node = walkNode(polar(front.r, 22.5 + 45 * k, 0).Position, front.jitter or 2.2, 0.85, "feature", front.look)
	walkLink(node, avenueNear[k + 1])
	walkLink(node, avenueNear[(k + 1) % 8 + 1])
	featureNode[k] = node
end

-- Seats: garden benches (from the ring node on the wedge bisector), district benches (from the
-- feature node), park benches (from the park node).
for k = 1, 7 do
	benchSeats(polar(44.2, 22.5 + 45 * k, DAIS_TOP), ring[2 * k + 1])
end
for k = 0, 7 do
	local node = featureNode[k]
	if node ~= nil and k ~= 6 then
		for _, side in { -1, 1 } do
			benchSeats(polar(112, 22.5 + 45 * k + side * 9, BED_TOP) * yaw(180), node)
		end
	end
end
for _, spot in { { 150, -14 }, { 150, 14 } } do
	benchSeats(polar(spot[1], 337.5 + spot[2], BED_TOP), featureNode[7])
end

HubLayout.lobbyWalk = { nodes = walkNodes, links = walkLinks, seats = walkSeats } :: LobbyWalk

return table.freeze(HubLayout)
