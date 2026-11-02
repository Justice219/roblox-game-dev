--!strict
--[[
	TutorialArrows — a trail of yellow chevron arrows on the ground that flows from the player
	toward the tutorial target (owner rule R27: "instead of a line to where the player needs to
	go, make like a little arrow effect").

	Look: `Count` chevrons, each a "V" of two neon arms (pointing along the path), spaced
	`Spacing` studs apart on the straight path from the character to the target, raycast-snapped
	to the ground, sliding forward at `Speed` studs / s and wrapping (a continuous "this way"
	flow). They fade in just in front of the character and fade out over the last `FadeNear`
	studs; within `HideWithin` studs they hide (the HUD's bouncing arrow over the target stays).
	Reduce Motion: the same chevrons, static.

	Performance: the chevrons are built ONCE (2 parts each, client-only, CanQuery / CanTouch /
	CanCollide off, no shadows) and parked when unused. One PreRender connection, alive only while
	a target is set, moves every arm with a single Workspace:BulkMoveTo per frame (+ one ground
	raycast per chevron). No Instance.new per frame.

	Goal (owner R84): a BasePart (pad trigger / producer anchor) or an Attachment (the producer
	billboard's spot, on the walkway side of the producer where its UPGRADE / make controls are);
	only its horizontal position matters (the chevrons are ground-snapped).

	Connects to: Tycoon/Tutorial (setTarget / clear), Shared/Config/TycoonClientConfig
	(TutorialArrows), Widgets/OfferFx (reduced motion).

	Example:
		TutorialArrows.setTarget(padPart)
		TutorialArrows.clear()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)

local Config = TycoonClientConfig.TutorialArrows

local TutorialArrows = {}

-- Far below the world: where unused arms park (one BulkMoveTo, never destroyed).
local PARK = CFrame.new(0, -10000, 0)

local folder: Folder? = nil
local arms: { BasePart } = {}
-- The trail's goal: a pad trigger / producer part, or (owner R84) the producer billboard's
-- spot Attachment (the walkway side of the producer, where its UPGRADE / make controls are).
local target: (BasePart | Attachment)? = nil
local connection: RBXScriptConnection? = nil
local clock = 0
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
-- Reused per frame (no table allocation in the loop).
local cframes: { CFrame } = {}

-- Builds the pooled arms once.
local function ensureParts()
	if folder ~= nil then
		return
	end
	local created = Instance.new("Folder")
	created.Name = "TutorialArrows"
	for index = 1, Config.Count * 2 do
		local arm = Instance.new("Part")
		arm.Name = `Arm{index}`
		arm.Anchored = true
		arm.CanCollide = false
		arm.CanQuery = false
		arm.CanTouch = false
		arm.CastShadow = false
		arm.Material = Enum.Material.Neon
		arm.Color = Config.Color
		arm.Transparency = 1
		arm.Size = Vector3.new(Config.ArmWidth, Config.ArmHeight, Config.ArmLength)
		arm.CFrame = PARK
		arm.Parent = created
		table.insert(arms, arm)
		table.insert(cframes, PARK)
	end
	created.Parent = Workspace
	folder = created
end

-- Parks every arm (invisible, far away).
local function park()
	for index, arm in arms do
		cframes[index] = PARK
		arm.Transparency = 1
	end
	if #arms > 0 then
		Workspace:BulkMoveTo(arms, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Ground height below `position` (falls back to the given height).
local function groundY(position: Vector3, fallback: number): number
	local hit = Workspace:Raycast(position + Vector3.new(0, 8, 0), Vector3.new(0, -30, 0), rayParams)
	return if hit ~= nil then hit.Position.Y else fallback
end

-- World position of the trail's goal (nil once it left the world).
local function goalPosition(goal: BasePart | Attachment): Vector3?
	if goal.Parent == nil then
		return nil
	end
	if goal:IsA("Attachment") then
		return goal.WorldPosition
	end
	return (goal :: BasePart).Position
end

-- One frame: lay the chevrons along the path from the character to the target.
local function step(dt: number)
	local goal = target
	local character = Players.LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	local to = if goal ~= nil then goalPosition(goal) else nil
	if to == nil or root == nil or not root:IsA("BasePart") then
		park()
		return
	end
	local from = root.Position
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local distance = flat.Magnitude
	if distance <= Config.HideWithin then
		park()
		return
	end
	local direction = flat / distance
	if not OfferFx.reducedMotion() then
		clock += dt
	end
	-- The whole trail slides forward and wraps by one spacing (a continuous flow).
	local shift = (clock * Config.Speed) % Config.Spacing
	local feetY = from.Y - 3
	local yaw = math.atan2(-direction.X, -direction.Z)
	local lean = math.rad(Config.ArmAngle)
	local halfLength = Config.ArmLength / 2
	-- Ground rays ignore the character and the arrows themselves.
	rayParams.FilterDescendantsInstances = { character :: Instance, folder :: Instance }
	for chevron = 1, Config.Count do
		local along = Config.StartGap + (chevron - 1) * Config.Spacing + shift
		local leftArm, rightArm = arms[chevron * 2 - 1], arms[chevron * 2]
		local remaining = distance - along
		if remaining <= 0.5 then
			cframes[chevron * 2 - 1], cframes[chevron * 2] = PARK, PARK
			leftArm.Transparency, rightArm.Transparency = 1, 1
		else
			-- Fade in at the start, out over the last FadeNear studs.
			local fadeIn = math.clamp((along - Config.StartGap) / Config.Spacing, 0, 1)
			local fadeOut = math.clamp(remaining / Config.FadeNear, 0, 1)
			local visible = fadeIn * fadeOut
			local transparency = 1 - (1 - Config.Transparency) * visible
			local tip = from + direction * along
			local y = groundY(tip, feetY) + Config.Hover + Config.ArmHeight / 2
			local base = CFrame.new(tip.X, y, tip.Z) * CFrame.Angles(0, yaw, 0)
			-- Each arm leans back from the tip (the chevron points along the path).
			cframes[chevron * 2 - 1] = base * CFrame.Angles(0, lean, 0) * CFrame.new(0, 0, halfLength)
			cframes[chevron * 2] = base * CFrame.Angles(0, -lean, 0) * CFrame.new(0, 0, halfLength)
			leftArm.Transparency, rightArm.Transparency = transparency, transparency
		end
	end
	Workspace:BulkMoveTo(arms, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

--[[
	Shows the arrow trail toward `part` (nil hides it).
	@param part the tutorial target (pad trigger / producer anchor), or the producer billboard's
	            spot Attachment (owner R84: the trail leads to the button to press)
]]
function TutorialArrows.setTarget(part: (BasePart | Attachment)?)
	target = part
	if part == nil then
		if connection ~= nil then
			connection:Disconnect()
			connection = nil
		end
		park()
		return
	end
	ensureParts()
	if connection == nil then
		connection = RunService.PreRender:Connect(step)
	end
end

--[[ Hides the trail and stops its loop. ]]
function TutorialArrows.clear()
	TutorialArrows.setTarget(nil)
end

return TutorialArrows
