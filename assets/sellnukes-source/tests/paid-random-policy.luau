--!strict
--[[
	Paid random items × PolicyService for the Lucky Wheel, the Starter / Secret Packs and the Turkey
	Lure (the eggs / crates matrix lives in tests/pets-policy.luau). Run:
		lune run tests/paid-random-policy

	Proves on the shipped modules (src/server/Economy/PolicyCache, src/server/Retention/{WheelLogic,
	RewardLogic}, src/server/Event/EventLogic, src/shared/Config/{MonetizationConfig,
	LuckySpinConfig, ShopConfig, RetentionConfig, CodesConfig, EventConfig}):
	  1. Flags: every product whose content is random (Spins, Crate, TurkeyLure kinds) is
	     paidRandom (MonetizationService refuses its prompt for a restricted / unknown policy);
	     the packs are NOT (on sale for everyone) and nothing else is.
	  2. The REAL PolicyCache's answers: restricted, five unknown variants, unrestricted.
	  3. Wheel × every answer: a Robux (paid) spin → refused / refused / allowed (nothing changes
	     on a refusal); timer + bonus (free reward) spins spin in every state, before paid ones.
	  4. Spins receipts × every answer: unknown → deferred, restricted → GemsPerSpin gems,
	     unrestricted → paid spins.
	  5. Starter / Secret Pack × every answer: the receipt rule (RewardLogic.robuxReward) gives
	     PAID spins only to a known-unrestricted buyer and the fixed gem equivalent otherwise; the
	     pack card's lines (ShopConfig.packLines) match exactly what is granted.
	  6. Turkey Lure × every answer: the sticker roll happens only for an allowed policy; anyone
	     else gets the fixed acorns with no random draw.
	  7. Free rewards (daily / time / codes / notify spins) land in the bonus bank and are always
	     spinnable.
]]

local task = require("@lune/task")

local Loader = require("./fixtures/RobloxLoader")

local loader = Loader.new()
local ProfileLogic = loader.load("src/server/Economy/ProfileLogic")
local PolicyCache = loader.load("src/server/Economy/PolicyCache")
local WheelLogic = loader.load("src/server/Retention/WheelLogic")
local RewardLogic = loader.load("src/server/Retention/RewardLogic")
local EventLogic = loader.load("src/server/Event/EventLogic")
local MonetizationConfig = loader.load("src/shared/Config/MonetizationConfig")
local LuckySpinConfig = loader.load("src/shared/Config/LuckySpinConfig")
local ShopConfig = loader.load("src/shared/Config/ShopConfig")
local RetentionConfig = loader.load("src/shared/Config/RetentionConfig")
local EventConfig = loader.load("src/shared/Config/EventConfig")
local CodesConfig = loader.load("src/shared/Config/CodesConfig")

local checks = 0
local function check(ok: boolean, label: string)
	if not ok then
		error(label, 2)
	end
	checks += 1
end

local NOW = 1_800_000_000

-- 1. Flags ------------------------------------------------------------------------------------------
-- Product kinds whose content is decided by a roll after paying Robux.
local RANDOM_KINDS = { Spins = true, Crate = true, TurkeyLure = true }
do
	for key, product in MonetizationConfig.Products do
		local random = RANDOM_KINDS[product.kind] == true
		check(product.paidRandom == random, `{key}: paidRandom must be {random}`)
	end
	check(MonetizationConfig.Products.TurkeyLure.paidRandom, "Turkey Lure is a paid random item")
	check(not MonetizationConfig.Products.StarterPack.paidRandom, "Starter Pack stays on sale for everyone")
	check(not MonetizationConfig.Products.SecretPack.paidRandom, "Secret Pack stays on sale for everyone")
	check(LuckySpinConfig.GemsPerSpin == 40, "documented spin → gems rate")
end

-- 2. The REAL PolicyCache's answers (fail closed) ------------------------------------------------
type Answer = { name: string, restricted: boolean, known: boolean }

