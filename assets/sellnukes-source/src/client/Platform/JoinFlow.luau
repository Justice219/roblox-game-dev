--!strict
--[[
	JoinFlow — the ONE join-time attention queue (owner R78 §6, first-minute fix).

	Why: before R78 every join pop-up opened on its own clock. A returning player's Welcome Back
	opened UNDER the loading screen, so the "Your plot is #N!" camera swooped behind a blurred
	window and the walk home happened while the window was up (verified in Studio 2026-10-31);
	the tutorial card, What's New, the notification prompt, Lucky Buttons and their edge arrow
	all competed for the same first minute. New players (6 of 20 left before their first pad on
	day 1, 3 of 7 on console) need exactly ONE thing on screen: the way to the free Workbench.

	Order of a join (each waits for the previous):
		1. loading screen (Widgets/LoadingGate)
		2. plot reveal camera (Tycoon/PlotReveal; it plays first now that nothing opens before it)
		3. queued pop-ups, highest priority first, one at a time with a calm gap between them:
		   Welcome Back (100) → tutorial coach card (95) → world rejoin (60) → What's New (50) →
		   notification prompt (10). During the guided tutorial steps (FtueConfig.isGuided) only
		   Essential items (≥ 90) open; the rest waits for the first upgrade.
	Modules with their own polite logic (ChangeNotesClient, NotifyPrompt) ask `isQuiet()` /
	`pending()` instead of queueing, so they never jump the queue; the Lucky Button arrow asks
	`guiding()`.

	API:
		JoinFlow.request(key, priority, open)  queue `open()` (a newer request with the same key
		                                       replaces the pending one: the latest payload wins)
		JoinFlow.cancel(key)                   drop a pending item
		JoinFlow.pending(): boolean            anything waiting in the queue
		JoinFlow.isQuiet(allowGuided?)         calm + settled + nothing queued (+ not guided unless
		                                       allowGuided): a self-polling pop-up may open now
		JoinFlow.guiding(): boolean            the tutorial is on a guided first-minute step
		JoinFlow.setTutorialStep(step)         Tycoon/Tutorial feeds the server step
		JoinFlow.debugState()                  QA probes: pending keys + the last blocker
		JoinFlow.GuidingChanged                Signal(guiding: boolean)

	Performance: event-free idle; ONE polling thread (FtueConfig.Join.CheckSeconds) exists only
	while something is pending. Nothing here is selectable or grabs the gamepad cursor.

	Security: presentation order only; every opened screen still talks to the server through its
	own validated remotes.

	Connects to: Platform/JoinFlowLogic (rules), Shared/Config/{FtueConfig, ChangeNotesConfig
	(purchase-flow attribute)}, UI/ScreenManager, UI/Widgets/LoadingGate, Tycoon/PlotReveal,
	Tycoon/Tutorial (setTutorialStep), Screens/{WelcomeBack, TycoonTutorial, NotifyPrompt,
	LuckyButtons/LuckyArrowScreen}, ChangeNotes/ChangeNotesClient.

	Example:
		JoinFlow.request("WelcomeBack", FtueConfig.Join.Priority.WelcomeBack, function()
			ScreenManager.open("WelcomeBack", payload)
		end)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ChangeNotesConfig = require(ReplicatedStorage.Shared.Config.ChangeNotesConfig)
local FtueConfig = require(ReplicatedStorage.Shared.Config.FtueConfig)
local JoinFlowLogic = require(script.Parent.JoinFlowLogic)
local LoadingGate = require(script.Parent.Parent.UI.Widgets.LoadingGate)
local PlotReveal = require(script.Parent.Parent.Tycoon.PlotReveal)
local ScreenManager = require(script.Parent.Parent.UI.ScreenManager)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local Join = FtueConfig.Join

local JoinFlow = {}

-- Fires (guiding) when the guided first-minute window opens / closes.
JoinFlow.GuidingChanged = Signal.new() :: Signal.Signal<boolean>

-- A queued item: JoinFlowLogic.Item's fields plus the opener.
type Pending = {
	key: string,
	priority: number,
	queuedAt: number,
	order: number,
	open: () -> (),
}

local pendingItems: { Pending } = {}
local requestCounter = 0
local tutorialStep = 0
local calmSince: number? = nil
local lastBlocker: string? = nil
local looping = false

-- The facts JoinFlowLogic decides on (refreshes the calm clock as a side effect).
local function facts(): JoinFlowLogic.Facts
	local now = os.clock()
	local current: JoinFlowLogic.Facts = {
		now = now,
		loadingDone = LoadingGate.isDone(),
		revealPlaying = PlotReveal.isPlaying(),
		modalOpen = ScreenManager.anyModalOpen(),
		focusMode = ScreenManager.isFocusMode(),
		purchaseFlow = Players.LocalPlayer:GetAttribute(ChangeNotesConfig.PurchaseFlow.Attr) ~= nil,
		guided = FtueConfig.isGuided(tutorialStep),
		calmSince = calmSince,
	}
	if JoinFlowLogic.blocker(current) ~= nil then
		calmSince = nil
	elseif calmSince == nil then
		calmSince = now
	end
	current.calmSince = calmSince
	return current
end

-- Removes the pending item at `index` (order kept).
local function removeAt(index: number)
	table.remove(pendingItems, index)
end

-- Opens the next item when the moment allows; returns true when one opened.
local function step(): boolean
	local now = os.clock()
	for index = #pendingItems, 1, -1 do
		if JoinFlowLogic.expired(pendingItems[index] :: any, now) then
			removeAt(index)
		end
	end
	local current = facts()
	local items: { JoinFlowLogic.Item } = pendingItems :: any
	local item, reason = JoinFlowLogic.pick(items, current)
	lastBlocker = reason
	if item == nil then
		return false
	end
	local index = table.find(items, item)
	if index == nil then
		return false
	end
	local chosen = pendingItems[index]
	removeAt(index)
	-- The next item needs a fresh calm gap after this one (a non-modal item keeps it calm, so
	-- restart the clock explicitly).
	calmSince = nil
	local ok, err = pcall(chosen.open)
	if not ok then
		warn(`[JoinFlow] {chosen.key} failed to open: {err}`)
	end
	return true
end

-- Runs the polling thread while anything is pending (exactly one thread at a time).
local function ensureLoop()
	if looping then
		return
	end
	looping = true
	task.spawn(function()
		while #pendingItems > 0 do
			step()
			task.wait(Join.CheckSeconds)
		end
		looping = false
	end)
end

--[[
	Queues a join-time pop-up.
	@param key      stable id ("WelcomeBack", "TutorialCoach", ...); a pending item with the
	                same key is replaced (latest payload wins)
	@param priority FtueConfig.Join.Priority value (higher opens first)
	@param open     opens the screen (called once, protected)
	Example: JoinFlow.request("WelcomeBack", 100, function() ScreenManager.open("WelcomeBack", p) end)
]]
function JoinFlow.request(key: string, priority: number, open: () -> ())
	requestCounter += 1
	local item: Pending = {
		key = key,
		priority = priority,
		queuedAt = os.clock(),
		order = requestCounter,
		open = open,
	}
	for index, existing in pendingItems do
		if existing.key == key then
			pendingItems[index] = item
			ensureLoop()
			return
		end
	end
	table.insert(pendingItems, item)
	ensureLoop()
end

--[[ Drops a pending item (no-op when none). ]]
function JoinFlow.cancel(key: string)
	for index, existing in pendingItems do
		if existing.key == key then
			removeAt(index)
			return
		end
	end
end

--[[ True while anything waits in the queue. ]]
function JoinFlow.pending(): boolean
	return #pendingItems > 0
end

--[[ True while the tutorial is on one of the guided first-minute steps. ]]
function JoinFlow.guiding(): boolean
	return FtueConfig.isGuided(tutorialStep)
end

--[[
	True when a self-polling pop-up may open right now: calm for the gap, nothing queued ahead of
	it, and (unless `allowGuided`) not during the guided tutorial steps.
	Example: if JoinFlow.isQuiet() then ScreenManager.open("NotifyPrompt", { source = "auto" }) end
]]
function JoinFlow.isQuiet(allowGuided: boolean?): boolean
	if #pendingItems > 0 then
		return false
	end
	local current = facts()
	if current.guided and allowGuided ~= true then
		return false
	end
	return JoinFlowLogic.settled(current)
end

--[[ Tycoon/Tutorial feeds the server tutorial step (0 = none / finished). ]]
function JoinFlow.setTutorialStep(stepNumber: number)
	local before = JoinFlow.guiding()
	tutorialStep = if type(stepNumber) == "number" and stepNumber == stepNumber then stepNumber else 0
	local after = JoinFlow.guiding()
	if before ~= after then
		JoinFlow.GuidingChanged:Fire(after)
	end
end

--[[ QA / admin probe: pending keys (queue order), the last blocker and the guided flag. ]]
function JoinFlow.debugState(): { pending: { string }, blocker: string?, guiding: boolean }
	local keys: { string } = {}
	for _, item in pendingItems do
		table.insert(keys, item.key)
	end
	return { pending = keys, blocker = lastBlocker, guiding = JoinFlow.guiding() }
end

return JoinFlow
