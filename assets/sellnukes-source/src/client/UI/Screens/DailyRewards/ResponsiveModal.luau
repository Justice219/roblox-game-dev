--!strict
--[[
	ResponsiveModal — a StudUI stud window as a modal ScreenModule (like StudUI.modalScreen) that
	can switch between several authored DESIGN SIZES ("modes") so it stays finger-friendly on
	phones (owner R11: console + mobile first; docs/platform.md §7, docs/ui.md §7).

	Why: ModalShell shrinks a window uniformly to fit the screen. A 960 x 660 reward window on a
	landscape phone is shrunk to ~0.76 of the 0.62 phone scale, so a 44 pt tap would need ~93
	design px and 14 pt text ~30 design px — impossible inside the reference's 3 x 2 card grid.
	A WIDE mode (e.g. 1320 x 500: one row of cards) fits the phone unshrunk instead. Each screen
	lists its modes; the first one is the reference layout (desktop / console / tablet).

	Mode choice (event-driven: ScreenManager.LayoutChanged / SafeAreaChanged, the gui's size, and
	every open):
		- mouse / gamepad (no finger targets): always the first mode (the reference look),
		- touch (ScreenManager.touchTargets): the mode whose window renders BIGGEST on this canvas
		  (largest ModalShell fit; the first mode wins ties within FIT_TIE).
	Switching modes builds a new ModalShell for the new design size (it re-parents the window),
	then drops the old one — the same technique as Screens/LuckyWheel. Rare (rotation / resize /
	device switch), never per frame.

	The screen receives a Controller: `current()` = the active Layout (mode, window size, body
	inner area, device points per design px, and the minimum tap side / text size in design px
	for this device: 44 pt and 14 pt on touch, 0 otherwise), and `onChanged(callback)` which runs
	after any of those changed. Screens re-place their content there.

	Lives inside Screens/DailyRewards (a ModuleScript folder), so UIController never registers it
	as a screen. Used by Screens/{DailyRewards, TimeRewards, WhatsNew, Settings}.

	Connects to: Kit/StudUI (window), Widgets/ModalShell (fit + pop-in), UI/ScreenManager (canvas,
	scale, touch targets, layout signals, close), Platform/GamepadNav (default selection fallback),
	Shared/Util/TouchLayout, Shared/Config/{TouchUIConfig, UIStyleConfig}.

	Example:
		return ResponsiveModal.screen({
			name = "Settings", title = "Settings", color = "blue", icon = "Settings",
			modes = { { name = "tall", size = Vector2.new(820, 780) },
			          { name = "wide", size = Vector2.new(1320, 500) } },
			build = function(window, gui, layout)
				layout.onChanged(function(current) placeRows(current) end)
				placeRows(layout.current())
				return { defaultSelection = function() return rows[1].instance end }
			end,
		})
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GamepadNav = require(script.Parent.Parent.Parent.Parent.Platform.GamepadNav)
local ModalShell = require(script.Parent.Parent.Parent.Widgets.ModalShell)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

-- Smallest readable text on phones / tablets after every scale (owner R11 / docs/platform.md §7).
local MIN_TEXT_POINTS = 14
-- A later mode must render this much bigger (fit) than an earlier one to be picked.
local FIT_TIE = 0.02

export type Mode = {
	name: string,
	size: Vector2, -- window design size (1080p design px)
}

export type Layout = {
	mode: string, -- the active mode's name
	size: Vector2, -- its window design size
	area: Vector2, -- the window body's inner size (design px; ResponsiveModal.bodySize)
	points: number, -- device points per design px inside the window (UI scale × window fit)
	touch: boolean, -- finger-sized targets wanted (ScreenManager.touchTargets)
	tap: number, -- smallest tap side in design px (44 pt on touch; 0 = no minimum)
	minText: number, -- smallest text size in design px (14 pt on touch; 0 = no minimum)
}

export type Controller = {
	current: () -> Layout,
	onChanged: (callback: (layout: Layout) -> ()) -> (),
}

export type Spec = {
	name: string,
	title: string,
	color: StudUI.ColorName?,
	icon: string?,
	scroll: boolean?,
	lazy: boolean?, -- default true (built on first open)
	modes: { Mode }, -- first = the reference layout
	build: (window: StudUI.Window, gui: ScreenGui, layout: Controller) -> ScreenManager.ScreenHandle?,
}

local ResponsiveModal = {}

--[[
	The inner size (design px) of a StudUI window body: the window minus its header bar, the
	header's dark lip and the body padding on every side.
	@param windowSize the window design size
	@return Vector2
	Example: ResponsiveModal.bodySize(Vector2.new(960, 660)) --> Vector2.new(928, 519)
]]
function ResponsiveModal.bodySize(windowSize: Vector2): Vector2
	local cfg = UIStyleConfig.Window
	return Vector2.new(
		windowSize.X - 2 * cfg.BodyPadding,
		windowSize.Y - cfg.HeaderHeight - cfg.HeaderLip - 2 * cfg.BodyPadding
	)
end

--[[
	Measures the canvas and picks a mode (see the module header). Uses ModalShell's own fit rule
	(TouchLayout.windowFit with the same margins / MinFit) so `points` equals what the shell will
	render — computed here rather than read from the shell, which may refit after us.
	@param gui   the screen's ScreenGui
	@param modes the screen's modes (non-empty)
	@return Layout
]]
local function measure(gui: ScreenGui, modes: { Mode }): Layout
	local canvas = ScreenManager.canvasSize(gui)
	local usableY = math.max(1, canvas.Y - ScreenManager.safeTop(0))
	local touch = ScreenManager.touchTargets()
	local margin = if touch then TouchUIConfig.Modal.TouchMargin else TouchUIConfig.Modal.DesktopMargin
	local function fitOf(mode: Mode): number
		return TouchLayout.windowFit(mode.size.X, mode.size.Y, canvas.X, usableY, margin, TouchUIConfig.Modal.MinFit)
	end
	local best = modes[1]
	local bestFit = fitOf(best)
	if touch then
		for index = 2, #modes do
			local fit = fitOf(modes[index])
			if fit > bestFit + FIT_TIE then
				best, bestFit = modes[index], fit
			end
		end
	end
	local points = math.max(ScreenManager.pointScale() * bestFit, 0.05)
	return {
		mode = best.name,
		size = best.size,
		area = ResponsiveModal.bodySize(best.size),
		points = points,
		touch = touch,
		tap = if touch then TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, points) else 0,
		minText = if touch then TouchLayout.pointsToDesign(MIN_TEXT_POINTS, points) else 0,
	}
end

-- True when two layouts place content differently (points alone only matter via tap / text).
local function differs(a: Layout, b: Layout): boolean
	return a.mode ~= b.mode or a.tap ~= b.tap or a.minText ~= b.minText or a.touch ~= b.touch
end

--[[
	A complete modal ScreenModule around a StudUI window with responsive modes (see the header).
	Same behaviour as StudUI.modalScreen otherwise: red X / keyboard X / gamepad B close it
	(ScreenManager closeOnBack), pop-in on open, gamepad selection starts on the screen's
	defaultSelection (fallback: the first selectable in the body, never the close X).
	@param spec name / title / colour / icon / scroll / lazy / modes / build
	@return ScreenManager.ScreenModule
]]
function ResponsiveModal.screen(spec: Spec): ScreenManager.ScreenModule
	assert(#spec.modes > 0, "ResponsiveModal needs at least one mode")
	return {
		name = spec.name,
		modal = true,
		closeOnBack = true,
		lazy = if spec.lazy == nil then true else spec.lazy,
		build = function(gui: ScreenGui): ScreenManager.ScreenHandle
			local window = StudUI.window({
				title = spec.title,
				color = spec.color,
				icon = spec.icon,
				size = spec.modes[1].size,
				scroll = spec.scroll,
				name = `{spec.name}Window`,
				onClose = function()
					ScreenManager.close(spec.name)
				end,
			})
			local layout = measure(gui, spec.modes)
			local shell = ModalShell.new(gui, window.frame, layout.size)
			local listeners: { (Layout) -> () } = {}
			local queued = false

			-- Re-measures; on a change swaps the shell (new design size) and tells the screen.
			local function apply()
				local next_ = measure(gui, spec.modes)
				if not differs(next_, layout) then
					layout = next_
					return
				end
				if next_.mode ~= layout.mode then
					-- New shell first (it re-parents the window), then drop the old one.
					local old = shell
					shell = ModalShell.new(gui, window.frame, next_.size)
					old.Destroy()
				end
				layout = next_
				for _, listener in listeners do
					local ok, err = pcall(listener, next_)
					if not ok then
						warn(`[ResponsiveModal] {spec.name} layout listener error: {err}`)
					end
				end
			end

			-- Coalesces bursts of layout signals into one re-measure next frame.
			local function requestApply()
				if queued then
					return
				end
				queued = true
				task.defer(function()
					queued = false
					apply()
				end)
			end
			ScreenManager.LayoutChanged:Connect(requestApply)
			ScreenManager.SafeAreaChanged:Connect(requestApply)
			gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(requestApply)

			local controller: Controller = {
				current = function(): Layout
					return layout
				end,
				onChanged = function(callback: (Layout) -> ())
					table.insert(listeners, callback)
				end,
			}
			local inner: ScreenManager.ScreenHandle = spec.build(window, gui, controller) or {}
			local fallbackSelection = GamepadNav.defaultSelection(window.body)
			return {
				onOpen = function(args: any?)
					apply() -- the canvas may have changed while closed
					shell.popIn()
					local onOpen = inner.onOpen
					if onOpen ~= nil then
						onOpen(args)
					end
				end,
				onClose = inner.onClose,
				onBack = inner.onBack,
				defaultSelection = function(): GuiObject?
					local selector = inner.defaultSelection
					local target = if selector ~= nil then selector() else nil
					return target or fallbackSelection() or window.closeButton
				end,
			}
		end,
	}
end

return table.freeze(ResponsiveModal)
