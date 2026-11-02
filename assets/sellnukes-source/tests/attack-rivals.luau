--!strict
--[[
	Attack mode — Rival Factories (owner R43) + the Q2 security fixes. Run:
		lune run tests/attack-rivals            (from the repo root)
		ATTACK_REPORT=1 lune run tests/attack-rivals   (also prints the rival intercept / reward table)

	Proves on the shipped modules (Shared/Attack/{AttackLogic, AttackGeometry, FlightMath, AttackRng,
	RivalLayout}, Shared/Config/{AttackConfig, WorldLayout, MeshAssets, AreaLayouts/*},
	Server/Attack/AttackProfile) and the shipped server sources:
	  1. Config: 3-4 rivals, unique wire-safe ids, kid-friendly names, an AA / reward / shield
	     ladder, every reward ratio <= MaxRewardRatio < 1, shields shorter than their cycle.
	  2. Placement: every island model (area set + plinth + sign + dressing) exists in MeshAssets,
	     stands outside the main island's boundary ring and inside the sea, never on a plot or the
	     hub, and the islands never overlap each other; the island centre is Radius from the hub.
	  3. Geometry: target slots (plots, then islands) round-trip; impacts land on the rival's floor
	     inside its base; the picker camera sits between the island and the hub, above it.
	  4. Flights: from every plot / silo to every rival impact point the flight time is in bounds
	     and the rival's tower can engage it at EVERY AA level (no useless towers); the intercept
	     rate climbs with the rival ladder.
	  5. Rewards: a rival hit always pays less than the same hit on an equal-income player, never
	     pays for "revenge", is 0 for hostile input and scales with the attacker's own income.
	  6. Rules: rivals go through AttackLogic.canLaunch unchanged (console, cooldown, barrage,
	     shield cycle; revenge refused); the wire-id allowlist rejects everything else; the shield
	     cycle is deterministic and at least one rival is always open; picker order = eligible
	     players → greyed players → rivals.
	  7. Security fixes: the free shield never passes MaxShieldSeconds (freeShieldFits); Barrage is
	     refused at PROMPT time when the pack would not fit (barrageFits) and a granted receipt is
	     never clamped (AttackProfile.addBarrage: whole pack or nothing, storage bound only).
	  8. Sources: AttackService / DefenseService connect their remotes through Remotes.onServerEvent
	     (departed-player guard), and no AFK protection or Studio dummy seam remains anywhere.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local AttackConfig = loader.load("src/shared/Config/AttackConfig")
local AttackGeometry = loader.load("src/shared/Attack/AttackGeometry")
local AttackLogic = loader.load("src/shared/Attack/AttackLogic")
local AttackRng = loader.load("src/shared/Attack/AttackRng")
local FlightMath = loader.load("src/shared/Attack/FlightMath")
local RivalLayout = loader.load("src/shared/Attack/RivalLayout")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local AttackProfile = loader.load("src/server/Attack/AttackProfile")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local nan = 0 / 0
local inf = math.huge
local RIVALS = AttackConfig.Rivals
-- Position tolerance in studs (Roblox CFrames are single precision; islands sit ~1000 studs out).
local EPS = 0.01
local FLIGHT = AttackConfig.Flight
-- HubLayout: the invisible boundary ring (WALL_R) and the far edge of the sea (Scenery_Water).
local WALL_R = 880
local SEA_R = 2000

-- Horizontal distance from the hub centre.
local function radius(point: any): number
	return math.sqrt(point.X * point.X + point.Z * point.Z)
end

--[[
	A model's horizontal reach around its pivot (studs): the farthest piece corner in MeshAssets,
	so clearance checks cover the whole model, not just its pivot.
]]
local function reachOf(key: string): number
	local asset = MeshAssets[key]
	local reach = 0
	if type(asset) == "table" and type(asset.pieces) == "table" then
		for _, piece in asset.pieces do
			local offset, size = piece.offset, piece.size
			local x = math.abs(offset.X) + size.X / 2
			local z = math.abs(offset.Z) + size.Z / 2
			reach = math.max(reach, math.sqrt(x * x + z * z))
		end
	end
	return reach
end

-- The rival's area layout table (Shared/Config/AreaLayouts/AreaNN).
local function layoutOf(area: number): any
	return loader.load(string.format("src/shared/Config/AreaLayouts/Area%02d", area))
end

--------------------------------------------------------------------------------------------------
-- 1. Config
--------------------------------------------------------------------------------------------------

do
	local count = #RIVALS.List
	check(count >= 3 and count <= 4, "rivals: 3-4 Rival Factories (R43)")
	check(WorldLayout.PlotCount + count <= 64, "rivals: slots fit the NukeFlight toPlot range")
	check(RIVALS.MaxRewardRatio > 0 and RIVALS.MaxRewardRatio < 1, "rivals: max reward ratio below a player hit")
	local ids: { [string]: boolean } = {}
	local previous: any = nil
	for index, rival in RIVALS.List do
		check(type(rival.id) == "string" and string.match(rival.id, "^[a-z_]+$") ~= nil, `rival {index}: wire-safe id`)
		check(#rival.id <= 32 and not ids[rival.id], `rival {index}: unique id <= 32`)
		ids[rival.id] = true
		check(type(rival.name) == "string" and #rival.name >= 4 and #rival.name <= 32, `rival {index}: name`)
		check(rival.aa >= 1 and rival.aa <= AttackConfig.MaxLevel and rival.aa % 1 == 0, `rival {index}: AA level`)
		check(rival.rewardRatio > 0 and rival.rewardRatio <= RIVALS.MaxRewardRatio, `rival {index}: reward ratio`)
		check(rival.area >= 1 and rival.area <= WorldLayout.AreaCount, `rival {index}: area set`)
		local shield = rival.shield
		check(shield.every >= 0 and shield.lasts >= 0 and shield.offset >= 0, `rival {index}: shield numbers`)
		check(shield.every == 0 or (shield.lasts > 0 and shield.lasts < shield.every), `rival {index}: shield < cycle`)
		if previous ~= nil then
			-- The ladder (owner rule: harder targets show bigger numbers, never smaller).
			check(rival.aa >= previous.aa and rival.rewardRatio > previous.rewardRatio, `rival {index}: ladder climbs`)
		end
		previous = rival
		check(
			AttackLogic.rivalIndex(rival.id) == index and AttackLogic.RivalIds[index] == rival.id,
			`rival {index}: ids`
		)
	end
	-- The easiest rival never shields, so Attack mode is ALWAYS usable.
	check(RIVALS.List[1].shield.every == 0, "rivals: the first rival is never shielded")
end

--------------------------------------------------------------------------------------------------
-- 2. Placement (islands just off the map edge, clear of everything)
--------------------------------------------------------------------------------------------------

do
	local centres: { any } = {}
	for index, rival in RIVALS.List do
		local frame = AttackGeometry.rivalFrame(index)
		local centre = frame * RIVALS.Centre
		check(math.abs(radius(centre) - RIVALS.Radius) < EPS, `rival {index}: centre at Radius`)
		table.insert(centres, centre)
		local placements = RivalLayout.island(index, layoutOf(rival.area))
		check(#placements >= 15, `rival {index}: a full base ({#placements} models)`)
		local hasPlinth, hasSign = false, false
		for _, placement in placements do
			check(MeshAssets[placement.key] ~= nil, `rival {index}: {placement.key} is a Blender mesh`)
			check(RIVALS.SkipKeys[placement.key] ~= true or placement.key == "A7_AATower", `rival {index}: skip list`)
			hasPlinth = hasPlinth or placement.key == "A7_AATower"
			hasSign = hasSign or placement.key == RIVALS.SignKey
			local world = (frame * placement.cf).Position
			local reach = reachOf(placement.key)
			-- Outside the boundary ring (with clearance), inside the sea.
			check(radius(world) - reach > WALL_R + 20, `rival {index}: {placement.key} off the map edge`)
			check(radius(world) + reach < SEA_R - 50, `rival {index}: {placement.key} inside the sea`)
			-- Never on (or overhanging) a plot.
			for plot = 1, WorldLayout.PlotCount do
				local p = WorldLayout.plotOrigin(plot):PointToObjectSpace(world)
				local onPlot = math.abs(p.X) < WorldLayout.PlotHalfWidth + reach + 40
					and p.Z > -reach - 40
					and p.Z < WorldLayout.PlotLength + reach + 40
				check(not onPlot, `rival {index}: {placement.key} clear of plot {plot}`)
			end
			-- Every base model stays on its island (within 110 studs of the centre).
			check((world - centre).Magnitude < 110, `rival {index}: {placement.key} on its island`)
		end
		check(hasPlinth and hasSign, `rival {index}: AA plinth + entrance sign`)
		-- The plinth / tower spot is inside the base footprint.
		check(
			math.abs(rival.tower.X) <= 52 - 7 and rival.tower.Z >= 7 and rival.tower.Z <= 70 - 7,
			`rival {index}: tower on the base`
		)
	end
	for a = 1, #centres do
		for b = a + 1, #centres do
			check((centres[a] - centres[b]).Magnitude > 2 * 120, `rivals {a}/{b}: islands never overlap`)
		end
	end
	-- The area-set reader ignores junk.
	check(
		#RivalLayout.areaSet(nil) == 0 and #RivalLayout.areaSet({ base = { models = { { key = 5 } } } }) == 0,
		"areaSet: junk"
	)
end

--------------------------------------------------------------------------------------------------
-- 3. Geometry (target slots)
--------------------------------------------------------------------------------------------------

do
	check(AttackGeometry.slotCount() == WorldLayout.PlotCount + #RIVALS.List, "slots: plots + rivals")
	check(
		AttackGeometry.validTarget(0) == nil and AttackGeometry.validTarget(AttackGeometry.slotCount() + 1) == nil,
		"slots: range"
	)
	check(AttackGeometry.validTarget(1.5) == nil and AttackGeometry.validTarget(nan) == nil, "slots: whole numbers")
	check(AttackGeometry.validPlot(WorldLayout.PlotCount + 1) == nil, "slots: a rival slot is not a plot")
	for plot = 1, WorldLayout.PlotCount do
		check(AttackGeometry.rivalOfSlot(plot) == nil, "slots: plots are not rivals")
	end
	for index, rival in RIVALS.List do
		local slot = AttackGeometry.rivalSlot(index)
		check(
			AttackGeometry.rivalOfSlot(slot) == index and AttackGeometry.validTarget(slot) == slot,
			`rival {index}: slot`
		)
		check(AttackGeometry.impactCount(slot) == #RIVALS.ImpactPoints, `rival {index}: impact count`)
		local frame = AttackGeometry.rivalFrame(index)
		for impact = 1, AttackGeometry.impactCount(slot) do
			local point = AttackGeometry.impactPoint(slot, impact)
			local localPoint = frame:PointToObjectSpace(point)
			check(math.abs(localPoint.Y - rival.floor) < EPS, `rival {index}: impact {impact} on the floor`)
			check(
				math.abs(localPoint.X) <= 52 and localPoint.Z >= 0 and localPoint.Z <= 70,
				`rival {index}: impact on base`
			)
			check(WorldLayout.plotAt(point) == nil, `rival {index}: impact is not on a plot`)
		end
		local mount = AttackGeometry.towerMount(slot)
		check(
			(frame:PointToObjectSpace(mount.Position) - (rival.tower + Vector3.new(0, RIVALS.TowerMountY, 0))).Magnitude
				< EPS,
			`rival {index}: turret on the plinth top`
		)
		local eye, focus = AttackGeometry.pickerView(slot)
		check(radius(eye) < radius(focus) and eye.Y > focus.Y + 100, `rival {index}: picker camera above, hub side`)
		check((focus - frame * RIVALS.Centre).Magnitude < EPS, `rival {index}: picker looks at the island`)
		local dome, size = AttackGeometry.shield(slot)
		check(
			(dome.Position - frame * Vector3.new(RIVALS.ShieldCentre.X, rival.floor, RIVALS.ShieldCentre.Z)).Magnitude
				< EPS,
			`rival {index}: dome`
		)
		check(size.X >= 104 and size.Z >= 70, `rival {index}: dome covers the base`)
	end
	-- Plots are unchanged.
	local eye, focus = AttackGeometry.pickerView(1)
	check(
		(focus - WorldLayout.plotOrigin(1) * AttackConfig.Client.PickerFocus).Magnitude < EPS,
		"plot picker focus unchanged"
	)
	check(eye.Y > focus.Y, "plot picker eye above")
end

--------------------------------------------------------------------------------------------------
-- 4. Flights + interception
--------------------------------------------------------------------------------------------------

local function rivalInterceptRate(index: number, launcherLevel: number, trials: number): number
	local rival = RIVALS.List[index]
	local aa = AttackConfig.AA[rival.aa]
	local slot = AttackGeometry.rivalSlot(index)
	local armor = AttackConfig.Launcher[launcherLevel].armor
	local intercepted, total, seed = 0, 0, 0
	for fromPlot = 1, WorldLayout.PlotCount do
		for impact = 1, AttackGeometry.impactCount(slot) do
			local flight = AttackGeometry.flight(fromPlot, 1, slot, impact)
			local from, to = FlightMath.engageWindow(flight, AttackGeometry.muzzle(slot), aa.range)
			for _ = 1, trials do
				seed += 1
				total += 1
				if from ~= nil and to ~= nil then
					local result = FlightMath.engage({
						windowFrom = from,
						windowTo = to,
						reload = aa.reload,
						chance = aa.chance,
						armor = armor,
						towerFreeAt = -inf,
						rng = AttackRng.new(AttackRng.mix(4242, seed)),
					})
					if result.intercepted then
						intercepted += 1
					end
				end
			end
		end
	end
	return intercepted / total
end

do
	for index in RIVALS.List do
		local slot = AttackGeometry.rivalSlot(index)
		for fromPlot = 1, WorldLayout.PlotCount do
			for silo = 1, 3 do
				for impact = 1, AttackGeometry.impactCount(slot) do
					local flight = AttackGeometry.flight(fromPlot, silo, slot, impact)
					check(
						flight.duration >= FLIGHT.MinSeconds and flight.duration <= FLIGHT.MaxSeconds,
						`rival {index}: flight time in bounds`
					)
					check(
						(flight.to - AttackGeometry.impactPoint(slot, impact)).Magnitude < EPS,
						`rival {index}: lands on impact`
					)
					for level = 1, AttackConfig.MaxLevel do
						local from, to =
							FlightMath.engageWindow(flight, AttackGeometry.muzzle(slot), AttackConfig.AA[level].range)
						check(from ~= nil and to ~= nil, `rival {index}: AA{level} engages from plot {fromPlot}`)
					end
				end
			end
		end
	end
	local rates: { number } = {}
	for index in RIVALS.List do
		rates[index] = rivalInterceptRate(index, 1, 40)
		check(rates[index] > 0.05 and rates[index] < 0.95, `rival {index}: intercept rate sane ({rates[index]})`)
		if index > 1 then
			check(rates[index] > rates[index - 1], `rival {index}: harder than rival {index - 1}`)
		end
	end
	if process.env.ATTACK_REPORT == "1" then
		print("[attack-rivals] rival | AA | intercept vs L1 | reward ratio | shield")
		for index, rival in RIVALS.List do
			print(
				string.format(
					"  %-22s AA%d  %5.1f %%   %.2f   %s",
					rival.name,
					rival.aa,
					rates[index] * 100,
					rival.rewardRatio,
					if rival.shield.every > 0 then `{rival.shield.lasts}s / {rival.shield.every}s` else "never"
				)
			)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- 5. Rewards
--------------------------------------------------------------------------------------------------

do
	for index, rival in RIVALS.List do
		for level = 1, AttackConfig.MaxLevel do
			for _, mega in { false, true } do
				for _, income in { 0, 1, 37, 1e6, 3.3e15 } do
					for _, kind in { "normal", "barrage" } do
						local rivalCash = AttackLogic.rivalReward(kind, level, index, income, mega)
						local playerCash = AttackLogic.reward(kind, level, income, income, mega)
						check(rivalCash >= 0 and rivalCash == rivalCash, `rival {index}: reward finite`)
						check(
							rivalCash <= playerCash * RIVALS.MaxRewardRatio * (1 + 1e-12),
							`rival {index}: L{level} {kind} pays less than an equal player`
						)
						if income > 0 then
							check(rivalCash < playerCash, `rival {index}: strictly smaller`)
						end
					end
				end
			end
		end
		check(AttackLogic.rivalReward("revenge", 3, index, 1e6, true) == 0, `rival {index}: no revenge reward`)
		local expected = AttackConfig.Launcher[1].rewardSeconds * 1000 * rival.rewardRatio
		check(
			math.abs(AttackLogic.rivalReward("normal", 1, index, 1000, false) - expected) < 1e-9,
			`rival {index}: formula`
		)
	end
	check(AttackLogic.rivalReward("normal", 1, 99, 1000, false) == 0, "reward: unknown rival")
	check(AttackLogic.rivalReward("normal", 0, 1, 1000, false) == 0, "reward: no launcher")
	check(AttackLogic.rivalReward("normal", 1, 1, nan, false) == 0, "reward: NaN income")
	check(AttackLogic.rivalReward("normal", 1, 1, -5, false) == 0, "reward: negative income")
	check(AttackLogic.rivalReward("bogus" :: any, 1, 1, 1000, false) == 0, "reward: unknown kind")
end

--------------------------------------------------------------------------------------------------
-- 6. Rules: allowlist, shield cycle, canLaunch, picker order
--------------------------------------------------------------------------------------------------

do
	for _, bad in { "", "Toy_Factory", "toy_factory ", "x", string.rep("a", 500), 1, nan, true, {}, nil } do
		check(AttackLogic.rivalIndex(bad) == nil, "rivalIndex: rejects junk")
	end
	check(
		AttackLogic.rival(1.5) == nil and AttackLogic.rival(0) == nil and AttackLogic.rival(nan) == nil,
		"rival(): index"
	)

	-- Shield cycle: deterministic, exact bounds, shielded fraction = lasts / every.
	local t0 = 1_700_000_000
	for index, rival in RIVALS.List do
		local shield = rival.shield
		if shield.every == 0 then
			for t = t0, t0 + 600, 7 do
				check(AttackLogic.rivalShieldUntil(index, t) == 0, `rival {index}: never shielded`)
			end
		else
			local up = 0
			for t = t0, t0 + shield.every - 1 do
				local untilTime = AttackLogic.rivalShieldUntil(index, t)
				check(untilTime == AttackLogic.rivalShieldUntil(index, t), `rival {index}: deterministic`)
				if untilTime > t then
					up += 1
					check(untilTime - t <= shield.lasts, `rival {index}: bubble length`)
				else
					check(untilTime == 0, `rival {index}: 0 when down`)
				end
			end
			check(up == shield.lasts, `rival {index}: up {shield.lasts}s per {shield.every}s ({up})`)
		end
	end
	for t = t0, t0 + 3600 do
		local open = false
		for index in RIVALS.List do
			open = open or AttackLogic.rivalShieldUntil(index, t) <= t
		end
		check(open, "rivals: at least one is always open")
	end
	check(AttackLogic.rivalShieldUntil(99, t0) == 0 and AttackLogic.rivalShieldUntil(2, nan) >= 0, "shield: hostile")

	local now = t0
	local me = {
		userId = 1,
		loaded = true,
		plot = 1,
		area = 7,
		console = true,
		launcher = 1,
		cooldownUntil = 0,
		shieldUntil = 0,
		barrage = 0,
	}
	local function with(overrides: { [string]: any }): any
		local copy = table.clone(me) :: any
		for key, value in overrides do
			copy[key] = value
		end
		return copy
	end
	local slot = AttackGeometry.rivalSlot(1)
	local toy = AttackLogic.rivalActor(1, slot, now)
	check(toy ~= nil and toy.userId == 0 and toy.plot == slot, "rivalActor")
	check(AttackLogic.rivalActor(99, slot, now) == nil, "rivalActor: unknown")
	check(AttackLogic.canLaunch(me, toy, "normal", now, false) == true, "rival: normal launch")
	check(select(2, AttackLogic.canLaunch(me, toy, "revenge", now, false)) == "target", "rival: no revenge")
	check(
		select(2, AttackLogic.canLaunch(with({ cooldownUntil = now + 5 }), toy, "normal", now, false)) == "cooldown",
		"rival: cooldown"
	)
	-- Owner R85: everyone has a starter launcher; only a missing launcher level refuses.
	check(AttackLogic.canLaunch(with({ console = false }), toy, "normal", now, false) == true, "rival: no console needed")
	check(
		select(2, AttackLogic.canLaunch(with({ launcher = 0 }), toy, "normal", now, false)) == "locked",
		"rival: needs a launcher level"
	)
	check(AttackLogic.canLaunch(with({ golden = 1 }), toy, "golden", now, false) == true, "rival: golden charge")
	check(select(2, AttackLogic.canLaunch(me, toy, "barrage", now, false)) == "empty", "rival: barrage needs nukes")
	check(
		AttackLogic.canLaunch(with({ barrage = 20, cooldownUntil = now + 9 }), toy, "barrage", now, false) == true,
		"rival: barrage"
	)
	-- A shielded rival refuses (find a moment inside rival 2's bubble).
	local shield = RIVALS.List[2].shield
	local inside = now - ((now + shield.offset) % shield.every) + 1
	local gus = AttackLogic.rivalActor(2, AttackGeometry.rivalSlot(2), inside)
	check(select(2, AttackLogic.canLaunch(me, gus, "normal", inside, false)) == "shield", "rival: shield bubble blocks")
	-- No AFK protection: a player actor carries no AFK flag. Owner R85: any area is targetable;
	-- only a brand-new player (server-decided `newbie`) is protected.
	check(AttackLogic.isTargetable(with({ userId = 2, plot = 2 })) == true, "players: targetable")
	check(AttackLogic.isTargetable(with({ userId = 2, plot = 2, area = 1 })) == true, "players: area 1 targetable")
	check(
		select(2, AttackLogic.isTargetable(with({ userId = 2, plot = 2, newbie = true }))) == "protected",
		"players: new protected"
	)

	-- Picker order: eligible players → greyed players → rivals (config order).
	local order = {
		AttackLogic.pickerRank(nil, "revenge"),
		AttackLogic.pickerRank(nil, "ready"),
		AttackLogic.pickerRank(nil, "shield"),
		AttackLogic.pickerRank(nil, "protected"),
	}
	for index in RIVALS.List do
		table.insert(order, AttackLogic.pickerRank(index, "ready"))
	end
	for i = 2, #order do
		check(order[i] > order[i - 1], `picker: rank {i} after {i - 1}`)
	end
	check(AttackLogic.pickerRank(1, "shield") == AttackLogic.pickerRank(1, "ready"), "picker: rivals keep their slot")
end

--------------------------------------------------------------------------------------------------
-- 7. Security fixes: free shield cap, Barrage never loses paid nukes
--------------------------------------------------------------------------------------------------

do
	local now = 5000
	local max, free = AttackConfig.MaxShieldSeconds, AttackConfig.FreeShieldSeconds
	check(AttackLogic.freeShieldFits(0, now), "free shield: fits with none")
	check(AttackLogic.freeShieldFits(now + max - free, now), "free shield: fits exactly at the cap")
	check(not AttackLogic.freeShieldFits(now + max - free + 1, now), "free shield: refused past the cap")
	check(AttackLogic.freeShieldFits(nan, now), "free shield: hostile stored value")
	-- Every activation that fits keeps the total within the cap.
	for remaining = 0, max, 997 do
		if AttackLogic.freeShieldFits(now + remaining, now) then
			local untilTime = AttackLogic.addShield(now + remaining, now, free)
			check(untilTime - now <= max, "free shield: total within MaxShieldSeconds")
		end
	end

	local pack = 20
	check(
		AttackLogic.barrageFits(0, pack) and AttackLogic.barrageFits(AttackConfig.MaxStoredBarrage - pack, pack),
		"barrage prompt: fits"
	)
	for stored = AttackConfig.MaxStoredBarrage - pack + 1, AttackConfig.MaxStoredBarrage + 5 do
		check(not AttackLogic.barrageFits(stored, pack), `barrage prompt: refused at {stored}`)
	end
	check(
		not AttackLogic.barrageFits(0, 0)
			and not AttackLogic.barrageFits(0, nan)
			and not AttackLogic.barrageFits(nan, nan),
		"barrage prompt: hostile"
	)

	-- A granted receipt is never clamped: every nuke paid for is stored.
	local profile: any = { attack = { barrage = 1990 } }
	local added, total = AttackProfile.addBarrage(profile, pack)
	check(
		added and total == 2010 and AttackProfile.barrage(profile) == 2010,
		"barrage receipt: whole pack above the prompt cap"
	)
	for _ = 1, 10 do
		local ok = AttackProfile.addBarrage(profile, pack)
		check(ok, "barrage receipt: back-to-back receipts all land")
	end
	check(AttackProfile.barrage(profile) == 2010 + 10 * pack, "barrage receipt: nothing lost")
	-- At the storage bound: all or nothing (false → NotProcessedYet, never a partial grant).
	profile.attack.barrage = AttackConfig.BarrageStorageLimit - 5
	local refused, kept = AttackProfile.addBarrage(profile, pack)
	check(
		not refused and kept == AttackConfig.BarrageStorageLimit - 5,
		"barrage receipt: refused whole at the storage bound"
	)
	check(profile.attack.barrage == AttackConfig.BarrageStorageLimit - 5, "barrage receipt: unchanged when refused")
	check(
		not (AttackProfile.addBarrage(profile, 0)) and not (AttackProfile.addBarrage(profile, nan)),
		"barrage receipt: hostile"
	)
	check(not (AttackProfile.addBarrage({}, pack)), "barrage receipt: malformed profile")
	check(
		AttackConfig.BarrageStorageLimit >= AttackConfig.MaxStoredBarrage * 100,
		"barrage: storage bound far above the prompt cap"
	)
end

--------------------------------------------------------------------------------------------------
-- 8. Sources
--------------------------------------------------------------------------------------------------

do
	for _, path in { "src/server/Services/AttackService.luau", "src/server/Services/DefenseService.luau" } do
		local source = fs.readFile(path)
		check(string.find(source, "OnServerEvent:Connect", 1, true) == nil, `{path}: no raw OnServerEvent`)
		check(string.find(source, "AfkTracker", 1, true) == nil, `{path}: no AFK tracker`)
		check(string.find(source, "StudioDummy", 1, true) == nil, `{path}: no Studio dummy seam`)
	end
	local attackService = fs.readFile("src/server/Services/AttackService.luau")
	local defenseService = fs.readFile("src/server/Services/DefenseService.luau")
	check(
		string.find(attackService, 'Remotes.onServerEvent("AttackLaunch", onLaunch)', 1, true) ~= nil,
		"AttackLaunch guarded"
	)
	check(
		string.find(defenseService, 'Remotes.onServerEvent("DefenseUpgrade", onUpgrade)', 1, true) ~= nil,
		"DefenseUpgrade guarded"
	)
	check(
		string.find(defenseService, 'Remotes.onServerEvent("ShieldActivate", onShield)', 1, true) ~= nil,
		"ShieldActivate guarded"
	)
	check(string.find(defenseService, "AttackLogic.freeShieldFits", 1, true) ~= nil, "free shield uses the cap check")
	check(string.find(attackService, "AttackProfile.addBarrage", 1, true) ~= nil, "Barrage receipts never clamp")
	check(string.find(attackService, "AttackLogic.barrageFits", 1, true) ~= nil, "Barrage prompt checks the pack")
	check(not fs.isFile("src/server/Attack/AfkTracker.luau"), "AfkTracker removed")
	check(not fs.isFile("src/server/Attack/StudioDummy.luau"), "StudioDummy removed")
	local config = fs.readFile("src/shared/Config/AttackConfig.luau")
	check(string.find(config, "AfkSeconds", 1, true) == nil, "no AFK tunables")
	local logic = fs.readFile("src/shared/Attack/AttackLogic.luau")
	check(string.find(logic, "afk", 1, true) == nil, "no AFK flag in the rules")
end

local _ = CFrame
print(`[attack-rivals] {checks} checks passed`)
