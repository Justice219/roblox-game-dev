--!strict
--[[
	SiloLaunch — the Launch Silos' rockets really leave and reload (owner R109: "make sure when you
	launch rockets the rockets actually leave the base and recharge load back"; screenshot: three
	rockets standing in their gantries).

	On every launch from a plot (normal / revenge / golden / barrage — any NukeFlight, so EVERY client
	sees it), the rocket standing in that flight's silo (Area07 `launchBuilds[silo]` → the
	A7_SiloNuke_* model) lifts off:
		ignite   (t0 - IgniteLead .. t0)   flame + smoke + light, it shakes and slowly rises
		lift-off (t0 .. t0 + HandOff)      it climbs fast and blends onto the flight's own arc
		                                   (Shared/Attack/FlightMath), shrinking to the flight nuke's
		                                   length; FlightRenderer starts drawing the flight nuke at
		                                   t0 + HandOff (`launch` returns that hand-off) and a smoke
		                                   puff covers the swap, so THAT rocket is the one that flies
		reload   (t0 + HandOff .. + reload) the gantry stands empty while a fresh rocket rises back in
		                                   (translucent → solid, build-in style) under a pulsing amber
		                                   "RELOADING" glow + a stud "RELOADING 12s" board; reload =
		                                   the launcher cooldown for a normal launch, QuickReload else
	Barrages cycle the silos (the server's round-robin `silo` per nuke); a silo firing again while
	its rocket is still lifting off just extends its reload.

	Rules: the server's rocket is NEVER moved — it is hidden on this client (LocalTransparencyModifier,
	re-asserted while empty: a knockdown / build-in reveal cannot pop it back) and pooled client
	clones fly / reload in its place (ClonesPerKey per art key, Highlights / boards pooled). ONE
	PreRender loop while anything is live, parts move with ONE BulkMoveTo per frame. Culling: lift-
	offs within CullDistance of the camera (own launches always), reload clones / glow / boards
	within ReloadDistance; far silos just stay hidden until reloaded. FxQuality sets the smoke rate
	(lights off on Low). Reduce Motion: no flight / rise — the rocket fades out at t0 and back in when
	reloaded (the board still counts down). A knocked-down Area 7 (KnockedUntil) is left alone.

	Connects to: Shared/Attack/{SiloLaunchMath, FlightMath, AttackGeometry}, Shared/Config/
	{AttackConfig (SiloFx, Launcher), AreaLayouts/Area07, KnockdownConfig, UIStyleConfig},
	Client/Attack/{FlightRenderer (launch), AttackFx (puff)}, Tycoon/Fx/FxQuality,
	UI/{Create, Widgets/StudWindow, Widgets/OfferFx}.

	Example (FlightRenderer.add):
		local handOff = SiloLaunch.launch(data, flight) -- 0 = draw the flight nuke from t0
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackFx = require(script.Parent.AttackFx)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local Create = require(script.Parent.Parent.UI.Create)
local FlightMath = require(ReplicatedStorage.Shared.Attack.FlightMath)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local SiloLaunchMath = require(ReplicatedStorage.Shared.Attack.SiloLaunchMath)
local StudWindow = require(script.Parent.Parent.UI.Widgets.StudWindow)
local UIStyleConfig = require(ReplicatedStorage.Shared.Config.UIStyleConfig)

local SiloLaunch = {}

local FX = AttackConfig.SiloFx
local LOCAL = Players.LocalPlayer
local PARK = CFrame.new(0, -4200, 0)
local UP = Vector3.yAxis
-- The Area 7 model inside a plot and its builds folder (Tycoon/TycoonContract tree).
local AREA_NAME = "Area07"
local BUILDS_NAME = "Builds"
-- Seconds between two lookups of a silo's real rocket (it can stream out / in mid-reload).
local RESOLVE_SECONDS = 0.5

-- The silo art: silo index → (build key, rocket model key) from AreaLayouts/Area07.
type SiloArt = { build: string, model: string }
local siloArt: { SiloArt } = {}
do
	local ok, layout = pcall(function(): any
		return require(ReplicatedStorage.Shared.Config.AreaLayouts.Area07) :: any
	end)
	if
		ok
		and type(layout) == "table"
		and type(layout.launchBuilds) == "table"
		and type(layout.animations) == "table"
	then
		for index, build in layout.launchBuilds do
			for _, animation in layout.animations do
				if type(animation) == "table" and animation.kind == "launch" and animation.build == build then
					siloArt[index] = { build = build, model = animation.model }
				end
			end
		end
	end
