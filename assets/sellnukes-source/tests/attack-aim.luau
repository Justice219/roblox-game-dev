--!strict
--[[
	Attack mode — owner R50 aiming / knockdown rewards and R51 admin test bots. Run:
		lune run tests/attack-aim            (from the repo root)

	Proves on the shipped modules (Shared/Attack/{AttackLogic, AttackGeometry, FlightMath,
	RivalLayout}, Shared/Config/{AttackConfig, WorldLayout, AdminConfig, KnockdownConfig,
	AreaLayouts/*}) and the shipped server sources:
	  1. Scatter: inside the level's radius, shrinking with launcher level, halved on rival sections.
	  2. Built areas: encode / decode round trip, junk dropped; resolveAim (default = highest built,
	     unbuilt refused, junk refused); spillNeighbour only ever picks a built neighbour.
	  3. Aim geometry: every plot x area x extreme scatter stays inside the aimed area's slot; rival
	     section points stay inside their section; flights to aimed points are in time bounds and
	     a target's AA tower can engage a nuke aimed at its Launch Silos area at every level.
	  4. Rival sections: every base model belongs to exactly one section (floors are static), every
	     section of every rival has models to topple.
	  5. Rewards: an area hit is bounded by the attacker's own income band; the blocked factor pays
	     less than a knockdown.
	  6. Admin tab + bots (sources / config): the Attack tab and its 8 commands exist, AdminService
	     installs AttackHandlers, bots are admin-only targets, never persisted, and the knockdown
	     sources the attack service sends are in KnockdownConfig's allowlist.
]]

local fs = require("@lune/fs")

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local AttackConfig = loader.load("src/shared/Config/AttackConfig")
local AttackGeometry = loader.load("src/shared/Attack/AttackGeometry")
local AttackLogic = loader.load("src/shared/Attack/AttackLogic")
local FlightMath = loader.load("src/shared/Attack/FlightMath")
local RivalLayout = loader.load("src/shared/Attack/RivalLayout")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local AdminConfig = loader.load("src/shared/Config/AdminConfig")
local KnockdownConfig = loader.load("src/shared/Config/KnockdownConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local nan = 0 / 0
local AIM = AttackConfig.Aim
local RIVALS = AttackConfig.Rivals
local EPS = 0.01

--------------------------------------------------------------------------------------------------
-- 1. Scatter
--------------------------------------------------------------------------------------------------

do
	local previous = math.huge
	for level = 1, AttackConfig.MaxLevel do
		local radius = AIM.Scatter[level]
		check(radius > 0 and radius < previous, `scatter L{level} shrinks`)
		previous = radius
		for i = 0, 40 do
			for j = 0, 8 do
				local sx, sz = AttackLogic.scatter(level, i / 40, j / 8, false)
				check(math.sqrt(sx * sx + sz * sz) <= radius + 1e-9, `scatter L{level} inside radius`)
				local rx, rz = AttackLogic.scatter(level, i / 40, j / 8, true)
				check(math.sqrt(rx * rx + rz * rz) <= radius * AIM.RivalScatterScale + 1e-9, "rival scatter smaller")
			end
		end
	end
	local x, z = AttackLogic.scatter(nan, nan, nan, false)
	check(x == x and z == z, "scatter: hostile input stays finite")
end

--------------------------------------------------------------------------------------------------
-- 2. Built areas, aim resolution, barrage spill
--------------------------------------------------------------------------------------------------

do
	check(AttackLogic.encodeAreas({ 1, 2, 5 }) == "1,2,5", "encodeAreas")
	check(AttackLogic.encodeAreas({ 0, 1.5, 3, nan :: any, "x" :: any }) == "3", "encodeAreas drops junk")
	local decoded = AttackLogic.decodeAreas("5,1,x,,2,2,-3,1e9")
	check(#decoded == 3 and decoded[1] == 1 and decoded[2] == 2 and decoded[3] == 5, "decodeAreas sorts + drops junk")
	check(
		#AttackLogic.decodeAreas(nil) == 0 and #AttackLogic.decodeAreas(string.rep("1,", 100)) == 0,
		"decodeAreas bounds"
	)

	local built = { 1, 2, 3, 4, 7 }
	check(
		AttackLogic.resolveAim(built, nil) == 7 and AttackLogic.resolveAim(built, 0) == 7,
		"aim default = highest built"
	)
	check(AttackLogic.resolveAim(built, 3) == 3, "aim: a built area")
	check(AttackLogic.resolveAim(built, 5) == nil, "aim: unbuilt refused")
	check(AttackLogic.resolveAim(built, 2.5) == nil and AttackLogic.resolveAim(built, "3") == nil, "aim: junk refused")
	check(AttackLogic.resolveAim({}, nil) == nil, "aim: nothing built")

	for u = 0, 0.99, 0.05 do
		local spill = AttackLogic.spillNeighbour(built, 3, u)
		check(spill == 2 or spill == 4, "spill: a built neighbour of 3")
		check(AttackLogic.spillNeighbour(built, 7, u) == nil, "spill: no built neighbour of 7")
		check(AttackLogic.spillNeighbour(built, 1, u) == 2, "spill: edge area")
	end
end

--------------------------------------------------------------------------------------------------
-- 3. Aim geometry
--------------------------------------------------------------------------------------------------

do
	local extremes = { { 0, 0 }, { 99, 99 }, { -99, 99 }, { 99, -99 }, { -99, -99 }, { nan, nan } }
	for plot = 1, WorldLayout.PlotCount do
		check(AttackGeometry.areaCount(plot) == WorldLayout.AreaCount, "plot: 10 aimable areas")
		for area = 1, WorldLayout.AreaCount do
			for _, e in extremes do
				local point = AttackGeometry.aimPoint(plot, area, e[1], e[2])
				local slot = WorldLayout.slotOrigin(plot, area):PointToObjectSpace(point)
				check(
					math.abs(slot.X) <= 52 + EPS and slot.Z >= -EPS and slot.Z <= 70 + EPS,
					`aim stays in plot {plot} area {area}`
				)
				check(WorldLayout.plotAt(point) == plot, "aim lands on the target plot")
			end
		end
	end
	for index in RIVALS.List do
		local slot = AttackGeometry.rivalSlot(index)
		check(AttackGeometry.areaCount(slot) == #RIVALS.Sections, "rival: sections are its areas")
		local frame = AttackGeometry.rivalFrame(index)
		for section, def in RIVALS.Sections do
			for _, e in extremes do
				local p = frame:PointToObjectSpace(AttackGeometry.aimPoint(slot, section, e[1], e[2]))
				check(
					math.abs(p.X - def.centre.X) <= def.half.X + EPS
						and math.abs(p.Z - def.centre.Z) <= def.half.Z + EPS,
					`rival {index} section {section}: aim inside`
				)
			end
		end
	end
	-- Legacy impact (area 0) is unchanged; aimed flights are in bounds and engageable at the silos.
	check((AttackGeometry.targetPoint(2, 3, 0) - AttackGeometry.impactPoint(2, 3)).Magnitude < EPS, "legacy impact")
	for from = 1, WorldLayout.PlotCount do
		for to = 1, WorldLayout.PlotCount do
			if from ~= to then
				for area = 1, WorldLayout.AreaCount do
					local flight = AttackGeometry.flightOf({
						fromPlot = from,
						silo = 1,
						toPlot = to,
						impact = 1,
						area = area,
						sx = 5,
						sz = -5,
					})
					check(
						flight.duration >= AttackConfig.Flight.MinSeconds
							and flight.duration <= AttackConfig.Flight.MaxSeconds,
						"aimed flight time in bounds"
					)
				end
				local silos = AttackGeometry.flightOf({
					fromPlot = from,
					silo = 2,
					toPlot = to,
					impact = 1,
					area = AttackConfig.UnlockArea,
				})
				for level = 1, AttackConfig.MaxLevel do
					local a, b = FlightMath.engageWindow(silos, AttackGeometry.muzzle(to), AttackConfig.AA[level].range)
					check(a ~= nil and b ~= nil, `AA{level} engages a nuke aimed at the Launch Silos`)
				end
			end
		end
	end
end

--------------------------------------------------------------------------------------------------
-- 4. Rival sections
--------------------------------------------------------------------------------------------------

do
	for index, rival in RIVALS.List do
		local layout = loader.load(string.format("src/shared/Config/AreaLayouts/Area%02d", rival.area))
		local perSection: { [number]: number } = {}
		for _, placement in RivalLayout.island(index, layout) do
			check(placement.section >= 0 and placement.section <= #RIVALS.Sections, "section index in range")
			if RIVALS.KeepKeys[placement.key] then
				check(placement.section == 0, `{placement.key} is static`)
			end
			perSection[placement.section] = (perSection[placement.section] or 0) + 1
		end
		for section in RIVALS.Sections do
			check((perSection[section] or 0) >= 1, `rival {index} section {section} has models to topple`)
		end
		check((perSection[0] or 0) >= #RIVALS.Dressing + 2, `rival {index}: dressing + plinth + sign are static`)
	end
end

--------------------------------------------------------------------------------------------------
-- 5. Rewards
--------------------------------------------------------------------------------------------------

do
	local reward = AttackConfig.Reward
	check(reward.BlockedFactor > 0 and reward.BlockedFactor < 1, "blocked hits pay less than a knockdown")
	for level = 1, AttackConfig.MaxLevel do
		local seconds = AttackConfig.Launcher[level].rewardSeconds
		for _, areaIncome in { 0, 1, 50, 1e3, 1e9 } do
			local cash = AttackLogic.reward("normal", level, areaIncome, 1000, false)
			check(
				cash >= seconds * 1000 * reward.MinRatio - 1e-6 and cash <= seconds * 1000 * reward.MaxRatio + 1e-6,
				"area reward inside the attacker's own income band"
			)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- 6. Admin tab + bots
--------------------------------------------------------------------------------------------------

do
	local hasTab = false
	for _, tab in AdminConfig.Tabs do
		hasTab = hasTab or tab.key == "Attack"
	end
	check(hasTab, "admin: Attack tab")
	for _, name in
		{
			"AttackBotSpawn",
			"AttackBotAttack",
			"AttackBotAuto",
			"AttackBotShield",
			"AttackBotRemove",
			"AttackMeReset",
			"AttackMeBarrage",
			"AttackMeLevels",
		}
	do
		local def = AdminConfig.Commands[name]
		check(def ~= nil and def.tab == "Attack" and def.audited == true, `admin: {name} on the Attack tab, audited`)
	end
	local adminService = fs.readFile("src/server/Services/AdminService.luau")
	check(
		string.find(adminService, "AttackHandlers.install(registry, env)", 1, true) ~= nil,
		"AdminService installs AttackHandlers"
	)
	local attack = fs.readFile("src/server/Services/AttackService.luau")
	check(
		string.find(attack, "target.bot ~= nil and not isAdmin(attacker)", 1, true) ~= nil,
		"bots: admin-only targets"
	)
	check(string.find(attack, '"attack_test"', 1, true) ~= nil, "bots: rewards tagged test")
	local bots = fs.readFile("src/server/Attack/TestBots.luau")
	check(
		string.find(bots, "markChanged", 1, true) == nil and string.find(bots, "getProfile", 1, true) == nil,
		"bots never touch a profile"
	)
	check(
		string.find(bots, "BindToClose", 1, true) ~= nil and string.find(bots, "LifetimeSeconds", 1, true) ~= nil,
		"bots: auto-removed"
	)
	for _, source in { "normal", "revenge", "barrage", "test" } do
		check(table.find(KnockdownConfig.Sources, source) ~= nil, `knockdown source {source} allowlisted`)
	end
	check(AttackConfig.Flight.LeadIn >= 3, "lead-in fits the R54 countdown")
end

print(`[attack-aim] {checks} checks passed`)
