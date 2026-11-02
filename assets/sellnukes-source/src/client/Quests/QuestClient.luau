--!strict
--[[
	QuestClient — the client model of Quests (owner R78, spec §1): ONE place that turns the synced
	profile into what the Quests screen, the HUD Quests badge and the objective chip show, with the
	same pure rules the server uses (Shared/Config/QuestConfig). Boot controller (Init / Start).

	What it does:
		- On every relevant profile push (quests, tycoon, stats, pets, worlds, daily, rebirths, pass;
		  coalesced to one recompute per frame) and at each UTC midnight, rebuilds the View:
		  state (QuestConfig.read: repaired copy of profile.quests), facts (QuestConfig.facts), today,
		  quest claimables, Nuke Pass banner info + claimables (PassBridge, guarded).
		- HUD: the "Quests" left button's red badge = quest claimables + pass claimables ("9+" cap).
		- Objective chip: hands the View to QuestObjective (post-tutorial goal / daily mission).
		- Intents: claim(kind, id) / reroll(slot) fire QuestClaim / QuestReroll (the server
		  re-validates everything; a short per-key debounce keeps a double tap from sending twice).
		- `Changed(view)` for the open screen; `view()` for a first render.

	Display only: nothing here decides a reward. The server answers with a `quests` push + a toast.

	Connects to: Shared/Config/QuestConfig, Client/ClientState, Client/Quests/{QuestObjective,
	PassBridge}, UI/Hud/Hud (badge), Shared/Net/Remotes (QuestClaim, QuestReroll),
	UI/Screens/Quests (reads view / Changed).

	Example:
		local view = QuestClient.view()
		print(view.count, view.badge, view.state.starter.step)
		QuestClient.Changed:Connect(function(view) render(view) end)
		QuestClient.claim("daily", 2)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.Parent.ClientState)
local Hud = require(script.Parent.Parent.UI.Hud.Hud)
local PassBridge = require(script.Parent.PassBridge)
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local QuestObjective = require(script.Parent.QuestObjective)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type View = {
	state: QuestConfig.State,
	facts: QuestConfig.Facts,
	today: number, -- UTC day of the server clock
	now: number, -- server unix seconds at the recompute
	tycoon: any, -- profile.tycoon snapshot (chip guide targets)
	count: number, -- quest claimables
	pass: PassBridge.Info,
	badge: number, -- count + pass claimables
	loaded: boolean, -- a profile snapshot has arrived
}

local QuestClient = {}

QuestClient.Changed = Signal.new() :: Signal.Signal<View>

local HUD_KEY = "Quests"
-- Profile fields any Quests rule reads (a push touching none of them is ignored).
local WATCHED = { "quests", "tycoon", "stats", "pets", "worlds", "daily", "rebirths", "pass" }
-- A claim / reroll intent for the same target is sent at most this often (double-tap guard;
-- the server's rate limit + idempotent claims are the real protection).
local INTENT_DEBOUNCE = 0.6
-- Seconds after UTC midnight to recompute (the server re-seeds within QuestConfig.LoopSeconds).
local MIDNIGHT_SLACK = 1

local current: View? = nil
local queued = false
local started = false
local lastBadge: string? = nil
local lastIntent: { [string]: number } = {}
local wakeThread: thread? = nil

-- The synced server clock (never os.time() on the client).
local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- True when a push touches a watched field (`fields` nil = a full snapshot).
local function touches(fields: { string }?): boolean
	if fields == nil then
		return true
	end
	for _, field in WATCHED do
		if table.find(fields, field) ~= nil then
			return true
		end
	end
	return false
end

-- Builds the View from the current profile snapshot.
local function build(): View
	local profile = ClientState.profile
	local now = serverNow()
	local today = QuestConfig.utcDay(now)
	local state = QuestConfig.read(if profile ~= nil then profile.quests else nil)
	local facts = QuestConfig.facts(profile)
	local count = QuestConfig.claimableCount(state, facts, today)
	local pass = PassBridge.info(profile, now)
	return {
		state = state,
		facts = facts,
		today = today,
		now = now,
		tycoon = if profile ~= nil then profile.tycoon else nil,
		count = count,
		pass = pass,
		badge = count + pass.claimable,
		loaded = profile ~= nil,
	}
end

-- One wake-up shortly after the next UTC midnight (new missions, pass season boundaries).
local function scheduleWake(recompute: () -> ())
	if wakeThread ~= nil then
		pcall(task.cancel, wakeThread)
	end
	wakeThread = task.delay(QuestConfig.secondsToReset(serverNow()) + MIDNIGHT_SLACK, function()
		wakeThread = nil
		recompute()
	end)
end

-- Recomputes the View, the badge and the chip, and tells listeners.
local function recompute()
	local view = build()
	current = view
	local badge = if view.badge <= 0 then nil elseif view.badge > 9 then "9+" else tostring(view.badge)
	if badge ~= lastBadge then
		lastBadge = badge
		Hud.setButtonBadge(HUD_KEY, badge)
	end
	QuestObjective.update(view)
	scheduleWake(recompute)
	QuestClient.Changed:Fire(view)
end

-- Coalesces every trigger in a frame into one recompute.
local function requestRecompute()
	if queued then
		return
	end
	queued = true
	task.defer(function()
		queued = false
		recompute()
	end)
end

--[[ The current View (built on demand before the first push). ]]
function QuestClient.view(): View
	local view = current
	if view ~= nil then
		return view
	end
	local built = build()
	current = built
	return built
end

-- True when an intent for `key` may be sent now (records it).
local function allowIntent(key: string): boolean
	local now = os.clock()
	if now - (lastIntent[key] or -math.huge) < INTENT_DEBOUNCE then
		return false
	end
	lastIntent[key] = now
	return true
end

--[[
	Sends a claim intent (the server re-checks everything).
	@param kind "starter" | "daily" | "chest" | "trophy"
	@param id   goal index / mission slot / trophy id (nil for the chest)
	@return true when the intent was sent
]]
function QuestClient.claim(kind: string, id: (number | string)?): boolean
	if not allowIntent(`claim:{kind}:{tostring(id)}`) then
		return false
	end
	Remotes.event("QuestClaim"):FireServer(kind, id)
	return true
end

--[[ Sends today's free reroll intent for mission `slot` (1..3). @return true when sent ]]
function QuestClient.reroll(slot: number): boolean
	if not allowIntent(`reroll:{slot}`) then
		return false
	end
	Remotes.event("QuestReroll"):FireServer(slot)
	return true
end

--[[ Forces a recompute (the screen calls it on open so countdown-driven state is fresh). ]]
function QuestClient.refresh()
	requestRecompute()
end

function QuestClient.Init() end

function QuestClient.Start()
	if started then
		return
	end
	started = true
	QuestObjective.start()
	ClientState.ProfileChanged:Connect(function(_profile: ClientState.Profile, fields: { string }?)
		if touches(fields) then
			requestRecompute()
		end
	end)
	-- The profile may already be here at boot.
	requestRecompute()
end

return QuestClient