end

-- One pooled client clone of a silo rocket.
type Clone = {
	model: Model,
	key: string,
	parts: { BasePart },
	offsets: { CFrame }, -- part CFrames in the rocket's pivot (tail) space
	sizes: { Vector3 },
	baseLtm: { number },
	attach: Attachment?,
	attachBase: CFrame?, -- the host part's offset (to re-seat the attachment when scaled)
	smoke: ParticleEmitter?,
	flame: ParticleEmitter?,
	light: PointLight?,
	scale: number, -- last scale written
	ltm: number, -- last LocalTransparencyModifier written
}

-- One pooled RELOADING board (local anchor + stud plate + countdown + progress bar).
type Board = { anchor: BasePart, gui: BillboardGui, seconds: TextLabel, fill: Frame, shown: number }

-- One silo's live state (a plot's silo index).
type Silo = {
	plot: number,
	silo: number,
	art: SiloArt,
	real: Model?,
	resolvedAt: number, -- os.clock() of the last lookup
	rest: CFrame?, -- the real rocket's pivot (tail) when last seen
	hidden: number, -- LocalTransparencyModifier we last wrote on the real rocket (-1 = untouched)
	-- lift-off
	launching: boolean,
	t0: number,
	flight: FlightMath.Flight?,
	length: number,
	reduced: boolean,
	drop: number, -- studs below rest the lift-off starts (fired mid-reload)
	launchClone: Clone?,
	ignited: boolean,
	-- reload (`pending*` = the next reload, applied at its flight's t0 so a running reload keeps
	-- counting down through the next launch's countdown)
	reloadStart: number,
	reloadEnd: number,
	pendingStart: number,
	pendingEnd: number,
	reloadClone: Clone?,
	highlight: Highlight?,
	board: Board?,
	fadeIn: number, -- Reduce Motion: server time the fade-in started (0 = none)
}

local silos: { [number]: Silo } = {}
local pools: { [string]: { Clone } } = {}
local cloneCount: { [string]: number } = {}
local highlights: { Highlight } = {}
local freeHighlights: { Highlight } = {}
local boards: { Board } = {}
local freeBoards: { Board } = {}
local folder: Folder? = nil
local connection: RBXScriptConnection? = nil
local moveParts: { BasePart } = {}
local moveFrames: { CFrame } = {}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- The client folder holding clones / anchors (never replicated).
local function fxFolder(): Folder
	local existing = folder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "SN_SiloFx"
	created.Parent = Workspace
	folder = created
	return created
end

-- The area 7 model of a plot on this client (nil while not streamed).
local function areaOf(plot: number): Instance?
	local plots = Workspace:FindFirstChild("Plots")
	local model = if plots ~= nil then plots:FindFirstChild(`Plot{plot}`) else nil
	return if model ~= nil then model:FindFirstChild(AREA_NAME) else nil
end

-- True while a plot's Area 7 is knocked down (owner R50: KnockdownFx owns its pieces then).
local function knocked(plot: number): boolean
	local area = areaOf(plot)
	local untilTime = if area ~= nil then area:GetAttribute(KnockdownConfig.Attr.Until) else nil
	return type(untilTime) == "number" and untilTime > serverNow()
end

-- The server's standing rocket of a silo (Plots.PlotN.Area07.Builds.<build>.<model key>_i).
local function rocketOf(state: Silo): Model?
	local now = os.clock()
	local real = state.real
	if real ~= nil and real.Parent ~= nil and now - state.resolvedAt < RESOLVE_SECONDS then
		return real
	end
	state.resolvedAt = now
	local area = areaOf(state.plot)
	local builds = if area ~= nil then area:FindFirstChild(BUILDS_NAME) else nil
	local build = if builds ~= nil then builds:FindFirstChild(state.art.build) else nil
	local found: Model? = nil
	if build ~= nil then
		local key = state.art.model
		for _, child in build:GetChildren() do
			if child:IsA("Model") and string.sub(child.Name, 1, #key) == key then
				found = child
				break
			end
		end
	end
	if found ~= state.real then
		state.hidden = -1 -- a new instance: its LocalTransparencyModifier is untouched
	end
	state.real = found
	if found ~= nil then
		state.rest = found:GetPivot()
	end
	return found
end

-- Writes LocalTransparencyModifier on the real rocket (only when it changed).
local function setReal(state: Silo, value: number)
	local real = state.real
	if real == nil or state.hidden == value then
		return
	end
	state.hidden = value
	for _, part in real:GetDescendants() do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = value
		end
	end
end

-- A pooled clone of a silo rocket (nil over the per-key budget / no source).
local function acquire(real: Model, key: string, withFx: boolean): Clone?
	local pool = pools[key]
	if pool == nil then
		pool = {}
		pools[key] = pool
	end
	local existing = table.remove(pool :: { Clone })
	if existing ~= nil then
		return existing
	end
	if (cloneCount[key] or 0) >= FX.ClonesPerKey then
		return nil
	end
	cloneCount[key] = (cloneCount[key] or 0) + 1
	local model = real:Clone()
	model.Name = `SiloClone_{key}`
	local pivot = real:GetPivot()
	local clone: Clone = {
		model = model,
		key = key,
		parts = {},
		offsets = {},
		sizes = {},
		baseLtm = {},
		attach = nil,
		attachBase = nil,
		smoke = nil,
		flame = nil,
		light = nil,
		scale = 1,
		ltm = 0,
	}
	local host: BasePart? = nil
	for _, node in model:GetDescendants() do
		-- No tags on the copy: tag-driven systems (build-in, world FX) must never adopt it.
		for _, tag in CollectionService:GetTags(node) do
			CollectionService:RemoveTag(node, tag)
		end
		if node:IsA("BasePart") then
			node.Anchored = true
			node.CanCollide = false
			node.CanQuery = false
			node.CanTouch = false
			node.LocalTransparencyModifier = 0
			table.insert(clone.parts, node)
			local offset: CFrame = pivot:ToObjectSpace(node.CFrame)
			table.insert(clone.offsets, offset)
			table.insert(clone.sizes, node.Size)
			if host == nil or node.Size.Magnitude > host.Size.Magnitude then
				host = node
			end
		elseif node:IsA("Script") or node:IsA("LocalScript") or node:IsA("ClickDetector") then
			node:Destroy()
		end
	end
	if withFx and host ~= nil then
		local hostOffset = clone.offsets[table.find(clone.parts, host) :: number]
		local attach = Instance.new("Attachment")
		attach.Name = "Exhaust"
		attach.Position = hostOffset:PointToObjectSpace(Vector3.zero)
		attach.Parent = host
		local flame = Instance.new("ParticleEmitter")
		flame.Name = "Flame"
		flame.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		flame.Color = ColorSequence.new(Color3.fromRGB(255, 230, 110), Color3.fromRGB(255, 110, 40))
		flame.LightEmission = 0.9
		flame.LightInfluence = 0
		flame.Rate = 70
		flame.Lifetime = NumberRange.new(0.2, 0.4)
		flame.Speed = NumberRange.new(8, 14)
		flame.SpreadAngle = Vector2.new(18, 18)
		flame.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 4), NumberSequenceKeypoint.new(1, 0) })
		flame.EmissionDirection = Enum.NormalId.Bottom
		flame.Enabled = false
		flame.Parent = attach
		local smoke = Instance.new("ParticleEmitter")
		smoke.Name = "Smoke"
		smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
		smoke.Color = ColorSequence.new(Color3.fromRGB(240, 242, 236))
		smoke.LightInfluence = 0.8
		smoke.Lifetime = NumberRange.new(1.6, 2.6)
		smoke.Speed = NumberRange.new(6, 12)
		smoke.SpreadAngle = Vector2.new(70, 70)
		smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 5), NumberSequenceKeypoint.new(1, 14) })
		smoke.Transparency =
			NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		smoke.EmissionDirection = Enum.NormalId.Bottom
		smoke.Enabled = false
		smoke.Parent = attach
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 160, 60)
		light.Range = 22
		light.Brightness = 3
		light.Shadows = false
		light.Enabled = false
		light.Parent = attach
		clone.attach, clone.attachBase = attach, hostOffset
		clone.flame, clone.smoke, clone.light = flame, smoke, light
	end
	model:PivotTo(PARK)
	model.Parent = fxFolder()
	return clone