-- Runs `fn` on its own thread (resolveAsync yields) and waits for it (bounded).
local function await<T>(fn: () -> T): T
	local done, result = false, nil :: any
	task.spawn(function()
		result = fn()
		done = true
	end)
	local waited = 0
	while not done and waited < 3 do
		waited += task.wait(0.01)
	end
	assert(done, "await timed out")
	return result
end

local function answerFrom(name: string, fetch: (any) -> unknown): Answer
	-- One attempt per lookup (see tests/pets-policy.luau: a Lune 0.10 exit quirk with retries).
	local cache = PolicyCache.new({ fetch = fetch, attempts = 1, backoff = 0, timeout = 0.05, retryCooldown = 30 })
	local key = { name = name }
	local restricted = await(function()
		return cache:resolveAsync(key)
	end)
	return { name = name, restricted = restricted, known = cache:isKnown(key) }
end

local releasePending = false
local ANSWERS: { Answer } = {
	answerFrom("restricted", function()
		return { ArePaidRandomItemsRestricted = true }
	end),
	answerFrom("unrestricted", function()
		return { ArePaidRandomItemsRestricted = false }
	end),
	answerFrom("failing", function()
		error("HTTP 503")
	end),
	answerFrom("missing flag", function()
		return {}
	end),
	answerFrom("wrong type", function()
		return { ArePaidRandomItemsRestricted = 0 }
	end),
	answerFrom("not a table", function()
		return true
	end),
	answerFrom("pending", function()
		while not releasePending do
			task.wait(0.01)
		end
		return { ArePaidRandomItemsRestricted = false }
	end),
}
releasePending = true

-- What the services compute from an answer: only KNOWN + unrestricted allows paid random items.
local function allowed(answer: Answer): boolean
	return answer.known and not answer.restricted
end
do
	local allowedCount = 0
	for _, answer in ANSWERS do
		if allowed(answer) then
			allowedCount += 1
			check(answer.name == "unrestricted", `only the unrestricted answer allows ({answer.name})`)
		else
			check(answer.restricted, `{answer.name} fails closed`)
		end
	end
	check(allowedCount == 1, "exactly one allowing answer")
end

-- 3. Wheel × every answer ---------------------------------------------------------------------------
for _, answer in ANSWERS do
	-- Only Robux spins left: refused unless allowed, and nothing changes on a refusal.
	local spin = { free = 0, lastFreeAt = NOW, paid = 3, bonus = 0 }
	check(WheelLogic.peek(spin, NOW) == "paid", `{answer.name}: next spin is paid`)
	local source, why = WheelLogic.consume(spin, NOW, allowed(answer))
	if allowed(answer) then
		check(source == "paid" and spin.paid == 2, `{answer.name}: paid spin allowed`)
	else
		check(source == nil and why == "restricted" and spin.paid == 3, `{answer.name}: paid spin refused, kept`)
	end
	-- Timer and bonus spins are free: always spinnable, and always spent before paid ones.
	local mixed = { free = 1, lastFreeAt = NOW, paid = 5, bonus = 1 }
	check(WheelLogic.consume(mixed, NOW, allowed(answer)) == "free", `{answer.name}: timer spin`)
	check(WheelLogic.consume(mixed, NOW, allowed(answer)) == "bonus", `{answer.name}: bonus spin`)
	check(mixed.paid == 5, `{answer.name}: paid untouched while free spins remain`)
end

-- 4. Spins receipts × every answer ------------------------------------------------------------------
for _, answer in ANSWERS do
	local profile = ProfileLogic.defaultProfile() :: any
	local outcome, amount = WheelLogic.receipt(profile, 10, answer.known, answer.restricted)
	local expected = if not answer.known then "defer" elseif answer.restricted then "gems" else "spins"
	check(outcome == expected, `{answer.name}: Spins10 receipt {outcome} (expected {expected})`)
	if outcome == "spins" then
		check(amount == 10 and profile.spin.paid == 10, "paid spins added")
	elseif outcome == "gems" then
		check(amount == 10 * LuckySpinConfig.GemsPerSpin and profile.spin.paid == 0, "gems instead, no spins")
	else
		check(amount == 0 and profile.spin.paid == 0, "deferred: nothing changed")
	end
