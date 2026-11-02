--!strict
--[[
	Egg hatch cinematic timeline maths (src/client/Pets/HatchAnim.luau, owner R49). Run:
		lune run tests/hatch-anim

	Proves:
	  1. Config: a beat for every rarity, budgets per FX tier, positive durations, every sound
	     cue is a real AudioConfig.Sfx key (a typo would play silence).
	  2. Every timeline (7 rarities x fast x reduced x granted) has its phases in order, bursts that
	     grow in strength + speed inside the wobble window, three ascending crack stages on
	     bursts, and Mythic / Secret build up longer than Common.
	  3. No NaN / inf anywhere: every pose function swept at 240 Hz over the whole timeline (and
	     before / after it), opacities within 0..1, scales positive.
	  4. Curves: the squash stretches into the burst, the pet + banner springs overshoot and
	     settle at exactly 1, shards are hidden before the burst and gone after the flight, the
	     cap first rises, reduced motion is a pure cross-fade (no flash, no jitter, no motion).
	  5. Triple hatch: eggs pop in left to right, bursts follow rarity order with at least
	     MinBurstGap between them — the best rarity is revealed LAST for all 7^3 rank combos.
	  6. Tap: before the last burst = skip to it (its burst events still fire, every pet is
	     out), just after = wait, later = close.
	  7. Events: sorted, burst + rarity stinger present, wobble clacks rise in pitch.
]]

local Loader = require("./fixtures/RobloxLoader")
local roblox = require("@lune/roblox")

local Vector3 = roblox.Vector3

