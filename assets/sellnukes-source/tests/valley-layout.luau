--!strict
--[[
	ValleyLayout regression (W9 valley-hub-art, owner R57; contract in
	src/shared/Config/Worlds/Dino/ValleyLayout.luau header). Mirrors tests/hub-layout.luau for Dino
	Valley's Base Camp.

	Loads the REAL src/shared/Config/{Worlds/Dino/ValleyLayout, HubLayout, WorldLayout, MeshAssets,
	Worlds/WorldGeometry, HubAmbientConfig, EggConfig} and the Dino area layouts that exist through
	tests/fixtures/RobloxLoader, and checks:
		1. Shape: every placement key exists in MeshAssets (camp, decor, scenery, plot frame, locked
		   slot, surfaces + their pieces); world names are "<key>_<index>" (what HubBuilder names the
		   instances, so anchors resolve); colliders positive, finite, <= 2048 per axis; plot colours
		   are Nuke Town's; the Time Machine colliders are the SAME list in HubLayout and here.
		2. Anchors: spawn == SpawnPoint == ReturnPortal.arrive; the Return Time Machine (trigger in
		   the swirl, prompt in front, sign on the Sign piece, arrival outside the trigger facing
		   away); no plot teleport pads (owner R134); 2 nest stands matching EggConfig (dino_egg area 2 /
		   volcano_egg area 5); 1 leaderboard with a screen; title sign; ambient presets + cap.
		3. Base Camp geometry: the arrival faces the DINO VALLEY sign; the volcano and the waterfall
		   are visible beside it (outside the sign's angular span); fixtures + decor stand on the
		   meadow / plaza, off the trails, the ring path, the pond and each other; nothing intrudes on
		   the arrival point.
		4. World: wedge scenery off every plot, off the ring path, inside the cliffs; the invisible
		   boundary ring sits at WorldGeometry.boundaryRadius (650); every placement lies within the
		   world's sceneryRadius (950); cliffs + volcano + ground stream Persistent.
		5. Plot frame: the arch at WorldLayout.EntranceZ, its pillar footprint kept clear by every Dino
		   area layout that exists; the hedge just outside the footprint; the backdrop behind the
		   hedge and inside the cliffs; the locked placeholder fits inside a slot.
		6. Budgets (spec §15): Base Camp first view <= 700 MeshParts / 150k triangles / 45 unique
		   meshes; decor; scenery; one plot frame + 6 locked slots.
	Z-fighting of the Valley scenes is audited by tests/zfight-audit.luau ("dino:hub",
	"dino:plot-fresh", "dino:plot-full").

	Run: lune run tests/valley-layout.luau
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local loader = Loader.new()
local ValleyLayout = loader.load("src/shared/Config/Worlds/Dino/ValleyLayout")
local HubLayout = loader.load("src/shared/Config/HubLayout")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local WorldGeometry = loader.load("src/shared/Config/Worlds/WorldGeometry")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end

local function finite(n: number): boolean
	return n == n and n > -math.huge and n < math.huge
end

local function planar(v: any): number
	return math.sqrt(v.X * v.X + v.Z * v.Z)
end

-- Valley geometry (mirrors tools/blender/models/dino_valley.py).
local POND_R = 26 -- basin rim outer edge
local PLAZA_OUT = 88
local RING_IN = 230
local PLOT_R = 260
local TRAIL_HALF = 9
local SCENERY_MAX_R = 630 -- props stay inside the cliffs (inner face r 644+)
local geometry = WorldGeometry.get("dino")
check(geometry ~= nil, "WorldGeometry dino")
local WORLD_ORIGIN_INV = geometry.origin:Inverse()

-- World-local plot origin i (the Valley ring = Nuke Town's ring, relative to the world origin).
local function plotOrigin(index: number): any
	return WORLD_ORIGIN_INV * WorldLayout.plotOrigin(index, "dino")
end

-- Distance of a world-local point from the nearest trail axis (trails run along yaw (i-1)*45, r > 0).
local function trailDistance(p: any): number
	local best = math.huge
	for i = 0, 7 do
		local a = math.rad(i * 45)
		local along = p.X * math.sin(a) + p.Z * math.cos(a)
		if along > 0 then
			best = math.min(best, math.abs(p.X * math.cos(a) - p.Z * math.sin(a)))
		end
	end
	return best
end

-- True when a circle (world-local centre, radius) overlaps plot `index`'s footprint (curved front).
local function onPlot(index: number, p: any, radius: number): boolean
	local lp = plotOrigin(index):PointToObjectSpace(p)
	return math.abs(lp.X) < WorldLayout.PlotHalfWidth + radius
		and lp.Z > -14 - radius
		and lp.Z < geometry.plotLength + radius
end

-- Piece name -> model-space vertices of a MeshAssets model, read from the GLB generate_world.py wrote
-- (export_yup, one node per piece, identity node transforms; same reader as tests/zfight-audit).
local glbCache: { [string]: { [string]: { any } } } = {}
local function glbVertices(key: string): { [string]: { any } }
	local cached = glbCache[key]
	if cached ~= nil then
		return cached
	end
	local serde = require("@lune/serde")
	local data = buffer.fromstring(fs.readFile(`assets/blender/world/{key}.glb`))
	assert(buffer.readu32(data, 0) == 0x46546C67, `{key}.glb: not a glTF binary`)
	local jsonLength = buffer.readu32(data, 12)
	local json = serde.decode("json", buffer.readstring(data, 20, jsonLength))
	local binStart = 20 + jsonLength + 8
	local out: { [string]: { any } } = {}
	for _, node in json.nodes do
		if node.mesh == nil then
			continue
		end
		local t = node.translation or { 0, 0, 0 }
		local list = out[node.name] or {}
		out[node.name] = list
		for _, primitive in json.meshes[node.mesh + 1].primitives do
			local accessor = json.accessors[primitive.attributes.POSITION + 1]
			local view = json.bufferViews[accessor.bufferView + 1]
			local start = binStart + (view.byteOffset or 0) + (accessor.byteOffset or 0)
			local stride = if (view.byteStride or 0) > 0 then view.byteStride else 12
			for i = 0, accessor.count - 1 do
				local at = start + i * stride
				table.insert(
					list,
					Vector3.new(
						buffer.readf32(data, at) + t[1],
						buffer.readf32(data, at + 4) + t[2],
						buffer.readf32(data, at + 8) + t[3]
					)
				)
			end
		end
	end
	glbCache[key] = out
	return out
end

-- Model-space AABB of a MeshAssets model (from its piece boxes).
local function modelBounds(key: string): (any, any)
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, piece in MeshAssets[key].pieces do
		lo = lo:Min(piece.offset - piece.size / 2)
		hi = hi:Max(piece.offset + piece.size / 2)
	end
	return lo, hi
end

--------------------------------------------------------------------------------------------------
-- 1. Shape, keys, names, colliders
--------------------------------------------------------------------------------------------------
local function checkPlacements(label: string, list: { any }, namedByIndex: boolean)
	check(type(list) == "table" and #list > 0, `{label}: placement list`)
	for index, entry in list do
		check(
			type(entry.key) == "string" and MeshAssets[entry.key] ~= nil,
			`{label}[{index}] key {entry.key} in MeshAssets`
		)
		check(typeof(entry.cf) == "CFrame", `{label}[{index}] cf is a CFrame`)
		if namedByIndex then
			check(entry.name == `{entry.key}_{index}`, `{label}[{index}] name {entry.name} == key_index`)
		end
	end
end

local function checkColliders(label: string, list: { any })
	for index, box in list do
		local s = box.size
		check(typeof(s) == "Vector3" and typeof(box.cf) == "CFrame", `{label} collider {index} types`)
		check(s.X > 0 and s.Y > 0 and s.Z > 0, `{label} collider {index} positive`)
		check(s.X <= 2048 and s.Y <= 2048 and s.Z <= 2048, `{label} collider {index} <= 2048`)
		check(finite(box.cf.Position.X) and finite(box.cf.Position.Z), `{label} collider {index} finite`)
	end
end

check(ValleyLayout.worldId == "dino", "worldId")
check(ValleyLayout.ground == false, "ValleyLayout ships its own ground (ground = false)")
check(typeof(ValleyLayout.spawn) == "CFrame", "spawn CFrame")
checkPlacements("models", ValleyLayout.models, true)
checkPlacements("plotFrame", ValleyLayout.plotFrame.models, false)
checkPlacements("lockedSlot", ValleyLayout.lockedSlot.models, false)
checkColliders("world", ValleyLayout.collision)
checkColliders("plotFrame", ValleyLayout.plotFrame.collision)
checkColliders("lockedSlot", ValleyLayout.lockedSlot.collision)

-- Every placement belongs to a known group (HubBuilder / preload / budgets rely on it).
local GROUPS = { camp = true, decor = true, scenery = true }
for _, entry in ValleyLayout.models do
	check(GROUPS[entry.group] == true, `{entry.name} has a known group ({entry.group})`)
end

-- Plot frame names are unique and the owner sign names a real piece.
do
	local seen: { [string]: boolean } = {}
	for _, entry in ValleyLayout.plotFrame.models do
		if entry.name ~= nil then
			check(not seen[entry.name], `plotFrame name {entry.name} unique`)
			seen[entry.name] = true
		end
	end
	for _, name in { "Ground", "Road", "Border", "EntranceArch" } do
		check(seen[name] == true, `plotFrame has {name} (HubLayout's names)`)
	end
	local owner = ValleyLayout.plotFrame.anchors.OwnerSign
	check(seen[owner.model] == true, "OwnerSign model is a plotFrame placement")
	check(MeshAssets.Valley_EntranceArch.pieces[owner.piece] ~= nil, "OwnerSign piece exists")
end

for key, surfaces in ValleyLayout.surfaces do
	check(MeshAssets[key] ~= nil, `surfaces key {key}`)
	for _, surface in surfaces do
		check(MeshAssets[key].pieces[surface.piece] ~= nil, `surfaces {key}.{surface.piece}`)
		check(#surface.faces >= 1 and surface.size.X > 0 and surface.size.Y > 0, `surfaces {key} faces / size`)
	end
end

-- Plot N has the same identity colour in both worlds.
check(#ValleyLayout.plotColors == 8, "8 plot colours")
for i = 1, 8 do
	check(ValleyLayout.plotColors[i] == HubLayout.plotColors[i], `plot colour {i} matches Nuke Town`)
end

-- The Time Machine's colliders are one list in both layouts: the boxes inside the machine's mesh
-- bounds, in the machine's own frame, sorted, must be identical.
local function portalColliders(layout: any, cf: any): { string }
	local lo, hi = modelBounds("Hub_TimeMachine")
	local out: { string } = {}
	for _, box in layout.collision do
		if box.size.X > 400 then
			continue -- ground discs
		end
		local rel = cf:ToObjectSpace(box.cf)
		local p = rel.Position
		if
			p.X >= lo.X - 0.5
			and p.X <= hi.X + 0.5
			and p.Y >= lo.Y - 0.5
			and p.Y <= hi.Y + 0.5
			and p.Z >= lo.Z - 0.5
			and p.Z <= hi.Z + 0.5
		then
			-- Snap to 0.01 and fold -0 into 0 so rotation round-off never reads as a difference.
			local function q(v: number): number
				local r = math.floor(v * 100 + 0.5) / 100
				return if r == 0 then 0 else r
			end
			table.insert(
				out,
				string.format(
					"%.2f,%.2f,%.2f|%.2f,%.2f,%.2f",
					q(p.X),
					q(p.Y),
					q(p.Z),
					box.size.X,
					box.size.Y,
					box.size.Z
				)
			)
		end
	end
	table.sort(out)
	return out
end
do
	local valleyList = portalColliders(ValleyLayout, ValleyLayout.anchors.ReturnPortal.cf)
	local hubList = portalColliders(HubLayout, HubLayout.anchors.WorldPortals.dino.cf)
	check(#valleyList >= 8, `Time Machine colliders present ({#valleyList})`)
	check(#valleyList == #hubList, `Time Machine collider count matches HubLayout ({#valleyList} / {#hubList})`)
	for i = 1, #valleyList do
		check(valleyList[i] == hubList[i], `Time Machine collider {i} matches HubLayout ({valleyList[i]})`)
	end
end

--------------------------------------------------------------------------------------------------
-- 2. Anchors
--------------------------------------------------------------------------------------------------
local byName: { [string]: any } = {}
for _, entry in ValleyLayout.models do
	byName[entry.name] = entry
end
local anchors = ValleyLayout.anchors

local function names(name: string, key: string): any
	local entry = byName[name]
	check(entry ~= nil and entry.key == key, `anchor model {name} is a {key}`)
	return entry
end

check(anchors.SpawnPoint == ValleyLayout.spawn, "anchors.SpawnPoint == spawn")

-- Return Time Machine.
local portal = anchors.ReturnPortal
do
	local entry = names(portal.model, "Hub_TimeMachine")
	check(entry.cf == portal.cf, "ReturnPortal cf matches its model")
	check(not ValleyLayout.isDeferred("Hub_TimeMachine") and entry.group == "camp", "Time Machine is first view")
	local lt = portal.cf:ToObjectSpace(portal.trigger.cf)
	check(math.abs(lt.Position.X) < 1e-3 and math.abs(lt.Position.Z) < 1e-3, "trigger centred in the ring")
	local size = portal.trigger.size
	check(size.X / 2 <= 5.5 and lt.Position.Y - size.Y / 2 >= 1.0, "trigger inside the swirl, above the dais")
	check(lt.Position.Y + size.Y / 2 <= 10 + 8.8, "trigger below the ring's inner top")
	local lp = portal.cf:PointToObjectSpace(portal.prompt.Position)
	check(lp.Z < -10 and lp.Z > -14 and math.abs(lp.X) < 1e-3, "prompt just in front of the step")
	local sign = MeshAssets.Hub_TimeMachine.pieces.Sign
	check(sign ~= nil, "Time Machine has a Sign piece")
	local face = Vector3.new(sign.offset.X, sign.offset.Y, sign.offset.Z - sign.size.Z / 2)
	check(
		(portal.cf:PointToObjectSpace(portal.sign.Position) - face).Magnitude < 0.05,
		"sign anchor on the Sign front face"
	)
	check(portal.sign.LookVector:Dot(portal.cf.LookVector) > 0.999, "sign faces out of the front")
	check(portal.arrive == ValleyLayout.spawn, "arrival = Base Camp spawn")
	check(portal.arrive.LookVector:Dot(portal.cf.LookVector) > 0.999, "arrival faces away from the machine")
	local la = portal.trigger.cf:PointToObjectSpace(portal.arrive.Position)
	check(math.abs(la.Z) - size.Z / 2 >= 6, "arrival >= 6 studs outside the trigger")
	check(math.abs(portal.arrive.Position.Y - portal.cf.Position.Y) < 1e-3, "arrival on the plaza")
end

-- Owner R134: no plot teleport pads (no anchor list, no pad model, no pad digit on the plaza).
check((anchors :: any).PlotTeleportPads == nil, "no Valley plot teleport pads (owner R134)")
for _, entry in ValleyLayout.models do
	check(entry.key ~= "Valley_TeleportPad", `{entry.name}: no teleport pad model (owner R134)`)
	check(string.sub(entry.key, 1, 9) ~= "Hub_Digit", `{entry.name}: no pad digit (owner R134)`)
end

do
	local EggConfig = loader.load("src/shared/Config/EggConfig")
	check(#anchors.EggStands == 2, "2 nest stands")
	for index, stand in anchors.EggStands do
		names(stand.model, "Valley_EggStand")
		local egg = EggConfig.get(stand.eggId)
		check(egg ~= nil and egg.world == "dino", `stand {index} egg {stand.eggId} is a Dino egg`)
		check(egg.area == stand.area, `stand {index} area {stand.area} == EggConfig area {egg.area}`)
		check(
			(stand.egg.Position - (stand.cf * CFrame.new(0, 4, 0)).Position).Magnitude < 1e-3,
			`stand {index} egg on cradle`
		)
		check(
			(stand.prompt.Position - (stand.cf * CFrame.new(0, 3, -6)).Position).Magnitude < 1e-3,
			`stand {index} prompt in front`
		)
		-- Faces the arrival point.
		local toSpawn = (ValleyLayout.spawn.Position - stand.cf.Position) * Vector3.new(1, 0, 1)
		check(stand.cf.LookVector:Dot(toSpawn.Unit) > 0.999, `stand {index} faces the arrival`)
	end
	check(anchors.EggStands[1].eggId == "dino_egg" and anchors.EggStands[2].eggId == "volcano_egg", "stand order")
end

check(#anchors.Leaderboards == 1, "1 Valley leaderboard")
for _, board in anchors.Leaderboards do
	names(board.model, "Valley_Leaderboard")
	check(type(board.stat) == "string" and type(board.title) == "string", "leaderboard stat / title")
	check(board.screen.LookVector:Dot(-board.cf.Position.Unit) > 0.99, "leaderboard faces Base Camp")
	local screen = MeshAssets.Valley_Leaderboard.pieces.Screen
	check(
		math.abs(screen.size.X - board.screenSize.X) < 0.05 and math.abs(screen.size.Y - board.screenSize.Y) < 0.05,
		"screen size"
	)
end
names(anchors.TitleSign.model, "Valley_TitleSign")

do
	local HubAmbientConfig = loader.load("src/shared/Config/HubAmbientConfig")
	check(
		#anchors.AmbientFx > 0 and #anchors.AmbientFx <= HubAmbientConfig.MaxEmitters,
		"ambient emitters within the cap"
	)
	for i, fx in anchors.AmbientFx do
		check(HubAmbientConfig.Presets[fx.preset] ~= nil, `ambient fx {i} preset {fx.preset}`)
		check(typeof(fx.cf) == "CFrame" and planar(fx.cf.Position) < PLAZA_OUT, `ambient fx {i} in Base Camp's centre`)
	end
	-- The spray rises out of the Bronto's mouth toward the pond.
	local spray = anchors.AmbientFx[1]
	check(spray.preset == "Spray" and spray.cf.LookVector.Y > 0.3, "Bronto spray rises")
end

-- Deferred decor: real keys, never something an anchor needs.
do
	check(#ValleyLayout.deferredKeys > 0, "deferred decor keys")
	for _, key in ValleyLayout.deferredKeys do
		check(MeshAssets[key] ~= nil and ValleyLayout.isDeferred(key), `deferred key {key}`)
	end
	for _, key in
		{
			"Valley_Ground",
			"Valley_BaseCamp",
			"Valley_RingPath",
			"Valley_Trail",
			"Valley_BrontoFountain",
			"Hub_TimeMachine",
			"Valley_EggStand",
			"Valley_Leaderboard",
			"Valley_TitleSign",
		}
	do
		check(not ValleyLayout.isDeferred(key), `{key} loads in the first wave`)
	end
	for _, entry in ValleyLayout.models do
		if ValleyLayout.isDeferred(entry.key) then
			check(entry.group ~= "camp", `{entry.name}: deferred decor is never in the camp group`)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- 3. Base Camp geometry
--------------------------------------------------------------------------------------------------
local spawnPos = ValleyLayout.spawn.Position
local look = ValleyLayout.spawn.LookVector

-- Angle (degrees) of a world-local point off the arrival view's axis, signed (+ = right).
local function offAxis(p: any): number
	local d = (p - spawnPos) * Vector3.new(1, 0, 1)
	local a = math.deg(math.atan2(d.X, d.Z) - math.atan2(look.X, look.Z))
	return (a + 540) % 360 - 180
end

do
	local toSign = (anchors.TitleSign.cf.Position - spawnPos).Unit
	check(look:Dot(toSign) > 0.99, "arrival faces the DINO VALLEY sign")
	check(anchors.TitleSign.cf.LookVector:Dot(-toSign) > 0.99, "title sign faces the arrival")
	-- The sign covers +- atan(half width / distance) of the view; the volcano and the waterfall
	-- must stand fully outside that span (they are the arrival view's backdrop, R57 spec §2).
	local _, hi = modelBounds("Valley_TitleSign")
	local signDistance = (anchors.TitleSign.cf.Position - spawnPos).Magnitude
	local signHalf = math.deg(math.atan(hi.X / signDistance))
	for _, key in { "Valley_VolcanoBackdrop", "Valley_Waterfall" } do
		local entry = nil
		for _, e in ValleyLayout.models do
			if e.key == key then
				entry = e
			end
		end
		check(entry ~= nil, `{key} placed`)
		local lo2, hi2 = modelBounds(key)
		local half = math.deg(math.atan(math.max(hi2.X, -lo2.X) / (entry.cf.Position - spawnPos).Magnitude))
		local angle = math.abs(offAxis(entry.cf.Position))
		check(angle - half >= signHalf + 1, `{key} visible beside the title sign ({angle} deg)`)
		check(angle + half <= 51, `{key} inside a 16:9 arrival view ({angle} deg)`)
	end
end

-- Footprint radius (studs) of every Base Camp fixture / decor prop.
local FOOTPRINT: { [string]: number } = {
	Valley_EggStand = 5.6,
	Valley_Leaderboard = 8.6,
	Valley_Palm = 5,
	Valley_Fern = 4,
	Valley_Boulder = 5,
}

local fixtures: { any } = {}
for _, entry in ValleyLayout.models do
	if entry.group ~= "camp" and entry.group ~= "decor" then
		continue
	end
	local radius = FOOTPRINT[entry.key]
	local p = entry.cf.Position
	if radius ~= nil then
		local r = planar(p)
		check(r - radius >= PLAZA_OUT - 1 and r + radius <= RING_IN - 1, `{entry.name} on the meadow`)
		check(trailDistance(p) - radius >= TRAIL_HALF + 1.5, `{entry.name} off the trails`)
		table.insert(fixtures, entry)
	end
	-- Nothing but the floor / fountain / machine near the arrival.
	if radius ~= nil then
		check((p - spawnPos).Magnitude > radius + 6, `{entry.name} clear of the arrival`)
	end
end
for i = 1, #fixtures do
	for j = i + 1, #fixtures do
		local a, b = fixtures[i], fixtures[j]
		local d = (a.cf.Position - b.cf.Position).Magnitude
		check(d >= (FOOTPRINT[a.key] + FOOTPRINT[b.key]) * 0.85, `{a.name} overlaps {b.name} (d = {d})`)
	end
end
-- The title sign is wide and thin: an oriented rectangle (its mesh bounds) instead of a circle. Its
-- corners stand on the meadow off the trails, and every prop keeps its footprint clear of it.
do
	local sign = anchors.TitleSign.cf
	local lo, hi = modelBounds("Valley_TitleSign")
	for _, x in { lo.X, hi.X } do
		for _, z in { lo.Z, hi.Z } do
			local p = (sign * CFrame.new(x, 0, z)).Position
			check(planar(p) >= PLAZA_OUT + 1 and planar(p) <= RING_IN - 1, "title sign corner on the meadow")
			check(trailDistance(p) >= TRAIL_HALF + 1.5, "title sign corner off the trails")
		end
	end
	for _, entry in fixtures do
		local p = sign:PointToObjectSpace(entry.cf.Position)
		local dx = math.max(lo.X - p.X, p.X - hi.X, 0)
		local dz = math.max(lo.Z - p.Z, p.Z - hi.Z, 0)
		check(math.sqrt(dx * dx + dz * dz) >= FOOTPRINT[entry.key] * 0.85, `{entry.name} clear of the title sign`)
	end
end
-- The Time Machine stands on the plaza, clear of the pond and the plaza's outer edge.
do
	local lo, hi = modelBounds("Hub_TimeMachine")
	for _, x in { lo.X, hi.X } do
		for _, z in { lo.Z, hi.Z } do
			local p = (portal.cf * CFrame.new(x, 0, z)).Position
			check(planar(p) >= POND_R + 2 and planar(p) <= PLAZA_OUT - 2, "Time Machine corner on the plaza")
		end
	end
	check(planar(spawnPos) + 2 <= PLAZA_OUT, "arrival on the plaza")
end

--------------------------------------------------------------------------------------------------
-- 4. World: scenery, boundary, scenery radius
--------------------------------------------------------------------------------------------------
local SCENERY_RADIUS: { [string]: number } = {
	Valley_Palm = 7,
	Valley_Fern = 4,
	Valley_Boulder = 5,
	Valley_Hill = 21,
	Valley_FossilDecor = 9,
}
for _, entry in ValleyLayout.models do
	local radius = SCENERY_RADIUS[entry.key]
	if entry.group == "scenery" and radius ~= nil then
		local p = entry.cf.Position
		check(planar(p) + radius <= SCENERY_MAX_R, `{entry.name} inside the cliffs`)
		check(planar(p) - radius >= PLOT_R + 2, `{entry.name} off the ring path`)
		for index = 1, 8 do
			check(not onPlot(index, p, radius + 2), `{entry.name} off plot {index}`)
		end
	end
end
-- Waterfall: against the cliffs, its pool off every plot.
for _, entry in ValleyLayout.models do
	if entry.key == "Valley_Waterfall" then
		local pool = (entry.cf * CFrame.new(0, 0, -6)).Position
		check(planar(pool) + 13 <= geometry.boundaryRadius, "waterfall pool inside the boundary")
		check(planar(entry.cf.Position) >= 620, "waterfall against the cliffs")
		for index = 1, 8 do
			check(not onPlot(index, pool, 15), `waterfall pool off plot {index}`)
		end
	end
end
-- Boundary ring: 32 boxes whose inner faces sit at boundaryRadius.
do
	local ring = 0
	for _, box in ValleyLayout.collision do
		local r = planar(box.cf.Position)
		if box.size.Y == 60 and math.abs(r - (geometry.boundaryRadius + 2)) < 0.01 then
			ring += 1
			check(math.abs(r - box.size.Z / 2 - geometry.boundaryRadius) < 0.01, "boundary box inner face at 650")
		end
	end
	check(ring == 32, `32 boundary boxes at r {geometry.boundaryRadius} ({ring})`)
end
-- Every placement within the world's scenery radius (separation from the other worlds, R57 §3).
for _, entry in ValleyLayout.models do
	local lo, hi = modelBounds(entry.key)
	local reach = 0
	for _, x in { lo.X, hi.X } do
		for _, z in { lo.Z, hi.Z } do
			reach = math.max(reach, planar((entry.cf * CFrame.new(x, 0, z)).Position))
		end
	end
	check(reach <= geometry.sceneryRadius, `{entry.name} within sceneryRadius ({reach})`)
end
for _, key in
	{ "Valley_Ground", "Valley_BoundaryCliffs", "Valley_VolcanoBackdrop", "Valley_BrontoFountain", "Valley_TitleSign" }
do
	for _, entry in ValleyLayout.models do
		if entry.key == key then
			check(entry.persistent == true, `{entry.name} streams Persistent (landmark)`)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- 5. Plot frame: arch, arch corner kept clear by the Dino areas, hedge, backdrop, locked slot
--------------------------------------------------------------------------------------------------
do
	local arch = nil
	for _, entry in ValleyLayout.plotFrame.models do
		if entry.key == "Valley_EntranceArch" then
			arch = entry
		end
	end
	check(arch ~= nil and math.abs(arch.cf.Position.Z - WorldLayout.EntranceZ) < 1e-3, "arch at EntranceZ")
	local archZ = arch.cf.Position.Z
	-- Pillar footprint (plot-local): |x| in [10.5, 15.5], z in archZ +- 2.5, height 0..16.7.
	local function hitsPillar(
		minX: number,
		maxX: number,
		minZ: number,
		maxZ: number,
		minY: number,
		maxY: number
	): boolean
		if maxY <= 1.2 or minY > 16.7 or maxZ < archZ - 2.5 or minZ > archZ + 2.5 then
			return false
		end
		return (maxX > 10.5 and minX < 15.5) or (minX < -10.5 and maxX > -15.5)
	end
	local function boxAabb(cf: any, centre: any, size: any): (number, number, number, number, number, number)
		local minX, maxX, minZ, maxZ, minY, maxY = math.huge, -math.huge, math.huge, -math.huge, math.huge, -math.huge
		for _, sx in { -0.5, 0.5 } do
			for _, sy in { -0.5, 0.5 } do
				for _, sz in { -0.5, 0.5 } do
					local corner = cf * (centre + Vector3.new(size.X * sx, size.Y * sy, size.Z * sz))
					minX, maxX = math.min(minX, corner.X), math.max(maxX, corner.X)
					minZ, maxZ = math.min(minZ, corner.Z), math.max(maxZ, corner.Z)
					minY, maxY = math.min(minY, corner.Y), math.max(maxY, corner.Y)
				end
			end
		end
		return minX, maxX, minZ, maxZ, minY, maxY
	end
	local areas = 0
	for area = 1, WorldLayout.areaCount("dino") do
		local path = string.format("src/shared/Config/Worlds/Dino/Layouts/Area%02d", area)
		if not fs.isFile(path .. ".luau") then
			continue
		end
		areas += 1
		local layout = loader.load(path)
		local slot = WorldLayout.slotLocal(area, "dino")
		local groups: { any } = { layout.base }
		for _, build in layout.builds or {} do
			table.insert(groups, build)
		end
		for _, group in groups do
			for _, model in group.models or {} do
				if MeshAssets[model.key] then
					-- Coarse pass on each piece's box; a piece whose box reaches the pillars (a
					-- slot-wide backdrop such as D1_Jungle) is checked vertex by vertex from its GLB.
					for name, piece in MeshAssets[model.key].pieces do
						local cf = slot * model.cf
						local minX, maxX, minZ, maxZ, minY, maxY = boxAabb(cf, piece.offset, piece.size)
						if hitsPillar(minX, maxX, minZ, maxZ, minY, maxY) then
							local inside = 0
							for _, v in glbVertices(model.key)[name] or {} do
								local p = cf * v
								if hitsPillar(p.X, p.X, p.Z, p.Z, p.Y, p.Y) then
									inside += 1
								end
							end
							check(
								inside == 0,
								`dino area {area} {model.key}.{name} clear of the arch pillars ({inside} vertices inside)`
							)
						end
					end
				end
			end
			for index, box in group.collision or {} do
				local minX, maxX, minZ, maxZ, minY, maxY = boxAabb(slot * box.cf, Vector3.new(0, 0, 0), box.size)
				check(
					not hitsPillar(minX, maxX, minZ, maxZ, minY, maxY),
					`dino area {area} collider {index} clear of the arch pillars`
				)
			end
		end
		for padId, point in layout.pads or {} do
			local p = slot * point
			check(
				not hitsPillar(p.X - 3.45, p.X + 3.45, p.Z - 3.45, p.Z + 3.45, p.Y, p.Y + 1.55),
				`dino area {area} pad {padId} clear of the arch`
			)
		end
	end
	print(`[valley-layout] arch corner checked against {areas} Dino area layout(s)`)
	-- Hedge just outside the footprint; ground covers the whole plot length.
	local hlo, hhi = modelBounds("Valley_FernHedge")
	check(hlo.X <= -WorldLayout.PlotHalfWidth and hhi.X >= WorldLayout.PlotHalfWidth, "hedge spans the plot width")
	check(hhi.Z >= geometry.plotLength and hhi.Z <= geometry.plotLength + 4, "hedge just behind the plot")
	local _, ghi = modelBounds("Valley_PlotGround")
	check(
		math.abs(ghi.Z - geometry.plotLength) < 0.01 and ghi.X <= WorldLayout.PlotHalfWidth + 0.01,
		"plot ground = footprint"
	)
	-- Backdrop props behind the hedge and inside the cliffs.
	for _, entry in ValleyLayout.plotFrame.models do
		if entry.key == "Valley_Palm" or entry.key == "Valley_Fern" then
			check(entry.cf.Position.Z >= hhi.Z + 6, `plot backdrop {entry.key} behind the hedge`)
			for index = 1, 8 do
				local p = (plotOrigin(index) * entry.cf).Position
				check(planar(p) + 7 <= SCENERY_MAX_R, `plot {index} backdrop {entry.key} inside the cliffs`)
			end
		end
	end
	for index, box in ValleyLayout.lockedSlot.collision do
		for _, sx in { -0.5, 0.5 } do
			for _, sz in { -0.5, 0.5 } do
				local corner = box.cf * Vector3.new(box.size.X * sx, 0, box.size.Z * sz)
				check(WorldLayout.inSlot(1, corner, 0.5, "dino"), `locked-slot collider {index} inside the slot`)
			end
		end
	end
	local llo, lhi = modelBounds("Valley_LockedSlot")
	check(
		llo.X >= -WorldLayout.SlotHalfWidth and lhi.X <= WorldLayout.SlotHalfWidth and lhi.Z <= WorldLayout.SlotDepth,
		"locked placeholder inside a slot"
	)
end

--------------------------------------------------------------------------------------------------
-- 6. Budgets (spec §15: mobile / console first)
--------------------------------------------------------------------------------------------------
local function cost(list: { any }, filter: ((any) -> boolean)?): (number, number, number)
	local parts, triangles = 0, 0
	local unique: { [string]: boolean } = {}
	local uniqueCount = 0
	for _, entry in list do
		if filter == nil or filter(entry) then
			local asset = MeshAssets[entry.key]
			for _ in asset.pieces do
				parts += 1
			end
			triangles += asset.triangles
			if not unique[entry.key] then
				unique[entry.key] = true
				uniqueCount += 1
			end
		end
	end
	return parts, triangles, uniqueCount
end

do
	local function inGroup(group: string): (any) -> boolean
		return function(entry: any): boolean
			return entry.group == group
		end
	end
	local BUDGETS = {
		-- Spec §15: the Base Camp first-view pass (everything HubBuilder spawns before decor).
		{ label = "Base Camp first view", parts = 700, triangles = 150000, unique = 45, filter = inGroup("camp") },
		{ label = "Base Camp decor (deferred)", parts = 200, triangles = 40000, unique = 6, filter = inGroup("decor") },
		{ label = "valley scenery", parts = 600, triangles = 120000, unique = 12, filter = inGroup("scenery") },
	}
	for _, budget in BUDGETS do
		local parts, triangles, unique = cost(ValleyLayout.models, budget.filter)
		check(parts <= budget.parts, `{budget.label}: {parts} MeshParts <= {budget.parts}`)
		check(triangles <= budget.triangles, `{budget.label}: {triangles} triangles <= {budget.triangles}`)
		check(unique <= budget.unique, `{budget.label}: {unique} unique meshes <= {budget.unique}`)
		print(`[valley-layout] {budget.label}: {parts} MeshParts, {triangles} triangles, {unique} unique meshes`)
	end
	-- One plot: frame + every slot still locked (a first-visit Dino plot, the worst case).
	local frameParts, frameTriangles = cost(ValleyLayout.plotFrame.models)
	local slotParts, slotTriangles = cost(ValleyLayout.lockedSlot.models)
	local areaCount = WorldLayout.areaCount("dino")
	local plotParts = frameParts + areaCount * slotParts
	local plotTriangles = frameTriangles + areaCount * slotTriangles
	check(plotParts <= 80, `plot frame + {areaCount} locked slots: {plotParts} MeshParts <= 80`)
	check(plotTriangles <= 28000, `plot frame + {areaCount} locked slots: {plotTriangles} triangles <= 28000`)
end

print(`[valley-layout] {checks} checks passed`)
