--!strict
--[[
	PassLogic — the PURE mutations of the Nuke Pass (R78 spec §2): XP with the daily play cap,
	season rollover (end-of-season auto-grant + the new season's reset), claims (one tier, CLAIM
	ALL, bonus chests), the premium receipt decision and the admin edits. No services, no yields,
	no Instances — tests/pass-logic.luau drives every rule under Lune.

	Every mutation works on a REPAIRED state (PassConfig.State, i.e. profile.pass after
	ProfileLogic.reconcile) and returns the rewards to pay as Grant records; the caller
	(Server/Services/PassService) applies them in the SAME non-yielding step, so a claim and its
	reward are always recorded together. Each grant is marked claimed here, so applying a result
	twice is impossible and re-running a rule on the same state pays nothing new (idempotent).

	Rules:
		addXp      only into the ACTIVE season the state belongs to (call rollover first); source
		           "play" is capped at PassConfig.PlayXp.DailyCap per UTC day (dayXp / day); every
		           other source is uncapped (bounded by MaxXp). Returns the tiers newly reached.
		rollover   1) the state's season has ENDED → every reached, unclaimed free tier, premium
		              tier (if premium was bought for it) and earned bonus chest is granted
		              ("nothing is lost"); the state is kept (UI: "Season N coming soon");
		           2) a season is ACTIVE and the state is fresh / of an ended or unknown season →
		              progress resets for it (premium purchases stay, keyed per season).
		claim      one tier of one track: active season, tier reached, not claimed, premium owned
		           for the premium track. Codes: Ok | NoSeason | BadTrack | BadTier | NotReached |
		           Claimed | NotPremium.
		claimAll   every claimable free + premium tier + all earned bonus chests at once.
		premiumReceipt  which season a premium receipt unlocks (the active one; else the season
		           that ended at most PremiumGraceSeconds ago while the state still holds its
		           progress) or "fallback" (PremiumFallbackGems instead: no season / already owned).
		premiumReward  premium spins / eggs are paid random items: allowed → spins go to the paid
		           bank; restricted / unknown → GemsPerSpin gems per spin, eggs → their fallbackGems.

	Connects to: Shared/Config/PassConfig (catalogue + read-only status), Shared/Config/
	RetentionConfig (Reward), Server/Services/PassService (applies grants), tests/pass-logic.luau.

	Example:
		local result = PassLogic.rollover(profile.pass, now)     -- join: settle the season
		local added, reached = PassLogic.addXp(profile.pass, 100, "daily", now)
		local code, grant = PassLogic.claim(profile.pass, "free", 3, now)
		if code == "Ok" then applyGrants({ grant :: PassLogic.Grant }) end
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PassConfig = require(ReplicatedStorage.Shared.Config.PassConfig)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)

type State = PassConfig.State
type TierReward = PassConfig.TierReward

export type GrantTrack = "free" | "premium" | "overflow"

-- One reward to pay (already marked claimed in the state).
export type Grant = {
	track: GrantTrack,
	tier: number, -- 1..TierCount; for "overflow" the chest number within the season (1, 2, ...)
	season: string,
	reward: TierReward,
}

export type ClaimCode = "Ok" | "NoSeason" | "BadTrack" | "BadTier" | "NotReached" | "Claimed" | "NotPremium"

export type Rollover = {
	grants: { Grant }, -- end-of-season auto-grants (empty when nothing was left)
	ended: string?, -- the ended season whose leftovers were granted
	started: string?, -- the season the state was reset for
}

export type PremiumOutcome = "granted" | "grace" | "fallback"

-- The pass-only exclusive part of a reward (pet / trail / title + its fallback gems).
export type Exclusive = { pet: string?, trail: string?, title: string?, fallbackGems: number }

local PassLogic = {}

-- True for a finite number.
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A whole positive amount (nil for garbage / ≤ 0).
local function cleanAmount(value: unknown): number?
	if not finite(value) then
		return nil
	end
	local whole = math.floor(value :: number)
	return if whole >= 1 then whole else nil
end

-- The active season when the state belongs to it, else nil (claims / XP need both).
local function currentSeason(state: State, now: number): PassConfig.SeasonDef?
	local active = PassConfig.activeSeason(now)
	if active ~= nil and state.season == active.id then
		return active
	end
	return nil
end

--[[
	A deep, independent copy of a state (dry runs before a yield: "what WOULD this claim pay?").
	Example: local preview = PassLogic.clone(profile.pass)
]]
function PassLogic.clone(state: State): State
	return PassConfig.reconcileState(PassConfig.toSave(state))
