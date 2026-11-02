--!strict
--[[
	CountdownOverlay — the drawn layer of the launch cinematic (owner R54: "an animated 3, 2, 1"):
	stud letterbox bars, the target line, the punching "3 … 2 … 1" stud badge with its stud-brick
	burst, the big green "LAUNCH!" banner with confetti, the outcome shout ("DIRECT HIT!" /
	"INTERCEPTED!" / "KNOCKDOWN!") and the SKIP button.

	It owns NO clock and NO loop: Client/Attack/LaunchCam (the director) calls `render(rel, k)` from
	its one RenderStepped with `rel` = seconds after the flight's server t0, and every element is a
	pure function of `rel` (Shared/Attack/LaunchCamMath), so the numbers are always in step with the
	server and the voice lines the director plays.

	Look (owner rule 2 — stud texture on every surface): badge + banners are StudWindow stud
	surfaces with a dark edge and the Luckiest Guy "shout" font; letterbox bars are dark stud strips
	(PanelBackdrop); burst pieces are little stud bricks in the number's colour; confetti is candy
	coloured. Kid-friendly: no flashes, no shaking UI.

	Accessibility / budget:
		* Reduce Motion: no punch scale / rotation, no burst / confetti; elements cut in and out.
		* FxQuality tier: burst / confetti counts from LaunchCamConfig.FxTiers (pools are built once
		  at the High size; extra pieces just stay hidden). Zero Instance.new after build.
		* Every Visible write is change-gated; moving pieces write Position / Rotation / Size only
		  while they fly.

	Input (owner R11): a full-screen transparent catcher (tap / click anywhere) and a stud SKIP
	button (gamepad default selection, so A skips; ≥ 44 pt on touch; device glyph X / B) both call
	the skip handler the director installs. B / X / Backspace arrive through ScreenManager's Back
	(LaunchCountdownScreen.onBack). The director ignores skips during its grace window.

	Connects to: UI/Screens/LaunchCountdown/LaunchCountdownScreen (builds it), Client/Attack/LaunchCam
	(drives it), Shared/Config/LaunchCamConfig, Shared/Attack/LaunchCamMath, UI/{Create, ScreenManager,
	Kit/StudUI, Widgets/{StudWindow, PanelBackdrop, InputGlyph}}, Shared/Util/TouchLayout.

	Example:
		local overlay = CountdownOverlay.current()
		overlay.begin({ seed = flight.id, targetName = "Rival Toy Factory", reduced = false, budget = budget })
		overlay.render(Workspace:GetServerTimeNow() - flight.t0, 1)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Create = require(script.Parent.Parent.Parent.Create)
local InputGlyph = require(script.Parent.Parent.Parent.Widgets.InputGlyph)
local LaunchCamConfig = require(ReplicatedStorage.Shared.Config.LaunchCamConfig)
local LaunchCamMath = require(ReplicatedStorage.Shared.Attack.LaunchCamMath)
local PanelBackdrop = require(script.Parent.Parent.Parent.Widgets.PanelBackdrop)
local ScreenManager = require(script.Parent.Parent.Parent.ScreenManager)
local StudUI = require(script.Parent.Parent.Parent.Kit.StudUI)
local StudWindow = require(script.Parent.Parent.Parent.Widgets.StudWindow)
local TouchLayout = require(ReplicatedStorage.Shared.Util.TouchLayout)
local TouchUIConfig = require(ReplicatedStorage.Shared.Config.TouchUIConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local COUNTDOWN = LaunchCamConfig.Countdown
local OUTCOME = LaunchCamConfig.Outcome
local BURST = LaunchCamConfig.Burst
local CONFETTI = LaunchCamConfig.Confetti
local LETTERBOX = LaunchCamConfig.Letterbox
-- Design px the letterbox bars and the catcher extend past the (TV-safe padded) canvas so they
-- always reach the real screen edges.
local BLEED = 400
-- Where the centre stage sits (share of the canvas).
local STAGE_Y = 0.45
-- Where the outcome shout sits (share of the canvas): the lower third, clear of the server toasts
-- that stack at the top ("BOOM! ... +$X") and of the impact at the centre of the frame.
local OUTCOME_Y = 0.7
-- Largest pools (the High tier); lower tiers leave the rest hidden.
local MAX_BURST = 16
local MAX_CONFETTI = 40
-- Dark stud strip colour of the letterbox bars.
local BAR_COLOR = Color3.fromRGB(14, 14, 24)
local BAR_STUDS = Color3.fromRGB(70, 74, 110)

export type OutcomeKind = "Hit" | "Intercepted" | "Knockdown"

export type BeginInfo = {
	seed: number, -- per-flight seed (piece jitter)
	targetName: string, -- shown in the top bar ("" hides it)
	reduced: boolean, -- Reduce Motion
	budget: LaunchCamConfig.FxBudget, -- burst / confetti counts for this device tier
}

export type Overlay = {
	gui: ScreenGui,
	skipButton: StudUI.Button,
	-- Resets every element for a new cinematic.
	begin: (info: BeginInfo) -> (),
	-- Draws the frame at `rel` (seconds after t0) with the letterbox `k` (0 hidden .. 1 in).
	render: (rel: number, letterbox: number) -> (),
	-- Schedules the outcome shout at `rel`.
	showOutcome: (kind: OutcomeKind, rel: number) -> (),
	-- Hides the countdown / banners / pieces at once (skip / finish).
	hideAll: () -> (),
	-- The director's skip handler (nil = none).
	setSkipHandler: (handler: ((source: string) -> ())?) -> (),
	-- A skip request from an input (catcher, SKIP button, Back).
	requestSkip: (source: string) -> (),
	-- Re-reads the canvas (device / scale change).
	layout: () -> (),
}

type Piece = { frame: Frame, shown: boolean }

local CountdownOverlay = {}

local current: Overlay? = nil

-- Sets `object.Visible` only when it changes (no redundant property writes per frame).
local function setVisible(object: GuiObject, visible: boolean)
	if object.Visible ~= visible then
		object.Visible = visible
	end
end

--[[
	Builds the overlay into `gui` (called once by LaunchCountdownScreen.build) and remembers it as
	the current overlay.
	@param gui ScreenGui — the LaunchCountdown screen's gui (AutoScale design px)
	@return Overlay
]]
function CountdownOverlay.new(gui: ScreenGui): Overlay
	local skipHandler: ((source: string) -> ())? = nil
	local info: BeginInfo = {
		seed = 1,
		targetName = "",
		reduced = false,
		budget = LaunchCamConfig.FxTiers.High,
	}
	local outcomeAt: number? = nil
	local outcomeKind: OutcomeKind = "Hit"
	local lastBadgeStep = 0
	local hidden = true

	local function requestSkip(source: string)
		local handler = skipHandler
		if handler ~= nil then
			handler(source)
		end
	end

	-- Tap / click anywhere skips (sound-free, no particle orbit on a full-screen button).
	local catcher = Create.new("TextButton", {
		Name = "SkipCatcher",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(-BLEED, -BLEED),
		Size = UDim2.new(1, 2 * BLEED, 1, 2 * BLEED),
		Selectable = false,
		ZIndex = 1,
		Parent = gui,
	}) :: TextButton
	catcher:SetAttribute("ButtonParticlesDisabled", true)
	catcher:SetAttribute("FeedbackSound", "")
	catcher.Activated:Connect(function()
		requestSkip("tap")
	end)

	-- Letterbox: dark stud strips sliding in from the top / bottom edges.
	local function makeBar(name: string, top: boolean): Frame
		local bar = Create.new("Frame", {
			Name = name,
			BackgroundColor3 = BAR_COLOR,
			BorderSizePixel = 0,
			AnchorPoint = if top then Vector2.zero else Vector2.new(0, 1),
			Size = UDim2.new(1, 2 * BLEED, LETTERBOX.Height, BLEED),
			Active = false,
			ZIndex = 2,
			Parent = gui,
		}) :: Frame
		PanelBackdrop.new(bar, { tint = BAR_STUDS, textureTransparency = 0.8, tileSize = 64, zIndex = 2 })
		return bar
	end
	local topBar = makeBar("LetterboxTop", true)
	local bottomBar = makeBar("LetterboxBottom", false)
	-- The target line rides the top bar. It is sized by SCALE of the canvas height (TextScaled,
	-- ≤ 40 px), so it always fits the bar's visible strip; Studio QA found offset sizing overflowing
	-- the thin phone bar.
	local targetLabel = StudUI.text({
		text = "",
		textSize = 40,
		font = "title",
		scaled = true,
		anchor = Vector2.new(0.5, 0.5),
		size = UDim2.fromScale(0.86, LETTERBOX.Height * 0.66),
		zIndex = 3,
		parent = gui,
		name = "Target",
	})

	-- Centre stage (a zero-size anchor; everything centres on it).
	local stage = Create.new("Frame", {
		Name = "Stage",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, STAGE_Y),
		Size = UDim2.fromOffset(0, 0),
		Active = false,
		ZIndex = 3,
		Parent = gui,
	}) :: Frame

	-- Stud bricks of the per-number burst (behind the badge).
	local burst: { Piece } = {}
	for index = 1, MAX_BURST do
		local frame = Create.new("Frame", {
			Name = `Burst{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(BURST.PieceSize, BURST.PieceSize),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			Visible = false,
			Active = false,
			ZIndex = 3,
			Parent = stage,
		}) :: Frame
		Create.new("UICorner", { CornerRadius = UDim.new(0, 8), Parent = frame })
		StudWindow.edge(frame, 3)
		PanelBackdrop.new(frame, { textureTransparency = 0.35, tileSize = BURST.PieceSize, zIndex = 3 })
		burst[index] = { frame = frame, shown = false }
	end

	-- The number badge (a square stud plate) with a slow sunburst behind it.
	local badgeSize = COUNTDOWN.BadgeSize
	local sunburstHolder = Create.new("Frame", {
		Name = "BadgeRays",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(badgeSize * 2, badgeSize * 2),
		Visible = false,
		Active = false,
		ZIndex = 3,
		Parent = stage,
	}) :: Frame
	StudWindow.sunburst(sunburstHolder, { zIndex = 3 })
	local badge = Create.new("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(badgeSize, badgeSize),
		Visible = false,
		Active = false,
		ZIndex = 4,
		Parent = stage,
	}) :: Frame
	local badgeSurface = StudWindow.surface(badge, "red", { edge = 8, corner = 56, tile = 72, zIndex = 4 })
	local badgeScale = Create.new("UIScale", { Name = "Punch", Parent = badge }) :: UIScale
	local numberLabel = StudUI.text({
		text = "3",
		textSize = COUNTDOWN.NumberTextSize,
		font = "shout",
		size = UDim2.fromScale(1, 1),
		zIndex = 5,
		parent = badge,
		name = "Number",
	})

	-- A wide stud banner (LAUNCH! / outcome shouts).
	local function makeBanner(
		name: string,
		size: Vector2,
		color: StudWindow.ColorName,
		textSize: number,
		parent: GuiObject | ScreenGui
	)
		local frame = Create.new("Frame", {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(size.X, size.Y),
			Visible = false,
			Active = false,
			ZIndex = 4,
			Parent = parent,
		}) :: Frame
		local surface = StudWindow.surface(frame, color, { edge = 8, corner = 48, tile = 72, zIndex = 4 })
		local scale = Create.new("UIScale", { Name = "Punch", Parent = frame }) :: UIScale
		local label = StudUI.text({
			text = "",
			textSize = textSize,
			font = "shout",
			size = UDim2.fromScale(1, 1),
			zIndex = 5,
			parent = frame,
			name = "Shout",
		})
		return frame, surface, scale, label
	end
	local launchBanner, _launchSurface, launchScale, launchLabel =
		makeBanner("LaunchBanner", COUNTDOWN.BannerSize, COUNTDOWN.LaunchColor, COUNTDOWN.LaunchTextSize, stage)
	launchLabel.Text = "LAUNCH!"
	local outcomeBanner, outcomeSurface, outcomeScale, outcomeLabel =
		makeBanner("OutcomeBanner", OUTCOME.BannerSize, "yellow", OUTCOME.TextSize, gui)
	outcomeBanner.Position = UDim2.fromScale(0.5, OUTCOME_Y)

	-- Confetti (LAUNCH!), in front of everything on the stage.
	local confetti: { Piece } = {}
	for index = 1, MAX_CONFETTI do
		local frame = Create.new("Frame", {
			Name = `Confetti{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(CONFETTI.PieceSize.X, CONFETTI.PieceSize.Y),
			BackgroundColor3 = CONFETTI.Colors[(index - 1) % #CONFETTI.Colors + 1],
			BorderSizePixel = 0,
			Visible = false,
			Active = false,
			ZIndex = 6,
			Parent = stage,
		}) :: Frame
		Create.new("UICorner", { CornerRadius = UDim.new(0, 4), Parent = frame })
		confetti[index] = { frame = frame, shown = false }
	end

	-- SKIP (bottom right, over the bottom bar): gamepad default selection; device glyph.
	local skipButton = StudUI.button({
		text = "SKIP",
		color = "grey",
		size = UDim2.fromOffset(LaunchCamConfig.Input.SkipSize.X, LaunchCamConfig.Input.SkipSize.Y),
		anchor = Vector2.new(1, 1),
		position = UDim2.new(1, -28, 1, -22),
		name = "Skip",
		parent = gui,
		onActivated = function()
			requestSkip("button")
		end,
	})
	skipButton.instance.ZIndex = 8
	local glyph = InputGlyph.dynamic(Enum.KeyCode.X, Enum.KeyCode.ButtonB, 34)
	glyph.AnchorPoint = Vector2.new(1, 0)
	glyph.Position = UDim2.new(1, 10, 0, -18)
	glyph.ZIndex = 9
	glyph.Parent = skipButton.instance

	-- Sizes that follow the device: SKIP ≥ 44 pt on touch.
	local function layout()
		local width = LaunchCamConfig.Input.SkipSize.X
		local height = LaunchCamConfig.Input.SkipSize.Y
		if ScreenManager.touchTargets() then
			local minTap = TouchLayout.pointsToDesign(TouchUIConfig.MinTapPoints, ScreenManager.pointScale())
			height = math.max(height, minTap)
			width = math.max(width, math.floor(minTap * 2.4))
		end
		skipButton.instance.Size = UDim2.fromOffset(width, height)
	end
	layout()

	-- Hides every piece of a pool from `from` on (change-gated).
	local function hidePieces(pool: { Piece }, from: number)
		for index = from, #pool do
			local piece = pool[index]
			if piece.shown then
				piece.shown = false
				piece.frame.Visible = false
			end
		end
	end

	local function hideAll()
		setVisible(skipButton.instance, false)
		setVisible(badge, false)
		setVisible(sunburstHolder, false)
		setVisible(launchBanner, false)
		setVisible(outcomeBanner, false)
		hidePieces(burst, 1)
		hidePieces(confetti, 1)
	end

	-- Draws one punching element (badge / banner); returns whether it is shown.
	local function drawPunch(frame: Frame, scale: UIScale, elapsed: number, length: number, side: number): boolean
		local s, rotation, transparency = LaunchCamMath.punch(elapsed, length, COUNTDOWN, info.reduced)
		local shown = if info.reduced then transparency < 0.5 else transparency < 0.98 and s > 0.02
		setVisible(frame, shown)
		if shown then
			scale.Scale = s
			frame.Rotation = rotation * side
		end
		return shown
	end

	local function render(rel: number, letterbox: number)
		-- Letterbox bars slide with k.
		local k = math.clamp(LaunchCamMath.finite(letterbox, 0), 0, 1)
		topBar.Position = UDim2.new(0, -BLEED, -LETTERBOX.Height * (1 - k), -BLEED)
		bottomBar.Position = UDim2.new(0, -BLEED, 1 + LETTERBOX.Height * (1 - k), BLEED)
		-- Centred in the top bar's visible strip, sliding with it.
		targetLabel.Position = UDim2.fromScale(0.5, LETTERBOX.Height * (k - 0.5))
		if hidden then
			return
		end
		local phase, step, elapsed, length =
			LaunchCamMath.countdown(rel, COUNTDOWN.Beat, COUNTDOWN.Steps, COUNTDOWN.LaunchHold)

		-- 3 … 2 … 1 badge + its stud burst.
		if phase == "count" and step ~= nil then
			if step ~= lastBadgeStep then
				lastBadgeStep = step
				numberLabel.Text = tostring(step)
				local colorName = (COUNTDOWN.Colors[step] or "red") :: StudWindow.ColorName
				badgeSurface.setColor(colorName)
				local preset = UIStyleConfig.Colors[colorName] or UIStyleConfig.Colors.red
				for _, piece in burst do
					piece.frame.BackgroundColor3 = preset.top
				end
			end
			local side = if step % 2 == 1 then 1 else -1
			local shown = drawPunch(badge, badgeScale, elapsed, length, side)
			setVisible(sunburstHolder, shown and not info.reduced)
			local count = if info.reduced then 0 else math.min(info.budget.burst, MAX_BURST)
			for index = 1, count do
				local piece = burst[index]
				local dx, dy, rotation, transparency =
					LaunchCamMath.burstPiece(index, count, elapsed, info.seed + step * 31, BURST)
				local visible = transparency < 1
				if visible ~= piece.shown then
					piece.shown = visible
					piece.frame.Visible = visible
				end
				if visible then
					local size = BURST.PieceSize * (1 - 0.7 * transparency)
					piece.frame.Position = UDim2.fromOffset(dx, dy)
					piece.frame.Rotation = rotation
					piece.frame.Size = UDim2.fromOffset(size, size)
				end
			end
			hidePieces(burst, count + 1)
		else
			setVisible(badge, false)
			setVisible(sunburstHolder, false)
			hidePieces(burst, 1)
		end

		-- LAUNCH! banner.
		if phase == "launch" then
			drawPunch(launchBanner, launchScale, elapsed, length, -1)
		else
			setVisible(launchBanner, false)
		end

		-- Confetti from the banner from t0 on (runs past the banner's hold).
		local confettiCount = if info.reduced then 0 else math.min(info.budget.confetti, MAX_CONFETTI)
		if rel >= 0 and rel < CONFETTI.Seconds and confettiCount > 0 then
			for index = 1, confettiCount do
				local piece = confetti[index]
				local dx, dy, rotation, transparency = LaunchCamMath.confettiPiece(index, rel, info.seed, CONFETTI)
				local visible = transparency < 1
				if visible ~= piece.shown then
					piece.shown = visible
					piece.frame.Visible = visible
				end
				if visible then
					piece.frame.Position = UDim2.fromOffset(dx, dy)
					piece.frame.Rotation = rotation
					piece.frame.BackgroundTransparency = transparency
				end
			end
			hidePieces(confetti, confettiCount + 1)
		else
			hidePieces(confetti, 1)
		end

		-- Outcome shout.
		local at = outcomeAt
		if at ~= nil and rel >= at then
			drawPunch(
				outcomeBanner,
				outcomeScale,
				rel - at,
				OUTCOME.ShowSeconds,
				if outcomeKind == "Hit" then 1 else -1
			)
		else
			setVisible(outcomeBanner, false)
		end
	end

	local overlay: Overlay = {
		gui = gui,
		skipButton = skipButton,
		begin = function(newInfo: BeginInfo)
			info = newInfo
			outcomeAt = nil
			lastBadgeStep = 0
			hidden = false
			targetLabel.Text = newInfo.targetName
			targetLabel.Visible = newInfo.targetName ~= ""
			hideAll()
			setVisible(skipButton.instance, true)
			layout()
		end,
		render = render,
		showOutcome = function(kind: OutcomeKind, rel: number)
			local spec = OUTCOME.Shouts[kind]
			if spec == nil then
				return
			end
			outcomeKind = kind
			outcomeAt = rel
			outcomeLabel.Text = spec.text
			outcomeSurface.setColor(spec.color)
		end,
		hideAll = function()
			hidden = true
			hideAll()
		end,
		setSkipHandler = function(handler: ((source: string) -> ())?)
			skipHandler = handler
		end,
		requestSkip = requestSkip,
		layout = layout,
	}
	ScreenManager.LayoutChanged:Connect(layout)
	current = overlay
	return overlay
end

--[[ The built overlay (nil until LaunchCountdownScreen built it). ]]
function CountdownOverlay.current(): Overlay?
	return current
end

return CountdownOverlay
