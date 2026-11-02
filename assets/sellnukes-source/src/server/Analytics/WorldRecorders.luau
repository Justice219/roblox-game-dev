--!strict
--[[
	WorldRecorders — the analytics of the extra worlds (owner R57 World 2 "Dino Valley"; spec §12,
	plan §3.7). Everything here writes the `worlds` family (plus a few world-agnostic tycoon keys)
	from the server's OWN trusted events. Pure counting: never yields, never throws (every public
	helper is wrapped in Runtime.economyGuard, so New Player Mode / staff are diverted exactly like
	the tycoon helpers).

	Typed helpers (exposed on AnalyticsService under the same names with a "world" prefix):
		unlocked(player, worldId, source)                 unlock / unlockSrc + funnel "unlocked"
		travelled(player, worldId, source, firstVisit)    travel / visitor (once per player-day) /
		                                                  firstVisit + funnel "firstTravel"; starts
		                                                  the time-in-world clock of `worldId`
		travelFailed(player, worldId?, reason)            travelFail (unknown ids / reasons fold)
		portalLocked(player, worldId)                     portalLocked (throttled per player)
		areaReached(player, worldId, area)                area / first-run areaN, areaAt, areaB +
		                                                  funnel "area<N>" + progression path
		rebirthed(player, worldId, rebirthsAfter, tokens) rebirth / rebirthN / tokens + funnel
		rebirthShop(player, worldId, upgradeKey)          rebirthShop
		offlinePaid(player, worldId, seconds, amount)     offline:pay / offlineSec / incomeW:offline
		offlineDoubled(player, worldId)                   offline:double
	Routed by Recorders (callers keep using padBought / producerClick / producerIncome /
	producerUpgraded with an extra world's ids; Recorders resolves the world from the id):
		padBought / producerClick / producerIncome / producerUpgraded (internal entry points below).
	Client claims (Sessions.onFunnelStep "worldPopup"): popupClaim(player, worldId, action).
	Session hooks (Sessions): fold(player) every flush + at leave (time per world), forget(player).
	Economy (Recorders.currencyChanged): batchIncome(player, currency, delta) batches an extra
	world's currency earnings for ONE Roblox economy event per player per flush (flushIncome).

	Why time per world is measured here: the analytics clock (os.clock) and the server-set Player
	attribute CurrentWorld are both trusted; WorldService only has to call travelled() and the
	numbers stay right even if a trip skips the hook (fold() re-reads the attribute).

	Funnel steps happen once per player by construction (no saved marker needed): "unlocked" is
	sticky, "firstTravel" comes from WorldService's own first-visit flag, "firstPad" / "manager" /
	"finale" / "area<N>" only on the world's FIRST run (rebirths = 0) at their first occurrence,
	"rebirth" when the world's rebirth count becomes 1. A per-session set also dedupes.

	Connects to: Recorders (routing + income batching), Sessions (fold / popup / flush), Runtime
	(sessions, profile, forwarder, guards), Recorder (counters), AnalyticsMarks (visit surface
	"w_<id>"), AnalyticsConfig.Worlds / Metrics.worlds, Shared/Config/Worlds/WorldsConfig,
	tests/analytics-recorders.luau.

	Example:
		AnalyticsService.worldUnlocked(player, "dino", "area")
		AnalyticsService.worldTravelled(player, "dino", "portal", true)
		AnalyticsService.worldAreaReached(player, "dino", 2)
		AnalyticsService.padBought(player, "d1_dig_site")   -- routed here by Recorders
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local AnalyticsMarks = require(ReplicatedStorage.Shared.Config.AnalyticsMarks)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local AnalyticsLogic = require(script.Parent.AnalyticsLogic)
local Recorder = require(script.Parent.Recorder)
local Runtime = require(script.Parent.Runtime)

type WorldDef = WorldsConfig.WorldDef

local WorldRecorders = {}

local count = Recorder.count
local guard = Runtime.economyGuard
local worldsConfig = AnalyticsConfig.Worlds
local tycoonConfig = AnalyticsConfig.Tycoon

local MAIN = WorldsConfig.MAIN
-- Server-set Player attribute naming the world the player is in (WorldService owns it).
local CURRENT_WORLD_ATTRIBUTE = "CurrentWorld"
local BAD_KEY = "ops:badKey:worlds"

-- Allowlists as sets.
local function setOf(list: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, value in list do
		set[value] = true
	end
	return set
end
local UNLOCK_SOURCES = setOf(worldsConfig.UnlockSources)
local POPUP_ACTIONS = setOf(worldsConfig.PopupActions)
local TRAVEL_SOURCES = setOf(worldsConfig.TravelSources)
local TRAVEL_REASONS = setOf(worldsConfig.TravelReasons)
local SURFACES = setOf(AnalyticsConfig.Unique.Surfaces)

-- Funnel step → its 1-based Roblox step number, per extra world.
local STEP_INDEX: { [string]: { [string]: number } } = {}
for worldId, funnel in worldsConfig.Funnels do
	local index: { [string]: number } = {}
	for position, step in funnel.steps do
		index[step] = position
	end
	STEP_INDEX[worldId] = index
end

-- Per analytics session (weak keys: dropped with the session table).
type WorldSession = {
	world: string, -- the world whose clock is running
	since: number, -- os.clock() the running world's seconds were last folded at
	areas: { [string]: { [number]: boolean } }, -- per world: areas counted this session (this run)
	steps: { [string]: boolean }, -- "<world>:<step>" funnel steps counted this session
	visits: { [string]: number }, -- per world: UTC day a visit was counted (fallback dedupe)
	popups: { [string]: number }, -- "<world>:<action>" popup claims counted this session
	portalAt: { [string]: number }, -- per world: os.clock() of the last counted portalLocked
	income: { [string]: number }, -- per currency key: earnings not yet forwarded to Roblox
}
local states: { [any]: WorldSession } = setmetatable({}, { __mode = "k" }) :: any

-- A valid world id the player's CurrentWorld attribute names, or nil.
local function attributeWorld(player: Player): string?
	local ok, value = pcall(player.GetAttribute, player, CURRENT_WORLD_ATTRIBUTE)
	if ok and type(value) == "string" and WorldsConfig.get(value) ~= nil then
		return value
	end
	return nil
end

-- The world state of the player's CURRENT analytics session (nil without a session).
local function stateOf(player: Player): WorldSession?
	local info = Runtime.sessions[player]
	if info == nil then
		return nil
	end
	local state = states[info]
	if state == nil then
		state = {
			world = attributeWorld(player) or MAIN,
			since = os.clock(),
			areas = {},
			steps = {},
			visits = {},
			popups = {},
			portalAt = {},
			income = {},
		}
		states[info] = state
	end
	return state
end

-- The definition of an EXTRA world (nil for "main", unknown ids and non-strings).
local function extraWorld(worldId: unknown): WorldDef?
	local def = WorldsConfig.get(worldId)
	if def == nil or def.id == MAIN then
		return nil
	end
	return def
end

-- profile.worlds[worldId] of the player's live profile (nil when unknown / not loaded).
local function worldStateOf(player: Player, worldId: string): { [string]: any }?
	local profile = Runtime.profileOf(player)
	local worlds = if profile ~= nil then (profile :: any).worlds else nil
	local state = if type(worlds) == "table" then worlds[worldId] else nil
	return if type(state) == "table" then state else nil
end

-- A sanitised whole number ≥ 0 from untrusted-shape profile data (anything else → 0).
local function wholeOf(value: unknown, max: number): number
	if type(value) ~= "number" or value ~= value or value < 0 or value > max then
		return 0
	end
	return math.floor(value)
end

-- The player's rebirth count in a world (0 when unknown).
local function rebirthsIn(player: Player, worldId: string): number
	local state = worldStateOf(player, worldId)
	return if state ~= nil then wholeOf(state.rebirths, 1e9) else 0
end

-- Seconds into the player's current run of a world (WorldService's 1 Hz world clock).
local function runSecondsIn(player: Player, worldId: string): number
	local state = worldStateOf(player, worldId)
	local stats = if state ~= nil then state.stats else nil
	return if type(stats) == "table" then wholeOf(stats.runSeconds, 1e10) else 0
end

-- Owned pads of a world (the profile's PadSet; empty when unknown).
local function padsIn(player: Player, worldId: string): { [string]: any }
	local state = worldStateOf(player, worldId)
	local tycoon = if state ~= nil then state.tycoon else nil
	local pads = if type(tycoon) == "table" then tycoon.pads else nil
	return if type(pads) == "table" then pads else {}
end

--[[
	Counts a world funnel step once ("step:<world>:<step>") and forwards it to the world's Roblox
	one-time funnel (AnalyticsConfig.Worlds.Funnels). Callers only call it at the step's first
	occurrence; the session set guards against a repeat within the session.
]]
local function markStep(player: Player, def: WorldDef, step: string)
	local index = STEP_INDEX[def.id]
	local number = if index ~= nil then index[step] else nil
	if number == nil then
		return
	end
	local state = stateOf(player)
	local id = `{def.id}:{step}`
	if state ~= nil then
		if state.steps[id] then
			return
		end
		state.steps[id] = true
	end
	count("worlds", `step:{id}`)
	local live = Runtime.livePlayer(player)
	local funnel = worldsConfig.Funnels[def.id]
	if live ~= nil and funnel ~= nil then
		Runtime.forwarder.funnel(live, funnel.name, nil, number, step)
	end
end

--------------------------------------------------------------------------------------------------
-- Time per world
--------------------------------------------------------------------------------------------------

-- Adds the running world's elapsed whole seconds to "seconds:<world>" (excluded players: the
-- clock advances, nothing is counted). The fraction carries over to the next fold.
local function foldSeconds(player: Player, state: WorldSession)
	local now = os.clock()
	local elapsed = math.max(0, now - state.since)
	local whole = math.floor(elapsed)
	if whole <= 0 then
		return
	end
	state.since += whole
	if not Runtime.isExcluded(player) then
		count("worlds", `seconds:{state.world}`, math.min(whole, worldsConfig.MaxFoldSeconds))
	end
end

-- Folds the running world, then starts `worldId`'s clock.
local function switchWorld(player: Player, state: WorldSession, worldId: string)
	foldSeconds(player, state)
	if state.world ~= worldId then
		state.world = worldId
		state.since = os.clock()
	end
end

--[[
	Folds time per world (Sessions.flushActivity every flush, Sessions.endSession at leave). If the
	server-set CurrentWorld attribute names another world than the one being clocked (a trip that
	skipped travelled()), the clock switches to it from now on.
]]
function WorldRecorders.fold(player: Player)
	local state = stateOf(player)
	if state == nil then
		return
	end
	local current = attributeWorld(player)
	if current ~= nil and current ~= state.world then
		switchWorld(player, state, current)
	else
		foldSeconds(player, state)
	end
end

--------------------------------------------------------------------------------------------------
-- Unlock, popup, portal, travel
--------------------------------------------------------------------------------------------------

--[[
	A world was unlocked (sticky; WorldService.unlock success path, once per player per world).
	@param source "area" | "rebirth" | "legacy" | "admin"
	Example: WorldRecorders.unlocked(player, "dino", "area")
]]
WorldRecorders.unlocked = guard("worldUnlocked", function(player: Player, worldId: string, source: string)
	local def = extraWorld(worldId)
	if def == nil then
		count("core", BAD_KEY)
		return
	end
	count("worlds", `unlock:{def.id}`)
	if type(source) == "string" and UNLOCK_SOURCES[source] then
		count("worlds", `unlockSrc:{def.id}:{source}`)
	else
		count("core", BAD_KEY)
	end
	markStep(player, def, "unlocked")
end)

--[[
	A WORLD UNLOCKED popup claim from the client (Sessions.onFunnelStep "worldPopup"). Untrusted:
	exact allowlists, capped per session per world and action (PopupSessionCap).
	@return true when counted
	Example: WorldRecorders.popupClaim(player, "dino", "go")
]]
function WorldRecorders.popupClaim(player: Player, rawWorld: unknown, rawAction: unknown): boolean
	local def = extraWorld(rawWorld)
	if def == nil or type(rawAction) ~= "string" or not POPUP_ACTIONS[rawAction] then
		return false
	end
	local state = stateOf(player)
	if state == nil or Runtime.isExcluded(player) then
		return false
	end
	local id = `{def.id}:{rawAction}`
	local used = state.popups[id] or 0
	if used >= worldsConfig.PopupSessionCap then
		return false
	end
	state.popups[id] = used + 1
	count("worlds", `popup:{id}`)
	return true
end

--[[
	A locked Time Machine portal was used (touch volume / prompt). Throttled per player and world
	(PortalLockedCooldown) so a player standing in the swirl counts once.
	Example: WorldRecorders.portalLocked(player, "dino")
]]
WorldRecorders.portalLocked = guard("worldPortalLocked", function(player: Player, worldId: string)
	local def = extraWorld(worldId)
	local state = stateOf(player)
	if def == nil or state == nil then
		return
	end
	local now = os.clock()
	local last = state.portalAt[def.id]
	if last ~= nil and now - last < worldsConfig.PortalLockedCooldown then
		return
	end
	state.portalAt[def.id] = now
	count("worlds", `portalLocked:{def.id}`)
end)

-- Counts "visitor:<world>" once per player per UTC day: the profile's unique-surface bit
-- "w_<id>" (across servers, also core "uniq:w_<id>"); per session per day if the surface is
-- missing from AnalyticsConfig.Unique.Surfaces.
local function markVisitor(player: Player, state: WorldSession, def: WorldDef)
	local today = Recorder.today()
	if state.visits[def.id] == today then
		return
	end
	state.visits[def.id] = today
	local surface = `w_{def.id}`
	if not SURFACES[surface] then
		count("worlds", `visitor:{def.id}`)
		return
	end
	local data, profile = Runtime.dataOf(player)
	if data == nil or not Runtime.canMark(player, profile) then
		return
	end
	if AnalyticsMarks.markSeen(data, today, surface) then
		count("core", AnalyticsMarks.uniqueKey(surface))
		count("worlds", `visitor:{def.id}`)
		Runtime.saveMarks(player)
	end
end

--[[
	The player arrived in a world (WorldService.travel success, after CurrentWorld is set).
	@param worldId    destination ("main" = back to Nuke Town)
	@param source     "portal" | "menu" | "popup" | "chip" | "admin" | "respawn"
	@param firstVisit true when this is the player's first ever visit (WorldService's stats.visits
	                  was 0 before this trip); counts firstVisit + funnel "firstTravel"
	Example: WorldRecorders.travelled(player, "dino", "menu", false)
]]
WorldRecorders.travelled = guard(
	"worldTravelled",
	function(player: Player, worldId: string, source: string, firstVisit: boolean?)
		local def = WorldsConfig.get(worldId)
		local state = stateOf(player)
		if def == nil then
			count("core", BAD_KEY)
			return
		end
		if state ~= nil then
			switchWorld(player, state, def.id)
		end
		if type(source) == "string" and TRAVEL_SOURCES[source] then
			count("worlds", `travel:{def.id}:{source}`)
		else
			count("core", BAD_KEY)
		end
		if def.id == MAIN then
			return
		end
		if state ~= nil then
			markVisitor(player, state, def)
		end
		if firstVisit == true then
			count("worlds", `firstVisit:{def.id}`)
			markStep(player, def, "firstTravel")
		end
	end
)

--[[
	A travel request was refused (TravelRules reason). Unknown world ids count as "unknown"; a
	reason outside AnalyticsConfig.Worlds.TravelReasons folds into "other" (never refused).
	Example: WorldRecorders.travelFailed(player, "dino", "locked")
]]
WorldRecorders.travelFailed = guard("worldTravelFailed", function(_player: Player, worldId: unknown, reason: unknown)
	local def = WorldsConfig.get(worldId)
	local world = if def ~= nil then def.id else worldsConfig.UnknownWorld
	local why = if type(reason) == "string" and TRAVEL_REASONS[reason] then reason else "other"
	count("worlds", `travelFail:{world}:{why}`)
end)

--------------------------------------------------------------------------------------------------
-- The world tycoon run
--------------------------------------------------------------------------------------------------

-- First-run area reach of a world (deduped per session per run).
local function reachArea(player: Player, def: WorldDef, area: number)
	local n = AnalyticsLogic.integerIn(area, 1, #def.economy.Areas)
	if n == nil then
		count("core", BAD_KEY)
		return
	end
	local state = stateOf(player)
	if state ~= nil then
		local seen = state.areas[def.id]
		if seen == nil then
			seen = {}
			state.areas[def.id] = seen
		end
		if seen[n] then
			return
		end
		seen[n] = true
	end
	count("worlds", `area:{def.id}:{n}`)
	if rebirthsIn(player, def.id) == 0 then
		local seconds = runSecondsIn(player, def.id)
		count("worlds", `areaN:{def.id}:{n}`)
		count("worlds", `areaAt:{def.id}:{n}`, seconds)
		count(
			"worlds",
			`areaB:{def.id}:{n}:{AnalyticsLogic.bucketOf(seconds / 60, tycoonConfig.AreaMinuteBuckets, "m")}`
		)
		if n >= 2 then
			markStep(player, def, `area{n}`)
		end
	end
	local live = Runtime.livePlayer(player)
	if live ~= nil then
		Runtime.forwarder.progression(live, def.name, n)
	end
end

--[[
	An area of an extra world opened (TycoonService.WorldAreaReached; an Unlock pad bought through
	padBought reports it too — deduped per session per run).
	Example: WorldRecorders.areaReached(player, "dino", 3)
]]
WorldRecorders.areaReached = guard("worldAreaReached", function(player: Player, worldId: string, area: number)
	local def = extraWorld(worldId)
	if def == nil then
		count("core", BAD_KEY)
		return
	end
	reachArea(player, def, area)
end)

-- Number of owned pads of `kind` in a world (≤ the world's pad count; Manager-step check).
local function ownedOfKind(player: Player, def: WorldDef, kind: string): number
	local n = 0
	for padId in padsIn(player, def.id) do
		local pad = if type(padId) == "string" then def.economy.PadsById[padId] else nil
		if pad ~= nil and pad.kind == kind then
			n += 1
		end
	end
	return n
end

-- Number of owned pads of a world.
local function ownedPads(player: Player, def: WorldDef): number
	local n = 0
	for _ in padsIn(player, def.id) do
		n += 1
	end
	return n
end

--[[
	A pad of an extra world was bought (Recorders.padBought routes it here; the purchase is already
	applied). Counts tycoon pad / padKind / padSkip / first-run padN + padAt (that world's run
	seconds) / manager, worlds padArea, the funnel steps firstPad / manager / finale, and the area
	an Unlock pad opens.
]]
function WorldRecorders.padBought(player: Player, def: WorldDef, padId: string, skipped: boolean?)
	local pad = def.economy.PadsById[padId]
	if pad == nil then
		count("core", "ops:badKey:tycoon")
		return
	end
	count("tycoon", `pad:{padId}`)
	count("tycoon", `padKind:{pad.kind}`)
	count("worlds", `padArea:{def.id}:{pad.area}`)
	if skipped == true then
		count("tycoon", `padSkip:{padId}`)
	end
	local firstRun = rebirthsIn(player, def.id) == 0
	if firstRun then
		count("tycoon", `padN:{padId}`)
		count("tycoon", `padAt:{padId}`, runSecondsIn(player, def.id))
		if ownedPads(player, def) <= 1 then
			markStep(player, def, "firstPad")
		end
	end
	local live = Runtime.livePlayer(player)
	if live ~= nil then
		Runtime.forwarder.custom(live, "PadBought", 1, padId, tostring(pad.area))
	end
	if pad.kind == "Manager" then
		local target = pad.target
		if type(target) == "string" and def.economy.ProducersById[target] ~= nil then
			count("tycoon", `manager:{target}`)
		end
		if firstRun and ownedOfKind(player, def, "Manager") <= 1 then
			markStep(player, def, "manager")
		end
		if live ~= nil then
			Runtime.forwarder.custom(live, "ManagerHired", 1, padId)
		end
	end
	if firstRun and padId == def.economy.FinalePadId then
		markStep(player, def, "finale")
	end
	if pad.kind == "Unlock" and type(pad.unlocks) == "number" then
		reachArea(player, def, pad.unlocks)
	end
end

-- Memoized per-producer keys (producer ids are a fixed config set).
type ProducerKeys = { click: string, incomeClick: string, incomeAuto: string, worldClick: string, worldAuto: string }
local producerKeys: { [string]: ProducerKeys } = {}

local function keysOf(def: WorldDef, producerId: string): ProducerKeys
	local keys = producerKeys[producerId]
	if keys == nil then
		keys = {
			click = `click:{producerId}`,
			incomeClick = `incomeP:{producerId}:click`,
			incomeAuto = `incomeP:{producerId}:auto`,
			worldClick = `incomeW:{def.id}:click`,
			worldAuto = `incomeW:{def.id}:auto`,
		}
		producerKeys[producerId] = keys
	end
	return keys
end

--[[ A producer of an extra world was clicked (Recorders.producerClick routes it here). ]]
function WorldRecorders.producerClick(_player: Player, def: WorldDef, producerId: string)
	if def.economy.ProducersById[producerId] == nil then
		count("core", "ops:badKey:tycoon")
		return
	end
	count("tycoon", keysOf(def, producerId).click)
end

--[[
	A producer of an extra world paid out (Recorders.producerIncome routes it here; TycoonAnalytics
	batches it): tycoon incomeP per producer + worlds incomeW click / auto share.
]]
function WorldRecorders.producerIncome(def: WorldDef, producerId: string, amount: number, automated: boolean)
	if def.economy.ProducersById[producerId] == nil then
		count("core", "ops:badKey:tycoon")
		return
	end
	local keys = keysOf(def, producerId)
	if automated == true then
		count("tycoon", keys.incomeAuto, amount)
		count("worlds", keys.worldAuto, amount)
	else
		count("tycoon", keys.incomeClick, amount)
		count("worlds", keys.worldClick, amount)
	end
end

--[[ A producer of an extra world was upgraded (Recorders.producerUpgraded routes it here). ]]
function WorldRecorders.producerUpgraded(
	def: WorldDef,
	producerId: string,
	fromLevel: number,
	toLevel: number,
	mode: string?
)
	local maxLevel = def.economy.MaxLevel
	local from = AnalyticsLogic.integerIn(fromLevel, 0, maxLevel)
	local to = AnalyticsLogic.integerIn(toLevel, 0, maxLevel)
	if def.economy.ProducersById[producerId] == nil or from == nil or to == nil or to <= from then
		count("core", "ops:badKey:tycoon")
		return
	end
	count("tycoon", `upgrade:{producerId}`)
	count("tycoon", `levels:{producerId}`, to - from)
	if mode ~= nil and table.find(tycoonConfig.UpgradeModes, mode) ~= nil then
		count("tycoon", `upgradeMode:{mode}`)
	end
	for _, mark in tycoonConfig.LevelMarks do
		if from < mark and mark <= to then
			count("tycoon", `lvl:{producerId}:{mark}`)
		end
	end
end

--[[
	The player rebirthed in an extra world (RebirthService.WorldRebirthed).
	@param rebirthsAfter the world's rebirth count now (≥ 1)
	@param tokens        the world's rebirth tokens granted (Amber), optional
	Example: WorldRecorders.rebirthed(player, "dino", 1, 14)
]]
WorldRecorders.rebirthed = guard(
	"worldRebirthed",
	function(player: Player, worldId: string, rebirthsAfter: number, tokens: number?)
		local def = extraWorld(worldId)
		local after = AnalyticsLogic.integerIn(rebirthsAfter, 1, 1e9)
		if def == nil or after == nil then
			count("core", BAD_KEY)
			return
		end
		count("worlds", `rebirth:{def.id}`)
		count("worlds", `rebirthN:{def.id}:{AnalyticsLogic.countBucket(after, tycoonConfig.RebirthBuckets)}`)
		if type(tokens) == "number" and tokens == tokens and tokens > 0 and tokens < 1e15 then
			count("worlds", `tokens:{def.id}`, tokens)
		end
		if after == 1 then
			markStep(player, def, "rebirth")
		end
		-- New run: this world's areas can be reached (and counted) again.
		local state = stateOf(player)
		if state ~= nil then
			state.areas[def.id] = nil
		end
		local live = Runtime.livePlayer(player)
		if live ~= nil then
			Runtime.forwarder.progression(live, `{def.name} Rebirth`, after)
		end
	end
)

--[[
	A world rebirth-shop upgrade was bought (Dino: the Amber shop).
	Example: WorldRecorders.rebirthShop(player, "dino", "boneBoost")
]]
WorldRecorders.rebirthShop = guard("worldRebirthShop", function(_player: Player, worldId: string, upgradeKey: string)
	local def = extraWorld(worldId)
	if def == nil or type(upgradeKey) ~= "string" or def.rebirth.Shop[upgradeKey] == nil then
		count("core", BAD_KEY)
		return
	end
	count("worlds", `rebirthShop:{def.id}:{upgradeKey}`)
end)

--[[
	An extra world's offline payout on join (`seconds` credited, `amount` of its currency paid).
	Example: WorldRecorders.offlinePaid(player, "dino", 7200, 5e4)
]]
WorldRecorders.offlinePaid = guard(
	"worldOfflinePaid",
	function(_player: Player, worldId: string, seconds: number, amount: number)
		local def = extraWorld(worldId)
		if def == nil then
			count("core", BAD_KEY)
			return
		end
		if type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 or seconds > 1e7 then
			return
		end
		count("worlds", `offline:{def.id}:pay`)
		count("worlds", `offlineSec:{def.id}`, math.floor(seconds))
		if type(amount) == "number" and amount == amount and amount > 0 and amount ~= math.huge then
			count("worlds", `incomeW:{def.id}:offline`, amount)
		end
	end
)

--[[ An extra world's offline payout was doubled with the DOUBLE IT! product. ]]
WorldRecorders.offlineDoubled = guard("worldOfflineDoubled", function(_player: Player, worldId: string)
	local def = extraWorld(worldId)
	if def == nil then
		count("core", BAD_KEY)
		return
	end
	count("worlds", `offline:{def.id}:double`)
end)

--------------------------------------------------------------------------------------------------
-- Economy: batched world-currency income for Roblox's economy dashboard
--------------------------------------------------------------------------------------------------

-- Extra-world CURRENCY keys (not their rebirth tokens) → world id ("bones" → "dino").
local INCOME_CURRENCY: { [string]: string } = {}
for _, def in WorldsConfig.extra() do
	INCOME_CURRENCY[def.currency.key] = def.id
end

--[[
	Batches an unmapped earning of an extra world's currency (producer ticks, mostly) so Roblox gets
	ONE economy Source per player per flush, like Nuke Town cash.
	@return true when batched (false = not an extra world's currency: the caller forwards it)
]]
function WorldRecorders.batchIncome(player: Player, currency: string, delta: number): boolean
	if INCOME_CURRENCY[currency] == nil then
		return false
	end
	local state = stateOf(player)
	if state == nil then
		return true
	end
	state.income[currency] = math.min(1e300, (state.income[currency] or 0) + delta)
	return true
end

--[[ Forwards the player's batched world-currency income (Sessions.flushActivity). ]]
function WorldRecorders.flushIncome(player: Player)
	local info = Runtime.sessions[player]
	local state = if info ~= nil then states[info] else nil
	if state == nil or next(state.income) == nil then
		return
	end
	local live = Runtime.livePlayer(player)
	for currency, amount in state.income do
		state.income[currency] = nil
		local worldId = INCOME_CURRENCY[currency]
		local world = if worldId ~= nil then worldStateOf(player, worldId) else nil
		local balance = if world ~= nil
				and type(world.cash) == "number"
				and world.cash == world.cash
			then world.cash
			else 0
		if live ~= nil and amount > 0 then
			Runtime.forwarder.economy(
				live,
				"Source",
				AnalyticsConfig.Economy.CurrencyNames[currency] or currency,
				amount,
				balance,
				"Gameplay",
				AnalyticsConfig.Economy.BatchedIncomeSku
			)
		end
	end
end

return table.freeze(WorldRecorders)
