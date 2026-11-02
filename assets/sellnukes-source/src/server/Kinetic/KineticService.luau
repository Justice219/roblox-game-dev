--!strict
--[[
	KineticService — boots owner R90's hands-on plot props, the Mega Lever + Tip Jar (spec
	docs/superpowers/specs/2026-10-31-r90-hands-on-design.md §2 / §3; system doc docs/kinetic.md;
	builder K-kinetic).

	What it owns
		Reconcile  ONE 1 Hz Heartbeat accumulator for every player: for each world in
		           WorldsConfig.Order the props should stand when that world's plot is built
		           (Nuke Town: TycoonService.isReady; others: isWorldBuilt) AND it owns
		           KineticConfig.UnlockArea. Missing → KineticWorld.place (the LEGO fly-in when the
		           world was seen locked earlier this session = a live reveal; a join / travel restore
		           appears finished); not wanted any more (rebirth to area 1, relock, plot rebuilt) →
		           removed. Then the lever's ReadyAt is republished (on change) and the Tip Jar of the
		           world the player stands in takes one fill step (TipJar.tick).
		Intents    KineticAction(action) through Remotes.onServerEvent (drops packets of players who
		           left) → RateLimiter (ActionBurst / ActionRefill) → Validate.oneOf(Actions) →
		           MegaLever.pull / TipJar.collect("prompt"). Walking into the jar is a server
		           Touched (TipJar.onTouched, bound per jar by KineticWorld).
		Rebirth    RebirthService.Rebirthed / WorldRebirthed (guarded lazy require: neither module is
		           edited) empty that world's jar: its coins were the old run's currency.
		Switches   ReplicatedStorage attributes KineticLeverOn / KineticJarOn (default on, set here;
		           admin KineticSwitch).
		Admin      KineticAdmin.install (KineticSwitch / KineticLeverReset / KineticJarFill /
		           KineticStatus).
		Cleanup    PlayerRemoving: props, runtimes and the limiter bucket are dropped.

	Security: clients send only allowlisted action strings; everything else is server-decided in
	MegaLever / TipJar (owner, unlock, reach, cooldown, amounts). Performance: one Heartbeat for the
	whole system, O(worlds) table reads per player per second, attributes only on change.

	Boot: FEATURE_SERVICES "Kinetic/KineticService", after Tycoon/FlavorService + Tycoon/WorldService
	(it needs TycoonService, PlotService, WorldService, FlavorService, Knockdown, RebirthService).

	Connects to: Server/Kinetic/{KineticWorld, MegaLever, TipJar, KineticAdmin, KineticAnalytics},
	Shared/Config/{KineticConfig, Worlds/WorldsConfig}, Shared/Tycoon/{KineticLogic, TycoonLogic},
	Shared/Net/{Remotes, Validate}, Shared/Util/RateLimiter, Server/Services/PlayerDataService,
	Server/Tycoon/{TycoonService, PlotService}, Server/Economy/ProfileLogic.

	Example (QA / tools/qa/kinetic_server.luau):
		KineticService.reconcileNow(player)          -- place the props right away
		KineticService.status(player) --> { placed = { main = true }, ... }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local KineticAdmin = require(script.Parent.KineticAdmin)
local KineticAnalytics = require(script.Parent.KineticAnalytics)
local KineticConfig = require(ReplicatedStorage.Shared.Config.KineticConfig)
local KineticLogic = require(ReplicatedStorage.Shared.Tycoon.KineticLogic)
local KineticWorld = require(script.Parent.KineticWorld)
local MegaLever = require(script.Parent.MegaLever)
local PlayerDataService = require(script.Parent.Parent.Services.PlayerDataService)
local PlotService = require(script.Parent.Parent.Tycoon.PlotService)
local ProfileLogic = require(script.Parent.Parent.Economy.ProfileLogic)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local TipJar = require(script.Parent.TipJar)
local TycoonLogic = require(ReplicatedStorage.Shared.Tycoon.TycoonLogic)
local TycoonService = require(script.Parent.Parent.Tycoon.TycoonService)
local Validate = require(ReplicatedStorage.Shared.Net.Validate)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

local ATTR = KineticConfig.Attr
local MAIN = WorldsConfig.MAIN

local KineticService = {}

-- Per player: whether each world's BUILT plot owned UnlockArea at the previous reconcile (nil = not
-- observed built yet this session — a first sighting never flies in).
type PlayerState = { known: { [string]: boolean } }

local states: { [Player]: PlayerState } = {}
local limiter = RateLimiter.new(KineticConfig.ActionBurst, KineticConfig.ActionRefill)
local started = false
local accumulator = 0

-- The per-player state (created on demand).
local function stateOf(player: Player): PlayerState
	local state = states[player]
	if state == nil then
		state = { known = {} }
		states[player] = state
	end
	return state
end

-- The tycoon state of a world on a profile (nil when absent).
local function tycoonOf(profile: any, worldId: string): any
	if worldId == MAIN then
		return profile.tycoon
	end
	local world = ProfileLogic.peekWorld(profile, worldId)
	return if world ~= nil then world.tycoon else nil
end

--[[
	Whether a world's plot is built for the player, and whether it owns UnlockArea. The props
	should stand exactly when both are true.
	@return (built, unlocked)
]]
local function worldReadiness(player: Player, profile: any, worldId: string): (boolean, boolean)
	local built = if worldId == MAIN then TycoonService.isReady(player) else TycoonService.isWorldBuilt(player, worldId)
	if not built then
		return false, false
	end
	local state = tycoonOf(profile, worldId)
	if state == nil then
		return true, false
	end
	return true, TycoonLogic.forWorld(worldId).areaUnlocked(state, KineticConfig.UnlockArea)
