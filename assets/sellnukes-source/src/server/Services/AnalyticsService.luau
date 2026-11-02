--!strict
--[[
	AnalyticsService — server-authoritative game analytics for SellNukes (spec §13; owner R6 "a fully
	in-depth analytics system to track as much data as possible", modelled on RoBeasts).

	What it is:
		Aggregate counters per UTC day and family (core, revenue, economy, tycoon, worlds, retention,
		pets, crates, attack, event, social, health), recorded from the server's OWN trusted events,
		flushed every 60 s to the DataStore "SellNukesAnalytics_v1", mirrored (rate-limited) to the
		Roblox Creator Dashboard, and read back by admins as a report (admin panel Analytics tab,
		COPY FOR AI, COPY RAW DATA). No per-player event stream, no names, no user ids in keys.
		Docs: docs/analytics.md (how it works, every key, how to add metrics),
		docs/analytics-scorecard.md (what to look at, experiment rules).

	The service is a facade over Server/Analytics/*:
		Runtime (shared state, guards, profile markers) · Recorder (pending deltas) · Sessions ·
		Revenue · Recorders · Flusher · Reports · ServerHealth · ClientPerfIngest · KeySpec ·
		AnalyticsStore · AnalyticsLogic · ReportSections · RobloxForwarder · ReceiptAccounting.

	RECORDER API (any server module; never throws, never yields, safe before Start):
		Generic, allowlisted by AnalyticsConfig.Metrics (undocumented keys are refused):
			AnalyticsService.tycoon(player?, key, amount?)      e.g. "rename", "teleport:3"
			AnalyticsService.worlds(player?, key, amount?)      e.g. "portalLocked:dino" (R57)
			AnalyticsService.retention(player?, key, amount?)   e.g. "daily:claim:3", "wheel:slice:Gems"
			AnalyticsService.pets(player?, key, amount?)        e.g. "hatch:BasicEgg", "equip"
			AnalyticsService.crates(player?, key, amount?)      e.g. "open:SupplyCrate"
			AnalyticsService.attack(player?, key, amount?)      e.g. "launch:normal", "intercept"
			AnalyticsService.event(player?, key, amount?)       e.g. "turkey:collect", "sticker:7"
			AnalyticsService.social(player?, key, amount?)      e.g. "visit"
			AnalyticsService.record(family, player?, key, amount?)
			AnalyticsService.registerIds(kind, isValid)         exact ids for a <kind> (eggId, ...)
		Typed tycoon helpers (drive the new-player funnel, first-day milestones and time-to-X):
			plotAssigned(player, plotIndex) · padBought(player, padId, skipped?) ·
			producerClick(player, producerId) · producerIncome(player, producerId, amount, automated) ·
			producerUpgraded(player, producerId, fromLevel, toLevel, mode?) · areaReached(player, area) ·
			rebirthed(player, rebirthsAfter, tokens?) · offlinePaid(player, seconds, cash) ·
			offlineDoubled(player) · tutorialStep(player, step, done?)
			padBought / producerClick / producerIncome / producerUpgraded take ANY world's ids
			(Nuke Town a1_… / p1_…, Dino Valley d3_… / dp3_…); extra-world ids are routed to the
			world analytics automatically (Server/Analytics/WorldRecorders).
		Typed world helpers (R57 World 2; spec §12; the `worlds` family + the world funnel):
			worldUnlocked(player, worldId, source)        source "area"|"rebirth"|"legacy"|"admin"
			worldTravelled(player, worldId, source, firstVisit)
			                                              after a successful trip (CurrentWorld set);
			                                              source "portal"|"menu"|"popup"|"chip"|
			                                              "admin"|"respawn"; firstVisit = first ever
			worldTravelFailed(player, worldId?, reason)   reason = TravelRules.TravelReason
			worldPortalLocked(player, worldId)            locked portal used (throttled inside)
			worldAreaReached(player, worldId, area)       TycoonService.WorldAreaReached
			worldRebirthed(player, worldId, rebirthsAfter, tokens?)
			worldRebirthShop(player, worldId, upgradeKey)
			worldOfflinePaid(player, worldId, seconds, amount) · worldOfflineDoubled(player, worldId)
			Time per world is measured automatically (travel hook + Player attribute CurrentWorld).
		Typed pets / crates: eggHatched(player, eggId, results, auto?) ·
			crateOpened(player, crateId, payWith, rewards?)
		Revenue / offers: offerShown(player, offerId) · offerClicked(player, offerId) (trusted server
			callers; client BUY presses on offer surfaces are counted automatically, R137)
		Health: systemTime(systemId, seconds) (server loop Luau time) · liveHealth() (admin Live tab)
	Wired automatically in Start (no caller work): sessions / retention / devices (Players +
	PlayerDataService.ProfileLoaded / ProfileReleasing), the economy (PlayerDataService.
	CurrencyChanged), the purchase funnel + durable receipt accounting (MonetizationService
	PromptRequested (R137 offer BUY press = click) / PromptShown / PromptFinished / ProductGranted /
	PassPurchased / setReceiptAccounting), client reports (FunnelStep, OffersSeen, ClientDevice,
	ClientPerf), admin reports (AnalyticsRequest, AnalyticsRawRequest), server health sampling, the
	60 s flush loop and the BindToClose drain.

	Boot: add `{ name = "AnalyticsService", module = require(Services.AnalyticsService) }` to the
	ORDERED list in Server/init.server.luau AFTER MonetizationService (it reads both services).

	Example:
		local AnalyticsService = require(ServerScriptService.Server.Services.AnalyticsService)
		AnalyticsService.padBought(player, "a1_tool_wall")
		AnalyticsService.retention(player, "daily:claim:" .. streakDay)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)

local Analytics = script.Parent.Parent.Analytics
local AnalyticsAuth = require(Analytics.AnalyticsAuth)
local AnalyticsLogic = require(Analytics.AnalyticsLogic)
local AnalyticsStore = require(Analytics.AnalyticsStore)
local ClientPerfIngest = require(Analytics.ClientPerfIngest)
local Flusher = require(Analytics.Flusher)
local Recorder = require(Analytics.Recorder)
local Recorders = require(Analytics.Recorders)
local Reports = require(Analytics.Reports)
local Revenue = require(Analytics.Revenue)
local Runtime = require(Analytics.Runtime)
local ServerHealth = require(Analytics.ServerHealth)
local ServerHealthLogic = require(Analytics.ServerHealthLogic)
local Sessions = require(Analytics.Sessions)
local WorldRecorders = require(Analytics.WorldRecorders)

local AnalyticsService = {}

--------------------------------------------------------------------------------------------------
-- Public recorder API (see the header)
--------------------------------------------------------------------------------------------------

AnalyticsService.record = Recorders.record
AnalyticsService.tycoon = Recorders.tycoon
AnalyticsService.worlds = Recorders.worlds
AnalyticsService.retention = Recorders.retention
AnalyticsService.pets = Recorders.pets
AnalyticsService.crates = Recorders.crates
AnalyticsService.attack = Recorders.attack
AnalyticsService.event = Recorders.event
AnalyticsService.social = Recorders.social
AnalyticsService.registerIds = Recorders.registerIds

AnalyticsService.plotAssigned = Recorders.plotAssigned
AnalyticsService.padBought = Recorders.padBought
AnalyticsService.producerClick = Recorders.producerClick
AnalyticsService.producerIncome = Recorders.producerIncome
AnalyticsService.producerUpgraded = Recorders.producerUpgraded
AnalyticsService.areaReached = Recorders.areaReached
AnalyticsService.rebirthed = Recorders.rebirthed
AnalyticsService.offlinePaid = Recorders.offlinePaid
AnalyticsService.offlineDoubled = Recorders.offlineDoubled
AnalyticsService.tutorialStep = Recorders.tutorialStep
AnalyticsService.eggHatched = Recorders.eggHatched
AnalyticsService.crateOpened = Recorders.crateOpened
AnalyticsService.currencyChanged = Recorders.currencyChanged
-- R57 world helpers (Server/Analytics/WorldRecorders).
AnalyticsService.worldUnlocked = WorldRecorders.unlocked
AnalyticsService.worldTravelled = WorldRecorders.travelled
AnalyticsService.worldTravelFailed = WorldRecorders.travelFailed
AnalyticsService.worldPortalLocked = WorldRecorders.portalLocked
AnalyticsService.worldAreaReached = WorldRecorders.areaReached
AnalyticsService.worldRebirthed = WorldRecorders.rebirthed
AnalyticsService.worldRebirthShop = WorldRecorders.rebirthShop
AnalyticsService.worldOfflinePaid = WorldRecorders.offlinePaid
AnalyticsService.worldOfflineDoubled = WorldRecorders.offlineDoubled

AnalyticsService.promptShown = Revenue.promptShown
AnalyticsService.promptFinished = Revenue.promptFinished
AnalyticsService.productGranted = Revenue.productGranted
AnalyticsService.passPurchased = Revenue.passPurchased
AnalyticsService.offerShown = Revenue.offerShown
AnalyticsService.offerClicked = Revenue.offerClicked

--[[ Adds Luau time of a server loop (AnalyticsConfig.Health.Systems id). Never yields. ]]
AnalyticsService.systemTime = ServerHealth.addTime
--[[ Instant server health for the admin Live tab (fps, heartbeat, memory, ping, systems). ]]
AnalyticsService.liveHealth = ServerHealth.liveStats

--[[ The session's device class claim ("phone" / "tablet" / "desktop" / "console") or nil. ]]
AnalyticsService.deviceOf = Runtime.deviceOf

--[[ Builds a report summary for a range (server-internal: NO authorization; yields). ]]
AnalyticsService.summaryAsync = Reports.summaryAsync

--[[ True when `player` may read analytics (AdminService when present, else the seam). Yields. ]]
AnalyticsService.isAuthorizedAsync = AnalyticsAuth.isAuthorizedAsync

--[[ A deep copy of this server's unsaved deltas (Studio verification / tests). ]]
function AnalyticsService.snapshotUnsaved(): AnalyticsLogic.Pending
	return Recorder.unsavedCopy()
end

--[[ Flushes now on a new thread (admin "flush analytics" command / tests). ]]
function AnalyticsService.flushNow()
	task.spawn(Flusher.flushOnce)
end

--[[ Roblox forwarder counters (sent / dropped / failed) for the admin Live tab. ]]
function AnalyticsService.forwardStats(): { sent: number, dropped: number, failed: number }
	return Runtime.forwarder.stats()
end

--[[ Studio only: swap in a test backend (AnalyticsStore.memoryBackend()); returns a restore fn. ]]
function AnalyticsService.useBackendForTests(backend: AnalyticsStore.Backend?, canWrite: boolean): () -> ()
	local restoreStore = Flusher.useBackendForTests(backend, canWrite)
	local restoreBuffers = Recorder.swapForTests()
	Reports.clearCache()
	return function()
		restoreStore()
		restoreBuffers()
		Reports.clearCache()
	end
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

local started = false
local healthBaseline: ServerHealthLogic.Totals? = nil

-- Records the server health window since the previous call + the server population sample.
local function recordHealthWindow()
	local now = ServerHealth.snapshot()
	local before = healthBaseline
	healthBaseline = now
	ServerHealth.markWindow()
	if before == nil then
		return
	end
	local window = ServerHealthLogic.diff(now, before)
	for key, amount in ServerHealthLogic.counters(window, AnalyticsConfig.Health) do
		Recorder.count("health", key, amount)
	end
	-- One server-minute at the current player / owned-plot counts (social family).
	local players = math.min(#Players:GetPlayers(), AnalyticsConfig.Social.MaxPlayers)
	local plots = 0
	for _, info in Runtime.sessions do
		if info.loaded then
			plots += 1
		end
	end
	Recorder.count("social", `players:{players}`)
	Recorder.count("social", `plots:{math.min(plots, AnalyticsConfig.Social.MaxPlayers)}`)
end

-- Connects a remote handler under pcall (a malformed client report never errors the event).
local function onRemote(name: string, handler: (Player, ...any) -> ...any)
	Remotes.onServerEvent(name :: any, function(player: Player, ...: any)
		local ok, err = pcall(handler, player, ...)
		if not ok then
			Recorder.warn(name, tostring(err))
		end
	end)
end

function AnalyticsService.Init() end

function AnalyticsService.Start()
	if started then
		return
	end
	started = true
	local services = script.Parent
	local PlayerDataService = require(services.PlayerDataService) :: any
	local MonetizationService = require(services.MonetizationService) :: any

	Runtime.setDeps({
		getProfile = function(player: Player): Runtime.Profile?
			return PlayerDataService.getProfile(player)
		end,
		canMutate = function(player: Player): boolean
			return PlayerDataService.canMutate(player) == true
		end,
		markSaved = function(player: Player)
			-- Dirty for the next save; `{}` = no client snapshot field changed (analytics never syncs).
			PlayerDataService.markChanged(player, false, {})
		end,
		isAdmin = AnalyticsAuth.isAdmin,
	})
	Flusher.start()
	Flusher.onBeforeFlush(Sessions.flushActivity)
	Flusher.onBeforeFlush(Revenue.drainOutboxes)

	-- Sessions and profiles.
	-- `isNew` = nothing was stored for this player (PlayerDataService's third argument); also true
	-- for an in-memory fallback session, which Sessions gates with canMutate (no markers, no counts).
	local function onLoaded(player: Player, profile: Runtime.Profile, isNew: boolean?)
		if isNew == nil then
			local session = PlayerDataService.getSession(player)
			isNew = if session ~= nil then session.migration == "new" else nil
		end
		Sessions.onProfileLoaded(player, profile, isNew)
		-- Receipt accounting left unfinished by a crash: journal it now (own thread: yields).
		task.spawn(function()
			local ok, err = pcall(Revenue.drainOutbox, player, profile)
			if not ok then
				Recorder.warn("drainOutbox", tostring(err))
			end
		end)
	end
	PlayerDataService.ProfileLoaded:Connect(function(player: Player, profile: Runtime.Profile, isNew: boolean?)
		local ok, err = pcall(onLoaded, player, profile, if type(isNew) == "boolean" then isNew else nil)
		if not ok then
			Recorder.warn("profileLoaded", tostring(err))
		end
	end)
	PlayerDataService.ProfileReleasing:Connect(function(player: Player, profile: Runtime.Profile)
		local ok, err = pcall(Sessions.onProfileReleasing, player, profile)
		if not ok then
			Recorder.warn("profileReleasing", tostring(err))
		end
	end)
	PlayerDataService.CurrencyChanged:Connect(Recorders.currencyChanged)
	Players.PlayerAdded:Connect(function(player: Player)
		local ok, err = pcall(Sessions.startSession, player)
		if not ok then
			Recorder.warn("startSession", tostring(err))
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		local ok, err = pcall(Sessions.endSession, player)
		if not ok then
			Recorder.warn("endSession", tostring(err))
		end
		Revenue.forget(player)
		Reports.forget(player)
		ClientPerfIngest.forget(player)
	end)
	for _, player in Players:GetPlayers() do
		pcall(Sessions.startSession, player)
		local profile = PlayerDataService.getProfile(player)
		if profile ~= nil then
			pcall(onLoaded, player, profile)
		end
	end

	-- Monetization: the purchase funnel and durable receipt accounting. PromptRequested (R137) is
	-- the BUY press itself (offer surfaces → the funnel's click step), before any prompt refusal.
	MonetizationService.PromptRequested:Connect(Revenue.promptRequested)
	MonetizationService.PromptShown:Connect(Revenue.promptShown)
	MonetizationService.PromptFinished:Connect(Revenue.promptFinished)
	MonetizationService.ProductGranted:Connect(Revenue.productGranted)
	MonetizationService.PassPurchased:Connect(Revenue.passPurchased)
	local setAccounting: any = MonetizationService.setReceiptAccounting
	if setAccounting ~= nil then
		local ok, err = pcall(setAccounting, Revenue.accountingHooks())
		if ok then
			Revenue.setAccountingInstalled(true)
		else
			Recorder.warn("receiptAccounting", tostring(err))
		end
	end

	-- Client reports (validated; counts only) and admin reports.
	onRemote("FunnelStep", Sessions.onFunnelStep)
	onRemote("ClientDevice", Sessions.onClientDevice)
	onRemote("OffersSeen", Revenue.onOffersSeen)
	onRemote("ClientPerf", ClientPerfIngest.handleReport)
	Reports.start()

	-- Periodic flush (its own thread: DataStore calls never block gameplay).
	task.spawn(function()
		while true do
			task.wait(AnalyticsConfig.FlushInterval)
			Flusher.flushOnce()
		end
	end)

	-- Server health sampling: one window per Health.WindowSeconds.
	ServerHealth.start()
	healthBaseline = ServerHealth.snapshot()
	ServerHealth.markWindow()
	task.spawn(function()
		while true do
			task.wait(AnalyticsConfig.Health.WindowSeconds)
			local ok, err = pcall(recordHealthWindow)
			if not ok then
				Recorder.warn("health", tostring(err))
			end
		end
	end)

	-- Shutdown: end every session, then a final flush bounded by CloseFlushSeconds.
	game:BindToClose(function()
		pcall(recordHealthWindow)
		for player in Runtime.sessions do
			pcall(Sessions.endSession, player)
		end
		Flusher.flushPendingAsync(AnalyticsConfig.CloseFlushSeconds)
	end)
end

return AnalyticsService
