--!strict
--[[
	LeaderboardConfig — every tunable and the replication contract of SellNukes' three global hub
	leaderboards (spec §4 "leaderboards (top cash earned, top rebirths, top playtime)",
	docs/leaderboards.md). Pattern: RoBeasts LeaderboardConfig, adapted to all-time boards.

	Boards (all-time, every server, OrderedDataStores):
		Cash          lifetime cash earned (profile.totalEarned) — huge doubles, stored LOG-ENCODED
		Rebirths      profile.rebirths
		Playtime      profile.stats.playSeconds (shown as hours / minutes)
		DinoRebirths  (owner R57 World 2) profile.worlds.dino.rebirths — "MOST DINO REBIRTHS",
		              standing in Dino Valley's Base Camp (`world = "dino"`: the Valley layout's
		              anchors.Leaderboards[slot], world-local → WorldLayout.toWorld)
		MoonRebirths  (owner R70 World 3) profile.worlds.moon.rebirths — "MOST MOON REBIRTHS" at
		              Moon Base's landing plaza (`world = "moon"`, MoonHubLayout anchors.Leaderboards)
	A board with `world = nil` stands in the Nuke Town hub (HubLayout slots 1..3); a board with a
	`world` stands in that world's hub (WorldsConfig def.hubLayout). `boardsIn(worldId?)` lists them.

	Why the cash board is log-encoded: OrderedDataStore values are 64-bit integers, but lifetime cash
	runs far past 2^63 (NumberFormat goes to 1e300). `encode` stores round(log10(value) * 1e13):
	strictly order-preserving (the board sorts correctly), at most ~3.1e15 (< 2^53, exact in a
	double), and `decode` gets the value back to 12 significant digits — more than any label shows.
	Count boards store the whole value itself.

	How it connects:
		- Server: Services/LeaderboardService samples trusted profile values, writes them with
		  SetAsync (throttled per player, again on leave, flushed on shutdown), reads the top
		  `TopN` back every `ReadEverySeconds` and publishes one bounded JSON payload per board in
		  ReplicatedStorage[ContainerName][boardId] (a StringValue). Pure helpers live in
		  Server/Leaderboards/LeaderboardLogic. No remotes: clients cannot send leaderboard data.
		- Client: Client/Leaderboards/LeaderboardBoardController decodes those StringValues with
		  `parsePayload` (re-validated even though the server wrote them) and draws the three stud
		  boards on the hub screen parts (CollectionService tag `ScreenTag`).

	Payload schema (JSON in the StringValue; "" = not read yet):
		{ board = "Cash", scope = "global" | "server", status = "ok" | "unavailable",
		  updatedAt = 1793491200, entries = { { rank = 1, userId = 123, name = "Ava", value = 1.2e15 } } }
		`value` is DECODED (display value); ranks are competition ranks ("1, 2, 2, 4").

	Example:
		local def = LeaderboardConfig.ById.Cash
		local stored = LeaderboardConfig.encode(def, 1.25e30)   --> 300_969_100_130_081 (integer)
		print(LeaderboardConfig.decode(def, stored))           --> 1.25e+30
		print(LeaderboardConfig.storeName("Cash", false))      --> SellNukesLB_v1_Cash
]]

export type BoardId = "Cash" | "Rebirths" | "Playtime" | "DinoRebirths" | "MoonRebirths"
export type ValueFormat = "money" | "count" | "duration"
export type Encoding = "log" | "int"
export type Scope = "global" | "server"
export type Status = "ok" | "unavailable"

export type BoardDef = {
	id: BoardId,
	slot: number, -- board index in its hub (HubLayout.leaderboards[slot] / <world hub>.anchors.Leaderboards[slot])
	world: string?, -- nil = the Nuke Town hub; else the WorldsConfig id whose hub holds it (and whose
	--                 profile.worlds[world] the value comes from)
	title: string,
	unit: string, -- short value caption ("EARNED", "REBIRTHS", "PLAYED")
	icon: string, -- IconAssets key for the board header
	color: string, -- UIStyleConfig ColorName of the header bar
	format: ValueFormat,
	encoding: Encoding,
	emptyText: string,
}

export type Entry = { rank: number, userId: number, name: string, value: number }

export type Payload = {
	board: BoardId,
	scope: Scope,
	status: Status,
	updatedAt: number,
	entries: { Entry },
}

local LeaderboardConfig = {}

