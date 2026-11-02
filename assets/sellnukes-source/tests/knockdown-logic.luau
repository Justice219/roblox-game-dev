--!strict
--[[
	Area knockdown regressions (owner R50, Q3). Run:
		lune run tests/knockdown-logic

	Loads the REAL shipped modules (src/shared/Config/KnockdownConfig.luau,
	src/shared/Tycoon/KnockdownLogic.luau, src/server/Analytics/KeySpec.luau) through
	tests/fixtures/RobloxLoader and proves:
	  1. Duration: 45 s at launcher level 1, +3 s per level above 1, clamped to [45, 90]; junk
	     levels (NaN, ±inf, 0, negatives, fractions, strings) never escape the bounds.
	     clampDuration bounds any caller value (NaN / inf / huge / negative).
	  2. Deadlines: apply sets untilTime = now + duration; isDown / anyDown flip exactly at the
	     deadline; expire brings areas up only once their deadline passed, reuses its out array.
	  3. Immunity: a plot is immune while an area is down and for ImmunitySeconds after its LAST
	     area comes up (two areas → immunity counts from the later one); taps never shorten it;
	     admin clearImmunity / an immunity override of 0 work; the same area can never be re-knocked
	     while down.
	  4. Volley spill: the same attacker may knock ONE more area within VolleyGraceSeconds; another
	     attacker, a third area, a late spill or attacker 0 are refused "immune".
	  5. Taps: −TapSeconds each, never earlier than appliedAt + MinDownSeconds nor before now,
	     refused once at the floor / when not down; the tap counter only counts accepted taps;
	     at most ceil((duration − MinDown) / TapSeconds) taps are ever accepted.
	  6. resumeStart: the producer bar keeps the progress held at the pause (bounded to one cycle),
	     a cycle restarted during the pause has none.
	  7. formatClock + labels + analytics keys: every knock* key the server records passes
	     KeySpec for the "attack" family; junk keys are refused.
	  8. Fuzz: 20k random operations keep downCount == #areas, deadlines finite and ≥ appliedAt +
	     MinDownSeconds (or the full duration when shorter), immunity monotone between clears.
	  9. Dazed managers (NpcPose.dazed, every rig): finite pose, sits ≤ 3 studs, stays in place,
	     Biped legs straight out / Hover none, arms flopped out; the brain is never written.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local KnockdownConfig = loader.load("src/shared/Config/KnockdownConfig")
local KnockdownLogic = loader.load("src/shared/Tycoon/KnockdownLogic")
local KeySpec = loader.load("src/server/Analytics/KeySpec")

local checks = 0
local function ok(condition: any, label: string)
	if not condition then
		error(`FAIL: {label}`, 2)
	end
	checks += 1
end

local function near(a: number, b: number, label: string)
	ok(math.abs(a - b) < 1e-9, `{label} (got {a}, want {b})`)
end

local RULES = KnockdownLogic.rulesFromConfig(KnockdownConfig)
local NAN = 0 / 0

-- 1. Duration -------------------------------------------------------------------------------------
do
	ok(KnockdownConfig.duration(1) == 45, "level 1 = 45 s")
	ok(KnockdownConfig.duration(2) == 48, "level 2 = 48 s")
	ok(KnockdownConfig.duration(5) == 57, "level 5 = 57 s")
	ok(KnockdownConfig.duration(16) == 90, "level 16 = 90 s (cap)")
	ok(KnockdownConfig.duration(1000) == 90, "huge level capped at 90 s")
	for _, junk in { 0, -3, NAN, math.huge, -math.huge, 1.9, "5" :: any, nil :: any } do
		local seconds = KnockdownConfig.duration(junk)
		ok(seconds >= 45 and seconds <= 90 and seconds == seconds, `junk level {tostring(junk)} bounded`)
	end
	ok(KnockdownConfig.duration(1.9) == 45, "fractional level floors")
	for level = 1, 40 do
		local seconds = KnockdownConfig.duration(level)
		ok(seconds >= KnockdownConfig.duration(math.max(level - 1, 1)), "duration never decreases with level")
	end
	ok(KnockdownLogic.clampDuration(NAN, 5, 90) == 5, "NaN duration → min")
	ok(KnockdownLogic.clampDuration(math.huge, 5, 90) == 5, "inf duration → min (not finite)")
	ok(KnockdownLogic.clampDuration(1e12, 5, 90) == 90, "huge duration → max")
	ok(KnockdownLogic.clampDuration(-4, 5, 90) == 5, "negative duration → min")
	ok(KnockdownLogic.clampDuration("45" :: any, 5, 90) == 5, "string duration → min")
	ok(KnockdownLogic.clampDuration(60, 5, 90) == 60, "valid duration kept")
end

-- 2. Deadlines ------------------------------------------------------------------------------------
do
	local state = KnockdownLogic.newState()
	local entry = KnockdownLogic.apply(state, 3, 1000, 45, 7, "normal")
	ok(entry.untilTime == 1045 and entry.appliedAt == 1000 and entry.area == 3, "apply sets the deadline")
	ok(state.downCount == 1, "downCount 1")
	local down, untilTime = KnockdownLogic.isDown(state, 3, 1044.999)
	ok(down and untilTime == 1045, "down just before the deadline")
	ok(not KnockdownLogic.isDown(state, 3, 1045), "up exactly at the deadline")
	ok(not KnockdownLogic.isDown(state, 4, 1001), "other area not down")
	ok(KnockdownLogic.anyDown(state, 1010) and not KnockdownLogic.anyDown(state, 1046), "anyDown")
	local out = {}
	local result = KnockdownLogic.expire(state, 1044, RULES, out)
	ok(result == out and #out == 0 and state.downCount == 1, "nothing expires early")
	KnockdownLogic.expire(state, 1045, RULES, out)
	ok(#out == 1 and out[1].area == 3 and state.downCount == 0 and state.areas[3] == nil, "expires at the deadline")
	KnockdownLogic.expire(state, 1046, RULES, out)
	ok(#out == 0, "out cleared and nothing left")
end

-- 3. Immunity -------------------------------------------------------------------------------------
do
	local state = KnockdownLogic.newState()
	ok(not KnockdownLogic.isImmune(state, 0), "fresh state not immune")
	KnockdownLogic.apply(state, 2, 100, 45, 9, "normal")
	ok(KnockdownLogic.isImmune(state, 120), "immune while down")
	local allowed, reason = KnockdownLogic.check(state, 2, 120, 9, RULES)
	ok(not allowed and reason == "immune", "same area never re-knocked while down")
	allowed, reason = KnockdownLogic.check(state, 5, 140, 11, RULES)
	ok(not allowed and reason == "immune", "another attacker refused while down")
	-- Taps never shorten protection: rebuild early, immunity counts from the actual end.
	for _ = 1, 100 do
		KnockdownLogic.tap(state, 2, 110, RULES)
	end
	local out = {}
	KnockdownLogic.expire(state, 110, RULES, out)
	ok(#out == 1, "tapped area came up at the tap floor")
	near(state.immuneUntil, 110 + KnockdownConfig.ImmunitySeconds, "immunity starts when the area came up")
	ok(KnockdownLogic.isImmune(state, 110 + KnockdownConfig.ImmunitySeconds - 0.01), "immune until the end")
	ok(not KnockdownLogic.isImmune(state, 110 + KnockdownConfig.ImmunitySeconds), "immunity over")
	allowed = KnockdownLogic.check(state, 2, 110 + KnockdownConfig.ImmunitySeconds, 9, RULES)
	ok(allowed, "knockable again after immunity")
	-- Two areas (volley): immunity from the LATER one.
	local twin = KnockdownLogic.newState()
	KnockdownLogic.apply(twin, 1, 0, 45, 4, "barrage")
	ok(KnockdownLogic.check(twin, 2, 2, 4, RULES), "spill allowed")
	KnockdownLogic.apply(twin, 2, 2, 60, 4, "barrage")
	KnockdownLogic.expire(twin, 45, RULES, out)
	ok(#out == 1 and twin.immuneUntil == 0, "no immunity while another area is still down")
	ok(KnockdownLogic.isImmune(twin, 50), "still immune: area 2 down")
	KnockdownLogic.expire(twin, 62, RULES, out)
	near(twin.immuneUntil, 62 + KnockdownConfig.ImmunitySeconds, "immunity from the last area")
	-- Admin: clear immunity, override 0.
	KnockdownLogic.clearImmunity(twin)
	ok(not KnockdownLogic.isImmune(twin, 63), "clearImmunity")
	local zero = KnockdownLogic.rulesFromConfig(KnockdownConfig, 0)
	ok(zero.immunitySeconds == 0, "override 0 accepted")
	local quick = KnockdownLogic.newState()
	KnockdownLogic.apply(quick, 1, 0, 10, 1, "normal")
	KnockdownLogic.expire(quick, 10, zero, out)
	ok(KnockdownLogic.check(quick, 1, 10, 1, zero), "zero immunity: knockable straight away")
	ok(KnockdownLogic.rulesFromConfig(KnockdownConfig, NAN).immunitySeconds == 0, "NaN override → 0, never NaN")
	-- finish (admin force rebuild) follows the same rule.
	local forced = KnockdownLogic.newState()
	KnockdownLogic.apply(forced, 4, 0, 45, 1, "normal")
	local ended = KnockdownLogic.finish(forced, 4, 5, RULES)
	ok(ended ~= nil and ended.area == 4 and forced.downCount == 0, "finish ends the area")
	near(forced.immuneUntil, 5 + KnockdownConfig.ImmunitySeconds, "finish starts immunity")
	ok(KnockdownLogic.finish(forced, 4, 6, RULES) == nil, "finish twice is a no-op")
end

-- 4. Volley spill ---------------------------------------------------------------------------------
do
	local grace = KnockdownConfig.VolleyGraceSeconds
	local state = KnockdownLogic.newState()
	KnockdownLogic.apply(state, 3, 0, 45, 42, "barrage")
	ok(not KnockdownLogic.check(state, 4, 1, 43, RULES), "other attacker cannot spill")
	ok(not KnockdownLogic.check(state, 4, grace + 0.01, 42, RULES), "late spill refused")
	ok(KnockdownLogic.check(state, 4, grace, 42, RULES), "spill at the grace edge")
	KnockdownLogic.apply(state, 4, grace, 45, 42, "barrage")
	ok(state.volleyAreas == KnockdownConfig.VolleyMaxAreas, "volley at its cap")
	ok(not KnockdownLogic.check(state, 5, grace, 42, RULES), "third area refused (VolleyMaxAreas)")
	local anon = KnockdownLogic.newState()
	KnockdownLogic.apply(anon, 3, 0, 45, 0, "admin")
	ok(not KnockdownLogic.check(anon, 4, 1, 0, RULES), "attacker 0 never spills")
	-- A new volley starts only after everything is up (and immunity passed).
	local out = {}
	KnockdownLogic.expire(state, 1000, RULES, out)
	ok(state.volleyAreas == 0 and state.volleyAttacker == 0, "volley reset when the plot is up")
end

-- 5. Taps -----------------------------------------------------------------------------------------
do
	local state = KnockdownLogic.newState()
	KnockdownLogic.apply(state, 6, 100, 45, 3, "normal")
	local accepted, untilTime = KnockdownLogic.tap(state, 6, 101, RULES)
	ok(accepted and untilTime == 145 - KnockdownConfig.TapSeconds, "a tap moves the deadline by TapSeconds")
	ok(state.areas[6].taps == 1, "tap counted")
	local maxTaps = math.ceil((45 - KnockdownConfig.MinDownSeconds) / KnockdownConfig.TapSeconds)
	local count = 1
	for _ = 1, 500 do
		local moved = KnockdownLogic.tap(state, 6, 101, RULES)
		if moved then
			count += 1
		end
	end
	ok(count <= maxTaps, `taps bounded ({count} <= {maxTaps})`)
	near(state.areas[6].untilTime, 100 + KnockdownConfig.MinDownSeconds, "never earlier than appliedAt + MinDown")
	ok(state.areas[6].taps == count, "only accepted taps counted")
	ok(not KnockdownLogic.tap(state, 6, 102, RULES), "refused at the floor")
	ok(not KnockdownLogic.tap(state, 2, 102, RULES), "refused on an area that is not down")
	-- Floor is also `now`: a tap at the very end never sets a past deadline.
	local late = KnockdownLogic.newState()
	KnockdownLogic.apply(late, 1, 0, 45, 3, "normal")
	local moved, target = KnockdownLogic.tap(late, 1, 44.5, RULES)
	ok(moved and target == 44.5, "tap near the end clamps to now")
	ok(not KnockdownLogic.tap(late, 1, 45, RULES), "refused after the deadline")
	-- A duration shorter than MinDown: taps can never move it.
	local short = KnockdownLogic.newState()
	KnockdownLogic.apply(short, 1, 0, 5, 3, "normal")
	ok(not KnockdownLogic.tap(short, 1, 1, RULES), "short knockdown cannot be tapped below its length")
end

-- 6. resumeStart ----------------------------------------------------------------------------------
do
	near(KnockdownLogic.resumeStart(100, 10, 104, 150), 146, "keeps 4 s of progress")
	near(KnockdownLogic.resumeStart(100, 10, 125, 150), 140, "progress bounded to one cycle")
	near(KnockdownLogic.resumeStart(130, 10, 120, 150), 150, "cycle started during the pause has none")
	near(KnockdownLogic.resumeStart(100, 0, 104, 150), 150, "zero cycle time safe")
end

-- 7. Clock, labels, analytics keys ----------------------------------------------------------------
do
	ok(KnockdownLogic.formatClock(45) == "0:45", "0:45")
	ok(KnockdownLogic.formatClock(44.1) == "0:45", "rounds up")
	ok(KnockdownLogic.formatClock(61.2) == "1:02", "1:02")
	ok(KnockdownLogic.formatClock(0) == "0:00" and KnockdownLogic.formatClock(-3) == "0:00", "never negative")
	ok(KnockdownLogic.formatClock(NAN) == "0:00", "NaN safe")
	ok(KnockdownConfig.areaLabel(5) == "LAB", "area 5 label = LAB (owner example)")
	ok(#KnockdownConfig.AreaLabels == 10, "one label per area")
	ok(KnockdownConfig.areaLabel(11) == "AREA 11", "label fallback")
	ok(KnockdownLogic.remaining(10, 12) == 0 and KnockdownLogic.remaining(12, 10) == 2, "remaining")
	ok(#KeySpec.invalidPatterns() == 0, "every recorder pattern compiles")
	for area = 1, 10 do
		ok(KeySpec.check("attack", `knock:{area}`) == `knock:{area}`, `knock:{area} accepted`)
	end
	ok(KeySpec.check("attack", "knock:11") == nil, "knock:11 refused")
	for _, source in KnockdownConfig.Sources do
		ok(KeySpec.check("attack", `knockSrc:{source}`) ~= nil, `knockSrc:{source} accepted`)
	end
	ok(KeySpec.check("attack", "knockSrc:other") ~= nil, "knockSrc:other accepted")
	for _, reason in KnockdownConfig.BlockReasons do
		ok(KeySpec.check("attack", `knockBlocked:{reason}`) ~= nil, `knockBlocked:{reason} accepted`)
	end
	for _, reason in KnockdownConfig.EndReasons do
		ok(KeySpec.check("attack", `knockEnd:{reason}`) ~= nil, `knockEnd:{reason} accepted`)
	end
	ok(KeySpec.check("attack", "knockTap") ~= nil and KeySpec.check("attack", "knockSec") ~= nil, "tap / sec keys")
	ok(KeySpec.check("attack", "knockBlocked:hacked") == nil, "junk reason refused")
end

-- 8. Fuzz -----------------------------------------------------------------------------------------
do
	local random = Loader.Random.new(50)
	local state = KnockdownLogic.newState()
	local out = {}
	local t = 0
	local lastImmune = 0
	for _ = 1, 20000 do
		t += random:NextNumber(0, 3)
		local op = random:NextInteger(1, 5)
		local area = random:NextInteger(1, 10)
		if op == 1 then
			local attacker = random:NextInteger(0, 3)
			if KnockdownLogic.check(state, area, t, attacker, RULES) then
				local duration = KnockdownConfig.duration(random:NextInteger(1, 5))
				KnockdownLogic.apply(state, area, t, duration, attacker, "normal")
			end
		elseif op == 2 then
			KnockdownLogic.tap(state, area, t, RULES)
		elseif op == 3 then
			KnockdownLogic.expire(state, t, RULES, out)
		elseif op == 4 then
			KnockdownLogic.finish(state, area, t, RULES)
		else
			KnockdownLogic.check(state, area, t, random:NextInteger(0, 3), RULES)
		end
		local count = 0
		for _, entry in state.areas do
			count += 1
			ok(entry.untilTime == entry.untilTime and entry.untilTime < math.huge, "finite deadline")
			ok(
				entry.untilTime >= math.min(entry.appliedAt + KnockdownConfig.MinDownSeconds, entry.appliedAt + entry.duration) - 1e-9,
				"deadline never below the tap floor"
			)
		end
		ok(count == state.downCount, "downCount matches")
		ok(state.immuneUntil >= lastImmune, "immunity never moves backwards (no clears in the fuzz)")
		lastImmune = state.immuneUntil
		ok(state.volleyAreas <= KnockdownConfig.VolleyMaxAreas, "volley cap holds")
	end
end

-- 9. Dazed managers (NpcPose.dazed) ---------------------------------------------------------------
do
	local ManagerNpcConfig = loader.load("src/shared/Config/ManagerNpcConfig")
	local NpcBrain = loader.load("src/client/Tycoon/Npc/NpcBrain")
	local NpcPose = loader.load("src/client/Tycoon/Npc/NpcPose")
	local function finite(x: number): boolean
		return x == x and x > -math.huge and x < math.huge
	end
	for key, rig in ManagerNpcConfig.Rigs do
		local brain = NpcBrain.new(rig, ManagerNpcConfig.Motion, 11)
		local pose = NpcPose.new()
		local hover = rig.style == "Hover"
		local hip = if hover then 0.7 else (rig.joints.LegL or rig.joints.Torso).Y - rig.figure.base.Y - 0.45
		for step = 0, 120 do
			NpcPose.dazed(brain, pose, step / 30, hip)
			for field, value in pose do
				ok(finite(value), `{key} dazed {field} finite`)
			end
			ok(pose.y <= brain.y and pose.y >= brain.y - 3, `{key} sits within 3 studs`)
			ok(pose.x == brain.x and pose.z == brain.z and pose.yaw == brain.yaw, `{key} stays put`)
			if hover then
				ok(pose.legLPitch == 0, `{key} hover rig has no leg pose`)
			else
				ok(pose.legLPitch > math.rad(60) and pose.legRPitch > math.rad(60), `{key} legs straight out`)
			end
			ok(pose.armLRoll < 0 and pose.armRRoll > 0, `{key} arms flopped outward`)
		end
	end
	-- The brain is never written: the work loop resumes intact.
	local rig = ManagerNpcConfig.Rigs.A1_UncleAtom
	local brain = NpcBrain.new(rig, ManagerNpcConfig.Motion, 3)
	local before = table.clone(brain)
	NpcPose.dazed(brain, NpcPose.new(), 4.2, 1.5)
	for field, value in before do
		ok(brain[field] == value, `brain.{field} untouched`)
	end
end

print(`[knockdown-logic] {checks} checks passed`)