end

-- Writes a clone's LocalTransparencyModifier (only when it changed).
local function cloneLtm(clone: Clone, value: number)
	if math.abs(clone.ltm - value) < 0.01 then
		return
	end
	clone.ltm = value
	for _, part in clone.parts do
		part.LocalTransparencyModifier = value
	end
end

-- Exhaust on / off (smoke rate by FxQuality tier; the light only above Low).
local function exhaust(clone: Clone, on: boolean)
	local tier = FxQuality.tier()
	if clone.smoke ~= nil then
		clone.smoke.Rate = (FX.Smoke :: any)[tier] or FX.Smoke.Mid
		clone.smoke.Enabled = on
	end
	if clone.flame ~= nil then
		clone.flame.Enabled = on
	end
	if clone.light ~= nil then
		clone.light.Enabled = on and tier ~= "Low"
	end
end

-- Returns a clone to its pool (parked, full size, opaque, exhaust off).
local function release(clone: Clone?)
	if clone == nil then
		return
	end
	exhaust(clone, false)
	if clone.scale ~= 1 then
		for index, part in clone.parts do
			part.Size = clone.sizes[index]
		end
		clone.scale = 1
		if clone.attach ~= nil and clone.attachBase ~= nil then
			clone.attach.Position = clone.attachBase:PointToObjectSpace(Vector3.zero)
		end
	end
	cloneLtm(clone, 0)
	for _, part in clone.parts do
		table.insert(moveParts, part)
		table.insert(moveFrames, PARK)
	end
	table.insert(pools[clone.key], clone)
