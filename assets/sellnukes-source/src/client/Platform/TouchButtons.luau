--!strict
--[[
	TouchButtons — big StudUI buttons for the contextual actions on phones and tablets (TAP! to
	make nukes, UPGRADE / BUY, the x1 / x10 / MAX amount, HATCH), placed around Roblox's jump
	button where the right thumb already rests.

	When: Touch mode only, no modal open, not in focus mode, and only the actions ActionMap says
	are active (ActionLogic.touchButtons: Produce near a manual producer, Interact near a
	producer / on a pad, UpgradeMode near a producer, Hatch at an egg stand). Captions follow the
	live hint text ("UPGRADE X10", "BUY $1.2K").

	Sizes: PlatformConfig.Touch.Sizes in DEVICE POINTS (large 72 / normal 60 / small 48 pt — all
	≥ the 44 pt minimum tap) converted to design px with TouchLayout.pointsToDesign, so a button
	measures the same under a finger on every phone.

	Placement (LayoutLogic.placeTouchButtons): an arc around the real jump button
	(PlayerGui.TouchGui.TouchControlFrame.JumpButton, read on layout events; Roblox's default
	geometry when it is missing), never over the jump button, the thumbstick zone or the HUD
	button / offer columns (Widgets/HudZones); the objective chip is avoided when possible.

	Press: ActionMap.tap(action) (the same InputController path as a key press) + a light
	Haptics "Tap". Buttons are never gamepad-selectable (touch only).

	Performance: buttons are rebuilt only when the visible set / captions change, re-placed on
	LayoutChanged / HudZones.Changed / jump-button geometry changes. No per-frame work.

	Connects to: Platform/{ActionMap, ActionLogic, LayoutLogic, Haptics}, Shared/Config/
	{PlatformConfig, TouchUIConfig}, Shared/Util/TouchLayout, UI/{ScreenManager, Kit/StudUI,
	Widgets/HudZones}, Controllers/InputController.

	Tutorial focus (owner R84): `TouchButtons.button(action)` returns the live button instance of
	a shown action and `TouchButtons.Changed` fires when the shown set changes, so the tutorial
	(Tycoon/TutorialHighlight) can ring the real TAP! / UPGRADE control and point its arrow at it.

	Example (PlatformController):
		ScreenManager.register(TouchButtons.screen, playerGui)
		print(TouchButtons.current()) --> { { action = "Produce", rect = {...} }, ... }
		local tap = TouchButtons.button("Produce") -- nil unless TAP! is on screen
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionLogic = require(script.Parent.ActionLogic)
local ActionMap = require(script.Parent.ActionMap)
local Create = require(script.Parent.Parent.UI.Create)
local Haptics = require(script.Parent.Haptics)
local HudZones = require(script.Parent.Parent.UI.Widgets.HudZones)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local LayoutLogic = require(script.Parent.LayoutLogic)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)

local Config = PlatformConfig.Touch
local actions = PlatformConfig.Actions :: { [string]: PlatformConfig.Binding }

local TouchButtons = {}

--[[
	Owner R84: fires () after the set of on-screen buttons changed (a button was built, rebuilt
	or removed; never on a mere re-placement). Tycoon/TutorialHighlight listens so the tutorial
	arrow + highlight ring move onto the TAP! / UPGRADE button the moment it appears.
]]
TouchButtons.Changed = Signal.new() :: Signal.Signal<>

export type Placed = { action: string, label: string, rect: LayoutLogic.Rect }

-- What is on screen now (TouchButtons.current(): QA / tests).
local currentPlaced: { Placed } = {}

-- action -> its live on-screen button instance (TouchButtons.button; owner R84 tutorial focus).
local liveButtons: { [string]: GuiObject } = {}

--[[
	The live on-screen button of an action while it is shown, else nil (R84: the tutorial rings
	the real TAP! / UPGRADE control and points its arrow at it). Read-only use: callers may parent
	decorations under it (destroyed with it) but must not move or resize it.
	Example: local tap = TouchButtons.button("Produce")
]]
function TouchButtons.button(action: string): GuiObject?
	local instance = liveButtons[action]
	if instance ~= nil and instance.Parent ~= nil then
		return instance
	end
	return nil
end

--[[ The buttons on screen right now (copy). ]]
function TouchButtons.current(): { Placed }
	return table.clone(currentPlaced)
end

-- Roblox's touch controls while they are SHOWN (nil until the PlayerModule builds them on a
-- touch device, and nil while hidden: a TouchGui left behind by a device switch keeps stale
-- geometry).
local function touchControlFrame(): Instance?
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local touchGui = if playerGui ~= nil then playerGui:FindFirstChild("TouchGui") else nil
	if touchGui == nil or not touchGui:IsA("ScreenGui") or not touchGui.Enabled then
		return nil
	end
	local frame = touchGui:FindFirstChild("TouchControlFrame")
	if frame == nil or not frame:IsA("GuiObject") or not frame.Visible then
		return nil
	end
	return frame
