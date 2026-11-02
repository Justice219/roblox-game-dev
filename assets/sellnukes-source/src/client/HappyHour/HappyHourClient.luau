--!strict
--[[
	HappyHourClient — the client model of NUKEY'S HAPPY HOURS (owner R89 §2, docs/happy-hours.md).

	Purpose:
		- Rebuilds the admin override from the server's ReplicatedStorage attributes
		  (HappyHourConfig.Attributes) and installs it into Shared/Events/HappyHourLogic, so this
		  client computes exactly the server's live / next events from the UTC schedule with
		  Workspace:GetServerTimeNow() (no polling remote, no per-second server push).
		- Wakes only at the next boundary (the live event's end or the next start; re-armed on
		  every override change) and fires `Changed` — the HUD chip and the schedule panel
		  (UI/Screens/HappyHour) redraw from it.
		- On an event START: the centre banner (Tycoon/Fx/JuiceBanner: "NUKEY'S HAPPY HOUR" /
		  "CONFETTI STORM!" / the event line, "in Dino Valley" when it is another world's) + its
		  sound; skipped during the guided first-minute tutorial and under the loading screen. The
		  banner is PopupQueue kind "happyHour" (owner R102): it takes its turn in the centre lane.
		- Drives the event effects: Low-Gravity Hour → Worlds/WorldGravity.setEvent, Confetti
		  Storm → HappyHourFx.setStorm (clouds + rain), Double Pops → HappyHourFx.setDoublePops
		  (bonus pops), and starts HappyHourPickupsClient (coins / eggs / moon rocks).

	Security: presentation only. Rewards, pickups, the luck and the income bonus are all
	server-side; attributes are re-validated (HappyHourLogic.overrideFromAttributes).

	Performance: one task.delay per boundary (a few per hour), attribute change signals, no
	per-frame work here.

	API (screens):
		HappyHourClient.Changed: Signal<>       live / next / override changed
		HappyHourClient.now() -> number         server unix time
		HappyHourClient.live() / nextEvent()    effective events now (HappyHourLogic.Live?)
		HappyHourClient.upcoming(count)         { Live } live first, then the next ones
		HappyHourClient.inWorld(live) -> boolean  the player is where the event happens
		HappyHourClient.travelTo(live) -> boolean GO: travel to the event's world (WorldClient)
		HappyHourClient.stats() -> table        QA probe

	Example:
		HappyHourClient.Changed:Connect(function() print(HappyHourClient.live()) end)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)
local ClientState = require(script.Parent.Parent.ClientState)
local FtueConfig = require(ReplicatedStorage.Shared.Config.FtueConfig)
local HappyHourChipLogic = require(script.Parent.HappyHourChipLogic)
local HappyHourConfig = require(ReplicatedStorage.Shared.Config.HappyHourConfig)
local HappyHourFx = require(script.Parent.HappyHourFx)
local HappyHourLogic = require(ReplicatedStorage.Shared.Events.HappyHourLogic)
local HappyHourPickupsClient = require(script.Parent.HappyHourPickupsClient)
local JuiceBanner = require(script.Parent.Parent.Tycoon.Fx.JuiceBanner)
local LoadingGate = require(script.Parent.Parent.UI.Widgets.LoadingGate)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Sound = require(script.Parent.Parent.Audio.Sound)
local WorldClient = require(script.Parent.Parent.Worlds.WorldClient)
local WorldGravity = require(script.Parent.Parent.Worlds.WorldGravity)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)

type Live = HappyHourLogic.Live

local HappyHourClient = {}

HappyHourClient.Changed = Signal.new() :: Signal.Signal<>

local localPlayer = Players.LocalPlayer
local started = false
local activeSignature = ""
local timerToken = 0
local banners = 0 -- start banners shown (QA)
local lastBannerSignature = ""

--[[ Server unix time (the clock the schedule runs on). ]]
function HappyHourClient.now(): number
	return Workspace:GetServerTimeNow()
end

--[[ The effective live event now (nil between events / kill switch). ]]
function HappyHourClient.live(): Live?
	return HappyHourLogic.liveAt(HappyHourClient.now())
end

--[[ The next effective event (nil with the kill switch on). ]]
function HappyHourClient.nextEvent(): Live?
	return HappyHourLogic.nextAt(HappyHourClient.now())
end

--[[ Live first, then the next events (schedule panel rows). ]]
function HappyHourClient.upcoming(count: number): { Live }
	return HappyHourLogic.upcoming(HappyHourClient.now(), count)
end

--[[ True when the player is in the world the event happens in (every world for global events). ]]
function HappyHourClient.inWorld(live: Live): boolean
	return live.world == nil or WorldClient.current() == live.world
end

--[[
	GO: travels to the event's world hub (WorldClient validates; a locked world shows its locked
	preview instead). @return true when a travel intent was sent
]]
function HappyHourClient.travelTo(live: Live): boolean
	local world = live.world
	if world == nil or WorldClient.current() == world then
		return false
	end
	return WorldClient.travel(world, "spawn", nil, "chip")
end

-- True while the player is on a guided first-minute tutorial step (no banner then).
local function inGuidedTutorial(): boolean
	local profile: any = ClientState.profile
	local tycoon = if type(profile) == "table" then profile.tycoon else nil
	return type(tycoon) == "table" and FtueConfig.isGuided(tycoon.tutorialStep)
end

