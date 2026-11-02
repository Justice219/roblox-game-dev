--!strict
--[[
	Badge regressions (B11: Welcome, areas 2-10, first manager / rebirth / hatch, Feast Master). Run:
		lune run tests/event-badges

	Proves on the shipped modules (src/shared/Config/BadgeConfig, src/server/Badges/BadgeAwardsQueue):
	  1. Catalog: 18 append-only definitions, unique keys, every id 0 (not created yet) or valid.
	  2. Qualification from profiles: new player = Welcome only; area / manager / rebirth / hatch /
	     sticker sheet each flip exactly their bit; snapshot array forms work too; (R57) Time
	     Traveler = first Dino Valley visit, Volcano Tamer = the Dino finale pad or a Dino rebirth,
	     never from Nuke Town progress.
	  3. Published catalog: exactly the first ten ids are live and unique; fresh players receive only
	     Welcome, area progression awards no unreached areas, and the unpublished tail stays inert.
	  4. Queue: zero ids are inert (no platform call ever), ownership is checked in batches of 10
	     (12 configured ids -> 2 paced calls), confirmed ownership is published, awards need an
	     explicit `true`, false / throwing awards back off and re-check ownership, metadata
	     "disabled" blocks awards until it expires, forget() cancels work mid-yield.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local BadgeConfig = loader.load("src/shared/Config/BadgeConfig")
local BadgeAwardsQueue = loader.load("src/server/Badges/BadgeAwardsQueue")
local TycoonConfig = loader.load("src/shared/Config/TycoonConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local function bit(id: string): number
	return bit32.lshift(1, BadgeConfig.IndexById[id] - 1)
end

-- 1. Catalog --------------------------------------------------------------------------------------
local defs = BadgeConfig.Definitions
check(#defs == 18, "18 badges")
check(defs[1].Id == "Welcome" and defs[2].Id == "Area2" and defs[10].Id == "Area10", "order: Welcome, Area2..Area10")
check(
	defs[11].Id == "FirstManager"
		and defs[12].Id == "FirstRebirth"
		and defs[13].Id == "FirstHatch"
		and defs[14].Id == "FeastMaster"
		and defs[15].Id == "TimeTraveler"
		and defs[16].Id == "VolcanoTamer",
	"tail order (append only)"
)
check(defs[15].World == "dino" and defs[16].World == "dino" and defs[15].BadgeId == 0, "World 2 badges (ids 0)")
-- R70 World 3 badges, appended after Dino's (mask bits are save data: append only).
check(defs[17].Id == "MoonWalker" and defs[18].Id == "StarTamer", "World 3 badges appended")
check(defs[17].World == "moon" and defs[18].World == "moon", "World 3 badges read worlds.moon")
check(defs[17].Source == "WorldVisit" and defs[18].Source == "WorldFinale", "World 3 badge sources")
do
	local walker, tamer = defs[17], defs[18]
	check(
		not BadgeConfig.qualifies({ worlds = { dino = { stats = { visits = 3 } } } }, walker),
		"a Dino visit is not a Moon visit"
	)
	check(BadgeConfig.qualifies({ worlds = { moon = { stats = { visits = 1 } } } }, walker), "first Moon visit")
	check(
		BadgeConfig.qualifies({ worlds = { moon = { tycoon = { pads = { m6_golden_astronaut = true } } } } }, tamer),
		"own the Golden Astronaut"
	)
	check(BadgeConfig.qualifies({ worlds = { moon = { rebirths = 1 } } }, tamer), "or a Moon rebirth")
	check(
		not BadgeConfig.qualifies({ worlds = { dino = { rebirths = 4 } } }, tamer),
		"a Dino rebirth is not a Moon finale"
	)
end
for _, def in defs do
	check(def.BadgeId == 0 or BadgeConfig.isConfigured(def.BadgeId), `{def.Id} id valid or 0`)
	check(#def.Name > 0 and #def.Name <= 50 and #def.Description <= 1000, `{def.Id} name / description lengths`)
end
check(defs[2].Name == TycoonConfig.Areas[2].name, "area badges use the area names")

-- 2. Qualification --------------------------------------------------------------------------------
local fresh = {
	tycoon = { area = 1, pads = {} },
	rebirths = 0,
	stats = { hatched = 0 },
	event = { stickers = {}, redeemed = false },
}
check(BadgeConfig.qualifiedMask(fresh) == bit("Welcome"), "a new player qualifies for Welcome only")
fresh.tycoon.area = 4
local mask = BadgeConfig.qualifiedMask(fresh)
check(
	bit32.band(mask, bit("Area4")) ~= 0 and bit32.band(mask, bit("Area2")) ~= 0 and bit32.band(mask, bit("Area5")) == 0,
	"areas up to the current one"
)
local managerPad: string? = nil
for id, pad in TycoonConfig.PadsById do
	if pad.kind == "Manager" then
		managerPad = id
		break
	end
end
check(managerPad ~= nil, "the economy has a manager pad")
fresh.tycoon.pads[managerPad :: string] = true
check(bit32.band(BadgeConfig.qualifiedMask(fresh), bit("FirstManager")) ~= 0, "manager pad (set form)")
check(BadgeConfig.qualifies({ tycoon = { pads = { managerPad } } }, defs[11]), "manager pad (snapshot array form)")
fresh.rebirths = 1
fresh.stats.hatched = 3
check(
	bit32.band(BadgeConfig.qualifiedMask(fresh), bit("FirstRebirth") + bit("FirstHatch"))
		== bit("FirstRebirth") + bit("FirstHatch"),
	"rebirth + hatch"
)
local sheet = {}
for index = 1, 19 do
	sheet[index] = true
end
fresh.event.stickers = sheet
check(bit32.band(BadgeConfig.qualifiedMask(fresh), bit("FeastMaster")) == 0, "19 stickers: not yet")
sheet[20] = true
check(bit32.band(BadgeConfig.qualifiedMask(fresh), bit("FeastMaster")) ~= 0, "20 stickers qualify")
check(
	BadgeConfig.qualifies({ event = { stickers = {}, redeemed = true } }, defs[14]),
	"redeemed (new season) still qualifies"
)
check(BadgeConfig.qualifiedMask("junk") == 0, "junk profile qualifies for nothing")
do
	-- R57 World 2 badges read profile.worlds.dino only.
	local traveler, tamer = defs[15], defs[16]
	check(
		bit32.band(BadgeConfig.qualifiedMask(fresh), bit("TimeTraveler") + bit("VolcanoTamer")) == 0,
		"Nuke Town progress (rebirth, finale-less) never earns a world badge"
	)
	local dino = { stats = { visits = 0 }, tycoon = { pads = {}, area = 1 }, rebirths = 0 }
	local withWorld = { worlds = { dino = dino } }
	check(not BadgeConfig.qualifies(withWorld, traveler), "unlocked but never visited")
	dino.stats.visits = 1
	check(BadgeConfig.qualifies(withWorld, traveler), "first visit = Time Traveler")
	check(not BadgeConfig.qualifies(withWorld, tamer), "no finale yet")
	dino.tycoon.pads["d6_golden_trex"] = true
	check(BadgeConfig.qualifies(withWorld, tamer), "Dino finale pad (set form) = Volcano Tamer")
	check(
		BadgeConfig.qualifies({ worlds = { dino = { tycoon = { pads = { "d6_golden_trex" } } } } }, tamer),
		"Dino finale pad (snapshot array form)"
	)
	check(
		BadgeConfig.qualifies({ worlds = { dino = { rebirths = 1, tycoon = { pads = {} } } } }, tamer),
		"a Dino rebirth (pads reset) keeps Volcano Tamer"
	)
	check(
		not BadgeConfig.qualifies({ worlds = { dino = { rebirths = 0 / 0, stats = { visits = "x" } } } }, tamer)
			and not BadgeConfig.qualifies({ worlds = "junk" }, traveler),
		"junk world data qualifies for nothing"
	)
end

-- 3. Published catalog integration ----------------------------------------------------------------
-- Exercise the shipped ids through the real worker: new players get Welcome, progression awards
-- only reached Nuke Town areas, and qualifying for unpublished milestones never sends id 0 to Roblox.
do
	local publishedIds: { number } = {}
	local configuredById: { [number]: number } = {}
	for index, def in defs do
		table.insert(publishedIds, def.BadgeId)
		if index <= 10 then
			check(BadgeConfig.isConfigured(def.BadgeId), `{def.Id} is published`)
			check(configuredById[def.BadgeId] == nil, `{def.Id} has a unique platform id`)
			configuredById[def.BadgeId] = index
		else
			check(def.BadgeId == 0, `{def.Id} remains unpublished`)
		end
	end

	local now = 0
	local awarded: { [number]: boolean } = {}
	local awardCount = 0
	local ownershipCalls = 0
	local metadataCalls = 0
	local confirmedMask = 0
	local publishedQueue = BadgeAwardsQueue.new(publishedIds, {
		now = function(): number
			return now
		end,
		isCurrent = function(userId: number): boolean
			return userId == 42
		end,
		checkOwnedAsync = function(_userId: number, requested: { number }): { number }
			ownershipCalls += 1
			check(#requested == 10, "ownership checks contain exactly the ten published badges")
			for _, id in requested do
				check(configuredById[id] ~= nil, "ownership checks never include unpublished badges")
			end
			return {}
		end,
		isEnabledAsync = function(id: number): boolean
			metadataCalls += 1
			check(configuredById[id] ~= nil, "metadata checks never include unpublished badges")
			return true
		end,
		awardAsync = function(_userId: number, id: number): boolean
			check(configuredById[id] ~= nil, "awards never include unpublished badges")
			check(awarded[id] == nil, "progression never awards the same platform id twice")
			awarded[id] = true
			awardCount += 1
			return true
		end,
		publish = function(_userId: number, owned: number)
			confirmedMask = owned
		end,
	}, BadgeConfig.Worker, BadgeConfig.OwnershipBatch)

	-- Advance the fake clock until the production queue is idle; a bound catches retry loops.
	local function drainPublished()
		for _ = 1, 40 do
			local delay = publishedQueue.nextDelay()
			if delay == nil then
				return
			end
			now += delay
			publishedQueue.stepAsync()
		end
		error("published badge queue did not become idle")
	end

	local profile = { tycoon = { area = 1 } }
	publishedQueue.observe(42, BadgeConfig.qualifiedMask(profile))
	drainPublished()
	check(awardCount == 1 and awarded[defs[1].BadgeId] == true, "new players receive Welcome only")
	check(confirmedMask == bit("Welcome"), "new-player ownership includes no unreached area")
	profile.tycoon.area = 4
	publishedQueue.observe(42, BadgeConfig.qualifiedMask(profile))
	drainPublished()
	check(awardCount == 4 and confirmedMask == 15, "area 4 awards Welcome and areas 2-4 only")
	check(awarded[defs[5].BadgeId] == nil, "area 5 stays unawarded until reached")
	profile.tycoon.area = 5
	publishedQueue.observe(42, BadgeConfig.qualifiedMask(profile))
	drainPublished()
	check(awardCount == 5 and confirmedMask == 31, "area 5 confirms precisely the first five badges")
	check(awarded[defs[6].BadgeId] == nil, "area 6 stays unawarded at the end of the first badge batch")
	profile.tycoon.area = 6
	publishedQueue.observe(42, BadgeConfig.qualifiedMask(profile))
	drainPublished()
	check(awardCount == 6 and confirmedMask == 63, "area 6 awards Rocket Factory at its existing mask bit")
	check(awarded[defs[7].BadgeId] == nil, "area 6 does not award Launch Silos early")
	profile.tycoon.area = 9
	publishedQueue.observe(42, BadgeConfig.qualifiedMask(profile))
	drainPublished()
	check(awardCount == 9 and confirmedMask == 511, "area 9 backfills reached areas 7-9")
	check(awarded[defs[10].BadgeId] == nil, "area 9 does not award Mega Nuclear Facility early")
	profile.tycoon.area = 10
	publishedQueue.observe(42, BadgeConfig.qualifiedMask(profile))
	drainPublished()
	check(awardCount == 10 and confirmedMask == 1023, "area 10 confirms all ten configured badges")

	-- Qualify every unpublished source too: zero ids must stay inert even when the player earned
	-- the underlying manager, rebirth, hatch, sticker-sheet and extra-world achievements.
	local allMilestones = {
		tycoon = { area = 10, pads = { [managerPad :: string] = true } },
		rebirths = 1,
		stats = { hatched = 1 },
		event = { redeemed = true },
		worlds = {
			dino = { stats = { visits = 1 }, rebirths = 1 },
			moon = { stats = { visits = 1 }, rebirths = 1 },
		},
	}
	local allMask = BadgeConfig.qualifiedMask(allMilestones)
	check(allMask == 2 ^ #defs - 1, "the zero-id tail is exercised with every milestone qualified")
	publishedQueue.observe(42, allMask)
	drainPublished()
	check(awardCount == 10 and confirmedMask == 1023, "unpublished milestones never create platform awards")
	check(metadataCalls == 10, "unpublished milestones never create metadata calls")
	check(ownershipCalls == 1, "all ten live badges share one initial ownership batch")

	-- Rebirth resets only current-run qualification. Higher-world progress cannot backfill Nuke
	-- Town areas, while the queue retains already-confirmed permanent platform ownership.
	local reborn = {
		tycoon = { area = 1 },
		rebirths = 1,
		lastWorld = "moon",
		worlds = {
			dino = { tycoon = { area = 6 }, stats = { visits = 1 }, rebirths = 1 },
			moon = { tycoon = { area = 6 }, stats = { visits = 1 }, rebirths = 1 },
		},
	}
	local rebornMask = BadgeConfig.qualifiedMask(reborn)
	check(bit32.band(rebornMask, 1023) == bit("Welcome"), "rebirth and extra worlds do not qualify Nuke Town areas")
	publishedQueue.observe(42, rebornMask)
	drainPublished()
	check(awardCount == 10 and confirmedMask == 1023, "confirmed ownership survives the current-run reset")
end

-- 4. Queue ----------------------------------------------------------------------------------------------
local clock = 0
local current: { [number]: boolean } = {}
local calls = { owned = 0, enabled = 0, award = 0 }
local ownedOnPlatform: { [number]: { [number]: boolean } } = {}
local awardResult: boolean | string = true
local enabledResult = true
local published: { [number]: number } = {}
local lastOwnedRequest: { number } = {}

local ids: { number } = {}
for index = 1, 14 do
	ids[index] = if index == 3 or index == 14 then 0 else 1000 + index -- two not created yet
end
local deps = {
	now = function(): number
		return clock
	end,
	isCurrent = function(userId: number): boolean
		return current[userId] == true
	end,
	checkOwnedAsync = function(userId: number, requested: { number }): { number }
		calls.owned += 1
		check(#requested <= 10, "ownership batch <= 10")
		for _, id in requested do
			check(id ~= 0, "zero ids never reach CheckUserBadgesAsync")
		end
		lastOwnedRequest = requested
		local result: { number } = {}
		for _, id in requested do
			if (ownedOnPlatform[userId] or {})[id] then
				table.insert(result, id)
			end
		end
		return result
	end,
	isEnabledAsync = function(id: number): boolean
		check(id ~= 0, "zero ids never reach GetBadgeInfoAsync")
		calls.enabled += 1
		return enabledResult
	end,
	awardAsync = function(_userId: number, id: number): boolean
		check(id ~= 0, "zero ids never reach AwardBadgeAsync")
		calls.award += 1
		if awardResult == "throw" then
			error("platform down")
		end
		return awardResult == true
	end,
	publish = function(userId: number, owned: number)
		published[userId] = owned
	end,
}
local queue = BadgeAwardsQueue.new(ids, deps, BadgeConfig.Worker, BadgeConfig.OwnershipBatch)

-- Run the queue until idle (advancing the fake clock to each due time).
local function drain(maxSteps: number)
	for _ = 1, maxSteps do
		local delay = queue.nextDelay()
		if delay == nil then
			return
		end
		clock += delay
		queue.stepAsync()
	end
end

check(queue.nextDelay() == nil, "idle queue schedules nothing")
current[1] = true
ownedOnPlatform[1] = { [1001] = true } -- Welcome already owned (returning veteran)
queue.observe(1, bit32.bor(bit("Welcome"), bit("Area2"), bit("Area3"), bit("FeastMaster")))
drain(50)
check(calls.owned == 2, `12 configured ids -> 2 ownership batches (got {calls.owned})`)
check(#lastOwnedRequest == 2, "second batch holds the remaining 2 ids")
local owned = published[1] or 0
check(bit32.band(owned, bit("Welcome")) ~= 0, "returning ownership published")
check(bit32.band(owned, bit("Area2")) ~= 0, "Area2 awarded (explicit true)")
check(bit32.band(owned, bit("Area3")) == 0, "Area3 has id 0: skipped")
check(bit32.band(owned, bit("FeastMaster")) == 0, "FeastMaster has id 0: skipped")
check(calls.award == 1, "exactly one award call (Area2)")

-- False award: backs off and re-checks ownership; true later succeeds.
awardResult = false
queue.observe(1, bit32.bor(queue.owned(1), bit("Area4")))
local ownedCallsBefore = calls.owned
-- Step until the award attempt happens (a metadata read for Area4 comes first).
for _ = 1, 5 do
	if calls.award >= 2 then
		break
	end
	clock += (queue.nextDelay() or 0)
	queue.stepAsync()
end
check(calls.award == 2 and bit32.band(queue.owned(1), bit("Area4")) == 0, "false award does not grant")
check((queue.nextDelay() :: number) >= BadgeConfig.Worker.RetryBase - 1e-6, "backoff after a false award")
awardResult = true
drain(50)
check(calls.owned > ownedCallsBefore, "a false award re-checks ownership")
check(bit32.band(queue.owned(1), bit("Area4")) ~= 0, "retry succeeds")

-- Throwing award: no grant, retry later.
awardResult = "throw"
queue.observe(1, bit32.bor(queue.owned(1), bit("Area5")))
clock += 400
drain(3)
check(bit32.band(queue.owned(1), bit("Area5")) == 0, "a throwing award never grants")
awardResult = true
drain(60)
check(bit32.band(queue.owned(1), bit("Area5")) ~= 0, "recovers after the outage")

-- Disabled badge: metadata says disabled -> no award until the TTL expires.
local awardsBefore = calls.award
enabledResult = false
current[2] = true
queue.observe(2, bit("Area6"))
clock += 1000
drain(4)
check(calls.award == awardsBefore, "disabled badge never awarded")
enabledResult = true
clock += BadgeConfig.Worker.MetadataTTL + 1
drain(20)
check(bit32.band(queue.owned(2), bit("Area6")) ~= 0, "re-enabled badge awarded after the TTL")

-- forget() cancels: a player who left is never published again.
current[3] = true
queue.observe(3, bit("Area7"))
queue.forget(3)
current[3] = nil
drain(10)
check(published[3] == nil, "forgotten player gets nothing")
check(queue.nextDelay() == nil, "idle again")

print(`[event-badges] {checks} checks passed`)