end

-- Queues a clone's pose (pivot = the rocket's tail) at `scale` for this frame's BulkMoveTo.
local function pose(clone: Clone, pivot: CFrame, scale: number)
	local rescale = math.abs(scale - clone.scale) > 1e-3
	for index, part in clone.parts do
		local offset = clone.offsets[index]
		local placed = if scale == 1 then offset else CFrame.new(offset.Position * scale) * offset.Rotation
		table.insert(moveParts, part)
		table.insert(moveFrames, pivot * placed)
		if rescale then
			part.Size = clone.sizes[index] * scale
		end
	end
	if rescale then
		clone.scale = scale
		local base = clone.attachBase
		if clone.attach ~= nil and base ~= nil then
			clone.attach.Position = (CFrame.new(base.Position * scale) * base.Rotation):PointToObjectSpace(Vector3.zero)
		end
	end
end

-- A pooled RELOADING board (nil over MaxBoards).
local function takeBoard(): Board?
	local free = table.remove(freeBoards)
	if free ~= nil then
		return free
	end
	if #boards >= FX.MaxBoards then
		return nil
	end
	local anchor = Instance.new("Part")
	anchor.Name = "ReloadAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = PARK
	anchor.Parent = fxFolder()
	local gui = Create.new("BillboardGui", {
		Name = "SiloReload",
		Adornee = anchor,
		Size = UDim2.fromOffset(FX.BoardPixels.X, FX.BoardPixels.Y),
		MaxDistance = FX.BoardMaxDistance,
		LightInfluence = 0,
		ResetOnSpawn = false,
		Enabled = false,
		Parent = LOCAL:FindFirstChildOfClass("PlayerGui"),
	}) :: BillboardGui
	local plate = Create.new("Frame", { Name = "Plate", Size = UDim2.fromScale(1, 1), Parent = gui }) :: Frame
	StudWindow.surface(plate, "orange", { edge = 2, corner = 10, tile = UIStyleConfig.StudTile.Button })
	Create.new("TextLabel", {
		Name = "Label",
		BackgroundTransparency = 1,
		Text = "RELOADING",
		TextScaled = true,
		FontFace = UIStyleConfig.Fonts.Number,
		TextColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(0.62, 0.62),
		Position = UDim2.fromScale(0.05, 0.06),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
		Parent = plate,
		Children = { Create.new("UIStroke", { Thickness = 2, Color = UIStyleConfig.Neutral.TextStroke }) },
	})
	local seconds = Create.new("TextLabel", {
		Name = "Seconds",
		BackgroundTransparency = 1,
		Text = "",
		TextScaled = true,
		FontFace = UIStyleConfig.Fonts.Number,
		TextColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(0.3, 0.62),
		Position = UDim2.fromScale(0.67, 0.06),
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 3,
		Parent = plate,
		Children = { Create.new("UIStroke", { Thickness = 2, Color = UIStyleConfig.Neutral.TextStroke }) },
	}) :: TextLabel
	local well = Create.new("Frame", {
		Name = "Well",
		BackgroundColor3 = Color3.fromRGB(40, 30, 20),
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0.9, 0.18),
		Position = UDim2.fromScale(0.05, 0.74),
		ZIndex = 3,
		Parent = plate,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) },
	}) :: Frame
	local fill = Create.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Color3.fromRGB(255, 236, 120),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 4,
		Parent = well,
		Children = { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) },
	}) :: Frame
	local board: Board = { anchor = anchor, gui = gui, seconds = seconds, fill = fill, shown = -1 }
	table.insert(boards, board)
	return board
