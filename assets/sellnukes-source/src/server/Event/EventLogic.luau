--!strict
--[[
	EventLogic — the pure (engine-free) decisions of the Harvest Feast event (spec §10,
	docs/event.md). No Instances, no clocks, no services: every function takes the facts it needs,
	so tests/event-logic.luau pins every rule under Lune.

	What it decides:
		ensureSeason(event, seasonId)        resets a previous season's acorns / stickers / redeemed
		                                     (decor is kept forever) — returns true when it changed
		grantStarters(event, seasonId)       owner R97: the free starter stickers, once per season
		                                     (tops a sheet up to EventConfig.Starter.Count; never
		                                     removes anything) — returns the indices granted
		rollSticker(stickers, r)             a sticker index by rarity weight with DUPE PROTECTION
		                                     (owned stickers weigh EventConfig.Rewards.DupeWeightFactor)
		rollReward(stickers, lure, rng, paidRandomAllowed?)
		                                     one catch: acorns, maybe a sticker roll, dupe consolation;
		                                     a PAID lure turkey of a player whose region restricts
		                                     paid random items gets a fixed reward (no roll)
		applyReward(event, reward)           writes a rolled reward into profile.event (clamped)
		collectCheck(facts)                  may this player catch this turkey now? (reason codes)
		redeemCheck(event, facts)            "ok" | "incomplete" | "already" | "closed"
		shopCheck(item, event, facts)        may this player buy this shop row now?
		planSpawns(now, facts, state, rng)   the 1 Hz spawn scheduler (hub, plots, lures; caps)
		minDistance(compiled, t, pos, lags)  smallest distance from `pos` to the turkey over the
		                                     server's lag samples (catch validation)

	The live state (turkeys, timers, profiles) belongs to Services/EventService and
	Event/TurkeySpawner; they pass plain tables in and apply what comes back.

	Example:
		local event = profile.event
		EventLogic.ensureSeason(event, EventConfig.Season.id)
		local reward = EventLogic.rollReward(event.stickers, false, function() return rng:NextNumber() end)
		EventLogic.applyReward(event, reward) --> event.acorns grew, maybe a new sticker
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)

-- The profile.event record (ProfileLogic schema + the fields the lead adds: decor, turkeys, lures).
-- Optional fields are read nil-safely until the profile schema carries them.
export type EventRecord = {
	season: string,
	acorns: number,
	stickers: { [number]: true },
	redeemed: boolean,
	decor: { [string]: true }?,
	turkeys: number?,
	lures: number?,
	-- Owner R97: the season id whose free starter stickers this record already got ("" / nil =
	-- never). Compared with the current season, so it needs no reset at a season rollover.
	starterSeason: string?,
}

-- One rolled catch.
export type Reward = {
	acorns: number, -- acorns for the turkey itself
	sticker: number, -- sticker index rolled (0 = no sticker roll)
	dup: boolean, -- the rolled sticker was already owned
	bonus: number, -- dupe consolation acorns (0 unless dup)
}

export type CollectReason = "ok" | "missing" | "inactive" | "notOwner" | "already" | "cooldown" | "far" | "noCharacter"

-- What EventService knows when a catch request arrives.
export type CollectFacts = {
	exists: boolean, -- the turkey id is alive on this server
	active: boolean, -- the event runs (window or admin force)
	lure: boolean, -- the turkey is a paid Turkey Lure (catchable even if the event just ended)
	owner: number, -- 0 = anyone; otherwise the only UserId allowed
	userId: number,
	already: boolean, -- this player already caught this turkey
	sinceLast: number, -- seconds since this player's previous catch (math.huge = never)
	hasCharacter: boolean,
	distance: number, -- smallest root → turkey distance over the lag samples
}

export type RedeemReason = "ok" | "incomplete" | "already" | "closed"

export type ShopReason = "ok" | "inactive" | "unknown" | "owned" | "poor" | "unsupported"

-- Scheduler facts: one row per present player with a loaded profile.
export type PlayerFacts = {
	userId: number,
	plotIndex: number?, -- nil = no plot (no plot turkeys)
	plotAlive: number, -- natural turkeys alive on this player's plot
	lurePending: number, -- lures bought and not yet caught
	lureAlive: number, -- lure turkeys alive for this player
}

export type SpawnFacts = {
	active: boolean,
	totalAlive: number, -- every turkey alive (natural + lures)
	naturalAlive: number,
	hubAlive: number,
	players: { PlayerFacts },
}

-- Scheduler memory between ticks (owned by TurkeySpawner; created with newSpawnState).
export type SpawnState = {
	nextHubAt: number, -- 0 = not scheduled yet (first spawn after FirstDelay)
	plotNextAt: { [number]: number }, -- userId -> next plot spawn time
}

export type SpawnOrder = { zone: EventConfig.Zone, userId: number?, lure: boolean }

local EventLogic = {}

-- True for a finite number.
local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- ─── Season ───────────────────────────────────────────────────────────────────────────────────

--[[
	Makes `event` belong to `seasonId`. A record from another season (or a brand-new "" record) is
	reset: acorns 0, no stickers, not redeemed, turkey counter 0, no pending lures. Decorations are
	permanent purchases and are kept.
	@return true when the record changed (the caller marks "event" changed)
	Example: EventLogic.ensureSeason(profile.event, "harvest2026")
]]
function EventLogic.ensureSeason(event: EventRecord, seasonId: string): boolean
	if event.season == seasonId then
		return false
	end
	event.season = seasonId
	event.acorns = 0
	event.stickers = {}
	event.redeemed = false
	if event.turkeys ~= nil then
		event.turkeys = 0
	end
	-- Lures were bought with Robux: a pending lure carries over to the next season (never lost).
	return true
end

--[[
	Owner R97 — the free STARTER stickers ("start people off with like 3-4 filled in"). Once per
	season (idempotent through `event.starterSeason`) a sheet holding fewer than
	EventConfig.Starter.Count stickers is topped up to that count with the commonest stickers it
	does not own yet (EventConfig.StarterStickers, in order): a brand-new sheet gets all 3, a sheet
	with 1 gets 2 more, a sheet with 3+ gets none. Only ever ADDS stickers; the season stamp is
	written even when nothing was needed, so a later loss of stickers (admin reset) never re-grants
	in the same season. The record must already belong to `seasonId` (call ensureSeason first);
	otherwise nothing happens, so a stale record is never stamped with the wrong season.
	@param event profile.event (mutated)
	@param seasonId the current season id (EventService currentSeasonId())
	@return the sticker indices granted now (empty when none / already granted / wrong season)
	Example:
		EventLogic.ensureSeason(profile.event, "harvest2026")
		local granted = EventLogic.grantStarters(profile.event, "harvest2026") --> { 1, 2, 3 }
		EventLogic.grantStarters(profile.event, "harvest2026") --> {} (already this season)
]]
function EventLogic.grantStarters(event: EventRecord, seasonId: string): { number }
	local granted: { number } = {}
	if event.season ~= seasonId or event.starterSeason == seasonId then
		return granted
	end
	if type(event.stickers) ~= "table" then
		event.stickers = {}
	end
	local need = EventConfig.Starter.Count - EventConfig.countStickers(event.stickers)
	for _, index in EventConfig.StarterStickers do
		if need <= 0 then
			break
		end
		if event.stickers[index] ~= true then
			event.stickers[index] = true
			table.insert(granted, index)
			need -= 1
		end
	end
	event.starterSeason = seasonId
	return granted
end

--[[ Whole acorns the record holds (0 for junk). ]]
function EventLogic.acorns(event: EventRecord): number
	local value = event.acorns
	return if finite(value) and value > 0 then math.floor(value) else 0
end

--[[
	Adds whole acorns, clamped to EventConfig.Rewards.MaxAcorns.
	@return acorns actually added
]]
function EventLogic.addAcorns(event: EventRecord, amount: number): number
	if not finite(amount) or amount < 1 then
		return 0
	end
	local before = EventLogic.acorns(event)
	local after = math.min(before + math.floor(amount), EventConfig.Rewards.MaxAcorns)
	event.acorns = after
	return after - before
end

--[[
	Spends whole acorns atomically (only when the balance covers them).
	@return true when spent
]]
function EventLogic.spendAcorns(event: EventRecord, amount: number): boolean
	if not finite(amount) or amount < 1 or amount % 1 ~= 0 then
		return false
	end
	local balance = EventLogic.acorns(event)
	if balance < amount then
		return false
	end
	event.acorns = balance - amount
	return true
end

-- ─── Rolls ────────────────────────────────────────────────────────────────────────────────────

--[[
	The roll weight of every sticker for a player who owns `stickers`: rarity weight × (owned →
	DupeWeightFactor). Exposed for the tests and the sheet's odds hint.
	@return weights by sheet index, and their total
]]
function EventLogic.stickerWeights(stickers: { [number]: true }): ({ number }, number)
	local weights: { number } = {}
	local total = 0
	local factor = EventConfig.Rewards.DupeWeightFactor
	for _, def in EventConfig.Stickers do
		local weight = EventConfig.RarityWeight[def.rarity]
		if stickers[def.index] then
			weight *= factor
		end
		weights[def.index] = weight
		total += weight
	end
	return weights, total
end

--[[
	Picks a sticker by weight with dupe protection.
	@param stickers the player's owned set { [index] = true }
	@param r a uniform random number in [0, 1)
	@return sticker index (1..StickerCount)
	Example: EventLogic.rollSticker({}, 0) --> 1
]]
function EventLogic.rollSticker(stickers: { [number]: true }, r: number): number
	local weights, total = EventLogic.stickerWeights(stickers)
	local target = math.clamp(if finite(r) then r else 0, 0, 0.999999999) * total
	local acc = 0
	for index, weight in weights do
		acc += weight
		if target < acc then
			return index
		end
	end
	return #weights
end

--[[
	Rolls one catch.
	@param stickers the player's owned set (read only)
	@param lure true for a paid Turkey Lure turkey (x LureMultiplier acorns, guaranteed roll)
	@param rng returns uniform numbers in [0, 1)
	@param paidRandomAllowed for a LURE turkey: the catcher's PolicyService answer allows paid
	       random items (the lure was bought with Robux, so its sticker roll is a paid random item).
	       false / nil → the FIXED lure reward instead: AcornsMax × LureMultiplier acorns, no
	       sticker, no roll (the caller passes false for restricted OR unknown — fail closed).
	       Natural turkeys are free and ignore it.
	@return Reward
]]
function EventLogic.rollReward(
	stickers: { [number]: true },
	lure: boolean,
	rng: () -> number,
	paidRandomAllowed: boolean?
): Reward
	local cfg = EventConfig.Rewards
	if lure and paidRandomAllowed ~= true then
		return { acorns = cfg.AcornsMax * cfg.LureMultiplier, sticker = 0, dup = false, bonus = 0 }
	end
	local span = cfg.AcornsMax - cfg.AcornsMin + 1
	local acorns = cfg.AcornsMin + math.min(span - 1, math.floor(rng() * span))
	if lure then
		acorns *= cfg.LureMultiplier
	end
	local chance = if lure then cfg.LureStickerChance else cfg.StickerChance
	local sticker = 0
	local dup = false
	if rng() < chance then
		sticker = EventLogic.rollSticker(stickers, rng())
		dup = stickers[sticker] == true
	end
	return { acorns = acorns, sticker = sticker, dup = dup, bonus = if dup then cfg.DupeAcorns else 0 }
end

--[[
	Writes a rolled reward into the record: acorns (+ dupe bonus), the new sticker, the turkey
	counter (when the schema has it).
	@return acorns actually added
]]
function EventLogic.applyReward(event: EventRecord, reward: Reward): number
	local added = EventLogic.addAcorns(event, reward.acorns + reward.bonus)
	if reward.sticker >= 1 and reward.sticker <= EventConfig.StickerCount and not reward.dup then
		event.stickers[reward.sticker] = true
	end
	if event.turkeys ~= nil and finite(event.turkeys) then
		event.turkeys = math.min((event.turkeys :: number) + 1, 1e15)
	end
	return added
end

-- ─── Checks ───────────────────────────────────────────────────────────────────────────────────

--[[
	Whether a catch request is valid. Order matters: cheap identity checks first; the distance
	check last (the caller computes it only when everything else passed).
	@return reason ("ok" when the catch is allowed)
]]
function EventLogic.collectCheck(facts: CollectFacts, range: number): CollectReason
	if not facts.exists then
		return "missing"
	end
	if not facts.active and not facts.lure then
		return "inactive"
	end
	if facts.owner ~= 0 and facts.owner ~= facts.userId then
		return "notOwner"
	end
	if facts.already then
		return "already"
	end
	if facts.sinceLast < EventConfig.Turkey.CollectCooldown then
		return "cooldown"
	end
	if not facts.hasCharacter then
		return "noCharacter"
	end
	if not finite(facts.distance) or facts.distance > range then
		return "far"
	end
	return "ok"
end

--[[
	The server's catch range: what the client offers (TapRange) + the root-lag slack.
]]
function EventLogic.serverRange(): number
	return EventConfig.Turkey.TapRange + EventConfig.Turkey.ServerSlack
end

--[[
	Smallest distance from `position` to the turkey at `t - lag` for every lag sample (the
	server's copy of a character trails the client by the ping, the turkey keeps walking).
	@return studs (math.huge when the turkey is not alive at any sample)
]]
function EventLogic.minDistance(
	compiled: EventConfig.CompiledPath,
	t: number,
	position: Vector3,
	lags: { number }
): number
	local best = math.huge
	for _, lag in lags do
		local pose = EventConfig.pose(compiled, t - lag)
		if pose.alive or lag > 0 then
			-- XZ distance plus a softened height term (stairs / ramps / standing on a pad).
			local delta = position - pose.position
			local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude
			local distance = flat + math.max(0, math.abs(delta.Y) - 6)
			if distance < best then
				best = distance
			end
		end
	end
	return best
end

--[[
	Whether a sheet redeem is allowed (complete sheet, not redeemed yet, window open).
	@param open the event runs, or now < EventConfig.redeemUntil() (the redeem grace)
]]
function EventLogic.redeemCheck(event: EventRecord, open: boolean): RedeemReason
	if event.redeemed then
		return "already"
	end
	if EventConfig.countStickers(event.stickers) < EventConfig.StickerCount then
		return "incomplete"
	end
	if not open then
		return "closed"
	end
	return "ok"
end

--[[
	Whether a shop purchase is allowed (the caller then spends + grants without yielding).
	@param hasDecorField the profile schema carries event.decor (decor purchases need it to persist)
]]
function EventLogic.shopCheck(
	item: EventConfig.ShopItem?,
	event: EventRecord,
	active: boolean,
	hasDecorField: boolean
): ShopReason
	if item == nil then
		return "unknown"
	end
	if not active then
		return "inactive"
	end
	if item.kind == "decor" then
		if not hasDecorField then
			return "unsupported"
		end
		local decor = event.decor
		if decor ~= nil and decor[item.key] then
			return "owned"
		end
	end
	if EventLogic.acorns(event) < item.price then
		return "poor"
	end
	return "ok"
end

-- ─── Spawn scheduler ──────────────────────────────────────────────────────────────────────────

--[[ A fresh scheduler memory. ]]
function EventLogic.newSpawnState(): SpawnState
	return { nextHubAt = 0, plotNextAt = {} }
end

--[[
	The 1 Hz spawn decision. Lures first (paid), then the hub, then plots; every order respects
	the caps. Mutates `state` (timers) and returns the turkeys to spawn now.
	Rules:
		- lures: a player with lurePending > 0 and no lure turkey alive gets one (even when the
		  event is off: it was paid for), while totalAlive < MaxAliveWithLures;
		- natural turkeys only while `active`, and only while naturalAlive < MaxAlive;
		- hub: one more while hubAlive < Hub.Max, every Hub.IntervalMin..Max seconds (first after
		  Hub.FirstDelay), and only when at least one player is present;
		- plots: each present player with a plot gets one while plotAlive < Plot.Max, every
		  Plot.IntervalMin..Max seconds (first after Plot.FirstDelay);
		- timers of players who left are dropped.
	@param rng returns uniform numbers in [0, 1)
	@return { SpawnOrder }
]]
function EventLogic.planSpawns(now: number, facts: SpawnFacts, state: SpawnState, rng: () -> number): { SpawnOrder }
	local cfg = EventConfig.Turkey
	local orders: { SpawnOrder } = {}
	local total = facts.totalAlive
	local natural = facts.naturalAlive
	local present: { [number]: boolean } = {}

	local function interval(min: number, max: number): number
		return min + (max - min) * math.clamp(rng(), 0, 1)
	end

	for _, row in facts.players do
		present[row.userId] = true
		if row.lurePending > 0 and row.lureAlive == 0 and total < cfg.MaxAliveWithLures then
			local order: SpawnOrder = { zone = "plot", userId = row.userId, lure = true }
			table.insert(orders, order)
			total += 1
		end
	end

	if facts.active and #facts.players > 0 then
		if state.nextHubAt == 0 then
			state.nextHubAt = now + cfg.Hub.FirstDelay
		elseif
			now >= state.nextHubAt
			and facts.hubAlive < cfg.Hub.Max
			and natural < cfg.MaxAlive
			and total < cfg.MaxAliveWithLures
		then
			local order: SpawnOrder = { zone = "hub", userId = nil, lure = false }
			table.insert(orders, order)
			natural += 1
			total += 1
			state.nextHubAt = now + interval(cfg.Hub.IntervalMin, cfg.Hub.IntervalMax)
		end
		for _, row in facts.players do
			if row.plotIndex == nil then
				continue
			end
			local nextAt = state.plotNextAt[row.userId]
			if nextAt == nil then
				state.plotNextAt[row.userId] = now + cfg.Plot.FirstDelay
			elseif
				now >= nextAt
				and row.plotAlive < cfg.Plot.Max
				and natural < cfg.MaxAlive
				and total < cfg.MaxAliveWithLures
			then
				local order: SpawnOrder = { zone = "plot", userId = row.userId, lure = false }
				table.insert(orders, order)
				natural += 1
				total += 1
				state.plotNextAt[row.userId] = now + interval(cfg.Plot.IntervalMin, cfg.Plot.IntervalMax)
			end
		end
	else
		-- Off: the next activation starts the hub / plot clocks fresh.
		state.nextHubAt = 0
		table.clear(state.plotNextAt)
	end

	for userId in state.plotNextAt do
		if not present[userId] then
			state.plotNextAt[userId] = nil
		end
	end
	return orders
end

-- ─── Wander paths ─────────────────────────────────────────────────────────────────────────────

--[[
	Plot-local XZ wander points along the plot road (x within ±RoadHalfWidth), centred on a random
	spot between StartZ and the end of the player's unlocked rows, so turkeys appear where the
	player is building. Ground Y is resolved by the caller (raycast) after placing in world space.
	@param area the player's current area (profile.tycoon.area, 1..10)
	@param plotLength WorldLayout.PlotLength
	@param rowLength WorldLayout.RowLength
	@return plot-local points (y = 0)
]]
function EventLogic.plotWanderPoints(
	area: number,
	plotLength: number,
	rowLength: number,
	rng: () -> number
): { Vector3 }
	local cfg = EventConfig.Turkey.Plot
	local rows = math.max(1, math.ceil(math.clamp(area, 1, 64) / 2))
	local maxZ = math.clamp(rows * rowLength - 8, cfg.StartZ + 1, plotLength - 8)
	local centre = cfg.StartZ + (maxZ - cfg.StartZ) * rng()
	local points: { Vector3 } = {}
	for _ = 1, EventConfig.Turkey.Waypoints do
		local x = (rng() * 2 - 1) * cfg.RoadHalfWidth
		local z = math.clamp(centre + (rng() * 2 - 1) * cfg.Spread, cfg.StartZ, maxZ)
		table.insert(points, Vector3.new(x, 0, z))
	end
	return points
end

--[[
	Hub wander points: a small loop around ONE randomly chosen HubLayout turkey spawn point (they
	sit in the event square and on the hub's flower beds, far apart, so a loop never crosses the
	whole hub), or — without anchors — a ring around the event square.
	@param anchors HubLayout.anchors.TurkeySpawnPoints positions (world) or {}
	@param square the event square's centre (world)
	@return world points (y from the anchor; the caller snaps them to the ground)
]]
function EventLogic.hubWanderPoints(anchors: { Vector3 }, square: Vector3, rng: () -> number): { Vector3 }
	local count = EventConfig.Turkey.Waypoints
	local centre = square
	local radius = EventConfig.Turkey.Hub.WanderRadius
	if #anchors > 0 then
		centre = anchors[1 + math.min(#anchors - 1, math.floor(rng() * #anchors))]
		radius = EventConfig.Turkey.Hub.AnchorWander
	end
	local points: { Vector3 } = {}
	local start = rng() * math.pi * 2
	for index = 1, count do
		local angle = start + (index - 1) * (math.pi * 2 / count) + (rng() - 0.5) * 0.6
		local r = radius * (0.45 + 0.55 * rng())
		table.insert(points, centre + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r))
	end
	return points
end

return table.freeze(EventLogic)
