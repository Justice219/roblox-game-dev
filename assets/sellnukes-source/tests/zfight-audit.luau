--!strict
--[[
	Z-fighting audit (owner R18, port of RoBeasts' map z-fight audit; module src/shared/World/ZFight).

	Places EVERYTHING as the game builds it and asserts that no two visible pieces have coplanar,
	same-facing, overlapping faces (the flicker the owner saw on the Garage Lab / plot floor).
	EVERY WORLD is audited (owner R57 worlds framework, W6 2026-10-31): the worlds come from
	WorldsConfig.Order through tests/fixtures/ArtWorlds (main only until the registry exists). The
	main world's scenes keep their names; another world's scenes are prefixed "<id>:" ("dino:hub").
		Scene "hub"        the world's hub layout `models` (main: hub + island, + the Harvest Feast
		                   group) + the plot frame of all 8 plots, in the world's own frame (main:
		                   WORLD space; other worlds: relative to their origin, like ValleyLayout).
		Scene "plot-fresh" one plot (plot-local; all 8 are identical): frame, a locked placeholder in
		                   every slot, and (main) the Harvest plot decorations on HubLayout.plotDecor.
		Scene "plot-full"  one plot fully built: frame, decorations, every area's base + every build
		                   (ArtWorlds.areaLayout: main merges art with placeholders exactly like
		                   Tycoon/AreaLayouts.get; other worlds use their authored layouts, which must
		                   validate), placed through WorldLayout.slotLocal(area, world), plus every
		                   BuyPad (as PlotBuilder places them). A pad only coexists with builds of
		                   EARLIER pads, so pad-vs-build pairs where the build comes later in the
		                   world's PadOrder are ignored.
	A world whose hub layout module does not exist yet gets only its "plot-full" scene.
	Geometry: the REAL triangles of every piece, read from assets/blender/world/<Key>.glb (checked
	against MeshAssets' piece boxes), primitive placeholder blocks as boxes. Three checks per scene:
		* overlaps  ZFight.facePairs — exact coplanar same-facing overlap (any rotation)
		* LOD seams ZFight.seamPairs — coplanar pieces butting along a CURVED seam (Roblox simplifies
		            each MeshPart's LOD alone, so both sides of the curve cross and flicker at range;
		            owner's ring-road / plot-entrance screenshots, R18b)
		* fallback  ZFight.pairs over every piece's bounding box (MeshLibrary's primitive fallback);
		            asserted only for the road / marking models (ROAD_KEYS), where it must be 0.

	Layer rule (docs/areas-art.md "Z-fighting layer rule"): plot ground top y = 0, area base floors
	+0.06, build floors / rugs +0.12, decals / stripes +0.18; abutting floors butt edge to edge.

	Owners: offenders are grouped by who placed the piece (main: hub/frame/decor = B8e, areas 1-3 =
	B8a, 4-6 = B8b, 7-8 = B8c, 9-10 = B8d; Dino: Base Camp/frame = W9, D1-2 = W6, D3-4 = W7,
	D5-6 = W8; BuyPads + placeholder blocks = B3; see tests/fixtures/ArtWorlds). PENDING is a per-owner
	RATCHET of offenders already reported to that owner (2026-10-30, owner rule R18) but not fixed
	yet: an owner's count may only go DOWN (any increase fails the suite); when it drops, the run
	prints the new number so PENDING can be lowered. Since 2026-10-30 (A1-art) every owner is at 0
	overlaps and 0 curved seams, PENDING / PENDING_SEAMS are empty and the audit asserts 0.

	Run: lune run tests/zfight-audit.luau      (LUNE_VERBOSE=1 lists every offender)
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local ArtWorlds = require("./fixtures/ArtWorlds")
local Loader = require("./fixtures/RobloxLoader")

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local loader = Loader.new()
local ZFight = loader.load("src/shared/World/ZFight")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")

local VERBOSE = process.env.LUNE_VERBOSE == "1"
local WORLD_DIR = "assets/blender/world"

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end

--------------------------------------------------------------------------------------------------
-- GLB reader: piece name -> flat triangle list {x1,y1,z1, x2,y2,z2, x3,y3,z3, ...} (model space)
--------------------------------------------------------------------------------------------------
local glbCache: { [string]: { [string]: { number } } } = {}

--[[
	Reads a binary glTF written by tools/blender/generate_world.py (export_yup, one node per piece,
	identity node transforms, so vertex positions are Roblox model-space studs).
]]
local function readGlb(key: string): { [string]: { number } }
	local cached = glbCache[key]
	if cached ~= nil then
		return cached
	end
	local data = buffer.fromstring(fs.readFile(`{WORLD_DIR}/{key}.glb`))
	assert(buffer.readu32(data, 0) == 0x46546C67, `{key}.glb: not a glTF binary`)
	local jsonLength = buffer.readu32(data, 12)
	local json = serde.decode("json", buffer.readstring(data, 20, jsonLength))
	local binStart = 20 + jsonLength + 8 -- BIN chunk header (length + type) follows the JSON chunk
	local function accessorData(index: number): (number, number, number, number)
		local accessor = json.accessors[index + 1]
		local view = json.bufferViews[accessor.bufferView + 1]
		return binStart + (view.byteOffset or 0) + (accessor.byteOffset or 0),
			accessor.count,
			accessor.componentType,
			view.byteStride or 0
	end
	local pieces: { [string]: { number } } = {}
	for _, node in json.nodes do
		if node.mesh == nil then
			continue
		end
		check(node.rotation == nil and node.scale == nil, `{key}.{node.name}: identity node transform`)
		local t = node.translation or { 0, 0, 0 }
		local tris = pieces[node.name] or {}
		pieces[node.name] = tris
		for _, primitive in json.meshes[node.mesh + 1].primitives do
			local posStart, posCount, _, posStride = accessorData(primitive.attributes.POSITION)
			local stride = if posStride > 0 then posStride else 12
			local positions = table.create(posCount * 3)
			for v = 0, posCount - 1 do
				local at = posStart + v * stride
				positions[v * 3 + 1] = buffer.readf32(data, at) + t[1]
				positions[v * 3 + 2] = buffer.readf32(data, at + 4) + t[2]
				positions[v * 3 + 3] = buffer.readf32(data, at + 8) + t[3]
			end
			local idxStart, idxCount, idxType = accessorData(primitive.indices)
			for i = 0, idxCount - 1 do
				local vertex
				if idxType == 5125 then
					vertex = buffer.readu32(data, idxStart + i * 4)
				elseif idxType == 5123 then
					vertex = buffer.readu16(data, idxStart + i * 2)
				else
					vertex = buffer.readu8(data, idxStart + i)
				end
				table.insert(tris, positions[vertex * 3 + 1])
				table.insert(tris, positions[vertex * 3 + 2])
				table.insert(tris, positions[vertex * 3 + 3])
			end
		end
	end
	-- Sanity: the GLB geometry matches MeshAssets' piece boxes (axis convention + freshness).
	local asset = MeshAssets[key]
	for name, piece in asset.pieces do
		local tris = pieces[name]
		check(tris ~= nil and #tris >= 9, `{key}.{name}: geometry in the GLB`)
		local lo = { math.huge, math.huge, math.huge }
		local hi = { -math.huge, -math.huge, -math.huge }
		for i = 1, #tris, 3 do
			for a = 1, 3 do
				lo[a] = math.min(lo[a], tris[i + a - 1])
				hi[a] = math.max(hi[a], tris[i + a - 1])
			end
		end
		local centre = Vector3.new((lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2)
		check((centre - piece.offset).Magnitude < 0.02, `{key}.{name}: GLB centre matches MeshAssets offset`)
	end
	glbCache[key] = pieces
	return pieces
end

-- The 12 triangles of a block (placeholder Parts) centred at the origin, outward-facing.
local function boxTriangles(size: any): { number }
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local c = {
		{ -hx, -hy, -hz },
		{ hx, -hy, -hz },
		{ hx, hy, -hz },
		{ -hx, hy, -hz },
		{ -hx, -hy, hz },
		{ hx, -hy, hz },
		{ hx, hy, hz },
		{ -hx, hy, hz },
	}
	local faces = { { 1, 4, 3, 2 }, { 5, 6, 7, 8 }, { 1, 2, 6, 5 }, { 2, 3, 7, 6 }, { 3, 4, 8, 7 }, { 4, 1, 5, 8 } }
	local out: { number } = {}
	for _, f in faces do
		for _, tri in { { f[1], f[2], f[3] }, { f[1], f[3], f[4] } } do
			for _, corner in tri do
				table.insert(out, c[corner][1])
				table.insert(out, c[corner][2])
				table.insert(out, c[corner][3])
			end
		end
	end
	return out
end

--------------------------------------------------------------------------------------------------
-- Scene builder
--------------------------------------------------------------------------------------------------
type Piece = { label: string, owner: string, key: string, padIndex: number?, buildIndex: number? }
type Scene = {
	name: string,
	triangles: { any },
	boxes: { any },
	pieces: { Piece },
	skippedBoxes: number,
}

local function newScene(name: string): Scene
	return { name = name, triangles = {}, boxes = {}, pieces = {}, skippedBoxes = 0 }
end

-- Appends one placed piece's triangles (model-space flat list) transformed by `cf`.
local function addTriangles(scene: Scene, id: number, cf: any, tris: { number })
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local out = scene.triangles
	for i = 1, #tris, 9 do
		local t = { piece = id }
		for k = 0, 2 do
			local px, py, pz = tris[i + 3 * k], tris[i + 3 * k + 1], tris[i + 3 * k + 2]
			local wx = x + r00 * px + r01 * py + r02 * pz
			local wy = y + r10 * px + r11 * py + r12 * pz
			local wz = z + r20 * px + r21 * py + r22 * pz
			if k == 0 then
				t.x1, t.y1, t.z1 = wx, wy, wz
			elseif k == 1 then
				t.x2, t.y2, t.z2 = wx, wy, wz
			else
				t.x3, t.y3, t.z3 = wx, wy, wz
			end
		end
		table.insert(out, t)
	end
end

-- Model key of every box (the fallback check filters road / marking models).
local boxKey: { [any]: string } = {}

-- Places a whole MeshAssets model (every piece) at `cf`.
local function addModel(scene: Scene, key: string, cf: any, label: string, owner: string, extra: { [string]: any }?)
	check(MeshAssets[key] ~= nil, `{scene.name}: {label} key {key} in MeshAssets`)
	local geometry = readGlb(key)
	for name, piece in MeshAssets[key].pieces do
		local entry: Piece = { label = `{label}.{name}`, owner = owner, key = key }
		if extra ~= nil then
			entry.padIndex = extra.padIndex
			entry.buildIndex = extra.buildIndex
		end
		table.insert(scene.pieces, entry)
		local id = #scene.pieces
		addTriangles(scene, id, cf, geometry[name])
		local box, reason = ZFight.box(cf * CFrame.new(piece.offset), piece.size, entry.label, owner)
		if box ~= nil then
			boxKey[box] = key
			table.insert(scene.boxes, box)
		elseif reason == "rotated" then
			scene.skippedBoxes += 1
		end
	end
end

-- Places a primitive placeholder block (PlotBuilder `model.box` entries; balls / cylinders skipped).
local function addBlock(scene: Scene, size: any, cf: any, label: string, owner: string, extra: { [string]: any }?)
	table.insert(scene.pieces, {
		label = label,
		owner = owner,
		key = "(block)",
		padIndex = extra and extra.padIndex,
		buildIndex = extra and extra.buildIndex,
	})
	addTriangles(scene, #scene.pieces, cf, boxTriangles(size))
	local box = ZFight.box(cf, size, label, owner)
	if box ~= nil then
		table.insert(scene.boxes, box)
	end
end

-- Harvest plot decorations as B11 places them (sample on every plotDecor slot it uses; main only).
local PLOT_DECOR: { [string]: string } = {
	GroundL1 = "Harvest_HayBale",
	GroundL2 = "Harvest_Scarecrow",
	GroundL3 = "Harvest_TurkeyStatue",
	GroundR1 = "Harvest_PumpkinPile",
	GroundR2 = "Harvest_CornucopiaSmall",
	Arch = "Harvest_Garland",
}

--[[
	Places a world's plot frame (hubLayout.plotFrame) at `origin`, plus (main only) the Harvest
	plot decorations. `owner` = the world's hub builder.
]]
local function addPlotFrame(scene: Scene, hubLayout: any, owner: string, origin: any, label: string, withDecor: boolean)
	local frame = hubLayout.plotFrame
	if frame ~= nil then
		for index, entry in frame.models do
			addModel(scene, entry.key, origin * entry.cf, `{label}{entry.name or `{entry.key}_{index}`}`, owner)
		end
	end
	if withDecor and hubLayout.plotDecor ~= nil then
		for slot, key in PLOT_DECOR do
			local cf = hubLayout.plotDecor[slot]
			if cf ~= nil then
				addModel(scene, key, origin * cf, `{label}Decor_{slot}`, owner)
			end
		end
	end
end

--[[
	Index (in the world's PadOrder) of the pad whose purchase builds each build key.
	@param economy any — the world's EconomyIndex (TycoonConfig for main)
]]
local function buildPadIndexOf(economy: any): { [string]: number }
	local out: { [string]: number } = {}
	for padId, index in economy.PadIndex do
		local pad = economy.PadsById[padId]
		if pad ~= nil and type(pad.build) == "string" then
			out[pad.build] = index
		end
	end
	return out
end

local function addEntry(scene: Scene, entry: any, slot: any, label: string, owner: string, buildIndex: number?)
	for index, model in entry.models or {} do
		local cf = slot * model.cf
		local extra = { buildIndex = buildIndex }
		if model.key ~= nil and MeshAssets[model.key] ~= nil then
			addModel(scene, model.key, cf, `{label}{model.key}_{index}`, owner, extra)
		elseif model.box ~= nil and (model.shape == nil or model.shape == "Block") then
			addBlock(scene, model.box, cf, `{label}Block_{index}`, if model.key == nil then "B3" else owner, extra)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Self-test: synthetic shapes with a known answer, so a change to ZFight can't silently blind the
-- audit (A1-art, 2026-10-30).
--------------------------------------------------------------------------------------------------
do
	-- Upward-facing triangle (winding fixed so the normal points +Y), as ZFight.Triangle.
	local function up(piece: number, a: { number }, b: { number }, c: { number }): any
		local ux, uz = b[1] - a[1], b[2] - a[2]
		local vx, vz = c[1] - a[1], c[2] - a[2]
		if uz * vx - ux * vz < 0 then
			b, c = c, b
		end
		return {
			piece = piece,
			x1 = a[1],
			y1 = a[3],
			z1 = a[2],
			x2 = b[1],
			y2 = b[3],
			z2 = b[2],
			x3 = c[1],
			y3 = c[3],
			z3 = c[2],
		}
	end
	-- Flat quad (x0..x1, z0..z1) at height y as two triangles (with an internal diagonal).
	local function quad(out: { any }, piece: number, x0: number, x1: number, z0: number, z1: number, y: number)
		table.insert(out, up(piece, { x0, z0, y }, { x1, z0, y }, { x1, z1, y }))
		table.insert(out, up(piece, { x0, z0, y }, { x1, z1, y }, { x0, z1, y }))
	end
	-- Flat ring sector r0..r1 over 0..90 degrees in `segments` steps at height y.
	local function ring(out: { any }, piece: number, r0: number, r1: number, y: number, segments: number)
		for k = 0, segments - 1 do
			local a0, a1 = math.rad(90 * k / segments), math.rad(90 * (k + 1) / segments)
			local p00 = { r0 * math.cos(a0), r0 * math.sin(a0), y }
			local p10 = { r1 * math.cos(a0), r1 * math.sin(a0), y }
			local p11 = { r1 * math.cos(a1), r1 * math.sin(a1), y }
			local p01 = { r0 * math.cos(a1), r0 * math.sin(a1), y }
			table.insert(out, up(piece, p00, p10, p11))
			table.insert(out, up(piece, p00, p11, p01))
		end
	end

	-- Overlap pass: coplanar overlapping squares flicker; 0.05 apart they don't.
	local flush, apart = {}, {}
	quad(flush, 1, 0, 4, 0, 4, 1)
	quad(flush, 2, 2, 6, 2, 6, 1)
	quad(apart, 1, 0, 4, 0, 4, 1)
	quad(apart, 2, 2, 6, 2, 6, 1.05)
	check(#ZFight.facePairs(flush) == 1, "self-test: coplanar overlapping squares are one offender")
	check(#ZFight.facePairs(apart) == 0, "self-test: squares 0.05 apart are clean")
	-- An overlapping triangle whose exactly-zero normal x comes out as -0 (0 * -4 - 4 * 0): -0 once
	-- printed as "-0" in the plane key and split one plane into two groups that were never compared.
	local signed = {}
	quad(signed, 1, 0, 4, 0, 4, 1)
	table.insert(signed, up(2, { 2, 2, 1 }, { 6, 6, 1 }, { 6, -2, 1 }))
	check(#ZFight.facePairs(signed) == 1, "self-test: -0 normal components share the plane group")

	-- Seam pass: two rings butting along a curve at ONE height = the ring-road bug (R18b).
	local curved, raised, groove = {}, {}, {}
	ring(curved, 1, 20, 24, 0, 24)
	ring(curved, 2, 24, 26, 0, 24)
	ring(raised, 1, 20, 24, 0, 24)
	ring(raised, 2, 24, 26, 0.25, 24)
	ring(groove, 1, 20, 24, 0, 24)
	ring(groove, 2, 24.4, 26, 0, 24) -- a 0.4 chamfer groove does not help (LOD margin 0.6)
	check(#ZFight.seamPairs(curved) == 1, "self-test: a curved same-height seam is flagged")
	check(#ZFight.seamPairs(groove) == 1, "self-test: a 0.4-stud groove along a curve is still flagged")
	check(#ZFight.seamPairs(raised) == 0, "self-test: a curb 0.25 higher is clean")

	-- Straight seams survive LOD: slabs edge to edge, a rectangle inside a frame, and alternating
	-- narrow hazard stripes (their quad diagonals are not seams).
	local straight, framed, stripes = {}, {}, {}
	quad(straight, 1, 0, 10, 0, 10, 0)
	quad(straight, 2, 10, 20, 0, 10, 0)
	quad(framed, 1, 2, 8, 2, 8, 0)
	quad(framed, 2, 0, 10, 0, 2, 0)
	quad(framed, 2, 0, 10, 8, 10, 0)
	quad(framed, 2, 0, 2, 2, 8, 0)
	quad(framed, 2, 8, 10, 2, 8, 0)
	for k = 0, 11 do
		quad(stripes, 1 + k % 2, k * 0.7, (k + 1) * 0.7, 0, 0.13, 1.1)
	end
	-- Two unrelated straight seams of the same piece pair ending 0.3 apart at a 9° angle (a hazard
	-- ring's radial seam next to a door band): one joint is not a curve.
	local function slab(out: { any }, piece: number, p0: { number }, dir: { number }, len: number, side: number)
		local nx, nz = -dir[2] * side, dir[1] * side
		local a = { p0[1], p0[2], 0 }
		local b = { p0[1] + dir[1] * len, p0[2] + dir[2] * len, 0 }
		local c = { b[1] + nx, b[2] + nz, 0 }
		local d = { a[1] + nx, a[2] + nz, 0 }
		table.insert(out, up(piece, a, b, c))
		table.insert(out, up(piece, a, c, d))
	end
	local near = {}
	slab(near, 1, { 2, 0 }, { 0, 1 }, 5, 1)
	slab(near, 2, { 2, 0 }, { 0, 1 }, 5, -1)
	local turn = { math.cos(math.rad(81)), math.sin(math.rad(81)) }
	slab(near, 1, { 2, 5.3 }, turn, 3, 1)
	slab(near, 2, { 2, 5.3 }, turn, 3, -1)
	check(#ZFight.seamPairs(near) == 0, "self-test: two separate straight seams 0.3 apart are not a curve")
	check(#ZFight.seamPairs(straight) == 0, "self-test: a straight seam is clean")
	check(#ZFight.seamPairs(framed) == 0, "self-test: a rectangle in its frame (90° corners only) is clean")
	check(#ZFight.seamPairs(stripes) == 0, "self-test: narrow alternating stripes are clean")
end

--------------------------------------------------------------------------------------------------
-- Build the scenes
--------------------------------------------------------------------------------------------------
local scenes: { Scene } = {}
-- Authored layouts of non-main worlds that do not validate (no placeholder hides them; see ArtWorlds).
local layoutProblems: { string } = {}

for _, world in ArtWorlds.list(loader) do
	-- Main keeps its scene names and today's WorldLayout calls (nil world = main).
	local prefix = if world.isMain then "" else `{world.id}:`
	local worldArg: string? = if world.isMain then nil else world.id
	local hubLayout = if world.hubPath ~= nil then loader.load(world.hubPath) else nil
	local hubOwner = world.hubOwner

	if hubLayout ~= nil then
		local hub = newScene(`{prefix}hub`)
		for index, entry in hubLayout.models or {} do
			addModel(hub, entry.key, entry.cf, entry.name or `{entry.key}_{index}`, hubOwner)
		end
		local harvest = hubLayout.event and hubLayout.event.harvest
		if harvest ~= nil then
			for index, entry in harvest.models do
				addModel(hub, entry.key, entry.cf, `Event.{entry.name or `{entry.key}_{index}`}`, hubOwner)
			end
		end
		-- Plot origins are WORLD space; the hub layout is in the world's own frame.
		local toWorldLocal = world.origin:Inverse()
		for plot = 1, WorldLayout.PlotCount do
			local origin = toWorldLocal * WorldLayout.plotOrigin(plot, worldArg)
			addPlotFrame(hub, hubLayout, hubOwner, origin, `Plot{plot}.`, false)
		end
		table.insert(scenes, hub)

		local fresh = newScene(`{prefix}plot-fresh`)
		addPlotFrame(fresh, hubLayout, hubOwner, CFrame.new(), "", world.isMain)
		local locked = hubLayout.lockedSlot
		for area = 1, world.areaCount do
			for index, entry in (locked and locked.models) or {} do
				local cf = WorldLayout.slotLocal(area, worldArg) * entry.cf
				addModel(fresh, entry.key, cf, `Slot{area}.{entry.name or index}`, hubOwner)
			end
		end
		table.insert(scenes, fresh)
	end

	local full = newScene(`{prefix}plot-full`)
	if hubLayout ~= nil then
		addPlotFrame(full, hubLayout, hubOwner, CFrame.new(), "", world.isMain)
	end
	local economy = world.economy
	local buildPadIndex = buildPadIndexOf(economy)
	-- Area labels: main keeps "A<n>." (offender lists the owners know); other worlds use their build
	-- key prefix ("D<n>.").
	local areaTag = if world.isMain then "A" else string.upper(string.sub(world.id, 1, 1))
	for area = 1, world.areaCount do
		local layout, problems = ArtWorlds.areaLayout(loader, world, area)
		for _, problem in problems do
			table.insert(layoutProblems, `{world.id} Area{area}: {problem}`)
		end
		if layout == nil then
			continue
		end
		local slot = WorldLayout.slotLocal(area, worldArg)
		local owner = world.areaOwner(area)
		local tag = `{areaTag}{area}`
		addEntry(full, layout.base, slot, `{tag}.base.`, owner, 0)
		for buildKey, entry in layout.builds do
			addEntry(full, entry, slot, `{tag}.{buildKey}.`, owner, buildPadIndex[buildKey] or 0)
		end
		-- BuyPads exactly as PlotBuilder.createPad places them.
		for padId, point in layout.pads or {} do
			local pad = economy.PadsById[padId]
			if pad ~= nil then
				local cf = CFrame.new(slot * point) * (slot - slot.Position)
				addModel(full, "BuyPad", cf, `{tag}.pad.{padId}`, "B3", { padIndex = economy.PadIndex[padId] })
			end
		end
	end
	table.insert(scenes, full)
end

--------------------------------------------------------------------------------------------------
-- Audit
--------------------------------------------------------------------------------------------------

--[[
	Per-owner ratchet (see header). Lists were sent to each owner with exact piece pairs; run with
	LUNE_VERBOSE=1 to print them. Lower a number as soon as the run reports fewer offenders.
]]
-- Road / marking models whose primitive fallback must not z-fight either (owner R18b).
local ROAD_KEYS: { [string]: boolean } = { Hub_RingRoadArc = true, Plot_Road = true, Hub_Avenue = true }

-- Curved same-height seams (LOD flicker) per owner, same ratchet rule. Every owner is at 0
-- (A1-art, 2026-10-30): the table stays so a future regression has a place to be ratcheted, but
-- the target is 0 and any seam fails the suite.
local PENDING_SEAMS: { [string]: number } = {}

-- Face-overlap offenders per owner: every owner is at 0 (A1-art, 2026-10-30), so any offender
-- fails the suite. A future fix-in-progress may add `Owner = n` here only as a temporary ratchet.
local PENDING: { [string]: number } = {}

local function signature(scene: Scene, offender: any): (string, Piece, Piece)
	local a, b = scene.pieces[offender.a], scene.pieces[offender.b]
	if a.label > b.label then
		a, b = b, a
	end
	return `{scene.name}|{a.label}|{b.label}`, a, b
end

-- Pad vs build pairs that can never be on screen together (the build belongs to a later pad).
local function neverTogether(a: Piece, b: Piece): boolean
	local pad, build = a, b
	if pad.padIndex == nil then
		pad, build = b, a
	end
	if pad.padIndex == nil or build.buildIndex == nil then
		return false
	end
	return build.buildIndex >= pad.padIndex
end

local byOwner: { [string]: { string } } = {}
local seamsByOwner: { [string]: { string } } = {}
local fallbackRoad: { string } = {}
local totals: { [string]: number } = {}

for _, scene in scenes do
	local offenders = ZFight.facePairs(scene.triangles)
	local count = 0
	for _, offender in offenders do
		local _, a, b = signature(scene, offender)
		if neverTogether(a, b) then
			continue
		end
		count += 1
		local line = string.format(
			"[%s] %s / %s  plane n=(%.2f,%.2f,%.2f) d=%.3f  overlap %.2f studs²",
			scene.name,
			a.label,
			b.label,
			offender.normal.X,
			offender.normal.Y,
			offender.normal.Z,
			offender.offset,
			offender.area
		)
		for _, owner in { a.owner, b.owner } do
			byOwner[owner] = byOwner[owner] or {}
			table.insert(byOwner[owner], line)
			if a.owner == b.owner then
				break
			end
		end
	end
	totals[scene.name] = count
	local seams = ZFight.seamPairs(scene.triangles)
	for _, seam in seams do
		local _, a, b = signature(scene, seam)
		local line = string.format(
			"[%s] %s / %s  curved seam %.1f studs (%d curved joints) n=(%.2f,%.2f,%.2f) d=%.3f",
			scene.name,
			a.label,
			b.label,
			seam.length,
			seam.joints,
			seam.normal.X,
			seam.normal.Y,
			seam.normal.Z,
			seam.offset
		)
		for _, owner in { a.owner, b.owner } do
			seamsByOwner[owner] = seamsByOwner[owner] or {}
			table.insert(seamsByOwner[owner], line)
			if a.owner == b.owner then
				break
			end
		end
	end
	local boxPairs = ZFight.pairs(scene.boxes)
	for _, pair in boxPairs do
		if ROAD_KEYS[boxKey[pair.a]] and ROAD_KEYS[boxKey[pair.b]] then
			table.insert(fallbackRoad, `[{scene.name}] {ZFight.describe(pair)}`)
		end
	end
	print(
		string.format(
			"[zfight-audit] %-10s %6d triangles, %4d pieces: %d face offenders, %d curved seams (box pass: %d boxes, %d rotated skipped, %d bbox pairs)",
			scene.name,
			#scene.triangles,
			#scene.pieces,
			count,
			#seams,
			#scene.boxes,
			scene.skippedBoxes,
			#boxPairs
		)
	)
end

local failures: { string } = {}
for owner, lines in byOwner do
	table.sort(lines)
	local allowed = PENDING[owner] or 0
	print(`[zfight-audit] {owner}: {#lines} offender(s) (ratchet {allowed})`)
	if VERBOSE or #lines > allowed then
		for _, line in lines do
			print(`    {line}`)
		end
	end
	if #lines > allowed then
		table.insert(failures, `{owner}: {#lines} z-fighting offenders > {allowed} allowed`)
	elseif #lines < allowed then
		print(`[zfight-audit] {owner} improved: lower PENDING.{owner} to {#lines}`)
	end
	checks += 1
end
for owner, allowed in PENDING do
	if byOwner[owner] == nil and allowed > 0 then
		print(`[zfight-audit] {owner} is clean: set PENDING.{owner} to 0`)
	end
end
for owner, allowed in PENDING_SEAMS do
	if seamsByOwner[owner] == nil and allowed > 0 then
		print(`[zfight-audit] {owner} has no curved seams: set PENDING_SEAMS.{owner} to 0`)
	end
end
for owner, lines in seamsByOwner do
	table.sort(lines)
	local allowed = PENDING_SEAMS[owner] or 0
	print(`[zfight-audit] {owner}: {#lines} curved same-height seam(s) (ratchet {allowed})`)
	if VERBOSE or #lines > allowed then
		for _, line in lines do
			print(`    {line}`)
		end
	end
	if #lines > allowed then
		table.insert(failures, `{owner}: {#lines} curved same-height seams > {allowed} allowed`)
	elseif #lines < allowed then
		print(`[zfight-audit] {owner} seams improved: lower PENDING_SEAMS.{owner} to {#lines}`)
	end
	checks += 1
end
for _, line in fallbackRoad do
	print(`    fallback: {line}`)
end
if #fallbackRoad > 0 then
	table.insert(failures, `{#fallbackRoad} road / marking fallback-box z-fights`)
end
checks += 1
for _, problem in layoutProblems do
	print(`    layout: {problem}`)
end
if #layoutProblems > 0 then
	table.insert(failures, `{#layoutProblems} authored layout problem(s) in non-main worlds (fix the AreaNN file)`)
end
checks += 1
if #failures > 0 then
	error(`z-fighting regressions (see the lists above):\n  ` .. table.concat(failures, "\n  "))
end
check(true, "no z-fighting regressions")
print(`[zfight-audit] {checks} checks passed`)
