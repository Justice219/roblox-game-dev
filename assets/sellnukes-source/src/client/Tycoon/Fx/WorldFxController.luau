--!strict
--[[
	WorldFxController — the living world: spinning rotors/turbines, sweeping dishes, waving arms,
	scrolling belts, bobbing glows / toys / hovering bots, soft pulsing lights, cooling-tower
	steam, pad-press squish + "ka-ching", and the area-unlock fanfare.

	Data-driven: MeshLibrary tags every piece whose NAME resolves in WorldFxConfig (or that a model
	assembly lists) with WorldFxConfig.Tag. Art builders only name pieces; behaviour is config.

	Motion GROUPS (owner R25 / R26): motions are computed per group, never per piece. A group is
	the set of pieces of one spawned model sharing a group name (WorldFxConfig.groupFor: same row,
	or an explicit assembly). The first piece is the leader; every other piece keeps its offset
	from the leader (`rel`), so a toy nuke's cap never drifts off its body and a car's roof rocket
	rides the car. One motion CFrame per group per frame.

	Performance (hundreds of pieces per server, owner R11 tiers via FxQuality):
		* ONE Heartbeat connection. Every RefreshInterval groups are re-ranked by camera distance:
		  only the nearest MaxMoving groups within Range move (one BulkMoveTo per frame), only the
		  nearest MaxLights pieces light up, only the nearest MaxEmitters steam. The re-rank sorts
		  only the groups within Range and reads no Instance properties (group centres are cached).
		* Per frame (perf pass 2026-10-30, 8 full plots: the BulkMoveTo was ~75% of client Luau
		  time): a moving group outside the camera cone (Shared/Util/ViewCone, frustum diagonal +
		  WorldFxConfig.ViewMarginDeg) holds its pose, and groups beyond the tier's HalfRateBeyond
		  move every other frame (staggered). Motion is time-based, so neither is visible.
		* Lights / steam emitters / belt textures are created the first time a piece is near, then
		  only toggled (no per-frame Instance.new, no per-frame tables or closures).
		* Lights are soft (owner R19): colour pulled toward warm white, shadows off, caps enforced
		  by tests/glow-budget.luau.

	Sounds (owner R57, sparse + FxQuality-aware): a periodic row with a `sound` (the Dino geyser
	jets' whoosh) plays once per motion period as its cycle passes `sound.at`; a model listed in
	WorldFxConfig.Ambience (the D6 volcano's soft rumble) plays now and then with random jitter.
	Both are ranked at refresh: only the tier's MaxSounds nearest in-range sources may sound (Low
	tier: 1), periodic ones only while actually moving (Reduce Motion / culled = silent).

	Hinges + swings (owner R75, "animate the miners ... they don't actually do anything"): an
	Assembly may name a model-space `hinge` (a shoulder, hips, a flag pole): its group then turns
	about that point (axis = the row's axis in the MODEL frame) instead of the leader's box centre.
	A "swing" row is a keyframed loop (Shared/World/SwingCurve: wind-up, strike, recoil, pause);
	swing groups of one model share one phase + stagger slot, so an arm that `follow`s the body
	lean rides it exactly, while every miner keeps its own beat. A swing `impact` fires once per
	loop, on screen and in range: a pooled burst (Fx/ImpactBursts, scaled by the tier's Bursts, none
	on Low), a short 3D sound in one of the tier's MaxSounds slots, and a brief flash of the model's
	glow lights at their pulse maximum (R19 caps hold). Reduce Motion: swings sway gently (the row's
	`gentle`), no impacts; every other row rests as before.

	Worlds (owner R57): world-agnostic by design — pieces are discovered by tag wherever they are
	spawned (Nuke Town plots, Workspace.Worlds.<id>.Plots, hubs), behaviour comes from the rows.

	Pads: PlotWatcher.PadAdded -> on the server's PressedAt attribute the pad squishes and plays
	"pad_buy" (R71: layered pop + coins) + "ka-ching", then fires PadPressed (the juice pass's
	coin burst, Fx/JuiceController). Fallback: a fresh purchase whose pad press was not seen plays the ka-ching
	at the build. Fanfare: BuildInController.BuildFinished on an area Base.

	Boot: controller contract Init() / Start().
]]

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BuildInConfig = require(ReplicatedStorage.Shared.Config.BuildInConfig)
local WorldFxConfig = require(ReplicatedStorage.Shared.Config.WorldFxConfig)
local WorldMaterialConfig = require(ReplicatedStorage.Shared.Config.WorldMaterialConfig)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local BuildInController = require(script.Parent.Parent.BuildIn.BuildInController)
local Confetti = require(script.Parent.Confetti)
local FxQuality = require(script.Parent.FxQuality)
local FxSound = require(script.Parent.FxSound)
local ImpactBursts = require(script.Parent.ImpactBursts)
local PlotWatcher = require(script.Parent.PlotWatcher)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SwingCurve = require(ReplicatedStorage.Shared.World.SwingCurve)
local ViewCone = require(ReplicatedStorage.Shared.Util.ViewCone)

type Group = {
	owner: Instance, -- the spawned model the group lives in (or the part itself when loose)
	name: string,
	fx: WorldFxConfig.PieceFx, -- shared motion row
	leader: BasePart?,
	base: CFrame, -- leader's authored CFrame; members are base * rel
	axis: Vector3,
	phase: number,
	members: { Member },
	distance: number,
	active: boolean, -- in the moving set this refresh
	moved: boolean, -- members currently offset from their authored CFrames
	suspended: boolean, -- inside a knocked-down area (owner R50): KnockdownFx owns its CFrames
	halfRate: boolean, -- beyond the tier's HalfRateBeyond: moves every other frame
	slot: number, -- stagger for half-rate frames (creation order)
	extras: boolean, -- some member owns a light / emitter / belt (far refresh must switch it off)
	soundAt: number, -- periodic sound: last cycle fraction seen (-1 = not sounding last frame)
	ambience: WorldFxConfig.AmbientSound?, -- the owner model's ambience row (Ambience[MeshKey])
	-- Owner R75 (Assembly.hinge): world hinge point + world rotation axis; nil hinge = turn about the
	-- leader's box centre on its own axis (every pre-R75 row).
	hinge: Vector3?,
	hingeAxis: Vector3,
	followName: string?, -- "@Lean": a group of the same owner whose motion this one rides
	impactPoint: Vector3?, -- swing impact: world point of the burst / sound
	impactLast: number, -- swing impact: last loop fraction seen (-1 = not armed)
	impactSlot: boolean, -- refresh gave this group one of the tier's sound slots for its impact
}

type Member = {
	part: BasePart,
	group: Group,
	rel: CFrame, -- offset from the group's leader base
	fx: WorldFxConfig.PieceFx?, -- the piece's own row (lights / steam / belt), may be nil
	light: PointLight?,
	emitter: ParticleEmitter?,
	belts: { Texture }?, -- scroll rows: one moving texture per face (row.faces, default Top)
	lit: boolean, -- mirrors light.Enabled (no per-frame property reads)
	steaming: boolean, -- mirrors emitter.Enabled
}

type Squish = { parts: { BasePart }, bases: { CFrame }, t0: number }

local WorldFxController = {}

-- Fires (padModel, position) when a pad press is played near the camera (owner R71: the juice
-- pass adds its coin burst here — Fx/JuiceController).
WorldFxController.PadPressed = Signal.new() :: Signal.Signal<Model, Vector3>

local started = false
local members: { [BasePart]: Member } = {}
local groupsByOwner: { [Instance]: { [string]: Group } } = {}
local groupList: { Group } = {}
local activeGroups: { Group } = {}
local nearGroups: { Group } = {} -- refresh scratch: groups within Range (sorted)
local nearMembers: { Member } = {}
local groupSlots = 0 -- next Group.slot
local frameCount = 0 -- half-rate stagger
local viewCos = -1 -- ViewCone limit for the current camera (-1 = everything visible)
local squishes: { Squish } = {}
-- "Plot3/a1_tool_wall" -> os.clock() of the last seen pad press (dedupes the ka-ching fallback).
local pressedAt: { [string]: number } = {}
local refreshTimer = math.huge -- force a refresh on the first frame
local clockStart = os.clock()
local random = Random.new()
-- Sound sources allowed this refresh (nearest first, tier MaxSounds): periodic-row groups and one
-- group per ambience model (its owner). Rebuilt at refresh, read per frame.
local soundGroups: { Group } = {}
local ambienceNext: { [Instance]: number } = {} -- owner model -> os.clock() of its next ambience
local soundOwners: { [Instance]: boolean } = {} -- refresh scratch: owners already given a slot
-- Owner R75: swing groups of one model share one phase + one half-rate stagger slot (an arm that
-- follows the body lean stays glued to it); each model gets its own (miners strike out of step).
local ownerPhases: { [Instance]: number } = {}
local ownerSlots: { [Instance]: number } = {}
-- Owner model -> os.clock() until which its glow lights sit at their pulse maximum (an impact flash).
local flashUntil: { [Instance]: number } = {}
-- Set at each refresh: Reduce Motion is on (swings sway gently, no impacts) / the tier's burst scale.
local gentleMode = false
local burstScale = 0
-- Shared empty key list (a swing row without keys never moves).
local NO_KEYS: { WorldFxConfig.SwingKey } = {}

local movedParts: { BasePart } = {}
local movedFrames: { CFrame } = {}

local AXES: { [string]: Vector3 } = { X = Vector3.xAxis, Y = Vector3.yAxis, Z = Vector3.zAxis }
-- Lights take the piece colour pulled this far toward warm white (owner R19: soft, never neon).
local WARM_WHITE = Color3.fromRGB(255, 236, 205)
local LIGHT_WARMTH = 0.55
-- Belt texture tile (studs); the scroll wraps at it (a constant: no per-frame property read).
local BELT_TILE = 2
-- Faces a scroll row's texture goes on when the row lists none.
local DEFAULT_FACES: { string } = { "Top" }

local function reducedMotion(): boolean
	if GuiService.ReducedMotionEnabled then
		return true
	end
	local profile = ClientState.profile
	local settings = profile and profile.settings
	return type(settings) == "table" and settings.reducedMotion == true
end

local function cameraPosition(): Vector3
	local camera = Workspace.CurrentCamera
	return if camera ~= nil then camera.CFrame.Position else Vector3.zero
end

-- "PlotN/padId" key for an instance inside Workspace.Plots.PlotN.
local function plotKey(instance: Instance, padId: string): string
	local node: Instance? = instance
	while node ~= nil and node.Parent ~= nil and node.Parent.Name ~= "Plots" do
		node = node.Parent
	end
	return `{if node ~= nil then node.Name else "?"}/{padId}`
end

--------------------------------------------------------------------------------------------------
-- Groups
--------------------------------------------------------------------------------------------------

-- Makes `member` the group leader: re-bases every member on its authored CFrame.
local function setLeader(group: Group, leader: Member)
	local newBase = group.base * leader.rel
	local inverse = newBase:Inverse()
	for _, member in group.members do
		member.rel = inverse * (group.base * member.rel)
	end
	group.base = newBase
	group.leader = leader.part
end

-- Roots (knocked-down areas' Builds) whose groups are suspended (owner R50, KnockdownFx).
local suspendedRoots: { [Instance]: boolean } = {}

-- True when a group owner lives under a suspended root (checked once, when a group is created).
local function suspendedFor(owner: Instance): boolean
	for root in suspendedRoots do
		if owner == root or owner:IsDescendantOf(root) then
			return true
		end
	end
	return false
end

-- The shared phase of a model's swing groups (created on first use, dropped with the model).
local function ownerPhase(owner: Instance): number
	local phase = ownerPhases[owner]
	if phase == nil then
		phase = random:NextNumber(0, 10)
		ownerPhases[owner] = phase
	end
	return phase :: number
end

-- The shared half-rate stagger slot of a model's swing groups.
local function ownerSlot(owner: Instance): number
	local slot = ownerSlots[owner]
	if slot == nil then
		slot = groupSlots
		groupSlots += 1
		ownerSlots[owner] = slot
	end
	return slot :: number
end

local function register(instance: Instance)
	if not instance:IsA("BasePart") or members[instance] ~= nil then
		return
	end
	local model = instance.Parent
	local modelKey = if model ~= nil then model:GetAttribute("MeshKey") else nil
	local groupName, row = WorldFxConfig.groupFor(if type(modelKey) == "string" then modelKey else nil, instance.Name)
	if groupName == nil or row == nil then
		return
	end
	local owner: Instance = if model ~= nil and model:IsA("Model") then model else instance
	local ambience = if type(modelKey) == "string" then WorldFxConfig.Ambience[modelKey] else nil
	-- Owner R75: an assembly group may carry a hinge / follow / impact point (model space).
	local assembly: WorldFxConfig.Assembly? = nil
	if type(modelKey) == "string" and string.sub(groupName, 1, 1) == "@" then
		local byKey = WorldFxConfig.Assemblies[modelKey]
		assembly = if byKey ~= nil then byKey[string.sub(groupName, 2)] else nil
	end
	local byName = groupsByOwner[owner]
	if byName == nil then
		byName = {}
		groupsByOwner[owner] = byName
	end
	local group = byName[groupName]
	if group == nil then
		-- The model's pivot (MeshLibrary sets WorldPivot = the layout placement): hinge maths frame.
		local pivot = if owner:IsA("Model") then (owner :: Model):GetPivot() else instance.CFrame
		local axis = AXES[row.axis or "Y"]
		local swing = row.motion == "swing"
		local hingeLocal = if assembly ~= nil then assembly.hinge else nil
		local created: Group = {
			owner = owner,
			name = groupName,
			fx = row,
			leader = instance,
			base = instance.CFrame,
			axis = axis,
			phase = if swing then ownerPhase(owner) else random:NextNumber(0, 10),
			members = {},
			distance = math.huge,
			active = false,
			moved = false,
			suspended = suspendedFor(owner),
			halfRate = false,
			slot = if swing then ownerSlot(owner) else groupSlots,
			extras = false,
			soundAt = -1,
			ambience = ambience,
			hinge = if hingeLocal ~= nil then pivot:PointToWorldSpace(hingeLocal) else nil,
			hingeAxis = pivot:VectorToWorldSpace(axis),
			followName = if assembly ~= nil and assembly.follow ~= nil then `@{assembly.follow}` else nil,
			impactPoint = if row.impact ~= nil
				then pivot:PointToWorldSpace((assembly and (assembly.impactAt or assembly.hinge)) or Vector3.zero)
				else nil,
			impactLast = -1,
			impactSlot = false,
		}
		if not swing then
			groupSlots += 1
		end
		group = created
		byName[groupName] = created
		table.insert(groupList, created)
	end
	local current = group :: Group
	local ownRow = WorldFxConfig.resolve(instance.Name)
	local member: Member = {
		part = instance,
		group = current,
		rel = current.base:Inverse() * instance.CFrame,
		fx = ownRow,
		light = nil,
		emitter = nil,
		belts = nil,
		lit = false,
		steaming = false,
	}
	-- A group joined while moving: compute rel from the authored pose, not the moved one.
	if current.moved and current.leader ~= nil then
		member.rel = current.base:Inverse() * instance.CFrame
	end
	members[instance] = member
	table.insert(current.members, member)
	refreshTimer = math.huge
end

local function unregister(instance: Instance)
	local member = members[instance :: BasePart]
	if member == nil then
		return
	end
	members[member.part] = nil
	local group = member.group
	local index = table.find(group.members, member)
	if index ~= nil then
		table.remove(group.members, index)
	end
	-- Tag removed but the part stays: drop what we added and put it back.
	if member.part.Parent ~= nil then
		if member.light ~= nil then
			member.light:Destroy()
		end
		for _, belt in member.belts or {} do
			belt:Destroy()
		end
		if member.emitter ~= nil and member.emitter.Parent ~= nil then
			(member.emitter.Parent :: Instance):Destroy()
		end
		if group.moved then
			member.part.CFrame = group.base * member.rel
		end
	end
	if #group.members == 0 then
		local byName = groupsByOwner[group.owner]
		if byName ~= nil then
			byName[group.name] = nil
			if next(byName) == nil then
				groupsByOwner[group.owner] = nil
				ambienceNext[group.owner] = nil -- the model is gone: forget its ambience clock
				ownerPhases[group.owner] = nil -- ... and its shared swing phase / slot / impact flash
				ownerSlots[group.owner] = nil
				flashUntil[group.owner] = nil
			end
		end
		local sounding = table.find(soundGroups, group)
		if sounding ~= nil then
			table.remove(soundGroups, sounding)
		end
		local at = table.find(groupList, group)
		if at ~= nil then
			table.remove(groupList, at)
		end
		local active = table.find(activeGroups, group)
		if active ~= nil then
			table.remove(activeGroups, active)
		end
	elseif group.leader == member.part then
		setLeader(group, group.members[1])
	end
	refreshTimer = math.huge
end

-- Lazily builds a piece's light / steam / belt extras the first time it is near.
local function ensureExtras(member: Member)
	local fx = member.fx
	if fx == nil then
		return
	end
	local part = member.part
	local lightFx = fx.light
	if lightFx ~= nil and member.light == nil then
		local light = Instance.new("PointLight")
		light.Name = "SN_FxLight"
		light.Color = (lightFx.color or part.Color):Lerp(WARM_WHITE, LIGHT_WARMTH)
		light.Range = lightFx.range
		light.Brightness = lightFx.brightness
		light.Shadows = false
		light.Enabled = false
		light.Parent = part
		member.light = light
		member.lit = false
		member.group.extras = true
	end
	if fx.particles == "steam" and member.emitter == nil then
		local steam = WorldFxConfig.Steam
		local attachment = Instance.new("Attachment")
		attachment.Name = "SN_FxSteam"
		attachment.Position = Vector3.new(0, part.Size.Y / 2, 0)
		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = steam.texture
		emitter.Rate = steam.rate
		emitter.Lifetime = steam.lifetime
		emitter.Speed = steam.speed
		emitter.Size = steam.size
		emitter.Transparency = steam.transparency
		emitter.SpreadAngle = Vector2.new(12, 12)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.Acceleration = Vector3.new(0.6, 1.2, 0)
		emitter.RotSpeed = NumberRange.new(-20, 20)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.LightInfluence = 0.8
		emitter.Enabled = false
		emitter.Parent = attachment
		attachment.Parent = part
		member.emitter = emitter
		member.steaming = false
		member.group.extras = true
	end
	if fx.motion == "scroll" and member.belts == nil then
		-- One moving stud texture per listed face (conveyors: Top; the lava falls: Top + Front).
		local belts: { Texture } = {}
		for _, faceName in fx.faces or DEFAULT_FACES do
			local face = (Enum.NormalId :: any)[faceName]
			if typeof(face) ~= "EnumItem" then
				continue
			end
			local texture = Instance.new("Texture")
			texture.Name = "SN_FxBelt"
			texture.Texture = `rbxassetid://{WorldMaterialConfig.Images.Color}`
			texture.Face = face
			texture.StudsPerTileU = BELT_TILE
			texture.StudsPerTileV = BELT_TILE
			texture.Color3 = part.Color:Lerp(Color3.new(1, 1, 1), 0.15)
			texture.Transparency = 0.2
			texture.Parent = part
			table.insert(belts, texture)
		end
		member.belts = belts
		member.group.extras = true
	end
end

-- Nearest first (module-level comparator: no closure allocated per refresh).
local function byDistance(a: Group, b: Group): boolean
	return a.distance < b.distance
end

-- Puts every member of a group back on its authored CFrame.
local function rest(group: Group)
	if not group.moved or group.suspended then
		return -- a suspended group's pieces lie as knockdown rubble: never snap them back
	end
	for _, member in group.members do
		if member.part.Parent ~= nil then
			member.part.CFrame = group.base * member.rel
		end
	end
	group.moved = false
end

--[[
	Re-ranks groups by camera distance (every RefreshInterval, not per frame): picks the moving
	set, the nearest lights / emitters, rests groups that left the set. Budgets follow the
	device tier (WorldFxConfig.Tiers via FxQuality, owner R11).
]]
local function refresh()
	local camera = Workspace.CurrentCamera
	local cameraAt = cameraPosition()
	local still = reducedMotion()
	local budget = WorldFxConfig.Tiers[FxQuality.tier()]
	gentleMode = still
	burstScale = budget.Bursts or 0
	-- View cone for this camera (FOV / viewport rarely change; per-frame culling reuses it).
	viewCos = -1
	if camera ~= nil then
		local viewport = camera.ViewportSize
		if viewport.Y > 0 then
			viewCos = ViewCone.cosLimit(camera.FieldOfView, viewport.X / viewport.Y, WorldFxConfig.ViewMarginDeg)
		end
	end
	-- Distance from the cached group centre (the leader's authored position: no Instance reads).
	-- Out-of-range groups are settled + switched off here; only in-range groups get sorted.
	table.clear(nearGroups)
	for _, group in groupList do
		local distance = (group.base.Position - cameraAt).Magnitude
		group.distance = distance
		if distance <= budget.Range then
			table.insert(nearGroups, group)
		else
			group.active = false
			group.halfRate = false
			group.impactSlot = false
			group.impactLast = -1
			rest(group)
			if group.extras then
				for _, member in group.members do
					local light, emitter = member.light, member.emitter
					if member.lit and light ~= nil then
						member.lit = false
						light.Enabled = false
					end
					if member.steaming and emitter ~= nil then
						member.steaming = false
						emitter.Enabled = false
					end
				end
			end
		end
	end
	table.sort(nearGroups, byDistance)
	table.clear(activeGroups)
	table.clear(nearMembers)
	table.clear(soundGroups)
	table.clear(soundOwners)
	local lights, emitters, impactSlots = 0, 0, 0
	for _, group in nearGroups do
		-- Reduce Motion rests every row except swings that author a gentle sway (owner R75).
		local motion = group.fx.motion
		local moving = (not still or (motion == "swing" and group.fx.gentle ~= nil))
			and not group.suspended
			and motion ~= "none"
			and #activeGroups < budget.MaxMoving
		group.active = moving
		group.halfRate = group.distance > budget.HalfRateBeyond
		group.impactSlot = false
		if moving then
			table.insert(activeGroups, group)
		else
			group.impactLast = -1
			rest(group)
		end
		for _, member in group.members do
			ensureExtras(member)
			local light = member.light
			if light ~= nil then
				local on = lights < budget.MaxLights
				lights += if on then 1 else 0
				if member.lit ~= on then
					member.lit = on
					light.Enabled = on
				end
			end
			local emitter = member.emitter
			if emitter ~= nil then
				local on = emitters < budget.MaxEmitters
				emitters += if on then 1 else 0
				if member.steaming ~= on then
					member.steaming = on
					emitter.Enabled = on
				end
			end
			if light ~= nil or member.belts ~= nil then
				table.insert(nearMembers, member)
			end
		end
		-- Sound sources, nearest first within the tier budget: a moving periodic row in its range,
		-- or the first group of an ambience model in its range (one slot per model).
		if #soundGroups + impactSlots < budget.MaxSounds then
			local rowSound = group.fx.sound
			local ambience = group.ambience
			local impact = group.fx.impact
			local impactSound = if impact ~= nil then impact.sound else nil
			if rowSound ~= nil and moving and group.distance <= rowSound.range then
				table.insert(soundGroups, group)
			elseif
				impactSound ~= nil
				and moving
				and not still
				and burstScale > 0
				and group.distance <= impactSound.range
			then
				-- A swing's strike sound (owner R75): one slot per striking group, Low tier none.
				group.impactSlot = true
				impactSlots += 1
			elseif ambience ~= nil and not soundOwners[group.owner] and group.distance <= ambience.range then
				soundOwners[group.owner] = true
				table.insert(soundGroups, group)
			end
		end
	end
	-- Groups that lost their slot must not replay their last fraction when they come back.
	for _, group in groupList do
		if group.soundAt >= 0 and table.find(soundGroups, group) == nil then
			group.soundAt = -1
		end
	end
end

--[[
	Plays the sound slots of this frame (refresh picked them): a periodic row's sound once per
	period as the cycle passes `sound.at`, an ambience model's sound when its jittered timer is up.
	@param t controller time (os.clock() - clockStart), the same clock the motions use
]]
local function playSounds(t: number)
	local now = os.clock()
	for _, group in soundGroups do
		local rowSound = group.fx.sound
		if rowSound ~= nil and group.active then
			local period = group.fx.period or 2
			local fraction = ((t + group.phase) / period) % 1
			local last = group.soundAt
			group.soundAt = fraction
			-- Crossed `at` since the last frame (wrapping at 1); the first frame only arms it.
			local crossed = last >= 0
				and (
					(last <= fraction and last < rowSound.at and fraction >= rowSound.at)
					or (last > fraction and (rowSound.at > last or rowSound.at <= fraction))
				)
			if crossed then
				FxSound.play(rowSound.key, group.base.Position, { volume = rowSound.volume })
			end
		else
			local ambience = group.ambience
			if ambience ~= nil then
				local due = ambienceNext[group.owner]
				if due == nil then
					-- First time near: start somewhere inside the first interval (no sound on join).
					ambienceNext[group.owner] = now + random:NextNumber(0.3, 1) * ambience.interval
				elseif now >= due then
					ambienceNext[group.owner] = now
						+ ambience.interval
						+ random:NextNumber(-ambience.jitter, ambience.jitter)
					FxSound.play(ambience.key, group.base.Position, { volume = ambience.volume })
				end
			end
		end
	end
end

--[[
	The leader's CFrame turned `degrees` about the group's axis: about the world hinge (owner R75,
	Assembly.hinge; axis in the model frame) or, with no hinge, about the leader's own box centre
	on its own axis (every pre-R75 row).
]]
local function turned(group: Group, degrees: number): CFrame
	local hinge = group.hinge
	if hinge ~= nil then
		return CFrame.new(hinge)
			* CFrame.fromAxisAngle(group.hingeAxis, math.rad(degrees))
			* CFrame.new(-hinge)
			* group.base
	end
	return group.base * CFrame.fromAxisAngle(group.axis, math.rad(degrees))
end

-- The group's leader CFrame at time t (nil = no motion).
local function motionCFrame(group: Group, t: number): CFrame?
	local fx = group.fx
	local motion = fx.motion
	if motion == "spin" then
		return turned(group, (fx.speed or 90) * (t + group.phase))
	elseif motion == "oscillate" then
		local period = fx.period or 3
		return turned(group, (fx.amplitude or 20) * math.sin(2 * math.pi * (t + group.phase) / period))
	elseif motion == "swing" then
		-- Owner R75: keyframed loop, or the gentle sway under Reduce Motion.
		local gentle = fx.gentle
		if gentleMode and gentle ~= nil then
			return turned(group, SwingCurve.gentleAngle(gentle, t + group.phase))
		end
		return turned(group, SwingCurve.angle(fx.keys or NO_KEYS, (t + group.phase) / (fx.period or 2)))
	elseif motion == "bob" then
		local period = fx.period or 2
		local offset = (fx.amplitude or 0.25) * math.sin(2 * math.pi * (t + group.phase) / period)
		return group.base + Vector3.new(0, offset, 0)
	end
	return nil
end

--------------------------------------------------------------------------------------------------
-- Pads, purchases, fanfare
--------------------------------------------------------------------------------------------------

local function squishPad(model: Model)
	local parts: { BasePart } = {}
	local bases: { CFrame } = {}
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") and item.Transparency < 1 then
			table.insert(parts, item)
			table.insert(bases, item.CFrame)
		end
	end
	if #parts > 0 and not reducedMotion() then
		table.insert(squishes, { parts = parts, bases = bases, t0 = os.clock() })
	end
end

local function onPadAdded(model: Model)
	model:GetAttributeChangedSignal(WorldFxConfig.PadPressedAttribute):Connect(function()
		local stamp = model:GetAttribute(WorldFxConfig.PadPressedAttribute)
		if type(stamp) ~= "number" or Workspace:GetServerTimeNow() - stamp > BuildInConfig.FreshWindow then
			return
		end
		local padId = model:GetAttribute("PadId")
		if type(padId) == "string" then
			pressedAt[plotKey(model, padId)] = os.clock()
		end
		local position = model:GetPivot().Position
		if (position - cameraPosition()).Magnitude > BuildInConfig.Tiers[FxQuality.tier()].LightRange then
			return
		end
		squishPad(model)
		-- R71: the layered ForgeGUI "pad_buy" (pop + coins + shimmer) replaces the plain "pop".
		FxSound.play("pad_buy", position)
		FxSound.play("kaching", position + Vector3.new(0, 2, 0))
		WorldFxController.PadPressed:Fire(model, position)
	end)
end

-- Fallback ka-ching when the server destroyed the pad without a PressedAt (no squish possible).
local function onBuildAdded(model: Model, info: PlotWatcher.BuildInfo)
	local padId = info.padId
	if padId == nil or info.age > BuildInConfig.FreshWindow then
		return
	end
	local key = plotKey(model, padId)
	task.delay(0.3, function()
		if os.clock() - (pressedAt[key] or -math.huge) < 3 or model.Parent == nil then
			return
		end
		local position = model:GetPivot().Position
		if (position - cameraPosition()).Magnitude <= BuildInConfig.Tiers[FxQuality.tier()].LightRange then
			FxSound.play("kaching", position + Vector3.new(0, 2, 0))
		end
	end)
end

-- Area unlock fanfare once the new area's base finished building in.
local function onBuildFinished(model: Model, info: PlotWatcher.BuildInfo)
	if not info.isAreaBase or info.age > BuildInConfig.FreshWindow then
		return
	end
	local ok, boxCf, boxSize = pcall(function()
		return model:GetBoundingBox()
	end)
	local top = if ok then boxCf.Position + Vector3.new(0, boxSize.Y / 2 + 3, 0) else model:GetPivot().Position
	FxSound.play("fanfare", top)
	if not reducedMotion() then
		local scale = BuildInConfig.Tiers[FxQuality.tier()].ConfettiScale
		local confetti = math.floor(BuildInConfig.Confetti * scale)
		local sparkle = math.floor(BuildInConfig.Sparkle * scale)
		Confetti.burst(top, confetti * 2, sparkle * 2)
		task.delay(0.35, function()
			Confetti.burst(top + Vector3.new(0, 4, 0), confetti, sparkle)
		end)
	end
end

--[[
	A swing's impact (owner R75: a pick strike): the pooled burst at the impact point, its sound
	when refresh gave the group a sound slot, and the owner's glow flash. Callers only fire while
	on screen; here the range + tier gates apply (Low tier: Bursts 0 = swing only).
]]
local function fireImpact(group: Group, impact: WorldFxConfig.ImpactFx, now: number)
	if burstScale <= 0 or group.distance > impact.range then
		return
	end
	local point = group.impactPoint or group.base.Position
	if impact.burst ~= nil then
		ImpactBursts.burst(impact.burst, point, burstScale)
	end
	local sound = impact.sound
	if sound ~= nil and group.impactSlot then
		FxSound.play(sound.key, point, { volume = sound.volume, pitch = sound.pitch })
	end
	if impact.flash ~= nil then
		flashUntil[group.owner] = now + impact.flash
	end
end

--------------------------------------------------------------------------------------------------
-- Frame loop
--------------------------------------------------------------------------------------------------

local function step(dt: number)
	refreshTimer += dt
	if refreshTimer >= WorldFxConfig.RefreshInterval then
		refreshTimer = 0
		refresh()
	end
	local now = os.clock()
	local t = now - clockStart
	table.clear(movedParts)
	table.clear(movedFrames)
	frameCount += 1
	local camera = Workspace.CurrentCamera
	local cameraFrame = if camera ~= nil then camera.CFrame else CFrame.identity
	local cameraAt, look = cameraFrame.Position, cameraFrame.LookVector
	local near = WorldFxConfig.AlwaysMoveWithin
	-- One motion CFrame per moving group; every member follows it with its own offset. Far
	-- groups skip alternate frames; groups outside the view cone hold their pose this frame.
	for _, group in activeGroups do
		-- Owner R75: a swing's impact is tracked every frame (never missed on a half-rate skip) and
		-- fires only on screen; Reduce Motion disarms it.
		local impact = group.fx.impact
		if impact ~= nil then
			if gentleMode then
				group.impactLast = -1
			else
				local fraction = ((t + group.phase) / (group.fx.period or 2)) % 1
				if
					SwingCurve.crossed(group.impactLast, fraction, impact.at)
					and ViewCone.visible(group.base.Position - cameraAt, look, viewCos, near)
				then
					fireImpact(group, impact, now)
				end
				group.impactLast = fraction
			end
		end
		if group.halfRate and (frameCount + group.slot) % 2 ~= 0 then
			continue
		end
		if not ViewCone.visible(group.base.Position - cameraAt, look, viewCos, near) then
			continue
		end
		local cf = motionCFrame(group, t)
		-- A follower (the pick arm) rides its parent group's motion (the body lean) on top of its own.
		local followName = group.followName
		if cf ~= nil and followName ~= nil then
			local byName = groupsByOwner[group.owner]
			local parent = if byName ~= nil then byName[followName] else nil
			if parent ~= nil and parent.active then
				local parentCf = motionCFrame(parent, t)
				if parentCf ~= nil then
					cf = parentCf * parent.base:Inverse() * cf
				end
			end
		end
		if cf ~= nil then
			for _, member in group.members do
				if member.part.Parent ~= nil then
					table.insert(movedParts, member.part)
					table.insert(movedFrames, cf * member.rel)
				end
			end
			group.moved = true
		end
	end
	for _, member in nearMembers do
		local light = member.light
		local lightFx = member.fx and member.fx.light
		if light ~= nil and lightFx ~= nil and member.lit then
			local pulse = lightFx.pulse or 0
			-- Smooth pulse, or a noisy flame flicker (math.noise is ~[-0.5, 0.5], so x2), both
			-- bounded by `pulse` (glow caps, R19). An impact flash (owner R75) holds the top of the
			-- same range briefly, so it never exceeds the caps.
			local flash = flashUntil[member.group.owner]
			local wave = if flash ~= nil and now < flash
				then 1
				elseif lightFx.flicker then math.clamp(2 * math.noise(t * 7, member.group.phase * 13.1, 0), -1, 1)
				else math.sin(2 * math.pi * (t + member.group.phase) / 1.7)
			light.Brightness = lightFx.brightness * (1 + pulse * wave)
		end
		local belts = member.belts
		-- Belts scroll only on screen (a texture offset write per belt per frame otherwise).
		if
			belts ~= nil
			and member.fx ~= nil
			and ViewCone.visible(member.group.base.Position - cameraAt, look, viewCos, near)
		then
			local offset = ((member.fx.speed or 3) * t) % BELT_TILE
			for _, belt in belts do
				belt.OffsetStudsV = offset
			end
		end
	end
	if #soundGroups > 0 then
		playSounds(t)
	end
	-- Pad squishes: sink, then spring back with a little overshoot.
	local cfg = WorldFxConfig.PadSquish
	for i = #squishes, 1, -1 do
		local squish = squishes[i]
		local u = math.clamp((now - squish.t0) / cfg.Duration, 0, 1)
		local dip = -cfg.Depth * math.sin(math.pi * u) * (1 - 0.35 * u)
		for k, part in squish.parts do
			if part.Parent ~= nil then
				table.insert(movedParts, part)
				table.insert(movedFrames, squish.bases[k] + Vector3.new(0, if u >= 1 then 0 else dip, 0))
			end
		end
		if u >= 1 then
			table.remove(squishes, i)
		end
	end
	if #movedParts > 0 then
		Workspace:BulkMoveTo(movedParts, movedFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function WorldFxController.Init() end

--[[
	Knockdown (owner R50, Tycoon/BuildIn/KnockdownFx): freezes (on) / releases (off) every motion
	group under `root` (a knocked-down area's Builds folder). A suspended group never moves and is
	never rest()-snapped, so the toppled pieces stay where KnockdownFx put them; lights and belts
	keep running. Off → the groups re-join the next ranking (KnockdownFx restored their CFrames).
	Example: WorldFxController.setSuspended(area.Builds, true)
]]
function WorldFxController.setSuspended(root: Instance, on: boolean)
	suspendedRoots[root] = if on then true else nil
	for _, group in groupList do
		local owner = group.owner
		if owner == root or owner:IsDescendantOf(root) then
			group.suspended = on
			if on then
				group.active = false
				group.moved = false -- KnockdownFx moves the pieces now; nothing to rest later
				local index = table.find(activeGroups, group)
				if index ~= nil then
					table.remove(activeGroups, index)
				end
			end
		end
	end
	refreshTimer = math.huge -- re-rank on the next frame
end

-- Subscribes to tags, PlotWatcher and BuildIn, then runs the single frame loop (idempotent).
function WorldFxController.Start()
	if started then
		return
	end
	started = true
	CollectionService:GetInstanceAddedSignal(WorldFxConfig.Tag):Connect(register)
	CollectionService:GetInstanceRemovedSignal(WorldFxConfig.Tag):Connect(unregister)
	for _, instance in CollectionService:GetTagged(WorldFxConfig.Tag) do
		register(instance)
	end
	PlotWatcher.PadAdded:Connect(onPadAdded)
	PlotWatcher.BuildAdded:Connect(onBuildAdded)
	BuildInController.BuildFinished:Connect(onBuildFinished)
	PlotWatcher.start()
	RunService.Heartbeat:Connect(step)
end

-- Debug / verification counters (groups = motion groups, tagged = pieces).
function WorldFxController.stats(): { tagged: number, groups: number, active: number, squishing: number }
	local tagged = 0
	for _ in members do
		tagged += 1
	end
	return { tagged = tagged, groups = #groupList, active = #activeGroups, squishing = #squishes }
end

return WorldFxController
