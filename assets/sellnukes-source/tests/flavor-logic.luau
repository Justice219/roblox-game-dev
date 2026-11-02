--!strict
--[[
	Surprise Batches + Flavour Book regressions (owner R89, spec 2026-10-31-r89 §1). Run:
		lune run tests/flavor-logic

	Proves on the shipped modules (src/shared/Config/FlavorConfig, src/shared/Tycoon/FlavorLogic,
	src/shared/Attack/AttackRng, src/server/Economy/ProfileLogic):
	  1. Config: Plain + 5 special flavours, ranks dense, odds strictly rarer and multipliers strictly
	     bigger, Rainbow+ glow / Galaxy+ reveal, the Big Pop tier = the reveal tier.
	  2. Chances: luck 1 = 1 / oneIn exactly; luck scales every special chance; the special share
	     is capped at MaxSpecialShare (Plain keeps the rest); hostile luck (NaN, strings, huge,
	     negative) is sanitised; luck 0 = Plain only. oneIn / formatOdds show the rolled numbers.
	  3. Economy: expectedMultiplier(1) = 1 + Σ p (mult - 1); the pacing lift (PacingLuck) stays
	     <= MaxPacingLift (tests/economy-sim.luau plays the whole game with it).
	  4. Distribution (seeded, deterministic): 1,000,000 single rolls and 400 aggregate rolls of
	     5,000 batches each land every flavour within 4.5 sigma of its expected count, and the mean
	     bonus per batch matches expectedMultiplier - 1 within 3 %. Mid-size batches (25..200)
	     too. A luck-2 aggregate doubles the special rate.
	  5. Bounds: rollInto never returns more than n, counts are whole and >= 0, Σ counts = the
	     returned total; hostile n (NaN, ±inf, 0, -3, 0.5) rolls nothing; WORK IS BOUNDED — an
	     aggregate roll of 5,000 (or 1e9) batches draws at most 2 uniforms per special flavour;
	     <= ExactCap batches draw exactly n. binomial: hostile input, p >= 1, mean / variance.
	  6. Event luck: 1 under Lune (HappyHourLogic is resolved through a guarded lookup).
	  7. Book state: keys parse only "<world>:<special flavour>"; reconcile repairs junk (types,
	     NaN, fractions, zero counts, unknown flavours, oversize maps) and keeps a newer server's
	     world; addFound reports the FIRST discovery only and caps counts; claim is idempotent
	     ("ok" once, then "claimed"; "locked" before found; "bad" for junk / unknown worlds) and
	     never changes state on a refusal; claimable / claimableCount / discovered tolerate wire
	     copies and junk; toWire is a deep-enough copy.
	  8. Quest credit token bucket: burst, refill, cap, hostile values.
	  9. ProfileLogic: defaultProfile has an empty Book; reconcile repairs profile.flavors; the
	     snapshot field `flavors` is a fresh copy; toSave keeps it JSON-safe.
]]

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local FlavorConfig = loader.load("src/shared/Config/FlavorConfig")
local FlavorLogic = loader.load("src/shared/Tycoon/FlavorLogic")
local AttackRng = loader.load("src/shared/Attack/AttackRng")
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local NAN = 0 / 0
local SPECIAL = FlavorConfig.Special
local COUNT = FlavorConfig.SpecialCount

local function near(a: number, b: number, tolerance: number): boolean
	return math.abs(a - b) <= tolerance
end

--------------------------------------------------------------------------------------------------
-- 1. Config
--------------------------------------------------------------------------------------------------

