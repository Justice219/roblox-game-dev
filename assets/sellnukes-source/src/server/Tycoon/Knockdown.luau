--!strict
--[[
	Knockdown — temporary area knockdown (owner R50: "attack mode should actually do something,
	like give you money and temporarily knockdown peoples areas depending on where it hits").

	A nuke that lands in one of a player's areas knocks that AREA down: its producer pauses (income,
	clicks and manager auto-work stop — TycoonService asks `activeAreas` every payout tick), every
	client topples its stud buildings like toy bricks (Client/Tycoon/BuildIn/KnockdownFx), and when
	the deadline passes the master-builder fly-in rebuilds it. The owner can "TAP TO REBUILD!" (HUD
	chip → `KnockdownTap`) to bring the deadline 1 s closer per tap. NOTHING is ever removed or
	refunded (hard rule 7): no cash, pads, producers, levels, pets or gems change, purchases inside a
	knocked area still work (they build in after the rebuild), and the state is NEVER saved — it
	clears on leave, plot release, rebirth and admin resets. Offline earnings ignore knockdowns
	(they are computed from the saved profile only).

	Rules (pure, Shared/Tycoon/KnockdownLogic; tunables Shared/Config/KnockdownConfig):
		duration   KnockdownConfig.duration(launcherLevel) (45 s +3 s per level above 1, ≤ 90 s),
		           clamped server-side whatever the caller passes; an admin override wins
		immunity   while any area is down and 180 s after the plot's LAST area comes up
		volley     barrage spill: the same attacker may knock ONE more area within 6 s of the first
		shields    an active attack shield blocks every knockdown ("shielded")
		taps       −1 s each, never earlier than 6 s after the start, ≤ 6 / s per player

	Replication (CollectionService tag `KnockdownTarget`; attributes, server time):
		Workspace.Plots.Plot<N>.AreaNN   KnockedAt, KnockedUntil, KnockCenter (cleared when it rebuilds)
		producer Anchor                  PausedAt (TycoonService, while paused)
		Rival Factory sections (Q2)      the same, through knockInstance()
		KnockdownState (S→C, owner only) { areas = { { area, untilTime, appliedAt, label } }, immuneUntil }

	Contract (Q2-attack, docs/attack.md "Knockdown"). Every subject is `Subject = Player | BotSubject`
	(owner R51 test bots: { key, plotIndex, tycoon, shieldUntil }):
		Knockdown.apply(subject, areaIndex, { durationSeconds, attackerUserId?, source, center? })
			-> (ok, reason?)  reason: "immune" | "shielded" | "not_built" | "disabled"
		Knockdown.isDown(player, area) -> (boolean, untilTime?)
		Knockdown.isImmune(player) -> boolean
		Knockdown.areaIncome(player, area) -> number      automated $/s of that area's producer
		Knockdown.builtAreas(player) -> { number }        unlocked areas owning ≥ 1 build
		Knockdown.knockInstance(section, seconds, center?) -> boolean   Rival Factory sections
		Knockdown.isInstanceDown(section) -> (boolean, untilTime?)
		Test bots (owner R51): applyBot(bot, area, opts), isBotDown, isBotImmune, botBuiltAreas,
		forceRebuildBot, forgetBot — bot = { key, plotIndex, tycoon, shieldUntil }; same rules +
		replication, no toast / remote / analytics.
	Tycoon seam: TycoonService.Init → Knockdown.bindTycoon({ areaIncome, isReady });
		TycoonService.tickPlayer → Knockdown.activeAreas(player); resetRun → Knockdown.reset(player).
	Admin seam (Server/Admin/Handlers/KnockdownHandlers via Seams.knockdown, "Attack" tab):
		setEnabled, setDurationOverride, setImmunitySeconds,
		adminKnock, forceRebuild, clearImmunity, settings, stats.

	Security: KnockdownTap is owner-only by construction (the caller's own state), typeof-checked
	(integer area 1..10), rate limited (token bucket 6 / 6 per s), departed-player guarded
	(Remotes.onServerEvent); every server API validates its arguments (Player present, integer
	area, finite duration clamped, Vector3 centre bounded). Clients never send amounts or times.

	Performance: one Heartbeat (KnockdownConfig.TickSeconds) that returns at once when nothing is
	down; attribute writes only on change; one small reliable event per change to the owner; tap
	analytics are summed and recorded once when the area comes back up.

	Boot: feature service "Tycoon/Knockdown", right after "Tycoon/TycoonService".
	Example (AttackService, at impact):
		local ok, reason = Knockdown.apply(target, area, {
			durationSeconds = KnockdownConfig.duration(launcherLevel),
			attackerUserId = attacker.UserId, source = "normal", center = impactPoint,
		})
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local AttackLogic = require(ReplicatedStorage.Shared.Attack.AttackLogic)
local AttackProfile = require(script.Parent.Parent.Attack.AttackProfile)
local KnockdownConfig = require(ReplicatedStorage.Shared.Config.KnockdownConfig)
local KnockdownLogic = require(ReplicatedStorage.Shared.Tycoon.KnockdownLogic)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)
local PlotService = require(script.Parent.PlotService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TycoonConfig = require(ReplicatedStorage.Shared.Config.TycoonConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonTypes = require(ReplicatedStorage.Shared.Tycoon.TycoonTypes)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)

type PlotState = KnockdownLogic.PlotState
type AreaState = KnockdownLogic.AreaState

export type Reason = "immune" | "shielded" | "not_built" | "disabled"
export type ApplyOptions = {
	durationSeconds: number,
	attackerUserId: number?,
	source: string,
	center: Vector3?,
}
export type TycoonHooks = {
	areaIncome: (player: Player, area: number) -> number,
	isReady: (player: Player) -> boolean,
}
export type Settings = { enabled: boolean, durationOverride: number, immunitySeconds: number }
-- An admin test bot plot (owner R51, Q2-attack): not a Player, never saved, no production.
export type BotSubject = {
	key: string, -- unique per bot ("bot:3")
	plotIndex: number, -- the plot slot it occupies
	tycoon: any, -- its TycoonState (which pads it "owns")
	shieldUntil: number, -- server time its test shield ends (0 / past = none)
}
-- Who can be knocked down: a real player, or an admin test bot (R51). Every public query below
-- accepts either; bots get the same rules + replication but no toasts / remote / analytics.
export type Subject = Player | BotSubject

-- One player's knockdown runtime (never saved).
type Runtime = {
	state: PlotState,
	plotIndex: number,
	centers: { [number]: Vector3 },
}

local Knockdown = {}

-- Fired (deferred) with the player whenever their knockdown state changed (apply / tap / end).
Knockdown.Changed = Signal.new() :: Signal.Signal<Player>

local ATTR = KnockdownConfig.Attr
local AREA_COUNT = #TycoonConfig.Areas
-- Impact centres farther than this from the world origin are refused (fall back to the slot centre).
local MAX_CENTER = WorldLayout.WorldRadius * 2
-- Bound of a caller-supplied attacker user id (2^53, the largest exact whole double).
local MAX_USER_ID = 9_007_199_254_740_992

local runtimes: { [Player]: Runtime } = {}
-- Test bots (owner R51) by BotSubject.key: same rules, same replication, no toasts / remote / analytics.
local bots: { [string]: Runtime } = {}
-- Rival Factory sections (and any other non-plot target) currently down → rebuild time.
local instanceTargets: { [Instance]: number } = {}
local settings: Settings = {
	enabled = KnockdownConfig.Enabled,
	durationOverride = 0, -- 0 = none (use the caller's duration)
	immunitySeconds = KnockdownConfig.ImmunitySeconds,
}
local hooks: TycoonHooks? = nil
local tapLimiter = RateLimiter.new(KnockdownConfig.TapBurst, KnockdownConfig.TapPerSecond)
local started = false
-- Reused by the loop (no per-tick allocation).
local ended: { AreaState } = {}
local doneInstances: { Instance } = {}
-- Counters for the admin Server tab.
local counters = { applied = 0, blocked = 0, taps = 0, rival = 0 }

local SOURCE_SET: { [string]: boolean } = {}
for _, source in KnockdownConfig.Sources do
	SOURCE_SET[source] = true
end

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- The live anti-grief rules (config + the admin immunity override).
local function rules(): KnockdownLogic.Rules
	return KnockdownLogic.rulesFromConfig(KnockdownConfig, settings.immunitySeconds)
end

-- The AnalyticsService module (guarded lazy require: analytics never breaks gameplay).
local analyticsService: any = nil
local analyticsResolved = false
local function analytics(): any
	if analyticsResolved then
		return analyticsService
	end
	analyticsResolved = true
	local ok, result = pcall(function(): any
		local module = ServerScriptService.Server.Services:FindFirstChild("AnalyticsService")
		return if module ~= nil and module:IsA("ModuleScript") then require(module) :: any else nil
	end)
	if ok and type(result) == "table" and type(result.attack) == "function" then
		analyticsService = result
	elseif not ok then
		warn(`[Knockdown] AnalyticsService unavailable: {result}`)
	end
	return analyticsService
end

--[[
	Records one attack-family analytics key (AnalyticsConfig.Metrics.attack knock*). Never throws.
	@param player Player? — the knocked player (nil = server-wide, e.g. Rival Factories)
]]
local function record(player: Player?, key: string, amount: number?)
	local api = analytics()
	if api ~= nil then
		pcall(api.attack, player, key, amount)
	end
end

-- Reports the loop's Luau time to the health system (Attack bucket).
local function reportTime(seconds: number)
	local api = analytics()
	if api ~= nil and type(api.systemTime) == "function" then
		pcall(api.systemTime, "Attack", seconds)
	end
end

-- The analytics source key of a caller-supplied source string.
local function sourceKey(source: unknown): string
	return if type(source) == "string" and SOURCE_SET[source] then source else "other"
end

-- True when `player` is a Player still in the game.
local function present(player: unknown): boolean
	return typeof(player) == "Instance"
		and (player :: Instance):IsA("Player")
		and (player :: Instance).Parent == Players
end

-- An integer area index 1..AREA_COUNT, else nil.
local function areaOf(raw: unknown): number?
	return Validate.integer(raw, 1, AREA_COUNT)
end

-- The AreaNN model of a plot (nil when the area was never built / is cleared).
local function areaModel(plotIndex: number, area: number): Instance?
	local ok, plot = pcall(PlotBuilder.getPlot, plotIndex)
	if not ok or plot == nil then
		return nil
	end
	return plot:FindFirstChild(string.format("Area%02d", area))
end

-- Sets an attribute only when it changes (no redundant replication).
local function setAttr(instance: Instance, name: string, value: any)
	if instance:GetAttribute(name) ~= value then
		instance:SetAttribute(name, value)
	end
end

-- Default impact centre: the middle of the area slot at ground level.
local function slotCenter(plotIndex: number, area: number): Vector3
	return WorldLayout.slotPointToWorld(plotIndex, area, Vector3.new(0, 0, WorldLayout.SlotDepth / 2))
end

-- A caller centre if it is a finite, bounded Vector3; else nil.
local function validCenter(raw: unknown): Vector3?
	return Validate.vector3(raw, MAX_CENTER)
end

-- True when the player owns at least one build placed in `area` (its own pads, not the Unlock pad
-- of the previous area, whose build is the next area's Base) and the area is open.
local function areaBuilt(tycoon: any, area: number): boolean
	if not TycoonLogic.areaUnlocked(tycoon, area) then
		return false
	end
	local pads: { [string]: any }? = if type(tycoon) == "table" and type(tycoon.pads) == "table"
		then tycoon.pads :: { [string]: any }
		else nil
	local list: { TycoonTypes.PadConfig }? = TycoonConfig.AreaPads[area]
	if pads == nil or list == nil then
		return false
	end
	for _, pad in list :: { TycoonTypes.PadConfig } do
		if pad.unlocks == nil and (pads :: { [string]: any })[pad.id] == true then
			return true
		end
	end
	return false
end

-- The player's runtime (created on first knockdown; re-created when their plot changed).
local function runtimeOf(player: Player, plotIndex: number): Runtime
	local rt = runtimes[player]
	if rt == nil or rt.plotIndex ~= plotIndex then
		rt = { state = KnockdownLogic.newState(), plotIndex = plotIndex, centers = {} }
		runtimes[player] = rt
	end
	return rt :: Runtime
end

-- Sends the owner their knockdown state (areas down + immunity) for the HUD chip.
local function sendState(player: Player)
	if player.Parent ~= Players then
		return
	end
	local rt = runtimes[player]
	type Row = { area: number, untilTime: number, appliedAt: number, label: string }
	local areas: { Row } = {}
	local immuneUntil = 0
	if rt ~= nil then
		local t = now()
		for area, entry in rt.state.areas do
			if entry.untilTime > t then
				table.insert(areas, {
					area = area,
					untilTime = entry.untilTime,
					appliedAt = entry.appliedAt,
					label = KnockdownConfig.areaLabel(area),
				})
			end
		end
		table.sort(areas, function(a: Row, b: Row): boolean
			return a.untilTime < b.untilTime
		end)
		immuneUntil = rt.state.immuneUntil
	end
	Remotes.fireClient("KnockdownState", player, { areas = areas, immuneUntil = immuneUntil })
end

-- Fires Changed after the current call stack (listeners may yield; our callers must not).
local function changed(player: Player)
	task.defer(function()
		Knockdown.Changed:Fire(player)
	end)
end

-- Publishes an area's knockdown on its AreaNN model (tag first, so tag listeners see the attrs).
local function publishArea(rt: Runtime, area: number, entry: AreaState, center: Vector3)
	local model = areaModel(rt.plotIndex, area)
	if model == nil then
		return
	end
	model:SetAttribute(ATTR.At, entry.appliedAt)
	model:SetAttribute(ATTR.Center, center)
	model:SetAttribute(ATTR.Until, entry.untilTime)
	if not CollectionService:HasTag(model, KnockdownConfig.Tag) then
		CollectionService:AddTag(model, KnockdownConfig.Tag)
	end
end

-- Clears an area's knockdown attributes (the tag stays; clients read KnockedUntil = nil as "up").
local function clearArea(plotIndex: number, area: number)
	local model = areaModel(plotIndex, area)
	if model == nil then
		return
	end
	model:SetAttribute(ATTR.Until, nil)
	model:SetAttribute(ATTR.At, nil)
	model:SetAttribute(ATTR.Center, nil)
end

-- Analytics + toast for an area that came back up. `reason`: "timer" | "admin" | "reset".
local function onAreaUp(player: Player, rt: Runtime, entry: AreaState, reason: string, t: number)
	clearArea(rt.plotIndex, entry.area)
	rt.centers[entry.area] = nil
	record(player, "knockSec", math.max(math.floor(t - entry.appliedAt + 0.5), 0))
	record(player, `knockEnd:{reason}`)
	if entry.taps > 0 then
		record(player, "knockTap", entry.taps)
	end
	if reason ~= "reset" then
		PlayerDataService.notify(player, `Your {KnockdownConfig.areaLabel(entry.area)} is rebuilt!`, "success")
	end
end

-- Records + returns a refusal.
local function blocked(player: Player?, reason: Reason): (boolean, string?)
	counters.blocked += 1
	record(player, `knockBlocked:{reason}`)
	return false, reason
end

--------------------------------------------------------------------------------------------------
-- Public API (Q2-attack contract)
--------------------------------------------------------------------------------------------------

--[[
	Knocks down one of `target`'s areas (attack impact, barrage spill, Revenge, admin test).
	Never yields. Admin source ("admin") bypasses the master switch, shields and immunity (tests).
	@param target Player — the plot owner (must be in the game with a loaded profile + plot)
	@param areaIndex number — 1..10, an open area that owns at least one build
	@param opts ApplyOptions — durationSeconds (clamped; admin override wins), attackerUserId?
	       (0 / nil = none), source ("normal" | "revenge" | "barrage" | "admin" | "test"),
	       center? (world impact point; default = the slot centre)
	@return boolean, string? — ok, or false + "immune" | "shielded" | "not_built" | "disabled"
	Example: Knockdown.apply(target, 3, { durationSeconds = 45, attackerUserId = 1, source = "normal" })
]]
function Knockdown.apply(subject: Subject, areaIndex: number, opts: ApplyOptions): (boolean, string?)
	if typeof(subject) ~= "Instance" then
		return Knockdown.applyBot(subject :: any, areaIndex, opts) -- R51 test bot
	end
	local target = subject :: Player
	if not present(target) then
		return blocked(nil, "not_built")
	end
	local options: any = if type(opts) == "table" then opts else {}
	local source = sourceKey(options.source)
	local admin = source == "admin"
	if not settings.enabled and not admin then
		return blocked(target, "disabled")
	end
	local area = areaOf(areaIndex)
	local profile = PlayerDataService.getProfile(target)
	local plotIndex = PlotService.getPlotIndex(target)
	if
		area == nil
		or profile == nil
		or plotIndex == nil
		or (hooks ~= nil and not (hooks :: TycoonHooks).isReady(target))
		or not areaBuilt(profile.tycoon, area)
	then
		return blocked(target, "not_built")
	end
	local areaIdx = area :: number
	local t = now()
	local rt = runtimeOf(target, plotIndex)
	-- Any whole user id (Studio test players are negative); 0 / nil = no attacker.
	local attacker = Validate.integer(options.attackerUserId, -MAX_USER_ID, MAX_USER_ID) or 0
	if not admin then
		if AttackLogic.shieldActive(AttackProfile.get(profile, "shieldUntil"), t) then
			return blocked(target, "shielded")
		end
		local allowed = KnockdownLogic.check(rt.state, areaIdx, t, attacker, rules())
		if not allowed then
			return blocked(target, "immune")
		end
	end
	local duration = if settings.durationOverride > 0
		then settings.durationOverride
		else KnockdownLogic.clampDuration(
			options.durationSeconds,
			KnockdownConfig.MinSeconds,
			if admin then KnockdownConfig.AdminMaxSeconds else KnockdownConfig.MaxSeconds
		)
	local entry = KnockdownLogic.apply(rt.state, areaIdx, t, duration, attacker, source)
	local center = validCenter(options.center) or slotCenter(plotIndex, areaIdx)
	rt.centers[areaIdx] = center
	publishArea(rt, areaIdx, entry, center)
	counters.applied += 1
	record(target, `knock:{areaIdx}`)
	record(target, `knockSrc:{source}`)
	PlayerDataService.notify(
		target,
		`Your {KnockdownConfig.areaLabel(areaIdx)} got knocked down! Rebuilding {KnockdownLogic.formatClock(duration)} - TAP TO REBUILD!`,
		"info"
	)
	sendState(target)
	changed(target)
	return true, nil
end

--[[
	Is one of the player's areas down right now?
	@return boolean, number? — down, and the server time it rebuilds
]]
function Knockdown.isDown(subject: Subject, areaIndex: number): (boolean, number?)
	if typeof(subject) ~= "Instance" then
		return Knockdown.isBotDown(subject :: any, areaIndex)
	end
	local rt = runtimes[subject :: Player]
	local area = areaOf(areaIndex)
	if rt == nil or area == nil then
		return false, nil
	end
	return KnockdownLogic.isDown(rt.state, area, now())
end

--[[ True while the player's plot is knockdown-immune (an area down, or the 180 s after). ]]
function Knockdown.isImmune(subject: Subject): boolean
	if typeof(subject) ~= "Instance" then
		return Knockdown.isBotImmune(subject :: any)
	end
	local rt = runtimes[subject :: Player]
	return rt ~= nil and KnockdownLogic.isImmune(rt.state, now())
end

--[[
	Idle $/s of one area's producer with every modifier (0 when manual / unbuilt / not loaded) —
	the same basis as the player's IncomePerSecond. Q2 scales the knockdown reward with it.
]]
function Knockdown.areaIncome(subject: Subject, areaIndex: number): number
	if typeof(subject) ~= "Instance" then
		return Knockdown.botAreaIncome(subject :: any, areaIndex)
	end
	local player = subject :: Player
	local area = areaOf(areaIndex)
	local bound = hooks
	if area == nil or bound == nil or not present(player) then
		return 0
	end
	local ok, value = pcall(bound.areaIncome, player, area)
	return if ok and type(value) == "number" and value == value and value >= 0 and value < math.huge then value else 0
end

--[[ Areas (ascending) that are open AND own at least one build — the attack picker's markers. ]]
function Knockdown.builtAreas(subject: Subject): { number }
	if typeof(subject) ~= "Instance" then
		return Knockdown.botBuiltAreas(subject :: any)
	end
	local player = subject :: Player
	local result: { number } = {}
	local profile = if present(player) then PlayerDataService.getProfile(player) else nil
	if profile == nil or PlotService.getPlotIndex(player) == nil then
		return result
	end
	for area = 1, AREA_COUNT do
		if areaBuilt(profile.tycoon, area) then
			table.insert(result, area)
		end
	end
	return result
end

--[[
	TycoonService fast path: the player's down-area table (area → AreaState, read-only) or nil when
	nothing is down. Entries whose deadline passed may linger ≤ TickSeconds: compare untilTime.
]]
function Knockdown.activeAreas(player: Player): { [number]: AreaState }?
	local rt = runtimes[player]
	if rt == nil or rt.state.downCount == 0 then
		return nil
	end
	return rt.state.areas
end

--[[
	Knocks down a non-plot target (Q2's Rival Factory sections): tags it, sets KnockedAt /
	KnockedUntil / KnockCenter, and clears it at the deadline. Clients topple it like an area
	(everything visible inside, or only its `Builds` child; `Keep` / KnockdownKeep parts stay).
	@param section Instance — a Model / Folder in Workspace
	@param durationSeconds number — clamped to [MinSeconds, MaxSeconds]
	@param center Vector3? — impact point (default: the section's pivot / first part)
	@return boolean — false when disabled, invalid or already down
]]
function Knockdown.knockInstance(section: Instance, durationSeconds: number, center: Vector3?): boolean
	if not settings.enabled or typeof(section) ~= "Instance" or not section:IsDescendantOf(Workspace) then
		return false
	end
	local t = now()
	local current = instanceTargets[section]
	if current ~= nil and current > t then
		return false
	end
	local duration = if settings.durationOverride > 0
		then settings.durationOverride
		else KnockdownLogic.clampDuration(durationSeconds, KnockdownConfig.MinSeconds, KnockdownConfig.MaxSeconds)
	local point = validCenter(center)
	if point == nil then
		if section:IsA("Model") then
			point = section:GetPivot().Position
		else
			local part = section:FindFirstChildWhichIsA("BasePart", true)
			point = if part ~= nil then part.Position else Vector3.zero
		end
	end
	local untilTime = t + duration
	instanceTargets[section] = untilTime
	section:SetAttribute(ATTR.At, t)
	section:SetAttribute(ATTR.Center, point)
	section:SetAttribute(ATTR.Until, untilTime)
	if not CollectionService:HasTag(section, KnockdownConfig.Tag) then
		CollectionService:AddTag(section, KnockdownConfig.Tag)
	end
	counters.rival += 1
	record(nil, "knockSrc:rival")
	return true
end

--------------------------------------------------------------------------------------------------
-- Test bots (owner R51: "Knockdown API accepts bot subjects"; Q2's admin test bots)
--------------------------------------------------------------------------------------------------

-- A validated bot subject (plain table, string key ≤ 64, plot 1..PlotCount), else nil.
local function botOf(raw: unknown): BotSubject?
	if type(raw) ~= "table" then
		return nil
	end
	local bot = raw :: any
	local key = Validate.string(bot.key, 1, 64)
	local plotIndex = Validate.integer(bot.plotIndex, 1, WorldLayout.PlotCount)
	if key == nil or plotIndex == nil or type(bot.tycoon) ~= "table" then
		return nil
	end
	return bot :: BotSubject
end

--[[
	Knocks down one area of a test bot's plot: the same anti-grief rules, duration clamp and
	replication as a player (so the client FX topples it), but no toast, no KnockdownState and no
	analytics (test traffic, R51). Source "admin" bypasses the switch / shield / immunity.
	@return boolean, string? — ok, or false + "immune" | "shielded" | "not_built" | "disabled"
	Example: Knockdown.applyBot({ key = "bot:3", plotIndex = 3, tycoon = state }, 2, { durationSeconds = 45, source = "test" })
]]
function Knockdown.applyBot(raw: BotSubject, areaIndex: number, opts: ApplyOptions): (boolean, string?)
	local bot = botOf(raw)
	if bot == nil then
		return false, "not_built"
	end
	local options: any = if type(opts) == "table" then opts else {}
	local admin = sourceKey(options.source) == "admin"
	if not settings.enabled and not admin then
		return false, "disabled"
	end
	local area = areaOf(areaIndex)
	if area == nil or not areaBuilt(bot.tycoon, area) or areaModel(bot.plotIndex, area) == nil then
		return false, "not_built"
	end
	local t = now()
	local rt = bots[bot.key]
	if rt == nil or rt.plotIndex ~= bot.plotIndex then
		rt = { state = KnockdownLogic.newState(), plotIndex = bot.plotIndex, centers = {} }
		bots[bot.key] = rt
	end
	local runtime = rt :: Runtime
	local attacker = Validate.integer(options.attackerUserId, -MAX_USER_ID, MAX_USER_ID) or 0
	if not admin then
		local shieldUntil = Validate.number(bot.shieldUntil, 0, math.huge) or 0
		if AttackLogic.shieldActive(shieldUntil, t) then
			return false, "shielded"
		end
		if not KnockdownLogic.check(runtime.state, area, t, attacker, rules()) then
			return false, "immune"
		end
	end
	local duration = if settings.durationOverride > 0
		then settings.durationOverride
		else KnockdownLogic.clampDuration(
			options.durationSeconds,
			KnockdownConfig.MinSeconds,
			if admin then KnockdownConfig.AdminMaxSeconds else KnockdownConfig.MaxSeconds
		)
	local entry = KnockdownLogic.apply(runtime.state, area, t, duration, attacker, sourceKey(options.source))
	local center = validCenter(options.center) or slotCenter(bot.plotIndex, area)
	runtime.centers[area] = center
	publishArea(runtime, area, entry, center)
	return true, nil
end

--[[ Is one of a bot's areas down? @return boolean, number? (rebuild time) ]]
function Knockdown.isBotDown(raw: BotSubject, areaIndex: number): (boolean, number?)
	local bot = botOf(raw)
	local area = areaOf(areaIndex)
	local rt = if bot ~= nil then bots[bot.key] else nil
	if rt == nil or area == nil then
		return false, nil
	end
	return KnockdownLogic.isDown(rt.state, area, now())
end

--[[ True while a bot's plot is knockdown-immune. ]]
function Knockdown.isBotImmune(raw: BotSubject): boolean
	local bot = botOf(raw)
	local rt = if bot ~= nil then bots[bot.key] else nil
	return rt ~= nil and KnockdownLogic.isImmune(rt.state, now())
end

--[[
	A bot's area income: the area producer's automated $/s from its tycoon state, without modifiers
	(bots have no passes / pets / boosts). 0 when manual / unbuilt.
]]
function Knockdown.botAreaIncome(raw: BotSubject, areaIndex: number): number
	local bot = botOf(raw)
	local area = areaOf(areaIndex)
	local areaCfg = if area ~= nil then TycoonConfig.Areas[area] else nil
	if bot == nil or areaCfg == nil then
		return 0
	end
	local ok, stats = pcall(TycoonLogic.producerStats, bot.tycoon, areaCfg.producer.id, nil)
	if not ok or stats == nil or not stats.built or not stats.automated then
		return 0
	end
	local value = stats.perSecond
	return if type(value) == "number" and value == value and value >= 0 and value < math.huge then value else 0
end

--[[ A bot's open areas that own at least one build (the picker's markers for a BOT target). ]]
function Knockdown.botBuiltAreas(raw: BotSubject): { number }
	local result: { number } = {}
	local bot = botOf(raw)
	if bot == nil then
		return result
	end
	for area = 1, AREA_COUNT do
		if areaBuilt(bot.tycoon, area) then
			table.insert(result, area)
		end
	end
	return result
end

--[[
	Forgets a bot (removed / its plot cleared): clears its areas' attributes so the client rebuilds
	anything still down, and drops its state. Safe to call twice.
]]
function Knockdown.forgetBot(raw: BotSubject)
	local bot = botOf(raw)
	local rt = if bot ~= nil then bots[bot.key] else nil
	if bot == nil or rt == nil then
		return
	end
	for area in rt.state.areas do
		clearArea(rt.plotIndex, area)
	end
	bots[bot.key] = nil
end

--[[ Admin: rebuilds every knocked area of a bot now. @return number — areas rebuilt ]]
function Knockdown.forceRebuildBot(raw: BotSubject): number
	local bot = botOf(raw)
	local rt = if bot ~= nil then bots[bot.key] else nil
	if rt == nil then
		return 0
	end
	local t = now()
	local areas: { number } = {}
	for area in rt.state.areas do
		table.insert(areas, area)
	end
	local rulesNow = rules()
	for _, area in areas do
		if KnockdownLogic.finish(rt.state, area, t, rulesNow) ~= nil then
			clearArea(rt.plotIndex, area)
		end
	end
	return #areas
end

--[[ Is a non-plot target down? @return boolean, number? (rebuild time) ]]
function Knockdown.isInstanceDown(section: Instance): (boolean, number?)
	local untilTime = instanceTargets[section]
	if untilTime ~= nil and untilTime > now() then
		return true, untilTime
	end
	return false, nil
end

--------------------------------------------------------------------------------------------------
-- Tycoon + admin seams
--------------------------------------------------------------------------------------------------

--[[ TycoonService.Init binds its income + readiness queries (it requires this module, not v.v.). ]]
function Knockdown.bindTycoon(bound: TycoonHooks)
	hooks = bound
end

--[[
	Ends every knockdown of a player without the "rebuilt" toast (rebirth, admin plot reset, plot
	release) and forgets their state, immunity included. TycoonService.resetRun calls it before
	PlotBuilder.clear. Never yields.
]]
function Knockdown.reset(player: Player)
	local rt = runtimes[player]
	if rt == nil then
		return
	end
	local t = now()
	for _, entry in rt.state.areas do
		onAreaUp(player, rt, entry, "reset", t)
	end
	runtimes[player] = nil
	sendState(player)
	changed(player)
end

--[[ Admin: the master switch (off = every apply / knockInstance refuses "disabled"). ]]
function Knockdown.setEnabled(on: boolean)
	settings.enabled = on == true
end

--[[ Admin: every new knockdown lasts `seconds` (0 = back to the caller's duration). ]]
function Knockdown.setDurationOverride(seconds: number)
	local value = if type(seconds) == "number" and seconds == seconds then seconds else 0
	settings.durationOverride = if value <= 0
		then 0
		else math.clamp(value, KnockdownConfig.MinSeconds, KnockdownConfig.AdminMaxSeconds)
end

--[[ Admin: post-knockdown immunity seconds (applies to areas that come up from now on). ]]
function Knockdown.setImmunitySeconds(seconds: number)
	local value = if type(seconds) == "number" and seconds == seconds then seconds else KnockdownConfig.ImmunitySeconds
	settings.immunitySeconds = math.clamp(value, 0, KnockdownConfig.AdminMaxImmunitySeconds)
end

--[[ Admin: a copy of the live settings. ]]
function Knockdown.settings(): Settings
	return table.clone(settings)
end

--[[
	Admin test: knocks down one area of a player (bypasses switch, shield and immunity).
	@return boolean, string? — ok / reason ("not_built")
]]
function Knockdown.adminKnock(subject: Subject, areaIndex: number, seconds: number?): (boolean, string?)
	return Knockdown.apply(subject, areaIndex, {
		durationSeconds = if type(seconds) == "number" and seconds > 0 then seconds else KnockdownConfig.duration(1),
		attackerUserId = 0,
		source = "admin",
	})
end

--[[
	Admin: rebuilds every knocked area of a player now (immunity follows the normal rule).
	@return number — areas rebuilt
]]
function Knockdown.forceRebuild(subject: Subject): number
	if typeof(subject) ~= "Instance" then
		return Knockdown.forceRebuildBot(subject :: any)
	end
	local player = subject :: Player
	local rt = runtimes[player]
	if rt == nil then
		return 0
	end
	local t = now()
	local count = 0
	local areas: { number } = {}
	for area in rt.state.areas do
		table.insert(areas, area)
	end
	local rulesNow = rules()
	for _, area in areas do
		local entry = KnockdownLogic.finish(rt.state, area, t, rulesNow)
		if entry ~= nil then
			onAreaUp(player, rt, entry, "admin", t)
			count += 1
		end
	end
	if count > 0 then
		sendState(player)
		changed(player)
	end
	return count
end

--[[ Admin: removes a player's knockdown immunity. @return boolean — had a runtime ]]
function Knockdown.clearImmunity(subject: Subject): boolean
	if typeof(subject) ~= "Instance" then
		local bot = botOf(subject)
		local botRuntime = if bot ~= nil then bots[bot.key] else nil
		if botRuntime == nil then
			return false
		end
		KnockdownLogic.clearImmunity(botRuntime.state)
		return true
	end
	local player = subject :: Player
	local rt = runtimes[player]
	if rt == nil then
		return false
	end
	KnockdownLogic.clearImmunity(rt.state)
	sendState(player)
	return true
end

--[[ Admin Server tab: live counts on this server. ]]
function Knockdown.stats(): {
	down: number,
	immune: number,
	rivalsDown: number,
	applied: number,
	blocked: number,
	taps: number,
}
	local t = now()
	local down, immune, rivalsDown = 0, 0, 0
	for _, rt in runtimes do
		for _, entry in rt.state.areas do
			if entry.untilTime > t then
				down += 1
			end
		end
		if KnockdownLogic.isImmune(rt.state, t) then
			immune += 1
		end
	end
	for _, untilTime in instanceTargets do
		if untilTime > t then
			rivalsDown += 1
		end
	end
	for _, rt in bots do
		for _, entry in rt.state.areas do
			if entry.untilTime > t then
				down += 1
			end
		end
	end
	return {
		down = down,
		immune = immune,
		rivalsDown = rivalsDown,
		applied = counters.applied,
		blocked = counters.blocked,
		taps = counters.taps,
	}
end

--------------------------------------------------------------------------------------------------
-- Remote + loop
--------------------------------------------------------------------------------------------------

-- KnockdownTap(areaIndex): "TAP TO REBUILD!" on one of the caller's own knocked areas.
local function onTap(player: Player, rawArea: unknown)
	if not tapLimiter:Allow(player) then
		return
	end
	local area = areaOf(rawArea)
	local rt = runtimes[player]
	if area == nil or rt == nil or PlotService.getPlotIndex(player) ~= rt.plotIndex then
		return
	end
	local accepted, untilTime = KnockdownLogic.tap(rt.state, area, now(), rules())
	if not accepted then
		return
	end
	counters.taps += 1
	local model = areaModel(rt.plotIndex, area)
	if model ~= nil then
		setAttr(model, ATTR.Until, untilTime)
	end
	sendState(player)
end

-- One loop step: brings up every area / section whose deadline passed.
local function step()
	local t = now()
	local rulesNow: KnockdownLogic.Rules? = nil
	for player, rt in runtimes do
		if rt.state.downCount == 0 then
			continue
		end
		rulesNow = rulesNow or rules()
		KnockdownLogic.expire(rt.state, t, rulesNow :: KnockdownLogic.Rules, ended)
		if #ended > 0 then
			for _, entry in ended do
				onAreaUp(player, rt, entry, "timer", t)
			end
			table.clear(ended)
			sendState(player)
			changed(player)
		end
	end
	for _, rt in bots do
		if rt.state.downCount == 0 then
			continue
		end
		rulesNow = rulesNow or rules()
		KnockdownLogic.expire(rt.state, t, rulesNow :: KnockdownLogic.Rules, ended)
		for _, entry in ended do
			clearArea(rt.plotIndex, entry.area)
			rt.centers[entry.area] = nil
		end
		table.clear(ended)
	end
	if next(instanceTargets) ~= nil then
		for section, untilTime in instanceTargets do
			if untilTime <= t or section.Parent == nil then
				table.insert(doneInstances, section)
			end
		end
		for _, section in doneInstances do
			instanceTargets[section] = nil
			if section.Parent ~= nil then
				section:SetAttribute(ATTR.Until, nil)
				section:SetAttribute(ATTR.At, nil)
				section:SetAttribute(ATTR.Center, nil)
			end
		end
		table.clear(doneInstances)
	end
end

-- Forgets a player (leave / plot released): their plot's areas are cleared by PlotService.
local function forget(player: Player)
	runtimes[player] = nil
end

function Knockdown.Init() end

function Knockdown.Start()
	if started then
		return
	end
	started = true
	Remotes.onServerEvent("KnockdownTap", onTap)
	PlotService.PlotReleased:Connect(function(player: Player)
		forget(player)
	end)
	PlotService.PlotAssigned:Connect(function(player: Player)
		-- A new plot (New Player Mode swap, re-claim): nothing carries over.
		forget(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		forget(player)
		tapLimiter:Forget(player)
	end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < KnockdownConfig.TickSeconds then
			return
		end
		accumulator = 0
		if next(runtimes) == nil and next(bots) == nil and next(instanceTargets) == nil then
			return
		end
		local started0 = os.clock()
		step()
		reportTime(os.clock() - started0)
	end)
end

return Knockdown
