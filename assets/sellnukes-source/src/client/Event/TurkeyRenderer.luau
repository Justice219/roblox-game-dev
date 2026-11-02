--!strict
--[[
	TurkeyRenderer — draws and animates every Golden Turkey on this client (Harvest Feast).

	Purpose:
		The server never creates turkey Instances; it sends each turkey's wander loop (EventState
		"spawn" / "sync") and this module renders it: a pooled clone of
		ReplicatedStorage.HarvestFeast.GoldenTurkey placed by EventConfig.pose(path, serverTime) —
		the exact pose the server validates catches against — with a waddle (bob + sway) while
		walking and a peck nod at each stop. Each turkey carries a ProximityPrompt "Catch!"
		(keyboard E / gamepad X / a tap on touch) and a ClickDetector (mouse click / tap from
		TapRange); both call `onCatch(id)`. A turkey this player cannot catch (another player's
		lure) shows no prompt.

	Standing ON the ground (owner R96 "the turkey i in the ground"):
		- Every part is placed relative to the bird's REAL feet (EventConfig.groundFrame over the
		  visual parts' boxes), not the model pivot: a template whose pivot sits mid-bird (a
		  PrimaryPart pivot) can never sink the turkey into the road again.
		- Ground follow: a visible turkey re-probes the walkable surface under it (EventConfig.Turkey
		  GroundHz, one ray, RespectCanCollide) and lifts its feet onto curbs / bed edges between the
		  server-snapped waypoints (EventConfig.groundSnapY window), eased so a step never pops.
		- The waddle bob only ever lifts (|sin|) and the peck pivots on the feet; the Catch! prompt
		  hangs on an attachment PromptLift above the hitbox top (over the head, never at ground
		  level).

	Performance (owner rules: one RunService connection per system, no per-frame Instance.new):
		- ONE Heartbeat connection moves every visible turkey with a single Workspace:BulkMoveTo.
		- Turkeys farther than RenderDistance from the camera are unparented (no draw, no update);
		  beyond SlowDistance they update at SlowHz.
		- Models (with their prompt + click detector) are pooled and reused; nothing is created per
		  frame. Reduced Motion parks the waddle (turkeys still glide along their path).
		- Ground probes: at most GroundHz rays per visible turkey per second (<= 22 turkeys), with one
		  shared RaycastParams whose exclusion list (characters + the turkey folder) refreshes once a
		  second, not per ray.

	Connects to: Shared/Config/EventConfig (pose maths, ranges), Client/Event/EventController (adds /
	removes turkeys from EventState, sends EventCollect, plays FX).

	Example:
		TurkeyRenderer.start(function(id) Remotes.event("EventCollect"):FireServer(id) end)
		TurkeyRenderer.setTemplate(ReplicatedStorage.HarvestFeast.GoldenTurkey)
		TurkeyRenderer.add(wire)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)

type TurkeyWire = EventConfig.TurkeyWire

-- One pooled turkey model: its parts with their offsets from the bird's real feet
-- (EventConfig.groundFrame), so `groundCFrame * offset` stands it on the ground.
type Visual = {
	model: Model,
	parts: { BasePart },
	offsets: { CFrame },
	prompt: ProximityPrompt,
	click: ClickDetector,
	hitbox: BasePart,
	-- Studs the bird rises at the full peck nod so its tipped-forward toes stay on the ground.
	peckLift: number,
}

-- One turkey this client knows about.
type Entry = {
	wire: TurkeyWire,
	compiled: EventConfig.CompiledPath,
	visual: Visual?,
	catchable: boolean, -- false: another player's lure
	pendingAt: number, -- os.clock() of the last catch request (0 = none)
	lastUpdate: number, -- os.clock() of the last pose write (slow updates)
	phaseSeed: number, -- per-turkey animation offset
	-- Ground follow (owner R96): feet height above the path point, its probed target, and the
	-- os.clock() of the last probe (0 = never probed: the next pose snaps instead of easing).
	lift: number,
	liftTarget: number,
	groundAt: number,
}

local TurkeyRenderer = {}

local localPlayer = Players.LocalPlayer
local entries: { [string]: Entry } = {}
local pool: { Visual } = {}
local template: Model? = nil
local folder: Folder? = nil
local connection: RBXScriptConnection? = nil
local catchCallback: ((id: string) -> ())? = nil
local reducedMotion = false
-- ProximityPrompts are the catch fallback for keyboard / gamepad / touch until the platform
-- layer's "EventCollect" action exists (EventController turns them off then).
local promptsEnabled = true

