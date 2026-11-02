--!strict
--[[
	Vehicle routes (owner R56: "the delivery truck should drive in and out, semi-truck should drive
	in and out"). Run:
		lune run tests/vehicle-routes

	Proves on the shipped Client/Tycoon/Fx/RouteMath + Shared/Config/VehicleRouteConfig:
	  1. Paths: Catmull-Rom knots are hit exactly, tangents are continuous, arc length is uniform
	     (true studs per second), open ends extrapolate straight, closed loops join seamlessly.
	  2. Profiles: distance(duration) = length, speeds stay within [0, vmax], v0 / v1 respected, and
	     profileTimeAt inverts profileAt.
	  3. Every route: compiles, legs feasible, the clock start sits exactly on the layout rest
	     placement (leader + followers), poses are continuous while visible (segment joins and the
	     loop wrap), the loop is periodic, the rest look has every cargo piece loaded.
	  4. Plot rotation: slot-local poses map to world exactly like WorldLayout.slotToWorld for all
	     8 plots (left + right road sides).
	  5. Clearance: sweeping each vehicle's bounding box along its loop never intersects a collider
	     of its area (3D box-box SAT), never leaves its slot except onto the road, and no two routes of
	     one area share floor space.
	  6. Contracts: piece names (wheels on their axle, lights, cargo, gate) exist in MeshAssets,
	     WorldFxConfig.RoutedModels == VehicleRouteConfig.RoutedModels and routed pieces never get a
	     moving WorldFx row, sound keys are real SFX, belt rockets ride at the WorldFx belt speed,
	     routed placements carry no collision box.
	  7. Worlds + flyers (owner R57, Dino D3 ptero couriers): every route's `world` is registered and
	     its placements come from THAT world's layouts (WorldDef.layoutFolder); slot frames use the
	     world's WorldLayout frames; nothing rises above the slot height budget. A flyer's swept box
	     also clears every visible piece box of its area (pieces its own perch already sits inside,
	     i.e. the nest, excepted), its wings exist and sit on the centre line, its `period` is met, and
	     routes sharing a `sync` clock never touch each other at any moment of the shared loop
	     (per-piece boxes, wings inflated by their flap).
	Set LUNE_VERBOSE=1 for per-route timings.
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")
local loader = Loader.new()
local RouteMath = loader.load("src/client/Tycoon/Fx/RouteMath")
local Config = loader.load("src/shared/Config/VehicleRouteConfig")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local WorldFxConfig = loader.load("src/shared/Config/WorldFxConfig")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local AudioConfig = loader.load("src/shared/Config/AudioConfig")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")

local V = roblox.Vector3.new
local CF = roblox.CFrame
local verbose = process.env.LUNE_VERBOSE == "1"

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end
local function near(a: number, b: number, eps: number, label: string)
	ok(math.abs(a - b) <= eps, `{label}: {a} vs {b}`)
end
local function angleDiff(a: number, b: number): number
	return math.abs((a - b + math.pi) % (2 * math.pi) - math.pi)
end

-- Every world's area layouts (WorldDef.layoutFolder under src/shared/Config), by world + area.
local layoutsByWorld: { [string]: { [number]: any } } = {}
for _, worldId in WorldsConfig.Order do
	local def = WorldsConfig.get(worldId)
	local folder = "src/shared/Config/" .. table.concat(def.layoutFolder, "/")
	local list = {}
	for area = 1, WorldLayout.areaCount(worldId) do
		list[area] = loader.load(string.format("%s/Area%02d", folder, area))
	end
	layoutsByWorld[worldId] = list
end

-- The world a route runs in (nil = Nuke Town).
local function worldOf(route: any): string
	return route.world or "main"
end

--------------------------------------------------------------------------------------------------
-- 1. Paths
--------------------------------------------------------------------------------------------------

do
	local straight = RouteMath.buildPath({ V(0, 0, 0), V(0, 0, 10), V(0, 0, 20) })
	near(straight.length, 20, 1e-3, "straight length")
	for _, s in { 0.5, 7.3, 19.9 } do
		local p, t = RouteMath.pathPoint(straight, s)
		ok((p - V(0, 0, s)).Magnitude < 1e-3, `straight point at {s}`)
		ok((t - V(0, 0, 1)).Magnitude < 1e-3, "straight tangent")
	end
	local before = RouteMath.pathPoint(straight, -3)
	ok((before - V(0, 0, -3)).Magnitude < 1e-3, "open start extrapolates straight back")
	local after = RouteMath.pathPoint(straight, 25)
	ok((after - V(0, 0, 25)).Magnitude < 1e-3, "open end extrapolates straight on")

	-- A curvy path: knots hit, tangent continuous, uniform arc length.
	local knots = { V(0, 0, 0), V(6, 0, 2), V(10, 0, 9), V(9, 0, 17), V(14, 0, 24), V(22, 0, 25) }
	local curvy = RouteMath.buildPath(knots)
	for i, knot in knots do
		local s = RouteMath.nearestS(curvy, knot)
		local p = RouteMath.pathPoint(curvy, s)
		ok((p - knot).Magnitude < 0.02, `curvy knot {i} lies on the path`)
		if i > 1 and i < #knots then
			local _, ta = RouteMath.pathPoint(curvy, s - 0.01)
			local _, tb = RouteMath.pathPoint(curvy, s + 0.01)
			ok(ta:Dot(tb) > math.cos(math.rad(2)), `curvy tangent continuous at knot {i}`)
		end
	end
	local previous = RouteMath.pathPoint(curvy, 0)
	local step = 0.25
	local s = step
	while s <= curvy.length do
		local p = RouteMath.pathPoint(curvy, s)
		local chord = (p - previous).Magnitude
		ok(chord > step * 0.98 and chord <= step * 1.02, `arc length uniform at s = {s} (chord {chord})`)
		previous = p
		s += step
	end

	-- Closed loop: seamless join.
	local ring = {}
	for k = 0, 11 do
		local a = math.rad(k * 30)
		table.insert(ring, V(10 * math.cos(a), 0, 10 * math.sin(a)))
	end
	local loop = RouteMath.buildPath(ring, true)
	near(loop.length, 2 * math.pi * 10, 0.2, "ring length ≈ circumference")
	local p0, t0 = RouteMath.pathPoint(loop, 0)
	local p1, t1 = RouteMath.pathPoint(loop, loop.length - 1e-4)
	ok((p0 - p1).Magnitude < 1e-2 and t0:Dot(t1) > 0.999, "closed loop joins seamlessly")
	local pWrap = RouteMath.pathPoint(loop, loop.length + 3)
	local pThree = RouteMath.pathPoint(loop, 3)
	ok((pWrap - pThree).Magnitude < 1e-3, "closed loop wraps s")
	-- Turn rate on a CCW-from-above circle (+X -> +Z is a right turn for a vehicle facing +X...):
	-- the sign must be constant around the ring.
	local sign = 0
	for _, rate in loop.turn do
		if math.abs(rate) > 1e-3 then
			local here = if rate > 0 then 1 else -1
			ok(sign == 0 or sign == here, "ring turn rate keeps one sign")
			sign = here
		end
	end
	near(math.abs(loop.turn[10]), 1 / 10, 0.01, "ring turn rate = 1 / radius")
	-- Facing +X then turning toward -X side... a vehicle driving +X that curves toward -Z turns
	-- LEFT (yaw grows). Check the sign convention on a quarter arc.
	local left = RouteMath.buildPath({ V(0, 0, 0), V(5, 0, 0), V(9, 0, -2), V(11, 0, -6), V(11, 0, -12) })
	local _, _, mid = RouteMath.pathPoint(left, left.length / 2)
	ok(left.turn[mid] > 0, "curving from +X toward -Z is a left turn (+)")
	ok(left.signal[1] == 1, "the left indicator comes on before the turn")
end

--------------------------------------------------------------------------------------------------
-- 2. Profiles
--------------------------------------------------------------------------------------------------

do
	local cases = {
		{ 40, 0, 0, 12, 4, 6 },
		{ 5, 0, 0, 12, 4, 6 }, -- triangle: never reaches vmax
		{ 133, 14, 0, 14, 4, 5 },
		{ 19, 7, 15, 15, 5, 6 },
		{ 32.4, 3, 3, 3, 4, 6 }, -- constant speed (belt)
	}
	for _, c in cases do
		local p = RouteMath.profile(c[1], c[2], c[3], c[4], c[5], c[6])
		ok(p.feasible, `profile {c[1]} feasible`)
		local d, v = RouteMath.profileAt(p, p.duration)
		near(d, c[1], 1e-3, "profile ends at the leg length")
		near(v, c[3], 1e-3, "profile ends at v1")
		local _, v0 = RouteMath.profileAt(p, 0)
		near(v0, c[2], 1e-3, "profile starts at v0")
		local last = -1
		for k = 0, 50 do
			local tau = p.duration * k / 50
			local dist, speed = RouteMath.profileAt(p, tau)
			ok(dist >= last - 1e-6, "profile distance is monotonic")
			ok(speed >= -1e-6 and speed <= c[4] + 1e-6, "profile speed within [0, vmax]")
			near(RouteMath.profileTimeAt(p, dist), tau, 1e-3, "profileTimeAt inverts profileAt")
			last = dist
		end
	end
	local bad = RouteMath.profile(2, 0, 15, 15, 1, 1)
	ok(not bad.feasible, "an impossible boundary speed is flagged")
end

--------------------------------------------------------------------------------------------------
-- Route helpers
--------------------------------------------------------------------------------------------------

-- Layout placement CFrame for a route Placement (in the route's world).
local function placementOf(area: number, placement: any, world: string?): any
	local layout = layoutsByWorld[world or "main"][area]
	local build = layout.builds[placement.build] or (placement.build == "base" and layout.base)
	ok(build ~= nil, `layout Area{area} has build {placement.build}`)
	local model = build.models[placement.index]
	ok(model ~= nil, `layout Area{area}.{placement.build} has model #{placement.index}`)
	return model
end

local function restsOf(route: any): { any }
	local world = worldOf(route)
	local rests = { placementOf(route.area, route.rest, world).cf }
	for _, follower in route.followers or {} do
		table.insert(rests, placementOf(route.area, follower.placement, world).cf)
	end
	return rests
end

-- Model bounding box (centre, size) from the manifest.
local function bounds(key: string): (any, any)
	local asset = MeshAssets[key]
	ok(asset ~= nil, `MeshAssets has {key}`)
	local lo = V(math.huge, math.huge, math.huge)
	local hi = V(-math.huge, -math.huge, -math.huge)
	for _, piece in asset.pieces do
		lo = lo:Min(piece.offset - piece.size / 2)
		hi = hi:Max(piece.offset + piece.size / 2)
	end
	return (lo + hi) / 2, hi - lo
end

-- Oriented box: centre + 3 unit axes + half extents.
type Box = { c: any, a: { any }, h: { number } }

local function boxFrom(cf: any, size: any): Box
	return {
		c = cf.Position,
		a = { cf.RightVector, cf.UpVector, -cf.LookVector },
		h = { size.X / 2, size.Y / 2, size.Z / 2 },
	}
end

-- 3D separating-axis test between two oriented boxes (true = they intersect).
local function boxesOverlap(A: Box, B: Box): boolean
	local axes = { A.a[1], A.a[2], A.a[3], B.a[1], B.a[2], B.a[3] }
	for i = 1, 3 do
		for j = 1, 3 do
			local cross = A.a[i]:Cross(B.a[j])
			if cross.Magnitude > 1e-4 then
				table.insert(axes, cross.Unit)
			end
		end
	end
	local delta = B.c - A.c
	for _, axis in axes do
		local ra = 0
		local rb = 0
		for k = 1, 3 do
			ra += math.abs(A.a[k]:Dot(axis)) * A.h[k]
			rb += math.abs(B.a[k]:Dot(axis)) * B.h[k]
		end
		if math.abs(delta:Dot(axis)) > ra + rb then
			return false
		end
	end
	return true
end

-- Colliders whose top is at or below this are floors the vehicles drive on (lot slab 0.5).
local FLOOR_TOP = 0.7

-- Every collider of an area (base + all builds), labelled.
local function collidersOf(area: number, world: string?): { { label: string, box: Box } }
	local list = {}
	local layout = layoutsByWorld[world or "main"][area]
	local function add(name: string, group: any)
		for i, collision in group.collision or {} do
			-- Floors (lot slabs, factory floors: top <= FLOOR_TOP) carry the vehicles; skip them.
			local top = collision.cf.Position.Y + collision.size.Y / 2
			if top > FLOOR_TOP then
				table.insert(list, { label = `{name}#{i}`, box = boxFrom(collision.cf, collision.size) })
			end
		end
	end
	if layout.base ~= nil then
		add("base", layout.base)
	end
	for name, group in layout.builds do
		add(name, group)
	end
	return list
end

local compiled: { [string]: any } = {}

--------------------------------------------------------------------------------------------------
-- 3 + 5 + 6. Every route
--------------------------------------------------------------------------------------------------

local TOTAL_SHRINK = 0.15 -- side margin of the swept box (studs)
local BOTTOM_LIFT = 0.35 -- wheels may sink into a curb / lot edge this much
-- Ground routes' floor cells, keyed "<world>:<area>" (flyers are checked in 3D, see 7).
local sweeps: { [string]: { [string]: { [string]: boolean } } } = {}
-- The road in front of a slot ends where the facing slot begins (slot z = -2 * road offset).
local ROAD_FAR_Z = -2 * WorldLayout.SlotRoadOffset

--[[
	Every visible piece box of an area (base + builds) except the models a route drives, labelled
	"<model key>#<placement>.<piece>" — the flyers' clearance set (meshes, not just colliders).
]]
local function pieceBoxesOf(area: number, worldId: string, skipKey: string): { { label: string, box: Box } }
	local list = {}
	local layout = layoutsByWorld[worldId][area]
	local function add(group: any)
		for index, placement in group.models or {} do
			local asset = MeshAssets[placement.key]
			if placement.key ~= skipKey and asset ~= nil then
				for name, piece in asset.pieces do
					if (piece.transparency or 0) < 0.99 then
						table.insert(list, {
							label = `{placement.key}#{index}.{name}`,
							box = boxFrom(placement.cf * CF.new(piece.offset), piece.size),
						})
					end
				end
			end
		end
	end
	if layout.base ~= nil then
		add(layout.base)
	end
	for _, group in layout.builds do
		add(group)
	end
	return list
end

for _, route in Config.Routes do
	local id = route.id
	local area = route.area
	local worldId = worldOf(route)
	ok(WorldsConfig.get(worldId) ~= nil, `{id}: world {worldId} is registered`)
	ok(area >= 1 and area <= WorldLayout.areaCount(worldId), `{id}: area {area} exists in {worldId}`)
	local slotHeight = if area == WorldLayout.areaCount(worldId)
		then WorldLayout.SlotHeightFinale
		else WorldLayout.SlotHeight
	local flyer = route.flyer
	local asset = MeshAssets[route.modelKey]
	ok(asset ~= nil, `{id}: MeshAssets has {route.modelKey}`)
	ok(WorldFxConfig.RoutedModels[route.modelKey] == true, `{id}: WorldFxConfig routes {route.modelKey}`)
	-- No collision box / collide flag on any placement this route drives.
	local function noCollide(placement: any)
		local model = placementOf(area, placement, worldId)
		ok(model.key == route.modelKey, `{id}: placement {placement.build}#{placement.index} is a {route.modelKey}`)
		ok(model.collide ~= true, `{id}: driven placement has no collide flag`)
	end
	noCollide(route.rest)
	for _, follower in route.followers or {} do
		noCollide(follower.placement)
	end
	-- Pieces.
	for _, group in route.cargo or {} do
		for _, name in group do
			ok(asset.pieces[name] ~= nil, `{id}: cargo piece {name}`)
		end
	end
	if route.wheelRadius ~= nil then
		local wheels = 0
		for name, piece in asset.pieces do
			for _, prefix in Config.WheelPrefixes do
				if string.sub(name, 1, #prefix) == prefix then
					wheels += 1
					ok(math.abs(piece.offset.X) < 0.02, `{id}: wheel piece {name} centred on its axle`)
					if prefix ~= "Hubs" then
						near(piece.size.Y / 2, route.wheelRadius, 0.06, `{id}: {name} radius`)
					end
				end
			end
		end
		ok(wheels >= 2, `{id}: has per-axle wheel pieces`)
	end
	if route.lights then
		for _, name in { Config.BrakePiece, Config.IndicatorLeft, Config.IndicatorRight } do
			ok(asset.pieces[name] ~= nil, `{id}: light piece {name}`)
		end
		ok(asset.pieces[Config.IndicatorLeft].offset.X < 0, `{id}: left indicator on the -X side`)
		ok(asset.pieces[Config.IndicatorRight].offset.X > 0, `{id}: right indicator on the +X side`)
	end
	if route.gate ~= nil then
		local gateAsset = MeshAssets[route.gate.modelKey]
		ok(gateAsset ~= nil, `{id}: gate model {route.gate.modelKey}`)
		for _, name in route.gate.pieces do
			ok(gateAsset.pieces[name] ~= nil, `{id}: gate piece {name}`)
		end
	end
	-- Flyers: both wings exist, balanced on the body centre line (they turn about it).
	if flyer ~= nil then
		for _, name in { flyer.wingLeft, flyer.wingRight } do
			local piece = asset.pieces[name]
			ok(piece ~= nil, `{id}: wing piece {name}`)
			ok(math.abs(piece.offset.X) < 0.05, `{id}: wing {name} box centred on the body centre line`)
		end
		ok(flyer.amplitude > 0 and flyer.amplitude <= 40 and flyer.period >= 0.3, `{id}: sane flap`)
		ok(flyer.restAmplitude < flyer.amplitude and flyer.blendSeconds > 0, `{id}: perched wings calmer`)
	end
	-- WorldFx never moves a routed piece.
	for name in asset.pieces do
		local group, row = WorldFxConfig.groupFor(route.modelKey, name)
		ok(group == nil or (row ~= nil and row.motion == "none"), `{id}: WorldFx leaves {name} still`)
	end

	-- Compile.
	local rests = restsOf(route)
	local timeline = RouteMath.compile(route, rests)
	compiled[id] = timeline
	ok(timeline.period >= 5 and timeline.period <= 120, `{id}: period {timeline.period} s within 5..120`)
	ok(timeline.periodOk, `{id}: its legs fit its fixed period`)
	if route.period ~= nil then
		near(timeline.period, route.period, 1e-6, `{id}: loop lasts exactly route.period`)
	end
	local maxSpeed = 0
	for i, seg in timeline.segs do
		if seg.kind == "drive" then
			ok(seg.profile.feasible, `{id}: leg {i} speed profile feasible`)
			maxSpeed = math.max(maxSpeed, seg.profile.vpeak)
		end
	end
	ok(maxSpeed <= 16, `{id}: top speed {maxSpeed} <= 16 studs/s`)
	if verbose then
		print(string.format("%-16s period %5.1f s  top %4.1f studs/s", id, timeline.period, maxSpeed))
	end

	-- Rest poses: the clock start sits on every instance's layout placement, fully loaded.
	local out = RouteMath.newSample()
	for k, rest in rests do
		RouteMath.sample(timeline, timeline.start, k, out)
		local _, restYaw = rest:ToEulerAnglesYXZ()
		ok(
			(out.position - rest.Position).Magnitude < 0.06,
			`{id}: instance {k} starts on its rest spot ({out.position} vs {rest.Position})`
		)
		ok(angleDiff(out.yaw, restYaw) < math.rad(1.5), `{id}: instance {k} starts on its rest yaw`)
		ok(out.alpha > 0.999, `{id}: instance {k} is visible at rest`)
	end
	for group = 1, #(route.cargo or {}) do
		local loaded, u = RouteMath.cargoAt(timeline, group, timeline.start)
		ok(loaded and u >= 1, `{id}: cargo group {group} loaded + settled at rest (the authored look)`)
	end

	-- Periodic + continuous while visible.
	local dt = 0.02
	local a, b = RouteMath.newSample(), RouteMath.newSample()
	for k = 1, #rests do
		RouteMath.sample(timeline, 1.234, k, a)
		RouteMath.sample(timeline, 1.234 + timeline.period, k, b)
		ok((a.position - b.position).Magnitude < 1e-6, `{id}: instance {k} loop is periodic`)
		local t = 0
		RouteMath.sample(timeline, 0, k, a)
		while t < timeline.period + dt do
			t += dt
			RouteMath.sample(timeline, t, k, b)
			if a.alpha > 0.02 and b.alpha > 0.02 then
				local jump = (b.position - a.position).Magnitude
				ok(jump <= maxSpeed * dt * 1.6 + 0.03, `{id}: instance {k} jumps {jump} studs at t = {t}`)
				ok(angleDiff(a.yaw, b.yaw) < math.rad(6), `{id}: instance {k} snaps its heading at t = {t}`)
			end
			a, b = b, a
		end
	end

	-- 4. Plot rotation: every plot maps the slot pose like WorldLayout.slotToWorld.
	RouteMath.sample(timeline, timeline.start + 3.7, 1, out)
	local localFrame = RouteMath.localFrame(out.position, out.yaw)
	for plot = 1, WorldLayout.PlotCount do
		local slot = WorldLayout.slotOrigin(plot, area, worldId)
		local world = slot * localFrame
		local expected = WorldLayout.slotToWorld(plot, area, localFrame, worldId)
		ok(
			WorldLayout.worldAt(world.Position) == worldId or out.position.Z < 0,
			`{id}: plot {plot} pose lies in {worldId}`
		)
		ok((world.Position - expected.Position).Magnitude < 1e-3, `{id}: plot {plot} position`)
		ok(world.LookVector:Dot(expected.LookVector) > 0.9999, `{id}: plot {plot} heading`)
		near(world.Position.Y, out.position.Y, 1e-4, `{id}: plot {plot} keeps the height`)
	end

	-- 5. Clearance sweep.
	local centre, size = bounds(route.modelKey)
	local sweptSize = V(size.X - 2 * TOTAL_SHRINK, size.Y - BOTTOM_LIFT, size.Z - 2 * TOTAL_SHRINK)
	local sweptCentre = centre + V(0, BOTTOM_LIFT / 2, 0)
	local colliders = collidersOf(area, worldId)
	local passThrough: { [string]: boolean } = {}
	for _, label in route.passThrough or {} do
		passThrough[label] = true
	end
	-- Flyers also clear every visible piece box, except pieces their own perch already sits
	-- inside at rest (the nest's bark / twigs / rim wrap the deck: "home" pieces).
	local pieces = if flyer ~= nil then pieceBoxesOf(area, worldId, route.modelKey) else {}
	if flyer ~= nil then
		local kept = {}
		for _, entry in pieces do
			local home = false
			for _, rest in rests do
				if boxesOverlap(boxFrom(rest * CF.new(sweptCentre), sweptSize), entry.box) then
					home = true
				end
			end
			if not home then
				table.insert(kept, entry)
			end
		end
		ok(#kept >= 20, `{id}: clears {#kept} piece boxes of its area`)
		pieces = kept
	end
	local cells: { [string]: boolean } = {}
	local t = 0
	while t < timeline.period do
		for k = 1, #rests do
			RouteMath.sample(timeline, t, k, out)
			if out.alpha > 0.05 then
				local frame = RouteMath.localFrame(out.position, out.yaw) * CF.new(sweptCentre)
				local box = boxFrom(frame, sweptSize)
				for _, collider in colliders do
					if passThrough[collider.label] then
						continue
					end
					ok(
						not boxesOverlap(box, collider.box),
						`{id}: instance {k} hits {collider.label} at t = {string.format("%.2f", t)} (at {out.position})`
					)
				end
				for _, entry in pieces do
					ok(
						not boxesOverlap(box, entry.box),
						`{id}: instance {k} flies into {entry.label} at t = {string.format("%.2f", t)} (at {out.position})`
					)
				end
				-- Stay in the slot, or on the road in front of it (never past it into the facing
				-- slot), and under the slot's height budget.
				for _, sx in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local corner = frame * V(sx * sweptSize.X / 2, 0, sz * sweptSize.Z / 2)
						local onRoad = corner.Z <= -0.5 and corner.Z >= ROAD_FAR_Z
						ok(
							onRoad or (math.abs(corner.X) <= 52 and corner.Z >= -0.5 and corner.Z <= 70),
							`{id}: leaves its slot at t = {t} ({corner})`
						)
					end
				end
				ok(
					frame.Position.Y + sweptSize.Y / 2 <= slotHeight,
					`{id}: above the slot height {slotHeight} at t = {t}`
				)
				if flyer ~= nil then
					continue -- flyers share no floor; sync partners are checked in 3D below
				end
				-- Floor cells (0.5 studs) covered, for the route-vs-route check.
				local reach = math.max(sweptSize.X, sweptSize.Z) / 2 + 0.5
				local p = frame.Position
				for x = math.floor((p.X - reach) * 2), math.ceil((p.X + reach) * 2) do
					for z = math.floor((p.Z - reach) * 2), math.ceil((p.Z + reach) * 2) do
						local q = frame:PointToObjectSpace(V(x / 2, p.Y, z / 2))
						if math.abs(q.X) <= sweptSize.X / 2 and math.abs(q.Z) <= sweptSize.Z / 2 and z >= 0 then
							cells[`{x},{z}`] = true
						end
					end
				end
			end
		end
		t += 0.1
	end
	if flyer == nil then
		local key = `{worldId}:{area}`
		sweeps[key] = sweeps[key] or {}
		sweeps[key][id] = cells
	end
end

-- Routes of one area never share floor space inside the slot (timing-independent).
for area, byRoute in sweeps do
	local ids = {}
	for id in byRoute do
		table.insert(ids, id)
	end
	for i = 1, #ids do
		for j = i + 1, #ids do
			for cell in byRoute[ids[i]] do
				ok(byRoute[ids[j]][cell] == nil, `Area{area}: {ids[i]} and {ids[j]} cross paths at cell {cell}`)
			end
		end
	end
end

--------------------------------------------------------------------------------------------------
-- 7. Shared clocks (route.sync): partners never touch at any moment of the shared loop
--------------------------------------------------------------------------------------------------

-- Per-piece boxes of a route's model at a pose (wings inflated by their flap, everything by the
-- heave; cargo only while it is on board or popping).
local function poseBoxes(route: any, timeline: any, clock: number, out: any): { Box }
	RouteMath.sample(timeline, clock, 1, out)
	local frame = RouteMath.localFrame(out.position, out.yaw)
	local asset = MeshAssets[route.modelKey]
	local flyer = route.flyer
	local heave = if flyer ~= nil then 2 * flyer.heave else 0
	local cargoGroup: { [string]: number } = {}
	for group, names in route.cargo or {} do
		for _, name in names do
			cargoGroup[name] = group
		end
	end
	local boxes = {}
	for name, piece in asset.pieces do
		local group = cargoGroup[name]
		if group ~= nil then
			local loaded, u = RouteMath.cargoAt(timeline, group, clock)
			if not loaded and u >= 1 then
				continue
			end
		end
		local size = piece.size + V(0, heave, 0)
		if flyer ~= nil and (name == flyer.wingLeft or name == flyer.wingRight) then
			size += V(0, 2 * (piece.size.X / 2) * math.sin(math.rad(flyer.amplitude)), 0)
		end
		table.insert(boxes, boxFrom(frame * CF.new(piece.offset), size))
	end
	return boxes
end

do
	local groups: { [string]: { any } } = {}
	for _, route in Config.Routes do
		if route.sync ~= nil then
			local key = `{worldOf(route)}:{route.area}:{route.sync}`
			groups[key] = groups[key] or {}
			table.insert(groups[key], route)
		end
	end
	local pairsChecked = 0
	for key, members in groups do
		ok(#members >= 2, `sync {key}: shares its clock with a partner`)
		local period = compiled[members[1].id].period
		for _, route in members do
			near(compiled[route.id].period, period, 1e-6, `sync {key}: {route.id} has the shared period`)
		end
		for i = 1, #members do
			for j = i + 1, #members do
				local a, b = members[i], members[j]
				local ta, tb = compiled[a.id], compiled[b.id]
				local sa, sb = RouteMath.newSample(), RouteMath.newSample()
				local closest = math.huge
				local master = 0
				while master < period do
					local ca = (master + ta.start) % ta.period
					local cb = (master + tb.start) % tb.period
					local boxesA = poseBoxes(a, ta, ca, sa)
					local boxesB = poseBoxes(b, tb, cb, sb)
					if sa.alpha > 0.05 and sb.alpha > 0.05 then
						closest = math.min(closest, (sa.position - sb.position).Magnitude)
						for _, boxA in boxesA do
							for _, boxB in boxesB do
								ok(
									not boxesOverlap(boxA, boxB),
									`sync {key}: {a.id} touches {b.id} at shared t = {string.format("%.2f", master)}`
								)
							end
						end
					end
					master += 0.05
				end
				pairsChecked += 1
				if verbose then
					print(string.format("sync %s: %s / %s closest %.2f studs", key, a.id, b.id, closest))
				end
			end
		end
	end
	ok(pairsChecked >= 1, "at least one shared-clock pair (Dino D3 couriers) is proven apart")
end

--------------------------------------------------------------------------------------------------
-- 6. Contracts
--------------------------------------------------------------------------------------------------

for key in WorldFxConfig.RoutedModels do
	ok(Config.RoutedModels[key] == true, `WorldFxConfig routes {key} but no VehicleRouteConfig route drives it`)
end
for key in Config.RoutedModels do
	ok(WorldFxConfig.RoutedModels[key] == true, `VehicleRouteConfig drives {key} but WorldFxConfig does not exclude it`)
end
for name, sound in Config.Sounds do
	if type(sound) == "table" then
		local spec = AudioConfig.Sfx[sound.key]
		ok(spec ~= nil and spec.group == "SFX", `sound {name} uses an existing SFX key ({sound.key})`)
	end
end
near(
	Config.byId.A6_BeltRockets.segments[1].speed,
	WorldFxConfig.Pieces.Belt.speed,
	1e-6,
	"belt rockets ride at the belt speed"
)
-- Owner R103: every tier drives vehicles (Low used to park them all, so phones / graphics 1-3 saw
-- machines + managers move but no vehicle); budgets still grow with quality (owner R11).
for _, tierName in { "Low", "Mid", "High" } do
	local budget = Config.Tiers[tierName]
	ok(budget ~= nil and budget.Enabled == true, `{tierName} tier drives vehicles (owner R103)`)
	ok(budget.MaxActive >= 1 and budget.Range > 0, `{tierName} tier moves at least one route in range`)
	ok(budget.HalfRateBeyond > 0 and budget.HalfRateBeyond < budget.Range, `{tierName} full-rate radius inside range`)
end
ok(Config.Tiers.Low.MaxActive <= Config.Tiers.Mid.MaxActive, "Low moves no more routes than Mid")
ok(Config.Tiers.Mid.MaxActive <= Config.Tiers.High.MaxActive, "tier budgets grow with quality")
ok(
	Config.Tiers.Low.Range <= Config.Tiers.Mid.Range and Config.Tiers.Mid.Range <= Config.Tiers.High.Range,
	"ranges grow with quality"
)
ok(Config.Tiers.Low.MaxActive <= 4, "R11: Low stays a small budget on low-end phones")

-- Real vehicle SFX (lead, committed): the honk + the reversing beeper, once per reverse leg.
ok(Config.Sounds.Honk.key == "vehicle_honk" and Config.Sounds.Beep.key == "vehicle_beep", "vehicle honk + beeper SFX")
for _, route in Config.Routes do
	local wanted = 0
	for _, seg in route.segments do
		if seg.beep == true then
			ok(seg.kind == "drive" and seg.reverse == true, `{route.id}: only reverse legs beep`)
			wanted += 1
		end
	end
	local beeps = 0
	for _, event in compiled[route.id].events do
		if event.kind == "beep" then
			beeps += 1
		end
	end
	ok(beeps == wanted, `{route.id}: one beeper run per reverse leg ({beeps} vs {wanted})`)
end

-- Route horns (owner R57, W10b): a `horn` override is a real SFX and only plays through honk waits;
-- the D3 ptero couriers squawk (sparse: one honk wait per lap, rolled at <= 0.5).
for _, route in Config.Routes do
	local horn = route.horn
	if horn ~= nil then
		ok(AudioConfig.Sfx[horn.key] ~= nil, `{route.id}: horn {horn.key} is an AudioConfig.Sfx key`)
		ok(horn.volume > 0 and horn.volume <= 1, `{route.id}: horn volume in (0, 1]`)
		local honks = 0
		for _, event in compiled[route.id].events do
			if event.kind == "honk" then
				honks += 1
			end
		end
		ok(honks >= 1, `{route.id}: a horn route has at least one honk wait`)
	end
	if route.world == "dino" and route.modelKey == "D3_PteroCourier" then
		ok(route.horn ~= nil and route.horn.key == "ptero_squawk_cute", `{route.id}: couriers squawk`)
		ok((route.honkChance or 1) <= 0.5, `{route.id}: squawks stay sparse (honkChance <= 0.5)`)
	end
end

-- Events: honks / beeps / pops fall inside their loop and are sorted.
for id, timeline in compiled do
	local last = -1
	for _, event in timeline.events do
		ok(
			event.t >= last and event.t >= 0 and event.t < timeline.period,
			`{id}: event {event.kind} at {event.t} sorted inside the loop`
		)
		last = event.t
	end
	local hits = {}
	local count = RouteMath.eventsBetween(timeline, timeline.period - 0.5, 0.5, hits)
	ok(count == #hits, `{id}: wrap-aware event window`)
end
-- Gate: the shopper car's barrier is open while the car passes it, shut while it shops.
do
	local timeline = compiled.A8_ShopperCar
	ok(#timeline.gates == 2, "the barrier opens twice per lap (in + out)")
	for _, window in timeline.gates do
		ok(RouteMath.gateAt(timeline, (window.t0 + window.t1) / 2) > 0.99, "barrier fully open mid-pass")
	end
	ok(RouteMath.gateAt(timeline, timeline.start) < 0.01, "barrier shut while the car shops")
end
-- Tip: the mine carts tip only while stopped at the bin.
do
	local timeline = compiled.A4_Carts
	local out = RouteMath.newSample()
	for _, window in timeline.tips do
		local mid = (window.t0 + window.t1) / 2
		RouteMath.sample(timeline, mid, 1, out)
		ok(out.speed == 0 and RouteMath.tipAt(timeline, mid) > 20, "carts tip while parked at the bin")
	end
	ok(RouteMath.tipAt(timeline, timeline.start) == 0, "carts roll upright")
end

-- Dino D3 couriers (owner R57): world-keyed flyers on the nest deck, parcels in and out.
do
	local out = Config.byId.D3_CourierOut
	local inbound = Config.byId.D3_CourierIn
	ok(out ~= nil and inbound ~= nil, "both D3 ptero couriers are routed")
	for _, route in { out, inbound } do
		ok(
			route.world == "dino" and route.area == 3 and route.modelKey == "D3_PteroCourier",
			`{route.id}: Dino D3 courier`
		)
		ok(route.flyer ~= nil and route.sync == "D3_Couriers", `{route.id}: flies on the shared courier clock`)
		local timeline = compiled[route.id]
		local hovers, spins = 0, 0
		for _, seg in timeline.segs do
			if seg.kind == "wait" and seg.hover then
				hovers += 1
			end
			if seg.kind == "wait" and math.abs(seg.spin) > 0 then
				spins += 1
			end
		end
		ok(hovers >= 2 and spins >= 2, `{route.id}: hovers and turns on the spot`)
		-- Mid-flight samples are airborne and flapping.
		local sample = RouteMath.newSample()
		local airborne = false
		for _, seg in timeline.segs do
			if seg.kind == "drive" then
				for f = 0.1, 0.9, 0.1 do
					RouteMath.sample(timeline, seg.t0 + (seg.t1 - seg.t0) * f, 1, sample)
					ok(sample.flying, `{route.id}: wings work in flight`)
					airborne = airborne or (sample.position.Y > 26 and sample.alpha > 0.5)
				end
			end
		end
		-- Courier IN leaves over the PTERO POST arch (top 25.2); courier OUT stays inside the slot.
		ok(airborne or route.id == "D3_CourierOut", `{route.id}: climbs above the arch`)
	end
	-- Rest placements are the two couriers on the D3 nest deck (layout build D3_NestTower #2 / #3).
	ok(out.rest.build == "D3_NestTower" and out.rest.index == 2, "courier OUT rests on the nest deck (#2)")
	ok(inbound.rest.build == "D3_NestTower" and inbound.rest.index == 3, "courier IN rests on the nest deck (#3)")
	-- Courier OUT drops its parcel over the landing pad (D3_LandingPad deck centre (28, 34), r 5).
	local timeline = compiled.D3_CourierOut
	local sample = RouteMath.newSample()
	for _, event in timeline.events do
		if event.kind == "unload" then
			RouteMath.sample(timeline, event.t, 1, sample)
			local pad = placementOf(3, { build = "D3_LandingPad", index = 1 }, "dino").cf.Position
			local flat = V(sample.position.X - pad.X, 0, sample.position.Z - pad.Z).Magnitude
			ok(flat <= 5, `courier OUT drops its parcel over the pad paint ({flat} studs off centre)`)
			ok(sample.speed == 0, "courier OUT hovers while dropping")
		end
	end
end

print(`vehicle-routes: {checks} checks passed`)
