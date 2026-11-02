--!strict
--[[
	EventService — HARVEST FEAST, the SellNukes Thanksgiving event (spec §10, owner R1,
	docs/event.md). Server-authoritative; clients send intents only.

	Purpose:
		- Window: on 2026-11-01 → 2026-12-01 UTC (EventConfig.Season), or forced on / off by the owner
		  from the admin panel (per server). The state is published as ReplicatedStorage attributes
		  (EventConfig.Attributes) for the HUD Event button, the screens and B9's Harvest Egg stand.
		- GOLDEN TURKEYS: one 1 Hz scheduler (EventLogic.planSpawns) spawns capped turkeys in the hub
		  and on every present player's plot (Event/TurkeySpawner: server keeps only the path; clients
		  render + animate along it). `EventCollect(turkeyId)` is validated: rate limit, id, event
		  on (or a paid lure), lure owner, once per player per turkey, per-player cooldown, alive
		  character, and the server-side distance from the character to the turkey's pose now and a
		  moment ago (EventLogic.minDistance). A catch pays acorns and maybe a Feast Sticker
		  (rarity weights + dupe protection; a dupe pays bonus acorns).
		- STICKER SHEET: 20 stickers → `EventRedeemSheet()` grants B9's Gobble Bomb pet exactly once
		  per season (in-flight guard + `event.redeemed`, set only after PetService.grantPet said ok).
		- EVENT SHOP: `EventShopBuy(itemKey)` spends acorns on plot decorations (built on the plot with
		  the LEGO build-in, kept forever) or personal boosts (BoostService). Harvest Egg hatches are
		  B9's HatchEgg flow, paid through `EventService.trySpendAcorns`.
		- PRODUCTS: "Acorns" (+acorns) and "TurkeyLure" (a guaranteed-sticker, 3x-acorn turkey that
		  spawns on the buyer's plot and waits for them; pending lures persist in event.lures).
		  PAID RANDOM ITEM (the guaranteed sticker roll): MonetizationConfig flags TurkeyLure
		  paidRandom, so the prompt is refused for a restricted / unknown policy (fail closed; a
		  KNOWN restricted refusal is counted here as event "lure:refused:policy"). A lure that
		  still reaches a restricted / unknown catcher (bought before the answer changed) pays the
		  FIXED lure reward — AcornsMax × LureMultiplier acorns, no sticker roll ("lure:fixed").
		- Decor by date: the hub event square is built while the event runs (Event/EventDecor).
		- Season rollover: a profile from another season is reset (acorns / stickers / redeemed)
		  the first time the event touches it during this season; decorations are kept.
		- STARTER STICKERS (owner R97): while the event runs, every loaded player gets the 3 commonest
		  stickers free once per season (EventLogic.grantStarters; profile.event.starterSeason makes
		  it idempotent): a new sheet gets all 3, an older sheet with 1-2 stickers is topped up to 3,
		  a sheet with 3+ gets nothing. Toast "You got 3 free stickers to start!"; analytics
		  event "starter:<new|topup>" (amount = stickers granted); admin "HarvestResetStarter".
		- Plot turkeys walk on the owner's plot in the WORLD THEY ARE IN; when the owner travels, their
		  plot turkeys are re-placed (a natural one respawns after its interval, a pending lure on
		  the next tick) — owner R96 follow-up.
		- Analytics (event family, guarded lazy AnalyticsService) and owner admin commands (force on /
		  off, spawn turkeys, grant acorns / stickers, reset a sheet).

	Remotes: EventCollect (C→S turkeyId), EventRedeemSheet (C→S), EventShopBuy (C→S itemKey),
	EventState (S→C; payloads in docs/event.md):
		{ kind = "sync", active, turkeys = { TurkeyWire }, caught = { id } }
		{ kind = "spawn", turkey = TurkeyWire }      { kind = "despawn", id, reason }
		{ kind = "caught", id, acorns, bonus, sticker, dup, count, lure }
		{ kind = "refused", id, reason }             { kind = "redeemed", petId }

	Public API (other services, admin, B9):
		isActive(), getForced(), setForced(mode?), seasonId(),
		getAcorns(player), grantAcorns(player, n, reason), trySpendAcorns(player, n, reason),
		spawnTurkey("hub" | "plot", player?), grantSticker(player, index), resetSheet(player),
		resetStarter(player, regrantNow) (owner R97 QA)
		Signals: ActiveChanged(active), StickerFound(player, index, count), SheetRedeemed(player),
		TurkeyCaught(player)

	Example:
		if EventService.isActive() and EventService.trySpendAcorns(player, 150, "egg") then hatch() end
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local EventDecor = require(ServerScriptService.Server.Event.EventDecor)
local EventLogic = require(ServerScriptService.Server.Event.EventLogic)
local Lazy = require(ServerScriptService.Server.Event.Lazy)
local ProgressEvents = require(ServerScriptService.Server.Progression.ProgressEvents)
local MonetizationService = require(script.Parent.MonetizationService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TurkeySpawner = require(ServerScriptService.Server.Event.TurkeySpawner)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WorldGeometry = require(ReplicatedStorage.Shared.Config.Worlds.WorldGeometry)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type EventRecord = EventLogic.EventRecord
type ForceMode = EventConfig.ForceMode

local EventService = {}

EventService.ActiveChanged = Signal.new() :: Signal.Signal<boolean>
EventService.StickerFound = Signal.new() :: Signal.Signal<Player, number, number>
EventService.SheetRedeemed = Signal.new() :: Signal.Signal<Player>
EventService.TurkeyCaught = Signal.new() :: Signal.Signal<Player>

local SNAPSHOT_FIELDS = table.freeze({ "event" })

local forced: ForceMode? = nil
local active = false
local started = false
local spawnState = EventLogic.newSpawnState()
local random = Random.new()
local collectLimiter = RateLimiter.new(EventConfig.Limits.CollectBurst, EventConfig.Limits.CollectPerSecond)
local actionLimiter = RateLimiter.new(EventConfig.Limits.ActionBurst, EventConfig.Limits.ActionPerSecond)
-- os.clock() of each player's last catch (per-player cooldown).
local lastCollect: { [Player]: number } = {}
-- Sheet redeems in flight (a second request while PetService works is refused).
local redeeming: { [Player]: boolean } = {}
-- Pending Turkey Lures for profiles whose schema has no event.lures yet (lost on leave).
local memoryLures: { [number]: number } = {}
-- Players who got the "event is on" toast this session.
local welcomed: { [Player]: boolean } = {}

-- Uniform [0, 1) numbers for EventLogic.
local function rng(): number
	return random:NextNumber()
end

-- The server's shared clock (the same clock clients animate turkeys with).
local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- profile.event as the EventLogic record (the schema's optional fields are read nil-safely).
local function recordOf(profile: any): EventRecord
	return profile.event :: EventRecord
end

--[[
	The season id profiles are stamped with right now: the real season id, except while the owner
	FORCES the event on before the season ever started (an October test). Those test profiles get
	"<id>_preview", so the real launch resets them to a clean sheet automatically.
]]
local function currentSeasonId(): string
	if os.time() < EventConfig.Season.starts then
		return EventConfig.Season.id .. "_preview"
	end
	return EventConfig.Season.id
end

-- Analytics: the event family (guarded, never yields).
local function track(player: Player?, key: string, amount: number?)
	Lazy.analytics("event", player, key, amount)
end

--------------------------------------------------------------------------------------------------
-- Tycoon lookups (B3/B5 PlotService; guarded, nil-safe)
--------------------------------------------------------------------------------------------------

-- Where the tycoon server (B5) lives: a boot "feature path" (Server/Tycoon/PlotService).
local PLOT_SERVICE = "Tycoon/PlotService"

--[[
	The player's plot index (1..PlotCount) or nil: Tycoon/PlotService.getPlotIndex, else the
	server-set Player attribute "PlotIndex".
]]
local function plotIndexOf(player: Player): number?
	for _, name in { "getPlotIndex", "plotIndexOf" } do
		local fn = Lazy.fn(PLOT_SERVICE, name)
		if fn ~= nil then
			local ok, result = pcall(fn, player)
			local index = if ok and type(result) == "number" then result :: number else nil
			if index ~= nil and index >= 1 and index <= 8 and index % 1 == 0 then
				return index
			end
			if ok then
				return nil
			end
		end
	end
	local attribute = player:GetAttribute("PlotIndex")
	if type(attribute) == "number" and attribute >= 1 and attribute <= 8 and attribute % 1 == 0 then
		return attribute
	end
	return nil
end

--[[
	The world the player is in (Tycoon/WorldService.currentWorld; "main" when it is not loaded,
	fails, or names a world WorldLayout has no geometry for — never an error in the spawner).
]]
local function worldOf(player: Player): string
	local currentWorld = Lazy.fn("Tycoon/WorldService", "currentWorld")
	if currentWorld ~= nil then
		local ok, world = pcall(currentWorld, player)
		if ok and type(world) == "string" and WorldGeometry.get(world) ~= nil then
			return world
		end
	end
	return WorldsConfig.MAIN
end

--[[
	The player's current area in `worldId` (Nuke Town: profile.tycoon.area; another world:
	profile.worlds[worldId].tycoon.area; 1 when unknown).
]]
local function areaOf(player: Player, worldId: string): number
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return 1
	end
	local tycoon = profile.tycoon
	if worldId ~= WorldsConfig.MAIN then
		local worlds = profile.worlds
		local state = if type(worlds) == "table" then worlds[worldId] else nil
		tycoon = if type(state) == "table" then state.tycoon else nil
	end
	local area = if type(tycoon) == "table" then tycoon.area else nil
	return if type(area) == "number" and area >= 1 then area else 1
end

--------------------------------------------------------------------------------------------------
-- Profile helpers
--------------------------------------------------------------------------------------------------

--[[
	Makes the record belong to the current season (EventLogic.ensureSeason) and pushes "event" if it
	changed. Only while the season matters (event on, or past its start): a profile is never reset
	before the first Harvest Feast ever starts.
]]
local function ensureSeason(player: Player, event: EventRecord): boolean
	if not active and os.time() < EventConfig.Season.starts then
		return false
	end
	if EventLogic.ensureSeason(event, currentSeasonId()) then
		PlayerDataService.markChanged(player, false, SNAPSHOT_FIELDS)
		return true
	end
	return false
end

-- Pending lures (profile field when the schema has it, else this server's memory).
local function pendingLures(player: Player, event: EventRecord): number
	local lures = event.lures
	if type(lures) == "number" then
		return math.max(0, math.floor(lures))
	end
	return memoryLures[player.UserId] or 0
end

-- Adds (delta > 0) or consumes (delta < 0) pending lures.
local function changeLures(player: Player, event: EventRecord, delta: number)
	if type(event.lures) == "number" then
		event.lures = math.clamp(math.floor((event.lures :: number) + delta), 0, 1e6)
	else
		memoryLures[player.UserId] = math.max(0, (memoryLures[player.UserId] or 0) + delta)
	end
end

--[[
	Owner R97 — gives a loaded player this season's free starter stickers while the event runs
	(EventLogic.grantStarters: the commonest stickers, topping the sheet up to
	EventConfig.Starter.Count, once per season), then saves, pushes "event", toasts and tracks.
	Idempotent: profile.event.starterSeason makes every later call this season a no-op, on this
	or any other server. Call it AFTER ensureSeason (a record from another season is skipped).
	@return the number of stickers granted now
	Example: ensureSeason(player, event); grantStarters(player, event) --> 3 for a brand-new sheet
]]
local function grantStarters(player: Player, event: EventRecord): number
	if not active then
		return 0
	end
	local seasonId = currentSeasonId()
	if event.season ~= seasonId or event.starterSeason == seasonId then
		return 0
	end
	local before = EventConfig.countStickers(event.stickers)
	local granted = EventLogic.grantStarters(event, seasonId)
	-- The season stamp changed even when the sheet needed nothing: persist it either way (a grant
	-- is a reward, so it is saved soon; a bare stamp rides the next regular save).
	PlayerDataService.markChanged(player, #granted > 0, SNAPSHOT_FIELDS)
	if #granted == 0 then
		return 0
	end
	local text = if #granted == 1
		then "You got a free sticker to start!"
		else `You got {#granted} free stickers to start!`
	PlayerDataService.notify(player, text, "reward", EventConfig.Stickers[granted[1]].icon)
	track(player, if before == 0 then "starter:new" else "starter:topup", #granted)
	return #granted
end

--------------------------------------------------------------------------------------------------
-- Replication
--------------------------------------------------------------------------------------------------

-- Every live turkey as wires + the ids this player already caught.
local function syncPayload(player: Player): { [string]: any }
	local turkeys = {}
	local caught = {}
	TurkeySpawner.forEach(function(record)
		table.insert(turkeys, record.wire)
		if record.collected[player.UserId] then
			table.insert(caught, record.wire.id)
		end
	end)
	return { kind = "sync", active = active, turkeys = turkeys, caught = caught }
end

local function sendSync(player: Player)
	if player.Parent == Players then
		Remotes.fireClient("EventState", player, syncPayload(player))
	end
end

-- Broadcasts the removal of turkeys (caught lures, ended event, admin clears).
local function broadcastDespawn(records: { TurkeySpawner.Live }, reason: string)
	for _, record in records do
		Remotes.fireAllClients("EventState", { kind = "despawn", id = record.wire.id, reason = reason })
	end
end

-- Writes the ReplicatedStorage attributes clients read.
local function publishAttributes()
	local names = EventConfig.Attributes
	ReplicatedStorage:SetAttribute(names.Active, active)
	ReplicatedStorage:SetAttribute(names.StartsAt, EventConfig.Season.starts)
	ReplicatedStorage:SetAttribute(names.EndsAt, EventConfig.Season.ends)
	ReplicatedStorage:SetAttribute(names.RedeemUntil, EventConfig.redeemUntil())
	ReplicatedStorage:SetAttribute(names.Forced, forced or "")
end

--------------------------------------------------------------------------------------------------
-- Turkeys
--------------------------------------------------------------------------------------------------

-- The spawn context (hub anchors from HubLayout, plot lookups) for TurkeySpawner.
local function spawnContext(): TurkeySpawner.SpawnContext
	local hub = EventDecor.hubEvent()
	return {
		now = serverNow(),
		plotIndexOf = function(userId: number): number?
			local player = Players:GetPlayerByUserId(userId)
			return if player ~= nil then plotIndexOf(player) else nil
		end,
		worldOf = function(userId: number): string
			local player = Players:GetPlayerByUserId(userId)
			return if player ~= nil then worldOf(player) else WorldsConfig.MAIN
		end,
		areaOf = function(userId: number, worldId: string): number
			local player = Players:GetPlayerByUserId(userId)
			return if player ~= nil then areaOf(player, worldId) else 1
		end,
		hubAnchors = hub.turkeySpawns or {},
		square = EventDecor.square().Position,
		rng = rng,
	}
end

-- Spawns one turkey for an order and tells every client. @return the turkey id or nil
local function spawnOrder(order: EventLogic.SpawnOrder, ctx: TurkeySpawner.SpawnContext): string?
	local record = TurkeySpawner.spawn(order, ctx)
	if record == nil then
		return nil
	end
	Remotes.fireAllClients("EventState", { kind = "spawn", turkey = record.wire })
	track(nil, "turkey:spawn")
	return record.wire.id
end

-- One scheduler step: expire, plan, spawn (EventLogic.planSpawns facts from live state).
local function schedulerTick()
	local now = serverNow()
	TurkeySpawner.expired(now) -- clients drop expired turkeys on their own (they know `life`)
	-- A plot turkey belongs to the world its owner was in when it spawned; after a trip it would
	-- wander an empty plot in a world they left, so it leaves ("moved"). The counts below then let
	-- a pending lure respawn on their new plot this tick and a natural one after its interval.
	-- Each owner's world is looked up once per tick, only for owners that have a plot turkey.
	local worldNow: { [number]: string | false } = {}
	local moved = TurkeySpawner.removeWhere(function(record)
		local owner = record.plotOwner
		if owner == nil then
			return false
		end
		local current = worldNow[owner]
		if current == nil then
			local player = Players:GetPlayerByUserId(owner)
			current = if player ~= nil then worldOf(player) else false
			worldNow[owner] = current
		end
		return current ~= false and current ~= record.world
	end)
	if #moved > 0 then
		broadcastDespawn(moved, "moved")
	end
	local counts = TurkeySpawner.counts()
	local rows: { EventLogic.PlayerFacts } = {}
	for _, player in Players:GetPlayers() do
		local profile = PlayerDataService.getProfile(player)
		if profile == nil then
			continue
		end
		local userId = player.UserId
		table.insert(rows, {
			userId = userId,
			plotIndex = plotIndexOf(player),
			plotAlive = counts.plotAlive[userId] or 0,
			lurePending = pendingLures(player, recordOf(profile)),
			lureAlive = counts.lureAlive[userId] or 0,
		})
	end
	local orders = EventLogic.planSpawns(now, {
		active = active,
		totalAlive = counts.total,
		naturalAlive = counts.natural,
		hubAlive = counts.hub,
		players = rows,
	}, spawnState, rng)
	if #orders == 0 then
		return
	end
	local ctx = spawnContext()
	for _, order in orders do
		spawnOrder(order, ctx)
	end
end

-- Shows each loaded player's owned plot decorations on their current plot (cheap check per tick).
local function decorTick()
	for _, player in Players:GetPlayers() do
		local profile = PlayerDataService.getProfile(player)
		if profile == nil then
			continue
		end
		local decor = recordOf(profile).decor
		if type(decor) ~= "table" or next(decor) == nil then
			continue
		end
		local plotIndex = plotIndexOf(player)
		if plotIndex ~= nil and EventDecor.decorPlotOf(player.UserId) ~= plotIndex then
			local owned = decor :: { [string]: true }
			task.spawn(EventDecor.showPlotDecor, player.UserId, plotIndex, owned, nil)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Active state
--------------------------------------------------------------------------------------------------

-- Recomputes active from the clock + force; applies every side effect of a change.
local function refreshActive()
	local now = os.time()
	local value = EventConfig.resolveActive(now, forced)
	if value == active then
		return
	end
	active = value
	publishAttributes()
	task.spawn(EventDecor.setHubActive, value)
	if value then
		for _, player in Players:GetPlayers() do
			local profile = PlayerDataService.getProfile(player)
			if profile ~= nil then
				local event = recordOf(profile)
				ensureSeason(player, event)
				if not welcomed[player] then
					welcomed[player] = true
					PlayerDataService.notify(
						player,
						"HARVEST FEAST is here! Catch Golden Turkeys for acorns + stickers!",
						"reward",
						"Event"
					)
				end
				grantStarters(player, event) -- owner R97: the event just turned on mid-session
			end
		end
	else
		-- Natural turkeys leave with the event; paid lure turkeys stay until caught.
		broadcastDespawn(
			TurkeySpawner.removeWhere(function(record)
				return not record.wire.lure
			end),
			"ended"
		)
	end
	for _, player in Players:GetPlayers() do
		sendSync(player)
	end
	EventService.ActiveChanged:Fire(value)
end

--------------------------------------------------------------------------------------------------
-- Remote handlers
--------------------------------------------------------------------------------------------------

-- Tells one client why a catch was refused (so it clears its "pending" flag / stale turkey).
local function refuse(player: Player, id: string, reason: string)
	Remotes.fireClient("EventState", player, { kind = "refused", id = id, reason = reason })
end

--[[ EventCollect(turkeyId): validate (see the module header) → roll → grant → reply. ]]
local function onCollect(player: Player, rawId: unknown)
	if not collectLimiter:Allow(player) then
		return
	end
	local id = Validate.key(rawId, EventConfig.Limits.MaxTurkeyIdLength)
	if id == nil then
		return
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return
	end
	local record = TurkeySpawner.get(id)
	local userId = player.UserId
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local hasCharacter = root ~= nil and root:IsA("BasePart") and humanoid ~= nil and humanoid.Health > 0
	local distance = math.huge
	if record ~= nil and hasCharacter then
		distance = EventLogic.minDistance(
			record.compiled,
			serverNow(),
			(root :: BasePart).Position,
			EventConfig.Turkey.LagSamples
		)
	end
	local last = lastCollect[player]
	local reason = EventLogic.collectCheck({
		exists = record ~= nil,
		active = active,
		lure = record ~= nil and record.wire.lure,
		owner = if record ~= nil then record.wire.owner else 0,
		userId = userId,
		already = record ~= nil and record.collected[userId] == true,
		sinceLast = if last ~= nil then os.clock() - last else math.huge,
		hasCharacter = hasCharacter,
		distance = distance,
	}, EventLogic.serverRange())
	if reason ~= "ok" or record == nil then
		refuse(player, id, reason)
		return
	end
	local turkey = record :: TurkeySpawner.Live
	lastCollect[player] = os.clock()
	turkey.collected[userId] = true

	local event = recordOf(profile)
	ensureSeason(player, event)
	local isLure = turkey.wire.lure
	-- A lure was bought with Robux: its sticker roll is a paid random item, so it only rolls when
	-- the catcher's policy is KNOWN to allow them (never yields; unknown = fixed reward, fail closed).
	local paidRandomAllowed = isLure
		and PlayerDataService.isPolicyKnown(player)
		and not PlayerDataService.isPaidRandomRestricted(player)
	local reward = EventLogic.rollReward(event.stickers, isLure, rng, paidRandomAllowed)
	if isLure and not paidRandomAllowed then
		track(player, "lure:fixed")
	end
	local added = EventLogic.applyReward(event, reward)
	if isLure then
		changeLures(player, event, -1)
		local removed = TurkeySpawner.remove(id)
		if removed ~= nil then
			broadcastDespawn({ removed }, "caught")
		end
	end
	local newSticker = reward.sticker > 0 and not reward.dup
	-- A new sticker (or a paid lure consumed) saves soon; plain acorns ride the next autosave.
	PlayerDataService.markChanged(player, newSticker or isLure, SNAPSHOT_FIELDS)
	local count = EventConfig.countStickers(event.stickers)
	Remotes.fireClient("EventState", player, {
		kind = "caught",
		id = id,
		acorns = reward.acorns,
		bonus = reward.bonus,
		sticker = reward.sticker,
		dup = reward.dup,
		count = count,
		lure = isLure,
	})
	track(player, "turkey:collect")
	ProgressEvents.progress(player, "turkey") -- R78 Quests / Pass: a Golden Turkey caught
	track(player, "acorns", added)
	if reward.sticker > 0 then
		track(player, if reward.dup then "stickerDup" else `sticker:{reward.sticker}`)
	end
	EventService.TurkeyCaught:Fire(player)
	if newSticker then
		EventService.StickerFound:Fire(player, reward.sticker, count)
	end
end

-- Player-facing texts for refused redeems / shop buys.
local REDEEM_TEXT: { [string]: string } = {
	incomplete = "Collect all 20 Feast Stickers to redeem the Gobble Bomb!",
	already = "You already redeemed this season's Gobble Bomb!",
	closed = "The Harvest Feast is over - see you next year!",
}
local SHOP_TEXT: { [string]: string } = {
	inactive = "The Harvest Shop is closed right now.",
	unknown = "That item isn't in the Harvest Shop.",
	owned = "You already own that decoration!",
	poor = "Not enough acorns yet - catch more Golden Turkeys!",
	unsupported = "Decorations are coming very soon!",
}

--[[ EventRedeemSheet(): 20 stickers → the Gobble Bomb pet, once per season. ]]
local function onRedeem(player: Player)
	if not actionLimiter:Allow(player) or redeeming[player] then
		return
	end
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return
	end
	if not PlayerDataService.canMutate(player) then
		PlayerDataService.notify(player, "Your save is offline right now - rejoin to redeem!", "error")
		return
	end
	local event = recordOf(profile)
	ensureSeason(player, event)
	local open = active or os.time() < EventConfig.redeemUntil()
	local reason = EventLogic.redeemCheck(event, open)
	if reason ~= "ok" then
		PlayerDataService.notify(player, REDEEM_TEXT[reason] or "Can't redeem right now.", "error")
		return
	end
	local grantPet = Lazy.fn("PetService", "grantPet")
	if grantPet == nil then
		PlayerDataService.notify(player, "The Gobble Bomb is almost ready - try again soon!", "info")
		return
	end
	redeeming[player] = true
	local ok, granted = pcall(grantPet, player, EventConfig.RewardPetId, "event_sheet")
	redeeming[player] = nil
	if not ok or granted ~= true then
		if not ok then
			warn(`[EventService] PetService.grantPet failed: {granted}`)
		end
		PlayerDataService.notify(player, "Couldn't add your Gobble Bomb right now - is your pet bag full?", "error")
		return
	end
	event.redeemed = true
	PlayerDataService.markChanged(player, true, SNAPSHOT_FIELDS)
	Remotes.fireClient("EventState", player, { kind = "redeemed", petId = EventConfig.RewardPetId })
	PlayerDataService.notify(player, "GOBBLE BOMB unlocked! Check your pets!", "reward", EventConfig.RewardIcon)
	track(player, "sheet:redeem")
	EventService.SheetRedeemed:Fire(player)
end

--[[ EventShopBuy(itemKey): acorns → a plot decoration or a personal boost. ]]
local function onShopBuy(player: Player, rawKey: unknown)
	if not actionLimiter:Allow(player) then
		return
	end
	local key, item = Validate.configKey(rawKey, EventConfig.ShopByKey, EventConfig.MaxShopKeyLength)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return
	end
	if not PlayerDataService.canMutate(player) then
		PlayerDataService.notify(player, "Your save is offline right now - rejoin to shop!", "error")
		return
	end
	local event = recordOf(profile)
	ensureSeason(player, event)
	local reason = EventLogic.shopCheck(item, event, active, type(event.decor) == "table")
	if reason ~= "ok" or item == nil or key == nil then
		PlayerDataService.notify(player, SHOP_TEXT[reason] or "Can't buy that right now.", "error")
		PlayerDataService.refresh(player, SNAPSHOT_FIELDS)
		return
	end
	local row = item :: EventConfig.ShopItem
	if row.kind == "boost" then
		local boost = row.boost :: EventConfig.BoostItemDef
		local grant = Lazy.fn("BoostService", "grant")
		if grant == nil then
			PlayerDataService.notify(player, "Boosts are coming very soon!", "info")
			return
		end
		if not EventLogic.spendAcorns(event, row.price) then
			return
		end
		local ok, expires = pcall(grant, player, boost.boostKey, boost.seconds)
		if not ok or type(expires) ~= "number" then
			EventLogic.addAcorns(event, row.price) -- refund: the boost was not applied
			PlayerDataService.markChanged(player, false, SNAPSHOT_FIELDS)
			PlayerDataService.notify(player, "That boost couldn't start - your acorns are back.", "error")
			return
		end
		PlayerDataService.markChanged(player, true, SNAPSHOT_FIELDS)
		PlayerDataService.notify(player, `{row.name} is on!`, "success", row.icon)
		track(player, `shop:{row.key}`)
		return
	end
	-- Decoration: spend, own, build on the plot (LEGO build-in).
	if not EventLogic.spendAcorns(event, row.price) then
		return
	end
	local owned = event.decor :: { [string]: true }
	owned[row.key] = true
	PlayerDataService.markChanged(player, true, SNAPSHOT_FIELDS)
	PlayerDataService.notify(player, `{row.name} is being built on your plot!`, "success", row.icon)
	track(player, `decor:{row.key}`)
	local plotIndex = plotIndexOf(player)
	if plotIndex ~= nil then
		task.spawn(EventDecor.showPlotDecor, player.UserId, plotIndex, owned, row.key)
	end
end

--------------------------------------------------------------------------------------------------
-- Products
--------------------------------------------------------------------------------------------------

--[[ "Acorns": +product.acorns (receipt grant step; never yields). ]]
local function grantAcornProduct(player: Player, profile: any, product: any, _receipt: any): boolean
	local amount = product.acorns
	if type(amount) ~= "number" or amount < 1 then
		return false
	end
	local event = recordOf(profile)
	EventLogic.ensureSeason(event, currentSeasonId())
	local added = EventLogic.addAcorns(event, amount)
	task.defer(track, player, "acorns", added)
	return true
end

--[[ "TurkeyLure": one more pending lure (the scheduler spawns it on the buyer's plot). ]]
local function grantLureProduct(player: Player, profile: any, _product: any, _receipt: any): boolean
	changeLures(player, recordOf(profile), 1)
	task.defer(function()
		track(player, "turkey:lure")
		PlayerDataService.notify(player, "A Golden Turkey is on its way to your plot!", "reward", "GoldenTurkey")
	end)
	return true
end

--------------------------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------------------------

--[[ True while the Harvest Feast runs on this server (window or admin force). ]]
function EventService.isActive(): boolean
	return active
end

--[[ The admin override ("on" / "off") or nil (by date). ]]
function EventService.getForced(): ForceMode?
	return forced
end

--[[
	Admin: force the event on / off on THIS server, or nil to follow the date window again.
	Example: EventService.setForced("on") -- test the event in October
]]
function EventService.setForced(mode: ForceMode?)
	forced = mode
	publishAttributes()
	refreshActive()
end

--[[ The current season id (profile.event.season). ]]
function EventService.seasonId(): string
	return currentSeasonId()
end

--[[ The player's acorns this season (0 when not loaded / from another season). ]]
function EventService.getAcorns(player: Player): number
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return 0
	end
	local event = recordOf(profile)
	if event.season ~= currentSeasonId() then
		return 0
	end
	return EventLogic.acorns(event)
end

--[[
	Grants acorns (admin, rewards). Never yields.
	@return acorns actually added
]]
function EventService.grantAcorns(player: Player, amount: number, _reason: string): number
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return 0
	end
	local event = recordOf(profile)
	EventLogic.ensureSeason(event, currentSeasonId())
	local added = EventLogic.addAcorns(event, amount)
	if added > 0 then
		PlayerDataService.markChanged(player, true, SNAPSHOT_FIELDS)
		track(player, "acorns", added)
	end
	return added
end

--[[
	Spends acorns atomically (B9's Harvest Egg hatches). Never yields. A previous season's balance
	is never spendable (the record is rolled first).
	@return true when spent
	Example: if EventService.trySpendAcorns(player, 150, "egg") then hatch() end
]]
function EventService.trySpendAcorns(player: Player, amount: number, _reason: string): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false
	end
	local event = recordOf(profile)
	EventLogic.ensureSeason(event, currentSeasonId())
	if not EventLogic.spendAcorns(event, amount) then
		return false
	end
	PlayerDataService.markChanged(player, true, SNAPSHOT_FIELDS)
	return true
end

--[[
	Admin: spawns a natural turkey now in the hub, or on `player`'s plot (ignores the timers, not
	the hard cap). @return the turkey id or nil
]]
function EventService.spawnTurkey(where: "hub" | "plot", player: Player?): string?
	if TurkeySpawner.counts().total >= EventConfig.Turkey.MaxAliveWithLures then
		return nil
	end
	local order: EventLogic.SpawnOrder = {
		zone = where,
		userId = if player ~= nil then player.UserId else nil,
		lure = false,
	}
	return spawnOrder(order, spawnContext())
end

--[[ Admin: gives a sticker (0 = every sticker). @return stickers now owned ]]
function EventService.grantSticker(player: Player, index: number): number
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return 0
	end
	local event = recordOf(profile)
	EventLogic.ensureSeason(event, currentSeasonId())
	for _, def in EventConfig.Stickers do
		if index == 0 or def.index == index then
			event.stickers[def.index] = true
		end
	end
	PlayerDataService.markChanged(player, true, SNAPSHOT_FIELDS)
	local count = EventConfig.countStickers(event.stickers)
	EventService.StickerFound:Fire(player, index, count)
	return count
end

--[[ Admin: clears the player's stickers + redeemed flag for this season (acorns stay). ]]
function EventService.resetSheet(player: Player): boolean
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false
	end
	local event = recordOf(profile)
	EventLogic.ensureSeason(event, currentSeasonId())
	event.stickers = {}
	event.redeemed = false
	PlayerDataService.markChanged(player, true, SNAPSHOT_FIELDS)
	return true
end

--[[
	Admin (owner R97 QA): clears the player's free-starter stamp for this season. With
	`regrantNow` the grant runs at once (same code path as a join: tops the sheet up to 3 while the
	event is on); without it the next join / event start grants. Stickers are never removed here
	(HarvestResetSheet does that).
	@return ok (profile loaded), stickers granted now
]]
function EventService.resetStarter(player: Player, regrantNow: boolean): (boolean, number)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return false, 0
	end
	local event = recordOf(profile)
	EventLogic.ensureSeason(event, currentSeasonId())
	event.starterSeason = ""
	PlayerDataService.markChanged(player, true, SNAPSHOT_FIELDS)
	track(player, "starter:reset")
	if not regrantNow then
		return true, 0
	end
	return true, grantStarters(player, event)
end

--------------------------------------------------------------------------------------------------
-- Admin commands (B14 AdminService.registerCommand; guarded)
--------------------------------------------------------------------------------------------------

type Ctx = { player: Player?, target: { player: Player }?, args: { [string]: any } }

local function targetOf(ctx: Ctx): Player?
	local target = ctx.target
	return if target ~= nil then target.player else nil
end

local function registerAdminCommands()
	Lazy.registerAdmin({
		name = "HarvestForce",
		tab = "Server",
		label = "Harvest Feast On/Off",
		description = "Force the Harvest Feast on or off on this server (Auto = by date).",
		target = "None",
		args = {
			mode = {
				kind = "enum",
				values = { "auto", "on", "off" },
				labels = { "Auto (date)", "Force ON", "Force OFF" },
				label = "Mode",
			},
		},
		argOrder = { "mode" },
		cooldown = 2,
		audited = true,
		confirm = false,
		color = "orange",
		order = 60,
	}, function(ctx: Ctx): (boolean, string)
		local mode = ctx.args.mode
		EventService.setForced(if mode == "on" then "on" elseif mode == "off" then "off" else nil)
		return true, `Harvest Feast: {if active then "ON" else "OFF"} ({mode})`
	end)
	Lazy.registerAdmin({
		name = "HarvestTurkeyHub",
		tab = "Server",
		label = "Spawn Turkey (Hub)",
		description = "Spawn a Golden Turkey in the hub event square now.",
		target = "None",
		args = {},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "yellow",
		order = 61,
	}, function(_ctx: Ctx): (boolean, string)
		local id = EventService.spawnTurkey("hub", nil)
		return id ~= nil, if id ~= nil then `Spawned turkey {id} in the hub` else "Turkey cap reached"
	end)
	Lazy.registerAdmin({
		name = "HarvestTurkeyPlot",
		tab = "Players",
		label = "Spawn Turkey (Plot)",
		description = "Spawn a Golden Turkey on this player's plot now.",
		target = "Player",
		args = {},
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "yellow",
		order = 61,
	}, function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		local id = EventService.spawnTurkey("plot", player)
		return id ~= nil,
			if id ~= nil then `Spawned turkey {id} on {player.Name}'s plot` else "No plot yet / turkey cap reached"
	end)
	Lazy.registerAdmin({
		name = "HarvestGrantAcorns",
		tab = "Players",
		label = "Give Acorns",
		target = "Player",
		args = {
			amount = { kind = "integer", min = 1, max = 100000, presets = { 100, 500, 1000, 5000 }, label = "Acorns" },
		},
		argOrder = { "amount" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 62,
	}, function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		local added = EventService.grantAcorns(player, ctx.args.amount, "admin")
		return added > 0, `Gave {added} acorns to {player.Name}`
	end)
	Lazy.registerAdmin({
		name = "HarvestGrantSticker",
		tab = "Players",
		label = "Give Sticker",
		description = "Give one Feast Sticker (0 = all 20).",
		target = "Player",
		args = {
			sticker = {
				kind = "integer",
				min = 0,
				max = EventConfig.StickerCount,
				presets = { 0, 1, 20 },
				label = "Sticker #",
			},
		},
		argOrder = { "sticker" },
		cooldown = 1,
		audited = true,
		confirm = false,
		color = "orange",
		order = 63,
	}, function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		local count = EventService.grantSticker(player, ctx.args.sticker)
		return true, `{player.Name} now has {count}/{EventConfig.StickerCount} stickers`
	end)
	Lazy.registerAdmin({
		name = "HarvestResetSheet",
		tab = "Players",
		label = "Reset Sticker Sheet",
		description = "Clear this player's stickers and Gobble Bomb redeem for this season.",
		target = "Player",
		args = {},
		cooldown = 2,
		audited = true,
		confirm = true,
		color = "red",
		order = 64,
	}, function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		local ok = EventService.resetSheet(player)
		return ok, if ok then `Reset {player.Name}'s sticker sheet` else "Profile not loaded"
	end)
	-- Owner R97 QA: replay the free starter stickers (combine with Reset Sticker Sheet to test a
	-- brand-new sheet, or with Give Sticker to test a top-up).
	Lazy.registerAdmin({
		name = "HarvestResetStarter",
		tab = "Players",
		label = "Reset Starter Stickers",
		description = "Clear this player's free-starter-sticker flag for this season (QA). Grant now, or on their next join.",
		target = "Player",
		args = {
			mode = {
				kind = "enum",
				values = { "now", "rejoin" },
				labels = { "Grant now", "On next join" },
				label = "When",
			},
		},
		argOrder = { "mode" },
		cooldown = 2,
		audited = true,
		confirm = false,
		color = "orange",
		order = 65,
	}, function(ctx: Ctx): (boolean, string)
		local player = targetOf(ctx)
		if player == nil then
			return false, "Pick a player first"
		end
		local now = ctx.args.mode ~= "rejoin"
		local ok, granted = EventService.resetStarter(player, now)
		if not ok then
			return false, "Profile not loaded"
		end
		if not now then
			return true, `{player.Name}'s starter stickers will be granted on their next join`
		end
		if not active then
			return true, `Flag cleared; the Harvest Feast is off, so {player.Name} gets them when it starts`
		end
		return true, `{player.Name} got {granted} starter sticker(s)`
	end)
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

local function onProfileLoaded(player: Player, profile: any, _isNew: boolean)
	if active then
		local event = recordOf(profile)
		ensureSeason(player, event)
		if not welcomed[player] then
			welcomed[player] = true
			PlayerDataService.notify(
				player,
				"HARVEST FEAST is on! Catch Golden Turkeys for acorns + stickers!",
				"reward",
				"Event"
			)
		end
		-- Owner R97: a first event join gets 3 free stickers; an older sheet is topped up to 3.
		grantStarters(player, event)
	end
	sendSync(player)
end

local function onPlayerRemoving(player: Player)
	collectLimiter:Forget(player)
	actionLimiter:Forget(player)
	lastCollect[player] = nil
	redeeming[player] = nil
	welcomed[player] = nil
	local userId = player.UserId
	memoryLures[userId] = nil
	EventDecor.clearPlotDecor(userId)
	-- Their lure turkey leaves with them (the pending lure stays saved and returns next session).
	broadcastDespawn(
		TurkeySpawner.removeWhere(function(record)
			return record.wire.lure and record.wire.owner == userId
		end),
		"left"
	)
end

function EventService.Init()
	MonetizationService.registerProductHandler("Acorns", grantAcornProduct)
	MonetizationService.registerProductHandler("TurkeyLure", grantLureProduct)
	-- Counts KNOWN restricted lure refusals (no yield); MonetizationService itself refuses every
	-- paid random prompt for a restricted / unknown policy (fail closed).
	MonetizationService.registerPromptRefusal("TurkeyLure", function(player: Player, _product: any): string?
		if PlayerDataService.isPolicyKnown(player) and PlayerDataService.isPaidRandomRestricted(player) then
			track(player, "lure:refused:policy")
			return EventConfig.LurePolicyText
		end
		return nil
	end)
	Lazy.registerIds("decorId", function(id: string): boolean
		local item = EventConfig.ShopByKey[id]
		return item ~= nil and item.kind == "decor"
	end)
	Lazy.registerIds("eventItemId", function(id: string): boolean
		return EventConfig.ShopByKey[id] ~= nil
	end)
end

function EventService.Start()
	if started then
		return
	end
	started = true
	active = EventConfig.resolveActive(os.time(), forced)
	publishAttributes()
	task.spawn(function()
		local ok, err = pcall(EventDecor.ensureTurkeyTemplate)
		if not ok then
			warn(`[EventService] turkey template failed: {err}`)
		end
	end)
	if active then
		task.spawn(EventDecor.setHubActive, true)
	end

	Remotes.onServerEvent("EventCollect", onCollect)
	Remotes.onServerEvent("EventRedeemSheet", function(player: Player)
		onRedeem(player)
	end)
	Remotes.onServerEvent("EventShopBuy", onShopBuy)

	PlayerDataService.ProfileLoaded:Connect(onProfileLoaded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	-- A released plot loses its decorations at once (the next owner's plot starts clean); a new
	-- plot gets them from decorTick within a second.
	local plotService = Lazy.service(PLOT_SERVICE)
	local released = if plotService ~= nil then plotService.PlotReleased else nil
	if type(released) == "table" and type(released.Connect) == "function" then
		released:Connect(function(player: Player)
			EventDecor.clearPlotDecor(player.UserId)
		end)
	end
	for _, player in Players:GetPlayers() do
		local profile = PlayerDataService.getProfile(player)
		if profile ~= nil then
			onProfileLoaded(player, profile, false)
		end
	end

	registerAdminCommands()

	-- The 1 Hz scheduler (one loop for the whole event; every step guarded).
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(function()
				refreshActive()
				schedulerTick()
				decorTick()
			end)
			if not ok then
				warn(`[EventService] tick failed: {err}`)
			end
		end
	end)
end

return EventService