end

local function dropBoard(state: Silo)
	local board = state.board
	if board == nil then
		return
	end
	state.board = nil
	board.gui.Enabled = false
	board.anchor.CFrame = PARK
	board.shown = -1
	table.insert(freeBoards, board)
end

-- A pooled RELOADING glow (nil over MaxHighlights: Roblox caps live Highlights per client).
local function takeHighlight(): Highlight?
	local free = table.remove(freeHighlights)
	if free ~= nil then
		return free
	end
	if #highlights >= FX.MaxHighlights then
		return nil
	end
	local highlight = Instance.new("Highlight")
	highlight.Name = "SiloReloadGlow"
	highlight.FillColor = FX.GlowColor
	highlight.OutlineColor = FX.GlowColor
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Parent = fxFolder()
	table.insert(highlights, highlight)
	return highlight
end

local function dropHighlight(state: Silo)
	local highlight = state.highlight
	if highlight == nil then
		return
	end
	state.highlight = nil
	highlight.Enabled = false
	highlight.Adornee = nil
	table.insert(freeHighlights, highlight)
end

-- Ends a silo's reload visuals (clone, glow, board).
local function dropReload(state: Silo)
	release(state.reloadClone)
	state.reloadClone = nil
	dropHighlight(state)
	dropBoard(state)
end

-- One silo's lift-off frame. Returns false once the lift-off is over.
local function stepLaunch(state: Silo, now: number): boolean
	local rel = now - state.t0
	local phase = SiloLaunchMath.phase(rel)
	if phase == "before" then
		return true
	end
	local real = rocketOf(state)
	local rest = state.rest
	if state.reduced then
		-- Reduce Motion: the real rocket fades out over ReducedFade after t0.
		if rel >= 0 then
			setReal(state, math.clamp(rel / FX.ReducedFade, 0, 1))
		end
		return rel < FX.ReducedFade
	end
	if not state.ignited then
		state.ignited = true
		dropReload(state)
		if real ~= nil and rest ~= nil then
			state.launchClone = acquire(real, state.art.model, true)
		end
		if state.launchClone ~= nil then
			setReal(state, 1)
			exhaust(state.launchClone :: Clone, true)
		end
	end
	local clone = state.launchClone
	if clone == nil or rest == nil then
		return phase ~= "gone"
	end
	local flight = state.flight :: FlightMath.Flight
	local rotation = rest - rest.Position
	if phase == "ignite" then
		local shake = FX.ShakeStuds * (rel + FX.IgniteLead) / FX.IgniteLead
		local jitter = Vector3.new((math.random() - 0.5) * shake, 0, (math.random() - 0.5) * shake)
		pose(clone, rest + UP * (SiloLaunchMath.rise(rel) + state.drop) + jitter, 1)
		return true
	elseif phase == "handoff" then
		local b = SiloLaunchMath.blend(rel)
		local own = rest.Position + UP * (SiloLaunchMath.climb(rel) + state.drop * (1 - b))
		local arc = FlightMath.position(flight, rel)
		local velocity = FlightMath.velocity(flight, rel)
		local direction = if velocity.Magnitude > 1e-3 then UP:Lerp(velocity.Unit, b) else UP
		direction = if direction.Magnitude > 1e-3 then direction.Unit else UP
		local tail = own:Lerp(arc, b)
		local turn = CFrame.fromRotationBetweenVectors(UP, direction)
		pose(clone, CFrame.new(tail) * turn * rotation, SiloLaunchMath.scale(rel, state.length))
		return true
	end
	-- Gone: the flight nuke takes over right here; a puff covers the swap.
	AttackFx.puff(FlightMath.position(flight, FX.HandOff), 8)
	release(clone)
	state.launchClone = nil
	return false
