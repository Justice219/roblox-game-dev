--!strict
--[[
	PriceBook regressions (src/client/UI/PriceBook.luau). Run:
		lune run tests/price-book

	Loads the shipped module through RobloxLoader with a MOCK MarketplaceService and drives every
	book on a VIRTUAL clock: sleep() parks the calling coroutine until the scheduler advances to
	its wake time, and the mock's GetProductInfoAsync "takes" 0.2 virtual seconds. Nothing waits on
	real time, so backoff and refresh behaviour is exact and the suite runs in milliseconds.

	Proves:
	  1. Catalogue: every MonetizationConfig pass + product is priced, keys are unique across
	     both groups, passes ask with InfoType.GamePass and products with InfoType.Product.
	  2. Before any answer: get → nil, text → "...", status "pending"; unknown keys "unknown";
	     unpublished ids (0) are never fetched ("unconfigured").
	  3. A sweep prices every item, Changed fires once per item, at most Concurrency calls are in
	     flight (and the cap is reached: calls overlap so the engine can batch them).
	  4. Retry: failed calls back off exponentially with jitter (base × factor^(n-1), shrunk by at
	     most BackoffJitter), then succeed.
	  5. Fallback: an item failing all MaxAttempts calls shows its MonetizationConfig price, and
	     uses exactly MaxAttempts calls.
	  6. Refresh: the next sweep starts after RefreshSeconds ± RefreshJitter; a changed price
	     fires Changed, an unchanged one does not; a later sweep that fails keeps the last LIVE
	     price (stale-but-real beats the config).
	  7. Junk / off-sale answers (IsForSale false, NaN, negative, huge, strings, non-tables) never
	     show a number; non-table answers count as failures and are retried.
	  8. Rate budget: no rolling 60 s window ever holds more than MaxRequestsPerMinute starts.
	  9. stop() ends the refresh loop: no calls after it.
	 10. format(): commas, "..." for nil / 0.
]]

local Loader = require("./fixtures/RobloxLoader")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- ── Virtual scheduler ────────────────────────────────────────────────────────────────────────

type Sleeper = { at: number, seq: number, thread: thread }

local clock = 0
local seq = 0
local sleepers: { Sleeper } = {}

local function resume(thread: thread)
	local ok, err = coroutine.resume(thread)
	if not ok then
		error(`coroutine failed: {err}`, 0)
	end
end

local function vsleep(seconds: number)
	seq += 1
	table.insert(sleepers, { at = clock + math.max(0, seconds), seq = seq, thread = coroutine.running() })
	coroutine.yield()
end

local function vspawn(fn: () -> ())
	resume(coroutine.create(fn))
end

-- Advances virtual time to `untilTime`, waking sleepers in (time, arrival) order.
local function runUntil(untilTime: number)
	while true do
		local bestIndex: number? = nil
		for index, sleeper in sleepers do
			local best = if bestIndex ~= nil then sleepers[bestIndex] else nil
			if
				sleeper.at <= untilTime
				and (best == nil or sleeper.at < best.at or (sleeper.at == best.at and sleeper.seq < best.seq))
			then
				bestIndex = index
			end
		end
		if bestIndex == nil then
			break
		end
		local sleeper = table.remove(sleepers, bestIndex) :: Sleeper
		clock = math.max(clock, sleeper.at)
		resume(sleeper.thread)
	end
	clock = math.max(clock, untilTime)
end

local function resetScheduler()
	clock, seq = 0, 0
	table.clear(sleepers)
end

-- Deterministic "random": a fixed sequence (cycled).
local randomValues = { 0.25, 0.9, 0.5, 0.0, 0.75 }
local randomIndex = 0
local function vrandom(): number
	randomIndex = randomIndex % #randomValues + 1
	return randomValues[randomIndex]
end

-- ── Mock MarketplaceService ──────────────────────────────────────────────────────────────────

type Call = { id: number, infoType: any, at: number }

local mock = {
	calls = {} :: { Call },
	inFlight = 0,
	maxInFlight = 0,
	-- id → function(callNumberForId) → result | error(...)
	behaviour = {} :: { [number]: (n: number) -> any },
	callsById = {} :: { [number]: number },
	latency = 0.2,
}

