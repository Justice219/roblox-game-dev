--!strict
--[[
	BadgeAwardsQueue — bounded, cancellable Roblox badge work (ported from RoBeasts' queue and
	extended past ten badges: ownership is checked in batches of BadgeConfig.OwnershipBatch).

	Model:
		- `observe(userId, qualifiedMask)` coalesces everything known about a player into one state
		  (never yields; stat bursts cannot reset backoff).
		- `stepAsync()` performs AT MOST ONE platform call: an ownership batch (CheckUserBadgesAsync),
		  a metadata read (GetBadgeInfoAsync → IsEnabled, cached MetadataTTL incl. "disabled"), or an
		  award (AwardBadgeAsync). `nextDelay()` tells the service when work is due (nil = idle; the
		  service schedules no timer at all then).
		- Only an explicit `true` from AwardBadgeAsync or confirmed ownership sets an owned bit; a
		  false / failed award backs off exponentially and re-checks ownership (already-owned race).
		- Every result is discarded if the player left / their profile changed while yielding
		  (`isCurrent`). Zero ids are inert (never sent to Roblox).

	Dependencies are injected, so tests/event-badges.luau runs the real queue under Lune.

	Example:
		local queue = BadgeAwardsQueue.new({ 0, 123, 456 }, deps, BadgeConfig.Worker, 10)
		queue.observe(userId, 0b110)
		task.delay(queue.nextDelay() or 0, queue.stepAsync)
]]

local BadgeAwardsQueue = {}

export type Policy = {
	read OwnershipInterval: number,
	read AwardInterval: number,
	read MetadataTTL: number,
	read RetryBase: number,
	read RetryMaximum: number,
	read MinimumStep: number,
}

export type Dependencies = {
	now: () -> number,
	isCurrent: (userId: number) -> boolean,
	checkOwnedAsync: (userId: number, ids: { number }) -> { number },
	isEnabledAsync: (badgeId: number) -> boolean,
	awardAsync: (userId: number, badgeId: number) -> boolean,
	publish: (userId: number, ownedMask: number) -> (),
}

export type Queue = {
	observe: (userId: number, qualified: number) -> (),
	forget: (userId: number) -> (),
	stepAsync: () -> (),
	nextDelay: () -> number?,
	owned: (userId: number) -> number,
}

