--!strict
--[[
	Mesh pipeline regressions (B4 art pipeline). Run:
		lune run tests/mesh-assets

	Loads the REAL generated modules (src/shared/Config/MeshAssets.luau,
	src/shared/Config/WorldMaterialConfig.luau) in a sandbox that supplies Roblox datatypes from
	@lune/roblox, and cross-checks them against the pipeline's on-disk truth:
	  1. MeshAssets shape: every piece has id (integer >= 0), positive finite size, finite offset,
	     Color3, a material WorldMaterialConfig knows, boolean tinted, transparency 0..1; `order` is
	     a bottom-to-top permutation of the pieces; no test-only models ship.
	  2. Manifest parity (assets/blender/world/manifest.json): same models, same pieces, same boxes,
	     triangle totals within each model's budget.
	  3. Hash-bound ids (assets/blender/world/mesh-ids.json): a non-zero id appears only when the
	     receipt's contentHash equals the CURRENT manifest's (sha256 over sorted name:hash pairs,
	     identical to tools/blender/upload_meshes.py content_hash) and matches that receipt's id.
	  4. Stud materials: WorldMaterialConfig variants == StudMaterialVariants.model.json children
	     (names, StudsPerTile, the three map ids) and image ids are uploaded (> 0).
	  5. Every model has <= 24 pieces (docs/world-art.md §4 hard cap: one draw call per piece).
	  6. Mesh budgets over EVERY world's area layouts (owner R57 worlds framework, W6 2026-10-31;
	     worlds from WorldsConfig.Order via tests/fixtures/ArtWorlds):
	       * every model key a layout places is in MeshAssets and fully uploaded (no piece id 0 —
	         an un-uploaded key would build as grey primitive boxes);
	       * every such model is <= HERO_TRIANGLES (world-art §4 "hero landmark" cap; spec §16);
	       * a fully built area (base + every build) is <= AREA_TRIANGLES[world] (spec §15: Dino
	         28k, finale 34k; main = the measured 2026-10-31 ceiling, 35.3k / finale 41.1k, so the
	         main areas can't grow).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local ArtWorlds = require("./fixtures/ArtWorlds")
local Loader = require("./fixtures/RobloxLoader")

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end

-- Run a src module with Roblox datatypes injected (they are not Lune globals).
local function loadModule(path: string): any
	local env = {
		Vector3 = roblox.Vector3,
		Color3 = roblox.Color3,
		Enum = roblox.Enum,
		string = string,
		table = table,
		math = math,
	}
	local chunk = luau.load(fs.readFile(path), { debugName = path, environment = env })
	return chunk()
end

local MeshAssets = loadModule("src/shared/Config/MeshAssets.luau")
local WorldMaterialConfig = loadModule("src/shared/Config/WorldMaterialConfig.luau")
local manifest = serde.decode("json", fs.readFile("assets/blender/world/manifest.json"))
local meshIds = if fs.isFile("assets/blender/world/mesh-ids.json")
	then serde.decode("json", fs.readFile("assets/blender/world/mesh-ids.json"))
	else {}

local function finite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

local function contentHash(pieces: { any }): string
	local rows = {}
	for _, piece in pieces do
		table.insert(rows, `{piece.name}:{piece.hash}`)
	end
	table.sort(rows)
	return serde.hash("sha256", table.concat(rows, "|"))
end

-- 1 + 2 + 3: every shipped model
local shipped = 0
for key, asset in MeshAssets do
	shipped += 1
	ok(string.sub(key, 1, 8) ~= "StudTest", `{key}: test-only model shipped`)
	local entry = manifest[key]
	ok(entry ~= nil, `{key}: missing from manifest.json`)
	ok(type(asset.pivot) == "string" and #asset.pivot > 0, `{key}: pivot description`)
	ok(asset.triangles == entry.triangles and asset.triangles <= entry.budget, `{key}: triangles/budget`)
	local byName = {}
	for _, piece in entry.pieces do
		byName[piece.name] = piece
	end
	local receipt = meshIds[key]
	local fresh = receipt ~= nil and receipt.contentHash == contentHash(entry.pieces)
	local seen = {}
	local lastBottom = -math.huge
	for _, name in asset.order do
		ok(seen[name] == nil, `{key}: duplicate {name} in order`)
		seen[name] = true
		local piece = asset.pieces[name]
		ok(piece ~= nil, `{key}: order names unknown piece {name}`)
		local bottom = piece.offset.Y - piece.size.Y / 2
		ok(bottom >= lastBottom - 0.002, `{key}: order not bottom-to-top at {name}`)
		lastBottom = bottom
	end
	local count = 0
	for name, piece in asset.pieces do
		count += 1
		ok(seen[name], `{key}.{name}: missing from order`)
		local source = byName[name]
		ok(source ~= nil, `{key}.{name}: not in manifest`)
		ok(type(piece.id) == "number" and piece.id >= 0 and piece.id % 1 == 0 and piece.id < 2 ^ 53, `{key}.{name}: id`)
		for _, axis in { "X", "Y", "Z" } do
			local s = (piece.size :: any)[axis]
			local o = (piece.offset :: any)[axis]
			ok(finite(s) and s > 0 and finite(o), `{key}.{name}: size/offset {axis}`)
		end
		ok(
			math.abs(piece.size.X - source.size[1]) < 1e-3 and math.abs(piece.offset.Y - source.offset[2]) < 1e-3,
			`{key}.{name}: box differs from manifest`
		)
		ok(typeof(piece.color) == "Color3", `{key}.{name}: color`)
		ok(WorldMaterialConfig.Materials[piece.material] ~= nil, `{key}.{name}: unknown material {piece.material}`)
		ok(type(piece.tinted) == "boolean", `{key}.{name}: tinted`)
		ok(piece.transparency >= 0 and piece.transparency <= 1, `{key}.{name}: transparency`)
		if piece.id > 0 then
			ok(fresh, `{key}.{name}: id shipped for stale content (re-upload or re-sync)`)
			ok(receipt.pieces[name].meshId == piece.id, `{key}.{name}: id differs from mesh-ids.json`)
			ok(receipt.pieces[name].hash == source.hash, `{key}.{name}: piece hash differs from receipt`)
		end
	end
	ok(count == #entry.pieces, `{key}: piece count differs from manifest`)
end
local expected = 0
for key in manifest do
	if string.sub(key, 1, 8) ~= "StudTest" then
		expected += 1
	end
end
ok(shipped == expected and shipped > 0, `MeshAssets has {shipped} models, manifest {expected}`)

-- 4: stud material variants
local model = serde.decode("json", fs.readFile("src/server/World/StudMaterialVariants.model.json"))
local children = {}
for _, child in model.children do
	children[child.name] = child
end
local images = WorldMaterialConfig.Images
ok(images.Color > 0 and images.Normal > 0 and images.Roughness > 0, "stud images uploaded")
local variants = 0
for configKey, spec in WorldMaterialConfig.Variants do
	variants += 1
	local child = children[spec.name]
	ok(child ~= nil and child.className == "MaterialVariant", `variant {spec.name} missing from model.json`)
	ok(child.properties.StudsPerTile == spec.studsPerTile, `variant {spec.name}: StudsPerTile drift`)
	ok(child.properties.ColorMap == `rbxassetid://{images.Color}`, `variant {spec.name}: ColorMap`)
	ok(child.properties.NormalMap == `rbxassetid://{images.Normal}`, `variant {spec.name}: NormalMap`)
	ok(child.properties.RoughnessMap == `rbxassetid://{images.Roughness}`, `variant {spec.name}: RoughnessMap`)
	ok(WorldMaterialConfig.Materials[configKey].variant == spec.name, `Materials.{configKey} uses {spec.name}`)
end
ok(variants == #model.children, "model.json has extra variants")

-- 5: pieces per model (hard cap)
local MAX_PIECES = 24
for key, asset in MeshAssets do
	local count = 0
	for _ in asset.pieces do
		count += 1
	end
	ok(count <= MAX_PIECES, `{key}: {count} pieces > {MAX_PIECES} (each piece is a draw call)`)
end

-- 6: per-world layout mesh budgets (see header)
local HERO_TRIANGLES = 6000
-- Fully built area triangle budgets: `default`, plus the finale area (`finale`, by area count).
local AREA_TRIANGLES: { [string]: { default: number, finale: number } } = {
	main = { default = 36000, finale = 42000 },
	dino = { default = 28000, finale = 34000 },
}
local loader = Loader.new()
local areas = 0
local heaviest, heaviestTris = "", 0
for _, world in ArtWorlds.list(loader) do
	local budget = AREA_TRIANGLES[world.id] or AREA_TRIANGLES.dino -- a new world gets the Dino budget
	for area = 1, world.areaCount do
		local layout, problems = ArtWorlds.areaLayout(loader, world, area)
		ok(#problems == 0, `{world.id} Area{area}: layout problems: {table.concat(problems, "; ")}`)
		if layout == nil then
			continue
		end
		areas += 1
		local label = `{world.id} Area{area}`
		local total = 0
		for _, placement in ArtWorlds.placements(layout) do
			if placement.key == nil then
				total += 12 -- primitive placeholder block
				continue
			end
			local asset = MeshAssets[placement.key]
			ok(asset ~= nil, `{label}: {placement.key} is not in MeshAssets (build + upload + sync it)`)
			for name, piece in asset.pieces do
				ok(piece.id > 0, `{label}: {placement.key}.{name} is not uploaded (upload_meshes.py + sync_meshes.py)`)
			end
			ok(
				asset.triangles <= HERO_TRIANGLES,
				`{label}: {placement.key} {asset.triangles} triangles > {HERO_TRIANGLES}`
			)
			total += asset.triangles
		end
		local limit = if area == world.areaCount then budget.finale else budget.default
		ok(total <= limit, `{label}: fully built area is {total} triangles > {limit}`)
		if total > heaviestTris then
			heaviest, heaviestTris = label, total
		end
	end
end
ok(areas > 0, "some area layouts checked")

print(
	`[mesh-assets] {checks} checks passed ({shipped} models; {areas} areas, heaviest {heaviest} {heaviestTris} triangles)`
)
