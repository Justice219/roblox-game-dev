--!strict
--[[
	PlotReveal — "Your plot is #N!" (owner rule R13): players spawn in the hub, the server assigns
	a random free plot (player attribute PlotIndex, B5), and the client shows where it is.

	Sequence (each time PlotIndex becomes a new N > 0):
		0. waits for the join loading screen to finish (player attribute LoadingDone, owner R16,
		   through Widgets/LoadingGate),
		1. waits (max Reveal.WaitForMenusSeconds) for a join pop-up such as Welcome Back to close,
		2. asks the engine to stream the plot in (Player:RequestStreamAroundAsync),
		3. shows the "Your plot is #N!" stud banner (non-modal screen "PlotReveal"),
		4. swoops the camera from where it is to a high view over the plot (Reveal.SwoopSeconds,
		   sine in-out), holds it, then hands the camera back (CameraType Custom on the character).
		   Reduced Motion: an instant cut to the plot view, a hold, an instant cut back.
		5. Skippable at any time: A / Space / Enter / click / tap (ContextActionService at a priority
		   above the default controls, plus TouchTapInWorld) -> camera back immediately.
		6. Tells the server PlotRevealDone() (once per reveal, also when it is skipped or cannot
		   play) so it walks the character home (server fallback: 60 s after assignment). The
		   total length follows the server's PlotRevealSeconds hint (swoop = total - hold).
		Before swooping it waits (max Reveal.WaitForPlotSeconds) for Plot<N>.PlotReady = true, so
		the placed builds are in the shot.
	Gameplay input is blocked ("PlotReveal") while the camera is scripted, so the swoop never
	fights the character controls; the HUD stays. Plot frames come from Shared/Config/WorldLayout,
	so the camera works before the plot has streamed in.
	Popup queue (owner R102): while the banner is up it holds UI/Widgets/PopupQueue's centre lane
	(kind "plotReveal", the top priority: other banners wait / resume after it, chips hide, toasts
	move under it) and sits at the top of the queue's free band — right under the measured currency
	stack, never over the cash counter (it used a fixed 190 px before).

	Connects to: Tycoon/TycoonContract (PlotIndex), Controllers/InputController (block),
	UI/{ScreenManager, Kit/StudUI, Widgets/OfferFx (reduced motion), Widgets/InputGlyph,
	Widgets/PopupQueue (centre lane + placement)},
	Shared/Config/{WorldLayout, TycoonClientConfig}.

	Example: PlotReveal.start(); PlotReveal.play(3) -- Studio / tests
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Contract = require(script.Parent.TycoonContract)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Create = require(script.Parent.Parent.UI.Create)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local InputGlyph = require(script.Parent.Parent.UI.Widgets.InputGlyph)
local LoadingGate = require(script.Parent.Parent.UI.Widgets.LoadingGate)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local PopupQueue = require(script.Parent.Parent.UI.Widgets.PopupQueue)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local StudUI = require(script.Parent.Parent.UI.Kit.StudUI)
local TycoonClientConfig = require(ReplicatedStorage.Shared.Config.TycoonClientConfig)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

local Config = TycoonClientConfig.Reveal

local PlotReveal = {}

local SCREEN = "PlotReveal"
local SKIP_ACTION = "SellNukesPlotRevealSkip"
-- Above the default character controls (2000) and B16's gameplay actions; below modal Back.
local SKIP_PRIORITY = 2950

local started = false
local lastShown = 0
local playing = false
-- True from play() until the reveal ends (covers the wait for menus / streaming).
local queued = false
local token = 0
local bannerTitle: TextLabel? = nil
local bannerCard: Frame? = nil
-- The banner card (design px) and its pre-R102 top, used until the first placement.
local BANNER_SIZE = Vector2.new(820, 170)
local BANNER_TOP = 190
-- Releases the PopupQueue centre-lane hold of the banner on screen (nil = none held).
local releaseSlot: (() -> ())? = nil
local tapConnection: RBXScriptConnection? = nil
local tween: Tween? = nil
-- True until the running reveal has told the server it is done.
local doneOwed = false

-- The banner screen (non-modal, above the HUD, below windows).
local bannerScreen: ScreenManager.ScreenModule = {
	name = SCREEN,
	modal = false,
	displayOrder = 15,
	build = function(gui: ScreenGui): ScreenManager.ScreenHandle
		local card = StudUI.card({
			name = "Banner",
			color = "yellow",
			sunburst = true,
			size = UDim2.fromOffset(BANNER_SIZE.X, BANNER_SIZE.Y),
			anchor = Vector2.new(0.5, 0),
			position = UDim2.new(0.5, 0, 0, BANNER_TOP),
			parent = gui,
		})
		bannerCard = card.frame
		bannerTitle = StudUI.text({
			name = "Title",
			text = "Your plot is #1!",
			textSize = 74,
			font = "shout",
			size = UDim2.new(1, 0, 0, 90),
			position = UDim2.fromOffset(0, 6),
			zIndex = 4,
			parent = card.content,
		})
		local hint = Create.new("Frame", {
			Name = "SkipHint",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -8),
			Size = UDim2.fromOffset(0, 44),
			AutomaticSize = Enum.AutomaticSize.X,
			ZIndex = 4,
			Parent = card.content,
			Children = {
				Create.new("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, 8),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			},
		}) :: Frame
		local glyph = InputGlyph.dynamic(Enum.KeyCode.Space, Enum.KeyCode.ButtonA, 34)
		glyph.LayoutOrder = 1
		glyph.Parent = hint
		StudUI.text({
			text = "Skip",
			textSize = 30,
			size = UDim2.fromOffset(0, 40),
			autoWidth = true,
			color = UIStyleConfig.Neutral.Text,
			layoutOrder = 2,
			zIndex = 4,
			parent = hint,
		})
		return {}
	end,
}

-- Opens the banner holding PopupQueue's centre lane, at the top of the free band.
local function openBanner()
	-- The new hold replaces a previous one (same kind) before that is released: the lane never
	-- frees in between, so no waiting banner flashes up for a frame.
	local previous = releaseSlot
	releaseSlot = PopupQueue.hold("plotReveal", BANNER_SIZE.Y)
	if previous ~= nil then
		previous()
	end
	ScreenManager.open(SCREEN)
	local card = bannerCard
	if card ~= nil then
		card.Position = UDim2.new(0.5, 0, 0, PopupQueue.placeTop("plotReveal", BANNER_SIZE.Y))
	end
end

-- Closes the banner and frees the centre lane.
local function closeBanner()
	ScreenManager.close(SCREEN)
	local release = releaseSlot
	releaseSlot = nil
	if release ~= nil then
		release()
	end
end

-- The plot overview camera CFrame for plot `index` (world space, from WorldLayout).
local function viewOf(index: number): CFrame
	local origin = WorldLayout.plotOrigin(index)
	local eye = origin:PointToWorldSpace(Config.CameraLocal)
	local look = origin:PointToWorldSpace(Config.LookLocal)
	return CFrame.lookAt(eye, look)
end

-- Ends the running reveal unconditionally: camera back to the character, input unblocked,
-- skip unbound.
local function stop()
	if not playing then
		return
	end
	playing = false
	local current = tween
	if current ~= nil then
		current:Cancel()
		tween = nil
	end
	ContextActionService:UnbindAction(SKIP_ACTION)
	if tapConnection ~= nil then
		tapConnection:Disconnect()
		tapConnection = nil
	end
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera.CameraType = Enum.CameraType.Custom
		local character = Players.LocalPlayer.Character
		local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid ~= nil then
			camera.CameraSubject = humanoid
		end
	end
	InputController.setGameplayBlocked("PlotReveal", false)
	if doneOwed then
		doneOwed = false
		task.spawn(function()
			Remotes.event("PlotRevealDone"):FireServer()
		end)
	end
	task.delay(math.max(0, Config.BannerSeconds - Config.SwoopSeconds - Config.HoldSeconds), function()
		if not playing then
			closeBanner()
		end
	end)
end

-- Ends reveal `myToken` if it is still the running one (skip input, timers).
local function finish(myToken: number)
	if myToken == token then
		stop()
	end
end

--[[
	Plays the reveal for plot `index` (1..WorldLayout.PlotCount). Safe to call again: a newer
	reveal cancels the running one.
	@param index the assigned plot number
]]
function PlotReveal.play(index: number)
	if index ~= index or index < 1 or index > WorldLayout.PlotCount or index % 1 ~= 0 then
		return
	end
	token += 1
	local myToken = token
	stop() -- a newer reveal replaces a running one
	queued = true
	task.spawn(function()
		-- Let a join pop-up (Welcome Back, ...) close first, at most WaitForMenusSeconds.
		local waited = 0
		while ScreenManager.anyModalOpen() and waited < Config.WaitForMenusSeconds do
			waited += task.wait(0.25)
		end
		if myToken ~= token then
			return
		end
		-- Let the server finish placing the plot's builds (Plot<N>.PlotReady) so the swoop shows
		-- them; bounded by Reveal.WaitForPlotSeconds.
		local plotsFolder = Workspace:FindFirstChild(Contract.Names.PlotsFolder)
		local plot = if plotsFolder ~= nil then plotsFolder:FindFirstChild(`Plot{index}`) else nil
		local plotWait = 0
		while plot ~= nil and plot:GetAttribute("PlotReady") == false and plotWait < Config.WaitForPlotSeconds do
			plotWait += task.wait(0.2)
		end
		if myToken ~= token then
			return
		end
		local view = viewOf(index)
		queued = false
		local player = Players.LocalPlayer
		pcall(function()
			player:RequestStreamAroundAsync(view.Position:Lerp(WorldLayout.plotOrigin(index).Position, 0.5), 4)
		end)
		local camera = Workspace.CurrentCamera
		if camera == nil or myToken ~= token then
			if myToken == token then
				queued = false -- no camera: nothing to reveal, never block the tutorial card
				-- Still release the server's hold (it walks the character home on this signal).
				task.spawn(function()
					Remotes.event("PlotRevealDone"):FireServer()
				end)
			end
			return
		end
		openBanner()
		local title = bannerTitle
		if title ~= nil then
			title.Text = `Your plot is #{index}!`
		end
		playing = true
		doneOwed = true
		InputController.setGameplayBlocked("PlotReveal", true)
		ContextActionService:BindActionAtPriority(
			SKIP_ACTION,
			function(_name, state)
				if state == Enum.UserInputState.Begin then
					finish(myToken)
					return Enum.ContextActionResult.Sink
				end
				return Enum.ContextActionResult.Pass
			end,
			false,
			SKIP_PRIORITY,
			Enum.KeyCode.ButtonA,
			Enum.KeyCode.Space,
			Enum.KeyCode.Return,
			Enum.UserInputType.MouseButton1
		)
		tapConnection = UserInputService.TouchTapInWorld:Connect(function()
			finish(myToken)
		end)
		camera.CameraType = Enum.CameraType.Scriptable
		local reduced = OfferFx.reducedMotion()
		if reduced then
			camera.CFrame = view
			task.delay(Config.ReducedHoldSeconds, finish, myToken)
			return
		end
		-- Total length from the server (PlotRevealSeconds), split into swoop + hold.
		local total =
			Contract.num(player:GetAttribute(Contract.Attr.PlotRevealSeconds), Config.SwoopSeconds + Config.HoldSeconds)
		local swoopSeconds = math.clamp(total - Config.HoldSeconds, 0.8, 6)
		local swoop = TweenService:Create(
			camera,
			TweenInfo.new(swoopSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ CFrame = view }
		)
		tween = swoop
		swoop:Play()
		swoop.Completed:Once(function(state: Enum.PlaybackState)
			if state == Enum.PlaybackState.Completed then
				task.delay(Config.HoldSeconds, finish, myToken)
			end
		end)
	end)
end

-- Reacts to the server assigning (or changing) the local player's plot; plays only after the
-- join loading screen (LoadingDone).
local function onPlotIndex()
	local index = Contract.num(Players.LocalPlayer:GetAttribute(Contract.Attr.PlayerPlotIndex), 0)
	if index > 0 and index ~= lastShown then
		lastShown = index
		LoadingGate.onDone(function()
			-- Still the current assignment once loading finished?
			if Contract.num(Players.LocalPlayer:GetAttribute(Contract.Attr.PlayerPlotIndex), 0) == index then
				PlotReveal.play(index)
			end
		end)
	end
end

--[[ True while a reveal (banner + camera) is running or queued to start. ]]
function PlotReveal.isPlaying(): boolean
	return playing or queued
end

--[[ Starts listening for plot assignments (once; TycoonClient calls it). ]]
function PlotReveal.start()
	if started then
		return
	end
	started = true
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui ~= nil and not ScreenManager.isRegistered(SCREEN) then
		ScreenManager.register(bannerScreen, playerGui)
	end
	Players.LocalPlayer:GetAttributeChangedSignal(Contract.Attr.PlayerPlotIndex):Connect(onPlotIndex)
	-- Studio playtests often start with the attribute already set: reveal it once after boot.
	if RunService:IsRunning() then
		task.defer(onPlotIndex)
	end
end

return PlotReveal