type State = {
	userId: number,
	qualified: number,
	owned: number,
	chunk: number, -- next ownership batch to check (> #chunks = all checked)
	ownershipAt: number,
	ownershipFailures: number,
	retryAt: { [number]: number },
	failures: { [number]: number },
}
type Metadata = { enabled: boolean, expires: number }
type Work = { state: State, kind: "ownership" | "metadata" | "award", index: number, at: number }

--[[
	Builds one server queue.
	@param definitions badge ids in catalog order (0 = not created; skipped)
	@param batch ids per ownership call (Roblox: 10)
]]
function BadgeAwardsQueue.new(definitions: { number }, deps: Dependencies, policy: Policy, batch: number): Queue
	assert(#definitions <= 32, "Badge catalog exceeds the 32-bit ownership mask")
	local states: { [number]: State } = {}
	local metadata: { [number]: Metadata } = {}
	local metadataFailures: { [number]: number } = {}
	local byId: { [number]: number } = {}
	local chunks: { { number } } = {}
	local ownershipAt, awardAt = 0, 0
	for index, id in definitions do
		if id > 0 and id < 2 ^ 53 and id % 1 == 0 then
			assert(byId[id] == nil, "Duplicate Roblox badge ID")
			byId[id] = index
			local last = chunks[#chunks]
			if last == nil or #last >= batch then
				last = {}
				table.insert(chunks, last)
			end
			table.insert(last, id)
		end
	end

	local function current(state: State): boolean
		return states[state.userId] == state and deps.isCurrent(state.userId)
	end

	local function retryDelay(failures: number): number
		return math.min(policy.RetryMaximum, policy.RetryBase * 2 ^ math.min(failures - 1, 10))
	end

	-- Publishes only confirmed positive ownership (never clears an owned bit).
	local function confirm(state: State, index: number)
		local bit = bit32.lshift(1, index - 1)
		if bit32.band(state.owned, bit) == 0 then
			state.owned = bit32.bor(state.owned, bit)
			deps.publish(state.userId, state.owned)
		end
	end

	-- The earliest eligible operation (bounded: players x catalog). nil = idle.
	local function nextWork(): Work?
		local best: Work? = nil
		local now = deps.now()
		for userId, state in states do
			if not current(state) then
				states[userId] = nil
				continue
			end
			if state.chunk <= #chunks then
				local at = math.max(state.ownershipAt, ownershipAt)
				if best == nil or at < best.at then
					local work: Work = { state = state, kind = "ownership", index = state.chunk, at = at }
					best = work
				end
				continue
			end
			for index, id in definitions do
				local bit = bit32.lshift(1, index - 1)
				if byId[id] == nil or bit32.band(state.qualified, bit) == 0 or bit32.band(state.owned, bit) ~= 0 then
					continue
				end
				local info = metadata[id]
				local at = state.retryAt[index] or 0
				local fresh = info ~= nil and info.expires > now
				local enabled = fresh and info ~= nil and info.enabled
				if enabled then
					at = math.max(at, awardAt)
				elseif fresh and info ~= nil then
					at = math.max(at, info.expires) -- disabled: wait for the metadata to expire
				end
				if best == nil or at < best.at then
					local work: Work = {
						state = state,
						kind = if enabled then "award" else "metadata",
						index = index,
						at = at,
					}
					best = work
				end
			end
		end
		return best
	end

	local queue = {} :: Queue

	function queue.observe(userId: number, qualified: number)
		local state = states[userId]
		if state == nil then
			states[userId] = {
				userId = userId,
				qualified = qualified,
				owned = 0,
				chunk = 1,
				ownershipAt = 0,
				ownershipFailures = 0,
				retryAt = {},
				failures = {},
			}
		else
			state.qualified = qualified
		end
	end

	function queue.forget(userId: number)
		states[userId] = nil
	end

	function queue.owned(userId: number): number
		local state = states[userId]
		return if state ~= nil then state.owned else 0
	end

	function queue.nextDelay(): number?
		local work = nextWork()
		return if work == nil then nil else math.max(policy.MinimumStep, work.at - deps.now())
	end

	function queue.stepAsync()
		local work = nextWork()
		if work == nil or work.at > deps.now() then
			return
		end
		local state = work.state
		if work.kind == "ownership" then
			ownershipAt = deps.now() + policy.OwnershipInterval
			local ids = chunks[work.index]
			local ok, owned = pcall(deps.checkOwnedAsync, state.userId, ids)
			if not current(state) then
				return
			end
			if ok and typeof(owned) == "table" then
				state.chunk = work.index + 1
				state.ownershipFailures = 0
				for _, id in owned :: { unknown } do
					local index = if type(id) == "number" then byId[id] else nil
					if index ~= nil then
						confirm(state, index)
					end
				end
			else
				state.ownershipFailures += 1
				state.ownershipAt = deps.now() + retryDelay(state.ownershipFailures)
			end
			return
		end
		local index = work.index
		local id = definitions[index]
		if work.kind == "metadata" then
			local ok, enabled = pcall(deps.isEnabledAsync, id)
			if not current(state) then
				return
			end
			if ok and typeof(enabled) == "boolean" then
				metadata[id] = { enabled = enabled, expires = deps.now() + policy.MetadataTTL }
				metadataFailures[id] = 0
			else
				metadataFailures[id] = (metadataFailures[id] or 0) + 1
				metadata[id] = { enabled = false, expires = deps.now() + retryDelay(metadataFailures[id]) }
			end
			return
		end
		awardAt = deps.now() + policy.AwardInterval
		local ok, awarded = pcall(deps.awardAsync, state.userId, id)
		if not current(state) then
			return
		end
		if ok and awarded == true then
			confirm(state, index)
			state.failures[index] = 0
		else
			state.failures[index] = (state.failures[index] or 0) + 1
			state.retryAt[index] = deps.now() + retryDelay(state.failures[index])
			-- A false result may be an already-owned race: re-check ownership (paced).
			state.chunk = 1
			state.ownershipAt = state.retryAt[index]
		end
	end

	return queue
end

return table.freeze(BadgeAwardsQueue)
