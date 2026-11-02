--!strict
--[[
	LaunchCountdownScreen ("LaunchCountdown") — the screen that hosts the launch cinematic overlay
	(owner R54: "follow the missile ... with like an animated 3, 2, 1. And a voiceover").

	Opened ONLY by Client/Attack/LaunchCam when the server accepts one of YOUR launches (its
	NukeFlight arrives); closed by LaunchCam when the cinematic ends or is skipped. The drawing lives
	in CountdownOverlay; LaunchCam drives it from its one RenderStepped.

	Why a modal: while it is open ScreenManager blocks gameplay input ("Menus": on a gamepad the
	character pauses, so the stick never walks a character the player cannot see), frees the mouse
	(click-to-skip works in first person / Shift Lock), and routes Back (gamepad B, keyboard X /
	Backspace) to onBack → skip. `blur = false` keeps the world sharp (the world IS the show).
	It draws its own SKIP button (BackButtonAttribute), so no generic touch X is added.

	Connects to: Client/Attack/LaunchCam (open / close / drive), UI/Screens/LaunchCountdown/
	CountdownOverlay (elements), UI/ScreenManager, Shared/Config/LaunchCamConfig.

	Example: (LaunchCam) ScreenManager.open("LaunchCountdown"); CountdownOverlay.current().render(rel, 1)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CountdownOverlay = require(script.Parent.CountdownOverlay)
local LaunchCamConfig = require(ReplicatedStorage.Shared.Config.LaunchCamConfig)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)

local module: ScreenManager.ScreenModule = {
	name = LaunchCamConfig.ScreenName,
	modal = true,
	closeOnBack = true,
	-- Built during idle time after boot, so the first launch never hitches on the build.
	lazy = true,
	prebuild = true,
	displayOrder = 36,
	blur = false,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		gui:SetAttribute(ScreenManager.BackButtonAttribute, true)
		local overlay = CountdownOverlay.new(gui)
		return {
			-- Back (B / X / Backspace) skips; LaunchCam closes the screen itself.
			onBack = function(): boolean
				overlay.requestSkip("back")
				return true
			end,
			-- Closed by anything else (closeAllModals from a teleport, ...): the cinematic ends too.
			onClose = function()
				overlay.requestSkip("closed")
			end,
			defaultSelection = function(): GuiObject?
				return overlay.skipButton.instance
			end,
		}
	end,
}

return module
