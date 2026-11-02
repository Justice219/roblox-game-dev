--!strict
--[[
	Procedural pet animation (src/client/Pets/PetAnim.luau, owner R44). Run:
		lune run tests/pet-anim

	Every species of PetConfig is rigged straight from its MeshAssets entry (the same names /
	offsets / joints the client uses) and simulated through idle, walking + turning, happy, sleep,
	Reduce Motion and Simple detail with normal and hostile frame times. Proves:
	  1. Rigging: prefix grouping (Head* with Head, longest prefix first), every pivot-string joint
	     is parsed, styles (walk / hop / blob / fly / swim / float / scuttle) are as designed.
	  2. Rigid groups (R25): pieces of one limb group never move relative to each other.
	  3. Wing symmetry: WingL is always the mirror image of WingR.
	  4. No NaN / inf anywhere, even with NaN / negative / huge dt, speed and turn rate.
	  5. Bounded: lift, squash, sway inside PetAnimConfig.Limits; no piece flies away.
	  6. Behaviour: flyers flap, walkers bounce only while moving, tails wag faster when moving,
	     happy spins once and ends, sleep lies down / droops, Reduce Motion = no hops / actions,
	     Simple detail = body + wings only, viewports never pick a big hop, determinism per seed.
]]

local Loader = require("./fixtures/RobloxLoader")
local roblox = require("@lune/roblox")

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local loader = Loader.new()
local PetAnim = loader.load("src/client/Pets/PetAnim")
local PetAnimConfig = loader.load("src/shared/Config/PetAnimConfig")
local PetConfig = loader.load("src/shared/Config/PetConfig")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local MeshPlacement = loader.load("src/shared/World/MeshPlacement")

local FULL = PetAnim.Detail.Full
local SIMPLE = PetAnim.Detail.Simple
local Limits = PetAnimConfig.Limits

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local function finite(x: number): boolean
	return x == x and x > -math.huge and x < math.huge
end

local function finiteCFrame(cf: any): boolean
	for _, value in { cf:GetComponents() } do
		if not finite(value) then
			return false
		end
	end
	return true
end

local function near(a: any, b: any, eps: number): boolean
	return (a - b).Magnitude <= eps
end

-- The species keys of the roster (unique, sorted).
local keys: { string } = {}
do
	local seen = {}
	for _, def in PetConfig.Pets do
		if not seen[def.model] then
			seen[def.model] = true
			table.insert(keys, def.model)
		end
	end
	table.sort(keys)
