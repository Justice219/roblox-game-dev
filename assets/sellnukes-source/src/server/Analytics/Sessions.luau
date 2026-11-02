--!strict
--[[
	Sessions — player sessions, daily activity, retention cohorts, payers, the device split and the
	validated client reports (FunnelStep, ClientDevice). Ported from RoBeasts' AnalyticsService
	session half (startSession / markActive / markPayer / endSession), adapted to the tycoon.

	Lifecycle (wired by AnalyticsService.Start):
		PlayerAdded          → startSession: clock, UTC start day / hour, join source (followed a
		                       friend, notification LaunchData), friends already in the server
		ProfileLoaded        → onProfileLoaded: lifetime session number, markActive("load") (new /
		                       returning / D-N / carry rejoin), cohort + funnel "joined", buffered
		                       client funnel steps, staff verdict, play clock starts
		ProfileReleasing     → onProfileReleasing: snapshot (area, rebirths, pets) + fold play time
		every flush          → flushActivity: markActive("flush") for players online across 00:00
		                       UTC (carry-overs), fold play time, forward batched income to Roblox
		PlayerRemoving       → endSession: sessions / length / hour / device / funnel-at-leave /
		                       where players stop (tycoon leaveArea) / pets at leave

	Roblox-aligned signals (owner R122; AnalyticsConfig.Algorithm, docs/analytics.md "Roblox
	signals"; Roblox's Recommended for You ranking reads these per user):
		rbx:session:<lt60|60to180|qualified>   every ended session (same population as `sessions`)
		rbx:bounce:<lt60|60to180>, rbx:bounceDev:<class>:<lt60|60to180|stay>
		                                       a tracked new player's FIRST session (the ftue:joined
		                                       population) by Roblox's bounce bucket
		rbx:playSec                            session seconds credited at every flush / release /
		                                       leave, at most PlayCapSeconds per player per UTC day
		                                       across sessions and servers (profile.analytics.rbxDay /
		                                       rbxSec), split at UTC midnight onto the day played
		rbx:coplay (+ rbx:coplayVia:<path>)    once per player per UTC day (the unique-surface bit
		                                       "coplay"): followed a friend who is here, joined from a
		                                       friend's invite who is here (JoinData.ReferredByPlayerId),
		                                       was followed / invited in to (host), or a private server
		                                       with company
		rbx:day:<2..28>                        markActive: active on day N of the cohort (play days
		                                       per user D2-7 / D8-28; D1 is r1)

	Client reports (untrusted; counts only, nothing is ever granted from them):
		FunnelStep(step, a?, b?)   token bucket → exact allowlists → once / capped per session;
		                           every refusal counts ops:clientRefused:FunnelStep AND
		                           ops:clientRefused:FunnelStep:<reason> (AnalyticsConfig
		                           .ClientRefusalReasons; "cap" counts the reason key only)
		ClientDevice(device, input) token bucket → exact allowlists → kept, counted at leave

	Connects to: Runtime (state, markers), Recorder (counts), ReturnTags (carry / notify),
	AnalyticsMarks, AnalyticsLogic (buckets, validators), ReceiptAccounting (payer-day bitmap).

	Example:
		Sessions.startSession(player)
		Sessions.onProfileLoaded(player, profile, true)  -- a brand-new profile
		Sessions.endSession(player)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local AnalyticsMarks = require(ReplicatedStorage.Shared.Config.AnalyticsMarks)
local FtueLogic = require(ReplicatedStorage.Shared.Analytics.FtueLogic)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local AnalyticsLogic = require(script.Parent.AnalyticsLogic)
local ReceiptAccounting = require(script.Parent.ReceiptAccounting)
local Recorder = require(script.Parent.Recorder)
local ReturnTags = require(script.Parent.ReturnTags)
local Runtime = require(script.Parent.Runtime)
local WorldRecorders = require(script.Parent.WorldRecorders)

type Profile = Runtime.Profile
type SessionInfo = Runtime.SessionInfo
type AnalyticsData = Runtime.AnalyticsData

local Sessions = {}

local sessions = Runtime.sessions
local count = Recorder.count

local ALGORITHM = AnalyticsConfig.Algorithm

-- Per-player token buckets for the client analytics remotes.
local funnelLimiter = RateLimiter.new(AnalyticsConfig.ClientFunnel.Burst, AnalyticsConfig.ClientFunnel.PerSecond)
local deviceLimiter = RateLimiter.new(AnalyticsConfig.DeviceReport.Burst, AnalyticsConfig.DeviceReport.PerSecond)

-- Screens whose open also counts a unique surface (uniq:<surface>, once per player per day).
local SCREEN_SURFACE: { [string]: string } = { Shop = "shop", Pets = "pets", Offers = "offers" }

local NOTIFY_LAUNCH: { [string]: boolean } = {}
for _, id in AnalyticsConfig.NotifyLaunchData do
	NOTIFY_LAUNCH[id] = true
end

-- Owner R122 Roblox-signal keys, built once (hot paths never build these strings).
local SESSION_KEY: { [string]: string } = {
	lt60 = "rbx:session:lt60",
	["60to180"] = "rbx:session:60to180",
	long = "rbx:session:qualified",
}
local BOUNCE_KEY: { [string]: string } = { lt60 = "rbx:bounce:lt60", ["60to180"] = "rbx:bounce:60to180" }
-- The bounceDev suffix of a bucket (a qualified first session "stays").
local BOUNCE_LABEL: { [string]: string } = { lt60 = "lt60", ["60to180"] = "60to180", long = "stay" }
-- "rbx:day:<n>" for n = 2..PlayDayMax (D1 is the existing r1).
local DAY_KEY: { [number]: string } = {}
for n = 2, ALGORITHM.PlayDayMax do
	DAY_KEY[n] = `rbx:day:{n}`
end
-- The once-per-player-per-day bit (AnalyticsConfig.Unique.Surfaces) behind rbx:coplay.
local COPLAY_SURFACE = "coplay"
type CoplayVia = "follow" | "invite" | "host" | "private"
local COPLAY_VIA_KEY: { [string]: string } = {
	follow = "rbx:coplayVia:follow",
	invite = "rbx:coplayVia:invite",
	host = "rbx:coplayVia:host",
	private = "rbx:coplayVia:private",
}
-- FunnelStep refusals: the pre-R122 key (kept, comparable with the 11-01 baseline) + one per reason.
type FunnelRefusal = "rate" | "malformed" | "implausible" | "cap" | "unknown" | "popup"
local REFUSED_BASE = "ops:clientRefused:FunnelStep"
local REFUSED_KEY: { [string]: string } = {}
for _, reason in AnalyticsConfig.ClientRefusalReasons do
	REFUSED_KEY[reason] = `{REFUSED_BASE}:{reason}`
end
-- Largest user id accepted from join data (a whole number Roblox could issue; doubles stay exact).
local MAX_USER_ID = 2 ^ 53

--[[
	Owner R122 per-session state, kept beside Runtime.sessions so the Roblox signals stay in this
	module (created in startSession, dropped in endSession):
		creditMark  os.clock() up to which the session's time was offered to rbx:playSec (starts at
		            the join: Roblox's playtime includes the loading screen)
		creditFrac  the fraction of a second not credited yet (credits are whole seconds)
		coplayVia   a co-play path seen before this player's profile loaded (applied at load)
]]
type RbxState = { creditMark: number, creditFrac: number, coplayVia: CoplayVia? }
local rbxState: { [Player]: RbxState } = {}

-- The player's join data (pcall: GetJoinData can fail for a departing player).
local function joinDataOf(player: Player): { [string]: any }?
	local ok, data = pcall(function(): any
		return player:GetJoinData()
	end)
	return if ok and type(data) == "table" then data else nil
end

--[[ True when the join came from one of our notifications (exact LaunchData match). ]]
local function joinedFromNotification(data: { [string]: any }?): boolean
	local launch = if data ~= nil then data.LaunchData else nil
	return type(launch) == "string" and NOTIFY_LAUNCH[launch] == true
end

--[[
	The inviter named by the join data (Roblox sets JoinData.ReferredByPlayerId when a player joins
	from SocialService:PromptGameInvite — the R78 INVITE FRIENDS / R122 HUD INVITE flow), or nil.
	Untrusted shape: a whole positive user id that is not the player's own.
	Example: referrerOf(player, { ReferredByPlayerId = 42 }) --> 42
]]
local function referrerOf(player: Player, data: { [string]: any }?): number?
	local raw = if data ~= nil then data.ReferredByPlayerId else nil
	if type(raw) ~= "number" or raw ~= raw or raw % 1 ~= 0 or raw < 1 or raw > MAX_USER_ID or raw == player.UserId then
		return nil
	end
	return raw
end

--[[ True on a VIP private server (an owner bought it); reserved servers have owner 0. ]]
local function inPrivateServer(): boolean
	local ok, owner = pcall(function(): any
		return game.PrivateServerOwnerId
	end)
	return ok and type(owner) == "number" and owner ~= 0
end

--[[
	Counts rbx:coplay (+ rbx:coplayVia:<via>) once per player per UTC day, across servers, through
	the unique-surface bitmap (AnalyticsMarks.markSeen, bit "coplay"; zero extra DataStore work).
	Before the player's profile loads the path is remembered and applied by onProfileLoaded; New
	Player Mode sandboxes and sessions that cannot save never count (as dau). Never yields.
]]
local function markCoplay(player: Player, via: CoplayVia)
	local info = sessions[player]
	local state = rbxState[player]
	if info == nil or state == nil then
		return
	end
	if not info.loaded then
		if state.coplayVia == nil then
			state.coplayVia = via
		end
		return
	end
	if Runtime.inNewPlayerMode(player) then
		return
	end
	local data, profile = Runtime.dataOf(player)
	if data == nil or not Runtime.canMark(player, profile) then
		return
	end
	if AnalyticsMarks.markSeen(data, Recorder.today(), COPLAY_SURFACE) then
		count("core", "rbx:coplay")
		count("core", COPLAY_VIA_KEY[via])
		Runtime.saveMarks(player)
	end
end

--[[
	Intentional co-play at a join (Roblox's "co-play days": join / invite / private server). Only a
	friend who is actually in this server makes it co-play:
		followed a friend here (FollowUserId)          → the joiner "follow", that friend "host"
		joined from a friend's invite, inviter here    → the joiner "invite", the inviter "host"
		a VIP private server with someone else here    → everyone here "private"
	Players already in a server who merely happen to be friends are not intentional co-play.
]]
local function coplayAtJoin(player: Player, data: { [string]: any }?)
	local followed = player.FollowUserId
	if followed ~= 0 and followed ~= player.UserId then
		local host = Players:GetPlayerByUserId(followed)
		if host ~= nil and host ~= player then
			markCoplay(player, "follow")
			markCoplay(host, "host")
			return
		end
	end
	local inviterId = referrerOf(player, data)
	local inviter = if inviterId ~= nil then Players:GetPlayerByUserId(inviterId) else nil
	if inviter ~= nil and inviter ~= player then
		markCoplay(player, "invite")
		markCoplay(inviter, "host")
		return
	end
	if inPrivateServer() then
		local others = Players:GetPlayers()
		if #others >= 2 then
			for _, other in others do
				markCoplay(other, "private")
			end
		end
	end
end

--[[
	Credits the session time since the last credit to rbx:playSec under the daily cap (flush,
	profile release and leave). The mark always advances, so time is never offered twice; time
	without a writable profile (or in New Player Mode) is never credited, like Runtime.foldPlay.
	The cap state (rbxDay / rbxSec) rides the profile's normal autosave. Never yields.
]]
local function creditPlay(player: Player)
	local info = sessions[player]
	local state = rbxState[player]
	if info == nil or state == nil or not info.loaded then
		return
	end
	local now = os.clock()
	local elapsed = math.max(0, now - state.creditMark) + state.creditFrac
	state.creditMark = now
	state.creditFrac = 0
	if Runtime.inNewPlayerMode(player) then
		return
	end
	local data, profile = Runtime.dataOf(player)
	if data == nil or not Runtime.canMark(player, profile) then
		return
	end
	local whole = math.floor(elapsed)
	state.creditFrac = elapsed - whole
	if whole <= 0 then
		return
	end
	local credits, day, sec = AnalyticsLogic.creditPlay(data.rbxDay, data.rbxSec, os.time(), whole)
	if day ~= data.rbxDay or sec ~= data.rbxSec then
		data.rbxDay, data.rbxSec = day, sec
		Runtime.saveMarks(player)
	end
	for _, credit in credits do
		Recorder.countOn(credit.day, "core", "rbx:playSec", credit.seconds)
	end
end

-- Counts one FunnelStep refusal: the base key (except "cap", which it never counted) + its reason.
local function refuseFunnel(reason: FunnelRefusal)
	if reason ~= "cap" then
		count("core", REFUSED_BASE)
	end
	count("core", REFUSED_KEY[reason])
end

--[[
	Starts the player's analytics session (idempotent). Never yields: the friends check runs on its
	own thread.
]]
function Sessions.startSession(player: Player)
	if sessions[player] ~= nil then
		return
	end
	local joinData = joinDataOf(player)
	local info: SessionInfo = {
		startedClock = os.clock(),
		startDay = Recorder.today(),
		startHour = os.date("!%H", os.time()) :: string,
		loaded = false,
		firstSession = false,
		playMark = nil,
		newDay = nil,
		d1Day = nil,
		d1CarryDay = nil,
		carryChecked = false,
		device = nil,
		input = nil,
		ftueReached = {},
		pendingFtue = {},
		onboardingStep = 0,
		clientSteps = {},
		screenOpens = 0,
		tutSteps = {},
		tutClient = {},
		offersSeen = AnalyticsLogic.newOffersSeen(),
		npm = false,
		staff = false,
		followed = player.FollowUserId ~= 0,
		notifyJoin = joinedFromNotification(joinData),
		incomeBatch = 0,
		snapshot = nil,
		perfAt = nil,
		connections = {},
	}
	sessions[player] = info
	rbxState[player] = { creditMark = info.startedClock, creditFrac = 0, coplayVia = nil }
	-- R122 intentional co-play (the joiner's path waits for its profile; a loaded host counts now).
	coplayAtJoin(player, joinData)
	-- New Player Mode may be switched on after the join: the verdict is sticky for the session.
	table.insert(
		info.connections,
		player:GetAttributeChangedSignal(AnalyticsConfig.NewPlayerModeAttribute):Connect(function()
			Runtime.inNewPlayerMode(player)
		end)
	)
	if info.followed then
		count("core", "followed")
		count("social", "joinFollow")
	end
	-- Friends already here (bounded IsFriendsWith checks; each yields once, so off-thread).
	task.spawn(function()
		local friends = 0
		local checked = 0
		for _, other in Players:GetPlayers() do
			if other ~= player and checked < AnalyticsConfig.Social.MaxFriendChecks then
				checked += 1
				local ok, isFriend = pcall(player.IsFriendsWithAsync, player, other.UserId)
				if ok and isFriend == true then
					friends += 1
				end
			end
		end
		if sessions[player] == info then
			count("social", `friendsIn:{AnalyticsLogic.countBucket(friends, AnalyticsConfig.Social.FriendBuckets)}`)
		end
	end)
end

--[[
	On a tracked player's D-N return: "r<N>:all" and "r<N>:<milestone>" for every first-day
	milestone they reached. Reads markers only (no save needed).
]]
local function countReturnMilestones(data: AnalyticsData, days: number)
	if not AnalyticsMarks.isTracked(data) then
		return
	end
	count("core", AnalyticsMarks.returnKeyAt(days, AnalyticsConfig.FirstDay.BaseId))
	for _, milestone in AnalyticsMarks.milestonesOf(data) do
		count("core", AnalyticsMarks.returnKeyAt(days, milestone))
	end
end

--[[
	A carry-over from earlier today who JOINS again: counts "r<N>:carryRejoin" (plus, for D1, the
	device D1 and milestone split the flush skipped). Only the first profile load of this server
	session is a join. Returns true when the marker was cleared (profile changed).
]]
local function takeCarryRejoin(player: Player, data: AnalyticsData, day: number): boolean
	local info = sessions[player]
	if info == nil or info.carryChecked then
		return false
	end
	info.carryChecked = true
	local action = ReturnTags.carryMarkerAction(data.carry, day, false)
	if action == "none" or action == "keep" then
		return false
	end
	data.carry = 0
	if action == "rejoin" and data.first > 0 then
		local age = day - data.first
		for _, n in AnalyticsConfig.RetentionDays do
			if age == n then
				count("core", ReturnTags.key(n, "carryRejoin"))
			end
		end
		if age == 1 then
			info.d1Day = day
			countReturnMilestones(data, 1)
		elseif age == 7 then
			countReturnMilestones(data, 7)
		end
	end
	return true
end

--[[
	Marks a player active today (once per UTC day, across servers: the day is stored in the
	session-locked profile). New players start a cohort; returning players count toward the D-N
	retention of their cohort. `via` = "load" (a join) or "flush" (online across midnight: a
	carry-over, tagged r<N>:carry and marked for a later genuine rejoin).
]]
function Sessions.markActive(player: Player, profile: Profile, isNewProfile: boolean, via: ReturnTags.Via)
	if not Runtime.canMark(player, profile) then
		return
	end
	local data = Runtime.dataOf(player)
	if data == nil then
		return
	end
	local day = Recorder.today()
	local changed = false
	if via == "load" and takeCarryRejoin(player, data, day) then
		changed = true
	end
	if isNewProfile and data.first == 0 then
		data.first = day
		changed = true
		count("core", "new")
		local info = sessions[player]
		if info ~= nil then
			info.newDay = day
		end
		if AnalyticsMarks.startCohort(data) then
			count("core", AnalyticsMarks.cohortKey(AnalyticsConfig.FirstDay.BaseId))
		end
	end
	if data.last < day then
		data.last = day
		changed = true
		count("core", "dau")
		if data.first ~= day then
			count("core", "returning")
			if data.first > 0 then
				local age = day - data.first
				-- R122 play days per user (D2-7 / D8-28): every active day counts, carry-overs
				-- included (Roblox counts a day the player played, however they got there).
				local dayKey = DAY_KEY[age]
				if dayKey ~= nil then
					count("core", dayKey)
				end
				local carried = false
				local info = sessions[player]
				for _, n in AnalyticsConfig.RetentionDays do
					if age == n then
						count("core", `r{n}`)
						local notify = via == "load" and info ~= nil and info.notifyJoin
						local tag = ReturnTags.tagFor(via, notify)
						if tag ~= nil then
							count("core", ReturnTags.key(n, tag))
						end
						carried = carried or tag == "carry"
					end
				end
				if carried then
					data.carry = day
				end
				if age == 1 and info ~= nil then
					if via == "flush" then
						info.d1CarryDay = day
					else
						info.d1Day = day
					end
				end
				-- D1 / D7 by first-day outcome: joins only (a carry-over counts if it rejoins).
				if via == "load" and (age == 1 or age == 7) then
					countReturnMilestones(data, age)
				end
			else
				count("core", "legacy")
			end
		end
	end
	if changed then
		Runtime.saveMarks(player)
	end
end

--[[
	Counts a Robux spender once per UTC day (payer-day bitmap, shared with receipt accounting) and
	their first ever purchase. Returns (payerToday, firstEver) for the caller's revenue keys.
]]
function Sessions.markPayer(player: Player?, profile: Profile?, robux: number): (boolean, boolean)
	if player == nil or profile == nil or not Runtime.canMark(player, profile) then
		return false, false
	end
	local data = Runtime.dataOf(player)
	if data == nil then
		return false, false
	end
	local day = Recorder.today()
	local payer = ReceiptAccounting.markPayerDay(data, day)
	local first = data.payFirst == 0
	if payer then
		count("core", "payers")
	end
	if first then
		data.payFirst = day
		count("core", "newPayers")
	end
	data.payLast = math.max(data.payLast, day)
	data.robux = math.min(1e9, data.robux + math.max(0, math.floor(robux)))
	Runtime.saveMarks(player)
	return payer, first
end

-- Pets owned / equipped in a profile (bounded walk; 0 when the pets system is absent).
local function petCounts(profile: Profile): (number, number)
	local pets = profile.pets
	if type(pets) ~= "table" then
		return 0, 0
	end
	local owned, equipped = 0, 0
	if type(pets.owned) == "table" then
		for _ in pets.owned do
			owned += 1
			if owned >= 100000 then
				break
			end
		end
	end
	if type(pets.equipped) == "table" then
		equipped = math.min(#pets.equipped, AnalyticsConfig.Pets.MaxEquipped)
	end
	return owned, equipped
end

-- Refreshes the session's leave snapshot from the live profile.
local function snapshot(player: Player, profile: Profile?)
	local info = sessions[player]
	if info == nil or profile == nil then
		return
	end
	local owned, equipped = petCounts(profile)
	-- Read the profile we were HANDED, never a lookup by player: at server shutdown
	-- PlayerDataService drops the player's session before ProfileReleasing fires, so a lookup would
	-- miss and fall back to the join-time snapshot (the R129 "everyone leaves in area 1" bug).
	local previous = info.snapshot
	info.snapshot = {
		area = Runtime.areaFromProfile(profile) or (if previous ~= nil then previous.area else 0),
		rebirths = Runtime.rebirthsFromProfile(profile),
		petsOwned = owned,
		petsEquipped = equipped,
	}
end

--[[
	The profile loaded: classify the session, count activity / retention, start the play clock.
	@param isNew optional verdict from PlayerDataService; without it a profile with analytics.first
	       == 0 and no progress at all (no cash ever earned, no pads, no rebirths) is new.
]]
function Sessions.onProfileLoaded(player: Player, profile: Profile, isNew: boolean?)
	local info = sessions[player]
	if info == nil then
		Sessions.startSession(player)
		info = sessions[player]
	end
	if info == nil or info.loaded then
		return
	end
	local data = Runtime.dataOf(player)
	if data == nil then
		return
	end
	local writable = Runtime.canMark(player, profile)
	local fresh = isNew
	if fresh == nil then
		local tycoon = profile.tycoon
		local pads = if type(tycoon) == "table" then tycoon.pads else nil
		fresh = data.first == 0
			and data.sessions == 0
			and (tonumber(profile.totalEarned) or 0) <= 0
			and (tonumber(profile.rebirths) or 0) <= 0
			and (type(pads) ~= "table" or next(pads) == nil)
	end
	if writable then
		-- Only a saving session is a counted session number (an in-memory fallback is not).
		data.sessions = math.min(1e9, data.sessions + 1)
		Runtime.saveMarks(player)
		count("core", `sessNo:{AnalyticsLogic.countBucket(data.sessions, AnalyticsConfig.SessionNumberBuckets)}`)
	end
	info.firstSession = writable and data.sessions == 1
	Runtime.isStaff(player)
	Runtime.inNewPlayerMode(player)
	if not info.npm then
		Sessions.markActive(player, profile, fresh == true, "load")
	end
	info.loaded = true
	info.playMark = os.clock()
	snapshot(player, profile)
	if fresh == true and not info.npm then
		Runtime.markFtue(player, "joined")
	end
	-- Client funnel steps that arrived before the profile (loading screen ends early).
	local buffered = info.pendingFtue
	info.pendingFtue = {}
	for _, step in AnalyticsConfig.Ftue.Steps do
		if buffered[step] then
			Runtime.markFtue(player, step)
		end
	end
	-- R122: a co-play path seen at the join, now that the once-per-day bit can be saved.
	local state = rbxState[player]
	local via = if state ~= nil then state.coplayVia else nil
	if state ~= nil and via ~= nil then
		state.coplayVia = nil
		markCoplay(player, via)
	end
end

--[[
	The profile is about to be saved and released: snapshot + fold the play clock + credit the
	capped Roblox playtime first (the last moment the profile is still writable).
]]
function Sessions.onProfileReleasing(player: Player, profile: Profile)
	snapshot(player, profile)
	Runtime.foldPlay(player)
	creditPlay(player)
end

--[[
	Every flush: online players crossing 00:00 UTC are marked active (carry-overs), play time is
	folded into the saved clock, the capped Roblox playtime (R122 rbx:playSec) is credited, and
	batched production income is forwarded to Roblox as one economy Source per player.
]]
function Sessions.flushActivity()
	for player, info in sessions do
		local profile = Runtime.profileOf(player)
		if profile ~= nil and info.loaded and not info.npm then
			Sessions.markActive(player, profile, false, "flush")
			Runtime.foldPlay(player)
			-- R122 capped playtime (a midnight crossing is split onto the day each part was played).
			creditPlay(player)
		end
		-- Time per world (worlds "seconds:<world>") and batched world-currency income.
		WorldRecorders.fold(player)
		WorldRecorders.flushIncome(player)
		if info.incomeBatch > 0 then
			local amount = info.incomeBatch
			info.incomeBatch = 0
			local live = Runtime.livePlayer(player)
			local balance = if profile ~= nil then tonumber(profile.cash) or 0 else 0
			if live ~= nil then
				Runtime.forwarder.economy(
					live,
					"Source",
					"Cash",
					amount,
					balance,
					"Gameplay",
					AnalyticsConfig.Economy.BatchedIncomeSku
				)
			end
		end
	end
end

--[[
	Ends the session: counts its length, hour, device, the Roblox session / first-play bounce bucket
	(R122), the first-session funnel at leave, where the player stopped in the tycoon, and their
	pets. Idempotent.
]]
function Sessions.endSession(player: Player)
	-- Forget the per-player limiters FIRST: a remote charged before the session existed (or after
	-- it ended) must not leave an orphan bucket behind (security audit 2026-10-30).
	funnelLimiter:Forget(player.UserId)
	deviceLimiter:Forget(player.UserId)
	local info = sessions[player]
	if info == nil then
		return
	end
	-- R129: refresh the leave snapshot (area / rebirths / pets) from the live profile. Both this
	-- module and PlayerDataService listen to Players.PlayerRemoving and Roblox does not promise
	-- their order; when THIS handler runs first, ProfileReleasing's snapshot comes too late (the
	-- session is gone by then) and the join-time snapshot was recorded instead — live 2026-11-01:
	-- 395 of 407 sessions "left in area 1" and 401 "owned 0 pets" although 71 players reached
	-- area 2 and 21 hatched. When PlayerDataService ran first the profile is gone (nil) and the
	-- snapshot ProfileReleasing just took is kept as is.
	snapshot(player, Runtime.profileOf(player))
	-- Final play fold while the profile may still be writable (ProfileReleasing usually did it).
	Runtime.foldPlay(player)
	creditPlay(player)
	-- Last time-in-world fold (the session's world state is dropped with the session table).
	WorldRecorders.fold(player)
	sessions[player] = nil
	rbxState[player] = nil
	for _, connection in info.connections do
		connection:Disconnect()
	end
	local seconds = math.max(0, os.clock() - info.startedClock)
	local whole = math.floor(seconds)
	local device = info.device or "unknown"
	local bucket = AnalyticsLogic.robloxBucket(seconds)
	count("core", "sessions")
	-- R122: every ended session by Roblox bucket (Σ rbx:session:* = sessions on R122+ servers, which
	-- the algorithm scorecard uses as its coverage check).
	count("core", SESSION_KEY[bucket])
	count("core", "sessionSeconds", whole)
	count("core", `len:{AnalyticsLogic.sessionBucket(seconds)}`)
	Recorder.countOn(info.startDay, "core", `hour:{info.startHour}`, 1)
	count("core", `device:{device}`)
	count("core", `input:{info.input or "unknown"}`)
	count("core", `devSeconds:{device}`, whole)
	-- Cohort / D1 by device: counted now that the device class is known.
	if info.newDay ~= nil then
		Recorder.countOn(info.newDay, "core", `devNew:{device}`, 1)
	end
	if info.d1Day ~= nil then
		Recorder.countOn(info.d1Day, "core", `devR1:{device}`, 1)
	end
	if info.d1CarryDay ~= nil then
		Recorder.countOn(info.d1CarryDay, "core", ReturnTags.deviceCarryKey(device), 1)
	end
	if not info.loaded then
		count("core", "ops:leftBeforeProfile")
		return
	end
	if info.npm then
		return
	end
	-- Where players stop (all sessions) and their pets at leave.
	local snap = info.snapshot
	if snap ~= nil and snap.area >= 1 then
		count("tycoon", `leaveArea:{snap.area}`)
	end
	if snap ~= nil then
		count("pets", `owned:{AnalyticsLogic.countBucket(snap.petsOwned, AnalyticsConfig.Pets.OwnedBuckets)}`)
		count("pets", `equipped:{snap.petsEquipped}`)
	end
	-- R122 Roblox first-play bounce: the FIRST session of a tracked new player — exactly the
	-- ftue:joined population (joined is marked at this session's load), so rbx:bounce:* / ftue:joined
	-- is Roblox's bounce rate. Players who leave before their profile loads cannot be told apart
	-- from returning ones (ops:leftBeforeProfile) and are not in it.
	if info.firstSession and not info.staff and info.ftueReached.joined == true then
		local bounceKey = BOUNCE_KEY[bucket]
		if bounceKey ~= nil then
			count("core", bounceKey)
		end
		count("core", `rbx:bounceDev:{device}:{BOUNCE_LABEL[bucket]}`)
	end
	-- The first session's funnel at leave (tracked new players only).
	if info.firstSession and not info.staff and next(info.ftueReached) ~= nil then
		local furthest = AnalyticsMarks.furthestStep(info.ftueReached)
		count("core", `ftueLen:{AnalyticsLogic.sessionBucket(seconds)}`)
		count("core", `ftueLeft:{furthest}`)
		count("core", `ftueDev:{device}:{furthest}`)
	end
end

--------------------------------------------------------------------------------------------------
-- Client reports
--------------------------------------------------------------------------------------------------

local CLIENT_STEPS: { [string]: boolean } = {}
for _, step in AnalyticsConfig.Ftue.ClientSteps do
	CLIENT_STEPS[step] = true
end

--[[
	The server's OWN view of a player for the R78 first-minute claims (FtueLogic.claimPlausible):
	the plot reveal finished (PlotRevealed, set by PlotService), the stored tutorial step, and the
	character's horizontal distance from the plot entrance spawn the reveal walked it to. Nothing
	here comes from the client.
]]
local function ftueFacts(player: Player): FtueLogic.ClaimFacts
	local profile: any = Runtime.profileOf(player)
	local tycoon = if type(profile) == "table" then profile.tycoon else nil
	local step = if type(tycoon) == "table" then tycoon.tutorialStep else nil
	local entranceStuds: number? = nil
	local plotIndex = player:GetAttribute("PlotIndex")
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if
		type(plotIndex) == "number"
		and plotIndex % 1 == 0
		and plotIndex >= 1
		and plotIndex <= WorldLayout.PlotCount
		and root ~= nil
		and root:IsA("BasePart")
	then
		local spawnAt = WorldLayout.entranceSpawn(plotIndex).Position
		local offset = root.Position - spawnAt
		entranceStuds = math.sqrt(offset.X * offset.X + offset.Z * offset.Z)
	end
	return {
		plotRevealed = player:GetAttribute("PlotRevealed") == true,
		tutorialStep = if type(step) == "number" and step == step then step else 0,
		entranceStuds = entranceStuds,
	}
end

--[[
	FunnelStep (C→S). Untrusted: token bucket → exact allowlists → once / capped per session.
	Each refusal counts ops:clientRefused:FunnelStep + ops:clientRefused:FunnelStep:<reason>
	(rate | malformed | implausible | cap | unknown | popup; refuseFunnel). Repeats of a
	once-per-session step, an out-of-range tutorial step and an over-cap WORLD UNLOCKED popup claim
	stay silent, as before R122.
		(Ftue.ClientSteps id)          funnel client steps (once per session; the funnel itself
		                               counts once per player): loadingDone, hudShown, and the
		                               R78 firstScreenClosed / tutorialSeen / firstMove, which also
		                               need FtueLogic.claimPlausible on the server's own facts
		("open", screen, source?)      retention "open:<screen>" + "openFrom:<screen>:<source>"
		("tutorial", step)             tycoon "tutClient:<step>" (once per step per session)
		("worldPopup", worldId, action) worlds "popup:<world>:<action>" (R57 WORLD UNLOCKED popup;
		                               extra world + PopupActions allowlist, capped per session)
	@return true when something was counted (tests)
]]
function Sessions.onFunnelStep(player: Player, rawStep: unknown, rawA: unknown, rawB: unknown): boolean
	local info = sessions[player]
	if info == nil then
		return false
	end
	if not funnelLimiter:Allow(player.UserId) then
		refuseFunnel("rate")
		return false
	end
	if type(rawStep) ~= "string" or #rawStep > AnalyticsConfig.ClientSourceMaxLength then
		refuseFunnel("malformed")
		return false
	end
	if Runtime.inNewPlayerMode(player) then
		count("core", "npm:funnelStep")
		return false
	end
	if CLIENT_STEPS[rawStep] then
		if info.clientSteps[rawStep] then
			return false
		end
		-- R78 §6 steps must agree with the server's own state (an implausible claim is refused and
		-- NOT remembered, so a later honest one still counts).
		if FtueLogic.checksClaim(rawStep) and not FtueLogic.claimPlausible(rawStep, ftueFacts(player)) then
			refuseFunnel("implausible")
			return false
		end
		info.clientSteps[rawStep] = true
		Runtime.markFtue(player, rawStep)
		return true
	elseif rawStep == "open" then
		if info.screenOpens >= AnalyticsConfig.ClientFunnel.SessionCap then
			refuseFunnel("cap")
			return false
		end
		local keys = AnalyticsLogic.screenOpen(rawA, rawB)
		if keys == nil then
			refuseFunnel("malformed")
			return false
		end
		info.screenOpens += 1
		for _, key in keys do
			count("retention", key)
		end
		local surface = SCREEN_SURFACE[rawA :: string]
		if surface ~= nil then
			Runtime.markUnique(player, surface)
		end
		return true
	elseif rawStep == "tutorial" then
		local step = AnalyticsLogic.integerIn(rawA, 1, AnalyticsConfig.ClientFunnel.MaxTutorialStep)
		if step == nil or info.tutClient[step] then
			return false
		end
		info.tutClient[step] = true
		count("tycoon", `tutClient:{step}`)
		return true
	elseif rawStep == "worldPopup" then
		if WorldRecorders.popupClaim(player, rawA, rawB) then
			return true
		end
		-- An over-cap repeat is ignored silently; a malformed claim is a refusal.
		if
			type(rawA) ~= "string"
			or type(rawB) ~= "string"
			or table.find(AnalyticsConfig.Worlds.PopupActions, rawB) == nil
		then
			refuseFunnel("popup")
		end
		return false
	end
	refuseFunnel("unknown")
	return false
end

--[[
	ClientDevice (C→S): the client's device class and input mode, for the device split only.
	Untrusted: token bucket, exact allowlists, live session required. The LAST valid claim is kept
	and counted once at leave; a lying client can at most mislabel its own session's device row.
]]
function Sessions.onClientDevice(player: Player, rawDevice: unknown, rawInput: unknown): boolean
	if not deviceLimiter:Allow(player.UserId) then
		return false
	end
	local info = sessions[player]
	if info == nil or type(rawDevice) ~= "string" or type(rawInput) ~= "string" then
		return false
	end
	if
		table.find(AnalyticsConfig.DeviceClasses, rawDevice) == nil
		or table.find(AnalyticsConfig.InputModes, rawInput) == nil
	then
		count("core", "ops:clientRefused:ClientDevice")
		return false
	end
	info.device = rawDevice
	info.input = rawInput
	return true
end

--[[ A unique id for one Roblox funnel attempt (LogFunnelStepEvent sessionId). ]]
function Sessions.funnelSessionId(): string
	return HttpService:GenerateGUID(false)
end

return table.freeze(Sessions)
