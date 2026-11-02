--!strict
--[[
	spawn_area07.luau — EDIT-MODE art check for Area 7 "Launch Silos": spawns the area exactly as the
	plot builder will (src/shared/Config/AreaLayouts/Area07.luau through the real MeshLibrary +
	WorldMaterials), in its true slot of a preview plot far from the play area, with a stand-in road.

	Knobs (edit, or let a wrapper rewrite the lines):
		STAGE           number of the area's pads bought, in buy order (0 = base only, nil = all).
		                Remaining pads show as BuyPads tinted by kind so the pad-by-pad growth reads.
		SHOW_COLLISION  true = translucent red boxes for every collision entry, blue = producer click
		                box, a yellow ball on the billboard anchor, green balls on attack launch points,
		                magenta = AA tower mount, orange = attack-console prompt.

	Run (Studio open, Rojo synced; hold the Studio lock):
		python3 scripts/studio-lock.py acquire B8c
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/spawn_area07.luau
		python3 tools/blender/studio_shot.py docs/verification/world-art/area07-x.jpg --luau <camera.luau>
		python3 scripts/studio_mcp.py luau-file tools/blender/studio/cleanup_preview.luau   # ALWAYS
		python3 scripts/studio-lock.py release B8c

	The preview plot origin is PREVIEW_PLOT; areas share it so spawn_area08.luau lands across the
	road (each area lives in its own sub-folder of SN_ArtPreview and only replaces that).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AREA = 7
local STAGE: number? = nil
local SHOW_COLLISION = false
local PREVIEW_PLOT = CFrame.new(-4000, 0, 4000)
local FOLDER_NAME = "SN_ArtPreview"

-- Pad kind -> BuyPad top colour (same pad colour language as the other area previews).
local PAD_COLOURS: { [string]: Color3 } = {
	Build = Color3.fromRGB(98, 204, 70),
	Multiplier = Color3.fromRGB(255, 206, 36),
	Speed = Color3.fromRGB(96, 168, 236),
	Manager = Color3.fromRGB(150, 96, 220),
	Unlock = Color3.fromRGB(255, 146, 40),
	Feature = Color3.fromRGB(232, 64, 56),
}

local World = ServerScriptService:WaitForChild("Server"):WaitForChild("World")
local MeshLibrary = (require :: any)(World:WaitForChild("MeshLibrary"))
local WorldMaterials = (require :: any)(World:WaitForChild("WorldMaterials"))
local Config = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local WorldLayout = (require :: any)(Config:WaitForChild("WorldLayout"))
local TycoonConfig = (require :: any)(Config:WaitForChild("TycoonConfig"))
-- Fail fast (instead of WaitForChild hanging the MCP call) when Rojo has not synced the layout.
local layoutsFolder = Config:FindFirstChild("AreaLayouts")
assert(layoutsFolder, "ReplicatedStorage.Shared.Config.AreaLayouts missing: is rojo serve connected?")
local layoutModule = layoutsFolder:FindFirstChild(string.format("Area%02d", AREA))
assert(layoutModule and layoutModule:IsA("ModuleScript"), string.format("AreaLayouts.Area%02d not synced", AREA))
-- Clone before requiring: edit-mode `require` caches by instance, so a fresh clone always picks up
-- the layout Rojo just synced (the layout module has no relative requires).
local Layout = (require :: any)(layoutModule:Clone())

-- Preview root + this area's own sub-folder (re-running replaces only this area).
local root = workspace:FindFirstChild(FOLDER_NAME)
if not root then
	root = Instance.new("Folder")
	root.Name = FOLDER_NAME
	root.Parent = workspace
end
local areaName = string.format("Area%02d", AREA)
local old = root:FindFirstChild(areaName)
if old then
	old:Destroy()
end
local folder = Instance.new("Folder")
folder.Name = areaName
folder.Parent = root

local installed = WorldMaterials.ensure()
local slot = PREVIEW_PLOT * WorldLayout.slotLocal(AREA)

-- Stand-in road (plot road x in [-8, 8]) along this row so the slot reads in context.
if not root:FindFirstChild("Road") then
	local row = math.ceil(AREA / 2)
	local road = Instance.new("Part")
	road.Name = "Road"
	road.Anchored = true
	road.Size = Vector3.new(WorldLayout.RoadHalfWidth * 2 + 4, 0.4, WorldLayout.RowLength + 40)
	road.CFrame = PREVIEW_PLOT * CFrame.new(0, -0.2, (row - 0.5) * WorldLayout.RowLength)
	road.Color = Color3.fromRGB(78, 82, 98)
	WorldMaterials.apply(road, "StudsLarge")
	road.Parent = root
end

-- Build keys in buy order; the area's Unlock pad builds the NEXT area's base (not shown here).
local area = TycoonConfig.Areas[AREA]
local ordered: { { id: string, kind: string, build: string?, unlock: boolean } } = {}
for _, pad in area.pads do
	table.insert(ordered, {
		id = pad.id,
		kind = pad.kind,
		build = pad.build,
		unlock = pad.kind == "Unlock" and pad.unlocks ~= nil,
	})
end
local stage = STAGE or #ordered

-- Collect every mesh key we will spawn and preload them in one batch.
local groups = { Layout.base }
for i = 1, math.min(stage, #ordered) do
	local entry = ordered[i]
	if not entry.unlock and entry.build and Layout.builds[entry.build] then
		table.insert(groups, Layout.builds[entry.build])
	end
end
local keySet: { [string]: boolean } = { BuyPad = true }
for _, group in groups do
	for _, model in group.models do
		keySet[model.key] = true
	end
end
local keys = {}
for key in keySet do
	table.insert(keys, key)
end
local started = os.clock()
local ready, failed = MeshLibrary.preload(keys)
local loadSeconds = os.clock() - started

local function debugBox(size: Vector3, cf: CFrame, color: Color3, name: string)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.Size = size
	part.CFrame = slot * cf
	part.Color = color
	part.Material = Enum.Material.ForceField
	part.Transparency = 0.35
	part.Parent = folder
end

local function debugBall(point: Vector3, color: Color3, name: string)
	local ball = Instance.new("Part")
	ball.Name = name
	ball.Shape = Enum.PartType.Ball
	ball.Anchored = true
	ball.CanCollide = false
	ball.Size = Vector3.new(1.6, 1.6, 1.6)
	ball.CFrame = slot * CFrame.new(point)
	ball.Color = color
	ball.Material = Enum.Material.Neon
	ball.Parent = folder
end

local spawned = 0
for _, group in groups do
	for _, model in group.models do
		MeshLibrary.spawn(model.key, folder, slot * model.cf)
		spawned += 1
	end
	if SHOW_COLLISION then
		for index, box in group.collision or {} do
			debugBox(box.size, box.cf, Color3.fromRGB(255, 60, 60), "Collision" .. index)
		end
	end
end

-- Remaining pads as BuyPads tinted by kind (bought ones are gone, like in game).
for i = stage + 1, #ordered do
	local point = Layout.pads[ordered[i].id]
	if point then
		MeshLibrary.spawn(
			"BuyPad",
			folder,
			slot * CFrame.new(point),
			{ tint = PAD_COLOURS[ordered[i].kind] or PAD_COLOURS.Build }
		)
	end
end

if SHOW_COLLISION then
	debugBox(Layout.producer.click.size, Layout.producer.click.cf, Color3.fromRGB(60, 120, 255), "ProducerClick")
	debugBall(Layout.producer.anchor, Color3.fromRGB(255, 220, 40), "ProducerAnchor")
	-- Attack-mode points (Area 7 only): launch frames are CFrames, the AA mount a CFrame.
	for index, frame in Layout.launchPoints or {} do
		debugBall(frame.Position, Color3.fromRGB(80, 255, 120), "LaunchPoint" .. index)
	end
	if Layout.aaTowerMount then
		debugBall(Layout.aaTowerMount.Position, Color3.fromRGB(255, 120, 255), "AATowerMount")
	end
	if Layout.consolePrompt then
		debugBall(Layout.consolePrompt, Color3.fromRGB(255, 160, 40), "ConsolePrompt")
	end
	debugBall(Layout.spawnPoint, Color3.fromRGB(255, 255, 255), "SpawnPoint")
end

local meshes, fallbacks = 0, 0
for _, item in folder:GetChildren() do
	if item:IsA("Model") then
		if item:GetAttribute("MeshSource") == "Mesh" then
			meshes += 1
		else
			fallbacks += 1
		end
	end
end
return string.format(
	"area %d stage %d/%d: variants=%s preload ready=%d failed=%d in %.2fs; models=%d (mesh %d, fallback %d)",
	AREA,
	stage,
	#ordered,
	tostring(installed),
	ready,
	failed,
	loadSeconds,
	spawned,
	meshes,
	fallbacks
)
