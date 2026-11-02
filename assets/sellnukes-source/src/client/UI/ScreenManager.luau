--!strict
--[[
	ScreenManager — opens / closes screens and owns menu-mode input (ported from RoBeasts).

	Purpose:
		Screens are registered as ScreenModules (type below). The manager:
			- builds each screen into its own ScreenGui (DisplayOrder per screen, AutoScale UIScale
			  for the 1080p design, device safe-area insets),
			- auto-opens HUD-style screens (`autoOpen = true`),
			- tracks a stack of open MODAL screens; while any is open: gameplay input is blocked
			  (InputController "Menus"; on a gamepad the character pauses so the stick drives the
			  menu), the mouse is freed (CameraController: works in first person / Shift Lock), the
			  world behind is softly blurred (skipped on Low graphics), and gamepad selection is
			  placed on the screen's default button,
			- binds Back to close the top modal (`closeOnBack`, default true): gamepad B plus the
			  keyboard close keys X / Backspace — never while a TextBox has focus (typing a code
			  must not close the Codes window: Shared/Util/PopupCloseRule),
			- re-applies gamepad selection when the player switches to a controller,
			- FALLBACK: `open(name)` of a screen that is not registered yet opens the fallback
			  screen (setFallback; UIController registers "ComingSoon") with args
			  `{ requested = name }`, so HUD buttons for systems later builders add never do nothing,
			- FOCUS MODE (setFocusReason): fades listed NON-modal screens out for clean moments
			  (egg hatch, attack target picker) and back in when every reason is cleared,
			- HANDOFF (owner R79, handoff(from, to, args)): a hub modal opening another modal hides
			  itself while that one is open and comes back (selection re-applied) when it closes —
			  Quests GO -> Lucky Wheel shows only the wheel, then Quests again,
			- DEVICE LAYOUT: UIController feeds the device profile (setDeviceProfile); the manager
			  applies its UI scale and fires LayoutChanged so responsive widgets re-layout,
			- TOUCH CLOSE: in Touch mode a closeOnBack modal that draws no close button of its own
			  (ScreenGui attribute BackButtonAttribute unset) gets an X button top-right,
			- LAZY BUILD: `lazy = true` screens build on first open (shorter phone boot);
			  `prebuild = true` builds them during idle time after boot instead.

	Screen module contract (one ModuleScript per screen under UI/Screens, discovered by
	UIController so parallel builders never edit a shared list):
		return {
			name = "Shop",
			modal = true,            -- blocks gameplay while open
			autoOpen = false,        -- HUD widgets set true
			closeOnBack = true,      -- default true for modals
			displayOrder = 20,       -- default 20 modal / 5 non-modal
			lazy = true,             -- build on first open
			prebuild = false,        -- with lazy: build during idle time after boot
			blur = true,             -- modal only: blur the world behind (default true)
			build = function(gui: ScreenGui): ScreenHandle ... end,
		}
		ScreenHandle = {
			onOpen: ((args: any?) -> ())?,       -- refresh contents when shown (args from open)
			onClose: (() -> ())?,
			onBack: (() -> boolean)?,            -- true = Back handled (do not close)
			defaultSelection: (() -> GuiObject?)?, -- first gamepad-selected element
		}

	Connects to: Controllers/InputController, Controllers/CameraController, Widgets/GuiFade,
	Widgets/OfferFx (graphics tier for blur), Shared/Util/{DeviceProfile, PopupCloseRule,
	TouchLayout}, Shared/Config/{InputConfig, HudFocusConfig, TouchUIConfig}, every screen.

	Example:
		ScreenManager.open("Shop")
		ScreenManager.open("Teleport", { area = 3 })
		ScreenManager.toggle("Codes")
		if ScreenManager.isOpen("DailyRewards") then ... end
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CameraController = require(script.Parent.Parent.Controllers.CameraController)
local Components = require(script.Parent.Components)
local DeviceProfile = require(ReplicatedStorage.Shared.Util.DeviceProfile)
local GuiFade = require(script.Parent.Widgets.GuiFade)
local HudFocusConfig = require(ReplicatedStorage.Shared.Config.HudFocusConfig)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local LauncherStuds = require(script.Parent.Widgets.LauncherStuds)
local OfferFx = require(script.Parent.Widgets.OfferFx)
local PopupCloseRule = require(ReplicatedStorage.Shared.Util.PopupCloseRule)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local StudTextureLocal = require(script.Parent.Widgets.StudTextureLocal)
local Theme = require(script.Parent.Theme)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)

export type ScreenHandle = {
	onOpen: ((args: any?) -> ())?,
	onClose: (() -> ())?,
	-- true consumes Back (the screen handled it, e.g. stepping back inside a sub-page);
	-- false / nil keeps the ordinary close.
	onBack: (() -> boolean)?,
	defaultSelection: (() -> GuiObject?)?,
}

export type ScreenModule = {
	name: string,
	modal: boolean,
	autoOpen: boolean?,
	closeOnBack: boolean?,
	displayOrder: number?,
	lazy: boolean?,
	prebuild: boolean?,
	blur: boolean?,
	-- false: no TV-safe "SafeArea" padding (full-bleed fades / letterboxes); default true.
	safeArea: boolean?,
	build: (gui: ScreenGui) -> ScreenHandle,
}

type Entry = {
	module: ScreenModule,
	gui: ScreenGui,
	handle: ScreenHandle, -- an empty placeholder until `built`
	open: boolean,
	built: boolean,
	building: boolean,
	buildMs: number,
}

local ScreenManager = {}

ScreenManager.Opened = Signal.new() :: Signal.Signal<string>
ScreenManager.Closed = Signal.new() :: Signal.Signal<string>
-- Fires when the area hidden by the Roblox top bar changes (scale or bar size).
ScreenManager.SafeAreaChanged = Signal.new() :: Signal.Signal<>
-- Fires after anything a responsive layout depends on changed (scale, device class, viewport,
-- top bar, Touch mode). HUD placement and ModalShell re-layout on it (event-driven).
ScreenManager.LayoutChanged = Signal.new() :: Signal.Signal<>
-- Fires (on) when focus mode turns on / off.
ScreenManager.FocusChanged = Signal.new() :: Signal.Signal<boolean>
-- Attribute a screen's ScreenGui carries when it draws its own close button (StudUI windows
-- through ModalShell), so the generic touch CLOSE button is not added on top of it.
ScreenManager.BackButtonAttribute = "HasBackButton"
-- Current resolution scale (1 at 1080p); see setScale.
ScreenManager.scale = 1
-- The device profile the UI is laid out for (Desktop until UIController feeds the real one).
ScreenManager.device = {
	class = "Desktop",
	isTouch = false,
	isPhone = false,
	isTablet = false,
	viewportX = 0,
	viewportY = 0,
	uiScale = 1,
} :: DeviceProfile.Profile

