--!strict
--[[
	Defence tower regressions (owner R80: "there are no buttons to like buy AA towers ... for your
	plot. So people can just nuke you ... And they need to be upgradable."). Run:
		lune run tests/attack-defense

	Proves on the shipped modules (Shared/Config/AttackConfig.Towers, Shared/Attack/{DefenseTowers,
	FlightMath, AttackGeometry}, Server/Attack/AttackProfile, Server/Economy/ProfileLogic,
	Server/Analytics/KeySpec, Shared/Tycoon/LuckyButtonLogic):
	  1. Config: unique ids, real price pads, unlock areas never below UnlockArea, slot areas in range.
	  2. Prices: the FIRST tower is cheaper than every Area 7 pad (targetable players can always
	     afford a defence), buy prices rise slot by slot, every level step is finite, rises with the
	     level, follows the HQ CostMultiplier ladder and is a friendly 2-significant-digit price.
	  3. Rules (DefenseTowers.plan): locked below the unlock area, toLevel must be stored + 1 (a
	     repeated / stale intent never buys twice), MaxLevel refuses; hostile slot / level / list /
	     area values (NaN, ±inf, fractions, strings, tables, booleans, nil) never throw, never pass.
	  4. Multi-tower engagement (FlightMath.engageMany): ONE tower is bit-identical to the classic
	     engage (shots, times, rng draws) over thousands of random inputs; with several towers every
	     shot is fired in time order, the first hit stops every tower, towers that never fired keep
	     their schedule, each tower obeys MaxShotsPerNuke, saturation carries over between nukes,
	     more towers stop more of a 20-nuke barrage; hostile numbers never fire a shot.
	  5. Placement (the shipped HubLayout data in world space — colliders are CanQuery = false, so
	     rays see nothing): on ALL 8 plots every slot (on the open ground outside the plot's side
	     curb) stands on the island's walkable ground, its whole L5 footprint clears every hub
	     collider / model piece at any height, never touches another plot, and clears the other
	     plots' towers; world CFrames match WorldLayout; slots are spread out and every area of the
	     plot is within L1 range of at least two slot towers; muzzles / mounts per tower; rivals
	     ignore tower ids.
	  6. Persistence: ProfileLogic reconciles attack.towers to a dense whole list (older saves and
	     junk → {}), the snapshot copies it; AttackProfile.setTowerLevel keeps it dense + clamped.
	  7. Wiring: the DefenseTower remote is registered and guarded (onServerEvent + rate limit),
	     the purchase path uses DefenseTowers.plan + trySpendCash, every tower analytics key passes
	     KeySpec, the PlatformConfig "Tower" context exists.
	  8. Owner R85: starter launcher / new-player protection tunables; the 39 R$ RevengeNuke product
	     (published id, one charge); golden storage is all-or-nothing (receipts never lose a paid
	     nuke) and reconciles any stored value; the receipt stores first and defers the launch (never
	     yields); a golden hit grants no counter-Revenge; DefenseService protects only brand-new
	     players (tutorial + play grace); the golden analytics keys pass KeySpec.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")

local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

local loader = Loader.new()
local AttackConfig = loader.load("src/shared/Config/AttackConfig")
local AttackRng = loader.load("src/shared/Attack/AttackRng")
local FlightMath = loader.load("src/shared/Attack/FlightMath")
local AttackGeometry = loader.load("src/shared/Attack/AttackGeometry")
local DefenseTowers = loader.load("src/shared/Attack/DefenseTowers")
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local AttackProfile = loader.load("src/server/Attack/AttackProfile")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local Remotes = loader.load("src/shared/Net/Remotes")
local PlatformConfig = loader.load("src/shared/Config/PlatformConfig")
local LuckyLogic = loader.load("src/shared/Tycoon/LuckyButtonLogic")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local HubLayout = loader.load("src/shared/Config/HubLayout")
local KeySpec = loader.load("src/server/Analytics/KeySpec")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local nan = 0 / 0
local inf = math.huge
local TOWERS = AttackConfig.Towers
local SLOTS = TOWERS.Slots
local MAX = AttackConfig.MaxLevel

local HOSTILE: { any } = {
	nan,
	inf,
	-inf,
	-1,
	0,
	0.5,
	1.5,
	1e300,
	-1e300,
	"1",
	"",
	true,
	false,
	{},
	{ 1 },
	Vector3.new(1, 2, 3),
	function() end,
}

-- 1. Config --------------------------------------------------------------------------------------
do
	check(#SLOTS >= 3 and DefenseTowers.count() == #SLOTS, "several defence tower slots")
	local ids: { [string]: boolean } = {}
	for index, slot in SLOTS do
		check(type(slot.id) == "string" and ids[slot.id] == nil, `slot {index}: unique id`)
		ids[slot.id] = true
		check(type(slot.name) == "string" and #slot.name > 0 and #slot.name <= 24, `slot {index}: short name`)
		check(
			slot.unlockArea >= 1 and slot.unlockArea <= WorldLayout.AreaCount and slot.unlockArea % 1 == 0,
			`slot {index}: unlock area in range`
		)
		check(typeof(slot.at) == "Vector3", `slot {index}: plot-local spot`)
		check(TycoonConfig.PadsById[slot.pricePad] ~= nil, `slot {index}: price pad {slot.pricePad} exists`)
		check(slot.priceFactor > 0 and slot.priceFactor == slot.priceFactor, `slot {index}: price factor`)
		check(DefenseTowers.slot(index) == slot, `slot {index}: lookup`)
	end
	check(#SLOTS + 1 <= 8, "towers (HQ + slots) fit the analytics <0-9> buckets and the client volley bound")
	check(AttackConfig.RateLimits.DefenseTower.capacity >= 1, "DefenseTower rate limit")
	check(AttackConfig.Attr.Towers == "SN_AttackTowers", "public tower-count attribute")
	check(AttackConfig.Tags.DefensePad ~= nil, "defence pad tag")
end

-- 2. Prices -----------------------------------------------------------------------------------------
do
	-- Owner R80 + R85: a player is targetable right after the tutorial + a short grace (area 1-2),
	-- so the first tower unlocks at area 1 and costs no more than the first pad of area 2.
	local first = DefenseTowers.buyCost(1)
	check(SLOTS[1].unlockArea == 1, "the first tower is available the moment protection ends")
	check(first <= TycoonConfig.AreaPads[2][1].cost, `the first tower ({first}) costs <= area 2's first pad`)
	local feature = TycoonConfig.PadsById[TycoonConfig.FeaturePadOf[AttackConfig.FeatureAA]]
	check(first < feature.cost, "the first tower is far cheaper than the HQ AA Tower Feature pad")
	local previousUnlock = 0
	for _, slot in SLOTS do
		check(slot.unlockArea >= previousUnlock, "slots unlock in area order")
		previousUnlock = slot.unlockArea
	end
	local previous = 0
	for index, slot in SLOTS do
		local buy = DefenseTowers.buyCost(index)
		local pad = TycoonConfig.PadsById[slot.pricePad]
		check(buy > previous, `slot {index}: buy price rises with the slot order`)
		previous = buy
		check(buy == TycoonConfig.friendlyPrice(pad.cost * slot.priceFactor), `slot {index}: priced from its pad`)
		check(DefenseTowers.costTo(index, 1) == buy, `slot {index}: level 1 = buy`)
		local last = buy
		for level = 2, MAX do
			local cost = DefenseTowers.costTo(index, level)
			check(cost ~= inf and cost == cost and cost > last, `slot {index}: level {level} finite and rising`)
			check(
				cost == TycoonConfig.friendlyPrice(buy * AttackConfig.CostMultiplier[level]),
				`slot {index}: level {level} follows the HQ ladder`
			)
			check(TycoonConfig.friendlyPrice(cost) == cost, `slot {index}: level {level} friendly price`)
			last = cost
			local toLevel, stepCost = DefenseTowers.nextStep(index, level - 1)
			check(toLevel == level and stepCost == cost, `slot {index}: nextStep from {level - 1}`)
		end
		local toLevel, stepCost = DefenseTowers.nextStep(index, MAX)
		check(toLevel == 0 and stepCost == inf, `slot {index}: maxed has no next step`)
	end
	check(DefenseTowers.costTo(1, 0) == inf and DefenseTowers.costTo(1, MAX + 1) == inf, "no step outside 1..Max")
	check(DefenseTowers.buyCost(0) == inf and DefenseTowers.buyCost(#SLOTS + 1) == inf, "bad slot never priced")
end

-- 3. Rules ------------------------------------------------------------------------------------------
do
	local fresh = { 0, 0, 0, 0 }
	local ok, cost, reason = DefenseTowers.plan(fresh, 1, 1, 1)
	check(ok and cost == DefenseTowers.buyCost(1) and reason == nil, "build the first tower at area 1")
	-- Owner R85: a protected (brand-new) player is passed area 0 → nothing unlocked.
	ok, _, reason = DefenseTowers.plan(fresh, DefenseTowers.areaFor(5, false), 1, 1)
	check(not ok and reason == "locked", "no tower while still protected")
	check(DefenseTowers.areaFor(5, true) == 5 and DefenseTowers.areaFor(5, false) == 0, "areaFor")
	for index, slot in SLOTS do
		local below = slot.unlockArea - 1
		check(not DefenseTowers.unlocked(index, below), `slot {index}: locked below its unlock area`)
		check(DefenseTowers.unlocked(index, below + 1), `slot {index}: unlocked at its unlock area`)
	end
	ok, _, reason = DefenseTowers.plan({ 2, 0, 0, 0 }, 10, 1, 2)
	check(not ok and reason == "level", "a repeated / stale intent (toLevel = stored) never buys again")
	ok, _, reason = DefenseTowers.plan({ 2, 0, 0, 0 }, 10, 1, 4)
	check(not ok and reason == "level", "skipping a level is refused")
	ok, cost = DefenseTowers.plan({ 2, 0, 0, 0 }, 10, 1, 3)
	check(ok and cost == DefenseTowers.costTo(1, 3), "upgrade 2 -> 3")
	ok, _, reason = DefenseTowers.plan({ MAX, 0, 0, 0 }, 10, 1, MAX + 1)
	check(not ok and reason == "max", "max level refuses")
	-- Hostile values in every position.
	for _, value in HOSTILE do
		for position = 1, 4 do
			local args: { any } = { fresh, 10, 1, 1 }
			args[position] = value
			local okCall, allowed, price = pcall(DefenseTowers.plan, args[1], args[2], args[3], args[4])
			check(okCall, "plan never throws")
			if allowed then
				-- Only a junk LIST (read as "nothing bought") or a big finite AREA (server-side profile
				-- data, clamped by ProfileLogic; any area >= the unlock area is unlocked) may pass.
				local bigArea = position == 2 and type(value) == "number" and value >= SLOTS[1].unlockArea
				check(position == 1 or bigArea, "hostile slot / level never pass")
				check(price == DefenseTowers.buyCost(1), "nothing bought: level 1 at the buy price")
			end
		end
		check(DefenseTowers.validSlot(value) == nil or value == 1, "validSlot refuses junk")
		check(DefenseTowers.validLevel(value) == nil or value == 1, "validLevel refuses junk")
		check(pcall(DefenseTowers.normalize, value), "normalize never throws")
		check(pcall(DefenseTowers.activeCount, value, value), "activeCount never throws")
		check(pcall(DefenseTowers.cheapestOpen, value, value), "cheapestOpen never throws")
	end
	-- Lists: holes, junk entries and out-of-range levels.
	local normal = DefenseTowers.normalize({ 2, "x", 9, nil, -3 } :: any)
	check(#normal == #SLOTS and normal[1] == 2 and normal[2] == 0 and normal[3] == MAX, "normalize clamps")
	check(DefenseTowers.level({ 2.9 }, 1) == 2, "levels are whole")
	local lastUnlock = SLOTS[#SLOTS].unlockArea
	check(DefenseTowers.activeCount({ 2, 0, 1, 3 }, lastUnlock - 1) == 2, "the last slot does not count before its area")
	check(DefenseTowers.activeCount({ 2, 0, 1, 3 }, lastUnlock) == 3, "the last slot counts from its area")
	check(DefenseTowers.effective({ 0, 3, 0, 0 }, 2, SLOTS[2].unlockArea - 1) == 0, "a level is packed away (kept) below its area")
	check(DefenseTowers.effective({ 3, 0, 0, 0 }, 1, 0) == 0, "nothing counts while protected (area 0)")
	local cheapest, cheapestCost = DefenseTowers.cheapestOpen({ 0, 0, 0, 0 }, 7)
	check(cheapest == 1 and cheapestCost == DefenseTowers.buyCost(1), "cheapest open slot")
	cheapest = DefenseTowers.cheapestOpen({ 1, 1, 1, 0 }, lastUnlock - 1)
	check(cheapest == nil, "the last slot is not offered before its area")
end

-- 4. Multi-tower engagement --------------------------------------------------------------------------
do
	local FLIGHT = AttackConfig.Flight
	local travel = FLIGHT.InterceptorSeconds
	-- One tower == the classic engage, over random inputs (same results AND the same rng draws).
	local gen = AttackRng.new(9001)
	local function classic(input: any): any
		-- The original single-tower loop (pre-R80), kept here as the reference implementation.
		local from = input.windowFrom
		local to = input.windowTo
		local reload = math.max(input.reload, 0.05)
		local chance = math.clamp(input.chance, 0, 1) * (1 - math.clamp(input.armor, 0, 1))
		local result = {
			intercepted = false,
			interceptAt = 0,
			firstShotAt = 0,
			shots = 0,
			towerFreeAt = input.towerFreeAt,
		}
		if from > to then
			return result
		end
		local fire = math.max(input.towerFreeAt, from - travel, 0)
		while fire + travel <= to and result.shots < FLIGHT.MaxShotsPerNuke do
			if result.shots == 0 then
				result.firstShotAt = fire
			end
			result.shots += 1
			result.towerFreeAt = fire + reload
			if input.rng:next() < chance then
				result.intercepted = true
				result.interceptAt = fire + travel
				break
			end
			fire += reload
		end
		return result
	end
	for trial = 1, 4000 do
		local seed = trial * 7919
		local input = {
			windowFrom = gen:next() * 6,
			windowTo = gen:next() * 9,
			reload = 0.1 + gen:next() * 1.8,
			chance = gen:next(),
			armor = gen:next() * 0.5,
			towerFreeAt = gen:next() * 6 - 3,
		}
		local a = table.clone(input) :: any
		a.rng = AttackRng.new(seed)
		local b = table.clone(input) :: any
		b.rng = AttackRng.new(seed)
		local expected = classic(a)
		local got = FlightMath.engage(b)
		check(
			got.intercepted == expected.intercepted
				and got.interceptAt == expected.interceptAt
				and got.firstShotAt == expected.firstShotAt
				and got.shots == expected.shots
				and got.towerFreeAt == expected.towerFreeAt,
			`trial {trial}: one tower is the classic engage`
		)
		check(a.rng:next() == b.rng:next(), `trial {trial}: same number of rng draws`)
	end

	-- Several towers: shots merge in fire-time order; the first hit stops everything.
	local function towers(count: number, rngSeed: number): ({ any }, any)
		local list = {}
		local g = AttackRng.new(rngSeed)
		for _ = 1, count do
			table.insert(list, {
				windowFrom = 1 + g:next() * 2,
				windowTo = 4 + g:next() * 4,
				reload = 0.4 + g:next(),
				chance = 0.1 + g:next() * 0.3,
				towerFreeAt = g:next() * 3 - 2,
			})
		end
		return list, g
	end
	for trial = 1, 1500 do
		local list = towers(1 + trial % 5, trial)
		local result = FlightMath.engageMany(list, 0.1, AttackRng.new(trial * 31))
		check(#result.volleys == #list, "one volley per tower")
		local total = 0
		local lastFire = -math.huge
		local maxFire = -math.huge
		for index, volley in result.volleys do
			total += volley.shots
			local input = list[index]
			if volley.shots == 0 then
				check(volley.towerFreeAt == input.towerFreeAt, "a tower that never fired keeps its schedule")
			else
				check(volley.shots <= FLIGHT.MaxShotsPerNuke, "each tower obeys MaxShotsPerNuke")
				check(volley.firstShotAt >= math.max(input.towerFreeAt, input.windowFrom - travel, 0) - 1e-9, "fires only once free and in window")
				local lastShot = volley.firstShotAt + (volley.shots - 1) * input.reload
				check(lastShot + travel <= input.windowTo + 1e-9, "every meeting inside the tower's window")
				check(math.abs(volley.towerFreeAt - (lastShot + input.reload)) < 1e-9, "schedule advances by reload")
				maxFire = math.max(maxFire, lastShot)
				lastFire = math.max(lastFire, volley.firstShotAt)
			end
		end
		check(total == result.shots, "shots add up")
		if result.intercepted then
			local hit = result.volleys[result.hitIndex]
			check(hit ~= nil and hit.shots >= 1, "the hit belongs to a tower that fired")
			local hitShot = hit.firstShotAt + (hit.shots - 1) * list[result.hitIndex].reload
			check(math.abs(result.interceptAt - (hitShot + travel)) < 1e-9, "intercept time = hit shot + travel")
			check(hitShot >= maxFire - 1e-9, "the hit is the LAST shot fired: everything stops at the first hit")
		else
			check(result.hitIndex == 0 and result.interceptAt == 0, "no hit, no intercept time")
		end
	end

	-- Hostile numbers never fire.
	for _, value in { nan, inf, -inf } do
		local result = FlightMath.engageMany({
			{ windowFrom = value, windowTo = 5, reload = 1, chance = 1, towerFreeAt = -1 },
			{ windowFrom = 1, windowTo = 5, reload = value, chance = 1, towerFreeAt = -1 },
		}, 0, AttackRng.new(1))
		check(result.volleys[1].shots == 0, "hostile window never fires")
		if value ~= value or value == inf then
			check(result.volleys[2].shots == 0, "hostile reload never fires")
		end
	end
	local always = FlightMath.engageMany({
		{ windowFrom = 2, windowTo = 6, reload = 1, chance = 1, towerFreeAt = -1 },
		{ windowFrom = 1, windowTo = 6, reload = 1, chance = 1, towerFreeAt = -1 },
	}, 0, AttackRng.new(5))
	check(always.intercepted and always.hitIndex == 2 and always.shots == 1, "the earliest shot wins (tower 2 fires at 0.1)")
	check(always.volleys[1].shots == 0, "tower 1 never fired: the nuke was already down")
	local tie = FlightMath.engageMany({
		{ windowFrom = 2, windowTo = 6, reload = 1, chance = 1, towerFreeAt = -1 },
		{ windowFrom = 2, windowTo = 6, reload = 1, chance = 1, towerFreeAt = -1 },
	}, 0, AttackRng.new(5))
	check(tie.hitIndex == 1, "ties fire the lower index first")
	check(FlightMath.engageMany({}, 0, AttackRng.new(1)).shots == 0, "no towers, no shots")

	-- Barrage saturation still carries over, and more towers stop more nukes.
	local function barrage(count: number, seed: number): number
		local freeAt: { number } = {}
		for index = 1, count do
			freeAt[index] = -math.huge
		end
		local stopped = 0
		for nuke = 1, AttackConfig.BarrageSize do
			local t0 = (nuke - 1) * AttackConfig.BarrageStagger
			local list = {}
			for index = 1, count do
				local stats = AttackConfig.AA[2]
				table.insert(list, {
					windowFrom = 3,
					windowTo = 5.5,
					reload = stats.reload,
					chance = stats.chance,
					towerFreeAt = freeAt[index] - t0,
				})
			end
			local result = FlightMath.engageMany(list, 0.08, AttackRng.new(seed * 100 + nuke))
			for index, volley in result.volleys do
				if volley.shots > 0 then
					freeAt[index] = t0 + volley.towerFreeAt
				end
			end
			if result.intercepted then
				stopped += 1
			end
		end
		return stopped
	end
	local one, four = 0, 0
	for seed = 1, 200 do
		one += barrage(1, seed)
		four += barrage(4, seed)
	end
	check(one < AttackConfig.BarrageSize * 200, "one tower is saturated by barrages (not every nuke stopped)")
	check(four > one * 2, `four towers stop far more of a barrage ({four} vs {one})`)
end

-- 5. Placement ----------------------------------------------------------------------------------------
do
	local H = TOWERS.FootprintHalf
	-- The hub's world-space colliders + model pieces (HubLayout): walkable ground (top at the
	-- ground plane) and everything standing on / above it at ANY height (trees, hills, posts).
	local hubCollision = HubLayout.collision or {}
	local hubModels = HubLayout.models or {}
	check(#hubCollision > 0 and #hubModels > 0, "hub layout data loaded")
	local supports: { any } = {}
	local solids: { any } = {}
	local function addBox(cf: any, size: any, collider: boolean)
		local rect, top, bottom = LuckyLogic.slab(cf, size)
		if math.abs(top) <= 1.25 then
			if collider then
				table.insert(supports, rect)
			end
		elseif top > 1.25 and bottom < 80 then
			table.insert(solids, rect)
		end
	end
	for _, collision in hubCollision do
		addBox(collision.cf, collision.size, true)
	end
	for _, model in hubModels do
		if typeof(model.box) == "Vector3" then
			addBox(model.cf, model.box, false)
		else
			local entry = MeshAssets[model.key or ""]
			if type(entry) == "table" and type(entry.pieces) == "table" then
				for _, piece in entry.pieces do
					local offset = if typeof(piece.offset) == "Vector3" then piece.offset else Vector3.zero
					addBox(model.cf * CFrame.new(offset), piece.size, false)
				end
			end
		end
	end
	for index, slot in SLOTS do
		local x, z = slot.at.X, slot.at.Z
		check(math.abs(x) - H > WorldLayout.PlotHalfWidth + 2, `slot {index}: outside the plot and its border curb`)
		check(z - H >= 0 and z + H <= WorldLayout.PlotLength, `slot {index}: alongside the plot's length`)
		check(type(slot.where) == "string" and #slot.where > 0, `slot {index}: location line`)
		for plot = 1, WorldLayout.PlotCount do
			local origin = WorldLayout.plotOrigin(plot)
			local centre = origin * Vector3.new(x, 0, z)
			local onGround = false
			for _, support in supports do
				if LuckyLogic.distance(support, centre.X, centre.Z) == 0 then
					onGround = true
				end
			end
			check(onGround, `slot {index} plot {plot}: on the island's walkable ground`)
			for sx = -H, H, 1 do
				for sz = -H, H, 1 do
					local point = origin * Vector3.new(x + sx, 0, z + sz)
					check(LuckyLogic.isClear(point.X, point.Z, solids, 0.5), `slot {index} plot {plot}: clear of hub props`)
									for other = 1, WorldLayout.PlotCount do
						if other ~= plot then
							local local_ = WorldLayout.plotOrigin(other):PointToObjectSpace(point)
							check(
								not (math.abs(local_.X) <= WorldLayout.PlotHalfWidth + 4 and local_.Z >= -4 and local_.Z <= WorldLayout.PlotLength + 20),
								`slot {index} plot {plot}: never on plot {other}`
							)
						end
					end
				end
			end
			-- World frames + mounts / muzzles per tower.
			local cf = AttackGeometry.towerSlotCFrame(plot, index)
			check((cf.Position - WorldLayout.plotToWorld(plot, CFrame.new(slot.at)).Position).Magnitude < 1e-6, `slot {index} plot {plot}: world frame`)
			check(AttackGeometry.towerMount(plot, index) == cf, `slot {index} plot {plot}: mount`)
			local muzzle = AttackGeometry.muzzle(plot, index)
			check((muzzle - (cf.Position + Vector3.new(0, TOWERS.MuzzleHeight, 0))).Magnitude < 1e-6, `slot {index}: muzzle`)
		end
		-- No two slots of neighbouring plots crowd each other in the wedge between them.
		for plot = 1, WorldLayout.PlotCount do
			local here = AttackGeometry.towerSlotCFrame(plot, index).Position
			for other = 1, WorldLayout.PlotCount do
				for otherIndex = 1, #SLOTS do
					if other ~= plot then
						local there = AttackGeometry.towerSlotCFrame(other, otherIndex).Position
						check((here - there).Magnitude >= 2 * H + 10, `slot {index} of plot {plot} clears plot {other}'s towers`)
					end
				end
			end
		end
	end
	-- Spread: no two slots crowd each other; every area centre is within L1 range of >= 2 slots.
	for i = 1, #SLOTS do
		for j = i + 1, #SLOTS do
			local d = SLOTS[i].at - SLOTS[j].at
			check(math.sqrt(d.X * d.X + d.Z * d.Z) >= 60, `slots {i} and {j} are spread out`)
		end
	end
	local range = AttackConfig.AA[1].range
	for area = 1, WorldLayout.AreaCount do
		local centre = WorldLayout.slotLocal(area) * Vector3.new(0, 0, 35)
		local covering = 0
		for _, slot in SLOTS do
			local d = (slot.at + Vector3.new(0, TOWERS.MuzzleHeight, 0)) - centre
			if d.Magnitude <= range then
				covering += 1
			end
		end
		check(covering >= 2, `area {area}: within L1 range of {covering} slot towers (>= 2)`)
	end
	-- The HQ tower (no tower id) and rivals are unchanged; rivals ignore a tower id.
	check(AttackGeometry.towerMount(1) == AttackGeometry.towerMount(1, 0), "tower 0 = the HQ tower")
	local rival = AttackGeometry.rivalSlot(1)
	check(AttackGeometry.towerMount(rival, 2) == AttackGeometry.towerMount(rival), "rivals have one tower")
	check(AttackGeometry.muzzle(rival, 2) == AttackGeometry.muzzle(rival), "rival muzzle ignores tower ids")
	check(AttackGeometry.validTower(0) == nil and AttackGeometry.validTower(#SLOTS + 1) == nil, "validTower")
	check(not pcall(AttackGeometry.towerSlotCFrame, 1, 0), "slot 0 has no defence spot")
end

-- 6. Persistence ----------------------------------------------------------------------------------------
do
	check(type(ProfileLogic.defaultProfile().attack.towers) == "table", "template has attack.towers")
	check(#ProfileLogic.defaultProfile().attack.towers == 0, "a new profile owns no tower")
	local function reconciled(value: any): { number }
		return ProfileLogic.reconcile({ attack = { towers = value } }).attack.towers
	end
	check(#ProfileLogic.reconcile({ attack = { aa = 2 } }).attack.towers == 0, "older saves → {}")
	for _, value in HOSTILE do
		local ok, result = pcall(reconciled, value)
		check(ok and type(result) == "table", "reconcile never throws on junk towers")
	end
	local list = reconciled({ 2.7, -4, 1e9, 3 })
	check(list[1] == 2 and list[2] == 0 and list[3] == ProfileLogic.Limits.MaxLevel and list[4] == 3, "whole + clamped")
	local holes = reconciled({ [1] = 1, [3] = 2 })
	check(#holes == 1 and holes[1] == 1, "a hole ends the list (dense)")
	local long = {}
	for index = 1, 40 do
		long[index] = 1
	end
	check(#reconciled(long) == ProfileLogic.Limits.MaxTowerSlots, "at most MaxTowerSlots entries")
	local profile = ProfileLogic.reconcile({ attack = { towers = { 1, 2 } } })
	local snapshot = ProfileLogic.snapshot(profile, { saveStatus = "ok" } :: any, { "attack" })
	check(snapshot.attack.towers[2] == 2 and snapshot.attack.towers ~= profile.attack.towers, "snapshot copies the list")
	-- AttackProfile writes keep it dense and clamped.
	local live = { attack = { towers = {} } }
	check(AttackProfile.setTowerLevel(live, 3, 2), "write slot 3")
	check(#live.attack.towers == 3 and live.attack.towers[1] == 0 and live.attack.towers[3] == 2, "dense fill")
	check(AttackProfile.setTowerLevel(live, 1, 99) and live.attack.towers[1] == MAX, "clamped to MaxLevel")
	check(not AttackProfile.setTowerLevel(live, 0, 1) and not AttackProfile.setTowerLevel(live, nan, 1), "bad slot ignored")
	check(not AttackProfile.setTowerLevel({}, 1, 1), "no attack table → ignored")
	local copy = AttackProfile.towers(live)
	check(#copy == #SLOTS and copy ~= live.attack.towers, "towers() is a normalised copy")
end

-- 7. Wiring ---------------------------------------------------------------------------------------------
do
	check(table.find(Remotes.EventNames, "DefenseTower") ~= nil, "DefenseTower remote registered")
	local defense = fs.readFile("src/server/Services/DefenseService.luau")
	check(string.find(defense, 'Remotes.onServerEvent("DefenseTower", onTower)', 1, true) ~= nil, "DefenseTower guarded")
	check(string.find(defense, "towerLimiter:Allow(player)", 1, true) ~= nil, "DefenseTower rate limited")
	check(string.find(defense, "DefenseTowers.plan(", 1, true) ~= nil, "purchase decided by DefenseTowers.plan")
	check(string.find(defense, 'trySpendCash(player, cost, "defense_tower")', 1, true) ~= nil, "atomic spend")
	check(string.find(defense, "towerLimiter:Forget(player)", 1, true) ~= nil, "limiter forgotten on leave")
	check(string.find(defense, "FlightMath.engageMany", 1, true) ~= nil, "every tower engages")
	check(table.find(PlatformConfig.Contexts, "Tower") ~= nil, "Tower context")
	check(table.find(PlatformConfig.Actions.Interact.contexts, "Tower") ~= nil, "Interact upgrades towers")
	-- Every tower analytics key passes the allowlist.
	local keys = { "tower:warned", "tower:admin", "tower:src:walk", "tower:src:remote" }
	for index = 1, #SLOTS do
		table.insert(keys, `tower:buy:{index}`)
		for level = 2, MAX do
			table.insert(keys, `tower:up:{index}:{level}`)
		end
	end
	for _, reason in { "cash", "locked", "level", "max", "rate", "off", "other" } do
		table.insert(keys, `tower:refused:{reason}`)
	end
	for n = 0, #SLOTS do
		table.insert(keys, `interceptBy:{n}`)
		table.insert(keys, `defTowers:{n}`)
	end
	for _, key in keys do
		check(KeySpec.check("attack", key) == key, `analytics key {key} is allowlisted`)
	end
	check(KeySpec.check("attack", "tower:buy:99") == nil, "out-of-range slot refused")
end

-- 8. Owner R85: attack open to everyone + the paid golden revenge nuke ------------------------------
do
	local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")
	local GOLDEN = AttackConfig.Golden
	-- Config.
	check(AttackConfig.StarterLauncher >= 1 and AttackConfig.ConsoleLauncher > AttackConfig.StarterLauncher, "launcher ladder")
	check(AttackConfig.NewPlayer.GraceSeconds >= 0 and AttackConfig.NewPlayer.GraceSeconds <= AttackConfig.NewPlayer.MaxGraceSeconds, "grace bounds")
	check(GOLDEN.ArmorBonus > 0 and GOLDEN.MaxArmor < 1 and AttackConfig.Launcher[GOLDEN.Tier] ~= nil, "golden tunables")
	check(GOLDEN.MaxStored >= 1 and GOLDEN.ExplosionScale > 1, "golden storage + blast")
	local product = MonetizationConfig.getProduct(GOLDEN.Product)
	-- Owner: "like a 39"; the 2026-10-31 store-wide product price cut may lower the base price.
	check(product ~= nil and product.kind == "RevengeNuke" and product.price >= 1 and product.price <= 39, "RevengeNuke product: <= 39 R$")
	check(product ~= nil and product.nukes == 1, "one golden charge per purchase")
	check(product ~= nil and MonetizationConfig.isConfigured(product.id), "RevengeNuke is published (Creator Dashboard id)")
	-- Storage: receipts are all-or-nothing and never clamped below the storage bound.
	local live = { attack = { golden = 0 } }
	check(AttackProfile.addGolden(live, 1) and AttackProfile.golden(live) == 1, "addGolden adds")
	live.attack.golden = AttackConfig.BarrageStorageLimit
	local added, total = AttackProfile.addGolden(live, 1)
	check(not added and total == AttackConfig.BarrageStorageLimit, "addGolden refuses past the storage bound")
	AttackProfile.setGolden(live, -5)
	check(AttackProfile.golden(live) == 0, "setGolden clamps")
	check(not AttackProfile.addGolden({}, 1), "no attack table → not granted")
	for _, value in HOSTILE do
		local ok, result = pcall(function()
			return ProfileLogic.reconcile({ attack = { golden = value } }).attack.golden
		end)
		check(ok and type(result) == "number" and result >= 0 and result % 1 == 0, "golden reconciles any value")
	end
	check(ProfileLogic.defaultProfile().attack.golden == 0, "template: no golden charges")
	-- Wiring (server sources).
	local attack = fs.readFile("src/server/Services/AttackService.luau")
	check(string.find(attack, 'registerProductHandler("RevengeNuke", grantGolden)', 1, true) ~= nil, "receipt handler")
	check(string.find(attack, 'registerPromptRefusal("RevengeNuke", refuseGolden)', 1, true) ~= nil, "prompt refusal")
	local handler = string.match(attack, "local function grantGolden%(.-\nend\n") or ""
	check(handler ~= "", "grantGolden found")
	check(string.find(handler, "AttackProfile.addGolden", 1, true) ~= nil, "the charge is stored first")
	check(string.find(handler, "task.defer", 1, true) ~= nil, "the launch is deferred (the receipt never yields)")
	check(string.find(handler, "task.wait", 1, true) == nil and string.find(handler, "Async", 1, true) == nil, "no yields in the receipt")
	check(string.find(attack, 'nuke.kind ~= "golden"', 1, true) ~= nil, "a golden hit grants no counter-Revenge")
	local defense = fs.readFile("src/server/Services/DefenseService.luau")
	check(string.find(defense, "newbie = isNewbie(profile)", 1, true) ~= nil, "targets carry the new-player flag")
	check(string.find(defense, "TutorialLogic.DoneStep", 1, true) ~= nil, "protected until the tutorial is done")
	check(string.find(defense, "playSeconds", 1, true) ~= nil, "plus the grace seconds of play")
	check(string.find(defense, "AttackLogic.launcherLevel", 1, true) ~= nil, "everyone has the starter launcher")
	for _, key in { "launch:golden", "golden:buy", "golden:auto", "golden:stored" } do
		check(KeySpec.check("attack", key) == key, `analytics key {key} is allowlisted`)
	end
end

print(`[attack-defense] {checks} checks passed`)
