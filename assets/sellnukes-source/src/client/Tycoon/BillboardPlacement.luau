--!strict
--[[
	BillboardPlacement — pure maths that decides WHERE a producer billboard goes and HOW BIG it is
	(owner R31 "the upgrade GUI for the nukestand also clips", R32 "the Glowrock Mine GUI ... is
	really hard to see just because of how high it is", lead QA: the billboard must never cover
	the producer or its working manager from where players naturally stand).

	Rule:
		1. Size: a camera-facing board measured in studs (shrinks with distance like the world),
		   clamped so it always fills between MinScreen and MaxScreen of the viewport height
		   (`heightAt`). Up close it never balloons over the scene; far away it stays readable.
		2. Viewpoints: where players actually look from — standing Stands studs in front of the
		   producer's front face (toward the plot road), Lateral studs either side, with Roblox's
		   default camera CameraBack behind and CameraUp above the ground. Boxes around a
		   player's head at a stand or on the walk in (the room they stand in, the doorway or
		   entry arch they walk through) are ignored.
		3. Protected boxes: the producer's click box + where its manager works
		   (`managerRegion`, from ManagerNpcConfig work waypoints + head height). From EVERY
		   viewpoint the board's on-screen rectangle (+ ScreenMargin) must not overlap any
		   protected box's on-screen silhouette. (Two things overlap on screen iff one ray from the
		   eye hits both, so this is the honest test, independent of where the camera points.)
		4. Candidates, cheapest first: right above the producer (centred, then shifted sideways,
		   stepping up), then beside it at eye height (either side, front, stepped toward the
		   players, or centre depth). Hard limits: readable (`readableFrom`: board top at most
		   MaxElevation° above the horizon from the far stand, NearElevation° from the closer one,
		   and within MaxBearing° / NearBearing° of the producer: R32; owner R117: board centre at
		   most MaxCentre studs above the producer's floor, and producers taller than TallBody get
		   no "above" candidates at all: a tall rocket's board goes beside it at eye height) and
		   never intersecting visible geometry (awnings, signs, beams, arches, shells around the
		   producer, other systems' props: Sources.props; bounding boxes, `obbOverlap`) in ANY
		   orientation the camera-facing board takes: front-facing and facing every viewpoint's
		   camera (owner R119: a board just in front of the Silo Launch gantry swung into the frame
		   from the side stands; `slabHit`). Soft: sight lines from the centre
		   viewpoints to the board's centre + corners that hit geometry add LosPenalty each.
		5. Nothing clears the screen test (an enormous producer)? The candidate with the least
		   on-screen overlap wins, so the result is always defined.
	All boxes are { cf: CFrame, size: Vector3 } in one consistent space (slot-local for the area
	solve; world only for the client's fallback). No services, no Instances: lune-testable.

	Geometry source (`areaInput`): the config, not the streamed parts — the producer's click box +
	every visible MeshAssets piece of the FULLY BUILT plot (AreaLayouts), managers excluded. So the
	spot is deterministic, independent of what has streamed in or been bought yet, solved once per
	area + device for all 8 plots, and tests/billboard-clearance.luau audits exactly this answer.

	Example (client, ProducerBillboards.place):
		local input = BillboardPlacement.areaInput(area, sources, device, Config.Billboard, Config.Placement)
		local spot = input and BillboardPlacement.choose(input)
		point.WorldPosition = slot * spot.position -- slot = WorldLayout.slotOrigin(plot, area)
]]

-- seeThrough: glass / translucent pieces block the board's space but not sight lines.
-- round: the thing inside the box is a vertical cylinder / dome (silo, rocket, reactor): its
-- silhouette is the inscribed elliptic cylinder, not the box (whose corners are empty air).
-- prop: another system's prop (Sources.props, owner R117): beside-spots keep a little air from it.
export type Box = {
	cf: CFrame,
	size: Vector3,
	label: string?,
	seeThrough: boolean?,
	round: boolean?,
	prop: boolean?,
}
export type Obstacle = {
	cf: CFrame,
	half: Vector3,
	centre: Vector3,
	radius: number,
	label: string?,
	seeThrough: boolean?,
	prop: boolean?,
}

export type Input = {
	body: Box, -- producer click box
	protect: { Box }, -- never covered on screen (body + manager region)
	forward: Vector3, -- horizontal, from the producer toward where players stand
	ground: number, -- ground height under the producer
	obstacles: { Obstacle }, -- `filterObstacles` output
	device: boolean, -- phone / tablet / ten-foot console sizing
	fov: number, -- camera vertical field of view (degrees)
	size: any, -- TycoonClientConfig.Billboard
	cfg: any, -- TycoonClientConfig.Placement
	trace: { string }?, -- diagnostics: when given, every candidate is described here
}

export type Result = {
	position: Vector3, -- board centre
	side: number, -- +1 / -1: which side (viewer's right / left) income pops go
	right: Vector3, -- the viewer's right (unit, horizontal) in the solve's space: pops go right * side
	family: string, -- "above" | "side" | "fallback"
	clear: boolean, -- no on-screen overlap with a protected box from any viewpoint
	readable: boolean, -- fully on screen from every viewpoint + not too high (R32)
	slabClear: boolean, -- the board does not intersect visible geometry
	blockedRays: number, -- sight lines (board centre + corners, centre viewpoints) that hit geometry
	elevation: number, -- degrees above the mid camera's horizon (board top)
	height: number, -- board height (studs) at the mid viewpoint
}

-- Config the area solve reads (`areaInput`): plain tables, so the client passes the live config
-- modules and the lune audit passes the same files loaded offline. One Sources = one WORLD (owner
-- R57): Nuke Town passes AreaLayouts + ManagerKeys and no `roundBodies` (Placement.RoundBodies
-- applies); another world passes its layoutFolder's AreaNN, `managerKeysOf(worldId)`, a slotLocal
-- bound to that world and `Placement.WorldRoundBodies[worldId]`.
-- Example (Dino Valley):
--	{ layouts = DinoLayouts, meshAssets = MeshAssets, managerKeys = ManagerNpcConfig.managerKeysOf("dino"),
--	  slotLocal = function(area) return WorldLayout.slotLocal(area, "dino") end,
--	  rigs = ManagerNpcConfig.Rigs, roundBodies = Placement.WorldRoundBodies.dino }
export type Sources = {
	layouts: { [number]: any }, -- AreaLayouts.AreaNN by area index (slot-local)
	meshAssets: any, -- Shared/Config/MeshAssets
	slotLocal: (area: number) -> CFrame, -- WorldLayout.slotLocal (slot frames in plot space)
	managerKeys: { [number]: string }, -- ManagerNpcConfig.ManagerKeys / managerKeysOf(worldId)
	rigs: { [string]: any }, -- ManagerNpcConfig.Rigs
	-- Areas whose producer is round, for THIS world (Placement.WorldRoundBodies[worldId]); nil =
	-- Nuke Town's Placement.RoundBodies (the main client and audit pass nil: behaviour unchanged).
	roundBodies: { [number]: boolean }?,
	-- Owner R117: PLOT-local boxes of props other systems stand in / beside the plot (the Order
	-- Window, AA tower slots, Mega Lever, Tip Jar: Tycoon/BillboardProps). They are obstacles
	-- like layout pieces, so a beside-spot never lands inside one. nil = none.
	props: { Box }?,
}

type Candidate = {
	position: Vector3,
	family: string,
	cost: number,
	covered: number, -- summed on-screen overlap with the protected boxes (0 = clear)
	readable: boolean,
	rank: number, -- sort key: covered, + 1e6 when unreadable (only ever a last resort)
	elevation: number,
}

type View = {
	eye: Vector3,
	look: Vector3,
	right: Vector3,
	up: Vector3,
	rects: { { number } }, -- per protected box: { x1, y1, x2, y2 } or empty when unprojectable
	hulls: { { number } }, -- per protected box: its projected silhouette (convex hull, flat x, y list)
	losOnly: boolean, -- the entrance viewpoint: sight lines only
	-- Readability role (`readableFrom`): "mid" (the far straight-on stand), "near" (closer
	-- straight-on stands) or "side" (side-stepped: coverage only).
	role: string,
}

-- What `choose` and `explain` derive from an input once: the viewer frame, the effective
-- obstacles and the (popped) viewpoints.
type Context = {
	F: Vector3, -- toward the players (horizontal unit)
	R: Vector3, -- the viewer's right
	origin: Vector3, -- producer click box centre
	rMin: number,
	rMax: number,
	fMin: number,
	fMax: number,
	top: number, -- click box top (world Y)
	obstacles: { Obstacle }, -- input obstacles minus rooms around a player's head
	views: { View }, -- every player viewpoint (screen tests)
	losViews: { View }, -- centre viewpoints + the entrance one (sight lines)
	mid: View, -- the far centre viewpoint (elevation, sizing)
}

local BillboardPlacement = {}

local Y = Vector3.yAxis

-- Unit sample points of a box (its corners) and of its inscribed vertical cylinder (16 around the
-- top and bottom rims), scaled by the half size when projected.
local BOX_SAMPLES: { Vector3 } = {}
for sx = -1, 1, 2 do
	for sy = -1, 1, 2 do
		for sz = -1, 1, 2 do
			table.insert(BOX_SAMPLES, Vector3.new(sx, sy, sz))
		end
	end
end
local ROUND_SAMPLES: { Vector3 } = {}
for k = 0, 15 do
	local a = 2 * math.pi * k / 16
	-- 1 / cos(pi / 16) keeps the 16-gon around the circle (never inside the real silhouette).
	local r = 1 / math.cos(math.pi / 16)
	for _, sy in { -1, 1 } do
		table.insert(ROUND_SAMPLES, Vector3.new(math.cos(a) * r, sy, math.sin(a) * r))
	end
end

--[[
	Board height (studs) at `distance` studs from the camera: the configured world size, clamped
	so the board fills [MinScreen, MaxScreen] of the viewport height.
	@param size TycoonClientConfig.Billboard (HeightStuds, DeviceScale, Min/MaxScreen[Device])
	Example: heightAt(20, Billboard, false, 70) --> 6.4 (base size fits the screen budget)
]]
function BillboardPlacement.heightAt(distance: number, size: any, device: boolean, fov: number): number
	local base = size.HeightStuds * (if device then size.DeviceScale else 1)
	local span = 2 * math.tan(math.rad(fov) / 2) * math.max(distance, 1)
	local lo = (if device then size.MinScreenDevice else size.MinScreen) * span
	local hi = (if device then size.MaxScreenDevice else size.MaxScreen) * span
	return math.clamp(base, lo, hi)
end

--[[
	Where a manager WORKS: its `work` waypoints (model space, ManagerNpcConfig.Rigs row; every
	waypoint when none is marked) widened by `reach` studs, from the feet to the top of the head
	(+ `headroom`), as one box in the space of `model` (the manager's placement CFrame). The rest of
	its walk loop is not protected: the board must never hide the manager at work, while a manager
	strolling past a board for a moment is fine.
	Example: managerRegion(slot * entry.cf, ManagerNpcConfig.Rigs.A1_UncleAtom, 1.4, 0.6)
]]
function BillboardPlacement.managerRegion(model: CFrame, rig: any, reach: number, headroom: number): Box
	local base: Vector3 = rig.figure.base
	-- Head top above the feet: the head pivot is the neck; heads + hats reach ~2.2 above it.
	local head = rig.joints.Head
	local tall = (if head ~= nil then head.Y else base.Y) - base.Y + 2.2 + headroom
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	local anyWork = false
	for _, wp in rig.waypoints do
		anyWork = anyWork or wp.work == true
	end
	for _, wp in rig.waypoints do
		if anyWork and wp.work ~= true then
			continue
		end
		minX = math.min(minX, wp.at.X)
		maxX = math.max(maxX, wp.at.X)
		minZ = math.min(minZ, wp.at.Z)
		maxZ = math.max(maxZ, wp.at.Z)
		-- Feet height at this stop (a deck / stairs stop can sit higher than the rest pose).
		minY = math.min(minY, wp.at.Y)
		maxY = math.max(maxY, wp.at.Y)
	end
	if minX == math.huge then
		-- No waypoints at all: the rest pose only.
		minX, maxX, minZ, maxZ, minY, maxY = base.X, base.X, base.Z, base.Z, base.Y, base.Y
	end
	minX, maxX, minZ, maxZ = minX - reach, maxX + reach, minZ - reach, maxZ + reach
	local bottom = math.min(minY, base.Y)
	local top = maxY + tall
	local centre = Vector3.new((minX + maxX) / 2, (bottom + top) / 2, (minZ + maxZ) / 2)
	return {
		cf = model * CFrame.new(centre),
		size = Vector3.new(maxX - minX, top - bottom, maxZ - minZ),
		label = "manager",
	}
end

--[[
	Visible-geometry boxes near the producer, ready for the overlap / sight-line tests: drops boxes
	farther than `radius` from `centre`. (2026-10-30 QA: boxes wrapping the producer used to be
	dropped too, which hid exactly the A2 awning of owner R31, the A7 silo truss and the A8
	storefront from the solver; now only rooms around the player's head are ignored, in `choose`.)
]]
function BillboardPlacement.filterObstacles(boxes: { Box }, centre: Vector3, radius: number): { Obstacle }
	local out: { Obstacle } = {}
	for _, box in boxes do
		local half = box.size / 2
		local r = half.Magnitude
		local p = box.cf.Position
		if (p - centre).Magnitude <= radius + r then
			-- Boxes wrapping the producer (an awning over the stand, a silo frame, a storefront)
			-- stay: the board must not sit inside them. Rooms the PLAYER stands in are dropped
			-- later, per viewpoint (`choose`: a box around the player's head is never between
			-- the player and the board).
			table.insert(out, {
				cf = box.cf,
				half = half,
				centre = p,
				radius = r,
				label = box.label,
				seeThrough = box.seeThrough,
				prop = box.prop,
			})
		end
	end
	return out
end

--[[
	Visible boxes of a FULLY BUILT area layout (its base + every build), in the layout's slot-local
	space (or moved by `frame`): every mesh piece as its bounding box (MeshAssets size / offset at
	the model's placement: exactly the parts MeshLibrary spawns, primitive fallbacks included) and
	primitive `box` entries as themselves. Pieces at transparency >= 0.9 are invisible (skipped);
	pieces at >= `seeThrough` (glass) are flagged so they never block sight lines. Models whose key
	is in `skip` (managers: they walk around) are left out.
	@param layout AreaLayouts.AreaNN table
	@param meshAssets Shared/Config/MeshAssets
	@param skip set of model keys to leave out
	@param seeThrough transparency from which a piece counts as glass (Placement.SeeThrough)
	@param frame optional CFrame applied to every box (another slot's frame in this slot's space)
	@param out optional list appended to (and returned)
	Example: BillboardPlacement.layoutBoxes(Area03, MeshAssets, { A3_Dispatcher = true }, 0.25)
]]
function BillboardPlacement.layoutBoxes(
	layout: any,
	meshAssets: any,
	skip: { [string]: boolean },
	seeThrough: number,
	frame: CFrame?,
	out: { Box }?
): { Box }
	local boxes: { Box } = out or {}
	local function addGroup(group: any)
		if type(group) ~= "table" or type(group.models) ~= "table" then
			return
		end
		for _, model in group.models do
			if type(model) ~= "table" or typeof(model.cf) ~= "CFrame" then
				continue
			end
			local key = model.key
			if type(key) == "string" and skip[key] then
				continue
			end
			local cf: CFrame = if frame ~= nil then frame * model.cf else model.cf
			local asset = if type(key) == "string" then meshAssets[key] else nil
			if asset ~= nil then
				for pieceName, piece in asset.pieces do
					local transparency = piece.transparency or 0
					if transparency < 0.9 then
						table.insert(boxes, {
							cf = cf * CFrame.new(piece.offset),
							size = piece.size,
							label = `{key}.{pieceName}`,
							seeThrough = transparency >= seeThrough,
						})
					end
				end
			elseif typeof(model.box) == "Vector3" then
				table.insert(boxes, { cf = cf, size = model.box, label = model.label or "box" })
			end
		end
	end
	addGroup(layout.base)
	if type(layout.builds) == "table" then
		for _, group in layout.builds do
			addGroup(group)
		end
	end
	return boxes
end

--[[
	The solver input for area `area`'s producer in that area's SLOT-LOCAL space, from config only
	(no Instances, no streaming): the producer's click box, its manager's work region, and every
	visible piece of the FULLY BUILT plot around it (this slot + the other slots, managers left
	out). Fully built is the most crowded state, so the spot stays clear whatever gets bought later
	and the board never jumps when a build lands. Shared by the client (ProducerBillboards, solved
	once per area + device) and the audit (tests/billboard-clearance.luau): the audit proves exactly
	what ships. Plot frames are rigid, so one slot-local answer serves all 8 plots. Worlds (R57):
	the slot frame is the same in every world, so the same solve serves Dino Valley's D1-D6 when
	`sources` is that world's (its layouts, managers, slotLocal and round-producer row).
	@param sources layouts / meshes / slot frames / managers (see `Sources`)
	@return Input, or nil when the area has no usable layout / producer (the caller falls back)
	Example:
		local input = BillboardPlacement.areaInput(3, sources, false, Config.Billboard, Config.Placement)
		local spot = input and BillboardPlacement.choose(input) -- world = slot * spot.position
]]
function BillboardPlacement.areaInput(area: number, sources: Sources, device: boolean, size: any, cfg: any): Input?
	local layout = sources.layouts[area]
	if type(layout) ~= "table" or type(layout.producer) ~= "table" then
		return nil
	end
	local click = layout.producer.click
	if type(click) ~= "table" or typeof(click.cf) ~= "CFrame" or typeof(click.size) ~= "Vector3" then
		return nil
	end
	-- Round producers (silhouette = the inscribed cylinder): the world's own row when the sources
	-- carry one (Placement.WorldRoundBodies[worldId]), else Nuke Town's Placement.RoundBodies.
	local roundBodies: { [number]: boolean } = sources.roundBodies or cfg.RoundBodies
	local body: Box = { cf = click.cf, size = click.size, round = roundBodies[area] == true, label = "producer" }
	local protect: { Box } = { body }
	local key = sources.managerKeys[area]
	local rig = if key ~= nil then sources.rigs[key] else nil
	local group = if key ~= nil and type(layout.builds) == "table" then layout.builds[key] else nil
	if rig ~= nil and type(group) == "table" and type(group.models) == "table" then
		for _, entry in group.models do
			if type(entry) == "table" and entry.key == key and typeof(entry.cf) == "CFrame" then
				table.insert(
					protect,
					BillboardPlacement.managerRegion(entry.cf, rig, cfg.ManagerReach, cfg.ManagerHeadroom)
				)
				break
			end
		end
	end
	-- Managers walk around: never obstacles (the own manager's work region is protected instead).
	local skip: { [string]: boolean } = {}
	for _, managerKey in sources.managerKeys do
		skip[managerKey] = true
	end
	local boxes = BillboardPlacement.layoutBoxes(layout, sources.meshAssets, skip, cfg.SeeThrough, nil, nil)
	local here = sources.slotLocal(area)
	for other, otherLayout in sources.layouts do
		if other ~= area and type(otherLayout) == "table" then
			-- The other slot's frame in this slot's space (filterObstacles drops what is out of reach).
			local frame = here:ToObjectSpace(sources.slotLocal(other))
			BillboardPlacement.layoutBoxes(otherLayout, sources.meshAssets, skip, cfg.SeeThrough, frame, boxes)
		end
	end
	-- Owner R117: props of other systems (plot space -> this slot's space).
	if sources.props ~= nil then
		for _, prop in sources.props do
			table.insert(boxes, {
				cf = here:ToObjectSpace(prop.cf),
				size = prop.size,
				label = prop.label,
				seeThrough = prop.seeThrough,
				prop = true,
			})
		end
	end
	local centre = click.cf.Position
	-- Ground: the bottom of the click box (it sits on the producer's floor).
	local half = click.size / 2
	local ground = centre.Y
		- (
			math.abs(click.cf.RightVector.Y) * half.X
			+ math.abs(click.cf.UpVector.Y) * half.Y
			+ math.abs(click.cf.LookVector.Y) * half.Z
		)
	return {
		body = body,
		protect = protect,
		forward = Vector3.new(0, 0, -1), -- slot -Z: every area faces its plot road
		ground = ground,
		obstacles = BillboardPlacement.filterObstacles(boxes, centre, cfg.ObstacleRadius),
		device = device,
		fov = cfg.Fov,
		size = size,
		cfg = cfg,
	}
end

-- Half extent of an oriented box (axes ax/ay/az, half h) along unit axis `l`.
local function extent(l: Vector3, ax: Vector3, ay: Vector3, az: Vector3, h: Vector3): number
	return math.abs(ax:Dot(l)) * h.X + math.abs(ay:Dot(l)) * h.Y + math.abs(az:Dot(l)) * h.Z
end

-- True when `l` separates the two boxes (degenerate axes never separate).
local function separates(
	l: Vector3,
	d: Vector3,
	ax: Vector3,
	ay: Vector3,
	az: Vector3,
	ah: Vector3,
	bx: Vector3,
	by: Vector3,
	bz: Vector3,
	bh: Vector3
): boolean
	local m = l.Magnitude
	if m < 1e-6 then
		return false
	end
	local u = l / m
	return math.abs(d:Dot(u)) >= extent(u, ax, ay, az, ah) + extent(u, bx, by, bz, bh) - 1e-4
end

--[[
	Separating-axis test of two oriented boxes (15 axes). Touching faces do not overlap.
	@param a/b CFrame centres + orientation, ah/bh half sizes
]]
function BillboardPlacement.obbOverlap(a: CFrame, ah: Vector3, b: CFrame, bh: Vector3): boolean
	local ax, ay, az = a.RightVector, a.UpVector, a.LookVector
	local bx, by, bz = b.RightVector, b.UpVector, b.LookVector
	local d = b.Position - a.Position
	if
		separates(ax, d, ax, ay, az, ah, bx, by, bz, bh)
		or separates(ay, d, ax, ay, az, ah, bx, by, bz, bh)
		or separates(az, d, ax, ay, az, ah, bx, by, bz, bh)
		or separates(bx, d, ax, ay, az, ah, bx, by, bz, bh)
		or separates(by, d, ax, ay, az, ah, bx, by, bz, bh)
		or separates(bz, d, ax, ay, az, ah, bx, by, bz, bh)
	then
		return false
	end
	for _, u in { ax, ay, az } do
		for _, v in { bx, by, bz } do
			if separates(u:Cross(v), d, ax, ay, az, ah, bx, by, bz, bh) then
				return false
			end
		end
	end
	return true
end

--[[
	Where the segment p0 -> p1 enters the box (slab method in the box's space): the fraction
	t in [0, 1] along the segment, or nil when it misses. A segment starting inside the box does
	not count (an eye inside a big bounding box) and returns nil.
	Example: segmentEntry(CFrame.new(), Vector3.one * 0.5, Vector3.new(-3, 0, 0), Vector3.new(3, 0, 0)) --> 0.4167
]]
function BillboardPlacement.segmentEntry(cf: CFrame, half: Vector3, p0: Vector3, p1: Vector3): number?
	local a = cf:PointToObjectSpace(p0)
	if math.abs(a.X) <= half.X and math.abs(a.Y) <= half.Y and math.abs(a.Z) <= half.Z then
		return nil
	end
	local d = cf:PointToObjectSpace(p1) - a
	local t0, t1 = 0, 1
	-- One slab per box axis: s = start coordinate, dir = segment delta, h = half size.
	for axis = 1, 3 do
		local s = if axis == 1 then a.X elseif axis == 2 then a.Y else a.Z
		local dir = if axis == 1 then d.X elseif axis == 2 then d.Y else d.Z
		local h = if axis == 1 then half.X elseif axis == 2 then half.Y else half.Z
		if math.abs(dir) < 1e-9 then
			if s < -h or s > h then
				return nil
			end
		else
			local u0 = (-h - s) / dir
			local u1 = (h - s) / dir
			if u0 > u1 then
				u0, u1 = u1, u0
			end
			t0 = math.max(t0, u0)
			t1 = math.min(t1, u1)
			if t0 > t1 then
				return nil
			end
		end
	end
	return t0
end

--[[ True when the segment p0 -> p1 passes through the box (see `segmentEntry`). ]]
function BillboardPlacement.segmentHits(cf: CFrame, half: Vector3, p0: Vector3, p1: Vector3): boolean
	return BillboardPlacement.segmentEntry(cf, half, p0, p1) ~= nil
end

-- True when point `p` lies inside the obstacle's box.
local function contains(o: Obstacle, p: Vector3): boolean
	local l = o.cf:PointToObjectSpace(p)
	return math.abs(l.X) <= o.half.X and math.abs(l.Y) <= o.half.Y and math.abs(l.Z) <= o.half.Z
end

-- Cross product of (b - a) x (c - a) in 2D.
local function cross2(ax: number, ay: number, bx: number, by: number, cx: number, cy: number): number
	return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end

--[[
	Convex hull (Andrew's monotone chain) of 2D points given as a flat { x1, y1, x2, y2, ... } list;
	returns the hull the same way, counter-clockwise. A projected box's silhouette is the hull of its
	8 projected corners (tighter than their bounding rectangle for boxes seen at an angle).
]]
local function hull2(flat: { number }): { number }
	local points: { { number } } = {}
	for i = 1, #flat, 2 do
		table.insert(points, { flat[i], flat[i + 1] })
	end
	table.sort(points, function(a: { number }, b: { number }): boolean
		return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
	end)
	local lower: { { number } } = {}
	for _, p in points do
		while
			#lower >= 2
			and cross2(lower[#lower - 1][1], lower[#lower - 1][2], lower[#lower][1], lower[#lower][2], p[1], p[2])
				<= 0
		do
			table.remove(lower)
		end
		table.insert(lower, p)
	end
	local upper: { { number } } = {}
	for i = #points, 1, -1 do
		local p = points[i]
		while
			#upper >= 2
			and cross2(upper[#upper - 1][1], upper[#upper - 1][2], upper[#upper][1], upper[#upper][2], p[1], p[2])
				<= 0
		do
			table.remove(upper)
		end
		table.insert(upper, p)
	end
	local out: { number } = {}
	for i = 1, #lower - 1 do
		table.insert(out, lower[i][1])
		table.insert(out, lower[i][2])
	end
	for i = 1, #upper - 1 do
		table.insert(out, upper[i][1])
		table.insert(out, upper[i][2])
	end
	return out
end

--[[
	True when the axis-aligned rectangle (cx +- hx, cy +- hy) overlaps the convex polygon `hull`
	(flat, counter-clockwise): separating-axis test on the polygon's edge normals (the rectangle's
	own axes are covered by the caller's bounding-rectangle check).
]]
local function rectHitsHull(cx: number, cy: number, hx: number, hy: number, hull: { number }): boolean
	local n = #hull
	if n < 6 then
		return true -- degenerate silhouette: trust the bounding rectangle
	end
	for i = 1, n, 2 do
		local x1, y1 = hull[i], hull[i + 1]
		local j = if i + 2 > n then 1 else i + 2
		local nx, ny = -(hull[j + 1] - y1), hull[j] - x1
		local lo, hi = math.huge, -math.huge
		for k = 1, n, 2 do
			local d = hull[k] * nx + hull[k + 1] * ny
			lo = math.min(lo, d)
			hi = math.max(hi, d)
		end
		local centre = cx * nx + cy * ny
		local reach = hx * math.abs(nx) + hy * math.abs(ny)
		if centre + reach <= lo or centre - reach >= hi then
			return false
		end
	end
	return true
end

-- Builds one viewpoint (eye + basis looking at `target`) and projects every protected box.
local function makeView(eye: Vector3, target: Vector3, protect: { Box }, losOnly: boolean): View
	local look = (target - eye).Unit
	local right = look:Cross(Y)
	right = if right.Magnitude > 1e-6 then right.Unit else Vector3.xAxis
	local up = right:Cross(look)
	local rects: { { number } } = {}
	local hulls: { { number } } = {}
	for i, box in protect do
		local x1: number, y1: number = math.huge, math.huge
		local x2: number, y2: number = -math.huge, -math.huge
		local ok = true
		local flat: { number } = {}
		local h = box.size / 2
		-- Silhouette samples in the box's space: its 8 corners, or 2 x ROUND_SAMPLES points on
		-- the top / bottom ellipses of the inscribed cylinder for round things.
		local samples = if box.round then ROUND_SAMPLES else BOX_SAMPLES
		for _, unit in samples do
			local v = box.cf:PointToWorldSpace(unit * h) - eye
			local z = v:Dot(look)
			if z < 0.3 then
				ok = false
			else
				local x, y = v:Dot(right) / z, v:Dot(up) / z
				table.insert(flat, x)
				table.insert(flat, y)
				x1 = math.min(x1, x)
				y1 = math.min(y1, y)
				x2 = math.max(x2, x)
				y2 = math.max(y2, y)
			end
		end
		rects[i] = if ok then { x1, y1, x2, y2 } else {}
		hulls[i] = if ok then hull2(flat) else {}
	end
	return {
		eye = eye,
		look = look,
		right = right,
		up = up,
		rects = rects,
		hulls = hulls,
		losOnly = losOnly,
		role = "mid",
	}
end

--[[
	On-screen overlap (tangent-plane area, summed over protected boxes) of a board centred at `c`
	seen from `view`, and the board height used there.
]]
local function overlapAt(view: View, c: Vector3, input: Input): (number, number)
	local v = c - view.eye
	local z = v:Dot(view.look)
	local h = BillboardPlacement.heightAt(v.Magnitude, input.size, input.device, input.fov)
	if z < 0.5 then
		return math.huge, h -- behind / inside the camera: unusable from here
	end
	local margin = input.cfg.ScreenMargin
	local hx = (h * input.size.Aspect / 2 + margin) / z
	local hy = (h / 2 + margin) / z
	local x, y = v:Dot(view.right) / z, v:Dot(view.up) / z
	local total = 0
	for i, r in view.rects do
		if #r == 4 then
			local ox = math.min(x + hx, r[3]) - math.max(x - hx, r[1])
			local oy = math.min(y + hy, r[4]) - math.max(y - hy, r[2])
			if ox > 0 and oy > 0 and rectHitsHull(x, y, hx, hy, view.hulls[i]) then
				total += ox * oy
			end
		end
	end
	return total, h
end

--[[
	Readability of a board centred at `c` from one straight-on viewpoint, as angles (direction
	independent: players turn the camera sideways freely; tilting it up is what hides a board,
	owner R32). Returns (readable, elevation of the board top above the horizon in degrees).
		mid  (the far stand): top <= MaxElevation, OUTER edge within MaxBearing of the producer
		near (closer stands): top <= NearElevation, centre within NearBearing of the producer
		side (side-stepped): always readable (coverage only)
]]
local function readableFrom(view: View, c: Vector3, input: Input, origin: Vector3): (boolean, number)
	local cfg = input.cfg
	local v = c - view.eye
	local h = BillboardPlacement.heightAt(v.Magnitude, input.size, input.device, input.fov)
	local flat = math.max(Vector3.new(v.X, 0, v.Z).Magnitude, 0.01)
	local elevation = math.deg(math.atan2(v.Y + h / 2, flat))
	if view.role == "side" then
		return true, elevation
	end
	local toBody = Vector3.new(origin.X - view.eye.X, 0, origin.Z - view.eye.Z)
	local bearing = 0
	if toBody.Magnitude > 1e-3 then
		bearing = math.deg(math.acos(math.clamp(Vector3.new(v.X, 0, v.Z).Unit:Dot(toBody.Unit), -1, 1)))
	end
	if view.role == "mid" then
		local edge = bearing + math.deg(math.atan(h * input.size.Aspect / 2 / flat))
		return elevation <= cfg.MaxElevation and edge <= cfg.MaxBearing, elevation
	end
	return elevation <= cfg.NearElevation and bearing <= cfg.NearBearing, elevation
end

-- Body extents in the viewer frame (R = viewer's right, F = toward the viewer).
local function extents(
	box: Box,
	origin: Vector3,
	R: Vector3,
	F: Vector3
): (number, number, number, number, number, number)
	local rMin: number, rMax: number = math.huge, -math.huge
	local fMin: number, fMax: number = math.huge, -math.huge
	local yMin: number, yMax: number = math.huge, -math.huge
	local h = box.size / 2
	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				local p = box.cf:PointToWorldSpace(Vector3.new(sx * h.X, sy * h.Y, sz * h.Z))
				local o = p - origin
				local r, f = o:Dot(R), o:Dot(F)
				rMin = math.min(rMin, r)
				rMax = math.max(rMax, r)
				fMin = math.min(fMin, f)
				fMax = math.max(fMax, f)
				yMin = math.min(yMin, p.Y)
				yMax = math.max(yMax, p.Y)
			end
		end
	end
	return rMin, rMax, fMin, fMax, yMin, yMax
end

-- True when the segment p0 -> p1 hits an opaque obstacle (bounding-sphere pre-check first).
local function blocked(obstacles: { Obstacle }, p0: Vector3, p1: Vector3): Obstacle?
	local d = p1 - p0
	local lengthSq = d:Dot(d)
	for _, o in obstacles do
		if not o.seeThrough then
			-- Distance from the obstacle's centre to the segment vs its bounding radius.
			local t = if lengthSq > 1e-9 then math.clamp((o.centre - p0):Dot(d) / lengthSq, 0, 1) else 0
			local gap = o.centre - (p0 + d * t)
			if gap:Dot(gap) <= o.radius * o.radius and BillboardPlacement.segmentHits(o.cf, o.half, p0, p1) then
				return o
			end
		end
	end
	return nil
end

--[[
	The sight-line sample points of a board centred at `c` seen from `view`: its centre and its
	four corners pulled 20 % inward (a board half hidden behind a truss or a facade band shows up
	even when its centre peeks through a gap).
]]
local function boardPoints(view: View, c: Vector3, input: Input): { Vector3 }
	local h = BillboardPlacement.heightAt((c - view.eye).Magnitude, input.size, input.device, input.fov)
	local rx = view.right * (h * input.size.Aspect / 2 * 0.8)
	local uy = view.up * (h / 2 * 0.8)
	return { c, c + rx + uy, c - rx + uy, c + rx - uy, c - rx - uy }
end

--[[
	Derives the solve context: the viewer frame, the player viewpoints and the effective
	obstacles. Viewpoints: a player standing Stands studs (x the producer's size / StandScale when
	bigger) in front of its front face (toward the road) and Lateral studs to either side, camera
	CameraBack behind + CameraUp above
	the ground (Roblox's default zoom); plus the far entrance viewpoint (sight lines only).
	Obstacles around a player's head (HeadHeight) at a stand or on the walk in from the entrance
	are dropped: the room / doorway / entry arch the player stands in or walks through is never
	between them and the board. (A camera "popper" pulling eyes in front of
	walls was tried and dropped: piece bounding boxes include door and arch openings, so it
	pulled cameras through open doorways right up to the player's head.)
]]
local function prepare(input: Input): Context
	local cfg = input.cfg
	local F = Vector3.new(input.forward.X, 0, input.forward.Z)
	F = if F.Magnitude > 1e-6 then F.Unit else Vector3.new(0, 0, -1)
	local R = (-F):Cross(Y).Unit
	local origin = input.body.cf.Position
	local rMin, rMax, fMin, fMax, _, top = extents(input.body, origin, R, F)
	local ground = input.ground
	local function headAt(foot: Vector3): Vector3
		return Vector3.new(foot.X, ground + cfg.HeadHeight, foot.Z)
	end
	-- Players step back from big producers (a 30-stud reactor dome is viewed from further away
	-- than a workbench): the stands scale with the producer's width / height past StandScale.
	local scale = math.max(1, math.max(rMax - rMin, top - ground) / cfg.StandScale)
	-- Player feet, stand-major: { foot, stand index, lateral }.
	local feet: { { any } } = {}
	for si, stand in cfg.Stands do
		for _, lateral in cfg.Lateral do
			table.insert(feet, { origin + F * (fMax + stand * scale) + R * lateral, si, lateral })
		end
	end
	-- Head positions the player passes through: every stand, plus the walk in from the entrance
	-- camera to the closest stand (every 2 studs). A box around any of them is a room or a
	-- walk-through frame (garage door, entry arch: their bounding boxes include the opening), so
	-- it is never between the player and the board.
	local heads: { Vector3 } = {}
	for _, entry in feet do
		table.insert(heads, headAt(entry[1]))
	end
	-- (The walk starts at the entrance camera, which trails the player in through the arch.)
	local walkFrom = fMax + cfg.EntranceStand + cfg.CameraBack
	local walkTo = fMax + cfg.Stands[1] * scale
	for f = walkTo, walkFrom, 2 do
		table.insert(heads, headAt(origin + F * f))
	end
	local obstacles: { Obstacle } = {}
	for _, o in input.obstacles do
		local around = false
		for _, head in heads do
			if contains(o, head) then
				around = true
				break
			end
		end
		if not around then
			table.insert(obstacles, o)
		end
	end
	local views: { View } = {}
	local losViews: { View } = {}
	local mid: View? = nil
	local function eyeOf(foot: Vector3): Vector3
		return Vector3.new(foot.X, ground + cfg.CameraUp, foot.Z) + F * cfg.CameraBack
	end
	for _, entry in feet do
		local view = makeView(eyeOf(entry[1]), origin, input.protect, false)
		view.role = if entry[3] ~= 0 then "side" elseif entry[2] == #cfg.Stands then "mid" else "near"
		table.insert(views, view)
		if entry[3] == 0 then
			table.insert(losViews, view)
			if entry[2] == #cfg.Stands then
				mid = view
			end
		end
	end
	table.insert(losViews, makeView(eyeOf(origin + F * (fMax + cfg.EntranceStand)), origin, {}, true))
	return {
		F = F,
		R = R,
		origin = origin,
		rMin = rMin,
		rMax = rMax,
		fMin = fMin,
		fMax = fMax,
		top = top,
		obstacles = obstacles,
		views = views,
		losViews = losViews,
		mid = mid or views[1],
	}
end

-- Sort order: least covering first (unreadable = +1e6), then cheapest.
local function cheaper(a: Candidate, b: Candidate): boolean
	if a.rank ~= b.rank then
		return a.rank < b.rank
	end
	return a.cost < b.cost
end

-- Sight lines from the centre viewpoints to the board's sample points that hit geometry.
local function countRays(ctx: Context, c: Vector3, input: Input, labels: { string }?): number
	local rays = 0
	for vi, view in ctx.losViews do
		for _, point in boardPoints(view, c, input) do
			local hit = blocked(ctx.obstacles, view.eye, point)
			if hit ~= nil then
				rays += 1
				if labels ~= nil then
					table.insert(labels, `los {vi}: {hit.label or "?"}`)
				end
			end
		end
	end
	return rays
end

--[[
	Chooses the board position (see the module header for the rule).
	@param input Input
	@return Result
]]
--[[
	Owner R119 ("silo launch is clipping in the frame"): the first visible-geometry obstacle the
	board at `c` intersects, or nil. A BillboardGui turns to face the camera, so the board is not
	one front-facing panel: it is tested front-facing AND in the camera-facing plane of EVERY
	viewpoint (the view's right / up vectors), each with the largest size any viewpoint shows
	(`slabHalf`). Before R119 only the front-facing panel was tested, so a board just in front of
	the Silo Launch gantry swung back into the frame from the side stands (beams in front of it).
	@param labels optional list: when given, EVERY obstacle hit is appended (diagnostics, `explain`)
	              and the scan does not stop at the first
	@return Obstacle? — the (first) obstacle hit (nil = clear in every orientation)
]]
local function slabHit(ctx: Context, c: Vector3, slabHalf: Vector3, labels: { string }?): Obstacle?
	local first: Obstacle? = nil
	local slabRadius = slabHalf.Magnitude
	local orientations: { CFrame } = { CFrame.lookAt(c, c + ctx.F) }
	for _, view in ctx.views do
		table.insert(orientations, CFrame.fromMatrix(c, view.right, view.up))
	end
	for _, view in ctx.losViews do
		table.insert(orientations, CFrame.fromMatrix(c, view.right, view.up))
	end
	for _, o in ctx.obstacles do
		if (o.centre - c).Magnitude <= o.radius + slabRadius then
			for _, slabCf in orientations do
				if BillboardPlacement.obbOverlap(slabCf, slabHalf, o.cf, o.half) then
					if labels == nil then
						return o
					end
					first = first or o
					table.insert(labels, o.label or "?")
					break
				end
			end
		end
	end
	return first
end

function BillboardPlacement.choose(input: Input): Result
	local cfg = input.cfg
	local ctx = prepare(input)
	local F, R, origin, mid = ctx.F, ctx.R, ctx.origin, ctx.mid
	local rMin, rMax, fMin, fMax, top = ctx.rMin, ctx.rMax, ctx.fMin, ctx.fMax, ctx.top
	local ground = input.ground
	local rMid = (rMin + rMax) / 2
	local fMid = (fMin + fMax) / 2
	-- Every protected box's lateral span + top (viewer frame): "above" spots clear only the boxes
	-- under them, "beside" spots clear all of them.
	local spans: { { number } } = {}
	local uMin: number, uMax: number = rMin, rMax
	for _, box in input.protect do
		local a, b, _, _, _, t = extents(box, origin, R, F)
		table.insert(spans, { a, b, t })
		uMin = math.min(uMin, a)
		uMax = math.max(uMax, b)
	end
	-- The largest board any player viewpoint shows (far boards are floored at MinScreen, so they
	-- can be bigger in studs than near ones): candidates are spaced for it and the slab test
	-- uses it, so no viewpoint ever sees the board dip into geometry.
	local hMax = 0
	for _, view in ctx.views do
		hMax = math.max(
			hMax,
			BillboardPlacement.heightAt((origin - view.eye).Magnitude, input.size, input.device, input.fov)
		)
	end
	local h0 = hMax
	local w0 = h0 * input.size.Aspect

	-- Candidate positions, cheapest families first.
	local candidates: { Candidate } = {}
	local function add(r: number, f: number, y: number, family: string, baseCost: number)
		local c = origin + R * r + F * f
		c = Vector3.new(c.X, y, c.Z)
		local covered = 0
		local unreadable = 0
		local elevation = 0
		for _, view in ctx.views do
			covered += overlapAt(view, c, input)
			local ok, angle = readableFrom(view, c, input, origin)
			if not ok then
				unreadable += 1
			end
			if view == mid then
				elevation = angle
			end
		end
		local toC = Vector3.new(c.X - mid.eye.X, 0, c.Z - mid.eye.Z)
		local toBody = Vector3.new(origin.X - mid.eye.X, 0, origin.Z - mid.eye.Z)
		local bearing = 0
		if toC.Magnitude > 1e-3 and toBody.Magnitude > 1e-3 then
			bearing = math.deg(math.acos(math.clamp(toC.Unit:Dot(toBody.Unit), -1, 1)))
		end
		-- Owner R117 ("orbital launches upgrade ui is too high up"): a board whose centre floats more
		-- than MaxCentre studs above the producer's floor is in the sky from where players stand,
		-- whatever the stand angles say (big producers push the stands back, shrinking the angle).
		if c.Y - ground > cfg.MaxCentre then
			unreadable += 1
		end
		local readable = unreadable == 0
		local trace = input.trace
		if trace ~= nil then
			table.insert(
				trace,
				string.format(
					"%s (%.1f, %.1f, %.1f) covered %.4f elev %.1f bearing %.1f unreadable from %d",
					family,
					c.X,
					c.Y,
					c.Z,
					covered,
					elevation,
					bearing,
					unreadable
				)
			)
		end
		-- Prefer spots near the producer, near the centre of the view and not high up.
		local cost = baseCost
			+ 0.12 * (c - Vector3.new(origin.X, top, origin.Z)).Magnitude
			+ 0.05 * bearing
			+ 0.08 * math.max(0, elevation - 8)
		-- Owner R117: keep some air from other systems' props (AA towers, the Mega Lever / Tip Jar):
		-- a soft cost fading out at PropClear studs.
		for _, o in ctx.obstacles do
			if o.prop then
				local gap = (o.centre - c).Magnitude - o.radius
				if gap < cfg.PropClear then
					cost += cfg.PropPenalty * (1 - math.max(gap, 0) / cfg.PropClear)
				end
			end
		end
		table.insert(candidates, {
			position = c,
			family = family,
			cost = cost,
			covered = covered,
			readable = readable,
			rank = covered + (if readable then 0 else 1e6),
			elevation = elevation,
		})
	end
	-- Above: centred over the producer, then shifted sideways in half-board steps; each spot
	-- starts just over the tallest protected box beneath it and steps up. Owner R117: producers
	-- taller than TallBody (rocket gantry, silos) never get an "above" board: it would float in the
	-- sky; they go beside at eye height.
	local aboveFrontRows = if top - ground > cfg.TallBody then {} else { fMid, fMin + 0.6, fMax }
	for _, f in aboveFrontRows do
		for _, shift in { 0, -0.5, 0.5, -1, 1, -1.5, 1.5 } do
			local rc = rMid + shift * w0
			local lo, hi = rc - w0 / 2 - cfg.Gap, rc + w0 / 2 + cfg.Gap
			local under = -math.huge
			for _, span in spans do
				if span[2] > lo and span[1] < hi then
					under = math.max(under, span[3])
				end
			end
			local y = math.max(under + cfg.Gap + h0 / 2, ground + cfg.MinBottom + h0 / 2)
			while y <= top + cfg.MaxAbove do
				add(rc, f, y, "above", math.abs(shift) * 0.8)
				y += cfg.StepUp
			end
		end
	end
	-- Beside: either side of the producer and of everything protected (the screen test rejects
	-- spots over the manager), at eye height (and higher), at the producer's front face, stepped
	-- toward the players (in front of neighbouring machines / out of a shell), or at mid depth.
	local eyeY = ground + math.max(cfg.EyeHeight, cfg.MinBottom + h0 / 2)
	local edges: { { number } } = { { rMax, 1 }, { rMin, -1 } }
	if uMax > rMax + 0.5 then
		table.insert(edges, { uMax, 1 })
	end
	if uMin < rMin - 0.5 then
		table.insert(edges, { uMin, -1 })
	end
	-- R117 / R119: further sideways (1.5, 2 board widths) and further toward the players (10, 12
	-- studs) so a camera-facing board can always step out of a shell (the A8 storefront glass) or a
	-- gantry frame; lifts that would break MaxCentre are never generated (always unreadable).
	for _, edge in edges do
		local side = edge[2]
		for _, out in { 0, 0.1, 0.25, 0.5, 1, 1.5, 2 } do
			for _, f in
				{
					fMax,
					fMax + 1,
					fMax + 2.5,
					fMax + 3.25,
					fMax + 3.5,
					fMax + 3.75,
					fMax + 4,
					fMax + 4.5,
					fMax + 5,
					fMax + 6,
					fMax + 8,
					fMax + 10,
					fMax + 12,
					fMax - 3,
					fMid,
				}
			do
				for _, lift in { 0, 2, 4, 6, 8, 10 } do
					if eyeY + lift - ground <= cfg.MaxCentre or lift == 0 then
						add(edge[1] + side * (cfg.SideGap + w0 / 2 + out * w0), f, eyeY + lift, "side", 2.0 + out * 1.5)
					end
				end
			end
		end
	end
	table.sort(candidates, cheaper)

	-- Geometry: hard slab test (hMax board), soft sight-line penalty; the cheapest EvaluateMax
	-- slab-clear candidates compete on sight lines.
	local slabHalf = Vector3.new(hMax * input.size.Aspect / 2, hMax / 2, 0.3)
	local best: Candidate? = nil
	local bestScore = math.huge
	local bestRays = 0
	local evaluated = 0
	for _, cand in candidates do
		if evaluated >= cfg.EvaluateMax then
			break
		end
		local c = cand.position
		-- R119: front-facing AND camera-facing from every viewpoint (`slabHit`).
		local hit = slabHit(ctx, c, slabHalf)
		local slabClear = hit == nil
		if hit ~= nil then
			local trace = input.trace
			if trace ~= nil and cand.rank < 1 then
				table.insert(
					trace,
					string.format("  geometry at (%.1f, %.1f, %.1f): %s", c.X, c.Y, c.Z, hit.label or "?")
				)
			end
		end
		if slabClear then
			evaluated += 1
			local rays = countRays(ctx, c, input, nil)
			-- Covering a protected box (or being unreadable) always loses to any clear spot.
			local score = cand.rank * 1e5 + cand.cost + rays * cfg.LosPenalty
			if score < bestScore then
				best, bestScore, bestRays = cand, score, rays
			end
			if rays == 0 and cand.rank == 0 then
				break -- clear, readable, unblocked: the cheapest such spot wins
			end
		end
	end
	local chosen = best or candidates[1]
	local offset = (chosen.position - origin):Dot(R)
	return {
		position = chosen.position,
		side = if offset < -0.5 then -1 else 1,
		right = R,
		family = if chosen.covered > 0 then "fallback" else chosen.family,
		clear = chosen.covered == 0,
		readable = chosen.readable,
		slabClear = best ~= nil,
		blockedRays = if best ~= nil then bestRays else countRays(ctx, chosen.position, input, nil),
		elevation = chosen.elevation,
		height = BillboardPlacement.heightAt(
			(chosen.position - mid.eye).Magnitude,
			input.size,
			input.device,
			input.fov
		),
	}
end

--[[
	Diagnostics for one board position (verification / tests): which viewpoints see it overlap
	which protected box (index) or find it unreadable (`readableFrom`), which obstacles it
	intersects, which obstacles block the sight lines, and every viewpoint's eye.
	Labels come from the boxes' optional `label`.
	Example: BillboardPlacement.explain(input, result.position).rays --> { "los 2: A8_Storefront.Walls" }
]]
function BillboardPlacement.explain(
	input: Input,
	position: Vector3
): {
	overlaps: { string },
	unreadable: { string },
	slab: { string },
	rays: { string },
	eyes: { Vector3 },
}
	local ctx = prepare(input)
	local out = {
		overlaps = {} :: { string },
		unreadable = {} :: { string },
		slab = {} :: { string },
		rays = {} :: { string },
		eyes = {} :: { Vector3 },
	}
	for vi, view in ctx.views do
		table.insert(out.eyes, view.eye)
		if not (readableFrom(view, position, input, ctx.origin)) then
			table.insert(out.unreadable, `view {vi}`)
		end
		for bi = 1, #input.protect do
			local single: View = {
				eye = view.eye,
				look = view.look,
				right = view.right,
				up = view.up,
				rects = { view.rects[bi] },
				hulls = { view.hulls[bi] },
				losOnly = false,
				role = view.role,
			}
			local amount = overlapAt(single, position, input)
			if amount > 0 then
				table.insert(out.overlaps, string.format("view %d box %d (%.4f)", vi, bi, amount))
			end
		end
	end
	-- The same slab as `choose`: the largest board any player viewpoint shows.
	local hMax = 0
	for _, view in ctx.views do
		hMax = math.max(
			hMax,
			BillboardPlacement.heightAt((ctx.origin - view.eye).Magnitude, input.size, input.device, input.fov)
		)
	end
	local slabHalf = Vector3.new(hMax * input.size.Aspect / 2, hMax / 2, 0.3)
	-- R119: every orientation the camera-facing board takes from a viewpoint (`slabHit`).
	slabHit(ctx, position, slabHalf, out.slab)
	countRays(ctx, position, input, out.rays)
	return out
end

return BillboardPlacement
