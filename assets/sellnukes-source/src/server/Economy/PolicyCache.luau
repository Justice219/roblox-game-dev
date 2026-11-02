--!strict
--[[
	PolicyCache — per-player cache of Roblox's paid-random-item policy, failing closed.

	Purpose:
		Roblox requires that players whose region restricts paid random items (loot boxes bought
		with Robux or with Robux-bought currency) can't buy them. PolicyService:
		GetPolicyInfoForPlayerAsync(player) tells us (`ArePaidRandomItemsRestricted`), but it is a
		web call that can fail or be slow. This cache:
			- fetches once per player (pcall + `attempts` tries with 1 s, 2 s, ... backoff), in the
			  background on join, and caches the answer for the session;
			- FAILS CLOSED: until an answer arrives — and if every attempt fails, or the answer has
			  no boolean ArePaidRandomItemsRestricted — the player counts as RESTRICTED;
			- lets a failed lookup be retried later (after `retryCooldown` s), e.g. when the player
			  tries to open a crate;
			- `resolveAsync` waits (up to `timeout` s) for a lookup in flight, so a crate opened
			  right after joining gets the real answer instead of a spurious refusal;
			- fires `onChanged(key)` whenever a player's answer changes (PlayerDataService pushes a
			  new profile snapshot so the Shop locks/unlocks paid random items live).
		The fetcher, clock and waits are injected, so tests can drive failure, retry, timeout and
		caching without PolicyService. (Copied unchanged in behaviour from RoBeasts.)

	Connects to (SellNukes):
		PlayerDataService (owns the production instance, prefetches on join, exposes
		`isPaidRandomRestricted(player)` / `resolvePaidRandomAsync(player)` and puts
		`policy = { paidRandomRestricted, known }` in the client snapshot), MonetizationService
		(refuses Robux prompts of products flagged `paidRandom` in MonetizationConfig, e.g. the
		Secret Pack), later services that sell random items for Robux-bought gems (crates, eggs).

	Example:
		local cache = PolicyCache.new({ fetch = function(player)
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end })
		cache:prefetch(player)
		if cache:resolveAsync(player) then -- restricted (or unknown): refuse paid crates
		end
]]

export type State = "unknown" | "fetching" | "known" | "failed"

export type Options = {
	-- Returns the PolicyService info table for a key (may yield or throw).
	fetch: (key: any) -> unknown,
	attempts: number?, -- tries per lookup (default 3)
	retryCooldown: number?, -- seconds before a failed lookup may run again (default 30)
	timeout: number?, -- max seconds resolveAsync waits for a lookup in flight (default 10)
	backoff: number?, -- first retry delay in seconds, doubling (default 1)
	clock: (() -> number)?, -- monotonic seconds (default os.clock)
	onChanged: ((key: any) -> ())?,
}

type Entry = {
	state: State,
	restricted: boolean, -- the answer while "known"; true otherwise
	failedAt: number, -- clock() of the last failure
	waiters: { thread },
	override: boolean?, -- Studio test override
	generation: number, -- bumps on forget() so a late lookup for a departed key is dropped
}

type PolicyCacheData = {
	_fetch: (key: any) -> unknown,
	_attempts: number,
	_retryCooldown: number,
	_timeout: number,
	_backoff: number,
	_clock: () -> number,
	_onChanged: ((key: any) -> ())?,
	_entries: { [any]: Entry },
	_generation: number,
}

local PolicyCache = {}
PolicyCache.__index = PolicyCache

export type PolicyCache = typeof(setmetatable({} :: PolicyCacheData, PolicyCache))

--[[ Creates a cache (see Options). ]]
function PolicyCache.new(options: Options): PolicyCache
	local self: PolicyCacheData = {
		_fetch = options.fetch,
		_attempts = options.attempts or 3,
		_retryCooldown = options.retryCooldown or 30,
		_timeout = options.timeout or 10,
		_backoff = options.backoff or 1,
		_clock = options.clock or os.clock,
		_onChanged = options.onChanged,
		_entries = {},
		_generation = 0,
	}
	return setmetatable(self, PolicyCache)
end

--[[
	Reads the restriction out of an untrusted policy table. Anything but an explicit boolean is
	"cannot tell" → nil (callers treat that as restricted).
]]
function PolicyCache.readRestricted(info: unknown): boolean?
	if type(info) ~= "table" then
		return nil
	end
	local value = (info :: { [string]: unknown }).ArePaidRandomItemsRestricted
	if type(value) == "boolean" then
		return value
	end
	return nil
end