function mock.GetProductInfoAsync(_self: any, id: number, infoType: any): any
	table.insert(mock.calls, { id = id, infoType = infoType, at = clock })
	mock.callsById[id] = (mock.callsById[id] or 0) + 1
	mock.inFlight += 1
	mock.maxInFlight = math.max(mock.maxInFlight, mock.inFlight)
	vsleep(mock.latency)
	mock.inFlight -= 1
	local fn = mock.behaviour[id]
	if fn == nil then
		error("HTTP 500 (mock: no behaviour)")
	end
	return fn(mock.callsById[id])
end

local function resetMock()
	table.clear(mock.calls)
	table.clear(mock.behaviour)
	table.clear(mock.callsById)
	mock.inFlight, mock.maxInFlight = 0, 0
end

local function priced(price: number): (n: number) -> any
	return function(_n: number): any
		return { Name = "x", PriceInRobux = price, IsForSale = true }
	end
end

-- ── Load the shipped module ──────────────────────────────────────────────────────────────────

local loader = Loader.new({ MarketplaceService = mock })
local PriceBook = loader.load("src/client/UI/PriceBook")
local PriceBookConfig = loader.load("src/shared/Config/PriceBookConfig")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")

local function newBook(config: any?, catalogue: any?): any
	return PriceBook.new({
		marketplace = mock,
		sleep = vsleep,
		spawn = vspawn,
		now = function(): number
			return clock
		end,
		random = vrandom,
		config = config,
		catalogue = catalogue,
	})
end

-- Config copy with overrides (the real one is frozen).
local function configWith(overrides: { [string]: any }): any
	local copy = table.clone(PriceBookConfig)
	for key, value in overrides do
		copy[key] = value
	end
	return copy
end

-- ── 1. Catalogue ─────────────────────────────────────────────────────────────────────────────

local catalogue = PriceBook.catalogue()
local passCount, productCount = 0, 0
local seenKeys: { [string]: boolean } = {}
for _, item in catalogue do
	check(not seenKeys[item.key], `catalogue key {item.key} is unique across passes + products`)
	seenKeys[item.key] = true
	if item.isPass then
		passCount += 1
		check(MonetizationConfig.Passes[item.key].id == item.id, `{item.key} pass id`)
		check(MonetizationConfig.Passes[item.key].price == item.fallback, `{item.key} pass fallback`)
	else
		productCount += 1
		check(MonetizationConfig.Products[item.key].id == item.id, `{item.key} product id`)
		check(MonetizationConfig.Products[item.key].price == item.fallback, `{item.key} product fallback`)
	end
end
local expectedPasses, expectedProducts = 0, 0
for _ in MonetizationConfig.Passes do
	expectedPasses += 1
end
for _ in MonetizationConfig.Products do
	expectedProducts += 1
end
check(passCount == expectedPasses and productCount == expectedProducts, "every pass + product is in the catalogue")

-- ── 2–3. Pending state, then one full sweep of the real catalogue ────────────────────────────

resetScheduler()
resetMock()
for _, item in catalogue do
	mock.behaviour[item.id] = priced(item.fallback + 1) -- managed pricing moved every price by 1
end
local book = newBook()
check(book.status("VIP") == "pending", "VIP pending before any answer")
check(book.status("NotAKey") == "unknown", "unknown key status")
check(book.get("NotAKey") == nil, "unknown key price nil")
local fired: { [string]: number } = {}
local firedCount = 0
book.Changed:Connect(function(key: string, price: number?)
	fired[key] = price :: number
	firedCount += 1
end)
check(book.get("VIP") == nil, "VIP nil before any answer (get starts the sweep)")
check(book.text("VIP") == "...", 'VIP text "..." before any answer')
check(mock.inFlight == PriceBookConfig.Concurrency, "first sweep started by get() with Concurrency calls in flight")
runUntil(30)
check(not book.isSweeping(), "sweep finished")
for _, item in catalogue do
	check(book.get(item.key) == item.fallback + 1, `{item.key} shows the live price`)
	check(book.status(item.key) == "live", `{item.key} live`)
	check(fired[item.key] == item.fallback + 1, `{item.key} Changed fired with the live price`)
