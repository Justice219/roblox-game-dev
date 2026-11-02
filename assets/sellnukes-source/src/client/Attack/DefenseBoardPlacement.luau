--!strict
--[[
	DefenseBoardPlacement — pure maths that decides WHERE a defence billboard goes so it never clips
	a producer billboard or another defence board (owner R105: "the site launch gui is clipping" —
	the Silo Launch producer board overlapped the HQ "AA TOWER" upgrade board and the "SILO TOWER"
	BUY pad board by the Launch Silos).

	Rule (the producer boards' own rules, Tycoon/BillboardPlacement, applied from the defence side;
	producer boards are never moved — additive):
		1. Base spot: above the BUY pad (PadOffset over its walk-on trigger), a slot tower's side sign
		   (InwardStuds toward the plot's centre line, SideHeight up), the HQ tower's mesh top +
		   TowerGap (MeshAssets pieces, `towerHeight`).
		2. Keep-outs: every producer billboard of the plot within ProducerRadius — its spot is the
		   shipped one (Shared/Config/BillboardSpots, slot-local → WorldLayout.slotOrigin, desktop or
		   device row) and its on-screen size follows BillboardPlacement.heightAt (studs clamped to
		   [MinScreen, MaxScreen] of the viewport) x Billboard.Aspect; for the HQ board also every
		   defence slot's pad AND tower board (both, so the answer never depends on what is bought).
		3. Eyes: where players look from — EyeHeight above the ground, EyeInward studs toward the
		   road and EyeOutward beyond the object, at each EyeAlong offset along the plot.
		4. Screen test: from an eye, every board is a screen-aligned rectangle (BillboardGuis face
		   the camera) — centre and half extents in tangent space (x / depth, y / depth); defence
		   boards are a constant pixel size (tan-per-pixel from the viewport height + FOV). Two
		   boards clip iff their rectangles (+ MarginPixels) intersect while both are in front of
		   the eye and within their MaxDistance (culled boards cannot clip).
		5. Candidates: the base spot moved Lift / Along / Out, cheapest first; the first with zero
		   overlap from every eye wins, else the least overlap (always defined).
	No services, no Instances: lune-testable (tests/attack-view.luau audits every plot, slot, kind,
	HQ level and device). Results are memoised per (plot, tower, kind, level, view).

	Connects to: Shared/Config/{AttackConfig (Towers.Billboard), BillboardSpots, MeshAssets,
	TycoonClientConfig, WorldLayout}, Shared/Attack/{AttackGeometry, DefenseTowers},
	Client/Tycoon/BillboardPlacement (heightAt); used by Client/Attack/DefenseWorld.

	Example:
		local view = DefenseBoardPlacement.view(false, 900, 70)        -- desktop, 900 px, FOV 70
		local spot = DefenseBoardPlacement.solve(3, 3, "pad", 0, view)  -- plot 3, Silo Tower pad
		anchor.CFrame = CFrame.new(spot.position)                      -- spot.clear == true
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local BillboardPlacement = require(script.Parent.Parent.Tycoon.BillboardPlacement)
local BillboardSpots = require(ReplicatedStorage.Shared.Config.BillboardSpots)
local DefenseTowers = require(ReplicatedStorage.Shared.Attack.DefenseTowers)
local MeshAssets = require(ReplicatedStorage.Shared.Config.MeshAssets)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

local DefenseBoardPlacement = {}

local BOARD = AttackConfig.Towers.Billboard
local PLACE = BOARD.Placement
local PRODUCER = TycoonClientConfig.Billboard
-- Tower height fallback (studs) when a level's mesh has no MeshAssets entry (primitive turret).
local FALLBACK_HEIGHT = 7
-- Half height of the BUY pad's walk-on trigger (Server/Attack/AttackWorld PAD_TRIGGER.Y / 2).
local PAD_TRIGGER_HALF = 2

-- "pad" = a slot's BUY pad, "slot" = a built slot tower, "hq" = the Area 7 HQ tower (tower 0).
export type Kind = "pad" | "slot" | "hq"

-- How the local screen sees boards.
export type View = {
	device: boolean, -- phone / tablet / console sizing (producer rows + defence pixels)
	viewportY: number, -- viewport height (px)
	fov: number, -- vertical field of view (degrees)
	pixels: Vector2, -- the defence board's pixel size on this device
}

-- One board to keep clear of: a producer board (studs size law) or a defence board (pixels).
export type Board = {
	centre: Vector3,
	producer: boolean,
	pixels: Vector2?, -- defence boards
	maxDistance: number,
	label: string?,
}

export type Result = {
	position: Vector3, -- board centre (world)
	base: Vector3, -- the unsolved base spot (world)
	clear: boolean, -- no overlap from any eye
	overlap: number, -- summed overlap (tangent units²; 0 when clear)
	cost: number, -- displacement cost of the chosen candidate
}

type Candidate = { lift: number, along: number, out: number, cost: number }

-- Candidates, cheapest first (built once from config).
local candidates: { Candidate } = {}
for _, lift in PLACE.Lifts do
	for _, along in PLACE.Alongs do
		for _, out in PLACE.Outs do
			table.insert(candidates, {
				lift = lift,
				along = along,
				out = out,
				cost = lift * PLACE.LiftCost + math.abs(along) * PLACE.AlongCost + out * PLACE.OutCost,
			})
		end
	end
end
table.sort(candidates, function(a: Candidate, b: Candidate): boolean
	if a.cost ~= b.cost then
		return a.cost < b.cost
	end
	-- Ties: prefer up, then the plot's far direction (deterministic).
	if a.lift ~= b.lift then
		return a.lift > b.lift
	end
	return a.along > b.along
end)

local cache: { [string]: Result } = {}
local cacheSize = 0
-- Memo bound (8 plots x 13 boards x a few views fit easily).
local CACHE_MAX = 512

--[[
	A View for the current screen.
	@param device boolean — phone / tablet / console
	@param viewportY number? — viewport height px (nil / junk = the config fallback for the class)
	@param fov number? — vertical FOV degrees (nil / junk = 70, Roblox's default)
	@return View
]]
function DefenseBoardPlacement.view(device: boolean, viewportY: number?, fov: number?): View
	local fallback = if device then PLACE.PhoneViewport else PLACE.DesktopViewport
	local height = if type(viewportY) == "number"
			and viewportY == viewportY
			and viewportY >= 100
			and viewportY < 1e5
		then viewportY
		else fallback
	local angle = if type(fov) == "number" and fov == fov and fov >= 10 and fov <= 120 then fov else 70
	return {
		device = device,
		viewportY = math.floor(height),
		fov = angle,
		pixels = if device then BOARD.Pixels else BOARD.DesktopPixels,
	}
end

--[[
	Height (studs) of AA tower level `level`'s mesh above its ground centre (MeshAssets pieces;
	FALLBACK_HEIGHT for a level without an uploaded mesh).
	Example: DefenseBoardPlacement.towerHeight(5) --> ~14.6
]]
function DefenseBoardPlacement.towerHeight(level: number): number
	local key = AttackConfig.Models.Towers[level]
	local entry: any = if key ~= nil then (MeshAssets :: any)[key] else nil
	local top = 0
	if type(entry) == "table" and type(entry.pieces) == "table" then
		for _, piece in entry.pieces do
			if type(piece) == "table" and typeof(piece.size) == "Vector3" then
				local offset = if typeof(piece.offset) == "Vector3" then piece.offset else Vector3.zero
				top = math.max(top, offset.Y + piece.size.Y / 2)
			end
		end
	end
	return if top > 0 then top else FALLBACK_HEIGHT
end

--[[
	The unsolved spot of a defence board and the ground point of its object (world).
	@param plot number — 1..PlotCount
	@param tower number — 0 = HQ ("hq"), 1.. = slot ("pad" / "slot")
	@param kind Kind
	@param level number — the HQ tower's level (height); ignored otherwise
	@return (Vector3 board centre, Vector3 object ground point)
]]
function DefenseBoardPlacement.base(plot: number, tower: number, kind: Kind, level: number): (Vector3, Vector3)
	if kind == "hq" then
		local mount = AttackGeometry.towerMount(plot).Position
		return mount + Vector3.new(0, DefenseBoardPlacement.towerHeight(level) + BOARD.TowerGap, 0), mount
	end
	local ground = AttackGeometry.towerSlotCFrame(plot, tower).Position
	if kind == "pad" then
		return ground + Vector3.new(0, PAD_TRIGGER_HALF, 0) + BOARD.PadOffset, ground
	end
	local slot = DefenseTowers.slot(tower)
	local side = if slot ~= nil and slot.at.X > 0 then -1 else 1
	local inward = WorldLayout.plotOrigin(plot).RightVector * side
	return ground + inward * BOARD.InwardStuds + Vector3.new(0, BOARD.SideHeight, 0), ground
end

--[[
	The producer billboards of a plot within `radius` studs of `near` (shipped BillboardSpots rows,
	Nuke Town: defence towers exist on Nuke Town plots only).
	@return { Board }
]]
function DefenseBoardPlacement.producerBoards(plot: number, device: boolean, near: Vector3, radius: number): { Board }
	local boards: { Board } = {}
	for area = 1, WorldLayout.AreaCount do
		local row = (BillboardSpots :: any)[area]
		local spot = if type(row) == "table" then (if device then row.device else row.desktop) else nil
		if type(spot) == "table" and typeof(spot.position) == "Vector3" then
			local centre = (WorldLayout.slotOrigin(plot, area) * CFrame.new(spot.position)).Position
			if (centre - near).Magnitude <= radius then
				table.insert(boards, {
					centre = centre,
					producer = true,
					pixels = nil,
					maxDistance = PRODUCER.MaxDistance,
					label = `producer{area}`,
				})
			end
		end
	end
	return boards
end

-- Tangent units per screen pixel for a view.
local function tanPerPixel(view: View): number
	return 2 * math.tan(math.rad(view.fov) / 2) / view.viewportY
end

-- Screen rectangle of a board seen from `eye` along the basis (f, r): x, y, half x, half y (nil when
-- it is behind the eye or culled by its MaxDistance).
local function project(
	board: Board,
	eye: Vector3,
	f: Vector3,
	r: Vector3,
	view: View
): (number?, number, number, number)
	local d = board.centre - eye
	local depth = d:Dot(f)
	if depth < 1 then
		return nil, 0, 0, 0
	end
	local distance = d.Magnitude
	if distance > board.maxDistance then
		return nil, 0, 0, 0
	end
	local x = d:Dot(r) / depth
	local y = d.Y / depth
	local pixels = board.pixels
	if board.producer or pixels == nil then
		local height = BillboardPlacement.heightAt(distance, PRODUCER, view.device, view.fov)
		return x, y, height * PRODUCER.Aspect / 2 / depth, height / 2 / depth
	end
	local k = tanPerPixel(view) / 2
	return x, y, pixels.X * k, pixels.Y * k
end

--[[
	On-screen overlap (tangent units², 0 = clear) of board `a` and board `b` seen from `eye` (the
	camera looking horizontally toward `a`), with MarginPixels around them.
	@return number
]]
function DefenseBoardPlacement.overlapFrom(eye: Vector3, a: Board, b: Board, view: View): number
	local toA = a.centre - eye
	local flat = Vector3.new(toA.X, 0, toA.Z)
	if flat.Magnitude < 1e-3 then
		return 0
	end
	local f = flat.Unit
	local r = f:Cross(Vector3.yAxis)
	local ax, ay, ahx, ahy = project(a, eye, f, r, view)
	if ax == nil then
		return 0
	end
	local bx, by, bhx, bhy = project(b, eye, f, r, view)
	if bx == nil then
		return 0
	end
	local margin = PLACE.MarginPixels * tanPerPixel(view)
	local ox = ahx + bhx + margin - math.abs(ax - bx)
	local oy = ahy + bhy + margin - math.abs(ay - by)
	if ox <= 0 or oy <= 0 then
		return 0
	end
	return ox * oy
end

--[[
	The eyes (world) a defence object's board is judged from: EyeInward studs toward the plot road
	and EyeOutward beyond it, at each EyeAlong offset, EyeHeight above the plot ground.
	@param plot number
	@param object Vector3 — the object's ground point (world)
	@return { Vector3 }
]]
function DefenseBoardPlacement.eyes(plot: number, object: Vector3): { Vector3 }
	local origin = WorldLayout.plotOrigin(plot)
	local localObject = origin:PointToObjectSpace(object)
	local inward = if localObject.X > 0 then -1 else 1
	local list: { Vector3 } = {}
	for _, along in PLACE.EyeAlong do
		for _, distance in PLACE.EyeInward do
			table.insert(
				list,
				origin * Vector3.new(localObject.X + inward * distance, PLACE.EyeHeight, localObject.Z + along)
			)
		end
		table.insert(
			list,
			origin * Vector3.new(localObject.X - inward * PLACE.EyeOutward, PLACE.EyeHeight, localObject.Z + along)
		)
	end
	return list
end

-- Summed overlap of a board at `centre` against every keep-out from every eye. `firstHit` stops at
-- the first overlap (the clear-candidate search only needs yes / no: most candidates fail fast).
local function overlapTotal(
	centre: Vector3,
	pixels: Vector2,
	maxDistance: number,
	keepouts: { Board },
	eyes: { Vector3 },
	view: View,
	firstHit: boolean?
): number
	local board: Board = { centre = centre, producer = false, pixels = pixels, maxDistance = maxDistance }
	local total = 0
	for _, eye in eyes do
		for _, other in keepouts do
			total += DefenseBoardPlacement.overlapFrom(eye, board, other, view)
			if firstHit and total > 0 then
				return total
			end
		end
	end
	return total
end

-- The culling distance of a board kind.
local function maxDistanceOf(kind: Kind): number
	return if kind == "pad" then BOARD.PadMaxDistance else BOARD.MaxDistance
end

-- The keep-outs of a board: producer boards near it (+ every slot's pad and tower board for the HQ).
local function keepoutsOf(plot: number, kind: Kind, object: Vector3, view: View): { Board }
	local keepouts = DefenseBoardPlacement.producerBoards(plot, view.device, object, PLACE.ProducerRadius)
	if kind == "hq" then
		for tower = 1, DefenseTowers.count() do
			for _, slotKind: Kind in { "pad" :: Kind, "slot" :: Kind } do
				local spot = DefenseBoardPlacement.solve(plot, tower, slotKind, 1, view)
				if (spot.position - object).Magnitude <= PLACE.ProducerRadius then
					table.insert(keepouts, {
						centre = spot.position,
						producer = false,
						pixels = view.pixels,
						maxDistance = maxDistanceOf(slotKind),
						label = `{slotKind}{tower}`,
					})
				end
			end
		end
	end
	return keepouts
end

--[[
	Summed on-screen overlap of a defence board placed at `centre` (tests: the base spot's overlap
	shows the R105 clip; the solved spot's is 0).
	@return number
]]
function DefenseBoardPlacement.score(
	plot: number,
	tower: number,
	kind: Kind,
	level: number,
	view: View,
	centre: Vector3
): number
	local _, object = DefenseBoardPlacement.base(plot, tower, kind, level)
	return overlapTotal(
		centre,
		view.pixels,
		maxDistanceOf(kind),
		keepoutsOf(plot, kind, object, view),
		DefenseBoardPlacement.eyes(plot, object),
		view
	)
end

--[[
	Solves one defence board's spot (memoised per plot / tower / kind / level / view).
	@param plot number — 1..PlotCount
	@param tower number — 0 for "hq", 1..#Towers.Slots for "pad" / "slot"
	@param kind Kind
	@param level number — the HQ tower level (its height); "pad" / "slot" ignore it
	@param view View — DefenseBoardPlacement.view(...)
	@return Result
	Example: DefenseBoardPlacement.solve(1, 0, "hq", 3, view).position
]]
function DefenseBoardPlacement.solve(plot: number, tower: number, kind: Kind, level: number, view: View): Result
	local levelKey = if kind == "hq" then math.clamp(math.floor(level), 1, AttackConfig.MaxLevel) else 0
	local key = `{plot}:{tower}:{kind}:{levelKey}:{view.device}:{view.viewportY}:{view.fov}`
	local cached = cache[key]
	if cached ~= nil then
		return cached
	end
	local base, object = DefenseBoardPlacement.base(plot, tower, kind, if kind == "hq" then levelKey else 1)
	local keepouts = keepoutsOf(plot, kind, object, view)
	local eyes = DefenseBoardPlacement.eyes(plot, object)
	local maxDistance = maxDistanceOf(kind)
	local origin = WorldLayout.plotOrigin(plot)
	local alongAxis = origin:VectorToWorldSpace(Vector3.zAxis)
	local outSign = if origin:PointToObjectSpace(object).X >= 0 then 1 else -1
	local outAxis = origin.RightVector * outSign
	local function at(candidate: Candidate): Vector3
		return base + Vector3.new(0, candidate.lift, 0) + alongAxis * candidate.along + outAxis * candidate.out
	end
	-- Pass 1: the cheapest clear candidate (each test stops at its first overlap).
	local best: Result? = nil
	for _, candidate in candidates do
		local centre = at(candidate)
		if overlapTotal(centre, view.pixels, maxDistance, keepouts, eyes, view, true) <= 0 then
			best = { position = centre, base = base, clear = true, overlap = 0, cost = candidate.cost }
			break
		end
	end
	-- Pass 2 (rare): nothing is clear — the least overlap, displacement breaking ties. The runtime
	-- declutter (DefenseWorld) hides the board from the few views where it would still clip.
	if best == nil then
		local bestScore = math.huge
		for _, candidate in candidates do
			local centre = at(candidate)
			local overlap = overlapTotal(centre, view.pixels, maxDistance, keepouts, eyes, view, false)
			local score = overlap * 1e4 + candidate.cost
			if score < bestScore then
				bestScore = score
				best = { position = centre, base = base, clear = false, overlap = overlap, cost = candidate.cost }
			end
		end
	end
	local result = best :: Result
	-- Bounded memo (a desktop window being resized produces many viewport heights).
	cacheSize += 1
	if cacheSize > CACHE_MAX then
		table.clear(cache)
		cacheSize = 1
	end
	cache[key] = result
	return result
end

--[[ Forgets memoised spots (DefenseWorld calls it on a device / viewport change; cheap). ]]
function DefenseBoardPlacement.reset()
	table.clear(cache)
	cacheSize = 0
end

return DefenseBoardPlacement
