--!strict
--[[
	TravelRules — the PURE rules of world travel (owner R57 World 2, spec §4 + §11, plan §3.4).
	No Instances, no services, no clocks: WorldService gathers the facts, this module decides.
	tests/world-travel.luau proves the whole truth table.

	What is here
		check(ctx)                    may this travel request run? (ok, reason?) — the ONE gate every
		                              TravelWorld intent, portal, admin send and chip goes through
		progress(profile)             per-world { area, rebirths } for WorldsConfig.unlockPasses
		isUnlocked(def, profile)      main always; else the sticky profile flag
		shouldUnlock(def, profile)    rule passes and the sticky flag is still false
		unlockSource(def, progress, event)   analytics source of an unlock ("area" | "rebirth" | ...)
		dayOf(unix) / recordVisit(stats, day)   visit counter + "first visit today" (unique visitor)
		addSeconds(stats, seconds)    the 1 Hz play-time counters (clamped)

	Check order (the first failing rule is the reason; the client toasts WorldClientConfig.FailText):
		unknownWorld   world id is not a registry world (Validate already drops junk packets; this is
		               the second line of defence for server callers)
		badTarget      target not spawn / area / plot, or an index that does not fit it (spawn: nil;
		               area: whole 1..areaCount; plot: whole 1..PlotCount) — NaN / inf / strings fail
		disabled       admin kill switch (WorldEnabled_<id> == false)
		locked         world not unlocked for this player (rule + sticky flag)
		noPlot         the player has no Nuke Town plot (queued: "Waiting for a plot")
		revealPending  the join plot reveal has not finished (R16: travel can never skip it)
		dead           no living character
		busy           a travel is already in flight
		cooldown       CooldownSeconds after the last travel has not passed
		areaLocked     target "area": that area of the player's plot in that world is not unlocked
		plotEmpty      target "plot": nobody owns that plot
		noPass         target "plot": someone else's plot without the Teleporter pass
	Every boolean is checked with `== true` / `~= false`, so a garbage context fails CLOSED.

	Connections
		Server/Tycoon/WorldService (the only runtime caller), Shared/Config/Worlds/WorldsConfig
		(registry + unlock rule), Shared/Config/WorldLayout (PlotCount). Reasons mirror
		Shared/Config/WorldClientConfig.FailText (W5) and analytics `travelFail:<w>:<reason>`.

	Usage
		local ok, reason = TravelRules.check({
			worldId = "dino", target = "area", index = 2, now = os.clock(), enabled = true,
			unlocked = true, hasPlot = true, revealed = true, alive = true, busy = false,
			cooldownUntil = 0, areaUnlocked = true, hasTeleporter = false, areaCount = 6,
		}) --> true, nil
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

export type TravelTarget = "spawn" | "area" | "plot"
export type TravelSource = "portal" | "menu" | "popup" | "chip" | "admin" | "respawn"
export type TravelReason =
	"unknownWorld"
	| "badTarget"
	| "disabled"
	| "locked"
	| "noPlot"
	| "revealPending"
	| "dead"
	| "busy"
	| "cooldown"
	| "areaLocked"
	| "plotEmpty"
	| "noPass"

--[[
	Everything check() needs, gathered by WorldService at request time (server truth only).
	`areaUnlocked` matters for target "area"; `plotOwned` / `ownPlot` for target "plot".
]]
export type TravelContext = {
	worldId: string?,
	target: string?,
	index: number?,
	now: number, -- os.clock() seconds (same clock as cooldownUntil)
	enabled: boolean,
	unlocked: boolean,
	hasPlot: boolean,
	revealed: boolean,
	alive: boolean,
	busy: boolean,
	cooldownUntil: number,
	areaUnlocked: boolean?,
	plotOwned: boolean?,
	ownPlot: boolean?,
	hasTeleporter: boolean,
	areaCount: number,
}

-- Unlock trigger as WorldService sees it ("load" = ProfileLoaded evaluation).
export type UnlockEvent = "load" | "area" | "rebirth" | "admin"
export type UnlockSource = "area" | "rebirth" | "legacy" | "admin"

-- A player's progress in one world (WorldsConfig.WorldProgress).
export type Progress = { area: number, rebirths: number }

local TravelRules = {}

-- Seconds after a finished travel before the next one is accepted (spec §11).
TravelRules.CooldownSeconds = 2
-- Hard server deadline: after this many seconds of preparing (plot build, streaming) the
-- character is pivoted anyway, so nobody is stranded in the warp (spec §4.5).
TravelRules.DeadlineSeconds = 4
-- Seconds given to Player:RequestStreamAroundAsync for the destination.
TravelRules.StreamTimeout = 3
-- Minimum seconds between "out" and the pivot, so the client's warp overlay is opaque before the
-- character jumps (= WorldClientConfig.Overlay.FadeSeconds).
TravelRules.CoverSeconds = 0.35
-- TravelWorld remote limiter: RateLimiter(RateBurst, RateRefill) per player (spec §11).
TravelRules.RateBurst = 3
TravelRules.RateRefill = 0.5
-- "Dino Valley is locked" portal toasts: at most one per player per this many seconds.
TravelRules.LockedToastSeconds = 4
-- Period of WorldService's play-time loop (worlds.<w>.stats.playSeconds / runSeconds).
TravelRules.StatsTickSeconds = 1
-- Cap of every counter WorldService writes (= ProfileLogic.Limits.MaxCounter).
TravelRules.MaxCounter = 1e15

-- Allowlists (frozen; order = display / documentation order).
TravelRules.Targets = table.freeze({ "spawn", "area", "plot" }) :: { TravelTarget }
TravelRules.Sources = table.freeze({ "portal", "menu", "popup", "chip", "admin", "respawn" }) :: { TravelSource }
-- Every refusal reason, in check order (W5 FailText must cover each one).
TravelRules.Reasons = table.freeze({
	"unknownWorld",
	"badTarget",
	"disabled",
	"locked",
	"noPlot",
	"revealPending",
	"dead",
	"busy",
	"cooldown",
	"areaLocked",
	"plotEmpty",
	"noPass",
}) :: { TravelReason }

local TARGET_SET: { [string]: boolean } = { spawn = true, area = true, plot = true }
local SOURCE_SET: { [string]: boolean } = {}
for _, source in TravelRules.Sources do
	SOURCE_SET[source] = true
end

-- A finite number (not NaN, not +-inf).
local function finite(x: any): boolean
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

-- A whole number in [lo, hi] (finite, integral).
local function wholeIn(x: any, lo: number, hi: number): boolean
	return finite(x) and x % 1 == 0 and x >= lo and x <= hi
end

--[[
	True when (target, index) is well-formed for a world with `areaCount` areas.
	@param target any, index any, areaCount number
	@return boolean
	Example: TravelRules.validTarget("area", 6, 6) --> true ; ("spawn", 1, 6) --> false
]]
function TravelRules.validTarget(target: any, index: any, areaCount: number): boolean
	if type(target) ~= "string" or not TARGET_SET[target] then
		return false
	end
	if target == "spawn" then
		return index == nil
	elseif target == "area" then
		return wholeIn(areaCount, 1, math.huge) and wholeIn(index, 1, areaCount)
	end
	return wholeIn(index, 1, WorldLayout.PlotCount)
end

--[[
	True when `source` is an allowlisted travel source (analytics `travel:<w>:<source>`).
	Example: TravelRules.validSource("portal") --> true ; TravelRules.validSource("hack") --> false
]]
function TravelRules.validSource(source: any): boolean
	return type(source) == "string" and SOURCE_SET[source] == true
end

--[[
	The travel gate (see the header for the order). Pure: same context, same answer.
	@param ctx TravelContext — built server-side by WorldService
	@return (true, nil) when the travel may start, else (false, reason)
	Example: TravelRules.check({ ...ctx, busy = true }) --> false, "busy"
]]
function TravelRules.check(ctx: TravelContext): (boolean, TravelReason?)
	if type(ctx) ~= "table" then
		return false, "unknownWorld"
	end
	local def = WorldsConfig.get(ctx.worldId)
	if def == nil then
		return false, "unknownWorld"
	end
	-- The registry's area count is the authority; a smaller context count narrows it (never widens).
	local areaCount = def.geometry.areaCount
	if finite(ctx.areaCount) then
		areaCount = math.min(areaCount, math.floor(ctx.areaCount))
	end
	if not TravelRules.validTarget(ctx.target, ctx.index, areaCount) then
		return false, "badTarget"
	end
	if ctx.enabled ~= true then
		return false, "disabled"
	end
	if ctx.unlocked ~= true then
		return false, "locked"
	end
	if ctx.hasPlot ~= true then
		return false, "noPlot"
	end
	if ctx.revealed ~= true then
		return false, "revealPending"
	end
	if ctx.alive ~= true then
		return false, "dead"
	end
	if ctx.busy ~= false then
		return false, "busy"
	end
	-- Fail closed on a broken clock / cooldown (NaN, +inf, non-numbers); -inf = never travelled.
	local cooldownUntil = ctx.cooldownUntil
	if not finite(ctx.now) or type(cooldownUntil) ~= "number" or cooldownUntil ~= cooldownUntil then
		return false, "cooldown"
	end
	if ctx.now < cooldownUntil then
		return false, "cooldown"
	end
	if ctx.target == "area" then
		if ctx.areaUnlocked ~= true then
			return false, "areaLocked"
		end
	elseif ctx.target == "plot" then
		if ctx.plotOwned ~= true then
			return false, "plotEmpty"
		end
		if ctx.ownPlot ~= true and ctx.hasTeleporter ~= true then
			return false, "noPass"
		end
	end
	return true, nil
end

--------------------------------------------------------------------------------------------------
-- Unlock helpers (spec §4.1)
--------------------------------------------------------------------------------------------------

-- A sanitised whole count >= 0 from untrusted profile data.
local function count(x: any): number
	if not finite(x) or x <= 0 then
		return 0
	end
	return math.floor(x)
end

--[[
	Per-world progress of a profile, the input of WorldsConfig.unlockPasses: Nuke Town from the
	top-level tycoon / rebirths, every registered extra world from profile.worlds[id]. Missing or
	malformed parts count as nothing (area 0, rebirths 0).
	@param profile any — ProfileLogic.Profile
	@return {[worldId]: Progress}
	Example: TravelRules.progress(profile).main --> { area = 3, rebirths = 0 }
]]
function TravelRules.progress(profile: any): { [string]: Progress }
	local result: { [string]: Progress } = {}
	if type(profile) ~= "table" then
		return result
	end
	local tycoon = profile.tycoon
	result[WorldsConfig.MAIN] = {
		area = count(if type(tycoon) == "table" then tycoon.area else nil),
		rebirths = count(profile.rebirths),
	}
	local worlds = profile.worlds
	if type(worlds) ~= "table" then
		return result
	end
	for _, def in WorldsConfig.extra() do
		local state = worlds[def.id]
		if type(state) == "table" then
			local worldTycoon = state.tycoon
			result[def.id] = {
				area = count(if type(worldTycoon) == "table" then worldTycoon.area else nil),
				rebirths = count(state.rebirths),
			}
		end
	end
	return result
end

--[[
	The sticky answer: Nuke Town always; another world once profile.worlds[id].unlocked is true.
	@param def WorldsConfig.WorldDef, profile any
	@return boolean
]]
function TravelRules.isUnlocked(def: WorldsConfig.WorldDef, profile: any): boolean
	if def.id == WorldsConfig.MAIN or def.unlock.kind == "always" then
		return true
	end
	if type(profile) ~= "table" or type(profile.worlds) ~= "table" then
		return false
	end
	local state = profile.worlds[def.id]
	return type(state) == "table" and state.unlocked == true
end

--[[
	True when the world's rule passes now and the sticky flag is still false (WorldService then
	unlocks it). Never true for Nuke Town.
	@param def WorldsConfig.WorldDef, profile any
	@return boolean
	Example: TravelRules.shouldUnlock(dino, profileAtArea3) --> true
]]
function TravelRules.shouldUnlock(def: WorldsConfig.WorldDef, profile: any): boolean
	if TravelRules.isUnlocked(def, profile) then
		return false
	end
	return WorldsConfig.unlockPasses(def, TravelRules.progress(profile))
end

--[[
	The analytics source of an unlock (`unlockSrc:<w>:<source>`): "admin" for admin unlocks,
	"legacy" when the first load of the update already qualifies, otherwise "area" when the area
	part of the rule passes, else "rebirth" (the orRebirths part did it).
	@param def WorldsConfig.WorldDef, progress {[string]: Progress}, event UnlockEvent
	@return UnlockSource
	Example: TravelRules.unlockSource(dino, { main = { area = 1, rebirths = 1 } }, "rebirth") --> "rebirth"
]]
function TravelRules.unlockSource(
	def: WorldsConfig.WorldDef,
	progress: { [string]: Progress },
	event: UnlockEvent
): UnlockSource
	if event == "admin" then
		return "admin"
	elseif event == "load" then
		return "legacy"
	end
	local rule = def.unlock
	if rule.kind == "progress" then
		local entry: any = if type(progress) == "table" then progress[rule.world] else nil
		if type(entry) == "table" and count(entry.area) >= rule.area then
			return "area"
		end
		return "rebirth"
	end
	return "area"
end

--------------------------------------------------------------------------------------------------
-- Visit + play-time counters (worlds.<w>.stats)
--------------------------------------------------------------------------------------------------

--[[
	UTC day number of a unix time (whole days since 1970-01-01).
	Example: TravelRules.dayOf(86400 * 3 + 5) --> 3
]]
function TravelRules.dayOf(unix: number): number
	if not finite(unix) or unix < 0 then
		return 0
	end
	return math.floor(unix / 86400)
end

--[[
	Records one arrival in a world: visits + 1 (clamped) and lastVisitDay = day.
	@param stats any — worlds.<w>.stats (ProfileLogic.WorldStats); ignored when not a table
	@param day number — TravelRules.dayOf(os.time())
	@return (firstToday: boolean, firstEver: boolean) — analytics `visitor:<w>` / `firstVisit:<w>`
	Example: TravelRules.recordVisit({ visits = 0, lastVisitDay = -1 }, 20390) --> true, true
]]
function TravelRules.recordVisit(stats: any, day: number): (boolean, boolean)
	if type(stats) ~= "table" or not finite(day) then
		return false, false
	end
	local visits = count(stats.visits)
	local firstEver = visits == 0
	local firstToday = stats.lastVisitDay ~= day
	stats.visits = math.min(visits + 1, TravelRules.MaxCounter)
	stats.lastVisitDay = day
	return firstToday, firstEver
end

--[[
	Adds play time to a world's counters (playSeconds = lifetime, runSeconds = this rebirth run).
	Non-positive / non-finite amounts are ignored; both counters clamp at MaxCounter.
	@param stats any — worlds.<w>.stats
	@param seconds number
	@return boolean — true when anything was added
]]
function TravelRules.addSeconds(stats: any, seconds: number): boolean
	if type(stats) ~= "table" or not finite(seconds) or seconds <= 0 then
		return false
	end
	stats.playSeconds = math.min(count(stats.playSeconds) + seconds, TravelRules.MaxCounter)
	stats.runSeconds = math.min(count(stats.runSeconds) + seconds, TravelRules.MaxCounter)
	return true
end

return table.freeze(TravelRules)