end
check(firedCount == #catalogue, "Changed fired exactly once per item")
check(mock.maxInFlight == PriceBookConfig.Concurrency, "concurrency cap reached and never exceeded")
check(#mock.calls == #catalogue, "one call per item")
for _, call in mock.calls do
	local isPass = false
	for _, item in catalogue do
		if item.id == call.id then
			isPass = item.isPass
		end
	end
	local expected = if isPass then "GamePass" else "Product"
	check(call.infoType ~= nil and call.infoType.Name == expected, `call {call.id} uses InfoType.{expected}`)
end
check(book.text("VIP") == PriceBook.format(MonetizationConfig.Passes.VIP.price + 1), "text() formats the live price")

-- 6. Refresh after RefreshSeconds ± jitter: one changed price fires, unchanged ones do not.
local vipId = MonetizationConfig.Passes.VIP.id
mock.behaviour[vipId] = priced(999)
firedCount = 0
table.clear(mock.calls)
local lo = PriceBookConfig.RefreshSeconds * (1 - PriceBookConfig.RefreshJitter)
runUntil(lo - 1)
check(#mock.calls == 0, "no refresh before RefreshSeconds × (1 - jitter)")
runUntil(PriceBookConfig.RefreshSeconds * (1 + PriceBookConfig.RefreshJitter) + 60)
check(#mock.calls == #catalogue, "second sweep re-fetched every item")
check(book.get("VIP") == 999, "refreshed VIP price")
check(firedCount == 1 and fired.VIP == 999, "only the changed price fired Changed")

-- 6b. A later sweep that fails everywhere keeps the last LIVE prices.
table.clear(mock.behaviour) -- every call now errors
firedCount = 0
check(book.refresh() == true, "manual refresh starts a sweep")
check(book.refresh() == false, "a second refresh while sweeping is refused (no overlap)")
runUntil(clock + 400)
check(book.get("VIP") == 999 and book.status("VIP") == "live", "failed refresh keeps the last live price")
check(firedCount == 0, "failed refresh changes nothing on screen")

-- 9. stop(): no calls after it.
book.stop()
table.clear(mock.calls)
runUntil(clock + 5000)
check(#mock.calls == 0, "stop() ends the refresh loop")

-- ── 4–5. Retry with backoff, then fallback ───────────────────────────────────────────────────

resetScheduler()
resetMock()
local retryCatalogue = {
	{ key = "Flaky", id = 101, isPass = false, fallback = 49 },
	{ key = "Dead", id = 102, isPass = true, fallback = 199 },
	{ key = "Unpublished", id = 0, isPass = false, fallback = 25 },
}
mock.behaviour[101] = function(n: number): any
	if n <= 2 then
		error("HTTP 429 (mock: throttled)")
	end
	return { PriceInRobux = 59, IsForSale = true }
end
-- 102 has no behaviour: every call errors.
local retryBook = newBook(nil, retryCatalogue)
check(retryBook.status("Unpublished") == "unconfigured", "id 0 is unconfigured")
local fallbackFired: number? = nil
retryBook.Changed:Connect(function(key: string, price: number?)
	if key == "Dead" then
		fallbackFired = price
	end
end)
retryBook.start()
runUntil(300)
check(retryBook.get("Flaky") == 59, "flaky item priced after two failures")
check(mock.callsById[101] == 3, "flaky item: exactly 3 calls")
-- The gaps between the flaky item's call starts are the backoff waits (+ the call latency).
local flakyStarts: { number } = {}
for _, call in mock.calls do
	if call.id == 101 then
		table.insert(flakyStarts, call.at)
	end
end
local cfg = PriceBookConfig
for attempt = 1, 2 do
	local gap = flakyStarts[attempt + 1] - flakyStarts[attempt] - mock.latency
	local nominal = math.min(cfg.BackoffMaxSeconds, cfg.BackoffBaseSeconds * cfg.BackoffFactor ^ (attempt - 1))
	check(
		gap >= nominal * (1 - cfg.BackoffJitter) - 1e-9 and gap <= nominal + 1e-9,
		`backoff {attempt}: {gap}s within [{nominal * (1 - cfg.BackoffJitter)}, {nominal}]`
	)
end
check(mock.callsById[102] == cfg.MaxAttempts, "dead item: exactly MaxAttempts calls")
check(retryBook.status("Dead") == "fallback", "dead item falls back")
check(retryBook.get("Dead") == 199, "fallback shows the MonetizationConfig price")
check(fallbackFired == 199, "fallback fired Changed")
check(mock.callsById[0] == nil, "unpublished id never fetched")
check(retryBook.get("Unpublished") == nil, "unpublished shows ...")
local stats = retryBook.stats()
check(stats.sweeps == 1 and stats.live == 1 and stats.fallback == 1, "stats count the sweep / live / fallback")
check(stats.requests == 3 + cfg.MaxAttempts and stats.failures == 2 + cfg.MaxAttempts, "stats count calls / failures")
-- The fallback item recovers on the next sweep.
mock.behaviour[102] = priced(149)
check(retryBook.refresh(), "manual refresh")
runUntil(clock + 10)
check(retryBook.get("Dead") == 149 and fallbackFired == 149, "fallback item goes live on a later sweep")
retryBook.stop()

-- ── 7. Junk / off-sale answers ───────────────────────────────────────────────────────────────

resetScheduler()
resetMock()
local junk: { [number]: any } = {
	[201] = { PriceInRobux = 99, IsForSale = false },
	[202] = { PriceInRobux = 0 / 0 },
	[203] = { PriceInRobux = -5 },
	[204] = { PriceInRobux = 1e12 },
	[205] = { PriceInRobux = "99" },
	[206] = {},
	[207] = { PriceInRobux = 79.6, IsForSale = true },
}
local junkCatalogue = {}
for id, answer in junk do
	table.insert(junkCatalogue, { key = `J{id}`, id = id, isPass = false, fallback = 10 })
	mock.behaviour[id] = function(_n: number): any
		return answer
	end
end
table.insert(junkCatalogue, { key = "NotTable", id = 208, isPass = false, fallback = 10 })
mock.behaviour[208] = function(_n: number): any
	return "oops"
end
local junkBook = newBook(nil, junkCatalogue)
junkBook.start()
runUntil(500)
for id = 201, 206 do
	check(junkBook.get(`J{id}`) == nil and junkBook.status(`J{id}`) == "offsale", `junk answer {id} shows ...`)
	check(mock.callsById[id] == 1, `junk answer {id} is final (not retried)`)
end
check(junkBook.get("J207") == 79, "fractional price floors")
check(mock.callsById[208] == cfg.MaxAttempts, "non-table answers are retried as failures")
check(junkBook.status("NotTable") == "fallback", "non-table answers end in fallback")
junkBook.stop()

-- ── 8. Rate budget ───────────────────────────────────────────────────────────────────────────

resetScheduler()
resetMock()
local budgetCatalogue = {}
for index = 1, 30 do
	local id = 300 + index
	table.insert(budgetCatalogue, { key = `B{index}`, id = id, isPass = false, fallback = 10 })
	mock.behaviour[id] = priced(20)
end
local budgetBook = newBook(configWith({ MaxRequestsPerMinute = 8, Concurrency = 3 }), budgetCatalogue)
budgetBook.start()
runUntil(500) -- < RefreshSeconds × (1 - jitter): only the first sweep
check(#mock.calls == 30, "every item fetched under a tight budget")
for _, first in mock.calls do
	local inWindow = 0
	for _, other in mock.calls do
		if other.at >= first.at and other.at < first.at + 60 then
			inWindow += 1
		end
	end
	check(inWindow <= 8, `≤ 8 calls in the 60 s window from {first.at}`)
end
check(mock.calls[30].at >= 3 * 60, "30 calls at 8 / min need at least three full windows")
check(mock.maxInFlight <= 3, "tight concurrency respected")
budgetBook.stop()

-- ── 10. format() ─────────────────────────────────────────────────────────────────────────────

check(PriceBook.format(1299) == "1,299", "format commas")
check(PriceBook.format(49) == "49", "format small")
check(PriceBook.format(nil) == "...", "format nil")
check(PriceBook.format(0) == "...", "format 0")

print(`[price-book] {checks} checks passed`)
