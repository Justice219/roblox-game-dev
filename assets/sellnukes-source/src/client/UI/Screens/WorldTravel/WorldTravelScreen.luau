--!strict
--[[
	WorldTravelScreen — the warp overlay of a world trip (owner R57 World 2, spec §4.5 / §14).

	What it shows:
		A full-bleed stud cover (dark violet studs, past the TV-safe padding) with a spinning stud
		swirl (three counter-rotating rings of stud tiles), a ticking clock in the middle and the
		destination's name card (world icon + "DINO VALLEY" + tagline). Same-world hops (a Dino
		area from inside Dino Valley) show the cover + clock only.
		Reduce Motion: a plain fade (nothing spins or pops).

	Lifecycle (driven by Worlds/WorldClient, never by input):
		WorldTravel "out"   WorldClient opens this screen ({ worldId, hop, source }) -> fade + pop in
		                    + the warp whoosh (AudioConfig "warp_whoosh", a real recording played
		                    at its natural pitch: no pitch override)
		WorldTravel "in"    WorldClient.Phase -> stays at least Overlay.MinSeconds in total, then
		                    warps in (card shrinks, cover fades, a second whoosh on a world
		                    change) and closes
		WorldTravel "fail"  WorldClient closes it (and toasts the reason)
		safety              closes itself after Overlay.MaxSeconds whatever happens
	It is a MODAL (gameplay input blocked while warping: controls are disabled during the warp),
	closeOnBack = false (B never cancels a trip), no blur (the cover hides the world anyway).

	Analytics (W12, rule 9): each open reports ClientAnalytics.screenOpened("WorldTravel", source)
	(source from WorldClient: "hud" / "popup" / "chip" / "portal").

	Performance: every Instance is built once (lazy + prebuild); one PreRender connection exists
	only while the overlay animates (full motion) and disconnects on close.

	Connects to: Worlds/{WorldClient, WorldClientLogic}, UI/{ScreenManager, Create, Kit/StudUI},
	Widgets/{PanelBackdrop, OfferFx, StudWindow}, Audio/Sound, Analytics/ClientAnalytics,
	Shared/Config/{WorldClientConfig, Worlds/WorldsConfig}.

	Example: ScreenManager.open("WorldTravel", { worldId = "dino" }) -- normally WorldClient does it
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ClientAnalytics = require(script.Parent.Parent.Parent.Parent.Analytics.ClientAnalytics)
local Create = require(script.Parent.Parent.Parent.Create)
local OfferFx = require(script.Parent.Parent.Parent.Widgets.OfferFx)
local PanelBackdrop = require(script.Parent.Parent.Parent.Widgets.PanelBackdrop)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local Sound = require(script.Parent.Parent.Parent.Parent.Audio.Sound)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local WorldClient = require(script.Parent.Parent.Parent.Parent.Worlds.WorldClient)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldClientLogic = require(script.Parent.Parent.Parent.Parent.Worlds.WorldClientLogic)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local NAME = WorldClient.TravelScreen
local Overlay = WorldClientConfig.Overlay
-- Design px of the swirl / clock / card (centred; the UIScale of the screen scales them).
local SWIRL_SIZE = 760
local CLOCK_SIZE = 220
local CARD_SIZE = Vector2.new(760, 170)
-- Design px between the card and the screen's bottom edge.
local CARD_MARGIN = 30
-- Three rings of stud tiles: radius share, tile count, tile px, turn direction / speed share.
local RINGS = {
	{ radius = 0.48, count = 18, tile = 46, speed = 1 },
	{ radius = 0.36, count = 14, tile = 40, speed = -1.4 },
	{ radius = 0.25, count = 10, tile = 34, speed = 1.9 },
}
-- Stud tile colours (warm candy tones; owner R19: no blown-out neon).
local TILE_COLORS = {
	Color3.fromRGB(255, 196, 64),
	Color3.fromRGB(120, 210, 255),
	Color3.fromRGB(170, 120, 255),
	Color3.fromRGB(120, 230, 120),
}
local COVER_COLOR = Color3.fromRGB(28, 20, 54)
-- The warp sound (AudioConfig.Sfx; a real recording, played at its natural pitch).
local WHOOSH = "warp_whoosh"

return {
	name = NAME,
	modal = true,
	closeOnBack = false,
	blur = false,
	safeArea = false,
	lazy = true,
	prebuild = true,
	displayOrder = Overlay.DisplayOrder,
	build = function(gui: ScreenGui): any
		-- Full-bleed cover (over-filled past every inset so the world is fully hidden).
		local cover = Create.new("TextButton", {
			Name = "Cover",
			Text = "",
			AutoButtonColor = false,
			Selectable = false,
			BackgroundColor3 = COVER_COLOR,
			BackgroundTransparency = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1.25, 1.25),
			ZIndex = 0,
			Parent = gui,
		}) :: TextButton
		-- Swallows taps (non-interactive overlay); never plays button feedback.
		cover:SetAttribute("ButtonParticlesDisabled", true)
		cover:SetAttribute("ButtonSoundDisabled", true)
		local backdrop = PanelBackdrop.new(cover, {
			tint = Color3.fromRGB(120, 100, 200),
			textureTransparency = 0.8,
			tileSize = 140,
		})
		-- Centre stage (design px; the screen's UIScale fits it to every device).
		local stage = Create.new("Frame", {
			Name = "Stage",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(SWIRL_SIZE, SWIRL_SIZE),
			ZIndex = 2,
			Parent = gui,
		}) :: Frame
		local stageScale = Create.new("UIScale", { Scale = 1, Parent = stage }) :: UIScale
		-- The stud swirl: rings of rounded stud tiles that counter-rotate.
		local rings: { { frame: Frame, speed: number } } = {}
		for ringIndex, spec in RINGS do
			local ring = Create.new("Frame", {
				Name = `Ring{ringIndex}`,
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				ZIndex = 2,
				Parent = stage,
			}) :: Frame
			for tileIndex = 1, spec.count do
				local angle = (tileIndex - 1) / spec.count * math.pi * 2
				local tile = Create.new("Frame", {
					Name = `Tile{tileIndex}`,
					BackgroundColor3 = TILE_COLORS[(tileIndex + ringIndex) % #TILE_COLORS + 1],
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(
						0.5 + math.cos(angle) * spec.radius,
						0.5 + math.sin(angle) * spec.radius
					),
					Size = UDim2.fromOffset(spec.tile, spec.tile),
					Rotation = math.deg(angle),
					ZIndex = 3,
					Parent = ring,
					Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.3, 0) }) },
				}) :: Frame
				-- A raised stud on each tile (the stud look, owner rule 2).
				Create.new("Frame", {
					Name = "Stud",
					BackgroundColor3 = Color3.new(1, 1, 1),
					BackgroundTransparency = 0.6,
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(0.5, 0.5),
					ZIndex = 4,
					Parent = tile,
					Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
				})
			end
			table.insert(rings, { frame = ring, speed = spec.speed })
		end
		-- The clock: a stud disc, 12 ticks and one hand that jumps (ClockTicksPerSecond).
		local clock = Create.new("Frame", {
			Name = "Clock",
			BackgroundColor3 = Color3.fromRGB(250, 236, 200),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(CLOCK_SIZE, CLOCK_SIZE),
			ZIndex = 5,
			Parent = stage,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
		}) :: Frame
		StudWindow.edge(clock, 8)
		for tick = 1, 12 do
			local angle = (tick - 1) / 12 * math.pi * 2
			Create.new("Frame", {
				Name = `Tick{tick}`,
				BackgroundColor3 = Color3.fromRGB(70, 50, 110),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5 + math.sin(angle) * 0.4, 0.5 - math.cos(angle) * 0.4),
				Size = UDim2.fromOffset(12, if tick % 3 == 1 then 28 else 16),
				Rotation = math.deg(angle),
				ZIndex = 6,
				Parent = clock,
				Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
			})
		end
		local hand = Create.new("Frame", {
			Name = "Hand",
			BackgroundColor3 = Color3.fromRGB(230, 70, 90),
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(14, CLOCK_SIZE * 0.36),
			ZIndex = 7,
			Parent = clock,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
		}) :: Frame
		Create.new("Frame", {
			Name = "Hub",
			BackgroundColor3 = Color3.fromRGB(70, 50, 110),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(30, 30),
			ZIndex = 8,
			Parent = clock,
			Children = { Create.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) },
		})
		-- The destination name card under the clock.
		local card = Create.new("Frame", {
			Name = "Card",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 1, -40),
			Size = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
			ZIndex = 9,
			Parent = gui,
		}) :: Frame
		local cardScale = Create.new("UIScale", { Scale = 1, Parent = card }) :: UIScale
		local surface = StudWindow.surface(card, "green", { edge = 6, corner = 18 })
		local cardIcon = StudUI.icon("WorldDino", 130, 11)
		cardIcon.AnchorPoint = Vector2.new(0, 0.5)
		cardIcon.Position = UDim2.new(0, 22, 0.5, 0)
		cardIcon.Parent = card
		local cardTitle = StudUI.text({
			text = "",
			textSize = 64,
			font = "shout",
			scaled = true,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(170, 18),
			size = UDim2.new(1, -190, 0, 76),
			zIndex = 11,
			parent = card,
		})
		local cardTagline = StudUI.text({
			text = "",
			textSize = 28,
			scaled = true,
			align = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(170, 100),
			size = UDim2.new(1, -190, 0, 50),
			zIndex = 11,
			parent = card,
		})
		-- The card sits at the bottom centre (its own frame: the stage scale never squashes it).
		card.AnchorPoint = Vector2.new(0.5, 1)
		card.Position = UDim2.new(0.5, 0, 1, -CARD_MARGIN)
		-- Fit to the device: the swirl fills the space above the card, the card the width.
		local stageFit, cardFit = 1, 1
		local function fit()
			local canvas = ScreenManager.canvasSize(gui)
			if canvas.X <= 0 or canvas.Y <= 0 then
				return
			end
			stageFit = math.clamp((canvas.Y - CARD_SIZE.Y - CARD_MARGIN * 2) / SWIRL_SIZE, 0.35, 1)
			cardFit = math.clamp((canvas.X - CARD_MARGIN * 2) / CARD_SIZE.X, 0.4, 1)
			stage.Position = UDim2.new(0.5, 0, 0.5, -(CARD_SIZE.Y * cardFit) / 2)
		end
		ScreenManager.LayoutChanged:Connect(fit)
		gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)

		local icons: { [string]: Frame } = { WorldDino = cardIcon }
		local render: RBXScriptConnection? = nil
		local openedAt = 0
		local generation = 0
		local closing = false
		local reduced = false
		local hopping = false -- this open is a same-world hop (no world-change whoosh on warp-in)

		-- Stops the per-frame animation.
		local function stopRender()
			local connection = render
			if connection ~= nil then
				connection:Disconnect()
				render = nil
			end
		end

		-- One frame of the swirl + clock (full motion only).
		local function step()
			local age = os.clock() - openedAt
			local turn = age * Overlay.SwirlTurnsPerSecond * 360
			for _, ring in rings do
				ring.frame.Rotation = turn * ring.speed
			end
			hand.Rotation = math.floor(age * Overlay.ClockTicksPerSecond) * 30
		end

		-- Shows the destination on the card (icon + name + tagline in the world's tab colour).
		local function showDestination(worldId: string)
			local def = WorldsConfig.get(worldId)
			local style = WorldClientLogic.style(worldId)
			cardTitle.Text = style.label
			cardTagline.Text = if def ~= nil then def.tagline else ""
			surface.setColor(style.color :: any)
			local icon = icons[style.icon]
			if icon == nil then
				icon = StudUI.icon(style.icon, 130, 11)
				icon.AnchorPoint = Vector2.new(0, 0.5)
				icon.Position = UDim2.new(0, 22, 0.5, 0)
				icon.Parent = card
				icons[style.icon] = icon
			end
			for key, frame in icons do
				frame.Visible = key == style.icon
			end
		end

		-- Warps in and closes (after the minimum on-screen time).
		local function finish(gen: number)
			if gen ~= generation or closing then
				return
			end
			closing = true
			if not hopping then
				Sound.play(WHOOSH)
			end
			local fade = TweenInfo.new(Overlay.FadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			TweenService:Create(cover, fade, { BackgroundTransparency = 1 }):Play()
			if not reduced then
				TweenService:Create(stageScale, fade, { Scale = 0.2 * stageFit }):Play()
				TweenService:Create(cardScale, fade, { Scale = 0.2 * cardFit }):Play()
			end
			backdrop.setTransparency(1)
			task.delay(Overlay.FadeSeconds, function()
				if gen == generation then
					ScreenManager.close(NAME)
				end
			end)
		end

		-- WorldClient phases while open: "in" -> warp in after the minimum time; "fail" closes.
		WorldClient.Phase:Connect(function(event: any)
			if not ScreenManager.isOpen(NAME) or closing then
				return
			end
			if event.phase == "in" then
				local gen = generation
				local remaining = math.max(0, Overlay.MinSeconds - (os.clock() - openedAt))
				task.delay(remaining, finish, gen)
			end
		end)

		return {
			onOpen = function(args: any?)
				generation += 1
				local gen = generation
				closing = false
				openedAt = os.clock()
				reduced = OfferFx.reducedMotion()
				local raw = if type(args) == "table" then args else {}
				local worldId = if type(raw.worldId) == "string" then raw.worldId else WorldClient.current()
				local hop = raw.hop == true
				hopping = hop
				Sound.play(WHOOSH)
				ClientAnalytics.screenOpened(NAME, if type(raw.source) == "string" then raw.source else "other")
				showDestination(worldId)
				card.Visible = not hop
				for _, ring in rings do
					ring.frame.Visible = not hop
				end
				-- Fade (Reduce Motion) or fade + pop in.
				local fadeIn = TweenInfo.new(Overlay.FadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				cover.BackgroundTransparency = 1
				TweenService:Create(cover, fadeIn, { BackgroundTransparency = 0 }):Play()
				backdrop.setTransparency(0.8)
				fit()
				if reduced then
					stageScale.Scale = stageFit
					cardScale.Scale = cardFit
				else
					stageScale.Scale = 0.3 * stageFit
					cardScale.Scale = 0.3 * cardFit
					local pop =
						TweenInfo.new(Overlay.FadeSeconds * 1.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
					TweenService:Create(stageScale, pop, { Scale = stageFit }):Play()
					TweenService:Create(cardScale, pop, { Scale = Overlay.CardPop * cardFit }):Play()
				end
				stopRender()
				if not reduced then
					render = RunService.PreRender:Connect(step)
				end
				-- Safety: never stays up longer than MaxSeconds.
				task.delay(Overlay.MaxSeconds, function()
					if gen == generation and ScreenManager.isOpen(NAME) then
						finish(gen)
					end
				end)
			end,
			onClose = function()
				generation += 1
				closing = false
				stopRender()
			end,
			-- B never cancels a trip.
			onBack = function(): boolean
				return true
			end,
			defaultSelection = function(): GuiObject?
				return nil
			end,
		}
	end,
}
