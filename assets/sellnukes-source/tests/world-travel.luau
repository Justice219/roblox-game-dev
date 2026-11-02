--!strict
--[[
	World travel rules (World 2 plan §4 W4.1, §5 "world-travel"): Server/Tycoon/TravelRules.

	Proves
		* The full TravelRules.check truth table: every reason in check order, each one reachable
		  alone from a passing context, and earlier rules win over later ones.
		* Boundary indices per target (spawn nil only; area 1..areaCount per world; plot 1..8) and
		  NaN / inf / -inf / fractional / string / table indices, unknown worlds + targets.
		* Cooldown edges (exactly at the boundary passes, just before fails, NaN / +inf fail closed,
		  -inf = never travelled), garbage booleans fail closed.
		* Own vs other plot with and without the Teleporter pass; empty plots.
		* Unlock helpers: progress(), isUnlocked (sticky), shouldUnlock (rule), unlockSource, and
		  the visit / play-time counters (clamped, first-today / first-ever).

	Run: lune run tests/world-travel.luau            (from the repo root)
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local TravelRules = loader.load("src/server/Tycoon/TravelRules")
local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
local WorldLayout = loader.load("src/shared/Config/WorldLayout")

local checks = 0
local function check(ok: boolean, message: string)
	assert(ok, message)
	checks += 1
end

local NAN = 0 / 0
local INF = math.huge

-- A context that passes for `target` in Dino Valley; `overrides` replace fields.
local function ctx(overrides: { [string]: any }?): any
	local base: { [string]: any } = {
		worldId = "dino",
		target = "spawn",
		index = nil,
		now = 100,
		enabled = true,
		unlocked = true,
		hasPlot = true,
		revealed = true,
		alive = true,
		busy = false,
		cooldownUntil = 0,
		areaUnlocked = nil,
		plotOwned = nil,
		ownPlot = nil,
		hasTeleporter = false,
		areaCount = 6,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return base
end

-- check() with `overrides`; returns the reason ("ok" when allowed).
local function reasonOf(overrides: { [string]: any }?): string
	local ok, reason = TravelRules.check(ctx(overrides))
	if ok then
		assert(reason == nil, "an allowed travel carries no reason")
		return "ok"
	end
	assert(type(reason) == "string", "a refusal always carries a reason")
	return reason :: string
end

local dino = WorldsConfig.get("dino")
assert(dino ~= nil, "Dino Valley is registered")
local main = WorldsConfig.get("main")
assert(main ~= nil, "Nuke Town is registered")

--------------------------------------------------------------------------------------------------
-- Constants + allowlists
--------------------------------------------------------------------------------------------------
do
	check(TravelRules.CooldownSeconds == 2, "spec §11: 2 s cooldown")
	check(TravelRules.DeadlineSeconds == 4, "spec §4.5: 4 s hard deadline")
	check(TravelRules.StreamTimeout == 3, "plan §3.4: 3 s stream timeout")
	check(TravelRules.RateBurst == 3 and TravelRules.RateRefill == 0.5, "spec §11: RateLimiter(3, 0.5)")
	check(TravelRules.CoverSeconds > 0 and TravelRules.CoverSeconds < TravelRules.DeadlineSeconds, "cover < deadline")
	check(#TravelRules.Reasons == 12 and table.isfrozen(TravelRules.Reasons), "12 frozen reasons")
	local seen: { [string]: boolean } = {}
	for _, reason in TravelRules.Reasons do
		check(not seen[reason], `reason {reason} unique`)
		seen[reason] = true
	end
	check(#TravelRules.Targets == 3 and table.isfrozen(TravelRules.Targets), "3 frozen targets")
	for _, source in { "portal", "menu", "popup", "chip", "admin", "respawn" } do
		check(TravelRules.validSource(source), `source {source}`)
	end
	for _, junk in { "hack", "", 5, nil, {}, "Portal" } :: { any } do
		check(not TravelRules.validSource(junk), `junk source {tostring(junk)}`)
	end
	check(not pcall(function()
		(TravelRules :: any).CooldownSeconds = 0
	end), "TravelRules is frozen")
end

--------------------------------------------------------------------------------------------------
-- Every reason alone, in check order
--------------------------------------------------------------------------------------------------
do
	check(reasonOf(nil) == "ok", "the base context passes (spawn)")
	check(reasonOf({ target = "area", index = 3, areaUnlocked = true }) == "ok", "area passes")
	check(reasonOf({ target = "plot", index = 4, plotOwned = true, ownPlot = true }) == "ok", "own plot passes")
	check(reasonOf({ worldId = "main" }) == "ok", "Nuke Town spawn passes")

	local single: { { any } } = {
		{ { worldId = "nope" }, "unknownWorld" },
		{ { target = "moon" }, "badTarget" },
		{ { enabled = false }, "disabled" },
		{ { unlocked = false }, "locked" },
		{ { hasPlot = false }, "noPlot" },
		{ { revealed = false }, "revealPending" },
		{ { alive = false }, "dead" },
		{ { busy = true }, "busy" },
		{ { cooldownUntil = 101 }, "cooldown" },
		{ { target = "area", index = 2, areaUnlocked = false }, "areaLocked" },
		{ { target = "plot", index = 2, plotOwned = false }, "plotEmpty" },
		{ { target = "plot", index = 2, plotOwned = true, ownPlot = false }, "noPass" },
	}
	for _, row in single do
		check(reasonOf(row[1]) == row[2], `alone: {row[2]}`)
	end

	-- Every reason in order: with ALL failures present the first wins; drop it and the next shows.
	local failures: { { [string]: any } } = {
		{ worldId = "nope" },
		{ target = "moon" },
		{ enabled = false },
		{ unlocked = false },
		{ hasPlot = false },
		{ revealed = false },
		{ alive = false },
		{ busy = true },
		{ cooldownUntil = 1e9 },
	}
	for first = 1, #failures do
		local overrides: { [string]: any } = {}
		for index = first, #failures do
			for key, value in failures[index] do
				overrides[key] = value
			end
		end
		check(reasonOf(overrides) == TravelRules.Reasons[first], `order: {TravelRules.Reasons[first]} first`)
	end
	-- Target-specific checks come last: a locked area in a disabled world reports "disabled".
	check(reasonOf({ target = "area", index = 2, areaUnlocked = false, enabled = false }) == "disabled", "state first")
	check(
		reasonOf({ target = "plot", index = 2, plotOwned = false, ownPlot = false }) == "plotEmpty",
		"empty plot before the pass check"
	)
end

--------------------------------------------------------------------------------------------------
-- Targets + indices: boundaries, NaN / inf, wrong types
--------------------------------------------------------------------------------------------------
do
	-- spawn takes no index at all.
	for _, index in { 1, 0, NAN, INF, "1", {} } :: { any } do
		check(reasonOf({ target = "spawn", index = index }) == "badTarget", `spawn + index {tostring(index)}`)
	end
	-- area: whole 1..areaCount of THAT world (Dino 6, Nuke Town 10).
	for index = 1, 6 do
		check(reasonOf({ target = "area", index = index, areaUnlocked = true }) == "ok", `dino area {index}`)
	end
	for _, index in { 0, 7, -1, 1.5, 6.0001, NAN, INF, -INF, "2", {}, true } :: { any } do
		check(
			reasonOf({ target = "area", index = index, areaUnlocked = true }) == "badTarget",
			`dino area {tostring(index)}`
		)
	end
	check(reasonOf({ target = "area", index = nil, areaUnlocked = true }) == "badTarget", "area needs an index")
	check(
		reasonOf({ worldId = "main", target = "area", index = 10, areaUnlocked = true, areaCount = 10 }) == "ok",
		"main area 10"
	)
	check(
		reasonOf({ worldId = "main", target = "area", index = 11, areaUnlocked = true, areaCount = 10 }) == "badTarget",
		"main area 11"
	)
	-- The registry is the authority: a bigger context count never widens the range ...
	check(
		reasonOf({ target = "area", index = 7, areaUnlocked = true, areaCount = 10 }) == "badTarget",
		"ctx areaCount cannot widen"
	)
	-- ... a smaller one narrows it, and garbage counts fall back to the registry.
	check(reasonOf({ target = "area", index = 5, areaUnlocked = true, areaCount = 4 }) == "badTarget", "narrowed")
	check(
		reasonOf({ target = "area", index = 6, areaUnlocked = true, areaCount = NAN }) == "ok",
		"NaN count -> registry"
	)
	check(reasonOf({ target = "area", index = 1, areaUnlocked = true, areaCount = 0 }) == "badTarget", "0 areas")
	-- plot: whole 1..PlotCount.
	check(WorldLayout.PlotCount == 8, "8 plots")
	for index = 1, 8 do
		check(reasonOf({ target = "plot", index = index, plotOwned = true, ownPlot = true }) == "ok", `plot {index}`)
	end
	for _, index in { 0, 9, 2.5, NAN, INF, -INF, "3", nil } :: { any } do
		check(
			reasonOf({ target = "plot", index = index, plotOwned = true, ownPlot = true }) == "badTarget",
			`plot {tostring(index)}`
		)
	end
	-- Unknown / malformed worlds and targets.
	for _, worldId in { "Dino", "DINO", "", 5, NAN, nil, {}, "dino\0", string.rep("a", 64) } :: { any } do
		check(reasonOf({ worldId = worldId }) == "unknownWorld", `world {tostring(worldId)}`)
	end
	for _, target in { "Spawn", "", nil, 1, {}, "plots" } :: { any } do
		check(reasonOf({ target = target }) == "badTarget", `target {tostring(target)}`)
	end
	check(TravelRules.validTarget("area", 3, 6) and not TravelRules.validTarget("area", 3, NAN), "validTarget")
	-- A non-table context never passes.
	local ok, reason = TravelRules.check(nil :: any)
	check(not ok and reason == "unknownWorld", "nil context")
end

--------------------------------------------------------------------------------------------------
-- Cooldown edges + garbage booleans (fail closed)
--------------------------------------------------------------------------------------------------
do
	check(reasonOf({ now = 10, cooldownUntil = 10 }) == "ok", "exactly at the cooldown end passes")
	check(reasonOf({ now = 9.999, cooldownUntil = 10 }) == "cooldown", "just before fails")
	check(reasonOf({ now = 10, cooldownUntil = -INF }) == "ok", "-inf = never travelled")
	check(reasonOf({ now = 10, cooldownUntil = INF }) == "cooldown", "+inf fails closed")
	check(reasonOf({ now = 10, cooldownUntil = NAN }) == "cooldown", "NaN cooldown fails closed")
	check(reasonOf({ now = NAN }) == "cooldown", "NaN clock fails closed")
	check(reasonOf({ now = INF }) == "cooldown", "inf clock fails closed")
	check(reasonOf({ cooldownUntil = "0" }) == "cooldown", "string cooldown fails closed")
	-- A full cooldown window: travel at t, refused through t + 2, allowed at t + 2.
	local at = 50
	local untilAt = at + TravelRules.CooldownSeconds
	check(reasonOf({ now = at + 1.99, cooldownUntil = untilAt }) == "cooldown", "inside the window")
	check(reasonOf({ now = at + 2, cooldownUntil = untilAt }) == "ok", "window end")

	for _, junk in { 1, "true", {}, nil } :: { any } do
		check(reasonOf({ enabled = junk }) == "disabled", `enabled {tostring(junk)}`)
		check(reasonOf({ unlocked = junk }) == "locked", `unlocked {tostring(junk)}`)
		check(reasonOf({ hasPlot = junk }) == "noPlot", `hasPlot {tostring(junk)}`)
		check(reasonOf({ revealed = junk }) == "revealPending", `revealed {tostring(junk)}`)
		check(reasonOf({ alive = junk }) == "dead", `alive {tostring(junk)}`)
		check(reasonOf({ busy = junk }) == "busy", `busy {tostring(junk)}`)
		check(
			reasonOf({ target = "area", index = 1, areaUnlocked = junk }) == "areaLocked",
			`areaUnlocked {tostring(junk)}`
		)
		check(
			reasonOf({ target = "plot", index = 1, plotOwned = junk, ownPlot = true }) == "plotEmpty",
			`plotOwned junk`
		)
		check(
			reasonOf({ target = "plot", index = 1, plotOwned = true, ownPlot = junk, hasTeleporter = junk }) == "noPass",
			`ownPlot / pass {tostring(junk)}`
		)
	end
end

--------------------------------------------------------------------------------------------------
-- Own vs other plot, with and without the Teleporter pass (both worlds)
--------------------------------------------------------------------------------------------------
do
	for _, worldId in { "main", "dino" } do
		local function plot(owned: boolean, own: boolean, pass: boolean): string
			return reasonOf({
				worldId = worldId,
				target = "plot",
				index = 5,
				plotOwned = owned,
				ownPlot = own,
				hasTeleporter = pass,
				areaCount = if worldId == "main" then 10 else 6,
			})
		end
		check(plot(true, true, false) == "ok", `{worldId}: own plot is free`)
		check(plot(true, true, true) == "ok", `{worldId}: own plot with the pass`)
		check(plot(true, false, false) == "noPass", `{worldId}: other plot needs the pass`)
		check(plot(true, false, true) == "ok", `{worldId}: other plot with the pass`)
		check(plot(false, false, true) == "plotEmpty", `{worldId}: empty plot even with the pass`)
		check(plot(false, true, false) == "plotEmpty", `{worldId}: unowned plot`)
	end
end

--------------------------------------------------------------------------------------------------
-- Unlock helpers (spec §4.1: main area 3 OR 1 main rebirth; sticky)
--------------------------------------------------------------------------------------------------
do
	local function profile(area: any, rebirths: any, unlocked: any): any
		return {
			tycoon = { area = area },
			rebirths = rebirths,
			worlds = { dino = { unlocked = unlocked, tycoon = { area = 2 }, rebirths = 4 } },
		}
	end
	local progress = TravelRules.progress(profile(3, 1, false))
	check(progress.main.area == 3 and progress.main.rebirths == 1, "main progress")
	check(progress.dino.area == 2 and progress.dino.rebirths == 4, "dino progress")
	local junk = TravelRules.progress(profile(NAN, -INF, false))
	check(junk.main.area == 0 and junk.main.rebirths == 0, "garbage progress counts as nothing")
	check(next(TravelRules.progress(nil)) == nil, "nil profile -> empty progress")
	check(TravelRules.progress({ tycoon = 5, rebirths = "3" }).main.area == 0, "malformed tycoon")

	check(TravelRules.isUnlocked(main, nil), "Nuke Town is always unlocked")
	check(not TravelRules.isUnlocked(dino, profile(3, 0, false)), "flag false -> locked (rule not consulted)")
	check(TravelRules.isUnlocked(dino, profile(1, 0, true)), "sticky: flag true stays unlocked after a rebirth")
	check(not TravelRules.isUnlocked(dino, profile(1, 0, "true")), "flag must be exactly true")
	check(not TravelRules.isUnlocked(dino, { worlds = 5 }), "malformed worlds")

	check(TravelRules.shouldUnlock(dino, profile(3, 0, false)), "area 3 unlocks")
	check(not TravelRules.shouldUnlock(dino, profile(2, 0, false)), "area 2 does not")
	check(TravelRules.shouldUnlock(dino, profile(1, 1, false)), "1 rebirth unlocks")
	check(TravelRules.shouldUnlock(dino, profile(10, 5, false)), "late game unlocks (legacy)")
	check(not TravelRules.shouldUnlock(dino, profile(3, 0, true)), "already unlocked")
	check(not TravelRules.shouldUnlock(main, profile(1, 0, false)), "never for Nuke Town")
	check(not TravelRules.shouldUnlock(dino, profile(INF, NAN, false)), "inf area fails closed")

	local areaProgress = TravelRules.progress(profile(3, 0, false))
	local rebirthProgress = TravelRules.progress(profile(1, 1, false))
	check(TravelRules.unlockSource(dino, areaProgress, "area") == "area", "source area")
	check(TravelRules.unlockSource(dino, rebirthProgress, "rebirth") == "rebirth", "source rebirth")
	check(TravelRules.unlockSource(dino, areaProgress, "rebirth") == "area", "rebirth event but area passes")
	check(TravelRules.unlockSource(dino, areaProgress, "load") == "legacy", "source legacy")
	check(TravelRules.unlockSource(dino, rebirthProgress, "admin") == "admin", "source admin")
end

--------------------------------------------------------------------------------------------------
-- Visit + play-time counters
--------------------------------------------------------------------------------------------------
do
	check(TravelRules.dayOf(0) == 0 and TravelRules.dayOf(86400 * 3 + 5) == 3, "dayOf")
	check(TravelRules.dayOf(NAN) == 0 and TravelRules.dayOf(-5) == 0, "dayOf garbage")

	local stats: any = { visits = 0, lastVisitDay = -1, playSeconds = 0, runSeconds = 0 }
	local today, ever = TravelRules.recordVisit(stats, 100)
	check(today and ever and stats.visits == 1 and stats.lastVisitDay == 100, "first visit ever")
	today, ever = TravelRules.recordVisit(stats, 100)
	check(not today and not ever and stats.visits == 2, "second visit same day")
	today, ever = TravelRules.recordVisit(stats, 101)
	check(today and not ever and stats.visits == 3 and stats.lastVisitDay == 101, "next day")
	stats.visits = TravelRules.MaxCounter
	TravelRules.recordVisit(stats, 102)
	check(stats.visits == TravelRules.MaxCounter, "visits clamp")
	local a, b = TravelRules.recordVisit(nil, 1)
	check(not a and not b, "nil stats ignored")
	a, b = TravelRules.recordVisit({ visits = NAN, lastVisitDay = 1 }, NAN)
	check(not a and not b, "NaN day ignored")

	check(TravelRules.addSeconds(stats, 1) and stats.playSeconds == 1 and stats.runSeconds == 1, "1 s added")
	check(not TravelRules.addSeconds(stats, 0) and not TravelRules.addSeconds(stats, -3), "non-positive ignored")
	check(not TravelRules.addSeconds(stats, NAN) and not TravelRules.addSeconds(stats, INF), "NaN / inf ignored")
	check(stats.playSeconds == 1, "unchanged by junk")
	stats.playSeconds = TravelRules.MaxCounter
	TravelRules.addSeconds(stats, 5)
	check(stats.playSeconds == TravelRules.MaxCounter and stats.runSeconds == 6, "playSeconds clamp")
	local broken: any = { playSeconds = NAN, runSeconds = "x" }
	TravelRules.addSeconds(broken, 2)
	check(broken.playSeconds == 2 and broken.runSeconds == 2, "garbage counters reset to finite")
end

print(`[world-travel] {checks} checks passed`)
