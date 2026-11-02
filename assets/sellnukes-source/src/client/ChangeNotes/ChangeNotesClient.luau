--!strict
--[[
	ChangeNotesClient — the client state + auto-open driver of WHAT'S NEW change notes (port of
	RoBeasts' Growth/ChangeNotesClient + the auto-open part of its Screens/ChangeNotes, owner R58;
	data Shared/Config/ChangeNotesConfig, rules Shared/Util/ChangeNotesLogic, server
	ChangeNotesService, screen UI/Screens/WhatsNew, HUD chip UI/Hud/HudWhatsNew,
	docs/change-notes.md). A boot controller (Init / Start): "ChangeNotes/ChangeNotesClient".

	Purpose:
		- SEEN POSITION: the newest note the player has seen, read from the profile snapshot
		  (`notes.seen`, ChangeNotesLogic.readSeen; "" when absent) and moved forward locally the
		  moment the player closes the panel (optimistic, so the HUD dot clears instantly; the
		  server's next push agrees because it applied the same rule). `hasUnseen()` drives the HUD
		  chip's NEW dot; `Changed` fires whenever it may have changed.
		- AUTO-OPEN (owner R58: "only show the what's new whenever returning players join"): the
		  server already marked the newest note seen for brand-new / mid-tutorial players before the
		  first snapshot, so an unseen note here means a RETURNING player. State machine: "idle"
		  (nothing owed / not decided), "waiting" (opens at the next polite moment), "open" (on
		  screen as the auto pop-up), "done" (shown or given up: ONCE per join). A polite moment =
		  PoliteChecks consecutive checks (one every CheckSeconds)
		  with: the join loading screen finished (Widgets/LoadingGate), no window open
		  (ScreenManager.anyModalOpen — Welcome Back, the tutorial intro card, any menu), no focus
		  mode (loading, egg hatch, attack cinematic), no plot-reveal fly-over
		  (Tycoon/PlotReveal), no Roblox purchase prompt (PurchaseFlowAt attribute), nothing
		  waiting in the join pop-up queue (Platform/JoinFlow, R78: Welcome Back first). The wait is
		  bounded (Auto.WaitSeconds, loading time excluded); giving up leaves the NEW dot on.
		- REPORTS (C→S ChangeNotesAction): markSeen(id) → "seen" (only when it moves forward);
		  report("shown" | "cta" | "closed", id, arg?) → analytics. Mirrors the server's token
		  bucket and per-key session cap, so this client never sends a report the server drops.
		- REVEALS (ShowFrom): `now()` is the clock every visibility rule here uses (the server
		  clock minus Auto.RevealLagSeconds). ONE task.delay is armed to the next ShowFrom; when it
		  fires, Changed fires and, if the auto pop-up already ran this session and the revealed
		  note is unseen, the state goes back to "idle" so the new note gets its ONE polite pop-up.
		- ADMIN (S→C ChangeNotesAdmin, owner admin commands only): "preview" opens the panel in
		  preview mode; "replay" forgets this session's optimistic mark + attempt, so the
		  returning-player pop-up runs again after the server reset the seen note.
	Nothing here grants or decides anything server-side: the server re-validates every report.

	Performance: event-driven (profile pushes, window open / close); the polite-moment poll runs
	only while a pop-up is owed ("waiting", ≤ WaitSeconds, 1 Hz); one reveal timer at most.

	Connects to: ClientState (ProfileChanged), Remotes (ChangeNotesAction, ChangeNotesAdmin),
	ChangeNotesConfig / ChangeNotesLogic, UI/ScreenManager, UI/Widgets/LoadingGate,
	Tycoon/PlotReveal, Shared/Util/{Signal, RateLimiter}, Workspace (server clock).

	Example:
		ChangeNotesClient.Changed:Connect(function() dot.Visible = ChangeNotesClient.hasUnseen() end)
		ChangeNotesClient.openMenu() -- the HUD chip / Settings: open the panel ("menu" source)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ChangeNotesConfig = require(ReplicatedStorage.Shared.Config.ChangeNotesConfig)
local ChangeNotesLogic = require(ReplicatedStorage.Shared.Util.ChangeNotesLogic)
local ClientState = require(script.Parent.Parent.ClientState)
local JoinFlow = require(script.Parent.Parent.Platform.JoinFlow)
local LoadingGate = require(script.Parent.Parent.UI.Widgets.LoadingGate)
local PlotReveal = require(script.Parent.Parent.Tycoon.PlotReveal)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type AutoState = "idle" | "waiting" | "open" | "done"
-- How the panel was opened: the auto pop-up, the HUD chip / Settings, or an admin preview.
export type OpenSource = "auto" | "menu" | "preview"

local ChangeNotesClient = {}

-- Fires () when the seen position, the profile readiness or the auto-open state changed.
ChangeNotesClient.Changed = Signal.new() :: Signal.Signal<>

local SCREEN = ChangeNotesConfig.Screen
local Auto = ChangeNotesConfig.Auto

local serverSeen = "" -- profile snapshot's notes.seen
local localSeen = "" -- the furthest id this client marked seen this session (optimistic)
local profileReady = false -- a snapshot arrived (the seen position is known)
local autoState: AutoState = "idle"
local started = false
local limiter = RateLimiter.new(ChangeNotesConfig.Server.ActionBurst, ChangeNotesConfig.Server.ActionPerSecond)
local LIMITER_KEY = "changeNotes"
local sentReports: { [string]: number } = {} -- metric key → reports sent this session
-- The one pending reveal timer (task.delay to the next ShowFrom), nil when none is armed.
local revealThread: thread? = nil
-- Shortest reveal wait: a clock that drifts behind the timer re-arms at most once a second.
local MIN_REVEAL_WAIT = 1
-- The current wait loop's generation (a replay / reveal starts a new one; an old loop exits).
local waitGeneration = 0
-- Why the last polite check failed (QA / Studio probes; nil = polite).
local lastBlocker: string? = nil

-- Reads the snapshot's seen id and fires Changed when anything moved.
local function onProfile(profile: { [string]: any }?)
	if profile == nil then
		return
	end
	local seen = ChangeNotesLogic.readSeen(profile.notes)
	if seen ~= serverSeen or not profileReady then
		serverSeen = seen
		profileReady = true
		ChangeNotesClient.Changed:Fire()
	end
end

--[[
	The clock every visibility rule on this client uses: the server clock minus
	ChangeNotesConfig.Auto.RevealLagSeconds (see the module header, REVEALS).
	Example: ChangeNotesConfig.visibleCount(ChangeNotesClient.now())
]]
function ChangeNotesClient.now(): number
	return Workspace:GetServerTimeNow() - Auto.RevealLagSeconds
end

--[[ How many notes this player can see right now (the first N of ChangeNotesConfig.Notes). ]]
function ChangeNotesClient.visibleCount(): number
	return ChangeNotesConfig.visibleCount(ChangeNotesClient.now())
end

--[[ True once a profile snapshot arrived (the seen position is known). ]]
function ChangeNotesClient.profileReady(): boolean
	return profileReady
end

--[[
	The effective seen id: the server's or this session's optimistic mark, whichever is further
	(ChangeNotesLogic.seenIndex order). "" = nothing seen.
]]
function ChangeNotesClient.seen(): string
	if ChangeNotesLogic.seenIndex(localSeen) > ChangeNotesLogic.seenIndex(serverSeen) then
		return localSeen
	end
	return serverSeen
end

--[[ True while a VISIBLE note is newer than the seen position (the NEW dot). False before the profile. ]]
function ChangeNotesClient.hasUnseen(): boolean
	return profileReady and ChangeNotesLogic.hasUnseen(ChangeNotesClient.seen(), ChangeNotesClient.now())
end

-- Sends one ChangeNotesAction within the mirrored token bucket.
local function send(verb: ChangeNotesConfig.Action, id: string, arg: (string | number)?): boolean
	if not limiter:Allow(LIMITER_KEY) then
		return false
	end
	local ok = pcall(function()
		Remotes.event("ChangeNotesAction"):FireServer(verb, id, arg)
	end)
	return ok
end

--[[
	The player has now seen the note `id` (closing the panel): moves the local position forward
	at once and tells the server (only when it actually moves forward; the server applies the
	same rule).
	@return true when the position moved
]]
function ChangeNotesClient.markSeen(id: string): boolean
	if ChangeNotesLogic.canMarkSeen(ChangeNotesClient.seen(), id, ChangeNotesClient.now()) ~= "Ok" then
		return false
	end
	localSeen = id
	ChangeNotesClient.Changed:Fire()
	send("seen", id, nil)
	return true
end

--[[
	An analytics report: "shown" (arg = source "auto" | "menu"), "cta", or "closed" (arg = seconds
	open). Capped per metric key per session exactly like the server (Server.MaxReportsPerKey).
	@return true when sent
	Example: ChangeNotesClient.report("closed", newest.Id, 12.4)
]]
function ChangeNotesClient.report(verb: ChangeNotesConfig.Action, id: string, arg: (string | number)?): boolean
	local action = ChangeNotesLogic.parseAction(verb, id, arg, ChangeNotesClient.now())
	if action == nil or action.verb == "seen" then
		return false
	end
	local key = ChangeNotesLogic.metricKey(action)
	local n = sentReports[key] or 0
	if n >= ChangeNotesConfig.Server.MaxReportsPerKey then
		return false
	end
	if not send(action.verb, action.id, if action.verb == "closed" then action.seconds else action.source) then
		return false
	end
	sentReports[key] = n + 1
	return true
end

--[[ The auto-open state (see the module header). ]]
function ChangeNotesClient.autoState(): AutoState
	return autoState
end

--[[ Screens/WhatsNew only: moves the auto-open state machine. ]]
function ChangeNotesClient.setAutoState(state: AutoState)
	if autoState ~= state then
		autoState = state
		ChangeNotesClient.Changed:Fire()
	end
end

--[[ True while the auto pop-up is waiting for its polite moment or on screen. ]]
function ChangeNotesClient.holdsPopups(): boolean
	return autoState == "waiting" or autoState == "open"
end

--[[
	Opens the panel from the HUD chip / Settings ("menu" source). Opening it while the auto
	pop-up still waits counts as its showing (the state becomes "done").
	Example: ChangeNotesClient.openMenu()
]]
function ChangeNotesClient.openMenu()
	if autoState == "waiting" then
		ChangeNotesClient.setAutoState("done")
	end
	ScreenManager.open(SCREEN, { source = "menu" })
end

-- Polite moment -------------------------------------------------------------------------------

--[[
	Why the one-time auto pop-up may NOT open right now, or nil when it may (a polite moment). The
	reason names the first blocker (QA probes read it via testState).
]]
local function impoliteReason(): string?
	if not LoadingGate.isDone() then
		return "loading"
	end
	if ScreenManager.isFocusMode() then
		return "focus"
	end
	if ScreenManager.anyModalOpen() then
		return "modal"
	end
	if PlotReveal.isPlaying() then
		return "plotReveal"
	end
	if Players.LocalPlayer:GetAttribute(ChangeNotesConfig.PurchaseFlow.Attr) ~= nil then
		return "purchaseFlow"
	end
	-- R78 §6: a join pop-up queued ahead (Welcome Back, the tutorial coach card) goes first.
	if JoinFlow.pending() then
		return "joinQueue"
	end
	return nil
end

-- Opens the panel as the auto pop-up. Returns false when the screen could not open.
local function openAuto(): boolean
	ChangeNotesClient.setAutoState("open")
	ScreenManager.open(SCREEN, { source = "auto" })
	if not ScreenManager.isOpen(SCREEN) then
		ChangeNotesClient.setAutoState("done")
		return false
	end
	return true
end

--[[
	Starts the wait for a polite moment when an unseen VISIBLE note is owed (once per session,
	plus once for a note revealed mid-session or an admin replay: those re-arm the state to "idle").
]]
local function considerAuto()
	if autoState ~= "idle" or not profileReady then
		return
	end
	if ChangeNotesLogic.autoNote(ChangeNotesClient.seen(), false, ChangeNotesClient.now()) == nil then
		return
	end
	ChangeNotesClient.setAutoState("waiting")
	waitGeneration += 1
	local generation = waitGeneration
	task.spawn(function()
		task.wait(Auto.FirstCheckDelay)
		local waited, streak = 0, 0
		while generation == waitGeneration and autoState == "waiting" do
			if not ChangeNotesClient.hasUnseen() then
				ChangeNotesClient.setAutoState("done") -- seen elsewhere meanwhile
				return
			end
			local reason = impoliteReason()
			lastBlocker = reason
			streak = if reason == nil then streak + 1 else 0
			if streak >= Auto.PoliteChecks then
				openAuto()
				return
			end
			-- Loading-screen time does not count against the wait.
			if reason ~= "loading" then
				waited += Auto.CheckSeconds
			end
			if waited >= Auto.WaitSeconds then
				ChangeNotesClient.setAutoState("done") -- no polite moment this session; the dot stays
				return
			end
			task.wait(Auto.CheckSeconds)
		end
	end)
end

-- Reveals -------------------------------------------------------------------------------------

-- Arms ONE task.delay to the next ShowFrom (no-op while one is pending or none is left).
local armReveal: () -> ()

-- The reveal timer fired: a note may have become visible (see the module header).
local function onReveal()
	revealThread = nil
	local owed = profileReady and ChangeNotesLogic.hasUnseen(ChangeNotesClient.seen(), ChangeNotesClient.now())
	if owed and autoState == "done" then
		-- The note revealed now gets its own ONE pop-up (even when this session's already ran).
		autoState = "idle"
	end
	ChangeNotesClient.Changed:Fire()
	armReveal()
end

armReveal = function()
	if revealThread ~= nil then
		return
	end
	local now = ChangeNotesClient.now()
	local at = ChangeNotesConfig.nextShowFrom(now)
	if at == nil then
		return
	end
	revealThread = task.delay(math.max(MIN_REVEAL_WAIT, at - now), onReveal)
end

-- Admin (S→C ChangeNotesAdmin; the server only sends it after an authorised admin command) -----

-- Applies one admin payload (untrusted shape: validated here).
local function onAdmin(payload: unknown)
	if type(payload) ~= "table" then
		return
	end
	local action = (payload :: { [string]: unknown }).action
	if action == "preview" then
		ScreenManager.open(SCREEN, { source = "preview" })
	elseif action == "replay" then
		-- The server set the seen note back: forget the optimistic mark + this join's attempt, so
		-- the returning-player pop-up runs again once the pushed `notes` arrives.
		localSeen = ""
		waitGeneration += 1
		if autoState ~= "open" then
			autoState = "idle"
		end
		ChangeNotesClient.Changed:Fire()
	end
end

--[[ QA / Studio probes: a copy of the client state. ]]
function ChangeNotesClient.testState(): { [string]: any }
	return {
		serverSeen = serverSeen,
		localSeen = localSeen,
		seen = ChangeNotesClient.seen(),
		profileReady = profileReady,
		hasUnseen = ChangeNotesClient.hasUnseen(),
		autoState = autoState,
		blocker = lastBlocker,
		visibleCount = ChangeNotesClient.visibleCount(),
		revealArmed = revealThread ~= nil,
	}
end

--[[ Starts listening to profile snapshots, admin pushes and window closes (idempotent). ]]
function ChangeNotesClient.start()
	if started then
		return
	end
	started = true
	ClientState.ProfileChanged:Connect(function(profile: { [string]: any }, fields: { string }?)
		if fields == nil or table.find(fields, "notes") ~= nil then
			onProfile(profile)
		end
	end)
	onProfile(ClientState.profile)
	ChangeNotesClient.Changed:Connect(considerAuto)
	task.spawn(function()
		Remotes.event("ChangeNotesAdmin").OnClientEvent:Connect(onAdmin)
	end)
	armReveal()
	task.defer(considerAuto)
end

-- Boot controller contract (init.client.luau ORDERED_NAMES "ChangeNotes/ChangeNotesClient").
function ChangeNotesClient.Init() end

function ChangeNotesClient.Start()
	ChangeNotesClient.start()
end

return ChangeNotesClient