local entries: { [string]: Entry } = {}
local modalStack: { string } = {}
--[[ Owner R79 handoffs: parent modal name -> the modal it handed off to (ScreenManager.handoff).
     While that child is open the parent stays open in the modal stack but its ScreenGui is
     hidden; when the child closes the parent shows again (and, being the top modal again, gets
     the gamepad selection back). E.g. Quests GO -> LuckyWheel: the wheel alone on screen, then
     Quests returns. ]]
local handoffs: { [string]: string } = {}
local BACK_ACTION = "SellNukesUIBack"
-- Modal bases occupy 20..34; the top modal is lifted to this order (below Toasts at 45).
local MODAL_FOREGROUND_ORDER = 39
local fallbackScreen: string? = nil
-- TV-safe insets in DEVICE POINTS (Platform/SafeArea, B16: 5 % on a ten-foot console, else 0).
local safeInsets = { left = 0, top = 0, right = 0, bottom = 0 }
local SAFE_AREA_NAME = "SafeArea"

-- Applies the TV-safe insets to one screen as a UIPadding (scaled by AutoScale, so the inset is
-- stored in design px = points / scale). Screens with `safeArea = false` are full-bleed.
local function applySafeArea(entry: Entry)
	if entry.module.safeArea == false then
		return
	end
	local padding = entry.gui:FindFirstChild(SAFE_AREA_NAME)
	if padding == nil then
		local created = Instance.new("UIPadding")
		created.Name = SAFE_AREA_NAME
		created.Parent = entry.gui
		padding = created
	end
	if padding ~= nil and padding:IsA("UIPadding") then
		local scale = math.max(ScreenManager.scale, 0.01)
		padding.PaddingLeft = UDim.new(0, safeInsets.left / scale)
		padding.PaddingTop = UDim.new(0, safeInsets.top / scale)
		padding.PaddingRight = UDim.new(0, safeInsets.right / scale)
		padding.PaddingBottom = UDim.new(0, safeInsets.bottom / scale)
	end