end

-- One silo's reload frame. Returns false once it is reloaded (state can be dropped).
local function stepReload(state: Silo, now: number, eye: Vector3, reduced: boolean): boolean
	if state.reloadEnd <= 0 then
		return false
	end
	local real = rocketOf(state)
	local rest = state.rest
	if now >= state.reloadEnd then
		dropReload(state)
		if knocked(state.plot) then
			return false -- KnockdownFx owns the pieces now; its rebuild shows them
		end
		if reduced then
			if state.fadeIn == 0 then
				state.fadeIn = now
			end
			local u = math.clamp((now - state.fadeIn) / FX.ReducedFade, 0, 1)
			setReal(state, 1 - u)
			return u < 1
		end
		setReal(state, 0)
		return false
	end
	-- Empty gantry while reloading (re-asserted: streamed back in / revealed by another system).
	if real ~= nil and state.hidden ~= 1 then
		setReal(state, 1)
	end
	local near = rest ~= nil and (rest.Position - eye).Magnitude <= FX.ReloadDistance
	if not near or rest == nil or real == nil then
		dropReload(state)
		return true
	end
	local p = SiloLaunchMath.progress(now, state.reloadStart, state.reloadEnd)
	if not reduced then
		local clone = state.reloadClone
		if clone == nil then
			clone = acquire(real, state.art.model, false)
			state.reloadClone = clone
		end
		if clone ~= nil then
			pose(clone, rest + UP * SiloLaunchMath.reloadOffset(p), 1)
			cloneLtm(clone, SiloLaunchMath.reloadFade(p))
			local highlight = state.highlight or takeHighlight()
			state.highlight = highlight
			if highlight ~= nil then
				if highlight.Adornee ~= clone.model then
					highlight.Adornee = clone.model
					highlight.Enabled = true
				end
				local pulse = 0.5 + 0.5 * math.sin(now * 6)
				highlight.FillTransparency = 0.45 + 0.3 * pulse
				highlight.OutlineTransparency = 0.2 + 0.3 * pulse
			end
		end
	else
		release(state.reloadClone)
		state.reloadClone = nil
		dropHighlight(state)
	end
	local board = state.board or takeBoard()
	state.board = board
	if board ~= nil then
		local left = math.max(math.ceil(state.reloadEnd - now), 0)
		if board.shown ~= left then
			board.shown = left
			board.seconds.Text = `{left}s`
			board.anchor.CFrame = rest + UP * (FX.SiloLength + FX.BoardLift)
			board.gui.Enabled = true
		end
		board.fill.Size = UDim2.fromScale(p, 1)
	end
	return true
end

-- The one per-frame body (alive only while a silo is launching / reloading).
local function step()
	local camera = Workspace.CurrentCamera
	local eye = if camera ~= nil then camera.CFrame.Position else Vector3.zero
	local now = serverNow()
	local reduced = OfferFx.reducedMotion()
	for key, state in silos do
		-- The next reload starts at its flight's t0 (the gantry empties then).
		if state.pendingEnd > 0 and now >= state.pendingStart - FX.HandOff then
			state.reloadStart = state.pendingStart
			state.reloadEnd = math.max(state.reloadEnd, state.pendingEnd)
			state.pendingStart, state.pendingEnd = 0, 0
			state.fadeIn = 0
		end
		if state.launching then
			state.launching = stepLaunch(state, now)
		end
		local alive = state.launching or state.pendingEnd > 0
		if not state.launching then
			alive = stepReload(state, now, eye, reduced) or alive
		end
		if not alive then
			dropReload(state)
			silos[key] = nil
		end
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(moveParts)
		table.clear(moveFrames)
	end
	if next(silos) == nil and connection ~= nil then
		connection:Disconnect()
		connection = nil
	end
end

-- The flight nuke's length for a tier (template attribute, else the config fallback).
local function flightLength(tier: number): number
	local templates = ReplicatedStorage:FindFirstChild(AttackConfig.TemplateFolder)
	local template = if templates ~= nil then templates:FindFirstChild(`Nuke{tier}`) else nil
	local length = if template ~= nil then template:GetAttribute("Length") else nil
	return if type(length) == "number" and length > 0 and length < 100 then length else FX.FlightLength
end

