--!strict
--[[
	RivalLayout — the pure "what stands on a Rival Factory island" list (owner R43), in
	island-local space (AttackConfig.Rivals: the island frame IS a WorldLayout slot, so an area
	layout drops in unchanged). No Instances: Server/Attack/RivalIslands spawns exactly this list
	through MeshLibrary, and tests/attack-rivals.luau checks it (every key exists in MeshAssets,
	everything stays on the island and clear of the hub / plots / other islands).

	An island =
		* a FULLY built area set: AreaLayouts/AreaNN `base` + every `builds` group (sorted build keys,
		  so every server builds the islands identically), minus Rivals.SkipKeys (entry arches; the
		  AA plinth, placed at the rival's own `tower` spot instead);
		* the A7_AATower plinth at `tower` (the levelled AATowerN turret is an AttackWorld object);
		* the entrance sign arch (Rivals.SignKey) at the front, carrying the rival's name;
		* the scenery dressing (Rivals.Dressing: sunk hills, shore rocks, pines).
	Every placement carries its `section` (owner R50 knockdown): RivalIslands groups the models of
	section i into a "Section<i>" Model (Builds folder) that Knockdown.knockInstance topples.

	Connects to: Shared/Config/{AttackConfig, AreaLayouts/*}, Server/Attack/RivalIslands,
	tests/attack-rivals.luau.

	Example:
		local layout = require(ReplicatedStorage.Shared.Config.AreaLayouts.Area06)
		for _, placement in RivalLayout.island(1, layout) do
			MeshLibrary.spawn(placement.key, folder, AttackGeometry.rivalFrame(1) * placement.cf)
		end
]]

local AttackConfig = require(script.Parent.Parent.Config.AttackConfig)

local RivalLayout = {}

-- `section` (owner R50): the Rival section (1..#Rivals.Sections) whose knockdown topples this
-- model, or 0 for static pieces (floors, the AA plinth, the sign arch, the dressing).
export type Placement = { key: string, cf: CFrame, section: number }

local RIVALS = AttackConfig.Rivals

--[[
	Every model placement of a FULLY built area layout (its `base` plus every `builds` group),
	minus Rivals.SkipKeys and malformed entries.
	@param layout any — an AreaLayouts module table (anything else → empty list)
	@return { Placement } — island-local (= slot-local) placements
	Example: RivalLayout.areaSet(require(AreaLayouts.Area06)) --> { {key = "A6_Floor", cf = ...}, ... }
]]
function RivalLayout.areaSet(layout: any): { Placement }
	local list: { Placement } = {}
	if type(layout) ~= "table" then
		return list
	end
	local function addGroup(group: any)
		if type(group) ~= "table" or type(group.models) ~= "table" then
			return
		end
		for _, entry in group.models do
			if
				type(entry) == "table"
				and type(entry.key) == "string"
				and typeof(entry.cf) == "CFrame"
				and RIVALS.SkipKeys[entry.key] ~= true
			then
				table.insert(
					list,
					{ key = entry.key, cf = entry.cf, section = RivalLayout.sectionOf(entry.key, entry.cf) }
				)
			end
		end
	end
	addGroup(layout.base)
	if type(layout.builds) == "table" then
		local keys: { string } = {}
		for key in layout.builds do
			if type(key) == "string" then
				table.insert(keys, key)
			end
		end
		table.sort(keys)
		for _, key in keys do
			addGroup(layout.builds[key])
		end
	end
	return list
end

--[[
	Every placement of Rival Factory `index`'s island (island-local): the area set, the AA plinth,
	the entrance sign and the dressing.
	@param index number — 1..#Rivals.List
	@param layout any? — the rival's AreaLayouts table (nil = only plinth, sign and dressing)
	@return { Placement }
]]
function RivalLayout.island(index: number, layout: any?): { Placement }
	local rival = assert(RIVALS.List[index], "RivalLayout: bad rival")
	local list = RivalLayout.areaSet(layout)
	table.insert(list, { key = "A7_AATower", cf = CFrame.new(rival.tower), section = 0 })
	table.insert(list, { key = RIVALS.SignKey, cf = CFrame.new(0, rival.floor, RIVALS.SignZ), section = 0 })
	for _, dressing in RIVALS.Dressing do
		table.insert(list, { key = dressing.key, cf = dressing.cf, section = 0 })
	end
	return list
end

--[[
	The section an area-set model belongs to (owner R50): floors (Rivals.KeepKeys) are static (0);
	everything else belongs to the section strip containing its pivot (island-local).
	@param key string, cf CFrame
	@return number — 0 or 1..#Rivals.Sections
	Example: RivalLayout.sectionOf("A6_LoadingDock", CFrame.new(37, 0.4, 63)) --> 4 (right strip)
]]
function RivalLayout.sectionOf(key: string, cf: CFrame): number
	if RIVALS.KeepKeys[key] == true then
		return 0
	end
	local p = cf.Position
	local best, bestDistance = 1, math.huge
	for index, section in RIVALS.Sections do
		-- Inside the strip wins; otherwise the nearest section centre (models outside the base).
		local dx, dz = math.abs(p.X - section.centre.X), math.abs(p.Z - section.centre.Z)
		-- Half-open strips [lo, hi) (the last one closed), so a model on a seam (x = 0, the base's
		-- centre line) belongs to exactly one section: the one on its right.
		local lo, hi = section.centre.X - section.half.X, section.centre.X + section.half.X
		if p.X >= lo and (p.X < hi or (index == #RIVALS.Sections and p.X <= hi)) and dz <= section.half.Z then
			return index
		end
		local distance = dx + dz
		if distance < bestDistance then
			best, bestDistance = index, distance
		end
	end
	return best
end

return RivalLayout