-- Board order = hub board slots 1..3.
local BOARDS: { BoardDef } = {
	{
		id = "Cash",
		slot = 1,
		title = "TOP CASH EARNED",
		unit = "EARNED",
		icon = "Cash",
		color = "green",
		format = "money",
		encoding = "log",
		emptyText = "Nobody has earned cash yet. Be the first!",
	},
	{
		id = "Rebirths",
		slot = 2,
		title = "MOST REBIRTHS",
		unit = "REBIRTHS",
		icon = "Rebirth",
		color = "teal",
		format = "count",
		encoding = "int",
		emptyText = "No rebirths yet. Finish the Mega Facility!",
	},
	{
		id = "Playtime",
		slot = 3,
		title = "MOST PLAYTIME",
		unit = "PLAYED",
		icon = "Time",
		color = "purple",
		format = "duration",
		encoding = "int",
		emptyText = "The clock just started. Keep playing!",
	},
	-- Owner R57 World 2: Dino Valley's own board at Base Camp (spec §12 / plan §4 W12).
	{
		id = "DinoRebirths",
		slot = 1,
		world = "dino",
		title = "MOST DINO REBIRTHS",
		unit = "DINO REBIRTHS",
		icon = "Amber",
		color = "orange",
		format = "count",
		encoding = "int",
		emptyText = "No Dino rebirths yet. Tame the Volcano Reactor!",
	},
	-- Owner R70 World 3: Moon Base's own board at the landing plaza (R69–R71 spec §2.3).
	{
		id = "MoonRebirths",
		slot = 1,
		world = "moon",
		title = "MOST MOON REBIRTHS",
		unit = "MOON REBIRTHS",
		icon = "StarShards",
		color = "purple",
		format = "count",
		encoding = "int",
		emptyText = "No Moon rebirths yet. Light the Star Reactor!",
	},
}
for _, def in BOARDS do
	table.freeze(def)
end
LeaderboardConfig.Boards = table.freeze(BOARDS)

-- Board id -> definition.
LeaderboardConfig.ById = (function(): { [BoardId]: BoardDef }
	local byId: { [BoardId]: BoardDef } = {}
	for _, def in BOARDS do
		byId[def.id] = def
	end
	return table.freeze(byId)
end)()

-- World id ("main" for the Nuke Town hub) -> its boards in slot order (built once).
local BOARDS_BY_WORLD: { [string]: { BoardDef } } = {}
for _, def in BOARDS do
	local worldId = def.world or "main"
	local list = BOARDS_BY_WORLD[worldId]
	if list == nil then
		list = {}
		BOARDS_BY_WORLD[worldId] = list
	end
	table.insert(list, def)
end
for _, list in BOARDS_BY_WORLD do
	table.sort(list, function(a: BoardDef, b: BoardDef): boolean
		return a.slot < b.slot
	end)
	table.freeze(list)
end
-- Returned for a world without boards (never mutate).
local NO_BOARDS: { BoardDef } = {}
table.freeze(NO_BOARDS)

--[[
	The boards standing in one world's hub, in slot order ("main" / nil = the Nuke Town hub).
	Example: LeaderboardConfig.boardsIn("dino")[1].id --> "DinoRebirths"; boardsIn() --> Cash, Rebirths, Playtime
]]
function LeaderboardConfig.boardsIn(worldId: string?): { BoardDef }
	return BOARDS_BY_WORLD[worldId or "main"] or NO_BOARDS
end

--[[ Every world id that has at least one board ("main" first, then the others sorted). ]]
function LeaderboardConfig.boardWorlds(): { string }
	local out: { string } = {}
	for worldId in BOARDS_BY_WORLD do
		if worldId ~= "main" then
			table.insert(out, worldId)
		end
	end
	table.sort(out)
	table.insert(out, 1, "main")
	return out
end

-- ─── Storage + cadence (server) ───────────────────────────────────────────────────────────────

-- OrderedDataStore names: `<StoreBase>_<board>[<StudioSuffix>]`. Bump the version only for a
-- deliberate global reset. Studio uses its own stores so test sessions never touch live boards.
LeaderboardConfig.StoreBase = "SellNukesLB_v1"
LeaderboardConfig.StudioSuffix = "_Studio"

-- Entries read per board (the hub boards show ShowRows; the rest give "your rank" context).
LeaderboardConfig.TopN = 25
LeaderboardConfig.ShowRows = 10
-- Seconds between top-N reads of every board (owner: refresh at most every 60 s).
LeaderboardConfig.ReadEverySeconds = 60
-- Seconds between flush ticks (sample every player, start the allowed writes).
LeaderboardConfig.FlushEverySeconds = 30
-- A player's value on one board is written at most once per this many seconds while they play
-- (throttle); leaving / shutdown writes the final value regardless.
LeaderboardConfig.MinUserWriteSeconds = 120
-- Minimum seconds between two writes to the same key (the engine allows one per 6 s per key).
LeaderboardConfig.MinKeyWriteSeconds = 7
-- Writes started per flush at most (bounds burst traffic).
LeaderboardConfig.MaxWritesPerFlush = 60
-- Request budget kept free for everyone else (profile saves always keep priority).
LeaderboardConfig.WriteBudgetReserve = 6
LeaderboardConfig.ReadBudgetReserve = 4
LeaderboardConfig.ProfileBudgetReserve = 10
-- BindToClose: time this service may spend flushing (parallel to the 25 s profile saves).
LeaderboardConfig.ShutdownBudgetSeconds = 8

