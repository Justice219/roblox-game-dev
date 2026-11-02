--!strict
--[[
	LoadingGate — "has the join loading screen finished?" (owner rule R16).

	Purpose:
		A loading screen (B15, src/first) covers the join until the world is loaded and sets the
		local player attribute `LoadingDone = true` when it fades. The HUD stays hidden until then,
		and the plot reveal + tutorial intro card play only AFTER it. This gate is the one place
		that answers it:
			LoadingGate.isDone()          true once LoadingDone is set (or the safety timeout passed)
			LoadingGate.onDone(callback)  runs `callback` once, now or when loading finishes
		Safety: a build without ReplicatedFirst.LoadingScreen opens the gate at once; if the
		loading screen never reports, the gate opens after HudFocusConfig.LoadingTimeoutSeconds so
		nothing is stuck hidden.

	Performance: one attribute connection + one timer for the whole client.

	Connects to: Controllers/UIController (HUD focus), Tycoon/{PlotReveal, Tutorial}.

	Example: LoadingGate.onDone(function() PlotReveal.play(index) end)
]]

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HudFocusConfig = require(ReplicatedStorage.Shared.Config.HudFocusConfig)

local LoadingGate = {}

local ATTRIBUTE = "LoadingDone"
-- The loading screen's container in ReplicatedFirst (src/first/LoadingScreen, B15).
local LOADING_SCREEN = "LoadingScreen"

local done = false
local watching = false
local waiters: { () -> () } = {}

-- Opens the gate once and runs every queued callback.
local function open()
	if done then
		return
	end
	done = true
	local queued = waiters
	waiters = {}
	for _, callback in queued do
		task.spawn(callback)
	end
end

-- Starts watching the attribute + the safety timer (once).
local function watch()
	if watching then
		return
	end
	watching = true
	local player = Players.LocalPlayer
	-- No loading screen in this build (ReplicatedFirst.LoadingScreen absent): nothing to wait for.
	if player:GetAttribute(ATTRIBUTE) == true or ReplicatedFirst:FindFirstChild(LOADING_SCREEN) == nil then
		open()
		return
	end
	player:GetAttributeChangedSignal(ATTRIBUTE):Connect(function()
		if player:GetAttribute(ATTRIBUTE) == true then
			open()
		end
	end)
	task.delay(HudFocusConfig.LoadingTimeoutSeconds, function()
		if not done then
			warn("[LoadingGate] LoadingDone never arrived; opening the gate after the safety timeout")
			open()
		end
	end)
end

--[[ True once the join loading screen has finished (or the safety timeout passed). ]]
function LoadingGate.isDone(): boolean
	watch()
	return done
end

--[[
	Runs `callback` once loading is done (immediately when it already is).
	@param callback the work to run after the loading screen
]]
function LoadingGate.onDone(callback: () -> ())
	watch()
	if done then
		task.spawn(callback)
	else
		table.insert(waiters, callback)
	end
end

return LoadingGate