-- The start banner + sound for a newly live event (once per instance).
local function announce(live: Live, attempt: number?)
	local def = HappyHourConfig.get(live.id)
	if def == nil then
		return
	end
	-- Pure rule (tests/happy-hours.luau): once per instance; deferred, not dropped, while the
	-- loading screen / guided tutorial is up (evaluate + LoadingGate.onDone call this again).
	local show, signature =
		HappyHourChipLogic.shouldAnnounce(lastBannerSignature, live, LoadingGate.isDone(), inGuidedTutorial())
	if not show then
		return
	end
	local world = if live.world ~= nil then WorldsConfig.get(live.world) else nil
	local title, line =
		HappyHourChipLogic.bannerText(live, HappyHourClient.inWorld(live), if world ~= nil then world.name else "")
	local Client = HappyHourConfig.Client
	-- Owner R102: kind "happyHour" in PopupQueue's centre lane (waits behind a reveal / Big Pop,
	-- pre-empts a milestone banner); true = shown or queued.
	if JuiceBanner.show(Client.BannerHeader, title, line, def.color :: any, Client.BannerSeconds, "happyHour") then
		lastBannerSignature = signature
		banners += 1
		if AudioConfig.Sfx[def.sound] ~= nil then
			Sound.play(def.sound)
		end
		return
	end
	-- The banner was not built yet (or the queue refused it): retry a few times while the same
	-- event instance still runs.
	local tries = attempt or 0
	if tries < Client.BannerRetries then
		task.delay(Client.BannerRetrySeconds, function()
			local still = HappyHourClient.live()
			if still ~= nil and HappyHourLogic.signature(still) == signature then
				announce(still, tries + 1)
			end
		end)
	end
end

-- Applies the effects of the live event (or clears them).
local function applyEffects(live: Live?)
	local def = if live ~= nil then HappyHourConfig.get(live.id) else nil
	-- Low-Gravity Hour (any event with a gravity row).
	if def ~= nil and def.gravityMultiplier ~= nil and live ~= nil then
		WorldGravity.setEvent(live.world, def.gravityMultiplier, def.glideFallSpeed)
	else
		WorldGravity.setEvent(nil, 1)
	end
	HappyHourFx.setStorm(def ~= nil and def.id == "confetti")
	HappyHourFx.setDoublePops(if def ~= nil and def.cashMultiplier ~= nil then def.cashMultiplier else 1)
	if live == nil then
		HappyHourPickupsClient.clear()
	end
end

-- Re-evaluates the live event; on a change applies effects / announces; re-arms the timer.
local function evaluate()
	local now = HappyHourClient.now()
	local live = HappyHourLogic.liveAt(now)
	local signature = HappyHourLogic.signature(live)
	if signature ~= activeSignature then
		activeSignature = signature
		applyEffects(live)
	end
	-- Idempotent per instance: also catches a banner deferred by the loading screen / tutorial.
	if live ~= nil then
		announce(live)
	end
	HappyHourClient.Changed:Fire()
	-- Wake at the next boundary (end of the live event / start of the next), at least every 60 s
	-- (a safety net against clock adjustments), never sooner than 0.2 s.
	local nextLive = HappyHourLogic.nextAt(now)
	local wake = now + 60
	if live ~= nil then
		wake = math.min(wake, live.endsAt)
	end
	if nextLive ~= nil then
		wake = math.min(wake, nextLive.startsAt)
	end
	timerToken += 1
	local token = timerToken
	task.delay(math.max(0.2, wake - now + 0.05), function()
		if token == timerToken then
			evaluate()
		end
	end)
end

-- Reads the override attributes, installs them, re-evaluates.
local function readOverride()
	HappyHourLogic.setOverride(HappyHourLogic.overrideFromAttributes(function(name: string): unknown
		return ReplicatedStorage:GetAttribute(name)
	end))
	evaluate()
end

--[[ QA probe: live / next ids, override, effects, banners, pickups. ]]
function HappyHourClient.stats(): { [string]: any }
	local live = HappyHourClient.live()
	local nextLive = HappyHourClient.nextEvent()
	local override = HappyHourLogic.currentOverride()
	return {
		live = if live ~= nil then live.id else nil,
		liveEndsIn = if live ~= nil then math.floor(live.endsAt - HappyHourClient.now()) else nil,
		forced = if live ~= nil then live.forced else nil,
		nextId = if nextLive ~= nil then nextLive.id else nil,
		nextIn = if nextLive ~= nil then math.floor(nextLive.startsAt - HappyHourClient.now()) else nil,
		kill = override.kill,
		version = override.v,
		luck = HappyHourLogic.flavorLuckAt(HappyHourClient.now()),
		serverLive = ReplicatedStorage:GetAttribute(HappyHourConfig.Attributes.Live),
		banners = banners,
		gravity = WorldGravity.stats(),
		fx = HappyHourFx.stats(),
		pickups = HappyHourPickupsClient.stats(),
	}
end

function HappyHourClient.Init() end

function HappyHourClient.Start()
	if started then
		return
	end
	started = true
	HappyHourPickupsClient.start()
	-- Any override attribute change (deferred so a burst of SetAttribute calls costs one read).
	local pending = false
	local function onAttribute()
		if pending then
			return
		end
		pending = true
		task.defer(function()
			pending = false
			readOverride()
		end)
	end
	local names = HappyHourConfig.Attributes
	for _, name in { names.Version, names.Kill, names.ForceId, names.ForceStart, names.ForceEnd, names.Skips } do
		ReplicatedStorage:GetAttributeChangedSignal(name):Connect(onAttribute)
	end
	-- A world change can make a world event's effects (gravity) apply / stop.
	localPlayer:GetAttributeChangedSignal("CurrentWorld"):Connect(function()
		HappyHourClient.Changed:Fire()
	end)
	-- The banner of an event that started under the loading screen shows once it lifts.
	LoadingGate.onDone(function()
		local live = HappyHourClient.live()
		if live ~= nil then
			announce(live)
		end
	end)
	readOverride()
end

return HappyHourClient
