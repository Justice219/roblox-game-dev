--!strict
--[[
	PlatformController — boots SellNukes' console + mobile platform layer (owner R11, spec §16).

	Start() (after UIController, so ScreenManager, the HUD and the device profile exist):
		1. GuiService.AutoSelectGuiEnabled = false — View / Select opens OUR quick menu
		   (MenuWheel) instead of Roblox's auto-select; D-pad left / right focus the HUD.
		2. GlyphFamily (Xbox / PlayStation glyph detection), Haptics (rumble presets + automatic
		   purchase / reward hooks), SafeArea (console TV-safe 5 % inset → ScreenManager).
		3. ActionMap: every PlatformConfig action bound through ContextActionService by context.
		4. Registers the platform screens with ScreenManager: PlatformHints (HintBar),
		   PlatformTouch (TouchButtons), MenuWheel.
		5. Studio: logs a one-line summary (CAS mode, device, safe insets) for QA.

	Boot entry: "Platform/PlatformController" in src/client/init.client.luau ORDERED_NAMES.

	Connects to: Platform/*, UI/ScreenManager, Controllers/{InputController, UIController}.

	Example (client boot):
		PlatformController.Init()
		PlatformController.Start()
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ActionMap = require(script.Parent.ActionMap)
local GlyphFamily = require(script.Parent.GlyphFamily)
local Haptics = require(script.Parent.Haptics)
local HintBar = require(script.Parent.HintBar)
local MenuWheel = require(script.Parent.MenuWheel)
local SafeArea = require(script.Parent.SafeArea)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local TouchButtons = require(script.Parent.TouchButtons)

local PlatformController = {}

local started = false

function PlatformController.Init() end

--[[ Boots the platform layer (see the module header). Called once by the client boot. ]]
function PlatformController.Start()
	if started then
		return
	end
	started = true
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 30)
	if playerGui == nil or not playerGui:IsA("PlayerGui") then
		warn("[PlatformController] PlayerGui missing")
		return
	end
	GuiService.AutoSelectGuiEnabled = false
	GlyphFamily.start()
	Haptics.start()
	SafeArea.start()
	ActionMap.start()
	for _, screen in { HintBar.screen, TouchButtons.screen, MenuWheel.screen } do
		if not ScreenManager.isRegistered(screen.name) then
			ScreenManager.register(screen, playerGui)
		end
	end
	if RunService:IsStudio() then
		local insets = SafeArea.current()
		print(
			`[Platform] started: cas={ActionMap.isCasMode()} device={ScreenManager.device.class} `
				.. `tvInset={insets.left}x{insets.top} glyphs={GlyphFamily.family()}`
		)
	end
end

return PlatformController
