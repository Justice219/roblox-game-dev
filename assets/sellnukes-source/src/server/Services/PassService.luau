--!strict
--[[
	PassService — the server side of the Nuke Pass (R78 retention pack, spec
	docs/superpowers/specs/2026-10-31-r78-retention-pack-design.md §2; docs/nuke-pass.md).

	Purpose:
		Owns profile.pass for every player: XP in (quest claims through ProgressEvents.Xp + its own
		play-time tick), the season rollover (end-of-season auto-grant, new-season reset), the claim
		remotes, the Nuke Pass Premium developer product and the admin commands. All rules live in
		the pure Server/Pass/PassLogic + Shared/Config/PassConfig; this module is the live boundary.

	XP:
		ProgressEvents.Xp(player, amount, source)  QuestService's claims ("starter", "daily",
		                                            "chest", "trophy"); amounts already validated
		                                            and clamped by ProgressEvents
		play tick   ONE loop for the whole server, once per minute (never per player / per frame):
		            each loaded player's online-minute counter +1; every PlayXp.EveryMinutes minutes
		            → PlayXp.Amount XP ("play"), capped at PlayXp.DailyCap per UTC day (PassLogic)
		XP only lands in the ACTIVE season; between seasons it is dropped (documented).

	Season rollover (settle): on join, on every XP grant / tick that sees a stale state, after a
	premium receipt and after admin edits. An ENDED season's reached-but-unclaimed rewards are
	granted automatically ("nothing is lost"), then a NEW active season resets the progress.
	Ordering (Server/Pass/PassFlow): XP / ticks / claims / admin settle only when PassFlow.decide says
	"now"; while a settle waits for the paid-random policy (or another settle / claim is in flight)
	XP is HELD and drained exactly once after it — never a settle with a guessed policy.

	Claims (C→S, intents only):
		PassClaim(track: "free" | "premium" | "overflow", tier: number)   one tier (overflow: every
		                                                                  earned bonus chest; tier 0)
		PassClaimAll()                                                    everything claimable
		Checks: RateLimiter, typeof + allowlist + integer range, one claim in flight per player,
		profile loaded + canMutate (never grant into an unsaveable session), the season / reached /
		claimed / premium rules (PassLogic). Premium rewards with spins / eggs are paid random
		items: the claim awaits PlayerDataService.resolvePaidRandomAsync (fail closed) BEFORE the
		grant step, re-checks the session after the yield, then runs ONE non-yielding step: mark
		claimed + pay every reward (RewardLogic.apply, PetGrants.grantFixed, CrateLogic.grantTrail,
		PlayerTitleService.grant; their fallbackGems when an item cannot be granted). Re-running the
		same claim pays nothing (claimed flags are set in the same step).

	Premium (developer product PassConfig.PremiumProduct, kind "PassPremium"):
		prompt   refused outside a season ("Season N starts soon!") and when already owned; every
		         other gate is MonetizationService's (New Player Mode, saveable session, ...)
		receipt  handler (no yield): PassLogic.premiumReceipt → premium[active season] = true, or
		         the season that ended ≤ PremiumGraceSeconds ago (state still holds it), else
		         PremiumFallbackGems gems (already owned / no season). The idempotent per-profile
		         receipt ledger is MonetizationService's. After the grant is durable
		         (ProductGranted): toast + analytics + settle (a grace unlock auto-grants the
		         ended season's premium tiers).

	Analytics (retention family, AnalyticsConfig "pass:*"): pass:xp:<source> (amount), pass:tier:<n>,
	pass:claims:<track> (amount), pass:claim:<track>:<tier>, pass:claimAll, pass:auto:<track>,
	pass:premium:<outcome>, pass:premiumTier:<tier>, pass:policyGems, pass:season:<seasonId>,
	pass:refused:<wait|recheck> (a claim tap refused while a season settle waits for the policy). The
	premium purchase funnel (prompt → purchase, source "pass") is MonetizationService's revenue
	recorders. Currency paid by rewards → PlayerDataService.CurrencyChanged reason "pass".

	Admin (Players tab unless noted; Lazy.registerAdmin, audited): PassGrantXp { amount },
	PassSetTier { tier }, PassPremium { mode on/off } (confirm), PassStatus (read-only),
	PassReset (Studio only), PassClock { days } (Server tab, Studio only: the test clock offset
	PassConfig.ClockOffsetAttribute, so seasons can be tested before / after their dates).

	Connects to: Shared/Config/{PassConfig, LuckySpinConfig, BoostConfig, PetConfig, CrateConfig,
	PlayerTitlesConfig}, Server/Pass/PassLogic, Server/Progression/ProgressEvents,
	Server/Retention/{RewardLogic, RewardGrant, ModifierHook}, Server/Pets/{PetGrants, CrateLogic},
	Server/Economy/ProfileLogic, Services/{PlayerDataService, MonetizationService,
	PlayerTitleService}, Server/Event/Lazy (analytics + admin), Shared/Net/{Remotes, Validate}.
	Boot: FEATURE service after PetService / CrateService / PlayerTitleService (init.server.luau).

	Example (tests / admin):
		PassService.grantXp(player, 400, "admin")   --> 400 (tier 1 reached)
		PassService.status(player)                  --> PassConfig.Status
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local BoostConfig = require(ReplicatedStorage.Shared.Config.BoostConfig)
local CrateConfig = require(ReplicatedStorage.Shared.Config.CrateConfig)
local CrateLogic = require(ServerScriptService.Server.Pets.CrateLogic)
local Lazy = require(ServerScriptService.Server.Event.Lazy)
local LuckySpinConfig = require(ReplicatedStorage.Shared.Config.LuckySpinConfig)
local ModifierHook = require(ServerScriptService.Server.Retention.ModifierHook)
local MonetizationService = require(script.Parent.MonetizationService)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PassConfig = require(ReplicatedStorage.Shared.Config.PassConfig)
local PassFlow = require(ServerScriptService.Server.Pass.PassFlow)
local PassLogic = require(ServerScriptService.Server.Pass.PassLogic)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PetGrants = require(ServerScriptService.Server.Pets.PetGrants)
local PlayerDataService = require(script.Parent.PlayerDataService)
local PlayerTitleService = require(script.Parent.PlayerTitleService)
local PlayerTitlesConfig = require(ReplicatedStorage.Shared.Config.PlayerTitlesConfig)
local ProfileLogic = require(ServerScriptService.Server.Economy.ProfileLogic)
local ProgressEvents = require(ServerScriptService.Server.Progression.ProgressEvents)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local RewardGrant = require(ServerScriptService.Server.Retention.RewardGrant)
local RewardLogic = require(ServerScriptService.Server.Retention.RewardLogic)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)

type Profile = ProfileLogic.Profile
type Grant = PassLogic.Grant

-- What one grant step paid (merged over every grant), for the toast and the profile push.
type Applied = {
	fields: { string }, -- top-level snapshot fields touched (always includes "pass")
	cash: number,
	gems: number,
	spins: number,
	eggs: number,
	boosts: { [string]: number }, -- boost key -> seconds added
	extras: { string }, -- exclusives granted ("Harvest Glow trail", "NUKE PASS title", pet name)
	policyGems: number, -- premium spins / eggs paid as gems (policy)
	counts: { [string]: number }, -- grants per track (free / premium / overflow)
}

-- A premium receipt waiting for its durable grant (toast + analytics), by PurchaseId.
type PendingReceipt = { outcome: PassLogic.PremiumOutcome, season: string?, tier: number, at: number }

local PassService = {}

-- Claim intents per player: a CLAIM ALL press plus a few single taps; honest UIs never hit it.
local claimLimiter = RateLimiter.new(6, 2)
-- Online minutes this session (the play-XP tick; session only, never saved).
local minutes: { [Player]: number } = {}
-- One claim / settle in flight per player (claims may yield on the paid-random policy).
local busy: { [Player]: boolean } = {}
-- XP held while a settle waits for the paid-random policy (Server/Pass/PassFlow; drained exactly
-- once when that settle / claim finishes).
local heldXp: { [Player]: { PassFlow.HeldXp } } = {}
-- os.clock() of the last "finishing last season" toast per player (mashing never spams).
local lastWaitNotice: { [Player]: number } = {}
-- Seconds between two of those toasts for one player.
local WAIT_NOTICE_SECONDS = 4
local pendingReceipts: { [string]: PendingReceipt } = {}
-- The active season id at the last play tick ("" = none; nil before the first tick).
local lastActiveSeason: string? = nil
-- Analytics XP sources (anything else is counted as "other").
local XP_SOURCES: { [string]: boolean } = {
	starter = true,
	daily = true,
	chest = true,
	trophy = true,
	play = true,
	admin = true,
}
-- Grant reason for PlayerDataService.CurrencyChanged (AnalyticsConfig.Economy "pass").
local REASON = "pass"
local CLAIM_TRACKS = { "free", "premium", "overflow" }
-- Pending receipts older than this are dropped (their toast simply never shows).
local PENDING_RECEIPT_SECONDS = 600
local started = false

local STILL_LOADING = "Your save is still loading - try again in a moment."
local NOT_SAVEABLE = "Rewards are paused while your save is offline. Please rejoin!"

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

-- The pass clock (server unix seconds + the Studio-only test offset; see PassConfig.clockNow).
local function now(): number
	return PassConfig.clockNow(os.time())
end

-- Counts a retention analytics key (guarded; never errors / yields).
local function track(player: Player?, key: string, amount: number?)
	Lazy.analytics("retention", player, key, amount)
end

-- The loaded profile of a player still in the game, else nil.
local function profileOf(player: Player): Profile?
	if player.Parent ~= Players then
		return nil
	end
	return PlayerDataService.getProfile(player)
end

-- The paid-random answer without yielding: known AND unrestricted (fail closed otherwise).
local function cachedAllow(player: Player): boolean
	return PlayerDataService.isPolicyKnown(player) and not PlayerDataService.isPaidRandomRestricted(player)
end

-- Adds `field` to a field list once.
local function addField(fields: { string }, field: string)
	if table.find(fields, field) == nil then
		table.insert(fields, field)
	end
end

-- Readable name of a reward exclusive ("Harvest Glow trail", "NUKE PASS title", "Golden Nukey").
local function exclusiveName(exclusive: PassLogic.Exclusive): string
	if exclusive.trail ~= nil then
		local def = CrateConfig.getTrail(exclusive.trail)
		return `{if def ~= nil then def.name else "Exclusive"} trail`
	elseif exclusive.title ~= nil then
		local def = PlayerTitlesConfig.Titles[exclusive.title]
		return `{if def ~= nil then def.label else "Exclusive"} title`
	elseif exclusive.pet ~= nil then
		local def = PetConfig.get(exclusive.pet)
		return if def ~= nil then def.name else "a golden pet"
	end
	return "an exclusive"
end

--[[
	Pays `grants` into `profile` in ONE non-yielding step (the caller already marked them claimed
	in profile.pass in this same step). Premium rewards are shaped by the paid-random policy
	(`allowPaidRandom`); items that cannot be granted pay their fallbackGems.
	@return Applied (merged totals + touched fields)
]]
local function applyGrants(player: Player, profile: Profile, grants: { Grant }, allowPaidRandom: boolean): Applied
	local applied: Applied = {
		fields = { "pass" },
		cash = 0,
		gems = 0,
		spins = 0,
		eggs = 0,
		boosts = {},
		extras = {},
		policyGems = 0,
		counts = {},
	}
	local granters = RewardGrant.granters()
	for _, grant in grants do
		applied.counts[grant.track] = (applied.counts[grant.track] or 0) + 1
		local reward = grant.reward
		local paidSpins = false
		if grant.track == "premium" then
			local shaped, paid = PassLogic.premiumReward(reward, allowPaidRandom, LuckySpinConfig.GemsPerSpin)
			if not paid then
				applied.policyGems += (shaped.gems or 0) - (reward.gems or 0)
			end
			reward, paidSpins = shaped, paid
		end
		local base, exclusive = PassLogic.splitReward(reward)
		-- Real server time for boost expiries (`at` is the pass clock, which may carry the Studio
		-- test offset and must never stretch a boost).
		local summary = RewardLogic.apply(profile, base, os.time(), granters, nil, { paidSpins = paidSpins })
		applied.cash += summary.cash
		applied.gems += summary.gems
		applied.spins += summary.spins
		if summary.egg ~= nil then
			applied.eggs += 1
		end
		if summary.boost ~= nil then
			applied.boosts[summary.boost.key] = (applied.boosts[summary.boost.key] or 0) + summary.boost.seconds
		end
		for _, field in summary.fields do
			addField(applied.fields, field)
		end
		if exclusive ~= nil then
			local granted = false
			if exclusive.pet ~= nil then
				-- The live PetService path (auto-equip, reveal popup, analytics); never yields.
				granted = PetGrants.grantFixed(player, exclusive.pet, REASON)
				if granted then
					addField(applied.fields, "pets")
				end
			elseif exclusive.trail ~= nil then
				granted = CrateLogic.grantTrail(profile, exclusive.trail)
				if granted then
					addField(applied.fields, "trails")
				end
			elseif exclusive.title ~= nil then
				-- Saved in profile.titles + the replicated Title attribute refreshed; never yields.
				granted = PlayerTitleService.grant(player, exclusive.title)
			end
			if granted then
				table.insert(applied.extras, exclusiveName(exclusive))
			elseif exclusive.fallbackGems > 0 then
				applied.gems += ProfileLogic.addGems(profile, exclusive.fallbackGems)
				addField(applied.fields, "gems")
			end
		end
	end
	-- Currency analytics (deferred inside announce) + modifier refresh for boosts, never in-step.
	if applied.cash > 0 or applied.gems > 0 then
		local merged: RewardLogic.Summary =
			{ cash = applied.cash, gems = applied.gems, spins = 0, fallbackGems = 0, fields = {} }
		RewardGrant.announce(player, profile, merged, REASON)
	end
	if next(applied.boosts) ~= nil then
		task.defer(ModifierHook.invalidate, player)
	end
	return applied
end

-- "+$1.2K, +75 Gems, +2 Spins, 2x Cash 30m, 2 eggs, NUKE PASS title" (or "nothing").
local function describe(applied: Applied): string
	local parts: { string } = {}
	if applied.cash > 0 then
		table.insert(parts, "+" .. NumberFormat.money(applied.cash))
	end
	if applied.gems > 0 then
		table.insert(parts, `+{NumberFormat.commas(applied.gems)} Gems`)
	end
	if applied.spins > 0 then
		table.insert(parts, `+{applied.spins} Spin{if applied.spins == 1 then "" else "s"}`)
	end
	local keys: { string } = {}
	for key in applied.boosts do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		local def = BoostConfig.get(key)
		local boostMinutes = math.max(1, math.floor(applied.boosts[key] / 60 + 0.5))
		table.insert(parts, `{if def ~= nil then def.name else key} {boostMinutes} min`)
	end
	if applied.eggs > 0 then
		table.insert(parts, if applied.eggs == 1 then "an egg" else `{applied.eggs} eggs`)
	end
	for _, extra in applied.extras do
		table.insert(parts, extra)
	end
	return if #parts == 0 then "nothing" else table.concat(parts, ", ")
end

-- Analytics for paid grants (claims or auto-grants).
local function trackApplied(player: Player, applied: Applied, grants: { Grant }, auto: boolean)
	for trackId, count in applied.counts do
		track(player, if auto then `pass:auto:{trackId}` else `pass:claims:{trackId}`, count)
	end
	if not auto then
		for _, grant in grants do
			if grant.track ~= "overflow" then
				track(player, `pass:claim:{grant.track}:{grant.tier}`)
			end
		end
	end
	if applied.policyGems > 0 then
		track(player, "pass:policyGems", applied.policyGems)
	end
end

--------------------------------------------------------------------------------------------------
-- Season rollover
--------------------------------------------------------------------------------------------------

--[[
	Settles the season NOW (no yield): an ended season's leftovers are paid (premium spins / eggs
	with `allowPaidRandom`), then a new active season resets the progress.
	@return true when anything changed
]]
local function settleNow(player: Player, profile: Profile, allowPaidRandom: boolean, at: number): boolean
	if not PassLogic.needsRollover(profile.pass, at) then
		return false
	end
	-- Leftovers are permanent rewards: never into a session that cannot be saved (retried on the
	-- next join, the state is left untouched).
	local preview = PassLogic.rollover(PassLogic.clone(profile.pass), at)
	if #preview.grants > 0 and not PlayerDataService.canMutate(player) then
		return false
	end
	local result = PassLogic.rollover(profile.pass, at)
	local fields = { "pass" }
	if #result.grants > 0 then
		local applied = applyGrants(player, profile, result.grants, allowPaidRandom)
		fields = applied.fields
		trackApplied(player, applied, result.grants, true)
		local def = PassConfig.season(result.ended)
		PlayerDataService.notify(
			player,
			`{if def ~= nil then def.name else "The season"} ended! Your unclaimed Nuke Pass rewards were added: {describe(
				applied
			)}`,
			"reward",
			"NukePass"
		)
	end
	if result.started ~= nil then
		track(player, `pass:season:{result.started}`)
	end
	PlayerDataService.markChanged(player, #result.grants > 0, fields)
	return true
end

-- Applies XP held during a policy wait (declared here, defined in the XP section below).
local releaseHeldXp: (player: Player) -> ()

--[[
	Settles the season, waiting (≤ 10 s) for the paid-random policy first when an ended season
	owes premium spins / eggs and the answer is not known yet, then applies any XP that was HELD
	meanwhile (PassFlow). Safe to call any time; one per player at a time (busy).
]]
function PassService.settle(player: Player)
	local profile = profileOf(player)
	if profile == nil or busy[player] then
		return
	end
	local at = now()
	if not PassLogic.needsRollover(profile.pass, at) then
		releaseHeldXp(player)
		return
	end
	local allow = cachedAllow(player)
	local preview = PassLogic.rollover(PassLogic.clone(profile.pass), at)
	if PassLogic.needsPolicy(preview.grants) and not PlayerDataService.isPolicyKnown(player) then
		busy[player] = true
		local ok, restricted = pcall(PlayerDataService.resolvePaidRandomAsync, player)
		busy[player] = nil
		allow = ok and restricted == false
		-- The session may have changed while waiting (left, New Player Mode swap): the held XP
		-- belonged to the old session and is dropped with it.
		if profileOf(player) ~= profile then
			heldXp[player] = nil
			return
		end
		at = now()
	end
	settleNow(player, profile, allow, at)
	releaseHeldXp(player)
end

--[[
	Settles now when that is safe (PassFlow.decide): "settled" / "now" → true (the state is current),
	"wait" → false, and when nothing else is in flight the waiting settle is started. Every non-
	settle path (XP, play tick, claims, admin) goes through this, never through a guessed policy.
]]
local function settleIfReady(player: Player, profile: Profile, at: number, onWait: (() -> ())?): boolean
	local decision = PassFlow.decide(profile.pass, at, PlayerDataService.isPolicyKnown(player), busy[player] == true)
	if decision == "settled" then
		return true
	elseif decision == "now" then
		settleNow(player, profile, cachedAllow(player), at)
		return true
	end
	-- `onWait` runs BEFORE the waiting settle starts, so XP held there is always drained by it
	-- (even if the policy lookup answers without yielding).
	if onWait ~= nil then
		onWait()
	end
	if not busy[player] then
		task.spawn(PassService.settle, player)
	end
	return false
end

--------------------------------------------------------------------------------------------------
-- XP
--------------------------------------------------------------------------------------------------

--[[
	Adds XP (any source) into the active season; pushes the profile and counts analytics. When the
	season must be settled first and that cannot happen safely right now (a settle / claim is in
	flight, or the rollover owes premium spins / eggs and the policy is unknown), the XP is HELD and
	applied once that settle finishes (PassFlow) — never into the stale state, never twice.
	@return XP added now (0 when held, outside a season or capped)
]]
local function giveXp(player: Player, profile: Profile, amount: number, source: string, at: number): number
	local function holdIt()
		local queue = heldXp[player]
		if queue == nil then
			queue = {}
			heldXp[player] = queue
		end
		PassFlow.hold(queue, amount, source, at)
	end
	if not settleIfReady(player, profile, at, holdIt) then
		return 0
	end
	local added, reached = PassLogic.addXp(profile.pass, amount, source, at)
	if added <= 0 then
		return 0
	end
	PlayerDataService.markChanged(player, #reached > 0, { "pass" })
	track(player, `pass:xp:{if XP_SOURCES[source] then source else "other"}`, added)
	for _, tier in reached do
		track(player, `pass:tier:{tier}`)
	end
	local highest = reached[#reached]
	if highest ~= nil then
		PlayerDataService.notify(
			player,
			`Nuke Pass tier {highest} reached! Open the pass to claim.`,
			"success",
			"NukePass"
		)
	end
	return added
end

-- Applies the XP held during a policy wait, exactly once, through the normal XP path (a new
-- season: it lands there; between seasons: the documented rule drops it).
releaseHeldXp = function(player: Player)
	local queue = heldXp[player]
	if queue == nil or #queue == 0 then
		return
	end
	local profile = profileOf(player)
	local held = PassFlow.drain(queue)
	if profile == nil then
		return
	end
	for _, entry in held do
		giveXp(player, profile, entry.amount, entry.source, now())
	end
end

--[[
	Grants Nuke Pass XP to an online player (admin / tests; gameplay XP comes through
	ProgressEvents.xp and the play tick).
	@return XP actually added (0 outside a season / profile not loaded)
]]
function PassService.grantXp(player: Player, amount: number, source: string): number
	local profile = profileOf(player)
	if profile == nil then
		return 0
	end
	return giveXp(player, profile, amount, source, now())
end

-- ProgressEvents.Xp listener (amount + source already validated by ProgressEvents).
local function onXp(player: Player, amount: number, source: string)
	local profile = profileOf(player)
	if profile ~= nil then
		giveXp(player, profile, amount, source, now())
	end
end

-- The once-per-minute play tick for every loaded player (one loop for the server).
local function playTick()
	local at = now()
	-- A season boundary (start / end) re-pushes `pass` to everyone, so time-based UI (the HUD Pass
	-- offer, the NukePass screen phase) flips within a minute even for players with nothing to
	-- settle. Once per boundary, not per tick.
	local active = PassConfig.activeSeason(at)
	local activeId = if active ~= nil then active.id else ""
	if lastActiveSeason ~= nil and activeId ~= lastActiveSeason then
		for _, player in Players:GetPlayers() do
			PlayerDataService.refresh(player, { "pass" })
		end
	end
	lastActiveSeason = activeId
	for _, player in Players:GetPlayers() do
		local profile = PlayerDataService.getProfile(player)
		if profile ~= nil then
			local ok, err = pcall(function()
				local count = (minutes[player] or 0) + 1
				minutes[player] = count
				local xp = PassLogic.playXpFor(count)
				if xp > 0 then
					giveXp(player, profile, xp, "play", at)
				else
					-- A season ended / started while the player is online (safe-settle rules).
					settleIfReady(player, profile, at)
				end
			end)
			if not ok then
				warn(`[PassService] play tick failed for {player.Name}: {err}`)
			end
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Claims
--------------------------------------------------------------------------------------------------

-- Player-facing text for a refused claim (nil = stay silent: hostile / impossible input).
local function refusalText(code: PassLogic.ClaimCode, tier: number): string?
	if code == "NoSeason" then
		local next = PassConfig.nextSeason(now())
		return if next ~= nil
			then `Nuke Pass Season {next.number} starts soon!`
			else "This season is over - your rewards were added automatically!"
	elseif code == "NotReached" then
		return `Reach tier {tier} first!`
	elseif code == "Claimed" then
		return "Already claimed!"
	elseif code == "NotPremium" then
		return "Unlock Nuke Pass Premium to claim this!"
	end
	return nil
end

--[[
	Tells the player why a claim tap did nothing while the season settle waits for the region
	policy (at most one toast per WAIT_NOTICE_SECONDS; every refusal is counted).
	@param reason "wait" (a settle is finishing) | "recheck" (newly reached premium tiers need the policy)
]]
local function noticeWait(player: Player, reason: "wait" | "recheck")
	track(player, `pass:refused:{reason}`)
	local last = lastWaitNotice[player]
	if last ~= nil and os.clock() - last < WAIT_NOTICE_SECONDS then
		return
	end
	lastWaitNotice[player] = os.clock()
	PlayerDataService.notify(player, "Finishing last season's rewards... try again in a moment!", "info", "NukePass")
end

-- Runs a claim rule on a state: one tier, the bonus chests, or CLAIM ALL.
local function runClaim(
	state: PassConfig.State,
	kind: "one" | "all",
	trackId: string,
	tier: number,
	at: number
): (PassLogic.ClaimCode, { Grant })
	if kind == "all" then
		return PassLogic.claimAll(state, at)
	end
	if trackId == "overflow" then
		local chests = PassLogic.claimOverflow(state, at)
		if #chests > 0 then
			return "Ok", chests
		end
		return if PassConfig.activeSeason(at) == nil then "NoSeason" else "Claimed", chests
	end
	local code, grant = PassLogic.claim(state, trackId, tier, at)
	return code, if grant ~= nil then { grant } else {}
end

--[[
	A claim intent (PassClaim / PassClaimAll after validation): see the module header.
	@return the grants paid (empty when refused)
]]
local function handleClaim(player: Player, kind: "one" | "all", trackId: string, tier: number): { Grant }
	if busy[player] then
		return {}
	end
	local profile = profileOf(player)
	if profile == nil then
		PlayerDataService.notify(player, STILL_LOADING, "info")
		return {}
	end
	if not PlayerDataService.canMutate(player) then
		PlayerDataService.notify(player, NOT_SAVEABLE, "info")
		return {}
	end
	-- The season must be current before a claim; if that needs the policy, the waiting settle
	-- runs (started here) and this press is refused with a rate-limited "try again" toast.
	if not settleIfReady(player, profile, now()) then
		noticeWait(player, "wait")
		PlayerDataService.refresh(player, { "pass" })
		return {}
	end
	busy[player] = true
	local ok, result = pcall(function(): { Grant }
		local at = now()
		-- Dry run first: what WOULD this pay? (No mutation before a possible policy yield.)
		local code, preview = runClaim(PassLogic.clone(profile.pass), kind, trackId, tier, at)
		if code ~= "Ok" then
			local text = refusalText(code, tier)
			if text ~= nil then
				PlayerDataService.notify(player, text, "info", "NukePass")
			end
			PlayerDataService.refresh(player, { "pass" })
			return {}
		end
		local allow = cachedAllow(player)
		if PassLogic.needsPolicy(preview) and not PlayerDataService.isPolicyKnown(player) then
			local resolved, restricted = pcall(PlayerDataService.resolvePaidRandomAsync, player)
			allow = resolved and restricted == false
			-- Re-check everything the yield could have changed.
			if profileOf(player) ~= profile or not PlayerDataService.canMutate(player) then
				return {}
			end
			at = now()
		end
		-- XP that arrived during the wait may have reached more premium tiers: never pay spins /
		-- eggs with a guessed policy (the tap is refused; the lookup is under way).
		local _, recheck = runClaim(PassLogic.clone(profile.pass), kind, trackId, tier, at)
		if PassLogic.needsPolicy(recheck) and not PlayerDataService.isPolicyKnown(player) then
			noticeWait(player, "recheck")
			PlayerDataService.refresh(player, { "pass" })
			return {}
		end
		-- The grant step: claim + pay, no yield in between.
		local finalCode, grants = runClaim(profile.pass, kind, trackId, tier, at)
		if finalCode ~= "Ok" or #grants == 0 then
			PlayerDataService.refresh(player, { "pass" })
			return {}
		end
		local applied = applyGrants(player, profile, grants, allow)
		PlayerDataService.markChanged(player, true, applied.fields)
		trackApplied(player, applied, grants, false)
		if kind == "all" then
			track(player, "pass:claimAll")
		end
		local head = if kind == "all"
			then `Claimed {#grants} reward{if #grants == 1 then "" else "s"}!`
			elseif trackId == "overflow" then "Bonus chest!"
			else `Tier {tier} claimed!`
		PlayerDataService.notify(player, `{head} {describe(applied)}`, "reward", "NukePass")
		return grants
	end)
	busy[player] = nil
	releaseHeldXp(player) -- XP that waited for this claim's policy lookup
	if not ok then
		warn(`[PassService] claim failed for {player.Name}: {result}`)
		return {}
	end
	return result
end

-- PassClaim(track, tier) remote handler: typeof + allowlist + integer range, then handleClaim.
local function onClaimRemote(player: Player, rawTrack: unknown, rawTier: unknown)
	if not claimLimiter:Allow(player) then
		return
	end
	local trackId = Validate.oneOf(rawTrack, CLAIM_TRACKS)
	local tier = Validate.integer(rawTier, 0, PassConfig.TierCount)
	if trackId == nil or tier == nil or (trackId ~= "overflow" and tier < 1) then
		return
	end
	handleClaim(player, "one", trackId, tier)
end

-- PassClaimAll() remote handler (no arguments; extra arguments are ignored).
local function onClaimAllRemote(player: Player)
	if not claimLimiter:Allow(player) then
		return
	end
	handleClaim(player, "all", "free", 0)
end

--[[ Test / admin seam: claims like the remotes (no rate limit). @return grants paid ]]
function PassService.claim(player: Player, trackId: string, tier: number): { Grant }
	return handleClaim(player, "one", trackId, tier)
end
function PassService.claimAll(player: Player): { Grant }
	return handleClaim(player, "all", "free", 0)
end

--------------------------------------------------------------------------------------------------
-- Premium product
--------------------------------------------------------------------------------------------------

-- Prompt-time refusal of "PassPremium" (no yield): outside a season, or already owned.
local function premiumRefusal(player: Player, _product: any): string?
	local at = now()
	local active = PassConfig.activeSeason(at)
	if active == nil then
		local next = PassConfig.nextSeason(at)
		return if next ~= nil
			then `Nuke Pass Season {next.number} starts soon!`
			else "The next Nuke Pass season is coming soon!"
	end
	local profile = PlayerDataService.getProfile(player)
	if profile ~= nil and profile.pass.premium[active.id] == true then
		return "You already own Nuke Pass Premium this season!"
	end
	return nil
end

-- "PassPremium" receipt handler (inside MonetizationService's no-yield grant step).
local function premiumHandler(_player: Player, profile: Profile, _product: any, receipt: any): boolean
	local at = now()
	local outcome, seasonId = PassLogic.premiumReceipt(profile.pass, at)
	if outcome == "fallback" then
		ProfileLogic.addGems(profile, PassConfig.PremiumFallbackGems)
	end
	pendingReceipts[receipt.PurchaseId] = {
		outcome = outcome,
		season = seasonId,
		tier = PassConfig.tierOf(profile.pass.xp),
		at = os.clock(),
	}
	return true
end

-- After a premium grant is durable: analytics, toast, settle (grace unlocks pay out here).
local function onProductGranted(player: Player, key: string, _robux: number, receipt: any)
	if key ~= PassConfig.PremiumProduct then
		return
	end
	local pending = pendingReceipts[receipt.PurchaseId]
	pendingReceipts[receipt.PurchaseId] = nil
	-- Drop stale entries (a buyer who left before the save finished).
	for id, entry in pendingReceipts do
		if os.clock() - entry.at > PENDING_RECEIPT_SECONDS then
			pendingReceipts[id] = nil
		end
	end
	if pending == nil then
		return -- a re-delivered, already-granted receipt: nothing new happened
	end
	track(player, `pass:premium:{pending.outcome}`)
	track(player, `pass:premiumTier:{pending.tier}`)
	if pending.outcome == "fallback" then
		local profile = profileOf(player)
		if profile ~= nil then
			local merged: RewardLogic.Summary =
				{ cash = 0, gems = PassConfig.PremiumFallbackGems, spins = 0, fallbackGems = 0, fields = {} }
			RewardGrant.announce(player, profile, merged, REASON)
		end
		PlayerDataService.notify(
			player,
			`No Nuke Pass season to unlock right now - here are {PassConfig.PremiumFallbackGems} Gems instead!`,
			"reward",
			"Gems"
		)
		return
	end
	PlayerDataService.notify(player, "NUKE PASS PREMIUM unlocked! Claim your premium rewards.", "reward", "NukePass")
	-- settle may wait for the paid-random policy: never yield inside the signal (handlers run in
	-- the firing thread, MonetizationService's receipt path).
	task.spawn(PassService.settle, player)
end

--------------------------------------------------------------------------------------------------
-- Read-only status (admin / tests)
--------------------------------------------------------------------------------------------------

--[[ The player's pass status at the pass clock (nil until the profile loads). ]]
function PassService.status(player: Player): PassConfig.Status?
	local profile = profileOf(player)
	if profile == nil then
		return nil
	end
	return PassConfig.status(profile.pass, now())
end

--------------------------------------------------------------------------------------------------
-- Admin
--------------------------------------------------------------------------------------------------

type Ctx = { args: { [string]: any }, target: { player: Player?, label: string }? }

-- The online target of a Player-target command, or nil.
local function targetOf(ctx: Ctx): Player?
	local target = ctx.target
	return if target ~= nil then target.player else nil
end

local function registerAdmin()
	Lazy.registerAdmin({
		name = "PassGrantXp",
		tab = "Players",
		label = "Nuke Pass: Give XP",
		description = "Adds Nuke Pass XP in the active season (400 XP = one tier).",
		target = "Player",
		args = {
			amount = {
				kind = "integer",
				min = 1,
				max = PassConfig.TierCount * PassConfig.XpPerTier,
				presets = { 100, 400, 2_000, 12_000 },
				label = "XP",
				default = 400,
			},
		},
		argOrder = { "amount" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 400,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Player not in this server"
		end
		local added = PassService.grantXp(player, ctx.args.amount, "admin")
		if added <= 0 then
			return false, "No XP added (no active season / profile not loaded)"
		end
		return true, `Gave {added} Nuke Pass XP to {player.Name}`
	end)
	Lazy.registerAdmin({
		name = "PassSetTier",
		tab = "Players",
		label = "Nuke Pass: Set Tier",
		description = "Sets the player's tier in the active season (claimed rewards stay claimed).",
		target = "Player",
		args = {
			tier = {
				kind = "integer",
				min = 0,
				max = PassConfig.TierCount,
				presets = { 0, 5, 10, 20, 30 },
				label = "Tier",
				default = 10,
			},
		},
		argOrder = { "tier" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 401,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		local profile = if player ~= nil then profileOf(player) else nil
		if player == nil or profile == nil then
			return false, "Player not in this server / not loaded"
		end
		local at = now()
		if not settleIfReady(player, profile, at) then
			return false, "Settling the season (waiting for the region policy) - try again in a moment"
		end
		if not PassLogic.setTier(profile.pass, ctx.args.tier, at) then
			return false, "No active Nuke Pass season"
		end
		PlayerDataService.markChanged(player, true, { "pass" })
		return true, `{player.Name} is now Nuke Pass tier {ctx.args.tier}`
	end)
	Lazy.registerAdmin({
		name = "PassPremium",
		tab = "Players",
		label = "Nuke Pass: Premium",
		description = "Turns Nuke Pass Premium on / off for the active season (no Robux involved).",
		target = "Player",
		args = { mode = { kind = "enum", values = { "on", "off" }, labels = { "ON", "OFF" }, label = "Premium" } },
		argOrder = { "mode" },
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "purple",
		order = 402,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		local profile = if player ~= nil then profileOf(player) else nil
		if player == nil or profile == nil then
			return false, "Player not in this server / not loaded"
		end
		local at = now()
		if not settleIfReady(player, profile, at) then
			return false, "Settling the season (waiting for the region policy) - try again in a moment"
		end
		local on = ctx.args.mode == "on"
		local changed, seasonId = PassLogic.setPremium(profile.pass, on, at)
		if seasonId == nil then
			return false, "No active Nuke Pass season"
		end
		if changed then
			PlayerDataService.markChanged(player, true, { "pass" })
			track(player, "pass:premium:admin")
		end
		return true, `{player.Name}: Nuke Pass Premium {if on then "ON" else "OFF"} ({seasonId})`
	end)
	Lazy.registerAdmin({
		name = "PassStatus",
		tab = "Players",
		label = "Nuke Pass: Status",
		description = "The player's season, tier, XP, premium and claimable rewards.",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = false,
		confirm = false,
		color = "orange",
		order = 403,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		local profile = if player ~= nil then profileOf(player) else nil
		if player == nil or profile == nil then
			return false, "Player not in this server / not loaded"
		end
		local at = now()
		local status = PassConfig.status(profile.pass, at)
		local active = PassConfig.activeSeason(at)
		return true,
			`season {if profile.pass.season == "" then "-" else profile.pass.season} (active {if active ~= nil
				then active.id
				else "none"}) · tier {status.tier} ({status.xpInto}/{status.xpPer}) · xp {profile.pass.xp} · play today {profile.pass.dayXp}/{PassConfig.PlayXp.DailyCap} · premium {if status.premium
				then "yes"
				else "no"} · claimable {PassConfig.claimableCount(profile.pass, at)}`
	end)
	Lazy.registerAdmin({
		name = "PassReset",
		tab = "Players",
		label = "Nuke Pass: Reset (Studio)",
		description = "Studio only: wipes the player's Nuke Pass state (season, XP, claims, premium).",
		target = "Player",
		args = {},
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "red",
		studioOnly = true,
		order = 404,
	}, function(ctx: any): (boolean, string)
		local player = targetOf(ctx)
		local profile = if player ~= nil then profileOf(player) else nil
		if player == nil or profile == nil or not RunService:IsStudio() then
			return false, "Studio only; player must be loaded"
		end
		profile.pass = PassConfig.newState()
		heldXp[player] = nil
		settleIfReady(player, profile, now()) -- a fresh state never owes leftovers
		PlayerDataService.markChanged(player, true, { "pass" })
		return true, `Reset {player.Name}'s Nuke Pass`
	end)
	Lazy.registerAdmin({
		name = "PassClock",
		tab = "Server",
		label = "Nuke Pass Clock (Studio)",
		description = "Studio only: shifts the Nuke Pass clock by N days (0 = real time) to test season start / end.",
		target = "None",
		args = {
			days = { kind = "number", min = -400, max = 400, presets = { 0, 1, 15, 31 }, label = "Days", default = 0 },
		},
		argOrder = { "days" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		studioOnly = true,
		order = 75,
	}, function(ctx: any): (boolean, string)
		if not RunService:IsStudio() then
			return false, "Studio only"
		end
		local days = math.clamp(ctx.args.days, -400, 400)
		ReplicatedStorage:SetAttribute(PassConfig.ClockOffsetAttribute, days * 86_400)
		for _, player in Players:GetPlayers() do
			PlayerDataService.refresh(player, { "pass" }) -- time-based UI re-reads the clock
			task.spawn(PassService.settle, player)
		end
		local active = PassConfig.activeSeason(now())
		return true,
			`Nuke Pass clock {if days >= 0 then "+" else ""}{days} d · active season: {if active ~= nil
				then active.name
				else "none"}`
	end)
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

function PassService.Init()
	MonetizationService.registerProductHandler("PassPremium", premiumHandler)
	MonetizationService.registerPromptRefusal("PassPremium", premiumRefusal)
end

function PassService.Start()
	if started then
		return
	end
	started = true
	Lazy.registerIds("seasonId", function(id: string): boolean
		return PassConfig.season(id) ~= nil
	end)
	ProgressEvents.Xp:Connect(onXp)
	MonetizationService.ProductGranted:Connect(onProductGranted)
	Remotes.onServerEvent("PassClaim", onClaimRemote)
	Remotes.onServerEvent("PassClaimAll", onClaimAllRemote)
	PlayerDataService.ProfileLoaded:Connect(function(player: Player, _profile: Profile, _isNew: boolean)
		minutes[player] = minutes[player] or 0
		task.spawn(PassService.settle, player)
	end)
	for _, player in Players:GetPlayers() do
		if PlayerDataService.getProfile(player) ~= nil then
			minutes[player] = minutes[player] or 0
			task.spawn(PassService.settle, player)
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		minutes[player] = nil
		busy[player] = nil
		heldXp[player] = nil
		lastWaitNotice[player] = nil
		claimLimiter:Forget(player)
	end)
	task.spawn(function()
		while true do
			task.wait(60)
			playTick()
		end
	end)
	registerAdmin()
end

return PassService