end
local lastLayoutKey = ""
local started = false

local function baseOrder(entry: Entry): number
	return entry.module.displayOrder or (if entry.module.modal then 20 else 5)
end

local function topModal(): Entry?
	local name = modalStack[#modalStack]
	return if name ~= nil then entries[name] else nil
end

-- Keeps the top modal drawn above every other modal (and below toasts).
local function refreshModalLayers()
	for _, name in modalStack do
		local entry = entries[name]
		entry.gui.DisplayOrder = baseOrder(entry)
	end
	local top = topModal()
	if top ~= nil and baseOrder(top) < MODAL_FOREGROUND_ORDER then
		top.gui.DisplayOrder = MODAL_FOREGROUND_ORDER
	end
end

--[[ True when `target` can take the gamepad selection inside `gui` right now (whole chain shown). ]]
local function canSelect(target: GuiObject?, gui: ScreenGui): boolean
	if
		target == nil
		or not target.Selectable
		or not target.Visible
		or not gui.Enabled
		or not target:IsDescendantOf(gui)
		or gui.Parent == nil
	then
		return false
	end
	local ancestor = target.Parent
	while ancestor ~= nil and ancestor ~= gui do
		if ancestor:IsA("GuiObject") and not ancestor.Visible then
			return false
		end
		ancestor = ancestor.Parent
	end
	return ancestor == gui
end

--[[ Puts the gamepad selection on the top modal's default control (Gamepad mode only). ]]
local function applySelection()
	local top = topModal()
	if top == nil then
		local current = GuiService.SelectedObject
		-- Leaving the last modal: drop a selection that pointed into a closed screen.
		if current ~= nil then
			local gui = current:FindFirstAncestorOfClass("ScreenGui")
			if gui == nil or not gui.Enabled then
				GuiService.SelectedObject = nil
			end
		end
		return
	end
	if InputController.mode ~= "Gamepad" then
		return
	end
	if canSelect(GuiService.SelectedObject, top.gui) then
		return
	end
	local selector = top.handle.defaultSelection
	local target = if selector ~= nil then selector() else nil
	GuiService.SelectedObject = if canSelect(target, top.gui) then target else nil
end

--[[
	One Back press while a modal is open (see header). A press that closed the modal is consumed
	(InputController.consumeInputPress) so nothing else acts on it.
	@return true when handled (the CAS handler sinks the press)
]]
local function handleBackKey(keyCode: Enum.KeyCode): boolean
	local press: PopupCloseRule.Press = {
		keyName = keyCode.Name,
		typing = UserInputService:GetFocusedTextBox() ~= nil,
		gameProcessed = false, -- ContextActionService never delivers a processed press
	}
	if PopupCloseRule.blocked(press) then
		return false
	end
	if not ScreenManager.closeTopModal() then
		return false
	end
	InputController.consumeInputPress(keyCode, nil)
	return true
end

local function onBack(_actionName: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	return if handleBackKey(input.KeyCode) then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
end

-- ── Device layout and touch helpers ─────────────────────────────────────────────────────────

--[[ True when the UI is laid out for a touch-screen DEVICE (phone / tablet). ]]
function ScreenManager.isTouchDevice(): boolean
	return ScreenManager.device.isTouch
end

--[[ True while the player is using touch right now (InputController mode "Touch"). ]]
function ScreenManager.touchMode(): boolean
	return InputController.mode == "Touch"
end

--[[ True when interactive elements must be finger-sized (touch device or Touch mode). ]]
function ScreenManager.touchTargets(): boolean
	return ScreenManager.device.isTouch or InputController.mode == "Touch"
end

--[[ Device points per design px (the resolution scale). ]]
function ScreenManager.pointScale(): number
	return ScreenManager.scale
end

--[[
	The design-px size of the area a ScreenGui covers (its safe area ÷ scale). Responsive layouts
	read this instead of gui.AbsoluteSize. A DISABLED ScreenGui keeps a stale AbsoluteSize (it
	stops updating while hidden: a lazy modal built before a resize / device switch reported the
	old desktop size on its first open), so only an enabled gui is measured; otherwise any
	enabled registered screen (they all share the same safe area) or the camera viewport is used.
	Example: local canvas = ScreenManager.canvasSize(gui)
]]
function ScreenManager.canvasSize(gui: ScreenGui?): Vector2
	local scale = math.max(ScreenManager.scale, 0.01)
	-- The TV-safe padding shrinks the usable area (design px).
	local inset = Vector2.new(safeInsets.left + safeInsets.right, safeInsets.top + safeInsets.bottom) / scale
	if gui ~= nil and gui.Enabled and gui.AbsoluteSize.X > 0 then
		return gui.AbsoluteSize / scale - inset
	end
	for _, entry in entries do
		local other = entry.gui
		if other.Enabled and other.Parent ~= nil and other.AbsoluteSize.X > 0 then
			return other.AbsoluteSize / scale - inset
		end
	end
	local device = ScreenManager.device
	return Vector2.new(device.viewportX, device.viewportY) / scale - inset
end

--[[
	The first design-px y below the Roblox top bar (menu / chat buttons), plus `margin`. Re-read
	it on SafeAreaChanged. Example: root.Position = UDim2.fromOffset(24, ScreenManager.safeTop(10))
]]
function ScreenManager.safeTop(margin: number?): number
	-- Measured from the TV-safe padded top edge (the padding already moved content down).
	local bar = GuiService.TopbarInset.Max.Y
	return math.max(0, bar - safeInsets.top) / math.max(ScreenManager.pointScale(), 0.01) + (margin or 0)
end

--[[
	Sets the TV-safe insets (DEVICE POINTS) every screen keeps clear (Platform/SafeArea, B16: a
	5 % margin on ten-foot consoles, zeros elsewhere; phone notches are DeviceSafeInsets already).
	Each registered ScreenGui, present and future, gets a "SafeArea" UIPadding (except modules
	with `safeArea = false`); canvasSize / safeTop account for it; layouts re-run.
	@param insets { left, top, right, bottom } in points (negative / NaN -> 0)
	Example: ScreenManager.setSafeInsets({ left = 48, top = 27, right = 48, bottom = 27 })
]]
function ScreenManager.setSafeInsets(insets: { left: number, top: number, right: number, bottom: number })
	local function clean(value: number): number
		return if value == value and value > 0 and value < math.huge then value else 0
	end
	local nextInsets = {
		left = clean(insets.left),
		top = clean(insets.top),
		right = clean(insets.right),
		bottom = clean(insets.bottom),
	}
	if
		nextInsets.left == safeInsets.left
		and nextInsets.top == safeInsets.top
		and nextInsets.right == safeInsets.right
		and nextInsets.bottom == safeInsets.bottom
	then
		return
	end
	safeInsets = nextInsets
	for _, entry in entries do
		applySafeArea(entry)
	end
	ScreenManager.SafeAreaChanged:Fire()
	ScreenManager.LayoutChanged:Fire()
end

--[[ Applies a resolution scale to every screen (UIController calls this on viewport changes). ]]
function ScreenManager.setScale(scale: number)
	if scale ~= scale or scale <= 0 or scale == ScreenManager.scale then
		return
	end
	ScreenManager.scale = scale
	-- The local stud bitmap picks its mip level from the on-screen tile size.
	StudTextureLocal.setScale(scale)
	for _, entry in entries do
		local autoScale = entry.gui:FindFirstChild("AutoScale")
		if autoScale ~= nil and autoScale:IsA("UIScale") then
			autoScale.Scale = scale
		end
		applySafeArea(entry)
	end
	ScreenManager.SafeAreaChanged:Fire()
end

--[[
	Feeds the real device profile (UIController: on start and on every viewport / input-device
	change). Fires LayoutChanged only when something a layout reads actually changed.
	Example: ScreenManager.setDeviceProfile(DeviceProfile.current())
]]
function ScreenManager.setDeviceProfile(profile: DeviceProfile.Profile)
	ScreenManager.device = profile
	ScreenManager.setScale(profile.uiScale)
	local key = `{profile.class}|{profile.viewportX}x{profile.viewportY}|{ScreenManager.scale}`
	if key ~= lastLayoutKey then
		lastLayoutKey = key
		ScreenManager.SafeAreaChanged:Fire()
		ScreenManager.LayoutChanged:Fire()
	end
end

--[[ Names of every registered screen, sorted. ]]
function ScreenManager.names(): { string }
	local names: { string } = {}
	for name in entries do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- ── Focus mode ──────────────────────────────────────────────────────────────────────────────

-- reason -> screens it hides.
local focusReasons: { [string]: { string } } = {}

-- True when an active focus reason hides `entry`'s screen (modals are never focus-hidden).
local function focusHides(entry: Entry): boolean
	if entry.module.modal then
		return false
	end
	for _, hidden in focusReasons do
		if table.find(hidden, entry.module.name) ~= nil then
			return true
		end
	end
	return false
end

--[[
	Applies an entry's visibility: shown when open and not focus-hidden. `fade` animates the
	change (focus transitions); open / close are instant.
]]
local function applyVisibility(entry: Entry, fade: boolean?)
	-- R79: a parent that handed off to a still-open child stays hidden until that child closes.
	local child = handoffs[entry.module.name]
	local handedOff = child ~= nil and entries[child] ~= nil and entries[child].open
	local shown = entry.open and not focusHides(entry) and not handedOff
	if fade then
		GuiFade.setShown(
			entry.gui,
			shown,
			if shown then HudFocusConfig.FadeInSeconds else HudFocusConfig.FadeOutSeconds
		)
	else
		GuiFade.cancel(entry.gui)
		entry.gui.Enabled = shown
	end
end

--[[
	Turns focus reason `reason` on (hiding `hidden` screens, default HudFocusConfig.DefaultHidden)
	or off (`hidden = nil` and `on = false`). Counted by reason: screens come back only when no
	reason hides them any more. Each change fades.
	Example:
		ScreenManager.setFocusReason("EggHatch", true, { "Hud" })
		ScreenManager.setFocusReason("EggHatch", false)
]]
function ScreenManager.setFocusReason(reason: string, on: boolean, hidden: { string }?)
	local wasOn = next(focusReasons) ~= nil
	if on then
		focusReasons[reason] = table.clone(hidden or (HudFocusConfig.DefaultHidden :: { string }))
	else
		focusReasons[reason] = nil
	end
	for _, entry in entries do
		if not entry.module.modal then
			applyVisibility(entry, true)
		end
	end
	local isOn = next(focusReasons) ~= nil
	if isOn ~= wasOn then
		ScreenManager.FocusChanged:Fire(isOn)
	end
end

--[[ True while any focus reason is active. ]]
function ScreenManager.isFocusMode(): boolean
	return next(focusReasons) ~= nil
end

-- ── Touch CLOSE fallback ─────────────────────────────────────────────────────────────────────

local touchClose: TextButton? = nil

-- The modal that needs the generic touch CLOSE button now, if any.
local function touchCloseTarget(): Entry?
	if InputController.mode ~= "Touch" then
		return nil
	end
	local top = topModal()
	if top == nil or top.module.closeOnBack == false then
		return nil
	end
	if top.gui:GetAttribute(ScreenManager.BackButtonAttribute) == true then
		return nil -- the screen draws its own close button (StudUI windows)
	end
	return top
end

--[[ Shows / moves / hides the touch CLOSE button inside the top modal's ScreenGui. ]]
local function refreshTouchClose()
	local target = touchCloseTarget()
	if target == nil then
		if touchClose ~= nil then
			touchClose.Visible = false
		end
		return
	end
	local button = touchClose
	if button == nil then
		local built = Components.button({
			text = "X",
			color = Theme.Colors.Danger,
			darkColor = Theme.Colors.DangerDark,
			size = UDim2.fromOffset(72, 72),
			name = "TouchClose",
			onActivated = function()
				ScreenManager.closeTopModal()
			end,
		})
		built.AnchorPoint = Vector2.new(1, 0.5)
		built.ZIndex = TouchUIConfig.Close.ZIndex
		built.Selectable = false -- touch only: never part of the gamepad selection graph
		LauncherStuds.attach(built)
		touchClose = built
		button = built
	end
	assert(button ~= nil, "touch close button")
	local bar = GuiService.TopbarInset
	local size, right, centerY = TouchLayout.closeLayout(ScreenManager.pointScale(), bar.Min.Y, bar.Height)
	button.Size = UDim2.fromOffset(size, size)
	button.TextSize = math.floor(size * 0.5)
	button.Position = UDim2.new(1, -right, 0, centerY)
	if not button:IsDescendantOf(target.gui) then
		button.Parent = target.gui
	end
	button.Visible = true
end

-- Re-applies menu-mode input after the modal stack changed.
local function refreshInputMode()
	local anyModal = #modalStack > 0
	InputController.setGameplayBlocked("Menus", anyModal)
	CameraController.setMouseFree(anyModal, "Menus")
	local top = topModal()
	CameraController.setMenuBlur(top ~= nil and top.module.blur ~= false, OfferFx.tier() ~= "Low")
	if anyModal then
		ContextActionService:BindActionAtPriority(
			BACK_ACTION,
			onBack,
			false,
			Enum.ContextActionPriority.High.Value,
			table.unpack(InputConfig.BackKeys)
		)
	else
		ContextActionService:UnbindAction(BACK_ACTION)
	end
	applySelection()
	refreshTouchClose()
end

-- ── Registration / building ──────────────────────────────────────────────────────────────────

-- Runs a screen's build (pcall + timing). Returns nil after a failed build (warned).
local function runBuild(module: ScreenModule, gui: ScreenGui): (ScreenHandle?, number)
	local startedAt = os.clock()
	local ok, handle = pcall(module.build, gui)
	local ms = (os.clock() - startedAt) * 1000
	if not ok then
		warn(`[ScreenManager] failed to build {module.name}: {handle}`)
		return nil, ms
	end
	return handle, ms
end

-- Builds a lazy screen now if needed. False when its build failed (the screen is dropped).
local function ensureBuilt(entry: Entry): boolean
	if entry.built or entry.building then
		return true
	end
	entry.building = true
	local handle, ms = runBuild(entry.module, entry.gui)
	entry.building = false
	entry.buildMs = ms
	if handle == nil then
		if entries[entry.module.name] == entry then
			entries[entry.module.name] = nil
		end
		entry.gui:Destroy()
		return false
	end
	entry.handle = handle
	entry.built = true
	return true
end

--[[
	Registers a screen module: builds it now (eager, the default), or for `lazy` screens only
	creates its empty ScreenGui and builds on first need. Errors in one screen never break others.
	@param module the ScreenModule
	@param parent the PlayerGui
]]
function ScreenManager.register(module: ScreenModule, parent: Instance)
	if type(module.name) ~= "string" or module.name == "" or type(module.build) ~= "function" then
		warn("[ScreenManager] invalid screen module")
		return
	end
	if entries[module.name] ~= nil then
		warn(`[ScreenManager] duplicate screen {module.name}`)
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = module.name
	gui.ResetOnSpawn = false
	-- Full-bleed screens start at the window's top edge (under the Roblox top bar; see safeTop)
	-- but stay out of a phone's notch / home-indicator strip (DeviceSafeInsets). Purely visual
	-- layers may still paint into the unsafe strips (ClipToDeviceSafeArea = false).
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
	gui.ClipToDeviceSafeArea = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = module.displayOrder or (if module.modal then 20 else 5)
	gui.Enabled = false
	local autoScale = Instance.new("UIScale")
	autoScale.Name = "AutoScale"
	autoScale.Scale = ScreenManager.scale
	autoScale.Parent = gui
	local entry: Entry = {
		module = module,
		gui = gui,
		handle = {},
		open = false,
		built = false,
		building = false,
		buildMs = 0,
	}
	if module.lazy == true and module.autoOpen ~= true then
		gui.Parent = parent
		applySafeArea(entry)
		entries[module.name] = entry
		return
	end
	local handle, ms = runBuild(module, gui)
	if handle == nil then
		gui:Destroy()
		return
	end
	entry.handle = handle
	entry.built = true
	entry.buildMs = ms
	gui.Parent = parent
	applySafeArea(entry)
	entries[module.name] = entry
	if module.autoOpen then
		ScreenManager.open(module.name)
	end
end

--[[
	Sets the screen that `open` shows for names that are not registered (args `{ requested }`).
	Example: ScreenManager.setFallback("ComingSoon")
]]
function ScreenManager.setFallback(name: string?)
	fallbackScreen = name
end

--[[ True if a screen is open. ]]
function ScreenManager.isOpen(name: string): boolean
	local entry = entries[name]
	return entry ~= nil and entry.open
end

--[[ True if a screen with this name is registered (built or still lazy). Never builds. ]]
function ScreenManager.isRegistered(name: string): boolean
	return entries[name] ~= nil
end

--[[ True if `name` is a registered modal screen. ]]
function ScreenManager.isModal(name: string): boolean
	local entry = entries[name]
	return entry ~= nil and entry.module.modal
end

--[[ True while any modal is open. ]]
function ScreenManager.anyModalOpen(): boolean
	return #modalStack > 0
end

--[[ Name of the modal on top of the stack, or nil. ]]
function ScreenManager.topModalName(): string?
	return modalStack[#modalStack]
end

--[[ True when `name` is the visible top modal (it owns modal shortcuts). ]]
function ScreenManager.isTopModal(name: string): boolean
	return modalStack[#modalStack] == name
end

--[[
	Opens a screen. An unknown name opens the fallback screen with `{ requested = name }`.
	Opening an already-open screen with `args` re-runs its onOpen(args) (refresh in place).
	@param name the screen name
	@param args optional table passed to the screen's onOpen
]]
function ScreenManager.open(name: string, args: any?)
	local entry = entries[name]
	if entry == nil then
		local fallback = fallbackScreen
		if fallback ~= nil and fallback ~= name and entries[fallback] ~= nil then
			ScreenManager.open(fallback, { requested = name })
		end
		return
	end
	if entry.open then
		local onOpen = entry.handle.onOpen
		if args ~= nil and onOpen ~= nil then
			local ok, err = pcall(onOpen, args)
			if not ok then
				warn(`[ScreenManager] {name}.onOpen error: {err}`)
			end
		end
		return
	end
	local firstBuild = not entry.built
	if not ensureBuilt(entry) then
		return
	end
	entry.open = true
	applyVisibility(entry)
	if entry.module.modal then
		table.insert(modalStack, name)
	end
	refreshModalLayers()
	local onOpen = entry.handle.onOpen
	if onOpen ~= nil then
		local ok, err = pcall(onOpen, args)
		if not ok then
			warn(`[ScreenManager] {name}.onOpen error: {err}`)
		end
	end
	refreshInputMode()
	ScreenManager.Opened:Fire(name)
	if firstBuild then
		-- A screen built just now may finish laying out next frame; re-apply the selection then.
		task.defer(function()
			if entry.open then
				applySelection()
			end
		end)
	end
end

--[[
	Owner R79: opens modal `to` FROM the open modal `from` as a handoff: `from` hides while `to` is
	open (it stays open underneath in the modal stack) and comes back by itself when `to` closes,
	with the gamepad selection re-applied to it. Used by hub-like windows whose buttons jump to
	another window (Quests GO / Nuke Pass OPEN -> Lucky Wheel, Pets, Shop, ...), so the player sees
	only the window they jumped to and returns to where they were.
	Falls back to a plain `open(to, args)` when `from` is not open, `to` is not a registered modal
	(non-modal screens and the ComingSoon fallback never hide the parent, so the player is never
	left on a blurred, input-blocked empty screen) or `to` was already open.
	@param from string — the open parent modal ("Quests")
	@param to string — the modal to open ("LuckyWheel")
	@param args any? — passed to `to`'s onOpen like ScreenManager.open
	Example: ScreenManager.handoff("Quests", "LuckyWheel", { source = "quests" })
]]
function ScreenManager.handoff(from: string, to: string, args: any?)
	local parent = entries[from]
	local child = entries[to]
	if from == to or parent == nil or not parent.open or child == nil or not child.module.modal or child.open then
		ScreenManager.open(to, args)
		return
	end
	ScreenManager.open(to, args)
	if child.open and parent.open then
		handoffs[from] = to
		applyVisibility(parent, true)
	end
end

--[[ R79: the modal `name` handed off to and is waiting on (nil when none) — QA / tests. ]]
function ScreenManager.handedOffTo(name: string): string?
	local child = handoffs[name]
	return if child ~= nil and entries[child] ~= nil and entries[child].open then child else nil
end

--[[ Closes a screen (no-op when closed / unknown). ]]
function ScreenManager.close(name: string)
	local entry = entries[name]
	if entry == nil or not entry.open then
		return
	end
	entry.open = false
	-- R79: a closing parent forgets its handoff (the child it opened stays open on its own).
	handoffs[name] = nil
	applyVisibility(entry)
	local index = table.find(modalStack, name)
	if index ~= nil then
		table.remove(modalStack, index)
	end
	entry.gui.DisplayOrder = baseOrder(entry)
	refreshModalLayers()
	-- R79: a closing child brings back the parent that handed off to it (before the selection is
	-- re-applied below, so the gamepad lands on the parent again).
	for parent, child in handoffs do
		if child == name then
			handoffs[parent] = nil
			local parentEntry = entries[parent]
			if parentEntry ~= nil and parentEntry.open then
				applyVisibility(parentEntry, true)
			end
		end
	end
	local onClose = entry.handle.onClose
	if onClose ~= nil then
		local ok, err = pcall(onClose)
		if not ok then
			warn(`[ScreenManager] {name}.onClose error: {err}`)
		end
	end
	ScreenManager.Closed:Fire(name)
	refreshInputMode()
end

--[[ Toggles a screen. ]]
function ScreenManager.toggle(name: string, args: any?)
	if ScreenManager.isOpen(name) then
		ScreenManager.close(name)
	else
		ScreenManager.open(name, args)
	end
end

--[[
	Closes the top modal (Back). A screen's onBack may handle the press itself (returns true).
	@return true when a modal was closed or its onBack handled the press
]]
function ScreenManager.closeTopModal(): boolean
	local top = topModal()
	if top == nil or top.module.closeOnBack == false then
		return false
	end
	local screenBack = top.handle.onBack
	if screenBack ~= nil then
		local ok, handled = pcall(screenBack)
		if ok and handled == true then
			return true
		end
	end
	ScreenManager.close(top.module.name)
	return true
end

--[[ Closes every modal screen (e.g. a teleport or cutscene). ]]
function ScreenManager.closeAllModals()
	for i = #modalStack, 1, -1 do
		ScreenManager.close(modalStack[i])
	end
end

--[[ The ScreenGui of a registered screen (a lazy screen is built first). ]]
function ScreenManager.getGui(name: string): ScreenGui?
	local entry = entries[name]
	if entry == nil or not ensureBuilt(entry) then
		return nil
	end
	return entry.gui
end

export type BuildStat = { lazy: boolean, built: boolean, ms: number }

--[[ Build bookkeeping per registered screen (tests / perf). ]]
function ScreenManager.buildStats(): { [string]: BuildStat }
	local stats: { [string]: BuildStat } = {}
	for name, entry in entries do
		stats[name] = { lazy = entry.module.lazy == true, built = entry.built, ms = entry.buildMs }
	end
	return stats
end

local prebuildStarted = false

--[[
	Builds every unbuilt `lazy` + `prebuild` screen during idle time, one per frame (no long
	hitch). Called once by UIController after boot; later calls are no-ops.
]]
function ScreenManager.prebuildIdle()
	if prebuildStarted then
		return
	end
	prebuildStarted = true
	task.spawn(function()
		local pending: { string } = {}
		for name, entry in entries do
			if entry.module.lazy == true and entry.module.prebuild == true and not entry.built then
				table.insert(pending, name)
			end
		end
		table.sort(pending)
		for _, name in pending do
			RunService.Heartbeat:Wait()
			local entry = entries[name]
			if entry ~= nil then
				ensureBuilt(entry)
			end
		end
	end)
end

--[[ Re-runs gamepad selection (screens call this after rebuilding their buttons). ]]
function ScreenManager.refreshSelection()
	applySelection()
end

--[[
	Wires device-switch handling (once; UIController calls it after registering screens):
		- input device switch: gamepad selection, the touch CLOSE button, LayoutChanged,
		- Roblox top bar resize: safe-area consumers and layouts re-place,
		- graphics tier change: the menu blur follows (off on Low).
]]
function ScreenManager.start()
	if started then
		return
	end
	started = true
	InputController.ModeChanged:Connect(function(mode)
		-- A finger has no selection cursor: drop the gamepad highlight when touch takes over.
		if mode == "Touch" then
			GuiService.SelectedObject = nil
		end
		applySelection()
		refreshTouchClose()
		ScreenManager.LayoutChanged:Fire()
	end)
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(function()
		ScreenManager.SafeAreaChanged:Fire()
		ScreenManager.LayoutChanged:Fire()
	end)
	OfferFx.Changed:Connect(function()
		local top = topModal()
		CameraController.setMenuBlur(top ~= nil and top.module.blur ~= false, OfferFx.tier() ~= "Low")
	end)
	ScreenManager.LayoutChanged:Connect(refreshTouchClose)
end

return ScreenManager
