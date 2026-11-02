--!strict
--[[
	PassView — DISPLAY helpers of the Nuke Pass screen (Screens/NukePass): what a tier card shows,
	which state its button is in, which season phase the window is in and the premium value line.
	Display only — every rule comes from Shared/Config/PassConfig (the same read-only status the
	server's claims use), every amount the server grants is decided on the server.

	Lives inside Screens/NukePass (a ModuleScript folder), so UIController never registers it as a
	screen.

	Cards (`lines` / `headline` / `iconOf`):
		cash / gems / spins / boost / egg  RewardPreview's lines (cash scaled by the player's income,
		                                   the same rule as the server's RewardLogic.cashFor)
		trail / title / pet                the pass exclusives ("Harvest Glow Trail", "NUKE PASS
		                                   Title", "Golden Nukey")
		premium, paid random restricted    spins shown as LuckySpinConfig.GemsPerSpin gems each,
		                                   eggs as their fallback gems (what the server will pay)
	Button states (`cellState`): "claimed" | "claimable" | "locked" (tier not reached) |
	"unlock" (premium tier reached, premium not bought → the CTA) | "premiumLocked" (premium tier
	not reached and not bought) | "preview" (no active season: read-only track).

	Example:
		local status = PassConfig.status(PassConfig.readState(profile.pass), now)
		print(PassView.cellState(status, state, "free", 3)) --> "claimable"
		print(PassView.headline(season.tiers[3].premium, "premium", profile, false)) --> "2 Spins"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local LuckySpinConfig = require(ReplicatedStorage.Shared.Config.LuckySpinConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PassConfig = require(ReplicatedStorage.Shared.Config.PassConfig)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PlayerTitlesConfig = require(ReplicatedStorage.Shared.Config.PlayerTitlesConfig)
local RetentionConfig = require(ReplicatedStorage.Shared.Config.RetentionConfig)
local RewardPreview = require(script.Parent.Parent.DailyRewards.RewardPreview)

-- One display part. `short` is the phone card's one-word form beside the icon ("x10", "15m").
export type Line = { icon: string, text: string, short: string? }
export type CellState = "claimed" | "claimable" | "locked" | "unlock" | "premiumLocked" | "preview"
export type Phase = {
	kind: "active" | "before" | "after", -- a season runs / the first one is coming / between seasons
	season: PassConfig.SeasonDef?, -- active: the running season; before: the next; after: the last ended
	at: number?, -- pass-clock instant the countdown runs to (active: end; before: start)
}

local PassView = {}

-- The display egg icon (RewardPreview uses the generic Gift; the pass has room for the egg art).
local EGG_ICON = "Egg"

--[[
	The reward a buyer would actually get (premium + paid random restricted → gems instead of
	spins / eggs; mirrors Server/Pass/PassLogic.premiumReward).
]]
local function shaped(reward: PassConfig.TierReward, track: string, restricted: boolean): PassConfig.TierReward
	if track ~= "premium" or not restricted then
		return reward
	end
	local out: PassConfig.TierReward = table.clone(reward) :: any
	local gems = out.gems or 0
	if out.spins ~= nil then
		gems += out.spins * LuckySpinConfig.GemsPerSpin
		out.spins = nil
	end
	if out.egg ~= nil then
		gems += out.fallbackGems or 0
		out.egg = nil
		out.fallbackGems = nil
	end
	out.gems = if gems > 0 then gems else nil
	return out
end

--[[
	Display lines of a tier reward: the exclusive first (it is the headline), then RewardPreview's
	parts (cash scaled by `profile`'s income, gems, spins, boost, egg).
	@param restricted the region restricts paid random items (EggConfig.policyState == "restricted")
]]
function PassView.lines(
	reward: PassConfig.TierReward,
	track: string,
	profile: { [string]: any }?,
	restricted: boolean
): { Line }
	local paid = shaped(reward, track, restricted)
	local lines: { Line } = {}
	if paid.pet ~= nil then
		local def = PetConfig.get(paid.pet)
		table.insert(lines, { icon = "Pets", text = if def ~= nil then def.name else "Golden Nukey", short = "Pet" })
	end
	if paid.trail ~= nil then
		local def = CrateConfig.getTrail(paid.trail)
		table.insert(
			lines,
			{ icon = "Star", text = `{if def ~= nil then def.name else "Exclusive"} Trail`, short = "Trail" }
		)
	end
	if paid.title ~= nil then
		local def = PlayerTitlesConfig.Titles[paid.title]
		table.insert(
			lines,
			{ icon = "Trophy", text = `{if def ~= nil then def.label else "Exclusive"} Title`, short = "Title" }
		)
	end
	local base: RetentionConfig.Reward = {
		cashSeconds = paid.cashSeconds,
		cashFloor = paid.cashFloor,
		gems = paid.gems,
		spins = paid.spins,
	}
	for _, line in RewardPreview.lines(base, profile) do
		-- Short forms: the amount alone reads well next to its icon on a phone card.
		local short: string? = nil
		if line.icon == "Cash" then
			short = line.text
		elseif line.icon == "Gems" and paid.gems ~= nil then
			short = `x{paid.gems}`
		elseif line.icon == "Spins" and paid.spins ~= nil then
			short = `x{paid.spins}`
		end
		table.insert(lines, { icon = line.icon, text = line.text, short = short })
	end
	-- Boosts read as "2x Cash 15 min" on a small card (RewardPreview's "15m 00s" is for timers).
	local boost = paid.boost
	if boost ~= nil then
		local def = BoostConfig.get(boost.key)
		local minutes = math.max(1, math.floor(boost.seconds / 60 + 0.5))
		table.insert(lines, {
			icon = if def ~= nil then def.icon else "x2Cash",
			text = `{if def ~= nil then def.name else "Boost"} {minutes} min`,
			short = `{minutes}m`,
		})
	end
	if paid.egg ~= nil then
		table.insert(lines, { icon = EGG_ICON, text = "Lucky Egg", short = "x1" })
	end
	return lines
end

--[[ The card's big icon (the first display line's icon; "Gift" for an empty reward). ]]
function PassView.iconOf(lines: { Line }): string
	return if lines[1] ~= nil then lines[1].icon else "Gift"
end

--[[ The card caption: the first two parts joined ("75 Gems + NUKE PASS Title"). ]]
function PassView.headline(
	reward: PassConfig.TierReward,
	track: string,
	profile: { [string]: any }?,
	restricted: boolean
): string
	local lines = PassView.lines(reward, track, profile, restricted)
	local parts: { string } = {}
	for index = 1, math.min(2, #lines) do
		table.insert(parts, lines[index].text)
	end
	return table.concat(parts, " + ")
end

--[[
	The button state of one card (see the header).
	@param status PassConfig.status of the repaired state at the pass clock
	@param state the repaired PassConfig.State
]]
function PassView.cellState(status: PassConfig.Status, state: PassConfig.State, track: string, tier: number): CellState
	if status.season == nil then
		return "preview"
	end
	local reached = tier <= status.tier
	if track == "premium" then
		if not status.premium then
			return if reached then "unlock" else "premiumLocked"
		end
		if state.claimedPremium[tier] == true then
			return "claimed"
		end
		return if reached then "claimable" else "locked"
	end
	if state.claimedFree[tier] == true then
		return "claimed"
	end
	return if reached then "claimable" else "locked"
end

--[[
	Where the pass is in its calendar at the pass clock `now`:
		active  a season runs (countdown to its end)
		before  no season yet, the next one is coming (countdown to its start)
		after   between seasons ("Season N+1 is coming soon!"; the last season's track as a preview)
]]
function PassView.phase(now: number): Phase
	local active = PassConfig.activeSeason(now)
	if active ~= nil then
		return { kind = "active", season = active, at = active.endsAt }
	end
	local nextSeason = PassConfig.nextSeason(now)
	if nextSeason ~= nil then
		return { kind = "before", season = nextSeason, at = nextSeason.startsAt }
	end
	return { kind = "after", season = PassConfig.lastEndedSeason(now), at = nil }
end

--[[
	The premium value line ("730 Gems · 18 Spins · 9 Eggs · Golden Nukey · Harvest Glow · NUKE PASS
	title"); spins / eggs read as gems where paid random items are restricted.
]]
function PassView.valueLine(season: PassConfig.SeasonDef, restricted: boolean): string
	local totals = PassConfig.totals(season, "premium")
	local parts: { string } = {}
	local gems = totals.gems
	if restricted then
		gems += totals.spins * LuckySpinConfig.GemsPerSpin
		for _, def in season.tiers do
			if def.premium.egg ~= nil then
				gems += def.premium.fallbackGems or 0
			end
		end
	end
	table.insert(parts, `{NumberFormat.commas(gems)} Gems`)
	if not restricted then
		table.insert(parts, `{totals.spins} Spins`)
		table.insert(parts, `{totals.eggs} Eggs`)
	end
	for _, def in season.tiers do
		local reward = def.premium
		if reward.pet ~= nil then
			local pet = PetConfig.get(reward.pet)
			table.insert(parts, if pet ~= nil then pet.name else "Golden Nukey")
		end
	end
	for _, def in season.tiers do
		local reward = def.premium
		if reward.trail ~= nil then
			local trail = CrateConfig.getTrail(reward.trail)
			table.insert(parts, `{if trail ~= nil then trail.name else "Exclusive"} Trail`)
		elseif reward.title ~= nil then
			local title = PlayerTitlesConfig.Titles[reward.title]
			table.insert(parts, `{if title ~= nil then title.label else "Exclusive"} Title`)
		end
	end
	return table.concat(parts, " · ")
end

--[[
	The real server time (Workspace:GetServerTimeNow scale) of a pass-clock instant: the pass clock
	may carry the Studio test offset (PassConfig.clockNow), StudUI countdowns run on server time.
	@param passInstant unix seconds on the pass clock
	@param serverNow Workspace:GetServerTimeNow()
]]
function PassView.toServerTime(passInstant: number, serverNow: number): number
	return passInstant - (PassConfig.clockNow(serverNow) - serverNow)
end

return table.freeze(PassView)
