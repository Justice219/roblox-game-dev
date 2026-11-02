--!strict
--[[
	Global leaderboard regressions (B11). Run:
		lune run tests/leaderboard-logic

	Proves on the shipped modules (src/shared/Config/LeaderboardConfig,
	src/server/Leaderboards/LeaderboardLogic):
	  1. Encoding: the log-encoded cash board is strictly order-preserving from $1 to 1e300, fits
	     2^53, round-trips display values (1000 -> 1000, 12 significant digits); count boards
	     store whole values; junk / < 1 is never ranked.
	  2. Write throttle: first sample writes, unchanged values never re-write, changed values wait
	     MinUserWriteSeconds unless final (leave / shutdown).
	  3. Pending writes: latest value wins, failed writes merge back without beating a newer value,
	     deterministic + limited selection, per-key filter.
	  4. Reading: page sanitizing (keys, values, duplicates, top N), competition ranks, server-scope
	     boards (eviction), payload building (decoded values, name fallback), bounded encoding.
	  5. Client validation: parsePayload drops malformed rows, rejects other boards, sorts by rank.
	  6. valueOf reads the right profile field per board (R57: the Dino board reads
	     profile.worlds.dino.rebirths).
	  7. R57 world boards: "MOST DINO REBIRTHS" stands in Dino Valley (boardsIn / boardWorlds), its
	     world exists in WorldsConfig, its icon / colour are real keys, the hub keeps 3 boards.
]]

local Loader = require("./fixtures/RobloxLoader")
local serde = require("@lune/serde")

local loader = Loader.new()
local LeaderboardConfig = loader.load("src/shared/Config/LeaderboardConfig")
local LeaderboardLogic = loader.load("src/server/Leaderboards/LeaderboardLogic")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local Cash = LeaderboardConfig.ById.Cash
local Rebirths = LeaderboardConfig.ById.Rebirths
local Playtime = LeaderboardConfig.ById.Playtime
local DinoRebirths = LeaderboardConfig.ById.DinoRebirths

