--!strict
--[[
	Big Pop broadcast regressions (owner R89, spec 2026-10-31-r89 §1; src/server/Tycoon/BigPop). Run:
		lune run tests/big-pop

	Proves on the shipped module (Remotes faked so FireAllClients is recorded):
	  1. A first pop goes out on the next step; the payload carries display names + config labels
	     only (userId, name, kind, id, label, oneIn, at) and `more`.
	  2. Global gap: nothing goes out again before FlavorConfig.BigPop.GapSeconds; queued pops wait.
	  3. Per player: a second pop inside PlayerCooldown is dropped; while one is still queued a
	     BETTER one replaces it, a weaker one is dropped.
	  4. Coalescing: more than MaxPending players → the weakest are folded into `more` (or evicted by
	     a better one); a broadcast carries at most MaxPerBroadcast entries, best score first, and
	     `more` counts every other pop.
	  5. Junk announcements (bad kind, non-string labels, NaN / huge odds, non-Vector3 spots, a
	     player who left) are refused or sanitised; labels / names are capped.
	  6. Kill switch: setEnabled(false) drops the queue and refuses new pops; on again works.
]]

local Loader = require("./fixtures/RobloxLoader")
local roblox = require("@lune/roblox")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

-- Fake Remotes folder: one recording RemoteEvent per name.
local sent: { { name: string, payload: any } } = {}
local function fakeRemote(name: string): any
	return {
		Name = name,
		IsA = function(_self: any, class: string): boolean
			return class == "RemoteEvent"
		end,
		FireAllClients = function(_self: any, payload: any)
			table.insert(sent, { name = name, payload = payload })
		end,
	}
end
local folder = {
	IsA = function(_self: any, class: string): boolean
		return class == "Folder"
	end,
	WaitForChild = function(_self: any, name: string): any
		return fakeRemote(name)
	end,
}
local PlayersStub: any = {
	GetPlayers = function()
		return {}
	end,
}
local loader = Loader.new({
	Players = PlayersStub,
	ReplicatedStorage = {
		Shared = Loader.node("src/shared"),
		WaitForChild = function(_self: any, _name: string): any
			return folder
		end,
	},
})
local FlavorConfig = loader.load("src/shared/Config/FlavorConfig")
local BigPop = loader.load("src/server/Tycoon/BigPop")
local Config = FlavorConfig.BigPop

local function player(userId: number, name: string?): any
	return { UserId = userId, DisplayName = name or `Player{userId}`, Parent = PlayersStub, Character = nil }
end

local function batch(score: number?): any
	return {
		kind = "batch",
		id = "galaxy",
		label = "GALAXY batch",
		oneIn = 2500,
		score = score or 60,
		at = roblox.Vector3.new(1, 2, 3),
	}
end

local now = os.clock() + 1000 -- step clock far past the module's start (lastBroadcast = -inf)