-- The entry of a key (created on first use).
local function entryOf(self: PolicyCache, key: any): Entry
	local entry = self._entries[key]
	if entry == nil then
		self._generation += 1
		local created: Entry = {
			state = "unknown",
			restricted = true,
			failedAt = -math.huge,
			waiters = {},
			generation = self._generation,
		}
		self._entries[key] = created
		return created
	end
	return entry
end

-- Wakes every thread waiting in resolveAsync for this entry.
local function wake(entry: Entry)
	local waiters = entry.waiters
	entry.waiters = {}
	for _, thread in waiters do
		if coroutine.status(thread) == "suspended" then
			task.spawn(thread)
		end
	end
end

-- Runs one lookup (attempts + backoff) for `key`; updates the entry and notifies.
local function runLookup(self: PolicyCache, key: any, entry: Entry)
	local generation = entry.generation
	local before = entry.restricted
	local answer: boolean? = nil
	local delay = self._backoff
	for attempt = 1, self._attempts do
		local ok, info = pcall(self._fetch, key)
		if ok then
			answer = PolicyCache.readRestricted(info)
			if answer ~= nil then
				break
			end
			warn("[PolicyCache] policy info has no ArePaidRandomItemsRestricted flag; treating as restricted")
			break -- a malformed answer will not improve by asking again right away
		end
		warn(`[PolicyCache] policy lookup failed ({attempt}/{self._attempts}): {info}`)
		if attempt < self._attempts then
			task.wait(delay)
			delay *= 2
		end
	end
	-- The key was forgotten (player left) while we were fetching: drop the result.
	if self._entries[key] ~= entry or entry.generation ~= generation then
		return
	end
	if answer ~= nil then
		entry.state = "known"
		entry.restricted = answer
	else
		entry.state = "failed"
		entry.restricted = true
		entry.failedAt = self._clock()
	end
	wake(entry)
	local onChanged = self._onChanged
	if onChanged ~= nil and (entry.restricted ~= before or answer ~= nil) then
		onChanged(key)
	end
end

--[[
	Starts a background lookup for `key` unless one is running, the answer is known, or the
	last failure is younger than retryCooldown. Never yields.
]]
function PolicyCache.prefetch(self: PolicyCache, key: any)
	local entry = entryOf(self, key)
	if entry.override ~= nil or entry.state == "fetching" or entry.state == "known" then
		return
	end
	if entry.state == "failed" and self._clock() - entry.failedAt < self._retryCooldown then
		return
	end
	entry.state = "fetching"
	task.spawn(runLookup, self, key, entry)
end

--[[ True unless the policy is KNOWN to allow paid random items (fail closed). Never yields. ]]
function PolicyCache.isRestricted(self: PolicyCache, key: any): boolean
	local entry = self._entries[key]
	if entry == nil then
		return true
	end
	if entry.override ~= nil then
		return entry.override
	end
	return entry.state ~= "known" or entry.restricted
end

--[[ True once PolicyService has answered for `key` (or a test override is set). ]]
function PolicyCache.isKnown(self: PolicyCache, key: any): boolean
	local entry = self._entries[key]
	return entry ~= nil and (entry.override ~= nil or entry.state == "known")
end

--[[
	The restriction for `key`, waiting up to `timeout` seconds for a lookup in flight (and
	starting one if none ran or the last one failed long enough ago). Yields.
	@return true if restricted OR still unknown when the wait ends (fail closed)
]]
function PolicyCache.resolveAsync(self: PolicyCache, key: any): boolean
	self:prefetch(key)
	local entry = entryOf(self, key)
	if entry.override == nil and entry.state == "fetching" then
		local thread = coroutine.running()
		table.insert(entry.waiters, thread)
		local timer = task.delay(self._timeout, function()
			local index = table.find(entry.waiters, thread)
			if index ~= nil then
				table.remove(entry.waiters, index)
				task.spawn(thread)
			end
		end)
		coroutine.yield()
		if coroutine.status(timer) == "suspended" then
			task.cancel(timer)
		end
	end
	return self:isRestricted(key)
end

--[[
	Test hook (Studio only by convention — PlayerDataService exposes it only in Studio): force a
	key's restriction (`nil` clears the override and returns to the real answer).
]]
function PolicyCache.setOverride(self: PolicyCache, key: any, restricted: boolean?)
	local entry = entryOf(self, key)
	entry.override = restricted
	wake(entry)
	local onChanged = self._onChanged
	if onChanged ~= nil then
		onChanged(key)
	end
end

--[[ Drops everything about a key (PlayerRemoving); a lookup still in flight is discarded. ]]
function PolicyCache.forget(self: PolicyCache, key: any)
	local entry = self._entries[key]
	if entry ~= nil then
		self._entries[key] = nil
		entry.generation = -1
		wake(entry)
	end
end

return PolicyCache
