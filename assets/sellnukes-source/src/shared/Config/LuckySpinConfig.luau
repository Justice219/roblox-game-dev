--!strict
--[[
	LuckySpinConfig — the Lucky Wheel (design spec §7): a free spin every 20 minutes (stacking to
	3), bonus spins from free rewards, paid spins from the x2 / x5 / x10 products and the packs,
	8 server-rolled weighted slices.

	State (profile.spin = { free, lastFreeAt, paid, bonus }):
		free        timer spins banked (0..MaxFree)
		lastFreeAt  unix time the free-spin timer last started (0 = not started yet: the timer
		            starts on first contact, so nobody gets a backfill of free spins)
		bonus       spins from FREE rewards (daily, time rewards, codes, notify, admin) — never a
		            paid random item, always spinnable
		paid        ROBUX-sourced spins (Spins2/5/10 receipts, Starter / Secret Pack for buyers
		            whose region allows paid random items; saves from before the split keep every
		            old spin here, fail closed)
	Spend order: free → bonus → paid. While `free` is at MaxFree the timer is idle; it restarts
	the moment a spin brings `free` below MaxFree.

	PAID RANDOM ITEMS (PolicyService ArePaidRandomItemsRestricted; docs/retention.md): a paid spin
	is a paid random item. The Spins products are `paidRandom` (prompt refused for a restricted /
	unknown policy); spending a paid spin re-checks the policy on the server every time (fail
	closed); a Spins receipt for a buyer whose policy is unknown is deferred, and a KNOWN
	restricted buyer gets GemsPerSpin gems per spin instead. Starter / Secret Pack stay on sale
	for everyone, but where paid random items are restricted (or the policy is unknown at the
	receipt) their spins are paid as GemsPerSpin gems each — a fixed, non-random equivalent the
	pack card shows.

	Slices: `weight` decides the odds (sum = 100, so weight = % chance; shown on the wheel's info
	line). Cash slices are income-scaled (RetentionConfig.Reward). The egg / pet slices pay their
	`fallbackGems` until the pets system (B9) registers a granter.

	Example:
		local view = LuckySpinConfig.status(profile.spin, now)
		print(view.free, view.bonus, view.paid, view.nextFreeIn)
]]

local RetentionConfig = require(script.Parent.RetentionConfig)

