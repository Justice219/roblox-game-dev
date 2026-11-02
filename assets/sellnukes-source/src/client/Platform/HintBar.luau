--!strict
--[[
	HintBar — bottom-centre button hints for the device in hand ("[RT] Make nukes  [X] Upgrade
	x10  [Y] Amount"), in the StudUI style (grey stud pill, white outlined labels).

	What it shows (ActionLogic.hints):
		- Keyboard / mouse: the contextual actions (near a producer, on a pad, ...).
		- Gamepad: the contextual actions, then idle navigation hints (◀ Menus, View Quick menu);
		  while a modal is open: "A Select · B Back" (+ "LB RB Tabs" on tabbed screens).
		- Touch: nothing — TouchButtons draws real buttons instead.
		- Focus mode (egg hatch, attack picker): hidden.
	Glyphs follow the device and family live (GlyphFamily: Xbox / PlayStation / keyboard).

	Placement: centred, just above the HUD objective chip (Widgets/HudZones "Bottom") when it is
	shown, else at the bottom margin; inside the TV-safe area (ScreenManager insets). While a
	modal is open the bar sits on the very bottom margin (windows keep that strip free).
	Published zone (owner R102): every placement / width change publishes the pill as HudZones
	"Hints" (canvas design px, like the other zones) and clears it while the bar is hidden, so
	popups (UI/Widgets/PopupQueue), the bottom-left feed and chips stay clear of it. Our own
	"Hints" publish never re-triggers this bar's HudZones.Changed handler (no feedback loop).

	Performance: re-renders only when the rendered signature (device, family, chips) changes;
	re-places on LayoutChanged / HudZones.Changed. No per-frame work.

	Connects to: Platform/{ActionMap, ActionLogic, GlyphFamily}, Shared/Config/PlatformConfig,
	UI/{ScreenManager, Kit/StudUI, Widgets/StudWindow, Widgets/HudZones},
	Controllers/InputController.

	Example (PlatformController):
		ScreenManager.register(HintBar.screen, playerGui)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionLogic = require(script.Parent.ActionLogic)
local ActionMap = require(script.Parent.ActionMap)
local Create = require(script.Parent.Parent.UI.Create)
local GlyphFamily = require(script.Parent.GlyphFamily)
local HudZones = require(script.Parent.Parent.UI.Widgets.HudZones)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.UI.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local Config = PlatformConfig.HintBar
local actions = PlatformConfig.Actions :: { [string]: PlatformConfig.Binding }

local HintBar = {}

-- The current chips (exposed for tests / QA through HintBar.current()).
local currentHints: { ActionLogic.Hint } = {}

--[[ The chips rendered right now (copy): action, text, keyCodes. ]]
function HintBar.current(): { ActionLogic.Hint }
	return table.clone(currentHints)
end

-- The hints for the current state (see the module header).
local function computeHints(): { ActionLogic.Hint }
	local device = InputController.mode :: ActionLogic.Device
	if device == "Touch" or ScreenManager.isFocusMode() then
		return {}
	end
	if ScreenManager.anyModalOpen() then
		if device ~= "Gamepad" then
			return {} -- keyboard players see the window's own [X] close chip
		end
		local hints: { ActionLogic.Hint } = {}
		if ActionMap.isActive("TabPrev") and ActionMap.isActive("TabNext") then
			table.insert(hints, {
				action = "Tabs",
				text = "Tabs",
				keyCodes = { actions.TabPrev.buttons[1], actions.TabNext.buttons[1] },
			})
		end
		for _, row in Config.MenuButtons do
			table.insert(hints, { action = row.text, text = row.text, keyCodes = { row.button } })
		end
		return hints
	end
	return ActionLogic.hints(actions, ActionMap.activeSet(), device, ActionMap.hintTexts(), Config.MaxHints)
end

-- A stable string for a hint list + device + family (skip identical re-renders).
local function signature(hints: { ActionLogic.Hint }): string
	local parts = { InputController.mode, GlyphFamily.family(), if ScreenManager.anyModalOpen() then "M" else "" }
	for _, hint in hints do
		local keys: { string } = {}
		for _, keyCode in hint.keyCodes do
			table.insert(keys, keyCode.Name)
		end
		table.insert(parts, `{table.concat(keys, "+")}={hint.text}`)
	end
	return table.concat(parts, "|")
end

-- The non-modal screen (registered by PlatformController through ScreenManager.register).
local screen: ScreenManager.ScreenModule = {
	name = "PlatformHints",
	modal = false,
	autoOpen = true,
	displayOrder = Config.DisplayOrder,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		local root = Create.new("Frame", {
			Name = "HintRoot",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			Parent = gui,
		}) :: Frame
		-- The pill: grey stud surface, auto width, chips in a row.
		local bar = Create.new("Frame", {
			Name = "HintBar",
			AnchorPoint = Vector2.new(0.5, 1),
			-- Width follows the chip row through StudUI.fitWidth below (AutomaticSize on a stud
			-- surface feeds back on its full-size decoration and grows too wide).
			Size = UDim2.fromOffset(200, Config.Height + 12),
			Active = false,
			Visible = false,
			Parent = root,
		}) :: Frame
		StudWindow.surface(bar, "grey", {
			tile = UIStyleConfig.StudTile.Button,
			studTransparency = UIStyleConfig.StudTransparency.Button,
			edge = 3,
			corner = math.floor((Config.Height + 12) / 2),
		})
		local row = Create.new("Frame", {
			Name = "Chips",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(0, 1),
			AutomaticSize = Enum.AutomaticSize.X,
			ZIndex = 3,
			Parent = bar,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, Config.Gap),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				Create.new("UIPadding", {
					PaddingLeft = UDim.new(0, 16),
					PaddingRight = UDim.new(0, 18),
				}),
			},
		}) :: Frame
		-- The pill hugs the chip row (event-driven; capped well inside the 1080p canvas).
		StudUI.fitWidth(bar, row, 0, Config.MaxWidth)

		local lastSignature = ""

		-- Builds one chip: glyph(s) then the label.
		local function chip(hint: ActionLogic.Hint, order: number): Frame
			local frame = Create.new("Frame", {
				Name = `Hint_{hint.action}`,
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(0, Config.Height),
				AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = order,
				ZIndex = 3,
				Children = {
					Create.new("UIListLayout", {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, 6),
						SortOrder = Enum.SortOrder.LayoutOrder,
					}),
				},
			}) :: Frame
			for index, keyCode in hint.keyCodes do
				local glyph = GlyphFamily.glyph(keyCode, Config.GlyphHeight)
				glyph.LayoutOrder = index
				glyph.ZIndex = 4
				for _, child in glyph:GetDescendants() do
					if child:IsA("GuiObject") then
						child.ZIndex = 4
					end
				end
				glyph.Parent = frame
			end
			StudUI.text({
				name = "Label",
				text = hint.text,
				textSize = Config.TextSize,
				autoWidth = true,
				size = UDim2.fromOffset(0, Config.Height),
				layoutOrder = 10,
				zIndex = 4,
				parent = frame,
			})
			return frame
		end

		-- True while this bar is publishing its own "Hints" zone (HudZones.Changed fires
		-- synchronously: the handler below ignores it, so publishing never loops back into place).
		local publishingHints = false

		-- Publishes the pill as HudZones "Hints" (design px; nil while the bar is hidden).
		local function publishHints()
			local rect: HudZones.Rect? = nil
			if bar.Visible then
				local width, height = bar.Size.X.Offset, bar.Size.Y.Offset
				rect = {
					x = bar.Position.X.Offset - width / 2,
					y = bar.Position.Y.Offset - height,
					w = width,
					h = height,
				}
			end
			publishingHints = true
			HudZones.set("Hints", rect)
			publishingHints = false
		end

		-- Places the bar above the objective chip (or the bottom margin).
		local function place()
			local canvas = ScreenManager.canvasSize(gui)
			local bottom = canvas.Y - Config.Margin
			if not ScreenManager.anyModalOpen() then
				local zone = HudZones.rect("Bottom")
				if zone ~= nil and zone.h > 0 then
					bottom = math.min(bottom, zone.y - Config.Margin)
				end
			end
			bar.Position = UDim2.fromOffset(math.floor(canvas.X / 2), math.floor(bottom))
			publishHints()
		end

		-- Re-renders when the signature changed (see the module header).
		local function render()
			local hints = computeHints()
			local sig = signature(hints)
			if sig == lastSignature then
				return
			end
			lastSignature = sig
			currentHints = hints
			for _, child in row:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			for index, hint in hints do
				chip(hint, index).Parent = row
			end
			bar.Visible = #hints > 0
			place() -- also publishes / clears the "Hints" zone
		end

		ActionMap.Changed:Connect(render)
		InputController.ModeChanged:Connect(render)
		GlyphFamily.Changed:Connect(function()
			lastSignature = "" -- same chips, different glyph images
			render()
		end)
		ScreenManager.Opened:Connect(render)
		ScreenManager.Closed:Connect(render)
		ScreenManager.FocusChanged:Connect(render)
		ScreenManager.LayoutChanged:Connect(place)
		HudZones.Changed:Connect(function()
			if not publishingHints then
				place()
			end
		end)
		-- StudUI.fitWidth resizes the pill after its chips laid out: keep the zone's width true.
		bar:GetPropertyChangedSignal("Size"):Connect(publishHints)
		render()
		return {}
	end,
}
HintBar.screen = screen

return HintBar
