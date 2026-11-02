--!strict
--[[
	Animated manager NPC regressions (owner R30, N1). Run:
		lune run tests/npc-logic

	Loads the REAL modules (src/shared/Config/ManagerNpcConfig.luau, src/client/Tycoon/Npc/
	NpcBrain.luau, src/client/Tycoon/Npc/NpcPose.luau, src/shared/Config/MeshAssets.luau) with
	Roblox datatypes injected from @lune/roblox, and proves:
	  1. ManagerKeys = the ten Manager pads' build keys; ownsModel accepts the key and the spawned
	     "<key>_<n>" name only; groupOf reads the leading rig word and leaves props static.
	  2. Every rig row is complete and sane: style / arms / action enums, joints for every group
	     its meshes use, waypoint 1 = figure.base, every stop within 8 studs of home, a work stop,
	     valid facings.
	  3. Rig vs meshes (MeshAssets): Biped managers have both legs, Hover managers none, every
	     group has pieces + a joint, each joint sits inside its group's (padded) piece bounds,
	     the held prop / torso split leaves <= 24 pieces, and every piece has an uploaded mesh id.
	  4. NpcBrain over 2 simulated minutes per manager: visits every stop in order, stays near
	     home, never turns faster than TurnSpeed, beats only while working and never faster than
	     MinBeatInterval, follows the producer cycle (synced) or the fallback cadence (unsynced),
	     waves once per owner arrival (cooldown), hops on request, reduced motion = home + idle,
	     a frame hitch never teleports.
	  5. NpcPose: walk swing (arms against legs), wave arm raised on the correct side, the hammer
	     curve (wind-up, strike, rest), every value finite.
	  6. Worlds (owner R57 Dino, R70 Moon; W10): WorldManagerKeys.main IS ManagerKeys; every other
	     world's list (iterated from WorldManagerKeys, so a new world needs no test edit) matches
	     its Areas/AreaNN Manager pad build keys in area order once those configs exist; keys are
	     unique across worlds and accepted by ownsModel; rig `world` fields match; a listed key may
	     lack a rig ONLY while its model has no art (MeshAssets) — worlds land in waves; Dino is
	     complete (6 rigs). Every rigged non-main manager's loop (stops + the walked segments)
	     stays inside its slot, keeps >= 1.3 studs from every collision box of its world's AreaNN
	     layout (its own figure / tail boxes aside) and >= 1.35 from the producer click box.
	Checks 2-4 run for EVERY world's rigged managers.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(label, 2)
	end
	checks += 1
end

local function load(path: string): any
	local env = {
		Vector3 = roblox.Vector3,
		Color3 = roblox.Color3,
		Enum = roblox.Enum,
		string = string,
		table = table,
		math = math,
		type = type,
		error = error,
	}
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

local Config = load("src/shared/Config/ManagerNpcConfig.luau")
local NpcBrain = load("src/client/Tycoon/Npc/NpcBrain.luau")
local NpcPose = load("src/client/Tycoon/Npc/NpcPose.luau")
local MeshAssets = load("src/shared/Config/MeshAssets.luau")
local Motion = Config.Motion

local function finite(x: number): boolean
	return x == x and x > -math.huge and x < math.huge
end

-- 1. Keys, ownsModel, groupOf -------------------------------------------------------------------
local padBuilds: { [string]: boolean } = {}
for area = 1, 10 do
	local source = fs.readFile(string.format("src/shared/Config/TycoonAreas/Area%02d.luau", area))
	-- Each Manager pad block: kind = "Manager" ... build = "<key>".
	for block in string.gmatch(source, 'kind = "Manager",(.-)}') do
		local key = string.match(block, 'build = "([%w_]+)"')
		if key ~= nil then
			padBuilds[key] = true
		end
	end
end
ok(#Config.ManagerKeys == 10, "ten manager keys")
for _, key in Config.ManagerKeys do
	ok(padBuilds[key], `{key}: is a Manager pad build key`)
	ok(Config.ownsModel(key), `{key}: ownsModel(key)`)
	ok(Config.ownsModel(key .. "_1") and Config.ownsModel(key .. "_12"), `{key}: ownsModel(spawned name)`)
	ok(not Config.ownsModel(key .. "X"), `{key}: no prefix match`)
end
local padCount = 0
for _ in padBuilds do
	padCount += 1
end
ok(padCount == 10, "every Manager pad is listed")
ok(not Config.ownsModel("A1_Workbench") and not Config.ownsModel("A1_Workbench_1"), "non-manager")

-- Worlds (owner R57 Dino Valley, R70 Moon): every world's managers, by area.
ok(Config.WorldManagerKeys.main == Config.ManagerKeys, "WorldManagerKeys.main is ManagerKeys")
ok(Config.managerKeysOf("main") == Config.ManagerKeys, "managerKeysOf(main)")
ok(#Config.managerKeysOf("nowhere") == 0, "managerKeysOf(unknown world) is empty")

-- Every world with manager keys, Nuke Town first, then by id (deterministic order for the brain seeds).
local WORLDS: { string } = {}
for worldId in Config.WorldManagerKeys do
	if worldId ~= "main" then
		table.insert(WORLDS, worldId)
	end
end
table.sort(WORLDS)
table.insert(WORLDS, 1, "main")

-- A world's config folder under src/shared/Config/Worlds ("dino" -> "Dino", "moon" -> "Moon").
local function worldFolder(worldId: string): string
	return `src/shared/Config/Worlds/{string.upper(string.sub(worldId, 1, 1))}{string.sub(worldId, 2)}`
end

--[[
	Keys listed vs rigs (worlds are built in waves: a world's key list can land before every
	manager's art + rig). Rules, so nothing slips through once its art exists:
	  * every listed key is unique across worlds and accepted by ownsModel;
	  * a key whose model has art (MeshAssets entry) MUST have a rig row;
	  * a rig row's `world` is its list's world (nil for Nuke Town) and every rig row is listed;
	  * when the world's AreaNN economy config exists, the key is that area's Manager pad build key.
	RIGGED = the listed keys with a rig: checks 2-4 (and 6 for non-main worlds) run over them.
]]
local ALL_KEYS: { string } = {}
local RIGGED: { string } = {}
local worldOfKey: { [string]: string } = {}
local areaOfKey: { [string]: number } = {}
local pendingRigs: { string } = {}
for _, worldId in WORLDS do
	local keys = Config.managerKeysOf(worldId)
	if worldId ~= "main" then
		ok(#keys >= 1, `{worldId}: lists its manager keys`)
	end
	for area, key in keys do
		ok(worldOfKey[key] == nil, `{key}: listed once across worlds`)
		worldOfKey[key] = worldId
		areaOfKey[key] = area
		table.insert(ALL_KEYS, key)
		ok(Config.ownsModel(key) and Config.ownsModel(key .. "_1"), `{key}: ownsModel`)
		ok(not Config.ownsModel(key .. "X"), `{key}: no prefix match`)
		local rig = Config.Rigs[key]
		if rig ~= nil then
			table.insert(RIGGED, key)
			local wanted = if worldId == "main" then nil else worldId
			ok(rig.world == wanted, `{key}: rig world field is {wanted}`)
		else
			ok(MeshAssets[key] == nil, `{key}: has art (MeshAssets) but no rig row`)
			table.insert(pendingRigs, key)
		end
		if worldId ~= "main" then
			local areaFile = string.format("%s/Areas/Area%02d.luau", worldFolder(worldId), area)
			if fs.isFile(areaFile) then
				local found: { string } = {}
				for block in string.gmatch(fs.readFile(areaFile), 'kind = "Manager",(.-)}') do
					local build = string.match(block, 'build = "([%w_]+)"')
					if build ~= nil then
						table.insert(found, build)
					end
				end
				ok(#found == 1, `{worldId} Area{area}: one Manager pad`)
				ok(found[1] == key, `{worldId} Area{area}: managerKeysOf("{worldId}")[{area}] == {found[1]}`)
			end
		end
	end
end
-- Dino Valley is complete: six areas, every rig present (no pending rig may hide there).
ok(#Config.managerKeysOf("dino") == 6, "six Dino manager keys")
for _, key in Config.managerKeysOf("dino") do
	ok(Config.Rigs[key] ~= nil, `{key}: Dino rig present`)
end
ok(not Config.ownsModel("D1_StoneBench") and not Config.ownsModel("D3_PteroCourier_1"), "Dino props are not managers")
local rigCount = 0
for key in Config.Rigs do
	rigCount += 1
	ok(worldOfKey[key] ~= nil, `{key}: rig is listed in a world's manager keys`)
end
ok(rigCount == #RIGGED, "one rig per rigged manager key")
ok(not Config.ownsModel("_1") and not Config.ownsModel(""), "degenerate names")
ok(Config.groupOf("ArmLCoat") == "ArmL" and Config.groupOf("ArmRNukeBody") == "ArmR", "arm groups")
ok(Config.groupOf("LegRShoes") == "LegR" and Config.groupOf("HeadHeadset") == "Head", "leg / head groups")
ok(Config.groupOf("TorsoHover") == "Torso", "torso group")
ok(Config.groupOf("Desk") == nil and Config.groupOf("Mat") == nil, "props stay static")
ok(
	Config.groupOf("Torsos") == nil and Config.groupOf("Head") == nil and Config.groupOf("Armchair") == nil,
	"whole words"
)

-- 2. Rig rows -----------------------------------------------------------------------------------
local ARMS = { ArmL = true, ArmR = true }
local ACTIONS = { Tap = true, Hammer = true, Press = true }
for _, key in RIGGED do
	local rig = Config.Rigs[key]
	ok(rig ~= nil, `{key}: rig row`)
	ok(rig.style == "Biped" or rig.style == "Hover", `{key}: style`)
	ok(ARMS[rig.waveArm] and ARMS[rig.workArm], `{key}: arms`)
	ok(ACTIONS[rig.workAction], `{key}: work action`)
	ok(
		Motion.ActionSeconds[rig.workAction] ~= nil and Motion.HitFraction[rig.workAction] ~= nil,
		`{key}: action timing`
	)
	local wps = rig.waypoints
	ok(#wps >= 2 and #wps <= 4, `{key}: 2-4 waypoints`)
	ok((wps[1].at - rig.figure.base).Magnitude < 1e-6, `{key}: waypoint 1 is the rest position`)
	local works = 0
	for i, wp in wps do
		ok((wp.at - rig.figure.base).Magnitude <= 8, `{key}: waypoint {i} within 8 studs of home`)
		ok(math.abs(wp.at.Y - rig.figure.base.Y) <= 0.01, `{key}: waypoint {i} on the figure's floor`)
		ok(wp.face == nil or type(wp.face) == "number" or wp.face == "producer", `{key}: waypoint {i} face`)
		ok(wp.pause == nil or wp.pause >= 0, `{key}: waypoint {i} pause`)
		if wp.work then
			works += 1
		end
	end
	ok(works >= 1, `{key}: has a work stop`)
	for _, group in { "Torso", "Head", "ArmL", "ArmR" } do
		ok(rig.joints[group] ~= nil, `{key}: joint {group}`)
	end
	if rig.style == "Biped" then
		ok(rig.joints.LegL ~= nil and rig.joints.LegR ~= nil, `{key}: biped leg joints`)
	end
end

-- 3. Rig vs meshes ------------------------------------------------------------------------------
for _, key in RIGGED do
	local rig = Config.Rigs[key]
	local asset = MeshAssets[key]
	ok(asset ~= nil, `{key}: MeshAssets entry`)
	ok(#asset.order <= 24, `{key}: <= 24 pieces`)
	local lo: { [string]: any } = {}
	local hi: { [string]: any } = {}
	for name, piece in asset.pieces do
		ok(piece.id ~= nil and piece.id > 0, `{key}.{name}: uploaded mesh id`)
		local group = Config.groupOf(name)
		if group ~= nil then
			ok(rig.joints[group] ~= nil, `{key}.{name}: group {group} has a joint`)
			local half = piece.size / 2
			local a, b = piece.offset - half, piece.offset + half
			lo[group] = if lo[group] then lo[group]:Min(a) else a
			hi[group] = if hi[group] then hi[group]:Max(b) else b
		end
	end
	for _, group in { "Torso", "Head", "ArmL", "ArmR" } do
		ok(lo[group] ~= nil, `{key}: has {group} pieces`)
	end
	if rig.style == "Biped" then
		ok(lo.LegL ~= nil and lo.LegR ~= nil, `{key}: biped has both legs`)
	else
		ok(lo.LegL == nil and lo.LegR == nil, `{key}: hover rig has no legs`)
	end
	local pad = roblox.Vector3.new(1.0, 1.0, 1.0)
	for group, joint in rig.joints do
		if lo[group] ~= nil then
			local a, b = lo[group] - pad, hi[group] + pad
			ok(
				joint.X >= a.X
					and joint.X <= b.X
					and joint.Y >= a.Y
					and joint.Y <= b.Y
					and joint.Z >= a.Z
					and joint.Z <= b.Z,
				`{key}: {group} joint inside its pieces' bounds`
			)
		end
	end
end

-- 4. Brain --------------------------------------------------------------------------------------
local DT = 1 / 30
for index, key in RIGGED do
	local rig = Config.Rigs[key]
	local brain = NpcBrain.new(rig, Motion, index * 101)
	local input = NpcBrain.newInput()
	input.dt = DT
	input.producerValid = true
	input.producerX, input.producerZ = rig.figure.base.X, rig.figure.base.Z - 20
	input.synced = true
	local home = rig.figure.base
	local reach = 0
	for _, wp in rig.waypoints do
		reach = math.max(reach, (wp.at - home).Magnitude)
	end
	local visits: { number } = {}
	local lastMode = brain.mode
	local hits, lastHitAt, beats = 0, -math.huge, 0
	local t = 0
	local cycle = 1.4
	local lastCycle = 0
	for _ = 1, math.floor(120 / DT) do
		t += DT
		local index2 = math.floor(t / cycle)
		input.cycleWrapped = index2 ~= lastCycle
		lastCycle = index2
		local yawBefore = brain.yaw
		local modeBefore = brain.mode
		NpcBrain.step(brain, input)
		local turned = math.abs(NpcBrain.wrap(brain.yaw - yawBefore))
		ok(turned <= math.rad(Motion.TurnSpeed) * DT + 1e-6, `{key}: turn rate`)
		ok(finite(brain.x) and finite(brain.y) and finite(brain.z) and finite(brain.yaw), `{key}: finite state`)
		local dx, dz = brain.x - home.X, brain.z - home.Z
		ok(math.sqrt(dx * dx + dz * dz) <= reach + 1e-6, `{key}: stays on its loop`)
		if brain.actionT == 0 then
			beats += 1
			ok(modeBefore == "Work", `{key}: beats only while working`)
		end
		if brain.hit then
			ok(t - lastHitAt >= Motion.MinBeatInterval - 1e-6, `{key}: beat spacing`)
			hits += 1
			lastHitAt = t
		end
		if brain.mode ~= lastMode and (brain.mode == "Idle" or brain.mode == "Work") then
			table.insert(visits, brain.target)
		end
		lastMode = brain.mode
	end
	ok(hits >= 3, `{key}: worked in sync ({hits} hits)`)
	ok(#visits >= #rig.waypoints, `{key}: completed a loop`)
	for i = 2, #visits do
		ok(visits[i] == visits[i - 1] % #rig.waypoints + 1 or #rig.waypoints == 1, `{key}: visits in order`)
	end

	-- Pose over a walk: everything finite.
	local pose = NpcPose.new()
	NpcPose.compute(brain, pose)
	for field, value in pose do
		ok(finite(value), `{key}: pose.{field} finite`)
	end
end

-- Unsynced fallback cadence + fast-cycle throttle (Uncle Atom, parked on his work stop).
do
	local rig = Config.Rigs.A1_UncleAtom
	local brain = NpcBrain.new(rig, Motion, 3)
	local input = NpcBrain.newInput()
	input.dt = DT
	-- Teleport onto the work stop.
	for i, wp in rig.waypoints do
		if wp.work then
			brain.target = i
			brain.x, brain.y, brain.z = wp.at.X, wp.at.Y, wp.at.Z
			brain.mode = "Work"
			brain.timer, brain.beats, brain.sinceBeat = 0, 0, 0
		end
	end
	local starts = {}
	local t = 0
	for _ = 1, math.floor(Motion.WorkMinSeconds / DT) do
		t += DT
		NpcBrain.step(brain, input)
		if brain.actionT == 0 then
			table.insert(starts, t)
		end
	end
	ok(#starts >= 1, "unsynced fallback beats")
	for i = 2, #starts do
		ok(starts[i] - starts[i - 1] >= Motion.UnsyncedBeatSeconds - DT, "unsynced cadence")
	end
	-- Fast producer: a cycle wraps every frame -> beats still >= MinBeatInterval apart.
	brain.mode, brain.timer, brain.beats, brain.sinceBeat = "Work", 0, 0, 0
	input.synced, input.cycleWrapped = true, true
	local last, count = -math.huge, 0
	t = 0
	for _ = 1, math.floor(3 / DT) do
		t += DT
		NpcBrain.step(brain, input)
		if brain.actionT == 0 then
			ok(t - last >= Motion.MinBeatInterval - DT, "fast cycles throttled")
			last = t
			count += 1
		end
	end
	ok(count >= 2, "fast cycles still beat")
end

-- Wave on arrival, once, with cooldown; hop; reduced motion; hitch clamp.
do
	local rig = Config.Rigs.A4_Foreman
	local brain = NpcBrain.new(rig, Motion, 11)
	local input = NpcBrain.newInput()
	input.dt = DT
	input.ownerValid = true
	input.ownerX, input.ownerZ = 40, 40 -- far away
	NpcBrain.step(brain, input)
	ok(brain.mode ~= "Wave", "no wave while the owner is far")
	input.ownerX, input.ownerZ = brain.x + 5, brain.z
	NpcBrain.step(brain, input)
	ok(brain.mode == "Wave", "waves when the owner arrives")
	local goal = NpcBrain.yawToward(brain.x, brain.z, input.ownerX, input.ownerZ)
	for _ = 1, math.floor((Motion.WaveSeconds - 0.15) / DT) do
		input.ownerX, input.ownerZ = brain.x + 5, brain.z
		NpcBrain.step(brain, input)
	end
	ok(brain.mode == "Wave", "still waving")
	ok(math.abs(NpcBrain.wrap(brain.yaw - goal)) < 0.05, "turned toward the owner")
	for _ = 1, math.floor(0.35 / DT) do
		input.ownerX, input.ownerZ = brain.x + 5, brain.z
		NpcBrain.step(brain, input)
	end
	ok(brain.mode ~= "Wave", "wave ends")
	for _ = 1, math.floor(3 / DT) do
		input.ownerX, input.ownerZ = brain.x + 5, brain.z
		NpcBrain.step(brain, input)
		ok(brain.mode ~= "Wave", "no repeat wave while the owner stays")
	end
	-- Leave, wait out the cooldown, come back -> waves again.
	input.ownerX, input.ownerZ = 200, 200
	for _ = 1, math.floor((Motion.WaveCooldown + 1) / DT) do
		NpcBrain.step(brain, input)
	end
	input.ownerX, input.ownerZ = brain.x + 4, brain.z
	NpcBrain.step(brain, input)
	ok(brain.mode == "Wave", "waves again after the cooldown")

	-- Hop.
	NpcBrain.requestHop(brain, 0)
	NpcBrain.step(brain, input)
	ok(brain.hopped, "hop event fires")
	local pose = NpcPose.new()
	for _ = 1, math.floor(Motion.HopSeconds * 0.5 / DT) do
		NpcBrain.step(brain, input)
	end
	NpcPose.compute(brain, pose)
	ok(pose.y > brain.y + Motion.HopHeight * 0.7, "hop lifts the body")

	-- Reduced motion: home, idle, no beats, hops ignored.
	input.reduced = true
	input.synced, input.cycleWrapped = true, true
	NpcBrain.step(brain, input)
	local home = rig.waypoints[1].at
	ok(brain.x == home.X and brain.z == home.Z and brain.mode == "Idle", "reduced motion: home + idle")
	NpcBrain.requestHop(brain, 0)
	for _ = 1, math.floor(10 / DT) do
		NpcBrain.step(brain, input)
		ok(not brain.hit and not brain.hopped and brain.mode == "Idle", "reduced motion: idle only")
	end
	NpcPose.compute(brain, pose)
	ok(pose.legLPitch == 0 and pose.armLRoll <= 0 and math.abs(pose.armLPitch) < 1e-9, "reduced motion: still limbs")
	input.reduced = false
	NpcBrain.step(brain, input)
	ok(brain.mode == "Idle" or brain.mode == "Work", "resumes after reduced motion")

	-- A 5 s frame hitch while walking moves at most WalkSpeed * 0.25 studs.
	brain.mode, brain.stride = "Walk", 1
	brain.target = brain.target % #rig.waypoints + 1
	local x0, z0 = brain.x, brain.z
	input.dt = 5
	NpcBrain.step(brain, input)
	local moved = math.sqrt((brain.x - x0) ^ 2 + (brain.z - z0) ^ 2)
	ok(moved <= Motion.WalkSpeed * 0.25 + 1e-6, "hitch clamp")
end

-- 5. Pose ---------------------------------------------------------------------------------------
do
	local rig = Config.Rigs.A1_UncleAtom
	local brain = NpcBrain.new(rig, Motion, 5)
	local pose = NpcPose.new()
	brain.stride, brain.gait = 1, math.pi / 2 -- mid-stride, left leg forward
	NpcPose.compute(brain, pose)
	ok(pose.legLPitch > 0 and pose.legRPitch < 0, "legs swing opposite")
	ok(pose.armLPitch < 0, "left arm swings back while the left leg is forward")
	ok(math.abs(pose.armRPitch) < math.abs(pose.armLPitch), "carrying arm swings less")
	ok(pose.torsoPitch < 0, "leans into the walk")
	-- Wave mid-way: ArmL raised outward (negative roll ~ WaveLift).
	brain.stride, brain.waveT = 0, Motion.WaveSeconds * 0.5
	NpcPose.compute(brain, pose)
	ok(pose.armLRoll < -math.rad(Motion.WaveLift - Motion.WaveWiggle - 5), "ArmL waves outward")
	local right = Config.Rigs.A3_Dispatcher
	local rbrain = NpcBrain.new(right, Motion, 9)
	rbrain.waveT = Motion.WaveSeconds * 0.5
	NpcPose.compute(rbrain, pose)
	ok(pose.armRRoll > math.rad(Motion.WaveLift - Motion.WaveWiggle - 5), "ArmR waves outward")
	-- Hammer curve.
	local raise = NpcPose.actionPitch("Hammer", 0.45, Motion)
	local strikeU = 0.45 + 0.55 * 0.3
	local strike = NpcPose.actionPitch("Hammer", strikeU, Motion)
	ok(math.abs(raise - math.rad(Motion.HammerRaise)) < 1e-6, "hammer wind-up")
	ok(math.abs(strike - math.rad(Motion.HammerStrike)) < 1e-6, "hammer strike")
	ok(math.abs(NpcPose.actionPitch("Hammer", 1, Motion)) < 1e-6, "hammer recovers")
	ok(
		Motion.HitFraction.Hammer > 0.45 and Motion.HitFraction.Hammer <= strikeU + 0.05,
		"hammer hit lands on the strike"
	)
	ok(math.abs(NpcPose.actionPitch("Tap", 0.5, Motion) - math.rad(Motion.TapReach)) < 1e-6, "tap peak")
	-- Rest pose zeroes every angle.
	NpcPose.rest(brain, pose)
	ok(pose.armLRoll == 0 and pose.legRPitch == 0 and pose.headYaw == 0, "rest pose")
end

-- 6. Other worlds' loops vs their layouts (owner R57 Dino, R70 Moon; W10) ----------------------------
do
	local Loader = require("./fixtures/RobloxLoader")
	local loader = Loader.new()
	local CFrameT = roblox.CFrame
	local V3 = roblox.Vector3
	local SLOT_HALF_WIDTH, SLOT_DEPTH = 52, 70
	local BODY_CLEARANCE, CLICK_CLEARANCE = 1.3, 1.35
	local FIGURE_BAND = 6.5 -- studs above the figure's floor a box must reach into to matter

	-- Horizontal distance from a point to a yaw-only box's footprint (negative = inside).
	local function footprintDistance(x: number, z: number, cf: any, size: any): number
		local p = cf:PointToObjectSpace(V3.new(x, cf.Position.Y, z))
		local dx = math.max(math.abs(p.X) - size.X / 2, 0)
		local dz = math.max(math.abs(p.Z) - size.Z / 2, 0)
		if dx == 0 and dz == 0 then
			return -math.min(size.X / 2 - math.abs(p.X), size.Z / 2 - math.abs(p.Z))
		end
		return math.sqrt(dx * dx + dz * dz)
	end

	-- Every rigged manager of a non-main world: its rig waypoints are authored against that world's
	-- AreaNN layout, so the layout MUST exist once the rig does.
	local loopsChecked: { [string]: number } = {}
	for _, key in RIGGED do
		local worldId = worldOfKey[key]
		if worldId == "main" then
			continue
		end
		local area = areaOfKey[key]
		local rig = Config.Rigs[key]
		local layoutPath = string.format("%s/Layouts/Area%02d", worldFolder(worldId), area)
		ok(fs.isFile(layoutPath .. ".luau"), `{key}: {worldId} Area{area} layout exists ({layoutPath})`)
		loopsChecked[worldId] = (loopsChecked[worldId] or 0) + 1
		local layout = loader.load(layoutPath)
		local group = layout.builds[key]
		ok(group ~= nil, `{key}: {worldId} Area{area} layout builds the manager`)
		local placement: any = nil
		for _, entry in group.models do
			if entry.key == key then
				placement = entry.cf
			end
		end
		ok(placement ~= nil, `{key}: layout placement`)
		local model: any = placement
		ok(model.UpVector.Y > 0.9999, `{key}: placed upright (yaw only)`)
		local floor = rig.figure.base.Y
		local home = rig.figure.base

		-- Collision boxes in model space that reach into the figure's height band. The manager's own
		-- boxes around its home (figure, tail) move with it, so they are skipped; its props (desk,
		-- podium) are not.
		type Box = { name: string, cf: any, size: any, clearance: number }
		local boxes: { Box } = {}
		local function consider(name: string, box: any, own: boolean, clearance: number)
			local cf = model:ToObjectSpace(box.cf)
			local size = box.size
			if cf.UpVector.Y < 0.9999 then
				-- Tilted (ramps, bridges): use its model-space bounding box (conservative).
				local half = size / 2
				local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
				size = V3.new(
					math.abs(r.X) * half.X + math.abs(u.X) * half.Y + math.abs(l.X) * half.Z,
					math.abs(r.Y) * half.X + math.abs(u.Y) * half.Y + math.abs(l.Y) * half.Z,
					math.abs(r.Z) * half.X + math.abs(u.Z) * half.Y + math.abs(l.Z) * half.Z
				) * 2
				cf = CFrameT.new(cf.Position)
			end
			local top, bottom = cf.Position.Y + size.Y / 2, cf.Position.Y - size.Y / 2
			if top <= floor + 0.3 or bottom >= floor + FIGURE_BAND then
				return
			end
			if own and footprintDistance(home.X, home.Z, cf, size + V3.new(2, 0, 2)) <= 0 then
				return
			end
			table.insert(boxes, { name = name, cf = cf, size = size, clearance = clearance })
		end
		for _, box in layout.base.collision or {} do
			consider("base", box, false, BODY_CLEARANCE)
		end
		for buildKey, build in layout.builds do
			for _, box in build.collision or {} do
				consider(buildKey, box, buildKey == key, BODY_CLEARANCE)
			end
		end
		consider("producer click box", layout.producer.click, false, CLICK_CLEARANCE)

		local function clear(point: any, label: string)
			local slot = model:PointToWorldSpace(point)
			ok(
				math.abs(slot.X) <= SLOT_HALF_WIDTH - BODY_CLEARANCE
					and slot.Z >= BODY_CLEARANCE
					and slot.Z <= SLOT_DEPTH - BODY_CLEARANCE,
				`{key}: {label} inside the slot ({slot.X}, {slot.Z})`
			)
			for _, box in boxes do
				local d = footprintDistance(point.X, point.Z, box.cf, box.size)
				ok(d >= box.clearance - 1e-6, `{key}: {label} keeps {box.clearance} from {box.name} ({d})`)
			end
		end
		local wps = rig.waypoints
		for i, wp in wps do
			clear(wp.at, `waypoint {i}`)
			local nextAt = wps[i % #wps + 1].at
			for step = 1, 19 do
				clear(wp.at:Lerp(nextAt, step / 20), `walk {i}->{i % #wps + 1} @{step}/20`)
			end
		end
	end
	ok(loopsChecked.dino == 6, "all six Dino manager loops checked against their layouts")
	for worldId, count in loopsChecked do
		print(`[npc-logic] {worldId}: {count} manager loop(s) checked against the layouts`)
	end
end
if #pendingRigs > 0 then
	-- Listed keys whose art + rig have not landed yet (e.g. a world built in waves): reported, the
	-- art rule above turns each into a failure the moment its MeshAssets entry appears.
	print(`[npc-logic] pending rigs (no art yet): {table.concat(pendingRigs, ", ")}`)
end

print(`[npc-logic] {checks} checks passed`)
