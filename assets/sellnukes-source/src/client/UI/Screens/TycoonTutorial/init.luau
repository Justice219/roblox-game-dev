--!strict
--[[
	TycoonTutorial — the tutorial COACH CARD a new player sees once, at tutorial step 1 (queued by
	Tycoon/Tutorial through Platform/JoinFlow: after the loading screen, the plot reveal and any
	Welcome Back).

	R78 first-minute fix (owner R78 §6; live day 2026-10-31: 6 of 20 new players left before the
	free Workbench pad, 3 of 7 console players). The card used to be a big MODAL window: it
	blurred the world, paused a gamepad player's character (ScreenManager menu mode), took the
	gamepad cursor and needed a LET'S GO press before anyone could move — and its three steps
	were in the wrong order ("1. Click the Workbench" while the Workbench did not exist yet; the
	real first step is walking onto its pad). Now it is a compact NON-modal strip:
		- three small numbered stud tiles in the order the tutorial really runs: walk onto glowing
		  pads → make nukes (with the device's control: "Press RT", "Tap TAP!", "Click or press
		  F") → upgrade & hire managers (Tycoon/TutorialText.coach),
		- a short strip (124 design px) under the top currency stack and the boost chips
		  (HudZones "Top" / "Boosts"), between the HUD's left grid and offer column, scaled down
		  to fit (phones); when the Workbench pad is under it on screen it moves to the other
		  side of that band (Studio QA 2026-10-31: a centred card hid the pad on a phone); never
		  over the thumbstick / jump corners or the bottom objective chip,
		- never selectable, never sinks input, never pauses the character: the player can walk
		  to the pad while reading it,
		- leaves by itself: FtueConfig.Coach.AfterMoveSeconds after the first real move
		  (Tycoon/FtueTracker.Moved), at the latest MaxSeconds, never before MinSeconds; and at
		  once when the tutorial leaves step 1 (Tycoon/Tutorial closes it).
		Slides in from the top (Reduced Motion: appears in place).

	Connects to: Kit/StudUI, UI/{Create, ScreenManager}, Widgets/{HudZones, OfferFx},
	Controllers/InputController, Platform/GlyphFamily, Tycoon/{Tutorial (keys + closes it),
	TutorialText, FtueTracker}, Shared/Config/FtueConfig.

	Example: ScreenManager.open("TycoonTutorial")   -- normally Tycoon/Tutorial via JoinFlow
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Create = require(script.Parent.Parent.Create)
local FtueConfig = require(ReplicatedStorage.Shared.Config.FtueConfig)
local FtueTracker = require(script.Parent.Parent.Parent.Tycoon.FtueTracker)
local GlyphFamily = require(script.Parent.Parent.Parent.Platform.GlyphFamily)
local HudZones = require(script.Parent.Parent.Widgets.HudZones)
local InputController = require(script.Parent.Parent.Parent.Controllers.InputController)
local OfferFx = require(script.Parent.Parent.Widgets.OfferFx)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local Tutorial = require(script.Parent.Parent.Parent.Tycoon.Tutorial)
local TutorialText = require(script.Parent.Parent.Parent.Tycoon.TutorialText)

local NAME = "TycoonTutorial"
local Coach = FtueConfig.Coach

-- Card geometry (design px at 1080p; scaled down with a UIScale when the free width is smaller).
-- Compact on purpose (Studio QA 2026-10-31): a taller card hid the Workbench pad on phones.
local CARD_WIDTH = 760
local CARD_HEIGHT = 124
local TILE_WIDTH = 240
local TILE_HEIGHT = 104
local ICON_SIZE = 56
-- Gap kept to the HUD's left grid / offer column / currency stack.
local HUD_GAP = 12
-- Design px kept between the card and the tutorial target's on-screen spot (the Workbench pad).
local TARGET_CLEARANCE = 60
-- The card never shrinks below this share of its design size.
local MIN_SCALE = 0.45
-- Top offset when the HUD has not published its zones yet.
local FALLBACK_TOP = 190
-- Slide-in.
local SLIDE = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- The three tiles: icon key and colour (texts from TutorialText.coach).
local TILES: { { icon: string, color: StudUI.ColorName } } = {
	{ icon = "Cash", color = "yellow" },
	{ icon = "Nuke", color = "green" },
	{ icon = "Arrow", color = "sky" },
}

local screen: ScreenManager.ScreenModule = {
	name = NAME,
	modal = false,
	autoOpen = false,
	-- Above the HUD (5), below the plot-reveal banner (15) and every window (20+).
	displayOrder = 14,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		-- Layout root: positioned + scaled to the free band under the currency stack.
		local holder = Create.new("Frame", {
			Name = "CoachHolder",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, FALLBACK_TOP),
			Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT),
			Parent = gui,
		}) :: Frame
		local fit = Create.new("UIScale", { Scale = 1, Parent = holder }) :: UIScale
		-- A thin stud strip holding the three tiles (no title bar: the numbers say the order).
		local card = StudUI.card({
			name = "Coach",
			color = "grey",
			size = UDim2.fromScale(1, 1),
			parent = holder,
		})
		local row = Create.new("Frame", {
			Name = "Tiles",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -16, 0, TILE_HEIGHT),
			ZIndex = 4,
			Parent = card.content,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, 10),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		local captions: { TextLabel } = {}
		for index, tile in TILES do
			local tileCard = StudUI.card({
				color = tile.color,
				size = UDim2.fromOffset(TILE_WIDTH, TILE_HEIGHT),
				layoutOrder = index,
				parent = row,
			})
			-- Step number (top-left) over the icon (left), caption on the right.
			local icon = StudUI.icon(tile.icon, ICON_SIZE, 3)
			icon.AnchorPoint = Vector2.new(0, 0.5)
			icon.Position = UDim2.new(0, 10, 0.5, 6)
			icon.Parent = tileCard.content
			StudUI.text({
				text = `{index}`,
				textSize = 26,
				position = UDim2.fromOffset(8, 2),
				size = UDim2.fromOffset(28, 30),
				zIndex = 5,
				parent = tileCard.content,
			})
			captions[index] = StudUI.text({
				text = "",
				textSize = 24,
				wrap = true,
				position = UDim2.fromOffset(ICON_SIZE + 18, 4),
				size = UDim2.new(1, -(ICON_SIZE + 24), 1, -8),
				zIndex = 4,
				parent = tileCard.content,
			})
		end
		-- Display only: nothing may take the gamepad cursor or sink a tap / click.
		for _, descendant in holder:GetDescendants() do
			if descendant:IsA("GuiObject") then
				descendant.Selectable = false
				descendant.Active = false
			end
		end

		local isOpen = false
		local openToken = 0
		local openedAt = 0
		local connections: { any } = {}

		-- Tile captions for the device in the player's hands.
		local function renderTexts()
			local keys = Tutorial.keys()
			for index, label in captions do
				label.Text = TutorialText.coach(index, InputController.mode, keys)
			end
		end

		-- The rest y (design px): under the currency stack and the boost chips under it (R-social's
		-- "Boosts" zone, when published), else the fallback.
		local function restY(): number
			local y = FALLBACK_TOP
			local top = HudZones.rect("Top")
			if top ~= nil then
				y = top.y + top.h + HUD_GAP
			end
			local boosts = HudZones.rect("Boosts" :: any)
			if boosts ~= nil then
				y = math.max(y, boosts.y + boosts.h + HUD_GAP)
			end
			return y
		end

		-- The tutorial target's on-screen x in design px (nil when off screen / none).
		local function targetX(canvas: Vector2): number?
			local target = Tutorial.hintTarget()
			local camera = Workspace.CurrentCamera
			if target == nil or camera == nil or camera.ViewportSize.X <= 0 then
				return nil
			end
			local point, onScreen = camera:WorldToViewportPoint(target.Position)
			if not onScreen then
				return nil
			end
			return point.X * canvas.X / camera.ViewportSize.X
		end

		--[[
			Places + scales the card into the free band between the HUD's left and right columns,
			centred; when the tutorial target (the Workbench pad) would sit under it, the card moves
			to the other side of the band (shrinking to fit, never below MIN_SCALE) so the pad
			stays visible (Studio QA 2026-10-31: centred, it hid the pad on a phone). Runs on open
			and on HUD layout changes only (the card leaves after the first move).
		]]
		local function layout()
			local canvas = ScreenManager.canvasSize(gui)
			local y = restY()
			local leftEdge, rightEdge = 0, canvas.X
			local left = HudZones.rect("Left")
			if left ~= nil and left.y < y + CARD_HEIGHT then
				leftEdge = left.x + left.w + HUD_GAP
			end
			local right = HudZones.rect("Right")
			if right ~= nil and right.y < y + CARD_HEIGHT then
				rightEdge = right.x - HUD_GAP
			end
			-- Centred on the screen: the free half-width is the smaller distance to either column.
			local centre = canvas.X / 2
			local halfFree = math.min(centre - leftEdge, rightEdge - centre)
			local scale = math.clamp((2 * halfFree) / CARD_WIDTH, MIN_SCALE, 1)
			local width = CARD_WIDTH * scale
			local x = targetX(canvas)
			if x ~= nil and x > centre - width / 2 - TARGET_CLEARANCE and x < centre + width / 2 + TARGET_CLEARANCE then
				-- Target under the centred card: use the band on the far side of it.
				local fromX, toX = leftEdge, x - TARGET_CLEARANCE
				if x < centre then
					fromX, toX = x + TARGET_CLEARANCE, rightEdge
				end
				local sideScale = math.min(scale, (toX - fromX) / CARD_WIDTH)
				if sideScale >= MIN_SCALE then
					scale = sideScale
					centre = (fromX + toX) / 2
				end
			end
			fit.Scale = scale
			holder.Position = UDim2.fromOffset(centre, y)
		end

		-- Closes the card if `token` is still the open one.
		local function closeIf(token: number)
			if isOpen and token == openToken then
				ScreenManager.close(NAME)
			end
		end

		-- Leaves AfterMoveSeconds after the first move, never before MinSeconds after opening.
		local function onMoved()
			local token = openToken
			local wait = math.max(Coach.AfterMoveSeconds, Coach.MinSeconds - (os.clock() - openedAt))
			task.delay(wait, closeIf, token)
		end

		table.insert(
			connections,
			InputController.ModeChanged:Connect(function()
				if isOpen then
					renderTexts()
				end
			end)
		)
		table.insert(
			connections,
			GlyphFamily.Changed:Connect(function()
				if isOpen then
					renderTexts()
				end
			end)
		)
		table.insert(
			connections,
			HudZones.Changed:Connect(function()
				if isOpen then
					layout()
				end
			end)
		)
		table.insert(
			connections,
			ScreenManager.LayoutChanged:Connect(function()
				if isOpen then
					layout()
				end
			end)
		)
		table.insert(
			connections,
			FtueTracker.Moved:Connect(function()
				if isOpen then
					onMoved()
				end
			end)
		)
		gui.Destroying:Once(function()
			for _, connection in connections do
				connection:Disconnect()
			end
		end)

		return {
			onOpen = function()
				isOpen = true
				openToken += 1
				openedAt = os.clock()
				renderTexts()
				layout()
				local token = openToken
				task.delay(Coach.MaxSeconds, closeIf, token)
				if FtueTracker.hasMoved() then
					onMoved()
				end
				-- Slide in from above the screen (Reduced Motion: in place).
				if not OfferFx.reducedMotion() then
					local target = holder.Position
					holder.Position = UDim2.fromOffset(target.X.Offset, -CARD_HEIGHT)
					TweenService:Create(holder, SLIDE, { Position = target }):Play()
				end
			end,
			onClose = function()
				isOpen = false
				openToken += 1
			end,
		}
	end,
}

return screen
