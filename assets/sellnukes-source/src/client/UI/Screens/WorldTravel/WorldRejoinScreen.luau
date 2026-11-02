--!strict
--[[
	WorldRejoinScreen — the "Back to Dino Valley? [GO] [X]" chip (owner R57 World 2, spec §4.6).

	Rejoin always starts in the Nuke Town lobby (owner R13 lobby + R16 reveal stay untouched). When
	the last session ended in another world (profile.lastWorld), Worlds/WorldClient opens this
	small bottom chip after the plot reveal, at a polite moment, once per session:
		[world icon]  Back to Dino Valley?   [GO (Y)]  [X]
	GO sends the travel intent (WorldClient.travel(world, "spawn", nil, "chip"); the server
	validates everything); X dismisses; it hides itself after WorldClientConfig.Rejoin.Seconds.

	Input (owner R11): mouse / touch tap GO or X (both >= 44 pt); gamepad Y = GO (bound through
	ContextActionService at the UI priority only while the chip shows, so it never steals Y
	afterwards). Non-modal: the player keeps moving; it sits above the objective chip (HudZones
	"Bottom") and the device hint bar on top of it, clear of the thumbstick / jump zones and
	inside the TV-safe area. It also never covers the left button grid or the right offer column
	(HudZones "Left" / "Right"): when the one-row chip does not fit between them (phones), it
	stacks into two rows (text over GO / X) inside that gap, and only as a last resort shrinks
	(RejoinLayout below; the buttons keep >= 44 pt on every shipped device).

	Connects to: Worlds/{WorldClient, WorldClientLogic}, UI/{ScreenManager, Create, Kit/StudUI},
	Widgets/{HudZones, StudWindow, InputGlyph}, Shared/Config/{WorldClientConfig, PlatformConfig,
	Worlds/WorldsConfig}.

	Example: ScreenManager.open("WorldRejoin", { worldId = "dino" }) -- normally WorldClient does it
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local HudZones = require(script.Parent.Parent.Parent.Widgets.HudZones)
local InputGlyph = require(script.Parent.Parent.Parent.Widgets.InputGlyph)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local WorldClient = require(script.Parent.Parent.Parent.Parent.Worlds.WorldClient)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldClientLogic = require(script.Parent.Parent.Parent.Parent.Worlds.WorldClientLogic)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local NAME = WorldClient.RejoinScreen
local ACTION = "SellNukes_WorldRejoinGo"
-- One-row chip (design px): [icon] text [GO] [X].
local CHIP_SIZE = Vector2.new(720, 96)
-- Two-row chip (narrow screens): [icon] text over [GO] [X]; MIN = narrowest before shrinking.
local STACKED_HEIGHT = 184
local STACKED_MIN_WIDTH = 440
-- Gap (design px) above the objective chip's zone and beside the left / right HUD zones.
local GAP = 14

return {
	name = NAME,
	modal = false,
	autoOpen = false,
	lazy = true,
	displayOrder = 7,
	build = function(gui: ScreenGui): any
		local chip = Create.new("Frame", {
			Name = "RejoinChip",
			BackgroundColor3 = Color3.fromRGB(34, 40, 56),
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -170),
			Size = UDim2.fromOffset(CHIP_SIZE.X, CHIP_SIZE.Y),
			Parent = gui,
		}) :: Frame
		local surface = StudWindow.surface(chip, "green", { edge = 5, corner = 16 })
		-- The world's tab icon, built once per icon key (World 3 gets its own automatically).
		local icons: { [string]: Frame } = {}
		local function showIcon(key: string)
			if icons[key] == nil then
				local icon = StudUI.icon(key, 76, 3)
				icon.AnchorPoint = Vector2.new(0, 0.5)
				icon.Position = UDim2.new(0, 12, 0.5, 0)
				icon.Parent = chip
				icons[key] = icon
			end
			for other, frame in icons do
				frame.Visible = other == key
			end
		end
		local label = StudUI.text({
			text = "",
			textSize = 34,
			scaled = true,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(100, 14),
			size = UDim2.new(1, -360, 0, CHIP_SIZE.Y - 28),
			zIndex = 3,
			parent = chip,
		})
		-- The first extra world until onOpen names one (R70: never a hard-coded world).
		local firstExtra = WorldsConfig.extra()[1]
		local worldId = if firstExtra ~= nil then firstExtra.id else WorldsConfig.MAIN
		local generation = 0

		local function close()
			ScreenManager.close(NAME)
		end
		local function goNow()
			close()
			WorldClient.travel(worldId, "spawn", nil, "chip")
		end
		local goButton = StudUI.button({
			text = "GO",
			color = "green",
			size = UDim2.fromOffset(150, 72),
			textSize = 34,
			position = UDim2.new(1, -100, 0.5, 0),
			anchor = Vector2.new(1, 0.5),
			name = "Go",
			parent = chip,
			onActivated = goNow,
		})
		-- The gamepad Y glyph on the GO button (shown only with a gamepad: InputGlyph.dynamic).
		local glyph = InputGlyph.dynamic(nil, Enum.KeyCode.ButtonY, 34)
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromOffset(4, 4)
		glyph.ZIndex = 9
		glyph.Parent = goButton.instance
		local closeButton = StudUI.button({
			text = "X",
			color = "red",
			size = UDim2.fromOffset(72, 72),
			textSize = 34,
			position = UDim2.new(1, -14, 0.5, 0),
			anchor = Vector2.new(1, 0.5),
			name = "Dismiss",
			parent = chip,
			onActivated = close,
		})
		goButton.instance.NextSelectionRight = closeButton.instance;
		(closeButton.instance :: any).NextSelectionLeft = goButton.instance
		-- Shrinks the whole chip only when even the stacked layout does not fit (last resort).
		local chipScale = Create.new("UIScale", { Scale = 1, Parent = chip }) :: UIScale

		--[[
			Lays the chip out one-row (`width` = CHIP_SIZE.X) or stacked (`width` = the gap between
			the HUD zones): sizes, label box and button anchors. Icons sit in the text row.
		]]
		local function layout(stacked: boolean, width: number)
			if stacked then
				chip.Size = UDim2.fromOffset(width, STACKED_HEIGHT)
				label.Position = UDim2.fromOffset(100, 12)
				label.Size = UDim2.new(1, -114, 0, 76)
				for _, icon in icons do
					icon.Position = UDim2.fromOffset(12, 50)
				end
				goButton.instance.AnchorPoint = Vector2.new(1, 1)
				goButton.instance.Position = UDim2.new(0.5, -8, 1, -14)
				closeButton.instance.AnchorPoint = Vector2.new(0, 1)
				closeButton.instance.Position = UDim2.new(0.5, 8, 1, -14)
			else
				chip.Size = UDim2.fromOffset(CHIP_SIZE.X, CHIP_SIZE.Y)
				label.Position = UDim2.fromOffset(100, 14)
				label.Size = UDim2.new(1, -360, 0, CHIP_SIZE.Y - 28)
				for _, icon in icons do
					icon.Position = UDim2.new(0, 12, 0.5, 0)
				end
				goButton.instance.AnchorPoint = Vector2.new(1, 0.5)
				goButton.instance.Position = UDim2.new(1, -100, 0.5, 0)
				closeButton.instance.AnchorPoint = Vector2.new(1, 0.5)
				closeButton.instance.Position = UDim2.new(1, -14, 0.5, 0)
			end
		end

		-- Sits above the objective chip (HudZones "Bottom") AND the device hint bar that sits on
		-- top of it (Platform/HintBar: Margin + Height), else a fixed bottom offset; horizontally
		-- inside the gap between the left button grid and the right offer column (HudZones
		-- "Left" / "Right") wherever they reach the chip's rows.
		local hintReserve = PlatformConfig.HintBar.Margin + PlatformConfig.HintBar.Height + GAP
		local function place()
			local canvas = ScreenManager.canvasSize(gui)
			local bottom = HudZones.rect("Bottom")
			local baseY = if bottom ~= nil then bottom.y - hintReserve else canvas.Y - (170 + hintReserve)
			local centreX = if bottom ~= nil then bottom.x + bottom.w / 2 else canvas.X / 2
			-- The free band at the chip's rows (the stacked height covers both layouts).
			local rowTop = baseY - STACKED_HEIGHT
			local leftEdge, rightEdge = 0, math.max(canvas.X, 1)
			local left = HudZones.rect("Left")
			if left ~= nil and left.y < baseY and left.y + left.h > rowTop then
				leftEdge = left.x + left.w + GAP
			end
			local right = HudZones.rect("Right")
			if right ~= nil and right.y < baseY and right.y + right.h > rowTop then
				rightEdge = right.x - GAP
			end
			local band = rightEdge - leftEdge
			local plan = WorldClientLogic.chipLayout(band, CHIP_SIZE.X, STACKED_MIN_WIDTH)
			layout(plan.stacked, plan.width)
			chipScale.Scale = plan.scale
			-- Centred on the objective chip when that fits in the band, else in the band.
			local half = plan.width * plan.scale / 2
			local x = if band > 0
				then math.clamp(centreX, leftEdge + half, math.max(leftEdge + half, rightEdge - half))
				else centreX
			chip.AnchorPoint = Vector2.new(0.5, 1)
			chip.Position = UDim2.fromOffset(x, baseY)
		end
		ScreenManager.LayoutChanged:Connect(function()
			if ScreenManager.isOpen(NAME) then
				place()
			end
		end)
		HudZones.Changed:Connect(place)

		-- Gamepad Y = GO while the chip shows (UI priority; Pass for every other key / state).
		local function onY(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			goNow()
			return Enum.ContextActionResult.Sink
		end

		return {
			onOpen = function(args: any?)
				generation += 1
				local gen = generation
				local requested = if type(args) == "table" then args.worldId else nil
				worldId = if type(requested) == "string" and WorldsConfig.get(requested) ~= nil
					then requested
					else worldId
				local def = WorldsConfig.get(worldId)
				local style = WorldClientLogic.style(worldId)
				label.Text = WorldClientLogic.fill(
					WorldClientConfig.Rejoin.Text,
					{ world = if def ~= nil then def.name else style.label }
				)
				surface.setColor(style.color :: any)
				showIcon(style.icon)
				place()
				ContextActionService:BindActionAtPriority(
					ACTION,
					onY,
					false,
					PlatformConfig.Priority.Ui,
					Enum.KeyCode.ButtonY
				)
				task.delay(WorldClientConfig.Rejoin.Seconds, function()
					if gen == generation and ScreenManager.isOpen(NAME) then
						close()
					end
				end)
			end,
			onClose = function()
				generation += 1
				ContextActionService:UnbindAction(ACTION)
			end,
		}
	end,
}
