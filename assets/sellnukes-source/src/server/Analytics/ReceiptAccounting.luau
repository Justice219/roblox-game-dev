--!strict
--[[
	ReceiptAccounting — the durable facts of one developer-product receipt (ported from RoBeasts'
	Economy/ReceiptAccounting; docs/analytics.md "Durable receipt accounting"). Pure: no services.

	Purpose:
		A developer-product receipt is granted ONCE (MonetizationService's per-profile receipt
		ledger), but the profile only keeps its newest receipts. The permanent journal
		(Server/Analytics/ReceiptJournal, DataStore keys "receiptV1:<yyyy-mm>:<shard>") remembers
		every PurchaseId forever and adds the receipt's revenue counters atomically with the id, so
		a replayed / recovered receipt can never be counted twice and a counted receipt is never
		lost to a server crash between grant and flush.

	Flow (MonetizationService drives it through AnalyticsService.receiptAccounting()):
		1. prepare  (no yield)  capture product, Robux, original UTC day, prompt source, device,
		                        tycoon area, staff flag → Record (ready = false)
		2. reserve  (yields)    ReceiptJournal.reserve: the id is reserved permanently BEFORE the grant
		3. grant + finalize     MonetizationService grants, then calls finalize(record, analytics) in
		                        the SAME profile commit (payer-day marking happens here, no yield)
		4. record   (yields)    ReceiptJournal.complete: one UpdateAsync inserts the id and adds
		                        `counters(record)` to the monthly ledger shard; AnalyticsStore.loadRange
		                        reads those ledger counters back into the report totals.

	Bounds: ids 1..64 characters, amounts finite whole numbers ≤ 1e9, days 1..MaxDay, string fields
	`[%w_]` ≤ 64 characters (config ids only). Malformed stored records read as nil (never trusted).

	Example:
		local record = ReceiptAccounting.read(saved)            -- nil when malformed
		ReceiptAccounting.finalize(record, profile.analytics, 250)
		local families = ReceiptAccounting.counters(record)     -- { revenue = {...}, core = {...}, ... }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)

local ReceiptAccounting = {}
ReceiptAccounting.OutboxLimit = 32
ReceiptAccounting.ShardLimit = 8192 -- monthly ID cap per shard; never evict replay protection
ReceiptAccounting.ShardCount = 32
ReceiptAccounting.MaxDay = 50000 -- through 2106; at most 1563 sparse payer bitmap blocks
-- The payer fields of profile.analytics (AnalyticsMarks.AnalyticsData has them all).
export type PayerMarks = { payFirst: number, payLast: number, payDays: { [string]: number } }

export type Record = {
	day: number,
	userId: number,
	productId: number,
	product: string,
	kind: string,
	robux: number,
	source: string,
	device: string,
	area: number, -- buyer's tycoon area at prepare time (0 = unknown)
	rebirths: number, -- buyer's rebirth count at prepare time
	staff: boolean,
	payEligible: boolean,
	ready: boolean,
	legacy: boolean?, -- historical grant: terminal replay protection without backfilling old totals
	payer: boolean?,
	newPayer: boolean?,
	gems: number,
}
export type Families = { [string]: { [string]: number } }

--[[
	Stable v1 destination: full-ID hashing spreads writes; the original UTC day picks the month.
	Changing this mapping requires a new ledger version and reads of both, not a retune.
]]
function ReceiptAccounting.shard(id: string): number
	local hash = 0
	for i = 1, #id do
		hash = (hash * 31 + string.byte(id, i)) % ReceiptAccounting.ShardCount
	end
	return hash
end

--[[ "yyyy-mm" of a UTC day number. ]]
function ReceiptAccounting.month(day: number): string
	return os.date("!%Y-%m", day * 86400) :: string
end

--[[ The ledger key of a receipt id on its original day. ]]
function ReceiptAccounting.ledgerKey(id: string, day: number): string
	return `receiptV1:{ReceiptAccounting.month(day)}:{ReceiptAccounting.shard(id)}`
end

--[[ The month's index key (which ledger shards hold receipts). ]]
function ReceiptAccounting.indexKey(day: number): string
	return `receiptIndexV1:{ReceiptAccounting.month(day)}`
end

-- A finite whole number in [0, max], or nil.
local function wholeIn(value: unknown, max: number): number?
	if type(value) ~= "number" or value ~= value or value < 0 or value > max or value % 1 ~= 0 then
		return nil
	end
	return value
end

--[[
	Rejects malformed persisted facts rather than inventing a successful grant / accounting result.
	@param raw any stored value
	@return a fresh Record with only known fields, or nil
]]
function ReceiptAccounting.read(raw: unknown): Record?
	if type(raw) ~= "table" then
		return nil
	end
	local value = raw :: { [string]: unknown }
	local day = wholeIn(value.day, ReceiptAccounting.MaxDay)
	local userId = wholeIn(value.userId, 2 ^ 53)
	local productId = wholeIn(value.productId, 2 ^ 53)
	local robux = wholeIn(value.robux, 1e9)
	local gems = wholeIn(value.gems, 1e9)
	local area = wholeIn(if value.area == nil then 0 else value.area, 99)
	local rebirths = wholeIn(if value.rebirths == nil then 0 else value.rebirths, 1e9)
	if
		day == nil
		or day < 1
		or userId == nil
		or userId < 1
		or productId == nil
		or productId < 1
		or robux == nil
		or gems == nil
		or area == nil
		or rebirths == nil
	then
		return nil
	end
	for _, key in { "product", "kind", "source", "device" } do
		local s = value[key]
		if type(s) ~= "string" or #s < 1 or #s > 64 or not string.match(s, "^[%w_]+$") then
			return nil
		end
	end
	if type(value.ready) ~= "boolean" or type(value.staff) ~= "boolean" or type(value.payEligible) ~= "boolean" then
		return nil
	end
	for _, key in { "payer", "newPayer", "legacy" } do
		if value[key] ~= nil and type(value[key]) ~= "boolean" then
			return nil
		end
	end
	-- Only known fields survive reconciliation; the record has constant serialized size.
	return {
		day = day,
		userId = userId,
		productId = productId,
		product = value.product :: string,
		kind = value.kind :: string,
		robux = robux,
		source = value.source :: string,
		device = value.device :: string,
		area = area,
		rebirths = rebirths,
		staff = value.staff :: boolean,
		payEligible = value.payEligible :: boolean,
		ready = value.ready :: boolean,
		legacy = value.legacy :: boolean?,
		payer = value.payer :: boolean?,
		newPayer = value.newPayer :: boolean?,
		gems = gems,
	}
end

--[[
	Lifetime sparse payer-day bitmap, shared with game-pass payer marking. Unlike payLast it handles
	a delayed older receipt after a newer purchase without counting a day twice.
	@return true when `day` was not marked yet (the caller counts a payer for that day)
]]
function ReceiptAccounting.markPayerDay(marks: PayerMarks, day: number): boolean
	local days = marks.payDays
	if type(days) ~= "table" then
		days = {}
		marks.payDays = days
	end
	local function add(value: number): boolean
		if value < 1 or value > ReceiptAccounting.MaxDay then
			return false
		end
		local key = tostring(value // 32)
		local bit = bit32.lshift(1, value % 32)
		local prior = days[key] or 0
		days[key] = bit32.bor(prior, bit)
		return bit32.band(prior, bit) == 0
	end
	-- Seed the known legacy days once / harmlessly on each call; never invent missing history.
	add(marks.payFirst)
	add(marks.payLast)
	return add(day)
end

--[[
	No-yield transition that belongs in the same profile commit as the receipt and its grant:
	stamps the granted gems and the payer facts (payer-day / first payer) onto the record.
]]
function ReceiptAccounting.finalize(record: Record, marks: PayerMarks, gems: number?)
	if record.ready then
		return
	end
	if gems ~= nil and gems >= 0 and gems <= 1e9 and gems % 1 == 0 then
		record.gems = gems
	end
	if record.payEligible and not record.legacy then
		record.payer = ReceiptAccounting.markPayerDay(marks, record.day)
		record.newPayer = marks.payFirst == 0
		marks.payLast = math.max(marks.payLast, record.day)
		if record.newPayer then
			marks.payFirst = record.day
		end
	end
	record.ready = true
end

-- Rebirth bucket label by lowest count (same spelling as AnalyticsLogic.countBucket; duplicated
-- here so this pure module stays free of the larger logic module).
local function rebirthBucket(value: number): string
	local lower = 0
	for _, upper in AnalyticsConfig.Tycoon.RebirthBuckets do
		if value < upper then
			return if upper - lower <= 1 then tostring(lower) else `{lower}-{upper - 1}`
		end
		lower = upper
	end
	return `{lower}+`
end

--[[
	The additive DataStore counters of one receipt (revenue / core / economy families), the same
	keys the live recorder writes. Roblox economy events have no idempotency key and stay on the
	live-success path only. A staff receipt counts nothing but its staff marker.
]]
function ReceiptAccounting.counters(record: Record): Families
	if record.staff then
		local staff: { [string]: number } = { ["staff:robuxPurchase"] = 1 }
		return { revenue = staff }
	end
	local area = tostring(record.area)
	local revenue: { [string]: number } = {
		purchases = 1,
		robux = record.robux,
		[`product:{record.product}:count`] = 1,
		[`product:{record.product}:robux`] = record.robux,
		[`kind:{record.kind}:robux`] = record.robux,
		[`purchase:{record.product}:{record.source}`] = 1,
		[`robuxBySource:{record.source}`] = record.robux,
		[`purchaseDevice:{record.product}:{record.device}`] = 1,
		[`robuxByDevice:{record.device}`] = record.robux,
		[`buyArea:{area}`] = 1,
		[`robuxByArea:{area}`] = record.robux,
		[`robuxByRebirth:{rebirthBucket(record.rebirths)}`] = record.robux,
		[`funnel:{record.product}:bought`] = 1,
	}
	if record.newPayer then
		revenue[`firstBuy:{record.product}`] = 1
	end
	local core = { payers = if record.payer then 1 else 0, newPayers = if record.newPayer then 1 else 0 }
	local economy: { [string]: number } = {}
	if record.gems > 0 then
		economy["earn:gems:robux"] = record.gems
		economy[`earn:gems:robux:{record.product}`] = record.gems
	end
	return { revenue = revenue, core = core, economy = economy }
end

return table.freeze(ReceiptAccounting)