-- Display-name cache (UserService lookups): entries kept, freshness, ids per batch call.
LeaderboardConfig.NameCacheSize = 300
LeaderboardConfig.NameCacheSeconds = 3600
LeaderboardConfig.NameBatchSize = 100

-- Payload bounds.
LeaderboardConfig.NameMaxChars = 24
LeaderboardConfig.MaxPayloadChars = 8000
-- Largest stored integer we ever write / accept (2^53: exact in a double, < OrderedDataStore 2^63).
LeaderboardConfig.MaxStored = 2 ^ 53
-- Largest display value accepted in a payload (cash goes to ~1e300).
LeaderboardConfig.MaxDisplay = 1e300
-- Distinct players this server remembers for its in-memory ("server" scope) boards.
LeaderboardConfig.ServerBoardSize = 200

-- Log encoding: stored = round(log10(value) * LogScale). 308 * 1e13 = 3.08e15 < 2^53.
LeaderboardConfig.LogScale = 1e13
-- Decoded log values are rounded to this many significant digits (removes float noise).
LeaderboardConfig.DecodeDigits = 12

-- ReplicatedStorage folder holding one StringValue per board (named by BoardId).
LeaderboardConfig.ContainerName = "Leaderboards"

-- ─── Hub boards ───────────────────────────────────────────────────────────────────────────────

-- CollectionService tag on the invisible screen parts (attribute "BoardId" names the board).
LeaderboardConfig.ScreenTag = "SellNukesLeaderboardScreen"
LeaderboardConfig.BoardAttribute = "BoardId"

LeaderboardConfig.Board = table.freeze({
	modelName = "Leaderboards",
	-- Fallback placement (world) until B8e's HubLayout.leaderboards exists: three boards side by
	-- side north of the hub centre, faces looking at the centre.
	fallbackCentre = Vector3.new(0, 0, -70),
	fallbackSpacing = 22,
	faceSize = Vector2.new(16, 12), -- default face size (studs)
	faceBottom = 3, -- fallback: studs between the ground and the face's bottom edge
	frame = 0.6, -- fallback backing border
	depth = 0.8, -- fallback backing thickness
	-- Client rendering.
	pixelsPerStud = 50,
	maxDistance = 170, -- SurfaceGui culling distance (studs)
	colors = table.freeze({
		backing = Color3.fromRGB(38, 44, 70),
		trim = Color3.fromRGB(255, 205, 60),
		post = Color3.fromRGB(70, 56, 44),
	}),
})

-- ─── Helpers (pure; server + client) ──────────────────────────────────────────────────────────

-- True for a finite number.
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- `value` rounded to `digits` significant digits.
local function roundSignificant(value: number, digits: number): number
	if value == 0 then
		return 0
	end
	local magnitude = math.floor(math.log10(math.abs(value)))
	local factor = 10 ^ (digits - 1 - magnitude)
	return math.floor(value * factor + 0.5) / factor
end

--[[
	The integer to store for a display value, or nil when it must not be ranked (< 1, junk).
	Log boards: round(log10(value) * LogScale); int boards: floor(value). Both clamp to MaxStored.
	Example: LeaderboardConfig.encode(LeaderboardConfig.ById.Rebirths, 3.7) --> 3
]]
function LeaderboardConfig.encode(def: BoardDef, value: number): number?
	if not finite(value) or value < 1 then
		return nil
	end
	if def.encoding == "log" then
		local stored =
			math.floor(math.log10(math.min(value, LeaderboardConfig.MaxDisplay)) * LeaderboardConfig.LogScale + 0.5)
		-- log10(1) = 0 would store 0 (never ranked): the smallest ranked cash value is 1 -> 1.
		return math.clamp(stored, 1, LeaderboardConfig.MaxStored)
	end
	return math.min(math.floor(value), LeaderboardConfig.MaxStored)
end

--[[
	The display value of a stored integer (inverse of encode, 12 significant digits for log
	boards). Example: decode(Cash, encode(Cash, 1000)) --> 1000
]]
function LeaderboardConfig.decode(def: BoardDef, stored: number): number
	if not finite(stored) or stored < 1 then
		return 0
	end
	if def.encoding == "log" then
		local value = 10 ^ (stored / LeaderboardConfig.LogScale)
		return math.min(roundSignificant(value, LeaderboardConfig.DecodeDigits), LeaderboardConfig.MaxDisplay)
	end
	return math.floor(stored)
