--!strict
-- Permanent receipt identities + daily additive accounting, over an injected DataStore boundary.
-- Each transform is pure/retryable. No claim here is an atomic transaction across profile keys:
-- the profile's pinned outbox bridges the grant commit and these idempotent acknowledgements.
local ReceiptAccounting = require(script.Parent.ReceiptAccounting)
type Record = ReceiptAccounting.Record
type Families = ReceiptAccounting.Families
export type Backend = { update: (string, (unknown) -> unknown?) -> boolean }
export type Journal = {
	reserve: (string, Record) -> (string, Record?, boolean?),
	complete: (string, Record) -> boolean,
}
local ReceiptJournal = {}

-- IDs remain forever in independent keys; bounded profile history is never the replay authority.
function ReceiptJournal.new(backend: Backend): Journal
	local indexed: { [string]: boolean } = {}
	local indexedCount = 0
	-- Publish discoverability before any grant. Cached successful index writes avoid turning
	-- this small monthly directory into a hot key on every purchase; at most64 cache entries.
	local function publishIndex(id: string, day: number): boolean
		local ledgerKey = ReceiptAccounting.ledgerKey(id, day)
		if indexed[ledgerKey] then
			return true
		end
		local accepted = false
		local ok = backend.update(ReceiptAccounting.indexKey(day), function(raw: unknown): unknown?
			accepted = false
			if raw ~= nil and type(raw) ~= "table" then
				return nil
			end
			local shards = if type(raw) == "table" then table.clone(raw :: { [string]: boolean }) else {}
			shards[tostring(ReceiptAccounting.shard(id))] = true
			accepted = true
			return shards
		end)
		if not ok or not accepted then
			return false
		end
		if indexedCount >= 64 then
			table.clear(indexed)
			indexedCount = 0
		end
		indexed[ledgerKey] = true
		indexedCount += 1
		return true
	end

	local function reserve(id: string, proposed: Record): (string, Record?, boolean?)
		if #id < 1 or #id > 64 or ReceiptAccounting.read(proposed) == nil then
			return "unavailable", nil, false
		end
		local status = "unavailable"
		local created = false
		local result: Record? = nil
		local ok = backend.update(`receipt:{string.sub(id, 1, 40)}`, function(raw: unknown): unknown?
			status, result, created = "unavailable", nil, false -- a transform may be retried with a newer value
			if raw ~= nil and type(raw) ~= "table" then
				return nil
			end
			local bucket = if type(raw) == "table" then table.clone(raw :: { [string]: any }) else {}
			local saved = bucket[id]
			if saved == nil then
				local n = 0
				for _ in bucket do
					n += 1
				end
				if n >= 1024 then
					return nil
				end -- full IDs never alias; oversized buckets fail closed
				result = table.clone(proposed)
				status = "pending"
				created = true
				bucket[id] = { record = result, granted = false }
				return bucket
			end
			if type(saved) ~= "table" then
				return nil
			end
			local record = ReceiptAccounting.read(saved.record)
			if record == nil or record.userId ~= proposed.userId or record.productId ~= proposed.productId then
				return nil
			end
			result = record
			status = if saved.granted == true then "granted" else "pending"
			return nil
		end)
		if not ok or result == nil then
			return "unavailable", nil, false
		end
		if status == "pending" and not (result :: Record).legacy then
			-- Reserve bounded shard capacity BEFORE a grant. False means reserved, true counted.
			local capacity = false
			local facts = result :: Record
			if not publishIndex(id, facts.day) then
				-- Identity is already durable even though granting cannot proceed. Preserve its
				-- creation proof so the caller consumes only that reservation's captured prompt.
				return "unavailable", result, created
			end
			local spaceOk = backend.update(ReceiptAccounting.ledgerKey(id, facts.day), function(raw: unknown): unknown?
				capacity = false
				local old = if type(raw) == "table" then raw :: { [string]: any } else nil
				if raw ~= nil and (old == nil or type(old.ids) ~= "table" or type(old.byDay) ~= "table") then
					return nil
				end
				local ids = if old ~= nil then table.clone(old.ids) else {}
				if ids[id] ~= nil then
					capacity = true
					return nil
				end
				local n = 0
				for _ in ids do
					n += 1
				end
				if n >= ReceiptAccounting.ShardLimit then
					return nil
				end
				ids[id] = false
				capacity = true
				return { ids = ids, byDay = if old ~= nil then old.byDay else {} }
			end)
			if not spaceOk or not capacity then
				return "unavailable", result, created
			end
		end
		return status, result, created
	end
	local function complete(id: string, record: Record): boolean
		if not record.ready then
			return false
		end
		-- Check immutable reservation facts before touching totals. A damaged outbox must not
		-- rewrite the original day/amount/source, or count once under two different day keys.
		local status, original = reserve(id, record)
		if status == "unavailable" or original == nil then
			return false
		end
		if (original.legacy == true) ~= (record.legacy == true) then
			return false -- a damaged outbox cannot bypass accounting by claiming a legacy grant
		end
		for _, key in
			{ "day", "userId", "productId", "product", "kind", "robux", "source", "device", "staff", "payEligible" }
		do
			if (original :: any)[key] ~= (record :: any)[key] then
				return false
			end
		end
		if status == "granted" then
			return true
		end
		-- Dedupe and all additive counters share ONE update. A lost response can be retried safely.
		local accepted = false
		local ledgerOk = record.legacy == true
			or backend.update(ReceiptAccounting.ledgerKey(id, record.day), function(raw: unknown): unknown?
				accepted = false
				local old = if type(raw) == "table" then raw :: { [string]: any } else nil
				if raw ~= nil and (old == nil or type(old.ids) ~= "table" or type(old.byDay) ~= "table") then
					return nil
				end
				local ids = if old ~= nil then table.clone(old.ids) else {}
				if ids[id] == true then
					accepted = true
					return nil
				end
				local n = 0
				for _ in ids do
					n += 1
				end
				if ids[id] == nil and n >= ReceiptAccounting.ShardLimit then
					return nil
				end
				local byDay = if old ~= nil then table.clone(old.byDay) else {}
				local dayKey = tostring(record.day)
				local families: Families = {}
				if byDay[dayKey] ~= nil then
					for family, counters in byDay[dayKey] do
						families[family] = table.clone(counters)
					end
				end
				for family, counters in ReceiptAccounting.counters(record) do
					local target = families[family] or {}
					families[family] = target
					for key, amount in counters do
						target[key] = (target[key] or 0) + amount
					end
				end
				ids[id] = true
				accepted = true
				byDay[dayKey] = families
				return { ids = ids, byDay = byDay }
			end)
		if not ledgerOk or (not record.legacy and not accepted) then
			return false
		end
		local acknowledged = false
		local ok = backend.update(`receipt:{string.sub(id, 1, 40)}`, function(raw: unknown): unknown?
			acknowledged = false
			if type(raw) ~= "table" then
				return nil
			end
			local bucket = table.clone(raw :: { [string]: any })
			local old = bucket[id]
			if type(old) ~= "table" then
				return nil
			end
			local saved = ReceiptAccounting.read(old.record)
			if saved == nil or saved.userId ~= record.userId or saved.productId ~= record.productId then
				return nil
			end
			acknowledged = true
			bucket[id] = { record = record, granted = true }
			return bucket
		end)
		return ok and acknowledged
	end
	return { reserve = reserve, complete = complete }
end
return ReceiptJournal
