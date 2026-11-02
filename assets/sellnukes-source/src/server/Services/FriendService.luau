--!strict
--[[
	FriendService — the R78 Friend Boost, invite analytics and referral rewards (spec §4;
	docs/social.md). Pure rules: Server/Social/FriendLogic.

	Friend Boost
		+PercentPerFriend % cash per Roblox friend in the same server, at most +MaxPercent %
		(ModifierSources provider "friendBoost" → { friendCash = 1 + percent / 100 }, offline = false).
		On every join a background task asks Player:IsFriendsWithAsync for each pair it does not
		know yet (pcall, CheckAttempts with backoff, one answer cached per unordered pair, so both
		players share it). A pair is cached only while BOTH players are still here (a player who
		left during the web call is never re-added), and a leave drops that player's pairs. Every
		change re-computes the affected players, invalidates their modifiers and pushes
		`Social { kind = "friends", count, percent, names }`; the friend already in the server gets
		the toast "Your friend X joined: +10% cash!", the joiner one summary toast.
	Invites
		The prompt is client-side (SocialService:PromptGameInvite needs the client). The
		`FriendInvite` remote only COUNTS what the client reports (allowlisted action, clamped
		recipient count, rate-limited); nothing is granted from it. Owner R122: the same remote
		carries the co-play SURFACE reports of the HUD INVITE button and the once-per-session
		invite moment (InviteConfig.Reports; own rate limit + per-session caps per report).
	Referrals
		A brand-new profile (first load, saving session, a real join, never a New Player Mode
		sandbox) whose Player:GetJoinData().ReferredByPlayerId names someone else gets
		Referral.NewcomerReward (50 Gems + 2x Cash 15 min through RewardGrant); profile.referral.by
		records the inviter so it can never be claimed twice. The inviter gets Referral.InviterReward
		(100 Gems + 1 free spin) per new friend, at most MaxPaid ever, idempotent per newcomer id
		(profile.referral.seen):
		  * inviter in this server (profile loaded, saving session) → paid at once;
		  * otherwise → queued in DataStore Referral.StoreName (+ "_Studio" in Studio, so a
		    playtest never writes the live store), key "Inviter_<id>", with UpdateAsync (deduped by
		    newcomer id, capped list, GDPR user ids on the key), retried with backoff;
		  * on the inviter's next join the queue is read, every unseen id is paid in one
		    non-yielding step, the profile is COMMITTED (ProfileStore.commitAsync), and only then
		    are those ids removed from the queue — a crash in between re-reads the queue and
		    `seen` stops a second payment, so every newcomer pays exactly once.

	Analytics (social family): friends:boost:<0-5>, friends:pair, friends:checkFail,
	friends:invite:<prompted|sent|closed|unavailable|failed>, friends:inviteTo (recipients),
	friends:hud:<shown|tap>, friends:moment:<shown|invite|later> (owner R122 surfaces),
	friends:ref:<new|paid|queued|duplicate|full|capped|seen|self|notNew|queueFail|delivered>.
	Admin (Lazy.registerAdmin): FriendBoostToggle, FriendBoostPercent, FriendStatus (Server tab);
	ReferralStatus, ReferralTest (Studio only) (Players tab).

	Public API:
		FriendService.percent(player) -> number             the player's Friend Boost percent
		FriendService.friendNames(player) -> { string }      display names of friends here
		FriendService.referralStatus(player) -> table?       by / paid / seen / last queue read

	Connects to: PlayerDataService (profiles, signals, canMutate, commit), Tycoon/ModifierSources,
	Retention/RewardGrant, Social/FriendLogic, Shared/Config/SocialConfig, Shared/Net/{Remotes,
	Validate}, Shared/Util/RateLimiter, Server/Event/Lazy (analytics + admin),
	Client/Social/SocialClient, UI/Screens/{Friends, BoostChips}.

	Usage: FEATURE service (boot list after RushService; before AdminService).
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local FriendLogic = require(ServerScriptService.Server.Social.FriendLogic)
-- Owner R122: the HUD INVITE button / invite moment reports (allowlist + per-session caps).
local InviteConfig = require(ReplicatedStorage.Shared.Config.InviteConfig)
local Lazy = require(ServerScriptService.Server.Event.Lazy)
local ModifierSources = require(ServerScriptService.Server.Tycoon.ModifierSources)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RewardGrant = require(ServerScriptService.Server.Retention.RewardGrant)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

local FRIENDS = SocialConfig.Friends
local REFERRAL = SocialConfig.Referral
local INVITE = SocialConfig.Invite
local ATTR = SocialConfig.Attributes
local TEXT = SocialConfig.Text
-- Queued referrals older than this are dropped on read (seconds).
local QUEUE_MAX_AGE = REFERRAL.QueueMaxAgeDays * 86400
-- Analytics bucket cap of friends:boost (5 = five or more friends).
local MAX_BOOST_BUCKET = 5
-- Seconds a request waits at most for DataStore budget before trying anyway.
local BUDGET_WAIT_SECONDS = 10

local FriendService = {}

-- Friend Boost state per player in the server.
type Boost = { count: number, percent: number, names: { string } }

-- Players being tracked (joined, not left) → join order (who is "the friend who joined").
local present: { [Player]: number } = {}
local joinCounter = 0
-- Players whose join task already sent its summary toast (a later pair answer toasts on its own).
local summarized: { [Player]: boolean } = {}
-- pairKey → friends? (only for pairs whose players are both still here).
local pairCache: { [string]: boolean } = {}
-- pairKey → true while a web check runs (the other side's task never asks twice).
local pairPending: { [string]: boolean } = {}
local boosts: { [Player]: Boost } = {}
-- The last referral queue read per player (admin ReferralStatus; display only).
local queueReads: { [Player]: { at: number, pending: number, paid: number, ok: boolean } } = {}
-- Players whose referral queue is being consumed (never two consumers at once).
local consuming: { [Player]: boolean } = {}
local inviteLimiter = RateLimiter.new(INVITE.Burst, INVITE.PerSecond)
-- Owner R122: the surface reports (friends:hud:* / friends:moment:*) have their own bucket so a
-- HUD tap never eats the invite outcome's budget, and their counts per player session.
local surfaceLimiter = RateLimiter.new(InviteConfig.ReportBurst, InviteConfig.ReportPerSecond)
local surfaceCounts: { [Player]: { [string]: number } } = {}
local started = false
local storeCache: any = nil

-- The admin-overridable values right now (ReplicatedStorage attributes).
local function live(): SocialConfig.Live
	return SocialConfig.live(function(name: string): any
		return ReplicatedStorage:GetAttribute(name)
	end)
end

-- Counts one social analytics key (never errors / yields).
local function track(player: Player?, key: string, amount: number?)
	Lazy.analytics("social", player, key, amount)
end

-- UserIds of every tracked player.
local function presentIds(): { number }
	local ids: { number } = {}
	for player in present do
		table.insert(ids, player.UserId)
	end
	return ids
end

-- Pushes a player's Friend Boost state to their client.
local function push(player: Player)
	local boost = boosts[player]
	if boost == nil or player.Parent ~= Players then
		return
	end
	Remotes.fireClient("Social", player, {
		kind = "friends",
		count = boost.count,
		percent = if live().friendsOn then boost.percent else 0,
		names = table.clone(boost.names),
	})
end

--[[
	Re-computes one player's Friend Boost from the pair cache. Invalidates modifiers + pushes when
	it changed. Never yields.
	@return (old percent, new percent)
]]
local function recompute(player: Player): (number, number)
	if not present[player] then
		return 0, 0
	end
	local settings = live()
	local count, friendIds = FriendLogic.friendsOf(player.UserId, presentIds(), pairCache)
	local percent = FriendLogic.percent(count, settings.friendPercent, FRIENDS.MaxPercent)
	local names: { string } = {}
	for _, id in friendIds do
		local friend = Players:GetPlayerByUserId(id)
		if friend ~= nil and #names < FRIENDS.MaxNames then
			table.insert(names, friend.DisplayName)
		end
	end
	local old = boosts[player]
	local oldPercent = if old ~= nil then old.percent else 0
	local same = old ~= nil and old.count == count and old.percent == percent and #old.names == #names
	if same and old ~= nil then
		for index, name in names do
			if old.names[index] ~= name then
				same = false
				break
			end
		end
	end
	boosts[player] = { count = count, percent = percent, names = names }
	if not same then
		ModifierSources.invalidate(player)
		push(player)
	end
	return oldPercent, percent
end

local applyFriendship: (a: Player, b: Player) -> ()

--[[
	Asks Roblox whether two players are friends (yields; pcall + retries with backoff).
	@return boolean? — nil when every attempt failed
]]
local function askFriends(a: Player, b: Player): boolean?
	for attempt = 1, FRIENDS.CheckAttempts do
		local ok, result = pcall(a.IsFriendsWithAsync, a, b.UserId)
		if ok and type(result) == "boolean" then
			return result
		end
		if attempt < FRIENDS.CheckAttempts then
			task.wait(FRIENDS.RetrySeconds[attempt] or FRIENDS.RetrySeconds[#FRIENDS.RetrySeconds])
		end
		if not (present[a] and present[b]) then
			return nil -- one of them left meanwhile: the answer no longer matters
		end
	end
	return nil
end

--[[
	A pair just turned out to be friends: re-computes both and toasts. The player who was here
	FIRST hears "Your friend X joined: +10% cash!"; the later joiner hears it in their join task's
	summary, or — when this answer arrives after that summary (the other side's task resolved the
	pair late) — gets a fresh "Friends here" toast now. Never yields.
]]
applyFriendship = function(a: Player, b: Player)
	local earlier, later = a, b
	if (present[b] or 0) < (present[a] or 0) then
		earlier, later = b, a
	end
	local laterBefore, laterAfter = recompute(later)
	local before, after = recompute(earlier)
	if not live().friendsOn then
		return
	end
	if after > before then
		PlayerDataService.notify(
			earlier,
			string.format(TEXT.FriendJoined, later.DisplayName, after - before),
			"success",
			SocialConfig.Client.FriendsIcon
		)
	end
	if summarized[later] and laterAfter > laterBefore then
		PlayerDataService.notify(
			later,
			string.format(TEXT.FriendsHere, laterAfter),
			"success",
			SocialConfig.Client.FriendsIcon
		)
	end
end

--[[
	The join task of one player: checks every unknown pair with the players already here, applies
	each answer at once (both sides), then sends the joiner's summary. Yields (web calls).
]]
local function checkJoin(player: Player)
	local found = 0
	for _, other in Players:GetPlayers() do
		if other == player or not present[other] then
			continue
		end
		if not present[player] then
			return -- the joiner left
		end
		local key = FriendLogic.pairKey(player.UserId, other.UserId)
		if pairCache[key] ~= nil or pairPending[key] then
			if pairCache[key] == true then
				found += 1
			end
			continue
		end
		pairPending[key] = true
		local friends = askFriends(player, other)
		pairPending[key] = nil
		-- Departed-player race: cache only while BOTH are still here.
		if not (present[player] and present[other]) then
			continue
		end
		if friends == nil then
			track(player, "friends:checkFail")
			friends = false
		end
		pairCache[key] = friends
		if friends then
			found += 1
			track(nil, "friends:pair")
			applyFriendship(player, other)
		end
	end
	if not present[player] then
		return
	end
	recompute(player)
	push(player) -- the joiner always learns their state (0 friends included)
	summarized[player] = true
	track(player, `friends:boost:{math.min(found, MAX_BOOST_BUCKET)}`)
	local boost = boosts[player]
	if boost ~= nil and boost.percent > 0 and live().friendsOn then
		PlayerDataService.notify(
			player,
			string.format(TEXT.FriendsHere, boost.percent),
			"success",
			SocialConfig.Client.FriendsIcon
		)
	end
end

-- A player joined: start tracking + the background friend checks.
local function onJoin(player: Player)
	if present[player] then
		return
	end
	joinCounter += 1
	present[player] = joinCounter
	boosts[player] = { count = 0, percent = 0, names = {} }
	task.spawn(checkJoin, player)
end

-- A player left: drop their pairs and re-compute everyone who counted them.
local function onLeave(player: Player)
	present[player] = nil
	summarized[player] = nil
	boosts[player] = nil
	queueReads[player] = nil
	consuming[player] = nil
	inviteLimiter:Forget(player)
	surfaceLimiter:Forget(player)
	surfaceCounts[player] = nil
	local id = player.UserId
	local affected: { number } = {}
	for key, friends in pairCache do
		local a, b = string.match(key, "^(%d+):(%d+)$")
		local first, second = tonumber(a), tonumber(b)
		if first == id or second == id then
			pairCache[key] = nil
			if friends then
				table.insert(affected, if first == id then second :: number else first :: number)
			end
		end
	end
	for _, otherId in affected do
		local other = Players:GetPlayerByUserId(otherId)
		if other ~= nil then
			recompute(other)
		end
	end
end

-- The "friendBoost" ModifierSources provider (pure, never yields).
local function provider(player: Player, _profile: any): (any, number?)
	if ReplicatedStorage:GetAttribute(ATTR.FriendsEnabled) == false then
		return nil, nil
	end
	local boost = boosts[player]
	if boost == nil or boost.percent <= 0 then
		return nil, nil
	end
	return { friendCash = FriendLogic.multiplier(boost.percent) }, nil
end

-- Re-computes every player (percent setting / switch changed) and invalidates everyone.
local function recomputeAll()
	for player in present do
		recompute(player)
		push(player)
	end
	ModifierSources.invalidateAll()
end

-- ── Referrals ───────────────────────────────────────────────────────────────────────────────

-- The referral queue DataStore ("_Studio" suffix in Studio), or nil when unavailable.
local function referralStore(): any
	if storeCache ~= nil then
		return storeCache
	end
	local name = if RunService:IsStudio() then REFERRAL.StoreName .. REFERRAL.StudioSuffix else REFERRAL.StoreName
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(name)
	end)
	if ok then
		storeCache = store
		return store
	end
	return nil
end

-- Waits (bounded) until the DataStore budget allows one request of `kind`.
local function waitForBudget(kind: Enum.DataStoreRequestType)
	local deadline = os.clock() + BUDGET_WAIT_SECONDS
	while os.clock() < deadline do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(kind)
		end)
		if not ok or budget > 0 then
			return
		end
		task.wait(1)
	end
end

-- The queue key of an inviter.
local function queueKey(inviterId: number): string
	return `{REFERRAL.KeyPrefix}{inviterId}`
end

-- True when `player` can receive referral rewards right now (loaded, saving, not a sandbox).
local function canReceive(player: Player): boolean
	return player.Parent == Players
		and PlayerDataService.getProfile(player) ~= nil
		and PlayerDataService.canMutate(player)
		and not PlayerDataService.isNewPlayerMode(player)
end

--[[
	Pays one newcomer to an inviter who is here (non-yielding ledger + reward step).
	@return FriendLogic.PayResult
]]
local function payInviter(inviter: Player, newcomerId: number): FriendLogic.PayResult
	local profile = PlayerDataService.getProfile(inviter)
	if profile == nil then
		return "invalid"
	end
	local result = FriendLogic.payInviter(profile.referral, newcomerId, REFERRAL.MaxPaid, REFERRAL.MaxSeen)
	if result == "paid" then
		RewardGrant.grant(
			inviter,
			REFERRAL.InviterReward,
			"referral",
			{ saveSoon = true, extraFields = { "referral" } }
		)
		local reward = REFERRAL.InviterReward
		PlayerDataService.notify(
			inviter,
			string.format(
				TEXT.InviterReward,
				reward.gems or 0,
				reward.spins or 0,
				profile.referral.paid,
				REFERRAL.MaxPaid
			),
			"reward",
			SocialConfig.Client.FriendsIcon
		)
		track(inviter, "friends:ref:paid")
	elseif result == "capped" or result == "seen" then
		track(inviter, `friends:ref:{result}`)
	end
	return result
end

local consumeQueue: (inviter: Player) -> ()

--[[
	Queues a newcomer for an inviter who is not here (yields: UpdateAsync with retries + backoff).
	When the inviter turns out to be here afterwards, their queue is consumed at once.
]]
local function queueReferral(inviterId: number, newcomerId: number)
	local status: FriendLogic.QueueStatus? = nil
	for attempt = 1, REFERRAL.WriteAttempts do
		local store = referralStore()
		if store ~= nil then
			waitForBudget(Enum.DataStoreRequestType.UpdateAsync)
			local ok, err = pcall(function()
				store:UpdateAsync(queueKey(inviterId), function(old: unknown): (any, any)
					local record, result =
						FriendLogic.enqueue(old, newcomerId, os.time(), REFERRAL.MaxQueue, QUEUE_MAX_AGE)
					status = result
					if record == nil then
						return nil, nil -- duplicate / full: cancel the write
					end
					return record, FriendLogic.recordUserIds(record, inviterId)
				end)
			end)
			if ok then
				break
			end
			status = nil
			warn(`[FriendService] referral queue write failed (attempt {attempt}): {err}`)
		end
		if attempt < REFERRAL.WriteAttempts then
			task.wait(REFERRAL.BackoffSeconds[attempt] or REFERRAL.BackoffSeconds[#REFERRAL.BackoffSeconds])
		end
	end
	if status == nil then
		track(nil, "friends:ref:queueFail")
		return
	end
	track(nil, `friends:ref:{status}`)
	-- The inviter may have joined this server meanwhile (their join read ran before our write).
	local inviter = Players:GetPlayerByUserId(inviterId)
	if status == "queued" and inviter ~= nil and canReceive(inviter) then
		task.spawn(consumeQueue, inviter)
	end
end

--[[
	Delivers one new referral to the inviter: paid at once when they are here, otherwise queued.
	Never yields (the queue write runs in its own task).
]]
local function deliver(inviterId: number, newcomerId: number)
	local inviter = Players:GetPlayerByUserId(inviterId)
	if inviter ~= nil and canReceive(inviter) then
		payInviter(inviter, newcomerId)
		return
	end
	task.spawn(queueReferral, inviterId, newcomerId)
end

--[[
	Reads an inviter's queue, pays every unseen newcomer, commits the profile, then removes the
	handled ids from the queue (exactly-once, see the header). Yields.
]]
consumeQueue = function(inviter: Player)
	if consuming[inviter] then
		return
	end
	consuming[inviter] = true
	local profile = PlayerDataService.getProfile(inviter)
	local store = referralStore()
	local function finish(pending: number, paid: number, ok: boolean)
		consuming[inviter] = nil
		if present[inviter] then
			queueReads[inviter] = { at = os.time(), pending = pending, paid = paid, ok = ok }
		end
	end
	if profile == nil or store == nil then
		finish(0, 0, false)
		return
	end
	waitForBudget(Enum.DataStoreRequestType.GetAsync)
	local ok, raw = pcall(function()
		return store:GetAsync(queueKey(inviter.UserId))
	end)
	if not ok then
		warn(`[FriendService] referral queue read failed: {raw}`)
		finish(0, 0, false)
		return
	end
	local entries = FriendLogic.readQueue(raw, os.time(), QUEUE_MAX_AGE, REFERRAL.MaxQueue)
	if #entries == 0 then
		finish(0, 0, true)
		return
	end
	-- Pay in ONE non-yielding pass (the profile cannot change hands mid-way).
	if not canReceive(inviter) or PlayerDataService.getProfile(inviter) ~= profile then
		finish(#entries, 0, false)
		return
	end
	local handled: { number } = {}
	local paid = 0
	for _, entry in entries do
		local result = payInviter(inviter, entry.id)
		table.insert(handled, entry.id)
		if result == "paid" then
			paid += 1
		end
	end
	-- Durable first: only a committed payment may leave the queue.
	local durable = true
	if paid > 0 then
		local version = PlayerDataService.markChanged(inviter, true, { "referral" })
		local session = PlayerDataService.getSession(inviter)
		local profileStore = PlayerDataService.getStore()
		local allowUnsaved = RunService:IsStudio() and not PlayerDataService.isSavingEnabled()
		durable = allowUnsaved
			or (
				version ~= nil
				and session ~= nil
				and profileStore ~= nil
				and profileStore:commitAsync(session, version)
			)
		track(inviter, "friends:ref:delivered", paid)
	end
	if not durable then
		warn("[FriendService] referral rewards not committed yet; the queue is kept for the next join")
		finish(#entries, paid, false)
		return
	end
	for attempt = 1, REFERRAL.WriteAttempts do
		waitForBudget(Enum.DataStoreRequestType.UpdateAsync)
		local removed, err = pcall(function()
			store:UpdateAsync(queueKey(inviter.UserId), function(old: unknown): (any, any)
				local record = FriendLogic.dequeue(old, handled, os.time(), REFERRAL.MaxQueue, QUEUE_MAX_AGE)
				return record, FriendLogic.recordUserIds(record, inviter.UserId)
			end)
		end)
		if removed then
			break
		end
		warn(`[FriendService] referral queue cleanup failed (attempt {attempt}): {err}`)
		if attempt < REFERRAL.WriteAttempts then
			task.wait(REFERRAL.BackoffSeconds[attempt] or REFERRAL.BackoffSeconds[#REFERRAL.BackoffSeconds])
		end
	end
	finish(#entries, paid, true)
end

--[[
	ProfileLoaded: the newcomer side (reward + deliver to the inviter) and the inviter side
	(consume the queue on a join). Never yields (queue I/O runs in tasks).
]]
local function onLoaded(player: Player, profile: any, isNew: boolean)
	local reason = PlayerDataService.getLoadReason(player)
	local joinOk, joinData = pcall(function()
		return player:GetJoinData()
	end)
	local rawReferrer = if joinOk and type(joinData) == "table" then (joinData :: any).ReferredByPlayerId else nil
	local verdict, inviterId = FriendLogic.newcomerVerdict({
		isNew = isNew,
		reason = reason,
		canMutate = PlayerDataService.canMutate(player),
		sandbox = PlayerDataService.isNewPlayerMode(player),
		rawReferrer = rawReferrer,
		selfId = player.UserId,
		by = profile.referral.by,
	})
	if verdict == "ok" and inviterId ~= nil then
		profile.referral.by = inviterId
		RewardGrant.grant(
			player,
			REFERRAL.NewcomerReward,
			"referral",
			{ saveSoon = true, extraFields = { "referral" } }
		)
		local reward = REFERRAL.NewcomerReward
		local boost = reward.boost
		PlayerDataService.notify(
			player,
			string.format(TEXT.NewcomerReward, reward.gems or 0, if boost ~= nil then boost.seconds // 60 else 0),
			"reward",
			SocialConfig.Client.FriendsIcon
		)
		track(player, "friends:ref:new")
		deliver(inviterId, player.UserId)
	elseif verdict == "self" or verdict == "notNew" then
		track(player, `friends:ref:{verdict}`)
	end
	-- Inviter side: every real join reads the queue once (never a New Player Mode swap).
	if reason == "join" and canReceive(player) then
		task.spawn(consumeQueue, player)
	end
end

--[[
	Owner R122: one co-play SURFACE report (InviteConfig.Reports: "hud:shown" / "hud:tap" /
	"moment:shown" / "moment:invite" / "moment:later") → social "friends:<report>". Analytics only;
	its own rate limit + a per-session cap per report (InviteConfig.reportAllowed), so a forged
	client can add at most a few counts.
	@param action an allowlisted report (already validated)
]]
local function onSurfaceReport(player: Player, action: string)
	if not present[player] or not surfaceLimiter:Allow(player) then
		return
	end
	local counts = surfaceCounts[player]
	if counts == nil then
		counts = {}
		surfaceCounts[player] = counts
	end
	if not InviteConfig.reportAllowed(counts, action) then
		return
	end
	counts[action] = (counts[action] or 0) + 1
	track(player, `friends:{action}`)
end

--[[
	FriendInvite (C→S): counts the client's invite prompt outcome (SocialConfig.Invite.Actions) or,
	owner R122, a co-play surface report (InviteConfig.Reports). Analytics only — nothing is
	granted, so a forged report can only add a count (allowlisted, clamped, rate-limited, capped).
]]
local function onInvite(player: Player, rawAction: unknown, rawRecipients: unknown)
	local surface = Validate.oneOf(rawAction, InviteConfig.Reports)
	if surface ~= nil then
		onSurfaceReport(player, surface)
		return
	end
	if not inviteLimiter:Allow(player) then
		return
	end
	local action = Validate.oneOf(rawAction, INVITE.Actions)
	if action == nil then
		return
	end
	track(player, `friends:invite:{action}`)
	if action == "sent" then
		local recipients = Validate.integer(rawRecipients, 1, INVITE.MaxRecipients)
		if recipients ~= nil then
			track(player, "friends:inviteTo", recipients)
		end
	end
end

-- ── Public API ──────────────────────────────────────────────────────────────────────────────

--[[ The player's Friend Boost percent right now (0 when off / none). ]]
function FriendService.percent(player: Player): number
	local boost = boosts[player]
	if boost == nil or not live().friendsOn then
		return 0
	end
	return boost.percent
end

--[[ Display names of the player's friends in this server (≤ Friends.MaxNames). ]]
function FriendService.friendNames(player: Player): { string }
	local boost = boosts[player]
	return if boost ~= nil then table.clone(boost.names) else {}
end

--[[
	The player's referral record for the admin panel (nil when not loaded).
	@return { by, paid, seen, lastRead? }
]]
function FriendService.referralStatus(player: Player): {
	by: number,
	paid: number,
	seen: number,
	lastRead: { at: number, pending: number, paid: number, ok: boolean }?,
}?
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return nil
	end
	return {
		by = profile.referral.by,
		paid = profile.referral.paid,
		seen = #profile.referral.seen,
		lastRead = queueReads[player],
	}
end

-- ── Admin ────────────────────────────────────────────────────────────────────────────────────

-- Registers the owner-panel commands (Server tab order 85+, Players tab order 85+).
local function registerAdmin()
	Lazy.registerAdmin({
		name = "FriendBoostToggle",
		tab = "Server",
		label = "Friend Boost On/Off",
		description = "Kill switch for the +cash per Roblox friend in the server (this server).",
		target = "None",
		args = { mode = { kind = "enum", values = { "on", "off" }, labels = { "ON", "OFF" }, label = "Mode" } },
		argOrder = { "mode" },
		cooldown = 2,
		audited = true,
		confirm = false,
		color = "blue",
		order = 85,
	}, function(ctx: any): (boolean, string)
		local on = ctx.args.mode == "on"
		ReplicatedStorage:SetAttribute(ATTR.FriendsEnabled, on)
		recomputeAll()
		return true, `Friend Boost: {if on then "ON" else "OFF"}`
	end)
	Lazy.registerAdmin({
		name = "FriendBoostPercent",
		tab = "Server",
		label = "Friend Boost %",
		description = `Cash percent per friend in the server (total capped at +{FRIENDS.MaxPercent}%).`,
		target = "None",
		args = {
			percent = {
				kind = "integer",
				min = FRIENDS.MinPercentPerFriend,
				max = FRIENDS.MaxPercentPerFriend,
				presets = { 5, 10, 15, 20, 25 },
				label = "Percent",
				format = "count",
				default = FRIENDS.PercentPerFriend,
			},
		},
		argOrder = { "percent" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "blue",
		order = 86,
	}, function(ctx: any): (boolean, string)
		local percent =
			math.clamp(math.floor(ctx.args.percent), FRIENDS.MinPercentPerFriend, FRIENDS.MaxPercentPerFriend)
		ReplicatedStorage:SetAttribute(ATTR.FriendPercent, percent)
		recomputeAll()
		return true, `Friend Boost: +{percent}% per friend (max +{FRIENDS.MaxPercent}%)`
	end)
	Lazy.registerAdmin({
		name = "FriendStatus",
		tab = "Server",
		label = "Friend Boost Status",
		description = "Friend pairs found on this server and every player's Friend Boost.",
		target = "None",
		args = {},
		cooldown = 1,
		audited = false,
		confirm = false,
		color = "blue",
		order = 87,
	}, function(_ctx: any): (boolean, string)
		local pairCount, friends = 0, 0
		for _, isFriend in pairCache do
			pairCount += 1
			if isFriend then
				friends += 1
			end
		end
		local parts: { string } = {}
		for player, boost in boosts do
			if boost.percent > 0 then
				table.insert(parts, `{player.Name} +{boost.percent}%`)
			end
		end
		local settings = live()
		return true,
			`{if settings.friendsOn then "ON" else "OFF"} · +{settings.friendPercent}%/friend · pairs {pairCount} (friends {friends}) · {if #parts
					> 0
				then table.concat(parts, ", ")
				else "no boosts"}`
	end)
	Lazy.registerAdmin({
		name = "ReferralStatus",
		tab = "Players",
		label = "Referral Status",
		description = "Who invited the player, inviter rewards received (n / 10) and the last queue read.",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = false,
		confirm = false,
		color = "blue",
		order = 85,
	}, function(ctx: any): (boolean, string)
		local player = if ctx.target ~= nil then ctx.target.player else nil
		local status = if player ~= nil then FriendService.referralStatus(player) else nil
		if player == nil or status == nil then
			return false, "Player not loaded"
		end
		local read = status.lastRead
		local readText = if read == nil
			then "queue not read this session"
			else `queue read {os.time() - read.at}s ago: {read.pending} pending, {read.paid} paid{if read.ok
				then ""
				else " (retry next join)"}`
		return true,
			`{player.Name}: invited by {if status.by > 0 then tostring(status.by) else "nobody"} · rewards {status.paid} / {REFERRAL.MaxPaid} · ledger {status.seen} · {readText}`
	end)
	Lazy.registerAdmin({
		name = "ReferralTest",
		tab = "Players",
		label = "Referral Test",
		description = "STUDIO: run the referral flow on the player (newcomer of the id / pay as inviter for the id / read their queue).",
		target = "Player",
		args = {
			mode = {
				kind = "enum",
				values = { "newcomer", "inviter", "consume" },
				labels = { "As newcomer", "Pay as inviter", "Read queue" },
				label = "Mode",
			},
			-- (not "userId": that key is reserved for the command's target player)
			otherId = { kind = "integer", min = 1, max = 2 ^ 53 - 1, label = "Other UserId", default = 1 },
		},
		argOrder = { "mode", "otherId" },
		cooldown = 1,
		audited = true,
		confirm = false,
		studioOnly = true,
		color = "blue",
		order = 86,
	}, function(ctx: any): (boolean, string)
		local player = if ctx.target ~= nil then ctx.target.player else nil
		local profile = if player ~= nil then PlayerDataService.getProfile(player) else nil
		if player == nil or profile == nil then
			return false, "Player not loaded"
		end
		local otherId = ctx.args.otherId
		if otherId == player.UserId then
			return false, "A player cannot refer themselves"
		end
		if ctx.args.mode == "newcomer" then
			if profile.referral.by ~= 0 then
				return false, "Already referred"
			end
			profile.referral.by = otherId
			RewardGrant.grant(
				player,
				REFERRAL.NewcomerReward,
				"referral",
				{ saveSoon = true, extraFields = { "referral" } }
			)
			deliver(otherId, player.UserId)
			return true, `{player.Name} rewarded as the newcomer of {otherId}; inviter paid or queued`
		elseif ctx.args.mode == "inviter" then
			local result = payInviter(player, otherId)
			return result == "paid", `pay {player.Name} for newcomer {otherId}: {result}`
		end
		task.spawn(consumeQueue, player)
		return true, `Reading {player.Name}'s referral queue (see Referral Status)`
	end)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────────────────────

--[[
	Init: the referral ProfileLoaded handler is wired here (not in Start) so no load can slip past
	it, even one that finishes before the feature services start.
]]
function FriendService.Init()
	PlayerDataService.ProfileLoaded:Connect(onLoaded)
end

--[[ Start: provider, signals, remote, admin commands, players already here. Idempotent. ]]
function FriendService.Start()
	if started then
		return
	end
	started = true
	-- A presence bonus: never part of offline earnings.
	ModifierSources.register("friendBoost", provider, { offline = false })
	Remotes.onServerEvent("FriendInvite", onInvite)
	Players.PlayerAdded:Connect(onJoin)
	Players.PlayerRemoving:Connect(onLeave)
	for _, player in Players:GetPlayers() do
		onJoin(player)
	end
	registerAdmin()
end

return FriendService
