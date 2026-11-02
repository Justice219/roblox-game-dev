--!nocheck
--[[
	juice_client.luau — client-VM probe for the R71 juice pass, run by tools/qa/juice.py through
	eval_client_runtime during ONE solo playtest.

		COMMAND  "clear"     closes every open window (returns the top one that was open, "" = none)
		         "state"     JSON: loading / HUD ready, combo count, banner up, fireworks live, loop
		                     running, watched own producers, glows, ambient emitters, particle pools
		         "approach"  stands the character in front of the first own producer it finds
		         "combo"     60 combo presses 0.12 s apart on that producer (ClickCombo.press only:
		                     no remote traffic) -> label up to x60, rings every 10, big bursts at 25 / 50
		         "upgrade"   one real UPGRADE press on it (ProducerBillboards.upgrade -> intent)
		         "banner"    the milestone banner as a level-50 speed milestone would show it
		         "padbuy"    the pad-buy coin burst at the producer (WorldFxController.PadPressed)
		         "rebirth"   the rebirth celebration (flash + fireworks + punch)
		         "finale"    the finale confetti cannon over the producer model
		         "showcase"  18 s of combo + coins + fireworks at once (for screenshots)
	Presentation only: the one intent sent ("upgrade") is a normal player action.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local COMMAND = "__COMMAND__"

local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Fx = client.Tycoon.Fx
local ClickCombo = require(Fx.ClickCombo)
local Fireworks = require(Fx.Fireworks)
local JuiceBanner = require(Fx.JuiceBanner)
local JuiceController = require(Fx.JuiceController)
local JuiceLoop = require(Fx.JuiceLoop)
local JuiceParticles = require(Fx.JuiceParticles)
local ProducerJuice = require(Fx.ProducerJuice)
local WorldFxController = require(Fx.WorldFxController)
local CameraPunch = require(Fx.CameraPunch)
local ProducerBillboards = require(client.Tycoon.ProducerBillboards)
local TycoonWorld = require(client.Tycoon.TycoonWorld)
local ScreenManager = require(client.UI.ScreenManager)

-- The own producer record every command uses: deterministic (lowest id, manual preferred), so
-- "approach" and "combo" (separate evals) always pick the same one.
local function ownRecord()
	local manual, any = {}, {}
	for _, anchor in TycoonWorld.producers() do
		if TycoonWorld.isMine(anchor) then
			local record = ProducerBillboards.byAnchor(anchor)
			if record ~= nil then
				table.insert(any, record)
				if not record.automated then
					table.insert(manual, record)
				end
			end
		end
	end
	local pool = if #manual > 0 then manual else any
	table.sort(pool, function(a, b)
		return a.id < b.id
	end)
	return pool[1]
end

local function state(): string
	local hud = ScreenManager.getGui("Hud")
	local stats = ProducerJuice.stats()
	return HttpService:JSONEncode({
		loadingDone = Players.LocalPlayer:GetAttribute("LoadingDone") == true,
		hud = hud ~= nil and hud.Enabled,
		combo = ClickCombo.count(),
		banner = JuiceBanner.isShowing(),
		fireworks = Fireworks.live(),
		loop = JuiceLoop.running(),
		punch = CameraPunch.isActive(),
		watched = stats.watched,
		glowing = stats.glowing,
		particles = JuiceParticles.stats(),
		bannerRegistered = ScreenManager.isRegistered("JuiceBanner"),
	})
end

if COMMAND == "state" then
	return state()
elseif COMMAND == "clear" then
	-- Join pop-ups (Welcome Back, What's New, plot reveal banner) open a few seconds after the
	-- loading hand-off and would cover the 3D shots.
	local top = ScreenManager.topModalName()
	ScreenManager.closeAllModals()
	return top or ""
elseif COMMAND == "labels" then
	-- The pooled combo labels as the engine sees them (debugging an invisible label).
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local out = {}
	local camera = workspace.CurrentCamera
	for _, gui in playerGui:GetChildren() do
		if gui:IsA("BillboardGui") and string.find(gui.Name, "ComboLabel", 1, true) then
			local adornee = gui.Adornee
			local world = if adornee == nil
				then nil
				elseif adornee:IsA("Attachment") then adornee.WorldPosition
				elseif adornee:IsA("BasePart") then adornee.Position
				else nil
			local screen, onScreen = nil, false
			if world ~= nil then
				local p, visible = camera:WorldToViewportPoint(world)
				screen, onScreen = { math.floor(p.X), math.floor(p.Y), math.floor(p.Z) }, visible
			end
			local text = gui:FindFirstChildOfClass("TextLabel")
			table.insert(out, {
				name = gui.Name,
				enabled = gui.Enabled,
				adornee = if adornee ~= nil then adornee:GetFullName() else "nil",
				screen = screen,
				onScreen = onScreen,
				text = if text ~= nil then text.Text else "",
				transparency = if text ~= nil then text.TextTransparency else -1,
				absolute = if text ~= nil then { text.AbsoluteSize.X, text.AbsoluteSize.Y } else nil,
			})
		end
	end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	table.insert(out, {
		camera = { math.floor(camera.CFrame.Position.X), math.floor(camera.CFrame.Position.Y), math.floor(camera.CFrame.Position.Z) },
		root = if root ~= nil then { math.floor(root.Position.X), math.floor(root.Position.Y), math.floor(root.Position.Z) } else nil,
		cameraType = tostring(camera.CameraType),
	})
	return HttpService:JSONEncode(out)
elseif COMMAND == "approach" then
	local record = ownRecord()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if record == nil or root == nil then
		return `missing record={record ~= nil} root={root ~= nil}`
	end
	-- Stand between the camera and the producer along the camera's own (flattened) look, so the
	-- follow camera keeps the producer in view without scripting the camera.
	local anchor = record.anchor
	local look = workspace.CurrentCamera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local front = anchor.Position - flat * 16 + Vector3.new(0, 3, 0)
	root.CFrame = CFrame.lookAt(front, Vector3.new(anchor.Position.X, front.Y, anchor.Position.Z))
	return `{record.id} automated={record.automated}`
elseif COMMAND == "combo" then
	-- Approach + press in ONE eval, so both always use the same producer (streaming can change
	-- which producers a later eval sees).
	local record = ownRecord()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if record == nil or root == nil then
		return "no record"
	end
	-- Join pop-ups (Welcome Back, What's New) would cover the shot.
	ScreenManager.closeAllModals()
	local look = workspace.CurrentCamera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local front = record.anchor.Position - flat * 16 + Vector3.new(0, 3, 0)
	root.CFrame = CFrame.lookAt(front, Vector3.new(record.anchor.Position.X, front.Y, record.anchor.Position.Z))
	task.spawn(function()
		task.wait(1)
		for _ = 1, 60 do
			ClickCombo.press(record.anchor, record.popPoint)
			task.wait(0.12)
		end
	end)
	return `pressing {record.id}`
elseif COMMAND == "showcase" then
	-- 18 s of everything at once, for screenshots: device-matrix captures switch the device first
	-- and land ~1-2 s after the request, so one-shot effects (< 1.5 s) would be missed. No teleport
	-- (server movement checks snap a teleported character back): it uses the own producer in front
	-- of the camera nearest to the character, keeps a combo going on it (label + rings + bursts),
	-- pops coins at it and launches a small fireworks show ahead of the camera every 1.5 s.
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil then
		return "no root"
	end
	ScreenManager.closeAllModals()
	local camera = workspace.CurrentCamera
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local record, best = nil, math.huge
	for _, anchor in TycoonWorld.producers() do
		if TycoonWorld.isMine(anchor) then
			local candidate = ProducerBillboards.byAnchor(anchor)
			local offset = anchor.Position - camera.CFrame.Position
			local distance = (anchor.Position - root.Position).Magnitude
			if candidate ~= nil and offset.Unit:Dot(look) > 0.5 and distance < best then
				record, best = candidate, distance
			end
		end
	end
	if record == nil then
		return "no producer in view"
	end
	local anchor = record.anchor
	-- Device-matrix captures skip AlwaysOnTop billboards (the "+$X" income pops are missing from
	-- every capture too), so for this QA shot only the combo labels draw in the normal 3D pass.
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	for _, gui in playerGui:GetChildren() do
		if gui:IsA("BillboardGui") and string.find(gui.Name, "ComboLabel", 1, true) then
			gui.AlwaysOnTop = false
		end
	end
	local sky = root.Position + flat * 60 - Vector3.new(0, 4, 0)
	task.spawn(function()
		task.wait(1)
		local started = os.clock()
		local nextShow, nextCoins = 0, 0
		while os.clock() - started < 18 do
			ClickCombo.press(anchor, record.popPoint)
			local age = os.clock() - started
			if age >= nextCoins then
				nextCoins = age + 0.8
				WorldFxController.PadPressed:Fire(anchor.Parent, anchor.Position)
			end
			if age >= nextShow then
				nextShow = age + 1.5
				Fireworks.show(sky, 3, 30) -- far enough ahead that the apex is in view
			end
			task.wait(0.12)
		end
	end)
	return `showcase {record.id} at {math.floor(best)} studs`
elseif COMMAND == "upgrade" then
	local record = ownRecord()
	if record == nil then
		return "no record"
	end
	return tostring(ProducerBillboards.upgrade(record))
elseif COMMAND == "banner" then
	-- Held 25 s so the four-device matrix capture sees it everywhere (normal hold: 2.4 s).
	return tostring(JuiceBanner.show("Pocket Nuke Workbench", "LEVEL 50!", "x2 SPEED!", "cyan", 25))
elseif COMMAND == "padbuy" then
	local record = ownRecord()
	if record == nil then
		return "no record"
	end
	WorldFxController.PadPressed:Fire(record.anchor.Parent, record.anchor.Position)
	return "coins"
elseif COMMAND == "rebirth" then
	JuiceController.celebrateRebirth()
	return state()
elseif COMMAND == "finale" then
	local record = ownRecord()
	if record == nil or not record.anchor.Parent:IsA("Model") then
		return "no model"
	end
	JuiceController.celebrateFinale(record.anchor.Parent)
	return "cannon"
end
return "unknown command"
