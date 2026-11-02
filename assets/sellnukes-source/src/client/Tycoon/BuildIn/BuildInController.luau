--!strict
--[[
	BuildInController — the LEGO "master builder" purchase animation (owner R1, spec §5).

	Every purchase builds in front of you: the real pieces are hidden on this client
	(LocalTransparencyModifier = 1, the server copy stays authoritative and collidable), pooled
	translucent ghost copies fly in from scattered points around the buyer on little arcs with a
	spin, fade to solid and snap into place one after another, bottom-to-top, with rising "clack"
	sounds every few pieces, then a confetti + sparkle finale. Each real piece is revealed the
	moment its ghost lands.

	Modes (BuildInConfig): Full for the buyer, Light (short drop-in + fade) for other players in
	range, None when far, late (older than FreshWindow) or Reduce Motion is on.

	Performance:
		* ONE RenderStepped connection, connected only while a build is animating.
		* Ghosts come from GhostPool (one Clone per new mesh, reused afterwards); all ghost CFrames
		  move in one Workspace:BulkMoveTo per frame; no Instance.new / tweens / threads per piece.
		* Per-device budgets (BuildInConfig.Tiers via FxQuality, owner R11): MaxGhosts across all
		  builds (60 on High, 24 on a low-end phone), MaxFlownPerBuild, confetti scale, range;
		  extra pieces fade in place. Discovery is tag-based (PlotWatcher), never a global
		  DescendantAdded. Your own completed build triggers B16's Haptics "BuildComplete"
		  (gamepad rumble / phone vibration, respects the Vibration setting).

	Connections: PlotWatcher (BuildAdded), GhostPool, FxSound, Confetti, BuildPlan (timing maths),
	ClientState (profile.settings.reducedMotion), GuiService.ReducedMotionEnabled.
	Exposes BuildFinished(model, info) so WorldFxController can play the area-unlock fanfare.
	Knockdown (owner R50, KnockdownFx): `rebuild(model, opts)` replays the fly-in with every ghost
	lifting off its rubble piece; `setDeferHook(fn)` lets KnockdownFx hold back builds bought
	inside a knocked-down area until that area is rebuilt.

	Boot: controller contract Init() / Start() (src/client/init.client.luau).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BuildInConfig = require(ReplicatedStorage.Shared.Config.BuildInConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
-- B16 platform haptics (gamepad rumble + phone vibration, Vibration setting, rate-limited).
local Haptics = require(script.Parent.Parent.Parent.Platform.Haptics)
local BuildPlan = require(script.Parent.BuildPlan)
local GhostPool = require(script.Parent.GhostPool)
local Confetti = require(script.Parent.Parent.Fx.Confetti)
local FxQuality = require(script.Parent.Parent.Fx.FxQuality)
local FxSound = require(script.Parent.Parent.Fx.FxSound)
local PlotWatcher = require(script.Parent.Parent.Fx.PlotWatcher)

type Mode = "Full" | "Light"

type Piece = {
	real: BasePart,
	extras: { Decal }, -- decals/textures (Texture is a Decal) on the piece, hidden with it
	targetTransparency: number,
	t0: number, -- launch time (os.clock)
	dur: number,
	from: Vector3,
	ctrl: Vector3,
	spin: CFrame, -- rotation offset that unwinds to identity
	ghost: BasePart?, -- nil until launched; stays nil for fade-in-place pieces
	fadeOnly: boolean,
	state: "waiting" | "flying" | "done",
}

type Build = {
	model: Model,
	info: PlotWatcher.BuildInfo,
	mode: Mode,
	pieces: { Piece },
	nextIndex: number, -- next piece to launch
	landed: number,
	top: Vector3, -- finale position (top centre of the build)
	alive: boolean,
	ancestry: RBXScriptConnection?,
	-- Knockdown rebuild (owner R50): each piece's ghost starts from its rubble CFrame instead of
	-- a random scatter point (nil = a normal purchase).
	starts: { [BasePart]: CFrame }?,
}

-- Options of BuildInController.rebuild (KnockdownFx).
export type RebuildOptions = {
	starts: { [BasePart]: CFrame }?, -- rubble CFrame per piece (nil = fly in like a purchase)
	isOwner: boolean, -- Full mode (sounds, confetti, haptics) for the area's owner, else Light
	areaIndex: number?,
}

local BuildInController = {}

-- Fired when a build's last piece lands (or immediately when not animated).
BuildInController.BuildFinished = Signal.new() :: Signal.Signal<Model, PlotWatcher.BuildInfo>

local started = false
-- Verification aid (setTimeScale): 1 = normal speed; 0.25 = 4x slower for frame captures.
local timeScale = 1
local builds: { Build } = {}
local activeGhosts = 0
local stepConnection: RBXScriptConnection? = nil
local random = Random.new()
-- KnockdownFx (owner R50): returns true to take over a fresh build placed inside a knocked-down
-- area (it stays hidden and builds in after the area's rebuild). nil = no knockdown system.
local deferHook: ((model: Model, info: PlotWatcher.BuildInfo) -> boolean)? = nil

-- Scratch arrays reused every frame for BulkMoveTo (no per-frame table churn).
local movedParts: { BasePart } = {}
local movedFrames: { CFrame } = {}

-- Reduce Motion: Roblox's own setting OR SellNukes' profile setting.
local function reducedMotion(): boolean
	if GuiService.ReducedMotionEnabled then
		return true
	end
	local profile = ClientState.profile
	local settings = profile and profile.settings
	return type(settings) == "table" and settings.reducedMotion == true
end

-- World-space bottom Y of a (possibly rotated) part's box.
local function bottomOf(part: BasePart): number
	local cf, size = part.CFrame, part.Size
	local halfY = math.abs(cf.RightVector.Y) * size.X / 2
		+ math.abs(cf.UpVector.Y) * size.Y / 2
		+ math.abs(cf.LookVector.Y) * size.Z / 2
	return cf.Position.Y - halfY
end

-- Hides / shows a piece and its decals on this client only.
local function setHidden(piece: Piece, hidden: boolean)
	local value = if hidden then 1 else 0
	piece.real.LocalTransparencyModifier = value
	for _, extra in piece.extras do
		extra.LocalTransparencyModifier = value
	end
end

-- Pushes a start point out of the camera's face (camera-safe launches).
local function clearOfCamera(point: Vector3, camera: Vector3): Vector3
	local offset = point - camera
	local distance = offset.Magnitude
	if distance >= BuildInConfig.CameraClearance then
		return point
	end
	local direction = if distance > 1e-3 then offset.Unit else Vector3.yAxis
	return camera + direction * BuildInConfig.CameraClearance
end

local function stopLoopIfIdle()
	if #builds == 0 and stepConnection ~= nil then
		stepConnection:Disconnect()
		stepConnection = nil
	end
end

-- Ends a build: reveal everything still hidden, return ghosts, fire BuildFinished if completed.
local function finish(build: Build, completed: boolean)
	if not build.alive then
		return
	end
	build.alive = false
	if build.ancestry ~= nil then
		build.ancestry:Disconnect()
		build.ancestry = nil
	end
	for _, piece in build.pieces do
		local ghost = piece.ghost
		if ghost ~= nil then
			piece.ghost = nil
			activeGhosts -= 1
			GhostPool.release(ghost)
		end
		if piece.state ~= "done" and piece.real.Parent ~= nil then
			piece.real.Transparency = piece.targetTransparency
			setHidden(piece, false)
		end
		piece.state = "done"
	end
	local index = table.find(builds, build)
	if index ~= nil then
		table.remove(builds, index)
	end
	if completed then
		local scale = BuildInConfig.Tiers[FxQuality.tier()].ConfettiScale
		if build.mode == "Full" then
			Confetti.burst(
				build.top,
				math.floor(BuildInConfig.Confetti * scale),
				math.floor(BuildInConfig.Sparkle * scale)
			)
			FxSound.play("sparkle", build.top)
			Haptics.play("BuildComplete") -- only Full mode = your own purchase
		else
			Confetti.burst(build.top, 0, math.floor(BuildInConfig.SparkleLight * scale))
			FxSound.play("sparkle", build.top, { volume = 0.5 })
		end
		BuildInController.BuildFinished:Fire(build.model, build.info)
	end
	stopLoopIfIdle()
end

-- Launches one piece: ghost (or fade-in-place when capped / not clonable).
local function launch(build: Build, piece: Piece, index: number)
	if piece.real.Parent == nil then
		piece.state = "done"
		build.landed += 1
		return
	end
	local ghost: BasePart? = nil
	if not piece.fadeOnly and activeGhosts < BuildInConfig.Tiers[FxQuality.tier()].MaxGhosts then
		ghost = GhostPool.acquire(piece.real)
	end
	piece.state = "flying"
	if ghost == nil then
		-- Fade the real piece in place: transparency animated on the real part locally.
		piece.fadeOnly = true
		piece.dur = BuildInConfig.FadeInPlace
		setHidden(piece, false)
		piece.real.Transparency = 1
		return
	end
	activeGhosts += 1
	piece.ghost = ghost
	ghost.Transparency = BuildInConfig.StartTransparency
	ghost.CFrame = CFrame.new(piece.from) * piece.real.CFrame.Rotation * piece.spin
	if build.mode == "Full" and index == 1 then
		FxSound.play("whoosh", piece.from)
	end
end

-- Lands one piece: reveal the real part, recycle the ghost, clack on the beat.
local function land(build: Build, piece: Piece)
	local ghost = piece.ghost
	if ghost ~= nil then
		piece.ghost = nil
		activeGhosts -= 1
		GhostPool.release(ghost)
	end
	if piece.real.Parent ~= nil then
		piece.real.Transparency = piece.targetTransparency
		setHidden(piece, false)
	end
	piece.state = "done"
	build.landed += 1
	local total = #build.pieces
	if build.mode == "Full" and BuildPlan.isClack(build.landed, total, BuildInConfig.ClackEvery) then
		local pitch =
			BuildPlan.clackPitch(build.landed / total, BuildInConfig.ClackPitch.Min, BuildInConfig.ClackPitch.Max)
		FxSound.play("clack", piece.real.Position, { pitch = pitch })
	end
end

-- Per-frame driver for every active build (single connection).
local function step()
	local now = os.clock()
	table.clear(movedParts)
	table.clear(movedFrames)
	for i = #builds, 1, -1 do
		local build = builds[i]
		if not build.alive then
			continue
		end
		local pieces = build.pieces
		-- Launch every piece whose time has come.
		while build.nextIndex <= #pieces and pieces[build.nextIndex].t0 <= now do
			launch(build, pieces[build.nextIndex], build.nextIndex)
			build.nextIndex += 1
		end
		for _, piece in pieces do
			if piece.state ~= "flying" then
				continue
			end
			local u = math.clamp((now - piece.t0) / piece.dur, 0, 1)
			local ghost = piece.ghost
			if ghost ~= nil then
				local e = BuildPlan.easeInOutSine(u)
				-- Quadratic Bezier from -> ctrl -> target, so pieces arc in.
				local target = piece.real.CFrame
				local a = piece.from:Lerp(piece.ctrl, e)
				local b = piece.ctrl:Lerp(target.Position, e)
				local position = a:Lerp(b, e)
				-- easeOutBack overshoots slightly: the spin "snaps" home.
				local spin = piece.spin:Lerp(CFrame.identity, BuildPlan.easeOutBack(u))
				table.insert(movedParts, ghost)
				table.insert(movedFrames, CFrame.new(position) * target.Rotation * spin)
				local fade = u ^ 0.7
				ghost.Transparency = BuildInConfig.StartTransparency
					+ (piece.targetTransparency - BuildInConfig.StartTransparency) * fade
			else
				piece.real.Transparency = 1 + (piece.targetTransparency - 1) * BuildPlan.easeOutCubic(u)
			end
			if u >= 1 then
				land(build, piece)
			end
		end
		if build.landed >= #pieces then
			finish(build, true)
		end
	end
	if #movedParts > 0 then
		Workspace:BulkMoveTo(movedParts, movedFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Collects the visible pieces of a build model, sorted bottom-to-top.
local function collectPieces(model: Model): { Piece }
	type Entry = { part: BasePart, bottom: number, order: number }
	local entries: { Entry } = {}
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") and item.Transparency < 1 then
			local order = item:GetAttribute(BuildInConfig.OrderAttribute)
			table.insert(entries, {
				part = item,
				bottom = bottomOf(item),
				order = if type(order) == "number" then order else 0,
			})
		end
	end
	table.sort(entries, function(a: Entry, b: Entry): boolean
		return BuildPlan.before(a.bottom, a.order, a.part.Name, b.bottom, b.order, b.part.Name)
	end)
	local pieces: { Piece } = {}
	for _, entry in entries do
		local extras: { Decal } = {}
		for _, child in entry.part:GetChildren() do
			if child:IsA("Decal") then
				table.insert(extras, child)
			end
		end
		local piece: Piece = {
			real = entry.part,
			extras = extras,
			targetTransparency = entry.part.Transparency,
			t0 = 0,
			dur = 0,
			from = Vector3.zero,
			ctrl = Vector3.zero,
			spin = CFrame.identity,
			ghost = nil,
			fadeOnly = false,
			state = "waiting",
		}
		table.insert(pieces, piece)
	end
	return pieces
end

-- Plans launch times + start points + arcs for every piece of a new build.
local function plan(build: Build)
	local pieces = build.pieces
	local camera = Workspace.CurrentCamera
	local cameraPos = if camera ~= nil then camera.CFrame.Position else Vector3.zero
	local full = build.mode == "Full"
	local flightCfg: BuildPlan.ScheduleConfig = if full
		then BuildInConfig :: any
		else {
			Flight = BuildInConfig.LightFlight,
			MinStagger = BuildInConfig.MinStagger,
			MaxStagger = BuildInConfig.MaxStagger,
			MinTotal = BuildInConfig.LightFlight + 0.4,
			MaxTotal = BuildInConfig.MaxTotal * 0.7,
		}
	local stagger, flight = BuildPlan.schedule(#pieces, flightCfg)
	stagger /= timeScale
	flight /= timeScale
	local origin = build.top
	if full then
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root ~= nil and root:IsA("BasePart") then
			origin = root.Position
		end
	end
	local now = os.clock()
	local maxFlown = BuildInConfig.Tiers[FxQuality.tier()].MaxFlownPerBuild
	local starts = build.starts
	for i, piece in pieces do
		local target = piece.real.Position
		piece.t0 = now + (i - 1) * stagger
		piece.dur = flight
		piece.fadeOnly = i > maxFlown
		local rubble = if starts ~= nil then starts[piece.real] else nil
		if rubble ~= nil then
			-- Knockdown rebuild: the ghost lifts off the rubble piece (same spot, same tilt) and
			-- arcs home; the tilt unwinds to the real rotation (spin = home⁻¹ · rubble).
			piece.from = rubble.Position
			piece.ctrl = (rubble.Position + target) / 2 + Vector3.new(0, BuildInConfig.ArcHeight, 0)
			piece.spin = piece.real.CFrame.Rotation:Inverse() * rubble.Rotation
		elseif full then
			local angle = random:NextNumber(0, 2 * math.pi)
			local radius = random:NextNumber(BuildInConfig.ScatterRadius.Min, BuildInConfig.ScatterRadius.Max)
			local height = random:NextNumber(BuildInConfig.ScatterHeight.Min, BuildInConfig.ScatterHeight.Max)
			local start = origin + Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
			piece.from = clearOfCamera(start, cameraPos)
			local mid = (piece.from + target) / 2
			piece.ctrl = mid + Vector3.new(0, BuildInConfig.ArcHeight, 0)
			local spin = math.rad(BuildInConfig.SpinDegrees)
			piece.spin = CFrame.Angles(
				random:NextNumber(-spin, spin),
				random:NextNumber(-spin, spin),
				random:NextNumber(-spin, spin)
			)
		else
			local drop = random:NextNumber(BuildInConfig.LightDrop.Min, BuildInConfig.LightDrop.Max)
			piece.from = target + Vector3.new(0, drop, 0)
			piece.ctrl = (piece.from + target) / 2
			piece.spin = CFrame.identity
		end
		setHidden(piece, true)
	end
end

-- Entry point for every build model PlotWatcher reports.
--[[
	Starts the build-in of one model (purchase or knockdown rebuild). Far away / Reduce Motion /
	nothing visible → BuildFinished at once and false (the pieces are already shown).
	@param starts { [BasePart]: CFrame }? — knockdown rubble start per piece
	@return boolean — true when an animation started
]]
local function animateBuild(
	model: Model,
	info: PlotWatcher.BuildInfo,
	mode: Mode,
	starts: { [BasePart]: CFrame }?
): boolean
	local camera = Workspace.CurrentCamera
	local center = model:GetPivot().Position
	local ok, boxCf, boxSize = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok then
		center = boxCf.Position
	end
	local top = center + Vector3.new(0, (if ok then boxSize.Y / 2 else 4) + 1.5, 0)
	local distance = if camera ~= nil then (camera.CFrame.Position - center).Magnitude else 0
	if reducedMotion() or distance > BuildInConfig.Tiers[FxQuality.tier()].LightRange then
		BuildInController.BuildFinished:Fire(model, info)
		return false
	end
	local pieces = collectPieces(model)
	if starts ~= nil then
		-- Knockdown rebuild: only the pieces that toppled fly (floors / kept parts never moved).
		for i = #pieces, 1, -1 do
			if starts[pieces[i].real] == nil then
				table.remove(pieces, i)
			end
		end
	end
	if #pieces == 0 then
		BuildInController.BuildFinished:Fire(model, info)
		return false
	end
	local build: Build = {
		model = model,
		info = info,
		mode = mode,
		pieces = pieces,
		nextIndex = 1,
		landed = 0,
		top = top,
		alive = true,
		ancestry = nil,
		starts = starts,
	}
	plan(build)
	-- The model can be destroyed (plot cleared) or streamed out mid-build: abort cleanly.
	build.ancestry = model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(Workspace) then
			finish(build, false)
		end
	end)
	table.insert(builds, build)
	if stepConnection == nil then
		stepConnection = RunService.RenderStepped:Connect(step)
	end
	return true
end

-- Entry point for every build model PlotWatcher reports.
local function onBuildAdded(model: Model, info: PlotWatcher.BuildInfo)
	if info.age > BuildInConfig.FreshWindow then
		return -- late joiner / streamed back in: show finished
	end
	-- Bought inside a knocked-down area (owner R50): KnockdownFx keeps it hidden and calls
	-- BuildInController.rebuild when the area comes back up.
	local hook = deferHook
	if hook ~= nil then
		local taken, result = pcall(hook, model, info)
		if taken and result == true then
			return
		end
	end
	animateBuild(model, info, if info.isBuyer then "Full" else "Light", nil)
end

function BuildInController.Init() end

-- Subscribes to PlotWatcher (idempotent).
function BuildInController.Start()
	if started then
		return
	end
	started = true
	PlotWatcher.BuildAdded:Connect(onBuildAdded)
	PlotWatcher.start()
end

--[[
	Knockdown rebuild (owner R50, Client/Tycoon/BuildIn/KnockdownFx): replays the master-builder
	fly-in on a model that already exists — with `starts`, every ghost lifts off its rubble CFrame
	and arcs home; without, it flies in like a purchase (a build bought while the area was down).
	Ignores FreshWindow; Reduce Motion / far away / nothing visible finishes at once (returns false,
	the pieces stay shown). The real pieces must already be back on their home CFrames.
	@param model Model — a build container (e.g. AreaNN/Builds/<BuildKey>)
	@param opts RebuildOptions
	@return boolean — true when an animation started
	Example: BuildInController.rebuild(container, { starts = rubble, isOwner = true, areaIndex = 3 })
]]
function BuildInController.rebuild(model: Model, opts: RebuildOptions): boolean
	if model.Parent == nil or not model:IsDescendantOf(Workspace) then
		return false
	end
	local info: PlotWatcher.BuildInfo = {
		age = 0,
		buyerUserId = if opts.isOwner then Players.LocalPlayer.UserId else 0,
		isBuyer = opts.isOwner,
		padId = nil,
		areaIndex = opts.areaIndex,
		isAreaBase = false,
	}
	return animateBuild(model, info, if opts.isOwner then "Full" else "Light", opts.starts)
end

--[[
	Ends any build-in still animating on `model` (or inside it) at once: ghosts back to the pool,
	real pieces revealed where they are, no finale. KnockdownFx calls it before toppling an area
	whose purchase was still flying in. @return number — builds ended
]]
function BuildInController.settle(model: Instance): number
	local count = 0
	for i = #builds, 1, -1 do
		local build = builds[i]
		if build ~= nil and (build.model == model or build.model:IsDescendantOf(model)) then
			finish(build, false)
			count += 1
		end
	end
	return count
end

--[[
	Installs the knockdown defer hook (KnockdownFx.Start; nil removes it). The hook runs for every
	FRESH build before it animates and returns true to take it over. Errors count as "not taken".
]]
function BuildInController.setDeferHook(hook: ((model: Model, info: PlotWatcher.BuildInfo) -> boolean)?)
	deferHook = hook
end

--[[
	Slows every NEW build down (verification frame captures only; default 1). Clamped 0.1..1.
	Example (Studio playtest, eval_client_runtime): BuildInController.setTimeScale(0.25)
]]
function BuildInController.setTimeScale(scale: number)
	timeScale = math.clamp(scale, 0.1, 1)
end

-- Debug / verification counters.
function BuildInController.stats(): { builds: number, ghosts: number, pooled: number }
	return { builds = #builds, ghosts = activeGhosts, pooled = GhostPool.stats().pooled }
end

return BuildInController
