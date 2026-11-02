--!strict
--[[
	TowerAnim — every AA tower comes alive (owner R106: "the AA towers should aniamte around";
	screenshot: Back Tower Lv 4/5 standing still).

	What moves (client-side only; the server's tower models never change):
		* idle — the turret sweeps / scans left and right (two sines, a per-tower phase so towers
		  never move in lockstep), the barrels bob up and down, the radar dish (TurretDish) spins;
		* engaging — while FlightRenderer aims a tower at a nuke (`aim`, every frame of the
		  engagement) the turret slews onto it fast (AimFollow) and the dish spins faster; when the
		  engagement ends it eases back into its scan (IdleFollow);
		* firing — `fire` (FlightRenderer, the moment each interceptor leaves) kicks the barrels back
		  along their axis + up and flashes a pooled muzzle flash (neon ball + light) at the barrel tip.
	Pieces: Shared/Attack/TowerAnimMath.classify (Turret* yaw, TurretDish yaw + spin, Barrel* pitch +
	recoil); joints from AttackConfig.TowerAnim.Joints (the Blender builders' notes), the primitive
	fallback turret pitches about its Turret part (BarrelPitch attribute = its resting elevation).

	Rules: ONE PreRender connection for every tower (alive only while towers exist), all parts move
	with ONE Workspace:BulkMoveTo per frame; idle animation only within AttackConfig.TowerAnim.Cull
	[FxQuality tier] studs of the camera (Low tier: off), beyond HalfRateBeyond at half rate;
	Reduce Motion (OfferFx.reducedMotion: the SellNukes setting or the OS one) turns idle sweep, dish
	and recoil off and eases every tower back to rest (engagement aim stays: gameplay readability);
	a freshly bought tower holds still for BuildInHold seconds (its LEGO fly-in); no per-frame
	Instance.new (muzzle flashes are a fixed pool created on the first shot seen).

	Connects to: Shared/Attack/TowerAnimMath, Shared/Config/{AttackConfig, BuildInConfig},
	Tycoon/Fx/FxQuality, UI/Widgets/OfferFx; Client/Attack/FlightRenderer (aim / fire),
	Client/Attack/AttackClient (start). Server/Attack/AttackWorld tags every tower model
	AttackConfig.Tags.Turret with Plot / Tower / Level attributes.

	Example:
		TowerAnim.start()
		TowerAnim.aim(plot, 0, nukePosition)  -- each frame while the HQ tower engages
		TowerAnim.fire(plot, 0)               -- an interceptor left the HQ tower
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local BuildInConfig = require(ReplicatedStorage.Shared.Config.BuildInConfig)
local FxQuality = require(script.Parent.Parent.Tycoon.Fx.FxQuality)
local OfferFx = require(script.Parent.Parent.UI.Widgets.OfferFx)
local TowerAnimMath = require(ReplicatedStorage.Shared.Attack.TowerAnimMath)

local TowerAnim = {}

local ANIM = AttackConfig.TowerAnim
local PARK = CFrame.new(0, -4000, 0)
-- Engaged-pitch clamp relative to the resting elevation (radians), as the old FlightRenderer aim.
local TILT_MIN, TILT_MAX = -0.6, 1.4
-- Pose error below which a returning tower snaps to its exact rest pose and stops updating.
local REST_EPSILON = 0.002

type Rig = {
	model: Model,
	key: number,
	mount: CFrame, -- model pivot (ground centre, faces -Z at rest)
	yawPivot: Vector3, -- mount space: the turret's vertical axis passes through it
	hinge: Vector3, -- mount space: the barrels pitch about +X through it
	basePitch: number, -- resting barrel elevation (radians; 0 for meshes)
	scale: number, -- recoil / flash scale by level
	yawParts: { BasePart },
	yawBase: { CFrame }, -- rest CFrames (mount space)
	pitchParts: { BasePart },
	pitchBase: { CFrame },
	dishParts: { BasePart },
	dishBase: { CFrame },
	tip: BasePart?, -- muzzle reference (BarrelTip, else Barrel)
	phase: number,
	yaw: number, -- current turret yaw (radians)
	pitch: number, -- current absolute barrel elevation (radians)
	dish: number, -- current dish spin angle
	aimYaw: number,
	aimPitch: number,
	engagedUntil: number, -- os.clock()
	firedAt: number, -- os.clock() of the last shot
	readyAt: number, -- os.clock() before which an idle tower holds still (fly-in)
	lastStep: number, -- os.clock() of its last pose update
	posed: boolean, -- displaced from rest (a return is due when idling stops)
}

type Flash = { part: Part, light: PointLight, untilTime: number }

local rigs: { [number]: Rig } = {}
local rigCount = 0
local connection: RBXScriptConnection? = nil
local started = false
local frame = 0
local flashes: { Flash } = {}
local nextFlash = 1
local activeFlashes = 0
local moveParts: { BasePart } = {}
local moveFrames: { CFrame } = {}

-- The rig key of a target slot's tower (tower 0 = HQ / rival / bot turret).
local function rigKey(plot: number, tower: number): number
	return plot * 32 + tower
end

-- A finite attribute number, else `fallback`.
local function attr(instance: Instance, name: string, fallback: number): number
	local value = instance:GetAttribute(name)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

-- Builds a rig for a tagged tower model (nil when it has no moving pieces).
local function buildRig(model: Model, plot: number, tower: number): Rig?
	local mount = model:GetPivot()
	local level = math.clamp(math.floor(attr(model, "Level", 1)), 1, #ANIM.Joints)
	local yawPivot, hinge = TowerAnimMath.joints(level)
	local basePitch = 0
	local fallbackPitch = model:GetAttribute("BarrelPitch")
	local rig: Rig = {
		model = model,
		key = rigKey(plot, tower),
		mount = mount,
		yawPivot = yawPivot,
		hinge = hinge,
		basePitch = 0,
		scale = 1 + (level - 1) * 0.15,
		yawParts = {},
		yawBase = {},
		pitchParts = {},
		pitchBase = {},
		dishParts = {},
		dishBase = {},
		tip = nil,
		phase = TowerAnimMath.phase(plot, tower),
		yaw = 0,
		pitch = 0,
		dish = 0,
		aimYaw = 0,
		aimPitch = 0,
		engagedUntil = 0,
		firedAt = -math.huge,
		readyAt = 0,
		lastStep = os.clock(),
		posed = false,
	}
	local barrel: BasePart? = nil
	for _, child in model:GetChildren() do
		if not child:IsA("BasePart") then
			continue
		end
		local group = TowerAnimMath.classify(child.Name)
		local base = mount:ToObjectSpace(child.CFrame)
		if group == "yaw" then
			table.insert(rig.yawParts, child)
			table.insert(rig.yawBase, base)
			if child.Name == "Turret" and type(fallbackPitch) == "number" then
				-- Primitive fallback turret: no joint notes — pivot at the model centre line, pitch
				-- about the Turret part (as the old FlightRenderer aim did).
				rig.yawPivot = Vector3.zero
				rig.hinge = base.Position
			end
		elseif group == "dish" then
			table.insert(rig.dishParts, child)
			table.insert(rig.dishBase, base)
		elseif group == "pitch" then
			table.insert(rig.pitchParts, child)
			table.insert(rig.pitchBase, base)
			if child.Name == "BarrelTip" then
				rig.tip = child
			elseif child.Name == "Barrel" then
				barrel = child
			end
		end
	end
	if rig.tip == nil then
		rig.tip = barrel
	end
	if type(fallbackPitch) == "number" and fallbackPitch == fallbackPitch then
		basePitch = math.rad(fallbackPitch)
	end
	rig.basePitch = basePitch
	rig.pitch = basePitch
	if #rig.yawParts + #rig.pitchParts + #rig.dishParts == 0 then
		return nil
	end
	-- A fresh purchase flies in (BuildIn ghosts land on the rest pose): hold still meanwhile.
	local stamp = model:GetAttribute(BuildInConfig.TimeAttribute)
	if type(stamp) == "number" then
		local age = Workspace:GetServerTimeNow() - stamp
		if age < ANIM.BuildInHold then
			rig.readyAt = os.clock() + (ANIM.BuildInHold - age)
		end
	end
	return rig
end

-- Queues one rig's pose for this frame's BulkMoveTo.
local function pose(rig: Rig, recoil: number)
	local pivot = rig.yawPivot
	local yawCf = CFrame.new(pivot.X, 0, pivot.Z) * CFrame.Angles(0, rig.yaw, 0) * CFrame.new(-pivot.X, 0, -pivot.Z)
	local turretFrame = rig.mount * yawCf
	for index, part in rig.yawParts do
		table.insert(moveParts, part)
		table.insert(moveFrames, turretFrame * rig.yawBase[index])
	end
	if #rig.dishParts > 0 then
		local spin = CFrame.Angles(0, rig.dish, 0)
		for index, part in rig.dishParts do
			local base = rig.dishBase[index]
			local centre = CFrame.new(base.Position)
			table.insert(moveParts, part)
			table.insert(moveFrames, turretFrame * centre * spin * centre:Inverse() * base)
		end
	end
	if #rig.pitchParts > 0 then
		local hinge = CFrame.new(rig.hinge)
		local kick = math.rad(ANIM.RecoilKickDegrees) * recoil
		local tilt = math.clamp(rig.pitch - rig.basePitch + kick, TILT_MIN, TILT_MAX)
		-- Recoil slides along the (tilted) barrel axis: barrels point -Z, so back = +Z.
		local barrelFrame = turretFrame
			* hinge
			* CFrame.Angles(tilt, 0, 0)
			* hinge:Inverse()
			* CFrame.new(0, 0, ANIM.RecoilStuds * rig.scale * recoil)
		for index, part in rig.pitchParts do
			table.insert(moveParts, part)
			table.insert(moveFrames, barrelFrame * rig.pitchBase[index])
		end
	end
end

-- Parks a flash (invisible, light off, far below the map).
local function park(flash: Flash)
	flash.part.Transparency = 1
	flash.part.CFrame = PARK
	flash.light.Enabled = false
end

-- The flash pool (created once, on the first shot this client draws).
local function flashPool(): { Flash }
	if #flashes > 0 then
		return flashes
	end
	local folder = Instance.new("Folder")
	folder.Name = "SN_TowerFx"
	for _ = 1, ANIM.FlashPool do
		local part = Instance.new("Part")
		part.Name = "MuzzleFlash"
		part.Shape = Enum.PartType.Ball
		part.Material = Enum.Material.Neon
		part.Color = ANIM.FlashColor
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Size = Vector3.one * ANIM.FlashSize
		local light = Instance.new("PointLight")
		light.Color = ANIM.FlashColor
		light.Range = 14
		light.Brightness = 4
		light.Shadows = false
		light.Parent = part
		local flash: Flash = { part = part, light = light, untilTime = 0 }
		park(flash)
		part.Parent = folder
		table.insert(flashes, flash)
	end
	folder.Parent = Workspace
	return flashes
end

-- Shows a muzzle flash at a rig's barrel tip (pooled ring; the oldest flash is reused).
local function flashAt(rig: Rig)
	local tip = rig.tip
	if tip == nil or tip.Parent == nil then
		return
	end
	local pool = flashPool()
	local flash = pool[nextFlash]
	nextFlash = nextFlash % #pool + 1
	if flash.untilTime <= os.clock() then
		activeFlashes += 1
	end
	local muzzle = tip.CFrame * CFrame.new(0, 0, -tip.Size.Z / 2)
	flash.part.Size = Vector3.one * ANIM.FlashSize * rig.scale
	flash.part.CFrame = CFrame.new(muzzle.Position)
	flash.part.Transparency = 0.1
	-- Lights only above the Low tier (they cost the most on phones).
	flash.light.Enabled = FxQuality.tier() ~= "Low"
	flash.untilTime = os.clock() + ANIM.FlashSeconds
end

-- Fades / parks the live flashes (touches only active ones).
local function stepFlashes(now: number)
	if activeFlashes <= 0 then
		return
	end
	local live = 0
	for _, flash in flashes do
		if flash.untilTime > 0 then
			local left = flash.untilTime - now
			if left <= 0 then
				flash.untilTime = 0
				park(flash)
			else
				live += 1
				flash.part.Transparency = 1 - 0.9 * (left / ANIM.FlashSeconds)
			end
		end
	end
	activeFlashes = live
end

-- The one per-frame body: pose every tower that should move this frame.
local function step()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	frame += 1
	local now = os.clock()
	local eye = camera.CFrame.Position
	local reduced = OfferFx.reducedMotion()
	local cull = if reduced then 0 else TowerAnimMath.cullDistance(FxQuality.tier())
	table.clear(moveParts)
	table.clear(moveFrames)
	for _, rig in rigs do
		if rig.model.Parent == nil then
			continue
		end
		local engaged = now < rig.engagedUntil
		local sinceShot = now - rig.firedAt
		local recoiling = not reduced and sinceShot < ANIM.RecoilSeconds
		local distance = (rig.mount.Position - eye).Magnitude
		local idling = false
		if engaged or recoiling then
			if distance > ANIM.AimDistance then
				continue
			end
		else
			if now < rig.readyAt then
				continue
			end
			idling = cull > 0 and distance <= cull
			if not idling then
				-- Out of idle range (or idle off): ease a displaced tower home while it is in view
				-- range, otherwise leave it (nobody sees it).
				if not rig.posed or distance > math.max(cull, ANIM.HalfRateBeyond) then
					rig.lastStep = now
					continue
				end
			elseif distance > ANIM.HalfRateBeyond and (frame + rig.key) % 2 == 1 then
				continue
			end
		end
		local dt = math.min(now - rig.lastStep, 0.25)
		rig.lastStep = now
		local targetYaw: number, targetPitch: number, rate: number
		if engaged then
			targetYaw, targetPitch, rate = rig.aimYaw, rig.aimPitch, ANIM.AimFollow
		elseif idling then
			targetYaw = TowerAnimMath.idleYaw(now, rig.phase)
			targetPitch = TowerAnimMath.idlePitch(now, rig.phase)
			rate = ANIM.IdleFollow
		else
			targetYaw, targetPitch, rate = 0, rig.basePitch, ANIM.IdleFollow
		end
		rig.yaw = TowerAnimMath.follow(rig.yaw, targetYaw, rate, dt)
		rig.pitch += (targetPitch - rig.pitch) * (1 - math.exp(-rate * dt))
		if not reduced and (idling or engaged) then
			rig.dish = (rig.dish + (if engaged then ANIM.DishEngagedSpeed else ANIM.DishSpeed) * dt) % (2 * math.pi)
		elseif rig.dish ~= 0 then
			rig.dish = TowerAnimMath.follow(rig.dish, 0, rate, dt)
		end
		local recoil = if reduced then 0 else TowerAnimMath.recoil(sinceShot)
		if
			not engaged
			and not idling
			and recoil == 0
			and math.abs(TowerAnimMath.wrap(rig.yaw)) < REST_EPSILON
			and math.abs(rig.pitch - rig.basePitch) < REST_EPSILON
			and math.abs(TowerAnimMath.wrap(rig.dish)) < REST_EPSILON
		then
			-- Home: write the exact rest pose once and stop updating.
			rig.yaw, rig.pitch, rig.dish = 0, rig.basePitch, 0
			rig.posed = false
		else
			rig.posed = true
		end
		pose(rig, recoil)
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	stepFlashes(now)
	-- Nothing left to animate (every tower streamed out, last flash faded): stop the loop.
	if rigCount <= 0 and activeFlashes <= 0 and connection ~= nil then
		connection:Disconnect()
		connection = nil
	end
end

-- Adds a tagged tower (any plot, Rival island or bot). A replacement model (upgrade) wins.
local function add(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local plot = attr(instance, "Plot", 0)
	local tower = attr(instance, "Tower", 0)
	if plot < 1 or plot % 1 ~= 0 or tower < 0 or tower >= 32 or tower % 1 ~= 0 then
		return
	end
	local rig = buildRig(instance, plot, tower)
	if rig == nil then
		return
	end
	if rigs[rig.key] == nil then
		rigCount += 1
	end
	rigs[rig.key] = rig
	if connection == nil then
		connection = RunService.PreRender:Connect(step)
	end
end

-- Removes a tower's rig (only if that model still owns the key) and stops the loop when empty.
local function remove(instance: Instance)
	for key, rig in rigs do
		if rig.model == instance then
			rigs[key] = nil
			rigCount -= 1
		end
	end
	if rigCount <= 0 and connection ~= nil and activeFlashes <= 0 then
		connection:Disconnect()
		connection = nil
	end
end

--[[
	Points a tower at a world point for this frame (FlightRenderer calls it every frame of an
	engagement); the tower slews there and stays engaged for EngageHold seconds after the last call.
	@param plot number — target slot
	@param tower number — 0 = HQ / rival / bot turret, 1.. = defence slot
	@param at Vector3 — the nuke's position
]]
function TowerAnim.aim(plot: number, tower: number, at: Vector3)
	local rig = rigs[rigKey(plot, tower)]
	if rig == nil or rig.model.Parent == nil then
		return
	end
	local yaw, pitch = TowerAnimMath.aim(rig.mount:PointToObjectSpace(at) - rig.hinge)
	if os.clock() >= rig.engagedUntil then
		-- Engagement starts: take the shortest way from the current scan pose.
		rig.lastStep = os.clock()
	end
	rig.aimYaw, rig.aimPitch = yaw, pitch
	rig.engagedUntil = os.clock() + ANIM.EngageHold
end

--[[
	A shot left a tower (FlightRenderer, the moment an interceptor fires): barrel recoil + muzzle
	flash (only when the camera is within AimDistance).
	@param plot number — target slot
	@param tower number
]]
function TowerAnim.fire(plot: number, tower: number)
	local rig = rigs[rigKey(plot, tower)]
	local camera = Workspace.CurrentCamera
	if rig == nil or rig.model.Parent == nil or camera == nil then
		return
	end
	if (rig.mount.Position - camera.CFrame.Position).Magnitude > ANIM.AimDistance then
		return
	end
	rig.firedAt = os.clock()
	flashAt(rig)
	if connection == nil then
		connection = RunService.PreRender:Connect(step)
	end
end

--[[ Diagnostics (QA tools/qa/attack_view.py): towers tracked, posed this session, flashes live. ]]
function TowerAnim.stats(): { [string]: any }
	local posed, engaged = 0, 0
	local now = os.clock()
	for _, rig in rigs do
		if rig.posed then
			posed += 1
		end
		if now < rig.engagedUntil then
			engaged += 1
		end
	end
	return {
		rigs = rigCount,
		posed = posed,
		engaged = engaged,
		flashes = activeFlashes,
		running = connection ~= nil,
		tier = FxQuality.tier(),
		reduced = OfferFx.reducedMotion(),
	}
end

--[[ One tower's current pose (QA): yaw / pitch / dish radians, nil when not tracked. ]]
function TowerAnim.poseOf(plot: number, tower: number): { [string]: number }?
	local rig = rigs[rigKey(plot, tower)]
	if rig == nil then
		return nil
	end
	return {
		yaw = rig.yaw,
		pitch = rig.pitch,
		dish = rig.dish,
		parts = #rig.yawParts + #rig.pitchParts + #rig.dishParts,
	}
end

--[[ Starts tracking every tagged tower (idempotent; AttackClient.start). ]]
function TowerAnim.start()
	if started then
		return
	end
	started = true
	CollectionService:GetInstanceAddedSignal(AttackConfig.Tags.Turret):Connect(add)
	CollectionService:GetInstanceRemovedSignal(AttackConfig.Tags.Turret):Connect(remove)
	for _, instance in CollectionService:GetTagged(AttackConfig.Tags.Turret) do
		add(instance)
	end
end

return TowerAnim
