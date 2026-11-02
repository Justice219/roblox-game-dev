--!strict
--[[
	RivalIslands — builds the Rival Factory islands (owner R43 "i have the silos but i cannot attack
	anyone"): 3-4 cartoon rival bases on islands just off the map edge that every player can nuke
	at any time, so Attack mode works solo and in early servers.

	What one island is (all EXISTING Blender sets through MeshLibrary, owner rule 3; the pure list
	is Shared/Attack/RivalLayout.island):
		* the base: a FULLY BUILT area set from AreaLayouts/AreaNN (base + every pad build, minus
		  AttackConfig.Rivals.SkipKeys: entry arches and the AA plinth), dropped into the island-local
		  frame unchanged — the island frame IS a WorldLayout slot (AttackConfig.Rivals);
		* an A7_AATower plinth at the rival's `tower` spot (its levelled AATowerN turret and the
		  shield dome are AttackWorld objects, driven by DefenseService);
		* a Plot_EntranceArch at the front with the rival's name on its OwnerSign panels;
		* scenery dressing (sunk hills, shore rocks, pines) so the base reads as an island.

	Instances: Workspace.<Rivals.Folder>.<rival id> (Folder, attributes RivalId / RivalIndex /
	Slot) holding `Island` (the static models) and `Attack` (AttackWorld: turret + dome). Static and
	streamed: every model is Atomic (MeshLibrary default), anchored, visual only (no collision is
	needed: the islands are outside the boundary ring), and nothing here ever changes after the
	build — zero per-frame or per-player cost.

	Boot cost: the island templates are preloaded at MeshLibrary.Priority.Idle BEFORE spawning, so
	the build never competes with the hub, a joining player's plot or a purchase, and never holds
	back Workspace.WorldReady.

	Security: server-only; keys come from config / area layouts, never from a client.

	Connects to: Shared/Config/{AttackConfig, AreaLayouts/*}, Shared/Attack/{AttackGeometry, RivalLayout},
	Shared/World/MeshPlacement, World/MeshLibrary, Attack/AttackWorld (finds the `Attack` folder),
	Services/DefenseService (calls start(), then shows turrets / domes), tests/attack-rivals.luau.

	Example (DefenseService.Start):
		RivalIslands.start()            -- folders now, meshes in the background
		local folder = RivalIslands.folder(1)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local MeshLibrary = require(script.Parent.Parent.World.MeshLibrary)
local MeshPlacement = require(ReplicatedStorage.Shared.World.MeshPlacement)
local RivalLayout = require(ReplicatedStorage.Shared.Attack.RivalLayout)

local RivalIslands = {}

local RIVALS = AttackConfig.Rivals
-- Sign text look (matches PlotBuilder's owner signs: FredokaOne, white, thick dark outline).
local SIGN_OUTLINE = Color3.fromRGB(30, 34, 52)
local SIGN_PIXELS_PER_STUD = 40

local started = false

--[[
	The AreaLayouts module table of `area` (guarded: a missing / broken layout → nil, the island is
	then built from its dressing, plinth and sign only).
	@param area number
	@return table?
]]
local function layoutOf(area: number): any?
	local ok, result = pcall(function(): any
		local folder = ReplicatedStorage.Shared.Config:FindFirstChild("AreaLayouts")
		local module = if folder ~= nil then folder:FindFirstChild(string.format("Area%02d", area)) else nil
		if module == nil or not module:IsA("ModuleScript") then
			return nil
		end
		return require(module) :: any
	end)
	return if ok and type(result) == "table" then result else nil
end

--[[
	The island's container folder Workspace.<Rivals.Folder>.<id> (created on first use).
	@param index number — 1..#Rivals.List
	@return Folder
]]
function RivalIslands.folder(index: number): Folder
	local rival = assert(RIVALS.List[index], "RivalIslands: bad rival")
	local root = Workspace:FindFirstChild(RIVALS.Folder)
	if root == nil then
		local created = Instance.new("Folder")
		created.Name = RIVALS.Folder
		created.Parent = Workspace
		root = created
	end
	local existing = (root :: Instance):FindFirstChild(rival.id)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = rival.id
	folder:SetAttribute("RivalId", rival.id)
	folder:SetAttribute("RivalIndex", index)
	folder:SetAttribute("Slot", AttackGeometry.rivalSlot(index))
	folder.Parent = root
	return folder
end

-- A big friendly name label on one MODEL side of the sign piece (PlotBuilder's owner-sign look).
local function signLabel(part: BasePart, face: Enum.NormalId, text: string)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label" .. face.Name
	gui.Face = MeshPlacement.face(part, face)
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = SIGN_PIXELS_PER_STUD
	gui.LightInfluence = 0.2
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 1
	label.Text = text
	local stroke = Instance.new("UIStroke")
	stroke.Color = SIGN_OUTLINE
	stroke.Thickness = 6
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	label.Parent = gui
	gui.Parent = part
end

-- Builds one island (yields while its templates load at Idle priority).
local function buildIsland(index: number)
	local rival = RIVALS.List[index]
	local container = RivalIslands.folder(index)
	if container:FindFirstChild("Island") ~= nil then
		return
	end
	local frame = AttackGeometry.rivalFrame(index)
	local placements = RivalLayout.island(index, layoutOf(rival.area))
	local keys: { string } = {}
	for _, placement in placements do
		if MeshLibrary.has(placement.key) then
			table.insert(keys, placement.key)
		end
	end
	MeshLibrary.preload(keys, MeshLibrary.Priority.Idle)
	-- Built unparented, parented once complete (one replication burst per island):
	--   Island/Static              floors, plinth, sign, dressing (never topple)
	--   Island/Section<i> (Model)  owner R50: section i's builds under "Builds" — the Model
	--                              Knockdown.knockInstance topples and rebuilds (Q3's FX)
	local island = Instance.new("Folder")
	island.Name = "Island"
	local static = Instance.new("Folder")
	static.Name = "Static"
	static.Parent = island
	local sections: { Model } = {}
	for sectionIndex, section in RIVALS.Sections do
		local model = Instance.new("Model")
		model.Name = `Section{sectionIndex}`
		model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		model.WorldPivot = frame * CFrame.new(section.centre.X, rival.floor, section.centre.Z)
		model:SetAttribute("RivalIndex", index)
		model:SetAttribute("SectionIndex", sectionIndex)
		local builds = Instance.new("Folder")
		builds.Name = "Builds"
		builds.Parent = model
		model.Parent = island
		sections[sectionIndex] = model
	end
	for order, placement in placements do
		if not MeshLibrary.has(placement.key) then
			continue
		end
		local section = sections[placement.section]
		local parent: Instance = if section ~= nil then section:FindFirstChild("Builds") :: Instance else static
		local isSign = placement.key == RIVALS.SignKey
		local model = MeshLibrary.spawn(placement.key, parent, frame * placement.cf, {
			tint = if isSign then rival.color else nil,
			name = if isSign then "Sign" else `{placement.key}_{order}`,
		})
		if isSign then
			local piece = model:FindFirstChild(RIVALS.SignPiece)
			if piece ~= nil and piece:IsA("BasePart") then
				signLabel(piece, Enum.NormalId.Front, rival.name)
				signLabel(piece, Enum.NormalId.Back, rival.name)
			end
		end
	end
	island.Parent = container
end

--[[
	Rival `index`'s section Model `section` (owner R50 knockdown target), or nil while the island is
	still building.
	@param index number, section number
	@return Model?
]]
function RivalIslands.section(index: number, section: number): Model?
	local rival = RIVALS.List[index]
	local root = if rival ~= nil then Workspace:FindFirstChild(RIVALS.Folder) else nil
	local folder = if root ~= nil and rival ~= nil then root:FindFirstChild(rival.id) else nil
	local island = if folder ~= nil then folder:FindFirstChild("Island") else nil
	local model = if island ~= nil then island:FindFirstChild(`Section{section}`) else nil
	return if model ~= nil and model:IsA("Model") then model else nil
end

--[[
	Creates every island folder at once (AttackWorld can place turrets / domes immediately), then
	builds the islands one after another in the background. Idempotent.
]]
function RivalIslands.start()
	if started then
		return
	end
	started = true
	for index in RIVALS.List do
		RivalIslands.folder(index)
	end
	task.spawn(function()
		for index in RIVALS.List do
			local ok, err = pcall(buildIsland, index)
			if not ok then
				warn(`[RivalIslands] island {index} failed: {err}`)
			end
		end
	end)
end

return RivalIslands
