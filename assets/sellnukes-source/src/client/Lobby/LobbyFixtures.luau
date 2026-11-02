--!strict
--[[
	LobbyFixtures — makes the Nuke Town lobby fixtures WORK (owner R99 "the lobby lucky spin doesnt
	work") and labels them (owner R101). Root causes: Shared/Config/LobbyConfig header.

	Per LobbyConfig.Fixtures row:
		* prompt   a client-only invisible part at HubLayout.anchors[anchor].prompt with a
		           ProximityPrompt (ActionText / ObjectText from config; keyboard E, gamepad X,
		           tap on touch — Roblox draws the right glyph per device). Triggered → the
		           fixture's screen via ScreenManager.open(screen, { source = "prompt" }).
		* action   owner R11 console + mobile: the "LobbyFixture" platform context is on while a
		           fixture's prompt point is within LobbyConfig.ActionReach, binding the LobbyUse
		           action (E / gamepad X / a big touch button) whose hint + touch caption is the
		           fixture's `hint` ("Spin!"); pressing it opens the nearest fixture's screen.
		* walk-on  the Lucky Wheel platform: stepping onto the stage in front of the wheel opens the
		           wheel once per entry (LobbyLogic.walkOnStep rules), polled at WalkOn.PollHz.
		* sign     the art's own board piece gets its caption (Client/Lobby/StallSigns) + a live
		           status line from RewardsBadges ("SPIN NOW!" / "Spin in 4m", "Join for a gift!").
		* spin     the physical wheel (anchors.LuckyWheelStage.wheelModel) drifts slowly while the
		           camera is near and spins (eased out over LuckySpinConfig.SpinAnimationSeconds) on
		           each of the local player's own successful SpinResults. Cosmetic + local only.
	Everything is presentation: spins / claims / codes stay server-validated intents inside the
	screens (LuckySpinService, GroupRewardService, CodesService).

	World + streaming: the fixtures exist only in Nuke Town ("main"); prompts are disabled while the
	player is in another world. The art models stream in / out (Opportunistic streaming), so signs
	and the wheel model are re-found every LobbyConfig.RescanSeconds (a few FindFirstChild calls),
	never cached past their lifetime.

	Performance: no loop of its own — Client/Lobby/LobbyController calls `step(dt)` from its one
	Heartbeat; per frame only the wheel's PivotTo while it moves near the camera; the walk-on poll,
	sign status and rescans run on accumulators.

	Analytics: each open reports through the screen's own ClientAnalytics.screenOpened with source
	"prompt" (the existing world-prompt source; "hub" means a Rewards hub tile).

	Connects to: Shared/Config/{LobbyConfig, HubLayout, LuckySpinConfig, Worlds/WorldsConfig},
	Shared/Net/Remotes (SpinResult), Client/Lobby/{LobbyLogic, StallSigns}, UI/{ScreenManager,
	RewardsBadges}, Worlds/WorldClient, Tycoon/Fx/FxQuality, Controllers/InputController,
	Platform/ActionMap (guarded), ClientState (reduced-motion setting).

	Example (Studio console, client):
		local lf = require(game.Players.LocalPlayer.PlayerScripts.Client.Lobby.LobbyFixtures)
		print(lf.stats()) --> { prompts = 3, signs = 4, wheelModel = true, walkOnInside = false, ... }
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.ClientState)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local HubLayout = require(ReplicatedStorage.Shared.Config.HubLayout)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local LobbyConfig = require(ReplicatedStorage.Shared.Config.LobbyConfig)
local LobbyLogic = require(script.Parent.LobbyLogic)
local LuckySpinConfig = require(ReplicatedStorage.Shared.Config.LuckySpinConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RewardsBadges = require(script.Parent.Parent.UI.RewardsBadges)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local StallSigns = require(script.Parent.StallSigns)
local WorldClient = require(script.Parent.Parent.Worlds.WorldClient)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local LOCAL = Players.LocalPlayer
local ACTION = "LobbyUse"
local CONTEXT = "LobbyFixture"
local SOURCE = "prompt"
local FOLDER_NAME = "LobbyFixturesClient"

type Fixture = LobbyConfig.Fixture

-- One fixture at runtime.
type Entry = {
	fixture: Fixture,
	anchor: any, -- HubLayout.anchors[fixture.anchor] (nil = missing anchor: fixture skipped)
	promptPoint: Vector3 | false, -- false = no prompt (sign-only fixture)
	prompt: ProximityPrompt?,
	sign: StallSigns.Sign?,
	walkOn: LobbyConfig.WalkOn?,
}

local LobbyFixtures = {}

local entries: { Entry } = {}
local promptPoints: { Vector3 | false } = {}
local folder: Folder? = nil
local started = false
local inMain = true

-- Walk-on (Lucky Wheel platform).
local walkOnState = LobbyLogic.newWalkOn()
local walkOnEntry: Entry? = nil
local pollAccum = 0
local rescanAccum = math.huge -- first step rescans at once
local statusAccum = math.huge

-- Physical wheel (cosmetic).
local wheelEntry: Entry? = nil
local wheelModel: Model? = nil
local wheelAngle = 0
local appliedAngle: number? = nil
local spinFrom = 0
local spinDelta = 0
local spinT = 0
local spinning = false
local random = Random.new()

-- Reduced motion: the Roblox accessibility setting or SellNukes' own setting.
local function isReduced(): boolean
	if GuiService.ReducedMotionEnabled then
		return true
	end
	local profile = ClientState.profile
	local settings = profile and (profile :: any).settings
	return type(settings) == "table" and settings.reducedMotion == true
end

-- The local character's root part (nil while dead / loading).
local function rootPart(): BasePart?
	local character = LOCAL.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

-- The art model of an anchor in Workspace.Hub.Art (nil while streamed out / not built yet).
local function artModel(name: unknown): Model?
	if type(name) ~= "string" then
		return nil
	end
	local hub = Workspace:FindFirstChild("Hub")
	local art = if hub ~= nil then hub:FindFirstChild("Art") else nil
	local model = if art ~= nil then art:FindFirstChild(name) else nil
	return if model ~= nil and model:IsA("Model") then model else nil
end

--[[
	Opens a fixture's screen (prompt / action / walk-on). Skips unknown screens and a screen that is
	already open.
	@return boolean — true when it asked ScreenManager to open
]]
local function openFixture(entry: Entry): boolean
	local screen = entry.fixture.screen
	if screen == nil or not ScreenManager.isRegistered(screen) or ScreenManager.isOpen(screen) then
		return false
	end
	ScreenManager.open(screen, { source = SOURCE })
	return true
end

-- Builds the client prompt part of one fixture.
local function buildPrompt(entry: Entry, parent: Instance)
	local spec = entry.fixture.prompt
	local cf = entry.anchor.prompt
	if spec == nil or typeof(cf) ~= "CFrame" then
		entry.promptPoint = false
		return
	end
	local point = Instance.new("Part")
	point.Name = `Prompt_{entry.fixture.id}`
	point.Size = Vector3.new(1, 1, 1)
	point.CFrame = cf
	point.Transparency = 1
	point.Anchored = true
	point.CanCollide = false
	point.CanQuery = false
	point.CanTouch = false
	point.CastShadow = false
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LobbyPrompt"
	prompt.ActionText = spec.action
	prompt.ObjectText = spec.object
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = LobbyConfig.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.Enabled = inMain
	prompt.Parent = point
	prompt.Triggered:Connect(function()
		openFixture(entry)
	end)
	point.Parent = parent
	entry.prompt = prompt
	entry.promptPoint = cf.Position
end

-- Shows / hides every prompt with the current world.
local function applyWorld()
	inMain = WorldClient.current() == WorldsConfig.MAIN
	for _, entry in entries do
		local prompt = entry.prompt
		if prompt ~= nil and prompt.Enabled ~= inMain then
			prompt.Enabled = inMain
		end
	end
end

-- The live status line of a sign (RewardsBadges feature), or "" (title only).
local function statusOf(entry: Entry): (string, string?)
	local sign = entry.fixture.sign
	local feature = if sign ~= nil then sign.feature else nil
	if feature == nil then
		return "", nil
	end
	local state = RewardsBadges.forFeature(feature)
	if state == nil then
		return "", nil
	end
	local text, tone = RewardsBadges.statusText(state, Workspace:GetServerTimeNow())
	return text, tone
end

-- Re-finds streamed art: (re)builds missing signs, drops dead ones, finds the wheel model.
local function rescan()
	for _, entry in entries do
		local spec = entry.fixture.sign
		local sign = entry.sign
		if sign ~= nil and not StallSigns.alive(sign) then
			StallSigns.destroy(sign)
			entry.sign = nil
			sign = nil
		end
		if spec ~= nil and sign == nil then
			local model = artModel(entry.anchor.model)
			local board = if model ~= nil then model:FindFirstChild(spec.piece or "Sign") else nil
			if board ~= nil and board:IsA("BasePart") then
				local built = StallSigns.build(board, spec)
				local text, tone = statusOf(entry)
				StallSigns.setStatus(built, text, tone)
				entry.sign = built
			end
		end
	end
	local entry = wheelEntry
	if entry ~= nil then
		local model = artModel(entry.anchor.wheelModel)
		if model ~= wheelModel then
			wheelModel = model
			appliedAngle = nil -- a fresh copy streamed in at its base pose
		end
	end
end

-- Refreshes the status lines of the signs that exist.
local function refreshStatus()
	for _, entry in entries do
		local sign = entry.sign
		if sign ~= nil then
			local text, tone = statusOf(entry)
			StallSigns.setStatus(sign, text, tone)
		end
	end
end

-- Walk-on poll: opens the wheel once per platform entry.
local function pollWalkOn()
	local entry = walkOnEntry
	local walkOn = if entry ~= nil then entry.walkOn else nil
	if entry == nil or walkOn == nil then
		return
	end
	local root = rootPart()
	local inside = inMain and root ~= nil and LobbyLogic.insideWalkOn(entry.anchor.cf, walkOn, root.Position)
	local blocked = ScreenManager.anyModalOpen()
	if LobbyLogic.walkOnStep(walkOnState, inside == true, os.clock(), blocked) then
		openFixture(entry)
	end
end

-- The physical wheel: spin / idle drift, PivotTo only when the angle changed and it is near.
local function stepWheel(dt: number)
	local entry = wheelEntry
	if entry == nil or not inMain then
		return
	end
	local camera = Workspace.CurrentCamera
	local base = entry.anchor.wheel :: CFrame
	local near = camera ~= nil and (camera.CFrame.Position - base.Position).Magnitude <= LobbyConfig.Wheel.IdleRange
	if spinning then
		spinT += dt
		wheelAngle = spinFrom + LobbyLogic.wheelAngle(spinT, LuckySpinConfig.SpinAnimationSeconds, spinDelta)
		if spinT >= LuckySpinConfig.SpinAnimationSeconds then
			spinning = false
		end
	elseif near and FxQuality.tier() ~= "Low" and not isReduced() then
		wheelAngle += math.rad(LobbyConfig.Wheel.IdleDegPerSecond) * dt
	end
	wheelAngle %= math.pi * 2
	local model = wheelModel
	if model == nil or model.Parent == nil or not near or appliedAngle == wheelAngle then
		return
	end
	appliedAngle = wheelAngle
	-- The wheel faces -Z; spinning = rotating about its local Z axis (HubLayout anchor contract).
	model:PivotTo(base * CFrame.Angles(0, 0, -wheelAngle))
end

-- A SpinResult for this player: spin the physical wheel too (instant with reduced motion).
local function onSpinResult(raw: unknown)
	if wheelEntry == nil or type(raw) ~= "table" or (raw :: any).ok ~= true then
		return
	end
	local delta = (LobbyConfig.Wheel.Turns + random:NextNumber()) * math.pi * 2
	if isReduced() then
		spinning = false
		wheelAngle = (wheelAngle + delta) % (math.pi * 2)
		return
	end
	spinFrom = wheelAngle
	spinDelta = delta
	spinT = 0
	spinning = true
end

--[[
	Console + mobile (owner R11): the LobbyFixture context near a prompt point binds LobbyUse (E /
	gamepad X / touch button, hint = the fixture's `hint`); pressing it opens that fixture. Guarded:
	a missing Platform layer leaves the ProximityPrompts.
]]
local function wirePlatform()
	local platform = script.Parent.Parent:FindFirstChild("Platform")
	local module = if platform ~= nil then platform:FindFirstChild("ActionMap") else nil
	if module == nil or not module:IsA("ModuleScript") then
		return
	end
	local ok, result = pcall(require, module)
	local ActionMap: any = if ok then result else nil
	if type(ActionMap) ~= "table" or type(ActionMap.addContextProvider) ~= "function" then
		return
	end
	local addContextProvider = ActionMap.addContextProvider :: (provider: (root: Vector3) -> any) -> any
	local setHintText = ActionMap.setHintText :: (action: string, text: string?) -> ()
	local shownHint: string? = nil
	addContextProvider(function(root: Vector3): { [string]: boolean }
		local index = if inMain then LobbyLogic.nearestFixture(promptPoints, root, LobbyConfig.ActionReach) else nil
		local hint = if index ~= nil then entries[index].fixture.hint else nil
		if hint ~= shownHint then
			shownHint = hint
			setHintText(ACTION, hint)
		end
		return { [CONTEXT] = index ~= nil }
	end)
	InputController.ActionPressed:Connect(function(action: string)
		if action ~= ACTION or not inMain then
			return
		end
		local root = rootPart()
		local index = if root ~= nil
			then LobbyLogic.nearestFixture(promptPoints, root.Position, LobbyConfig.ActionReach)
			else nil
		if index ~= nil then
			openFixture(entries[index])
		end
	end)
end

--[[
	Advances the fixtures (LobbyController's Heartbeat): wheel motion every frame, the walk-on poll,
	sign status refreshes and art rescans on their accumulators.
]]
function LobbyFixtures.step(dt: number)
	if not started then
		return
	end
	stepWheel(dt)
	pollAccum += dt
	if pollAccum >= 1 / LobbyConfig.WalkOn.PollHz then
		pollAccum = 0
		pollWalkOn()
	end
	rescanAccum += dt
	if rescanAccum >= LobbyConfig.RescanSeconds then
		rescanAccum = 0
		if inMain then
			rescan()
		end
	end
	statusAccum += dt
	if statusAccum >= LobbyConfig.Sign.StatusRefresh then
		statusAccum = 0
		if inMain then
			refreshStatus()
		end
	end
end

--[[ Builds the prompts, wires world / platform / spin results (idempotent). ]]
function LobbyFixtures.start()
	if started then
		return
	end
	started = true
	local anchors: any = (HubLayout :: any).anchors
	local root = Instance.new("Folder")
	root.Name = FOLDER_NAME
	root.Parent = Workspace
	folder = root
	inMain = WorldClient.current() == WorldsConfig.MAIN
	for _, fixture in LobbyConfig.Fixtures do
		local anchor = if type(anchors) == "table" then anchors[fixture.anchor] else nil
		if type(anchor) ~= "table" or typeof(anchor.cf) ~= "CFrame" then
			warn(`[LobbyFixtures] HubLayout.anchors.{fixture.anchor} missing; {fixture.id} skipped`)
			continue
		end
		local entry: Entry = {
			fixture = fixture,
			anchor = anchor,
			promptPoint = false,
			prompt = nil,
			sign = nil,
			walkOn = fixture.walkOn,
		}
		buildPrompt(entry, root)
		if fixture.walkOn ~= nil then
			walkOnEntry = entry
		end
		if fixture.spin == true and typeof(anchor.wheel) == "CFrame" then
			wheelEntry = entry
		end
		table.insert(entries, entry)
		table.insert(promptPoints, entry.promptPoint)
	end
	WorldClient.Changed:Connect(applyWorld)
	applyWorld()
	RewardsBadges.start()
	RewardsBadges.Updated:Connect(function()
		if inMain then
			refreshStatus()
		end
	end)
	task.spawn(function()
		Remotes.event("SpinResult").OnClientEvent:Connect(onSpinResult)
	end)
	wirePlatform()
end

--[[ Debug / QA snapshot (tools/qa/lobby.py). ]]
function LobbyFixtures.stats(): { [string]: any }
	local prompts, signs = 0, 0
	local signTexts: { [string]: string } = {}
	for _, entry in entries do
		if entry.prompt ~= nil then
			prompts += 1
		end
		local sign = entry.sign
		if sign ~= nil then
			signs += 1
			signTexts[entry.fixture.id] = `{sign.title.Text} | {sign.statusText}`
		end
	end
	return {
		started = started,
		inMain = inMain,
		folder = folder ~= nil,
		prompts = prompts,
		signs = signs,
		signTexts = signTexts,
		wheelModel = wheelModel ~= nil and wheelModel.Parent ~= nil,
		wheelAngle = math.deg(wheelAngle),
		spinning = spinning,
		walkOnInside = walkOnState.inside,
	}
end

--[[ QA: the world CFrame of a fixture's walk-on volume centre (nil when it has none). ]]
function LobbyFixtures.walkOnCFrame(id: string): CFrame?
	for _, entry in entries do
		local walkOn = entry.walkOn
		if entry.fixture.id == id and walkOn ~= nil then
			return entry.anchor.cf * walkOn.offset
		end
	end
	return nil
end

return LobbyFixtures