end
-- 29 B8f species (pets.py) + 9 World 2 dinos (W11 pets_dino.py, owner R57) + 9 World 3 Moon Base
-- pets (W11 pets_moon.py, owner R70) + the R78 Golden Nukey's SparkleNukey (pet_golden_nukey.py).
check(#keys == 48, `48 species (got {#keys})`)

-- Hover per species (from the roster).
local hoverOf: { [string]: number } = {}
for _, def in PetConfig.Pets do
	hoverOf[def.model] = def.hover
end

-- A rig exactly like PetModels.animRig builds it for an uploaded mesh at `scale`.
local function rigFor(key: string, scale: number): any
	local entry = MeshAssets[key]
	local names, rest, sizes, alphas = {}, {}, {}, {}
	local pieceNames = {}
	for name in entry.pieces do
		table.insert(pieceNames, name)
	end
	table.sort(pieceNames)
	for _, name in pieceNames do
		local piece = entry.pieces[name]
		local cf = MeshPlacement.pieceCFrame(CFrame.new(), piece.offset, true)
		table.insert(names, name)
		table.insert(rest, cf.Rotation + cf.Position * scale)
		table.insert(sizes, piece.size * scale)
		table.insert(alphas, piece.transparency or 0)
	end
	local joints = PetAnim.parseJoints(entry.pivot)
	for name, joint in joints do
		joints[name] = joint * scale
	end
	return PetAnim.buildRig({
		key = key,
		names = names,
		rest = rest,
		sizes = sizes,
		transparency = alphas,
		joints = joints,
		hover = hoverOf[key],
	})
end

--------------------------------------------------------------------------------------------------
-- 1. Rigging
--------------------------------------------------------------------------------------------------

check(PetAnim.groupOf("Head") == "Head", "Head")
check(PetAnim.groupOf("HeadEars") == "Head", "HeadEars → Head")
check(PetAnim.groupOf("HeadGlow") == "Head", "HeadGlow → Head")
check(PetAnim.groupOf("TailTip") == "Tail", "TailTip → Tail")
check(PetAnim.groupOf("WingL") == "WingL", "WingL")
check(PetAnim.groupOf("WingR") == "WingR", "WingR")
check(PetAnim.groupOf("ClawL") == "ClawL", "ClawL")
check(PetAnim.groupOf("Orbit") == "Orbit", "Orbit")
for _, name in { "Body", "Glow", "Face", "Shine", "Belly", "Fins", "Feet", "Hooves", "Crown", "Horn", "Beak" } do
	check(PetAnim.groupOf(name) == "Body", `{name} → Body`)
end
check(next(PetAnim.parseJoints("ground; hover 0; joints none")) == nil, "joints none → {}")
check(next(PetAnim.parseJoints(nil)) == nil, "nil pivot → {}")
local bad = PetAnim.parseJoints("joints Head@(0,1.-,2) Tail@(0,0.5,0.6)")
check(bad.Head == nil and bad.Tail ~= nil, "unparsable joint skipped, the rest kept")

local expectedStyle: { [string]: string } = {
	FissionFox = "Walk",
	AtomPup = "Walk",
	QuarkDuck = "Walk",
	FusionPhoenix = "Fly",
	ReactorOwl = "Fly",
	CoreDragon = "Fly",
	IonJelly = "Float",
	VoidCat = "Float",
	GlowSlime = "Blob",
	UraniumBunny = "Hop",
	NuclearNarwhal = "Swim",
	AtomicAxolotl = "Swim",
	CranberryCrab = "Scuttle",
	-- World 2 dinos (R57): walkers derive Walk, the two pteros (hover + WingL / WingR) Fly.
	AtomRaptor = "Walk",
	GlowStego = "Walk",
	FissionTrike = "Walk",
	PocketBronto = "Walk",
	EmberAnkylo = "Walk",
	LavaPara = "Walk",
	SupernovaSpino = "Walk",
	MagmaPtero = "Fly",
	TimePtero = "Fly",
	-- World 3 Moon Base (R70): walkers Walk, the owl + unicorn (hover + wings) Fly, the octo + corgi
	-- (hover, no wings) Float, the bunny Hops and the whale Swims (PetAnimConfig overrides).
	AstroPup = "Walk",
	CosmoCat = "Walk",
	CometFox = "Walk",
	MoonBunny = "Hop",
	OrbitOwl = "Fly",
	StarlightUnicorn = "Fly",
	SaucerOcto = "Float",
	RocketCorgi = "Float",
	GalaxyWhale = "Swim",
}

local rigs: { [string]: any } = {}
for _, key in keys do
	local entry = MeshAssets[key]
	check(entry ~= nil, `{key} in MeshAssets`)
	local rig = rigFor(key, 1)
	rigs[key] = rig
	check(rig.count > 0, `{key} has pieces`)
	if expectedStyle[key] ~= nil then
		check(rig.style == expectedStyle[key], `{key} style {rig.style} (want {expectedStyle[key]})`)
	end
	-- Every joint in the pivot string drives a present group.
	local parsed = PetAnim.parseJoints(entry.pivot)
	for name, joint in parsed do
		check(rig.has[name] == true, `{key}: joint {name} has pieces`)
		check(near(rig.joints[name], joint, 1e-6), `{key}: joint {name} from the pivot string`)
	end
	-- Every present limb group has a joint; every Head*-named piece is in the Head group.
	for index, name in rig.names do
		local group = rig.groups[index]
		if group ~= "Body" then
			check(rig.joints[group] ~= nil, `{key}: {group} has a joint`)
		end
		if string.sub(name, 1, 4) == "Head" then
			check(group == "Head", `{key}: {name} moves with the head`)
		end
	end
	check(rig.anchor >= 1 and rig.anchor <= rig.count, `{key} emote anchor`)
	check(rig.height > 0.5 and rig.height < 4, `{key} height {rig.height}`)
	check(#rig.squash >= 1, `{key} has a squashing body`)
	if rig.airborne then
		check(rig.pivotY > 0, `{key} airborne pivot above the ground`)
	else
		check(rig.pivotY == 0, `{key} ground pivot at the feet`)
	end
end
-- Derived joints (a group without a pivot-string joint) sit at sensible places.
do
	local rig = PetAnim.buildRig({
		key = "Critter",
		names = { "Body", "WingL", "WingR", "Orbit" },
		rest = { CFrame.new(0, 1, 0), CFrame.new(-1.25, 1.1, 0), CFrame.new(1.25, 1.1, 0), CFrame.new(0, 2.7, 0) },
		sizes = { Vector3.new(2, 2, 2), Vector3.new(1.3, 0.25, 0.9), Vector3.new(1.3, 0.25, 0.9), Vector3.new(1, 0.1, 1) },
		transparency = { 0, 0, 0, 0 },
		joints = {},
		hover = 0.4,
	})
	check(rig.style == "Fly", "critter with wings + hover flies")
	check(near(rig.joints.WingL, Vector3.new(-0.6, 1.1, 0), 1e-6), "derived WingL joint = inner edge")
	check(near(rig.joints.WingR, Vector3.new(0.6, 1.1, 0), 1e-6), "derived WingR joint = inner edge")
	check(near(rig.joints.Orbit, Vector3.new(0, 2.7, 0), 1e-6), "derived Orbit joint = centre")
end

--------------------------------------------------------------------------------------------------
-- 2-5. Simulation: rigid groups, wing symmetry, finite + bounded
--------------------------------------------------------------------------------------------------

local MIRROR = function(v: any): any
	return Vector3.new(-v.X, v.Y, v.Z)
end
local SAMPLES = { Vector3.new(0.3, 0.2, 0.1), Vector3.new(-0.7, 1.4, -0.5), Vector3.new(1.1, -0.3, 0.9) }

-- Checks one posed frame of `rig` / `state` / `out`.
local function verifyFrame(key: string, rig: any, state: any, out: { any }, label: string)
	for _, field in {
		"y",
		"pitch",
		"yaw",
		"roll",
		"swayX",
		"swayZ",
		"sx",
		"sy",
		"headPitch",
		"headYaw",
		"tailYaw",
		"tailPitch",
		"wing",
		"glow",
	} do
		check(finite(state[field]), `{key} {label}: {field} finite`)
	end
	check(state.y >= Limits.MinY and state.y <= Limits.MaxY, `{key} {label}: y {state.y} in limits`)
	check(state.sy >= Limits.MinScaleY and state.sy <= Limits.MaxScaleY, `{key} {label}: sy {state.sy}`)
	check(state.sx >= Limits.MinScaleX and state.sx <= Limits.MaxScaleX, `{key} {label}: sx {state.sx}`)
	check(math.abs(state.swayX) <= Limits.MaxSway and math.abs(state.swayZ) <= Limits.MaxSway, `{key} sway`)
	check(state.glow >= 0 and state.glow <= 1, `{key} glow 0..1`)
	-- Every piece finite and close to where it rests (a spin moves a piece at most 2 × its radius).
	for index = 1, rig.count do
		local cf = out[index]
		check(cf ~= nil and finiteCFrame(cf), `{key} {label}: piece {index} finite`)
		local restPos = rig.rest[index].Position
		local radius = Vector3.new(restPos.X, 0, restPos.Z).Magnitude + 2.2
		local bound = 2 * radius + Limits.MaxY - Limits.MinY + 2 * Limits.MaxSway
		check((cf.Position - restPos).Magnitude <= bound, `{key} {label}: piece {rig.names[index]} stays near`)
	end
	-- Rigid limb groups: relative transforms inside a group never change (R25).
	local firstOf: { [string]: number } = {}
	for index = 1, rig.count do
		local group = rig.groups[index]
		if group ~= "Body" then
			local first = firstOf[group]
			if first == nil then
				firstOf[group] = index
			else
				local now = out[first]:Inverse() * out[index]
				local was = rig.rest[first]:Inverse() * rig.rest[index]
				check(near(now.Position, was.Position, 2e-3), `{key} {label}: {rig.names[index]} rigid with {group}`)
				check(near(now.LookVector, was.LookVector, 2e-3), `{key} {label}: {rig.names[index]} rotation rigid`)
			end
		end
	end
	-- Wing symmetry: WingL = mirror(WingR) about the YZ plane.
	local left, right = state.frames.WingL, state.frames.WingR
	if rig.has.WingL and rig.has.WingR and left ~= nil and right ~= nil then
		for _, p in SAMPLES do
			check(near(left * MIRROR(p), MIRROR(right * p), 1e-4), `{key} {label}: wings mirrored`)
		end
	end
end

-- Runs one scenario; `driver(frame, t)` returns dt, speed, turnRate, asleep.
local function simulate(
	key: string,
	detail: number,
	reduced: boolean,
	frames: number,
	label: string,
	driver: (number, number) -> (number, number, number, boolean),
	seed: number?
): any
	local rig = rigs[key]
	local state = PetAnim.newState(seed or 7)
	local out = table.create(rig.count)
	local t = 0
	for frame = 1, frames do
		local dt, speed, turn, asleep = driver(frame, t)
		t += if finite(dt) and dt > 0 then dt else 0
		PetAnim.step(rig, state, dt, speed, turn, asleep, detail, reduced)
		PetAnim.pose(rig, state, out, detail)
		if frame % 9 == 0 or frame == frames then
			verifyFrame(key, rig, state, out, label)
		end
	end
	return state, out
end

local DT = 1 / 60
local hostile = { 0, -1, 0 / 0, math.huge, 5, 1e-6, 1 / 30 }

for _, key in keys do
	for _, detail in { FULL, SIMPLE } do
		for _, reduced in { false, true } do
			local tag = `d{detail}{if reduced then "r" else ""}`
			-- Long idle (actions, look-around, breathing).
			simulate(key, detail, reduced, 900, `idle {tag}`, function()
				return DT, 0, 0, false
			end)
			-- Walking with turns, stop-and-go.
			simulate(key, detail, reduced, 600, `walk {tag}`, function(frame)
				local speed = if (frame // 120) % 2 == 0 then 15 else 0
				return DT, speed, math.sin(frame / 40) * 4, false
			end)
			-- Asleep.
			simulate(key, detail, reduced, 240, `sleep {tag}`, function()
				return DT, 0, 0, true
			end)
			-- Hostile inputs.
			simulate(key, detail, reduced, 200, `hostile {tag}`, function(frame)
				local bad = hostile[(frame % #hostile) + 1]
				return bad, if frame % 3 == 0 then 0 / 0 else bad * 10, if frame % 5 == 0 then math.huge else bad, frame % 2 == 0
			end)
		end
	end
	-- Happy spin mid-walk and while idle.
	local rig = rigs[key]
	local state = PetAnim.newState(3)
	local out = table.create(rig.count)
	PetAnim.happy(state, 0.2)
	check(PetAnim.isHappy(state), `{key} happy pending`)
	local maxYaw = 0
	for _ = 1, math.ceil((PetAnimConfig.Happy.Duration + 0.2) / DT) + 5 do
		PetAnim.step(rig, state, DT, 0, 0, false, FULL, false)
		PetAnim.pose(rig, state, out, FULL)
		maxYaw = math.max(maxYaw, state.yaw)
	end
	verifyFrame(key, rig, state, out, "happy")
	check(not PetAnim.isHappy(state), `{key} happy ends`)
	check(maxYaw > math.pi, `{key} happy spins round ({maxYaw})`)
end

--------------------------------------------------------------------------------------------------
-- 6. Behaviour
--------------------------------------------------------------------------------------------------

-- Max / min of a state field over `frames` frames of a driver.
local function range(key: string, field: string, frames: number, speed: number, detail: number, reduced: boolean): (number, number)
	local rig = rigs[key]
	local state = PetAnim.newState(11)
	state.actionIn = math.huge -- no random actions in these measurements
	local out = table.create(rig.count)
	local lo, hi = math.huge, -math.huge
	for frame = 1, frames do
		PetAnim.step(rig, state, DT, speed, 0, false, detail, reduced)
		PetAnim.pose(rig, state, out, detail)
		if frame > 60 then
			lo = math.min(lo, state[field])
			hi = math.max(hi, state[field])
		end
	end
	return lo, hi
end

-- Flyers flap their wings (both directions), more when moving.
do
	local lo, hi = range("FusionPhoenix", "wing", 240, 0, FULL, false)
	check(hi > math.rad(20) and lo < -math.rad(20), `phoenix flaps idle ({lo}, {hi})`)
	local mlo, mhi = range("FusionPhoenix", "wing", 240, 14, FULL, false)
	check(mhi - mlo > hi - lo, "phoenix flaps harder when moving")
	local slo, shi = range("FusionPhoenix", "wing", 240, 0, SIMPLE, false)
	check(shi > math.rad(20) and slo < -math.rad(20), "Low tier keeps the wing flap")
	local rlo, rhi = range("FusionPhoenix", "wing", 240, 0, FULL, true)
	check(rhi - rlo < hi - lo and rhi - rlo > 0, "Reduce Motion: gentler flap")
end

-- Walkers bounce only while moving; Reduce Motion never hops.
do
	local _, idleHi = range("FissionFox", "y", 240, 0, FULL, false)
	local _, walkHi = range("FissionFox", "y", 240, 14, FULL, false)
	check(walkHi > 0.15, `fox bounces when walking ({walkHi})`)
	check(idleHi < 0.05, `fox stays grounded idle ({idleHi})`)
	local _, calmHi = range("FissionFox", "y", 240, 14, FULL, true)
	check(calmHi < 0.05, `Reduce Motion: no hop ({calmHi})`)
	local sqLo, sqHi = range("FissionFox", "sy", 240, 14, FULL, false)
	check(sqLo < 0.95 and sqHi > 1.02, `fox squashes + stretches ({sqLo}, {sqHi})`)
	local hopLo, hopHi = range("UraniumBunny", "y", 240, 14, FULL, false)
	check(hopHi > 0.4 and hopLo < 0.05, `bunny hops high ({hopLo}, {hopHi})`)
end

-- Floaters pulse + drift; swimmers undulate their tail.
do
	local lo, hi = range("IonJelly", "sy", 240, 0, FULL, false)
	check(hi - lo > 0.08, `jelly pulses ({lo}, {hi})`)
	local xlo, xhi = range("IonJelly", "swayX", 600, 0, FULL, false)
	check(xhi - xlo > 0.05, "jelly drifts")
	local tlo, thi = range("NuclearNarwhal", "tailPitch", 240, 0, FULL, false)
	check(thi - tlo > math.rad(15), "narwhal tail undulates up/down")
	local clo, chi = range("CranberryCrab", "clawR", 240, 10, FULL, false)
	check(chi > math.rad(10) and chi - clo > math.rad(5), "crab raises + snips its claws while scuttling")
end

-- Tails wag faster when moving.
do
	local rig = rigs.AtomPup
	local idle = PetAnim.newState(5)
	local walk = PetAnim.newState(5)
	local out = table.create(rig.count)
	local idleStart, walkStart = idle.wag, walk.wag
	for _ = 1, 120 do
		PetAnim.step(rig, idle, DT, 0, 0, false, FULL, false)
		PetAnim.step(rig, walk, DT, 14, 0, false, FULL, false)
	end
	PetAnim.pose(rig, walk, out, FULL)
	check(walk.wag - walkStart > (idle.wag - idleStart) * 1.5, "tail wags faster when moving")
	local lo, hi = range("AtomPup", "tailYaw", 240, 14, FULL, false)
	check(hi > math.rad(10) and lo < -math.rad(10), "pup wags both ways")
end

-- Orbit rings spin; Glow pulses only in Full detail.
do
	local rig = rigs.FissionFox
	local state = PetAnim.newState(9)
	local start = state.orbit
	for _ = 1, 30 do
		PetAnim.step(rig, state, DT, 0, 0, false, FULL, false)
	end
	check(math.abs(state.orbit - start) > 0.3, "orbit ring spins")
	check(#rigs.FusionPhoenix.glow >= 1, "phoenix has a glow piece")
	local lo, hi = range("FusionPhoenix", "glow", 240, 0, FULL, false)
	check(hi - lo > 0.5, "glow pulses")
	local slo, shi = range("FusionPhoenix", "glow", 240, 0, SIMPLE, false)
	check(slo == 0 and shi == 0, "no glow pulse in Simple detail")
	-- A pulse only ever dims (never brighter than at rest, R19).
	local glowRig = rigs.FusionPhoenix
	local s2 = PetAnim.newState(1)
	for _ = 1, 50 do
		PetAnim.step(glowRig, s2, DT, 0, 0, false, FULL, false)
		for n = 1, #glowRig.glow do
			check(PetAnim.glowTransparency(glowRig, s2, n) >= glowRig.glowRest[n], "glow never brighter")
		end
	end
end

-- Simple detail: head / tail / squash all still.
do
	for _, field in { "headPitch", "headYaw", "tailYaw", "tailPitch" } do
		local lo, hi = range("FissionFox", field, 240, 14, SIMPLE, false)
		check(lo == 0 and hi == 0, `Simple detail: {field} still`)
	end
	local lo, hi = range("FissionFox", "sy", 240, 14, SIMPLE, false)
	check(lo == 1 and hi == 1, "Simple detail: no squash")
end

-- Sleep: lies down, droops the head; wakes back up.
do
	local rig = rigs.FissionFox
	local state = PetAnim.newState(4)
	state.actionIn = math.huge
	for _ = 1, 180 do
		PetAnim.step(rig, state, DT, 0, 0, true, FULL, false)
	end
	check(state.sleep == 1, "fell asleep")
	check(state.y < -0.05, `lies down ({state.y})`)
	check(state.headPitch < -math.rad(10), "head droops")
	for _ = 1, 180 do
		PetAnim.step(rig, state, DT, 0, 0, false, FULL, false)
	end
	check(state.sleep == 0, "woke up")
	local flyer = rigs.FusionPhoenix
	local bird = PetAnim.newState(4)
	for _ = 1, 180 do
		PetAnim.step(flyer, bird, DT, 0, 0, true, FULL, false)
	end
	check(bird.y < -0.2, `a sleepy flyer sinks ({bird.y})`)
end

-- Reduce Motion never starts actions; viewports never pick a big hop.
do
	local rig = rigs.FissionFox
	local state = PetAnim.newState(2)
	for _ = 1, 60 * 40 do
		PetAnim.step(rig, state, DT, 0, 0, false, FULL, true)
		check(state.action == nil, "Reduce Motion: no idle actions")
	end
	local seen: { [string]: boolean } = {}
	for seed = 1, 40 do
		local view = PetAnim.newState(seed, true)
		for _ = 1, 60 * 30 do
			PetAnim.step(rigs.UraniumBunny, view, DT, 0, 0, false, FULL, false)
			if view.action ~= nil then
				seen[view.action] = true
			end
		end
	end
	check(seen.Hop == nil, "viewport pets never hop out of frame")
	check(next(seen) ~= nil, "viewport pets do idle actions")
	local world: { [string]: boolean } = {}
	for seed = 1, 40 do
		local follower = PetAnim.newState(seed)
		for _ = 1, 60 * 30 do
			PetAnim.step(rigs.FissionFox, follower, DT, 0, 0, false, FULL, false)
			if follower.action ~= nil then
				world[follower.action] = true
			end
		end
	end
	check(world.Sit and world.Spin and world.Hop, "followers sit, spin and hop")
end

-- Determinism: same seed + inputs → identical pose; different seeds → desynchronised teams.
do
	local rig = rigs.CoreDragon
	local a, b, c = PetAnim.newState(21), PetAnim.newState(21), PetAnim.newState(22)
	local outA, outB = table.create(rig.count), table.create(rig.count)
	for frame = 1, 300 do
		local speed = if frame > 150 then 12 else 0
		PetAnim.step(rig, a, DT, speed, 0.5, false, FULL, false)
		PetAnim.step(rig, b, DT, speed, 0.5, false, FULL, false)
		PetAnim.step(rig, c, DT, speed, 0.5, false, FULL, false)
	end
	PetAnim.pose(rig, a, outA, FULL)
	PetAnim.pose(rig, b, outB, FULL)
	for index = 1, rig.count do
		check(near(outA[index].Position, outB[index].Position, 1e-9), "deterministic pose")
	end
	check(a.flap ~= c.flap, "different seeds flap out of step")
end

-- Banking: a flyer turning left rolls left (left wing down), and the bank is bounded.
do
	local rig = rigs.FusionPhoenix
	local state = PetAnim.newState(8)
	state.actionIn = math.huge
	for _ = 1, 120 do
		PetAnim.step(rig, state, DT, 12, 3, false, FULL, false)
	end
	check(state.roll > 0.1, `banks into a left turn ({state.roll})`)
	check(state.roll <= math.rad(PetAnimConfig.Motion.Fly.BankMax) + 0.05, "bank bounded")
end

-- Squash sizes follow the pose and stay positive.
do
	local rig = rigs.GlowSlime
	local state = PetAnim.newState(1)
	for _ = 1, 100 do
		PetAnim.step(rig, state, DT, 14, 0, false, FULL, false)
		for n = 1, #rig.squash do
			local size = PetAnim.squashSize(rig, state, n)
			check(size.X > 0 and size.Y > 0 and size.Z > 0 and finite(size.Y), "squash size positive")
		end
	end
end

-- rescaleRig (a ScaleTo mid-reveal): a rig rescaled 1 → 2.5 equals a rig built at 2.5.
do
	for _, key in { "FusionPhoenix", "CranberryCrab", "IonJelly" } do
		local grown = rigFor(key, 1)
		PetAnim.rescaleRig(grown, 2.5)
		local built = rigFor(key, 2.5)
		for index = 1, built.count do
			check(near(grown.rest[index].Position, built.rest[index].Position, 1e-4), `{key}: rescaled rest {index}`)
			check(near(grown.rest[index].LookVector, built.rest[index].LookVector, 1e-6), `{key}: rotation kept`)
		end
		for group, joint in built.joints do
			check(near(grown.joints[group], joint, 1e-4), `{key}: rescaled joint {group}`)
		end
		for n, size in built.restSize do
			check(near(grown.restSize[n], size, 1e-4), `{key}: rescaled squash size`)
		end
		check(math.abs(grown.height - built.height) < 1e-4, `{key}: rescaled height`)
		check(grown.scale == 2.5, `{key}: motion scale follows`)
		-- Bigger pets move proportionally further, still bounded by the scaled limits.
		local state = PetAnim.newState(6, true)
		local out = table.create(grown.count)
		for _ = 1, 240 do
			PetAnim.step(grown, state, DT, 0, 0, false, FULL, false)
			PetAnim.pose(grown, state, out, FULL)
			check(state.y <= Limits.MaxY * 2.5 and state.y >= Limits.MinY * 2.5, `{key}: scaled y bounded`)
		end
		PetAnim.rescaleRig(grown, 0 / 0)
		PetAnim.rescaleRig(grown, -1)
		check(grown.scale == 2.5, `{key}: bad factors ignored`)
	end
end

print(`[pet-anim] {checks} checks passed ({#keys} species)`)
