--!strict
--[[
	RewardLogic — turns a RetentionConfig.Reward definition into what the player actually gets,
	and applies it to a profile in ONE non-yielding step. Every retention / shop grant goes through
	`apply` (daily, time rewards, wheel slices, codes, group, notify, Starter / Secret Pack, cash
	packs), so caps, income scaling and fallbacks behave the same everywhere.

	Rules:
		cash   max(cashFloor, cashSeconds × income), where income = automated $/s of the profile's
		       tycoon with permanent rebirth bonuses only (TycoonLogic.incomePerSecond) — timed
		       boosts and passes never inflate a reward; always finite, never negative
		gems   whole, ProfileLogic caps
		spins  Lucky Wheel spins, capped: into profile.spin.bonus (FREE reward spins — daily, codes,
		       notify, admin; never a paid random item) unless the caller says they were bought
		       with Robux (options.paidSpins → profile.spin.paid, re-checked against PolicyService
		       when spent). Robux packs for a buyer whose region restricts paid random items use
		       spinsAsGems first (a fixed gem equivalent instead of spins).
		boost  BoostLogic.extend (stacking, capped)
		pet / egg  the registered item granter for that kind (B9 pets system) when present and it
		       returns true; otherwise `fallbackGems` is paid instead, so a reward never vanishes
	Item granters MUST NOT yield (they run inside receipt grant steps too).

	Connects to: RetentionConfig (Reward), ProfileLogic (currency caps), BoostLogic, TycoonLogic,
	every B7 service (RewardGrant.grant wraps `apply` with markChanged + analytics).

	Example:
		local summary = RewardLogic.apply(profile, { cashSeconds = 300, cashFloor = 1000, gems = 10 }, os.time())
		print(RewardLogic.describe(summary)) --> "+$1K, +10 Gems"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local BoostLogic = require(script.Parent.BoostLogic)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local ProfileLogic = require(ServerScriptService.Server.Economy.ProfileLogic)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)

type Profile = ProfileLogic.Profile
type Reward = RetentionConfig.Reward

-- What a reward actually paid (all zero / nil when nothing of that kind).
export type Summary = {
	cash: number,
	gems: number,
	spins: number,
	boost: RetentionConfig.BoostGrant?,
	pet: string?, -- granted pet id
	egg: string?, -- granted egg id
	fallbackGems: number, -- gems paid because an item could not be granted (included in gems)
	fields: { string }, -- top-level snapshot fields touched (PlayerDataService.markChanged)
}

-- An item granter registered by the pets system: grants `id` into the profile, no yield.
export type ItemGranter = (profile: Profile, id: string) -> boolean
export type Granters = { pet: ItemGranter?, egg: ItemGranter? }
-- paidSpins: the reward was bought with Robux, so its spins are PAID (Robux-sourced) spins.
export type ApplyOptions = { paidSpins: boolean? }

local RewardLogic = {}

-- True for a finite number.
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	The automated income ($/s) rewards scale with: managed producers × permanent rebirth bonuses.
	Example: RewardLogic.incomeOf(profile) --> 1234.5
]]
function RewardLogic.incomeOf(profile: Profile): number
	local ok, income = pcall(
		TycoonLogic.incomePerSecond,
		profile.tycoon :: any,
		{
			rebirths = profile.rebirths,
			rebirthShop = profile.rebirthShop,
		} :: any
	)
	if not ok or not finite(income) or income < 0 then
		return 0
	end
	return income
end

--[[ The cash a reward pays at `income` $/s (0 when the reward has no cash part). ]]
function RewardLogic.cashFor(reward: Reward, income: number): number
	local seconds = reward.cashSeconds
	local floor = reward.cashFloor
	if seconds == nil and floor == nil then
		return 0
	end
	local scaled = if seconds ~= nil and finite(income) and income > 0 then seconds * income else 0
	local cash = math.max(floor or 0, scaled)
	if not finite(cash) or cash <= 0 then
		return 0
	end
	return math.floor(cash)
end