-- Seconds a catch request waits for the server before it may be sent again.
local PENDING_SECONDS = 1.2
-- Waddle / peck animation (radians / studs / Hz).
local BOB_HEIGHT = 0.28
local WADDLE_HZ = 2.6
local SWAY = math.rad(7)
local PECK_PITCH = math.rad(26)
-- Seconds between two refreshes of the ground probe's exclusion list (characters come and go).
local GROUND_FILTER_SECONDS = 1

-- Ground follow probe (owner R96): walkable surfaces only (RespectCanCollide), never characters
-- or the turkeys themselves (exclusion list refreshed by refreshGroundFilter).
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
groundParams.RespectCanCollide = true
local groundFilterAt = -math.huge

-- The Workspace folder the visible turkeys live in (client-only).
local function container(): Folder
	if folder ~= nil and folder.Parent ~= nil then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "HarvestTurkeys"
	created.Parent = Workspace
	folder = created
	return created
end

-- Builds one pooled visual from the template (prompt + click detector wired once).
local function newVisual(): Visual?
	local source = template
	if source == nil then
		return nil
	end
	local model = source:Clone()
	local hitbox = model:FindFirstChild("Hitbox")
	if hitbox == nil or not hitbox:IsA("BasePart") then
		model:Destroy()
		return nil
	end
	-- The real feet (owner R96): the lowest point of the VISUAL parts (the invisible hitbox is
	-- left out of the measurement) under the pivot's rotation. Offsets are taken from there.
	local boxes: { EventConfig.GroundBox } = {}
	local parts: { BasePart } = {}
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			table.insert(parts, item)
			if item ~= hitbox then
				table.insert(boxes, { cframe = item.CFrame, size = item.Size })
			end
		end
	end
	local feet = EventConfig.groundFrame(model:GetPivot(), boxes)
	local offsets: { CFrame } = {}
	for index, part in parts do
		offsets[index] = feet:ToObjectSpace(part.CFrame)
	end
	-- The peck nod tips the bird forward on its feet; measure (once per pooled model) how far its
	-- lowest point would dip at the full nod, so poseCFrame lifts it by that much.
	local nod = CFrame.Angles(-PECK_PITCH, 0, 0)
	local tipped: { EventConfig.GroundBox } = {}
	for _, box in boxes do
		table.insert(tipped, { cframe = nod * feet:ToObjectSpace(box.cframe), size = box.size })
	end
	local peckLift = math.max(0, -EventConfig.groundFrame(CFrame.identity, tipped).Position.Y)
	-- The prompt hangs over the bird's head (hitbox top + PromptLift), never at ground level.
	local anchor = Instance.new("Attachment")
	anchor.Name = "PromptAnchor"
	anchor.Position = Vector3.new(0, hitbox.Size.Y / 2 + EventConfig.Turkey.PromptLift, 0)
	anchor.Parent = hitbox
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CatchPrompt"
	prompt.ActionText = "Catch!"
	prompt.ObjectText = "Golden Turkey"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = EventConfig.Turkey.PromptRange
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor
	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = EventConfig.Turkey.TapRange
	click.CursorIcon = ""
	click.Parent = hitbox
	local visual: Visual = {
		model = model,
		parts = parts,
		offsets = offsets,
		prompt = prompt,
		click = click,
		hitbox = hitbox,
		peckLift = peckLift,
	}
	local function fire()
		local id = model:GetAttribute("TurkeyId")
		if type(id) == "string" then
			TurkeyRenderer.requestCatch(id)
		end
	end
	prompt.Triggered:Connect(fire)
	click.MouseClick:Connect(fire)
	return visual
end

-- A visual for an entry (pool or new); nil until the template has replicated.
local function acquire(entry: Entry): Visual?
	local visual = table.remove(pool) or newVisual()
	if visual == nil then
		return nil
	end
	visual.model:SetAttribute("TurkeyId", entry.wire.id)
	visual.prompt.Enabled = entry.catchable and promptsEnabled
	visual.click.MaxActivationDistance = if entry.catchable then EventConfig.Turkey.TapRange else 0
	visual.model.Parent = container()
	entry.visual = visual
	entry.groundAt = 0 -- re-probe at once; the first pose snaps (no easing from a stale height)
	return visual
end

-- Returns an entry's visual to the pool (unparented: no draw cost).
local function release(entry: Entry)
	local visual = entry.visual
	if visual == nil then
		return
	end
	entry.visual = nil
	visual.model.Parent = nil
	visual.model:SetAttribute("TurkeyId", nil)
	table.insert(pool, visual)
end

-- Rebuilds the ground probe's exclusion list (every character + the turkey folder), at most once
-- per GROUND_FILTER_SECONDS.
local function refreshGroundFilter(clock: number)
	if clock - groundFilterAt < GROUND_FILTER_SECONDS then
		return
	end
	groundFilterAt = clock
	local exclude: { Instance } = { container() }
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character ~= nil then
			table.insert(exclude, character)
		end
	end
	groundParams.FilterDescendantsInstances = exclude
