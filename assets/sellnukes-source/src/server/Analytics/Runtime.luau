--!strict
--[[
	Runtime — shared live state of the analytics recorders: the dependency boundary to the player
	data layer, the per-player analytics sessions, the staff / New Player Mode exclusions, the
	recorder guards, and the profile-marker rules (unique surfaces, first-day milestones, the
	new-player funnel, the analytics play clock).

	Why a separate module: AnalyticsService is split by concern (Sessions, Revenue, Recorders,
	Flusher, Reports) to stay readable and far below Luau's 200-local main-chunk limit (Studio
	compiles with debug info; "Out of local registers" would stop the server bootstrap). They all
	share this one state module.

	Dependency boundary (`Runtime.setDeps`, filled by AnalyticsService.Start from B1's services):
		getProfile(player)  the loaded profile table or nil
		canMutate(player)   the session may still write (session-locked, not released)
		markSaved(player)   mark the profile for the next save WITHOUT a client push
		isAdmin(player)     cached, non-yielding admin verdict (AnalyticsAuth)
	Tests pass their own deps; nothing here requires another service.

	Exclusions (measurement hygiene, never punishment):
		- New Player Mode (admin sandbox, attribute AnalyticsConfig.NewPlayerModeAttribute): every
		  per-player recorder counts ONLY core "npm:<recorder>" (guard).
		- Staff (an admin on a LIVE server, or a profile stamped staff): economy / revenue
		  recorders count "staff:<recorder>" instead (economyGuard); sessions still count.
		Both verdicts are cached on the session (O(1) on hot paths such as producer income).

	Example:
		Runtime.setDeps({ getProfile = ..., canMutate = ..., markSaved = ..., isAdmin = ... })
		local recorder = Runtime.guard("padBought", function(player, padId) ... end)
		Runtime.markFtue(player, "firstPad")
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local AnalyticsMarks = require(ReplicatedStorage.Shared.Config.AnalyticsMarks)
local AnalyticsLogic = require(script.Parent.AnalyticsLogic)
local Recorder = require(script.Parent.Recorder)
local RobloxForwarder = require(script.Parent.RobloxForwarder)

export type Profile = { [string]: any }
export type AnalyticsData = AnalyticsMarks.AnalyticsData

export type Deps = {
	getProfile: (player: Player) -> Profile?,
	canMutate: (player: Player) -> boolean,
	markSaved: (player: Player) -> (),
	isAdmin: (player: Player) -> boolean,
}

-- What the session remembers of the profile for the leave counters (PlayerDataService may
-- release the profile before our PlayerRemoving handler runs).
export type Snapshot = { area: number, rebirths: number, petsOwned: number, petsEquipped: number }

-- One player's analytics session (PlayerAdded → PlayerRemoving).
export type SessionInfo = {
	startedClock: number,
	startDay: number,
	startHour: string, -- "00".."23" UTC
	loaded: boolean, -- the profile loaded and was classified this session
	firstSession: boolean, -- the player's first ever session (analytics.sessions == 1)
	playMark: number?, -- os.clock() of the last fold into analytics.play (nil before load)
	newDay: number?, -- day this session counted the player as new (devNew at leave)
	d1Day: number?, -- day this session counted a D1 join (devR1 at leave)
	d1CarryDay: number?, -- day this session counted a D1 carry-over (devR1carry at leave)
	carryChecked: boolean, -- the first profile load of this session checked the carry marker
	device: string?, -- last valid ClientDevice claim
	input: string?,
	ftueReached: { [string]: boolean }, -- funnel steps newly reached this session
	pendingFtue: { [string]: boolean }, -- client steps that arrived before the profile loaded
	onboardingStep: number, -- last Roblox onboarding step forwarded
	clientSteps: { [string]: boolean }, -- FunnelStep client steps accepted this session
	screenOpens: number, -- FunnelStep screen opens counted this session
	tutSteps: { [number]: boolean }, -- server tutorial steps counted this session
	tutClient: { [number]: boolean }, -- client tutorial steps counted this session
	offersSeen: AnalyticsLogic.OffersSeenState,
	npm: boolean, -- in New Player Mode (attribute; sticky for the session once seen)
	staff: boolean, -- staff verdict (sticky)
	followed: boolean, -- joined by following a friend
	notifyJoin: boolean, -- joined from one of our notifications (LaunchData)
	incomeBatch: number, -- cash income not yet forwarded to Roblox (batched per flush)
	snapshot: Snapshot?,
	perfAt: number?, -- os.clock() of the last accepted ClientPerf report
	connections: { RBXScriptConnection },
}

local Runtime = {}

-- Analytics sessions by player (strong keys; removed in Sessions.endSession).
Runtime.sessions = {} :: { [Player]: SessionInfo }

-- Roblox Creator Dashboard mirror (rate-limited, pcall'd; AnalyticsConfig.Forward).
Runtime.forwarder = RobloxForwarder.new({ enabled = AnalyticsConfig.Forward.Enabled })

-- Staff rule applies on live servers only: in Studio every tester is an admin (spec §14), and
-- Studio never writes analytics anyway, so verification playtests still see real counters.
local LIVE_STAFF = not RunService:IsStudio()

local deps: Deps? = nil

-- Analytics tables already validated by AnalyticsMarks.ensure (weak keys: a released profile's
-- table is collected with it; tables, never Instances, are weak-keyed here).
local ensured: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--[[ Installs the player-data boundary (AnalyticsService.Start or a test). ]]
function Runtime.setDeps(newDeps: Deps?)
	deps = newDeps
end

--[[ The installed deps (nil before Start). ]]
function Runtime.deps(): Deps?
	return deps
end

--[[ A connected Player instance, or nil (bots / departed / non-players). ]]
function Runtime.livePlayer(player: unknown): Player?
	if
		typeof(player) == "Instance"
		and (player :: Instance):IsA("Player")
		and (player :: Instance).Parent == Players
	then
		return player :: Player
	end
	return nil
end

--[[ A Player instance (connected or not), or nil. ]]
function Runtime.asPlayer(player: unknown): Player?
	if typeof(player) == "Instance" and (player :: Instance):IsA("Player") then
		return player :: Player
	end
	return nil
end

--[[ The player's loaded profile (nil before Start, before load, or after release). ]]
function Runtime.profileOf(player: Player?): Profile?
	local d = deps
	if player == nil or d == nil then
		return nil
	end
	local ok, profile = pcall(d.getProfile, player)
	if ok and type(profile) == "table" then
		return profile
	end
	return nil
end

--[[
	The profile's analytics record, made valid in place the first time (AnalyticsMarks.ensure),
	plus the profile. nil when the profile is not loaded or has no analytics table.
]]
function Runtime.dataOf(player: Player?): (AnalyticsData?, Profile?)
	local profile = Runtime.profileOf(player)
	if profile == nil then
		return nil, nil
	end
	local raw = profile.analytics
	if type(raw) ~= "table" then
		-- A loader without the field: create it so the markers persist with the next save.
		raw = AnalyticsMarks.newAnalytics()
		profile.analytics = raw
		return raw, profile
	end
	if not ensured[raw] then
		-- Validate once per live analytics table (nothing is added to the saved data for it).
		AnalyticsMarks.ensure(raw)
		ensured[raw] = true
	end
	return raw :: AnalyticsData, profile
end

--[[
	True when the player's CURRENT profile may receive markers now: the session can still save and
	`profile` is that player's live profile (a stale callback never marks a released profile).
]]
function Runtime.canMark(player: Player?, profile: Profile?): boolean
	local d = deps
	if player == nil or profile == nil or d == nil then
		return false
	end
	if Runtime.profileOf(player) ~= profile then
		return false
	end
	local ok, writable = pcall(d.canMutate, player)
	return ok and writable == true
end

--[[ Marks the profile for its next save without a client push (analytics fields never replicate). ]]
function Runtime.saveMarks(player: Player)
	local d = deps
	if d ~= nil then
		pcall(d.markSaved, player)
	end
end

--------------------------------------------------------------------------------------------------
-- Exclusions and guards
--------------------------------------------------------------------------------------------------

--[[ True while the player is in New Player Mode (admin sandbox). Sticky per session once seen. ]]
function Runtime.inNewPlayerMode(player: unknown): boolean
	local p = Runtime.asPlayer(player)
	if p == nil then
		return false
	end
	local info = Runtime.sessions[p]
	if info ~= nil and info.npm then
		return true
	end
	local active = p:GetAttribute(AnalyticsConfig.NewPlayerModeAttribute) == true
	if active and info ~= nil then
		info.npm = true
	end
	return active
end

--[[
	True when `player` is staff: an admin on a live server (stamped into the profile on the way) or
	a profile stamped earlier. Cached on the session; never yields.
]]
function Runtime.isStaff(player: unknown): boolean
	local p = Runtime.asPlayer(player)
	if p == nil then
		return false
	end
	local info = Runtime.sessions[p]
	if info ~= nil and info.staff then
		return true
	end
	local d = deps
	local admin = false
	if LIVE_STAFF and d ~= nil then
		local ok, verdict = pcall(d.isAdmin, p)
		admin = ok and verdict == true
	end
	local data, profile = Runtime.dataOf(p)
	local staff = admin or (data ~= nil and data.staff == true)
	if admin and data ~= nil and not data.staff and Runtime.canMark(p, profile) then
		data.staff = true
		Runtime.saveMarks(p)
	end
	if staff and info ~= nil then
		info.staff = true
	end
	return staff
end

--[[ True when the player's events are kept out of player metrics (staff or New Player Mode). ]]
function Runtime.isExcluded(player: unknown): boolean
	return Runtime.inNewPlayerMode(player) or Runtime.isStaff(player)
end

-- The first value of a vararg pack (a recorder's player argument).
local function firstArgument(...: unknown): unknown
	return (...)
end

--[[
	Wraps a recorder so a bug or bad argument never throws into gameplay code, and diverts a player
	in New Player Mode (first argument) to core "npm:<name>".
	Example: AnalyticsService.padBought = Runtime.guard("padBought", function(player, padId) ... end)
]]
function Runtime.guard<A...>(name: string, fn: (A...) -> ()): (A...) -> ()
	local npmKey = `npm:{name}`
	return function(...: A...)
		if Runtime.inNewPlayerMode(firstArgument(...)) then
			Recorder.count("core", npmKey)
			return
		end
		local ok, err = pcall(fn, ...)
		if not ok then
			Recorder.warn(name, tostring(err))
		end
	end
end

--[[
	guard() plus the staff diversion for economy / revenue recorders: a staff player's event counts
	only core "staff:<name>"; everyone else's runs `fn`.
]]
function Runtime.economyGuard<A...>(name: string, fn: (A...) -> ()): (A...) -> ()
	local staffKey = `staff:{name}`
	return Runtime.guard(name, function(...: A...)
		if Runtime.isStaff(firstArgument(...)) then
			Recorder.count("core", staffKey)
			return
		end
		fn(...)
	end)
end

--------------------------------------------------------------------------------------------------
-- Profile markers
--------------------------------------------------------------------------------------------------

--[[
	Counts the player once per UTC day for a unique surface (core "uniq:<surface>"), across servers.
	No-op without a writable current session (as dau).
]]
function Runtime.markUnique(player: Player?, surface: string)
	local data, profile = Runtime.dataOf(player)
	if player == nil or data == nil or not Runtime.canMark(player, profile) then
		return
	end
	if AnalyticsMarks.markSeen(data, Recorder.today(), surface) then
		Recorder.count("core", AnalyticsMarks.uniqueKey(surface))
		Runtime.saveMarks(player)
	end
end

--[[
	Records a first-day milestone (core "cohort:<milestone>", once per player) while it is still
	the player's first UTC day and the profile is a tracked cohort member.
]]
function Runtime.markFirstDay(player: Player?, milestone: string)
	local data, profile = Runtime.dataOf(player)
	if player == nil or data == nil or not Runtime.canMark(player, profile) then
		return
	end
	if data.first ~= Recorder.today() then
		return
	end
	if AnalyticsMarks.markMilestone(data, milestone) then
		Recorder.count("core", AnalyticsMarks.cohortKey(milestone))
		Runtime.saveMarks(player)
	end
end

-- Minutes-to-step labels (ftueAt:<step>:<label>).
local FTUE_MINUTES = AnalyticsConfig.Ftue.MinuteBuckets
-- Roblox onboarding step number per forwarded funnel step.
local ONBOARDING_INDEX: { [string]: number } = {}
for index, step in AnalyticsConfig.Ftue.OnboardingSteps do
	ONBOARDING_INDEX[step] = index
end

--[[
	The player's lifetime play seconds by the analytics clock: the saved total plus this session's
	unfolded time. 0 when unknown.
]]
function Runtime.playSeconds(player: Player?): number
	local data = Runtime.dataOf(player)
	if player == nil or data == nil then
		return 0
	end
	local info = Runtime.sessions[player]
	local mark = if info ~= nil then info.playMark else nil
	return data.play + (if mark ~= nil then math.max(0, os.clock() - mark) else 0)
end

--[[ Play seconds into the current rebirth run (playSeconds - runAt, never negative). ]]
function Runtime.runSeconds(player: Player?): number
	local data = Runtime.dataOf(player)
	if data == nil then
		return 0
	end
	return math.max(0, Runtime.playSeconds(player) - data.runAt)
end

--[[
	Folds this session's elapsed play time into analytics.play (flush + leave). Only a writable
	current session folds; the mark always advances so time is never counted twice.
]]
function Runtime.foldPlay(player: Player)
	local info = Runtime.sessions[player]
	if info == nil or info.playMark == nil then
		return
	end
	local now = os.clock()
	local elapsed = math.max(0, now - (info.playMark :: number))
	info.playMark = now
	local data, profile = Runtime.dataOf(player)
	if data ~= nil and elapsed > 0 and Runtime.canMark(player, profile) then
		data.play = math.floor(data.play + elapsed + 0.5)
		Runtime.saveMarks(player)
	end
end

--[[
	Forwards a reached funnel step to Roblox's onboarding funnel when it is one of the forwarded
	steps, in order (a step older than the last forwarded one is skipped, once per session).
]]
local function forwardOnboarding(player: Player, info: SessionInfo, step: string)
	local number = ONBOARDING_INDEX[step]
	if number == nil or number <= info.onboardingStep then
		return
	end
	info.onboardingStep = number
	local live = Runtime.livePlayer(player)
	if live ~= nil then
		Runtime.forwarder.onboarding(live, number, step)
	end
end

--[[
	Marks a new-player funnel step for a tracked profile (once per player, any session) and counts
	core "ftue:<step>", "ftueS1:<step>" (first session), "ftueMin:<step>" (+ play minutes) and
	"ftueAt:<step>:<bucket>". A client step that arrives before the profile loaded is buffered and
	applied by Sessions at load. Excluded players never enter the funnel.
	Example: Runtime.markFtue(player, "firstPad")
]]
function Runtime.markFtue(player: Player?, step: string)
	if player == nil then
		return
	end
	local info = Runtime.sessions[player]
	if info == nil or Runtime.isExcluded(player) then
		return
	end
	if not info.loaded then
		info.pendingFtue[step] = true
		return
	end
	local data, profile = Runtime.dataOf(player)
	if data == nil or not Runtime.canMark(player, profile) then
		return
	end
	if not AnalyticsMarks.markFtue(data, step) then
		return
	end
	local minutes = Runtime.playSeconds(player) / 60
	Recorder.count("core", `ftue:{step}`)
	if info.firstSession then
		Recorder.count("core", `ftueS1:{step}`)
	end
	Recorder.count("core", `ftueMin:{step}`, math.floor(minutes * 100 + 0.5) / 100)
	Recorder.count("core", `ftueAt:{step}:{AnalyticsLogic.bucketOf(minutes, FTUE_MINUTES, "m")}`)
	info.ftueReached[step] = true
	forwardOnboarding(player, info, step)
	Runtime.saveMarks(player)
end

--[[ The session's device class claim ("phone" / "tablet" / "desktop" / "console"), or nil. ]]
function Runtime.deviceOf(player: Player?): string?
	local info = if player ~= nil then Runtime.sessions[player] else nil
	return if info ~= nil then info.device else nil
end

--[[ The player's current tycoon area from the live profile (or the session snapshot), 0 if unknown. ]]
function Runtime.areaOf(player: Player?): number
	local area = Runtime.areaFromProfile(Runtime.profileOf(player))
	if area ~= nil then
		return area
	end
	local info = if player ~= nil then Runtime.sessions[player] else nil
	local snapshot = if info ~= nil then info.snapshot else nil
	return if snapshot ~= nil then snapshot.area else 0
end

--[[
	The Nuke Town tycoon area stored in a profile table (validated 1..99, floored), or nil when the
	profile is missing or the value is not a sane number. Reads the table it is GIVEN, so it works
	while the profile is being released — after PlayerDataService has already dropped the player's
	session and `Runtime.profileOf(player)` returns nil (server shutdown path).

	Example: Runtime.areaFromProfile({ tycoon = { area = 3 } }) --> 3
]]
function Runtime.areaFromProfile(profile: Profile?): number?
	local tycoon = if profile ~= nil then profile.tycoon else nil
	local area = if type(tycoon) == "table" then tycoon.area else nil
	if type(area) == "number" and area == area and area >= 1 and area <= 99 then
		return math.floor(area)
	end
	return nil
end

--[[ The player's rebirth count from the live profile (0 if unknown). ]]
function Runtime.rebirthsOf(player: Player?): number
	return Runtime.rebirthsFromProfile(Runtime.profileOf(player))
end

--[[
	The rebirth count stored in a profile table (validated 0..1e9, floored; 0 if missing). Like
	areaFromProfile it reads the table it is given, so a releasing profile still reports correctly.

	Example: Runtime.rebirthsFromProfile({ rebirths = 2 }) --> 2
]]
function Runtime.rebirthsFromProfile(profile: Profile?): number
	local rebirths = if profile ~= nil then profile.rebirths else nil
	if type(rebirths) == "number" and rebirths == rebirths and rebirths >= 0 and rebirths < 1e9 then
		return math.floor(rebirths)
	end
	return 0
end

return Runtime
