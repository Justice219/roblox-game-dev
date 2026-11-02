--!strict
--[[
	Worlds/Dino/Layouts/Area06 — slot layout of Dino Valley area D6 "Volcano Reactor", the Dino
	FINALE (spec 2026-10-31-world2-design §6.2 / §16; W8 art-d56).

	Contract: identical to AreaLayouts/AreaNN (docs/superpowers/plans/2026-10-30-sellnukes-build.md
	→ "World layout"), validated by src/server/Tycoon/LayoutLogic.luau against the Dino AreaConfig
	(Worlds/Dino/Areas/Area06). `base` is built when D5's Unlock pad ("Wake the Volcano", key
	D6_EntryArch) is bought, `builds[buildKey]` when that pad is bought (LEGO build-in). The finale
	pad (Golden T-Rex Statue, feature "Rebirth") is an ordinary own build of this area.

	Meshes: tools/blender/models/dino_area06.py (D6_*). Art + FX notes: docs/areas-art.md → "Dino D5-D6".

	Frame: SLOT-LOCAL studs. Origin = road-side edge midpoint, +Z away from the road, +Y up,
	x ∈ [-52, 52], z ∈ [0, 70], height budget 140 (finale; the statue's crown tops out at ~66).
	Identity rotation = model front (-Z) faces the road; standing on the road, +X is on your LEFT.
	The ash lot (D6_Floor) is a 0.5-stud plate: everything stands at y = LOT.

	Scene (top-down, road at the bottom):
		z 28-68  the volcano (r 19.5 foot, rim y 38.5 slot) at the centre: reactor door + core window
		         facing the road, west terrace (y 14.5..15.4) on its -X flank, obsidian crown on the
		         rim and the GOLDEN T-REX on a pillar rising out of the crater (crown y ~66)
		z 36     basalt spire (x -46) with the sky bridge sagging across to the volcano terrace
		z 47-60  lava falls cliff (x 36) · crystal core ring (x -36, z 55)
		z 16-28  twin lava channels (x ±7.5) from the volcano's foot outlets to front basins, a stone
		         turbine astride each (z 24) · magma pumps (x 30 / 42) · steam vents (x -33) ·
		         Chief Tyra at her control podium (x -18.9, z 23)
		z  3     VOLCANO / REACTOR arch (clear width 20); flagstones up to the door steps (z ~23.5)
		z 10     pad row (x ±16..48) + the finale pad on the path at (0, 14)
	Low basalt wall with moss caps on the sides (z 20..70) and back; palms in the back corners.

	Geometry coupling (all derived in dino_area06.py; move them together):
		VOLCANO slot (0, 48): the channel troughs end 0.15 short of the outlet hoods (volcano-local
		z -19.633 → slot 28.367); the Sky Bridge spire foot is at SKY_SPIRE and its deck lands on the
		terrace top (volcano bridge angle 194.6 deg); the statue pivot is the crater islet top (36.4).

	Animated pieces (WorldFx names): D6_VolcanoBase Core (core window light) + Lamp (door torches);
	D6_VolcanoTop CoreLava (crater light), Bubbles (bob), SteamCloud (Steam); D6_LavaChannel /
	D6_LavaFalls LavaFlow / LavaFall (W10 row "Lava": scroll) + Bubbles; D6_StoneTurbines Wheel*
	(spin X); D6_MagmaPumps Arm* (nod about X); D6_SteamVents SteamA/B/C; D6_CrystalCore Crystal
	(light) + Twirl* (slow spin); D6_ObsidianCrown CrystalTips (light); D6_SkyBridge Lamp.
	Manager: D6_ChiefTyra (R30 rig pieces; joints printed by the Blender build).

	Collision: invisible primitive boxes (meshes never collide). The cone uses stacked nested boxes
	inscribed in its narrowest radius per band; the terrace and the bridge deck are walkable.

	Example:
		local layout = require(ReplicatedStorage.Shared.Config.Worlds.Dino.Layouts.Area06)
		print(#layout.builds.D6_VolcanoCore.models) --> 2 (VolcanoBase + VolcanoTop)
]]

export type ModelPlacement = { key: string, cf: CFrame, tint: Color3?, castShadow: boolean?, collide: boolean? }
export type CollisionBox = { size: Vector3, cf: CFrame }
export type BuildGroup = { models: { ModelPlacement }, collision: { CollisionBox } }

-- Ash lot top (D6_Floor): every model stands at this height.
local LOT = 0.5
-- Arch post centre |x| (dino_arch: inner 20 + post 3.6 → 11.8) and pad row z.
local ARCH_POST_X = 11.8
local PAD_Z = 10

-- Volcano geometry (dino_area06.py): door plane, outlets, terrace, islet.
local DOOR_Z = -18.737 -- -vr(270 deg, 2): door / portal reference plane (volcano-local)
local OUTLET_X = 7.5
local OUTLET_Z = -19.633 -- outlet hood front faces (volcano-local)
local CHANNEL_LEN = 10.217 -- channel-local z of the trough ends (0.15 short of the hoods)
local ISLET_TOP = 36.4 -- crater islet top = D6_GoldenTRex pivot (volcano-local y)
local LEDGE_Y0, LEDGE_Y1 = 14, 14.9 -- west terrace slab
local BRIDGE_DEG = 194.621 -- volcano-local angle of the bridge landing (gap in the railing)
-- Cone bands (y0, y1, narrowest radius at y1 over all angles): inscribed collision.
local CONE_BANDS = {
	{ 0, 4, 15.064 },
	{ 4, 8, 13.132 },
	{ 8, 12, 11.592 },
	{ 12, 16, 10.385 },
	{ 16, 20, 9.419 },
	{ 20, 24, 8.694 },
	{ 24, 28, 8.09 },
	{ 28, 32, 7.607 },
	{ 32, 38, 7.2 },
}
-- Terrace arcs (volcano-local): centre angle (deg) and outer radius per 19-degree segment.
local TERRACE = {
	{ 159.5, 15.316 },
	{ 178.5, 13.706 },
	{ 197.5, 14.103 },
	{ 216.5, 14.143 },
	{ 235.5, 14.107 },
}
-- Sky bridge deck (spire-local, deck centre line): start on the platform, end on the terrace top.
local BRIDGE_START = Vector3.new(2.516, 15.125, 0.656)
local BRIDGE_END = Vector3.new(33.564, 15.125, 8.756)
local BRIDGE_SAG = 1.8
local SPIRE_TOP = 15.0 -- platform top (SPIRE_H 14.4 + 0.6)
-- Stone turbine axle height (D6_StoneTurbines AXLE_Y) and magma pump fulcrum (BEAM_Y).
local AXLE_Y = 3.8
local BEAM_Y = 6

--[[
	Slot-local CFrame from a position + yaw in degrees (CCW seen from above, Roblox convention).
	yaw 90 turns a model's front (-Z) toward -X; yaw -90 toward +X; 180 toward +Z.

	Example: at(-46, LOT, 36) -- the sky bridge spire
]]
local function at(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

--[[
	Collision box anchored to a placed model: `localCentre` is in the model's own frame, so the box
	follows the model's yaw.

	Example: boxOn(VENTS, Vector3.new(8.6, 2.2, 7.6), Vector3.new(0, 1.1, 0)) -- the vent mound
]]
local function boxOn(model: CFrame, size: Vector3, localCentre: Vector3): CollisionBox
	return { size = size, cf = model * CFrame.new(localCentre) }
end

--[[
	Nested boxes approximating an upright cylinder from the inside: for each half-depth `hz` the box
	half-width is sqrt(r² - hz²), so every box corner lies on the circle (never outside it).

	Example: roundCollision(CRYSTAL, 5, 0.95, 0.475, { 1.5, 3, 4.2 }) -- the crystal dais
]]
local function roundCollision(
	model: CFrame,
	radius: number,
	height: number,
	centreY: number,
	halfDepths: { number }
): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, hz in halfDepths do
		local hw = math.sqrt(radius * radius - hz * hz)
		table.insert(boxes, boxOn(model, Vector3.new(hw * 2, height, hz * 2), Vector3.new(0, centreY, 0)))
	end
	return boxes
end

--[[ Appends every box of `extra` to `list` and returns `list` (keeps the tables below readable). ]]
local function join(list: { CollisionBox }, extra: { CollisionBox }): { CollisionBox }
	for _, box in extra do
		table.insert(list, box)
	end
	return list
end

--[[
	A box standing on an arc round a model's vertical axis: centre at angle `deg` (volcano convention
	x = r cos a, z = r sin a), `radial` deep from rIn outward, `tangential` wide, y0..y1. Local Z is
	radial (yaw 90 - deg), so the box hugs the arc.

	Example: arcBox(VOLCANO, 159.5, 9.5, 15.7, 4.6, 20, 20.9) -- one terrace segment
]]
local function arcBox(
	model: CFrame,
	deg: number,
	rIn: number,
	rOut: number,
	tangential: number,
	y0: number,
	y1: number
): CollisionBox
	local a = math.rad(deg)
	local r = (rIn + rOut) / 2
	return {
		size = Vector3.new(tangential, y1 - y0, rOut - rIn),
		cf = model
			* CFrame.new(r * math.cos(a), (y0 + y1) / 2, r * math.sin(a))
			* CFrame.Angles(0, math.rad(90 - deg), 0),
	}
end

-- Shared placements.
local ARCH = at(0, LOT, 3)
local VOLCANO = at(0, LOT, 48)
local STATUE = VOLCANO * CFrame.new(0, ISLET_TOP, 0)
local CHANNEL = at(0, LOT, 18) -- basin centres at local (±7.5, 0, 0); troughs along +Z
local TURBINES = { at(OUTLET_X, LOT, 24), at(-OUTLET_X, LOT, 24) }
local PUMPS = { at(30, LOT, 27), at(42, LOT, 27) }
local VENTS = at(-33, LOT, 26)
local CRYSTAL = at(-36, LOT, 55)
local FALLS = at(36, LOT, 47) -- pool centre at local (0.8, 0, 0.6); cliff z 3..12.6 local
local SKY_SPIRE = at(-46, LOT, 36)
local TYRA = at(-18.9, LOT, 23) -- figure at the model origin (shared Dino body), podium at local x 4.1
local PALMS = { { 47, 64.5 }, { -47, 64.5 } }

--[[
	Volcano collision: inscribed cone bands, the reactor door portal + steps, the outlet hoods, the
	torches, and the walkable west terrace (boxes reach 9.5 into the cone so there is no gap to fall
	through) with a railing on its outer edge except at the bridge landing.
]]
local function volcanoCollision(): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, band in CONE_BANDS do
		local r = band[3]
		join(
			boxes,
			roundCollision(VOLCANO, r, band[2] - band[1], (band[1] + band[2]) / 2, { r * 0.3, r * 0.6, r * 0.85 })
		)
	end
	table.insert(boxes, boxOn(VOLCANO, Vector3.new(10.4, 11.2, 3.4), Vector3.new(0, 5.6, DOOR_Z + 0.3))) -- portal + door
	for k = 0, 2 do -- three steps up to the door
		local top = 0.36 + 0.32 * k
		local depth = 1.2 + (2 - k) * 0.95
		table.insert(
			boxes,
			boxOn(
				VOLCANO,
				Vector3.new(8.6 - 0.8 * k, top, depth),
				Vector3.new(0, top / 2, DOOR_Z - 2.3 - (2 - k) * 0.95 + 0.6)
			)
		)
	end
	for _, sx in { -1, 1 } do
		table.insert(boxes, boxOn(VOLCANO, Vector3.new(3.6, 3, 2.6), Vector3.new(sx * OUTLET_X, 1.5, OUTLET_Z + 1.3))) -- outlet hood
		table.insert(boxes, boxOn(VOLCANO, Vector3.new(0.6, 5.2, 0.6), Vector3.new(sx * 5.2, 2.6, DOOR_Z - 2.4))) -- torch post
	end
	for _, seg in TERRACE do
		local deg, rOut = seg[1], seg[2]
		table.insert(boxes, arcBox(VOLCANO, deg, 9.5, rOut, 4.8, LEDGE_Y0, LEDGE_Y1))
		-- Railing (2 high on the outer edge), skipped where the bridge lands.
		if math.abs(deg - BRIDGE_DEG) > 8 then
			table.insert(boxes, arcBox(VOLCANO, deg, rOut - 0.6, rOut - 0.1, 4.8, LEDGE_Y1, LEDGE_Y1 + 2))
		end
	end
	return boxes
end

--[[
	Sky bridge collision (spire-local → placed by SKY_SPIRE): the spire column, the platform, and the
	sagging deck as 8 straight segments (a plank floor 3 wide) with a 2-high rope-rail wall each side.
]]
local function bridgeCollision(): { CollisionBox }
	local boxes = roundCollision(SKY_SPIRE, 2.3, SPIRE_TOP, SPIRE_TOP / 2, { 0.8, 1.5, 2 })
	table.insert(boxes, boxOn(SKY_SPIRE, Vector3.new(4.8, 0.6, 4.8), Vector3.new(0, SPIRE_TOP - 0.3, 0))) -- platform
	local function deckAt(t: number): Vector3
		return BRIDGE_START:Lerp(BRIDGE_END, t) - Vector3.new(0, BRIDGE_SAG * 4 * t * (1 - t), 0)
	end
	local segments = 8
	for i = 0, segments - 1 do
		local p0, p1 = deckAt(i / segments), deckAt((i + 1) / segments)
		local mid = (p0 + p1) / 2
		local length = (p1 - p0).Magnitude + 0.2
		local frame = CFrame.lookAt(mid, p1) -- -Z along the deck, +X across it
		table.insert(boxes, { size = Vector3.new(3, 0.25, length), cf = SKY_SPIRE * frame })
		for _, side in { -1, 1 } do
			table.insert(
				boxes,
				{ size = Vector3.new(0.3, 2, length), cf = SKY_SPIRE * frame * CFrame.new(side * 1.5, 1.1, 0) }
			)
		end
	end
	return boxes
end

--[[ Stone turbine frames (one per placement): the A-frame legs + top blocks either side of the trough. ]]
local function turbineCollision(): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, cf in TURBINES do
		for _, sx in { -1, 1 } do
			table.insert(
				boxes,
				boxOn(cf, Vector3.new(0.8, AXLE_Y + 1, 3.4), Vector3.new(sx * 2.05, (AXLE_Y + 1) / 2, 0))
			)
		end
	end
	return boxes
end

--[[ Magma pumps (one set per placement): base slab, the two wells, the A-frame, the side tank. ]]
local function pumpCollision(): { CollisionBox }
	local boxes: { CollisionBox } = {}
	for _, cf in PUMPS do
		table.insert(boxes, boxOn(cf, Vector3.new(3.6, 0.6, 11), Vector3.new(0, 0.3, 0)))
		for _, sz in { -1, 1 } do
			join(boxes, roundCollision(cf * CFrame.new(0, 0, sz * 4.4), 1.65, 1.75, 0.875, { 0.6, 1.2 }))
		end
		table.insert(boxes, boxOn(cf, Vector3.new(2.8, BEAM_Y, 3), Vector3.new(0, BEAM_Y / 2, 0)))
		table.insert(boxes, boxOn(cf, Vector3.new(2, 4.35, 2), Vector3.new(-2.9, 2.175, 1.6)))
	end
	return boxes
end

--[[ Crystal core: the two dais tiers, the crystal cluster and the six rune stones. ]]
local function crystalCollision(): { CollisionBox }
	local boxes = roundCollision(CRYSTAL, 5, 0.95, 0.475, { 1.5, 3, 4.2 })
	join(boxes, roundCollision(CRYSTAL, 3.6, 1.75, 0.875, { 1.1, 2.2, 3 }))
	table.insert(boxes, boxOn(CRYSTAL, Vector3.new(3, 12, 3), Vector3.new(0, 7.45, 0)))
	for k = 0, 5 do
		local a = math.rad(60 * k + 30)
		table.insert(boxes, {
			size = Vector3.new(1.6, 4.9, 1.1),
			cf = CRYSTAL
				* CFrame.new(6.9 * math.cos(a), 2.45, 6.9 * math.sin(a))
				* CFrame.Angles(0, math.rad(90 - math.deg(a)), 0),
		})
	end
	return boxes
end

local baseCollision: { CollisionBox } = {
	{ size = Vector3.new(104, LOT, 70), cf = at(0, LOT / 2, 35) }, -- ash lot (top = LOT)
	boxOn(ARCH, Vector3.new(4.4, 10, 4.4), Vector3.new(ARCH_POST_X, 5, 0)), -- arch posts (stacked stones)
	boxOn(ARCH, Vector3.new(4.4, 10, 4.4), Vector3.new(-ARCH_POST_X, 5, 0)),
	{ size = Vector3.new(104, 2.3, 1.4), cf = at(0, LOT + 1.15, 69.3) }, -- back wall (+ moss cap)
	{ size = Vector3.new(1.4, 2.3, 50), cf = at(51.3, LOT + 1.15, 45) }, -- side walls (z 20..70)
	{ size = Vector3.new(1.4, 2.3, 50), cf = at(-51.3, LOT + 1.15, 45) },
}
for _, palm in PALMS do
	table.insert(baseCollision, { size = Vector3.new(1.3, 6, 1.3), cf = at(palm[1], LOT + 3, palm[2]) })
end

local layout = {
	area = 6,
	-- Built when D5's Unlock pad ("Wake the Volcano", key D6_EntryArch) is bought.
	base = {
		models = {
			{ key = "D6_Floor", cf = CFrame.identity, castShadow = false },
			{ key = "D6_EntryArch", cf = ARCH },
		},
		collision = baseCollision,
	} :: BuildGroup,
	builds = {
		-- Pad 1: the producer "Volcano Core" — two meshes on one pivot (hero budget split).
		D6_VolcanoCore = {
			models = {
				{ key = "D6_VolcanoBase", cf = VOLCANO },
				{ key = "D6_VolcanoTop", cf = VOLCANO },
			},
			collision = volcanoCollision(),
		},
		-- Twin lava troughs from the outlet hoods to the front basins (LavaFlow scrolls).
		D6_LavaChannel = {
			models = { { key = "D6_LavaChannel", cf = CHANNEL } },
			collision = (function(): { CollisionBox }
				local boxes: { CollisionBox } = {}
				for _, sx in { -1, 1 } do
					table.insert(
						boxes,
						boxOn(
							CHANNEL,
							Vector3.new(3, 1.4, CHANNEL_LEN - 2),
							Vector3.new(sx * OUTLET_X, 0.7, (2 + CHANNEL_LEN) / 2)
						)
					)
					join(
						boxes,
						roundCollision(CHANNEL * CFrame.new(sx * OUTLET_X, 0, 0), 2.45, 1.25, 0.625, { 0.8, 1.6, 2.1 })
					)
				end
				return boxes
			end)(),
		},
		-- A stone paddle wheel astride each trough (Wheel* spin about X).
		D6_StoneTurbines = {
			models = { { key = "D6_StoneTurbines", cf = TURBINES[1] }, { key = "D6_StoneTurbines", cf = TURBINES[2] } },
			collision = turbineCollision(),
		},
		D6_SteamVents = {
			models = { { key = "D6_SteamVents", cf = VENTS } },
			collision = {
				boxOn(VENTS, Vector3.new(8.6, 2.2, 7.6), Vector3.new(0, 1.1, 0)), -- rock mound
				boxOn(VENTS, Vector3.new(2.4, 7.8, 2.4), Vector3.new(-2.4, 3.9, 1.2)), -- chimneys
				boxOn(VENTS, Vector3.new(2.2, 6.2, 2.2), Vector3.new(2.5, 3.1, 0.8)),
				boxOn(VENTS, Vector3.new(1.9, 4.9, 1.9), Vector3.new(0.2, 2.45, -2)),
			},
		},
		-- Two nodding magma seesaw pumps (Arm* oscillate about X).
		D6_MagmaPumps = {
			models = { { key = "D6_MagmaPumps", cf = PUMPS[1] }, { key = "D6_MagmaPumps", cf = PUMPS[2] } },
			collision = pumpCollision(),
		},
		D6_CrystalCore = {
			models = { { key = "D6_CrystalCore", cf = CRYSTAL } },
			collision = crystalCollision(),
		},
		D6_LavaFalls = {
			models = { { key = "D6_LavaFalls", cf = FALLS } },
			collision = join({
				boxOn(FALLS, Vector3.new(15, 8, 9.6), Vector3.new(0, 4, 7.8)), -- cliff tiers
				boxOn(FALLS, Vector3.new(13.4, 7.2, 8.6), Vector3.new(0, 11.4, 7.9)),
				boxOn(FALLS, Vector3.new(11.6, 6.2, 7.8), Vector3.new(0, 17.9, 7.9)),
			}, roundCollision(FALLS * CFrame.new(0.8, 0, 0.6), 4.2, 1.4, 0.7, { 1.4, 2.8, 3.7 })),
		},
		-- Basalt spire + rope bridge to the volcano's west terrace (walkable).
		D6_SkyBridge = {
			models = { { key = "D6_SkyBridge", cf = SKY_SPIRE } },
			collision = bridgeCollision(),
		},
		-- Gold band + obsidian spires on the crater rim (out of reach: no collision).
		D6_ObsidianCrown = {
			models = { { key = "D6_ObsidianCrown", cf = VOLCANO } },
			collision = {},
		},
		-- Manager: Chief Tyra (hard hat, vest, clipboard) at the reactor control podium.
		D6_ChiefTyra = {
			models = { { key = "D6_ChiefTyra", cf = TYRA } },
			collision = {
				boxOn(TYRA, Vector3.new(3, 6.8, 3.2), Vector3.new(0, 3.4, 0.1)), -- Tyra
				boxOn(TYRA, Vector3.new(1.4, 2.2, 3.2), Vector3.new(0, 1.9, 2.3)), -- her tail
				boxOn(TYRA, Vector3.new(2.2, 3.2, 1.8), Vector3.new(4.1, 1.6, 0.2)), -- control podium
			},
		},
		-- FINALE: the Golden T-Rex on its pillar in the crater (feature "Rebirth").
		D6_GoldenTRex = {
			models = { { key = "D6_GoldenTRex", cf = STATUE } },
			collision = join(
				{ boxOn(STATUE, Vector3.new(3.8, 6, 3.8), Vector3.new(0, 3, 0)) }, -- pillar
				roundCollision(STATUE, 5, 1, 6.5, { 1.6, 3.2, 4.2 }) -- gold plinth
			),
		},
	} :: { [string]: BuildGroup },
	-- BuyPad ground positions: each pad sits on the pad row in front of what it builds (right of the
	-- path, seen from the road: volcano, Tyra, vents, crystal, sky bridge; left: channel, turbines,
	-- pumps, falls, crown). The finale (Golden T-Rex) waits alone on the path at (0, 14), right in
	-- front of the volcano it crowns, once every other pad is bought.
	pads = {
		d6_volcano_core = Vector3.new(-16, LOT, PAD_Z),
		d6_chief_tyra = Vector3.new(-24, LOT, PAD_Z),
		d6_steam_vents = Vector3.new(-32, LOT, PAD_Z),
		d6_crystal_core = Vector3.new(-40, LOT, PAD_Z),
		d6_sky_bridge = Vector3.new(-48, LOT, PAD_Z),
		d6_lava_channel = Vector3.new(16, LOT, PAD_Z),
		d6_stone_turbines = Vector3.new(24, LOT, PAD_Z),
		d6_magma_pumps = Vector3.new(32, LOT, PAD_Z),
		d6_lava_falls = Vector3.new(40, LOT, PAD_Z),
		d6_obsidian_crown = Vector3.new(48, LOT, PAD_Z),
		d6_golden_trex = Vector3.new(0, LOT, 14),
	} :: { [string]: Vector3 },
	-- Billboard (owner R31 / R32): FrontGap (2.5) in front of the click box (front face slot z 25.23)
	-- at eye level (7.5 over the lot): slot (0, 8, 22.7), in front of the door steps (z >= 23.5),
	-- between the turbine frames (|x| >= 5.15). The click box wraps the door + core window.
	producer = {
		anchor = Vector3.new(0, LOT + 7.5, 22.7),
		click = { size = Vector3.new(14, 16, 10), cf = VOLCANO * CFrame.new(0, 8, -17.77) },
	},
	-- Teleport target (ground level on the flagstones between the arch and the finale pad).
	spawnPoint = Vector3.new(0, LOT, 7),
}

return layout
