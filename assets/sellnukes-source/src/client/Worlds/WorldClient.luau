--!strict
--[[
	WorldClient — the client side of the worlds framework (owner R57 World 2 "Dino Valley", spec §4 /
	§14, plan §3.5). A boot controller (Init / Start): "Worlds/WorldClient".

	What it does (display + intents only; the server decides every trip):
		- WHERE AM I: `current()` = the server-set Player attribute CurrentWorld ("main" default,
		  junk ignored). `Changed(worldId, previous)` fires on every change (travel, kill-switch
		  evacuation, admin moves), and the client swaps:
		    * the Lighting preset (WorldClientConfig.Lighting[def.ambience.lighting]: Atmosphere,
		      the client-only "WorldTint" ColorCorrection, Ambient / OutdoorAmbient — never
		      ClockTime; Nuke Town's look is CAPTURED at boot and restored exactly; R70: a preset's
		      optional `Sky` swaps in a client-only Sky "WorldSky" — Moon Base's star field — and
		      the place's own Sky is parked, then put back on the way out),
		    * the gravity (R70, Worlds/WorldGravity: WorldClientConfig.Physics[worldId]
		      .gravityScale, Moon Base 0.4, + the landing boing / dust puff),
		    * the music (WorldClientConfig.Music -> SoundController.setOverride) and the world's
		      ambience bed (Music[key].bed, e.g. the Dino jungle bed: a soft 2D loop re-triggered
		      every track length, stopped the moment the player leaves),
		    * the HUD (Hud.setWorld: Bones primary + Cash pill, Attack hidden, offers rotation),
		    * the first-run objective chip (Worlds/WorldObjectives -> Hud.setWorldObjective).
		- TRAVEL: `travel(worldId, target, index?, source)` sends the TravelWorld INTENT (client
		  throttle 1 / s; a locked world never sends — it opens the locked preview). The server's
		  WorldTravel phases drive the warp overlay (UI/Screens/WorldTravel): "out" opens it and
		  preloads the destination's meshes (PreloadList.world), "in" warps in, "fail" closes it and
		  toasts WorldClientConfig.FailText[reason] (a locked portal also opens the locked preview).
		- WORLD UNLOCKED popup (spec §4.2): once per join when the server stamped `unlockedAt` after
		  this session began (anchor = this join's server-set PlotAssignedAt, else the first synced
		  clock reading, never the unsynced 0; a world that is locked again owes it again, so an
		  admin relock + unlock re-tests it; W12 QA), at a polite moment (the WHAT'S NEW gate:
		  loading done, no window, no focus mode, no plot reveal, no purchase prompt, WHAT'S NEW
		  not pending).
		- Teleport NEW dot until the first visit (worlds.<id>.stats.visits == 0).
		- REJOIN chip (spec §4.6): "Back to Dino Valley? [GO] [X]" after the plot reveal when the last
		  session ended in another world (UI/Screens/WorldTravel/WorldRejoinScreen).
		- `isUnlocked(id)` / `isEnabled(id)` (admin kill switch: ReplicatedStorage attribute
		  WorldEnabled_<id>) for the tabbed screens; `StateChanged` fires when either may have
		  changed.

	Analytics (W12 ClientAnalytics): every screen this module opens carries a funnel `source`
	(WorldClientConfig.AnalyticsSource): the overlay / a locked preview report the client's own
	recent intent ("hud" for the Teleport menu, "popup", "chip") or "portal" when the server
	started the trip; the WORLD UNLOCKED celebration reports "auto". The screens send them.

	Security: the client sends intents only (worldId, target, index, source); every inbound
	WorldTravel payload is shape-checked (known world, allowlisted phase, short reason string) and
	is cosmetic. Nothing here reads or writes economy values.

	Performance: event-driven (attribute / profile / remote signals); the polite-moment wait runs
	only while a popup is owed (1 Hz, bounded); preloads run in their own task; lighting tweens
	run only on a world change.

	Connects to: Client/ClientState, Shared/Net/Remotes (TravelWorld C→S, WorldTravel S→C),
	Shared/Config/{WorldClientConfig, Worlds/WorldsConfig, AudioConfig, ChangeNotesConfig},
	Worlds/{WorldClientLogic, WorldObjectives, WorldGravity}, UI/{ScreenManager, Hud/Hud, Widgets/LoadingGate},
	Audio/SoundController, Tycoon/{TycoonWorld, PlotReveal}, ChangeNotes/ChangeNotesClient,
	Shared/World/PreloadList (W3), screens WorldTravel / WorldRejoin / WorldUnlocked.

	Example:
		WorldClient.Changed:Connect(function(worldId, previous) print(previous, "->", worldId) end)
		WorldClient.travel("dino", "spawn", nil, "menu")
		if WorldClient.current() == "dino" then ... end
]]

local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)
local ChangeNotesConfig = require(ReplicatedStorage.Shared.Config.ChangeNotesConfig)
local ClientState = require(script.Parent.Parent.ClientState)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SoundAssets = require(ReplicatedStorage.Shared.Config.SoundAssets)
local WorldClientConfig = require(ReplicatedStorage.Shared.Config.WorldClientConfig)
local WorldClientLogic = require(script.Parent.WorldClientLogic)
local WorldGravity = require(script.Parent.WorldGravity)
local WorldObjectives = require(script.Parent.WorldObjectives)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

