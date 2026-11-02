--!strict
--[[
	UIController — boots the SellNukes UI (ported from RoBeasts' UIController boot wiring).

	Start() does, in order:
		1. feeds the device profile (DeviceProfile.current) into ScreenManager (UI scale, phone /
		   tablet / desktop / console layout) and keeps it fresh on viewport / input changes,
		2. registers the HUD screens ("Hud", "Toasts"; UI/Hud/Hud.screens()) and keeps them hidden
		   under the join loading screen until LoadingDone (owner R16, Widgets/LoadingGate),
		3. DISCOVERS every screen module under UI/Screens and registers it (dynamic discovery on
		   purpose: parallel builders add screens without editing a shared list). Rules:
		     - each direct-child ModuleScript returning a ScreenModule is a screen,
		     - a Folder child is scanned one level deep for ModuleScripts named "*Screen",
		     - DEV_ONLY screens (UIGallery) register only in Studio,
		4. sets the "ComingSoon" fallback (unknown screen names open it),
		5. starts ScreenManager (device-switch handling), boots the tycoon client UI
		   (Tycoon/TycoonClient) and prebuilds lazy `prebuild` screens a few seconds after boot,
		6. wires input actions: D-pad left / right put the gamepad cursor on the HUD columns;
		   F6 (Studio) toggles the UI gallery,
		7. mirrors the player's reduce-motion setting (profile.settings.reducedMotion) into the
		   shared animation driver (Widgets/OfferFx),
		8. Studio only: the local player's "DevOpenScreen" attribute opens a screen by name (the
		   MCP / server can drive screenshots). Ignored on live servers.

	Connects to: UI/ScreenManager, UI/Hud/Hud, UI/Screens/*, Widgets/OfferFx,
	Controllers/InputController, Client/ClientState, Shared/Util/DeviceProfile.

	Example (client boot):
		for _, controller in { InputController, CameraController, UIController } do controller.Init() end
		for _, controller in { InputController, CameraController, UIController } do controller.Start() end
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ButtonFeedback = require(script.Parent.Parent.UI.ButtonFeedback)
local ClientState = require(script.Parent.Parent.ClientState)
local Create = require(script.Parent.Parent.UI.Create)
local DeviceProfile = require(ReplicatedStorage.Shared.Util.DeviceProfile)
local Hud = require(script.Parent.Parent.UI.Hud.Hud)
local HudFocusConfig = require(ReplicatedStorage.Shared.Config.HudFocusConfig)
local InputController = require(script.Parent.InputController)
local LoadingGate = require(script.Parent.Parent.UI.Widgets.LoadingGate)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)

local UIController = {}

-- Screens that exist only in Studio (developer tools).
local DEV_ONLY: { [string]: boolean } = { UIGallery = true }
-- The fallback for screens that are not built yet.
local FALLBACK_SCREEN = "ComingSoon"
-- Seconds after boot before lazy `prebuild` screens build in idle time.
local PREBUILD_DELAY = 4

local started = false
local cameraConnection: RBXScriptConnection? = nil

-- Re-reads the device profile (viewport / class / scale) into ScreenManager.
local function updateScale()
	ScreenManager.setDeviceProfile(DeviceProfile.current())
end

-- Watches the current camera's viewport (the camera object can be replaced).
local function watchCamera()
	if cameraConnection ~= nil then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
	updateScale()
end

-- True when `value` looks like a ScreenModule (name + build), so a helper module is skipped.
local function isScreenModule(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local candidate = value :: { [string]: unknown }
	return type(candidate.name) == "string" and type(candidate.build) == "function"
end

-- Requires and registers one screen module (pcall: one broken screen never breaks the rest).
local function registerModule(module: ModuleScript, playerGui: PlayerGui)
	local ok, result = pcall(require, module)
	if not ok then
		warn(`[UIController] screen {module.Name} failed to load: {result}`)
		return
	end
	if not isScreenModule(result) then
		return
	end
	local screen = result :: ScreenManager.ScreenModule
	if DEV_ONLY[screen.name] and not RunService:IsStudio() then
		return
	end
	ScreenManager.register(screen, playerGui)
end

-- Discovers every screen under UI/Screens (see the module header).
local function discoverScreens(playerGui: PlayerGui)
	local folder = script.Parent.Parent.UI:FindFirstChild("Screens")
	if folder == nil then
		return
	end
	local children = folder:GetChildren()
	table.sort(children, function(a: Instance, b: Instance)
		return a.Name < b.Name
	end)
	for _, child in children do
		if child:IsA("ModuleScript") then
			registerModule(child, playerGui)
		elseif child:IsA("Folder") then
			for _, nested in child:GetChildren() do
				if nested:IsA("ModuleScript") and string.sub(nested.Name, -6) == "Screen" then
					registerModule(nested, playerGui)
				end
			end
		end
	end
end

-- Mirrors profile.settings.reducedMotion into the animation driver.
local function applySettings(profile: ClientState.Profile)
	local settings = profile.settings
	OfferFx.setReducedMotion(type(settings) == "table" and settings.reducedMotion == true)
end

function UIController.Init() end

--[[ Builds the whole UI (see the module header). Called once by the client boot. ]]
function UIController.Start()
	if started then
		return
	end
	started = true
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui", 30)
	if playerGui == nil or not playerGui:IsA("PlayerGui") then
		warn("[UIController] PlayerGui missing")
		return
	end
	watchCamera()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	-- A touch laptop can flip between touch-first and keyboard-first (pcall: older clients).
	pcall(function()
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(updateScale)
	end)

	-- Owner R22: every GuiButton built from here on gets press sound + particles (bound by
	-- Create before its action handlers); the overlay + PlayerGui fallback start right after.
	Create.setButtonFeedbackBinder(ButtonFeedback.bind)
	for _, screen in Hud.screens() do
		ScreenManager.register(screen, playerGui)
	end
	-- Owner R16: the HUD stays hidden under the join loading screen (fades in after it).
	if not LoadingGate.isDone() then
		ScreenManager.setFocusReason("Loading", true, HudFocusConfig.LoadingHidden :: { string })
		LoadingGate.onDone(function()
			ScreenManager.setFocusReason("Loading", false)
		end)
	end
	discoverScreens(playerGui)
	ScreenManager.setFallback(FALLBACK_SCREEN)
	ScreenManager.start()
	ButtonFeedback.start(playerGui)
	-- The tycoon client UI (billboards, pops, tutorial, YOU marker, income) reads the HUD and
	-- opens screens, so it boots right after them (src/client/Tycoon, B6).
	local tycoonOk, tycoonError = pcall(function()
		local TycoonClient = require(script.Parent.Parent.Tycoon.TycoonClient)
		TycoonClient.start()
	end)
	if not tycoonOk then
		warn(`[UIController] tycoon client failed to start: {tycoonError}`)
	end
	task.delay(PREBUILD_DELAY, ScreenManager.prebuildIdle)

	InputController.ActionPressed:Connect(function(action)
		if action == "HudFocus" then
			Hud.focusButtons()
		elseif action == "OffersFocus" then
			Hud.focusOffers()
		elseif action == "DevGallery" and RunService:IsStudio() then
			ScreenManager.toggle("UIGallery")
		end
	end)

	ClientState.ProfileChanged:Connect(function(profile, fields)
		if fields == nil or table.find(fields, "settings") ~= nil then
			applySettings(profile)
		end
	end)
	local profile = ClientState.profile
	if profile ~= nil then
		applySettings(profile)
	end

	if RunService:IsStudio() then
		-- Studio-only screenshot hook: the server (or MCP) sets the attribute; we open the screen.
		local function openRequested()
			local requested = player:GetAttribute("DevOpenScreen")
			if type(requested) == "string" and requested ~= "" then
				ScreenManager.closeAllModals()
				ScreenManager.open(requested)
			end
		end
		player:GetAttributeChangedSignal("DevOpenScreen"):Connect(openRequested)
		openRequested()
	end
end

return UIController
