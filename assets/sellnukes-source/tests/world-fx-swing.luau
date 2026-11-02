--!strict
--[[
	WorldFx swings + hinges (owner R75: "animate the miners in the Glowrock area. They don't
	actually do anything"). Run:
		lune run tests/world-fx-swing

	Proves, from config + the pure Shared/World/SwingCurve (nothing in Studio):
	  1. SwingCurve: keys are hit exactly, easing stays inside each segment, the loop wraps
	     seamlessly, the gentle sway is bounded, and the impact crossing fires exactly once per loop
	     (wrap-aware, never on the first armed frame).
	  2. Rows: every "swing" row has valid keys (SwingCurve.validate), a period, a gentle Reduce
	     Motion sway, and a sane impact (fraction in [0, 1), range, a known burst kind, a real
	     AudioConfig.Sfx key); the PickSwing strike is a forward (negative) angle after a backward
	     wind-up. Tiers: Low has no bursts; Mid <= High.
	  3. Hinged assemblies: every Assembly with a hinge / follow / impactAt names a MeshAssets model
	     whose members all exist; the hinge sits on its members' geometry (within 1.5 studs of their
	     boxes); `follow` names another group of the same model; a follower's parent is a swing too
	     (shared phase).
	  4. A4_Miner: the pick arm is exactly the ArmR* pieces; every Torso* / Head* / ArmL* piece leans;
	     legs, the rock and its Glow gems never join a motion group (Glow keeps its own light row).
	  5. A9_AstronautCrew: the waving arm and the flag form their own hinged groups; nothing else of
	     the crew moves.
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")

local Vector3 = roblox.Vector3

local loader = Loader.new()
local SwingCurve = loader.load("src/shared/World/SwingCurve")
local WorldFxConfig = loader.load("src/shared/Config/WorldFxConfig")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local AudioConfig = loader.load("src/shared/Config/AudioConfig")

local checks, failures = 0, 0
-- Records one check (keeps going so a run lists every problem).
local function ok(condition: any, label: string)
	checks += 1
	if not condition then
		failures += 1
		print(`FAIL {label}`)
	end
end

local function near(a: number, b: number, eps: number, label: string)
	ok(math.abs(a - b) <= eps, `{label}: {a} vs {b}`)
end

-- 1. SwingCurve maths --------------------------------------------------------------------------
do
	local keys = {
		{ t = 0, angle = 0 },
		{ t = 0.4, angle = 45 },
		{ t = 0.5, angle = -80, ease = "in" },
		{ t = 0.6, angle = -70, ease = "out" },
		{ t = 1, angle = 0 },
	}
	ok(#SwingCurve.validate(keys) == 0, "example keys validate")
	for _, key in keys do
		near(
			SwingCurve.angle(keys, key.t % 1),
			if key.t == 1 then keys[1].angle else key.angle,
			1e-9,
			`key t={key.t} hit exactly`
		)
	end
	-- Inside each segment the angle stays between its end keys (no overshoot from the easing).
	for i = 1, #keys - 1 do
		local a, b = keys[i], keys[i + 1]
		local lo, hi = math.min(a.angle, b.angle), math.max(a.angle, b.angle)
		for k = 1, 9 do
			local u = a.t + (b.t - a.t) * k / 10
			local angle = SwingCurve.angle(keys, u)
			ok(angle >= lo - 1e-9 and angle <= hi + 1e-9, `segment {i}: no overshoot at u={u}`)
		end
	end
	-- "in" accelerates: halfway in time is less than halfway in angle travel.
	local mid = SwingCurve.angle(keys, 0.45)
	ok(math.abs(mid - 45) < math.abs(-80 - 45) / 2, "ease in: the strike gathers speed")
	-- Seamless wrap.
	near(SwingCurve.angle(keys, 0.999999), SwingCurve.angle(keys, 0), 0.01, "loop wraps without a jump")
	near(SwingCurve.angle(keys, 1.25), SwingCurve.angle(keys, 0.25), 1e-9, "u wraps modulo 1")
	-- Gentle sway bounded.
	local gentle = { amplitude = 8, period = 5 }
	local maxAbs = 0
	for k = 0, 100 do
		maxAbs = math.max(maxAbs, math.abs(SwingCurve.gentleAngle(gentle, k * 0.1)))
	end
	ok(maxAbs <= 8 + 1e-9 and maxAbs > 7, "gentle sway stays within its amplitude")
	-- Crossing: once per loop, wrap-aware, unarmed never fires.
	ok(SwingCurve.crossed(0.4, 0.5, 0.47), "crossed: inside a step")
	ok(not SwingCurve.crossed(0.47, 0.5, 0.47), "crossed: `at` equal to last is not re-fired")
	ok(SwingCurve.crossed(0.95, 0.05, 0.02), "crossed: across the wrap (after)")
	ok(SwingCurve.crossed(0.95, 0.05, 0.97), "crossed: across the wrap (before)")
	ok(not SwingCurve.crossed(0.95, 0.05, 0.5), "crossed: not across the wrap")
	ok(not SwingCurve.crossed(-1, 0.6, 0.47), "crossed: unarmed never fires")
	local fires = 0
	local last = -1
	for frame = 0, 600 do
		local fraction = (frame / 60 / 2.6) % 1
		if SwingCurve.crossed(last, fraction, 0.47) then
			fires += 1
		end
		last = fraction
	end
	ok(fires == 4, `one impact per loop at 60 fps over 10 s of a 2.6 s loop (got {fires})`)
	-- Validation catches bad tables.
	ok(#SwingCurve.validate({ { t = 0, angle = 0 } }) > 0, "validate: one key is not a loop")
	ok(#SwingCurve.validate({ { t = 0, angle = 0 }, { t = 1, angle = 5 } }) > 0, "validate: ends must match")
	ok(#SwingCurve.validate({
		{ t = 0, angle = 0 },
		{ t = 0.6, angle = 10 },
		{ t = 0.5, angle = 3 },
		{ t = 1, angle = 0 },
	}) > 0, "validate: t must rise")
	ok(
		#SwingCurve.validate({ { t = 0, angle = 0 }, { t = 0.5, angle = 1e9 }, { t = 1, angle = 0 } }) > 0,
		"validate: angle range"
	)
	ok(
		#SwingCurve.validate({ { t = 0, angle = 0 }, { t = 0.5, angle = 5, ease = "wobble" }, { t = 1, angle = 0 } })
			> 0,
		"validate: ease names"
	)
end

-- 2. Rows + tiers -------------------------------------------------------------------------------
local Pieces = WorldFxConfig.Pieces
local swingRows = 0
for name, row in Pieces do
	if row.motion ~= "swing" then
		ok(row.keys == nil and row.impact == nil and row.gentle == nil, `{name}: swing fields only on swing rows`)
		continue
	end
	swingRows += 1
	local problems = SwingCurve.validate(row.keys)
	ok(#problems == 0, `{name}: keys valid ({table.concat(problems, "; ")})`)
	ok(row.axis == "X" or row.axis == "Y" or row.axis == "Z", `{name}: axis`)
	ok(type(row.period) == "number" and row.period >= 1 and row.period <= 10, `{name}: period 1..10 s`)
	local gentle = row.gentle
	ok(
		gentle ~= nil and gentle.amplitude > 0 and gentle.amplitude <= 15 and gentle.period >= 3,
		`{name}: gentle Reduce Motion sway (small + slow)`
	)
	local impact = row.impact
	if impact ~= nil then
		ok(impact.at >= 0 and impact.at < 1, `{name}: impact.at in [0, 1)`)
		ok(impact.range > 0 and impact.range <= 120, `{name}: impact range sane`)
		ok(impact.burst == nil or WorldFxConfig.Bursts[impact.burst] ~= nil, `{name}: burst kind exists`)
		ok(impact.flash == nil or (impact.flash > 0 and impact.flash <= 1), `{name}: flash is brief`)
		local sound = impact.sound
		if sound ~= nil then
			ok(AudioConfig.Sfx[sound.key] ~= nil, `{name}: impact sound {sound.key} is an AudioConfig.Sfx key`)
			ok(sound.range > 0 and sound.range <= 80, `{name}: impact sound is short range`)
		end
	end
end
ok(swingRows >= 2, "the miner rows exist (PickSwing + MinerLean)")
do
	local pick = Pieces.PickSwing
	ok(pick ~= nil and pick.impact ~= nil and pick.impact.burst == "rockChips", "PickSwing strikes with rock chips")
	if pick ~= nil and pick.keys ~= nil and pick.impact ~= nil then
		local strike = SwingCurve.angle(pick.keys, pick.impact.at)
		local windup = -math.huge
		for _, key in pick.keys do
			if key.t < pick.impact.at then
				windup = math.max(windup, key.angle)
			end
		end
		ok(windup > 20, `PickSwing winds up backward before the strike (+{windup})`)
		ok(strike < -30, `PickSwing strikes forward-down at the impact ({strike})`)
	end
	for kind, burst in WorldFxConfig.Bursts do
		ok(
			burst.chips > 0 and burst.chips <= 16 and burst.sparkles >= 0 and burst.sparkles <= 12,
			`burst {kind}: small counts`
		)
		ok(#burst.chipColors >= 1 and burst.chipSize > 0 and burst.chipSize <= 0.6, `burst {kind}: chip look`)
	end
	local tiers = WorldFxConfig.Tiers
	ok(tiers.Low.Bursts == 0, "Low tier: swing only (no bursts / impact sounds)")
	ok(
		tiers.Mid.Bursts > 0 and tiers.Mid.Bursts <= tiers.High.Bursts and tiers.High.Bursts <= 1,
		"bursts rise with tier"
	)
end

-- 3. Hinged assemblies ---------------------------------------------------------------------------
local function boxDistance(point: any, offset: any, size: any): number
	local d = Vector3.new(
		math.max(math.abs(point.X - offset.X) - size.X / 2, 0),
		math.max(math.abs(point.Y - offset.Y) - size.Y / 2, 0),
		math.max(math.abs(point.Z - offset.Z) - size.Z / 2, 0)
	)
	return d.Magnitude
end

for modelKey, groups in WorldFxConfig.Assemblies do
	for groupName, assembly in groups do
		if assembly.hinge == nil and assembly.follow == nil and assembly.impactAt == nil then
			continue
		end
		local asset = MeshAssets[modelKey]
		ok(asset ~= nil, `{modelKey}: hinged assembly model exists in MeshAssets`)
		if asset == nil then
			continue
		end
		ok(assembly.members ~= nil and #assembly.members > 0, `{modelKey}.{groupName}: hinged groups list members`)
		local closest = math.huge
		for _, member in assembly.members or {} do
			local piece = asset.pieces[member]
			ok(piece ~= nil, `{modelKey}.{groupName}: member {member} exists`)
			if piece ~= nil and assembly.hinge ~= nil then
				closest = math.min(closest, boxDistance(assembly.hinge, piece.offset, piece.size))
			end
		end
		if assembly.hinge ~= nil then
			ok(closest <= 1.5, `{modelKey}.{groupName}: hinge sits on its members ({closest} studs away)`)
		end
		if assembly.follow ~= nil then
			local parent = groups[assembly.follow]
			ok(
				parent ~= nil and assembly.follow ~= groupName,
				`{modelKey}.{groupName}: follows another group of the model`
			)
			local row, parentRow = Pieces[assembly.fx], parent and Pieces[parent.fx]
			ok(
				row ~= nil and parentRow ~= nil and row.motion == "swing" and parentRow.motion == "swing",
				`{modelKey}.{groupName}: follower + parent are swings (shared phase)`
			)
			ok(
				row ~= nil and parentRow ~= nil and row.period == parentRow.period,
				`{modelKey}.{groupName}: follower + parent share the period`
			)
		end
	end
end

-- 4. A4_Miner partition ---------------------------------------------------------------------------
do
	local asset = MeshAssets.A4_Miner
	ok(asset ~= nil, "A4_Miner in MeshAssets")
	if asset ~= nil then
		for name in asset.pieces do
			local group, row = WorldFxConfig.groupFor("A4_Miner", name)
			if string.sub(name, 1, 4) == "ArmR" then
				ok(group == "@Pick" and row == Pieces.PickSwing, `A4_Miner.{name}: swings with the pick`)
			elseif
				string.sub(name, 1, 5) == "Torso"
				or string.sub(name, 1, 4) == "Head"
				or string.sub(name, 1, 4) == "ArmL"
			then
				ok(group == "@Lean" and row == Pieces.MinerLean, `A4_Miner.{name}: leans with the body`)
			elseif name == "Glow" then
				ok(group == "Glow", "A4_Miner.Glow keeps its own glow row (flashes on impact)")
			else
				ok(group == nil, `A4_Miner.{name}: stays still (got {group})`)
			end
		end
	end
end

-- 5. A9_AstronautCrew --------------------------------------------------------------------------------
do
	local asset = MeshAssets.A9_AstronautCrew
	ok(asset ~= nil, "A9_AstronautCrew in MeshAssets")
	if asset ~= nil then
		for name in asset.pieces do
			local group = WorldFxConfig.groupFor("A9_AstronautCrew", name)
			if string.sub(name, 1, 4) == "Wave" then
				ok(group == "@Wave", `A9_AstronautCrew.{name}: waves`)
			elseif name == "Flag" or name == "Stars" then
				ok(group == "@Flag", `A9_AstronautCrew.{name}: flutters`)
			else
				ok(group == nil, `A9_AstronautCrew.{name}: stays still (got {group})`)
			end
		end
	end
end

if failures > 0 then
	print(`[world-fx-swing] {failures} of {checks} checks failed`)
	process.exit(1)
end
print(`[world-fx-swing] {checks} checks passed`)