-- 1. Encoding ---------------------------------------------------------------------------------------
check(#LeaderboardConfig.Boards == 5, "three hub boards + the Dino Valley board + the Moon Base board (R70)")
check(#LeaderboardConfig.boardsIn(nil) == 3 and #LeaderboardConfig.boardsIn("main") == 3, "three hub boards")
check(Cash.slot == 1 and Rebirths.slot == 2 and Playtime.slot == 3, "hub slots")
check(LeaderboardConfig.encode(Cash, 0) == nil and LeaderboardConfig.encode(Cash, 0.5) == nil, "< $1 never ranked")
check(
	LeaderboardConfig.encode(Cash, 0 / 0) == nil and LeaderboardConfig.encode(Cash, math.huge) == nil,
	"junk never ranked"
)
check(LeaderboardConfig.encode(Cash, 1) == 1, "$1 stores 1 (log10(1) = 0 is lifted)")
local previous = 0
local value = 1.5
while value < 1e300 do
	local stored = LeaderboardConfig.encode(Cash, value) :: number
	check(stored > previous, `log encoding strictly increasing at {value}`)
	check(stored % 1 == 0 and stored <= 2 ^ 53, "stored is a whole number <= 2^53")
	local decoded = LeaderboardConfig.decode(Cash, stored)
	check(math.abs(decoded - value) / value < 1e-11, `round trip at {value} (got {decoded})`)
	previous = stored
	value *= 1.37
end
for _, exact in { 1000, 123456, 1e6, 2.5e9, 448087050019 } do
	check(
		LeaderboardConfig.decode(Cash, LeaderboardConfig.encode(Cash, exact) :: number) == exact,
		`exact display value {exact}`
	)
end
check(LeaderboardConfig.encode(Cash, 1001) > LeaderboardConfig.encode(Cash, 1000), "neighbours stay ordered")
check(
	LeaderboardConfig.encode(Rebirths, 7.9) == 7 and LeaderboardConfig.decode(Rebirths, 7) == 7,
	"count board stores whole values"
)
check(LeaderboardConfig.encode(Playtime, 2 ^ 60) == 2 ^ 53, "count board clamps to 2^53")
check(LeaderboardConfig.storeName("Cash", false) == "SellNukesLB_v1_Cash", "live store name")
check(LeaderboardConfig.storeName("Playtime", true) == "SellNukesLB_v1_Playtime_Studio", "studio store name")

-- 2. Throttle ----------------------------------------------------------------------------------------
local wait = LeaderboardConfig.MinUserWriteSeconds
check(LeaderboardLogic.dueForWrite(nil, 5, 0, false), "never written: write")
check(not LeaderboardLogic.dueForWrite({ written = 5, at = 0 }, 5, 1e6, true), "unchanged: never rewrite, even final")
check(not LeaderboardLogic.dueForWrite({ written = 5, at = 0 }, 6, wait - 1, false), "changed: throttled")
check(LeaderboardLogic.dueForWrite({ written = 5, at = 0 }, 6, wait, false), "changed: due after the interval")
check(LeaderboardLogic.dueForWrite({ written = 5, at = 0 }, 6, 1, true), "final write skips the throttle")

-- 3. Pending -------------------------------------------------------------------------------------------
local pending: any = {}
check(LeaderboardLogic.setPending(pending, "S", 10, 3), "set")
check(LeaderboardLogic.setPending(pending, "S", 10, 2) and pending.S[10] == 2, "latest value wins (set semantics)")
check(
	not LeaderboardLogic.setPending(pending, "S", -1, 2) and not LeaderboardLogic.setPending(pending, "S", 11, 0),
	"invalid refused"
)
LeaderboardLogic.setPending(pending, "S", 4, 9)
LeaderboardLogic.setPending(pending, "A", 99, 1)
local writes = LeaderboardLogic.selectWrites(pending, 2, function()
	return true
end)
check(
	#writes == 2 and writes[1].store == "A" and writes[2].store == "S" and writes[2].userId == 4,
	"sorted, limited selection"
)
check(pending.A == nil and pending.S[4] == nil and pending.S[10] == 2, "selected writes removed")
LeaderboardLogic.setPending(pending, "S", 4, 12) -- a newer value arrived while 9 was in flight
LeaderboardLogic.mergeBack(pending, writes[2])
check(pending.S[4] == 12, "failed old write does not beat the newer value")
LeaderboardLogic.mergeBack(pending, writes[1])
check(pending.A[99] == 1, "failed write merges back")
local filtered = LeaderboardLogic.selectWrites(pending, 10, function(_store: string, userId: number)
	return userId == 10
end)
check(#filtered == 1 and filtered[1].userId == 10 and LeaderboardLogic.pendingCount(pending) == 2, "per-key filter")

-- 4. Reading -------------------------------------------------------------------------------------------
local page = {
	{ key = "100", value = 50 },
	{ key = "200", value = 70 },
	{ key = "300", value = 50 },
	{ key = "abc", value = 999 },
	{ key = "-4", value = 999 },
	{ key = "400", value = 0 },
	{ key = "100", value = 60 },
	{ key = "500", value = 0 / 0 },
	"junk",
}
local rows = LeaderboardLogic.sanitizePage(page, 25)
check(
	#rows == 3 and rows[1].userId == 200 and rows[2].userId == 100 and rows[2].stored == 60,
	"sanitized + dedup (best value)"
)
check(LeaderboardLogic.sanitizePage(page, 1)[1].userId == 200 and #LeaderboardLogic.sanitizePage(page, 1) == 1, "top N")
local ranks = LeaderboardLogic.ranks({
	{ userId = 1, stored = 9 },
	{ userId = 2, stored = 7 },
	{ userId = 3, stored = 7 },
	{ userId = 4, stored = 5 },
})
check(ranks[1] == 1 and ranks[2] == 2 and ranks[3] == 2 and ranks[4] == 4, "competition ranks 1, 2, 2, 4")

local board: { [number]: number } = {}
LeaderboardLogic.setServerBoard(board, 1, 10, 2)
LeaderboardLogic.setServerBoard(board, 2, 20, 2)
LeaderboardLogic.setServerBoard(board, 3, 5, 2)
check(board[3] == nil and board[1] == 10, "full board keeps better players")
LeaderboardLogic.setServerBoard(board, 3, 30, 2)
check(board[3] == 30 and board[1] == nil, "a better newcomer evicts the lowest")
LeaderboardLogic.setServerBoard(board, 2, 0, 2)
check(board[2] == nil, "value < 1 removes the user")

local cashRows =
	{ { userId = 7, stored = LeaderboardConfig.encode(Cash, 1.25e15) :: number }, { userId = 8, stored = 3 } }
local payload = LeaderboardLogic.buildPayload(
	{ def = Cash, scope = "global", status = "ok", updatedAt = 1793491200.7 },
	cashRows,
	{ [7] = "Ava\0Nuke", [8] = "" }
)
check(payload.board == "Cash" and payload.updatedAt == 1793491200, "payload header")
check(payload.entries[1].value == 1.25e15 and payload.entries[1].rank == 1, "decoded display value")
check(payload.entries[1].name == "Ava Nuke", "control characters cleaned")
check(payload.entries[2].name == "Player #8", "fallback name")
local big = { board = "Cash", scope = "global", status = "ok", updatedAt = 0, entries = {} }
for index = 1, 25 do
	big.entries[index] = { rank = index, userId = index, name = string.rep("N", 24), value = 1e300 }
end
local encoded = LeaderboardLogic.encodeBounded(big :: any, function(data: any): string
	return serde.encode("json", data)
end)
check(#encoded <= LeaderboardConfig.MaxPayloadChars, "payload bounded")

-- 5. parsePayload ----------------------------------------------------------------------------------------
local raw = {
	board = "Cash",
	scope = "server",
	status = "ok",
	updatedAt = 5,
	entries = {
		{ rank = 2, userId = 2, name = "B", value = 10 },
		{ rank = 1, userId = 1, name = "A", value = 20 },
		{ rank = 3, userId = 1, name = "dup", value = 5 },
		{ rank = 0, userId = 9, name = "bad rank", value = 5 },
		{ rank = 4, userId = 3, name = "nan", value = 0 / 0 },
		{ rank = 5, userId = 4, name = 42, value = 3 },
	},
}
local parsed = LeaderboardConfig.parsePayload(raw, "Cash")
check(parsed ~= nil and parsed.scope == "server", "parsed")
local entries = (parsed :: any).entries
check(
	#entries == 3 and entries[1].userId == 1 and entries[2].userId == 2,
	"sorted by rank, malformed + duplicates dropped"
)
check(entries[3].name == "Player #4", "bad name falls back")
check(LeaderboardConfig.parsePayload(raw, "Rebirths") == nil, "another board's payload rejected")
check(LeaderboardConfig.parsePayload("nope", "Cash") == nil, "non-table rejected")

-- 6. valueOf -----------------------------------------------------------------------------------------------
local profile = { totalEarned = 5e20, rebirths = 3, stats = { playSeconds = 7200 } }
check(LeaderboardConfig.valueOf(Cash, profile) == 5e20, "cash = totalEarned")
check(LeaderboardConfig.valueOf(Rebirths, profile) == 3, "rebirths")
check(LeaderboardConfig.valueOf(Playtime, profile) == 7200, "playtime = stats.playSeconds")
check(
	LeaderboardConfig.valueOf(Playtime, { stats = "x" }) == 0 and LeaderboardConfig.valueOf(Cash, nil) == 0,
	"junk -> 0"
)

check(LeaderboardConfig.valueOf(DinoRebirths, profile) == 0, "no worlds -> 0 Dino rebirths")
check(
	LeaderboardConfig.valueOf(DinoRebirths, { rebirths = 9, worlds = { dino = { rebirths = 4 } } }) == 4,
	"Dino board = worlds.dino.rebirths (never the main rebirths)"
)
check(LeaderboardConfig.valueOf(DinoRebirths, { worlds = { dino = { rebirths = 0 / 0 } } }) == 0, "junk Dino -> 0")

-- 7. World boards (owner R57) --------------------------------------------------------------------------------
do
	local WorldsConfig = loader.load("src/shared/Config/Worlds/WorldsConfig")
	local IconAssets = loader.load("src/shared/Config/IconAssets")
	local UIStyleConfig = loader.load("src/shared/Config/UIStyleConfig")
	check(
		DinoRebirths ~= nil and DinoRebirths.world == "dino" and DinoRebirths.title == "MOST DINO REBIRTHS",
		"MOST DINO REBIRTHS board"
	)
	check(DinoRebirths.encoding == "int" and DinoRebirths.format == "count", "count board")
	local dinoBoards = LeaderboardConfig.boardsIn("dino")
	check(#dinoBoards == 1 and dinoBoards[1].id == "DinoRebirths" and dinoBoards[1].slot == 1, "Valley slot 1")
	local worlds = LeaderboardConfig.boardWorlds()
	check(worlds[1] == "main" and table.find(worlds, "dino") ~= nil, "board worlds")
	for _, def in LeaderboardConfig.Boards do
		check(def.world == nil or WorldsConfig.get(def.world) ~= nil, `{def.id}: known world`)
		check(IconAssets.Ids[def.icon] ~= nil, `{def.id}: icon {def.icon} is an IconAssets key`)
		check(UIStyleConfig.Colors[def.color] ~= nil, `{def.id}: colour {def.color} is a UIStyleConfig colour`)
	end
	check(
		LeaderboardConfig.storeName("DinoRebirths", false) == "SellNukesLB_v1_DinoRebirths",
		"own OrderedDataStore per board"
	)
	-- R70 World 3: "MOST MOON REBIRTHS" at Moon Base, valued from worlds.moon only.
	local MoonRebirths = LeaderboardConfig.ById.MoonRebirths
	check(
		MoonRebirths ~= nil and MoonRebirths.world == "moon" and MoonRebirths.title == "MOST MOON REBIRTHS",
		"Moon board"
	)
	local moonBoards = LeaderboardConfig.boardsIn("moon")
	check(#moonBoards == 1 and moonBoards[1].id == "MoonRebirths" and moonBoards[1].slot == 1, "Moon slot 1")
	check(table.find(LeaderboardConfig.boardWorlds(), "moon") ~= nil, "moon is a board world")
	check(
		LeaderboardConfig.valueOf(
			MoonRebirths,
			{ rebirths = 9, worlds = { dino = { rebirths = 4 }, moon = { rebirths = 2 } } }
		) == 2,
		"Moon board = worlds.moon.rebirths (never main / Dino)"
	)
	check(LeaderboardConfig.valueOf(MoonRebirths, { worlds = { moon = { rebirths = -1 } } }) == 0, "junk Moon -> 0")
	check(LeaderboardConfig.storeName("MoonRebirths", false) == "SellNukesLB_v1_MoonRebirths", "Moon store")
	-- Every extra world with a hub has exactly one rebirth board in its slot 1.
	for _, def in WorldsConfig.extra() do
		local boards = LeaderboardConfig.boardsIn(def.id)
		check(#boards == 1 and boards[1].slot == 1, `{def.id} has its rebirth board`)
	end
end

print(`[leaderboard-logic] {checks} checks passed`)
