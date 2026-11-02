--!strict
--[[
	FlavorReveal — the owner's short Lucky Nuke reveal (owner R89 Surprise Batches, spec §1; owner
	R108: no letterbox, no HUD fade, never centre-screen — a larger card in the bottom-left corner;
	owner R112 wording; owner R120: ONLY for the player's FIRST find of a flavour in a world, at most
	once per 5 minutes — every other Lucky Nuke is a small feed pill). A non-modal card of at most
	FlavorConfig.Reveal.Seconds (2.8 s):

		┌──── flavour-coloured stud card ─────────[B] SKIP ┐
		│ LUCKY NUKES!                                     │   ← title, springy pop from the corner
		│ Your Pocket Nuke Workbench made GALAXY nukes      │
		│ 1 in 2,500                     (counts up)       │
		│ Sold for x20: +$1.25M                             │   ← the payout always shows
		│ New Lucky Nuke: GALAXY in Nuke Town! Claim 60     │   ← the Flavour Book claim line
		│ Gems in Pets → FLAVOURS.                          │     (first find, owner R120)
		└───────────────────────────────────────────────────┘
	+ a confetti burst at the producer (world) and the fanfare (2D).

	Where: the bottom of the bottom-left FEED column (UI/Widgets/PopupQueue.placeFeedCard: under or
	beside the left button grid, clear of the objective chip, the hint bar, the touch thumbstick /
	jump reserve), fitted between PopupQueueConfig.Feed.Card.MinFit and 1 (phones: never under
	14 pt text). The feed's toasts / Big Pop pills stack above it while it plays. The HUD stays.

	When it plays: Tycoon/FlavorController opens it through PopupQueue's centre lane (kind
	"flavorReveal": banners wait for it, chips hide) for a first find (FlavorFeedLogic), only while
	no menu (modal), no cinematic and no tutorial step is up. It never blocks gameplay and closes
	itself.

	Input (owner R11 / R108): display-only except dismissing — SKIP (≥ 44 pt everywhere: its height
	is raised on small scales) or a tap / click anywhere on the card; gamepad B and keyboard X /
	Backspace skip too (a ContextActionService binding that exists only while the card is up, high
	priority so B never reaches anything else). Nothing is Selectable (the gamepad cursor is never
	stolen); the SKIP glyph follows the device (InputGlyph.dynamic, hidden on touch).
	Reduce Motion: no card punch, no confetti.

	Payload (validated by FlavorController): { producerId, flavor, worldId, oneIn, mult, amount,
	claim? } (claim = the Flavour Book claim line).
	Studio QA only: the ScreenGui attribute DebugHold = true keeps it open past Reveal.Seconds (the
	device-matrix captures of tools/qa/{flavors, popup_queue}.py); ignored outside Studio.

	Connects to: UI/{ScreenManager, Create, Kit/StudUI, Widgets/{InputGlyph, OfferFx, PopupQueue}},
	Tycoon/{ProducerBillboards, WorldLookup, Fx/{Confetti, FxQuality, JuiceRules}}, Audio/Sound,
	Shared/Config/{FlavorConfig (Reveal + Text / revealLines), InputConfig, PopupQueueConfig,
	TouchUIConfig, UIStyleConfig}, Shared/Tycoon/FlavorLogic, Shared/Util/{Signal, TouchLayout}.

	Example: ScreenManager.open("FlavorReveal", { producerId = "garage", flavor = "galaxy",
		worldId = "main", oneIn = 2500, mult = 20, amount = 1250000 })
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Confetti = require(script.Parent.Parent.Parent.Tycoon.Fx.Confetti)
local Create = require(script.Parent.Parent.Create)
local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local FlavorLogic = require(ReplicatedStorage.Shared.Tycoon.FlavorLogic)
local FxQuality = require(script.Parent.Parent.Parent.Tycoon.Fx.FxQuality)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local InputGlyph = require(script.Parent.Parent.Widgets.InputGlyph)
local JuiceRules = require(script.Parent.Parent.Parent.Tycoon.Fx.JuiceRules)
local OfferFx = require(script.Parent.Parent.Widgets.OfferFx)
local PopupQueue = require(script.Parent.Parent.Widgets.PopupQueue)
local PopupQueueConfig = require(ReplicatedStorage.Shared.Config.PopupQueueConfig)
local ProducerBillboards = require(script.Parent.Parent.Parent.Tycoon.ProducerBillboards)
local ScreenManager = require(script.Parent.Parent.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Sound = require(script.Parent.Parent.Parent.Audio.Sound)
local StudUI = require(script.Parent.Parent.Kit.StudUI)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldLookup = require(script.Parent.Parent.Parent.Tycoon.WorldLookup)

local NAME = "FlavorReveal"
local SKIP_ACTION = "SellNukesFlavorRevealSkip"
local Config = FlavorConfig.Reveal
local Card = PopupQueueConfig.Feed.Card
-- The smallest text on the card (design px at fit 1): phones keep it >= 14 pt.
local SMALLEST_TEXT = 30

local screen: ScreenManager.ScreenModule = {
	name = NAME,
	modal = false,
	autoOpen = false,
	displayOrder = 17, -- above the HUD + juice banner (16), below every window (20+)
	lazy = true,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		local root = Create.new("Frame", {
			Name = "Root",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			Parent = gui,
		}) :: Frame
		-- Holder: positioned by PopupQueue.placeFeedCard; its UIScale fits the card to the column.
		local holder = Create.new("Frame", {
			Name = "CardHolder",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(Card.Width, Card.Height),
			Active = false,
			Parent = root,
		}) :: Frame
		local fitScale = Create.new("UIScale", { Name = "Fit", Scale = 1, Parent = holder }) :: UIScale

		-- The card grows out of its bottom-left corner (the feed's corner).
		local card = StudUI.card({
			name = "Card",
			color = "purple",
			sunburst = true,
			size = UDim2.fromScale(1, 1),
			anchor = Vector2.new(0, 1),
			position = UDim2.fromScale(0, 1),
			parent = holder,
		})
		card.frame.Active = false
		local punch = Create.new("UIScale", { Name = "Punch", Scale = 1, Parent = card.frame }) :: UIScale
		local textWidth = Card.Width - 40
		local title = StudUI.text({
			name = "Title",
			text = "",
			textSize = 50,
			font = "shout",
			scaled = true,
			align = Enum.TextXAlignment.Left,
			size = UDim2.fromOffset(textWidth - Card.SkipWidth - 60, 54),
			position = UDim2.fromOffset(16, 4),
			zIndex = 4,
			parent = card.content,
		})
		local madeLabel = StudUI.text({
			name = "Made",
			text = "",
			textSize = SMALLEST_TEXT,
			scaled = true,
			align = Enum.TextXAlignment.Left,
			size = UDim2.fromOffset(textWidth, 38),
			position = UDim2.fromOffset(16, 60),
			zIndex = 4,
			parent = card.content,
		})
		local oddsLabel = StudUI.text({
			name = "Odds",
			text = "",
			textSize = 46,
			font = "number",
			scaled = true,
			color = Color3.fromRGB(255, 226, 80),
			align = Enum.TextXAlignment.Left,
			size = UDim2.fromOffset(textWidth, 50),
			position = UDim2.fromOffset(16, 100),
			zIndex = 4,
			parent = card.content,
		})
		local soldLabel = StudUI.text({
			name = "Sold",
			text = "",
			textSize = 36,
			font = "number",
			scaled = true,
			color = UIStyleConfig.Neutral.CashGreen,
			align = Enum.TextXAlignment.Left,
			size = UDim2.fromOffset(textWidth, 42),
			position = UDim2.fromOffset(16, 152),
			zIndex = 4,
			parent = card.content,
		})

		-- Owner R120: the card is a FIRST find — the Flavour Book claim line (the server's
		-- discovery toast text, dropped from the feed while this card says it). Two lines max.
		local claimLabel = StudUI.text({
			name = "Claim",
			text = "",
			textSize = SMALLEST_TEXT,
			wrap = true,
			color = Color3.fromRGB(255, 226, 80),
			align = Enum.TextXAlignment.Left,
			size = UDim2.fromOffset(textWidth, 72),
			position = UDim2.fromOffset(16, 198),
			zIndex = 4,
			parent = card.content,
		})

		local finish: () -> ()

		-- Tap / click anywhere on the card dismisses it (never Selectable: no gamepad cursor grab).
		local dismiss = Create.new("TextButton", {
			Name = "Dismiss",
			Text = "",
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Selectable = false,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 6,
			Parent = card.frame,
		}) :: TextButton
		dismiss.Activated:Connect(function()
			finish()
		end)

		-- SKIP: the card's top-right corner, glyph (B / X) beside it.
		local skipRow = Create.new("Frame", {
			Name = "SkipRow",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 10),
			Size = UDim2.fromOffset(Card.SkipWidth + 60, Card.SkipHeight),
			ZIndex = 7,
			Parent = card.frame,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 8),
				}),
			},
		}) :: Frame
		local glyph = InputGlyph.dynamic(InputConfig.CloseKey, InputConfig.BackButton, 36)
		glyph.LayoutOrder = 1
		glyph.Parent = skipRow
		local skip = StudUI.button({
			name = "Skip",
			text = "SKIP",
			color = "grey",
			size = UDim2.fromOffset(Card.SkipWidth, Card.SkipHeight),
			layoutOrder = 2,
			parent = skipRow,
			onActivated = function()
				finish()
			end,
		})
		skip.instance.Selectable = false
		for _, descendant in skipRow:GetDescendants() do
			if descendant:IsA("GuiObject") then
				descendant.ZIndex = math.max(descendant.ZIndex, 7)
			end
		end

		-- The odds count-up: a NumberValue tween drives the label (no per-frame code here).
		local counter = Instance.new("NumberValue")
		counter.Value = 1
		counter.Changed:Connect(function(value: number)
			oddsLabel.Text = FlavorLogic.formatOdds(math.max(1, math.floor(value + 0.5)))
		end)

		local tweens: { Tween } = {}
		local token = 0
		local open = false
		local bandConnection: Signal.Connection? = nil

		local function play(tween: Tween)
			table.insert(tweens, tween)
			tween:Play()
		end
		local function cancelTweens()
			for _, tween in tweens do
				tween:Cancel()
			end
			table.clear(tweens)
		end

		-- The fit floor: phones keep the smallest text >= 14 pt.
		local function minFit(): number
			local floor = Card.MinFit
			if ScreenManager.touchTargets() then
				local fourteen = TouchLayout.pointsToDesign(14, ScreenManager.pointScale())
				floor = math.max(floor, fourteen / SMALLEST_TEXT)
			end
			return math.min(floor, 1)
		end

		-- Places the card in the feed column + keeps SKIP >= 44 pt at the chosen fit.
		local function place()
			local x, y, fit = PopupQueue.placeFeedCard(Card.Width, Card.Height, minFit())
			holder.Position = UDim2.fromOffset(x, y)
			fitScale.Scale = fit
			local minTap = TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, ScreenManager.pointScale())
			local height = math.max(Card.SkipHeight, math.ceil(minTap / math.max(fit, 0.01)))
			skip.instance.Size = UDim2.fromOffset(Card.SkipWidth, height)
			skipRow.Size = UDim2.fromOffset(Card.SkipWidth + 60, height)
		end

		local function onSkip(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin and open then
				finish()
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end

		finish = function()
			if not open then
				return
			end
			ScreenManager.close(NAME)
		end

		return {
			onOpen = function(args: any?)
				local data: any = if type(args) == "table" then args else {}
				local def = FlavorConfig.byId(data.flavor) or FlavorConfig.byRank(Config.MinRank)
				if def == nil then
					return
				end
				open = true
				token += 1
				local mine = token
				cancelTweens()
				local reduced = OfferFx.reducedMotion()
				local worldId = WorldLookup.normalize(data.worldId)
				local record = if type(data.producerId) == "string"
					then ProducerBillboards.byId(data.producerId)
					else nil
				local oneIn = if type(data.oneIn) == "number" and data.oneIn >= 1 then data.oneIn else def.oneIn
				local amount = if type(data.amount) == "number" and data.amount > 0 then data.amount else 0
				-- Owner R112 words; the payout always shows when the server sent it.
				local lines = FlavorConfig.revealLines(
					def,
					if record ~= nil and record.cfg ~= nil then record.cfg.name else nil,
					if amount > 0 then WorldLookup.label(worldId, amount) else nil
				)
				card.setColor(def.ui)
				title.Text = lines.title
				madeLabel.Text = lines.made
				soldLabel.Text = lines.sold
				-- Built by FlavorController from FlavorConfig.Text (never player text).
				claimLabel.Text = if type(data.claim) == "string" then data.claim else ""
				claimLabel.Visible = claimLabel.Text ~= ""
				place()
				-- Re-place while open when the HUD / layout moves (rotation, device switch).
				if bandConnection == nil then
					bandConnection = PopupQueue.Changed:Connect(function(what: string)
						if what == "band" and open then
							place()
						end
					end)
				end
				if reduced then
					punch.Scale = 1
				else
					punch.Scale = 0.4
					play(
						TweenService:Create(
							punch,
							TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
							{ Scale = 1 }
						)
					)
				end
				counter.Value = 1
				oddsLabel.Text = FlavorLogic.formatOdds(1)
				play(
					TweenService:Create(
						counter,
						TweenInfo.new(Config.CountSeconds, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
						{ Value = oneIn }
					)
				)
				-- World confetti at the producer + the fanfare.
				if record ~= nil and not reduced then
					local tier = FxQuality.tier()
					Confetti.burst(
						record.popPoint.WorldPosition + Vector3.new(0, 2, 0),
						JuiceRules.perTier(Config.Confetti, tier),
						JuiceRules.perTier(FlavorConfig.Pop.Sparkles, tier)
					)
				end
				Sound.play("fanfare")
				ContextActionService:BindActionAtPriority(
					SKIP_ACTION,
					onSkip,
					false,
					Enum.ContextActionPriority.High.Value + 10,
					InputConfig.BackButton,
					table.unpack(InputConfig.CloseKeys)
				)
				skip.setState("normal", "SKIP")
				task.delay(Config.Seconds, function()
					-- Studio QA (tools/qa/flavors.py, popup_queue.py): the ScreenGui attribute
					-- DebugHold keeps the card up for the device-matrix captures; never live.
					if token == mine and not (RunService:IsStudio() and gui:GetAttribute("DebugHold") == true) then
						finish()
					end
				end)
			end,
			onClose = function()
				open = false
				token += 1
				cancelTweens()
				ContextActionService:UnbindAction(SKIP_ACTION)
				local connection = bandConnection
				if connection ~= nil then
					connection:Disconnect()
					bandConnection = nil
				end
				PopupQueue.clearFeedCard()
			end,
		}
	end,
}

return screen
