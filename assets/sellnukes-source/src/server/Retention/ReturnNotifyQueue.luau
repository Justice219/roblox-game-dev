--!strict
--[[
	ReturnNotifyQueue — the MemoryStore SortedMap due queue of the return notifications (owner
	R122 §2.3; map NotifyConfig.Queue.MapName, key = userId, sort key = due unix time, value =
	ReturnNotifyLogic Entry / Marker, expiration <= 2 days).

	Every write is an UpdateAsync running a PURE ReturnNotifyLogic transform, so concurrent
	servers stay correct: a plan never overwrites an in-flight send, a join cancels a pending
	entry, exactly one server's claim wins, only the claimer may finish. The expiration of a write
	is computed from the value the transform is expected to produce (from the item the poll just
	read, the claimed entry this server holds, or one GetAsync for a join), so markers do not
	linger and entries live exactly through their late window.

	Every call is pcall'd and returns ok = false on any MemoryStore error (quota, outage, Studio
	without API access); callers count / back off, nothing throws. Values read back are decoded
	strictly (ReturnNotifyLogic.decode) and size-checked; keys are parsed as user ids.

	Request units (MemoryStore quota 1000 + 120 × CCU per minute, per universe): plan 1, join 2
	(GetAsync + UpdateAsync), due read = items returned (min 1), claim 1, finish 1, size 1.

	Connects to: Server/Retention/ReturnNotifyLogic (transforms + expiration), Shared/Config/
	NotifyConfig (Queue). Used by ReturnNotifyRunner / ReturnNotifyService / ReturnNotifyAdmin.
	Tests drive it with a fake SortedMap that simulates UpdateAsync conflicts
	(tests/return-notify.luau).

	Example:
		local queue = ReturnNotifyQueue.new(MemoryStoreService:GetSortedMap(NotifyConfig.Queue.MapName))
		local ok, outcome = queue.plan(facts, control, os.time())
		if ok and outcome.result == "planned" then print(outcome.plan.kind) end
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NotifyConfig = require(ReplicatedStorage.Shared.Config.NotifyConfig)
local ReturnNotifyLogic = require(script.Parent.ReturnNotifyLogic)

type Facts = ReturnNotifyLogic.Facts
type Control = ReturnNotifyLogic.Control
type Kinds = ReturnNotifyLogic.Kinds

export type DueItem = { key: string, userId: number, value: any }

export type Queue = {
	plan: (facts: Facts, control: Control, now: number) -> (boolean, ReturnNotifyLogic.PlanOutcome?),
	join: (userId: number, joinAt: number, now: number) -> (boolean, ReturnNotifyLogic.JoinOutcome?),
	due: (now: number, count: number) -> (boolean, { DueItem }),
	claim: (item: DueItem, now: number, token: string, control: Control) -> (boolean, ReturnNotifyLogic.ClaimOutcome?),
	finish: (
		userId: number,
		entry: ReturnNotifyLogic.Entry,
		token: string,
		verdict: ReturnNotifyLogic.FinishVerdict,
		now: number
	) -> (boolean, ReturnNotifyLogic.FinishOutcome?),
	put: (userId: number, entry: ReturnNotifyLogic.Entry, now: number) -> boolean,
	size: () -> number?,
	dueCount: (now: number, max: number) -> number?,
	lastError: () -> string?,
}

local Queue = NotifyConfig.Queue
local HOUR = 3600

local ReturnNotifyQueue = {}

-- True when a value read back is small enough to be ours (defensive bound on stored JSON).
local function sizeOk(value: unknown): boolean
	if type(value) ~= "table" then
		return value == nil
	end
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
	return ok and type(encoded) == "string" and #encoded <= Queue.MaxValueBytes
end

-- A short error text for the admin status (never a secret: MemoryStore errors only). A leading
-- "<script path>:<line>: " is dropped so the 80 characters carry the actual reason.
local function shortError(err: unknown): string
	local text = string.gsub(tostring(err), "^.-:%d+: ", "")
	return string.sub(text, 1, 80)
end

--[[
	Wraps a SortedMap (or a test double with the same four methods).
	@param map any — MemoryStoreSortedMap (GetAsync / GetRangeAsync / UpdateAsync / SetAsync /
	                  GetSizeAsync)
	@param kinds Kinds? — kind table (tests pass message ids; defaults to NotifyConfig.Kinds)
	@return Queue
]]
function ReturnNotifyQueue.new(map: any, kinds: Kinds?): Queue
	local lastErr: string? = nil

	-- One UpdateAsync with a pure transform; returns (ok, outcome of the LAST transform run).
	local function update<O>(key: string, transform: (old: any) -> (any, any, O), expiration: number): (boolean, O?)
		local outcome: O? = nil
		local ok, err = pcall(function()
			map:UpdateAsync(key, function(old: any, _oldSortKey: any): (any, any)
				if not sizeOk(old) then
					old = nil -- oversized / foreign value: treated as absent (overwritten)
				end
				local value, sortKey, result = transform(old)
				outcome = result
				if value == nil then
					return nil
				end
				return value, sortKey
			end, expiration)
		end)
		if not ok then
			lastErr = shortError(err)
			return false, nil
		end
		return true, outcome
	end

	local queue = {} :: Queue

	--[[
		Plans a leaving player's notification (ReturnNotifyLogic.planTransform). The expiration
		covers the plan's late window even if the send gap moves it up to SendGapHours later.
	]]
	function queue.plan(facts: Facts, control: Control, now: number): (boolean, ReturnNotifyLogic.PlanOutcome?)
		local key = ReturnNotifyLogic.keyOf(facts.userId)
		if key == nil then
			return false, nil
		end
		local preview = ReturnNotifyLogic.plan(facts, control, nil, now, kinds)
		if preview == nil then
			return true, { result = "none" } -- nothing applies: no write at all
		end
		local def = (kinds or NotifyConfig.Kinds)[preview.kind]
		local late = if def ~= nil then def.maxLateHours * HOUR else 0
		local latestDue = math.max(preview.due, now + Queue.SendGapHours * HOUR)
		local expiration =
			math.clamp(math.ceil(latestDue + late + Queue.LeaseSeconds - now), 60, Queue.MaxExpirationSeconds)
		return update(key, function(old: any)
			return ReturnNotifyLogic.planTransform(old, facts, control, now, kinds)
		end, expiration)
	end

	--[[
		A player joined: cancels their pending entry and leaves a "join" marker (GetAsync first,
		so the marker's expiration keeps an earlier send time through the send gap).
	]]
	function queue.join(userId: number, joinAt: number, now: number): (boolean, ReturnNotifyLogic.JoinOutcome?)
		local key = ReturnNotifyLogic.keyOf(userId)
		if key == nil then
			return false, nil
		end
		local okGet, current = pcall(function(): any
			return map:GetAsync(key)
		end)
		if not okGet then
			lastErr = shortError(current)
			current = nil
		end
		local predicted = ReturnNotifyLogic.joinTransform(if sizeOk(current) then current else nil, joinAt, now)
		local expiration = if predicted ~= nil
			then ReturnNotifyLogic.expiration(predicted, now, kinds)
			else math.clamp(Queue.SendGapHours * HOUR, 60, Queue.MaxExpirationSeconds)
		if not okGet then
			-- Unknown old value: keep a possible send time through the whole gap.
			expiration = math.clamp(Queue.SendGapHours * HOUR, 60, Queue.MaxExpirationSeconds)
		end
		return update(key, function(old: any)
			return ReturnNotifyLogic.joinTransform(old, joinAt, now)
		end, expiration)
	end

	--[[
		Up to `count` entries due at or before `now` (numeric sort keys only; markers sort after).
		The bound is exclusive, so it is the next whole second.
		@return (ok, items) — items with an unparseable key are skipped
	]]
	function queue.due(now: number, count: number): (boolean, { DueItem })
		local okRead, items = pcall(function(): any
			return map:GetRangeAsync(Enum.SortDirection.Ascending, math.clamp(math.floor(count), 1, 200), nil, {
				sortKey = math.floor(now) + 1,
			})
		end)
		if not okRead then
			lastErr = shortError(items)
			return false, {}
		end
		local out: { DueItem } = {}
		if type(items) ~= "table" then
			return true, out
		end
		for _, item in items :: { any } do
			if type(item) == "table" then
				local userId = ReturnNotifyLogic.userIdOf(item.key)
				if userId ~= nil and sizeOk(item.value) then
					table.insert(out, { key = item.key, userId = userId, value = item.value })
				end
			end
		end
		return true, out
	end

	--[[ Claims one due item (ReturnNotifyLogic.claimTransform; exactly one server wins). ]]
	function queue.claim(
		item: DueItem,
		now: number,
		token: string,
		control: Control
	): (boolean, ReturnNotifyLogic.ClaimOutcome?)
		local predicted = ReturnNotifyLogic.claimTransform(item.value, now, token, control, kinds)
		local expiration = if predicted ~= nil then ReturnNotifyLogic.expiration(predicted, now, kinds) else 60
		return update(item.key, function(old: any)
			return ReturnNotifyLogic.claimTransform(old, now, token, control, kinds)
		end, expiration)
	end

	--[[ Finishes a claimed entry (only while this server's token still holds it). ]]
	function queue.finish(
		userId: number,
		entry: ReturnNotifyLogic.Entry,
		token: string,
		verdict: ReturnNotifyLogic.FinishVerdict,
		now: number
	): (boolean, ReturnNotifyLogic.FinishOutcome?)
		local key = ReturnNotifyLogic.keyOf(userId)
		if key == nil then
			return false, nil
		end
		local predicted = ReturnNotifyLogic.finishTransform(entry, token, verdict, now, kinds)
		local expiration = if predicted ~= nil then ReturnNotifyLogic.expiration(predicted, now, kinds) else 60
		return update(key, function(old: any)
			return ReturnNotifyLogic.finishTransform(old, token, verdict, now, kinds)
		end, expiration)
	end

	--[[ Admin test only: writes an entry directly (SetAsync; replaces whatever is there). ]]
	function queue.put(userId: number, entry: ReturnNotifyLogic.Entry, now: number): boolean
		local key = ReturnNotifyLogic.keyOf(userId)
		if key == nil then
			return false
		end
		local ok, err = pcall(function()
			map:SetAsync(key, entry, ReturnNotifyLogic.expiration(entry, now, kinds), entry.d)
		end)
		if not ok then
			lastErr = shortError(err)
		end
		return ok
	end

	--[[ Items in the map (pending entries + markers), or nil on error. ]]
	function queue.size(): number?
		local ok, size = pcall(function(): any
			return map:GetSizeAsync()
		end)
		if not ok or type(size) ~= "number" then
			lastErr = if ok then "bad size" else shortError(size)
			return nil
		end
		return size
	end

	--[[ Entries due before `now`, counted up to `max` (admin status), or nil on error. ]]
	function queue.dueCount(now: number, max: number): number?
		local ok, items = queue.due(now, max)
		return if ok then #items else nil
	end

	--[[ The last MemoryStore error text (admin status), or nil. ]]
	function queue.lastError(): string?
		return lastErr
	end

	return queue
end

return ReturnNotifyQueue