export type Slice = {
	id: string, -- stable id (analytics "wheel:slice:<id>")
	label: string, -- short caption ("CASH" captions show the client's income-scaled amount)
	icon: string, -- IconAssets key
	color: Color3, -- slice colour on the wheel
	weight: number, -- relative odds (the weights sum to 100)
	reward: RetentionConfig.Reward,
}

-- free = timer spins, bonus = free reward spins, paid = Robux spins (see the header).
export type Status = { free: number, bonus: number, paid: number, nextFreeIn: number }

local LuckySpinConfig = {}

LuckySpinConfig.FreeEverySeconds = 20 * 60
LuckySpinConfig.MaxFree = 3

-- The fixed gem value of one paid spin where paid random items are restricted: the Spins5 price
-- (79 R$ / 5 spins) at the GemsSmall rate (100 gems / 39 R$) ≈ 40 gems. Starter Pack 5 spins →
-- 200 gems, Secret Pack 10 spins → 400 gems, a restricted Spins5 receipt → 200 gems.
LuckySpinConfig.GemsPerSpin = 40

--[[ Player-facing texts of the paid-random gate (wheel screen, server refusals, pack cards). ]]
LuckySpinConfig.PolicyText = table.freeze({
	-- SPIN button while only paid spins are left and the region restricts them.
	Button = "UNAVAILABLE",
	-- Wheel info line in that state.
	Restricted = "Bought spins aren't available in your region. Free spins still work!",
	-- Server refusal: restricted.
	RefusedRestricted = "Bought spins aren't available in your region. Free spins still work!",
	-- Server refusal: PolicyService has not answered yet (fail closed).
	RefusedUnknown = "We couldn't check if bought spins are available for you yet. Try again in a moment!",
})

-- Request handling: per-player token bucket and how many answered request ids are remembered
-- (a retried request id gets the same answer instead of a second spin).
LuckySpinConfig.SpinLimit = table.freeze({ Burst = 3, PerSecond = 0.5 })
LuckySpinConfig.RememberResults = 8

-- Client animation length (seconds) of one spin; the result is applied server-side at once.
LuckySpinConfig.SpinAnimationSeconds = 4

local SLICES: { Slice } = {
	{
		id = "cashS",
		label = "CASH",
		icon = "Cash",
		color = Color3.fromRGB(235, 64, 64),
		weight = 26,
		reward = { cashSeconds = 120, cashFloor = 500 },
	},
	{
		id = "gemsS",
		label = "5 GEMS",
		icon = "Gems",
		color = Color3.fromRGB(250, 214, 60),
		weight = 18,
		reward = { gems = 5 },
	},
	{
		id = "cashM",
		label = "CASH",
		icon = "Cash",
		color = Color3.fromRGB(110, 214, 70),
		weight = 18,
		reward = { cashSeconds = 600, cashFloor = 2_500 },
	},
	{
		id = "boost",
		label = "2x CASH",
		icon = "x2Cash",
		color = Color3.fromRGB(80, 180, 240),
		weight = 12,
		reward = { boost = { key = "cash2x", seconds = 600 } },
	},
	{
		id = "cashL",
		label = "CASH",
		icon = "Cash",
		color = Color3.fromRGB(160, 90, 230),
		weight = 10,
		reward = { cashSeconds = 1_800, cashFloor = 10_000 },
	},
	{
		id = "gemsL",
		label = "25 GEMS",
		icon = "Gems",
		color = Color3.fromRGB(255, 150, 50),
		weight = 8,
		reward = { gems = 25 },
	},
	{
		id = "egg",
		label = "EGG",
		icon = "Gift",
		color = Color3.fromRGB(255, 120, 190),
		weight = 6,
		reward = { egg = "lucky_egg", fallbackGems = 15 },
	},
	{
		id = "pet",
		label = "RARE PET",
		icon = "Pets",
		color = Color3.fromRGB(40, 210, 190),
		weight = 2,
		reward = { pet = "lucky_atom", fallbackGems = 60 },
	},
}
for _, slice in SLICES do
	if slice.reward.boost ~= nil then
		table.freeze(slice.reward.boost)
	end
	table.freeze(slice.reward)
	table.freeze(slice)
end
LuckySpinConfig.Slices = table.freeze(SLICES)

local TOTAL_WEIGHT = 0
local BY_ID: { [string]: number } = {}
for index, slice in SLICES do
	TOTAL_WEIGHT += slice.weight
	BY_ID[slice.id] = index
end
LuckySpinConfig.TotalWeight = TOTAL_WEIGHT

--[[ The 1-based index of a slice id, or nil (analytics id validation, client lookups). ]]
function LuckySpinConfig.indexOf(id: string): number?
	return BY_ID[id]
end

--[[
	Free spins available at `now` and seconds until the next one (0 when banked at MaxFree), plus
	the bonus / paid banks. Read-only mirror of WheelLogic.refill (the server's mutation) for the
	screen's timer. A missing `bonus` (older snapshot) reads as 0.
]]
function LuckySpinConfig.status(
	spin: { free: number, lastFreeAt: number, paid: number, bonus: number },
	now: number
): Status
	local free = math.clamp(spin.free, 0, LuckySpinConfig.MaxFree)
	local every = LuckySpinConfig.FreeEverySeconds
	-- (A malformed / missing bonus reads as 0: the typed field can still be absent in old data.)
	local bonus = math.max(0, if type(spin.bonus) == "number" then spin.bonus else 0)
	local paid = math.max(0, spin.paid)
	if free >= LuckySpinConfig.MaxFree or spin.lastFreeAt <= 0 then
		return {
			free = free,
			bonus = bonus,
			paid = paid,
			nextFreeIn = if free >= LuckySpinConfig.MaxFree then 0 else every,
		}
	end
	local elapsed = math.max(0, now - spin.lastFreeAt)
	local gained = elapsed // every
	free = math.min(LuckySpinConfig.MaxFree, free + gained)
	local nextIn = if free >= LuckySpinConfig.MaxFree then 0 else every - (elapsed % every)
	return { free = free, bonus = bonus, paid = paid, nextFreeIn = nextIn }
end

--[[
	Which bank the next spin would use: "free" → "bonus" → "paid", or nil when none is left. Pure
	read of a Status (the client's button state; the server decides with WheelLogic).
	Example: LuckySpinConfig.nextSource({ free = 0, bonus = 0, paid = 2, nextFreeIn = 60 }) --> "paid"
]]
function LuckySpinConfig.nextSource(status: Status): ("free" | "bonus" | "paid")?
	if status.free > 0 then
		return "free"
	elseif status.bonus > 0 then
		return "bonus"
	elseif status.paid > 0 then
		return "paid"
	end
	return nil
end

return table.freeze(LuckySpinConfig)