end

--------------------------------------------------------------------------------------------------
-- XP
--------------------------------------------------------------------------------------------------

--[[
	Adds XP from `source` into the active season (see the header for the play cap).
	@param amount whole XP (garbage / ≤ 0 → nothing)
	@param source analytics label; "play" is the capped play-time source
	@return (XP actually added, tiers newly reached in ascending order)
	Example: PassLogic.addXp(state, 100, "daily", now) --> 100, { 1 }
]]
function PassLogic.addXp(state: State, amount: unknown, source: string, now: number): (number, { number })
	local reached: { number } = {}
	local season = currentSeason(state, now)
	local clean = cleanAmount(amount)
	if season == nil or clean == nil then
		return 0, reached
	end
	local add = clean
	if source == "play" then
		local today = PassConfig.utcDay(now)
		if state.day ~= today then
			state.day = today
			state.dayXp = 0
		end
		add = math.min(add, math.max(0, PassConfig.PlayXp.DailyCap - state.dayXp))
		if add <= 0 then
			return 0, reached
		end
		state.dayXp += add
	end
	local before = PassConfig.tierOf(state.xp)
	local nextXp = math.min(PassConfig.MaxXp, state.xp + add)
	add = nextXp - state.xp
	state.xp = nextXp
	local after = PassConfig.tierOf(state.xp)
	for tier = before + 1, after do
		table.insert(reached, tier)
	end
	return add, reached
end