end

--[[
	Ground follow (owner R96): updates `entry.lift` (feet height above the path point) from a probe
	of the walkable surface under `position`, at most GroundHz times a second, eased at GroundEase.
	A never-probed entry (groundAt = 0) snaps straight to the probe.
	@param dt seconds since this entry's previous pose write (easing step)
]]
local function updateLift(entry: Entry, position: Vector3, clock: number, dt: number)
	local cfg = EventConfig.Turkey
	local snap = entry.groundAt == 0
	if snap or clock - entry.groundAt >= 1 / cfg.GroundHz then
		entry.groundAt = clock
		refreshGroundFilter(clock)
		local origin = position + Vector3.new(0, cfg.GroundUp, 0)
		local hit = Workspace:Raycast(origin, Vector3.new(0, -(cfg.GroundUp + cfg.GroundDown), 0), groundParams)
		local y = EventConfig.groundSnapY(
			position.Y,
			if hit ~= nil then hit.Position.Y else nil,
			cfg.GroundUp,
			cfg.GroundDown
		)
		entry.liftTarget = y - position.Y
	end
	if snap then
		entry.lift = entry.liftTarget
	else
		entry.lift += (entry.liftTarget - entry.lift) * math.min(1, math.max(0, dt) * cfg.GroundEase)
	end
end

--[[
	The feet CFrame of a turkey in `pose` at time `t` (lifted onto the probed ground by
	entry.lift), with the waddle / peck animation. The bob only lifts and the peck pivots on the
	feet, so no animation frame dips the bird below the ground.
]]
local function poseCFrame(entry: Entry, visual: Visual, pose: EventConfig.Pose, t: number): CFrame?
	if not pose.alive then
		return nil
	end
	local position = pose.position + Vector3.new(0, entry.lift, 0)
	local facing = pose.facing
	local base = CFrame.lookAt(position, position + facing)
	if reducedMotion then
		return base
	end
	local wave = (t + entry.phaseSeed) * WADDLE_HZ * math.pi * 2
	if pose.moving then
		local bob = math.abs(math.sin(wave)) * BOB_HEIGHT
		return base * CFrame.new(0, bob, 0) * CFrame.Angles(0, 0, math.sin(wave) * SWAY)
	end
	-- Pecking: two quick nods forward (pivot at the feet) per stop, lifted in proportion to the
	-- nod (peckLift at the full PECK_PITCH) so the tipped toes never go under the ground.
	local nod = math.max(0, math.sin(pose.phase * math.pi * 4)) * PECK_PITCH
	local rise = visual.peckLift * math.sin(nod) / math.sin(PECK_PITCH)
	return base * CFrame.new(0, rise, 0) * CFrame.Angles(-nod, 0, 0)
end