--[[
	A launch from a plot's silo (FlightRenderer.add, for EVERY NukeFlight): plans the lift-off and
	the reload. Returns the hand-off — the seconds after t0 until which FlightRenderer must NOT draw
	the flight nuke (the silo rocket flies that part); 0 = draw it from t0 as before (no rocket on
	this client, culled, Reduce Motion, too late, area knocked down, the silo still lifting off).
	@param data { fromUserId, fromPlot, silo, t0, kind, tier } — the validated flight data
	@param flight FlightMath.Flight — the arc FlightRenderer draws
	@return number
]]
function SiloLaunch.launch(data: any, flight: FlightMath.Flight): number
	local plot: number = if type(data.fromPlot) == "number" then data.fromPlot else 0
	if #siloArt == 0 or AttackGeometry.validPlot(plot) == nil then
		return 0
	end
	local siloIndex = if type(data.silo) == "number" then math.clamp(math.floor(data.silo), 1, #siloArt) else 1
	local art = siloArt[siloIndex]
	local now = serverNow()
	local t0: number = if type(data.t0) == "number" then data.t0 else now
	if now - t0 >= FX.HandOff or knocked(plot) then
		return 0
	end
	local key = plot * 4 + siloIndex
	local state = silos[key]
	if state == nil then
		local created: Silo = {
			plot = plot,
			silo = siloIndex,
			art = art,
			real = nil,
			resolvedAt = -math.huge,
			rest = nil,
			hidden = -1,
			launching = false,
			t0 = t0,
			flight = nil,
			length = FX.FlightLength,
			reduced = false,
			drop = 0,
			launchClone = nil,
			ignited = false,
			reloadStart = 0,
			reloadEnd = 0,
			pendingStart = 0,
			pendingEnd = 0,
			reloadClone = nil,
			highlight = nil,
			board = nil,
			fadeIn = 0,
		}
		silos[key] = created
		state = created
	end
	local current = state :: Silo
	-- The reload restarts from this launch at its t0 (barrages extend it).
	local start = t0 + FX.HandOff
	current.pendingStart = start
	current.pendingEnd =
		math.max(current.pendingEnd, start + SiloLaunchMath.reloadSeconds(tostring(data.kind), data.tier))
	if connection == nil then
		connection = RunService.PreRender:Connect(step)
	end
	if current.launching then
		return 0 -- this silo's rocket is still lifting off: the extra nuke just flies
	end
	local real = rocketOf(current)
	local camera = Workspace.CurrentCamera
	local mine = data.fromUserId == LOCAL.UserId
	local rest = current.rest
	local near = rest ~= nil
		and camera ~= nil
		and (mine or (rest.Position - camera.CFrame.Position).Magnitude <= FX.CullDistance)
	if real == nil or not near then
		-- Not drawn here: the gantry simply empties at t0 (the reload loop hides the real rocket).
		return 0
	end
	-- Fired mid-reload: lift off from where the fresh rocket has got to.
	local drop = 0
	if current.reloadClone ~= nil then
		drop = SiloLaunchMath.reloadOffset(SiloLaunchMath.progress(now, current.reloadStart, current.reloadEnd))
	end
	current.launching = true
	current.ignited = false
	current.t0 = t0
	current.flight = flight
	current.length = flightLength(if type(data.tier) == "number" then data.tier else 1)
	current.reduced = OfferFx.reducedMotion()
	current.drop = drop
	return if current.reduced then 0 else FX.HandOff
end

--[[ Diagnostics (QA tools/qa/attack_view.py): silos launching / reloading, clones, boards. ]]
function SiloLaunch.stats(): { [string]: any }
	local launching, reloading, clones = 0, 0, 0
	local list = {}
	for _, state in silos do
		if state.launching then
			launching += 1
		elseif state.reloadEnd > 0 or state.pendingEnd > 0 then
			reloading += 1
		end
		if state.launchClone ~= nil or state.reloadClone ~= nil then
			clones += 1
		end
		table.insert(list, {
			plot = state.plot,
			silo = state.silo,
			launching = state.launching,
			reloadLeft = math.max(state.reloadEnd - serverNow(), 0),
			hidden = state.hidden,
			board = state.board ~= nil,
			glow = state.highlight ~= nil,
		})
	end
	return {
		enabled = #siloArt > 0,
		launching = launching,
		reloading = reloading,
		clones = clones,
		running = connection ~= nil,
		silos = list,
	}
end

return SiloLaunch