-- UI / audio / tycoon modules are required lazily (Start) so this module stays cheap to require
-- from any screen and never forms a require cycle with the HUD.
type HudApi = {
	setWorld: (worldId: string) -> (),
	setWorldObjective: (text: string?, target: any?) -> (),
	setButtonNew: (key: string, on: boolean) -> (),
	notify: (kind: string, text: string, icon: string?) -> (),
}
type ScreenApi = {
	open: (name: string, args: any?) -> (),
	close: (name: string) -> (),
	isOpen: (name: string) -> boolean,
	anyModalOpen: () -> boolean,
	isFocusMode: () -> boolean,
}

export type TravelTarget = "spawn" | "area" | "plot"
export type TravelSource = "menu" | "popup" | "chip"
export type TravelPhase = "out" | "in" | "fail"
-- One validated WorldTravel push (cosmetic).
export type TravelEvent = { worldId: string, phase: TravelPhase, reason: string?, at: number }

local WorldClient = {}

WorldClient.Changed = Signal.new() :: Signal.Signal<string, string>
-- Unlocks, the kill switch, first visits: tabbed screens / the HUD dot re-render.
WorldClient.StateChanged = Signal.new() :: Signal.Signal<>
-- Every validated WorldTravel push (the overlay screen listens).
WorldClient.Phase = Signal.new() :: Signal.Signal<TravelEvent>

-- Screen names (UI/Screens/WorldTravel, UI/Screens/WorldUnlocked).
WorldClient.TravelScreen = "WorldTravel"
WorldClient.RejoinScreen = "WorldRejoin"
WorldClient.UnlockScreen = "WorldUnlocked"

local MAIN = WorldsConfig.MAIN
local CURRENT_ATTR = "CurrentWorld"
local REVEALED_ATTR = "PlotRevealed"
local MAX_REASON = 32
local PHASES: { [string]: boolean } = { out = true, ["in"] = true, fail = true }

local localPlayer = Players.LocalPlayer
-- The WORLD UNLOCKED "once per join" anchor (WorldClientLogic.sessionAnchor; W12 QA fix): the
-- first PlotAssignedAt the server set on this join, else the first SYNCED clock reading. Never
-- sampled at module load: GetServerTimeNow() reads 0 until the client clock syncs.
local PLOT_ASSIGNED_ATTR = "PlotAssignedAt"
-- Most seconds the boot waits for the first synced clock reading (fallback anchor).
local SYNC_WAIT_SECONDS = 30
local plotAssignedAt: number? = nil
local firstSynced: number? = nil
local started = false
local applied: string? = nil -- the world whose presentation is applied
local lastTravelAt = -math.huge
local lastFailToast: { [string]: number } = {}
local lastLockedPreview = -math.huge
local unlockShown: { [string]: boolean } = {}
-- Owner R130: the Nuke Town area when this session's profile first synced (nil = not yet) — a
-- world unlocked in an earlier session owes its popup when the player crosses the popup area in
-- THIS session — and the last area seen (a change re-checks the popup; WorldClientLogic.unlockPopupOwed).
local sessionStartArea: number? = nil
local lastMainArea: number? = nil
local rejoinDone = false
local pendingTravel: string? = nil -- world of the trip in flight (overlay open)
local hud: HudApi? = nil
local screens: ScreenApi? = nil
local objectiveStep: WorldObjectives.Step? = nil
-- The ambience bed looping now (AudioConfig.Sfx key) + its loop task's generation.
local playingBed: string? = nil
local bedGeneration = 0
-- The last travel intent this client sent (the origin of the next "out" phase; analytics).
local lastIntent: { worldId: string, source: TravelSource, at: number }? = nil

