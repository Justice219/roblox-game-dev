--!strict
--[[
	HubLayout regression (B8e hub art; contract in src/shared/Config/HubLayout.luau header).

	Loads the REAL src/shared/Config/{HubLayout, WorldLayout, MeshAssets} and the committed
	AreaLayouts/Area01-02 through tests/fixtures/RobloxLoader and checks:
		1. Shape: every placement key exists in MeshAssets (world, event, plot frame, locked slot,
		   surfaces + their pieces); world/event names are "<key>_<index>" (what HubBuilder names
		   the instances, so anchors resolve); B11's flat aliases point at the same data; colliders
		   are positive, finite and <= 2048 studs per axis.
		2. Anchors: 10 egg stands (areas 1-10), 8 gates toward plots 1-8 (same order as
		   WorldLayout.plotOrigin; no plot teleport pads since owner R134, see
		   tests/hub-no-teleport-pads.luau), 3 leaderboards with screen faces, wheel / chest / crate /
		   codes / title anchors naming real models of the right key, turkey points, jets, lamps.
		3. Lobby geometry: spawn sits on Hub_SpawnPad and faces the "SELL NUKES" sign; hub fixtures
		   and event decor stand on the grass beds, never on an avenue, the ring road, the spawn pad
		   or the fountain, and never overlap each other; lamps sit on the
		   paving strip beside the avenues; gates straddle the avenue ends inside the plaza.
		4. World: island scenery is off every plot, off the ring road and inside the island; every
		   plotDecor ground slot (with the size of what B11 puts there) is off the plots / road,
		   clear of scenery and of every other plot's slots.
		5. Plot frame: the entrance arch sits at WorldLayout.EntranceZ and its pillar footprint
		   (plot x = +-[10.5, 15.5], z = [1.5, 6.5]) is kept clear by Area01 / Area02 (models' mesh
		   bounds, collision boxes, buy pads; floor slabs topping out <= 1.2 may run underneath); the locked-slot placeholder fits inside a slot.
		6. Budgets (owner R11 — mobile / console first): MeshParts, triangles and unique meshes per
		   group (hub lobby, island scenery, Harvest event, one plot frame + 10 locked slots).
		7. World portals (owner R57 W9, R70 W9b): every non-main world's portalAnchor has a lobby
		   portal (Hub_TimeMachine for Dino Valley, Hub_MoonRocket for Moon Base — any known portal
		   model, read from the anchor's placement); trigger in the swirl / launch ring, prompt in
		   front, sign on the Sign face (+ a "Sign" surface), arrival outside the
		   trigger facing away; first-wave (within MeshLibrary's 200-stud near-hub radius, not
		   deferred); faces the spawn and is not hidden behind the SELL NUKES sign; its footprint
		   stands on the forecourt paving clear of the R55 lobby centre, the grass beds, the avenues,
		   the ring road, the spawn pad, the plot gates, the EventSquare and every
		   fixture / tree / lamp; the portals are the LAST placements (no older "<key>_<index>" name
		   moved) and stand >= 60 studs apart.

	Run: lune run tests/hub-layout.luau
]]

local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local loader = Loader.new()
local HubLayout = loader.load("src/shared/Config/HubLayout")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
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

-- Hub geometry (mirrors tools/blender/models/hub.py).
local PLAZA_R = 230
local ROAD_OUT_R = 260
local BED_IN_R = 92
local BED_OUT_R = 194
local BED_OFFSET = 16
local AVENUE_HALF = 12
local ISLAND_R = 836
-- Lobby centre (owner R55, mirrors tools/blender/models/hub_plaza.py).
local CENTER_EDGE = 87 -- rim outer edge 86.5: everything nearer stands on the dais, not a bed
local SPOKE_EDGE = 9 -- plot path half-width incl. its white edging
local GARDEN_OFFSET = 12.5 -- garden bed edge distance from each spoke axis
local FOUNTAIN_R = 26.6

-- Distance of a world point from the nearest avenue axis (avenues run along yaw (i-1)*45, r > 0).
local function avenueDistance(p: any): number
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

-- True when a circle (world centre, radius) overlaps plot `index`'s footprint (incl. curved front).
local function onPlot(index: number, p: any, radius: number): boolean
	local lp = WorldLayout.plotOrigin(index):PointToObjectSpace(p)
	return math.abs(lp.X) < WorldLayout.PlotHalfWidth + radius
		and lp.Z > -14 - radius
		and lp.Z < WorldLayout.PlotLength + radius
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

check(HubLayout.ground == false, "HubLayout ships its own ground (ground = false)")
check(typeof(HubLayout.spawn) == "CFrame", "spawn CFrame")
checkPlacements("models", HubLayout.models, true)
checkPlacements("event.harvest", HubLayout.event.harvest.models, true)
checkPlacements("plotFrame", HubLayout.plotFrame.models, false)
checkPlacements("lockedSlot", HubLayout.lockedSlot.models, false)
checkColliders("world", HubLayout.collision)
checkColliders("event", HubLayout.event.harvest.collision)
checkColliders("plotFrame", HubLayout.plotFrame.collision)
checkColliders("lockedSlot", HubLayout.lockedSlot.collision)

-- B11's flat aliases are the same data, not copies that could drift.
check(HubLayout.event.models == HubLayout.event.harvest.models, "event.models aliases event.harvest.models")
check(HubLayout.event.collision == HubLayout.event.harvest.collision, "event.collision aliases harvest")
check(typeof(HubLayout.event.square) == "CFrame" and typeof(HubLayout.event.npc) == "CFrame", "event square / npc")
check(#HubLayout.event.turkeySpawns >= 8, "event.turkeySpawns >= 8")
for _, point in HubLayout.event.turkeySpawns do
	check(typeof(point) == "Vector3", "turkey spawn is a Vector3")
end

-- Plot-frame names are unique (PlotBuilder looks them up) and the anchors' model exists.
do
	local names: { [string]: boolean } = {}
	for _, entry in HubLayout.plotFrame.models do
		if entry.name ~= nil then
			check(not names[entry.name], `plotFrame name {entry.name} unique`)
			names[entry.name] = true
		end
	end
	local owner = HubLayout.plotFrame.anchors.OwnerSign
	check(names[owner.model] == true, "OwnerSign model is a plotFrame placement")
	check(MeshAssets.Plot_EntranceArch.pieces[owner.piece] ~= nil, "OwnerSign piece exists")
end

-- SurfaceGui faces name real pieces of real models.
for key, surfaces in HubLayout.surfaces do
	check(MeshAssets[key] ~= nil, `surfaces key {key}`)
	for _, surface in surfaces do
		check(MeshAssets[key].pieces[surface.piece] ~= nil, `surfaces {key}.{surface.piece}`)
		check(#surface.faces >= 1 and surface.size.X > 0 and surface.size.Y > 0, `surfaces {key} faces / size`)
	end
end

--------------------------------------------------------------------------------------------------
-- 2. Anchors
--------------------------------------------------------------------------------------------------
local byName: { [string]: any } = {}
for _, entry in HubLayout.models do
	byName[entry.name] = entry
end
local eventByName: { [string]: any } = {}
for _, entry in HubLayout.event.harvest.models do
	eventByName[entry.name] = entry
end
local anchors = HubLayout.anchors

local function names(name: string, key: string, inEvent: boolean?)
	local entry = if inEvent then eventByName[name] else byName[name]
	check(entry ~= nil and entry.key == key, `anchor model {name} is a {key}`)
	return entry
end

check(anchors.SpawnPoint == HubLayout.spawn, "anchors.SpawnPoint == spawn")
check(#anchors.EggStands == 10, "10 egg stands")
for area, stand in anchors.EggStands do
	check(stand.area == area, `egg stand {area} area`)
	local entry = names(stand.model, "Hub_EggStand")
	check((entry.cf.Position - stand.cf.Position).Magnitude < 1e-3, `egg stand {area} cf matches its model`)
	check(
		(stand.egg.Position - (stand.cf * CFrame.new(0, 4, 0)).Position).Magnitude < 1e-3,
		`egg stand {area} egg on cradle`
	)
end
names(anchors.HarvestEggStand.model, "Hub_EggStand", true)
names(anchors.CrateStall.model, "Hub_CrateStall")
names(anchors.LuckyWheelStage.model, "Hub_LuckyWheelStage")
names(anchors.LuckyWheelStage.wheelModel, "Hub_LuckyWheel")
names(anchors.GroupChest.model, "Hub_GroupChest")
names(anchors.GroupChest.lidModel, "Hub_GroupChestLid")
names(anchors.CodesBoard.model, "Hub_CodesBoard")
names(anchors.TitleSign.model, "Hub_TitleSign")

-- Owner R134: no plot teleport pads (tests/hub-no-teleport-pads.luau checks every world's hub).
check((anchors :: any).PlotTeleportPads == nil, "no plot teleport pads (owner R134)")
check(#anchors.PlotGates == 8, "8 gates")
for i = 1, 8 do
	local toward = WorldLayout.plotOrigin(i).Position.Unit
	local gate = anchors.PlotGates[i]
	check(gate.plot == i, `gate {i} plot index`)
	names(gate.model, "Hub_PlotGate")
	check(gate.cf.Position.Unit:Dot(toward) > 0.999, `gate {i} on avenue {i}`)
	check(planar(gate.cf.Position) + 2 < PLAZA_R, `gate {i} inside the plaza`)
	check(gate.tint == HubLayout.plotColors[i], `gate {i} wears the plot colour`)
end

check(#anchors.Leaderboards == 3 and #HubLayout.leaderboards == 3, "3 leaderboards")
for i, board in anchors.Leaderboards do
	names(board.model, "Hub_Leaderboard")
	check(HubLayout.leaderboards[i].cf == board.screen, `leaderboards[{i}] alias`)
	-- The screen face looks back toward the hub centre (where viewers stand).
	check(board.screen.LookVector:Dot(-board.cf.Position.Unit) > 0.99, `leaderboard {i} faces the hub`)
end
check(#anchors.TurkeySpawnPoints >= 8 and #anchors.FountainJets == 8, "turkey points + fountain jets")
-- Lobby centre (owner R55): every spout jet leaves its nozzle toward the statue, rising; the statue
-- faces the spawn; ambient emitters name real presets, stay in the lobby centre and within the cap.
for i, jet in anchors.FountainJets do
	local look = jet.LookVector
	check(look.Y > 0.3 and look.Y < 0.9, `fountain jet {i} rises`)
	check(
		Vector3.new(look.X, 0, look.Z).Unit:Dot(-Vector3.new(jet.Position.X, 0, jet.Position.Z).Unit) > 0.99,
		`fountain jet {i} sprays at the centre`
	)
	check(math.abs(planar(jet.Position) - 24.2) < 0.5, `fountain jet {i} on the spout ring`)
end
do
	local statue = nil
	for _, entry in HubLayout.models do
		if entry.key == "Hub_NukeyStatue" then
			statue = entry
		end
	end
	check(statue ~= nil, "Nukey statue placed")
	local toSpawn = Vector3.new(HubLayout.spawn.Position.X, 0, HubLayout.spawn.Position.Z).Unit
	check(statue.cf.LookVector:Dot(toSpawn) > 0.999, "Nukey faces the spawn")
	check(statue.persistent == true, "Nukey streams persistently (landmark)")
end
do
	-- Deferred decor (R55 perf): real lobby keys, never something an anchor / system needs at once.
	check(#HubLayout.deferredKeys > 0, "deferred decor keys")
	local used: { [string]: boolean } = {}
	for _, entry in HubLayout.models do
		used[entry.key] = true
	end
	for _, key in HubLayout.deferredKeys do
		check(used[key] == true and MeshAssets[key] ~= nil, `deferred key {key} is a placed hub model`)
		check(HubLayout.isDeferred(key), `isDeferred({key})`)
	end
	local essential = {
		"Hub_CenterPlaza",
		"Hub_PlazaSpoke",
		"Hub_Monument",
		"Hub_NukeyStatue",
		"Hub_SpawnPad",
		"Hub_TitleSign",
		"Hub_PlotGate",
		"Hub_Avenue",
		"Hub_DistrictWedge",
		"Hub_RingRoadArc",
	}
	for _, key in essential do
		check(not HubLayout.isDeferred(key), `{key} loads in the first wave`)
	end
	local function notDeferred(name: string, inEvent: boolean?)
		local entry = if inEvent then eventByName[name] else byName[name]
		check(entry ~= nil and not HubLayout.isDeferred(entry.key), `anchor model {name} loads in the first wave`)
	end
	for _, stand in anchors.EggStands do
		notDeferred(stand.model)
	end
	for _, name in
		{
			anchors.CrateStall.model,
			anchors.LuckyWheelStage.model,
			anchors.LuckyWheelStage.wheelModel,
			anchors.GroupChest.model,
			anchors.GroupChest.lidModel,
			anchors.CodesBoard.model,
			anchors.TitleSign.model,
		}
	do
		notDeferred(name)
	end
	for _, board in anchors.Leaderboards do
		notDeferred(board.model)
	end
end
do
	local HubAmbientConfig = loader.load("src/shared/Config/HubAmbientConfig")
	check(
		#anchors.AmbientFx > 0 and #anchors.AmbientFx <= HubAmbientConfig.MaxEmitters,
		"ambient emitters within the cap"
	)
	for i, fx in anchors.AmbientFx do
		check(HubAmbientConfig.Presets[fx.preset] ~= nil, `ambient fx {i} preset {fx.preset}`)
		check(typeof(fx.cf) == "CFrame" and planar(fx.cf.Position) < CENTER_EDGE, `ambient fx {i} in the lobby centre`)
	end
	for name, preset in HubAmbientConfig.Presets do
		check(preset.lightEmission <= 0.5 and preset.rate <= 12, `{name}: soft + cheap (R19 / R11)`)
	end
end
check(typeof(anchors.EventSquare.cf) == "CFrame" and typeof(anchors.EventSquare.size) == "Vector3", "EventSquare")
do
	local lamps = 0
	for _, entry in HubLayout.models do
		if entry.key == "Hub_Lamp" then
			lamps += 1
		end
	end
	check(#anchors.LampLights == lamps, "one LampLights anchor per lamp")
end

--------------------------------------------------------------------------------------------------
-- 3. Lobby geometry
--------------------------------------------------------------------------------------------------
-- Footprint radius (studs) of every hub / event model that stands on a grass bed.
local FOOTPRINT: { [string]: number } = {
	Hub_EggStand = 5,
	Hub_CrateStall = 8,
	Hub_GroupChest = 6,
	Hub_LuckyWheelStage = 10,
	Hub_Leaderboard = 8,
	Hub_CodesBoard = 7.5,
	Hub_Bench = 3.2,
	Hub_Tree = 5,
	Hub_Planter = 3,
	Scenery_Flowers = 3,
	Harvest_Arch = 3, -- walkway centre (pillars are at +-9, checked by the overlap test as a pair)
	Harvest_Cornucopia = 7,
	Harvest_TurkeyStatue = 4.5,
	Harvest_PieStand = 8,
	Harvest_HayBale = 2.6,
	Harvest_Pumpkin = 1.8,
	Harvest_AutumnTree = 5,
}

do
	-- Spawn: on its pad, facing the SELL NUKES sign.
	local spawnPad = nil
	for _, entry in HubLayout.models do
		if entry.key == "Hub_SpawnPad" then
			spawnPad = entry
		end
	end
	check(
		spawnPad ~= nil and (spawnPad.cf.Position - HubLayout.spawn.Position).Magnitude < 1e-3,
		"spawn on Hub_SpawnPad"
	)
	local toSign = (anchors.TitleSign.cf.Position - HubLayout.spawn.Position).Unit
	check(HubLayout.spawn.LookVector:Dot(toSign) > 0.95, "spawn faces the SELL NUKES sign")
end

local spawnPos = HubLayout.spawn.Position
local function bedCheck(label: string, entry: any)
	local radius = FOOTPRINT[entry.key]
	local p = entry.cf.Position
	local r = planar(p)
	if radius == nil or r < CENTER_EDGE then
		return -- lobby-centre furniture stands on the dais, not a bed (R55; event pumpkins / spawn hay too)
	end
	check(r - radius >= BED_IN_R - 2 and r + radius <= BED_OUT_R + 2, `{label} {entry.name} on its bed radially`)
	check(avenueDistance(p) - radius >= BED_OFFSET - 1.6, `{label} {entry.name} clear of the avenues`)
end

local fixtures: { any } = {}
for _, entry in HubLayout.models do
	if entry.group == "hub" then
		bedCheck("hub", entry)
		if FOOTPRINT[entry.key] then
			table.insert(fixtures, entry)
		end
		-- Nothing but the gate digits / spawn / plaza floor intrudes on the spawn pad.
		local p = entry.cf.Position
		if string.sub(entry.key, 1, 9) ~= "Hub_Digit" and entry.key ~= "Hub_SpawnPad" then
			if planar(p) > 1 then
				check((p - spawnPos).Magnitude > 9.5 + 2, `{entry.name} clear of the spawn pad`)
			end
		end
	end
end
for _, entry in HubLayout.event.harvest.models do
	bedCheck("event", entry)
	local p = entry.cf.Position
	check((p - spawnPos).Magnitude > 9.5 + 1, `event {entry.name} clear of the spawn pad`)
	check(planar(p) > 26.6 + 1, `event {entry.name} clear of the fountain`)
	if FOOTPRINT[entry.key] and entry.key ~= "Harvest_StringLights" then
		table.insert(fixtures, entry)
	end
end
-- Pairwise overlap (circle approximation; same height band so stacked bales are allowed).
for i = 1, #fixtures do
	for j = i + 1, #fixtures do
		local a, b = fixtures[i], fixtures[j]
		local d = (a.cf.Position - b.cf.Position).Magnitude
		if math.abs(a.cf.Position.Y - b.cf.Position.Y) < 2 then
			check(d >= (FOOTPRINT[a.key] + FOOTPRINT[b.key]) * 0.85, `{a.name} overlaps {b.name} (d = {d})`)
		end
	end
end
for _, entry in HubLayout.models do
	local p = entry.cf.Position
	if entry.key == "Hub_Lamp" then
		local d = avenueDistance(p)
		check(d >= AVENUE_HALF + 0.85 and d <= BED_OFFSET - 1.6 - 0.85, `{entry.name} on the paving strip`)
	elseif
		(entry.key == "Hub_Bench" or entry.key == "Hub_BannerPole" or entry.key == "Hub_Coin")
		and planar(p) < CENTER_EDGE
	then
		-- Lobby furniture keeps the plot paths clear and stays out of the fountain.
		check(avenueDistance(p) >= SPOKE_EDGE + 0.8, `{entry.name} off the plot paths`)
		check(planar(p) > FOUNTAIN_R + 2, `{entry.name} clear of the fountain`)
	elseif entry.key == "Hub_Bunting" then
		-- Spoke-mouth gateway: its lamp posts (x = +-10.6) stand on the walkway between the plot
		-- path edging (9) and the garden beds (12.5).
		for _, x in { -10.6, 10.6 } do
			local d = avenueDistance((entry.cf * CFrame.new(x, 0, 0)).Position)
			check(d >= SPOKE_EDGE + 0.8 and d <= GARDEN_OFFSET - 0.8, `{entry.name} lamp post on the walkway`)
		end
	elseif entry.key == "Hub_TitleSign" then
		for _, x in { -20.2, 20.2 } do
			local post = (entry.cf * CFrame.new(x, 0, 0)).Position
			check(avenueDistance(post) - 1.7 >= AVENUE_HALF, "title sign posts off the avenues")
		end
	end
end

--------------------------------------------------------------------------------------------------
-- 4. World scenery + plot decor slots
--------------------------------------------------------------------------------------------------
local SCENERY_RADIUS: { [string]: number } = {
	Hub_Tree = 5,
	Scenery_TreePine = 5,
	Scenery_Pond = 23,
	Scenery_Hill = 21,
	Scenery_HillSmall = 12,
	Scenery_Cloud = 8,
	Scenery_CloudBig = 15,
	Scenery_Rock = 4,
	Scenery_Flowers = 3,
}
local sceneryProps: { any } = {}
for _, entry in HubLayout.models do
	local radius = SCENERY_RADIUS[entry.key]
	if entry.group == "scenery" and radius then
		table.insert(sceneryProps, entry)
		local p = entry.cf.Position
		check(planar(p) + radius <= ISLAND_R - 8, `{entry.name} inside the island`)
		check(planar(p) - radius >= ROAD_OUT_R + 2, `{entry.name} off the ring road`)
		for index = 1, WorldLayout.PlotCount do
			check(not onPlot(index, p, radius + 2), `{entry.name} off plot {index}`)
		end
	end
end

-- What B11 puts on each ground slot (footprint radius incl. the model's reach).
local DECOR_RADIUS: { [string]: number } = {
	GroundL1 = 3, -- hay bale
	GroundL2 = 3.5, -- scarecrow
	GroundL3 = 4.6, -- turkey statue pedestal
	GroundR1 = 4, -- pumpkin pile
	GroundR2 = 5.5, -- small cornucopia (~10 long)
}
do
	check(typeof(HubLayout.plotDecor.Arch) == "CFrame", "plotDecor.Arch (garland)")
	local slots: { { name: string, pos: any, radius: number, plot: number } } = {}
	for name, radius in DECOR_RADIUS do
		local cf = HubLayout.plotDecor[name]
		check(typeof(cf) == "CFrame", `plotDecor.{name}`)
		for index = 1, WorldLayout.PlotCount do
			table.insert(
				slots,
				{ name = name, pos = (WorldLayout.plotOrigin(index) * cf).Position, radius = radius, plot = index }
			)
		end
	end
	for _, slot in slots do
		local label = `plotDecor.{slot.name} of plot {slot.plot}`
		check(planar(slot.pos) - slot.radius >= ROAD_OUT_R + 2, `{label} off the ring road`)
		check(planar(slot.pos) + slot.radius <= ISLAND_R - 8, `{label} inside the island`)
		for index = 1, WorldLayout.PlotCount do
			check(not onPlot(index, slot.pos, slot.radius), `{label} off plot {index}`)
		end
		for _, prop in sceneryProps do
			local d = (prop.cf.Position - slot.pos).Magnitude
			check(d >= SCENERY_RADIUS[prop.key] + slot.radius + 1, `{label} clear of {prop.name}`)
		end
		for _, other in slots do
			if other ~= slot then
				local d = (other.pos - slot.pos).Magnitude
				check(d >= slot.radius + other.radius + 1, `{label} clear of {other.name} of plot {other.plot}`)
			end
		end
	end
end

--------------------------------------------------------------------------------------------------
-- 5. Plot frame: arch position, arch corner kept clear by areas 1-2, locked slot fits a slot
--------------------------------------------------------------------------------------------------
do
	local arch = nil
	for _, entry in HubLayout.plotFrame.models do
		if entry.key == "Plot_EntranceArch" then
			arch = entry
		end
	end
	check(arch ~= nil and math.abs(arch.cf.Position.Z - WorldLayout.EntranceZ) < 1e-3, "arch at EntranceZ")
	local archZ = arch.cf.Position.Z
	-- Pillar footprint (plot-local): |x| in [10.5, 15.5], z in archZ +- 2.5, height 0..20.8.
	local function hitsPillar(
		minX: number,
		maxX: number,
		minZ: number,
		maxZ: number,
		minY: number,
		maxY: number
	): boolean
		-- Floor slabs (top <= 1.2) may run under the pillars; anything taller must stay clear.
		if maxY <= 1.2 or minY > 20.8 or maxZ < archZ - 2.5 or minZ > archZ + 2.5 then
			return false
		end
		return (maxX > 10.5 and minX < 15.5) or (minX < -10.5 and maxX > -15.5)
	end
	-- Plot-local AABB of a model-space box (centre offset + size) placed at `cf` (plot-local).
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
	local function modelAabb(key: string, cf: any): (number, number, number, number, number, number)
		local lo = Vector3.new(math.huge, math.huge, math.huge)
		local hi = Vector3.new(-math.huge, -math.huge, -math.huge)
		for _, piece in MeshAssets[key].pieces do
			lo = lo:Min(piece.offset - piece.size / 2)
			hi = hi:Max(piece.offset + piece.size / 2)
		end
		return boxAabb(cf, (lo + hi) / 2, hi - lo)
	end
	for _, area in { 1, 2 } do
		local layout = loader.load(string.format("src/shared/Config/AreaLayouts/Area%02d", area))
		local slot = WorldLayout.slotLocal(area)
		local groups: { any } = { layout.base }
		for _, build in layout.builds or {} do
			table.insert(groups, build)
		end
		for _, group in groups do
			for _, model in group.models or {} do
				if MeshAssets[model.key] then
					local minX, maxX, minZ, maxZ, minY, maxY = modelAabb(model.key, slot * model.cf)
					check(
						not hitsPillar(minX, maxX, minZ, maxZ, minY, maxY),
						`area {area} {model.key} clear of the arch pillars`
					)
				end
			end
			for index, box in group.collision or {} do
				local minX, maxX, minZ, maxZ, minY, maxY = boxAabb(slot * box.cf, Vector3.new(0, 0, 0), box.size)
				check(
					not hitsPillar(minX, maxX, minZ, maxZ, minY, maxY),
					`area {area} collider {index} clear of the arch pillars`
				)
			end
		end
		for padId, point in layout.pads or {} do
			local p = slot * point
			check(
				not hitsPillar(p.X - 3.45, p.X + 3.45, p.Z - 3.45, p.Z + 3.45, p.Y, p.Y + 1.55),
				`area {area} pad {padId} clear of the arch`
			)
		end
	end
	for index, box in HubLayout.lockedSlot.collision do
		for _, sx in { -0.5, 0.5 } do
			for _, sz in { -0.5, 0.5 } do
				local corner = box.cf * Vector3.new(box.size.X * sx, 0, box.size.Z * sz)
				check(WorldLayout.inSlot(1, corner, 0.5), `locked-slot collider {index} inside the slot`)
			end
		end
	end
end

--------------------------------------------------------------------------------------------------
-- 6. Budgets (owner R11: mobile / console first; the hub is always streamed in)
--------------------------------------------------------------------------------------------------
local function cost(list: { any }, filter: string?): (number, number, number)
	local parts, triangles = 0, 0
	local unique: { [string]: boolean } = {}
	local uniqueCount = 0
	for _, entry in list do
		if filter == nil or entry.group == filter then
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
	local BUDGETS = {
		-- Owner R55 lobby-centre redesign (L1-lobby): +~140 MeshParts, all instanced repeats (8 paths,
		-- 7 gardens, 8 gateways, 9 banners, 10 coins) with pieces merged wherever colours allow.
		-- Measured 2026-10-30 after the redesign: 660 parts, 144.4k triangles, 37 unique meshes.
		-- + the R57 Time Machine (W9, 9 pieces / 4,448 triangles): 669 / 148.9k / 38, inside the same
		-- budget (the machine was built lean for exactly that).
		-- + the R70 Moon Rocket (W9b, 9 pieces / 3,880 triangles, built lean the same way): 678 /
		-- 152.8k / 39. The cap grows by exactly one portal (+10 parts, +4k triangles, +1 mesh): a
		-- lobby portal per world is the worlds framework's contract (spec r69 §2.3), every other
		-- lobby number is unchanged.
		{ label = "hub lobby", parts = 680, triangles = 154000, unique = 39, list = HubLayout.models, group = "hub" },
		{
			label = "island scenery",
			parts = 500, -- wedge props stream by distance; only nearby wedges are ever loaded
			triangles = 100000,
			unique = 12,
			list = HubLayout.models,
			group = "scenery",
		},
		{ label = "Harvest event", parts = 120, triangles = 28000, unique = 10, list = HubLayout.event.harvest.models },
	}
	for _, budget in BUDGETS do
		local parts, triangles, unique = cost(budget.list, budget.group)
		check(parts <= budget.parts, `{budget.label}: {parts} MeshParts <= {budget.parts}`)
		check(triangles <= budget.triangles, `{budget.label}: {triangles} triangles <= {budget.triangles}`)
		check(unique <= budget.unique, `{budget.label}: {unique} unique meshes <= {budget.unique}`)
	end
	-- One plot: frame + all 10 slots still locked (a brand-new player's plot, the worst case).
	local frameParts, frameTriangles = cost(HubLayout.plotFrame.models)
	local slotParts, slotTriangles = cost(HubLayout.lockedSlot.models)
	local plotParts = frameParts + WorldLayout.AreaCount * slotParts
	local plotTriangles = frameTriangles + WorldLayout.AreaCount * slotTriangles
	check(plotParts <= 80, `plot frame + 10 locked slots: {plotParts} MeshParts <= 80`)
	check(plotTriangles <= 28000, `plot frame + 10 locked slots: {plotTriangles} triangles <= 28000`)
end

--------------------------------------------------------------------------------------------------
-- 7. World portals (owner R57 Time Machine, R70 Moon Rocket): one lobby portal per extra world
--------------------------------------------------------------------------------------------------
do
	local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
	local portals = anchors.WorldPortals
	check(type(portals) == "table", "anchors.WorldPortals")
	for _, def in WorldsConfig.extra() do
		check(portals[def.portalAnchor] ~= nil, `WorldPortals.{def.portalAnchor} for world {def.id}`)
	end
	--[[
		Portal models (each world brings its own mesh; HubBuilder is generic): the walk-in opening of
		each model, so its trigger stays inside the swirl / launch ring. openHalf = max trigger
		half-width, top = the opening's top (ring centre + inner radius) the trigger stays under.
	]]
	local PORTAL_MODELS: { [string]: { openHalf: number, top: number } } = {
		Hub_TimeMachine = { openHalf = 5.5, top = 18.8 }, -- ring centre 10, inner r 8.8
		Hub_MoonRocket = { openHalf = 5.0, top = 16.0 }, -- ring centre 8.6, inner r 7.4
	}
	-- Model-space bounds of a portal mesh (every piece box).
	local function bounds(key: string): (any, any)
		local lo = Vector3.new(math.huge, math.huge, math.huge)
		local hi = Vector3.new(-math.huge, -math.huge, -math.huge)
		for _, piece in MeshAssets[key].pieces do
			lo = lo:Min(piece.offset - piece.size / 2)
			hi = hi:Max(piece.offset + piece.size / 2)
		end
		return lo, hi
	end
	-- The model key of a portal anchor's placement ("<key>_<index>").
	local function portalKey(model: string): string
		return string.match(model, "^(.-)_%d+$") or model
	end
	-- Everything a portal must never stand on / in (world-space points with a clearance radius).
	local keepOut: { { name: string, pos: any, radius: number } } = {}
	local CLEAR: { [string]: number } = {
		Hub_Tree = 5,
		Hub_Lamp = 1.2,
		Hub_Bench = 3.2,
		Hub_Planter = 3,
		Scenery_Flowers = 3,
		Hub_EggStand = 5,
		Hub_CrateStall = 8,
		Hub_GroupChest = 6,
		Hub_LuckyWheelStage = 10,
		Hub_Leaderboard = 8,
		Hub_CodesBoard = 7.5,
		Hub_TitleSign = 3,
		Hub_SpawnPad = 9.5,
	}
	for _, entry in HubLayout.models do
		local radius = CLEAR[entry.key]
		if radius ~= nil then
			table.insert(keepOut, { name = entry.name, pos = entry.cf.Position, radius = radius })
		elseif entry.key == "Hub_PlotGate" then
			for _, x in { -14.5, 14.5 } do
				table.insert(
					keepOut,
					{ name = `{entry.name} pillar`, pos = (entry.cf * CFrame.new(x, 0, 0)).Position, radius = 3 }
				)
			end
		end
	end
	local lastIndex = 0
	local portalPositions: { { id: string, pos: any } } = {}
	for id, portal in portals do
		local key = portalKey(portal.model)
		local spec = PORTAL_MODELS[key]
		check(spec ~= nil, `portal {id}: {key} is a known portal model`)
		local tmLo, tmHi = bounds(key)
		local sign = MeshAssets[key].pieces.Sign
		check(sign ~= nil, `{key} has a Sign piece`)
		check(HubLayout.surfaces[key] ~= nil and HubLayout.surfaces[key][1].piece == "Sign", `{key} Sign surface`)
		local entry = names(portal.model, key)
		table.insert(portalPositions, { id = id, pos = portal.cf.Position })
		check(entry.cf == portal.cf, `portal {id} cf matches its model`)
		check(entry.group == "hub" and not HubLayout.isDeferred(entry.key), `portal {id} is a first-wave hub model`)
		check((portal.cf.Position - spawnPos).Magnitude <= 200, `portal {id} within the near-hub radius of the spawn`)
		lastIndex = math.max(lastIndex, tonumber(string.match(entry.name, "_(%d+)$")) or 0)
		-- Trigger inside the swirl, above the dais; prompt in front; sign on its face; arrival.
		local lt = portal.cf:ToObjectSpace(portal.trigger.cf)
		local size = portal.trigger.size
		check(
			math.abs(lt.Position.X) < 1e-3 and math.abs(lt.Position.Z) < 1e-3,
			`portal {id} trigger centred in the ring`
		)
		check(
			size.X / 2 <= spec.openHalf and lt.Position.Y - size.Y / 2 >= 1.0 and lt.Position.Y + size.Y / 2 <= spec.top,
			`portal {id} trigger in the swirl`
		)
		local lp = portal.cf:PointToObjectSpace(portal.prompt.Position)
		check(lp.Z < -10 and lp.Z > -14 and math.abs(lp.X) < 1e-3, `portal {id} prompt in front of the step`)
		local face = Vector3.new(sign.offset.X, sign.offset.Y, sign.offset.Z - sign.size.Z / 2)
		check(
			(portal.cf:PointToObjectSpace(portal.sign.Position) - face).Magnitude < 0.05,
			`portal {id} sign on the Sign face`
		)
		check(portal.sign.LookVector:Dot(portal.cf.LookVector) > 0.999, `portal {id} sign faces out`)
		check(portal.arrive.LookVector:Dot(portal.cf.LookVector) > 0.999, `portal {id} arrival faces away from it`)
		local la = portal.trigger.cf:PointToObjectSpace(portal.arrive.Position)
		check(math.abs(la.Z) - size.Z / 2 >= 6, `portal {id} arrival >= 6 studs outside the trigger`)
		-- Faces the spawn, and is not hidden behind the SELL NUKES sign from the spawn.
		local toSpawn = (spawnPos - portal.cf.Position) * Vector3.new(1, 0, 1)
		check(portal.cf.LookVector:Dot(toSpawn.Unit) > 0.999, `portal {id} faces the spawn`)
		local look = HubLayout.spawn.LookVector
		local function angle(p: any): number
			local d = (p - spawnPos) * Vector3.new(1, 0, 1)
			return math.deg(math.acos(math.clamp(d.Unit:Dot(look), -1, 1)))
		end
		local signDistance = (anchors.TitleSign.cf.Position - spawnPos).Magnitude
		local signHalf = math.deg(math.atan(22 / signDistance))
		local half = math.deg(math.atan(tmHi.X / toSpawn.Magnitude))
		check(angle(portal.cf.Position) - half >= signHalf, `portal {id} not behind the title sign`)
		check(
			angle(portal.cf.Position) <= 45,
			`portal {id} within 45° of the spawn view ({angle(portal.cf.Position)})`
		)
		-- Footprint: corners + edge midpoints of the mesh bounds (incl. the step).
		local samples: { any } = {}
		for _, fx in { 0, 0.5, 1 } do
			for _, fz in { 0, 0.5, 1 } do
				local x = tmLo.X + (tmHi.X - tmLo.X) * fx
				local z = tmLo.Z + (tmHi.Z - tmLo.Z) * fz
				table.insert(samples, (portal.cf * CFrame.new(x, 0, z)).Position)
			end
		end
		for _, p in samples do
			local r = planar(p)
			check(r >= BED_OUT_R + 0.5 and r <= PLAZA_R - 0.5, `portal {id} footprint on the forecourt paving (r {r})`)
			check(avenueDistance(p) >= AVENUE_HALF + 1, `portal {id} footprint off the avenues`)
			check(r > CENTER_EDGE, `portal {id} clear of the R55 lobby centre`)
		end
		-- Fixtures, trees, lamps, the spawn pad and the gate pillars stay out of the footprint.
		for _, item in keepOut do
			local p = portal.cf:PointToObjectSpace(item.pos)
			local dx = math.max(tmLo.X - p.X, p.X - tmHi.X, 0)
			local dz = math.max(tmLo.Z - p.Z, p.Z - tmHi.Z, 0)
			check(math.sqrt(dx * dx + dz * dz) >= item.radius + 0.5, `portal {id} clear of {item.name}`)
		end
		-- Clear of the event square (oriented box) with the machine's half-diagonal as margin.
		local sq = anchors.EventSquare.cf:PointToObjectSpace(portal.cf.Position)
		local reach = math.sqrt(tmHi.X * tmHi.X + tmLo.Z * tmLo.Z)
		check(
			math.abs(sq.X) > anchors.EventSquare.size.X / 2 + reach
				or math.abs(sq.Z) > anchors.EventSquare.size.Z / 2 + reach,
			`portal {id} clear of the EventSquare`
		)
	end
	-- Appended last: every earlier placement kept its "<key>_<index>" name (anchors / instances), so
	-- the portals are the last N world placements.
	local portalCount = #portalPositions
	check(lastIndex == #HubLayout.models, "the world portals are the last world placements")
	for i = #HubLayout.models - portalCount + 1, #HubLayout.models do
		check(PORTAL_MODELS[HubLayout.models[i].key] ~= nil, `placement {i} is a world portal`)
	end
	-- Portals never crowd each other: their pivots stay >= 60 studs apart (each footprint ~32 wide).
	for i = 1, portalCount do
		for j = i + 1, portalCount do
			local a, b = portalPositions[i], portalPositions[j]
			check((a.pos - b.pos).Magnitude >= 60, `portals {a.id} / {b.id} at least 60 studs apart`)
		end
	end
end

print(`[hub-layout] {checks} checks passed`)
