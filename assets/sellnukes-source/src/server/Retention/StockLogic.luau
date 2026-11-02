--!strict
--[[
	StockLogic — the idempotent cross-server counter behind a globally limited product (the
	Secret Pack). Pure: ShopService runs `count` inside DataStore:UpdateAsync.

	Record (DataStore value): { sold = n, ids = { [purchaseId] = true } }
		count(old, purchaseId) adds the purchase exactly once (a retried / replayed PurchaseId is
		"already"); a paid receipt is ALWAYS counted, even past the limit (the player paid; the
		prompt refusal is what stops further sales). `ids` is bounded by MaxIds — a record that full
		keeps counting without remembering new ids (sold out long before that in practice).
	read(value) → sold count from any stored value (junk → 0).

	Example:
		store:UpdateAsync(key, function(old) local new = StockLogic.count(old, id); return new end)
]]

export type Record = { sold: number, ids: { [string]: boolean } }
export type Outcome = "counted" | "already"

local StockLogic = {}

-- Remembered purchase ids per record (DataStore value stays far below the 4 MB limit).
StockLogic.MaxIds = 5_000

-- A sanitized record from any stored value.
local function readRecord(value: unknown): Record
	if type(value) ~= "table" then
		return { sold = 0, ids = {} }
	end
	local raw = value :: { [string]: any }
	local sold = raw.sold
	local ids: { [string]: boolean } = {}
	if type(raw.ids) == "table" then
		for id, flag in raw.ids do
			if type(id) == "string" and flag == true then
				ids[id] = true
			end
		end
	end
	local safeSold = if type(sold) == "number"
			and sold == sold
			and sold >= 0
			and sold ~= math.huge
		then math.floor(sold)
		else 0
	return { sold = safeSold, ids = ids }
end

--[[ The sold count stored in `value` (0 for junk / nil). ]]
function StockLogic.read(value: unknown): number
	return readRecord(value).sold
end

--[[
	Counts `purchaseId` once.
	@return the new record and "counted" | "already"
]]
function StockLogic.count(old: unknown, purchaseId: string): (Record, Outcome)
	local record = readRecord(old)
	if record.ids[purchaseId] then
		return record, "already"
	end
	record.sold += 1
	local idCount = 0
	for _ in record.ids do
		idCount += 1
	end
	if idCount < StockLogic.MaxIds then
		record.ids[purchaseId] = true
	end
	return record, "counted"
end

return table.freeze(StockLogic)
