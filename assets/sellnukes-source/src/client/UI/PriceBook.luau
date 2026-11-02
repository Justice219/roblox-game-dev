--!strict
--[[
	PriceBook — the REAL current Robux price of every SellNukes game pass and developer product,
	fetched on the client and pushed into every price label.

	Why: all 35 items use Roblox MANAGED PRICING (Creator Dashboard, 2026-10-30), so the price
	Roblox charges can drift from MonetizationConfig.price and differ per player / region. Only
	MarketplaceService:GetProductInfoAsync on the player's own client returns what THAT player
	will pay, so the UI reads prices from here instead of from the config.

	How it works:
		- One sweep = one GetProductInfoAsync call per published item (PublishedProductIds via
		  MonetizationConfig; id 0 = unpublished, never fetched). PriceBookConfig.Concurrency
		  workers pull from one queue (the engine transparently batches concurrent calls), every
		  call start waits for the rolling MaxRequestsPerMinute budget, and a failed call retries
		  with jittered exponential backoff up to MaxAttempts.
		- The first sweep starts lazily (the first get / bind / start); later sweeps run every
		  RefreshSeconds ± RefreshJitter on ONE thread. A sweep never overlaps a running one.
		- Results are cached for the session. `Changed` fires (key, price) only when the price a
		  label should show actually changes.

	What `get(key)` returns (status → price):
		"pending"      no answer yet                         → nil  (labels show "...")
		"live"         Roblox answered with a valid price    → that price
		"fallback"     every attempt of the FIRST fetch failed → MonetizationConfig price (until
		               a later sweep succeeds). A later sweep that fails keeps the last live price.
		"offsale"      Roblox says not for sale / no sane price → nil ("...", never a wrong number)
		"unconfigured" id 0 (not on the dashboard yet)        → nil
		"unknown"      not a catalogue key                    → nil

	Security: display only. The server never reads these prices; it prompts by key and Roblox's
	own purchase dialog always shows and charges the real price. Responses are validated
	(table, IsForSale ~= false, finite whole-ish PriceInRobux in (0, MaxSanePrice)).

	Performance: ≤ 35 calls per 10 min, no per-frame work, no Instance creation. Label bindings
	are a key → { instance → apply } registry (strong keys, dropped on Destroying via
	ForgetOnDestroy), so a price change touches only the labels showing that key.

	Connects to: Shared/Config/{MonetizationConfig, PriceBookConfig}, Shared/Util/{Signal,
	ForgetOnDestroy, NumberFormat}. Used by Kit/StudUI (robuxTag / button / starburst
	`productKey`), so every screen's Robux labels follow it. Tested by tests/price-book.luau
	(PriceBook.new with a mock MarketplaceService and a virtual clock).

	Example:
		local PriceBook = require(script.Parent.PriceBook) -- from UI/*
		print(PriceBook.text("VIP")) --> "..." at first, then this player's current live Robux price
		PriceBook.Changed:Connect(function(key, price) print(key, price) end)
		PriceBook.bind(label, "CashSmall", function(price) label.Text = PriceBook.format(price) end)
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ForgetOnDestroy = require(ReplicatedStorage.Shared.Util.ForgetOnDestroy)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PriceBookConfig = require(ReplicatedStorage.Shared.Config.PriceBookConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type Status = "pending" | "live" | "fallback" | "offsale" | "unconfigured" | "unknown"

-- One catalogue item the book prices.
export type CatalogueItem = {
	key: string,
	id: number, -- dashboard id (0 = unpublished: never fetched)
	isPass: boolean, -- true → Enum.InfoType.GamePass, else Enum.InfoType.Product
	fallback: number, -- MonetizationConfig price (shown only after the first fetch fails)
}

-- Everything the book touches outside itself (tests swap these for doubles + a virtual clock).
export type Deps = {
	-- MarketplaceService, or a double with :GetProductInfoAsync(id, infoType) (may yield / error).
	marketplace: any,
	sleep: (seconds: number) -> (),
	spawn: (fn: () -> ()) -> (),
	now: () -> number, -- monotonic seconds
	random: () -> number, -- uniform [0, 1)
	config: typeof(PriceBookConfig)?,
	catalogue: { CatalogueItem }?, -- default: every MonetizationConfig pass + product
}

export type Stats = {
	sweeps: number, -- sweeps started
	requests: number, -- GetProductInfoAsync calls made
	failures: number, -- calls that errored / returned junk
	live: number,
	fallback: number,
	pending: number,
}

export type Book = {
	get: (key: string) -> number?,
	status: (key: string) -> Status,
	text: (key: string) -> string,
	start: () -> (),
	stop: () -> (),
	-- Starts a sweep now; false when one is already running (or the book is stopped).
	refresh: () -> boolean,
	isSweeping: () -> boolean,
	stats: () -> Stats,
	Changed: Signal.Signal<string, number?>,
}

-- A catalogue item plus what the book knows about it.
type Entry = {
	key: string,
	id: number,
	isPass: boolean,
	fallback: number,
	state: Status,
	price: number?, -- the last live price (kept through later failed sweeps)
}

local PriceBook = {}

--[[
	The text a Robux label shows for a price: "1,299", or "..." while unknown (nil / 0).
	Example: PriceBook.format(1299) --> "1,299";  PriceBook.format(nil) --> "..."
]]
function PriceBook.format(price: number?): string
	if price ~= nil and price > 0 then
		return NumberFormat.commas(price)
	end
	return PriceBookConfig.UnknownText
end

--[[
	The default catalogue: every MonetizationConfig pass and product (keys are unique across both
	groups — validate() / tests enforce it), in display order so the first sweep prices the
	passes and the first products the HUD shows first.
]]
function PriceBook.catalogue(): { CatalogueItem }
	local items: { CatalogueItem } = {}
	for _, key in MonetizationConfig.PassOrder do
		local def = MonetizationConfig.Passes[key]
		table.insert(items, { key = key, id = def.id, isPass = true, fallback = def.price })
	end
	for _, key in MonetizationConfig.ProductOrder do
		local def = MonetizationConfig.Products[key]
		table.insert(items, { key = key, id = def.id, isPass = false, fallback = def.price })
	end
	return items
end

--[[
	A validated price from a GetProductInfoAsync result, or nil (not for sale / missing / junk).
	@param info the raw result (untrusted shape)
	@param maxSane prices at or above this are junk
]]
local function parsePrice(info: { [string]: unknown }, maxSane: number): number?
	if info.IsForSale == false then
		return nil
	end
	local raw = info.PriceInRobux
	if type(raw) ~= "number" or raw ~= raw or raw <= 0 or raw >= maxSane then
		return nil
	end
	return math.floor(raw)
end

--[[
	Creates a price book. The game uses the module-level default (PriceBook.get / bind / ...);
	tests build their own with doubles.
	@param deps services + clock (see Deps); nil = the real MarketplaceService and task library
	@return Book (not started: the first get / start begins the sweeps)
	Example: local book = PriceBook.new(); book.start(); print(book.get("VIP"))
]]
function PriceBook.new(deps: Deps?): Book
	local rng = Random.new()
	local d: Deps = deps
		or {
			marketplace = MarketplaceService,
			sleep = function(seconds: number)
				task.wait(seconds)
			end,
			spawn = function(fn: () -> ())
				task.spawn(fn)
			end,
			now = os.clock,
			random = function(): number
				return rng:NextNumber()
			end,
		}
	local cfg = d.config or PriceBookConfig
	local changed = Signal.new() :: Signal.Signal<string, number?>

	local entries: { [string]: Entry } = {}
	local queue: { Entry } = {} -- published items, sweep order
	for _, item in d.catalogue or PriceBook.catalogue() do
		local published = MonetizationConfig.isConfigured(item.id)
		local entry: Entry = {
			key = item.key,
			id = item.id,
			isPass = item.isPass,
			fallback = item.fallback,
			state = if published then "pending" else "unconfigured",
			price = nil,
		}
		entries[item.key] = entry
		if published then
			table.insert(queue, entry)
		end
	end

	local started = false
	local stopped = false
	local sweeping = false
	local sweeps, requests, failures = 0, 0, 0
	-- Start times of recent calls (ascending) for the rolling one-minute budget.
	local recentStarts: { number } = {}

	-- The price a label shows for an entry (see the header's status table).
	local function shown(entry: Entry): number?
		if entry.state == "live" then
			return entry.price
		elseif entry.state == "fallback" then
			return entry.fallback
		end
		return nil
	end

	-- Moves an entry to a new state; fires Changed only when the shown price changes.
	local function setState(entry: Entry, state: Status, price: number?)
		local before = shown(entry)
		entry.state = state
		if price ~= nil then
			entry.price = price
		end
		local after = shown(entry)
		if after ~= before then
			changed:Fire(entry.key, after)
		end
	end

	-- Blocks until one more call fits the rolling 60 s budget, then books it.
	local function awaitBudget()
		while not stopped do
			local now = d.now()
			while recentStarts[1] ~= nil and recentStarts[1] <= now - 60 do
				table.remove(recentStarts, 1) -- ≤ MaxRequestsPerMinute entries: trivial
			end
			if #recentStarts < cfg.MaxRequestsPerMinute then
				table.insert(recentStarts, now)
				return
			end
			-- Sleep until the oldest booked start leaves the window (never a busy spin).
			d.sleep(math.max(0.05, recentStarts[1] + 60 - now))
		end
	end

	-- Jittered exponential backoff after failed attempt `attempt` (1-based).
	local function backoff(attempt: number): number
		local base = math.min(cfg.BackoffMaxSeconds, cfg.BackoffBaseSeconds * cfg.BackoffFactor ^ (attempt - 1))
		return base * (1 - cfg.BackoffJitter * d.random())
	end

	-- Fetches one item with retries; updates its state.
	local function fetch(entry: Entry)
		local infoType = if entry.isPass then Enum.InfoType.GamePass else Enum.InfoType.Product
		for attempt = 1, cfg.MaxAttempts do
			awaitBudget()
			if stopped then
				return
			end
			requests += 1
			local ok, info = pcall(function(): unknown
				return d.marketplace:GetProductInfoAsync(entry.id, infoType)
			end)
			if ok and type(info) == "table" then
				local price = parsePrice(info :: { [string]: unknown }, cfg.MaxSanePrice)
				if price ~= nil then
					setState(entry, "live", price)
				else
					setState(entry, "offsale", nil)
				end
				return
			end
			failures += 1
			if attempt < cfg.MaxAttempts then
				d.sleep(backoff(attempt))
			end
		end
		-- Every attempt failed. A price Roblox gave earlier this session beats the config one.
		if entry.state ~= "live" then
			setState(entry, "fallback", nil)
		end
	end

	-- Runs one sweep on Concurrency workers; false when one is running already.
	local function sweep(): boolean
		if sweeping or stopped then
			return false
		end
		local workers = math.min(cfg.Concurrency, #queue)
		if workers <= 0 then
			return true
		end
		sweeping = true
		sweeps += 1
		local nextIndex = 1
		local running = workers
		for _ = 1, workers do
			d.spawn(function()
				while not stopped do
					local entry = queue[nextIndex]
					if entry == nil then
						break
					end
					nextIndex += 1
					fetch(entry)
				end
				running -= 1
				if running == 0 then
					sweeping = false
				end
			end)
		end
		return true
	end

	local book = {} :: Book
	book.Changed = changed

	function book.start()
		if started or stopped then
			return
		end
		started = true
		-- ONE refresh thread: sweep, then wait RefreshSeconds ± jitter (a still-running sweep
		-- is skipped, so a slow, retrying sweep never doubles the request rate).
		d.spawn(function()
			while not stopped do
				sweep()
				d.sleep(cfg.RefreshSeconds * (1 + cfg.RefreshJitter * (2 * d.random() - 1)))
			end
		end)
	end

	function book.stop()
		stopped = true
	end

	function book.refresh(): boolean
		return sweep()
	end

	function book.isSweeping(): boolean
		return sweeping
	end

	function book.get(key: string): number?
		local entry = entries[key]
		if entry == nil then
			return nil
		end
		book.start()
		return shown(entry)
	end

	function book.status(key: string): Status
		local entry = entries[key]
		return if entry == nil then "unknown" else entry.state
	end

	function book.text(key: string): string
		return PriceBook.format(book.get(key))
	end

	function book.stats(): Stats
		local live, fallback, pending = 0, 0, 0
		for _, entry in entries do
			if entry.state == "live" then
				live += 1
			elseif entry.state == "fallback" then
				fallback += 1
			elseif entry.state == "pending" then
				pending += 1
			end
		end
		return {
			sweeps = sweeps,
			requests = requests,
			failures = failures,
			live = live,
			fallback = fallback,
			pending = pending,
		}
	end

	return book
end

-- ── The game's default book + label bindings ─────────────────────────────────────────────────

local default = PriceBook.new()

-- key → { bound instance → apply(price) }; boundKey is the reverse index for unbind.
local bindings: { [string]: { [Instance]: (price: number?) -> () } } = {}
local boundKey: { [Instance]: string } = {}

local function forget(instance: Instance)
	local key = boundKey[instance]
	if key == nil then
		return
	end
	boundKey[instance] = nil
	local set = bindings[key]
	if set ~= nil then
		set[instance] = nil
	end
end
local tracker = ForgetOnDestroy.new(forget)

-- One dispatcher for every binding: only the labels of the changed key are touched.
default.Changed:Connect(function(key: string, price: number?)
	local set = bindings[key]
	if set == nil then
		return
	end
	for _, apply in set do
		apply(price)
	end
end)

--[[ Fires (key, price) whenever the price shown for `key` changes (price nil = show "..."). ]]
PriceBook.Changed = default.Changed

--[[
	The price to show for a pass / product key (nil while unknown → "..."). Starts the sweeps.
	Example: PriceBook.get("CashSmall") --> 29 (or nil until the first answer)
]]
function PriceBook.get(key: string): number?
	return default.get(key)
end

--[[ The book's status for a key ("pending" | "live" | "fallback" | "offsale" | ...). ]]
function PriceBook.status(key: string): Status
	return default.status(key)
end

--[[ get(key) formatted for a label ("249" / "..."). ]]
function PriceBook.text(key: string): string
	return default.text(key)
end

--[[ Starts the background sweeps now (the client boot calls this so prices are ready early). ]]
function PriceBook.start()
	default.start()
end

--[[ Counters for the admin / perf tooling (sweeps, calls, failures, live / fallback / pending). ]]
function PriceBook.stats(): Stats
	return default.stats()
end

--[[
	Keeps `instance`'s price display on `key`: calls apply(price) now and on every change until
	`instance` is destroyed or unbound. Re-binding an instance replaces its previous key.
	@param instance the label / button that owns the display (its Destroying ends the binding)
	@param key MonetizationConfig pass / product key
	@param apply writes the price (nil = unknown → show "...")
	Example: PriceBook.bind(tag, "VIP", function(price) priceLabel.Text = PriceBook.format(price) end)
]]
function PriceBook.bind(instance: Instance, key: string, apply: (price: number?) -> ())
	forget(instance)
	local set = bindings[key] or {}
	bindings[key] = set
	set[instance] = apply
	boundKey[instance] = key
	tracker.track(instance)
	apply(default.get(key))
end

--[[ Stops `instance`'s price binding (no-op when it has none). ]]
function PriceBook.unbind(instance: Instance)
	forget(instance)
	tracker.untrack(instance)
end

return PriceBook