end

--[[
	Places / removes one player's props in every world to match `wanted` (see the module header).
	Never yields (placement is async inside KineticWorld).
]]
local function reconcile(player: Player)
	local plot = PlotService.getPlotIndex(player)
	local profile = PlayerDataService.getProfile(player)
	if plot == nil or profile == nil then
		KineticWorld.removeAll(player)
		return
	end
	local state = stateOf(player)
	for _, worldId in WorldsConfig.Order do
		local built, unlocked = worldReadiness(player, profile, worldId)
		local want = built and unlocked
		if want then
			if not KineticWorld.isPlaced(player, worldId) and not KineticWorld.isPending(player, worldId) then
				-- A live reveal (seen locked earlier this session) builds in; a restore just appears.
				local flyIn = state.known[worldId] == false
				local entry = KineticLogic.peek((profile :: any).kinetic, worldId)
				local income = TycoonService.incomePerSecond(player, worldId)
				local jar, tips = if entry ~= nil then entry.jar else 0, if entry ~= nil then entry.tips else 0
				local cap = KineticLogic.jarCap(income)
				KineticWorld.place(player, worldId, plot, flyIn, {
					readyAt = if entry ~= nil then entry.readyAt else 0,
					fill = KineticLogic.fillRatio(jar, tips, income),
					full = cap > 0 and jar >= cap,
				}, TipJar.onTouched)
				if flyIn then
					KineticAnalytics.record(player, `reveal:{worldId}`)
				end
			else
				MegaLever.publish(player, worldId)
			end
		elseif KineticWorld.get(player, worldId) ~= nil then
			KineticWorld.remove(player, worldId)
		end
		-- Remember the unlock state only while the plot is built: travelling to a world whose
		-- plot restores already unlocked is a restore (no fly-in), not a reveal.
		if built then
			state.known[worldId] = unlocked
		end
	end
end

-- One 1 Hz pass over every player (one player's error never stops the others).
local function tick(dt: number)
	for _, player in Players:GetPlayers() do
		local ok, err = pcall(function()
			reconcile(player)
			TipJar.tick(player, dt)
		end)
		if not ok then
			warn(`[KineticService] tick failed for {player.Name}: {err}`)
		end
	end
end

-- KineticAction(action): the only intent of the system.
local function onAction(player: Player, rawAction: unknown)
	if not limiter:Allow(player) then
		KineticAnalytics.record(player, "pullRefused:rate")
		return
	end
	local action = Validate.oneOf(rawAction, KineticConfig.Actions)
	if action == "pull" then
		MegaLever.pull(player)
	elseif action == "collect" then
		TipJar.collect(player, "prompt")
	end
end

-- Guarded lazy hook into RebirthService's signals (its module is never edited or required at load).
local function hookRebirths()
	local tycoon = script.Parent.Parent:FindFirstChild("Tycoon")
	local module = if tycoon ~= nil then tycoon:FindFirstChild("RebirthService") else nil
	if module == nil or not module:IsA("ModuleScript") then
		return
	end
	local ok, RebirthService = pcall(require, module)
	if not ok or type(RebirthService) ~= "table" then
		warn("[KineticService] RebirthService unavailable; jars are not emptied on rebirth")
		return
	end
	local service = RebirthService :: any
	if service.Rebirthed ~= nil then
		service.Rebirthed:Connect(function(player: Player)
			TipJar.clearWorld(player, MAIN)
		end)
	end
	if service.WorldRebirthed ~= nil then
		service.WorldRebirthed:Connect(function(player: Player, worldId: string)
			TipJar.clearWorld(player, worldId)
		end)
	end
end

--[[ QA: reconcile one player at once (instead of waiting for the next tick). ]]
function KineticService.reconcileNow(player: Player)
	reconcile(player)
end

--[[
	QA / admin: one player's props + saved state.
	@return { placed: { [string]: boolean }, readyAt: { [string]: number }, jar: { [string]: number },
	          tips: { [string]: number } }
]]
function KineticService.status(player: Player): any
	local profile = PlayerDataService.getProfile(player)
	local out = { placed = {}, readyAt = {}, jar = {}, tips = {} }
	for _, worldId in WorldsConfig.Order do
		out.placed[worldId] = KineticWorld.isPlaced(player, worldId)
		local entry = if profile ~= nil then KineticLogic.peek((profile :: any).kinetic, worldId) else nil
		if entry ~= nil then
			out.readyAt[worldId] = entry.readyAt
			out.jar[worldId] = entry.jar
			out.tips[worldId] = entry.tips
		end
	end
	return out
end

function KineticService.Init()
	-- Switches default ON (an admin may flip them later; nothing else writes them).
	if ReplicatedStorage:GetAttribute(ATTR.LeverOn) == nil then
		ReplicatedStorage:SetAttribute(ATTR.LeverOn, true)
	end
	if ReplicatedStorage:GetAttribute(ATTR.JarOn) == nil then
		ReplicatedStorage:SetAttribute(ATTR.JarOn, true)
	end
end

function KineticService.Start()
	if started then
		return
	end
	started = true
	Remotes.onServerEvent("KineticAction", onAction)
	Players.PlayerRemoving:Connect(function(player: Player)
		KineticWorld.removeAll(player)
		TipJar.forget(player)
		MegaLever.forget(player)
		limiter:Forget(player)
		states[player] = nil
	end)
	hookRebirths()
	KineticAdmin.install(MegaLever, TipJar, KineticWorld)
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < KineticConfig.TickSeconds then
			return
		end
		local step = accumulator
		accumulator = 0
		tick(step)
	end)
end

return KineticService
