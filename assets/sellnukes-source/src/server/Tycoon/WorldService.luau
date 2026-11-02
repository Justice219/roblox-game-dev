--!strict
--[[
	WorldService — where every player IS (which world), which worlds they have UNLOCKED, and the
	ONE server-authoritative travel pipeline between worlds (owner R57 World 2 "Dino Valley";
	spec §4, §5, §11, §13, §17; plan §3.4).

	Unlock (sticky, spec §4.1)
		Each extra world's WorldsConfig unlock rule (Dino Valley: Nuke Town area 3 OR 1 Nuke Town
		rebirth) is evaluated on ProfileLoaded ("legacy" source: players who already qualify unlock
		on their first load of the update), on TycoonService.AreaReached / WorldAreaReached
		("area") and on RebirthService.Rebirthed / WorldRebirthed ("rebirth"). The first pass sets
		profile.worlds[w].unlocked = true + unlockedAt = os.time() (the client's WORLD UNLOCKED
		popup reads it), saves soon, fires Unlocked and starts that world's idle runtime
		(TycoonService.ensureWorld(player, w, false)). A later Nuke Town rebirth (area back to 1)
		never re-locks. Admin: unlock / relock (re-test the popup).

	Travel (spec §4.5) — TravelWorld(worldId, target, index?, source?) and every server caller
		1. Validate.travelRequest + RateLimiter(3, 0.5) (packets that fail are dropped silently).
		2. TravelRules.check (enabled, unlocked, plot, reveal, alive, busy, cooldown, area / plot).
		   Refusal → WorldTravel { phase = "fail", reason } (the client toasts FailText).
		3. busy; WorldTravel { phase = "out" } (client warp overlay + preload).
		4. In parallel, under the 4 s deadline: the destination world's runtime + plot build for the
		   player (and the visited owner for target "plot"), RequestStreamAroundAsync(dest, 3) and
		   the CoverSeconds overlay fade. The deadline pivots anyway — nobody is stranded.
		5. Re-checks after the yields (still here, same profile, alive, world still enabled, plot
		   owner unchanged), unseats the character, pivots it to the SERVER-computed CFrame, sets
		   the Player attribute CurrentWorld + profile.lastWorld, counts the visit, fires
		   WorldChanged, WorldTravel { phase = "in" } and the analytics.
		The destination is never taken from the client: "spawn" = that world's hub spawn (or the
		Time Machine's arrive spot when travelling by portal), "area" = the player's OWN plot area
		N, "plot" = plot N's entrance (own plot free; others need the Teleporter pass).

	Respawn / rejoin (spec §4.6)
		respawnCFrame(player): a character respawning in a non-main world goes to the entrance of
		its plot IN THAT WORLD (PlotService asks first, then streams + pivots). Rejoin always starts
		in the Nuke Town lobby (CurrentWorld = "main" at join); profile.lastWorld (written on every
		travel and on ProfileReleasing / ProfileUnloading) drives the client's "Back to Dino
		Valley?" chip. Travel is refused until PlotRevealed, so the R16 join reveal is never skipped.

	Kill switch (spec §13 / §17)
		setEnabled(worldId, false) sets ReplicatedStorage attribute WorldEnabled_<id> = false,
		refuses travel into it and sends everyone inside back to the Nuke Town lobby with a toast.
		Runtimes keep earning (it only blocks travel and building).

	Portals (spec §4.4)
		The lobby Time Machine (HubBuilder.getWorldPortal(w, "main")) and each world's return portal
		(getWorldPortal(w, "world")) have a ProximityPrompt + a touch volume; both go through
		travel() with source "portal". A locked lobby portal answers with a throttled "locked"
		failure (toast + the client's locked preview) and analytics portalLocked.

	Stats: worlds.<w>.stats.visits / lastVisitDay on arrival; playSeconds / runSeconds by ONE 1 Hz
	loop over the players inside a non-main world (saved by the regular autosave, no push).

	API
		currentWorld(player): string                     server truth ("main" default)
		isUnlocked(player, worldId): boolean             never yields (MonetizationService seam)
		unlock(player, worldId, source): boolean         source "area" | "rebirth" | "legacy" | "admin"
		relock(player, worldId): boolean                 admin re-test of the popup flow
		travel(player, worldId, target, index?, source): (boolean, string?)   yields
		adminSend(player, worldId, "spawn" | "plot")     admin WorldSend (own plot; cooldown skipped)
		sendHome(player, toast?)                         straight to the Nuke Town lobby (kill switch)
		respawnCFrame(player): CFrame?                   nil = Nuke Town (PlotService default)
		isEnabled(worldId) / setEnabled(worldId, on)     kill switch
		playersIn(worldId): { Player }                   admin Live tab
		Unlocked: Signal(player, worldId)                WorldChanged: Signal(player, worldId, previous)

	Connects to: Tycoon/TravelRules (pure gate), Tycoon/PlotService (plot index, teleport, world
	hooks), Tycoon/TycoonService (ensureWorld, AreaReached, WorldAreaReached), Tycoon/RebirthService
	(Rebirthed, WorldRebirthed), World/HubBuilder (spawns, portals), World/PlotBuilder (world plot
	entrances / area spawns), Services/PlayerDataService, Services/MonetizationService
	(setWorldUnlockCheck, Teleporter pass), Tycoon/TycoonAnalytics → AnalyticsService world*
	recorders, Admin/Handlers/MultiWorldHandlers (admin commands via Admin/Seams.worldService).

	Boot: server feature list "Tycoon/WorldService" right after "Tycoon/RebirthService".

	Usage
		local ok, reason = WorldService.travel(player, "dino", "area", 2, "admin")
		if WorldService.currentWorld(player) == "dino" then ... end
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local HubBuilder = require(script.Parent.Parent.World.HubBuilder)
local MonetizationService = require(script.Parent.Parent.Services.MonetizationService)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)
local PlotService = require(script.Parent.PlotService)
local ProgressEvents = require(script.Parent.Parent.Progression.ProgressEvents)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local RebirthService = require(script.Parent.RebirthService)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TravelRules = require(script.Parent.TravelRules)
local TycoonAnalytics = require(script.Parent.TycoonAnalytics)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonService = require(script.Parent.TycoonService)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WorldLayout = require(ReplicatedStorage.Shared.Config.WorldLayout)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

export type TravelTarget = TravelRules.TravelTarget
export type TravelSource = TravelRules.TravelSource
export type UnlockSource = TravelRules.UnlockSource

local WorldService = {}

WorldService.Unlocked = Signal.new() :: Signal.Signal<Player, string>
WorldService.WorldChanged = Signal.new() :: Signal.Signal<Player, string, string>

-- ReplicatedStorage attribute prefix of the kill switch (WorldClientConfig.EnabledAttrPrefix).
WorldService.EnabledAttrPrefix = "WorldEnabled_"
-- Player attribute holding the world the player is in (WorldClient reads it).
WorldService.CurrentAttr = "CurrentWorld"
-- Extra studs of tolerance on a portal prompt's MaxActivationDistance (server-side range check).
WorldService.PromptSlack = 8
-- Seconds after an arrival during which portal TOUCHES are ignored for that player (the arrive
-- spot sits next to the Time Machine; walking off it must never bounce them straight back).
WorldService.ArrivalTouchGrace = 3
-- Toast when the kill switch sends a player home.
WorldService.EvacuateText = "%s is closed for a quick fix - back soon! You're home in Nuke Town."

local MAIN = WorldsConfig.MAIN
-- Sources a CLIENT may claim on TravelWorld (analytics only); anything else counts as "menu".
local CLIENT_SOURCES: { [string]: boolean } = { menu = true, popup = true, chip = true }

-- Where each player is (absent = "main").
local current: { [Player]: string } = {}
-- The world each player's session ends in (written to profile.lastWorld on ProfileReleasing). Kept
-- apart from `current` on purpose: PlayerRemoving clears `current` at once, and on some exits
-- (Studio stop, shutdown) ProfileReleasing fires AFTER it — the lastWorld must still be right.
local endWorld: { [Player]: string } = {}
-- Travel token of the player's in-flight travel (absent = not busy).
local busyToken: { [Player]: number } = {}
local tokenSeq = 0
-- os.clock() before which the player's next travel is refused (TravelRules cooldown).
local cooldownUntil: { [Player]: number } = {}
-- os.clock() of the player's last arrival (portal touch grace).
local arrivedAt: { [Player]: number } = {}
-- os.clock() of the player's last "locked portal" answer per world (toast throttle).
local lockedAt: { [Player]: { [string]: number } } = {}
-- Remote / prompt / touch limiters (per player).
local travelLimiter = RateLimiter.new(TravelRules.RateBurst, TravelRules.RateRefill)
local promptLimiter = RateLimiter.new(3, 1)
local touchLimiter = RateLimiter.new(4, 2)
local started = false

--------------------------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------------------------

-- The world definition of an id, or nil.
local function defOf(worldId: unknown): WorldsConfig.WorldDef?
	return WorldsConfig.get(worldId)
end

-- The analytics seam (guarded; never throws, never yields).
local function record(name: string, ...: any)
	TycoonAnalytics.call(name, ...)
end

-- The living character parts of a player, or nil.
local function aliveParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if character == nil then
		return nil, nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") or humanoid.Health <= 0 then
		return nil, nil, nil
	end
	return character, humanoid, root
end

--[[
	A world's plot builder (Nuke Town: the module API; others: PlotBuilder.world(id)), or nil when
	that world has no builder yet (guarded so a builder error never breaks travel).
]]
local function builderOf(worldId: string): any
	local ok, builder = pcall(PlotBuilder.world, worldId)
	return if ok then builder else nil
end

--[[
	Ground-level CFrame of plot `index`'s entrance in `worldId` (the arrival + respawn spot).
	Falls back to the shared geometry when the world's builder is not available.
]]
local function plotEntrance(worldId: string, index: number): CFrame
	if worldId == MAIN then
		return PlotService.entrance(index)
	end
	local builder = builderOf(worldId)
	if builder ~= nil and type(builder.entrance) == "function" then
		local ok, cf = pcall(builder.entrance, index)
		if ok and typeof(cf) == "CFrame" then
			return cf
		end
	end
	return WorldLayout.entranceSpawn(index, worldId)
end

--[[
	Ground-level CFrame a travel to area `area` of plot `index` in `worldId` lands on (the area
	layout's spawn point, facing the area). Fallback: 8 studs into the slot, facing inward.
]]
local function areaSpawn(worldId: string, index: number, area: number): CFrame
	local builder = builderOf(worldId)
	if builder ~= nil and type(builder.areaSpawn) == "function" then
		local ok, cf = pcall(builder.areaSpawn, index, area)
		if ok and typeof(cf) == "CFrame" then
			return cf
		end
	end
	local slot = WorldLayout.slotOrigin(index, area, worldId)
	local at = slot * Vector3.new(0, 0, 8)
	local look = slot * Vector3.new(0, 0, 18)
	return CFrame.lookAt(at, Vector3.new(look.X, at.Y, look.Z))
end

--[[
	Ground-level CFrame of a world's "spawn" target. By portal: the Time Machine's arrive spot of
	the portal the player comes OUT of (Nuke Town: the lobby machine of the world they leave; an
	extra world: its return portal). Otherwise the world's hub spawn.
]]
local function spawnOf(worldId: string, fromWorld: string, source: TravelSource): CFrame
	if source == "portal" then
		local portal = if worldId == MAIN
			then HubBuilder.getWorldPortal(fromWorld, "main")
			else HubBuilder.getWorldPortal(worldId, "world")
		if portal ~= nil then
			return portal.arrive
		end
	end
	return HubBuilder.spawnCFrame(if worldId == MAIN then nil else worldId)
end

-- The tycoon state of a player in a world (Nuke Town: profile.tycoon), or nil.
local function tycoonOf(profile: any, worldId: string): any
	if worldId == MAIN then
		return profile.tycoon
	end
	local state = ProfileLogic.peekWorld(profile, worldId)
	return if state ~= nil then state.tycoon else nil
end

-- Sends one WorldTravel event (cosmetic) to a player.
local function sendPhase(player: Player, worldId: string, phase: "out" | "in" | "fail", reason: string?)
	if player.Parent ~= Players then
		return
	end
	Remotes.fireClient("WorldTravel", player, {
		worldId = worldId,
		phase = phase,
		reason = reason,
		at = Workspace:GetServerTimeNow(),
	})
end

-- A refused travel: tell the client (toast) and count it.
local function refuse(player: Player, worldId: string, reason: string)
	sendPhase(player, worldId, "fail", reason)
	record("worldTravelFailed", player, worldId, reason)
end

--[[
	Runs `jobs` in parallel and waits until every one finished or `seconds` passed (whichever comes
	first). Job errors are warned, never thrown. The jobs keep running after a timeout.
	@return true when all finished in time
]]
local function runWithDeadline(jobs: { () -> () }, seconds: number): boolean
	if #jobs == 0 then
		return true
	end
	local thread = coroutine.running()
	local remaining = #jobs
	local resolved = false
	local waiting = false
	local result = true
	local function finish(ok: boolean)
		if resolved then
			return
		end
		resolved = true
		result = ok
		if waiting then
			task.spawn(thread, ok)
		end
	end
	for _, job in jobs do
		task.spawn(function()
			local ok, problem = pcall(job)
			if not ok then
				warn(`[WorldService] travel step failed: {problem}`)
			end
			remaining -= 1
			if remaining == 0 then
				finish(true)
			end
		end)
	end
	if resolved then
		return result
	end
	local timer = task.delay(seconds, finish, false)
	waiting = true
	local ok = coroutine.yield()
	if coroutine.status(timer) == "suspended" then
		task.cancel(timer)
	end
	return ok == true
end

-- Gets the character out of any seat (vehicles, benches) before a pivot.
local function unseat(humanoid: Humanoid)
	local seat = humanoid.SeatPart
	if seat ~= nil then
		local weld = seat:FindFirstChild("SeatWeld")
		if weld ~= nil then
			weld:Destroy()
		end
	end
	humanoid.Sit = false
end

--------------------------------------------------------------------------------------------------
-- Where am I / unlocked / enabled
--------------------------------------------------------------------------------------------------

--[[
	The world a player is in right now (server truth; mirrored in Player attribute CurrentWorld).
	@return string — "main" by default
]]
function WorldService.currentWorld(player: Player): string
	return current[player] or MAIN
end

--[[
	True when `worldId` is unlocked for the player: Nuke Town always; another world once its sticky
	profile flag is set (unlock()). Never yields (MonetizationService's prompt gate calls it).
	Unknown worlds / no profile → false.
]]
function WorldService.isUnlocked(player: Player, worldId: string): boolean
	local def = defOf(worldId)
	if def == nil then
		return false
	end
	if def.id == MAIN then
		return true
	end
	local profile = PlayerDataService.getProfile(player)
	return profile ~= nil and TravelRules.isUnlocked(def, profile)
end

--[[ True unless the admin kill switch turned the world off (Nuke Town can never be off). ]]
function WorldService.isEnabled(worldId: string): boolean
	local def = defOf(worldId)
	if def == nil then
		return false
	end
	if def.id == MAIN then
		return true
	end
	return ReplicatedStorage:GetAttribute(WorldService.EnabledAttrPrefix .. def.id) ~= false
end

--[[ Every online player currently in `worldId` (admin Live tab / kill switch). ]]
function WorldService.playersIn(worldId: string): { Player }
	local list: { Player } = {}
	for _, player in Players:GetPlayers() do
		if WorldService.currentWorld(player) == worldId then
			table.insert(list, player)
		end
	end
	return list
end

--[[
	Records that a player is now in `worldId`: attribute, lastWorld, visit counters, signal,
	analytics. `source` nil = a silent reset (join, swap, evacuation without a trip).
]]
local function setCurrent(player: Player, worldId: string, source: TravelSource?)
	local previous = WorldService.currentWorld(player)
	current[player] = if worldId == MAIN then nil else worldId
	endWorld[player] = worldId
	if player.Parent == Players then
		player:SetAttribute(WorldService.CurrentAttr, worldId)
	end
	local profile = PlayerDataService.getProfile(player)
	local firstVisit = false
	if profile ~= nil then
		local fields = { "lastWorld" }
		profile.lastWorld = worldId
		if worldId ~= MAIN and previous ~= worldId and source ~= nil then
			local state = ProfileLogic.peekWorld(profile, worldId)
			if state ~= nil then
				local _, firstEver = TravelRules.recordVisit(state.stats, TravelRules.dayOf(os.time()))
				firstVisit = firstEver
				table.insert(fields, "worlds")
			end
		end
		PlayerDataService.markChanged(player, false, fields)
	end
	if source ~= nil then
		record("worldTravelled", player, worldId, source, firstVisit)
	end
	if previous ~= worldId then
		WorldService.WorldChanged:Fire(player, worldId, previous)
	end
end

--------------------------------------------------------------------------------------------------
-- Unlock
--------------------------------------------------------------------------------------------------

-- Starts the idle runtime of every unlocked extra world of a player (no plot build; spec §5).
local function ensureRuntimes(player: Player)
	for _, def in WorldsConfig.extra() do
		if WorldService.isUnlocked(player, def.id) then
			task.spawn(function()
				local ok, problem = pcall(TycoonService.ensureWorld, player, def.id, false)
				if not ok then
					warn(`[WorldService] ensureWorld({def.id}) failed: {problem}`)
				end
			end)
		end
	end
end

--[[
	Unlocks a world for a player (sticky). Sets unlocked + unlockedAt, saves soon, fires Unlocked,
	counts the analytics and starts the world's idle runtime. False when already unlocked, the
	world is Nuke Town / unknown, or no profile is loaded.
	@param source "area" | "rebirth" | "legacy" | "admin"
	Example: WorldService.unlock(player, "dino", "admin") --> true
]]
function WorldService.unlock(player: Player, worldId: string, source: UnlockSource): boolean
	local def = defOf(worldId)
	local profile = PlayerDataService.getProfile(player)
	if def == nil or def.id == MAIN or profile == nil or TravelRules.isUnlocked(def, profile) then
		return false
	end
	local state = ProfileLogic.worldState(profile, def.id)
	state.unlocked = true
	state.unlockedAt = os.time()
	PlayerDataService.markChanged(player, true, { "worlds" })
	record("worldUnlocked", player, def.id, source)
	ProgressEvents.progress(player, "world") -- R78 Quests / Pass: a world unlocked
	WorldService.Unlocked:Fire(player, def.id)
	if PlotService.getPlotIndex(player) ~= nil then
		ensureRuntimes(player)
	end
	return true
end

--[[
	Admin re-test of the unlock flow: clears the sticky flag (unlockedAt 0). A player inside that
	world is sent home first. The rule unlocks it again on the next area / rebirth / load event
	(or the admin WorldUnlock). The world's runtime is dropped and its plot cleared
	(TycoonService.releaseWorld); its saved data is untouched.
	@return boolean — false when it was not unlocked
]]
function WorldService.relock(player: Player, worldId: string): boolean
	local def = defOf(worldId)
	local profile = PlayerDataService.getProfile(player)
	if def == nil or def.id == MAIN or profile == nil or not TravelRules.isUnlocked(def, profile) then
		return false
	end
	if WorldService.currentWorld(player) == def.id then
		WorldService.sendHome(player, nil)
	end
	local state = ProfileLogic.worldState(profile, def.id)
	state.unlocked = false
	state.unlockedAt = 0
	PlayerDataService.markChanged(player, true, { "worlds" })
	-- A locked world never earns: drop its runtime + clear its plot (data untouched; the next
	-- unlock restarts it through ensureRuntimes).
	local ok, problem = pcall(TycoonService.releaseWorld, player, def.id)
	if not ok then
		warn(`[WorldService] releaseWorld({def.id}) failed: {problem}`)
	end
	return true
end

--[[
	Evaluates every extra world's unlock rule for a player and unlocks the ones that now pass.
	@param event "load" | "area" | "rebirth" — picks the analytics source
]]
local function evaluate(player: Player, event: TravelRules.UnlockEvent)
	local profile = PlayerDataService.getProfile(player)
	if profile == nil then
		return
	end
	for _, def in WorldsConfig.extra() do
		if TravelRules.shouldUnlock(def, profile) then
			local source = TravelRules.unlockSource(def, TravelRules.progress(profile), event)
			WorldService.unlock(player, def.id, source)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Travel
--------------------------------------------------------------------------------------------------

-- The TravelRules context of a request (server facts only).
local function contextOf(player: Player, worldId: string, target: string, index: number?, source: TravelSource): any
	local def = defOf(worldId)
	local profile = PlayerDataService.getProfile(player)
	local plotIndex = PlotService.getPlotIndex(player)
	local _, _, root = aliveParts(player)
	local ctx: { [string]: any } = {
		worldId = worldId,
		target = target,
		index = index,
		now = os.clock(),
		enabled = WorldService.isEnabled(worldId),
		unlocked = WorldService.isUnlocked(player, worldId),
		hasPlot = plotIndex ~= nil,
		revealed = player:GetAttribute("PlotRevealed") == true,
		alive = root ~= nil,
		busy = busyToken[player] ~= nil,
		-- Admin sends skip the cooldown (testing); everything else is checked.
		cooldownUntil = if source == "admin" then -math.huge else (cooldownUntil[player] or -math.huge),
		hasTeleporter = false,
		areaCount = if def ~= nil then def.geometry.areaCount else 0,
	}
	if target == "area" and profile ~= nil and index ~= nil and def ~= nil then
		local tycoon = tycoonOf(profile, def.id)
		local ok, unlocked = pcall(function(): boolean
			return tycoon ~= nil and TycoonLogic.forWorld(def.id).areaUnlocked(tycoon, index)
		end)
		ctx.areaUnlocked = ok and unlocked == true
	elseif target == "plot" and index ~= nil then
		local owner = PlotService.getOwner(index)
		ctx.plotOwned = owner ~= nil
		ctx.ownPlot = owner == player
		ctx.hasTeleporter = owner ~= nil and owner ~= player and MonetizationService.ownsPass(player, "Teleporter")
	end
	return ctx
end

-- The destination of a validated request (ground-level CFrame) + the visited plot owner.
local function destinationOf(
	player: Player,
	worldId: string,
	target: string,
	index: number?,
	source: TravelSource,
	fromWorld: string
): (CFrame?, Player?)
	if target == "spawn" then
		return spawnOf(worldId, fromWorld, source), nil
	end
	if target == "area" then
		local own = PlotService.getPlotIndex(player)
		if own == nil or index == nil then
			return nil, nil
		end
		if worldId == MAIN then
			return PlotBuilder.areaSpawn(own, index), player
		end
		return areaSpawn(worldId, own, index), player
	end
	if index == nil then
		return nil, nil
	end
	local owner = PlotService.getOwner(index)
	if owner == nil then
		return nil, nil
	end
	return plotEntrance(worldId, index), owner
end

-- The world jobs a trip waits for: the player's runtime + plot build (and the visited owner's).
local function buildJobs(player: Player, worldId: string, owner: Player?): { () -> () }
	local jobs: { () -> () } = {}
	if worldId == MAIN then
		return jobs
	end
	local subjects = { player }
	-- A visited owner who never unlocked this world has an empty plot there: nothing to build.
	if owner ~= nil and owner ~= player and WorldService.isUnlocked(owner, worldId) then
		table.insert(subjects, owner)
	end
	for _, subject in subjects do
		table.insert(jobs, function()
			TycoonService.ensureWorld(subject, worldId, true)
		end)
	end
	return jobs
end

-- One accepted trip (between "out" and "in"; see completeTrip).
type Trip = {
	player: Player,
	def: WorldsConfig.WorldDef,
	target: TravelTarget,
	index: number?,
	source: TravelSource,
	fromWorld: string,
	profile: any,
	dest: CFrame,
	owner: Player?,
	token: number,
}

--[[
	The second half of a trip (after "out"): prepare in parallel under the hard deadline (world
	builds, client streaming, the overlay cover), re-check everything the yields could have changed,
	then unseat + pivot + record the arrival. Runs inside travel()'s pcall.
	@return (true, nil) on arrival, else (false, reason) — the client was told
]]
local function completeTrip(trip: Trip): (boolean, string?)
	local player, def, target, index = trip.player, trip.def, trip.target, trip.index
	local jobs = buildJobs(player, def.id, trip.owner)
	local streamAt = trip.dest.Position
	table.insert(jobs, function()
		player:RequestStreamAroundAsync(streamAt, TravelRules.StreamTimeout)
	end)
	table.insert(jobs, function()
		task.wait(TravelRules.CoverSeconds)
	end)
	runWithDeadline(jobs, TravelRules.DeadlineSeconds)

	-- Re-check everything the yields could have changed.
	local function abandon(why: string): (boolean, string?)
		if busyToken[player] == trip.token then
			busyToken[player] = nil
		end
		if player.Parent == Players then
			refuse(player, def.id, why)
		end
		return false, why
	end
	if player.Parent ~= Players or busyToken[player] ~= trip.token then
		-- Left mid-warp, or superseded (sendHome / swap): that path already told the client.
		return false, "busy"
	end
	if PlayerDataService.getProfile(player) ~= trip.profile or PlotService.getPlotIndex(player) == nil then
		return abandon("noPlot")
	end
	if not WorldService.isEnabled(def.id) then
		return abandon("disabled")
	end
	if target == "plot" and index ~= nil and PlotService.getOwner(index) ~= trip.owner then
		return abandon("plotEmpty")
	end
	-- Recomputed after the yields (the world hub / plot frames may have finished building).
	local final, _ = destinationOf(player, def.id, target, index, trip.source, trip.fromWorld)
	local _, humanoid, _ = aliveParts(player)
	if final == nil or humanoid == nil then
		return abandon("dead")
	end
	unseat(humanoid)
	if not PlotService.teleport(player, final) then
		return abandon("dead")
	end
	busyToken[player] = nil
	cooldownUntil[player] = os.clock() + TravelRules.CooldownSeconds
	arrivedAt[player] = os.clock()
	setCurrent(player, def.id, trip.source)
	sendPhase(player, def.id, "in", nil)
	return true, nil
end

--[[
	Travels a player (yields up to TravelRules.DeadlineSeconds + a little). The one pipeline behind
	TravelWorld, portals, the rejoin chip / popup and admin WorldSend (see the header).
	@param worldId string — destination world
	@param target "spawn" | "area" | "plot"
	@param index number? — area (1..areaCount) / plot (1..8); nil for spawn
	@param source "portal" | "menu" | "popup" | "chip" | "admin" | "respawn"
	@return (true, nil) on arrival, else (false, reason) — the client already got the failure
	Example: WorldService.travel(player, "dino", "spawn", nil, "portal")
]]
function WorldService.travel(
	player: Player,
	worldId: string,
	target: TravelTarget,
	index: number?,
	source: TravelSource
): (boolean, string?)
	local requested = if type(worldId) == "string" then worldId else "unknown"
	local ok, reason = TravelRules.check(contextOf(player, worldId, target, index, source))
	if not ok then
		local why: string = if reason ~= nil then reason else "badTarget"
		refuse(player, requested, why)
		return false, why
	end
	local def = defOf(worldId) :: WorldsConfig.WorldDef
	local fromWorld = WorldService.currentWorld(player)
	local dest, owner = destinationOf(player, def.id, target, index, source, fromWorld)
	if dest == nil then
		local why = if target == "plot" then "plotEmpty" else "noPlot"
		refuse(player, def.id, why)
		return false, why
	end

	tokenSeq += 1
	local token = tokenSeq
	busyToken[player] = token
	sendPhase(player, def.id, "out", nil)
	-- Everything after "out" runs protected: an unexpected error can never leave the player
	-- marked busy (unable to ever travel again) or stuck behind the client's warp overlay.
	local trip: Trip = {
		player = player,
		def = def,
		target = target,
		index = index,
		source = source,
		fromWorld = fromWorld,
		profile = PlayerDataService.getProfile(player),
		dest = dest :: CFrame,
		owner = owner,
		token = token,
	}
	local okTrip, arrived, why = pcall(completeTrip, trip)
	if okTrip then
		return arrived, why
	end
	warn(`[WorldService] travel to {def.id} failed: {arrived}`)
	if busyToken[player] == token then
		busyToken[player] = nil
		if player.Parent == Players then
			refuse(player, def.id, "badTarget")
		end
	end
	return false, "badTarget"
end

--[[
	Admin WorldSend: travels a player (warp, cooldown skipped) to a world's spawn, or to THEIR OWN
	plot entrance in that world. Every other travel rule still applies (unlocked, enabled, alive,
	revealed, not mid-trip). Yields like travel().
	@param to "spawn" | "plot"
	@return (ok, reason?)
	Example: WorldService.adminSend(player, "dino", "plot")
]]
function WorldService.adminSend(player: Player, worldId: string, to: "spawn" | "plot"): (boolean, string?)
	if to == "plot" then
		local index = PlotService.getPlotIndex(player)
		if index == nil then
			return false, "noPlot"
		end
		return WorldService.travel(player, worldId, "plot", index, "admin")
	end
	return WorldService.travel(player, worldId, "spawn", nil, "admin")
end

--[[
	Sends a player back to the Nuke Town lobby NOW (kill switch, relock, profile swap): no checks,
	no cooldown, no overlay wait. A dead / missing character just gets CurrentWorld = "main" (the
	respawn then lands on the Nuke Town plot). Optional toast.
]]
function WorldService.sendHome(player: Player, toast: string?)
	local from = WorldService.currentWorld(player)
	if from == MAIN then
		return
	end
	busyToken[player] = nil
	local _, humanoid, _ = aliveParts(player)
	if humanoid ~= nil then
		unseat(humanoid)
		sendPhase(player, MAIN, "out", nil)
		PlotService.teleport(player, HubBuilder.spawnCFrame(nil))
	end
	setCurrent(player, MAIN, if humanoid ~= nil then "admin" else nil)
	if humanoid ~= nil then
		sendPhase(player, MAIN, "in", nil)
	end
	if toast ~= nil then
		PlayerDataService.notify(player, toast, "info")
	end
end

--[[
	Turns a world's kill switch on / off (admin). Off: travel into it is refused and everyone inside
	is sent to the Nuke Town lobby with a toast; their runtimes keep earning. Nuke Town can never be
	switched off.
	@return boolean — false for Nuke Town / unknown worlds
]]
function WorldService.setEnabled(worldId: string, on: boolean): boolean
	local def = defOf(worldId)
	if def == nil or def.id == MAIN then
		return false
	end
	ReplicatedStorage:SetAttribute(WorldService.EnabledAttrPrefix .. def.id, on == true)
	if on ~= true then
		local text = string.format(WorldService.EvacuateText, def.name)
		for _, player in WorldService.playersIn(def.id) do
			task.spawn(WorldService.sendHome, player, text)
		end
	end
	return true
end

--[[
	Where a respawning character of `player` belongs: the entrance of their plot in the world they
	are in, or nil for Nuke Town (PlotService then uses its own entrance). Never yields.
]]
function WorldService.respawnCFrame(player: Player): CFrame?
	local worldId = WorldService.currentWorld(player)
	local index = PlotService.getPlotIndex(player)
	if worldId == MAIN or index == nil then
		return nil
	end
	if not WorldService.isEnabled(worldId) then
		-- Switched off while they were dead: they belong home.
		setCurrent(player, MAIN, nil)
		return nil
	end
	return plotEntrance(worldId, index)
end

--------------------------------------------------------------------------------------------------
-- Portals
--------------------------------------------------------------------------------------------------

-- A locked lobby Time Machine was used: throttled "locked" failure (toast + client preview).
local function lockedPortal(player: Player, worldId: string)
	local perWorld = lockedAt[player]
	if perWorld == nil then
		perWorld = {}
		lockedAt[player] = perWorld
	end
	local now = os.clock()
	local last = perWorld[worldId]
	if last ~= nil and now - last < TravelRules.LockedToastSeconds then
		return
	end
	perWorld[worldId] = now
	sendPhase(player, worldId, "fail", "locked")
	record("worldPortalLocked", player, worldId)
end

--[[
	A portal was used by `player` (prompt or touch). `worldId` = the extra world the portal belongs
	to; `side` "main" = the lobby machine (go there), "world" = its return portal (go home).
	Touches stay silent for busy / cooldown / reveal refusals (a player standing in the swirl).
]]
local function usePortal(player: Player, worldId: string, side: "main" | "world", touched: boolean)
	if busyToken[player] ~= nil then
		return
	end
	if side == "main" then
		if WorldService.currentWorld(player) ~= MAIN then
			return
		end
		if not WorldService.isUnlocked(player, worldId) then
			lockedPortal(player, worldId)
			return
		end
		if touched then
			local ctx = contextOf(player, worldId, "spawn", nil, "portal")
			local ok, reason = TravelRules.check(ctx)
			if not ok and (reason == "cooldown" or reason == "busy" or reason == "revealPending") then
				return
			end
		end
		task.spawn(WorldService.travel, player, worldId, "spawn", nil, "portal")
		return
	end
	if WorldService.currentWorld(player) ~= worldId then
		return
	end
	if touched then
		local ok, reason = TravelRules.check(contextOf(player, MAIN, "spawn", nil, "portal"))
		if not ok and (reason == "cooldown" or reason == "busy") then
			return
		end
	end
	task.spawn(WorldService.travel, player, MAIN, "spawn", nil, "portal")
end

-- The player whose character owns `hit` (touch volumes), or nil.
local function playerFromHit(hit: BasePart): Player?
	local character = hit:FindFirstAncestorOfClass("Model")
	return if character ~= nil then Players:GetPlayerFromCharacter(character) else nil
end

-- True when the player's character is within reach of a prompt (server-side range check).
local function nearPrompt(player: Player, prompt: ProximityPrompt): boolean
	local _, _, root = aliveParts(player)
	local holder = prompt.Parent
	local at: Vector3? = nil
	if holder ~= nil and holder:IsA("BasePart") then
		at = holder.Position
	elseif holder ~= nil and holder:IsA("Attachment") then
		at = holder.WorldPosition
	end
	if root == nil or at == nil then
		return false
	end
	local position = at :: Vector3
	return (root.Position - position).Magnitude <= prompt.MaxActivationDistance + WorldService.PromptSlack
end

-- Connects one portal's prompt + touch volume.
local function connectPortal(worldId: string, side: "main" | "world")
	local portal = HubBuilder.getWorldPortal(worldId, side)
	if portal == nil then
		warn(`[WorldService] no {side} portal for {worldId}`)
		return
	end
	portal.prompt.Triggered:Connect(function(player: Player)
		if promptLimiter:Allow(player) and nearPrompt(player, portal.prompt) then
			usePortal(player, worldId, side, false)
		end
	end)
	portal.trigger.Touched:Connect(function(hit: BasePart)
		local player = playerFromHit(hit)
		if player == nil then
			return
		end
		local arrived = arrivedAt[player]
		if arrived ~= nil and os.clock() - arrived < WorldService.ArrivalTouchGrace then
			return
		end
		if touchLimiter:Allow(player) then
			usePortal(player, worldId, side, true)
		end
	end)
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

-- PlotService's world hooks (installed in Init; PlotService cannot require this module).
local function routeTravel(player: Player, worldId: string, target: string, index: number?): boolean
	if
		WorldService.currentWorld(player) == worldId or (target ~= "spawn" and target ~= "area" and target ~= "plot")
	then
		return false
	end
	task.spawn(WorldService.travel, player, worldId, target :: TravelTarget, index, "menu")
	return true
end

function WorldService.Init()
	PlotService.setWorldHooks({
		respawnCFrame = WorldService.respawnCFrame,
		route = routeTravel,
		currentWorld = WorldService.currentWorld,
		-- No `visit` hook since owner R134 (the hub plot pads that used it are gone): a visitor's
		-- Teleport-menu trip builds the visited owner's plot in travel() (buildJobs).
	})
end

function WorldService.Start()
	if started then
		return
	end
	started = true

	-- Kill switches default ON (published so every client's tabs know).
	for _, def in WorldsConfig.extra() do
		local attr = WorldService.EnabledAttrPrefix .. def.id
		if ReplicatedStorage:GetAttribute(attr) == nil then
			ReplicatedStorage:SetAttribute(attr, true)
		end
	end

	-- World products are refused while their world is locked (W2's prompt gate).
	MonetizationService.setWorldUnlockCheck(WorldService.isUnlocked)

	-- Portals: built by PlotService.Start (HubBuilder.build / buildWorld) before this Start.
	HubBuilder.build()
	for _, def in WorldsConfig.extra() do
		HubBuilder.buildWorld(def.id)
		connectPortal(def.id, "main")
		connectPortal(def.id, "world")
	end

	-- Unlock evaluation.
	PlayerDataService.ProfileLoaded:Connect(function(player: Player)
		evaluate(player, "load")
	end)
	TycoonService.AreaReached:Connect(function(player: Player, _area: number)
		evaluate(player, "area")
	end)
	TycoonService.WorldAreaReached:Connect(function(player: Player, _worldId: string, _area: number)
		evaluate(player, "area")
	end)
	RebirthService.Rebirthed:Connect(function(player: Player, _count: number)
		evaluate(player, "rebirth")
	end)
	RebirthService.WorldRebirthed:Connect(function(player: Player, _worldId: string, _count: number)
		evaluate(player, "rebirth")
	end)
	-- Idle runtimes of unlocked worlds start once the player has a Nuke Town plot (spec §5).
	PlotService.PlotAssigned:Connect(function(player: Player, _index: number)
		ensureRuntimes(player)
	end)
	-- No main plot any more (leave / swap): they are home (the plot is gone everywhere).
	PlotService.PlotReleased:Connect(function(player: Player, _index: number)
		busyToken[player] = nil
	end)

	-- lastWorld is written when the session ends (leave / shutdown) and before a profile swap.
	PlayerDataService.ProfileReleasing:Connect(function(player: Player, profile: any)
		if type(profile) == "table" then
			profile.lastWorld = endWorld[player] or WorldService.currentWorld(player)
		end
		if player.Parent ~= Players then
			endWorld[player] = nil
		end
	end)
	PlayerDataService.ProfileUnloading:Connect(function(player: Player)
		local from = WorldService.currentWorld(player)
		-- New Player Mode swap: the plot is re-claimed + revealed in Nuke Town.
		WorldService.sendHome(player, nil)
		-- The REAL (parked) profile keeps the world its session really was in (sendHome just wrote
		-- "main" into it).
		local profile = PlayerDataService.getProfile(player)
		if profile ~= nil then
			profile.lastWorld = from
		end
	end)

	local function onPlayer(player: Player)
		-- Every session starts in the Nuke Town lobby (R13); profile.lastWorld keeps the previous
		-- session's world for the client's rejoin chip until this session travels or ends.
		player:SetAttribute(WorldService.CurrentAttr, MAIN)
		endWorld[player] = MAIN
		if PlayerDataService.getProfile(player) ~= nil then
			evaluate(player, "load") -- profile loaded before this service started (Studio hot start)
			if PlotService.getPlotIndex(player) ~= nil then
				ensureRuntimes(player)
			end
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		current[player] = nil
		-- endWorld outlives the leave until the profile release wrote it (fallback clean-up).
		task.delay(60, function()
			if player.Parent ~= Players then
				endWorld[player] = nil
			end
		end)
		busyToken[player] = nil
		cooldownUntil[player] = nil
		arrivedAt[player] = nil
		lockedAt[player] = nil
		travelLimiter:Forget(player)
		promptLimiter:Forget(player)
		touchLimiter:Forget(player)
	end)

	-- TravelWorld(worldId, target, index?, source?) — the client intent (see the header).
	Remotes.onServerEvent(
		"TravelWorld",
		function(player: Player, rawWorld: unknown, rawTarget: unknown, rawIndex: unknown, rawSource: unknown)
			if not travelLimiter:Allow(player) then
				return
			end
			local request = Validate.travelRequest(rawWorld, rawTarget, rawIndex)
			if request == nil then
				return
			end
			local source: TravelSource = if type(rawSource) == "string" and CLIENT_SOURCES[rawSource]
				then rawSource :: TravelSource
				else "menu"
			WorldService.travel(player, request.worldId, request.target, request.index, source)
		end
	)

	-- Play time in extra worlds: ONE 1 Hz loop (saved by the regular autosave, nothing pushed).
	task.spawn(function()
		while true do
			task.wait(TravelRules.StatsTickSeconds)
			for player, worldId in current do
				local profile = PlayerDataService.getProfile(player)
				local state = if profile ~= nil then ProfileLogic.peekWorld(profile, worldId) else nil
				if state ~= nil then
					TravelRules.addSeconds(state.stats, TravelRules.StatsTickSeconds)
				end
			end
		end
	end)
end

return WorldService
