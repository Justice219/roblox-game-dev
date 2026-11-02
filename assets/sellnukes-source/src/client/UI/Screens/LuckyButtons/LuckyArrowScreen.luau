--!strict
--[[
	LuckyArrowScreen — the on-screen pointer to the nearest Lucky Button (owner R69; spec §1.3:
	"an on-screen edge arrow to the nearest button (gamepad + touch friendly, TV-safe)").

	Behaviour (one PreRender connection, ONLY while a button is live):
		- off screen / behind the camera: a round stud chip (the kind's colour + the LuckyButton
		  icon) on the screen edge with an arrow glyph pointing at the button (behind = mirrored),
		- on screen and farther than ArrowNearStuds: the chip floats over the button, arrow down,
		- on screen and near (you can see it, you are about to walk in): hidden,
		- hidden while any modal window is open or the HUD is in focus mode, and during the
		  guided first-minute tutorial steps (Platform/JoinFlow.guiding, owner R78 §6: one arrow),
		- owner R102 popup queue (UI/Widgets/PopupQueue, kind "luckyArrow" in the chip channel):
		  hidden while a centre popup (reveal, Big Pop, banners, the plot reveal) is up; the edge
		  chip also steers around the objective chip / hint bar and the other chips' published
		  rects (the Happy Hours pill); the over-the-button chip hides where it would cover the
		  currency stack, the objective chip / hint bar or another chip.
	Placement maths is the pure LuckyButtonLogic.arrow: it stays inside the TV-safe area (this
	screen keeps ScreenManager's SafeArea padding), between the HUD's left and right columns
	(HudZones), ArrowInset from the edge, and on touch it is lifted out of Roblox's thumbstick
	and jump zones (Platform/LayoutLogic rects + ArrowTouchClearance).

	Non-modal, auto-open, discovered by UIController (a "...Screen" module in a Screens folder).
	Display only; nothing is selectable (it never steals the gamepad cursor).

	Connects to: Client/LuckyButtons/LuckyButtonClient (nearest / Changed), UI/{ScreenManager,
	Create, Kit/StudUI, Widgets/{StudWindow, HudZones, PopupQueue}}, Platform/LayoutLogic,
	Shared/Config/{LuckyButtonConfig, PlatformConfig}, Shared/Tycoon/LuckyButtonLogic.

	Example: (automatic) a button spawns → the chip appears at the edge pointing at it.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Create = require(script.Parent.Parent.Parent.Create)
local HudZones = require(script.Parent.Parent.Parent.Widgets.HudZones)
local JoinFlow = require(script.Parent.Parent.Parent.Parent.Platform.JoinFlow)
local LayoutLogic = require(script.Parent.Parent.Parent.Parent.Platform.LayoutLogic)
local LuckyButtonClient = require(script.Parent.Parent.Parent.Parent.LuckyButtons.LuckyButtonClient)
local LuckyButtonConfig = require(ReplicatedStorage.Shared.Config.LuckyButtonConfig)
local LuckyButtonLogic = require(ReplicatedStorage.Shared.Tycoon.LuckyButtonLogic)
local PlatformConfig = require(ReplicatedStorage.Shared.Config.PlatformConfig)
local PopupQueue = require(script.Parent.Parent.Parent.Widgets.PopupQueue)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)

local CFG = LuckyButtonConfig.Client
-- Studs above the button's ground point the arrow aims at (the cap / label).
local AIM_HEIGHT = 4
-- Gap (design px) kept between the chip and the HUD's left / right columns.
local HUD_GAP = 10
-- The "over the button" chip floats this far (design px) above the projected point.
local OVER_LIFT = 90
-- This chip's PopupQueue kind (owner R102 chip channel).
local CHIP_KIND = "luckyArrow"

-- One frame: places / hides the chip.
type View = {
	root: Frame,
	chip: Frame,
	surface: StudWindow.Surface,
	icon: Frame,
	pointer: Frame,
	iconKey: string,
}

-- The arrow glyph's natural direction is down (+90° in screen space): rotation offset.
local GLYPH_OFFSET = -90

return {
	name = "LuckyArrow",
	modal = false,
	autoOpen = true,
	displayOrder = 6,
	--[[
		Builds the chip (hidden) and the PreRender loop that runs only while a button is live.
		@param gui the screen's ScreenGui
		@return ScreenHandle (empty: nothing to select)
	]]
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		local root = Create.new("Frame", {
			Name = "LuckyArrowRoot",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			Parent = gui,
		}) :: Frame
		local size = CFG.ArrowSize
		local chip = Create.new("Frame", {
			Name = "Chip",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(size, size),
			Visible = false,
			Active = false,
			Selectable = false,
			Parent = root,
		}) :: Frame
		local surface =
			StudWindow.surface(chip, "yellow", { edge = 4, corner = math.floor(size / 2), highlight = true })
		local iconKey = if StudUI.hasIcon(CFG.Icon) then CFG.Icon else CFG.IconFallback
		local icon = StudUI.icon(iconKey, math.floor(size * 0.72), 3)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Parent = chip
		-- The pointer orbits the chip: a rotating square holder with the arrow glyph at its bottom.
		local pointer = Create.new("Frame", {
			Name = "Pointer",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(math.floor(size * 1.75), math.floor(size * 1.75)),
			BackgroundTransparency = 1,
			Active = false,
			Parent = chip,
		}) :: Frame
		local glyph = StudUI.icon("Arrow", math.floor(size * 0.5), 4)
		glyph.AnchorPoint = Vector2.new(0.5, 1)
		glyph.Position = UDim2.fromScale(0.5, 1)
		glyph.Parent = pointer
		local view: View = {
			root = root,
			chip = chip,
			surface = surface,
			icon = icon,
			pointer = pointer,
			iconKey = iconKey,
		}

		-- Zones to keep clear, in this screen's pixel space: the HUD's top stacks (currency, the
		-- phone top-right row), R102's reserved bottom strip (objective chip + hint bar) and the
		-- other chips' published rects, and, on touch, Roblox's thumbstick + jump zones.
		local function avoidRects(scale: number): { LuckyButtonLogic.Rect }
			local list: { LuckyButtonLogic.Rect } = {}
			local design: { PopupQueue.Rect } = PopupQueue.reservedRects()
			for _, name in { "Top", "TopRight" } do
				local zone = HudZones.rect(name :: any)
				if zone ~= nil then
					table.insert(design, zone)
				end
			end
			for _, other in PopupQueue.chipRects(CHIP_KIND) do
				table.insert(design, other)
			end
			for _, zone in design do
				table.insert(
					list,
					{ x = zone.x * scale, y = zone.y * scale, width = zone.w * scale, height = zone.h * scale }
				)
			end
			local camera = Workspace.CurrentCamera
			if not ScreenManager.touchMode() or camera == nil then
				return list
			end
			local viewport = camera.ViewportSize
			local shift = GuiService:GetGuiInset() + root.AbsolutePosition
			local zone = PlatformConfig.Touch.ThumbstickZone
			for _, rect in
				{
					LayoutLogic.jumpRect(viewport.X, viewport.Y, PlatformConfig.Touch.DefaultJump),
					LayoutLogic.thumbstickRect(viewport.X, viewport.Y, zone.width, zone.height),
				}
			do
				table.insert(list, { x = rect.x - shift.X, y = rect.y - shift.Y, width = rect.w, height = rect.h })
			end
			return list
		end

		-- One frame: hide, float over the button, or pin to the edge.
		local function step()
			local target = LuckyButtonClient.nearest()
			local camera = Workspace.CurrentCamera
			-- R78 §6: during the guided first-minute tutorial steps the only arrow is the tutorial's.
			if
				target == nil
				or camera == nil
				or ScreenManager.anyModalOpen()
				or ScreenManager.isFocusMode()
				or JoinFlow.guiding()
				or PopupQueue.chipsHidden()
			then
				chip.Visible = false
				return
			end
			-- The LuckyButton icon may arrive after the build (W1b): swap it in once.
			if view.iconKey ~= CFG.Icon and StudUI.hasIcon(CFG.Icon) then
				view.icon:Destroy()
				view.iconKey = CFG.Icon
				local fresh = StudUI.icon(CFG.Icon, math.floor(size * 0.72), 3)
				fresh.AnchorPoint = Vector2.new(0.5, 0.5)
				fresh.Position = UDim2.fromScale(0.5, 0.5)
				fresh.Parent = chip
				view.icon = fresh
			end
			if view.surface.color() ~= target.ui then
				view.surface.setColor(target.ui :: any)
			end
			local scale = math.max(ScreenManager.scale, 0.01)
			local aim = target.position + Vector3.new(0, AIM_HEIGHT, 0)
			local screen = camera:WorldToScreenPoint(aim)
			local origin = root.AbsolutePosition
			local canvas = root.AbsoluteSize
			local point = Vector2.new(screen.X, screen.Y) - origin
			local inFront = screen.Z > 0
			local inset = CFG.ArrowInset * scale
			local onScreen = inFront
				and point.X >= inset
				and point.X <= canvas.X - inset
				and point.Y >= inset
				and point.Y <= canvas.Y - inset
			if onScreen then
				local character = Players.LocalPlayer.Character
				local body = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
				local distance = if body ~= nil and body:IsA("BasePart")
					then (body.Position - target.position).Magnitude
					else math.huge
				if distance <= CFG.ArrowNearStuds then
					chip.Visible = false
					return
				end
				-- Over the button, pointing down at it (hidden where it would cover the HUD / a chip;
				-- the button itself is on screen then).
				local centerX, centerY = point.X / scale, point.Y / scale - OVER_LIFT
				local box = { x = centerX - size / 2, y = centerY - size / 2, w = size, h = size }
				if PopupQueue.chipBlockedAt(CHIP_KIND, box) then
					chip.Visible = false
					return
				end
				chip.Position = UDim2.fromOffset(centerX, centerY)
				pointer.Rotation = 90 + GLYPH_OFFSET
				chip.Visible = true
				return
			end
			-- Off screen: between the HUD columns, inside the safe area, out of the touch zones.
			local left, right = 0, 0
			local leftZone, rightZone = HudZones.rect("Left"), HudZones.rect("Right")
			if leftZone ~= nil then
				left = math.max(0, (leftZone.x + leftZone.w + HUD_GAP) * scale - inset + size * scale / 2)
			end
			if rightZone ~= nil then
				right = math.max(0, canvas.X - rightZone.x * scale + HUD_GAP * scale - inset + size * scale / 2)
			end
			if left + right + 2 * inset >= canvas.X then
				left, right = 0, 0 -- columns leave no room (tiny screens): use the full width
			end
			local place = LuckyButtonLogic.arrow({
				point = point,
				inFront = inFront,
				canvas = canvas,
				safe = { left = left, top = 0, right = right, bottom = 0 },
				inset = inset,
				avoid = avoidRects(scale),
				clearance = (CFG.ArrowTouchClearance + size / 2) * scale,
			})
			chip.Position = UDim2.fromOffset(place.position.X / scale, place.position.Y / scale)
			pointer.Rotation = place.rotation + GLYPH_OFFSET
			chip.Visible = true
		end

		local connection: RBXScriptConnection? = nil
		-- The loop runs only while a button is live.
		local function refresh()
			local want = LuckyButtonClient.count() > 0
			if want and connection == nil then
				connection = RunService.PreRender:Connect(step)
			elseif not want and connection ~= nil then
				(connection :: RBXScriptConnection):Disconnect()
				connection = nil
				chip.Visible = false
			end
		end
		LuckyButtonClient.Changed:Connect(refresh)
		refresh()
		return {}
	end,
} :: ScreenManager.ScreenModule
