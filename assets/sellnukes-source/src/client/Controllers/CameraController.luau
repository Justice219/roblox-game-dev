--!strict
--[[
	CameraController — the small camera / mouse services the SellNukes UI needs.

	Purpose:
		SellNukes keeps Roblox's default follow camera (players walk their tycoon). The UI needs
		exactly one thing from the camera layer: when a modal window opens, the mouse must be FREE
		even if the player is zoomed into first person or uses Shift Lock (otherwise the cursor
		is locked to the screen centre and cannot click the window). The engine-supported way is
		a visible GuiButton with `Modal = true`: while one is visible, Roblox unlocks the mouse.
		`setMouseFree(true)` shows a 1x1 transparent modal button; `false` hides it. Counted by
		reason so two systems never fight.

		`setMenuBlur(on)` softly blurs the 3D world behind open windows (the references show a
		blurred world behind every window). One BlurEffect under the CurrentCamera; skipped when
		the graphics tier is Low (the caller passes `allowed = false`) because full-screen blur
		costs GPU on weak phones.

	Performance: event-driven; no per-frame work.

	Connects to: UI/ScreenManager (calls setMouseFree / setMenuBlur on modal stack changes),
	Controllers/UIController (boot).

	Example:
		CameraController.setMouseFree(true, "Menus")
		CameraController.setMenuBlur(true, OfferFx.tier() ~= "Low")
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local CameraController = {}

-- Design: BlurEffect size while a window is open (Roblox units; 0 = off).
local MENU_BLUR_SIZE = 10

local freeReasons: { [string]: true } = {}
local modalGui: ScreenGui? = nil
local modalButton: TextButton? = nil
local blur: BlurEffect? = nil

-- Builds the hidden modal-button ScreenGui on first need (PlayerGui exists by then).
local function ensureModalButton(): TextButton?
	if modalButton ~= nil and modalButton.Parent ~= nil then
		return modalButton
	end
	local player = Players.LocalPlayer
	local playerGui = if player ~= nil then player:FindFirstChildOfClass("PlayerGui") else nil
	if playerGui == nil then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "MouseFree"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -10
	gui.IgnoreGuiInset = true
	local button = Instance.new("TextButton")
	button.Name = "ModalUnlock"
	button.Size = UDim2.fromOffset(1, 1)
	button.Position = UDim2.fromOffset(-10, -10) -- off screen: never intercepts a click
	button.BackgroundTransparency = 1
	button.Text = ""
	button.Selectable = false
	button.Active = false
	button.Modal = true
	button.Visible = false
	button.Parent = gui
	gui.Parent = playerGui
	modalGui = gui
	modalButton = button
	return button
end

--[[
	Frees (or releases) the mouse for `reason` (counted). While any reason is active the mouse
	is never locked by first person / Shift Lock.
	@param free   true to add the reason
	@param reason stable id (default "Menus")
	Example: CameraController.setMouseFree(true)
]]
function CameraController.setMouseFree(free: boolean, reason: string?)
	local key = reason or "Menus"
	if free then
		freeReasons[key] = true
	else
		freeReasons[key] = nil
	end
	local button = ensureModalButton()
	if button ~= nil then
		button.Visible = next(freeReasons) ~= nil
	end
end

--[[
	Turns the soft world blur behind open windows on / off.
	@param on      a window is open
	@param allowed false on Low graphics (blur skipped entirely)
]]
function CameraController.setMenuBlur(on: boolean, allowed: boolean)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local effect = blur
	if effect == nil or effect.Parent ~= camera then
		if not on then
			return
		end
		local created = Instance.new("BlurEffect")
		created.Name = "MenuBlur"
		created.Size = 0
		created.Parent = camera
		blur = created
		effect = created
	end
	assert(effect ~= nil, "menu blur")
	effect.Size = if on and allowed then MENU_BLUR_SIZE else 0
	effect.Enabled = on and allowed
end

function CameraController.Init() end

function CameraController.Start()
	-- The camera may be replaced (rare); the next setMenuBlur call re-creates the effect under it.
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local effect = blur
		if effect ~= nil then
			effect:Destroy()
			blur = nil
		end
	end)
	if modalGui == nil then
		ensureModalButton()
	end
end

return CameraController
