--!strict
--[[
	LeaderboardLogic — the pure (engine-free) half of SellNukes' global leaderboards
	(docs/leaderboards.md). Ported from RoBeasts' LeaderboardLogic, adapted to all-time "set"
	boards with encoded values (LeaderboardConfig.encode).

	What it decides (tests/leaderboard-logic.luau pins it under Lune):
		- pending writes: the LATEST stored value per (store, userId) between flushes; a failed
		  write merges back unless a newer value arrived meanwhile,
		- the per-player write throttle (`dueForWrite`): changed value AND MinUserWriteSeconds since
		  the last write, or "final" (leaving / shutdown) with only the engine's per-key interval,
		- write selection: which pending writes a flush may start (deterministic order, limit),
		- sanitizing an OrderedDataStore page (positive whole values ≤ MaxStored, userId > 0, one
		  row per user, top N) and competition ranks ("1, 2, 2, 4"),
		- in-memory "server" scope boards (Studio without DataStore access),
		- the bounded replication payload (decoded display values) and the display-name cache.

	How it connects: Services/LeaderboardService owns every state table and passes it in; nothing
	here yields, reads a clock or touches an Instance. Shapes / limits: LeaderboardConfig.

	Example:
		local pending: LeaderboardLogic.Pending = {}
		LeaderboardLogic.setPending(pending, "SellNukesLB_v1_Rebirths", 123, 4)
		local writes = LeaderboardLogic.selectWrites(pending, 10, function() return true end)
		--> { { store = "SellNukesLB_v1_Rebirths", userId = 123, value = 4 } }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LeaderboardConfig = require(ReplicatedStorage.Shared.Config.LeaderboardConfig)

type BoardDef = LeaderboardConfig.BoardDef
type Entry = LeaderboardConfig.Entry
type Payload = LeaderboardConfig.Payload

-- store name -> userId -> stored integer to SET.
export type Pending = { [string]: { [number]: number } }

-- One write a flush performs.
export type Write = { store: string, userId: number, value: number }

-- A sanitized row (stored integer, before decoding / names).
export type Row = { userId: number, stored: number }

export type NameEntry = { name: string, at: number }
export type NameCache = { [number]: NameEntry }

-- What the service remembers per (store, userId) about writes.
export type WriteRecord = { written: number, at: number } -- last stored value written + clock

local LeaderboardLogic = {}

--[[ True for a real Roblox user id (positive whole number; Studio test players are negative). ]]
function LeaderboardLogic.isUserId(value: unknown): boolean
	return type(value) == "number" and value == value and value > 0 and value < 2 ^ 53 and value % 1 == 0
end

--[[ A stored value as a whole number in 1..MaxStored, or nil (junk / zero / negative). ]]
function LeaderboardLogic.storedValue(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value == math.huge or value < 1 then
		return nil
	end
	return math.min(math.floor(value), LeaderboardConfig.MaxStored)
end

-- ─── Pending writes ───────────────────────────────────────────────────────────────────────────

--[[ Records the latest value to SET for (store, userId). @return false for invalid input ]]
function LeaderboardLogic.setPending(pending: Pending, store: string, userId: number, value: number): boolean
	local stored = LeaderboardLogic.storedValue(value)
	if not LeaderboardLogic.isUserId(userId) or stored == nil then
		return false
	end
	local byUser = pending[store]
	if byUser == nil then
		byUser = {}
		pending[store] = byUser
	end
	byUser[userId] = stored
	return true
end

--[[
	Merges a FAILED write back: it becomes pending again unless a newer value is already pending
	(the newer one wins; the next flush writes it).
]]
function LeaderboardLogic.mergeBack(pending: Pending, write: Write)
	local byUser = pending[write.store]
	if byUser ~= nil and byUser[write.userId] ~= nil then
		return
	end
	LeaderboardLogic.setPending(pending, write.store, write.userId, write.value)
end

--[[
	Whether a sampled value should become a pending write now.
	@param record the last successful write of this key (nil = never written this session)
	@param final  the player is leaving / the server is closing (skip the user throttle)
]]
function LeaderboardLogic.dueForWrite(record: WriteRecord?, stored: number, now: number, final: boolean): boolean
	if record == nil then
		return true
	end
	if record.written == stored then
		return false
	end
	return final or now - record.at >= LeaderboardConfig.MinUserWriteSeconds
end

--[[
	Picks up to `limit` pending writes `canWrite(store, userId)` allows and REMOVES them from
	`pending`. Stores and users are visited in sorted order (deterministic).
]]
function LeaderboardLogic.selectWrites(
	pending: Pending,
	limit: number,
	canWrite: (store: string, userId: number) -> boolean
): { Write }
	local writes: { Write } = {}
	if limit < 1 then
		return writes
	end
	local stores: { string } = {}
	for store in pending do
		table.insert(stores, store)
	end
	table.sort(stores)
	for _, store in stores do
		local byUser = pending[store]
		local users: { number } = {}
		for userId in byUser do
			table.insert(users, userId)
		end
		table.sort(users)
		for _, userId in users do
			if #writes >= limit then
				return writes
			end
			if canWrite(store, userId) then
				table.insert(writes, { store = store, userId = userId, value = byUser[userId] })
				byUser[userId] = nil
			end
		end
		if next(byUser) == nil then
			pending[store] = nil
		end
	end
	return writes
end

--[[ Number of pending writes (diagnostics). ]]
function LeaderboardLogic.pendingCount(pending: Pending): number
	local count = 0
	for _, byUser in pending do
		for _ in byUser do
			count += 1
		end
	end
	return count
end

-- ─── Reading + ranking ────────────────────────────────────────────────────────────────────────

--[[ { [userId]: stored } -> rows sorted stored desc / userId asc, valid only, <= topN. ]]
function LeaderboardLogic.topRows(values: { [number]: number }, topN: number): { Row }
	local rows: { Row } = {}
	for userId, value in values do
		local stored = LeaderboardLogic.storedValue(value)
		if LeaderboardLogic.isUserId(userId) and stored ~= nil then
			table.insert(rows, { userId = userId, stored = stored })
		end
	end
	table.sort(rows, function(a: Row, b: Row): boolean
		if a.stored ~= b.stored then
			return a.stored > b.stored
		end
		return a.userId < b.userId
	end)
	while #rows > topN do
		table.remove(rows)
	end
	return rows
end

--[[
	Sanitizes an OrderedDataStore page ({ { key, value } }). Keys must be a user id written as a
	string; values whole and >= 1. Duplicate users keep their highest value.
]]
function LeaderboardLogic.sanitizePage(page: unknown, topN: number): { Row }
	local best: { [number]: number } = {}
	if type(page) == "table" then
		for _, item in page :: { unknown } do
			if type(item) ~= "table" then
				continue
			end
			local raw = item :: { [string]: unknown }
			local key = raw.key
			local userId = if type(key) == "string" and string.match(key, "^%d+$") ~= nil then tonumber(key) else nil
			local stored = LeaderboardLogic.storedValue(raw.value)
			if userId == nil or not LeaderboardLogic.isUserId(userId) or stored == nil then
				continue
			end
			best[userId] = math.max(best[userId] or 0, stored)
		end
	end
	return LeaderboardLogic.topRows(best, topN)
end

--[[ Competition ranks for sorted rows: equal values share a rank, the next rank skips. ]]
function LeaderboardLogic.ranks(rows: { Row }): { number }
	local ranks: { number } = {}
	for index, row in rows do
		if index > 1 and rows[index - 1].stored == row.stored then
			ranks[index] = ranks[index - 1]
		else
			ranks[index] = index
		end
	end
	return ranks
end

--[[
	Sets a user's value on an in-memory "server" scope board, keeping at most `maxSize` users (the
	lowest is evicted when a new user would overflow it). Values below 1 remove the user.
]]
function LeaderboardLogic.setServerBoard(board: { [number]: number }, userId: number, value: number, maxSize: number)
	if not LeaderboardLogic.isUserId(userId) then
		return
	end
	local stored = LeaderboardLogic.storedValue(value)
	if stored == nil then
		board[userId] = nil
		return
	end
	if board[userId] == nil then
		local count = 0
		local lowestId: number? = nil
		local lowest = math.huge
		for id, existing in board do
			count += 1
			if existing < lowest then
				lowest, lowestId = existing, id
			end
		end
		if count >= maxSize and lowestId ~= nil then
			if lowest >= stored then
				return -- the board is full of better players
			end
			board[lowestId] = nil
		end
	end
	board[userId] = stored
end

-- ─── Payload ──────────────────────────────────────────────────────────────────────────────────

export type PayloadInfo = {
	def: BoardDef,
	scope: LeaderboardConfig.Scope,
	status: LeaderboardConfig.Status,
	updatedAt: number,
}

--[[
	Builds the replication payload from ranked rows: decoded display values, cleaned names
	(missing → "Player #id").
	@param names userId -> display name (untrusted strings)
]]
function LeaderboardLogic.buildPayload(info: PayloadInfo, rows: { Row }, names: { [number]: string }): Payload
	local ranks = LeaderboardLogic.ranks(rows)
	local entries: { Entry } = {}
	for index, row in rows do
		if index > LeaderboardConfig.TopN then
			break
		end
		table.insert(entries, {
			rank = ranks[index],
			userId = row.userId,
			name = LeaderboardConfig.cleanName(names[row.userId]) or LeaderboardConfig.fallbackName(row.userId),
			value = LeaderboardConfig.decode(info.def, row.stored),
		})
	end
	return {
		board = info.def.id,
		scope = info.scope,
		status = info.status,
		updatedAt = math.max(0, math.floor(info.updatedAt)),
		entries = entries,
	}
end

--[[ Encodes with `encode` and drops trailing entries until it fits MaxPayloadChars. ]]
function LeaderboardLogic.encodeBounded(payload: Payload, encode: (value: any) -> string): string
	local copy = table.clone(payload)
	copy.entries = table.clone(payload.entries)
	local text = encode(copy)
	while #text > LeaderboardConfig.MaxPayloadChars and #copy.entries > 0 do
		table.remove(copy.entries)
		text = encode(copy)
	end
	return text
end

-- ─── Display-name cache ───────────────────────────────────────────────────────────────────────

--[[
	User ids in `rows` that need a UserService lookup: not online (`known`) and not cached within
	`ttl`. Sorted, capped at `limit`.
]]
function LeaderboardLogic.missingNames(
	rows: { Row },
	known: { [number]: string },
	cache: NameCache,
	now: number,
	ttl: number,
	limit: number
): { number }
	local missing: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, row in rows do
		local userId = row.userId
		if seen[userId] or known[userId] ~= nil then
			continue
		end
		seen[userId] = true
		local cached = cache[userId]
		if cached == nil or now - cached.at > ttl then
			table.insert(missing, userId)
		end
	end
	table.sort(missing)
	while #missing > limit do
		table.remove(missing)
	end
	return missing
end

--[[ Stores a cleaned name and evicts the oldest entries beyond `maxSize`. ]]
function LeaderboardLogic.cacheName(cache: NameCache, userId: number, name: unknown, now: number, maxSize: number)
	local clean = LeaderboardConfig.cleanName(name)
	if clean == nil or not LeaderboardLogic.isUserId(userId) then
		return
	end
	local existing = cache[userId]
	cache[userId] = { name = clean, at = now }
	if existing ~= nil then
		return
	end
	local count = 0
	for _ in cache do
		count += 1
	end
	while count > maxSize do
		local oldestId: number? = nil
		local oldestAt = math.huge
		for id, entry in cache do
			if entry.at < oldestAt then
				oldestAt, oldestId = entry.at, id
			end
		end
		if oldestId == nil then
			break
		end
		cache[oldestId] = nil
		count -= 1
	end
end

return table.freeze(LeaderboardLogic)