-- 1. First pop.
local alex = player(1, "Alex")
check(BigPop.announce(alex, batch()) == true, "first pop queued")
check(BigPop.step(now) == true and #sent == 1, "first pop broadcast on the next step")
local payload = sent[1].payload
check(sent[1].name == "BigPop", "on the BigPop remote")
check(#payload.entries == 1 and payload.more == 0, "one entry, nothing folded")
local entry = payload.entries[1]
check(entry.userId == 1 and entry.name == "Alex" and entry.kind == "batch", "entry identity")
check(entry.id == "galaxy" and entry.label == "GALAXY batch" and entry.oneIn == 2500, "entry labels")
check(typeof(entry.at) == "Vector3" and entry.score == nil, "spot sent, score kept server-side")

-- 2. Global gap.
local sam = player(2, "Sam")
check(BigPop.announce(sam, batch()) == true, "second player queued")
check(BigPop.step(now + Config.GapSeconds - 0.1) == false, "nothing inside the global gap")
check(BigPop.step(now + Config.GapSeconds) == true and #sent == 2, "goes out after the gap")
now += Config.GapSeconds

-- 3. Per-player cooldown + replace-better.
check(BigPop.announce(alex, batch()) == false, "Alex is cooling down")
local kim = player(3, "Kim")
check(BigPop.announce(kim, batch(45)) == true, "Kim queued (weak)")
check(BigPop.announce(kim, batch(40)) == false, "a weaker pop does not replace")
check(BigPop.announce(kim, batch(65)) == true, "a better pop replaces the queued one")
now += Config.GapSeconds
check(BigPop.step(now) == true, "Kim broadcast")
check(#sent[#sent].payload.entries == 1, "one entry per player")
check(sent[#sent].payload.entries[1].label == "GALAXY batch", "Kim's better entry")

-- 4. Coalescing.
local crowd = {}
for index = 1, Config.MaxPending + 3 do
	crowd[index] = player(100 + index)
end
local queued = 0
for index, member in crowd do
	-- Scores rise with the index, so the last ones evict the first ones.
	if BigPop.announce(member, batch(40 + index)) then
		queued += 1
	end
end
check(queued == #crowd, "better arrivals evict the weakest (all accepted)")
now += Config.GapSeconds
check(BigPop.step(now) == true, "crowd broadcast")
local crowdPayload = sent[#sent].payload
check(#crowdPayload.entries == Config.MaxPerBroadcast, "at most MaxPerBroadcast entries")
check(crowdPayload.entries[1].userId == 100 + #crowd, "best score first")
check(crowdPayload.more == #crowd - Config.MaxPerBroadcast, `more counts every other pop ({crowdPayload.more})`)
-- A weaker arrival into a full queue is folded into `more`.
local full = {}
for index = 1, Config.MaxPending do
	full[index] = player(200 + index)
	BigPop.announce(full[index], batch(80))
end
check(BigPop.announce(player(299), batch(10)) == false, "a weaker arrival into a full queue is folded")
now += Config.GapSeconds
BigPop.step(now)
check(sent[#sent].payload.more == Config.MaxPending - Config.MaxPerBroadcast + 1, "the folded pop is counted")

-- 5. Junk.
local junk = player(400)
check(BigPop.announce(junk, { kind = "nuke", id = "x", label = "y", oneIn = 1, score = 1 } :: any) == false, "bad kind")
check(BigPop.announce(junk, { kind = "batch", id = 5, label = "y", oneIn = 1, score = 1 } :: any) == false, "bad id")
check(BigPop.announce(junk, { kind = "batch", id = "x", label = nil, oneIn = 1, score = 1 } :: any) == false, "bad label")
local gone = player(401)
gone.Parent = nil
check(BigPop.announce(gone, batch()) == false, "a player who left is refused")
local long = player(402, string.rep("N", 200))
check(
	BigPop.announce(long, {
		kind = "hatch",
		id = string.rep("i", 99),
		label = string.rep("L", 300),
		oneIn = 0 / 0,
		score = 0 / 0,
		at = "here",
	} :: any) == true,
	"junk fields are sanitised"
)
now += Config.GapSeconds
BigPop.step(now)
local cleaned = sent[#sent].payload.entries[1]
check(#cleaned.name <= 40 and #cleaned.id <= 24 and #cleaned.label <= 48, "names / labels capped")
check(cleaned.oneIn == 0 and cleaned.at == nil, "NaN odds → 0, non-Vector3 spot dropped")
check(BigPop.announce(player(403), { kind = "batch", id = "g", label = "G", oneIn = 1e300, score = 1 }) == true, "huge odds")
now += Config.GapSeconds
BigPop.step(now)
check(sent[#sent].payload.entries[1].oneIn == 0, "huge odds → 0")

-- 6. Kill switch.
BigPop.announce(player(500), batch())
BigPop.setEnabled(false)
check(not BigPop.isEnabled(), "off")
local before = #sent
now += Config.GapSeconds
check(BigPop.step(now) == false and #sent == before, "off drops the queue")
check(BigPop.announce(player(501), batch()) == false, "off refuses new pops")
BigPop.setEnabled(true)
check(BigPop.announce(player(502), batch()) == true, "on again")
now += Config.GapSeconds
check(BigPop.step(now) == true, "broadcasts again")
local stats = BigPop.stats()
check(stats.sent == #sent and stats.entries >= stats.sent and stats.dropped > 0, "counters")

print(`[big-pop] {checks} checks passed`)
