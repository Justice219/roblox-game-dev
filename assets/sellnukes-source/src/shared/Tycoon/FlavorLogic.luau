--!strict
--[[
	FlavorLogic — the pure math of the R89 Surprise Batches + the Flavour Book state (spec §1).
	No services, no yields, no Roblox-only APIs: the server (Server/Tycoon/FlavorService), the client
	(Book / reveal) and the Lune tests (tests/flavor-logic.luau, tests/economy-sim.luau) all run it.

	Rolling
		chances(luck)                   the per-batch chance of every SPECIAL flavour (index = rank)
		                                with luck applied (special share capped at MaxSpecialShare)
		rollOne(rng, chances)           one batch → rank (0 = Plain)
		rollInto(counts, rng, n, chances)
		                                n batches → counts[rank] of every special flavour; returns the
		                                special total. BOUNDED WORK: n <= Roll.ExactCap draws one
		                                uniform per batch; more batches sample the multinomial by
		                                conditional binomials (rarest first), each by inversion
		                                (mean < SmallMean, <= InversionCap steps) or a clamped normal
		                                approximation — constant work whatever n is (a 5000-cycle
		                                hitch catch-up costs the same as 25 cycles).
		bonusCycles(counts)             Σ counts[r] × (mult_r - 1): extra batches' worth of payout
		expectedMultiplier(luck)        1 + Σ p_r (mult_r - 1) — the average income lift (economy sim)
		oneIn(rank, luck) / formatOdds  the "1 in N" shown to players (same numbers the server rolls)
	The rng is any object with `:next() -> [0, 1)` (Shared/Attack/AttackRng: a seeded mulberry32 —
	the server seeds one stream per player from a per-server secret, so clients can't predict it).

	Event luck
		eventLuck(nowUnix)              the Happy Hours' luck multiplier, read DIRECTLY from
		                                Shared/Events/HappyHourLogic.flavorLuckAt(nowUnix) (E-events,
		                                spec §2) through a guarded lookup: 1 while that module is
		                                missing / malformed / throws (and always under Lune).

	Flavour Book state (profile.flavors; ProfileLogic delegates default / reconcile / snapshot here)
		{ found = { ["<world>:<flavor>"] = lifetime batches (whole, capped) },
		  claimed = { ["<world>:<flavor>"] = true },
		  tip = the one-time Lucky Nukes tip card was dismissed (owner R112; missing → false) }
		key / parseKey, newState, reconcileState (any junk → a valid state), toWire (a fresh copy),
		addFound (true on a NEW discovery), claim (idempotent: "ok" | "claimed" | "locked" | "bad"),
		claimable (keys whose reward is ready), claimableCount (HUD badge; tolerant of a missing /
		malformed wire copy), discovered.

	Quest credit
		creditStep(bank, elapsed, perMinute, burst, earned)  a token bucket: fast producers' special
		                                batches credit the "flavor" quest stat at a capped rate.

	Example:
		local chances = FlavorLogic.chances(1)
		local counts = table.create(FlavorConfig.SpecialCount, 0)
		local special = FlavorLogic.rollInto(counts, rng, 40, chances)
		local bonus = perCycle * FlavorLogic.bonusCycles(counts)
		FlavorLogic.formatOdds(FlavorLogic.oneIn(4, 1)) --> "1 in 2,500"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)

export type FlavorDef = FlavorConfig.FlavorDef
export type Rng = { next: (self: any) -> number }
export type State = {
	found: { [string]: number },
	claimed: { [string]: true },
	-- Owner R112: the one-time "what are Lucky Nukes?" tip card was dismissed (UI/Screens/FlavorTip).
	tip: boolean,
}
export type ClaimCode = "ok" | "claimed" | "locked" | "bad"

local FlavorLogic = {}

local SPECIAL = FlavorConfig.Special
local COUNT = FlavorConfig.SpecialCount
local ROLL = FlavorConfig.Roll
local TWO_PI = 2 * math.pi

-- Key shapes: "<world>:<flavor>" (world ids follow the profile.worlds rule, flavour ids FlavorConfig).
local KEY_PATTERN = "^([a-z][a-z0-9]*):([a-z]+)$"
local MAX_WORLD_LENGTH = 16

--------------------------------------------------------------------------------------------------
-- Luck + chances
--------------------------------------------------------------------------------------------------

--[[
	Sanitises a luck multiplier: non-numbers / NaN → 1, then clamped to [MinLuck, MaxLuck].
	@param luck unknown
	@return number
	Example: FlavorLogic.clampLuck(0 / 0) --> 1; FlavorLogic.clampLuck(99) --> 10
]]
function FlavorLogic.clampLuck(luck: unknown): number
	if type(luck) ~= "number" or luck ~= luck then
		return 1
	end
	return math.clamp(luck :: number, FlavorConfig.MinLuck, FlavorConfig.MaxLuck)
end

--[[
	Writes the per-batch chance of every special flavour into `out` (out[rank], rank 1..n) for
	`luck`: base 1 / oneIn × luck, then scaled down together so the special total never exceeds
	MaxSpecialShare. Reuses `out` (no allocation on the hot path).
	@param out { number } — written in place (length = SpecialCount)
	@param luck unknown — sanitised by clampLuck
	@return { number } — `out`
]]
function FlavorLogic.chancesInto(out: { number }, luck: unknown): { number }
	local factor = FlavorLogic.clampLuck(luck)
	local total = 0
	for rank, def in SPECIAL do
		local chance = factor / def.oneIn
		out[rank] = chance
		total += chance
	end
	if total > FlavorConfig.MaxSpecialShare then
		local scale = FlavorConfig.MaxSpecialShare / total
		for rank = 1, COUNT do
			out[rank] *= scale
		end
	end
	return out
end

--[[
	A fresh chance table for `luck` (see chancesInto).
	@param luck unknown
	@return { number } — index = special rank
	Example: FlavorLogic.chances(1)[1] --> 0.05 (Sprinkle, 1 in 20)
]]
function FlavorLogic.chances(luck: unknown): { number }
	return FlavorLogic.chancesInto(table.create(COUNT, 0), luck)
end

--[[
	The "1 in N" of a special flavour at `luck` — exactly the chance the server rolls with, rounded
	to a whole N (at least 1). Plain / unknown ranks → 0.
	@param rank number — 1..SpecialCount
	@param luck unknown
	@return number
	Example: FlavorLogic.oneIn(4, 2) --> 1250 (Galaxy during a x2 Sprinkle Surge)
]]
function FlavorLogic.oneIn(rank: number, luck: unknown): number
	if type(rank) ~= "number" or rank < 1 or rank > COUNT or rank ~= math.floor(rank) then
		return 0
	end
	local chance = FlavorLogic.chances(luck)[rank]
	if chance <= 0 then
		return 0
	end
	return math.max(1, math.floor(1 / chance + 0.5))
end

--[[
	The average payout multiplier of a batch at `luck`: 1 + Σ p_r (mult_r − 1). The economy
	simulator multiplies every producer's income by this at FlavorConfig.PacingLuck.
	@param luck unknown
	@return number
	Example: FlavorLogic.expectedMultiplier(1) --> 1.06456
]]
function FlavorLogic.expectedMultiplier(luck: unknown): number
	local chances = FlavorLogic.chances(luck)
	local lift = 0
	for rank, def in SPECIAL do
		lift += chances[rank] * (def.mult - 1)
	end
	return 1 + lift
end

--------------------------------------------------------------------------------------------------
-- Rolling
--------------------------------------------------------------------------------------------------

-- A uniform draw in [0, 1) from any rng; a broken generator (NaN / out of range) reads as 0.5.
local function uniform(rng: Rng): number
	local value = rng:next()
	if type(value) ~= "number" or value ~= value or value < 0 or value >= 1 then
		return 0.5
	end
	return value
end

--[[
	Rolls ONE batch.
	@param rng Rng
	@param chances { number } — from chances / chancesInto
	@return number — the rank (0 = Plain)
	Example: FlavorLogic.rollOne(rng, FlavorLogic.chances(1)) --> 0 most of the time
]]
function FlavorLogic.rollOne(rng: Rng, chances: { number }): number
	local u = uniform(rng)
	-- Rarest first: the cumulative bands are [0, p5), [p5, p5 + p4), ... ; the rest is Plain.
	local edge = 0
	for rank = COUNT, 1, -1 do
		edge += chances[rank]
		if u < edge then
			return rank
		end
	end
	return 0
end

--[[
	A Binomial(n, p) sample with BOUNDED work: inversion while the mean is small (at most
	Roll.InversionCap steps, exact), else a normal approximation rounded and clamped to [0, n]
	(two uniform draws). Hostile input (n < 1, p <= 0, NaN) → 0; p >= 1 → n.
	@param rng Rng
	@param n number — whole trials
	@param p number — success chance
	@return number — whole successes in [0, n]
	Example: FlavorLogic.binomial(rng, 5000, 0.05) --> ~250
]]
function FlavorLogic.binomial(rng: Rng, n: number, p: number): number
	if n ~= n or n < 1 or p ~= p or p <= 0 then
		return 0
	end
	n = math.floor(n)
	if p >= 1 then
		return n
	end
	local mean = n * p
	if mean < ROLL.SmallMean then
		local pmf = (1 - p) ^ n
		if pmf > 0 then
			local ratio = p / (1 - p)
			local u = uniform(rng)
			local cdf = pmf
			local k = 0
			local cap = math.min(n, ROLL.InversionCap)
			while u > cdf and k < cap do
				pmf *= ratio * (n - k) / (k + 1)
				k += 1
				cdf += pmf
			end
			return k
		end
	end
	-- Box–Muller: z ~ N(0, 1) from two uniforms (1 - u keeps the log argument in (0, 1]).
	local z = math.sqrt(-2 * math.log(1 - uniform(rng))) * math.cos(TWO_PI * uniform(rng))
	local sample = math.floor(mean + z * math.sqrt(mean * (1 - p)) + 0.5)
	return math.clamp(sample, 0, n)
end

--[[
	Rolls `n` batches at once into `counts` (counts[rank] for every special rank; Plain is the
	rest). Up to Roll.ExactCap batches roll one by one; more batches roll in aggregate (multinomial
	by conditional binomials, rarest first) with constant work — see the module header.
	@param counts { number } — overwritten (length = SpecialCount); reuse one table per caller
	@param rng Rng
	@param n number — finished batches (non-whole / hostile → floored, < 1 → nothing)
	@param chances { number }
	@return number — special batches in total (Σ counts)
	Example: local special = FlavorLogic.rollInto(counts, rng, 5000, FlavorLogic.chances(1))
]]
function FlavorLogic.rollInto(counts: { number }, rng: Rng, n: number, chances: { number }): number
	for rank = 1, COUNT do
		counts[rank] = 0
	end
	if type(n) ~= "number" or n ~= n or n < 1 or n == math.huge then
		return 0
	end
	n = math.floor(n)
	local special = 0
	if n <= ROLL.ExactCap then
		for _ = 1, n do
			local rank = FlavorLogic.rollOne(rng, chances)
			if rank > 0 then
				counts[rank] += 1
				special += 1
			end
		end
		return special
	end
	-- Multinomial by conditionals: draw the rarest flavour's count from all n batches, the next
	-- one from the batches left with its chance renormalised by the mass left, and so on.
	local left = n
	local mass = 1
	for rank = COUNT, 1, -1 do
		local chance = chances[rank]
		if left <= 0 or mass <= 0 then
			break
		end
		local hits = FlavorLogic.binomial(rng, left, math.min(1, chance / mass))
		counts[rank] = hits
		special += hits
		left -= hits
		mass -= chance
	end
	return special
end

--[[
	Extra batches' worth of payout the counts earn: Σ counts[r] × (mult_r − 1). Payout bonus =
	perCycle × this (the base already pays every batch once).
	@param counts { number }
	@return number
	Example: FlavorLogic.bonusCycles({ 0, 1, 0, 0, 0 }) --> 2 (one Glitter x3 = two extra batches)
]]
function FlavorLogic.bonusCycles(counts: { number }): number
	local extra = 0
	for rank, def in SPECIAL do
		local hits = counts[rank]
		if type(hits) == "number" and hits > 0 then
			extra += hits * (def.mult - 1)
		end
	end
	return extra
end

--[[
	The rarest rank present in `counts` (0 = none).
	@param counts { number }
	@return number
]]
function FlavorLogic.bestRank(counts: { number }): number
	for rank = COUNT, 1, -1 do
		local hits = counts[rank]
		if type(hits) == "number" and hits > 0 then
			return rank
		end
	end
	return 0
end

--------------------------------------------------------------------------------------------------
-- Event luck (Happy Hours, E-events)
--------------------------------------------------------------------------------------------------

local happyHour: any = nil
local happyHourResolved = false

-- Finds Shared/Events/HappyHourLogic once (guarded: nil while missing / failing / under Lune).
local function resolveHappyHour(): any
	if happyHourResolved then
		return happyHour
	end
	happyHourResolved = true
	local ok, loaded = pcall(function(): any
		local shared = (script :: any).Parent.Parent
		local events = shared:FindFirstChild("Events")
		local module = if events ~= nil then events:FindFirstChild("HappyHourLogic") else nil
		if module == nil or not module:IsA("ModuleScript") then
			return nil
		end
		return (require :: any)(module)
	end)
	if ok and type(loaded) == "table" and type(loaded.flavorLuckAt) == "function" then
		happyHour = loaded
	end
	return happyHour
end

--[[
	The Happy Hours' flavour luck at `nowUnix` (Sprinkle Surge > 1; 1 = no event / module missing).
	Never throws; the value is sanitised (clampLuck, and never below 1 — an event only adds luck).
	@param nowUnix number — UTC unix seconds (server: os.time() / Workspace:GetServerTimeNow())
	@return number
	Example: FlavorLogic.eventLuck(os.time()) --> 1 (or 2 during a Sprinkle Surge)
]]
function FlavorLogic.eventLuck(nowUnix: number): number
	local module = resolveHappyHour()
	if module == nil then
		return 1
	end
	local ok, value = pcall(module.flavorLuckAt, nowUnix)
	if not ok then
		return 1
	end
	return math.max(1, FlavorLogic.clampLuck(value))
end

--------------------------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------------------------

--[[
	"1 in 2,500" for N (whole, thousands separated). N < 1 → "".
	@param n number
	@return string
	Example: FlavorLogic.formatOdds(25000) --> "1 in 25,000"
]]
function FlavorLogic.formatOdds(n: number): string
	if type(n) ~= "number" or n ~= n or n < 1 or n == math.huge then
		return ""
	end
	local digits = tostring(math.floor(n))
	local out = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return `1 in {out}`
end

--------------------------------------------------------------------------------------------------
-- Flavour Book state
--------------------------------------------------------------------------------------------------

--[[
	The Book key of a flavour in a world.
	@param worldId string
	@param flavorId string
	@return string
	Example: FlavorLogic.key("dino", "galaxy") --> "dino:galaxy"
]]
function FlavorLogic.key(worldId: string, flavorId: string): string
	return `{worldId}:{flavorId}`
end

--[[
	Parses an untrusted Book key into (worldId, special FlavorDef). Only well-formed keys of a
	SPECIAL flavour and a world id of the profile.worlds shape pass; anything else → nil.
	@param raw unknown
	@return (string?, FlavorDef?)
	Example: FlavorLogic.parseKey("main:rainbow") --> "main", <Rainbow>
]]
function FlavorLogic.parseKey(raw: unknown): (string?, FlavorDef?)
	if type(raw) ~= "string" or #(raw :: string) > MAX_WORLD_LENGTH + 17 then
		return nil, nil
	end
	local worldId, flavorId = string.match(raw :: string, KEY_PATTERN)
	if worldId == nil or flavorId == nil or #worldId > MAX_WORLD_LENGTH then
		return nil, nil
	end
	local def = FlavorConfig.byId(flavorId)
	if def == nil or def.rank < 1 then
		return nil, nil
	end
	return worldId, def
end

--[[ A fresh, empty Book (nothing found, nothing claimed, tip not seen). ]]
function FlavorLogic.newState(): State
	return { found = {}, claimed = {}, tip = false }
end

--[[
	Repairs ANY stored value into a valid State: wrong types → empty; keys must parse (parseKey);
	found counts whole, finite and clamped to [1, MaxFoundCount] (0 / junk dropped); claimed only
	`true`; each map at most MaxEntries entries. Keys of worlds this server doesn't know are KEPT
	(a newer server's world survives an older server's save).
	@param raw unknown
	@return State
	Example: FlavorLogic.reconcileState({ found = { ["main:galaxy"] = 2.7 } }).found["main:galaxy"] --> 2
]]
function FlavorLogic.reconcileState(raw: unknown): State
	local state = FlavorLogic.newState()
	if type(raw) ~= "table" then
		return state
	end
	local source = raw :: { [any]: any }
	local found = source.found
	if type(found) == "table" then
		local kept = 0
		for key, value in found :: { [any]: any } do
			if kept >= FlavorConfig.MaxEntries then
				break
			end
			local worldId = FlavorLogic.parseKey(key)
			if worldId ~= nil and type(value) == "number" and value == value and value >= 1 then
				state.found[key :: string] = math.min(math.floor(value), FlavorConfig.MaxFoundCount)
				kept += 1
			end
		end
	end
	state.tip = source.tip == true -- owner R112 (pre-R112 saves: false)
	local claimed = source.claimed
	if type(claimed) == "table" then
		local kept = 0
		for key, value in claimed :: { [any]: any } do
			if kept >= FlavorConfig.MaxEntries then
				break
			end
			if value == true and FlavorLogic.parseKey(key) ~= nil then
				state.claimed[key :: string] = true
				kept += 1
			end
		end
	end
	return state
end

--[[
	The owner's snapshot copy (fresh tables; string keys only, remote / JSON safe).
	@param state State
	@return { found, claimed, tip }
]]
function FlavorLogic.toWire(state: State): State
	return { found = table.clone(state.found), claimed = table.clone(state.claimed), tip = state.tip == true }
end

--[[
	Adds `count` found batches of special `rank` in `worldId` (capped). Ignores junk input.
	@param state State
	@param worldId string
	@param rank number — 1..SpecialCount
	@param count number — whole > 0
	@return boolean — true when this was the FIRST time this flavour was found in this world
	Example: FlavorLogic.addFound(state, "main", 4, 1) --> true (Galaxy discovered!)
]]
function FlavorLogic.addFound(state: State, worldId: string, rank: number, count: number): boolean
	local def = SPECIAL[rank]
	if def == nil or type(count) ~= "number" or count ~= count or count < 1 then
		return false
	end
	local key = FlavorLogic.key(worldId, def.id)
	local before = state.found[key]
	if before == nil then
		local entries = 0
		for _ in state.found do
			entries += 1
		end
		if entries >= FlavorConfig.MaxEntries then
			return false
		end
	end
	state.found[key] = math.min((before or 0) + math.floor(count), FlavorConfig.MaxFoundCount)
	return before == nil
end

--[[
	Claims the discovery reward of `rawKey` once.
	@param state State
	@param rawKey unknown — untrusted "<world>:<flavor>"; the world must be one of `worlds`
	@param worlds { string }? — known world ids (default FlavorConfig.Worlds)
	@return (ClaimCode, FlavorDef?, string?) — "ok" marks it claimed and returns the flavour + key;
		"claimed" (already), "locked" (not found yet) and "bad" change nothing
	Example: FlavorLogic.claim(state, "main:sprinkle") --> "ok", <Sprinkle>, "main:sprinkle"
]]
function FlavorLogic.claim(state: State, rawKey: unknown, worlds: { string }?): (ClaimCode, FlavorDef?, string?)
	local worldId, def = FlavorLogic.parseKey(rawKey)
	if worldId == nil or def == nil or table.find(worlds or FlavorConfig.Worlds, worldId) == nil then
		return "bad", nil, nil
	end
	local key = FlavorLogic.key(worldId, def.id)
	if state.claimed[key] then
		return "claimed", def, key
	end
	local found = state.found[key]
	if found == nil or found < 1 then
		return "locked", def, key
	end
	state.claimed[key] = true
	return "ok", def, key
end

-- Reads a possibly malformed wire / profile copy's map (nil when not a table).
local function mapOf(state: any, field: string): { [any]: any }?
	if type(state) ~= "table" then
		return nil
	end
	local map = state[field]
	return if type(map) == "table" then map else nil
end

--[[
	Keys whose discovery reward is ready (found, not claimed), Book order (world rows, then rank).
	Tolerates a missing / malformed state (client wire copies) → {}.
	@param state any — State or its wire copy
	@param worlds { string }? — default FlavorConfig.Worlds
	@return { string }
	Example: FlavorLogic.claimable(profile.flavors) --> { "main:sprinkle", "main:glitter" }
]]
function FlavorLogic.claimable(state: any, worlds: { string }?): { string }
	local out: { string } = {}
	local found = mapOf(state, "found")
	if found == nil then
		return out
	end
	local claimed = mapOf(state, "claimed") or {}
	for _, worldId in worlds or FlavorConfig.Worlds do
		for _, def in SPECIAL do
			local key = FlavorLogic.key(worldId, def.id)
			local count = found[key]
			if type(count) == "number" and count >= 1 and claimed[key] ~= true then
				table.insert(out, key)
			end
		end
	end
	return out
end

--[[ Number of ready discovery rewards (the HUD Pets badge + the Book's FLAVOURS button "!"). ]]
function FlavorLogic.claimableCount(state: any): number
	return #FlavorLogic.claimable(state)
end

--[[
	Discovered special flavours (in one world, or every known world when nil).
	@param state any — State or its wire copy
	@param worldId string?
	@return number
]]
function FlavorLogic.discovered(state: any, worldId: string?): number
	local found = mapOf(state, "found")
	if found == nil then
		return 0
	end
	local total = 0
	for _, world in if worldId ~= nil then { worldId } else FlavorConfig.Worlds do
		for _, def in SPECIAL do
			local count = found[FlavorLogic.key(world, def.id)]
			if type(count) == "number" and count >= 1 then
				total += 1
			end
		end
	end
	return total
end

--[[ Book size: every special flavour in every known world. ]]
function FlavorLogic.total(): number
	return COUNT * #FlavorConfig.Worlds
end

--------------------------------------------------------------------------------------------------
-- Quest credit
--------------------------------------------------------------------------------------------------

--[[
	One token-bucket step of the "flavor" quest credit: the bucket refills at perMinute / 60 per
	second up to `burst`; `earned` special batches spend whole tokens.
	@param bank number — tokens in the bucket (fractional)
	@param elapsed number — seconds since the last step (clamped to [0, 3600])
	@param perMinute number — refill rate
	@param burst number — bucket size
	@param earned number — special batches this step
	@return (number, number) — whole credit to report, the new bank
	Example: FlavorLogic.creditStep(10, 0, 20, 10, 50) --> 10, 0
]]
function FlavorLogic.creditStep(
	bank: number,
	elapsed: number,
	perMinute: number,
	burst: number,
	earned: number
): (number, number)
	local safeBank = if type(bank) == "number" and bank == bank then math.clamp(bank, 0, burst) else 0
	local safeElapsed = if type(elapsed) == "number" and elapsed == elapsed then math.clamp(elapsed, 0, 3600) else 0
	local filled = math.min(burst, safeBank + safeElapsed * perMinute / 60)
	if type(earned) ~= "number" or earned ~= earned or earned < 1 then
		return 0, filled
	end
	local credit = math.min(math.floor(earned), math.floor(filled))
	return credit, filled - credit
end

return table.freeze(FlavorLogic)
