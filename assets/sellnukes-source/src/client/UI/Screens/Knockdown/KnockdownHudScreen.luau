--!strict
--[[
	KnockdownHudScreen ("KnockdownHud") — the target's HUD chip for a temporary area knockdown
	(owner R50): "Your LAB got knocked down! Rebuilding 0:45" + [TAP TO REBUILD!].

	Non-modal, auto-open, always built (no lazy build), so the chip appears the moment the server's
	`KnockdownState` arrives. It only shows while one of YOUR areas is down. Every tap / H key / LT
	press sends one `KnockdownTap(area)` intent (the server moves the rebuild 1 s earlier, never
	before 6 s after the hit, rate-limited to 6 / s). The client keeps to that rate itself
	(KnockdownConfig.Client.TapInterval), so held or mashed inputs never get refused. Two areas
	down → both names, and the area that rebuilds first is the one tapped.

	Placement (owner R11): bottom centre, stacked ABOVE the Attack HUD chips (Revenge / free shield)
	and the platform hint bar (both read from their live screens, so whatever they show is
	respected) and the HUD's bottom zone;
	TV-safe through ScreenManager.canvasSize; on touch devices the button is at least 44 pt
	(TouchLayout.pointsToDesign) and the chip grows with it. The input glyph follows the device
	(InputGlyph.dynamic: [H] on keyboard, LT on gamepad, hidden on touch). Bindings are active only
	while the chip is visible and no modal window is open.

	Boot: also starts Tycoon/BuildIn/KnockdownFx (idempotent) so the knockdown FX runs even before
	the client boot list lists it.

	Connects to: Shared/Net/Remotes (KnockdownState S→C, KnockdownTap C→S), Shared/Config/
	KnockdownConfig, Shared/Tycoon/KnockdownLogic (clock), UI/{ScreenManager, Create, Kit/StudUI,
	Widgets/{HudZones, InputGlyph, StudWindow}}, Shared/Util/TouchLayout, Tycoon/BuildIn/KnockdownFx.

	Example: (auto-open) — the chip appears on its own when your area is knocked down.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Create = require(script.Parent.Parent.Parent.Create)
local HudZones = require(script.Parent.Parent.Parent.Widgets.HudZones)
local InputGlyph = require(script.Parent.Parent.Parent.Widgets.InputGlyph)
local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local KnockdownFx = require(script.Parent.Parent.Parent.Parent.Tycoon.BuildIn.KnockdownFx)
local KnockdownLogic = require(ReplicatedStorage.Shared.Tycoon.KnockdownLogic)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)

local NAME = "KnockdownHud"
local ACTION = "SN_KnockdownHud_Rebuild"
local BINDING = KnockdownConfig.Client.Keys.Rebuild
local CHIP_WIDTH = 900
local CHIP_HEIGHT = 120
local BUTTON_WIDTH = 350
local BUTTON_HEIGHT = 84
local BUTTON_TEXT = 30
local CHIP_GAP = 14
-- Design px above the bottom zone (or the canvas bottom when the HUD has no bottom chip).
local BOTTOM_MARGIN = 150
-- Countdown refresh period while the chip is up (no per-frame work).
local TICK_SECONDS = 0.25
-- Bottom-centre HUD pieces we stack above (by ScreenGui → root frame): the Attack HUD's chips
-- (Screens/AttackTarget/AttackHudScreen) and the platform hint bar (Platform/HintBar).
local STACK_ABOVE: { { gui: string, root: string } } = {
	{ gui = "AttackHud", root = "AttackHudRoot" },
	{ gui = "PlatformHints", root = "HintRoot" },
}

type Row = { area: number, untilTime: number, appliedAt: number }

-- A finite number, else nil.
local function finite(value: unknown): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

--[[
	Validates a KnockdownState payload (only the server sends it, still checked defensively).
	@return { Row } sorted by rebuild time, number immuneUntil
]]
local function parseState(payload: unknown): ({ Row }, number)
	local rows: { Row } = {}
	if type(payload) ~= "table" then
		return rows, 0
	end
	local data = payload :: { [string]: any }
	local areas = data.areas
	if type(areas) == "table" then
		for index, raw in areas :: { any } do
			if type(index) ~= "number" or index > #KnockdownConfig.AreaLabels or type(raw) ~= "table" then
				continue
			end
			local area = finite(raw.area)
			local untilTime = finite(raw.untilTime)
			local appliedAt = finite(raw.appliedAt)
			if
				area ~= nil
				and area == math.floor(area)
				and area >= 1
				and area <= #KnockdownConfig.AreaLabels
				and untilTime ~= nil
				and appliedAt ~= nil
			then
				table.insert(rows, { area = area, untilTime = untilTime, appliedAt = appliedAt })
			end
		end
	end
	table.sort(rows, function(a: Row, b: Row): boolean
		return a.untilTime < b.untilTime
	end)
	return rows, finite(data.immuneUntil) or 0
end

local module: ScreenManager.ScreenModule = {
	name = NAME,
	modal = false,
	autoOpen = true,
	displayOrder = 6,
	lazy = false,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		KnockdownFx.Start()

		local rows: { Row } = {}
		local lastTap = 0

		local root = Create.new("Frame", {
			Name = "KnockdownHudRoot",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(1920, 1080),
			Parent = gui,
		}) :: Frame

		local chip = Create.new("Frame", {
			Name = "KnockdownChip",
			AnchorPoint = Vector2.new(0.5, 1),
			Size = UDim2.fromOffset(CHIP_WIDTH, CHIP_HEIGHT),
			Visible = false,
			Parent = root,
		}) :: Frame
		StudWindow.surface(chip, "red", { edge = 4, tile = 0 })
		local title = StudUI.text({
			text = "",
			textSize = 34,
			align = Enum.TextXAlignment.Left,
			scaled = true,
			position = UDim2.fromOffset(22, 10),
			size = UDim2.new(1, -(BUTTON_WIDTH + 96), 0.56, -10),
			zIndex = 4,
			parent = chip,
		})
		local timer = StudUI.text({
			text = "",
			textSize = 28,
			align = Enum.TextXAlignment.Left,
			scaled = true,
			position = UDim2.new(0, 22, 0.56, 0),
			size = UDim2.new(1, -(BUTTON_WIDTH + 96), 0.24, 0),
			zIndex = 4,
			parent = chip,
		})
		-- Rebuild progress (fills as the area comes back).
		local bar = StudUI.progressBar({
			color = "yellow",
			size = UDim2.new(1, -(BUTTON_WIDTH + 110), 0, 14),
			parent = chip,
		})
		bar.frame.AnchorPoint = Vector2.new(0, 1)
		bar.frame.Position = UDim2.new(0, 24, 1, -12)
		bar.frame.ZIndex = 4

		-- One tap intent (client-throttled to the server's rate; the server re-checks everything).
		local function tap()
			local first = rows[1]
			local now = os.clock()
			if first == nil or now - lastTap < KnockdownConfig.Client.TapInterval then
				return
			end
			lastTap = now
			Remotes.event("KnockdownTap"):FireServer(first.area)
		end

		local button = StudUI.button({
			text = "TAP TO REBUILD!",
			textSize = BUTTON_TEXT,
			color = "green",
			size = UDim2.fromOffset(BUTTON_WIDTH, BUTTON_HEIGHT),
			anchor = Vector2.new(1, 0.5),
			position = UDim2.new(1, -66, 0.5, 0),
			parent = chip,
			onActivated = tap,
		})
		local glyph = InputGlyph.dynamic(BINDING.keys[1], BINDING.pads[1], 40)
		glyph.AnchorPoint = Vector2.new(1, 0.5)
		glyph.Position = UDim2.new(1, -14, 0.5, 0)
		glyph.ZIndex = 5
		glyph.Parent = chip

		-- Keys bound only while the chip is up (and no modal is open at press time).
		local bound = false
		local function setBound(on: boolean)
			if bound == on then
				return
			end
			bound = on
			if not on then
				ContextActionService:UnbindAction(ACTION)
				return
			end
			local inputs: { Enum.KeyCode } = {}
			for _, key in BINDING.keys do
				table.insert(inputs, key)
			end
			for _, key in BINDING.pads do
				table.insert(inputs, key)
			end
			ContextActionService:BindAction(
				ACTION,
				function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
					if state ~= Enum.UserInputState.Begin or ScreenManager.anyModalOpen() or not chip.Visible then
						return Enum.ContextActionResult.Pass
					end
					tap()
					return Enum.ContextActionResult.Sink
				end,
				false,
				table.unpack(inputs)
			)
		end

		-- The top (design px) of the visible bottom-centre HUD pieces we stack above, or nil.
		local function obstaclesTop(): number?
			local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
			if playerGui == nil then
				return nil
			end
			local top: number? = nil
			for _, entry in STACK_ABOVE do
				local other = playerGui:FindFirstChild(entry.gui)
				local otherRoot = if other ~= nil then other:FindFirstChild(entry.root) else nil
				if otherRoot == nil or (other :: Instance):IsA("ScreenGui") and not (other :: ScreenGui).Enabled then
					continue
				end
				for _, child in (otherRoot :: Instance):GetChildren() do
					if child:IsA("GuiObject") and child.Visible then
						local y = child.Position.Y.Offset - child.AnchorPoint.Y * child.Size.Y.Offset
						top = if top == nil then y else math.min(top, y)
					end
				end
			end
			return top
		end

		-- Sizes for touch (≥ 44 pt button) + stacks the chip above the HUD / Attack chips.
		local function layout()
			local canvas = ScreenManager.canvasSize(gui)
			if canvas.X <= 0 or canvas.Y <= 0 then
				return
			end
			root.Size = UDim2.fromOffset(canvas.X, canvas.Y)
			local buttonHeight = BUTTON_HEIGHT
			if ScreenManager.touchTargets() then
				buttonHeight = math.max(
					BUTTON_HEIGHT,
					TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, ScreenManager.pointScale())
				)
			end
			local width = math.min(CHIP_WIDTH, canvas.X - 32)
			chip.Size = UDim2.fromOffset(width, math.max(CHIP_HEIGHT, buttonHeight + 24))
			button.instance.Size = UDim2.fromOffset(BUTTON_WIDTH, buttonHeight)
			local bottomZone = HudZones.rect("Bottom")
			local y = if bottomZone ~= nil then bottomZone.y - CHIP_GAP else canvas.Y - BOTTOM_MARGIN
			local otherTop = obstaclesTop()
			if otherTop ~= nil then
				y = math.min(y, otherTop - CHIP_GAP)
			end
			chip.Position = UDim2.fromOffset(canvas.X / 2, y)
		end

		-- Re-reads the rows into the chip (labels, countdown, progress, visibility, bindings).
		local function refresh()
			local now = Workspace:GetServerTimeNow()
			for i = #rows, 1, -1 do
				if rows[i].untilTime <= now then
					table.remove(rows, i)
				end
			end
			local first = rows[1]
			local visible = first ~= nil
			if first ~= nil then
				local labels: { string } = {}
				for _, row in rows do
					table.insert(labels, KnockdownConfig.areaLabel(row.area))
				end
				title.Text = `Your {table.concat(labels, " + ")} got knocked down!`
				timer.Text = `Rebuilding {KnockdownLogic.formatClock(first.untilTime - now)}`
				local total = math.max(first.untilTime - first.appliedAt, 1)
				bar.setProgress(1 - KnockdownLogic.remaining(first.untilTime, now) / total)
			end
			chip.Visible = visible
			setBound(visible)
			layout()
		end

		task.spawn(function()
			Remotes.event("KnockdownState").OnClientEvent:Connect(function(payload: unknown)
				rows = (parseState(payload))
				refresh()
			end)
		end)
		HudZones.Changed:Connect(layout)
		ScreenManager.LayoutChanged:Connect(layout)
		-- Countdown: a few updates a second, only while the chip is up.
		task.spawn(function()
			while true do
				task.wait(TICK_SECONDS)
				if chip.Visible then
					refresh()
				end
			end
		end)
		return {
			onOpen = function()
				task.defer(refresh)
			end,
		}
	end,
}

return module
