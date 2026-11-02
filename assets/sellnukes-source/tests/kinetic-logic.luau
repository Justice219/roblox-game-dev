--!strict
--[[
	Mega Lever + Tip Jar regressions (owner R90, K-kinetic; spec
	docs/superpowers/specs/2026-10-31-r90-hands-on-design.md §2 / §3; docs/kinetic.md). Run:
		lune run tests/kinetic-logic
	Proves on the shipped modules (Shared/Config/KineticConfig, Shared/Tycoon/KineticLogic, plus the
	shared registries they plug into):
	  1. Config: cooldown / multiplier / clamp window, jar caps (a full jar + full tips always fits
	     the hard ceiling), the action allowlist, both remotes declared, the "lever" / "tipjar"
	     stats in ProgressEvents + QuestConfig (+ their missions), the "kinetic" analytics family
	     + every key the server builds passes the real KeySpec, MeshAssets carries both models with
	     the pieces the client animates (Arm / ArmStripes / HopperNuke / Coins; the pile's bottom
	     matches TipJar.CoinBottom), boot lists name both entry points.
	  2. Save state: newState / reconcileState on junk (NaN, ±inf, negatives, bad keys, too many
	     worlds, non-tables), entry() creation + MaxWorlds, ProfileLogic default / reconcile /
	     toSave round-trip, and `kinetic` never reaches the client snapshot.
	  3. Cooldown: cooldownLeft / isReady / nextReadyAt (whole seconds, never early) / the
	     MaxCooldownAhead clamp.
	  4. Payout math: leverPlan inside the window (x multiplier, unscaled), below the floor (scaled
	     up), above the ceiling (scaled down), shares preserved, junk cycles skipped, nothing → 0;
	     flavorOf maps every FlavorConfig multiplier back to its flavour.
	  5. Jar: jarCap, jarFill (rate, cap, never shrinks, dt clamp, no income), addTips (bucket cap),
	     collectable (min fill, tips-only, hard ceiling, no income), fillRatio steps.
	  6. Pacing: pacingLift at the real flavour lift stays under KineticConfig.Pacing.MaxLift.
	  7. Placement (owner R116: INSIDE the plot, Area 1's front yard): EVERY world's real layout
	     data (area layout incl. every build, billboard spots, the plot frame's colliders, Dino's
	     D1_Jungle clumps): both footprints inside the slot / fence lines, the plot footprint (all 8
	     plots) and their KeepOut, on walkable ground, clear of solids, the producer + billboards,
	     the spawn, the entrance arch / plot sign, the road, each other, D-defense's tower slots,
	     and never where a Lucky Button can spawn. (The R90 Order Window clearance checks went with
	     the order system, owner R128.)
	  8. Validation: decodeWire accepts the server's payloads and refuses / trims hostile ones
	     without throwing; reach / nearPlot / formatCountdown edges.
	  9. Server wiring (source scan): intents through Remotes.onServerEvent + RateLimiter +
	     Validate.oneOf; the cooldown and the jar are committed BEFORE the grant (idempotent).
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Loader = require("./fixtures/RobloxLoader")

local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
local Enum = roblox.Enum

local loader = Loader.new()
local KineticConfig = loader.load("src/shared/Config/KineticConfig")
local KineticLogic = loader.load("src/shared/Tycoon/KineticLogic")
local FlavorConfig = loader.load("src/shared/Config/FlavorConfig")
local FlavorLogic = loader.load("src/shared/Tycoon/FlavorLogic")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
local MeshAssets = loader.load("src/shared/Config/MeshAssets")
local Remotes = loader.load("src/shared/Net/Remotes")
local ProgressEvents = loader.load("src/server/Progression/ProgressEvents")
local QuestConfig = loader.load("src/shared/Config/QuestConfig")
local AnalyticsConfig = loader.load("src/shared/Config/AnalyticsConfig")
local KeySpec = loader.load("src/server/Analytics/KeySpec")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local AttackConfig = loader.load("src/shared/Config/AttackConfig")
local LuckyLogic = loader.load("src/shared/Tycoon/LuckyButtonLogic")

local checks = 0
local function check(ok: boolean, label: string)
	checks += 1
	if not ok then
		error(label, 2)
	end
end

local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-9) * math.max(1, math.abs(a), math.abs(b))
end

local nan = 0 / 0
local LEVER = KineticConfig.Lever
local JAR = KineticConfig.TipJar

-- 1. Config ------------------------------------------------------------------------------------------
do
	check(LEVER.CooldownSeconds == 600, "spec: 10 min lever cooldown")
	check(LEVER.CycleMultiplier >= 1, "a bonus cycle is worth at least one cycle")
	check(LEVER.MinIncomeSeconds > 0 and LEVER.MinIncomeSeconds < LEVER.MaxIncomeSeconds, "lever clamp window ordered")
	check(JAR.FillFraction > 0 and JAR.FillFraction <= 0.05, "the jar takes a SMALL % of income")
	check(JAR.CapMinutes > 0 and JAR.MinCollectFraction > 0 and JAR.MinCollectFraction < 1, "jar caps sane")
	local passiveSeconds = JAR.FillFraction * 60 * JAR.CapMinutes
	check(
		JAR.HardCapIncomeSeconds >= passiveSeconds + JAR.BonusCapIncomeSeconds,
		"a full jar + full tips always fit under the payout ceiling"
	)
	check(KineticConfig.UnlockArea >= 1, "unlock area")
	for _, def in WorldsConfig.extra() do
		check(KineticConfig.UnlockArea <= WorldLayout.areaCount(def.id), `unlock area exists in {def.id}`)
	end
	check(
		#KineticConfig.Actions == 2
			and table.find(KineticConfig.Actions, "pull") ~= nil
			and table.find(KineticConfig.Actions, "collect") ~= nil,
		"intent allowlist: pull + collect"
	)
	check(table.find(Remotes.EventNames, "KineticAction") ~= nil, "KineticAction declared")
	check(table.find(Remotes.EventNames, "Kinetic") ~= nil, "Kinetic declared")
	for _, stat in { "lever", "tipjar" } do
		check(ProgressEvents.isStat(stat), `ProgressEvents knows {stat}`)
		check(QuestConfig.isStat(stat), `QuestConfig knows {stat}`)
		check(QuestConfig.MissionByStat[stat] ~= nil, `daily mission for {stat}`)
	end
	check(LEVER.Prompt.HoldSeconds > 0, "the lever is a HOLD prompt")
	check(
		LEVER.Prompt.MaxDistance < LEVER.Reach and JAR.Prompt.MaxDistance < JAR.Reach,
		"server reach covers the prompt distance (+ slack)"
	)
	check(
		LEVER.Prompt.KeyboardKey == Enum.KeyCode.E and LEVER.Prompt.GamepadKey == Enum.KeyCode.ButtonX,
		"lever prompt on the Interact keys"
	)
	check(
		JAR.Prompt.KeyboardKey == Enum.KeyCode.E and JAR.Prompt.GamepadKey == Enum.KeyCode.ButtonX,
		"jar prompt on the Interact keys"
	)
	-- Analytics family + every key shape the server builds.
	check(table.find(AnalyticsConfig.Families, "kinetic") ~= nil, "kinetic family")
	check(table.find(AnalyticsConfig.RecorderFamilies, "kinetic") ~= nil, "kinetic is a recorder family")
	check(AnalyticsConfig.FamilyTitles.kinetic ~= nil, "kinetic family title")
	local keys = {
		"reveal:main",
		"pull:dino",
		"pullPaid:moon",
		"pullCycles:main",
		"pullFlavor:galaxy",
		"jar:main",
		"jarTouch:dino",
		"jarPaid:main",
		"jarFull:moon",
		"tip:main",
		"tipPaid:dino",
		"admin:switch",
		"admin:status",
	}
	for _, reason in { "cooldown", "reach", "locked", "off", "noProducers", "notReady", "rate" } do
		table.insert(keys, `pullRefused:{reason}`)
	end
	for _, reason in { "empty", "reach", "locked", "off", "noIncome", "rate" } do
		table.insert(keys, `jarRefused:{reason}`)
	end
	for _, reason in { "bad", "locked", "full", "noIncome" } do
		table.insert(keys, `tipRefused:{reason}`)
	end
	for _, key in keys do
		check(KeySpec.check("kinetic", key) == key, `KeySpec accepts kinetic {key}`)
	end
	check(KeySpec.check("kinetic", "pull:atlantis") == nil, "unknown world refused")
	check(KeySpec.check("kinetic", "pullRefused:whatever") == nil, "undocumented reason refused")
	-- Models: the pieces the client animates exist; the coin pile's bottom is where config says.
	local lever = MeshAssets[KineticConfig.Models.Lever]
	local jar = MeshAssets[KineticConfig.Models.Jar]
	check(lever ~= nil and jar ~= nil, "both models in MeshAssets")
	for _, name in LEVER.ArmPieces do
		check(lever.pieces[name] ~= nil, `lever piece {name}`)
	end
	check(lever.pieces[LEVER.Chute.NukePiece] ~= nil, "lever HopperNuke piece (cloned for the chute ride)")
	local coins = jar.pieces[JAR.CoinPiece]
	check(coins ~= nil, "jar Coins piece")
	check(near(coins.offset.Y - coins.size.Y / 2, JAR.CoinBottom, 1e-3), "coin pile bottom = TipJar.CoinBottom")
	check(#LEVER.Chute.Points >= 2 and LEVER.Chute.RideSeconds > 0, "chute path")
	-- Boot lists.
	local serverBoot = fs.readFile("src/server/init.server.luau")
	local clientBoot = fs.readFile("src/client/init.client.luau")
	check(string.find(serverBoot, '"Kinetic/KineticService"', 1, true) ~= nil, "server boot list")
	check(string.find(clientBoot, '"Kinetic/KineticClient"', 1, true) ~= nil, "client boot list")
end

-- 2. Save state ---------------------------------------------------------------------------------------
do
	local fresh = KineticLogic.newState()
	check(type(fresh.worlds) == "table" and next(fresh.worlds) == nil, "newState empty")
	for _, junk in { nil, 5, "x", true, { worlds = 7 } } do
		local state = KineticLogic.reconcileState(junk)
		check(next(state.worlds) == nil, "junk → empty state")
	end
	local repaired = KineticLogic.reconcileState({
		worlds = {
			main = { readyAt = 1700000000.7, jar = 50, tips = 3 },
			dino = { readyAt = nan, jar = -4, tips = math.huge },
			["Bad Key"] = { readyAt = 5 },
			[7] = { readyAt = 5 },
			moon = "nope",
		},
	})
	check(repaired.worlds.main.readyAt == 1700000000 and repaired.worlds.main.jar == 50, "valid entry kept (floored)")
	check(
		repaired.worlds.dino.readyAt == 0 and repaired.worlds.dino.jar == 0 and repaired.worlds.dino.tips == 0,
		"junk numbers → 0"
	)
	check(repaired.worlds["Bad Key"] == nil and repaired.worlds.moon == nil, "bad keys / non-table entries dropped")
	local many = { worlds = {} }
	for i = 1, 20 do
		many.worlds[`w{i}`] = { readyAt = i }
	end
	local count = 0
	for _ in KineticLogic.reconcileState(many).worlds do
		count += 1
	end
	check(count == KineticLogic.MaxWorlds, "entries bounded")
	local state = KineticLogic.newState()
	local entry = KineticLogic.entry(state, "main")
	check(entry ~= nil and entry.readyAt == 0 and entry.jar == 0 and entry.tips == 0, "entry created fresh")
	check(KineticLogic.entry(state, "main") == entry, "entry reused")
	check(KineticLogic.entry(state, "Main!") == nil, "bad world key → nil")
	check(KineticLogic.peek(state, "dino") == nil, "peek never creates")
	-- ProfileLogic integration.
	local profile = ProfileLogic.defaultProfile()
	check(type(profile.kinetic) == "table" and next(profile.kinetic.worlds) == nil, "default profile.kinetic")
	local old = ProfileLogic.migrate({ schemaVersion = 2, cash = 5 })
	check(type(old.kinetic) == "table" and next(old.kinetic.worlds) == nil, "pre-R90 save → fresh kinetic")
	local live = ProfileLogic.defaultProfile()
	local mainEntry = KineticLogic.entry(live.kinetic, "main")
	mainEntry.readyAt, mainEntry.jar, mainEntry.tips = 1800000000, 1234.5, 7
	local back = ProfileLogic.migrate(ProfileLogic.toSave(live))
	check(
		back.kinetic.worlds.main.readyAt == 1800000000
			and back.kinetic.worlds.main.jar == 1234.5
			and back.kinetic.worlds.main.tips == 7,
		"kinetic round-trips through toSave"
	)
	check(table.find(ProfileLogic.SnapshotFields, "kinetic") == nil, "kinetic is server-only (no snapshot field)")
end

-- 3. Cooldown -----------------------------------------------------------------------------------------
do
	check(KineticLogic.cooldownLeft(1000, 940) == 60, "60 s left")
	check(KineticLogic.cooldownLeft(1000, 1000) == 0 and KineticLogic.isReady(1000, 1000), "ready at readyAt")
	check(KineticLogic.isReady(0, 1700000000), "0 = ready")
	check(not KineticLogic.isReady(1001, 1000), "1 s early = not ready")
	check(KineticLogic.cooldownLeft(nan, 5) == 0 and KineticLogic.cooldownLeft(5, nan) == 0, "NaN → ready")
	check(KineticLogic.cooldownLeft(1e12, 0) == KineticLogic.MaxCooldownAhead, "far future clamped")
	check(KineticLogic.nextReadyAt(1000.2) == 1601, "next ready rounds UP (never early)")
	check(KineticLogic.nextReadyAt(1000, 30) == 1030, "custom cooldown")
	check(KineticLogic.formatCountdown(599.2) == "10:00", "m:ss rounds up")
	check(KineticLogic.formatCountdown(0) == "0:00" and KineticLogic.formatCountdown(nan) == "0:00", "0:00")
	check(KineticLogic.formatCountdown(61) == "1:01", "1:01")
end

-- 4. Payout math --------------------------------------------------------------------------------------
do
	-- Inside the window: 10 cycles of 100 at 2 s = 1000 = 20 s of the 50/s rate (12..24): unscaled.
	local plan = KineticLogic.leverPlan({ { id = "a", perCycle = 100, cycle = 2 } }, 10, 12, 24)
	check(near(plan.total, 1000) and near(plan.scale, 1) and near(plan.rate, 50), "inside the window: x10 unscaled")
	-- Below the floor: 0.1 s cycle → raw 10 = 1 s of income → scaled up to 12 s.
	plan = KineticLogic.leverPlan({ { id = "a", perCycle = 1, cycle = 0.1 } }, 10, 12, 24)
	check(near(plan.total, 120) and near(plan.scale, 12), "floor: 12 s of the 10/s rate")
	-- Above the ceiling: 8 s cycle → raw 80 s of income → scaled down to 24 s.
	plan = KineticLogic.leverPlan({ { id = "a", perCycle = 80, cycle = 8 } }, 10, 12, 24)
	check(near(plan.total, 240) and near(plan.scale, 0.3), "ceiling: 24 s of the 10/s rate")
	-- Several producers: shares preserved, bonuses sum to the total, junk skipped.
	plan = KineticLogic.leverPlan({
		{ id = "a", perCycle = 100, cycle = 1 },
		{ id = "b", perCycle = nan, cycle = 1 },
		{ id = "c", perCycle = 300, cycle = 3 },
		{ id = "d", perCycle = 5, cycle = 0 },
		{ id = "e", perCycle = -5, cycle = 1 },
	})
	local sum = 0
	for _, bonus in plan.bonuses do
		sum += bonus
	end
	check(near(sum, plan.total), "bonuses add up to the total")
	check(plan.bonuses[2] == 0 and plan.bonuses[4] == 0 and plan.bonuses[5] == 0, "junk cycles pay 0")
	check(near(plan.bonuses[3] / plan.bonuses[1], 3), "shares preserved by the common scale")
	check(
		plan.total >= plan.rate * LEVER.MinIncomeSeconds - 1e-6
			and plan.total <= plan.rate * LEVER.MaxIncomeSeconds + 1e-6,
		"default window respected"
	)
	local empty = KineticLogic.leverPlan({})
	check(empty.total == 0 and empty.scale == 0, "no producers → nothing")
	-- flavorOf: every flavour's multiplier maps back to it.
	for _, def in FlavorConfig.Flavors do
		check(KineticLogic.flavorOf(100 * (def.mult - 1), 100) == def.id, `flavorOf {def.id}`)
	end
	check(KineticLogic.flavorOf(nan, 100) == "plain" and KineticLogic.flavorOf(5, 0) == "plain", "junk → plain")
end

-- 5. Jar ----------------------------------------------------------------------------------------------
do
	local income = 1000
	local cap = KineticLogic.jarCap(income)
	check(near(cap, JAR.FillFraction * 60 * JAR.CapMinutes * income), "cap = CapMinutes of filling")
	check(
		KineticLogic.jarCap(0) == 0 and KineticLogic.jarCap(nan) == 0 and KineticLogic.jarCap(-5) == 0,
		"no income → 0"
	)
	check(near(KineticLogic.jarFill(0, income, 1), JAR.FillFraction * income), "one second of filling")
	check(KineticLogic.jarFill(cap - 1, income, 10) == cap, "fill stops at the cap")
	check(KineticLogic.jarFill(cap * 3, income, 1) == cap * 3, "never shrinks above a lower cap")
	check(near(KineticLogic.jarFill(0, income, 1e6), JAR.FillFraction * income * 5), "dt clamped (hitch)")
	check(
		KineticLogic.jarFill(10, 0, 1) == 10 and KineticLogic.jarFill(10, income, nan) == 10,
		"no income / NaN dt: unchanged"
	)
	check(KineticLogic.jarFill(nan, income, 1) == JAR.FillFraction * income, "junk stored → 0 + step")
	-- Tips bucket.
	local tips, accepted = KineticLogic.addTips(0, 500, income)
	check(tips == 500 and accepted == 500, "tip accepted")
	local bonusCap = JAR.BonusCapIncomeSeconds * income
	tips, accepted = KineticLogic.addTips(bonusCap - 10, 500, income)
	check(tips == bonusCap and accepted == 10, "tip bucket capped")
	tips, accepted = KineticLogic.addTips(bonusCap, 500, income)
	check(accepted == 0 and tips == bonusCap, "full bucket refuses")
	for _, junk in { nan, -5, 0, math.huge } do
		local _, got = KineticLogic.addTips(0, junk, income)
		check(got == 0 or junk == math.huge, "junk tip refused")
	end
	local _, inf = KineticLogic.addTips(0, math.huge, income)
	check(inf == 0, "inf tip refused")
	-- Collect.
	local payout, reason = KineticLogic.collectable(cap * JAR.MinCollectFraction * 0.5, 0, income)
	check(payout == 0 and reason == "empty", "below the min fill: empty")
	payout = KineticLogic.collectable(cap * JAR.MinCollectFraction, 0, income)
	check(near(payout, cap * JAR.MinCollectFraction), "at the min fill: pays")
	payout = KineticLogic.collectable(0, 3, income)
	check(payout == 3, "tips alone always pay")
	payout = KineticLogic.collectable(1e12, 1e12, income)
	check(near(payout, JAR.HardCapIncomeSeconds * income), "hard ceiling")
	payout, reason = KineticLogic.collectable(500, 0, 0)
	check(payout == 0 and reason == "noIncome", "no income: refused (coins kept)")
	-- Fill ratio steps.
	check(KineticLogic.fillRatio(cap / 2, 0, income) == 0.5, "half full")
	check(KineticLogic.fillRatio(0, 0, income) == 0, "empty")
	check(KineticLogic.fillRatio(1, 0, income) == 1 / JAR.FillSteps, "any coins show the first step")
	check(KineticLogic.fillRatio(cap * 5, 0, income) == 1, "never above 1")
	check(KineticLogic.fillRatio(cap * 0.5, cap * 0.25, income) == 0.75, "tips show on top")
	check(KineticLogic.fillRatio(5, 0, 0) == 1 and KineticLogic.fillRatio(0, 0, 0) == 0, "no income: full if any coins")
end

-- 6. Pacing -------------------------------------------------------------------------------------------
do
	local flavor = FlavorLogic.expectedMultiplier(FlavorConfig.PacingLuck)
	local lift = KineticLogic.pacingLift(flavor)
	check(lift > 0 and lift <= KineticConfig.Pacing.MaxLift, `pacing lift {lift} within MaxLift`)
	check(
		near(lift, LEVER.MaxIncomeSeconds / LEVER.CooldownSeconds * flavor + JAR.FillFraction, 1e-9),
		"lift = lever ceiling share x flavour + jar rate (shares 1)"
	)
	check(KineticLogic.pacingLift(nan) == KineticLogic.pacingLift(1), "junk flavour lift → none")
end

-- 7. Placement (owner R116: INSIDE the plot) --------------------------------------------------------
do
	local LuckyConfig = loader.load("src/shared/Config/LuckyButtonConfig")
	local BillboardSpots = loader.load("src/shared/Config/BillboardSpots")
	local placement = KineticConfig.Placement
	local AREA = placement.Area
	check(AREA >= 1 and AREA < KineticConfig.UnlockArea, "the props' area is fully bought before they appear")
	-- D1_Jungle (Dino Area 1) is ONE mesh of scattered palms / ferns / boulders split only L / R, so its
	-- piece boxes span the whole lawn. Its real clumps come from tools/blender/models/dino_area01.py
	-- build_jungle (palm canopy r 6, fern r 3.6 = max frond reach, boulder r x 1.4). The triangle pin
	-- flags any art change that would need this list re-derived.
	local JUNGLE_TRIANGLES = 2472
	local jungle: { any } = {}
	for _, p in { { -44, 20 }, { -38, 4.5 }, { 44, 22 }, { 39, 4.5 }, { -30, 36 }, { 38, 32 } } do
		table.insert(jungle, LuckyLogic.point(p[1], p[2], 6))
	end
	for _, p in { { -48, 30 }, { -34, 19 }, { -24, 2 }, { 48, 31 }, { 34, 19 }, { 25, 2 }, { -9, 37 }, { 11, 34 } } do
		table.insert(jungle, LuckyLogic.point(p[1], p[2], 3.6))
	end
	for _, p in { { -46, 18, 1.4 }, { -29, 28, 1.0 }, { 47, 18, 1.3 }, { 28, 29, 1.1 } } do
		table.insert(jungle, LuckyLogic.point(p[1], p[2], p[3] * 1.4))
	end
	-- Model-local footprint sample points (1-stud grid over the box, edges included).
	local function footprint(box: any): { any }
		local points = {}
		local hx, hz = box.size.X / 2, box.size.Z / 2
		local nx, nz = math.ceil(box.size.X), math.ceil(box.size.Z)
		for i = 0, nx do
			for j = 0, nz do
				table.insert(
					points,
					Vector3.new(box.center.X - hx + i * box.size.X / nx, 0, box.center.Z - hz + j * box.size.Z / nz)
				)
			end
		end
		return points
	end
	local PROPS = {
		{
			name = "Lever",
			mount = placement.Lever,
			points = footprint(placement.LeverFootprint),
			keep = placement.KeepOut.Lever,
		},
		{
			name = "Jar",
			mount = placement.Jar,
			points = footprint(placement.JarFootprint),
			keep = placement.KeepOut.Jar,
		},
	}
	-- Slot-local footprint points of each prop (the same in every world and on every plot).
	for _, prop in PROPS do
		prop.slotPoints = {}
		for _, point in prop.points do
			table.insert(prop.slotPoints, prop.mount * point)
		end
		for _, p in prop.slotPoints do
			check(
				p.X >= prop.keep.minX and p.X <= prop.keep.maxX and p.Z >= prop.keep.minZ and p.Z <= prop.keep.maxZ,
				`{prop.name}: footprint inside its published KeepOut`
			)
			-- Inside the area slot (whose edges are the area's fence / curb lines) with 1 stud spare.
			check(
				math.abs(p.X) <= WorldLayout.SlotHalfWidth - 1 and p.Z >= 1 and p.Z <= WorldLayout.SlotDepth - 1,
				`{prop.name}: inside the Area {AREA} slot (fence lines)`
			)
		end
	end
	-- The two props never overlap (2 studs of air between their footprints).
	for _, a in PROPS[1].slotPoints do
		for _, b in PROPS[2].slotPoints do
			check(
				(Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude >= 2,
				"lever and jar keep 2 studs apart"
			)
		end
	end
	local function configPath(parts: { string }): string
		return "src/shared/Config/" .. table.concat(parts, "/")
	end
	for _, worldId in WorldsConfig.Order do
		local def = WorldsConfig.get(worldId)
		local hub = loader.load(configPath(def.hubLayout))
		local layout = loader.load(string.format(configPath(def.layoutFolder) .. "/Area%02d", AREA))
		-- The area's pads all stand at the lot height the props are placed at.
		for _, pad in layout.pads or {} do
			for _, prop in PROPS do
				check(math.abs(pad.Y - prop.mount.Position.Y) < 1e-6, `{worldId}: {prop.name} stands at the lot height`)
			end
		end
		-- Area 1's pads are all bought when the props exist (they never block one), so the geometry is
		-- built without them; every other keep-out (producer, billboards) and solid stays.
		local copy = table.clone(layout)
		copy.pads = {}
		local usesJungle = false
		local base = { models = {}, collision = layout.base.collision }
		for _, model in layout.base.models or {} do
			if model.key == "D1_Jungle" then
				usesJungle = true
			else
				table.insert(base.models, model)
			end
		end
		copy.base = base
		local spots = if worldId == WorldsConfig.MAIN
			then BillboardSpots[AREA]
			else (BillboardSpots.worlds[worldId] or {})[AREA]
		local geometry = LuckyLogic.slotGeometry({
			layout = copy,
			spots = spots,
			frame = hub.plotFrame,
			toSlot = WorldLayout.slotLocal(AREA, worldId):Inverse(),
			plotHalfWidth = WorldLayout.PlotHalfWidth,
			plotLength = WorldLayout.plotLength(worldId),
			meshes = MeshAssets,
		})
		if usesJungle then
			check(
				MeshAssets.D1_Jungle.triangles == JUNGLE_TRIANGLES,
				"D1_Jungle art unchanged (else re-derive the clumps)"
			)
			for _, clump in jungle do
				table.insert(geometry.solids, clump)
			end
		end
		check(#geometry.supports > 0, `{worldId}: Area {AREA} walkable ground found`)
		local spawn = layout.spawnPoint
		for _, prop in PROPS do
			for _, p in prop.slotPoints do
				local x, z = p.X, p.Z
				local supported = false
				for _, support in geometry.supports do
					if LuckyLogic.inside(support, x, z, 0.3) then
						supported = true
						break
					end
				end
				check(supported, `{worldId} {prop.name}: on the plot's walkable ground`)
				check(
					LuckyLogic.isClear(x, z, geometry.solids, 1),
					`{worldId} {prop.name}: clear of buildings / props / fences`
				)
				check(
					LuckyLogic.isClear(x, z, geometry.keepouts, 2),
					`{worldId} {prop.name}: clear of the producer + its billboards`
				)
				if typeof(spawn) == "Vector3" then
					check(
						(Vector3.new(x, 0, z) - Vector3.new(spawn.X, 0, spawn.Z)).Magnitude >= 4,
						`{worldId} {prop.name}: clear of the area's teleport spawn`
					)
				end
				-- Never where a Lucky Button / Happy Hour pickup can stand: a button's centre keeps
				-- Clearance from every pad box (bought or not) and SlotMargin from the road edge, so its
				-- base never reaches a point inside (Clearance - ButtonRadius) of a pad or below
				-- (SlotMargin - ButtonRadius).
				local luckySafe = z < LuckyConfig.SlotMargin - LuckyConfig.ButtonRadius
				for _, pad in layout.pads or {} do
					if
						LuckyLogic.distance(LuckyLogic.point(pad.X, pad.Z, LuckyConfig.PadHalf), x, z)
						< LuckyConfig.Clearance - LuckyConfig.ButtonRadius
					then
						luckySafe = true
						break
					end
				end
				check(luckySafe, `{worldId} {prop.name}: no Lucky Button / pickup can spawn on it`)
			end
		end
		-- Plot-level checks on all 8 plots: inside the plot footprint, off the road, away from the
		-- entrance arch + plot sign, the world helper agrees.
		local plotLength = WorldLayout.plotLength(worldId)
		for plot = 1, WorldLayout.PlotCount do
			local origin = WorldLayout.plotOrigin(plot, worldId)
			for _, prop in PROPS do
				local mounted = KineticLogic.mountCFrame(plot, worldId, prop.name)
				check(
					(mounted.Position - WorldLayout.slotToWorld(plot, AREA, prop.mount, worldId).Position).Magnitude
						< 1e-6,
					`{worldId} plot {plot} {prop.name}: mountCFrame = the slot spot`
				)
				for _, p in prop.slotPoints do
					local world = WorldLayout.slotPointToWorld(plot, AREA, p, worldId)
					local l = origin:PointToObjectSpace(world)
					check(
						math.abs(l.X) <= WorldLayout.PlotHalfWidth - 2 and l.Z >= 2 and l.Z <= plotLength - 2,
						`{worldId} plot {plot} {prop.name}: inside the plot footprint`
					)
					check(
						math.abs(l.X) >= WorldLayout.RoadHalfWidth + 1,
						`{worldId} plot {plot} {prop.name}: off the road`
					)
					check(l.Z >= 12, `{worldId} plot {plot} {prop.name}: clear of the entrance arch + plot sign`)
					check(
						WorldLayout.plotAt(world, worldId) == plot,
						`{worldId} plot {plot} {prop.name}: WorldLayout.plotAt says it is this plot`
					)
				end
			end
		end
	end
	-- D-defense's AA tower slots stand outside the plot's side curbs: the props are inside it.
	for _, slot in AttackConfig.Towers.Slots do
		for _, prop in PROPS do
			for _, p in prop.slotPoints do
				local l = WorldLayout.slotLocal(AREA) * p
				local dx = math.abs(l.X - slot.at.X) - AttackConfig.Towers.FootprintHalf
				local dz = math.abs(l.Z - slot.at.Z) - AttackConfig.Towers.FootprintHalf
				check(dx > 2 or dz > 2, `{prop.name}: clear of AA slot {slot.id}`)
			end
		end
	end
end

-- 8. Validation ---------------------------------------------------------------------------------------
do
	local pull = KineticLogic.decodeWire({
		kind = "pull",
		world = "main",
		total = 1200,
		currency = "cash",
		readyAt = 1800000000,
		cycles = {
			{ id = "p1_workbench", amount = 600, flavor = "plain" },
			{ id = "p2_stand", amount = 600, flavor = "galaxy" },
		},
	})
	check(pull ~= nil and pull.kind == "pull" and #pull.cycles == 2 and pull.cycles[2].flavor == "galaxy", "pull wire")
	local collect = KineticLogic.decodeWire({ kind = "collect", world = "dino", amount = 5, currency = "bones" })
	check(collect ~= nil and collect.kind == "collect" and collect.amount == 5, "collect wire")
	local tip = KineticLogic.decodeWire({ kind = "tip", world = "moon", amount = 9, currency = "moonrocks" })
	check(tip ~= nil and tip.kind == "tip", "tip wire")
	local hostile = {
		5,
		"pull",
		{},
		{ kind = "pull" },
		{ kind = "explode", world = "main", amount = 5, currency = "cash" },
		{ kind = "collect", world = "Main", amount = 5, currency = "cash" },
		{ kind = "collect", world = "main", amount = nan, currency = "cash" },
		{ kind = "collect", world = "main", amount = -1, currency = "cash" },
		{ kind = "collect", world = "main", amount = math.huge, currency = "cash" },
		{ kind = "collect", world = "main", amount = 5, currency = string.rep("c", 80) },
		{ kind = "collect", world = "main", amount = 5, currency = "ca sh" },
		{ kind = "pull", world = "main", total = 5, currency = "cash", readyAt = 1, cycles = "x" },
		setmetatable({}, {
			__index = function()
				error("never index a hostile payload's metatable")
			end,
		}),
	}
	for index, raw in hostile do
		local ok, result = pcall(KineticLogic.decodeWire, raw)
		check(ok and result == nil, `hostile wire {index} refused without throwing`)
	end
	-- Cycles are trimmed to MaxWireCycles and junk entries dropped.
	local many = {}
	for i = 1, 40 do
		table.insert(many, { id = `p{i}`, amount = i, flavor = "plain" })
	end
	table.insert(many, 3, { id = "bad id!", amount = 1, flavor = "plain" })
	local trimmed = KineticLogic.decodeWire({
		kind = "pull",
		world = "main",
		total = 1,
		currency = "cash",
		readyAt = 1,
		cycles = many,
	})
	check(trimmed ~= nil and #trimmed.cycles <= LEVER.MaxWireCycles, "cycles trimmed")
	-- Reach + near-plot.
	check(KineticLogic.withinReach(Vector3.new(0, 3, 0), Vector3.new(10, 0, 0), 18, 20), "within reach")
	check(not KineticLogic.withinReach(Vector3.new(0, 0, 0), Vector3.new(19, 0, 0), 18, 20), "too far")
	check(not KineticLogic.withinReach(Vector3.new(0, 25, 0), Vector3.new(1, 0, 0), 18, 20), "too high")
	local length = WorldLayout.plotLength("main")
	check(KineticLogic.nearPlot(Vector3.new(-22, 0, 34), length), "the props' front yard counts as near")
	check(KineticLogic.nearPlot(Vector3.new(94, 0, 62), length), "just outside the side curb still counts as near")
	check(KineticLogic.nearPlot(Vector3.new(0, 0, length + JAR.NearMargin), length), "edge of the margin")
	check(not KineticLogic.nearPlot(Vector3.new(0, 0, -JAR.NearMargin - 1), length), "out on the ring road / hub")
	check(
		not KineticLogic.nearPlot(Vector3.new(WorldLayout.PlotHalfWidth + JAR.NearMargin + 1, 0, 50), length),
		"beside, too far"
	)
end

-- 9. Server wiring (source scan) ----------------------------------------------------------------------
do
	local service = fs.readFile("src/server/Kinetic/KineticService.luau")
	check(string.find(service, 'Remotes.onServerEvent("KineticAction"', 1, true) ~= nil, "intent through onServerEvent")
	check(string.find(service, "limiter:Allow(player)", 1, true) ~= nil, "intent rate-limited")
	check(
		string.find(service, "Validate.oneOf(rawAction, KineticConfig.Actions)", 1, true) ~= nil,
		"action allowlisted"
	)
	check(string.find(service, "limiter:Forget(player)", 1, true) ~= nil, "limiter bucket forgotten on leave")
	local lever = fs.readFile("src/server/Kinetic/MegaLever.luau")
	local commit = string.find(lever, "entry.readyAt = KineticLogic.nextReadyAt(now)", 1, true)
	local grant = string.find(lever, "PlayerDataService.grantCurrency(", 1, true)
	check(commit ~= nil and grant ~= nil and commit < grant, "lever cooldown committed before the grant")
	check(
		string.find(lever, "FlavorService.batch(player, worldId, cycle.id, 1, bonus, true)", 1, true) ~= nil,
		"flavours via the public API"
	)
	local jar = fs.readFile("src/server/Kinetic/TipJar.luau")
	local empty = string.find(jar, "entry.jar, entry.tips = 0, 0", 1, true)
	local pay = string.find(jar, "PlayerDataService.grantCurrency(player, currency, payout", 1, true)
	check(empty ~= nil and pay ~= nil and empty < pay, "jar emptied before the grant")
	check(
		string.find(jar, "Players:GetPlayerFromCharacter(character) ~= owner", 1, true) ~= nil,
		"touch counts the owner only"
	)
end

print(`[kinetic-logic] {checks} checks passed`)