check(#FlavorConfig.Flavors == 6 and COUNT == 5, "six flavours, five special")
check(FlavorConfig.Flavors[1].id == "plain" and FlavorConfig.Flavors[1].mult == 1, "Plain pays x1")
local expectedIds = { "sprinkle", "glitter", "rainbow", "galaxy", "mystery" }
for rank, def in SPECIAL do
	check(def.rank == rank and def.id == expectedIds[rank], `special {rank} is {expectedIds[rank]}`)
	check(FlavorConfig.byId(def.id) == def and FlavorConfig.byRank(rank) == def, `lookups of {def.id}`)
	check(FlavorConfig.isSpecial(def.id), `{def.id} is special`)
	check(def.glow == (rank >= 3) and def.reveal == (rank >= 4), `{def.id} glow / reveal flags`)
	if rank > 1 then
		check(def.oneIn > SPECIAL[rank - 1].oneIn and def.mult > SPECIAL[rank - 1].mult, `{def.id} rarer + bigger`)
	end
end
check(FlavorConfig.byId("galaxy").oneIn == 2500, "Galaxy is 1 in 2,500 (spec example)")
check(not FlavorConfig.isSpecial("plain") and not FlavorConfig.isSpecial(5) and FlavorConfig.byId(nil) == nil, "junk ids")
check(FlavorConfig.byRank(NAN) == nil and FlavorConfig.byRank(9) == nil, "junk ranks")
check(FlavorConfig.BigPop.MinBatchRank == 4 and FlavorConfig.BigPop.MinHatchRank == 6, "Big Pop tiers")
check(FlavorConfig.Reveal.Seconds <= 3, "the reveal is at most 3 s")
check(#FlavorConfig.Worlds == 3 and FlavorConfig.Worlds[1] == "main", "Book rows = every world")

-- Owner R112 words: never "batch" on screen; the helpers build the agreed lines.
for key, value in FlavorConfig.Text do
	check(string.find(string.lower(value), "batch", 1, true) == nil, `Text.{key} never says "batch"`)
end
do
	local galaxy = FlavorConfig.byId("galaxy")
	local lines = FlavorConfig.revealLines(galaxy, "Pocket Nuke Workbench", "$31.8M")
	check(lines.title == "LUCKY NUKES!", "reveal title")
	check(lines.made == "Your Pocket Nuke Workbench made GALAXY nukes", "reveal made line")
	check(lines.sold == "Sold for x20: +$31.8M", "reveal sold line (the payout always shows)")
	check(FlavorConfig.revealLines(galaxy, nil, nil).made == "You made GALAXY nukes", "reveal without producer")
	check(FlavorConfig.revealLines(galaxy, "", "").sold == "Sold for x20!", "reveal without amount")
	check(FlavorConfig.popWord(galaxy, 1) == "GALAXY x20", "pop word")
	check(FlavorConfig.popWord(FlavorConfig.byId("sprinkle"), 3) == "SPRINKLE x1.5  +2", "pop word folded")
	check(
		FlavorConfig.bigPopLine("Alex", "batch", "GALAXY", "1 in 2,500") == "Alex got GALAXY nukes! (1 in 2,500)",
		"Big Pop line"
	)
	check(FlavorConfig.bigPopLine("Sam", "hatch", "MYTHIC Nova Fox", "") == "Sam hatched a MYTHIC Nova Fox!", "hatch line")
	check(FlavorConfig.bigPopLine("Kim", "rebirth", "REBIRTH #3", nil) == "Kim did a REBIRTH #3!", "rebirth line")
	check(FlavorConfig.multText(1.5) == "x1.5" and FlavorConfig.multText(100) == "x100", "multText")
end

--------------------------------------------------------------------------------------------------
-- 2. Chances
--------------------------------------------------------------------------------------------------

local base = FlavorLogic.chances(1)
for rank, def in SPECIAL do
	check(near(base[rank], 1 / def.oneIn, 1e-15), `luck 1 chance of {def.id}`)
end
local doubled = FlavorLogic.chances(2)
for rank = 1, COUNT do
	check(near(doubled[rank], 2 * base[rank], 1e-15), "luck 2 doubles every special chance")
end
local maxed = FlavorLogic.chances(FlavorConfig.MaxLuck)
local share = 0
for rank = 1, COUNT do
	share += maxed[rank]
end
check(share <= FlavorConfig.MaxSpecialShare + 1e-12, "special share capped at max luck")
local junkLuck = { NAN, "2", {}, nil, true }
for _, luck in junkLuck do
	local chances = FlavorLogic.chances(luck)
	check(near(chances[1], base[1], 1e-15), `junk luck {tostring(luck)} reads as 1`)
end
check(FlavorLogic.clampLuck(1e9) == FlavorConfig.MaxLuck and FlavorLogic.clampLuck(-4) == FlavorConfig.MinLuck, "clamp")
local none = FlavorLogic.chances(0)
for rank = 1, COUNT do
	check(none[rank] == 0, "luck 0 = Plain only")
end
check(FlavorLogic.oneIn(4, 1) == 2500 and FlavorLogic.oneIn(4, 2) == 1250, "oneIn galaxy")
check(FlavorLogic.oneIn(1, 1) == 20 and FlavorLogic.oneIn(5, 1) == 25000, "oneIn ends")
check(FlavorLogic.oneIn(0, 1) == 0 and FlavorLogic.oneIn(6, 1) == 0 and FlavorLogic.oneIn(2.5, 1) == 0, "oneIn junk")
check(FlavorLogic.oneIn(3, 0) == 0, "oneIn at luck 0 = never")
check(FlavorLogic.formatOdds(2500) == "1 in 2,500", "format 2,500")
check(FlavorLogic.formatOdds(25000) == "1 in 25,000", "format 25,000")
check(FlavorLogic.formatOdds(250000) == "1 in 250,000", "format 250,000")
check(FlavorLogic.formatOdds(20) == "1 in 20" and FlavorLogic.formatOdds(999) == "1 in 999", "format small")
check(FlavorLogic.formatOdds(1234567) == "1 in 1,234,567", "format millions")
check(FlavorLogic.formatOdds(0) == "" and FlavorLogic.formatOdds(NAN) == "" and FlavorLogic.formatOdds(math.huge) == "", "format junk")

--------------------------------------------------------------------------------------------------
-- 3. Economy
--------------------------------------------------------------------------------------------------

local lift = 0
for _, def in SPECIAL do
	lift += (def.mult - 1) / def.oneIn
end
check(near(FlavorLogic.expectedMultiplier(1), 1 + lift, 1e-12), "expectedMultiplier(1)")
local pacingLift = FlavorLogic.expectedMultiplier(FlavorConfig.PacingLuck) - 1
check(pacingLift > 0 and pacingLift <= FlavorConfig.MaxPacingLift, `pacing lift {pacingLift} <= MaxPacingLift`)
check(FlavorLogic.expectedMultiplier(0) == 1, "no luck, no lift")
print(string.format("flavor-logic: average lift %.2f %% (luck 1), %.2f %% (pacing luck)", lift * 100, pacingLift * 100))

--------------------------------------------------------------------------------------------------
-- 4. Distribution
--------------------------------------------------------------------------------------------------

-- Within z sigma of the binomial expectation (n trials, chance p).
local function withinSigma(observed: number, n: number, p: number, z: number): boolean
	local mean = n * p
	local sd = math.sqrt(n * p * (1 - p))
	return math.abs(observed - mean) <= z * sd + 1
end

do
	local rng = AttackRng.new(AttackRng.mix(20261031, 1))
	local totals = table.create(COUNT, 0)
	local trials = 1_000_000
	local plain = 0
	for _ = 1, trials do
		local rank = FlavorLogic.rollOne(rng, base)
		if rank == 0 then
			plain += 1
		else
			totals[rank] += 1
		end
	end
	for rank, def in SPECIAL do
		check(withinSigma(totals[rank], trials, 1 / def.oneIn, 4.5), `single rolls: {def.id} {totals[rank]}`)
	end
	local specialTotal = 0
	for rank = 1, COUNT do
		specialTotal += totals[rank]
	end
	check(plain + specialTotal == trials, "single rolls account for every batch")
end

-- Aggregate rolls of `size` batches, `repeats` times: per-flavour totals + the mean bonus.
local function aggregate(seed: number, size: number, repeats: number, chances: { number }): ({ number }, number)
	local rng = AttackRng.new(AttackRng.mix(seed, size))
	local counts = table.create(COUNT, 0)
	local totals = table.create(COUNT, 0)
	local bonus = 0
	for _ = 1, repeats do
		local special = FlavorLogic.rollInto(counts, rng, size, chances)
		local sum = 0
		for rank = 1, COUNT do
			local hits = counts[rank]
			check(hits >= 0 and hits == math.floor(hits), "counts are whole and >= 0")
			totals[rank] += hits
			sum += hits
		end
		check(sum == special and special <= size, "rollInto total = Σ counts <= n")
		bonus += FlavorLogic.bonusCycles(counts)
	end
	return totals, bonus / (size * repeats)
end

for _, case in { { size = 5000, repeats = 400 }, { size = 25, repeats = 40000 }, { size = 200, repeats = 5000 } } do
	local trials = case.size * case.repeats
	local totals, meanBonus = aggregate(77, case.size, case.repeats, base)
	for rank, def in SPECIAL do
		check(
			withinSigma(totals[rank], trials, 1 / def.oneIn, 4.5),
			`aggregate {case.size}: {def.id} {totals[rank]} vs {trials / def.oneIn}`
		)
	end
	check(near(meanBonus, lift, lift * 0.03), `aggregate {case.size}: mean bonus {meanBonus} vs {lift}`)
end
do
	local trials = 5000 * 200
	local totals = aggregate(91, 5000, 200, doubled)
	check(withinSigma(totals[1], trials, 2 / 20, 4.5), "luck 2 doubles the Sprinkle rate in aggregate")
end

--------------------------------------------------------------------------------------------------
-- 5. Bounds + bounded work
--------------------------------------------------------------------------------------------------

-- An rng that counts draws.
local function countingRng(seed: number): (any, () -> number)
	local inner = AttackRng.new(seed)
	local calls = 0
	local rng = {
		next = function(_self: any): number
			calls += 1
			return inner:next()
		end,
	}
	return rng, function(): number
		return calls
	end
end

do
	local counts = table.create(COUNT, 7)
	for _, n in { NAN, math.huge, -math.huge, 0, -3, 0.5 } do
		local rng = countingRng(1)
		check(FlavorLogic.rollInto(counts, rng, n, base) == 0, `hostile n {tostring(n)} rolls nothing`)
		for rank = 1, COUNT do
			check(counts[rank] == 0, "hostile n clears the counts")
		end
	end
	for _, n in { 1, 7, FlavorConfig.Roll.ExactCap } do
		local rng, calls = countingRng(n)
		FlavorLogic.rollInto(counts, rng, n, base)
		check(calls() == n, `exact path draws n uniforms ({n})`)
	end
	for _, n in { FlavorConfig.Roll.ExactCap + 1, 5000, 1e6, 1e9 } do
		for seed = 1, 50 do
			local rng, calls = countingRng(seed * 31 + n)
			local special = FlavorLogic.rollInto(counts, rng, n, FlavorLogic.chances(FlavorConfig.MaxLuck))
			check(special <= n, "aggregate never exceeds n")
			check(calls() <= 2 * COUNT, `aggregate of {n} draws <= {2 * COUNT} uniforms (drew {calls()})`)
		end
	end
	-- A broken generator (NaN / out of range draws) never throws and stays in bounds.
	local broken = {
		next = function(_self: any): number
			return NAN
		end,
	}
	check(FlavorLogic.rollInto(counts, broken, 50, base) <= 50, "a broken rng stays in bounds")
	check(FlavorLogic.rollOne(broken, base) == 0, "a broken rng single roll is Plain (u = 0.5)")
end

do
	local rng = AttackRng.new(4242)
	check(FlavorLogic.binomial(rng, NAN, 0.5) == 0 and FlavorLogic.binomial(rng, 10, NAN) == 0, "binomial NaN")
	check(FlavorLogic.binomial(rng, -5, 0.5) == 0 and FlavorLogic.binomial(rng, 10, 0) == 0, "binomial empty")
	check(FlavorLogic.binomial(rng, 10, 1) == 10 and FlavorLogic.binomial(rng, 10.9, 2) == 10, "binomial p >= 1")
	for _, case in { { n = 400, p = 0.01 }, { n = 5000, p = 0.05 }, { n = 100000, p = 0.3 } } do
		local sum, sumSq, samples = 0, 0, 4000
		for _ = 1, samples do
			local k = FlavorLogic.binomial(rng, case.n, case.p)
			check(k >= 0 and k <= case.n and k == math.floor(k), "binomial in [0, n], whole")
			sum += k
			sumSq += k * k
		end
		local mean = sum / samples
		local variance = sumSq / samples - mean * mean
		local expectedMean = case.n * case.p
		local expectedVariance = expectedMean * (1 - case.p)
		check(near(mean, expectedMean, 5 * math.sqrt(expectedVariance / samples) + 0.05), `binomial mean {case.n}`)
		check(near(variance, expectedVariance, expectedVariance * 0.15 + 0.1), `binomial variance {case.n}`)
	end
end

check(FlavorLogic.bonusCycles({ 0, 1, 0, 0, 0 }) == 2, "one Glitter x3 = two extra batches")
check(FlavorLogic.bonusCycles({ 2, 0, 0, 0, 1 }) == 2 * 0.5 + 99, "bonus sums every flavour")
check(FlavorLogic.bonusCycles({ NAN, -3, "x" :: any, 0, 0 }) == 0, "bonus ignores junk counts")
check(FlavorLogic.bestRank({ 3, 0, 1, 0, 0 }) == 3 and FlavorLogic.bestRank({ 0, 0, 0, 0, 0 }) == 0, "bestRank")

--------------------------------------------------------------------------------------------------
-- 6. Event luck
--------------------------------------------------------------------------------------------------

check(FlavorLogic.eventLuck(os.time()) == 1, "no Happy Hour module under Lune → luck 1")

--------------------------------------------------------------------------------------------------
-- 7. Book state
--------------------------------------------------------------------------------------------------

check(FlavorLogic.key("dino", "galaxy") == "dino:galaxy", "key")
do
	local world, def = FlavorLogic.parseKey("main:rainbow")
	check(world == "main" and def ~= nil and def.id == "rainbow", "parse a good key")
	for _, junk in {
		"main:plain",
		"main:unknown",
		"Main:galaxy",
		"main:galaxy:x",
		":galaxy",
		"main:",
		"1main:galaxy",
		"main galaxy",
		string.rep("a", 17) .. ":galaxy",
		string.rep("x", 5000),
		5,
		NAN,
		{},
		nil,
	} do
		local w, d = FlavorLogic.parseKey(junk)
		check(w == nil and d == nil, `parse refuses {tostring(junk)}`)
	end
end

do
	local state = FlavorLogic.reconcileState({
		found = {
			["main:sprinkle"] = 12.9,
			["main:glitter"] = 0,
			["main:rainbow"] = NAN,
			["main:galaxy"] = -4,
			["main:plain"] = 9,
			["dino:mystery"] = 1e30,
			["future:galaxy"] = 3, -- a newer server's world: kept
			[7] = 5,
			bad = 2,
		},
		claimed = { ["main:sprinkle"] = true, ["main:glitter"] = "yes", ["main:nope"] = true, [1] = true },
	})
	check(state.found["main:sprinkle"] == 12, "reconcile floors counts")
	check(state.found["main:glitter"] == nil and state.found["main:rainbow"] == nil, "reconcile drops 0 / NaN")
	check(state.found["main:galaxy"] == nil and state.found["main:plain"] == nil, "reconcile drops negative / Plain")
	check(state.found["dino:mystery"] == FlavorConfig.MaxFoundCount, "reconcile caps counts")
	check(state.found["future:galaxy"] == 3, "reconcile keeps a newer server's world")
	check(state.found[7 :: any] == nil and state.found.bad == nil, "reconcile drops junk keys")
	check(state.claimed["main:sprinkle"] == true and state.claimed["main:glitter"] == nil, "claimed only true")
	check(state.claimed["main:nope"] == nil and state.claimed[1 :: any] == nil, "claimed keys must parse")
	check(state.tip == false, "reconcile: no tip flag → not seen")
	check(FlavorLogic.reconcileState({ tip = true }).tip == true, "reconcile keeps tip = true")
	check(FlavorLogic.reconcileState({ tip = "yes" }).tip == false, "reconcile: junk tip → false")
	check(FlavorLogic.newState().tip == false, "a fresh Book has not shown the tip")
	check(FlavorLogic.toWire({ found = {}, claimed = {}, tip = true }).tip == true, "toWire carries the tip flag")
	for _, junk in { nil, 5, "x", { found = 3, claimed = "y" } } do
		local repaired = FlavorLogic.reconcileState(junk)
		check(next(repaired.found) == nil and next(repaired.claimed) == nil, `reconcile {tostring(junk)} → empty`)
	end
	local huge = { found = {}, claimed = {} }
	for index = 1, 5000 do
		huge.found[`w{index}:galaxy`] = 1
		huge.claimed[`w{index}:galaxy`] = true
	end
	local bounded = FlavorLogic.reconcileState(huge)
	local foundCount, claimedCount = 0, 0
	for _ in bounded.found do
		foundCount += 1
	end
	for _ in bounded.claimed do
		claimedCount += 1
	end
	check(foundCount <= FlavorConfig.MaxEntries and claimedCount <= FlavorConfig.MaxEntries, "reconcile bounds maps")
end

do
	local state = FlavorLogic.newState()
	check(FlavorLogic.addFound(state, "main", 4, 1) == true, "first Galaxy is a discovery")
	check(FlavorLogic.addFound(state, "main", 4, 3) == false, "second is not")
	check(state.found["main:galaxy"] == 4, "counts add up")
	check(FlavorLogic.addFound(state, "main", 0, 1) == false and FlavorLogic.addFound(state, "main", 9, 1) == false, "bad rank")
	check(FlavorLogic.addFound(state, "main", 1, NAN) == false and FlavorLogic.addFound(state, "main", 1, 0) == false, "bad count")
	check(state.found["main:sprinkle"] == nil, "refused adds change nothing")
	FlavorLogic.addFound(state, "dino", 5, 2e12)
	check(state.found["dino:mystery"] == FlavorConfig.MaxFoundCount, "addFound caps")

	-- Claims.
	local before = FlavorLogic.toWire(state)
	local code = FlavorLogic.claim(state, "main:sprinkle")
	check(code == "locked", "unfound flavour is locked")
	for _, junk in { "moonbase:galaxy", "main:plain", 5, nil, "main:galaxy:2", "future:galaxy" } do
		check(FlavorLogic.claim(state, junk) == "bad", `claim refuses {tostring(junk)}`)
	end
	check(next(state.claimed) == nil and state.found["main:galaxy"] == before.found["main:galaxy"], "refusals change nothing")
	check(#FlavorLogic.claimable(state) == 2 and FlavorLogic.claimableCount(state) == 2, "two rewards ready")
	check(FlavorLogic.claimable(state)[1] == "main:galaxy", "claimable in Book order (worlds, then rank)")
	local ok, def, key = FlavorLogic.claim(state, "main:galaxy")
	check(ok == "ok" and def ~= nil and def.id == "galaxy" and key == "main:galaxy", "claim ok")
	check(FlavorLogic.claim(state, "main:galaxy") == "claimed", "claim is idempotent")
	check(FlavorLogic.claimableCount(state) == 1, "one reward left")
	check(FlavorLogic.discovered(state) == 2 and FlavorLogic.discovered(state, "main") == 1, "discovered")
	check(FlavorLogic.total() == 15, "Book size = 5 flavours x 3 worlds")

	-- Wire copies + junk.
	local wire = FlavorLogic.toWire(state)
	wire.found["main:galaxy"] = 999
	wire.claimed["dino:mystery"] = true
	check(state.found["main:galaxy"] == 4 and state.claimed["dino:mystery"] == nil, "toWire is a copy")
	check(FlavorLogic.claimableCount(nil) == 0 and FlavorLogic.claimableCount(5) == 0, "claimableCount junk")
	check(FlavorLogic.claimableCount({ found = "x" }) == 0, "claimableCount junk map")
	check(FlavorLogic.claimableCount({ found = { ["main:sprinkle"] = 1 } }) == 1, "claimableCount without claimed")
	check(FlavorLogic.discovered(nil) == 0, "discovered junk")
end

--------------------------------------------------------------------------------------------------
-- 8. Quest credit
--------------------------------------------------------------------------------------------------

do
	local credit, bank = FlavorLogic.creditStep(10, 0, 20, 10, 50)
	check(credit == 10 and bank == 0, "burst spends the bucket")
	credit, bank = FlavorLogic.creditStep(bank, 30, 20, 10, 50)
	check(credit == 10 and bank == 0, "30 s refill at 20 / min caps at the burst")
	credit, bank = FlavorLogic.creditStep(0, 6, 20, 10, 5)
	check(credit == 2 and near(bank, 0, 1e-9), "6 s = 2 tokens")
	credit, bank = FlavorLogic.creditStep(3, 0, 20, 10, 0)
	check(credit == 0 and bank == 3, "nothing earned keeps the bank")
	credit, bank = FlavorLogic.creditStep(NAN, NAN, 20, 10, NAN)
	check(credit == 0 and bank == 0, "hostile values")
	credit, bank = FlavorLogic.creditStep(1e9, 1e9, 20, 10, 1e9)
	check(credit == 10 and bank == 0, "huge values clamp to the burst")
end

--------------------------------------------------------------------------------------------------
-- 9. ProfileLogic
--------------------------------------------------------------------------------------------------

do
	local profile = ProfileLogic.defaultProfile() :: any
	check(type(profile.flavors) == "table" and next(profile.flavors.found) == nil, "default profile: empty Book")
	local repaired = ProfileLogic.reconcile({ flavors = { found = { ["main:glitter"] = 3, ["main:x"] = 2 } } }) :: any
	check(repaired.flavors.found["main:glitter"] == 3 and repaired.flavors.found["main:x"] == nil, "reconcile flavors")
	local legacy = ProfileLogic.reconcile({}) :: any
	check(type(legacy.flavors) == "table" and next(legacy.flavors.claimed) == nil, "pre-R89 saves get an empty Book")
	local context = { saveStatus = "ok", paidRandomRestricted = false, policyKnown = true }
	local snapshot = ProfileLogic.snapshot(repaired, context, { "flavors" })
	check(snapshot.flavors.found["main:glitter"] == 3, "snapshot carries the Book")
	snapshot.flavors.found["main:glitter"] = 1
	check(repaired.flavors.found["main:glitter"] == 3, "snapshot is a copy")
	check(table.find(ProfileLogic.SnapshotFields, "flavors") ~= nil, "flavors is a snapshot field")
	local saved = ProfileLogic.toSave(repaired)
	check(saved.flavors.found["main:glitter"] == 3, "toSave keeps the Book")
end

print(`flavor-logic: {checks} checks passed`)