end

-- One on-screen button: a HUD-style icon tile (spec.icon) or a plain stud button (text only).
type Record = {
	instance: TextButton,
	spec: PlatformConfig.TouchSpec,
	side: number,
	setLabel: (text: string) -> (),
	setSide: (side: number) -> (),
	destroy: () -> (),
}

--[[
	Builds one touch button. Icon actions use the HUD tile look (StudUI.hudButton: icon on top,
	auto-fitting label — the same family as the HUD's left column); text-only actions (the x1 /
	x10 / MAX amount) use a StudUI.button. Never gamepad-selectable (touch only).
]]
local function makeButton(
	action: string,
	label: string,
	spec: PlatformConfig.TouchSpec,
	side: number,
	parent: Instance,
	onPress: () -> ()
): Record
	if spec.icon ~= nil then
		local tile = StudUI.hudButton({
			name = `Touch_{action}`,
			label = label,
			icon = spec.icon,
			color = spec.color :: any,
			size = Vector2.new(side, side),
			parent = parent,
			onActivated = onPress,
		})
		tile.instance.Selectable = false
		local record: Record
		record = {
			instance = tile.instance,
			spec = spec :: PlatformConfig.TouchSpec,
			side = side,
			setLabel = tile.setLabel,
			setSide = function(newSide: number)
				record.side = newSide
				tile.setSize(newSide, newSide)
			end,
			destroy = tile.Destroy,
		}
		return record
	end
	local button = StudUI.button({
		name = `Touch_{action}`,
		text = label,
		color = spec.color :: any,
		size = UDim2.fromOffset(side, side),
		textSize = math.floor(side * Config.TextRatio * 1.4),
		parent = parent,
		onActivated = onPress,
	})
	button.instance.Selectable = false
	local record: Record
	record = {
		instance = button.instance,
		spec = spec :: PlatformConfig.TouchSpec,
		side = side,
		setLabel = button.setText,
		setSide = function(newSide: number)
			record.side = newSide
			button.instance.Size = UDim2.fromOffset(newSide, newSide)
		end,
		destroy = button.Destroy,
	}
	return record
end

-- A live GuiObject's rect in design px relative to `origin` (our full-size root frame).
local function rectOf(object: GuiObject, origin: GuiObject, scale: number): LayoutLogic.Rect
	local position = (object.AbsolutePosition - origin.AbsolutePosition) / scale
	local size = object.AbsoluteSize / scale
	return { x = position.X, y = position.Y, w = size.X, h = size.Y }
end

-- The shown thumbstick frame (classic or dynamic), if any.
local function thumbstickFrame(frame: Instance?): GuiObject?
	if frame == nil then
		return nil
	end
	for _, name in { "DynamicThumbstickFrame", "ThumbstickFrame" } do
		local child = frame:FindFirstChild(name)
		if child ~= nil and child:IsA("GuiObject") and child.Visible and child.AbsoluteSize.X > 0 then
			return child
		end
	end
	return nil
