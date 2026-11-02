--!strict
--[[
	ModalShell — places a stud window inside its modal ScreenGui: centred below the Roblox top
	bar, uniformly shrunk to fit small screens, with a short pop-in when opened (ported idea from
	RoBeasts' ModalShell, rebuilt around Kit/StudUI windows).

	Purpose:
		Windows are authored at a fixed design size (e.g. 1000 x 640 at 1080p). On a phone the
		1080p canvas is ~1360 x 630 design px, so a tall window must shrink. ModalShell computes
		one uniform fit (TouchLayout.windowFit, never below TouchUIConfig.Modal.MinFit) and
		re-runs it on ScreenManager.LayoutChanged / SafeAreaChanged (event-driven, no per-frame
		work). The pop-in tweens a dedicated UIScale (skipped with Reduce Motion).
		It also marks the ScreenGui as drawing its own close button (the window's red X), so
		ScreenManager never adds the generic touch CLOSE on top.

	Connects to: UI/ScreenManager (layout signals, BackButtonAttribute, canvasSize, safeTop),
	Shared/Util/TouchLayout, Shared/Config/TouchUIConfig, Widgets/OfferFx (reduced motion),
	Kit/StudUI.modalScreen (the usual caller).

	Example:
		local shell = ModalShell.new(gui, window.frame, Vector2.new(1000, 640))
		-- in onOpen:
		shell.popIn()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Create = require(script.Parent.Parent.Create)
local OfferFx = require(script.Parent.OfferFx)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)

export type Shell = {
	root: Frame, -- full-screen holder the window lives in
	fit: () -> (), -- re-run the fit now
	popIn: () -> (), -- the open animation (instant with Reduce Motion)
	scale: () -> number, -- the current fit factor
	Destroy: () -> (),
}

local ModalShell = {}

-- Pop-in: start scale and tween.
local POP_FROM = 0.86
local POP_TWEEN = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

--[[
	Hosts `window` (already sized in design px) inside `gui`.
	@param gui        the modal's ScreenGui
	@param window     the window root (its Size is set to `designSize`)
	@param designSize authored window size in design px
	@return Shell
]]
function ModalShell.new(gui: ScreenGui, window: GuiObject, designSize: Vector2): Shell
	gui:SetAttribute(ScreenManager.BackButtonAttribute, true)
	local root = Create.new("Frame", {
		Name = "ModalShell",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Active = false,
		Parent = gui,
	}) :: Frame
	local fitScale = Create.new("UIScale", { Name = "Fit", Scale = 1 }) :: UIScale
	local popScale = Create.new("UIScale", { Name = "Pop", Scale = 1 }) :: UIScale
	-- Two nested holders so the fit and the pop each own one UIScale (one writer per UIScale).
	local fitHolder = Create.new("Frame", {
		Name = "FitHolder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(designSize.X, designSize.Y),
		Active = false,
		Parent = root,
		Children = { fitScale },
	}) :: Frame
	local popHolder = Create.new("Frame", {
		Name = "PopHolder",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Active = false,
		Parent = fitHolder,
		Children = { popScale },
	}) :: Frame
	window.AnchorPoint = Vector2.zero
	window.Position = UDim2.fromOffset(0, 0)
	window.Size = UDim2.fromScale(1, 1)
	window.Parent = popHolder

	local function fit()
		local canvas = ScreenManager.canvasSize(gui)
		local top = ScreenManager.safeTop(0)
		local margin = if ScreenManager.touchTargets()
			then TouchUIConfig.Modal.TouchMargin
			else TouchUIConfig.Modal.DesktopMargin
		-- The usable band is below the Roblox top bar; the window centres in it.
		local usableY = math.max(1, canvas.Y - top)
		local factor =
			TouchLayout.windowFit(designSize.X, designSize.Y, canvas.X, usableY, margin, TouchUIConfig.Modal.MinFit)
		fitScale.Scale = factor
		fitHolder.Position = UDim2.new(0.5, 0, 0, top + usableY / 2)
	end

	local connections = {
		ScreenManager.LayoutChanged:Connect(fit),
		ScreenManager.SafeAreaChanged:Connect(fit),
	}
	-- A ScreenGui that was disabled keeps a stale AbsoluteSize until the engine's next layout pass
	-- after it is enabled; re-fit when the real size arrives (event-driven).
	local sizeChanged = gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	local currentTween: Tween? = nil
	local dead = false
	local function destroy()
		if dead then
			return
		end
		dead = true
		for _, connection in connections do
			connection:Disconnect()
		end
		sizeChanged:Disconnect()
		if currentTween ~= nil then
			currentTween:Cancel()
		end
		root:Destroy()
	end
	root.Destroying:Once(destroy)
	fit()
	return {
		root = root,
		fit = fit,
		popIn = function()
			if dead then
				return
			end
			fit()
			if currentTween ~= nil then
				currentTween:Cancel()
				currentTween = nil
			end
			if OfferFx.reducedMotion() then
				popScale.Scale = 1
				return
			end
			popScale.Scale = POP_FROM
			local tween = TweenService:Create(popScale, POP_TWEEN, { Scale = 1 })
			currentTween = tween
			tween:Play()
		end,
		scale = function(): number
			return fitScale.Scale
		end,
		Destroy = destroy,
	}
end

return table.freeze(ModalShell)