end

--[[
	OrderedDataStore name of a board (Studio gets its own stores).
	Example: storeName("Rebirths", true) --> "SellNukesLB_v1_Rebirths_Studio"
]]
function LeaderboardConfig.storeName(boardId: BoardId, studio: boolean): string
	local name = `{LeaderboardConfig.StoreBase}_{boardId}`
	return if studio then name .. LeaderboardConfig.StudioSuffix else name
end

--[[
	Cleans a display name: control characters become spaces, invalid UTF-8 / blank is rejected,
	cut to NameMaxChars characters. @return the cleaned name or nil
]]
function LeaderboardConfig.cleanName(value: unknown): string?
	if type(value) ~= "string" or value == "" then
		return nil
	end
	local length = utf8.len(value)
	if length == nil then
		return nil
	end
	local text = string.gsub(value, "%c", " ")
	if length > LeaderboardConfig.NameMaxChars then
		local cut = utf8.offset(text, LeaderboardConfig.NameMaxChars + 1)
		if cut ~= nil then
			text = string.sub(text, 1, cut - 1)
		end
	end
	if string.match(text, "^%s*$") ~= nil then
		return nil
	end
	return text
end

--[[ Label for a user whose name could not be resolved. ]]
function LeaderboardConfig.fallbackName(userId: number): string
	return `Player #{userId}`
end

-- A whole number in [0, max] or nil.
local function whole(value: unknown, max: number): number?
	if type(value) ~= "number" or value ~= value or value < 0 or value > max or value % 1 ~= 0 then
		return nil
	end
	return value
end

--[[
	Validates a decoded payload (client side, on every StringValue change). Malformed payloads are
	rejected (nil); single malformed entries are dropped; duplicate users keep their first row.
	@param expected the board the StringValue belongs to
]]
function LeaderboardConfig.parsePayload(decoded: unknown, expected: BoardId): Payload?
	if type(decoded) ~= "table" then
		return nil
	end
	local raw = decoded :: { [string]: unknown }
	if raw.board ~= expected then
		return nil
	end
	local entries: { Entry } = {}
	local seen: { [number]: boolean } = {}
	local list = raw.entries
	if type(list) == "table" then
		for _, item in list :: { unknown } do
			if #entries >= LeaderboardConfig.TopN then
				break
			end
			if type(item) ~= "table" then
				continue
			end
			local row = item :: { [string]: unknown }
			local userId = whole(row.userId, 2 ^ 53)
			local rank = whole(row.rank, LeaderboardConfig.TopN)
			local value = row.value
			if
				userId == nil
				or userId <= 0
				or rank == nil
				or rank < 1
				or not finite(value)
				or (value :: number) < 0
				or (value :: number) > LeaderboardConfig.MaxDisplay
				or seen[userId]
			then
				continue
			end
			seen[userId] = true
			table.insert(entries, {
				rank = rank,
				userId = userId,
				name = LeaderboardConfig.cleanName(row.name) or LeaderboardConfig.fallbackName(userId),
				value = value :: number,
			})
		end
	end
	table.sort(entries, function(a: Entry, b: Entry): boolean
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		return a.userId < b.userId
	end)
	return {
		board = expected,
		scope = if raw.scope == "server" then "server" else "global",
		status = if raw.status == "unavailable" then "unavailable" else "ok",
		updatedAt = whole(raw.updatedAt, 1e11) or 0,
		entries = entries,
	}
end

--[[
	The display value of a board for a profile-like table (server profile or client snapshot):
	Cash = totalEarned, Rebirths = rebirths, Playtime = stats.playSeconds; a world board (R57,
	`def.world`) = profile.worlds[world].rebirths (the snapshot's `worlds` carries it too). 0 for junk.
]]
function LeaderboardConfig.valueOf(def: BoardDef, profile: unknown): number
	if type(profile) ~= "table" then
		return 0
	end
	local data = profile :: { [string]: any }
	local value: unknown = nil
	if def.world ~= nil then
		local worlds = data.worlds
		local state = if type(worlds) == "table" then worlds[def.world] else nil
		value = if type(state) == "table" then state.rebirths else nil
	elseif def.id == "Cash" then
		value = data.totalEarned
	elseif def.id == "Rebirths" then
		value = data.rebirths
	elseif type(data.stats) == "table" then
		value = data.stats.playSeconds
	end
	return if finite(value) and (value :: number) > 0 then value :: number else 0
end

return table.freeze(LeaderboardConfig)
