--!strict
--[[
	PassConfig — the Nuke Pass (R78 retention pack, spec docs/superpowers/specs/2026-10-31-r78-
	retention-pack-design.md §2): seasons, the 30-tier reward track (FREE + PREMIUM), the XP rules
	and the pure READ-ONLY rules every side shares (server claims, the NukePass screen, the Quests
	banner / badge, the HUD "Pass" offer).

	Season 1 "Harvest Season": 2026-11-01 00:00 → 2026-12-01 00:00 UTC (the same instants as the
	Harvest Feast, EventConfig.Season / MonetizationConfig HARVEST_*). 30 tiers × 400 XP = 12,000 XP.
	XP sources: quest claims (QuestService → ProgressEvents.xp) and play time (PassService's own
	once-per-minute tick: PlayXp.Amount XP per PlayXp.EveryMinutes online minutes, at most
	PlayXp.DailyCap play XP per UTC day). After tier 30, every OverflowXp further XP is one bonus
	chest (OverflowReward), repeatable.

	Tracks:
		free     every player, every tier
		premium  developer product PremiumProduct ("Nuke Pass Premium", 159 R$) for ONE season;
		         buying late unlocks every premium tier already reached. Exclusives: tier 10 trail
		         Harvest Glow, tier 20 title NUKE PASS, tier 30 pet Golden Nukey.

	Rewards (`TierReward`) are a RetentionConfig.Reward (cash / gems / spins / boost / pet / egg +
	fallbackGems, applied by Server/Retention/RewardLogic) plus two pass-only exclusives:
		trail   a CrateConfig.Trails id (in NO crate pool), granted once; fallbackGems if owned
		title   a PlayerTitlesConfig key, granted through PlayerTitleService; fallbackGems if refused
	A reward holds at most ONE item (pet / egg / trail / title), so its single `fallbackGems`
	always belongs to exactly one thing (validate() enforces it). PREMIUM rewards are bought with
	Robux: their spins (paid bank) and eggs are paid random items, so for a buyer whose region
	restricts paid random items (PolicyService, fail closed) spins pay LuckySpinConfig.GemsPerSpin
	gems each and eggs pay their fallbackGems instead (Server/Pass/PassLogic.premiumReward).

	State (profile.pass; ProfileLogic owns defaults / repair through newState / reconcileState):
		season          the season id this progress belongs to ("" = never played a season)
		xp              XP earned in `season` (whole, [0, MaxXp])
		dayXp, day      PLAY XP earned on UTC day `day` (the daily play cap)
		claimedFree     {[tier] = true} claimed free rewards of `season`
		claimedPremium  {[tier] = true} claimed premium rewards of `season`
		premium         {[seasonId] = true} seasons the player bought premium for (kept forever)
		overflow        bonus chests already claimed in `season`
	Numeric sets are sparse tables, which DataStores and remotes mangle: toSave / toWire write them
	as sorted arrays and reconcileState / readState accept either form.

	Season rules (pure; Server/Pass/PassLogic applies them):
		- activeSeason(now): the season whose [startsAt, endsAt) holds `now` (exact instants).
		- When a season ENDS, its reached-but-unclaimed rewards are granted automatically (next join,
		  or live at the end instant); the state is kept (the UI shows "Season N coming soon").
		- When a NEW season is active and the state belongs to an older / unknown season, progress
		  resets for the new season (premium purchases are kept per season id).

	Exports used by other builders (Q-quests: the Quests banner + HUD badge):
		PassConfig.activeSeason(nowUtc) -> SeasonDef?        { id, name, number, startsAt, endsAt, ... }
		PassConfig.progress(xp) -> (tier, xpIntoTier, xpPerTier)   (tier 30: progress to the next chest)
		PassConfig.claimableCount(passState, nowUtc) -> number     pure, nil-safe for garbage state

	Studio test clock: Studio-only ReplicatedStorage attribute ClockOffsetAttribute (seconds) shifts
	the pass clock on the server AND the client (admin PassClock), so a season can be tested before
	it starts / after it ends. PassConfig.clockNow(baseNow) applies it; live servers ignore it.

	Connects to: Shared/Config/{RetentionConfig (Reward), CrateConfig (Harvest Glow trail),
	PlayerTitlesConfig (season1 / nukePass), MonetizationConfig (NukePassPremium)},
	Server/Pass/PassLogic, Server/Services/PassService, Server/Economy/ProfileLogic (profile.pass),
	Client/UI/Screens/NukePass, Client/UI/Hud/HudOffers (the "Pass" offer), Q-quests' Quests screen,
	tests/pass-logic.luau.

	Example:
		local season = PassConfig.activeSeason(os.time())
		if season then
			local tier, into, per = PassConfig.progress(profile.pass.xp)
			print(season.name, tier, into, per) --> "Harvest Season" 3 120 400
		end
		print(PassConfig.claimableCount(profile.pass, os.time())) --> 2
]]

