--!strict
--[[
	TrailRenderer — shows each player's equipped cosmetic trail (CrateConfig.Trails) behind their
	character: two Attachments on the HumanoidRootPart + one Trail, created by the SERVER so every
	client sees it with zero client code and zero remote traffic.

	Lifecycle: `apply(player, trailId)` is called by CrateService when the profile loads, after an
	EquipTrail / a crate trail reward, and on every CharacterAdded. It reuses the existing Trail
	when the id is unchanged, replaces it when it changed, and removes it for "". Instances live
	under the root part, so they die with the character (no cleanup needed on death / leave).

	Performance: one Trail per player at most (8 per server), engine-rendered; nothing per frame.

	Connects to: Shared/Config/CrateConfig (trail looks), Server/Services/CrateService.

	Example:
		TrailRenderer.apply(player, "trail_rainbow")
		TrailRenderer.apply(player, "") -- removes it
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)

local TrailRenderer = {}

local TRAIL_NAME = "SNTrail"
local ATTACH_TOP = "SNTrailTop"
local ATTACH_BOTTOM = "SNTrailBottom"

-- A ColorSequence spreading `colors` evenly along the trail.
local function sequence(colors: { Color3 }): ColorSequence
	local keypoints: { ColorSequenceKeypoint } = {}
	for index, color in colors do
		local t = if #colors == 1 then 0 else (index - 1) / (#colors - 1)
		table.insert(keypoints, ColorSequenceKeypoint.new(t, color))
	end
	if #keypoints == 1 then
		table.insert(keypoints, ColorSequenceKeypoint.new(1, colors[1]))
	end
	return ColorSequence.new(keypoints)
end

-- Removes the trail instances from a root part.
local function clear(root: BasePart)
	for _, name in { TRAIL_NAME, ATTACH_TOP, ATTACH_BOTTOM } do
		local child = root:FindFirstChild(name)
		if child ~= nil then
			child:Destroy()
		end
	end
end

--[[
	Shows `trailId` on the player's current character ("" or unknown → none). Never yields.
]]
function TrailRenderer.apply(player: Player, trailId: string)
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return
	end
	local def = CrateConfig.getTrail(trailId)
	local existing = root:FindFirstChild(TRAIL_NAME)
	if def == nil then
		clear(root)
		return
	end
	if existing ~= nil and existing:GetAttribute("TrailId") == def.id then
		return
	end
	clear(root)
	local top = Instance.new("Attachment")
	top.Name = ATTACH_TOP
	top.Position = Vector3.new(0, def.width / 2, 0.4)
	top.Parent = root
	local bottom = Instance.new("Attachment")
	bottom.Name = ATTACH_BOTTOM
	bottom.Position = Vector3.new(0, -def.width / 2, 0.4)
	bottom.Parent = root
	local trail = Instance.new("Trail")
	trail.Name = TRAIL_NAME
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Color = sequence(def.colors)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.7, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime = def.lifetime
	trail.LightEmission = def.lightEmission
	trail.MinLength = 0.1
	trail.FaceCamera = true
	trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.3) })
	trail:SetAttribute("TrailId", def.id)
	trail.Parent = root
end

return table.freeze(TrailRenderer)
