--!strict
--[[
	Area layout + world frame regression (build plan "World layout").

	Checks:
		* WorldLayout frames: plot origins on the ring, slot frames right-handed pure Y rotations with
		  +Z_s pointing away from the road, every slot inside its plot footprint, no two slots or
		  plots overlapping, plotAt / entranceSpawn consistent.
		* LayoutLogic: the contract rules (own build keys exclude the EntryArch key, the finale is an
		  own build), validation catches each class of mistake, merge fills gaps from the placeholder
		  and passes extra fields (attack-mode mounts) through.
		* PlaceholderLayouts: every area's generated layout is COMPLETE and valid (every mesh key
		  exists in MeshAssets), so a plot is always playable before art lands.
		* Every committed art layout src/shared/Config/AreaLayouts/AreaNN.luau validates STRICTLY
		  (every own build key, every pad, producer, spawn point), and HubLayout (if present) has the
		  documented shape.
		* R57 worlds (plan §4 W3 task 1): every non-main world of WorldsConfig gets the same gate —
		  its placeholders are complete + valid against ITS geometry (Dino's finale D6 = 140 tall),
		  its own build keys carry its prefix ("D3_"), and its art layouts under
		  WorldDef.layoutFolder (Shared/Config/Worlds/Dino/Layouts/AreaNN.luau) validate STRICTLY
		  once every area of the world has a file, PARTIALLY (shape, bounds, ids, mesh keys) before,
		  so the art builders (W6–W8) are gated from their first file.

	Run: lune run tests/area-layouts.luau
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local loader = Loader.new()
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local LayoutLogic = loader.load("src/server/Tycoon/LayoutLogic")
local PlaceholderLayouts = loader.load("src/server/Tycoon/PlaceholderLayouts")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end
-- Default tolerance 1e-3: Lune's CFrame / Vector3 are float32 (Roblox's are too).
local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-3)
end
local function nearVector(a: any, b: any, eps: number?): boolean
	return near(a.X, b.X, eps) and near(a.Y, b.Y, eps) and near(a.Z, b.Z, eps)
end

