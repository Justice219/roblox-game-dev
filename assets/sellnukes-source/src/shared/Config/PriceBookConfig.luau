--!strict
--[[
	PriceBookConfig — tunables for the client's live Robux price lookup (Client/UI/PriceBook).

	Why it exists: every pass and developer product uses Roblox MANAGED PRICING (Creator
	Dashboard, 2026-10-30), so the price Roblox charges can differ from MonetizationConfig.price
	(and per player / region). The client asks MarketplaceService:GetProductInfoAsync for the
	real price and shows that; these numbers bound how often and how hard it asks.

	Rate budget: Roblox throttles GetProductInfoAsync per client (on the order of 100 calls per
	minute). One full sweep is 35 calls (11 passes + 24 products), so the defaults below keep a
	sweep plus every retry well inside that: at most MaxRequestsPerMinute starts in any rolling
	60 s window, at most Concurrency in flight (concurrent calls are transparently batched by the
	engine), one sweep every RefreshSeconds (± RefreshJitter so 8 clients never align).

	Retries: a failed call waits BackoffBaseSeconds × BackoffFactor^(attempt-1), capped at
	BackoffMaxSeconds, scaled by a random factor in [1 - BackoffJitter, 1] (decorrelates clients),
	for up to MaxAttempts calls per item per sweep. After the last failure the item shows its
	MonetizationConfig price as a fallback until the next sweep fetches it.

	Connects to: Client/UI/PriceBook (only reader), tests/price-book.luau.

	Example:
		local interval = PriceBookConfig.RefreshSeconds --> 600
]]

local PriceBookConfig = {
	-- Seconds between full price sweeps after the first one (owner: "refreshed every ~10 min").
	RefreshSeconds = 600,
	-- ± fraction of RefreshSeconds added at random to each wait (0.1 → 540..660 s).
	RefreshJitter = 0.1,
	-- Max GetProductInfoAsync calls in flight at once. The engine batches concurrent calls, so 8
	-- workers price all 35 items in ~1 s (Studio: 4 workers took 2.9 s) without more requests.
	Concurrency = 8,
	-- Max call STARTS in any rolling 60 s window (well under Roblox's per-client throttle).
	MaxRequestsPerMinute = 60,
	-- Calls per item per sweep before falling back to the configured price.
	MaxAttempts = 5,
	-- Exponential backoff between attempts: base × factor^(attempt-1), capped.
	BackoffBaseSeconds = 2,
	BackoffFactor = 2,
	BackoffMaxSeconds = 60,
	-- Random shrink of each backoff wait (0.5 → wait in [50%, 100%] of the computed delay).
	BackoffJitter = 0.5,
	-- A PriceInRobux at or above this is treated as garbage (never shown).
	MaxSanePrice = 1_000_000,
	-- Shown while no price is known yet (fonts lack U+2026, so three dots like the kit's tags).
	UnknownText = "...",
}

return table.freeze(PriceBookConfig)
