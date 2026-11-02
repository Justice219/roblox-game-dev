--!strict
--[[
	LaunchCam — the launch cinematic director (owner R54: "when you launch an attack on somebody
	that you follow the missile as well with like an animated 3, 2, 1. And a voiceover").

	When the server accepts one of YOUR launches (normal / revenge / barrage / Rival Factory), its
	NukeFlight reaches AttackClient, which calls `LaunchCam.play(flight)`. Then:
		1. COUNTDOWN (inside the server lead-in, AttackConfig.Flight.LeadIn): the picker / any window
		   closes, the camera eases to a shot behind your silo and slowly dollies in while the stud
		   "3 … 2 … 1" punches in (UI/Screens/LaunchCountdown), each beat with its announcer line
		   (vo_three / vo_two / vo_one) and a soft haptic tick; "LAUNCH!" + confetti + vo_launch +
		   a rumble exactly at the server's t0.
		2. LIFT-OFF: light shake + FOV kick while the look follows the rising nuke.
		3. CHASE: a critically damped spring keeps the camera behind / above the toy nuke along its
		   arc, looking ahead and, late in the flight, toward the target.
		4. IMPACT: the camera decelerates off the nuke into a 3/4 impact shot (zooming in a little —
		   the slow-mo feel, camera ease only, never time scaling), then holds on the AA POP
		   ("INTERCEPTED!", vo_intercepted) or the confetti hit ("DIRECT HIT!", vo_direct_hit) with a
		   slow orbit; a knockdown topple seen on that area (KnockdownConfig tag + attributes) adds
		   "KNOCKDOWN!" + vo_knockdown and a longer hold.
		5. RETURN: eases back to the player's own camera (following the character if it moved).

	Authority: purely presentational. Every time is `Workspace:GetServerTimeNow() - t0` — the clock
	FlightRenderer draws the nuke with — so the camera, the countdown and the nuke can never drift;
	the hit time and outcome come from the server's NukeFlight. A late packet joins mid-countdown.

	Rules (owner R54 / R11 / R7):
		* Only the LOCAL player's flights (fromUserId == me) — other players' launches never move your
		  camera. Barrage: the first nuke only (later flights are ignored while one plays).
		* Skippable any time after a short grace: tap / click anywhere, SKIP (A), B / X / Backspace
		  (ScreenManager Back), Esc (the Roblox menu opening ends it). Skip = instant ease back.
		* Input is held only while the cinematic plays (≤ lead-in + flight + hold, watchdog-capped):
		  the modal blocks gameplay actions and pauses a gamepad character, keyboard movement is sunk
		  so your character stays put, touch controls + proximity prompts hide; all restored when
		  the short return ease ends (0.35 s after a skip). Respawn / another script taking the
		  camera ends it at once.
		* Reduce Motion: no shake / FOV kick / orbit, hard cuts between static shots (silo → wide arc
		  → impact), an instant return. FxQuality tier sets the overlay particle counts.
	Performance: ONE BindToRenderStep (Camera priority) only while active; zero Instance.new per
	frame; a handful of raycasts per cinematic (shot occlusion) and ≤ 3 tag scans for the knockdown.

	Connects to: Client/Attack/AttackClient (calls play), Client/Attack/FlightRenderer (same clock),
	Shared/Attack/{AttackGeometry, FlightMath, LaunchCamMath}, Shared/Config/{LaunchCamConfig,
	AttackConfig, KnockdownConfig, AudioConfig}, UI/{ScreenManager, Widgets/OfferFx,
	Screens/LaunchCountdown/CountdownOverlay}, Client/Audio/Sound, Client/Platform/Haptics,
	Client/Tycoon/Fx/FxQuality, Client/Analytics/ClientAnalytics (guarded).

	Example:
		-- AttackClient.onFlight, after FlightRenderer.add:
		if flight.fromUserId == LOCAL.UserId then LaunchCam.play(flight) end
		LaunchCam.skip()          -- e.g. a teleport
		print(LaunchCam.stats())  --> { active = false, plays = 3, skips = 1, ... }
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)
local ClientState = require(script.Parent.Parent.ClientState)
local CountdownOverlay = require(script.Parent.Parent.UI.Screens.LaunchCountdown.CountdownOverlay)
local FlightMath = require(ReplicatedStorage.Shared.Attack.FlightMath)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local Haptics = require(script.Parent.Parent.Platform.Haptics)
local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local LaunchCamConfig = require(ReplicatedStorage.Shared.Config.LaunchCamConfig)
local LaunchCamMath = require(ReplicatedStorage.Shared.Attack.LaunchCamMath)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Sound = require(script.Parent.Parent.Audio.Sound)

local LaunchCam = {}

local LOCAL = Players.LocalPlayer
local IS_STUDIO = RunService:IsStudio()
local COUNTDOWN = LaunchCamConfig.Countdown
local SHOTS = LaunchCamConfig.Shots
local WATCH = LaunchCamConfig.KnockdownWatch
local UP = Vector3.new(0, 1, 0)
local RENDER_BINDING = "SN_LaunchCam"
local FREEZE_ACTION = "SN_LaunchCamFreeze"
local SKIP_ACTION = "SN_LaunchCamSkip"
local FOCUS_REASON = "LaunchCam"
-- Seconds of the eased cut from the player's camera into the silo shot (not with Reduce Motion).
local INTRO_SECONDS = 0.35
-- A flight whose outcome is this close (or past) is not worth a cinematic.
local MIN_REMAINING = 0.6

-- The NukeFlight fields the cinematic reads (AttackClient's FlightRenderer.FlightData has them all).
export type Flight = {
	id: number,
	fromUserId: number,
	toUserId: number,
	t0: number,
	duration: number,
	intercepted: boolean,
	interceptAt: number,
	kind: string,
	fromPlot: number,
	toPlot: number,
	silo: number,
	impact: number,
	area: number, -- owner R50 aimed area / rival section (0 = legacy impact index)
	sx: number, -- server scatter offsets (studs)
	sz: number,
	toBot: string?, -- an admin test bot's key (owner R51), nil otherwise
}

type State = "idle" | "playing" | "returning"

type Saved = {
	cameraType: Enum.CameraType,
	subject: Instance?,
	cframe: CFrame,
	fov: number,
	touchControls: boolean,
	prompts: boolean?,
	rootPosition: Vector3?, -- character root when the cinematic started (return follows a move)
}

local state: State = "idle"
local current: Flight? = nil
-- The running cinematic's shot (arc, timeline, occlusion, chase springs: LaunchCamMath.frame).
local shot: LaunchCamMath.Shot? = nil
local saved: Saved? = nil
local camera: Camera? = nil
local reduced = false
local openedClock = 0
local holdUntil = 0
local watchdogClock = 0
-- The outcome shot's occlusion is measured once, when the approach starts (target streamed in).
local impactReachReady = false
-- One-shot events.
local beatsSaid: { [number]: boolean } = {}
local launchSaid = false
local outcomeShown = false
local knockSamples = 0
local knockFound = false
local knockSayAt: number? = nil
local knockSaid = false
-- Last applied camera (the return starts from it).
local lastCFrame = CFrame.identity
local lastFov = 70
-- Return.
local returnClock = 0
local returnSeconds = 0
local returnFromCFrame = CFrame.identity
local returnFromFov = 70
local connections: { RBXScriptConnection } = {}
local stats = { plays = 0, skips = 0, completed = 0, aborted = 0 }
local analyticsModule: any = nil
-- The announcer line playing now (cut when the next one starts or on a skip).
local currentVoice: string? = nil
local voicesWarmed = false

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- Clamps x into [0, 1].
local function clamp01(x: number): number
	return math.clamp(LaunchCamMath.finite(x, 0), 0, 1)
end

--[[
	Every announcer key the cinematic can say (countdown + LAUNCH! + the three outcome shouts).
	Built once from LaunchCamConfig so a renamed key is warmed and cut like the rest.
]]
local VOICE_KEYS: { string } = {}
for _, key in COUNTDOWN.Voice do
	table.insert(VOICE_KEYS, key)
end
table.insert(VOICE_KEYS, COUNTDOWN.LaunchVoice)
for _, shout in LaunchCamConfig.Outcome.Shouts do
	table.insert(VOICE_KEYS, shout.voice)
end

--[[
	Fetches the announcer lines ahead of the first launch (they are not in the join-time preload
	set). Idempotent; Sound.warm runs off-thread and ignores keys that are not uploaded.
]]
local function warmVoices()
	if voicesWarmed then
		return
	end
	voicesWarmed = true
	Sound.warm(VOICE_KEYS)
end

--[[
	Plays an announcer line, cutting the previous one (lines run ~1.2–1.8 s, beats are 1 s). A key
	AudioConfig does not define is skipped silently.
]]
local function say(key: string)
	if AudioConfig.Sfx[key] == nil and AudioConfig.Aliases[key] == nil then
		return
	end
	local previous = currentVoice
	if previous ~= nil and previous ~= key then
		Sound.stop(previous)
	end
	currentVoice = key
	Sound.play(key)
end

-- Cuts the announcer (a skip ends the show at once).
local function hush()
	local previous = currentVoice
	if previous ~= nil then
		Sound.stop(previous)
		currentVoice = nil
	end
end

--[[ A haptic preset by config name (unknown names are ignored by Haptics). ]]
local function buzz(name: string)
	pcall(Haptics.play, name :: any)
end

-- Reports the cinematic to the client funnel (guarded: analytics never breaks play).
local function reportPlay()
	if analyticsModule == nil then
		local ok, module = pcall(function(): any
			return require(script.Parent.Parent.Analytics.ClientAnalytics) :: any
		end)
		analyticsModule = if ok then module else false
	end
	if analyticsModule ~= false then
		pcall(analyticsModule.screenOpened, "Launch", "auto")
	end
end

-- The local character's root part, if any.
local function rootPart(): BasePart?
	local character = LOCAL.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

--[[
	How far an eye may sit from `subject` toward `eye` before scenery blocks the view (one raycast,
	excluding the character and the flight FX). math.huge when clear.
]]
local function reach(subject: Vector3, eye: Vector3): number
	local origin = subject + UP * LaunchCamMath.RayLift
	local direction = eye - origin
	if direction.Magnitude < 1 or not LaunchCamMath.finiteVector(direction) then
		return math.huge
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	if LOCAL.Character ~= nil then
		table.insert(exclude, LOCAL.Character)
	end
	local flights = Workspace:FindFirstChild("SN_AttackFlights")
	if flights ~= nil then
		table.insert(exclude, flights)
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	local result = Workspace:Raycast(origin, direction, params)
	if result == nil then
		return math.huge
	end
	return math.max(result.Distance - SHOTS.OcclusionClearance, 6)
end

-- The display name of the flight's target (a player or a Rival Factory).
local function targetName(flight: Flight): string
	if flight.toBot ~= nil then
		return "TARGET: TEST BOT"
	end
	if flight.toUserId ~= 0 then
		local player = Players:GetPlayerByUserId(flight.toUserId)
		return if player ~= nil then `TARGET: {player.DisplayName}` else ""
	end
	local rival = AttackGeometry.rivalOfSlot(flight.toPlot)
	local entry = if rival ~= nil then AttackConfig.Rivals.List[rival] else nil
	return if entry ~= nil then `TARGET: {entry.name}` else ""
end

--------------------------------------------------------------------------------------------------
-- Input hold (released at the return)
--------------------------------------------------------------------------------------------------

local onSkip: (source: string) -> ()

-- The PlayerActions the default PlayerModule binds keyboard movement / jump to (at Medium priority).
-- Sinking them at High priority holds the character still; CAS cancels a held key's lower binding,
-- so a key held when the cinematic starts stops the character too. (PlayerActions are valid CAS
-- inputs; the type definitions only list KeyCode / UserInputType, hence `any`.)
local MOVEMENT_ACTIONS: { any } = {
	Enum.PlayerActions.CharacterForward,
	Enum.PlayerActions.CharacterBackward,
	Enum.PlayerActions.CharacterLeft,
	Enum.PlayerActions.CharacterRight,
	Enum.PlayerActions.CharacterJump,
}

local function sinkMovement(): Enum.ContextActionResult
	return Enum.ContextActionResult.Sink
end

local function onSkipKey(_: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		onSkip("key")
	end
	return Enum.ContextActionResult.Sink
end

local function holdInput(info: Saved)
	-- Keyboard movement is sunk so the (unseen) character stays put; gamepad movement is paused by
	-- the modal ("Menus"); touch controls hide like the picker's.
	ContextActionService:BindActionAtPriority(
		FREEZE_ACTION,
		sinkMovement,
		false,
		Enum.ContextActionPriority.High.Value,
		table.unpack(MOVEMENT_ACTIONS)
	)
	ContextActionService:BindActionAtPriority(
		SKIP_ACTION,
		onSkipKey,
		false,
		Enum.ContextActionPriority.High.Value + 1,
		table.unpack(LaunchCamConfig.Input.SkipKeys)
	)
	GuiService.TouchControlsEnabled = false
	-- No "Launch Nukes!" / pad prompt can open a window under the cinematic (local only).
	info.prompts = ProximityPromptService.Enabled
	ProximityPromptService.Enabled = false
	ScreenManager.setFocusReason(FOCUS_REASON, true, LaunchCamConfig.FocusHidden :: { string })
end

local function releaseInput()
	ContextActionService:UnbindAction(FREEZE_ACTION)
	ContextActionService:UnbindAction(SKIP_ACTION)
	local info = saved
	if info ~= nil then
		GuiService.TouchControlsEnabled = info.touchControls
		local prompts = info.prompts
		if prompts ~= nil then
			ProximityPromptService.Enabled = prompts
		end
	end
	ScreenManager.setFocusReason(FOCUS_REASON, false)
	local overlay = CountdownOverlay.current()
	if overlay ~= nil then
		overlay.setSkipHandler(nil)
		overlay.hideAll()
	end
	if ScreenManager.isOpen(LaunchCamConfig.ScreenName) then
		ScreenManager.close(LaunchCamConfig.ScreenName)
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

--------------------------------------------------------------------------------------------------
-- Finish / return
--------------------------------------------------------------------------------------------------

-- Ends everything. `restore` = hand the camera back (false when another script took it).
local function finish(restore: boolean)
	RunService:UnbindFromRenderStep(RENDER_BINDING)
	if state ~= "idle" then
		releaseInput()
	end
	local info = saved
	local cam = camera
	if restore and info ~= nil and cam ~= nil and cam.Parent ~= nil then
		cam.CameraType = info.cameraType
		local character = LOCAL.Character
		local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
		local subject = info.subject
		cam.CameraSubject = (if subject ~= nil and subject.Parent ~= nil then subject else humanoid) :: any
		cam.FieldOfView = info.fov
	end
	state = "idle"
	current = nil
	shot = nil
	saved = nil
	camera = nil
end

-- The player's camera to return to: the saved view, shifted by however far the character moved.
local function returnTarget(info: Saved): CFrame
	local root = rootPart()
	local start = info.rootPosition
	if root ~= nil and start ~= nil then
		local moved = root.Position - start
		if LaunchCamMath.finiteVector(moved) and moved.Magnitude < 2000 then
			return info.cframe + moved
		end
	end
	return info.cframe
end

--[[
	Starts the ease back. The countdown / shouts vanish at once and the letterbox slides out with
	the camera; input stays held for these ≤ ReturnSeconds so nothing (a window, the picker) can grab
	the camera mid-return, then finish() gives everything back.
]]
local function beginReturn(skipped: boolean)
	if state ~= "playing" then
		return
	end
	local overlay = CountdownOverlay.current()
	if overlay ~= nil then
		overlay.setSkipHandler(nil)
		overlay.hideAll()
	end
	if skipped then
		hush()
	end
	state = "returning"
	returnClock = os.clock()
	returnFromCFrame = lastCFrame
	returnFromFov = lastFov
	returnSeconds = if reduced then 0 elseif skipped then SHOTS.SkipReturnSeconds else SHOTS.ReturnSeconds
	if skipped then
		stats.skips += 1
	else
		stats.completed += 1
	end
end

onSkip = function(source: string)
	if state ~= "playing" then
		return
	end
	-- The click / tap that pressed LAUNCH! never skips its own cinematic.
	if not LaunchCamMath.skipAllowed(source, os.clock() - openedClock, LaunchCamConfig.Input.SkipGraceSeconds) then
		return
	end
	beginReturn(true)
end

--------------------------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------------------------

--[[ True when a knockdown landed on the area this nuke hit (tag + attributes, KnockdownConfig). ]]
local function knockdownSeen(impactAt: number, point: Vector3): boolean
	local attr = KnockdownConfig.Attr
	local now = serverNow()
	for _, instance in CollectionService:GetTagged(KnockdownConfig.Tag) do
		local at = instance:GetAttribute(attr.At)
		local untilTime = instance:GetAttribute(attr.Until)
		if type(at) == "number" and type(untilTime) == "number" and untilTime > now and at >= impactAt - 1.5 then
			local center = instance:GetAttribute(attr.Center)
			if typeof(center) == "Vector3" then
				if (center - point).Magnitude <= WATCH.CenterRadius then
					return true
				end
			elseif instance:IsA("PVInstance") then
				if (instance:GetPivot().Position - point).Magnitude <= WATCH.PivotRadius then
					return true
				end
			end
		end
	end
	return false
end

-- One-shot moments: voice lines, haptics, outcome shouts, knockdown detection.
local function events(rel: number, flight: Flight, timeline: LaunchCamMath.Timeline, path: FlightMath.Flight)
	local overlay = CountdownOverlay.current()
	local steps = COUNTDOWN.Steps
	for index, number in steps do
		local beatStart = -(#steps - index + 1) * COUNTDOWN.Beat
		if rel >= beatStart and rel < 0 and not beatsSaid[index] then
			beatsSaid[index] = true
			if rel - beatStart <= COUNTDOWN.LateVoiceSeconds then
				say(COUNTDOWN.Voice[number] or "")
				buzz(COUNTDOWN.BeatHaptic)
			end
		end
	end
	if rel >= 0 and not launchSaid then
		launchSaid = true
		if rel <= COUNTDOWN.LateVoiceSeconds then
			say(COUNTDOWN.LaunchVoice)
			buzz(COUNTDOWN.LaunchHaptic)
		end
	end
	if rel >= timeline.endAt and not outcomeShown then
		outcomeShown = true
		local kind: CountdownOverlay.OutcomeKind = if timeline.intercepted then "Intercepted" else "Hit"
		local shout = LaunchCamConfig.Outcome.Shouts[kind]
		if shout ~= nil then
			say(shout.voice)
		end
		if overlay ~= nil then
			overlay.showOutcome(kind, timeline.endAt)
		end
		if not timeline.intercepted then
			buzz(COUNTDOWN.LaunchHaptic)
		end
	end
	-- Knockdown: a few samples after a ground hit (the server applies it at impact; replication follows).
	if not timeline.intercepted and not knockFound then
		local samples = WATCH.Samples
		while knockSamples < #samples and rel >= timeline.endAt + samples[knockSamples + 1] do
			knockSamples += 1
			if knockdownSeen(flight.t0 + timeline.endAt, path.to) then
				knockFound = true
				knockSayAt = math.max(rel, timeline.endAt + WATCH.SayAfter)
				holdUntil = math.max(holdUntil, rel + SHOTS.KnockdownHold, timeline.holdUntil + SHOTS.KnockdownHold)
				watchdogClock += SHOTS.KnockdownHold
				break
			end
		end
	end
	local sayAt = knockSayAt
	if sayAt ~= nil and not knockSaid and rel >= sayAt then
		knockSaid = true
		local shout = LaunchCamConfig.Outcome.Shouts.Knockdown
		if shout ~= nil then
			say(shout.voice)
		end
		if overlay ~= nil then
			overlay.showOutcome("Knockdown", rel)
		end
	end
end

-- The one RenderStepped body while active.
local function step(dt: number)
	local cam = camera
	local flight = current
	local scene = shot
	local info = saved
	if cam == nil or flight == nil or scene == nil or info == nil then
		finish(true)
		return
	end
	-- Another script took the camera (or it was replaced): stop without fighting it.
	if Workspace.CurrentCamera ~= cam or cam.CameraType ~= Enum.CameraType.Scriptable then
		stats.aborted += 1
		finish(false)
		return
	end
	if state == "returning" then
		local w = LaunchCamMath.returnBlend(os.clock() - returnClock, returnSeconds)
		cam.CFrame = returnFromCFrame:Lerp(returnTarget(info), w)
		cam.FieldOfView = returnFromFov + (info.fov - returnFromFov) * w
		local overlay = CountdownOverlay.current()
		if overlay ~= nil then
			overlay.render(0, 1 - w)
		end
		if w >= 1 then
			finish(true)
		end
		return
	end
	local timeline = scene.timeline
	local rel = serverNow() - flight.t0
	-- The outcome shot's occlusion: measured once the approach starts (the target is streamed by now).
	if not impactReachReady and rel >= timeline.approachAt - 0.5 then
		impactReachReady = true
		local focus = FlightMath.position(scene.flight, timeline.endAt)
		scene.impactReach =
			reach(focus, LaunchCamMath.impactPose(focus, scene.flat, timeline.intercepted, 0, SHOTS :: any).eye)
	end
	events(rel, flight, timeline, scene.flight)
	local cf, fov = LaunchCamMath.frame(scene, rel, dt, LaunchCamConfig :: any)
	-- Eased cut in from the player's camera.
	local intro = if reduced then 1 else LaunchCamMath.smoothstep((os.clock() - openedClock) / INTRO_SECONDS)
	if intro < 1 then
		cf = info.cframe:Lerp(cf, intro)
		fov = info.fov + (fov - info.fov) * intro
	end
	cam.CFrame = cf
	cam.FieldOfView = fov
	lastCFrame = cf
	lastFov = fov
	local overlay = CountdownOverlay.current()
	if overlay ~= nil then
		local overlayRel = rel
		if IS_STUDIO then
			local hold = overlay.gui:GetAttribute(LaunchCamConfig.DebugHoldAttribute)
			if type(hold) == "number" and hold == hold then
				overlayRel = hold
			end
		end
		local k = if reduced then 1 else clamp01((os.clock() - openedClock) / LaunchCamConfig.Letterbox.SlideSeconds)
		overlay.render(overlayRel, LaunchCamMath.smoothstep(k))
	end
	if rel >= holdUntil then
		beginReturn(false)
	elseif os.clock() > watchdogClock then
		beginReturn(true)
	end
end

-- step() guarded: an error ends the cinematic and gives the camera back (never a stuck camera).
local function safeStep(dt: number)
	local ok, err = pcall(step, dt)
	if not ok then
		warn(`[LaunchCam] {err}`)
		stats.aborted += 1
		finish(true)
	end
end

--------------------------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------------------------

--[[
	Plays the cinematic for one of YOUR flights (AttackClient validated the payload).
	Ignored when: the feature is off (config / ReplicatedStorage kill switch), it is not your
	flight, a cinematic is already running (Barrage → first nuke only), the outcome is too close,
	or there is no camera.
	@param flight Flight — the validated NukeFlight
	@return boolean — true when the cinematic started
]]
function LaunchCam.play(flight: Flight): boolean
	if not LaunchCamConfig.Enabled or ReplicatedStorage:GetAttribute(LaunchCamConfig.KillSwitchAttribute) == true then
		return false
	end
	if state ~= "idle" or LOCAL == nil or flight.fromUserId ~= LOCAL.UserId then
		return false
	end
	local t0 = LaunchCamMath.finite(flight.t0, -1)
	if t0 <= 0 then
		return false
	end
	-- Aim-aware: the exact arc the server built (and FlightRenderer draws) from the same indices.
	local indices: AttackGeometry.FlightIndices = {
		fromPlot = flight.fromPlot,
		silo = flight.silo,
		toPlot = flight.toPlot,
		impact = flight.impact,
		area = flight.area,
		sx = flight.sx,
		sz = flight.sz,
		duration = flight.duration,
	}
	local ok, path = pcall(AttackGeometry.flightOf, indices)
	if not ok or path == nil then
		return false
	end
	local timeline = LaunchCamMath.timeline(path.duration, flight.intercepted, flight.interceptAt, SHOTS :: any)
	local rel = serverNow() - t0
	if rel > timeline.endAt - MIN_REMAINING then
		return false
	end
	local cam = Workspace.CurrentCamera
	if cam == nil then
		return false
	end
	-- The picker (or any window) closes first: its onClose hands the player's own camera back
	-- synchronously, and that is the view we save and return to.
	ScreenManager.closeAllModals()
	local root = rootPart()
	local info: Saved = {
		cameraType = if cam.CameraType == Enum.CameraType.Scriptable then Enum.CameraType.Custom else cam.CameraType,
		subject = cam.CameraSubject,
		cframe = cam.CFrame,
		fov = cam.FieldOfView,
		touchControls = GuiService.TouchControlsEnabled,
		prompts = nil,
		rootPosition = if root ~= nil then root.Position else nil,
	}
	reduced = OfferFx.reducedMotion()
	local flat = LaunchCamMath.flatDir(path.from, path.to)
	state = "playing"
	current = flight
	saved = info
	camera = cam
	shot = {
		flight = path,
		timeline = timeline,
		flat = flat,
		startRel = math.min(rel, 0),
		reduced = reduced,
		siloReach = reach(path.from, LaunchCamMath.siloPose(path.from, path.to, 0, SHOTS :: any).eye),
		impactReach = math.huge,
		chase = LaunchCamMath.newChase(flat),
	}
	openedClock = os.clock()
	holdUntil = timeline.holdUntil
	watchdogClock = openedClock + (timeline.holdUntil - rel) + SHOTS.ReturnSeconds + LaunchCamConfig.WatchdogSlack
	impactReachReady = false
	currentVoice = nil
	-- Normally warmed when the picker opened; a first Revenge from the HUD chip warms here.
	warmVoices()
	table.clear(beatsSaid)
	launchSaid = false
	outcomeShown = false
	knockSamples = 0
	knockFound = false
	knockSayAt = nil
	knockSaid = false
	lastCFrame = cam.CFrame
	lastFov = cam.FieldOfView
	stats.plays += 1

	cam.CameraType = Enum.CameraType.Scriptable
	ScreenManager.open(LaunchCamConfig.ScreenName)
	local overlay = CountdownOverlay.current()
	if overlay ~= nil then
		local budget = LaunchCamConfig.FxTiers[FxQuality.tier()] or LaunchCamConfig.FxTiers.Mid
		overlay.begin({ seed = flight.id, targetName = targetName(flight), reduced = reduced, budget = budget })
		overlay.setSkipHandler(onSkip)
		-- SKIP was hidden by the previous return: put the gamepad selection on it now.
		ScreenManager.refreshSelection()
	end
	holdInput(info)
	table.insert(
		connections,
		GuiService.MenuOpened:Connect(function()
			onSkip("menu")
		end)
	)
	table.insert(
		connections,
		LOCAL.CharacterAdded:Connect(function()
			-- Respawned elsewhere: hand the camera straight back.
			if state == "playing" then
				stats.aborted += 1
				finish(true)
			end
		end)
	)
	-- Make sure the target is streamed in before the camera gets there (picker-less Revenge).
	task.spawn(function()
		pcall(function()
			LOCAL:RequestStreamAroundAsync(path.to, 6)
		end)
	end)
	RunService:BindToRenderStep(RENDER_BINDING, Enum.RenderPriority.Camera.Value, safeStep)
	reportPlay()
	return true
end

--[[ Skips the running cinematic now (e.g. a teleport); no-op when idle. ]]
function LaunchCam.skip()
	onSkip("external")
end

--[[ True while a cinematic (or its return) is running. ]]
function LaunchCam.isActive(): boolean
	return state ~= "idle"
end

--[[
	QA counters + the current phase: `rel` = seconds after the followed flight's t0 (nil when idle),
	`skips` / `completed` / `aborted` count how cinematics ended.
]]
function LaunchCam.stats(): {
	active: boolean,
	state: string,
	rel: number?,
	plays: number,
	skips: number,
	completed: number,
	aborted: number,
}
	local flight = current
	return {
		active = state ~= "idle",
		state = state,
		rel = if flight ~= nil then serverNow() - flight.t0 else nil,
		plays = stats.plays,
		skips = stats.skips,
		completed = stats.completed,
		aborted = stats.aborted,
	}
end

--------------------------------------------------------------------------------------------------
-- Voice warm-up triggers (wired once, when AttackClient first requires this module)
--------------------------------------------------------------------------------------------------

-- The picker / Defense screen opening means a launch is coming: fetch the lines now.
ScreenManager.Opened:Connect(function(name: string)
	if name == "Attack" or name == "Defense" then
		warmVoices()
	end
end)

-- Owning the Attack Console (launcher level) or having been hit (Revenge is possible) also warms.
local function checkProfile(profile: ClientState.Profile?)
	if voicesWarmed or type(profile) ~= "table" then
		return
	end
	local attack = (profile :: any).attack
	if type(attack) ~= "table" then
		return
	end
	local launcher = if type(attack.launcher) == "number" then attack.launcher else 0
	local hits = if type(attack.hitsTaken) == "number" then attack.hitsTaken else 0
	if launcher > 0 or hits > 0 then
		warmVoices()
	end
end
ClientState.ProfileChanged:Connect(checkProfile)
checkProfile(ClientState.profile)

return LaunchCam