--------------------------------------------------------------------------------------------------
-- World frames
--------------------------------------------------------------------------------------------------
do
	check(nearVector(WorldLayout.plotOrigin(1).Position, Vector3.new(0, 0, 260)), "plot 1 origin at (0, 0, 260)")
	for index = 1, WorldLayout.PlotCount do
		local origin = WorldLayout.plotOrigin(index)
		check(near(origin.Position.Magnitude, WorldLayout.PlotRadius), `plot {index} on the ring`)
		check(near(origin.Position.Y, 0), `plot {index} at ground level`)
		-- Plot +Z points away from the hub.
		local outward = origin:VectorToWorldSpace(Vector3.new(0, 0, 1))
		check(outward:Dot(origin.Position.Unit) > 0.999, `plot {index} +Z points outward`)
		check(WorldLayout.plotAt(origin * Vector3.new(0, 0, 100)) == index, `plotAt inside plot {index}`)
		local spawn = WorldLayout.entranceSpawn(index)
		check(WorldLayout.plotAt(spawn.Position) == index, `entrance spawn of plot {index} is on the plot`)
	end
	check(WorldLayout.plotAt(Vector3.new(0, 0, 0)) == nil, "the hub centre is not a plot")
	check(not pcall(WorldLayout.plotOrigin, 9), "plot 9 is rejected")
	check(not pcall(WorldLayout.slotLocal, 0), "slot 0 is rejected")

	-- Plots never overlap: the far corners of neighbouring plots stay apart.
	local function corners(index: number): { any }
		local origin = WorldLayout.plotOrigin(index)
		local h, l = WorldLayout.PlotHalfWidth, WorldLayout.PlotLength
		return {
			origin * Vector3.new(-h, 0, 0),
			origin * Vector3.new(h, 0, 0),
			origin * Vector3.new(-h, 0, l),
			origin * Vector3.new(h, 0, l),
		}
	end
	for index = 1, WorldLayout.PlotCount do
		local neighbour = index % WorldLayout.PlotCount + 1
		for _, corner in corners(neighbour) do
			check(WorldLayout.plotAt(corner * 0.999) ~= index, `plot {neighbour} corner not inside plot {index}`)
		end
	end

	for area = 1, WorldLayout.AreaCount do
		local slot = WorldLayout.slotLocal(area)
		local right = slot:VectorToWorldSpace(Vector3.new(1, 0, 0))
		local up = slot:VectorToWorldSpace(Vector3.new(0, 1, 0))
		local back = slot:VectorToWorldSpace(Vector3.new(0, 0, 1))
		check(nearVector(right:Cross(up), back), `slot {area} frame is right-handed`)
		check(nearVector(up, Vector3.new(0, 1, 0)), `slot {area} is a pure Y rotation`)
		-- +Z_s points away from the road: further from the plot centreline.
		local away = slot * Vector3.new(0, 0, 10)
		check(math.abs(away.X) > math.abs(slot.Position.X), `slot {area} +Z_s points away from the road`)
		check(near(math.abs(slot.Position.X), WorldLayout.SlotRoadOffset), `slot {area} origin at the road edge`)
		check((area % 2 == 1) == (slot.Position.X < 0), `slot {area} on the documented side`)
		-- Hub direction: -X_s on the left side, +X_s on the right side (plot -Z = toward the hub).
		local towardHub = if area % 2 == 1 then -1 else 1
		check(slot:VectorToWorldSpace(Vector3.new(towardHub, 0, 0)).Z < -0.99, `slot {area} hub direction`)
		-- The whole slot footprint lies inside the plot footprint, beside the road.
		for _, corner in
			{
				Vector3.new(-WorldLayout.SlotHalfWidth, 0, 0),
				Vector3.new(WorldLayout.SlotHalfWidth, 0, 0),
				Vector3.new(-WorldLayout.SlotHalfWidth, 0, WorldLayout.SlotDepth),
				Vector3.new(WorldLayout.SlotHalfWidth, 0, WorldLayout.SlotDepth),
			}
		do
			local p = slot * corner
			-- (Lune's CFrame is float32: 1e-3 stud tolerance.)
			check(math.abs(p.X) <= WorldLayout.PlotHalfWidth + 1e-3, `slot {area} inside the plot width`)
			check(math.abs(p.X) >= WorldLayout.RoadHalfWidth, `slot {area} clear of the road`)
			check(p.Z >= -1e-3 and p.Z <= WorldLayout.PlotLength + 1e-3, `slot {area} inside the plot length`)
		end
		-- Slots on the same side never overlap.
		for other = area + 2, WorldLayout.AreaCount, 2 do
			local a = WorldLayout.slotLocal(area).Position.Z
			local b = WorldLayout.slotLocal(other).Position.Z
			check(math.abs(a - b) >= WorldLayout.SlotHalfWidth * 2 - 1e-6, `slots {area} / {other} apart`)
		end
	end
	local world = WorldLayout.slotToWorld(3, 5, CFrame.new(0, 0, 10))
	check(
		nearVector(
			world.Position,
			(WorldLayout.plotOrigin(3) * WorldLayout.slotLocal(5) * CFrame.new(0, 0, 10)).Position
		),
		"slotToWorld"
	)
end

--------------------------------------------------------------------------------------------------
-- Contract rules
--------------------------------------------------------------------------------------------------
do
	local area1 = TycoonConfig.Areas[1]
	local own = LayoutLogic.ownBuildKeys(area1)
	check(table.find(own, "A2_EntryArch") == nil, "A2_EntryArch is area 2's base, not an area 1 build")
	check(table.find(own, "A1_ToolWall") ~= nil and #own == #area1.pads - 1, "area 1 own keys")
	local own10 = LayoutLogic.ownBuildKeys(TycoonConfig.Areas[10])
	check(table.find(own10, "A10_GoldenAtom") ~= nil, "the finale is an own build of area 10")
	check(#own10 == #TycoonConfig.Areas[10].pads, "area 10 has no EntryArch key")
	for _, area in TycoonConfig.Areas do
		for _, key in LayoutLogic.ownBuildKeys(area) do
			check(
				string.sub(key, 1, #`A{area.index}_`) == `A{area.index}_`,
				`own key {key} belongs to area {area.index}`
			)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Placeholders: complete and valid for every area
--------------------------------------------------------------------------------------------------
do
	for _, area in TycoonConfig.Areas do
		local layout = PlaceholderLayouts.generate(area.index)
		local problems = LayoutLogic.validate(layout, area, MeshAssets, false)
		check(#problems == 0, `placeholder area {area.index} invalid:\n  {table.concat(problems, "\n  ")}`)
		check(PlaceholderLayouts.generate(area.index) == layout, `placeholder area {area.index} is cached`)
		-- Pads never overlap each other (7-stud triggers need >= 8 studs between centres).
		local points = {}
		for _, point in layout.pads do
			table.insert(points, point)
		end
		for i = 1, #points do
			for j = i + 1, #points do
				check((points[i] - points[j]).Magnitude >= 8, `area {area.index} pads overlap`)
			end
		end
	end

	-- Validation catches each class of mistake.
	local area3 = TycoonConfig.Areas[3]
	local good = PlaceholderLayouts.generate(3)
	local function mutate(fn: (any) -> ()): { string }
		local copy = table.clone(good) :: any
		copy.builds = table.clone(good.builds)
		copy.pads = table.clone(good.pads)
		fn(copy)
		return LayoutLogic.validate(copy, area3, MeshAssets, false)
	end
	local function has(problems: { string }, needle: string): boolean
		for _, problem in problems do
			if string.find(problem, needle, 1, true) then
				return true
			end
		end
		return false
	end
	check(
		has(
			mutate(function(l)
				l.builds.A3_GPS = nil
			end),
			"builds.A3_GPS: missing"
		),
		"missing build caught"
	)
	check(
		has(
			mutate(function(l)
				l.builds.A4_EntryArch = { models = {} }
			end),
			"builds.A4_EntryArch"
		),
		"EntryArch as a build caught"
	)
	check(
		has(
			mutate(function(l)
				l.pads.a3_gps = Vector3.new(0, 0, 40)
			end),
			"pads.a3_gps"
		),
		"pad outside the strip caught"
	)
	check(
		has(
			mutate(function(l)
				l.builds.A3_GPS = { models = { { key = "NoSuchMesh", cf = CFrame.new(0, 0, 30) } } }
			end),
			"unknown mesh key"
		),
		"unknown mesh key caught"
	)
	check(
		has(
			mutate(function(l)
				l.builds.A3_GPS = { models = { { key = "Workbench", cf = CFrame.new(0, 0, 500) } } }
			end),
			"outside slot"
		),
		"content outside the slot caught"
	)
	check(
		has(
			mutate(function(l)
				l.area = 4
			end),
			"area = 4"
		),
		"wrong area index caught"
	)
	check(
		has(
			mutate(function(l)
				l.spawnPoint = nil
			end),
			"spawnPoint"
		),
		"missing spawn point caught"
	)
	check(#LayoutLogic.validate("nope", area3, nil, false) == 1, "non-table layout caught")

	-- Partial layouts are accepted at runtime and merged with the placeholder.
	local partial = {
		area = 3,
		builds = { A3_GPS = { models = { { key = "Workbench", cf = CFrame.new(0, 0, 30) } } } },
		aaTowerMount = Vector3.new(1, 2, 3),
	}
	check(#LayoutLogic.validate(partial, area3, MeshAssets, true) == 0, "partial layout passes partial validation")
	check(#LayoutLogic.validate(partial, area3, MeshAssets, false) > 0, "partial layout fails strict validation")
	local merged, filled = LayoutLogic.merge(partial, good)
	check(merged.builds.A3_GPS == partial.builds.A3_GPS, "authored build wins")
	check(merged.builds.A3_Scooters == good.builds.A3_Scooters, "missing build filled")
	check(merged.producer == good.producer and #filled > 0, "missing producer filled")
	check((merged :: any).aaTowerMount == partial.aaTowerMount, "extra fields pass through")
	check(#LayoutLogic.validate(merged, area3, MeshAssets, false) == 0, "merged layout is complete")
end

--------------------------------------------------------------------------------------------------
-- Committed art layouts (strict) and HubLayout shape
--------------------------------------------------------------------------------------------------
-- Every file is validated and every problem reported before the suite fails (art lands area by
-- area from several builders; one report shows them all).
local artCount = 0
local artProblems: { string } = {}
for _, area in TycoonConfig.Areas do
	local path = string.format("src/shared/Config/AreaLayouts/Area%02d", area.index)
	if fs.isFile(path .. ".luau") then
		artCount += 1
		local ok, layout = pcall(loader.load, path)
		if not ok then
			table.insert(artProblems, `{path}: failed to load: {layout}`)
			continue
		end
		for _, problem in LayoutLogic.validate(layout, area, MeshAssets, false) do
			table.insert(artProblems, `{path}: {problem}`)
		end
		checks += 1
	end
end
if #artProblems > 0 then
	-- Print every problem first: long assert messages get truncated.
	print(`art layouts break the contract ({#artProblems} problems):`)
	for _, problem in artProblems do
		print("  " .. problem)
	end
end
check(#artProblems == 0, `art layouts break the contract ({#artProblems} problems, listed above)`)
-- HubLayout (optional): the documented shape, and every mesh key it builds must exist (the runtime
-- only adopts HubLayout once ALL of them are synced, World/HubBuilder.layout).
if fs.isFile("src/shared/Config/HubLayout.luau") then
	local ok, hub = pcall(loader.load, "src/shared/Config/HubLayout")
	check(ok and type(hub) == "table", "HubLayout loads as a table")
	local hubProblems: { string } = {}
	local missingKeys: { [string]: boolean } = {}
	local missing = 0
	local function scan(list: any, where: string)
		for index, entry in list or {} do
			if type(entry) ~= "table" or type(entry.key) ~= "string" or typeof(entry.cf) ~= "CFrame" then
				table.insert(hubProblems, `{where}[{index}]: needs key + cf`)
			elseif MeshAssets[entry.key] == nil and not missingKeys[entry.key] then
				missingKeys[entry.key] = true
				missing += 1
			end
		end
	end
	scan(hub.models, "models")
	scan(hub.plotFrame and hub.plotFrame.models, "plotFrame.models")
	scan(hub.lockedSlot and hub.lockedSlot.models, "lockedSlot.models")
	if missing > 0 then
		table.insert(hubProblems, `{missing} mesh key(s) not in MeshAssets yet (run tools/blender/sync_meshes.py)`)
	end
	if hub.spawn ~= nil and typeof(hub.spawn) ~= "CFrame" then
		table.insert(hubProblems, "spawn must be a CFrame")
	end
	-- Owner R134: hubs have no plot teleport pads (HubBuilder builds no plot triggers / portals).
	if hub.anchors ~= nil and hub.anchors.PlotTeleportPads ~= nil then
		table.insert(hubProblems, "anchors.PlotTeleportPads must not exist (owner R134 removed the pads)")
	end
	if #hubProblems > 0 then
		print("HubLayout problems:")
		for _, problem in hubProblems do
			print("  " .. problem)
		end
	end
	check(#hubProblems == 0, `HubLayout breaks the contract ({#hubProblems} problems, listed above)`)
end

--------------------------------------------------------------------------------------------------
-- R57: every non-main world (placeholders, prefixes, art layouts strict / partial)
--------------------------------------------------------------------------------------------------
local worldSummary: { string } = {}
for _, def in WorldsConfig.extra() do
	local worldId = def.id
	local areas = def.economy.Areas
	local buildPrefix = string.upper(def.idPrefix)
	check(#areas == def.geometry.areaCount, `{worldId}: economy areas match the geometry`)
	check(WorldLayout.areaCount(worldId) == #areas, `{worldId}: WorldLayout.areaCount`)

	-- Own build keys: the world's prefix + area number; the finale is an own build.
	for _, area in areas do
		for _, key in LayoutLogic.ownBuildKeys(area) do
			check(
				string.sub(key, 1, #`{buildPrefix}{area.index}_`) == `{buildPrefix}{area.index}_`,
				`{worldId}: own key {key} belongs to area {area.index}`
			)
			check(WorldsConfig.worldOfBuildKey(key) == worldId, `{worldId}: build key {key} resolves to its world`)
		end
	end

	-- Placeholders: complete + valid against this world's geometry, cached per world, distinct
	-- from Nuke Town's (same area index, different world).
	for _, area in areas do
		local layout = PlaceholderLayouts.generate(area.index, worldId)
		local problems = LayoutLogic.validate(layout, area, MeshAssets, false, worldId)
		check(#problems == 0, `{worldId} placeholder area {area.index} invalid:\n  {table.concat(problems, "\n  ")}`)
		check(PlaceholderLayouts.generate(area.index, worldId) == layout, `{worldId} placeholder {area.index} cached`)
		check(PlaceholderLayouts.generate(area.index) ~= layout, `{worldId} placeholder {area.index} is its own`)
		local points = {}
		for _, point in layout.pads do
			table.insert(points, point)
		end
		for i = 1, #points do
			for j = i + 1, #points do
				check((points[i] - points[j]).Magnitude >= 8, `{worldId} area {area.index} pads overlap`)
			end
		end
	end

	-- The finale slot's height budget is the world's (content at y = 120 fits D6, not D5).
	local finale = def.geometry.finaleArea
	local tall = { models = { { box = Vector3.new(2, 2, 2), cf = CFrame.new(0, 120, 30) } } }
	local finaleLayout = table.clone(PlaceholderLayouts.generate(finale, worldId)) :: any
	finaleLayout.base = tall
	check(
		#LayoutLogic.validate(finaleLayout, areas[finale], nil, false, worldId) == 0,
		`{worldId}: the finale slot allows {def.geometry.finaleHeight} studs`
	)
	if finale > 1 then
		local lower = table.clone(PlaceholderLayouts.generate(finale - 1, worldId)) :: any
		lower.base = tall
		check(
			#LayoutLogic.validate(lower, areas[finale - 1], nil, false, worldId) > 0,
			`{worldId}: a non-finale slot keeps the 80-stud budget`
		)
	end

	-- Art layouts: strict once every area has a file, partial (still shape / bounds / ids / mesh
	-- keys) while art is landing.
	local folder = "src/shared/Config/" .. table.concat(def.layoutFolder, "/")
	local present: { number } = {}
	for _, area in areas do
		if fs.isFile(string.format("%s/Area%02d.luau", folder, area.index)) then
			table.insert(present, area.index)
		end
	end
	local strict = #present == #areas
	local problems: { string } = {}
	for _, index in present do
		local path = string.format("%s/Area%02d", folder, index)
		local ok, layout = pcall(loader.load, path)
		if not ok then
			table.insert(problems, `{path}: failed to load: {layout}`)
			continue
		end
		for _, problem in LayoutLogic.validate(layout, areas[index], MeshAssets, not strict, worldId) do
			table.insert(problems, `{path}: {problem}`)
		end
		checks += 1
	end
	if #problems > 0 then
		print(`{worldId} art layouts break the contract ({#problems} problems):`)
		for _, problem in problems do
			print("  " .. problem)
		end
	end
	check(#problems == 0, `{worldId} art layouts break the contract ({#problems} problems, listed above)`)
	table.insert(worldSummary, `{worldId}: {#present}/{#areas} art file(s), {if strict then "strict" else "partial"}`)
end

print(
	`area-layouts: {checks} checks passed ({artCount} art layout file(s), the rest use placeholders; `
		.. `{table.concat(worldSummary, "; ")})`
)