-- Per-frame work: one BulkMoveTo for every visible turkey (see the module header).
local bulkParts: { BasePart } = {}
local bulkFrames: { CFrame } = {}
local function step()
	local t = Workspace:GetServerTimeNow()
	local clock = os.clock()
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera ~= nil then camera.CFrame.Position else Vector3.zero
	local cfg = EventConfig.Turkey
	table.clear(bulkParts)
	table.clear(bulkFrames)
	for id, entry in entries do
		if t >= entry.compiled.ends then
			TurkeyRenderer.remove(id)
			continue
		end
		local pose = EventConfig.pose(entry.compiled, t)
		local distance = (pose.position - cameraPosition).Magnitude
		if distance > cfg.RenderDistance then
			release(entry)
			continue
		end
		if distance > cfg.SlowDistance and entry.visual ~= nil and clock - entry.lastUpdate < 1 / cfg.SlowHz then
			continue
		end
		local visual = entry.visual or acquire(entry)
		if visual == nil then
			continue
		end
		if not pose.alive then
			continue
		end
		updateLift(entry, pose.position, clock, clock - entry.lastUpdate)
		local cf = poseCFrame(entry, visual, pose, t)
		if cf == nil then
			continue
		end
		entry.lastUpdate = clock
		for index, part in visual.parts do
			table.insert(bulkParts, part)
			table.insert(bulkFrames, cf * visual.offsets[index])
		end
	end
	if #bulkParts > 0 then
		Workspace:BulkMoveTo(bulkParts, bulkFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

--------------------------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------------------------

--[[ Sets the replicated turkey template (models are built lazily from it). ]]
function TurkeyRenderer.setTemplate(model: Model)
	template = model
end

--[[ Turns the waddle animation off / on (Reduced Motion). ]]
function TurkeyRenderer.setReducedMotion(on: boolean)
	reducedMotion = on
end

--[[ Adds (or replaces) a turkey from a validated wire. ]]
function TurkeyRenderer.add(wire: TurkeyWire)
	local existing = entries[wire.id]
	if existing ~= nil then
		release(existing)
	end
	local seed = 0
	for index = 1, #wire.id do
		seed += string.byte(wire.id, index)
	end
	entries[wire.id] = {
		wire = wire,
		compiled = EventConfig.compilePath(wire),
		visual = nil,
		catchable = wire.owner == 0 or wire.owner == localPlayer.UserId,
		pendingAt = 0,
		lastUpdate = 0,
		phaseSeed = (seed % 97) / 97,
		lift = 0,
		liftTarget = 0,
		groundAt = 0,
	}
end

--[[ Removes a turkey (caught / despawned / expired). @return its last ground position, if known ]]
function TurkeyRenderer.remove(id: string): Vector3?
	local entry = entries[id]
	if entry == nil then
		return nil
	end
	entries[id] = nil
	-- Where the feet really were (path point + ground-follow lift), so catch FX start on the bird.
	local position = EventConfig.pose(entry.compiled, Workspace:GetServerTimeNow()).position
		+ Vector3.new(0, entry.lift, 0)
	release(entry)
	return position
end

--[[ Forgets every turkey (a full "sync" replaces the set). ]]
function TurkeyRenderer.clear()
	for id in entries do
		TurkeyRenderer.remove(id)
	end
end

--[[ The turkey's current ground position (nil when unknown). ]]
function TurkeyRenderer.positionOf(id: string): Vector3?
	local entry = entries[id]
	if entry == nil then
		return nil
	end
	return EventConfig.pose(entry.compiled, Workspace:GetServerTimeNow()).position + Vector3.new(0, entry.lift, 0)
end

--[[ Allows a new catch request for this turkey (the server refused the last one). ]]
function TurkeyRenderer.clearPending(id: string)
	local entry = entries[id]
	if entry ~= nil then
		entry.pendingAt = 0
	end
end

--[[
	Sends a catch request for `id` through the start() callback, at most once per PENDING_SECONDS
	per turkey (the server answers "caught" or "refused").
]]
function TurkeyRenderer.requestCatch(id: string)
	local entry = entries[id]
	local callback = catchCallback
	if entry == nil or callback == nil or not entry.catchable then
		return
	end
	local now = os.clock()
	if entry.pendingAt > 0 and now - entry.pendingAt < PENDING_SECONDS then
		return
	end
	entry.pendingAt = now
	callback(id)
end

--[[
	Ids of catchable turkeys within `radius` studs (flat distance) of `position` — the auto-catch
	when a player walks into a turkey.
]]
function TurkeyRenderer.near(position: Vector3, radius: number): { string }
	local t = Workspace:GetServerTimeNow()
	local found: { string } = {}
	for id, entry in entries do
		if not entry.catchable then
			continue
		end
		local pose = EventConfig.pose(entry.compiled, t)
		if pose.alive then
			local delta = pose.position - position
			if Vector3.new(delta.X, 0, delta.Z).Magnitude <= radius and math.abs(delta.Y) < 8 then
				table.insert(found, id)
			end
		end
	end
	return found
end

--[[
	The nearest catchable turkey within `radius` studs (flat distance) of `position`, or nil — the
	target of the platform "EventCollect" action (gamepad A / E / the touch CATCH! button).
]]
function TurkeyRenderer.nearest(position: Vector3, radius: number): string?
	local t = Workspace:GetServerTimeNow()
	local bestId: string? = nil
	local best = radius
	for id, entry in entries do
		if not entry.catchable then
			continue
		end
		local pose = EventConfig.pose(entry.compiled, t)
		if pose.alive then
			local delta = pose.position - position
			local distance = Vector3.new(delta.X, 0, delta.Z).Magnitude
			if distance <= best and math.abs(delta.Y) < 8 then
				best, bestId = distance, id
			end
		end
	end
	return bestId
end

--[[ Shows / hides every turkey's "Catch!" ProximityPrompt (the platform action replaces it). ]]
function TurkeyRenderer.setPromptsEnabled(on: boolean)
	promptsEnabled = on
	for _, entry in entries do
		local visual = entry.visual
		if visual ~= nil then
			visual.prompt.Enabled = entry.catchable and on
		end
	end
end

--[[ Number of turkeys known (tests / diagnostics). ]]
function TurkeyRenderer.count(): number
	local count = 0
	for _ in entries do
		count += 1
	end
	return count
end

--[[ Starts the per-frame driver; `onCatch(id)` sends the intent to the server. ]]
function TurkeyRenderer.start(onCatch: (id: string) -> ())
	catchCallback = onCatch
	if connection == nil then
		connection = RunService.Heartbeat:Connect(step)
	end
end

return TurkeyRenderer
