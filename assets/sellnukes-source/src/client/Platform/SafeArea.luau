--!strict
--[[
	SafeArea — keeps every SellNukes ScreenGui inside the TV-safe area on consoles and reports the
	phone notch insets.

	Console (ten-foot interface, DeviceProfile class "Console"): TVs may overscan the picture,
	so all interactive / important UI stays inside a 5 % inset per side
	(PlatformConfig.SafeArea.TvFraction). SafeArea computes the inset in points
	(LayoutLogic.tvInsets) and hands it to ScreenManager.setSafeInsets, which pads every
	registered ScreenGui (UIPadding "SafeArea", scaled by the AutoScale UIScale — verified in
	Studio) and shrinks canvasSize, so the HUD columns, windows and hint bar all re-lay out inside
	it. Phones / tablets / desktop get zero extra inset: ScreenManager's guis already use
	ScreenInsets.DeviceSafeInsets (notch, home indicator, rounded corners).

	Phone notch report: `deviceInsets()` measures how far Roblox's DeviceSafeInsets area sits
	inside the full screen (two invisible probe ScreenGuis), for the device-matrix QA and for
	overlays that must draw full-bleed.

	Studio: LocalPlayer attribute `DevTvSafe = true` forces the TV inset on a desktop session
	(device-matrix console screenshots). Ignored on live servers.

	Migration guard: until ScreenManager.setSafeInsets exists (B2), the computed insets are kept
	(current()) but not applied; a Studio warning says so once.

	Connects to: Platform/{LayoutLogic, PlatformController}, UI/ScreenManager,
	Shared/Config/PlatformConfig.

	Example:
		SafeArea.start()
		print(SafeArea.current().left) --> 96 on a 1080p console, 0 elsewhere
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LayoutLogic = require(script.Parent.LayoutLogic)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local SafeArea = {}

-- Fires () after the applied insets changed.
SafeArea.Changed = Signal.new() :: Signal.Signal<>

-- Never mutated (current() hands out copies).
local ZERO: LayoutLogic.Insets = { left = 0, top = 0, right = 0, bottom = 0 }
local current: LayoutLogic.Insets = ZERO
local started = false
local warnedMissing = false
-- Probe frames: full screen (ScreenInsets.None) and the device-safe area.
local fullProbe: Frame? = nil
local safeProbe: Frame? = nil

--[[ The TV-safe insets currently applied (points; zeros off console). A copy. ]]
function SafeArea.current(): LayoutLogic.Insets
	return table.clone(current)
end

-- True when the TV inset applies (console, or the Studio override).
local function tvActive(): boolean
	if ScreenManager.device.class == "Console" then
		return true
	end
	return RunService:IsStudio() and Players.LocalPlayer:GetAttribute(PlatformConfig.SafeArea.StudioAttr) == true
end

-- Recomputes the insets and applies them when they changed.
local function apply()
	local device = ScreenManager.device
	local insets = if tvActive()
		then LayoutLogic.tvInsets(device.viewportX, device.viewportY, PlatformConfig.SafeArea.TvFraction)
		else ZERO
	if LayoutLogic.insetsEqual(insets, current) then
		return
	end
	current = insets
	-- Typed local from `any` (feature-detected until B2's hook lands).
	local setter: (LayoutLogic.Insets) -> () = (ScreenManager :: any).setSafeInsets
	if setter ~= nil then
		setter(table.clone(current))
	elseif not warnedMissing and RunService:IsStudio() then
		warnedMissing = true
		warn("[SafeArea] ScreenManager.setSafeInsets missing: TV-safe inset computed but not applied")
	end
	SafeArea.Changed:Fire()
end

-- One invisible probe ScreenGui with a full-size frame.
local function probe(name: string, insets: Enum.ScreenInsets, playerGui: PlayerGui): Frame
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = insets
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -100
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Active = false
	frame.Parent = gui
	gui.Parent = playerGui
	return frame
end

--[[
	How far the device-safe area sits inside the full screen, per side (points): the notch /
	home-indicator / rounded-corner insets Roblox applies through DeviceSafeInsets.
	@return insets (zeros before start or on devices without cutouts)
	Example: SafeArea.deviceInsets() --> { left = 47, top = 0, right = 47, bottom = 21 } (iPhone landscape)
]]
function SafeArea.deviceInsets(): LayoutLogic.Insets
	local full, safe = fullProbe, safeProbe
	if full == nil or safe == nil then
		return ZERO
	end
	local fullPos, fullSize = full.AbsolutePosition, full.AbsoluteSize
	local safePos, safeSize = safe.AbsolutePosition, safe.AbsoluteSize
	return {
		left = math.max(0, safePos.X - fullPos.X),
		top = math.max(0, safePos.Y - fullPos.Y),
		right = math.max(0, (fullPos.X + fullSize.X) - (safePos.X + safeSize.X)),
		bottom = math.max(0, (fullPos.Y + fullSize.Y) - (safePos.Y + safeSize.Y)),
	}
end

--[[ Starts tracking (once; PlatformController, after UIController fed the device profile). ]]
function SafeArea.start()
	if started then
		return
	end
	started = true
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui ~= nil then
		fullProbe = probe("SafeAreaProbeFull", Enum.ScreenInsets.None, playerGui)
		safeProbe = probe("SafeAreaProbeDevice", Enum.ScreenInsets.DeviceSafeInsets, playerGui)
	end
	-- setSafeInsets fires LayoutChanged; apply() is idempotent, so the echo stops at once.
	ScreenManager.LayoutChanged:Connect(apply)
	if RunService:IsStudio() then
		Players.LocalPlayer:GetAttributeChangedSignal(PlatformConfig.SafeArea.StudioAttr):Connect(apply)
	end
	apply()
end

return SafeArea
