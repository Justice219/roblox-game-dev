--!nocheck
--[[
	r96_feast_client.luau — client-VM probe for the owner R96 (Golden Turkey ON the ground) + R97
	(3 free starter stickers) QA, run by tools/qa/r96_feast.py through eval_client_runtime during
	ONE solo playtest.

		COMMAND  "diag"     HUD shown, profile loaded, the client's sticker count
		         "probe"    every rendered turkey in Workspace.HarvestTurkeys: its id, the bottom of
		                    its VISUAL parts (hitbox left out), the walkable ground under it (one ray,
		                    RespectCanCollide, characters + turkeys excluded), gap = bottom - ground,
		                    the Catch! prompt's world height and its parent; `ok` when every turkey
		                    stands within the waddle bob of the ground and its prompt is above it
		         "camera"   Scriptable camera from eye (ARGS 1-3) to target (ARGS 4-6)
		         "free"     camera back to Custom (the player's normal camera)
		         "sheet"    closes every modal and opens the Feast Sticker Sheet ("HarvestFeast")
		         "close"    closes every modal
	Presentation / measurement only: every grant and spawn goes through the server seams.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local COMMAND = "__COMMAND__"
local ARGS = { --[[ARGS]] }

local LOCAL = Players.LocalPlayer
local client = LOCAL:WaitForChild("PlayerScripts"):WaitForChild("Client")
local ClientState = require(client.ClientState)
local ScreenManager = require(client.UI.ScreenManager)

-- The waddle bob is at most 0.28 studs; the ground follow eases over a few frames.
local GAP_TOLERANCE = 0.4
-- The Catch! prompt must float at least this high above the ground (over the head).
local PROMPT_MIN_HEIGHT = 2

-- Lowest world y of a part's oriented box (its 8 corners).
local function partBottom(part: BasePart): number
	local cf, half = part.CFrame, part.Size / 2
	local reach = math.abs(cf.RightVector.Y) * half.X
		+ math.abs(cf.UpVector.Y) * half.Y
		+ math.abs(cf.LookVector.Y) * half.Z
	return cf.Position.Y - reach
end

local function probe(): { [string]: any }
	local folder = Workspace:FindFirstChild("HarvestTurkeys")
	local exclude = { folder }
	for _, player in Players:GetPlayers() do
		if player.Character ~= nil then
			table.insert(exclude, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true
	local rows = {}
	local ok = true
	for _, model in (if folder ~= nil then folder:GetChildren() else {}) do
		if not model:IsA("Model") then
			continue
		end
		local bottom = math.huge
		local centre = Vector3.zero
		local count = 0
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") and part.Name ~= "Hitbox" then
				bottom = math.min(bottom, partBottom(part))
				centre += part.Position
				count += 1
			end
		end
		if count == 0 then
			continue
		end
		centre /= count
		local hit = Workspace:Raycast(Vector3.new(centre.X, bottom + 4, centre.Z), Vector3.new(0, -12, 0), params)
		local ground = if hit ~= nil then hit.Position.Y else nil
		local prompt = model:FindFirstChild("CatchPrompt", true)
		local promptParent = if prompt ~= nil then prompt.Parent else nil
		local promptY = if promptParent ~= nil and promptParent:IsA("Attachment")
			then promptParent.WorldPosition.Y
			elseif promptParent ~= nil and promptParent:IsA("BasePart") then promptParent.Position.Y
			else nil
		local gap = if ground ~= nil then bottom - ground else nil
		local rowOk = gap ~= nil
			and gap > -0.05
			and gap < GAP_TOLERANCE
			and promptY ~= nil
			and promptY - (ground :: number) >= PROMPT_MIN_HEIGHT
		ok = ok and rowOk
		table.insert(rows, {
			id = model:GetAttribute("TurkeyId"),
			bottom = math.floor(bottom * 1000) / 1000,
			ground = if ground ~= nil then math.floor(ground * 1000) / 1000 else "none",
			gap = if gap ~= nil then math.floor(gap * 1000) / 1000 else "none",
			groundPart = if hit ~= nil then hit.Instance:GetFullName() else "none",
			promptY = if promptY ~= nil then math.floor(promptY * 1000) / 1000 else "none",
			promptParent = if promptParent ~= nil then promptParent.Name else "none",
			x = math.floor(centre.X * 10) / 10,
			z = math.floor(centre.Z * 10) / 10,
			ok = rowOk,
		})
	end
	return { turkeys = rows, ok = ok and #rows > 0 }
end

if COMMAND == "diag" then
	local hud = ScreenManager.getGui("Hud")
	local profile = ClientState.profile
	local stickers = if type(profile) == "table" and type(profile.event) == "table" then profile.event.stickers else nil
	return HttpService:JSONEncode({
		hud = hud ~= nil and hud.Enabled,
		profile = type(profile) == "table",
		stickers = stickers or {},
	})
elseif COMMAND == "probe" then
	return HttpService:JSONEncode(probe())
elseif COMMAND == "camera" then
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(Vector3.new(ARGS[1], ARGS[2], ARGS[3]), Vector3.new(ARGS[4], ARGS[5], ARGS[6]))
	return "ok"
elseif COMMAND == "free" then
	Workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
	return "ok"
elseif COMMAND == "sheet" then
	ScreenManager.closeAllModals()
	ScreenManager.open("HarvestFeast")
	task.wait(0.8)
	return ScreenManager.topModalName() or ""
elseif COMMAND == "close" then
	ScreenManager.closeAllModals()
	return "ok"
end
return "unknown command"