local RetentionConfig = require(script.Parent.RetentionConfig)

export type Track = "free" | "premium"

-- One tier reward: a RetentionConfig.Reward + the pass-only exclusives (see the header).
export type TierReward = {
	cashSeconds: number?,
	cashFloor: number?,
	gems: number?,
	spins: number?,
	boost: RetentionConfig.BoostGrant?,
	pet: string?,
	egg: string?,
	trail: string?,
	title: string?,
	fallbackGems: number?,
}

export type TierDef = {
	tier: number, -- 1..TierCount
	free: TierReward,
	premium: TierReward,
	milestone: boolean, -- a bigger card (tiers 5, 10, 15, ...)
}

export type SeasonDef = {
	id: string, -- stable save-data id (profile.pass.season / premium keys): never rename
	number: number, -- 1, 2, ... ("Season 1")
	name: string, -- "Harvest Season"
	startsAt: number, -- unix seconds (inclusive)
	endsAt: number, -- unix seconds (exclusive)
	color: string, -- UIStyleConfig colour preset of the window header / banner
	tiers: { TierDef },
}

export type State = {
	season: string,
	xp: number,
	dayXp: number,
	day: number,
	claimedFree: { [number]: true },
	claimedPremium: { [number]: true },
	premium: { [string]: true },
	overflow: number,
}

local PassConfig = {}

