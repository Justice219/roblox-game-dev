--!strict
--[[
	PickerView — streams the attack target picker's target in and tells the picker when it is
	there (owner R104: "you cant see peoples bases in the attack menu").

	Why: with Workspace.StreamingEnabled (Opportunistic stream-out, 768-stud target radius around
	the character) other players' plots and the Rival islands are not on this client, so the
	picker camera showed empty sky. A client RequestStreamAroundAsync alone is temporary.

	What it does, per framed target (`focus(slot)`, called by Screens/AttackTarget/AttackScreen
	every time the camera frames a target, incl. < > cycling):
		1. AttackPickerFocus(slot) to the server (coalesced: at most one intent per SendGap; the
		   newest slot wins) — Server/Attack/PickerFocus keeps a replication focus there while the
		   picker is open, so the base STAYS streamed in.
		2. Player:RequestStreamAroundAsync(focus, RequestTimeout) — the quick first push.
		3. A loading probe every PollSeconds counts the target's BaseParts in its container
		   (Shared/Attack/PickerStream.container: Workspace.Plots.Plot<N> /
		   Workspace.AttackRivals.<id>) and asks PickerStream.step whether it is loaded; the picker
		   shows "LOADING BASE..." while `loading()` is true (Changed fires on every flip).
	`keepAlive()` (picker ticker) re-sends the slot every KeepAlive seconds so the server focus
	never expires while the picker is open; `release()` (picker closed) sends 0 (the server keeps
	the focus a few seconds for the launch cinematic, then drops it).

	Trust: intents only (a slot index); the server validates and rate-limits. Nothing here affects
	gameplay.
	Performance: no per-frame work; the probe runs only while loading (<= LoadTimeout seconds, one
	bounded descendant scan per poll); one task per framed target, stale ones exit by generation.

	Connects to: Shared/Attack/PickerStream, Shared/Config/AttackConfig, Shared/Net/Remotes,
	Shared/Util/Signal; used by Screens/AttackTarget/AttackScreen; QA tools/qa/attack_view.py.

	Example:
		PickerView.focus(9)             -- the picker framed Rival 1
		PickerView.focus(3, { 1, 2 })   -- plot 3 with areas 1-2 built (stream centred on them)
		if PickerView.loading() then ... show the shimmer ... end
		PickerView.release()            -- the picker closed
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage.Shared.Config.AttackConfig)
local AttackGeometry = require(ReplicatedStorage.Shared.Attack.AttackGeometry)
local PickerStream = require(ReplicatedStorage.Shared.Attack.PickerStream)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local PickerView = {}

local STREAM = AttackConfig.Client.PickerStream
local LOCAL = Players.LocalPlayer

-- Fires (loading: boolean) whenever the loading state flips.
PickerView.Changed = Signal.new() :: Signal.Signal<boolean>

local currentSlot = 0 -- the framed target slot (0 = picker closed)
local generation = 0 -- bumps per framed target: stale probe tasks exit
local isLoading = false
local load: PickerStream.Load = PickerStream.newLoad()
local lastCount = 0
local lastSentAt = -math.huge
local lastSentSlot = -1
local sendQueued = false
local intents = 0 -- intents sent this session (QA)

-- Flips the loading flag (Changed fires only on a real change).
local function setLoading(value: boolean)
	if isLoading == value then
		return
	end
	isLoading = value
	PickerView.Changed:Fire(value)
end

-- Sends the current slot now (or once SendGap has passed: fast < > cycling coalesces to the last).
local function send()
	local now = os.clock()
	local wait = lastSentAt + STREAM.SendGap - now
	if wait > 0 then
		if not sendQueued then
			sendQueued = true
			task.delay(wait, function()
				sendQueued = false
				send()
			end)
		end
		return
	end
	lastSentAt = now
	lastSentSlot = currentSlot
	intents += 1
	local slot = currentSlot
	task.spawn(function()
		pcall(function()
			Remotes.event("AttackPickerFocus"):FireServer(slot)
		end)
	end)
end

-- BaseParts of a target slot currently on this client (bounded by ProbeMax).
local function countParts(slot: number): number
	local folderName, childName = PickerStream.container(slot)
	local folder = Workspace:FindFirstChild(folderName)
	local container = if folder ~= nil then folder:FindFirstChild(childName) else nil
	if container == nil then
		return 0
	end
	local count = 0
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
			if count >= STREAM.ProbeMax then
				break
			end
		end
	end
	return count
end

-- The loading probe of one framed target (exits when loaded or when another target is framed).
local function probe(slot: number, gen: number)
	local last = os.clock()
	while generation == gen and currentSlot == slot do
		local count = countParts(slot)
		lastCount = count
		local now = os.clock()
		local done = PickerStream.step(load, count, now - last)
		last = now
		if done then
			if generation == gen then
				setLoading(false)
			end
			return
		end
		task.wait(STREAM.PollSeconds)
	end
end

--[[
	The picker framed target `slot`: stream it in (server focus + client request) and start the
	loading probe. Re-framing the same slot is a no-op.
	@param slot number — a valid target slot
	@param areas { number }? — the target's built areas (owner R133: the first push centres on the
	       built base, like the server focus; nil = the whole plot / the island)
]]
function PickerView.focus(slot: number, areas: { number }?)
	if AttackGeometry.validTarget(slot) == nil or slot == currentSlot then
		return
	end
	currentSlot = slot
	generation += 1
	local gen = generation
	load = PickerStream.newLoad()
	lastCount = 0
	send()
	local point = PickerStream.focusPoint(slot, areas)
	task.spawn(function()
		pcall(function()
			LOCAL:RequestStreamAroundAsync(point, STREAM.RequestTimeout)
		end)
	end)
	-- Already streamed (my own plot, a neighbour)? The first poll settles it within StableTicks.
	setLoading(true)
	task.spawn(probe, slot, gen)
end

--[[ Re-sends the framed slot when KeepAlive seconds passed (picker ticker; cheap otherwise). ]]
function PickerView.keepAlive()
	if currentSlot ~= 0 and os.clock() - lastSentAt >= STREAM.KeepAlive then
		send()
	end
end

--[[ The picker closed: stop probing, tell the server (it lingers briefly, then drops the focus). ]]
function PickerView.release()
	if currentSlot == 0 then
		return
	end
	currentSlot = 0
	generation += 1
	setLoading(false)
	send()
end

--[[ True while the framed target's base is still streaming in (the picker's shimmer). ]]
function PickerView.loading(): boolean
	return isLoading
end

--[[ Diagnostics for QA (tools/qa/attack_view.py). ]]
function PickerView.stats(): { [string]: any }
	return {
		slot = currentSlot,
		loading = isLoading,
		parts = lastCount,
		elapsed = load.elapsed,
		reason = load.reason,
		sentSlot = lastSentSlot,
		intents = intents,
	}
end

return PickerView