--[[
	Play XP due for an online-minute count (PassService's once-per-minute tick): PlayXp.Amount
	every PlayXp.EveryMinutes minutes, else 0. The daily cap is applied by addXp.
	Example: PassLogic.playXpFor(5) --> 10 ; PassLogic.playXpFor(4) --> 0
]]
function PassLogic.playXpFor(onlineMinutes: number): number
	if not finite(onlineMinutes) or onlineMinutes < 1 or onlineMinutes % 1 ~= 0 then
		return 0
	end
	return if onlineMinutes % PassConfig.PlayXp.EveryMinutes == 0 then PassConfig.PlayXp.Amount else 0
end

--------------------------------------------------------------------------------------------------
-- Grants (shared by rollover / claimAll)
--------------------------------------------------------------------------------------------------

-- One typed grant record (keeps the track a GrantTrack literal under the new solver).
local function grantOf(track: GrantTrack, tier: number, season: string, reward: TierReward): Grant
	return { track = track, tier = tier, season = season, reward = reward }
end

-- Marks every reached, unclaimed tier of `season` claimed and returns them as grants (free
-- first, then premium when owned, then the earned bonus chests).
local function collectAll(state: State, season: PassConfig.SeasonDef, includeOverflow: boolean): { Grant }
	local grants: { Grant } = {}
	local tier = PassConfig.tierOf(state.xp)
	local premium = state.premium[season.id] == true
	for index = 1, math.min(tier, #season.tiers) do
		local def = season.tiers[index]
		if state.claimedFree[index] ~= true then
			state.claimedFree[index] = true
			table.insert(grants, grantOf("free", index, season.id, def.free))
		end
	end
	if premium then
		for index = 1, math.min(tier, #season.tiers) do
			local def = season.tiers[index]
			if state.claimedPremium[index] ~= true then
				state.claimedPremium[index] = true
				table.insert(grants, grantOf("premium", index, season.id, def.premium))
			end
		end
	end
	if includeOverflow then
		local earned = PassConfig.overflowEarned(state.xp)
		while state.overflow < earned do
			state.overflow += 1
			table.insert(grants, grantOf("overflow", state.overflow, season.id, PassConfig.OverflowReward))
		end
	end
	return grants
end

--[[
	True when rollover(state, now) would change anything (a leftover to grant, or a reset to do).
	Cheap; the once-per-minute tick uses it to notice a season end while the player is online.
]]
function PassLogic.needsRollover(state: State, now: number): boolean
	local def = PassConfig.season(state.season)
	if def ~= nil and now >= def.endsAt then
		local status = PassLogic.leftovers(state, def)
		if status > 0 then
			return true
		end
	end
	local active = PassConfig.activeSeason(now)
	return active ~= nil and state.season ~= active.id and (def == nil or now >= def.endsAt)
end

--[[ How many grants an (ended) season still owes the state (free + premium tiers + chests). ]]
function PassLogic.leftovers(state: State, season: PassConfig.SeasonDef): number
	local count = 0
	local tier = math.min(PassConfig.tierOf(state.xp), #season.tiers)
	local premium = state.premium[season.id] == true
	for index = 1, tier do
		if state.claimedFree[index] ~= true then
			count += 1
		end
		if premium and state.claimedPremium[index] ~= true then
			count += 1
		end
	end
	return count + math.max(0, PassConfig.overflowEarned(state.xp) - state.overflow)
end

--[[
	Settles the season (see the header): grants an ended season's leftovers, then resets for a new
	active season. Idempotent: a second call on the same state at the same time returns nothing.
	@return Rollover { grants, ended?, started? }
	Example (join 2026-12-02, tier 7 reached, 2 unclaimed):
		PassLogic.rollover(state, now) --> { grants = { free 6, free 7 }, ended = "harvest1" }
]]
function PassLogic.rollover(state: State, now: number): Rollover
	local result: Rollover = { grants = {} }
	if not finite(now) then
		return result
	end
	local def = PassConfig.season(state.season)
	if def ~= nil and now >= def.endsAt then
		local grants = collectAll(state, def, true)
		if #grants > 0 then
			result.grants = grants
			result.ended = def.id
		end
	end
	local active = PassConfig.activeSeason(now)
	if active ~= nil and state.season ~= active.id and (def == nil or now >= def.endsAt) then
		state.season = active.id
		state.xp = 0
		state.overflow = 0
		table.clear(state.claimedFree)
		table.clear(state.claimedPremium)
		result.started = active.id
	end
	return result
end

--------------------------------------------------------------------------------------------------
-- Claims
--------------------------------------------------------------------------------------------------

--[[
	Claims one tier of one track (see the header for the codes).
	@return (code, the grant when code == "Ok")
	Example: PassLogic.claim(state, "premium", 10, now) --> "NotPremium", nil
]]
function PassLogic.claim(state: State, track: unknown, tier: unknown, now: number): (ClaimCode, Grant?)
	local season = currentSeason(state, now)
	if season == nil then
		return "NoSeason", nil
	end
	if track ~= "free" and track ~= "premium" then
		return "BadTrack", nil
	end
	local def = PassConfig.tierDef(season, tier)
	if def == nil then
		return "BadTier", nil
	end
	local index = def.tier
	if index > PassConfig.tierOf(state.xp) then
		return "NotReached", nil
	end
	if track == "premium" then
		if state.premium[season.id] ~= true then
			return "NotPremium", nil
		end
		if state.claimedPremium[index] == true then
			return "Claimed", nil
		end
		state.claimedPremium[index] = true
		return "Ok", grantOf("premium", index, season.id, def.premium)
	end
	if state.claimedFree[index] == true then
		return "Claimed", nil
	end
	state.claimedFree[index] = true
	return "Ok", grantOf("free", index, season.id, def.free)
end

--[[
	Claims every bonus chest earned beyond the last tier (active season only).
	@return the chest grants (empty when none)
]]
function PassLogic.claimOverflow(state: State, now: number): { Grant }
	local grants: { Grant } = {}
	local season = currentSeason(state, now)
	if season == nil then
		return grants
	end
	local earned = PassConfig.overflowEarned(state.xp)
	while state.overflow < earned do
		state.overflow += 1
		table.insert(grants, grantOf("overflow", state.overflow, season.id, PassConfig.OverflowReward))
	end
	return grants
end

--[[
	CLAIM ALL: every claimable free + premium tier and every earned bonus chest (active season).
	@return (code "Ok" | "NoSeason" | "Claimed" (nothing left), grants)
]]
function PassLogic.claimAll(state: State, now: number): (ClaimCode, { Grant })
	local season = currentSeason(state, now)
	if season == nil then
		return "NoSeason", {}
	end
	local grants = collectAll(state, season, true)
	return if #grants > 0 then "Ok" else "Claimed", grants
end

--[[ True when paying `grants` needs the paid-random policy (a premium reward with spins / an egg). ]]
function PassLogic.needsPolicy(grants: { Grant }): boolean
	for _, grant in grants do
		if grant.track == "premium" and (grant.reward.spins ~= nil or grant.reward.egg ~= nil) then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------------------------
-- Reward shaping (premium policy + the exclusive split)
--------------------------------------------------------------------------------------------------

--[[
	A PREMIUM reward as it may be paid to this buyer (premium is bought with Robux, so its spins /
	eggs are paid random items). Allowed (known-unrestricted) → unchanged, spins go to the PAID
	bank. Otherwise (restricted or unknown, fail closed) → spins become `gemsPerSpin` gems each and
	an egg becomes its fallbackGems; nothing random is granted. Free / overflow rewards: unchanged,
	spins to the bonus bank.
	@return (the reward to pay, paidSpins)
	Example: PassLogic.premiumReward({ spins = 2 }, false, 40) --> { gems = 80 }, false
]]
function PassLogic.premiumReward(
	reward: TierReward,
	allowPaidRandom: boolean,
	gemsPerSpin: number
): (TierReward, boolean)
	if allowPaidRandom then
		return reward, true
	end
	local out: TierReward = table.clone(reward) :: any
	local gems = out.gems or 0
	if out.spins ~= nil then
		gems += out.spins * gemsPerSpin
		out.spins = nil
	end
	if out.egg ~= nil then
		gems += out.fallbackGems or 0
		out.egg = nil
		out.fallbackGems = nil
	end
	out.gems = if gems > 0 then gems else nil
	return out, false
end

--[[
	Splits a reward into the RewardLogic part (cash / gems / spins / boost / egg + the egg's
	fallback) and the pass-only exclusive (pet / trail / title + its fallback gems). A reward holds
	at most one item (PassConfig.validate), so its fallbackGems belongs to exactly one side.
	@return (RetentionConfig.Reward, Exclusive?)
]]
function PassLogic.splitReward(reward: TierReward): (RetentionConfig.Reward, Exclusive?)
	local base: RetentionConfig.Reward = {
		cashSeconds = reward.cashSeconds,
		cashFloor = reward.cashFloor,
		gems = reward.gems,
		spins = reward.spins,
		boost = reward.boost,
	}
	if reward.egg ~= nil then
		base.egg = reward.egg
		base.fallbackGems = reward.fallbackGems
	end
	if reward.pet == nil and reward.trail == nil and reward.title == nil then
		return base, nil
	end
	return base,
		{
			pet = reward.pet,
			trail = reward.trail,
			title = reward.title,
			fallbackGems = math.max(0, math.floor(reward.fallbackGems or 0)),
		}
end

--------------------------------------------------------------------------------------------------
-- Premium
--------------------------------------------------------------------------------------------------

--[[
	Decides what a premium receipt unlocks (and records it):
		a season is active and not owned yet          → premium[active] = true      "granted"
		none active; the last one ended ≤ grace ago,  → premium[ended] = true       "grace"
		  the state still holds its progress, not owned
		anything else (already owned, no season, too late) → nothing recorded     "fallback"
	@return (outcome, season id when unlocked)
]]
function PassLogic.premiumReceipt(state: State, now: number): (PremiumOutcome, string?)
	if not finite(now) then
		return "fallback", nil
	end
	local active = PassConfig.activeSeason(now)
	if active ~= nil then
		if state.premium[active.id] == true then
			return "fallback", nil
		end
		state.premium[active.id] = true
		return "granted", active.id
	end
	local ended = PassConfig.lastEndedSeason(now)
	if
		ended ~= nil
		and now < ended.endsAt + PassConfig.PremiumGraceSeconds
		and state.season == ended.id
		and state.premium[ended.id] ~= true
	then
		state.premium[ended.id] = true
		return "grace", ended.id
	end
	return "fallback", nil
end

--------------------------------------------------------------------------------------------------
-- Admin edits (PassService admin commands; validated + audited there)
--------------------------------------------------------------------------------------------------

--[[
	Sets the XP to exactly the start of `tier` (0..TierCount) in the active season. Claimed flags
	are kept (a lowered tier never re-pays anything).
	@return true when applied (false: no active season for this state / bad tier)
]]
function PassLogic.setTier(state: State, tier: unknown, now: number): boolean
	if currentSeason(state, now) == nil or not finite(tier) or (tier :: number) % 1 ~= 0 then
		return false
	end
	local clean = math.clamp(tier :: number, 0, PassConfig.TierCount)
	state.xp = clean * PassConfig.XpPerTier
	state.overflow = math.min(state.overflow, PassConfig.overflowEarned(state.xp))
	return true
end

--[[
	Turns premium on / off for the active season of this state.
	@return (changed, season id)
]]
function PassLogic.setPremium(state: State, on: boolean, now: number): (boolean, string?)
	local season = currentSeason(state, now)
	if season == nil then
		return false, nil
	end
	local owned = state.premium[season.id] == true
	if owned == on then
		return false, season.id
	end
	state.premium[season.id] = if on then true else nil
	return true, season.id
end

return table.freeze(PassLogic)
