--!strict
--[[
	CrateConfig — Supply Crates (design spec §8): three crates bought with GEMS or ROBUX that roll
	one reward each — a timed boost, gems, held eggs, a pet or a cosmetic trail — plus the trail
	catalogue the crates hand out.

	Odds (published = rolled): each crate lists rewards with a weight in basis points of TotalBp
	(100,000 = 100 %). Roll = NextInteger(1, TotalBp) over the cumulative weights
	(Server/Pets/CrateLogic.rollReward). Every reward has a display rarity (PetConfig.Rarities)
	for the reveal colour and for PITY: `pity = { rank, opens }` — the `opens`-th open in a row
	without a reward of rarity rank >= `rank` is re-rolled among those rewards proportional to
	their weights. Counter: profile.crates.pity[crateId].

	Paying (EVERY crate open is a PAID RANDOM ITEM — PaidRandomPay below):
		gems   CrateDef.gems from profile.gems (OpenCrate remote). Gems are sold for Robux
		       (GemsSmall/Medium/Large, StarterPack, SecretPack), so a gem crate is a paid random
		       item: refused unless PolicyService says the player may buy them (fail closed).
		robux  MonetizationConfig product CrateDef.product (kind "Crate", paidRandom): the PROMPT
		       is refused for a restricted / unknown policy (MonetizationService); the receipt
		       defers while unknown, pays the gem price instead to a KNOWN restricted buyer, else
		       adds a HELD crate (profile.crates.held), opened with the same OpenCrate remote.
		held   held crates are opened first (no gems). They come ONLY from Robux receipts (and the
		       owner's admin GiveCrate), so a held crate IS a paid random item generator bought
		       with Robux: opening one is gated too (PolicyService "can not interact with paid
		       random item generators ... bought with Robux"). A player whose region restricts
		       them (e.g. after travelling) keeps the crates safe until they may open them.
		       If a FREE crate source is ever added, give it its own held pool first.
	Clients mirror the gate with EggConfig.policyState(profile.policy) (CrateShop / CrateOpen lock
	the buttons with PolicyText); the full odds are shown on every card before any purchase
	(the first press of a buy button flips the card to its odds) and as a summary line
	(oddsSummary) on the CrateOpen screen next to OPEN AGAIN.

	Rewards:
		boost  BoostConfig key + seconds (stacks via BoostLogic, capped by BoostConfig)
		gems   whole gems
		egg    held eggs (EggConfig id × count) — hatch anywhere from the Pets screen
		pet    a pet (PetConfig id); over the soft inventory cap it still lands (up to HardCap)
		trail  a cosmetic trail (Trails below); a trail already owned pays DupGems instead

	Ids are SAVE DATA (crates.held / crates.pity keys, trails.owned keys). Never rename one.

	Connects to: Shared/Config/{PetConfig, EggConfig, BoostConfig}, MonetizationConfig products
	CrateSupply / CrateMega / CrateGolden, Server/Pets/CrateLogic, Server/Services/CrateService,
	Server/Pets/TrailRenderer, UI/Screens/{CrateShop, CrateOpen}, tests/pets-crates.luau.

	Example:
		local crate = CrateConfig.get("supply_crate")
		print(crate.name, crate.gems, #crate.rewards) --> Supply Crate 120 9
]]

local BoostConfig = require(script.Parent.BoostConfig)
local EggConfig = require(script.Parent.EggConfig)
local PetConfig = require(script.Parent.PetConfig)

export type RewardKind = "boost" | "gems" | "egg" | "pet" | "trail"

export type Reward = {
	key: string, -- unique within the crate (analytics + UI)
	kind: RewardKind,
	id: string?, -- boost key / egg id / pet id / trail id
	amount: number, -- gems, egg count, 1 for pets / trails / boosts
	seconds: number, -- boost seconds (0 otherwise)
	rarity: PetConfig.Rarity, -- reveal colour + pity rank
	bp: number, -- weight in TotalBp
	label: string, -- short card text ("2x Cash 15m", "+150 Gems")
}

export type CrateDef = {
	id: string,
	name: string,
	order: number,
	gems: number, -- gem price
	product: string, -- MonetizationConfig product key (Robux)
	model: string, -- MeshAssets key (B8f crates.py; lid pieces Lid*)
	color: Color3,
	accent: Color3,
	ui: string, -- StudUI colour preset
	rewards: { Reward },
	pity: { rank: number, opens: number }?,
	dupGems: number, -- gems paid instead of a trail the player already owns
	blurb: string,
}

export type TrailDef = {
	id: string,
	name: string,
	rarity: PetConfig.Rarity,
	colors: { Color3 }, -- 2..5 colour keypoints along the trail
	width: number, -- studs
	lifetime: number, -- seconds
	lightEmission: number,
	order: number,
}

local CrateConfig = {}

CrateConfig.TotalBp = 100_000

-- Server tunables (CrateService).
CrateConfig.Server = table.freeze({
	OpenBurst = 3,
	OpenPerSecond = 1,
	RecentRequests = 32,
	MaxRequestId = 2 ^ 31,
	MaxHeld = 999, -- held crates per crate id (receipts beyond it still count, clamped here)
})

-- Payments that make an open a PAID RANDOM ITEM (PolicyService gate, fail closed; header). Both are
-- true today: gems are Robux-reachable and held crates are only sold for Robux. Every payment
-- kind MUST appear here (validate() checks it).
CrateConfig.PaidRandomPay = table.freeze({ gems = true, held = true }) :: { [string]: boolean }

--[[
	Player-facing texts of the paid-random gate (CrateShop, CrateOpen, server refusals).
]]
CrateConfig.PolicyText = table.freeze({
	-- Locked buy / open button caption while the region restricts paid random items (short: the
	-- card line explains why).
	Button = "UNAVAILABLE",
	-- Held crates while restricted: kept, not lost.
	KeptSafe = "KEPT SAFE",
	-- The card line (in place of the pity line) while restricted.
	CardLine = "Not available in your region",
	-- The card line while the server is still checking (fail closed: the server decides on press).
	Checking = "Checking your region...",
	-- Server refusal: the region restricts paid random items.
	RefusedRestricted = "Crates aren't available in your region. Your crates are kept safe!",
	-- Server refusal: PolicyService has not answered yet (fail closed).
	RefusedUnknown = "We couldn't check if crates are available for you yet. Try again in a moment!",
})

--[[
	True when an open paid with `pay` ("held" | "gems") is a paid random item (PaidRandomPay), i.e.
	the server must have an unrestricted PolicyService answer first. Unknown pay kinds are gated
	(fail closed).
	Example: CrateConfig.needsPolicy("held") --> true
]]
function CrateConfig.needsPolicy(pay: string): boolean
	return CrateConfig.PaidRandomPay[pay] ~= false
end

--------------------------------------------------------------------------------------------------
-- Trails (cosmetic; attached to the character by Server/Pets/TrailRenderer)
--------------------------------------------------------------------------------------------------

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Freezes a config record and keeps its declared (writable) type for the tables below; the new
-- type solver would otherwise narrow it to a read-only shape.
local function frozen<T>(value: T): T
	return table.freeze(value :: any) :: any
end

local TRAIL_LIST: { TrailDef } = {
	{
		id = "trail_green_glow",
		name = "Green Glow",
		rarity = "Rare",
		colors = { rgb(120, 255, 120), rgb(40, 200, 90) },
		width = 1.6,
		lifetime = 0.6,
		lightEmission = 0.8,
		order = 1,
	},
	{
		id = "trail_atom_orbit",
		name = "Atom Orbit",
		rarity = "Rare",
		colors = { rgb(90, 220, 255), rgb(255, 255, 255), rgb(90, 220, 255) },
		width = 1.8,
		lifetime = 0.7,
		lightEmission = 0.9,
		order = 2,
	},
	{
		id = "trail_gold_sparkle",
		name = "Gold Sparkle",
		rarity = "Epic",
		colors = { rgb(255, 230, 120), rgb(255, 180, 30), rgb(255, 250, 200) },
		width = 2,
		lifetime = 0.8,
		lightEmission = 1,
		order = 3,
	},
	{
		id = "trail_rainbow",
		name = "Rainbow Boom",
		rarity = "Legendary",
		colors = { rgb(255, 80, 80), rgb(255, 200, 60), rgb(90, 230, 90), rgb(80, 160, 255), rgb(200, 90, 255) },
		width = 2.2,
		lifetime = 1,
		lightEmission = 1,
		order = 4,
	},
	-- R78 Nuke Pass Season 1 EXCLUSIVE (premium tier 10, Shared/Config/PassConfig.Exclusives.Trail):
	-- in NO crate pool, so only the pass grants it. Autumn amber → pumpkin orange → harvest gold.
	{
		id = "harvest_glow",
		name = "Harvest Glow",
		rarity = "Legendary",
		colors = { rgb(255, 214, 90), rgb(255, 140, 40), rgb(214, 70, 30), rgb(255, 236, 160) },
		width = 2.1,
		lifetime = 0.9,
		lightEmission = 1,
		order = 5,
	},
}
local TRAILS: { [string]: TrailDef } = {}
local TRAIL_ORDER: { string } = {}
for _, def in TRAIL_LIST do
	table.freeze(def.colors)
	TRAILS[def.id] = frozen(def)
	table.insert(TRAIL_ORDER, def.id)
end
CrateConfig.Trails = table.freeze(TRAILS)
CrateConfig.TrailOrder = table.freeze(TRAIL_ORDER)

--------------------------------------------------------------------------------------------------
-- Crates
--------------------------------------------------------------------------------------------------

-- Reward builders (keep the crate tables readable).
local function boost(key: string, minutes: number, rarity: PetConfig.Rarity, bp: number): Reward
	local name = if key == "cash2x" then "2x Cash" else "2x Speed"
	local label = if minutes >= 60 then `{name} {minutes // 60}h` else `{name} {minutes}m`
	return {
		key = `{key}_{minutes}`,
		kind = "boost",
		id = key,
		amount = 1,
		seconds = minutes * 60,
		rarity = rarity,
		bp = bp,
		label = label,
	}
end
local function gems(amount: number, rarity: PetConfig.Rarity, bp: number): Reward
	return {
		key = `gems_{amount}`,
		kind = "gems",
		id = nil,
		amount = amount,
		seconds = 0,
		rarity = rarity,
		bp = bp,
		label = `+{amount} Gems`,
	}
end
local function egg(id: string, count: number, rarity: PetConfig.Rarity, bp: number): Reward
	local def = EggConfig.get(id)
	local name = if def ~= nil then def.name else id
	local label = if count > 1 then `{count}x {name}` else name
	return {
		key = `{id}_{count}`,
		kind = "egg",
		id = id,
		amount = count,
		seconds = 0,
		rarity = rarity,
		bp = bp,
		label = label,
	}
end
local function pet(id: string, bp: number): Reward
	local def = PetConfig.get(id)
	return {
		key = id,
		kind = "pet",
		id = id,
		amount = 1,
		seconds = 0,
		rarity = if def ~= nil then def.rarity else "Common",
		bp = bp,
		label = if def ~= nil then def.name else id,
	}
end
local function trail(id: string, bp: number): Reward
	local def = TRAILS[id]
	return {
		key = id,
		kind = "trail",
		id = id,
		amount = 1,
		seconds = 0,
		rarity = if def ~= nil then def.rarity else "Rare",
		bp = bp,
		label = if def ~= nil then `{def.name} Trail` else id,
	}
end

local CRATE_LIST: { CrateDef } = {
	{
		id = "supply_crate",
		name = "Supply Crate",
		order = 1,
		gems = 120,
		product = "CrateSupply",
		model = "SupplyCrate",
		color = rgb(120, 200, 90),
		accent = rgb(255, 230, 90),
		ui = "green",
		rewards = {
			boost("cash2x", 15, "Common", 30_000),
			boost("speed2x", 15, "Common", 20_000),
			gems(40, "Uncommon", 18_000),
			egg("lucky_egg", 1, "Uncommon", 14_000),
			trail("trail_green_glow", 8_000),
			gems(150, "Rare", 5_000),
			boost("cash2x", 60, "Rare", 3_500),
			pet("crate_supply_mole", 1_300),
			trail("trail_rainbow", 200),
		},
		pity = { rank = 3, opens = 6 }, -- a Rare+ at least every 6 opens
		dupGems = 30,
		blurb = "Boosts, gems, Lucky Eggs and a shot at the Supply Mole!",
	},
	{
		id = "mega_crate",
		name = "Mega Crate",
		order = 2,
		gems = 350,
		product = "CrateMega",
		model = "MegaCrate",
		color = rgb(90, 150, 255),
		accent = rgb(255, 255, 255),
		ui = "blue",
		rewards = {
			boost("cash2x", 30, "Uncommon", 24_000),
			boost("speed2x", 30, "Uncommon", 16_000),
			egg("lucky_egg", 2, "Uncommon", 18_000),
			gems(200, "Rare", 12_000),
			trail("trail_atom_orbit", 10_000),
			boost("cash2x", 120, "Epic", 8_000),
			pet("crate_supply_mole", 6_000),
			pet("crate_storm_phoenix", 4_000),
			trail("trail_rainbow", 1_500),
			pet("crate_golden_dragon", 500),
		},
		pity = { rank = 4, opens = 8 }, -- an Epic+ at least every 8 opens
		dupGems = 90,
		blurb = "Bigger boosts and rarer pets!",
	},
	{
		id = "golden_crate",
		name = "Golden Crate",
		order = 3,
		gems = 1_000,
		product = "CrateGolden",
		model = "GoldenCrate",
		color = rgb(255, 196, 46),
		accent = rgb(255, 255, 220),
		ui = "yellow",
		rewards = {
			boost("cash2x", 120, "Rare", 22_000),
			egg("lucky_egg", 5, "Rare", 18_000),
			gems(600, "Epic", 15_000),
			trail("trail_gold_sparkle", 12_000),
			pet("crate_storm_phoenix", 14_000),
			boost("cash2x", 360, "Legendary", 8_000),
			trail("trail_rainbow", 6_000),
			pet("crate_golden_dragon", 4_500),
			pet("crate_cosmic_unicorn", 500),
		},
		pity = { rank = 5, opens = 5 }, -- a Legendary+ at least every 5 opens
		dupGems = 250,
		blurb = "The best loot! Golden Dragon and the Secret Cosmic Unicorn.",
	},
}

local CRATES: { [string]: CrateDef } = {}
local CRATE_ORDER: { string } = {}
local BY_PRODUCT: { [string]: string } = {}
for _, def in CRATE_LIST do
	for _, reward in def.rewards do
		table.freeze(reward)
	end
	table.freeze(def.rewards)
	if def.pity ~= nil then
		table.freeze(def.pity)
	end
	CRATES[def.id] = frozen(def)
	table.insert(CRATE_ORDER, def.id)
	BY_PRODUCT[def.product] = def.id
end
CrateConfig.Crates = table.freeze(CRATES)
CrateConfig.Order = table.freeze(CRATE_ORDER)
CrateConfig.ByProduct = table.freeze(BY_PRODUCT)

--------------------------------------------------------------------------------------------------
-- Lookups (pure)
--------------------------------------------------------------------------------------------------

--[[ The crate with id `id` (nil for unknown / non-string ids). ]]
function CrateConfig.get(id: unknown): CrateDef?
	if type(id) ~= "string" then
		return nil
	end
	return rawget(CRATES :: any, id)
end

--[[ The trail with id `id` (nil for unknown / non-string ids). ]]
function CrateConfig.getTrail(id: unknown): TrailDef?
	if type(id) ~= "string" then
		return nil
	end
	return rawget(TRAILS :: any, id)
end

--[[ The reward of `crate` with key `key` (client reveal lookups), or nil. ]]
function CrateConfig.reward(crate: CrateDef, key: unknown): Reward?
	for _, reward in crate.rewards do
		if reward.key == key then
			return reward
		end
	end
	return nil
end

--[[
	"52.5%", "1.3%", "0.2%" — a basis-point weight as a short percentage (one decimal at 1 % and
	above, two below, trailing zeros dropped). The same text the CrateShop odds list shows.
	Example: CrateConfig.formatChance(200) --> "0.2%"
]]
function CrateConfig.formatChance(bp: number): string
	local percent = bp / CrateConfig.TotalBp * 100
	if percent >= 1 then
		return `{math.floor(percent * 10 + 0.5) / 10}%`
	end
	return `{math.floor(percent * 100 + 0.5) / 100}%`
end

export type RarityOdds = { rarity: PetConfig.Rarity, bp: number }

--[[
	The crate's odds summed per display rarity, rarest last (the published = rolled weights, just
	grouped) — the compact odds line shown next to every repeat purchase (CrateOpen OPEN AGAIN).
	Example: CrateConfig.oddsByRarity(supply) --> { {rarity="Common", bp=50000}, ... }
]]
function CrateConfig.oddsByRarity(crate: CrateDef): { RarityOdds }
	local byRarity: { [string]: number } = {}
	for _, reward in crate.rewards do
		byRarity[reward.rarity] = (byRarity[reward.rarity] or 0) + reward.bp
	end
	local out: { RarityOdds } = {}
	for _, rarity in PetConfig.Rarities do
		local bp = byRarity[rarity.id]
		if bp ~= nil then
			table.insert(out, { rarity = rarity.id, bp = bp })
		end
	end
	return out
end

--[[
	One line of the crate's odds per rarity ("Common 50% · Uncommon 32% · Rare 16.5% ...").
	Example: CrateConfig.oddsSummary(CrateConfig.get("supply_crate"))
]]
function CrateConfig.oddsSummary(crate: CrateDef): string
	local parts: { string } = {}
	for _, row in CrateConfig.oddsByRarity(crate) do
		table.insert(parts, `{row.rarity} {CrateConfig.formatChance(row.bp)}`)
	end
	return table.concat(parts, "  ·  ")
end

--[[
	Checks every crate: weights positive whole bp summing to TotalBp, reward ids valid for their
	kind, unique keys, pity rank reachable, gem prices positive, trails valid.
	@return problems (empty = valid)
]]
function CrateConfig.validate(): { string }
	local problems: { string } = {}
	for _, id in CRATE_ORDER do
		local crate = CRATES[id]
		local total = 0
		local keys: { [string]: boolean } = {}
		local pityReachable = crate.pity == nil
		for _, reward in crate.rewards do
			total += reward.bp
			if reward.bp <= 0 or reward.bp % 1 ~= 0 then
				table.insert(problems, `crate {id}: {reward.key} weight must be a positive whole bp`)
			end
			if keys[reward.key] then
				table.insert(problems, `crate {id}: duplicate reward key {reward.key}`)
			end
			keys[reward.key] = true
			if PetConfig.rarity(reward.rarity) == nil then
				table.insert(problems, `crate {id}: {reward.key} unknown rarity`)
			end
			if crate.pity ~= nil and PetConfig.rank(reward.rarity) >= crate.pity.rank then
				pityReachable = true
			end
			if reward.kind == "boost" then
				if BoostConfig.get(reward.id or "") == nil or reward.seconds <= 0 then
					table.insert(problems, `crate {id}: {reward.key} bad boost`)
				end
			elseif reward.kind == "gems" then
				if reward.amount < 1 or reward.amount % 1 ~= 0 then
					table.insert(problems, `crate {id}: {reward.key} gems must be whole`)
				end
			elseif reward.kind == "egg" then
				if EggConfig.get(reward.id) == nil or reward.amount < 1 then
					table.insert(problems, `crate {id}: {reward.key} bad egg`)
				end
			elseif reward.kind == "pet" then
				if PetConfig.get(reward.id) == nil then
					table.insert(problems, `crate {id}: {reward.key} unknown pet`)
				end
			elseif reward.kind == "trail" then
				if TRAILS[reward.id or ""] == nil then
					table.insert(problems, `crate {id}: {reward.key} unknown trail`)
				end
			else
				table.insert(problems, `crate {id}: {reward.key} unknown kind`)
			end
		end
		if total ~= CrateConfig.TotalBp then
			table.insert(problems, `crate {id}: weights sum to {total}, not {CrateConfig.TotalBp}`)
		end
		if not pityReachable then
			table.insert(problems, `crate {id}: pity rank has no reward`)
		end
		if crate.gems < 1 or crate.gems % 1 ~= 0 or crate.dupGems < 1 then
			table.insert(problems, `crate {id}: gem price / dup gems must be whole and positive`)
		end
	end
	for _, trailId in TRAIL_ORDER do
		local def = TRAILS[trailId]
		if #def.colors < 2 or #def.colors > 5 or def.width <= 0 or def.lifetime <= 0 then
			table.insert(problems, `trail {trailId}: colours 2..5, width / lifetime positive`)
		end
	end
	-- Every payment kind must be classified for the paid-random gate.
	for _, pay in { "held", "gems" } do
		if type(CrateConfig.PaidRandomPay[pay]) ~= "boolean" then
			table.insert(problems, `PaidRandomPay is missing {pay}`)
		end
	end
	return problems
end

return table.freeze(CrateConfig)
