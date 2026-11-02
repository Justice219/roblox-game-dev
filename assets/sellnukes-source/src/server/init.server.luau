--!strict
--[[
	Server bootstrap — the single server entry point (pattern from RoBeasts).

	Lifecycle:
		1. Create every remote (Shared/Net/Remotes.createAll) so clients can fetch them at once.
		2. Init every service in dependency order (wiring only: registrations, no yielding).
		3. Start every service (connect remotes / player events, begin loops).
		4. In a Studio test run (StudioTestService args present), run the requested suite
		   (Tests/TestRunner) and end the playtest with its results. Never active in live games.

	Service contract: each module in ./Services returns a table with Init() and Start(). Order
	matters: a service may only call into services listed BEFORE it during Init/Start. Two tiers:
	  * CRITICAL core (PlayerData, Monetization, Analytics): a failing require/Init/Start stops the
	    boot with the service's name in the error (the game cannot run without them).
	  * FEATURE services (tycoon, retention, pets, attack, event, admin, ...): loaded by name under
	    pcall; a failure warns with the name and only that feature is skipped, so one broken
	    feature never takes the whole server down.

	Adding a service (later waves / the lead): add its name to FEATURE_SERVICES below, after
	everything it depends on. Product-selling services register their handlers in Init
	(MonetizationService.registerProductHandler).

	Test runs ALWAYS end (StudioTestService:EndTest), whatever goes wrong: a module that fails to
	load or a service that throws ends the run with a `bootstrap failed` result, a suite that runs
	past its budget is ended by a watchdog, and EndTest is called exactly once.

	Example (Studio, through scripts/studio_mcp.py):
		StudioTestService:ExecuteRunModeAsync({ suite = "Core" })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local VersionConfig = require(ReplicatedStorage.Shared.Config.VersionConfig)

local Services = script.Services

type Service = { Init: () -> (), Start: () -> () }

-- Test-run time budget in seconds; a run may pass its own `timeout` within [MIN, MAX].
local SUITE_TIMEOUT_DEFAULT = 300
local SUITE_TIMEOUT_MIN = 30
local SUITE_TIMEOUT_MAX = 1800

-- Studio integration tests: read the test args up front (Studio only).
local testArgs: { [string]: unknown }? = nil
if RunService:IsStudio() then
	local ok, args = pcall(function()
		return game:GetService("StudioTestService"):GetTestArgs()
	end)
	if ok and type(args) == "table" and type((args :: any).suite) == "string" then
		testArgs = args :: any
	end
end

--[[
	Ends the Studio test run with `result`, once. If EndTest throws (e.g. an oversized result) it
	retries with a small failure payload; if even that fails the flag stays clear so the watchdog
	can still try.
]]
local testRunEnded = false
local function endTestRun(result: { [string]: unknown })
	if testRunEnded then
		return
	end
	local ok, err = pcall(function()
		game:GetService("StudioTestService"):EndTest(result)
	end)
	if ok then
		testRunEnded = true
		return
	end
	warn(`[Bootstrap] EndTest failed: {err}; retrying with a minimal result`)
	local suite = if testArgs ~= nil then testArgs.suite else nil
	testRunEnded = pcall(function()
		game:GetService("StudioTestService"):EndTest({
			suite = suite,
			error = `EndTest failed: {string.sub(tostring(err), 1, 300)}`,
			passed = 0,
			failed = 1,
			tests = {},
		})
	end)
end

-- A failure result in TestRunner's shape.
local function failedRun(reason: string): { [string]: unknown }
	local suite = if testArgs ~= nil then testArgs.suite else nil
	return { suite = suite, error = reason, passed = 0, failed = 1, tests = {} }
end

-- Watchdog first, so even a bootstrap that hangs cannot keep the test session open forever.
if testArgs ~= nil then
	local requested = testArgs.timeout
	local budget = if type(requested) == "number" and requested == requested
		then math.clamp(requested, SUITE_TIMEOUT_MIN, SUITE_TIMEOUT_MAX)
		else SUITE_TIMEOUT_DEFAULT
	task.delay(budget, function()
		if not testRunEnded then
			warn(`[Bootstrap] test run timed out after {budget}s; ending it (watchdog)`)
			endTestRun(failedRun(`timed out after {budget}s (bootstrap watchdog)`))
		end
	end)
end

-- Feature services in boot order, by module name in ./Services. Unlike the CRITICAL core below,
-- a feature that fails to load / Init / Start is skipped with a warning naming it, so one broken
-- feature (mid-development, or a bad hotfix) never takes the whole server down. The lead owns
-- this list; each wave adds its services here. Product handlers register in each service's Init
-- (MonetizationService.registerProductHandler); ModifierSources registrations likewise.
local FEATURE_SERVICES: { string } = {
	-- Tycoon (B5): random free plot in the lobby + plot builds, then pads / producers / clicks /
	-- upgrades / income loop / teleports / tutorial (registers Cash + SkipPad products and the
	-- ModifierSources registry), offline earnings on join (DoubleOffline product), rebirth + shop.
	-- Retention + shop (B7), in dependency order: settings first; personal + server boosts
	-- (ModifierSources, offline = false); daily streak, playtime gifts, lucky wheel, codes, group
	-- reward, notification opt-in reward; ShopService LAST of the group (installs admin hooks, packs).
	"SettingsService",
	-- Player Titles (owner R73 / R74): the Title / TitleHidden attributes (DEVELOPER, FIRST PLAYER,
	-- EARLY PLAYER; permanent by UserId + owner-granted in profile.titles), the audited admin
	-- TitleGrant / TitleRevoke commands. Needs SettingsService.
	"PlayerTitleService",
	"BoostService",
	"ServerBoostService",
	"RetentionService",
	"PlaytimeService",
	"LuckySpinService",
	"CodesService",
	"GroupRewardService",
	"NotifyRewardService",
	"Retention/ReturnNotifyService", -- owner R122: return notifications (MemoryStore queue → Open Cloud)
	-- WHAT'S NEW change notes (owner R58, RoBeasts port): profile.notes seen record, no-context rule on
	-- load, ChangeNotesAction remote + analytics, purchase-flow hint, admin reset / preview commands.
	"ChangeNotesService",
	"ShopService",
	"Tycoon/PlotService",
	"Tycoon/TycoonService",
	-- Temporary area knockdown from attack hits (owner R50): per-area deadlines, production gating
	-- (TycoonService binds to it in Init), rebuild taps, immunity. Never persisted.
	"Tycoon/Knockdown",
	"Tycoon/OfflineService",
	"Tycoon/RebirthService",
	-- R89 Surprise Batches: server flavour rolls (TycoonService pay-path hook), Flavour Book claims,
	-- Big Pop broadcasts (Galaxy+ batch / Mythic+ hatch / rebirth).
	"Tycoon/FlavorService",
	-- Worlds (owner R57, W4): sticky unlock, validated travel between Nuke Town and Dino Valley,
	-- respawn in the current world, Time Machine portals, kill switch, admin World* commands.
	"Tycoon/WorldService",
	-- Mega Lever + Tip Jar (owner R90, K-kinetic): per-plot hands-on props in every world (reveal at
	-- KineticConfig.UnlockArea), KineticAction intents, the jar's server Touched, one 1 Hz loop,
	-- admin Kinetic* commands. After TycoonService / FlavorService / WorldService (it needs all three).
	"Kinetic/KineticService",
	-- Movement (owner R21): base WalkSpeed + Fast Walk pass + speed boosts, server-authoritative.
	"MovementService",
	-- Attack side mode (owner R3, B10): AA towers + shields first, then launches (needs Defense).
	"DefenseService",
	"AttackService",
	-- Pets / eggs (B9): pet inventory, hatching, equip, pet cash bonus; then crates (needs PetService
	-- for pet drops; registers the "Crate" product kind).
	"PetService",
	"CrateService",
	-- Harvest Feast event + global boards + badges (B11): EventService (turkeys, acorns, stickers,
	-- event shop; AcornPack / TurkeyLure products), LeaderboardService (OrderedDataStore boards),
	-- BadgeService (requires EventService).
	"EventService",
	"LeaderboardService",
	"BadgeService",
	-- Lucky Buttons (owner R69): random free / Robux buttons on the player's own plot; one 1 Hz
	-- loop, no server Instances (needs Tycoon / World / Plot / Knockdown / Monetization / Boost).
	"LuckyButtonService",
	-- Nukey's Happy Hours (owner R89): deterministic UTC mini-events (pure HappyHourLogic schedule),
	-- the cross-server admin override (DataStore + MessagingService), Double Pops' eventCash modifier,
	-- the 1 Hz pickup loop (Confetti Storm / Egg Stampede / Low-Gravity), admin HappyHour* commands.
	-- After LuckyButtonService (pickups reuse its placement + cash helpers through Lazy).
	"HappyHourService",
	-- Nuke Pass (owner R78): season XP (ProgressEvents.Xp + its once-per-minute play tick), claims,
	-- end-of-season auto-grant, the "PassPremium" product (needs Pets / Crate / Titles / Monetization).
	"PassService",
	-- Quests (owner R78): starter goals, daily missions, trophies; listens to ProgressEvents, owns
	-- the once-per-minute `playMinute` tick, QuestClaim / QuestReroll remotes, admin commands.
	"QuestService",
	-- Rush + Friends (owner R78): Rookie / Comeback Rush ("rush" modifier, offline = false) and the
	-- Friend Boost + invites + referral rewards ("friendBoost"; SellNukesReferrals_v1 queue). Needs
	-- PlayerData / Tycoon ModifierSources / Retention RewardGrant.
	"RushService",
	"FriendService",
	-- Lobby visitors (owner R100, L-lobby): builds the R15 template rigs (HumanoidDescription presets,
	-- server-only API) the clients clone into Nuke Town's lobby + the admin LobbyNpcs on / off switch.
	"World/LobbyNpcService",
	-- Owner admin panel (B14) goes LAST: it drives every service above through their admin seams,
	-- sets the `IsAdmin` attribute (owner R20: the HUD ADMIN button), serves the Analytics tab.
	"AdminService",
}

--[[
	Loads one feature service by name under pcall.
	@param name ModuleScript name in ./Services
	@return the service table, or nil (with a warning) when missing, erroring or malformed
	Example: loadFeature("PetService")
]]
local function loadFeature(name: string): Service?
	-- A bare name lives in ./Services; a slash path ("Tycoon/PlotService") resolves from this script
	-- so feature folders keep their own services.
	local module: Instance? = nil
	if string.find(name, "/", 1, true) == nil then
		module = Services:FindFirstChild(name)
	else
		module = script
		for _, segment in string.split(name, "/") do
			if module == nil then
				break
			end
			module = module:FindFirstChild(segment)
		end
	end
	if module == nil or not module:IsA("ModuleScript") then
		warn(`[Bootstrap] feature {name} is missing; skipped`)
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok then
		warn(`[Bootstrap] feature {name} failed to load: {result}`)
		return nil
	end
	if type(result) ~= "table" or type(result.Init) ~= "function" or type(result.Start) ~= "function" then
		warn(`[Bootstrap] feature {name} does not export Init/Start; skipped`)
		return nil
	end
	return result :: Service
end

--[[
	Requires the critical core (static requires, dependency order) and the feature services (by name,
	guarded), creates the remotes, then runs Init on all and Start on all. A CRITICAL failure throws
	with the failing step's name (the server cannot run without it); a FEATURE failure only warns and
	drops that feature.
]]
local function bootstrap()
	local CRITICAL: { { name: string, module: Service } } = {
		-- Profiles, persistence, profile sync, currency API (everything else depends on it).
		{ name = "PlayerDataService", module = require(Services.PlayerDataService) :: Service },
		-- Passes, products, receipts, prompts (needs PlayerDataService sessions / commits).
		{ name = "MonetizationService", module = require(Services.MonetizationService) :: Service },
		-- Aggregate analytics (B13; RoBeasts order): after PlayerData + Monetization, whose signals /
		-- setReceiptAccounting it hooks in Init. Gameplay services that report to it come after it.
		{ name = "AnalyticsService", module = require(Services.AnalyticsService) :: Service },
	}

	local features: { { name: string, module: Service } } = {}
	for _, name in FEATURE_SERVICES do
		local module = loadFeature(name)
		if module ~= nil then
			table.insert(features, { name = name, module = module })
		end
	end

	Remotes.createAll()

	for _, entry in CRITICAL do
		local ok, err = pcall(entry.module.Init)
		if not ok then
			error(`[Bootstrap] {entry.name}.Init failed: {err}`, 0)
		end
	end
	-- Features whose Init fails are not Started (their wiring is incomplete).
	local initialised: { { name: string, module: Service } } = {}
	for _, entry in features do
		local ok, err = pcall(entry.module.Init)
		if ok then
			table.insert(initialised, entry)
		else
			warn(`[Bootstrap] feature {entry.name}.Init failed; skipped: {err}`)
		end
	end

	for _, entry in CRITICAL do
		local ok, err = pcall(entry.module.Start)
		if not ok then
			error(`[Bootstrap] {entry.name}.Start failed: {err}`, 0)
		end
	end
	for _, entry in initialised do
		local ok, err = pcall(entry.module.Start)
		if not ok then
			warn(`[Bootstrap] feature {entry.name}.Start failed: {err}`)
		end
	end
	print(`[Bootstrap] features started: {#initialised}/{#FEATURE_SERVICES}`)
end

-- (The wrapper returns nil so `bootError` is typed as a string on both paths.)
local booted, bootError = xpcall(function(): string?
	bootstrap()
	return nil
end, function(message: unknown): string?
	return debug.traceback(tostring(message), 2)
end)
if not booted then
	if testArgs ~= nil then
		endTestRun(failedRun(`bootstrap failed: {bootError}`))
	end
	error(bootError, 0)
end

print(`[SellNukes] server started ({VersionConfig.label()})`)

-- Studio integration tests (Tests/TestRunner). Case exceptions become result rows; this boundary
-- also ends the run after suite-loading failures.
if testArgs ~= nil then
	local args = testArgs
	task.spawn(function()
		local ok, result = pcall(function()
			return require(script.Tests.TestRunner).run(args)
		end)
		if ok and type(result) == "table" then
			endTestRun(result)
		else
			endTestRun(failedRun(`test runner failed: {result}`))
		end
	end)
end
