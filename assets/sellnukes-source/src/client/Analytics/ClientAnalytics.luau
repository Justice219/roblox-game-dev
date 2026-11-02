--!strict
--[[
	ClientAnalytics — the small client API UI code calls to report what the player SAW (spec §13).
	Everything here is a CLAIM the server validates (Server/Analytics/Sessions + Revenue): exact
	allowlists, token buckets, per-session caps. Nothing is ever granted, unlocked or shown because
	of these reports; they only feed the analytics report. Every function is cheap, never yields
	and never throws, so UI code can call it inline.

	API (UI / client systems):
		ClientAnalytics.step(stepId)                 "loadingDone" (loading screen handed over) |
		                                             "hudShown" (the HUD became visible); once each
		ClientAnalytics.screenOpened(screen, source?) a screen opened ("Shop", "Daily", "Wheel", ...
		                                             AnalyticsConfig.ClientFunnel.Screens; source
		                                             "hud" | "offer" | "pad" | "prompt" | "auto" |
		                                             "npc" | "popup" | "keybind" | "other")
		ClientAnalytics.tutorialShown(step)          the tutorial arrow / objective moved to step N
		ClientAnalytics.offerSeen(offerId, source, newVisit?)
		                                             an offer card RENDERED (offer id = a
		                                             MonetizationConfig product / pass key). Cards of
		                                             one visit are batched into one OffersSeen report;
		                                             pass newVisit = true for the first card when a
		                                             surface opens (starburst column, shop page, popup)
		ClientAnalytics.plotReady(seconds)           the player's plot finished streaming / building
		ClientAnalytics.worldPopup(worldId, action)  R57 WORLD UNLOCKED popup: action "shown" |
		                                             "go" | "later" | "lockedPreview" (the locked
		                                             portal version); worldId = an extra world id
		                                             ("dino"). Capped client-side + server-side.
	Automatic (start): device class + input mode (ClientDevice, at start and when the input mode
	changes) and the ClientPerfReporter (frame time, memory, ping, boot; once a minute).

	Controller contract: Init() / Start() (the client boot calls Start once; `start` is an alias).

	Connects to: Shared/Net/Remotes (FunnelStep, OffersSeen, ClientDevice), Shared/Util/DeviceProfile,
	AnalyticsConfig (client-side pre-filters mirror the server allowlists), ClientPerfReporter.

	Example:
		local ClientAnalytics = require(script.Parent.Parent.Analytics.ClientAnalytics)
		ClientAnalytics.screenOpened("Shop", "hud")
		ClientAnalytics.offerSeen("StarterPack", "starburst", true)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)
local WorldsConfig = require(ReplicatedStorage.Shared.Config.Worlds.WorldsConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local DeviceProfile = require(ReplicatedStorage.Shared.Util.DeviceProfile)
local ClientPerfReporter = require(script.Parent.ClientPerfReporter)

local ClientAnalytics = {}

-- Client-side throttles (the server enforces the real limits; these just avoid useless sends).
local SCREEN_REPEAT_SECONDS = 2 -- the same screen reopened within this window is one open
local OFFER_BATCH_SECONDS = 0.5 -- cards rendered within this window share one OffersSeen report
local MAX_DEVICE_REPORTS = 4 -- per session (server bucket allows a few)

local started = false
local stepsSent: { [string]: boolean } = {}
local lastScreenAt: { [string]: number } = {}
local tutorialSent: { [number]: boolean } = {}
local deviceReports = 0
local lastDevice: string? = nil
local lastInput: string? = nil

-- Pending offer batch: one per source (cards of the same surface within OFFER_BATCH_SECONDS).
type Batch = { ids: { string }, seen: { [string]: boolean }, newVisit: boolean, scheduled: boolean }
local batches: { [string]: Batch } = {}

local CLIENT_STEPS: { [string]: boolean } = {}
for _, step in AnalyticsConfig.Ftue.ClientSteps do
	CLIENT_STEPS[step] = true
end
local SCREENS: { [string]: boolean } = {}
for _, screen in AnalyticsConfig.ClientFunnel.Screens do
	SCREENS[screen] = true
end
local POPUP_ACTIONS: { [string]: boolean } = {}
for _, action in AnalyticsConfig.Worlds.PopupActions do
	POPUP_ACTIONS[action] = true
end
-- Popup claims sent this session per "<world>:<action>" (mirrors the server's PopupSessionCap).
local popupSent: { [string]: number } = {}

-- Fires a remote without ever throwing / yielding into the caller (Remotes.event may wait for
-- the remote to replicate, so the lookup + fire run on their own thread).
local function fire(name: string, ...: any)
	local args = table.pack(...)
	task.spawn(function()
		local ok, err = pcall(function()
			Remotes.event(name :: any):FireServer(table.unpack(args, 1, args.n))
		end)
		if not ok then
			warn(`[ClientAnalytics] {name} failed: {err}`)
		end
	end)
end

--[[
	A client-only funnel step ("loadingDone" | "hudShown"), sent once per session.
	Example: ClientAnalytics.step("hudShown")
]]
function ClientAnalytics.step(stepId: string)
	if type(stepId) ~= "string" or not CLIENT_STEPS[stepId] or stepsSent[stepId] then
		return
	end
	stepsSent[stepId] = true
	fire("FunnelStep", stepId)
end

--[[
	A screen opened. `screen` must be one of AnalyticsConfig.ClientFunnel.Screens; `source` says
	what opened it (unknown → "other" on the server).
	Example: ClientAnalytics.screenOpened("Wheel", "hud")
]]
function ClientAnalytics.screenOpened(screen: string, source: string?)
	if type(screen) ~= "string" or not SCREENS[screen] then
		return
	end
	local now = os.clock()
	if now - (lastScreenAt[screen] or -math.huge) < SCREEN_REPEAT_SECONDS then
		return
	end
	lastScreenAt[screen] = now
	fire("FunnelStep", "open", screen, if type(source) == "string" then source else "other")
end

--[[
	R57: a WORLD UNLOCKED popup event. `worldId` = an extra world ("dino"), `action` = "shown" |
	"go" | "later" | "lockedPreview". The server counts worlds "popup:<world>:<action>" (capped).
	Example: ClientAnalytics.worldPopup("dino", "go")
]]
function ClientAnalytics.worldPopup(worldId: string, action: string)
	local def = WorldsConfig.get(worldId)
	if def == nil or def.id == WorldsConfig.MAIN or type(action) ~= "string" or not POPUP_ACTIONS[action] then
		return
	end
	local id = `{def.id}:{action}`
	local sent = popupSent[id] or 0
	if sent >= AnalyticsConfig.Worlds.PopupSessionCap then
		return
	end
	popupSent[id] = sent + 1
	fire("FunnelStep", "worldPopup", def.id, action)
end

--[[ The tutorial arrow / objective chip moved to step `step` (1..MaxTutorialStep; once each). ]]
function ClientAnalytics.tutorialShown(step: number)
	if type(step) ~= "number" or step % 1 ~= 0 or step < 1 or step > AnalyticsConfig.ClientFunnel.MaxTutorialStep then
		return
	end
	if tutorialSent[step] then
		return
	end
	tutorialSent[step] = true
	fire("FunnelStep", "tutorial", step)
end

-- Sends one source's batched offer cards.
local function flushBatch(source: string)
	local batch = batches[source]
	batches[source] = nil
	if batch == nil or (#batch.ids == 0 and not batch.newVisit) then
		return
	end
	local ids = batch.ids
	-- The server reads at most MaxCards per report: send the rest as same-visit follow-ups.
	local maxCards = AnalyticsConfig.OffersSeen.MaxCards
	local first = true
	local index = 1
	repeat
		local chunk = table.move(ids, index, math.min(#ids, index + maxCards - 1), 1, {})
		fire("OffersSeen", source, chunk, first and batch.newVisit)
		first = false
		index += maxCards
	until index > #ids
end

--[[
	An offer card rendered. `offerId` = a MonetizationConfig product / pass key; `source` = the
	surface ("starburst" | "shop" | "popup" | "welcome" | "pad" | "hud" | "other"); `newVisit` =
	true when this render opens a new visit of that surface (pass it on the first card).
	Example: ClientAnalytics.offerSeen("VIP", "starburst", true)
]]
function ClientAnalytics.offerSeen(offerId: string, source: string, newVisit: boolean?)
	if type(offerId) ~= "string" or #offerId > AnalyticsConfig.ClientSourceMaxLength then
		return
	end
	local surface = if type(source) == "string"
			and table.find(AnalyticsConfig.OffersSeen.Sources, source) ~= nil
		then source
		else "other"
	local batch = batches[surface]
	if batch == nil then
		batch = { ids = {}, seen = {}, newVisit = false, scheduled = false }
		batches[surface] = batch
	end
	if newVisit == true then
		if batch.newVisit or #batch.ids > 0 then
			-- A new visit while one is batched: send the old visit first.
			flushBatch(surface)
			batch = { ids = {}, seen = {}, newVisit = true, scheduled = false }
			batches[surface] = batch
		else
			batch.newVisit = true
		end
	end
	if not batch.seen[offerId] then
		batch.seen[offerId] = true
		table.insert(batch.ids, offerId)
	end
	if not batch.scheduled then
		batch.scheduled = true
		task.delay(OFFER_BATCH_SECONDS, flushBatch, surface)
	end
end

--[[ The player's plot finished streaming / building in, `seconds` after it was assigned. ]]
function ClientAnalytics.plotReady(seconds: number)
	ClientPerfReporter.plotReady(seconds)
end

-- The current input mode from the last input type.
local function inputMode(): string
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		return "touch"
	elseif string.find(last.Name, "Gamepad", 1, true) ~= nil then
		return "gamepad"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not UserInputService.MouseEnabled then
		return "touch"
	end
	return "kbm"
end

-- Reports the device class + input mode when they changed (bounded per session).
local function reportDevice()
	if deviceReports >= MAX_DEVICE_REPORTS then
		return
	end
	-- Cheap check first: LastInputTypeChanged fires often (keyboard ↔ mouse) within one mode.
	local input = inputMode()
	if input == lastInput and lastDevice ~= nil then
		return
	end
	local device = string.lower(DeviceProfile.current().class)
	if device == lastDevice and input == lastInput then
		return
	end
	lastDevice, lastInput = device, input
	deviceReports += 1
	fire("ClientDevice", device, input)
end

function ClientAnalytics.Init() end

--[[ Starts the automatic reporters (device + client performance). Idempotent. ]]
function ClientAnalytics.Start()
	if started then
		return
	end
	started = true
	ClientPerfReporter.start()
	-- The device class needs the camera viewport: report once it exists, then on input changes.
	task.defer(reportDevice)
	UserInputService.LastInputTypeChanged:Connect(function()
		reportDevice()
	end)
end
ClientAnalytics.start = ClientAnalytics.Start

return ClientAnalytics