-- Track ids (wire + analytics); the remotes validate against this list.
PassConfig.Tracks = table.freeze({ "free", "premium" } :: { Track })
PassConfig.TierCount = 30
PassConfig.XpPerTier = 400
-- XP per bonus chest after the last tier, and what one chest pays.
PassConfig.OverflowXp = 800
PassConfig.OverflowReward = table.freeze({ gems = 20 }) :: TierReward
-- Highest XP a state keeps (12,000 for the track + ~1,000 chests; a bound, never reached).
PassConfig.MaxXp = 1_000_000
-- Play XP (PassService's once-per-minute tick): Amount XP per EveryMinutes online minutes,
-- at most DailyCap play XP per UTC day. Quest XP is not capped here (QuestConfig sizes it).
PassConfig.PlayXp = table.freeze({ Amount = 10, EveryMinutes = 5, DailyCap = 360 })
-- Most premium seasons a profile keeps (bounded set; 2 years of monthly seasons).
PassConfig.MaxPremiumSeasons = 24
-- Premium developer product (MonetizationConfig key; kind "PassPremium").
PassConfig.PremiumProduct = "NukePassPremium"
-- A premium receipt that arrives AFTER a season ended (Roblox retries receipts; receipts carry no
-- purchase time) still unlocks that season when it ended at most this long ago: the player was
-- almost certainly prompted during the season. Later receipts pay PremiumFallbackGems instead
-- (also paid when the player already owns premium for the active season), so Robux are never
-- taken for nothing. 500 gems ≥ what 159 R$ buys in gem packs (Bag of Gems: 350 for 119 R$).
PassConfig.PremiumGraceSeconds = 6 * 3600
PassConfig.PremiumFallbackGems = 500
-- Exclusive ids (validated against their catalogues by tests/pass-logic.luau).
PassConfig.Exclusives = table.freeze({
	Trail = "harvest_glow", -- CrateConfig.Trails (no crate pool)
	FreeTitle = "season1", -- PlayerTitlesConfig, free tier 30
	PremiumTitle = "nukePass", -- PlayerTitlesConfig, premium tier 20
	Pet = "golden_nukey", -- PetConfig (A-pets), premium tier 30
})
-- Studio-only test clock (seconds added to the pass clock; see the header).
PassConfig.ClockOffsetAttribute = "NukePassClockOffset"
-- Season ids: lowercase, digits, ≤ 16 chars (save data + analytics safe).
PassConfig.SeasonIdPattern = "^[a-z][a-z0-9]*$"
PassConfig.MaxSeasonIdLength = 16

--------------------------------------------------------------------------------------------------
-- Season 1 "Harvest Season" track
--------------------------------------------------------------------------------------------------

local function cash2x(seconds: number): RetentionConfig.BoostGrant
	return { key = "cash2x", seconds = seconds }
end
local function speed2x(seconds: number): RetentionConfig.BoostGrant
	return { key = "speed2x", seconds = seconds }
end

-- Lucky Egg fallback (the Lucky Wheel pays 15 gems for one when eggs are unavailable).
local EGG = "lucky_egg"
local EGG_GEMS = 15
local FIFTEEN_MIN = 900
local THIRTY_MIN = 1_800

--[[
	Free: gems 10–40, bonus spins, 15-min boosts, income cash, Lucky Eggs; tier 30 = title SEASON 1.
	Premium: ≈ double the free value + 9 Lucky Eggs; tier 10 Harvest Glow trail, tier 20 NUKE PASS
	title, tier 30 Golden Nukey (A-pets' PetConfig row; fallbackGems while it is missing).
	Totals (PassConfig.totals): free 325 gems · 9 spins · 4 eggs · 6 × 15-min boosts;
	premium 730 gems · 18 spins · 9 eggs · 4 × 30-min boosts + 3 exclusives — vs 159 R$ ≈ 500 gems in packs.
]]
local HARVEST_ROWS: { { free: TierReward, premium: TierReward } } = {
	{ free = { gems = 10 }, premium = { gems = 25, egg = EGG, fallbackGems = EGG_GEMS } }, -- 1
	{ free = { cashSeconds = 600, cashFloor = 500 }, premium = { cashSeconds = 1_200, cashFloor = 1_000 } }, -- 2
	{ free = { spins = 1 }, premium = { spins = 2 } }, -- 3
	{ free = { gems = 15 }, premium = { gems = 30 } }, -- 4
	{ free = { boost = cash2x(FIFTEEN_MIN) }, premium = { boost = cash2x(THIRTY_MIN) } }, -- 5
	{ free = { egg = EGG, fallbackGems = EGG_GEMS }, premium = { gems = 20, egg = EGG, fallbackGems = EGG_GEMS } }, -- 6
	{ free = { gems = 20 }, premium = { gems = 40 } }, -- 7
	{ free = { cashSeconds = 900, cashFloor = 2_000 }, premium = { cashSeconds = 1_800, cashFloor = 4_000 } }, -- 8
	{ free = { spins = 1 }, premium = { spins = 2 } }, -- 9
	{
		free = { gems = 25, boost = speed2x(FIFTEEN_MIN) },
		premium = { gems = 50, trail = "harvest_glow", fallbackGems = 150 },
	}, -- 10 (premium exclusive trail)
	{ free = { cashSeconds = 1_200, cashFloor = 4_000 }, premium = { cashSeconds = 2_400, cashFloor = 8_000 } }, -- 11
	{ free = { gems = 20 }, premium = { gems = 40, egg = EGG, fallbackGems = EGG_GEMS } }, -- 12
	{ free = { boost = cash2x(FIFTEEN_MIN) }, premium = { boost = cash2x(THIRTY_MIN) } }, -- 13
	{ free = { egg = EGG, fallbackGems = EGG_GEMS }, premium = { spins = 3 } }, -- 14
	{ free = { gems = 30, spins = 1 }, premium = { gems = 60, egg = EGG, fallbackGems = EGG_GEMS } }, -- 15
	{ free = { cashSeconds = 1_500, cashFloor = 8_000 }, premium = { cashSeconds = 3_000, cashFloor = 16_000 } }, -- 16
	{ free = { gems = 25 }, premium = { gems = 50 } }, -- 17
	{ free = { boost = speed2x(FIFTEEN_MIN) }, premium = { boost = speed2x(THIRTY_MIN) } }, -- 18
	{ free = { spins = 2 }, premium = { spins = 3, egg = EGG, fallbackGems = EGG_GEMS } }, -- 19
	{
		free = { gems = 35, egg = EGG, fallbackGems = EGG_GEMS },
		premium = { gems = 75, title = "nukePass", fallbackGems = 100 },
	}, -- 20 (premium exclusive title)
	{ free = { cashSeconds = 1_800, cashFloor = 15_000 }, premium = { cashSeconds = 3_600, cashFloor = 30_000 } }, -- 21
	{ free = { gems = 30 }, premium = { gems = 60, egg = EGG, fallbackGems = EGG_GEMS } }, -- 22
	{ free = { boost = cash2x(FIFTEEN_MIN) }, premium = { boost = cash2x(THIRTY_MIN) } }, -- 23
	{ free = { spins = 2 }, premium = { spins = 4 } }, -- 24
	{ free = { gems = 40, boost = speed2x(FIFTEEN_MIN) }, premium = { gems = 80, egg = EGG, fallbackGems = EGG_GEMS } }, -- 25
	{ free = { egg = EGG, fallbackGems = EGG_GEMS }, premium = { gems = 30, egg = EGG, fallbackGems = EGG_GEMS } }, -- 26
	{ free = { gems = 35 }, premium = { gems = 70 } }, -- 27
	{ free = { cashSeconds = 2_700, cashFloor = 30_000 }, premium = { cashSeconds = 5_400, cashFloor = 60_000 } }, -- 28
	{ free = { spins = 2 }, premium = { spins = 4, egg = EGG, fallbackGems = EGG_GEMS } }, -- 29
	{
		free = { gems = 40, title = "season1", fallbackGems = 40 },
		premium = { gems = 100, pet = "golden_nukey", fallbackGems = 400 },
	}, -- 30 (free title SEASON 1; premium exclusive pet)
}

-- Freezes a reward (and its boost) so no caller can ever edit the catalogue.
local function freezeReward(reward: TierReward): TierReward
	if reward.boost ~= nil then
		table.freeze(reward.boost)
	end
	return table.freeze(reward) :: any
end

local function buildTiers(rows: { { free: TierReward, premium: TierReward } }): { TierDef }
	local tiers: { TierDef } = {}
	for index, row in rows do
		local def: TierDef = {
			tier = index,
			free = freezeReward(row.free),
			premium = freezeReward(row.premium),
			milestone = index % 5 == 0,
		}
		table.insert(tiers, table.freeze(def) :: any)
	end
	return table.freeze(tiers) :: any
end

-- Seasons in chronological order (add Season 2 as a new row with later instants).
local SEASON_LIST: { SeasonDef } = {
	{
		id = "harvest1",
		number = 1,
		name = "Harvest Season",
		startsAt = 1_793_491_200, -- 2026-11-01T00:00:00Z
		endsAt = 1_796_083_200, -- 2026-12-01T00:00:00Z
		color = "orange",
		tiers = buildTiers(HARVEST_ROWS),
	},
}
local SEASONS: { [string]: SeasonDef } = {}
local SEASON_ORDER: { string } = {}
for _, def in SEASON_LIST do
	SEASONS[def.id] = table.freeze(def) :: any
	table.insert(SEASON_ORDER, def.id)
end
PassConfig.Seasons = table.freeze(SEASONS)
PassConfig.SeasonOrder = table.freeze(SEASON_ORDER)

--------------------------------------------------------------------------------------------------
-- Small pure helpers
--------------------------------------------------------------------------------------------------

-- True for a finite number.
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A whole number in [lo, hi], else `default`.
local function whole(value: unknown, lo: number, hi: number, default: number): number
	if not finite(value) then
		return default
	end
	return math.clamp(math.floor(value :: number), lo, hi)
end

--[[ True when `value` is a well-formed season id (pattern + length). ]]
function PassConfig.isSeasonId(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= PassConfig.MaxSeasonIdLength
		and string.match(value, PassConfig.SeasonIdPattern) ~= nil
end

--[[ The season with id `id` (nil for unknown / non-string ids; rawget so nothing can fake one). ]]
function PassConfig.season(id: unknown): SeasonDef?
	if type(id) ~= "string" then
		return nil
	end
	return rawget(SEASONS :: any, id)
end

--[[
	The season running at `now` (unix seconds): startsAt <= now < endsAt (exact instants), else nil.
	Example: PassConfig.activeSeason(1_793_491_200).id --> "harvest1"; (1_796_083_200) --> nil
]]
function PassConfig.activeSeason(now: number): SeasonDef?
	if not finite(now) then
		return nil
	end
	for _, id in SEASON_ORDER do
		local def = SEASONS[id]
		if now >= def.startsAt and now < def.endsAt then
			return def
		end
	end
	return nil
end

--[[ The first season that has not started yet at `now` (the "Season N starts in ..." countdown). ]]
function PassConfig.nextSeason(now: number): SeasonDef?
	if not finite(now) then
		return nil
	end
	for _, id in SEASON_ORDER do
		local def = SEASONS[id]
		if def.startsAt > now then
			return def
		end
	end
	return nil
end

--[[ The most recent season that has ENDED at `now` (nil before the first one ends). ]]
function PassConfig.lastEndedSeason(now: number): SeasonDef?
	if not finite(now) then
		return nil
	end
	local best: SeasonDef? = nil
	for _, id in SEASON_ORDER do
		local def = SEASONS[id]
		if now >= def.endsAt and (best == nil or def.endsAt > best.endsAt) then
			best = def
		end
	end
	return best
end

--[[ True when the season `id` is known and over at `now`. ]]
function PassConfig.hasEnded(id: unknown, now: number): boolean
	local def = PassConfig.season(id)
	return def ~= nil and finite(now) and now >= def.endsAt
end

--[[ The UTC day number of `now` (0 = 1970-01-01). ]]
function PassConfig.utcDay(now: number): number
	if not finite(now) then
		return 0
	end
	return now // 86_400
end

--[[
	The pass clock: `baseNow` plus the Studio-only test offset (ReplicatedStorage attribute
	ClockOffsetAttribute, clamped to ±400 days). Outside Studio the offset is ignored, so a live
	server can never be time-shifted. Server: PassConfig.clockNow(os.time()); client:
	PassConfig.clockNow(Workspace:GetServerTimeNow()).
]]
function PassConfig.clockNow(baseNow: number): number
	local ok, offset = pcall(function(): number
		local RunService = game:GetService("RunService")
		if not RunService:IsStudio() then
			return 0
		end
		local raw = game:GetService("ReplicatedStorage"):GetAttribute(PassConfig.ClockOffsetAttribute)
		return if finite(raw) then math.clamp(raw :: number, -400 * 86_400, 400 * 86_400) else 0
	end)
	return baseNow + (if ok and finite(offset) then offset else 0)
end

--------------------------------------------------------------------------------------------------
-- XP → tiers
--------------------------------------------------------------------------------------------------

--[[ The tier reached with `xp` (0..TierCount; garbage → 0). ]]
function PassConfig.tierOf(xp: unknown): number
	local clean = whole(xp, 0, PassConfig.MaxXp, 0)
	return math.min(PassConfig.TierCount, clean // PassConfig.XpPerTier)
end

--[[
	Progress for a bar: (tier reached, XP into the next step, XP per step). Below the last tier the
	step is the next tier (XpPerTier); at the last tier it is the next bonus chest (OverflowXp).
	Example: PassConfig.progress(1_320) --> 3, 120, 400 ; PassConfig.progress(12_500) --> 30, 500, 800
]]
function PassConfig.progress(xp: unknown): (number, number, number)
	local clean = whole(xp, 0, PassConfig.MaxXp, 0)
	local tier = PassConfig.tierOf(clean)
	if tier < PassConfig.TierCount then
		return tier, clean - tier * PassConfig.XpPerTier, PassConfig.XpPerTier
	end
	local beyond = clean - PassConfig.TierCount * PassConfig.XpPerTier
	return tier, beyond % PassConfig.OverflowXp, PassConfig.OverflowXp
end

--[[ Bonus chests EARNED with `xp` (claimed or not): one per OverflowXp beyond the last tier. ]]
function PassConfig.overflowEarned(xp: unknown): number
	local clean = whole(xp, 0, PassConfig.MaxXp, 0)
	local beyond = clean - PassConfig.TierCount * PassConfig.XpPerTier
	return if beyond > 0 then beyond // PassConfig.OverflowXp else 0
end

--[[ The tier definition of a season (nil for unknown seasons / tiers). ]]
function PassConfig.tierDef(season: SeasonDef?, tier: unknown): TierDef?
	if season == nil or not finite(tier) or (tier :: number) % 1 ~= 0 then
		return nil
	end
	return season.tiers[tier :: number]
end

--[[ One track's reward of a tier (nil for unknown seasons / tiers / tracks). ]]
function PassConfig.reward(season: SeasonDef?, track: unknown, tier: unknown): TierReward?
	local def = PassConfig.tierDef(season, tier)
	if def == nil then
		return nil
	end
	if track == "free" then
		return def.free
	elseif track == "premium" then
		return def.premium
	end
	return nil
end

--------------------------------------------------------------------------------------------------
-- State: defaults, repair, save / wire forms
--------------------------------------------------------------------------------------------------

--[[ A fresh profile.pass (never played a season). ]]
function PassConfig.newState(): State
	return {
		season = "",
		xp = 0,
		dayXp = 0,
		day = 0,
		claimedFree = {},
		claimedPremium = {},
		premium = {},
		overflow = 0,
	}
end

--[[
	A tier set from untrusted data: the map form {[tier] = true} or the array form { t1, t2 }
	(toSave / toWire); whole tiers in [1, TierCount] only.
]]
local function readTierSet(raw: unknown): { [number]: true }
	local out: { [number]: true } = {}
	if type(raw) ~= "table" or getmetatable(raw :: any) ~= nil then
		return out
	end
	local count = 0
	for key, value in raw :: { [any]: any } do
		count += 1
		if count > 4 * PassConfig.TierCount then
			break -- a hostile / corrupt table never costs more than a bounded walk
		end
		local tier = if value == true then key elseif type(key) == "number" then value else nil
		if finite(tier) and (tier :: number) % 1 == 0 and tier >= 1 and tier <= PassConfig.TierCount then
			out[tier :: number] = true
		end
	end
	return out
end

-- The premium season set from untrusted data: map {[id] = true} or array { id, ... }; bounded.
local function readPremium(raw: unknown): { [string]: true }
	local out: { [string]: true } = {}
	if type(raw) ~= "table" or getmetatable(raw :: any) ~= nil then
		return out
	end
	local ids: { string } = {}
	local walked = 0
	for key, value in raw :: { [any]: any } do
		walked += 1
		if walked > 4 * PassConfig.MaxPremiumSeasons then
			break
		end
		local id = if value == true then key elseif type(key) == "number" then value else nil
		if PassConfig.isSeasonId(id) then
			table.insert(ids, id :: string)
		end
	end
	-- Known seasons first (newest first), then other well-formed ids, so a cap never drops one
	-- this server can still use.
	table.sort(ids, function(a: string, b: string): boolean
		local da, db = SEASONS[a], SEASONS[b]
		if (da ~= nil) ~= (db ~= nil) then
			return da ~= nil
		end
		if da ~= nil and db ~= nil and da.startsAt ~= db.startsAt then
			return da.startsAt > db.startsAt
		end
		return a < b
	end)
	local kept = 0
	for _, id in ids do
		if out[id] == nil and kept < PassConfig.MaxPremiumSeasons then
			out[id] = true
			kept += 1
		end
	end
	return out
end

--[[
	profile.pass from untrusted save data (ProfileLogic.reconcile): every field present, numbers
	whole + clamped, sets bounded, junk dropped. A missing / garbage value → newState().
	Example: PassConfig.reconcileState({ xp = 0 / 0, claimedFree = { 1, 99 } }) --> xp 0, claimedFree {[1]=true}
]]
function PassConfig.reconcileState(raw: unknown): State
	local state = PassConfig.newState()
	if type(raw) ~= "table" or getmetatable(raw :: any) ~= nil then
		return state
	end
	local source = raw :: { [string]: any }
	state.season = if PassConfig.isSeasonId(source.season) then source.season else ""
	state.xp = whole(source.xp, 0, PassConfig.MaxXp, 0)
	state.dayXp = whole(source.dayXp, 0, PassConfig.PlayXp.DailyCap, 0)
	state.day = whole(source.day, 0, 10_000_000, 0)
	state.claimedFree = readTierSet(source.claimedFree)
	state.claimedPremium = readTierSet(source.claimedPremium)
	state.premium = readPremium(source.premium)
	state.overflow = whole(source.overflow, 0, PassConfig.overflowEarned(PassConfig.MaxXp), 0)
	if state.season == "" then
		-- No season yet: nothing can have been earned or claimed.
		state.xp, state.overflow = 0, 0
		table.clear(state.claimedFree)
		table.clear(state.claimedPremium)
	end
	return state
end

-- A tier set as a sorted array ({ [3] = true, [1] = true } → { 1, 3 }).
local function tierList(set: { [number]: true }): { number }
	local list: { number } = {}
	for tier in set do
		table.insert(list, tier)
	end
	table.sort(list)
	return list
end

--[[
	The DataStore / remote form of a state: a fresh table with the tier sets as sorted arrays
	(premium stays a string-key set, which both encode safely). Never returns live tables.
]]
function PassConfig.toSave(state: State): { [string]: any }
	return {
		season = state.season,
		xp = state.xp,
		dayXp = state.dayXp,
		day = state.day,
		claimedFree = tierList(state.claimedFree),
		claimedPremium = tierList(state.claimedPremium),
		premium = table.clone(state.premium),
		overflow = state.overflow,
	}
end

-- The snapshot field (ProfileLogic BUILDERS.pass) is exactly the save form.
PassConfig.toWire = PassConfig.toSave

--[[
	A State from ANY untrusted shape (the client's profile snapshot, a server profile, nil): the
	same repair as reconcileState. Clients call it before reading anything.
]]
function PassConfig.readState(raw: unknown): State
	return PassConfig.reconcileState(raw)
end

--[[ True when the state owns premium for season `seasonId`. ]]
function PassConfig.isPremium(state: State, seasonId: string): boolean
	return state.premium[seasonId] == true
end

--------------------------------------------------------------------------------------------------
-- Read-only status (server claims and every screen use the same rules)
--------------------------------------------------------------------------------------------------

export type Status = {
	season: SeasonDef?, -- the active season the state belongs to (nil: none / not yet rolled over)
	tier: number,
	xpInto: number,
	xpPer: number,
	premium: boolean, -- premium owned for that season
	freeClaimable: { number }, -- reached, unclaimed free tiers (ascending)
	premiumClaimable: { number }, -- reached, unclaimed premium tiers (only when premium)
	premiumLocked: { number }, -- reached premium tiers waiting for a purchase (not premium)
	overflowClaimable: number, -- earned, unclaimed bonus chests
}

--[[
	Everything claimable for `state` at `now`. Only a state that belongs to the ACTIVE season can
	claim (an older season's leftovers are auto-granted by the server's rollover, never claimed).
	Accepts a repaired State; use statusOf for raw / untrusted input.
]]
function PassConfig.status(state: State, now: number): Status
	local active = PassConfig.activeSeason(now)
	local season = if active ~= nil and state.season == active.id then active else nil
	local xp = if season ~= nil then state.xp else 0
	local tier, into, per = PassConfig.progress(xp)
	local premium = season ~= nil and state.premium[season.id] == true
	local status: Status = {
		season = season,
		tier = tier,
		xpInto = into,
		xpPer = per,
		premium = premium,
		freeClaimable = {},
		premiumClaimable = {},
		premiumLocked = {},
		overflowClaimable = 0,
	}
	if season == nil then
		return status
	end
	for index = 1, math.min(tier, #season.tiers) do
		if state.claimedFree[index] ~= true then
			table.insert(status.freeClaimable, index)
		end
		if state.claimedPremium[index] ~= true then
			table.insert(if premium then status.premiumClaimable else status.premiumLocked, index)
		end
	end
	status.overflowClaimable = math.max(0, PassConfig.overflowEarned(xp) - state.overflow)
	return status
end

--[[ status() on untrusted input (repairs it first). ]]
function PassConfig.statusOf(raw: unknown, now: number): Status
	return PassConfig.status(PassConfig.readState(raw), now)
end

--[[
	How many CLAIM presses are waiting (free + premium tiers + bonus chests) — the Quests HUD badge
	and the NukePass banner. Pure and nil-safe: a missing / garbage state, a NaN clock or a state of
	an older season → 0.
	Example: PassConfig.claimableCount(ClientState.profile.pass, Workspace:GetServerTimeNow()) --> 2
]]
function PassConfig.claimableCount(passState: unknown, nowUtc: number): number
	if type(passState) ~= "table" or not finite(nowUtc) then
		return 0
	end
	local ok, status = pcall(PassConfig.statusOf, passState, nowUtc)
	if not ok then
		return 0
	end
	return #status.freeClaimable + #status.premiumClaimable + (if status.overflowClaimable > 0 then 1 else 0)
end

--[[
	True while the HUD "Pass" offer should show: a season is running and the player has not bought
	its premium (nil-safe on raw snapshots).
]]
function PassConfig.offerVisible(passState: unknown, now: number): boolean
	local active = PassConfig.activeSeason(now)
	if active == nil then
		return false
	end
	local state = PassConfig.readState(passState)
	return state.premium[active.id] ~= true
end

--------------------------------------------------------------------------------------------------
-- Value summary (the premium CTA line, the docs, tests)
--------------------------------------------------------------------------------------------------

export type Totals = { gems: number, spins: number, eggs: number, boosts: number, cash: number, exclusives: number }

--[[ What one track of a season pays in total (gems include no fallbacks). ]]
function PassConfig.totals(season: SeasonDef, track: Track): Totals
	local totals: Totals = { gems = 0, spins = 0, eggs = 0, boosts = 0, cash = 0, exclusives = 0 }
	for _, def in season.tiers do
		local reward = if track == "premium" then def.premium else def.free
		totals.gems += reward.gems or 0
		totals.spins += reward.spins or 0
		totals.eggs += if reward.egg ~= nil then 1 else 0
		totals.boosts += if reward.boost ~= nil then 1 else 0
		totals.cash += if reward.cashSeconds ~= nil then 1 else 0
		if track == "premium" and (reward.trail ~= nil or reward.pet ~= nil or reward.title ~= nil) then
			totals.exclusives += 1
		end
	end
	return totals
end

--------------------------------------------------------------------------------------------------
-- Validation (tests/pass-logic.luau)
--------------------------------------------------------------------------------------------------

-- How many item kinds a reward holds (pet / egg / trail / title).
local function itemCount(reward: TierReward): number
	local count = 0
	for _, field in { "pet", "egg", "trail", "title" } do
		if (reward :: any)[field] ~= nil then
			count += 1
		end
	end
	return count
end

--[[
	Structural problems in the catalogue (empty = valid): season windows ordered and disjoint, ids
	well-formed, TierCount tiers each, every reward grants something, at most one item per reward
	with a fallback, exclusives where the spec puts them.
]]
function PassConfig.validate(): { string }
	local problems: { string } = {}
	local previousEnd = -math.huge
	for _, id in SEASON_ORDER do
		local def = SEASONS[id]
		if not PassConfig.isSeasonId(id) then
			table.insert(problems, `season {id}: malformed id`)
		end
		if not (finite(def.startsAt) and finite(def.endsAt) and def.startsAt < def.endsAt) then
			table.insert(problems, `season {id}: startsAt must be before endsAt`)
		end
		if def.startsAt < previousEnd then
			table.insert(problems, `season {id}: overlaps the previous season`)
		end
		previousEnd = def.endsAt
		if #def.tiers ~= PassConfig.TierCount then
			table.insert(problems, `season {id}: {#def.tiers} tiers (want {PassConfig.TierCount})`)
		end
		for index, tier in def.tiers do
			if tier.tier ~= index then
				table.insert(problems, `season {id}: tier {index} numbered {tier.tier}`)
			end
			for _, track in PassConfig.Tracks do
				local reward = if track == "free" then tier.free else tier.premium
				local items = itemCount(reward)
				local base: RetentionConfig.Reward = {
					cashSeconds = reward.cashSeconds,
					cashFloor = reward.cashFloor,
					gems = reward.gems,
					spins = reward.spins,
					boost = reward.boost,
					pet = reward.pet,
					egg = reward.egg,
					fallbackGems = reward.fallbackGems,
				}
				local exclusive = reward.trail ~= nil or reward.title ~= nil
				if not exclusive and not RetentionConfig.isRewardValid(base) then
					table.insert(problems, `season {id}: tier {index} {track} reward grants nothing / invalid`)
				end
				if items > 1 then
					table.insert(problems, `season {id}: tier {index} {track} holds {items} items (max 1)`)
				end
				if items == 1 and not finite(reward.fallbackGems) then
					table.insert(problems, `season {id}: tier {index} {track} item needs fallbackGems`)
				end
			end
		end
	end
	return problems
end

return table.freeze(PassConfig)