--[[
	Applies `reward` to `profile` (mutates it; never yields).
	@param now      unix seconds (boost expiry)
	@param granters item granters (pets / eggs); nil entries pay the fallback gems
	@param income   optional precomputed income (default RewardLogic.incomeOf(profile))
	@param options  paidSpins = true for Robux-bought rewards (spins → profile.spin.paid)
	@return the Summary of what was paid
]]
function RewardLogic.apply(
	profile: Profile,
	reward: Reward,
	now: number,
	granters: Granters?,
	income: number?,
	options: ApplyOptions?
): Summary
	local summary: Summary = { cash = 0, gems = 0, spins = 0, fallbackGems = 0, fields = {} }
	local touched: { [string]: boolean } = {}

	local cash = RewardLogic.cashFor(reward, income or RewardLogic.incomeOf(profile))
	if cash > 0 then
		summary.cash = ProfileLogic.addCash(profile, cash)
		touched.cash, touched.totalEarned = true, true
	end
	local gems = 0
	if reward.gems ~= nil then
		gems += reward.gems
	end
	-- Items: the registered granter, else their fallback gems.
	local function item(kind: "pet" | "egg", id: string?)
		if id == nil then
			return
		end
		local granter = if granters == nil then nil elseif kind == "pet" then granters.pet else granters.egg
		if granter ~= nil then
			local ok, granted = pcall(granter, profile, id)
			if ok and granted == true then
				if kind == "pet" then
					summary.pet = id
				else
					summary.egg = id
				end
				touched.pets = true
				return
			end
		end
		local fallback = reward.fallbackGems or 0
		summary.fallbackGems += fallback
		gems += fallback
	end
	item("pet", reward.pet)
	item("egg", reward.egg)
	if gems > 0 then
		summary.gems = ProfileLogic.addGems(profile, gems)
		touched.gems = true
	end
	local spins = reward.spins
	if spins ~= nil and finite(spins) and spins > 0 then
		-- Robux-bought spins are paid random items (gated when spent); every other source is free.
		local add = math.floor(spins)
		local cap = ProfileLogic.Limits.MaxSpins
		local spin = profile.spin
		if options ~= nil and options.paidSpins == true then
			local before = if finite(spin.paid) then spin.paid else 0
			spin.paid = math.min(before + add, cap)
			summary.spins = spin.paid - before
		else
			local before = if finite(spin.bonus) then spin.bonus else 0
			spin.bonus = math.min(before + add, cap)
			summary.spins = spin.bonus - before
		end
		touched.spin = true
	end
	local boost = reward.boost
	if boost ~= nil and BoostLogic.extend(profile.boosts, boost.key, boost.seconds, now) ~= nil then
		summary.boost = boost
		touched.boosts = true
	end
	for field in touched do
		table.insert(summary.fields, field)
	end
	table.sort(summary.fields)
	return summary
end

--[[
	A Robux reward with its spins replaced by a FIXED gem equivalent (`gemsPerSpin` each, added to
	the reward's gems) — what a Starter / Secret Pack pays where paid random items are restricted
	(LuckySpinConfig.GemsPerSpin). Returns the reward unchanged when it has no spins. Never mutates
	the (frozen) config table.
	Example: RewardLogic.spinsAsGems({ gems = 100, spins = 5 }, 40) --> { gems = 300 }
]]
function RewardLogic.spinsAsGems(reward: Reward, gemsPerSpin: number): Reward
	local spins = reward.spins
	if spins == nil or not finite(spins) or spins <= 0 then
		return reward
	end
	local copy = table.clone(reward) :: any
	copy.spins = nil
	copy.gems = (reward.gems or 0) + math.floor(spins) * gemsPerSpin
	return copy :: Reward
end

--[[
	What a Robux-bought reward (Starter / Secret Pack) actually grants for one buyer: where paid
	random items are allowed (`allowPaidRandom` = the policy is KNOWN and unrestricted) the reward
	as configured with its spins in the PAID bank; otherwise (restricted OR unknown — fail closed)
	the reward with its spins swapped for `gemsPerSpin` gems each. Pure.
	@return (reward to apply, apply options)
	Example: RewardLogic.robuxReward(pack, false, 40) --> { gems = 300, ... }, { paidSpins = false }
]]
function RewardLogic.robuxReward(reward: Reward, allowPaidRandom: boolean, gemsPerSpin: number): (Reward, ApplyOptions)
	if allowPaidRandom == true then
		return reward, { paidSpins = true }
	end
	return RewardLogic.spinsAsGems(reward, gemsPerSpin), { paidSpins = false }
end

--[[
	A short player-facing line for a summary (toasts): "+$1.25K, +10 Gems, +2 Spins, 2x Cash 10m".
]]
function RewardLogic.describe(summary: Summary): string
	local parts: { string } = {}
	if summary.cash > 0 then
		table.insert(parts, "+" .. NumberFormat.money(summary.cash))
	end
	if summary.gems > 0 then
		table.insert(parts, `+{NumberFormat.commas(summary.gems)} Gems`)
	end
	if summary.spins > 0 then
		table.insert(parts, `+{summary.spins} Spin{if summary.spins == 1 then "" else "s"}`)
	end
	if summary.boost ~= nil then
		local def = BoostConfig.get(summary.boost.key)
		local name = if def ~= nil then def.name else summary.boost.key
		table.insert(parts, `{name} {NumberFormat.duration(summary.boost.seconds)}`)
	end
	if summary.pet ~= nil then
		table.insert(parts, "a new pet")
	end
	if summary.egg ~= nil then
		table.insert(parts, "an egg")
	end
	if #parts == 0 then
		return "nothing"
	end
	return table.concat(parts, ", ")
end

return table.freeze(RewardLogic)