end

local screen: ScreenManager.ScreenModule = {
	name = "PlatformTouch",
	modal = false,
	autoOpen = true,
	displayOrder = Config.DisplayOrder,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		local root = Create.new("Frame", {
			Name = "TouchRoot",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			Visible = false,
			Parent = gui,
		}) :: Frame

		-- action -> its on-screen button
		local buttons: { [string]: Record } = {}
		local shown: { ActionLogic.TouchButton } = {}
		local lastSignature = ""
		local watchedJump: GuiObject? = nil
		local jumpConnections: { RBXScriptConnection } = {}

		-- Side of a size class in design px (≥ the minimum tap target).
		local function sideFor(size: PlatformConfig.TouchSize): number
			local points = math.max(Config.Sizes[size], TouchUIConfig.MinTapPoints)
			return TouchLayout.pointsToDesign(points, ScreenManager.pointScale())
		end

		-- Places every shown button (see the module header).
		local function place()
			if #shown == 0 or not root.Visible then
				currentPlaced = {}
				return
			end
			local scale = math.max(ScreenManager.pointScale(), 0.01)
			local canvas = ScreenManager.canvasSize(gui)
			local frame = touchControlFrame()
			local jumpObject = if frame ~= nil then frame:FindFirstChild("JumpButton") else nil
			local jump: LayoutLogic.Rect
			if jumpObject ~= nil and jumpObject:IsA("GuiObject") and jumpObject.AbsoluteSize.X > 0 then
				jump = rectOf(jumpObject, root, scale)
			else
				local pts = LayoutLogic.jumpRect(canvas.X * scale, canvas.Y * scale, Config.DefaultJump)
				jump = { x = pts.x / scale, y = pts.y / scale, w = pts.w / scale, h = pts.h / scale }
			end
			local reserved: { LayoutLogic.Rect } = {}
			-- "TopRight" = the phone row of the less-used HUD buttons (owner R59; nil elsewhere).
			for _, zone in { "Left", "Right", "Top", "TopRight" } do
				local rect = HudZones.rect(zone :: HudZones.ZoneName)
				if rect ~= nil then
					table.insert(reserved, rect)
				end
			end
			local stick = thumbstickFrame(frame)
			if stick ~= nil then
				table.insert(reserved, rectOf(stick, root, scale))
			else
				local zone = Config.ThumbstickZone
				table.insert(reserved, LayoutLogic.thumbstickRect(canvas.X, canvas.Y, zone.width, zone.height))
			end
			local sizes: { number } = {}
			for index, entry in shown do
				sizes[index] = sideFor(entry.spec.size)
			end
			local margin = Config.EdgeMargin / scale
			local gap = Config.Gap / scale
			-- Pass 1 also avoids the objective chip; pass 2 may cover it (tiny phones).
			local hard = table.clone(reserved)
			local bottomZone = HudZones.rect("Bottom")
			if bottomZone ~= nil then
				table.insert(reserved, bottomZone)
			end
			local input: LayoutLogic.PlaceInput = {
				canvasX = canvas.X,
				canvasY = canvas.Y,
				jump = jump,
				sizes = sizes,
				reserved = reserved,
				gap = gap,
				margin = margin,
			}
			local rects = LayoutLogic.placeTouchButtons(input)
			-- Any rect that fell back onto a reserved rect: retry without the chip.
			local clean = true
			for _, rect in rects do
				for _, other in reserved do
					if LayoutLogic.overlaps(rect, other) then
						clean = false
					end
				end
			end
			if not clean and bottomZone ~= nil then
				input.reserved = hard
				rects = LayoutLogic.placeTouchButtons(input)
			end
			local placed: { Placed } = {}
			for index, entry in shown do
				local rect = rects[index]
				local record = buttons[entry.action]
				if record ~= nil then
					record.instance.Position = UDim2.fromOffset(rect.x, rect.y)
					if record.side ~= rect.w then
						record.setSide(rect.w)
					end
				end
				table.insert(placed, { action = entry.action, label = entry.label, rect = rect })
			end
			currentPlaced = placed
		end

		-- Follows the live jump button's geometry (it moves when the PlayerModule rebuilds it).
		local function watchJump()
			local frame = touchControlFrame()
			local jumpObject = if frame ~= nil then frame:FindFirstChild("JumpButton") else nil
			local object: GuiObject? = if jumpObject ~= nil and jumpObject:IsA("GuiObject") then jumpObject else nil
			if object == watchedJump then
				return
			end
			for _, connection in jumpConnections do
				connection:Disconnect()
			end
			table.clear(jumpConnections)
			watchedJump = object
			if object ~= nil then
				table.insert(jumpConnections, object:GetPropertyChangedSignal("AbsolutePosition"):Connect(place))
				table.insert(jumpConnections, object:GetPropertyChangedSignal("AbsoluteSize"):Connect(place))
				table.insert(
					jumpConnections,
					object.Destroying:Connect(function()
						task.defer(watchJump)
					end)
				)
			end
		end

		-- Rebuilds the button set when it changed; always refreshes visibility + placement.
		local function render()
			local visible = InputController.mode == "Touch"
				and not ScreenManager.anyModalOpen()
				and not ScreenManager.isFocusMode()
			local list = if visible
				then ActionLogic.touchButtons(actions, ActionMap.activeSet(), ActionMap.hintTexts())
				else {}
			local parts: { string } = {}
			for _, entry in list do
				table.insert(parts, `{entry.action}={entry.label}`)
			end
			local sig = table.concat(parts, "|")
			if sig ~= lastSignature then
				lastSignature = sig
				local keep: { [string]: boolean } = {}
				for _, entry in list do
					keep[entry.action] = true
					local record = buttons[entry.action]
					if record == nil or record.spec ~= entry.spec then
						if record ~= nil then
							record.destroy()
						end
						local action = entry.action
						buttons[action] = makeButton(
							action,
							entry.label,
							entry.spec,
							sideFor(entry.spec.size),
							root,
							function()
								if ActionMap.tap(action :: any) then
									Haptics.play("Tap")
								end
							end
						)
					else
						record.setLabel(entry.label)
					end
				end
				for action, record in buttons do
					if not keep[action] then
						record.destroy()
						buttons[action] = nil
					end
				end
				shown = list
				-- R84: publish the live instances, then tell listeners (tutorial focus).
				table.clear(liveButtons)
				for action, record in buttons do
					liveButtons[action] = record.instance
				end
				TouchButtons.Changed:Fire()
			end
			root.Visible = #shown > 0
			watchJump()
			place()
		end

		ActionMap.Changed:Connect(render)
		InputController.ModeChanged:Connect(render)
		ScreenManager.Opened:Connect(render)
		ScreenManager.Closed:Connect(render)
		ScreenManager.FocusChanged:Connect(render)
		ScreenManager.LayoutChanged:Connect(function()
			-- Sizes are in points: a scale change re-sizes every button (place() applies them).
			render()
		end)
		HudZones.Changed:Connect(place)
		-- Roblox builds the TouchGui lazily (first touch / device switch): follow its arrival.
		local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if playerGui ~= nil then
			playerGui.ChildAdded:Connect(function(child: Instance)
				if child.Name == "TouchGui" then
					task.defer(render)
				end
			end)
		end
		render()
		return {}
	end,
}
TouchButtons.screen = screen

-- Exposes the actions that have a touch spec (docs / tests).
function TouchButtons.touchActions(): { string }
	local names: { string } = {}
	for name, binding in actions do
		if binding.touch ~= nil then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

return TouchButtons