end

-- 5. Starter / Secret Pack × every answer -----------------------------------------------------------
for _, packName in { "StarterPack", "SecretPack" } do
	local pack = ShopConfig[packName]
	local spins = pack.reward.spins :: number
	check(spins > 0 and pack.spinLine ~= nil, `{packName} has a spins line`)
	for _, answer in ANSWERS do
		local profile = ProfileLogic.defaultProfile() :: any
		local reward, options = RewardLogic.robuxReward(pack.reward, allowed(answer), LuckySpinConfig.GemsPerSpin)
		local summary = RewardLogic.apply(profile, reward, NOW, nil, 0, options)
		local lines = ShopConfig.packLines(pack, not allowed(answer))
		if allowed(answer) then
			check(profile.spin.paid == spins and profile.spin.bonus == 0, `{packName} × {answer.name}: paid spins`)
			check(summary.spins == spins, `{packName}: spins summary`)
			check(lines[pack.spinLine] == pack.lines[pack.spinLine], `{packName}: card shows spins`)
		else
			local fallback = pack.reward.fallbackGems or 0
			local expectedGems = (pack.reward.gems or 0) + spins * LuckySpinConfig.GemsPerSpin + fallback
			check(profile.spin.paid == 0 and profile.spin.bonus == 0, `{packName} × {answer.name}: no spins at all`)
			check(summary.spins == 0, `{packName} × {answer.name}: spins summary 0`)
			check(profile.gems == expectedGems, `{packName} × {answer.name}: gems {profile.gems} vs {expectedGems}`)
			check(
				lines[pack.spinLine] == `{spins * LuckySpinConfig.GemsPerSpin} Gems`,
				`{packName}: card shows the gem equivalent`
			)
		end
		-- The frozen config is never mutated by the conversion.
		check(pack.reward.spins == spins, `{packName}: config untouched`)
	end
end

-- 6. Turkey Lure × every answer --------------------------------------------------------------------
for _, answer in ANSWERS do
	local draws = 0
	local rng = function(): number
		draws += 1
		return 0.4
	end
	local reward = EventLogic.rollReward({}, true, rng, allowed(answer))
	if allowed(answer) then
		check(reward.sticker >= 1 and draws >= 2, `lure × {answer.name}: sticker rolled`)
	else
		check(reward.sticker == 0 and draws == 0, `lure × {answer.name}: no roll`)
		check(
			reward.acorns == EventConfig.Rewards.AcornsMax * EventConfig.Rewards.LureMultiplier,
			`lure × {answer.name}: fixed acorns`
		)
	end
end
check(type(EventConfig.LurePolicyText) == "string" and #EventConfig.LurePolicyText > 0, "lure region text")

-- 7. Free reward spins are bonus spins -----------------------------------------------------------------
do
	local found = 0
	local function freeReward(reward: any, label: string)
		if reward == nil or reward.spins == nil then
			return
		end
		found += 1
		for _, answer in ANSWERS do
			local profile = ProfileLogic.defaultProfile() :: any
			profile.spin.free = 0
			RewardLogic.apply(profile, reward, NOW, nil, 0)
			check(profile.spin.bonus == reward.spins and profile.spin.paid == 0, `{label}: bonus spins`)
			check(WheelLogic.consume(profile.spin, NOW, allowed(answer)) == "bonus", `{label} × {answer.name}: spins`)
		end
	end
	for index, day in RetentionConfig.Days do
		freeReward(day.reward, `daily {index}`)
	end
	freeReward(RetentionConfig.Notify.Reward, "notify")
	for _, code in CodesConfig.Codes do
		freeReward(code.reward, `code {code.id}`)
	end
	check(found >= 1, "at least one free reward grants spins")
end

print(`[paid-random-policy] {checks} checks passed`)
