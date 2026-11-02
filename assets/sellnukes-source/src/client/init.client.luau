--!strict
--[[
	Client bootstrap — the single client entry point (pattern from RoBeasts).

	Lifecycle (mirrors the server):
		1. Roblox default UI: the health bar and the backpack are hidden (SellNukes has no damage
		   and no tools); the player list, chat and the reset button stay.
		2. ClientState.start(): profile sync (full snapshot + deltas), toasts and purchase grants
		   are listened to ONCE, before any controller needs them.
		3. Init every controller (wiring only), then Start them, in ORDERED order:
		   InputController before CameraController (the camera reads input), UIController last
		   (screens read the started controllers). Later waves (B6 tycoon client, ...) append here.
		4. Marks the local player `ClientBooted` (a client-only attribute, never replicated) so a
		   loading screen can hand over once every controller has started.

	Robustness: each controller module is looked up by name and required under pcall, so a
	missing or broken controller (another builder mid-edit) is reported with its name and skipped
	instead of stopping the whole client. Init/Start errors are reported the same way.

	Yield safety (owner R103): every controller require, Init and Start runs through BootRunner in
	its own thread. A phase that returns without yielding behaves exactly like the old plain call
	(same order). A phase that YIELDS is waited for, in order, for at most
	ClientBootConfig.InitBudgetSeconds (require / Init) / StartBudgetSeconds (Start); then the boot
	carries on with the controllers behind it (a warning names the slow phase, which finishes in its
	own thread, and the boot line lists it). A controller never runs out of contract order: its
	Start follows its own Init, and a late require boots Init -> Start by itself once it loads.
	Before this, one yielding phase held every later controller (Tycoon/Fx/VehicleRoutes: the map
	vehicles stood still) and the ClientBooted loading-screen hand-off.

	Controller contract: a ModuleScript in ./Controllers returning a table with Init() and Start().
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local BootRunner = require(script.BootRunner)
local ClientBootConfig = require(ReplicatedStorage.Shared.Config.ClientBootConfig)
local ClientState = require(script.ClientState)

type Controller = { Init: () -> (), Start: () -> () }

-- Controller names in boot order. A bare name ("UIController") is a module in ./Controllers; a
-- slash path ("Analytics/ClientAnalytics") is resolved from this script, so feature folders
-- (Analytics, Tycoon, Pets, Attack, Event, Platform, ...) keep their own controllers. The lead
-- owns this list; each wave adds its entries here.
local ORDERED_NAMES: { string } = {
	"InputController",
	"CameraController",
	"UIController",
	-- WHAT'S NEW (owner R58): seen state, NEW dot, the once-per-join returning-player pop-up (after
	-- the loading screen / Welcome Back / any window), admin preview + replay.
	"ChangeNotes/ChangeNotesClient",
	-- Console + mobile layer (B16): action map (ContextActionService), device-glyph hint bar,
	-- touch buttons, TV-safe / notch insets, haptics, menu wheel. After UIController (needs ScreenManager).
	"Platform/PlatformController",
	-- Music + SFX (B4): SoundService groups + context music; `Audio/Sound.play(key, opts)` is the
	-- shared SFX API. Before the Tycoon controllers so the groups exist first (Sound.ensure is lazy).
	"Audio/SoundController",
	-- Worlds (owner R57): current world (CurrentWorld attr), lighting/music presets, travel intents +
	-- warp overlay, WORLD UNLOCKED popup, rejoin chip, Bones HUD swap. After UIController (HUD +
	-- screens) and SoundController (music override); screens require the module directly.
	"Worlds/WorldClient",
	-- Speed-scaled wind streaks + whoosh while running (owner R21, B13).
	"Movement/WindController",
	-- LEGO master-builder fly-in for every purchase, then piece-name-driven world FX (B4).
	"Tycoon/BuildIn/BuildInController",
	"Tycoon/Fx/WorldFxController",
	-- Juice pass (owner R71): pad-buy coins, milestone banner, unlock / rebirth fireworks + camera
	-- punch, finale confetti cannon, upgrade glow, manager puff, ambient income sparkles (the click
	-- combo rides ProducerBillboards.click). Cosmetic only; after WorldFxController (PadPressed).
	"Tycoon/Fx/JuiceController",
	-- R89 Surprise Batches: flavour-tinted income pops + sparkle, Rainbow+ producer glow (anyone),
	-- the Galaxy+ owner reveal, Big Pop banner + system chat line + toy fireworks.
	"Tycoon/FlavorController",
	-- Animated manager NPCs (R30): walk / work / wave / hop, one loop, FxQuality culled (N1).
	"Tycoon/Npc/ManagerController",
	-- Knockdown FX (owner R50): any CollectionService `KnockdownTarget` (plot areas + Rival
	-- Factory sections) topples like toy bricks while `KnockedUntil` is in the future, then rebuilds
	-- with the master-builder fly-in (Q3).
	"Tycoon/BuildIn/KnockdownFx",
	-- Map vehicles + machines (owner R56): van / semi / shopper car drive in + out, mine carts,
	-- forklift, lane scooters, belt rockets, garage barrier; one Heartbeat, FxQuality culled,
	-- pauses while an area is knocked down (V1).
	"Tycoon/Fx/VehicleRoutes",
	-- Pets (B9): follow renderer, egg-stand billboards, hatch / crate result routing (opens screens,
	-- so after UIController).
	"Pets/PetController",
	-- Attack side mode client (B10): flight arcs, interceptors, confetti hits, revenge chips.
	"Attack/AttackClient",
	-- Harvest Feast client (turkey renderer, event HUD button + screens) and the hub leaderboard
	-- SurfaceGui boards (B11).
	"Event/EventController",
	-- Lucky Buttons (owner R69): pooled plot buttons from the server's wire, walk-in claims,
	-- claim FX; the edge arrow is UI/Screens/LuckyButtons/LuckyArrowScreen.
	"LuckyButtons/LuckyButtonClient",
	-- Nukey's Happy Hours (owner R89): effective live / next event from the UTC schedule + the
	-- replicated admin override, start banner + sound, Double Pops bonus pops, Low-Gravity gravity,
	-- Confetti Storm sky and the own pickups (the HUD chip + schedule are UI/Screens/HappyHour).
	"HappyHour/HappyHourClient",
	-- Mega Lever + Tip Jar (owner R90, K-kinetic): countdown boards, arm swing, coin pile, the
	-- owner's hold prompts (KineticAction intents), chute ride / coin FX + CurrencyFly. After
	-- UIController (ScreenManager, HUD CurrencyFly) and PlatformController (Haptics).
	"Kinetic/KineticClient",
	-- Quests (owner R78): the client model of goals / missions / trophies — HUD Quests badge (+ Nuke
	-- Pass claimables), the post-tutorial objective chip, QuestClaim / QuestReroll intents.
	"Quests/QuestClient",
	-- Nuke Town lobby (owner R99-R101, L-lobby): Lucky Wheel stage prompt + walk-on + spinning wheel,
	-- group chest / codes board prompts, fixture sign captions, and the R15 lobby visitors. After
	-- UIController + Worlds/WorldClient (opens screens, reads the current world).
	"Lobby/LobbyController",
	"Leaderboards/LeaderboardBoardController",
	-- Player Titles (owner R73 / R74): the stud title tag over titled players (DEVELOPER, FIRST
	-- PLAYER, EARLY PLAYER) + the chat prefix (TextChatService.OnIncomingMessage), from the
	-- server-set Title / TitleHidden attributes.
	"Social/PlayerTitleClient",
	-- Rush + Friends (owner R78): rush timers from the profile, the server's Friend Boost, the
	-- Comeback Rush announcement and the SocialService invite prompt (BoostChips / Friends /
	-- WelcomeBack screens read it).
	"Social/SocialClient",
	-- Device + client-perf reporters and the funnel/screen/offer recorders UI code calls (B13).
	"Analytics/ClientAnalytics",
	-- First-minute funnel steps (owner R78 §6): loadingDone, hudShown, tutorialSeen, firstMove,
	-- firstScreenClosed + per-step tutorial views. After ClientAnalytics (it reports through it).
	"Tycoon/FtueTracker",
}

--[[
	Resolves a boot entry to its ModuleScript.
	@param name bare controller name (./Controllers) or a slash path relative to this script
	@return the ModuleScript, or nil when any path segment is missing
	Example: resolveModule("Analytics/ClientAnalytics") --> script.Analytics.ClientAnalytics
]]
local function resolveModule(name: string): Instance?
	if string.find(name, "/", 1, true) == nil then
		return script.Controllers:FindFirstChild(name)
	end
	local node: Instance? = script
	for _, segment in string.split(name, "/") do
		if node == nil then
			return nil
		end
		node = node:FindFirstChild(segment)
	end
	return node
end

-- Requires one controller by name; nil (with a warning naming it) when missing or broken.
local function loadController(name: string): Controller?
	local module = resolveModule(name)
	if module == nil or not module:IsA("ModuleScript") then
		warn(`[Client] controller {name} is missing; skipped`)
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok then
		warn(`[Client] controller {name} failed to load: {result}`)
		return nil
	end
	if type(result) ~= "table" or type(result.Init) ~= "function" or type(result.Start) ~= "function" then
		warn(`[Client] controller {name} does not export Init/Start; skipped`)
		return nil
	end
	return result :: Controller
end

for _, coreGui in { Enum.CoreGuiType.Health, Enum.CoreGuiType.Backpack } do
	StarterGui:SetCoreGuiEnabled(coreGui, false)
end

-- Server-pushed per-player state before any controller / screen needs it.
ClientState.start()

-- Budgets (BootRunner: a non-yielding phase is a plain in-order call; a yielding one is waited
-- for at most this long, then the boot moves on and the phase finishes in its own thread).
local initOptions: BootRunner.Options = { budget = ClientBootConfig.InitBudgetSeconds, warn = warn }
local startOptions: BootRunner.Options = { budget = ClientBootConfig.StartBudgetSeconds, warn = warn }

-- Required controller modules by boot name (nil = missing / broken / still loading).
local loaded: { [string]: Controller } = {}
-- Phases still finishing in their own thread when the boot completed (named in the boot line).
local slowPhases: { string } = {}

--[[
	Boots one controller whose require outlived the budget, once that require settles: its Init,
	then its Start (after the Init settles), each under its own budget, in this thread.
	@param name string boot name from ORDERED_NAMES
]]
local function bootLate(name: string)
	local module = loaded[name]
	if module == nil then
		return -- loadController already warned (missing / broken)
	end
	local initJob = BootRunner.run(`{name}.Init`, module.Init, initOptions)
	BootRunner.after(initJob, `{name}.Start`, module.Start, startOptions)
end

-- 1. Require every controller, in order (a module whose top level yields cannot hold the rest).
local loadJobs: { BootRunner.Job } = {}
for index, name in ORDERED_NAMES do
	loadJobs[index] = BootRunner.run(`{name} (require)`, function()
		loaded[name] = loadController(name)
	end, initOptions)
end
-- 2. Init every loaded controller (wiring only), in order; a late require boots on its own.
local initJobs: { [number]: BootRunner.Job } = {}
for index, name in ORDERED_NAMES do
	local loadJob = loadJobs[index]
	local module = loaded[name]
	if loadJob.status == "running" then
		table.insert(slowPhases, loadJob.label)
		BootRunner.onSettled(loadJob, function()
			bootLate(name)
		end)
	elseif module ~= nil then
		initJobs[index] = BootRunner.run(`{name}.Init`, module.Init, initOptions)
	end
end
-- 3. Start them, in order; a controller whose Init is still yielding starts once it settles.
local controllerCount = 0
for index, name in ORDERED_NAMES do
	local initJob = initJobs[index]
	local module = loaded[name]
	if initJob ~= nil and module ~= nil then
		controllerCount += 1
		if initJob.status == "running" then
			table.insert(slowPhases, initJob.label)
		end
		local startJob = BootRunner.after(initJob, `{name}.Start`, module.Start, startOptions)
		if startJob ~= nil and startJob.status == "running" then
			table.insert(slowPhases, startJob.label)
		end
	end
end

Players.LocalPlayer:SetAttribute("ClientBooted", true)

-- Same prefix as always (QA probes read it); slow phases (still finishing in their own thread) are
-- named so a stalled controller shows up in the published game's console too.
local slowNote = if #slowPhases > 0 then `; still booting: {table.concat(slowPhases, ", ")}` else ""
print(`[SellNukes] client started ({controllerCount}/{#ORDERED_NAMES} controllers{slowNote})`)
