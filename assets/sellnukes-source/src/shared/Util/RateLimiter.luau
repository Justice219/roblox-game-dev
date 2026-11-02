--!strict
--[[
	RateLimiter — per-key token bucket.

	Purpose:
		Every RemoteEvent handler on the server rate-limits each player so an exploiter cannot spam
		producer clicks, pad buys, purchase prompts, etc. A token bucket allows short bursts (rapid
		clicking is a real part of a clicker tycoon) while capping the sustained rate.
		(Copied unchanged in behaviour from RoBeasts.)

	How it works:
		Each key (usually a Player) owns a bucket holding up to `capacity` tokens. Tokens refill at
		`refillPerSecond`. `Allow(key)` spends one token (or `cost`) if available.

	Pure logic: no Roblox APIs except the injectable clock, so it is unit-tested with Lune
	(tests/validate.luau covers burst, refill and Forget).

	Example:
		local limiter = RateLimiter.new(10, 5) -- burst of 10, 5/s sustained
		Remote.OnServerEvent:Connect(function(player, ...)
			if not limiter:Allow(player) then return end
			...
		end)
		Players.PlayerRemoving:Connect(function(player) limiter:Forget(player) end)
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type Bucket = {
	tokens: number,
	lastRefill: number,
}

type RateLimiterData = {
	_capacity: number,
	_refillPerSecond: number,
	_buckets: { [any]: Bucket? },
	_clock: () -> number,
}

export type RateLimiter = typeof(setmetatable({} :: RateLimiterData, RateLimiter))

--[[
	@param capacity        Max burst size (tokens), must be > 0.
	@param refillPerSecond Tokens restored per second, must be > 0.
	@param clock           Optional time source (seconds). Defaults to os.clock. Injected by tests.
]]
function RateLimiter.new(capacity: number, refillPerSecond: number, clock: (() -> number)?): RateLimiter
	if capacity <= 0 or refillPerSecond <= 0 then
		error("RateLimiter.new: capacity and refillPerSecond must be positive")
	end
	local self: RateLimiterData = {
		_capacity = capacity,
		_refillPerSecond = refillPerSecond,
		_buckets = {},
		_clock = clock or os.clock,
	}
	return setmetatable(self, RateLimiter)
end

--[[
	Spends `cost` tokens (default 1) from `key`'s bucket.
	@return true if allowed, false if the key is over its rate.
]]
function RateLimiter.Allow(self: RateLimiter, key: any, cost: number?): boolean
	local spend = cost or 1
	local now = self._clock()
	local bucket = self._buckets[key]
	if bucket == nil then
		bucket = { tokens = self._capacity, lastRefill = now }
		self._buckets[key] = bucket
	end
	assert(bucket ~= nil, "bucket exists")

	-- Refill proportionally to elapsed time, capped at capacity.
	local elapsed = math.max(0, now - bucket.lastRefill)
	bucket.tokens = math.min(self._capacity, bucket.tokens + elapsed * self._refillPerSecond)
	bucket.lastRefill = now

	if bucket.tokens >= spend then
		bucket.tokens -= spend
		return true
	end
	return false
end

--[[ Drops all state for a key (call on PlayerRemoving to avoid leaking buckets). ]]
function RateLimiter.Forget(self: RateLimiter, key: any)
	self._buckets[key] = nil
end

return RateLimiter