local loader = Loader.new()
local HatchAnim = loader.load("src/client/Pets/HatchAnim")
local HatchAnimConfig = loader.load("src/shared/Config/HatchAnimConfig")
local AudioConfig = loader.load("src/shared/Config/AudioConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local function finite(x: number): boolean
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

local function within01(x: number): boolean
	return finite(x) and x >= -1e-9 and x <= 1 + 1e-9
end

-- 1. Config ---------------------------------------------------------------------------------------

check(#HatchAnimConfig.Rarity == 7, "a beat for each of the 7 rarities")
for rank, beat in HatchAnimConfig.Rarity do
	check(beat.bursts >= 3, `rank {rank}: at least 3 bursts (3 crack stages)`)
	check(beat.glow > 0 and beat.glow <= 1, `rank {rank}: glow 0..1`)
	check(#beat.reveal >= 1, `rank {rank}: has a reveal stinger`)
	for _, cue in beat.reveal do
		local key = AudioConfig.Aliases[cue.key] or cue.key
		check(AudioConfig.Sfx[key] ~= nil, `rank {rank}: stinger "{cue.key}" is an AudioConfig.Sfx key`)
		check(cue.delay >= 0 and cue.pitch > 0 and cue.volume > 0, `rank {rank}: sane cue`)
	end
	if rank > 1 then
		local lower = HatchAnimConfig.Rarity[rank - 1]
		check(beat.confetti >= lower.confetti, `rank {rank}: confetti never shrinks with rarity`)
		check(beat.strength >= lower.strength, `rank {rank}: wobble never weaker with rarity`)
	end
	check(beat.dramatic == (rank >= 6), `rank {rank}: only Mythic / Secret are dramatic`)
	check(beat.chance == (rank >= HatchAnimConfig.ChanceFromRank), `rank {rank}: chance shown from Rare`)
end
for name, cue in HatchAnimConfig.Sounds do
	if type(cue) == "table" then
		local key = AudioConfig.Aliases[cue.key] or cue.key
		check(AudioConfig.Sfx[key] ~= nil, `build-up cue {name} "{cue.key}" is an AudioConfig.Sfx key`)
	end
end
for name, tier in HatchAnimConfig.Tiers do
	check(tier.shards >= 1 and tier.shards <= HatchAnimConfig.ShardCount, `tier {name}: shard budget`)
	check(tier.confetti > 0 and tier.confetti <= 1, `tier {name}: confetti multiplier`)
end
check(HatchAnimConfig.Tiers.Low.shards < HatchAnimConfig.Tiers.High.shards, "Low FX flies fewer shards")
check(
	HatchAnimConfig.Rarity[7].confetti * HatchAnimConfig.Tiers.High.confetti <= HatchAnimConfig.Confetti.Pool,
	"the confetti pool covers the biggest burst"
)
for name, profile in HatchAnimConfig.Profiles do
	for field, value in profile do
		check(finite(value) and value > 0, `profile {name}.{field} positive`)
	end
end
check(HatchAnimConfig.Light.FlashPeak <= 0.7, "owner R19: the flash is soft (peak opacity <= 0.7)")

-- 2 + 3 + 4. Every timeline ----------------------------------------------------------------------

local Shell = HatchAnimConfig.Shell
local Egg = HatchAnimConfig.Egg

local function sweep(tl: any, label: string)
	local t = -1
	local stop = tl.done + 2
	local sawPetOvershoot = false
	while t <= stop do
		local pose = HatchAnim.eggPose(tl, t)
		for _, field in { "scale", "sxz", "sy", "roll", "lean", "y" } do
			check(finite(pose[field]), `{label}: eggPose.{field} finite at {t}`)
		end
		check(pose.scale > 0 and pose.sy > 0 and pose.sxz > 0, `{label}: egg scales positive at {t}`)
		check(within01(pose.fade), `{label}: egg fade 0..1 at {t}`)
		for _, motion in
			{ HatchAnim.cap(tl, t), HatchAnim.cup(tl, t), HatchAnim.shard(tl, t, 3, Vector3.new(1, 0, -1)) }
		do
			check(
				finite(motion.offset.X) and finite(motion.offset.Y) and finite(motion.offset.Z),
				`{label}: motion offset finite`
			)
			check(finite(motion.rx) and finite(motion.ry) and finite(motion.rz), `{label}: motion spin finite`)
			check(motion.scale > 0 and within01(motion.fade), `{label}: motion scale / fade`)
		end
		for stage = 1, 3 do
			check(within01(HatchAnim.crack(tl, t, stage)), `{label}: crack {stage} opacity`)
		end
		check(within01(HatchAnim.crackGlow(tl, t)), `{label}: crack glow 0..1`)
		check(within01(HatchAnim.halo(tl, t)), `{label}: halo 0..1`)
		local rayOpacity, rayScale, rayRotation = HatchAnim.rays(tl, t)
		check(within01(rayOpacity) and finite(rayScale) and rayScale > 0 and finite(rayRotation), `{label}: rays`)
		check(within01(HatchAnim.flash(tl, t)), `{label}: flash 0..1`)
		check(within01(HatchAnim.wash(tl, t)), `{label}: wash 0..1`)
		check(within01(HatchAnim.dim(tl, t)), `{label}: dim 0..1`)
		check(within01(HatchAnim.ambient(tl, t)), `{label}: ambient 0..1`)
		local dx, dy = HatchAnim.jitter(tl, t)
		check(finite(dx) and finite(dy) and math.abs(dx) <= 10 and math.abs(dy) <= 10, `{label}: jitter bounded`)
		local pet = HatchAnim.pet(tl, t)
		check(finite(pet.scale) and pet.scale > 0 and finite(pet.y) and within01(pet.fade), `{label}: pet pose`)
		if pet.scale > 1.02 then
			sawPetOvershoot = true
		end
		local banner = HatchAnim.banner(tl, t)
		check(finite(banner.scale) and banner.scale > 0 and within01(banner.fade), `{label}: banner pose`)
		t += 1 / 240
	end
	-- NaN input never leaks out.
	local nanPose = HatchAnim.eggPose(tl, 0 / 0)
	check(nanPose.visible == false, `{label}: NaN time hides the egg`)
	check(within01(HatchAnim.flash(tl, 0 / 0)) and within01(HatchAnim.halo(tl, 0 / 0)), `{label}: NaN-safe light`)
	return sawPetOvershoot
end

local totals: { [string]: number } = {}
for rank = 1, 7 do
	for _, fast in { false, true } do
		for _, reduced in { false, true } do
			for _, granted in { false, true } do
				local label = `rank {rank} fast={fast} reduced={reduced} granted={granted}`
				local tl = HatchAnim.build({ rank = rank, fast = fast, reduced = reduced, granted = granted })
				-- Phase order.
				check(tl.start <= tl.introEnd, `{label}: intro`)
				check(tl.introEnd <= tl.wobbleStart, `{label}: idle`)
				check(tl.wobbleStart <= tl.wobbleEnd, `{label}: wobble`)
				check(tl.wobbleEnd <= tl.squashStart, `{label}: squash after wobble`)
				check(tl.squashStart <= tl.burst, `{label}: burst after squash`)
				check(tl.burst < tl.popEnd, `{label}: pop after burst`)
				check(tl.burst <= tl.banner and tl.banner < tl.bannerEnd, `{label}: banner after burst`)
				check(tl.popEnd <= tl.done and tl.bannerEnd <= tl.done and tl.flyEnd <= tl.done, `{label}: done last`)
				if not granted and not reduced then
					check(#tl.bursts >= 3, `{label}: at least 3 bursts`)
					check(#tl.cracks == 3, `{label}: three crack stages`)
					local previous = tl.wobbleStart
					for index, b in tl.bursts do
						check(b.start >= previous - 1e-9 and b.finish > b.start, `{label}: burst {index} in order`)
						check(b.finish <= tl.wobbleEnd + 1e-9, `{label}: burst {index} inside the wobble`)
						if index > 1 then
							local before = tl.bursts[index - 1]
							check(b.amp > before.amp, `{label}: burst {index} stronger`)
							check(b.freq > before.freq, `{label}: burst {index} faster`)
						end
						previous = b.finish
					end
					for stage = 1, 3 do
						local at = tl.cracks[stage]
						check(at >= tl.wobbleStart and at < tl.wobbleEnd, `{label}: crack {stage} during the wobble`)
						if stage > 1 then
							check(at > tl.cracks[stage - 1], `{label}: crack {stage} after {stage - 1}`)
						end
						check(HatchAnim.crack(tl, at - 0.01, stage) == 0, `{label}: crack {stage} hidden before`)
						check(HatchAnim.crack(tl, at + 0.2, stage) == 1, `{label}: crack {stage} shown after`)
					end
					check(HatchAnim.crack(tl, tl.burst + 0.01, 3) == 0, `{label}: cracks gone at the burst`)
					-- The squash stretches into the burst.
					local stretched = HatchAnim.eggPose(tl, tl.burst - 0.001)
					check(math.abs(stretched.sy - Egg.StretchScale) < 0.02, `{label}: stretched at the burst`)
					local crouched = HatchAnim.eggPose(tl, tl.squashStart + (tl.burst - tl.squashStart) * Egg.CrouchAt)
					check(math.abs(crouched.sy - Egg.CrouchScale) < 0.02, `{label}: crouched mid-squash`)
					-- Shell pieces.
					check(
						HatchAnim.shard(tl, tl.burst - 0.01, 1, Vector3.new(0, 0, -1)).fade == 1,
						`{label}: shard hidden before`
					)
					check(
						HatchAnim.shard(tl, tl.burst + 0.01, 1, Vector3.new(0, 0, -1)).fade == 0,
						`{label}: shard shown at burst`
					)
					check(
						HatchAnim.shard(tl, tl.burst + tl.speed.Fly + 0.01, 1, Vector3.new(0, 0, -1)).fade == 1,
						`{label}: shard gone`
					)
					check(HatchAnim.cap(tl, tl.burst + 0.05).offset.Y > 0, `{label}: the cap first rises`)
					check(HatchAnim.cap(tl, tl.burst + 5).fade == 1, `{label}: the cap is gone later`)
					check(HatchAnim.cup(tl, tl.burst + 5).fade == 1, `{label}: the cup is gone later`)
					check(HatchAnim.eggPose(tl, tl.start + 0.001).scale < 0.5, `{label}: intro starts small`)
					check(
						HatchAnim.flash(tl, tl.burst + HatchAnimConfig.Light.FlashRise) > 0.5,
						`{label}: flash at the burst`
					)
				end
				if reduced then
					check(#tl.bursts == 0 and #tl.cracks == 0, `{label}: no shaking`)
					local mid = (tl.burst + tl.popEnd) / 2
					check(HatchAnim.flash(tl, mid) == 0, `{label}: no flash`)
					local dx, dy = HatchAnim.jitter(tl, mid)
					check(dx == 0 and dy == 0, `{label}: no jitter`)
					local egg = HatchAnim.eggPose(tl, mid)
					local pet = HatchAnim.pet(tl, mid)
					check(egg.roll == 0 and egg.y == 0 and egg.sy == 1, `{label}: the egg stays still`)
					check(pet.scale == 1 and pet.y == 0, `{label}: the pet does not bounce`)
					if not granted then
						check(math.abs(egg.fade + pet.fade - 1) < 1e-6, `{label}: a true cross-fade`)
					end
					check(HatchAnim.pet(tl, tl.popEnd).fade == 0, `{label}: the pet ends fully shown`)
				end
				if granted then
					check(not HatchAnim.eggPose(tl, tl.burst - 0.01).visible, `{label}: no egg for a grant`)
				end
				local overshoot = sweep(tl, label)
				if not reduced then
					check(overshoot, `{label}: the pet springs past its size`)
					check(HatchAnim.pet(tl, tl.popEnd).scale == 1, `{label}: the pet settles at exactly 1`)
					check(HatchAnim.banner(tl, tl.bannerEnd).scale == 1, `{label}: the banner settles at exactly 1`)
				end
				totals[label] = tl.done
			end
		end
	end
end

local common = HatchAnim.build({ rank = 1, fast = false, reduced = false, granted = false })
local mythic = HatchAnim.build({ rank = 6, fast = false, reduced = false, granted = false })
local secret = HatchAnim.build({ rank = 7, fast = false, reduced = false, granted = false })
check(
	mythic.burst - mythic.wobbleStart > (common.burst - common.wobbleStart) + 0.5,
	"Mythic builds up clearly longer than Common"
)
check(
	secret.beat.dramatic and HatchAnim.dim(secret, secret.burst - 0.01) < HatchAnim.dim(common, common.burst - 0.01),
	"dramatic eggs darken the room"
)
do
	local dx = HatchAnim.jitter(secret, secret.burst - 0.05)
	local cx = HatchAnim.jitter(common, common.burst - 0.05)
	check(dx ~= 0 and cx == 0, "only dramatic eggs jitter during the build-up")
end
for rank = 1, 7 do
	local normal = totals[`rank {rank} fast=false reduced=false granted=false`]
	local fast = totals[`rank {rank} fast=true reduced=false granted=false`]
	local reduced = totals[`rank {rank} fast=false reduced=true granted=false`]
	check(fast < normal, `rank {rank}: fast hatch is shorter`)
	check(reduced < normal, `rank {rank}: reduced motion is shorter`)
end
check(HatchAnim.spring(0.5, 5.5, 11) ~= HatchAnim.spring(0.6, 5.5, 11), "the spring moves")
check(HatchAnim.spring(-1, 5.5, 11) == 0 and HatchAnim.spring(2, 5.5, 11) == 1, "spring clamps")

-- 5. Triple stagger ------------------------------------------------------------------------------

check(table.concat(HatchAnim.revealOrder({ 5, 1, 3 }), ",") == "2,3,1", "reveal order by rarity")
check(table.concat(HatchAnim.revealOrder({ 4, 4, 4 }), ",") == "1,2,3", "ties reveal left to right")
for _, fast in { false, true } do
	for _, reduced in { false, true } do
		local options = { fast = fast, reduced = reduced, granted = false }
		local gap = (if fast then HatchAnimConfig.Profiles.Fast else HatchAnimConfig.Profiles.Normal).MinBurstGap
		for a = 1, 7 do
			for b = 1, 7 do
				for c = 1, 7 do
					local ranks = { a, b, c }
					local timelines = HatchAnim.schedule(ranks, options)
					check(#timelines == 3, "three timelines")
					check(
						timelines[1].start <= timelines[2].start and timelines[2].start <= timelines[3].start,
						"pop in left to right"
					)
					local order = HatchAnim.revealOrder(ranks)
					for k = 2, 3 do
						local before, after = timelines[order[k - 1]], timelines[order[k]]
						check(after.burst - before.burst >= gap - 1e-9, `bursts {a}{b}{c} at least MinBurstGap apart`)
					end
					-- The best rarity bursts last.
					local best, bestBurst = 0, -1
					for index, tl in timelines do
						check(tl.burst <= HatchAnim.lastBurst(timelines), "lastBurst is the latest")
						if tl.rank > best or (tl.rank == best and tl.burst > bestBurst) then
							best, bestBurst = tl.rank, tl.burst
						end
						check(tl.done <= HatchAnim.total(timelines), "total covers every slot")
						check(tl.bursts[1] == nil or tl.bursts[1].start >= tl.introEnd, "build-up after the intro")
						local _ = index
					end
					check(bestBurst == HatchAnim.lastBurst(timelines), `best rarity of {a}{b}{c} revealed last`)
				end
			end
		end
	end
end
local single = HatchAnim.schedule({ 3 }, { fast = false, reduced = false, granted = false })
check(#single == 1 and single[1].start == 0, "a single hatch starts at once")

-- 6. Tap -----------------------------------------------------------------------------------------

for _, options in
	{
		{ fast = false, reduced = false, granted = false },
		{ fast = true, reduced = false, granted = false },
		{ fast = false, reduced = true, granted = false },
		{ fast = false, reduced = false, granted = true },
	}
do
	local timelines = HatchAnim.schedule({ 2, 6, 4 }, options)
	local last = HatchAnim.lastBurst(timelines)
	local action, nextT = HatchAnim.onTap(timelines, 0)
	check(action == "skip" and nextT < last and last - nextT < 0.01, "an early tap skips to the last burst")
	for _, tl in timelines do
		check(HatchAnim.pet(tl, nextT + 0.01).visible, "after a skip every pet is out")
	end
	-- The skipped-to burst still fires its events (sound / confetti / haptic).
	local fired = false
	for _, event in HatchAnim.events(timelines[2]) do
		if event.kind == "haptic" and event.time >= nextT then
			fired = true
		end
	end
	check(fired, "the last burst's events fire after a skip")
	local again = HatchAnim.onTap(timelines, last + 0.01)
	check(again == "wait", "a tap right after the reveal is ignored")
	local speed = timelines[1].speed
	local close = HatchAnim.onTap(timelines, last + speed.MinReveal + 0.01)
	check(close == "close", "a later tap continues")
	local nanAction = HatchAnim.onTap(timelines, 0 / 0)
	check(nanAction == "skip", "a NaN clock still skips safely")
end

-- 7. Events --------------------------------------------------------------------------------------

for rank = 1, 7 do
	for _, reduced in { false, true } do
		local tl = HatchAnim.build({ rank = rank, fast = false, reduced = reduced, granted = false })
		local events = HatchAnim.events(tl)
		local previous = -math.huge
		local burstSound, haptic, confetti = false, false, false
		local wobblePitch = -math.huge
		local stinger = 0
		for _, event in events do
			check(event.time >= previous, `rank {rank}: events sorted`)
			previous = event.time
			check(finite(event.time) and finite(event.pitch) and finite(event.volume), `rank {rank}: finite event`)
			if event.kind == "sound" then
				local key = AudioConfig.Aliases[event.key] or event.key
				check(AudioConfig.Sfx[key] ~= nil, `rank {rank}: event sound "{event.key}" exists`)
				if event.key == HatchAnimConfig.Sounds.Burst.key and event.time == tl.burst then
					burstSound = true
				end
				if event.key == HatchAnimConfig.Sounds.Wobble.key and event.time < tl.squashStart then
					local isCrack = false
					for _, at in tl.cracks do
						if at == event.time then
							isCrack = true
						end
					end
					if not isCrack then
						check(event.pitch > wobblePitch, `rank {rank}: wobble clacks rise in pitch`)
						wobblePitch = event.pitch
					end
				end
				if event.time >= tl.burst then
					stinger += 1
				end
			elseif event.kind == "haptic" then
				haptic = true
			elseif event.kind == "confetti" then
				confetti = true
			end
		end
		check(haptic, `rank {rank}: haptic at the reveal`)
		check(stinger >= #tl.beat.reveal, `rank {rank}: every stinger cue scheduled`)
		if not reduced then
			check(burstSound and confetti, `rank {rank}: burst sound + confetti`)
		else
			check(not confetti, `rank {rank}: reduced motion skips the confetti`)
		end
	end
end

print(`[hatch-anim] {checks} checks passed`)
