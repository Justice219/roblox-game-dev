--!strict
--[[
	FlavorService — the server of owner R89's Surprise Batches, Flavour Book and Big Pop (spec
	docs/superpowers/specs/2026-10-31-r89-competitive-wave-design.md §1).

	Rolls (the hot path)
		TycoonService's two pay paths call FlavorService.batch(player, worldId, producerId, cycles,
		perCycle, present) once per producer per payout tick with the finished cycles (clicked or
		automated) and ADD the returned bonus to that producer's payout:
			bonus = perCycle × Σ counts[r] × (mult_r − 1)
		Rolls are server-only, from one seeded stream per player (Shared/Attack/AttackRng seeded by
		a per-server secret mixed with the UserId — clients can't predict them) through
		FlavorLogic.rollInto: <= Roll.ExactCap cycles one by one, more in AGGREGATE (one binomial
		per flavour, bounded work — a 5000-cycle hitch catch-up costs ~10 draws). batch() only rolls
		and buffers (no remotes, no profile writes, no allocation in steady state); everything
		visible happens in the flush.
	Flush (one Heartbeat accumulator, every FlavorConfig.FlushSeconds)
		per player: found counts → profile.flavors (FlavorLogic.addFound; a NEW discovery toasts
		and pushes `flavors` at once, plain count growth at most every PushSeconds) · per producer
		the best flavour since the last flush → FlavorPop (owner, only while in that world) ·
		Rainbow+ → FlavorGlow to every player in that world (per-producer GlowCooldown) · Galaxy+ →
		FlavorHighlight (the owner's reveal) + a Big Pop · the Quests "flavor" stat through a token
		bucket (FlavorConfig.QuestCredit) · analytics batched every AnalyticsFlushSeconds.
		Also steps BigPop (global throttle) and refreshes the luck every LuckRefreshSeconds.
	Luck
		event (FlavorLogic.eventLuck: Happy Hours' Sprinkle Surge, E-events) × admin odds,
		clamped; ONE shared chance table for every player. Replicated for the Book through
		ReplicatedStorage attributes FlavorConfig.Attr (Enabled / Luck / EventLuck; only this module
		writes them).
	Flavour Book claims
		FlavorClaim(key | "all"): RateLimiter → profile loaded + writable (canMutate) →
		FlavorLogic.claim per key (idempotent; parseKey allowlist, known world, found, unclaimed) →
		PlayerDataService.grantGems + markChanged({ "flavors" }, saveSoon) in the same step (no
		yield anywhere) → toast + analytics. Refusals change nothing.
	Big Pop triggers (Server/Tycoon/BigPop): Galaxy+ batches (here), Mythic+ hatches
		(PetService.Hatched) and rebirths (RebirthService.Rebirthed / WorldRebirthed) — listened to
		in Start through guarded lazy requires, so neither service is edited or required at load.
	Admin (Server/Tycoon/FlavorAdmin): FlavorSettings (kill switch, odds multiplier, Big Pop
		switch; this server), FlavorGrant (force the target's next batch to a flavour, QA),
		FlavorBookReset (Studio only).

	Security: clients send only FlavorClaim intents (validated keys); every roll, multiplier, gem
	amount and discovery is decided here. Performance: O(1) per pay call, one Heartbeat for the
	whole system, remotes only for flavoured batches (FlavorPop unreliable, per producer per flush).

	API
		FlavorService.batch(player, worldId, producerId, cycles, perCycle, present) -> number
		FlavorService.settings() -> { enabled, odds, bigPop, luck, eventLuck }
		FlavorService.setSettings(enabled, odds, bigPop) -> (ok, message)
		FlavorService.adminForce(player, flavorId) -> (ok, message)
		FlavorService.adminReset(player) -> (ok, message)

	Usage: boot list "Tycoon/FlavorService" (after Tycoon/TycoonService); TycoonService requires it
	for the pay-path hook (batch() returns 0 until Start ran).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackRng = require(ReplicatedStorage.Shared.Attack.AttackRng)
local BigPop = require(script.Parent.BigPop)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local FlavorAdmin = require(script.Parent.FlavorAdmin)
local FlavorConfig = require(ReplicatedStorage.Shared.Config.FlavorConfig)
local FlavorLogic = require(ReplicatedStorage.Shared.Tycoon.FlavorLogic)
local PetConfig = require(ReplicatedStorage.Shared.Config.PetConfig)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)
local PlotService = require(script.Parent.PlotService)
local ProgressEvents = require(script.Parent.Parent.Progression.ProgressEvents)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TycoonAnalytics = require(script.Parent.TycoonAnalytics)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local SPECIAL = FlavorConfig.Special
local COUNT = FlavorConfig.SpecialCount
local FLAVOR_FIELDS: { string } = table.freeze({ "flavors" }) :: any
-- Server-set Player attribute naming the world the character is in (WorldService).
local CURRENT_WORLD_ATTR = "CurrentWorld"

-- One world's buffered rolls since the last flush.
type WorldPending = { counts: { number }, bonus: number, any: boolean }
-- One producer's best flavour since the last flush (entries are reused, never re-created).
type Highlight = {
	worldId: string,
	rank: number,
	count: number,
	present: boolean,
	perCycle: number,
	sentAt: number, -- os.clock() of its last FlavorPop (PopSendSeconds throttle)
}
type PlayerState = {
	rng: AttackRng.Rng,
	pending: { [string]: WorldPending },
	highlights: { [string]: Highlight },
	hasHighlights: boolean,
	forced: number?, -- admin QA: the rank the next batch in the player's world becomes
	creditBank: number,
	creditAt: number?,
	creditEarned: number,
	dirtyCounts: boolean,
	pushAt: number,
	glowAt: { [string]: number },
	analytics: { [string]: number },
}

local FlavorService = {}

local started = false
local enabled = FlavorConfig.DefaultEnabled -- ship default; the admin kill switch overrides (this server)
local adminOdds = 1 -- admin odds multiplier (this server)
local eventLuck = 1 -- Happy Hours (refreshed every LuckRefreshSeconds)
local liveLuck = 1
local liveChances: { number } = FlavorLogic.chances(1)
local serverSeed = Random.new():NextInteger(1, 2_147_483_646)

local states: { [Player]: PlayerState } = {}
-- Reused roll buffer (batch() never yields, so one table serves every call).
local scratch: { number } = table.create(COUNT, 0)

local claimLimiter = RateLimiter.new(FlavorConfig.ClaimBurst, FlavorConfig.ClaimPerSecond)

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

-- Adds to a player's analytics batch (flushed every AnalyticsFlushSeconds).
local function track(state: PlayerState, key: string, amount: number?)
	state.analytics[key] = (state.analytics[key] or 0) + (amount or 1)
end

-- Reports one key right away (rare events: claims, refusals, admin).
local function trackNow(player: Player?, key: string, amount: number?)
	TycoonAnalytics.call("tycoon", player, key, amount)
end

-- The world display name ("Nuke Town").
local function worldName(worldId: string): string
	local def = WorldsConfig.get(worldId)
	return if def ~= nil then def.name else worldId
end

-- The world a player is in (server attribute; Nuke Town by default).
local function currentWorldOf(player: Player): string
	local def = WorldsConfig.get(player:GetAttribute(CURRENT_WORLD_ATTR))
	return if def ~= nil then def.id else WorldsConfig.MAIN
end

-- Fresh per-player state with its own seeded roll stream.
local function newState(player: Player): PlayerState
	return {
		rng = AttackRng.new(AttackRng.mix(serverSeed, player.UserId)),
		pending = {},
		highlights = {},
		hasHighlights = false,
		forced = nil,
		creditBank = FlavorConfig.QuestCredit.Burst,
		creditAt = nil,
		creditEarned = 0,
		dirtyCounts = false,
		pushAt = 0,
		glowAt = {},
		analytics = {},
	}
end

-- The player's state (created on first use while they are in the game).
local function stateOf(player: Player): PlayerState?
	local state = states[player]
	if state == nil and player.Parent == Players then
		state = newState(player)
		states[player] = state
	end
	return state
end

-- The profile's Book (repaired in place if a profile somehow lacks it).
local function bookOf(profile: any): FlavorLogic.State?
	if type(profile) ~= "table" then
		return nil
	end
	local book = profile.flavors
	if type(book) ~= "table" or type(book.found) ~= "table" or type(book.claimed) ~= "table" then
		book = FlavorLogic.reconcileState(book)
		profile.flavors = book
	end
	return book
end

-- Writes the replicated attributes (only writer). Skipped under the Lune test harness.
local function publish()
	if typeof(ReplicatedStorage) ~= "Instance" then
		return
	end
	ReplicatedStorage:SetAttribute(FlavorConfig.Attr.Enabled, enabled)
	ReplicatedStorage:SetAttribute(FlavorConfig.Attr.Luck, liveLuck)
	ReplicatedStorage:SetAttribute(FlavorConfig.Attr.EventLuck, eventLuck)
end

-- Recomputes the shared chance table from the event x admin luck (publishes on change).
local function refreshLuck()
	local event = FlavorLogic.eventLuck(os.time())
	local luck = FlavorLogic.clampLuck(event * adminOdds)
	if luck ~= liveLuck or event ~= eventLuck then
		liveLuck, eventLuck = luck, event
		FlavorLogic.chancesInto(liveChances, liveLuck)
		publish()
	end
end

--------------------------------------------------------------------------------------------------
-- The pay-path hook
--------------------------------------------------------------------------------------------------

--[[
	Rolls `cycles` finished batches of one producer and returns the EXTRA payout their flavours
	earn (TycoonService adds it to the producer's payout). O(1) work whatever `cycles` is; never
	yields, never throws on junk (→ 0), never allocates in steady state.
	@param player Player
	@param worldId string — the runtime's world (trusted: TycoonService)
	@param producerId string
	@param cycles number — whole batches finished this tick
	@param perCycle number — payout of one batch (stats.output / stats.clickPayout)
	@param present boolean — the player is in that world (pops / glow / reveal / quest credit)
	@return number — bonus (>= 0, finite)
	Example: amount += FlavorService.batch(rt.player, rt.worldId, producerId, cycles, stats.output, rt.present)
]]
function FlavorService.batch(
	player: Player,
	worldId: string,
	producerId: string,
	cycles: number,
	perCycle: number,
	present: boolean
): number
	if not started or not enabled then
		return 0
	end
	if type(cycles) ~= "number" or cycles < 1 or cycles ~= cycles or cycles == math.huge then
		return 0
	end
	if type(perCycle) ~= "number" or perCycle <= 0 or perCycle ~= perCycle or perCycle == math.huge then
		return 0
	end
	local state = stateOf(player)
	if state == nil then
		return 0
	end
	local special = FlavorLogic.rollInto(scratch, state.rng, cycles, liveChances)
	local forced = state.forced
	if forced ~= nil and present then
		-- Admin QA: one batch of this tick becomes the forced flavour (a Plain one when there is
		-- one, else the weakest special one is upgraded) — the whole pipeline runs for real.
		state.forced = nil
		if special >= math.floor(cycles) then
			for rank = 1, COUNT do
				if scratch[rank] > 0 then
					scratch[rank] -= 1
					special -= 1
					break
				end
			end
		end
		scratch[forced] += 1
		special += 1
	end
	if special <= 0 then
		return 0
	end
	local bonus = perCycle * FlavorLogic.bonusCycles(scratch)
	if bonus ~= bonus or bonus < 0 or bonus == math.huge then
		bonus = 0
	end
	-- Buffer the counts for the flush (discoveries, analytics).
	local pending = state.pending[worldId]
	if pending == nil then
		pending = { counts = table.create(COUNT, 0), bonus = 0, any = false }
		state.pending[worldId] = pending
	end
	for rank = 1, COUNT do
		pending.counts[rank] += scratch[rank]
	end
	pending.bonus += bonus
	pending.any = true
	-- The producer's best flavour since the last flush (one pop / glow / reveal per producer).
	local best = FlavorLogic.bestRank(scratch)
	local highlight = state.highlights[producerId]
	if highlight == nil then
		highlight = { worldId = worldId, rank = 0, count = 0, present = false, perCycle = 0, sentAt = -math.huge }
		state.highlights[producerId] = highlight
	end
	highlight.worldId = worldId
	highlight.rank = math.max(highlight.rank, best)
	highlight.count += special
	highlight.present = present
	highlight.perCycle = perCycle
	state.hasHighlights = true
	if present then
		state.creditEarned += special
	end
	return bonus
end

--------------------------------------------------------------------------------------------------
-- Flush
--------------------------------------------------------------------------------------------------

-- A Rainbow+ glow on the producer's anchor for every player in that world (per-producer cooldown).
local function glow(
	player: Player,
	state: PlayerState,
	worldId: string,
	producerId: string,
	def: FlavorConfig.FlavorDef,
	now: number
): BasePart?
	local plotIndex = PlotService.getPlotIndex(player)
	if plotIndex == nil then
		return nil
	end
	local ok, anchor = pcall(function(): BasePart?
		return PlotBuilder.world(worldId).getProducerAnchor(plotIndex, producerId)
	end)
	if not ok or anchor == nil then
		return nil
	end
	local last = state.glowAt[producerId]
	if last ~= nil and now - last < FlavorConfig.GlowCooldown then
		return anchor
	end
	state.glowAt[producerId] = now
	for _, other in Players:GetPlayers() do
		if currentWorldOf(other) == worldId then
			Remotes.fireUnreliableClient("FlavorGlow", other, { anchor = anchor, flavor = def.id })
		end
	end
	return anchor
end

-- Sends one player's producer highlights (pops / glows / reveals) and resets them. Plain-tier
-- pops (Sprinkle / Glitter) of one producer go out at most every PopSendSeconds (they keep
-- accumulating meanwhile, best flavour + count); Rainbow+ always go out at once.
local function flushHighlights(player: Player, state: PlayerState, now: number)
	if not state.hasHighlights then
		return
	end
	state.hasHighlights = false
	for producerId, highlight in state.highlights do
		if highlight.count <= 0 then
			continue
		end
		local def = SPECIAL[highlight.rank]
		if
			def ~= nil
			and highlight.present
			and not def.glow
			and now - highlight.sentAt < FlavorConfig.PopSendSeconds
		then
			state.hasHighlights = true -- still pending: flushed on a later pass
			continue
		end
		if def ~= nil and highlight.present then
			highlight.sentAt = now
			Remotes.fireUnreliableClient("FlavorPop", player, {
				producerId = producerId,
				flavor = def.id,
				count = highlight.count,
				-- Owner R120 feed pills: the best Lucky Nuke's own payout + its world currency.
				amount = highlight.perCycle * def.mult,
				worldId = highlight.worldId,
			})
			local anchor: BasePart? = nil
			if def.glow then
				anchor = glow(player, state, highlight.worldId, producerId, def, now)
			end
			if def.reveal then
				local oneIn = FlavorLogic.oneIn(def.rank, liveLuck)
				Remotes.fireClient("FlavorHighlight", player, {
					producerId = producerId,
					flavor = def.id,
					worldId = highlight.worldId,
					oneIn = oneIn,
					mult = def.mult,
					amount = highlight.perCycle * def.mult,
				})
				track(state, "flavorReveal")
				BigPop.announce(player, {
					kind = "batch",
					id = def.id,
					label = string.upper(def.name), -- clients: FlavorConfig.bigPopLine → "Alex got GALAXY nukes!"
					oneIn = oneIn,
					score = 40 + def.rank * 5,
					at = if anchor ~= nil then anchor.Position else BigPop.positionOf(player),
				})
			end
		end
		highlight.count = 0
		highlight.rank = 0
	end
end

-- Moves one player's buffered counts into their Book; toasts + pushes new discoveries.
local function flushCounts(player: Player, state: PlayerState, now: number)
	local profile = PlayerDataService.getProfile(player)
	local book = bookOf(profile)
	local discovered: { { worldId: string, def: FlavorConfig.FlavorDef } }? = nil
	for worldId, pending in state.pending do
		if not pending.any then
			continue
		end
		pending.any = false
		for rank = 1, COUNT do
			local hits = pending.counts[rank]
			if hits > 0 then
				pending.counts[rank] = 0
				local def = SPECIAL[rank]
				track(state, `flavor:{def.id}:{worldId}`, hits)
				if book ~= nil and FlavorLogic.addFound(book, worldId, rank, hits) then
					discovered = discovered or {}
					table.insert(discovered :: any, { worldId = worldId, def = def })
				end
				state.dirtyCounts = state.dirtyCounts or book ~= nil
			end
		end
		if pending.bonus > 0 then
			track(state, `flavorBonus:{worldId}`, pending.bonus)
			pending.bonus = 0
		end
	end
	if discovered ~= nil then
		for _, found in discovered do
			trackNow(player, `flavorFind:{found.def.id}:{found.worldId}`)
			PlayerDataService.notify(
				player,
				string.format(
					FlavorConfig.Text.DiscoveryToast,
					string.upper(found.def.name),
					worldName(found.worldId),
					found.def.gems
				),
				"reward",
				"Gems"
			)
		end
		PlayerDataService.markChanged(player, true, FLAVOR_FIELDS)
		state.dirtyCounts = false
		state.pushAt = now
	elseif state.dirtyCounts and now - state.pushAt >= FlavorConfig.PushSeconds then
		PlayerDataService.markChanged(player, false, FLAVOR_FIELDS)
		state.dirtyCounts = false
		state.pushAt = now
	end
end

-- The Quests "flavor" stat: special batches in the player's world, through the token bucket.
local function flushCredit(player: Player, state: PlayerState, now: number)
	local last = state.creditAt
	local credit, bank = FlavorLogic.creditStep(
		state.creditBank,
		if last ~= nil then now - last else 0,
		FlavorConfig.QuestCredit.PerMinute,
		FlavorConfig.QuestCredit.Burst,
		state.creditEarned
	)
	state.creditBank, state.creditAt, state.creditEarned = bank, now, 0
	if credit > 0 then
		ProgressEvents.progress(player, "flavor", credit)
	end
end

-- Sends every batched analytics key of one player.
local function flushAnalytics(player: Player, state: PlayerState)
	if next(state.analytics) == nil then
		return
	end
	local batch = state.analytics
	state.analytics = {}
	for key, amount in batch do
		trackNow(player, key, amount)
	end
end

local flushAccumulator = 0
local luckAccumulator = 0
local analyticsAccumulator = 0

-- The system's one Heartbeat: flush passes, analytics batches, luck refreshes, Big Pop steps.
local function onHeartbeat(dt: number)
	flushAccumulator += dt
	luckAccumulator += dt
	analyticsAccumulator += dt
	if luckAccumulator >= FlavorConfig.LuckRefreshSeconds then
		luckAccumulator = 0
		refreshLuck()
	end
	if flushAccumulator >= FlavorConfig.FlushSeconds then
		flushAccumulator = 0
		local now = os.clock()
		for player, state in states do
			if player.Parent ~= Players then
				continue
			end
			flushHighlights(player, state, now)
			flushCounts(player, state, now)
			flushCredit(player, state, now)
		end
		BigPop.step(now)
	end
	if analyticsAccumulator >= FlavorConfig.AnalyticsFlushSeconds then
		analyticsAccumulator = 0
		for player, state in states do
			flushAnalytics(player, state)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Flavour Book claims
--------------------------------------------------------------------------------------------------

-- Counts a refused claim (tycoon "flavorRefused:<reason>").
local function refused(player: Player, reason: string)
	trackNow(player, `flavorRefused:{reason}`)
end

--[[
	FlavorClaim(key | "all") handler. See the module header for the order of checks.
	@return number — gems paid (0 on any refusal)
]]
function FlavorService.handleClaim(player: Player, rawKey: unknown): number
	if not enabled then
		refused(player, "off")
		return 0
	end
	if not claimLimiter:Allow(player) then
		refused(player, "rate")
		return 0
	end
	if type(rawKey) ~= "string" or #(rawKey :: string) > 40 then
		refused(player, "bad")
		return 0
	end
	local profile = PlayerDataService.getProfile(player)
	local book = bookOf(profile)
	if book == nil or not PlayerDataService.canMutate(player) then
		refused(player, "save")
		PlayerDataService.notify(player, "Your save is still loading - try again in a moment.", "info", "Pets")
		return 0
	end
	local all = rawKey == "all"
	local keys = if all then FlavorLogic.claimable(book) else { rawKey :: string }
	local gems = 0
	local names: { string } = {}
	for _, key in keys do
		local code, def, claimedKey = FlavorLogic.claim(book, key)
		if code == "ok" and def ~= nil and claimedKey ~= nil then
			gems += def.gems
			table.insert(names, def.name)
			local worldId = string.match(claimedKey, "^([^:]+):") or WorldsConfig.MAIN
			trackNow(player, `flavorClaim:{def.id}:{worldId}`)
		elseif not all then
			refused(player, code)
			if code == "claimed" then
				PlayerDataService.notify(player, FlavorConfig.Text.ClaimedAlready, "info", "Gems")
			elseif code == "locked" then
				PlayerDataService.notify(player, FlavorConfig.Text.ClaimLocked, "info", "Gems")
			end
		end
	end
	if gems <= 0 then
		if all then
			refused(player, "none")
		end
		return 0
	end
	-- Same step (no yield since the claim marks): pay + mark the Book changed + save soon.
	PlayerDataService.grantGems(player, gems, FlavorConfig.Reason)
	PlayerDataService.markChanged(player, true, FLAVOR_FIELDS)
	trackNow(player, "flavorGems", gems)
	local what = if #names == 1 then names[1] else `{#names} flavours`
	PlayerDataService.notify(player, string.format(FlavorConfig.Text.ClaimToast, gems, what), "reward", "Gems")
	return gems
end

--------------------------------------------------------------------------------------------------
-- Big Pop triggers (hatches + rebirths)
--------------------------------------------------------------------------------------------------

-- The "1 in N" of a pet in an egg (0 when unknown).
local function hatchOdds(eggId: string, petId: string): number
	local egg = EggConfig.get(eggId)
	if egg == nil then
		return 0
	end
	for _, slot in egg.slots do
		if slot.pet == petId and slot.bp > 0 then
			return math.floor(EggConfig.TotalBp / slot.bp + 0.5)
		end
	end
	return 0
end

-- A hatch committed (PetService.Hatched): Mythic+ → a Big Pop after the hatch reveal.
local function onHatched(player: Player, eggId: string, petId: string)
	if not enabled then
		return -- the feature is off: no Big Pops at all
	end
	local pet = PetConfig.get(petId)
	if pet == nil then
		return
	end
	local rank = PetConfig.rank(pet.rarity)
	if rank < FlavorConfig.BigPop.MinHatchRank then
		return
	end
	local oneIn = hatchOdds(eggId, petId)
	task.delay(FlavorConfig.BigPop.HatchDelay, function()
		if player.Parent ~= Players then
			return
		end
		if
			BigPop.announce(player, {
				kind = "hatch",
				id = pet.rarity,
				label = `{string.upper(pet.rarity)} {pet.name}`,
				oneIn = oneIn,
				score = 40 + rank,
				at = BigPop.positionOf(player),
			})
		then
			trackNow(player, "bigPop:hatch")
		end
	end)
end

-- A rebirth committed (any world): a Big Pop after the rebirth flash.
local function onRebirth(player: Player, worldId: string, count: number)
	if not enabled then
		return
	end
	task.delay(FlavorConfig.BigPop.RebirthDelay, function()
		if player.Parent ~= Players then
			return
		end
		local label = if worldId == WorldsConfig.MAIN
			then `REBIRTH #{count}`
			else `{string.upper(worldName(worldId))} REBIRTH #{count}`
		if
			BigPop.announce(player, {
				kind = "rebirth",
				id = worldId,
				label = label,
				oneIn = 0,
				score = 30,
				at = BigPop.positionOf(player),
			})
		then
			trackNow(player, "bigPop:rebirth")
		end
	end)
end

-- Requires a Server/Services module by name under pcall (nil when missing / failing).
local function lazyService(name: string): any
	local server = ServerScriptService:FindFirstChild("Server")
	local services = if server ~= nil then server:FindFirstChild("Services") else nil
	local module = if services ~= nil then services:FindFirstChild(name) else nil
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, loaded = pcall(require, module)
	return if ok and type(loaded) == "table" then loaded else nil
end

-- Same for a Server/Tycoon module (RebirthService lives there).
local function lazyTycoon(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, loaded = pcall(require, module)
	return if ok and type(loaded) == "table" then loaded else nil
end

-- Hooks the hatch + rebirth signals (guarded: a missing service just means no Big Pop for it).
local function connectTriggers()
	local PetService = lazyService("PetService")
	if PetService ~= nil and type(PetService.Hatched) == "table" then
		PetService.Hatched:Connect(onHatched)
	else
		warn("[FlavorService] PetService.Hatched unavailable; no Big Pop for hatches")
	end
	local RebirthService = lazyTycoon("RebirthService")
	if RebirthService ~= nil and type(RebirthService.Rebirthed) == "table" then
		RebirthService.Rebirthed:Connect(function(player: Player, count: number)
			onRebirth(player, WorldsConfig.MAIN, count)
		end)
		if type(RebirthService.WorldRebirthed) == "table" then
			RebirthService.WorldRebirthed:Connect(onRebirth)
		end
	else
		warn("[FlavorService] RebirthService signals unavailable; no Big Pop for rebirths")
	end
end

--------------------------------------------------------------------------------------------------
-- Admin seams (Server/Tycoon/FlavorAdmin)
--------------------------------------------------------------------------------------------------

--[[ This server's live flavour settings (admin panel result lines). ]]
function FlavorService.settings(): { enabled: boolean, odds: number, bigPop: boolean, luck: number, eventLuck: number }
	return { enabled = enabled, odds = adminOdds, bigPop = BigPop.isEnabled(), luck = liveLuck, eventLuck = eventLuck }
end

--[[
	Sets this server's kill switch, admin odds multiplier and Big Pop switch.
	@param on boolean — flavours roll
	@param odds number — multiplier on every special chance (clamped to [MinLuck, MaxLuck])
	@param bigPop boolean — Big Pop broadcasts
	@return (ok, message)
]]
function FlavorService.setSettings(on: boolean, odds: number, bigPop: boolean): (boolean, string)
	enabled = on == true
	adminOdds = FlavorLogic.clampLuck(odds)
	BigPop.setEnabled(bigPop == true)
	refreshLuck()
	publish()
	trackNow(nil, "flavorAdmin:settings")
	return true,
		`Flavours {if enabled then "ON" else "OFF"}, odds x{adminOdds} (live luck x{liveLuck}), Big Pop {if BigPop.isEnabled()
			then "ON"
			else "OFF"} (this server)`
end

--[[
	Forces the target's next finished batch (in the world they are in) to `flavorId` — QA for the
	whole pipeline (bonus, pop, glow, reveal, Big Pop, discovery).
	@return (ok, message)
]]
function FlavorService.adminForce(player: Player, flavorId: unknown): (boolean, string)
	local def = FlavorConfig.byId(flavorId)
	if def == nil or def.rank < 1 then
		return false, "Pick a special flavour"
	end
	local state = stateOf(player)
	if state == nil then
		return false, "Player is not in the game"
	end
	if not enabled then
		return false, "Flavours are switched OFF on this server"
	end
	state.forced = def.rank
	trackNow(player, "flavorAdmin:grant")
	return true, `{player.Name}'s next batch will be {def.name}`
end

--[[ Clears the target's Flavour Book (found + claimed). Studio-only command (re-claimable gems). ]]
function FlavorService.adminReset(player: Player): (boolean, string)
	local profile = PlayerDataService.getProfile(player)
	if type(profile) ~= "table" then
		return false, "Profile not loaded"
	end
	(profile :: any).flavors = FlavorLogic.newState()
	PlayerDataService.markChanged(player, true, FLAVOR_FIELDS)
	trackNow(player, "flavorAdmin:reset")
	return true, `{player.Name}'s Flavour Book was cleared`
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

--[[
	FlavorTipSeen() handler (owner R112): marks the one-time Lucky Nukes tip card as dismissed so it
	never shows again (profile.flavors.tip). No arguments are read; rate-limited; idempotent.
	@return boolean — true when the flag was newly set
]]
function FlavorService.handleTipSeen(player: Player): boolean
	if not claimLimiter:Allow(player) then
		return false
	end
	local book = bookOf(PlayerDataService.getProfile(player))
	if book == nil or book.tip then
		return false
	end
	book.tip = true
	PlayerDataService.markChanged(player, false, FLAVOR_FIELDS)
	trackNow(player, "flavorTip")
	return true
end

function FlavorService.Init()
	Remotes.onServerEvent("FlavorClaim", function(player: Player, rawKey: unknown)
		FlavorService.handleClaim(player, rawKey)
	end)
	Remotes.onServerEvent("FlavorTipSeen", function(player: Player)
		FlavorService.handleTipSeen(player)
	end)
end

function FlavorService.Start()
	if started then
		return
	end
	started = true
	refreshLuck()
	publish()
	TycoonAnalytics.call("registerIds", "flavorId", FlavorConfig.isSpecial)
	connectTriggers()
	FlavorAdmin.install(FlavorService)
	Players.PlayerRemoving:Connect(function(player: Player)
		local state = states[player]
		if state ~= nil then
			flushAnalytics(player, state)
		end
		states[player] = nil
		claimLimiter:Forget(player)
		BigPop.forget(player)
	end)
	RunService.Heartbeat:Connect(onHeartbeat)
end

return FlavorService