-- Lighting state captured at boot (Nuke Town's look).
type AtmosphereCapture = { atmosphere: Atmosphere, look: WorldClientConfig.AtmosphereLook }
local capturedAtmospheres: { AtmosphereCapture } = {}
local capturedAmbient: Color3? = nil
local capturedOutdoor: Color3? = nil
local tintEffect: ColorCorrectionEffect? = nil
-- R70 night skies: the client-only "WorldSky" while a preset has a Sky look, and the place's own
-- Sky instances parked (Parent = nil) meanwhile, restored when the look goes away.
local worldSky: Sky? = nil
local parkedSkies: { Sky } = {}
local NEUTRAL_TINT: WorldClientConfig.TintLook =
	{ TintColor = Color3.new(1, 1, 1), Saturation = 0, Contrast = 0, Brightness = 0 }

-- A finite number, else nil.
local function finite(value: unknown): number?
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- This session's anchor (nil = not known yet). PlotAssignedAt is latched on first sight, so a
-- later plot re-assignment never moves it.
local function sessionAnchor(): number?
	if plotAssignedAt == nil then
		local value = finite(localPlayer:GetAttribute(PLOT_ASSIGNED_ATTR))
		if value ~= nil and value > 0 then
			plotAssignedAt = value
		end
	end
	return WorldClientLogic.sessionAnchor(plotAssignedAt, firstSynced)
end

--[[
	The world the player is in (server-set Player attribute CurrentWorld; "main" when unset or
	not a known world).
	Example: if WorldClient.current() == "dino" then ... end
]]
function WorldClient.current(): string
	local value = localPlayer:GetAttribute(CURRENT_ATTR)
	if type(value) == "string" and WorldsConfig.get(value) ~= nil then
		return value
	end
	return MAIN
end

--[[ True when the server says `worldId` is unlocked for this player ("main" always). Display only. ]]
function WorldClient.isUnlocked(worldId: string): boolean
	return ClientState.worldUnlocked(worldId)
end

--[[
	True unless the admin kill switch closed `worldId` (ReplicatedStorage attribute
	WorldEnabled_<id> == false). Nuke Town is always open.
]]
function WorldClient.isEnabled(worldId: string): boolean
	if worldId == MAIN then
		return true
	end
	return ReplicatedStorage:GetAttribute(WorldClientConfig.EnabledAttrPrefix .. worldId) ~= false
end

--[[ The world tab model for the current state (WorldClientLogic.tabs). ]]
function WorldClient.tabs(): { WorldClientLogic.Tab }
	return WorldClientLogic.tabs(WorldClient.current(), WorldClient.isUnlocked, WorldClient.isEnabled)
end

--[[ The trip in flight (the overlay's destination), or nil. ]]
function WorldClient.pending(): string?
	return pendingTravel
end

--[[
	Toasts a travel failure (same reason at most once per FailToastGap seconds), with the icon of
	the portal the trip used: the destination's (Time Machine, Moon rocket, ...), or — for a trip
	home — the portal of the world the player is leaving.
]]
local function failToast(reason: string?, worldId: string)
	local key = reason or "?"
	local now = os.clock()
	if now - (lastFailToast[key] or -math.huge) < WorldClientConfig.FailToastGap then
		return
	end
	lastFailToast[key] = now
	local api = hud
	if api ~= nil then
		local portalWorld = if worldId == MAIN then WorldClient.current() else worldId
		api.notify("error", WorldClientLogic.failText(reason), WorldClientLogic.portal(portalWorld).icon)
	end
end

--[[
	Opens the WORLD UNLOCKED popup in locked-preview mode for `worldId` (a locked portal / tab),
	throttled to once per FailToastGap.
	@param source the analytics origin ("portal" = a Time Machine portal, "hud" = a menu / tab;
	              default "portal"); the popup reports it (ClientAnalytics.screenOpened)
	Example: WorldClient.previewLocked("dino", "hud")
]]
function WorldClient.previewLocked(worldId: string, source: string?)
	local now = os.clock()
	if now - lastLockedPreview < WorldClientConfig.FailToastGap then
		return
	end
	lastLockedPreview = now
	local api = screens
	if api ~= nil and not api.isOpen(WorldClient.UnlockScreen) then
		api.open(WorldClient.UnlockScreen, { worldId = worldId, mode = "locked", source = source or "portal" })
	end
end

--[[
	Sends a travel INTENT (the server validates everything: unlock, kill switch, reveal, area,
	plot, pass, cooldown). A locked world never sends (locked preview instead); a closed world
	toasts. Client throttle: WorldClientConfig.TravelThrottleSeconds.
	@param worldId a WorldsConfig id
	@param target  "spawn" (that world's hub) | "area" (own plot area `index`) | "plot" (plot `index`)
	@param index   area / plot number (nil for spawn)
	@param source  "menu" | "popup" | "chip" (display / analytics only)
	@return true when the intent was sent
	Example: WorldClient.travel("dino", "area", 2, "menu")
]]
function WorldClient.travel(worldId: string, target: TravelTarget, index: number?, source: TravelSource): boolean
	if WorldsConfig.get(worldId) == nil then
		return false
	end
	if not WorldClient.isEnabled(worldId) then
		failToast("disabled", worldId)
		return false
	end
	if not WorldClient.isUnlocked(worldId) then
		WorldClient.previewLocked(worldId, WorldClientConfig.AnalyticsSource[source] or "other")
		return false
	end
	local now = os.clock()
	if not WorldClientLogic.travelAllowed(now, lastTravelAt, WorldClientConfig.TravelThrottleSeconds) then
		return false
	end
	lastTravelAt = now
	lastIntent = { worldId = worldId, source = source, at = now }
	local remote: any = Remotes.event("TravelWorld")
	if index ~= nil then
		remote:FireServer(worldId, target, index, source)
	else
		remote:FireServer(worldId, target, nil, source)
	end
	return true
end

-- Lighting -------------------------------------------------------------------------------------

-- Captures Nuke Town's look once (every Atmosphere, Ambient, OutdoorAmbient) + the tint effect.
local function captureLighting()
	for _, child in Lighting:GetChildren() do
		if child:IsA("Atmosphere") then
			table.insert(capturedAtmospheres, {
				atmosphere = child,
				look = {
					Density = child.Density,
					Offset = child.Offset,
					Color = child.Color,
					Decay = child.Decay,
					Glare = child.Glare,
					Haze = child.Haze,
				},
			})
		end
	end
	capturedAmbient = Lighting.Ambient
	capturedOutdoor = Lighting.OutdoorAmbient
	-- A client-only ColorCorrection layered on the place's own (neutral = no change).
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = WorldClientConfig.TintName
	effect.TintColor = NEUTRAL_TINT.TintColor
	effect.Saturation = 0
	effect.Contrast = 0
	effect.Brightness = 0
	effect.Parent = Lighting
	tintEffect = effect
end

-- Tweens `object` to `goal` over the configured lighting time (hidden under the warp overlay).
local function tweenTo(object: Instance, goal: { [string]: any })
	TweenService:Create(
		object,
		TweenInfo.new(WorldClientConfig.LightingTween, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		goal
	):Play()
end

--[[
	Swaps the sky (R70): a Sky look (validated with the preset by WorldClientLogic.validateSky)
	parks every Sky the place has in Lighting and shows one client-only "WorldSky" built from the
	look; nil puts the parked skies back and removes WorldSky. Instant (it happens under the warp
	overlay), idempotent, never touches ClockTime.
]]
local function applySky(look: any?)
	if look == nil then
		local sky = worldSky
		if sky ~= nil then
			sky:Destroy()
			worldSky = nil
		end
		for _, parked in parkedSkies do
			parked.Parent = Lighting
		end
		table.clear(parkedSkies)
		return
	end
	for _, child in Lighting:GetChildren() do
		if child:IsA("Sky") and child ~= worldSky then
			child.Parent = nil
			table.insert(parkedSkies, child)
		end
	end
	local sky = worldSky
	if sky == nil then
		local created = Instance.new("Sky")
		created.Name = "WorldSky"
		sky = created
		worldSky = created
	end
	local target = sky :: Sky
	target.SkyboxBk = look.SkyboxBk
	target.SkyboxDn = look.SkyboxDn
	target.SkyboxFt = look.SkyboxFt
	target.SkyboxLf = look.SkyboxLf
	target.SkyboxRt = look.SkyboxRt
	target.SkyboxUp = look.SkyboxUp
	target.StarCount = look.StarCount
	target.CelestialBodiesShown = look.CelestialBodiesShown
	target.SunAngularSize = look.SunAngularSize
	target.Parent = Lighting
end

-- Applies a lighting preset (captured = Nuke Town's own look).
local function applyLighting(presetKey: string)
	local preset = WorldClientConfig.Lighting[presetKey] or WorldClientConfig.Lighting.main
	local ok = WorldClientLogic.validatePreset(preset)
	if not ok then
		preset = WorldClientConfig.Lighting.main
	end
	local ambient = if preset.capture then capturedAmbient else preset.Ambient
	local outdoor = if preset.capture then capturedOutdoor else preset.OutdoorAmbient
	if ambient ~= nil and outdoor ~= nil then
		tweenTo(Lighting, { Ambient = ambient, OutdoorAmbient = outdoor })
	end
	for _, entry in capturedAtmospheres do
		if entry.atmosphere.Parent ~= nil then
			local look = if preset.capture then entry.look else preset.Atmosphere
			if look ~= nil then
				tweenTo(entry.atmosphere, {
					Density = look.Density,
					Offset = look.Offset,
					Color = look.Color,
					Decay = look.Decay,
					Glare = look.Glare,
					Haze = look.Haze,
				})
			end
		end
	end
	applySky(if preset.capture then nil else (preset :: any).Sky)
	local effect = tintEffect
	if effect ~= nil then
		local look = if preset.capture then NEUTRAL_TINT else (preset.Tint or NEUTRAL_TINT)
		tweenTo(effect, {
			TintColor = look.TintColor,
			Saturation = look.Saturation,
			Contrast = look.Contrast,
			Brightness = look.Brightness,
		})
	end
end

-- Music: the world's playlist (or automatic Nuke Town contexts).
--[[
	The world's ambience bed (spec §14, e.g. Dino Valley's jungle bed): stops the previous bed and,
	when the new world has one, plays it now and re-triggers it every track length until the
	world changes again. One task per bed, cancelled by the generation counter (never stacks).
	Sound.play honours the SFX setting (a muted group never decodes the bed).
]]
local function applyBed(musicKey: string)
	local ok, Sound = pcall(require, script.Parent.Parent.Audio.Sound)
	if not ok then
		return
	end
	local bed, period = WorldClientLogic.ambienceBed(musicKey, function(key: string): boolean
		return AudioConfig.Sfx[key] ~= nil
	end, function(key: string): number?
		local track = SoundAssets.LibrarySfx[key]
		return if track ~= nil then track.seconds else nil
	end)
	if bed == playingBed then
		return -- the same bed (or none) keeps looping untouched
	end
	bedGeneration += 1
	local generation = bedGeneration
	local previous = playingBed
	if previous ~= nil then
		Sound.stop(previous)
	end
	playingBed = bed
	if bed == nil then
		return
	end
	task.spawn(function()
		while generation == bedGeneration do
			Sound.play(bed)
			task.wait(period)
		end
	end)
end

local function applyMusic(musicKey: string)
	local ok, SoundController = pcall(require, script.Parent.Parent.Audio.SoundController)
	if ok then
		local context = WorldClientLogic.musicContext(musicKey, function(name: string): boolean
			return AudioConfig.Contexts[name] ~= nil
		end)
		SoundController.setOverride(context)
	end
	applyBed(musicKey)
end

-- Objective chip ---------------------------------------------------------------------------------

-- Resolves an objective step's world target (a pad / producer of the own plot), or nil.
local function objectiveTarget(step: WorldObjectives.Step): any?
	local ok, TycoonWorld = pcall(require, script.Parent.Parent.Tycoon.TycoonWorld)
	if not ok then
		return nil
	end
	if step.padId ~= nil then
		return TycoonWorld.myPad(step.padId)
	elseif step.producerId ~= nil then
		return TycoonWorld.myProducer(step.producerId)
	end
	return nil
end

-- Re-computes the first-run objective of the current world (nil in Nuke Town).
local function refreshObjective()
	local api = hud
	if api == nil then
		return
	end
	local worldId = WorldClient.current()
	local world = ClientState.world(worldId)
	local step: WorldObjectives.Step? = nil
	if world ~= nil then
		step = WorldObjectives.next(world.tycoon, worldId, finite(world.rebirths))
	end
	objectiveStep = step
	if step == nil then
		api.setWorldObjective(nil, nil)
	else
		api.setWorldObjective(step.text, objectiveTarget(step))
	end
end

-- Presentation ------------------------------------------------------------------------------------

-- Applies the current world's lighting, music, HUD and objective (no-op when already applied).
local function applyWorld(force: boolean?)
	local worldId = WorldClient.current()
	if worldId == applied and not force then
		return
	end
	local previous = applied or MAIN
	applied = worldId
	local def = WorldsConfig.get(worldId) or WorldsConfig.get(MAIN)
	if def ~= nil then
		applyLighting(def.ambience.lighting)
		applyMusic(def.ambience.music)
	end
	local api = hud
	if api ~= nil then
		api.setWorld(worldId)
	end
	refreshObjective()
	if previous ~= worldId then
		WorldClient.Changed:Fire(worldId, previous)
		WorldClient.StateChanged:Fire()
	end
end

-- The Teleport NEW dot: any unlocked, never-visited world.
local function refreshNewDot()
	local api = hud
	if api == nil then
		return
	end
	local any = false
	for _, def in WorldsConfig.extra() do
		if WorldClient.isEnabled(def.id) and WorldClientLogic.isNewWorld(ClientState.world(def.id)) then
			any = true
			break
		end
	end
	api.setButtonNew("Teleport", any)
end

-- Polite moments (the WHAT'S NEW gate) --------------------------------------------------------------

--[[
	Why a popup may NOT open now (nil = a polite moment): loading screen, a window, focus mode,
	the plot-reveal fly-over, a centre popup (PopupQueue: reveal / Big Pop / banner, owner R102),
	a Roblox purchase prompt, the warp overlay, WHAT'S NEW pending.
]]
local function impoliteReason(): string?
	local LoadingGate = require(script.Parent.Parent.UI.Widgets.LoadingGate)
	if not LoadingGate.isDone() then
		return "loading"
	end
	local api = screens
	if api == nil then
		return "boot"
	end
	if api.isFocusMode() then
		return "focus"
	end
	if api.anyModalOpen() then
		return "modal"
	end
	if pendingTravel ~= nil then
		return "travel"
	end
	local revealOk, PlotReveal = pcall(require, script.Parent.Parent.Tycoon.PlotReveal)
	if revealOk and PlotReveal.isPlaying() then
		return "plotReveal"
	end
	-- Owner R102: never open over a reveal / banner in PopupQueue's centre lane; wait for it.
	local queueOk, PopupQueue = pcall(require, script.Parent.Parent.UI.Widgets.PopupQueue)
	if queueOk and PopupQueue.centerActive() then
		return "popup"
	end
	if localPlayer:GetAttribute(ChangeNotesConfig.PurchaseFlow.Attr) ~= nil then
		return "purchaseFlow"
	end
	local notesOk, ChangeNotesClient = pcall(require, script.Parent.Parent.ChangeNotes.ChangeNotesClient)
	if notesOk and ChangeNotesClient.holdsPopups() then
		return "whatsNew"
	end
	return nil
end

-- The player's Nuke Town area from the synced profile (0 = no profile yet).
local function mainArea(): number
	local profile = ClientState.profile
	local tycoon = if profile ~= nil then profile.tycoon else nil
	local area = if type(tycoon) == "table" then finite(tycoon.area) else nil
	return if area ~= nil and area >= 0 then math.floor(area) else 0
end

--[[
	Owner R130: whether `def`'s WORLD UNLOCKED popup is owed now — unlocked, the player has moved
	one Nuke Town area past the unlock area (or rebirthed), and either the unlock or that move
	happened this session (WorldClientLogic.unlockPopupOwed has the full rule).
]]
local function unlockOwed(def: WorldsConfig.WorldDef): boolean
	local world = ClientState.world(def.id)
	if world == nil then
		return false
	end
	local profile = ClientState.profile
	local stats = world.stats
	return WorldClientLogic.unlockPopupOwed({
		unlocked = world.unlocked == true,
		unlockedAt = world.unlockedAt,
		anchor = sessionAnchor(),
		slack = WorldClientConfig.Unlock.JoinSlackSeconds,
		mainArea = mainArea(),
		startArea = sessionStartArea,
		rebirths = if profile ~= nil then profile.rebirths else nil,
		visits = if type(stats) == "table" then stats.visits else nil,
		popupArea = WorldClientLogic.popupArea(def),
	})
end

-- The worlds whose WORLD UNLOCKED popup is owed this session (not shown yet).
local function owedUnlock(): string?
	for _, def in WorldsConfig.extra() do
		if not unlockShown[def.id] and unlockOwed(def) then
			return def.id
		end
	end
	return nil
end

-- The world the rejoin chip offers, or nil (once per session, after the plot reveal).
local function owedRejoin(): string?
	if rejoinDone or ClientState.profile == nil then
		return nil
	end
	if localPlayer:GetAttribute(REVEALED_ATTR) ~= true then
		return nil
	end
	local last = ClientState.lastWorld()
	if
		WorldClientLogic.rejoinOffer(
			last,
			WorldClient.current(),
			WorldClient.isUnlocked(last),
			WorldClient.isEnabled(last)
		)
	then
		return last
	end
	rejoinDone = true -- nothing to offer this session
	return nil
end

local waiting = false

-- Waits (1 Hz, bounded) for a polite moment, then opens the owed popup(s): unlock first.
local function considerPopups()
	if waiting or not started then
		return
	end
	if owedUnlock() == nil and owedRejoin() == nil then
		return
	end
	waiting = true
	task.spawn(function()
		local unlock = WorldClientConfig.Unlock
		task.wait(unlock.FirstCheckDelay)
		local waited, streak = 0, 0
		while true do
			local unlockWorld = owedUnlock()
			local rejoinWorld = owedRejoin()
			if unlockWorld == nil and rejoinWorld == nil then
				break
			end
			local reason = impoliteReason()
			streak = if reason == nil then streak + 1 else 0
			local api = screens
			if streak >= unlock.PoliteChecks and api ~= nil then
				streak = 0
				if unlockWorld ~= nil then
					unlockShown[unlockWorld] = true
					api.open(
						WorldClient.UnlockScreen,
						{ worldId = unlockWorld, mode = "unlocked", source = WorldClientConfig.AnalyticsSource.auto }
					)
				elseif rejoinWorld ~= nil then
					rejoinDone = true
					task.wait(WorldClientConfig.Rejoin.DelayAfterReveal)
					if impoliteReason() == nil and WorldClient.current() == MAIN then
						api.open(WorldClient.RejoinScreen, { worldId = rejoinWorld })
					end
				end
			end
			if reason ~= "loading" then
				waited += unlock.CheckSeconds
			end
			if waited >= unlock.WaitSeconds then
				-- No polite moment this session: give up (the Teleport NEW dot still points the way).
				for _, def in WorldsConfig.extra() do
					unlockShown[def.id] = true
				end
				rejoinDone = true
				break
			end
			task.wait(unlock.CheckSeconds)
		end
		waiting = false
	end)
end

--[[
	Read-only snapshot of the popup gate (QA probe tools/qa/worlds_ui_client.luau + debugging):
	whether the polite-moment wait runs, what is owed, why now is not polite, and the unlock
	stamps the once-rule compares. Changes nothing (owedRejoin's "nothing to offer" latch is
	not touched: the rejoin rule is evaluated without it).
	Example: print(WorldClient.popupState().impolite) --> "whatsNew"
]]
function WorldClient.popupState(): { [string]: any }
	local shown: { string } = {}
	for id, on in unlockShown do
		if on then
			table.insert(shown, id)
		end
	end
	local owed = owedUnlock()
	-- unlockedAt per extra world (R70: every world, not just Dino Valley) + the R130 area gate.
	local unlockedAt: { [string]: number } = {}
	local popupAreas: { [string]: number } = {}
	for _, def in WorldsConfig.extra() do
		local world = ClientState.world(def.id)
		local stamp = if world ~= nil then finite(world.unlockedAt) else nil
		if stamp ~= nil then
			unlockedAt[def.id] = stamp
		end
		popupAreas[def.id] = WorldClientLogic.popupArea(def)
	end
	local ok, reason = pcall(impoliteReason)
	return {
		started = started,
		waiting = waiting,
		owedUnlock = owed,
		rejoinDone = rejoinDone,
		unlockShown = shown,
		impolite = if ok then reason or "polite" else `error: {reason}`,
		anchor = sessionAnchor(),
		plotAssignedAt = plotAssignedAt,
		firstSynced = firstSynced,
		unlockedAt = unlockedAt,
		popupAreas = popupAreas,
		mainArea = mainArea(),
		sessionStartArea = sessionStartArea,
		serverNow = Workspace:GetServerTimeNow(),
	}
end

-- Remote: WorldTravel ------------------------------------------------------------------------------

-- Preloads the destination world's meshes behind the overlay (W3 PreloadList.world, when present).
local function preload(worldId: string)
	task.spawn(function()
		local ok, PreloadList = pcall(require, ReplicatedStorage.Shared.World.PreloadList)
		if not ok then
			return
		end
		local worldKeys = (PreloadList :: any).world
		if type(worldKeys) ~= "function" then
			return
		end
		local world = ClientState.world(worldId)
		local keysOk, keys = pcall(worldKeys, worldId, if world ~= nil then world.tycoon else nil)
		if not keysOk or type(keys) ~= "table" then
			return
		end
		local ids = PreloadList.contentIds(keys)
		if #ids > 0 then
			pcall(function()
				ContentProvider:PreloadAsync(ids)
			end)
		end
	end)
end

-- Validates one WorldTravel push; nil when malformed (ignored).
local function parseTravel(payload: unknown): TravelEvent?
	if type(payload) ~= "table" then
		return nil
	end
	local raw = payload :: { [string]: unknown }
	local worldId, phase, reason = raw.worldId, raw.phase, raw.reason
	if type(worldId) ~= "string" or WorldsConfig.get(worldId) == nil then
		return nil
	end
	if type(phase) ~= "string" or not PHASES[phase] then
		return nil
	end
	local cleanReason: string? = nil
	if type(reason) == "string" and #reason >= 1 and #reason <= MAX_REASON then
		cleanReason = reason
	end
	return {
		worldId = worldId,
		phase = phase :: TravelPhase,
		reason = cleanReason,
		at = finite(raw.at) or Workspace:GetServerTimeNow(),
	}
end

--[[
	The analytics origin of an "out" phase for `worldId`: the client's own recent intent to that
	world (WorldClientConfig.AnalyticsSource of "menu" / "popup" / "chip"), else "portal" (a Time
	Machine prompt / touch volume — the server started the trip). Consumes the intent.
]]
local function originOf(worldId: string): string
	local intent = lastIntent
	lastIntent = nil
	if
		intent ~= nil
		and intent.worldId == worldId
		and os.clock() - intent.at <= WorldClientConfig.IntentMatchSeconds
	then
		return WorldClientConfig.AnalyticsSource[intent.source] or "other"
	end
	return WorldClientConfig.AnalyticsSource.portal
end

-- Handles a validated travel phase (overlay, preload, toasts).
local function onTravel(event: TravelEvent)
	local api = screens
	if event.phase == "out" then
		pendingTravel = event.worldId
		local source = originOf(event.worldId)
		if api ~= nil then
			api.open(
				WorldClient.TravelScreen,
				{ worldId = event.worldId, hop = event.worldId == WorldClient.current(), source = source }
			)
		end
		if event.worldId ~= WorldClient.current() then
			preload(event.worldId)
		end
	elseif event.phase == "in" then
		pendingTravel = nil
		-- The attribute normally changed already; apply anyway (idempotent).
		applyWorld()
	else
		pendingTravel = nil
		if api ~= nil and api.isOpen(WorldClient.TravelScreen) then
			api.close(WorldClient.TravelScreen)
		end
		failToast(event.reason, event.worldId)
		-- A refused trip the client never asked for came from a portal; else from its menu.
		local source = originOf(event.worldId)
		if event.reason == "locked" then
			WorldClient.previewLocked(event.worldId, source)
		end
	end
	WorldClient.Phase:Fire(event)
	if event.phase ~= "out" then
		considerPopups()
	end
end

-- Profile ------------------------------------------------------------------------------------------

local function onProfile(_profile: ClientState.Profile, fields: { string }?)
	local worldsChanged = fields == nil or table.find(fields, "worlds") ~= nil
	if worldsChanged then
		-- A world that is locked again (admin WorldRelock re-tests the popup, W12 QA) owes its
		-- WORLD UNLOCKED popup again on its next unlock.
		for _, def in WorldsConfig.extra() do
			if unlockShown[def.id] and not WorldClient.isUnlocked(def.id) then
				unlockShown[def.id] = nil
			end
		end
		refreshNewDot()
		refreshObjective()
		WorldClient.StateChanged:Fire()
	end
	-- Owner R130: the WORLD UNLOCKED popup waits for a Nuke Town area (or a rebirth), so a new
	-- area or a rebirth re-checks it. Only real changes call considerPopups (the tycoon field
	-- changes on every upgrade). The first synced area is this session's start area.
	local area = mainArea()
	local areaChanged = false
	if ClientState.profile ~= nil then
		if sessionStartArea == nil then
			sessionStartArea = area
		end
		areaChanged = lastMainArea ~= nil and lastMainArea ~= area
		lastMainArea = area
	end
	local rebirthed = fields ~= nil and table.find(fields, "rebirths") ~= nil
	if worldsChanged or areaChanged or rebirthed or (fields ~= nil and table.find(fields, "lastWorld") ~= nil) then
		considerPopups()
	end
end

function WorldClient.Init()
	-- Wiring happens in Start (the HUD + screens exist by then).
end

--[[
	Starts the worlds client (once). Requires UIController to have started (the HUD + screens
	are registered), so the boot list places it after "UIController" / "Audio/SoundController".
]]
function WorldClient.Start()
	if started then
		return
	end
	started = true
	hud = require(script.Parent.Parent.UI.Hud.Hud) :: any
	screens = require(script.Parent.Parent.UI.ScreenManager) :: any
	captureLighting()
	-- Per-world gravity + landing feedback (R70): follows CurrentWorld on its own.
	WorldGravity.start()
	localPlayer:GetAttributeChangedSignal(CURRENT_ATTR):Connect(function()
		applyWorld()
		considerPopups()
	end)
	localPlayer:GetAttributeChangedSignal(REVEALED_ATTR):Connect(considerPopups)
	-- The session anchor: PlotAssignedAt (server) or, failing that, the first synced clock
	-- reading; either arriving may make an unlock owed.
	localPlayer:GetAttributeChangedSignal(PLOT_ASSIGNED_ATTR):Connect(considerPopups)
	task.spawn(function()
		local deadline = os.clock() + SYNC_WAIT_SECONDS
		while firstSynced == nil and os.clock() < deadline do
			local now = Workspace:GetServerTimeNow()
			if now > 0 then
				firstSynced = now
				considerPopups()
				break
			end
			task.wait(0.1)
		end
	end)
	-- Kill switch flips (any world): tabs / dot re-render.
	ReplicatedStorage.AttributeChanged:Connect(function(name: string)
		if string.sub(name, 1, #WorldClientConfig.EnabledAttrPrefix) == WorldClientConfig.EnabledAttrPrefix then
			refreshNewDot()
			WorldClient.StateChanged:Fire()
		end
	end)
	Remotes.event("WorldTravel").OnClientEvent:Connect(function(payload: unknown)
		local event = parseTravel(payload)
		if event ~= nil then
			onTravel(event)
		end
	end)
	ClientState.ProfileChanged:Connect(onProfile)
	-- Pads / producers appearing (purchases, streaming) can resolve the objective's arrow target.
	local tycoonOk, TycoonWorld = pcall(require, script.Parent.Parent.Tycoon.TycoonWorld)
	if tycoonOk then
		local function retarget()
			local step, api = objectiveStep, hud
			if step ~= nil and api ~= nil then
				api.setWorldObjective(step.text, objectiveTarget(step))
			end
		end
		TycoonWorld.PadAdded:Connect(retarget)
		TycoonWorld.ProducerAdded:Connect(retarget)
	end
	applyWorld(true)
	local profile = ClientState.profile
	if profile ~= nil then
		onProfile(profile, nil)
	end
end

return WorldClient
