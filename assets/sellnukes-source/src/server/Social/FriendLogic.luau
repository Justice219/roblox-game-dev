--!strict
--[[
	FriendLogic — the PURE rules of the R78 Friend Boost and referrals (spec §4; docs/social.md).
	No services, no yields, no DataStores: FriendService does the I/O and calls these, so Lune
	proves every rule (tests/social-logic.luau).

	Friend Boost
		Friendship is symmetric on Roblox, so ONE IsFriendsWithAsync answer is cached per unordered
		pair (`pairKey`). A player's boost = percent(friends present, perFriend, maxPercent): +10 %
		per Roblox friend in the same server, at most +50 % (`multiplier` = 1 + percent / 100).

	Referrals
		`referrerOf` reads Player:GetJoinData().ReferredByPlayerId (untrusted shape: a whole UserId
		that is not the player). `newcomerVerdict` decides whether a load may claim the newcomer
		reward: a brand-new profile, on a real join (never a New Player Mode swap / sandbox), with a
		saving session, referred by someone else, and not referred before.
		`payInviter` is the inviter-side ledger step: idempotent per newcomer UserId
		(referral.seen), capped at MaxPaid lifetime.
		Offline inviters get a DataStore queue record { v = 1, list = { { id, at } } }:
		`enqueue` (dedupe by newcomer id, capped, entries older than the max age dropped),
		`readQueue` (sanitised entries) and `dequeue` (removes the ids a commit made durable).

	Connects to: Shared/Config/SocialConfig (ReferralState, tunables), Server/Services/
	FriendService, tests/social-logic.luau.

	Example:
		FriendLogic.percent(3, 10, 50)                       --> 30
		FriendLogic.referrerOf({ ReferredByPlayerId = 42 }, 7) --> 42
		FriendLogic.payInviter(profile.referral, 7, 10, 32)   --> "paid" (then "seen" for 7 again)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)

type ReferralState = SocialConfig.ReferralState

-- One queued newcomer (DataStore record entry).
export type QueueEntry = { id: number, at: number }
-- The DataStore record of one inviter's queue.
export type QueueRecord = { v: number, list: { QueueEntry } }

-- newcomerVerdict answers ("ok" = grant the newcomer reward + reward / queue the inviter).
export type Verdict = "ok" | "none" | "self" | "notNew" | "swap" | "unsaved" | "already"

-- payInviter answers.
export type PayResult = "paid" | "seen" | "capped" | "invalid"

-- enqueue answers.
export type QueueStatus = "queued" | "duplicate" | "full"

local FriendLogic = {}

-- Largest whole Roblox UserId (2^53).
local MAX_USER_ID = 9_007_199_254_740_992
-- Record format version of the referral queue.
local QUEUE_VERSION = 1

-- A whole UserId in [1, 2^53], else nil.
local function userIdOf(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < 1 or value > MAX_USER_ID then
		return nil
	end
	return value
end

--[[
	The cache key of an unordered player pair ("small:large").
	Example: FriendLogic.pairKey(9, 3) --> "3:9"
]]
function FriendLogic.pairKey(a: number, b: number): string
	if a < b then
		return `{a}:{b}`
	end
	return `{b}:{a}`
end

--[[
	The Friend Boost percent for `count` friends present.
	@param count any — friends counted (non-numbers / NaN / negatives → 0, floored)
	@param perFriend number — percent per friend (SocialConfig.live().friendPercent)
	@param maxPercent number — the cap (SocialConfig.Friends.MaxPercent)
	@return whole percent in [0, maxPercent]
	Example: FriendLogic.percent(7, 10, 50) --> 50
]]
function FriendLogic.percent(count: unknown, perFriend: number, maxPercent: number): number
	if type(count) ~= "number" or count ~= count or count <= 0 or count == math.huge then
		return 0
	end
	if perFriend ~= perFriend or perFriend <= 0 or maxPercent ~= maxPercent or maxPercent <= 0 then
		return 0
	end
	return math.clamp(math.floor(math.floor(count) * perFriend), 0, math.floor(maxPercent))
end

--[[
	The `friendCash` modifier for a percent: 1 + percent / 100 (1 = neutral; garbage → 1).
	Example: FriendLogic.multiplier(20) --> 1.2
]]
function FriendLogic.multiplier(percent: unknown): number
	if type(percent) ~= "number" or percent ~= percent or percent <= 0 or percent == math.huge then
		return 1
	end
	return 1 + percent / 100
end

--[[
	The friends of `userId` among `present` according to the pair cache (unknown pairs = not yet).
	@param userId number
	@param present { number } — UserIds of the players in the server (may include userId)
	@param cache { [string]: boolean } — pairKey → friends?
	@return (count, friendIds in `present` order)
	Example: FriendLogic.friendsOf(1, { 1, 2, 3 }, { ["1:2"] = true, ["1:3"] = false }) --> 1, { 2 }
]]
function FriendLogic.friendsOf(userId: number, present: { number }, cache: { [string]: boolean }): (number, { number })
	local ids: { number } = {}
	for _, other in present do
		if other ~= userId and cache[FriendLogic.pairKey(userId, other)] == true then
			table.insert(ids, other)
		end
	end
	return #ids, ids
end

--[[
	The referrer named by a join's data (Player:GetJoinData()), or nil.
	@param joinData any — the untrusted join data table
	@param selfId number — the joining player's UserId (a self-referral is no referral)
	@return number? — the inviter's UserId
	Example: FriendLogic.referrerOf({ ReferredByPlayerId = 42 }, 7) --> 42
]]
function FriendLogic.referrerOf(joinData: unknown, selfId: number): number?
	if type(joinData) ~= "table" then
		return nil
	end
	local id = userIdOf((joinData :: { [string]: unknown }).ReferredByPlayerId)
	if id == nil or id == selfId then
		return nil
	end
	return id
end

--[[
	Whether a profile load may claim the newcomer referral reward.
	@param input {
		isNew: boolean      -- PlayerDataService ProfileLoaded isNew (nothing was stored)
		reason: string?     -- getLoadReason ("join" | "enterNewPlayerMode" | "exitNewPlayerMode")
		canMutate: boolean  -- a saving session (never an in-memory fallback)
		sandbox: boolean    -- New Player Mode (a throwaway profile)
		rawReferrer: any    -- GetJoinData().ReferredByPlayerId as received
		selfId: number
		by: number          -- profile.referral.by (0 = never referred)
	}
	@return Verdict, inviterId?
	Example: FriendLogic.newcomerVerdict({ isNew = true, reason = "join", canMutate = true,
		sandbox = false, rawReferrer = 42, selfId = 7, by = 0 }) --> "ok", 42
]]
function FriendLogic.newcomerVerdict(input: {
	isNew: boolean,
	reason: string?,
	canMutate: boolean,
	sandbox: boolean,
	rawReferrer: unknown,
	selfId: number,
	by: number,
}): (Verdict, number?)
	local raw = userIdOf(input.rawReferrer)
	if raw == nil then
		return "none", nil
	end
	if raw == input.selfId then
		return "self", nil
	end
	if input.sandbox or input.reason ~= "join" then
		return "swap", nil
	end
	if not input.isNew then
		return "notNew", nil
	end
	if not input.canMutate then
		return "unsaved", nil
	end
	if input.by ~= 0 then
		return "already", nil
	end
	return "ok", raw
end

--[[
	The inviter-side ledger step for one newcomer: idempotent per newcomer id, capped.
	"paid" mutates `referral` (paid += 1, the id appended to seen; seen keeps the newest maxSeen) —
	the caller grants SocialConfig.Referral.InviterReward in the SAME non-yielding step.
	@param referral ReferralState (the inviter's profile.referral; mutated on "paid")
	@param newcomerId any — the newcomer's UserId (untrusted when it came from a DataStore)
	@param maxPaid number, maxSeen number
	@return PayResult
	Example: FriendLogic.payInviter(referral, 7, 10, 32) --> "paid"; again --> "seen"
]]
function FriendLogic.payInviter(
	referral: ReferralState,
	newcomerId: unknown,
	maxPaid: number,
	maxSeen: number
): PayResult
	local id = userIdOf(newcomerId)
	if id == nil then
		return "invalid"
	end
	if table.find(referral.seen, id) ~= nil then
		return "seen"
	end
	if referral.paid >= maxPaid then
		return "capped"
	end
	referral.paid += 1
	table.insert(referral.seen, id)
	while #referral.seen > math.max(1, maxSeen) do
		table.remove(referral.seen, 1)
	end
	return "paid"
end

--[[
	Sanitises a stored queue record into its entries: whole newcomer ids (first entry per id
	wins), finite `at` not older than maxAgeSeconds (nor in the future), at most maxQueue.
	@param raw any — the DataStore value (untrusted)
	@param now number, maxAgeSeconds number, maxQueue number
	@return { QueueEntry }
	Example: FriendLogic.readQueue({ v = 1, list = { { id = 7, at = 990 } } }, 1000, 86400, 20)
		--> { { id = 7, at = 990 } }
]]
function FriendLogic.readQueue(raw: unknown, now: number, maxAgeSeconds: number, maxQueue: number): { QueueEntry }
	local out: { QueueEntry } = {}
	if type(raw) ~= "table" then
		return out
	end
	local list = (raw :: { [string]: unknown }).list
	if type(list) ~= "table" then
		return out
	end
	local seen: { [number]: boolean } = {}
	local entries = list :: { unknown }
	-- Bounded read: a corrupted record can never make this loop long.
	for index = 1, math.max(0, maxQueue) * 4 do
		local entry = entries[index]
		if entry == nil then
			break
		end
		if type(entry) == "table" then
			local fields = entry :: { [string]: unknown }
			local id = userIdOf(fields.id)
			local at = fields.at
			if
				id ~= nil
				and not seen[id]
				and type(at) == "number"
				and at == at
				and at <= now + 60 -- a little clock skew between servers is fine
				and now - at <= maxAgeSeconds
			then
				seen[id] = true
				table.insert(out, { id = id, at = math.floor(at) })
				if #out >= maxQueue then
					break
				end
			end
		end
	end
	return out
end

--[[
	The UpdateAsync transform of a newcomer joining while their inviter is elsewhere.
	@param raw any — the current record (nil = none yet)
	@param newcomerId number, now number, maxQueue number, maxAgeSeconds number
	@return (record?: the record to write — nil = cancel the write, status)
	Example: FriendLogic.enqueue(nil, 7, 1000, 20, 86400) --> { v = 1, list = { { id = 7, at = 1000 } } }, "queued"
]]
function FriendLogic.enqueue(
	raw: unknown,
	newcomerId: number,
	now: number,
	maxQueue: number,
	maxAgeSeconds: number
): (QueueRecord?, QueueStatus)
	local entries = FriendLogic.readQueue(raw, now, maxAgeSeconds, maxQueue)
	for _, entry in entries do
		if entry.id == newcomerId then
			return nil, "duplicate"
		end
	end
	if #entries >= maxQueue then
		return nil, "full"
	end
	table.insert(entries, { id = newcomerId, at = math.floor(now) })
	return { v = QUEUE_VERSION, list = entries }, "queued"
end

--[[
	The UpdateAsync transform that removes the newcomer ids an inviter's commit made durable.
	@param raw any — the current record (another server may have appended meanwhile: kept)
	@param ids { number } — ids to remove
	@return QueueRecord (possibly with an empty list)
	Example: FriendLogic.dequeue(record, { 7 }, now, 20, 86400).list --> entries without 7
]]
function FriendLogic.dequeue(
	raw: unknown,
	ids: { number },
	now: number,
	maxQueue: number,
	maxAgeSeconds: number
): QueueRecord
	local remove: { [number]: boolean } = {}
	for _, id in ids do
		remove[id] = true
	end
	local kept: { QueueEntry } = {}
	for _, entry in FriendLogic.readQueue(raw, now, maxAgeSeconds, maxQueue) do
		if not remove[entry.id] then
			table.insert(kept, entry)
		end
	end
	return { v = QUEUE_VERSION, list = kept }
end

--[[
	The UserIds a queue record is about (GDPR: DataStore key metadata, so an erasure request for
	the inviter or any queued newcomer finds the key).
	Example: FriendLogic.recordUserIds({ v = 1, list = { { id = 7, at = 1 } } }, 42) --> { 42, 7 }
]]
function FriendLogic.recordUserIds(record: QueueRecord, inviterId: number): { number }
	local ids = { inviterId }
	for _, entry in record.list do
		table.insert(ids, entry.id)
	end
	return ids
end

return table.freeze(FriendLogic)
