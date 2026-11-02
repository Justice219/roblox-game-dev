--!strict
--[[
	FtueTracker — reports WHERE in the first minute a new player is, so the next analytics day
	shows exactly where people stall (owner R78 §6).

	Why: on 2026-10-31 the live funnel jumped from `plotReady` straight to `firstPad`: 7 first
	sessions ended at "plotReady" and nobody could tell whether they left on the loading screen,
	during the plot reveal, on the tutorial card or while looking for the pad. Two client steps
	that existed in the config (`loadingDone`, `hudShown`) were never sent by any code. This
	controller sends them and three new ones, each ONCE per session through ClientAnalytics.step
	(the server counts each once per PROFILE and checks plausibility: Server/Analytics/Sessions
	+ Shared/Analytics/FtueLogic.claimPlausible):
		loadingDone        the loading screen handed over (LocalPlayer.LoadingDone; NOT the gate's
		                   safety timeout, which means the screen never reported)
		hudShown           the HUD became visible after loading
		tutorialSeen       the tutorial hint (objective chip + arrows) is genuinely on screen: no
		                   loading screen, no reveal camera, no window over it, HUD not hidden
		firstMove          the character got FtueConfig.Track.MoveStuds (12) away, by the player's
		                   own steering, from where they gained control on their plot (teleports,
		                   respawns and the server's walk-home re-anchor instead of counting)
		firstScreenClosed  the first window (modal screen) the player closed after loading
	tutorialSeen and firstScreenClosed wait for the PlotRevealed attribute (R135,
	FtueLogic.claimReady): the server refuses them before the reveal ends, and a refused
	once-per-session claim was never sent again.
	Plus `tutorialShown(step)` (tycoon "tutClient:<N>") each time a new tutorial step's hint is
	genuinely visible, so the server's own tut:<N> can be compared with what was actually shown.

	API:
		FtueTracker.hasMoved(): boolean   the player made their first real move this session
		FtueTracker.Moved                 Signal() fired once, on that move (coach card listens)

	Performance: ONE sampling thread (FtueConfig.Track.SampleSeconds) that ends as soon as every
	one-shot step is sent and the tutorial is over (hard cap Track.MaxSeconds); a couple of
	attribute reads + one distance per sample. One ScreenManager.Closed connection, dropped after
	the first close. Never yields a caller, never throws into the boot.

	Controller contract: Init() / Start() ("Tycoon/FtueTracker" in init.client.luau).

	Connects to: Analytics/ClientAnalytics (step, tutorialShown), Shared/Analytics/FtueLogic,
	Shared/Config/FtueConfig, Tycoon/{Tutorial, PlotReveal}, UI/{ScreenManager,
	Widgets/LoadingGate}, Screens/TycoonTutorial (Moved).

	Example: (automatic) a new player walks 12 studs toward the Workbench pad → FunnelStep("firstMove").
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientAnalytics = require(script.Parent.Parent.Analytics.ClientAnalytics)
local FtueConfig = require(ReplicatedStorage.Shared.Config.FtueConfig)
local FtueLogic = require(ReplicatedStorage.Shared.Analytics.FtueLogic)
local LoadingGate = require(script.Parent.Parent.UI.Widgets.LoadingGate)
local PlotReveal = require(script.Parent.PlotReveal)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Tutorial = require(script.Parent.Tutorial)

local Track = FtueConfig.Track

-- Player attributes written by the loading screen (client) and PlotService (server).
local LOADING_DONE_ATTR = "LoadingDone"
local PLOT_REVEALED_ATTR = "PlotRevealed"
local HUD_SCREEN = "Hud"

local FtueTracker = {}

-- Fires once when the player makes their first real move this session.
FtueTracker.Moved = Signal.new() :: Signal.Signal<>

local started = false
local sent: { [string]: boolean } = {}
local moved = false
local move = FtueLogic.newMove()
local lastTutorialShown = 0

--[[ True once the player made their first real move this session. ]]
function FtueTracker.hasMoved(): boolean
	return moved
end

-- Sends a client funnel step once per session (ClientAnalytics de-dups too; this keeps the
-- loop's "all done?" check cheap).
local function send(stepId: string)
	if sent[stepId] then
		return
	end
	sent[stepId] = true
	ClientAnalytics.step(stepId)
end

-- True when the HUD ScreenGui is on screen.
local function hudShown(): boolean
	if not ScreenManager.isOpen(HUD_SCREEN) then
		return false
	end
	local gui = ScreenManager.getGui(HUD_SCREEN)
	return gui ~= nil and gui.Enabled
end

-- One sample of the movement tracker (only after the plot reveal walked the player home).
local function sampleMove(player: Player, dt: number)
	if moved or player:GetAttribute(PLOT_REVEALED_ATTR) ~= true then
		return
	end
	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if humanoid == nil or root == nil or not root:IsA("BasePart") or humanoid.Health <= 0 then
		return
	end
	local position = root.Position
	local steering = humanoid.MoveDirection.Magnitude > 0.05
	if FtueLogic.sampleMove(move, position.X, position.Z, dt, humanoid.WalkSpeed, steering) then
		moved = true
		send("firstMove")
		FtueTracker.Moved:Fire()
	end
end

-- One sample of the tutorial-hint visibility (tutorialSeen + the per-step tutorialShown).
local function sampleHint()
	local stepNumber = Tutorial.step()
	local visible = FtueLogic.hintVisible({
		loadingDone = LoadingGate.isDone(),
		revealPlaying = PlotReveal.isPlaying(),
		modalOpen = ScreenManager.anyModalOpen(),
		focusMode = ScreenManager.isFocusMode(),
		hudShown = hudShown(),
		step = stepNumber,
		hasText = Tutorial.hintText() ~= nil,
	})
	if not visible then
		return
	end
	-- R135: the server counts tutorialSeen only after the plot reveal (FtueLogic.claimReady); the
	-- per-step tutorialShown below is unchecked and keeps reporting as before.
	if FtueLogic.claimReady("tutorialSeen", Players.LocalPlayer:GetAttribute(PLOT_REVEALED_ATTR) == true) then
		send("tutorialSeen")
	end
	if stepNumber ~= lastTutorialShown then
		lastTutorialShown = stepNumber
		ClientAnalytics.tutorialShown(stepNumber)
	end
end

-- True when the sampling loop has nothing left to watch: the first move and the HUD are
-- reported and no tutorial step is running any more (each step's hint is reported while it runs).
local function finished(): boolean
	local tutorialOver = Tutorial.step() <= 0 or Tutorial.hintText() == nil
	return moved and sent.hudShown == true and tutorialOver
end

-- The one sampling thread (ends when finished or after Track.MaxSeconds).
local function runLoop(player: Player)
	local startedAt = os.clock()
	local last = startedAt
	while os.clock() - startedAt < Track.MaxSeconds do
		task.wait(Track.SampleSeconds)
		local now = os.clock()
		local dt = now - last
		last = now
		if LoadingGate.isDone() then
			if not sent.hudShown and hudShown() then
				send("hudShown")
			end
			local ok, err = pcall(sampleHint)
			if not ok then
				warn(`[FtueTracker] hint sample failed: {err}`)
			end
		end
		sampleMove(player, dt)
		if finished() then
			return
		end
	end
end

function FtueTracker.Init() end

--[[ Starts the trackers (once). Never yields. ]]
function FtueTracker.Start()
	if started then
		return
	end
	started = true
	local player = Players.LocalPlayer
	-- loadingDone: only a real hand-off (the gate's safety timeout opens without the attribute).
	LoadingGate.onDone(function()
		if player:GetAttribute(LOADING_DONE_ATTR) == true then
			send("loadingDone")
		end
	end)
	-- firstScreenClosed: the first window the player closes after loading.
	local closedConnection: Signal.Connection? = nil
	closedConnection = ScreenManager.Closed:Connect(function(name: string)
		if not LoadingGate.isDone() or not ScreenManager.isModal(name) then
			return
		end
		-- R135: a window closed while the plot reveal still plays would be refused for good; keep
		-- listening for the first one closed after it (FtueLogic.claimReady).
		if not FtueLogic.claimReady("firstScreenClosed", player:GetAttribute(PLOT_REVEALED_ATTR) == true) then
			return
		end
		send("firstScreenClosed")
		local connection = closedConnection
		if connection ~= nil then
			connection:Disconnect()
			closedConnection = nil
		end
	end)
	-- A respawn or the server's walk-home teleports the character: start measuring from there.
	player.CharacterAdded:Connect(function()
		if not moved then
			move = FtueLogic.newMove()
		end
	end)
	player:GetAttributeChangedSignal(PLOT_REVEALED_ATTR):Connect(function()
		if not moved then
			move = FtueLogic.newMove()
		end
	end)
	task.spawn(runLoop, player)
end

FtueTracker.start = FtueTracker.Start

return FtueTracker
