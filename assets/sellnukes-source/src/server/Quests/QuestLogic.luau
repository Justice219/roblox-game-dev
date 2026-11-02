--!strict
--[[
	QuestLogic — the PURE mutations of profile.quests (owner R78 Quests, spec §1). No services, no
	yields, no clocks: every input (today's UTC day, the user id, the progress tier, whether the
	Harvest Feast is live, the profile facts) is passed in, so tests/quest-logic.luau drives the
	exact shipped rules. Server/Services/QuestService is the live boundary (remotes, rewards,
	analytics, pushes).

	Rules (QuestConfig holds the numbers and the read-only views):
		startChain(state)            records starter.base for counter goals (once)
		rollDay(state, today, ...)   new UTC day → three fresh missions (seeded, see below); a clock
		                             running BACKWARDS (today < stored day) opens nothing
		applyProgress(state, stat, amount, today)
		                             life counters + today's matching missions (capped at target)
		advanceStarter(state, facts) completes goals IN ORDER while the next one is satisfied (sticky)
		claimStarter / claimDaily / claimChest / claimTrophy
		                             flip the claim flag (idempotent: a second claim is refused), the
		                             caller grants the returned reward in the SAME non-yielding step
		reroll(state, slot, ...)     the one free reroll: swaps an unfinished, unclaimed mission for a
		                             stat not already shown
		readClaim / readSlot         validate raw remote arguments (typeof, ranges, config ids)

	Seeding (spec "seeded Random(userId, day)"): a portable 32-bit hash of (userId, day, salt) feeds
	an xorshift32 generator built on bit32 — identical results on every Roblox server AND under Lune,
	so the tests prove the real picks (Roblox's Random has no Lune equivalent). The pool is the
	mission list minus event-only missions outside the event, minus stats already shown; a partial
	Fisher-Yates shuffle draws distinct stats, so no two missions ever share a stat.

	Example:
		local facts = QuestConfig.facts(profile)
		QuestLogic.rollDay(profile.quests, QuestConfig.utcDay(os.time()), player.UserId, QuestConfig.tierOf(facts), false)
		local done = QuestLogic.applyProgress(profile.quests, "click", 1, today)
		local goals = QuestLogic.advanceStarter(profile.quests, facts)
		local ok, code, reward, xp = QuestLogic.claimStarter(profile.quests, 1)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

type State = QuestConfig.State
type Facts = QuestConfig.Facts
type Pick = QuestConfig.Pick
type Reward = QuestConfig.Reward

export type ClaimKind = "starter" | "daily" | "chest" | "trophy"
-- A validated QuestClaim request: `index` for starter / daily, `trophy` for trophy.
export type ClaimRequest = { kind: ClaimKind, index: number?, trophy: string? }
-- Refusal codes (QuestService turns them into toasts).
export type Code = "ok" | "locked" | "claimed" | "unknown" | "stale" | "used" | "done" | "empty"

local QuestLogic = {}

QuestLogic.ClaimKinds = table.freeze({ "starter", "daily", "chest", "trophy" }) :: { ClaimKind }

local TWO32 = 4_294_967_296
local FNV_OFFSET = 2_166_136_261
local FNV_PRIME = 16_777_619
-- Salts keep the reroll draw independent of the daily draw.
local SALT_DAILY = 1
local SALT_REROLL = 2

--------------------------------------------------------------------------------------------------
-- Portable deterministic random (no Random, no clock)
--------------------------------------------------------------------------------------------------

--[[
	(a * b) mod 2^32 without losing precision in a double (both operands < 2^32): split into 16-bit
	halves so every partial product stays below 2^53.
]]
local function mul32(a: number, b: number): number
	local aLo, aHi = a % 65536, a // 65536
	local bLo, bHi = b % 65536, b // 65536
	return (aLo * bLo + ((aHi * bLo + aLo * bHi) % 65536) * 65536) % TWO32
end

--[[
	FNV-1a over the 8 bytes of each (whole) input number → a 32-bit seed (never 0, xorshift's
	only fixed point). Negative user ids (Studio test players) hash fine: floored modulo.
	Example: QuestLogic.seed(1586034782, 20757, 1) --> the same number on every server
]]
function QuestLogic.seed(userId: number, day: number, salt: number): number
	local h = FNV_OFFSET
	for _, value in { userId, day, salt } do
		local n = math.floor(if value == value then value else 0)
		local lo = n % TWO32
		local hi = math.floor(n / TWO32) % TWO32
		for _, word in { lo, hi } do
			local w = word
			for _ = 1, 4 do
				h = bit32.bxor(h, w % 256)
				h = mul32(h, FNV_PRIME)
				w = w // 256
			end
		end
	end
	return if h == 0 then 0x9E3779B9 else h
end

--[[
	An xorshift32 generator: returns a function giving whole numbers in [1, n].
	Example: local roll = QuestLogic.generator(QuestLogic.seed(1, 2, 3)); print(roll(9))
]]
function QuestLogic.generator(seed: number): (n: number) -> number
	local x = if seed % TWO32 == 0 then 0x9E3779B9 else seed % TWO32
	return function(n: number): number
		x = bit32.bxor(x, bit32.lshift(x, 13))
		x = bit32.bxor(x, bit32.rshift(x, 17))
		x = bit32.bxor(x, bit32.lshift(x, 5))
		return (x % math.max(1, n)) + 1
	end
end

--[[
	Draws `count` DISTINCT mission stats for (userId, day, salt) from the pool: missions in
	QuestConfig order, minus event missions when the event is off, minus `exclude`.
	@return the stats (fewer than `count` when the pool is smaller)
	Example: QuestLogic.pickStats(1, 20757, 1, false, {}, 3) --> { "pad", "gift", "click" }
]]
function QuestLogic.pickStats(
	userId: number,
	day: number,
	salt: number,
	eventLive: boolean,
	exclude: { [string]: boolean },
	count: number
): { string }
	local pool: { string } = {}
	for _, mission in QuestConfig.Missions do
		if (mission.event ~= true or eventLive) and not exclude[mission.stat] then
			table.insert(pool, mission.stat)
		end
	end
	local roll = QuestLogic.generator(QuestLogic.seed(userId, day, salt))
	local picked: { string } = {}
	-- Partial Fisher-Yates: position i swaps with a random position in [i, #pool].
	for i = 1, math.min(count, #pool) do
		local j = i + roll(#pool - i + 1) - 1
		pool[i], pool[j] = pool[j], pool[i]
		table.insert(picked, pool[i])
	end
	return picked
end

-- A mission's target for a progress tier (1..3).
local function targetOf(stat: string, tier: number): number
	local mission = QuestConfig.MissionByStat[stat]
	if mission == nil then
		return 1
	end
	return mission.targets[math.clamp(tier, 1, #mission.targets)] or mission.targets[1]
end

--------------------------------------------------------------------------------------------------
-- Mutations
--------------------------------------------------------------------------------------------------

--[[
	Starts the starter chain's counters once: base[stat] = 0 for every counter goal's stat that
	has no base yet.
	Why 0 and never the current lifetime count: the chain and the `life` counters start together
	(both with the first 0.6.0 load of the record), so 0 IS the count at chain start. Re-basing to
	`life` would erase progress whenever a base went missing — the R78 review bug: reconcile used
	to drop a stored base of 0, so every rejoin re-based `spin` to the spins already made and reset
	"Spin the Lucky Wheel" (blocking goals 6-12). Saves written while that bug existed (base
	missing) therefore migrate to 0 here, which counts every spin since 0.6.0 — the intended rule.
	@return true when anything was recorded
]]
function QuestLogic.startChain(state: State): boolean
	local changed = false
	for _, stat in QuestConfig.BaseStats do
		if state.starter.base[stat] == nil then
			state.starter.base[stat] = 0
			changed = true
		end
	end
	return changed
end

--[[
	Seeds today's missions when the stored day is older than `today`.
	@param tier      QuestConfig.tierOf(facts) at seeding time
	@param eventLive the Harvest Feast runs (turkey missions may be picked)
	@return true + the picked stats when a new day was seeded; false when it is the same day or the
	        clock is behind the stored day (nothing opens)
]]
function QuestLogic.rollDay(
	state: State,
	today: number,
	userId: number,
	tier: number,
	eventLive: boolean
): (boolean, { string })
	local daily = state.daily
	if daily.day >= today then
		return false, {}
	end
	local stats = QuestLogic.pickStats(userId, today, SALT_DAILY, eventLive, {}, QuestConfig.MissionsPerDay)
	local picks: { Pick } = {}
	for _, stat in stats do
		table.insert(picks, { stat = stat, target = targetOf(stat, tier), progress = 0, claimed = false })
	end
	daily.day = today
	daily.picks = picks
	daily.chest = false
	daily.rerolled = false
	return true, stats
end

--[[
	Counts `amount` of `stat`: the lifetime counter (LifeStats only) and today's missions of that
	stat (only when the record is on `today`; capped at the target).
	@return the mission slots that JUST finished, and whether anything changed
	Example: QuestLogic.applyProgress(state, "pad", 1, today) --> { 2 }, true
]]
function QuestLogic.applyProgress(state: State, stat: string, amount: number, today: number): ({ number }, boolean)
	local finished: { number } = {}
	if
		not QuestConfig.isStat(stat)
		or type(amount) ~= "number"
		or amount ~= amount
		or amount < 1
		or amount == math.huge
	then
		return finished, false
	end
	local add = math.min(math.floor(amount), QuestConfig.MaxCounter)
	local changed = false
	if QuestConfig.isLifeStat(stat) then
		state.life[stat] = math.min((state.life[stat] or 0) + add, QuestConfig.MaxCounter)
		changed = true
	end
	local daily = state.daily
	if daily.day == today then
		for slot, pick in daily.picks do
			if pick.stat == stat and pick.progress < pick.target then
				pick.progress = math.min(pick.target, pick.progress + add)
				changed = true
				if pick.progress >= pick.target then
					table.insert(finished, slot)
				end
			end
		end
	end
	return finished, changed
end

--[[
	Completes starter goals IN ORDER while the next goal's progress has reached its target. The
	step is sticky: a rebirth never takes a completed goal back.
	@return the goal indices completed now (ascending)
]]
function QuestLogic.advanceStarter(state: State, facts: Facts): { number }
	local completed: { number } = {}
	local starter = state.starter
	while starter.step < QuestConfig.GoalCount do
		local goal = QuestConfig.Goals[starter.step + 1]
		if QuestConfig.goalProgress(goal, facts, state) < goal.target then
			break
		end
		starter.step += 1
		table.insert(completed, starter.step)
	end
	return completed
end

--[[
	Admin: completes the current starter goal regardless of its progress.
	@return the completed goal index, or nil when every goal is already completed
]]
function QuestLogic.forceStep(state: State): number?
	local starter = state.starter
	if starter.step >= QuestConfig.GoalCount then
		return nil
	end
	starter.step += 1
	return starter.step
end

--[[
	Claims a completed starter goal (any completed goal, once).
	@return ok, code, reward?, xp?
]]
function QuestLogic.claimStarter(state: State, index: number): (boolean, Code, Reward?, number?)
	local goal = QuestConfig.Goals[index]
	if goal == nil then
		return false, "unknown", nil, nil
	end
	local starter = state.starter
	if index > starter.step then
		return false, "locked", nil, nil
	end
	if starter.claimed[index] == true then
		return false, "claimed", nil, nil
	end
	starter.claimed[index] = true
	return true, "ok", goal.reward, goal.xp
end

--[[
	Claims a finished daily mission of today.
	@return ok, code, reward?, xp?, stat?
]]
function QuestLogic.claimDaily(state: State, slot: number, today: number): (boolean, Code, Reward?, number?, string?)
	local daily = state.daily
	if daily.day ~= today then
		return false, "stale", nil, nil, nil
	end
	local pick = daily.picks[slot]
	if pick == nil then
		return false, "unknown", nil, nil, nil
	end
	if pick.claimed then
		return false, "claimed", nil, nil, pick.stat
	end
	if pick.progress < pick.target then
		return false, "locked", nil, nil, pick.stat
	end
	pick.claimed = true
	return true, "ok", QuestConfig.MissionReward, QuestConfig.MissionXp, pick.stat
end

--[[
	Claims today's Daily Chest (every mission finished; claimed or not).
	@return ok, code, reward?, xp?
]]
function QuestLogic.claimChest(state: State, today: number): (boolean, Code, Reward?, number?)
	local daily = state.daily
	if daily.day ~= today then
		return false, "stale", nil, nil
	end
	if daily.chest then
		return false, "claimed", nil, nil
	end
	if #daily.picks < QuestConfig.MissionsPerDay then
		return false, "locked", nil, nil
	end
	for _, pick in daily.picks do
		if pick.progress < pick.target then
			return false, "locked", nil, nil
		end
	end
	daily.chest = true
	return true, "ok", QuestConfig.ChestReward, QuestConfig.ChestXp
end

--[[
	Claims a trophy's NEXT tier once its value reached the target (tiers claim one at a time).
	@return ok, code, reward?, xp?, tier? (the tier just claimed, 1-based)
]]
function QuestLogic.claimTrophy(
	state: State,
	trophyId: string,
	facts: Facts
): (boolean, Code, Reward?, number?, number?)
	local trophy = QuestConfig.TrophyById[trophyId]
	if trophy == nil then
		return false, "unknown", nil, nil, nil
	end
	local claimed = math.clamp(state.trophies[trophyId] or 0, 0, #trophy.tiers)
	local target = trophy.tiers[claimed + 1]
	if target == nil then
		return false, "claimed", nil, nil, nil
	end
	if QuestConfig.trophyValue(trophy, facts, state) < target then
		return false, "locked", nil, nil, nil
	end
	local tier = claimed + 1
	state.trophies[trophyId] = tier
	return true, "ok", QuestConfig.trophyReward(tier), QuestConfig.TrophyXp, tier
end

--[[
	Uses today's free reroll on mission `slot`: an unfinished, unclaimed mission becomes a stat
	not already shown (deterministic for the user + day), progress 0.
	@return ok, code, old stat?, new stat?
]]
function QuestLogic.reroll(
	state: State,
	slot: number,
	today: number,
	userId: number,
	tier: number,
	eventLive: boolean
): (boolean, Code, string?, string?)
	local daily = state.daily
	if daily.day ~= today then
		return false, "stale", nil, nil
	end
	if daily.rerolled then
		return false, "used", nil, nil
	end
	local pick = daily.picks[slot]
	if pick == nil then
		return false, "unknown", nil, nil
	end
	if pick.claimed or pick.progress >= pick.target then
		return false, "done", nil, nil
	end
	local shown: { [string]: boolean } = {}
	for _, other in daily.picks do
		shown[other.stat] = true
	end
	local stats = QuestLogic.pickStats(userId, today, SALT_REROLL, eventLive, shown, 1)
	local replacement = stats[1]
	if replacement == nil then
		return false, "empty", nil, nil
	end
	local old = pick.stat
	daily.picks[slot] = { stat = replacement, target = targetOf(replacement, tier), progress = 0, claimed = false }
	daily.rerolled = true
	return true, "ok", old, replacement
end

--[[
	Admin: re-seeds today's missions (fresh picks, progress 0, chest + reroll back).
	@return the picked stats
]]
function QuestLogic.resetDay(state: State, today: number, userId: number, tier: number, eventLive: boolean): { string }
	state.daily.day = -1
	local _, stats = QuestLogic.rollDay(state, today, userId, tier, eventLive)
	return stats
end

--[[
	Admin: sets a COUNTER trophy's lifetime counter (state trophies read the profile and refuse).
	@return true when set
]]
function QuestLogic.setCounter(state: State, trophyId: string, value: number): boolean
	local trophy = QuestConfig.TrophyById[trophyId]
	if trophy == nil or trophy.source ~= "counter" or trophy.stat == nil then
		return false
	end
	if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
		return false
	end
	local stat = trophy.stat :: string
	state.life[stat] = math.min(math.floor(value), QuestConfig.MaxCounter)
	-- Claimed tiers above the new value stay claimed (never take a reward back).
	return true
end

--------------------------------------------------------------------------------------------------
-- Remote argument validation
--------------------------------------------------------------------------------------------------

--[[
	Validates QuestClaim(kind, id): kind one of ClaimKinds; starter id = whole 1..12, daily id =
	whole 1..MissionsPerDay, chest ignores id, trophy id = a QuestConfig.TrophyById key.
	@return the request, or nil for anything else (NaN, inf, wrong types, unknown ids)
	Example: QuestLogic.readClaim("trophy", "clicker") --> { kind = "trophy", trophy = "clicker" }
]]
function QuestLogic.readClaim(rawKind: unknown, rawId: unknown): ClaimRequest?
	local kind = Validate.oneOf(rawKind, QuestLogic.ClaimKinds)
	if kind == nil then
		return nil
	end
	if kind == "starter" then
		local index = Validate.integer(rawId, 1, QuestConfig.GoalCount)
		return if index ~= nil then { kind = kind, index = index } else nil
	elseif kind == "daily" then
		local index = Validate.integer(rawId, 1, QuestConfig.MissionsPerDay)
		return if index ~= nil then { kind = kind, index = index } else nil
	elseif kind == "trophy" then
		local id = Validate.configKey(rawId, QuestConfig.TrophyById :: any, QuestConfig.MaxKeyLength)
		return if id ~= nil then { kind = kind, trophy = id } else nil
	end
	return { kind = "chest" }
end

--[[
	Validates QuestReroll(slot): whole 1..MissionsPerDay.
	Example: QuestLogic.readSlot(2) --> 2; QuestLogic.readSlot(0 / 0) --> nil
]]
function QuestLogic.readSlot(rawSlot: unknown): number?
	return Validate.integer(rawSlot, 1, QuestConfig.MissionsPerDay)
end

return table.freeze(QuestLogic)
